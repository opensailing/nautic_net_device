defmodule RacingOrg.Tracker.Pro.WindShift.PeriodTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WindShift.Period

  @two_pi 2.0 * :math.pi()

  test "a clean 480 s sinusoid is recovered within +/-30 s with high confidence" do
    :rand.seed(:exsss, {1, 2, 3})
    residuals = sinusoid(10.0, 480.0, 2700, 1.5)

    assert %{period_s: period_s, confidence: conf} = Period.estimate(residuals)
    assert_in_delta period_s, 480.0, 30.0
    assert conf >= 0.5
  end

  test "a 9 min oscillation in a 30 min window is recovered" do
    :rand.seed(:exsss, {4, 5, 6})
    residuals = sinusoid(8.0, 540.0, 1800, 1.5)

    assert %{period_s: period_s, confidence: conf} = Period.estimate(residuals)
    assert_in_delta period_s, 540.0, 60.0
    assert conf >= 0.5
  end

  test "less than two full periods of data yields :none" do
    residuals = sinusoid(10.0, 480.0, 700, 0.0)
    assert Period.estimate(residuals) == :none
  end

  test "an empty or tiny buffer yields :none" do
    assert Period.estimate([]) == :none
    assert Period.estimate([1.0, -1.0, 0.5]) == :none
  end

  test "white noise is not called periodic" do
    :rand.seed(:exsss, {7, 8, 9})
    residuals = Enum.map(1..1800, fn _ -> :rand.normal() * 2.0 end)

    case Period.estimate(residuals) do
      :none -> :ok
      %{confidence: conf} -> assert conf < 0.5
    end
  end

  test "a demeaned random walk is not called periodic (honesty)" do
    for seed <- [{10, 20, 30}, {40, 50, 60}, {70, 80, 90}] do
      :rand.seed(:exsss, seed)

      walk =
        Enum.scan(1..1800, 0.0, fn _, acc -> acc + :rand.normal() * 0.8 end)

      walk_mean = Enum.sum(walk) / length(walk)
      residuals = Enum.map(walk, &(&1 - walk_mean))

      case Period.estimate(residuals) do
        :none -> :ok
        %{confidence: conf} -> assert conf < 0.5, "seed #{inspect(seed)}: conf #{conf}"
      end
    end
  end

  test "a constant residual stream yields :none" do
    assert Period.estimate(List.duplicate(0.0, 1800)) == :none
  end

  test "zero_crossings recovers the half period and last extreme of a sinusoid" do
    :rand.seed(:exsss, {11, 12, 13})
    residuals = sinusoid(10.0, 480.0, 2400, 1.0)

    assert %{last_extreme_ms: last_extreme_ms, median_half_period_s: half} =
             Period.zero_crossings(residuals)

    assert_in_delta half, 240.0, 30.0

    # Extremes of sin(2*pi*t/480) sit at t = 120 + k*240 s; the last one inside
    # the buffer (2400 s) is near 2280 s.
    assert_in_delta last_extreme_ms, 2_280_000, 60_000
  end

  test "zero_crossings on too-flat data yields :none" do
    assert Period.zero_crossings(List.duplicate(0.0, 600)) == :none
  end

  defp sinusoid(amp, period_s, n, noise_sd) do
    Enum.map(0..(n - 1), fn t ->
      amp * :math.sin(@two_pi * t / period_s) + noise(noise_sd)
    end)
  end

  defp noise(sd) when sd <= 0.0, do: 0.0
  defp noise(sd), do: :rand.normal() * sd
end
