defmodule RacingOrg.Tracker.Pro.WindShift.Means do
  @moduledoc """
  Multi-timescale circular means of true wind direction — the tactical phase/lift
  primitive of the wind-shift predictor.

  Boundary-layer oscillating shifts (convective rolls) run 3–20 min periods at
  ±5–20° amplitude, while persistent shifts move the reference itself (fronts and
  sea-breeze onsets STEP 25–90° in minutes; sea-breeze veers RAMP 5–15°/h). The
  tactical primitive that survives all of that is the SIGNED DEVIATION of the
  current wind from a reference mean, which this module computes from three
  time-constant circular EWMAs over the same TWD stream:

    * **fast** (τ 30 s) — "the wind right now", de-jittered
    * **mid** (τ 300 s) — the current oscillation half-cycle
    * **slow** (τ 1500 s) — the day's reference direction

  `phase_deg` is the wrap-aware signed deviation `fast − slow` (positive =
  veered/right of the reference — a lift on starboard tack, a header on port).

  `stability` is the mean resultant length (`R ∈ [0, 1]`) of a parallel
  unit-vector EWMA at the slow time constant: the sin/cos components are smoothed
  LINEARLY (no per-step renormalization), so `R` decays with circular variance
  (`R ≈ 1 − var/2`). It is the confidence weight for the reference mean — steady
  wind reads ~1.0, an unsettled or boxing wind decays toward 0.

  ## Gaps

  Each EWMA derives its blend factor from the actual elapsed time
  (`α = 1 − exp(−Δt/τ)`, see `RacingOrg.Tracker.Pro.Telemetry.Ewma`), so gaps
  need no special casing: a gap longer than ~3·τ_fast (≈ 90 s at the default)
  yields α ≈ 1 for the fast mean, which therefore effectively RESETS onto the
  first post-gap sample, while the slow mean only blends a small step toward it.

  Pure data structure + functions: no processes, no IO.
  """

  alias RacingOrg.Tracker.Pro.Calibration.Detect.Circular
  alias RacingOrg.Tracker.Pro.Telemetry.Ewma

  @deg2rad :math.pi() / 180.0
  @rad2deg 180.0 / :math.pi()

  defstruct tau_fast_s: 30.0,
            tau_mid_s: 300.0,
            tau_slow_s: 1500.0,
            fast: nil,
            mid: nil,
            slow: nil,
            # Linear EWMAs of the unit-vector components at tau_slow, for `stability`.
            sin: nil,
            cos: nil

  @type t :: %__MODULE__{}

  @typedoc "Point-in-time view of the three means (degrees, `[0, 360)`)."
  @type snapshot :: %{
          fast: float() | nil,
          mid: float() | nil,
          slow: float() | nil,
          phase_deg: float() | nil,
          stability: float() | nil
        }

  @doc """
  Build a fresh multi-timescale mean.

  Options: `:tau_fast_s` (default 30), `:tau_mid_s` (300), `:tau_slow_s` (1500),
  all in seconds.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      tau_fast_s: Keyword.get(opts, :tau_fast_s, 30.0) / 1,
      tau_mid_s: Keyword.get(opts, :tau_mid_s, 300.0) / 1,
      tau_slow_s: Keyword.get(opts, :tau_slow_s, 1500.0) / 1
    }
  end

  @doc """
  Fold one TWD sample (degrees, any wrap) taken at monotonic `mono_ms` into all
  three means and the stability vector.
  """
  @spec update(t(), number(), integer()) :: t()
  def update(%__MODULE__{} = means, twd_deg, mono_ms) do
    rad = twd_deg * @deg2rad

    {_, fast} = Ewma.update(means.fast, rad, mono_ms, means.tau_fast_s, :circular)
    {_, mid} = Ewma.update(means.mid, rad, mono_ms, means.tau_mid_s, :circular)
    {_, slow} = Ewma.update(means.slow, rad, mono_ms, means.tau_slow_s, :circular)
    {_, sin} = Ewma.update(means.sin, :math.sin(rad), mono_ms, means.tau_slow_s, :linear)
    {_, cos} = Ewma.update(means.cos, :math.cos(rad), mono_ms, means.tau_slow_s, :linear)

    %{means | fast: fast, mid: mid, slow: slow, sin: sin, cos: cos}
  end

  @doc """
  Current view: the three means in degrees `[0, 360)`, the signed `phase_deg`
  deviation `fast − slow` in `[-180, 180)` (positive = veered right of the
  reference), and the `stability` resultant length in `[0, 1]`. All `nil`
  before the first sample.
  """
  @spec snapshot(t()) :: snapshot()
  def snapshot(%__MODULE__{fast: nil}) do
    %{fast: nil, mid: nil, slow: nil, phase_deg: nil, stability: nil}
  end

  def snapshot(%__MODULE__{} = means) do
    fast = to_deg(means.fast)
    slow = to_deg(means.slow)

    %{
      fast: fast,
      mid: to_deg(means.mid),
      slow: slow,
      phase_deg: Circular.wrapped_delta(slow, fast),
      stability: resultant(means.sin, means.cos)
    }
  end

  defp to_deg({rad, _ms}), do: Circular.normalize(rad * @rad2deg)

  defp resultant({sin, _}, {cos, _}), do: min(:math.sqrt(sin * sin + cos * cos), 1.0)
end
