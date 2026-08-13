defmodule RacingOrg.Tracker.Pro.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @max_unfragmented_udp_payload_size {508, :bytes}

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: RacingOrg.Tracker.Pro.Supervisor]

    children = child_specs(product(), target())

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

  @doc false
  @spec child_specs(:logger | :uplink, atom() | nil) :: [Supervisor.child_spec() | module() | {module(), term()}]
  def child_specs(product, target), do: children(product, target)

  @doc false
  @spec start_checkpoint_hydration(keyword()) :: GenServer.on_start()
  def start_checkpoint_hydration(opts) when is_list(opts) do
    alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Store

    identity_reader = Keyword.fetch!(opts, :identity)
    identity_authority = Keyword.fetch!(opts, :identity_authority)
    coordinator_starter = Keyword.fetch!(opts, :coordinator_starter)

    with {:ok, identity} <- identity_reader.(),
         {:ok, head_store} <-
           Store.new(
             base_dir: Keyword.fetch!(opts, :head_store_base_dir),
             device_id: identity.device_id,
             credential_epoch: identity.credential_epoch,
             storage_epoch: identity.storage_epoch,
             identity: identity_authority
           ) do
      coordinator_starter.(
        name: Keyword.get(opts, :name, RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.Coordinator),
        journal_path: Keyword.fetch!(opts, :journal_path),
        head_store: head_store
      )
    end
  rescue
    _exception -> {:error, :checkpoint_hydration_unavailable}
  catch
    _kind, _reason -> {:error, :checkpoint_hydration_unavailable}
  end

  # Product: NMEA 2000 standalone, on-board device
  defp children(:logger, target) do
    controller_capability = make_ref()

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
      {RacingOrg.Tracker.Pro.DataSetRecorder, chunk_every: @max_unfragmented_udp_payload_size}
    ] ++
      wifi_manager_children(target) ++
      desired_state_children(target, controller_capability) ++
      secure_transport_children(:logger, target, controller_capability) ++
      data_set_uploader_children(:logger) ++
      firmware_validation_children(:logger, target)
  end

  # Product: Base station receiver node for racing_org_tracker_mini
  defp children(:uplink, target) do
    [
      commands_child(),
      RacingOrg.Tracker.Pro.SecureTransport.SessionHolder,
      {RacingOrg.Tracker.Pro.WebClients.UDPClient, udp_config()}
    ] ++
      data_set_children(:uplink) ++
      [RacingOrg.Tracker.Pro.BaseStation] ++
      wifi_manager_children(target) ++ secure_transport_children(:uplink, target, nil)
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

  # Logger-only Desired State foundations. RuntimeIdentity owns the boot/storage
  # incarnation, and the Applier starts only after all authoritative section owners
  # (including WiFiManager) are available. BootProvisioner, Manager, and the gate are
  # ordered separately below so the gate can pin the exact live Manager PID at claim.
  defp desired_state_children(target, controller_capability) do
    if secure_transport_configured?(target) do
      [
        RacingOrg.Tracker.Pro.DesiredState.RuntimeIdentity,
        RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistry.Root,
        RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistry.Store,
        RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistry,
        RacingOrg.Tracker.Pro.DesiredState.Runtime.applier_child_spec(controller_capability: controller_capability)
      ]
    else
      []
    end
  end

  # P9-job-6 secure-transport children, appended after the network/HTTP deps they
  # rely on. The SessionHolder is started inline above (it runs in EVERY environment:
  # the UDP send path + tests read it, and it is idle/cheap with no session). These
  # extra children are gated together by `secure_transport_configured?/1` — a real
  # device target AND the pinned server public key being configured (there is no
  # separate enable flag; the pinned key IS the enable):
  #
  #   * BootProvisioner — supervised receipt/state reconciliation coordinator. It
  #     remains available for authenticated readiness and legacy-enrollment callbacks.
  #   * ChannelClient — outbound WSS command channel. It additionally SELF-GATES in
  #     init (idle unless verified authority + an active identity + server pin exist).
  #   * BulkUploader — thin GenServer giving `upload_async/2` a named server for the
  #     Archive's post-race trigger. Cheap + idle.
  #
  # Each child also self-gates at runtime, so this is belt-and-suspenders. On
  # host/test (`real_target?` false) they never start.
  #
  # Ordering on logger: BootProvisioner (signed authority) → DesiredState.Manager →
  # OperationalGate (pins the live Manager PID) → ChannelClient (connects/handshakes)
  # → BulkUploader, all AFTER SessionHolder and the Desired State foundations. Uplink
  # preserves the legacy three-child order and
  # does not start the logger-only generation runtime.
  defp secure_transport_children(product, target, controller_capability) do
    if secure_transport_configured?(target) do
      [RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner] ++
        desired_state_manager_children(product, controller_capability) ++
        operational_gate_children(product, controller_capability) ++
        command_executor_children(product) ++
        outbox_owner_children(product) ++
        checkpoint_hydration_children(product) ++
        [
          RacingOrg.Tracker.Pro.SecureTransport.ChannelClient,
          RacingOrg.Tracker.Pro.Race.BulkUploader
        ]
    else
      []
    end
  end

  # The durable command executor owns the on-device command ledger and every
  # command effect. It starts AFTER the Manager and the gate (it reads both to
  # judge the desired-generation, manifest, and operational-gate fences) and
  # BEFORE the ChannelClient that routes authenticated deliveries into it, so a
  # delivery can never arrive before the ledger is open and recovered.
  #
  # Its ledger path is derived from the PERSISTENT desired-state storage root
  # (which holds the /data storage_epoch file), never from the transient boot_id,
  # so a reboot reopens the same ledger and a pending intent is recovered rather
  # than lost. Identity is resolved at init from the verified bootstrap authority.
  defp command_executor_children(:logger) do
    [
      {RacingOrg.Tracker.Pro.Commands.Ledger.Executor,
       path: command_ledger_path(), providers: RacingOrg.Tracker.Pro.Commands.Ledger.Registry.recovery_verifiers()}
    ]
  end

  defp command_executor_children(:uplink), do: []

  defp outbox_owner_children(:logger) do
    [
      {RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner,
       name: RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner,
       root: outbox_root(),
       identity: &RacingOrg.Tracker.Pro.DesiredState.Runtime.identity/0}
    ]
  end

  defp outbox_owner_children(:uplink), do: []

  # The hydration coordinator starts only after Manager, SessionHolder, every
  # observer restorer, and the exact durable identity authority are live. Its
  # start MFA constructs the identity-bound checkpoint-head store before starting
  # the coordinator. ChannelClient comes later, so no authenticated hydration can
  # arrive before recovery has inspected the durable journal.
  defp checkpoint_hydration_children(:logger) do
    coordinator = RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.Coordinator

    [
      %{
        id: coordinator,
        start:
          {__MODULE__, :start_checkpoint_hydration,
           [
             [
               journal_path: checkpoint_hydration_journal_path(),
               head_store_base_dir: checkpoint_head_root(),
               identity: &RacingOrg.Tracker.Pro.DesiredState.Runtime.identity/0,
               identity_authority: &checkpoint_head_identity_authority/1,
               coordinator_starter: &coordinator.start_link/1
             ]
           ]},
        restart: :permanent,
        shutdown: 5_000,
        type: :worker,
        modules: [coordinator]
      }
    ]
  end

  defp checkpoint_hydration_children(:uplink), do: []

  defp checkpoint_head_identity_authority(transition) when is_function(transition, 1) do
    case RacingOrg.Tracker.Pro.DesiredState.Runtime.identity() do
      {:ok, identity} -> transition.(identity)
      {:error, _reason} = error -> error
    end
  end

  # Logger legacy spool migration starts only after the durable Outbox owner is
  # open and identity-bound. The Recorder is started earlier so newly persisted
  # files can always notify a live admission worker once it boots. Uplink has no
  # Outbox owner and therefore retains the existing UDP uploader strategy.
  defp data_set_uploader_children(:logger) do
    [
      {RacingOrg.Tracker.Pro.DataSetUploader,
       delivery: :durable, outbox: RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner}
    ]
  end

  defp data_set_children(:uplink) do
    [
      {RacingOrg.Tracker.Pro.DataSetRecorder, chunk_every: @max_unfragmented_udp_payload_size},
      {RacingOrg.Tracker.Pro.DataSetUploader, delivery: :legacy, via: :udp}
    ]
  end

  # Firmware validation starts last, after every source it must inspect. The
  # Coordinator owns the one boot-relative rollback deadline and waits for exact
  # target authority before starting a single Trial. Health readers fail closed;
  # missing receipt evidence therefore consumes the original deadline instead of
  # delaying coordinator startup and granting a fresh budget later.
  defp firmware_validation_children(:logger, target) do
    if secure_transport_configured?(target) do
      [{RacingOrg.Tracker.Pro.FirmwareValidation.Coordinator, firmware_validation_options()}]
    else
      []
    end
  end

  defp firmware_validation_options do
    alias RacingOrg.Tracker.Pro.FirmwareValidation

    config = Application.fetch_env!(:racing_org_tracker_pro, FirmwareValidation.Coordinator)
    soak_period_ms = Keyword.fetch!(config, :soak_period_ms)

    default_target_reader = fn ->
      FirmwareValidation.Target.read(soak_period_ms: soak_period_ms)
    end

    default_snapshot_opts = [
      process_health_reader: &FirmwareValidation.RequiredProcesses.status/0,
      receipt_health_reader: &FirmwareValidation.ReceiptHealth.read/0,
      outbox_reader: &FirmwareValidation.OutboxHealth.read/0
    ]

    default_health_event_sink = fn event ->
      RacingOrg.Tracker.Pro.DurableDelivery.Producer.HealthEvent.admit(event,
        outbox: RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner
      )
    end

    trial_opts =
      config
      |> Keyword.get(:trial_opts, [])
      |> Keyword.put_new(:store_dir, Keyword.fetch!(config, :store_dir))
      |> Keyword.put_new(:retry_ms, Keyword.fetch!(config, :retry_ms))
      |> Keyword.put_new(:health_event_sink, default_health_event_sink)
      |> Keyword.put_new(:health_event_context, %{
        target_source: :firmware_validation_target,
        manifest_hash_reader: &RacingOrg.Tracker.Pro.DesiredState.Manager.status/0
      })
      |> Keyword.update(:snapshot_opts, default_snapshot_opts, &Keyword.merge(default_snapshot_opts, &1))

    config
    |> Keyword.take([:name, :clock, :trial_starter])
    |> Keyword.put(:rollback_after_ms, Keyword.fetch!(config, :rollback_after_ms))
    |> Keyword.put(:retry_ms, Keyword.fetch!(config, :retry_ms))
    |> Keyword.put(:target_reader, Keyword.get(config, :target_reader, default_target_reader))
    |> Keyword.put(:trial_opts, trial_opts)
  end

  defp outbox_root do
    Application.get_env(:racing_org_tracker_pro, :durable_outbox_root) ||
      RacingOrg.Tracker.Pro.DesiredState.RuntimeIdentity.storage_epoch_path()
      |> Path.dirname()
      |> Path.join("outbox")
  end

  defp checkpoint_head_root do
    Application.get_env(:racing_org_tracker_pro, :checkpoint_head_root) ||
      RacingOrg.Tracker.Pro.DesiredState.RuntimeIdentity.storage_epoch_path()
      |> Path.dirname()
      |> Path.join("checkpoint_heads")
  end

  defp checkpoint_hydration_journal_path do
    Application.get_env(:racing_org_tracker_pro, :checkpoint_hydration_journal_path) ||
      RacingOrg.Tracker.Pro.DesiredState.RuntimeIdentity.storage_epoch_path()
      |> Path.dirname()
      |> Path.join("checkpoint_hydration.journal")
  end

  defp command_ledger_path do
    case Application.get_env(:racing_org_tracker_pro, :command_ledger_path) do
      path when is_binary(path) and path != "" ->
        if Path.type(path) == :absolute do
          path
        else
          RacingOrg.Tracker.Pro.DesiredState.RuntimeIdentity.storage_epoch_path()
          |> Path.dirname()
          |> Path.join(path)
        end

      _unset_or_invalid ->
        RacingOrg.Tracker.Pro.Commands.Ledger.Executor.default_path()
    end
  end

  defp desired_state_manager_children(:logger, controller_capability) do
    [
      RacingOrg.Tracker.Pro.DesiredState.Runtime.manager_child_spec(controller_capability: controller_capability)
    ]
  end

  defp desired_state_manager_children(:uplink, _controller_capability), do: []

  defp operational_gate_children(:logger, controller_capability) do
    [
      {RacingOrg.Tracker.Pro.DesiredState.OperationalGate, controller_capability: controller_capability}
    ]
  end

  defp operational_gate_children(:uplink, _controller_capability), do: []

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
     name:
       Application.get_env(
         :racing_org_tracker_pro,
         :upstream_config_name,
         RacingOrg.Tracker.Pro.Upstream.Config
       ),
     store_dir: Application.get_env(:racing_org_tracker_pro, :upstream_directory)}
  end

  defp tracking_config_child do
    {RacingOrg.Tracker.Pro.Tracking.Config,
     name: RacingOrg.Tracker.Pro.Tracking.Config,
     store_dir: Application.get_env(:racing_org_tracker_pro, :tracking_directory),
     on_apply: fn config ->
       RacingOrg.Tracker.Pro.Sampling.reconfigure(RacingOrg.Tracker.Pro.Sampling, config)
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
    outbox = RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner

    {RacingOrg.Tracker.Pro.Race.Archive,
     name: RacingOrg.Tracker.Pro.Race.Archive,
     base_dir: Application.get_env(:racing_org_tracker_pro, :race_archive_directory),
     sampling: RacingOrg.Tracker.Pro.Sampling,
     device_id: RacingOrg.Tracker.Pro.boat_identifier(),
     durable_enqueue_fn: fn stream, payload, opts -> outbox.enqueue(outbox, stream, payload, opts) end,
     durable_pending_fn: fn -> outbox.pending(outbox) end}
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
