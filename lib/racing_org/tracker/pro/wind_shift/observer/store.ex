defmodule RacingOrg.Tracker.Pro.WindShift.Observer.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the wind-shift
  `RacingOrg.Tracker.Pro.WindShift.Observer`'s SESSION state — the sailing-day
  session identity (started_at_ms + running centroid/TWS sums), the upstream
  sync sequence, and the not-yet-synced timeline rows / events — so a mid-day
  reboot keeps the SAME session and sequence instead of starting a new one.

  The ordinary session snapshot deliberately excludes the estimation cores
  (means / envelope / Kalman cycle / step detector). After an authoritative
  runtime restore, however, the complete closed learner snapshot, its accepted
  SHA-256 fingerprint, and its UTC capture time are stored in this SAME record.
  One durable atomic replacement therefore cannot expose a new duplicate marker
  with old learner bytes after power loss. Historical split-fingerprint sidecars
  are ignored; `clear/1` removes any orphan left by an older release.

  Writes use `DesiredState.AtomicFile`, including file and parent-directory sync,
  so `:ok` means the complete replacement is durably committed. Loading a
  missing, unreadable, corrupt, or unknown-version file returns `:empty` rather
  than raising — the Observer simply starts a fresh session.

  This is a SEPARATE file (`observer.wind_shift`) from
  `RacingOrg.Tracker.Pro.WindShift.Store`'s `current.wind_shift` (the
  server-pushed policy owned by `WindShift.Config`); both live under the same
  `:wind_shift_directory` without clashing.

  ## Persisted shape

      %{
        session: %{started_at_ms: integer(), lat_sum: float(), lon_sum: float(),
                   pos_n: non_neg_integer(), tws_sum: float(), tws_n: non_neg_integer()} | nil,
        seq: non_neg_integer(),
        pending_timeline: [map()],
        pending_events: [map()],
        last_summary: map() | nil,
        optional(:authoritative_runtime) => %{
          captured_at_utc_ms: integer(),
          fingerprint: <<_::256>>,
          snapshot: map()
        }
      }
  """

  require Logger

  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile

  @filename "observer.wind_shift"
  @authoritative_filename "observer.wind_shift.authoritative"
  # Bump if the persisted representation changes incompatibly; older/unknown
  # versions are ignored on load (the Observer starts a fresh session).
  @format_version 1

  @doc "Durably atomically persist the complete Observer record under `dir`. Never raises."
  @spec save(Path.t(), map(), keyword()) :: :ok | {:error, term()}
  def save(dir, snapshot, opts \\ [])

  def save(dir, %{} = snapshot, opts) do
    atomic_opts = Keyword.put_new(opts, :directory_root, dir)

    case AtomicFile.write(path(dir), :erlang.term_to_binary({@format_version, snapshot}), atomic_opts) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to persist wind-shift observer state to #{inspect(dir)}: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning("Failed to persist wind-shift observer state to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  @doc "Load the persisted snapshot from `dir`, or `:empty` if absent/unusable."
  @spec load(Path.t()) :: {:ok, map()} | :empty
  def load(dir) do
    case File.read(path(dir)) do
      {:ok, binary} -> decode(binary, dir)
      {:error, :enoent} -> :empty
      {:error, reason} -> warn_empty(dir, "could not read", reason)
    end
  end

  @doc "Remove any persisted snapshot under `dir`."
  @spec clear(Path.t()) :: :ok
  def clear(dir) do
    _ = File.rm(path(dir))
    _ = File.rm(authoritative_path(dir))
    :ok
  end

  defp decode(binary, dir) do
    case safe_binary_to_term(binary) do
      {@format_version, %{} = snapshot} -> {:ok, snapshot}
      _other -> warn_empty(dir, "unrecognized/incompatible", :format)
    end
  rescue
    error -> warn_empty(dir, "corrupt", error)
  end

  defp safe_binary_to_term(binary), do: :erlang.binary_to_term(binary, [:safe])

  defp warn_empty(dir, what, detail) do
    Logger.warning("Ignoring #{what} persisted wind-shift observer state in #{inspect(dir)}: #{inspect(detail)}")
    :empty
  end

  defp path(dir), do: Path.join(dir, @filename)
  defp authoritative_path(dir), do: Path.join(dir, @authoritative_filename)
end
