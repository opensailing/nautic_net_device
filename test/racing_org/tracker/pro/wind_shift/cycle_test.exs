defmodule RacingOrg.Tracker.Pro.WindShift.CycleTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WindShift.Cycle

  @two_pi 2.0 * :math.pi()

  test "snapshot before any step is all nil" do
    snap = Cycle.snapshot(Cycle.new())
    assert snap.level_deg == nil
    assert snap.trend_deg_per_hr == nil
    assert snap.amplitude_deg == nil
    assert snap.phase_rad == nil
  end

  test "constant input pins the level with negligible trend and amplitude" do
    cycle = feed(Cycle.new(), fn _t -> 100.0 end, 600)
    snap = Cycle.snapshot(cycle)

    assert_in_delta snap.level_deg, 100.0, 0.5
    assert abs(snap.trend_deg_per_hr) < 1.0
    assert snap.amplitude_deg < 1.0
    assert snap.innovation_var > 0.0
  end

  test "a pure sinusoid is captured by the cycle states, not the trend" do
    # 10 deg amplitude, 480 s period, 2400 steps at 1 Hz (5 periods).
    cycle = Cycle.new(period_s: 480.0)
    cycle = feed(cycle, fn t -> 200.0 + 10.0 * :math.sin(@two_pi * t / 480.0) end, 2400)
    snap = Cycle.snapshot(cycle)

    assert_in_delta snap.amplitude_deg, 10.0, 2.0
    assert abs(snap.trend_deg_per_hr) < 2.0
    assert_in_delta snap.level_deg, 200.0, 2.0
  end

  test "a linear ramp is captured by the trend with an honest standard error" do
    # 6 deg/h ramp over one hour.
    cycle = feed(Cycle.new(), fn t -> 200.0 + 6.0 * t / 3600.0 end, 3600)
    snap = Cycle.snapshot(cycle)

    assert_in_delta snap.trend_deg_per_hr, 6.0, 1.5
    assert snap.trend_se_deg_per_hr > 0.0
    assert snap.trend_deg_per_hr - 1.96 * snap.trend_se_deg_per_hr <= 6.0
    assert snap.trend_deg_per_hr + 1.96 * snap.trend_se_deg_per_hr >= 6.0
  end

  test "retune re-anchors the cycle frequency" do
    cycle = Cycle.new(period_s: 480.0)
    assert_in_delta Cycle.snapshot(cycle).period_s, 480.0, 1.0e-9

    cycle = Cycle.retune(cycle, 600.0)
    assert_in_delta Cycle.snapshot(cycle).period_s, 600.0, 1.0e-9
  end

  test "time_from_phase rotates the phase BACKWARD toward the target" do
    # phase_rad = atan2(psi*, psi) DECREASES at 2*pi/period per second, so from
    # phase pi/2 the cycle reaches phase 0 a quarter period later.
    assert_in_delta Cycle.time_from_phase(:math.pi() / 2.0, 480.0, 0.0), 120.0, 1.0e-6
    # ... and reaching pi/2 from 0 takes three quarters of a period (wraps).
    assert_in_delta Cycle.time_from_phase(0.0, 480.0, :math.pi() / 2.0), 360.0, 1.0e-6
    # Reaching the phase you are at is "now".
    assert_in_delta Cycle.time_from_phase(1.0, 480.0, 1.0), 0.0, 1.0e-6
  end

  test "time_to_phase matches the scripted sinusoid's next falling zero" do
    # Truth: y = 10*sin(2*pi*t/480). Feed up to t = 2520 s, i.e. phase fraction
    # 0.25 (positive peak). The next falling zero of the deviation (target phase
    # -pi/2, where the cycle contribution cos(theta) crosses 0 downward) is
    # 120 s away in truth.
    cycle = Cycle.new(period_s: 480.0)
    cycle = feed(cycle, fn t -> 200.0 + 10.0 * :math.sin(@two_pi * t / 480.0) end, 2521)

    t = Cycle.time_to_phase(cycle, -:math.pi() / 2.0)
    assert_in_delta t, 120.0, 60.0
  end

  test "forecast extrapolates the trend and its CI grows with the horizon" do
    cycle = feed(Cycle.new(), fn t -> 200.0 + 36.0 * t / 3600.0 end, 3600)

    # 36 deg/h: 10 minutes ahead is +6 deg.
    f = Cycle.forecast(cycle, 600.0)
    now = Cycle.snapshot(cycle).level_deg
    assert_in_delta f.twd_deg - now, 6.0, 2.0

    ci_60 = Cycle.forecast(cycle, 60.0).ci_deg
    ci_300 = Cycle.forecast(cycle, 300.0).ci_deg
    ci_900 = Cycle.forecast(cycle, 900.0).ci_deg
    assert ci_60 > 0.0
    assert ci_60 < ci_300
    assert ci_300 < ci_900
  end

  test "the filter is rate-independent: 2 Hz and 1 Hz see the same wall-clock response" do
    ramp = fn t -> 100.0 + 12.0 * t / 3600.0 end

    one_hz = feed(Cycle.new(), ramp, 1800)

    two_hz =
      Enum.reduce(1..3600, Cycle.new(), fn i, c ->
        Cycle.step(c, ramp.(i * 0.5), 0.5)
      end)

    a = Cycle.snapshot(one_hz)
    b = Cycle.snapshot(two_hz)
    assert_in_delta a.level_deg, b.level_deg, 0.5
    assert_in_delta a.trend_deg_per_hr, b.trend_deg_per_hr, 1.0
  end

  test "all snapshot fields stay finite over a long mixed run" do
    cycle =
      feed(
        Cycle.new(),
        fn t -> 200.0 + 8.0 * :math.sin(@two_pi * t / 540.0) + 6.0 * t / 3600.0 end,
        3600
      )

    snap = Cycle.snapshot(cycle)

    for key <- [:level_deg, :trend_deg_per_hr, :trend_se_deg_per_hr, :amplitude_deg, :phase_rad, :innovation_var] do
      value = Map.fetch!(snap, key)
      assert is_float(value), "#{key} not a float: #{inspect(value)}"
    end
  end

  defp feed(cycle, truth_fn, steps) do
    Enum.reduce(1..steps, cycle, fn t, c -> Cycle.step(c, truth_fn.(t * 1.0), 1.0) end)
  end
end
