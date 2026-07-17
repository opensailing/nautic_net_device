defmodule RacingOrg.Tracker.Pro.Calibration.Observer.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the auto-calibration
  `RacingOrg.Tracker.Pro.Calibration.Observer`'s accumulated state — the
  per-sensor estimator instances, the per-(sensor, parameter) previously-applied
  values the slew limiter continues from, and the upstream sync sequence — so a
  reboot RESUMES calibration learning instead of starting from zero (and a
  restored correction keeps CREEPING from where it left off, never jumping).

  Mirrors `RacingOrg.Tracker.Pro.Polar.Observer.Store`: the snapshot is written
  to a temp file and atomically renamed into place, so a crash mid-write can
  never leave a partially written file. Loading a missing, unreadable, corrupt,
  or unknown-version file returns `:empty` rather than raising, so a bad on-disk
  snapshot can never take down the Observer — it simply starts learning fresh.

  This is a SEPARATE file (`observer.calibration`) from
  `RacingOrg.Tracker.Pro.Calibration.Store`'s `current.calibration` (the
  server-pushed policy + learned entries owned by `Calibration.Config`); both
  live under the same `:calibration_directory` without clashing.

  ## Persisted shape

      %{
        awa_estimators: %{hex => %AwaOffset{}},
        stw_estimators: %{hex => %StwScale{}},
        aws_estimators: %{hex => %AwsScale{}},
        prev_applied: %{{hex, parameter} => float()},
        seq: non_neg_integer()
      }

  The estimator structs embed only `Estimate.Tracker`/`PSquare` structs and plain
  scalars, so the whole term is `term_to_binary`-safe and
  `binary_to_term(_, [:safe])`-decodable.
  """

  require Logger

  @filename "observer.calibration"
  # Bump if the persisted representation changes incompatibly; older/unknown
  # versions are ignored on load (the Observer restarts from empty).
  # v2: %AwaOffset{} gained the :bands field (TWS-banded upwash) — restoring a
  # v1 snapshot would resurrect band-less estimator structs that KeyError.
  @format_version 2

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
      Logger.warning("Failed to persist calibration observer state to #{inspect(dir)}: #{inspect(error)}")
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
    Logger.warning("Ignoring #{what} persisted calibration observer state in #{inspect(dir)}: #{inspect(detail)}")
    :empty
  end

  defp path(dir), do: Path.join(dir, @filename)
end
