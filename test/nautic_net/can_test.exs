defmodule NauticNet.CANTest do
  use ExUnit.Case

  setup do
    test_pid = self()

    start_supervised!(
      {NauticNet.CAN,
       driver: NauticNet.CAN.Fake.Driver,
       handlers: [
         {NauticNet.PacketHandler.Callbacks,
          handle_packet: &send(test_pid, &1), handle_closed: fn -> send(test_pid, :can_closed) end}
       ]}
    )

    :ok
  end

  test "can churn through a big log file without blowing up" do
    replay_until_completion(log_filename())

    assert_receive %NauticNet.NMEA2000.Packet{}
  end

  test "can decode a WindDataParams packet" do
    replay_until_completion(["<- 54 T09FD02028FAB30090DFFAFFFF"])

    assert_receive %NauticNet.NMEA2000.Packet{
      data: <<250, 179, 0, 144, 223, 250, 255, 255>>,
      data_size: 8,
      description: nil,
      frame_id: 0,
      frame_type: :extended,
      packet_type: :single,
      parameters: %NauticNet.NMEA2000.J1939.WindDataParams{
        sid: 250,
        wind_angle: 5.7232,
        wind_reference: :apparent,
        wind_speed: 1.79
      },
      pgn: 130_306,
      sequence_id: 0,
      source_addr: 2,
      timestamp: %DateTime{}
    }
  end

  test "can decode a GNSSPositionDataParams packet" do
    replay_until_completion([
      "<- 67177 T0DF805018A02BC9E34A802AEA",
      "<- 67177 T0DF805018A11F80FFD18BAF72",
      "<- 67178 T0DF805018A2DD0580546ECCD2",
      "<- 67178 T0DF805018A36129F6309299FE",
      "<- 67178 T0DF805018A4FFFFFFFF10FC0C",
      "<- 67179 T0DF805018A550008C00CCF2FF",
      "<- 67179 T0DF805018A6FFFFFFFFFFFFFF"
    ])

    assert_receive %NauticNet.NMEA2000.Packet{
      data:
        <<201, 227, 74, 128, 42, 234, 31, 128, 255, 209, 139, 175, 114, 221, 5, 128, 84, 110, 204, 210, 97, 41, 246, 48,
          146, 153, 254, 255, 255, 255, 255, 16, 252, 12, 80, 0, 140, 0, 204, 242, 255, 255, 255>>,
      data_size: 43,
      description: nil,
      frame_id: 6,
      frame_type: :extended,
      packet_type: :fast,
      parameters: %NauticNet.NMEA2000.J1939.GNSSPositionDataParams{
        altitude: -23.49,
        datetime: ~U[2022-06-28T14:52:24.000000Z],
        latitude: 42.26200383333334,
        longitude: -70.89279083333334,
        sid: 201
      },
      pgn: 129_029,
      sequence_id: 5,
      source_addr: 1,
      timestamp: %DateTime{}
    }
  end

  defp replay_until_completion(log, timeout \\ 5000) do
    :ok = NauticNet.CAN.Fake.Driver.replay_canusb_log(log)

    # Sent to us from Callbacks handler after the log frames have been completely handled
    assert_receive :can_closed, timeout
  end

  defp log_filename do
    Path.join(["test", "logs", "canusb-2022-06-28T14-51-17Z.txt"])
  end
end
