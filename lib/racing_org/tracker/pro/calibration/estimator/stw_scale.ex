defmodule RacingOrg.Tracker.Pro.Calibration.Estimator.StwScale do
  @moduledoc """
  Pure estimator of the per-speed-band multiplicative STW gain from RECIPROCAL
  course pairs (two legs sailed on opposite headings close in time).

  ## The observation

  Over a reciprocal pair a uniform current cancels to first order — exactly when
  it flows along-track (it adds to SOG one way and subtracts the other), and to
  O((c/stw)²) when it crosses. So the paired SOG/STW ratio isolates the speedo
  gain:

      gain_obs = (a.sog_mean + b.sog_mean) / (a.stw_mean + b.stw_mean)

  guarded by `a.stw_mean + b.stw_mean > 0.5` m/s. With the injection
  `stw_meas = stw_true / g` this recovers exactly `g` — the multiplicative
  CORRECTION (`stw_corrected = stw_meas · gain`).

  ## Speed bands

  Paddlewheel/ultrasonic gain is speed-dependent, so pairs are banded by the
  MEASURED pair-mean STW with edges `[0, 2, 4, 6, 8, ∞)` m/s and integer band
  centers `[1, 3, 5, 7, 9]`. Each band keeps:

    * a scalar RLS with forgetting `λ = 0.995` (state `θ` init 1.0, `p` init 1.0):
      `k = p/(λ + p); θ ← θ + k·(gain_obs − θ); p ← (1 − k)·p/λ` — the adaptive
      applied value, able to follow slow drift (fouling, transducer wear);
    * an `Estimate` tracker on the raw gains (median / quartiles / validation) —
      the robust gate that decides when the band is trustworthy.

  ## Applying

  `gain_curve/1` returns `[{center, applied_gain}]` for VALIDATED bands only, the
  RLS `θ` clamped to `[0.8, 1.2]` — a speedo more than 20% off needs service, not
  auto-calibration.
  """

  alias RacingOrg.Tracker.Pro.Calibration.Estimate

  defstruct bands: %{}, estimate_opts: [], pairs_seen: 0, pairs_skipped: 0

  @type leg :: %{
          required(:sog_mean) => number(),
          required(:stw_mean) => number(),
          optional(atom()) => any()
        }

  @type reciprocal_pair :: %{required(:a) => leg(), required(:b) => leg(), optional(atom()) => any()}

  @type band :: %{theta: float(), p: float(), estimate: Estimate.Tracker.t()}

  @type t :: %__MODULE__{
          bands: %{optional(1 | 3 | 5 | 7 | 9) => band()},
          estimate_opts: keyword(),
          pairs_seen: non_neg_integer(),
          pairs_skipped: non_neg_integer()
        }

  @lambda 0.995
  @clamp_min 0.8
  @clamp_max 1.2
  @min_stw_sum 0.5

  # Estimator-specific Estimate defaults: gains are dimensionless near 1.0.
  @default_min_samples 6
  @default_max_spread 0.04

  @doc """
  Build a fresh estimator. Options are forwarded to each band's embedded
  `Estimate` tracker, with estimator-specific defaults `min_samples: 6` and
  `max_spread: 0.04`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    defaults = [min_samples: @default_min_samples, max_spread: @default_max_spread]
    %__MODULE__{estimate_opts: Keyword.merge(defaults, opts)}
  end

  @doc """
  Fold one reciprocal pair into its speed band. Pairs with missing/non-positive
  speeds or an STW sum at/below #{@min_stw_sum} m/s are counted in
  `pairs_skipped` and otherwise ignored.
  """
  @spec observe_pair(t(), reciprocal_pair()) :: t()
  def observe_pair(%__MODULE__{} = t, %{a: a, b: b}) do
    with true <- sane_leg?(a) and sane_leg?(b),
         stw_sum = a.stw_mean + b.stw_mean,
         true <- stw_sum > @min_stw_sum do
      gain_obs = (a.sog_mean + b.sog_mean) / stw_sum
      center = band_center(stw_sum / 2)

      band = Map.get(t.bands, center) || new_band(t.estimate_opts)
      band = update_band(band, gain_obs)

      %{t | bands: Map.put(t.bands, center, band), pairs_seen: t.pairs_seen + 1}
    else
      _ -> %{t | pairs_skipped: t.pairs_skipped + 1}
    end
  end

  @doc """
  Snapshot: `%{bands: %{center => %{rls: θ, estimate: %Estimate{}}}}` for every
  band that has seen at least one pair.
  """
  @spec snapshot(t()) :: %{bands: %{optional(integer()) => %{rls: float(), estimate: Estimate.t()}}}
  def snapshot(%__MODULE__{} = t) do
    bands =
      Map.new(t.bands, fn {center, band} ->
        {center, %{rls: band.theta, estimate: Estimate.snapshot(band.estimate)}}
      end)

    %{bands: bands}
  end

  @doc """
  The applied gain curve `[{center, gain}]`, ascending by center: VALIDATED bands
  only, each RLS `θ` clamped to `[#{@clamp_min}, #{@clamp_max}]`.
  """
  @spec gain_curve(t()) :: [{integer(), float()}]
  def gain_curve(%__MODULE__{} = t) do
    t.bands
    |> Enum.filter(fn {_center, band} -> Estimate.snapshot(band.estimate).state == :validated end)
    |> Enum.map(fn {center, band} -> {center, band.theta |> min(@clamp_max) |> max(@clamp_min)} end)
    |> Enum.sort_by(fn {center, _gain} -> center end)
  end

  # --- internal ---

  defp new_band(estimate_opts), do: %{theta: 1.0, p: 1.0, estimate: Estimate.new(estimate_opts)}

  # One scalar RLS-with-forgetting step plus the robust tracker update.
  defp update_band(band, gain_obs) do
    k = band.p / (@lambda + band.p)

    %{
      theta: band.theta + k * (gain_obs - band.theta),
      p: (1 - k) * band.p / @lambda,
      estimate: Estimate.observe(band.estimate, gain_obs)
    }
  end

  # Band edges [0, 2, 4, 6, 8, ∞) m/s → integer centers [1, 3, 5, 7, 9].
  defp band_center(stw) when stw < 2.0, do: 1
  defp band_center(stw) when stw < 4.0, do: 3
  defp band_center(stw) when stw < 6.0, do: 5
  defp band_center(stw) when stw < 8.0, do: 7
  defp band_center(_stw), do: 9

  defp sane_leg?(leg) do
    is_number(leg[:sog_mean]) and leg.sog_mean >= 0 and
      is_number(leg[:stw_mean]) and leg.stw_mean > 0
  end
end
