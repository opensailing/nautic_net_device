defmodule RacingOrg.Tracker.Pro.CAN do
  @moduledoc """
  Entrypoint for reading and writing from the CAN bus.
  """

  alias RacingOrg.Tracker.NMEA2000.Packet

  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {RacingOrg.Tracker.Pro.CAN.Server, :start_link, [config]}
    }
  end

  defdelegate transmit_frame(frame), to: RacingOrg.Tracker.Pro.CAN.Server

  def transmit_packet(%Packet{} = packet) do
    for frame <- Packet.to_frames(packet) do
      transmit_frame(frame)
    end

    :ok
  end
end
