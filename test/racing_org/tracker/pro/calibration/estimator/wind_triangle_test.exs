defmodule RacingOrg.Tracker.Pro.Calibration.Estimator.WindTriangleTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Estimator.WindTriangle

  describe "true_wind/3 (inverse triangle: apparent → true)" do
    test "matches the hand-computed close-hauled fixture" do
      # AWS 8, AWA +30°, STW 4:
      #   ty = 8·sin30 = 4.0, tx = 8·cos30 − 4 = 2.9282
      #   TWS = √(16 + 8.5744) = 4.9573, TWA = atan2(4, 2.9282) = 53.79°
      # (the same fixture the polar Observer tests pin against Library.compute).
      {tws, twa} = WindTriangle.true_wind(8.0, 30.0, 4.0)

      assert_in_delta tws, 4.9573, 0.001
      assert_in_delta twa, 53.79, 0.01
    end

    test "port-side apparent wind gives a negative (port) TWA" do
      {tws, twa} = WindTriangle.true_wind(8.0, -30.0, 4.0)

      assert_in_delta tws, 4.9573, 0.001
      assert_in_delta twa, -53.79, 0.01
    end

    test "head-to-wind: AWA 0 keeps TWA 0 and subtracts STW" do
      {tws, twa} = WindTriangle.true_wind(8.0, 0.0, 3.0)

      assert_in_delta tws, 5.0, 1.0e-9
      assert_in_delta twa, 0.0, 1.0e-9
    end

    test "running: apparent from dead astern with STW faster than AWS flips TWA" do
      # AWS 2 from dead ahead at STW 4 means the true wind is from dead astern.
      {tws, twa} = WindTriangle.true_wind(2.0, 0.0, 4.0)

      assert_in_delta tws, 2.0, 1.0e-9
      assert_in_delta abs(twa), 180.0, 1.0e-9
    end
  end

  describe "apparent_wind/3 (forward triangle: true → apparent)" do
    test "round-trips with true_wind/3 across the sailing envelope" do
      for twa <- [-170.0, -120.0, -90.0, -42.0, -10.0, 10.0, 42.0, 90.0, 120.0, 170.0],
          tws <- [3.0, 6.0, 10.0],
          stw <- [0.0, 2.0, 4.0] do
        {aws, awa} = WindTriangle.apparent_wind(tws, twa, stw)
        {tws2, twa2} = WindTriangle.true_wind(aws, awa, stw)

        assert_in_delta tws2, tws, 1.0e-9
        assert_in_delta twa2, twa, 1.0e-9
      end
    end

    test "beam true wind moves apparent forward, never aft" do
      {aws, awa} = WindTriangle.apparent_wind(6.0, 90.0, 4.0)

      assert aws > 6.0
      assert awa > 0.0 and awa < 90.0
    end
  end

  describe "twd/2" do
    test "wraps heading + TWA into [0, 360)" do
      assert_in_delta WindTriangle.twd(350.0, 20.0), 10.0, 1.0e-9
      assert_in_delta WindTriangle.twd(10.0, -20.0), 350.0, 1.0e-9
      assert_in_delta WindTriangle.twd(180.0, 45.0), 225.0, 1.0e-9
    end
  end

  describe "wrap180/1 and wrap360/1" do
    test "wrap180 maps into (−180, 180]" do
      assert_in_delta WindTriangle.wrap180(190.0), -170.0, 1.0e-9
      assert_in_delta WindTriangle.wrap180(-190.0), 170.0, 1.0e-9
      assert_in_delta WindTriangle.wrap180(540.0), 180.0, 1.0e-9
      assert_in_delta WindTriangle.wrap180(-540.0), 180.0, 1.0e-9
      assert_in_delta WindTriangle.wrap180(0.0), 0.0, 1.0e-9
      assert_in_delta WindTriangle.wrap180(179.5), 179.5, 1.0e-9
    end

    test "wrap360 maps into [0, 360)" do
      assert_in_delta WindTriangle.wrap360(-10.0), 350.0, 1.0e-9
      assert_in_delta WindTriangle.wrap360(370.0), 10.0, 1.0e-9
      assert_in_delta WindTriangle.wrap360(360.0), 0.0, 1.0e-9
      assert_in_delta WindTriangle.wrap360(0.0), 0.0, 1.0e-9
    end
  end

  describe "sensitivity/3 (local ∂TWA/∂AWA)" do
    test "matches a direct central difference through the triangle" do
      step = 0.5
      {_, hi} = WindTriangle.true_wind(8.0, 30.0 + step, 4.0)
      {_, lo} = WindTriangle.true_wind(8.0, 30.0 - step, 4.0)
      expected = (hi - lo) / (2.0 * step)

      assert_in_delta WindTriangle.sensitivity(8.0, 30.0, 4.0), expected, 1.0e-9
    end

    test "is > 1 close-hauled (STW subtraction amplifies AWA changes)" do
      g = WindTriangle.sensitivity(8.0, 30.0, 4.0)

      assert g > 1.0 and g < 2.5
    end
  end
end
