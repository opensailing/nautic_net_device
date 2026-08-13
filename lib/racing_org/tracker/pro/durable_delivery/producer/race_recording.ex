defmodule RacingOrg.Tracker.Pro.DurableDelivery.Producer.RaceRecording do
  @moduledoc """
  Pure durable-admission boundary for sealed race recording artifacts.

  Callers inject the durable enqueue function. This module does not read archive
  state or decide retention; it only validates stable source identity, freezes a
  deterministic outbox entry identity, and submits the exact artifact bytes.
  """

  alias RacingOrg.Tracker.Protobuf.RaceManifest

  @chunk_entry_id_domain "RacingOrg-RaceRecordingChunkEntryId-v1"
  @manifest_entry_id_domain "RacingOrg-RaceRecordingManifestEntryId-v1"
  @max_source_id_bytes 65_535

  @type enqueue ::
          (atom(), binary(), keyword() -> {:ok, term()} | {:error, term()})

  @doc """
  Durably admit one sealed chunk's raw on-disk bytes.

  The `(race_recording_id, chunk_id)` source identity deterministically selects
  the outbox entry id, so every retry reaches the same idempotency boundary.
  """
  @spec admit_chunk(enqueue(), binary(), binary(), binary()) ::
          {:ok, term()} | {:error, term()}
  def admit_chunk(enqueue, race_recording_id, chunk_id, chunk_bytes) do
    with :ok <- validate_enqueue(enqueue),
         :ok <- validate_race_recording_id(race_recording_id),
         :ok <- validate_chunk_id(chunk_id),
         :ok <- validate_chunk_bytes(chunk_bytes) do
      enqueue.(
        :race_recording_chunk,
        chunk_bytes,
        entry_id: chunk_entry_id(race_recording_id, chunk_id)
      )
    end
  end

  @doc """
  Encode and durably admit one exact `RaceManifest` protobuf.

  The supplied source identity must match the protobuf's `race_recording_id`.
  Encoding happens once at this boundary and those exact bytes are handed to the
  outbox under the recording's deterministic manifest entry id.
  """
  @spec admit_manifest(enqueue(), binary(), RaceManifest.t()) ::
          {:ok, term()} | {:error, term()}
  def admit_manifest(enqueue, race_recording_id, manifest) do
    with :ok <- validate_enqueue(enqueue),
         :ok <- validate_race_recording_id(race_recording_id),
         :ok <- validate_manifest(manifest),
         :ok <- validate_manifest_identity(race_recording_id, manifest),
         {:ok, manifest_bytes} <- encode_manifest(manifest) do
      enqueue.(
        :race_recording_manifest,
        manifest_bytes,
        entry_id: manifest_entry_id(race_recording_id)
      )
    end
  end

  @doc "Return the deterministic Outbox entry id for one recording chunk source identity."
  @spec chunk_entry_id(binary(), binary()) :: binary()
  def chunk_entry_id(race_recording_id, chunk_id) do
    :crypto.hash(
      :sha256,
      [@chunk_entry_id_domain, lp(race_recording_id), lp(chunk_id)]
    )
  end

  @doc "Return the deterministic Outbox entry id for one recording manifest source identity."
  @spec manifest_entry_id(binary()) :: binary()
  def manifest_entry_id(race_recording_id) do
    :crypto.hash(:sha256, [@manifest_entry_id_domain, lp(race_recording_id)])
  end

  defp lp(binary) do
    <<byte_size(binary)::unsigned-big-integer-size(32), binary::binary>>
  end

  defp validate_enqueue(enqueue) when is_function(enqueue, 3), do: :ok
  defp validate_enqueue(_enqueue), do: {:error, :invalid_enqueue}

  defp validate_race_recording_id(value)
       when is_binary(value) and byte_size(value) in 1..@max_source_id_bytes,
       do: :ok

  defp validate_race_recording_id(_value), do: {:error, :invalid_race_recording_id}

  defp validate_chunk_id(value)
       when is_binary(value) and byte_size(value) in 1..@max_source_id_bytes,
       do: :ok

  defp validate_chunk_id(_value), do: {:error, :invalid_chunk_id}

  defp validate_chunk_bytes(value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp validate_chunk_bytes(_value), do: {:error, :invalid_chunk_bytes}

  defp validate_manifest(%RaceManifest{race_recording_id: race_recording_id}) do
    case validate_race_recording_id(race_recording_id) do
      :ok -> :ok
      {:error, :invalid_race_recording_id} -> {:error, :invalid_manifest}
    end
  end

  defp validate_manifest(_manifest), do: {:error, :invalid_manifest}

  defp validate_manifest_identity(race_recording_id, %RaceManifest{
         race_recording_id: race_recording_id
       }),
       do: :ok

  defp validate_manifest_identity(_race_recording_id, %RaceManifest{}),
    do: {:error, :race_recording_id_mismatch}

  defp encode_manifest(manifest) do
    {:ok, RaceManifest.encode(manifest)}
  rescue
    _exception -> {:error, :invalid_manifest}
  catch
    _kind, _reason -> {:error, :invalid_manifest}
  end
end
