defmodule RacingOrg.Tracker.Pro.DurableDelivery.Submission.PlannerTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointSubmission.Payload, as: CheckpointPayload
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Entry
  alias RacingOrg.Tracker.Pro.DurableDelivery.Submission.Planner
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{
    Canonical,
    Checkpoint,
    Messages
  }

  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @entry_id Base.decode16!("102132435465768798a9bacbdcedfe0f", case: :lower)
  @credential_epoch 7
  @chunk_size 61_440

  describe "generic delivery entries" do
    test "plans the frozen delivery identity followed by one single-frame payload" do
      entry = generic_entry(:telemetry, <<0x00, 0xFF, 0x42>>)

      assert {:ok,
              %{
                entry: ^entry,
                payload: nil,
                frames: [
                  %{type: :delivery_submission, attrs: attrs},
                  %{type: :delivery_payload, attrs: payload_attrs}
                ]
              }} = Planner.plan(entry)

      assert attrs == %{
               device_id: @device_id,
               credential_epoch: @credential_epoch,
               storage_epoch: @storage_epoch,
               stream: :telemetry,
               sequence: 11,
               payload_hash: entry.payload_hash
             }

      refute Map.has_key?(attrs, :payload)
      refute Map.has_key?(attrs, :payload_checksum)
      assert {:ok, encoded} = Messages.encode(:delivery_submission, attrs)
      assert {:ok, ^attrs} = Messages.decode(:delivery_submission, encoded)

      assert payload_attrs == Map.put(attrs, :payload, entry.payload)
      assert {:ok, encoded_payload} = Messages.encode(:delivery_payload, payload_attrs)
      assert {:ok, ^payload_attrs} = Messages.decode(:delivery_payload, encoded_payload)
    end

    test "uses the single payload frame exactly up to the frozen single-frame cap" do
      payload = :binary.copy(<<0xAB>>, Contract.max_delivery_payload_size())
      entry = generic_entry(:race_recording_chunk, payload)

      assert {:ok, %{frames: [%{type: :delivery_submission}, %{type: :delivery_payload, attrs: attrs}]}} =
               Planner.plan(entry)

      assert attrs.payload == payload
      assert {:ok, _encoded} = Messages.encode(:delivery_payload, attrs)
    end

    test "chunks payloads immediately above the frozen single-frame cap" do
      total = Contract.max_delivery_payload_size() + 1
      payload = :binary.copy(<<0xCD>>, total)
      entry = generic_entry(:race_recording_chunk, payload)

      assert {:ok, %{payload: nil, frames: [%{type: :delivery_submission} | chunk_frames]}} =
               Planner.plan(entry)

      assert [
               %{type: :delivery_payload_chunk, attrs: first},
               %{type: :delivery_payload_chunk, attrs: final}
             ] = chunk_frames

      assert first.total_payload_length == total
      assert first.chunk_count == 2
      assert first.chunk_index == 0
      assert first.chunk_offset == 0
      assert byte_size(first.chunk) == @chunk_size
      assert final.chunk_index == 1
      assert final.chunk_offset == @chunk_size
      assert byte_size(final.chunk) == total - @chunk_size
    end

    test "chunked payload frames carry frozen geometry, hashes, and the exact payload bytes" do
      total = 2 * @chunk_size + 17
      payload = :crypto.hash(:sha256, "seed") |> then(&:binary.copy(&1, div(total, 32) + 1)) |> binary_part(0, total)
      entry = generic_entry(:desired_state_ack, payload)

      chunk_hash = fn attrs ->
        send(self(), {:payload_chunk_hash, attrs.chunk_index})
        Messages.delivery_payload_chunk_hash(attrs)
      end

      assert {:ok, %{frames: [%{type: :delivery_submission, attrs: common} | chunk_frames]}} =
               Planner.plan(entry, payload_chunk_hash: chunk_hash)

      assert_received {:payload_chunk_hash, 0}
      assert_received {:payload_chunk_hash, 1}
      assert_received {:payload_chunk_hash, 2}

      assert Enum.map(chunk_frames, & &1.type) == List.duplicate(:delivery_payload_chunk, 3)
      assert Enum.map(chunk_frames, & &1.attrs.chunk_index) == [0, 1, 2]
      assert Enum.map(chunk_frames, & &1.attrs.chunk_count) == [3, 3, 3]
      assert Enum.map(chunk_frames, & &1.attrs.chunk_offset) == [0, @chunk_size, 2 * @chunk_size]
      assert Enum.map(chunk_frames, & &1.attrs.total_payload_length) == List.duplicate(total, 3)
      assert Enum.map(chunk_frames, &byte_size(&1.attrs.chunk)) == [@chunk_size, @chunk_size, 17]
      assert IO.iodata_to_binary(Enum.map(chunk_frames, & &1.attrs.chunk)) == payload

      for frame <- chunk_frames do
        attrs = frame.attrs

        assert Map.drop(attrs, [
                 :total_payload_length,
                 :chunk_index,
                 :chunk_count,
                 :chunk_offset,
                 :chunk_hash,
                 :chunk
               ]) == common

        assert {:ok, attrs.chunk_hash} ==
                 Messages.delivery_payload_chunk_hash(
                   Map.take(attrs, [
                     :payload_hash,
                     :total_payload_length,
                     :chunk_index,
                     :chunk_count,
                     :chunk_offset,
                     :chunk
                   ])
                 )

        assert {:ok, encoded} = Messages.encode(:delivery_payload_chunk, attrs)
        assert {:ok, ^attrs} = Messages.decode(:delivery_payload_chunk, encoded)
      end
    end

    test "rejects a generic entry whose durable payload hash does not match its payload bytes" do
      entry = %{generic_entry(:health, "health") | payload_hash: <<0xA5::256>>}
      assert {:error, :delivery_payload_hash_mismatch} = Planner.plan(entry)
    end

    test "rejects payloads above the frozen generic content capacity" do
      total = Contract.max_delivery_payload_content_size() + 1
      entry = generic_entry(:race_recording_chunk, :binary.copy(<<0>>, total))
      assert {:error, :payload_too_large} = Planner.plan(entry)
    end

    test "uses an injected message encoder and propagates a frozen-contract rejection" do
      entry = generic_entry(:health, "health")

      encoder = fn type, attrs ->
        send(self(), {:encode, type, attrs})
        {:error, :rejected_by_contract}
      end

      assert {:error, :rejected_by_contract} = Planner.plan(entry, message_encoder: encoder)

      assert_received {:encode, :delivery_submission,
                       %{
                         stream: :health,
                         payload_hash: payload_hash
                       }}

      assert payload_hash == entry.payload_hash
    end
  end

  describe "checkpoint entries" do
    test "uses the frozen single-frame checkpoint submission when content fits its cap" do
      submission = checkpoint_submission(Contract.max_checkpoint_size())
      entry = checkpoint_entry(submission)

      assert {:ok,
              %{
                entry: ^entry,
                payload: nil,
                frames: [
                  %{
                    type: :checkpoint_submission,
                    attrs: attrs
                  }
                ]
              }} = Planner.plan(entry)

      assert attrs == submission
      assert {:ok, encoded} = Messages.encode(:checkpoint_submission, attrs)
      assert {:ok, ^attrs} = Messages.decode(:checkpoint_submission, encoded)
    end

    test "uses chunk carriage immediately above the frozen single-frame cap" do
      submission = checkpoint_submission(Contract.max_checkpoint_size() + 1)
      assert {:ok, payload} = CheckpointPayload.encode(submission)
      entry = checkpoint_entry(submission, payload)

      assert {:ok,
              %{
                frames: [
                  %{type: :checkpoint_submission_chunk, attrs: first},
                  %{type: :checkpoint_submission_chunk, attrs: final}
                ]
              }} = Planner.plan(entry)

      assert first.total_content_length == Contract.max_checkpoint_size() + 1
      assert first.chunk_count == 2
      assert first.chunk_index == 0
      assert first.chunk_offset == 0
      assert byte_size(first.chunk) == @chunk_size
      assert final.chunk_index == 1
      assert final.chunk_offset == @chunk_size
      assert byte_size(final.chunk) == Contract.max_checkpoint_size() + 1 - @chunk_size
    end

    test "keeps the exact legacy wire payload for single-frame durable checkpoints" do
      submission = checkpoint_submission(Contract.max_checkpoint_size())
      assert {:ok, legacy} = Messages.encode(:checkpoint_submission, submission)
      assert CheckpointPayload.encode(submission) == {:ok, legacy}
      assert CheckpointPayload.decode(legacy) == {:ok, submission}
    end

    test "rejects corruption of the durable large-checkpoint representation" do
      submission = checkpoint_submission(Contract.max_checkpoint_size() + 1)
      assert {:ok, payload} = CheckpointPayload.encode(submission)
      last = byte_size(payload) - 1
      <<prefix::binary-size(last), byte>> = payload
      corrupt = prefix <> <<Bitwise.bxor(byte, 1)>>

      assert {:error, :checkpoint_payload_checksum_mismatch} = CheckpointPayload.decode(corrupt)

      entry = checkpoint_entry(submission, corrupt)
      assert {:error, :checkpoint_payload_checksum_mismatch} = Planner.plan(entry)
    end

    test "chunks larger checkpoint content at exactly 61,440 bytes with frozen geometry and hashes" do
      content_size = 2 * @chunk_size + 17
      submission = checkpoint_submission(content_size)
      entry = checkpoint_entry(submission, submission.content)
      decoder = fn payload when payload == entry.payload -> {:ok, submission} end

      message_encoder = fn type, attrs ->
        send(self(), {:encode, type, attrs.chunk_index})
        Messages.encode(type, attrs)
      end

      chunk_hash = fn attrs ->
        send(self(), {:chunk_hash, attrs.chunk_index})
        Checkpoint.chunk_hash(attrs)
      end

      assert {:ok, %{entry: ^entry, payload: nil, frames: frames}} =
               Planner.plan(entry,
                 checkpoint_decoder: decoder,
                 message_encoder: message_encoder,
                 chunk_hash: chunk_hash
               )

      assert_received {:chunk_hash, 0}
      assert_received {:chunk_hash, 1}
      assert_received {:chunk_hash, 2}
      assert_received {:encode, :checkpoint_submission_chunk, 0}
      assert_received {:encode, :checkpoint_submission_chunk, 1}
      assert_received {:encode, :checkpoint_submission_chunk, 2}
      assert Enum.map(frames, & &1.type) == List.duplicate(:checkpoint_submission_chunk, 3)

      assert Enum.map(frames, &byte_size(&1.attrs.chunk)) == [@chunk_size, @chunk_size, 17]
      assert Enum.map(frames, & &1.attrs.chunk_index) == [0, 1, 2]
      assert Enum.map(frames, & &1.attrs.chunk_count) == [3, 3, 3]
      assert Enum.map(frames, & &1.attrs.chunk_offset) == [0, @chunk_size, 2 * @chunk_size]
      assert Enum.map(frames, & &1.attrs.total_content_length) == List.duplicate(content_size, 3)

      assert IO.iodata_to_binary(Enum.map(frames, & &1.attrs.chunk)) == submission.content

      common = Map.drop(submission, [:content])

      for frame <- frames do
        attrs = frame.attrs

        assert Map.drop(attrs, [:total_content_length, :chunk_index, :chunk_count, :chunk_offset, :chunk_hash, :chunk]) ==
                 common

        assert {:ok, attrs.chunk_hash} ==
                 Checkpoint.chunk_hash(
                   Map.take(attrs, [
                     :checkpoint_hash,
                     :total_content_length,
                     :chunk_index,
                     :chunk_count,
                     :chunk_offset,
                     :chunk
                   ])
                 )

        assert {:ok, encoded} = Messages.encode(:checkpoint_submission_chunk, attrs)
        assert {:ok, ^attrs} = Messages.decode(:checkpoint_submission_chunk, encoded)
      end
    end

    test "rejects chunk planning when canonical content does not match its frozen content hash" do
      submission = checkpoint_submission(Contract.max_checkpoint_size() + 1)
      forged = %{submission | content_hash: <<0xA5::256>>}
      assert {:ok, checkpoint_hash} = Checkpoint.hash(Map.drop(forged, [:checkpoint_hash, :content]))
      forged = %{forged | checkpoint_hash: checkpoint_hash}
      entry = checkpoint_entry(forged, forged.content)
      decoder = fn payload when payload == entry.payload -> {:ok, forged} end

      assert {:error, :checkpoint_content_hash_mismatch} =
               Planner.plan(entry, checkpoint_decoder: decoder)
    end

    test "rejects a checkpoint entry whose durable semantic hash is not the submission hash" do
      submission = checkpoint_submission(Contract.max_checkpoint_size() + 1)
      entry = %{checkpoint_entry(submission, submission.content) | payload_hash: <<0xA5::256>>}
      decoder = fn payload when payload == entry.payload -> {:ok, submission} end

      assert {:error, :checkpoint_submission_mismatch} =
               Planner.plan(entry, checkpoint_decoder: decoder)
    end
  end

  defp generic_entry(stream, payload) do
    %Entry{
      stream: stream,
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      sequence: 11,
      entry_id: @entry_id,
      payload_hash: :crypto.hash(:sha256, payload),
      payload_checksum: :crypto.hash(:sha256, payload),
      payload: payload,
      priority: 1,
      encoded_size: 256,
      ordinal: 1
    }
  end

  defp checkpoint_entry(submission), do: checkpoint_entry(submission, encoded_submission(submission))

  defp checkpoint_entry(submission, payload) do
    %Entry{
      stream: :checkpoint,
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      sequence: submission.sequence,
      entry_id: @entry_id,
      payload_hash: submission.checkpoint_hash,
      payload_checksum: :crypto.hash(:sha256, payload),
      payload: payload,
      priority: 0,
      encoded_size: byte_size(payload) + 128,
      ordinal: 1
    }
  end

  defp encoded_submission(submission) do
    assert {:ok, payload} = Messages.encode(:checkpoint_submission, submission)
    payload
  end

  defp checkpoint_submission(content_size) do
    content = runtime_polar_content(content_size)
    assert byte_size(content) == content_size
    assert {:ok, content_hash} = Checkpoint.content_hash(:polar, 3, content)

    attrs = %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      sequence: 11,
      kind: :polar,
      schema_version: 3,
      source_generation: 42,
      parent_hash: <<0::256>>,
      content_hash: content_hash
    }

    assert {:ok, checkpoint_hash} = Checkpoint.hash(attrs)

    attrs
    |> Map.put(:checkpoint_hash, checkpoint_hash)
    |> Map.put(:content, content)
  end

  defp runtime_polar_content(target_size) do
    Enum.find_value([polar_checkpoint(), %{polar_checkpoint() | "cells" => []}], fn learner ->
      content = runtime_polar_checkpoint(learner)
      assert {:ok, base} = Canonical.encode(content)
      padding_size = target_size - byte_size(base)

      if padding_size >= 0 and rem(padding_size, 2) == 0 do
        current_authority = content["authority"]["boat_identifier"]
        authority = :binary.copy("x", byte_size(current_authority) + div(padding_size, 2))

        padded =
          content
          |> put_in(["authority", "boat_identifier"], authority)
          |> put_in(["learner", "content", "authority"], authority)

        case Checkpoint.canonical_content(:polar, 3, padded) do
          {:ok, bytes} when byte_size(bytes) == target_size -> bytes
          _other -> nil
        end
      end
    end) || flunk("could not build exact #{target_size}-byte runtime polar checkpoint")
  end

  defp runtime_polar_checkpoint(learner) do
    authority = "boat-runtime"
    policy = runtime_polar_policy()
    assert {:ok, learner_bytes} = Checkpoint.canonical_content(:polar, 2, learner)
    assert {:ok, learner_hash} = Checkpoint.content_hash(:polar, 2, learner_bytes)

    %{
      "runtime_schema_version" => 3,
      "runtime_snapshot_version" => 1,
      "captured_at_utc_ms" => 1_786_536_000_000,
      "authority" => %{"boat_identifier" => authority},
      "policy" => policy,
      "learner" => %{
        "source_generation" => 42,
        "content" => %{
          "authority" => authority,
          "policy_hash" => policy["admission_hash"],
          "kind" => "polar",
          "schema_version" => 2,
          "source_generation" => 42,
          "content_hash" => Canonical.bytes(learner_hash),
          "content" => Canonical.bytes(learner_bytes)
        }
      },
      "upstream_seq" => 0,
      "window" => %{"count" => 0, "chunks" => []},
      "sync" => %{
        "dirty_keys" => %{"count" => 0, "chunks" => []},
        "last_sync_age_ms" => 0
      },
      "persistence_phase" => %{
        "dirty_keys" => %{"count" => 0, "chunks" => []},
        "force" => false,
        "last_persist_age_ms" => 0
      },
      "tick" => %{"remaining_ms" => nil}
    }
  end

  defp runtime_polar_policy do
    gate = %{
      "angle_band_deg" => [25.0, 165.0],
      "heel_band_deg" => [-45.0, 45.0],
      "max_tws_sd_mps" => 0.2572,
      "max_turn_rate_dps" => 3.0,
      "max_accel_mps2" => 0.05,
      "min_dwell" => 1,
      "engine_rpm_idle" => 50.0,
      "angle_key" => "twa_deg"
    }

    hash_content = %{
      "gate" => gate,
      "min_stw_mps" => 0.3,
      "p" => 0.9,
      "window_size" => 1
    }

    assert {:ok, hash_bytes} = Canonical.encode(hash_content)
    admission_hash = :crypto.hash(:sha256, "RacingOrg-PolarObserverPolicy-v1" <> hash_bytes)

    %{
      "admission_hash" => Canonical.bytes(admission_hash),
      "gate" => gate,
      "min_stw_mps" => 0.3,
      "window_size" => 1,
      "p" => 0.9,
      "sample_ms" => 0,
      "sync_ms" => 60_000,
      "persist_ms" => 60_000,
      "persistence_enabled" => true,
      "bins" => %{
        "twa_width_deg" => 5.0,
        "tws_width_mps" => 0.514444,
        "max_tws_mps" => 51.4444
      }
    }
  end

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
end
