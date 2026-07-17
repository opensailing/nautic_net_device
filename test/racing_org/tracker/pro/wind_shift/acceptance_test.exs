Code.require_file("support/wind_gen_helper.exs", __DIR__)

defmodule RacingOrg.Tracker.Pro.WindShift.AcceptanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  End-to-end acceptance scenarios for the wind-shift predictor cores.

  Each test drives the FULL pure pipeline (Means + Envelope + Cycle + Period +
  StepDetect + Classifier) over a scripted-truth 1 Hz TWD stream and asserts the
  recovered values against the script. These tests DEFINE correctness for the
  Wave-2 observer integration.
  """

  alias RacingOrg.Tracker.Pro.Calibration.Detect.Circular
  alias RacingOrg.Tracker.Pro.WindShift.Classifier
  alias RacingOrg.Tracker.Pro.WindShift.Cycle
  alias RacingOrg.Tracker.Pro.WindShift.Envelope
  alias RacingOrg.Tracker.Pro.WindShift.Means
  alias RacingOrg.Tracker.Pro.WindShift.Period
  alias RacingOrg.Tracker.Pro.WindShift.StepDetect
  alias RacingOrg.Tracker.Pro.WindShift.WindGen

  # Residual ring for Period: last 30 min at 1 Hz.
  @resid_window 1800
  # Re-estimate the oscillation period once a minute.
  @period_every_ms 60_000

  # ---------------------------------------------------------------------------
  # Scenario 1 — pure oscillation: +/-10 deg @ 8 min, noise sigma 1.5, 45 min.
  # ---------------------------------------------------------------------------

  test "scenario 1: oscillation is recovered (period, amplitude, regime, header timing)" do
    samples =
      WindGen.generate([%{dur_s: 2700, base: 200.0, osc: {10.0, 480}}], noise_sigma: 1.5)

    {_p, snaps, _meta} = run(samples)

    # Period.estimate: within +/-60 s of the scripted 480 s, confidently.
    final = List.last(snaps)
    assert %{period_s: period_s, confidence: period_conf} = final.period
    assert_in_delta period_s, 480.0, 60.0
    assert period_conf >= 0.5

    # Cycle amplitude 10 +/- 2 deg (mean over the last 10 minutes), trend < 2 deg/h.
    late = Enum.filter(snaps, &(&1.t_ms >= 2_100_000))
    mean_amp = mean(Enum.map(late, & &1.cycle.amplitude_deg))
    assert_in_delta mean_amp, 10.0, 2.0
    assert abs(final.cycle.trend_deg_per_hr) < 2.0

    # Classifier: :oscillating with confidence >= 0.6.
    assert final.verdict.regime == :oscillating
    assert final.verdict.confidence >= 0.6
    assert %{period_s: _, amplitude_deg: _} = final.verdict.oscillation

    # Time-to-next-shift from known scripted phases, within +/-90 s of truth.
    # The scripted deviation is 10*sin(2*pi*t/480): at t = 2040 s and 2520 s the
    # phase fraction is 0.25 (positive peak, next sign flip in 120 s); at
    # t = 2280 s it is 0.75 (negative peak, next sign flip in 120 s).
    for t_ms <- [2_040_000, 2_280_000, 2_520_000] do
      snap = Enum.find(snaps, &(&1.t_ms == t_ms))
      assert snap != nil
      assert snap.verdict.time_to_next_shift_s != nil
      assert_in_delta snap.verdict.time_to_next_shift_s, 120.0, 90.0
      assert snap.verdict.ci_s >= 30.0
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 2 — ramp 6 deg/h + oscillation +/-8 deg @ 9 min, 60 min.
  # ---------------------------------------------------------------------------

  test "scenario 2: ramp + oscillation classifies :mixed with both components recovered" do
    samples =
      WindGen.generate([%{dur_s: 3600, base: 200.0, ramp: 6.0, osc: {8.0, 540}}],
        noise_sigma: 1.5
      )

    {_p, snaps, _meta} = run(samples)
    final = List.last(snaps)

    assert final.verdict.regime == :mixed

    # Trend CI (trend +/- 1.96*SE) covers the scripted 6 deg/h.
    trend = final.cycle.trend_deg_per_hr
    se = final.cycle.trend_se_deg_per_hr
    assert trend - 1.96 * se <= 6.0
    assert trend + 1.96 * se >= 6.0

    # Oscillation stats still recovered alongside the ramp.
    assert %{period_s: period_s, confidence: conf} = final.period
    assert_in_delta period_s, 540.0, 60.0
    assert conf >= 0.5

    late = Enum.filter(snaps, &(&1.t_ms >= 3_000_000))
    mean_amp = mean(Enum.map(late, & &1.cycle.amplitude_deg))
    assert_in_delta mean_amp, 8.0, 2.0
  end

  # ---------------------------------------------------------------------------
  # Scenario 3 — persistent step: +30 deg front at t = 20 min.
  # ---------------------------------------------------------------------------

  test "scenario 3: +30 deg step is confirmed fast, sized right, and overrides the regime" do
    samples =
      WindGen.generate(
        [%{dur_s: 1200, base: 200.0}, %{dur_s: 1500, step: 30.0}],
        noise_sigma: 1.5
      )

    {p, snaps, meta} = run(samples)

    # Confirmed within 120 s of the scripted onset (t = 1200 s).
    assert meta.first_confirm_ms != nil
    assert meta.first_confirm_ms - 1_200_000 <= 120_000

    # Magnitude 30 +/- 5 deg, onset dated near the scripted front.
    step = StepDetect.snapshot(p.step)
    assert step.status == :confirmed
    assert_in_delta step.magnitude_deg, 30.0, 5.0
    assert_in_delta step.onset_ms, 1_200_000, 30_000

    # Classifier: :persistent_step from confirmation to the end; no :oscillating
    # verdict at any point after the step (until an explicit reset).
    post_step = Enum.filter(snaps, &(&1.t_ms >= 1_200_000))
    assert Enum.all?(post_step, &(&1.verdict.regime != :oscillating))

    post_confirm = Enum.filter(snaps, &(&1.t_ms >= meta.first_confirm_ms))
    assert post_confirm != []
    assert Enum.all?(post_confirm, &(&1.verdict.regime == :persistent_step))
  end

  # ---------------------------------------------------------------------------
  # Scenario 4 — HONESTY: a pure random walk must never read as an oscillation.
  # ---------------------------------------------------------------------------

  test "scenario 4: random walk never yields a confident :oscillating verdict" do
    for seed <- [{11, 22, 33}, {44, 55, 66}] do
      samples =
        WindGen.generate([%{dur_s: 3600, base: 200.0, walk_sigma: 0.8}], seed: seed)

      {_p, snaps, _meta} = run(samples)
      assert snaps != []

      for snap <- snaps do
        refute snap.verdict.regime == :oscillating and snap.verdict.confidence > 0.5,
               "seed #{inspect(seed)}: confident :oscillating at t=#{snap.t_ms}"

        case snap.period do
          :none -> :ok
          %{confidence: conf} -> assert conf < 0.5, "seed #{inspect(seed)}: period conf #{conf} at t=#{snap.t_ms}"
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 5 — HONESTY: 12 min of history is not enough to classify.
  # ---------------------------------------------------------------------------

  test "scenario 5: 12 min of stream is :insufficient_history but phase/lift still flows" do
    samples =
      WindGen.generate([%{dur_s: 720, base: 200.0, osc: {10.0, 480}}], noise_sigma: 1.5)

    {p, snaps, _meta} = run(samples)
    final = List.last(snaps)

    assert final.verdict.regime == :insufficient_history
    assert final.verdict.oscillation == nil
    assert final.verdict.time_to_next_shift_s == nil

    # Means-based phase/lift passthrough is still live.
    assert is_number(final.verdict.phase_deg)
    assert is_number(Means.snapshot(p.means).phase_deg)
  end

  # ---------------------------------------------------------------------------
  # Scenario 8 — calm: flat TWD + noise -> :calm, no alarms.
  # ---------------------------------------------------------------------------

  test "scenario 8: flat wind classifies :calm with no alarms" do
    samples = WindGen.generate([%{dur_s: 2400, base: 200.0}], noise_sigma: 1.0)

    {p, snaps, meta} = run(samples)
    final = List.last(snaps)

    assert final.verdict.regime == :calm
    assert meta.envelope_alarms == []
    assert StepDetect.snapshot(p.step).status != :confirmed
  end

  # ---------------------------------------------------------------------------
  # Scenario 9 — forecast skill: beats persistence at 120 s; CI grows with horizon.
  # ---------------------------------------------------------------------------

  test "scenario 9: cycle forecast beats persistence on scenario 1 at 120 s horizon" do
    samples =
      WindGen.generate([%{dur_s: 2700, base: 200.0, osc: {10.0, 480}}], noise_sigma: 1.5)

    truth = Map.new(samples, &{&1.t_ms, &1.truth_deg})

    {p, checks} =
      Enum.reduce(samples, {pipeline_new(), []}, fn sample, {p, checks} ->
        p = pipeline_step(p, sample)

        checks =
          if rem(sample.t_ms, 30_000) == 0 and sample.t_ms >= 1_500_000 and
               sample.t_ms <= 2_400_000 do
            forecast = Cycle.forecast(p.cycle, 120.0)
            [{sample.t_ms, forecast.twd_deg, sample.twd_deg} | checks]
          else
            checks
          end

        {p, checks}
      end)

    errors =
      for {t_ms, forecast_twd, now_twd} <- checks do
        future = Map.fetch!(truth, t_ms + 120_000)
        {forecast_twd - future, Circular.wrapped_delta(future, now_twd)}
      end

    assert length(errors) > 20
    rmse_forecast = rmse(Enum.map(errors, &elem(&1, 0)))
    rmse_persistence = rmse(Enum.map(errors, &elem(&1, 1)))
    assert rmse_forecast < rmse_persistence

    # CI is honest: it grows with the horizon.
    ci_60 = Cycle.forecast(p.cycle, 60.0).ci_deg
    ci_300 = Cycle.forecast(p.cycle, 300.0).ci_deg
    ci_900 = Cycle.forecast(p.cycle, 900.0).ci_deg
    assert ci_60 < ci_300
    assert ci_300 < ci_900
  end

  # ---------------------------------------------------------------------------
  # Pipeline harness (what the Wave-2 observer will do, in pure form)
  # ---------------------------------------------------------------------------

  defp run(samples) do
    {p, snaps, meta} =
      Enum.reduce(samples, {pipeline_new(), [], %{first_confirm_ms: nil, envelope_alarms: []}}, fn sample,
                                                                                                   {p, snaps, meta} ->
        p = pipeline_step(p, sample)

        meta =
          meta
          |> track_confirm(p, sample.t_ms)
          |> track_alarm(p, sample.t_ms)

        snaps =
          if rem(sample.t_ms, 60_000) == 0 and sample.t_ms > 0 do
            snap = %{
              t_ms: sample.t_ms,
              verdict: classify(p, sample.tws_mps),
              cycle: Cycle.snapshot(p.cycle),
              period: p.period,
              step: StepDetect.snapshot(p.step)
            }

            [snap | snaps]
          else
            snaps
          end

        {p, snaps, meta}
      end)

    {p, Enum.reverse(snaps), Map.update!(meta, :envelope_alarms, &Enum.reverse/1)}
  end

  defp track_confirm(%{first_confirm_ms: nil} = meta, p, t_ms) do
    if StepDetect.snapshot(p.step).status == :confirmed do
      %{meta | first_confirm_ms: t_ms}
    else
      meta
    end
  end

  defp track_confirm(meta, _p, _t_ms), do: meta

  defp track_alarm(meta, p, t_ms) do
    case Envelope.snapshot(p.envelope).new_extreme do
      :none -> meta
      kind -> Map.update!(meta, :envelope_alarms, &[{t_ms, kind} | &1])
    end
  end

  defp pipeline_new do
    %{
      means: Means.new(),
      envelope: Envelope.new(),
      cycle: Cycle.new(),
      step: StepDetect.new(),
      unwrap: nil,
      resid: [],
      period: :none,
      t0_ms: nil,
      last_t_ms: nil,
      last_period_ms: nil
    }
  end

  defp pipeline_step(p, sample) do
    %{t_ms: t_ms, twd_deg: twd} = sample

    unwrapped =
      case p.unwrap do
        nil -> twd
        {last_in, last_un} -> last_un + Circular.wrapped_delta(last_in, twd)
      end

    dt_s = if p.last_t_ms, do: (t_ms - p.last_t_ms) / 1000.0, else: 1.0

    means = Means.update(p.means, twd, t_ms)
    envelope = Envelope.update(p.envelope, twd, t_ms)
    cycle = Cycle.step(p.cycle, unwrapped, dt_s)

    # Residual for the period estimator: observation minus the structural level
    # (trend removed by the filter), i.e. cycle + noise.
    resid = unwrapped - Cycle.snapshot(cycle).level_deg

    # Residual for step detection: wrap-aware deviation from the slow mean.
    step_resid = Circular.wrapped_delta(Means.snapshot(means).slow, twd)
    step = StepDetect.step(p.step, step_resid, t_ms)

    p = %{
      p
      | means: means,
        envelope: envelope,
        cycle: cycle,
        step: step,
        unwrap: {twd, unwrapped},
        resid: [resid | p.resid],
        t0_ms: p.t0_ms || t_ms,
        last_t_ms: t_ms
    }

    maybe_estimate_period(p, t_ms)
  end

  defp maybe_estimate_period(p, t_ms) do
    if p.last_period_ms == nil or t_ms - p.last_period_ms >= @period_every_ms do
      residuals = p.resid |> Enum.take(@resid_window) |> Enum.reverse()
      estimate = Period.estimate(residuals)
      p = %{p | period: estimate, last_period_ms: t_ms}

      case estimate do
        %{period_s: period_s, confidence: conf} when conf >= 0.5 ->
          %{p | cycle: Cycle.retune(p.cycle, period_s), step: StepDetect.put_period_hint(p.step, period_s)}

        _ ->
          p
      end
    else
      p
    end
  end

  defp classify(p, tws_mps, near_mark_s \\ nil) do
    Classifier.classify(%{
      means: Means.snapshot(p.means),
      envelope: Envelope.snapshot(p.envelope),
      cycle: Cycle.snapshot(p.cycle),
      period: p.period,
      step: StepDetect.snapshot(p.step),
      history_s: (p.last_t_ms - p.t0_ms) / 1000.0,
      tws_mps: tws_mps,
      near_mark_s: near_mark_s
    })
  end

  defp mean([]), do: nil
  defp mean(xs), do: Enum.sum(xs) / length(xs)

  defp rmse(errors) do
    :math.sqrt(Enum.sum(Enum.map(errors, &(&1 * &1))) / length(errors))
  end
end
