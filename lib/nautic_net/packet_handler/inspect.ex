defmodule NauticNet.PacketHandler.Inspect do
  @behaviour NauticNet.PacketHandler

  require Logger

  @impl NauticNet.PacketHandler
  def init(opts) do
    only = List.flatten([Keyword.get(opts, :only, [])])
    %{only: only}
  end

  @impl NauticNet.PacketHandler
  def handle_packet(packet, config) do
    if config.only == [] or packet.parameters.__struct__ in config.only do
      Logger.debug(inspect(packet))
    end
  end

  @impl NauticNet.PacketHandler
  def handle_closed(_config) do
    Logger.debug("CAN device closed")
  end
end
