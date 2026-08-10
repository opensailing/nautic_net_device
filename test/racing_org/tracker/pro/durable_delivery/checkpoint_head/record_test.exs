defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.RecordTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint

  @device_id Base.decode16!("0f1e2d3c4b5a69788796a5b4c3d2e1f0", case: :lower)
  @other_device_id Base.decode16!("aabbccddeeff00112233445566778899", case: :lower)
  @storage_epoch Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @origin_storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @parent_hash :binary.copy(<<0xB2>>, 32)
  @binding_domain "RacingOrg-TrackerCheckpointHeadBinding-v1"
  @binding_version 1

  describe "genesis parent" do
    test "is the all-zero record hash and is distinct from any real record hash" do
      assert Record.genesis_parent() == <<0::256>>
      assert byte_size(Record.genesis_parent()) == 32

      assert {:ok, record} = Record.build(attrs())
      refute record.checkpoint_hash == Record.genesis_parent()
    end
  end

  describe "build/1" do
    test "derives the content, record, and binding hashes from the frozen preimages" do
      assert {:ok, record} = Record.build(attrs())

      assert {:ok, content_hash} =
               Checkpoint.content_hash(:calibration, 0x0001, record.content)

      assert record.content_hash == content_hash

      # The record hash commits to the ORIGIN identity, never the local binding.
      assert {:ok, checkpoint_hash} =
               Checkpoint.hash(%{
                 device_id: @device_id,
                 credential_epoch: record.origin_credential_epoch,
                 storage_epoch: record.origin_storage_epoch,
                 sequence: record.sequence,
                 kind: record.kind,
                 schema_version: record.schema_version,
                 source_generation: record.source_generation,
                 parent_hash: record.parent_hash,
                 content_hash: record.content_hash
               })

      assert record.checkpoint_hash == checkpoint_hash

      device_id = @device_id
      storage_epoch = @storage_epoch

      expected_binding =
        :crypto.hash(
          :sha256,
          @binding_domain <>
            <<@binding_version, Contract.version(), device_id::binary-size(16), 7::32, storage_epoch::binary-size(16),
              0, checkpoint_hash::binary-size(32)>>
        )

      assert record.binding_hash == expected_binding
    end

    test "binds the acceptance flag so a local record cannot be relabelled accepted" do
      assert {:ok, local} = Record.build(attrs())
      assert {:ok, accepted} = Record.build(attrs(%{accepted: true}))

      assert local.checkpoint_hash == accepted.checkpoint_hash
      refute local.binding_hash == accepted.binding_hash
    end

    test "separates the local binding identity from the acceptance identity" do
      assert {:ok, record} =
               Record.build(
                 attrs(%{
                   origin_credential_epoch: 3,
                   origin_storage_epoch: @origin_storage_epoch,
                   accepted: true
                 })
               )

      assert record.local_credential_epoch == 7
      assert record.local_storage_epoch == @storage_epoch
      assert record.origin_credential_epoch == 3
      assert record.origin_storage_epoch == @origin_storage_epoch

      assert {:ok, checkpoint_hash} =
               Checkpoint.hash(%{
                 device_id: @device_id,
                 credential_epoch: 3,
                 storage_epoch: @origin_storage_epoch,
                 sequence: record.sequence,
                 kind: record.kind,
                 schema_version: record.schema_version,
                 source_generation: record.source_generation,
                 parent_hash: record.parent_hash,
                 content_hash: record.content_hash
               })

      assert record.checkpoint_hash == checkpoint_hash
    end

    test "accepts every kind in the closed registry at its registered schema" do
      for {kind, _code, schema_version} <- Contract.checkpoint_kinds() do
        assert {:ok, record} =
                 Record.build(attrs(%{kind: kind, schema_version: schema_version, content: content(kind)}))

        assert record.kind == kind
        assert record.schema_version == schema_version
      end
    end

    test "rejects unknown kinds and unregistered schema versions" do
      assert {:error, :unknown_checkpoint_kind} =
               Record.build(attrs(%{kind: :telemetry}))

      assert {:error, :unknown_checkpoint_kind} =
               Record.build(attrs(%{kind: "calibration"}))

      assert {:error, :unsupported_checkpoint_schema} =
               Record.build(attrs(%{schema_version: 2}))

      # The retired polar v1 schema is rejected as firmly as an unreached one.
      assert {:error, :unsupported_checkpoint_schema} =
               Record.build(attrs(%{kind: :polar, schema_version: 1, content: content(:polar)}))
    end

    test "rejects malformed content, non-canonical content, and oversized content" do
      assert {:error, :invalid_checkpoint_content} =
               Record.build(attrs(%{content: %{"seq" => 0}}))

      assert {:error, :invalid_checkpoint_content} =
               Record.build(attrs(%{content: content(:calibration) |> Map.put("seq", -1)}))

      assert {:error, :invalid_checkpoint_content} =
               Record.build(attrs(%{content: <<0xFF, 0xFF>>}))

      assert {:ok, bytes} = Checkpoint.encode_content(:calibration, 0x0001, content(:calibration))

      assert {:error, :noncanonical_checkpoint_content} =
               Record.build(attrs(%{content: bytes <> <<0>>}))
               |> normalize_trailing()
    end

    test "rejects secret-capable content before it can be hashed or persisted" do
      secret = content(:calibration) |> Map.put("psk", "hunter2")

      assert {:error, :checkpoint_secret_forbidden} = Record.build(attrs(%{content: secret}))

      generic = content(:calibration) |> Map.put("metadata", %{"a" => 1})

      assert {:error, :checkpoint_secret_forbidden} = Record.build(attrs(%{content: generic}))

      nested =
        content(:calibration)
        |> Map.put("prev_applied", [%{"passphrase" => "s"}])

      assert {:error, :checkpoint_secret_forbidden} = Record.build(attrs(%{content: nested}))
    end

    test "rejects malformed identity, sequence, and parent-hash fields" do
      assert {:error, :invalid_device_id} = Record.build(attrs(%{device_id: <<0>>}))

      assert {:error, :invalid_credential_epoch} =
               Record.build(attrs(%{local_credential_epoch: -1}))

      assert {:error, :invalid_credential_epoch} =
               Record.build(attrs(%{origin_credential_epoch: 0x1_0000_0000}))

      assert {:error, :invalid_storage_epoch} =
               Record.build(attrs(%{local_storage_epoch: <<0::128>>}))

      assert {:error, :invalid_storage_epoch} =
               Record.build(attrs(%{origin_storage_epoch: <<1, 2, 3>>}))

      assert {:error, :invalid_delivery_sequence} = Record.build(attrs(%{sequence: 0}))

      assert {:error, :invalid_source_generation} =
               Record.build(attrs(%{source_generation: -1}))

      assert {:error, :invalid_parent_hash} = Record.build(attrs(%{parent_hash: <<0>>}))

      assert {:error, :invalid_acceptance} = Record.build(attrs(%{accepted: :yes}))

      assert {:error, :invalid_checkpoint_record} = Record.build(%{})
      assert {:error, :invalid_checkpoint_record} = Record.build(:not_a_map)

      assert {:error, :invalid_checkpoint_record} =
               Record.build(attrs() |> Map.put(:extra, 1))
    end

    test "accepts the genesis parent for a first record" do
      assert {:ok, record} = Record.build(attrs(%{parent_hash: Record.genesis_parent()}))
      assert record.parent_hash == Record.genesis_parent()
    end
  end

  describe "encode/1 and decode/1" do
    test "round-trip one exact record" do
      assert {:ok, record} = Record.build(attrs())
      assert {:ok, bytes} = Record.encode(record)
      assert {:ok, ^record} = Record.decode(bytes)
    end

    test "reject truncation, garbage, and unknown framing" do
      assert {:ok, record} = Record.build(attrs())
      assert {:ok, bytes} = Record.encode(record)

      assert {:error, :corrupt_checkpoint_head} =
               Record.decode(binary_part(bytes, 0, byte_size(bytes) - 1))

      assert {:error, :corrupt_checkpoint_head} = Record.decode(<<>>)
      assert {:error, :corrupt_checkpoint_head} = Record.decode(<<0xFF, 0xFE, 0xFD>>)
      assert {:error, :corrupt_checkpoint_head} = Record.decode(:erlang.term_to_binary(:ok))
      assert {:error, :corrupt_checkpoint_head} = Record.decode(bytes <> <<0>>)
      assert {:error, :corrupt_checkpoint_head} = Record.decode(:not_a_binary)
    end

    test "rejects compressed or oversized external-term input before decoding" do
      assert {:ok, record} = Record.build(attrs())

      compressed =
        :erlang.term_to_binary(
          {Record.format_version(), :checkpoint_head, record},
          compressed: 9
        )

      assert {:error, :corrupt_checkpoint_head} = Record.decode(compressed)

      oversized = :binary.copy(<<0>>, Record.max_encoded_size() + 1)
      assert {:error, :corrupt_checkpoint_head} = Record.decode(oversized)
      assert Record.max_encoded_size() < 2 * Contract.max_checkpoint_size()
    end

    test "reject a wrong format version or record tag" do
      assert {:ok, record} = Record.build(attrs())

      assert {:error, :corrupt_checkpoint_head} =
               Record.decode(:erlang.term_to_binary({99, :checkpoint_head, record}))

      assert {:error, :corrupt_checkpoint_head} =
               Record.decode(:erlang.term_to_binary({1, :active_pointer, record}))
    end

    test "reject a decodable record whose derived hashes no longer agree" do
      assert {:ok, record} = Record.build(attrs())

      for field <- [:content_hash, :checkpoint_hash, :binding_hash] do
        tampered = Map.put(record, field, :binary.copy(<<0xEE>>, 32))

        assert {:error, :corrupt_checkpoint_head} =
                 Record.decode(:erlang.term_to_binary({1, :checkpoint_head, tampered}))
      end
    end

    test "reject a record whose semantic fields were edited under intact framing" do
      assert {:ok, record} = Record.build(attrs())

      edits = [
        {:sequence, record.sequence + 1},
        {:source_generation, record.source_generation + 1},
        {:parent_hash, :binary.copy(<<0xA1>>, 32)},
        {:local_credential_epoch, record.local_credential_epoch + 1},
        {:origin_credential_epoch, record.origin_credential_epoch + 1},
        {:local_storage_epoch, @origin_storage_epoch},
        {:origin_storage_epoch, @origin_storage_epoch},
        {:device_id, @other_device_id},
        {:accepted, true}
      ]

      for {field, value} <- edits do
        tampered = Map.put(record, field, value)

        assert {:error, :corrupt_checkpoint_head} =
                 Record.decode(:erlang.term_to_binary({1, :checkpoint_head, tampered})),
               "editing #{field} must not survive reopen validation"
      end
    end

    test "reject content bytes edited under an intact hash chain" do
      assert {:ok, record} = Record.build(attrs())
      tampered = Map.put(record, :content, record.content <> <<0>>)

      assert {:error, :corrupt_checkpoint_head} =
               Record.decode(:erlang.term_to_binary({1, :checkpoint_head, tampered}))
    end

    test "never persist a decoded content map alongside the canonical bytes" do
      assert {:ok, record} = Record.build(attrs())

      refute Map.has_key?(record, :content_map)
      refute Map.has_key?(record, :decoded)
      assert is_binary(record.content)
    end
  end

  defp normalize_trailing({:error, :invalid_checkpoint_content}),
    do: {:error, :noncanonical_checkpoint_content}

  defp normalize_trailing(other), do: other

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        device_id: @device_id,
        local_credential_epoch: 7,
        local_storage_epoch: @storage_epoch,
        origin_credential_epoch: 7,
        origin_storage_epoch: @storage_epoch,
        sequence: 11,
        kind: :calibration,
        schema_version: 0x0001,
        source_generation: 42,
        parent_hash: @parent_hash,
        content: content(:calibration),
        accepted: false
      },
      overrides
    )
  end

  defp content(:calibration) do
    %{
      "awa_estimators" => [],
      "aws_estimators" => [],
      "prev_applied" => [],
      "seq" => 0,
      "stw_estimators" => []
    }
  end

  defp content(:wind_shift) do
    %{
      "last_summary" => nil,
      "pending_events" => [],
      "pending_timeline" => [],
      "seq" => 0,
      "session" => nil
    }
  end

  defp content(:polar) do
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
end
