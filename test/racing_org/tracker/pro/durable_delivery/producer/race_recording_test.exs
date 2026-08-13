defmodule RacingOrg.Tracker.Pro.DurableDelivery.Producer.RaceRecordingTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableDelivery.Producer.RaceRecording
  alias RacingOrg.Tracker.Protobuf.{ChunkDescriptor, RaceManifest}

  @chunk_bytes <<0, 4, "race", 0, 3, "raw">>
  @manifest %RaceManifest{
    race_recording_id: "race-recording-7",
    device_id: "device-22",
    assignment_id: "assignment-31",
    assignment_version: 5,
    chunks: [
      %ChunkDescriptor{
        chunk_id: "0007",
        byte_count: byte_size(@chunk_bytes),
        checksum: "6814f8e4",
        sample_count: 19
      }
    ],
    total_sample_count: 19,
    course_hash: "course-v4",
    route_hash: "route-v2",
    device_status: "complete"
  }

  describe "admit_chunk/4" do
    test "admits the sealed raw bytes with a deterministic source identity" do
      parent = self()

      enqueue = fn stream, payload, opts ->
        send(parent, {:enqueue, stream, payload, opts})
        {:ok, %{stream: stream, sequence: 7}}
      end

      assert {:ok, %{stream: :race_recording_chunk, sequence: 7}} =
               RaceRecording.admit_chunk(enqueue, "race-recording-7", "0007", @chunk_bytes)

      expected_entry_id =
        :crypto.hash(
          :sha256,
          [
            "RacingOrg-RaceRecordingChunkEntryId-v1",
            <<16::unsigned-big-integer-size(32)>>,
            "race-recording-7",
            <<4::unsigned-big-integer-size(32)>>,
            "0007"
          ]
        )

      assert_receive {:enqueue, :race_recording_chunk, @chunk_bytes, [entry_id: ^expected_entry_id]}
    end

    test "retries reuse the exact same idempotency identity" do
      parent = self()

      enqueue = fn stream, payload, opts ->
        send(parent, {:enqueue, stream, payload, opts})
        {:error, {:backpressure, :max_entries}}
      end

      assert {:error, {:backpressure, :max_entries}} =
               RaceRecording.admit_chunk(enqueue, "race-recording-7", "0007", @chunk_bytes)

      assert {:error, {:backpressure, :max_entries}} =
               RaceRecording.admit_chunk(enqueue, "race-recording-7", "0007", @chunk_bytes)

      assert_receive {:enqueue, :race_recording_chunk, @chunk_bytes, first_opts}
      assert_receive {:enqueue, :race_recording_chunk, @chunk_bytes, second_opts}
      assert first_opts == second_opts
    end

    test "propagates durable admission errors unchanged" do
      for error <- [
            {:error, :identity_unbound},
            {:error, :identity_changed},
            {:error, {:backpressure, :max_bytes}},
            {:error, {:durability_uncertain, :sync}}
          ] do
        assert ^error =
                 RaceRecording.admit_chunk(
                   fn _stream, _payload, _opts -> error end,
                   "race-recording-7",
                   "0007",
                   @chunk_bytes
                 )
      end
    end

    test "rejects invalid source identity and payload before enqueue" do
      enqueue = fn _stream, _payload, _opts -> flunk("enqueue must not run") end

      assert {:error, :invalid_race_recording_id} =
               RaceRecording.admit_chunk(enqueue, "", "0007", @chunk_bytes)

      assert {:error, :invalid_race_recording_id} =
               RaceRecording.admit_chunk(enqueue, String.duplicate("r", 65_536), "0007", @chunk_bytes)

      assert {:error, :invalid_chunk_id} =
               RaceRecording.admit_chunk(enqueue, "race-recording-7", "", @chunk_bytes)

      assert {:error, :invalid_chunk_id} =
               RaceRecording.admit_chunk(
                 enqueue,
                 "race-recording-7",
                 String.duplicate("c", 65_536),
                 @chunk_bytes
               )

      assert {:error, :invalid_chunk_bytes} =
               RaceRecording.admit_chunk(enqueue, "race-recording-7", "0007", <<>>)

      assert {:error, :invalid_chunk_bytes} =
               RaceRecording.admit_chunk(enqueue, "race-recording-7", "0007", nil)

      assert {:error, :invalid_enqueue} =
               RaceRecording.admit_chunk(:not_a_function, "race-recording-7", "0007", @chunk_bytes)
    end
  end

  describe "admit_manifest/3" do
    test "encodes and admits the exact RaceManifest protobuf bytes" do
      parent = self()
      expected_bytes = RaceManifest.encode(@manifest)

      enqueue = fn stream, payload, opts ->
        send(parent, {:enqueue, stream, payload, opts})
        {:ok, %{stream: stream, sequence: 3}}
      end

      assert {:ok, %{stream: :race_recording_manifest, sequence: 3}} =
               RaceRecording.admit_manifest(enqueue, "race-recording-7", @manifest)

      expected_entry_id =
        :crypto.hash(
          :sha256,
          [
            "RacingOrg-RaceRecordingManifestEntryId-v1",
            <<16::unsigned-big-integer-size(32)>>,
            "race-recording-7"
          ]
        )

      assert_receive {:enqueue, :race_recording_manifest, ^expected_bytes, [entry_id: ^expected_entry_id]}
    end

    test "binds manifest identity to the encoded protobuf recording id" do
      enqueue = fn _stream, _payload, _opts -> flunk("enqueue must not run") end

      assert {:error, :race_recording_id_mismatch} =
               RaceRecording.admit_manifest(enqueue, "another-recording", @manifest)

      assert {:error, :invalid_manifest} =
               RaceRecording.admit_manifest(
                 enqueue,
                 "race-recording-7",
                 %{@manifest | race_recording_id: ""}
               )

      assert {:error, :invalid_manifest} =
               RaceRecording.admit_manifest(
                 enqueue,
                 "race-recording-7",
                 %{@manifest | race_recording_id: String.duplicate("r", 65_536)}
               )

      assert {:error, :invalid_manifest} =
               RaceRecording.admit_manifest(
                 enqueue,
                 "race-recording-7",
                 %{@manifest | assignment_version: :not_an_integer}
               )
    end

    test "retries reuse the same protobuf bytes and idempotency identity" do
      parent = self()

      enqueue = fn stream, payload, opts ->
        send(parent, {:enqueue, stream, payload, opts})
        {:error, :duplicate_entry_id}
      end

      assert {:error, :duplicate_entry_id} =
               RaceRecording.admit_manifest(enqueue, "race-recording-7", @manifest)

      assert {:error, :duplicate_entry_id} =
               RaceRecording.admit_manifest(enqueue, "race-recording-7", @manifest)

      assert_receive {:enqueue, :race_recording_manifest, first_bytes, first_opts}
      assert_receive {:enqueue, :race_recording_manifest, second_bytes, second_opts}
      assert first_bytes == RaceManifest.encode(@manifest)
      assert second_bytes == first_bytes
      assert second_opts == first_opts
    end

    test "propagates durable admission errors unchanged" do
      for error <- [
            {:error, :identity_unbound},
            {:error, :quarantined},
            {:error, {:backpressure, :max_disk_bytes}},
            {:error, {:durability_uncertain, :rename}}
          ] do
        assert ^error =
                 RaceRecording.admit_manifest(
                   fn _stream, _payload, _opts -> error end,
                   "race-recording-7",
                   @manifest
                 )
      end
    end

    test "rejects invalid source identity and manifests before enqueue" do
      enqueue = fn _stream, _payload, _opts -> flunk("enqueue must not run") end

      assert {:error, :invalid_race_recording_id} =
               RaceRecording.admit_manifest(enqueue, "", @manifest)

      assert {:error, :invalid_race_recording_id} =
               RaceRecording.admit_manifest(enqueue, String.duplicate("r", 65_536), @manifest)

      assert {:error, :invalid_manifest} =
               RaceRecording.admit_manifest(enqueue, "race-recording-7", %{})

      assert {:error, :invalid_enqueue} =
               RaceRecording.admit_manifest(:not_a_function, "race-recording-7", @manifest)
    end
  end
end
