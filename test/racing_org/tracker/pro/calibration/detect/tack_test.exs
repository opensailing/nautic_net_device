Code.require_file("support/stream_gen_helper.exs", __DIR__)

defmodule RacingOrg.Tracker.Pro.Calibration.Detect.TackTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Detect.Leg
  alias RacingOrg.Tracker.Pro.Calibration.Detect.Legs
  alias RacingOrg.Tracker.Pro.Calibration.Detect.StreamGen
  alias RacingOrg.Tracker.Pro.Calibration.Detect.Tack

  # ==================================================================
  # Helpers
  # ==================================================================

  # Chain: samples -> Legs (flushed) -> every Legs event -> Tack.
  defp detect(samples, legs_opts \\ [], tack_opts \\ []) do
    {leg_events, legs_state} =
      Enum.flat_map_reduce(samples, Legs.new(legs_opts), fn sample, state ->
        {state, events} = Legs.step(state, sample)
        {events, state}
      end)

    {_legs_state, tail} = Legs.flush(legs_state)
    leg_events = leg_events ++ tail

    {pair_events, tack_state} =
      Enum.flat_map_reduce(leg_events, Tack.new(tack_opts), fn event, state ->
        {state, events} = Tack.step(state, event)
        {events, state}
      end)

    {tack_state, leg_events, pair_events}
  end

  defp tacks(events), do: for({:tack_pair, pair} <- events, do: pair)
  defp gybes(events), do: for({:gybe_pair, pair} <- events, do: pair)
  defp legs(events), do: for({:leg, leg} <- events, do: leg)

  # A hand-built starboard close-hauled leg (0..80 s) to exercise the pairing
  # criteria one at a time.
  defp stbd_leg(overrides \\ []) do
    struct!(
      %Leg{
        started_ms: 0,
        ended_ms: 80_000,
        duration_s: 80.0,
        samples: 81,
        side: :starboard,
        heading_mean: 320.0,
        heading_sd: 1.0,
        cog_mean: 320.0,
        sog_mean: 3.0,
        stw_mean: 3.0,
        stw_sd: 0.02,
        awa_mean_signed: 30.0,
        awa_abs_mean: 30.0,
        aws_mean: 8.0,
        tws_mean: 6.0,
        tws_sd: 0.1,
        heel_mean: 12.0
      },
      overrides
    )
  end

  # Its natural mate: a port close-hauled leg 30 s later on the other board.
  defp port_leg(overrides \\ []) do
    stbd_leg(
      Keyword.merge(
        [
          started_ms: 110_000,
          ended_ms: 190_000,
          side: :port,
          heading_mean: 40.0,
          cog_mean: 40.0,
          awa_mean_signed: -30.0
        ],
        overrides
      )
    )
  end

  defp pair_up(a, b, opts \\ []) do
    {state, []} = Tack.step(Tack.new(opts), a)
    Tack.step(state, b)
  end

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

  # ==================================================================
  # Pairing criteria (hand-built legs)
  # ==================================================================

  describe "pairing criteria" do
    test "two consecutive opposite close-hauled legs form a tack pair" do
      a = stbd_leg()
      b = port_leg()

      assert {state, [{:tack_pair, pair}]} = pair_up(a, b)
      assert pair.starboard == a
      assert pair.port == b
      assert_in_delta pair.gap_s, 30.0, 0.001
      assert state.pending == nil
    end

    test "accepts {:leg, leg} event tuples and ignores other Legs events" do
      state = Tack.new()

      assert {^state, []} = Tack.step(state, {:reciprocal_pair, %{a: stbd_leg(), b: port_leg()}})

      {state, []} = Tack.step(state, {:leg, stbd_leg()})
      assert {_state, [{:tack_pair, _}]} = Tack.step(state, {:leg, port_leg()})
    end

    test "same-side legs never pair; the newer leg becomes the candidate" do
      a = stbd_leg()
      later = stbd_leg(started_ms: 110_000, ended_ms: 190_000)

      assert {state, []} = pair_up(a, later)
      assert state.pending == later
    end

    test "a transition longer than max_transition_s rejects the pair" do
      b = port_leg(started_ms: 145_000, ended_ms: 225_000)
      assert {%{pending: ^b}, []} = pair_up(stbd_leg(), b)
    end

    test "a total span longer than max_pair_span_s rejects the pair" do
      # Transition stays within max_transition_s; only the 600 s span gate
      # rejects (b alone runs 130 s -> 720 s).
      b = port_leg(started_ms: 130_000, ended_ms: 720_000, duration_s: 590.0)
      assert {%{pending: ^b}, []} = pair_up(stbd_leg(), b)
    end

    test "a heading swing below min_swing_deg rejects the pair" do
      b = port_leg(heading_mean: 355.0, cog_mean: 355.0)
      assert {%{pending: ^b}, []} = pair_up(stbd_leg(), b)
    end

    test "a leg shorter than min_leg_s rejects the pair" do
      b = port_leg(duration_s: 25.0)
      assert {%{pending: ^b}, []} = pair_up(stbd_leg(), b)
    end

    test "a TWS mismatch beyond tws_match_mps rejects the pair" do
      b = port_leg(tws_mean: 7.6)
      assert {%{pending: ^b}, []} = pair_up(stbd_leg(), b)
    end

    test "a missing TWS skips the wind-steadiness check" do
      b = port_leg(tws_mean: nil, tws_sd: nil)
      assert {_state, [{:tack_pair, _}]} = pair_up(stbd_leg(), b)
    end

    test "a close-hauled leg against a broad leg is neither a tack nor a gybe pair" do
      b = port_leg(awa_mean_signed: -125.0, awa_abs_mean: 125.0)
      assert {%{pending: ^b}, []} = pair_up(stbd_leg(), b)
    end

    test "two opposite broad legs form a gybe pair, not a tack pair" do
      a = stbd_leg(side: :port, heading_mean: 150.0, awa_mean_signed: -150.0, awa_abs_mean: 150.0)

      b =
        port_leg(side: :starboard, heading_mean: 210.0, awa_mean_signed: 150.0, awa_abs_mean: 150.0)

      assert {state, [{:gybe_pair, pair}]} = pair_up(a, b)
      assert pair.starboard == b
      assert pair.port == a
      assert state.pending == nil
    end
  end

  # ==================================================================
  # End-to-end over synthetic streams
  # ==================================================================

  describe "detection over synthetic streams" do
    test "the scripted 3-leg beat yields one tack pair, third leg left as candidate" do
      {state, leg_events, pair_events} = detect(StreamGen.generate(beat_script()))

      assert length(legs(leg_events)) == 3
      assert [pair] = tacks(pair_events)
      assert gybes(pair_events) == []

      assert pair.starboard.side == :starboard
      assert pair.port.side == :port
      assert pair.starboard.started_ms < pair.port.started_ms
      assert pair.gap_s > 0.0 and pair.gap_s <= 60.0

      # Greedy consumption: leg 3 is unpaired, waiting for a 4th.
      assert %Leg{side: :starboard} = state.pending
      assert state.pending.started_ms > pair.port.started_ms
    end

    test "a four-leg beat pairs greedily in time order" do
      truth = %{stw: 3.0, twd: 0.0, tws: 6.0}

      script =
        beat_script() ++
          [
            {:turn, 30, Map.merge(truth, %{from: 320.0, to: 40.0})},
            {:steady, 90, Map.put(truth, :heading, 40.0)}
          ]

      {state, leg_events, pair_events} = detect(StreamGen.generate(script))

      assert length(legs(leg_events)) == 4
      assert [p1, p2] = tacks(pair_events)
      assert p1.starboard.started_ms < p1.port.started_ms
      assert p1.port.started_ms < p2.starboard.started_ms
      assert p2.starboard.started_ms < p2.port.started_ms
      assert state.pending == nil
    end

    test "a slow 3-minute meandering turn produces no tack pair" do
      truth = %{stw: 3.0, twd: 0.0, tws: 6.0}

      script = [
        {:steady, 90, Map.put(truth, :heading, 320.0)},
        {:turn, 180, Map.merge(truth, %{from: 320.0, to: 40.0, wiggle: {6.0, 20.0}})},
        {:steady, 90, Map.put(truth, :heading, 40.0)}
      ]

      {_state, leg_events, pair_events} = detect(StreamGen.generate(script))

      # The steady endpoints still form legs...
      assert length(legs(leg_events)) >= 2
      # ...but the transition is far too long to be a tack.
      assert tacks(pair_events) == []
      assert gybes(pair_events) == []
    end

    test "a 3 kn TWS jump across the pair rejects it" do
      script = [
        {:steady, 90, %{heading: 320.0, stw: 3.0, twd: 0.0, tws: 5.0}},
        {:turn, 30, %{from: 320.0, to: 40.0, stw: 3.0, twd: 0.0, tws: 5.0}},
        # 3 kn = 1.543 m/s jump.
        {:steady, 90, %{heading: 40.0, stw: 3.0, twd: 0.0, tws: 6.543}}
      ]

      {_state, leg_events, pair_events} = detect(StreamGen.generate(script))

      assert length(legs(leg_events)) == 2
      assert tacks(pair_events) == []
    end

    test "broad-reach legs flipping sides form a gybe pair, not a tack pair" do
      truth = %{stw: 3.0, twd: 0.0, tws: 6.0}

      # TWA -150 -> +150 (AWA ~ -126 -> +126 at TWS 6 / STW 3).
      script = [
        {:steady, 90, Map.put(truth, :heading, 150.0)},
        {:turn, 20, Map.merge(truth, %{from: 150.0, to: 210.0})},
        {:steady, 90, Map.put(truth, :heading, 210.0)}
      ]

      {_state, leg_events, pair_events} = detect(StreamGen.generate(script))

      assert length(legs(leg_events)) == 2
      assert tacks(pair_events) == []
      assert [pair] = gybes(pair_events)
      assert pair.starboard.side == :starboard
      assert pair.port.side == :port
      assert pair.port.started_ms < pair.starboard.started_ms
    end
  end

  describe "runtime snapshot/restore" do
    test "round-trips the pending leg with monotonic timestamps rebased to the restore clock" do
      {state, []} = Tack.step(Tack.new(), stbd_leg())
      assert {:ok, snapshot} = Tack.snapshot(state, 80_000)
      assert Map.keys(snapshot) |> Enum.sort() == [:config, :pending]
      refute Map.has_key?(snapshot.pending, :duration_s)
      refute Map.has_key?(snapshot.pending, :side)

      assert Map.keys(Map.from_struct(state)) |> Enum.sort() ==
               Map.keys(snapshot.config) |> Kernel.++([:pending]) |> Enum.sort()

      assert {:ok, restored} = Tack.restore(snapshot, 1_080_000)
      assert {:ok, ^snapshot} = Tack.snapshot(restored, 1_080_000)
    end

    test "rejects generic metadata and future timestamp ages fail closed" do
      {state, []} = Tack.step(Tack.new(), stbd_leg())
      assert {:ok, snapshot} = Tack.snapshot(state, 80_000)

      assert {:error, :invalid_tack_snapshot} =
               snapshot
               |> Map.put(:metadata, %{token: "must-not-restore"})
               |> Tack.restore(90_000)

      invalid_age = put_in(snapshot, [:pending, :ended_age_ms], -1)
      assert {:error, :invalid_tack_snapshot} = Tack.restore(invalid_age, 90_000)

      forged_duration =
        snapshot
        |> put_in([:pending, :started_age_ms], snapshot.pending.ended_age_ms + 1_000)
        |> put_in([:pending, :duration_s], 120.0)

      assert {:error, :invalid_tack_snapshot} = Tack.restore(forged_duration, 90_000)
      assert {:ok, ^snapshot} = Tack.snapshot(state, 80_000)
    end
  end
end
