defmodule RacingOrg.Tracker.Pro.Calibration.Replay do
  @moduledoc """
  Offline replay of the COMPLETE auto-calibration estimation pipeline over a
  recorded (or synthetic) ~1 Hz sample stream.

  This is the research-mandated validation harness: replay logged data through
  the estimators offline to confirm convergence — and, just as important,
  NON-divergence — before any correction is trusted on-water. It is a pure
  fold (no processes, no IO, no clocks) that wires the pipeline exactly as the
  live observer does:

      samples ──> Detect.Legs ──{:leg}──────────> Detect.Tack ──{:tack_pair}──> Estimator.AwaOffset
                        │            │
                        │            └──────────> Estimator.AwsScale   (legs, :t_end_s = ended_ms/1000)
                        │
                        └──{:reciprocal_pair}──> Estimator.StwScale

  Gybe pairs are counted for observability but not folded — the `AwaOffset`
  contrast is derived and validated for close-hauled pairs only (v1).

  ## Samples

  One map per ~1 s tick, the `Detect.Legs` sample shape: `:t_ms` required,
  plus `:heading_deg`, `:cog_deg`, `:sog_mps`, `:stw_mps`, `:awa_deg` (signed,
  starboard positive), `:aws_mps`, `:tws_mps`, `:heel_deg` — any of which may
  be `nil`.

  ## Options

    * `:legs`, `:tack`, `:awa`, `:stw`, `:aws` — keyword lists forwarded
      verbatim to `Detect.Legs.new/1`, `Detect.Tack.new/1`,
      `Estimator.AwaOffset.new/1`, `Estimator.StwScale.new/1` and
      `Estimator.AwsScale.new/1`, so replays can probe gate settings against
      recorded data.
    * `:trace` — when `true`, collect one entry per pipeline event (legs and
      pairs) with a full snapshot of every estimator at that moment, for
      convergence curves. Defaults to `false` (`trace: []` in the result).

  ## Result

      %{
        awa: %{rotation: %Estimate{}, upwash: %Estimate{}},
        stw: %{bands: %{center => %{rls: θ, estimate: %Estimate{}}}, gain_curve: [{center, gain}]},
        aws: %{downwind_over_upwind_ratio: %Estimate{}, regimes: %{...}},
        events: %{legs: n, tack_pairs: n, gybe_pairs: n, reciprocal_pairs: n},
        trace: [%{kind: kind, t_ms: t, awa: ..., stw: ..., aws: ...}]
      }

  The `events` counters make non-detection honest: a session with zero tack
  pairs SHOULD report estimators still `:learning` — silence, not invention.
  """

  alias RacingOrg.Tracker.Pro.Calibration.Detect.Leg
  alias RacingOrg.Tracker.Pro.Calibration.Detect.Legs
  alias RacingOrg.Tracker.Pro.Calibration.Detect.Tack
  alias RacingOrg.Tracker.Pro.Calibration.Estimate
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.AwaOffset
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.AwsScale
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.StwScale

  @type event_kind :: :leg | :tack_pair | :gybe_pair | :reciprocal_pair

  @type event_counts :: %{
          legs: non_neg_integer(),
          tack_pairs: non_neg_integer(),
          gybe_pairs: non_neg_integer(),
          reciprocal_pairs: non_neg_integer()
        }

  @type trace_entry :: %{
          kind: event_kind(),
          t_ms: integer(),
          awa: %{rotation: Estimate.t(), upwash: Estimate.t()},
          stw: map(),
          aws: map()
        }

  @type result :: %{
          awa: %{rotation: Estimate.t(), upwash: Estimate.t()},
          stw: map(),
          aws: map(),
          events: event_counts(),
          trace: [trace_entry()]
        }

  @doc """
  Fold `samples` (any `Enumerable` of sample maps, in time order) through the
  full pipeline and return the final snapshots, event counts, and optional
  trace. See the module doc for options and result shape.
  """
  @spec run(Enumerable.t(), keyword()) :: result()
  def run(samples, opts \\ []) do
    state = %{
      legs: Legs.new(Keyword.get(opts, :legs, [])),
      tack: Tack.new(Keyword.get(opts, :tack, [])),
      awa: AwaOffset.new(Keyword.get(opts, :awa, [])),
      stw: StwScale.new(Keyword.get(opts, :stw, [])),
      aws: AwsScale.new(Keyword.get(opts, :aws, [])),
      counts: %{legs: 0, tack_pairs: 0, gybe_pairs: 0, reciprocal_pairs: 0},
      trace: if(Keyword.get(opts, :trace, false), do: [], else: nil)
    }

    state = Enum.reduce(samples, state, &fold_sample(&2, &1))

    # End-of-stream: finalize any trailing leg exactly like the live pipeline
    # would at shutdown, so a session-ending leg still counts.
    {legs, tail_events} = Legs.flush(state.legs)
    state = Enum.reduce(tail_events, %{state | legs: legs}, &fold_legs_event(&2, &1))

    result(state)
  end

  # =====================================================================
  # The fold
  # =====================================================================

  defp fold_sample(state, sample) do
    {legs, events} = Legs.step(state.legs, sample)
    Enum.reduce(events, %{state | legs: legs}, &fold_legs_event(&2, &1))
  end

  # A completed steady leg feeds the tack pairer and the AWS diagnostic
  # (which takes its session clock from the leg's own end time).
  defp fold_legs_event(state, {:leg, %Leg{} = leg}) do
    {tack, tack_events} = Tack.step(state.tack, leg)

    state = %{
      state
      | tack: tack,
        aws: AwsScale.observe_leg(state.aws, aws_leg(leg)),
        counts: bump(state.counts, :legs)
    }

    state = trace(state, :leg, leg.ended_ms)
    Enum.reduce(tack_events, state, &fold_tack_event(&2, &1))
  end

  defp fold_legs_event(state, {:reciprocal_pair, %{a: %Leg{} = a, b: %Leg{} = b}}) do
    state = %{
      state
      | stw: StwScale.observe_pair(state.stw, %{a: Map.from_struct(a), b: Map.from_struct(b)}),
        counts: bump(state.counts, :reciprocal_pairs)
    }

    trace(state, :reciprocal_pair, max(a.ended_ms, b.ended_ms))
  end

  defp fold_tack_event(state, {:tack_pair, %{starboard: %Leg{} = s, port: %Leg{} = p}}) do
    pair = %{starboard: Map.from_struct(s), port: Map.from_struct(p)}

    state = %{
      state
      | awa: AwaOffset.observe_pair(state.awa, pair),
        counts: bump(state.counts, :tack_pairs)
    }

    trace(state, :tack_pair, max(s.ended_ms, p.ended_ms))
  end

  # Counted for observability; not folded (see module doc).
  defp fold_tack_event(state, {:gybe_pair, %{starboard: %Leg{} = s, port: %Leg{} = p}}) do
    state = %{state | counts: bump(state.counts, :gybe_pairs)}
    trace(state, :gybe_pair, max(s.ended_ms, p.ended_ms))
  end

  # =====================================================================
  # Snapshots
  # =====================================================================

  defp result(state) do
    %{
      awa: AwaOffset.snapshot(state.awa),
      stw: stw_snapshot(state.stw),
      aws: AwsScale.snapshot(state.aws),
      events: state.counts,
      trace: if(state.trace, do: Enum.reverse(state.trace), else: [])
    }
  end

  defp stw_snapshot(stw) do
    stw
    |> StwScale.snapshot()
    |> Map.put(:gain_curve, StwScale.gain_curve(stw))
  end

  defp trace(%{trace: nil} = state, _kind, _t_ms), do: state

  defp trace(state, kind, t_ms) do
    entry = %{
      kind: kind,
      t_ms: t_ms,
      awa: AwaOffset.snapshot(state.awa),
      stw: stw_snapshot(state.stw),
      aws: AwsScale.snapshot(state.aws)
    }

    %{state | trace: [entry | state.trace]}
  end

  # The estimators consume plain maps (Access-friendly), and the AWS
  # diagnostic's session clock is the leg's own end time in seconds.
  defp aws_leg(%Leg{} = leg) do
    leg
    |> Map.from_struct()
    |> Map.put(:t_end_s, leg.ended_ms / 1000)
  end

  defp bump(counts, key), do: Map.update!(counts, key, &(&1 + 1))
end
