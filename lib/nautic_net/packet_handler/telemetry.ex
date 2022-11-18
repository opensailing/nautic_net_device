defmodule NauticNet.PacketHandler.Telemetry do
  @behaviour NauticNet.PacketHandler

  alias NauticNet.DeviceInfo
  alias NauticNet.Discovery
  alias NauticNet.NMEA2000.Packet
  alias NauticNet.NMEA2000.J1939.GNSSPositionDataParams
  alias NauticNet.NMEA2000.J1939.TemperatureParams
  alias NauticNet.NMEA2000.J1939.WindDataParams

  @impl NauticNet.PacketHandler
  def init(_opts) do
    %{}
  end

  @impl NauticNet.PacketHandler
  def handle_packet(%Packet{parameters: %WindDataParams{} = params} = packet, _config) do
    execute([:nautic_net, :wind, params.wind_reference], packet, %{
      vector: %{
        angle: params.wind_angle,
        magnitude: params.wind_speed
      }
    })
  end

  def handle_packet(%Packet{parameters: %GNSSPositionDataParams{} = params} = packet, _config) do
    execute([:nautic_net, :gps], packet, %{
      position: %{
        lat: params.latitude,
        lon: params.longitude
      }
    })
  end

  def handle_packet(%Packet{parameters: %TemperatureParams{} = params} = packet, _config) do
    execute([:nautic_net, :temperature], packet, %{kelvin: params.temperature_k})
  end

  def handle_packet(_packet, _config), do: :ok

  @impl NauticNet.PacketHandler
  def handle_closed(_config), do: :ok

  defp execute(event_name, packet, measurements, metadata \\ %{}) do
    # TODO: Factor in some sort of unique sensor ID, because the device_id is not nearly specific enough

    with {:ok, device_info} <- Discovery.fetch(packet.source_addr) do
      device_id = DeviceInfo.identifier(device_info)

      :telemetry.execute(
        event_name,
        measurements,
        Map.merge(
          %{device_id: device_id, timestamp_monotonic_ms: packet.timestamp_monotonic_ms},
          metadata
        )
      )
    end
  end
end
