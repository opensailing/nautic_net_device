defmodule RacingOrg.Tracker.Pro.PolarTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Polar
  alias RacingOrg.Tracker.Protobuf.PolarCell
  alias RacingOrg.Tracker.Protobuf.PolarOptimum
  alias RacingOrg.Tracker.Protobuf.PolarRow
  alias RacingOrg.Tracker.Protobuf.PolarTable

  test "from_protobuf/1 normalizes a PolarTable into a values-only struct" do
    table =
      struct(PolarTable,
        polar_id: "boat-42",
        version: 7,
        rows: [
          struct(PolarRow,
            tws_mps: 5.0,
            cells: [
              struct(PolarCell, twa_deg: 45.0, boat_speed_mps: 4.1),
              struct(PolarCell, twa_deg: 90.0, boat_speed_mps: 6.2)
            ]
          )
        ],
        optima: [
          struct(PolarOptimum, tws_mps: 5.0, beat_twa: 42.0, beat_vmg: 3.0, run_twa: 165.0, run_vmg: 5.1)
        ]
      )

    polar = Polar.from_protobuf(table)

    assert %Polar{polar_id: "boat-42", version: 7} = polar
    assert [%{tws_mps: 5.0, cells: cells}] = polar.rows
    assert cells == [%{twa_deg: 45.0, boat_speed_mps: 4.1}, %{twa_deg: 90.0, boat_speed_mps: 6.2}]

    assert [%{tws_mps: 5.0, beat_twa: 42.0, beat_vmg: 3.0, run_twa: 165.0, run_vmg: 5.1}] = polar.optima

    # No generated protobuf structs leak into the normalized representation.
    refute Enum.any?(polar.rows, &is_struct/1)
    refute Enum.any?(polar.optima, &is_struct/1)
  end

  test "from_protobuf/1 handles an empty grid" do
    polar = Polar.from_protobuf(struct(PolarTable, polar_id: "p", version: 1, rows: [], optima: []))
    assert %Polar{polar_id: "p", version: 1, rows: [], optima: []} = polar
  end
end
