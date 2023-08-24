defmodule NauticNet.PacketHandler.Callbacks do
  @behaviour NauticNet.PacketHandler

  @impl NauticNet.PacketHandler
  def init(opts) do
    opts
    |> Keyword.take([:handle_packet, :handle_closed])
    |> Map.new()
  end

  @impl NauticNet.PacketHandler
  def handle_packet(packet, config) do
    apply_callback(config[:handle_packet], [packet])
  end

  @impl NauticNet.PacketHandler
  def handle_data(data, config) do
    apply_callback(config[:handle_packet], [data])
  end

  @impl NauticNet.PacketHandler
  def handle_closed(config) do
    apply_callback(config[:handle_closed], [])
  end

  defp apply_callback(nil, _args), do: nil

  defp apply_callback(callback, args) when is_function(callback) do
    apply(callback, args)
  end

  defp apply_callback({module, fun}, args) do
    apply(module, fun, args)
  end
end
