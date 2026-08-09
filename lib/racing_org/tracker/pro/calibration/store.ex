defmodule RacingOrg.Tracker.Pro.Calibration.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the device's calibration state:
  the server-pushed `set_calibration` config (version, parameter modes, sensor
  locks) PLUS the learned per-sensor corrections, so both survive reboots WITHOUT
  reflashing.

  Mirrors `RacingOrg.Tracker.Pro.ClockSource.Store`: the state is written to a temp
  file and atomically renamed into place, so a crash mid-write can never leave a
  partially written current file. Loading a missing, unreadable, corrupt, or
  unknown-version file returns `:empty` rather than raising, so a bad on-disk
  state can never take down the calibration manager (it falls back to the safe
  defaults: no version applied, default modes, no locks, nothing learned).

  The persisted state is a plain map of the manager's durable fields:

      %{
        applied_version: integer() | nil,
        modes: %{String.t() => String.t()},
        locks: %{{hex :: String.t(), param :: String.t()} => %{locked: boolean(), value: number() | nil}},
        learned: %{hex :: String.t() => %{param :: String.t() => %{value: term(), confidence: number(),
                                                                    sample_count: non_neg_integer(), state: String.t()}}}
      }
  """

  require Logger

  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile

  @filename "current.calibration"
  # Bump if the persisted representation changes incompatibly; older/unknown
  # versions are ignored on load.
  @format_version 1

  @doc "Atomically persist the calibration `state` under `dir`. Best-effort; never raises."
  @spec save(Path.t(), map()) :: :ok | {:error, term()}
  def save(dir, %{} = state) do
    File.mkdir_p!(dir)
    path = path(dir)
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary({@format_version, state}))
    File.rename!(tmp, path)
    :ok
  rescue
    error ->
      Logger.warning("Failed to persist calibration state to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  @doc "Load the persisted calibration state from `dir`, or `:empty` if absent/unusable."
  @spec load(Path.t()) :: {:ok, map()} | :empty
  def load(dir) do
    case File.read(path(dir)) do
      {:ok, binary} -> decode(binary, dir)
      {:error, :enoent} -> :empty
      {:error, reason} -> warn_empty(dir, "could not read", reason)
    end
  end

  @doc "Durably remove any persisted calibration state under `dir`."
  @spec clear(Path.t(), keyword()) :: :ok | {:error, term()}
  def clear(dir, opts \\ []) do
    AtomicFile.remove(path(dir), Keyword.put_new(opts, :directory_root, dir))
  end

  defp decode(binary, dir) do
    case safe_binary_to_term(binary) do
      {@format_version, %{modes: _, locks: _, learned: _} = state} -> {:ok, state}
      _other -> warn_empty(dir, "unrecognized/incompatible", :format)
    end
  rescue
    error -> warn_empty(dir, "corrupt", error)
  end

  defp safe_binary_to_term(binary), do: :erlang.binary_to_term(binary, [:safe])

  defp warn_empty(dir, what, detail) do
    Logger.warning("Ignoring #{what} persisted calibration state in #{inspect(dir)}: #{inspect(detail)}")
    :empty
  end

  defp path(dir), do: Path.join(dir, @filename)
end
