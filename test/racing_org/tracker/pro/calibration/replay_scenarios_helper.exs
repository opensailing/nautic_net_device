defmodule RacingOrg.Tracker.Pro.Calibration.ReplayScenarios do
  @moduledoc """
  Scripted multi-hour ground-truth scenario generator for the offline replay
  convergence tests (`RacingOrg.Tracker.Pro.Calibration.Replay`).

  Kept separate from `Detect.StreamGen` (which scripts short, error-free
  segment streams for the maneuver-detection tests) because the convergence
  scenarios need what StreamGen deliberately does not model:

    * instrument-error INJECTION (vane rotation / upwash, speedo gain),
    * a TWD random walk with an optional genuine mid-session shift,
    * uniform current (SOG/COG decoupled from heading/STW),
    * wave-induced heading oscillation, and
    * device-computed TWS — derived from the CORRUPTED apparent-wind
      channels through the inverse triangle, as a real instrument chain
      would compute it.

  ## Locked injection conventions (same as `Calibration.Synthetic`)

    * `rotation_error_deg` δ_r — vane rotated toward starboard:
      `awa_meas = awa_true − δ_r`. The correction the estimators must
      recover is `+δ_r`.
    * `upwash_error_deg` δ_u — |AWA| reads HIGH by δ_u on both tacks:
      `awa_meas = awa_true + δ_u · sign(awa_true)`. The recovered
      correction is `−δ_u`.
    * `stw_gain_error` g — the speedo under-reads by the factor g:
      `stw_meas = stw_true / g`. The recovered correction is exactly `g`.

  Wind here is WATER-referenced (the frame the instrument triangle
  recovers), so `apparent = forward_triangle(tws, twa, stw)` holds exactly
  even when a current displaces SOG/COG from heading/STW.

  All randomness comes from the seeded process RNG (`:rand.seed(:exsss, …)`
  is called by every generator), so streams are fully deterministic and
  async-test safe. Per-sample noise on gate-checked channels is BOUNDED
  (Irwin-Hall, |x| ≤ amp) and sized to sit inside the `Detect.Legs`
  steadiness gates: heading amp #{0.4}° (rate gate 2 °/s), STW amp
  #{0.02} m/s (accel gate 0.05 m/s²). AWA noise is genuinely gaussian
  (no gate consumes per-sample AWA deltas).
  """

  @deg_per_rad 180.0 / :math.pi()
  @rad_per_deg :math.pi() / 180.0

  # Bounded per-sample noise amplitudes (see moduledoc).
  @helm_amp 0.4
  @stw_amp 0.02
  @tws_noise_amp 0.1
  @aws_amp 0.05
  @cog_amp 0.3
  @sog_amp 0.02

  @doc """
  A scripted upwind race: alternate-tack legs of `:leg_s` seconds joined by
  `:turn_s`-second tacks, sailed at a constant true-wind angle off a TWD that
  random-walks (per-second gaussian step `:twd_walk_sigma_deg`, clamped to
  `:twd0_deg ± :twd_bound_deg`) and may genuinely step once
  (`twd_step: {at_s, delta_deg}`). TWS breathes sinusoidally
  (`:tws_amp_mps` over `:tws_period_s`). The helmsman sets each leg's compass
  heading from the TWD at the moment the leg starts and then holds it, so
  intra-leg wind wander shows up as AWA/TWD contrast noise — exactly what the
  estimators must absorb.

  Options (defaults): `duration_s 7200`, `leg_s 220`, `turn_s 20`,
  `twd0_deg 20.0`, `twd_walk_sigma_deg 0.05`, `twd_bound_deg 5.0`,
  `twd_step nil`, `tws_mps 6.17` (12 kn), `tws_amp_mps 0.51` (1 kn),
  `tws_period_s 1500`, `stw_mps 3.2`, `twa_abs_deg 42.0`,
  `wave nil` (`{amp_deg, period_s}`), `heel_deg 12.0` (may be nil),
  `rotation_error_deg 0.0`, `upwash_error_deg 0.0`, `awa_sigma_deg 0.0`,
  `stw_gain_error 1.0`, `seed {20_260, 716, 1}`.
  """
  def race_day_beat(opts \\ []) do
    duration_s = Keyword.get(opts, :duration_s, 7_200)
    leg_s = Keyword.get(opts, :leg_s, 220)
    turn_s = Keyword.get(opts, :turn_s, 20)
    twd0 = Keyword.get(opts, :twd0_deg, 20.0)
    walk_sigma = Keyword.get(opts, :twd_walk_sigma_deg, 0.05)
    twd_bound = Keyword.get(opts, :twd_bound_deg, 5.0)
    twd_step = Keyword.get(opts, :twd_step)
    tws0 = Keyword.get(opts, :tws_mps, 6.17)
    tws_amp = Keyword.get(opts, :tws_amp_mps, 0.51)
    tws_period_s = Keyword.get(opts, :tws_period_s, 1_500)
    stw = Keyword.get(opts, :stw_mps, 3.2)
    twa_abs = Keyword.get(opts, :twa_abs_deg, 42.0)
    wave = Keyword.get(opts, :wave)
    heel = Keyword.get(opts, :heel_deg, 12.0)
    inject = inject(opts)

    :rand.seed(:exsss, Keyword.get(opts, :seed, {20_260, 716, 1}))

    cycle_s = leg_s + turn_s

    {samples, _acc} =
      Enum.map_reduce(0..(duration_s - 1), {0.0, 0.0}, fn t, {walk, leg_heading} ->
        walk = clamp(walk + gauss(walk_sigma), -twd_bound, twd_bound)
        twd_t = twd0 + walk + step_offset(twd_step, t)

        k = div(t, cycle_s)
        phase = rem(t, cycle_s)

        # The helmsman commits to a heading from the wind at leg start...
        leg_heading =
          if phase == 0, do: wrap360(twd_t - tack_sign(k) * twa_abs), else: leg_heading

        # ...holds it for the leg, then swings onto the other board.
        base_heading =
          if phase < leg_s do
            leg_heading
          else
            target = wrap360(twd_t - tack_sign(k + 1) * twa_abs)
            frac = (phase - leg_s + 1) / turn_s
            wrap360(leg_heading + wrapped_delta(leg_heading, target) * frac)
          end

        tws_t = tws0 + tws_amp * :math.sin(2.0 * :math.pi() * t / tws_period_s)

        {sample(t, base_heading, twd_t, tws_t, stw, {0.0, 0.0}, wave, heel, inject), {walk, leg_heading}}
      end)

    samples
  end

  @doc """
  A motor-out-and-back delivery: for each speed in `:speeds_mps`,
  `:pairs_per_speed` out/back leg pairs on exact reciprocal headings
  (`:heading_deg` and its reciprocal), each leg `:leg_s` seconds, separated
  by silent `:gap_s`-second turnarounds (no samples — and, at the default
  90 s, deliberately longer than the tack detector's 60 s transition gate,
  so a motoring delivery can never masquerade as tacking). A uniform
  `current: {speed_mps, toward_deg}` displaces SOG/COG from heading/STW;
  the injected `:stw_gain_error` corrupts the speedo.

  Options (defaults): `speeds_mps [3.6, 5.3, 7.4]`, `pairs_per_speed 8`,
  `leg_s 120`, `gap_s 90`, `heading_deg 0.0`, `twd0_deg 40.0`,
  `tws_mps 4.0`, `current {0.4, 40.0}`, `heel_deg 2.0`,
  `awa_sigma_deg 0.5`, `stw_gain_error 1.0`, `seed {20_260, 716, 2}`.
  """
  def delivery_reciprocals(opts \\ []) do
    speeds = Keyword.get(opts, :speeds_mps, [3.6, 5.3, 7.4])
    pairs_per_speed = Keyword.get(opts, :pairs_per_speed, 8)
    leg_s = Keyword.get(opts, :leg_s, 120)
    gap_s = Keyword.get(opts, :gap_s, 90)
    out = Keyword.get(opts, :heading_deg, 0.0)
    twd = Keyword.get(opts, :twd0_deg, 40.0)
    tws = Keyword.get(opts, :tws_mps, 4.0)
    current = Keyword.get(opts, :current, {0.4, 40.0})
    heel = Keyword.get(opts, :heel_deg, 2.0)
    inject = opts |> Keyword.put_new(:awa_sigma_deg, 0.5) |> inject()

    :rand.seed(:exsss, Keyword.get(opts, :seed, {20_260, 716, 2}))

    legs =
      for s <- speeds,
          _i <- 1..pairs_per_speed,
          h <- [out, wrap360(out + 180.0)],
          do: {h, s}

    {chunks, _t_end} =
      Enum.map_reduce(legs, 0, fn {heading, stw}, t0 ->
        chunk =
          for i <- 0..(leg_s - 1) do
            sample(t0 + i, heading, twd, tws, stw, current, nil, heel, inject)
          end

        {chunk, t0 + leg_s + gap_s}
      end)

    List.flatten(chunks)
  end

  @doc """
  A delivery holding ONE board for the whole session: the race-day beat with
  a single leg as long as the session, so no tack, gybe, or reciprocal ever
  occurs. Takes the same options as `race_day_beat/1`.
  """
  def single_tack_delivery(opts \\ []) do
    duration_s = Keyword.get(opts, :duration_s, 7_200)

    opts
    |> Keyword.put(:duration_s, duration_s)
    |> Keyword.put(:leg_s, duration_s + 1)
    |> Keyword.put(:turn_s, 1)
    |> race_day_beat()
  end

  @doc """
  Forward wind triangle, independent of the modules under test: true wind
  (`tws`, signed `twa_deg`) + `stw` → `{aws, awa_deg}` (signed, starboard
  positive).
  """
  def apparent(tws, twa_deg, stw) do
    twa = twa_deg * @rad_per_deg
    ax = tws * :math.cos(twa) + stw
    ay = tws * :math.sin(twa)
    {:math.sqrt(ax * ax + ay * ay), :math.atan2(ay, ax) * @deg_per_rad}
  end

  @doc """
  Inverse wind triangle, independent of the modules under test: apparent wind
  (`aws`, signed `awa_deg`) + `stw` → `{tws, twa_deg}` — what an instrument
  chain computes for TWS/TWA from its (possibly corrupted) channels.
  """
  def true_wind(aws, awa_deg, stw) do
    awa = awa_deg * @rad_per_deg
    ty = aws * :math.sin(awa)
    tx = aws * :math.cos(awa) - stw
    {:math.sqrt(tx * tx + ty * ty), :math.atan2(ty, tx) * @deg_per_rad}
  end

  # =====================================================================
  # One synthesized sample
  # =====================================================================

  # Truth: base heading (+ wave + helm wobble), water-referenced wind, STW,
  # uniform current. Measurement: injected vane/speedo errors, bounded channel
  # noise, and TWS recomputed from the corrupted channels.
  defp sample(t, base_heading, twd, tws_base, stw_base, {c_mps, c_toward}, wave, heel, inj) do
    heading = wrap360(base_heading + wave_offset(wave, t) + ih(@helm_amp))
    stw_true = max(stw_base + ih(@stw_amp), 0.0)
    tws_true = max(tws_base + ih(@tws_noise_amp), 0.0)

    twa = wrap180(twd - heading)
    {aws_true, awa_true} = apparent(tws_true, twa, stw_true)

    awa_meas =
      wrap180(awa_true - inj.rotation + inj.upwash * sgn(awa_true) + gauss(inj.awa_sigma))

    aws_meas = max(aws_true + ih(@aws_amp), 0.0)
    stw_meas = stw_true / inj.stw_gain

    # Ground velocity = through-water velocity + current (east/north).
    ge = stw_true * sin_deg(heading) + c_mps * sin_deg(c_toward)
    gn = stw_true * cos_deg(heading) + c_mps * cos_deg(c_toward)
    sog = max(:math.sqrt(ge * ge + gn * gn) + ih(@sog_amp), 0.0)
    cog = wrap360(:math.atan2(ge, gn) * @deg_per_rad + ih(@cog_amp))

    {tws_device, _twa_device} = true_wind(aws_meas, awa_meas, stw_meas)

    %{
      t_ms: t * 1000,
      heading_deg: heading,
      cog_deg: cog,
      sog_mps: sog,
      stw_mps: stw_meas,
      awa_deg: awa_meas,
      aws_mps: aws_meas,
      tws_mps: tws_device,
      heel_deg: heel
    }
  end

  defp inject(opts) do
    %{
      rotation: Keyword.get(opts, :rotation_error_deg, 0.0),
      upwash: Keyword.get(opts, :upwash_error_deg, 0.0),
      awa_sigma: Keyword.get(opts, :awa_sigma_deg, 0.0),
      stw_gain: Keyword.get(opts, :stw_gain_error, 1.0)
    }
  end

  # =====================================================================
  # Numeric plumbing
  # =====================================================================

  # Even cycles are starboard tack (heading = TWD − TWA), odd are port.
  defp tack_sign(k), do: if(rem(k, 2) == 0, do: 1.0, else: -1.0)

  defp step_offset({at_s, delta}, t) when t >= at_s, do: delta
  defp step_offset(_step, _t), do: 0.0

  defp wave_offset(nil, _t), do: 0.0

  defp wave_offset({amp, period_s}, t),
    do: amp * :math.sin(2.0 * :math.pi() * t / period_s)

  # Bounded "gaussian-ish" noise (Irwin-Hall, |x| <= amp, sd ~= amp/3).
  defp ih(amp) do
    (:rand.uniform() + :rand.uniform() + :rand.uniform() - 1.5) * (amp / 1.5)
  end

  # True gaussian noise from the seeded process RNG (:rand.normal takes VARIANCE).
  defp gauss(sigma) when sigma <= 0.0, do: 0.0
  defp gauss(sigma), do: :rand.normal(0.0, sigma * sigma)

  defp sgn(x) when x < 0, do: -1.0
  defp sgn(_x), do: 1.0

  defp clamp(x, lo, hi), do: x |> max(lo) |> min(hi)

  defp sin_deg(deg), do: :math.sin(deg * @rad_per_deg)
  defp cos_deg(deg), do: :math.cos(deg * @rad_per_deg)

  defp wrap360(deg) do
    r = :math.fmod(deg, 360.0)
    if r < 0, do: r + 360.0, else: r + 0.0
  end

  defp wrap180(deg) do
    r = :math.fmod(deg, 360.0)

    cond do
      r > 180.0 -> r - 360.0
      r <= -180.0 -> r + 360.0
      true -> r + 0.0
    end
  end

  # Shortest signed angular path a -> b, in (−180, 180].
  defp wrapped_delta(a, b), do: wrap180(b - a)
end
