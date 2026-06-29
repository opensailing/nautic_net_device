defmodule RacingOrg.Tracker.Pro.Compute.PgnEncodeTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Compute.PgnEncode

  # We assert round-trip correctness: PgnEncode emits a payload that, decoded by the
  # SAME deps' decoders the device uses to RECEIVE these PGNs, recovers the input
  # within scaling tolerance. That guarantees ENCODE is the inverse of DECODE.
  alias RacingOrg.Tracker.NMEA2000.J1939

  @deg_per_rad 180.0 / :math.pi()

  # Catalog units: speeds m/s, angles DEGREES, depth m, temperature Kelvin (the
  # NMEA-native unit). The engine output for a 130312 def is already Kelvin and
  # scales straight to the wire (no offset).

  defp def_for(pgn, overrides) do
    Map.merge(
      %{
        output_pgn: pgn,
        output_field: nil,
        output_reference: nil,
        output_unit: nil,
        output_instance: nil
      },
      overrides
    )
  end

  describe "130306 Wind — speed + angle + reference" do
    test "encodes a single-scalar speed def and round-trips speed" do
      d = def_for(130_306, %{output_field: "wind_speed", output_reference: "apparent"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 6.0})
      assert byte_size(payload) == 8

      decoded = J1939.WindDataParams.decode(payload)
      assert_in_delta decoded.wind_speed, 6.0, 0.01
      assert decoded.wind_reference == :apparent
    end

    test "a true_wind library calc fills BOTH wind_speed and wind_angle with reference=true" do
      d = def_for(130_306, %{output_field: "wind_speed", output_reference: "true"})
      outputs = %{"true_wind_speed" => 7.5, "true_wind_angle" => 35.0, "true_wind_direction" => 200.0}

      assert {:ok, payload} = PgnEncode.encode(d, outputs)
      decoded = J1939.WindDataParams.decode(payload)

      assert_in_delta decoded.wind_speed, 7.5, 0.01
      # 35 deg -> radians; decoder yields radians.
      assert_in_delta decoded.wind_angle, 35.0 / @deg_per_rad, 0.001
      # reference "true" must map to a TRUE wind reference (boat- or water-referenced),
      # never :apparent.
      assert decoded.wind_reference in [:true_boat_referenced, :true_water_referenced, :true_ground_referenced]
    end

    test "wind angle wraps negative degrees into [0,2pi) on the wire (u16 angle)" do
      d = def_for(130_306, %{output_field: "wind_speed", output_reference: "true"})
      # -10 deg should encode as 350 deg.
      outputs = %{"true_wind_speed" => 5.0, "true_wind_angle" => -10.0}
      assert {:ok, payload} = PgnEncode.encode(d, outputs)
      decoded = J1939.WindDataParams.decode(payload)
      assert_in_delta decoded.wind_angle, 350.0 / @deg_per_rad, 0.001
    end
  end

  describe "128259 Speed — water/ground referenced" do
    test "water-referenced speed round-trips into the water_speed field" do
      d = def_for(128_259, %{output_field: "speed_water_referenced"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 4.2})
      decoded = J1939.SpeedParams.decode(payload)
      assert_in_delta decoded.water_speed, 4.2, 0.01
    end

    test "ground-referenced speed round-trips into the ground_speed field" do
      d = def_for(128_259, %{output_field: "speed_ground_referenced"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 3.1})
      decoded = J1939.SpeedParams.decode(payload)
      assert_in_delta decoded.ground_speed, 3.1, 0.01
    end
  end

  describe "128267 Water Depth" do
    test "depth in meters round-trips" do
      d = def_for(128_267, %{output_field: "depth"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 12.34})
      decoded = J1939.WaterDepthParams.decode(payload)
      assert_in_delta decoded.depth, 12.34, 0.01
    end
  end

  describe "130312 Temperature — instanced" do
    test "temperature (Kelvin catalog unit) round-trips on the wire; instance carried" do
      d = def_for(130_312, %{output_field: "temperature", output_instance: 3})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 294.15})
      decoded = J1939.TemperatureParams.decode(payload)
      assert decoded.instance == 3
      # catalog unit is Kelvin; the value passes straight through (no offset)
      assert_in_delta decoded.temperature_k, 294.15, 0.02
    end
  end

  describe "127250 Vessel Heading (+ reference)" do
    test "heading degrees round-trips to radians with reference" do
      d = def_for(127_250, %{output_field: "heading", output_reference: "true"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 123.0})
      decoded = J1939.VesselHeadingParams.decode(payload)
      assert_in_delta decoded.heading, 123.0 / @deg_per_rad, 0.001
      assert decoded.reference == :true_reference
    end
  end

  describe "127257 Attitude (yaw/pitch/roll)" do
    test "single-scalar roll maps to the roll field (signed)" do
      d = def_for(127_257, %{output_field: "roll"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => -15.0})
      decoded = J1939.AttitudeParams.decode(payload)
      assert_in_delta decoded.roll, -15.0 / @deg_per_rad, 0.001
    end

    test "named yaw/pitch/roll outputs all populate their fields" do
      d = def_for(127_257, %{output_field: "yaw"})
      outputs = %{"yaw" => 10.0, "pitch" => -5.0, "roll" => 20.0}
      assert {:ok, payload} = PgnEncode.encode(d, outputs)
      decoded = J1939.AttitudeParams.decode(payload)
      assert_in_delta decoded.yaw, 10.0 / @deg_per_rad, 0.001
      assert_in_delta decoded.pitch, -5.0 / @deg_per_rad, 0.001
      assert_in_delta decoded.roll, 20.0 / @deg_per_rad, 0.001
    end
  end

  describe "129026 COG/SOG Rapid" do
    test "cog (deg) + sog (m/s) round-trip; reference=true" do
      d = def_for(129_026, %{output_field: "sog", output_reference: "true"})
      outputs = %{"sog" => 5.5, "cog" => 88.0}
      assert {:ok, payload} = PgnEncode.encode(d, outputs)
      decoded = J1939.VelocityOverGroundParams.decode(payload)
      assert_in_delta decoded.speed_over_ground, 5.5, 0.01
      assert_in_delta decoded.course_over_ground, 88.0 / @deg_per_rad, 0.001
      assert decoded.direction_reference == :true_reference
    end
  end

  describe "proprietary best-effort PGNs" do
    test "130824 (B&G) encodes 8 bytes with manufacturer header + scalar (best effort)" do
      d = def_for(130_824, %{output_field: "value"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 3.3})
      assert byte_size(payload) == 8
      # Manufacturer/industry header is the canonical NMEA proprietary prefix: the
      # first two little-endian bytes carry manufacturer code (11 bits) + industry
      # code (3 bits, 4 = Marine) with a 2-bit reserved field set to 1s.
      <<_mfg_word::little-16, _rest::binary>> = payload
    end

    test "65305 (Simrad) encodes 8 bytes with manufacturer header + scalar (best effort)" do
      d = def_for(65_305, %{output_field: "value"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 1.0})
      assert byte_size(payload) == 8
    end
  end

  describe "130824 B&G Race Timer (Key 117)" do
    # canboat: PGN 130824 "B&G: key-value data", Key 117 "Race Timer", value u32 in
    # MILLISECONDS (resolution 0.001 s). The descriptor packs Key (12 bits) + Length
    # (4 bits, = value byte length) into 2 little-endian bytes: low byte = key[0..7],
    # high byte = key[8..11] | (Length << 4). Key 117 = 0x075, Length 4 -> "75 40".
    # The full payload is the 2-byte B&G/Marine manufacturer header, then the pair.

    # B&G = 381, Marine = 4: (381 &&& 0x7FF) | (0b11 <<< 11) | (4 <<< 13) = 0x997D,
    # serialized little-endian -> bytes 7D 99.
    @bandg_header <<0x7D, 0x99>>

    test "encodes the worked 5:00 example exactly: 7D 99 75 40 E0 93 04 00" do
      # 300_000 ms = 0x000493E0; u32 LE -> E0 93 04 00; pair -> 75 40 E0 93 04 00.
      assert PgnEncode.race_timer(300_000) == @bandg_header <> <<0x75, 0x40, 0xE0, 0x93, 0x04, 0x00>>
    end

    test "the descriptor word is always Key=117 Length=4 (75 40), header first" do
      <<header::binary-2, 0x75, 0x40, _value::binary-4>> = PgnEncode.race_timer(123_456)
      assert header == @bandg_header
    end

    test "zero ms encodes as all-zero value bytes (the gun)" do
      assert PgnEncode.race_timer(0) == @bandg_header <> <<0x75, 0x40, 0x00, 0x00, 0x00, 0x00>>
    end

    test "value is uint32 little-endian milliseconds for an arbitrary count" do
      # 1500 ms = 0x000005DC -> LE DC 05 00 00.
      assert PgnEncode.race_timer(1_500) == @bandg_header <> <<0x75, 0x40, 0xDC, 0x05, 0x00, 0x00>>
    end

    test "the payload is exactly 8 bytes (2 header + 6 pair) — one fast-packet frame's worth" do
      assert byte_size(PgnEncode.race_timer(60_000)) == 8
    end

    test "race_timer_from/2 computes (gun - now) in ms from monotonic-ms inputs" do
      # gun 90s out from now (in ms): 90_000 ms remaining.
      assert PgnEncode.race_timer_from(90_000, 0) == PgnEncode.race_timer(90_000)
    end

    test "race_timer_from/2 past the gun encodes the elapsed magnitude (count-up)" do
      # now 30s past the gun: |gun - now| = 30_000 ms elapsed.
      assert PgnEncode.race_timer_from(0, 30_000) == PgnEncode.race_timer(30_000)
    end
  end

  # PGN 130824 "B&G: key-value data" carrying the Phase-2 polar TARGET/VMG/next-leg
  # outputs as key-value entries — the ONLY home this data has on a B&G/Zeus display
  # (there is no standard PGN for it). Each frame is the 2-byte B&G/Marine manufacturer
  # header, then ONE Key/Length descriptor + little-endian value, built by the SAME
  # `serialize_with_entry/3` machinery the race timer (Key 117) uses.
  #
  # HARDWARE-VALIDATION: these keys/resolutions are reverse-engineered from the canboat
  # BANDG_KEY_VALUE enum (like race-timer Key 117) and need a bench sniff against a real
  # B&G display. These tests LOCK the exact byte layout we currently believe is correct.
  describe "130824 B&G target/VMG/next-leg key-value entries — exact bytes" do
    # B&G = 381, Marine = 4: serialized little-endian -> bytes 7D 99 (see race timer).
    @bandg_header <<0x7D, 0x99>>

    # Descriptor for a 2-byte value: low = key[0..7], high = key[8..11] | (2 << 4).
    defp descriptor2(key) do
      import Bitwise
      <<key &&& 0xFF, (key >>> 8 &&& 0x0F) ||| 2 <<< 4>>
    end

    defp encode_field(field, value) do
      d = def_for(130_824, %{output_field: field})
      PgnEncode.encode(d, %{field => value})
    end

    test "target_boat_speed -> Key 125, u16 m/s ×100" do
      # 5.0 m/s -> round(5.0 / 0.01) = 500 = 0x01F4 -> LE F4 01.
      assert {:ok, payload} = encode_field("target_boat_speed", 5.0)
      assert payload == @bandg_header <> descriptor2(125) <> <<0xF4, 0x01>>
    end

    test "vmg -> Key 127, u16 m/s ×100" do
      # 3.21 m/s -> round(3.21 / 0.01) = 321 = 0x0141 -> LE 41 01.
      assert {:ok, payload} = encode_field("vmg", 3.21)
      assert payload == @bandg_header <> descriptor2(127) <> <<0x41, 0x01>>
    end

    test "next_leg_aws -> Key 113, u16 m/s ×100" do
      # 12.0 m/s -> round(12.0 / 0.01) = 1200 = 0x04B0 -> LE B0 04.
      assert {:ok, payload} = encode_field("next_leg_aws", 12.0)
      assert payload == @bandg_header <> descriptor2(113) <> <<0xB0, 0x04>>
    end

    test "vmg_performance -> Key 285, u16 percent ×10" do
      # 95.0 % -> round(95.0 / 0.1) = 950 = 0x03B6 -> LE B6 03.
      assert {:ok, payload} = encode_field("vmg_performance", 95.0)
      assert payload == @bandg_header <> descriptor2(285) <> <<0xB6, 0x03>>
    end

    test "target_twa -> Key 83, i16 radians ×10000 (deg→rad)" do
      # 42.0 deg -> 0.733038... rad -> round(0.733038 / 0.0001) = 7330 = 0x1CA2 -> LE A2 1C.
      assert {:ok, payload} = encode_field("target_twa", 42.0)
      assert payload == @bandg_header <> descriptor2(83) <> <<0xA2, 0x1C>>
    end

    test "next_leg_awa -> Key 111, i16 radians ×10000 (deg→rad)" do
      # The worked example: 30 deg -> 0.5235987 rad -> round(/1e-4) = 5236 = 0x1474 -> LE 74 14.
      assert {:ok, payload} = encode_field("next_leg_awa", 30.0)
      assert payload == @bandg_header <> descriptor2(111) <> <<0x74, 0x14>>
    end

    test "angle keys are SIGNED i16: a negative angle encodes a negative raw value" do
      # next_leg_awa -30 deg -> -0.5235987 rad -> -5236 -> i16 LE = 0xEB8C bytes 8C EB.
      assert {:ok, payload} = encode_field("next_leg_awa", -30.0)
      <<_hdr::binary-2, _desc::binary-2, raw::little-signed-16>> = payload
      assert raw == -5236
    end

    test "every target frame is exactly 6 bytes (2 header + 2 descriptor + 2 value)" do
      for {field, v} <- [
            {"target_boat_speed", 5.0},
            {"target_twa", 42.0},
            {"vmg", 3.0},
            {"vmg_performance", 90.0},
            {"next_leg_awa", 30.0},
            {"next_leg_aws", 10.0}
          ] do
        assert {:ok, payload} = encode_field(field, v)
        assert byte_size(payload) == 6
      end
    end

    test "an out-of-range speed clamps to the u16 max, never wraps/garbles" do
      # 700 m/s -> round(/0.01) = 70_000 > u16 max -> clamps to 0xFFFE.
      assert {:ok, payload} = encode_field("target_boat_speed", 700.0)
      <<_hdr::binary-2, _desc::binary-2, raw::little-16>> = payload
      assert raw == 0xFFFE
    end

    test "an angle past ±180 wraps the short way into (-π, π], keeping i16 in range" do
      # 200 deg wraps to -160 deg = -2.7925 rad -> round(/1e-4) = -27925. Wrapping keeps
      # |rad| <= π so the raw can never exceed the i16 range — no garbled wide-angle frame.
      assert {:ok, payload} = encode_field("target_twa", 200.0)
      <<_hdr::binary-2, _desc::binary-2, raw::little-signed-16>> = payload
      assert raw == -27_925
      assert raw in -0x8000..(0x7FFF - 1)
    end

    test "a missing/invalid target output is :error (nothing to encode, no garbage)" do
      d = def_for(130_824, %{output_field: "next_leg_awa"})
      assert :error = PgnEncode.encode(d, %{})
      assert :error = PgnEncode.encode(d, %{"next_leg_awa" => "nan"})
    end

    test "the best-effort 'value' field still encodes (no regression to the fallback)" do
      d = def_for(130_824, %{output_field: "value"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 3.3})
      assert byte_size(payload) == 8
      <<_mfg_word::little-16, _rest::binary>> = payload
    end
  end

  # PGN 129284 "Navigation Data" — the bearing/distance/destination data-box that a
  # B&G/Zeus plotter renders for the active waypoint. 34-byte fast packet. Field order
  # and encodings per canboat + the ttlappalainen library (see PgnEncode.navigation_data_129284/1).
  describe "129284 Navigation Data — exact byte layout" do
    # A fully-specified nav input with distinct, decodable values per field.
    defp nav_input do
      %{
        sid: 0x42,
        # 1234.56 m -> round(*100) = 123456
        distance_to_dest_m: 1234.56,
        reference: true,
        perpendicular_crossed?: false,
        arrival_circle_entered?: false,
        calculation_type: :great_circle,
        # bearings in radians
        bearing_origin_to_dest_rad: 0.5,
        bearing_position_to_dest_rad: 1.25,
        origin_wp_number: 7,
        destination_wp_number: 9,
        destination: {42.3601, -71.0589},
        closing_velocity_m_s: 3.21
      }
    end

    test "encodes all fields at the documented resolutions, 34 bytes" do
      payload = PgnEncode.navigation_data_129284(nav_input())
      assert byte_size(payload) == 34

      <<sid::8, distance::little-32, _flags::8, eta_time::little-32, eta_date::little-16, brg_od::little-16,
        brg_pd::little-16, origin_wp::little-32, dest_wp::little-32, dest_lat::little-signed-32,
        dest_lon::little-signed-32, closing::little-signed-16>> = payload

      assert sid == 0x42
      # distance 0.01 m resolution
      assert distance == 123_456
      # ETA unknown (we do not compute it on the device)
      assert eta_time == 0xFFFFFFFF
      assert eta_date == 0xFFFF
      # bearings 1e-4 rad resolution
      assert brg_od == round(0.5 / 1.0e-4)
      assert brg_pd == round(1.25 / 1.0e-4)
      assert origin_wp == 7
      assert dest_wp == 9
      # lat/lon 1e-7 deg resolution
      assert dest_lat == round(42.3601 * 1.0e7)
      assert dest_lon == round(-71.0589 * 1.0e7)
      # closing velocity 0.01 m/s resolution
      assert closing == round(3.21 / 0.01)
    end

    test "the flags byte packs ref (2b) / perp (2b) / arrival (2b) / calc-type (2b)" do
      # Magnetic ref (1), perpendicular crossed (1), arrival entered (1), rhumbline (1).
      input = %{
        nav_input()
        | reference: :magnetic,
          perpendicular_crossed?: true,
          arrival_circle_entered?: true,
          calculation_type: :rhumbline
      }

      <<_sid::8, _distance::little-32, flags::8, _rest::binary>> = PgnEncode.navigation_data_129284(input)
      <<calc::2, arrival::2, perp::2, ref::2>> = <<flags::8>>
      assert ref == 1
      assert perp == 1
      assert arrival == 1
      assert calc == 1
    end

    test "a true/great-circle/not-crossed flags byte is all zeros in the low 8 bits" do
      <<_sid::8, _distance::little-32, flags::8, _rest::binary>> = PgnEncode.navigation_data_129284(nav_input())
      assert flags == 0x00
    end

    test "missing destination position / distance / bearings encode the unknown sentinels" do
      input = %{
        sid: 0,
        distance_to_dest_m: nil,
        reference: true,
        perpendicular_crossed?: false,
        arrival_circle_entered?: false,
        calculation_type: :great_circle,
        bearing_origin_to_dest_rad: nil,
        bearing_position_to_dest_rad: nil,
        origin_wp_number: nil,
        destination_wp_number: 1,
        destination: nil,
        closing_velocity_m_s: nil
      }

      <<_sid::8, distance::little-32, _flags::8, _eta_time::little-32, _eta_date::little-16, brg_od::little-16,
        brg_pd::little-16, origin_wp::little-32, dest_wp::little-32, dest_lat::little-signed-32,
        dest_lon::little-signed-32, closing::little-signed-16>> = PgnEncode.navigation_data_129284(input)

      assert distance == 0xFFFFFFFF
      assert brg_od == 0xFFFF
      assert brg_pd == 0xFFFF
      assert origin_wp == 0xFFFFFFFF
      assert dest_wp == 1
      assert dest_lat == 0x7FFFFFFF
      assert dest_lon == 0x7FFFFFFF
      assert closing == 0x7FFF
    end
  end

  # PGN 129285 "Navigation - Route/WP Information" — the LABEL the plotter ties to
  # 129284.Destination Waypoint Number via WP ID. We emit a single-waypoint route.
  describe "129285 Route/WP Information — one waypoint" do
    test "encodes the header + one repeating WP block (STRING_LAU name, lat/lon)" do
      payload =
        PgnEncode.route_wp_129285(%{wp_id: 9, name: "WL", lat: 42.3601, lon: -71.0589})

      # Header: start RPS#(u16) nItems(u16) database id(u16) route id(u16)
      #         nav-dir(3b)+supp(2b)+reserved(3b) (1 byte) route-name STRING_LAU reserved(8)
      <<start_rps::little-16, n_items::little-16, _db_id::little-16, _route_id::little-16, dir_byte::8, rest::binary>> =
        payload

      assert start_rps == 1
      assert n_items == 1
      # nav direction Forward (0) in the low 3 bits.
      assert <<_supp_res::5, dir::3>> = <<dir_byte::8>>
      assert dir == 0

      # route name STRING_LAU: <len::8, enc::8, chars>. Empty route name -> len 2, enc 1 (ASCII).
      <<rn_len::8, rn_enc::8, after_rn::binary>> = rest
      assert rn_len == 2
      assert rn_enc == 1
      # reserved(8) after the route name
      <<_reserved::8, wp_block::binary>> = after_rn

      # WP block: WP ID(u16) WP name STRING_LAU  WP lat(i32 1e-7) WP lon(i32 1e-7)
      <<wp_id::little-16, name_len::8, name_enc::8, body::binary>> = wp_block
      assert wp_id == 9
      # "WL" is 2 ASCII chars -> STRING_LAU length 4 (len + enc + 2 chars), enc 1.
      assert name_len == 4
      assert name_enc == 1
      <<name::binary-2, lat::little-signed-32, lon::little-signed-32>> = body
      assert name == "WL"
      assert lat == round(42.3601 * 1.0e7)
      assert lon == round(-71.0589 * 1.0e7)
    end

    test "an empty/nil waypoint name still produces a valid 2-byte STRING_LAU" do
      payload = PgnEncode.route_wp_129285(%{wp_id: 3, name: nil, lat: 1.0, lon: 2.0})
      # walk to the WP-name STRING_LAU and assert length 2 (just len+enc, no chars).
      <<_hdr::binary-8, _dir::8, 2::8, 1::8, _res::8, 3::little-16, name_len::8, _name_enc::8, _::binary>> = payload
      assert name_len == 2
    end
  end

  describe "unknown / unencodable" do
    test "an unknown PGN returns :error" do
      d = def_for(999_999, %{output_field: "value"})
      assert :error = PgnEncode.encode(d, %{"value" => 1.0})
    end

    test "a missing required output returns :error" do
      d = def_for(128_259, %{output_field: "speed_water_referenced"})
      assert :error = PgnEncode.encode(d, %{})
    end
  end
end
