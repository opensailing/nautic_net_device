defmodule RacingOrg.Tracker.Pro.E2E.LostStatusRecoveryTest do
  @moduledoc """
  Chained lost-status recovery scenarios across the durable-delivery stack.

  Each test drives one continuous slice over shared on-disk state:
  `DesiredState.Manager` + `DesiredState.OperationalGate` (isolated term key) +
  `CheckpointHydration.Coordinator` + `CheckpointHydration.Journal` +
  `CheckpointHead.Store` (built through
  `TrackerApplication.start_checkpoint_hydration`) + `SessionHolder`, chained
  with the `DurableDelivery.Outbox.Owner` over the same durable roots.

  Boundary: the chain stops below the secure-transport channel. A device
  restart is simulated the way `coordinator_manager_restart_test.exs` does —
  the supervised Manager/Coordinator processes and the outbox Owner are
  stopped or killed and restarted over the same on-disk state inside one BEAM,
  not by restarting the VM. Identity rebind is exercised at the
  identity-provider seam (the exact callback the transport layer feeds after a
  real re-handshake): identity sources start or become unavailable and then
  publish the old- or new-epoch identity. No Slipstream fake-backend handshake
  is performed here; the re-handshake wire flow itself is covered by
  `secure_transport/channel_client_test.exs`.
  """

  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Application, as: TrackerApplication
  alias RacingOrg.Tracker.Pro.Calibration.Observer, as: CalibrationObserver
  alias RacingOrg.Tracker.Pro.DesiredState.{Manager, OperationalGate, Store}
  alias RacingOrg.Tracker.Pro.DesiredStateTestSupport, as: DS
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Store, as: CheckpointHeadStore
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.{Coordinator, Journal, RuntimeRegistry}
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.Calibration
  alias RacingOrg.Tracker.Pro.SecureTransport.{Session, SessionHolder}

  @moduletag :capture_log
  @moduletag timeout: 120_000

  @credential_epoch 4
  @old_storage_epoch :binary.copy(<<0x31>>, 16)

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

  test "restart after volatile-status loss rebinds identity, rehydrates the accepted head, and replays the outbox exactly once" do
    ctx = new_context("volatile")
    origin = identity(DS.storage_epoch())

    # ── Phase 1: the device's durable life before the crash ─────────────────
    # Outbox: one durably resolved entry, two still pending.
    outbox = seed_outbox(ctx.outbox_root, origin, "volatile")
    assert outbox.resolved.sequence == 1
    assert outbox.keep1.storage_epoch == DS.storage_epoch()

    # An accepted checkpoint head H1 was already installed before the crash.
    calibration = build_calibration(ctx.boat_identifier)

    h1_attrs =
      checkpoint_attrs(calibration, origin, sequence: 9, source_generation: 1, parent_hash: Record.genesis_parent())

    assert {:ok, origin_store} = head_store(ctx, origin)
    assert {:ok, h1} = CheckpointHeadStore.hydrate(origin_store, store_hydrate_attrs(origin, h1_attrs))
    assert h1.accepted
    assert h1.checkpoint_hash == h1_attrs.checkpoint_hash

    # The successor hydration H2 was journaled (:prepared) but the device lost
    # all volatile state before completing it. Desired state was activated.
    h2_attrs =
      checkpoint_attrs(calibration, origin, sequence: 10, source_generation: 2, parent_hash: h1.checkpoint_hash)

    {desired_store, fixture} = stage_desired_state(ctx)

    assert :ok =
             Journal.write(
               ctx.journal_path,
               journal_record(fixture, h2_attrs, %{state: :accepted, checkpoint_hash: h1.checkpoint_hash})
             )

    # ── Phase 2: reboot over the intact durable storage ─────────────────────
    boot = boot_chain(ctx, origin, desired_store, fixture)
    assert_converged(boot, h2_attrs.checkpoint_hash)
    assert_replayed_transition_order(boot)

    assert {:ok, head} = CheckpointHeadStore.head(boot.head_store, :calibration)
    assert head.accepted
    assert head.parent_hash == h1.checkpoint_hash
    assert head.origin_credential_epoch == @credential_epoch
    assert head.origin_storage_epoch == DS.storage_epoch()
    assert head.local_storage_epoch == DS.storage_epoch()
    assert head.content == calibration.content

    # Outbox restart: the owner starts unbound, then the identity source
    # rebinds and durable replay from the (same) old origin is authorized.
    {:ok, owner_identity} = Agent.start_link(fn -> {:error, :no_verified_authority} end)
    on_exit(fn -> if Process.alive?(owner_identity), do: Agent.stop(owner_identity) end)

    assert {:ok, owner} =
             start_owner(ctx.outbox_root,
               identity: fn -> Agent.get(owner_identity, & &1) end,
               identity_refresh_ms: 10
             )

    assert %{storage_epoch_bound: false, accepting: false} = Owner.status(owner)
    assert {:error, :identity_unbound} = Owner.enqueue(owner, :telemetry, "while-unbound")

    Agent.update(owner_identity, fn _unavailable -> {:ok, bare(origin)} end)
    eventually(fn -> assert %{storage_epoch_bound: true, quarantined: false} = Owner.status(owner) end)

    # Nothing accepted was lost; the resolved entry was not resurrected.
    assert Enum.map(Owner.pending(owner), &{&1.sequence, &1.payload}) ==
             [{2, "volatile-keep-1"}, {3, "volatile-keep-2"}]

    # Not double-applied: the pre-restart resolution is durably proven.
    assert {:ok, []} = Owner.acknowledge(owner, outbox.resolved, idempotent: true)
    assert {:error, :receipt_entry_not_found} = Owner.acknowledge(owner, outbox.resolved)

    # The pre-restart receipt for a surviving entry still authorizes exactly once.
    assert {:ok, [removed]} = Owner.acknowledge(owner, outbox.keep1)
    assert removed.sequence == outbox.keep1.sequence
    assert {:ok, []} = Owner.acknowledge(owner, outbox.keep1, idempotent: true)
    assert Enum.map(Owner.pending(owner), & &1.payload) == ["volatile-keep-2"]

    # ── Phase 3: a second volatile loss with transient identity outage ──────
    assert {:ok, head_before} = CheckpointHeadStore.head(boot.head_store, :calibration)
    Agent.update(boot.probe, fn _events -> [] end)

    make_identity_temporarily_unavailable(boot)
    restart_both(boot)

    assert_converged(boot, h2_attrs.checkpoint_hash)
    assert {:ok, ^head_before} = CheckpointHeadStore.head(boot.head_store, :calibration)
    refute File.exists?(ctx.journal_path)
    assert_restore_stayed_blocked(boot)

    :ok = stop_owner(owner)
    assert {:ok, third_life} = start_owner(ctx.outbox_root, identity: fn -> {:ok, bare(origin)} end)
    assert Enum.map(Owner.pending(third_life), &{&1.sequence, &1.payload}) == [{3, "volatile-keep-2"}]
    assert {:ok, []} = Owner.acknowledge(third_life, outbox.resolved, idempotent: true)
    assert {:ok, []} = Owner.acknowledge(third_life, outbox.keep1, idempotent: true)
  end

  test "restart with a storage-epoch bump rebinds under the new epoch and replays the old origin through the existing origin authorization" do
    ctx = new_context("epoch_bump")
    old_identity = identity(@old_storage_epoch)
    new_identity = identity(DS.storage_epoch())

    # ── Phase 1: the device's durable life under the old storage epoch ──────
    outbox = seed_outbox(ctx.outbox_root, old_identity, "epoch")

    calibration = build_calibration(ctx.boat_identifier)

    old_attrs =
      checkpoint_attrs(calibration, old_identity,
        sequence: 9,
        source_generation: 1,
        parent_hash: Record.genesis_parent()
      )

    assert {:ok, old_store} = head_store(ctx, old_identity)
    assert {:ok, old_head} = CheckpointHeadStore.hydrate(old_store, store_hydrate_attrs(old_identity, old_attrs))
    assert old_head.accepted
    assert old_head.origin_storage_epoch == @old_storage_epoch

    # ── Phase 2: reboot after storage loss bumped the storage epoch ─────────
    # The surviving head is fenced for the new epoch, never silently adopted.
    assert {:ok, new_store} = head_store(ctx, new_identity)

    assert {:ok, %{state: :fenced, checkpoint_hash: fenced_hash}} =
             CheckpointHeadStore.observe_target_head(new_store, :calibration)

    assert fenced_hash == old_head.checkpoint_hash

    # The backend re-delivered the same old-origin checkpoint; the device
    # journaled it against the fenced observation and then lost volatile state.
    {desired_store, fixture} = stage_desired_state(ctx)

    assert :ok =
             Journal.write(
               ctx.journal_path,
               journal_record(fixture, old_attrs, %{state: :fenced, checkpoint_hash: old_head.checkpoint_hash})
             )

    boot = boot_chain(ctx, new_identity, desired_store, fixture)
    assert_converged(boot, old_attrs.checkpoint_hash)
    assert_replayed_transition_order(boot)

    # The exact old-origin checkpoint is re-established as the accepted head
    # under the new epoch, through the origin identity fields only.
    assert {:ok, head} = CheckpointHeadStore.head(boot.head_store, :calibration)
    assert head.accepted
    assert head.checkpoint_hash == old_head.checkpoint_hash
    assert head.origin_credential_epoch == @credential_epoch
    assert head.origin_storage_epoch == @old_storage_epoch
    assert head.local_storage_epoch == DS.storage_epoch()
    assert head.content == calibration.content

    # Outbox: the old-origin root refuses adoption under the bumped epoch.
    assert {:error, :storage_epoch_mismatch} =
             start_owner(ctx.outbox_root, identity: fn -> {:ok, bare(new_identity)} end)

    # Deferred rebind under the new epoch preserves the root in stable quarantine.
    {:ok, owner_identity} = Agent.start_link(fn -> {:error, :no_verified_authority} end)
    on_exit(fn -> if Process.alive?(owner_identity), do: Agent.stop(owner_identity) end)

    assert {:ok, quarantined} =
             start_owner(ctx.outbox_root,
               identity: fn -> Agent.get(owner_identity, & &1) end,
               identity_refresh_ms: 10
             )

    assert {:error, :identity_unbound} = Owner.enqueue(quarantined, :telemetry, "while-unbound")
    Agent.update(owner_identity, fn _unavailable -> {:ok, bare(new_identity)} end)

    eventually(fn ->
      assert %{quarantined: true, storage_epoch_bound: false, pending_entries: :unavailable} =
               Owner.status(quarantined)
    end)

    assert {:error, :quarantined} = Owner.enqueue(quarantined, :telemetry, "new-epoch-entry")
    :ok = stop_owner(quarantined)

    # Nothing accepted was lost: the old-origin entries remain intact and
    # exactly-once under their recorded origin identity.
    assert {:ok, old_owner} = start_owner(ctx.outbox_root, identity: fn -> {:ok, bare(old_identity)} end)

    assert Enum.map(Owner.pending(old_owner), &{&1.sequence, &1.payload}) ==
             [{2, "epoch-keep-1"}, {3, "epoch-keep-2"}]

    assert {:ok, []} = Owner.acknowledge(old_owner, outbox.resolved, idempotent: true)
    assert {:error, :receipt_entry_not_found} = Owner.acknowledge(old_owner, outbox.resolved)

    # ── Phase 3: another volatile loss under the new epoch ──────────────────
    assert {:ok, head_before} = CheckpointHeadStore.head(boot.head_store, :calibration)
    Agent.update(boot.probe, fn _events -> [] end)

    make_identity_temporarily_unavailable(boot)
    restart_both(boot)

    assert_converged(boot, old_attrs.checkpoint_hash)
    assert {:ok, ^head_before} = CheckpointHeadStore.head(boot.head_store, :calibration)
    refute File.exists?(ctx.journal_path)
    assert_restore_stayed_blocked(boot)
  end

  # ── Context and durable-state helpers ─────────────────────────────────────

  defp new_context(label) do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "lost_status_recovery_#{label}_#{nonce}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    %{
      nonce: nonce,
      base: base,
      journal_path: Path.join(base, "checkpoint_hydration.journal"),
      head_store_base_dir: Path.join(base, "checkpoint_heads"),
      outbox_root: Path.join(base, "outbox"),
      desired_state_dir: Path.join(base, "desired_state"),
      boat_identifier: "lost-status-#{label}-#{nonce}",
      manager_name: :"lost_status_manager_#{label}_#{nonce}",
      coordinator_name: :"lost_status_coordinator_#{label}_#{nonce}",
      gate_name: :"lost_status_gate_#{label}_#{nonce}",
      term_key: {__MODULE__, label, nonce}
    }
  end

  defp identity(storage_epoch) do
    %{
      device_id: DS.device_id(),
      credential_epoch: @credential_epoch,
      boot_id: DS.boot_id(),
      storage_epoch: storage_epoch
    }
  end

  defp bare(identity), do: Map.take(identity, [:device_id, :credential_epoch, :storage_epoch])

  defp seed_outbox(root, identity, prefix) do
    assert {:ok, owner} = start_owner(root, identity: fn -> {:ok, bare(identity)} end)
    assert {:ok, resolved} = Owner.enqueue(owner, :telemetry, "#{prefix}-resolved")
    assert {:ok, keep1} = Owner.enqueue(owner, :telemetry, "#{prefix}-keep-1")
    assert {:ok, keep2} = Owner.enqueue(owner, :telemetry, "#{prefix}-keep-2")
    assert {:ok, [_removed]} = Owner.acknowledge(owner, resolved)
    assert Enum.map(Owner.pending(owner), & &1.sequence) == [keep1.sequence, keep2.sequence]
    :ok = stop_owner(owner)
    %{resolved: resolved, keep1: keep1, keep2: keep2}
  end

  defp build_calibration(boat_identifier) do
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
    %{content: content, content_hash: content_hash}
  end

  defp checkpoint_attrs(calibration, origin, opts) do
    attrs = %{
      device_id: origin.device_id,
      credential_epoch: origin.credential_epoch,
      storage_epoch: origin.storage_epoch,
      sequence: Keyword.fetch!(opts, :sequence),
      kind: :calibration,
      schema_version: 2,
      source_generation: Keyword.fetch!(opts, :source_generation),
      parent_hash: Keyword.fetch!(opts, :parent_hash),
      content_hash: calibration.content_hash
    }

    {:ok, checkpoint_hash} = Checkpoint.hash(attrs)

    Map.merge(attrs, %{
      origin_credential_epoch: origin.credential_epoch,
      origin_storage_epoch: origin.storage_epoch,
      checkpoint_hash: checkpoint_hash,
      content: calibration.content
    })
  end

  defp store_hydrate_attrs(addressed, attrs) do
    %{
      device_id: addressed.device_id,
      credential_epoch: addressed.credential_epoch,
      storage_epoch: addressed.storage_epoch,
      origin_credential_epoch: attrs.origin_credential_epoch,
      origin_storage_epoch: attrs.origin_storage_epoch,
      kind: attrs.kind,
      schema_version: attrs.schema_version,
      sequence: attrs.sequence,
      source_generation: attrs.source_generation,
      parent_hash: attrs.parent_hash,
      content: attrs.content,
      checkpoint_hash: attrs.checkpoint_hash
    }
  end

  defp head_store(ctx, identity) do
    head_identity = bare(identity)

    CheckpointHeadStore.new(
      base_dir: ctx.head_store_base_dir,
      device_id: head_identity.device_id,
      credential_epoch: head_identity.credential_epoch,
      storage_epoch: head_identity.storage_epoch,
      identity: fn transition -> transition.(head_identity) end,
      transition_timeout_ms: 30_000
    )
  end

  defp stage_desired_state(ctx) do
    desired_store =
      Store.new(
        base_dir: ctx.desired_state_dir,
        storage_epoch: DS.storage_epoch()
      )

    fixture = DS.generation_fixture()
    assert {:ok, _disposition} = Store.stage_manifest(desired_store, fixture.delivery)
    Enum.each(DS.chunks(fixture), &assert({:ok, _disposition} = Store.put_chunk(desired_store, &1)))

    assert {:ok, %{status: :staged}} =
             Store.verify_and_stage(desired_store, fixture.binding.generation, fixture.manifest_hash)

    assert {:ok, nil} = Store.activate(desired_store, fixture.binding.generation, fixture.manifest_hash)
    {desired_store, fixture}
  end

  # The journal was written by the pre-restart incarnation: its session values
  # belong to the session that died with the device. Replay must not depend on
  # them, so they intentionally differ from the freshly published boot session.
  defp journal_record(fixture, attrs, expected_head) do
    %{
      version: 2,
      phase: :prepared,
      transaction_id: <<1::128>>,
      session_incarnation: <<1::128>>,
      session_generation: 1,
      target: pointer(fixture),
      expected_head: expected_head,
      hydration: %{
        kind: attrs.kind,
        schema_version: attrs.schema_version,
        origin_credential_epoch: attrs.origin_credential_epoch,
        origin_storage_epoch: attrs.origin_storage_epoch,
        revision: attrs.sequence,
        source_generation: attrs.source_generation,
        parent_hash: attrs.parent_hash,
        content_hash: attrs.content_hash,
        checkpoint_hash: attrs.checkpoint_hash,
        content: attrs.content
      }
    }
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

  # ── The rebooted process chain ────────────────────────────────────────────

  defp boot_chain(ctx, identity, desired_store, fixture) do
    controller_capability = make_ref()
    head_identity = bare(identity)

    {:ok, probe} = Agent.start_link(fn -> [] end)
    {:ok, identity_source} = Agent.start_link(fn -> {:ready, identity} end)

    {:ok, gate_pid} =
      OperationalGate.start_link(
        name: ctx.gate_name,
        term_key: ctx.term_key,
        controller: ctx.manager_name,
        controller_capability: controller_capability
      )

    holder = start_supervised!({SessionHolder, name: nil})
    {:ok, session} = SessionHolder.publish(holder, session())

    {:ok, registry} = RuntimeRegistry.new([{:calibration, 2, Calibration}])

    :persistent_term.put(
      {ProbeRestorer, ctx.boat_identifier},
      %{journal_path: ctx.journal_path, probe: probe, term_key: ctx.term_key}
    )

    boundary = fn stage ->
      Agent.update(probe, fn events ->
        events ++
          [
            {:boundary, stage, OperationalGate.open?(ctx.term_key), File.exists?(ctx.journal_path)}
          ]
      end)

      :ok
    end

    manager_opts = [
      name: ctx.manager_name,
      store: desired_store,
      gate: ctx.gate_name,
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
      applier: applier(probe, ctx.term_key),
      ack_sink: fn _ack -> :ok end
    ]

    coordinator_opts = [
      name: ctx.coordinator_name,
      journal_path: ctx.journal_path,
      head_store_base_dir: ctx.head_store_base_dir,
      head_store_transition_timeout_ms: 30_000,
      reconcile_empty_journal: true,
      identity: fn ->
        case next_identity(identity_source) do
          {:ok, identity} -> {:ok, Map.take(identity, [:device_id, :credential_epoch, :storage_epoch])}
          {:error, _reason} = error -> error
        end
      end,
      identity_authority: fn transition -> transition.(head_identity) end,
      coordinator_starter: fn opts ->
        Coordinator.start_link(
          Keyword.merge(opts,
            manager: ctx.manager_name,
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

    # Production tolerance for a Coordinator whose child start requires the
    # shared durable identity: repeated start failures during a transient
    # authority outage must not exhaust restart intensity before recovery.
    {:ok, supervisor} =
      Supervisor.start_link(children, strategy: :one_for_one, max_restarts: 100, max_seconds: 5)

    Process.unlink(supervisor)

    {:ok, head_store} = head_store(ctx, identity)

    on_exit(fn ->
      :persistent_term.erase({ProbeRestorer, ctx.boat_identifier})
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
      if Process.alive?(gate_pid), do: GenServer.stop(gate_pid)
      if Process.alive?(probe), do: Agent.stop(probe)
      if Process.alive?(identity_source), do: Agent.stop(identity_source)
    end)

    Map.merge(ctx, %{
      fixture: fixture,
      gate_pid: gate_pid,
      head_store: head_store,
      identity: identity,
      identity_source: identity_source,
      probe: probe,
      session_generation: session.generation,
      supervisor: supervisor
    })
  end

  defp session do
    Session.new(
      role: :initiator,
      session_id: <<2::128>>,
      epoch: 0,
      credential_epoch: @credential_epoch,
      out_key: :binary.copy(<<0xAA>>, 32),
      in_key: :binary.copy(<<0xBB>>, 32)
    )
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

  defp make_identity_temporarily_unavailable(boot) do
    manager = Process.whereis(boot.manager_name)
    assert is_pid(manager)

    Agent.update(boot.identity_source, fn _state ->
      {:until_manager_exit, manager, boot.identity}
    end)
  end

  defp restart_both(boot) do
    coordinator = Process.whereis(boot.coordinator_name)
    manager = Process.whereis(boot.manager_name)
    coordinator_monitor = Process.monitor(coordinator)
    manager_monitor = Process.monitor(manager)

    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :killed}
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^manager_monitor, :process, ^manager, :killed}

    eventually(fn -> refute OperationalGate.open?(boot.term_key) end)
  end

  # ── Convergence and ordering assertions ───────────────────────────────────

  defp assert_converged(boot, expected_checkpoint_hash) do
    eventually(
      fn ->
        assert OperationalGate.status(boot.gate_name) == {:open, gate_binding(boot.fixture)},
               convergence_diagnostics(boot)

        assert OperationalGate.operational?(@credential_epoch, DS.storage_epoch(), boot.term_key)
        refute File.exists?(boot.journal_path)

        assert Coordinator.status(boot.coordinator_name) == %{
                 blocked?: false,
                 phase: nil,
                 recovery_error: nil
               }

        assert Manager.status(boot.manager_name).checkpoint_hydration == %{
                 state: :ready,
                 binding: pointer(boot.fixture),
                 coordinator_available?: true
               }

        coordinator = Process.whereis(boot.coordinator_name)
        manager = Process.whereis(boot.manager_name)
        assert is_pid(coordinator)
        assert is_pid(manager)
        assert coordinator in :sys.get_state(boot.gate_pid).dependency_pids

        assert {:ok, head} = CheckpointHeadStore.head(boot.head_store, :calibration)
        assert head.checkpoint_hash == expected_checkpoint_hash
        assert head.accepted
      end,
      300
    )
  end

  defp assert_replayed_transition_order(boot) do
    events = Agent.get(boot.probe, & &1)

    assert {:restore, false, true} in events
    assert {:reconcile, false, pointer(boot.fixture)} in events

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

  defp assert_restore_stayed_blocked(boot) do
    eventually(fn ->
      restore_events =
        Enum.filter(Agent.get(boot.probe, & &1), fn
          {:restore, _gate_open?, _journal_exists?} -> true
          _event -> false
        end)

      assert restore_events != []
      assert Enum.all?(restore_events, &match?({:restore, false, _journal_exists?}, &1))
    end)
  end

  defp convergence_diagnostics(boot) do
    inspect(
      %{
        coordinator: safe_status(fn -> Coordinator.status(boot.coordinator_name) end),
        manager: safe_status(fn -> Manager.status(boot.manager_name) end),
        events: Agent.get(boot.probe, & &1),
        journal?: File.exists?(boot.journal_path),
        supervisor: Supervisor.which_children(boot.supervisor)
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

  # ── Outbox owner lifecycle helpers ────────────────────────────────────────

  defp start_owner(root, overrides) do
    opts =
      Keyword.merge(
        [
          root: root,
          streams: [:telemetry, :health],
          max_entries: 10,
          max_bytes: 10_000,
          segment_max_bytes: 4_096
        ],
        overrides
      )

    # A failed init/1 exits the linked caller, so trap exits around start_link
    # and normalize the {:error, reason} the tests assert on.
    previous = Process.flag(:trap_exit, true)

    try do
      case Owner.start_link(opts) do
        {:ok, pid} = result ->
          on_exit(fn -> stop_owner(pid) end)
          result

        {:error, reason} ->
          flush_exit()
          {:error, reason}
      end
    after
      Process.flag(:trap_exit, previous)
    end
  end

  # Monitor before signalling: an already-dead process still delivers :DOWN, so
  # this stays correct whether or not the owner is alive on entry.
  defp stop_owner(owner) do
    reference = Process.monitor(owner)
    Process.unlink(owner)
    Process.exit(owner, :shutdown)

    receive do
      {:DOWN, ^reference, :process, _pid, _reason} -> :ok
    after
      5_000 -> {:error, :timeout}
    end
  end

  defp flush_exit do
    receive do
      {:EXIT, _pid, _reason} -> :ok
    after
      0 -> :ok
    end
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
