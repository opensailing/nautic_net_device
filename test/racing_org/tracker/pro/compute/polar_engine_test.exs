defmodule RacingOrg.Tracker.Pro.Compute.PolarEngineTest do
  @moduledoc """
  Integration: the compute Engine threads the cached polar interpolant into the
  polar-aware library calcs, refreshing its LOCAL cache only when the polar version
  changes — NEVER rebuilding or cross-process-fetching per compute tick.

  Not async: the Engine attaches global :telemetry handlers and we drive real
  :telemetry.execute/3 events.
  """
  use ExUnit.Case

  alias RacingOrg.Tracker.Pro.Compute.Broadcaster
  alias RacingOrg.Tracker.Pro.Compute.Engine
  alias RacingOrg.Tracker.Pro.Polar
  alias RacingOrg.Tracker.Pro.Polar.Lookup

  # A stub "Commands" the Engine reads the polar lookup from. It counts the number of
  # current_polar_lookup/1 calls so we can PROVE the build/fetch is off the hot path.
  defmodule StubCommands do
    use Agent

    def start_link(opts) do
      Agent.start_link(fn -> %{lookup: opts[:lookup], version: opts[:version] || 1, fetches: 0} end,
        name: opts[:name]
      )
    end

    def set(agent, lookup, version) do
      Agent.update(agent, fn s -> %{s | lookup: lookup, version: version} end)
    end

    def current_polar_lookup(agent) do
      Agent.get_and_update(agent, fn s -> {s.lookup, %{s | fetches: s.fetches + 1}} end)
    end

    def current_polar_version(agent), do: Agent.get(agent, & &1.version)
    def fetches(agent), do: Agent.get(agent, & &1.fetches)

    # The Engine subscribes via this; it just records the subscriber so the test can
    # send a polar-change notification.
    def subscribe(agent, pid) do
      Agent.update(agent, fn s -> Map.put(s, :subscriber, pid) end)
      :ok
    end
  end

  @rad_per_deg :math.pi() / 180.0

  defp lookup do
    polar = %Polar{
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

    {:ok, lk} = Lookup.build(polar)
    lk
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
        "output_unit" => "%",
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
    {:ok, cmds} =
      StubCommands.start_link(name: nil, lookup: opts[:lookup], version: opts[:version] || 1)

    base = [
      name: nil,
      store_dir: nil,
      commands: {StubCommands, cmds},
      now_fn: opts[:now_fn] || fn -> 1_000 end
    ]

    pid = start_supervised!({Engine, base}, id: {Engine, System.unique_integer([:positive])})
    %{engine: pid, cmds: cmds}
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() ->
        true

      retries <= 0 ->
        false

      true ->
        Process.sleep(5)
        eventually(fun, retries - 1)
    end
  end

  describe "polar calcs flow through the engine with the cached lookup" do
    test "polar_performance computes from live signals + the cached polar" do
      %{engine: pid, cmds: cmds} = start_engine(lookup: lookup(), version: 1)

      def = library_value("pp", "polar_performance", ["boat_speed", "true_wind_angle", "true_wind_speed"])
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [def]))

      # The engine must pull the lookup once (on apply/subscribe), then compute.
      :telemetry.execute(
        [:racing_org, :speed, :water],
        %{speed_m_s: %{value: 6.3, timestamp: DateTime.utc_now()}},
        %{timestamp_monotonic_ms: 1_000, device_id: <<1::64>>}
      )

      Engine.put_signal(pid, "true_wind_angle", 90.0, 1_000)
      Engine.put_signal(pid, "true_wind_speed", 10.0, 1_000)

      assert eventually(fn ->
               case Engine.current_values(pid) do
                 [%{valid?: true, outputs: %{"polar_performance" => v}}] -> abs(v - 90.0) < 1.0e-2
                 _ -> false
               end
             end)

      # Sanity: the stub WAS consulted (lookup is wired), but not absurdly often.
      assert StubCommands.fetches(cmds) >= 1
    end

    test "target_boat_speed + target_twa pick the right leg from live TWA" do
      %{engine: pid} = start_engine(lookup: lookup(), version: 1)

      defs = [
        library_value("tbs", "target_boat_speed", ["true_wind_angle", "true_wind_speed"]),
        library_value("ttwa", "target_twa", ["true_wind_angle", "true_wind_speed"])
      ]

      assert {:ok, _} = Engine.apply_config(pid, payload(0, defs))

      # Upwind: twa 40 -> beat optimum (twa 45, bsp = 4/cos45).
      Engine.put_signal(pid, "true_wind_angle", 40.0, 1_000)
      Engine.put_signal(pid, "true_wind_speed", 10.0, 1_000)

      assert eventually(fn ->
               vals = Engine.current_values(pid)
               Enum.all?(vals, & &1.valid?) and length(vals) == 2
             end)

      vals = Map.new(Engine.current_values(pid), &{&1.def.id, &1.outputs})
      assert_in_delta vals["tbs"]["target_boat_speed"], 4.0 / :math.cos(45.0 * @rad_per_deg), 1.0e-2
      assert_in_delta vals["ttwa"]["target_twa"], 45.0, 1.0e-2
    end

    test "with no polar the polar calcs are INVALID (never garbage)" do
      %{engine: pid} = start_engine(lookup: nil, version: 0)

      def = library_value("pp", "polar_performance", ["boat_speed", "true_wind_angle", "true_wind_speed"])
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [def]))

      Engine.put_signal(pid, "boat_speed", 6.0, 1_000)
      Engine.put_signal(pid, "true_wind_angle", 90.0, 1_000)
      Engine.put_signal(pid, "true_wind_speed", 10.0, 1_000)
      Process.sleep(30)

      assert [%{valid?: false}] = Engine.current_values(pid)
    end
  end

  describe "stream-up: polar calcs reach the SAME backend stream path as true_wind" do
    test "an enabled polar calc (stream_to_backend, broadcast disabled) is streamed" do
      %{engine: pid} = start_engine(lookup: lookup(), version: 1)

      # Phase 2: stream up only — broadcast disabled (bus encoding is Phase 3).
      def =
        library_value("pp", "polar_performance", ["boat_speed", "true_wind_angle", "true_wind_speed"], %{
          "broadcast_enabled" => false,
          "stream_to_backend" => true,
          "output_field" => "polar_performance"
        })

      assert {:ok, _} = Engine.apply_config(pid, payload(0, [def]))

      Engine.put_signal(pid, "boat_speed", 6.3, 1_000)
      Engine.put_signal(pid, "true_wind_angle", 90.0, 1_000)
      Engine.put_signal(pid, "true_wind_speed", 10.0, 1_000)

      assert eventually(fn -> match?([%{valid?: true}], Engine.current_values(pid)) end)

      test_pid = self()

      bcast =
        start_supervised!(
          {Broadcaster,
           engine: {Engine, pid},
           tick_ms: 3_600_000,
           now_fn: fn -> 0 end,
           transmit_fn: fn _p, _pgn, _payload -> :ok end,
           stream_fn: fn streamed -> send(test_pid, {:stream, streamed}) end,
           name: nil},
          id: {Broadcaster, System.unique_integer([:positive])}
        )

      # Bus broadcast is disabled, so the tick transmits 0 to the bus...
      assert 0 == Broadcaster.tick_now(bcast)
      # ...but the value is streamed to the backend via the SAME stream path.
      assert_receive {:stream, streamed}
      assert [%{id: "pp", value: value}] = streamed
      assert_in_delta value, 90.0, 1.0e-2
    end
  end

  describe "next-leg apparent wind flows through the engine (next_leg_bearing injected as a signal)" do
    test "next_leg_aws/awa compute from injected next_leg_bearing + live wind + polar" do
      %{engine: pid} = start_engine(lookup: lookup(), version: 1)

      defs = [
        library_value("nlaws", "next_leg_aws", ["true_wind_direction", "true_wind_speed", "next_leg_bearing"]),
        library_value("nlawa", "next_leg_awa", ["true_wind_direction", "true_wind_speed", "next_leg_bearing"])
      ]

      assert {:ok, _} = Engine.apply_config(pid, payload(0, defs))

      # Live wind: TWS 10, wind FROM the east (90). next_leg_bearing 0 (north) -> twa 90.
      Engine.put_signal(pid, "true_wind_direction", 90.0, 1_000)
      Engine.put_signal(pid, "true_wind_speed", 10.0, 1_000)

      # No next_leg_bearing yet -> both INVALID (no next leg known).
      assert eventually(fn -> Enum.all?(Engine.current_values(pid), &(&1.valid? == false)) end)

      # Nav.Broadcaster injects the next-leg bearing as a signal (same path as bearing_to_mark).
      Engine.put_signal(pid, "next_leg_bearing", 0.0, 1_000)

      assert eventually(fn -> Enum.all?(Engine.current_values(pid), & &1.valid?) end)

      vals = Map.new(Engine.current_values(pid), &{&1.def.id, &1.outputs})
      # twa 90, BSP(90,10) = 7.0: AWS = sqrt(149) = 12.2066, AWA = atan2(10,7) = 55.008.
      assert_in_delta vals["nlaws"]["next_leg_aws"], :math.sqrt(149.0), 1.0e-2
      assert_in_delta vals["nlawa"]["next_leg_awa"], :math.atan2(10.0, 7.0) * 180.0 / :math.pi(), 1.0e-2
    end

    test "next-leg geometry refresh is OFF the hot path: a burst of ticks never re-fetches" do
      %{engine: pid, cmds: cmds} = start_engine(lookup: lookup(), version: 1)

      def = library_value("nlaws", "next_leg_aws", ["true_wind_direction", "true_wind_speed", "next_leg_bearing"])
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [def]))

      Engine.put_signal(pid, "true_wind_direction", 90.0, 1_000)
      Engine.put_signal(pid, "true_wind_speed", 10.0, 1_000)
      Engine.put_signal(pid, "next_leg_bearing", 0.0, 1_000)

      assert eventually(fn -> match?([%{valid?: true}], Engine.current_values(pid)) end)

      fetches_before = StubCommands.fetches(cmds)

      # The next-leg bearing arrives as an injected SIGNAL (Nav.Broadcaster pushes it on
      # assignment/active-mark change), so recompute ticks never cross into Commands.
      for _ <- 1..200, do: _ = Engine.current_values(pid)

      assert StubCommands.fetches(cmds) == fetches_before
    end

    test "stream-up: an enabled next-leg calc reaches the SAME backend stream path" do
      %{engine: pid} = start_engine(lookup: lookup(), version: 1)

      def =
        library_value("nlaws", "next_leg_aws", ["true_wind_direction", "true_wind_speed", "next_leg_bearing"], %{
          "broadcast_enabled" => false,
          "stream_to_backend" => true,
          "output_field" => "next_leg_aws"
        })

      assert {:ok, _} = Engine.apply_config(pid, payload(0, [def]))

      Engine.put_signal(pid, "true_wind_direction", 90.0, 1_000)
      Engine.put_signal(pid, "true_wind_speed", 10.0, 1_000)
      Engine.put_signal(pid, "next_leg_bearing", 0.0, 1_000)

      assert eventually(fn -> match?([%{valid?: true}], Engine.current_values(pid)) end)

      test_pid = self()

      bcast =
        start_supervised!(
          {Broadcaster,
           engine: {Engine, pid},
           tick_ms: 3_600_000,
           now_fn: fn -> 0 end,
           transmit_fn: fn _p, _pgn, _payload -> :ok end,
           stream_fn: fn streamed -> send(test_pid, {:stream, streamed}) end,
           name: nil},
          id: {Broadcaster, System.unique_integer([:positive])}
        )

      assert 0 == Broadcaster.tick_now(bcast)
      assert_receive {:stream, streamed}
      assert [%{id: "nlaws", value: value}] = streamed
      assert_in_delta value, :math.sqrt(149.0), 1.0e-2
    end
  end

  describe "HOT-PATH: build-once / no per-tick fetch or rebuild" do
    test "a burst of compute ticks does NOT re-fetch the lookup from Commands" do
      %{engine: pid, cmds: cmds} = start_engine(lookup: lookup(), version: 1)

      def = library_value("pp", "polar_performance", ["boat_speed", "true_wind_angle", "true_wind_speed"])
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [def]))

      Engine.put_signal(pid, "boat_speed", 6.3, 1_000)
      Engine.put_signal(pid, "true_wind_angle", 90.0, 1_000)
      Engine.put_signal(pid, "true_wind_speed", 10.0, 1_000)

      assert eventually(fn -> match?([%{valid?: true}], Engine.current_values(pid)) end)

      fetches_before = StubCommands.fetches(cmds)

      # Hammer the compute path: 200 recompute reads + 200 signal updates (a burst of
      # "ticks"). NONE of these may fetch the lookup from Commands.
      for i <- 1..200 do
        Engine.put_signal(pid, "boat_speed", 6.0 + i / 1000.0, 1_000)
        _ = Engine.current_values(pid)
      end

      assert StubCommands.fetches(cmds) == fetches_before,
             "engine re-fetched the polar lookup on the hot path " <>
               "(#{StubCommands.fetches(cmds) - fetches_before} extra fetches over 200 ticks)"
    end

    test "the cached lookup refreshes ONLY when a polar-version change is notified" do
      lk_v1 = lookup()
      %{engine: pid, cmds: cmds} = start_engine(lookup: lk_v1, version: 1)

      def = library_value("tbs", "target_boat_speed", ["true_wind_angle", "true_wind_speed"])
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [def]))

      Engine.put_signal(pid, "true_wind_angle", 40.0, 1_000)
      Engine.put_signal(pid, "true_wind_speed", 10.0, 1_000)

      assert eventually(fn -> match?([%{valid?: true}], Engine.current_values(pid)) end)
      [%{outputs: out_v1}] = Engine.current_values(pid)
      assert_in_delta out_v1["target_boat_speed"], 4.0 / :math.cos(45.0 * @rad_per_deg), 1.0e-2

      fetches_after_v1 = StubCommands.fetches(cmds)

      # Swap to a NEW polar (different beat optimum) and notify the engine of a polar
      # version change (the standard Commands subscriber notification).
      polar_v2 = %Polar{
        polar_id: "t",
        version: 2,
        rows: [
          %{
            tws_mps: 10.0,
            cells: [
              %{twa_deg: 45.0, boat_speed_mps: 8.0},
              %{twa_deg: 90.0, boat_speed_mps: 9.0},
              %{twa_deg: 150.0, boat_speed_mps: 7.0}
            ]
          }
        ],
        optima: [%{tws_mps: 10.0, beat_twa: 50.0, beat_vmg: 6.0, run_twa: 150.0, run_vmg: 7.0}]
      }

      {:ok, lk_v2} = Lookup.build(polar_v2)
      StubCommands.set(cmds, lk_v2, 2)

      # Deliver the standard polar-table command notification the engine subscribes to.
      send(pid, {:racing_org_command, polar_table_command(2)})

      assert eventually(fn ->
               case Engine.current_values(pid) do
                 [%{valid?: true, outputs: %{"target_boat_speed" => v}}] ->
                   abs(v - 6.0 / :math.cos(50.0 * @rad_per_deg)) < 1.0e-2

                 _ ->
                   false
               end
             end)

      # The refresh consulted Commands exactly once for the version change — not per
      # tick. (One extra fetch beyond the v1 baseline.)
      assert StubCommands.fetches(cmds) == fetches_after_v1 + 1
    end
  end

  defp polar_table_command(version) do
    alias RacingOrg.Tracker.Protobuf.DeviceCommand
    alias RacingOrg.Tracker.Protobuf.PolarTable

    struct(DeviceCommand,
      command_id: "polar-#{version}",
      assignment_id: "",
      assignment_version: 0,
      payload: {:polar_table, struct(PolarTable, polar_id: "t", version: version)}
    )
  end
end
