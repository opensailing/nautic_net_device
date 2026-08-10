defmodule RacingOrg.Tracker.Pro.Polar.Checkpoint do
  @moduledoc """
  Pure projection and hydration for sailed-polar checkpoint content.

  The projection boundary converts the tuple-keyed `Observer.Store` cell map and
  tuple-backed `PSquare` markers into the closed, deterministically ordered polar
  schema. Hydration performs the inverse conversion only after the durable
  checkpoint contract accepts the exact content shape.
  """

  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint, as: ContractCheckpoint

  @schema_version 1
  @invalid {:error, :invalid_checkpoint_content}
  @u32_max 0xFFFF_FFFF

  @type cell_key :: {non_neg_integer(), non_neg_integer()}
  @type store_cells :: %{optional(cell_key()) => {pos_integer(), PSquare.t()}}
  @type content :: %{required(String.t()) => term()}

  @doc "Project an observer store cell map into closed polar checkpoint content."
  @spec project(store_cells()) :: {:ok, content()} | {:error, :invalid_checkpoint_content}
  def project(cells) when is_map(cells) do
    with {:ok, projected_cells} <- project_cells(Map.to_list(cells)),
         content = %{"cells" => Enum.sort_by(projected_cells, &cell_sort_key/1)},
         {:ok, _bytes} <- ContractCheckpoint.encode_content(:polar, @schema_version, content) do
      {:ok, content}
    else
      _error -> @invalid
    end
  end

  def project(_cells), do: @invalid

  @doc "Hydrate closed polar checkpoint content into an observer store cell map."
  @spec hydrate(content()) :: {:ok, store_cells()} | {:error, :invalid_checkpoint_content}
  def hydrate(content) when is_map(content) do
    with {:ok, _bytes} <- ContractCheckpoint.encode_content(:polar, @schema_version, content),
         {:ok, cells} <- hydrate_cells(content["cells"]) do
      {:ok, Map.new(cells)}
    else
      _error -> @invalid
    end
  end

  def hydrate(_content), do: @invalid

  defp project_cells(cells) do
    Enum.reduce_while(cells, {:ok, []}, fn cell, {:ok, projected} ->
      case project_cell(cell) do
        {:ok, value} -> {:cont, {:ok, [value | projected]}}
        @invalid -> {:halt, @invalid}
      end
    end)
  end

  defp project_cell({{tws_bin, twa_bin}, {count, %PSquare{} = quantile}})
       when is_integer(tws_bin) and tws_bin >= 0 and tws_bin <= @u32_max and is_integer(twa_bin) and
              twa_bin >= 0 and twa_bin <= @u32_max and is_integer(count) and count > 0 do
    with {:ok, projected_quantile} <- project_quantile(quantile) do
      {:ok,
       %{
         "count" => count,
         "quantile" => projected_quantile,
         "twa_bin" => twa_bin,
         "tws_bin" => tws_bin
       }}
    end
  end

  defp project_cell(_cell), do: @invalid

  defp project_quantile(%PSquare{} = quantile) do
    with {:ok, q} <- marker_list(quantile.q),
         {:ok, n} <- marker_list(quantile.n),
         {:ok, np} <- marker_list(quantile.np),
         {:ok, dnp} <- marker_list(quantile.dnp) do
      {:ok,
       %{
         "buffer" => quantile.buffer,
         "count" => quantile.count,
         "dnp" => dnp,
         "n" => n,
         "np" => np,
         "p" => quantile.p,
         "q" => q
       }}
    end
  end

  defp marker_list(nil), do: {:ok, nil}

  defp marker_list(markers) when is_tuple(markers) and tuple_size(markers) == 5,
    do: {:ok, Tuple.to_list(markers)}

  defp marker_list(_markers), do: @invalid

  defp cell_sort_key(cell), do: {cell["tws_bin"], cell["twa_bin"]}

  defp hydrate_cells(cells) when is_list(cells) do
    Enum.reduce_while(cells, {:ok, []}, fn cell, {:ok, hydrated} ->
      case hydrate_cell(cell) do
        {:ok, value} -> {:cont, {:ok, [value | hydrated]}}
        @invalid -> {:halt, @invalid}
      end
    end)
  end

  defp hydrate_cells(_cells), do: @invalid

  defp hydrate_cell(%{
         "count" => count,
         "quantile" => quantile,
         "twa_bin" => twa_bin,
         "tws_bin" => tws_bin
       }) do
    with {:ok, hydrated_quantile} <- hydrate_quantile(quantile) do
      {:ok, {{tws_bin, twa_bin}, {count, hydrated_quantile}}}
    end
  end

  defp hydrate_cell(_cell), do: @invalid

  defp hydrate_quantile(%{
         "buffer" => buffer,
         "count" => count,
         "dnp" => dnp,
         "n" => n,
         "np" => np,
         "p" => p,
         "q" => q
       }) do
    with {:ok, q} <- marker_tuple(q),
         {:ok, n} <- marker_tuple(n),
         {:ok, np} <- marker_tuple(np),
         {:ok, dnp} <- marker_tuple(dnp) do
      {:ok,
       %PSquare{
         p: p,
         count: count,
         buffer: buffer,
         q: q,
         n: n,
         np: np,
         dnp: dnp
       }}
    end
  end

  defp hydrate_quantile(_quantile), do: @invalid

  defp marker_tuple(nil), do: {:ok, nil}
  defp marker_tuple([a, b, c, d, e]), do: {:ok, {a, b, c, d, e}}
  defp marker_tuple(_markers), do: @invalid
end
