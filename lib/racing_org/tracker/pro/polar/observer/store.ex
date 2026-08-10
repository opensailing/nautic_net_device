defmodule RacingOrg.Tracker.Pro.Polar.Observer.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the device's SECONDARY
  observational ("sailed") polar so the cells the boat has actually sailed survive
  reboots WITHOUT re-accumulation from zero.

  Mirrors `RacingOrg.Tracker.Pro.Polar.Store` (and, transitively,
  `RacingOrg.Tracker.Pro.Commands.Store`): state is written to a temp file and
  atomically renamed into place, so a crash mid-write can never leave a partially
  written file. The historical cell-only loader maps missing, unreadable,
  corrupt, or unknown-version files to `:empty`; the runtime loader distinguishes
  invalid content as `:invalid` so the Observer can durably scrub it.

  Runtime format 2 binds the learned cells to their boat authority, complete
  admission-policy hash, global probability, exact grid geometry, monotonic
  learner revision, and last accepted restore fingerprint. The legacy format-1
  cell-only reader remains for in-place upgrade; the Observer semantically
  validates and rewrites it under the complete binding before use.
  """

  require Logger

  alias RacingOrg.Tracker.Pro.Polar.Observer.Bins
  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare

  @filename "sailed.polar"
  @legacy_format_version 1
  @runtime_format_version 2
  @database_int_max 9_223_372_036_854_775_807

  @type key :: {non_neg_integer(), non_neg_integer()}
  @type cells :: %{optional(key()) => {non_neg_integer(), PSquare.t()}}

  @type runtime :: %{
          required(:authority) => String.t(),
          required(:policy_hash) => <<_::256>>,
          required(:source_generation) => non_neg_integer(),
          required(:last_restore_fingerprint) => <<_::256>> | nil,
          required(:p) => float(),
          required(:bins) => Bins.t(),
          required(:cells) => cells()
        }

  @doc "Atomically persist legacy cell-only state. Used for format-1 compatibility fixtures."
  @spec save(Path.t(), cells()) :: :ok | {:error, term()}
  def save(dir, cells) when is_map(cells),
    do: write(dir, {@legacy_format_version, cells})

  @doc "Atomically persist the fully bound Observer runtime state."
  @spec save_runtime(Path.t(), runtime()) :: :ok | {:error, term()}
  def save_runtime(dir, %{
        authority: authority,
        policy_hash: policy_hash,
        source_generation: source_generation,
        last_restore_fingerprint: fingerprint,
        p: p,
        bins: %Bins{} = bins,
        cells: cells
      })
      when is_binary(authority) and byte_size(authority) > 0 and is_binary(policy_hash) and
             byte_size(policy_hash) == 32 and is_integer(source_generation) and
             source_generation >= 0 and source_generation <= @database_int_max and
             (is_nil(fingerprint) or (is_binary(fingerprint) and byte_size(fingerprint) == 32)) and
             is_float(p) and is_map(cells) do
    write(
      dir,
      {@runtime_format_version, authority, policy_hash, source_generation, fingerprint, p, bins, cells}
    )
  end

  def save_runtime(_dir, _runtime), do: {:error, :invalid_runtime}

  @doc "Load persisted cells alone, preserving the historical Store API."
  @spec load(Path.t()) :: {:ok, cells()} | :empty
  def load(dir) do
    case load_runtime(dir) do
      {:ok, %{cells: cells}} -> {:ok, cells}
      result when result in [:empty, :invalid] -> :empty
    end
  end

  @doc "Load the fully bound runtime, or a marked legacy runtime requiring rewrite."
  @spec load_runtime(Path.t()) :: {:ok, runtime() | map()} | :empty | :invalid
  def load_runtime(dir) do
    case File.read(path(dir)) do
      {:ok, binary} -> decode(binary, dir)
      {:error, reason} when reason in [:enoent, :enotdir] -> :empty
      {:error, reason} -> warn_invalid(dir, "could not read", reason)
    end
  end

  @doc "Remove any persisted sailed polar under `dir`."
  @spec clear(Path.t()) :: :ok
  def clear(dir) do
    _ = File.rm(path(dir))
    :ok
  end

  defp write(dir, term) do
    File.mkdir_p!(dir)
    path = path(dir)
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary(term))
    File.rename!(tmp, path)
    :ok
  rescue
    error ->
      Logger.warning("Failed to persist sailed polar to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  defp decode(binary, dir) do
    case safe_binary_to_term(binary) do
      {@runtime_format_version, authority, policy_hash, source_generation, fingerprint, p, %Bins{} = bins, cells}
      when is_binary(authority) and byte_size(authority) > 0 and is_binary(policy_hash) and
             byte_size(policy_hash) == 32 and is_integer(source_generation) and
             source_generation >= 0 and source_generation <= @database_int_max and
             (is_nil(fingerprint) or
                (is_binary(fingerprint) and byte_size(fingerprint) == 32)) and is_float(p) and
             is_map(cells) ->
        {:ok,
         %{
           authority: authority,
           policy_hash: policy_hash,
           source_generation: source_generation,
           last_restore_fingerprint: fingerprint,
           p: p,
           bins: bins,
           cells: cells
         }}

      {@legacy_format_version, cells} when is_map(cells) ->
        {:ok,
         %{
           authority: nil,
           policy_hash: nil,
           source_generation: legacy_generation(cells),
           last_restore_fingerprint: nil,
           p: nil,
           bins: nil,
           cells: cells,
           legacy?: true
         }}

      _other ->
        warn_invalid(dir, "unrecognized/incompatible", :format)
    end
  rescue
    error -> warn_invalid(dir, "corrupt", error)
  end

  defp legacy_generation(cells) do
    Enum.reduce_while(cells, 0, fn
      {_key, {count, _quantile}}, total
      when is_integer(count) and count > 0 and total <= @database_int_max - count ->
        {:cont, total + count}

      _cell, _total ->
        {:halt, 0}
    end)
  end

  defp safe_binary_to_term(binary), do: :erlang.binary_to_term(binary, [:safe])

  defp warn_invalid(dir, what, detail) do
    Logger.warning("Ignoring #{what} persisted sailed polar in #{inspect(dir)}: #{inspect(detail)}")
    :invalid
  end

  defp path(dir), do: Path.join(dir, @filename)
end
