defmodule RacingOrg.Tracker.Pro.Calibration.Estimate do
  @moduledoc """
  The shared robust-estimate wrapper every auto-calibration estimator embeds.

  Each estimator produces a stream of RAW per-pair (or per-leg) scalar estimates —
  e.g. one vane-rotation guess per matched tack pair. This module folds that stream
  into a bounded-memory robust tracker and exposes a `%Estimate{}` snapshot:

    * **value** — the running MEDIAN of the raw estimates (streaming P² at p = 0.5),
      robust to outlier pairs (wind shifts, bad legs).
    * **spread** — the inter-quartile range `q75 − q25` (two more P² trackers), the
      scale of disagreement between raw estimates.
    * **state** — `:learning` until ALL validation gates hold, then `:validated`:
      `sample_count ≥ min_samples`, `spread ≤ max_spread`, and the recent-window
      drift check (below).
    * **confidence** — `min(1, n/min_samples) · max(0, 1 − spread/max_spread)`,
      a bounded 0..1 blend of "enough evidence" and "estimates agree".

  ## Circular safety

  The quartile trackers run LINEARLY on the raw scalar estimates. That is safe even
  for angle corrections because every estimator's raw output is a SMALL BOUNDED
  correction (a few degrees of vane offset, a gain near 1.0) — never a full-circle
  quantity — so no estimate can sit near a ±180° wrap. Full-circle angles (TWD,
  heading) are wrapped by the estimators BEFORE differencing; only the small
  differences reach this tracker.

  ## Stability (drift) gate

  Validation additionally requires the last `stability_window` raw estimates to
  agree with the long-run median: `|median(recent) − value| ≤ max_drift` (default
  `max_spread / 2`). A tracker whose recent estimates are marching away from its
  history — a real physical change or a bad regime — must fall back to `:learning`
  rather than keep promoting a stale value.

  ## Promotion (`applied_value/3`)

  The promotion step turns the tracked estimate into a value safe to APPLY:
  only a `:validated` tracker moves the applied value at all; the target is clamped
  to `[clamp_min, clamp_max]`; and each call moves at most `max_slew` from
  `prev_applied` — corrections creep, they never jump.
  """

  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare

  defstruct value: nil, confidence: 0.0, sample_count: 0, state: :learning, spread: nil

  @type state :: :learning | :validated

  @type t :: %__MODULE__{
          value: float() | nil,
          confidence: float(),
          sample_count: non_neg_integer(),
          state: state(),
          spread: float() | nil
        }

  defmodule Tracker do
    @moduledoc """
    The internal robust-tracker state `RacingOrg.Tracker.Pro.Calibration.Estimate`
    operates on: three streaming P² quantiles (median + quartiles), the recent-raw
    stability window, and the validation / promotion options.
    """

    @enforce_keys [:p50, :p25, :p75]
    defstruct [
      :p50,
      :p25,
      :p75,
      count: 0,
      recent: [],
      min_samples: 8,
      max_spread: 1.0,
      stability_window: 5,
      max_drift: 0.5,
      clamp_min: nil,
      clamp_max: nil,
      max_slew: nil
    ]

    @type t :: %__MODULE__{
            p50: RacingOrg.Tracker.Pro.Polar.Observer.PSquare.t(),
            p25: RacingOrg.Tracker.Pro.Polar.Observer.PSquare.t(),
            p75: RacingOrg.Tracker.Pro.Polar.Observer.PSquare.t(),
            count: non_neg_integer(),
            recent: [float()],
            min_samples: pos_integer(),
            max_spread: float(),
            stability_window: pos_integer(),
            max_drift: float(),
            clamp_min: float() | nil,
            clamp_max: float() | nil,
            max_slew: float() | nil
          }
  end

  @doc """
  Build a fresh tracker.

  Options:

    * `:min_samples` — raw estimates required before validation (default 8).
    * `:max_spread` — maximum inter-quartile range to validate (default 1.0;
      estimator-specific in practice).
    * `:stability_window` — recent raw estimates the drift gate looks at (default 5).
    * `:max_drift` — maximum |median(recent) − value| to validate
      (default `max_spread / 2`).
    * `:clamp_min` / `:clamp_max` — promotion clamp bounds (default none).
    * `:max_slew` — maximum promotion step per `applied_value/3` call (default none).
  """
  @spec new(keyword()) :: Tracker.t()
  def new(opts \\ []) do
    max_spread = Keyword.get(opts, :max_spread, 1.0) / 1

    %Tracker{
      p50: PSquare.new(0.5),
      p25: PSquare.new(0.25),
      p75: PSquare.new(0.75),
      min_samples: Keyword.get(opts, :min_samples, 8),
      max_spread: max_spread,
      stability_window: Keyword.get(opts, :stability_window, 5),
      max_drift: Keyword.get(opts, :max_drift, max_spread / 2) / 1,
      clamp_min: Keyword.get(opts, :clamp_min),
      clamp_max: Keyword.get(opts, :clamp_max),
      max_slew: Keyword.get(opts, :max_slew)
    }
  end

  @doc "Fold one raw scalar estimate into the tracker (O(1), bounded memory)."
  @spec observe(Tracker.t(), number()) :: Tracker.t()
  def observe(%Tracker{} = t, raw) when is_number(raw) do
    raw = raw / 1

    %{
      t
      | p50: PSquare.add(t.p50, raw),
        p25: PSquare.add(t.p25, raw),
        p75: PSquare.add(t.p75, raw),
        count: t.count + 1,
        recent: Enum.take([raw | t.recent], t.stability_window)
    }
  end

  @doc "The current `%Estimate{}` snapshot of the tracker."
  @spec snapshot(Tracker.t()) :: t()
  def snapshot(%Tracker{} = t) do
    value = PSquare.value(t.p50)
    spread = spread(t)

    %__MODULE__{
      value: value,
      spread: spread,
      sample_count: t.count,
      state: if(validated?(t, value, spread), do: :validated, else: :learning),
      confidence: confidence(t, spread)
    }
  end

  @doc """
  The promotion step: the next value safe to APPLY given the previously applied
  `prev_applied`. Only a `:validated` tracker moves the applied value; the target
  is clamped to `[clamp_min, clamp_max]` and the move is slew-limited to
  `max_slew` per call. `opts` override the tracker's own promotion options.

  Returns `{applied, tracker}` (the tracker is returned for pipeline symmetry —
  promotion does not mutate the estimate itself).
  """
  @spec applied_value(Tracker.t(), number(), keyword()) :: {float(), Tracker.t()}
  def applied_value(%Tracker{} = t, prev_applied, opts \\ []) when is_number(prev_applied) do
    case snapshot(t) do
      %__MODULE__{state: :validated, value: value} when is_number(value) ->
        target =
          value
          |> clamp_max(Keyword.get(opts, :clamp_max, t.clamp_max))
          |> clamp_min(Keyword.get(opts, :clamp_min, t.clamp_min))

        {slew(prev_applied / 1, target, Keyword.get(opts, :max_slew, t.max_slew)), t}

      _learning ->
        {prev_applied / 1, t}
    end
  end

  # --- internal ---

  defp spread(%Tracker{} = t) do
    with q25 when is_number(q25) <- PSquare.value(t.p25),
         q75 when is_number(q75) <- PSquare.value(t.p75) do
      q75 - q25
    else
      _ -> nil
    end
  end

  defp validated?(t, value, spread) do
    is_number(value) and is_number(spread) and
      t.count >= t.min_samples and
      spread <= t.max_spread and
      stable?(t, value)
  end

  # The drift gate: the recent raw estimates must agree with the long-run median.
  defp stable?(%Tracker{recent: recent} = t, value) do
    length(recent) >= t.stability_window and
      abs(exact_median(recent) - value) <= t.max_drift
  end

  defp exact_median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end

  defp confidence(%Tracker{count: 0}, _spread), do: 0.0
  defp confidence(_t, nil), do: 0.0

  defp confidence(t, spread) do
    n_factor = min(1.0, t.count / t.min_samples)
    spread_factor = max(0.0, 1.0 - spread / t.max_spread)
    min(1.0, n_factor * spread_factor)
  end

  defp clamp_max(v, nil), do: v
  defp clamp_max(v, max), do: min(v, max / 1)

  defp clamp_min(v, nil), do: v
  defp clamp_min(v, min), do: max(v, min / 1)

  defp slew(_prev, target, nil), do: target
  defp slew(prev, target, max_slew), do: prev + min(max_slew / 1, max(-max_slew / 1, target - prev))
end
