defmodule RacingOrg.Tracker.Pro.Commands.Ledger.StoreTransitionTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands.Ledger
  alias RacingOrg.Tracker.Pro.Commands.Ledger.Store
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Command, Messages}

  defmodule RecoveryVerifier do
    def with_non_application_lease(intent, proof, reason, effect_state, transition) do
      Agent.get_and_update(effect_state, fn effects ->
        case {Map.get(effects, intent.command_hash), proof, reason} do
          {:not_started, :effect_not_started, :operational_gate_closed} ->
            finish_transition(transition, effects, intent.command_hash)

          {:absent, :effect_verified_absent, :operational_gate_closed} ->
            finish_transition(transition, effects, intent.command_hash)

          _other ->
            {{:error, :effect_non_application_unverified}, effects}
        end
      end)
    end

    defp finish_transition(transition, effects, command_hash) do
      result = transition.()
      next_effects = if match?({:ok, _persisted}, result), do: Map.put(effects, command_hash, :rejected), else: effects
      {result, next_effects}
    end
  end

  defmodule FailingRecoveryVerifier do
    def with_non_application_lease(_intent, _proof, _reason, behavior, _transition) do
      case behavior do
        :raise -> raise "verifier failed"
        :throw -> throw(:verifier_failed)
        :exit -> exit(:verifier_failed)
        :unexpected -> :ok
      end
    end
  end

  defmodule HungRecoveryVerifier do
    def with_non_application_lease(_intent, _proof, _reason, _context, _transition) do
      receive do
        :never -> :ok
      end
    end
  end

  defmodule NoTransitionRecoveryVerifier do
    def with_non_application_lease(_intent, _proof, _reason, _context, _transition),
      do: {:ok, :forged}
  end

  defmodule DoubleTransitionRecoveryVerifier do
    def with_non_application_lease(_intent, _proof, _reason, _context, transition) do
      first = transition.()
      _second = transition.()
      first
    end
  end

  defmodule MismatchedTransitionRecoveryVerifier do
    def with_non_application_lease(_intent, _proof, _reason, _context, transition) do
      _persisted = transition.()
      {:ok, :forged}
    end
  end

  defmodule CommitThenHangRecoveryVerifier do
    def with_non_application_lease(_intent, _proof, _reason, owner, transition) do
      result = transition.()
      send(owner, {:recovery_transition_completed, result})

      receive do
        :never -> result
      end
    end
  end

  defmodule DirectRecoveryVerifier do
    def with_non_application_lease(_intent, _proof, _reason, _context, transition),
      do: transition.()
  end

  defmodule CommitThenCrashRecoveryVerifier do
    def with_non_application_lease(_intent, _proof, _reason, owner, transition) do
      result = transition.()
      send(owner, {:crashing_recovery_transition_completed, result})
      Process.exit(self(), :kill)
    end
  end

  defmodule AsyncTransitionRecoveryVerifier do
    def with_non_application_lease(_intent, _proof, _reason, {owner, mode}, transition) do
      if match?({:await_started, _waiter}, mode) or
           match?({:kill_after_started, _waiter}, mode) do
        {_behavior, waiter} = mode
        verifier = self()
        Agent.update(waiter, fn _unset -> verifier end)
      end

      pid =
        spawn(fn ->
          if mode == :deferred do
            receive do
              :run_deferred_transition -> :ok
            end
          end

          result = transition.()
          send(owner, {:async_recovery_transition_result, self(), result})
        end)

      send(owner, {:async_recovery_transition_spawned, pid})

      if match?({:await_started, _waiter}, mode) or
           match?({:kill_after_started, _waiter}, mode) do
        receive do
          :async_recovery_transition_started -> :ok
        end
      end

      if match?({:kill_after_started, _waiter}, mode),
        do: Process.exit(self(), :kill),
        else: {:error, :effect_non_application_unverified}
    end
  end

  defmodule PostRenameCrashFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def read(path), do: FileSystem.read(path)
    def read(device, count), do: FileSystem.read(device, count)
    def list_dir(path), do: FileSystem.list_dir(path)
    def lstat(path), do: FileSystem.lstat(path)
    def file_info(device), do: FileSystem.file_info(device)
    def mkdir_p(path), do: FileSystem.mkdir_p(path)
    def mkdir(path), do: FileSystem.mkdir(path)
    def chmod(path, mode), do: FileSystem.chmod(path, mode)
    def open(path, modes), do: FileSystem.open(path, modes)
    def write(device, contents), do: FileSystem.write(device, contents)
    def close(device), do: FileSystem.close(device)
    def remove(path), do: FileSystem.remove(path)
    def rmdir(path), do: FileSystem.rmdir(path)

    def rename(source, destination) do
      case FileSystem.rename(source, destination) do
        :ok ->
          Process.put({__MODULE__, :renamed?}, true)
          :ok

        error ->
          error
      end
    end

    def sync(device) do
      if Process.delete({__MODULE__, :renamed?}) do
        raise "simulated post-rename filesystem crash"
      else
        FileSystem.sync(device)
      end
    end
  end

  defmodule BlockingMkdirFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def attach(owner, blocked_path), do: :persistent_term.put({__MODULE__, :block}, {owner, blocked_path})
    def detach, do: :persistent_term.erase({__MODULE__, :block})

    def read(path), do: FileSystem.read(path)
    def read(device, count), do: FileSystem.read(device, count)
    def list_dir(path), do: FileSystem.list_dir(path)
    def lstat(path), do: FileSystem.lstat(path)
    def file_info(device), do: FileSystem.file_info(device)

    def mkdir_p(path), do: FileSystem.mkdir_p(path)

    def mkdir(path) do
      case :persistent_term.get({__MODULE__, :block}, nil) do
        {owner, blocked_path} ->
          if Path.basename(path) == Path.basename(blocked_path) do
            send(owner, {:ledger_parent_mkdir_blocked, self()})

            receive do
              :release_ledger_parent_mkdir -> :ok
            end
          end

        _other ->
          :ok
      end

      case FileSystem.lstat(path) do
        {:ok, %File.Stat{}} -> {:error, :eexist}
        {:error, :enoent} -> FileSystem.mkdir(path)
        other -> other
      end
    end

    def chmod(path, mode), do: FileSystem.chmod(path, mode)
    def open(path, modes), do: FileSystem.open(path, modes)
    def write(device, contents), do: FileSystem.write(device, contents)
    def sync(device), do: FileSystem.sync(device)
    def close(device), do: FileSystem.close(device)
    def rename(source, destination), do: FileSystem.rename(source, destination)
    def remove(path), do: FileSystem.remove(path)
    def rmdir(path), do: FileSystem.rmdir(path)
  end

  defmodule ToggleReadFailureFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def fail_reads, do: :persistent_term.put({__MODULE__, :fail_reads?}, true)
    def reset, do: :persistent_term.erase({__MODULE__, :fail_reads?})

    def read(path) do
      if :persistent_term.get({__MODULE__, :fail_reads?}, false),
        do: {:error, :simulated_read_failure},
        else: FileSystem.read(path)
    end

    def read(device, count), do: FileSystem.read(device, count)
    def list_dir(path), do: FileSystem.list_dir(path)
    def lstat(path), do: FileSystem.lstat(path)
    def file_info(device), do: FileSystem.file_info(device)
    def mkdir_p(path), do: FileSystem.mkdir_p(path)
    def mkdir(path), do: FileSystem.mkdir(path)
    def chmod(path, mode), do: FileSystem.chmod(path, mode)
    def open(path, modes), do: FileSystem.open(path, modes)
    def write(device, contents), do: FileSystem.write(device, contents)
    def sync(device), do: FileSystem.sync(device)
    def close(device), do: FileSystem.close(device)
    def rename(source, destination), do: FileSystem.rename(source, destination)
    def remove(path), do: FileSystem.remove(path)
    def rmdir(path), do: FileSystem.rmdir(path)
  end

  defmodule ReclassifyingAdmissionAuthority do
    alias RacingOrg.Tracker.Pro.Commands.Ledger

    def authorize(plan, snapshot, limits, runtime_state) do
      context =
        runtime_state
        |> Agent.get(& &1)
        |> Map.merge(%{snapshot: snapshot, limits: limits})

      expected =
        case plan.action do
          :execute -> {:execute, plan}
          :terminal -> {:terminal, plan}
          _other -> :invalid
        end

      if Ledger.classify(plan.delivery, context) == expected,
        do: :ok,
        else: {:error, :command_admission_not_authoritative}
    end
  end

  defmodule PermissiveAdmissionAuthority do
    def authorize(_plan, _snapshot, _limits, _context), do: :ok
  end

  defmodule DenyRecoveryVerifier do
    def with_non_application_lease(_intent, _proof, _reason, _context, _transition),
      do: {:error, :effect_non_application_unverified}
  end

  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @manifest_hash :binary.copy(<<0xB2>>, 32)

  @pre_rename_faults [
    :temp_opened,
    :temp_chmodded,
    :temp_written,
    :temp_synced,
    :temp_closed,
    :before_rename
  ]
  @uncertain_faults [:renamed]
  @durable_faults [:parent_synced]

  setup do
    root = Path.join(System.tmp_dir!(), "command_ledger_transition_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf(root)
      BlockingMkdirFileSystem.detach()
      ToggleReadFailureFileSystem.reset()
    end)

    %{root: root, path: Path.join(root, "ledger.snapshot")}
  end

  test "persists intent before exposing execution and persists exact outcome before exposing ACK", %{path: path} do
    assert {:ok, store} = open_store(path)
    delivery = delivery(command_id: command_id(1), payload: <<0x00, 0xFF, "effect">>)
    plan = execution_plan(delivery, :set_tracking, 32)

    assert {:ok, intent, _store} = begin_intent(store, plan)
    assert intent.command_id == delivery.command_id
    assert intent.command_hash == delivery.command_hash
    assert intent.payload == delivery.payload
    assert intent.command_type == :set_tracking
    assert intent.reserved_result_bytes == 32

    assert {:ok, interrupted} = open_store(path)
    assert Store.pending_intent(interrupted) == intent
    assert Store.snapshot(interrupted).outcomes == %{}
    assert Store.snapshot(interrupted).next_expected_sequence == 1

    result = <<0x00, 0xFF, "persisted-result">>
    assert {:ok, ack, completed} = Store.complete_intent(interrupted, result)
    assert {:ok, encoded_ack} = Messages.encode(:command_ack, ack)
    assert {:ok, ^ack} = Messages.decode(:command_ack, encoded_ack)

    expected_result_hash =
      :crypto.hash(
        :sha256,
        Contract.command_result_hash_domain() <>
          <<Contract.version(), 0x01, 0x00, byte_size(result)::32, result::binary>>
      )

    assert ack.status == :applied
    assert ack.reason == :none
    assert ack.result == result
    assert ack.result_hash == expected_result_hash

    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened) == nil
    assert Store.snapshot(reopened).next_expected_sequence == 2

    assert Store.snapshot(reopened).outcomes == %{
             delivery.command_id => %{
               hash: delivery.command_hash,
               status: :applied,
               reason: :none,
               result: result,
               result_hash: expected_result_hash,
               sequence: 1
             }
           }

    assert Store.snapshot(completed) == Store.snapshot(reopened)
  end

  test "store rejects forged delivery hashes even when called without classification", %{root: root} do
    begin_path = Path.join(root, "forged-begin.snapshot")
    assert {:ok, begin_store} = open_store(begin_path)
    delivery = delivery(command_id: command_id(1), payload: "authentic")
    forged_payload = %{delivery | payload_hash: :binary.copy(<<0xA5>>, 32)}

    assert {:error, :invalid_command_delivery} =
             begin_intent(begin_store, execution_plan(forged_payload, :set_tracking, 8))

    terminal_path = Path.join(root, "forged-terminal.snapshot")
    assert {:ok, terminal_store} = open_store(terminal_path)
    forged_command = %{delivery | command_hash: :binary.copy(<<0x5A>>, 32)}

    assert {:error, :invalid_command_delivery} =
             Store.record_terminal(terminal_store, terminal_plan(forged_command, :expired))
  end

  test "retains terminal non-execution outcomes and advances only after the durable write", %{path: path} do
    assert {:ok, store} = open_store(path)

    {store, sequence} =
      Enum.reduce(
        [expired: :expired, unsupported: :unsupported_command, invalid: :invalid_payload],
        {store, 1},
        fn {name, reason}, {store, sequence} ->
          delivery = delivery(command_id: command_id(sequence), command_sequence: sequence)
          plan = terminal_plan(delivery, reason)

          assert {:ok, ack, store} = Store.record_terminal(store, plan)
          assert ack.status == :rejected
          assert ack.reason == reason
          assert ack.result == <<>>
          assert {:ok, _bytes} = Messages.encode(:command_ack, ack)

          outcome = Map.fetch!(Store.snapshot(store).outcomes, delivery.command_id)
          assert outcome.status == :rejected
          assert outcome.reason == reason
          assert outcome.sequence == sequence
          assert name in [:expired, :unsupported, :invalid]

          {store, sequence + 1}
        end
      )

    assert sequence == 4
    assert Store.snapshot(store).next_expected_sequence == 4
    assert map_size(Store.snapshot(store).outcomes) == 3
    assert {:ok, reopened} = open_store(path)
    assert Store.snapshot(reopened) == Store.snapshot(store)
  end

  test "an unresolved intent is the sole recoverable authority and blocks every new transition", %{path: path} do
    assert {:ok, store} = open_store(path)
    delivery = delivery(command_id: command_id(1))
    assert {:ok, intent, store} = begin_intent(store, execution_plan(delivery, :set_tracking, 16))

    assert {:error, :pending_command_intent} =
             begin_intent(
               store,
               execution_plan(delivery(command_id: command_id(2)), :set_tracking, 8)
             )

    assert {:error, :pending_command_intent} =
             Store.record_terminal(
               store,
               terminal_plan(delivery(command_id: command_id(2)), :expired)
             )

    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened) == intent
    assert {:ok, _ack, completed} = Store.complete_intent(reopened, "recovered")
    assert Store.pending_intent(completed) == nil
  end

  test "completion records an applied effect after expiry instead of manufacturing rejection", %{root: root} do
    path = Path.join(root, "expired.snapshot")
    assert {:ok, store} = open_store(path)
    delivery = delivery(command_id: command_id(1), expires_at_ms: 100)

    assert {:ok, intent, store} =
             begin_intent(store, execution_plan(delivery, :set_tracking, 8), 99)

    assert intent.expires_at_ms == 100
    assert {:ok, ack, completed} = Store.complete_intent(store, "late")
    assert ack.status == :applied
    assert ack.reason == :none
    assert ack.result == "late"
    assert Store.pending_intent(completed) == nil

    assert {:ok, reopened} = open_store(path)
    assert Store.snapshot(reopened) == Store.snapshot(completed)
  end

  test "admission authority reclassifies with fresh clock and mutable desired-state fences", %{root: root} do
    path = Path.join(root, "fresh-admission.snapshot")
    {:ok, runtime_state} = Agent.start_link(fn -> admission_runtime(trusted_now_ms: 99) end)

    assert {:ok, store} =
             open_store(path,
               admission_authority: {ReclassifyingAdmissionAuthority, runtime_state}
             )

    expiring = delivery(command_id: command_id(1), expires_at_ms: 100)
    assert {:execute, expiry_plan} = classify(expiring, store, runtime_state)
    Agent.update(runtime_state, &Map.put(&1, :trusted_now_ms, 100))

    assert {:error, :command_admission_not_authoritative} =
             Store.begin_intent(store, expiry_plan)

    assert {:ok, reopened_after_expiry} =
             open_store(path,
               admission_authority: {ReclassifyingAdmissionAuthority, runtime_state}
             )

    assert Store.pending_intent(reopened_after_expiry) == nil

    Agent.update(runtime_state, fn runtime ->
      runtime
      |> Map.put(:trusted_now_ms, 99)
      |> Map.put(:active_generation, 42)
      |> Map.put(:active_manifest_hash, @manifest_hash)
      |> Map.put(:gate, open_gate())
    end)

    stale = delivery(command_id: command_id(2), expires_at_ms: 1_000)
    assert {:execute, stale_plan} = classify(stale, store, runtime_state)

    Agent.update(runtime_state, fn runtime ->
      runtime
      |> Map.put(:active_generation, 43)
      |> Map.put(:gate, {:open, %{open_gate_binding() | generation: 43}})
    end)

    assert {:error, :command_admission_not_authoritative} =
             Store.begin_intent(store, stale_plan)

    assert {:ok, reopened_after_generation} =
             open_store(path,
               admission_authority: {ReclassifyingAdmissionAuthority, runtime_state}
             )

    assert Store.pending_intent(reopened_after_generation) == nil
  end

  test "admission authority binds command type, reservation, and terminal reason", %{root: root} do
    path = Path.join(root, "bound-admission.snapshot")
    {:ok, runtime_state} = Agent.start_link(fn -> admission_runtime(trusted_now_ms: 99) end)

    assert {:ok, store} =
             open_store(path,
               admission_authority: {ReclassifyingAdmissionAuthority, runtime_state}
             )

    command = delivery(command_id: command_id(1), expires_at_ms: 1_000)
    assert {:execute, plan} = classify(command, store, runtime_state)

    assert {:error, :command_admission_not_authoritative} =
             Store.begin_intent(store, %{plan | command_type: :set_wifi})

    assert {:error, :command_admission_not_authoritative} =
             Store.begin_intent(store, %{plan | reserved_result_bytes: 0})

    forged_terminal = terminal_plan(command, :expired)

    assert {:error, :command_admission_not_authoritative} =
             Store.record_terminal(store, forged_terminal)

    expired = delivery(command_id: command_id(2), expires_at_ms: 99)
    assert {:terminal, terminal} = classify(expired, store, runtime_state)
    assert {:ok, ack, persisted} = Store.record_terminal(store, terminal)
    assert ack.reason == :expired
    assert Store.snapshot(persisted).next_expected_sequence == 2
  end

  test "rejection requires a closed proof bound to the exact pending effect", %{root: root} do
    path = Path.join(root, "not-applied.snapshot")
    {:ok, effect_state} = Agent.start_link(fn -> %{} end)

    assert {:ok, store} =
             open_store(path,
               recovery_verifiers: %{set_tracking: {RecoveryVerifier, effect_state}}
             )

    delivery = delivery(command_id: command_id(2))

    assert {:ok, intent, store} =
             begin_intent(store, execution_plan(delivery, :set_tracking, 3))

    assert {:error, :command_result_reservation_exceeded} = Store.complete_intent(store, "four")
    assert {:error, :invalid_command_rejection_plan} = Store.reject_intent(store, :expired)

    for invalid_reason <- [:expired, :invalid_payload] do
      plan = rejection_plan(intent, :effect_not_started, invalid_reason)
      assert {:error, :invalid_command_rejection_plan} = Store.reject_intent(store, plan)
    end

    valid_plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)

    invalid_plans = [
      %{valid_plan | action: :execute},
      %{valid_plan | command_id: command_id(99)},
      %{valid_plan | command_hash: :binary.copy(<<0xFF>>, 32)},
      %{valid_plan | command_type: :set_wifi},
      %{valid_plan | proof: :unverified},
      Map.put(valid_plan, :extra, :field),
      Map.delete(valid_plan, :command_id)
    ]

    for invalid_plan <- invalid_plans do
      assert {:error, :invalid_command_rejection_plan} = Store.reject_intent(store, invalid_plan)
    end

    assert Store.pending_intent(store) == intent

    plan = valid_plan
    Agent.update(effect_state, &Map.put(&1, intent.command_hash, :applied))
    assert {:error, :effect_non_application_unverified} = Store.reject_intent(store, plan)

    Agent.update(effect_state, &Map.put(&1, intent.command_hash, :absent))
    assert {:ok, ack, rejected} = Store.reject_intent(store, plan)
    assert ack.status == :rejected
    assert ack.reason == :operational_gate_closed
    assert ack.result == <<>>
    assert Store.pending_intent(rejected) == nil
    assert Store.snapshot(rejected).next_expected_sequence == 2
  end

  test "pending intents require a validated recovery verifier on admission and reopen", %{root: root} do
    invalid_path = Path.join(root, "invalid-verifier.snapshot")

    assert {:error, {:invalid_command_ledger_option, :recovery_verifiers}} =
             open_store(invalid_path,
               recovery_verifiers: %{set_tracking: {__MODULE__, nil}}
             )

    missing_path = Path.join(root, "missing-verifier.snapshot")
    assert {:ok, missing_store} = open_store(missing_path, recovery_verifiers: %{})
    missing_delivery = delivery(command_id: command_id(1))

    assert {:error, {:missing_command_recovery_verifier, :set_tracking}} =
             Store.begin_intent(
               missing_store,
               execution_plan(missing_delivery, :set_tracking, 8)
             )

    {:ok, effect_state} = Agent.start_link(fn -> %{} end)
    pending_path = Path.join(root, "pending-verifier.snapshot")
    assert {:ok, pending_store} = open_verified_store(pending_path, effect_state)
    pending_delivery = delivery(command_id: command_id(2))

    assert {:ok, _intent, _pending} =
             Store.begin_intent(
               pending_store,
               execution_plan(pending_delivery, :set_tracking, 8)
             )

    assert {:error, {:missing_command_recovery_verifier, :set_tracking}} =
             open_store(pending_path, recovery_verifiers: %{})
  end

  test "recovery verifier failures and timeouts fail closed without clearing the intent", %{root: root} do
    for behavior <- [:raise, :throw, :exit, :unexpected] do
      path = Path.join([root, "verifier-failure", Atom.to_string(behavior), "ledger.snapshot"])

      assert {:ok, store} =
               open_store(path,
                 recovery_verifiers: %{set_tracking: {FailingRecoveryVerifier, behavior}}
               )

      delivery = delivery(command_id: command_id(1))
      assert {:ok, intent, pending} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 8))
      plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)

      assert {:error, :effect_non_application_unverified} = Store.reject_intent(pending, plan)

      assert {:ok, reopened} =
               open_store(path,
                 recovery_verifiers: %{set_tracking: {FailingRecoveryVerifier, behavior}}
               )

      assert Store.pending_intent(reopened) == intent
    end

    timeout_path = Path.join(root, "verifier-timeout.snapshot")

    assert {:ok, timeout_store} =
             open_store(timeout_path,
               recovery_timeout_ms: 25,
               recovery_verifiers: %{set_tracking: {HungRecoveryVerifier, nil}}
             )

    timeout_delivery = delivery(command_id: command_id(2))

    assert {:ok, timeout_intent, timeout_pending} =
             Store.begin_intent(
               timeout_store,
               execution_plan(timeout_delivery, :set_tracking, 8)
             )

    timeout_plan = rejection_plan(timeout_intent, :effect_verified_absent, :operational_gate_closed)
    assert {:error, :command_recovery_verifier_timeout} = Store.reject_intent(timeout_pending, timeout_plan)

    assert {:ok, timeout_reopened} =
             open_store(timeout_path,
               recovery_timeout_ms: 25,
               recovery_verifiers: %{set_tracking: {HungRecoveryVerifier, nil}}
             )

    assert Store.pending_intent(timeout_reopened) == timeout_intent
  end

  test "recovery verifier must invoke the exact durable transition exactly once", %{root: root} do
    cases = [
      {:missing, NoTransitionRecoveryVerifier, :effect_non_application_unverified, true},
      {
        :duplicate,
        DoubleTransitionRecoveryVerifier,
        {:command_ledger_durability_uncertain, :command_recovery_verifier_invalid_transition},
        false
      },
      {
        :mismatched,
        MismatchedTransitionRecoveryVerifier,
        {:command_ledger_durability_uncertain, :command_recovery_verifier_result_mismatch},
        false
      }
    ]

    for {name, verifier, expected_error, pending_after?} <- cases do
      path = Path.join([root, "verifier-transition", Atom.to_string(name), "ledger.snapshot"])

      assert {:ok, store} =
               open_store(path,
                 recovery_verifiers: %{set_tracking: {verifier, nil}}
               )

      delivery = delivery(command_id: command_id(1))
      assert {:ok, intent, pending} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 8))
      plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)

      assert {:error, ^expected_error} = Store.reject_intent(pending, plan)

      assert {:ok, reopened} =
               open_store(path,
                 recovery_verifiers: %{set_tracking: {verifier, nil}}
               )

      if pending_after?,
        do: assert(Store.pending_intent(reopened) == intent),
        else: assert(Store.pending_intent(reopened) == nil)
    end
  end

  test "a verifier cannot defer the durable transition until after returning", %{root: root} do
    path = Path.join(root, "verifier-deferred-transition.snapshot")

    assert {:ok, store} =
             open_store(path,
               recovery_verifiers: %{
                 set_tracking: {AsyncTransitionRecoveryVerifier, {self(), :deferred}}
               }
             )

    delivery = delivery(command_id: command_id(1))
    assert {:ok, intent, pending} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 8))
    plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)

    assert {:error, :effect_non_application_unverified} = Store.reject_intent(pending, plan)
    assert_receive {:async_recovery_transition_spawned, transition_process}
    send(transition_process, :run_deferred_transition)

    assert_receive {:async_recovery_transition_result, ^transition_process, {:error, :recovery_transition_unavailable}}

    assert {:ok, reopened} =
             open_store(path,
               recovery_verifiers: %{
                 set_tracking: {AsyncTransitionRecoveryVerifier, {self(), :deferred}}
               }
             )

    assert Store.pending_intent(reopened) == intent
  end

  test "a verifier cannot return while its asynchronous durable transition is running", %{root: root} do
    path = Path.join(root, "verifier-running-async-transition.snapshot")
    parent = self()
    {:ok, armed} = Agent.start_link(fn -> false end)
    {:ok, verifier_waiter} = Agent.start_link(fn -> nil end)

    injector = fn
      :before_rename ->
        if Agent.get(armed, & &1) do
          send(Agent.get(verifier_waiter, & &1), :async_recovery_transition_started)
          send(parent, {:async_recovery_before_rename, self()})

          receive do
            :release_async_recovery -> :ok
          end
        else
          :ok
        end

      _stage ->
        :ok
    end

    assert {:ok, store} =
             open_store(path,
               fault_injector: injector,
               recovery_verifiers: %{
                 set_tracking: {AsyncTransitionRecoveryVerifier, {self(), {:await_started, verifier_waiter}}}
               }
             )

    delivery = delivery(command_id: command_id(1))
    assert {:ok, intent, pending} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 8))
    Agent.update(armed, fn _disarmed -> true end)
    plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)
    rejection_task = Task.async(fn -> Store.reject_intent(pending, plan) end)

    assert_receive {:async_recovery_transition_spawned, _transition_process}
    assert_receive {:async_recovery_before_rename, writer}
    assert Task.yield(rejection_task, 75) == nil
    send(writer, :release_async_recovery)

    assert {:error, {:command_ledger_durability_uncertain, :command_recovery_verifier_result_mismatch}} =
             Task.await(rejection_task)

    assert_receive {:async_recovery_transition_result, _transition_process, {:ok, _persisted}}

    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened) == nil
    assert Map.fetch!(Store.snapshot(reopened).outcomes, delivery.command_id).status == :rejected
  end

  test "caller death cannot release the path lock while recovery persistence survives", %{root: root} do
    path = Path.join(root, "verifier-caller-death.snapshot")
    parent = self()
    {:ok, fault_state} = Agent.start_link(fn -> %{armed?: false, blocked?: false} end)
    {:ok, verifier_waiter} = Agent.start_link(fn -> nil end)

    injector = fn
      :before_rename ->
        block? =
          Agent.get_and_update(fault_state, fn state ->
            if state.armed? and not state.blocked? do
              {true, %{state | blocked?: true}}
            else
              {false, state}
            end
          end)

        if block? do
          send(Agent.get(verifier_waiter, & &1), :async_recovery_transition_started)
          send(parent, {:orphaned_recovery_before_rename, self()})

          receive do
            :release_orphaned_recovery -> :ok
          end
        end

        :ok

      _stage ->
        :ok
    end

    assert {:ok, store} =
             open_store(path,
               fault_injector: injector,
               recovery_verifiers: %{
                 set_tracking: {AsyncTransitionRecoveryVerifier, {self(), {:await_started, verifier_waiter}}}
               }
             )

    delivery = delivery(command_id: command_id(1))
    assert {:ok, intent, pending} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 8))
    Agent.update(fault_state, &%{&1 | armed?: true})
    plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)
    rejection_task = Task.async(fn -> Store.reject_intent(pending, plan) end)

    assert_receive {:orphaned_recovery_before_rename, recovery_writer}
    assert Task.shutdown(rejection_task, :brutal_kill) == nil

    completion_task = Task.async(fn -> Store.complete_intent(pending, "applied") end)
    assert Task.yield(completion_task, 75) == nil
    send(recovery_writer, :release_orphaned_recovery)

    assert {:error, :stale_command_ledger_store} = Task.await(completion_task)
    assert_receive {:async_recovery_transition_result, _transition_process, {:ok, _persisted}}

    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened) == nil
    assert Map.fetch!(Store.snapshot(reopened).outcomes, delivery.command_id).status == :rejected
  end

  test "verifier worker death cannot release the lock while its transition executor survives", %{root: root} do
    path = Path.join(root, "verifier-worker-death.snapshot")
    parent = self()
    {:ok, armed} = Agent.start_link(fn -> false end)
    {:ok, verifier_waiter} = Agent.start_link(fn -> nil end)

    injector = fn
      :before_rename ->
        if Agent.get(armed, & &1) do
          send(Agent.get(verifier_waiter, & &1), :async_recovery_transition_started)
          send(parent, {:worker_death_recovery_before_rename, self()})

          receive do
            :release_worker_death_recovery -> :ok
          end
        end

        :ok

      _stage ->
        :ok
    end

    assert {:ok, store} =
             open_store(path,
               fault_injector: injector,
               recovery_verifiers: %{
                 set_tracking: {AsyncTransitionRecoveryVerifier, {self(), {:kill_after_started, verifier_waiter}}}
               }
             )

    delivery = delivery(command_id: command_id(1))
    assert {:ok, intent, pending} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 8))
    Agent.update(armed, fn _disarmed -> true end)
    plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)
    rejection_task = Task.async(fn -> Store.reject_intent(pending, plan) end)

    assert_receive {:worker_death_recovery_before_rename, recovery_writer}
    assert Task.yield(rejection_task, 75) == nil
    send(recovery_writer, :release_worker_death_recovery)

    assert {:error, {:command_ledger_durability_uncertain, :command_recovery_verifier_failed}} =
             Task.await(rejection_task)

    assert_receive {:async_recovery_transition_result, ^recovery_writer, {:ok, _persisted}}

    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened) == nil
    assert Map.fetch!(Store.snapshot(reopened).outcomes, delivery.command_id).status == :rejected
  end

  test "transition executor death fails closed without retaining the path lock", %{root: root} do
    path = Path.join(root, "recovery-transition-executor-death.snapshot")
    parent = self()
    {:ok, armed} = Agent.start_link(fn -> false end)
    {:ok, effect_state} = Agent.start(fn -> %{} end)

    injector = fn
      :before_rename ->
        if Agent.get(armed, & &1) do
          send(parent, {:recovery_transition_runner_before_rename, self()})

          receive do
            :never_release_recovery_transition_runner -> :ok
          end
        end

        :ok

      _stage ->
        :ok
    end

    assert {:ok, store} =
             open_verified_store(path, effect_state,
               fault_injector: injector,
               recovery_timeout_ms: 5_000
             )

    delivery = delivery(command_id: command_id(1))
    assert {:ok, intent, pending} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 8))
    Agent.update(effect_state, &Map.put(&1, intent.command_hash, :absent))
    Agent.update(armed, fn _disarmed -> true end)
    plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)
    rejection_task = Task.async(fn -> Store.reject_intent(pending, plan) end)

    assert_receive {:recovery_transition_runner_before_rename, transition_runner}
    Process.exit(transition_runner, :kill)

    assert {:error, {:command_ledger_durability_uncertain, :command_recovery_transition_failed}} =
             Task.await(rejection_task)

    assert {:ok, reopened} = open_verified_store(path, effect_state)
    assert Store.pending_intent(reopened) == intent
    assert Store.snapshot(reopened).outcomes == %{}
  end

  test "a detached recovery writer cannot outlive the path lock and overwrite applied state", %{root: root} do
    path = Path.join(root, "detached-recovery-overwrite.snapshot")
    parent = self()
    {:ok, armed} = Agent.start_link(fn -> false end)
    {:ok, verifier_waiter} = Agent.start_link(fn -> nil end)

    injector = fn
      :before_rename ->
        if Agent.get(armed, & &1) do
          send(Agent.get(verifier_waiter, & &1), :async_recovery_transition_started)
          send(parent, {:detached_recovery_before_rename, self()})

          receive do
            :release_detached_recovery_writer -> :ok
          end
        end

        :ok

      _stage ->
        :ok
    end

    assert {:ok, store} =
             open_store(path,
               fault_injector: injector,
               recovery_timeout_ms: 100,
               recovery_verifiers: %{
                 set_tracking: {AsyncTransitionRecoveryVerifier, {self(), {:await_started, verifier_waiter}}}
               }
             )

    delivery = delivery(command_id: command_id(1))
    assert {:ok, intent, pending} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 8))
    Agent.update(armed, fn _disarmed -> true end)
    plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)
    rejection_task = Task.async(fn -> Store.reject_intent(pending, plan) end)

    assert_receive {:detached_recovery_before_rename, detached_writer}, 2_000
    holder = linked_process!(detached_writer)
    holder_monitor = Process.monitor(holder)
    writer_monitor = Process.monitor(detached_writer)

    Process.exit(holder, :kill)

    assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :killed}, 2_000
    assert_receive {:DOWN, ^writer_monitor, :process, ^detached_writer, :killed}, 2_000
    assert {:error, :command_ledger_lock_holder_failed} = Task.await(rejection_task)

    Agent.update(armed, fn _armed -> false end)
    assert {:ok, _ack, _applied} = Store.complete_intent(pending, "applied")

    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened) == nil
    assert Map.fetch!(Store.snapshot(reopened).outcomes, delivery.command_id).status == :applied
  end

  test "reopen reclaims a detached recovery temp only after holder death fences its writer", %{root: root} do
    path = Path.join(root, "detached-recovery-cleanup.snapshot")
    parent = self()
    suffix = "DeTaChEdWrItEr01"
    {:ok, armed} = Agent.start_link(fn -> false end)
    {:ok, verifier_waiter} = Agent.start_link(fn -> nil end)

    injector = fn
      :temp_synced ->
        if Agent.get(armed, & &1) do
          send(Agent.get(verifier_waiter, & &1), :async_recovery_transition_started)
          send(parent, {:detached_recovery_temp_synced, self()})

          receive do
            :release_detached_recovery_temp -> :ok
          end
        end

        :ok

      _stage ->
        :ok
    end

    assert {:ok, store} =
             open_store(path,
               fault_injector: injector,
               temp_suffix: fn -> suffix end,
               recovery_timeout_ms: 100,
               recovery_verifiers: %{
                 set_tracking: {AsyncTransitionRecoveryVerifier, {self(), {:await_started, verifier_waiter}}}
               }
             )

    delivery = delivery(command_id: command_id(1))
    assert {:ok, intent, pending} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 8))
    Agent.update(armed, fn _disarmed -> true end)
    plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)
    rejection_task = Task.async(fn -> Store.reject_intent(pending, plan) end)

    assert_receive {:detached_recovery_temp_synced, detached_writer}, 2_000
    holder = linked_process!(detached_writer)
    holder_monitor = Process.monitor(holder)
    writer_monitor = Process.monitor(detached_writer)
    orphan = path <> ".tmp." <> suffix

    Process.exit(holder, :kill)

    assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :killed}, 2_000
    assert_receive {:DOWN, ^writer_monitor, :process, ^detached_writer, :killed}, 2_000
    assert {:error, :command_ledger_lock_holder_failed} = Task.await(rejection_task)
    assert File.exists?(orphan)

    assert {:ok, _reopened} = open_store(path)
    refute File.exists?(orphan)
  end

  test "holder death after parent sync reports typed durability uncertainty", %{root: root} do
    path = Path.join(root, "holder-death-after-parent-sync.snapshot")
    parent = self()
    {:ok, armed} = Agent.start_link(fn -> false end)

    injector = fn
      :parent_synced ->
        if Agent.get(armed, & &1) do
          send(parent, :holder_parent_synced)
          Process.exit(self(), :kill)
        end

        :ok

      _stage ->
        :ok
    end

    assert {:ok, store} = open_store(path, fault_injector: injector)
    Agent.update(armed, fn _disarmed -> true end)
    plan = execution_plan(delivery(command_id: command_id(1)), :set_tracking, 8)

    assert {:error, {:command_ledger_durability_uncertain, :command_ledger_lock_holder_failed}} =
             Store.begin_intent(store, plan)

    assert_receive :holder_parent_synced, 2_000
    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened) != nil
  end

  test "unreadable authority after holder death reports typed durability uncertainty", %{root: root} do
    path = Path.join(root, "holder-death-unreadable.snapshot")
    parent = self()
    suffix = "UnReAdAbLeStAtE1"
    {:ok, armed} = Agent.start_link(fn -> false end)

    injector = fn
      :temp_synced ->
        if Agent.get(armed, & &1) do
          send(parent, {:unreadable_holder_temp_synced, self()})

          receive do
            :never_release_unreadable_holder -> :ok
          end
        end

        :ok

      _stage ->
        :ok
    end

    assert {:ok, store} =
             open_store(path,
               file_system: ToggleReadFailureFileSystem,
               fault_injector: injector,
               temp_suffix: fn -> suffix end
             )

    Agent.update(armed, fn _disarmed -> true end)
    plan = execution_plan(delivery(command_id: command_id(1)), :set_tracking, 8)
    writer_task = Task.async(fn -> Store.begin_intent(store, plan) end)
    assert_receive {:unreadable_holder_temp_synced, holder}, 2_000

    ToggleReadFailureFileSystem.fail_reads()
    Process.exit(holder, :kill)

    assert {:error, {:command_ledger_durability_uncertain, :command_ledger_lock_holder_failed}} =
             Task.await(writer_task)

    ToggleReadFailureFileSystem.reset()
    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened) == nil
  end

  test "externally killed writers parked after temp sync accumulate until reopen", %{root: root} do
    path = Path.join(root, "externally-killed-writer.snapshot")
    parent = self()
    suffix = "AbCdEfGhIjKlMnOp"
    {:ok, armed} = Agent.start_link(fn -> false end)

    injector = fn
      :temp_synced ->
        if Agent.get(armed, & &1) do
          send(parent, {:ledger_writer_parked_after_temp_sync, self()})

          receive do
            :never_release_parked_ledger_writer -> :ok
          end
        end

        :ok

      _stage ->
        :ok
    end

    assert {:ok, store} =
             open_store(path,
               fault_injector: injector,
               temp_suffix: fn -> suffix end
             )

    plan = execution_plan(delivery(command_id: command_id(1)), :set_tracking, 8)
    Agent.update(armed, fn _disarmed -> true end)

    for expected_temp <- [path <> ".tmp." <> suffix, path <> ".tmp." <> suffix <> ".2"] do
      writer_task = Task.async(fn -> Store.begin_intent(store, plan) end)
      assert_receive {:ledger_writer_parked_after_temp_sync, writer}, 2_000
      Process.exit(writer, :kill)
      assert {:error, :command_ledger_lock_holder_failed} = Task.await(writer_task)
      assert File.exists?(expected_temp)
    end

    assert Enum.sort(Path.wildcard(path <> ".tmp.*")) ==
             Enum.sort([path <> ".tmp." <> suffix, path <> ".tmp." <> suffix <> ".2"])

    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened) == nil
    assert Store.snapshot(reopened).outcomes == %{}
    assert Path.wildcard(path <> ".tmp.*") == []
  end

  test "reopen cannot reclaim a live writer temp while the path lock is held", %{root: root} do
    path = Path.join(root, "live-writer-temp.snapshot")
    parent = self()
    suffix = "QrStUvWxYz012345"
    {:ok, armed} = Agent.start_link(fn -> false end)

    injector = fn
      :temp_synced ->
        if Agent.get(armed, & &1) do
          send(parent, {:live_ledger_writer_parked_after_temp_sync, self()})

          receive do
            :release_live_ledger_writer -> :ok
          end
        end

        :ok

      _stage ->
        :ok
    end

    assert {:ok, store} =
             open_store(path,
               fault_injector: injector,
               temp_suffix: fn -> suffix end
             )

    delivery = delivery(command_id: command_id(1))
    plan = execution_plan(delivery, :set_tracking, 8)
    Agent.update(armed, fn _disarmed -> true end)
    writer_task = Task.async(fn -> Store.begin_intent(store, plan) end)

    assert_receive {:live_ledger_writer_parked_after_temp_sync, writer}, 2_000
    live_temp = path <> ".tmp." <> suffix
    assert File.exists?(live_temp)

    reopen_task = Task.async(fn -> open_store(path) end)
    assert Task.yield(reopen_task, 75) == nil
    assert File.exists?(live_temp)

    send(writer, :release_live_ledger_writer)
    assert {:ok, intent, _persisted} = Task.await(writer_task)
    assert {:ok, reopened} = Task.await(reopen_task)
    assert Store.pending_intent(reopened) == intent
    assert Path.wildcard(path <> ".tmp.*") == []
  end

  test "missing-parent symlink changes reacquire the canonical path lock before I/O", %{root: root} do
    target_dir = Path.join(root, "target")
    alias_dir = Path.join(root, "alias")
    direct_path = Path.join(target_dir, "ledger.snapshot")
    alias_path = Path.join(alias_dir, "ledger.snapshot")
    parent = self()
    suffix = "SyMlInKrAcE_1234"
    {:ok, armed} = Agent.start_link(fn -> false end)

    injector = fn
      :temp_synced ->
        if Agent.get(armed, & &1) do
          send(parent, {:direct_writer_parked_for_symlink_race, self()})

          receive do
            :release_direct_writer_after_symlink_race -> :ok
          end
        end

        :ok

      _stage ->
        :ok
    end

    assert {:ok, direct_store} =
             open_store(direct_path,
               fault_injector: injector,
               temp_suffix: fn -> suffix end
             )

    plan = execution_plan(delivery(command_id: command_id(1)), :set_tracking, 8)
    Agent.update(armed, fn _disarmed -> true end)
    writer_task = Task.async(fn -> Store.begin_intent(direct_store, plan) end)
    assert_receive {:direct_writer_parked_for_symlink_race, direct_writer}, 2_000

    BlockingMkdirFileSystem.attach(self(), alias_dir)
    alias_task = Task.async(fn -> open_store(alias_path, file_system: BlockingMkdirFileSystem) end)
    assert_receive {:ledger_parent_mkdir_blocked, mkdir_holder}, 2_000
    File.ln_s!(target_dir, alias_dir)
    send(mkdir_holder, :release_ledger_parent_mkdir)

    premature_alias_result = Task.yield(alias_task, 75)
    assert File.exists?(direct_path <> ".tmp." <> suffix)
    send(direct_writer, :release_direct_writer_after_symlink_race)
    assert {:ok, intent, _persisted} = Task.await(writer_task)

    alias_result =
      case premature_alias_result do
        nil -> Task.await(alias_task)
        {:ok, result} -> result
      end

    assert premature_alias_result == nil
    assert {:ok, alias_store} = alias_result
    assert Store.pending_intent(alias_store) == intent
  end

  test "verifier death after a completed transition reports committed uncertainty", %{root: root} do
    path = Path.join(root, "recovery-verifier-post-commit-death.snapshot")

    assert {:ok, store} =
             open_store(path,
               recovery_verifiers: %{
                 set_tracking: {CommitThenCrashRecoveryVerifier, self()}
               }
             )

    delivery = delivery(command_id: command_id(1))
    assert {:ok, intent, pending} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 8))
    plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)

    assert {:error, {:command_ledger_durability_uncertain, :command_recovery_verifier_failed}} =
             Store.reject_intent(pending, plan)

    assert_receive {:crashing_recovery_transition_completed, {:ok, _persisted}}

    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened) == nil
    assert Map.fetch!(Store.snapshot(reopened).outcomes, delivery.command_id).status == :rejected
  end

  test "executor death after parent sync reports uncertainty for the durable rejection", %{root: root} do
    path = Path.join(root, "recovery-transition-post-sync-death.snapshot")
    parent = self()
    {:ok, armed} = Agent.start_link(fn -> false end)

    injector = fn
      :parent_synced ->
        if Agent.get(armed, & &1) do
          send(parent, :recovery_transition_parent_synced)
          Process.exit(self(), :kill)
        end

        :ok

      _stage ->
        :ok
    end

    assert {:ok, store} =
             open_store(path,
               fault_injector: injector,
               recovery_verifiers: %{set_tracking: {DirectRecoveryVerifier, nil}}
             )

    delivery = delivery(command_id: command_id(1))
    assert {:ok, intent, pending} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 8))
    Agent.update(armed, fn _disarmed -> true end)
    plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)

    assert {:error, {:command_ledger_durability_uncertain, :command_recovery_transition_failed}} =
             Store.reject_intent(pending, plan)

    assert_receive :recovery_transition_parent_synced

    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened) == nil
    assert Map.fetch!(Store.snapshot(reopened).outcomes, delivery.command_id).status == :rejected
  end

  test "post-rename filesystem crashes report transition uncertainty", %{root: root} do
    path = Path.join(root, "recovery-transition-post-rename-crash.snapshot")

    assert {:ok, store} =
             open_store(path,
               recovery_verifiers: %{set_tracking: {DirectRecoveryVerifier, nil}}
             )

    delivery = delivery(command_id: command_id(1))
    assert {:ok, intent, pending} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 8))
    plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)

    faulted = %{
      pending
      | file_system: PostRenameCrashFileSystem,
        atomic_opts: Keyword.put(pending.atomic_opts, :file_system, PostRenameCrashFileSystem)
    }

    assert {:error, {:command_ledger_durability_uncertain, {:destination_file_sync, {:callback_failed, :raise}}}} =
             Store.reject_intent(faulted, plan)

    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened) == nil
    assert Map.fetch!(Store.snapshot(reopened).outcomes, delivery.command_id).status == :rejected
  end

  test "timeout after the durable transition reports uncertainty without restoring the intent", %{root: root} do
    path = Path.join(root, "verifier-post-transition-timeout.snapshot")

    assert {:ok, store} =
             open_store(path,
               recovery_timeout_ms: 25,
               recovery_verifiers: %{set_tracking: {CommitThenHangRecoveryVerifier, self()}}
             )

    delivery = delivery(command_id: command_id(1))
    assert {:ok, intent, pending} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 8))
    plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)

    assert {:error, {:command_ledger_durability_uncertain, :command_recovery_verifier_timeout}} =
             Store.reject_intent(pending, plan)

    assert_receive {:recovery_transition_completed, {:ok, _persisted}}

    assert {:ok, reopened} =
             open_store(path,
               recovery_timeout_ms: 25,
               recovery_verifiers: %{set_tracking: {CommitThenHangRecoveryVerifier, self()}}
             )

    assert Store.pending_intent(reopened) == nil
    assert Map.fetch!(Store.snapshot(reopened).outcomes, delivery.command_id).status == :rejected
  end

  test "timeout cannot release the path lock while a durable recovery transition is running", %{root: root} do
    path = Path.join(root, "verifier-active-transition-timeout.snapshot")
    parent = self()
    {:ok, armed} = Agent.start_link(fn -> false end)
    {:ok, effect_state} = Agent.start_link(fn -> %{} end)

    injector = fn
      :before_rename ->
        if Agent.get(armed, & &1) do
          send(parent, {:active_recovery_transition, self()})

          receive do
            :release_active_recovery_transition -> :ok
          end
        else
          :ok
        end

      _stage ->
        :ok
    end

    assert {:ok, store} =
             open_verified_store(path, effect_state,
               fault_injector: injector,
               recovery_timeout_ms: 25
             )

    delivery = delivery(command_id: command_id(1))
    assert {:ok, intent, pending} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 8))
    Agent.update(effect_state, &Map.put(&1, intent.command_hash, :absent))
    Agent.update(armed, fn _disarmed -> true end)
    plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)
    rejection_task = Task.async(fn -> Store.reject_intent(pending, plan) end)

    assert_receive {:active_recovery_transition, writer}
    assert Task.yield(rejection_task, 75) == nil
    send(writer, :release_active_recovery_transition)

    assert {:error, {:command_ledger_durability_uncertain, :command_recovery_verifier_timeout}} =
             Task.await(rejection_task)
  end

  test "recovery verifier holds effect ownership through the durable rejection", %{root: root} do
    path = Path.join(root, "recovery-lease.snapshot")
    parent = self()
    {:ok, armed} = Agent.start_link(fn -> false end)
    {:ok, effect_state} = Agent.start_link(fn -> %{} end)

    injector = fn
      :before_rename ->
        if Agent.get(armed, & &1) do
          send(parent, {:rejection_before_rename, self()})

          receive do
            :release_rejection -> :ok
          end
        else
          :ok
        end

      _stage ->
        :ok
    end

    assert {:ok, store} =
             open_verified_store(path, effect_state,
               fault_injector: injector,
               recovery_timeout_ms: 5_000
             )

    delivery = delivery(command_id: command_id(1))
    assert {:ok, intent, pending} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 8))
    Agent.update(effect_state, &Map.put(&1, intent.command_hash, :absent))
    Agent.update(armed, fn _disarmed -> true end)
    plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)
    rejection_task = Task.async(fn -> Store.reject_intent(pending, plan) end)
    assert_receive {:rejection_before_rename, writer}

    effect_task =
      Task.async(fn ->
        Agent.get_and_update(effect_state, fn effects ->
          case Map.get(effects, intent.command_hash) do
            :absent -> {:applied, Map.put(effects, intent.command_hash, :applied)}
            status -> {{:blocked, status}, effects}
          end
        end)
      end)

    assert Task.yield(effect_task, 50) == nil
    send(writer, :release_rejection)
    assert {:ok, _ack, _rejected} = Task.await(rejection_task)
    assert {:blocked, :rejected} = Task.await(effect_task)
  end

  test "verified rejection persists before ACK and fails closed at every durability boundary", %{root: root} do
    success_path = Path.join(root, "rejection-success.snapshot")
    {:ok, success_effects} = Agent.start_link(fn -> %{} end)
    assert {:ok, success_store} = open_verified_store(success_path, success_effects)
    success_delivery = delivery(command_id: command_id(1))

    assert {:ok, success_intent, success_store} =
             begin_intent(success_store, execution_plan(success_delivery, :set_tracking, 8))

    Agent.update(success_effects, &Map.put(&1, success_intent.command_hash, :not_started))
    success_plan = rejection_plan(success_intent, :effect_not_started, :operational_gate_closed)
    assert {:ok, success_ack, _rejected} = Store.reject_intent(success_store, success_plan)
    assert success_ack.status == :rejected

    assert {:ok, success_reopened} = open_verified_store(success_path, success_effects)
    assert Store.pending_intent(success_reopened) == nil
    assert Map.fetch!(Store.snapshot(success_reopened).outcomes, success_delivery.command_id).status == :rejected

    pre_path = Path.join(root, "rejection-pre.snapshot")
    {:ok, pre_effects} = Agent.start_link(fn -> %{} end)
    {pre_armed, pre_injector} = armed_fail_at(:before_rename)
    assert {:ok, pre_store} = open_verified_store(pre_path, pre_effects, fault_injector: pre_injector)
    pre_delivery = delivery(command_id: command_id(2))
    assert {:ok, pre_intent, pre_store} = begin_intent(pre_store, execution_plan(pre_delivery, :set_tracking, 8))
    Agent.update(pre_effects, &Map.put(&1, pre_intent.command_hash, :absent))
    arm_fault(pre_armed)
    pre_plan = rejection_plan(pre_intent, :effect_verified_absent, :operational_gate_closed)

    assert {:error, {:write_command_ledger, {:pre_rename, {:fault_injected, :before_rename, :power_loss}}}} =
             Store.reject_intent(pre_store, pre_plan)

    assert {:ok, pre_reopened} = open_verified_store(pre_path, pre_effects)
    assert Store.pending_intent(pre_reopened) == pre_intent
    assert Store.snapshot(pre_reopened).outcomes == %{}

    uncertain_path = Path.join(root, "rejection-uncertain.snapshot")
    {:ok, uncertain_effects} = Agent.start_link(fn -> %{} end)
    {uncertain_armed, uncertain_injector} = armed_fail_at(:renamed)

    assert {:ok, uncertain_store} =
             open_verified_store(uncertain_path, uncertain_effects, fault_injector: uncertain_injector)

    uncertain_delivery = delivery(command_id: command_id(3))

    assert {:ok, uncertain_intent, uncertain_store} =
             begin_intent(uncertain_store, execution_plan(uncertain_delivery, :set_tracking, 8))

    Agent.update(uncertain_effects, &Map.put(&1, uncertain_intent.command_hash, :absent))
    arm_fault(uncertain_armed)
    uncertain_plan = rejection_plan(uncertain_intent, :effect_verified_absent, :operational_gate_closed)

    assert {:error, {:command_ledger_durability_uncertain, {:fault_injected, :renamed, :power_loss}}} =
             Store.reject_intent(uncertain_store, uncertain_plan)

    assert {:ok, uncertain_reopened} = open_verified_store(uncertain_path, uncertain_effects)
    assert Store.pending_intent(uncertain_reopened) == nil

    uncertain_outcome =
      Map.fetch!(Store.snapshot(uncertain_reopened).outcomes, uncertain_delivery.command_id)

    assert uncertain_outcome.status == :rejected
    assert uncertain_outcome.reason == :operational_gate_closed
  end

  test "strictly higher epochs reset history atomically only at sequence one without an intent", %{path: path} do
    assert {:ok, store} = open_store(path)
    first = delivery(command_epoch: 1, command_sequence: 1, command_id: command_id(1))

    assert {:ok, _ack, store} =
             Store.record_terminal(store, terminal_plan(first, :expired, reset_epoch?: true))

    assert Store.snapshot(store).command_epoch == 1
    assert map_size(Store.snapshot(store).outcomes) == 1

    higher = delivery(command_epoch: 2, command_sequence: 1, command_id: command_id(2))

    assert {:error, :invalid_command_epoch_transition} =
             Store.record_terminal(store, terminal_plan(higher, :expired))

    invalid_reset = delivery(command_epoch: 2, command_sequence: 2, command_id: command_id(2))

    assert {:error, :invalid_command_epoch_transition} =
             Store.record_terminal(
               store,
               terminal_plan(invalid_reset, :expired, reset_epoch?: true)
             )

    assert {:ok, ack, reset} =
             Store.record_terminal(store, terminal_plan(higher, :expired, reset_epoch?: true))

    assert ack.command_epoch == 2
    assert Store.snapshot(reset).command_epoch == 2
    assert Store.snapshot(reset).next_expected_sequence == 2
    refute Map.has_key?(Store.snapshot(reset).outcomes, first.command_id)
    assert Map.keys(Store.snapshot(reset).outcomes) == [higher.command_id]

    next_epoch = delivery(command_epoch: 3, command_sequence: 1, command_id: command_id(3))

    assert {:ok, _intent, pending} =
             begin_intent(reset, execution_plan(next_epoch, :set_tracking, 8, reset_epoch?: true))

    another_epoch = delivery(command_epoch: 4, command_sequence: 1, command_id: command_id(4))

    assert {:error, :pending_command_intent} =
             begin_intent(
               pending,
               execution_plan(another_epoch, :set_tracking, 8, reset_epoch?: true)
             )
  end

  test "count and aggregate-result-byte budgets reject transitions without pruning", %{root: root} do
    count_path = Path.join(root, "count.snapshot")
    assert {:ok, count_store} = open_store(count_path, max_outcomes: 1)
    first = delivery(command_id: command_id(1))
    assert {:ok, _ack, count_store} = Store.record_terminal(count_store, terminal_plan(first, :expired))

    assert {:error, {:command_ledger_capacity, :outcome_count}} =
             begin_intent(
               count_store,
               execution_plan(
                 delivery(command_id: command_id(2), command_sequence: 2),
                 :set_tracking,
                 1
               )
             )

    assert Map.keys(Store.snapshot(count_store).outcomes) == [first.command_id]

    bytes_path = Path.join(root, "bytes.snapshot")
    assert {:ok, byte_store} = open_store(bytes_path, max_result_bytes: 4)
    applied = delivery(command_id: command_id(3))
    assert {:ok, _intent, byte_store} = begin_intent(byte_store, execution_plan(applied, :set_tracking, 4))
    assert {:ok, _ack, byte_store} = Store.complete_intent(byte_store, "1234")
    assert Store.usage(byte_store) == %{outcomes: 1, result_bytes: 4}

    assert {:error, {:command_ledger_capacity, :result_bytes}} =
             begin_intent(
               byte_store,
               execution_plan(
                 delivery(command_id: command_id(4), command_sequence: 2),
                 :set_tracking,
                 1
               )
             )

    assert {:ok, roomy} = open_store(Path.join(root, "reservation.snapshot"), max_result_bytes: 8)
    reserved = delivery(command_id: command_id(5))
    assert {:ok, _intent, pending} = begin_intent(roomy, execution_plan(reserved, :set_tracking, 3))
    assert {:error, :command_result_reservation_exceeded} = Store.complete_intent(pending, "four")
    assert Store.pending_intent(pending) != nil
  end

  test "lowered admission limits never make retained outcomes or pending recovery unreadable", %{root: root} do
    path = Path.join(root, "reduced-limits.snapshot")
    assert {:ok, store} = open_store(path, max_outcomes: 2, max_result_bytes: 8)
    first = delivery(command_id: command_id(1))
    assert {:ok, _intent, store} = begin_intent(store, execution_plan(first, :set_tracking, 4))
    assert {:ok, _ack, store} = Store.complete_intent(store, "1234")

    second = delivery(command_id: command_id(2), command_sequence: 2)
    assert {:ok, intent, _store} = begin_intent(store, execution_plan(second, :set_tracking, 1))

    assert {:ok, reopened} = open_store(path, max_outcomes: 1, max_result_bytes: 4)
    assert Store.pending_intent(reopened) == intent
    assert Store.usage(reopened) == %{outcomes: 1, result_bytes: 4}

    assert {:ok, _ack, completed} = Store.complete_intent(reopened, "x")
    assert Store.usage(completed) == %{outcomes: 2, result_bytes: 5}

    assert {:ok, reopened_completed} = open_store(path, max_outcomes: 1, max_result_bytes: 4)
    assert Store.snapshot(reopened_completed) == Store.snapshot(completed)

    third = delivery(command_id: command_id(3), command_sequence: 3)

    assert {:error, {:command_ledger_capacity, :outcome_count}} =
             begin_intent(reopened_completed, execution_plan(third, :set_tracking, 1))

    byte_path = Path.join(root, "reduced-byte-limit.snapshot")
    assert {:ok, byte_store} = open_store(byte_path, max_outcomes: 3, max_result_bytes: 8)
    byte_delivery = delivery(command_id: command_id(4))
    assert {:ok, _intent, byte_store} = begin_intent(byte_store, execution_plan(byte_delivery, :set_tracking, 4))
    assert {:ok, _ack, _byte_store} = Store.complete_intent(byte_store, "1234")
    assert {:ok, byte_reopened} = open_store(byte_path, max_outcomes: 3, max_result_bytes: 4)
    next_byte = delivery(command_id: command_id(5), command_sequence: 2)

    assert {:error, {:command_ledger_capacity, :result_bytes}} =
             begin_intent(byte_reopened, execution_plan(next_byte, :set_tracking, 1))

    reject_path = Path.join(root, "reduced-rejection-limits.snapshot")
    {:ok, reject_effects} = Agent.start_link(fn -> %{} end)

    assert {:ok, reject_store} =
             open_verified_store(reject_path, reject_effects,
               max_outcomes: 2,
               max_result_bytes: 8
             )

    reject_delivery = delivery(command_id: command_id(6))

    assert {:ok, reject_intent, _reject_store} =
             begin_intent(reject_store, execution_plan(reject_delivery, :set_tracking, 8))

    Agent.update(reject_effects, &Map.put(&1, reject_intent.command_hash, :absent))

    assert {:ok, reject_reopened} =
             open_verified_store(reject_path, reject_effects,
               max_outcomes: 1,
               max_result_bytes: 1
             )

    reject_plan = rejection_plan(reject_intent, :effect_verified_absent, :operational_gate_closed)
    assert {:ok, _ack, rejected} = Store.reject_intent(reject_reopened, reject_plan)
    assert Store.usage(rejected) == %{outcomes: 1, result_bytes: 0}
  end

  test "open re-establishes a visible outcome before it can become replay authority", %{root: root} do
    path = Path.join(root, "reestablish.snapshot")
    assert {:ok, clean} = open_store(path)
    delivery = delivery(command_id: command_id(1))
    assert {:ok, _intent, _pending} = begin_intent(clean, execution_plan(delivery, :set_tracking, 8))

    {:ok, armed} = Agent.start_link(fn -> false end)

    injector = fn
      :renamed ->
        if Agent.get(armed, & &1),
          do: {:error, :simulated_power_loss},
          else: :ok

      _stage ->
        :ok
    end

    assert {:ok, faulted} = open_store(path, fault_injector: injector)
    Agent.update(armed, fn _ -> true end)

    assert {:error, {:command_ledger_durability_uncertain, {:fault_injected, :renamed, :simulated_power_loss}}} =
             Store.complete_intent(faulted, "result")

    assert {:error, {:write_command_ledger, {:pre_rename, {:fault_injected, :before_rename, :power_loss}}}} =
             open_store(path, fault_injector: fail_at(:before_rename))

    assert {:error, {:command_ledger_durability_uncertain, {:fault_injected, :renamed, :power_loss}}} =
             open_store(path, fault_injector: fail_at(:renamed))

    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened) == nil
    assert Map.fetch!(Store.snapshot(reopened).outcomes, delivery.command_id).result == "result"
  end

  test "open re-establishes a visible intent before it can authorize recovery", %{root: root} do
    path = Path.join(root, "reestablish-intent.snapshot")
    assert {:ok, clean} = open_store(path)
    delivery = delivery(command_id: command_id(1))
    {armed, injector} = armed_fail_at(:renamed)
    assert {:ok, faulted} = open_store(path, fault_injector: injector)
    arm_fault(armed)

    assert {:error, {:command_ledger_durability_uncertain, {:fault_injected, :renamed, :power_loss}}} =
             begin_intent(faulted, execution_plan(delivery, :set_tracking, 8))

    assert Store.pending_intent(clean) == nil

    assert {:error, {:write_command_ledger, {:pre_rename, {:fault_injected, :before_rename, :power_loss}}}} =
             open_store(path, fault_injector: fail_at(:before_rename))

    assert {:error, {:command_ledger_durability_uncertain, {:fault_injected, :renamed, :power_loss}}} =
             open_store(path, fault_injector: fail_at(:renamed))

    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened).command_id == delivery.command_id
    assert Store.snapshot(reopened).outcomes == %{}
  end

  test "concurrent handles cannot both pass the snapshot check before replacing state", %{root: root} do
    path = Path.join(root, "concurrent-handles.snapshot")
    parent = self()
    {:ok, armed} = Agent.start_link(fn -> false end)

    injector = fn
      :before_rename ->
        if Agent.get(armed, & &1) do
          send(parent, {:before_rename, self()})

          receive do
            :release_rename -> :ok
          end
        else
          :ok
        end

      _stage ->
        :ok
    end

    assert {:ok, clean} = open_store(path)
    assert {:ok, store} = open_store(path, fault_injector: injector)
    Agent.update(armed, fn _disarmed -> true end)

    first = delivery(command_id: command_id(1), payload: "first")
    second = delivery(command_id: command_id(2), payload: "second")

    first_task =
      Task.async(fn -> begin_intent(store, execution_plan(first, :set_tracking, 8)) end)

    assert_receive {:before_rename, first_writer}

    second_task =
      Task.async(fn -> begin_intent(store, execution_plan(second, :set_tracking, 8)) end)

    second_reached_commit =
      receive do
        {:before_rename, second_writer} ->
          send(second_writer, :release_rename)
          true
      after
        100 -> false
      end

    send(first_writer, :release_rename)

    assert {:ok, first_intent, _pending} = Task.await(first_task)
    assert first_intent.command_id == first.command_id
    assert {:error, :stale_command_ledger_store} = Task.await(second_task)
    refute second_reached_commit

    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened).command_id == first.command_id
    assert Store.pending_intent(clean) == nil
  end

  test "symlink aliases share the same transaction lock", %{root: root} do
    real_path = Path.join(root, "real/ledger.snapshot")
    alias_root = Path.join(root, "alias")
    alias_path = Path.join(alias_root, "ledger.snapshot")
    parent = self()
    {:ok, armed} = Agent.start_link(fn -> false end)

    assert {:ok, _created} = open_store(real_path)
    File.ln_s!(Path.dirname(real_path), alias_root)

    injector = fn
      :before_rename ->
        if Agent.get(armed, & &1) do
          send(parent, {:alias_before_rename, self()})

          receive do
            :release_alias_rename -> :ok
          end
        else
          :ok
        end

      _stage ->
        :ok
    end

    assert {:ok, real_store} = open_store(real_path, fault_injector: injector)
    assert {:ok, alias_store} = open_store(alias_path, fault_injector: injector)
    Agent.update(armed, fn _disarmed -> true end)

    first = delivery(command_id: command_id(1), payload: "real")
    second = delivery(command_id: command_id(2), payload: "alias")

    first_task =
      Task.async(fn -> begin_intent(real_store, execution_plan(first, :set_tracking, 8)) end)

    assert_receive {:alias_before_rename, first_writer}

    second_task =
      Task.async(fn -> begin_intent(alias_store, execution_plan(second, :set_tracking, 8)) end)

    alias_reached_commit =
      receive do
        {:alias_before_rename, alias_writer} ->
          send(alias_writer, :release_alias_rename)
          true
      after
        100 -> false
      end

    send(first_writer, :release_alias_rename)

    assert {:ok, _intent, _pending} = Task.await(first_task)
    assert {:error, :stale_command_ledger_store} = Task.await(second_task)
    refute alias_reached_commit
  end

  test "open cannot rewrite a snapshot that advances while durability is re-established", %{root: root} do
    path = Path.join(root, "concurrent-open.snapshot")
    parent = self()
    assert {:ok, clean} = open_store(path)
    delivery = delivery(command_id: command_id(1))
    assert {:ok, _intent, pending} = begin_intent(clean, execution_plan(delivery, :set_tracking, 8))

    injector = fn
      :before_rename ->
        send(parent, {:open_before_rename, self()})

        receive do
          :release_open -> :ok
        end

      _stage ->
        :ok
    end

    open_task = Task.async(fn -> open_store(path, fault_injector: injector) end)
    assert_receive {:open_before_rename, opener}

    completion_task =
      Task.async(fn ->
        result = Store.complete_intent(pending, "result")
        send(parent, {:completion_finished, result})
        result
      end)

    completion_raced_open =
      receive do
        {:completion_finished, _result} -> true
      after
        100 -> false
      end

    send(opener, :release_open)
    assert {:ok, _opened} = Task.await(open_task)
    assert {:ok, _ack, _completed} = Task.await(completion_task)
    refute completion_raced_open

    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened) == nil
    assert Map.fetch!(Store.snapshot(reopened).outcomes, delivery.command_id).result == "result"
  end

  test "a stale handle cannot overwrite a visible applied outcome after durability uncertainty", %{root: root} do
    path = Path.join(root, "stale-handle.snapshot")
    assert {:ok, clean} = open_store(path)
    delivery = delivery(command_id: command_id(1))
    assert {:ok, intent, _pending} = begin_intent(clean, execution_plan(delivery, :set_tracking, 8))
    {armed, injector} = armed_fail_at(:renamed)
    assert {:ok, faulted} = open_store(path, fault_injector: injector)
    arm_fault(armed)

    assert {:error, {:command_ledger_durability_uncertain, {:fault_injected, :renamed, :power_loss}}} =
             Store.complete_intent(faulted, "result")

    Agent.update(armed, fn _armed -> false end)
    plan = rejection_plan(intent, :effect_verified_absent, :operational_gate_closed)
    assert {:error, :stale_command_ledger_store} = Store.reject_intent(faulted, plan)

    assert {:ok, reopened} = open_store(path)
    assert Store.pending_intent(reopened) == nil
    outcome = Map.fetch!(Store.snapshot(reopened).outcomes, delivery.command_id)
    assert outcome.status == :applied
    assert outcome.result == "result"
  end

  test "every mutator rejects an immutable handle after disk advances", %{root: root} do
    path = Path.join(root, "all-stale-mutators.snapshot")
    assert {:ok, clean} = open_store(path)
    first = delivery(command_id: command_id(1))
    assert {:ok, _intent, pending} = begin_intent(clean, execution_plan(first, :set_tracking, 8))

    competing = delivery(command_id: command_id(2), payload: "competing")

    assert {:error, :stale_command_ledger_store} =
             begin_intent(clean, execution_plan(competing, :set_tracking, 8))

    assert {:ok, _ack, completed} = Store.complete_intent(pending, "result")
    assert {:error, :stale_command_ledger_store} = Store.complete_intent(pending, "other")

    terminal = delivery(command_id: command_id(3), payload: "terminal")

    assert {:error, :stale_command_ledger_store} =
             Store.record_terminal(clean, terminal_plan(terminal, :expired))

    assert Store.pending_intent(completed) == nil
    assert Map.fetch!(Store.snapshot(completed).outcomes, first.command_id).result == "result"
  end

  test "transitions never release execution or ACK on directory-sync uncertainty", %{root: root} do
    for stage <- @pre_rename_faults do
      path = Path.join([root, "pre", Atom.to_string(stage), "ledger.snapshot"])
      assert {:ok, _clean} = open_store(path)
      {armed, injector} = armed_fail_at(stage)
      assert {:ok, faulted} = open_store(path, fault_injector: injector)
      arm_fault(armed)
      delivery = delivery(command_id: command_id(1))

      assert {:error, {:write_command_ledger, {:pre_rename, {:fault_injected, ^stage, :power_loss}}}} =
               begin_intent(faulted, execution_plan(delivery, :set_tracking, 8))

      assert {:ok, reopened} = open_store(path)
      assert Store.pending_intent(reopened) == nil
    end

    for stage <- @uncertain_faults do
      path = Path.join([root, "uncertain", Atom.to_string(stage), "ledger.snapshot"])
      assert {:ok, _clean} = open_store(path)
      {armed, injector} = armed_fail_at(stage)
      assert {:ok, faulted} = open_store(path, fault_injector: injector)
      arm_fault(armed)
      delivery = delivery(command_id: command_id(1))

      assert {:error, {:command_ledger_durability_uncertain, {:fault_injected, ^stage, :power_loss}}} =
               begin_intent(faulted, execution_plan(delivery, :set_tracking, 8))

      assert {:ok, reopened} = open_store(path)
      assert Store.pending_intent(reopened).command_id == delivery.command_id
    end

    for stage <- @durable_faults do
      path = Path.join([root, "durable", Atom.to_string(stage), "ledger.snapshot"])
      assert {:ok, _clean} = open_store(path)
      {armed, injector} = armed_fail_at(stage)
      assert {:ok, faulted} = open_store(path, fault_injector: injector)
      arm_fault(armed)
      delivery = delivery(command_id: command_id(1))

      assert {:ok, intent, _store} =
               begin_intent(faulted, execution_plan(delivery, :set_tracking, 8))

      assert {:ok, reopened} = open_store(path)
      assert Store.pending_intent(reopened) == intent
    end

    for stage <- @pre_rename_faults do
      path = Path.join([root, "outcome-pre", Atom.to_string(stage), "ledger.snapshot"])
      assert {:ok, clean} = open_store(path)
      delivery = delivery(command_id: command_id(1))
      assert {:ok, intent, _pending} = begin_intent(clean, execution_plan(delivery, :set_tracking, 8))
      {armed, injector} = armed_fail_at(stage)
      assert {:ok, faulted} = open_store(path, fault_injector: injector)
      arm_fault(armed)

      assert {:error, {:write_command_ledger, {:pre_rename, {:fault_injected, ^stage, :power_loss}}}} =
               Store.complete_intent(faulted, "result")

      assert {:ok, reopened} = open_store(path)
      assert Store.pending_intent(reopened) == intent
      assert Store.snapshot(reopened).outcomes == %{}
    end

    for stage <- @uncertain_faults do
      path = Path.join([root, "outcome-uncertain", Atom.to_string(stage), "ledger.snapshot"])
      assert {:ok, clean} = open_store(path)
      delivery = delivery(command_id: command_id(1))
      assert {:ok, _intent, _pending} = begin_intent(clean, execution_plan(delivery, :set_tracking, 8))
      {armed, injector} = armed_fail_at(stage)
      assert {:ok, faulted} = open_store(path, fault_injector: injector)
      arm_fault(armed)

      assert {:error, {:command_ledger_durability_uncertain, {:fault_injected, ^stage, :power_loss}}} =
               Store.complete_intent(faulted, "result")

      assert {:ok, reopened} = open_store(path)
      assert Store.pending_intent(reopened) == nil
      assert Map.fetch!(Store.snapshot(reopened).outcomes, delivery.command_id).result == "result"
    end

    for stage <- @durable_faults do
      path = Path.join([root, "outcome-durable", Atom.to_string(stage), "ledger.snapshot"])
      assert {:ok, clean} = open_store(path)
      delivery = delivery(command_id: command_id(1))
      assert {:ok, _intent, _pending} = begin_intent(clean, execution_plan(delivery, :set_tracking, 8))
      {armed, injector} = armed_fail_at(stage)
      assert {:ok, faulted} = open_store(path, fault_injector: injector)
      arm_fault(armed)

      assert {:ok, ack, _completed} = Store.complete_intent(faulted, "result")
      assert ack.result == "result"
    end
  end

  defp classify(delivery, store, runtime_state) do
    context =
      runtime_state
      |> Agent.get(& &1)
      |> Map.merge(%{snapshot: Store.snapshot(store), limits: Store.limits(store)})

    Ledger.classify(delivery, context)
  end

  defp admission_runtime(overrides) do
    defaults = %{
      active_generation: 42,
      active_manifest_hash: @manifest_hash,
      trusted_now_ms: 1_700_000_000_000,
      decode_payload: fn payload -> {:ok, %{type: :set_tracking, payload: payload}} end,
      resolve_type: fn %{type: :set_tracking} -> {:ok, :set_tracking, 16} end,
      gate: open_gate()
    }

    Map.merge(defaults, Map.new(overrides))
  end

  defp open_gate, do: {:open, open_gate_binding()}

  defp open_gate_binding do
    %{
      credential_epoch: 7,
      storage_epoch: @storage_epoch,
      generation: 42,
      manifest_hash: @manifest_hash
    }
  end

  defp begin_intent(store, plan, _trusted_now_ms \\ 1_700_000_000_000),
    do: Store.begin_intent(store, plan)

  defp open_verified_store(path, effect_state, overrides \\ []) do
    open_store(
      path,
      Keyword.put(overrides, :recovery_verifiers, %{
        set_tracking: {RecoveryVerifier, effect_state}
      })
    )
  end

  defp open_store(path, overrides \\ []) do
    defaults = [
      device_id: @device_id,
      credential_epoch: 7,
      storage_epoch: @storage_epoch,
      max_outcomes: 8,
      max_result_bytes: 1_024,
      admission_authority: {PermissiveAdmissionAuthority, nil},
      recovery_verifiers: %{set_tracking: {DenyRecoveryVerifier, nil}}
    ]

    Store.open(path, Keyword.merge(defaults, overrides))
  end

  defp delivery(overrides) do
    payload = Keyword.get(overrides, :payload, "command")
    payload_hash = :crypto.hash(:sha256, payload)

    attrs = %{
      device_id: Keyword.get(overrides, :device_id, @device_id),
      credential_epoch: Keyword.get(overrides, :credential_epoch, 7),
      storage_epoch: Keyword.get(overrides, :storage_epoch, @storage_epoch),
      required_generation: Keyword.get(overrides, :required_generation, 42),
      required_manifest_hash: Keyword.get(overrides, :required_manifest_hash, @manifest_hash),
      command_epoch: Keyword.get(overrides, :command_epoch, 0),
      command_sequence: Keyword.get(overrides, :command_sequence, 1),
      command_id: Keyword.get(overrides, :command_id, command_id(1)),
      expires_at_ms: Keyword.get(overrides, :expires_at_ms, 1_800_000_000_000),
      payload_hash: payload_hash
    }

    assert {:ok, command_hash} = Command.hash(attrs)
    attrs |> Map.put(:command_hash, command_hash) |> Map.put(:payload, payload)
  end

  defp execution_plan(delivery, command_type, reserved_result_bytes, overrides \\ []) do
    %{
      action: :execute,
      delivery: delivery,
      command_type: command_type,
      reserved_result_bytes: reserved_result_bytes,
      reset_epoch?: Keyword.get(overrides, :reset_epoch?, false)
    }
  end

  defp rejection_plan(intent, proof, reason) do
    %{
      action: :reject,
      command_id: intent.command_id,
      command_hash: intent.command_hash,
      command_type: intent.command_type,
      proof: proof,
      reason: reason
    }
  end

  defp terminal_plan(delivery, reason, overrides \\ []) do
    %{
      action: :terminal,
      delivery: delivery,
      status: :rejected,
      reason: reason,
      result: <<>>,
      reset_epoch?: Keyword.get(overrides, :reset_epoch?, false)
    }
  end

  defp command_id(n), do: <<n::128>>

  defp linked_process!(pid) do
    {:links, links} = Process.info(pid, :links)

    case links do
      [linked] -> linked
      _other -> flunk("expected recovery writer to link only to the command-ledger lock holder")
    end
  end

  defp armed_fail_at(stage) do
    {:ok, armed} = Agent.start_link(fn -> false end)

    injector = fn
      ^stage ->
        if Agent.get(armed, & &1),
          do: {:error, :power_loss},
          else: :ok

      _other ->
        :ok
    end

    {armed, injector}
  end

  defp arm_fault(armed), do: Agent.update(armed, fn _disarmed -> true end)

  defp fail_at(stage) do
    fn
      ^stage -> {:error, :power_loss}
      _other -> :ok
    end
  end
end
