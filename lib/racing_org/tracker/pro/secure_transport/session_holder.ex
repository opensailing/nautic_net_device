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
  `send_counter` itself; instead it calls `with_send_counter/2,3` for a fenced send,
  or `take_send_counter/1,2` (`take_send_counters/2,3` for a batch) when it only
  needs to reserve nonce material. Because the GenServer serializes allocation,
  two concurrent sealers can never receive the same counter.

  ## API contract (job-4)

  Job-4 seals and transmits a UDP telemetry frame like this:

      SessionHolder.with_send_counter(fn grant ->
        {:ok, frame} =
          Frame.seal_with(
            grant.session_id,
            grant.epoch,
            grant.counter,
            grant.out_key,
            plaintext
          )

        transport.(frame)
      end)

  `with_send_counter/2,3` atomically reserves everything needed to seal exactly
  one frame plus a monitored send lease. The callback and transport run in the
  CALLER, while replacement/clear remain deferred until the callback returns.

  `take_send_counter/1,2` returns the same nonce material WITHOUT a lease. It is a
  reservation-only primitive: the counter is never reused, but the grant does not
  fence session replacement. A caller that can reach a transport boundary must use
  `with_send_counter/2,3` (or establish an equivalent lease) so it cannot transmit
  reserved old-session bytes after replacement.

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

  The public `with_session/3`, `with_send_counter/2,3`, and
  `with_control_send/5` APIs preserve their callback/result contracts but implement
  them with CALLER-SIDE work under a holder-owned lease. The holder authorizes (and,
  for UDP/control, consumes the nonce atomically) and replies IMMEDIATELY; the
  caller runs arbitrary work and releases before returning. A slow or re-entrant
  callback therefore cannot park the single writer or block `live?/1`,
  `generation/1`, and `get_current_session/1`.

  While a lease is open the holder answers reads normally, but `publish/2,3`,
  `clear/1,2`, and `fence_for_credential_epoch/2` are DEFERRED — parked in arrival
  order and replayed once the last lease clears — so replacement still cannot
  overtake an authorized send. The first deferred mutation also enters DRAIN MODE:
  later lease acquisitions fail closed until the existing leases clear and the FIFO
  mutation queue applies. Deferred callers are monitored, and every mutation carries
  a caller-owned token whose ETS lifetime ends atomically with that caller, so a
  caller that dies while parked cannot be replayed as an orphan even if its monitor
  `:DOWN` has not reached the holder yet. A mutation attempted by the SAME lease
  owner fails fast with `{:error, :send_lease_active}` rather than self-deadlocking.

  Leaseholders are monitored and every lease has a bounded TTL (30 seconds by
  default, configurable with `:send_lease_ttl`). Each lease is bound to the exact
  holder PID that issued it; a per-incarnation guard kills the owner if that holder
  dies, so a restarted registered name cannot validate stale work from its
  predecessor. If an owner dies, the lease is released automatically. If a live
  owner exceeds the TTL, the holder first kills it with an untrappable `:kill` signal
  and only releases the lease after `:DOWN`; it never merely revokes authorization
  while old-session transport could continue. The default deliberately exceeds
  Slipstream's 5-second synchronous push timeout.

  Nonce allocation NEVER leaves the holder. Only callback/transport work does.

  ## Session identity history is bounded and EVICTING

  Re-publishing a recently fenced `session_id` is refused, because re-installing a
  prior session would restart holder-owned counters and the replay window under
  keys that already carried traffic. The retained history is a bounded ring that
  evicts its oldest entry; it must never refuse a fresh session, since a device
  that cannot rotate its own credentials would be permanently unable to reconnect.

  This is defense-in-depth, not the uniqueness primitive. Uniqueness comes from the
  handshake: `session_id` and both direction keys are HKDF-derived from a single
  transcript binding fresh ephemeral keys and the server nonce, so every handshake
  yields a distinct id AND distinct keys. Reproducing an evicted id means
  reproducing that transcript — an RNG failure that already breaks the session keys
  themselves. The ring is also process-local, so it can never be a durable
  invariant across a holder restart in any size.

  ## Lifecycle

    * `put/1`        — ChannelClient publishes a freshly-established session
                       (resets UDP and control state for the new session).
    * `take_send_counter/1`, `take_send_counters/2` — reservation-only UDP
                       counter grants; they do not fence later transport.
    * `with_send_counter/2,3`, `with_control_send/5` — allocate atomically and run
                       fenced callback/transport work in the caller.
    * `open_control/3` — own fenced control replay state.
    * `acquire_send_lease/2`, `take_send_counter_lease/2`,
      `seal_control_send/4`, `release_send_lease/2` — low-level lease primitives.
    * `get_current_session/0` — read-only UDP snapshot (counter NOT advanced); for
                       inspection only. Transport sealers use the leased wrappers.
    * `clear/0`      — ChannelClient drops both states on disconnect/eviction.

  The holder is a plain `GenServer` (no ETS/`:persistent_term`): a single writer
  is the simplest correct way to guarantee counter monotonicity, and the session
  is small + read-rarely-relative-to-writes. It is safe to start with NO session
  (idle) and never crashes on a missing session.
  """

  use GenServer

  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.Session
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Control

  # How many recent session identities are retained per credential epoch for
  # duplicate-publication rejection. The ring EVICTS past this bound; it never
  # refuses a fresh session, so reconnects stay unbounded. See
  # `check_fresh_session/2` for why aging out is sound.
  @session_identity_history 256

  # Long enough to exceed Slipstream's 5-second synchronous push timeout while
  # still bounding a live-but-hung owner. Tests can lower this deterministically.
  @default_send_lease_ttl 30_000

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
          holder: pid(),
          generation: generation(),
          session_id: binary()
        }

  @type mutation_error :: :stale_session | :send_lease_active

  @type publication_error ::
          mutation_error()
          | :epoch_downgrade
          | :session_reused

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
          :ok | {:error, :epoch_downgrade | :session_reused | :send_lease_active}
  def put(server \\ __MODULE__, %Session{} = session) do
    case publish(server, session) do
      {:ok, %Session{}} ->
        :ok

      {:error, reason} = error
      when reason in [:epoch_downgrade, :session_reused, :send_lease_active] ->
        error
    end
  end

  @doc """
  Publish a replacement session and return it with its new monotonic generation.

  Re-publishing the identity the holder is currently fencing is rejected, including
  after a `clear/1`, so holder-owned counters and replay windows can never restart
  under keys that already carried traffic. That is the whole reuse boundary: the
  handshake derives `session_id` and both direction keys from one transcript, so a
  repeated id means repeated keys, and any genuinely new handshake yields both a
  new id and new keys. Reconnects are therefore unbounded: a bounded newest-first
  history evicts its oldest identity and no reconnect count can refuse a fresh
  session merely because the history reached capacity.
  """
  @spec publish(GenServer.server(), Session.t()) ::
          {:ok, Session.t()} | {:error, :epoch_downgrade | :session_reused | :send_lease_active}
  def publish(server \\ __MODULE__, %Session{} = session) do
    call_mutation(server, {:publish, session, :any})
  end

  @doc "Publish only if `expected_generation` is still the holder's current fence."
  @spec publish(GenServer.server(), Session.t(), generation()) ::
          {:ok, Session.t()} | {:error, publication_error()}
  def publish(server, %Session{} = session, expected_generation)
      when is_integer(expected_generation) and expected_generation >= 0 do
    call_mutation(server, {:publish, session, expected_generation})
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
          {:ok, generation(), :current | :evicted}
          | {:error, :epoch_downgrade | :send_lease_active}
  def fence_for_credential_epoch(server \\ __MODULE__, credential_epoch)
      when is_integer(credential_epoch) and credential_epoch >= 0 and
             credential_epoch <= 0xFFFF_FFFF do
    call_mutation(server, {:fence_for_credential_epoch, credential_epoch})
  end

  @doc "Drop the current session and advance the generation fence."
  @spec clear(GenServer.server()) :: :ok | {:error, :send_lease_active}
  def clear(server \\ __MODULE__) do
    call_mutation(server, {:clear, :any})
  end

  @doc "Drop the session only if it is still the expected generation."
  @spec clear(GenServer.server(), generation()) :: :ok | {:error, mutation_error()}
  def clear(server, expected_generation)
      when is_integer(expected_generation) and expected_generation >= 0 do
    call_mutation(server, {:clear, expected_generation})
  end

  @doc """
  Read-only snapshot of the current session, or `{:error, :no_session}`.

  The returned `Session`'s `send_counter` reflects the NEXT counter that would be
  handed out, but reading it here does NOT reserve it. Production transport sealers
  must use `with_send_counter/2,3` so reservation and session fencing are atomic.
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

  This is RESERVATION-ONLY: the counter is never handed out again, but no send
  lease is taken and replacement is not fenced after this call returns. Code that
  can reach a transport boundary must use `with_send_counter/2,3` (or the low-level
  `take_send_counter_lease/2` with `try/after`) so an old-session grant cannot be
  transmitted after replacement.

  Returns `{:ok, grant}` where `grant` is a `t:counter_grant/0`, or
  `{:error, :no_session}` when no session is live.
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
  each (ascending). This is also reservation-only: it guarantees nonce uniqueness,
  not that later transport remains within the granted session generation.
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

  @doc """
  Run caller-side work against the current session under a monitored, bounded
  lease, so replacement/clear remains serialized without blocking holder reads.
  """
  @spec with_session(GenServer.server(), generation(), (Session.t() -> result)) ::
          {:ok, result} | {:error, session_error() | :session_callback_failed}
        when result: term()
  def with_session(server, expected_generation, fun)
      when is_integer(expected_generation) and expected_generation >= 0 and is_function(fun, 1) do
    case GenServer.call(server, {:take_session_lease, expected_generation}) do
      {:ok, session, lease} ->
        invoke_leased_callback(server, lease, fun, session, :session_callback_failed)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Atomically reserve one counter plus a monitored, bounded send lease, then run
  `fun` in the CALLER while replacement/clear remain serialized behind that send
  boundary. This prevents a granted old-session key from being used after the
  holder has moved to another generation without parking the holder in transport.
  """
  @spec with_send_counter(GenServer.server(), (counter_grant() -> result)) ::
          {:ok, result} | {:error, :no_session | :send_failed}
        when result: term()
  def with_send_counter(server \\ __MODULE__, fun) when is_function(fun, 1) do
    with_send_counter_lease(server, :any, fun)
  end

  @doc "Run caller-side fenced send work only if `expected_generation` is still current."
  @spec with_send_counter(GenServer.server(), generation(), (counter_grant() -> result)) ::
          {:ok, result} | {:error, session_error() | :send_failed}
        when result: term()
  def with_send_counter(server, expected_generation, fun)
      when is_integer(expected_generation) and expected_generation >= 0 and is_function(fun, 1) do
    with_send_counter_lease(server, expected_generation, fun)
  end

  @doc """
  Seal one device-to-server `control_v1` payload atomically, then run transport
  work in the CALLER under the returned monitored, bounded lease.

  The holder owns the complete independent control state. It consumes the control
  counter before invoking `fun`, so a callback failure can skip a nonce but can
  never cause nonce reuse. Session replacement and clear remain serialized behind
  the caller-side callback while holder reads stay responsive.
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
    case seal_control_send(server, expected_generation, type, encoded_payload) do
      {:ok, frame, lease} ->
        invoke_leased_callback(server, lease, fun, frame, :control_send_failed)

      {:error, _reason} = error ->
        error
    end
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

  This is the low-level authorization primitive used by code that cannot express
  transport as one of the public `with_*` callbacks. It preserves mutual exclusion
  without head-of-line blocking: while a lease is open the holder answers every
  read normally, but `publish/2,3` and `clear/1,2` wait, so replacement cannot
  overtake an authorized send.

  The holder monitors the owner and bounds every lease with `:send_lease_ttl`. A
  crashed sender releases automatically; a hung live sender is killed before its
  lease is released, so it cannot resume old-session transport after replacement.
  """
  @spec acquire_send_lease(GenServer.server(), generation()) ::
          {:ok, send_lease()} | {:error, session_error()}
  def acquire_send_lease(server, expected_generation)
      when is_integer(expected_generation) and expected_generation >= 0 do
    GenServer.call(server, {:acquire_send_lease, expected_generation})
  end

  @doc """
  Atomically reserve one UDP counter grant and return it with an open send lease.

  Unlike reservation-only `take_send_counter/1,2`, this fences replacement/clear
  from the instant the nonce is allocated until the lease is released. Counter
  allocation stays inside the holder; sealing and transport run in the caller.
  Callers MUST release in `try/after`, or rely on owner monitoring/TTL termination.
  """
  @spec take_send_counter_lease(GenServer.server(), generation()) ::
          {:ok, counter_grant(), send_lease()} | {:error, session_error()}
  def take_send_counter_lease(server, expected_generation)
      when is_integer(expected_generation) and expected_generation >= 0 do
    GenServer.call(server, {:take_send_counter_lease, expected_generation})
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
  Release a lease taken by `acquire_send_lease/2`, `take_send_counter_lease/2`,
  or `seal_control_send/4`,
  unblocking deferred replacement/clear. Releasing an unknown, already-released,
  or superseded lease is inert, so callers can release unconditionally.
  """
  @spec release_send_lease(GenServer.server(), send_lease()) ::
          :ok | {:error, :not_send_lease_owner}
  def release_send_lease(_server, %{holder: holder, ref: ref})
      when is_pid(holder) and is_reference(ref) do
    GenServer.call(holder, {:release_send_lease, ref})
  end

  defp with_send_counter_lease(server, expected_generation, fun) do
    case GenServer.call(server, {:take_send_counter_lease, expected_generation}) do
      {:ok, grant, lease} ->
        invoke_leased_callback(server, lease, fun, grant, :send_failed)

      {:error, :stale_session} when expected_generation == :any ->
        {:error, :no_session}

      {:error, _reason} = error ->
        error
    end
  end

  defp invoke_leased_callback(server, lease, fun, value, failure_reason) do
    callback_result =
      try do
        {:ok, fun.(value)}
      rescue
        _exception -> {:error, failure_reason}
      catch
        _kind, _reason -> {:error, failure_reason}
      end

    case release_send_lease_safely(server, lease) do
      :ok -> callback_result
      {:error, :session_holder_unavailable} -> {:error, failure_reason}
    end
  end

  defp release_send_lease_safely(server, lease) do
    release_send_lease(server, lease)
  catch
    :exit, _reason -> {:error, :session_holder_unavailable}
  end

  defp call_mutation(server, request) do
    token_table = :ets.new(:session_holder_mutation, [:set, :protected])
    token = make_ref()
    true = :ets.insert(token_table, {token, true})

    try do
      GenServer.call(server, {:mutation, request, token_table, token}, :infinity)
    after
      :ets.delete(token_table)
    end
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
    send_lease_ttl = Keyword.get(opts, :send_lease_ttl, @default_send_lease_ttl)

    if is_integer(send_lease_ttl) and send_lease_ttl > 0 do
      {incarnation_guard, incarnation_guard_monitor} = start_incarnation_guard()

      {:ok,
       %{
         session: nil,
         control: nil,
         generation: 0,
         credential_epoch: nil,
         # Bounded newest-first ring of recently fenced identities, retained across
         # clear so a re-derived (therefore same-keyed) session cannot restart its
         # counters. Evicts rather than refusing — see `check_fresh_session/2`.
         used_session_ids: [],
         incarnation_guard: incarnation_guard,
         incarnation_guard_monitor: incarnation_guard_monitor,
         # ref => %{owner, monitor_ref, timer_ref, expiring?} for every authorized
         # send still in flight.
         send_leases: %{},
         send_lease_monitors: %{},
         send_lease_ttl: send_lease_ttl,
         # The queue holds only monitor refs; key-bearing request terms live in the
         # map so DOWN drops them in O(1). Queue tombstones are skipped on drain.
         deferred: :queue.new(),
         deferred_monitors: %{}
       }}
    else
      {:stop, :invalid_send_lease_ttl}
    end
  end

  defp start_incarnation_guard do
    holder = self()

    {guard, guard_monitor} =
      spawn_monitor(fn ->
        holder_monitor = Process.monitor(holder)
        send(holder, {:incarnation_guard_ready, self()})
        incarnation_guard_loop(holder, holder_monitor, %{})
      end)

    receive do
      {:incarnation_guard_ready, ^guard} -> {guard, guard_monitor}
    after
      5_000 -> exit(:incarnation_guard_start_timeout)
    end
  end

  defp incarnation_guard_loop(holder, holder_monitor, owners) do
    receive do
      {:register_send_lease, ^holder, ref, owner} when is_reference(ref) and is_pid(owner) ->
        incarnation_guard_loop(holder, holder_monitor, Map.put(owners, ref, owner))

      {:unregister_send_lease, ^holder, ref} when is_reference(ref) ->
        incarnation_guard_loop(holder, holder_monitor, Map.delete(owners, ref))

      {:DOWN, ^holder_monitor, :process, ^holder, _reason} ->
        kill_lease_owners(owners)

      {:EXIT, ^holder, _reason} ->
        kill_lease_owners(owners)
    end
  end

  defp kill_lease_owners(owners) do
    Enum.each(owners, fn {_ref, owner} -> Process.exit(owner, :kill) end)
  end

  # Session-mutating calls must not overtake an authorized send. While any lease is
  # open they are parked (in arrival order) and replayed the moment the last lease
  # is released; reads are never parked, so the holder stays responsive.
  @impl true
  def handle_call(
        {:mutation, {:publish, _session, _expected_generation} = request, token_table, token},
        from,
        state
      ) do
    maybe_defer(request, from, token_table, token, state)
  end

  def handle_call(
        {:mutation, {:clear, _expected_generation} = request, token_table, token},
        from,
        state
      ) do
    maybe_defer(request, from, token_table, token, state)
  end

  def handle_call(
        {:mutation, {:fence_for_credential_epoch, _credential_epoch} = request, token_table, token},
        from,
        state
      ) do
    maybe_defer(request, from, token_table, token, state)
  end

  def handle_call(
        {:acquire_send_lease, _expected_generation},
        _from,
        %{deferred_monitors: deferred} = state
      )
      when map_size(deferred) > 0,
      do: {:reply, {:error, :stale_session}, state}

  def handle_call({:acquire_send_lease, expected_generation}, {pid, _tag}, state) do
    with :ok <- check_generation(state, expected_generation),
         %Session{} <- state.session do
      {lease, next_state} = new_send_lease(state, pid)
      {:reply, {:ok, lease}, next_state}
    else
      nil -> {:reply, {:error, :no_session}, state}
      {:error, :stale_session} = error -> {:reply, error, state}
    end
  end

  def handle_call(
        {:take_session_lease, _expected_generation},
        _from,
        %{deferred_monitors: deferred} = state
      )
      when map_size(deferred) > 0,
      do: {:reply, {:error, :stale_session}, state}

  def handle_call({:take_session_lease, expected_generation}, {pid, _tag}, state) do
    with :ok <- check_generation(state, expected_generation),
         %Session{} = session <- state.session do
      {lease, next_state} = new_send_lease(state, pid)
      {:reply, {:ok, session, lease}, next_state}
    else
      nil -> {:reply, {:error, :no_session}, state}
      {:error, :stale_session} = error -> {:reply, error, state}
    end
  end

  def handle_call(
        {:take_send_counter_lease, _expected_generation},
        _from,
        %{deferred_monitors: deferred} = state
      )
      when map_size(deferred) > 0,
      do: {:reply, {:error, :stale_session}, state}

  def handle_call({:take_send_counter_lease, expected_generation}, {pid, _tag}, state) do
    case reserve_counters(state, 1, expected_generation) do
      {:ok, [grant], reserved_state} ->
        {lease, next_state} = new_send_lease(reserved_state, pid)
        {:reply, {:ok, grant, lease}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release_send_lease, ref}, {pid, _tag}, state) do
    case release_owned_lease(state, ref, pid) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, :not_send_lease_owner} -> {:reply, {:error, :not_send_lease_owner}, state}
    end
  end

  def handle_call(
        {:seal_control_send, _expected_generation, _type, _encoded_payload},
        _from,
        %{deferred_monitors: deferred} = state
      )
      when map_size(deferred) > 0,
      do: {:reply, {:error, :stale_session}, state}

  # Nonce allocation stays in the holder; only the transport write leaves it.
  def handle_call(
        {:seal_control_send, expected_generation, type, encoded_payload},
        {pid, _tag},
        state
      ) do
    with :ok <- check_generation(state, expected_generation),
         {:ok, control} <- current_control(state),
         {:ok, frame, next_control} <- Control.seal(control, type, encoded_payload) do
      {lease, leased_state} = new_send_lease(%{state | control: next_control}, pid)
      {:reply, {:ok, frame, lease}, leased_state}
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
  def handle_info(
        {:DOWN, monitor_ref, :process, guard, reason},
        %{incarnation_guard: guard, incarnation_guard_monitor: monitor_ref} = state
      ) do
    kill_send_lease_owners(state.send_leases)
    {:stop, {:incarnation_guard_down, reason}, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    cond do
      Map.has_key?(state.deferred_monitors, monitor_ref) ->
        {:noreply, cancel_deferred(state, monitor_ref)}

      lease_ref = Map.get(state.send_lease_monitors, monitor_ref) ->
        {:noreply, release_lease(state, lease_ref, :owner_down)}

      true ->
        {:noreply, state}
    end
  end

  # A live-but-hung owner cannot hold transitions forever. Fail closed: kill the
  # owner first, retain the lease, and wait for its monitored DOWN before replaying
  # deferred mutations. Merely revoking here would let old-session bytes transmit
  # after replacement if the callback later resumed.
  def handle_info({:send_lease_expired, ref}, state) do
    case Map.fetch(state.send_leases, ref) do
      {:ok, %{owner: owner} = lease_state} ->
        Process.exit(owner, :kill)

        expiring = %{lease_state | timer_ref: nil, expiring?: true}
        {:noreply, put_in(state.send_leases[ref], expiring)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Mutations run immediately when nothing is in flight, and are otherwise parked
  # until the last lease is released. Reads never reach here, so an open lease
  # never blocks `live?/1`, `get_current_session/0`, or counter allocation.
  defp maybe_defer(request, {pid, _tag} = from, token_table, token, state)
       when is_pid(pid) do
    cond do
      lease_owner?(state, pid) ->
        {:reply, {:error, :send_lease_active}, state}

      map_size(state.send_leases) == 0 ->
        if mutation_token_live?(token_table, token) do
          {reply, next_state} = apply_request(request, state)
          {:reply, reply, next_state}
        else
          {:reply, {:error, :stale_session}, state}
        end

      true ->
        monitor_ref = Process.monitor(pid)

        entry = %{
          request: request,
          from: from,
          owner: pid,
          token_table: token_table,
          token: token
        }

        {:noreply,
         %{
           state
           | deferred: :queue.in(monitor_ref, state.deferred),
             deferred_monitors: Map.put(state.deferred_monitors, monitor_ref, entry)
         }}
    end
  end

  defp kill_send_lease_owners(send_leases) do
    Enum.each(send_leases, fn {_ref, %{owner: owner}} -> Process.exit(owner, :kill) end)
  end

  defp new_send_lease(%{session: %Session{} = session} = state, owner) when is_pid(owner) do
    ref = make_ref()
    monitor_ref = Process.monitor(owner)
    timer_ref = Process.send_after(self(), {:send_lease_expired, ref}, state.send_lease_ttl)

    lease = %{ref: ref, holder: self(), generation: state.generation, session_id: session.session_id}

    lease_state = %{
      owner: owner,
      monitor_ref: monitor_ref,
      timer_ref: timer_ref,
      expiring?: false
    }

    send(state.incarnation_guard, {:register_send_lease, self(), ref, owner})

    {lease,
     %{
       state
       | send_leases: Map.put(state.send_leases, ref, lease_state),
         send_lease_monitors: Map.put(state.send_lease_monitors, monitor_ref, ref)
     }}
  end

  defp lease_owner?(state, pid) do
    Enum.any?(state.send_leases, fn {_ref, lease_state} -> lease_state.owner == pid end)
  end

  defp mutation_token_live?(token_table, token) do
    :ets.lookup(token_table, token) == [{token, true}]
  rescue
    ArgumentError -> false
  end

  defp cancel_deferred(state, monitor_ref) do
    %{state | deferred_monitors: Map.delete(state.deferred_monitors, monitor_ref)}
  end

  defp release_owned_lease(state, ref, owner) do
    case Map.fetch(state.send_leases, ref) do
      :error ->
        {:ok, state}

      {:ok, %{owner: ^owner}} ->
        {:ok, release_lease(state, ref)}

      {:ok, _lease_state} ->
        {:error, :not_send_lease_owner}
    end
  end

  defp release_lease(state, ref, release_reason \\ :owner_release) do
    case Map.fetch(state.send_leases, ref) do
      :error ->
        state

      # Expiry has already killed the owner. Keep the lease until DOWN proves that
      # process can no longer resume old-session transport.
      {:ok, %{expiring?: true}} when release_reason == :owner_release ->
        state

      {:ok, lease_state} ->
        if release_reason == :owner_release do
          Process.demonitor(lease_state.monitor_ref, [:flush])
        end

        send(state.incarnation_guard, {:unregister_send_lease, self(), ref})
        cancel_lease_timer(ref, lease_state.timer_ref)
        leases = Map.delete(state.send_leases, ref)
        lease_monitors = Map.delete(state.send_lease_monitors, lease_state.monitor_ref)
        flush_deferred(%{state | send_leases: leases, send_lease_monitors: lease_monitors})
    end
  end

  defp cancel_lease_timer(_ref, nil), do: :ok

  defp cancel_lease_timer(ref, timer_ref) do
    _ = Process.cancel_timer(timer_ref, async: false, info: false)

    receive do
      {:send_lease_expired, ^ref} -> :ok
    after
      0 -> :ok
    end
  end

  # Replay parked mutations in arrival order once the last lease clears. A replayed
  # mutation may itself be rejected (its generation moved on) — that is the correct
  # fenced answer, and exactly what the caller would have received had it run inline.
  defp flush_deferred(%{send_leases: leases} = state) when map_size(leases) > 0, do: state

  defp flush_deferred(state) do
    case :queue.out(state.deferred) do
      {{:value, monitor_ref}, rest} ->
        {entry, deferred_monitors} = Map.pop(state.deferred_monitors, monitor_ref)
        next_state = %{state | deferred: rest, deferred_monitors: deferred_monitors}

        case entry do
          nil ->
            flush_deferred(next_state)

          %{request: request, from: from, token_table: token_table, token: token} ->
            token_live? = mutation_token_live?(token_table, token)
            Process.demonitor(monitor_ref, [:flush])

            if token_live? do
              {reply, applied_state} = apply_request(request, next_state)
              GenServer.reply(from, reply)
              flush_deferred(applied_state)
            else
              flush_deferred(next_state)
            end
        end

      {:empty, _rest} ->
        state
    end
  end

  defp apply_request({:publish, session, expected_generation}, state) do
    with :ok <- check_generation(state, expected_generation),
         :ok <- check_credential_epoch(state, session.credential_epoch),
         :ok <- check_fresh_session(state, session) do
      generation = state.generation + 1
      published = %{session | generation: generation}

      {{:ok, published},
       %{
         state
         | session: published,
           control: new_control_state(published),
           generation: generation,
           credential_epoch: session.credential_epoch,
           used_session_ids: remember_session_id(state, published)
       }}
    else
      {:error, reason} = error
      when reason in [:stale_session, :epoch_downgrade, :session_reused] ->
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

    # A strictly higher credential epoch re-keys everything: the epoch is bound into
    # the transcript, so no id from the old epoch can be re-derived under the new
    # one and the retained identity is meaningless there.
    {{:ok, generation, :evicted},
     %{
       state
       | session: nil,
         control: nil,
         generation: generation,
         credential_epoch: credential_epoch,
         used_session_ids: []
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

  # Refuse to reinstall a cryptographic identity this holder recently fenced.
  #
  # Reinstating a prior session restarts holder-owned counters and the replay
  # window under keys that already carried traffic, which IS nonce reuse — so the
  # check cannot narrow to "the current session only". But the retained history
  # must not become an availability cliff either: the previous implementation
  # REFUSED publication once the ledger filled, so ~4k legitimate reconnects on one
  # credential epoch permanently bricked reconnect on a device that cannot rotate
  # its own credentials.
  #
  # The history is therefore a bounded ring that EVICTS its oldest entry instead of
  # refusing a fresh session. Reconnects are unbounded; only replay protection ages
  # out, and it ages out along the axis where it stops mattering.
  #
  # Aging out is sound because the real uniqueness boundary is the HANDSHAKE:
  # `session_id` and both direction keys are HKDF-derived from one transcript that
  # binds freshly generated ephemeral keys plus the server nonce. Re-deriving an
  # evicted id requires reproducing that transcript — i.e. the device repeating its
  # own ephemeral key — which is an RNG failure that already breaks the session
  # keys themselves. The ring is defense-in-depth against a duplicate/retried
  # publication, not the primitive that provides uniqueness. (It also cannot be a
  # DURABLE invariant in any size: it is process-local and a holder restart erases
  # it, so it never survived the boundary an unbounded ledger appeared to protect.)
  defp check_fresh_session(
         %{credential_epoch: credential_epoch, used_session_ids: used_session_ids},
         %Session{credential_epoch: credential_epoch, session_id: session_id}
       ) do
    if Enum.any?(used_session_ids, &Primitives.secure_compare(&1, session_id)),
      do: {:error, :session_reused},
      else: :ok
  end

  defp check_fresh_session(_state, _session), do: :ok

  # Newest first, oldest evicted past the cap — bounded memory, never a refusal.
  defp remember_session_id(
         %{credential_epoch: credential_epoch, used_session_ids: used_session_ids},
         %Session{credential_epoch: credential_epoch, session_id: session_id}
       ),
       do: Enum.take([session_id | used_session_ids], @session_identity_history)

  defp remember_session_id(_state, %Session{session_id: session_id}), do: [session_id]

  defp check_credential_epoch(%{credential_epoch: nil}, _credential_epoch), do: :ok

  defp check_credential_epoch(%{credential_epoch: current_epoch}, credential_epoch)
       when current_epoch <= credential_epoch,
       do: :ok

  defp check_credential_epoch(_state, _credential_epoch), do: {:error, :epoch_downgrade}
end
