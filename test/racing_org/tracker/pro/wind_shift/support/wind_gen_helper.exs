defmodule RacingOrg.Tracker.Pro.WindShift.WindGen do
  @moduledoc false

  # Scripted-truth synthetic 1 Hz TWD/TWS stream generator for the wind-shift
  # predictor tests.
  #
  # A script is a list of segments executed in order on a continuous 1 Hz clock:
  #
  #   * `%{dur_s: n, ...}` — emit `n` samples. Optional keys:
  #       * `:base` — absolute baseline TWD (deg) at segment start. Defaults to
  #         the baseline carried forward from the previous segment (including any
  #         completed ramp), so ramps compose without bookkeeping in the test.
  #       * `:step` — instantaneous offset (deg) added to the carried baseline at
  #         segment start (a front / persistent STEP).
  #       * `:ramp` — linear drift in deg/HOUR across the segment (sea-breeze
  #         RAMP); the drift accumulates into the carried baseline.
  #       * `:osc` — `{amp_deg, period_s}` sinusoid. The oscillation phase is
  #         GLOBAL (`2 * pi * t / period + phase0`), so it is continuous across
  #         segment boundaries as long as amp/period stay the same.
  #       * `:walk_sigma` — random-walk TWD: gaussian-ish increments of this sd
  #         (deg) added per 1 s step, accumulated into the carried baseline
  #         (part of TRUTH, not measurement noise).
  #       * `:tws` — true wind speed in m/s stamped on every sample
  #         (default 6.0).
  #   * `{:gap, dur_s}` — the clock advances, no samples are emitted.
  #
  # Every sample is `%{t_ms:, twd_deg:, truth_deg:, tws_mps:}`:
  #
  #   * `truth_deg` — the noise-free scripted TWD (baseline + ramp + walk + osc),
  #     UNWRAPPED (continuous; may leave [0, 360)). The random walk is truth —
  #     it models the wind actually wandering.
  #   * `twd_deg` — `truth_deg` plus measurement noise, wrapped to [0, 360) like
  #     a real TWD reading.
  #
  # Noise is gaussian-ish but BOUNDED (Irwin-Hall: sum of 12 uniforms minus 6 has
  # sd exactly 1 and |value| <= 6), scaled by `:noise_sigma`, so tests can reason
  # about both dispersion and worst-case excursions. The generator seeds the
  # process-local `:rand` (async-test safe) from `:seed`, so every stream is
  # reproducible.
  #
  # Options:
  #
  #   * `:seed` — 3-tuple for `:rand.seed(:exsss, _)` (default `{2026, 7, 17}`)
  #   * `:noise_sigma` — measurement noise sd in deg (default `0.0`)
  #   * `:t0_ms` — first sample timestamp (default `0`)
  #   * `:osc_phase0` — oscillation phase offset in rad at t = t0 (default `0.0`)

  @default_tws 6.0

  def generate(script, opts \\ []) do
    :rand.seed(:exsss, Keyword.get(opts, :seed, {2026, 7, 17}))

    sigma = Keyword.get(opts, :noise_sigma, 0.0)
    t0_ms = Keyword.get(opts, :t0_ms, 0)
    phase0 = Keyword.get(opts, :osc_phase0, 0.0)

    {samples, _base, _t} =
      Enum.reduce(script, {[], nil, t0_ms}, fn segment, {acc, base, t_ms} ->
        emit_segment(segment, acc, base, t_ms, t0_ms, sigma, phase0)
      end)

    Enum.reverse(samples)
  end

  @doc false
  # Truth TWD deviation of a `{amp, period}` oscillation at absolute time `t_ms`
  # (same global-phase convention as `generate/2`).
  def osc_truth(t_ms, t0_ms, {amp, period_s}, phase0 \\ 0.0) do
    amp * :math.sin(2.0 * :math.pi() * ((t_ms - t0_ms) / 1000.0) / period_s + phase0)
  end

  defp emit_segment({:gap, dur_s}, acc, base, t_ms, _t0, _sigma, _phase0),
    do: {acc, base, t_ms + dur_s * 1000}

  defp emit_segment(%{dur_s: dur_s} = seg, acc, carried, t_ms, t0_ms, sigma, phase0) do
    base = Map.get(seg, :base, carried || 200.0) + Map.get(seg, :step, 0.0)
    ramp_per_s = Map.get(seg, :ramp, 0.0) / 3600.0
    osc = Map.get(seg, :osc)
    walk_sigma = Map.get(seg, :walk_sigma, 0.0)
    tws = Map.get(seg, :tws, @default_tws)

    {acc, base, t_ms} =
      Enum.reduce(0..(dur_s - 1), {acc, base, t_ms}, fn _i, {acc, base, t} ->
        truth =
          case osc do
            nil -> base
            _ -> base + osc_truth(t, t0_ms, osc, phase0)
          end

        twd = normalize(truth + gauss(sigma))
        sample = %{t_ms: t, twd_deg: twd, truth_deg: truth, tws_mps: tws}

        # Advance the baseline: ramp is deterministic drift, walk is stochastic.
        base = base + ramp_per_s + gauss(walk_sigma)
        {[sample | acc], base, t + 1000}
      end)

    {acc, base, t_ms}
  end

  # Gaussian-ish bounded noise: Irwin-Hall sum of 12 uniforms minus 6 has mean 0,
  # sd exactly 1, and is bounded to [-6, 6].
  defp gauss(sigma) when sigma <= 0.0, do: 0.0

  defp gauss(sigma) do
    sum = Enum.reduce(1..12, 0.0, fn _, s -> s + :rand.uniform() end)
    (sum - 6.0) * sigma
  end

  defp normalize(deg) do
    d = :math.fmod(deg, 360.0)
    if d < 0.0, do: d + 360.0, else: d
  end
end
