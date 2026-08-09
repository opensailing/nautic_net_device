defmodule RacingOrg.Tracker.Pro.WindShift.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the device's wind-shift
  config (the server-pushed `set_wind_shift` config) so a runtime change
  survives reboots WITHOUT reflashing.

  Mirrors `RacingOrg.Tracker.Pro.ClockSource.Store`: the state is written to a
  temp file and atomically renamed into place, so a crash mid-write can never
  leave a partially written current file. Loading a missing, unreadable,
  corrupt, or unknown-version file returns `:empty` rather than raising, so a
  bad on-disk state can never take down the wind-shift config manager (it falls
  back to the built-in defaults).

  Only the CONFIG is persisted here — the live predictor state belongs to
  `RacingOrg.Tracker.Pro.WindShift.Observer` (whose own `Observer.Store` file,
  `observer.wind_shift`, shares the directory without clashing).

  The persisted state is a plain map of the applied config:

      %{
        version: integer(),
        windows: %{fast_s: float(), mid_s: float(), slow_s: float(), envelope_s: float()},
        alarms: %{new_extreme_margin_deg: float(), enabled: boolean()},
        wally_mode: "off" | "shadow" | "on"
      }
  """

  require Logger

  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile

  @filename "current.wind_shift"
  # Bump if the persisted representation changes incompatibly; older/unknown
  # versions are ignored on load.
  @format_version 1

  @doc "Atomically persist the wind-shift `config` under `dir`. Best-effort; never raises."
  @spec save(Path.t(), map()) :: :ok | {:error, term()}
  def save(dir, %{} = config) do
    File.mkdir_p!(dir)
    path = path(dir)
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary({@format_version, config}))
    File.rename!(tmp, path)
    :ok
  rescue
    error ->
      Logger.warning("Failed to persist wind-shift config to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  @doc "Load the persisted wind-shift config from `dir`, or `:empty` if absent/unusable."
  @spec load(Path.t()) :: {:ok, map()} | :empty
  def load(dir) do
    case File.read(path(dir)) do
      {:ok, binary} -> decode(binary, dir)
      {:error, :enoent} -> :empty
      {:error, reason} -> warn_empty(dir, "could not read", reason)
    end
  end

  @doc "Durably remove any persisted wind-shift config under `dir`."
  @spec clear(Path.t(), keyword()) :: :ok | {:error, term()}
  def clear(dir, opts \\ []) do
    AtomicFile.remove(path(dir), Keyword.put_new(opts, :directory_root, dir))
  end

  defp decode(binary, dir) do
    case safe_binary_to_term(binary) do
      {@format_version, %{version: _, windows: _, alarms: _, wally_mode: _} = config} -> {:ok, config}
      _other -> warn_empty(dir, "unrecognized/incompatible", :format)
    end
  rescue
    error -> warn_empty(dir, "corrupt", error)
  end

  defp safe_binary_to_term(binary), do: :erlang.binary_to_term(binary, [:safe])

  defp warn_empty(dir, what, detail) do
    Logger.warning("Ignoring #{what} persisted wind-shift config in #{inspect(dir)}: #{inspect(detail)}")
    :empty
  end

  defp path(dir), do: Path.join(dir, @filename)
end
