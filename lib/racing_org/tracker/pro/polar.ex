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
