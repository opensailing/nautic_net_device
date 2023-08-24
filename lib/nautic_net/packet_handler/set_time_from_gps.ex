defmodule NauticNet.PacketHandler.SetTimeFromGPS do
  @behaviour NauticNet.PacketHandler

  require Logger

  alias NauticNet.NMEA2000.J1939.GNSSPositionDataParams
  alias NauticNet.NMEA2000.Packet
  alias NMEA.Data

  @impl NauticNet.PacketHandler
  def init(_opts) do
    %{}
  end

  @impl NauticNet.PacketHandler
  def handle_packet(%Packet{parameters: %GNSSPositionDataParams{datetime: gps_datetime = %DateTime{}}}, _config) do
    maybe_set_system_clock(gps_datetime)
  end

  def handle_packet(_packet, _config), do: :ok

  @impl NauticNet.PacketHandler
  def handle_data(%Data{values: %NMEA.DateTimeParams{datetime: gps_datetime = %DateTime{}} = data}, _config) do
    Logger.debug("Recieved NMEA 0183 sentence to set DateTime: #{inspect(data)}")
    maybe_set_system_clock(gps_datetime)
  end

  def handle_data(_packet, _config), do: :ok

  defp maybe_set_system_clock(gps_datetime) do
    # If the system time differs from the GPS time by more than 10 seconds and the new time is in the future, then we should
    # definitely update the system time (assumes the system is in the UTC timezone)
    diff = abs(DateTime.diff(gps_datetime, DateTime.utc_now()))
    direction = DateTime.compare(gps_datetime, DateTime.utc_now())

    if diff > 10 and direction == :gt do
      gps_datetime
      |> DateTime.to_naive()
      |> NervesTime.set_system_time()
    end

    :ok
  end

  @impl NauticNet.PacketHandler
  def handle_closed(_config), do: :ok
end
