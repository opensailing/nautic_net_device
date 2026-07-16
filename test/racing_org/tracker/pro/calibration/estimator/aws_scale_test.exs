defmodule RacingOrg.Tracker.Pro.Calibration.Estimator.AwsScaleTest do
  @moduledoc """
  Tests for the SHADOW-ONLY `Estimator.AwsScale` diagnostic: a binned
  TWS-consistency check whose down/up ratio is only meaningful within a
  near-in-time window (2 h rolling by leg end time).
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Estimate
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.AwsScale

  defp leg(awa_abs, tws, t_end_s) do
    %{
      duration_s: 120.0,
      samples: 120,
      side: :starboard,
      heading_mean: 0.0,
      cog_mean: 0.0,
      sog_mean: 4.0,
      stw_mean: 4.0,
      awa_mean_signed: awa_abs,
      awa_abs_mean: awa_abs,
      aws_mean: tws + 2.0,
      tws_mean: tws,
      heel_mean: nil,
      t_end_s: t_end_s
    }
  end

  defp observe_legs(estimator, legs),
    do: Enum.reduce(legs, estimator, &AwsScale.observe_leg(&2, &1))

  describe "downwind/upwind TWS ratio within a session" do
    test "recovers the ratio once both regimes have enough near-in-time legs" do
      # Upwind legs imply TWS 6.0, downwind legs imply 6.6 → ratio 1.1: the
      # downwind TWS reads 10% high relative to upwind, all within minutes.
      legs =
        Enum.flat_map(0..4, fn i ->
          [leg(40.0, 6.0, i * 600.0), leg(150.0, 6.6, i * 600.0 + 300.0)]
        end)

      snapshot = AwsScale.new() |> observe_legs(legs) |> AwsScale.snapshot()

      assert %Estimate{} = snapshot.downwind_over_upwind_ratio
      assert_in_delta snapshot.downwind_over_upwind_ratio.value, 1.1, 0.001
      assert snapshot.regimes.upwind.count == 5
      assert snapshot.regimes.downwind.count == 5
    end

    test "reports no ratio before both regimes have min_legs in the window" do
      legs = [leg(40.0, 6.0, 0.0), leg(40.0, 6.0, 300.0), leg(150.0, 6.6, 600.0)]

      snapshot = AwsScale.new() |> observe_legs(legs) |> AwsScale.snapshot()

      assert snapshot.downwind_over_upwind_ratio.value == nil
      assert snapshot.downwind_over_upwind_ratio.sample_count == 0
    end
  end

  describe "the 2 h rolling window" do
    test "legs older than the window are pruned and cannot skew the ratio" do
      # A stale morning session in a gale (TWS 20) must not be compared against
      # the afternoon's light air: wind strength correlates with course choices.
      stale = for i <- 0..2, do: leg(40.0, 20.0, i * 300.0)

      fresh =
        Enum.flat_map(0..3, fn i ->
          [leg(40.0, 6.0, 10_000.0 + i * 600.0), leg(150.0, 6.6, 10_300.0 + i * 600.0)]
        end)

      snapshot = AwsScale.new() |> observe_legs(stale ++ fresh) |> AwsScale.snapshot()

      assert_in_delta snapshot.downwind_over_upwind_ratio.value, 1.1, 0.001
      assert snapshot.regimes.upwind.count == 4
      assert_in_delta snapshot.regimes.upwind.median_tws, 6.0, 1.0e-9
    end
  end

  describe "regime binning" do
    test "reach legs (70–120°) are tracked separately and excluded from the ratio" do
      legs =
        Enum.flat_map(0..3, fn i ->
          base = i * 900.0
          [leg(40.0, 6.0, base), leg(90.0, 9.9, base + 300.0), leg(150.0, 6.6, base + 600.0)]
        end)

      snapshot = AwsScale.new() |> observe_legs(legs) |> AwsScale.snapshot()

      assert snapshot.regimes.reach.count == 4
      assert_in_delta snapshot.regimes.reach.median_tws, 9.9, 1.0e-9
      # The wild reach values must not leak into the down/up ratio.
      assert_in_delta snapshot.downwind_over_upwind_ratio.value, 1.1, 0.001
    end

    test "boundary angles: 70° bins upwind, 120° bins downwind" do
      legs = [leg(70.0, 6.0, 0.0), leg(120.0, 6.6, 300.0)]

      snapshot = AwsScale.new() |> observe_legs(legs) |> AwsScale.snapshot()

      assert snapshot.regimes.upwind.count == 1
      assert snapshot.regimes.downwind.count == 1
      assert snapshot.regimes.reach.count == 0
    end
  end

  describe "input hygiene" do
    test "legs without a t_end_s cannot be placed in time and are skipped" do
      bare = leg(40.0, 6.0, 0.0) |> Map.delete(:t_end_s)

      snapshot = AwsScale.new() |> AwsScale.observe_leg(bare) |> AwsScale.snapshot()

      assert snapshot.regimes.upwind.count == 0
    end

    test "an explicit end time can be passed instead of the leg key" do
      bare = leg(40.0, 6.0, 0.0) |> Map.delete(:t_end_s)

      snapshot = AwsScale.new() |> AwsScale.observe_leg(bare, 123.0) |> AwsScale.snapshot()

      assert snapshot.regimes.upwind.count == 1
    end
  end
end
