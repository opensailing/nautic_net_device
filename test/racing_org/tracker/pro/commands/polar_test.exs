defmodule RacingOrg.Tracker.Pro.Commands.PolarTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.Polar
  alias RacingOrg.Tracker.Protobuf.CommandAck
  alias RacingOrg.Tracker.Protobuf.DeviceCommand
  alias RacingOrg.Tracker.Protobuf.PolarCell
  alias RacingOrg.Tracker.Protobuf.PolarOptimum
  alias RacingOrg.Tracker.Protobuf.PolarRow
  alias RacingOrg.Tracker.Protobuf.PolarTable
  alias RacingOrg.Tracker.Protobuf.RaceAssignment
  alias RacingOrg.Tracker.Protobuf.ServerReply

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_polar_cmd_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # A polar command is NOT scoped to an assignment: assignment_id is empty and
  # assignment_version is 0, so assignment-centric staleness/expiry must never
  # apply to it. Idempotency is keyed off the PolarTable.version.
  defp polar_reply(opts) do
    table =
      struct(PolarTable,
        polar_id: Keyword.get(opts, :polar_id, "boat-1"),
        version: Keyword.get(opts, :version, 1),
        # NOTE: PolarTable fields are protobuf `float` (single precision). Use
        # values that are EXACTLY representable in float32 so wire round-tripping
        # (encode -> decode) does not perturb assertions.
        rows:
          Keyword.get(opts, :rows, [
            struct(PolarRow,
              tws_mps: 5.0,
              cells: [struct(PolarCell, twa_deg: 45.0, boat_speed_mps: 4.0)]
            )
          ]),
        optima:
          Keyword.get(opts, :optima, [
            struct(PolarOptimum, tws_mps: 5.0, beat_twa: 42.0, beat_vmg: 3.0, run_twa: 165.0, run_vmg: 5.0)
          ])
      )

    command =
      struct(DeviceCommand,
        command_id: Keyword.get(opts, :command_id, "polar-cmd"),
        assignment_id: "",
        assignment_version: 0,
        payload: {:polar_table, table}
      )

    struct(ServerReply, protocol_version: 1, device_id: "", command: command) |> ServerReply.encode()
  end

  defp assignment_reply(opts) do
    command =
      struct(DeviceCommand,
        command_id: Keyword.get(opts, :command_id, "asg-cmd"),
        assignment_id: Keyword.get(opts, :assignment_id, "asg-1"),
        assignment_version: Keyword.get(opts, :assignment_version, 1),
        payload: {:race_assignment, struct(RaceAssignment, race_session_id: "2026-06-03-1")}
      )

    struct(ServerReply, protocol_version: 1, device_id: "", command: command) |> ServerReply.encode()
  end

  defp start(dir), do: start_supervised!({Commands, device_id: "dev", polar_dir: dir})

  test "applying a polar_table command stores + exposes the polar and ACKs it", %{dir: dir} do
    c = start(dir)
    assert Commands.current_polar(c) == nil

    assert :applied = Commands.apply_reply(c, polar_reply(command_id: "p1", version: 2, polar_id: "boat-1"))

    polar = Commands.current_polar(c)
    assert %Polar{polar_id: "boat-1", version: 2} = polar
    assert [%{tws_mps: 5.0, cells: [%{twa_deg: 45.0, boat_speed_mps: 4.0}]}] = polar.rows
    assert [%{beat_twa: 42.0}] = polar.optima

    # ACKed through the normal command-ack path.
    assert %CommandAck{command_id: "p1"} = Commands.current_ack(c)
  end

  test "ignores an older or equal polar version, applies a newer one", %{dir: dir} do
    c = start(dir)

    assert :applied = Commands.apply_reply(c, polar_reply(command_id: "v2", version: 2))
    assert Commands.current_polar(c).version == 2

    # Equal version is ignored.
    assert {:ignored, :stale_polar_version} = Commands.apply_reply(c, polar_reply(command_id: "v2-again", version: 2))
    assert Commands.current_polar(c).version == 2

    # Older version is ignored.
    assert {:ignored, :stale_polar_version} = Commands.apply_reply(c, polar_reply(command_id: "v1", version: 1))
    assert Commands.current_polar(c).version == 2

    # Newer version is applied.
    assert :applied = Commands.apply_reply(c, polar_reply(command_id: "v3", version: 3))
    assert Commands.current_polar(c).version == 3
  end

  test "a persisted polar survives a restart", %{dir: dir} do
    c1 = start(dir)
    assert :applied = Commands.apply_reply(c1, polar_reply(command_id: "p1", version: 5, polar_id: "boat-7"))
    :ok = stop_supervised(RacingOrg.Tracker.Pro.Commands)

    c2 = start(dir)
    polar = Commands.current_polar(c2)
    assert %Polar{polar_id: "boat-7", version: 5} = polar
    assert [%{tws_mps: 5.0}] = polar.rows

    # A re-sent same/older version is still rejected after reboot (idempotency
    # survives the restart).
    assert {:ignored, :stale_polar_version} =
             Commands.apply_reply(c2, polar_reply(command_id: "p1-again", version: 5))
  end

  test "cancelling/replacing a race assignment does NOT clear the polar", %{dir: dir} do
    c = start(dir)

    assert :applied = Commands.apply_reply(c, polar_reply(command_id: "pol", version: 1))
    assert :applied = Commands.apply_reply(c, assignment_reply(command_id: "a1", assignment_version: 1))

    # Replace the assignment (new version) — polar untouched.
    assert :applied = Commands.apply_reply(c, assignment_reply(command_id: "a2", assignment_version: 2))
    assert Commands.current_polar(c).version == 1

    # Cancel the assignment — polar untouched.
    cancel =
      struct(DeviceCommand,
        command_id: "cancel",
        assignment_id: "asg-1",
        assignment_version: 3,
        payload: {:cancel_assignment, struct(RacingOrg.Tracker.Protobuf.CancelAssignment, reason: "abandoned")}
      )

    cancel_reply = struct(ServerReply, protocol_version: 1, device_id: "", command: cancel) |> ServerReply.encode()
    assert :applied = Commands.apply_reply(c, cancel_reply)

    assert Commands.current_assignment(c).cancelled == true
    assert %Polar{version: 1} = Commands.current_polar(c)
  end

  test "applying a polar does NOT disturb an active assignment", %{dir: dir} do
    c = start(dir)

    assert :applied = Commands.apply_reply(c, assignment_reply(command_id: "a1", assignment_version: 3))
    assignment_before = Commands.current_assignment(c)

    assert :applied = Commands.apply_reply(c, polar_reply(command_id: "pol", version: 1))

    # Assignment unchanged; the polar command did not bump/replace it.
    assert Commands.current_assignment(c) == assignment_before
    assert Commands.current_assignment(c).version == 3
    assert %Polar{version: 1} = Commands.current_polar(c)
  end

  test "without a polar_dir, persistence is disabled and the polar still applies in-memory" do
    c = start_supervised!({Commands, device_id: "dev"})
    assert :applied = Commands.apply_reply(c, polar_reply(command_id: "mem", version: 1))
    assert Commands.current_polar(c).version == 1
  end
end
