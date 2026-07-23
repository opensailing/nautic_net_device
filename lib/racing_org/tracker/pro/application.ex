defmodule RacingOrg.Tracker.Pro.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @max_unfragmented_udp_payload_size {508, :bytes}

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: RacingOrg.Tracker.Pro.Supervisor]

    children = children(product(), target())

    with {:ok, sup} <- Supervisor.start_link(children, opts) do
      {:ok, vd_pid} = start_virtual_device_and_handlers(sup)
      start_discovery(sup, vd_pid)
      maybe_replay_log()
      {:ok, sup}
    end
  end

  defp start_virtual_device_and_handlers(sup) do
    {:ok, emit_telemetry_pid} =
      Supervisor.start_child(sup, {RacingOrg.Tracker.Pro.PacketHandler.EmitTelemetry, emit_telemetry_config()})

    {:ok, system_time_pid} = Supervisor.start_child(sup, RacingOrg.Tracker.Pro.PacketHandler.SetTimeFromGPS)
    {:ok, pid} = on_start = Supervisor.start_child(sup, {NMEA.NMEA2000.VirtualDevice, virtual_device_config()})

    # Expose the VirtualDevice so RacingOrg.Tracker.Pro.Nav.Broadcaster can transmit nav PGNs.
    RacingOrg.Tracker.Pro.put_virtual_device(pid)

    # Handlers must be a list of pids which define a
    # def handle_info({:data, data})
    # See NMEA.NMEA2000.VirtualDevice.AddressManager for an example
    # The clock-source manager also observes decoded time messages to maintain the
    # boat-time timebase, and the calibration Observer consumes RAW per-sensor
    # data to fit instrument corrections (nil on products where they aren't started).
    clock_source_pid = Process.whereis(RacingOrg.Tracker.Pro.ClockSource.Config)
    calibration_observer_pid = Process.whereis(RacingOrg.Tracker.Pro.Calibration.Observer)

    handlers =
      Enum.reject(
        [emit_telemetry_pid, system_time_pid, clock_source_pid, calibration_observer_pid],
        &is_nil/1
      )

    # Register the handlers with the virtual device
    for handler <- handlers do
      NMEA.NMEA2000.VirtualDevice.register_handler(pid, handler)
    end

    on_start
  end

  defp start_discovery(supervisor, virtual_device_pid) do
    {:ok, _discovery_pid} =
      Supervisor.start_child(supervisor, {RacingOrg.Tracker.Pro.Discovery, %{virtual_device_pid: virtual_device_pid}})
  end

  # Product: NMEA 2000 standalone, on-board device
  defp children(:logger, target) do
    [
      commands_child(),
      # Upstream signal selection BEFORE Telemetry: Telemetry's report path reads
      # the published selection per sample (fail-open all-on until this boots).
      upstream_config_child(),
      RacingOrg.Tracker.Pro.Telemetry,
      tracking_config_child(),
      clock_source_config_child(),
      calibration_config_child(),
      wind_shift_config_child(),
      calibration_observer_child(),
      compute_engine_child(),
      polar_observer_child(),
      wind_shift_observer_child(),
      {RacingOrg.Tracker.Pro.Sampling, name: RacingOrg.Tracker.Pro.Sampling},
      archive_child(),
      {RacingOrg.Tracker.Pro.Nav.Broadcaster, name: RacingOrg.Tracker.Pro.Nav.Broadcaster},
      {RacingOrg.Tracker.Pro.Nav.DeviationMonitor, name: RacingOrg.Tracker.Pro.Nav.DeviationMonitor},
      {RacingOrg.Tracker.Pro.Compute.Broadcaster, name: RacingOrg.Tracker.Pro.Compute.Broadcaster},
      race_timer_broadcaster_child(),
      waypoint_broadcaster_child(),
      {RacingOrg.Tracker.Pro.Serial, serial_config()},
      # SessionHolder BEFORE the UDP send path + ChannelClient: the UDP path reads
      # the live session from the holder, and the ChannelClient publishes into it.
      RacingOrg.Tracker.Pro.SecureTransport.SessionHolder,
      {RacingOrg.Tracker.Pro.WebClients.UDPClient, udp_config()},
      {RacingOrg.Tracker.Pro.DataSetRecorder, chunk_every: @max_unfragmented_udp_payload_size},
      {RacingOrg.Tracker.Pro.DataSetUploader, via: :udp}
    ] ++ wifi_manager_children(target) ++ secure_transport_children(target)
  end

  # Product: Base station receiver node for racing_org_tracker_mini
  defp children(:uplink, target) do
    [
      commands_child(),
      RacingOrg.Tracker.Pro.SecureTransport.SessionHolder,
      {RacingOrg.Tracker.Pro.WebClients.UDPClient, udp_config()},
      {RacingOrg.Tracker.Pro.DataSetRecorder, chunk_every: @max_unfragmented_udp_payload_size},
      {RacingOrg.Tracker.Pro.DataSetUploader, via: :udp},
      RacingOrg.Tracker.Pro.BaseStation
    ] ++ wifi_manager_children(target) ++ secure_transport_children(target)
  end

  # Wi-Fi: on a real device target, `RacingOrg.Tracker.Pro.WiFiManager` OWNS wlan0 at runtime.
  # It is ALWAYS started on a real target and decides everything internally: on boot
  # it reconciles the DESIRED state persisted to /data (which survives reboots and
  # takes precedence) against the compile-time `:wifi_enabled` default baked into
  # config/target.exs, which it receives here. With no persisted state and
  # `:wifi_enabled` false, it reproduces the old WiFiPower behaviour (radio off for
  # battery save). It reuses `RacingOrg.Tracker.Pro.WiFiPower` for the rfkill block/unblock and
  # link-down helpers. Never started on host/test (`real_target?` gate).
  defp wifi_manager_children(target) do
    if real_target?(target) do
      [{RacingOrg.Tracker.Pro.WiFiManager, compile_default: wifi_enabled?()}]
    else
      []
    end
  end

  defp wifi_enabled?, do: Application.get_env(:racing_org_tracker_pro, :wifi_enabled, true) == true

  # P9-job-6 secure-transport children, appended after the network/HTTP deps they
  # rely on. The SessionHolder is started inline above (it runs in EVERY environment:
  # the UDP send path + tests read it, and it is idle/cheap with no session). These
  # extra children are gated together by `secure_transport_configured?/1` — a real
  # device target AND the pinned server public key being configured (there is no
  # separate enable flag; the pinned key IS the enable):
  #
  #   * BootProvisioner — one-shot boot self-registration. It generates the device
  #     identity and tokenlessly registers it with the server, which (once an admin
  #     associates it) makes the ChannelClient connectable.
  #   * ChannelClient — outbound WSS command channel. It additionally SELF-GATES in
  #     init (idle unless claimed + identity provisioned + server pinned), so it is
  #     safe even if started before provisioning.
  #   * BulkUploader — thin GenServer giving `upload_async/2` a named server for the
  #     Archive's post-race trigger. Cheap + idle.
  #
  # Each child also self-gates at runtime, so this is belt-and-suspenders. On
  # host/test (`real_target?` false) they never start.
  #
  # Ordering: BootProvisioner (registers) → ChannelClient (connects/handshakes) →
  # BulkUploader, all AFTER SessionHolder.
  defp secure_transport_children(target) do
    if secure_transport_configured?(target) do
      [
        RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner,
        RacingOrg.Tracker.Pro.SecureTransport.ChannelClient,
        RacingOrg.Tracker.Pro.Race.BulkUploader
      ]
    else
      []
    end
  end

  @doc """
  Whether the secure-transport children should start: a real device target AND the
  pinned server public key is configured (`ServerIdentity.configured?`). There is no
  separate enable flag — the pinned key is the single enable. Host/test
  (`real_target?` false) and un-pinned firmware return `false`.
  """
  @spec secure_transport_configured?(atom()) :: boolean()
  def secure_transport_configured?(target) do
    real_target?(target) and RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity.configured?()
  end

  defp real_target?(:host), do: false
  defp real_target?(:""), do: false
  defp real_target?(nil), do: false
  defp real_target?(_target), do: true

  # Receives, validates, and de-duplicates RacingOrg server commands arriving on
  # the device-initiated UDP socket.
  defp commands_child do
    {RacingOrg.Tracker.Pro.Commands,
     name: RacingOrg.Tracker.Pro.Commands,
     device_id: RacingOrg.Tracker.Pro.boat_identifier(),
     store_dir: Application.get_env(:racing_org_tracker_pro, :assignment_directory),
     polar_dir: Application.get_env(:racing_org_tracker_pro, :polar_directory)}
  end

  # Per-tracking-state damping + send-rate config pushed by the server over the WSS
  # channel ("set_tracking"). It persists the config to /data (survives reboots) and,
  # on apply, re-drives RacingOrg.Tracker.Pro.Sampling (which sets the Reporter flush interval +
  # EWMA damping for the active state). Started in EVERY environment so Sampling can
  # read it; cheap + idle with no config (Sampling falls back to safe defaults). Must
  # start BEFORE Sampling.
  # Upstream signal selection pushed by the server over the WSS channel
  # ("set_upstream"): WHICH telemetry sample types the tracker streams (position
  # always streams). Persists to /data (survives reboots) and publishes the
  # disabled-signal set to :persistent_term for Telemetry's per-sample read.
  # Started in EVERY environment; cheap + idle with no config (everything streams
  # until the server pushes a selection). Must start BEFORE Telemetry.
  defp upstream_config_child do
    {RacingOrg.Tracker.Pro.Upstream.Config,
     name: RacingOrg.Tracker.Pro.Upstream.Config,
     store_dir: Application.get_env(:racing_org_tracker_pro, :upstream_directory)}
  end

  defp tracking_config_child do
    {RacingOrg.Tracker.Pro.Tracking.Config,
     name: RacingOrg.Tracker.Pro.Tracking.Config,
     store_dir: Application.get_env(:racing_org_tracker_pro, :tracking_directory),
     on_apply: fn _config ->
       try do
         RacingOrg.Tracker.Pro.Sampling.reconfigure(RacingOrg.Tracker.Pro.Sampling)
       catch
         :exit, _ -> :ok
       end
     end}
  end

  # On-device compute engine (Phase 7): receives user-defined computed-value
  # definitions from the server over the WSS channel ("set_computed_values"),
  # subscribes to decoded telemetry to keep the current value of each source signal,
  # and recomputes each computed value when one of its sources changes — evaluating
  # both free-form expressions and the native library calcs (true wind / VMG / VMC).
  # It persists the defs to /data (survives reboots) and holds the latest result per
  # def for Phase 8 (N2K broadcast) to consume via current_values/1. Started in EVERY
  # environment so the channel + Phase 8 can read it; cheap + idle with no defs. Must
  # start AFTER Telemetry (it attaches :telemetry handlers).
  defp clock_source_config_child do
    {RacingOrg.Tracker.Pro.ClockSource.Config,
     name: RacingOrg.Tracker.Pro.ClockSource.Config,
     store_dir: Application.get_env(:racing_org_tracker_pro, :clock_source_directory)}
  end

  # Sensor-calibration state (server-pushed "set_calibration" policy + on-device
  # learned corrections). It persists both to /data (survives reboots) and compiles
  # the per-sensor corrections the compute engine caches and applies to decoded
  # telemetry. Started in EVERY environment so the channel + engine can read it;
  # cheap + idle with no config (no corrections -> every signal passes through).
  # Must start BEFORE Compute.Engine (the engine subscribes to / reads it in init).
  defp calibration_config_child do
    {RacingOrg.Tracker.Pro.Calibration.Config,
     name: RacingOrg.Tracker.Pro.Calibration.Config,
     store_dir: Application.get_env(:racing_org_tracker_pro, :calibration_directory)}
  end

  # The auto-calibration Observer: harvests steady legs / tack pairs / reciprocal
  # runs from RAW per-sensor bus data (it is also registered as a VirtualDevice
  # handler below), fits corrections, and promotes them into Calibration.Config.
  # Shares :calibration_directory with the Config (distinct filenames).
  defp calibration_observer_child do
    {RacingOrg.Tracker.Pro.Calibration.Observer,
     name: RacingOrg.Tracker.Pro.Calibration.Observer,
     dir: Application.get_env(:racing_org_tracker_pro, :calibration_directory)}
  end

  defp compute_engine_child do
    {RacingOrg.Tracker.Pro.Compute.Engine,
     name: RacingOrg.Tracker.Pro.Compute.Engine,
     store_dir: Application.get_env(:racing_org_tracker_pro, :computed_values_directory),
     calibration: RacingOrg.Tracker.Pro.Calibration.Config}
  end

  # Wind-shift policy (server-pushed "set_wind_shift" config: predictor windows /
  # envelope alarms / wally mode). It persists the config to /data (survives
  # reboots) and notifies the WindShift.Observer, which rebuilds its cores on a
  # change. Started in EVERY environment so the channel + Observer can read it;
  # cheap + idle with no config (built-in defaults apply). Must start BEFORE
  # WindShift.Observer (the Observer subscribes to / reads it in init).
  defp wind_shift_config_child do
    {RacingOrg.Tracker.Pro.WindShift.Config,
     name: RacingOrg.Tracker.Pro.WindShift.Config,
     store_dir: Application.get_env(:racing_org_tracker_pro, :wind_shift_directory)}
  end

  # The wind-shift predictor Observer: on its own ~1 Hz timer it samples the
  # compute engine's signals, drives the pure wind-shift cores (means / envelope /
  # cycle / period / step / classifier), publishes the wind-shift signals back
  # into the engine, broadcasts the B&G 130824 keys 336-338, and syncs a
  # throttled session batch upstream over the WSS channel. Shares
  # :wind_shift_directory with the Config (distinct filenames). Must start AFTER
  # Compute.Engine (it reads its signals) and AFTER WindShift.Config.
  defp wind_shift_observer_child do
    {RacingOrg.Tracker.Pro.WindShift.Observer,
     name: RacingOrg.Tracker.Pro.WindShift.Observer,
     dir: Application.get_env(:racing_org_tracker_pro, :wind_shift_directory),
     boat_identifier: RacingOrg.Tracker.Pro.boat_identifier()}
  end

  # SECONDARY observational ("sailed") polar (Phase 4): on its own ~1 Hz timer it
  # samples the compute engine's raw signals, derives STW-based true wind, gates each
  # sample for steady-state sailing (and a moving-boat min-STW floor), and accumulates
  # a streaming boat-speed percentile per (TWS, TWA) cell. It persists the sailed cells
  # to /data (survives reboots) THROTTLED to spare flash, and syncs CHANGED cells
  # upstream over the WSS channel as throttled incremental deltas. Started in EVERY
  # environment so it accumulates whenever sailing; cheap + idle at rest. The `:dir` is
  # the polar directory (nil on host/test disables persistence, mirroring Commands).
  # Must start AFTER Compute.Engine (it reads its signals).
  defp polar_observer_child do
    {RacingOrg.Tracker.Pro.Polar.Observer,
     name: RacingOrg.Tracker.Pro.Polar.Observer,
     dir: Application.get_env(:racing_org_tracker_pro, :polar_directory),
     boat_identifier: RacingOrg.Tracker.Pro.boat_identifier()}
  end

  # Durable local race archiving + reconciliation with RacingOrg.
  defp archive_child do
    {RacingOrg.Tracker.Pro.Race.Archive,
     name: RacingOrg.Tracker.Pro.Race.Archive,
     base_dir: Application.get_env(:racing_org_tracker_pro, :race_archive_directory),
     sampling: RacingOrg.Tracker.Pro.Sampling,
     device_id: RacingOrg.Tracker.Pro.boat_identifier()}
  end

  # Broadcasts the B&G race-start countdown (PGN 130824 Key 117) at ~1 Hz whenever the
  # device holds a race assignment with a gun time (a reverse-engineered proprietary
  # message). Always on; cheap + a no-op while unassigned.
  defp race_timer_broadcaster_child do
    {RacingOrg.Tracker.Pro.Compute.RaceTimerBroadcaster, name: RacingOrg.Tracker.Pro.Compute.RaceTimerBroadcaster}
  end

  # Broadcasts the NEXT WAYPOINT to steer to (PGN 129284 Navigation Data + PGN 129285
  # Route/WP Information) at ~1 Hz whenever the device holds a race assignment whose
  # active mark carries a position AND a recent GPS fix is available (STANDARD nav PGNs).
  # Always on; cheap + a no-op while unassigned or before a GPS fix.
  defp waypoint_broadcaster_child do
    {RacingOrg.Tracker.Pro.Compute.WaypointBroadcaster, name: RacingOrg.Tracker.Pro.Compute.WaypointBroadcaster}
  end

  # RacingOrg.Tracker.Pro.Nav.DeviationMonitor (on-water P3): every 10 s, while RACING, it
  # compares the boat's cross-track error (the same Nav.State the Nav.Broadcaster derives)
  # against the server-pushed deviation_threshold_meters (from Tracking.Config) and asks
  # the backend for a route recalc — ONCE per excursion (a new route or a cooldown re-arms
  # it). It is wired with all default-named collaborators (Commands / Sampling /
  # Tracking.Config / ChannelClient); cheap + idle until a race is underway, and the recalc
  # push is best-effort + session-gated so it never couples to channel state. Must start
  # AFTER Commands + Sampling + Tracking.Config (it subscribes to / reads them in init).

  defp product do
    case Application.get_env(:racing_org_tracker_pro, :product) do
      "logger" ->
        :logger

      "uplink" ->
        :uplink

      unexpected ->
        raise """
        unexpected PRODUCT #{inspect(unexpected)}; must be one of:

             - "logger" for NMEA2000 device
             - "uplink" for mini tracker base station uplink node

        """
    end
  end

  defp target do
    Application.get_env(:racing_org_tracker_pro, :target)
  end

  # Get the filtering configuration / settings for NMEA data being
  # set to the cloud.
  # FUTURETODO: Load the current fitters from disk
  defp emit_telemetry_config do
    (Application.get_env(:racing_org_tracker_pro, :data_filtering) || [])
    |> Keyword.put(:clock_source, RacingOrg.Tracker.Pro.ClockSource.Config)
  end

  defp virtual_device_config do
    Application.get_env(:nmea, NMEA.VirtualDevice, [])
    |> Kernel.++(virtual_device_save_fns(target()))
    |> Enum.into(%{})
  end

  # Functions cannot be defined in target.exs so they kept here and to be merged with the previously
  # defined configs
  defp virtual_device_save_fns(:racing_org_rpi3) do
    [
      save_fn: fn key, value -> File.write("/root/#{key}.setting", :erlang.term_to_binary(value)) end,
      retrieve_fn: fn key ->
        "/root/#{key}.setting"
        |> File.read()
        |> case do
          {:ok, ""} -> nil
          {:ok, setting} -> :erlang.binary_to_term(setting)
          {:error, _reason} -> nil
        end
      end
    ]
  end

  defp virtual_device_save_fns(_) do
    [
      save_fn: fn _key, _value -> :ok end,
      retrieve_fn: fn _key -> nil end
    ]
  end

  defp serial_config do
    Application.get_env(:racing_org_tracker_pro, RacingOrg.Tracker.Pro.Serial, [])
  end

  defp udp_config do
    endpoint = Application.get_env(:racing_org_tracker_pro, :udp_endpoint, "localhost:4001")
    [hostname, port] = String.split(endpoint, ":")

    [hostname: hostname, port: String.to_integer(port)]
  end

  def maybe_replay_log do
    if filename = Application.get_env(:racing_org_tracker_pro, :replay_log) do
      RacingOrg.Tracker.Pro.DeviceCLI.replay_log(filename, realtime?: true)
    end
  end
end
