defmodule RacingOrg.Tracker.Pro.Polar do
  @moduledoc """
  The device's normalized, on-device view of the current REFERENCE performance
  polar.

  A polar is BOAT-scoped configuration (a stable `polar_id` + a monotonic
  `version`), pushed to the device as the `:polar_table` device command. It is
  independent of the race-assignment lifecycle: replacing, cancelling, or
  expiring a race assignment never touches the polar, and applying a polar never
  touches an active assignment.

  This struct keeps the polar RAW (values-only): the sparse speed grid (rows of
  true wind speed, each holding cells of true wind angle → boat speed) and the
  per-TWS VMG optima. No interpolation / target / VMG math happens here — that is
  a later phase, which reads the current polar via
  `RacingOrg.Tracker.Pro.Commands.current_polar/1`.

  All values are SI floats, mirroring the `PolarTable` contract: wind/boat speeds
  in meters/second, wind angles in degrees.
  """

  alias RacingOrg.Tracker.Protobuf.PolarTable

  # The Desired State v1 `polar` section contract (see
  # RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1).
  @schema_version 1
  @command_type "polar_table"

  @type cell :: %{twa_deg: float(), boat_speed_mps: float()}
  @type row :: %{tws_mps: float(), cells: [cell()]}
  @type optimum :: %{
          tws_mps: float(),
          beat_twa: float(),
          beat_vmg: float(),
          run_twa: float(),
          run_vmg: float()
        }

  @type t :: %__MODULE__{
          polar_id: String.t(),
          version: non_neg_integer(),
          rows: [row()],
          optima: [optimum()]
        }

  defstruct polar_id: "",
            version: 0,
            rows: [],
            optima: []

  @doc """
  Build the normalized on-device polar from a decoded `%PolarTable{}`.

  The protobuf is flattened into plain maps (values only), so the persisted /
  exposed representation never depends on the generated protobuf structs.
  """
  @spec from_protobuf(PolarTable.t()) :: t()
  def from_protobuf(%PolarTable{} = table) do
    %__MODULE__{
      polar_id: table.polar_id,
      version: table.version,
      rows: Enum.map(table.rows, &row/1),
      optima: Enum.map(table.optima, &optimum/1)
    }
  end

  @doc """
  Validate and normalize the canonical Desired State v1 polar projection.

  This is STRICT and exact: the projection must declare the supported
  `schema_version` / `command_type`, carry at least one row, and every value must
  sit inside the physical domain the interpolant assumes — `tws_mps >= 0`,
  `twa_deg` within `0..180` (the polar is symmetric about the wind axis), and
  `boat_speed_mps >= 0`. A polar that cannot produce a usable lookup surface is
  rejected here rather than silently installed as an unusable reference.
  """
  @spec from_desired_state(term()) :: {:ok, t()} | {:error, term()}
  def from_desired_state(%{} = content) do
    with :ok <- validate_schema_version(get(content, :schema_version)),
         :ok <- validate_command_type(get(content, :command_type)),
         polar_id when is_binary(polar_id) and polar_id != "" <- get(content, :polar_id),
         version when is_integer(version) and version >= 0 <- get(content, :version),
         rows when is_list(rows) and rows != [] <- get(content, :rows),
         {:ok, rows} <- normalize_rows(rows),
         optima when is_list(optima) <- get(content, :optima, []),
         {:ok, optima} <- normalize_optima(optima) do
      {:ok, %__MODULE__{polar_id: polar_id, version: version, rows: rows, optima: optima}}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_polar}
    end
  end

  def from_desired_state(_content), do: {:error, :invalid_polar}

  defp validate_schema_version(@schema_version), do: :ok
  defp validate_schema_version(_version), do: {:error, :unsupported_polar_schema_version}

  defp validate_command_type(@command_type), do: :ok
  defp validate_command_type(_type), do: {:error, :invalid_polar_command_type}

  defp normalize_rows(rows) do
    reduce_normalized(rows, fn row ->
      with tws when is_number(tws) and tws >= 0 <- get(row, :tws_mps),
           cells when is_list(cells) and cells != [] <- get(row, :cells),
           {:ok, cells} <- normalize_cells(cells) do
        {:ok, %{tws_mps: tws / 1, cells: cells}}
      else
        {:error, _reason} = error -> error
        _other -> {:error, :invalid_polar_row}
      end
    end)
  end

  defp normalize_cells(cells) do
    reduce_normalized(cells, fn cell ->
      with twa when is_number(twa) and twa >= 0 and twa <= 180 <- get(cell, :twa_deg),
           speed when is_number(speed) and speed >= 0 <- get(cell, :boat_speed_mps) do
        {:ok, %{twa_deg: twa / 1, boat_speed_mps: speed / 1}}
      else
        _other -> {:error, :invalid_polar_cell}
      end
    end)
  end

  defp normalize_optima(optima) do
    reduce_normalized(optima, fn optimum ->
      fields = [:tws_mps, :beat_twa, :beat_vmg, :run_twa, :run_vmg]

      if is_map(optimum) and Enum.all?(fields, &is_number(get(optimum, &1))) do
        {:ok, Map.new(fields, &{&1, get(optimum, &1) / 1})}
      else
        {:error, :invalid_polar_optimum}
      end
    end)
  end

  defp reduce_normalized(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default

  defp row(%{tws_mps: tws, cells: cells}) do
    %{tws_mps: tws, cells: Enum.map(cells, &cell/1)}
  end

  defp cell(%{twa_deg: twa, boat_speed_mps: bsp}) do
    %{twa_deg: twa, boat_speed_mps: bsp}
  end

  defp optimum(%{} = o) do
    %{
      tws_mps: o.tws_mps,
      beat_twa: o.beat_twa,
      beat_vmg: o.beat_vmg,
      run_twa: o.run_twa,
      run_vmg: o.run_vmg
    }
  end
end
