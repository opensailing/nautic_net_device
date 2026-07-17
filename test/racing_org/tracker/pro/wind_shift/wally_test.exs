defmodule RacingOrg.Tracker.Pro.WindShift.WallyTest do
  @moduledoc """
  Pure WALLY (shift-phase target modulation) math: the half-the-shift delta rule
  with its clamp, and the activation gates (oscillating regime, confidence,
  lift deadband, upwind-only).
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WindShift.Wally

  # A fully-active baseline: oscillating regime, confident, well past the
  # deadband, upwind on starboard tack.
  defp active_inputs(overrides \\ %{}) do
    Map.merge(
      %{wind_lift_deg: 8.0, wind_regime: 2, shift_confidence: 80.0, twa_deg: 40.0},
      overrides
    )
  end

  describe "delta_deg/2 — pinch/foot by HALF the shift, clamped" do
    test "half the lift, signed: +8 deg lift -> +4 deg (foot)" do
      assert Wally.delta_deg(8.0) == 4.0
    end

    test "half the header, signed: -8 deg lift -> -4 deg (pinch)" do
      assert Wally.delta_deg(-8.0) == -4.0
    end

    test "clamps at the default +/-6 deg" do
      assert Wally.delta_deg(20.0) == 6.0
      assert Wally.delta_deg(-20.0) == -6.0
      # Exactly at the clamp boundary: lift 12 -> delta 6, untouched.
      assert Wally.delta_deg(12.0) == 6.0
    end

    test "a small shift modulates proportionally (no minimum step)" do
      assert Wally.delta_deg(3.0) == 1.5
      assert Wally.delta_deg(-3.0) == -1.5
    end

    test ":max_delta_deg overrides the clamp" do
      assert Wally.delta_deg(20.0, max_delta_deg: 4.0) == 4.0
      assert Wally.delta_deg(-20.0, max_delta_deg: 4.0) == -4.0
    end
  end

  describe "active?/1 — the gates (ALL must hold)" do
    test "active when oscillating + confident + past deadband + upwind" do
      assert Wally.active?(active_inputs())
    end

    test "sign/tack coverage: lifted and headed on both tacks are all active upwind" do
      # Lifted starboard (twa +40, lift +8) / lifted port (twa -40, lift +8).
      assert Wally.active?(active_inputs(%{twa_deg: 40.0, wind_lift_deg: 8.0}))
      assert Wally.active?(active_inputs(%{twa_deg: -40.0, wind_lift_deg: 8.0}))
      # Headed starboard / headed port (lift -8).
      assert Wally.active?(active_inputs(%{twa_deg: 40.0, wind_lift_deg: -8.0}))
      assert Wally.active?(active_inputs(%{twa_deg: -40.0, wind_lift_deg: -8.0}))
    end

    test "deadband: |lift| < 2.0 deg is inactive; exactly 2.0 is active (both signs)" do
      refute Wally.active?(active_inputs(%{wind_lift_deg: 1.9}))
      refute Wally.active?(active_inputs(%{wind_lift_deg: -1.9}))
      assert Wally.active?(active_inputs(%{wind_lift_deg: 2.0}))
      assert Wally.active?(active_inputs(%{wind_lift_deg: -2.0}))
    end

    test "any regime other than 2 (oscillating) is inactive" do
      for regime <- [0, 1, 3, 4, 5] do
        refute Wally.active?(active_inputs(%{wind_regime: regime})),
               "regime #{regime} must be inactive"
      end

      # The engine hands the regime code through as a float; 2.0 still gates open.
      assert Wally.active?(active_inputs(%{wind_regime: 2.0}))
    end

    test "confidence 49 is inactive; 50 is active" do
      refute Wally.active?(active_inputs(%{shift_confidence: 49.0}))
      assert Wally.active?(active_inputs(%{shift_confidence: 50.0}))
    end

    test "downwind is inactive (|twa| >= 90; downwind Wally is a later refinement)" do
      refute Wally.active?(active_inputs(%{twa_deg: 120.0}))
      refute Wally.active?(active_inputs(%{twa_deg: -120.0}))
      refute Wally.active?(active_inputs(%{twa_deg: 90.0}))
      assert Wally.active?(active_inputs(%{twa_deg: 89.9}))
    end

    test "missing or non-numeric inputs are inactive (fail-safe off)" do
      refute Wally.active?(%{})
      refute Wally.active?(active_inputs(%{wind_lift_deg: nil}))
      refute Wally.active?(active_inputs(%{wind_regime: nil}))
      refute Wally.active?(active_inputs(%{shift_confidence: nil}))
      refute Wally.active?(active_inputs(%{twa_deg: nil}))
    end
  end

  describe "mode_code/1 — the policy string as an engine-signal int" do
    test "maps the three policy modes" do
      assert Wally.mode_code("off") == 0
      assert Wally.mode_code("shadow") == 1
      assert Wally.mode_code("on") == 2
    end

    test "anything unknown is 0 (fail-safe off)" do
      assert Wally.mode_code(nil) == 0
      assert Wally.mode_code("bogus") == 0
    end
  end
end
