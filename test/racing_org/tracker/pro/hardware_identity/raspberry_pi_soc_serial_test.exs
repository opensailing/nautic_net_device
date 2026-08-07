defmodule RacingOrg.Tracker.Pro.HardwareIdentity.RaspberryPiSoCSerialTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.HardwareIdentity.RaspberryPiSoCSerial
  alias RacingOrg.Tracker.Pro.SecureTransport.TrackerContractV2

  @device_tree_path "/proc/device-tree/serial-number"
  @cpuinfo_path "/proc/cpuinfo"

  test "publishes the contract's exact provider identifier" do
    assert RaspberryPiSoCSerial.provider() == TrackerContractV2.provider()
    assert RaspberryPiSoCSerial.provider() == "raspberry_pi_soc_serial_v1"
  end

  test "reads the device-tree source first and normalizes it through TrackerContractV2" do
    test_pid = self()

    opts = [
      device_tree_reader: fn path ->
        send(test_pid, {:read, path})
        {:ok, "0x1234ABCD\0\n"}
      end,
      cpuinfo_reader: fn path ->
        send(test_pid, {:read, path})
        {:ok, "processor\t: 0\nModel\t\t: Raspberry Pi 3 Model B\n"}
      end
    ]

    assert {:ok, "000000001234abcd"} = RaspberryPiSoCSerial.identifier(opts)

    assert_receive {:read, @device_tree_path}
    assert_receive {:read, @cpuinfo_path}
  end

  test "falls back to the cpuinfo Serial field when device-tree serial is unavailable" do
    cpuinfo = "processor\t: 0\nSerial\t\t: 000000001234ABCD\nModel\t\t: Raspberry Pi 3 Model B\n"

    assert {:ok, "000000001234abcd"} =
             RaspberryPiSoCSerial.identifier(readers({:error, :enoent}, {:ok, cpuinfo}))
  end

  test "accepts present device-tree and cpuinfo sources only when they normalize identically" do
    cpuinfo = "Serial : 0x000000001234abcd\n"

    assert {:ok, "000000001234abcd"} =
             RaspberryPiSoCSerial.identifier(readers({:ok, "1234ABCD\0"}, {:ok, cpuinfo}))
  end

  test "rejects conflicting device-tree and cpuinfo serials" do
    cpuinfo = "Serial\t: 0000000000000002\n"

    assert {:error, :conflicting_serial_sources} =
             RaspberryPiSoCSerial.identifier(readers({:ok, "1\0"}, {:ok, cpuinfo}))
  end

  test "rejects a malformed present source even when the other source is valid" do
    cpuinfo = "Serial\t: not-a-serial\n"

    assert {:error, :invalid_serial_source} =
             RaspberryPiSoCSerial.identifier(readers({:ok, "1234abcd\0"}, {:ok, cpuinfo}))

    assert {:error, :invalid_serial_source} =
             RaspberryPiSoCSerial.identifier(readers({:ok, " 1234abcd\0"}, {:ok, "processor : 0\n"}))
  end

  test "rejects all-zero serials from either local source" do
    assert {:error, :invalid_serial_source} =
             RaspberryPiSoCSerial.identifier(readers({:ok, "0000000000000000\0"}, {:ok, "processor : 0\n"}))

    assert {:error, :invalid_serial_source} =
             RaspberryPiSoCSerial.identifier(readers({:error, :enoent}, {:ok, "Serial : 0000000000000000\n"}))
  end

  test "rejects ambiguous cpuinfo with more than one Serial field, even when values agree" do
    for cpuinfo <- [
          "Serial : 1\nSerial : 1\n",
          "Serial : 1\nSerial : 2\n"
        ] do
      assert {:error, :ambiguous_serial_source} =
               RaspberryPiSoCSerial.identifier(readers({:error, :enoent}, {:ok, cpuinfo}))
    end
  end

  test "rejects a malformed cpuinfo Serial field instead of treating it as absent" do
    assert {:error, :invalid_serial_source} =
             RaspberryPiSoCSerial.identifier(readers({:error, :enoent}, {:ok, "processor : 0\nSerial\nModel : Pi\n"}))
  end

  test "rejects missing serials when neither source supplies one" do
    assert {:error, :serial_unavailable} =
             RaspberryPiSoCSerial.identifier(readers({:error, :enoent}, {:error, :enoent}))

    assert {:error, :serial_unavailable} =
             RaspberryPiSoCSerial.identifier(
               readers({:error, :enoent}, {:ok, "processor\t: 0\nModel\t: Raspberry Pi\n"})
             )
  end

  test "fails closed when a source cannot be read for a reason other than absence" do
    assert {:error, {:serial_source_read_failed, :device_tree, :eacces}} =
             RaspberryPiSoCSerial.identifier(readers({:error, :eacces}, {:ok, "Serial : 1\n"}))

    assert {:error, {:serial_source_read_failed, :cpuinfo, :eio}} =
             RaspberryPiSoCSerial.identifier(readers({:ok, "1\0"}, {:error, :eio}))
  end

  test "converts reader exceptions into a sanitized fail-closed source error" do
    assert {:error, {:serial_source_read_failed, :device_tree, :reader_failed}} =
             RaspberryPiSoCSerial.identifier(
               device_tree_reader: fn _path -> raise "raw device-tree failure" end,
               cpuinfo_reader: fn _path -> {:ok, "Serial : 1\n"} end
             )
  end

  defp readers(device_tree_result, cpuinfo_result) do
    [
      device_tree_reader: fn path ->
        assert path == @device_tree_path
        device_tree_result
      end,
      cpuinfo_reader: fn path ->
        assert path == @cpuinfo_path
        cpuinfo_result
      end
    ]
  end
end
