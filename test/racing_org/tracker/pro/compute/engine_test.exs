defmodule RacingOrg.Tracker.Pro.Compute.EngineTest do
  # Not async: the Engine attaches global :telemetry handlers and we drive real
  # :telemetry.execute/3 events to exercise the signal-map update path.
  use ExUnit.Case

  alias RacingOrg.Tracker.Pro.Compute.Engine
  alias RacingOrg.Tracker.Pro.Compute.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_compute_engine_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # --- wire-shape payloads (string keys, as they arrive over Slipstream) ---

  defp expr_value(id, name, rpn, signals, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => name,
        "definition_type" => "expression",
        "library_key" => nil,
        "input_bindings" => %{},
        "rpn" => rpn,
        "signals" => signals,
        "output_pgn" => 128_259,
        "output_field" => "speed_water_referenced",
        "output_reference" => nil,
        "output_unit" => "m/s",
        "output_instance" => nil,
        "damping_seconds" => 0.5,
        "broadcast_rate_hz" => 2.0,
        "broadcast_enabled" => true,
        "stream_to_backend" => true
      },
      overrides
    )
  end

  defp library_value(id, name, key, signals, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => name,
        "definition_type" => "library",
        "library_key" => key,
        "input_bindings" => %{},
        "rpn" => nil,
        "signals" => signals,
        "output_pgn" => 130_306,
        "output_field" => "wind_speed",
        "output_reference" => "true",
        "output_unit" => "m/s",
        "output_instance" => nil,
        "damping_seconds" => 1.0,
        "broadcast_rate_hz" => 4.0,
        "broadcast_enabled" => true,
        "stream_to_backend" => true
      },
      overrides
    )
  end

  defp aws_x2(id \\ "v1") do
    expr_value(id, "AWS x2", [%{"signal" => "apparent_wind_speed"}, %{"const" => 2.0}, %{"op" => "*"}], [
      "apparent_wind_speed"
    ])
  end

  defp payload(version, values), do: %{"version" => version, "values" => values}

  defp start(opts) do
    base = [name: nil, store_dir: opts[:dir]]
    start_supervised!({Engine, Keyword.merge(base, Keyword.delete(opts, :dir))})
  end

  # --- config apply (mirrors Tracking.Config) ---

  describe "apply_config — version 0 is a real config applied on first receipt" do
    test "applies version 0 on first receipt", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, applied} = Engine.apply_config(pid, payload(0, [aws_x2()]))
      assert applied.version == 0
      assert Engine.applied_version(pid) == 0
    end

    test "an empty values list at version 0 is a valid CLEAR", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, applied} = Engine.apply_config(pid, payload(0, []))
      assert applied.version == 0
      assert Engine.current_values(pid) == []
    end

    test "persists the applied config and round-trips from the store", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Engine.apply_config(pid, payload(2, [aws_x2()]))
      assert {:ok, persisted} = Store.load(dir)
      assert persisted.version == 2
      assert [%{id: "v1"}] = persisted.values
    end
  end

  describe "idempotency on version" do
    test "re-applying the same version is a no-op", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [aws_x2()]))
      assert {:ok, :unchanged} = Engine.apply_config(pid, payload(0, [aws_x2()]))
    end

    test "applying an older version is a no-op", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Engine.apply_config(pid, payload(5, [aws_x2()]))
      assert {:ok, :unchanged} = Engine.apply_config(pid, payload(4, [aws_x2()]))
      assert Engine.applied_version(pid) == 5
    end

    test "applying a newer version is applied", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [aws_x2()]))
      assert {:ok, applied} = Engine.apply_config(pid, payload(1, [aws_x2("v2")]))
      assert applied.version == 1
      assert Engine.applied_version(pid) == 1
    end
  end

  describe "boot reconciliation" do
    test "loads a persisted config on boot and treats it as applied", %{dir: dir} do
      Store.save(dir, %{
        version: 7,
        values: [
          %{
            id: "v1",
            name: "AWS x2",
            definition_type: :expression,
            library_key: nil,
            input_bindings: %{},
            rpn: [%{"signal" => "apparent_wind_speed"}, %{"const" => 2.0}, %{"op" => "*"}],
            signals: ["apparent_wind_speed"],
            output_pgn: 128_259,
            output_field: "speed_water_referenced",
            output_reference: nil,
            output_unit: "m/s",
            output_instance: nil,
            damping_seconds: 0.5,
            broadcast_rate_hz: 2.0,
            broadcast_enabled: true,
            stream_to_backend: true
          }
        ]
      })

      pid = start(dir: dir)
      assert Engine.applied_version(pid) == 7
      assert {:ok, :unchanged} = Engine.apply_config(pid, payload(7, [aws_x2()]))
    end

    test "with no persisted config, applied_version is nil and no values", %{dir: dir} do
      pid = start(dir: dir)
      assert Engine.applied_version(pid) == nil
      assert Engine.current_values(pid) == []
    end
  end

  describe "malformed config is rejected and nothing is applied" do
    test "missing values key", %{dir: dir} do
      pid = start(dir: dir)
      assert {:error, _} = Engine.apply_config(pid, %{"version" => 0})
      assert Engine.applied_version(pid) == nil
    end

    test "a value missing its id is rejected", %{dir: dir} do
      pid = start(dir: dir)
      bad = Map.delete(aws_x2(), "id")
      assert {:error, _} = Engine.apply_config(pid, payload(0, [bad]))
      assert Engine.applied_version(pid) == nil
    end

    test "an expression value with a non-list rpn is rejected", %{dir: dir} do
      pid = start(dir: dir)
      bad = expr_value("x", "bad", "not-a-list", ["apparent_wind_speed"])
      assert {:error, _} = Engine.apply_config(pid, payload(0, [bad]))
    end
  end

  # --- signal-map updates from telemetry with unit conversion ---

  describe "signal map updates from decoded telemetry (radians -> degrees)" do
    test "apparent wind: speed stays m/s, angle is converted rad -> deg", %{dir: dir} do
      pid = start(dir: dir, now_fn: fn -> 1_000 end)

      # AWA = pi/2 rad should become 90 deg; AWS = 7.5 m/s passes through.
      emit_wind(:apparent, _angle_rad = :math.pi() / 2, _speed = 7.5, 1_000)

      assert eventually(fn ->
               s = Engine.signals(pid)
               match?(%{"apparent_wind_angle" => {v, _}} when abs(v - 90.0) < 1.0e-6, s)
             end)

      signals = Engine.signals(pid)
      assert {7.5, _} = signals["apparent_wind_speed"]
    end

    test "heading: radians -> degrees", %{dir: dir} do
      pid = start(dir: dir)
      emit_heading(:math.pi(), 1_000)

      assert eventually(fn ->
               match?(%{"heading" => {v, _}} when abs(v - 180.0) < 1.0e-6, Engine.signals(pid))
             end)
    end

    test "velocity over ground maps to sog (m/s) + cog (deg)", %{dir: dir} do
      pid = start(dir: dir)
      emit_velocity_ground(_cog_rad = :math.pi(), _sog = 4.0, 1_000)

      assert eventually(fn ->
               s = Engine.signals(pid)
               match?(%{"sog" => {4.0, _}, "cog" => {c, _}} when abs(c - 180.0) < 1.0e-6, s)
             end)
    end

    test "water speed maps to boat_speed (STW) in m/s", %{dir: dir} do
      pid = start(dir: dir)
      emit_water_speed(3.25, 1_000)

      assert eventually(fn ->
               match?(%{"boat_speed" => {3.25, _}}, Engine.signals(pid))
             end)
    end

    test "attitude maps heel<-roll and pitch (radians -> degrees)", %{dir: dir} do
      pid = start(dir: dir)
      # roll = pi/4 -> heel 45 deg; pitch = pi/6 -> 30 deg.
      emit_attitude(_yaw = 0.0, _pitch = :math.pi() / 6, _roll = :math.pi() / 4, 1_000)

      assert eventually(fn ->
               s = Engine.signals(pid)

               match?(
                 %{"heel" => {h, _}, "pitch" => {p, _}} when abs(h - 45.0) < 1.0e-6 and abs(p - 30.0) < 1.0e-6,
                 s
               )
             end)
    end

    test "depth maps to depth (m)", %{dir: dir} do
      pid = start(dir: dir)
      emit_depth(12.0, 1_000)
      assert eventually(fn -> match?(%{"depth" => {12.0, _}}, Engine.signals(pid)) end)
    end

    test "gps maps latitude + longitude (degrees pass-through)", %{dir: dir} do
      pid = start(dir: dir)
      emit_gps(42.0, -71.0, 1_000)

      assert eventually(fn ->
               match?(%{"latitude" => {42.0, _}, "longitude" => {-71.0, _}}, Engine.signals(pid))
             end)
    end
  end

  # --- recompute on signal change (event-driven) ---

  describe "recompute on signal change fires for the right defs only" do
    test "an expression recomputes when its source signal changes", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [aws_x2()]))

      # Before any signal, the def is INVALID (its source is missing).
      assert [%{def: %{id: "v1"}, valid?: false}] = Engine.current_values(pid)

      emit_wind(:apparent, 0.0, 7.5, 1_000)

      assert eventually(fn ->
               case Engine.current_values(pid) do
                 [%{valid?: true, outputs: %{"value" => v}}] -> abs(v - 15.0) < 1.0e-6
                 _ -> false
               end
             end)
    end

    test "a signal NOT referenced by any def does not produce a value", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [aws_x2()]))

      # depth is not referenced by aws_x2; updating it must not make the def valid.
      emit_depth(10.0, 1_000)
      Process.sleep(30)
      assert [%{valid?: false}] = Engine.current_values(pid)
    end

    test "current_values exposes the full def, outputs, valid?, and a timestamp", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [aws_x2()]))
      emit_wind(:apparent, 0.0, 5.0, 1_000)

      assert eventually(fn ->
               match?([%{valid?: true}], Engine.current_values(pid))
             end)

      assert [entry] = Engine.current_values(pid)
      assert entry.def.id == "v1"
      assert entry.def.output_pgn == 128_259
      assert is_integer(entry.computed_at_ms)
      assert entry.outputs["value"] == 10.0
    end
  end

  # --- library defs recompute over the current signals ---

  describe "library defs" do
    test "true_wind recomputes from its inputs and exposes named outputs", %{dir: dir} do
      pid = start(dir: dir)

      tw =
        library_value("tw", "True wind", "true_wind", [
          "apparent_wind_speed",
          "apparent_wind_angle",
          "boat_speed",
          "heel",
          "pitch"
        ])

      assert {:ok, _} = Engine.apply_config(pid, payload(0, [tw]))

      now = 5_000
      emit_wind(:apparent, _awa = :math.pi() / 2, _aws = 10.0, now)
      emit_water_speed(10.0, now)
      emit_attitude(0.0, 0.0, 0.0, now)

      assert eventually(fn ->
               case Engine.current_values(pid) do
                 [%{valid?: true, outputs: outs}] ->
                   Map.has_key?(outs, "true_wind_speed") and Map.has_key?(outs, "true_wind_angle")

                 _ ->
                   false
               end
             end)

      [%{outputs: outs}] = Engine.current_values(pid)
      assert_in_delta outs["true_wind_speed"], :math.sqrt(200.0), 1.0e-4
      assert_in_delta outs["true_wind_angle"], 135.0, 1.0e-4
    end
  end

  # --- staleness / missing inputs => invalid ---

  describe "staleness policy" do
    test "a stale signal makes a dependent value invalid", %{dir: dir} do
      # max_age 1000 ms; now starts at 10_000, sample stamped at 1_000 -> already
      # 9 s old, so stale.
      now = :counters.new(1, [])
      :counters.put(now, 1, 10_000)
      now_fn = fn -> :counters.get(now, 1) end

      pid = start(dir: dir, max_age_ms: 1_000, now_fn: now_fn)
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [aws_x2()]))

      emit_wind(:apparent, 0.0, 7.5, _ts = 1_000)
      Process.sleep(20)

      # Even though a sample arrived, it is older than max_age -> invalid.
      assert [%{valid?: false}] = Engine.current_values(pid)
    end

    test "a fresh signal is valid; advancing the clock past max_age makes it stale", %{dir: dir} do
      counter = :counters.new(1, [])
      :counters.put(counter, 1, 1_000)
      now_fn = fn -> :counters.get(counter, 1) end

      pid = start(dir: dir, max_age_ms: 1_000, now_fn: now_fn)
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [aws_x2()]))

      emit_wind(:apparent, 0.0, 7.5, _ts = 1_000)

      assert eventually(fn -> match?([%{valid?: true}], Engine.current_values(pid)) end)

      # Advance the clock well past max_age and force a re-read.
      :counters.put(counter, 1, 5_000)
      assert [%{valid?: false}] = Engine.current_values(pid)
    end
  end

  # --- bearing_to_mark feeds vmc (Phase 8 wiring of the tracked gap) ---

  describe "vmc via injected bearing_to_mark signal" do
    test "vmc is invalid without bearing_to_mark, valid once it is supplied", %{dir: dir} do
      pid = start(dir: dir)

      vmc = library_value("vmc", "VMC", "vmc", ["sog", "cog", "bearing_to_mark"])
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [vmc]))

      # sog + cog present, but no bearing_to_mark yet -> vmc invalid.
      emit_velocity_ground(_cog_rad = :math.pi() / 2, _sog = 5.0, 1_000)
      assert eventually(fn -> match?([%{valid?: false}], Engine.current_values(pid)) end)

      # Inject bearing_to_mark = 60 deg (the value Nav sources from the active mark).
      Engine.put_signal(pid, "bearing_to_mark", 60.0, 1_000)

      assert eventually(fn -> match?([%{valid?: true}], Engine.current_values(pid)) end)
      [%{outputs: outs}] = Engine.current_values(pid)
      # vmc = sog * cos(bearing - cog) = 5 * cos(60 - 90 deg) = 5 * cos(-30) = 4.3301...
      assert_in_delta outs["vmc"], 5.0 * :math.cos(-30.0 * :math.pi() / 180.0), 1.0e-4
    end
  end

  # --- batched signal injection (the WindShift.Observer's per-tick output) ---

  describe "put_signals batch injection" do
    test "a batch folds into the signal map in one message with a shared timestamp", %{dir: dir} do
      pid = start(dir: dir)

      assert :ok =
               Engine.put_signals(pid, [{"average_twd", 202.5}, {"wind_phase_deg", 4.0}, {"wind_regime", 2}], 1_000)

      assert eventually(fn ->
               match?(
                 %{"average_twd" => {202.5, 1_000}, "wind_phase_deg" => {4.0, 1_000}, "wind_regime" => {2, 1_000}},
                 Engine.signals(pid)
               )
             end)
    end

    test "an empty batch is a no-op", %{dir: dir} do
      pid = start(dir: dir)
      assert :ok = Engine.put_signals(pid, [], 1_000)
      assert Engine.signals(pid) == %{}
    end

    test "no-ops safely when the engine is not running" do
      assert :ok = Engine.put_signals(:no_such_engine, [{"average_twd", 200.0}], 1_000)
    end
  end

  # --- status for the channel (applied_version + active_count) ---

  describe "status for the channel" do
    test "status reports applied_version + active_count (number of currently-valid values)", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Engine.apply_config(pid, payload(0, [aws_x2()]))

      # No signals yet -> 0 active.
      assert %{applied_version: 0, active_count: 0} = Engine.status(pid)

      emit_wind(:apparent, 0.0, 5.0, 1_000)
      assert eventually(fn -> Engine.status(pid).active_count == 1 end)
    end
  end

  # --- telemetry emit helpers (mirror EmitTelemetry's event shapes) ---

  defp emit_wind(reference, angle_rad, speed_m_s, ts_ms) do
    :telemetry.execute(
      [:racing_org, :wind, reference],
      %{vector: %{timestamp: nil, angle: angle_rad, magnitude: speed_m_s}},
      %{device_id: <<1, 2, 3, 4, 5, 6, 7, 8>>, timestamp_monotonic_ms: ts_ms}
    )
  end

  defp emit_heading(rad, ts_ms) do
    :telemetry.execute(
      [:racing_org, :heading],
      %{rad: %{timestamp: nil, value: rad}},
      %{device_id: <<1, 2, 3, 4, 5, 6, 7, 8>>, timestamp_monotonic_ms: ts_ms}
    )
  end

  defp emit_velocity_ground(cog_rad, sog_m_s, ts_ms) do
    :telemetry.execute(
      [:racing_org, :velocity, :ground],
      %{vector: %{timestamp: nil, angle: cog_rad, magnitude: sog_m_s}},
      %{device_id: <<1, 2, 3, 4, 5, 6, 7, 8>>, timestamp_monotonic_ms: ts_ms}
    )
  end

  defp emit_water_speed(m_s, ts_ms) do
    :telemetry.execute(
      [:racing_org, :speed, :water],
      %{speed_m_s: %{timestamp: nil, value: m_s}},
      %{device_id: <<1, 2, 3, 4, 5, 6, 7, 8>>, timestamp_monotonic_ms: ts_ms}
    )
  end

  defp emit_attitude(yaw, pitch, roll, ts_ms) do
    :telemetry.execute(
      [:racing_org, :attitude],
      %{rad: %{timestamp: nil, yaw: yaw, pitch: pitch, roll: roll}},
      %{device_id: <<1, 2, 3, 4, 5, 6, 7, 8>>, timestamp_monotonic_ms: ts_ms}
    )
  end

  defp emit_depth(m, ts_ms) do
    :telemetry.execute(
      [:racing_org, :water_depth],
      %{depth_m: %{timestamp: nil, value: m}},
      %{device_id: <<1, 2, 3, 4, 5, 6, 7, 8>>, timestamp_monotonic_ms: ts_ms}
    )
  end

  defp emit_gps(lat, lon, ts_ms) do
    :telemetry.execute(
      [:racing_org, :gps],
      %{position: %{timestamp: nil, lat: lat, lon: lon}},
      %{device_id: <<1, 2, 3, 4, 5, 6, 7, 8>>, timestamp_monotonic_ms: ts_ms}
    )
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
end
