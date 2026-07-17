defmodule RacingOrg.Tracker.Pro.WindShift.ClassifierTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WindShift.Classifier

  @pi :math.pi()

  defp means_snap(over \\ %{}) do
    Map.merge(
      %{fast: 203.0, mid: 201.0, slow: 200.0, phase_deg: 3.0, stability: 0.95},
      over
    )
  end

  defp envelope_snap(over \\ %{}) do
    Map.merge(%{min_deg: 190.0, max_deg: 212.0, range_deg: 22.0, new_extreme: :none}, over)
  end

  defp cycle_snap(over \\ %{}) do
    Map.merge(
      %{
        level_deg: 200.0,
        trend_deg_per_hr: 0.4,
        trend_se_deg_per_hr: 0.5,
        amplitude_deg: 10.0,
        phase_rad: 0.0,
        period_s: 480.0,
        innovation_var: 2.5
      },
      over
    )
  end

  defp step_snap(status \\ :none) do
    case status do
      :none -> %{status: :none, onset_ms: nil, magnitude_deg: nil}
      :candidate -> %{status: :candidate, onset_ms: 100_000, magnitude_deg: 12.0}
      :confirmed -> %{status: :confirmed, onset_ms: 100_000, magnitude_deg: 30.0}
    end
  end

  defp inputs(over \\ %{}) do
    Map.merge(
      %{
        means: means_snap(),
        envelope: envelope_snap(),
        cycle: cycle_snap(),
        period: %{period_s: 480.0, confidence: 0.8},
        step: step_snap(),
        history_s: 2400.0,
        tws_mps: 6.0,
        near_mark_s: nil
      },
      over
    )
  end

  test "short history is :insufficient_history but the phase passthrough survives" do
    out = Classifier.classify(inputs(%{history_s: 900.0}))

    assert out.regime == :insufficient_history
    assert out.confidence == 0.0
    assert out.oscillation == nil
    assert out.time_to_next_shift_s == nil
    assert out.trend_deg_per_hr == nil
    assert out.phase_deg == 3.0
  end

  test "small amplitude and flat trend is :calm" do
    out =
      Classifier.classify(
        inputs(%{
          cycle: cycle_snap(%{amplitude_deg: 1.5, trend_deg_per_hr: 0.5}),
          period: :none
        })
      )

    assert out.regime == :calm
    assert out.oscillation == nil
  end

  test "a confident period + amplitude + wind is :oscillating with timing outputs" do
    out = Classifier.classify(inputs())

    assert out.regime == :oscillating
    assert out.confidence >= 0.6

    assert out.oscillation.period_s == 480.0
    assert out.oscillation.amplitude_deg == 10.0
    assert out.oscillation.phase_rad == 0.0
    # ci per the documented formula: max(30, (1 - conf) * period / 2).
    assert_in_delta out.ci_s, max(30.0, (1.0 - 0.8) * 480.0 / 2.0), 1.0e-9

    # phase_rad = 0 -> the cycle sits at its veered (positive) extreme; the next
    # sign flip (falling zero, target -pi/2) is a quarter period away.
    assert_in_delta out.time_to_next_shift_s, 120.0, 1.0e-6

    # Per-tack header timing: phase 0 is the PORT-tack header moment (veer max);
    # the starboard header (backing extreme, target pi) is half a period away.
    assert_in_delta out.oscillation.time_to_next_header_s.port, 0.0, 1.0e-6
    assert_in_delta out.oscillation.time_to_next_header_s.starboard, 240.0, 1.0e-6
    assert_in_delta out.oscillation.phase_frac_to_next_header.starboard, 0.5, 1.0e-6
  end

  test "the backed extreme flips the sign target for time_to_next_shift" do
    out = Classifier.classify(inputs(%{cycle: cycle_snap(%{phase_rad: @pi})}))

    assert out.regime == :oscillating
    # From the backed extreme (phase pi) the rising zero (target pi/2) is a
    # quarter period away.
    assert_in_delta out.time_to_next_shift_s, 120.0, 1.0e-6
  end

  test "light air blocks the :oscillating verdict" do
    out = Classifier.classify(inputs(%{tws_mps: 1.5}))
    refute out.regime == :oscillating
  end

  test "a low-confidence period blocks :oscillating" do
    out = Classifier.classify(inputs(%{period: %{period_s: 480.0, confidence: 0.4}}))
    refute out.regime == :oscillating
  end

  test "a sub-4-deg amplitude blocks :oscillating" do
    out = Classifier.classify(inputs(%{cycle: cycle_snap(%{amplitude_deg: 3.5})}))
    refute out.regime == :oscillating
  end

  test "a significant trend without oscillation is :persistent_ramp" do
    out =
      Classifier.classify(
        inputs(%{
          cycle: cycle_snap(%{trend_deg_per_hr: 6.0, trend_se_deg_per_hr: 1.0, amplitude_deg: 2.0}),
          period: :none
        })
      )

    assert out.regime == :persistent_ramp
    assert out.trend_deg_per_hr == 6.0
  end

  test "a significant trend plus a confident oscillation is :mixed" do
    out =
      Classifier.classify(
        inputs(%{
          cycle: cycle_snap(%{trend_deg_per_hr: 6.0, trend_se_deg_per_hr: 1.0, amplitude_deg: 8.0}),
          period: %{period_s: 540.0, confidence: 0.7}
        })
      )

    assert out.regime == :mixed
    assert out.trend_deg_per_hr == 6.0
    assert %{amplitude_deg: 8.0} = out.oscillation
    assert out.time_to_next_shift_s != nil
  end

  test "an insignificant small trend cannot force :mixed" do
    # |trend|/SE > 2 but under the 2 deg/h magnitude floor: still :oscillating.
    out =
      Classifier.classify(inputs(%{cycle: cycle_snap(%{trend_deg_per_hr: 1.0, trend_se_deg_per_hr: 0.1})}))

    assert out.regime == :oscillating
  end

  test "a confirmed step overrides everything until reset" do
    out = Classifier.classify(inputs(%{step: step_snap(:confirmed)}))

    assert out.regime == :persistent_step
    assert out.confidence > 0.5
    assert out.oscillation == nil
  end

  test "a mere step candidate does not override" do
    out = Classifier.classify(inputs(%{step: step_snap(:candidate)}))
    assert out.regime == :oscillating
  end

  test "near a mark the persistent-treatment flag is raised without changing the regime" do
    out = Classifier.classify(inputs(%{near_mark_s: 120.0}))
    assert out.regime == :oscillating
    assert out.treat_as_persistent == true

    out = Classifier.classify(inputs(%{near_mark_s: 600.0}))
    assert out.treat_as_persistent == false

    out = Classifier.classify(inputs())
    assert out.treat_as_persistent == false
  end

  test "an out-of-range envelope reading raises the regime alarm passthrough" do
    out = Classifier.classify(inputs(%{envelope: envelope_snap(%{new_extreme: :high})}))
    assert out.regime_alarm == true

    out = Classifier.classify(inputs())
    assert out.regime_alarm == false
  end

  test "random-walk-like inputs never claim a confident oscillation" do
    out =
      Classifier.classify(
        inputs(%{
          period: %{period_s: 700.0, confidence: 0.3},
          cycle: cycle_snap(%{amplitude_deg: 6.0, trend_deg_per_hr: 1.0, trend_se_deg_per_hr: 2.0})
        })
      )

    refute out.regime == :oscillating and out.confidence > 0.5
  end
end
