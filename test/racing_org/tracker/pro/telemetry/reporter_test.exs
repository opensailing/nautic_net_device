defmodule RacingOrg.Tracker.Pro.Telemetry.ReporterTest do
  use ExUnit.Case

  import Telemetry.Metrics

  @production_device_id <<1::64>>

  describe "the :asap? option" do
    test "reports metrics as soon as they are emitted" do
      start_reporter([last_value("some.metric.value", reporter_options: [asap?: true])])

      telemetry_execute_value(999)

      assert_receive {:report, [:some, :metric, :value], 999}
    end
  end

  describe "the :every_ms option" do
    test "reports metrics at a timed interval" do
      start_reporter([last_value("some.metric.value", reporter_options: [every_ms: 10])])

      telemetry_execute_value(999)

      # Should be sent within 10ms
      assert_receive {:report, [:some, :metric, :value], 999}, 20

      # Shouldn't repeat until more values come in
      refute_receive {:report, [:some, :metric, :value], 999}, 20

      # Check again
      telemetry_execute_value(999)

      assert_receive {:report, [:some, :metric, :value], 999}, 20
    end
  end

  describe "summary metrics" do
    test "calculate measurements at a timed interval" do
      start_reporter([summary("some.metric.value", reporter_options: [every_ms: 10])])

      telemetry_execute_value(1)
      telemetry_execute_value(2)
      telemetry_execute_value(3)
      telemetry_execute_value(4)
      telemetry_execute_value(5)

      assert_receive {:report, [:some, :metric, :value],
                      %{
                        min: 1,
                        max: 5,
                        mean: 3.0,
                        median: 3
                      }}
    end

    test "works with vector data" do
      start_reporter([summary("some.metric.value", reporter_options: [every_ms: 10])])

      telemetry_execute_value(%{magnitude: 1, angle: 0})
      telemetry_execute_value(%{magnitude: 2, angle: :math.pi() / 2})
      telemetry_execute_value(%{magnitude: 3, angle: :math.pi() / 3})
      telemetry_execute_value(%{magnitude: 4, angle: :math.pi() / 4})
      telemetry_execute_value(%{magnitude: 5, angle: :math.pi() / 5})

      assert_receive {:report, [:some, :metric, :value],
                      %{
                        max: %{angle: 0.6283185307179586, magnitude: 5},
                        mean: %{angle: 0.835607735645695, magnitude: 2.7950303022866176},
                        median: %{angle: 1.0471975511965976, magnitude: 3},
                        min: %{angle: 0, magnitude: 1}
                      }}
    end
  end

  describe "set_flush_interval/2" do
    test "changes the output flush rate at runtime" do
      pid = start_reporter([last_value("some.metric.value")], flush_interval_ms: 1_000)

      # At 1 Hz, a value emitted now is not flushed within 50 ms.
      telemetry_execute_value(1)
      refute_receive {:report, [:some, :metric, :value], 1}, 50

      # Speed up to ~100 Hz; the pending value flushes promptly.
      assert :ok = RacingOrg.Tracker.Pro.Telemetry.Reporter.set_flush_interval(pid, 10)
      assert_receive {:report, [:some, :metric, :value], 1}, 50
    end
  end

  describe "set_damping/2 EWMA smoothing of signal measurements" do
    # The real signals carry measurement MAPS like %{timestamp, value} (scalar) or
    # %{timestamp, angle, magnitude} (vector). With damping the reporter low-passes
    # the numeric fields before flushing.

    test "tau = 0 is pass-through: the last sample is reported verbatim (linear)" do
      pid =
        start_reporter(
          [last_value([:racing_org, :speed, :water, :speed_m_s], reporter_options: [every_ms: 10_000])],
          flush_interval_ms: 10_000
        )

      assert :ok = RacingOrg.Tracker.Pro.Telemetry.Reporter.set_damping(pid, 0.0)

      emit_scalar_full([:racing_org, :speed, :water], :speed_m_s, %{value: 1.0}, 0)
      emit_scalar_full([:racing_org, :speed, :water], :speed_m_s, %{value: 7.0}, 100)

      flush(pid)
      assert_receive {:report, [:racing_org, :speed, :water, :speed_m_s], %{value: 7.0}}
    end

    test "a step input on a scalar field converges toward, but lags, the new value" do
      pid =
        start_reporter([last_value([:racing_org, :speed, :water, :speed_m_s], reporter_options: [every_ms: 10_000])],
          flush_interval_ms: 10_000
        )

      # 1 second time constant.
      assert :ok = RacingOrg.Tracker.Pro.Telemetry.Reporter.set_damping(pid, 1.0)

      # Seed at 0, then a held step to 10 over 1 tau (10 x 100 ms samples).
      emit_scalar_full([:racing_org, :speed, :water], :speed_m_s, %{value: 0.0}, 0)
      for n <- 1..10, do: emit_scalar_full([:racing_org, :speed, :water], :speed_m_s, %{value: 10.0}, n * 100)

      flush(pid)
      assert_receive {:report, [:racing_org, :speed, :water, :speed_m_s], %{value: v}}
      # After one tau, ~63% of the way from 0 to 10.
      assert v > 4.0 and v < 9.0
    end

    test "a circular angle field is smoothed across the 0/2π wrap (vector signal)" do
      pid =
        start_reporter([last_value([:racing_org, :velocity, :ground, :vector], reporter_options: [every_ms: 10_000])],
          flush_interval_ms: 10_000
        )

      assert :ok = RacingOrg.Tracker.Pro.Telemetry.Reporter.set_damping(pid, 1.0)

      eps = 0.05
      # Seed just below 2π, then feed angles just above 0 -> must NOT swing toward π.
      emit_vector([:racing_org, :velocity, :ground], :vector, %{angle: 2 * :math.pi() - eps, magnitude: 5.0}, 0)

      for n <- 1..50,
          do: emit_vector([:racing_org, :velocity, :ground], :vector, %{angle: eps, magnitude: 5.0}, n * 100)

      flush(pid)
      assert_receive {:report, [:racing_org, :velocity, :ground, :vector], %{angle: angle}}
      offset = :math.atan2(:math.sin(angle), :math.cos(angle))
      assert abs(offset) < 0.3, "expected smoothed angle near the wrap, got #{angle}"
    end
  end

  describe "application reporter isolation" do
    test "production-shaped smoothing fixtures do not crash the application reporter" do
      application_reporter = Process.whereis(RacingOrg.Tracker.Pro.Telemetry.Reporter)
      assert is_pid(application_reporter)
      monitor_ref = Process.monitor(application_reporter)

      pid =
        start_reporter(
          [last_value([:racing_org, :speed, :water, :speed_m_s], reporter_options: [every_ms: 10_000])],
          flush_interval_ms: 10_000
        )

      emit_scalar_full([:racing_org, :speed, :water], :speed_m_s, %{value: 6.3}, 1_000)
      flush(pid)
      send(application_reporter, :flush_all)

      assert is_map(:sys.get_state(application_reporter))
      refute_receive {:DOWN, ^monitor_ref, :process, ^application_reporter, _reason}
      Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp start_reporter(metrics, opts \\ []) do
    test_pid = self()

    base = [
      metrics: metrics,
      # Flush interval metrics quickly so the timed tests are fast.
      flush_interval_ms: 10,
      callback: fn name, _source_addr, value -> send(test_pid, {:report, name, value}) end
    ]

    {:ok, pid} = RacingOrg.Tracker.Pro.Telemetry.Reporter.start_link(Keyword.merge(base, opts))
    pid
  end

  defp telemetry_execute_value(value) do
    :telemetry.execute([:some, :metric], %{value: value}, %{device_id: {123, 456}})
  end

  # Force a synchronous flush + give the cast/report a beat.
  defp flush(pid) do
    send(pid, :flush_all)
    # Round-trip a call so :flush_all has been processed before we assert.
    :sys.get_state(pid)
    :ok
  end

  defp emit_scalar_full(event, field, value_map, mono_ms) do
    :telemetry.execute(event, %{field => Map.put(value_map, :timestamp, DateTime.utc_now())}, %{
      device_id: @production_device_id,
      timestamp_monotonic_ms: mono_ms
    })
  end

  defp emit_vector(event, field, %{angle: _, magnitude: _} = v, mono_ms) do
    :telemetry.execute(event, %{field => Map.put(v, :timestamp, DateTime.utc_now())}, %{
      device_id: @production_device_id,
      timestamp_monotonic_ms: mono_ms
    })
  end
end
