defmodule NauticNet.PacketHandler.DiscoverDevices do
  @behaviour NauticNet.PacketHandler

  alias NauticNet.Discovery

  @impl NauticNet.PacketHandler
  def init(_opts) do
    %{}
  end

  @impl NauticNet.PacketHandler
  def handle_packet(packet, _config) do
    Discovery.handle_packet(packet)
  end

  @impl NauticNet.PacketHandler
  def handle_data(_data, _config), do: :ok

  @impl NauticNet.PacketHandler
  def handle_closed(_config), do: :ok
end
