defmodule RacingOrg.Tracker.Pro.SecureTransport.ChannelClient do
  @moduledoc """
  Device side of the RacingOrg authenticated command channel (P9): an OUTBOUND,
  CGNAT-friendly WSS Slipstream client that runs the SecureTransport INITIATOR
  handshake over channel messages, receives server→device commands, applies them
  through the SAME command path as the UDP transport, and acks them.

  ## Transport

  Mirrors `NervesHubLink.Socket`: a single outbound `wss://` connection (so a
  device behind CGNAT/NAT reaches the server without an inbound route), TLS via
  the system/`castore` CA bundle, `http1` only. It connects to the server's
  `RacingOrgWeb.DeviceSocket` mount (`/device_socket`) presenting the device key
  `fingerprint` as the connect param, then joins `device:<fingerprint>`.

  ## Handshake (driven over channel pushes — see `RacingOrgWeb.DeviceChannel`)

      join "device:<fp>"               ==>
                                       <== "handshake_hello" %{hello: b64}
      "handshake_init" %{init: b64}    ==>
                                       <== "handshake_ok"    %{session_id: b64}
                                           (or "handshake_error" %{reason})

  On `"handshake_hello"` the client runs
  `RacingOrg.Tracker.Pro.SecureTransport.Handshake.initiator_init/2` (via the pure
  `ChannelHandler`) with its identity (`KeyStore`), the pinned server public key
  (`ServerIdentity`), and its fingerprint as the `device_id`. It pushes the INIT
  and holds the derived `Session`. On `"handshake_ok"` it sanity-checks the
  `session_id`, marks the session LIVE, and PUBLISHES it to
  `RacingOrg.Tracker.Pro.SecureTransport.SessionHolder` (the shared holder job-4 reads for
  AEAD UDP telemetry).

  ## Commands

  There are two mutually exclusive command paths, selected by what the session
  negotiated at connect.

  AUTHENTICATED DURABLE (a control capability offer was made): commands arrive as
  `control_v1` `:command_delivery` frames and are routed to
  `RacingOrg.Tracker.Pro.Commands.Ledger.Executor`, which classifies them,
  persists the intent, runs the effect, persists the terminal outcome, and
  returns the exact `:command_ack` this client seals and sends. In this mode the
  legacy `"command"` event is DISABLED: honoring it would apply an unfenced
  effect and emit a legacy ACK for a command the ledger never admitted.

  LEGACY (no capability offer): a `"command"` push decodes the `ServerReply`
  protobuf and applies it through `RacingOrg.Tracker.Pro.Commands` (the existing,
  idempotent handler), then pushes the `"ack"` event the server expects.
  Duplicate commands are de-duped by `RacingOrg.Tracker.Pro.Commands` and still
  acked. This path is preserved only for genuinely legacy sessions, where no
  durable command delivery owns the command.

  ## Eviction / reconnect

  `"session_evicted"` (or `"handshake_error"`, or any disconnect) clears the
  session holder and schedules a reconnect on a JITTERED exponential backoff
  (`RacingOrg.Tracker.Pro.SecureTransport.Backoff`) — never a hot loop. A fresh handshake runs
  on every reconnect.

  ## Gating (job-6 wires this into the supervision tree)

  `start_link/1` always succeeds and the process is safe to run "not configured":
  if the device is not on a real target, is unregistered, has no identity, or has no
  pinned server key, the client stays IDLE (it never attempts to connect and never
  crash-loops). It only connects when `connectable?/1` is true and starts after the
  supervised bootstrap coordinator in `application.ex`.
  """

  use Slipstream

  require Logger

  alias RacingOrg.Tracker.Pro.Commands.Ledger.Executor, as: CommandExecutor
  alias RacingOrg.Tracker.Pro.DesiredState.{Manager, Runtime}
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner, as: OutboxOwner
  alias RacingOrg.Tracker.Pro.SecureTransport.Backoff
  alias RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelHandler
  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.Session
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Control, Messages, Negotiation}

  @device_socket_path "/device_socket"
  @control_offer %{control_versions: [1], desired_state_versions: [1]}

  # --- Public API / child spec ---

  @doc """
  Start the channel client. Always returns `{:ok, pid}` (or a standard GenServer
  start result); the process self-gates and stays idle when not configured.

  Options (all optional; sensible production defaults):

    * `:name` — registered name (default `__MODULE__`).
    * `:commands` — the `RacingOrg.Tracker.Pro.Commands` server (default `RacingOrg.Tracker.Pro.Commands`).
    * `:session_holder` — the `SessionHolder` server (default `SessionHolder`).
    * `:boot_provisioner` — coordinator collaborator as a module or `{module, server}`.
    * `:bootstrap_opts` — full authority-validation options used by `connectable?/1`.
    * `:wifi` — the WiFi collaborator that applies config + reports status. Either a
      module (used as both module and GenServer name, default `RacingOrg.Tracker.Pro.WiFiManager`)
      or a `{module, server}` tuple so tests can inject a fake module + pid.
    * `:url` — full `wss://host/device_socket` URL override (else derived from
      `SECURE_TRANSPORT_WS_URL`, then the configured `:api_endpoint` host).
    * `:command_executor` — the durable command executor server that owns
      authenticated `control_v1` command delivery (default
      `RacingOrg.Tracker.Pro.Commands.Ledger.Executor`).
    * `:command_executor_module` — the module used to call it, so tests can
      inject a stand-in without a real on-disk ledger.
    * `:keystore_opts` — opts forwarded to `KeyStore.load/1` (tests use a temp dir).
    * `:auto_connect?` — force connect/idle for tests (defaults to `connectable?/0`).
    * `:backoff` — `RacingOrg.Tracker.Pro.SecureTransport.Backoff` opts.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Slipstream.start_link(__MODULE__, opts, name: name)
  end

  @doc "Standard supervisor child spec (job-6 adds this to the tree)."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name) || __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc "Enqueue a durable desired-state ACK for authenticated control delivery."
  @spec send_desired_state_ack(GenServer.server(), map()) ::
          :ok | {:error, :control_plane_unavailable}
  def send_desired_state_ack(server \\ __MODULE__, ack) when is_map(ack) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        send(pid, {:send_desired_state_ack, ack})
        :ok

      _unavailable ->
        {:error, :control_plane_unavailable}
    end
  end

  @doc """
  Whether the device is currently configured to connect: a real device target AND
  registered AND a provisioned identity AND a pinned server public key. Host/test and
  unregistered/unprovisioned devices return `false` (the client stays idle).
  """
  @spec connectable?(keyword()) :: boolean()
  def connectable?(opts \\ []) do
    device_target?() and registered?(opts) and has_identity?(opts) and ServerIdentity.configured?()
  end

  @doc """
  Stream a batch of live computed values back to the backend over the channel
  (Phase 10), as the `"computed_values_data"` event with payload `%{values: values}`,
  where each value is `%{id: <computed_value_uuid>, value: <number>}`.

  Best-effort: it casts the batch to the running client, which pushes ONLY when a
  secure session is live (a joined topic + derived session). With no live session —
  or no running client — it is a no-op (exactly like telemetry is dropped when no
  session). Always returns `:ok` and never raises (the Phase 8 broadcaster calls this
  on every flush and must never be coupled to channel state).
  """
  @spec send_computed_values_data(GenServer.server(), [map()]) :: :ok
  def send_computed_values_data(server \\ __MODULE__, values) when is_list(values) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> send(pid, {:send_computed_values_data, values})
      _ -> :ok
    end

    :ok
  end

  @doc """
  Stream an incremental SAILED-POLAR update back to the backend over the channel
  (Phase 4), as the `"sailed_polar_update"` event with payload
  `%{boat_identifier: id, seq: monotonic_int, cells: cells}`, where each cell is
  `%{tws_mps: float, twa_deg: float, boat_speed_mps: float, count: int}` — the
  binned wind operating point (bin center), its percentile boat speed, and the
  cell's sample count. `seq` is a per-device monotonic sequence so the server can
  order/merge deltas (later `seq` wins for a given cell).

  Best-effort + session-gated, exactly like `send_computed_values_data/2`: it casts
  the batch to the running client, which pushes ONLY when a secure session is live.
  With no live session — or no running client — it is a no-op (the delta is simply
  dropped, like telemetry; the `Observer` re-emits it on its next sync). Always
  returns `:ok` and never raises (the `Observer` calls this on each throttled sync
  and must never be coupled to channel state).
  """
  @spec send_sailed_polar_update(GenServer.server(), map()) :: :ok
  def send_sailed_polar_update(server \\ __MODULE__, %{} = update) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> send(pid, {:send_sailed_polar_update, update})
      _ -> :ok
    end

    :ok
  end

  @doc """
  Stream a throttled AUTO-CALIBRATION update back to the backend over the channel,
  as the `"calibration_update"` event with payload
  `%{boat_identifier: id, seq: monotonic_int, entries: entries}`, where each entry
  is `%{hardware_identifier:, parameter:, value:, confidence:, sample_count:,
  state:, residual:}`. Banded parameters additionally carry the full `curve`:
  `stw_scale` as `[%{center:, gain:}]` and (once its TWS curve has published)
  `awa_upwash` as `[%{center:, value:}]` — awa_upwash curve points use `value`
  keys, which is what the backend expects. `seq` is a per-device advisory
  sequence; the server merges idempotently per (sensor, parameter), so a
  reboot-reset seq is harmless.

  Best-effort + session-gated, exactly like `send_sailed_polar_update/2`: pushes
  ONLY when a secure session is live; with no live session — or no running
  client — the update is simply dropped (the `Calibration.Observer` re-emits
  changed entries on its next throttled sync). Always returns `:ok` and never
  raises (the Observer must never be coupled to channel state).
  """
  @spec send_calibration_update(GenServer.server(), map()) :: :ok
  def send_calibration_update(server \\ __MODULE__, %{} = update) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> send(pid, {:send_calibration_update, update})
      _ -> :ok
    end

    :ok
  end

  @doc """
  Stream a throttled WIND-SHIFT update back to the backend over the channel, as
  the `"wind_shift_update"` event with payload `%{boat_identifier:, seq:,
  session: %{started_at_ms:, centroid:, race_session_id:, summary:},
  timeline: rows, events: events}` — the session-scoped batch the
  `WindShift.Observer` assembles (60 s timeline rows + envelope/step/regime/
  extrema events + the running session summary). `seq` is a per-device
  monotonic sequence so the server can order batches.

  Best-effort + session-gated, exactly like `send_calibration_update/2`: pushes
  ONLY when a secure session is live; with no live session — or no running
  client — the update is simply dropped (the Observer keeps its session summary
  and re-syncs when it next changes). The Observer already skips no-op batches
  (nothing new AND an unchanged summary); a degenerate update with no session
  and empty timeline/events is dropped here too. Always returns `:ok` and never
  raises (the Observer must never be coupled to channel state).
  """
  @spec send_wind_shift_update(GenServer.server(), map()) :: :ok
  def send_wind_shift_update(server \\ __MODULE__, %{} = update) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> send(pid, {:send_wind_shift_update, update})
      _ -> :ok
    end

    :ok
  end

  @doc """
  Request a route recalc from the backend (P3), as the `"request_route_recalc"`
  event. `position` is `{lat, lon}` (the boat's exact position at the deviation) or
  `nil`; when present it is sent as `%{position: %{latitude: lat, longitude: lon}}`,
  otherwise the payload is empty and the server resolves the position from telemetry.

  Best-effort + session-gated, exactly like `send_computed_values_data/2`: it casts to
  the running client, which pushes ONLY when a secure session is live. With no live
  session — or no running client — it is a no-op. Always returns `:ok` and never
  raises (the `RacingOrg.Tracker.Pro.Nav.DeviationMonitor` calls this and must never be
  coupled to channel state).
  """
  @spec request_route_recalc(GenServer.server(), {number(), number()} | nil) :: :ok
  def request_route_recalc(server \\ __MODULE__, position) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> send(pid, {:request_route_recalc, position})
      _ -> :ok
    end

    :ok
  end

  # --- Slipstream callbacks ---

  @impl Slipstream
  def init(opts) do
    {control_offer, control_selection} = control_negotiation!(opts)

    state = %{
      opts: opts,
      commands: Keyword.get(opts, :commands, RacingOrg.Tracker.Pro.Commands),
      session_holder: Keyword.get(opts, :session_holder, SessionHolder),
      boot_provisioner: normalize_collaborator(Keyword.get(opts, :boot_provisioner, BootProvisioner)),
      wifi: normalize_wifi(Keyword.get(opts, :wifi, RacingOrg.Tracker.Pro.WiFiManager)),
      # The per-state tracking config (damping + send-rate). `tracking` applies the
      # server-pushed config (default RacingOrg.Tracker.Pro.Tracking.Config); `tracking_status`
      # reports what is actually being applied (default RacingOrg.Tracker.Pro.Sampling). Both
      # are {module, server} pairs (a bare module is used as both module + name).
      tracking: normalize_collaborator(Keyword.get(opts, :tracking, RacingOrg.Tracker.Pro.Tracking.Config)),
      tracking_status: normalize_collaborator(Keyword.get(opts, :tracking_status, RacingOrg.Tracker.Pro.Sampling)),
      # The upstream signal selection: applies the server-pushed "set_upstream"
      # config (default RacingOrg.Tracker.Pro.Upstream.Config, which is ALSO the
      # status source) and reports the applied version back as "upstream_status".
      # A {module, server} pair (a bare module is used as both module + name).
      upstream: normalize_collaborator(Keyword.get(opts, :upstream, RacingOrg.Tracker.Pro.Upstream.Config)),
      # The clock-source policy: applies the server-pushed "set_clock_source" config
      # (default RacingOrg.Tracker.Pro.ClockSource.Config, which is ALSO the status
      # source) and reports the active boat-time timebase back as
      # "clock_source_status". A {module, server} pair (bare module = both).
      clock_source: normalize_collaborator(Keyword.get(opts, :clock_source, RacingOrg.Tracker.Pro.ClockSource.Config)),
      # The calibration policy: applies the server-pushed "set_calibration" config
      # (default RacingOrg.Tracker.Pro.Calibration.Config, which is ALSO the status
      # source) and reports the learned/locked per-sensor state back as
      # "calibration_status". A {module, server} pair (bare module = both).
      calibration: normalize_collaborator(Keyword.get(opts, :calibration, RacingOrg.Tracker.Pro.Calibration.Config)),
      # The wind-shift policy: applies the server-pushed "set_wind_shift" config
      # (default RacingOrg.Tracker.Pro.WindShift.Config — the POLICY half of the
      # status: applied_version + wally_mode). The LIVE half (regime, confidence,
      # oscillation, phase/lift, range) comes from the separate
      # :wind_shift_observer collaborator (default
      # RacingOrg.Tracker.Pro.WindShift.Observer); "wind_shift_status" composes
      # the two, exactly like tracking (Tracking.Config applies, Sampling
      # reports). Both are {module, server} pairs (bare module = both).
      wind_shift: normalize_collaborator(Keyword.get(opts, :wind_shift, RacingOrg.Tracker.Pro.WindShift.Config)),
      wind_shift_observer:
        normalize_collaborator(Keyword.get(opts, :wind_shift_observer, RacingOrg.Tracker.Pro.WindShift.Observer)),
      # The on-device compute engine: applies the server-pushed computed-value defs
      # ("set_computed_values") and reports applied_version + active_count back as
      # "computed_values_status". A {module, server} pair (bare module = both).
      compute: normalize_collaborator(Keyword.get(opts, :compute, RacingOrg.Tracker.Pro.Compute.Engine)),
      # The Phase 8 N2K broadcaster: reports whether any computed value is actively
      # being broadcast on the bus, surfaced as the `broadcasting` field of
      # "computed_values_status". A {module, server} pair (bare module = both).
      compute_broadcaster:
        normalize_collaborator(Keyword.get(opts, :compute_broadcaster, RacingOrg.Tracker.Pro.Compute.Broadcaster)),
      firmware_validator:
        Keyword.get(opts, :firmware_validator, &RacingOrg.Tracker.Pro.FirmwareValidator.validate_on_connect/0),
      backoff_opts: Keyword.get(opts, :backoff, Backoff.defaults()),
      control_offer: control_offer,
      control_selection: control_selection,
      # The durable command executor that owns classification, the ledger, and
      # every command effect. `command_executor_module` exists so tests can inject
      # a stand-in without a real ledger on disk.
      command_executor: Keyword.get(opts, :command_executor, CommandExecutor),
      command_executor_module: Keyword.get(opts, :command_executor_module, CommandExecutor),
      outbox: Keyword.get(opts, :outbox, OutboxOwner),
      outbox_module: Keyword.get(opts, :outbox_module, OutboxOwner),
      desired_state_manager: Keyword.get(opts, :desired_state_manager, Manager),
      desired_state_manager_module: Keyword.get(opts, :desired_state_manager_module, Manager),
      desired_state_identity: Keyword.get(opts, :desired_state_identity, &Runtime.identity/0),
      desired_state_compatibility: Keyword.get(opts, :desired_state_compatibility, &Runtime.compatibility/0),
      desired_state_status:
        Keyword.get(opts, :desired_state_status, fn ->
          Manager.status(Keyword.get(opts, :desired_state_manager, Manager))
        end),
      desired_state_replay:
        Keyword.get(opts, :desired_state_replay, fn generation ->
          Manager.replay(Keyword.get(opts, :desired_state_manager, Manager), generation)
        end),
      control_topic: nil,
      control_ready?: false,
      attempt: 0,
      session: nil,
      session_fence: nil,
      owned_session_generation: nil,
      enrollment_ref: nil,
      topic: nil
    }

    # Report wlan0 connection changes to the server so the owner's /account page
    # reflects live status. Real (target) builds subscribe to the VintageNet
    # property; host/test builds skip it (VintageNet is target-only) and instead
    # drive `handle_info({VintageNet, ...}, socket)` directly in tests.
    maybe_subscribe_wlan0(opts)

    socket = new_socket() |> assign(state)

    if auto_connect?(opts) do
      {:ok, socket, {:continue, :connect}}
    else
      Logger.info(
        "[ChannelClient] not yet provisioned (unregistered / no identity / no pinned " <>
          "server key); will re-check until ready"
      )

      {:ok, schedule_recheck(socket)}
    end
  end

  @impl Slipstream
  def handle_continue(:connect, socket) do
    case connect_opts(socket.assigns.opts, socket.assigns.control_offer) do
      {:ok, opts, topic} ->
        Logger.info("[ChannelClient] connecting to #{inspect(opts[:uri])}")
        {:noreply, socket |> assign(:topic, topic) |> connect!(opts)}

      {:error, reason} ->
        Logger.warning("[ChannelClient] cannot build connect opts: #{inspect(reason)}; backing off")
        {:noreply, schedule_reconnect(socket)}
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    Logger.info("[ChannelClient] socket connected; joining #{socket.assigns.topic}")
    {:ok, join(socket, socket.assigns.topic)}
  end

  @impl Slipstream
  def handle_join(_topic, _reply, socket) do
    # Reset the failure counter only once the server actually completes the
    # handshake (handshake_ok); a successful socket+join but failed handshake must
    # still back off. So we do NOT reset attempt here.
    Logger.debug("[ChannelClient] joined #{socket.assigns.topic}; awaiting handshake_hello")
    {:ok, socket}
  end

  # Server pushes "handshake_hello" -> produce + push INIT, hold the session.
  @impl Slipstream
  def handle_message(_topic, "handshake_hello", payload, socket) do
    with {:ok, init_payload, session} <- ChannelHandler.handshake_init(payload, handshake_inputs(socket)),
         :ok <- persist_handshake_epoch(socket, session.credential_epoch),
         {:ok, session_fence} <- handshake_session_fence(socket, session.credential_epoch) do
      socket =
        socket
        |> assign(:session, session)
        |> assign(:session_fence, session_fence)

      push(socket, socket.assigns.topic, "handshake_init", init_payload)
      {:ok, socket}
    else
      {:error, reason} ->
        Logger.error("[ChannelClient] handshake_init failed: #{inspect(reason)}")
        {:ok, fail_handshake(socket)}
    end
  end

  # Server confirms with "handshake_ok" -> verify, publish the live session.
  def handle_message(_topic, "handshake_ok", payload, socket) do
    case socket.assigns.session do
      %Session{generation: generation} = session when is_integer(generation) ->
        case ChannelHandler.verify_handshake_ok(payload, session) do
          :ok ->
            Logger.debug("[ChannelClient] ignoring duplicate handshake_ok for the live session")
            {:ok, socket}

          {:error, reason} ->
            Logger.error("[ChannelClient] duplicate handshake_ok rejected: #{inspect(reason)}")
            {:ok, fail_handshake(socket)}
        end

      nil ->
        Logger.error("[ChannelClient] handshake_ok before a derived session")
        {:ok, fail_handshake(socket)}

      session ->
        with :ok <- ChannelHandler.verify_handshake_ok(payload, session),
             {:ok, published_session} <- publish_session(socket, session) do
          Logger.info("[ChannelClient] secure session established")

          socket =
            socket
            |> assign(:session, published_session)
            |> assign(:session_fence, published_session.generation)
            |> assign(:owned_session_generation, published_session.generation)
            |> report_authenticated()

          # The device has connected to RacingOrg correctly -> mark the running
          # firmware VALID (idempotent, best-effort). A bad OTA that never reaches
          # this point stays unvalidated and auto-reverts on the next reboot.
          _ = socket.assigns.firmware_validator.()
          # Report current WiFi status once the session is live so the server
          # reflects the device's actual state on (re)connect.
          send(self(), :report_wifi_status)
          {:ok, assign(socket, :attempt, 0)}
        else
          {:error, reason} ->
            Logger.error("[ChannelClient] handshake_ok rejected: #{inspect(reason)}")
            {:ok, fail_handshake(socket)}
        end
    end
  end

  def handle_message(_topic, "handshake_error", payload, socket) do
    Logger.error("[ChannelClient] server handshake_error: #{inspect(payload)}")
    {:ok, fail_handshake(socket)}
  end

  # The backend uses one strict Base64 carrier for every authenticated control_v1
  # message. Decode the carrier, authenticate/open it in the SessionHolder, then
  # decode the expected typed payload. Every failure is fail-closed and side-effect
  # free; a rekey boundary reconnects instead of leaving outbound control wedged.
  def handle_message(topic, "control_v1", carrier, %{assigns: %{topic: topic}} = socket) do
    case open_control_message(socket, carrier) do
      {:ok, type, attrs} ->
        handle_control_message(topic, type, attrs, socket)

      {:error, :rekey_required} ->
        {:ok, fail_handshake(socket)}

      {:error, _malformed_replayed_or_stale} ->
        {:ok, socket}
    end
  end

  def handle_message(_other_topic, "control_v1", _carrier, socket), do: {:ok, socket}

  # The legacy direct command path is DISABLED for any session that negotiated
  # authenticated durable command mode. Applying it would run an unfenced effect
  # and emit a legacy ACK for a command the ledger never admitted — exactly the
  # bypass the durable ledger exists to prevent. Legacy sessions (no capability
  # offer) keep the original behavior because no durable delivery owns their
  # commands.
  def handle_message(_topic, "command", payload, %{assigns: %{control_selection: selection}} = socket)
      when not is_nil(selection) do
    Logger.warning(
      "[ChannelClient] ignoring legacy command #{inspect(command_id(payload))}; " <>
        "this session negotiated authenticated durable command delivery"
    )

    {:ok, socket}
  end

  # Server pushes a command -> decode + apply + ack (idempotent).
  def handle_message(topic, "command", payload, socket) do
    command_id = command_id(payload)

    case ChannelHandler.handle_command(payload, command_id, socket.assigns.commands) do
      {:ack, ack_payload} ->
        push(socket, topic, "ack", ack_payload)
        {:ok, socket}

      {:noack, reason} ->
        Logger.debug("[ChannelClient] command #{inspect(command_id)} not acked: #{inspect(reason)}")
        {:ok, socket}
    end
  end

  # Server pushes a desired Wi-Fi config -> apply it through the WiFiManager and
  # report the resulting status back. The status NEVER includes the psk; on an
  # apply error we still report the (unchanged) current state so the owner's
  # /account page is not left stale, and we never crash the channel.
  def handle_message(topic, "set_wifi", payload, socket) do
    {result, socket} = apply_wifi(payload, socket)
    status = wifi_status(socket, applied_version(result, payload))
    push(socket, topic, "wifi_status", status)
    {:ok, socket}
  end

  # Server pushes a per-state tracking config (damping + send-rate). Apply it through
  # RacingOrg.Tracker.Pro.Tracking.Config (versioned, idempotent), then report what the device is
  # actually applying back as "tracking_status". On an apply error we still report the
  # current status so the server is not left stale, and we never crash the channel.
  def handle_message(topic, "set_tracking", payload, socket) do
    {_result, socket} = apply_tracking(payload, socket)
    push(socket, topic, "tracking_status", tracking_status(socket))
    {:ok, socket}
  end

  # Server pushes the upstream signal selection (which telemetry sample types the
  # tracker streams — position always streams and is not in the set). Apply it
  # through RacingOrg.Tracker.Pro.Upstream.Config (versioned, idempotent), then
  # report the applied version back as "upstream_status". On an apply error we
  # still report the current status so the server is not left stale, and we never
  # crash the channel.
  def handle_message(topic, "set_upstream", payload, socket) do
    {_result, socket} = apply_upstream(payload, socket)
    push(socket, topic, "upstream_status", upstream_status(socket))
    {:ok, socket}
  end

  # Server pushes the computed-value definitions. Apply them through
  # RacingOrg.Tracker.Pro.Compute.Engine (versioned, idempotent), then report applied_version +
  # active_count back as "computed_values_status". On an apply error we still report
  # the current status so the server is not left stale, and we never crash the channel.
  def handle_message(topic, "set_computed_values", payload, socket) do
    {_result, socket} = apply_computed(payload, socket)
    push(socket, topic, "computed_values_status", computed_values_status(socket))
    {:ok, socket}
  end

  # Server pushes the clock-source policy (which time source drives telemetry
  # timestamps). Apply it through RacingOrg.Tracker.Pro.ClockSource.Config
  # (versioned, idempotent), then report the active timebase back as
  # "clock_source_status". On an apply error we still report the current status so
  # the server is not left stale, and we never crash the channel.
  def handle_message(topic, "set_clock_source", payload, socket) do
    {_result, socket} = apply_clock_source(payload, socket)
    push(socket, topic, "clock_source_status", clock_source_status(socket))
    {:ok, socket}
  end

  # Server pushes the calibration policy (which parameters may auto-apply, plus
  # explicit per-sensor locks). Apply it through
  # RacingOrg.Tracker.Pro.Calibration.Config (versioned, idempotent), then report
  # the learned/locked per-sensor state back as "calibration_status". On an apply
  # error we still report the current status so the server is not left stale, and
  # we never crash the channel.
  def handle_message(topic, "set_calibration", payload, socket) do
    {_result, socket} = apply_calibration(payload, socket)
    push(socket, topic, "calibration_status", calibration_status(socket))
    {:ok, socket}
  end

  # Server pushes the wind-shift policy (predictor windows / envelope alarms /
  # wally mode). Apply it through RacingOrg.Tracker.Pro.WindShift.Config
  # (versioned, idempotent), then report the composed policy+live state back as
  # "wind_shift_status". On an apply error we still report the current status so
  # the server is not left stale, and we never crash the channel.
  def handle_message(topic, "set_wind_shift", payload, socket) do
    {_result, socket} = apply_wind_shift(payload, socket)
    push(socket, topic, "wind_shift_status", wind_shift_status(socket))
    {:ok, socket}
  end

  # Server killed the session (key revoke / device revoke / transfer).
  def handle_message(_topic, "session_evicted", payload, socket) do
    Logger.warning("[ChannelClient] session evicted: #{inspect(payload)}")
    {:stop, :normal, clear_session(socket)}
  end

  def handle_message(_topic, event, _payload, socket) do
    Logger.debug("[ChannelClient] ignoring unhandled event #{inspect(event)}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_reply(ref, reply, socket), do: handle_channel_reply(ref, reply, socket)

  defp handle_channel_reply(ref, reply, %{assigns: %{enrollment_ref: ref}} = socket) when not is_nil(ref) do
    socket = assign(socket, :enrollment_ref, nil)

    case reply do
      {:ok, %{"receipt" => receipt} = response} when is_binary(receipt) and map_size(response) == 1 ->
        complete_legacy_enrollment(response, socket)

      _unsupported_or_invalid ->
        Logger.info("[ChannelClient] authenticated legacy enrollment was not accepted")
        {:ok, socket}
    end
  end

  defp handle_channel_reply(_ref, _reply, socket), do: {:ok, socket}

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("[ChannelClient] disconnected: #{inspect(reason)}")
    {:ok, socket |> clear_session() |> schedule_reconnect()}
  end

  @impl Slipstream
  def handle_topic_close(_topic, reason, socket) do
    Logger.warning("[ChannelClient] topic closed: #{inspect(reason)}")
    {:ok, socket |> clear_session() |> disconnect() |> schedule_reconnect()}
  end

  # Our own jittered-backoff reconnect timer.
  @impl Slipstream
  def handle_info(:reconnect, socket) do
    {:noreply, socket, {:continue, :connect}}
  end

  # Provisioning can complete AFTER boot: BootProvisioner generates the device
  # identity + registers asynchronously, and an admin may associate it later. When we
  # started idle, poll connectable?/1 and connect the moment the device is registered +
  # identity-provisioned + server-pinned, so a fresh device needs no reboot to come
  # online.
  def handle_info(:recheck, socket) do
    if auto_connect?(socket.assigns.opts) do
      Logger.info("[ChannelClient] now provisioned; connecting")
      {:noreply, socket, {:continue, :connect}}
    else
      {:noreply, schedule_recheck(socket)}
    end
  end

  # wlan0's connection changed (VintageNet property notification on target, or a
  # simulated message in tests) -> push a fresh status so the server/account page
  # stays live. We don't know the applied version here, so we omit it (the server
  # allowlist keeps the rest).
  def handle_info({VintageNet, ["interface", "wlan0", "connection"], _old, _new, _meta}, socket) do
    {:noreply, push_wifi_status(socket)}
  end

  # Initial status report after a successful handshake.
  def handle_info(:report_wifi_status, socket) do
    {:noreply, push_wifi_status(socket)}
  end

  # The Phase 8 broadcaster streams live (damped) computed values back for display.
  # Push them as "computed_values_data" ONLY when a secure session is live (joined
  # topic + derived session); otherwise drop the batch (best-effort, like telemetry).
  def handle_info({:send_computed_values_data, values}, socket) do
    {:noreply, push_computed_values_data(socket, values)}
  end

  # The Phase 4 Observer streams a throttled incremental sailed-polar delta.
  # Push it as "sailed_polar_update" ONLY when a secure session is live; otherwise
  # drop it (best-effort, like telemetry — the Observer re-emits on the next sync).
  def handle_info({:send_sailed_polar_update, update}, socket) do
    {:noreply, push_sailed_polar_update(socket, update)}
  end

  def handle_info({:send_calibration_update, update}, socket) do
    {:noreply, push_calibration_update(socket, update)}
  end

  def handle_info({:send_wind_shift_update, update}, socket) do
    {:noreply, push_wind_shift_update(socket, update)}
  end

  # The DeviationMonitor asks for a recalc when the boat deviates past the threshold.
  # Push it as "request_route_recalc" ONLY when a secure session is live; otherwise
  # drop it (best-effort, like telemetry).
  def handle_info({:request_route_recalc, position}, socket) do
    {:noreply, push_request_route_recalc(socket, position)}
  end

  def handle_info({:send_desired_state_ack, ack}, socket) do
    case push_ready_control(socket, :ack, ack) do
      {:ok, socket} -> {:noreply, socket}
      {:reconnect, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_info({:replay_desired_state_acks, generation}, socket) do
    session = socket.assigns.session

    if socket.assigns.control_ready? and match?(%Session{generation: ^generation}, session) do
      _ = invoke_desired_state_replay(socket.assigns.desired_state_replay, generation)
    end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- internal ---

  defp open_control_message(%{assigns: %{session: %Session{generation: generation}}} = socket, carrier)
       when is_integer(generation) do
    with {:ok, frame} <- Control.decode_carrier(carrier),
         {:ok, type, payload} <-
           SessionHolder.open_control(socket.assigns.session_holder, generation, frame),
         {:ok, attrs} <- Messages.decode(type, payload) do
      {:ok, type, attrs}
    end
  rescue
    _exception -> {:error, :control_unavailable}
  catch
    :exit, _reason -> {:error, :control_unavailable}
  end

  defp open_control_message(_socket, _carrier), do: {:error, :stale_session}

  defp handle_control_message(_topic, :control_accept, _attrs, %{assigns: %{control_ready?: true}} = socket),
    do: {:ok, socket}

  defp handle_control_message(topic, :control_accept, attrs, socket) do
    with {:ok, identity} <- invoke_zero_arity(socket.assigns.desired_state_identity),
         :ok <- verify_control_accept(attrs, identity, socket.assigns.control_selection),
         {:ok, readiness} <- readiness_attrs(socket, identity),
         {:ok, socket} <- push_control(socket, topic, :readiness, readiness) do
      generation = socket.assigns.session.generation

      socket =
        socket
        |> assign(:control_topic, topic)
        |> assign(:control_ready?, true)

      send(self(), {:replay_desired_state_acks, generation})
      {:ok, socket}
    else
      {:reconnect, socket} ->
        {:ok, socket}

      # A binding mismatch is a REJECTION: the accept did not describe this device
      # or this negotiation, so staying on the session is correct and no readiness
      # is owed. Nothing is wedged — a legitimate accept can still arrive.
      {:error, reason} when reason in [:control_accept_mismatch, :legacy_negotiation] ->
        Logger.warning("[ChannelClient] control_accept rejected: #{inspect(reason)}")
        {:ok, socket}

      # Anything else means we accepted the frame but could not answer it. The
      # accept's control counter is already consumed, so the server's frame can
      # never be replayed to us and no further accept is coming for this session:
      # swallowing the error would leave the control plane permanently dead with
      # `control_ready?` false. Fail closed and reconnect so a fresh session
      # re-runs negotiation from the top.
      {:error, reason} ->
        Logger.error(
          "[ChannelClient] control readiness unavailable (#{inspect(reason)}); reconnecting " <>
            "rather than leaving the control plane wedged"
        )

        {:ok, fail_handshake(socket)}
    end
  end

  defp handle_control_message(
         _topic,
         type,
         attrs,
         %{assigns: %{control_ready?: true, session: %Session{generation: generation}}} = socket
       )
       when type in [:manifest_delivery, :section_chunk, :secret_delivery] do
    case deliver_desired_state(socket, type, generation, attrs) do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[ChannelClient] desired-state delivery refused: " <>
            inspect(reason)
        )
    end

    {:ok, socket}
  end

  defp handle_control_message(_topic, type, _attrs, socket)
       when type in [:manifest_delivery, :section_chunk, :secret_delivery] do
    Logger.warning("[ChannelClient] desired-state delivery before control readiness; refusing")

    {:ok, socket}
  end

  # An authenticated command delivery is routed to the durable executor, which
  # owns classification, the ledger, and every effect. The executor returns the
  # exact ACK to encode; a deferral (foreign device, unusable clock, capacity, or
  # an ambiguous pending intent) owes nothing and MUST NOT be acked.
  defp handle_control_message(_topic, :command_delivery, attrs, %{assigns: %{control_ready?: true}} = socket) do
    case deliver_command(socket, attrs) do
      {:ack, ack} ->
        case push_ready_control(socket, :command_ack, ack) do
          {:ok, socket} -> {:ok, socket}
          {:reconnect, socket} -> {:ok, socket}
          {:error, socket} -> {:ok, socket}
        end

      {:defer, reason} ->
        Logger.debug("[ChannelClient] command delivery deferred: #{inspect(reason)}")
        {:ok, socket}
    end
  end

  # A delivery that arrives before this session answered control_accept has no
  # negotiated control topic to answer on, so it is refused without an effect.
  defp handle_control_message(_topic, :command_delivery, _attrs, socket) do
    Logger.warning("[ChannelClient] command delivery before control readiness; refusing")
    {:ok, socket}
  end

  defp handle_control_message(_topic, :delivery_receipt, attrs, socket) do
    case acknowledge_delivery(socket, Map.delete(attrs, :receipt_hash)) do
      {:ok, _removed} -> :ok
      {:error, reason} -> Logger.warning("[ChannelClient] durable receipt refused: #{inspect(reason)}")
    end

    {:ok, socket}
  end

  # Checkpoint hydration is a registered, authenticated type whose runtime
  # dispatch remains an explicit seam rather than being folded into the catch-all.
  defp handle_control_message(_topic, :checkpoint_hydration, _attrs, socket) do
    Logger.debug("[ChannelClient] checkpoint hydration received; runtime dispatch not wired in this stage")
    {:ok, socket}
  end

  defp handle_control_message(_topic, type, _attrs, socket) do
    Logger.debug("[ChannelClient] ignoring unhandled control message #{inspect(type)}")
    {:ok, socket}
  end

  defp acknowledge_delivery(socket, receipt) do
    socket.assigns.outbox_module.acknowledge(socket.assigns.outbox, receipt, idempotent: true)
  rescue
    _exception -> {:error, :outbox_owner_unavailable}
  catch
    :exit, _reason -> {:error, :outbox_owner_unavailable}
  end

  defp deliver_desired_state(socket, type, generation, attrs) do
    module = socket.assigns.desired_state_manager_module
    manager = socket.assigns.desired_state_manager

    case type do
      :manifest_delivery -> module.deliver_manifest(manager, generation, attrs)
      :section_chunk -> module.deliver_chunk(manager, generation, attrs)
      :secret_delivery -> module.deliver_secret(manager, generation, attrs)
    end
  rescue
    _exception -> {:error, :desired_state_manager_unavailable}
  catch
    _kind, _reason -> {:error, :desired_state_manager_unavailable}
  end

  defp deliver_command(socket, attrs) do
    module = socket.assigns.command_executor_module

    case module.deliver(socket.assigns.command_executor, attrs) do
      {:ack, ack} when is_map(ack) -> {:ack, ack}
      {:defer, reason} -> {:defer, reason}
      _unexpected -> {:defer, :invalid_command_executor_result}
    end
  rescue
    _exception -> {:defer, :command_executor_unavailable}
  catch
    :exit, _reason -> {:defer, :command_executor_unavailable}
  end

  defp verify_control_accept(_attrs, _identity, nil), do: {:error, :legacy_negotiation}

  defp verify_control_accept(attrs, identity, selection) do
    if attrs.device_id == identity.device_id and
         attrs.credential_epoch == identity.credential_epoch and
         attrs.selected_control_version == selection.selected_control_version and
         attrs.selected_desired_version == selection.selected_desired_version and
         attrs.offer_hash == selection.offer_hash do
      :ok
    else
      {:error, :control_accept_mismatch}
    end
  end

  defp readiness_attrs(socket, identity) do
    with {:ok, compatibility} <- invoke_zero_arity(socket.assigns.desired_state_compatibility),
         {:ok, status} <- invoke_zero_arity(socket.assigns.desired_state_status) do
      selection = socket.assigns.control_selection

      {:ok,
       Map.merge(identity, %{
         selected_control_version: selection.selected_control_version,
         selected_desired_version: selection.selected_desired_version,
         offer_hash: selection.offer_hash,
         firmware_version: compatibility.firmware_version,
         firmware_git_sha: compatibility.firmware_git_sha,
         capabilities: compatibility.capabilities,
         effective: readiness_effective(status)
       })}
    end
  end

  defp readiness_effective(%{active: active}) when is_map(active),
    do: Map.take(active, [:credential_epoch, :generation, :manifest_hash])

  defp readiness_effective(_status), do: nil

  defp push_ready_control(
         %{assigns: %{control_ready?: true, control_topic: topic}} = socket,
         type,
         attrs
       )
       when is_binary(topic),
       do: push_control(socket, topic, type, attrs)

  defp push_ready_control(socket, _type, _attrs), do: {:error, socket}

  # Seal in the holder (the control counter is a real AEAD nonce, so its allocation
  # must stay atomic and single-writer), then transmit from THIS process under the
  # returned lease. The lease keeps replacement/clear from overtaking the sealed
  # frame while the holder stays responsive to every other caller — see
  # `push_if_session_live/3` for why the write must not run inside the holder.
  defp push_control(
         %{assigns: %{session: %Session{generation: generation}}} = socket,
         topic,
         type,
         attrs
       )
       when is_integer(generation) do
    holder = socket.assigns.session_holder

    with {:ok, payload} <- Messages.encode(type, attrs),
         {:ok, frame, lease} <- SessionHolder.seal_control_send(holder, generation, type, payload) do
      try do
        push(socket, topic, "control_v1", Control.encode_carrier(frame))
        {:ok, socket}
      after
        SessionHolder.release_send_lease(holder, lease)
      end
    else
      {:error, :rekey_required} -> {:reconnect, fail_handshake(socket)}
      {:error, _reason} -> {:error, socket}
    end
  rescue
    _exception -> {:error, socket}
  catch
    :exit, _reason -> {:error, socket}
  end

  defp push_control(socket, _topic, _type, _attrs), do: {:error, socket}

  defp invoke_zero_arity(fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, value} -> {:ok, value}
      value when is_map(value) -> {:ok, value}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_desired_state_runtime}
    end
  rescue
    _exception -> {:error, :desired_state_runtime_unavailable}
  catch
    :exit, _reason -> {:error, :desired_state_runtime_unavailable}
  end

  defp invoke_desired_state_replay(fun, generation) when is_function(fun, 1) do
    fun.(generation)
  rescue
    _exception -> {:error, :desired_state_manager_unavailable}
  catch
    :exit, _reason -> {:error, :desired_state_manager_unavailable}
  end

  # Push the current WiFi status (no applied_version known) only while this
  # connection still owns the live secure session. Delayed VintageNet/report
  # callbacks from a replaced or disconnected client are dropped.
  defp push_wifi_status(%{assigns: %{topic: nil}} = socket), do: socket

  defp push_wifi_status(socket) do
    push_if_session_live(socket, "wifi_status", wifi_status(socket, nil))
  end

  # Push a batch of streamed computed values as "computed_values_data". Gated on a
  # LIVE secure session: a joined topic AND a derived session that the SessionHolder
  # confirms is live (i.e. the handshake completed). No `at` field — the server stamps
  # receipt time. With no live session / empty batch this is a no-op (the value is
  # simply dropped, like telemetry with no session).
  defp push_computed_values_data(%{assigns: %{topic: nil}} = socket, _values), do: socket
  defp push_computed_values_data(socket, []), do: socket

  defp push_computed_values_data(socket, values) do
    push_if_session_live(socket, "computed_values_data", %{values: values})
  end

  # Push an incremental "sailed_polar_update". Gated on a LIVE secure session (joined
  # topic + holder-confirmed session), exactly like the streamback. With no live
  # session / no cells this is a no-op (the delta is dropped; the Observer re-emits the
  # unchanged cells on its next throttled sync).
  defp push_sailed_polar_update(%{assigns: %{topic: nil}} = socket, _update), do: socket
  defp push_sailed_polar_update(socket, %{cells: []}), do: socket

  defp push_sailed_polar_update(socket, update) do
    push_if_session_live(socket, "sailed_polar_update", update)
  end

  # Calibration updates follow the sailed-polar rules exactly: no joined topic or
  # an empty batch -> drop; push only over a live secure session.
  defp push_calibration_update(%{assigns: %{topic: nil}} = socket, _update), do: socket
  defp push_calibration_update(socket, %{entries: []}), do: socket

  defp push_calibration_update(socket, update) do
    push_if_session_live(socket, "calibration_update", update)
  end

  # Wind-shift updates follow the calibration rules exactly: no joined topic or a
  # degenerate batch (no session + nothing pending) -> drop; push only over a live
  # secure session. (A summary-only update with empty timeline/events is NOT
  # degenerate — the Observer sends those when the session summary changed.)
  defp push_wind_shift_update(%{assigns: %{topic: nil}} = socket, _update), do: socket
  defp push_wind_shift_update(socket, %{timeline: [], events: [], session: nil}), do: socket

  defp push_wind_shift_update(socket, update) do
    push_if_session_live(socket, "wind_shift_update", update)
  end

  # Push a "request_route_recalc". Gated on a LIVE secure session (joined topic +
  # holder-confirmed session), exactly like the streamback. A `{lat, lon}` position is
  # sent as %{position: %{latitude, longitude}}; nil sends an empty payload (the server
  # resolves the device→race + position from telemetry). No-op with no live session.
  defp push_request_route_recalc(%{assigns: %{topic: nil}} = socket, _position), do: socket

  defp push_request_route_recalc(socket, position) do
    push_if_session_live(socket, "request_route_recalc", recalc_payload(position))
  end

  defp recalc_payload({lat, lon}) when is_number(lat) and is_number(lon),
    do: %{position: %{latitude: lat, longitude: lon}}

  defp recalc_payload(_), do: %{}

  # Emit the final push under a holder SEND LEASE. The lease keeps the original
  # guarantee — replacement/clear cannot overtake a send this connection already
  # authorized — while moving the transport write out of the holder process.
  #
  # It must not run inside a `with_session/3` callback: `Slipstream.push/5` is a
  # synchronous call into the connection process, so executing it in the holder
  # parks the single writer that serializes nonce allocation for every subsystem,
  # and an unanswered or slow channel push stalls `take_send_counter/1`, `clear/1`,
  # and even `live?/1` for unrelated callers. A bare check-then-push would instead
  # leave a TOCTOU window where a replacement lands between authorization and the
  # write. The lease closes both: the holder authorizes and replies immediately,
  # stays responsive to reads, and defers publish/clear until the lease is released
  # (or the leaseholder dies).
  defp push_if_session_live(%{assigns: %{session: nil}} = socket, _event, _payload), do: socket

  defp push_if_session_live(socket, event, payload) do
    session = socket.assigns.session
    holder = socket.assigns.session_holder

    if is_integer(session.generation) do
      case SessionHolder.acquire_send_lease(holder, session.generation) do
        {:ok, lease} ->
          try do
            if lease.session_id == session.session_id do
              push(socket, socket.assigns.topic, event, payload)
            end
          after
            SessionHolder.release_send_lease(holder, lease)
          end

        {:error, _stale_or_missing_session} ->
          :ok
      end
    end

    socket
  rescue
    _ -> socket
  catch
    :exit, _ -> socket
  end

  defp handshake_session_fence(socket, credential_epoch) do
    case SessionHolder.fence_for_credential_epoch(
           socket.assigns.session_holder,
           credential_epoch
         ) do
      {:ok, generation, :current} ->
        {:ok, generation}

      {:ok, generation, :evicted} ->
        _ = bootstrap_call(socket, :session_lost)
        {:ok, generation}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :session_holder_unavailable}
  catch
    :exit, _ -> {:error, :session_holder_unavailable}
  end

  defp publish_session(socket, session) do
    case socket.assigns.session_fence do
      generation when is_integer(generation) and generation >= 0 ->
        SessionHolder.publish(socket.assigns.session_holder, session, generation)

      _missing_fence ->
        {:error, :stale_session}
    end
  rescue
    _ -> {:error, :session_holder_unavailable}
  catch
    :exit, _ -> {:error, :session_holder_unavailable}
  end

  # --- WiFi collaborator (injectable like :commands) ---

  # Normalize the :wifi opt into a {module, server} pair. A bare module is used as
  # both the implementation module and the registered GenServer name.
  defp normalize_wifi({module, server}) when is_atom(module), do: {module, server}
  defp normalize_wifi(module) when is_atom(module), do: {module, module}

  # Same shape for the tracking collaborators (apply target + status source).
  defp normalize_collaborator({module, server}) when is_atom(module), do: {module, server}
  defp normalize_collaborator(module) when is_atom(module), do: {module, module}

  defp apply_wifi(payload, socket) do
    {module, server} = socket.assigns.wifi
    result = module.apply_config(server, payload)
    {result, socket}
  rescue
    error ->
      Logger.warning("[ChannelClient] WiFi apply_config failed: #{inspect(error)}")
      {{:error, :apply_failed}, socket}
  end

  # Build the status map the server's `Devices.record_wifi_status/2` allowlists:
  # enabled/ssid/connection/signal/applied_version. NEVER includes psk. Falls back
  # to a minimal disconnected status if current_status/1 is unavailable.
  defp wifi_status(socket, applied_version) do
    {module, server} = socket.assigns.wifi

    base =
      try do
        module.current_status(server)
      rescue
        error ->
          Logger.warning("[ChannelClient] WiFi current_status failed: #{inspect(error)}")
          %{enabled: false, ssid: nil, connection: :disconnected, signal: nil}
      catch
        :exit, reason ->
          Logger.warning("[ChannelClient] WiFi current_status unavailable: #{inspect(reason)}")
          %{enabled: false, ssid: nil, connection: :disconnected, signal: nil}
      end

    %{
      enabled: Map.get(base, :enabled),
      ssid: Map.get(base, :ssid),
      connection: Map.get(base, :connection),
      signal: Map.get(base, :signal)
    }
    |> maybe_put_applied_version(applied_version)
  end

  defp maybe_put_applied_version(status, nil), do: status
  defp maybe_put_applied_version(status, version), do: Map.put(status, :applied_version, version)

  # --- Tracking config collaborator ---

  defp apply_tracking(payload, socket) do
    {module, server} = socket.assigns.tracking
    result = module.apply_config(server, payload)
    {result, socket}
  rescue
    error ->
      Logger.warning("[ChannelClient] Tracking apply_config failed: #{inspect(error)}")
      {{:error, :apply_failed}, socket}
  end

  # Build the "tracking_status" the server allowlists: applied_version, active_state,
  # active_rate_hz, active_damping_seconds, reported_at (ISO-8601). Reflects what the
  # device is actually applying (from RacingOrg.Tracker.Pro.Sampling). Falls back to a minimal map
  # if the status source is unavailable, and always stamps reported_at.
  defp tracking_status(socket) do
    {module, server} = socket.assigns.tracking_status

    base =
      try do
        module.tracking_status(server)
      rescue
        error ->
          Logger.warning("[ChannelClient] tracking_status read failed: #{inspect(error)}")
          %{}
      end

    %{
      applied_version: Map.get(base, :applied_version),
      active_state: Map.get(base, :active_state),
      active_rate_hz: Map.get(base, :active_rate_hz),
      active_damping_seconds: Map.get(base, :active_damping_seconds),
      reported_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # --- Upstream-selection collaborator ---

  defp apply_upstream(payload, socket) do
    {module, server} = socket.assigns.upstream
    result = module.apply_config(server, payload)
    {result, socket}
  rescue
    error ->
      Logger.warning("[ChannelClient] Upstream apply_config failed: #{inspect(error)}")
      {{:error, :apply_failed}, socket}
  end

  # Build the "upstream_status" the server allowlists: applied_version +
  # reported_at (ISO-8601). Falls back to a minimal map if the status source is
  # unavailable, and always stamps reported_at.
  defp upstream_status(socket) do
    {module, server} = socket.assigns.upstream

    base =
      try do
        module.upstream_status(server)
      rescue
        error ->
          Logger.warning("[ChannelClient] upstream_status read failed: #{inspect(error)}")
          %{}
      end

    %{
      applied_version: Map.get(base, :applied_version),
      reported_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # --- Clock-source collaborator ---

  defp apply_clock_source(payload, socket) do
    {module, server} = socket.assigns.clock_source
    result = module.apply_config(server, payload)
    {result, socket}
  rescue
    error ->
      Logger.warning("[ChannelClient] ClockSource apply_config failed: #{inspect(error)}")
      {{:error, :apply_failed}, socket}
  end

  # Build the "clock_source_status" the server allowlists: applied_version, mode,
  # the active source's identity, the current timebase, fallback_reason,
  # last_gps_time, status, and reported_at (ISO-8601). Falls back to a minimal map
  # if the status source is unavailable, and always stamps reported_at.
  defp clock_source_status(socket) do
    {module, server} = socket.assigns.clock_source

    base =
      try do
        module.status(server)
      rescue
        error ->
          Logger.warning("[ChannelClient] clock_source status read failed: #{inspect(error)}")
          %{}
      end

    %{
      applied_version: Map.get(base, :applied_version),
      mode: Map.get(base, :mode),
      active_source_sensor_id: Map.get(base, :active_source_sensor_id),
      active_source_label: Map.get(base, :active_source_label),
      active_hw_id: Map.get(base, :active_hw_id),
      active_source_address: Map.get(base, :active_source_address),
      timebase: Map.get(base, :timebase),
      fallback_reason: Map.get(base, :fallback_reason),
      last_gps_time: Map.get(base, :last_gps_time),
      status: Map.get(base, :status, "ok"),
      reported_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # --- Calibration collaborator ---

  defp apply_calibration(payload, socket) do
    {module, server} = socket.assigns.calibration
    result = module.apply_config(server, payload)
    {result, socket}
  rescue
    error ->
      Logger.warning("[ChannelClient] Calibration apply_config failed: #{inspect(error)}")
      {{:error, :apply_failed}, socket}
  end

  # Build the "calibration_status" the server allowlists: applied_version, modes
  # (parameter => mode string), sensors (hardware_identifier / parameter / state /
  # value / confidence / sample_count), status, and reported_at (ISO-8601). Falls
  # back to a minimal map if the status source is unavailable, and always stamps
  # reported_at.
  defp calibration_status(socket) do
    {module, server} = socket.assigns.calibration

    base =
      try do
        module.status(server)
      rescue
        error ->
          Logger.warning("[ChannelClient] calibration status read failed: #{inspect(error)}")
          %{}
      end

    %{
      applied_version: Map.get(base, :applied_version),
      modes: Map.get(base, :modes, %{}),
      sensors: Map.get(base, :sensors, []),
      status: Map.get(base, :status, "ok"),
      reported_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # --- Wind-shift collaborators (policy config + live observer) ---

  defp apply_wind_shift(payload, socket) do
    {module, server} = socket.assigns.wind_shift
    result = module.apply_config(server, payload)
    {result, socket}
  rescue
    error ->
      Logger.warning("[ChannelClient] WindShift apply_config failed: #{inspect(error)}")
      {{:error, :apply_failed}, socket}
  end

  # Build the "wind_shift_status" the server allowlists — EXACTLY the 12 contract
  # fields: applied_version + wally_mode from the policy (WindShift.Config.status),
  # the live predictor fields from the Observer (WindShift.Observer.status), plus
  # status and reported_at (ISO-8601). Falls back to minimal maps if either source
  # is unavailable, and always stamps reported_at.
  defp wind_shift_status(socket) do
    config = wind_shift_source_status(socket.assigns.wind_shift, "wind_shift config")
    live = wind_shift_source_status(socket.assigns.wind_shift_observer, "wind_shift observer")

    %{
      applied_version: Map.get(config, :applied_version),
      regime: Map.get(live, :regime),
      confidence: Map.get(live, :confidence),
      oscillation_period_s: Map.get(live, :oscillation_period_s),
      oscillation_amplitude_deg: Map.get(live, :oscillation_amplitude_deg),
      trend_deg_per_hr: Map.get(live, :trend_deg_per_hr),
      wind_phase_deg: Map.get(live, :wind_phase_deg),
      wind_lift_deg: Map.get(live, :wind_lift_deg),
      twd_range_deg: Map.get(live, :twd_range_deg),
      wally_mode: Map.get(config, :wally_mode),
      reported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: Map.get(live, :status, Map.get(config, :status, "ok"))
    }
  end

  defp wind_shift_source_status({module, server}, what) do
    module.status(server)
  rescue
    error ->
      Logger.warning("[ChannelClient] #{what} status read failed: #{inspect(error)}")
      %{}
  catch
    :exit, _ -> %{}
  end

  # --- Computed-values collaborator (Phase 7 compute engine) ---

  defp apply_computed(payload, socket) do
    {module, server} = socket.assigns.compute
    result = module.apply_config(server, payload)
    {result, socket}
  rescue
    error ->
      Logger.warning("[ChannelClient] Compute apply_config failed: #{inspect(error)}")
      {{:error, :apply_failed}, socket}
  end

  # Build the "computed_values_status" the server allowlists: applied_version +
  # active_count (number of currently-valid computed values) + broadcasting (whether
  # the Phase 8 N2K broadcaster is actively emitting at least one value) + reported_at
  # (ISO-8601). The live streamback of values themselves is a separate event
  # ("computed_values_data", see send_computed_values_data/2). Falls back gracefully if
  # a collaborator is unavailable, and always stamps reported_at.
  defp computed_values_status(socket) do
    {module, server} = socket.assigns.compute

    base =
      try do
        module.status(server)
      rescue
        error ->
          Logger.warning("[ChannelClient] computed_values status read failed: #{inspect(error)}")
          %{}
      end

    %{
      applied_version: Map.get(base, :applied_version),
      active_count: Map.get(base, :active_count, 0),
      broadcasting: broadcasting?(socket),
      reported_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # Whether the Compute.Broadcaster is actively broadcasting at least one computed
  # value onto the N2K bus. Defaults to false if the broadcaster is unavailable.
  defp broadcasting?(socket) do
    {module, server} = socket.assigns.compute_broadcaster
    module.broadcasting?(server)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Report a version only when the Wi-Fi owner established durable authority for
  # it. A successful apply returns that exact version; `:unchanged` means the
  # requested version was already covered by durable authority. Errors, especially
  # an indeterminate marker write, must never echo the uncommitted request version.
  defp applied_version({:ok, %{version: version}}, _payload), do: version
  defp applied_version({:ok, :unchanged}, payload), do: payload_version(payload)
  defp applied_version(_result, _payload), do: nil

  defp payload_version(%{"version" => v}), do: v
  defp payload_version(%{version: v}), do: v
  defp payload_version(_), do: nil

  # Subscribe to wlan0 connection changes on a real target (VintageNet is
  # target-only); skip entirely in test_mode / on host so we never call VintageNet
  # where it does not exist.
  defp maybe_subscribe_wlan0(opts) do
    if subscribe_wlan0?(opts) do
      vintage_net = Module.concat(["VintageNet"])

      if Code.ensure_loaded?(vintage_net) and function_exported?(vintage_net, :subscribe, 1) do
        vintage_net.subscribe(["interface", "wlan0", "connection"])
      end
    end

    :ok
  end

  # Default to the target gate; tests pass test_mode?: true and host has no
  # VintageNet, so subscription is skipped there regardless.
  defp subscribe_wlan0?(opts) do
    not Keyword.get(opts, :test_mode?, false) and device_target?()
  end

  defp report_authenticated(socket) do
    case bootstrap_call(socket, :authenticated) do
      {:ok, _state} -> socket
      {:error, :invalid_transition} -> start_legacy_enrollment(socket)
      _unavailable_or_failed -> socket
    end
  end

  defp start_legacy_enrollment(socket) do
    case bootstrap_call(socket, :legacy_enrollment_request) do
      {:ok, %{body: body}} when is_map(body) ->
        case push(socket, socket.assigns.topic, "enroll_hardware_identity", body) do
          {:ok, ref} -> assign(socket, :enrollment_ref, ref)
          {:error, _reason} -> socket
        end

      _not_a_legacy_migration ->
        socket
    end
  end

  defp complete_legacy_enrollment(response, socket) do
    case bootstrap_call(socket, :accept_legacy_enrollment, [response]) do
      {:ok, _registered_state} ->
        case bootstrap_call(socket, :authenticated) do
          {:ok, _authenticated_state} ->
            Logger.info("[ChannelClient] authenticated legacy enrollment completed")

          _failed ->
            Logger.warning("[ChannelClient] legacy enrollment persisted but readiness update failed")
        end

      _invalid_receipt_or_state ->
        Logger.warning("[ChannelClient] authenticated legacy enrollment receipt was rejected")
    end

    {:ok, socket}
  end

  defp bootstrap_call(socket, callback, args \\ []) do
    {module, server} = socket.assigns.boot_provisioner
    apply(module, callback, args ++ [server])
  rescue
    _exception -> {:error, :bootstrap_unavailable}
  catch
    :exit, _reason -> {:error, :bootstrap_unavailable}
  end

  # A handshake failure (bad signature, mismatch, server error) is NOT a clean
  # session: clear the holder and reconnect on backoff (which re-runs the
  # handshake fresh). We disconnect the socket so a full reconnect happens.
  defp fail_handshake(socket) do
    socket
    |> clear_session()
    |> disconnect()
    |> schedule_reconnect()
  end

  defp clear_session(socket) do
    case socket.assigns.owned_session_generation do
      generation when is_integer(generation) ->
        case clear_owned_session(socket, generation) do
          :ok -> _ = bootstrap_call(socket, :session_lost)
          {:error, :stale_session} -> :ok
          {:error, :session_holder_unavailable} -> _ = bootstrap_call(socket, :session_lost)
        end

      nil ->
        :ok
    end

    socket
    |> assign(:session, nil)
    |> assign(:session_fence, nil)
    |> assign(:owned_session_generation, nil)
    |> assign(:enrollment_ref, nil)
    |> assign(:control_topic, nil)
    |> assign(:control_ready?, false)
  end

  defp clear_owned_session(socket, generation) do
    SessionHolder.clear(socket.assigns.session_holder, generation)
  rescue
    _ -> {:error, :session_holder_unavailable}
  catch
    :exit, _ -> {:error, :session_holder_unavailable}
  end

  defp schedule_reconnect(socket) do
    attempt = socket.assigns.attempt
    delay = Backoff.delay(attempt, socket.assigns.backoff_opts)
    Logger.info("[ChannelClient] reconnect ##{attempt + 1} in #{delay}ms")
    Process.send_after(self(), :reconnect, delay)
    assign(socket, :attempt, attempt + 1)
  end

  # Fixed-interval poll used only while idle-waiting for provisioning to complete
  # (distinct from the jittered reconnect backoff above). Configurable for tests.
  defp schedule_recheck(socket) do
    ms = Keyword.get(socket.assigns.opts, :recheck_ms, 15_000)
    Process.send_after(self(), :recheck, ms)
    socket
  end

  defp command_id(payload) do
    case payload do
      %{"command_id" => id} -> id
      _ -> nil
    end
  end

  # --- connect option construction ---

  defp connect_opts(opts, control_offer) do
    with {:ok, fingerprint} <- fingerprint(opts),
         {:ok, uri} <- ws_uri(opts, fingerprint, control_offer) do
      base = [
        uri: uri,
        mint_opts: mint_opts(uri),
        reconnect_after_msec: [5_000]
      ]

      # Threaded through so Slipstream.SocketTest can drive the socket layer
      # without a real server (default false in production).
      connect = Keyword.put(base, :test_mode?, Keyword.get(opts, :test_mode?, false))

      {:ok, connect, "device:" <> fingerprint}
    end
  end

  # Append the routing fingerprint and complete control capability offer to the
  # /device_socket websocket URL. Explicit legacy mode intentionally omits both
  # capability parameters while retaining the existing fingerprint behavior.
  defp ws_uri(opts, fingerprint, control_offer) do
    case base_ws_url(opts) do
      {:ok, base} ->
        uri = URI.parse(base)

        params =
          uri.query
          |> decode_query()
          |> Map.put("fingerprint", fingerprint)
          |> Map.merge(control_offer_params(control_offer))

        {:ok, %{uri | query: URI.encode_query(params)} |> URI.to_string()}

      {:error, _} = err ->
        err
    end
  end

  defp control_negotiation!(opts) do
    case Keyword.get(opts, :control_offer, @control_offer) do
      :legacy ->
        {:legacy, nil}

      offer when is_map(offer) ->
        {:ok, selection} = Negotiation.select(offer)
        {offer, selection}
    end
  end

  defp control_offer_params(:legacy), do: %{}

  defp control_offer_params(offer) do
    %{
      "control_versions" => Enum.join(offer.control_versions, ","),
      "desired_state_versions" => Enum.join(offer.desired_state_versions, ",")
    }
  end

  defp decode_query(nil), do: %{}
  defp decode_query(query), do: URI.decode_query(query)

  # URL precedence: explicit :url opt, then SECURE_TRANSPORT_WS_URL env, then
  # derived from the configured HTTP :api_endpoint (http->ws, https->wss) with the
  # /device_socket/websocket path.
  defp base_ws_url(opts) do
    cond do
      url = Keyword.get(opts, :url) -> {:ok, url}
      url = System.get_env("SECURE_TRANSPORT_WS_URL") -> {:ok, url}
      true -> derive_from_api_endpoint()
    end
  end

  defp derive_from_api_endpoint do
    case Application.get_env(:racing_org_tracker_pro, :api_endpoint) do
      endpoint when is_binary(endpoint) and endpoint != "" ->
        uri = URI.parse(endpoint)
        scheme = if uri.scheme in ["https", "wss"], do: "wss", else: "ws"
        path = @device_socket_path <> "/websocket"
        {:ok, %URI{scheme: scheme, host: uri.host, port: uri.port, path: path} |> URI.to_string()}

      _ ->
        {:error, :no_api_endpoint}
    end
  end

  # Mirror NervesHubLink: http1 only; for wss, TLS with verify_peer against the
  # castore CA bundle (the device already depends on castore).
  defp mint_opts(uri) do
    if String.starts_with?(uri, "wss") do
      [
        protocols: [:http1],
        transport_opts: [
          verify: :verify_peer,
          cacertfile: castore_path(),
          versions: [:"tlsv1.2", :"tlsv1.3"]
        ]
      ]
    else
      [protocols: [:http1]]
    end
  end

  # CAStore is a target-only dep (it is not present on host/test); resolve it at
  # runtime so the host build compiles cleanly without a missing-module warning.
  defp castore_path do
    castore = Module.concat(["CAStore"])

    if Code.ensure_loaded?(castore) and function_exported?(castore, :file_path, 0) do
      castore.file_path()
    else
      :undefined
    end
  end

  defp handshake_inputs(socket) do
    opts = socket.assigns.opts
    {:ok, identity} = KeyStore.load(keystore_opts(opts))
    server_pub = ServerIdentity.public_key()

    inputs = %{
      device_identity: identity,
      server_identity_public: server_pub,
      # The server does not validate device_id; it binds whatever we send into the
      # transcript. We send the active identity fingerprint (the routing id) — the
      # same identifier used at connect + as the topic.
      device_id: IdentityProvider.fingerprint(identity)
    }

    case bootstrap_call(socket, :credential_epoch) do
      {:ok, credential_epoch} -> Map.put(inputs, :credential_epoch, credential_epoch)
      _legacy_or_unavailable -> inputs
    end
  end

  defp persist_handshake_epoch(socket, credential_epoch) do
    case bootstrap_call(socket, :adopt_credential_epoch, [credential_epoch]) do
      {:ok, %BootstrapState{}} -> :ok
      {:error, reason} when credential_epoch == 0 and reason in [:no_verified_authority, :bootstrap_unavailable] -> :ok
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :bootstrap_unavailable}
    end
  end

  defp fingerprint(opts) do
    case KeyStore.load(keystore_opts(opts)) do
      {:ok, identity} -> {:ok, IdentityProvider.fingerprint(identity)}
      {:error, _} = err -> err
    end
  end

  # --- gating helpers ---

  defp auto_connect?(opts), do: Keyword.get_lazy(opts, :auto_connect?, fn -> connectable?(opts) end)

  defp device_target? do
    case Application.get_env(:racing_org_tracker_pro, :target) do
      nil -> false
      :host -> false
      :"" -> false
      _ -> true
    end
  end

  defp registered?(opts), do: BootProvisioner.registered?(bootstrap_opts(opts))

  defp has_identity?(opts) do
    match?({:ok, _}, KeyStore.load(keystore_opts(opts)))
  end

  defp bootstrap_opts(opts) do
    Keyword.get_lazy(opts, :bootstrap_opts, fn ->
      [keystore_opts: keystore_opts(opts)]
    end)
  end

  defp keystore_opts(opts), do: Keyword.get(opts, :keystore_opts, [])
end
