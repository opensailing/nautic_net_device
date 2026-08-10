defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.RecordTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Record

  @storage_epoch Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @entry_id Base.decode16!("102132435465768798a9bacbdcedfe0f", case: :lower)
  @device_id Base.decode16!("0f1e2d3c4b5a69788796a5b4c3d2e1f0", case: :lower)

  test "binds device id and credential epoch into every durable record kind" do
    payload = "payload"
    payload_hash = :crypto.hash(:sha256, payload)

    entry = %{
      kind: :entry,
      stream: "telemetry",
      device_id: @device_id,
      credential_epoch: 7,
      storage_epoch: @storage_epoch,
      sequence: 1,
      entry_id: @entry_id,
      payload_hash: payload_hash,
      payload: payload,
      priority: 1
    }

    acknowledgement = %{
      kind: :acknowledgement,
      stream: "telemetry",
      device_id: @device_id,
      credential_epoch: 7,
      storage_epoch: @storage_epoch,
      sequence: 1,
      payload_hash: payload_hash,
      cumulative_sequence: 0
    }

    loss = %{
      kind: :loss_authorization,
      stream: "health",
      device_id: @device_id,
      credential_epoch: 7,
      storage_epoch: @storage_epoch,
      sequence: 1,
      entry_id: @entry_id,
      payload_hash: payload_hash,
      reason: "operator approved"
    }

    for record <- [entry, acknowledgement, loss] do
      assert {:ok, encoded} = Record.encode(record)
      encoded_size = byte_size(encoded)
      assert {:ok, ^record, <<>>, ^encoded_size} = Record.decode_next(encoded)

      assert {:error, :invalid_device_id} = Record.encode(%{record | device_id: <<0::120>>})
      assert {:error, :invalid_device_id} = Record.encode(Map.delete(record, :device_id))
      assert {:error, :invalid_credential_epoch} = Record.encode(%{record | credential_epoch: -1})

      assert {:error, :invalid_credential_epoch} =
               Record.encode(%{record | credential_epoch: 0x1_0000_0000})

      assert {:error, :invalid_credential_epoch} =
               Record.encode(Map.delete(record, :credential_epoch))
    end
  end

  test "refuses to decode a record written before origin identity was bound" do
    body_length = 10
    guard = Bitwise.bxor(body_length, 0xFFFFFFFF)

    assert {:error, :unsupported_record_version} =
             Record.decode_next(<<"RODO", 1, 1, body_length::32, guard::32, 0::80>>)

    assert {:error, :invalid_partial_header} = Record.decode_next(<<"RODO", 1>>)
  end

  test "round-trips a versioned entry record with a positive signed bigint sequence" do
    payload = <<0, 1, 2, 255, 0, 128>>
    sequence = 1 <<< 130

    record = %{
      kind: :entry,
      stream: "telemetry",
      device_id: @device_id,
      credential_epoch: 3,
      storage_epoch: @storage_epoch,
      sequence: sequence,
      entry_id: @entry_id,
      payload_hash: :crypto.hash(:sha256, payload),
      payload: payload,
      priority: 201
    }

    assert {:ok, encoded} = Record.encode(record)
    encoded_size = byte_size(encoded)
    assert <<"RODO", 2, 1, _body_length::32, _length_guard::32, _body::binary>> = encoded

    assert {:ok, decoded, <<>>, ^encoded_size} = Record.decode_next(encoded)
    assert decoded == record
  end

  test "round-trips acknowledgement and loss authorization records" do
    payload_hash = :crypto.hash(:sha256, "payload")

    acknowledgement = %{
      kind: :acknowledgement,
      stream: "telemetry",
      device_id: @device_id,
      credential_epoch: 3,
      storage_epoch: @storage_epoch,
      sequence: 9,
      payload_hash: payload_hash,
      cumulative_sequence: 7
    }

    loss = %{
      kind: :loss_authorization,
      stream: "health",
      device_id: @device_id,
      credential_epoch: 3,
      storage_epoch: @storage_epoch,
      sequence: 4,
      entry_id: @entry_id,
      payload_hash: payload_hash,
      reason: "operator approved removal after damaged storage replacement"
    }

    for record <- [acknowledgement, loss] do
      assert {:ok, encoded} = Record.encode(record)
      encoded_size = byte_size(encoded)
      assert {:ok, ^record, <<>>, ^encoded_size} = Record.decode_next(encoded)
    end
  end

  test "rejects invalid entry semantics before encoding" do
    payload = "payload"

    valid = %{
      kind: :entry,
      stream: "telemetry",
      device_id: @device_id,
      credential_epoch: 3,
      storage_epoch: @storage_epoch,
      sequence: 1,
      entry_id: @entry_id,
      payload_hash: :crypto.hash(:sha256, payload),
      payload: payload,
      priority: 1
    }

    assert {:error, :invalid_sequence} = Record.encode(%{valid | sequence: 0})
    assert {:error, :invalid_storage_epoch} = Record.encode(%{valid | storage_epoch: <<0>>})
    assert {:error, :invalid_entry_id} = Record.encode(%{valid | entry_id: <<>>})
    assert {:error, :payload_hash_mismatch} = Record.encode(%{valid | payload_hash: <<0::256>>})
    assert {:error, :invalid_priority} = Record.encode(%{valid | priority: 256})
  end

  test "truncation accepts only a plausible canonical header prefix" do
    assert {:incomplete, 14} = Record.decode_next("RO")
    assert {:error, :invalid_partial_header} = Record.decode_next("RX")
    assert {:error, :invalid_partial_header} = Record.decode_next(<<"RODO", 3>>)
    assert {:error, :invalid_partial_header} = Record.decode_next(<<"RODO", 2, 99>>)
    assert {:error, :invalid_partial_header} = Record.decode_next(<<"RODO", 2, 1, 0xFF>>)

    body_length = 100
    guard = Bitwise.bxor(body_length, 0xFFFFFFFF)
    <<first_guard_byte, _rest::binary>> = <<guard::32>>

    assert {:incomplete, 114} =
             Record.decode_next(<<"RODO", 2, 1, body_length::32, first_guard_byte>>)

    assert {:error, :invalid_partial_header} =
             Record.decode_next(<<"RODO", 2, 1, body_length::32, Bitwise.bxor(first_guard_byte, 1)>>)
  end

  test "distinguishes a torn record from checksum and framing corruption" do
    payload = "payload"

    record = %{
      kind: :entry,
      stream: "telemetry",
      device_id: @device_id,
      credential_epoch: 3,
      storage_epoch: @storage_epoch,
      sequence: 1,
      entry_id: @entry_id,
      payload_hash: :crypto.hash(:sha256, payload),
      payload: payload,
      priority: 1
    }

    assert {:ok, encoded} = Record.encode(record)
    encoded_size = byte_size(encoded)

    assert {:incomplete, ^encoded_size} =
             Record.decode_next(binary_part(encoded, 0, encoded_size - 1))

    <<prefix::binary-size(byte_size(encoded) - 2), byte, suffix>> = encoded
    checksum_corruption = prefix <> <<Bitwise.bxor(byte, 1), suffix>>
    assert {:error, :checksum_mismatch} = Record.decode_next(checksum_corruption)

    <<magic_and_version::binary-size(6), body_length::32, length_guard::32, body::binary>> = encoded
    framing_corruption = magic_and_version <> <<body_length::32, Bitwise.bxor(length_guard, 1)::32, body::binary>>
    assert {:error, :invalid_length_guard} = Record.decode_next(framing_corruption)
  end
end
