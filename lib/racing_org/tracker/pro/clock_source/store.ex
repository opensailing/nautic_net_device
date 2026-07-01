defmodule RacingOrg.Tracker.Pro.ClockSource.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the device's clock-source
  config (the server-pushed `set_clock_source` config) so a runtime change
  survives reboots WITHOUT reflashing.

  Mirrors `RacingOrg.Tracker.Pro.Tracking.Store`: the state is written to a temp
  file and atomically renamed into place, so a crash mid-write can never leave a
  partially written current file. Loading a missing, unreadable, corrupt, or
  unknown-version file returns `:empty` rather than raising, so a bad on-disk
  state can never take down the clock-source manager (it falls back to the safe
  default of `tracker_receive_time`).

  Only the CONFIG is persisted — the live boat-time timebase (derived from GPS
  observations at runtime) is intentionally NOT persisted; it is rebuilt from
  live time messages after boot.

  The persisted state is a plain map of the applied config:

      %{
        version: integer(),
        mode: :tracker_receive_time | :sensor_priority,
        fallback: :tracker_receive_time,
        sources: [%{priority: integer(), sensor_id: String.t() | nil, ...}]
      }
  """

  require Logger

  @filename "current.clock_source"
  # Bump if the persisted representation changes incompatibly; older/unknown
  # versions are ignored on load.
  @format_version 1

  @doc "Atomically persist the clock-source `config` under `dir`. Best-effort; never raises."
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
      Logger.warning("Failed to persist clock-source config to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  @doc "Load the persisted clock-source config from `dir`, or `:empty` if absent/unusable."
  @spec load(Path.t()) :: {:ok, map()} | :empty
  def load(dir) do
    case File.read(path(dir)) do
      {:ok, binary} -> decode(binary, dir)
      {:error, :enoent} -> :empty
      {:error, reason} -> warn_empty(dir, "could not read", reason)
    end
  end

  @doc "Remove any persisted clock-source config under `dir`."
  @spec clear(Path.t()) :: :ok
  def clear(dir) do
    _ = File.rm(path(dir))
    :ok
  end

  defp decode(binary, dir) do
    case safe_binary_to_term(binary) do
      {@format_version, %{version: _, mode: _, sources: _} = config} -> {:ok, config}
      _other -> warn_empty(dir, "unrecognized/incompatible", :format)
    end
  rescue
    error -> warn_empty(dir, "corrupt", error)
  end

  defp safe_binary_to_term(binary), do: :erlang.binary_to_term(binary, [:safe])

  defp warn_empty(dir, what, detail) do
    Logger.warning("Ignoring #{what} persisted clock-source config in #{inspect(dir)}: #{inspect(detail)}")
    :empty
  end

  defp path(dir), do: Path.join(dir, @filename)
end
