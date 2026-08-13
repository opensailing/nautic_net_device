defmodule RacingOrg.Tracker.Pro.SecureTransport.DurableDeliveryV1ContractTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{
    Canonical,
    Checkpoint,
    Messages,
    Receipt
  }

  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @replacement_storage_epoch Base.decode16!("102132435465768798a9bacbdcedfe0f", case: :lower)
  @payload_hash :binary.copy(<<0xA1>>, 32)
  @parent_hash :binary.copy(<<0xB2>>, 32)
  @database_int_max 9_223_372_036_854_775_807
  @polar_schema 2
  @delivery_submission_keys [
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :stream,
    :sequence,
    :payload_hash
  ]
  @generic_delivery_streams [
    :telemetry,
    :race_recording_chunk,
    :race_recording_manifest,
    :desired_state_ack,
    :health
  ]

  describe "closed durable-delivery registries" do
    test "freezes message codes, directions, streams, and checkpoint schemas" do
      assert Contract.message_type(:delivery_receipt) ==
               {:ok, 0x30, :server_to_device}

      assert Contract.message_type(:checkpoint_submission) ==
               {:ok, 0x31, :device_to_server}

      assert Contract.message_type(:checkpoint_hydration) ==
               {:ok, 0x32, :server_to_device}

      assert Contract.message_type(:delivery_submission) ==
               {:ok, 0x33, :device_to_server}

      assert Contract.message_type(0x33) ==
               {:ok, :delivery_submission, :device_to_server}

      assert Contract.payload_domain(:delivery_receipt) ==
               "RacingOrg-DurableDeliveryReceipt-v1"

      assert Contract.payload_domain(:checkpoint_submission) ==
               "RacingOrg-CheckpointSubmission-v1"

      assert Contract.payload_domain(:checkpoint_hydration) ==
               "RacingOrg-CheckpointHydration-v1"

      assert Contract.payload_domain(:delivery_submission) ==
               "RacingOrg-DurableDeliverySubmission-v1"

      assert Contract.delivery_receipt_hash_domain() ==
               "RacingOrg-DurableDeliveryReceiptHash-v1"

      assert Contract.checkpoint_content_hash_domain() ==
               "RacingOrg-CheckpointContentHash-v1"

      assert Contract.checkpoint_hash_domain() ==
               "RacingOrg-CheckpointRecordHash-v1"

      assert Contract.max_checkpoint_size() == 65_327

      assert Contract.delivery_streams() == [
               {:telemetry, 0x01},
               {:race_recording_chunk, 0x02},
               {:race_recording_manifest, 0x03},
               {:desired_state_ack, 0x04},
               {:checkpoint, 0x05},
               {:health, 0x06}
             ]

      for {stream, code} <- Contract.delivery_streams() do
        assert Contract.delivery_stream(stream) == {:ok, code}
        assert Contract.delivery_stream(code) == {:ok, stream}
      end

      # Polar is at schema 2: its v1 content carried a bare cell index with no
      # bin geometry to interpret it under. The kind CODE is unchanged, so the
      # bump is visible only in the schema_version u16 that every checkpoint
      # hash preimage binds.
      assert Contract.checkpoint_kinds() == [
               {:calibration, 0x01, 0x0001},
               {:polar, 0x02, 0x0002},
               {:wind_shift, 0x03, 0x0001}
             ]

      for {kind, code, schema_version} <- Contract.checkpoint_kinds() do
        assert Contract.checkpoint_kind(kind) == {:ok, code, schema_version}
        assert Contract.checkpoint_kind(code) == {:ok, kind, schema_version}
      end

      assert {:error, :unknown_delivery_stream} = Contract.delivery_stream(:arbitrary)
      assert {:error, :unknown_checkpoint_kind} = Contract.checkpoint_kind(:arbitrary)
    end
  end

  describe "generic durable-delivery submissions" do
    test "round-trips every registered generic stream with byte-for-byte golden vectors" do
      for stream <- @generic_delivery_streams do
        submission = delivery_submission_attrs(stream)
        assert Map.keys(submission) |> Enum.sort() == Enum.sort(@delivery_submission_keys)
        assert {:ok, stream_code} = Contract.delivery_stream(stream)
        assert {:ok, bytes} = Messages.encode(:delivery_submission, submission)
        assert {:ok, ^submission} = Messages.decode(:delivery_submission, bytes)

        assert bytes ==
                 "RacingOrg-DurableDeliverySubmission-v1" <>
                   <<0x01, 0x33, @device_id::binary, 7::unsigned-32, @storage_epoch::binary, stream_code::unsigned-8,
                     11::unsigned-64, @payload_hash::binary>>
      end
    end

    test "requires exact closed atom keys and valid durable identity fields" do
      submission = delivery_submission_attrs(:telemetry)

      assert {:error, :invalid_delivery_submission} =
               submission
               |> Map.put(:metadata, %{})
               |> then(&Messages.encode(:delivery_submission, &1))

      assert {:error, :invalid_delivery_submission} =
               submission
               |> Map.delete(:payload_hash)
               |> then(&Messages.encode(:delivery_submission, &1))

      assert {:error, :invalid_delivery_submission} =
               submission
               |> Map.delete(:stream)
               |> Map.put("stream", :telemetry)
               |> then(&Messages.encode(:delivery_submission, &1))

      assert {:error, :invalid_device_id} =
               Messages.encode(:delivery_submission, %{submission | device_id: <<0::128>>})

      assert {:error, :invalid_device_id} =
               Messages.encode(:delivery_submission, %{submission | device_id: <<0>>})

      for credential_epoch <- [0, 0xFFFF_FFFF] do
        assert {:ok, _bytes} =
                 Messages.encode(:delivery_submission, %{
                   submission
                   | credential_epoch: credential_epoch
                 })
      end

      assert {:error, :invalid_credential_epoch} =
               Messages.encode(:delivery_submission, %{submission | credential_epoch: -1})

      assert {:error, :invalid_credential_epoch} =
               Messages.encode(:delivery_submission, %{
                 submission
                 | credential_epoch: 0x1_0000_0000
               })

      assert {:error, :invalid_storage_epoch} =
               Messages.encode(:delivery_submission, %{submission | storage_epoch: <<0::128>>})

      assert {:error, :invalid_storage_epoch} =
               Messages.encode(:delivery_submission, %{submission | storage_epoch: <<0>>})
    end

    test "rejects checkpoint specialization, open stream values, sequence bounds, and malformed hashes" do
      submission = delivery_submission_attrs(:telemetry)

      assert {:error, :checkpoint_requires_specialized_submission} =
               Messages.encode(:delivery_submission, %{submission | stream: :checkpoint})

      assert {:error, :unknown_delivery_stream} =
               Messages.encode(:delivery_submission, %{submission | stream: :arbitrary})

      assert {:error, :unknown_delivery_stream} =
               Messages.encode(:delivery_submission, %{submission | stream: 0x01})

      assert {:error, :invalid_delivery_sequence} =
               Messages.encode(:delivery_submission, %{submission | sequence: 0})

      assert {:error, :invalid_delivery_sequence} =
               Messages.encode(:delivery_submission, %{submission | sequence: -1})

      assert {:ok, _bytes} =
               Messages.encode(:delivery_submission, %{
                 submission
                 | sequence: @database_int_max
               })

      assert {:error, :invalid_delivery_sequence} =
               Messages.encode(:delivery_submission, %{
                 submission
                 | sequence: @database_int_max + 1
               })

      assert {:error, :invalid_payload_hash} =
               Messages.encode(:delivery_submission, %{submission | payload_hash: <<0>>})
    end

    test "strictly rejects wrong domains, versions, types, truncation, trailing, unknown, and checkpoint streams" do
      submission = delivery_submission_attrs(:health)
      assert {:ok, bytes} = Messages.encode(:delivery_submission, submission)
      assert {:ok, receipt_bytes} = Messages.encode(:delivery_receipt, receipt_attrs())

      assert {:error, :payload_domain_mismatch} =
               Messages.decode(:delivery_submission, receipt_bytes)

      assert {:error, :unsupported_payload_version} =
               Messages.decode(
                 :delivery_submission,
                 replace_version(bytes, :delivery_submission, 0x02)
               )

      assert {:error, :payload_type_mismatch} =
               Messages.decode(
                 :delivery_submission,
                 replace_type(bytes, :delivery_submission, 0x31)
               )

      assert {:error, :truncated} =
               Messages.decode(:delivery_submission, binary_part(bytes, 0, byte_size(bytes) - 1))

      assert {:error, :trailing_bytes} =
               Messages.decode(:delivery_submission, bytes <> <<0>>)

      body_offset = byte_size("RacingOrg-DurableDeliverySubmission-v1") + 2
      storage_epoch_offset = body_offset + 16 + 4
      stream_offset = storage_epoch_offset + 16
      sequence_offset = stream_offset + 1

      assert {:error, :invalid_device_id} =
               Messages.decode(:delivery_submission, replace_bytes(bytes, body_offset, <<0::128>>))

      assert {:error, :invalid_storage_epoch} =
               Messages.decode(
                 :delivery_submission,
                 replace_bytes(bytes, storage_epoch_offset, <<0::128>>)
               )

      assert {:error, :unknown_delivery_stream} =
               Messages.decode(:delivery_submission, replace_byte(bytes, stream_offset, 0xFF))

      assert {:error, :checkpoint_requires_specialized_submission} =
               Messages.decode(:delivery_submission, replace_byte(bytes, stream_offset, 0x05))

      assert {:error, :invalid_delivery_sequence} =
               Messages.decode(:delivery_submission, replace_bytes(bytes, sequence_offset, <<0::64>>))
    end
  end

  describe "delivery receipts" do
    test "binds the exact durable identity without binding one transient boot" do
      receipt = receipt_attrs()

      assert Map.keys(receipt) |> Enum.sort() ==
               [
                 :credential_epoch,
                 :cumulative_sequence,
                 :device_id,
                 :payload_hash,
                 :receipt_hash,
                 :sequence,
                 :storage_epoch,
                 :stream
               ]
               |> Enum.sort()

      refute Map.has_key?(receipt, :boot_id)

      assert {:ok, bytes} = Messages.encode(:delivery_receipt, receipt)
      assert {:ok, ^receipt} = Messages.decode(:delivery_receipt, bytes)
      assert {:ok, receipt.receipt_hash} == Receipt.hash(Map.delete(receipt, :receipt_hash))

      expected_hash =
        :crypto.hash(
          :sha256,
          Contract.delivery_receipt_hash_domain() <>
            <<Contract.version(), @device_id::binary, 7::32, @storage_epoch::binary, 0x01, 7::64, @payload_hash::binary,
              4::64>>
        )

      assert receipt.receipt_hash == expected_hash

      assert bytes ==
               Contract.payload_domain(:delivery_receipt) <>
                 <<Contract.version(), 0x30, @device_id::binary, 7::32, @storage_epoch::binary, 0x01, 7::64,
                   @payload_hash::binary, 4::64, expected_hash::binary-size(32)>>
    end

    test "bounds durable receipt integers to signed database storage" do
      receipt = receipt_attrs()

      oversized_sequence =
        receipt
        |> Map.delete(:receipt_hash)
        |> Map.put(:sequence, @database_int_max + 1)

      assert {:error, :invalid_delivery_sequence} = Receipt.hash(oversized_sequence)

      assert {:error, :invalid_delivery_sequence} =
               Messages.encode(
                 :delivery_receipt,
                 Map.put(oversized_sequence, :receipt_hash, raw_receipt_hash(oversized_sequence))
               )

      oversized_cumulative =
        receipt
        |> Map.delete(:receipt_hash)
        |> Map.put(:cumulative_sequence, @database_int_max + 1)

      assert {:error, :invalid_cumulative_sequence} = Receipt.hash(oversized_cumulative)

      assert {:error, :invalid_cumulative_sequence} =
               Messages.encode(
                 :delivery_receipt,
                 Map.put(
                   oversized_cumulative,
                   :receipt_hash,
                   raw_receipt_hash(oversized_cumulative)
                 )
               )
    end

    test "rejects sequence zero, unknown streams, malformed hashes, and receipt tampering" do
      receipt = receipt_attrs()

      assert {:error, :invalid_delivery_sequence} =
               Messages.encode(:delivery_receipt, %{receipt | sequence: 0})

      assert {:error, :unknown_delivery_stream} =
               Messages.encode(:delivery_receipt, %{receipt | stream: :arbitrary})

      assert {:error, :unknown_delivery_stream} =
               Messages.encode(:delivery_receipt, %{receipt | stream: 0x01})

      assert {:error, :unknown_delivery_stream} =
               receipt
               |> Map.delete(:receipt_hash)
               |> Map.put(:stream, 0x01)
               |> Receipt.hash()

      assert {:error, :invalid_payload_hash} =
               Messages.encode(:delivery_receipt, %{receipt | payload_hash: <<0>>})

      assert {:error, :invalid_receipt_hash} =
               Messages.encode(:delivery_receipt, %{receipt | receipt_hash: <<0>>})

      assert {:error, :receipt_hash_mismatch} =
               Messages.encode(:delivery_receipt, %{
                 receipt
                 | receipt_hash: :binary.copy(<<0xFF>>, 32)
               })
    end
  end

  describe "checkpoint payloads" do
    test "round-trips every closed checkpoint content schema" do
      for {kind, content} <- [
            calibration: empty_calibration_checkpoint(),
            polar: polar_checkpoint(),
            wind_shift: empty_wind_shift_checkpoint()
          ] do
        # Each kind carries its OWN frozen schema version; the hash preimage binds
        # it, so a kind at schema 2 must not be encoded under a hardcoded 1.
        assert {:ok, kind_code, schema_version} = Contract.checkpoint_kind(kind)

        assert {:ok, bytes} = Checkpoint.encode_content(kind, schema_version, content)
        assert {:ok, ^content} = Checkpoint.decode_content(kind, schema_version, bytes)
        assert {:ok, hash} = Checkpoint.content_hash(kind, schema_version, bytes)

        assert hash ==
                 :crypto.hash(
                   :sha256,
                   Contract.checkpoint_content_hash_domain() <>
                     <<Contract.version(), kind_code, schema_version::16, byte_size(bytes)::64, bytes::binary>>
                 )

        # The retired schema is refused rather than silently reinterpreted.
        assert {:error, :unsupported_checkpoint_schema} =
                 Checkpoint.encode_content(kind, schema_version + 1, content)
      end
    end

    test "round-trips a submission and binds all record-level checkpoint fields" do
      submission = checkpoint_submission_attrs()

      refute Map.has_key?(submission, :boot_id)
      assert {:ok, bytes} = Messages.encode(:checkpoint_submission, submission)
      assert {:ok, ^submission} = Messages.decode(:checkpoint_submission, bytes)

      assert {:ok, submission.checkpoint_hash} ==
               Checkpoint.hash(Map.drop(submission, [:checkpoint_hash, :content]))

      expected_hash =
        :crypto.hash(
          :sha256,
          Contract.checkpoint_hash_domain() <>
            <<Contract.version(), @device_id::binary, 7::32, @storage_epoch::binary, 11::64, 0x02, @polar_schema::16,
              42::64, @parent_hash::binary, submission.content_hash::binary-size(32)>>
        )

      assert submission.checkpoint_hash == expected_hash

      assert bytes ==
               Contract.payload_domain(:checkpoint_submission) <>
                 <<Contract.version(), 0x31, @device_id::binary, 7::32, @storage_epoch::binary, 11::64, 0x02,
                   @polar_schema::16, 42::64, @parent_hash::binary, submission.content_hash::binary-size(32),
                   expected_hash::binary-size(32), byte_size(submission.content)::32, submission.content::binary>>
    end

    test "exposes the exact checkpoint record-hash preimage codec" do
      submission = checkpoint_submission_attrs()
      attrs = Map.drop(submission, [:checkpoint_hash, :content])

      assert {:ok, preimage} = Checkpoint.encode(attrs)

      expected =
        Contract.checkpoint_hash_domain() <>
          <<Contract.version(), @device_id::binary, 7::32, @storage_epoch::binary, 11::64, 0x02, @polar_schema::16,
            42::64, @parent_hash::binary, submission.content_hash::binary-size(32)>>

      assert byte_size(preimage) == 153
      assert preimage == expected
      assert {:ok, ^attrs} = Checkpoint.decode(preimage)

      assert {:ok, checkpoint_hash} = Checkpoint.hash(attrs)
      assert checkpoint_hash == :crypto.hash(:sha256, preimage)
      assert checkpoint_hash == submission.checkpoint_hash
    end

    test "strictly rejects malformed checkpoint record-hash preimages" do
      submission = checkpoint_submission_attrs()
      attrs = Map.drop(submission, [:checkpoint_hash, :content])
      assert {:ok, preimage} = Checkpoint.encode(attrs)

      domain = Contract.checkpoint_hash_domain()
      domain_size = byte_size(domain)
      <<_first, domain_rest::binary>> = preimage

      assert {:error, :checkpoint_hash_domain_mismatch} =
               Checkpoint.decode(<<0, domain_rest::binary>>)

      <<presented_domain::binary-size(domain_size), _version, body::binary>> = preimage
      assert presented_domain == domain

      assert {:error, :unsupported_checkpoint_hash_version} =
               Checkpoint.decode(domain <> <<Contract.version() + 1>> <> body)

      assert {:error, :truncated} =
               Checkpoint.decode(binary_part(preimage, 0, byte_size(preimage) - 1))

      assert {:error, :trailing_bytes} = Checkpoint.decode(preimage <> <<0>>)

      <<kind_prefix::binary-size(78), _kind, kind_suffix::binary>> = preimage

      assert {:error, :unknown_checkpoint_kind} =
               Checkpoint.decode(kind_prefix <> <<0xFF>> <> kind_suffix)

      <<schema_prefix::binary-size(79), _schema::16, schema_suffix::binary>> = preimage

      assert {:error, :unsupported_checkpoint_schema} =
               Checkpoint.decode(schema_prefix <> <<1::16>> <> schema_suffix)

      <<sequence_prefix::binary-size(70), _sequence::64, sequence_suffix::binary>> = preimage

      assert {:error, :invalid_delivery_sequence} =
               Checkpoint.decode(sequence_prefix <> <<0::64>> <> sequence_suffix)

      <<storage_prefix::binary-size(54), _storage::binary-size(16), storage_suffix::binary>> =
        preimage

      assert {:error, :invalid_storage_epoch} =
               Checkpoint.decode(storage_prefix <> <<0::128>> <> storage_suffix)

      assert {:error, :invalid_checkpoint} = Checkpoint.decode(:not_binary)
    end

    test "round-trips hydration across credential rotation and storage replacement" do
      submission = checkpoint_submission_attrs()

      hydration = %{
        device_id: @device_id,
        credential_epoch: 8,
        storage_epoch: @replacement_storage_epoch,
        origin_credential_epoch: submission.credential_epoch,
        origin_storage_epoch: submission.storage_epoch,
        sequence: submission.sequence,
        kind: submission.kind,
        schema_version: submission.schema_version,
        source_generation: submission.source_generation,
        parent_hash: submission.parent_hash,
        content_hash: submission.content_hash,
        checkpoint_hash: submission.checkpoint_hash,
        content: submission.content
      }

      refute Map.has_key?(hydration, :boot_id)
      assert {:ok, bytes} = Messages.encode(:checkpoint_hydration, hydration)
      assert {:ok, ^hydration} = Messages.decode(:checkpoint_hydration, bytes)

      assert bytes ==
               Contract.payload_domain(:checkpoint_hydration) <>
                 <<Contract.version(), 0x32, @device_id::binary, 8::32, @replacement_storage_epoch::binary, 7::32,
                   @storage_epoch::binary, 11::64, 0x02, @polar_schema::16, 42::64, @parent_hash::binary,
                   hydration.content_hash::binary-size(32), hydration.checkpoint_hash::binary-size(32),
                   byte_size(hydration.content)::32, hydration.content::binary>>
    end

    test "bounds durable checkpoint integers to signed database storage" do
      submission = checkpoint_submission_attrs()
      checkpoint_attrs = Map.drop(submission, [:checkpoint_hash, :content])

      oversized_sequence = Map.put(checkpoint_attrs, :sequence, @database_int_max + 1)

      assert {:error, :invalid_delivery_sequence} = Checkpoint.hash(oversized_sequence)

      assert {:error, :invalid_delivery_sequence} =
               Messages.encode(
                 :checkpoint_submission,
                 submission
                 |> Map.put(:sequence, oversized_sequence.sequence)
                 |> Map.put(:checkpoint_hash, raw_checkpoint_hash(oversized_sequence))
               )

      oversized_generation =
        Map.put(checkpoint_attrs, :source_generation, @database_int_max + 1)

      assert {:error, :invalid_source_generation} = Checkpoint.hash(oversized_generation)

      assert {:error, :invalid_source_generation} =
               Messages.encode(
                 :checkpoint_submission,
                 submission
                 |> Map.put(:source_generation, oversized_generation.source_generation)
                 |> Map.put(:checkpoint_hash, raw_checkpoint_hash(oversized_generation))
               )
    end

    test "rejects hash mismatches, unsupported schemas, and invalid parent hashes" do
      submission = checkpoint_submission_attrs()
      root_attrs = %{submission | parent_hash: :binary.copy(<<0>>, 32)}

      assert {:ok, root_hash} =
               Checkpoint.hash(Map.drop(root_attrs, [:checkpoint_hash, :content]))

      root = %{root_attrs | checkpoint_hash: root_hash}
      assert {:ok, _root_bytes} = Messages.encode(:checkpoint_submission, root)

      assert {:error, :checkpoint_content_hash_mismatch} =
               Messages.encode(:checkpoint_submission, %{
                 submission
                 | content_hash: :binary.copy(<<0xCC>>, 32)
               })

      assert {:error, :checkpoint_hash_mismatch} =
               Messages.encode(:checkpoint_submission, %{
                 submission
                 | checkpoint_hash: :binary.copy(<<0xDD>>, 32)
               })

      assert {:error, :invalid_delivery_sequence} =
               Messages.encode(:checkpoint_submission, %{submission | sequence: 0})

      assert {:error, :invalid_parent_hash} =
               Messages.encode(:checkpoint_submission, %{submission | parent_hash: <<0>>})

      # The RETIRED polar schema is rejected as firmly as an unreached future one:
      # a v1 index pair has no bin geometry, so it must never be accepted again.
      assert {:error, :unsupported_checkpoint_schema} =
               Messages.encode(:checkpoint_submission, %{submission | schema_version: 1})

      assert {:error, :unsupported_checkpoint_schema} =
               Messages.encode(:checkpoint_submission, %{submission | schema_version: @polar_schema + 1})

      assert {:error, :unknown_checkpoint_kind} =
               Messages.encode(:checkpoint_submission, %{submission | kind: :arbitrary})

      assert {:error, :unknown_checkpoint_kind} =
               Messages.encode(:checkpoint_submission, %{submission | kind: 0x02})
    end

    test "rejects secret-capable and open-ended checkpoint content" do
      safe = polar_checkpoint()
      [cell] = safe["cells"]

      for forbidden <- ["psk", "password", "passphrase", "metadata", "payload"] do
        unsafe = put_in(safe, ["cells"], [Map.put(cell, forbidden, "synthetic-noncredential")])

        assert {:error, :checkpoint_secret_forbidden} =
                 Checkpoint.encode_content(:polar, @polar_schema, unsafe)
      end

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(:polar, @polar_schema, %{
                 "cells" => [],
                 "arbitrary_numeric_tree" => [1, 2, 3]
               })
    end

    test "rejects typed-schema bypasses carried as self-consistent canonical bytes" do
      submission = checkpoint_submission_attrs()
      safe = polar_checkpoint()
      [cell] = safe["cells"]
      unsafe = put_in(safe, ["cells"], [Map.put(cell, "psk", "synthetic-noncredential")])
      assert {:ok, content} = Canonical.encode(unsafe)

      assert {:error, :checkpoint_secret_forbidden} =
               Checkpoint.decode_content(:polar, @polar_schema, content)

      content_hash =
        :crypto.hash(
          :sha256,
          Contract.checkpoint_content_hash_domain() <>
            <<Contract.version(), 0x02, @polar_schema::16, byte_size(content)::64, content::binary>>
        )

      attrs =
        submission
        |> Map.put(:content, content)
        |> Map.put(:content_hash, content_hash)

      assert {:ok, checkpoint_hash} =
               Checkpoint.hash(Map.drop(attrs, [:checkpoint_hash, :content]))

      forged = %{attrs | checkpoint_hash: checkpoint_hash}

      assert {:error, :checkpoint_secret_forbidden} =
               Messages.encode(:checkpoint_submission, forged)

      assert {:error, _} =
               Checkpoint.decode_content(:polar, @polar_schema, :erlang.term_to_binary(safe))

      assert {:error, _} =
               Checkpoint.decode_content(:polar, @polar_schema, submission.content <> <<0>>)
    end

    test "rejects wrong domains, versions, type substitution, truncation, and trailing bytes" do
      receipt = receipt_attrs()
      assert {:ok, bytes} = Messages.encode(:delivery_receipt, receipt)

      assert {:error, :payload_domain_mismatch} =
               Messages.decode(:checkpoint_hydration, bytes)

      assert {:error, :unsupported_payload_version} =
               Messages.decode(:delivery_receipt, replace_version(bytes, :delivery_receipt, 2))

      assert {:error, :payload_type_mismatch} =
               Messages.decode(:delivery_receipt, replace_type(bytes, :delivery_receipt, 0x31))

      assert {:error, :truncated} =
               Messages.decode(:delivery_receipt, binary_part(bytes, 0, byte_size(bytes) - 1))

      assert {:error, :trailing_bytes} = Messages.decode(:delivery_receipt, bytes <> <<0>>)
    end
  end

  defp delivery_submission_attrs(stream) do
    durable_identity(%{
      stream: stream,
      sequence: 11,
      payload_hash: @payload_hash
    })
  end

  defp receipt_attrs do
    attrs =
      durable_identity(%{
        stream: :telemetry,
        sequence: 7,
        payload_hash: @payload_hash,
        cumulative_sequence: 4
      })

    assert {:ok, receipt_hash} = Receipt.hash(attrs)
    Map.put(attrs, :receipt_hash, receipt_hash)
  end

  defp checkpoint_submission_attrs do
    assert {:ok, content} = Checkpoint.encode_content(:polar, @polar_schema, polar_checkpoint())
    assert {:ok, content_hash} = Checkpoint.content_hash(:polar, @polar_schema, content)

    attrs =
      durable_identity(%{
        sequence: 11,
        kind: :polar,
        schema_version: @polar_schema,
        source_generation: 42,
        parent_hash: @parent_hash,
        content_hash: content_hash
      })

    assert {:ok, checkpoint_hash} = Checkpoint.hash(attrs)

    attrs
    |> Map.put(:checkpoint_hash, checkpoint_hash)
    |> Map.put(:content, content)
  end

  defp durable_identity(extra) do
    Map.merge(
      %{
        device_id: @device_id,
        credential_epoch: 7,
        storage_epoch: @storage_epoch
      },
      extra
    )
  end

  defp empty_calibration_checkpoint do
    %{
      "awa_estimators" => [],
      "aws_estimators" => [],
      "prev_applied" => [],
      "seq" => 0,
      "stw_estimators" => []
    }
  end

  # Polar schema 2: one global `p` plus the exact bin geometry that gives the
  # bare `{tws_bin, twa_bin}` indices meaning. Per cell, `dnp`, `p`, the
  # quantile's own count, and the two derivable `n` endpoints are all absent —
  # only the three interior marker positions ship.
  defp polar_checkpoint do
    %{
      "cells" => [
        %{
          "count" => 5,
          "quantile" => %{
            "buffer" => [],
            "n" => [2, 3, 4],
            "np" => [1.0, 2.8, 4.6, 4.8, 5.0],
            "q" => [1.0, 2.0, 3.0, 4.0, 5.0]
          },
          "twa_bin" => 35,
          "tws_bin" => 3
        }
      ],
      "max_tws_mps" => 51.4444,
      "p" => 0.9,
      "twa_width_deg" => 5.0,
      "tws_width_mps" => 0.514444
    }
  end

  defp empty_wind_shift_checkpoint do
    %{
      "last_summary" => nil,
      "pending_events" => [],
      "pending_timeline" => [],
      "seq" => 0,
      "session" => nil
    }
  end

  defp raw_receipt_hash(attrs) do
    assert {:ok, stream_code} = Contract.delivery_stream(attrs.stream)

    :crypto.hash(
      :sha256,
      Contract.delivery_receipt_hash_domain() <>
        <<Contract.version(), attrs.device_id::binary-size(16), attrs.credential_epoch::32,
          attrs.storage_epoch::binary-size(16), stream_code, attrs.sequence::64, attrs.payload_hash::binary-size(32),
          attrs.cumulative_sequence::64>>
    )
  end

  defp raw_checkpoint_hash(attrs) do
    schema_version = attrs.schema_version
    assert {:ok, kind_code, ^schema_version} = Contract.checkpoint_kind(attrs.kind)

    :crypto.hash(
      :sha256,
      Contract.checkpoint_hash_domain() <>
        <<Contract.version(), attrs.device_id::binary-size(16), attrs.credential_epoch::32,
          attrs.storage_epoch::binary-size(16), attrs.sequence::64, kind_code, attrs.schema_version::16,
          attrs.source_generation::64, attrs.parent_hash::binary-size(32), attrs.content_hash::binary-size(32)>>
    )
  end

  defp replace_byte(bytes, offset, replacement),
    do: replace_bytes(bytes, offset, <<replacement>>)

  defp replace_bytes(bytes, offset, replacement) do
    <<prefix::binary-size(offset), _old::binary-size(byte_size(replacement)), suffix::binary>> =
      bytes

    prefix <> replacement <> suffix
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
