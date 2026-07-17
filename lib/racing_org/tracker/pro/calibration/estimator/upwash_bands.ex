defmodule RacingOrg.Tracker.Pro.Calibration.Estimator.UpwashBands do
  @moduledoc """
  Pure TWS-banded partial-pooling layer for the upwash correction: one robust
  `Estimate.Tracker` per true-wind-speed band, a linear-in-TWS **backbone** fit
  across the populated bands, and empirical-Bayes **shrinkage** of each band
  toward that backbone — so light-air and breeze-on days learn DIFFERENT upwash
  corrections without a sparse band having to starve until it clears the full
  global gate on its own.

  ## Physics: why upwash varies with TWS

  The masthead vane sits in flow already bent by the sails' bound circulation
  ("upwash"); the bend scales with the sail plan's lift coefficient C_L. In
  light and medium air the rig is powered up near maximum C_L, so the upwash
  error is largest (a few degrees). As the breeze builds the crew DEPOWERS —
  flattening, twist, traveler down — C_L falls, and with it the upwash, which
  typically shrinks toward (and can cross) zero somewhere around 12–15 kn TWS.
  Instrument vendors publish linear upwash corrections in TWS with slopes up to
  about ±0.36 °/kn ≈ ±0.7 °/(m/s) (Ockam's outer range — the slope clamp used
  here). A single global scalar smears these regimes together; fully independent
  per-band fits starve the bands a boat rarely sails in. Partial pooling gives
  both: dense bands keep their own medians, sparse bands borrow strength from
  the backbone.

  ## Bands

  2 m/s-wide TWS bins with edges [2, 4, 6, 8, 10, 12, ∞) and centers
  [3, 5, 7, 9, 11, 13] m/s; the top band absorbs everything above 12 m/s.
  Pair TWS below 2 m/s is EXCLUDED entirely (masthead vane stiction makes AWA
  unreliable in drifting conditions) and counted in `excluded_light`. Each
  populated band embeds an `Estimate.Tracker` on the raw per-pair upwash
  estimates with `min_samples: 4` / `max_spread: 2.0` — the shrinkage
  compensates for the lighter gate — except the lightest band (center 3), which
  is noisier and gets `min_samples: 6` / `max_spread: 3.0`.

  ## Backbone + between-band variance + shrinkage

  Weighted least squares of `m(V) = a + b·(V − 6.17)` (6.17 m/s = 12 kn anchor)
  to the populated-band medians ȳ_j at their centers V_j, with weights
  `w_j = n_j / s_j²` where `s_j = max(spread_j / 1.349, 0.3°)` (IQR → σ for a
  normal; the 0.3° floor keeps a zero-variance band from swallowing the fit).
  With fewer than 2 populated bands, or a populated span under 3 m/s, the slope
  is PINNED to 0 and the backbone degenerates to the weighted mean — effectively
  the old global scalar. The slope is clamped to ±0.7 °/(m/s) and the intercept
  re-solved under the clamped slope.

  Between-band variance τ² comes from DerSimonian–Laird:

      τ² = max(0, [Σ w_j·(ȳ_j − m(V_j))² − (k − p)] / [Σ w_j − Σ w_j² / Σ w_j])

  with `k` populated bands and `p = 2` fitted parameters (1 when the slope is
  pinned). Each band is then shrunk toward the backbone:

      û_j = B_j·ȳ_j + (1 − B_j)·m(V_j),   B_j = τ² / (τ² + s_j²/n_j)

  with posterior variance `(1/τ² + n_j/s_j²)⁻¹ = B_j·s_j²/n_j` when τ² > 0 and
  `s_j²/n_j` when τ² = 0 (full pooling: the band value IS the backbone value).

  ## Publication

  With k ≥ 2 a band PUBLISHES into `curve` when its posterior SD ≤ 0.5° and it
  has ≥ 3 samples (≥ 6 for the lightest band) — the point of pooling: three
  consistent pairs in a rare band ride the backbone out of the gate. With k = 1
  there is nothing to pool against, so the single band must clear the CLASSIC
  global gate on its own — tracker validated (stability window) with
  ≥ `min_samples` (default 8) and spread ≤ `max_spread` (default 2.0°) —
  exactly the pre-banding behavior. Published values are clamped to ±10°;
  unpublished bands are simply OMITTED from the curve (consumers interpolate
  between and hold beyond published points).

  ## Shear-day screen

  Once a curve exists (≥ 2 published bands), a raw estimate further than
  `max(3·posterior_sd_at_bin + 1.0°, 3.0°)` from the curve interpolated at the
  pair's TWS is REJECTED (counted in `screened`, fed to nothing): a freak
  veer/shear day must not drag a matured curve. Early learning is untouched —
  below 2 published bands everything (non-light) is accepted.
  """

  alias RacingOrg.Tracker.Pro.Calibration.Estimate

  defstruct bands: %{},
            screened: 0,
            excluded_light: 0,
            band_opts: [],
            light_band_opts: [],
            classic_min_samples: 8,
            classic_max_spread: 2.0,
            clamp_min: -10.0,
            clamp_max: 10.0

  @type center :: 3 | 5 | 7 | 9 | 11 | 13

  @type t :: %__MODULE__{
          bands: %{optional(center()) => Estimate.Tracker.t()},
          screened: non_neg_integer(),
          excluded_light: non_neg_integer(),
          band_opts: keyword(),
          light_band_opts: keyword(),
          classic_min_samples: pos_integer(),
          classic_max_spread: float(),
          clamp_min: float() | nil,
          clamp_max: float() | nil
        }

  @type snapshot :: %{
          bands: %{optional(center()) => Estimate.t()},
          curve: [{center(), float()}],
          backbone: %{a: float(), b: float()} | nil,
          screened: non_neg_integer(),
          excluded_light: non_neg_integer()
        }

  # Band geometry: edges [2, 4, 6, 8, 10, 12, ∞), centers [3, 5, 7, 9, 11, 13].
  @light_cutoff_mps 2.0
  @top_edge_mps 12.0
  @top_center 13
  @lightest_center 3

  # Backbone: 12 kn anchor, Ockam's outer slope range, minimum span to dare a slope.
  @anchor_mps 6.17
  @max_slope_deg_per_mps 0.7
  @min_slope_span_mps 3.0

  # Robust-scale conversion (IQR → σ for a normal) and the zero-variance floor.
  @iqr_to_sigma 1.349
  @sigma_floor_deg 0.3

  # Per-band tracker gates (shrinkage compensates for the lighter min_samples).
  @band_min_samples 4
  @band_max_spread 2.0
  @light_band_min_samples 6
  @light_band_max_spread 3.0

  # Publication gate (k ≥ 2, posterior-based).
  @publish_posterior_sd_deg 0.5
  @publish_min_samples 3
  @light_publish_min_samples 6

  # Shear-day screen: max(3·posterior_sd + 1°, 3°).
  @screen_sd_mult 3.0
  @screen_base_deg 1.0
  @screen_floor_deg 3.0

  @doc """
  Build a fresh banded tracker. `opts` are the estimator's `Estimate` options
  (as given to `AwaOffset.new/1`): they are forwarded to every per-band tracker,
  except that the structural per-band `min_samples`/`max_spread` above always
  win; `:min_samples`/`:max_spread` (defaults 8 / 2.0) define the CLASSIC k = 1
  publication gate, and `:clamp_min`/`:clamp_max` (defaults ∓10.0) clamp
  published curve values.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      band_opts: Keyword.merge(opts, min_samples: @band_min_samples, max_spread: @band_max_spread),
      light_band_opts: Keyword.merge(opts, min_samples: @light_band_min_samples, max_spread: @light_band_max_spread),
      classic_min_samples: Keyword.get(opts, :min_samples, 8),
      classic_max_spread: Keyword.get(opts, :max_spread, 2.0) / 1,
      clamp_min: Keyword.get(opts, :clamp_min, -10.0),
      clamp_max: Keyword.get(opts, :clamp_max, 10.0)
    }
  end

  @doc """
  The band center for a pair TWS (m/s), or `:light` below the 2 m/s cutoff.
  """
  @spec band_center(number()) :: center() | :light
  def band_center(tws) when is_number(tws) do
    cond do
      tws < @light_cutoff_mps -> :light
      tws >= @top_edge_mps -> @top_center
      true -> trunc((tws - @light_cutoff_mps) / 2.0) * 2 + @lightest_center
    end
  end

  @doc """
  Fold one raw upwash estimate observed at `pair_tws` (m/s). Returns
  `{:accepted, t}` when the raw was fed into its band, `{:excluded_light, t}`
  below the 2 m/s TWS cutoff, or `{:screened, t}` when the shear-day screen
  rejected it against a published curve — in the last two cases NO tracker
  (band or otherwise) should see the raw, only the counter moves.
  """
  @spec observe(t(), number(), number()) :: {:accepted | :screened | :excluded_light, t()}
  def observe(%__MODULE__{} = t, pair_tws, raw) when is_number(pair_tws) and is_number(raw) do
    case band_center(pair_tws) do
      :light ->
        {:excluded_light, %{t | excluded_light: t.excluded_light + 1}}

      center ->
        if screened?(t, pair_tws, center, raw) do
          {:screened, %{t | screened: t.screened + 1}}
        else
          tracker = Map.get(t.bands, center, Estimate.new(band_opts(t, center)))
          {:accepted, %{t | bands: Map.put(t.bands, center, Estimate.observe(tracker, raw))}}
        end
    end
  end

  @doc """
  Snapshot of the banded state:

    * `bands` — per-center `%Estimate{}` snapshots of the RAW band trackers
      (unshrunk medians, for observability).
    * `curve` — `[{center_mps, value_deg}]`, ascending, ONLY the published
      bands (shrunk values, clamped ±10°); empty until something publishes.
    * `backbone` — `%{a: intercept_deg_at_6_17_mps, b: slope_deg_per_mps}` of
      the descriptive fit over populated bands, `nil` when none are populated.
      Present even before publication — publication is gated separately.
    * `screened` / `excluded_light` — rejection counters.
  """
  @spec snapshot(t()) :: snapshot()
  def snapshot(%__MODULE__{} = t) do
    %{bins: bins, curve: curve, backbone: backbone} = analyze(t)

    %{
      bands: Map.new(bins, fn bin -> {bin.center, bin.snap} end),
      curve: curve,
      backbone: backbone,
      screened: t.screened,
      excluded_light: t.excluded_light
    }
  end

  # --- internal ---

  defp band_opts(%__MODULE__{light_band_opts: opts}, @lightest_center), do: opts
  defp band_opts(%__MODULE__{band_opts: opts}, _center), do: opts

  defp publish_min_samples(@lightest_center), do: @light_publish_min_samples
  defp publish_min_samples(_center), do: @publish_min_samples

  # The full pure analysis: populated-bin stats -> backbone -> shrinkage ->
  # publication gate -> curve. Recomputed on demand (bounded by 6 bands).
  defp analyze(%__MODULE__{bands: bands} = t) do
    bins =
      bands
      |> Enum.map(fn {center, tracker} -> base_bin(center, Estimate.snapshot(tracker)) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.center)

    {backbone, pinned?} = fit_backbone(bins)
    bins = shrink(bins, backbone, pinned?, t)
    curve = for bin <- bins, bin.published?, do: {bin.center, clamp(bin.u_hat, t.clamp_min, t.clamp_max)}

    %{bins: bins, curve: curve, backbone: backbone}
  end

  defp base_bin(center, %Estimate{value: value, spread: spread, sample_count: n} = snap) when is_number(value) do
    s = max((spread || 0.0) / @iqr_to_sigma, @sigma_floor_deg)
    %{center: center, snap: snap, n: n, s: s, w: n / (s * s), u_hat: nil, posterior_sd: nil, published?: false}
  end

  defp base_bin(_center, _empty_snapshot), do: nil

  # Weighted least squares of m(V) = a + b·(V − anchor) over the populated-bin
  # medians. Slope pinned to 0 (weighted mean) below 2 bins or a 3 m/s span;
  # clamped to ±0.7 °/(m/s) otherwise, with the intercept re-solved under the
  # clamp. Returns {backbone | nil, pinned?}.
  defp fit_backbone([]), do: {nil, true}

  defp fit_backbone(bins) do
    {sw, sx, sy, sxx, sxy} =
      Enum.reduce(bins, {0.0, 0.0, 0.0, 0.0, 0.0}, fn bin, {sw, sx, sy, sxx, sxy} ->
        x = bin.center - @anchor_mps
        y = bin.snap.value
        w = bin.w
        {sw + w, sx + w * x, sy + w * y, sxx + w * x * x, sxy + w * x * y}
      end)

    span = List.last(bins).center - hd(bins).center
    denom = sw * sxx - sx * sx

    if length(bins) >= 2 and span >= @min_slope_span_mps and denom > 1.0e-9 do
      b = clamp((sw * sxy - sx * sy) / denom, -@max_slope_deg_per_mps, @max_slope_deg_per_mps)
      {%{a: (sy - b * sx) / sw, b: b}, false}
    else
      {%{a: sy / sw, b: 0.0}, true}
    end
  end

  defp shrink([], _backbone, _pinned?, _t), do: []

  # k = 1: nothing to pool against — no shrinkage, and the lone band must clear
  # the CLASSIC global gate (validated + min_samples + max_spread) by itself,
  # exactly the pre-banding single-tracker behavior.
  defp shrink([bin], _backbone, _pinned?, t) do
    published? =
      bin.snap.state == :validated and
        bin.n >= t.classic_min_samples and
        is_number(bin.snap.spread) and bin.snap.spread <= t.classic_max_spread

    [%{bin | u_hat: bin.snap.value, posterior_sd: bin.s / :math.sqrt(bin.n), published?: published?}]
  end

  # k ≥ 2: DerSimonian–Laird between-band variance, then per-band shrinkage
  # toward the backbone and the posterior-based publication gate.
  defp shrink(bins, %{a: a, b: b}, pinned?, _t) do
    tau2 = tau_squared(bins, a, b, if(pinned?, do: 1, else: 2))

    Enum.map(bins, fn bin ->
      m = a + b * (bin.center - @anchor_mps)
      se2 = bin.s * bin.s / bin.n

      {u_hat, posterior_var} =
        if tau2 > 0.0 do
          shrinkage = tau2 / (tau2 + se2)
          # B·se2 == (1/τ² + n/s²)⁻¹ without the 1/τ² overflow risk at tiny τ².
          {shrinkage * bin.snap.value + (1.0 - shrinkage) * m, shrinkage * se2}
        else
          {m, se2}
        end

      posterior_sd = :math.sqrt(posterior_var)
      published? = posterior_sd <= @publish_posterior_sd_deg and bin.n >= publish_min_samples(bin.center)

      %{bin | u_hat: u_hat, posterior_sd: posterior_sd, published?: published?}
    end)
  end

  # DerSimonian–Laird: τ² = max(0, [Q − (k − p)] / [Σw − Σw²/Σw]), Q the
  # weighted squared residuals of the bin medians about the backbone.
  defp tau_squared(bins, a, b, p) do
    {q, sw, sw2} =
      Enum.reduce(bins, {0.0, 0.0, 0.0}, fn bin, {q, sw, sw2} ->
        r = bin.snap.value - (a + b * (bin.center - @anchor_mps))
        {q + bin.w * r * r, sw + bin.w, sw2 + bin.w * bin.w}
      end)

    denom = sw - sw2 / sw

    if denom > 1.0e-9 do
      max(0.0, (q - (length(bins) - p)) / denom)
    else
      0.0
    end
  end

  # The shear-day screen: only once a matured curve exists (≥ 2 published
  # bands). Expected = the curve interpolated at the pair's TWS (held flat
  # beyond the published range); tolerance max(3·posterior_sd + 1°, 3°), with
  # the bare 3° floor when the pair's own band has no posterior yet.
  defp screened?(%__MODULE__{} = t, pair_tws, center, raw) do
    %{bins: bins, curve: curve} = analyze(t)

    case curve do
      [_, _ | _] ->
        expected = interpolate(curve, pair_tws)
        abs(raw - expected) > screen_tolerance(bins, center)

      _fewer_than_two_published ->
        false
    end
  end

  defp screen_tolerance(bins, center) do
    case Enum.find(bins, fn bin -> bin.center == center and is_number(bin.posterior_sd) end) do
      nil -> @screen_floor_deg
      bin -> max(@screen_sd_mult * bin.posterior_sd + @screen_base_deg, @screen_floor_deg)
    end
  end

  # Piecewise-linear interpolation over the published curve, holding the edge
  # values flat outside the published range. Callers guarantee ≥ 1 point.
  defp interpolate([{c0, v0} | _rest], tws) when tws <= c0, do: v0
  defp interpolate([{_c0, v0}], _tws), do: v0

  defp interpolate([{c0, v0}, {c1, v1} | _rest], tws) when tws <= c1,
    do: v0 + (v1 - v0) * (tws - c0) / (c1 - c0)

  defp interpolate([_point | rest], tws), do: interpolate(rest, tws)

  defp clamp(v, min, max) do
    v
    |> clamp_min(min)
    |> clamp_max(max)
  end

  defp clamp_min(v, nil), do: v
  defp clamp_min(v, min), do: max(v, min / 1)

  defp clamp_max(v, nil), do: v
  defp clamp_max(v, max), do: min(v, max / 1)
end
