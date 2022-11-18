defmodule NauticNet.PacketHandler.SetTimeFromGPS do
  @behaviour NauticNet.PacketHandler

  require Logger

  alias NauticNet.NMEA2000.J1939.GNSSPositionDataParams
  alias NauticNet.NMEA2000.Packet

  @impl NauticNet.PacketHandler
  def init(_opts) do
    %{}
  end

  @impl NauticNet.PacketHandler
  def handle_packet(%Packet{parameters: %GNSSPositionDataParams{} = params}, _config) do
    # TODO: Somehow set the system time on the device
    IO.inspect(params)
  end

  def handle_packet(_packet, _config), do: :ok

  @impl NauticNet.PacketHandler
  def handle_closed(_config), do: :ok
end
