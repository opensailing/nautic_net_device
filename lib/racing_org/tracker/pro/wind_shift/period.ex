defmodule RacingOrg.Tracker.Pro.WindShift.Period do
  @moduledoc """
  Autocorrelation period estimator for the TWD oscillation.

  Boundary-layer oscillating shifts run 3–20 min periods, so candidate lags span
  60..1800 s. Honest classification needs 20–45 min of history: this estimator
  refuses to name a period it has not seen at least twice (`lag ≤ n/2`).

  ## Contract

  `estimate/2` and `zero_crossings/1` take a PLAIN LIST of demeaned/detrended
  residual degrees sampled at a fixed 1 Hz, oldest first (the caller — the KF
  pipeline — produces `twd_unwrapped − level`, which removes both the mean and
  the trend). Index `i` is therefore second `i` / millisecond `i * 1000` from the
  start of the buffer. This is the simpler contract than timestamped pairs; the
  1 Hz cadence is what the tracker's sampling layer already guarantees.

  ## Method

  Biased sample autocorrelation `r(ℓ) = Σ x_i·x_{i+ℓ} / Σ x_i²` (the biased
  normalization tapers far lags, so the FIRST true peak dominates its own
  harmonics), evaluated on a coarse lag grid (default 15 s), then refined at 1 s
  resolution around the winner. A candidate peak must:

    * come AFTER the first non-positive dip of the ACF (skips the trivial
      small-lag correlation of any smooth series — a monotonically decaying ACF,
      the signature of a random walk or trend leak, never qualifies);
    * clear `:threshold` (default r > 0.3);
    * satisfy `lag ≤ n/2` — at least two full periods of data.

  ## Confidence

  `confidence = r_peak · span · shape`, clamped to `[0, 1]`, where

    * `span = clamp((n/period − 1) / 2, 0, 1)` — 0 at two observed periods,
      1 at three or more;
    * `shape = clamp(−r(period/2) / (0.5 · r_peak), 0, 1)` — a true oscillation
      is ANTI-correlated at half its period (`r(T/2) ≈ −r(T)`); random-walk
      residuals that drift through a spurious positive peak have no such trough
      and are heavily discounted. This is the honesty guard.

  `zero_crossings/1` is the cheap structural cross-check: hysteresis zero
  crossings at ±sd/2 give the median half-period and the time of the last
  extremum (the "time since the last header" source).

  Pure functions over immutable input: no processes, no IO.
  """

  @doc """
  Estimate the oscillation period from 1 Hz residuals (oldest first).

  Returns `%{period_s: float, confidence: float}` or `:none` when no credible
  positive ACF peak exists (insufficient data, flat input, aperiodic input).

  Options: `:min_lag_s` (default 60), `:max_lag_s` (1800), `:threshold` (0.3),
  `:coarse_step_s` (15).
  """
  @spec estimate([number()], keyword()) :: %{period_s: float(), confidence: float()} | :none
  def estimate(residuals_1hz, opts \\ []) do
    min_lag = Keyword.get(opts, :min_lag_s, 60)
    max_lag_opt = Keyword.get(opts, :max_lag_s, 1800)
    threshold = Keyword.get(opts, :threshold, 0.3)
    coarse_step = Keyword.get(opts, :coarse_step_s, 15)

    n = length(residuals_1hz)
    max_lag = min(max_lag_opt, div(n, 2))

    with true <- n >= 2 * min_lag and max_lag >= min_lag,
         {:ok, xs, energy} <- demean(residuals_1hz, n),
         {:ok, lag, r_peak} <- find_peak(xs, n, energy, min_lag, max_lag, threshold, coarse_step) do
      %{period_s: lag / 1, confidence: confidence(xs, n, energy, lag, r_peak)}
    else
      _ -> :none
    end
  end

  @doc """
  Hysteresis zero-crossing structure of 1 Hz residuals (oldest first): crossings
  count only after the signal has cleared ±sd/2 on the far side.

  Returns `%{last_extreme_ms: ms, median_half_period_s: s}` — the time (ms from
  buffer start) of the largest |residual| since the last confirmed crossing, and
  the median spacing of successive crossings — or `:none` with fewer than two
  confirmed crossings.
  """
  @spec zero_crossings([number()]) :: %{last_extreme_ms: non_neg_integer(), median_half_period_s: float()} | :none
  def zero_crossings(residuals_1hz) do
    n = length(residuals_1hz)

    with true <- n >= 4,
         {:ok, xs, energy} <- demean(residuals_1hz, n) do
      sd = :math.sqrt(energy / n)
      hyst = sd / 2.0
      walk_crossings(xs, n, hyst)
    else
      _ -> :none
    end
  end

  # --- demean -----------------------------------------------------------------

  defp demean(residuals, n) do
    mean = Enum.sum(residuals) / n
    xs = residuals |> Enum.map(&(&1 - mean)) |> List.to_tuple()
    energy = sum_sq(xs, n - 1, 0.0)

    if energy / n < 1.0e-9, do: :error, else: {:ok, xs, energy}
  end

  defp sum_sq(_xs, i, acc) when i < 0, do: acc

  defp sum_sq(xs, i, acc) do
    x = elem(xs, i)
    sum_sq(xs, i - 1, acc + x * x)
  end

  # --- autocorrelation ---------------------------------------------------------

  # Biased ACF at lag `l`: sum of overlapping products over TOTAL energy.
  defp acf(xs, n, energy, l) do
    dot(xs, l, n - l - 1, 0.0) / energy
  end

  defp dot(_xs, _l, i, acc) when i < 0, do: acc

  defp dot(xs, l, i, acc) do
    dot(xs, l, i - 1, acc + elem(xs, i) * elem(xs, i + l))
  end

  defp find_peak(xs, n, energy, min_lag, max_lag, threshold, coarse_step) do
    coarse =
      min_lag
      |> Stream.iterate(&(&1 + coarse_step))
      |> Enum.take_while(&(&1 <= max_lag))
      |> Enum.map(&{&1, acf(xs, n, energy, &1)})

    # Only lags after the ACF has dipped to <= 0 qualify: a smooth/drifting
    # series decays without dipping and is honestly reported as aperiodic.
    case Enum.drop_while(coarse, fn {_, r} -> r > 0.0 end) do
      [] ->
        :error

      after_dip ->
        {lag, r} = Enum.max_by(after_dip, fn {_, r} -> r end)

        if r >= threshold do
          refine(xs, n, energy, lag, coarse_step, max_lag, min_lag)
        else
          :error
        end
    end
  end

  defp refine(xs, n, energy, coarse_lag, coarse_step, max_lag, min_lag) do
    lo = max(coarse_lag - coarse_step + 1, min_lag)
    hi = min(coarse_lag + coarse_step - 1, max_lag)

    {lag, r} = Enum.max_by(lo..hi, &acf(xs, n, energy, &1)) |> then(&{&1, acf(xs, n, energy, &1)})
    {:ok, lag, r}
  end

  defp confidence(xs, n, energy, lag, r_peak) do
    span = clamp((n / lag - 1.0) / 2.0)
    r_half = acf(xs, n, energy, max(div(lag, 2), 1))
    shape = clamp(-r_half / (0.5 * r_peak))
    clamp(r_peak * span * shape)
  end

  defp clamp(x), do: min(max(x, 0.0), 1.0)

  # --- zero crossings ----------------------------------------------------------

  defp walk_crossings(xs, n, hyst) do
    {crossings, extreme_i, _side, _best} =
      Enum.reduce(0..(n - 1), {[], 0, nil, 0.0}, fn i, {crossings, extreme_i, side, best} ->
        x = elem(xs, i)

        new_side =
          cond do
            x > hyst -> :pos
            x < -hyst -> :neg
            true -> side
          end

        crossed = side != nil and new_side != side

        # Track the largest |residual| since the last confirmed crossing.
        {extreme_i, best} =
          if crossed do
            {i, abs(x)}
          else
            if abs(x) > best, do: {i, abs(x)}, else: {extreme_i, best}
          end

        crossings = if crossed, do: [i | crossings], else: crossings
        {crossings, extreme_i, new_side, best}
      end)

    case Enum.reverse(crossings) do
      [_, _ | _] = confirmed ->
        gaps =
          confirmed
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [a, b] -> (b - a) / 1 end)

        %{last_extreme_ms: extreme_i * 1000, median_half_period_s: median(gaps)}

      _ ->
        :none
    end
  end

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2.0
    end
  end
end
