defmodule NauticNet.CAN.CANUSB.ProtocolTest do
  use ExUnit.Case

  alias NauticNet.CAN.CANUSB.Protocol
  alias NauticNet.NMEA2000.Frame

  test "separator/0" do
    assert Protocol.separator() == "\r"
  end

  test "set_bit_rate/1" do
    assert Protocol.set_bit_rate(10) == "S0"
    assert Protocol.set_bit_rate(20) == "S1"
    assert Protocol.set_bit_rate(50) == "S2"
    assert Protocol.set_bit_rate(100) == "S3"
    assert Protocol.set_bit_rate(125) == "S4"
    assert Protocol.set_bit_rate(250) == "S5"
    assert Protocol.set_bit_rate(500) == "S6"
    assert Protocol.set_bit_rate(800) == "S7"
    assert Protocol.set_bit_rate(1_000) == "S8"
  end

  test "set_btr_bit_rates/2" do
    assert Protocol.set_btr_bit_rates(12, 34) == "s0C22"
  end

  test "open_channel/0" do
    assert Protocol.open_channel() == "O"
  end

  test "close_channel/0" do
    assert Protocol.close_channel() == "C"
  end

  describe "transmit_frame/1" do
    test "with a standard frame" do
      frame = %Frame{
        type: :standard,
        identifier: 0x012,
        data: <<0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80>>
      }

      assert Protocol.transmit_frame(frame) == "t01281020304050607080"
    end

    test "with an extended frame" do
      frame = %Frame{
        type: :extended,
        identifier: 0x01234,
        data: <<0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80>>
      }

      assert Protocol.transmit_frame(frame) == "T0000123481020304050607080"
    end
  end

  describe "transmit_rtr_frame/1" do
    test "with a standard frame" do
      frame = %Frame{
        type: :standard,
        identifier: 0x012,
        data: <<0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80>>
      }

      assert Protocol.transmit_rtr_frame(frame) == "r0128"
    end

    test "with an extended frame" do
      frame = %Frame{
        type: :extended,
        identifier: 0x01234,
        data: <<0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80>>
      }

      assert Protocol.transmit_rtr_frame(frame) == "R000012348"
    end
  end

  test "read_status_flags/0" do
    assert Protocol.read_status_flags() == "F"
  end

  test "set_acceptance_code/1" do
    assert Protocol.set_acceptance_code(0x12345678) == "M12345678"
  end

  test "set_acceptance_mask/1" do
    assert Protocol.set_acceptance_mask(0x12345678) == "m12345678"
  end

  test "get_version/0" do
    assert Protocol.get_version() == "V"
  end

  test "get_serial_number/0" do
    assert Protocol.get_serial_number() == "N"
  end

  test "set_timestamps/1" do
    assert Protocol.set_timestamps(false) == "Z0"
    assert Protocol.set_timestamps(true) == "Z1"
  end

  describe "parse/1" do
    test "an error bell" do
      assert Protocol.parse("\a") == {:ok, :error}
    end

    test "ok responses" do
      assert Protocol.parse("") == {:ok, :ok}
      assert Protocol.parse("z") == {:ok, :ok}
      assert Protocol.parse("Z") == {:ok, :ok}
    end

    test "a received standard frame" do
      assert Protocol.parse("t01281020304050607080") ==
               {:ok,
                %NauticNet.NMEA2000.Frame{
                  data: <<0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80>>,
                  identifier: 0x12,
                  timestamp_ms: 0,
                  type: :standard
                }}
    end

    test "a received extended frame" do
      assert Protocol.parse("T0000123481020304050607080") ==
               {:ok,
                %NauticNet.NMEA2000.Frame{
                  data: <<0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80>>,
                  identifier: 0x1234,
                  timestamp_ms: 0,
                  type: :extended
                }}
    end

    test "status flags" do
      assert Protocol.parse("F00") ==
               {:ok,
                {:status_flags,
                 %{
                   arbitration_lost?: 0,
                   bus_error?: 0,
                   data_overrun?: 0,
                   error_passive?: 0,
                   error_warning?: 0,
                   receive_fifo_queue_full?: 0,
                   transmit_fifo_queue_full?: 0
                 }}}

      assert Protocol.parse("FFF") ==
               {:ok,
                {:status_flags,
                 %{
                   arbitration_lost?: 1,
                   bus_error?: 1,
                   data_overrun?: 1,
                   error_passive?: 1,
                   error_warning?: 1,
                   receive_fifo_queue_full?: 1,
                   transmit_fifo_queue_full?: 1
                 }}}
    end

    test "versions" do
      assert Protocol.parse("V1234") ==
               {:ok,
                {:version,
                 %{
                   hardware_version: 0x12,
                   software_version: 0x34
                 }}}
    end

    test "serial number" do
      assert Protocol.parse("NDERP") == {:ok, {:serial_number, "DERP"}}
    end
  end
end
