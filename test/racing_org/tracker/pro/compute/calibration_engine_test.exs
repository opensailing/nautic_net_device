defmodule RacingOrg.Tracker.Pro.Compute.CalibrationEngineTest do
  @moduledoc """
  Integration: the compute Engine applies the cached per-sensor calibration
  corrections to decoded telemetry BEFORE folding values into the signal map,
  refreshing its LOCAL corrections cache only on a calibration-change
  notification — NEVER cross-process-fetching per telemetry event. With no
  calibration collaborator (or an empty corrections map) every signal value is
  BIT-IDENTICAL to the uncorrected path.

  Not async: the Engine attaches global :telemetry handlers and we drive real
  :telemetry.execute/3 events.
  """
  use ExUnit.Case

  alias RacingOrg.Tracker.Pro.Compute.Engine

  @rad_per_deg :math.pi() / 180.0
  @deg_per_rad 180.0 / :math.pi()

  # NMEA NAME integer 0x1A2B as its on-bus 8-byte binary NAME -> canonical hex "1A2B".
  @name_1a2b <<0, 0, 0, 0, 0, 0, 0x1A, 0x2B>>
  @other_name <<9, 9, 9, 9, 9, 9, 9, 9>>

  # A stub Calibration.Config the Engine reads the corrections from. It counts the
  # number of corrections/1 calls so we can PROVE the fetch is off the hot path.
  defmodule StubCalibration do
    use Agent

    def start_link(opts) do
      Agent.start_link(
        fn -> %{corrections: opts[:corrections] || %{}, fetches: 0, subscriber: nil} end,
        name: opts[:name]
      )
    end

    def set(agent, corrections), do: Agent.update(agent, &%{&1 | corrections: corrections})

    def corrections(agent) do
      Agent.get_and_update(agent, fn s -> {s.corrections, %{s | fetches: s.fetches + 1}} end)
    end

    def fetches(agent), do: Agent.get(agent, & &1.fetches)

    # The Engine subscribes via this; it just records the subscriber so the test can
    # deliver a calibration-change notification.
    def subscribe(agent, pid) do
      Agent.update(agent, fn s -> %{s | subscriber: pid} end)
      :ok
    end
  end

  defp start_engine(opts) do
    {calibration, cal} =
      case Keyword.fetch(opts, :corrections) do
        {:ok, corrections} ->
          {:ok, cal} = StubCalibration.start_link(name: nil, corrections: corrections)
          {{StubCalibration, cal}, cal}

        :error ->
          {Keyword.get(opts, :calibration), nil}
      end

    base = [
      name: nil,
      store_dir: nil,
      commands: nil,
      calibration: calibration,
      now_fn: fn -> 1_000 end
    ]

    pid = start_supervised!({Engine, base}, id: {Engine, System.unique_integer([:positive])})
    %{engine: pid, cal: cal}
  end

  defp emit_wind(angle_deg, speed_m_s, device_id) do
    :telemetry.execute(
      [:racing_org, :wind, :apparent],
      %{vector: %{timestamp: nil, angle: angle_deg * @rad_per_deg, magnitude: speed_m_s}},
      %{device_id: device_id, timestamp_monotonic_ms: 1_000}
    )
  end

  defp emit_water_speed(m_s, device_id) do
    :telemetry.execute(
      [:racing_org, :speed, :water],
      %{speed_m_s: %{timestamp: nil, value: m_s}},
      %{device_id: device_id, timestamp_monotonic_ms: 1_000}
    )
  end

  defp emit_heading(rad, device_id) do
    :telemetry.execute(
      [:racing_org, :heading],
      %{rad: %{timestamp: nil, value: rad}},
      %{device_id: device_id, timestamp_monotonic_ms: 1_000}
    )
  end

  defp emit_attitude(yaw, pitch, roll, device_id) do
    :telemetry.execute(
      [:racing_org, :attitude],
      %{rad: %{timestamp: nil, yaw: yaw, pitch: pitch, roll: roll}},
      %{device_id: device_id, timestamp_monotonic_ms: 1_000}
    )
  end

  # The telemetry handler forwards asynchronously; a sync call flushes the mailbox.
  defp signal(pid, name) do
    case Engine.signals(pid)[name] do
      {value, _mono} -> value
      nil -> nil
    end
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

  defp await_signal(pid, name) do
    assert eventually(fn -> signal(pid, name) != nil end)
    signal(pid, name)
  end

  # The documented Ockam angle shape the engine scales the upwash term by
  # (recomputed here independently of the module under test).
  defp shape(abs_awa), do: :math.pow(:math.sin(0.6 * (180.0 - abs_awa) * :math.pi() / 180.0), 2.5)

  defp put_tws(pid, tws) do
    Engine.put_signal(pid, "true_wind_speed", tws, 1_000)
    assert eventually(fn -> signal(pid, "true_wind_speed") == tws end)
  end

  # --- apparent wind angle corrections ---

  describe "apparent_wind_angle corrections" do
    test "0..360 convention: offset applies and wraps correctly (+170 + 14 -> 184)" do
      %{engine: pid} = start_engine(corrections: %{"1A2B" => %{awa_offset_deg: 14.0}})

      emit_wind(170.0, 8.0, @name_1a2b)
      assert_in_delta await_signal(pid, "apparent_wind_angle"), 184.0, 1.0e-9
    end

    test "signed convention: a negative AWA stays signed and wraps correctly (-170 - 14 -> 176)" do
      %{engine: pid} = start_engine(corrections: %{"1A2B" => %{awa_offset_deg: -14.0}})

      emit_wind(-170.0, 8.0, @name_1a2b)
      assert_in_delta await_signal(pid, "apparent_wind_angle"), 176.0, 1.0e-9
    end

    test "upwash sign flips with the tack side (starboard +, port -), scaled by the angle shape" do
      %{engine: pid} = start_engine(corrections: %{"1A2B" => %{awa_upwash: [{0.0, 5.0}]}})

      # Starboard: +10 deg -> +10 + 5*shape(10).
      expected = 10.0 + 5.0 * shape(10.0)
      emit_wind(10.0, 8.0, @name_1a2b)
      assert_in_delta await_signal(pid, "apparent_wind_angle"), expected, 1.0e-9

      # Port (0..360 convention): 350 deg == -10 signed -> mirrored -> 360 - expected.
      emit_wind(350.0, 8.0, @name_1a2b)
      assert eventually(fn -> abs(signal(pid, "apparent_wind_angle") - (360.0 - expected)) < 1.0e-9 end)
    end

    test "the upwash angle shape at |awa| 30/90/150 is ~1.0/0.588/0.053 (fades off the wind)" do
      %{engine: pid} = start_engine(corrections: %{"1A2B" => %{awa_upwash: [{0.0, 5.0}]}})

      # Hand-computed: shape(a) = sin(0.6*(180-a)*pi/180)^2.5.
      for {awa, factor} <- [{30.0, 1.0}, {90.0, 0.5887}, {150.0, 0.0531}] do
        emit_wind(awa, 8.0, @name_1a2b)

        assert eventually(fn -> abs(signal(pid, "apparent_wind_angle") - (awa + 5.0 * factor)) < 5.0e-3 end),
               "expected #{awa} + 5*#{factor}, got #{signal(pid, "apparent_wind_angle")}"
      end
    end

    test "no upwash at dead-ahead (sign(0) = 0); the offset still applies" do
      %{engine: pid} = start_engine(corrections: %{"1A2B" => %{awa_offset_deg: 2.0, awa_upwash: [{0.0, 5.0}]}})

      emit_wind(0.0, 8.0, @name_1a2b)
      assert_in_delta await_signal(pid, "apparent_wind_angle"), 2.0, 1.0e-9
    end

    test "the total AWA correction is defensively clamped to +/-15 degrees" do
      # offset 12 + upwash 8*shape(30) = 8 -> 20 total, clamped to 15.
      %{engine: pid} = start_engine(corrections: %{"1A2B" => %{awa_offset_deg: 12.0, awa_upwash: [{0.0, 8.0}]}})

      emit_wind(30.0, 8.0, @name_1a2b)
      assert_in_delta await_signal(pid, "apparent_wind_angle"), 45.0, 1.0e-9
    end

    test "a sensor without a correction entry passes through untouched" do
      %{engine: pid} = start_engine(corrections: %{"1A2B" => %{awa_offset_deg: 14.0}})

      emit_wind(170.0, 8.0, @other_name)
      assert_in_delta await_signal(pid, "apparent_wind_angle"), 170.0, 1.0e-9
    end

    test "an integer NMEA NAME device_id canonicalizes to the same hex identity" do
      %{engine: pid} = start_engine(corrections: %{"1A2B" => %{awa_offset_deg: 10.0}})

      emit_wind(10.0, 8.0, 0x1A2B)
      assert_in_delta await_signal(pid, "apparent_wind_angle"), 20.0, 1.0e-9
    end
  end

  # --- TWS-banded upwash (awa_upwash is a {tws_center_mps, deg} curve) ---

  describe "TWS-banded upwash" do
    setup do
      %{engine: pid} = start_engine(corrections: %{"1A2B" => %{awa_upwash: [{5.0, 4.0}, {9.0, 2.0}]}})
      %{pid: pid}
    end

    # shape(30) == 1.0 exactly, so the corrected AWA is 30 + upwash_at(tws).

    test "below the first curve center: flat hold", %{pid: pid} do
      put_tws(pid, 4.0)
      emit_wind(30.0, 8.0, @name_1a2b)
      assert_in_delta await_signal(pid, "apparent_wind_angle"), 34.0, 1.0e-9
    end

    test "between curve centers: linear interpolation", %{pid: pid} do
      put_tws(pid, 7.0)
      emit_wind(30.0, 8.0, @name_1a2b)
      assert_in_delta await_signal(pid, "apparent_wind_angle"), 33.0, 1.0e-9
    end

    test "above the last curve center: flat hold", %{pid: pid} do
      put_tws(pid, 12.0)
      emit_wind(30.0, 8.0, @name_1a2b)
      assert_in_delta await_signal(pid, "apparent_wind_angle"), 32.0, 1.0e-9
    end

    test "with no TWS ever heard: the curve's middle point applies (flat prior)", %{pid: pid} do
      # Middle element of a 2-point curve = index div(2, 2) = 1 -> {9.0, 2.0}.
      emit_wind(30.0, 8.0, @name_1a2b)
      assert_in_delta await_signal(pid, "apparent_wind_angle"), 32.0, 1.0e-9
    end

    test "the last-known TWS keeps applying until a fresh one arrives", %{pid: pid} do
      put_tws(pid, 4.0)
      emit_wind(30.0, 8.0, @name_1a2b)
      assert_in_delta await_signal(pid, "apparent_wind_angle"), 34.0, 1.0e-9

      put_tws(pid, 9.0)
      emit_wind(30.0, 8.0, @name_1a2b)
      assert eventually(fn -> abs(signal(pid, "apparent_wind_angle") - 32.0) < 1.0e-9 end)
    end
  end

  # --- boat_speed (STW) gain corrections ---

  describe "boat_speed corrections (piecewise-linear stw_gains)" do
    setup do
      %{engine: pid, cal: cal} =
        start_engine(corrections: %{"1A2B" => %{stw_gains: [{2.0, 1.10}, {6.0, 1.02}]}})

      %{pid: pid, cal: cal}
    end

    test "below the first band center: flat extrapolation", %{pid: pid} do
      emit_water_speed(1.0, @name_1a2b)
      assert_in_delta await_signal(pid, "boat_speed"), 1.0 * 1.10, 1.0e-9
    end

    test "between band centers: linear interpolation", %{pid: pid} do
      emit_water_speed(4.0, @name_1a2b)
      assert_in_delta await_signal(pid, "boat_speed"), 4.0 * 1.06, 1.0e-9
    end

    test "above the last band center: flat extrapolation", %{pid: pid} do
      emit_water_speed(8.0, @name_1a2b)
      assert_in_delta await_signal(pid, "boat_speed"), 8.0 * 1.02, 1.0e-9
    end

    test "a single pair is a uniform gain" do
      %{engine: pid} = start_engine(corrections: %{"1A2B" => %{stw_gains: [{0.0, 1.05}]}})
      emit_water_speed(3.0, @name_1a2b)
      assert_in_delta await_signal(pid, "boat_speed"), 3.0 * 1.05, 1.0e-9
    end

    test "the gain is defensively clamped to [0.8, 1.2]" do
      %{engine: pid} = start_engine(corrections: %{"1A2B" => %{stw_gains: [{0.0, 2.0}]}})
      emit_water_speed(3.0, @name_1a2b)
      assert_in_delta await_signal(pid, "boat_speed"), 3.0 * 1.2, 1.0e-9

      %{engine: pid2} = start_engine(corrections: %{"1A2B" => %{stw_gains: [{0.0, 0.1}]}})
      emit_water_speed(3.0, @name_1a2b)
      assert_in_delta await_signal(pid2, "boat_speed"), 3.0 * 0.8, 1.0e-9
    end

    test "other signals from a corrected sensor pass through untouched", %{pid: pid} do
      emit_heading(:math.pi(), @name_1a2b)
      assert_in_delta await_signal(pid, "heading"), 180.0, 1.0e-9
    end
  end

  # --- ZERO-DIFF guarantee ---

  describe "zero-diff guarantee" do
    test "no collaborator and empty corrections produce BIT-IDENTICAL signal maps" do
      %{engine: bare} = start_engine(calibration: nil)
      %{engine: empty} = start_engine(corrections: %{})

      # Both engines see the SAME telemetry events (global handlers).
      emit_wind(123.456, 7.891, @name_1a2b)
      emit_water_speed(3.14159, @name_1a2b)
      emit_heading(1.0471975511965976, @name_1a2b)
      emit_attitude(0.0, 0.1, 0.2, @name_1a2b)

      assert eventually(fn -> signal(bare, "heading") != nil and signal(empty, "heading") != nil end)
      assert eventually(fn -> signal(bare, "boat_speed") != nil and signal(empty, "boat_speed") != nil end)

      # Strict (===) equality: every value bit-identical between the two paths.
      assert Engine.signals(bare) === Engine.signals(empty)
    end
  end

  # --- HOT PATH: corrections cached; refresh ONLY on notification ---

  describe "hot path" do
    test "a burst of telemetry events never re-fetches corrections from the collaborator" do
      %{engine: pid, cal: cal} = start_engine(corrections: %{"1A2B" => %{awa_offset_deg: 10.0}})

      emit_wind(10.0, 8.0, @name_1a2b)
      assert_in_delta await_signal(pid, "apparent_wind_angle"), 20.0, 1.0e-9

      fetches_before = StubCalibration.fetches(cal)

      # Hammer the ingest path: 200 telemetry events, all corrected. NONE of these
      # may fetch corrections from the collaborator.
      for i <- 1..200 do
        emit_wind(10.0 + i / 1000.0, 8.0, @name_1a2b)
        emit_water_speed(3.0 + i / 1000.0, @name_1a2b)
      end

      # Synchronize: the last event has been folded in (corrected).
      assert eventually(fn -> abs(signal(pid, "apparent_wind_angle") - 20.2) < 1.0e-9 end)

      assert StubCalibration.fetches(cal) == fetches_before,
             "engine re-fetched calibration corrections on the hot path " <>
               "(#{StubCalibration.fetches(cal) - fetches_before} extra fetches over 200 events)"
    end

    test "the cached corrections refresh ONLY when a calibration change is notified" do
      %{engine: pid, cal: cal} = start_engine(corrections: %{"1A2B" => %{awa_offset_deg: 10.0}})

      emit_wind(10.0, 8.0, @name_1a2b)
      assert_in_delta await_signal(pid, "apparent_wind_angle"), 20.0, 1.0e-9

      fetches_before = StubCalibration.fetches(cal)
      StubCalibration.set(cal, %{"1A2B" => %{awa_offset_deg: -5.0}})

      # Deliver the standard calibration notification the engine subscribes to.
      send(pid, {:racing_org_calibration, :updated})

      assert eventually(fn ->
               emit_wind(10.0, 8.0, @name_1a2b)
               abs(signal(pid, "apparent_wind_angle") - 5.0) < 1.0e-9
             end)

      # The refresh consulted the collaborator exactly once for the change — not per event.
      assert StubCalibration.fetches(cal) == fetches_before + 1
    end
  end

  # --- true wind computes from CORRECTED inputs (feed_back_outputs reads the signal map) ---

  describe "true wind uses corrected inputs" do
    test "a corrected AWA shifts the computed true_wind_direction accordingly" do
      %{engine: pid} = start_engine(corrections: %{"1A2B" => %{awa_offset_deg: 10.0}})

      tw = %{
        "id" => "tw",
        "name" => "True wind",
        "definition_type" => "library",
        "library_key" => "true_wind",
        "input_bindings" => %{},
        "rpn" => nil,
        "signals" => ["apparent_wind_speed", "apparent_wind_angle", "boat_speed", "heel", "pitch", "heading"],
        "output_pgn" => 130_306,
        "output_field" => "wind_speed",
        "output_reference" => "true",
        "output_unit" => "m/s",
        "output_instance" => nil,
        "damping_seconds" => 1.0,
        "broadcast_rate_hz" => 4.0,
        "broadcast_enabled" => true,
        "stream_to_backend" => true
      }

      assert {:ok, _} = Engine.apply_config(pid, %{"version" => 0, "values" => [tw]})

      emit_wind(90.0, 10.0, @name_1a2b)
      emit_water_speed(10.0, @name_1a2b)
      emit_attitude(0.0, 0.0, 0.0, @name_1a2b)
      emit_heading(0.0, @name_1a2b)

      # Expected from the CORRECTED AWA (100 deg), same math as Library.true_wind.
      corrected_awa_rad = 100.0 * @rad_per_deg
      tx = 10.0 * :math.cos(corrected_awa_rad) - 10.0
      ty = 10.0 * :math.sin(corrected_awa_rad)
      expected_twa = :math.atan2(ty, tx) * @deg_per_rad

      assert eventually(fn ->
               match?([%{valid?: true}], Engine.current_values(pid))
             end)

      assert [%{outputs: outs}] = Engine.current_values(pid)
      assert_in_delta outs["true_wind_angle"], expected_twa, 1.0e-6
      # heading 0 -> direction == angle; the UNcorrected AWA (90) would give 135.
      assert_in_delta outs["true_wind_direction"], expected_twa, 1.0e-6
      refute_in_delta outs["true_wind_direction"], 135.0, 1.0

      # The fed-back true_wind_direction signal (read by downstream calcs) is the
      # corrected one too — feed_back_outputs reads the corrected signal map.
      assert eventually(fn ->
               case signal(pid, "true_wind_direction") do
                 nil -> false
                 twd -> abs(twd - expected_twa) < 1.0e-6
               end
             end)
    end
  end
end
