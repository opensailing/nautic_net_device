defmodule RacingOrg.Tracker.Pro.Calibration.Estimator.WindTriangle do
  @moduledoc """
  The pure wind-triangle math shared by the calibration estimators.

  ## Conventions

    * Angles in DEGREES. AWA/TWA are SIGNED, ±180, starboard positive.
    * Speeds in m/s. STW is speed through the water along the bow axis.
    * `TWD = wrap360(heading + TWA)`; `wrap180` maps into `(−180, 180]`,
      `wrap360` into `[0, 360)`.

  ## The triangle

  In the boat frame (x forward, y to starboard), the apparent wind vector is the
  true wind vector plus the boat's through-water velocity:

      inverse (apparent → true):  ty = AWS·sin(AWA)
                                  tx = AWS·cos(AWA) − STW
                                  TWA = atan2(ty, tx),  TWS = hypot(tx, ty)

      forward (true → apparent):  ax = TWS·cos(TWA) + STW
                                  ay = TWS·sin(TWA)
                                  AWA = atan2(ay, ax),  AWS = hypot(ax, ay)

  This is the FLAT triangle (no heel/pitch refinement): the estimators run on
  per-leg MEAN aggregates where the heel correction (`cos heel` on the
  athwartships component, ≲ 1% under 10° of heel) is far below the leg-to-leg
  scatter the robust trackers already absorb.
  """

  @deg_per_rad 180.0 / :math.pi()
  @rad_per_deg :math.pi() / 180.0

  @doc """
  Inverse triangle: apparent wind (`aws`, signed `awa_deg`) + `stw` →
  `{tws, twa_deg}` with `twa_deg` signed ±180 (starboard positive).
  """
  @spec true_wind(number(), number(), number()) :: {float(), float()}
  def true_wind(aws, awa_deg, stw) do
    awa = awa_deg * @rad_per_deg
    ty = aws * :math.sin(awa)
    tx = aws * :math.cos(awa) - stw
    {:math.sqrt(tx * tx + ty * ty), :math.atan2(ty, tx) * @deg_per_rad}
  end

  @doc """
  Forward triangle: true wind (`tws`, signed `twa_deg`) + `stw` →
  `{aws, awa_deg}` with `awa_deg` signed ±180 (starboard positive).
  """
  @spec apparent_wind(number(), number(), number()) :: {float(), float()}
  def apparent_wind(tws, twa_deg, stw) do
    twa = twa_deg * @rad_per_deg
    ax = tws * :math.cos(twa) + stw
    ay = tws * :math.sin(twa)
    {:math.sqrt(ax * ax + ay * ay), :math.atan2(ay, ax) * @deg_per_rad}
  end

  @doc "True wind direction: `wrap360(heading + twa)`."
  @spec twd(number(), number()) :: float()
  def twd(heading_deg, twa_deg), do: wrap360(heading_deg + twa_deg)

  @doc """
  Local sensitivity `∂TWA/∂AWA` at the given operating point, by central finite
  difference of ±`step_deg` (default 0.5°) through the inverse triangle.
  Close-hauled this is > 1 (subtracting STW amplifies angle changes).
  """
  @spec sensitivity(number(), number(), number(), number()) :: float()
  def sensitivity(aws, awa_deg, stw, step_deg \\ 0.5) do
    {_, twa_hi} = true_wind(aws, awa_deg + step_deg, stw)
    {_, twa_lo} = true_wind(aws, awa_deg - step_deg, stw)
    wrap180(twa_hi - twa_lo) / (2.0 * step_deg)
  end

  @doc "Wrap an angle in degrees into `(−180, 180]`."
  @spec wrap180(number()) :: float()
  def wrap180(deg) do
    r = :math.fmod(deg, 360.0)

    cond do
      r > 180.0 -> r - 360.0
      r <= -180.0 -> r + 360.0
      true -> r + 0.0
    end
  end

  @doc "Wrap an angle in degrees into `[0, 360)`."
  @spec wrap360(number()) :: float()
  def wrap360(deg) do
    r = :math.fmod(deg, 360.0)
    if r < 0, do: r + 360.0, else: r + 0.0
  end
end
