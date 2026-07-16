defmodule RacingOrg.Tracker.Pro.Calibration.EstimateTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Estimate

  defp feed(tracker, values), do: Enum.reduce(values, tracker, &Estimate.observe(&2, &1))

  describe "snapshot/1 while empty / learning" do
    test "starts with nil value, zero confidence, :learning" do
      snap = Estimate.new([]) |> Estimate.snapshot()

      assert %Estimate{} = snap
      assert snap.value == nil
      assert snap.spread == nil
      assert snap.confidence == 0.0
      assert snap.sample_count == 0
      assert snap.state == :learning
    end

    test "reports the running median and zero spread from constant observations" do
      snap = Estimate.new([]) |> feed(List.duplicate(2.5, 4)) |> Estimate.snapshot()

      assert_in_delta snap.value, 2.5, 1.0e-9
      assert_in_delta snap.spread, 0.0, 1.0e-9
      assert snap.sample_count == 4
    end

    test "integer raw estimates are accepted" do
      snap = Estimate.new([]) |> feed([3, 3, 3]) |> Estimate.snapshot()

      assert_in_delta snap.value, 3.0, 1.0e-9
    end
  end

  describe "validation" do
    test "stays :learning below min_samples even when perfectly stable" do
      tracker = Estimate.new(min_samples: 8, max_spread: 1.0, stability_window: 3)

      snaps =
        for n <- 1..7 do
          tracker |> feed(List.duplicate(1.0, n)) |> Estimate.snapshot()
        end

      assert Enum.all?(snaps, &(&1.state == :learning))
    end

    test "validates once samples, spread, and drift all hold" do
      snap =
        Estimate.new(min_samples: 8, max_spread: 1.0, stability_window: 3)
        |> feed(List.duplicate(1.0, 8))
        |> Estimate.snapshot()

      assert snap.state == :validated
      assert snap.confidence > 0.0 and snap.confidence <= 1.0
    end

    test "a wide inter-quartile spread blocks validation" do
      snap =
        Estimate.new(min_samples: 4, max_spread: 0.5, stability_window: 3, max_drift: 100.0)
        |> feed([0.0, 10.0, 0.0, 10.0, 0.0, 10.0, 0.0, 10.0])
        |> Estimate.snapshot()

      assert snap.state == :learning
      assert snap.spread > 0.5
    end

    test "drift in the recent window blocks validation" do
      tracker =
        Estimate.new(min_samples: 6, max_spread: 100.0, stability_window: 4, max_drift: 0.5)
        |> feed(List.duplicate(1.0, 8))

      assert Estimate.snapshot(tracker).state == :validated

      # A run of shifted estimates: the recent-window median drifts away from the
      # long-run median, so the tracker must fall back to :learning.
      drifted = feed(tracker, List.duplicate(4.0, 4))
      snap = Estimate.snapshot(drifted)

      assert snap.state == :learning
    end
  end

  describe "applied_value/3 (promotion: clamp + slew)" do
    defp validated_tracker(value, opts) do
      defaults = [min_samples: 4, max_spread: 1.0, stability_window: 3]

      Estimate.new(Keyword.merge(defaults, opts))
      |> feed(List.duplicate(value, 6))
    end

    test "holds the previous applied value while :learning" do
      tracker = Estimate.new(min_samples: 8) |> feed([5.0, 5.0])

      assert {held, ^tracker} = Estimate.applied_value(tracker, 0.0)
      assert held == 0.0
    end

    test "slew-limits successive moves to max_slew per call" do
      tracker = validated_tracker(5.0, clamp_min: -10.0, clamp_max: 10.0, max_slew: 0.5)

      {v1, tracker} = Estimate.applied_value(tracker, 0.0)
      assert_in_delta v1, 0.5, 1.0e-9

      {v2, tracker} = Estimate.applied_value(tracker, v1)
      assert_in_delta v2, 1.0, 1.0e-9

      # Never overshoots: from just under the target it lands exactly on it.
      {v3, _tracker} = Estimate.applied_value(tracker, 4.8)
      assert_in_delta v3, 5.0, 1.0e-9
    end

    test "slew-limits downward moves symmetrically" do
      tracker = validated_tracker(-5.0, clamp_min: -10.0, clamp_max: 10.0, max_slew: 0.5)

      {v1, _tracker} = Estimate.applied_value(tracker, 0.0)
      assert_in_delta v1, -0.5, 1.0e-9
    end

    test "clamps the target to [clamp_min, clamp_max]" do
      tracker = validated_tracker(15.0, clamp_min: -10.0, clamp_max: 10.0, max_slew: 100.0)

      {v, _tracker} = Estimate.applied_value(tracker, 9.0)
      assert_in_delta v, 10.0, 1.0e-9

      low = validated_tracker(-15.0, clamp_min: -10.0, clamp_max: 10.0, max_slew: 100.0)
      {v_low, _} = Estimate.applied_value(low, -9.0)
      assert_in_delta v_low, -10.0, 1.0e-9
    end

    test "call-site opts override the tracker's promotion opts" do
      tracker = validated_tracker(5.0, clamp_min: -10.0, clamp_max: 10.0, max_slew: 0.5)

      {v, _tracker} = Estimate.applied_value(tracker, 0.0, max_slew: 2.0, clamp_max: 1.5)
      assert_in_delta v, 1.5, 1.0e-9
    end

    test "reaches the (clamped) target across repeated calls" do
      tracker = validated_tracker(2.0, clamp_min: -10.0, clamp_max: 10.0, max_slew: 0.5)

      final =
        Enum.reduce(1..10, 0.0, fn _, prev ->
          {v, _} = Estimate.applied_value(tracker, prev)
          v
        end)

      assert_in_delta final, 2.0, 1.0e-9
    end
  end

  describe "confidence" do
    test "grows with sample count and stays within 0..1" do
      tracker = Estimate.new(min_samples: 8, max_spread: 1.0)

      confidences =
        for n <- [1, 4, 8, 16] do
          tracker |> feed(List.duplicate(1.0, n)) |> Estimate.snapshot() |> Map.fetch!(:confidence)
        end

      assert confidences == Enum.sort(confidences)
      assert Enum.all?(confidences, &(&1 >= 0.0 and &1 <= 1.0))
      assert List.last(confidences) == 1.0
    end

    test "is lower for noisy estimates than for tight ones" do
      tight =
        Estimate.new(min_samples: 4, max_spread: 1.0)
        |> feed(List.duplicate(1.0, 8))
        |> Estimate.snapshot()

      noisy =
        Estimate.new(min_samples: 4, max_spread: 1.0)
        |> feed([0.6, 1.4, 0.5, 1.5, 0.6, 1.4, 0.5, 1.5])
        |> Estimate.snapshot()

      assert noisy.confidence < tight.confidence
    end
  end
end
