defmodule RacingOrg.Tracker.Pro.WindShift.StepDetectTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WindShift.StepDetect

  @two_pi 2.0 * :math.pi()

  test "a quiet residual stream stays :none" do
    :rand.seed(:exsss, {21, 22, 23})
    sd = feed(StepDetect.new(), fn _t -> :rand.normal() * 1.5 end, 1200)
    assert StepDetect.snapshot(sd).status == :none
  end

  test "a +30 deg offset is confirmed on the fast path with accurate onset and magnitude" do
    :rand.seed(:exsss, {24, 25, 26})
    offset = fn t -> if t >= 600, do: 30.0, else: 0.0 end

    {sd, first_confirm_ms} = feed_tracking(StepDetect.new(), fn t -> offset.(t) + :rand.normal() * 1.5 end, 1200)

    snap = StepDetect.snapshot(sd)
    assert snap.status == :confirmed
    # Fast confirmation: a 30 deg offset out-runs any plausible oscillation
    # amplitude, so it confirms in ~90 s, well within 120 s.
    assert first_confirm_ms != nil
    assert first_confirm_ms - 600_000 <= 120_000
    assert_in_delta snap.magnitude_deg, 30.0, 3.0
    assert_in_delta snap.onset_ms, 600_000, 15_000
  end

  test "a -30 deg offset is detected with negative magnitude" do
    :rand.seed(:exsss, {27, 28, 29})

    {sd, _} =
      feed_tracking(StepDetect.new(), fn t -> if(t >= 600, do: -30.0, else: 0.0) + :rand.normal() * 1.5 end, 1200)

    snap = StepDetect.snapshot(sd)
    assert snap.status == :confirmed
    assert_in_delta snap.magnitude_deg, -30.0, 3.0
  end

  test "a +12 deg offset needs the full confirmation window without a period hint" do
    :rand.seed(:exsss, {30, 31, 32})

    {sd, first_confirm_ms} =
      feed_tracking(StepDetect.new(), fn t -> if(t >= 300, do: 12.0, else: 0.0) + :rand.normal() * 1.5 end, 1200)

    snap = StepDetect.snapshot(sd)
    assert snap.status == :confirmed
    # Default window: min(period_hint || 480 s, 480 s) after onset.
    assert first_confirm_ms - 300_000 >= 400_000
    assert first_confirm_ms - 300_000 <= 560_000
    assert_in_delta snap.magnitude_deg, 12.0, 3.0
  end

  test "a period hint shortens the confirmation window" do
    :rand.seed(:exsss, {33, 34, 35})
    sd = StepDetect.put_period_hint(StepDetect.new(), 240.0)

    {sd, first_confirm_ms} =
      feed_tracking(sd, fn t -> if(t >= 300, do: 12.0, else: 0.0) + :rand.normal() * 1.5 end, 900)

    assert StepDetect.snapshot(sd).status == :confirmed
    assert first_confirm_ms - 300_000 >= 200_000
    assert first_confirm_ms - 300_000 <= 320_000
  end

  test "a short gust pulse becomes a candidate but reverts to :none" do
    :rand.seed(:exsss, {36, 37, 38})
    pulse = fn t -> if t >= 300 and t < 320, do: 15.0, else: 0.0 end

    {statuses, sd} =
      Enum.map_reduce(1..900, StepDetect.new(), fn t, sd ->
        sd = StepDetect.step(sd, pulse.(t) + :rand.normal() * 1.0, t * 1000)
        {StepDetect.snapshot(sd).status, sd}
      end)

    assert :candidate in statuses
    refute :confirmed in statuses
    assert StepDetect.snapshot(sd).status == :none
  end

  test "a tracked oscillation never confirms a step" do
    :rand.seed(:exsss, {39, 40, 41})
    sd = StepDetect.put_period_hint(StepDetect.new(), 480.0)

    {statuses, _sd} =
      Enum.map_reduce(1..2400, sd, fn t, sd ->
        resid = 10.0 * :math.sin(@two_pi * t / 480.0) + :rand.normal() * 1.5
        sd = StepDetect.step(sd, resid, t * 1000)
        {StepDetect.snapshot(sd).status, sd}
      end)

    refute :confirmed in statuses
  end

  test "a small persistent lag offset (ramp leftover) never confirms" do
    :rand.seed(:exsss, {42, 43, 44})
    sd = feed(StepDetect.new(), fn _t -> 2.5 + :rand.normal() * 1.5 end, 1800)
    assert StepDetect.snapshot(sd).status != :confirmed
  end

  test "reset clears a confirmed step back to :none" do
    :rand.seed(:exsss, {45, 46, 47})
    {sd, _} = feed_tracking(StepDetect.new(), fn t -> if(t >= 300, do: 30.0, else: 0.0) end, 600)
    assert StepDetect.snapshot(sd).status == :confirmed

    sd = StepDetect.reset(sd)
    snap = StepDetect.snapshot(sd)
    assert snap == %{status: :none, onset_ms: nil, magnitude_deg: nil}
  end

  defp feed(sd, resid_fn, steps) do
    Enum.reduce(1..steps, sd, fn t, sd -> StepDetect.step(sd, resid_fn.(t), t * 1000) end)
  end

  defp feed_tracking(sd, resid_fn, steps) do
    Enum.reduce(1..steps, {sd, nil}, fn t, {sd, first_confirm_ms} ->
      sd = StepDetect.step(sd, resid_fn.(t), t * 1000)

      first_confirm_ms =
        if first_confirm_ms == nil and StepDetect.snapshot(sd).status == :confirmed do
          t * 1000
        else
          first_confirm_ms
        end

      {sd, first_confirm_ms}
    end)
  end
end
