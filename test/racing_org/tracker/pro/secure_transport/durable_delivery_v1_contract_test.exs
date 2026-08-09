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

  describe "closed durable-delivery registries" do
    test "freezes message codes, directions, streams, and checkpoint schemas" do
      assert Contract.message_type(:delivery_receipt) ==
               {:ok, 0x30, :server_to_device}

      assert Contract.message_type(:checkpoint_submission) ==
               {:ok, 0x31, :device_to_server}

      assert Contract.message_type(:checkpoint_hydration) ==
               {:ok, 0x32, :server_to_device}

      assert Contract.payload_domain(:delivery_receipt) ==
               "RacingOrg-DurableDeliveryReceipt-v1"

      assert Contract.payload_domain(:checkpoint_submission) ==
               "RacingOrg-CheckpointSubmission-v1"

      assert Contract.payload_domain(:checkpoint_hydration) ==
               "RacingOrg-CheckpointHydration-v1"

      assert Contract.delivery_receipt_hash_domain() ==
               "RacingOrg-DurableDeliveryReceiptHash-v1"

      assert Contract.checkpoint_content_hash_domain() ==
               "RacingOrg-CheckpointContentHash-v1"

      assert Contract.checkpoint_hash_domain() ==
               "RacingOrg-CheckpointRecordHash-v1"

      assert Contract.max_checkpoint_size() == 8_388_608

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

      assert Contract.checkpoint_kinds() == [
               {:calibration, 0x01, 0x0001},
               {:polar, 0x02, 0x0001},
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

    test "rejects sequence zero, unknown streams, malformed hashes, and receipt tampering" do
      receipt = receipt_attrs()

      assert {:error, :invalid_delivery_sequence} =
               Messages.encode(:delivery_receipt, %{receipt | sequence: 0})

      assert {:error, :unknown_delivery_stream} =
               Messages.encode(:delivery_receipt, %{receipt | stream: :arbitrary})

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
        assert {:ok, bytes} = Checkpoint.encode_content(kind, 1, content)
        assert {:ok, ^content} = Checkpoint.decode_content(kind, 1, bytes)
        assert {:ok, hash} = Checkpoint.content_hash(kind, 1, bytes)
        assert {:ok, kind_code, 1} = Contract.checkpoint_kind(kind)

        assert hash ==
                 :crypto.hash(
                   :sha256,
                   Contract.checkpoint_content_hash_domain() <>
                     <<Contract.version(), kind_code, 1::16, byte_size(bytes)::64, bytes::binary>>
                 )
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
            <<Contract.version(), @device_id::binary, 7::32, @storage_epoch::binary, 11::64, 0x02, 1::16, 42::64,
              @parent_hash::binary, submission.content_hash::binary-size(32)>>
        )

      assert submission.checkpoint_hash == expected_hash

      assert bytes ==
               Contract.payload_domain(:checkpoint_submission) <>
                 <<Contract.version(), 0x31, @device_id::binary, 7::32, @storage_epoch::binary, 11::64, 0x02, 1::16,
                   42::64, @parent_hash::binary, submission.content_hash::binary-size(32),
                   expected_hash::binary-size(32), byte_size(submission.content)::32, submission.content::binary>>
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
                   @storage_epoch::binary, 11::64, 0x02, 1::16, 42::64, @parent_hash::binary,
                   hydration.content_hash::binary-size(32), hydration.checkpoint_hash::binary-size(32),
                   byte_size(hydration.content)::32, hydration.content::binary>>
    end

    test "rejects hash mismatches, unsupported schemas, and invalid parent hashes" do
      submission = checkpoint_submission_attrs()
      root_attrs = %{submission | parent_hash: :binary.copy(<<0>>, 32)}
      assert {:ok, root_hash} = Checkpoint.hash(Map.drop(root_attrs, [:checkpoint_hash, :content]))
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

      assert {:error, :unsupported_checkpoint_schema} =
               Messages.encode(:checkpoint_submission, %{submission | schema_version: 2})

      assert {:error, :unknown_checkpoint_kind} =
               Messages.encode(:checkpoint_submission, %{submission | kind: :arbitrary})
    end

    test "rejects secret-capable and open-ended checkpoint content" do
      safe = polar_checkpoint()
      [cell] = safe["cells"]

      for forbidden <- ["psk", "password", "passphrase", "metadata", "payload"] do
        unsafe = put_in(safe, ["cells"], [Map.put(cell, forbidden, "synthetic-noncredential")])

        assert {:error, :checkpoint_secret_forbidden} =
                 Checkpoint.encode_content(:polar, 1, unsafe)
      end

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(:polar, 1, %{
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
               Checkpoint.decode_content(:polar, 1, content)

      content_hash =
        :crypto.hash(
          :sha256,
          Contract.checkpoint_content_hash_domain() <>
            <<Contract.version(), 0x02, 1::16, byte_size(content)::64, content::binary>>
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
               Checkpoint.decode_content(:polar, 1, :erlang.term_to_binary(safe))

      assert {:error, _} =
               Checkpoint.decode_content(:polar, 1, submission.content <> <<0>>)
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
    assert {:ok, content} = Checkpoint.encode_content(:polar, 1, polar_checkpoint())
    assert {:ok, content_hash} = Checkpoint.content_hash(:polar, 1, content)

    attrs =
      durable_identity(%{
        sequence: 11,
        kind: :polar,
        schema_version: 1,
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

  defp polar_checkpoint do
    %{
      "cells" => [
        %{
          "count" => 5,
          "quantile" => %{
            "buffer" => [],
            "count" => 5,
            "dnp" => [0.0, 0.45, 0.9, 0.95, 1.0],
            "n" => [1, 2, 3, 4, 5],
            "np" => [1.0, 2.8, 4.6, 4.8, 5.0],
            "p" => 0.9,
            "q" => [1.0, 2.0, 3.0, 4.0, 5.0]
          },
          "twa_bin" => 45,
          "tws_bin" => 3
        }
      ]
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
