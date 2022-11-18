defmodule NauticNet.CAN.Server do
  @moduledoc """
  GenServer for handling CAN bus TX and RX.
  """

  use GenServer

  require Logger

  alias NauticNet.NMEA2000.FrameDecoder

  def start_link(false), do: :ignore

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl GenServer
  def init(config) do
    {:ok, decoder} = FrameDecoder.start_link()

    {driver, driver_config} =
      get_callback_module_config(config[:driver] || raise(":driver config is required"))

    :ok = driver.init(driver_config)

    handlers =
      get_callback_module_configs(config[:handlers] || raise(":handlers config is required"))
      |> Enum.map(fn {handler, handler_config} ->
        {handler, handler.init(handler_config)}
      end)

    {:ok, %{driver: driver, decoder: decoder, handlers: handlers}}
  end

  defp get_callback_module_config({module, config}), do: {module, config}
  defp get_callback_module_config(module), do: {module, []}

  defp get_callback_module_configs(list) do
    Enum.map(list, &get_callback_module_config/1)
  end

  @impl GenServer
  def handle_info({:can_frame, frame}, state) do
    # Logger.debug("Got frame: #{inspect(frame)}")

    case FrameDecoder.decode_frame(state.decoder, frame) do
      {:ok, packet} ->
        for {handler, handler_opts} <- state.handlers do
          handler.handle_packet(packet, handler_opts)
        end

      :incomplete ->
        nil

      {:discarded, _reason} ->
        nil
        # Logger.debug("Frame discarded: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(:can_closed, state) do
    for {handler, handler_opts} <- state.handlers do
      handler.handle_closed(handler_opts)
    end

    {:noreply, state}
  end
end
