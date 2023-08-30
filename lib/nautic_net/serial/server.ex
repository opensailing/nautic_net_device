defmodule NauticNet.Serial.Server do
  use GenServer
  require Logger

  def start_link(false), do: :ignore

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl GenServer
  def init(config) do
    Logger.debug("Serial config: #{inspect(config)}")
    # Open Port
    {driver, driver_config} = get_callback_module_config(config[:driver] || raise(":driver config is required"))

    # Start listening
    :ok = driver.init(driver_config)

    # Start Handlers
    handlers =
      get_callback_module_configs(config[:handlers] || raise(":handlers config is required"))
      |> Enum.map(fn {handler, handler_config} ->
        {handler, handler.init(handler_config)}
      end)

    {:ok, %{driver: driver, handlers: handlers, port_name: "ttyUSB1"}}
  end

  defp get_callback_module_config({module, config}), do: {module, config}
  defp get_callback_module_config(module), do: {module, []}

  defp get_callback_module_configs(list) do
    Enum.map(list, &get_callback_module_config/1)
  end

  @impl GenServer

  def handle_info({:circuits_uart, port_name, sentence}, %{port_name: port_name} = state) do
    case NMEA.to_data(:nmea_0183, sentence) do
      :invalid ->
        nil

      nmea_datas ->
        for data <- nmea_datas do
          data = NMEA.Data.put_metadata(data, %{port: port_name, source_description: "SixFab LTE Modem GPS"})

          for {handler, handler_opts} <- state.handlers do
            handler.handle_data(data, handler_opts)
          end
        end
    end

    {:noreply, state}
  end
end
