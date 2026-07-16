defmodule RacingOrg.Tracker.Pro.Calibration.Detect.Tack do
  @moduledoc """
  Matched tack-pair (and gybe-pair) detection over completed steady legs.

  A matched tack pair — the same boat settled close-hauled on both boards
  within a couple of minutes, in the same wind — is the classic input for
  wind-vane and compass calibration: the port/starboard asymmetry of the two
  legs' AWA and heading means exposes sensor offsets. This module finds those
  pairs. It also classifies the downwind equivalent (`{:gybe_pair, ...}`),
  which v1 consumers may ignore.

  ## Composition choice

  This detector consumes the OUTPUT of
  `RacingOrg.Tracker.Pro.Calibration.Detect.Legs`, not raw samples: `step/2`
  accepts a `%Leg{}` (bare or as a `{:leg, %Leg{}}` event) and ignores any
  other `Legs` event, so the caller can pipe every event emitted by
  `Legs.step/2` / `Legs.flush/1` straight in. Rationale:

    * segmentation state and criteria live in exactly one place (`Legs`);
    * memory is O(1) — at most one candidate leg is retained, because a tack
      pair is by definition two *consecutive* legs;
    * the transition is characterized at leg level: transition time is the
      gap between the legs, and the heading swing is the wrap-aware
      difference of the two legs' circular heading means (a tack through the
      wind swings the mean heading by roughly twice the tacking angle).

  ## Pair criteria (configurable, with justification)

  Given the previous leg `a` and a new leg `b` (consecutive by construction):

    * **Opposite sides** — a tack or gybe flips the wind to the other board.
    * **Transition** (`:max_transition_s`, default `60.0`): `b` must start at
      most this long after `a` ended. A crash tack takes seconds; a minute
      allows a leisurely one. Longer than that, the wind or course likely
      changed and the pair tells us nothing.
    * **Heading swing** (`:min_swing_deg`, default `50.0`): the legs' mean
      headings must differ by at least this much — a wind shift can flip AWA
      sign without the boat actually turning; a real tack turns ~80–100°.
    * **Leg duration** (`:min_leg_s`, default `30.0`): both legs must be at
      least this long (of steady duration) for their aggregates to be
      trustworthy.
    * **Steady wind** (`:tws_match_mps`, default `1.0`): the legs' mean TWS
      must agree within this bound when both are known (skipped when either
      is `nil`) — comparing boards in different wind biases the estimate.
    * **Total span** (`:max_pair_span_s`, default `300.0`): first sample of
      `a` to last of `b` within five minutes, so the wind direction has had
      little time to walk.

  Classification by point of sail, from each leg's `awa_abs_mean`:

    * both `<= :close_hauled_max_deg` (default `60.0`) -> `{:tack_pair, ...}`
    * both `>= :gybe_min_awa_deg` (default `120.0`) -> `{:gybe_pair, ...}`
    * anything else -> no pair.

  The pair payload is `%{starboard: %Leg{}, port: %Leg{}, gap_s: float}` —
  legs keyed by *their* side, `gap_s` the transition time in seconds.

  Legs are consumed greedily in time order: a leg participates in at most one
  pair, and a leg that fails to pair replaces the previous candidate.

  ## Usage

      {state, events} =
        Enum.flat_map_reduce(leg_events, Tack.new(), fn event, state ->
          {state, events} = Tack.step(state, event)
          {events, state}
        end)
  """

  alias RacingOrg.Tracker.Pro.Calibration.Detect.Circular
  alias RacingOrg.Tracker.Pro.Calibration.Detect.Leg
  alias RacingOrg.Tracker.Pro.Calibration.Detect.Legs

  @default_close_hauled_max_deg 60.0
  @default_gybe_min_awa_deg 120.0
  @default_max_transition_s 60.0
  @default_min_swing_deg 50.0
  @default_min_leg_s 30.0
  @default_tws_match_mps 1.0
  @default_max_pair_span_s 300.0

  defstruct close_hauled_max_deg: @default_close_hauled_max_deg,
            gybe_min_awa_deg: @default_gybe_min_awa_deg,
            max_transition_s: @default_max_transition_s,
            min_swing_deg: @default_min_swing_deg,
            min_leg_s: @default_min_leg_s,
            tws_match_mps: @default_tws_match_mps,
            max_pair_span_s: @default_max_pair_span_s,
            pending: nil

  @type pair :: %{starboard: Leg.t(), port: Leg.t(), gap_s: float()}
  @type event :: {:tack_pair, pair()} | {:gybe_pair, pair()}

  @type t :: %__MODULE__{
          close_hauled_max_deg: float(),
          gybe_min_awa_deg: float(),
          max_transition_s: float(),
          min_swing_deg: float(),
          min_leg_s: float(),
          tws_match_mps: float(),
          max_pair_span_s: float(),
          pending: Leg.t() | nil
        }

  @doc """
  Build a detector. See the module doc for every option and its default.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      close_hauled_max_deg: Keyword.get(opts, :close_hauled_max_deg, @default_close_hauled_max_deg),
      gybe_min_awa_deg: Keyword.get(opts, :gybe_min_awa_deg, @default_gybe_min_awa_deg),
      max_transition_s: Keyword.get(opts, :max_transition_s, @default_max_transition_s),
      min_swing_deg: Keyword.get(opts, :min_swing_deg, @default_min_swing_deg),
      min_leg_s: Keyword.get(opts, :min_leg_s, @default_min_leg_s),
      tws_match_mps: Keyword.get(opts, :tws_match_mps, @default_tws_match_mps),
      max_pair_span_s: Keyword.get(opts, :max_pair_span_s, @default_max_pair_span_s)
    }
  end

  @doc """
  Fold one leg (or any `Legs` event — non-leg events are ignored) into the
  detector. Returns `{state, events}` with at most one pair event.
  """
  @spec step(t(), Leg.t() | Legs.event()) :: {t(), [event()]}
  def step(%__MODULE__{} = t, {:leg, %Leg{} = leg}), do: step(t, leg)

  def step(%__MODULE__{pending: nil} = t, %Leg{} = leg), do: {%{t | pending: leg}, []}

  def step(%__MODULE__{pending: %Leg{} = a} = t, %Leg{} = b) do
    case classify(t, a, b) do
      {tag, pair} -> {%{t | pending: nil}, [{tag, pair}]}
      :no_pair -> {%{t | pending: b}, []}
    end
  end

  def step(%__MODULE__{} = t, {tag, _payload}) when is_atom(tag), do: {t, []}

  # =====================================================================
  # Pair classification
  # =====================================================================

  defp classify(t, a, b) do
    gap_s = (b.started_ms - a.ended_ms) / 1000.0
    span_s = (b.ended_ms - a.started_ms) / 1000.0

    cond do
      not opposite_sides?(a, b) -> :no_pair
      gap_s < 0.0 or gap_s > t.max_transition_s -> :no_pair
      span_s > t.max_pair_span_s -> :no_pair
      a.duration_s < t.min_leg_s or b.duration_s < t.min_leg_s -> :no_pair
      not swung?(t, a, b) -> :no_pair
      not tws_steady?(t, a, b) -> :no_pair
      close_hauled?(t, a) and close_hauled?(t, b) -> {:tack_pair, payload(a, b, gap_s)}
      running?(t, a) and running?(t, b) -> {:gybe_pair, payload(a, b, gap_s)}
      true -> :no_pair
    end
  end

  defp opposite_sides?(a, b) do
    (a.side == :starboard and b.side == :port) or (a.side == :port and b.side == :starboard)
  end

  defp swung?(t, a, b) do
    is_number(a.heading_mean) and is_number(b.heading_mean) and
      Circular.distance(a.heading_mean, b.heading_mean) >= t.min_swing_deg
  end

  defp tws_steady?(t, %Leg{tws_mean: a}, %Leg{tws_mean: b}) when is_number(a) and is_number(b) do
    abs(a - b) <= t.tws_match_mps
  end

  # Either TWS unknown: nothing to compare against; don't reject on it.
  defp tws_steady?(_t, _a, _b), do: true

  defp close_hauled?(t, leg), do: leg.awa_abs_mean <= t.close_hauled_max_deg

  defp running?(t, leg), do: leg.awa_abs_mean >= t.gybe_min_awa_deg

  defp payload(a, b, gap_s) do
    {starboard, port} = if a.side == :starboard, do: {a, b}, else: {b, a}
    %{starboard: starboard, port: port, gap_s: gap_s}
  end
end
