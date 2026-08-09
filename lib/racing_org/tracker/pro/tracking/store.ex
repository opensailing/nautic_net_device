defmodule RacingOrg.Tracker.Pro.Tracking.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the device's per-tracking-state
  damping + send-rate config (the server-pushed `set_tracking` config) so a runtime
  change survives reboots WITHOUT reflashing.

  Mirrors `RacingOrg.Tracker.Pro.WiFi.Store` / `RacingOrg.Tracker.Pro.Commands.Store`: the state is written
  to a temp file and atomically renamed into place, so a crash mid-write can never
  leave a partially written current file. Loading a missing, unreadable, corrupt, or
  unknown-version file returns `:empty` rather than raising, so a bad on-disk state
  can never take down the tracking-config manager (it falls back to safe defaults).

  The persisted state is a plain map of the full 3-state config + applied version:

      %{
        version: integer(),
        states: %{
          pre_race: %{damping_seconds: float(), send_rate_hz: float()},
          starting: %{damping_seconds: float(), send_rate_hz: float()},
          race:     %{damping_seconds: float(), send_rate_hz: float()}
        }
      }
  """

  require Logger

  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile

  @type state_config :: %{damping_seconds: float(), send_rate_hz: float()}
  @type config :: %{version: integer(), states: %{atom() => state_config()}}

  @filename "current.tracking"
  # Bump if the persisted representation changes incompatibly; older/unknown
  # versions are ignored on load.
  @format_version 1

  @doc "Atomically persist the tracking `config` under `dir`. Best-effort; never raises."
  @spec save(Path.t(), config()) :: :ok | {:error, term()}
  def save(dir, %{} = config) do
    File.mkdir_p!(dir)
    path = path(dir)
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary({@format_version, config}))
    File.rename!(tmp, path)
    :ok
  rescue
    error ->
      Logger.warning("Failed to persist tracking config to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  @doc "Load the persisted tracking config from `dir`, or `:empty` if absent/unusable."
  @spec load(Path.t()) :: {:ok, config()} | :empty
  def load(dir) do
    case File.read(path(dir)) do
      {:ok, binary} -> decode(binary, dir)
      {:error, :enoent} -> :empty
      {:error, reason} -> warn_empty(dir, "could not read", reason)
    end
  end

  @doc "Durably remove any persisted tracking config under `dir`."
  @spec clear(Path.t(), keyword()) :: :ok | {:error, term()}
  def clear(dir, opts \\ []) do
    AtomicFile.remove(path(dir), Keyword.put_new(opts, :directory_root, dir))
  end

  defp decode(binary, dir) do
    case safe_binary_to_term(binary) do
      {@format_version, %{version: _, states: %{}} = config} -> {:ok, config}
      _other -> warn_empty(dir, "unrecognized/incompatible", :format)
    end
  rescue
    error -> warn_empty(dir, "corrupt", error)
  end

  defp safe_binary_to_term(binary), do: :erlang.binary_to_term(binary, [:safe])

  defp warn_empty(dir, what, detail) do
    Logger.warning("Ignoring #{what} persisted tracking config in #{inspect(dir)}: #{inspect(detail)}")
    :empty
  end

  defp path(dir), do: Path.join(dir, @filename)
end
