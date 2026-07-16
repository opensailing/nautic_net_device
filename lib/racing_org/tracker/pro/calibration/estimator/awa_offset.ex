defmodule RacingOrg.Tracker.Pro.Calibration.Estimator.AwaOffset do
  @moduledoc """
  Pure estimator that fits TWO scalar AWA corrections from each matched tack pair
  (a starboard leg and a port leg sailed close in time), feeding two embedded
  `Estimate` trackers. No processes, no IO — `observe_pair/2` folds state.

  ## 1. rotation_offset_deg — vane misalignment (tack-ANTISYMMETRIC in |AWA|)

  A vane rotated toward STARBOARD by δ reads `awa_meas = awa_true − δ` on the
  signed scale (starboard positive). So on starboard tack (awa_true > 0) the |AWA|
  reads LOW by δ, and on port tack (awa_true < 0) the |AWA| reads HIGH by δ. The
  additive correction that restores the truth is `+δ`, recovered per pair as:

      rotation_raw = (|awa_port| − |awa_stbd|) / 2

  Applied as `awa_corrected = awa_meas + rotation`.

  ## 2. upwash_offset_deg — side-dependent error (tack-SYMMETRIC in |AWA|)

  Sail upwash inflates (or deflates) the |AWA| by the SAME amount on both tacks:
  an error of δ_u makes `awa_meas = awa_true + δ_u · sign(awa_true)`. It is
  invisible to the rotation fit (it cancels in the |AWA| difference) but it makes
  the wind DIRECTION computed from the two tacks disagree: per leg
  `TWD = wrap360(heading + TWA(awa, aws, stw))`, and an |AWA|-high error pushes
  the starboard TWD up and the port TWD down by `g′·δ_u` each, where
  `g′ = ∂TWA/∂AWA` at the operating point. Per pair (rotation-corrected first):

      twd_delta  = wrap180(TWD_stbd − TWD_port)        # = 2·g′·δ_u
      upwash_raw = −(twd_delta / 2) / g′               # = −δ_u

  `g′` comes from a ±0.5° central finite difference through the wind triangle at
  the starboard operating point (guarded away from degenerate |g′| ≈ 0).

  ## Locked sign conventions (defined by the synthetic-recovery tests)

    * `rotation` is the correction ADDED to signed AWA: injected starboard-rotation
      error δ_r = 3° recovers rotation = **+3.0**.
    * `upwash` is the side-signed correction applied as `awa + upwash · sign(awa)`:
      an injected |AWA|-reads-high error δ_u = 2° recovers upwash = **−2.0** —
      i.e. the ERROR is +δ_u, the CORRECTION is −δ_u.
    * Application order: rotation first, then upwash on the rotated sign.

  Because both fits are pure per-pair contrasts (starboard vs port), slow wind
  shifts and absolute wind errors drop out; residual shift within one pair is
  leg-to-leg noise the median trackers absorb.
  """

  alias RacingOrg.Tracker.Pro.Calibration.Estimate
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.WindTriangle

  defstruct rotation: nil, upwash: nil, pairs_seen: 0, pairs_skipped: 0

  @type leg :: %{
          required(:heading_mean) => number(),
          required(:stw_mean) => number(),
          required(:awa_mean_signed) => number(),
          required(:awa_abs_mean) => number(),
          required(:aws_mean) => number(),
          optional(atom()) => any()
        }

  @type tack_pair :: %{required(:starboard) => leg(), required(:port) => leg(), optional(atom()) => any()}

  @type t :: %__MODULE__{
          rotation: Estimate.Tracker.t(),
          upwash: Estimate.Tracker.t(),
          pairs_seen: non_neg_integer(),
          pairs_skipped: non_neg_integer()
        }

  # Estimator-specific Estimate defaults: corrections are a few degrees at most.
  @default_max_spread 2.0
  @default_clamp 10.0
  @default_max_slew 0.5

  # Sanity floors: a leg drifting slower than this, or with no apparent wind,
  # cannot support a wind-triangle fit.
  @min_stw_mps 0.5
  @min_aws_mps 0.5

  # |∂TWA/∂AWA| below this is a degenerate operating point (apparent wind
  # collapsing onto the bow axis); the upwash division would explode.
  @min_sensitivity 0.05

  @doc """
  Build a fresh estimator. Options are forwarded to BOTH embedded `Estimate`
  trackers, with estimator-specific defaults: `max_spread: 2.0` (degrees),
  `clamp_min/clamp_max: ∓10.0`, `max_slew: 0.5`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    defaults = [
      max_spread: @default_max_spread,
      clamp_min: -@default_clamp,
      clamp_max: @default_clamp,
      max_slew: @default_max_slew
    ]

    est_opts = Keyword.merge(defaults, opts)

    %__MODULE__{rotation: Estimate.new(est_opts), upwash: Estimate.new(est_opts)}
  end

  @doc """
  Fold one matched tack pair into both trackers. Pairs that fail sanity checks
  (missing fields, boat not moving, no apparent wind, or signed AWA inconsistent
  with the tack labels) are counted in `pairs_skipped` and otherwise ignored.
  """
  @spec observe_pair(t(), tack_pair()) :: t()
  def observe_pair(%__MODULE__{} = t, %{starboard: stbd, port: port}) do
    if sane_leg?(stbd, :starboard) and sane_leg?(port, :port) do
      rotation_raw = (port.awa_abs_mean - stbd.awa_abs_mean) / 2

      t = %{t | rotation: Estimate.observe(t.rotation, rotation_raw), pairs_seen: t.pairs_seen + 1}

      case upwash_raw(stbd, port, rotation_raw) do
        {:ok, raw} -> %{t | upwash: Estimate.observe(t.upwash, raw)}
        :skip -> t
      end
    else
      %{t | pairs_skipped: t.pairs_skipped + 1}
    end
  end

  @doc "Snapshot of both corrections: `%{rotation: %Estimate{}, upwash: %Estimate{}}`."
  @spec snapshot(t()) :: %{rotation: Estimate.t(), upwash: Estimate.t()}
  def snapshot(%__MODULE__{} = t) do
    %{rotation: Estimate.snapshot(t.rotation), upwash: Estimate.snapshot(t.upwash)}
  end

  # --- internal ---

  # The per-pair upwash contrast: rotation-correct each leg's AWA (with THIS
  # pair's own rotation estimate, keeping the two fits separable pair-by-pair),
  # push both through the wind triangle to a per-leg TWD, and convert the
  # starboard-vs-port TWD disagreement back to an AWA-scale correction via the
  # local sensitivity g′ at the starboard operating point.
  defp upwash_raw(stbd, port, rotation_raw) do
    awa_stbd = stbd.awa_mean_signed + rotation_raw
    awa_port = port.awa_mean_signed + rotation_raw

    {_tws_s, twa_stbd} = WindTriangle.true_wind(stbd.aws_mean, awa_stbd, stbd.stw_mean)
    {_tws_p, twa_port} = WindTriangle.true_wind(port.aws_mean, awa_port, port.stw_mean)

    twd_stbd = WindTriangle.twd(stbd.heading_mean, twa_stbd)
    twd_port = WindTriangle.twd(port.heading_mean, twa_port)
    twd_delta = WindTriangle.wrap180(twd_stbd - twd_port)

    g = WindTriangle.sensitivity(stbd.aws_mean, awa_stbd, stbd.stw_mean)

    if abs(g) < @min_sensitivity do
      :skip
    else
      {:ok, -(twd_delta / 2) / g}
    end
  end

  defp sane_leg?(leg, side) do
    is_number(leg[:heading_mean]) and is_number(leg[:awa_mean_signed]) and
      is_number(leg[:awa_abs_mean]) and
      is_number(leg[:aws_mean]) and leg.aws_mean > @min_aws_mps and
      is_number(leg[:stw_mean]) and leg.stw_mean > @min_stw_mps and
      tack_sign_ok?(leg.awa_mean_signed, side)
  end

  # Signed AWA is starboard-positive: a starboard-tack leg must carry the wind on
  # the starboard side and vice versa, or the pair is mislabeled.
  defp tack_sign_ok?(awa, :starboard), do: awa > 0
  defp tack_sign_ok?(awa, :port), do: awa < 0
end
