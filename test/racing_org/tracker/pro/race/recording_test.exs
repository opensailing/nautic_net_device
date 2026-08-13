defmodule RacingOrg.Tracker.Pro.Race.RecordingTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Protobuf.DataSet
  alias RacingOrg.Tracker.Protobuf.RaceManifest
  alias RacingOrg.Tracker.Pro.Race.Recording

  setup do
    base = Path.join(System.tmp_dir!(), "nn_rec_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  defp ds(i), do: DataSet.encode(struct(DataSet, boat_identifier: "b", counter: i))

  defp open(base, opts \\ []) do
    attrs =
      Map.merge(
        %{
          recording_id: "2026-06-03-1",
          device_id: "dev",
          assignment_id: "a",
          assignment_version: 2,
          course_hash: "ch",
          route_hash: "rh"
        },
        Map.new(opts)
      )

    Recording.open(base, attrs)
  end

  defp append_all(rec, range), do: Enum.reduce(range, rec, &Recording.append(&2, ds(&1)))

  test "appends samples, finalizes, and produces a checksummed manifest", %{base: base} do
    {rec, manifest} = base |> open() |> append_all(1..5) |> Recording.finalize(device_status: "complete")

    assert %RaceManifest{race_recording_id: "2026-06-03-1", device_id: "dev", device_status: "complete"} = manifest
    assert [chunk] = manifest.chunks
    assert chunk.sample_count == 5
    assert chunk.byte_count > 0
    assert String.length(chunk.checksum) == 64
    assert manifest.total_sample_count == 5
    assert manifest.course_hash == "ch"
    assert Recording.finalized?(rec)
  end

  test "rolls to a new chunk when the size threshold is exceeded", %{base: base} do
    # Tiny threshold so each small sample rolls to a new chunk.
    {_rec, manifest} = base |> open(chunk_max_bytes: 1) |> append_all(1..5) |> Recording.finalize()
    assert length(manifest.chunks) >= 2
    assert manifest.total_sample_count == 5
  end

  test "read_chunk returns the stored DataSet binaries", %{base: base} do
    {rec, manifest} = base |> open() |> append_all(1..3) |> Recording.finalize()
    [chunk | _] = manifest.chunks

    assert {:ok, records} = Recording.read_chunk(rec, chunk.chunk_id)
    counters = Enum.map(records, &DataSet.decode(&1).counter)
    assert 1 in counters and 3 in counters
  end

  test "the chunk checksum matches the sha256 of the chunk bytes", %{base: base} do
    {rec, manifest} = base |> open() |> append_all(1..1) |> Recording.finalize()
    [chunk] = manifest.chunks
    bytes = File.read!(Path.join(rec.dir, "chunk-#{chunk.chunk_id}"))

    assert chunk.checksum == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert chunk.byte_count == byte_size(bytes)
  end

  test "exposes exact post-truncation sealed chunk and manifest artifacts", %{base: base} do
    encoded = ds(1)
    expected_chunk_bytes = <<byte_size(encoded)::32, encoded::binary>>
    rec = base |> open() |> Recording.append(encoded)

    # Simulate a power loss mid-write: a record header claiming 999 bytes with 3 present.
    File.write!(Path.join(rec.dir, "chunk-0001"), <<999::32, 1, 2, 3>>, [:append])

    {rec, manifest} = Recording.finalize(rec)
    assert [chunk] = manifest.chunks

    assert {:ok, [%{descriptor: descriptor, bytes: ^expected_chunk_bytes}]} =
             Recording.sealed_chunk_artifacts(rec)

    assert descriptor.chunk_id == chunk.chunk_id
    assert descriptor.byte_count == byte_size(expected_chunk_bytes)
    assert descriptor.checksum == chunk.checksum
    assert descriptor.sample_count == 1

    expected_manifest_bytes = RaceManifest.encode(manifest)

    assert {:ok, %{manifest: ^manifest, bytes: ^expected_manifest_bytes}} =
             Recording.manifest_artifact(rec)

    assert File.read!(Path.join(rec.dir, "manifest.pb")) == expected_manifest_bytes
    assert {:ok, [^encoded]} = Recording.read_chunk(rec, "0001")
  end

  test "refuses sealed artifacts whose bytes no longer match their descriptor", %{base: base} do
    {rec, _manifest} = base |> open() |> append_all(1..1) |> Recording.finalize()
    File.write!(Path.join(rec.dir, "chunk-0001"), "tampered", [:append])

    assert {:error, {:sealed_chunk_mismatch, "0001"}} = Recording.sealed_chunk_artifacts(rec)
  end

  test "load reconstructs a recording from disk and finalizes after reboot", %{base: base} do
    _rec = base |> open() |> append_all(1..3)

    assert {:ok, reloaded} = Recording.load(base, "2026-06-03-1")
    {_rec, manifest} = Recording.finalize(reloaded)
    assert manifest.total_sample_count == 3
  end

  test "load preserves finalized sealed descriptors for durable retry", %{base: base} do
    {rec, _manifest} = base |> open() |> append_all(1..3) |> Recording.finalize()
    assert {:ok, original_artifacts} = Recording.sealed_chunk_artifacts(rec)

    assert {:ok, reloaded} = Recording.load(base, "2026-06-03-1")
    assert Recording.finalized?(reloaded)
    assert {:ok, ^original_artifacts} = Recording.sealed_chunk_artifacts(reloaded)
  end

  test "delete removes the recording", %{base: base} do
    open(base)
    assert "2026-06-03-1" in Recording.list(base)
    assert :ok = Recording.delete(base, "2026-06-03-1")
    refute "2026-06-03-1" in Recording.list(base)
  end
end
