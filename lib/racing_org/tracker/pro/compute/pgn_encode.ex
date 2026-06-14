defmodule RacingOrg.Tracker.Pro.Compute.PgnEncode do
  @moduledoc """
  Encodes a single computed value to the on-wire NMEA 2000 payload for its target PGN
  (Phase 8). This is the INVERSE of the decoders the device uses to RECEIVE these PGNs
  (`RacingOrg.Tracker.NMEA2000.J1939.*Params` in the `racing_org_tracker_nmea2000` dep), so a payload
  produced here decodes back to the input within scaling tolerance — the property the
  test-suite asserts via round-trip.

  ## Inputs

  `encode/2` takes a computed-value `def` (the map carried by
  `RacingOrg.Tracker.Pro.Compute.Engine` — at minimum `output_pgn`, `output_field`,
  `output_reference`, `output_instance`) and the calc's `outputs` map. Outputs are in
  **catalog units**: speeds m/s, angles DEGREES, depth m, temperature Kelvin.
  Returns `{:ok, payload_binary}` (an 8-byte single-frame for every PGN here) or
  `:error` when the PGN is unsupported or a required output is missing.

  ## Output naming

  A scalar EXPRESSION exposes its value under `"value"`; a LIBRARY calc exposes named
  outputs (`"true_wind_speed"`, `"true_wind_angle"`, `"vmg"`, `"vmc"`, `"sog"`,
  `"cog"`, …). For a multi-field PGN (e.g. 130306 carries BOTH speed and angle) the
  named outputs populate all applicable fields; `output_field` names the PRIMARY field
  and is the one a single-scalar `"value"` maps to.

  ## Units / scaling (wire = catalog × factor), matching the dep decoders

    * speed / wind speed — u16, wire = round(m/s × 100)            (J1939.decode_speed = /100)
    * angle (heading/wind/cog) — u16, wire = round(rad × 10000)    (J1939.decode_angle = /10000)
    * angle (attitude yaw/pitch/roll) — i16, wire = round(rad × 10000)
    * depth — u32 cm, wire = round(m × 100)                        (decode_length(_, :cm) = /100)
    * temperature — u16, wire = round(K × 100)                      (decode_temperature = /100)

  All multi-byte fields are little-endian. "Unknown" sentinels are written when an
  optional secondary field is absent.

  ## PGN support

  Encoded for-real (round-trip verified against the dep decoders):
  130306 Wind, 128259 Speed, 128267 Water Depth, 130312 Temperature,
  127250 Vessel Heading, 127257 Attitude, 129026 COG/SOG Rapid.

  Best-effort (manufacturer framing not public — header + scalar, NEEDS ON-HARDWARE
  VALIDATION): 130824 (B&G), 65305 (Simrad). These emit the canonical NMEA proprietary
  manufacturer/industry header word followed by the scalar; the exact field layout a
  B&G/Simrad display expects is unverified.
  """

  @rad_per_deg :math.pi() / 180.0

  @u16_unknown 0xFFFF
  @i16_unknown 0x7FFF
  @u32_unknown 0xFFFFFFFF
  @u8_unknown 0xFF

  @speed_scale 100
  @angle_scale 10_000
  @depth_cm_scale 100
  @temp_scale 100

  # 129284/129285 resolutions (canboat).
  @i32_unknown 0x7FFFFFFF
  @distance_cm_scale 100
  @bearing_rad_scale 10_000
  @latlon_scale 1.0e7
  @closing_velocity_cm_s_scale 100

  # Direction reference lookup (DIRECTION_REFERENCE): true = 0, magnetic = 1.
  @ref_true 0
  @ref_magnetic 1

  # Wind reference (per WindDataParams): true_ground=0, magnetic_ground=1, apparent=2,
  # true_boat=3, true_water=4. On-device "true" wind from the library calc is the
  # flat-water through-water vector → boat-referenced (3).
  @wind_ref_apparent 2
  @wind_ref_true_boat 3

  # Proprietary header: manufacturer code (11 bits) + reserved (2 bits, set) + industry
  # code (3 bits; 4 = Marine), packed little-endian into the first 2 bytes. Manufacturer
  # codes: B&G = 381, Navico/Simrad = 1857 (canboat). These are best-effort.
  @industry_marine 4
  @mfg_bandg 381
  @mfg_simrad 1857

  @doc """
  Encode the computed value to its PGN payload. `{:ok, binary}` or `:error`.
  """
  @spec encode(map(), %{optional(String.t()) => number()}) :: {:ok, binary()} | :error
  def encode(def, outputs) when is_map(def) and is_map(outputs) do
    do_encode(def.output_pgn, def, outputs)
  rescue
    _ -> :error
  end

  # --- 130824 B&G Race Timer (Key 117) ---------------------------------------------

  # canboat: PGN 130824 "B&G: key-value data". A B&G/Zeus display ticks a race
  # countdown when it sees Key 117 "Race Timer" (value u32, resolution 0.001 s, i.e.
  # MILLISECONDS). The payload is the canonical proprietary header followed by one
  # key/value entry, fast-packet framed by the transmit layer (>8 bytes once the
  # frame index is added). See `RacingOrg.Tracker.Pro.Compute.RaceTimerBroadcaster`.
  @race_timer_key 117

  @doc """
  The fast-packet payload for the B&G Race Timer (PGN 130824, Key 117) for a
  countdown of `ms` MILLISECONDS: the 2-byte B&G/Marine manufacturer header followed
  by the `Key=117 Length=4 <u32 LE ms>` entry. `ms` is clamped non-negative and into
  the u32 range. For a 5:00 countdown (300_000 ms) this is
  `<<0x7D, 0x99, 0x75, 0x40, 0xE0, 0x93, 0x04, 0x00>>`.
  """
  @spec race_timer(integer()) :: binary()
  def race_timer(ms) when is_integer(ms) do
    value = clamp_u32(ms)
    manufacturer_word(@mfg_bandg) |> serialize_with_entry(@race_timer_key, <<value::little-32>>)
  end

  @doc """
  The Race Timer payload from a `gun` time and `now`, in the SAME unit (e.g. both
  monotonic-/unix-milliseconds): encodes `gun - now`, counting DOWN to the gun and UP
  (elapsed) afterward.

  ## On-hardware validation seam (THROUGH THE GUN)

  canboat documents the value as an unsigned DURATION; the exact representation as the
  countdown crosses zero (whether the display wants the elapsed magnitude, a wrapped
  unsigned, or a separate "started" flag) is the single thing the on-hardware sniff
  must confirm. That decision is isolated in `through_gun_ms/1` ONLY — change it there
  to retune post-gun behavior without touching the wire format or the broadcaster.
  """
  @spec race_timer_from(integer(), integer()) :: binary()
  def race_timer_from(gun_ms, now_ms) when is_integer(gun_ms) and is_integer(now_ms) do
    race_timer(through_gun_ms(gun_ms - now_ms))
  end

  # THROUGH-GUN REPRESENTATION (hardware-validation tweak point). Before the gun the
  # remaining time is positive and used as-is (count DOWN). At/after the gun it is <= 0;
  # we currently send the ELAPSED MAGNITUDE (count UP from 0). If the sniff shows a
  # B&G display instead expects the value to keep decreasing through zero / wrap, OR a
  # companion "started" key, adjust HERE (and add the key in `race_timer/1`).
  @spec through_gun_ms(integer()) :: non_neg_integer()
  defp through_gun_ms(remaining_ms) when remaining_ms >= 0, do: remaining_ms
  defp through_gun_ms(remaining_ms), do: -remaining_ms

  # --- 129284 Navigation Data (bearing/distance/destination) ------------------------

  # canboat / ttlappalainen "Navigation Data": the data-box a B&G/Zeus plotter renders
  # for the active waypoint. FAST-PACKET, priority 3, 34 bytes. The plotter ties our
  # `destination_wp_number` to the WP ID in 129285 to label the waypoint.
  @doc """
  The 34-byte PGN 129284 "Navigation Data" payload from a navigation map. Fields
  (in wire order, all multi-byte little-endian):

    * `:sid` — uint8 (sequence id; 0 if unused)
    * `:distance_to_dest_m` — uint32, 0.01 m; `nil` → unknown
    * flags byte — `:reference` (`:true`/`:magnetic`), `:perpendicular_crossed?`,
      `:arrival_circle_entered?`, `:calculation_type` (`:great_circle`/`:rhumbline`),
      each 2 bits
    * ETA Time uint32 + ETA Date uint16 — always the unknown sentinels (the device
      does not compute an ETA)
    * `:bearing_origin_to_dest_rad` — uint16, 1e-4 rad; `nil` → unknown
    * `:bearing_position_to_dest_rad` — uint16, 1e-4 rad (the live steer-to bearing);
      `nil` → unknown
    * `:origin_wp_number` — uint32; `nil` → unknown
    * `:destination_wp_number` — uint32 (links to 129285 WP ID)
    * `:destination` — `{lat, lon}` degrees → two int32 1e-7; `nil` → unknown
    * `:closing_velocity_m_s` — int16, 0.01 m/s; `nil` → unknown
  """
  @spec navigation_data_129284(map()) :: binary()
  def navigation_data_129284(nav) when is_map(nav) do
    {dest_lat, dest_lon} = encode_latlon_1e7(Map.get(nav, :destination))

    <<u8(Map.get(nav, :sid, 0))::8, encode_distance_cm(Map.get(nav, :distance_to_dest_m))::little-32,
      nav_flags_byte(nav)::8, @u32_unknown::little-32, @u16_unknown::little-16,
      encode_bearing_rad(Map.get(nav, :bearing_origin_to_dest_rad))::little-16,
      encode_bearing_rad(Map.get(nav, :bearing_position_to_dest_rad))::little-16,
      encode_wp_number(Map.get(nav, :origin_wp_number))::little-32,
      encode_wp_number(Map.get(nav, :destination_wp_number))::little-32, dest_lat::little-signed-32,
      dest_lon::little-signed-32, encode_closing_velocity(Map.get(nav, :closing_velocity_m_s))::little-signed-16>>
  end

  # --- 129285 Navigation Route/WP Information (the label) ---------------------------

  @doc """
  The PGN 129285 "Navigation - Route/WP Information" payload for a SINGLE waypoint —
  the label a plotter ties to 129284 via the WP ID. FAST-PACKET, priority 6.

  `wp` is `%{wp_id: integer, name: String.t() | nil, lat: float, lon: float}`. The
  header carries Start RPS# = 1, nItems = 1, Database/Route ID = 0, Nav direction =
  Forward (0), an empty route name; then one repeating block: WP ID (uint16), WP Name
  (STRING_LAU), WP Latitude/Longitude (int32 1e-7).
  """
  @spec route_wp_129285(map()) :: binary()
  def route_wp_129285(%{wp_id: wp_id, lat: lat, lon: lon} = wp) do
    name = Map.get(wp, :name)
    {wp_lat, wp_lon} = encode_latlon_1e7({lat, lon})

    # Header: Start RPS#(1), nItems(1), Database ID(0), Route ID(0), nav-dir/supp byte
    # (Forward=0), Route Name STRING_LAU (empty), reserved(8).
    header =
      <<1::little-16, 1::little-16, 0::little-16, 0::little-16, 0::8>> <>
        string_lau("") <> <<@u8_unknown::8>>

    wp_block =
      <<u16(wp_id)::little-16>> <> string_lau(name) <> <<wp_lat::little-signed-32, wp_lon::little-signed-32>>

    header <> wp_block
  end

  # --- 130306 Wind (speed + angle + reference) -------------------------------------

  defp do_encode(130_306, def, outputs) do
    # speed from either a true_wind named output, a generic wind_speed, or "value".
    with {:ok, speed} <- first_value(outputs, ["true_wind_speed", "wind_speed", "value"]) do
      # angle is optional (a pure speed def may omit it); default unknown.
      angle_deg = first_value(outputs, ["true_wind_angle", "wind_angle"])
      ref = wind_reference(def.output_reference)

      angle_field =
        case angle_deg do
          {:ok, deg} -> u16_angle(deg)
          :error -> @u16_unknown
        end

      payload =
        <<0::8, u16_speed(speed)::little-16, angle_field::little-16, 0::5, ref::3, @u16_unknown::little-16>>

      {:ok, payload}
    end
  end

  # --- 128259 Speed (water / ground referenced) ------------------------------------

  defp do_encode(128_259, def, outputs) do
    with {:ok, speed} <- first_value(outputs, ["value", "boat_speed", "sog"]) do
      ground? = def.output_field == "speed_ground_referenced"

      {water, ground} =
        if ground?, do: {@u16_unknown, u16_speed(speed)}, else: {u16_speed(speed), @u16_unknown}

      # water_reference = paddle_wheel (0); speed_direction 0; reserved bits.
      payload = <<0::8, water::little-16, ground::little-16, 0::8, 0::4, 0::4, 0::8>>
      {:ok, payload}
    end
  end

  # --- 128267 Water Depth ----------------------------------------------------------

  defp do_encode(128_267, _def, outputs) do
    with {:ok, depth_m} <- first_value(outputs, ["value", "depth"]) do
      depth_cm = clamp_u32(round(depth_m * @depth_cm_scale))
      # offset unknown (i16), range unknown (u8).
      payload = <<0::8, depth_cm::little-32, @i16_unknown::little-signed-16, @u8_unknown::8>>
      {:ok, payload}
    end
  end

  # --- 130312 Temperature (instanced) ----------------------------------------------

  defp do_encode(130_312, def, outputs) do
    # Catalog temperature unit is Kelvin (NMEA-native); the engine output is already
    # K, so it scales straight to the wire with no offset.
    with {:ok, temp_k_value} <- first_value(outputs, ["value", "temperature"]) do
      instance = instance_byte(def.output_instance)
      temp_k = clamp_u16(round(temp_k_value * @temp_scale))
      # source = 0 (sea temperature); set-temperature unknown.
      payload = <<0::8, instance::8, 0::8, temp_k::little-16, @u16_unknown::little-16>>
      {:ok, payload}
    end
  end

  # --- 127250 Vessel Heading (+ reference) -----------------------------------------

  defp do_encode(127_250, def, outputs) do
    with {:ok, heading_deg} <- first_value(outputs, ["value", "heading"]) do
      ref = direction_reference(def.output_reference)
      # deviation + variation unknown.
      payload =
        <<0::8, u16_angle(heading_deg)::little-16, @i16_unknown::little-signed-16, @i16_unknown::little-signed-16, 0::6,
          ref::2>>

      {:ok, payload}
    end
  end

  # --- 127257 Attitude (yaw / pitch / roll) ----------------------------------------

  defp do_encode(127_257, def, outputs) do
    # Named outputs populate all three; a single "value" maps to output_field.
    yaw = attitude_field(outputs, "yaw", def.output_field)
    pitch = attitude_field(outputs, "pitch", def.output_field)
    roll = attitude_field(outputs, "roll", def.output_field)

    if yaw == @i16_unknown and pitch == @i16_unknown and roll == @i16_unknown do
      :error
    else
      payload =
        <<0::8, yaw::little-signed-16, pitch::little-signed-16, roll::little-signed-16, @u16_unknown::little-16>>

      {:ok, payload}
    end
  end

  # --- 129026 COG/SOG Rapid --------------------------------------------------------

  defp do_encode(129_026, def, outputs) do
    with {:ok, sog} <- first_value(outputs, ["sog", "value"]) do
      ref = direction_reference(def.output_reference)

      cog_field =
        case first_value(outputs, ["cog"]) do
          {:ok, deg} -> u16_angle(deg)
          :error -> @u16_unknown
        end

      payload = <<0::8, 0::6, ref::2, cog_field::little-16, u16_speed(sog)::little-16, @u16_unknown::little-16>>
      {:ok, payload}
    end
  end

  # --- 130824 B&G (best effort — NEEDS ON-HARDWARE VALIDATION) ----------------------

  defp do_encode(130_824, _def, outputs) do
    proprietary(@mfg_bandg, outputs)
  end

  # --- 65305 Simrad (best effort — NEEDS ON-HARDWARE VALIDATION) --------------------

  defp do_encode(65_305, _def, outputs) do
    proprietary(@mfg_simrad, outputs)
  end

  defp do_encode(_pgn, _def, _outputs), do: :error

  # Best-effort proprietary frame: 2-byte manufacturer/industry header word, then the
  # scalar as an i16 (×100), padded to 8 bytes. The real layout is manufacturer-
  # specific and unverified; this preserves the standard header so a sniffer attributes
  # the frame correctly on hardware.
  defp proprietary(mfg_code, outputs) do
    with {:ok, value} <- first_value(outputs, ["value"]) do
      header = manufacturer_word(mfg_code)
      scalar = clamp_i16(round(value * 100))
      payload = <<header::little-16, scalar::little-signed-16, @u32_unknown::little-32>>
      {:ok, payload}
    end
  end

  # --- field encoders --------------------------------------------------------------

  defp u16_speed(m_s), do: clamp_u16(round(m_s * @speed_scale))

  # Angle DEGREES -> u16 radians×10000, wrapped to [0, 2π).
  defp u16_angle(deg) do
    rad = normalize_rad(deg * @rad_per_deg)
    clamp_u16(round(rad * @angle_scale))
  end

  # Signed angle DEGREES -> i16 radians×10000, wrapped to (-π, π].
  defp i16_angle(deg) do
    rad = wrap_pi(deg * @rad_per_deg)
    clamp_i16(round(rad * @angle_scale))
  end

  defp attitude_field(outputs, name, primary_field) do
    cond do
      match?({:ok, _}, first_value(outputs, [name])) ->
        {:ok, deg} = first_value(outputs, [name])
        i16_angle(deg)

      primary_field == name ->
        case first_value(outputs, ["value"]) do
          {:ok, deg} -> i16_angle(deg)
          :error -> @i16_unknown
        end

      true ->
        @i16_unknown
    end
  end

  defp instance_byte(n) when is_integer(n) and n >= 0 and n <= 255, do: n
  defp instance_byte(_), do: 0

  # --- 129284/129285 field encoders (isolated bit-packing) -------------------------

  # Distance metres -> u32 centimetres; nil -> unknown sentinel.
  defp encode_distance_cm(nil), do: @u32_unknown
  defp encode_distance_cm(m) when is_number(m), do: clamp_u32(round(m * @distance_cm_scale))

  # Bearing radians -> u16 (1e-4 rad), wrapped to [0, 2π); nil -> unknown sentinel.
  defp encode_bearing_rad(nil), do: @u16_unknown
  defp encode_bearing_rad(rad) when is_number(rad), do: clamp_u16(round(normalize_rad(rad) * @bearing_rad_scale))

  # Waypoint number -> u32; nil -> unknown sentinel.
  defp encode_wp_number(nil), do: @u32_unknown
  defp encode_wp_number(n) when is_integer(n) and n >= 0, do: min(n, @u32_unknown - 1)

  # {lat, lon} degrees -> {i32, i32} at 1e-7 deg; nil -> unknown sentinels.
  defp encode_latlon_1e7(nil), do: {@i32_unknown, @i32_unknown}

  defp encode_latlon_1e7({lat, lon}) when is_number(lat) and is_number(lon),
    do: {round(lat * @latlon_scale), round(lon * @latlon_scale)}

  # Closing velocity m/s -> i16 (0.01 m/s); nil -> unknown sentinel.
  defp encode_closing_velocity(nil), do: @i16_unknown
  defp encode_closing_velocity(m_s) when is_number(m_s), do: clamp_i16(round(m_s * @closing_velocity_cm_s_scale))

  # 129284 flags byte: 2 bits each, MSB->LSB calc-type | arrival | perpendicular | ref.
  # ref: True=0, Magnetic=1. perp/arrival: No=0, Yes=1. calc: Great Circle=0, Rhumbline=1.
  defp nav_flags_byte(nav) do
    ref = if Map.get(nav, :reference) == :magnetic, do: 1, else: 0
    perp = if Map.get(nav, :perpendicular_crossed?) == true, do: 1, else: 0
    arrival = if Map.get(nav, :arrival_circle_entered?) == true, do: 1, else: 0
    calc = if Map.get(nav, :calculation_type) == :rhumbline, do: 1, else: 0
    <<byte::8>> = <<calc::2, arrival::2, perp::2, ref::2>>
    byte
  end

  defp u8(n) when is_integer(n) and n >= 0 and n <= 255, do: n
  defp u8(_), do: 0

  defp u16(n) when is_integer(n) and n >= 0, do: min(n, @u16_unknown - 1)
  defp u16(_), do: 0

  # NMEA 2000 STRING_LAU: <<total_len::8, encoding::8, chars::binary>> where total_len
  # includes the length and encoding bytes (so empty string -> 2), and encoding 1 = ASCII.
  defp string_lau(str) do
    bytes = to_string(str || "")
    <<byte_size(bytes) + 2::8, 1::8, bytes::binary>>
  end

  defp direction_reference("magnetic"), do: @ref_magnetic
  defp direction_reference(_), do: @ref_true

  defp wind_reference("apparent"), do: @wind_ref_apparent
  defp wind_reference(_), do: @wind_ref_true_boat

  # Manufacturer header word: bits [0..10] manufacturer code, [11..12] reserved (set),
  # [13..15] industry code. Little-endian when serialized.
  defp manufacturer_word(mfg_code) do
    import Bitwise
    (mfg_code &&& 0x7FF) ||| 0x3 <<< 11 ||| (@industry_marine &&& 0x7) <<< 13
  end

  # Serialize a B&G "key-value data" (PGN 130824) payload: the manufacturer header
  # word (little-endian-16), then one key/value entry. Each entry is a 2-byte
  # descriptor packing Key (12 bits) + Length (4 bits = byte_size(value)) — low byte =
  # key[0..7], high byte = key[8..11] | (Length << 4) — followed by the little-endian
  # value bytes. Reused by every 130824 key (composes with `manufacturer_word/1`).
  defp serialize_with_entry(mfg_word, key, value) when is_integer(mfg_word) and is_binary(value) do
    import Bitwise
    length = byte_size(value)
    low = key &&& 0xFF
    high = (key >>> 8 &&& 0x0F) ||| length <<< 4
    <<mfg_word::little-16, low::8, high::8>> <> value
  end

  defp clamp_u16(v) when v < 0, do: 0
  defp clamp_u16(v) when v >= @u16_unknown, do: @u16_unknown - 1
  defp clamp_u16(v), do: v

  defp clamp_i16(v) when v > @i16_unknown - 1, do: @i16_unknown - 1
  defp clamp_i16(v) when v < -0x8000, do: -0x8000
  defp clamp_i16(v), do: v

  defp clamp_u32(v) when v < 0, do: 0
  defp clamp_u32(v) when v >= @u32_unknown, do: @u32_unknown - 1
  defp clamp_u32(v), do: v

  # First present + numeric output among the candidate keys.
  defp first_value(_outputs, []), do: :error

  defp first_value(outputs, [key | rest]) do
    case Map.fetch(outputs, key) do
      {:ok, v} when is_number(v) -> {:ok, v / 1}
      _ -> first_value(outputs, rest)
    end
  end

  defp normalize_rad(theta) do
    two_pi = 2 * :math.pi()
    r = :math.fmod(theta, two_pi)
    if r < 0, do: r + two_pi, else: r / 1
  end

  defp wrap_pi(theta) do
    n = normalize_rad(theta)
    if n > :math.pi(), do: n - 2 * :math.pi(), else: n
  end
end
