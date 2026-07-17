Code.require_file("support/wind_gen_helper.exs", __DIR__)

defmodule RacingOrg.Tracker.Pro.WindShift.MeansTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WindShift.Means
  alias RacingOrg.Tracker.Pro.WindShift.WindGen

  test "snapshot before any update is all nil" do
    snap = Means.snapshot(Means.new())
    assert snap == %{fast: nil, mid: nil, slow: nil, phase_deg: nil, stability: nil}
  end

  test "constant input converges every timescale to the input with zero phase" do
    means = feed(Means.new(), List.duplicate(200.0, 600), 0)
    snap = Means.snapshot(means)

    assert_in_delta snap.fast, 200.0, 0.01
    assert_in_delta snap.mid, 200.0, 0.01
    assert_in_delta snap.slow, 200.0, 0.01
    assert_in_delta snap.phase_deg, 0.0, 0.01
    assert_in_delta snap.stability, 1.0, 0.01
  end

  # Acceptance 7 — a known deviation of the fast mean from the slow mean is
  # recovered as phase_deg.
  test "a scripted +10 deg excursion is recovered as positive phase_deg" do
    samples =
      WindGen.generate([%{dur_s: 2400, base: 200.0}, %{dur_s: 180, base: 210.0}],
        noise_sigma: 0.5
      )

    means =
      Enum.reduce(samples, Means.new(), fn %{t_ms: t, twd_deg: twd}, m ->
        Means.update(m, twd, t)
      end)

    snap = Means.snapshot(means)
    # Fast (tau 30 s) has converged onto 210; slow (tau 1500 s) has crept up by
    # ~10 * (1 - exp(-180/1500)) ~= 1.1 deg, so the recovered phase is ~+8.9 deg.
    assert_in_delta snap.phase_deg, 8.9, 1.5
  end

  test "phase deviation is recovered across the 0/360 wrap" do
    samples =
      WindGen.generate([%{dur_s: 2400, base: 355.0}, %{dur_s: 180, base: 5.0}],
        noise_sigma: 0.5
      )

    means =
      Enum.reduce(samples, Means.new(), fn %{t_ms: t, twd_deg: twd}, m ->
        Means.update(m, twd, t)
      end)

    snap = Means.snapshot(means)
    assert_in_delta snap.phase_deg, 8.9, 1.5
    # Wrapped display values on each side of north.
    assert snap.fast > 350.0 or snap.fast < 10.0
  end

  # Acceptance 7 — documented gap behavior: a gap > ~3*tau_fast effectively
  # resets the fast mean onto the next sample while the slow mean barely moves.
  test "a 300 s gap resets the fast mean but only nudges the slow mean" do
    means = feed(Means.new(), List.duplicate(200.0, 2400), 0)

    # One sample at 240 deg after a 300 s gap (10x tau_fast).
    gap_t = 2400 * 1000 + 300_000
    means = Means.update(means, 240.0, gap_t)
    snap = Means.snapshot(means)

    assert_in_delta snap.fast, 240.0, 1.0
    # Slow moved by at most 40 * (1 - exp(-300/1500)) ~= 7.3 deg.
    assert snap.slow < 210.0
    assert snap.slow > 199.0
  end

  test "stability drops when the wind direction is widely dispersed" do
    # Alternate +/-50 deg around 200 every second for 2000 s: the resultant of
    # the unit-vector EWMA collapses toward cos(50 deg) ~= 0.64.
    twds = Enum.map(0..1999, fn i -> if rem(i, 2) == 0, do: 150.0, else: 250.0 end)
    means = feed(Means.new(), twds, 0)
    snap = Means.snapshot(means)

    assert snap.stability < 0.8
    assert snap.stability > 0.3
  end

  test "custom time constants are honored" do
    means = Means.new(tau_fast_s: 5.0, tau_mid_s: 50.0, tau_slow_s: 500.0)
    means = feed(means, List.duplicate(100.0, 100), 0)
    # Step to 120 for 20 s: tau 5 fast mean is nearly there, tau 500 is not.
    means = feed(means, List.duplicate(120.0, 20), 100 * 1000)
    snap = Means.snapshot(means)

    assert_in_delta snap.fast, 120.0, 1.0
    assert snap.slow < 105.0
  end

  defp feed(means, twds, t0_ms) do
    twds
    |> Enum.with_index()
    |> Enum.reduce(means, fn {twd, i}, m -> Means.update(m, twd, t0_ms + i * 1000) end)
  end
end
