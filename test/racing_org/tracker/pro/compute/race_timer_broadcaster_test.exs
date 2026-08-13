defmodule RacingOrg.Tracker.Pro.Compute.RaceTimerBroadcasterTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands.Assignment
  alias RacingOrg.Tracker.Pro.Compute.RaceTimerBroadcaster
  alias RacingOrg.Tracker.Protobuf.RaceAssignment
  alias RacingOrg.Tracker.Protobuf.SamplingRules

  # PGN 130824 Key 117 "Race Timer", value u32 LE MILLISECONDS, prefixed by the
  # 2-byte B&G/Marine manufacturer header. Decode the timer ms back out of a payload.
  @bandg_header <<0x7D, 0x99>>

  defp decode_timer(@bandg_header <> <<0x75, 0x40, ms::little-32>>), do: ms

  @gun ~U[2026-06-03 12:00:00Z]

  defp ts(%DateTime{} = dt), do: RacingOrg.Tracker.Protobuf.to_proto_timestamp(dt)

  # An assignment with a gun time `start` and a start-sequence length `sw` seconds.
  # `sw` maps to sampling_rules.start_window_seconds (the existing start-window concept).
  defp assignment(opts) do
    rules =
      if Keyword.get(opts, :rules, true) do
        struct(SamplingRules, start_window_seconds: Keyword.get(opts, :sw, 300))
      end

    race =
      struct(RaceAssignment,
        official_start_time: opts[:start] && ts(opts[:start]),
        sampling_rules: rules
      )

    %Assignment{
      assignment_id: "a",
      version: 1,
      command_id: "c",
      race_assignment: race,
      cancelled: Keyword.get(opts, :cancelled, false)
    }
  end

  # A commands stub: current_assignment/1 returns whatever was stashed in an Agent.
  defmodule StubCommands do
    def start(assignment), do: Agent.start_link(fn -> assignment end)
    def set(agent, assignment), do: Agent.update(agent, fn _ -> assignment end)
    def current_assignment(agent), do: Agent.get(agent, & &1)
  end

  # Start a broadcaster whose commands source is the stub, with an injected clock
  # (returns a DateTime) and a transmit fn forwarding frames to the test process.
  # `:tick_ms` huge so only manual `tick_now/1` fires. ENABLED by default so the
  # injectable seams exercise the gated path.
  defp start_bcast(assignment, opts \\ []) do
    test_pid = self()
    {:ok, commands} = StubCommands.start(assignment)
    clock = opts[:clock] || fn -> @gun end

    bcast =
      start_supervised!(
        {RaceTimerBroadcaster,
         [
           commands: {StubCommands, commands},
           enabled: Keyword.get(opts, :enabled, true),
           tick_ms: opts[:tick_ms] || 3_600_000,
           now_fn: clock,
           transmit_fn: fn priority, pgn, payload -> send(test_pid, {:tx, priority, pgn, payload}) end,
           output_fence: Keyword.get(opts, :output_fence, fn -> true end),
           name: nil
         ]},
        id: {RaceTimerBroadcaster, System.unique_integer([:positive])}
      )

    %{commands: commands, bcast: bcast}
  end

  describe "broadcasting the race timer" do
    test "with a gun N seconds out, a tick transmits a 130824 fast-packet whose timer ≈ gun - now" do
      # now = gun - 90s -> 90_000 ms remaining.
      clock = fn -> DateTime.add(@gun, -90, :second) end
      %{bcast: b} = start_bcast(assignment(start: @gun), clock: clock)

      assert 1 == RaceTimerBroadcaster.tick_now(b)
      assert_receive {:tx, priority, 130_824, payload}
      assert priority == 2
      assert_in_delta decode_timer(payload), 90_000, 5
    end

    test "transmits nothing while the operational gate fences output" do
      clock = fn -> DateTime.add(@gun, -90, :second) end

      %{bcast: b} =
        start_bcast(assignment(start: @gun), clock: clock, output_fence: fn -> false end)

      assert 0 == RaceTimerBroadcaster.tick_now(b)
      refute_receive {:tx, _priority, _pgn, _payload}, 50
    end

    test "counts DOWN across successive ticks before the gun" do
      now_ref = :atomics.new(1, [])
      # store seconds-before-gun as a positive int; clock = gun - that.
      :atomics.put(now_ref, 1, 120)
      clock = fn -> DateTime.add(@gun, -:atomics.get(now_ref, 1), :second) end

      %{bcast: b} = start_bcast(assignment(start: @gun), clock: clock)

      RaceTimerBroadcaster.tick_now(b)
      assert_receive {:tx, _p, 130_824, p120}

      :atomics.put(now_ref, 1, 60)
      RaceTimerBroadcaster.tick_now(b)
      assert_receive {:tx, _p, 130_824, p60}

      assert decode_timer(p120) > decode_timer(p60)
      assert_in_delta decode_timer(p120), 120_000, 5
      assert_in_delta decode_timer(p60), 60_000, 5
    end

    test "crosses the gun then counts UP (elapsed) afterward" do
      now_ref = :atomics.new(1, [])
      # signed seconds relative to gun: negative = before, positive = after.
      :atomics.put(now_ref, 1, -10)
      clock = fn -> DateTime.add(@gun, :atomics.get(now_ref, 1), :second) end

      %{bcast: b} = start_bcast(assignment(start: @gun), clock: clock)

      RaceTimerBroadcaster.tick_now(b)
      assert_receive {:tx, _p, 130_824, before}
      assert_in_delta decode_timer(before), 10_000, 5

      # exactly the gun -> ~0
      :atomics.put(now_ref, 1, 0)
      RaceTimerBroadcaster.tick_now(b)
      assert_receive {:tx, _p, 130_824, at}
      assert decode_timer(at) <= 5

      # 30s after the gun -> count up to 30_000 ms elapsed
      :atomics.put(now_ref, 1, 30)
      RaceTimerBroadcaster.tick_now(b)
      assert_receive {:tx, _p, 130_824, after_gun}
      assert_in_delta decode_timer(after_gun), 30_000, 5
    end
  end

  describe "silence when there is no race" do
    test "transmits NOTHING with no assignment" do
      %{bcast: b} = start_bcast(nil)
      assert 0 == RaceTimerBroadcaster.tick_now(b)
      refute_receive {:tx, _, _, _}, 50
    end

    test "transmits NOTHING when the assignment has no gun time" do
      %{bcast: b} = start_bcast(assignment(start: nil))
      assert 0 == RaceTimerBroadcaster.tick_now(b)
      refute_receive {:tx, _, _, _}, 50
    end

    test "transmits NOTHING after cancel_assignment" do
      %{bcast: b, commands: c} = start_bcast(assignment(start: @gun))
      # cancel: the device-side assignment is marked cancelled.
      StubCommands.set(c, assignment(start: @gun, cancelled: true))
      assert 0 == RaceTimerBroadcaster.tick_now(b)
      refute_receive {:tx, _, _, _}, 50
    end

    test "transmits NOTHING when the clock is pre-GPS-sync (unreliable time)" do
      clock = fn -> ~U[1970-01-01 00:00:00Z] end
      %{bcast: b} = start_bcast(assignment(start: @gun), clock: clock)
      assert 0 == RaceTimerBroadcaster.tick_now(b)
      refute_receive {:tx, _, _, _}, 50
    end
  end

  describe "validation gate (config flag)" do
    test "emits NOTHING when disabled, even with a valid in-window assignment" do
      clock = fn -> DateTime.add(@gun, -60, :second) end
      %{bcast: b} = start_bcast(assignment(start: @gun), clock: clock, enabled: false)
      assert 0 == RaceTimerBroadcaster.tick_now(b)
      refute_receive {:tx, _, _, _}, 50
    end
  end

  describe "rate limiting to ~1 Hz" do
    test "a flurry of ticks inside one second transmits about once" do
      now_ms = :atomics.new(1, [])
      :atomics.put(now_ms, 1, 0)
      # advance the clock in 100ms steps over ~1s; the broadcaster should emit ~1/s.
      clock = fn -> DateTime.add(DateTime.add(@gun, -300, :second), :atomics.get(now_ms, 1), :millisecond) end

      %{bcast: b} = start_bcast(assignment(start: @gun), clock: clock)

      sent =
        Enum.reduce(0..9, 0, fn i, acc ->
          :atomics.put(now_ms, 1, i * 100)
          acc + RaceTimerBroadcaster.tick_now(b)
        end)

      # ~1 Hz over <1.0s of ticks -> 1 send (first tick), maybe 2 at the boundary.
      assert sent in 1..2
    end
  end

  describe "in_start_sequence?/2" do
    test "true only within [gun - start_sequence_seconds, gun]" do
      a = assignment(start: @gun, sw: 300)
      # 5 min sequence: 4 min before the gun is IN, 6 min before is OUT.
      assert RaceTimerBroadcaster.in_start_sequence?(a, DateTime.add(@gun, -240, :second))
      assert RaceTimerBroadcaster.in_start_sequence?(a, DateTime.add(@gun, -1, :second))
      assert RaceTimerBroadcaster.in_start_sequence?(a, @gun)
      refute RaceTimerBroadcaster.in_start_sequence?(a, DateTime.add(@gun, -360, :second))
      # after the gun is NOT the start sequence anymore (the race is underway)
      refute RaceTimerBroadcaster.in_start_sequence?(a, DateTime.add(@gun, 1, :second))
    end

    test "false with no assignment / no gun / cancelled" do
      refute RaceTimerBroadcaster.in_start_sequence?(nil, @gun)
      refute RaceTimerBroadcaster.in_start_sequence?(assignment(start: nil), @gun)
      refute RaceTimerBroadcaster.in_start_sequence?(assignment(start: @gun, cancelled: true), @gun)
    end
  end
end
