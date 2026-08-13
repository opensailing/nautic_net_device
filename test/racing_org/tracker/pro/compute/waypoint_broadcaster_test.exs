defmodule RacingOrg.Tracker.Pro.Compute.WaypointBroadcasterTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands.Assignment
  alias RacingOrg.Tracker.Pro.Compute.WaypointBroadcaster
  alias RacingOrg.Tracker.Pro.Nav.Geo
  alias RacingOrg.Tracker.Protobuf.CourseMark
  alias RacingOrg.Tracker.Protobuf.LatLon
  alias RacingOrg.Tracker.Protobuf.RaceAssignment

  @pgn_nav_data 129_284
  @pgn_route 129_285

  # A couple of marks ~a few km apart off Marblehead.
  @mark1 {42.5000, -70.8500}
  @mark2 {42.5400, -70.8000}
  # An own-position south-west of mark 2.
  @own_pos {42.5100, -70.8300}

  defp ll({lat, lon}), do: struct(LatLon, latitude: lat, longitude: lon)

  defp mark(code, seq, pos),
    do: struct(CourseMark, code: code, sequence: seq, position: ll(pos))

  # An assignment whose course_marks carry positions; `active` names the next mark.
  # The Assignment-level `active_mark_code` is what the device reads (overlaid by
  # route/waypoint commands), mirroring the real command flow + RacingOrg.Tracker.Pro.Nav.State.
  defp assignment(opts) do
    marks = Keyword.get(opts, :marks, [mark("1", 1, @mark1), mark("WL", 2, @mark2)])
    active = Keyword.get(opts, :active, "WL")
    race = struct(RaceAssignment, course_marks: marks, active_mark_code: active)

    %Assignment{
      assignment_id: "a",
      version: 1,
      command_id: "c",
      race_assignment: race,
      active_mark_code: active,
      cancelled: Keyword.get(opts, :cancelled, false)
    }
  end

  defmodule StubCommands do
    def start(assignment), do: Agent.start_link(fn -> assignment end)
    def set(agent, assignment), do: Agent.update(agent, fn _ -> assignment end)
    def current_assignment(agent), do: Agent.get(agent, & &1)
  end

  # Start a broadcaster with the stub commands, an injected position fn (returns
  # `{lat, lon}` or nil), and a transmit fn forwarding frames to the test process.
  # ENABLED by default; tick only via manual `tick_now/1`.
  defp start_bcast(assignment, opts \\ []) do
    test_pid = self()
    {:ok, commands} = StubCommands.start(assignment)
    position = Keyword.get(opts, :position, @own_pos)
    # Default monotonic clock advances 1s per read so each manual `tick_now` clears the
    # 1 Hz rate-limit; the rate-limit test injects its own slow-advancing clock.
    clock = opts[:clock] || advancing_clock()

    bcast =
      start_supervised!(
        {WaypointBroadcaster,
         [
           commands: {StubCommands, commands},
           enabled: Keyword.get(opts, :enabled, true),
           tick_ms: opts[:tick_ms] || 3_600_000,
           position_fn: fn -> position end,
           now_ms_fn: clock,
           transmit_fn: fn priority, pgn, payload -> send(test_pid, {:tx, priority, pgn, payload}) end,
           output_fence: Keyword.get(opts, :output_fence, fn -> true end),
           name: nil
         ]},
        id: {WaypointBroadcaster, System.unique_integer([:positive])}
      )

    %{commands: commands, bcast: bcast}
  end

  # A monotonic-ms clock that advances 1000 ms each read.
  defp advancing_clock do
    ref = :atomics.new(1, [])
    fn -> :atomics.add_get(ref, 1, 1_000) end
  end

  # Decode the steer-to bearing (rad) + distance (m) + dest WP number + dest lat/lon
  # out of a 129284 payload.
  defp decode_nav(
         <<_sid::8, distance::little-32, _flags::8, _eta_t::little-32, _eta_d::little-16, _brg_od::little-16,
           brg_pd::little-16, _origin_wp::little-32, dest_wp::little-32, dest_lat::little-signed-32,
           dest_lon::little-signed-32, _closing::little-signed-16>>
       ) do
    %{
      distance_m: distance / 100,
      bearing_pd_rad: brg_pd / 10_000,
      dest_wp: dest_wp,
      dest_lat: dest_lat / 1.0e7,
      dest_lon: dest_lon / 1.0e7
    }
  end

  describe "broadcasting the next waypoint" do
    test "transmits nothing while the operational gate fences output" do
      %{bcast: b} = start_bcast(assignment(active: "WL"), output_fence: fn -> false end)

      assert WaypointBroadcaster.tick_now(b) == 0
      refute_receive {:tx, _priority, _pgn, _payload}, 50
    end

    test "a tick transmits 129284 with distance + steer-to bearing ≈ the great-circle values" do
      %{bcast: b} = start_bcast(assignment(active: "WL"))

      assert WaypointBroadcaster.tick_now(b) >= 1
      assert_receive {:tx, 3, @pgn_nav_data, payload}

      decoded = decode_nav(payload)
      expected_distance = Geo.distance_m(@own_pos, @mark2)
      expected_bearing = Geo.bearing_rad(@own_pos, @mark2)

      assert_in_delta decoded.distance_m, expected_distance, 0.5
      # u16 1e-4 rad resolution -> tolerance ~1e-4 rad
      assert_in_delta decoded.bearing_pd_rad, expected_bearing, 5.0e-4
      # destination lat/lon comes from the active mark's position
      assert_in_delta decoded.dest_lat, 42.5400, 1.0e-6
      assert_in_delta decoded.dest_lon, -70.8000, 1.0e-6
    end

    test "also transmits a 129285 label carrying the mark code + the SAME dest WP id" do
      %{bcast: b} = start_bcast(assignment(active: "WL"))
      assert WaypointBroadcaster.tick_now(b) >= 1

      assert_receive {:tx, 3, @pgn_nav_data, nav_payload}
      assert_receive {:tx, 6, @pgn_route, route_payload}

      %{dest_wp: dest_wp} = decode_nav(nav_payload)

      # 129285: header(8) + dir byte(1) + route-name STRING_LAU(2) + reserved(1) + WP id...
      <<_hdr::binary-8, _dir::8, 2::8, 1::8, _res::8, wp_id::little-16, name_len::8, _enc::8, body::binary>> =
        route_payload

      assert wp_id == dest_wp
      name = binary_part(body, 0, name_len - 2)
      assert name == "WL"
    end

    test "tracks the active mark when it advances (different mark -> different destination)" do
      %{bcast: b, commands: c} = start_bcast(assignment(active: "WL"))
      assert WaypointBroadcaster.tick_now(b) >= 1
      assert_receive {:tx, 3, @pgn_nav_data, p_wl}
      assert_in_delta decode_nav(p_wl).dest_lat, 42.5400, 1.0e-6

      StubCommands.set(c, assignment(active: "1"))
      assert WaypointBroadcaster.tick_now(b) >= 1
      assert_receive {:tx, 3, @pgn_nav_data, p1}
      assert_in_delta decode_nav(p1).dest_lat, 42.5000, 1.0e-6
    end

    test "the destination WP number / WP id is STABLE across ticks for the same mark" do
      %{bcast: b} = start_bcast(assignment(active: "WL"))

      assert WaypointBroadcaster.tick_now(b) >= 1
      assert_receive {:tx, 3, @pgn_nav_data, p1}
      assert WaypointBroadcaster.tick_now(b) >= 1
      assert_receive {:tx, 3, @pgn_nav_data, p2}

      assert decode_nav(p1).dest_wp == decode_nav(p2).dest_wp
    end
  end

  describe "silence rules" do
    test "transmits NOTHING with no assignment" do
      %{bcast: b} = start_bcast(nil)
      assert 0 == WaypointBroadcaster.tick_now(b)
      refute_receive {:tx, _, _, _}, 50
    end

    test "transmits NOTHING when the assignment has no active mark code" do
      %{bcast: b} = start_bcast(assignment(active: ""))
      assert 0 == WaypointBroadcaster.tick_now(b)
      refute_receive {:tx, _, _, _}, 50
    end

    test "transmits NOTHING when the active mark has no position on the device" do
      marks = [mark("1", 1, @mark1), struct(CourseMark, code: "WL", sequence: 2, position: nil)]
      %{bcast: b} = start_bcast(assignment(active: "WL", marks: marks))
      assert 0 == WaypointBroadcaster.tick_now(b)
      refute_receive {:tx, _, _, _}, 50
    end

    test "transmits NOTHING when there is no own-position" do
      %{bcast: b} = start_bcast(assignment(active: "WL"), position: nil)
      assert 0 == WaypointBroadcaster.tick_now(b)
      refute_receive {:tx, _, _, _}, 50
    end

    test "transmits NOTHING after cancel_assignment" do
      %{bcast: b, commands: c} = start_bcast(assignment(active: "WL"))
      StubCommands.set(c, assignment(active: "WL", cancelled: true))
      assert 0 == WaypointBroadcaster.tick_now(b)
      refute_receive {:tx, _, _, _}, 50
    end
  end

  describe "validation gate (config flag)" do
    test "emits NOTHING when disabled, even with a valid assignment + position" do
      %{bcast: b} = start_bcast(assignment(active: "WL"), enabled: false)
      assert 0 == WaypointBroadcaster.tick_now(b)
      refute_receive {:tx, _, _, _}, 50
    end
  end

  describe "rate limiting to ~1 Hz" do
    test "a flurry of ticks inside one second transmits 129284 about once" do
      now_ms = :atomics.new(1, [])
      :atomics.put(now_ms, 1, 0)
      clock = fn -> :atomics.get(now_ms, 1) end

      %{bcast: b} = start_bcast(assignment(active: "WL"), clock: clock)

      nav_frames =
        Enum.reduce(0..9, 0, fn i, acc ->
          :atomics.put(now_ms, 1, i * 100)
          WaypointBroadcaster.tick_now(b)
          acc
        end)

      _ = nav_frames
      # collect the nav-data frames seen
      count = count_nav_frames(0)
      assert count in 1..2
    end
  end

  defp count_nav_frames(acc) do
    receive do
      {:tx, 3, @pgn_nav_data, _} -> count_nav_frames(acc + 1)
      {:tx, _, _, _} -> count_nav_frames(acc)
    after
      0 -> acc
    end
  end
end
