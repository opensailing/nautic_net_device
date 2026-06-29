defmodule RacingOrg.Tracker.Pro.Compute.PolarLibraryTest do
  @moduledoc """
  The polar-aware native library calcs (`polar_performance`, `target_boat_speed`,
  `target_twa`, `vmg_performance`). Unlike the wind/VMG calcs these need the
  compiled polar interpolant, passed through `Library.compute/3` as a context
  (`%{polar_lookup: t}`) — the polar is device STATE, not a telemetry signal.

  All signal values are CATALOG UNITS: speeds m/s, angles DEGREES.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Compute.Library
  alias RacingOrg.Tracker.Pro.Polar
  alias RacingOrg.Tracker.Pro.Polar.Lookup

  @rad_per_deg :math.pi() / 180.0

  # A deliberately SIMPLE single-TWS polar so optimum/2 returns the provided optima
  # exactly (no across-TWS interpolation) and boat_speed at a grid node returns the
  # node value, making every assertion hand-computable.
  #
  #   At TWS = 10 m/s:
  #     - boat_speed(twa=60) is interpolated; boat_speed at a node is the node value.
  #     - beat optimum: twa=45, vmg=4.0  -> bsp = vmg/cos(45) = 4/0.70710678 = 5.65685
  #     - run  optimum: twa=150, vmg=5.0 -> bsp = vmg/|cos(150)| = 5/0.8660254 = 5.77350
  defp single_tws_polar do
    %Polar{
      polar_id: "test",
      version: 1,
      rows: [
        %{
          tws_mps: 10.0,
          cells: [
            %{twa_deg: 45.0, boat_speed_mps: 5.65685},
            %{twa_deg: 60.0, boat_speed_mps: 6.0},
            %{twa_deg: 90.0, boat_speed_mps: 7.0},
            %{twa_deg: 120.0, boat_speed_mps: 6.5},
            %{twa_deg: 150.0, boat_speed_mps: 5.7735},
            %{twa_deg: 180.0, boat_speed_mps: 4.0}
          ]
        }
      ],
      optima: [
        %{tws_mps: 10.0, beat_twa: 45.0, beat_vmg: 4.0, run_twa: 150.0, run_vmg: 5.0}
      ]
    }
  end

  defp lookup do
    {:ok, lk} = Lookup.build(single_tws_polar())
    lk
  end

  defp ctx, do: %{polar_lookup: lookup()}

  describe "polar_performance (percent of polar target boat speed)" do
    # At twa=90, tws=10: polar boat_speed = 7.0 (a grid node). If we actually make
    # 6.3 m/s STW, performance = 100 * 6.3 / 7.0 = 90.0%.
    test "100 * STW / polar_target at a known node" do
      signals = %{
        "boat_speed" => 6.3,
        "true_wind_angle" => 90.0,
        "true_wind_speed" => 10.0
      }

      assert {:ok, out} = Library.compute(:polar_performance, signals, ctx())
      assert_in_delta out["polar_performance"], 90.0, 1.0e-3
    end

    # 100% when STW equals the polar target.
    test "100% when sailing exactly to the polar" do
      signals = %{"boat_speed" => 7.0, "true_wind_angle" => 90.0, "true_wind_speed" => 10.0}
      assert {:ok, out} = Library.compute(:polar_performance, signals, ctx())
      assert_in_delta out["polar_performance"], 100.0, 1.0e-3
    end

    # In the no-go zone the polar target speed is ~0 -> performance is INVALID, not
    # a divide-by-zero or a bogus huge number.
    test "no-go zone (target ~0) is INVALID, not a divide-by-zero" do
      signals = %{"boat_speed" => 1.0, "true_wind_angle" => 0.0, "true_wind_speed" => 10.0}
      assert :invalid = Library.compute(:polar_performance, signals, ctx())
    end

    test "no polar loaded is INVALID" do
      signals = %{"boat_speed" => 6.0, "true_wind_angle" => 90.0, "true_wind_speed" => 10.0}
      assert :invalid = Library.compute(:polar_performance, signals, %{polar_lookup: nil})
      assert :invalid = Library.compute(:polar_performance, signals, %{})
      assert :invalid = Library.compute(:polar_performance, signals)
    end

    test "missing a required signal is INVALID" do
      assert :invalid =
               Library.compute(:polar_performance, %{"boat_speed" => 6.0, "true_wind_speed" => 10.0}, ctx())
    end
  end

  describe "target_boat_speed (VMG-optimal target speed for the current leg)" do
    # Upwind (twa < 90): the beat optimum bsp = beat_vmg / cos(beat_twa) = 4/cos(45).
    test "upwind leg -> beat optimum bsp" do
      signals = %{"true_wind_angle" => 40.0, "true_wind_speed" => 10.0}
      assert {:ok, out} = Library.compute(:target_boat_speed, signals, ctx())
      assert_in_delta out["target_boat_speed"], 4.0 / :math.cos(45.0 * @rad_per_deg), 1.0e-2
    end

    # Downwind (twa >= 90): the run optimum bsp = run_vmg / |cos(run_twa)| = 5/|cos(150)|.
    test "downwind leg -> run optimum bsp" do
      signals = %{"true_wind_angle" => 140.0, "true_wind_speed" => 10.0}
      assert {:ok, out} = Library.compute(:target_boat_speed, signals, ctx())
      assert_in_delta out["target_boat_speed"], 5.0 / abs(:math.cos(150.0 * @rad_per_deg)), 1.0e-2
    end

    test "no polar / missing inputs are INVALID" do
      signals = %{"true_wind_angle" => 40.0, "true_wind_speed" => 10.0}
      assert :invalid = Library.compute(:target_boat_speed, signals, %{polar_lookup: nil})
      assert :invalid = Library.compute(:target_boat_speed, %{"true_wind_speed" => 10.0}, ctx())
    end
  end

  describe "target_twa (the matching optimum angle for the current leg)" do
    test "upwind leg -> beat optimum twa" do
      signals = %{"true_wind_angle" => 50.0, "true_wind_speed" => 10.0}
      assert {:ok, out} = Library.compute(:target_twa, signals, ctx())
      assert_in_delta out["target_twa"], 45.0, 1.0e-2
    end

    test "downwind leg -> run optimum twa" do
      signals = %{"true_wind_angle" => 160.0, "true_wind_speed" => 10.0}
      assert {:ok, out} = Library.compute(:target_twa, signals, ctx())
      assert_in_delta out["target_twa"], 150.0, 1.0e-2
    end

    # The beat-vs-run boundary is at twa = 90 (< 90 beat, >= 90 run).
    test "beat-vs-run selection just below/above 90 deg" do
      below = %{"true_wind_angle" => 89.9, "true_wind_speed" => 10.0}
      above = %{"true_wind_angle" => 90.1, "true_wind_speed" => 10.0}

      assert {:ok, %{"target_twa" => b}} = Library.compute(:target_twa, below, ctx())
      assert {:ok, %{"target_twa" => a}} = Library.compute(:target_twa, above, ctx())
      assert_in_delta b, 45.0, 1.0e-2
      assert_in_delta a, 150.0, 1.0e-2
    end
  end

  describe "vmg (actual velocity made good, from boat_speed + true_wind_angle)" do
    # The polar-context VMG uses the live TWA directly: vmg = STW * cos(TWA).
    # Upwind: positive = progress to windward.
    test "upwind twa=45: vmg = STW * cos(45)" do
      signals = %{"boat_speed" => 6.0, "true_wind_angle" => 45.0}
      assert {:ok, out} = Library.compute(:vmg, signals, ctx())
      assert_in_delta out["vmg"], 6.0 * :math.cos(45.0 * @rad_per_deg), 1.0e-6
    end

    # Downwind twa=135: cos(135) < 0; positive-to-leeward convention means we report
    # the magnitude of progress along the wind axis as a positive leeward VMG.
    test "downwind twa=135: positive vmg to leeward (sign convention)" do
      signals = %{"boat_speed" => 6.0, "true_wind_angle" => 135.0}
      assert {:ok, out} = Library.compute(:vmg, signals, ctx())
      # |cos(135)| = cos(45); leeward progress reported positive.
      assert_in_delta out["vmg"], 6.0 * abs(:math.cos(135.0 * @rad_per_deg)), 1.0e-6
      assert out["vmg"] > 0.0
    end

    test "missing inputs are INVALID" do
      assert :invalid = Library.compute(:vmg, %{"boat_speed" => 6.0}, ctx())
    end
  end

  describe "vmg_performance (percent of optimum VMG for the current leg)" do
    # Upwind: actual_vmg = STW*cos(TWA); optimum_vmg = beat_vmg (4.0).
    # At twa=45, STW=4.0: actual_vmg = 4*cos(45) = 2.8284; perf = 100*2.8284/4 = 70.71%.
    test "upwind: 100 * actual_vmg / beat_vmg" do
      signals = %{"boat_speed" => 4.0, "true_wind_angle" => 45.0, "true_wind_speed" => 10.0}
      assert {:ok, out} = Library.compute(:vmg_performance, signals, ctx())
      expected = 100.0 * (4.0 * :math.cos(45.0 * @rad_per_deg)) / 4.0
      assert_in_delta out["vmg_performance"], expected, 1.0e-2
    end

    test "downwind: 100 * actual_vmg / run_vmg" do
      signals = %{"boat_speed" => 5.0, "true_wind_angle" => 150.0, "true_wind_speed" => 10.0}
      assert {:ok, out} = Library.compute(:vmg_performance, signals, ctx())
      expected = 100.0 * (5.0 * abs(:math.cos(150.0 * @rad_per_deg))) / 5.0
      assert_in_delta out["vmg_performance"], expected, 1.0e-2
    end

    test "no polar / missing inputs are INVALID" do
      signals = %{"boat_speed" => 4.0, "true_wind_angle" => 45.0, "true_wind_speed" => 10.0}
      assert :invalid = Library.compute(:vmg_performance, signals, %{polar_lookup: nil})
      assert :invalid = Library.compute(:vmg_performance, %{"true_wind_speed" => 10.0}, ctx())
    end
  end

  describe "backwards-compatible compute/2 for non-polar calcs" do
    test "true_wind still works through compute/2 (no context)" do
      signals = %{
        "apparent_wind_speed" => 10.0,
        "apparent_wind_angle" => 0.0,
        "boat_speed" => 5.0,
        "heel" => 0.0,
        "pitch" => 0.0
      }

      assert {:ok, out} = Library.compute(:true_wind, signals)
      assert_in_delta out["true_wind_speed"], 5.0, 1.0e-6
    end

    test "a polar calc through compute/2 (no context) is INVALID (no polar)" do
      signals = %{"boat_speed" => 6.0, "true_wind_angle" => 90.0, "true_wind_speed" => 10.0}
      assert :invalid = Library.compute(:polar_performance, signals)
    end
  end
end
