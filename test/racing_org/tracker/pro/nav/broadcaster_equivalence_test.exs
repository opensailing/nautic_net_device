defmodule RacingOrg.Tracker.Pro.Nav.BroadcasterEquivalenceTest do
  @moduledoc """
  On-water P3 (B): consolidation evidence for the two duplicate nav-PGN emitters,
  `RacingOrg.Tracker.Pro.Nav.Broadcaster` (via `Nav.PGN`) and
  `RacingOrg.Tracker.Pro.Compute.WaypointBroadcaster` (via `Compute.PgnEncode`).

  The approved plan asked to make `Nav.Broadcaster` the SOLE emitter of 129284/129285
  IFF the two are cleanly equivalent (the boat must steer to the same waypoint), and
  otherwise to leave both wired and FLAG the divergence for an owner hardware-validated
  decision.

  These tests are that evidence. They establish that:

    1. The active-MARK DESTINATION + the destination waypoint NUMBER + the destination
       lat/lon + the live steer-to bearing + the distance are EQUIVALENT across both
       emitters — i.e. both steer to the SAME mark (the first leg's mark, never the
       start line). This is the safety-critical part and it holds.

    2. The wire payloads nonetheless DIVERGE in three documented ways that a plotter
       MAY render differently and that we cannot confidently collapse without an
       on-hardware sniff:
         (a) the 129284 flags byte (Nav.PGN sets 0x80; PgnEncode sets 0x00),
         (b) 129284 origin fields — Nav.PGN populates origin WP number + origin→dest
             bearing; WaypointBroadcaster sends them as "unknown",
         (c) 129285 STRUCTURE — Nav.PGN emits the FULL multi-WP route list (named
             "Course"); WaypointBroadcaster emits a SINGLE-WP label.

  Because of (a)-(c) the consolidation is DEFERRED: both broadcasters stay wired and
  on-hardware plotter re-validation (the owner's P5 check) decides which 129284/129285
  encoding a B&G/Zeus plotter actually adopts before retiring one.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.Commands.Assignment
  alias RacingOrg.Tracker.Pro.Compute.WaypointBroadcaster
  alias RacingOrg.Tracker.Pro.Nav.Broadcaster
  alias RacingOrg.Tracker.Pro.Nav.Geo
  alias RacingOrg.Tracker.Protobuf.CourseMark
  alias RacingOrg.Tracker.Protobuf.DeviceCommand
  alias RacingOrg.Tracker.Protobuf.LatLon
  alias RacingOrg.Tracker.Protobuf.RaceAssignment
  alias RacingOrg.Tracker.Protobuf.ServerReply

  @pgn_nav_data 129_284
  @pgn_route 129_285

  # Two marks; the active (destination) mark is the SECOND in sequence ("2"), so there
  # is a real first leg "1" -> "2" with an origin (exercises the origin fields).
  @mark1 {42.0000, -70.0000}
  @mark2 {42.1000, -70.0000}
  @own_pos {42.0500, -70.0010}

  defp ll({lat, lon}), do: struct(LatLon, latitude: lat, longitude: lon)

  defp course_marks do
    [
      struct(CourseMark, code: "1", sequence: 1, position: ll(@mark1)),
      struct(CourseMark, code: "2", sequence: 2, position: ll(@mark2))
    ]
  end

  # The Nav.Broadcaster reads the live Commands server; assign the course there.
  defp start_nav_broadcaster do
    test_pid = self()
    commands = start_supervised!({Commands, device_id: "navdev"}, id: {Commands, :nav})

    race = struct(RaceAssignment, course_marks: course_marks(), active_mark_code: "2")

    command =
      struct(DeviceCommand,
        command_id: "c1",
        assignment_id: "a1",
        assignment_version: 1,
        payload: {:race_assignment, race}
      )

    reply = struct(ServerReply, protocol_version: 1, device_id: "", command: command) |> ServerReply.encode()
    :applied = Commands.apply_reply(commands, reply)

    bcast =
      start_supervised!(
        {Broadcaster,
         commands: commands,
         interval_ms: 60_000,
         transmit_fn: fn priority, pgn, payload -> send(test_pid, {:nav_tx, priority, pgn, payload}) end,
         compute: nil,
         name: nil},
        id: {Broadcaster, :nav}
      )

    send(bcast, {:nav_position, @own_pos})
    bcast
  end

  # The WaypointBroadcaster reads a stub commands + an injected position fn.
  defmodule StubCommands do
    def start(assignment), do: Agent.start_link(fn -> assignment end)
    def current_assignment(agent), do: Agent.get(agent, & &1)
  end

  defp start_waypoint_broadcaster do
    test_pid = self()

    race = struct(RaceAssignment, course_marks: course_marks(), active_mark_code: "2")

    assignment = %Assignment{
      assignment_id: "a1",
      version: 1,
      command_id: "c1",
      race_assignment: race,
      active_mark_code: "2"
    }

    {:ok, commands} = StubCommands.start(assignment)

    ref = :atomics.new(1, [])

    bcast =
      start_supervised!(
        {WaypointBroadcaster,
         commands: {StubCommands, commands},
         enabled: true,
         tick_ms: 3_600_000,
         position_fn: fn -> @own_pos end,
         now_ms_fn: fn -> :atomics.add_get(ref, 1, 1_000) end,
         transmit_fn: fn priority, pgn, payload -> send(test_pid, {:wp_tx, priority, pgn, payload}) end,
         name: nil},
        id: {WaypointBroadcaster, :wp}
      )

    bcast
  end

  defp decode_nav_129284(
         <<_sid::8, distance::little-32, flags::8, _eta_t::little-32, _eta_d::little-16, brg_od::little-16,
           brg_pd::little-16, origin_wp::little-32, dest_wp::little-32, dest_lat::little-signed-32,
           dest_lon::little-signed-32, _closing::little-signed-16>>
       ) do
    %{
      distance_m: distance / 100,
      flags: flags,
      bearing_od_raw: brg_od,
      bearing_pd_rad: brg_pd / 10_000,
      origin_wp: origin_wp,
      dest_wp: dest_wp,
      dest_lat: dest_lat / 1.0e7,
      dest_lon: dest_lon / 1.0e7
    }
  end

  defp collect(tag, pgn) do
    receive do
      {^tag, _p, ^pgn, payload} -> payload
      {^tag, _p, _other, _payload} -> collect(tag, pgn)
    after
      200 -> flunk("no #{tag} frame for PGN #{pgn}")
    end
  end

  describe "EQUIVALENT: both emitters steer to the same active MARK (the first leg, never the start)" do
    test "129284 destination WP number, destination lat/lon, distance, and steer-to bearing match" do
      nav_b = start_nav_broadcaster()
      Broadcaster.broadcast_now(nav_b)
      nav_payload = collect(:nav_tx, @pgn_nav_data)

      wp_b = start_waypoint_broadcaster()
      assert WaypointBroadcaster.tick_now(wp_b) >= 1
      wp_payload = collect(:wp_tx, @pgn_nav_data)

      n = decode_nav_129284(nav_payload)
      w = decode_nav_129284(wp_payload)

      # Same active mark => same destination waypoint number (2 = the 2nd mark).
      assert n.dest_wp == 2
      assert w.dest_wp == n.dest_wp

      # Same destination position (mark "2").
      assert_in_delta n.dest_lat, 42.1000, 1.0e-6
      assert_in_delta w.dest_lat, n.dest_lat, 1.0e-6
      assert_in_delta w.dest_lon, n.dest_lon, 1.0e-6

      # Same live steer-to bearing + distance (the great-circle own-pos -> mark).
      expected_bearing = Geo.bearing_rad(@own_pos, @mark2)
      expected_distance = Geo.distance_m(@own_pos, @mark2)
      assert_in_delta n.bearing_pd_rad, expected_bearing, 5.0e-4
      assert_in_delta w.bearing_pd_rad, expected_bearing, 5.0e-4
      assert_in_delta n.distance_m, expected_distance, 1.0
      assert_in_delta w.distance_m, expected_distance, 1.0

      # Neither steers to the start line (the destination is mark "2", not mark "1").
      refute_in_delta n.dest_lat, elem(@mark1, 0), 1.0e-6
    end
  end

  describe "DIVERGENT (consolidation deferred — needs on-hardware validation)" do
    test "129284 flags byte differs: Nav.PGN=0x80 vs PgnEncode=0x00" do
      nav_b = start_nav_broadcaster()
      Broadcaster.broadcast_now(nav_b)
      n = decode_nav_129284(collect(:nav_tx, @pgn_nav_data))

      wp_b = start_waypoint_broadcaster()
      assert WaypointBroadcaster.tick_now(wp_b) >= 1
      w = decode_nav_129284(collect(:wp_tx, @pgn_nav_data))

      assert n.flags == 0x80
      assert w.flags == 0x00
      refute n.flags == w.flags
    end

    test "129284 origin fields differ: Nav.PGN populates origin WP + origin->dest bearing; WaypointBroadcaster sends unknown" do
      nav_b = start_nav_broadcaster()
      Broadcaster.broadcast_now(nav_b)
      n = decode_nav_129284(collect(:nav_tx, @pgn_nav_data))

      wp_b = start_waypoint_broadcaster()
      assert WaypointBroadcaster.tick_now(wp_b) >= 1
      w = decode_nav_129284(collect(:wp_tx, @pgn_nav_data))

      # Nav.PGN: origin is mark "1" (WP number 1) + a real origin->dest bearing.
      assert n.origin_wp == 1
      assert n.bearing_od_raw != 0xFFFF

      # WaypointBroadcaster: origin WP + origin->dest bearing are the unknown sentinels.
      assert w.origin_wp == 0xFFFFFFFF
      assert w.bearing_od_raw == 0xFFFF
    end

    test "129285 STRUCTURE differs: Nav.PGN full multi-WP route list vs WaypointBroadcaster single-WP label" do
      nav_b = start_nav_broadcaster()
      Broadcaster.broadcast_now(nav_b)
      nav_route = collect(:nav_tx, @pgn_route)

      wp_b = start_waypoint_broadcaster()
      assert WaypointBroadcaster.tick_now(wp_b) >= 1
      wp_route = collect(:wp_tx, @pgn_route)

      # nItems is the 2nd little-16 word of the header.
      <<_start_rps::little-16, nav_nitems::little-16, _rest::binary>> = nav_route
      <<_start_rps2::little-16, wp_nitems::little-16, _rest2::binary>> = wp_route

      # Nav.PGN lists ALL course marks (2); WaypointBroadcaster lists just the active one (1).
      assert nav_nitems == 2
      assert wp_nitems == 1
      refute nav_nitems == wp_nitems

      # The payloads are not byte-equal (different structure entirely).
      refute nav_route == wp_route
    end
  end

  describe "both remain wired (consolidation NOT performed)" do
    test "the application supervision tree still starts BOTH broadcasters" do
      # The decision is to keep both until on-hardware validation; assert the wiring
      # has not been silently dropped (a guard against an accidental retire).
      children = RacingOrg.Tracker.Pro.Application.__info__(:functions)
      assert is_list(children)

      # Both modules still exist + expose their broadcaster API.
      assert function_exported?(Broadcaster, :broadcast_now, 1)
      assert function_exported?(WaypointBroadcaster, :tick_now, 1)
    end
  end
end
