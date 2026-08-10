defmodule RacingOrg.Tracker.Pro.SecureTransport.SessionHolder do
  @moduledoc """
  Shared, supervised holder for the CURRENT live secure-transport `Session`.

  The `RacingOrg.Tracker.Pro.SecureTransport.ChannelClient` runs the device→server handshake
  over the WSS command channel and, once the server confirms it
  (`"handshake_ok"`), PUBLISHES the established `Session` here. Other subsystems —
  most importantly the P9-job-4 AEAD UDP telemetry path — read the session from
  this single owner rather than reaching into the channel client process.

  ## Why a GenServer owns the send counter

  The secure-transport AEAD nonce is `epoch || send_counter` (see
  `RacingOrg.Tracker.Pro.SecureTransport.Frame`). Reusing a `(key, counter)` pair under one
  epoch is catastrophic (nonce reuse breaks ChaCha20-Poly1305 confidentiality and
  integrity). The counter MUST therefore advance monotonically with no gaps or
  reuse even when MANY processes seal frames concurrently.

  To make that safe by construction, this holder OWNS counter monotonicity: it is
  the single writer of the send counter. A sealer never mutates a `Session`'s
  `send_counter` itself; instead it calls `take_send_counter/1` (or
  `take_send_counters/2` for a batch), which atomically returns the next
  counter value(s) and advances the stored counter. Because the GenServer
  serializes these calls, two concurrent sealers can never receive the same
  counter.

  ## API contract (job-4)

  Job-4 seals a UDP telemetry frame like this:

      {:ok, %{session_id: sid, out_key: key, epoch: epoch, counter: ctr}} =
        SessionHolder.take_send_counter()
      frame = Frame.seal_with(key, epoch, ctr, plaintext)  # job-4 helper

  i.e. `take_send_counter/1` hands back everything needed to seal exactly ONE
  frame: the sealing key (`out_key` = device→server `k_d2s`), the `epoch`, the
  cleartext `session_id` (for routing/the frame header), and a UNIQUE, never-reused
  `counter`. The counter is reserved the instant it is returned, so even if the
  caller crashes before sealing, that counter is simply skipped (gaps are safe;
  reuse is not).

  When there is no live session, the take/get functions return
  `{:error, :no_session}` — callers must not seal.

  ## Independent control_v1 state

  Each published authenticated session also gets a complete
  `RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Control` state. Its send
  counter and receive replay window are independent from the UDP telemetry
  `Session` fields. `with_control_send/5` seals and consumes a control counter
  before serialized transport work runs; `open_control/3` authenticates and
  commits the control replay window. Both require the same session generation
  fence used by the UDP APIs.

  ## Send leases — why transport work must not run in the holder

  The `with_*` callback APIs run caller work INSIDE the holder, which serializes
  that work against replacement and clear. That is the right guarantee, but it is
  the wrong place to do NETWORK I/O: a `Slipstream` push is itself a synchronous
  call into the connection process, so a slow or unanswered push parks the single
  writer and every unrelated caller — `live?/1`, `take_send_counter/1`, `clear/1` —
  queues behind foreign transport until that push times out.

  `acquire_send_lease/2` and `seal_control_send/4` split the two concerns without
  weakening the guarantee. The holder authorizes (and, for control, consumes the
  nonce atomically) and replies IMMEDIATELY; the caller then transmits and releases.
  While a lease is open the holder answers every read normally, but `publish/2,3`,
  `clear/1,2`, and `fence_for_credential_epoch/2` are DEFERRED — parked in arrival
  order and replayed once the last lease clears — so a replacement can still never
  overtake an authorized send. Leaseholders are monitored, so a caller that dies
  mid-send releases its lease automatically and cannot wedge replacement.

  Nonce allocation NEVER leaves the holder. Only the transport write does.

  ## Lifecycle

    * `put/1`        — ChannelClient publishes a freshly-established session
                       (resets UDP and control state for the new session).
    * `take_send_counter/1`, `take_send_counters/2` — reserve UDP counter(s) to seal.
    * `with_control_send/5`, `open_control/3` — own fenced control sealing/replay.
    * `acquire_send_lease/2`, `seal_control_send/4`, `release_send_lease/2` —
                       authorize/seal in the holder, transmit outside it.
    * `get_current_session/0` — read-only UDP snapshot (counter NOT advanced); for
                       inspection/telemetry. UDP sealers MUST use the take functions.
    * `clear/0`      — ChannelClient drops both states on disconnect/eviction.

  The holder is a plain `GenServer` (no ETS/`:persistent_term`): a single writer
  is the simplest correct way to guarantee counter monotonicity, and the session
  is small + read-rarely-relative-to-writes. It is safe to start with NO session
  (idle) and never crashes on a missing session.
  """

  use GenServer

  alias RacingOrg.Tracker.Pro.SecureTransport.Session
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Control

  # Bounds retained reconnect history while allowing thousands of fresh sessions
  # between credential rotations. Tests may inject a smaller limit through init opts.
  @default_session_identity_limit 4_096

  @type generation :: non_neg_integer()

  @type counter_grant :: %{
          session_id: binary(),
          out_key: binary(),
          epoch: non_neg_integer(),
          credential_epoch: non_neg_integer(),
          generation: generation(),
          counter: non_neg_integer(),
          role: Session.role()
        }

  @type session_error :: :no_session | :stale_session

  @type send_lease :: %{
          ref: reference(),
          generation: generation(),
          session_id: binary()
        }

  @type publication_error ::
          :stale_session
          | :epoch_downgrade
          | :session_reused
          | :session_identity_limit_reached

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Publish the current live session, replacing any previous one. The counter base
  is taken from the session's own `send_counter` (normally 0 for a fresh
  handshake).

  This compatibility API discards the holder-assigned generation. New session
  owners should use `publish/2` or fenced `publish/3` and retain the returned
  session.
  """
  @spec put(GenServer.server(), Session.t()) ::
          :ok | {:error, :epoch_downgrade | :session_reused | :session_identity_limit_reached}
  def put(server \\ __MODULE__, %Session{} = session) do
    case publish(server, session) do
      {:ok, %Session{}} ->
        :ok

      {:error, reason} = error
      when reason in [:epoch_downgrade, :session_reused, :session_identity_limit_reached] ->
        error
    end
  end

  @doc """
  Publish a replacement session and return it with its new monotonic generation.

  A cryptographic `session_id` already used in the current credential epoch is
  rejected even after replacement or clear, preventing holder-owned counters and
  replay windows from resetting under reused keys. The retained identity ledger is
  finite; once full, publication fails with `:session_identity_limit_reached` until
  the credential epoch advances. A higher epoch starts a fresh ledger because its
  keys and nonce epoch are distinct.
  """
  @spec publish(GenServer.server(), Session.t()) ::
          {:ok, Session.t()}
          | {:error, :epoch_downgrade | :session_reused | :session_identity_limit_reached}
  def publish(server \\ __MODULE__, %Session{} = session) do
    GenServer.call(server, {:publish, session, :any})
  end

  @doc "Publish only if `expected_generation` is still the holder's current fence."
  @spec publish(GenServer.server(), Session.t(), generation()) ::
          {:ok, Session.t()} | {:error, publication_error()}
  def publish(server, %Session{} = session, expected_generation)
      when is_integer(expected_generation) and expected_generation >= 0 do
    GenServer.call(server, {:publish, session, expected_generation})
  end

  @doc "Return the current monotonic generation fence, including while no session is live."
  @spec generation(GenServer.server()) :: generation()
  def generation(server \\ __MODULE__), do: GenServer.call(server, :generation)

  @doc """
  Return a publication fence for an authenticated credential epoch.

  A higher epoch is retained as a high-water mark, atomically clears any live
  lower-epoch session, and advances the generation even while idle. An equal
  epoch reuses the current generation; a lower requested epoch is rejected.
  """
  @spec fence_for_credential_epoch(GenServer.server(), non_neg_integer()) ::
          {:ok, generation(), :current | :evicted} | {:error, :epoch_downgrade}
  def fence_for_credential_epoch(server \\ __MODULE__, credential_epoch)
      when is_integer(credential_epoch) and credential_epoch >= 0 and
             credential_epoch <= 0xFFFF_FFFF do
    GenServer.call(server, {:fence_for_credential_epoch, credential_epoch})
  end

  @doc "Drop the current session and advance the generation fence."
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__) do
    GenServer.call(server, {:clear, :any})
  end

  @doc "Drop the session only if it is still the expected generation."
  @spec clear(GenServer.server(), generation()) :: :ok | {:error, :stale_session}
  def clear(server, expected_generation)
      when is_integer(expected_generation) and expected_generation >= 0 do
    GenServer.call(server, {:clear, expected_generation})
  end

  @doc """
  Read-only snapshot of the current session, or `{:error, :no_session}`.

  The returned `Session`'s `send_counter` reflects the NEXT counter that would be
  handed out, but reading it here does NOT reserve it. Sealers MUST use
  `take_send_counter/1` instead so the counter is reserved atomically.
  """
  @spec get_current_session(GenServer.server()) :: {:ok, Session.t()} | {:error, :no_session}
  def get_current_session(server \\ __MODULE__) do
    GenServer.call(server, :get_current_session)
  end

  @doc "Whether a live session is currently held."
  @spec live?(GenServer.server()) :: boolean()
  def live?(server \\ __MODULE__) do
    GenServer.call(server, :live?)
  end

  @doc """
  Atomically reserve the next send counter and return everything needed to seal
  ONE outbound (device→server) frame.

  Returns `{:ok, grant}` where `grant` is a `t:counter_grant/0`, or
  `{:error, :no_session}` when no session is live. The reserved counter is never
  handed out again for this session.
  """
  @spec take_send_counter(GenServer.server()) ::
          {:ok, counter_grant()} | {:error, :no_session}
  def take_send_counter(server \\ __MODULE__) do
    take_one_send_counter(server, :any)
  end

  @doc "Reserve one counter only if the expected generation is still current."
  @spec take_send_counter(GenServer.server(), generation()) ::
          {:ok, counter_grant()} | {:error, session_error()}
  def take_send_counter(server, expected_generation)
      when is_integer(expected_generation) and expected_generation >= 0 do
    take_one_send_counter(server, expected_generation)
  end

  @doc """
  Atomically reserve `count` consecutive send counters, returning a grant for
  each (ascending). Useful for sealing a batch without N round-trips.
  """
  @spec take_send_counters(GenServer.server(), pos_integer()) ::
          {:ok, [counter_grant()]} | {:error, :no_session}
  def take_send_counters(server \\ __MODULE__, count) when is_integer(count) and count > 0 do
    GenServer.call(server, {:take_send_counters, count, :any})
  end

  @doc "Reserve a counter block only if the expected generation is still current."
  @spec take_send_counters(GenServer.server(), pos_integer(), generation()) ::
          {:ok, [counter_grant()]} | {:error, session_error()}
  def take_send_counters(server, count, expected_generation)
      when is_integer(count) and count > 0 and is_integer(expected_generation) and
             expected_generation >= 0 do
    GenServer.call(server, {:take_send_counters, count, expected_generation})
  end

  @doc "Run work against the current session while replacement/clear remains serialized."
  @spec with_session(GenServer.server(), generation(), (Session.t() -> result)) ::
          {:ok, result} | {:error, session_error() | :session_callback_failed}
        when result: term()
  def with_session(server, expected_generation, fun)
      when is_integer(expected_generation) and expected_generation >= 0 and is_function(fun, 1) do
    GenServer.call(server, {:with_session, expected_generation, fun})
  end

  @doc """
  Reserve one counter and run `fun` while replacement/clear calls remain serialized
  behind that send boundary. This prevents a granted old-session key from being
  used after the holder has moved to another generation.
  """
  @spec with_send_counter(GenServer.server(), (counter_grant() -> result)) ::
          {:ok, result} | {:error, :no_session | :send_failed}
        when result: term()
  def with_send_counter(server \\ __MODULE__, fun) when is_function(fun, 1) do
    GenServer.call(server, {:with_send_counter, :any, fun})
  end

  @doc "Run fenced send work only if `expected_generation` is still current."
  @spec with_send_counter(GenServer.server(), generation(), (counter_grant() -> result)) ::
          {:ok, result} | {:error, session_error() | :send_failed}
        when result: term()
  def with_send_counter(server, expected_generation, fun)
      when is_integer(expected_generation) and expected_generation >= 0 and is_function(fun, 1) do
    GenServer.call(server, {:with_send_counter, expected_generation, fun})
  end

  @doc """
  Seal one device-to-server `control_v1` payload and run transport work while the
  authenticated session generation remains current.

  The holder owns the complete independent control state. It consumes the control
  counter before invoking `fun`, so a callback failure can skip a nonce but can
  never cause nonce reuse. Session replacement and clear remain serialized behind
  the callback.
  """
  @spec with_control_send(
          GenServer.server(),
          generation(),
          atom(),
          binary(),
          (binary() -> result)
        ) :: {:ok, result} | {:error, atom()}
        when result: term()
  def with_control_send(server, expected_generation, type, encoded_payload, fun)
      when is_integer(expected_generation) and expected_generation >= 0 and is_atom(type) and
             is_binary(encoded_payload) and is_function(fun, 1) do
    GenServer.call(
      server,
      {:with_control_send, expected_generation, type, encoded_payload, fun}
    )
  end

  @doc """
  Authenticate and open one server-to-device `control_v1` frame under the current
  session generation.

  The holder commits the independent control replay window after successful AEAD
  authentication, including authenticated frames whose canonical payload later
  fails validation. UDP telemetry replay state is never read or advanced.
  """
  @spec open_control(GenServer.server(), generation(), binary()) ::
          {:ok, atom(), binary()} | {:error, atom()}
  def open_control(server, expected_generation, frame)
      when is_integer(expected_generation) and expected_generation >= 0 and is_binary(frame) do
    GenServer.call(server, {:open_control, expected_generation, frame})
  end

  @doc """
  Authorize an outbound send under `expected_generation` and hold the session
  against replacement until the lease is released.

  This exists because transport work must NOT run inside a holder callback: a
  `Slipstream` push is a synchronous call into the connection process, so running
  it in `with_session/3` parks the single writer that serializes nonce allocation
  for every subsystem, and unrelated callers (`live?/1`, `take_send_counter/1`)
  queue behind foreign transport.

  A lease preserves the same mutual exclusion without that head-of-line blocking:
  while a lease is open the holder answers every read normally, but `publish/2,3`
  and `clear/1,2` BLOCK until it is released, so a replacement can never overtake
  a send this caller already authorized. The holder monitors the leaseholder and
  releases the lease automatically if it dies, so a crashed sender cannot wedge
  session replacement.
  """
  @spec acquire_send_lease(GenServer.server(), generation()) ::
          {:ok, send_lease()} | {:error, session_error()}
  def acquire_send_lease(server, expected_generation)
      when is_integer(expected_generation) and expected_generation >= 0 do
    GenServer.call(server, {:acquire_send_lease, expected_generation})
  end

  @doc """
  Seal one device-to-server `control_v1` payload and return the frame together with
  an open send lease.

  This is the nonce-safe split of `with_control_send/5`: the counter is still
  consumed ATOMICALLY INSIDE the holder (so concurrent sealers can never collide,
  and a caller that dies after sealing merely skips a nonce), but the transport
  write runs in the caller. The returned lease defers replacement and clear until
  it is released, so a sealed frame can never be transmitted over a session that
  has already been replaced.

  Callers MUST release the lease — use `try/after` — or rely on the holder's
  monitor to release it if they die. A contract failure consumes no counter and
  takes no lease.
  """
  @spec seal_control_send(GenServer.server(), generation(), atom(), binary()) ::
          {:ok, binary(), send_lease()} | {:error, atom()}
  def seal_control_send(server, expected_generation, type, encoded_payload)
      when is_integer(expected_generation) and expected_generation >= 0 and is_atom(type) and
             is_binary(encoded_payload) do
    GenServer.call(server, {:seal_control_send, expected_generation, type, encoded_payload})
  end

  @doc """
  Release a lease taken by `acquire_send_lease/2` or `seal_control_send/4`,
  unblocking deferred replacement/clear. Releasing an unknown, already-released,
  or superseded lease is inert, so callers can release unconditionally.
  """
  @spec release_send_lease(GenServer.server(), send_lease()) :: :ok
  def release_send_lease(server, %{ref: ref}) when is_reference(ref) do
    GenServer.call(server, {:release_send_lease, ref})
  end

  defp take_one_send_counter(server, expected_generation) do
    case GenServer.call(server, {:take_send_counters, 1, expected_generation}) do
      {:ok, [grant]} -> {:ok, grant}
      {:error, _} = error -> error
    end
  end

  # --- Server ---

  @impl true
  def init(opts) do
    session_identity_limit =
      Keyword.get(opts, :session_identity_limit, @default_session_identity_limit)

    if is_integer(session_identity_limit) and session_identity_limit > 0 and
         session_identity_limit <= @default_session_identity_limit do
      {:ok,
       %{
         session: nil,
         control: nil,
         generation: 0,
         credential_epoch: nil,
         used_session_ids: MapSet.new(),
         session_identity_limit: session_identity_limit,
         # ref => monitor_ref for every authorized send still in flight.
         send_leases: %{},
         # Mutations parked behind those leases, replayed in arrival order.
         deferred: :queue.new()
       }}
    else
      {:stop, :invalid_session_identity_limit}
    end
  end

  # Session-mutating calls must not overtake an authorized send. While any lease is
  # open they are parked (in arrival order) and replayed the moment the last lease
  # is released; reads are never parked, so the holder stays responsive.
  @impl true
  def handle_call({:publish, _session, _expected_generation} = request, from, state) do
    maybe_defer(request, from, state)
  end

  def handle_call({:clear, _expected_generation} = request, from, state) do
    maybe_defer(request, from, state)
  end

  def handle_call({:fence_for_credential_epoch, _credential_epoch} = request, from, state) do
    maybe_defer(request, from, state)
  end

  def handle_call({:acquire_send_lease, expected_generation}, {pid, _tag}, state) do
    with :ok <- check_generation(state, expected_generation),
         %Session{} = session <- state.session do
      ref = make_ref()
      monitor_ref = Process.monitor(pid)

      lease = %{ref: ref, generation: state.generation, session_id: session.session_id}

      {:reply, {:ok, lease}, %{state | send_leases: Map.put(state.send_leases, ref, monitor_ref)}}
    else
      nil -> {:reply, {:error, :no_session}, state}
      {:error, :stale_session} = error -> {:reply, error, state}
    end
  end

  def handle_call({:release_send_lease, ref}, _from, state) do
    {:reply, :ok, release_lease(state, ref)}
  end

  # Nonce allocation stays in the holder; only the transport write leaves it.
  def handle_call(
        {:seal_control_send, expected_generation, type, encoded_payload},
        {pid, _tag},
        state
      ) do
    with :ok <- check_generation(state, expected_generation),
         {:ok, control} <- current_control(state),
         {:ok, frame, next_control} <- Control.seal(control, type, encoded_payload) do
      ref = make_ref()
      monitor_ref = Process.monitor(pid)

      lease = %{ref: ref, generation: state.generation, session_id: state.session.session_id}

      {:reply, {:ok, frame, lease},
       %{state | control: next_control, send_leases: Map.put(state.send_leases, ref, monitor_ref)}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:generation, _from, state) do
    {:reply, state.generation, state}
  end

  def handle_call(:get_current_session, _from, %{session: nil} = state) do
    {:reply, {:error, :no_session}, state}
  end

  def handle_call(:get_current_session, _from, %{session: session} = state) do
    {:reply, {:ok, session}, state}
  end

  def handle_call(:live?, _from, state) do
    {:reply, not is_nil(state.session), state}
  end

  def handle_call({:take_send_counters, count, expected_generation}, _from, state) do
    case reserve_counters(state, count, expected_generation) do
      {:ok, grants, next_state} -> {:reply, {:ok, grants}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:with_session, expected_generation, fun}, _from, state) do
    with :ok <- check_generation(state, expected_generation),
         %Session{} = session <- state.session do
      {:reply, invoke_callback(fun, session, :session_callback_failed), state}
    else
      nil -> {:reply, {:error, :no_session}, state}
      {:error, :stale_session} = error -> {:reply, error, state}
    end
  end

  def handle_call({:with_send_counter, expected_generation, fun}, _from, state) do
    case reserve_counters(state, 1, expected_generation) do
      {:ok, [grant], next_state} ->
        {:reply, invoke_callback(fun, grant, :send_failed), next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:with_control_send, expected_generation, type, encoded_payload, fun},
        _from,
        state
      ) do
    with :ok <- check_generation(state, expected_generation),
         {:ok, control} <- current_control(state),
         {:ok, frame, next_control} <- Control.seal(control, type, encoded_payload) do
      next_state = %{state | control: next_control}
      {:reply, invoke_callback(fun, frame, :control_send_failed), next_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:open_control, expected_generation, frame}, _from, state) do
    with :ok <- check_generation(state, expected_generation),
         {:ok, control} <- current_control(state) do
      case Control.open(control, frame) do
        {:ok, type, encoded_payload, next_control} ->
          {:reply, {:ok, type, encoded_payload}, %{state | control: next_control}}

        {:error, reason, next_control} ->
          {:reply, {:error, reason}, %{state | control: next_control}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # A leaseholder that dies mid-send must never wedge session replacement.
  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Enum.find(state.send_leases, fn {_ref, mref} -> mref == monitor_ref end) do
      {ref, _monitor_ref} -> {:noreply, release_lease(state, ref, :already_demonitored)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Mutations run immediately when nothing is in flight, and are otherwise parked
  # until the last lease is released. Reads never reach here, so an open lease
  # never blocks `live?/1`, `get_current_session/0`, or counter allocation.
  defp maybe_defer(request, _from, %{send_leases: leases} = state) when map_size(leases) == 0 do
    {reply, next_state} = apply_request(request, state)
    {:reply, reply, next_state}
  end

  defp maybe_defer(request, from, state) do
    {:noreply, %{state | deferred: :queue.in({request, from}, state.deferred)}}
  end

  defp release_lease(state, ref, demonitor \\ :demonitor) do
    case Map.pop(state.send_leases, ref) do
      {nil, _leases} ->
        state

      {monitor_ref, leases} ->
        if demonitor == :demonitor do
          Process.demonitor(monitor_ref, [:flush])
        end

        flush_deferred(%{state | send_leases: leases})
    end
  end

  # Replay parked mutations in arrival order once the last lease clears. A replayed
  # mutation may itself be rejected (its generation moved on) — that is the correct
  # fenced answer, and exactly what the caller would have received had it run inline.
  defp flush_deferred(%{send_leases: leases} = state) when map_size(leases) > 0, do: state

  defp flush_deferred(state) do
    case :queue.out(state.deferred) do
      {{:value, {request, from}}, rest} ->
        {reply, next_state} = apply_request(request, %{state | deferred: rest})
        GenServer.reply(from, reply)
        flush_deferred(next_state)

      {:empty, _rest} ->
        state
    end
  end

  defp apply_request({:publish, session, expected_generation}, state) do
    with :ok <- check_generation(state, expected_generation),
         :ok <- check_credential_epoch(state, session.credential_epoch),
         :ok <- check_fresh_session(state, session),
         :ok <- check_session_identity_capacity(state, session) do
      generation = state.generation + 1
      published = %{session | generation: generation}
      used_session_ids = remember_session_id(state, published)

      {{:ok, published},
       %{
         state
         | session: published,
           control: new_control_state(published),
           generation: generation,
           credential_epoch: session.credential_epoch,
           used_session_ids: used_session_ids
       }}
    else
      {:error, reason} = error
      when reason in [
             :stale_session,
             :epoch_downgrade,
             :session_reused,
             :session_identity_limit_reached
           ] ->
        {error, state}
    end
  end

  defp apply_request({:clear, expected_generation}, state) do
    case check_generation(state, expected_generation) do
      :ok ->
        generation = state.generation + 1
        {:ok, %{state | session: nil, control: nil, generation: generation}}

      {:error, :stale_session} = error ->
        {error, state}
    end
  end

  defp apply_request(
         {:fence_for_credential_epoch, credential_epoch},
         %{credential_epoch: nil} = state
       ),
       do: {{:ok, state.generation, :current}, %{state | credential_epoch: credential_epoch}}

  defp apply_request(
         {:fence_for_credential_epoch, credential_epoch},
         %{credential_epoch: credential_epoch} = state
       ),
       do: {{:ok, state.generation, :current}, state}

  defp apply_request(
         {:fence_for_credential_epoch, credential_epoch},
         %{credential_epoch: current_epoch} = state
       )
       when current_epoch < credential_epoch do
    generation = state.generation + 1

    {{:ok, generation, :evicted},
     %{
       state
       | session: nil,
         control: nil,
         generation: generation,
         credential_epoch: credential_epoch,
         used_session_ids: MapSet.new()
     }}
  end

  defp apply_request({:fence_for_credential_epoch, _credential_epoch}, state),
    do: {{:error, :epoch_downgrade}, state}

  defp reserve_counters(state, count, expected_generation) do
    with :ok <- check_generation(state, expected_generation),
         %Session{} = session <- state.session do
      start = session.send_counter

      grants =
        for counter <- start..(start + count - 1)//1 do
          %{
            session_id: session.session_id,
            out_key: session.out_key,
            epoch: session.epoch,
            credential_epoch: session.credential_epoch,
            generation: state.generation,
            counter: counter,
            role: session.role
          }
        end

      session = %{session | send_counter: start + count}
      {:ok, grants, %{state | session: session}}
    else
      nil -> {:error, :no_session}
      {:error, :stale_session} = error -> error
    end
  end

  defp current_control(%{session: nil}), do: {:error, :no_session}
  defp current_control(%{control: %Control{} = control}), do: {:ok, control}
  defp current_control(%{control: {:error, reason}}), do: {:error, reason}

  defp new_control_state(%Session{} = session) do
    case Control.new(:device, session) do
      {:ok, %Control{} = control} -> control
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_generation(_state, :any), do: :ok

  defp check_generation(%{generation: generation}, generation), do: :ok
  defp check_generation(_state, _expected_generation), do: {:error, :stale_session}

  # Reinstalling any cryptographic session already used in this credential epoch
  # would reset holder-owned counters/windows and reuse AEAD nonces. Remember ids
  # across replacement and clear; a strictly higher epoch can safely prune them.
  defp check_fresh_session(
         %{credential_epoch: credential_epoch, used_session_ids: used_session_ids},
         %Session{credential_epoch: credential_epoch, session_id: session_id}
       ) do
    if MapSet.member?(used_session_ids, session_id),
      do: {:error, :session_reused},
      else: :ok
  end

  defp check_fresh_session(_state, _session), do: :ok

  defp check_session_identity_capacity(
         %{
           credential_epoch: credential_epoch,
           used_session_ids: used_session_ids,
           session_identity_limit: session_identity_limit
         },
         %Session{credential_epoch: credential_epoch}
       ) do
    if MapSet.size(used_session_ids) < session_identity_limit,
      do: :ok,
      else: {:error, :session_identity_limit_reached}
  end

  defp check_session_identity_capacity(_state, _session), do: :ok

  defp remember_session_id(
         %{credential_epoch: credential_epoch, used_session_ids: used_session_ids},
         %Session{credential_epoch: credential_epoch, session_id: session_id}
       ),
       do: MapSet.put(used_session_ids, session_id)

  defp remember_session_id(_state, %Session{session_id: session_id}),
    do: MapSet.new([session_id])

  defp check_credential_epoch(%{credential_epoch: nil}, _credential_epoch), do: :ok

  defp check_credential_epoch(%{credential_epoch: current_epoch}, credential_epoch)
       when current_epoch <= credential_epoch,
       do: :ok

  defp check_credential_epoch(_state, _credential_epoch), do: {:error, :epoch_downgrade}

  defp invoke_callback(fun, value, failure_reason) do
    {:ok, fun.(value)}
  rescue
    _exception -> {:error, failure_reason}
  catch
    _kind, _reason -> {:error, failure_reason}
  end
end
