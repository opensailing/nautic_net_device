defmodule RacingOrg.Tracker.Pro.DesiredState.ManagerTest do
  @moduledoc """
  Contract suite for the desired-state runtime `Manager`.

  The manager is the single authority that turns delivered desired-state bytes into
  an effective generation. Every collaborator it needs is injected so the observable
  call sequence — gate closure, owner validation, non-network apply, the atomic
  pointer commit, the bounded Wi-Fi trial, and only then the effective ACK and gate
  opening — is asserted from the outside instead of from private state.

  The logical desired-state identity (16-byte device ID, credential epoch, boot ID,
  storage epoch) is injected as its own authority. It is never inferred from the live
  `Session`, whose fingerprint binds an operational key rather than the logical device.
  `SessionHolder` supplies only the mutation fence: a durable mutation may proceed only
  while the caller-supplied session generation is still current.
  """

  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DesiredState.{Manager, OperationalGate, Store}
  alias RacingOrg.Tracker.Pro.DesiredStateTestSupport, as: DS
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Messages
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem
  alias RacingOrg.Tracker.Pro.SecureTransport.{Session, SessionHolder}
  alias RacingOrg.Tracker.Pro.WiFiManager.Secret

  defmodule OwnerReferenceRegistry do
    def whereis_name({registry, name}) do
      Agent.get(registry, fn entries ->
        entries |> Map.fetch!(name) |> elem(0)
      end)
    end

    def authority_snapshot({registry, name}) do
      Agent.get(registry, fn entries ->
        {owner_pid, incarnation_pid} = Map.fetch!(entries, name)
        {:ok, owner_pid, incarnation_pid}
      end)
    end
  end

  defmodule SequencedOwnerRegistry do
    def start_link(owner_pids), do: Agent.start_link(fn -> owner_pids end)

    def whereis_name(registry) do
      Agent.get_and_update(registry, fn
        [owner_pid, next_owner_pid | rest] -> {owner_pid, [next_owner_pid | rest]}
        [owner_pid] -> {owner_pid, [owner_pid]}
      end)
    end

    def authority_snapshot(registry) do
      owner_pid = Agent.get(registry, &List.first/1)
      {:ok, owner_pid, registry}
    end
  end

  defmodule BlockingReferenceRegistry do
    def start_link(listener, resolved_pid) do
      Agent.start_link(fn -> %{listener: listener, resolved_pid: resolved_pid} end)
    end

    def whereis_name(registry) do
      %{listener: listener, resolved_pid: resolved_pid} = Agent.get(registry, & &1)
      send(listener, {:manager_reference_resolution_blocked, self()})

      receive do
        :continue_reference_resolution -> resolved_pid
      end
    end
  end

  defmodule PathFaultFileSystem do
    @behaviour FileSystem

    def fault(operation, path, timing),
      do: :persistent_term.put({__MODULE__, operation, path}, timing)

    def clear(operation, path),
      do: :persistent_term.erase({__MODULE__, operation, path})

    def rename(source, destination) do
      case :persistent_term.get({__MODULE__, :rename, destination}, :none) do
        :before ->
          {:error, :path_fault}

        :after ->
          with :ok <- FileSystem.rename(source, destination), do: {:error, :path_fault}

        :none ->
          FileSystem.rename(source, destination)
      end
    end

    def remove(path) do
      case :persistent_term.get({__MODULE__, :remove, path}, :none) do
        :before ->
          {:error, :path_fault}

        :after ->
          with :ok <- FileSystem.remove(path), do: {:error, :path_fault}

        :none ->
          FileSystem.remove(path)
      end
    end

    def read(path) do
      case :persistent_term.get({__MODULE__, :read, path}, :none) do
        :before ->
          {:error, :path_fault}

        :after ->
          with {:ok, _bytes} <- FileSystem.read(path), do: {:error, :path_fault}

        :none ->
          FileSystem.read(path)
      end
    end

    defdelegate mkdir_p(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
  end

  setup do
    base = Path.join(System.tmp_dir!(), "desired_manager_#{System.unique_integer([:positive])}")
    term_key = {__MODULE__, make_ref()}
    gate_name = {:global, {__MODULE__, term_key}}
    manager_name = {:global, {__MODULE__, term_key, :manager}}
    controller_capability = make_ref()

    {:ok, gate_pid} =
      OperationalGate.start_link(
        name: gate_name,
        term_key: term_key,
        controller: manager_name,
        controller_capability: controller_capability
      )

    holder = start_supervised!({SessionHolder, name: nil})
    {:ok, session} = SessionHolder.publish(holder, session(<<1::128>>))

    on_exit(fn ->
      case :global.whereis_name({__MODULE__, term_key}) do
        pid when is_pid(pid) -> GenServer.stop(pid)
        :undefined -> :ok
      end

      :persistent_term.erase(term_key)
      File.rm_rf(base)
    end)

    %{
      base: base,
      store: Store.new(base_dir: base, storage_epoch: DS.storage_epoch()),
      gate: gate_name,
      gate_pid: gate_pid,
      manager_name: manager_name,
      controller_capability: controller_capability,
      term_key: term_key,
      holder: holder,
      session_generation: session.generation
    }
  end

  test "startup replays only current-identity ACKs without deleting unreceipted prior identities", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)

    current_ack = effective_ack(prior)
    prior_boot_ack = Map.put(current_ack, :boot_id, <<0x99::128>>)
    foreign_device_ack = Map.put(current_ack, :device_id, <<0x98::128>>)
    foreign_epoch_ack = Map.put(current_ack, :credential_epoch, 99)

    assert {:ok, :stored} = Store.put_pending_ack(ctx.store, current_ack)
    assert {:ok, :stored} = Store.put_pending_ack(ctx.store, prior_boot_ack)
    assert {:ok, :stored} = Store.put_pending_ack(ctx.store, foreign_device_ack)
    assert {:ok, :stored} = Store.put_pending_ack(ctx.store, foreign_epoch_ack)

    assert {:error, :storage_epoch_mismatch} =
             Store.put_pending_ack(ctx.store, Map.put(current_ack, :storage_epoch, <<0x97::128>>))

    pid = start_manager(ctx)

    assert_receive {:applier, :reconcile, reconcile}
    assert reconcile.pointer == pointer(prior)
    refute reconcile.gate_open?

    assert_receive {:ack, ^current_ack, _meta}
    refute_receive {:ack, ^prior_boot_ack, _meta}
    refute_receive {:ack, ^foreign_device_ack, _meta}
    refute_receive {:ack, ^foreign_epoch_ack, _meta}

    assert {:ok, retained_acks} = Store.pending_acks(ctx.store)

    assert MapSet.new(retained_acks) ==
             MapSet.new([current_ack, prior_boot_ack, foreign_device_ack, foreign_epoch_ack])

    assert OperationalGate.status(ctx.gate) == {:open, gate_binding(prior)}
    assert OperationalGate.operational?(4, DS.storage_epoch(), ctx.term_key)
    assert Manager.status(pid).active == pointer(prior)
  end

  test "startup rolls an interrupted activation back when the Wi-Fi owner did not commit the candidate", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 2, candidate.manifest_hash)
    assert {:ok, _prior} = Store.commit_activation(ctx.store)

    test_pid = self()
    candidate_pointer = pointer(candidate)

    recovering_applier =
      ctx
      |> applier()
      |> Map.put(:reconcile, fn pointer, _owner_pid_map ->
        send(test_pid, {:applier, :reconcile, snapshot(ctx, pointer, nil, nil)})

        if pointer == candidate_pointer,
          do: {:error, {:apply_failed, :wifi, :wifi_activation_mismatch}},
          else: :ok
      end)

    start_manager(ctx, applier: recovering_applier)

    assert_receive {:applier, :reconcile, candidate_probe}
    assert candidate_probe.pointer == candidate_pointer

    assert_receive {:applier, :reconcile, prior_reconcile}
    assert prior_reconcile.pointer == pointer(prior)
    assert prior_reconcile.active == pointer(prior)

    rejected =
      rejected_ack(candidate,
        phase: :wifi_trial,
        error_code: :wifi_trial_failed,
        retryable: true,
        section: section_identity(candidate, :wifi)
      )

    assert_receive {:ack, ^rejected, rejected_meta}
    assert rejected_meta.active == pointer(prior)
    assert Store.activation_journal(ctx.store) == :empty
    assert OperationalGate.status(ctx.gate) == {:open, gate_binding(prior)}
  end

  test "startup finalizes an interrupted activation after the Wi-Fi owner committed the candidate", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 2, candidate.manifest_hash)
    assert {:ok, _prior} = Store.commit_activation(ctx.store)

    start_manager(ctx)

    assert_receive {:applier, :reconcile, candidate_probe}
    assert candidate_probe.pointer == pointer(candidate)

    assert_receive {:ack, %{status: :effective}, effective_meta}
    assert effective_meta.active == pointer(candidate)
    refute_receive {:applier, :reconcile, _duplicate_reconcile}
    assert Store.activation_journal(ctx.store) == :empty
    assert OperationalGate.status(ctx.gate) == {:open, gate_binding(candidate)}
  end

  test "startup makes the candidate pointer authoritative before reporting interrupted recovery effective", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 2, candidate.manifest_hash)

    start_manager(ctx)

    assert_receive {:applier, :reconcile, candidate_probe}
    assert candidate_probe.pointer == pointer(candidate)

    assert_receive {:ack, %{status: :effective}, effective_meta}
    assert effective_meta.active == pointer(candidate)

    eventually(fn ->
      assert Store.activation_journal(ctx.store) == :empty
      assert Store.active(ctx.store) == {:ok, pointer(candidate)}
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(candidate)}
    end)
  end

  test "a failed startup reconcile keeps the gate closed and preserves the active generation", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)

    start_manager(ctx, applier: applier(ctx, fail: %{reconcile: {:error, :owner_unavailable}}))

    assert_receive {:applier, :reconcile, _reconcile}
    assert OperationalGate.status(ctx.gate) == :closed
    refute OperationalGate.open?(ctx.term_key)
    assert {:ok, active} = Store.active(ctx.store)
    assert active == pointer(prior)
  end

  test "startup preserves active-pointer read errors and retries with capped backoff", ctx do
    store =
      Store.new(
        base_dir: ctx.base,
        storage_epoch: DS.storage_epoch(),
        file_system: PathFaultFileSystem
      )

    active = fully_stage(store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(store, 1, active.manifest_hash)

    active_path = Store.active_pointer_path(store)
    PathFaultFileSystem.fault(:read, active_path, :before)
    on_exit(fn -> PathFaultFileSystem.clear(:read, active_path) end)

    pid =
      start_manager(ctx,
        store: store,
        owner_retry_base_ms: 10_000,
        owner_retry_max_ms: 40_000
      )

    refute_receive {:applier, :reconcile, _reconcile}
    assert OperationalGate.status(ctx.gate) == :closed

    assert Manager.status(pid).active == {:error, {:read, :path_fault}}

    first_retry = :sys.get_state(pid)
    assert first_retry.recovery_error == {:active_pointer_read, {:read, :path_fault}}
    assert first_retry.owner_retry_attempt == 1
    assert first_retry.owner_retry_delay_ms == 10_000
    assert is_reference(first_retry.owner_retry_token)
    assert is_reference(first_retry.owner_retry_ref)

    assert Process.cancel_timer(first_retry.owner_retry_ref) != false
    send(pid, {:reconcile_authoritative_owners, first_retry.owner_retry_token})
    second_retry = :sys.get_state(pid)
    assert second_retry.owner_retry_attempt == 2
    assert second_retry.owner_retry_delay_ms == 20_000

    assert Process.cancel_timer(second_retry.owner_retry_ref) != false
    send(pid, {:reconcile_authoritative_owners, second_retry.owner_retry_token})
    capped_retry = :sys.get_state(pid)
    assert capped_retry.owner_retry_attempt == 3
    assert capped_retry.owner_retry_delay_ms == 40_000

    assert Process.cancel_timer(capped_retry.owner_retry_ref) != false
    send(pid, {:reconcile_authoritative_owners, capped_retry.owner_retry_token})
    still_capped = :sys.get_state(pid)
    assert still_capped.owner_retry_attempt == 4
    assert still_capped.owner_retry_delay_ms == 40_000

    PathFaultFileSystem.clear(:read, active_path)
    assert Process.cancel_timer(still_capped.owner_retry_ref) != false
    send(pid, {:reconcile_authoritative_owners, still_capped.owner_retry_token})

    assert_receive {:applier, :reconcile, reconcile}, 1_000
    assert reconcile.pointer == pointer(active)

    eventually(fn ->
      state = :sys.get_state(pid)
      assert state.recovery_error == nil
      assert state.owner_retry_ref == nil
      assert state.owner_retry_token == nil
      assert state.owner_retry_attempt == 0
      assert state.owner_retry_delay_ms == nil
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(active)}
    end)
  end

  test "startup preserves activation-journal read errors until a retry succeeds", ctx do
    store =
      Store.new(
        base_dir: ctx.base,
        storage_epoch: DS.storage_epoch(),
        file_system: PathFaultFileSystem
      )

    active = fully_stage(store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(store, 1, active.manifest_hash)

    activation_path = Store.activation_journal_path(store)
    PathFaultFileSystem.fault(:read, activation_path, :before)
    on_exit(fn -> PathFaultFileSystem.clear(:read, activation_path) end)

    pid =
      start_manager(ctx,
        store: store,
        owner_retry_base_ms: 10_000,
        owner_retry_max_ms: 40_000
      )

    refute_receive {:applier, :reconcile, _reconcile}
    assert Store.activation_journal(store) == {:error, {:read, :path_fault}}
    assert OperationalGate.status(ctx.gate) == :closed

    retry = :sys.get_state(pid)
    assert retry.recovery_error == {:activation_journal_read, {:read, :path_fault}}
    assert retry.owner_retry_attempt == 1
    assert retry.owner_retry_delay_ms == 10_000

    PathFaultFileSystem.clear(:read, activation_path)
    assert Process.cancel_timer(retry.owner_retry_ref) != false
    send(pid, {:reconcile_authoritative_owners, retry.owner_retry_token})

    assert_receive {:applier, :reconcile, reconcile}, 1_000
    assert reconcile.pointer == pointer(active)

    eventually(fn ->
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(active)}
      assert :sys.get_state(pid).recovery_error == nil
    end)
  end

  test "startup retries a selected activation manifest read failure", ctx do
    store =
      Store.new(
        base_dir: ctx.base,
        storage_epoch: DS.storage_epoch(),
        file_system: PathFaultFileSystem
      )

    candidate = fully_stage(store, DS.generation_fixture())
    assert {:ok, _journal} = Store.prepare_activation(store, 1, candidate.manifest_hash)
    effective = effective_ack(candidate)
    assert :ok = Store.record_activation_decision(store, :candidate, effective)

    manifest_path = Store.manifest_path(store, 1, candidate.manifest_hash)
    PathFaultFileSystem.fault(:read, manifest_path, :before)
    on_exit(fn -> PathFaultFileSystem.clear(:read, manifest_path) end)

    assert {:error, {:read_activation_manifest, :path_fault}} =
             Store.activation_journal(store)

    pid =
      start_manager(ctx,
        store: store,
        owner_retry_base_ms: 10_000,
        owner_retry_max_ms: 40_000
      )

    refute_receive {:applier, :reconcile, _reconcile}
    refute_receive {:ack, ^effective, _meta}
    assert OperationalGate.status(ctx.gate) == :closed

    retry = :sys.get_state(pid)
    refute retry.recovery_quiescent?

    assert retry.recovery_error ==
             {:activation_journal_read, {:read_activation_manifest, :path_fault}}

    assert retry.owner_retry_attempt == 1
    assert retry.owner_retry_delay_ms == 10_000

    PathFaultFileSystem.clear(:read, manifest_path)
    assert Process.cancel_timer(retry.owner_retry_ref) != false
    send(pid, {:reconcile_authoritative_owners, retry.owner_retry_token})

    assert_receive {:applier, :reconcile, recovered}, 1_000
    assert recovered.pointer == pointer(candidate)
    assert recovered.active == pointer(candidate)
    assert_receive {:ack, ^effective, effective_meta}, 1_000
    assert effective_meta.active == pointer(candidate)

    eventually(fn ->
      assert Store.activation_journal(store) == :empty
      assert Store.active(store) == {:ok, pointer(candidate)}
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(candidate)}
      assert :sys.get_state(pid).recovery_error == nil
    end)
  end

  test "startup never mutates owners for a foreign activation candidate", ctx do
    foreign_device_id = <<0x77::128>>
    foreign = fully_stage(ctx.store, DS.generation_fixture(device_id: foreign_device_id))
    assert {:ok, %{prior: nil}} = Store.prepare_activation(ctx.store, 1, foreign.manifest_hash)
    assert {:ok, nil} = Store.commit_activation(ctx.store)

    terminal_ack = Map.put(effective_ack(foreign), :device_id, foreign_device_id)
    assert :ok = Store.record_activation_decision(ctx.store, :candidate, terminal_ack)

    pid = start_manager(ctx)

    refute_receive {:applier, :reconcile, _reconcile}
    refute_receive {:applier, :reset, _reset}
    refute_receive {:ack, ^terminal_ack, _meta}
    assert OperationalGate.status(ctx.gate) == :closed

    assert {:ok, %{decision: :candidate, terminal_ack: ^terminal_ack}} =
             Store.activation_journal(ctx.store)

    state = :sys.get_state(pid)
    assert state.recovery_error == {:activation_identity_mismatch, :device_mismatch}
    assert state.owner_retry_ref == nil
    assert state.owner_retry_token == nil
  end

  test "an undecided superseded activation rolls back without emitting its stale rejection", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 2, candidate.manifest_hash)
    assert {:ok, _prior} = Store.commit_activation(ctx.store)

    stale_rejected =
      rejected_ack(candidate,
        phase: :activation,
        error_code: :activation_failed,
        retryable: false,
        section: nil
      )

    current_identity = Map.put(identity(), :credential_epoch, 7)
    pid = start_manager(ctx, identity: current_identity)

    assert_receive {:applier, :reconcile, rollback}, 1_000
    assert rollback.pointer == pointer(prior)
    assert rollback.active == pointer(prior)
    refute rollback.gate_open?
    refute_receive {:ack, ^stale_rejected, _meta}

    eventually(fn ->
      assert Store.activation_journal(ctx.store) == :empty
      assert Store.active(ctx.store) == {:ok, pointer(prior)}
      assert {:ok, [^stale_rejected]} = Store.pending_acks(ctx.store)
      assert OperationalGate.status(ctx.gate) == :closed
    end)

    {:ok, current_session} = SessionHolder.publish(ctx.holder, session(<<2::128>>, 7))
    current = DS.generation_fixture(generation: 3, credential_epoch: 7)
    deliver_generation(pid, current, current_session.generation)

    assert_receive {:ack, %{status: :staged, credential_epoch: 7}, _meta}
    assert_receive {:ack, %{status: :effective, credential_epoch: 7}, _meta}

    eventually(fn ->
      assert Store.active(ctx.store) == {:ok, pointer(current)}
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(current)}
    end)
  end

  test "startup never opens an active generation from a former credential epoch", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)

    current_identity = Map.put(identity(), :credential_epoch, 5)
    pid = start_manager(ctx, identity: current_identity)

    refute_receive {:applier, :reconcile, _reconcile}
    assert OperationalGate.status(ctx.gate) == :closed
    refute OperationalGate.open?(ctx.term_key)
    assert Manager.status(pid).identity == current_identity
    assert {:ok, active} = Store.active(ctx.store)
    assert active == pointer(prior)
  end

  test "a deferred authority provider opens only after exact identity resolves and closes on epoch advance", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)

    authority =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> {:error, :no_verified_authority} end},
          id: make_ref()
        )
      )

    identity_provider = fn -> Agent.get(authority, & &1) end

    pid =
      start_manager(ctx,
        identity: identity_provider,
        identity_refresh_ms: 10
      )

    assert Manager.status(pid).identity == nil
    assert OperationalGate.status(ctx.gate) == :closed
    refute_receive {:applier, :reconcile, _reconcile}

    Agent.update(authority, fn _current -> {:ok, identity()} end)

    assert_receive {:applier, :reconcile, reconcile}, 500
    assert reconcile.pointer == pointer(prior)

    eventually(fn ->
      assert Manager.status(pid).identity == identity()
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(prior)}
    end)

    next_identity = Map.put(identity(), :credential_epoch, 5)
    Agent.update(authority, fn _current -> {:ok, next_identity} end)

    eventually(fn ->
      assert Manager.status(pid).identity == next_identity
      assert OperationalGate.status(ctx.gate) == :closed
      refute OperationalGate.open?(ctx.term_key)
    end)
  end

  test "manifest delivery is fenced on exact identity and session generation before durable mutation", ctx do
    pid = start_manager(ctx)
    fixture = DS.generation_fixture()

    fenced = [
      {Map.put(fixture.delivery, :device_id, <<0x99::128>>), :device_mismatch},
      {Map.put(fixture.delivery, :credential_epoch, 5), :credential_epoch_mismatch},
      {Map.put(fixture.delivery, :boot_id, <<0x99::128>>), :boot_id_mismatch},
      {Map.put(fixture.delivery, :storage_epoch, <<0x99::128>>), :storage_epoch_mismatch}
    ]

    Enum.each(fenced, fn {delivery, reason} ->
      assert {:error, ^reason} = Manager.deliver_manifest(pid, ctx.session_generation, delivery)
    end)

    assert {:error, :stale_session} = Manager.deliver_manifest(pid, stale(ctx), fixture.delivery)
    assert :empty = Store.generation_state(ctx.store, 1, fixture.manifest_hash)
    refute File.exists?(Store.generation_directory(ctx.store, 1, fixture.manifest_hash))
  end

  test "every section chunk is fenced on the same identity and session generation", ctx do
    pid = start_manager(ctx)
    fixture = DS.generation_fixture()
    assert {:ok, :staged} = Manager.deliver_manifest(pid, ctx.session_generation, fixture.delivery)
    chunk = hd(DS.chunks_for_section(fixture.binding, fixture.sections_by_name.tracking))

    fenced = [
      {Map.put(chunk, :device_id, <<0x99::128>>), :device_mismatch},
      {Map.put(chunk, :credential_epoch, 5), :credential_epoch_mismatch},
      {Map.put(chunk, :boot_id, <<0x99::128>>), :boot_id_mismatch},
      {Map.put(chunk, :storage_epoch, <<0x99::128>>), :storage_epoch_mismatch}
    ]

    Enum.each(fenced, fn {payload, reason} ->
      assert {:error, ^reason} = Manager.deliver_chunk(pid, ctx.session_generation, payload)
    end)

    assert {:error, :stale_session} = Manager.deliver_chunk(pid, stale(ctx), chunk)
    refute File.exists?(Store.chunk_path(ctx.store, 1, fixture.manifest_hash, :tracking, 0))
    assert {:ok, %{received: received}} = Store.generation_state(ctx.store, 1, fixture.manifest_hash)
    assert received == %{}
  end

  test "a transient chunk read failure stays retryable and emits no rejected transfer ACK", ctx do
    store =
      Store.new(
        base_dir: ctx.base,
        storage_epoch: DS.storage_epoch(),
        file_system: PathFaultFileSystem
      )

    pid = start_manager(ctx, store: store)
    fixture = DS.generation_fixture()
    chunks = DS.chunks(fixture)
    initial_chunks = Enum.drop(chunks, -1)
    final_chunk = List.last(chunks)
    faulted_chunk = hd(initial_chunks)

    assert {:ok, :staged} =
             Manager.deliver_manifest(pid, ctx.session_generation, fixture.delivery)

    Enum.each(initial_chunks, fn chunk ->
      assert {:ok, :stored} =
               Manager.deliver_chunk(pid, ctx.session_generation, chunk)
    end)

    faulted_path =
      Store.chunk_path(
        store,
        fixture.binding.generation,
        fixture.manifest_hash,
        faulted_chunk.section,
        faulted_chunk.chunk_index
      )

    PathFaultFileSystem.fault(:read, faulted_path, :before)
    on_exit(fn -> PathFaultFileSystem.clear(:read, faulted_path) end)

    assert {:error, {:storage_failed, {:read_chunk, :path_fault}}} =
             Manager.deliver_chunk(pid, ctx.session_generation, final_chunk)

    assert {:ok, %{status: :receiving}} =
             Store.generation_state(
               store,
               fixture.binding.generation,
               fixture.manifest_hash
             )

    assert Store.pending_acks(store) == {:ok, []}
    refute_receive {:ack, %{status: :rejected}, _meta}
    refute_receive {:applier, _operation, _snapshot}

    PathFaultFileSystem.clear(:read, faulted_path)

    assert {:ok, :unchanged} =
             Manager.deliver_chunk(pid, ctx.session_generation, final_chunk)

    assert_receive {:ack, %{status: :staged}, _meta}
    assert_receive {:ack, %{status: :effective}, _meta}
    refute_receive {:ack, %{status: :rejected}, _meta}
    assert Store.active(store) == {:ok, pointer(fixture)}
  end

  test "activation validates all nine, applies non-network owners, commits the pointer, then runs Wi-Fi last", ctx do
    pid = start_manager(ctx)
    fixture = DS.generation_fixture()

    deliver_generation(pid, fixture, ctx.session_generation)

    staged = staged_ack(fixture)
    effective = effective_ack(fixture)
    assert_receive {:ack, ^staged, _staged_meta}

    assert_receive {:applier, :validate, validate}
    assert validate.pointer == pointer(fixture)
    assert validate.sections == Enum.sort(Contract.sections())
    refute validate.gate_open?
    assert validate.active == nil

    assert_receive {:applier, :apply_non_network, non_network}
    refute non_network.gate_open?
    assert non_network.active == nil

    assert_receive {:applier, :apply_wifi, wifi}
    refute wifi.gate_open?
    assert wifi.active == pointer(fixture)

    assert_receive {:ack, ^effective, effective_meta}
    assert effective_meta.active == pointer(fixture)

    assert Store.activation_journal(ctx.store) == :empty
    assert OperationalGate.status(ctx.gate) == {:open, gate_binding(fixture)}
    assert {:ok, [^staged, ^effective]} = Store.pending_acks(ctx.store)
    assert {:ok, _bytes} = Messages.encode(:ack, effective)
  end

  test "a durable staged ACK allows activation to continue when its immediate send fails", ctx do
    pid = start_manager(ctx, ack_sink: ack_sink(ctx, fail_status: :staged))
    fixture = DS.generation_fixture()

    deliver_generation(pid, fixture, ctx.session_generation)

    staged = staged_ack(fixture)
    effective = effective_ack(fixture)
    assert_receive {:ack, ^staged, staged_meta}
    refute staged_meta.gate_open?
    assert_receive {:ack, ^effective, effective_meta}
    assert effective_meta.active == pointer(fixture)

    assert Store.activation_journal(ctx.store) == :empty
    assert {:ok, active} = Store.active(ctx.store)
    assert active == pointer(fixture)
    assert OperationalGate.status(ctx.gate) == {:open, gate_binding(fixture)}
    assert {:ok, [^staged, ^effective]} = Store.pending_acks(ctx.store)
  end

  test "a durable effective ACK keeps the committed generation active when its immediate send fails", ctx do
    pid = start_manager(ctx, ack_sink: ack_sink(ctx, fail_status: :effective))
    fixture = DS.generation_fixture()

    deliver_generation(pid, fixture, ctx.session_generation)

    staged = staged_ack(fixture)
    effective = effective_ack(fixture)
    assert_receive {:ack, ^staged, _staged_meta}
    assert_receive {:ack, ^effective, effective_meta}
    assert effective_meta.active == pointer(fixture)
    refute_receive {:ack, %{status: :rejected}, _meta}
    refute_receive {:applier, :reconcile, _rollback}

    assert Store.activation_journal(ctx.store) == :empty
    assert {:ok, active} = Store.active(ctx.store)
    assert active == pointer(fixture)
    assert OperationalGate.status(ctx.gate) == {:open, gate_binding(fixture)}
    assert {:ok, [^staged, ^effective]} = Store.pending_acks(ctx.store)
  end

  test "an effective ACK storage failure keeps the decided candidate recoverable", ctx do
    store =
      Store.new(
        base_dir: ctx.base,
        storage_epoch: DS.storage_epoch(),
        file_system: PathFaultFileSystem
      )

    pending_acks_path = Store.pending_acks_path(store)
    on_exit(fn -> PathFaultFileSystem.clear(:rename, pending_acks_path) end)
    test_pid = self()

    applier =
      ctx
      |> applier()
      |> Map.put(:apply_wifi, fn pointer, secret, _owner_pid_map ->
        send(test_pid, {:applier, :apply_wifi, snapshot(ctx, pointer, [:wifi], secret)})
        PathFaultFileSystem.fault(:rename, pending_acks_path, :before)
        :ok
      end)

    pid = start_manager(ctx, store: store, applier: applier)
    fixture = DS.generation_fixture()
    deliver_generation(pid, fixture, ctx.session_generation)

    assert_receive {:ack, %{status: :staged}, _meta}
    assert_receive {:applier, :apply_wifi, _wifi}
    refute_receive {:ack, %{status: :effective}, _meta}
    refute_receive {:ack, %{status: :rejected}, _meta}

    assert {:ok, journal} = Store.activation_journal(store)
    assert journal.candidate == pointer(fixture)
    assert {:ok, active} = Store.active(store)
    assert active == pointer(fixture)
    assert OperationalGate.status(ctx.gate) == :closed

    PathFaultFileSystem.clear(:rename, pending_acks_path)

    assert_receive {:ack, %{status: :effective}, effective_meta}, 1_000
    assert effective_meta.active == pointer(fixture)

    eventually(fn ->
      assert Store.activation_journal(store) == :empty
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(fixture)}
    end)
  end

  test "an effective decision write failure keeps the undecided journal recoverable", ctx do
    store =
      Store.new(
        base_dir: ctx.base,
        storage_epoch: DS.storage_epoch(),
        file_system: PathFaultFileSystem
      )

    activation_path = Store.activation_journal_path(store)
    on_exit(fn -> PathFaultFileSystem.clear(:rename, activation_path) end)
    test_pid = self()

    applier =
      ctx
      |> applier()
      |> Map.put(:apply_wifi, fn pointer, secret, _owner_pid_map ->
        send(test_pid, {:applier, :apply_wifi, snapshot(ctx, pointer, [:wifi], secret)})
        PathFaultFileSystem.fault(:rename, activation_path, :before)
        :ok
      end)

    pid = start_manager(ctx, store: store, applier: applier)
    fixture = DS.generation_fixture()
    deliver_generation(pid, fixture, ctx.session_generation)

    assert_receive {:ack, %{status: :staged}, _meta}
    assert_receive {:applier, :apply_wifi, _wifi}
    refute_receive {:ack, %{status: :effective}, _meta}
    refute_receive {:ack, %{status: :rejected}, _meta}

    assert {:ok, journal} = Store.activation_journal(store)
    assert journal.candidate == pointer(fixture)
    assert journal.decision == nil
    assert journal.terminal_ack == nil
    assert Store.active(store) == {:ok, pointer(fixture)}
    assert OperationalGate.status(ctx.gate) == :closed

    PathFaultFileSystem.clear(:rename, activation_path)

    assert_receive {:ack, %{status: :effective}, effective_meta}, 1_000
    assert effective_meta.active == pointer(fixture)

    eventually(fn ->
      assert Store.activation_journal(store) == :empty
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(fixture)}
    end)
  end

  test "an activation journal cleanup failure retains the durable candidate outcome", ctx do
    store =
      Store.new(
        base_dir: ctx.base,
        storage_epoch: DS.storage_epoch(),
        file_system: PathFaultFileSystem
      )

    activation_path = Store.activation_journal_path(store)
    on_exit(fn -> PathFaultFileSystem.clear(:remove, activation_path) end)
    test_pid = self()

    applier =
      ctx
      |> applier()
      |> Map.put(:apply_wifi, fn pointer, secret, _owner_pid_map ->
        send(test_pid, {:applier, :apply_wifi, snapshot(ctx, pointer, [:wifi], secret)})
        PathFaultFileSystem.fault(:remove, activation_path, :before)
        :ok
      end)

    pid = start_manager(ctx, store: store, applier: applier)
    fixture = DS.generation_fixture()
    deliver_generation(pid, fixture, ctx.session_generation)

    staged = staged_ack(fixture)
    effective = effective_ack(fixture)
    assert_receive {:ack, ^staged, _meta}
    assert_receive {:applier, :apply_wifi, _wifi}
    refute_receive {:ack, ^effective, _meta}
    refute_receive {:ack, %{status: :rejected}, _meta}

    assert {:ok, %{decision: :candidate, terminal_ack: ^effective}} =
             Store.activation_journal(store)

    assert Store.active(store) == {:ok, pointer(fixture)}
    assert {:ok, [^staged, ^effective]} = Store.pending_acks(store)
    assert OperationalGate.status(ctx.gate) == :closed

    PathFaultFileSystem.clear(:remove, activation_path)

    assert_receive {:ack, ^effective, effective_meta}, 1_000
    assert effective_meta.active == pointer(fixture)

    eventually(fn ->
      assert Store.activation_journal(store) == :empty
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(fixture)}
    end)
  end

  test "a candidate decision from a prior boot rebinds its effective ACK and converges", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 2, candidate.manifest_hash)

    prior_boot_ack = effective_ack(candidate)
    assert :ok = Store.record_activation_decision(ctx.store, :candidate, prior_boot_ack)

    current_boot_id = <<0x55::128>>
    current_identity = Map.put(identity(), :boot_id, current_boot_id)
    current_ack = Map.put(prior_boot_ack, :boot_id, current_boot_id)
    start_manager(ctx, identity: current_identity)

    assert_receive {:applier, :reconcile, recovery}, 1_000
    assert recovery.pointer == pointer(candidate)
    assert recovery.active == pointer(candidate)

    assert_receive {:ack, ^current_ack, effective_meta}, 1_000
    assert effective_meta.active == pointer(candidate)
    refute_receive {:ack, ^prior_boot_ack, _meta}

    eventually(fn ->
      assert Store.activation_journal(ctx.store) == :empty
      assert Store.active(ctx.store) == {:ok, pointer(candidate)}
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(candidate)}
    end)
  end

  test "a prior decision from a prior boot rebinds its rejected ACK after durable rollback", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 2, candidate.manifest_hash)
    assert {:ok, _prior} = Store.commit_activation(ctx.store)

    prior_boot_ack =
      rejected_ack(candidate,
        phase: :wifi_trial,
        error_code: :wifi_trial_failed,
        retryable: true,
        section: section_identity(candidate, :wifi)
      )

    assert :ok = Store.record_activation_decision(ctx.store, :prior, prior_boot_ack)
    File.rm_rf!(Store.generation_directory(ctx.store, 2, candidate.manifest_hash))
    assert {:error, :active_generation_missing} = Store.active(ctx.store)

    current_boot_id = <<0x66::128>>
    current_identity = Map.put(identity(), :boot_id, current_boot_id)
    current_ack = Map.put(prior_boot_ack, :boot_id, current_boot_id)
    start_manager(ctx, identity: current_identity)

    assert_receive {:applier, :reconcile, rollback}, 1_000
    assert rollback.pointer == pointer(prior)
    assert rollback.active == pointer(prior)

    assert_receive {:ack, ^current_ack, rejected_meta}, 1_000
    assert rejected_meta.active == pointer(prior)
    refute_receive {:ack, ^prior_boot_ack, _meta}

    eventually(fn ->
      assert Store.activation_journal(ctx.store) == :empty
      assert Store.active(ctx.store) == {:ok, pointer(prior)}
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(prior)}
    end)
  end

  test "a decided candidate from a superseded credential epoch retires without a stale ACK", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 2, candidate.manifest_hash)

    stale_ack = effective_ack(candidate)
    assert :ok = Store.record_activation_decision(ctx.store, :candidate, stale_ack)

    current_identity = Map.put(identity(), :credential_epoch, 7)
    pid = start_manager(ctx, identity: current_identity)

    assert_receive {:applier, :reconcile, recovery}, 1_000
    assert recovery.pointer == pointer(candidate)
    assert recovery.active == pointer(candidate)
    refute_receive {:ack, ^stale_ack, _meta}

    eventually(fn ->
      assert Store.activation_journal(ctx.store) == :empty
      assert Store.active(ctx.store) == {:ok, pointer(candidate)}
      assert OperationalGate.status(ctx.gate) == :closed
      assert {:ok, [^stale_ack]} = Store.pending_acks(ctx.store)
    end)

    {:ok, current_session} = SessionHolder.publish(ctx.holder, session(<<2::128>>, 7))
    current = DS.generation_fixture(generation: 3, credential_epoch: 7)
    deliver_generation(pid, current, current_session.generation)

    assert_receive {:ack, %{status: :staged, credential_epoch: 7}, _meta}
    assert_receive {:ack, %{status: :effective, credential_epoch: 7}, _meta}

    eventually(fn ->
      assert Store.active(ctx.store) == {:ok, pointer(current)}
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(current)}
    end)
  end

  test "a decided rollback from a superseded credential epoch retires after restoring prior owners", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 2, candidate.manifest_hash)
    assert {:ok, _prior} = Store.commit_activation(ctx.store)

    stale_ack =
      rejected_ack(candidate,
        phase: :wifi_trial,
        error_code: :wifi_trial_failed,
        retryable: true,
        section: section_identity(candidate, :wifi)
      )

    assert :ok = Store.record_activation_decision(ctx.store, :prior, stale_ack)

    current_identity = Map.put(identity(), :credential_epoch, 7)
    start_manager(ctx, identity: current_identity)

    assert_receive {:applier, :reconcile, rollback}, 1_000
    assert rollback.pointer == pointer(prior)
    assert rollback.active == pointer(prior)
    refute_receive {:ack, ^stale_ack, _meta}

    eventually(fn ->
      assert Store.activation_journal(ctx.store) == :empty
      assert Store.active(ctx.store) == {:ok, pointer(prior)}
      assert OperationalGate.status(ctx.gate) == :closed
      assert {:ok, [^stale_ack]} = Store.pending_acks(ctx.store)
    end)
  end

  test "a superseded decided rollback retires after its unselected candidate bytes are gone", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 2, candidate.manifest_hash)
    assert {:ok, _prior} = Store.commit_activation(ctx.store)

    stale_ack =
      rejected_ack(candidate,
        phase: :wifi_trial,
        error_code: :wifi_trial_failed,
        retryable: true,
        section: section_identity(candidate, :wifi)
      )

    assert :ok = Store.record_activation_decision(ctx.store, :prior, stale_ack)
    File.rm_rf!(Store.generation_directory(ctx.store, 2, candidate.manifest_hash))
    assert {:error, :active_generation_missing} = Store.active(ctx.store)

    start_manager(ctx, identity: Map.put(identity(), :credential_epoch, 7))

    assert_receive {:applier, :reconcile, rollback}, 1_000
    assert rollback.pointer == pointer(prior)
    assert rollback.active == pointer(prior)
    refute rollback.gate_open?
    refute_receive {:ack, ^stale_ack, _meta}

    eventually(fn ->
      assert Store.activation_journal(ctx.store) == :empty
      assert Store.active(ctx.store) == {:ok, pointer(prior)}
      assert Store.pending_acks(ctx.store) == {:ok, [stale_ack]}
      assert OperationalGate.status(ctx.gate) == :closed
    end)
  end

  test "a tampered decided rollback quiesces without mutating owners or emitting its ACK", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 2, candidate.manifest_hash)
    assert {:ok, _prior} = Store.commit_activation(ctx.store)

    rejected =
      rejected_ack(candidate,
        phase: :activation,
        error_code: :activation_failed,
        retryable: false,
        section: nil
      )

    assert :ok = Store.record_activation_decision(ctx.store, :prior, rejected)
    assert {:ok, decided} = Store.activation_journal(ctx.store)

    foreign_ack = Map.put(rejected, :device_id, <<0x77::128>>)
    tampered = %{decided | terminal_ack: foreign_ack}

    File.write!(
      Store.activation_journal_path(ctx.store),
      :erlang.term_to_binary({1, :activation_journal, tampered})
    )

    File.rm_rf!(Store.generation_directory(ctx.store, 2, candidate.manifest_hash))

    pid = start_manager(ctx, identity: Map.put(identity(), :credential_epoch, 7))

    refute_receive {:applier, :reconcile, _rollback}
    refute_receive {:applier, :reset, _reset}
    refute_receive {:ack, ^foreign_ack, _meta}

    state = :sys.get_state(pid)
    assert state.recovery_quiescent?
    assert state.owner_retry_ref == nil
    assert state.owner_retry_token == nil

    assert state.recovery_error ==
             {:activation_journal_invalid, :corrupt_activation_journal}

    assert File.exists?(Store.activation_journal_path(ctx.store))
    assert Store.pending_acks(ctx.store) == {:ok, []}
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "a first-generation rollback without candidate authority quiesces before owner reset", ctx do
    candidate = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, %{prior: nil}} = Store.prepare_activation(ctx.store, 1, candidate.manifest_hash)
    assert {:ok, nil} = Store.commit_activation(ctx.store)

    rejected =
      rejected_ack(candidate,
        phase: :activation,
        error_code: :activation_failed,
        retryable: false,
        section: nil
      )

    assert :ok = Store.record_activation_decision(ctx.store, :prior, rejected)
    File.rm_rf!(Store.generation_directory(ctx.store, 1, candidate.manifest_hash))

    pid = start_manager(ctx)

    refute_receive {:applier, :reset, _reset}
    refute_receive {:applier, :reconcile, _reconcile}
    refute_receive {:ack, ^rejected, _meta}

    state = :sys.get_state(pid)
    assert state.recovery_quiescent?
    assert state.owner_retry_ref == nil

    assert state.recovery_error ==
             {:activation_journal_invalid, :corrupt_activation_journal}

    assert File.exists?(Store.activation_journal_path(ctx.store))
    assert Store.pending_acks(ctx.store) == {:ok, []}
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "a superseded rollback pointer failure preserves its decision and retries without a stale ACK", ctx do
    store =
      Store.new(
        base_dir: ctx.base,
        storage_epoch: DS.storage_epoch(),
        file_system: PathFaultFileSystem
      )

    prior = fully_stage(store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(store, 1, prior.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(store, 2, candidate.manifest_hash)
    assert {:ok, _prior} = Store.commit_activation(store)

    stale_rejected =
      rejected_ack(candidate,
        phase: :activation,
        error_code: :activation_failed,
        retryable: false,
        section: nil
      )

    active_path = Store.active_pointer_path(store)
    PathFaultFileSystem.fault(:rename, active_path, :before)
    on_exit(fn -> PathFaultFileSystem.clear(:rename, active_path) end)

    pid =
      start_manager(ctx,
        store: store,
        identity: Map.put(identity(), :credential_epoch, 7),
        owner_retry_base_ms: 10_000,
        owner_retry_max_ms: 40_000
      )

    refute_receive {:applier, :reconcile, _rollback}
    refute_receive {:ack, ^stale_rejected, _meta}
    assert Store.active(store) == {:ok, pointer(candidate)}
    assert Store.pending_acks(store) == {:ok, []}

    assert {:ok, %{decision: :prior, terminal_ack: ^stale_rejected}} =
             Store.activation_journal(store)

    retry = :sys.get_state(pid)

    assert match?(
             {:superseded_activation_retirement, {:rename, :path_fault}},
             retry.recovery_error
           )

    assert retry.owner_retry_attempt == 1
    assert retry.owner_retry_delay_ms == 10_000

    PathFaultFileSystem.clear(:rename, active_path)
    assert Process.cancel_timer(retry.owner_retry_ref) != false
    send(pid, {:reconcile_authoritative_owners, retry.owner_retry_token})

    assert_receive {:applier, :reconcile, rollback}, 1_000
    assert rollback.pointer == pointer(prior)
    assert rollback.active == pointer(prior)
    refute rollback.gate_open?
    refute_receive {:ack, ^stale_rejected, _meta}

    eventually(fn ->
      state = :sys.get_state(pid)
      assert Store.activation_journal(store) == :empty
      assert Store.active(store) == {:ok, pointer(prior)}
      assert Store.pending_acks(store) == {:ok, [stale_rejected]}
      assert OperationalGate.status(ctx.gate) == :closed
      assert state.owner_retry_attempt == 0
      assert state.owner_retry_ref == nil
      assert state.recovery_error == nil
    end)
  end

  test "a failed prior-owner reconcile retains the terminal decision and retries before ACK", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 2, candidate.manifest_hash)
    assert {:ok, _prior} = Store.commit_activation(ctx.store)

    rejected =
      rejected_ack(candidate,
        phase: :wifi_trial,
        error_code: :wifi_trial_failed,
        retryable: true,
        section: section_identity(candidate, :wifi)
      )

    assert :ok = Store.record_activation_decision(ctx.store, :prior, rejected)

    reconcile_result =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> {:error, :owner_unavailable} end},
          id: make_ref()
        )
      )

    test_pid = self()

    recovering_applier =
      ctx
      |> applier()
      |> Map.put(:reconcile, fn pointer, _owner_pid_map ->
        result = Agent.get(reconcile_result, & &1)
        send(test_pid, {:prior_reconcile_attempt, result, snapshot(ctx, pointer, nil, nil)})
        result
      end)

    pid =
      start_manager(ctx,
        applier: recovering_applier,
        owner_retry_base_ms: 10_000,
        owner_retry_max_ms: 40_000
      )

    assert_receive {:prior_reconcile_attempt, {:error, :owner_unavailable}, failed}, 1_000
    assert failed.pointer == pointer(prior)
    assert failed.active == pointer(prior)
    refute failed.gate_open?
    refute_receive {:ack, ^rejected, _meta}
    assert Store.pending_acks(ctx.store) == {:ok, []}

    assert {:ok, %{decision: :prior, terminal_ack: ^rejected}} =
             Store.activation_journal(ctx.store)

    retry = :sys.get_state(pid)
    assert retry.recovery_error == {:activation_recovery_failed, :owner_unavailable}
    assert retry.owner_retry_attempt == 1
    assert retry.owner_retry_delay_ms == 10_000

    Agent.update(reconcile_result, fn _result -> :ok end)
    assert Process.cancel_timer(retry.owner_retry_ref) != false
    send(pid, {:reconcile_authoritative_owners, retry.owner_retry_token})

    assert_receive {:prior_reconcile_attempt, :ok, successful}, 1_000
    assert successful.pointer == pointer(prior)
    assert successful.active == pointer(prior)
    refute successful.gate_open?

    assert_receive {:ack, ^rejected, rejected_meta}, 1_000
    assert rejected_meta.active == pointer(prior)

    eventually(fn ->
      state = :sys.get_state(pid)
      assert Store.activation_journal(ctx.store) == :empty
      assert Store.pending_acks(ctx.store) == {:ok, [rejected]}
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(prior)}
      assert state.owner_retry_attempt == 0
      assert state.owner_retry_ref == nil
      assert state.recovery_error == nil
    end)
  end

  test "a rejected ACK storage failure retains prior pointer and terminal decision", ctx do
    store =
      Store.new(
        base_dir: ctx.base,
        storage_epoch: DS.storage_epoch(),
        file_system: PathFaultFileSystem
      )

    prior = fully_stage(store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(store, 1, prior.manifest_hash)
    pending_acks_path = Store.pending_acks_path(store)
    on_exit(fn -> PathFaultFileSystem.clear(:rename, pending_acks_path) end)
    test_pid = self()

    applier =
      ctx
      |> applier()
      |> Map.put(:apply_wifi, fn pointer, secret, _owner_pid_map ->
        send(test_pid, {:applier, :apply_wifi, snapshot(ctx, pointer, [:wifi], secret)})
        PathFaultFileSystem.fault(:rename, pending_acks_path, :before)
        {:error, {:apply_failed, :wifi, :confirmation_timeout}}
      end)

    pid = start_manager(ctx, store: store, applier: applier)
    assert_receive {:applier, :reconcile, startup}
    assert startup.pointer == pointer(prior)

    candidate = DS.generation_fixture(generation: 2)
    deliver_generation(pid, candidate, ctx.session_generation)

    rejected =
      rejected_ack(candidate,
        phase: :wifi_trial,
        error_code: :wifi_trial_failed,
        retryable: true,
        section: section_identity(candidate, :wifi)
      )

    assert_receive {:ack, %{status: :staged}, _meta}
    assert_receive {:applier, :apply_wifi, _wifi}
    assert_receive {:applier, :reconcile, rollback}
    assert rollback.pointer == pointer(prior)
    assert rollback.active == pointer(prior)
    refute_receive {:ack, ^rejected, _meta}
    refute_receive {:ack, %{status: :effective}, _meta}

    assert {:ok, %{decision: :prior, terminal_ack: ^rejected}} =
             Store.activation_journal(store)

    assert Store.active(store) == {:ok, pointer(prior)}
    assert OperationalGate.status(ctx.gate) == :closed

    PathFaultFileSystem.clear(:rename, pending_acks_path)

    assert_receive {:ack, ^rejected, rejected_meta}, 1_000
    assert rejected_meta.active == pointer(prior)

    eventually(fn ->
      assert Store.activation_journal(store) == :empty
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(prior)}
    end)
  end

  test "a durable prior decision fences candidate retransmission while terminal ACK storage retries", ctx do
    store =
      Store.new(
        base_dir: ctx.base,
        storage_epoch: DS.storage_epoch(),
        file_system: PathFaultFileSystem
      )

    prior = fully_stage(store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(store, 1, prior.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(store, 2, candidate.manifest_hash)

    rejected =
      rejected_ack(candidate,
        phase: :wifi_trial,
        error_code: :wifi_trial_failed,
        retryable: true,
        section: section_identity(candidate, :wifi)
      )

    assert :ok = Store.record_activation_decision(store, :prior, rejected)
    assert {:ok, :stored} = Store.put_pending_ack(store, staged_ack(candidate))

    pending_acks_path = Store.pending_acks_path(store)
    PathFaultFileSystem.fault(:rename, pending_acks_path, :before)
    on_exit(fn -> PathFaultFileSystem.clear(:rename, pending_acks_path) end)

    pid = start_manager(ctx, store: store)
    assert_receive {:applier, :reconcile, prior_reconcile}
    assert prior_reconcile.pointer == pointer(prior)

    deliver_generation(pid, candidate, ctx.session_generation)

    refute_receive {:applier, :apply_non_network, _candidate}
    refute_receive {:applier, :apply_wifi, _candidate}
    refute_receive {:ack, ^rejected, _meta}
    assert {:ok, %{decision: :prior, terminal_ack: ^rejected}} = Store.activation_journal(store)
    assert Store.active(store) == {:ok, pointer(prior)}
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "indeterminate Wi-Fi authority keeps the activation journal until owner reconciliation decides", ctx do
    {:ok, reconcile_result} = Agent.start_link(fn -> {:error, :owner_unavailable} end)
    test_pid = self()

    applier =
      ctx
      |> applier()
      |> Map.put(:apply_wifi, fn pointer, secret, _owner_pid_map ->
        send(test_pid, {:applier, :apply_wifi, snapshot(ctx, pointer, [:wifi], secret)})
        {:error, {:apply_failed, :wifi, :wifi_authority_indeterminate}}
      end)
      |> Map.put(:reconcile, fn pointer, _owner_pid_map ->
        result = Agent.get(reconcile_result, & &1)
        send(test_pid, {:wifi_reconcile_attempt, pointer, result})
        result
      end)

    pid = start_manager(ctx, applier: applier)
    fixture = DS.generation_fixture()
    deliver_generation(pid, fixture, ctx.session_generation)

    staged = staged_ack(fixture)
    effective = effective_ack(fixture)
    assert_receive {:ack, ^staged, _staged_meta}
    assert_receive {:applier, :apply_wifi, wifi}
    assert wifi.active == pointer(fixture)
    refute_receive {:ack, %{status: :rejected}, _meta}
    refute_receive {:ack, ^effective, _meta}

    assert {:ok, %{candidate: candidate}} = Store.activation_journal(ctx.store)
    assert candidate == pointer(fixture)
    assert {:ok, active} = Store.active(ctx.store)
    assert active == pointer(fixture)
    assert OperationalGate.status(ctx.gate) == :closed

    assert_receive {:wifi_reconcile_attempt, ^candidate, {:error, :owner_unavailable}}, 1_000
    Agent.update(reconcile_result, fn _current -> :ok end)

    assert_receive {:wifi_reconcile_attempt, ^candidate, :ok}, 1_000
    assert_receive {:ack, ^effective, _meta}, 1_000
    refute_receive {:wifi_reconcile_attempt, ^candidate, :ok}

    eventually(fn ->
      assert Store.activation_journal(ctx.store) == :empty
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(fixture)}
    end)
  end

  test "a Wi-Fi failure restores and reopens the prior generation after authoritative reconciliation", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)

    pid =
      start_manager(ctx,
        applier:
          applier(ctx,
            fail: %{apply_wifi: {:error, {:apply_failed, :wifi, :confirmation_timeout}}}
          )
      )

    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)

    candidate = DS.generation_fixture(generation: 2)
    deliver_generation(pid, candidate, ctx.session_generation)

    assert_receive {:applier, :apply_wifi, wifi}
    assert wifi.active == pointer(candidate)

    rejected =
      rejected_ack(candidate,
        phase: :wifi_trial,
        error_code: :wifi_trial_failed,
        retryable: true,
        section: section_identity(candidate, :wifi)
      )

    assert_receive {:ack, ^rejected, rejected_meta}
    assert rejected_meta.active == pointer(prior)

    assert_receive {:applier, :reconcile, rollback}
    assert rollback.pointer == pointer(prior)
    assert rollback.active == pointer(prior)
    refute rollback.gate_open?

    assert_receive {:applier, :reconcile, reopen}, 1_000
    assert reopen.pointer == pointer(prior)
    assert reopen.active == pointer(prior)
    refute reopen.gate_open?

    eventually(fn ->
      assert Store.activation_journal(ctx.store) == :empty
      assert Store.active(ctx.store) == {:ok, pointer(prior)}
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(prior)}
    end)

    assert {:ok, _bytes} = Messages.encode(:ack, rejected)
  end

  test "a validation rejection reopens the unchanged prior generation", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)

    failure = {:error, {:validation_failed, :tracking, :invalid_tracking}}
    pid = start_manager(ctx, applier: applier(ctx, fail: %{validate: failure}))

    assert_receive {:applier, :reconcile, startup}
    assert startup.pointer == pointer(prior)
    assert OperationalGate.status(ctx.gate) == {:open, gate_binding(prior)}

    candidate = DS.generation_fixture(generation: 2)
    deliver_generation(pid, candidate, ctx.session_generation)

    rejected =
      rejected_ack(candidate,
        phase: :staging,
        error_code: :section_validation_failed,
        retryable: false,
        section: section_identity(candidate, :tracking)
      )

    assert_receive {:ack, ^rejected, rejected_meta}
    refute rejected_meta.gate_open?
    assert rejected_meta.active == pointer(prior)
    refute_receive {:applier, :apply_non_network, _candidate}

    assert_receive {:applier, :reconcile, reopened}, 1_000
    assert reopened.pointer == pointer(prior)
    assert reopened.active == pointer(prior)
    refute reopened.gate_open?

    eventually(fn ->
      assert Store.active(ctx.store) == {:ok, pointer(prior)}
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(prior)}
    end)
  end

  test "a first rejected activation resets owner authority before persisting its terminal ACK", ctx do
    pid =
      start_manager(ctx,
        applier:
          applier(ctx,
            fail: %{apply_wifi: {:error, {:apply_failed, :wifi, :confirmation_timeout}}}
          )
      )

    candidate = DS.generation_fixture()
    deliver_generation(pid, candidate, ctx.session_generation)

    staged = staged_ack(candidate)

    rejected =
      rejected_ack(candidate,
        phase: :wifi_trial,
        error_code: :wifi_trial_failed,
        retryable: true,
        section: section_identity(candidate, :wifi)
      )

    assert_receive {:ack, ^staged, _meta}
    assert_receive {:applier, :apply_wifi, wifi}
    assert wifi.active == pointer(candidate)

    assert_receive {:applier, :reset, reset}
    refute reset.gate_open?
    assert reset.active == nil

    assert {:ok,
            %{
              prior: nil,
              candidate: candidate_pointer,
              decision: :prior,
              terminal_ack: ^rejected
            }} = reset.journal

    assert candidate_pointer == pointer(candidate)
    assert reset.pending_acks == {:ok, [staged]}

    assert_receive {:ack, ^rejected, rejected_meta}
    assert rejected_meta.active == nil

    assert Store.activation_journal(ctx.store) == :empty
    assert Store.active(ctx.store) == :empty
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "a failed first-generation reset preserves the journal and retries before rejection", ctx do
    reset_result =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> {:error, :owner_unavailable} end},
          id: make_ref()
        )
      )

    test_pid = self()

    recovering_applier =
      ctx
      |> applier(fail: %{apply_wifi: {:error, {:apply_failed, :wifi, :confirmation_timeout}}})
      |> Map.put(:reset, fn _owner_pid_map ->
        result = Agent.get(reset_result, & &1)
        send(test_pid, {:reset_attempt, result, authority_snapshot(ctx)})
        result
      end)

    pid = start_manager(ctx, applier: recovering_applier)
    candidate = DS.generation_fixture()
    deliver_generation(pid, candidate, ctx.session_generation)

    staged = staged_ack(candidate)

    rejected =
      rejected_ack(candidate,
        phase: :wifi_trial,
        error_code: :wifi_trial_failed,
        retryable: true,
        section: section_identity(candidate, :wifi)
      )

    assert_receive {:ack, ^staged, _meta}

    assert_receive {:reset_attempt, {:error, :owner_unavailable}, failed_reset}
    refute failed_reset.gate_open?
    assert failed_reset.active == nil
    assert failed_reset.pending_acks == {:ok, [staged]}

    assert {:ok, %{prior: nil, decision: :prior, terminal_ack: ^rejected}} =
             failed_reset.journal

    assert {:ok, %{prior: nil, decision: :prior, terminal_ack: ^rejected}} =
             Store.activation_journal(ctx.store)

    assert Store.active(ctx.store) == :empty
    assert {:ok, [^staged]} = Store.pending_acks(ctx.store)
    assert OperationalGate.status(ctx.gate) == :closed
    refute_receive {:ack, ^rejected, _meta}

    Agent.update(reset_result, fn _result -> :ok end)

    assert_receive {:reset_attempt, :ok, successful_reset}, 1_000
    refute successful_reset.gate_open?
    assert successful_reset.active == nil
    assert successful_reset.pending_acks == {:ok, [staged]}

    assert_receive {:ack, ^rejected, rejected_meta}, 1_000
    assert rejected_meta.active == nil

    eventually(fn ->
      assert Store.activation_journal(ctx.store) == :empty
      assert {:ok, [^staged, ^rejected]} = Store.pending_acks(ctx.store)
      assert OperationalGate.status(ctx.gate) == :closed
    end)
  end

  test "a rejected ACK carries only stable sanitized section and error identity", ctx do
    failure = {:error, {:validation_failed, :tracking, :invalid_tracking}}
    pid = start_manager(ctx, applier: applier(ctx, fail: %{validate: failure}))
    fixture = DS.generation_fixture()

    deliver_generation(pid, fixture, ctx.session_generation)

    rejected =
      rejected_ack(fixture,
        phase: :staging,
        error_code: :section_validation_failed,
        retryable: false,
        section: section_identity(fixture, :tracking)
      )

    assert_receive {:ack, ^rejected, meta}
    refute meta.gate_open?
    refute inspect(rejected) =~ "invalid_tracking"
    assert {:ok, _bytes} = Messages.encode(:ack, rejected)

    assert Store.active(ctx.store) == :empty
    assert OperationalGate.status(ctx.gate) == :closed
    refute_receive {:applier, :apply_non_network, _snapshot}
  end

  test "incompatible firmware or capability requirements are rejected in the manifest phase", ctx do
    pid = start_manager(ctx)

    incompatible = [
      {DS.generation_fixture(generation: 1, minimum_firmware: "9.9.9"), :incompatible_firmware},
      {DS.generation_fixture(generation: 2, required_capabilities: [{:secret_injection, 1}]), :incompatible_capability}
    ]

    Enum.each(incompatible, fn {fixture, error_code} ->
      assert {:error, ^error_code} = Manager.deliver_manifest(pid, ctx.session_generation, fixture.delivery)

      rejected =
        rejected_ack(fixture, phase: :manifest, error_code: error_code, retryable: false, section: nil)

      assert_receive {:ack, ^rejected, meta}
      refute meta.gate_open?
      assert {:ok, _bytes} = Messages.encode(:ack, rejected)

      assert :empty = Store.generation_state(ctx.store, fixture.binding.generation, fixture.manifest_hash)
      refute File.exists?(Store.generation_directory(ctx.store, fixture.binding.generation, fixture.manifest_hash))
    end)

    assert {:ok, durable} = Store.pending_acks(ctx.store)
    assert Enum.all?(durable, &(&1.status == :rejected and &1.phase == :manifest))

    compatible =
      DS.generation_fixture(generation: 3, minimum_firmware: "0.1.0", required_capabilities: [{:atomic_generation, 1}])

    assert {:ok, :staged} = Manager.deliver_manifest(pid, ctx.session_generation, compatible.delivery)

    refute_receive {:applier, :apply_non_network, _snapshot}
    assert Store.active(ctx.store) == :empty
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "same-boot reconnect replay and duplicate delivery are idempotent", ctx do
    pid = start_manager(ctx)
    fixture = DS.generation_fixture()
    deliver_generation(pid, fixture, ctx.session_generation)

    staged = staged_ack(fixture)
    effective = effective_ack(fixture)
    assert_receive {:ack, ^staged, _staged_meta}
    assert_receive {:ack, ^effective, _effective_meta}
    assert_receive {:applier, :validate, _validate}
    assert_receive {:applier, :apply_non_network, _non_network}
    assert_receive {:applier, :apply_wifi, _wifi}

    assert :ok = SessionHolder.clear(ctx.holder)
    {:ok, reconnected} = SessionHolder.publish(ctx.holder, session(<<2::128>>))
    refute reconnected.generation == ctx.session_generation

    assert :ok = Manager.replay(pid, reconnected.generation)
    assert_receive {:ack, ^staged, _replayed_staged}
    assert_receive {:ack, ^effective, _replayed_effective}

    assert {:ok, :unchanged} = Manager.deliver_manifest(pid, reconnected.generation, fixture.delivery)

    Enum.each(DS.chunks(fixture), fn chunk ->
      assert {:ok, :unchanged} = Manager.deliver_chunk(pid, reconnected.generation, chunk)
    end)

    refute_receive {:applier, :apply_non_network, _snapshot}
    assert {:ok, [^staged, ^effective]} = Store.pending_acks(ctx.store)
    assert OperationalGate.status(ctx.gate) == {:open, gate_binding(fixture)}
  end

  test "prior-boot, stale-session, and downgrade input cannot mutate state or emit a current ACK", ctx do
    active = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 2, active.manifest_hash)

    prior_boot_ack = Map.put(effective_ack(active), :boot_id, <<0x99::128>>)
    assert {:ok, :stored} = Store.put_pending_ack(ctx.store, prior_boot_ack)

    pid = start_manager(ctx)
    assert_receive {:applier, :reconcile, _reconcile}
    refute_receive {:ack, ^prior_boot_ack, _meta}

    downgrade = DS.generation_fixture(generation: 1)
    assert {:error, :stale_generation} = Manager.deliver_manifest(pid, ctx.session_generation, downgrade.delivery)
    assert :empty = Store.generation_state(ctx.store, 1, downgrade.manifest_hash)

    assert {:error, :stale_session} = Manager.replay(pid, stale(ctx))
    assert {:ok, current} = Store.active(ctx.store)
    assert current == pointer(active)
    assert OperationalGate.status(ctx.gate) == {:open, gate_binding(active)}
  end

  test "a Wi-Fi secret is accepted only for the matching descriptor binding", ctx do
    pid = start_manager(ctx)
    fixture = secret_fixture()
    deliver_generation(pid, fixture, ctx.session_generation)

    assert_receive {:ack, %{status: :staged}, _staged_meta}
    refute_receive {:applier, :validate, _snapshot}

    delivery = DS.secret_delivery(fixture, "top-secret-wifi-passphrase")

    mismatched = [
      {Map.put(delivery, :secret_ref, <<0x77::128>>), :secret_reference_mismatch},
      {Map.put(delivery, :secret_digest, :binary.copy(<<0x11>>, 32)), :secret_reference_mismatch},
      {Map.put(delivery, :digest_key_id, 11), :secret_reference_mismatch},
      {Map.put(delivery, :section_hash, :binary.copy(<<0x12>>, 32)), :secret_reference_mismatch},
      {Map.put(delivery, :boot_id, <<0x99::128>>), :boot_id_mismatch}
    ]

    Enum.each(mismatched, fn {payload, reason} ->
      assert {:error, ^reason} = Manager.deliver_secret(pid, ctx.session_generation, payload)
    end)

    refute_receive {:applier, :validate, _snapshot}

    assert {:ok, :accepted} = Manager.deliver_secret(pid, ctx.session_generation, delivery)
    assert_receive {:applier, :apply_wifi, wifi}
    assert wifi.secret =~ "REDACTED"
    assert OperationalGate.status(ctx.gate) == {:open, gate_binding(fixture)}
  end

  test "a delivered Wi-Fi secret never reaches manager state, status, ACK payloads, or durable storage", ctx do
    pid = start_manager(ctx)
    fixture = secret_fixture()
    secret = "top-secret-wifi-passphrase"

    deliver_generation(pid, fixture, ctx.session_generation)
    assert {:ok, :accepted} = Manager.deliver_secret(pid, ctx.session_generation, DS.secret_delivery(fixture, secret))
    assert_receive {:ack, %{status: :effective}, _meta}

    refute inspect(:sys.get_state(pid)) =~ secret
    refute inspect(:sys.get_status(pid)) =~ secret
    refute inspect(Manager.status(pid)) =~ secret

    assert {:ok, acks} = Store.pending_acks(ctx.store)
    refute inspect(acks) =~ secret
    refute durable_bytes(ctx.base) =~ secret
    assert durable_bytes(ctx.base) =~ DS.secret_descriptor().ref
  end

  test "crash-report formatting redacts a transient Wi-Fi secret from the current call" do
    secret = "top-secret-wifi-passphrase"

    status = %{
      state: %{identity: identity()},
      message:
        {:deliver_secret, 7, %{secret_ref: DS.secret_descriptor().ref},
         RacingOrg.Tracker.Pro.WiFiManager.Secret.new(secret)},
      reason: {:badmatch, RacingOrg.Tracker.Pro.WiFiManager.Secret.new(secret)},
      log: [
        {:in,
         {:"$gen_call", {self(), make_ref()},
          {:deliver_secret, 7, %{}, RacingOrg.Tracker.Pro.WiFiManager.Secret.new(secret)}}}
      ]
    }

    rendered =
      status
      |> Manager.format_status()
      |> then(&:io_lib.format(~c"~0p", [&1]))
      |> IO.iodata_to_binary()

    refute rendered =~ secret
  end

  test "a manager crash cannot return a Secret-bearing call in the caller exit reason" do
    server =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, {:deliver_secret, _session_generation, _metadata, %Secret{}}} ->
            exit(:simulated_crash)
        end
      end)

    result =
      Manager.deliver_secret(server, 7, %{
        secret_ref: DS.secret_descriptor().ref,
        secret: "caller-visible-secret"
      })

    assert result == {:error, :desired_state_manager_unavailable}

    rendered = result |> then(&:io_lib.format(~c"~p", [&1])) |> IO.iodata_to_binary()
    refute rendered =~ "caller-visible-secret"
  end

  test "a durable store failure never advances the gate and preserves the previous active generation", ctx do
    {:ok, armed} = Agent.start_link(fn -> false end)

    faulted =
      Store.new(
        base_dir: ctx.base,
        storage_epoch: DS.storage_epoch(),
        fault_injector: fn stage ->
          if stage == :before_rename and Agent.get(armed, & &1), do: {:error, :power_loss}, else: :ok
        end
      )

    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)

    pid = start_manager(ctx, store: faulted)
    assert_receive {:applier, :reconcile, _reconcile}
    assert OperationalGate.open?(ctx.term_key)

    Agent.update(armed, fn _armed -> true end)
    candidate = DS.generation_fixture(generation: 2)

    assert {:error, {:storage_failed, _reason}} =
             Manager.deliver_manifest(pid, ctx.session_generation, candidate.delivery)

    refute_receive {:applier, :apply_non_network, _snapshot}
    assert {:ok, active} = Store.active(ctx.store)
    assert active == pointer(prior)
    assert OperationalGate.status(ctx.gate) == {:open, gate_binding(prior)}
  end

  test "missing owner metadata fails closed and remains retryable", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    manager = start_manager(ctx, applier: applier(ctx, owners: :missing))
    refute_receive {:applier, :reconcile, _startup}

    eventually(fn ->
      refute OperationalGate.open?(ctx.term_key)
      assert OperationalGate.status(ctx.gate) == :closed

      state = :sys.get_state(manager)

      assert state.recovery_error ==
               {:owner_resolution_failed, :missing_owner_resolver}

      assert is_reference(state.owner_retry_ref)
    end)
  end

  test "partial owner metadata fails closed before any owner reconciliation", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    manager =
      start_manager(ctx,
        applier:
          applier(ctx,
            owners: fn -> %{tracking: self()} end
          )
      )

    refute_receive {:applier, :reconcile, _startup}

    eventually(fn ->
      refute OperationalGate.open?(ctx.term_key)
      assert OperationalGate.status(ctx.gate) == :closed

      state = :sys.get_state(manager)

      assert state.recovery_error ==
               {:owner_resolution_failed, :incomplete_owner_resolver}

      assert is_reference(state.owner_retry_ref)
    end)
  end

  test "a shared Via owner rebind before guard preparation fails closed", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    first_owner = start_owner_probe()
    replacement = start_owner_probe()
    {:ok, registry} = SequencedOwnerRegistry.start_link([first_owner, replacement])
    shared_reference = {:via, SequencedOwnerRegistry, registry}

    on_exit(fn ->
      if Process.alive?(registry), do: Agent.stop(registry)
    end)

    owners =
      self()
      |> owner_map()
      |> Map.put(:assignment, shared_reference)
      |> Map.put(:polar, shared_reference)

    test_pid = self()

    unique_applier =
      ctx
      |> applier(owners: fn -> owners end)
      |> Map.put(:reconcile, fn pointer, owner_pid_map ->
        send(test_pid, {:applier_owner_set, pointer, owner_pid_map})
        :ok
      end)

    manager =
      start_manager(ctx,
        applier: unique_applier,
        owner_retry_base_ms: 10_000
      )

    refute_receive {:applier_owner_set, _pointer, _owner_pid_map}
    assert OperationalGate.status(ctx.gate) == :closed
    assert {:ok, pointer(fixture)} == Store.active(ctx.store)

    state = :sys.get_state(manager)
    assert state.recovery_error == {:owner_resolution_failed, :owner_authority_changed}
    assert is_reference(state.owner_retry_ref)
  end

  test "a blocked owner reference cannot wedge manager startup", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    {:ok, registry} = BlockingReferenceRegistry.start_link(self(), self())
    owner_reference = {:via, BlockingReferenceRegistry, registry}

    on_exit(fn ->
      if Process.alive?(registry), do: Agent.stop(registry)
    end)

    starter =
      Task.async(fn ->
        Manager.start_link(
          manager_opts(ctx,
            applier: applier(ctx, owners: fn -> owner_map(owner_reference) end),
            owner_resolution_timeout_ms: 25,
            owner_retry_base_ms: 10_000
          )
        )
      end)

    assert_receive {:manager_reference_resolution_blocked, resolver_pid}
    resolver_ref = Process.monitor(resolver_pid)
    assert {:ok, manager} = Task.await(starter, 250)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    assert_receive {:DOWN, ^resolver_ref, :process, ^resolver_pid, _reason}, 250
    assert Process.alive?(manager)

    assert :sys.get_state(manager).recovery_error ==
             {:owner_resolution_failed, :owner_resolution_timeout}

    refute_receive {:applier, :reconcile, _snapshot}
  end

  test "a blocked gate reference cannot wedge manager startup", ctx do
    {:ok, registry} = BlockingReferenceRegistry.start_link(self(), ctx.gate_pid)
    gate_reference = {:via, BlockingReferenceRegistry, registry}

    on_exit(fn ->
      if Process.alive?(registry), do: Agent.stop(registry)
    end)

    starter =
      Task.async(fn ->
        Manager.start_link(
          manager_opts(ctx,
            name: nil,
            gate: gate_reference,
            owner_resolution_timeout_ms: 25,
            owner_retry_base_ms: 10_000
          )
        )
      end)

    assert_receive {:manager_reference_resolution_blocked, resolver_pid}
    resolver_ref = Process.monitor(resolver_pid)
    assert {:ok, manager} = Task.await(starter, 250)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    assert_receive {:DOWN, ^resolver_ref, :process, ^resolver_pid, _reason}, 250
    assert Process.alive?(manager)
    assert :sys.get_state(manager).gate_pid == nil
  end

  test "an owner replacement during reconciliation cannot inherit the open lease", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    first_owner =
      start_supervised!(
        Supervisor.child_spec({Task, fn -> Process.sleep(:infinity) end},
          id: make_ref(),
          restart: :temporary
        )
      )

    replacement =
      start_supervised!(
        Supervisor.child_spec({Task, fn -> Process.sleep(:infinity) end},
          id: make_ref(),
          restart: :temporary
        )
      )

    owner_registry = start_supervised!({Agent, fn -> first_owner end})
    test_pid = self()

    replacing_applier =
      ctx
      |> applier(
        owners: fn ->
          owner_map(Agent.get(owner_registry, & &1))
        end
      )
      |> Map.put(:reconcile, fn pointer, _owner_pid_map ->
        send(test_pid, {:applier, :reconcile, snapshot(ctx, pointer, nil, nil)})
        Agent.update(owner_registry, fn _owner -> replacement end)
        :ok
      end)

    manager =
      start_manager(ctx,
        applier: replacing_applier,
        owner_retry_base_ms: 10_000
      )

    assert_receive {:applier, :reconcile, _startup}
    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed

    state = :sys.get_state(manager)
    assert state.recovery_error == {:owner_resolution_failed, :owner_set_changed}
    assert is_reference(state.owner_retry_ref)
  end

  test "a global owner-reference ABA during reconciliation cannot open a lease", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)

    first_owner = start_owner_probe()
    transient_owner = start_owner_probe()
    owner_name = {:desired_state_reconcile_owner, make_ref()}
    owner_ref = {:global, owner_name}
    assert :yes = :global.register_name(owner_name, first_owner)
    on_exit(fn -> :global.unregister_name(owner_name) end)
    test_pid = self()

    aba_applier =
      ctx
      |> applier(owners: fn -> owner_map(owner_ref) end)
      |> Map.put(:reconcile, fn pointer, _owner_pid_map ->
        send(test_pid, {:applier, :reconcile, snapshot(ctx, pointer, nil, nil)})
        :ok = :global.unregister_name(owner_name)
        :yes = :global.register_name(owner_name, transient_owner)
        :ok = :global.unregister_name(owner_name)
        :yes = :global.register_name(owner_name, first_owner)
        :ok
      end)

    manager =
      start_manager(ctx,
        applier: aba_applier,
        owner_retry_base_ms: 10_000
      )

    assert_receive {:applier, :reconcile, _startup}
    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
    assert {:ok, pointer(prior)} == Store.active(ctx.store)

    state = :sys.get_state(manager)
    assert is_reference(state.owner_retry_ref)
  end

  test "a global owner-reference ABA during activation fails closed before commit", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)

    first_owner = start_owner_probe()
    transient_owner = start_owner_probe()
    owner_name = {:desired_state_owner, make_ref()}
    owner_ref = {:global, owner_name}
    assert :yes = :global.register_name(owner_name, first_owner)
    on_exit(fn -> :global.unregister_name(owner_name) end)

    test_pid = self()

    aba_applier =
      ctx
      |> applier(owners: fn -> owner_map(owner_ref) end)
      |> Map.put(:apply_non_network, fn pointer, sections, owner_pid_map ->
        send(test_pid, {:applier, :apply_non_network, snapshot(ctx, pointer, sections, nil)})

        :ok = :global.unregister_name(owner_name)
        :yes = :global.register_name(owner_name, transient_owner)
        send(Map.fetch!(owner_pid_map, :tracking), {:apply_generation, pointer})
        :ok = :global.unregister_name(owner_name)
        :yes = :global.register_name(owner_name, first_owner)
        :ok
      end)

    manager =
      start_manager(ctx,
        applier: aba_applier,
        owner_retry_base_ms: 10_000
      )

    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)

    candidate = DS.generation_fixture(generation: 2)
    deliver_generation(manager, candidate, ctx.session_generation)

    assert_receive {:owner_applied, applied_owner, applied_pointer}
    assert applied_owner == first_owner
    assert applied_pointer == pointer(candidate)
    refute_receive {:ack, %{status: :effective}, _meta}
    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
    assert {:ok, pointer(prior)} == Store.active(ctx.store)

    assert {:ok, %{candidate: candidate_pointer, decision: nil, terminal_ack: nil}} =
             Store.activation_journal(ctx.store)

    assert candidate_pointer == pointer(candidate)
  end

  test "a local owner-reference ABA during activation fails closed before commit", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)

    first_owner = start_owner_probe()
    transient_owner = start_owner_probe()
    owner_name = String.to_atom("desired_state_owner_#{System.unique_integer([:positive])}")
    true = Process.register(first_owner, owner_name)

    on_exit(fn ->
      if Process.whereis(owner_name), do: Process.unregister(owner_name)
    end)

    test_pid = self()

    aba_applier =
      ctx
      |> applier(owners: fn -> owner_map(owner_name) end)
      |> Map.put(:apply_non_network, fn pointer, sections, owner_pid_map ->
        send(test_pid, {:applier, :apply_non_network, snapshot(ctx, pointer, sections, nil)})

        true = Process.unregister(owner_name)
        true = Process.register(transient_owner, owner_name)
        send(Map.fetch!(owner_pid_map, :tracking), {:apply_generation, pointer})
        true = Process.unregister(owner_name)
        true = Process.register(first_owner, owner_name)
        :ok
      end)

    manager =
      start_manager(ctx,
        applier: aba_applier,
        owner_retry_base_ms: 10_000
      )

    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)

    candidate = DS.generation_fixture(generation: 2)
    deliver_generation(manager, candidate, ctx.session_generation)

    assert_receive {:owner_applied, ^first_owner, applied_pointer}
    assert applied_pointer == pointer(candidate)
    refute_receive {:ack, %{status: :effective}, _meta}
    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
    assert {:ok, pointer(prior)} == Store.active(ctx.store)
  end

  test "a same-PID Via incarnation ABA during activation fails closed before commit", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)

    owner = start_owner_probe()
    first_incarnation = start_owner_probe()
    transient_incarnation = start_owner_probe()
    restored_incarnation = start_owner_probe()

    registry =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> %{owner: {owner, first_incarnation}} end},
          id: make_ref()
        )
      )

    owner_ref = {:via, OwnerReferenceRegistry, {registry, :owner}}
    test_pid = self()

    aba_applier =
      ctx
      |> applier(owners: fn -> owner_map(owner_ref) end)
      |> Map.put(:apply_non_network, fn pointer, sections, owner_pid_map ->
        send(test_pid, {:applier, :apply_non_network, snapshot(ctx, pointer, sections, nil)})

        Agent.update(registry, fn entries ->
          Process.exit(first_incarnation, :kill)
          entries = Map.put(entries, :owner, {owner, transient_incarnation})
          Process.exit(transient_incarnation, :kill)
          Map.put(entries, :owner, {owner, restored_incarnation})
        end)

        send(Map.fetch!(owner_pid_map, :tracking), {:apply_generation, pointer})
        :ok
      end)

    manager =
      start_manager(ctx,
        applier: aba_applier,
        owner_retry_base_ms: 10_000
      )

    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)

    candidate = DS.generation_fixture(generation: 2)
    deliver_generation(manager, candidate, ctx.session_generation)

    assert_receive {:owner_applied, ^owner, applied_pointer}
    assert applied_pointer == pointer(candidate)
    refute_receive {:ack, %{status: :effective}, _meta}
    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
    assert {:ok, pointer(prior)} == Store.active(ctx.store)
  end

  test "a global owner-reference ABA during Wi-Fi apply restores the prior pointer", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)

    first_owner = start_owner_probe()
    transient_owner = start_owner_probe()
    owner_name = {:desired_state_wifi_owner, make_ref()}
    owner_ref = {:global, owner_name}
    assert :yes = :global.register_name(owner_name, first_owner)
    on_exit(fn -> :global.unregister_name(owner_name) end)

    test_pid = self()

    aba_applier =
      ctx
      |> applier(owners: fn -> owner_map(owner_ref) end)
      |> Map.put(:apply_wifi, fn pointer, secret, _owner_pid_map ->
        send(test_pid, {:applier, :apply_wifi, snapshot(ctx, pointer, [:wifi], secret)})
        :ok = :global.unregister_name(owner_name)
        :yes = :global.register_name(owner_name, transient_owner)
        :ok = :global.unregister_name(owner_name)
        :yes = :global.register_name(owner_name, first_owner)
        :ok
      end)

    manager =
      start_manager(ctx,
        applier: aba_applier,
        owner_retry_base_ms: 10_000
      )

    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)

    candidate = DS.generation_fixture(generation: 2)
    deliver_generation(manager, candidate, ctx.session_generation)

    assert_receive {:applier, :apply_wifi, wifi_apply}
    assert wifi_apply.active == pointer(candidate)
    refute_receive {:ack, %{status: :effective}, _meta}
    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
    assert {:ok, pointer(prior)} == Store.active(ctx.store)

    assert {:ok, %{candidate: candidate_pointer, decision: nil, terminal_ack: nil}} =
             Store.activation_journal(ctx.store)

    assert candidate_pointer == pointer(candidate)
  end

  test "a live owner reference handoff revokes the operational lease", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    first_owner = start_owner_probe()
    replacement = start_owner_probe()
    owner_name = {:desired_state_owner, make_ref()}
    owner_ref = {:global, owner_name}
    assert :yes = :global.register_name(owner_name, first_owner)
    on_exit(fn -> :global.unregister_name(owner_name) end)

    manager =
      start_manager(ctx,
        applier: applier(ctx, owners: fn -> owner_map(owner_ref) end),
        lease_heartbeat_ms: 10_000,
        lease_timeout_ms: 20_000,
        owner_retry_base_ms: 10_000
      )

    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)

    :ok = :global.unregister_name(owner_name)
    assert :yes = :global.register_name(owner_name, replacement)
    assert Process.alive?(first_owner)

    refute OperationalGate.open?(ctx.term_key)
    refute OperationalGate.operational?(4, DS.storage_epoch(), ctx.term_key)

    lease_token = :sys.get_state(manager).lease_sentinel_token
    send(manager, {:lease_heartbeat, lease_token})

    eventually(fn ->
      assert OperationalGate.status(ctx.gate) == :closed
      state = :sys.get_state(manager)
      assert state.recovery_error == {:owner_resolution_failed, :owner_set_changed}
      assert is_reference(state.owner_retry_ref)
    end)
  end

  test "a same-PID owner reference replacement revokes the leased authority", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    owner = start_owner_probe()
    first_incarnation = start_owner_probe()
    replacement_incarnation = start_owner_probe()

    registry =
      start_supervised!(
        Supervisor.child_spec(
          {Agent,
           fn ->
             %{
               first: {owner, first_incarnation},
               replacement: {owner, replacement_incarnation}
             }
           end},
          id: make_ref()
        )
      )

    first_ref = {:via, OwnerReferenceRegistry, {registry, :first}}
    replacement_ref = {:via, OwnerReferenceRegistry, {registry, :replacement}}

    owner_reference =
      start_supervised!(Supervisor.child_spec({Agent, fn -> first_ref end}, id: make_ref()))

    manager =
      start_manager(ctx,
        applier:
          applier(ctx,
            owners: fn -> owner_map(Agent.get(owner_reference, & &1)) end
          ),
        lease_heartbeat_ms: 10_000,
        lease_timeout_ms: 20_000,
        owner_retry_base_ms: 10_000
      )

    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)

    Agent.update(owner_reference, fn _current -> replacement_ref end)
    assert OperationalGate.open?(ctx.term_key)

    lease_token = :sys.get_state(manager).lease_sentinel_token
    send(manager, {:lease_heartbeat, lease_token})

    eventually(fn ->
      state = :sys.get_state(manager)
      assert state.recovery_error == {:owner_resolution_failed, :owner_authority_changed}
      assert is_reference(state.owner_retry_ref)
      refute OperationalGate.open?(ctx.term_key)
      assert OperationalGate.status(ctx.gate) == :closed
    end)
  end

  test "an observed owner-reference ABA reconciles the sticky closed lease", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    first_owner = start_owner_probe()
    replacement = start_owner_probe()
    owner_name = {:desired_state_owner, make_ref()}
    owner_ref = {:global, owner_name}
    assert :yes = :global.register_name(owner_name, first_owner)
    on_exit(fn -> :global.unregister_name(owner_name) end)

    manager =
      start_manager(ctx,
        applier: applier(ctx, owners: fn -> owner_map(owner_ref) end),
        lease_heartbeat_ms: 10_000,
        lease_timeout_ms: 20_000,
        owner_retry_base_ms: 10_000
      )

    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)

    :ok = :global.unregister_name(owner_name)
    assert :yes = :global.register_name(owner_name, replacement)
    refute OperationalGate.open?(ctx.term_key)

    :ok = :global.unregister_name(owner_name)
    assert :yes = :global.register_name(owner_name, first_owner)
    refute OperationalGate.open?(ctx.term_key)

    lease_token = :sys.get_state(manager).lease_sentinel_token
    send(manager, {:lease_heartbeat, lease_token})

    eventually(fn ->
      state = :sys.get_state(manager)
      assert state.recovery_error == :gate_lease_revoked
      assert is_reference(state.owner_retry_ref)
      assert OperationalGate.status(ctx.gate) == :closed
    end)
  end

  test "an owner replacement during activation cannot inherit the effective lease", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)

    first_owner =
      start_supervised!(
        Supervisor.child_spec({Task, fn -> Process.sleep(:infinity) end},
          id: make_ref(),
          restart: :temporary
        )
      )

    replacement =
      start_supervised!(
        Supervisor.child_spec({Task, fn -> Process.sleep(:infinity) end},
          id: make_ref(),
          restart: :temporary
        )
      )

    owner_registry = start_supervised!({Agent, fn -> first_owner end})
    test_pid = self()

    replacing_applier =
      ctx
      |> applier(
        owners: fn ->
          owner_map(Agent.get(owner_registry, & &1))
        end
      )
      |> Map.put(:apply_non_network, fn pointer, sections, _owner_pid_map ->
        send(test_pid, {:applier, :apply_non_network, snapshot(ctx, pointer, sections, nil)})
        Agent.update(owner_registry, fn _owner -> replacement end)
        :ok
      end)

    manager =
      start_manager(ctx,
        applier: replacing_applier,
        owner_retry_base_ms: 10_000
      )

    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)

    candidate = DS.generation_fixture(generation: 2)
    deliver_generation(manager, candidate, ctx.session_generation)

    refute_receive {:ack, %{status: :effective}, _meta}
    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed

    state = :sys.get_state(manager)
    assert state.recovery_error == {:owner_resolution_failed, :owner_set_changed}
    assert is_reference(state.owner_retry_ref)
    assert {:ok, pointer(prior)} == Store.active(ctx.store)

    assert {:ok, %{candidate: candidate_pointer, decision: nil, terminal_ack: nil}} =
             Store.activation_journal(ctx.store)

    assert candidate_pointer == pointer(candidate)
  end

  test "identity revocation invalidates the old lease before a suspended gate acknowledges close",
       ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    authority =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> {:ok, identity()} end},
          id: make_ref()
        )
      )

    manager =
      start_manager(ctx,
        identity: fn -> Agent.get(authority, & &1) end,
        identity_refresh_ms: 10
      )

    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)
    assert OperationalGate.operational?(4, DS.storage_epoch(), ctx.term_key)

    :ok = :sys.suspend(ctx.gate_pid)

    on_exit(fn ->
      if Process.alive?(ctx.gate_pid), do: :sys.resume(ctx.gate_pid)
    end)

    Agent.update(authority, fn _identity -> {:error, :authority_revoked} end)

    eventually(fn ->
      refute OperationalGate.open?(ctx.term_key)
      refute OperationalGate.operational?(4, DS.storage_epoch(), ctx.term_key)
    end)

    assert Process.alive?(manager)
    :ok = :sys.resume(ctx.gate_pid)

    eventually(fn ->
      assert Manager.status(manager).identity == nil
      assert OperationalGate.status(ctx.gate) == :closed
    end)
  end

  test "candidate activation invalidates the old lease before a suspended gate acknowledges close",
       ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)

    manager = start_manager(ctx)
    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)

    candidate = DS.generation_fixture(generation: 2)

    assert {:ok, :staged} =
             Manager.deliver_manifest(
               manager,
               ctx.session_generation,
               candidate.delivery
             )

    chunks = DS.chunks(candidate)

    Enum.each(Enum.drop(chunks, -1), fn chunk ->
      assert {:ok, :stored} =
               Manager.deliver_chunk(
                 manager,
                 ctx.session_generation,
                 chunk
               )
    end)

    final_chunk = List.last(chunks)
    :ok = :sys.suspend(ctx.gate_pid)

    on_exit(fn ->
      if Process.alive?(ctx.gate_pid), do: :sys.resume(ctx.gate_pid)
    end)

    delivery =
      Task.async(fn ->
        Manager.deliver_chunk(
          manager,
          ctx.session_generation,
          final_chunk
        )
      end)

    eventually(fn ->
      refute OperationalGate.open?(ctx.term_key)
      refute OperationalGate.operational?(4, DS.storage_epoch(), ctx.term_key)
    end)

    :ok = :sys.resume(ctx.gate_pid)
    assert {:ok, :stored} = Task.await(delivery, 5_000)

    assert_receive {:ack, %{status: :staged}, _meta}
    assert_receive {:ack, %{status: :effective}, _meta}

    eventually(fn ->
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(candidate)}
    end)
  end

  test "a responsive manager renews its operational lease", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    manager =
      start_manager(ctx,
        lease_heartbeat_ms: 25,
        lease_timeout_ms: 250
      )

    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)

    Process.sleep(600)

    assert Process.alive?(manager)
    assert OperationalGate.open?(ctx.term_key)
    assert OperationalGate.operational?(4, DS.storage_epoch(), ctx.term_key)
  end

  test "an unresponsive manager loses its operational lease", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    manager =
      start_manager(ctx,
        lease_heartbeat_ms: 10,
        lease_timeout_ms: 50
      )

    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)

    :ok = :sys.suspend(manager)
    on_exit(fn -> if Process.alive?(manager), do: :sys.resume(manager) end)

    eventually(fn ->
      refute OperationalGate.open?(ctx.term_key)
      refute OperationalGate.operational?(4, DS.storage_epoch(), ctx.term_key)
    end)

    :ok = :sys.resume(manager)

    assert_receive {:applier, :reconcile, _recovered}, 1_000

    eventually(fn ->
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(fixture)}
    end)
  end

  test "owner liveness closes the gate while the manager cannot process DOWN", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    owner =
      start_supervised!(
        Supervisor.child_spec({Task, fn -> Process.sleep(:infinity) end},
          id: make_ref(),
          restart: :temporary
        )
      )

    applier = applier(ctx, owners: fn -> owner_map(owner) end)
    manager = start_manager(ctx, applier: applier)
    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)

    :sys.suspend(manager)
    on_exit(fn -> if Process.alive?(manager), do: :sys.resume(manager) end)

    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

    refute OperationalGate.open?(ctx.term_key)
    refute OperationalGate.operational?(4, DS.storage_epoch(), ctx.term_key)

    :sys.resume(manager)
    eventually(fn -> assert OperationalGate.status(ctx.gate) == :closed end)
  end

  test "an authoritative owner death closes the gate until its replacement reconciles", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    owner =
      start_supervised!(
        Supervisor.child_spec({Task, fn -> Process.sleep(:infinity) end},
          id: make_ref(),
          restart: :temporary
        )
      )

    owner_registry = start_supervised!({Agent, fn -> owner end})

    applier =
      applier(ctx,
        owners: fn -> owner_map(Agent.get(owner_registry, & &1)) end
      )

    start_manager(ctx, applier: applier)
    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)

    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

    eventually(fn ->
      refute OperationalGate.open?(ctx.term_key)
      assert OperationalGate.status(ctx.gate) == :closed
    end)

    replacement =
      start_supervised!(
        Supervisor.child_spec({Task, fn -> Process.sleep(:infinity) end},
          id: make_ref(),
          restart: :temporary
        )
      )

    Agent.update(owner_registry, fn _owner -> replacement end)

    assert_receive {:applier, :reconcile, replacement_reconcile}, 1_000
    refute replacement_reconcile.gate_open?
    eventually(fn -> assert OperationalGate.status(ctx.gate) == {:open, gate_binding(fixture)} end)
  end

  test "a restarted operational gate reopens only after the active generation reconciles", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    manager = start_manager(ctx)
    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.status(ctx.gate) == {:open, gate_binding(fixture)}

    ref = Process.monitor(ctx.gate_pid)
    assert :ok = GenServer.stop(ctx.gate_pid)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    eventually(fn -> refute OperationalGate.open?(ctx.term_key) end)

    Process.sleep(75)
    assert Process.alive?(manager)
    refute_receive {:applier, :reconcile, _without_gate}

    assert {:ok, replacement} =
             OperationalGate.start_link(
               name: ctx.gate,
               term_key: ctx.term_key,
               controller: ctx.manager_name,
               controller_capability: ctx.controller_capability
             )

    assert Process.alive?(replacement)
    assert Process.alive?(manager)
    assert OperationalGate.status(ctx.gate) == :closed

    assert_receive {:applier, :reconcile, reconcile}, 1_000
    assert reconcile.pointer == pointer(fixture)
    assert reconcile.active == pointer(fixture)
    refute reconcile.gate_open?

    eventually(fn ->
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(fixture)}
      assert OperationalGate.operational?(4, DS.storage_epoch(), ctx.term_key)
    end)
  end

  test "an unauthorized replacement gate cannot disrupt the manager lease", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    manager =
      start_manager(ctx,
        lease_heartbeat_ms: 10,
        lease_timeout_ms: 50,
        owner_retry_base_ms: 10
      )

    assert_receive {:applier, :reconcile, _startup}
    assert OperationalGate.open?(ctx.term_key)
    parent = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)

      result =
        OperationalGate.start_link(
          name: nil,
          term_key: ctx.term_key,
          controller: ctx.manager_name
        )

      send(parent, {:replacement_result, result})
    end)

    assert_receive {:replacement_result, {:error, :gate_authority_in_use}}

    eventually(fn ->
      assert OperationalGate.status(ctx.gate) == {:open, gate_binding(fixture)}
      assert OperationalGate.operational?(4, DS.storage_epoch(), ctx.term_key)
      assert :sys.get_state(manager).gate_pid == ctx.gate_pid
    end)

    refute_receive {:applier, :reconcile, _replacement_reconcile}
  end

  test "the operational gate closes when the manager process dies", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    pid = start_manager(ctx)
    assert_receive {:applier, :reconcile, _reconcile}
    assert OperationalGate.open?(ctx.term_key)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    eventually(fn -> refute OperationalGate.open?(ctx.term_key) end)
    assert OperationalGate.status(ctx.gate) == :closed
  end

  defp start_manager(ctx, opts \\ []) do
    start_supervised!(
      {Manager, manager_opts(ctx, opts)},
      restart: :temporary
    )
  end

  defp manager_opts(ctx, opts) do
    [
      name: Keyword.get(opts, :name, ctx.manager_name),
      store: Keyword.get(opts, :store, ctx.store),
      gate: Keyword.get(opts, :gate, ctx.gate),
      controller_capability: ctx.controller_capability,
      session_holder: ctx.holder,
      identity: Keyword.get(opts, :identity, identity()),
      identity_refresh_ms: Keyword.get(opts, :identity_refresh_ms, 1_000),
      lease_heartbeat_ms: Keyword.get(opts, :lease_heartbeat_ms, 1_000),
      lease_timeout_ms: Keyword.get(opts, :lease_timeout_ms, 5_000),
      owner_retry_base_ms: Keyword.get(opts, :owner_retry_base_ms, 25),
      owner_retry_max_ms: Keyword.get(opts, :owner_retry_max_ms, 5_000),
      owner_resolution_timeout_ms: Keyword.get(opts, :owner_resolution_timeout_ms, 100),
      compatibility: compatibility(),
      applier: Keyword.get(opts, :applier, applier(ctx)),
      ack_sink: Keyword.get(opts, :ack_sink, ack_sink(ctx))
    ]
  end

  # The authoritative LOGICAL desired-state identity. It is injected, never derived
  # from the live Session (whose fingerprint identifies an operational key, not the
  # 16-byte logical device UUID these payloads bind).
  defp identity do
    %{
      device_id: DS.device_id(),
      credential_epoch: 4,
      boot_id: DS.boot_id(),
      storage_epoch: DS.storage_epoch()
    }
  end

  # Injected local firmware version and supported capability set. A manifest may
  # require only what this device actually advertises.
  defp compatibility do
    %{firmware_version: "0.7.0", capabilities: [{:atomic_generation, 1}, {:bounded_wifi_trial, 1}]}
  end

  defp session(session_id, credential_epoch \\ 4) do
    Session.new(
      role: :initiator,
      session_id: session_id,
      epoch: 0,
      credential_epoch: credential_epoch,
      out_key: :binary.copy(<<0xAA>>, 32),
      in_key: :binary.copy(<<0xBB>>, 32)
    )
  end

  defp stale(ctx), do: ctx.session_generation + 1

  defp applier(ctx, opts \\ []) do
    test_pid = self()
    fail = Keyword.get(opts, :fail, %{})

    callbacks = %{
      validate: fn pointer, sections, secret, _owner_pid_map ->
        send(test_pid, {:applier, :validate, snapshot(ctx, pointer, sections, secret)})
        Map.get(fail, :validate, :ok)
      end,
      apply_non_network: fn pointer, sections, _owner_pid_map ->
        send(test_pid, {:applier, :apply_non_network, snapshot(ctx, pointer, sections, nil)})
        Map.get(fail, :apply_non_network, :ok)
      end,
      apply_wifi: fn pointer, secret, _owner_pid_map ->
        send(test_pid, {:applier, :apply_wifi, snapshot(ctx, pointer, [:wifi], secret)})
        Map.get(fail, :apply_wifi, :ok)
      end,
      reset: fn _owner_pid_map ->
        send(test_pid, {:applier, :reset, authority_snapshot(ctx)})
        Map.get(fail, :reset, :ok)
      end,
      reconcile: fn pointer, _owner_pid_map ->
        send(test_pid, {:applier, :reconcile, snapshot(ctx, pointer, nil, nil)})
        Map.get(fail, :reconcile, :ok)
      end
    }

    case Keyword.get(opts, :owners, fn -> owner_map(test_pid) end) do
      :missing -> callbacks
      owners -> Map.put(callbacks, :owners, owners)
    end
  end

  defp owner_map(owner) do
    Map.new(Contract.sections(), &{&1, owner})
  end

  defp start_owner_probe do
    test_pid = self()

    start_supervised!(
      Supervisor.child_spec({Task, fn -> owner_probe(test_pid) end},
        id: make_ref(),
        restart: :temporary
      )
    )
  end

  defp owner_probe(test_pid) do
    receive do
      {:apply_generation, pointer} ->
        send(test_pid, {:owner_applied, self(), pointer})
        owner_probe(test_pid)
    end
  end

  defp ack_sink(ctx, opts \\ []) do
    test_pid = self()
    fail_status = Keyword.get(opts, :fail_status)

    fn ack ->
      send(test_pid, {:ack, ack, %{gate_open?: OperationalGate.open?(ctx.term_key), active: active_pointer(ctx.store)}})

      if ack.status == fail_status,
        do: {:error, :control_plane_unavailable},
        else: :ok
    end
  end

  defp snapshot(ctx, pointer, sections, secret) do
    %{
      pointer: pointer,
      sections: sections && Enum.sort(sections),
      secret: inspect(secret),
      gate_open?: OperationalGate.open?(ctx.term_key),
      active: active_pointer(ctx.store)
    }
  end

  defp authority_snapshot(ctx) do
    %{
      gate_open?: OperationalGate.open?(ctx.term_key),
      active: active_pointer(ctx.store),
      journal: Store.activation_journal(ctx.store),
      pending_acks: Store.pending_acks(ctx.store)
    }
  end

  defp active_pointer(store) do
    case Store.active(store) do
      {:ok, pointer} -> pointer
      :empty -> nil
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_generation(pid, fixture, session_generation) do
    assert {:ok, _disposition} = Manager.deliver_manifest(pid, session_generation, fixture.delivery)

    Enum.each(DS.chunks(fixture), fn chunk ->
      assert {:ok, _disposition} = Manager.deliver_chunk(pid, session_generation, chunk)
    end)

    fixture
  end

  defp fully_stage(store, fixture) do
    assert {:ok, _disposition} = Store.stage_manifest(store, fixture.delivery)
    Enum.each(DS.chunks(fixture), &assert({:ok, _disposition} = Store.put_chunk(store, &1)))

    assert {:ok, %{status: :staged}} =
             Store.verify_and_stage(store, fixture.binding.generation, fixture.manifest_hash)

    fixture
  end

  defp secret_fixture do
    DS.generation_fixture(
      wifi_secrets: [DS.secret_descriptor()],
      contents: %{wifi: %{"version" => 2, "enabled" => true, "ssid" => "race-net"}}
    )
  end

  defp pointer(fixture) do
    %{
      storage_epoch: DS.storage_epoch(),
      credential_epoch: fixture.binding.credential_epoch,
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

  defp staged_ack(fixture) do
    summaries =
      Enum.map(fixture.sections, fn section ->
        %{
          section: section.name,
          section_schema_version: section.schema_version,
          tombstone: section.tombstone,
          section_hash: section.hash
        }
      end)

    Map.merge(identity(), %{
      generation: fixture.binding.generation,
      manifest_hash: fixture.manifest_hash,
      status: :staged,
      sections: summaries
    })
  end

  defp effective_ack(fixture) do
    Map.merge(identity(), %{
      generation: fixture.binding.generation,
      manifest_hash: fixture.manifest_hash,
      status: :effective
    })
  end

  defp rejected_ack(fixture, opts) do
    Map.merge(identity(), %{
      generation: fixture.binding.generation,
      manifest_hash: fixture.manifest_hash,
      status: :rejected,
      phase: Keyword.fetch!(opts, :phase),
      error_code: Keyword.fetch!(opts, :error_code),
      retryable: Keyword.fetch!(opts, :retryable),
      section: Keyword.get(opts, :section)
    })
  end

  defp section_identity(fixture, name) do
    section = Map.fetch!(fixture.sections_by_name, name)

    %{
      section: name,
      section_schema_version: section.schema_version,
      section_hash: section.hash
    }
  end

  defp durable_bytes(base) do
    base
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map_join(&File.read!/1)
  end

  defp eventually(assertion, attempts \\ 50)

  defp eventually(assertion, attempts) when attempts > 0 do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(assertion, attempts - 1)
  end

  defp eventually(assertion, 0), do: assertion.()
end
