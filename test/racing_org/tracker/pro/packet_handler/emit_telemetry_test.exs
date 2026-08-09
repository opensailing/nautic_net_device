defmodule RacingOrg.Tracker.Pro.PacketHandler.EmitTelemetryTest do
  # Not async: attaches global :telemetry handlers and asserts on emitted events.
  use ExUnit.Case

  alias RacingOrg.Tracker.Pro.PacketHandler.EmitTelemetry
  alias RacingOrg.Tracker.Pro.ClockSource.Config

  @receive_ts ~U[2020-05-05 05:05:05.000Z]
  @gps ~U[2026-06-30 12:00:00.000Z]

  test "attitude data is emitted on the :attitude event path, not :heading" do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      handler_id,
      [[:racing_org, :attitude], [:racing_org, :heading]],
      fn event, measurements, _meta, _config -> send(test_pid, {:telemetry, event, measurements}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, pid} = EmitTelemetry.start_link(filter_mode: :permissive)

    data = %NMEA.Data{
      values: %{NMEA.AttitudeParams => %NMEA.AttitudeParams{yaw: 0.1, pitch: 0.2, roll: 0.3}},
      source_info: %NMEA.NMEA2000.Frame{timestamp: ~U[2026-06-03 12:00:00Z], timestamp_monotonic_ms: 1},
      metadata: %{source_nmea_name: <<1, 2, 3, 4, 5, 6, 7, 8>>}
    }

    send(pid, {:data, data})

    assert_receive {:telemetry, [:racing_org, :attitude], %{rad: %{yaw: 0.1, pitch: 0.2, roll: 0.3}}}
    refute_receive {:telemetry, [:racing_org, :heading], _}, 50
  end

  # --- boat-clock timestamp resolution (clock-source policy) ---

  # Attach a handler that only forwards events tagged with our unique marker
  # (device_id) so a concurrently-running emitter can never pollute assertions.
  defp unique_device_id, do: <<System.unique_integer([:positive])::64>>

  defp attach(event, marker) do
    id = "emit-telemetry-clock-test-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      id,
      event,
      fn _e, m, meta, _ -> if meta[:device_id] == marker, do: send(test, {:telemetry, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  defp wind_data(marker, receive_ts, mono) do
    %NMEA.Data{
      values: %{NMEA.WindParams => %NMEA.WindParams{speed: 5.0, angle: 1.2, reference: :apparent}},
      source_info: %NMEA.NMEA2000.Frame{timestamp: receive_ts, timestamp_monotonic_ms: mono},
      metadata: %{source_nmea_name: marker}
    }
  end

  defp time_data(dt, sa, mono) do
    %NMEA.Data{
      values: %{NMEA.DateTimeParams => %NMEA.DateTimeParams{datetime: dt}},
      source_info: %NMEA.NMEA2000.Frame{source_address: sa, timestamp_monotonic_ms: mono, timestamp: dt},
      metadata: %{source_nmea_name: nil}
    }
  end

  defp start_emitter(clock_source) do
    {:ok, pid} = EmitTelemetry.start_link(filter_mode: :permissive, clock_source: clock_source)
    pid
  end

  test "default (no clock-source config) emits the frame receive timestamp — current behavior" do
    marker = unique_device_id()
    :ok = attach([:racing_org, :wind, :apparent], marker)
    {:ok, clock} = Config.start_link(name: nil, store_dir: nil)
    emit = start_emitter(clock)

    send(emit, {:data, wind_data(marker, @receive_ts, 1000)})

    assert_receive {:telemetry, measurements, metadata}
    assert measurements.vector.timestamp == @receive_ts
    # monotonic passes through untouched for ordering/damping
    assert metadata.timestamp_monotonic_ms == 1000
  end

  test "an unavailable clock-source server falls back to the frame receive timestamp" do
    marker = unique_device_id()
    :ok = attach([:racing_org, :wind, :apparent], marker)
    emit = start_emitter(:no_such_clock_source_server)

    send(emit, {:data, wind_data(marker, @receive_ts, 2000)})

    assert_receive {:telemetry, measurements, _metadata}
    assert measurements.vector.timestamp == @receive_ts
  end

  test "sensor_priority derives the telemetry timestamp from GPS + monotonic delta" do
    marker = unique_device_id()
    :ok = attach([:racing_org, :wind, :apparent], marker)

    {:ok, clock} = Config.start_link(name: nil, store_dir: nil)

    {:ok, _} =
      Config.apply_config(clock, %{
        "version" => 1,
        "mode" => "sensor_priority",
        "fallback" => "tracker_receive_time",
        "sources" => [%{"priority" => 1, "source_address" => "35"}]
      })

    # observe a GPS time sample from the configured source at monotonic 1000
    send(clock, {:data, time_data(@gps, 35, 1000)})
    _ = Config.applied_version(clock)

    emit = start_emitter(clock)

    # a wind frame at monotonic 1500 is 500 ms after the GPS sample
    send(emit, {:data, wind_data(marker, @receive_ts, 1500)})

    assert_receive {:telemetry, measurements, metadata}
    assert measurements.vector.timestamp == DateTime.add(@gps, 500, :millisecond)
    assert metadata.timestamp_monotonic_ms == 1500
  end
end
