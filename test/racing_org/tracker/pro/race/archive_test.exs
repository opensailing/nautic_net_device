defmodule RacingOrg.Tracker.Pro.Race.ArchiveTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Protobuf.DataSet
  alias RacingOrg.Tracker.Protobuf.DeviceCommand
  alias RacingOrg.Tracker.Protobuf.ManifestVerificationResult
  alias RacingOrg.Tracker.Protobuf.MissingChunkRequest
  alias RacingOrg.Tracker.Protobuf.RaceAssignment
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

    archive =
      start_supervised!(
        {Archive,
         [
           base_dir: base,
           commands: commands,
           device_id: "dev",
           enqueue_fn: fn binary -> send(test_pid, {:enqueued, binary}) end,
           now_fn: fn -> ~U[2026-06-03 12:00:00Z] end,
           name: nil
         ] ++ opts}
      )

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

  test "opens a recording on race start and tracks the active recording id", %{base: base} do
    %{commands: c, archive: a} = start_archive(base)
    race(a, c, "2026-06-03-7", [1, 2])
    assert Archive.current_recording_id(a) == "2026-06-03-7"
  end

  test "finalizes at complete, uploads a manifest, and keeps the recording on disk", %{base: base} do
    %{commands: c, archive: a} = start_archive(base)
    race(a, c, "2026-06-03-7", [1, 2, 3])
    finish(a)

    assert_receive {:enqueued, binary}
    manifest = DataSet.decode(binary).manifest
    assert manifest.race_recording_id == "2026-06-03-7"
    assert manifest.total_sample_count == 3
    assert manifest.device_status == "complete"
    assert [_chunk] = manifest.chunks

    assert Archive.current_recording_id(a) == nil
    assert "2026-06-03-7" in Recording.list(base)
  end

  test "deletes the recording once RacingOrg confirms it complete", %{base: base} do
    %{commands: c, archive: a} = start_archive(base)
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
    # let the cast/info be processed
    _ = Archive.current_recording_id(a)
    refute "2026-06-03-7" in Recording.list(base)
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

  test "recovers and finalizes an in-progress recording left by a power loss", %{base: base} do
    # A recording written but never finalized (power loss mid-race).
    rec = Recording.open(base, %{recording_id: "2026-06-03-3", device_id: "dev"})
    Enum.reduce(1..2, rec, &Recording.append(&2, ds(&1)))

    # Booting the archive recovers it.
    start_archive(base)

    assert_receive {:enqueued, binary}
    manifest = DataSet.decode(binary).manifest
    assert manifest.race_recording_id == "2026-06-03-3"
    assert manifest.device_status == "recovered"
    assert {:ok, reloaded} = Recording.load(base, "2026-06-03-3")
    assert Recording.finalized?(reloaded)
  end
end
