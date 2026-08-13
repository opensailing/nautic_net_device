defmodule RacingOrg.Tracker.Pro.Race.Recording do
  @moduledoc """
  A durable, on-disk archive of a single race's sampled output stream.

  Each recording is a directory under the archive root, named for its
  `YYYY-MM-DD-N` recording id. Sampled `DataSet` binaries are appended as
  length-delimited records (`<<size::32, bytes>>`) into size-bounded chunk files.
  When a chunk fills (or the recording is finalized) it is sealed: any torn
  trailing record from a power loss is truncated, and a descriptor recording the
  byte count, SHA-256 checksum, and sample count is written to durable metadata.

  This makes the archive recoverable after reboot/power loss (re-open the
  directory, finalize the in-progress chunk), checksummed per chunk, and
  re-readable for re-uploading chunks the server reports missing.
  """

  require Logger

  alias RacingOrg.Tracker.Protobuf.ChunkDescriptor
  alias RacingOrg.Tracker.Protobuf.RaceManifest

  @meta_file "meta.bin"
  @manifest_file "manifest.pb"
  @default_chunk_max_bytes 256 * 1024

  @type t :: %__MODULE__{}

  defstruct [
    :dir,
    :recording_id,
    :device_id,
    :assignment_id,
    :assignment_version,
    :started_at,
    :course_hash,
    :route_hash,
    :chunk_max_bytes,
    current_chunk_index: 1,
    current_chunk_bytes: 0,
    sealed_chunks: []
  ]

  @doc """
  Create a new recording directory under `base_dir` and return the open recording.

  `attrs` must include `:recording_id`; optional `:device_id`, `:assignment_id`,
  `:assignment_version`, `:started_at` (DateTime), `:course_hash`, `:route_hash`,
  `:chunk_max_bytes`.
  """
  def open(base_dir, attrs) do
    recording_id = Map.fetch!(attrs, :recording_id)
    dir = Path.join(base_dir, recording_id)
    File.mkdir_p!(dir)

    recording = %__MODULE__{
      dir: dir,
      recording_id: recording_id,
      device_id: attrs[:device_id],
      assignment_id: attrs[:assignment_id],
      assignment_version: attrs[:assignment_version] || 0,
      started_at: attrs[:started_at] || DateTime.utc_now(),
      course_hash: attrs[:course_hash],
      route_hash: attrs[:route_hash],
      chunk_max_bytes: attrs[:chunk_max_bytes] || @default_chunk_max_bytes
    }

    persist_meta(recording)
    recording
  end

  @doc "Append one encoded `DataSet`, sealing + rolling the chunk when it fills."
  def append(%__MODULE__{} = recording, data_set_binary) when is_binary(data_set_binary) do
    record = <<byte_size(data_set_binary)::32, data_set_binary::binary>>
    File.write!(current_chunk_path(recording), record, [:append])
    recording = %{recording | current_chunk_bytes: recording.current_chunk_bytes + byte_size(record)}

    if recording.current_chunk_bytes >= recording.chunk_max_bytes do
      roll_chunk(recording)
    else
      recording
    end
  end

  @doc """
  Finalize the recording: seal the open chunk, write and return the
  `%RaceManifest{}`, and persist it to disk.
  """
  def finalize(%__MODULE__{} = recording, opts \\ []) do
    finished_at = opts[:finished_at] || DateTime.utc_now()
    device_status = opts[:device_status] || "complete"

    recording = seal_current_chunk(recording)
    persist_meta(recording)
    manifest = build_manifest(recording, finished_at, device_status)
    File.write!(Path.join(recording.dir, @manifest_file), RaceManifest.encode(manifest))
    {recording, manifest}
  end

  @doc "The current `%RaceManifest{}` for the recording (sealed chunks only)."
  def build_manifest(%__MODULE__{} = recording, finished_at \\ nil, device_status \\ "in_progress") do
    chunks = Enum.map(recording.sealed_chunks, &to_proto_chunk/1)

    struct(RaceManifest,
      race_recording_id: recording.recording_id,
      device_id: recording.device_id || "",
      assignment_id: recording.assignment_id || "",
      assignment_version: recording.assignment_version,
      started_at: proto_ts(recording.started_at),
      finished_at: proto_ts(finished_at),
      chunks: chunks,
      total_sample_count: Enum.sum(Enum.map(recording.sealed_chunks, & &1.sample_count)),
      course_hash: recording.course_hash || "",
      route_hash: recording.route_hash || "",
      device_status: device_status
    )
  end

  @doc "Re-open a recording from disk (for recovery or re-uploading chunks)."
  def load(base_dir, recording_id) do
    dir = Path.join(base_dir, recording_id)

    case File.read(Path.join(dir, @meta_file)) do
      {:ok, binary} ->
        recording = %{:erlang.binary_to_term(binary, [:safe]) | dir: dir}
        # Restore the in-progress chunk's size so resumed appends roll correctly.
        {:ok, %{recording | current_chunk_bytes: current_chunk_size(recording)}}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp current_chunk_size(recording) do
    case File.stat(current_chunk_path(recording)) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  @doc "Whether the recording has been finalized (its manifest written)."
  def finalized?(%__MODULE__{dir: dir}), do: File.exists?(Path.join(dir, @manifest_file))

  @doc "Return the exact sealed raw chunk bytes with their durable descriptors."
  def sealed_chunk_artifacts(%__MODULE__{} = recording) do
    Enum.reduce_while(recording.sealed_chunks, {:ok, []}, fn descriptor, {:ok, artifacts} ->
      case read_sealed_chunk(recording, descriptor) do
        {:ok, bytes} ->
          {:cont, {:ok, artifacts ++ [%{descriptor: descriptor, bytes: bytes}]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  @doc "Return the exact persisted `RaceManifest` protobuf bytes and decoded manifest."
  def manifest_artifact(%__MODULE__{dir: dir}) do
    case File.read(Path.join(dir, @manifest_file)) do
      {:ok, bytes} -> decode_manifest_artifact(bytes)
      error -> error
    end
  end

  @doc "Return the list of encoded `DataSet` records stored in a sealed chunk."
  def read_chunk(%__MODULE__{dir: dir}, chunk_id) do
    path = Path.join(dir, "chunk-#{chunk_id}")

    case File.read(path) do
      {:ok, bytes} -> {:ok, records(bytes, [])}
      error -> error
    end
  end

  @doc "Delete the recording directory."
  def delete(base_dir, recording_id) do
    File.rm_rf!(Path.join(base_dir, recording_id))
    :ok
  end

  @doc "All recording ids currently on disk under `base_dir`."
  def list(base_dir) do
    case File.ls(base_dir) do
      {:ok, entries} -> Enum.filter(entries, &File.dir?(Path.join(base_dir, &1)))
      {:error, _} -> []
    end
  end

  # --- internals ---

  defp read_sealed_chunk(%__MODULE__{dir: dir}, descriptor) do
    case File.read(Path.join(dir, "chunk-#{descriptor.chunk_id}")) do
      {:ok, bytes} ->
        if sealed_chunk_matches?(descriptor, bytes),
          do: {:ok, bytes},
          else: {:error, {:sealed_chunk_mismatch, descriptor.chunk_id}}

      {:error, reason} ->
        {:error, {:sealed_chunk_read_failed, descriptor.chunk_id, reason}}
    end
  end

  defp sealed_chunk_matches?(descriptor, bytes) do
    descriptor.byte_count == byte_size(bytes) and
      descriptor.checksum == sha256_hex(bytes) and
      descriptor.sample_count == length(records(bytes, []))
  end

  defp decode_manifest_artifact(bytes) do
    {:ok, %{manifest: RaceManifest.decode(bytes), bytes: bytes}}
  rescue
    _exception -> {:error, :invalid_manifest_artifact}
  catch
    _kind, _reason -> {:error, :invalid_manifest_artifact}
  end

  defp roll_chunk(recording) do
    recording
    |> seal_current_chunk()
    |> Map.update!(:current_chunk_index, &(&1 + 1))
    |> Map.put(:current_chunk_bytes, 0)
    |> tap(&persist_meta/1)
  end

  defp seal_current_chunk(recording) do
    path = current_chunk_path(recording)

    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) > 0 ->
        valid = valid_length(bytes, 0)
        valid_bytes = binary_part(bytes, 0, valid)
        if valid < byte_size(bytes), do: File.write!(path, valid_bytes)

        descriptor = %{
          chunk_id: chunk_id(recording.current_chunk_index),
          byte_count: byte_size(valid_bytes),
          checksum: sha256_hex(valid_bytes),
          sample_count: length(records(valid_bytes, []))
        }

        %{recording | sealed_chunks: recording.sealed_chunks ++ [descriptor]}

      _ ->
        recording
    end
  end

  defp persist_meta(recording) do
    meta = %{recording | dir: nil}
    path = Path.join(recording.dir, @meta_file)
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary(meta))
    File.rename!(tmp, path)
  end

  defp current_chunk_path(recording), do: Path.join(recording.dir, "chunk-#{chunk_id(recording.current_chunk_index)}")

  defp chunk_id(index), do: index |> Integer.to_string() |> String.pad_leading(4, "0")

  # Length, in bytes, of the leading complete length-delimited records (ignores a
  # torn trailing record from a power loss).
  defp valid_length(<<size::32, _body::binary-size(size), rest::binary>>, acc),
    do: valid_length(rest, acc + 4 + size)

  defp valid_length(_leftover, acc), do: acc

  defp records(<<size::32, body::binary-size(size), rest::binary>>, acc),
    do: records(rest, [body | acc])

  defp records(_leftover, acc), do: Enum.reverse(acc)

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp to_proto_chunk(%{chunk_id: id, byte_count: bc, checksum: cs, sample_count: sc}) do
    struct(ChunkDescriptor, chunk_id: id, byte_count: bc, checksum: cs, sample_count: sc)
  end

  defp proto_ts(nil), do: nil
  defp proto_ts(%DateTime{} = dt), do: RacingOrg.Tracker.Protobuf.to_proto_timestamp(dt)
end
