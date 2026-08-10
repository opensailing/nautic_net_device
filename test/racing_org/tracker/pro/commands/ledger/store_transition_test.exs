defmodule RacingOrg.Tracker.Pro.Commands.Ledger.StoreTransitionTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands.Ledger.Store
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Command, Messages}

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
  @post_rename_faults [:renamed, :parent_synced]

  setup do
    root = Path.join(System.tmp_dir!(), "command_ledger_transition_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, path: Path.join(root, "ledger.snapshot")}
  end

  test "persists intent before exposing execution and persists exact outcome before exposing ACK", %{path: path} do
    assert {:ok, store} = open_store(path)
    delivery = delivery(command_id: command_id(1), payload: <<0x00, 0xFF, "effect">>)
    plan = execution_plan(delivery, :set_tracking, 32)

    assert {:ok, intent, _store} = Store.begin_intent(store, plan)
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
    assert {:ok, ack, completed} = Store.complete_intent(interrupted, result, 1_700_000_000_000)
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
    assert {:ok, intent, store} = Store.begin_intent(store, execution_plan(delivery, :set_tracking, 16))

    assert {:error, :pending_command_intent} =
             Store.begin_intent(
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
    assert {:ok, _ack, completed} = Store.complete_intent(reopened, "recovered", 1_700_000_000_000)
    assert Store.pending_intent(completed) == nil
  end

  test "expired, failed, and oversized effects have one durable bounded abort transition", %{root: root} do
    expired_path = Path.join(root, "expired.snapshot")
    assert {:ok, expired_store} = open_store(expired_path)
    expired_delivery = delivery(command_id: command_id(1), expires_at_ms: 100)

    assert {:ok, expired_intent, expired_store} =
             Store.begin_intent(expired_store, execution_plan(expired_delivery, :set_tracking, 8))

    assert {:error, :pending_command_intent_expired} =
             Store.complete_intent(expired_store, "late", expired_intent.expires_at_ms)

    assert {:ok, expired_ack, expired_store} = Store.abort_intent(expired_store, :expired)
    assert expired_ack.status == :rejected
    assert expired_ack.reason == :expired
    assert expired_ack.result == <<>>
    assert Store.pending_intent(expired_store) == nil

    assert {:ok, reopened_expired} = open_store(expired_path)
    assert Store.snapshot(reopened_expired) == Store.snapshot(expired_store)

    failed_path = Path.join(root, "failed.snapshot")
    assert {:ok, failed_store} = open_store(failed_path)
    failed_delivery = delivery(command_id: command_id(2))

    assert {:ok, _intent, failed_store} =
             Store.begin_intent(failed_store, execution_plan(failed_delivery, :set_tracking, 3))

    assert {:error, :command_result_reservation_exceeded} =
             Store.complete_intent(failed_store, "four", failed_delivery.expires_at_ms - 1)

    assert {:error, :invalid_command_abort_reason} = Store.abort_intent(failed_store, :arbitrary)
    assert Store.pending_intent(failed_store) != nil

    assert {:ok, failed_ack, failed_store} = Store.abort_intent(failed_store, :invalid_payload)
    assert failed_ack.status == :rejected
    assert failed_ack.reason == :invalid_payload
    assert Store.pending_intent(failed_store) == nil
    assert Store.snapshot(failed_store).next_expected_sequence == 2
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
             Store.begin_intent(reset, execution_plan(next_epoch, :set_tracking, 8, reset_epoch?: true))

    another_epoch = delivery(command_epoch: 4, command_sequence: 1, command_id: command_id(4))

    assert {:error, :pending_command_intent} =
             Store.begin_intent(
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
             Store.begin_intent(
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
    assert {:ok, _intent, byte_store} = Store.begin_intent(byte_store, execution_plan(applied, :set_tracking, 4))
    assert {:ok, _ack, byte_store} = Store.complete_intent(byte_store, "1234", 1_700_000_000_000)
    assert Store.usage(byte_store) == %{outcomes: 1, result_bytes: 4}

    assert {:error, {:command_ledger_capacity, :result_bytes}} =
             Store.begin_intent(
               byte_store,
               execution_plan(
                 delivery(command_id: command_id(4), command_sequence: 2),
                 :set_tracking,
                 1
               )
             )

    assert {:ok, roomy} = open_store(Path.join(root, "reservation.snapshot"), max_result_bytes: 8)
    reserved = delivery(command_id: command_id(5))
    assert {:ok, _intent, pending} = Store.begin_intent(roomy, execution_plan(reserved, :set_tracking, 3))
    assert {:error, :command_result_reservation_exceeded} = Store.complete_intent(pending, "four", 1_700_000_000_000)
    assert Store.pending_intent(pending) != nil
  end

  test "all transition fault stages resolve from the authoritative snapshot", %{root: root} do
    for stage <- @pre_rename_faults do
      path = Path.join([root, "pre", Atom.to_string(stage), "ledger.snapshot"])
      assert {:ok, _clean} = open_store(path)
      assert {:ok, faulted} = open_store(path, fault_injector: fail_at(stage))
      delivery = delivery(command_id: command_id(1))

      assert {:error, {:write_command_ledger, {:fault_injected, ^stage, :power_loss}}} =
               Store.begin_intent(faulted, execution_plan(delivery, :set_tracking, 8))

      assert {:ok, reopened} = open_store(path)
      assert Store.pending_intent(reopened) == nil
    end

    for stage <- @post_rename_faults do
      path = Path.join([root, "post", Atom.to_string(stage), "ledger.snapshot"])
      assert {:ok, _clean} = open_store(path)
      assert {:ok, faulted} = open_store(path, fault_injector: fail_at(stage))
      delivery = delivery(command_id: command_id(1))

      assert {:ok, intent, _store} =
               Store.begin_intent(faulted, execution_plan(delivery, :set_tracking, 8))

      assert {:ok, reopened} = open_store(path)
      assert Store.pending_intent(reopened) == intent
    end

    for stage <- @pre_rename_faults do
      path = Path.join([root, "outcome-pre", Atom.to_string(stage), "ledger.snapshot"])
      assert {:ok, clean} = open_store(path)
      delivery = delivery(command_id: command_id(1))
      assert {:ok, intent, _pending} = Store.begin_intent(clean, execution_plan(delivery, :set_tracking, 8))
      assert {:ok, faulted} = open_store(path, fault_injector: fail_at(stage))

      assert {:error, {:write_command_ledger, {:fault_injected, ^stage, :power_loss}}} =
               Store.complete_intent(faulted, "result", 1_700_000_000_000)

      assert {:ok, reopened} = open_store(path)
      assert Store.pending_intent(reopened) == intent
      assert Store.snapshot(reopened).outcomes == %{}
    end

    for stage <- @post_rename_faults do
      path = Path.join([root, "outcome-post", Atom.to_string(stage), "ledger.snapshot"])
      assert {:ok, clean} = open_store(path)
      delivery = delivery(command_id: command_id(1))
      assert {:ok, _intent, _pending} = Store.begin_intent(clean, execution_plan(delivery, :set_tracking, 8))
      assert {:ok, faulted} = open_store(path, fault_injector: fail_at(stage))

      assert {:ok, ack, _completed} = Store.complete_intent(faulted, "result", 1_700_000_000_000)
      assert ack.result == "result"

      assert {:ok, reopened} = open_store(path)
      assert Store.pending_intent(reopened) == nil
      assert Map.fetch!(Store.snapshot(reopened).outcomes, delivery.command_id).result == "result"
    end
  end

  defp open_store(path, overrides \\ []) do
    defaults = [
      device_id: @device_id,
      credential_epoch: 7,
      storage_epoch: @storage_epoch,
      max_outcomes: 8,
      max_result_bytes: 1_024
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

  defp fail_at(stage) do
    fn
      ^stage -> {:error, :power_loss}
      _other -> :ok
    end
  end
end
