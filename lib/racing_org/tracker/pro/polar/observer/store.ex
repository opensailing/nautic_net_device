defmodule RacingOrg.Tracker.Pro.Polar.Observer.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the device's SECONDARY
  observational ("sailed") polar so the cells the boat has actually sailed survive
  reboots WITHOUT re-accumulation from zero.

  Writes use `DesiredState.AtomicFile`, including file and parent-directory sync,
  so `:ok` means the replacement is durably committed. The historical cell-only
  loader maps missing, unreadable, corrupt, or unknown-version files to `:empty`;
  the runtime loader distinguishes invalid content as `:invalid` so the Observer
  can durably scrub it.

  Runtime format 3 binds the learned cells to their boat authority, complete
  admission-policy hash, global probability, exact grid geometry, monotonic
  learner revision, durable upstream sequence, and last accepted restore
  fingerprint. The legacy format-1 cell-only reader remains for in-place upgrade;
  the Observer semantically validates and rewrites it under the complete binding
  before use. Runtime format 2 is read once with sequence zero and marked for an
  immediate format-3 rewrite.
  """

  require Logger

  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile
  alias RacingOrg.Tracker.Pro.Polar.Observer.Bins
  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare
  alias RacingOrg.Tracker.Pro.Polar.Observer.Snapshot

  @filename "sailed.polar"
  @legacy_format_version 1
  @previous_runtime_format_version 2
  @runtime_format_version 3
  @database_int_max 9_223_372_036_854_775_807
  @max_finite 1.7976931348623157e308

  @type key :: {non_neg_integer(), non_neg_integer()}
  @type cells :: %{optional(key()) => {non_neg_integer(), PSquare.t()}}

  @type runtime :: %{
          required(:authority) => String.t(),
          required(:policy_hash) => <<_::256>>,
          required(:source_generation) => non_neg_integer(),
          required(:seq) => non_neg_integer(),
          required(:last_restore_fingerprint) => <<_::256>> | nil,
          required(:p) => float(),
          required(:bins) => Bins.t(),
          required(:cells) => cells()
        }

  @doc "Atomically persist legacy cell-only state. Used for format-1 compatibility fixtures."
  @spec save(Path.t(), cells()) :: :ok | {:error, term()}
  def save(dir, cells) when is_map(cells),
    do: write(dir, {@legacy_format_version, cells}, [])

  @doc "Atomically persist the fully bound Observer runtime state."
  @spec save_runtime(Path.t(), runtime(), keyword()) :: :ok | {:error, term()}
  def save_runtime(dir, runtime, opts \\ [])

  def save_runtime(
        dir,
        %{
          authority: authority,
          policy_hash: policy_hash,
          source_generation: source_generation,
          seq: seq,
          last_restore_fingerprint: fingerprint,
          p: p,
          bins: %Bins{} = bins,
          cells: cells
        },
        opts
      ) do
    with :ok <- Snapshot.validate_authority(authority),
         true <- fixed_hash?(policy_hash),
         true <- database_int?(source_generation),
         true <- database_int?(seq),
         true <- is_nil(fingerprint) or fixed_hash?(fingerprint),
         true <- finite_probability?(p),
         true <- is_map(cells) do
      write(
        dir,
        {@runtime_format_version, authority, policy_hash, source_generation, seq, fingerprint, p, bins, cells},
        opts
      )
    else
      _invalid -> warn_invalid_runtime(dir)
    end
  end

  def save_runtime(dir, _runtime, _opts), do: warn_invalid_runtime(dir)

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

  @doc "Durably remove any persisted sailed polar under `dir`."
  @spec clear(Path.t()) :: :ok | {:error, term()}
  def clear(dir), do: AtomicFile.remove(path(dir), directory_root: dir)

  defp write(dir, term, opts) do
    atomic_opts = Keyword.put_new(opts, :directory_root, dir)

    case AtomicFile.write(path(dir), :erlang.term_to_binary(term), atomic_opts) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to persist sailed polar to #{inspect(dir)}: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning("Failed to persist sailed polar to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  defp decode(binary, dir) do
    case safe_binary_to_term(binary) do
      {@runtime_format_version, authority, policy_hash, source_generation, seq, fingerprint, p, %Bins{} = bins, cells} ->
        decode_runtime(
          dir,
          authority,
          policy_hash,
          source_generation,
          seq,
          fingerprint,
          p,
          bins,
          cells,
          false
        )

      {@previous_runtime_format_version, authority, policy_hash, source_generation, fingerprint, p, %Bins{} = bins,
       cells} ->
        decode_runtime(
          dir,
          authority,
          policy_hash,
          source_generation,
          0,
          fingerprint,
          p,
          bins,
          cells,
          true
        )

      {@legacy_format_version, cells} when is_map(cells) ->
        decode_legacy(dir, cells)

      _other ->
        warn_invalid(dir, "unrecognized/incompatible", :format)
    end
  rescue
    error -> warn_invalid(dir, "corrupt", error)
  end

  defp decode_runtime(
         dir,
         authority,
         policy_hash,
         source_generation,
         seq,
         fingerprint,
         p,
         bins,
         cells,
         upgrade?
       ) do
    with :ok <- Snapshot.validate_authority(authority),
         true <- fixed_hash?(policy_hash),
         true <- database_int?(source_generation),
         true <- database_int?(seq),
         true <- is_nil(fingerprint) or fixed_hash?(fingerprint),
         true <- finite_probability?(p),
         true <- is_map(cells) do
      runtime = %{
        authority: authority,
        policy_hash: policy_hash,
        source_generation: source_generation,
        seq: seq,
        last_restore_fingerprint: fingerprint,
        p: p,
        bins: bins,
        cells: cells
      }

      if upgrade?, do: {:ok, Map.put(runtime, :upgrade?, true)}, else: {:ok, runtime}
    else
      _invalid -> warn_invalid(dir, "unrecognized/incompatible", :runtime)
    end
  end

  defp decode_legacy(dir, cells) do
    case legacy_generation(cells) do
      {:ok, source_generation} ->
        {:ok,
         %{
           authority: nil,
           policy_hash: nil,
           source_generation: source_generation,
           seq: 0,
           last_restore_fingerprint: nil,
           p: nil,
           bins: nil,
           cells: cells,
           legacy?: true
         }}

      :error ->
        warn_invalid(dir, "unrecognized/incompatible", :legacy_generation)
    end
  end

  defp legacy_generation(cells) do
    Enum.reduce_while(cells, {:ok, 0}, fn
      {_key, {count, _quantile}}, {:ok, total}
      when is_integer(count) and count > 0 and total <= @database_int_max - count ->
        {:cont, {:ok, total + count}}

      _cell, _total ->
        {:halt, :error}
    end)
  end

  defp fixed_hash?(value), do: is_binary(value) and byte_size(value) == 32

  defp database_int?(value),
    do: is_integer(value) and value >= 0 and value <= @database_int_max

  defp finite_probability?(value) when is_float(value),
    do: value == value and value > 0.0 and value < 1.0 and value <= @max_finite

  defp finite_probability?(_value), do: false

  defp safe_binary_to_term(binary), do: :erlang.binary_to_term(binary, [:safe])

  defp warn_invalid_runtime(dir) do
    Logger.warning("Refusing to persist invalid sailed-polar runtime in #{inspect(dir)}")
    {:error, :invalid_runtime}
  end

  defp warn_invalid(dir, what, detail) do
    Logger.warning("Ignoring #{what} persisted sailed polar in #{inspect(dir)}: #{inspect(detail)}")
    :invalid
  end

  defp path(dir), do: Path.join(dir, @filename)
end
