defmodule RacingOrg.Tracker.Pro.Polar.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the device's current REFERENCE
  polar (`RacingOrg.Tracker.Pro.Polar`) so a server-pushed polar survives reboots
  WITHOUT reflashing.

  Mirrors `RacingOrg.Tracker.Pro.Commands.Store`: the polar is written to a temp
  file and atomically renamed into place, so a crash mid-write can never leave a
  partially written current file. Loading a missing, unreadable, corrupt, or
  unknown-version file returns `:empty` rather than raising, so a bad on-disk
  polar can never take down the command pipeline (the device simply boots with no
  reference polar).
  """

  require Logger

  alias RacingOrg.Tracker.Pro.Polar

  @filename "reference.polar"
  # Bump if the persisted representation changes incompatibly; older/unknown
  # versions are ignored on load.
  @format_version 1

  @doc "Atomically persist `polar` under `dir`. Best-effort; never raises."
  @spec save(Path.t(), Polar.t()) :: :ok | {:error, term()}
  def save(dir, %Polar{} = polar) do
    File.mkdir_p!(dir)
    path = path(dir)
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary({@format_version, polar}))
    File.rename!(tmp, path)
    :ok
  rescue
    error ->
      Logger.warning("Failed to persist polar to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  @doc "Load the persisted polar from `dir`, or `:empty` if absent/unusable."
  @spec load(Path.t()) :: {:ok, Polar.t()} | :empty
  def load(dir) do
    case File.read(path(dir)) do
      {:ok, binary} -> decode(binary, dir)
      {:error, :enoent} -> :empty
      {:error, reason} -> warn_empty(dir, "could not read", reason)
    end
  end

  @doc "Remove any persisted polar under `dir`."
  @spec clear(Path.t()) :: :ok
  def clear(dir) do
    _ = File.rm(path(dir))
    :ok
  end

  defp decode(binary, dir) do
    case safe_binary_to_term(binary) do
      {@format_version, %Polar{} = polar} -> {:ok, polar}
      _other -> warn_empty(dir, "unrecognized/incompatible", :format)
    end
  rescue
    error -> warn_empty(dir, "corrupt", error)
  end

  defp safe_binary_to_term(binary), do: :erlang.binary_to_term(binary, [:safe])

  defp warn_empty(dir, what, detail) do
    Logger.warning("Ignoring #{what} persisted polar in #{inspect(dir)}: #{inspect(detail)}")
    :empty
  end

  defp path(dir), do: Path.join(dir, @filename)
end
