defmodule RacingOrg.Tracker.Pro.Polar.LookupTest do
  @moduledoc """
  Property + example suite for the precomputed PCHIP (Fritsch–Carlson) polar
  interpolant.

  The 12 property GROUPS required by the spec are each tagged with a
  `describe "N. <name>"` block so the green summary maps one-to-one onto them.

  Property tests use `stream_data` (`ExUnitProperties`) to fan out over the
  whole input space (dense TWA × TWS scans, random samples); deterministic
  example tests pin the exact numeric guarantees (anchors, node interpolation,
  optima).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RacingOrg.Tracker.Pro.Polar
  alias RacingOrg.Tracker.Pro.Polar.Lookup

  # ORC-like reference fixture. TWS breakpoints in knots -> m/s. A realistic
  # close-hauled-to-run TWA grid, plus per-TWS beat/run VMG optima.
  @kt 0.514444

  # TWA grid (degrees) the speed cells are sampled at.
  @twa_grid [52.0, 60.0, 75.0, 90.0, 110.0, 120.0, 135.0, 150.0, 165.0, 180.0]

  # boat_speed (knots) per [tws_kt][twa] — monotone-ish realistic ORC numbers.
  @speed_kt %{
    6.0 => [4.6, 5.0, 5.5, 5.7, 5.6, 5.4, 5.0, 4.4, 3.6, 3.2],
    8.0 => [5.4, 5.8, 6.3, 6.6, 6.6, 6.4, 6.0, 5.4, 4.6, 4.1],
    10.0 => [5.9, 6.3, 6.9, 7.3, 7.4, 7.3, 6.9, 6.3, 5.5, 5.0],
    12.0 => [6.3, 6.7, 7.3, 7.8, 8.1, 8.0, 7.7, 7.1, 6.3, 5.8],
    14.0 => [6.6, 7.0, 7.6, 8.2, 8.7, 8.7, 8.5, 7.9, 7.1, 6.6],
    16.0 => [6.8, 7.3, 7.9, 8.6, 9.3, 9.4, 9.3, 8.8, 8.0, 7.5],
    20.0 => [7.2, 7.7, 8.4, 9.3, 10.4, 10.8, 11.0, 10.7, 9.9, 9.4]
  }

  # Per-TWS beat/run VMG optima (twa deg, vmg knots). Derived to be physically
  # consistent-ish with the speed grid (the optima bsp is recovered via VMG).
  @optima_kt %{
    6.0 => {43.0, 3.5, 150.0, 3.4},
    8.0 => {42.0, 4.2, 153.0, 4.2},
    10.0 => {41.0, 4.7, 156.0, 4.9},
    12.0 => {40.5, 5.1, 158.0, 5.6},
    14.0 => {40.0, 5.4, 160.0, 6.2},
    16.0 => {39.5, 5.6, 162.0, 6.9},
    20.0 => {39.0, 6.0, 165.0, 8.4}
  }

  @tws_breakpoints_kt [6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 20.0]

  defp kt(v), do: v * @kt

  # Build the %Polar{} fixture (SI units) from the knots tables.
  defp fixture_polar(opts) do
    include_optima = Keyword.get(opts, :optima, true)

    rows =
      for tws_kt <- @tws_breakpoints_kt do
        cells =
          @twa_grid
          |> Enum.zip(Map.fetch!(@speed_kt, tws_kt))
          |> Enum.map(fn {twa, bsp_kt} -> %{twa_deg: twa, boat_speed_mps: kt(bsp_kt)} end)

        %{tws_mps: kt(tws_kt), cells: cells}
      end

    optima =
      if include_optima do
        for tws_kt <- @tws_breakpoints_kt do
          {btwa, bvmg, rtwa, rvmg} = Map.fetch!(@optima_kt, tws_kt)

          %{
            tws_mps: kt(tws_kt),
            beat_twa: btwa,
            beat_vmg: kt(bvmg),
            run_twa: rtwa,
            run_vmg: kt(rvmg)
          }
        end
      else
        []
      end

    %Polar{polar_id: "orc-fixture", version: 1, rows: rows, optima: optima}
  end

  defp build!(opts \\ []) do
    {:ok, lk} = Lookup.build(fixture_polar(opts))
    lk
  end

  # Numeric derivative of boat_speed wrt twa (deg).
  defp dbsp_dtwa(lk, twa, tws, h \\ 1.0e-4) do
    {:ok, a} = Lookup.boat_speed(lk, twa - h, tws)
    {:ok, b} = Lookup.boat_speed(lk, twa + h, tws)
    (b - a) / (2 * h)
  end

  @tws_lo 6.0 * @kt
  @tws_hi 20.0 * @kt

  # float32 tolerance: the source values are float32-precision.
  @f32_tol 1.0e-3

  describe "1. anchor + non-negativity" do
    test "boat_speed(0deg, any tws) == 0.0" do
      lk = build!()

      for tws_kt <- 0..24 do
        assert {:ok, +0.0} = Lookup.boat_speed(lk, 0.0, kt(tws_kt * 1.0))
      end
    end

    property "dense [0,180] x [tws_range] scan yields NO negative speeds" do
      lk = build!()

      check all(
              twa <- float(min: 0.0, max: 180.0),
              tws <- float(min: 0.0, max: @tws_hi)
            ) do
        {:ok, v} = Lookup.boat_speed(lk, twa, tws)
        assert v >= -1.0e-9, "negative speed #{v} at twa=#{twa} tws=#{tws}"
      end
    end
  end

  describe "2. no overshoot" do
    property "samples between adjacent nodes stay within the bracketing node values" do
      lk = build!()
      tws = @tws_lo
      nodes = @twa_grid

      check all(
              i <- integer(0..(length(nodes) - 2)),
              frac <- float(min: 0.0, max: 1.0)
            ) do
        x0 = Enum.at(nodes, i)
        x1 = Enum.at(nodes, i + 1)
        {:ok, y0} = Lookup.boat_speed(lk, x0, tws)
        {:ok, y1} = Lookup.boat_speed(lk, x1, tws)
        x = x0 + frac * (x1 - x0)
        {:ok, y} = Lookup.boat_speed(lk, x, tws)
        lo = min(y0, y1) - 1.0e-6
        hi = max(y0, y1) + 1.0e-6
        assert y >= lo and y <= hi, "overshoot: y=#{y} not in [#{lo},#{hi}] (twa=#{x})"
      end
    end
  end

  describe "3. interpolating at grid nodes" do
    test "evaluating at a grid node returns that node's value (f32 tol)" do
      lk = build!(optima: false)

      for tws_kt <- @tws_breakpoints_kt do
        tws = kt(tws_kt)
        speeds = Map.fetch!(@speed_kt, tws_kt)

        for {twa, bsp_kt} <- Enum.zip(@twa_grid, speeds) do
          {:ok, v} = Lookup.boat_speed(lk, twa, tws)
          assert_in_delta v, kt(bsp_kt), @f32_tol
        end
      end
    end
  end

  describe "4. optima are honored as nodes" do
    test "optimum(tws_node).beat ~ provided beat_twa & derived bsp" do
      lk = build!()

      for tws_kt <- @tws_breakpoints_kt do
        tws = kt(tws_kt)
        {btwa, bvmg, rtwa, rvmg} = Map.fetch!(@optima_kt, tws_kt)
        {:ok, opt} = Lookup.optimum(lk, tws)

        assert_in_delta opt.beat.twa, btwa, 1.0e-3
        assert_in_delta opt.run.twa, rtwa, 1.0e-3

        # derived bsp = vmg / |cos(twa)|
        beat_bsp = kt(bvmg) / abs(:math.cos(btwa * :math.pi() / 180.0))
        run_bsp = kt(rvmg) / abs(:math.cos(rtwa * :math.pi() / 180.0))

        assert_in_delta opt.beat.bsp, beat_bsp, @f32_tol
        assert_in_delta opt.run.bsp, run_bsp, @f32_tol

        # boat_speed AT the optimum twa ~ derived bsp (optimum is an exact node)
        {:ok, b_at} = Lookup.boat_speed(lk, btwa, tws)
        {:ok, r_at} = Lookup.boat_speed(lk, rtwa, tws)
        assert_in_delta b_at, beat_bsp, @f32_tol
        assert_in_delta r_at, run_bsp, @f32_tol
      end
    end
  end

  describe "5. monotone rise 0 -> beat angle" do
    test "0deg up to beat twa is non-decreasing" do
      lk = build!()
      tws = @tws_lo
      {btwa, _, _, _} = Map.fetch!(@optima_kt, 6.0)

      samples =
        for t <- Stream.iterate(0.0, &(&1 + 0.5)) |> Enum.take(round(btwa / 0.5) + 1) do
          {:ok, v} = Lookup.boat_speed(lk, t, tws)
          v
        end

      samples
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] ->
        assert b >= a - 1.0e-6, "hump on the way up to the beat angle: #{a} -> #{b}"
      end)
    end
  end

  describe "6. zero end-slope at 0 and 180" do
    test "numerical derivative ~ 0 at 0deg and 180deg" do
      lk = build!()

      for tws_kt <- [6.0, 12.0, 20.0] do
        tws = kt(tws_kt)
        # Sample close to the boundary: the end tangent is clamped to exactly 0,
        # so the one-sided slope must vanish as twa -> 0 / 180.
        d0 = dbsp_dtwa(lk, 0.05, tws)
        d180 = dbsp_dtwa(lk, 179.95, tws)
        assert abs(d0) < 5.0e-3, "end slope at 0 not ~0: #{d0}"
        assert abs(d180) < 5.0e-3, "end slope at 180 not ~0: #{d180}"
      end
    end
  end

  describe "7. C1 continuity across node boundaries" do
    property "numerical derivative is continuous across nodes (no jump)" do
      lk = build!()
      interior = @twa_grid -- [List.first(@twa_grid), List.last(@twa_grid)]

      check all(
              node <- member_of(interior),
              tws <- float(min: @tws_lo, max: @tws_hi)
            ) do
        left = dbsp_dtwa(lk, node - 0.05, tws)
        right = dbsp_dtwa(lk, node + 0.05, tws)
        assert_in_delta left, right, 5.0e-2
      end
    end
  end

  describe "8. VMG tangent fallback (optima omitted)" do
    test "derived optimum matches the fixture's optimum within tolerance" do
      lk = build!(optima: false)

      for tws_kt <- @tws_breakpoints_kt do
        tws = kt(tws_kt)
        {btwa, _bvmg, rtwa, _rvmg} = Map.fetch!(@optima_kt, tws_kt)
        {:ok, opt} = Lookup.optimum(lk, tws)

        # The surface-derived VMG optimum should land near the fixture's optima.
        # This is an approximation: without the optima as nodes the surface only
        # knows the grid cells, so the VMG-tangent angle is close but not exact.
        assert_in_delta opt.beat.twa, btwa, 8.0
        assert_in_delta opt.run.twa, rtwa, 8.0

        # vmg = bsp * |cos(twa)| and should be positive.
        assert opt.beat.vmg > 0.0
        assert opt.run.vmg > 0.0
      end
    end
  end

  describe "9. TWS dimension" do
    test "tws=0 -> 0.0" do
      lk = build!()
      for twa <- [0.0, 45.0, 90.0, 135.0, 180.0], do: assert({:ok, +0.0} = Lookup.boat_speed(lk, twa, 0.0))
    end

    test "hold-last above the top TWS breakpoint" do
      lk = build!()

      for twa <- [45.0, 90.0, 135.0, 165.0] do
        {:ok, top} = Lookup.boat_speed(lk, twa, @tws_hi)
        {:ok, above} = Lookup.boat_speed(lk, twa, @tws_hi + kt(5.0))
        assert_in_delta above, top, 1.0e-9
      end
    end

    test "above-top query is flagged extrapolated; in-range is not" do
      lk = build!()
      assert {:ok, _v, %{extrapolated: false}} = Lookup.boat_speed_with_meta(lk, 90.0, @tws_lo)
      assert {:ok, _v, %{extrapolated: true}} = Lookup.boat_speed_with_meta(lk, 90.0, @tws_hi + kt(5.0))
    end

    property "between-row query lies between the two bracketing rows' values" do
      lk = build!()

      check all(
              i <- integer(0..(length(@tws_breakpoints_kt) - 2)),
              twa <- float(min: 50.0, max: 175.0),
              frac <- float(min: 0.0, max: 1.0)
            ) do
        tws0 = kt(Enum.at(@tws_breakpoints_kt, i))
        tws1 = kt(Enum.at(@tws_breakpoints_kt, i + 1))
        {:ok, y0} = Lookup.boat_speed(lk, twa, tws0)
        {:ok, y1} = Lookup.boat_speed(lk, twa, tws1)
        tws = tws0 + frac * (tws1 - tws0)
        {:ok, y} = Lookup.boat_speed(lk, twa, tws)
        lo = min(y0, y1) - 1.0e-6
        hi = max(y0, y1) + 1.0e-6
        assert y >= lo and y <= hi
      end
    end
  end

  describe "10. robustness" do
    test "empty polar -> build :error and lookups :error" do
      assert {:error, _} = Lookup.build(%Polar{rows: [], optima: []})
    end

    test "polar with only blank/non-usable rows -> :error" do
      bad = %Polar{rows: [%{tws_mps: 5.0, cells: []}], optima: []}
      assert {:error, _} = Lookup.build(bad)
    end

    test "single TWS row used for all TWS (no interpolation)" do
      single = %Polar{
        rows: [
          %{
            tws_mps: kt(10.0),
            cells:
              Enum.zip(@twa_grid, Map.fetch!(@speed_kt, 10.0))
              |> Enum.map(fn {a, s} -> %{twa_deg: a, boat_speed_mps: kt(s)} end)
          }
        ],
        optima: []
      }

      {:ok, lk} = Lookup.build(single)
      {:ok, lo} = Lookup.boat_speed(lk, 90.0, kt(4.0))
      {:ok, mid} = Lookup.boat_speed(lk, 90.0, kt(10.0))
      {:ok, hi} = Lookup.boat_speed(lk, 90.0, kt(25.0))
      assert_in_delta lo, mid, 1.0e-9
      assert_in_delta hi, mid, 1.0e-9
    end

    property "TWA folding by symmetry: twa>180 folds to 360-twa" do
      lk = build!()

      check all(
              twa <- float(min: 0.0, max: 180.0),
              tws <- float(min: @tws_lo, max: @tws_hi)
            ) do
        {:ok, a} = Lookup.boat_speed(lk, twa, tws)
        {:ok, b} = Lookup.boat_speed(lk, 360.0 - twa, tws)
        assert_in_delta a, b, 1.0e-9
      end
    end

    test "negative twa clamps to 0" do
      lk = build!()
      assert {:ok, +0.0} = Lookup.boat_speed(lk, -30.0, @tws_lo)
    end

    test "nonsensical cells skipped; non-numeric query -> :error" do
      # NOTE: BEAM float arithmetic *raises* on overflow and ETF decode rejects
      # Inf/NaN bit patterns, so a genuine IEEE Inf/NaN float cannot reach this
      # module at runtime. The reachable defensive cases are out-of-domain /
      # non-numeric values, which must be skipped (not poison the surface).
      poisoned = %Polar{
        rows: [
          %{
            tws_mps: kt(10.0),
            cells: [
              %{twa_deg: 45.0, boat_speed_mps: kt(5.0)},
              # negative speed (unphysical) -> skipped
              %{twa_deg: 90.0, boat_speed_mps: -3.0},
              # non-numeric value -> skipped
              %{twa_deg: 120.0, boat_speed_mps: :nan},
              %{twa_deg: 150.0, boat_speed_mps: kt(4.0)}
            ]
          }
        ],
        optima: []
      }

      {:ok, lk} = Lookup.build(poisoned)
      # surface stays finite/non-negative despite the poisoned cells.
      {:ok, v} = Lookup.boat_speed(lk, 100.0, kt(10.0))
      assert is_float(v) and v >= 0.0

      # non-numeric query angle -> :error, not a crash.
      assert :error = Lookup.boat_speed(lk, :nan, kt(10.0))
      assert :error = Lookup.boat_speed(lk, 90.0, :nan)
    end
  end

  describe "11. cusp (jib->spinnaker)" do
    test "a fixture with a downwind sail-change cusp does not overshoot" do
      # Sharp bump near 110-130 (spinnaker hoist) then drop — classic cusp.
      cells =
        [
          {52.0, 4.6},
          {90.0, 6.0},
          {110.0, 7.6},
          {120.0, 7.7},
          {130.0, 7.0},
          {150.0, 5.4},
          {180.0, 4.2}
        ]
        |> Enum.map(fn {a, s} -> %{twa_deg: a, boat_speed_mps: kt(s)} end)

      cusp = %Polar{rows: [%{tws_mps: kt(12.0), cells: cells}], optima: []}
      {:ok, lk} = Lookup.build(cusp)

      pairs = Enum.map(cells, fn c -> {c.twa_deg, c.boat_speed_mps} end)

      for [{x0, y0}, {x1, y1}] <- Enum.chunk_every(pairs, 2, 1, :discard) do
        lo = min(y0, y1) - 1.0e-6
        hi = max(y0, y1) + 1.0e-6

        for f <- 0..20 do
          x = x0 + f / 20 * (x1 - x0)
          {:ok, y} = Lookup.boat_speed(lk, x, kt(12.0))
          assert y >= lo and y <= hi, "cusp overshoot at twa=#{x}: #{y} not in [#{lo},#{hi}]"
        end
      end
    end
  end

  describe "12. perf sanity" do
    test "100k boat_speed/3 calls run well under bound; build is once" do
      lk = build!()
      n = 100_000

      # warm
      Enum.each(1..1000, fn _ -> Lookup.boat_speed(lk, 95.0, @tws_lo) end)

      {usec, :ok} =
        :timer.tc(fn ->
          Enum.reduce(1..n, :ok, fn i, _ ->
            twa = rem(i, 180) * 1.0
            tws = @tws_lo + rem(i, 14) * @kt
            {:ok, _} = Lookup.boat_speed(lk, twa, tws)
            :ok
          end)
        end)

      ms = usec / 1000.0
      per_call_us = usec / n
      # Generous CI bound; expect ~1us/call on a dev box.
      assert ms < 2000.0, "100k evals took #{ms}ms (#{per_call_us}us/call)"
      IO.puts("\n[perf] 100k boat_speed/3: #{Float.round(ms, 1)}ms (#{Float.round(per_call_us, 3)}us/call)")
    end

    test "boat_speed never rebuilds (no Polar fields needed at eval)" do
      lk = build!()
      # The compiled t must be self-contained: it carries no %Polar{} fields, so
      # the hot path cannot be re-deriving the surface from the source rows.
      assert lk.__struct__ == Lookup
      assert is_tuple(lk.curves) and is_tuple(lk.tws)
      refute Map.has_key?(lk, :rows)
      {:ok, _} = Lookup.boat_speed(lk, 90.0, @tws_lo)
    end
  end
end
