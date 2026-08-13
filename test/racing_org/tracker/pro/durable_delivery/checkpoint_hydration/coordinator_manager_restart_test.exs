defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.CoordinatorManagerRestartTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Application, as: TrackerApplication
  alias RacingOrg.Tracker.Pro.Calibration.Observer, as: CalibrationObserver
  alias RacingOrg.Tracker.Pro.DesiredState.{Manager, OperationalGate, Store}
  alias RacingOrg.Tracker.Pro.DesiredStateTestSupport, as: DS
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Store, as: CheckpointHeadStore
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.{Coordinator, Journal, RuntimeRegistry}
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.Calibration
  alias RacingOrg.Tracker.Pro.SecureTransport.{Session, SessionHolder}

  @moduletag :capture_log

  defmodule ProbeRestorer do
    def restore(%{authority: %{boat_identifier: identifier}}) do
      %{journal_path: journal_path, probe: probe, term_key: term_key} =
        :persistent_term.get({__MODULE__, identifier})

      Agent.update(probe, fn events ->
        events ++
          [
            {:restore, OperationalGate.open?(term_key), File.exists?(journal_path)}
          ]
      end)

      :ok
    end
  end

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "checkpoint_hydration_restart_#{nonce}")
    manager_name = String.to_atom("checkpoint_hydration_manager_#{nonce}")
    coordinator_name = String.to_atom("checkpoint_hydration_coordinator_#{nonce}")
    gate_name = String.to_atom("checkpoint_hydration_gate_#{nonce}")
    term_key = {__MODULE__, nonce}
    controller_capability = make_ref()
    journal_path = Path.join(base, "checkpoint_hydration.journal")
    head_store_base_dir = Path.join(base, "checkpoint_heads")
    boat_identifier = "checkpoint-hydration-restart-#{nonce}"
    identity = identity()
    head_identity = Map.take(identity, [:device_id, :credential_epoch, :storage_epoch])

    File.mkdir_p!(base)
    {:ok, probe} = Agent.start_link(fn -> [] end)
    {:ok, identity_source} = Agent.start_link(fn -> {:ready, identity} end)

    {:ok, gate_pid} =
      OperationalGate.start_link(
        name: gate_name,
        term_key: term_key,
        controller: manager_name,
        controller_capability: controller_capability
      )

    holder = start_supervised!({SessionHolder, name: nil})
    {:ok, session} = SessionHolder.publish(holder, session())

    desired_store =
      Store.new(
        base_dir: Path.join(base, "desired_state"),
        storage_epoch: DS.storage_epoch()
      )

    fixture = fully_stage(desired_store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(desired_store, 1, fixture.manifest_hash)

    hydration = hydration(boat_identifier, head_identity)
    assert :ok = Journal.write(journal_path, journal_record(fixture, session, hydration))

    {:ok, registry} = RuntimeRegistry.new([{:calibration, 2, Calibration}])

    :persistent_term.put(
      {ProbeRestorer, boat_identifier},
      %{journal_path: journal_path, probe: probe, term_key: term_key}
    )

    boundary = fn stage ->
      Agent.update(probe, fn events ->
        events ++
          [
            {:boundary, stage, OperationalGate.open?(term_key), File.exists?(journal_path)}
          ]
      end)

      :ok
    end

    manager_opts = [
      name: manager_name,
      store: desired_store,
      gate: gate_name,
      controller_capability: controller_capability,
      session_holder: holder,
      identity: fn -> next_identity(identity_source) end,
      identity_refresh_ms: 10,
      lease_heartbeat_ms: 25,
      lease_timeout_ms: 250,
      owner_retry_base_ms: 5,
      owner_retry_max_ms: 25,
      owner_resolution_timeout_ms: 100,
      checkpoint_hydration_startup_barrier: true,
      compatibility: %{firmware_version: "0.7.0", capabilities: []},
      applier: applier(probe, term_key),
      ack_sink: fn _ack -> :ok end
    ]

    coordinator_opts = [
      name: coordinator_name,
      journal_path: journal_path,
      head_store_base_dir: head_store_base_dir,
      head_store_transition_timeout_ms: 30_000,
      reconcile_empty_journal: true,
      identity: fn -> {:ok, head_identity} end,
      identity_authority: fn transition -> transition.(head_identity) end,
      coordinator_starter: fn opts ->
        Coordinator.start_link(
          Keyword.merge(opts,
            manager: manager_name,
            session_holder: holder,
            registry: registry,
            restorers: %{calibration: {ProbeRestorer, :restore}},
            manager_retry_ms: 5,
            boundary: boundary
          )
        )
      end
    ]

    children = [
      %{
        id: Manager,
        start: {Manager, :start_link, [manager_opts]},
        restart: :permanent,
        shutdown: 5_000,
        type: :worker
      },
      %{
        id: Coordinator,
        start: {TrackerApplication, :start_checkpoint_hydration, [coordinator_opts]},
        restart: :permanent,
        shutdown: 5_000,
        type: :worker
      }
    ]

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
    Process.unlink(supervisor)

    {:ok, head_store} =
      CheckpointHeadStore.new(
        base_dir: head_store_base_dir,
        device_id: head_identity.device_id,
        credential_epoch: head_identity.credential_epoch,
        storage_epoch: head_identity.storage_epoch,
        identity: fn transition -> transition.(head_identity) end,
        transition_timeout_ms: 30_000
      )

    ctx = %{
      coordinator_name: coordinator_name,
      fixture: fixture,
      gate_name: gate_name,
      gate_pid: gate_pid,
      head_store: head_store,
      hydration: hydration,
      identity: identity,
      identity_source: identity_source,
      journal_path: journal_path,
      manager_name: manager_name,
      probe: probe,
      session_generation: session.generation,
      supervisor: supervisor,
      term_key: term_key
    }

    on_exit(fn ->
      :persistent_term.erase({ProbeRestorer, boat_identifier})
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
      if Process.alive?(probe), do: Agent.stop(probe)
      if Process.alive?(identity_source), do: Agent.stop(identity_source)
      File.rm_rf(base)
    end)

    assert_converged(ctx)
    assert_initial_transition_order(ctx)
    Agent.update(probe, fn _events -> [] end)

    ctx
  end

  test "a supervised Coordinator restart reclaims the real Manager blocker", ctx do
    old_coordinator = Process.whereis(ctx.coordinator_name)
    monitor = Process.monitor(old_coordinator)
    Process.exit(old_coordinator, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^old_coordinator, :killed}
    eventually(fn -> refute OperationalGate.open?(ctx.term_key) end)

    eventually(fn ->
      replacement = Process.whereis(ctx.coordinator_name)
      assert is_pid(replacement)
      assert replacement != old_coordinator
    end)

    assert_converged(ctx)
    assert_restore_stayed_blocked(ctx)
  end

  test "a supervised Manager restart converges after transient identity unavailability", ctx do
    old_manager = Process.whereis(ctx.manager_name)
    coordinator = Process.whereis(ctx.coordinator_name)
    make_identity_temporarily_unavailable(ctx.identity_source, old_manager, ctx.identity)

    monitor = Process.monitor(old_manager)
    Process.exit(old_manager, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^old_manager, :killed}
    eventually(fn -> refute OperationalGate.open?(ctx.term_key) end)

    assert_converged(ctx)
    assert Process.whereis(ctx.coordinator_name) == coordinator
    assert Process.alive?(ctx.supervisor)
    assert_restore_stayed_blocked(ctx)
  end

  test "both processes converge when the Coordinator dies first", ctx do
    manager = Process.whereis(ctx.manager_name)
    make_identity_temporarily_unavailable(ctx.identity_source, manager, ctx.identity)
    restart_both(ctx, :coordinator_first)

    assert_converged(ctx)
    assert Process.alive?(ctx.supervisor)
    assert_restore_stayed_blocked(ctx)
  end

  test "both processes converge when the Manager dies first", ctx do
    manager = Process.whereis(ctx.manager_name)
    make_identity_temporarily_unavailable(ctx.identity_source, manager, ctx.identity)
    restart_both(ctx, :manager_first)

    assert_converged(ctx)
    assert Process.alive?(ctx.supervisor)
    assert_restore_stayed_blocked(ctx)
  end

  defp restart_both(ctx, order) do
    coordinator = Process.whereis(ctx.coordinator_name)
    manager = Process.whereis(ctx.manager_name)
    coordinator_monitor = Process.monitor(coordinator)
    manager_monitor = Process.monitor(manager)

    case order do
      :coordinator_first ->
        Process.exit(coordinator, :kill)
        assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :killed}
        Process.exit(manager, :kill)
        assert_receive {:DOWN, ^manager_monitor, :process, ^manager, :killed}

      :manager_first ->
        Process.exit(manager, :kill)
        assert_receive {:DOWN, ^manager_monitor, :process, ^manager, :killed}
        Process.exit(coordinator, :kill)
        assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :killed}
    end

    eventually(fn -> refute OperationalGate.open?(ctx.term_key) end)
  end

  defp assert_converged(ctx) do
    eventually(fn ->
      assert OperationalGate.status(ctx.gate_name) ==
               {:open, gate_binding(ctx.fixture)},
             convergence_diagnostics(ctx)

      assert OperationalGate.operational?(4, DS.storage_epoch(), ctx.term_key)
      refute File.exists?(ctx.journal_path)

      assert Coordinator.status(ctx.coordinator_name) == %{
               blocked?: false,
               phase: nil,
               recovery_error: nil
             }

      assert Manager.status(ctx.manager_name).checkpoint_hydration == %{
               state: :ready,
               binding: pointer(ctx.fixture),
               coordinator_available?: true
             }

      coordinator = Process.whereis(ctx.coordinator_name)
      manager = Process.whereis(ctx.manager_name)
      assert is_pid(coordinator)
      assert is_pid(manager)
      assert coordinator in :sys.get_state(ctx.gate_pid).dependency_pids

      assert {:ok, head} = CheckpointHeadStore.head(ctx.head_store, :calibration)
      assert head.checkpoint_hash == ctx.hydration.checkpoint_hash
      assert head.accepted
    end)
  end

  defp assert_initial_transition_order(ctx) do
    events = Agent.get(ctx.probe, & &1)

    assert {:restore, false, true} in events
    assert {:reconcile, false, pointer(ctx.fixture)} in events

    for stage <- [:before_restore, :after_restore, :before_remove] do
      assert {:boundary, stage, false, true} in events
    end

    for stage <- [:after_remove, :before_finish] do
      assert {:boundary, stage, false, false} in events
    end

    assert event_index(events, &match?({:restore, false, true}, &1)) <
             event_index(events, &match?({:boundary, :after_remove, false, false}, &1))

    assert event_index(events, &match?({:boundary, :before_finish, false, false}, &1)) <
             event_index(events, &match?({:reconcile, false, _pointer}, &1))
  end

  defp assert_restore_stayed_blocked(ctx) do
    eventually(fn ->
      restore_events =
        Enum.filter(Agent.get(ctx.probe, & &1), fn
          {:restore, _gate_open?, _journal_exists?} -> true
          _event -> false
        end)

      assert restore_events != []
      assert Enum.all?(restore_events, &match?({:restore, false, _journal_exists?}, &1))
    end)
  end

  defp make_identity_temporarily_unavailable(identity_source, old_manager, identity) do
    Agent.update(identity_source, fn _state ->
      {:until_manager_exit, old_manager, identity}
    end)
  end

  defp next_identity(identity_source) do
    Agent.get_and_update(identity_source, fn
      {:ready, identity} ->
        {{:ok, identity}, {:ready, identity}}

      {:until_manager_exit, old_manager, identity} ->
        if Process.alive?(old_manager) do
          {{:ok, identity}, {:until_manager_exit, old_manager, identity}}
        else
          errors = List.duplicate({:error, :no_verified_authority}, 7)
          {{:error, :no_verified_authority}, {:sequence, errors, identity}}
        end

      {:sequence, [result | rest], identity} ->
        next = if rest == [], do: {:ready, identity}, else: {:sequence, rest, identity}
        {result, next}
    end)
  end

  defp applier(probe, term_key) do
    owner = self()

    %{
      validate: fn _pointer, _sections, _secret, _owners -> :ok end,
      apply_non_network: fn _pointer, _sections, _owners -> :ok end,
      apply_wifi: fn _pointer, _secret, _owners -> :ok end,
      reset: fn _owners -> :ok end,
      reconcile: fn pointer, _owners ->
        Agent.update(probe, fn events ->
          events ++ [{:reconcile, OperationalGate.open?(term_key), pointer}]
        end)

        :ok
      end,
      owners: fn -> Map.new(Contract.sections(), &{&1, owner}) end
    }
  end

  defp hydration(boat_identifier, identity) do
    {:ok, observer} =
      CalibrationObserver.start_link(
        name: nil,
        sample_ms: 0,
        dir: nil,
        calibration: nil,
        boat_identifier: boat_identifier,
        sender: fn _channel, _update -> :ok end,
        now_fn: fn -> 10_000 end,
        utc_now_fn: fn -> ~U[2026-08-10 12:00:00Z] end,
        sync_ms: 60_000,
        persist_ms: 60_000,
        legs: [min_duration_s: 30.0]
      )

    {:ok, snapshot} = CalibrationObserver.snapshot(observer)
    :ok = GenServer.stop(observer)
    {:ok, wire} = Calibration.project(snapshot)
    {:ok, content} = Checkpoint.canonical_content(:calibration, 2, wire)
    {:ok, content_hash} = Checkpoint.content_hash(:calibration, 2, content)

    attrs = %{
      device_id: identity.device_id,
      credential_epoch: identity.credential_epoch,
      storage_epoch: identity.storage_epoch,
      sequence: 9,
      kind: :calibration,
      schema_version: 2,
      source_generation: 1,
      parent_hash: Record.genesis_parent(),
      content_hash: content_hash
    }

    {:ok, checkpoint_hash} = Checkpoint.hash(attrs)

    Map.merge(attrs, %{
      origin_credential_epoch: identity.credential_epoch,
      origin_storage_epoch: identity.storage_epoch,
      checkpoint_hash: checkpoint_hash,
      content: content
    })
  end

  defp journal_record(fixture, session, hydration) do
    %{
      version: 2,
      phase: :prepared,
      transaction_id: <<1::128>>,
      session_incarnation: session.session_id,
      session_generation: session.generation,
      target: pointer(fixture),
      expected_head: %{
        state: :absent,
        checkpoint_hash: Record.genesis_parent()
      },
      hydration: %{
        kind: hydration.kind,
        schema_version: hydration.schema_version,
        origin_credential_epoch: hydration.origin_credential_epoch,
        origin_storage_epoch: hydration.origin_storage_epoch,
        revision: hydration.sequence,
        source_generation: hydration.source_generation,
        parent_hash: hydration.parent_hash,
        content_hash: hydration.content_hash,
        checkpoint_hash: hydration.checkpoint_hash,
        content: hydration.content
      }
    }
  end

  defp fully_stage(store, fixture) do
    assert {:ok, _disposition} = Store.stage_manifest(store, fixture.delivery)
    Enum.each(DS.chunks(fixture), &assert({:ok, _disposition} = Store.put_chunk(store, &1)))

    assert {:ok, %{status: :staged}} =
             Store.verify_and_stage(store, fixture.binding.generation, fixture.manifest_hash)

    fixture
  end

  defp pointer(fixture) do
    %{
      device_id: fixture.binding.device_id,
      credential_epoch: fixture.binding.credential_epoch,
      storage_epoch: DS.storage_epoch(),
      generation: fixture.binding.generation,
      manifest_hash: fixture.manifest_hash
    }
  end

  defp gate_binding(fixture) do
    %{
      credential_epoch: fixture.binding.credential_epoch,
      storage_epoch: DS.storage_epoch(),
      generation: fixture.binding.generation,
      manifest_hash: fixture.manifest_hash
    }
  end

  defp identity do
    %{
      device_id: DS.device_id(),
      credential_epoch: 4,
      boot_id: DS.boot_id(),
      storage_epoch: DS.storage_epoch()
    }
  end

  defp session do
    Session.new(
      role: :initiator,
      session_id: <<1::128>>,
      epoch: 0,
      credential_epoch: 4,
      out_key: :binary.copy(<<0xAA>>, 32),
      in_key: :binary.copy(<<0xBB>>, 32)
    )
  end

  defp convergence_diagnostics(ctx) do
    inspect(
      %{
        coordinator: safe_status(fn -> Coordinator.status(ctx.coordinator_name) end),
        manager: safe_status(fn -> Manager.status(ctx.manager_name) end),
        events: Agent.get(ctx.probe, & &1),
        journal?: File.exists?(ctx.journal_path),
        supervisor: Supervisor.which_children(ctx.supervisor)
      },
      limit: :infinity,
      printable_limit: :infinity
    )
  end

  defp safe_status(callback) do
    callback.()
  catch
    :exit, reason -> {:exit, reason}
  end

  defp event_index(events, predicate) do
    Enum.find_index(events, predicate) || flunk("expected event was not recorded")
  end

  defp eventually(assertion, attempts \\ 100)

  defp eventually(assertion, attempts) when attempts > 0 do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(assertion, attempts - 1)
  catch
    :exit, _reason ->
      Process.sleep(10)
      eventually(assertion, attempts - 1)
  end

  defp eventually(assertion, 0), do: assertion.()
end
