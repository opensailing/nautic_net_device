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

    test "defaults carry a finite TWS ceiling of 100 knots" do
      b = Bins.new()
      assert_in_delta b.max_tws_mps, 100.0 * @kt, 1.0e-6
      assert_in_delta Bins.max_tws_mps(), 100.0 * @kt, 1.0e-6
    end

    test "the TWS ceiling is configurable and must be positive and finite" do
      assert Bins.new(max_tws_mps: 30.0).max_tws_mps == 30.0
      assert_raise ArgumentError, fn -> Bins.new(max_tws_mps: 0.0) end
      assert_raise ArgumentError, fn -> Bins.new(max_tws_mps: -1.0) end
      assert_raise ArgumentError, fn -> Bins.new(max_tws_mps: :lots) end
    end
  end

  describe "operating domain (fail-closed, bounded key space)" do
    setup do
      %{b: Bins.new(twa_width_deg: 5.0, tws_width_mps: 1.0, max_tws_mps: 51.4444)}
    end

    test "in-domain samples resolve to a cell", %{b: b} do
      assert {:ok, {5, 9}} = Bins.fetch_cell(b, 5.4, 47.0)
      assert Bins.in_domain?(b, 5.4, 47.0)
    end

    test "TWS 0 (dead calm) is IN domain and bins to 0", %{b: b} do
      assert {:ok, {0, 18}} = Bins.fetch_cell(b, 0.0, 90.0)
    end

    test "TWS exactly at the ceiling is IN domain and stays in the LAST bin", %{b: b} do
      # The closed top edge must clamp into the final bin, exactly like TWA 180 —
      # it must NOT spawn a new index one past the end of the bounded key space.
      assert {:ok, {51, 18}} = Bins.fetch_cell(b, 51.4444, 90.0)
      assert {:ok, {51, 18}} = Bins.fetch_cell(b, 51.4, 90.0)
    end

    test "TWS above the ceiling is REJECTED, not clamped into the top bin", %{b: b} do
      # Clamping would silently fold a broken sensor's reading into the highest
      # REAL wind bin and poison a legitimate learned cell. Fail closed instead.
      assert {:error, :tws_out_of_domain} = Bins.fetch_cell(b, 51.5, 90.0)
      assert {:error, :tws_out_of_domain} = Bins.fetch_cell(b, 200.0, 90.0)
      refute Bins.in_domain?(b, 200.0, 90.0)
    end

    test "an absurd TWS cannot mint an absurd key", %{b: b} do
      # Each of these previously produced a distinct, arbitrarily large tws_idx —
      # an unbounded cell key straight out of one bad sample.
      for tws <- [1.0e6, 1.0e9, 1.0e15, 1.0e100] do
        assert {:error, :tws_out_of_domain} = Bins.fetch_cell(b, tws, 90.0)
      end
    end

    test "a near-overflow TWS is rejected cleanly rather than raising", %{b: b} do
      # tws / width overflows to +Inf for a large enough tws, which raised
      # ArithmeticError from inside the binning math. The domain check runs first.
      assert {:error, :tws_out_of_domain} = Bins.fetch_cell(b, 1.0e308, 90.0)
    end

    test "negative TWS is REJECTED, not clamped to bin 0", %{b: b} do
      assert {:error, :tws_out_of_domain} = Bins.fetch_cell(b, -0.001, 90.0)
      assert {:error, :tws_out_of_domain} = Bins.fetch_cell(b, -1.0, 90.0)
      assert {:error, :tws_out_of_domain} = Bins.fetch_cell(b, -1.0e15, 90.0)
    end

    test "non-numeric / missing TWS is rejected (no FunctionClauseError)", %{b: b} do
      for tws <- [nil, :nan, "6.0", %{}] do
        assert {:error, :tws_out_of_domain} = Bins.fetch_cell(b, tws, 90.0)
      end
    end

    test "TWA within a full turn either way is in domain and folds as before", %{b: b} do
      assert {:ok, {5, 9}} = Bins.fetch_cell(b, 5.4, -47.0)
      assert {:ok, {5, 9}} = Bins.fetch_cell(b, 5.4, 313.0)
      assert {:ok, {5, _}} = Bins.fetch_cell(b, 5.4, 360.0)
      assert {:ok, {5, _}} = Bins.fetch_cell(b, 5.4, -360.0)
    end

    test "TWA beyond a full turn either way is REJECTED, not silently wrapped", %{b: b} do
      # Nothing on the wire produces a wind angle outside +/-360; a value that does
      # is a broken/garbage reading, and wrapping it would alias it onto a valid
      # angle and poison that cell.
      assert {:error, :twa_out_of_domain} = Bins.fetch_cell(b, 5.4, 361.0)
      assert {:error, :twa_out_of_domain} = Bins.fetch_cell(b, 5.4, -361.0)
      assert {:error, :twa_out_of_domain} = Bins.fetch_cell(b, 5.4, 1.0e15)
      assert {:error, :twa_out_of_domain} = Bins.fetch_cell(b, 5.4, 1.0e308)
    end

    test "non-numeric / missing TWA is rejected (no FunctionClauseError)", %{b: b} do
      for twa <- [nil, :nan, "90", []] do
        assert {:error, :twa_out_of_domain} = Bins.fetch_cell(b, 5.4, twa)
      end
    end

    test "TWS is checked before TWA (stable reason precedence)", %{b: b} do
      assert {:error, :tws_out_of_domain} = Bins.fetch_cell(b, -1.0, 9999.0)
    end
  end

  describe "bounded key space" do
    test "the default binning admits at most 100 x 36 cells" do
      b = Bins.new()
      assert Bins.max_key(b) == {99, 35}
    end

    test "every in-domain sample lands inside the declared key bound" do
      b = Bins.new()
      {max_tws_idx, max_twa_idx} = Bins.max_key(b)

      keys =
        for tws <- Enum.map(0..1000, &(&1 * b.max_tws_mps / 1000.0)),
            twa <- Enum.map(-360..360//7, &(&1 * 1.0)) do
          assert {:ok, {ti, ai} = key} = Bins.fetch_cell(b, tws, twa)
          assert ti >= 0 and ti <= max_tws_idx
          assert ai >= 0 and ai <= max_twa_idx
          assert Bins.valid_key?(b, key)
          key
        end

      assert MapSet.size(MapSet.new(keys)) <= (max_tws_idx + 1) * (max_twa_idx + 1)
    end

    test "a width too fine to index refuses construction instead of raising later" do
      # `max_key/1` divides the axis extent by the bin width. A finite but
      # unboundedly small width overflows that division to +Inf, which raises
      # ArithmeticError on the BEAM — and it would raise from `max_key/1`,
      # `valid_key?/2`, and every restore path that screens persisted keys,
      # far from the misconfiguration that caused it. Reject it at the source.
      for width <- [1.0e-320, 5.0e-324, 1.0e-8] do
        assert_raise ArgumentError, fn -> Bins.new(tws_width_mps: width) end
        assert_raise ArgumentError, fn -> Bins.new(twa_width_deg: width) end
      end

      assert_raise ArgumentError, fn -> Bins.new(max_tws_mps: 1.7976931348623157e308) end

      # The finest grid that still fits the u32 index space stays constructible,
      # and every key-space query on it answers without raising.
      b = Bins.new(tws_width_mps: 1.2e-8, twa_width_deg: 4.2e-8, max_tws_mps: 51.4444)
      {max_tws_idx, max_twa_idx} = Bins.max_key(b)
      assert max_tws_idx <= 0xFFFF_FFFF
      assert max_twa_idx <= 0xFFFF_FFFF
      assert Bins.valid_key?(b, {0, 0})
      refute Bins.valid_key?(b, {max_tws_idx + 1, 0})
    end

    test "admits the exact geometry whose largest index is u32_max, and nothing finer" do
      # The index space is 0..u32_max, so the admissible BIN COUNT is u32_max + 1.
      # The exact boundary width is the one that fills it precisely; its largest
      # index must land on u32_max, not one short of it and not one past it.
      exact_twa = 180.0 / (0xFFFF_FFFF + 1)
      exact_tws = 51.4444 / (0xFFFF_FFFF + 1)

      b = Bins.new(twa_width_deg: exact_twa, tws_width_mps: exact_tws, max_tws_mps: 51.4444)
      assert Bins.max_key(b) == {0xFFFF_FFFF, 0xFFFF_FFFF}

      # One step finer overflows the index space and must fail closed.
      assert_raise ArgumentError, fn -> Bins.new(twa_width_deg: exact_twa / 2) end

      assert_raise ArgumentError, fn ->
        Bins.new(tws_width_mps: exact_tws / 2, max_tws_mps: 51.4444)
      end
    end

    test "an unrepresentably large integer extent or width is an ArgumentError, not ArithmeticError" do
      # `finite_number?/1` treats EVERY integer as finite, but an integer beyond
      # the float range raises ArithmeticError the moment `+ 0.0` converts it —
      # leaking a raw arithmetic fault out of a constructor that documents
      # ArgumentError for bad geometry.
      huge = 10 ** 400

      assert_raise ArgumentError, fn -> Bins.new(max_tws_mps: huge) end
      assert_raise ArgumentError, fn -> Bins.new(tws_width_mps: huge) end
      assert_raise ArgumentError, fn -> Bins.new(twa_width_deg: huge) end
      assert_raise ArgumentError, fn -> Bins.new(max_tws_mps: -huge) end

      # Ordinary integer options keep converting to floats exactly as before.
      assert Bins.new(tws_width_mps: 1, max_tws_mps: 30).tws_width_mps == 1.0
      assert Bins.new(tws_width_mps: 1, max_tws_mps: 30).max_tws_mps == 30.0
      assert Bins.new(twa_width_deg: 5).twa_width_deg == 5.0
    end

    test "valid_key?/2 rejects keys outside the bound (poisoned/restored state)" do
      b = Bins.new()
      refute Bins.valid_key?(b, {100, 0})
      refute Bins.valid_key?(b, {0, 36})
      refute Bins.valid_key?(b, {-1, 0})
      refute Bins.valid_key?(b, {0, -1})
      refute Bins.valid_key?(b, {1_943_846_171, 18})
      refute Bins.valid_key?(b, {:x, 1})
      refute Bins.valid_key?(b, :not_a_key)
      assert Bins.valid_key?(b, {99, 35})
      assert Bins.valid_key?(b, {0, 0})
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

    test "zero TWS is in-domain and lands in bin 0" do
      b = Bins.new(twa_width_deg: 5.0, tws_width_mps: 1.0)
      assert Bins.cell(b, 0.0, 90.0) == {0, 18}
    end

    test "cell/3 RAISES on an out-of-domain sample instead of minting a bad key" do
      # Clamping an impossible wind speed into a real bin would fold a broken
      # sensor reading into legitimate learned state. cell/3 fails closed; callers
      # that must not crash use fetch_cell/3.
      b = Bins.new(twa_width_deg: 5.0, tws_width_mps: 1.0, max_tws_mps: 51.4444)
      assert_raise ArgumentError, fn -> Bins.cell(b, -1.0, 90.0) end
      assert_raise ArgumentError, fn -> Bins.cell(b, 1.0e15, 90.0) end
      assert_raise ArgumentError, fn -> Bins.cell(b, 6.0, 1.0e15) end
      assert_raise ArgumentError, fn -> Bins.cell(b, nil, 90.0) end
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

    test "truncated closed top bins report an in-domain midpoint" do
      b = Bins.new(twa_width_deg: 140.0, tws_width_mps: 7.0, max_tws_mps: 10.0)
      assert Bins.max_key(b) == {1, 1}

      {tws_c, twa_c} = Bins.center(b, {1, 1})
      assert_in_delta tws_c, 8.5, 1.0e-9
      assert_in_delta twa_c, 160.0, 1.0e-9
      assert tws_c <= b.max_tws_mps
      assert twa_c <= 180.0
      assert Bins.cell(b, tws_c, twa_c) == {1, 1}
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
