defmodule RacingOrg.Tracker.Pro.Calibration.Estimator.AwsScale do
  @moduledoc """
  SHADOW-ONLY anemometer diagnostic: a binned TWS-consistency check. Its output
  is NEVER applied as a correction — consumers must treat it as a suggestion
  ("your masthead unit may read differently downwind than upwind"), because the
  TWS comparison is confounded in ways a pure leg-aggregate fit cannot untangle
  (mast twist, heel response, wind-gradient exposure, sea state).

  ## What it does

  Each leg's triangle-implied TWS (`tws_mean`) is binned by the leg's mean |AWA|
  regime:

    * upwind — `awa_abs_mean ≤ 70°`
    * reach — `70° < awa_abs_mean < 120°` (tracked, but excluded from the ratio)
    * downwind — `awa_abs_mean ≥ 120°`

  Within a ROLLING SESSION WINDOW (2 h by leg END time), the same true wind should
  yield the same TWS on any point of sail; a systematic downwind/upwind TWS ratio
  away from 1.0 flags an apparent-wind-speed calibration issue. Once both regimes
  hold `min_legs` legs inside the window, each new leg contributes one ratio
  observation `median(downwind TWS) / median(upwind TWS)` to an embedded
  `Estimate` tracker, reported by `snapshot/1`.

  ## Why the window matters (be honest about this)

  Up/downwind comparisons are only meaningful NEAR IN TIME: wind strength
  correlates with course choices across days (crews reach in heavy air, beat in
  light), so pooling legs across sessions would manufacture a spurious ratio.
  Legs older than the window relative to the newest leg are pruned and can never
  enter the medians. Successive ratio observations within a session share legs and
  are therefore autocorrelated — one more reason this stays a diagnostic, not a
  correction.

  Pure module: `observe_leg/2,3` folds state; time comes from the leg itself
  (`:t_end_s`, seconds on any monotone-per-session clock) or the explicit third
  argument — never from a wall clock read here.
  """

  alias RacingOrg.Tracker.Pro.Calibration.Estimate

  defstruct regimes: %{upwind: [], reach: [], downwind: []},
            ratio: nil,
            window_s: 7_200.0,
            min_legs: 3,
            legs_seen: 0,
            legs_skipped: 0

  @type regime :: :upwind | :reach | :downwind

  @type t :: %__MODULE__{
          regimes: %{regime() => [{float(), float()}]},
          ratio: Estimate.Tracker.t(),
          window_s: float(),
          min_legs: pos_integer(),
          legs_seen: non_neg_integer(),
          legs_skipped: non_neg_integer()
        }

  @upwind_max_awa 70.0
  @downwind_min_awa 120.0

  # Hard per-regime retention cap: bounds memory even under pathological leg rates
  # (at sane tacking rates the 2 h window holds far fewer).
  @max_legs_per_regime 256

  # A near-zero upwind median cannot anchor a ratio.
  @min_upwind_tws 0.1

  @doc """
  Build a fresh diagnostic.

  Options: `:window_s` (rolling session window, default 7200 s), `:min_legs`
  (legs per regime before ratio observations start, default 3), plus `Estimate`
  options for the ratio tracker (default `max_spread: 0.15`; no clamp/slew —
  this estimate is never promoted).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    {window_s, opts} = Keyword.pop(opts, :window_s, 7_200.0)
    {min_legs, opts} = Keyword.pop(opts, :min_legs, 3)

    %__MODULE__{
      window_s: window_s / 1,
      min_legs: min_legs,
      ratio: Estimate.new(Keyword.merge([max_spread: 0.15], opts))
    }
  end

  @doc """
  Fold one leg aggregate, timestamped by `t_end_s` (defaults to the leg's own
  `:t_end_s` key). Legs without a usable time, TWS, or |AWA| are counted in
  `legs_skipped` and otherwise ignored.
  """
  @spec observe_leg(t(), map(), number() | nil) :: t()
  def observe_leg(estimator, leg, t_end_s \\ nil)

  def observe_leg(%__MODULE__{} = t, leg, nil), do: do_observe(t, leg, leg[:t_end_s])
  def observe_leg(%__MODULE__{} = t, leg, t_end_s), do: do_observe(t, leg, t_end_s)

  @doc """
  Snapshot:

      %{
        downwind_over_upwind_ratio: %Estimate{},   # never applied — suggestion only
        regimes: %{upwind | reach | downwind => %{count, median_tws}}
      }

  Regime counts/medians cover only legs still inside the rolling window.
  """
  @spec snapshot(t()) :: %{
          downwind_over_upwind_ratio: Estimate.t(),
          regimes: %{regime() => %{count: non_neg_integer(), median_tws: float() | nil}}
        }
  def snapshot(%__MODULE__{} = t) do
    %{
      downwind_over_upwind_ratio: Estimate.snapshot(t.ratio),
      regimes:
        Map.new(t.regimes, fn {regime, legs} ->
          {regime, %{count: length(legs), median_tws: median_tws(legs)}}
        end)
    }
  end

  # --- internal ---

  defp do_observe(%__MODULE__{} = t, leg, t_end_s) do
    tws = leg[:tws_mean]
    awa_abs = leg[:awa_abs_mean]

    if is_number(t_end_s) and is_number(tws) and is_number(awa_abs) do
      t
      |> push_leg(regime(awa_abs), t_end_s / 1, tws / 1)
      |> prune(t_end_s / 1)
      |> maybe_observe_ratio()
      |> Map.update!(:legs_seen, &(&1 + 1))
    else
      %{t | legs_skipped: t.legs_skipped + 1}
    end
  end

  defp regime(awa_abs) when awa_abs <= @upwind_max_awa, do: :upwind
  defp regime(awa_abs) when awa_abs >= @downwind_min_awa, do: :downwind
  defp regime(_awa_abs), do: :reach

  defp push_leg(t, regime, t_end_s, tws) do
    %{t | regimes: Map.update!(t.regimes, regime, &Enum.take([{t_end_s, tws} | &1], @max_legs_per_regime))}
  end

  # Drop every leg that ended more than window_s before the NEWEST leg end seen
  # across all regimes (leg lists are newest-first).
  defp prune(t, t_end_s) do
    latest =
      t.regimes
      |> Enum.flat_map(fn {_regime, legs} -> Enum.take(legs, 1) end)
      |> Enum.map(fn {leg_t, _tws} -> leg_t end)
      |> Enum.max(fn -> t_end_s end)

    cutoff = max(latest, t_end_s) - t.window_s

    regimes =
      Map.new(t.regimes, fn {regime, legs} ->
        {regime, Enum.filter(legs, fn {leg_t, _tws} -> leg_t >= cutoff end)}
      end)

    %{t | regimes: regimes}
  end

  defp maybe_observe_ratio(t) do
    upwind = t.regimes.upwind
    downwind = t.regimes.downwind

    with true <- length(upwind) >= t.min_legs and length(downwind) >= t.min_legs,
         up_median when is_number(up_median) <- median_tws(upwind),
         true <- up_median > @min_upwind_tws,
         down_median when is_number(down_median) <- median_tws(downwind) do
      %{t | ratio: Estimate.observe(t.ratio, down_median / up_median)}
    else
      _ -> t
    end
  end

  defp median_tws([]), do: nil

  defp median_tws(legs) do
    sorted = legs |> Enum.map(fn {_t, tws} -> tws end) |> Enum.sort()
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end
end
