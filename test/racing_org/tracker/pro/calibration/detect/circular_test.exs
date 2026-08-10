defmodule RacingOrg.Tracker.Pro.Calibration.Detect.CircularTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Detect.Circular

  describe "normalize/1" do
    test "returns positive zero for negative full rotations" do
      normalized = Circular.normalize(-360.0)

      assert normalized == 0.0
      assert <<0::1, _magnitude::63>> = <<normalized::float-64>>
    end

    test "canonicalizes floating remainder edge cases below 360 degrees" do
      assert Circular.normalize(-1.0e-14) == 0.0

      for input <- [-720.0, -360.0, -1.0e-14, -0.0, 0.0, 360.0, 720.0] do
        normalized = Circular.normalize(input)
        assert normalized >= 0.0
        assert normalized < 360.0
      end
    end
  end
end
