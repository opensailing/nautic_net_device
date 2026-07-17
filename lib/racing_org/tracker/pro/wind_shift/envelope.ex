defmodule RacingOrg.Tracker.Pro.WindShift.Envelope do
  @moduledoc """
  Sliding-window circular min/max envelope of TWD with a New-Extreme alarm.

  Tactical doctrine: **range beats timing** — knowing today's oscillation band is
  worth more than predicting the next swing, and a reading OUTSIDE the
  established band is a regime alarm (a front or sea-breeze step of 25–90° starts
  as exactly such a reading). This module maintains the windowed min/max (default
  30 min) and flags the update that breaks out of the prior envelope.

  ## Algorithm

  Compass angles cannot be min/max'd directly across the 0 ⇄ 360 wrap, so each
  sample is first UNWRAPPED onto a continuous line: the module keeps the previous
  (wrapped, unwrapped) pair and extends by the wrap-aware signed delta
  (`Circular.wrapped_delta/2`). The unwrap reference is therefore the previous
  sample itself — no external mean needs feeding in — which is exact as long as
  consecutive samples differ by < 180° (guaranteed for wind at 1 Hz).

  Windowed extremes over the unwrapped series use TWO MONOTONIC DEQUES (the
  classic sliding-window-extrema pattern): the max-deque holds a decreasing
  subsequence, the min-deque an increasing one; expired timestamps are pruned
  from the front, dominated values popped from the back. Every update is O(1)
  amortized and memory is bounded by the window.

  ## New-extreme alarm

  `new_extreme` reports on THIS update: `:high` / `:low` when the sample exceeds
  the prior window extreme by more than `:margin_deg` (default 2°), `:none`
  otherwise. Alarms are debounced — within `:debounce_s` (default 60 s) of the
  previous alarm nothing re-fires — and suppressed during the first `:warmup_s`
  (default 300 s), while the envelope is still being established and every other
  reading would trivially be "new".

  Display values re-wrap to `[0, 360)`; `range_deg` is the unwrapped width (it
  can legitimately exceed 360 if the wind boxes the compass within one window).

  Pure data structure + functions: no processes, no IO.
  """

  alias RacingOrg.Tracker.Pro.Calibration.Detect.Circular

  defstruct window_ms: 1_800_000,
            margin_deg: 2.0,
            debounce_ms: 60_000,
            warmup_ms: 300_000,
            # Monotonic deques of {t_ms, unwrapped_deg}.
            minq: :queue.new(),
            maxq: :queue.new(),
            last_input_deg: nil,
            last_unwrapped: nil,
            first_ms: nil,
            last_alarm_ms: nil,
            new_extreme: :none

  @type t :: %__MODULE__{}

  @typedoc "Point-in-time view of the envelope."
  @type snapshot :: %{
          min_deg: float() | nil,
          max_deg: float() | nil,
          range_deg: float() | nil,
          new_extreme: :none | :high | :low
        }

  @doc """
  Build a fresh envelope.

  Options: `:window_s` (default 1800), `:margin_deg` (2.0), `:debounce_s` (60),
  `:warmup_s` (300).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      window_ms: round(Keyword.get(opts, :window_s, 1800) * 1000),
      margin_deg: Keyword.get(opts, :margin_deg, 2.0) / 1,
      debounce_ms: round(Keyword.get(opts, :debounce_s, 60) * 1000),
      warmup_ms: round(Keyword.get(opts, :warmup_s, 300) * 1000)
    }
  end

  @doc """
  Fold one TWD sample (degrees, any wrap) taken at monotonic `mono_ms` into the
  envelope. The `new_extreme` decision for THIS update is readable from the next
  `snapshot/1`.
  """
  @spec update(t(), number(), integer()) :: t()
  def update(%__MODULE__{} = env, twd_deg, mono_ms) do
    unwrapped =
      case env.last_input_deg do
        nil -> twd_deg / 1
        last_in -> env.last_unwrapped + Circular.wrapped_delta(last_in, twd_deg)
      end

    minq = prune(env.minq, mono_ms - env.window_ms)
    maxq = prune(env.maxq, mono_ms - env.window_ms)

    alarm = alarm(env, minq, maxq, unwrapped, mono_ms)

    %{
      env
      | minq: push_min(minq, mono_ms, unwrapped),
        maxq: push_max(maxq, mono_ms, unwrapped),
        last_input_deg: twd_deg / 1,
        last_unwrapped: unwrapped,
        first_ms: env.first_ms || mono_ms,
        last_alarm_ms: if(alarm == :none, do: env.last_alarm_ms, else: mono_ms),
        new_extreme: alarm
    }
  end

  @doc """
  Current view: wrapped `min_deg`/`max_deg` (`[0, 360)`), unwrapped `range_deg`,
  and the `new_extreme` verdict of the LAST update. All `nil`/`:none` before the
  first sample.
  """
  @spec snapshot(t()) :: snapshot()
  def snapshot(%__MODULE__{} = env) do
    case {:queue.peek(env.minq), :queue.peek(env.maxq)} do
      {{:value, {_, min}}, {:value, {_, max}}} ->
        %{
          min_deg: Circular.normalize(min),
          max_deg: Circular.normalize(max),
          range_deg: max - min,
          new_extreme: env.new_extreme
        }

      _ ->
        %{min_deg: nil, max_deg: nil, range_deg: nil, new_extreme: :none}
    end
  end

  defp alarm(env, minq, maxq, unwrapped, mono_ms) do
    armed = env.first_ms != nil and mono_ms - env.first_ms >= env.warmup_ms

    debounced =
      env.last_alarm_ms == nil or mono_ms - env.last_alarm_ms >= env.debounce_ms

    cond do
      not (armed and debounced) -> :none
      beyond_max?(maxq, unwrapped, env.margin_deg) -> :high
      beyond_min?(minq, unwrapped, env.margin_deg) -> :low
      true -> :none
    end
  end

  defp beyond_max?(maxq, unwrapped, margin) do
    case :queue.peek(maxq) do
      {:value, {_, max}} -> unwrapped > max + margin
      :empty -> false
    end
  end

  defp beyond_min?(minq, unwrapped, margin) do
    case :queue.peek(minq) do
      {:value, {_, min}} -> unwrapped < min - margin
      :empty -> false
    end
  end

  # Drop expired entries from the front of a deque.
  defp prune(queue, expire_before_ms) do
    case :queue.peek(queue) do
      {:value, {t_ms, _}} when t_ms <= expire_before_ms -> prune(:queue.drop(queue), expire_before_ms)
      _ -> queue
    end
  end

  # Monotonic push: pop dominated entries off the back, then append.
  defp push_min(queue, t_ms, value) do
    queue = pop_back_while(queue, fn {_, v} -> v >= value end)
    :queue.in({t_ms, value}, queue)
  end

  defp push_max(queue, t_ms, value) do
    queue = pop_back_while(queue, fn {_, v} -> v <= value end)
    :queue.in({t_ms, value}, queue)
  end

  defp pop_back_while(queue, fun) do
    case :queue.peek_r(queue) do
      {:value, entry} ->
        if fun.(entry), do: pop_back_while(:queue.drop_r(queue), fun), else: queue

      :empty ->
        queue
    end
  end
end
