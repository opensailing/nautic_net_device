defmodule RacingOrg.Tracker.Pro.NmeaIdentityTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.NmeaIdentity

  # The full input matrix of canonical_hardware_id/1 — extracted UNCHANGED from
  # ClockSource.Config's private canonicalization, now shared with the calibration
  # layer. Every clause below locks the documented behavior:
  #
  #   nil                          -> nil
  #   non-negative integer         -> uppercase hex
  #   printable hex string (0x ok) -> trimmed, unprefixed, UPPERCASE
  #   8-byte (non-hex) binary NAME -> DeviceInfo.hw_id -> uppercase hex
  #   other binary                 -> itself (literal label-style names)
  #   anything else                -> to_string/1

  describe "nil" do
    test "nil -> nil" do
      assert NmeaIdentity.canonical_hardware_id(nil) == nil
    end
  end

  describe "integer NMEA NAME" do
    test "a non-negative integer becomes uppercase hex" do
      # 0x1A2B == 6699
      assert NmeaIdentity.canonical_hardware_id(6699) == "1A2B"
    end

    test "zero is valid (hex \"0\")" do
      assert NmeaIdentity.canonical_hardware_id(0) == "0"
    end

    test "a full 64-bit NAME integer round-trips to its hex form" do
      name = 0xC0A5B2C3D4E5F607
      assert NmeaIdentity.canonical_hardware_id(name) == "C0A5B2C3D4E5F607"
    end

    test "a negative integer is NOT hex-encoded; it falls through to to_string" do
      assert NmeaIdentity.canonical_hardware_id(-5) == "-5"
    end
  end

  describe "printable hex string (the configured-identifier case)" do
    test "lowercase hex is uppercased" do
      assert NmeaIdentity.canonical_hardware_id("1a2b") == "1A2B"
    end

    test "already-uppercase hex is unchanged" do
      assert NmeaIdentity.canonical_hardware_id("1A2B") == "1A2B"
    end

    test "a 0x prefix is stripped" do
      assert NmeaIdentity.canonical_hardware_id("0x1a2b") == "1A2B"
    end

    test "a 0X prefix is stripped" do
      assert NmeaIdentity.canonical_hardware_id("0X1a2b") == "1A2B"
    end

    test "surrounding whitespace is trimmed" do
      assert NmeaIdentity.canonical_hardware_id("  1a2b  ") == "1A2B"
    end

    test "an 8-CHARACTER printable hex string is treated as hex text, not raw NAME bytes" do
      # Precedence lock: printable-hex wins over the 8-byte-binary branch, so a
      # backend id that happens to be 8 chars long is canonicalized as hex text.
      assert NmeaIdentity.canonical_hardware_id("aabbccdd") == "AABBCCDD"
    end
  end

  describe "8-byte binary NMEA NAME (the observed on-bus case)" do
    test "a raw 8-byte NAME becomes its unsigned 64-bit integer's uppercase hex" do
      # <<0xC0, 0xA5, ...>> is non-printable, 8 bytes -> DeviceInfo.hw_id -> hex.
      name = <<0xC0, 0xA5, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07>>
      assert NmeaIdentity.canonical_hardware_id(name) == "C0A5B2C3D4E5F607"
    end

    test "matches the canonical form of the same NAME given as an integer" do
      name_int = 0x1122334455667788
      name_bin = <<name_int::integer-size(64)>>

      # The two on-bus representations of one NAME canonicalize identically.
      # (This binary is non-printable — 0x11.. bytes are control characters.)
      assert NmeaIdentity.canonical_hardware_id(name_bin) ==
               NmeaIdentity.canonical_hardware_id(name_int)
    end
  end

  describe "other binaries (label-style names)" do
    test "a non-hex textual name passes through unchanged" do
      assert NmeaIdentity.canonical_hardware_id("Garmin GPS 24xd") == "Garmin GPS 24xd"
    end

    test "an empty string passes through unchanged" do
      assert NmeaIdentity.canonical_hardware_id("") == ""
    end

    test "a non-printable binary that is not 8 bytes passes through unchanged" do
      assert NmeaIdentity.canonical_hardware_id(<<1, 2, 3>>) == <<1, 2, 3>>
    end

    test "a bare hex prefix with no digits is not hex; it passes through unchanged" do
      assert NmeaIdentity.canonical_hardware_id("0x") == "0x"
    end
  end

  describe "anything else" do
    test "an atom is stringified" do
      assert NmeaIdentity.canonical_hardware_id(:some_sensor) == "some_sensor"
    end

    test "a float is stringified" do
      assert NmeaIdentity.canonical_hardware_id(1.5) == "1.5"
    end
  end
end
