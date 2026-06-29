defmodule RacingOrg.Tracker.Pro.Nav.StateTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands.Assignment
  alias RacingOrg.Tracker.Pro.Nav.Geo
  alias RacingOrg.Tracker.Pro.Nav.State
  alias RacingOrg.Tracker.Protobuf.CourseMark
  alias RacingOrg.Tracker.Protobuf.LatLon
  alias RacingOrg.Tracker.Protobuf.RaceAssignment

  describe "Geo" do
    test "distance is ~111 km per degree of latitude" do
      assert_in_delta Geo.distance_m({0.0, 0.0}, {1.0, 0.0}), 111_195, 200
    end

    test "bearing is 0 due north and ~pi/2 due east" do
      assert_in_delta Geo.bearing_rad({0.0, 0.0}, {1.0, 0.0}), 0.0, 0.001
      assert_in_delta Geo.bearing_rad({0.0, 0.0}, {0.0, 1.0}), :math.pi() / 2, 0.001
    end

    test "cross-track is negative (left of track) for a point north of an eastward leg" do
      xte = Geo.cross_track_m({0.0, 0.0}, {0.0, 1.0}, {0.001, 0.5})
      assert xte < 0
      assert_in_delta abs(xte), 111, 10
    end
  end

  describe "State.derive/2" do
    defp marks do
      [
        struct(CourseMark, code: "1", sequence: 1, position: struct(LatLon, latitude: 42.0, longitude: -70.0)),
        struct(CourseMark, code: "2", sequence: 2, position: struct(LatLon, latitude: 42.1, longitude: -70.0)),
        struct(CourseMark, code: "3", sequence: 3, position: struct(LatLon, latitude: 42.2, longitude: -70.0))
      ]
    end

    defp assignment(active_code) do
      %Assignment{
        active_mark_code: active_code,
        race_assignment: struct(RaceAssignment, course_marks: marks(), active_mark_code: active_code)
      }
    end

    test "no assignment is inactive" do
      refute State.derive(nil, {42.0, -70.0}).active?
    end

    test "derives the active leg, destination, bearing, range, and XTE" do
      state = State.derive(assignment("2"), {42.05, -70.001})

      assert state.active?
      assert state.destination_mark_code == "2"
      assert state.destination == {42.1, -70.0}
      assert state.destination_wp_number == 2
      assert state.origin_mark_code == "1"
      assert state.origin == {42.0, -70.0}
      assert state.origin_wp_number == 1
      assert state.total_waypoints == 3
      assert is_number(state.distance_to_dest_m) and state.distance_to_dest_m > 0
      assert is_number(state.bearing_position_to_dest_rad)
      assert is_number(state.cross_track_m)
    end

    test "the first mark has no origin (no active leg yet)" do
      state = State.derive(assignment("1"), {42.0, -70.0})
      assert state.active?
      assert state.origin == nil
      assert state.bearing_origin_to_dest_rad == nil
      assert state.cross_track_m == nil
    end

    test "an unknown active mark code is inactive" do
      refute State.derive(assignment("nope"), {42.0, -70.0}).active?
    end

    test "without a position, bearing/range/XTE are unset but the leg is known" do
      state = State.derive(assignment("2"), nil)
      assert state.active?
      assert state.destination == {42.1, -70.0}
      assert state.distance_to_dest_m == nil
      assert state.bearing_position_to_dest_rad == nil
      # origin->dest bearing does not need a position
      assert is_number(state.bearing_origin_to_dest_rad)
    end

    # --- next leg (active mark -> the FOLLOWING mark in sequence) ---

    test "derives the next mark and the great-circle bearing from active to next" do
      state = State.derive(assignment("2"), {42.05, -70.001})

      assert state.next_destination_mark_code == "3"
      assert state.next_destination == {42.2, -70.0}
      # Mark "3" (42.2,-70.0) is due NORTH of mark "2" (42.1,-70.0) -> bearing ~0.
      assert_in_delta state.bearing_dest_to_next_rad, 0.0, 0.001
      # It is the same value the Geo helper produces for active->next (reused helper).
      assert state.bearing_dest_to_next_rad == Geo.bearing_rad({42.1, -70.0}, {42.2, -70.0})
    end

    test "next-leg bearing does not need a position (geometry is mark-to-mark)" do
      state = State.derive(assignment("2"), nil)
      assert state.next_destination_mark_code == "3"
      assert is_number(state.bearing_dest_to_next_rad)
    end

    test "the last mark in sequence has no next leg" do
      state = State.derive(assignment("3"), {42.2, -70.0})
      assert state.active?
      assert state.next_destination == nil
      assert state.next_destination_mark_code == nil
      assert state.bearing_dest_to_next_rad == nil
    end
  end
end
