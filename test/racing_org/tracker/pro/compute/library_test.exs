defmodule RacingOrg.Tracker.Pro.Compute.LibraryTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Compute.Library

  # All signal values are in CATALOG UNITS: speeds in m/s, angles in DEGREES.

  describe "true_wind (flat-water vector triangle + heel correction)" do
    # The ESSENTIAL inputs are apparent_wind_speed / apparent_wind_angle / boat_speed.
    # heel is an OPTIONAL refinement (default 0.0 → no athwartships correction) and
    # pitch/heading are not required. So the minimal apparent-only signal set must
    # compute (the apparent-only pipeline + the sailed-polar Observer depend on this).
    test "apparent-only (no heel, no pitch, no heading): TWS/TWA still compute" do
      signals = %{
        "apparent_wind_speed" => 10.0,
        "apparent_wind_angle" => 90.0,
        "boat_speed" => 10.0
      }

      assert {:ok, out} = Library.compute(:true_wind, signals)
      # Heel absent → no athwartships correction → flat-water triangle:
      #   TW = (0 - 10, 10 - 0) = (-10, 10); TWS = hypot, TWA = 135.
      assert_in_delta out["true_wind_speed"], :math.sqrt(200.0), 1.0e-6
      assert_in_delta out["true_wind_angle"], 135.0, 1.0e-6
      # No heading → no direction output.
      refute Map.has_key?(out, "true_wind_direction")
    end

    # Head-to-wind: AWA = 0, AWS = 10, boat moving 5 m/s straight into the wind.
    # TWS = AWS - boat_speed = 5 m/s; TWA = 0.
    test "head to wind: TWS = AWS - STW, TWA = 0" do
      signals = %{
        "apparent_wind_speed" => 10.0,
        "apparent_wind_angle" => 0.0,
        "boat_speed" => 5.0
      }

      assert {:ok, out} = Library.compute(:true_wind, signals)
      assert_in_delta out["true_wind_speed"], 5.0, 1.0e-6
      assert_in_delta out["true_wind_angle"], 0.0, 1.0e-6
    end

    # Beam apparent wind: AWA = 90 deg (wind on the beam), AWS = 10, boat 10 m/s.
    # Apparent vector (boat frame, x=forward, y=starboard):
    #   AW = (AWS*cos90, AWS*sin90) = (0, 10)
    #   boat contributes (boat_speed, 0) to the apparent; true = apparent - boat motion
    #   TW = (0 - 10, 10 - 0) = (-10, 10)
    #   TWS = hypot(-10,10) = 14.142..., TWA = atan2(10, -10) = 135 deg
    test "beam apparent wind: TWS = hypot, TWA = 135 deg" do
      signals = %{
        "apparent_wind_speed" => 10.0,
        "apparent_wind_angle" => 90.0,
        "boat_speed" => 10.0
      }

      assert {:ok, out} = Library.compute(:true_wind, signals)
      assert_in_delta out["true_wind_speed"], :math.sqrt(200.0), 1.0e-6
      assert_in_delta out["true_wind_angle"], 135.0, 1.0e-6
    end

    test "exposes true_wind_direction relative to heading when heading is present" do
      signals = %{
        "apparent_wind_speed" => 10.0,
        "apparent_wind_angle" => 90.0,
        "boat_speed" => 10.0,
        "heading" => 50.0
      }

      assert {:ok, out} = Library.compute(:true_wind, signals)
      # TWD = heading + TWA, wrapped to [0,360): 50 + 135 = 185
      assert_in_delta out["true_wind_direction"], 185.0, 1.0e-6
    end

    # Heel correction: the masthead measures AWA in the heeled mast frame, where the
    # athwartships component of the horizontal wind is COMPRESSED by cos(heel). The
    # Gentry / Pedrick–McCurdy recovery therefore DIVIDES the measured athwartships
    # component by cos(heel), so the recovered (horizontal) angle is LARGER than the
    # measured one and the recovered TWA/TWS both grow with heel.
    test "heel correction adjusts AWA (recovered angle is larger than flat-water)" do
      flat = %{
        "apparent_wind_speed" => 12.0,
        "apparent_wind_angle" => 45.0,
        "boat_speed" => 6.0,
        "heel" => 0.0
      }

      heeled = %{flat | "heel" => 25.0}

      assert {:ok, out_flat} = Library.compute(:true_wind, flat)
      assert {:ok, out_heel} = Library.compute(:true_wind, heeled)

      # Dividing by cos(heel) RECOVERS the full athwartships component the heeled
      # vane under-read, so the recovered TWA and TWS are strictly larger.
      assert out_heel["true_wind_angle"] > out_flat["true_wind_angle"]
      assert out_heel["true_wind_speed"] > out_flat["true_wind_speed"]
      assert is_float(out_heel["true_wind_speed"])
    end

    # Regression for the inverted heel correction (multiply instead of divide): at
    # AWA 30 and heel 20 the corrected apparent angle must INCREASE vs the measured
    # one. With boat_speed 0 the true wind IS the corrected apparent wind, so TWA
    # directly exposes the corrected angle: atan2(sin30/cos20, cos30) ~ 31.57 deg.
    test "regression: heel 20 at AWA 30 makes the corrected |AWA| LARGER (~31.5), heel 0 is a no-op" do
      base = %{
        "apparent_wind_speed" => 10.0,
        "apparent_wind_angle" => 30.0,
        "boat_speed" => 0.0
      }

      assert {:ok, out_flat} = Library.compute(:true_wind, base)
      assert {:ok, out_heel} = Library.compute(:true_wind, Map.put(base, "heel", 20.0))

      # heel 0 (absent) -> no-op: the "true" wind is the measured apparent wind.
      assert_in_delta out_flat["true_wind_angle"], 30.0, 1.0e-6

      expected =
        :math.atan2(
          :math.sin(30.0 * :math.pi() / 180.0) / :math.cos(20.0 * :math.pi() / 180.0),
          :math.cos(30.0 * :math.pi() / 180.0)
        ) * 180.0 / :math.pi()

      assert out_heel["true_wind_angle"] > 30.0
      assert_in_delta out_heel["true_wind_angle"], expected, 1.0e-6
      assert_in_delta out_heel["true_wind_angle"], 31.5, 0.1
    end

    # Heel is an OPTIONAL refinement defaulting to 0.0: a boat with no heel sensor
    # must produce the SAME output as one explicitly publishing heel = 0.0.
    test "heel absent == heel 0.0 (default, no athwartships correction)" do
      base = %{
        "apparent_wind_speed" => 12.0,
        "apparent_wind_angle" => 45.0,
        "boat_speed" => 6.0
      }

      assert {:ok, out_absent} = Library.compute(:true_wind, base)
      assert {:ok, out_zero} = Library.compute(:true_wind, Map.put(base, "heel", 0.0))

      assert out_absent == out_zero
    end

    test "a hand-verified heel case (AWA 90, heel 60 -> athwartships doubled)" do
      # cos(60deg) = 0.5, so the RECOVERED athwartships component doubles (the heeled
      # vane under-read it by cos(heel); the correction divides to undo that):
      #   corrected apparent y = AWS*sin(90)/cos(60) = 10*1/0.5 = 20
      #   corrected apparent x = AWS*cos(90)         = 0
      #   true = (0 - boat_speed, 20 - 0) = (-10, 20)
      #   TWS = hypot(-10, 20) = sqrt(500), TWA = atan2(20, -10) ~ 116.565 deg
      signals = %{
        "apparent_wind_speed" => 10.0,
        "apparent_wind_angle" => 90.0,
        "boat_speed" => 10.0,
        "heel" => 60.0
      }

      assert {:ok, out} = Library.compute(:true_wind, signals)
      assert_in_delta out["true_wind_speed"], :math.sqrt(500.0), 1.0e-6
      assert_in_delta out["true_wind_angle"], :math.atan2(20.0, -10.0) * 180.0 / :math.pi(), 1.0e-6
    end

    test "extreme heel is clamped: heel beyond 60 deg corrects no further than cos = 0.5" do
      # The divisor is max(cos(heel), 0.5): a bad/knockdown heel reading (>= 60 deg)
      # can at most DOUBLE the athwartships component, never blow the vector up.
      # cos(75) ~ 0.259 would otherwise nearly quadruple it; the clamp pins it to the
      # same output as heel 60 (cos = 0.5 exactly).
      base = %{
        "apparent_wind_speed" => 10.0,
        "apparent_wind_angle" => 90.0,
        "boat_speed" => 10.0
      }

      assert {:ok, at_60} = Library.compute(:true_wind, Map.put(base, "heel", 60.0))
      assert {:ok, at_75} = Library.compute(:true_wind, Map.put(base, "heel", 75.0))
      assert {:ok, at_85} = Library.compute(:true_wind, Map.put(base, "heel", 85.0))

      # Beyond the clamp the divisor is pinned to exactly 0.5, so 75 and 85 deg are
      # byte-identical; 60 deg agrees to float precision (cos(60 deg) via radians is
      # 0.5 only to ~1 ulp). All match the hand computation ay = 10/0.5 = 20:
      # true = (-10, 20) -> TWS = sqrt(500), TWA = atan2(20, -10).
      assert at_85 == at_75
      assert_in_delta at_60["true_wind_speed"], :math.sqrt(500.0), 1.0e-9
      assert_in_delta at_75["true_wind_speed"], :math.sqrt(500.0), 1.0e-9
      assert_in_delta at_75["true_wind_angle"], :math.atan2(20.0, -10.0) * 180.0 / :math.pi(), 1.0e-9
    end

    # Regression lock: the heel-present output is byte-identical to the prior
    # (heel-and-pitch-required) implementation — pitch never participated, so its
    # absence cannot change a thing.
    test "heel-present output is unchanged whether pitch is present or absent" do
      heeled = %{
        "apparent_wind_speed" => 10.0,
        "apparent_wind_angle" => 90.0,
        "boat_speed" => 10.0,
        "heel" => 60.0
      }

      assert {:ok, out_without_pitch} = Library.compute(:true_wind, heeled)
      assert {:ok, out_with_pitch} = Library.compute(:true_wind, Map.put(heeled, "pitch", 12.0))

      assert out_with_pitch == out_without_pitch
    end

    test "an ESSENTIAL input missing is invalid (no apparent_wind_angle)" do
      assert :invalid =
               Library.compute(:true_wind, %{"apparent_wind_speed" => 10.0, "boat_speed" => 5.0})
    end
  end

  describe "vmg (boat speed projected onto the wind axis)" do
    # VMG = boat_speed * cos(TWA). With TWA derived from heading + TWD.
    # Simplest closed case: provide true_wind_direction + heading + boat_speed.
    # TWA = TWD - heading. boat_speed = 6, TWA = 0 -> sailing straight into the wind:
    # VMG upwind = 6 * cos(0) = 6.
    test "straight into the wind: VMG = boat_speed" do
      signals = %{
        "boat_speed" => 6.0,
        "true_wind_direction" => 0.0,
        "heading" => 0.0
      }

      assert {:ok, out} = Library.compute(:vmg, signals)
      assert_in_delta out["vmg"], 6.0, 1.0e-6
    end

    # 60 deg off the wind: VMG = 6 * cos(60) = 3.
    test "60 degrees off the wind: VMG = boat_speed * cos(60)" do
      signals = %{
        "boat_speed" => 6.0,
        "true_wind_direction" => 60.0,
        "heading" => 0.0
      }

      assert {:ok, out} = Library.compute(:vmg, signals)
      assert_in_delta out["vmg"], 3.0, 1.0e-6
    end

    test "missing inputs are invalid" do
      assert :invalid = Library.compute(:vmg, %{"boat_speed" => 6.0})
    end
  end

  describe "vmc (SOG projected onto the bearing to the active mark)" do
    # With a bearing_to_mark provided: VMC = sog * cos(bearing_to_mark - cog).
    test "with bearing_to_mark + cog: VMC = sog * cos(diff)" do
      signals = %{
        "sog" => 8.0,
        "cog" => 30.0,
        "bearing_to_mark" => 30.0
      }

      assert {:ok, out} = Library.compute(:vmc, signals)
      assert_in_delta out["vmc"], 8.0, 1.0e-6
    end

    test "60 deg off the mark bearing: VMC = sog * cos(60)" do
      signals = %{
        "sog" => 8.0,
        "cog" => 30.0,
        "bearing_to_mark" => 90.0
      }

      assert {:ok, out} = Library.compute(:vmc, signals)
      assert_in_delta out["vmc"], 4.0, 1.0e-6
    end

    # No bearing-to-mark source on-device yet -> honestly invalid rather than faked.
    test "without a bearing-to-mark source, vmc is invalid" do
      assert :invalid = Library.compute(:vmc, %{"sog" => 8.0, "cog" => 30.0})
    end
  end

  describe "unknown library key" do
    test "is invalid" do
      assert :invalid = Library.compute(:nonsense, %{})
    end
  end
end
