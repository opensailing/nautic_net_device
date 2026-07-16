defmodule RacingOrg.Tracker.Pro.Calibration.Synthetic do
  @moduledoc """
  Ground-truth synthetic leg/pair generator for the calibration estimator tests.

  Builds EXACT leg aggregates from chosen truth (TWD/TWS/STW/current), computing the
  true apparent wind per tack via a forward wind triangle implemented HERE —
  independently of the `WindTriangle` module under test — then injects KNOWN errors
  to produce the "measured" legs. These tests DEFINE the sign conventions:

    * **rotation δ_r** — vane rotated toward starboard by δ_r reads
      `awa_meas = awa_true − δ_r` (signed AWA, starboard positive). Starboard-tack
      |AWA| therefore reads LOW by δ_r and port-tack |AWA| reads HIGH by δ_r. The
      additive correction that restores truth is `+δ_r`.

    * **upwash δ_u** — |AWA| reads HIGH by δ_u on BOTH tacks:
      `awa_meas = awa_true + δ_u · sign(awa_true)`. The side-signed correction
      (applied as `awa + upwash · sign(awa)`) that restores truth is `−δ_u`.

    * **STW gain error g** — the speedo under-reads by the factor g:
      `stw_meas = stw_true / g`, so the multiplicative CORRECTION that restores
      truth is exactly `g`.

  Gaussian noise (when requested) uses the seeded process RNG (`:rand`), so tests
  seed `:rand.seed(:exsss, {…})` for determinism.
  """

  @deg_per_rad 180.0 / :math.pi()
  @rad_per_deg :math.pi() / 180.0

  @doc """
  A matched tack pair `%{starboard: leg, port: leg, gap_s: gap}` sailed in truth
  wind `:twd` / `:tws` at `:stw` through the water, `:twa_abs` degrees off the true
  wind on each tack, with injected `:rotation` (δ_r), `:upwash` (δ_u) and per-leg
  gaussian noise `:noise_sigma` (deg, on the AWA leg mean). No current: SOG = STW.
  """
  def tack_pair(opts \\ []) do
    twd = Keyword.get(opts, :twd, 200.0)
    tws = Keyword.get(opts, :tws, 6.0)
    stw = Keyword.get(opts, :stw, 3.5)
    twa_abs = Keyword.get(opts, :twa_abs, 42.0)
    rotation = Keyword.get(opts, :rotation, 0.0)
    upwash = Keyword.get(opts, :upwash, 0.0)
    sigma = Keyword.get(opts, :noise_sigma, 0.0)

    %{
      starboard: tack_leg(:starboard, 1.0, twd, tws, stw, twa_abs, rotation, upwash, sigma),
      port: tack_leg(:port, -1.0, twd, tws, stw, twa_abs, rotation, upwash, sigma),
      gap_s: 30.0
    }
  end

  defp tack_leg(side, sign, twd, tws, stw, twa_abs, rotation, upwash, sigma) do
    heading = wrap360(twd - sign * twa_abs)
    twa_true = sign * twa_abs
    {aws_true, awa_true} = apparent(tws, twa_true, stw)

    awa_meas = awa_true - rotation + upwash * sgn(awa_true) + noise(sigma)

    %{
      duration_s: 120.0,
      samples: 120,
      side: side,
      heading_mean: heading,
      cog_mean: heading,
      sog_mean: stw,
      stw_mean: stw,
      awa_mean_signed: awa_meas,
      awa_abs_mean: abs(awa_meas),
      aws_mean: aws_true,
      tws_mean: tws,
      heel_mean: nil
    }
  end

  @doc """
  A reciprocal pair `%{a: leg, b: leg}`: leg `a` on `:heading`, leg `b` on the exact
  reciprocal, both at `:stw` (m/s, TRUE through-water speed) in a uniform current of
  `:current_speed` m/s flowing TOWARD `:current_toward_deg`. The injected STW gain
  error `:gain` makes `stw_meas = stw_true / gain`; SOG/COG are the exact
  ground-frame values (water velocity + current).
  """
  def reciprocal_pair(opts \\ []) do
    heading = Keyword.get(opts, :heading, 0.0)
    stw = Keyword.get(opts, :stw, 4.0)
    gain = Keyword.get(opts, :gain, 1.0)
    c = Keyword.get(opts, :current_speed, 0.0)
    c_toward = Keyword.get(opts, :current_toward_deg, 0.0)
    sigma = Keyword.get(opts, :noise_sigma, 0.0)

    %{
      a: reciprocal_leg(:starboard, heading, stw, gain, c, c_toward, sigma),
      b: reciprocal_leg(:port, wrap360(heading + 180.0), stw, gain, c, c_toward, sigma)
    }
  end

  defp reciprocal_leg(side, heading, stw, gain, c, c_toward, sigma) do
    h = heading * @rad_per_deg
    cd = c_toward * @rad_per_deg

    # Ground velocity = through-water velocity + current (east/north components).
    ge = stw * :math.sin(h) + c * :math.sin(cd)
    gn = stw * :math.cos(h) + c * :math.cos(cd)

    sog = :math.sqrt(ge * ge + gn * gn) + noise(sigma)
    cog = wrap360(:math.atan2(ge, gn) * @deg_per_rad)
    stw_meas = stw / gain + noise(sigma)

    %{
      duration_s: 180.0,
      samples: 180,
      side: side,
      heading_mean: heading,
      cog_mean: cog,
      sog_mean: sog,
      stw_mean: stw_meas,
      awa_mean_signed: 90.0,
      awa_abs_mean: 90.0,
      aws_mean: 6.0,
      tws_mean: 6.0,
      heel_mean: nil
    }
  end

  @doc """
  Forward wind triangle (independent of the module under test): true wind
  (`tws`, signed `twa_deg`) + STW → `{aws, awa_deg}` (signed, starboard positive).
  """
  def apparent(tws, twa_deg, stw) do
    twa = twa_deg * @rad_per_deg
    ax = tws * :math.cos(twa) + stw
    ay = tws * :math.sin(twa)
    {:math.sqrt(ax * ax + ay * ay), :math.atan2(ay, ax) * @deg_per_rad}
  end

  @doc "Gaussian noise from the (seeded) process RNG; `0.0` sigma is exactly zero."
  def noise(sigma) when sigma <= 0.0, do: 0.0
  def noise(sigma), do: :rand.normal(0.0, sigma * sigma)

  defp sgn(x) when x < 0, do: -1.0
  defp sgn(_x), do: 1.0

  defp wrap360(deg) do
    r = :math.fmod(deg, 360.0)
    if r < 0, do: r + 360.0, else: r + 0.0
  end
end
