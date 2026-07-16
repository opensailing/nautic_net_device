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

  On a `"command"` push the client decodes the `ServerReply` protobuf and applies
  it through `RacingOrg.Tracker.Pro.Commands` (the existing, idempotent command handler), then
  pushes the `"ack"` event the server expects. Duplicate commands are de-duped by
  `RacingOrg.Tracker.Pro.Commands` and still acked (idempotent).

  ## Eviction / reconnect

  `"session_evicted"` (or `"handshake_error"`, or any disconnect) clears the
  session holder and schedules a reconnect on a JITTERED exponential backoff
  (`RacingOrg.Tracker.Pro.SecureTransport.Backoff`) — never a hot loop. A fresh handshake runs
  on every reconnect.

  ## Gating (job-6 wires this into the supervision tree)

  `start_link/1` always succeeds and the process is safe to run "not configured":
  if the device is not on a real target, is unregistered, has no identity, or has no
  pinned server key, the client stays IDLE (it never attempts to connect and never
  crash-loops). It only connects when `connectable?/1` is true. The child spec is
  exposed but NOT added to `application.ex` here.
  """

  use Slipstream

  require Logger

  alias RacingOrg.Tracker.Pro.SecureTransport.Backoff
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelHandler
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder

  @device_socket_path "/device_socket"
  @handshake_epoch 0

  # --- Public API / child spec ---

  @doc """
  Start the channel client. Always returns `{:ok, pid}` (or a standard GenServer
  start result); the process self-gates and stays idle when not configured.

  Options (all optional; sensible production defaults):

    * `:name` — registered name (default `__MODULE__`).
    * `:commands` — the `RacingOrg.Tracker.Pro.Commands` server (default `RacingOrg.Tracker.Pro.Commands`).
    * `:session_holder` — the `SessionHolder` server (default `SessionHolder`).
    * `:wifi` — the WiFi collaborator that applies config + reports status. Either a
      module (used as both module and GenServer name, default `RacingOrg.Tracker.Pro.WiFiManager`)
      or a `{module, server}` tuple so tests can inject a fake module + pid.
    * `:url` — full `wss://host/device_socket` URL override (else derived from
      `SECURE_TRANSPORT_WS_URL`, then the configured `:api_endpoint` host).
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
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
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
  state:, residual:}` (stw_scale entries additionally carry the full `curve`).
  `seq` is a per-device advisory sequence; the server merges idempotently per
  (sensor, parameter), so a reboot-reset seq is harmless.

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
    state = %{
      opts: opts,
      commands: Keyword.get(opts, :commands, RacingOrg.Tracker.Pro.Commands),
      session_holder: Keyword.get(opts, :session_holder, SessionHolder),
      wifi: normalize_wifi(Keyword.get(opts, :wifi, RacingOrg.Tracker.Pro.WiFiManager)),
      # The per-state tracking config (damping + send-rate). `tracking` applies the
      # server-pushed config (default RacingOrg.Tracker.Pro.Tracking.Config); `tracking_status`
      # reports what is actually being applied (default RacingOrg.Tracker.Pro.Sampling). Both
      # are {module, server} pairs (a bare module is used as both module + name).
      tracking: normalize_collaborator(Keyword.get(opts, :tracking, RacingOrg.Tracker.Pro.Tracking.Config)),
      tracking_status: normalize_collaborator(Keyword.get(opts, :tracking_status, RacingOrg.Tracker.Pro.Sampling)),
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
      attempt: 0,
      session: nil,
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
    case connect_opts(socket.assigns.opts) do
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
    case ChannelHandler.handshake_init(payload, handshake_inputs(socket.assigns.opts)) do
      {:ok, init_payload, session} ->
        socket = assign(socket, :session, session)
        push(socket, socket.assigns.topic, "handshake_init", init_payload)
        {:ok, socket}

      {:error, reason} ->
        Logger.error("[ChannelClient] handshake_init failed: #{inspect(reason)}")
        {:ok, fail_handshake(socket)}
    end
  end

  # Server confirms with "handshake_ok" -> verify, publish the live session.
  def handle_message(_topic, "handshake_ok", payload, socket) do
    case socket.assigns.session do
      nil ->
        Logger.error("[ChannelClient] handshake_ok before a derived session")
        {:ok, fail_handshake(socket)}

      session ->
        case ChannelHandler.verify_handshake_ok(payload, session) do
          :ok ->
            :ok = SessionHolder.put(socket.assigns.session_holder, session)
            Logger.info("[ChannelClient] secure session established")
            # The device has connected to RacingOrg correctly -> mark the running
            # firmware VALID (idempotent, best-effort). A bad OTA that never reaches
            # this point stays unvalidated and auto-reverts on the next reboot.
            _ = socket.assigns.firmware_validator.()
            # Report current WiFi status once the session is live so the server
            # reflects the device's actual state on (re)connect.
            send(self(), :report_wifi_status)
            {:ok, assign(socket, :attempt, 0)}

          {:error, reason} ->
            Logger.error("[ChannelClient] handshake_ok mismatch: #{inspect(reason)}")
            {:ok, fail_handshake(socket)}
        end
    end
  end

  def handle_message(_topic, "handshake_error", payload, socket) do
    Logger.error("[ChannelClient] server handshake_error: #{inspect(payload)}")
    {:ok, fail_handshake(socket)}
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

  # Server killed the session (key revoke / device revoke / transfer).
  def handle_message(_topic, "session_evicted", payload, socket) do
    Logger.warning("[ChannelClient] session evicted: #{inspect(payload)}")
    clear_session(socket)
    {:stop, :normal, socket}
  end

  def handle_message(_topic, event, _payload, socket) do
    Logger.debug("[ChannelClient] ignoring unhandled event #{inspect(event)}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("[ChannelClient] disconnected: #{inspect(reason)}")
    clear_session(socket)
    {:ok, schedule_reconnect(socket)}
  end

  @impl Slipstream
  def handle_topic_close(_topic, reason, socket) do
    Logger.warning("[ChannelClient] topic closed: #{inspect(reason)}")
    clear_session(socket)
    {:ok, schedule_reconnect(disconnect(socket))}
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

  # The DeviationMonitor asks for a recalc when the boat deviates past the threshold.
  # Push it as "request_route_recalc" ONLY when a secure session is live; otherwise
  # drop it (best-effort, like telemetry).
  def handle_info({:request_route_recalc, position}, socket) do
    {:noreply, push_request_route_recalc(socket, position)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- internal ---

  # Push the current WiFi status (no applied_version known) to the server. A no-op
  # when there is no joined topic yet (e.g. a change before the channel is up).
  defp push_wifi_status(%{assigns: %{topic: nil}} = socket), do: socket

  defp push_wifi_status(socket) do
    status = wifi_status(socket, nil)
    push(socket, socket.assigns.topic, "wifi_status", status)
    socket
  end

  # Push a batch of streamed computed values as "computed_values_data". Gated on a
  # LIVE secure session: a joined topic AND a derived session that the SessionHolder
  # confirms is live (i.e. the handshake completed). No `at` field — the server stamps
  # receipt time. With no live session / empty batch this is a no-op (the value is
  # simply dropped, like telemetry with no session).
  defp push_computed_values_data(%{assigns: %{topic: nil}} = socket, _values), do: socket
  defp push_computed_values_data(socket, []), do: socket

  defp push_computed_values_data(socket, values) do
    if session_live?(socket) do
      push(socket, socket.assigns.topic, "computed_values_data", %{values: values})
    end

    socket
  end

  # Push an incremental "sailed_polar_update". Gated on a LIVE secure session (joined
  # topic + holder-confirmed session), exactly like the streamback. With no live
  # session / no cells this is a no-op (the delta is dropped; the Observer re-emits the
  # unchanged cells on its next throttled sync).
  defp push_sailed_polar_update(%{assigns: %{topic: nil}} = socket, _update), do: socket
  defp push_sailed_polar_update(socket, %{cells: []}), do: socket

  defp push_sailed_polar_update(socket, update) do
    if session_live?(socket) do
      push(socket, socket.assigns.topic, "sailed_polar_update", update)
    end

    socket
  end

  # Calibration updates follow the sailed-polar rules exactly: no joined topic or
  # an empty batch -> drop; push only over a live secure session.
  defp push_calibration_update(%{assigns: %{topic: nil}} = socket, _update), do: socket
  defp push_calibration_update(socket, %{entries: []}), do: socket

  defp push_calibration_update(socket, update) do
    if session_live?(socket) do
      push(socket, socket.assigns.topic, "calibration_update", update)
    end

    socket
  end

  # Push a "request_route_recalc". Gated on a LIVE secure session (joined topic +
  # holder-confirmed session), exactly like the streamback. A `{lat, lon}` position is
  # sent as %{position: %{latitude, longitude}}; nil sends an empty payload (the server
  # resolves the device→race + position from telemetry). No-op with no live session.
  defp push_request_route_recalc(%{assigns: %{topic: nil}} = socket, _position), do: socket

  defp push_request_route_recalc(socket, position) do
    if session_live?(socket) do
      push(socket, socket.assigns.topic, "request_route_recalc", recalc_payload(position))
    end

    socket
  end

  defp recalc_payload({lat, lon}) when is_number(lat) and is_number(lon),
    do: %{position: %{latitude: lat, longitude: lon}}

  defp recalc_payload(_), do: %{}

  # The session is live once the handshake has completed and published it to the
  # holder (and not since been evicted/disconnected). Defaults to false if the holder
  # is unavailable, so streamback is never sent over a half-open channel.
  defp session_live?(%{assigns: %{session: nil}}), do: false

  defp session_live?(socket) do
    SessionHolder.live?(socket.assigns.session_holder)
  rescue
    _ -> false
  catch
    :exit, _ -> false
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

  # The version that was just applied: prefer the version from the apply result,
  # else echo the payload's version. On error/unchanged we still echo the payload
  # version so the server records which config the device acknowledged.
  defp applied_version({:ok, %{version: version}}, _payload), do: version
  defp applied_version(_result, payload), do: payload_version(payload)

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

  # A handshake failure (bad signature, mismatch, server error) is NOT a clean
  # session: clear the holder and reconnect on backoff (which re-runs the
  # handshake fresh). We disconnect the socket so a full reconnect happens.
  defp fail_handshake(socket) do
    clear_session(socket)
    schedule_reconnect(disconnect(socket))
  end

  defp clear_session(socket) do
    _ = SessionHolder.clear(socket.assigns.session_holder)
    assign(socket, :session, nil)
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

  defp connect_opts(opts) do
    with {:ok, fingerprint} <- fingerprint(opts),
         {:ok, uri} <- ws_uri(opts, fingerprint) do
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

  # Append the fingerprint connect param to the /device_socket websocket URL.
  defp ws_uri(opts, fingerprint) do
    case base_ws_url(opts) do
      {:ok, base} ->
        uri = URI.parse(base)
        query = URI.encode_query(%{"fingerprint" => fingerprint})
        {:ok, %{uri | query: query} |> URI.to_string()}

      {:error, _} = err ->
        err
    end
  end

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
    case Application.get_env(:racing_org_tracker, :api_endpoint) do
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

  defp handshake_inputs(opts) do
    {:ok, identity} = KeyStore.load(keystore_opts(opts))
    server_pub = ServerIdentity.public_key()

    %{
      device_identity_private: identity.private_key,
      device_identity_public: identity.public_key,
      server_identity_public: server_pub,
      # The server does not validate device_id; it binds whatever we send into the
      # transcript. We send the fingerprint (the routing id) — deterministic, the
      # same id used at connect + as the topic.
      device_id: identity.fingerprint,
      epoch: @handshake_epoch
    }
  end

  defp fingerprint(opts) do
    case KeyStore.load(keystore_opts(opts)) do
      {:ok, %{fingerprint: fp}} -> {:ok, fp}
      {:error, _} = err -> err
    end
  end

  # --- gating helpers ---

  defp auto_connect?(opts), do: Keyword.get_lazy(opts, :auto_connect?, fn -> connectable?(opts) end)

  defp device_target? do
    case Application.get_env(:racing_org_tracker, :target) do
      nil -> false
      :host -> false
      :"" -> false
      _ -> true
    end
  end

  defp registered?(opts) do
    RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner.registered?(keystore_opts(opts))
  end

  defp has_identity?(opts) do
    match?({:ok, _}, KeyStore.load(keystore_opts(opts)))
  end

  defp keystore_opts(opts), do: Keyword.get(opts, :keystore_opts, [])
end
