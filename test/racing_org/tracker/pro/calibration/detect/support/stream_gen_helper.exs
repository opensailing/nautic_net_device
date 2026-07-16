defmodule RacingOrg.Tracker.Pro.Calibration.Detect.StreamGen do
  @moduledoc false

  # Deterministic synthetic 1 Hz sample streams from a scripted truth, for the
  # calibration maneuver-detection tests.
  #
  # A script is a list of segments, executed in order on a continuous clock:
  #
  #   * `{:steady, dur_s, truth}` — hold `%{heading:, stw:, twd:, tws:}`.
  #   * `{:turn, dur_s, truth}` — wrap-aware linear heading sweep `:from` ->
  #     `:to` (plus `:stw`, `:twd`, `:tws`). An optional `wiggle: {amp_deg,
  #     period_s}` superimposes a sinusoidal meander on the sweep.
  #   * `{:gap, dur_s}` — the clock advances but no samples are emitted.
  #
  # Wind is specified as TRUTH (`twd` = direction the wind blows FROM, `tws`);
  # the apparent wind fields (`awa_deg` signed starboard-positive, `aws_mps`)
  # are derived from the (noisy) heading/stw/tws via the standard apparent-wind
  # triangle, and `cog_deg`/`sog_mps` mirror heading/stw (no current, no
  # leeway). Every value is reproducible: the generator seeds `:rand` (process
  # local, async-test safe) from the `:seed` option before emitting.
  #
  # Noise is "gaussian-ish" but BOUNDED (Irwin-Hall: sum of three uniforms,
  # scaled): `|noise| <= amp` and `sd ~= amp / 3`, so tests can reason about
  # worst-case sample-to-sample deltas as well as dispersion.
  #
  # Options:
  #
  #   * `:seed` — 3-tuple for `:rand.seed(:exsss, _)` (default `{101, 102, 103}`)
  #   * `:noise` — `%{heading: amp, stw: amp, tws: amp}` merged over defaults
  #     (`heading: 0.5`, `stw: 0.015`, `tws: 0.1`)
  #   * `:drop` — list of sample keys to nil out (e.g. `[:cog_deg, :sog_mps]`)
  #   * `:heel` — constant heel value stamped on every sample (default `12.0`)
  #   * `:t0_ms` — start timestamp (default `0`)

  @default_noise %{heading: 0.5, stw: 0.015, tws: 0.1}
  @deg2rad :math.pi() / 180.0
  @rad2deg 180.0 / :math.pi()

  def generate(script, opts \\ []) do
    :rand.seed(:exsss, Keyword.get(opts, :seed, {101, 102, 103}))

    noise = Map.merge(@default_noise, Keyword.get(opts, :noise, %{}))
    drop = Keyword.get(opts, :drop, [])
    heel = Keyword.get(opts, :heel, 12.0)
    t0 = Keyword.get(opts, :t0_ms, 0)

    {samples, _t} =
      Enum.reduce(script, {[], t0}, fn segment, {acc, t} ->
        emit_segment(segment, t, noise, drop, heel, acc)
      end)

    Enum.reverse(samples)
  end

  defp emit_segment({:gap, dur_s}, t, _noise, _drop, _heel, acc), do: {acc, t + dur_s * 1000}

  defp emit_segment({:steady, dur_s, truth}, t, noise, drop, heel, acc) do
    emit(dur_s, t, noise, drop, heel, acc, fn _i -> truth.heading end, truth)
  end

  defp emit_segment({:turn, dur_s, truth}, t, noise, drop, heel, acc) do
    swing = wrapped_delta(truth.from, truth.to)
    {wiggle_amp, wiggle_period} = Map.get(truth, :wiggle, {0.0, 1.0})

    heading_fn = fn i ->
      progress = i / max(dur_s - 1, 1)
      wiggle = wiggle_amp * :math.sin(2.0 * :math.pi() * i / wiggle_period)
      normalize(truth.from + swing * progress + wiggle)
    end

    emit(dur_s, t, noise, drop, heel, acc, heading_fn, truth)
  end

  defp emit(dur_s, t, noise, drop, heel, acc, heading_fn, truth) do
    acc =
      Enum.reduce(0..(dur_s - 1), acc, fn i, acc ->
        heading = normalize(heading_fn.(i) + gauss(noise.heading))
        stw = max(truth.stw + gauss(noise.stw), 0.0)
        tws = max(truth.tws + gauss(noise.tws), 0.0)
        twa = wrapped_delta(heading, truth.twd)
        {awa, aws} = apparent(twa, tws, stw)

        sample = %{
          t_ms: t + i * 1000,
          heading_deg: heading,
          cog_deg: heading,
          sog_mps: stw,
          stw_mps: stw,
          awa_deg: awa,
          aws_mps: aws,
          tws_mps: tws,
          heel_deg: heel
        }

        [Enum.reduce(drop, sample, &Map.put(&2, &1, nil)) | acc]
      end)

    {acc, t + dur_s * 1000}
  end

  # Apparent wind from the wind triangle (no current, no leeway). `twa` is the
  # signed true wind angle off the bow (starboard positive); the sign carries
  # through to AWA.
  defp apparent(twa, tws, stw) do
    x = tws * :math.cos(twa * @deg2rad) + stw
    y = tws * :math.sin(twa * @deg2rad)
    {:math.atan2(y, x) * @rad2deg, :math.sqrt(x * x + y * y)}
  end

  # Bounded gaussian-ish noise: Irwin-Hall sum of three uniforms, centered and
  # scaled so |result| <= amp with sd ~= amp / 3.
  defp gauss(amp) do
    (:rand.uniform() + :rand.uniform() + :rand.uniform() - 1.5) * (amp / 1.5)
  end

  defp wrapped_delta(a, b) do
    d = :math.fmod(b - a + 180.0, 360.0)
    d = if d < 0.0, do: d + 360.0, else: d
    d - 180.0
  end

  defp normalize(deg) do
    d = :math.fmod(deg + 0.0, 360.0)
    if d < 0.0, do: d + 360.0, else: d
  end
end
