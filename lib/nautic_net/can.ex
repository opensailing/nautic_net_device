defmodule NauticNet.CAN do
  @moduledoc """
  Entrypoint for reading and writing from the CAN bus.
  """

  alias NauticNet.NMEA2000.Packet

  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {NauticNet.CAN.Server, :start_link, [config]}
    }
  end

  defdelegate transmit_frame(frame), to: NauticNet.CAN.Server

  def transmit_packet(%Packet{} = packet) do
    for frame <- Packet.to_frames(packet) do
      transmit_frame(frame)
    end

    :ok
  end
end
