defmodule RacingOrg.Tracker.Pro.WindShift.Wally do
  @moduledoc """
  The WALLY doctrine (Ockam/McCurdy): pure shift-phase target-modulation math
  for the wind-shift predictor.

  When the wind OSCILLATES, VMG should be maximized along the AVERAGE wind, not
  the current wind: on the LIFTED tack sail LOWER and FASTER than the polar
  target ("foot the lift"); on the HEADED tack sail HIGHER and SLOWER ("pinch
  the header"). Rule of thumb: pinch/foot by HALF the shift. Sailed well this is
  worth ~5 s/mile of raw VMG plus unbounded separation gains (the boat is always
  positioned on the advantaged side of the next shift). It is only valid when
  the regime is GENUINELY oscillating — against a persistent shift the same
  moves point the boat the wrong way — hence the hard regime gate and the
  confidence requirement below.

  This module is pure math + gates; the mode POLICY lives in
  `RacingOrg.Tracker.Pro.WindShift.Config`, is published per tick as the
  `wally_mode` engine signal by `RacingOrg.Tracker.Pro.WindShift.Observer`, and
  the modulation is APPLIED by the `target_boat_speed` / `target_twa` calcs in
  `RacingOrg.Tracker.Pro.Compute.Library`.

  ## The delta rule (`delta_deg/2`)

      delta = clamp(wind_lift_deg / 2, ±max_delta)      # max_delta default 6.0°

  `wind_lift_deg` is the Observer's tack-resolved shift phase (positive =
  LIFTED on the current tack, whichever tack that is), so the SIGNED delta
  applies directly to the |TWA| target: positive WIDENS the target angle
  (foot), negative NARROWS it (pinch). The clamp caps the modulation for a
  monster shift — beyond ±12° of lift the strategy is a tactical call, not a
  target tweak.

  ## The activation gates (`active?/1`) — ALL must hold

    * `wind_regime == 2` — the classifier's genuinely-OSCILLATING verdict
      (`RacingOrg.Tracker.Pro.WindShift.Observer.regime_code/1`);
    * `shift_confidence >= 50` — half-confident or better;
    * `|wind_lift_deg| >= 2.0°` — deadband: don't chase noise;
    * `|twa| < 90°` — upwind only. Downwind Wally (playing shifts through
      gybes) is a LATER refinement: run targets move the OTHER way with the
      shift and the payoff shape differs, so it is deliberately not modulated
      yet.

  Missing or non-numeric inputs are simply INACTIVE (fail-safe off), never an
  error — the target calcs stay byte-identical to a build without Wally.

  ## Mode codes (`mode_code/1`)

  Engine signals are numeric, so the policy's `wally_mode` string travels as an
  int signal: 0 `"off"` / 1 `"shadow"` / 2 `"on"` (anything unknown → 0,
  fail-safe off).
  """

  @mode_codes %{"off" => 0, "shadow" => 1, "on" => 2}

  @max_delta_deg 6.0
  @deadband_deg 2.0
  @min_confidence 50.0
  @oscillating_regime_code 2
  @upwind_boundary_deg 90.0

  @doc """
  The `wally_mode` policy string as its engine-signal int code:
  0 `"off"` / 1 `"shadow"` / 2 `"on"`; anything else is 0 (fail-safe off).
  """
  @spec mode_code(String.t() | nil) :: 0 | 1 | 2
  def mode_code(mode), do: Map.get(@mode_codes, mode, 0)

  @doc """
  The signed target-TWA modulation in degrees: HALF the (tack-resolved) lift,
  clamped to ±`:max_delta_deg` (default `#{@max_delta_deg}`). Positive widens
  the target angle (foot the lift), negative narrows it (pinch the header).
  """
  @spec delta_deg(number(), keyword()) :: float()
  def delta_deg(wind_lift_deg, opts \\ []) when is_number(wind_lift_deg) do
    max_delta = Keyword.get(opts, :max_delta_deg, @max_delta_deg) / 1
    clamp(wind_lift_deg / 2.0, -max_delta, max_delta)
  end

  @doc """
  Whether the modulation gates are ALL open for
  `%{wind_lift_deg:, wind_regime:, shift_confidence:, twa_deg:}` (the live
  signal values plus the resolved signed TWA): oscillating regime (code 2),
  confidence ≥ #{@min_confidence}, |lift| ≥ #{@deadband_deg}° (deadband), and
  upwind (|twa| < #{@upwind_boundary_deg}°). Missing/non-numeric inputs are
  inactive (fail-safe off).
  """
  @spec active?(map()) :: boolean()
  def active?(%{wind_lift_deg: lift, wind_regime: regime, shift_confidence: confidence, twa_deg: twa})
      when is_number(lift) and is_number(regime) and is_number(confidence) and is_number(twa) do
    regime == @oscillating_regime_code and
      confidence >= @min_confidence and
      abs(lift) >= @deadband_deg and
      abs(twa) < @upwind_boundary_deg
  end

  def active?(_inputs), do: false

  defp clamp(value, lo, _hi) when value < lo, do: lo
  defp clamp(value, _lo, hi) when value > hi, do: hi
  defp clamp(value, _lo, _hi), do: value
end
