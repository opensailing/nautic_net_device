defmodule NauticNet.PacketHandler.EmitTelemetry do
  @behaviour NauticNet.PacketHandler

  alias NauticNet.DeviceInfo
  alias NauticNet.Discovery
  alias NauticNet.NMEA2000.Packet
  alias NauticNet.NMEA2000.J1939

  @impl NauticNet.PacketHandler
  def init(_opts) do
    %{}
  end

  @impl NauticNet.PacketHandler
  def handle_packet(%Packet{parameters: %J1939.WindDataParams{} = params} = packet, _config) do
    execute([:nautic_net, :wind, params.wind_reference], packet, %{
      vector: %{
        timestamp: packet.timestamp,
        angle: params.wind_angle,
        magnitude: params.wind_speed
      }
    })
  end

  def handle_packet(%Packet{parameters: %J1939.GNSSPositionDataParams{} = params} = packet, _config) do
    execute([:nautic_net, :gps], packet, %{
      position: %{
        timestamp: packet.timestamp,
        lat: params.latitude,
        lon: params.longitude
      }
    })
  end

  def handle_packet(%Packet{parameters: %J1939.TemperatureParams{} = params} = packet, _config) do
    execute([:nautic_net, :temperature], packet, %{
      timestamp: packet.timestamp,
      kelvin: params.temperature_k
    })
  end

  def handle_packet(%Packet{parameters: %J1939.SpeedParams{} = params} = packet, _config) do
    execute([:nautic_net, :water_speed], packet, %{
      m_s: %{
        timestamp: packet.timestamp,
        value: params.water_speed
      }
    })
  end

  # Discard (UINT32_MAX / 100)
  def handle_packet(%Packet{parameters: %J1939.WaterDepthParams{depth: depth_m}} = packet, _config)
      when depth_m != 42_949_672.0 do
    execute([:nautic_net, :water_depth], packet, %{
      m: %{
        timestamp: packet.timestamp,
        value: depth_m
      }
    })
  end

  def handle_packet(%Packet{parameters: %J1939.VesselHeadingParams{} = params} = packet, _config) do
    execute([:nautic_net, :heading], packet, %{
      rad: %{
        timestamp: packet.timestamp,
        value: params.heading
      }
    })
  end

  def handle_packet(%Packet{parameters: %J1939.VelocityOverGroundParams{} = params} = packet, _config) do
    execute([:nautic_net, :ground_velocity], packet, %{
      vector: %{
        timestamp: packet.timestamp,
        angle: params.course_over_ground,
        magnitude: params.speed_over_ground
      }
    })
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
