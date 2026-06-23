defmodule RacingOrg.Tracker.Pro.Nav.DeviationMonitorTest do
  @moduledoc """
  The tracker side of the deviation→recalc loop (P3): every 10 s, while RACING, the
  monitor compares the already-computed cross-track error against the
  server-pushed threshold and — exactly once per excursion — asks the
  `ChannelClient` for a route recalc with the boat's current position. Below the
  threshold it never asks; a new route/assignment (or a cooldown) re-arms it.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.Nav.DeviationMonitor
  alias RacingOrg.Tracker.Protobuf.CourseMark
  alias RacingOrg.Tracker.Protobuf.DeviceCommand
  alias RacingOrg.Tracker.Protobuf.LatLon
  alias RacingOrg.Tracker.Protobuf.RaceAssignment
  alias RacingOrg.Tracker.Protobuf.ServerReply

  # A two-mark leg running due-north up the -70.0 meridian. The origin is mark "1";
  # the active (destination) mark is "2". A position EAST of the meridian has a large
  # positive cross-track; a position essentially ON the meridian has ~0.
  @origin {42.00, -70.00}
  @dest {42.10, -70.00}
  # ~0 m off track (a hair north of the origin, on the meridian).
  @on_track {42.05, -70.00000}
  # Far east of the meridian at this latitude (~hundreds of m of cross-track).
  @far_off {42.05, -69.99000}

  # --- fakes -------------------------------------------------------------------------

  # Records request_route_recalc/2 calls to the test process. Mirrors the
  # ChannelClient.request_route_recalc/2 signature the monitor calls.
  defmodule FakeChannel do
    def request_route_recalc(agent, position) do
      send(Agent.get(agent, & &1), {:recalc, position})
      :ok
    end
  end

  # A phase source mirroring RacingOrg.Tracker.Pro.Sampling.current_phase/1.
  defmodule FakePhase do
    def start(phase), do: Agent.start_link(fn -> phase end)
    def set(agent, phase), do: Agent.update(agent, fn _ -> phase end)
    def current_phase(agent), do: Agent.get(agent, & &1)
  end

  # A tracking-config source mirroring RacingOrg.Tracker.Pro.Tracking.Config.deviation_threshold/1.
  defmodule FakeThreshold do
    def start(meters), do: Agent.start_link(fn -> meters end)
    def set(agent, meters), do: Agent.update(agent, fn _ -> meters end)
    def deviation_threshold(agent), do: Agent.get(agent, & &1)
  end

  # A monotonic-ms clock the test advances explicitly (freshness + cooldown).
  defp clock_at(ref), do: fn -> :atomics.get(ref, 1) end

  defp set_clock(ref, ms), do: :atomics.put(ref, 1, ms)

  defp marks do
    [
      struct(CourseMark, code: "1", sequence: 1, position: struct(LatLon, latitude: elem(@origin, 0), longitude: elem(@origin, 1))),
      struct(CourseMark, code: "2", sequence: 2, position: struct(LatLon, latitude: elem(@dest, 0), longitude: elem(@dest, 1)))
    ]
  end

  # Each call establishes a DISTINCT assignment (a fresh assignment_id) so a second
  # assignment is never rejected as a stale version of the first.
  defp assign_course(commands, active_code \\ "2") do
    race = struct(RaceAssignment, course_marks: marks(), active_mark_code: active_code)
    n = System.unique_integer([:positive])

    command =
      struct(DeviceCommand,
        command_id: "c-#{n}",
        assignment_id: "a-#{n}",
        assignment_version: 1,
        payload: {:race_assignment, race}
      )

    reply = struct(ServerReply, protocol_version: 1, device_id: "", command: command) |> ServerReply.encode()
    :applied = Commands.apply_reply(commands, reply)
  end

  # Start the monitor with all collaborators injected + a manual tick. `opts`:
  #   :phase (default :racing), :threshold (default 50.0), :position (default @far_off),
  #   :clock_ms (initial monotonic ms, default 100_000), :cooldown_ms, :freshness_ms.
  defp start_monitor(opts) do
    test_pid = self()
    {:ok, recalc_agent} = Agent.start_link(fn -> test_pid end)
    {:ok, commands} = start_supervised({Commands, device_id: "dev"}, id: {Commands, System.unique_integer([:positive])})
    {:ok, phase} = FakePhase.start(Keyword.get(opts, :phase, :racing))
    {:ok, threshold} = FakeThreshold.start(Keyword.get(opts, :threshold, 50.0))

    clock_ref = :atomics.new(1, [])
    set_clock(clock_ref, Keyword.get(opts, :clock_ms, 100_000))

    monitor =
      start_supervised!(
        {DeviationMonitor,
         [
           name: nil,
           commands: commands,
           tracking_config: {FakeThreshold, threshold},
           phase_source: {FakePhase, phase},
           channel: {FakeChannel, recalc_agent},
           now_ms_fn: clock_at(clock_ref),
           # Manual cadence: a huge interval so only check_now/1 drives the check.
           check_interval_ms: Keyword.get(opts, :check_interval_ms, 3_600_000),
           position_freshness_ms: Keyword.get(opts, :freshness_ms, 30_000),
           cooldown_ms: Keyword.get(opts, :cooldown_ms, 120_000)
         ]},
        id: {DeviationMonitor, System.unique_integer([:positive])}
      )

    # Seed an initial fresh position unless suppressed.
    unless Keyword.get(opts, :no_position, false) do
      send(monitor, {:nav_position, Keyword.get(opts, :position, @far_off)})
    end

    %{
      monitor: monitor,
      commands: commands,
      phase: phase,
      threshold: threshold,
      clock_ref: clock_ref
    }
  end

  describe "fires a recalc when racing + deviated beyond the threshold" do
    test "a deviation > threshold while racing requests exactly ONE recalc with the current position" do
      %{monitor: m, commands: c} = start_monitor(position: @far_off, threshold: 50.0)
      assign_course(c)

      assert :requested = DeviationMonitor.check_now(m)
      assert_receive {:recalc, {42.05, -69.99}}

      # A second check WITHOUT a new route is suppressed (no constant recalc).
      assert :suppressed = DeviationMonitor.check_now(m)
      refute_receive {:recalc, _}, 50
    end

    test "uses the latest position fix at the time of the deviation" do
      %{monitor: m, commands: c} = start_monitor(position: @far_off)
      assign_course(c)
      # Move further east just before the check; the recalc must carry THAT fix.
      send(m, {:nav_position, {42.05, -69.98}})

      assert :requested = DeviationMonitor.check_now(m)
      assert_receive {:recalc, {42.05, -69.98}}
    end
  end

  describe "does not fire below the threshold" do
    test "an on-track position never requests a recalc" do
      %{monitor: m, commands: c} = start_monitor(position: @on_track, threshold: 50.0)
      assign_course(c)

      assert :within = DeviationMonitor.check_now(m)
      refute_receive {:recalc, _}, 50
    end

    test "a deviation just under the threshold does not request" do
      # Make the threshold huge so the (real) far-off cross-track is under it.
      %{monitor: m, commands: c} = start_monitor(position: @far_off, threshold: 100_000.0)
      assign_course(c)

      assert :within = DeviationMonitor.check_now(m)
      refute_receive {:recalc, _}, 50
    end
  end

  describe "phase gate — never fires outside racing/rounding" do
    for phase <- [:idle, :pre_start, :finish, :complete] do
      test "never requests a recalc while #{phase} (even far off track)" do
        %{monitor: m, commands: c} = start_monitor(phase: unquote(phase), position: @far_off)
        assign_course(c)

        assert :not_racing = DeviationMonitor.check_now(m)
        refute_receive {:recalc, _}, 50
      end
    end

    test "fires during :rounding (an active leg still exists)" do
      %{monitor: m, commands: c} = start_monitor(phase: :rounding, position: @far_off)
      assign_course(c)

      assert :requested = DeviationMonitor.check_now(m)
      assert_receive {:recalc, _}
    end
  end

  describe "active-leg gate" do
    test "the first mark (no origin -> nil cross-track) never fires" do
      # active mark "1" has no origin, so Nav.State.cross_track_m is nil: not a real
      # active leg, so the monitor must not request.
      %{monitor: m, commands: c} = start_monitor(position: @far_off)
      assign_course(c, "1")

      assert :no_active_leg = DeviationMonitor.check_now(m)
      refute_receive {:recalc, _}, 50
    end

    test "no assignment never fires" do
      %{monitor: m} = start_monitor(position: @far_off)
      assert :no_active_leg = DeviationMonitor.check_now(m)
      refute_receive {:recalc, _}, 50
    end
  end

  describe "position freshness" do
    test "a stale position fix does not request (don't recalc off an old fix)" do
      %{monitor: m, commands: c, clock_ref: ref} =
        start_monitor(position: @far_off, freshness_ms: 30_000, clock_ms: 100_000)

      assign_course(c)
      # Advance the clock far past the freshness window since the seeded fix.
      set_clock(ref, 100_000 + 60_000)

      assert :stale_position = DeviationMonitor.check_now(m)
      refute_receive {:recalc, _}, 50
    end

    test "no position at all never fires" do
      %{monitor: m, commands: c} = start_monitor(no_position: true)
      assign_course(c)
      assert :stale_position = DeviationMonitor.check_now(m)
      refute_receive {:recalc, _}, 50
    end
  end

  describe "cooldown + reset (no deadlock, no spam)" do
    test "a NEW assignment re-arms the monitor (the recalc landed)" do
      %{monitor: m, commands: c} = start_monitor(position: @far_off)
      assign_course(c)

      assert :requested = DeviationMonitor.check_now(m)
      assert_receive {:recalc, _}
      assert :suppressed = DeviationMonitor.check_now(m)

      # A new route/assignment arrives -> suppression resets -> still deviated -> fires again.
      assign_course(c)
      assert eventually(fn -> DeviationMonitor.armed?(m) end)
      assert :requested = DeviationMonitor.check_now(m)
      assert_receive {:recalc, _}
    end

    test "the cooldown re-arms even if no new route ever arrives (no deadlock)" do
      %{monitor: m, commands: c, clock_ref: ref} =
        start_monitor(position: @far_off, cooldown_ms: 120_000, clock_ms: 100_000, freshness_ms: 1_000_000)

      assign_course(c)

      assert :requested = DeviationMonitor.check_now(m)
      assert_receive {:recalc, _}
      assert :suppressed = DeviationMonitor.check_now(m)

      # Advance past the cooldown; the monitor re-arms and requests again (the route
      # never arrived, so the boat must eventually re-ask).
      set_clock(ref, 100_000 + 120_001)
      assert :requested = DeviationMonitor.check_now(m)
      assert_receive {:recalc, _}
    end
  end

  describe "threshold mid-race change" do
    test "a tighter threshold pushed mid-race takes effect on the next check" do
      %{monitor: m, commands: c, threshold: th} = start_monitor(position: @far_off, threshold: 100_000.0)
      assign_course(c)

      # Under the huge threshold: no recalc.
      assert :within = DeviationMonitor.check_now(m)
      refute_receive {:recalc, _}, 50

      # Server tightens the threshold; the next check reads the new value and fires.
      FakeThreshold.set(th, 50.0)
      assert :requested = DeviationMonitor.check_now(m)
      assert_receive {:recalc, _}
    end
  end

  describe "robustness" do
    test "a crashing channel push never takes down the monitor" do
      test_pid = self()
      {:ok, commands} = start_supervised({Commands, device_id: "dev"}, id: {Commands, System.unique_integer([:positive])})
      {:ok, phase} = FakePhase.start(:racing)
      {:ok, threshold} = FakeThreshold.start(50.0)

      crashing = fn _pos -> raise "boom" end

      monitor =
        start_supervised!(
          {DeviationMonitor,
           [
             name: nil,
             commands: commands,
             tracking_config: {FakeThreshold, threshold},
             phase_source: {FakePhase, phase},
             # A bare fn channel that raises: the monitor must isolate it.
             channel: crashing,
             check_interval_ms: 3_600_000
           ]},
          id: {DeviationMonitor, System.unique_integer([:positive])}
        )

      send(monitor, {:nav_position, @far_off})
      assign_course(commands)

      # The check still returns and the process survives the raising push.
      DeviationMonitor.check_now(monitor)
      assert Process.alive?(monitor)
      _ = test_pid
    end

    test "the periodic tick drives the check on its own cadence" do
      %{commands: c} = start_monitor(position: @far_off, check_interval_ms: 20)
      assign_course(c)
      # No manual check_now: the 20 ms tick should fire the recalc on its own.
      assert_receive {:recalc, _}, 500
    end
  end

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() -> true
      retries <= 0 -> false
      true ->
        Process.sleep(5)
        eventually(fun, retries - 1)
    end
  end
end
