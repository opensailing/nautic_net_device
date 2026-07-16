Code.require_file("replay_scenarios_helper.exs", __DIR__)
Code.require_file("detect/support/stream_gen_helper.exs", __DIR__)

defmodule RacingOrg.Tracker.Pro.Calibration.ReplayTest do
  @moduledoc """
  Offline replay / convergence validation of the full auto-calibration
  pipeline (`Legs → Tack → AwaOffset / StwScale / AwsScale`), over scripted
  multi-hour truths with injected instrument errors — the "replay logged data
  through the estimators offline to confirm convergence and non-divergence
  before trusting on-water" harness.

  Every scenario is deterministic (seeded RNG). Tolerances are the honest
  ones from the scenario spec — measured behavior is recorded in comments
  next to each assertion.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Detect.StreamGen
  alias RacingOrg.Tracker.Pro.Calibration.Estimate
  alias RacingOrg.Tracker.Pro.Calibration.Replay
  alias RacingOrg.Tracker.Pro.Calibration.ReplayScenarios, as: Scenarios

  # ==================================================================
  # FINDING (gate strictness): the tack detector's default
  # max_pair_span_s of 300 s admits a pair only when BOTH legs plus the
  # transition fit in five minutes — legs of ≤ ~135 s. A boat tacking
  # every 4 minutes (220 s legs) therefore produces ZERO tack pairs
  # under the defaults (locked in by the "default gates" test below).
  # The beat scenarios relax only that span gate so the mandated
  # 4-minute-tack race day can feed the estimators at all.
  # ==================================================================
  @beat_tack_opts [tack: [max_pair_span_s: 520.0]]

  # ==================================================================
  # Helpers
  # ==================================================================

  defp tack_pair_entries(trace), do: Enum.filter(trace, &(&1.kind == :tack_pair))

  # The 3-leg beat script used by the detection tests (see tack_test.exs).
  defp beat_script do
    truth = %{stw: 3.0, twd: 0.0, tws: 6.0}

    [
      {:steady, 90, Map.put(truth, :heading, 320.0)},
      {:turn, 30, Map.merge(truth, %{from: 320.0, to: 40.0})},
      {:steady, 90, Map.put(truth, :heading, 40.0)},
      {:turn, 30, Map.merge(truth, %{from: 40.0, to: 320.0})},
      {:steady, 90, Map.put(truth, :heading, 320.0)}
    ]
  end

  # Two reciprocal motoring runs (COG 010/192-ish) separated by a 120 s gap.
  defp motoring_script do
    [
      {:steady, 90, %{heading: 10.0, stw: 3.0, twd: 90.0, tws: 5.0}},
      {:gap, 120},
      {:steady, 90, %{heading: 192.0, stw: 3.0, twd: 90.0, tws: 5.0}}
    ]
  end

  # A broad-reach gybe (TWA -150 -> +150) from the detection tests.
  defp gybe_script do
    truth = %{stw: 3.0, twd: 0.0, tws: 6.0}

    [
      {:steady, 90, Map.put(truth, :heading, 150.0)},
      {:turn, 20, Map.merge(truth, %{from: 150.0, to: 210.0})},
      {:steady, 90, Map.put(truth, :heading, 210.0)}
    ]
  end

  # ==================================================================
  # run/2 wiring
  # ==================================================================

  describe "run/2 wiring" do
    test "an empty stream yields a fresh, honest result" do
      result = Replay.run([])

      assert result.events == %{legs: 0, tack_pairs: 0, gybe_pairs: 0, reciprocal_pairs: 0}

      assert %Estimate{value: nil, state: :learning, sample_count: 0} = result.awa.rotation
      assert %Estimate{value: nil, state: :learning, sample_count: 0} = result.awa.upwash
      assert result.stw.bands == %{}
      assert result.stw.gain_curve == []
      assert %Estimate{sample_count: 0, state: :learning} = result.aws.downwind_over_upwind_ratio
      assert result.trace == []
    end

    test "a scripted 3-leg beat wires Legs -> Tack -> AwaOffset" do
      result = Replay.run(StreamGen.generate(beat_script()))

      assert result.events == %{legs: 3, tack_pairs: 1, gybe_pairs: 0, reciprocal_pairs: 0}
      assert result.awa.rotation.sample_count == 1
      assert result.awa.upwash.sample_count == 1
      # No injected error: the single pair's raw estimates sit near zero.
      assert_in_delta result.awa.rotation.value, 0.0, 0.5
    end

    test "AwsScale receives every leg, timestamped from ended_ms" do
      result = Replay.run(StreamGen.generate(beat_script()))

      # All three legs are upwind (|AWA| ~ 27 deg) and inside the 2 h window;
      # a broken t_end_s plumbing would leave them in legs_skipped instead.
      assert result.aws.regimes.upwind.count == 3
      assert result.aws.regimes.downwind.count == 0
      assert result.aws.downwind_over_upwind_ratio.sample_count == 0
    end

    test "reciprocal motoring runs wire Legs -> StwScale" do
      result = Replay.run(StreamGen.generate(motoring_script()))

      assert result.events == %{legs: 2, tack_pairs: 0, gybe_pairs: 0, reciprocal_pairs: 1}
      assert %{3 => %{estimate: %Estimate{sample_count: 1}}} = result.stw.bands
      # One pair is nowhere near validation: nothing is promoted.
      assert result.stw.gain_curve == []
    end

    test "gybe pairs are counted but not folded into AwaOffset (v1)" do
      result = Replay.run(StreamGen.generate(gybe_script()))

      assert result.events == %{legs: 2, tack_pairs: 0, gybe_pairs: 1, reciprocal_pairs: 0}
      assert result.awa.rotation.sample_count == 0
    end

    test "trace: true collects per-event snapshots in time order" do
      result = Replay.run(StreamGen.generate(beat_script()), trace: true)

      assert length(result.trace) == 4
      assert Enum.map(result.trace, & &1.kind) == [:leg, :leg, :tack_pair, :leg]

      times = Enum.map(result.trace, & &1.t_ms)
      assert times == Enum.sort(times)

      # Each entry snapshots every estimator at that moment.
      final = List.last(result.trace)
      assert %Estimate{} = final.awa.rotation
      assert %{bands: %{}, gain_curve: []} = final.stw
      assert %Estimate{} = final.aws.downwind_over_upwind_ratio

      # The pair lands in the trace exactly when its second leg completes.
      [pair_entry] = tack_pair_entries(result.trace)
      assert pair_entry.awa.rotation.sample_count == 1
    end

    test "trace defaults to off and returns an empty list" do
      result = Replay.run(StreamGen.generate(beat_script()))
      assert result.trace == []
    end

    test "component options are forwarded to the detectors" do
      samples = StreamGen.generate(beat_script())

      # 90 s legs fail a raised min duration...
      assert Replay.run(samples, legs: [min_duration_s: 120.0]).events.legs == 0
      # ...and an impossible transition gate blocks pairing but not legs.
      strict = Replay.run(samples, tack: [max_transition_s: 0.1])
      assert strict.events == %{legs: 3, tack_pairs: 0, gybe_pairs: 0, reciprocal_pairs: 0}
    end
  end

  # ==================================================================
  # Scenario 1: race-day beat (rotation +3.0, upwash -1.5)
  # ==================================================================

  describe "scenario 1: race-day beat" do
    # 2 h upwind, tack every 4 min (220 s legs + 20 s tacks), TWD random-walks
    # within +-5 deg, TWS 12 +- 1 kn, per-sample AWA noise sigma 0.8 deg.
    # Injected: rotation error +3.0 deg (correction +3.0), upwash error
    # +1.5 deg (|AWA| reads high; correction -1.5).
    defp race_day_samples(overrides \\ []) do
      Scenarios.race_day_beat(
        Keyword.merge(
          [rotation_error_deg: 3.0, upwash_error_deg: 1.5, awa_sigma_deg: 0.8],
          overrides
        )
      )
    end

    test "recovers rotation +3.0 and upwash -1.5 within +-0.5, both validated" do
      result = Replay.run(race_day_samples(), @beat_tack_opts ++ [trace: true])

      # 30 legs -> 15 consecutive-leg tack pairs, all admitted.
      assert result.events.legs == 30
      assert result.events.tack_pairs == 15
      assert result.events.gybe_pairs == 0
      assert result.events.reciprocal_pairs == 0

      # Measured (seed {20260,716,1}): rotation 2.946 (error 0.054 deg,
      # spread 0.417); upwash -1.545 (error 0.045 deg, spread 0.308).
      assert %Estimate{state: :validated, value: rot} = result.awa.rotation
      assert %Estimate{state: :validated, value: up} = result.awa.upwash
      assert_in_delta rot, 3.0, 0.5
      assert_in_delta up, -1.5, 0.5

      # Convergence along the trace (measured):
      #   pair  1: rot 3.362, spread 0.00 (degenerate early IQR)
      #   pair  2: rot 2.602, spread 0.76  <- worst value error, 0.40 deg
      #   pair  8: rot 3.133, spread 0.34  <- first :validated (min_samples 8)
      #   pair 15: rot 2.946, spread 0.42  <- final
      # FINDING: the P-square spread is a SCATTER estimate — it converges UP
      # toward the raw per-pair scatter (~0.3-0.4 deg here) rather than
      # shrinking like a standard error, so "spread shrinking" is NOT the
      # signature of convergence. What converges is the VALUE: assert that
      # once the tracker first validates it stays validated, every validated
      # value sits within 0.25 deg of truth (measured max dev 0.133), and the
      # validated spread stays far inside the 2.0 deg gate.
      entries = tack_pair_entries(result.trace)
      assert length(entries) == 15

      validated = Enum.drop_while(entries, &(&1.awa.rotation.state != :validated))
      assert length(validated) == 8

      for entry <- validated do
        assert %Estimate{state: :validated, value: v, spread: s} = entry.awa.rotation
        assert_in_delta v, 3.0, 0.25
        assert s <= 0.5
      end

      # And the value error shrinks early -> late: the worst of the first five
      # pair estimates is ~0.40 deg off, the last five are all within 0.06.
      errors = Enum.map(entries, &abs(&1.awa.rotation.value - 3.0))
      assert Enum.max(Enum.take(errors, -5)) < 0.1
      assert Enum.max(Enum.take(errors, -5)) < Enum.max(Enum.take(errors, 5))
    end

    test "FINDING: under fully-default gates the same beat yields zero tack pairs" do
      # max_pair_span_s 300 rejects every 220 s + 20 s + 220 s pair, so a
      # 4-minute-tack race day is invisible to AwaOffset out of the box:
      # honest non-detection (everything stays :learning), but a gate the
      # live Observer will want to revisit for real race data.
      result = Replay.run(race_day_samples())

      assert result.events.legs == 30
      assert result.events.tack_pairs == 0
      assert %Estimate{state: :learning, sample_count: 0} = result.awa.rotation
    end
  end

  # ==================================================================
  # Scenario 2: delivery motor-out-and-back through current
  # ==================================================================

  describe "scenario 2: delivery reciprocals" do
    test "recovers the 1.06 speedo gain per sampled band within +-0.015" do
      # 8 out/back pairs at each of 3.6 / 5.3 / 7.4 m/s true STW through a
      # 0.4 m/s current 40 deg off-track; speedo under-reads by 1.06, so the
      # measured speeds land in bands 3 / 5 / 7.
      samples = Scenarios.delivery_reciprocals(stw_gain_error: 1.06)
      result = Replay.run(samples)

      assert result.events.legs == 48
      assert result.events.reciprocal_pairs == 24
      # 90 s silent turnarounds exceed the 60 s tack transition gate.
      assert result.events.tack_pairs == 0
      assert result.events.gybe_pairs == 0

      # Validated bands exist ONLY where the boat actually sampled speeds.
      assert result.stw.bands |> Map.keys() |> Enum.sort() == [3, 5, 7]

      # Measured: raw-gain medians 1.0628 / 1.0613 / 1.0607 (the tiny excess
      # over 1.06 is the O((c_cross/stw)^2) crossing-current residual, largest
      # in the slowest band); RLS gains 1.0559 / 1.0546 / 1.0541 (8 pairs pull
      # theta from its 1.0 prior ~90% of the way to the observations).
      for {center, %{estimate: est}} <- result.stw.bands do
        assert %Estimate{state: :validated} = est
        assert_in_delta est.value, 1.06, 0.01, "band #{center} median off"
      end

      assert [{3, g3}, {5, g5}, {7, g7}] = result.stw.gain_curve
      assert_in_delta g3, 1.06, 0.015
      assert_in_delta g5, 1.06, 0.015
      assert_in_delta g7, 1.06, 0.015
    end
  end

  # ==================================================================
  # Scenario 3 (ADVERSARIAL): a genuine 15-degree wind shift
  # ==================================================================

  describe "scenario 3: real TWD step mid-session" do
    test "SAFE: no validated AWA estimate ever sits > 1.5 deg from truth" do
      # Same race-day beat (rotation error +3.0, no upwash error), but TWD
      # genuinely steps +15 deg at t = 3690 s — mid-leg, so the leg straddling
      # the shift carries a skewed AWA mean and its pair contributes one
      # corrupted raw estimate (~ -2.5 deg off). The helmsman re-trims to the
      # new wind from the next leg on, so later pairs are clean again.
      samples =
        Scenarios.race_day_beat(
          rotation_error_deg: 3.0,
          awa_sigma_deg: 0.8,
          twd_step: {3_690, 15.0}
        )

      result = Replay.run(samples, @beat_tack_opts ++ [trace: true])
      assert result.events.tack_pairs == 15

      entries = tack_pair_entries(result.trace)

      # The safety property, asserted along the WHOLE trace: at no point does
      # a :validated estimate stray more than 1.5 deg from the injected truth
      # (rotation +3.0; upwash truth 0.0 — none injected).
      for entry <- entries do
        %{rotation: rot, upwash: up} = entry.awa

        if rot.state == :validated do
          assert_in_delta rot.value, 3.0, 1.5
        end

        if up.state == :validated do
          assert_in_delta up.value, 0.0, 1.5
        end
      end

      # The corruption really entered the stream: the shift-straddling pair
      # (the leg over t=3690 ends at 3819 s, pair 8) jumps the rotation
      # spread from 0.119 to 0.711 in one event — a jump (+0.59) no clean
      # pair produces after the trackers settle (scenario 1's worst settled
      # step is +0.22) — while the median moves by < 0.01 deg.
      settled_jumps =
        entries
        |> Enum.drop(5)
        |> Enum.map(& &1.awa.rotation.spread)
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> b - a end)

      assert Enum.max(settled_jumps) >= 0.4

      # What actually happens (measured): the outlier widens the spread; the
      # median absorbs it. Final rotation 2.992 (error 0.008 deg), still
      # validated; final upwash -0.001 against a truth of 0.0.
      assert %Estimate{state: :validated, value: rot} = result.awa.rotation
      assert_in_delta rot, 3.0, 1.0
      assert %Estimate{state: :validated, value: up} = result.awa.upwash
      assert_in_delta up, 0.0, 1.0
    end
  end

  # ==================================================================
  # Scenario 4 (ADVERSARIAL): single-tack delivery — observability honesty
  # ==================================================================

  describe "scenario 4: single-tack delivery" do
    test "with zero maneuvers nothing validates and nothing is invented" do
      # 2 h on one board with the same errors injected as scenario 1: the
      # errors are present but UNOBSERVABLE without maneuvers, and the
      # pipeline must say so rather than invent a value.
      samples =
        Scenarios.single_tack_delivery(
          rotation_error_deg: 3.0,
          upwash_error_deg: 1.5,
          awa_sigma_deg: 0.8
        )

      result = Replay.run(samples, @beat_tack_opts)

      assert result.events.legs == 1
      assert result.events.tack_pairs == 0
      assert result.events.gybe_pairs == 0
      assert result.events.reciprocal_pairs == 0

      assert %Estimate{value: nil, state: :learning, sample_count: 0} = result.awa.rotation
      assert %Estimate{value: nil, state: :learning, sample_count: 0} = result.awa.upwash

      # No reciprocals: no STW band ever forms, nothing is promoted.
      assert result.stw.bands == %{}
      assert result.stw.gain_curve == []

      # One long upwind leg: the AWS diagnostic has no downwind legs to
      # compare against and stays silent.
      assert result.aws.downwind_over_upwind_ratio.sample_count == 0
    end
  end

  # ==================================================================
  # Scenario 5: mixed noise robustness (waves)
  # ==================================================================

  describe "scenario 5: wave-induced heading oscillation" do
    # Scenario 1 with +-4 deg of heading oscillation at an 8 s period
    # superimposed (peak yaw rate ~3.1 deg/s, ~3.9 deg/s with helm noise).
    defp wavy_samples(overrides \\ []) do
      race_day_samples(Keyword.merge([wave: {4.0, 8.0}, turn_s: 10], overrides))
    end

    test "FINDING: default gates reject every wave-oscillated leg — no data, no false validation" do
      # The Legs rate gate (2 deg/s) trips on nearly every sample of +-4 deg
      # @ 8 s yaw, so NO leg ever completes: the pipeline reports zero events
      # and stays honestly in :learning. Safe (no false validation), but it
      # means an ordinary seaway silences auto-calibration entirely — the
      # live Observer needs a rate gate above the wave-yaw band (or yaw
      # low-pass filtering upstream) to learn anything offshore.
      result = Replay.run(wavy_samples(), @beat_tack_opts)

      assert result.events == %{legs: 0, tack_pairs: 0, gybe_pairs: 0, reciprocal_pairs: 0}
      assert %Estimate{state: :learning, sample_count: 0} = result.awa.rotation
      assert result.stw.gain_curve == []
    end

    test "with the rate gate above the wave band (4 deg/s) recovery matches flat water" do
      # 4.0 deg/s sits between the wave yaw peak (~3.9) and the 10 s tack
      # sweep (~9.3), so waves pass and maneuvers still segment the stream.
      result =
        Replay.run(
          wavy_samples(),
          [legs: [max_heading_rate_dps: 4.0], trace: true] ++ @beat_tack_opts
        )

      # 10 s tacks make the cycle 230 s: 31 full legs fit in 2 h and the
      # 70 s tail leg is flushed at end-of-stream, giving 32 legs / 16 pairs.
      assert result.events.legs == 32
      assert result.events.tack_pairs == 16

      # Measured: rotation 3.040 (error 0.040, spread 0.295), upwash -1.638
      # (error 0.138, spread 0.366) — the oscillation is symmetric on both
      # boards, so leg means (and the port/starboard contrast) stay unbiased
      # and recovery matches flat-water scenario 1.
      assert %Estimate{state: :validated, value: rot} = result.awa.rotation
      assert %Estimate{state: :validated, value: up} = result.awa.upwash
      assert_in_delta rot, 3.0, 0.5
      assert_in_delta up, -1.5, 0.5
    end
  end

  # ==================================================================
  # Scenario 6: heel-less boat
  # ==================================================================

  describe "scenario 6: no heel sensor" do
    test "recovery matches scenario 1 with heel_deg nil throughout" do
      result =
        Replay.run(race_day_samples(heel_deg: nil), @beat_tack_opts)

      assert result.events.legs == 30
      assert result.events.tack_pairs == 15

      # Identical stream geometry to scenario 1 (heel is aggregated but never
      # gates or feeds any estimator, and the constant consumes no RNG draws),
      # so recovery is bit-identical: rotation 2.946, upwash -1.545.
      assert %Estimate{state: :validated, value: rot} = result.awa.rotation
      assert %Estimate{state: :validated, value: up} = result.awa.upwash
      assert_in_delta rot, 3.0, 0.5
      assert_in_delta up, -1.5, 0.5
    end
  end
end
