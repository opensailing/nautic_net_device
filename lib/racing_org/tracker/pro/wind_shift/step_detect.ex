defmodule RacingOrg.Tracker.Pro.WindShift.StepDetect do
  @moduledoc """
  Persistent-shift (STEP) detector: two-sided Page–Hinkley with run-length
  confirmation.

  Persistent shifts come in two shapes: STEPS (fronts / sea-breeze onset, 25–90°
  within minutes) and RAMPS (5–15°/h, which the Kalman trend handles). This
  module finds the steps on a RESIDUAL stream — the wrap-aware deviation of TWD
  from a slow reference (the caller feeds e.g. `wrapped_delta(slow_mean, twd)`;
  KF innovations also work but decay as the filter absorbs the step, so the
  slow-reference residual is the intended input).

  ## Candidate: two-sided Page–Hinkley

  With drift `δ` (default 0.5°) and threshold `h` (default 8°), the up-side
  statistic `U_t = Σ (x_i − δ)` and its running minimum `U_min` flag a candidate
  when `U_t − U_min > h`; the down side mirrors with `Σ (x_i + δ)` against a
  running maximum. The onset is BACKDATED to the time of the extremum, and the
  running mean of the residual since onset (`m̄`, maintained incrementally) is
  the magnitude estimate.

  ## Confirmation: run-length + revert band

  An oscillation half-cycle looks exactly like a step for half a period, so a
  candidate must survive:

    * **revert band** — after `:settle_s` (default 30 s), if `|m̄|` falls below
      `:band_deg` (default 2°) or flips sign, the candidate is DISCARDED and the
      detector re-arms (an oscillation's mean over a full period washes to ~0,
      so tracked oscillations candidate-flicker but never confirm);
    * **fast path** — `|m̄| ≥ :fast_confirm_deg` (default 25°) sustained for
      `:fast_confirm_s` (default 90 s) confirms immediately: no boundary-layer
      oscillation reaches ±25° (research bound ±20°), so waiting a full period
      would only cost tactical time on a front;
    * **normal path** — after `min(period_hint, :max_confirm_s)` (default
      480 s = 8 min) since onset, `|m̄| ≥ :min_magnitude_deg` (default 8°)
      confirms; anything smaller at that point is discarded (a ramp's
      slow-reference lag offset is τ·rate ≈ 2–4° and must NOT confirm).

  Once `:confirmed`, the state FREEZES (onset, magnitude) until the caller
  absorbs the shift and calls `reset/1` to re-baseline.

  Pure data structure + functions: no processes, no IO.
  """

  defstruct delta_deg: 0.5,
            threshold_deg: 8.0,
            band_deg: 2.0,
            settle_s: 30.0,
            min_magnitude_deg: 8.0,
            fast_confirm_deg: 25.0,
            fast_confirm_s: 90.0,
            max_confirm_s: 480.0,
            period_hint_s: nil,
            status: :none,
            # Page-Hinkley up side: statistic, extremum, extremum time, and the
            # incremental sum/count of residuals since the extremum.
            u: 0.0,
            u_min: 0.0,
            u_min_ms: nil,
            u_sum: 0.0,
            u_n: 0,
            # Down side (mirror).
            d: 0.0,
            d_max: 0.0,
            d_max_ms: nil,
            d_sum: 0.0,
            d_n: 0,
            # Candidate / confirmed bookkeeping.
            dir: nil,
            onset_ms: nil,
            cand_sum: 0.0,
            cand_n: 0,
            magnitude: nil

  @type t :: %__MODULE__{}

  @typedoc "Point-in-time view of the detector."
  @type snapshot :: %{
          status: :none | :candidate | :confirmed,
          onset_ms: integer() | nil,
          magnitude_deg: float() | nil
        }

  @doc """
  Build a fresh detector. Options (all optional): `:delta_deg`, `:threshold_deg`,
  `:band_deg`, `:settle_s`, `:min_magnitude_deg`, `:fast_confirm_deg`,
  `:fast_confirm_s`, `:max_confirm_s`, `:period_hint_s`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      delta_deg: Keyword.get(opts, :delta_deg, 0.5) / 1,
      threshold_deg: Keyword.get(opts, :threshold_deg, 8.0) / 1,
      band_deg: Keyword.get(opts, :band_deg, 2.0) / 1,
      settle_s: Keyword.get(opts, :settle_s, 30.0) / 1,
      min_magnitude_deg: Keyword.get(opts, :min_magnitude_deg, 8.0) / 1,
      fast_confirm_deg: Keyword.get(opts, :fast_confirm_deg, 25.0) / 1,
      fast_confirm_s: Keyword.get(opts, :fast_confirm_s, 90.0) / 1,
      max_confirm_s: Keyword.get(opts, :max_confirm_s, 480.0) / 1,
      period_hint_s: Keyword.get(opts, :period_hint_s)
    }
  end

  @doc """
  Supply (or clear) the current oscillation period estimate; the confirmation
  window is `min(period_hint, max_confirm_s)`.
  """
  @spec put_period_hint(t(), number() | nil) :: t()
  def put_period_hint(%__MODULE__{} = sd, period_s), do: %{sd | period_hint_s: period_s}

  @doc """
  Fold one residual sample (degrees, taken at monotonic `mono_ms`) into the
  detector.
  """
  @spec step(t(), number(), integer()) :: t()
  def step(%__MODULE__{status: :confirmed} = sd, _resid_deg, _mono_ms), do: sd

  def step(%__MODULE__{status: :none} = sd, resid_deg, mono_ms) do
    x = resid_deg / 1

    sd = sd |> ph_up(x, mono_ms) |> ph_down(x, mono_ms)

    up_excess = sd.u - sd.u_min
    down_excess = sd.d_max - sd.d

    cond do
      up_excess > sd.threshold_deg and up_excess >= down_excess -> to_candidate(sd, :up)
      down_excess > sd.threshold_deg -> to_candidate(sd, :down)
      true -> sd
    end
  end

  def step(%__MODULE__{status: :candidate} = sd, resid_deg, mono_ms) do
    x = resid_deg / 1
    sd = %{sd | cand_sum: sd.cand_sum + x, cand_n: sd.cand_n + 1}
    mean = sd.cand_sum / sd.cand_n
    elapsed_s = (mono_ms - sd.onset_ms) / 1000.0
    window_s = min(sd.period_hint_s || sd.max_confirm_s, sd.max_confirm_s)

    signed = if sd.dir == :up, do: mean, else: -mean

    cond do
      # Revert: the offset washed out after the settling time.
      elapsed_s >= sd.settle_s and signed < sd.band_deg ->
        rearm(sd)

      # Decisive revert: the mean-since-onset has FLIPPED beyond the band — the
      # shift is going the other way, so re-arm immediately (no settling wait;
      # this keeps the onset backdating sharp when a real step lands while a
      # stale opposite-direction noise candidate is still open).
      sd.cand_n >= 3 and signed < -sd.band_deg ->
        rearm(sd)

      # Fast path: larger than any plausible oscillation, sustained.
      elapsed_s >= sd.fast_confirm_s and abs(mean) >= sd.fast_confirm_deg ->
        confirm(sd, mean)

      # Normal path: survived a full confirmation window with real magnitude.
      elapsed_s >= window_s ->
        if abs(mean) >= sd.min_magnitude_deg, do: confirm(sd, mean), else: rearm(sd)

      true ->
        sd
    end
  end

  @doc """
  Current view. `magnitude_deg` is the running mean-since-onset while
  `:candidate` and the frozen confirmed magnitude while `:confirmed`.
  """
  @spec snapshot(t()) :: snapshot()
  def snapshot(%__MODULE__{status: :none}), do: %{status: :none, onset_ms: nil, magnitude_deg: nil}

  def snapshot(%__MODULE__{status: :candidate} = sd) do
    %{status: :candidate, onset_ms: sd.onset_ms, magnitude_deg: sd.cand_sum / max(sd.cand_n, 1)}
  end

  def snapshot(%__MODULE__{status: :confirmed} = sd) do
    %{status: :confirmed, onset_ms: sd.onset_ms, magnitude_deg: sd.magnitude}
  end

  @doc """
  Re-baseline after the caller has absorbed a confirmed step: clears all
  detection state, keeps the configuration and period hint.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = sd) do
    %__MODULE__{
      delta_deg: sd.delta_deg,
      threshold_deg: sd.threshold_deg,
      band_deg: sd.band_deg,
      settle_s: sd.settle_s,
      min_magnitude_deg: sd.min_magnitude_deg,
      fast_confirm_deg: sd.fast_confirm_deg,
      fast_confirm_s: sd.fast_confirm_s,
      max_confirm_s: sd.max_confirm_s,
      period_hint_s: sd.period_hint_s
    }
  end

  # --- Page-Hinkley sides ------------------------------------------------------

  defp ph_up(sd, x, mono_ms) do
    u = sd.u + x - sd.delta_deg

    if u < sd.u_min or sd.u_min_ms == nil do
      %{sd | u: u, u_min: u, u_min_ms: mono_ms, u_sum: 0.0, u_n: 0}
    else
      %{sd | u: u, u_sum: sd.u_sum + x, u_n: sd.u_n + 1}
    end
  end

  defp ph_down(sd, x, mono_ms) do
    d = sd.d + x + sd.delta_deg

    if d > sd.d_max or sd.d_max_ms == nil do
      %{sd | d: d, d_max: d, d_max_ms: mono_ms, d_sum: 0.0, d_n: 0}
    else
      %{sd | d: d, d_sum: sd.d_sum + x, d_n: sd.d_n + 1}
    end
  end

  defp to_candidate(sd, :up) do
    %{sd | status: :candidate, dir: :up, onset_ms: sd.u_min_ms, cand_sum: sd.u_sum, cand_n: max(sd.u_n, 1)}
  end

  defp to_candidate(sd, :down) do
    %{sd | status: :candidate, dir: :down, onset_ms: sd.d_max_ms, cand_sum: sd.d_sum, cand_n: max(sd.d_n, 1)}
  end

  defp confirm(sd, mean), do: %{sd | status: :confirmed, magnitude: mean}

  # Discard the candidate and re-arm both Page-Hinkley sides from scratch.
  defp rearm(sd) do
    %{
      sd
      | status: :none,
        dir: nil,
        onset_ms: nil,
        cand_sum: 0.0,
        cand_n: 0,
        u: 0.0,
        u_min: 0.0,
        u_min_ms: nil,
        u_sum: 0.0,
        u_n: 0,
        d: 0.0,
        d_max: 0.0,
        d_max_ms: nil,
        d_sum: 0.0,
        d_n: 0
    }
  end
end
