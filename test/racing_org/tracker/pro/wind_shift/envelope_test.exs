Code.require_file("support/wind_gen_helper.exs", __DIR__)

defmodule RacingOrg.Tracker.Pro.WindShift.EnvelopeTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WindShift.Envelope
  alias RacingOrg.Tracker.Pro.WindShift.WindGen

  test "snapshot before any update is empty" do
    snap = Envelope.snapshot(Envelope.new())
    assert snap == %{min_deg: nil, max_deg: nil, range_deg: nil, new_extreme: :none}
  end

  test "min/max/range track a simple sequence and slide out of the window" do
    env = Envelope.new(window_s: 60, warmup_s: 0)

    env =
      Enum.reduce(Enum.with_index([100.0, 110.0, 90.0, 100.0, 100.0]), env, fn {twd, i}, e ->
        Envelope.update(e, twd, i * 1000)
      end)

    snap = Envelope.snapshot(env)
    assert_in_delta snap.min_deg, 90.0, 1.0e-9
    assert_in_delta snap.max_deg, 110.0, 1.0e-9
    assert_in_delta snap.range_deg, 20.0, 1.0e-9

    # 70 s later a single 100 remains: the old extremes have expired.
    env = Envelope.update(env, 100.0, 75_000)
    snap = Envelope.snapshot(env)
    assert_in_delta snap.min_deg, 100.0, 1.0e-9
    assert_in_delta snap.max_deg, 100.0, 1.0e-9
    assert_in_delta snap.range_deg, 0.0, 1.0e-9
  end

  # Acceptance 6 — range tracks scripted extremes within +/-1 deg, across the
  # 350 <-> 10 wrap.
  test "range tracks a noiseless oscillation around north within 1 deg" do
    samples = WindGen.generate([%{dur_s: 900, base: 0.0, osc: {10.0, 360}}])

    env =
      Enum.reduce(samples, Envelope.new(), fn %{t_ms: t, twd_deg: twd}, e ->
        Envelope.update(e, twd, t)
      end)

    snap = Envelope.snapshot(env)
    assert_in_delta snap.range_deg, 20.0, 1.0
    # Wrapped display: min just below north, max just above.
    assert_in_delta snap.min_deg, 350.0, 1.0
    assert_in_delta snap.max_deg, 10.0, 1.0
  end

  # Acceptance 6 — the New-High alarm fires exactly once per excursion, with the
  # 60 s debounce suppressing a second out-of-range reading.
  test "new-high alarm fires once per excursion and is debounced" do
    script = [
      # 30 min establishes the +/-10 range (well past the default warmup).
      %{dur_s: 1800, base: 0.0, osc: {10.0, 360}},
      # Excursion 1: jump to +17 (beyond max 10 + margin 2) at t = 1800 s.
      %{dur_s: 10, base: 17.0},
      # Back inside the range.
      %{dur_s: 30, base: 0.0, osc: {10.0, 360}},
      # Excursion 2 at t = 1840 s: beyond the window max even with noise, but
      # only 40 s after alarm 1 -> debounced.
      %{dur_s: 10, base: 23.0},
      # Back inside for 2 min.
      %{dur_s: 120, base: 0.0, osc: {10.0, 360}},
      # Excursion 3 at t = 1970 s: 170 s after alarm 1 -> fires again.
      %{dur_s: 10, base: 28.0},
      %{dur_s: 30, base: 0.0, osc: {10.0, 360}}
    ]

    samples = WindGen.generate(script, noise_sigma: 0.2)

    {_env, alarms} =
      Enum.reduce(samples, {Envelope.new(), []}, fn %{t_ms: t, twd_deg: twd}, {e, alarms} ->
        e = Envelope.update(e, twd, t)

        case Envelope.snapshot(e).new_extreme do
          :none -> {e, alarms}
          kind -> {e, [{t, kind} | alarms]}
        end
      end)

    alarms = Enum.reverse(alarms)

    assert [{t1, :high}, {t2, :high}] = alarms
    assert_in_delta t1, 1_800_000, 2000
    assert_in_delta t2, 1_970_000, 2000
    assert t2 - t1 >= 60_000
  end

  test "new-low alarm fires on a drop below the window minimum" do
    env = Envelope.new(warmup_s: 0, margin_deg: 2.0)

    env =
      Enum.reduce(0..119, env, fn i, e -> Envelope.update(e, 100.0, i * 1000) end)

    env = Envelope.update(env, 95.0, 120_000)
    assert Envelope.snapshot(env).new_extreme == :low
  end

  test "no alarms during the warmup period" do
    env = Envelope.new(warmup_s: 300)

    {_env, fired} =
      Enum.reduce(0..250, {env, false}, fn i, {e, fired} ->
        # A staircase that keeps setting new extremes.
        e = Envelope.update(e, 100.0 + i * 3.0, i * 1000)
        {e, fired or Envelope.snapshot(e).new_extreme != :none}
      end)

    refute fired
  end

  test "the alarm margin is honored" do
    env = Envelope.new(warmup_s: 0, margin_deg: 2.0)
    env = Enum.reduce(0..59, env, fn i, e -> Envelope.update(e, 100.0, i * 1000) end)

    # +1.5 deg above the max: inside the margin, no alarm.
    env = Envelope.update(env, 101.5, 60_000)
    assert Envelope.snapshot(env).new_extreme == :none

    # +2.5 deg above the (new) max of 101.5: outside the margin, alarm.
    env = Envelope.update(env, 104.5, 61_000)
    assert Envelope.snapshot(env).new_extreme == :high
  end
end
