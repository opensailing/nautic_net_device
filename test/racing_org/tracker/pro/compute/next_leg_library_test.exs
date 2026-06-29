defmodule RacingOrg.Tracker.Pro.Compute.NextLegLibraryTest do
  @moduledoc """
  The "next leg" predicted apparent-wind native library calcs (`next_leg_twa`,
  `next_leg_aws`, `next_leg_awa`) — B&G "Next Leg AWA/AWS". They predict the
  apparent wind you'd experience on the FOLLOWING leg of the course (from the
  active mark to the next mark in `sequence` order), given the current true wind
  and the polar boat speed you'd make on that leg.

  Angle convention: TWA/AWA are measured FROM THE BOW, 0 = head to wind, folded
  into [0, 180] (no port/starboard sign here — the leg geometry already fixes the
  side). `next_leg_bearing` is a geographic 0–360 bearing (injected as a signal by
  Nav.Broadcaster, the same way `bearing_to_mark` is).

  `next_leg_aws`/`next_leg_awa` need the compiled polar interpolant, passed through
  `Library.compute/3` as `%{polar_lookup: t}` (the polar is device STATE, not a
  signal). All signal values are CATALOG UNITS: speeds m/s, angles DEGREES.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Compute.Library
  alias RacingOrg.Tracker.Pro.Polar
  alias RacingOrg.Tracker.Pro.Polar.Lookup

  @rad_per_deg :math.pi() / 180.0
  @deg_per_rad 180.0 / :math.pi()

  # A simple single-TWS polar so boat_speed at a grid node returns the node value
  # exactly, making the wind-triangle math hand-computable.
  #   At TWS = 10 m/s: boat_speed(twa=90) = 7.0, boat_speed(twa=120) = 6.5.
  defp single_tws_polar do
    %Polar{
      polar_id: "test",
      version: 1,
      rows: [
        %{
          tws_mps: 10.0,
          cells: [
            %{twa_deg: 45.0, boat_speed_mps: 5.65685},
            %{twa_deg: 90.0, boat_speed_mps: 7.0},
            %{twa_deg: 120.0, boat_speed_mps: 6.5},
            %{twa_deg: 150.0, boat_speed_mps: 5.7735},
            %{twa_deg: 180.0, boat_speed_mps: 4.0}
          ]
        }
      ],
      optima: [%{tws_mps: 10.0, beat_twa: 45.0, beat_vmg: 4.0, run_twa: 150.0, run_vmg: 5.0}]
    }
  end

  defp lookup do
    {:ok, lk} = Lookup.build(single_tws_polar())
    lk
  end

  defp ctx, do: %{polar_lookup: lookup()}

  # Reference wind triangle (TWA from the bow, 0 = head to wind):
  #   AWS = sqrt(TWS^2 + BSP^2 + 2*TWS*BSP*cos(TWA))
  #   AWA = atan2(TWS*sin(TWA), BSP + TWS*cos(TWA))  -> degrees, 0..180
  defp triangle(tws, bsp, twa_deg) do
    twa = twa_deg * @rad_per_deg
    aws = :math.sqrt(tws * tws + bsp * bsp + 2 * tws * bsp * :math.cos(twa))
    awa = :math.atan2(tws * :math.sin(twa), bsp + tws * :math.cos(twa)) * @deg_per_rad
    {aws, awa}
  end

  describe "next_leg_twa (fold of true_wind_direction - next_leg_bearing into [0,180])" do
    test "true wind dead astern of the next-leg heading -> twa 180 (running)" do
      # next_leg_bearing 0 (heading north), wind FROM the south (twd 180) -> twa 180.
      signals = %{"true_wind_direction" => 180.0, "next_leg_bearing" => 0.0}
      assert {:ok, out} = Library.compute(:next_leg_twa, signals)
      assert_in_delta out["next_leg_twa"], 180.0, 1.0e-9
    end

    test "true wind dead ahead -> twa 0 (head to wind)" do
      signals = %{"true_wind_direction" => 0.0, "next_leg_bearing" => 0.0}
      assert {:ok, out} = Library.compute(:next_leg_twa, signals)
      assert_in_delta out["next_leg_twa"], 0.0, 1.0e-9
    end

    test "folds port and starboard to the same absolute angle" do
      # heading 90 (east). Wind from 30 (port) and 150 (starboard) are both 60 off.
      port = %{"true_wind_direction" => 30.0, "next_leg_bearing" => 90.0}
      stbd = %{"true_wind_direction" => 150.0, "next_leg_bearing" => 90.0}
      assert {:ok, %{"next_leg_twa" => p}} = Library.compute(:next_leg_twa, port)
      assert {:ok, %{"next_leg_twa" => s}} = Library.compute(:next_leg_twa, stbd)
      assert_in_delta p, 60.0, 1.0e-9
      assert_in_delta s, 60.0, 1.0e-9
    end

    test "folds correctly across the 180 boundary (350 deg difference -> 10)" do
      signals = %{"true_wind_direction" => 350.0, "next_leg_bearing" => 0.0}
      assert {:ok, out} = Library.compute(:next_leg_twa, signals)
      assert_in_delta out["next_leg_twa"], 10.0, 1.0e-9
    end

    test "missing next_leg_bearing (no next leg) is INVALID" do
      assert :invalid = Library.compute(:next_leg_twa, %{"true_wind_direction" => 180.0})
    end

    test "missing true_wind_direction is INVALID" do
      assert :invalid = Library.compute(:next_leg_twa, %{"next_leg_bearing" => 0.0})
    end
  end

  describe "next_leg_aws / next_leg_awa (predicted apparent wind via the wind triangle)" do
    # Beam reach on the next leg: next_leg_twa = 90, TWS = 10, polar BSP(90,10) = 7.0.
    #   AWS = sqrt(10^2 + 7^2 + 2*10*7*cos90) = sqrt(149) = 12.2066
    #   AWA = atan2(10*sin90, 7 + 10*cos90) = atan2(10, 7) = 55.008 deg
    test "beam-reach next leg: AWS/AWA from the triangle with polar BSP" do
      # next_leg_bearing 0 (north). Wind from 90 (east) -> twa 90.
      signals = %{
        "true_wind_direction" => 90.0,
        "true_wind_speed" => 10.0,
        "next_leg_bearing" => 0.0
      }

      {aws, awa} = triangle(10.0, 7.0, 90.0)

      assert {:ok, out_aws} = Library.compute(:next_leg_aws, signals, ctx())
      assert {:ok, out_awa} = Library.compute(:next_leg_awa, signals, ctx())
      assert_in_delta out_aws["next_leg_aws"], aws, 1.0e-3
      assert_in_delta out_awa["next_leg_awa"], awa, 1.0e-3
    end

    # Broad reach: next_leg_twa = 120, BSP(120,10) = 6.5.
    #   AWS = sqrt(100 + 42.25 + 2*10*6.5*cos120) = sqrt(100 + 42.25 - 65) = sqrt(77.25)
    test "broad-reach next leg: AWS/AWA from the triangle" do
      # next_leg_bearing 0 (north). Wind from 120 -> twa 120.
      signals = %{
        "true_wind_direction" => 120.0,
        "true_wind_speed" => 10.0,
        "next_leg_bearing" => 0.0
      }

      {aws, awa} = triangle(10.0, 6.5, 120.0)

      assert {:ok, out_aws} = Library.compute(:next_leg_aws, signals, ctx())
      assert {:ok, out_awa} = Library.compute(:next_leg_awa, signals, ctx())
      assert_in_delta out_aws["next_leg_aws"], aws, 1.0e-3
      assert_in_delta out_awa["next_leg_awa"], awa, 1.0e-3
    end

    test "AWA folds across the 180 boundary the same as TWA (port/starboard symmetric)" do
      # heading north. Wind from 80 (starboard) and 280 (port) are both twa 80.
      stbd = %{"true_wind_direction" => 80.0, "true_wind_speed" => 10.0, "next_leg_bearing" => 0.0}
      port = %{"true_wind_direction" => 280.0, "true_wind_speed" => 10.0, "next_leg_bearing" => 0.0}

      assert {:ok, %{"next_leg_awa" => a}} = Library.compute(:next_leg_awa, stbd, ctx())
      assert {:ok, %{"next_leg_awa" => b}} = Library.compute(:next_leg_awa, port, ctx())
      assert_in_delta a, b, 1.0e-6
      assert a >= 0.0 and a <= 180.0
    end

    test "no polar loaded -> INVALID (never garbage)" do
      signals = %{"true_wind_direction" => 90.0, "true_wind_speed" => 10.0, "next_leg_bearing" => 0.0}
      assert :invalid = Library.compute(:next_leg_aws, signals, %{polar_lookup: nil})
      assert :invalid = Library.compute(:next_leg_awa, signals, %{polar_lookup: nil})
      assert :invalid = Library.compute(:next_leg_aws, signals)
      assert :invalid = Library.compute(:next_leg_awa, signals)
    end

    test "no next leg (missing next_leg_bearing) -> INVALID" do
      signals = %{"true_wind_direction" => 90.0, "true_wind_speed" => 10.0}
      assert :invalid = Library.compute(:next_leg_aws, signals, ctx())
      assert :invalid = Library.compute(:next_leg_awa, signals, ctx())
    end

    test "missing true_wind_speed -> INVALID" do
      signals = %{"true_wind_direction" => 90.0, "next_leg_bearing" => 0.0}
      assert :invalid = Library.compute(:next_leg_aws, signals, ctx())
      assert :invalid = Library.compute(:next_leg_awa, signals, ctx())
    end

    # No-go zone on the next leg: next_leg_twa ~0 -> the polar interpolates to ~0
    # boat speed; the prediction is degenerate (you cannot sail there). INVALID,
    # not a NaN / blow-up.
    test "next leg in the no-go zone (BSP ~0) -> INVALID" do
      # next_leg_bearing 0, wind from 0 -> twa 0 (dead upwind, no-go).
      signals = %{"true_wind_direction" => 0.0, "true_wind_speed" => 10.0, "next_leg_bearing" => 0.0}
      assert :invalid = Library.compute(:next_leg_aws, signals, ctx())
      assert :invalid = Library.compute(:next_leg_awa, signals, ctx())
    end
  end

  describe "unknown vs known keys" do
    test "next_leg_twa composes without a polar (pure geometry/wind)" do
      assert {:ok, _} =
               Library.compute(:next_leg_twa, %{"true_wind_direction" => 90.0, "next_leg_bearing" => 0.0})
    end
  end
end
