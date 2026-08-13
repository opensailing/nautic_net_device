defmodule RacingOrg.Tracker.Pro.SecureTransport.DeliveryPayloadV1ContractTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Messages

  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @database_int_max 9_223_372_036_854_775_807
  @chunk_size 61_440
  @max_payload_content_size 16_777_216
  @max_payload_chunks 274
  @generic_streams [
    :telemetry,
    :race_recording_chunk,
    :race_recording_manifest,
    :desired_state_ack,
    :health
  ]

  @delivery_payload_keys [
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :stream,
    :sequence,
    :payload_hash,
    :payload
  ]
  @delivery_payload_chunk_keys [
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :stream,
    :sequence,
    :payload_hash,
    :total_payload_length,
    :chunk_index,
    :chunk_count,
    :chunk_offset,
    :chunk_hash,
    :chunk
  ]

  @complete_payload <<0x00, 0xFF, "opaque", 0x80>>
  @complete_payload_hash Base.decode16!(
                           "061985550b713dbb67f807b7c399330d26d363c688f48e8b901eda50fa0904de",
                           case: :lower
                         )
  @complete_kat_hex "526163696e674f72672d44757261626c6544656c69766572795061796c6f61642d7631" <>
                      "013800112233445566778899aabbccddeeff00000007ffeeddccbbaa99887766554433221100" <>
                      "06000000000000000b061985550b713dbb67f807b7c399330d26d363c688f48e8b901eda50" <>
                      "fa0904de0000000900ff6f706171756580"

  @chunk_bytes <<0x00, 0xFF, 0x10, 0x20, 0x80>>
  @chunk_payload_hash Base.decode16!(
                        "e97bfcd959f902cd457964d618944c5599d49aa32a2381254f5b817bca5664e1",
                        case: :lower
                      )
  @chunk_hash Base.decode16!(
                "8018b448b8e1e5bacede5e3ea54543481b38ee7b967e972769a53eb567f64b95",
                case: :lower
              )
  @chunk_kat_hex "526163696e674f72672d44757261626c6544656c69766572795061796c6f61644368756e6b2d" <>
                   "7631013900112233445566778899aabbccddeeff00000007ffeeddccbbaa998877665544332211" <>
                   "0002000000000000000be97bfcd959f902cd457964d618944c5599d49aa32a2381254f5b817b" <>
                   "ca5664e1000000000000f0050000000100000002000000000000f0008018b448b8e1e5bacede" <>
                   "5e3ea54543481b38ee7b967e972769a53eb567f64b950000000500ff102080"

  describe "frozen payload-carriage registry" do
    test "freezes assignments, domains, directions, and derived capacities" do
      assert Contract.message_type(:delivery_payload) == {:ok, 0x38, :device_to_server}
      assert Contract.message_type(0x38) == {:ok, :delivery_payload, :device_to_server}

      assert Contract.message_type(:delivery_payload_chunk) ==
               {:ok, 0x39, :device_to_server}

      assert Contract.message_type(0x39) ==
               {:ok, :delivery_payload_chunk, :device_to_server}

      assert Contract.payload_domain(:delivery_payload) ==
               "RacingOrg-DurableDeliveryPayload-v1"

      assert Contract.payload_domain(:delivery_payload_chunk) ==
               "RacingOrg-DurableDeliveryPayloadChunk-v1"

      assert Contract.delivery_payload_chunk_hash_domain() ==
               "RacingOrg-DurableDeliveryPayloadChunkHash-v1"

      complete_fixed_body_size = 16 + 4 + 16 + 1 + 8 + 32 + 4

      assert Contract.max_delivery_payload_size() ==
               Contract.max_plaintext_size() -
                 byte_size(Contract.payload_domain(:delivery_payload)) - 2 -
                 complete_fixed_body_size

      assert Contract.max_delivery_payload_size() == 65_418
      assert Contract.max_delivery_payload_content_size() == @max_payload_content_size
      assert Contract.max_delivery_payload_chunks() == @max_payload_chunks
      assert Contract.max_delivery_payload_chunks() == div(@max_payload_content_size + @chunk_size - 1, @chunk_size)
    end
  end

  describe "complete payload carriage" do
    test "matches the complete-message known-answer bytes and round-trips opaque bytes" do
      attrs = complete_attrs(:health, @complete_payload)
      assert attrs.payload_hash == @complete_payload_hash
      assert Map.keys(attrs) |> Enum.sort() == Enum.sort(@delivery_payload_keys)

      expected = Base.decode16!(@complete_kat_hex, case: :lower)
      assert {:ok, ^expected} = Messages.encode(:delivery_payload, attrs)
      assert {:ok, ^attrs} = Messages.decode(:delivery_payload, expected)
    end

    test "round-trips every closed non-checkpoint stream without interpreting payload bytes" do
      payload = <<0xFF, 0x00, 0x80, 0x01>>

      for stream <- @generic_streams do
        attrs = complete_attrs(stream, payload)
        assert {:ok, bytes} = Messages.encode(:delivery_payload, attrs)
        assert {:ok, ^attrs} = Messages.decode(:delivery_payload, bytes)
      end
    end

    test "derives the exact complete payload ceiling from the plaintext frame" do
      payload = :binary.copy(<<0xA5>>, Contract.max_delivery_payload_size())
      attrs = complete_attrs(:telemetry, payload)

      assert {:ok, bytes} = Messages.encode(:delivery_payload, attrs)
      assert byte_size(bytes) == Contract.max_plaintext_size()

      oversized = payload <> <<0xA5>>

      assert {:error, :payload_too_large} =
               Messages.encode(:delivery_payload, complete_attrs(:telemetry, oversized))
    end

    test "requires actual payload bytes to match the bound SHA-256" do
      attrs = complete_attrs(:health, "payload")

      assert {:error, :payload_hash_mismatch} =
               Messages.encode(:delivery_payload, %{attrs | payload_hash: <<0::256>>})
    end
  end

  describe "chunk payload carriage" do
    test "matches the payload chunk-hash and chunk-message known-answer vectors" do
      full_payload = :binary.copy(<<0xA5>>, @chunk_size) <> @chunk_bytes
      assert :crypto.hash(:sha256, full_payload) == @chunk_payload_hash

      attrs = %{
        device_id: @device_id,
        credential_epoch: 7,
        storage_epoch: @storage_epoch,
        stream: :race_recording_chunk,
        sequence: 11,
        payload_hash: @chunk_payload_hash,
        total_payload_length: 61_445,
        chunk_index: 1,
        chunk_count: 2,
        chunk_offset: @chunk_size,
        chunk_hash: @chunk_hash,
        chunk: @chunk_bytes
      }

      hash_attrs = Map.take(attrs, payload_chunk_hash_keys())
      assert {:ok, @chunk_hash} = Messages.delivery_payload_chunk_hash(hash_attrs)

      expected = Base.decode16!(@chunk_kat_hex, case: :lower)
      assert {:ok, ^expected} = Messages.encode(:delivery_payload_chunk, attrs)
      assert {:ok, ^attrs} = Messages.decode(:delivery_payload_chunk, expected)
    end

    test "accepts exact first, middle, and final chunk geometry" do
      first = chunk_attrs(@max_payload_content_size, 0)
      middle = chunk_attrs(3 * @chunk_size + 4_096, 1)
      final = chunk_attrs(@max_payload_content_size, 273)

      assert first.chunk_offset == 0
      assert first.chunk_count == @max_payload_chunks
      assert byte_size(first.chunk) == @chunk_size

      assert middle.chunk_offset == @chunk_size
      assert middle.chunk_count == 4
      assert byte_size(middle.chunk) == @chunk_size

      assert final.chunk_index == 273
      assert final.chunk_count == @max_payload_chunks
      assert final.chunk_offset == 16_773_120
      assert byte_size(final.chunk) == 4_096

      assert {:ok, first_bytes} = Messages.encode(:delivery_payload_chunk, first)
      assert byte_size(first_bytes) == 61_619
      assert byte_size(first_bytes) < Contract.max_plaintext_size()

      for attrs <- [first, middle, final] do
        assert {:ok, bytes} = Messages.encode(:delivery_payload_chunk, attrs)
        assert {:ok, ^attrs} = Messages.decode(:delivery_payload_chunk, bytes)
      end
    end

    test "keeps helper and codec chunk-byte errors in lockstep" do
      valid = chunk_attrs(@chunk_size + 1, 0)
      hash_attrs = Map.take(valid, payload_chunk_hash_keys())

      for {chunk, reason} <- [
            {:not_binary, :invalid_chunk},
            {<<>>, :invalid_chunk_length},
            {:binary.copy(<<0>>, @chunk_size + 1), :invalid_chunk_length}
          ] do
        assert {:error, ^reason} =
                 hash_attrs
                 |> Map.put(:chunk, chunk)
                 |> Messages.delivery_payload_chunk_hash()

        assert {:error, ^reason} =
                 valid
                 |> Map.put(:chunk, chunk)
                 |> then(&Messages.encode(:delivery_payload_chunk, &1))
      end
    end

    test "enforces the 16 MiB and 274-chunk boundaries" do
      assert {:ok, _bytes} =
               Messages.encode(:delivery_payload_chunk, chunk_attrs(@max_payload_content_size, 273))

      assert {:error, :payload_too_large} =
               Messages.encode(
                 :delivery_payload_chunk,
                 chunk_attrs_unchecked(@max_payload_content_size + 1, 273)
               )

      attrs = chunk_attrs(@max_payload_content_size, 273)

      assert {:error, :invalid_chunk_count} =
               Messages.encode(:delivery_payload_chunk, %{attrs | chunk_count: 275})
    end
  end

  describe "strict malformed payload rejection" do
    test "rejects invalid stream, durable identity, sequence, and hashes for both forms" do
      complete = complete_attrs(:telemetry, "payload")
      chunk = chunk_attrs(1, 0)

      for {type, attrs} <- [{:delivery_payload, complete}, {:delivery_payload_chunk, chunk}] do
        assert {:error, :checkpoint_requires_specialized_submission} =
                 Messages.encode(type, %{attrs | stream: :checkpoint})

        assert {:error, :unknown_delivery_stream} =
                 Messages.encode(type, %{attrs | stream: :arbitrary})

        assert {:error, :unknown_delivery_stream} = Messages.encode(type, %{attrs | stream: 0x01})
        assert {:error, :invalid_device_id} = Messages.encode(type, %{attrs | device_id: <<0::128>>})
        assert {:error, :invalid_device_id} = Messages.encode(type, %{attrs | device_id: <<0>>})

        assert {:error, :invalid_credential_epoch} =
                 Messages.encode(type, %{attrs | credential_epoch: -1})

        assert {:error, :invalid_storage_epoch} =
                 Messages.encode(type, %{attrs | storage_epoch: <<0::128>>})

        assert {:error, :invalid_delivery_sequence} = Messages.encode(type, %{attrs | sequence: 0})

        assert {:error, :invalid_delivery_sequence} =
                 Messages.encode(type, %{attrs | sequence: @database_int_max + 1})

        assert {:error, :invalid_payload_hash} =
                 Messages.encode(type, %{attrs | payload_hash: <<0>>})
      end

      assert {:error, :invalid_payload_chunk_hash} =
               Messages.encode(:delivery_payload_chunk, %{chunk | chunk_hash: <<0>>})

      assert {:error, :payload_chunk_hash_mismatch} =
               Messages.encode(:delivery_payload_chunk, %{chunk | chunk_hash: <<0::256>>})
    end

    test "rejects invalid complete lengths and chunk total/count/index/offset/length" do
      complete = complete_attrs(:telemetry, "payload")
      assert {:error, :invalid_payload} = Messages.encode(:delivery_payload, %{complete | payload: :not_binary})

      chunk = chunk_attrs(@chunk_size + 1, 1)

      assert {:error, :invalid_total_payload_length} =
               Messages.encode(:delivery_payload_chunk, %{chunk | total_payload_length: 0})

      assert {:error, :invalid_chunk_count} =
               Messages.encode(:delivery_payload_chunk, %{chunk | chunk_count: 1})

      assert {:error, :invalid_chunk_index} =
               Messages.encode(:delivery_payload_chunk, %{chunk | chunk_index: 2})

      assert {:error, :invalid_chunk_offset} =
               Messages.encode(:delivery_payload_chunk, %{chunk | chunk_offset: @chunk_size - 1})

      assert {:error, :invalid_chunk_length} =
               Messages.encode(:delivery_payload_chunk, %{chunk | chunk: <<0, 1>>})
    end

    test "rejects malformed derived wire lengths and trailing bytes" do
      complete = complete_attrs(:health, @complete_payload)
      assert {:ok, complete_bytes} = Messages.encode(:delivery_payload, complete)
      complete_domain = Contract.payload_domain(:delivery_payload)
      complete_domain_size = byte_size(complete_domain)

      <<^complete_domain::binary-size(complete_domain_size), version, code, common::binary-size(77), payload_length::32,
        payload::binary>> = complete_bytes

      assert {:error, :truncated} =
               Messages.decode(
                 :delivery_payload,
                 complete_domain <>
                   <<version, code>> <>
                   common <> <<payload_length + 1::32>> <> payload
               )

      <<common_prefix::binary-size(45), _payload_hash::binary-size(32)>> = common
      shorter_length = payload_length - 1
      <<shorter_payload::binary-size(shorter_length), _trailing>> = payload
      shorter_hash = :crypto.hash(:sha256, shorter_payload)

      assert {:error, :trailing_bytes} =
               Messages.decode(
                 :delivery_payload,
                 complete_domain <>
                   <<version, code>> <>
                   common_prefix <>
                   shorter_hash <>
                   <<shorter_length::32>> <>
                   payload
               )

      chunk = chunk_attrs(@chunk_size + 1, 1)
      assert {:ok, chunk_bytes} = Messages.encode(:delivery_payload_chunk, chunk)
      chunk_domain = Contract.payload_domain(:delivery_payload_chunk)
      chunk_domain_size = byte_size(chunk_domain)

      <<^chunk_domain::binary-size(chunk_domain_size), chunk_version, chunk_code, chunk_common::binary-size(133),
        chunk_length::32, encoded_chunk::binary>> = chunk_bytes

      assert {:error, :truncated} =
               Messages.decode(
                 :delivery_payload_chunk,
                 chunk_domain <>
                   <<chunk_version, chunk_code>> <>
                   chunk_common <> <<chunk_length + 1::32>> <> encoded_chunk
               )

      assert {:error, :trailing_bytes} = Messages.decode(:delivery_payload, complete_bytes <> <<0>>)
      assert {:error, :trailing_bytes} = Messages.decode(:delivery_payload_chunk, chunk_bytes <> <<0>>)
    end

    test "accepts exact atom keys only and has no secret-shaped metadata fields" do
      complete = complete_attrs(:telemetry, "payload")
      chunk = chunk_attrs(1, 0)
      forbidden = [:boot_id, :metadata, :auth, :authorization, :token, :secret, :password, :psk]

      assert Map.keys(complete) |> Enum.sort() == Enum.sort(@delivery_payload_keys)
      assert Map.keys(chunk) |> Enum.sort() == Enum.sort(@delivery_payload_chunk_keys)
      assert Enum.all?(forbidden, &(&1 not in Map.keys(complete)))
      assert Enum.all?(forbidden, &(&1 not in Map.keys(chunk)))

      assert {:error, :invalid_delivery_payload} =
               complete
               |> Map.put(:metadata, %{})
               |> then(&Messages.encode(:delivery_payload, &1))

      assert {:error, :invalid_delivery_payload_chunk} =
               chunk
               |> Map.put(:token, "opaque-but-forbidden-metadata")
               |> then(&Messages.encode(:delivery_payload_chunk, &1))
    end
  end

  defp complete_attrs(stream, payload) do
    %{
      device_id: @device_id,
      credential_epoch: 7,
      storage_epoch: @storage_epoch,
      stream: stream,
      sequence: 11,
      payload_hash: if(is_binary(payload), do: :crypto.hash(:sha256, payload), else: <<0::256>>),
      payload: payload
    }
  end

  defp chunk_attrs(total, index) do
    total
    |> chunk_attrs_unchecked(index)
    |> with_chunk_hash()
  end

  defp chunk_attrs_unchecked(total, index) do
    offset = index * @chunk_size
    length = max(min(@chunk_size, total - offset), 1)

    %{
      device_id: @device_id,
      credential_epoch: 7,
      storage_epoch: @storage_epoch,
      stream: :race_recording_chunk,
      sequence: 11,
      payload_hash: :crypto.hash(:sha256, <<total::64>>),
      total_payload_length: total,
      chunk_index: index,
      chunk_count: div(total + @chunk_size - 1, @chunk_size),
      chunk_offset: offset,
      chunk_hash: <<0::256>>,
      chunk: :binary.copy(<<rem(index + total, 256)>>, length)
    }
    |> with_chunk_hash()
  end

  defp with_chunk_hash(attrs) do
    {:ok, hash} =
      attrs
      |> Map.take(payload_chunk_hash_keys())
      |> Messages.delivery_payload_chunk_hash()

    Map.put(attrs, :chunk_hash, hash)
  end

  defp payload_chunk_hash_keys do
    [
      :payload_hash,
      :total_payload_length,
      :chunk_index,
      :chunk_count,
      :chunk_offset,
      :chunk
    ]
  end
end
