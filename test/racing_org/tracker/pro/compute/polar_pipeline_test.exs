defmodule RacingOrg.Tracker.Pro.Compute.PolarPipelineTest do
  @moduledoc """
  PRODUCTION-REALISTIC end-to-end acceptance for the polar + next-leg compute chain.

  On a real boat the network true-wind PGN decodes to `true_wind_speed` +
  `true_wind_direction` — NOT `true_wind_angle`. And a boat that publishes only
  APPARENT wind has the device compute true wind on-device via the `:true_wind`
  library calc. Either way, the polar calcs (`polar_performance`, `target_boat_speed`,
  `target_twa`) and the next-leg calcs must compute from realistic raw signals with
  NO manual injection of `true_wind_angle`.

  Two variants are covered:

    (i) NETWORK true wind present (`true_wind_speed` + `true_wind_direction`) — the
        polar calcs resolve TWA from `true_wind_direction − heading` (the same
        resolution `vmg` uses), and next-leg uses `true_wind_direction` directly.

    (ii) APPARENT-ONLY — only apparent wind + boat motion are published. An on-device
         `:true_wind` def computes true wind, whose outputs (`true_wind_speed`,
         `true_wind_angle`, `true_wind_direction`) are fed back into the engine's
         signal map so the polar + next-leg calcs drive off them (a one-tick lag).

  Not async: the Engine attaches global :telemetry handlers and we drive real
  :telemetry.execute/3 events.
  """
  use ExUnit.Case

  alias RacingOrg.Tracker.Pro.Compute.Engine
  alias RacingOrg.Tracker.Pro.Polar
  alias RacingOrg.Tracker.Pro.Polar.Lookup

  @rad_per_deg :math.pi() / 180.0

  # A stub "Commands" the Engine reads the cached polar lookup from.
  defmodule StubCommands do
    use Agent

    def start_link(opts) do
      Agent.start_link(fn -> %{lookup: opts[:lookup], version: opts[:version] || 1} end, name: opts[:name])
    end

    def current_polar_lookup(agent), do: Agent.get(agent, & &1.lookup)
    def current_polar_version(agent), do: Agent.get(agent, & &1.version)

    def subscribe(agent, pid) do
      Agent.update(agent, fn s -> Map.put(s, :subscriber, pid) end)
      :ok
    end
  end

  # A simple single-TWS polar so boat_speed at a grid node returns the node value
  # exactly, making every assertion hand-computable.
  #   At TWS = 10 m/s: boat_speed(90) = 7.0; beat optimum twa=45 vmg=4.0; run twa=150 vmg=5.0.
  defp polar do
    %Polar{
      polar_id: "t",
      version: 1,
      rows: [
        %{
          tws_mps: 10.0,
          cells: [
            %{twa_deg: 45.0, boat_speed_mps: 5.65685},
            %{twa_deg: 90.0, boat_speed_mps: 7.0},
            %{twa_deg: 120.0, boat_speed_mps: 6.5},
            %{twa_deg: 150.0, boat_speed_mps: 5.7735},
            %{twa_deg: 180.0, boat_speed_mps: 4.0}
          ]
        }
      ],
      optima: [%{tws_mps: 10.0, beat_twa: 45.0, beat_vmg: 4.0, run_twa: 150.0, run_vmg: 5.0}]
    }
  end

  defp lookup do
    {:ok, lk} = Lookup.build(polar())
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

  defp start_engine do
    {:ok, cmds} = StubCommands.start_link(name: nil, lookup: lookup(), version: 1)

    pid =
      start_supervised!(
        {Engine, name: nil, store_dir: nil, commands: {StubCommands, cmds}, now_fn: fn -> 1_000 end},
        id: {Engine, System.unique_integer([:positive])}
      )

    %{engine: pid}
  end

  defp emit_apparent(angle_rad, speed_m_s, ts), do: emit_wind(:apparent, angle_rad, speed_m_s, ts)

  defp emit_wind(reference, angle_rad, speed_m_s, ts) do
    :telemetry.execute(
      [:racing_org, :wind, reference],
      %{vector: %{timestamp: DateTime.utc_now(), angle: angle_rad, magnitude: speed_m_s}},
      %{device_id: <<1, 2, 3, 4, 5, 6, 7, 8>>, timestamp_monotonic_ms: ts}
    )
  end

  defp emit_water_speed(m_s, ts) do
    :telemetry.execute(
      [:racing_org, :speed, :water],
      %{speed_m_s: %{timestamp: DateTime.utc_now(), value: m_s}},
      %{device_id: <<1, 2, 3, 4, 5, 6, 7, 8>>, timestamp_monotonic_ms: ts}
    )
  end

  defp emit_heading(rad, ts) do
    :telemetry.execute(
      [:racing_org, :heading],
      %{rad: %{timestamp: DateTime.utc_now(), value: rad}},
      %{device_id: <<1, 2, 3, 4, 5, 6, 7, 8>>, timestamp_monotonic_ms: ts}
    )
  end

  defp emit_attitude(pitch_rad, roll_rad, ts) do
    :telemetry.execute(
      [:racing_org, :attitude],
      %{rad: %{timestamp: DateTime.utc_now(), yaw: 0.0, pitch: pitch_rad, roll: roll_rad}},
      %{device_id: <<1, 2, 3, 4, 5, 6, 7, 8>>, timestamp_monotonic_ms: ts}
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

  # ===================================================================
  # VARIANT (i): NETWORK TRUE WIND present (true_wind_speed + true_wind_direction)
  # ===================================================================

  describe "variant (i): network true wind — polar + next-leg from realistic raw signals" do
    test "polar_performance / target_boat_speed / target_twa / next_leg compute (no put_signal of true_wind_angle)" do
      %{engine: pid} = start_engine()

      defs = [
        # Polar calcs declare true_wind_direction + heading so TWA resolves like vmg does.
        library_value("pp", "polar_performance", [
          "boat_speed",
          "true_wind_direction",
          "true_wind_speed",
          "heading"
        ]),
        library_value("tbs", "target_boat_speed", ["true_wind_direction", "true_wind_speed", "heading"]),
        library_value("ttwa", "target_twa", ["true_wind_direction", "true_wind_speed", "heading"]),
        library_value("nlaws", "next_leg_aws", ["true_wind_direction", "true_wind_speed", "next_leg_bearing"])
      ]

      assert {:ok, _} = Engine.apply_config(pid, payload(0, defs))

      # Realistic raw signals: heading north (0), wind FROM the east (twd 90),
      # TWS 10 -> TWA = wrap(90 - 0) = 90 (beam reach). STW 6.3.
      emit_water_speed(6.3, 1_000)
      emit_heading(0.0, 1_000)
      emit_wind(:theoretical_ground_true, 90.0 * @rad_per_deg, 10.0, 1_000)

      # Next leg bearing 0 (north): next_leg_twa = |wrap(90 - 0)| = 90.
      Engine.put_signal(pid, "next_leg_bearing", 0.0, 1_000)

      assert eventually(fn ->
               v = values(pid)
               Enum.all?(["pp", "tbs", "ttwa", "nlaws"], &(v[&1] && v[&1].valid?))
             end)

      v = values(pid)

      # polar target at twa=90,tws=10 is the grid node 7.0 -> 100*6.3/7.0 = 90%.
      assert_in_delta v["pp"].outputs["polar_performance"], 90.0, 1.0e-2
      # TWA 90 -> downwind boundary is >= 90, so run optimum: bsp = 5/|cos150|, twa=150.
      assert_in_delta v["tbs"].outputs["target_boat_speed"], 5.0 / abs(:math.cos(150.0 * @rad_per_deg)), 1.0e-2
      assert_in_delta v["ttwa"].outputs["target_twa"], 150.0, 1.0e-2
      # next-leg twa 90, BSP(90,10)=7.0: AWS = sqrt(149).
      assert_in_delta v["nlaws"].outputs["next_leg_aws"], :math.sqrt(149.0), 1.0e-2
    end

    test "upwind heading picks the beat optimum from true_wind_direction − heading" do
      %{engine: pid} = start_engine()

      defs = [
        library_value("tbs", "target_boat_speed", ["true_wind_direction", "true_wind_speed", "heading"]),
        library_value("ttwa", "target_twa", ["true_wind_direction", "true_wind_speed", "heading"])
      ]

      assert {:ok, _} = Engine.apply_config(pid, payload(0, defs))

      # heading 0, wind from 040 -> TWA = 40 (upwind, < 90) -> beat optimum.
      emit_heading(0.0, 1_000)
      emit_wind(:theoretical_ground_true, 40.0 * @rad_per_deg, 10.0, 1_000)

      assert eventually(fn ->
               v = values(pid)
               v["tbs"] && v["tbs"].valid? && v["ttwa"] && v["ttwa"].valid?
             end)

      v = values(pid)
      assert_in_delta v["tbs"].outputs["target_boat_speed"], 4.0 / :math.cos(45.0 * @rad_per_deg), 1.0e-2
      assert_in_delta v["ttwa"].outputs["target_twa"], 45.0, 1.0e-2
    end
  end

  # ===================================================================
  # VARIANT (ii): APPARENT-ONLY — on-device :true_wind feeds the polar/next-leg chain
  # ===================================================================

  describe "variant (ii): apparent-only — on-device true_wind feedback drives polar + next-leg" do
    test "an on-device true_wind def feeds true_wind_* signals to the polar + next-leg calcs" do
      %{engine: pid} = start_engine()

      defs = [
        # The on-device true-wind calc: apparent wind + motion -> true_wind_* outputs.
        library_value("tw", "true_wind", [
          "apparent_wind_speed",
          "apparent_wind_angle",
          "boat_speed",
          "heel",
          "pitch",
          "heading"
        ]),
        # The polar/next-leg calcs read the FED-BACK true_wind_* signals (no network PGN).
        library_value("pp", "polar_performance", [
          "boat_speed",
          "true_wind_direction",
          "true_wind_speed",
          "heading"
        ]),
        library_value("tbs", "target_boat_speed", ["true_wind_direction", "true_wind_speed", "heading"]),
        library_value("ttwa", "target_twa", ["true_wind_direction", "true_wind_speed", "heading"]),
        library_value("nlaws", "next_leg_aws", ["true_wind_direction", "true_wind_speed", "next_leg_bearing"])
      ]

      assert {:ok, _} = Engine.apply_config(pid, payload(0, defs))

      # Realistic raw signals. Heading 0; flat water (heel=pitch=0). We want a beam-reach
      # true wind (TWA ~ 90) so the polar node value 7.0 is hit cleanly. With heel 0 the
      # true wind is the flat triangle: choose AWA + AWS + STW so the true wind comes out
      # at TWA ~ 90 and TWS ~ 10.
      #
      # Pick STW = 6.0 m/s, and a true wind of TWA = 90, TWS = 10 (athwartships true wind).
      # Then apparent = true + boat-velocity(forward):
      #   apparent_x = tx + STW = 0 + 6 = 6, apparent_y = ty = 10.
      #   AWS = hypot(6, 10) = 11.6619; AWA = atan2(10, 6) = 59.036 deg.
      aws = :math.sqrt(6.0 * 6.0 + 10.0 * 10.0)
      awa = :math.atan2(10.0, 6.0)

      emit_water_speed(6.0, 1_000)
      emit_heading(0.0, 1_000)
      emit_attitude(0.0, 0.0, 1_000)
      emit_apparent(awa, aws, 1_000)
      Engine.put_signal(pid, "next_leg_bearing", 0.0, 1_000)

      # The on-device true_wind def must compute first, feed back true_wind_* signals,
      # then the polar/next-leg calcs compute (one-tick lag is acceptable). Drive a few
      # more apparent ticks to let the feedback settle.
      for ts <- 1_001..1_010, do: emit_apparent(awa, aws, ts)

      assert eventually(fn ->
               v = values(pid)
               Enum.all?(["tw", "pp", "tbs", "ttwa", "nlaws"], &(v[&1] && v[&1].valid?))
             end)

      v = values(pid)

      # The on-device true wind: TWS ~ 10, TWA ~ 90, direction = heading + twa ~ 90.
      assert_in_delta v["tw"].outputs["true_wind_speed"], 10.0, 1.0e-2
      assert_in_delta abs(v["tw"].outputs["true_wind_angle"]), 90.0, 1.0e-2
      assert_in_delta v["tw"].outputs["true_wind_direction"], 90.0, 1.0e-2

      # Polar performance: STW 6.0 / polar target 7.0 at twa 90 -> ~85.71%.
      assert_in_delta v["pp"].outputs["polar_performance"], 100.0 * 6.0 / 7.0, 1.0e-1
      # TWA 90 -> run optimum.
      assert_in_delta v["tbs"].outputs["target_boat_speed"], 5.0 / abs(:math.cos(150.0 * @rad_per_deg)), 1.0e-1
      assert_in_delta v["ttwa"].outputs["target_twa"], 150.0, 1.0e-1
      # next-leg twa 90, BSP(90,10)=7.0: AWS = sqrt(149).
      assert_in_delta v["nlaws"].outputs["next_leg_aws"], :math.sqrt(149.0), 1.0e-1
    end

    test "feedback does NOT add a per-tick cross-process fetch or rebuild (hot path preserved)" do
      # Re-use the engine + Commands stub: a burst of compute reads must not re-fetch.
      {:ok, cmds} = StubCommands.start_link(name: nil, lookup: lookup(), version: 1)

      defmodule CountingCommands do
        use Agent

        def start_link(opts) do
          Agent.start_link(fn -> %{lookup: opts[:lookup], version: 1, fetches: 0} end, name: opts[:name])
        end

        def current_polar_lookup(a), do: Agent.get_and_update(a, fn s -> {s.lookup, %{s | fetches: s.fetches + 1}} end)
        def current_polar_version(a), do: Agent.get(a, & &1.version)
        def fetches(a), do: Agent.get(a, & &1.fetches)
        def subscribe(_a, _pid), do: :ok
      end

      {:ok, counting} = CountingCommands.start_link(name: nil, lookup: lookup())

      pid =
        start_supervised!(
          {Engine, name: nil, store_dir: nil, commands: {CountingCommands, counting}, now_fn: fn -> 1_000 end},
          id: {Engine, System.unique_integer([:positive])}
        )

      defs = [
        library_value("tw", "true_wind", [
          "apparent_wind_speed",
          "apparent_wind_angle",
          "boat_speed",
          "heel",
          "pitch",
          "heading"
        ]),
        library_value("pp", "polar_performance", [
          "boat_speed",
          "true_wind_direction",
          "true_wind_speed",
          "heading"
        ])
      ]

      assert {:ok, _} = Engine.apply_config(pid, payload(0, defs))

      aws = :math.sqrt(6.0 * 6.0 + 10.0 * 10.0)
      awa = :math.atan2(10.0, 6.0)
      emit_water_speed(6.0, 1_000)
      emit_heading(0.0, 1_000)
      emit_attitude(0.0, 0.0, 1_000)
      for ts <- 1_000..1_010, do: emit_apparent(awa, aws, ts)

      assert eventually(fn -> values(pid)["pp"] && values(pid)["pp"].valid? end)

      fetches_before = CountingCommands.fetches(counting)

      # Hammer the compute + feedback path: 200 apparent updates + 200 reads. NONE may
      # cross into Commands (no per-tick fetch / rebuild).
      for i <- 1..200 do
        emit_apparent(awa, aws, 1_000)
        _ = Engine.current_values(pid)
        if rem(i, 50) == 0, do: Process.sleep(1)
      end

      assert CountingCommands.fetches(counting) == fetches_before,
             "feedback caused #{CountingCommands.fetches(counting) - fetches_before} extra Commands fetches"

      _ = cmds
    end
  end
end
