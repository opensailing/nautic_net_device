defmodule RacingOrg.Tracker.Pro.Polar.Checkpoint do
  @moduledoc """
  Pure projection and hydration for sailed-polar checkpoint content (schema 2).

  The projection boundary converts the tuple-keyed `Observer.Store` cell map and
  tuple-backed `PSquare` markers into the closed, deterministically ordered polar
  schema. Hydration performs the inverse conversion only after the durable
  checkpoint contract accepts the exact content shape.

  ## Why the content carries the grid and one global `p`

  A sailed-polar cell key is a BARE `{tws_bin, twa_bin}` index pair. An index is
  meaningless without the grid that minted it: under a 1-knot TWS width `tws_bin
  5` is ≈ 2.8 m/s, under a 1 m/s width it is 5.5 m/s. So the content binds the
  exact producing geometry — `tws_width_mps`, `twa_width_deg`, and the finite
  `max_tws_mps` ceiling that closes the TWS axis — and hydration rebuilds the
  producing `Bins` from it. The caller's own defaults are NEVER used to interpret
  a persisted index.

  The same argument applies to the quantile probability. Every cell of one
  observer is accumulated at the same `p` (`Observer`'s `:p` option), so `p` is
  bound ONCE for the whole checkpoint. A per-cell probability would let two cells
  of a single sailed polar disagree about what their stored speed even estimates;
  projection rejects any snapshot whose cells do not all share the declared `p`.

  ## Lossless compaction

  Only fields that the grid, the global `p`, or the cell count cannot reproduce
  are written:

    * `p` and `dnp` — `dnp` is exactly `[0, p/2, p, (1+p)/2, 1]`, so both come
      from the one global probability.
    * `quantile.count` — always the cell's own count.
    * `n[0]` and `n[4]` — the first marker's actual position is always 1 and the
      last is always the cell count, so only the three INTERIOR positions ship.
    * `np` is kept verbatim: it depends on the estimator's whole update history
      and is not reconstructible from `p` and `count`. `q` and the warmup
      `buffer` are the observations themselves.

  Compaction is lossless, not lossy: hydration reconstructs every dropped field
  bit-exactly, and the strict decoder re-derives the endpoints and revalidates
  the full five-marker P² invariants against the reconstruction. Cells are never
  truncated or dropped to fit — a sailed polar too large for one frame is valid
  content awaiting chunked carriage, which is why projection reports capacity
  separately from validity.
  """

  alias RacingOrg.Tracker.Pro.Polar.Observer.Bins
  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint, as: ContractCheckpoint

  @schema_version 2
  @invalid {:error, :invalid_checkpoint_content}

  @type cell_key :: {non_neg_integer(), non_neg_integer()}
  @type store_cells :: %{optional(cell_key()) => {pos_integer(), PSquare.t()}}
  @type content :: %{required(String.t()) => term()}
  @type runtime :: %{bins: Bins.t(), p: float(), cells: store_cells()}

  @doc "The polar checkpoint schema version this adapter projects and hydrates."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Project an observer store cell map into closed polar checkpoint content, bound
  to the `bins` geometry that minted the keys and the one quantile probability
  `p` every cell was accumulated at.
  """
  @spec project(Bins.t(), float(), store_cells()) ::
          {:ok, content()} | {:error, :invalid_checkpoint_content}
  def project(%Bins{} = bins, p, cells) when is_number(p) and is_map(cells) do
    with {:ok, projected_cells} <- project_cells(bins, p + 0.0, Map.to_list(cells)),
         content = %{
           "cells" => Enum.sort_by(projected_cells, &cell_sort_key/1),
           "max_tws_mps" => bins.max_tws_mps,
           "p" => p + 0.0,
           "twa_width_deg" => bins.twa_width_deg,
           "tws_width_mps" => bins.tws_width_mps
         },
         {:ok, _bytes} <- ContractCheckpoint.canonical_content(:polar, @schema_version, content) do
      {:ok, content}
    else
      _error -> @invalid
    end
  end

  def project(_bins, _p, _cells), do: @invalid

  @doc """
  Hydrate closed polar checkpoint content into the exact runtime configuration
  that produced it: the producing `Bins`, the global quantile probability, and
  the observer store cell map.
  """
  @spec hydrate(content()) ::
          {:ok, runtime()} | {:error, :invalid_checkpoint_content | :checkpoint_secret_forbidden}
  def hydrate(content) when is_map(content) do
    with {:ok, _bytes} <- ContractCheckpoint.canonical_content(:polar, @schema_version, content),
         {:ok, bins} <- hydrate_bins(content),
         {:ok, cells} <- hydrate_cells(content["cells"], content["p"]) do
      {:ok, %{bins: bins, p: content["p"], cells: Map.new(cells)}}
    else
      {:error, :checkpoint_secret_forbidden} = error -> error
      _error -> @invalid
    end
  end

  def hydrate(_content), do: @invalid

  defp project_cells(bins, p, cells) do
    Enum.reduce_while(cells, {:ok, []}, fn cell, {:ok, projected} ->
      case project_cell(bins, p, cell) do
        {:ok, value} -> {:cont, {:ok, [value | projected]}}
        @invalid -> {:halt, @invalid}
      end
    end)
  end

  # A key outside the declared finite grid is refused rather than carried: it
  # cannot be interpreted under the geometry the content binds, and admitting it
  # would persist an index whose meaning no reader can recover.
  defp project_cell(bins, p, {key, {count, %PSquare{} = quantile}})
       when is_integer(count) and count > 0 do
    with true <- Bins.valid_key?(bins, key),
         true <- quantile.p === p,
         true <- quantile.count === count,
         {:ok, projected_quantile} <- project_quantile(quantile, p, count) do
      {tws_bin, twa_bin} = key

      {:ok,
       %{
         "count" => count,
         "quantile" => projected_quantile,
         "twa_bin" => twa_bin,
         "tws_bin" => tws_bin
       }}
    else
      _error -> @invalid
    end
  end

  defp project_cell(_bins, _p, _cell), do: @invalid

  # Warmup phase: no markers yet, so the sorted buffer IS the estimator.
  defp project_quantile(%PSquare{q: nil} = quantile, _p, count) when count < 5 do
    if is_list(quantile.buffer) and length(quantile.buffer) == count and
         is_nil(quantile.n) and is_nil(quantile.np) and is_nil(quantile.dnp) do
      {:ok, %{"buffer" => quantile.buffer, "n" => nil, "np" => nil, "q" => nil}}
    else
      @invalid
    end
  end

  # Marker phase. `dnp` is checked against the global `p` before being dropped,
  # and the two derivable `n` endpoints are checked before only the interior
  # three are written.
  defp project_quantile(%PSquare{} = quantile, p, count) when count >= 5 do
    with {:ok, q} <- marker_list(quantile.q),
         {:ok, n} <- marker_list(quantile.n),
         {:ok, np} <- marker_list(quantile.np),
         {:ok, dnp} <- marker_list(quantile.dnp),
         true <- quantile.buffer == [],
         true <- dnp === ContractCheckpoint.expected_dnp(p),
         [1 | interior] <- n,
         {interior, [^count]} <- Enum.split(interior, 3) do
      {:ok, %{"buffer" => [], "n" => interior, "np" => np, "q" => q}}
    else
      _error -> @invalid
    end
  end

  defp project_quantile(_quantile, _p, _count), do: @invalid

  defp marker_list(markers) when is_tuple(markers) and tuple_size(markers) == 5,
    do: {:ok, Tuple.to_list(markers)}

  defp marker_list(_markers), do: @invalid

  defp cell_sort_key(cell), do: {cell["tws_bin"], cell["twa_bin"]}

  # Rebuilt through `Bins.new/1` so the hydrated geometry is constructed exactly
  # as a live one is, never as a hand-assembled struct that could drift from it.
  defp hydrate_bins(content) do
    {:ok,
     Bins.new(
       twa_width_deg: content["twa_width_deg"],
       tws_width_mps: content["tws_width_mps"],
       max_tws_mps: content["max_tws_mps"]
     )}
  rescue
    ArgumentError -> @invalid
  end

  defp hydrate_cells(cells, p) do
    Enum.reduce_while(cells, {:ok, []}, fn cell, {:ok, hydrated} ->
      case hydrate_cell(cell, p) do
        {:ok, value} -> {:cont, {:ok, [value | hydrated]}}
        @invalid -> {:halt, @invalid}
      end
    end)
  end

  defp hydrate_cell(cell, p) do
    key = {cell["tws_bin"], cell["twa_bin"]}
    count = cell["count"]

    with {:ok, quantile} <- hydrate_quantile(cell["quantile"], p, count) do
      {:ok, {key, {count, quantile}}}
    end
  end

  defp hydrate_quantile(%{"buffer" => buffer, "n" => nil, "np" => nil, "q" => nil}, p, count),
    do: {:ok, %PSquare{p: p, count: count, buffer: buffer, q: nil, n: nil, np: nil, dnp: nil}}

  defp hydrate_quantile(%{"buffer" => [], "n" => interior, "np" => np, "q" => q}, p, count) do
    {:ok,
     %PSquare{
       p: p,
       count: count,
       buffer: [],
       q: List.to_tuple(q),
       n: List.to_tuple([1 | interior] ++ [count]),
       np: List.to_tuple(np),
       dnp: List.to_tuple(ContractCheckpoint.expected_dnp(p))
     }}
  end

  defp hydrate_quantile(_quantile, _p, _count), do: @invalid
end
