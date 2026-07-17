Code.require_file("support/wind_gen_helper.exs", __DIR__)

defmodule RacingOrg.Tracker.Pro.WindShift.PerfTest do
  # async: false so the timing runs on an uncontended scheduler.
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.Calibration.Detect.Circular
  alias RacingOrg.Tracker.Pro.WindShift.Classifier
  alias RacingOrg.Tracker.Pro.WindShift.Cycle
  alias RacingOrg.Tracker.Pro.WindShift.Envelope
  alias RacingOrg.Tracker.Pro.WindShift.Means
  alias RacingOrg.Tracker.Pro.WindShift.Period
  alias RacingOrg.Tracker.Pro.WindShift.StepDetect
  alias RacingOrg.Tracker.Pro.WindShift.WindGen

  # Acceptance 10 — 3600 sequential full per-sample pipeline updates (means,
  # envelope, cycle, step detector, classifier) in < 500 ms. The batch period
  # estimator runs on its own 60 s cadence, so it is bounded separately below.
  test "3600 sequential per-sample pipeline updates run in under 500 ms" do
    samples =
      WindGen.generate([%{dur_s: 3600, base: 200.0, osc: {10.0, 480}}], noise_sigma: 1.5)

    state = %{
      means: Means.new(),
      envelope: Envelope.new(),
      cycle: Cycle.new(),
      step: StepDetect.new(),
      unwrap: nil,
      t0_ms: hd(samples).t_ms
    }

    {micros, _state} =
      :timer.tc(fn ->
        Enum.reduce(samples, state, fn %{t_ms: t_ms, twd_deg: twd, tws_mps: tws}, s ->
          unwrapped =
            case s.unwrap do
              nil -> twd
              {last_in, last_un} -> last_un + Circular.wrapped_delta(last_in, twd)
            end

          means = Means.update(s.means, twd, t_ms)
          envelope = Envelope.update(s.envelope, twd, t_ms)
          cycle = Cycle.step(s.cycle, unwrapped, 1.0)
          step = StepDetect.step(s.step, Circular.wrapped_delta(Means.snapshot(means).slow, twd), t_ms)

          _verdict =
            Classifier.classify(%{
              means: Means.snapshot(means),
              envelope: Envelope.snapshot(envelope),
              cycle: Cycle.snapshot(cycle),
              period: %{period_s: 480.0, confidence: 0.8},
              step: StepDetect.snapshot(step),
              history_s: (t_ms - s.t0_ms) / 1000.0,
              tws_mps: tws,
              near_mark_s: nil
            })

          %{s | means: means, envelope: envelope, cycle: cycle, step: step, unwrap: {twd, unwrapped}}
        end)
      end)

    assert micros < 500_000, "pipeline took #{Float.round(micros / 1000, 1)} ms (budget 500 ms)"
  end

  test "one 30-minute period estimation runs in under 50 ms" do
    :rand.seed(:exsss, {50, 51, 52})

    residuals =
      Enum.map(0..1799, fn t ->
        10.0 * :math.sin(2.0 * :math.pi() * t / 480.0) + :rand.normal() * 1.5
      end)

    {micros, result} = :timer.tc(fn -> Period.estimate(residuals) end)

    assert %{period_s: _, confidence: _} = result
    assert micros < 50_000, "Period.estimate took #{Float.round(micros / 1000, 1)} ms (budget 50 ms)"
  end
end
