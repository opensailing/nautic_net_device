defmodule RacingOrg.Tracker.Pro.SecureTransport.CommandV1ContractTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Command, Messages}

  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @device_uuid "00112233-4455-6677-8899-AABBCCDDEEFF"
  @storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @command_id Base.decode16!("0123456789abcdeffedcba9876543210", case: :lower)
  @command_uuid "01234567-89AB-CDEF-FEDC-BA9876543210"
  @manifest_hash :binary.copy(<<0xB2>>, 32)
  @database_int_max 9_223_372_036_854_775_807
  @payload <<0x00, 0xFF, "synthetic-command">>
  @result <<0x01, 0x02, 0x03, 0xFF>>

  describe "closed command registries" do
    test "freezes message assignments, domains, bounds, statuses, and reasons" do
      assert Contract.message_type(:command_delivery) ==
               {:ok, 0x20, :server_to_device}

      assert Contract.message_type(:command_ack) ==
               {:ok, 0x21, :device_to_server}

      assert Contract.payload_domain(:command_delivery) == "RacingOrg-CommandDelivery-v1"
      assert Contract.payload_domain(:command_ack) == "RacingOrg-CommandAck-v1"
      assert Contract.command_record_hash_domain() == "RacingOrg-CommandRecordHash-v1"
      assert Contract.command_result_hash_domain() == "RacingOrg-CommandResultHash-v1"
      assert Contract.max_command_payload_size() == 65_326
      assert Contract.max_command_result_size() == 65_337

      assert Contract.command_statuses() == [applied: 0x01, duplicate: 0x02, rejected: 0x03]

      assert Contract.command_reasons() == [
               none: 0x00,
               stale_credential_epoch: 0x01,
               storage_epoch_mismatch: 0x02,
               generation_mismatch: 0x03,
               manifest_hash_mismatch: 0x04,
               expired: 0x05,
               sequence_replay: 0x06,
               sequence_gap: 0x07,
               command_id_conflict: 0x08,
               unsupported_command: 0x09,
               invalid_payload: 0x0A,
               operational_gate_closed: 0x0B
             ]

      for {status, code} <- Contract.command_statuses() do
        assert Contract.command_status(status) == {:ok, code}
        assert Contract.command_status(code) == {:ok, status}
      end

      for {reason, code} <- Contract.command_reasons() do
        assert Contract.command_reason(reason) == {:ok, code}
        assert Contract.command_reason(code) == {:ok, reason}
      end

      assert {:error, :unknown_command_status} = Contract.command_status(:arbitrary)
      assert {:error, :unknown_command_reason} = Contract.command_reason(:arbitrary)
    end
  end

  describe "command delivery" do
    test "binds the exact canonical command record and round-trips exact wire bytes" do
      delivery = delivery_attrs()

      assert Map.keys(delivery) |> Enum.sort() ==
               [
                 :device_id,
                 :credential_epoch,
                 :storage_epoch,
                 :required_generation,
                 :required_manifest_hash,
                 :command_epoch,
                 :command_sequence,
                 :command_id,
                 :expires_at_ms,
                 :payload_hash,
                 :command_hash,
                 :payload
               ]
               |> Enum.sort()

      assert {:ok, delivery.payload_hash} == Command.payload_hash(delivery.payload)

      assert {:ok, delivery.command_hash} ==
               Command.hash(Map.drop(delivery, [:command_hash, :payload]))

      expected_payload_hash = :crypto.hash(:sha256, @payload)

      expected_command_hash =
        :crypto.hash(
          :sha256,
          Contract.command_record_hash_domain() <>
            <<Contract.version(), 0x20, @device_id::binary, 7::32, @storage_epoch::binary, 42::64,
              @manifest_hash::binary, 9::32, 11::64, @command_id::binary, 1_800_000_000_000::64,
              expected_payload_hash::binary>>
        )

      assert delivery.payload_hash == expected_payload_hash
      assert delivery.command_hash == expected_command_hash

      assert {:ok, bytes} = Messages.encode(:command_delivery, delivery)
      assert {:ok, ^delivery} = Messages.decode(:command_delivery, bytes)

      assert bytes ==
               Contract.payload_domain(:command_delivery) <>
                 <<Contract.version(), 0x20, @device_id::binary, 7::32, @storage_epoch::binary, 42::64,
                   @manifest_hash::binary, 9::32, 11::64, @command_id::binary, 1_800_000_000_000::64,
                   expected_payload_hash::binary, expected_command_hash::binary, byte_size(@payload)::32,
                   @payload::binary>>
    end

    test "normalizes canonical UUID strings to raw wire UUIDs" do
      raw = delivery_attrs()
      textual = %{raw | device_id: @device_uuid, command_id: @command_uuid}

      assert {:ok, raw.command_hash} ==
               Command.hash(Map.drop(textual, [:command_hash, :payload]))

      assert {:ok, raw_bytes} = Messages.encode(:command_delivery, raw)
      assert {:ok, ^raw_bytes} = Messages.encode(:command_delivery, textual)
      assert {:ok, ^raw} = Messages.decode(:command_delivery, raw_bytes)

      assert {:error, :invalid_device_id} =
               Messages.encode(:command_delivery, %{raw | device_id: "00112233445566778899aabbccddeeff"})

      assert {:error, :invalid_command_id} =
               Messages.encode(:command_delivery, %{raw | command_id: "not-a-uuid"})
    end

    test "requires exact keys, signed database bounds, fixed lengths, and binary payloads" do
      delivery = delivery_attrs()

      assert {:error, :invalid_command_delivery} =
               Messages.encode(:command_delivery, Map.delete(delivery, :payload))

      assert {:error, :invalid_command_delivery} =
               Messages.encode(:command_delivery, Map.put(delivery, :arbitrary, true))

      for {field, value, error} <- [
            {:credential_epoch, -1, :invalid_credential_epoch},
            {:credential_epoch, 0x1_0000_0000, :invalid_credential_epoch},
            {:required_generation, 0, :invalid_required_generation},
            {:required_generation, @database_int_max + 1, :invalid_required_generation},
            {:command_epoch, -1, :invalid_command_epoch},
            {:command_epoch, 0x1_0000_0000, :invalid_command_epoch},
            {:command_sequence, 0, :invalid_command_sequence},
            {:command_sequence, @database_int_max + 1, :invalid_command_sequence},
            {:expires_at_ms, -1, :invalid_expires_at_ms},
            {:expires_at_ms, @database_int_max + 1, :invalid_expires_at_ms},
            {:storage_epoch, <<0::128>>, :invalid_storage_epoch},
            {:required_manifest_hash, <<0>>, :invalid_required_manifest_hash},
            {:payload_hash, <<0>>, :invalid_payload_hash},
            {:command_hash, <<0>>, :invalid_command_hash},
            {:payload, :not_binary, :invalid_command_payload}
          ] do
        assert {:error, ^error} =
                 Messages.encode(:command_delivery, Map.put(delivery, field, value))
      end
    end

    test "enforces the exact maximum payload against the control plaintext ceiling" do
      payload = :binary.copy(<<0xA5>>, Contract.max_command_payload_size())
      delivery = delivery_attrs(payload)

      assert {:ok, bytes} = Messages.encode(:command_delivery, delivery)
      assert byte_size(bytes) == Contract.max_plaintext_size()
      assert {:ok, ^delivery} = Messages.decode(:command_delivery, bytes)

      oversized = :binary.copy(<<0xA5>>, Contract.max_command_payload_size() + 1)
      oversized_delivery = delivery_attrs(oversized)

      assert {:error, :command_payload_too_large} =
               Messages.encode(:command_delivery, oversized_delivery)

      assert {:error, :command_payload_too_large} = Command.payload_hash(oversized)
    end

    test "verifies both payload and record hashes on encode and decode" do
      delivery = delivery_attrs()

      assert {:error, :payload_hash_mismatch} =
               Messages.encode(:command_delivery, %{
                 delivery
                 | payload_hash: :binary.copy(<<0xCC>>, 32)
               })

      assert {:error, :command_hash_mismatch} =
               Messages.encode(:command_delivery, %{
                 delivery
                 | command_hash: :binary.copy(<<0xDD>>, 32)
               })

      assert {:ok, bytes} = Messages.encode(:command_delivery, delivery)
      last = byte_size(bytes) - 1
      <<prefix::binary-size(last), byte>> = bytes
      payload_tampered = prefix <> <<Bitwise.bxor(byte, 1)>>

      assert {:error, :payload_hash_mismatch} =
               Messages.decode(:command_delivery, payload_tampered)

      command_hash_tampered =
        encode_delivery_bytes(%{
          delivery
          | command_hash: :binary.copy(<<0xDD>>, 32)
        })

      assert {:error, :command_hash_mismatch} =
               Messages.decode(:command_delivery, command_hash_tampered)
    end
  end

  describe "command acknowledgements" do
    test "round-trips each status and enforces status/reason consistency" do
      for ack <- [
            ack_attrs(:applied, :none),
            ack_attrs(:duplicate, :none),
            ack_attrs(:rejected, :invalid_payload)
          ] do
        assert {:ok, bytes} = Messages.encode(:command_ack, ack)
        assert {:ok, ^ack} = Messages.decode(:command_ack, bytes)
      end

      assert {:error, :invalid_command_status_reason} =
               Messages.encode(:command_ack, ack_attrs(:applied, :expired))

      assert {:error, :invalid_command_status_reason} =
               Messages.encode(:command_ack, ack_attrs(:duplicate, :sequence_replay))

      assert {:error, :invalid_command_status_reason} =
               Messages.encode(:command_ack, ack_attrs(:rejected, :none))
    end

    test "binds the command hash and exact result-hash preimage in exact wire bytes" do
      ack = ack_attrs(:rejected, :operational_gate_closed)
      status_code = 0x03
      reason_code = 0x0B

      expected_result_hash =
        :crypto.hash(
          :sha256,
          Contract.command_result_hash_domain() <>
            <<Contract.version(), status_code, reason_code, byte_size(@result)::32, @result::binary>>
        )

      assert ack.result_hash == expected_result_hash

      assert {:ok, ack.result_hash} ==
               Command.result_hash(%{status: :rejected, reason: :operational_gate_closed, result: @result})

      assert {:ok, bytes} = Messages.encode(:command_ack, ack)
      assert {:ok, ^ack} = Messages.decode(:command_ack, bytes)

      assert bytes ==
               Contract.payload_domain(:command_ack) <>
                 <<Contract.version(), 0x21, @device_id::binary, 7::32, @storage_epoch::binary, 42::64,
                   @manifest_hash::binary, 9::32, 11::64, @command_id::binary, ack.command_hash::binary, status_code,
                   reason_code, expected_result_hash::binary, byte_size(@result)::32, @result::binary>>
    end

    test "normalizes UUIDs while requiring atom registry names from encoders" do
      raw = ack_attrs(:applied, :none)
      textual = %{raw | device_id: @device_uuid, command_id: @command_uuid}

      assert {:ok, raw_bytes} = Messages.encode(:command_ack, raw)
      assert {:ok, ^raw_bytes} = Messages.encode(:command_ack, textual)
      assert {:ok, ^raw} = Messages.decode(:command_ack, raw_bytes)

      assert {:error, :unknown_command_status} =
               Messages.encode(:command_ack, %{raw | status: 0x01})

      assert {:error, :unknown_command_reason} =
               Messages.encode(:command_ack, %{raw | reason: 0x00})

      assert {:error, :unknown_command_status} =
               Command.result_hash(%{status: 0x01, reason: :none, result: @result})

      assert {:error, :unknown_command_reason} =
               Command.result_hash(%{status: :applied, reason: 0x00, result: @result})
    end

    test "requires exact keys, signed bounds, fixed lengths, and binary results" do
      ack = ack_attrs(:applied, :none)

      assert {:error, :invalid_command_ack} =
               Messages.encode(:command_ack, Map.delete(ack, :result))

      assert {:error, :invalid_command_ack} =
               Messages.encode(:command_ack, Map.put(ack, :arbitrary, true))

      for {field, value, error} <- [
            {:credential_epoch, -1, :invalid_credential_epoch},
            {:required_generation, 0, :invalid_required_generation},
            {:required_generation, @database_int_max + 1, :invalid_required_generation},
            {:command_epoch, -1, :invalid_command_epoch},
            {:command_sequence, 0, :invalid_command_sequence},
            {:command_sequence, @database_int_max + 1, :invalid_command_sequence},
            {:storage_epoch, <<0::128>>, :invalid_storage_epoch},
            {:required_manifest_hash, <<0>>, :invalid_required_manifest_hash},
            {:command_hash, <<0>>, :invalid_command_hash},
            {:result_hash, <<0>>, :invalid_result_hash},
            {:result, :not_binary, :invalid_command_result}
          ] do
        assert {:error, ^error} = Messages.encode(:command_ack, Map.put(ack, field, value))
      end
    end

    test "enforces the exact maximum result against the control plaintext ceiling" do
      result = :binary.copy(<<0x5A>>, Contract.max_command_result_size())
      ack = ack_attrs(:applied, :none, result)

      assert {:ok, bytes} = Messages.encode(:command_ack, ack)
      assert byte_size(bytes) == Contract.max_plaintext_size()
      assert {:ok, ^ack} = Messages.decode(:command_ack, bytes)

      oversized = :binary.copy(<<0x5A>>, Contract.max_command_result_size() + 1)
      oversized_ack = ack_attrs(:applied, :none, oversized)

      assert {:error, :command_result_too_large} =
               Messages.encode(:command_ack, oversized_ack)

      assert {:error, :command_result_too_large} =
               Command.result_hash(%{status: :applied, reason: :none, result: oversized})
    end

    test "rejects unknown decoded codes, inconsistent pairs, and result-hash tampering" do
      ack = ack_attrs(:applied, :none)

      unknown_status = encode_ack_bytes(ack, 0xFF, 0x00, raw_result_hash(0xFF, 0x00, ack.result))
      assert {:error, :unknown_command_status} = Messages.decode(:command_ack, unknown_status)

      unknown_reason = encode_ack_bytes(ack, 0x01, 0xFF, raw_result_hash(0x01, 0xFF, ack.result))
      assert {:error, :unknown_command_reason} = Messages.decode(:command_ack, unknown_reason)

      inconsistent =
        encode_ack_bytes(ack, 0x01, 0x05, raw_result_hash(0x01, 0x05, ack.result))

      assert {:error, :invalid_command_status_reason} =
               Messages.decode(:command_ack, inconsistent)

      bad_hash = encode_ack_bytes(ack, 0x01, 0x00, :binary.copy(<<0xEE>>, 32))
      assert {:error, :result_hash_mismatch} = Messages.decode(:command_ack, bad_hash)

      assert {:ok, bytes} = Messages.encode(:command_ack, ack)
      last = byte_size(bytes) - 1
      <<prefix::binary-size(last), byte>> = bytes
      result_tampered = prefix <> <<Bitwise.bxor(byte, 1)>>
      assert {:error, :result_hash_mismatch} = Messages.decode(:command_ack, result_tampered)
    end
  end

  test "rejects wrong domains, versions, types, truncation, trailing bytes, and non-binaries" do
    delivery = delivery_attrs()
    ack = ack_attrs(:applied, :none)
    assert {:ok, delivery_bytes} = Messages.encode(:command_delivery, delivery)
    assert {:ok, ack_bytes} = Messages.encode(:command_ack, ack)

    assert {:error, :payload_domain_mismatch} =
             Messages.decode(:command_ack, delivery_bytes)

    assert {:error, :payload_domain_mismatch} =
             Messages.decode(:command_delivery, ack_bytes)

    assert {:error, :unsupported_payload_version} =
             Messages.decode(
               :command_delivery,
               replace_version(delivery_bytes, :command_delivery, 2)
             )

    assert {:error, :payload_type_mismatch} =
             Messages.decode(
               :command_delivery,
               replace_type(delivery_bytes, :command_delivery, 0x21)
             )

    assert {:error, :truncated} =
             Messages.decode(
               :command_delivery,
               binary_part(delivery_bytes, 0, byte_size(delivery_bytes) - 1)
             )

    assert {:error, :trailing_bytes} =
             Messages.decode(:command_ack, ack_bytes <> <<0>>)

    assert {:error, :invalid_payload} = Messages.decode(:command_ack, :not_binary)
    assert {:error, :invalid_payload} = Messages.encode(:command_delivery, :not_a_map)
  end

  defp delivery_attrs(payload \\ @payload) do
    payload_hash = :crypto.hash(:sha256, payload)

    attrs = %{
      device_id: @device_id,
      credential_epoch: 7,
      storage_epoch: @storage_epoch,
      required_generation: 42,
      required_manifest_hash: @manifest_hash,
      command_epoch: 9,
      command_sequence: 11,
      command_id: @command_id,
      expires_at_ms: 1_800_000_000_000,
      payload_hash: payload_hash
    }

    attrs
    |> Map.put(:command_hash, raw_command_hash(attrs))
    |> Map.put(:payload, payload)
  end

  defp ack_attrs(status, reason, result \\ @result) do
    delivery = delivery_attrs()
    {:ok, status_code} = Contract.command_status(status)
    {:ok, reason_code} = Contract.command_reason(reason)

    %{
      device_id: delivery.device_id,
      credential_epoch: delivery.credential_epoch,
      storage_epoch: delivery.storage_epoch,
      required_generation: delivery.required_generation,
      required_manifest_hash: delivery.required_manifest_hash,
      command_epoch: delivery.command_epoch,
      command_sequence: delivery.command_sequence,
      command_id: delivery.command_id,
      command_hash: delivery.command_hash,
      status: status,
      reason: reason,
      result_hash: raw_result_hash(status_code, reason_code, result),
      result: result
    }
  end

  defp raw_command_hash(attrs) do
    :crypto.hash(
      :sha256,
      Contract.command_record_hash_domain() <>
        <<Contract.version(), 0x20, normalize_uuid!(attrs.device_id)::binary-size(16), attrs.credential_epoch::32,
          attrs.storage_epoch::binary-size(16), attrs.required_generation::64,
          attrs.required_manifest_hash::binary-size(32), attrs.command_epoch::32, attrs.command_sequence::64,
          normalize_uuid!(attrs.command_id)::binary-size(16), attrs.expires_at_ms::64,
          attrs.payload_hash::binary-size(32)>>
    )
  end

  defp raw_result_hash(status_code, reason_code, result) do
    :crypto.hash(
      :sha256,
      Contract.command_result_hash_domain() <>
        <<Contract.version(), status_code, reason_code, byte_size(result)::32, result::binary>>
    )
  end

  defp encode_delivery_bytes(attrs) do
    Contract.payload_domain(:command_delivery) <>
      <<Contract.version(), 0x20, normalize_uuid!(attrs.device_id)::binary-size(16), attrs.credential_epoch::32,
        attrs.storage_epoch::binary-size(16), attrs.required_generation::64,
        attrs.required_manifest_hash::binary-size(32), attrs.command_epoch::32, attrs.command_sequence::64,
        normalize_uuid!(attrs.command_id)::binary-size(16), attrs.expires_at_ms::64,
        attrs.payload_hash::binary-size(32), attrs.command_hash::binary-size(32), byte_size(attrs.payload)::32,
        attrs.payload::binary>>
  end

  defp encode_ack_bytes(attrs, status_code, reason_code, result_hash) do
    Contract.payload_domain(:command_ack) <>
      <<Contract.version(), 0x21, normalize_uuid!(attrs.device_id)::binary-size(16), attrs.credential_epoch::32,
        attrs.storage_epoch::binary-size(16), attrs.required_generation::64,
        attrs.required_manifest_hash::binary-size(32), attrs.command_epoch::32, attrs.command_sequence::64,
        normalize_uuid!(attrs.command_id)::binary-size(16), attrs.command_hash::binary-size(32), status_code,
        reason_code, result_hash::binary-size(32), byte_size(attrs.result)::32, attrs.result::binary>>
  end

  defp normalize_uuid!(<<uuid::binary-size(16)>>), do: uuid

  defp normalize_uuid!(uuid) do
    uuid
    |> String.replace("-", "")
    |> Base.decode16!(case: :mixed)
  end

  defp replace_version(bytes, type, version) do
    domain = Contract.payload_domain(type)
    <<^domain::binary, _old_version, rest::binary>> = bytes
    domain <> <<version>> <> rest
  end

  defp replace_type(bytes, type, code) do
    domain = Contract.payload_domain(type)
    <<^domain::binary, version, _old_code, rest::binary>> = bytes
    domain <> <<version, code>> <> rest
  end
end
