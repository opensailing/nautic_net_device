defmodule RacingOrg.Tracker.Pro.Polar.Observer.GateTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Polar.Observer.Gate

  # A baseline qualifying sample: upwind-ish, steady, level, under sail.
  defp sample(overrides \\ %{}) do
    base = %{
      t_ms: 0,
      tws_mps: 6.0,
      twa_deg: 45.0,
      stw_mps: 4.0,
      heading_deg: 100.0,
      heel_deg: 15.0
    }

    Map.merge(base, Map.new(overrides))
  end

  # Build a steady window of `n` samples at 1 Hz that all qualify, ending at the
  # given current sample (most-recent LAST). Heading/STW/TWS held constant.
  defp steady_window(n, cur \\ sample()) do
    for i <- 0..(n - 1) do
      Map.merge(cur, %{t_ms: i * 1000})
    end
  end

  defp gate(opts), do: Gate.new(opts)

  describe "happy path" do
    test "admits a steady, level, on-angle, dwelled sample" do
      g = gate(min_dwell: 10)
      window = steady_window(10)
      assert :admit = Gate.evaluate(g, window)
    end
  end

  describe "no-go / maneuver exclusion (wind angle band)" do
    test "rejects a sample inside the no-go zone (twa < 25)" do
      g = gate(min_dwell: 1)
      window = [sample(%{twa_deg: 15.0})]
      assert {:reject, :no_go_angle} = Gate.evaluate(g, window)
    end

    test "rejects a dead-downwind sample (twa > 165)" do
      g = gate(min_dwell: 1)
      window = [sample(%{twa_deg: 172.0})]
      assert {:reject, :no_go_angle} = Gate.evaluate(g, window)
    end

    test "folds the wind angle before testing the band (-15 -> 15 -> reject)" do
      g = gate(min_dwell: 1)
      assert {:reject, :no_go_angle} = Gate.evaluate(g, [sample(%{twa_deg: -15.0})])
    end

    test "admits exactly at the lower band edge (25 deg)" do
      g = gate(min_dwell: 1)
      assert :admit = Gate.evaluate(g, [sample(%{twa_deg: 25.0})])
    end

    test "admits exactly at the upper band edge (165 deg)" do
      g = gate(min_dwell: 1)
      assert :admit = Gate.evaluate(g, [sample(%{twa_deg: 165.0})])
    end

    test "can be driven off an AWA field instead of TWA" do
      g = gate(min_dwell: 1, angle_key: :awa_deg)
      assert {:reject, :no_go_angle} = Gate.evaluate(g, [sample(%{twa_deg: 45.0, awa_deg: 10.0})])
      assert :admit = Gate.evaluate(g, [sample(%{twa_deg: 45.0, awa_deg: 35.0})])
    end
  end

  describe "steady wind (TWS stddev over the window)" do
    test "rejects when TWS varies more than the threshold" do
      g = gate(min_dwell: 1, max_tws_sd_mps: 0.2572)
      # alternate 5 and 7 m/s -> sd ~1.0 m/s >> threshold
      window =
        for {tws, i} <- Enum.with_index([5.0, 7.0, 5.0, 7.0, 5.0]) do
          sample(%{tws_mps: tws, t_ms: i * 1000})
        end

      assert {:reject, :unsteady_wind} = Gate.evaluate(g, window)
    end

    test "admits when TWS is within the steadiness threshold" do
      g = gate(min_dwell: 1, max_tws_sd_mps: 0.2572)
      # tiny jitter under half a knot
      window =
        for {tws, i} <- Enum.with_index([6.0, 6.05, 5.95, 6.02, 5.98]) do
          sample(%{tws_mps: tws, t_ms: i * 1000})
        end

      assert :admit = Gate.evaluate(g, window)
    end
  end

  describe "rate of turn (steady heading)" do
    test "rejects when heading changes faster than the threshold" do
      g = gate(min_dwell: 1, max_turn_rate_dps: 3.0)
      # 100 -> 130 over 2 s = 15 deg/s -> a tack/gybe
      window = [
        sample(%{heading_deg: 100.0, t_ms: 0}),
        sample(%{heading_deg: 115.0, t_ms: 1000}),
        sample(%{heading_deg: 130.0, t_ms: 2000})
      ]

      assert {:reject, :turning} = Gate.evaluate(g, window)
    end

    test "handles the 0/360 wrap when computing turn rate" do
      g = gate(min_dwell: 1, max_turn_rate_dps: 3.0)
      # 358 -> 2 is a 4 deg change across the wrap (2 deg/s), NOT 356.
      window = [
        sample(%{heading_deg: 358.0, t_ms: 0}),
        sample(%{heading_deg: 2.0, t_ms: 2000})
      ]

      assert :admit = Gate.evaluate(g, window)
    end

    test "admits gentle steering below the threshold" do
      g = gate(min_dwell: 1, max_turn_rate_dps: 3.0)
      # 2 deg/s
      window = [
        sample(%{heading_deg: 100.0, t_ms: 0}),
        sample(%{heading_deg: 104.0, t_ms: 2000})
      ]

      assert :admit = Gate.evaluate(g, window)
    end
  end

  describe "acceleration (quasi-steady STW)" do
    test "rejects when boat speed is accelerating" do
      g = gate(min_dwell: 1, max_accel_mps2: 0.05)
      # 4.0 -> 5.0 over 2 s = 0.5 m/s^2
      window = [
        sample(%{stw_mps: 4.0, t_ms: 0}),
        sample(%{stw_mps: 5.0, t_ms: 2000})
      ]

      assert {:reject, :accelerating} = Gate.evaluate(g, window)
    end

    test "admits when boat speed is essentially constant" do
      g = gate(min_dwell: 1, max_accel_mps2: 0.05)

      window = [
        sample(%{stw_mps: 4.00, t_ms: 0}),
        sample(%{stw_mps: 4.02, t_ms: 2000})
      ]

      assert :admit = Gate.evaluate(g, window)
    end
  end

  describe "heel band" do
    test "rejects heel outside the configured band" do
      g = gate(min_dwell: 1, heel_band_deg: {-45.0, 45.0})
      assert {:reject, :heel_out_of_band} = Gate.evaluate(g, [sample(%{heel_deg: 60.0})])
      assert {:reject, :heel_out_of_band} = Gate.evaluate(g, [sample(%{heel_deg: -60.0})])
    end

    test "admits heel at the band edges" do
      g = gate(min_dwell: 1, heel_band_deg: {-45.0, 45.0})
      assert :admit = Gate.evaluate(g, [sample(%{heel_deg: 45.0})])
      assert :admit = Gate.evaluate(g, [sample(%{heel_deg: -45.0})])
    end

    test "admits (skips the check) when no heel signal is present" do
      # Heel is an accuracy ENHANCER, never an availability gate: with no heel
      # sensor the gate cannot judge the band and must not reject on that basis —
      # mirroring how the motoring check skips without an engine signal. A boat
      # with no heel feed still accumulates a sailed polar.
      g = gate(min_dwell: 1)
      assert :admit = Gate.evaluate(g, [Map.delete(sample(), :heel_deg)])
    end

    test "an explicit nil heel is 'absent' too (skipped, not rejected)" do
      g = gate(min_dwell: 1)
      assert :admit = Gate.evaluate(g, [sample(%{heel_deg: nil})])
    end

    test "a full heel-less window still dwells and admits" do
      # Every sample in the window lacks heel: the per-sample sweep must not turn
      # the missing signal into a dwell-breaking rejection.
      g = gate(min_dwell: 10)
      window = for s <- steady_window(10), do: Map.delete(s, :heel_deg)
      assert :admit = Gate.evaluate(g, window)
    end
  end

  describe "minimum dwell (N consecutive qualifying samples)" do
    test "rejects when the window is shorter than the dwell requirement" do
      g = gate(min_dwell: 10)
      window = steady_window(9)
      assert {:reject, :insufficient_dwell} = Gate.evaluate(g, window)
    end

    test "rejects when a recent sample in the window failed a gate" do
      g = gate(min_dwell: 5)
      # 5 samples, but the 3rd is a hard turn -> the window is not 5-in-a-row good
      window = [
        sample(%{t_ms: 0, heading_deg: 100.0}),
        sample(%{t_ms: 1000, heading_deg: 100.0}),
        sample(%{t_ms: 2000, heading_deg: 130.0}),
        sample(%{t_ms: 3000, heading_deg: 130.0}),
        sample(%{t_ms: 4000, heading_deg: 130.0})
      ]

      assert {:reject, _reason} = Gate.evaluate(g, window)
    end

    test "admits exactly at the dwell count" do
      g = gate(min_dwell: 5)
      assert :admit = Gate.evaluate(g, steady_window(5))
    end
  end

  describe "motoring exclusion (optional signal)" do
    test "rejects when under_power? is true" do
      g = gate(min_dwell: 1)
      assert {:reject, :motoring} = Gate.evaluate(g, [sample(%{under_power?: true})])
    end

    test "admits when under_power? is explicitly false" do
      g = gate(min_dwell: 1)
      assert :admit = Gate.evaluate(g, [sample(%{under_power?: false})])
    end

    test "admits (skips the check) when no motoring signal is present" do
      # No :under_power? key at all -> the gate cannot detect motoring and must
      # NOT reject on that basis; contamination is mitigated only by the other
      # gates (and by STW-based wind downstream). This is the documented path for
      # devices without an engine-RPM / under-power signal.
      g = gate(min_dwell: 1)
      assert :admit = Gate.evaluate(g, [sample()])
    end

    test "engine_rpm above idle threshold also rejects as motoring" do
      g = gate(min_dwell: 1, engine_rpm_idle: 100.0)
      assert {:reject, :motoring} = Gate.evaluate(g, [sample(%{engine_rpm: 1500.0})])
      assert :admit = Gate.evaluate(g, [sample(%{engine_rpm: 0.0})])
    end
  end

  describe "reason precedence is stable" do
    test "an empty window is rejected for insufficient dwell" do
      assert {:reject, :insufficient_dwell} = Gate.evaluate(gate(min_dwell: 1), [])
    end
  end
end
