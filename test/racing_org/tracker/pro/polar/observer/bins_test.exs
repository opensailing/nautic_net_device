defmodule RacingOrg.Tracker.Pro.Polar.Observer.BinsTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Polar.Observer.Bins

  # 1 knot in m/s — the default TWS bin width.
  @kt 0.514444

  describe "new/1 defaults and config" do
    test "defaults: 5-degree TWA bins, 1-knot TWS bins (expressed in m/s)" do
      b = Bins.new()
      assert_in_delta b.twa_width_deg, 5.0, 1.0e-9
      assert_in_delta b.tws_width_mps, @kt, 1.0e-6
    end

    test "widths are configurable" do
      b = Bins.new(twa_width_deg: 10.0, tws_width_mps: 2.0)
      assert b.twa_width_deg == 10.0
      assert b.tws_width_mps == 2.0
    end
  end

  describe "TWA folding (port/starboard merge into [0,180])" do
    test "folds 200 deg -> 160" do
      assert_in_delta Bins.fold_twa(200.0), 160.0, 1.0e-9
    end

    test "folds -30 deg -> 30" do
      assert_in_delta Bins.fold_twa(-30.0), 30.0, 1.0e-9
    end

    test "folds 270 (i.e. -90 equiv) -> 90" do
      assert_in_delta Bins.fold_twa(270.0), 90.0, 1.0e-9
    end

    test "wraps beyond 360 then folds: 540 -> 180, 390 -> 30" do
      assert_in_delta Bins.fold_twa(540.0), 180.0, 1.0e-9
      assert_in_delta Bins.fold_twa(390.0), 30.0, 1.0e-9
    end

    test "leaves an in-range value untouched" do
      assert_in_delta Bins.fold_twa(123.0), 123.0, 1.0e-9
    end
  end

  describe "cell/3 -> canonical {tws_idx, twa_idx} key" do
    test "maps a sample to floor-indexed bins" do
      b = Bins.new(twa_width_deg: 5.0, tws_width_mps: 1.0)
      # tws = 5.4 m/s -> idx 5 ; twa = 47 deg -> idx 9
      assert Bins.cell(b, 5.4, 47.0) == {5, 9}
    end

    test "folds TWA before binning (negative / >180)" do
      b = Bins.new(twa_width_deg: 5.0, tws_width_mps: 1.0)
      # -47 folds to 47 -> idx 9 ; 313 folds to 47 -> idx 9
      assert Bins.cell(b, 5.4, -47.0) == {5, 9}
      assert Bins.cell(b, 5.4, 313.0) == {5, 9}
    end

    test "lower bin edge is inclusive (boundary lands in the upper bin)" do
      b = Bins.new(twa_width_deg: 5.0, tws_width_mps: 1.0)
      # exactly 45.0 -> idx 9 (the bin [45,50)); 44.999 -> idx 8
      assert Bins.cell(b, 3.0, 45.0) == {3, 9}
      assert Bins.cell(b, 3.0, 44.999) == {3, 8}
    end

    test "TWA exactly 180 lands in the top bin (clamped, not a new bin)" do
      b = Bins.new(twa_width_deg: 5.0, tws_width_mps: 1.0)
      # 180/5 = 36 would be an out-of-range index; it must clamp to bin 35
      # ([175,180]) so 180 doesn't create an empty singleton bin.
      assert Bins.cell(b, 3.0, 180.0) == {3, 35}
    end

    test "negative or zero TWS clamps to bin 0" do
      b = Bins.new(twa_width_deg: 5.0, tws_width_mps: 1.0)
      assert Bins.cell(b, 0.0, 90.0) == {0, 18}
      assert Bins.cell(b, -1.0, 90.0) == {0, 18}
    end

    test "default knot-width TWS binning is unit-correct" do
      b = Bins.new()
      # 3 knots in m/s should land in TWS bin index 3.
      assert {3, _} = Bins.cell(b, 3.0 * @kt, 90.0)
      # 2.5 knots -> bin 2 (floor)
      assert {2, _} = Bins.cell(b, 2.5 * @kt, 90.0)
    end
  end

  describe "center/2 -> representative (tws_mps, twa_deg) of a cell" do
    test "bin center is (idx + 0.5) * width" do
      b = Bins.new(twa_width_deg: 5.0, tws_width_mps: 1.0)
      {tws_c, twa_c} = Bins.center(b, {5, 9})
      assert_in_delta tws_c, 5.5, 1.0e-9
      assert_in_delta twa_c, 47.5, 1.0e-9
    end

    test "cell -> center -> cell is a fixed point" do
      b = Bins.new(twa_width_deg: 5.0, tws_width_mps: 1.0)
      key = Bins.cell(b, 7.3, 121.0)
      {tws_c, twa_c} = Bins.center(b, key)
      assert Bins.cell(b, tws_c, twa_c) == key
    end

    test "default-width center reports in m/s and degrees" do
      b = Bins.new()
      {tws_c, twa_c} = Bins.center(b, {3, 9})
      assert_in_delta tws_c, 3.5 * @kt, 1.0e-6
      assert_in_delta twa_c, 47.5, 1.0e-9
    end
  end

  describe "populated-cell enumeration over a map keyed by cell" do
    test "enumerates populated cells with their centers" do
      b = Bins.new(twa_width_deg: 5.0, tws_width_mps: 1.0)
      cells = %{{5, 9} => :a, {3, 18} => :b}

      result = Bins.populated(b, cells) |> Enum.sort()

      assert result == [
               {{3, 18}, {3.5, 92.5}, :b},
               {{5, 9}, {5.5, 47.5}, :a}
             ]
    end

    test "empty map yields no cells" do
      assert Bins.populated(Bins.new(), %{}) == []
    end
  end
end
