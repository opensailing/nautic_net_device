defmodule RacingOrg.Tracker.Pro.Calibration.Detect.Circular do
  @moduledoc """
  Wrap-aware angle arithmetic and streaming circular statistics (degrees).

  Compass angles cannot be averaged or differenced arithmetically — `359°` and
  `1°` are 2° apart, and their arithmetic mean (180°) points the wrong way.
  This module carries the same wrap conventions as
  `RacingOrg.Tracker.Pro.Polar.Observer.Gate.wrapped_delta/2` and adds the
  *running-sum* circular mean / standard deviation that the calibration leg
  detectors need for bounded-memory streaming: fold each angle's sine and
  cosine into two running sums; the mean is `atan2(sin_sum, cos_sum)` and the
  dispersion is Mardia's circular standard deviation `sqrt(-2 ln R)`, where
  `R` is the mean resultant length `|(sin_sum, cos_sum)| / n`.
  """

  @deg2rad :math.pi() / 180.0
  @rad2deg 180.0 / :math.pi()

  # Below this resultant length the mean direction is numerically meaningless
  # (no data, or angles perfectly dispersed around the circle).
  @degenerate_resultant 1.0e-9

  @doc """
  Smallest signed angular difference `b - a` in degrees, wrapped to
  `[-180.0, 180.0)`.
  """
  @spec wrapped_delta(number(), number()) :: float()
  def wrapped_delta(a, b) do
    d = :math.fmod(b - a + 180.0, 360.0)
    d = if d < 0.0, do: d + 360.0, else: d
    d - 180.0
  end

  @doc """
  Absolute wrap-aware angular distance between two angles, in `[0.0, 180.0]`.
  """
  @spec distance(number(), number()) :: float()
  def distance(a, b), do: abs(wrapped_delta(a, b))

  @doc """
  Normalize an angle to `[0.0, 360.0)`.
  """
  @spec normalize(number()) :: float()
  def normalize(deg) do
    remainder = :math.fmod(deg + 0.0, 360.0)
    normalized = if remainder < 0.0, do: remainder + 360.0, else: remainder

    if normalized == 0.0 or normalized >= 360.0, do: 0.0, else: normalized
  end

  @doc """
  Sine of an angle given in degrees (for folding into a running sum).
  """
  @spec sin_deg(number()) :: float()
  def sin_deg(deg), do: :math.sin(deg * @deg2rad)

  @doc """
  Cosine of an angle given in degrees (for folding into a running sum).
  """
  @spec cos_deg(number()) :: float()
  def cos_deg(deg), do: :math.cos(deg * @deg2rad)

  @doc """
  Circular mean in degrees (`[0.0, 360.0)`) from running sine/cosine sums, or
  `nil` when the resultant is numerically zero (no data, or fully dispersed —
  there is no meaningful mean direction). The sample count cancels out, so
  the raw sums are used directly.
  """
  @spec mean_from_sums(float(), float()) :: float() | nil
  def mean_from_sums(sin_sum, cos_sum) do
    if :math.sqrt(sin_sum * sin_sum + cos_sum * cos_sum) < @degenerate_resultant do
      nil
    else
      normalize(:math.atan2(sin_sum, cos_sum) * @rad2deg)
    end
  end

  @doc """
  Circular standard deviation in degrees from running sine/cosine sums over
  `n` angles: `sqrt(-2 ln R) * 180 / pi`, capped at `180.0` as `R -> 0`.
  Returns `0.0` for fewer than two angles (nothing to disagree on).
  """
  @spec sd_from_sums(float(), float(), non_neg_integer()) :: float()
  def sd_from_sums(_sin_sum, _cos_sum, n) when n < 2, do: 0.0

  def sd_from_sums(sin_sum, cos_sum, n) do
    r = min(:math.sqrt(sin_sum * sin_sum + cos_sum * cos_sum) / n, 1.0)

    if r < @degenerate_resultant do
      180.0
    else
      min(:math.sqrt(-2.0 * :math.log(r)) * @rad2deg, 180.0)
    end
  end
end
