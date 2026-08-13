defmodule RacingOrg.Tracker.Pro.Race.Retention do
  @moduledoc """
  Deterministic local retention for race recordings: keep only the most recent
  `keep` recordings (default 10) and delete the rest.

  Recordings are ordered by their `YYYY-MM-DD-N` id, treating `N` numerically so
  that `2026-06-03-10` sorts after `2026-06-03-2`.
  """

  alias RacingOrg.Tracker.Pro.DurableDelivery.Producer.RaceRecording, as: RaceRecordingProducer
  alias RacingOrg.Tracker.Pro.Race.Recording

  @default_keep 10
  @recording_streams [:race_recording_chunk, :race_recording_manifest]

  @doc """
  Prune recordings under `base_dir` to the most recent `keep`.

  When `:pending` is supplied it must return Outbox entries. Recordings with a
  pending chunk or manifest identity remain protected unless both an auditable
  `:loss_reason` and an `:authorize_loss` collaborator durably authorize every
  protected entry. Pending lookup errors fail closed. Returns the deleted ids.
  """
  def prune(base_dir, keep \\ @default_keep, opts \\ []) do
    {_kept, dropped} =
      base_dir
      |> Recording.list()
      |> Enum.sort_by(&sort_key/1, :desc)
      |> Enum.split(keep)

    case protected_pending_entries(base_dir, dropped, opts) do
      {:ok, protected} -> prune_eligible(base_dir, dropped, protected, opts)
      {:error, _reason} -> []
    end
  end

  defp protected_pending_entries(_base_dir, [], _opts), do: {:ok, %{}}

  defp protected_pending_entries(base_dir, recording_ids, opts) do
    case Keyword.fetch(opts, :pending) do
      {:ok, pending} when is_function(pending, 0) ->
        case pending.() do
          entries when is_list(entries) -> {:ok, index_pending(entries, base_dir, recording_ids)}
          {:error, reason} -> {:error, reason}
          _other -> {:error, :invalid_pending_result}
        end

      :error ->
        {:error, :pending_unconfigured}

      {:ok, _invalid} ->
        {:error, :invalid_pending}
    end
  rescue
    _exception -> {:error, :pending_failed}
  catch
    _kind, _reason -> {:error, :pending_failed}
  end

  defp index_pending(entries, base_dir, recording_ids) do
    identities =
      Map.new(recording_ids, fn recording_id ->
        {recording_id, expected_entry_ids(base_dir, recording_id)}
      end)

    Enum.reduce(entries, %{}, fn entry, protected ->
      case pending_recording_id(entry, identities) do
        nil -> protected
        recording_id -> Map.update(protected, recording_id, [entry], &[entry | &1])
      end
    end)
  end

  defp expected_entry_ids(base_dir, recording_id) do
    chunk_ids =
      case Recording.load(base_dir, recording_id) do
        {:ok, recording} -> Enum.map(recording.sealed_chunks, & &1.chunk_id)
        :error -> []
      end

    manifest = RaceRecordingProducer.manifest_entry_id(recording_id)
    chunks = Enum.map(chunk_ids, &RaceRecordingProducer.chunk_entry_id(recording_id, &1))
    MapSet.new([manifest | chunks])
  end

  defp pending_recording_id(%{stream: stream, entry_id: entry_id}, identities)
       when stream in @recording_streams and is_binary(entry_id) do
    Enum.find_value(identities, fn {recording_id, entry_ids} ->
      if MapSet.member?(entry_ids, entry_id), do: recording_id
    end)
  end

  defp pending_recording_id(_entry, _identities), do: nil

  defp prune_eligible(base_dir, dropped, protected, opts) do
    Enum.reduce(dropped, [], fn id, deleted ->
      case Map.get(protected, id, []) do
        [] ->
          :ok = Recording.delete(base_dir, id)
          deleted ++ [id]

        entries ->
          case authorize_pending_loss(entries, opts) do
            :ok ->
              :ok = Recording.delete(base_dir, id)
              deleted ++ [id]

            {:error, _reason} ->
              deleted
          end
      end
    end)
  end

  defp authorize_pending_loss(entries, opts) do
    with reason when is_binary(reason) and reason != "" <- Keyword.get(opts, :loss_reason),
         authorize when is_function(authorize, 2) <- Keyword.get(opts, :authorize_loss),
         :ok <- authorize.(entries, reason) do
      :ok
    else
      _other -> {:error, :loss_not_authorized}
    end
  end

  # Sort most-recent first by (date, race number). Malformed ids sort oldest so
  # they are the first to be pruned.
  defp sort_key(id) do
    case String.split(id, "-") do
      [year, month, day, n] ->
        {year, month, day, String.to_integer(n)}

      _ ->
        {"", "", "", 0}
    end
  rescue
    ArgumentError -> {"", "", "", 0}
  end
end
