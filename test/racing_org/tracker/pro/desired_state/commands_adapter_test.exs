defmodule RacingOrg.Tracker.Pro.DesiredState.CommandsAdapterTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.Commands.Store, as: AssignmentStore
  alias RacingOrg.Tracker.Pro.Polar.Lookup
  alias RacingOrg.Tracker.Pro.Polar.Store, as: PolarStore
  alias RacingOrg.Tracker.Protobuf.DeviceCommand

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "desired_state_commands_#{System.unique_integer([:positive])}"
      )

    assignment_dir = Path.join(base, "assignment")
    polar_dir = Path.join(base, "polar")

    pid =
      start_supervised!({Commands, name: nil, device_id: "device-1", store_dir: assignment_dir, polar_dir: polar_dir})

    on_exit(fn -> File.rm_rf(base) end)

    %{commands: pid, assignment_dir: assignment_dir, polar_dir: polar_dir}
  end

  test "validates and force-installs complete assignment desired state", ctx do
    assignment = assignment_projection(2)

    assert {:ok, normalized} = Commands.validate_assignment(assignment)
    assert normalized.assignment_id == "assignment-1"
    assert normalized.version == 2
    assert normalized.desired_state == assignment

    Commands.subscribe(ctx.commands, self())
    assert {:ok, installed} = Commands.reconcile_assignment(ctx.commands, assignment)
    assert installed == Commands.current_assignment(ctx.commands)
    assert installed.race_assignment.race_session_id == "session-1"
    assert installed.active_mark_code == "B"
    assert installed.desired_state["route"]["route_request_id"] == "route-1"
    assert {:ok, ^installed} = AssignmentStore.load(ctx.assignment_dir)

    assert_receive {:racing_org_command, %DeviceCommand{payload: {:race_assignment, _}}}
  end

  test "assignment validation rejects malformed nested backend projection fields" do
    projection = assignment_projection(2)

    invalid = [
      Map.put(projection, "schema_version", 2),
      Map.put(projection, "device_id", nil),
      Map.put(projection, "official_start_at", "not-a-time"),
      Map.put(projection, "course_marks", ["not-a-mark"]),
      put_in(projection["active_next_mark"]["position"], -1),
      put_in(projection["route"]["route_points"], [%{"latitude" => "north", "longitude" => -70.9}])
    ]

    Enum.each(invalid, fn content ->
      assert {:error, _reason} = Commands.validate_assignment(content)
    end)
  end

  test "assignment tombstone durably removes assignment authority", ctx do
    assert {:ok, _} = Commands.reconcile_assignment(ctx.commands, assignment_projection(2))
    Commands.subscribe(ctx.commands, self())

    assert :ok = Commands.clear_assignment(ctx.commands)
    assert Commands.current_assignment(ctx.commands) == nil
    assert AssignmentStore.load(ctx.assignment_dir) == :empty
    assert_receive {:racing_org_command, %DeviceCommand{payload: {:cancel_assignment, _}}}
  end

  test "validates, installs, rebuilds, and clears the reference polar without touching assignment", ctx do
    assignment = assignment_projection(2)
    assert {:ok, installed_assignment} = Commands.reconcile_assignment(ctx.commands, assignment)
    Commands.subscribe(ctx.commands, self())

    polar = polar_projection(3)
    assert {:ok, normalized} = Commands.validate_polar(polar)
    assert normalized.version == 3

    assert {:ok, installed_polar} = Commands.reconcile_polar(ctx.commands, polar)
    assert installed_polar == Commands.current_polar(ctx.commands)
    assert Commands.current_assignment(ctx.commands) == installed_assignment
    assert {:ok, ^installed_polar} = PolarStore.load(ctx.polar_dir)
    assert %Lookup{} = Commands.current_polar_lookup(ctx.commands)
    assert_receive {:racing_org_command, %DeviceCommand{payload: {:polar_table, _}}}

    assert :ok = Commands.clear_polar(ctx.commands)
    assert Commands.current_polar(ctx.commands) == nil
    assert Commands.current_polar_lookup(ctx.commands) == nil
    assert Commands.current_assignment(ctx.commands) == installed_assignment
    assert PolarStore.load(ctx.polar_dir) == :empty
  end

  test "polar validation rejects unusable or out-of-domain backend projections" do
    polar = polar_projection(3)

    invalid = [
      Map.put(polar, "schema_version", 2),
      Map.put(polar, "command_type", "other"),
      Map.put(polar, "rows", []),
      put_in(polar["rows"], [
        %{"tws_mps" => -1.0, "cells" => [%{"twa_deg" => 45.0, "boat_speed_mps" => 3.0}]}
      ]),
      put_in(polar["rows"], [
        %{"tws_mps" => 5.0, "cells" => [%{"twa_deg" => 181.0, "boat_speed_mps" => 3.0}]}
      ])
    ]

    Enum.each(invalid, fn content ->
      assert {:error, _reason} = Commands.validate_polar(content)
    end)
  end

  test "persistence failures do not mutate command-owned desired state", %{commands: commands} do
    state = :sys.get_state(commands)
    File.mkdir_p!(state.store_dir)
    blocker = Path.join(state.store_dir, "current.assignment")
    File.mkdir_p!(blocker)

    assert {:error, _reason} = Commands.reconcile_assignment(commands, assignment_projection(1))
    assert Commands.current_assignment(commands) == nil
  end

  defp assignment_projection(version) do
    %{
      "schema_version" => 1,
      "assignment_id" => "assignment-1",
      "assignment_version" => version,
      "boat_id" => "boat-1",
      "device_id" => "device-1",
      "race_id" => "race-1",
      "race_session_id" => "session-1",
      "official_start_at" => "2026-08-07T13:00:00Z",
      "expected_duration_seconds" => 7_200,
      "start_line" => %{},
      "finish" => %{},
      "course_marks" => [],
      "shortened_course" => %{},
      "active_next_mark" => %{"code" => "B", "position" => 2},
      "sampling_rules" => %{},
      "route_geometry_hash" => "route-hash",
      "route" => %{
        "route_request_id" => "route-1",
        "route_points" => [
          %{"latitude" => 42.1, "longitude" => -70.9},
          %{"latitude" => 42.2, "longitude" => -70.8}
        ]
      }
    }
  end

  defp polar_projection(version) do
    %{
      "schema_version" => 1,
      "command_type" => "polar_table",
      "polar_id" => "polar-1",
      "version" => version,
      "rows" => [
        %{
          "tws_mps" => 5.0,
          "cells" => [
            %{"twa_deg" => 45.0, "boat_speed_mps" => 3.0},
            %{"twa_deg" => 90.0, "boat_speed_mps" => 4.0}
          ]
        }
      ],
      "optima" => []
    }
  end
end
