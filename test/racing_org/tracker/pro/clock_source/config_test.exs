defmodule RacingOrg.Tracker.Pro.ClockSource.ConfigTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.ClockSource.Config

  @fallback ~U[2000-01-01 00:00:00.000Z]
  @gps ~U[2026-06-30 12:00:00.000Z]

  # --- helpers ---

  defp start_config(opts \\ []) do
    opts = opts |> Keyword.put_new(:name, nil) |> Keyword.put_new(:store_dir, nil)
    {:ok, pid} = Config.start_link(opts)
    pid
  end

  defp sensor_config(version, sources) do
    %{
      "version" => version,
      "mode" => "sensor_priority",
      "fallback" => "tracker_receive_time",
      "sources" => sources
    }
  end

  defp src(priority, fields), do: Map.merge(%{"priority" => priority}, fields)

  defp time_data(dt, sa, name, mono) do
    %NMEA.Data{
      values: %{NMEA.DateTimeParams => %NMEA.DateTimeParams{datetime: dt}},
      source_info: %NMEA.NMEA2000.Frame{source_address: sa, timestamp_monotonic_ms: mono, timestamp: dt},
      metadata: %{source_nmea_name: name}
    }
  end

  # send a decoded time message and synchronize (the following call is processed
  # after the info, so the timebase is updated before we assert).
  defp observe(pid, data) do
    send(pid, {:data, data})
    _ = Config.applied_version(pid)
    :ok
  end

  # --- default behavior ---

  test "with no config, the mode is tracker_receive_time and resolve returns the frame receive time" do
    pid = start_config()
    assert Config.applied_version(pid) == nil
    assert Config.resolve_timestamp(pid, @fallback, 5000) == @fallback
    status = Config.status(pid)
    assert status.mode == "tracker_receive_time"
    assert status.timebase == "tracker_receive_time"
    assert status.fallback_reason == "default_mode"
    assert status.last_gps_time == nil
  end

  test "resolve_timestamp returns the fallback when the server is unavailable" do
    assert Config.resolve_timestamp(:no_such_clock_source_server, @fallback, 5000) == @fallback
  end

  # --- versioned idempotency ---

  test "applying config is idempotent by version" do
    pid = start_config()

    assert {:ok, %{version: 1}} = Config.apply_config(pid, sensor_config(1, []))
    assert Config.applied_version(pid) == 1

    # same and older versions are no-ops
    assert {:ok, :unchanged} = Config.apply_config(pid, sensor_config(1, []))
    assert {:ok, :unchanged} = Config.apply_config(pid, sensor_config(0, []))
    assert Config.applied_version(pid) == 1

    # a newer version applies
    assert {:ok, %{version: 2}} = Config.apply_config(pid, sensor_config(2, []))
    assert Config.applied_version(pid) == 2
  end

  test "the first config (even version 0) is always applied" do
    pid = start_config()
    assert {:ok, %{version: 0}} = Config.apply_config(pid, sensor_config(0, []))
    assert Config.applied_version(pid) == 0
  end

  test "a malformed config (no version) is rejected and nothing is applied" do
    pid = start_config()
    assert {:error, :bad_version} = Config.apply_config(pid, %{"mode" => "sensor_priority"})
    assert Config.applied_version(pid) == nil
  end

  test "an unknown mode falls back to tracker_receive_time (safe default)" do
    pid = start_config()
    assert {:ok, _} = Config.apply_config(pid, %{"version" => 1, "mode" => "bogus"})
    assert Config.status(pid).mode == "tracker_receive_time"
  end

  # --- sensor_priority timebase ---

  test "sensor_priority derives telemetry timestamps from GPS time via the monotonic delta" do
    pid = start_config()
    {:ok, _} = Config.apply_config(pid, sensor_config(1, [src(1, %{"source_address" => "35"})]))

    observe(pid, time_data(@gps, 35, nil, 1000))

    # a later frame (monotonic 1500) is 500 ms after the GPS sample
    assert Config.resolve_timestamp(pid, @fallback, 1500) == DateTime.add(@gps, 500, :millisecond)
    # an earlier frame (monotonic 800) is 200 ms before the GPS sample
    assert Config.resolve_timestamp(pid, @fallback, 800) == DateTime.add(@gps, -200, :millisecond)
  end

  test "sensor_priority ignores time from an unconfigured source (falls back)" do
    pid = start_config()
    {:ok, _} = Config.apply_config(pid, sensor_config(1, [src(1, %{"source_address" => "35"})]))

    observe(pid, time_data(@gps, 99, nil, 1000))

    assert Config.resolve_timestamp(pid, @fallback, 1500) == @fallback
    assert Config.status(pid).fallback_reason == "no_valid_source"
  end

  test "a higher-priority source preempts a lower-priority one; a lower one does not downgrade a fresh higher one" do
    pid = start_config()

    {:ok, _} =
      Config.apply_config(
        pid,
        sensor_config(1, [src(1, %{"source_address" => "35"}), src(2, %{"source_address" => "40"})])
      )

    # only the low-priority source is heard first -> it is active
    t40 = ~U[2026-06-30 12:00:00.000Z]
    observe(pid, time_data(t40, 40, nil, 1000))
    assert Config.resolve_timestamp(pid, @fallback, 1000) == t40

    # the high-priority source is heard -> it preempts
    t35 = ~U[2026-06-30 12:00:10.000Z]
    observe(pid, time_data(t35, 35, nil, 2000))
    assert Config.resolve_timestamp(pid, @fallback, 2000) == t35

    # the low-priority source is heard again but must NOT downgrade the fresh high-priority timebase
    observe(pid, time_data(~U[2026-06-30 09:00:00.000Z], 40, nil, 3000))
    assert Config.resolve_timestamp(pid, @fallback, 3000) == DateTime.add(t35, 1000, :millisecond)
  end

  test "a stale active source falls back to the frame receive time" do
    pid = start_config(stale_ms: 1000)
    {:ok, _} = Config.apply_config(pid, sensor_config(1, [src(1, %{"source_address" => "35"})]))

    observe(pid, time_data(@gps, 35, nil, 1000))

    # within the stale window -> GPS-derived
    assert Config.resolve_timestamp(pid, @fallback, 1500) == DateTime.add(@gps, 500, :millisecond)
    # beyond the stale window (delta 2000 > 1000) -> fallback
    assert Config.resolve_timestamp(pid, @fallback, 3000) == @fallback
  end

  # --- source matching (backend uppercase-hex hardware ids) ---

  # NMEA NAME integer 0x1A2B (== 6699) as its on-bus 8-byte binary NAME.
  @name_1a2b <<0, 0, 0, 0, 0, 0, 0x1A, 0x2B>>

  test "backend hardware_identifier (uppercase hex) matches an 8-byte binary NMEA NAME" do
    pid = start_config()
    {:ok, _} = Config.apply_config(pid, sensor_config(1, [src(1, %{"hardware_identifier" => "1A2B"})]))

    # Different source_address, but the NAME canonicalizes to the backend hex id.
    observe(pid, time_data(@gps, 77, @name_1a2b, 1000))
    assert Config.resolve_timestamp(pid, @fallback, 1500) == DateTime.add(@gps, 500, :millisecond)
  end

  test "backend hardware_identifier (uppercase hex) matches an integer NMEA NAME" do
    pid = start_config()
    {:ok, _} = Config.apply_config(pid, sensor_config(1, [src(1, %{"hardware_identifier" => "1A2B"})]))

    observe(pid, time_data(@gps, 77, 0x1A2B, 1000))
    assert Config.resolve_timestamp(pid, @fallback, 1500) == DateTime.add(@gps, 500, :millisecond)
  end

  test "metadata.source_nmea_name given as prefixed lowercase hex matches a binary NMEA NAME" do
    pid = start_config()

    {:ok, _} =
      Config.apply_config(pid, sensor_config(1, [src(1, %{"metadata" => %{"source_nmea_name" => "0x1a2b"}})]))

    observe(pid, time_data(@gps, 12, @name_1a2b, 1000))
    assert Config.resolve_timestamp(pid, @fallback, 1500) == DateTime.add(@gps, 500, :millisecond)
  end

  test "backend sensor_uid (uppercase hex) matches an integer NMEA NAME" do
    pid = start_config()
    {:ok, _} = Config.apply_config(pid, sensor_config(1, [src(1, %{"sensor_uid" => "1A2B"})]))

    observe(pid, time_data(@gps, 12, 0x1A2B, 1000))
    assert Config.resolve_timestamp(pid, @fallback, 1500) == DateTime.add(@gps, 500, :millisecond)
  end

  test "source_address matching still works when the NAME matches no identity" do
    pid = start_config()
    {:ok, _} = Config.apply_config(pid, sensor_config(1, [src(1, %{"source_address" => "35"})]))

    observe(pid, time_data(@gps, 35, <<9, 9, 9, 9, 9, 9, 9, 9>>, 1000))
    assert Config.resolve_timestamp(pid, @fallback, 1500) == DateTime.add(@gps, 500, :millisecond)
  end

  test "non-hex label-style names do not crash, and literal label matching still works" do
    pid = start_config()
    {:ok, _} = Config.apply_config(pid, sensor_config(1, [src(1, %{"label" => "Dockyard GPS"})]))

    # A non-hex textual NAME must not crash canonicalization; the label matches it literally.
    observe(pid, time_data(@gps, 12, "Dockyard GPS", 1000))
    assert Config.resolve_timestamp(pid, @fallback, 1500) == DateTime.add(@gps, 500, :millisecond)

    # A non-matching label leaves the timebase unset -> falls back.
    pid2 = start_config()
    {:ok, _} = Config.apply_config(pid2, sensor_config(1, [src(1, %{"label" => "Other"})]))
    observe(pid2, time_data(@gps, 12, "Dockyard GPS", 1000))
    assert Config.resolve_timestamp(pid2, @fallback, 1500) == @fallback
  end

  # --- status ---

  test "status reflects the active sensor source when fresh" do
    pid = start_config(now_fn: fn -> 5000 end)

    {:ok, _} =
      Config.apply_config(
        pid,
        sensor_config(7, [
          src(1, %{
            "source_address" => "35",
            "sensor_id" => "sensor-abc",
            "label" => "Masthead GPS",
            "hardware_identifier" => "hw-1"
          })
        ])
      )

    observe(pid, time_data(@gps, 35, nil, 5000))

    status = Config.status(pid)
    assert status.applied_version == 7
    assert status.mode == "sensor_priority"
    assert status.timebase == "sensor"
    assert status.fallback_reason == nil
    assert status.active_source_sensor_id == "sensor-abc"
    assert status.active_source_label == "Masthead GPS"
    assert status.active_hw_id == "hw-1"
    assert status.active_source_address == "35"
    assert status.last_gps_time == DateTime.to_iso8601(@gps)
    assert status.status == "ok"
  end

  test "status reports a stale timebase as fallback" do
    pid = start_config(stale_ms: 100, now_fn: fn -> 100_000 end)
    {:ok, _} = Config.apply_config(pid, sensor_config(1, [src(1, %{"source_address" => "35"})]))
    observe(pid, time_data(@gps, 35, nil, 1000))

    status = Config.status(pid)
    assert status.timebase == "tracker_receive_time"
    assert status.fallback_reason == "stale"
    # the last observed GPS time is still reported for diagnostics
    assert status.last_gps_time == DateTime.to_iso8601(@gps)
  end

  # --- persistence ---

  describe "persistence" do
    setup do
      dir = Path.join(System.tmp_dir!(), "clock_source_config_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "config survives a restart and is treated as already-applied", %{dir: dir} do
      pid = start_config(store_dir: dir)
      {:ok, _} = Config.apply_config(pid, sensor_config(5, [src(1, %{"source_address" => "35"})]))
      # stop the first instance so the second reloads from disk
      :ok = GenServer.stop(pid)

      pid2 = start_config(store_dir: dir)
      assert Config.applied_version(pid2) == 5
      assert Config.status(pid2).mode == "sensor_priority"
      # re-pushing the same version is a no-op; a newer one still applies
      assert {:ok, :unchanged} = Config.apply_config(pid2, sensor_config(5, []))
      assert {:ok, %{version: 6}} = Config.apply_config(pid2, sensor_config(6, []))

      # the timebase is NOT persisted -> resolve falls back until fresh GPS is seen
      assert Config.resolve_timestamp(pid2, @fallback, 1000) == @fallback
    end

    test "a corrupt persisted store falls back to safe defaults", %{dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "current.clock_source"), "garbage")

      pid = start_config(store_dir: dir)
      assert Config.applied_version(pid) == nil
      assert Config.status(pid).mode == "tracker_receive_time"
      assert Config.resolve_timestamp(pid, @fallback, 1000) == @fallback
    end
  end
end
