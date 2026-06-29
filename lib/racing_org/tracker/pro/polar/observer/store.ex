defmodule RacingOrg.Tracker.Pro.Polar.Observer.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the device's SECONDARY
  observational ("sailed") polar so the cells the boat has actually sailed survive
  reboots WITHOUT re-accumulation from zero.

  Mirrors `RacingOrg.Tracker.Pro.Polar.Store` (and, transitively,
  `RacingOrg.Tracker.Pro.Commands.Store`): the cell map is written to a temp file
  and atomically renamed into place, so a crash mid-write can never leave a
  partially written file. Loading a missing, unreadable, corrupt, or
  unknown-version file returns `:empty` rather than raising, so a bad on-disk
  sailed polar can never take down the `Observer` — it simply starts accumulating
  from empty.

  This is a SEPARATE file (`sailed.polar`) from the reference polar
  (`reference.polar`): the two never share state, and persisting/restoring the
  sailed polar never touches the server-pushed reference polar.

  ## Persisted shape

  A map keyed by `Bins` cell key, each value a `{count, PSquare.t()}` tuple. The
  `PSquare` struct holds only plain floats / ints / tuples, so the whole term is
  `term_to_binary`-safe and `binary_to_term(_, [:safe])`-decodable.
  """

  require Logger

  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare

  @filename "sailed.polar"
  # Bump if the persisted representation changes incompatibly; older/unknown
  # versions are ignored on load (the Observer restarts from empty).
  @format_version 1

  @type key :: {non_neg_integer(), non_neg_integer()}
  @type cells :: %{optional(key()) => {non_neg_integer(), PSquare.t()}}

  @doc "Atomically persist the sailed `cells` map under `dir`. Best-effort; never raises."
  @spec save(Path.t(), cells()) :: :ok | {:error, term()}
  def save(dir, cells) when is_map(cells) do
    File.mkdir_p!(dir)
    path = path(dir)
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary({@format_version, cells}))
    File.rename!(tmp, path)
    :ok
  rescue
    error ->
      Logger.warning("Failed to persist sailed polar to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  @doc "Load the persisted sailed cells from `dir`, or `:empty` if absent/unusable."
  @spec load(Path.t()) :: {:ok, cells()} | :empty
  def load(dir) do
    case File.read(path(dir)) do
      {:ok, binary} -> decode(binary, dir)
      {:error, :enoent} -> :empty
      {:error, reason} -> warn_empty(dir, "could not read", reason)
    end
  end

  @doc "Remove any persisted sailed polar under `dir`."
  @spec clear(Path.t()) :: :ok
  def clear(dir) do
    _ = File.rm(path(dir))
    :ok
  end

  defp decode(binary, dir) do
    case safe_binary_to_term(binary) do
      {@format_version, cells} when is_map(cells) -> {:ok, cells}
      _other -> warn_empty(dir, "unrecognized/incompatible", :format)
    end
  rescue
    error -> warn_empty(dir, "corrupt", error)
  end

  defp safe_binary_to_term(binary), do: :erlang.binary_to_term(binary, [:safe])

  defp warn_empty(dir, what, detail) do
    Logger.warning("Ignoring #{what} persisted sailed polar in #{inspect(dir)}: #{inspect(detail)}")
    :empty
  end

  defp path(dir), do: Path.join(dir, @filename)
end
