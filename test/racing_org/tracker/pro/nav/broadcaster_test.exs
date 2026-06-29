defmodule RacingOrg.Tracker.Pro.Nav.BroadcasterTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.Nav.Broadcaster
  alias RacingOrg.Tracker.Protobuf.CourseMark
  alias RacingOrg.Tracker.Protobuf.DeviceCommand
  alias RacingOrg.Tracker.Protobuf.LatLon
  alias RacingOrg.Tracker.Protobuf.RaceAssignment
  alias RacingOrg.Tracker.Protobuf.ServerReply

  defp start_broadcaster do
    test_pid = self()
    commands = start_supervised!({Commands, device_id: "dev"})

    broadcaster =
      start_supervised!(
        {Broadcaster,
         commands: commands,
         interval_ms: 60_000,
         transmit_fn: fn priority, pgn, payload -> send(test_pid, {:tx, priority, pgn, payload}) end,
         name: nil}
      )

    %{commands: commands, broadcaster: broadcaster}
  end

  defp assign_course(commands, active_code \\ "2") do
    marks = [
      struct(CourseMark, code: "1", sequence: 1, position: struct(LatLon, latitude: 42.0, longitude: -70.0)),
      struct(CourseMark, code: "2", sequence: 2, position: struct(LatLon, latitude: 42.1, longitude: -70.0)),
      struct(CourseMark, code: "3", sequence: 3, position: struct(LatLon, latitude: 42.1, longitude: -69.9))
    ]

    race = struct(RaceAssignment, course_marks: marks, active_mark_code: active_code, route_hash: "rh")

    command =
      struct(DeviceCommand,
        command_id: "c1",
        assignment_id: "a1",
        assignment_version: 1,
        payload: {:race_assignment, race}
      )

    reply = struct(ServerReply, protocol_version: 1, device_id: "", command: command) |> ServerReply.encode()
    :applied = Commands.apply_reply(commands, reply)
  end

  test "broadcasts nav-data, XTE, and route PGNs while navigating" do
    %{commands: c, broadcaster: b} = start_broadcaster()
    assign_course(c)
    send(b, {:nav_position, {42.05, -70.001}})

    assert {%{active?: true}, 3} = Broadcaster.broadcast_now(b)

    assert_receive {:tx, 3, 129_284, nav_data}
    assert byte_size(nav_data) == 34
    assert_receive {:tx, 3, 129_283, _xte}
    assert_receive {:tx, 6, 129_285, _route}
  end

  test "broadcasts nothing when there is no active waypoint" do
    %{broadcaster: b} = start_broadcaster()
    assert {%{active?: false}, 0} = Broadcaster.broadcast_now(b)
    refute_receive {:tx, _, _, _}, 50
  end

  test "never transmits an autopilot heading/track-control PGN" do
    %{commands: c, broadcaster: b} = start_broadcaster()
    assign_course(c)
    send(b, {:nav_position, {42.05, -70.0}})
    Broadcaster.broadcast_now(b)

    pgns =
      for _ <- 1..3,
          do:
            (receive do
               {:tx, _p, pgn, _} -> pgn
             after
               50 -> nil
             end)

    refute 127_237 in pgns
    assert Enum.sort(pgns) == [129_283, 129_284, 129_285]
  end

  # The Nav.Broadcaster is the natural source of `bearing_to_mark`: it already derives
  # the active-mark geometry (bearing from current position to the active mark). On
  # each broadcast it pushes that bearing (in DEGREES) into the compute engine so
  # `vmc` can compute. This stub compute module records the pushed signal.
  defmodule StubCompute do
    def put_signal(agent, name, value, _mono_ms) do
      Agent.update(agent, fn acc -> [{name, value} | acc] end)
    end

    def pushed(agent), do: Agent.get(agent, & &1)
  end

  defp start_broadcaster_with_compute(compute_agent) do
    test_pid = self()
    commands = start_supervised!({Commands, device_id: "dev2"})

    broadcaster =
      start_supervised!(
        {Broadcaster,
         commands: commands,
         interval_ms: 60_000,
         transmit_fn: fn priority, pgn, payload -> send(test_pid, {:tx, priority, pgn, payload}) end,
         compute: {StubCompute, compute_agent},
         name: nil}
      )

    %{commands: commands, broadcaster: broadcaster}
  end

  test "pushes bearing_to_mark (degrees) into the compute engine while navigating" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    %{commands: c, broadcaster: b} = start_broadcaster_with_compute(agent)
    assign_course(c)
    # Position due south of mark "2" (42.1, -70.0); bearing to it is ~0 deg (north).
    send(b, {:nav_position, {42.05, -70.0}})

    Broadcaster.broadcast_now(b)

    pushed = StubCompute.pushed(agent)
    assert {"bearing_to_mark", bearing} = List.keyfind(pushed, "bearing_to_mark", 0)
    assert is_number(bearing)
    # Mark is due north -> bearing ~ 0 deg (allow a small great-circle tolerance).
    assert bearing < 1.0 or bearing > 359.0
  end

  test "does not push bearing_to_mark when there is no active waypoint" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    %{broadcaster: b} = start_broadcaster_with_compute(agent)
    Broadcaster.broadcast_now(b)
    refute List.keyfind(StubCompute.pushed(agent), "bearing_to_mark", 0)
  end

  # The Nav.Broadcaster is also the natural source of `next_leg_bearing`: the SAME
  # mark-to-mark geometry it derives includes the bearing from the active mark to the
  # FOLLOWING mark in sequence. It pushes that (in DEGREES) into the compute engine so
  # the next-leg apparent-wind calcs can compute. No position is needed (it is a
  # mark-to-mark bearing), refreshed only on each broadcast / assignment change.
  test "pushes next_leg_bearing (degrees) into the compute engine while navigating" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    %{commands: c, broadcaster: b} = start_broadcaster_with_compute(agent)
    # Active mark "2" (42.1,-70.0); next mark "3" (42.1,-69.9) is due EAST -> bearing ~90.
    assign_course(c, "2")
    send(b, {:nav_position, {42.05, -70.0}})

    Broadcaster.broadcast_now(b)

    pushed = StubCompute.pushed(agent)
    assert {"next_leg_bearing", bearing} = List.keyfind(pushed, "next_leg_bearing", 0)
    assert is_number(bearing)
    assert_in_delta bearing, 90.0, 0.1
  end

  test "next_leg_bearing is pushed even with no position (mark-to-mark geometry)" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    %{commands: c, broadcaster: b} = start_broadcaster_with_compute(agent)
    assign_course(c, "2")

    Broadcaster.broadcast_now(b)

    assert {"next_leg_bearing", _} = List.keyfind(StubCompute.pushed(agent), "next_leg_bearing", 0)
  end

  test "does not push next_leg_bearing when the active mark is the LAST in sequence" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    %{commands: c, broadcaster: b} = start_broadcaster_with_compute(agent)
    assign_course(c, "3")
    send(b, {:nav_position, {42.05, -70.0}})

    Broadcaster.broadcast_now(b)

    refute List.keyfind(StubCompute.pushed(agent), "next_leg_bearing", 0)
  end

  test "does not push next_leg_bearing when there is no active waypoint" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    %{broadcaster: b} = start_broadcaster_with_compute(agent)
    Broadcaster.broadcast_now(b)
    refute List.keyfind(StubCompute.pushed(agent), "next_leg_bearing", 0)
  end
end
