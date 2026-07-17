defmodule RacingOrg.Tracker.Pro.WindShift.Observer.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the wind-shift
  `RacingOrg.Tracker.Pro.WindShift.Observer`'s SESSION state — the sailing-day
  session identity (started_at_ms + running centroid/TWS sums), the upstream
  sync sequence, and the not-yet-synced timeline rows / events — so a mid-day
  reboot keeps the SAME session and sequence instead of starting a new one.

  Deliberately NOT persisted: the estimation cores (means / envelope / Kalman
  cycle / step detector). They are cheap to rebuild from live data and their
  freshness is part of the classifier's honesty contract (`history_s` restarts,
  so a rebooted device honestly reports `:insufficient_history` through its
  ~20 min warmup rather than resuming stale filter state).

  Mirrors `RacingOrg.Tracker.Pro.Calibration.Observer.Store`: the snapshot is
  written to a temp file and atomically renamed into place, so a crash
  mid-write can never leave a partially written file. Loading a missing,
  unreadable, corrupt, or unknown-version file returns `:empty` rather than
  raising — the Observer simply starts a fresh session.

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
        last_summary: map() | nil
      }
  """

  require Logger

  @filename "observer.wind_shift"
  # Bump if the persisted representation changes incompatibly; older/unknown
  # versions are ignored on load (the Observer starts a fresh session).
  @format_version 1

  @doc "Atomically persist the Observer `snapshot` under `dir`. Best-effort; never raises."
  @spec save(Path.t(), map()) :: :ok | {:error, term()}
  def save(dir, %{} = snapshot) do
    File.mkdir_p!(dir)
    path = path(dir)
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary({@format_version, snapshot}))
    File.rename!(tmp, path)
    :ok
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
end
