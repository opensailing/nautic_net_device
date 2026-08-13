defmodule RacingOrg.Tracker.Pro.Race.ArchiveTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.DurableDelivery.Producer.RaceRecording, as: RaceRecordingProducer
  alias RacingOrg.Tracker.Protobuf.DataSet
  alias RacingOrg.Tracker.Protobuf.DeviceCommand
  alias RacingOrg.Tracker.Protobuf.ManifestVerificationResult
  alias RacingOrg.Tracker.Protobuf.MissingChunkRequest
  alias RacingOrg.Tracker.Protobuf.RaceAssignment
  alias RacingOrg.Tracker.Protobuf.RaceManifest
  alias RacingOrg.Tracker.Protobuf.ServerReply
  alias RacingOrg.Tracker.Pro.Race.Archive
  alias RacingOrg.Tracker.Pro.Race.Recording

  setup do
    base = Path.join(System.tmp_dir!(), "nn_arc_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  defp start_archive(base, opts \\ []) do
    test_pid = self()
    commands = start_supervised!({Commands, device_id: "dev"})

    archive_opts =
      Keyword.merge(
        [
          base_dir: base,
          commands: commands,
          device_id: "dev",
          enqueue_fn: fn binary -> send(test_pid, {:enqueued, binary}) end,
          durable_enqueue_fn: fn _stream, _payload, _opts -> {:ok, %{}} end,
          durable_pending_fn: fn -> [] end,
          now_fn: fn -> ~U[2026-06-03 12:00:00Z] end,
          name: nil
        ],
        opts
      )

    archive = start_supervised!({Archive, archive_opts})

    %{commands: commands, archive: archive}
  end

  defp assign(commands, recording_id, attrs) do
    race =
      struct(
        RaceAssignment,
        [race_recording_id: recording_id, route_hash: "rh"] ++ attrs
      )

    command =
      struct(DeviceCommand,
        command_id: "c1",
        assignment_id: "a1",
        assignment_version: 1,
        assignment_hash: "course-hash",
        payload: {:race_assignment, race}
      )

    reply = struct(ServerReply, protocol_version: 1, device_id: "", command: command) |> ServerReply.encode()
    :applied = Commands.apply_reply(commands, reply)
  end

  defp ds(i), do: DataSet.encode(struct(DataSet, boat_identifier: "b", counter: i))

  defp race(archive, commands, recording_id, samples, assign_attrs \\ []) do
    assign(commands, recording_id, assign_attrs)
    send(archive, {:sampling_phase, :idle, :racing})
    for i <- samples, do: Archive.record(archive, ds(i))
  end

  defp finish(archive) do
    send(archive, {:sampling_phase, :finish, :complete})
    assert Archive.current_recording_id(archive) == nil
  end

  defp durable_opts(test_pid, overrides \\ []) do
    enqueue =
      Keyword.get(overrides, :durable_enqueue_fn, fn stream, payload, opts ->
        send(test_pid, {:durable_enqueue, stream, payload, opts})
        {:ok, %{stream: stream}}
      end)

    pending = Keyword.get(overrides, :durable_pending_fn, fn -> [] end)

    [
      durable_enqueue_fn: enqueue,
      durable_pending_fn: pending
    ]
  end

  test "opens a recording on race start and tracks the active recording id", %{base: base} do
    %{commands: c, archive: a} = start_archive(base)
    race(a, c, "2026-06-03-7", [1, 2])
    assert Archive.current_recording_id(a) == "2026-06-03-7"
  end

  test "durably admits exact sealed chunks and manifest before completing finalization", %{base: base} do
    test_pid = self()
    %{commands: c, archive: a} = start_archive(base, durable_opts(test_pid))
    race(a, c, "2026-06-03-7", [1, 2, 3])
    finish(a)

    assert_receive {:enqueued, binary}
    manifest = DataSet.decode(binary).manifest
    assert manifest.race_recording_id == "2026-06-03-7"
    assert manifest.total_sample_count == 3
    assert manifest.device_status == "complete"
    assert [chunk] = manifest.chunks

    assert {:ok, recording} = Recording.load(base, "2026-06-03-7")
    chunk_bytes = File.read!(Path.join(recording.dir, "chunk-#{chunk.chunk_id}"))
    manifest_bytes = File.read!(Path.join(recording.dir, "manifest.pb"))

    assert_receive {:durable_enqueue, :race_recording_chunk, ^chunk_bytes, chunk_opts}
    assert_receive {:durable_enqueue, :race_recording_manifest, ^manifest_bytes, manifest_opts}

    expected_chunk_id =
      capture_entry_id(fn enqueue ->
        RaceRecordingProducer.admit_chunk(
          enqueue,
          "2026-06-03-7",
          chunk.chunk_id,
          chunk_bytes
        )
      end)

    expected_manifest_id =
      capture_entry_id(fn enqueue ->
        RaceRecordingProducer.admit_manifest(enqueue, "2026-06-03-7", manifest)
      end)

    assert chunk_opts == [entry_id: expected_chunk_id]
    assert manifest_opts == [entry_id: expected_manifest_id]
    assert Archive.current_recording_id(a) == nil
    assert "2026-06-03-7" in Recording.list(base)
  end

  test "durable admission errors retain the finalized recording and fail closed", %{base: base} do
    test_pid = self()

    opts =
      durable_opts(test_pid,
        durable_enqueue_fn: fn stream, payload, opts ->
          send(test_pid, {:durable_attempt, stream, payload, opts})
          {:error, {:backpressure, :disk_capacity}}
        end
      )

    %{commands: c, archive: a} = start_archive(base, opts)
    race(a, c, "2026-06-03-7", [1])
    send(a, {:sampling_phase, :finish, :complete})

    assert Archive.current_recording_id(a) == "2026-06-03-7"
    assert "2026-06-03-7" in Recording.list(base)
    assert_receive {:durable_attempt, :race_recording_chunk, _payload, _opts}
    refute_receive {:durable_attempt, :race_recording_manifest, _payload, _opts}
    refute_receive {:enqueued, _legacy_manifest}
  end

  test "retry accepts an exact pending duplicate chunk and continues to manifest", %{base: base} do
    test_pid = self()
    {:ok, durable} = Agent.start_link(fn -> %{attempt: 0, pending: []} end)

    durable_enqueue = fn stream, payload, entry_id: entry_id ->
      result =
        Agent.get_and_update(durable, fn state ->
          entry = %{stream: stream, entry_id: entry_id, payload: payload}

          {result, pending} =
            case state.attempt do
              0 -> {{:ok, %{stream: stream}}, [entry]}
              1 -> {{:error, {:backpressure, :disk_capacity}}, state.pending}
              2 -> {{:error, :duplicate_entry_id}, state.pending}
              _later -> {{:ok, %{stream: stream}}, [entry | state.pending]}
            end

          {result, %{state | attempt: state.attempt + 1, pending: pending}}
        end)

      send(test_pid, {:durable_attempt, stream, payload, entry_id, result})
      result
    end

    durable_pending = fn -> Agent.get(durable, & &1.pending) end

    %{commands: c, archive: a} =
      start_archive(base,
        durable_enqueue_fn: durable_enqueue,
        durable_pending_fn: durable_pending
      )

    race(a, c, "2026-06-03-7", [1])
    send(a, {:sampling_phase, :finish, :complete})
    assert Archive.current_recording_id(a) == "2026-06-03-7"

    assert_receive {:durable_attempt, :race_recording_chunk, chunk_bytes, chunk_entry_id, {:ok, _receipt}}

    assert_receive {:durable_attempt, :race_recording_manifest, _manifest_bytes, _manifest_entry_id,
                    {:error, {:backpressure, :disk_capacity}}}

    send(a, {:sampling_phase, :finish, :complete})
    assert Archive.current_recording_id(a) == nil

    assert_receive {:durable_attempt, :race_recording_chunk, ^chunk_bytes, ^chunk_entry_id,
                    {:error, :duplicate_entry_id}}

    assert_receive {:durable_attempt, :race_recording_manifest, _manifest_bytes, _manifest_entry_id, {:ok, _receipt}}

    assert_receive {:enqueued, _legacy_manifest}
  end

  test "restart accepts exact pending duplicates for both chunks and manifest", %{base: base} do
    test_pid = self()

    {recording, manifest} =
      base
      |> Recording.open(%{recording_id: "2026-06-03-3", device_id: "dev"})
      |> Recording.append(ds(1))
      |> Recording.finalize(device_status: "recovered")

    assert {:ok, [%{descriptor: descriptor, bytes: chunk_bytes}]} =
             Recording.sealed_chunk_artifacts(recording)

    assert {:ok, %{bytes: manifest_bytes}} = Recording.manifest_artifact(recording)

    pending = [
      %{
        stream: :race_recording_chunk,
        entry_id: RaceRecordingProducer.chunk_entry_id(recording.recording_id, descriptor.chunk_id),
        payload: chunk_bytes
      },
      %{
        stream: :race_recording_manifest,
        entry_id: RaceRecordingProducer.manifest_entry_id(recording.recording_id),
        payload: manifest_bytes
      }
    ]

    start_archive(base,
      durable_enqueue_fn: fn stream, payload, opts ->
        send(test_pid, {:durable_duplicate, stream, payload, opts})
        {:error, :duplicate_entry_id}
      end,
      durable_pending_fn: fn -> pending end
    )

    assert_receive {:durable_duplicate, :race_recording_chunk, ^chunk_bytes, _opts}
    assert_receive {:durable_duplicate, :race_recording_manifest, ^manifest_bytes, _opts}
    assert_receive {:enqueued, legacy_bytes}
    assert DataSet.decode(legacy_bytes).manifest == manifest
  end

  test "retry rejects a duplicate whose pending payload does not match", %{base: base} do
    test_pid = self()

    durable_enqueue = fn stream, payload, entry_id: entry_id ->
      send(test_pid, {:durable_attempt, stream, payload, entry_id})
      {:error, :duplicate_entry_id}
    end

    durable_pending = fn ->
      [%{stream: :race_recording_chunk, entry_id: <<0::256>>, payload: "unrelated"}]
    end

    %{commands: c, archive: a} =
      start_archive(base,
        durable_enqueue_fn: durable_enqueue,
        durable_pending_fn: durable_pending
      )

    race(a, c, "2026-06-03-7", [1])
    send(a, {:sampling_phase, :finish, :complete})

    assert Archive.current_recording_id(a) == "2026-06-03-7"
    assert_receive {:durable_attempt, :race_recording_chunk, _payload, _entry_id}
    refute_receive {:durable_attempt, :race_recording_manifest, _payload, _entry_id}
    refute_receive {:enqueued, _legacy_manifest}
  end

  test "legacy completion is not an authoritative durable receipt", %{base: base} do
    test_pid = self()
    %{commands: c, archive: a} = start_archive(base, durable_opts(test_pid))
    race(a, c, "2026-06-03-7", [1])
    finish(a)
    assert_receive {:enqueued, _manifest}

    verification =
      struct(DeviceCommand,
        command_id: "v1",
        payload:
          {:manifest_verification_result,
           struct(ManifestVerificationResult, race_recording_id: "2026-06-03-7", complete: true)}
      )

    send(a, {:racing_org_command, verification})
    _ = Archive.current_recording_id(a)
    assert "2026-06-03-7" in Recording.list(base)
  end

  test "re-sends requested missing chunks", %{base: base} do
    %{commands: c, archive: a} = start_archive(base)
    race(a, c, "2026-06-03-7", [1, 2])
    finish(a)
    assert_receive {:enqueued, manifest_binary}
    [chunk] = DataSet.decode(manifest_binary).manifest.chunks

    request =
      struct(DeviceCommand,
        command_id: "m1",
        payload:
          {:missing_chunk_request,
           struct(MissingChunkRequest, race_recording_id: "2026-06-03-7", chunk_ids: [chunk.chunk_id])}
      )

    send(a, {:racing_org_command, request})
    _recording_id = Archive.current_recording_id(a)

    # The two archived samples are re-enqueued from the chunk.
    assert_receive {:enqueued, resent1}
    assert_receive {:enqueued, resent2}
    counters = Enum.map([resent1, resent2], &DataSet.decode(&1).counter)
    assert Enum.sort(counters) == [1, 2]
  end

  test "triggers a post-race bulk upload with the recording id + race_session_id", %{base: base} do
    test_pid = self()

    %{commands: c, archive: a} =
      start_archive(base,
        bulk_upload_fn: fn opts -> send(test_pid, {:bulk_upload, opts}) end
      )

    race(a, c, "2026-06-03-7", [1, 2], race_session_id: "sess-abc")
    finish(a)

    assert_receive {:bulk_upload, opts}
    assert opts[:base_dir] == base
    assert opts[:recording_id] == "2026-06-03-7"
    assert opts[:race_session_id] == "sess-abc"

    # The recording is still kept on disk (deletion waits for the server's
    # manifest_verification_result command, not the bulk upload trigger).
    assert "2026-06-03-7" in Recording.list(base)
  end

  test "skips the bulk upload when the assignment has no race_session_id", %{base: base} do
    test_pid = self()

    %{commands: c, archive: a} =
      start_archive(base,
        bulk_upload_fn: fn opts -> send(test_pid, {:bulk_upload, opts}) end
      )

    race(a, c, "2026-06-03-7", [1])
    finish(a)

    # The legacy UDP manifest still goes out...
    assert_receive {:enqueued, _manifest}
    # ...but no bulk upload is triggered without a session id to route it.
    refute_receive {:bulk_upload, _opts}
  end

  test "recovers and durably admits an in-progress recording left by a power loss", %{base: base} do
    test_pid = self()
    # A recording written but never finalized (power loss mid-race).
    rec = Recording.open(base, %{recording_id: "2026-06-03-3", device_id: "dev"})
    Enum.reduce(1..2, rec, &Recording.append(&2, ds(&1)))

    # Booting the archive recovers it.
    start_archive(base, durable_opts(test_pid))

    assert_receive {:durable_enqueue, :race_recording_chunk, _chunk_bytes, _chunk_opts}
    assert_receive {:durable_enqueue, :race_recording_manifest, manifest_bytes, _manifest_opts}
    assert_receive {:enqueued, binary}
    manifest = DataSet.decode(binary).manifest
    assert manifest.race_recording_id == "2026-06-03-3"
    assert manifest.device_status == "recovered"
    assert RaceManifest.decode(manifest_bytes) == manifest
    assert {:ok, reloaded} = Recording.load(base, "2026-06-03-3")
    assert Recording.finalized?(reloaded)
  end

  test "retries durable admission for an already finalized recording after restart", %{base: base} do
    test_pid = self()

    {_recording, expected_manifest} =
      base
      |> Recording.open(%{recording_id: "2026-06-03-3", device_id: "dev"})
      |> Recording.append(ds(1))
      |> Recording.finalize(device_status: "recovered")

    start_archive(base, durable_opts(test_pid))

    assert_receive {:durable_enqueue, :race_recording_chunk, _chunk_bytes, _chunk_opts}
    assert_receive {:durable_enqueue, :race_recording_manifest, manifest_bytes, _manifest_opts}
    assert RaceManifest.decode(manifest_bytes) == expected_manifest
  end

  defp capture_entry_id(admit) do
    {:ok, entry_id} =
      admit.(fn _stream, _payload, entry_id: entry_id -> {:ok, entry_id} end)

    entry_id
  end
end
