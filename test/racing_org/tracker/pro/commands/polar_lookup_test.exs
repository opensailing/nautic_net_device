defmodule RacingOrg.Tracker.Pro.Commands.PolarLookupTest do
  @moduledoc """
  The compiled `Polar.Lookup` is built ONCE when a polar is applied (off the hot
  path) and cached in `Commands` state, exposed via `current_polar_lookup/1`. The
  compute engine reads this cached `t` rather than rebuilding it per tick.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.Polar.Lookup
  alias RacingOrg.Tracker.Protobuf.DeviceCommand
  alias RacingOrg.Tracker.Protobuf.PolarCell
  alias RacingOrg.Tracker.Protobuf.PolarOptimum
  alias RacingOrg.Tracker.Protobuf.PolarRow
  alias RacingOrg.Tracker.Protobuf.PolarTable
  alias RacingOrg.Tracker.Protobuf.ServerReply

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_polar_lk_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp polar_reply(opts) do
    table =
      struct(PolarTable,
        polar_id: Keyword.get(opts, :polar_id, "boat-1"),
        version: Keyword.get(opts, :version, 1),
        rows:
          Keyword.get(opts, :rows, [
            struct(PolarRow,
              tws_mps: 10.0,
              cells: [
                struct(PolarCell, twa_deg: 45.0, boat_speed_mps: 5.0),
                struct(PolarCell, twa_deg: 90.0, boat_speed_mps: 7.0),
                struct(PolarCell, twa_deg: 135.0, boat_speed_mps: 6.0)
              ]
            )
          ]),
        optima:
          Keyword.get(opts, :optima, [
            struct(PolarOptimum, tws_mps: 10.0, beat_twa: 42.0, beat_vmg: 4.0, run_twa: 150.0, run_vmg: 5.0)
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

  defp start(dir), do: start_supervised!({Commands, device_id: "dev", polar_dir: dir})

  test "no polar applied -> current_polar_lookup is nil", %{dir: dir} do
    c = start(dir)
    assert Commands.current_polar_lookup(c) == nil
  end

  test "applying a polar caches a compiled Lookup.t exposed via current_polar_lookup", %{dir: dir} do
    c = start(dir)
    assert :applied = Commands.apply_reply(c, polar_reply(version: 1))

    lookup = Commands.current_polar_lookup(c)
    assert %Lookup{} = lookup

    # The cached lookup evaluates the surface — boat_speed at a node returns it.
    assert {:ok, bsp} = Lookup.boat_speed(lookup, 90.0, 10.0)
    assert_in_delta bsp, 7.0, 1.0e-3
  end

  test "the SAME cached struct is returned across reads (built once, not per read)", %{dir: dir} do
    c = start(dir)
    assert :applied = Commands.apply_reply(c, polar_reply(version: 1))

    a = Commands.current_polar_lookup(c)
    b = Commands.current_polar_lookup(c)
    # Equal across reads — the lookup is cached in state (build/1 is deterministic but
    # NOT pure-fast, so a per-read rebuild would be the only alternative; the engine's
    # build-once proof lives in the engine test). Term-identity can't be asserted here
    # because GenServer replies are deep-copied across the process boundary.
    assert a == b
  end

  test "applying a NEW polar version rebuilds + replaces the cached lookup", %{dir: dir} do
    c = start(dir)
    assert :applied = Commands.apply_reply(c, polar_reply(command_id: "p1", version: 1))
    first = Commands.current_polar_lookup(c)
    assert {:ok, 7.0} = Lookup.boat_speed(first, 90.0, 10.0)

    # New version with a different surface (boat_speed at 90 becomes 9.0).
    rows = [
      struct(PolarRow,
        tws_mps: 10.0,
        cells: [
          struct(PolarCell, twa_deg: 45.0, boat_speed_mps: 6.0),
          struct(PolarCell, twa_deg: 90.0, boat_speed_mps: 9.0),
          struct(PolarCell, twa_deg: 135.0, boat_speed_mps: 7.0)
        ]
      )
    ]

    assert :applied = Commands.apply_reply(c, polar_reply(command_id: "p2", version: 2, rows: rows))
    second = Commands.current_polar_lookup(c)

    refute first == second
    assert {:ok, bsp} = Lookup.boat_speed(second, 90.0, 10.0)
    assert_in_delta bsp, 9.0, 1.0e-3
  end

  test "a polar whose grid won't compile leaves the lookup nil but still stores the polar", %{dir: dir} do
    c = start(dir)
    # No cells AND no optima -> only the (0,0) anchor remains (< 2 nodes), so
    # Lookup.build/1 returns {:error, _} and the lookup stays nil.
    rows = [struct(PolarRow, tws_mps: 10.0, cells: [])]
    assert :applied = Commands.apply_reply(c, polar_reply(version: 1, rows: rows, optima: []))

    assert Commands.current_polar_lookup(c) == nil
    # The raw polar is still applied/exposed (build failure must not drop the polar).
    assert Commands.current_polar(c).version == 1
  end

  test "a cached lookup is rebuilt from the persisted polar on boot", %{dir: dir} do
    c1 = start(dir)
    assert :applied = Commands.apply_reply(c1, polar_reply(version: 3))
    assert %Lookup{} = Commands.current_polar_lookup(c1)
    :ok = stop_supervised(RacingOrg.Tracker.Pro.Commands)

    c2 = start(dir)
    lookup = Commands.current_polar_lookup(c2)
    assert %Lookup{} = lookup
    assert {:ok, bsp} = Lookup.boat_speed(lookup, 90.0, 10.0)
    assert_in_delta bsp, 7.0, 1.0e-3
  end
end
