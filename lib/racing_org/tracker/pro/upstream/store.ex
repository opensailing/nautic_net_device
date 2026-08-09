defmodule RacingOrg.Tracker.Pro.Upstream.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the device's upstream signal
  selection (the server-pushed `set_upstream` config) so a runtime change survives
  reboots WITHOUT reflashing.

  Mirrors `RacingOrg.Tracker.Pro.Tracking.Store`: the state is written to a temp
  file and atomically renamed into place, so a crash mid-write can never leave a
  partially written current file. Loading a missing, unreadable, corrupt, or
  unknown-version file returns `:empty` rather than raising, so a bad on-disk state
  can never take down the upstream-config manager (it falls back to the all-on
  default — never dropping telemetry because persistence is broken).

  The persisted state is a plain map of the full signal selection + applied version:

      %{
        version: integer(),
        signals: %{
          heading: boolean(), speed: boolean(), velocity: boolean(),
          wind: boolean(), water_depth: boolean(), attitude: boolean()
        }
      }
  """

  require Logger

  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile

  @type config :: %{version: integer(), signals: %{atom() => boolean()}}

  @filename "current.upstream"
  # Bump if the persisted representation changes incompatibly; older/unknown
  # versions are ignored on load.
  @format_version 1

  @doc "Atomically persist the upstream `config` under `dir`. Best-effort; never raises."
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
      Logger.warning("Failed to persist upstream config to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  @doc "Load the persisted upstream config from `dir`, or `:empty` if absent/unusable."
  @spec load(Path.t()) :: {:ok, config()} | :empty
  def load(dir) do
    case File.read(path(dir)) do
      {:ok, binary} ->
        case safe_binary_to_term(binary) do
          {:ok, {@format_version, %{version: version, signals: %{} = signals} = config}}
          when is_integer(version) and map_size(signals) > 0 ->
            {:ok, config}

          _other ->
            :empty
        end

      {:error, _reason} ->
        :empty
    end
  end

  @doc "Durably remove the persisted upstream config."
  @spec clear(Path.t(), keyword()) :: :ok | {:error, term()}
  def clear(dir, opts \\ []) do
    AtomicFile.remove(path(dir), Keyword.put_new(opts, :directory_root, dir))
  end

  defp path(dir), do: Path.join(dir, @filename)

  defp safe_binary_to_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    _error -> :error
  end
end
