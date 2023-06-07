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
  def handle_packet(%Packet{parameters: %GNSSPositionDataParams{datetime: gps_datetime = %DateTime{}}}, _config) do
    # If the system time differs from the GPS time by more than 10 seconds, then we should
    # definitely update the system time (assumes the system is in the UTC timezone)

    diff = abs(DateTime.diff(gps_datetime, DateTime.utc_now()))

    if diff > 10 do
      gps_datetime
      |> DateTime.to_naive()
      |> NervesTime.set_system_time()
    end

    :ok
  end

  def handle_packet(_packet, _config), do: :ok

  @impl NauticNet.PacketHandler
  def handle_closed(_config), do: :ok
end
