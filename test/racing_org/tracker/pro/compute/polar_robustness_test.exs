defmodule RacingOrg.Tracker.Pro.Compute.PolarRobustnessTest do
  @moduledoc """
  Robustness of the polar + next-leg compute chain under degenerate / boundary
  conditions (Phase 2 gap analysis, GAP 2):

    * empty/degenerate polar -> nil cached lookup -> polar calcs INVALID, and a
      SUBSEQUENT valid polar rebuilds the lookup and the calcs RECOVER;
    * a stale true-wind input drops the polar calc to INVALID (never computed on
      stale data);
    * at the finish / last mark in sequence there is no next-leg bearing, so the
      next-leg calcs are INVALID (not garbage).

  Not async: the Engine attaches global :telemetry handlers and we drive real
  :telemetry.execute/3 events.
  """
  use ExUnit.Case

  alias RacingOrg.Tracker.Pro.Compute.Engine
  alias RacingOrg.Tracker.Pro.Polar
  alias RacingOrg.Tracker.Pro.Polar.Lookup
  alias RacingOrg.Tracker.Protobuf.DeviceCommand
  alias RacingOrg.Tracker.Protobuf.PolarTable

  # A mutable stub "Commands" the Engine reads the cached polar lookup from. It starts
  # with whatever lookup is given and can be swapped + notified (the standard
  # polar-table command path) to model an invalid -> valid recovery.
  defmodule StubCommands do
    use Agent

    def start_link(opts) do
      Agent.start_link(fn -> %{lookup: opts[:lookup], version: opts[:version] || 1} end, name: opts[:name])
    end

    def set(agent, lookup, version), do: Agent.update(agent, fn s -> %{s | lookup: lookup, version: version} end)
    def current_polar_lookup(agent), do: Agent.get(agent, & &1.lookup)
    def current_polar_version(agent), do: Agent.get(agent, & &1.version)
    def subscribe(_agent, _pid), do: :ok
  end

  defp valid_polar do
    %Polar{
      polar_id: "t",
      version: 1,
      rows: [
        %{
          tws_mps: 10.0,
          cells: [
            %{twa_deg: 45.0, boat_speed_mps: 5.65685},
            %{twa_deg: 90.0, boat_speed_mps: 7.0},
            %{twa_deg: 150.0, boat_speed_mps: 5.7735}
          ]
        }
      ],
      optima: [%{tws_mps: 10.0, beat_twa: 45.0, beat_vmg: 4.0, run_twa: 150.0, run_vmg: 5.0}]
    }
  end

  defp valid_lookup do
    {:ok, lk} = Lookup.build(valid_polar())
    lk
  end

  # An empty/degenerate polar: no cells AND no optima -> only the (0,0) anchor remains
  # (< 2 nodes), so Lookup.build/1 returns {:error, _} and the cached lookup is nil.
  # Commands mirrors that with build_lookup/1, returning nil — proven separately in
  # commands/polar_lookup_test.exs; here we assert build failure IS the nil case.
  defp degenerate_lookup do
    polar = %Polar{polar_id: "t", version: 1, rows: [%{tws_mps: 10.0, cells: []}], optima: []}
    assert {:error, _} = Lookup.build(polar)
    nil
  end

  defp library_value(id, key, signals, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => id,
        "definition_type" => "library",
        "library_key" => key,
        "input_bindings" => %{},
        "rpn" => nil,
        "signals" => signals,
        "output_pgn" => nil,
        "output_field" => key,
        "output_reference" => nil,
        "output_unit" => nil,
        "output_instance" => nil,
        "damping_seconds" => 0.0,
        "broadcast_rate_hz" => 2.0,
        "broadcast_enabled" => false,
        "stream_to_backend" => true
      },
      overrides
    )
  end

  defp payload(version, values), do: %{"version" => version, "values" => values}

  defp start_engine(opts) do
    {:ok, cmds} = StubCommands.start_link(name: nil, lookup: opts[:lookup], version: opts[:version] || 1)

    pid =
      start_supervised!(
        {Engine,
         name: nil,
         store_dir: nil,
         commands: {StubCommands, cmds},
         max_age_ms: opts[:max_age_ms] || 5_000,
         now_fn: opts[:now_fn] || fn -> 1_000 end},
        id: {Engine, System.unique_integer([:positive])}
      )

    %{engine: pid, cmds: cmds}
  end

  defp polar_table_command(version) do
    struct(DeviceCommand,
      command_id: "polar-#{version}",
      assignment_id: "",
      assignment_version: 0,
      payload: {:polar_table, struct(PolarTable, polar_id: "t", version: version)}
    )
  end

  defp values(pid), do: Map.new(Engine.current_values(pid), &{&1.def.id, &1})

  defp eventually(_fun, retries) when retries <= 0, do: false

  defp eventually(fun, retries) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, retries - 1)
    end
  end

  defp eventually(fun), do: eventually(fun, 200)

  describe "degenerate polar: INVALID, then a subsequent valid polar recovers" do
    test "Lookup.build failure is the nil-lookup case Commands caches" do
      # Confirms the chain assumption: a build failure -> nil (not a crash).
      assert nil == degenerate_lookup()
    end

    test "a nil cached lookup makes the polar calc INVALID; a later valid polar recovers" do
      # Boot with a degenerate (nil) lookup -> the polar calc must be INVALID.
      %{engine: pid, cmds: cmds} = start_engine(lookup: degenerate_lookup(), version: 1)

      def = library_value("pp", "polar_performance", ["boat_speed", "true_wind_angle", "true_wind_speed"])
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [def]))

      Engine.put_signal(pid, "boat_speed", 6.3, 1_000)
      Engine.put_signal(pid, "true_wind_angle", 90.0, 1_000)
      Engine.put_signal(pid, "true_wind_speed", 10.0, 1_000)

      # All inputs present, but the lookup is nil -> INVALID (never garbage).
      assert eventually(fn -> match?(%{valid?: false}, values(pid)["pp"]) end)

      # A VALID polar arrives: swap the cached lookup + notify the standard polar-table
      # command. The engine refreshes its cache (off the hot path) and the calc recovers.
      StubCommands.set(cmds, valid_lookup(), 2)
      send(pid, {:racing_org_command, polar_table_command(2)})

      assert eventually(fn ->
               case values(pid)["pp"] do
                 %{valid?: true, outputs: %{"polar_performance" => v}} -> abs(v - 90.0) < 1.0e-2
                 _ -> false
               end
             end)
    end
  end

  describe "stale true-wind input drops the polar calc to INVALID" do
    test "a polar calc whose true_wind inputs are older than max_age is INVALID (not stale data)" do
      # max_age 1000ms, clock at 10_000; samples stamped at 1_000 are ~9s old -> stale.
      now_fn = fn -> 10_000 end
      %{engine: pid} = start_engine(lookup: valid_lookup(), version: 1, max_age_ms: 1_000, now_fn: now_fn)

      def = library_value("pp", "polar_performance", ["boat_speed", "true_wind_angle", "true_wind_speed"])
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [def]))

      # boat_speed is fresh, but the true-wind inputs are stale (stamped 1_000, now 10_000).
      Engine.put_signal(pid, "boat_speed", 6.3, 10_000)
      Engine.put_signal(pid, "true_wind_angle", 90.0, 1_000)
      Engine.put_signal(pid, "true_wind_speed", 10.0, 1_000)
      Process.sleep(30)

      assert %{valid?: false} = values(pid)["pp"]
    end

    test "a fresh polar calc goes INVALID once its true-wind inputs age past max_age" do
      {:ok, clock} = Agent.start_link(fn -> 1_000 end)
      now_fn = fn -> Agent.get(clock, & &1) end
      %{engine: pid} = start_engine(lookup: valid_lookup(), version: 1, max_age_ms: 1_000, now_fn: now_fn)

      def = library_value("pp", "polar_performance", ["boat_speed", "true_wind_angle", "true_wind_speed"])
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [def]))

      Engine.put_signal(pid, "boat_speed", 6.3, 1_000)
      Engine.put_signal(pid, "true_wind_angle", 90.0, 1_000)
      Engine.put_signal(pid, "true_wind_speed", 10.0, 1_000)

      assert eventually(fn -> match?(%{valid?: true}, values(pid)["pp"]) end)

      # Advance the clock well past max_age -> the true-wind inputs are now stale.
      Agent.update(clock, fn _ -> 5_000 end)
      assert %{valid?: false} = values(pid)["pp"]
    end
  end

  describe "next-leg at the finish / last mark in sequence (no next mark)" do
    test "with no next_leg_bearing the next-leg calcs are INVALID, not garbage" do
      # At the last mark Nav.Broadcaster injects NO next_leg_bearing (there is no next
      # leg), so the next-leg calcs must be INVALID — never computed off a fabricated
      # bearing.
      %{engine: pid} = start_engine(lookup: valid_lookup(), version: 1)

      defs = [
        library_value("nltwa", "next_leg_twa", ["true_wind_direction", "next_leg_bearing"]),
        library_value("nlaws", "next_leg_aws", ["true_wind_direction", "true_wind_speed", "next_leg_bearing"]),
        library_value("nlawa", "next_leg_awa", ["true_wind_direction", "true_wind_speed", "next_leg_bearing"])
      ]

      assert {:ok, _} = Engine.apply_config(pid, payload(0, defs))

      # Live wind present, but NO next_leg_bearing (finish / last mark).
      Engine.put_signal(pid, "true_wind_direction", 90.0, 1_000)
      Engine.put_signal(pid, "true_wind_speed", 10.0, 1_000)
      Process.sleep(30)

      v = values(pid)
      assert %{valid?: false} = v["nltwa"]
      assert %{valid?: false} = v["nlaws"]
      assert %{valid?: false} = v["nlawa"]
    end

    test "when a next_leg_bearing IS injected (not the last mark) the next-leg calcs recover" do
      # Contrast: an earlier leg (a next mark exists) DOES inject next_leg_bearing, so
      # the calcs become valid — proving the INVALID-at-finish case is the absence of
      # the bearing, not a permanent failure.
      %{engine: pid} = start_engine(lookup: valid_lookup(), version: 1)

      def = library_value("nlaws", "next_leg_aws", ["true_wind_direction", "true_wind_speed", "next_leg_bearing"])
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [def]))

      Engine.put_signal(pid, "true_wind_direction", 90.0, 1_000)
      Engine.put_signal(pid, "true_wind_speed", 10.0, 1_000)
      assert eventually(fn -> match?(%{valid?: false}, values(pid)["nlaws"]) end)

      # Not the last mark: a next-leg bearing is injected -> the calc recovers.
      Engine.put_signal(pid, "next_leg_bearing", 0.0, 1_000)

      assert eventually(fn ->
               case values(pid)["nlaws"] do
                 %{valid?: true, outputs: %{"next_leg_aws" => v}} -> abs(v - :math.sqrt(149.0)) < 1.0e-2
                 _ -> false
               end
             end)
    end
  end
end
