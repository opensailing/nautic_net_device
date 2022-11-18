defmodule NauticNet.DiscoveryTest do
  use ExUnit.Case

  alias NauticNet.CAN
  alias NauticNet.DeviceInfo
  alias NauticNet.Discovery
  alias NauticNet.PacketHandler

  setup do
    test_pid = self()
    handle_closed = fn -> send(test_pid, :can_closed) end

    start_supervised!(Discovery)

    start_supervised!(
      {CAN,
       driver: CAN.Fake.Driver,
       handlers: [
         PacketHandler.DiscoverDevices,
         {PacketHandler.Callbacks, handle_closed: handle_closed}
       ]}
    )

    :ok
  end

  test "can discover all devices from the log file" do
    replay_until_completion(log_filename())

    assert Discovery.all() == %{
             1 => %DeviceInfo{manufacturer_code: 1957, source_addr: 1, unique_number: 1_444_621},
             3 => %DeviceInfo{manufacturer_code: 1797, source_addr: 3, unique_number: 1_450_083},
             4 => %DeviceInfo{manufacturer_code: 1797, source_addr: 4, unique_number: 1_466_467},
             5 => %DeviceInfo{manufacturer_code: 1231, source_addr: 5, unique_number: 1_861_955},
             6 => %DeviceInfo{manufacturer_code: 1797, source_addr: 6, unique_number: 1_482_851},
             7 => %DeviceInfo{manufacturer_code: 1797, source_addr: 7, unique_number: 1_499_235},
             8 => %DeviceInfo{manufacturer_code: 1797, source_addr: 8, unique_number: 1_450_083},
             9 => %DeviceInfo{manufacturer_code: 1797, source_addr: 9, unique_number: 1_466_467},
             10 => %DeviceInfo{manufacturer_code: 1829, source_addr: 10, unique_number: 1_526_541},
             11 => %DeviceInfo{manufacturer_code: 1797, source_addr: 11, unique_number: 1_510_157},
             12 => %DeviceInfo{manufacturer_code: 1797, source_addr: 12, unique_number: 1_450_083},
             15 => %DeviceInfo{manufacturer_code: 1797, source_addr: 15, unique_number: 1_466_467},
             16 => %DeviceInfo{manufacturer_code: 1861, source_addr: 16, unique_number: 1_510_157},
             17 => %DeviceInfo{manufacturer_code: 1989, source_addr: 17, unique_number: 1_510_162},
             18 => %DeviceInfo{manufacturer_code: 1989, source_addr: 18, unique_number: 1_512_024},
             35 => %DeviceInfo{manufacturer_code: 226, source_addr: 35, unique_number: 2_051_393}
           }
  end

  test "can fetch one known device from the log file" do
    replay_until_completion(["<- 30108 T18EEFF06863A0B02F008432C0"])

    assert Discovery.fetch(6) ==
             {:ok, %DeviceInfo{manufacturer_code: 1797, source_addr: 6, unique_number: 1_482_851}}
  end

  test "cannot fetch an unknown device from the log file" do
    replay_until_completion(["<- 30108 T18EEFF06863A0B02F008432C0"])

    assert Discovery.fetch(7) == :error
  end

  defp replay_until_completion(log, timeout \\ 5000) do
    :ok = NauticNet.CAN.Fake.Driver.replay_canusb_log(log)

    # Sent to us from Callback handler after the log frames have been completely handled
    assert_receive :can_closed, timeout
  end

  defp log_filename do
    Path.join(["test", "logs", "canusb-2022-06-28T14-51-17Z.txt"])
  end
end
