defmodule RacingOrg.Tracker.Pro.WindShift.Classifier do
  @moduledoc """
  Wind-shift regime classifier and prediction assembler — a pure function of the
  other cores' snapshots.

  Encodes the research doctrine:

    * classification honestly needs 20–45 min of history — below
      `:history_min_s` (default 1200 s) the verdict is `:insufficient_history`
      (the Means phase/lift passthrough still flows);
    * oscillating shifts (convective rolls, 3–20 min, ±5–20°) need wind:
      TWS below `:min_tws_mps` (default 2 m/s ≈ the bottom of the "TWS > ~8 kn
      + instability" band, kept permissive) blocks the `:oscillating` verdict;
    * a CONFIRMED step (front / sea-breeze onset, 25–90°) overrides everything
      until the step detector is reset;
    * near a mark (`near_mark_s < 240`) there is no time to play an oscillation,
      so `treat_as_persistent: true` is raised WITHOUT changing the regime;
    * range beats timing: an envelope breakout surfaces as `regime_alarm: true`.

  ## Regimes

    * `:insufficient_history` — history < 1200 s
    * `:persistent_step` — step detector `:confirmed` (overrides, until reset)
    * `:calm` — amplitude < 3° and |trend| < 2°/h
    * `:mixed` — significant trend (|trend|/SE > 2 and |trend| ≥ 2°/h) AND a
      confident oscillation, or an ambiguous middle ground (low confidence)
    * `:persistent_ramp` — significant trend without a confident oscillation
    * `:oscillating` — period confidence ≥ 0.5 AND amplitude ≥ 4° AND
      TWS ≥ 2 m/s

  ## Confidence (documented formulas)

    * insufficient: `0.0`
    * step: `min(1, 0.7 + |magnitude|/100)`
    * calm: `0.5 + 0.5·clamp(1 − max(amp/3, |trend|/2), 0, 1)`
    * oscillating: `period_confidence · clamp(amp/8, 0.5, 1)`
    * ramp: `min(|trend|/SE / 4, 0.95)`
    * mixed (both components confident): mean of the oscillating and ramp
      confidences; ambiguous fallback: `0.2`

  ## Timing outputs

  The cycle phase `θ = atan2(ψ*, ψ)` decreases at `2π/period` per second and
  contributes `amplitude·cos θ` to TWD. `time_to_next_shift_s` is the time until
  the cycle deviation next flips its CURRENT sign: target phase `−π/2` (falling
  zero) when veered, `+π/2` (rising zero) when backed. Per-tack header
  extremes: on starboard tack a header is a BACK (cycle minimum, phase `π`); on
  port tack a header is a VEER (cycle maximum, phase `0`).

  `ci_s = max(30, (1 − period_confidence) · period / 2)` — an honest timing band:
  a perfectly confident period pins the crossing to the 30 s floor, a barely
  confident one smears it across half the period.
  """

  alias RacingOrg.Tracker.Pro.WindShift.Cycle

  @type regime ::
          :insufficient_history | :calm | :oscillating | :persistent_ramp | :persistent_step | :mixed

  @typedoc "Classifier verdict."
  @type verdict :: %{
          regime: regime(),
          confidence: float(),
          oscillation: map() | nil,
          trend_deg_per_hr: float() | nil,
          time_to_next_shift_s: float() | nil,
          ci_s: float() | nil,
          treat_as_persistent: boolean(),
          regime_alarm: boolean(),
          phase_deg: float() | nil
        }

  @doc """
  Classify the current regime from the cores' snapshots.

  `inputs` — `%{means:, envelope:, cycle:, period:, step:, history_s:,
  tws_mps:, near_mark_s:}` where `means`/`envelope`/`cycle`/`step` are the
  respective modules' snapshots, `period` is `Period.estimate/2`'s result
  (`:none` allowed), `history_s` is seconds of TWD history seen, and
  `near_mark_s` is seconds to the next mark rounding (`nil` when unknown).

  Options override the doctrine thresholds: `:history_min_s` (1200),
  `:calm_amp_deg` (3), `:calm_trend_deg_per_hr` (2), `:osc_amp_deg` (4),
  `:osc_period_conf` (0.5), `:min_tws_mps` (2.0), `:trend_t_stat` (2.0),
  `:trend_min_deg_per_hr` (2.0), `:near_mark_s` (240).
  """
  @spec classify(map(), keyword()) :: verdict()
  def classify(inputs, opts \\ []) do
    history_min_s = Keyword.get(opts, :history_min_s, 1200)
    near_mark_limit = Keyword.get(opts, :near_mark_s, 240)

    base = %{
      regime: :insufficient_history,
      confidence: 0.0,
      oscillation: nil,
      trend_deg_per_hr: nil,
      time_to_next_shift_s: nil,
      ci_s: nil,
      treat_as_persistent: near?(inputs[:near_mark_s], near_mark_limit),
      regime_alarm: envelope_alarm?(inputs[:envelope]),
      phase_deg: get_in_snapshot(inputs, :means, :phase_deg)
    }

    cond do
      inputs.history_s < history_min_s -> base
      step_confirmed?(inputs[:step]) -> step_verdict(base, inputs.step)
      true -> regime_verdict(base, inputs, opts)
    end
  end

  # --- persistent step (overrides until the detector is reset) -----------------

  defp step_confirmed?(%{status: :confirmed}), do: true
  defp step_confirmed?(_), do: false

  defp step_verdict(base, step) do
    %{base | regime: :persistent_step, confidence: min(1.0, 0.7 + abs(step.magnitude_deg) / 100.0)}
  end

  # --- oscillation / trend / calm ------------------------------------------------

  defp regime_verdict(base, inputs, opts) do
    calm_amp = Keyword.get(opts, :calm_amp_deg, 3.0)
    calm_trend = Keyword.get(opts, :calm_trend_deg_per_hr, 2.0)
    osc_amp = Keyword.get(opts, :osc_amp_deg, 4.0)
    osc_conf = Keyword.get(opts, :osc_period_conf, 0.5)
    min_tws = Keyword.get(opts, :min_tws_mps, 2.0)
    t_stat_min = Keyword.get(opts, :trend_t_stat, 2.0)
    trend_min = Keyword.get(opts, :trend_min_deg_per_hr, 2.0)

    cycle = inputs.cycle
    amp = cycle.amplitude_deg || 0.0
    trend = cycle.trend_deg_per_hr || 0.0
    se = cycle.trend_se_deg_per_hr || 0.0

    {period_s, period_conf} =
      case inputs.period do
        %{period_s: p, confidence: c} -> {p, c}
        _ -> {nil, 0.0}
      end

    tws = inputs[:tws_mps] || 0.0
    osc? = period_conf >= osc_conf and amp >= osc_amp and tws >= min_tws
    trend_significant? = se > 0.0 and abs(trend) / se > t_stat_min and abs(trend) >= trend_min

    osc_confidence = period_conf * clamp(amp / 8.0, 0.5, 1.0)
    ramp_confidence = if se > 0.0, do: min(abs(trend) / se / 4.0, 0.95), else: 0.0

    base = %{base | trend_deg_per_hr: cycle.trend_deg_per_hr}

    cond do
      amp < calm_amp and abs(trend) < calm_trend ->
        %{
          base
          | regime: :calm,
            confidence: 0.5 + 0.5 * clamp(1.0 - max(amp / calm_amp, abs(trend) / calm_trend), 0.0, 1.0)
        }

      osc? and trend_significant? ->
        base
        |> with_oscillation(cycle, period_s, period_conf)
        |> Map.merge(%{regime: :mixed, confidence: 0.5 * (osc_confidence + ramp_confidence)})

      osc? ->
        base
        |> with_oscillation(cycle, period_s, period_conf)
        |> Map.merge(%{regime: :oscillating, confidence: osc_confidence})

      trend_significant? ->
        %{base | regime: :persistent_ramp, confidence: ramp_confidence}

      true ->
        # Neither calm, confidently oscillating, nor confidently trending.
        %{base | regime: :mixed, confidence: 0.2}
    end
  end

  # --- oscillation timing --------------------------------------------------------

  defp with_oscillation(base, cycle, period_s, period_conf) do
    period = period_s || cycle.period_s
    phase = cycle.phase_rad

    # Flip target for the CURRENT cycle sign: the contribution is amp*cos(phase),
    # so veered (cos >= 0) flips at the falling zero (-pi/2), backed at the
    # rising zero (+pi/2).
    flip_target = if :math.cos(phase) >= 0.0, do: -:math.pi() / 2.0, else: :math.pi() / 2.0

    to_starboard_header = Cycle.time_from_phase(phase, period, :math.pi())
    to_port_header = Cycle.time_from_phase(phase, period, 0.0)

    %{
      base
      | oscillation: %{
          period_s: period,
          amplitude_deg: cycle.amplitude_deg,
          phase_rad: phase,
          time_to_next_header_s: %{starboard: to_starboard_header, port: to_port_header},
          phase_frac_to_next_header: %{
            starboard: to_starboard_header / period,
            port: to_port_header / period
          }
        },
        time_to_next_shift_s: Cycle.time_from_phase(phase, period, flip_target),
        ci_s: max(30.0, (1.0 - period_conf) * period / 2.0)
    }
  end

  # --- small helpers --------------------------------------------------------------

  defp near?(nil, _limit), do: false
  defp near?(near_mark_s, limit), do: near_mark_s < limit

  defp envelope_alarm?(%{new_extreme: extreme}) when extreme in [:high, :low], do: true
  defp envelope_alarm?(_), do: false

  defp get_in_snapshot(inputs, key, field) do
    case inputs[key] do
      %{^field => value} -> value
      _ -> nil
    end
  end

  defp clamp(x, lo, hi), do: min(max(x, lo), hi)
end
