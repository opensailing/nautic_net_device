Code.require_file(Path.expand("../synthetic_helper.exs", __DIR__))

defmodule RacingOrg.Tracker.Pro.Calibration.Estimator.StwScaleTest do
  @moduledoc """
  Synthetic-recovery tests for `Estimator.StwScale`. Injection: the speedo
  under-reads by the gain error g (`stw_meas = stw_true / g`), so the recovered
  multiplicative correction must be exactly g. Reciprocal courses cancel a uniform
  current to first order: exactly for along-track current, to O((c/stw)²) for
  crossing current.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Estimate
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.StwScale
  alias RacingOrg.Tracker.Pro.Calibration.Synthetic

  defp observe_pairs(estimator, pairs),
    do: Enum.reduce(pairs, estimator, &StwScale.observe_pair(&2, &1))

  defp band(snapshot, center), do: Map.fetch!(snapshot.bands, center)

  describe "gain recovery through current" do
    test "along-track current of 0.5 m/s cancels exactly: recovers 1.05 ± 0.01" do
      # stw_true 4.0, g 1.05 → stw_meas ≈ 3.81 → pair-mean band [2, 4) → center 3.
      pairs =
        for _ <- 1..10 do
          Synthetic.reciprocal_pair(
            heading: 0.0,
            stw: 4.0,
            gain: 1.05,
            current_speed: 0.5,
            current_toward_deg: 0.0
          )
        end

      snapshot = StwScale.new() |> observe_pairs(pairs) |> StwScale.snapshot()
      %{rls: theta, estimate: estimate} = band(snapshot, 3)

      assert_in_delta theta, 1.05, 0.01
      assert_in_delta estimate.value, 1.05, 0.001
      assert estimate.state == :validated

      assert [{3, applied}] = StwScale.gain_curve(StwScale.new() |> observe_pairs(pairs))
      assert_in_delta applied, 1.05, 0.01
    end

    test "crossing current of 0.5 m/s still recovers to first order: 1.05 ± 0.01" do
      pairs =
        for _ <- 1..10 do
          Synthetic.reciprocal_pair(
            heading: 0.0,
            stw: 4.0,
            gain: 1.05,
            current_speed: 0.5,
            current_toward_deg: 90.0
          )
        end

      %{rls: theta, estimate: estimate} =
        StwScale.new() |> observe_pairs(pairs) |> StwScale.snapshot() |> band(3)

      assert_in_delta theta, 1.05, 0.01
      assert_in_delta estimate.value, 1.05, 0.01
    end
  end

  describe "validation" do
    test "5 pairs stay :learning and produce an empty gain curve" do
      pairs = for _ <- 1..5, do: Synthetic.reciprocal_pair(stw: 4.0, gain: 1.05)
      estimator = StwScale.new() |> observe_pairs(pairs)

      %{estimate: estimate} = estimator |> StwScale.snapshot() |> band(3)
      assert %Estimate{state: :learning} = estimate
      assert StwScale.gain_curve(estimator) == []
    end

    test "6 pairs validate the band (min_samples default 6)" do
      pairs = for _ <- 1..6, do: Synthetic.reciprocal_pair(stw: 4.0, gain: 1.05)

      %{estimate: estimate} =
        StwScale.new() |> observe_pairs(pairs) |> StwScale.snapshot() |> band(3)

      assert %Estimate{state: :validated} = estimate
    end
  end

  describe "clamping" do
    test "an absurd gain error of 1.4 clamps the applied gain at 1.2" do
      pairs = for _ <- 1..8, do: Synthetic.reciprocal_pair(stw: 4.0, gain: 1.4)
      estimator = StwScale.new() |> observe_pairs(pairs)

      # The band center follows the MEASURED pair-mean stw: 4.0/1.4 ≈ 2.86 → center 3.
      assert [{3, applied}] = StwScale.gain_curve(estimator)
      assert_in_delta applied, 1.2, 1.0e-9
    end

    test "a low gain error of 0.7 clamps the applied gain at 0.8" do
      pairs = for _ <- 1..8, do: Synthetic.reciprocal_pair(stw: 4.0, gain: 0.7)
      estimator = StwScale.new() |> observe_pairs(pairs)

      # 4.0/0.7 ≈ 5.71 → band [4, 6) → center 5.
      assert [{5, applied}] = StwScale.gain_curve(estimator)
      assert_in_delta applied, 0.8, 1.0e-9
    end
  end

  describe "speed banding" do
    test "pairs land in bands by measured pair-mean stw, independently per band" do
      # Measured stw is what the device bands on: 1.5/1.02 ≈ 1.47 → center 1;
      # 9.5/1.08 ≈ 8.80 → center 9.
      slow = for _ <- 1..6, do: Synthetic.reciprocal_pair(stw: 1.5, gain: 1.02)
      fast = for _ <- 1..6, do: Synthetic.reciprocal_pair(stw: 9.5, gain: 1.08)

      snapshot = StwScale.new() |> observe_pairs(slow ++ fast) |> StwScale.snapshot()

      assert Map.keys(snapshot.bands) |> Enum.sort() == [1, 9]
      assert_in_delta band(snapshot, 1).estimate.value, 1.02, 0.001
      assert_in_delta band(snapshot, 9).estimate.value, 1.08, 0.001
    end

    test "gain_curve is sorted by band center" do
      slow = for _ <- 1..8, do: Synthetic.reciprocal_pair(stw: 1.5, gain: 1.02)
      fast = for _ <- 1..8, do: Synthetic.reciprocal_pair(stw: 9.5, gain: 1.08)

      curve = StwScale.new() |> observe_pairs(fast ++ slow) |> StwScale.gain_curve()

      assert [{1, g1}, {9, g9}] = curve
      assert_in_delta g1, 1.02, 0.01
      assert_in_delta g9, 1.08, 0.01
    end
  end

  describe "input hygiene" do
    test "pairs with a near-zero stw sum are rejected (guard > 0.5 m/s)" do
      pairs = for _ <- 1..6, do: Synthetic.reciprocal_pair(stw: 0.2, gain: 1.05)

      snapshot = StwScale.new() |> observe_pairs(pairs) |> StwScale.snapshot()

      assert snapshot.bands == %{}
    end

    test "pairs with missing sog are rejected" do
      good = Synthetic.reciprocal_pair(stw: 4.0, gain: 1.05)
      bad = %{good | a: %{good.a | sog_mean: nil}}

      snapshot = StwScale.new() |> StwScale.observe_pair(bad) |> StwScale.snapshot()

      assert snapshot.bands == %{}
    end
  end
end
