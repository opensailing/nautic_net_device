Code.require_file("support/stream_gen_helper.exs", __DIR__)

defmodule RacingOrg.Tracker.Pro.Calibration.Detect.LegsTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Detect.Leg
  alias RacingOrg.Tracker.Pro.Calibration.Detect.Legs
  alias RacingOrg.Tracker.Pro.Calibration.Detect.StreamGen

  # ==================================================================
  # Helpers
  # ==================================================================

  # Fold a sample stream through the detector and flush the trailing leg.
  defp run(samples, opts \\ []) do
    {events, state} =
      Enum.flat_map_reduce(samples, Legs.new(opts), fn sample, state ->
        {state, events} = Legs.step(state, sample)
        {events, state}
      end)

    {state, tail} = Legs.flush(state)
    {state, events ++ tail}
  end

  defp legs(events), do: for({:leg, leg} <- events, do: leg)
  defp recips(events), do: for({:reciprocal_pair, pair} <- events, do: pair)

  # Wrap-aware absolute angular distance, kept independent of the code under test.
  defp circ_dist(a, b) do
    d = :math.fmod(b - a + 180.0, 360.0)
    d = if d < 0.0, do: d + 360.0, else: d
    abs(d - 180.0)
  end

  # A 3-leg beat in a northerly: TWA ~ +40 / -40 / +40, 90 s legs, 30 s turns.
  defp beat_script do
    truth = %{stw: 3.0, twd: 0.0, tws: 6.0}

    [
      # Realistic 10 s tacks (80 deg / 10 s = 8 deg/s) stay well above the
      # 4 deg/s rate gate, so the turn samples break legs crisply and the
      # leg means match the scripted steady headings.
      {:steady, 90, Map.put(truth, :heading, 320.0)},
      {:turn, 10, Map.merge(truth, %{from: 320.0, to: 40.0})},
      {:steady, 90, Map.put(truth, :heading, 40.0)},
      {:turn, 10, Map.merge(truth, %{from: 40.0, to: 320.0})},
      {:steady, 90, Map.put(truth, :heading, 320.0)}
    ]
  end

  # A steady beam reach (TWA -90): far from both the AWA side deadband and the
  # downwind sign flip, so heading-noise tests only exercise heading criteria.
  @beam %{heading: 90.0, stw: 3.0, twd: 0.0, tws: 6.0}

  # Two motoring runs with wind on the beam-ish; heading2/stw2/gap parameterized.
  defp motoring_script(heading2, opts \\ []) do
    stw2 = Keyword.get(opts, :stw2, 3.0)
    gap_s = Keyword.get(opts, :gap_s, 120)

    [
      {:steady, 90, %{heading: 10.0, stw: 3.0, twd: 90.0, tws: 5.0}},
      {:gap, gap_s},
      {:steady, 90, %{heading: heading2, stw: stw2, twd: 90.0, tws: 5.0}}
    ]
  end

  # ==================================================================
  # Steady-leg segmentation
  # ==================================================================

  describe "steady-leg segmentation" do
    test "a scripted 3-leg beat yields exactly 3 legs with correct sides and aggregates" do
      {_state, events} = run(StreamGen.generate(beat_script()))

      assert [l1, l2, l3] = legs(events)

      # Sides from the mean AWA sign (starboard positive).
      assert l1.side == :starboard
      assert l2.side == :port
      assert l3.side == :starboard
      assert l1.awa_mean_signed > 0.0
      assert l2.awa_mean_signed < 0.0

      # Circular heading means match the scripted headings.
      assert circ_dist(l1.heading_mean, 320.0) < 1.0
      assert circ_dist(l2.heading_mean, 40.0) < 1.0
      assert circ_dist(l3.heading_mean, 320.0) < 1.0
      assert l1.heading_sd < 2.0

      # Scalar aggregates match the scripted truth.
      for leg <- [l1, l2, l3] do
        assert_in_delta leg.stw_mean, 3.0, 0.05
        assert leg.stw_sd < 0.05
        assert_in_delta leg.tws_mean, 6.0, 0.15
        assert leg.tws_sd < 0.2
        # TWA 40 @ TWS 6 / STW 3 -> AWA ~ 26.9 deg.
        assert_in_delta leg.awa_abs_mean, 26.9, 2.0
        assert leg.aws_mean > 6.0
        assert_in_delta leg.heel_mean, 12.0, 0.001
        assert leg.duration_s >= 85.0 and leg.duration_s <= 95.0
        assert leg.samples >= 85 and leg.samples <= 96
        assert is_float(leg.cog_mean)
        assert_in_delta leg.sog_mean, 3.0, 0.05
      end

      assert l1.ended_ms < l2.started_ms
      assert l2.ended_ms < l3.started_ms

      # Beat legs are not reciprocal courses.
      assert recips(events) == []
    end

    test "heading noise below the circular-sd threshold admits a leg, above splits it" do
      # Disable the sample-to-sample rate criterion so only the sd criterion acts.
      opts = [max_heading_rate_dps: 1.0e9]

      # amp 6 -> circular sd ~ 2 deg, well under the 8 deg default.
      quiet = StreamGen.generate([{:steady, 90, @beam}], noise: %{heading: 6.0})
      {_state, events} = run(quiet, opts)
      assert [%Leg{}] = legs(events)

      # amp 36 -> circular sd ~ 12 deg: every fragment breaks before 60 s.
      noisy = StreamGen.generate([{:steady, 90, @beam}], noise: %{heading: 36.0})
      {_state, events} = run(noisy, opts)
      assert legs(events) == []
    end

    test "a 10 s gap splits a leg" do
      samples = StreamGen.generate([{:steady, 80, @beam}, {:gap, 10}, {:steady, 80, @beam}])
      {_state, events} = run(samples)

      assert [a, b] = legs(events)
      assert a.ended_ms < b.started_ms
      assert b.started_ms - a.ended_ms >= 10_000
    end

    test "a gap within max_gap_ms does not split a leg" do
      samples = StreamGen.generate([{:steady, 80, @beam}, {:gap, 3}, {:steady, 80, @beam}])
      {_state, events} = run(samples)

      assert [leg] = legs(events)
      assert leg.duration_s >= 160.0
    end

    test "circular heading mean is correct across the 359 -> 1 wrap" do
      truth = %{heading: 359.5, stw: 3.0, twd: 90.0, tws: 6.0}
      samples = StreamGen.generate([{:steady, 90, truth}])
      {_state, events} = run(samples)

      assert [leg] = legs(events)
      # A naive arithmetic mean of headings jittering across the wrap is ~180.
      assert circ_dist(leg.heading_mean, 359.5) < 0.5
      assert leg.heading_mean >= 0.0 and leg.heading_mean < 360.0
      assert leg.heading_sd < 2.0
    end

    test "an STW acceleration burst breaks a leg in two" do
      slow = @beam
      fast = %{@beam | stw: 3.5}
      samples = StreamGen.generate([{:steady, 90, slow}, {:steady, 90, fast}])
      {_state, events} = run(samples)

      assert [a, b] = legs(events)
      assert_in_delta a.stw_mean, 3.0, 0.05
      assert_in_delta b.stw_mean, 3.5, 0.05
    end

    test "a sample missing a required channel ends the current leg" do
      samples =
        [{:steady, 181, @beam}]
        |> StreamGen.generate()
        |> List.update_at(90, &%{&1 | stw_mps: nil})

      {_state, events} = run(samples)
      assert length(legs(events)) == 2
    end

    test "nil heel yields legs with heel_mean nil" do
      samples = StreamGen.generate([{:steady, 90, @beam}], drop: [:heel_deg])
      {_state, events} = run(samples)

      assert [%Leg{heel_mean: nil}] = legs(events)
    end

    test "segments shorter than min duration are discarded" do
      samples = StreamGen.generate([{:steady, 40, @beam}])
      {_state, events} = run(samples)

      assert legs(events) == []
    end
  end

  # ==================================================================
  # Reciprocal-course pairing
  # ==================================================================

  describe "reciprocal-course pairing" do
    test "reciprocal COGs (010/192) within 5 min at matched speed pair exactly once" do
      {_state, events} = run(StreamGen.generate(motoring_script(192.0)))

      assert length(legs(events)) == 2
      assert [%{a: a, b: b}] = recips(events)
      assert a.started_ms < b.started_ms
      assert circ_dist(a.cog_mean, 10.0) < 1.0
      assert circ_dist(b.cog_mean, 192.0) < 1.0
    end

    test "non-reciprocal COGs (010/160) do not pair" do
      {_state, events} = run(StreamGen.generate(motoring_script(160.0)))

      assert length(legs(events)) == 2
      assert recips(events) == []
    end

    test "same-direction legs do not pair" do
      {_state, events} = run(StreamGen.generate(motoring_script(10.0)))

      assert length(legs(events)) == 2
      assert recips(events) == []
    end

    test "legs more than pair_window_ms apart do not pair" do
      {_state, events} = run(StreamGen.generate(motoring_script(192.0, gap_s: 700)))

      assert length(legs(events)) == 2
      assert recips(events) == []
    end

    test "a relative speed mismatch beyond speed_match_frac rejects the pair" do
      {_state, events} = run(StreamGen.generate(motoring_script(192.0, stw2: 4.2)))

      assert length(legs(events)) == 2
      assert recips(events) == []
    end

    test "nil COG: legs still form but cannot pair" do
      samples = StreamGen.generate(motoring_script(192.0), drop: [:cog_deg])
      {_state, events} = run(samples)

      assert [%Leg{cog_mean: nil}, %Leg{cog_mean: nil}] = legs(events)
      assert recips(events) == []
    end
  end

  # ==================================================================
  # Memory boundedness
  # ==================================================================

  describe "memory boundedness" do
    test "10k samples of continuous tacking do not grow unbounded state" do
      truth = %{stw: 3.0, twd: 0.0, tws: 6.0}

      cycle = [
        {:steady, 90, Map.put(truth, :heading, 320.0)},
        {:turn, 30, Map.merge(truth, %{from: 320.0, to: 40.0})},
        {:steady, 90, Map.put(truth, :heading, 40.0)},
        {:turn, 30, Map.merge(truth, %{from: 40.0, to: 320.0})}
      ]

      samples = StreamGen.generate(List.flatten(List.duplicate(cycle, 42)))
      assert length(samples) >= 10_000

      {state, sizes} =
        samples
        |> Enum.with_index(1)
        |> Enum.reduce({Legs.new(), []}, fn {sample, i}, {state, sizes} ->
          {state, _events} = Legs.step(state, sample)
          sizes = if rem(i, 2500) == 0, do: [:erts_debug.flat_size(state) | sizes], else: sizes
          {state, sizes}
        end)

      [size_10k, _, size_5k, _] = sizes

      # Only running aggregates and a time-pruned handful of pending legs.
      assert size_10k < 6_000
      # Once the pairing window is saturated the state stops growing.
      assert size_10k <= size_5k * 1.5

      assert is_list(state.pending)
      assert length(state.pending) <= 16
      assert Enum.all?(state.pending, &match?(%Leg{}, &1))

      # The open segment holds scalar aggregates only - no per-sample retention.
      if state.seg do
        assert Enum.all?(Map.values(state.seg), fn v -> is_number(v) or is_atom(v) or is_nil(v) end)
      end
    end
  end
end
