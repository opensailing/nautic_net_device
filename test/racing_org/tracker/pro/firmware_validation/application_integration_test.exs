defmodule RacingOrg.Tracker.Pro.FirmwareValidation.ApplicationIntegrationTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.DesiredState.{
    Applier,
    Manager,
    OperationalGate,
    RuntimeIdentity
  }

  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Store, as: CheckpointHeadStore
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.Coordinator, as: HydrationCoordinator
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner

  alias RacingOrg.Tracker.Pro.FirmwareValidation.{
    Coordinator,
    OutboxHealth,
    ReceiptHealth,
    RequiredProcesses,
    Snapshot
  }

  alias RacingOrg.Tracker.Pro.SecureTransport.{
    BootProvisioner,
    ChannelClient,
    ServerIdentity,
    SessionHolder
  }

  @git_sha String.duplicate("a", 40)

  setup do
    coordinator_config = Application.get_env(:racing_org_tracker_pro, Coordinator)
    server_identity_config = Application.get_env(:racing_org_tracker_pro, ServerIdentity)

    on_exit(fn ->
      restore_env(Coordinator, coordinator_config)
      restore_env(ServerIdentity, server_identity_config)
    end)

    :ok
  end

  test "logger supervises one non-restarting Coordinator after every required dependency" do
    Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

    Application.put_env(:racing_org_tracker_pro, Coordinator,
      rollback_after_ms: 50,
      soak_period_ms: 10,
      retry_ms: 60_000,
      store_dir: "/tmp/firmware-validation-test"
    )

    specs = child_specs(:logger, :racing_org_rpi3)
    ids = Enum.map(specs, & &1.id)

    assert Enum.count(ids, &(&1 == Coordinator)) == 1
    refute Enum.any?(ids, &(&1 == RacingOrg.Tracker.Pro.FirmwareValidation.Trial))

    coordinator_index = Enum.find_index(ids, &(&1 == Coordinator))

    for dependency <- [
          RuntimeIdentity,
          BootProvisioner,
          SessionHolder,
          Applier,
          Manager,
          OperationalGate,
          Owner,
          ChannelClient
        ] do
      assert Enum.find_index(ids, &(&1 == dependency)) < coordinator_index
    end

    coordinator_spec = Enum.find(specs, &(&1.id == Coordinator))
    assert coordinator_spec.restart == :temporary

    assert {Coordinator, :start_link, [opts]} = coordinator_spec.start
    assert opts[:rollback_after_ms] == 50
    assert opts[:retry_ms] == 60_000
    assert opts[:trial_opts][:store_dir] == "/tmp/firmware-validation-test"
    assert opts[:trial_opts][:retry_ms] == 60_000
  end

  test "logger wires durable Archive admission through the production Outbox owner" do
    specs = child_specs(:logger, :racing_org_rpi3)
    archive_spec = Enum.find(specs, &(&1.id == RacingOrg.Tracker.Pro.Race.Archive))

    assert {RacingOrg.Tracker.Pro.Race.Archive, :start_link, [opts]} = archive_spec.start
    assert is_function(opts[:durable_enqueue_fn], 3)
    assert is_function(opts[:durable_pending_fn], 0)

    purge_module(RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner)

    on_exit(fn ->
      purge_module(RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner)

      {:module, RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner} =
        :code.load_file(RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner)
    end)

    owner = self()

    Module.create(
      RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner,
      quote do
        def enqueue(server, stream, payload, enqueue_opts) do
          send(unquote(owner), {:archive_enqueue, server, stream, payload, enqueue_opts})
          {:ok, :receipt}
        end

        def pending(server) do
          send(unquote(owner), {:archive_pending, server})
          [:pending]
        end
      end,
      Macro.Env.location(__ENV__)
    )

    assert {:ok, :receipt} = opts[:durable_enqueue_fn].(:race_recording_chunk, "sealed", entry_id: <<1>>)

    assert_receive {:archive_enqueue, Owner, :race_recording_chunk, "sealed", [entry_id: <<1>>]}
    assert [:pending] = opts[:durable_pending_fn].()
    assert_receive {:archive_pending, Owner}
  end

  test "logger supervises the checkpoint submission scheduler with acknowledgement wiring" do
    scheduler = RacingOrg.Tracker.Pro.DurableDelivery.CheckpointSubmission.Scheduler
    owner = RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner
    Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

    specs = child_specs(:logger, :racing_org_rpi3)
    ids = Enum.map(specs, & &1.id)

    assert Enum.count(ids, &(&1 == scheduler)) == 1
    scheduler_index = Enum.find_index(ids, &(&1 == scheduler))
    assert Enum.find_index(ids, &(&1 == owner)) < scheduler_index
    assert Enum.find_index(ids, &(&1 == HydrationCoordinator)) < scheduler_index
    assert scheduler_index < Enum.find_index(ids, &(&1 == ChannelClient))

    scheduler_spec = Enum.find(specs, &(&1.id == scheduler))
    assert {^scheduler, :start_link, [scheduler_opts]} = scheduler_spec.start
    assert scheduler_opts[:identity] == (&RacingOrg.Tracker.Pro.DesiredState.Runtime.identity/0)
    assert is_function(scheduler_opts[:head_store], 0)

    owner_spec = Enum.find(specs, &(&1.id == owner))
    assert {^owner, :start_link, [owner_opts]} = owner_spec.start
    assert is_function(owner_opts[:on_acknowledge], 1)
    assert owner_opts[:on_acknowledge].([]) == :ok
  end

  test "logger starts checkpoint hydration after authority and observers but before ChannelClient" do
    Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

    specs = child_specs(:logger, :racing_org_rpi3)
    ids = Enum.map(specs, & &1.id)

    assert Enum.count(ids, &(&1 == HydrationCoordinator)) == 1
    hydration_index = Enum.find_index(ids, &(&1 == HydrationCoordinator))
    channel_index = Enum.find_index(ids, &(&1 == ChannelClient))

    for dependency <- [
          SessionHolder,
          Manager,
          RacingOrg.Tracker.Pro.Calibration.Observer,
          RacingOrg.Tracker.Pro.Polar.Observer,
          RacingOrg.Tracker.Pro.WindShift.Observer
        ] do
      assert Enum.find_index(ids, &(&1 == dependency)) < hydration_index
    end

    assert hydration_index < channel_index

    hydration_spec = Enum.find(specs, &(&1.id == HydrationCoordinator))
    assert {RacingOrg.Tracker.Pro.Application, :start_checkpoint_hydration, [opts]} = hydration_spec.start
    assert Path.type(opts[:journal_path]) == :absolute
    assert Path.type(opts[:head_store_base_dir]) == :absolute
    assert opts[:head_store_transition_timeout_ms] == 180_000
    assert opts[:reconcile_empty_journal]
    assert is_function(opts[:identity], 0)
    assert is_function(opts[:identity_authority], 1)
    assert is_function(opts[:coordinator_starter], 1)
  end

  test "checkpoint hydration composition constructs and passes the exact head store" do
    identity = %{
      device_id: <<1::128>>,
      credential_epoch: 7,
      storage_epoch: <<2::128>>
    }

    parent = self()
    base = Path.join(System.tmp_dir!(), "checkpoint-head-composition-#{System.unique_integer([:positive])}")
    journal = Path.join(base, "hydration.journal")

    opts = [
      name: nil,
      journal_path: journal,
      head_store_base_dir: Path.join(base, "heads"),
      reconcile_empty_journal: true,
      identity: fn -> {:ok, identity} end,
      identity_authority: fn transition -> transition.(identity) end,
      coordinator_starter: fn coordinator_opts ->
        send(parent, {:hydration_coordinator_opts, coordinator_opts})
        {:ok, self()}
      end
    ]

    assert {:ok, _coordinator} = RacingOrg.Tracker.Pro.Application.start_checkpoint_hydration(opts)

    assert_receive {:hydration_coordinator_opts, coordinator_opts}
    assert coordinator_opts[:journal_path] == journal
    assert coordinator_opts[:reconcile_empty_journal]
    assert %CheckpointHeadStore{} = coordinator_opts[:head_store]
    assert coordinator_opts[:head_store].base_dir == Path.join(base, "heads")
    assert coordinator_opts[:head_store].device_id == identity.device_id
    assert coordinator_opts[:head_store].credential_epoch == identity.credential_epoch
    assert coordinator_opts[:head_store].storage_epoch == identity.storage_epoch
    assert coordinator_opts[:head_store].transition_timeout_ms == 180_000
  end

  test "production Trial receives the durable health admitter and exact target context" do
    Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

    Application.put_env(:racing_org_tracker_pro, Coordinator,
      rollback_after_ms: 50,
      soak_period_ms: 10,
      retry_ms: 60_000,
      store_dir: "/tmp/firmware-validation-test"
    )

    coordinator_spec =
      :logger
      |> child_specs(:racing_org_rpi3)
      |> Enum.find(&(&1.id == Coordinator))

    assert {Coordinator, :start_link, [opts]} = coordinator_spec.start
    health_event_sink = opts[:trial_opts][:health_event_sink]
    assert is_function(health_event_sink, 1)

    assert opts[:trial_opts][:health_event_context] == %{
             target_source: :firmware_validation_target,
             manifest_hash_reader: &Manager.status/0
           }

    health_event_producer = RacingOrg.Tracker.Pro.DurableDelivery.Producer.HealthEvent
    purge_module(health_event_producer)

    on_exit(fn ->
      purge_module(health_event_producer)
      {:module, ^health_event_producer} = :code.load_file(health_event_producer)
    end)

    owner = self()

    Module.create(
      health_event_producer,
      quote do
        def admit(event, admit_opts) do
          send(unquote(owner), {:health_event_admitted, event, admit_opts})
          {:ok, :receipt}
        end
      end,
      Macro.Env.location(__ENV__)
    )

    assert {:ok, :receipt} = health_event_sink.(%{event_type: :validation_pending})

    assert_receive {:health_event_admitted, %{event_type: :validation_pending}, [outbox: Owner]}
  end

  test "Application wiring preserves the startup deadline and starts Trial exactly once" do
    Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

    clock = start_supervised!({Agent, fn -> 100 end}, id: {:clock, make_ref()})
    target = start_supervised!({Agent, fn -> :pending end}, id: {:target, make_ref()})
    parent = self()

    Application.put_env(:racing_org_tracker_pro, Coordinator,
      name: nil,
      clock: fn -> Agent.get(clock, & &1) end,
      target_reader: fn -> Agent.get(target, & &1) end,
      trial_starter: fn opts ->
        send(parent, {:trial_started, opts})
        {:ok, self()}
      end,
      rollback_after_ms: 50,
      soak_period_ms: 10,
      retry_ms: 60_000,
      store_dir: "/tmp/firmware-validation-test"
    )

    coordinator_spec =
      :logger
      |> child_specs(:racing_org_rpi3)
      |> Enum.find(&(&1.id == Coordinator))

    assert {:ok, coordinator} = start_spec(coordinator_spec)
    on_exit(fn -> if Process.alive?(coordinator), do: GenServer.stop(coordinator) end)

    assert %{phase: :target_pending, deadline_at_ms: 150} = Coordinator.status(coordinator)
    refute_received {:trial_started, _opts}

    Agent.update(clock, fn _current -> 200 end)
    Agent.update(target, fn _current -> {:ok, target_identity()} end)

    assert :ok = Coordinator.check_now(coordinator)

    assert_receive {:trial_started, trial_opts}
    assert trial_opts[:target] == Map.put(target_identity(), :deadline_at_ms, 150)
    assert trial_opts[:clock].() == 200

    assert :ok = Coordinator.check_now(coordinator)
    refute_receive {:trial_started, _opts}
  end

  test "production Trial readers use the closed health adapters and remain unhealthy without evidence" do
    Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

    Application.put_env(:racing_org_tracker_pro, Coordinator,
      rollback_after_ms: 50,
      soak_period_ms: 10,
      retry_ms: 60_000,
      store_dir: "/tmp/firmware-validation-test"
    )

    coordinator_spec =
      :logger
      |> child_specs(:racing_org_rpi3)
      |> Enum.find(&(&1.id == Coordinator))

    assert {Coordinator, :start_link, [opts]} = coordinator_spec.start
    snapshot_opts = opts[:trial_opts][:snapshot_opts]

    assert snapshot_opts[:process_health_reader].() == RequiredProcesses.status()
    assert snapshot_opts[:receipt_health_reader].() == ReceiptHealth.read()
    assert snapshot_opts[:outbox_reader].() == OutboxHealth.read()

    assert %{supervisor: :unhealthy, owner: :unhealthy} =
             snapshot_opts[:process_health_reader].()

    assert %{control: :pending, telemetry: :pending} =
             snapshot_opts[:receipt_health_reader].()

    assert %{corrupt: true, critical_pressure: true} = snapshot_opts[:outbox_reader].()
  end

  test "Snapshot consumes aggregate production adapter results and fails closed on unavailable adapters" do
    healthy =
      Snapshot.build(
        %{observed_at_ms: 10, soak_started_at_ms: 10},
        core_snapshot_opts() ++
          [
            process_health_reader: fn -> %{supervisor: :healthy, owner: :healthy} end,
            receipt_health_reader: fn -> %{control: :succeeded, telemetry: :succeeded} end,
            outbox_reader: fn -> %{corrupt: false, critical_pressure: false} end
          ]
      )

    assert healthy.process_health == %{supervisor: :healthy, owner: :healthy}
    assert healthy.receipts == %{control: :succeeded, telemetry: :succeeded}
    assert healthy.outbox == %{corrupt: false, critical_pressure: false}

    unavailable =
      Snapshot.build(
        %{observed_at_ms: 10, soak_started_at_ms: 10},
        core_snapshot_opts() ++
          [
            process_health_reader: fn -> raise "process evidence unavailable" end,
            receipt_health_reader: fn -> :unavailable end,
            outbox_reader: fn -> raise "outbox evidence unavailable" end
          ]
      )

    assert unavailable.process_health == %{supervisor: :unhealthy, owner: :unhealthy}
    assert unavailable.receipts == %{control: :failed, telemetry: :failed}
    assert unavailable.outbox == %{corrupt: true, critical_pressure: true}
  end

  test "uplink and unconfigured targets never supervise firmware validation" do
    Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

    assert :uplink
           |> child_specs(:racing_org_rpi3)
           |> Enum.all?(&(&1.id != Coordinator))

    Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: nil)

    assert :logger
           |> child_specs(:racing_org_rpi3)
           |> Enum.all?(&(&1.id != Coordinator))
  end

  test "production config provides one bounded rollback, soak, retry, and durable diagnostics path" do
    config = Application.fetch_env!(:racing_org_tracker_pro, Coordinator)

    assert config[:rollback_after_ms] > config[:soak_period_ms]
    assert config[:soak_period_ms] > 0
    assert config[:retry_ms] > 0
    assert Path.type(config[:store_dir]) == :absolute
  end

  defp child_specs(product, target) do
    product
    |> RacingOrg.Tracker.Pro.Application.child_specs(target)
    |> Enum.map(&Supervisor.child_spec(&1, []))
  end

  defp start_spec(%{start: {module, function, arguments}}) do
    apply(module, function, arguments)
  end

  defp target_identity do
    %{
      firmware: %{version: "0.7.0", git_sha: @git_sha},
      credential_epoch: 7,
      desired_generation: 12,
      soak_period_ms: 10
    }
  end

  defp core_snapshot_opts do
    [
      firmware_version_reader: fn -> "0.7.0" end,
      git_commit_reader: fn -> @git_sha end,
      session_reader: fn -> {:ok, %{credential_epoch: 7}} end,
      manager_reader: fn ->
        %{
          active: Map.put(gate_binding(), :device_id, <<1::128>>),
          gate: {:open, gate_binding()},
          identity: nil,
          recovery_error: nil
        }
      end,
      applier_owners_reader: fn -> %{tracking: self()} end,
      owner_alive_reader: fn _owner -> true end
    ]
  end

  defp gate_binding do
    %{
      credential_epoch: 7,
      storage_epoch: <<2::128>>,
      generation: 12,
      manifest_hash: <<3::256>>
    }
  end

  defp purge_module(module) do
    :code.purge(module)
    :code.delete(module)
  end

  defp restore_env(key, nil), do: Application.delete_env(:racing_org_tracker_pro, key)
  defp restore_env(key, value), do: Application.put_env(:racing_org_tracker_pro, key, value)
end
