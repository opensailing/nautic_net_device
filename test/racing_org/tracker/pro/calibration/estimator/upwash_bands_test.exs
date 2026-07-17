defmodule RacingOrg.Tracker.Pro.Calibration.Estimator.UpwashBandsTest do
  @moduledoc """
  Unit tests for the TWS-banded partial-pooling layer, on RAW scalar upwash
  estimates (no wind-triangle involvement — the synthetic-recovery tests in
  `AwaOffsetTest` cover the full chain). These lock:

    * the band edges [2, 4, 6, 8, 10, 12, ∞) / centers [3, 5, 7, 9, 11, 13];
    * the light-air (< 2 m/s) exclusion;
    * the k = 1 "no pooling with itself" classic gate (min 8 samples);
    * the backbone fit: slope pinned to 0 under a 3 m/s populated span,
      clamped to ±0.7 °/(m/s), zero-variance bins floored at s = 0.3°;
    * empirical-Bayes shrinkage of a deviant band toward the backbone;
    * the shear-day screen (interpolate/hold, 3° floor) and its counters;
    * the ±10° clamp on published curve values.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Estimator.UpwashBands

  defp feed(t, tws, values) do
    Enum.reduce(values, t, fn v, t ->
      {:accepted, t} = UpwashBands.observe(t, tws, v)
      t
    end)
  end

  describe "band_center/1" do
    test "maps TWS onto 2 m/s band centers, the top band absorbing everything above 12" do
      assert UpwashBands.band_center(1.99) == :light
      assert UpwashBands.band_center(2.0) == 3
      assert UpwashBands.band_center(3.99) == 3
      assert UpwashBands.band_center(4.0) == 5
      assert UpwashBands.band_center(7.3) == 7
      assert UpwashBands.band_center(9.99) == 9
      assert UpwashBands.band_center(10.0) == 11
      assert UpwashBands.band_center(11.99) == 11
      assert UpwashBands.band_center(12.0) == 13
      assert UpwashBands.band_center(25.0) == 13
    end
  end

  describe "light-air exclusion" do
    test "TWS below 2 m/s is excluded and counted, feeding nothing" do
      t = UpwashBands.new()

      assert {:excluded_light, t} = UpwashBands.observe(t, 1.5, 2.0)

      snap = UpwashBands.snapshot(t)
      assert snap.excluded_light == 1
      assert snap.screened == 0
      assert snap.bands == %{}
      assert snap.curve == []
      assert snap.backbone == nil
    end
  end

  describe "k = 1 (single populated band: no pooling with itself)" do
    test "publishes only after the classic 8-sample gate" do
      t7 = feed(UpwashBands.new(), 6.5, List.duplicate(2.5, 7))
      assert UpwashBands.snapshot(t7).curve == []

      t8 = feed(t7, 6.5, [2.5])
      snap = UpwashBands.snapshot(t8)

      assert [{7, v}] = snap.curve
      assert_in_delta v, 2.5, 1.0e-9
    end

    test "the k = 1 backbone degenerates to the band median with zero slope (τ² edge)" do
      t = feed(UpwashBands.new(), 6.5, List.duplicate(2.5, 3))
      snap = UpwashBands.snapshot(t)

      # The DerSimonian–Laird denominator is zero at k = 1; the fit must fall
      # back to the pinned-slope weighted mean instead of dividing by zero.
      assert snap.backbone.b == 0.0
      assert_in_delta snap.backbone.a, 2.5, 1.0e-9
      assert snap.curve == []
    end
  end

  describe "backbone fit" do
    test "zero-spread bands do not blow up the weighted fit (σ floor at 0.3°)" do
      t =
        UpwashBands.new()
        |> feed(5.0, List.duplicate(2.0, 8))
        |> feed(7.0, List.duplicate(2.0, 8))

      snap = UpwashBands.snapshot(t)

      assert [{5, v5}, {7, v7}] = snap.curve
      assert_in_delta v5, 2.0, 1.0e-9
      assert_in_delta v7, 2.0, 1.0e-9
      assert_in_delta snap.backbone.a, 2.0, 1.0e-9
    end

    test "the slope is pinned to 0 when the populated span is under 3 m/s" do
      t =
        UpwashBands.new()
        |> feed(5.0, List.duplicate(4.0, 8))
        |> feed(7.0, List.duplicate(0.0, 8))

      snap = UpwashBands.snapshot(t)

      assert snap.backbone.b == 0.0
      # Equal counts and spreads: the pinned backbone is the plain mean.
      assert_in_delta snap.backbone.a, 2.0, 1.0e-9
    end

    test "the slope is clamped to ±0.7 °/(m/s)" do
      down =
        UpwashBands.new()
        |> feed(5.0, List.duplicate(4.0, 8))
        |> feed(9.0, List.duplicate(-4.0, 8))

      assert_in_delta UpwashBands.snapshot(down).backbone.b, -0.7, 1.0e-9

      up =
        UpwashBands.new()
        |> feed(5.0, List.duplicate(-4.0, 8))
        |> feed(9.0, List.duplicate(4.0, 8))

      assert_in_delta UpwashBands.snapshot(up).backbone.b, 0.7, 1.0e-9
    end
  end

  describe "shrinkage (k ≥ 2)" do
    test "a sparse band publishes once pooling tightens its posterior" do
      t =
        UpwashBands.new()
        |> feed(7.0, List.duplicate(2.0, 15))
        |> feed(11.0, List.duplicate(1.0, 3))

      snap = UpwashBands.snapshot(t)

      assert {11, v} = List.keyfind(snap.curve, 11, 0)
      assert_in_delta v, 1.0, 1.0e-6
    end

    test "the lightest band (center 3) needs 6 samples to publish even when pooled" do
      base =
        UpwashBands.new()
        |> feed(5.0, List.duplicate(2.0, 12))
        |> feed(9.0, List.duplicate(2.0, 12))

      t5 = feed(base, 3.0, List.duplicate(2.0, 5))
      refute List.keyfind(UpwashBands.snapshot(t5).curve, 3, 0)

      t6 = feed(t5, 3.0, [2.0])
      assert {3, v} = List.keyfind(UpwashBands.snapshot(t6).curve, 3, 0)
      assert_in_delta v, 2.0, 1.0e-6
    end

    test "a deviant (but unscreenable) middle band is shrunk toward the backbone" do
      t =
        UpwashBands.new()
        |> feed(5.0, List.duplicate(2.0, 8))
        |> feed(13.0, List.duplicate(-2.0, 8))
        # 2.5° raw at TWS 9: the curve interpolates 0.0 there, so this clears
        # the 3° screen floor but sits well off the backbone.
        |> feed(9.0, List.duplicate(2.5, 4))

      snap = UpwashBands.snapshot(t)

      assert {9, u9} = List.keyfind(snap.curve, 9, 0)
      m9 = snap.backbone.a + snap.backbone.b * (9 - 6.17)

      # Strictly between its own median and the backbone prediction.
      assert u9 < 2.5
      assert u9 > m9
    end
  end

  describe "shear-day screen" do
    test "inactive until two bands publish" do
      t = feed(UpwashBands.new(), 6.5, List.duplicate(2.0, 15))

      # 6° off the single published band: still accepted (no curve yet).
      assert {:accepted, _t} = UpwashBands.observe(t, 7.0, 8.0)
    end

    test "rejects a raw far from the interpolated curve and counts it" do
      t =
        UpwashBands.new()
        |> feed(5.0, List.duplicate(3.0, 8))
        |> feed(9.0, List.duplicate(1.0, 8))

      # Expected at TWS 7.0 is the midpoint 2.0; |8.0 − 2.0| = 6° > the 3° floor.
      assert {:screened, t} = UpwashBands.observe(t, 7.0, 8.0)

      snap = UpwashBands.snapshot(t)
      assert snap.screened == 1
      refute Map.has_key?(snap.bands, 7)

      # A raw within tolerance at the same TWS is accepted.
      assert {:accepted, _t} = UpwashBands.observe(t, 7.0, 2.5)
    end

    test "holds the edge value beyond the published range" do
      t =
        UpwashBands.new()
        |> feed(5.0, List.duplicate(3.0, 8))
        |> feed(9.0, List.duplicate(1.0, 8))

      # Above the range: expected holds at 1.0, so a 5.0 raw is 4° off → screened.
      assert {:screened, _t} = UpwashBands.observe(t, 12.5, 5.0)
      # Below the range: expected holds at 3.0, so a 3.5 raw is fine.
      assert {:accepted, _t} = UpwashBands.observe(t, 2.5, 3.5)
    end
  end

  describe "curve clamp" do
    test "published curve values are clamped to ±10°" do
      high = feed(UpwashBands.new(), 6.5, List.duplicate(15.0, 8))
      assert [{7, 10.0}] = UpwashBands.snapshot(high).curve

      low = feed(UpwashBands.new(), 6.5, List.duplicate(-15.0, 8))
      assert [{7, -10.0}] = UpwashBands.snapshot(low).curve
    end
  end
end
