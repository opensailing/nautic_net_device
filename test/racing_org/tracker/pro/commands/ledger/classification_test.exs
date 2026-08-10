defmodule RacingOrg.Tracker.Pro.Commands.Ledger.ClassificationTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands.Ledger
  alias RacingOrg.Tracker.Pro.Commands.Ledger.Store
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Command, Messages}

  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @other_device_id Base.decode16!("10112233445566778899aabbccddeeff", case: :lower)
  @storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @other_storage_epoch Base.decode16!("102132435465768798a9bacbdcedfe0f", case: :lower)
  @manifest_hash :binary.copy(<<0xB2>>, 32)
  @other_manifest_hash :binary.copy(<<0xC3>>, 32)

  setup do
    root = Path.join(System.tmp_dir!(), "command_ledger_classification_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    path = Path.join(root, "ledger.snapshot")
    assert {:ok, store} = open_store(path)
    %{path: path, store: store}
  end

  test "enforces device, credential, storage, generation, and manifest fences in exact order", %{store: store} do
    rows = [
      {delivery(device_id: @other_device_id), {:defer, :device_mismatch}},
      {delivery(credential_epoch: 8), {:transient, :stale_credential_epoch}},
      {delivery(storage_epoch: @other_storage_epoch), {:transient, :storage_epoch_mismatch}},
      {delivery(required_generation: 43), {:transient, :generation_mismatch}},
      {delivery(required_manifest_hash: @other_manifest_hash), {:transient, :manifest_hash_mismatch}}
    ]

    for {command, expected} <- rows do
      context = context(store, decode_payload: forbidden_callback(), resolve_type: forbidden_callback())
      result = Ledger.classify(command, context)

      case {expected, result} do
        {{:defer, reason}, {:defer, actual_reason}} when actual_reason == reason ->
          :ok

        {{:transient, reason}, {:transient, ack}} ->
          assert ack.reason == reason
          assert ack.status == :rejected
          assert ack.result == <<>>
          assert {:ok, _bytes} = Messages.encode(:command_ack, ack)

        other ->
          flunk("unexpected classification #{inspect(other)}")
      end
    end
  end

  test "checks command IDs within the current epoch and replays exact retained result bytes", %{store: store} do
    original = delivery(command_id: command_id(1), payload: <<0x00, 0xFF, "original">>)
    assert {:ok, _intent, store} = Store.begin_intent(store, execution_plan(original, 32))
    result = <<0x00, 0xFF, "exact-result">>
    assert {:ok, _ack, store} = Store.complete_intent(store, result, 1_700_000_000_000)

    assert {:duplicate, duplicate_ack} = Ledger.classify(original, context(store))
    assert duplicate_ack.status == :duplicate
    assert duplicate_ack.reason == :none
    assert duplicate_ack.result == result
    assert {:ok, encoded} = Messages.encode(:command_ack, duplicate_ack)
    assert {:ok, ^duplicate_ack} = Messages.decode(:command_ack, encoded)

    conflict =
      delivery(
        command_id: original.command_id,
        command_sequence: 2,
        payload: "different"
      )

    assert {:transient, conflict_ack} = Ledger.classify(conflict, context(store))
    assert conflict_ack.reason == :command_id_conflict
  end

  test "higher epoch resets may reuse command IDs while same-epoch conflicts fail closed", %{store: store} do
    original = delivery(command_id: command_id(1), expires_at_ms: 0)
    assert {:ok, _ack, store} = Store.record_terminal(store, terminal_plan(original, :expired))

    reset =
      delivery(
        command_id: original.command_id,
        command_epoch: 1,
        command_sequence: 1,
        payload: "new-epoch-command"
      )

    assert {:execute, plan} = Ledger.classify(reset, context(store))
    assert plan.reset_epoch? == true
    assert plan.delivery == reset
  end

  test "rejects tampered command hashes and out-of-range higher epochs before execution", %{store: store} do
    valid = delivery(command_id: command_id(1))
    invalid_hash = %{valid | command_hash: :binary.copy(<<0xFE>>, 32)}

    invalid_epoch = %{
      valid
      | command_epoch: 0x1_0000_0000,
        command_hash: valid.command_hash
    }

    guarded_context = context(store, decode_payload: forbidden_callback(), resolve_type: forbidden_callback())

    assert {:defer, :invalid_command_delivery} = Ledger.classify(invalid_hash, guarded_context)
    assert {:defer, :invalid_command_delivery} = Ledger.classify(invalid_epoch, guarded_context)
  end

  test "replays retained rejected outcomes byte-for-byte instead of fabricating duplicate success", %{store: store} do
    original = delivery(command_id: command_id(1), expires_at_ms: 0)
    assert {:ok, original_ack, store} = Store.record_terminal(store, terminal_plan(original, :expired))
    assert {:ok, original_bytes} = Messages.encode(:command_ack, original_ack)

    assert {:duplicate, replayed_ack} = Ledger.classify(original, context(store, trusted_now_ms: 1))
    assert replayed_ack == original_ack
    assert replayed_ack.status == :rejected
    assert replayed_ack.reason == :expired
    assert replayed_ack.result_hash == original_ack.result_hash
    assert {:ok, ^original_bytes} = Messages.encode(:command_ack, replayed_ack)
  end

  test "classifies old epochs, replays, gaps, and valid higher-epoch reset candidates", %{store: store} do
    epoch_two = delivery(command_epoch: 2, command_sequence: 1, command_id: command_id(1))

    assert {:ok, _ack, store} =
             Store.record_terminal(store, terminal_plan(epoch_two, :expired, reset_epoch?: true))

    assert_transient_reason(
      Ledger.classify(
        delivery(command_epoch: 1, command_sequence: 1, command_id: command_id(2)),
        context(store)
      ),
      :sequence_replay
    )

    assert_transient_reason(
      Ledger.classify(
        delivery(command_epoch: 2, command_sequence: 1, command_id: command_id(3)),
        context(store)
      ),
      :sequence_replay
    )

    assert_transient_reason(
      Ledger.classify(
        delivery(command_epoch: 2, command_sequence: 3, command_id: command_id(4)),
        context(store)
      ),
      :sequence_gap
    )

    assert_transient_reason(
      Ledger.classify(
        delivery(command_epoch: 3, command_sequence: 2, command_id: command_id(5)),
        context(store)
      ),
      :sequence_gap
    )

    higher = delivery(command_epoch: 3, command_sequence: 1, command_id: command_id(6))
    assert {:execute, plan} = Ledger.classify(higher, context(store))
    assert plan.reset_epoch? == true
    assert plan.delivery == higher
    assert plan.command_type == :set_tracking
    assert plan.reserved_result_bytes == 16
  end

  test "defers without a trusted clock and treats zero expiry as expired at positive trusted time", %{store: store} do
    command = delivery(expires_at_ms: 0)

    assert {:defer, :trusted_clock_unavailable} =
             Ledger.classify(command, context(store, trusted_now_ms: :unavailable))

    assert {:terminal, plan} = Ledger.classify(command, context(store, trusted_now_ms: 1))
    assert plan.reason == :expired
    assert plan.status == :rejected
    assert plan.result == <<>>
    assert plan.reset_epoch? == false
  end

  test "checks payload, type, and operational gate in order", %{store: store} do
    owner = self()
    invalid_hash = %{delivery(payload: "valid") | payload: "tampered"}

    assert {:terminal, %{reason: :invalid_payload}} =
             Ledger.classify(
               invalid_hash,
               context(store,
                 decode_payload: fn _payload -> flunk("decoder called after payload hash failure") end,
                 resolve_type: forbidden_callback()
               )
             )

    assert {:terminal, %{reason: :invalid_payload}} =
             Ledger.classify(
               delivery(command_id: command_id(2)),
               context(store,
                 decode_payload: fn payload ->
                   send(owner, {:classification_step, :payload, payload})
                   {:error, :malformed}
                 end,
                 resolve_type: forbidden_callback()
               )
             )

    assert_receive {:classification_step, :payload, "command"}

    unsupported_context =
      context(store,
        decode_payload: fn payload ->
          send(owner, {:classification_step, :payload, payload})
          {:ok, %{type: :future_command}}
        end,
        resolve_type: fn decoded ->
          send(owner, {:classification_step, :type, decoded})
          :unsupported
        end
      )

    assert {:terminal, %{reason: :unsupported_command}} =
             Ledger.classify(delivery(command_id: command_id(3)), unsupported_context)

    assert_receive {:classification_step, :payload, "command"}
    assert_receive {:classification_step, :type, %{type: :future_command}}

    closed_context =
      context(store,
        decode_payload: fn payload ->
          send(owner, {:classification_step, :payload, payload})
          {:ok, %{type: :set_tracking}}
        end,
        resolve_type: fn decoded ->
          send(owner, {:classification_step, :type, decoded})
          {:ok, :set_tracking, 16}
        end,
        gate: :closed
      )

    assert_transient_reason(
      Ledger.classify(delivery(command_id: command_id(4)), closed_context),
      :operational_gate_closed
    )

    assert_receive {:classification_step, :payload, "command"}
    assert_receive {:classification_step, :type, %{type: :set_tracking}}

    assert {:execute, plan} = Ledger.classify(delivery(command_id: command_id(5)), context(store))
    assert plan.command_type == :set_tracking
    assert plan.reserved_result_bytes == 16
  end

  test "defers silently at count and aggregate-result-byte capacity but reset epochs reclaim history", %{path: path} do
    assert {:ok, count_store} = open_store(path <> ".count", max_outcomes: 1)
    first = delivery(command_id: command_id(1))
    assert {:ok, _ack, count_store} = Store.record_terminal(count_store, terminal_plan(first, :expired))

    assert {:defer, {:capacity, :outcome_count}} =
             Ledger.classify(
               delivery(command_id: command_id(2), command_sequence: 2),
               context(count_store)
             )

    expired = delivery(command_id: command_id(3), command_sequence: 2, expires_at_ms: 0)

    assert {:defer, {:capacity, :outcome_count}} =
             Ledger.classify(expired, context(count_store, trusted_now_ms: 1))

    reset = delivery(command_id: command_id(4), command_epoch: 1, command_sequence: 1)
    assert {:execute, %{reset_epoch?: true}} = Ledger.classify(reset, context(count_store))

    assert {:ok, byte_store} = open_store(path <> ".bytes", max_result_bytes: 5)
    applied = delivery(command_id: command_id(5))
    assert {:ok, _intent, byte_store} = Store.begin_intent(byte_store, execution_plan(applied, 4))
    assert {:ok, _ack, byte_store} = Store.complete_intent(byte_store, "1234", 1_700_000_000_000)

    assert {:defer, {:capacity, :result_bytes}} =
             Ledger.classify(
               delivery(command_id: command_id(6), command_sequence: 2),
               context(byte_store, resolve_type: fn _decoded -> {:ok, :set_tracking, 2} end)
             )
  end

  test "recovery requires trusted time and aborts expired pending intents", %{store: store} do
    command = delivery(command_id: command_id(1))
    assert {:ok, intent, store} = Store.begin_intent(store, execution_plan(command, 16))

    assert {:defer, :trusted_clock_unavailable} =
             Ledger.recover_pending(Store.snapshot(store), :unavailable)

    assert {:recover, ^intent} = Ledger.recover_pending(Store.snapshot(store), intent.expires_at_ms - 1)
    assert {:abort, ^intent, :expired} = Ledger.recover_pending(Store.snapshot(store), intent.expires_at_ms)

    next = delivery(command_id: command_id(2))
    assert {:defer, :pending_command_intent} = Ledger.classify(next, context(store))
  end

  test "classification performs no filesystem writes or durable advancement", %{path: path, store: store} do
    command = delivery(command_id: command_id(1))
    before_bytes = File.read!(path)
    before_snapshot = Store.snapshot(store)

    assert {:execute, _plan} = Ledger.classify(command, context(store))
    assert File.read!(path) == before_bytes
    assert Store.snapshot(store) == before_snapshot

    transient = delivery(command_id: command_id(2), command_sequence: 2)
    assert_transient_reason(Ledger.classify(transient, context(store)), :sequence_gap)
    assert File.read!(path) == before_bytes
    assert Store.snapshot(store) == before_snapshot
  end

  defp assert_transient_reason({:transient, ack}, reason) do
    assert ack.status == :rejected
    assert ack.reason == reason
    assert ack.result == <<>>
    assert {:ok, _bytes} = Messages.encode(:command_ack, ack)
  end

  defp context(store, overrides \\ []) do
    defaults = [
      snapshot: Store.snapshot(store),
      limits: Store.limits(store),
      active_generation: 42,
      active_manifest_hash: @manifest_hash,
      trusted_now_ms: 1_700_000_000_000,
      decode_payload: fn payload -> {:ok, %{type: :set_tracking, payload: payload}} end,
      resolve_type: fn %{type: :set_tracking} -> {:ok, :set_tracking, 16} end,
      gate:
        {:open,
         %{
           credential_epoch: 7,
           storage_epoch: @storage_epoch,
           generation: 42,
           manifest_hash: @manifest_hash
         }}
    ]

    Map.new(Keyword.merge(defaults, overrides))
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

  defp execution_plan(delivery, reserved_result_bytes) do
    %{
      action: :execute,
      delivery: delivery,
      command_type: :set_tracking,
      reserved_result_bytes: reserved_result_bytes,
      reset_epoch?: false
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

  defp forbidden_callback do
    fn _value -> flunk("classification reached a later step") end
  end

  defp command_id(n), do: <<n::128>>
end
