defmodule RacingOrg.Tracker.Pro.Calibration.Detect.Legs do
  @moduledoc """
  Streaming steady-leg segmentation and reciprocal-course pairing.

  Auto-calibration estimators harvest their inputs from normal sailing: long,
  straight, settled legs and matched pairs of them. This module is the pure
  segmentation core — fold a ~1 Hz sample stream through `step/2` and it emits

    * `{:leg, %Leg{}}` — a completed steady leg, summarized as running
      aggregates (see `RacingOrg.Tracker.Pro.Calibration.Detect.Leg`), and
    * `{:reciprocal_pair, %{a: %Leg{}, b: %Leg{}}}` — two nearby legs sailed
      on opposite courses at matched speed (the classic reciprocal-run input
      for speed/compass calibration).

  It is deliberately I/O-free and GenServer-free: `new/1` builds a config +
  state struct, `step/2` is a pure fold step returning `{state, events}`, and
  `flush/1` finalizes a trailing leg at end-of-stream. Memory is bounded — a
  building segment is a fixed set of running scalar aggregates (heading and
  COG as running sine/cosine sums for circular statistics), and completed legs
  are retained for pairing only within the pairing window.

  ## Sample shape

  One map per ~1 s tick. `:t_ms` (monotonic milliseconds) is required; every
  other field may be `nil`:

    * `:heading_deg` — heading, 0–360 (wrap-aware rate + circular stats)
    * `:cog_deg` — course over ground, 0–360, or `nil`
    * `:sog_mps` — speed over ground, or `nil`
    * `:stw_mps` — speed through water
    * `:awa_deg` — signed apparent wind angle, ±180, starboard positive
    * `:aws_mps` — apparent wind speed
    * `:tws_mps` — true wind speed, or `nil`
    * `:heel_deg` — heel, or `nil`

  Heading, STW, AWA and AWS are what make a segment a *steady sailing leg*, so
  a sample missing any of them ends the current segment (a leg requiring a nil
  field just doesn't form). COG/SOG/TWS/heel are aggregated when present; a
  leg without COG/SOG still forms but is not eligible for reciprocal pairing.

  ## Leg criteria (configurable, with justification)

    * **Minimum duration** (`:min_duration_s`, default `60.0`): calibration
      wants settled averages; a minute at 1 Hz gives ~60 samples per leg.
    * **Peak heading rate** (`:max_heading_rate_dps`, default `4.0` °/s):
      wrap-aware sample-to-sample heading rate. Tacks/gybes slew at 5–30 °/s
      so 4 °/s still excludes maneuvers, while admitting ordinary wave-induced
      heading oscillation (±4° at 8 s peaks at ~3.1 °/s); sustained slow
      curves are caught by the heading-dispersion gate instead.
    * **Heading dispersion** (`:max_heading_sd_deg`, default `8.0`): circular
      standard deviation across the whole segment. Catches slow wander that
      never trips the rate check but still isn't a straight leg.
    * **Peak STW acceleration** (`:max_stw_accel_mps2`, default `0.05` m/s²):
      the boat must be at a stable speed, not building or bleeding.
    * **Constant AWA side** (`:awa_side_min_deg`, default `5.0`): no AWA sign
      flip across the segment, judged only on samples with `|awa|` at or above
      the deadband (near-zero AWA jitters across the bow without meaning a
      tack).
    * **Maximum gap** (`:max_gap_ms`, default `5_000`): a hole in the stream
      longer than this ends the segment — we can't vouch for what happened.

  A segment ends when a criterion breaks, a required field goes missing, or a
  gap occurs; it is emitted as a leg only if it lasted at least the minimum
  duration. The breaking sample (when itself valid) seeds the next segment.
  Samples whose clock does not advance are dropped.

  ## Reciprocal pairing (configurable)

  When a leg completes with valid COG and SOG it is checked against recently
  completed unpaired legs:

    * **Window** (`:pair_window_ms`, default `600_000` = 10 min): the new
      leg must start within the window after the candidate ended.
    * **Opposite course** (`:reciprocal_tol_deg`, default `15.0`): the legs'
      circular COG means are reciprocal within the tolerance.
    * **Matched speed** (`:speed_match_frac`, default `0.25`): the legs'
      STW means differ by at most this fraction of the faster leg.

  Each leg pairs at most once; among multiple candidates the closest in time
  wins. Candidates older than the window are pruned, which bounds memory.

  ## Usage

      {state, events} =
        Enum.flat_map_reduce(samples, Legs.new(), fn sample, state ->
          {state, events} = Legs.step(state, sample)
          {events, state}
        end)

      {_state, tail} = Legs.flush(state)
  """

  alias RacingOrg.Tracker.Pro.Calibration.Detect.Circular
  alias RacingOrg.Tracker.Pro.Calibration.Detect.Leg

  @default_min_duration_s 60.0
  # 4°/s admits ordinary wave-induced heading oscillation (±4° at an 8 s period
  # peaks at ~3.1°/s, which the original 2°/s default rejected outright — the
  # replay findings showed zero legs, hence zero learning, in any seaway).
  # Real maneuvers still break legs: a tack turns at ~5–10°/s, and sustained
  # slow curves are rejected by the heading circular-sd gate.
  @default_max_heading_rate_dps 4.0
  @default_max_heading_sd_deg 8.0
  @default_max_stw_accel_mps2 0.05
  @default_awa_side_min_deg 5.0
  @default_max_gap_ms 5_000
  @default_pair_window_ms 600_000
  @default_reciprocal_tol_deg 15.0
  @default_speed_match_frac 0.25

  defstruct min_duration_s: @default_min_duration_s,
            max_heading_rate_dps: @default_max_heading_rate_dps,
            max_heading_sd_deg: @default_max_heading_sd_deg,
            max_stw_accel_mps2: @default_max_stw_accel_mps2,
            awa_side_min_deg: @default_awa_side_min_deg,
            max_gap_ms: @default_max_gap_ms,
            pair_window_ms: @default_pair_window_ms,
            reciprocal_tol_deg: @default_reciprocal_tol_deg,
            speed_match_frac: @default_speed_match_frac,
            seg: nil,
            pending: []

  @type sample :: %{required(:t_ms) => integer(), optional(atom()) => term()}
  @type event :: {:leg, Leg.t()} | {:reciprocal_pair, %{a: Leg.t(), b: Leg.t()}}

  @type t :: %__MODULE__{
          min_duration_s: float(),
          max_heading_rate_dps: float(),
          max_heading_sd_deg: float(),
          max_stw_accel_mps2: float(),
          awa_side_min_deg: float(),
          max_gap_ms: pos_integer(),
          pair_window_ms: pos_integer(),
          reciprocal_tol_deg: float(),
          speed_match_frac: float(),
          seg: map() | nil,
          pending: [Leg.t()]
        }

  @doc """
  Build a detector. See the module doc for every option and its default.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      min_duration_s: Keyword.get(opts, :min_duration_s, @default_min_duration_s),
      max_heading_rate_dps: Keyword.get(opts, :max_heading_rate_dps, @default_max_heading_rate_dps),
      max_heading_sd_deg: Keyword.get(opts, :max_heading_sd_deg, @default_max_heading_sd_deg),
      max_stw_accel_mps2: Keyword.get(opts, :max_stw_accel_mps2, @default_max_stw_accel_mps2),
      awa_side_min_deg: Keyword.get(opts, :awa_side_min_deg, @default_awa_side_min_deg),
      max_gap_ms: Keyword.get(opts, :max_gap_ms, @default_max_gap_ms),
      pair_window_ms: Keyword.get(opts, :pair_window_ms, @default_pair_window_ms),
      reciprocal_tol_deg: Keyword.get(opts, :reciprocal_tol_deg, @default_reciprocal_tol_deg),
      speed_match_frac: Keyword.get(opts, :speed_match_frac, @default_speed_match_frac)
    }
  end

  @doc """
  Fold one sample into the detector. Returns `{state, events}`; events are
  emitted when the sample ends a qualifying leg (the leg event precedes any
  pair event it triggers).
  """
  @spec step(t(), sample()) :: {t(), [event()]}
  def step(%__MODULE__{seg: nil} = t, sample) do
    if eligible?(sample) do
      {%{t | seg: seg_new(t, sample)}, []}
    else
      {t, []}
    end
  end

  def step(%__MODULE__{seg: seg} = t, sample) do
    cond do
      not eligible?(sample) ->
        close(t)

      # Non-advancing clock: no rate is definable against it; drop the sample.
      sample[:t_ms] <= seg.last_ms ->
        {t, []}

      break?(t, seg, sample) ->
        restart(t, sample)

      true ->
        case seg_add(t, seg, sample) do
          {:steady, seg} -> {%{t | seg: seg}, []}
          :unsteady -> restart(t, sample)
        end
    end
  end

  @doc """
  Finalize the stream: ends any building segment, emitting it (and any pair it
  completes) if it qualifies as a leg. Call once at end-of-stream.
  """
  @spec flush(t()) :: {t(), [event()]}
  def flush(%__MODULE__{} = t), do: close(t)

  # =====================================================================
  # Segmentation
  # =====================================================================

  # Heading, STW, AWA and AWS define a steady sailing leg; without any one of
  # them the segment cannot continue.
  defp eligible?(sample) do
    is_number(sample[:heading_deg]) and is_number(sample[:stw_mps]) and
      is_number(sample[:awa_deg]) and is_number(sample[:aws_mps])
  end

  # Sample-to-sample criteria: stream gap, wrap-aware heading rate, STW
  # acceleration, AWA side flip.
  defp break?(t, seg, sample) do
    dt_ms = sample[:t_ms] - seg.last_ms
    dt = dt_ms / 1000.0

    dt_ms > t.max_gap_ms or
      Circular.distance(seg.last_heading, sample[:heading_deg]) / dt > t.max_heading_rate_dps or
      abs(sample[:stw_mps] - seg.last_stw) / dt > t.max_stw_accel_mps2 or
      side_flip?(t, seg, sample)
  end

  defp side_flip?(%{awa_side_min_deg: min_deg}, %{side: seg_side}, sample) do
    case {seg_side, awa_side(sample[:awa_deg], min_deg)} do
      {nil, _} -> false
      {_, nil} -> false
      {same, same} -> false
      _ -> true
    end
  end

  defp awa_side(awa, min_deg) do
    cond do
      abs(awa) < min_deg -> nil
      awa >= 0 -> :starboard
      true -> :port
    end
  end

  # Whole-segment criterion: adding the sample must keep the heading circular
  # standard deviation inside the steadiness bound.
  defp seg_add(t, seg, sample) do
    heading = sample[:heading_deg]
    hdg_sin = seg.hdg_sin + Circular.sin_deg(heading)
    hdg_cos = seg.hdg_cos + Circular.cos_deg(heading)

    if Circular.sd_from_sums(hdg_sin, hdg_cos, seg.n + 1) > t.max_heading_sd_deg do
      :unsteady
    else
      {:steady, accumulate(seg, t, sample)}
    end
  end

  # Zero aggregates seeded with the first sample.
  defp seg_new(t, sample) do
    accumulate(
      %{
        started_ms: sample[:t_ms],
        last_ms: sample[:t_ms],
        n: 0,
        last_heading: 0.0,
        last_stw: 0.0,
        side: nil,
        hdg_sin: 0.0,
        hdg_cos: 0.0,
        stw_sum: 0.0,
        stw_sq: 0.0,
        awa_sum: 0.0,
        awa_abs_sum: 0.0,
        aws_sum: 0.0,
        cog_sin: 0.0,
        cog_cos: 0.0,
        cog_n: 0,
        sog_sum: 0.0,
        sog_n: 0,
        tws_sum: 0.0,
        tws_sq: 0.0,
        tws_n: 0,
        heel_sum: 0.0,
        heel_n: 0
      },
      t,
      sample
    )
  end

  # Fold one (eligible) sample into the running aggregates — constant size.
  defp accumulate(seg, t, sample) do
    heading = sample[:heading_deg]
    stw = sample[:stw_mps]
    awa = sample[:awa_deg]

    seg = %{
      seg
      | last_ms: sample[:t_ms],
        n: seg.n + 1,
        last_heading: heading,
        last_stw: stw,
        side: seg.side || awa_side(awa, t.awa_side_min_deg),
        hdg_sin: seg.hdg_sin + Circular.sin_deg(heading),
        hdg_cos: seg.hdg_cos + Circular.cos_deg(heading),
        stw_sum: seg.stw_sum + stw,
        stw_sq: seg.stw_sq + stw * stw,
        awa_sum: seg.awa_sum + awa,
        awa_abs_sum: seg.awa_abs_sum + abs(awa),
        aws_sum: seg.aws_sum + sample[:aws_mps]
    }

    seg
    |> add_cog(sample[:cog_deg])
    |> add_sog(sample[:sog_mps])
    |> add_tws(sample[:tws_mps])
    |> add_heel(sample[:heel_deg])
  end

  defp add_cog(seg, cog) when is_number(cog) do
    %{
      seg
      | cog_sin: seg.cog_sin + Circular.sin_deg(cog),
        cog_cos: seg.cog_cos + Circular.cos_deg(cog),
        cog_n: seg.cog_n + 1
    }
  end

  defp add_cog(seg, _), do: seg

  defp add_sog(seg, sog) when is_number(sog), do: %{seg | sog_sum: seg.sog_sum + sog, sog_n: seg.sog_n + 1}
  defp add_sog(seg, _), do: seg

  defp add_tws(seg, tws) when is_number(tws) do
    %{seg | tws_sum: seg.tws_sum + tws, tws_sq: seg.tws_sq + tws * tws, tws_n: seg.tws_n + 1}
  end

  defp add_tws(seg, _), do: seg

  defp add_heel(seg, heel) when is_number(heel), do: %{seg | heel_sum: seg.heel_sum + heel, heel_n: seg.heel_n + 1}
  defp add_heel(seg, _), do: seg

  # =====================================================================
  # Finalization and pairing
  # =====================================================================

  # End the current segment (if any): emit it as a leg when it qualifies,
  # then try to pair it.
  defp close(%__MODULE__{seg: nil} = t), do: {t, []}

  defp close(%__MODULE__{seg: seg} = t) do
    t = %{t | seg: nil}

    case build_leg(t, seg) do
      nil ->
        {t, []}

      leg ->
        {t, pair_events} = pair(t, leg)
        {t, [{:leg, leg} | pair_events]}
    end
  end

  # End the current segment and seed the next one with the breaking sample.
  defp restart(t, sample) do
    {t, events} = close(t)
    {%{t | seg: seg_new(t, sample)}, events}
  end

  defp build_leg(%__MODULE__{min_duration_s: min_s}, seg) do
    duration_s = (seg.last_ms - seg.started_ms) / 1000.0

    if seg.n >= 2 and duration_s >= min_s do
      awa_mean = seg.awa_sum / seg.n

      %Leg{
        started_ms: seg.started_ms,
        ended_ms: seg.last_ms,
        duration_s: duration_s,
        samples: seg.n,
        side: if(awa_mean >= 0.0, do: :starboard, else: :port),
        heading_mean: Circular.mean_from_sums(seg.hdg_sin, seg.hdg_cos),
        heading_sd: Circular.sd_from_sums(seg.hdg_sin, seg.hdg_cos, seg.n),
        cog_mean: if(seg.cog_n > 0, do: Circular.mean_from_sums(seg.cog_sin, seg.cog_cos)),
        sog_mean: if(seg.sog_n > 0, do: seg.sog_sum / seg.sog_n),
        stw_mean: seg.stw_sum / seg.n,
        stw_sd: sd_from_sums(seg.stw_sum, seg.stw_sq, seg.n),
        awa_mean_signed: awa_mean,
        awa_abs_mean: seg.awa_abs_sum / seg.n,
        aws_mean: seg.aws_sum / seg.n,
        tws_mean: if(seg.tws_n > 0, do: seg.tws_sum / seg.tws_n),
        tws_sd: if(seg.tws_n > 0, do: sd_from_sums(seg.tws_sum, seg.tws_sq, seg.tws_n)),
        heel_mean: if(seg.heel_n > 0, do: seg.heel_sum / seg.heel_n)
      }
    end
  end

  # A completed leg with valid COG/SOG either pairs with the closest-in-time
  # reciprocal candidate or becomes a candidate itself. Candidates older than
  # the pairing window are pruned (bounded memory); each leg pairs at most
  # once.
  defp pair(%__MODULE__{} = t, %Leg{cog_mean: cog, sog_mean: sog} = leg)
       when is_number(cog) and is_number(sog) do
    pending = Enum.filter(t.pending, fn c -> leg.started_ms - c.ended_ms <= t.pair_window_ms end)

    case best_reciprocal(t, pending, leg) do
      nil ->
        {%{t | pending: [leg | pending]}, []}

      mate ->
        {%{t | pending: List.delete(pending, mate)}, [{:reciprocal_pair, %{a: mate, b: leg}}]}
    end
  end

  defp pair(t, _leg), do: {t, []}

  defp best_reciprocal(t, pending, leg) do
    pending
    |> Enum.filter(&reciprocal_match?(t, &1, leg))
    |> Enum.max_by(& &1.ended_ms, fn -> nil end)
  end

  defp reciprocal_match?(t, a, b) do
    Circular.distance(Circular.normalize(a.cog_mean + 180.0), b.cog_mean) <= t.reciprocal_tol_deg and
      abs(a.stw_mean - b.stw_mean) <= t.speed_match_frac * max(a.stw_mean, b.stw_mean)
  end

  # Population standard deviation from running sum / sum-of-squares.
  defp sd_from_sums(sum, sq_sum, n) do
    mean = sum / n
    :math.sqrt(max(sq_sum / n - mean * mean, 0.0))
  end
end
