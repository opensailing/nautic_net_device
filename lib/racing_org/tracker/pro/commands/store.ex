defmodule RacingOrg.Tracker.Pro.Commands.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the active
  `RacingOrg.Tracker.Pro.Commands.Assignment` so it survives reboots.

  The assignment is written to a temp file and atomically renamed into place, so
  a crash mid-write can never leave a partially-written current file. Loading a
  missing, unreadable, corrupt, or unknown-version file returns `:empty` rather
  than raising, so a bad on-disk state can never take down the command pipeline.
  """

  require Logger

  alias RacingOrg.Tracker.Pro.Commands.Assignment

  @filename "current.assignment"
  # Bump if the persisted representation changes incompatibly; older/unknown
  # versions are ignored on load.
  @format_version 1

  @doc "Atomically persist `assignment` under `dir`. Best-effort; never raises."
  def save(dir, %Assignment{} = assignment) do
    File.mkdir_p!(dir)
    path = path(dir)
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary({@format_version, assignment}))
    File.rename!(tmp, path)
    :ok
  rescue
    error ->
      Logger.warning("Failed to persist assignment to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  @doc "Load the persisted assignment from `dir`, or `:empty` if absent/unusable."
  def load(dir) do
    case File.read(path(dir)) do
      {:ok, binary} -> decode(binary, dir)
      {:error, :enoent} -> :empty
      {:error, reason} -> warn_empty(dir, "could not read", reason)
    end
  end

  @doc "Remove any persisted assignment under `dir`."
  def clear(dir) do
    case File.rm(path(dir)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(binary, dir) do
    case safe_binary_to_term(binary) do
      {@format_version, %Assignment{} = assignment} -> {:ok, assignment}
      _other -> warn_empty(dir, "unrecognized/incompatible", :format)
    end
  rescue
    error -> warn_empty(dir, "corrupt", error)
  end

  defp safe_binary_to_term(binary), do: :erlang.binary_to_term(binary, [:safe])

  defp warn_empty(dir, what, detail) do
    Logger.warning("Ignoring #{what} persisted assignment in #{inspect(dir)}: #{inspect(detail)}")
    :empty
  end

  defp path(dir), do: Path.join(dir, @filename)
end
