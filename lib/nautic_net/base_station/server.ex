defmodule NauticNet.BaseStation.Server do
  use GenServer

  require Logger

  alias Circuits.UART
  alias Circuits.UART.Framing.Line

  alias NauticNet.Protobuf.DataSet
  alias NauticNet.Protobuf.DataSet.DataPoint
  alias NauticNet.Protobuf.LoRaPacket
  alias NauticNet.Protobuf.RoverData
  alias NauticNet.Protobuf.TrackerSample
  alias NauticNet.WebClients.UDPClient

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def poll_status do
    GenServer.cast(__MODULE__, :poll_status)
  end

  @impl true
  def init(_) do
    state = %{uart_pid: nil}
    {:ok, try_open_uart(state)}
  end

  @impl true
  def handle_info(:open, state) do
    {:noreply, try_open_uart(state)}
  end

  def handle_info({:circuits_uart, _port, {:error, reason}}, state) do
    Logger.info("UART error: #{inspect(reason)}")

    schedule_open()

    {:noreply, %{state | uart_pid: nil}}
  end

  def handle_info({:circuits_uart, _port, "LORA," <> _ = data}, state) do
    Logger.info("UART: #{inspect(data)}")

    # Example: "LORA,-45,0D55BC15F512120DBF742742154E4190C220F101289E033003"
    ["LORA", rssi, lora_packet_protobuf_base16 | _future] = String.split(data, ",")
    rssi = String.to_integer(rssi)

    lora_packet_protobuf_base16
    |> Base.decode16!()
    |> LoRaPacket.decode()
    |> upload_rover_data_now(rssi)

    {:noreply, state}
  rescue
    _ ->
      # Catch LoRaPacket.decode/1 error
      Logger.warn("Error decoding LoRa packet; ignoring")
      {:noreply, state}
  end

  def handle_info({:circuits_uart, _port, data}, state) do
    Logger.info("UART: #{inspect(data)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:poll_status, state) do
    {:noreply, println(state, "?")}
  end

  defp try_open_uart(%{uart_pid: pid} = state) when is_pid(pid), do: state

  defp try_open_uart(%{uart_pid: nil} = state) do
    {:ok, pid} = UART.start_link()

    #
    # "ttyACM0" => %{
    #   description: "Adafruit Feather M0",
    #   manufacturer: "Adafruit",
    #   product_id: 32779,
    #   serial_number: "77CD8E9250304C4B552E3120FF062608",
    #   vendor_id: 9114
    # },
    #
    UART.enumerate()
    |> Enum.find(fn {_, info} -> info[:product_id] == 32779 && info[:vendor_id] == 9114 end)
    |> case do
      {port, _info} ->
        Logger.info("Found Adafruit Feather M0 on port #{port}")
        :ok = UART.open(pid, port, speed: 115_200, active: true, framing: {Line, separator: "\r\n"})
        Logger.info("Opened port #{port}")
        poll_status()
        %{state | uart_pid: pid}

      _ ->
        Logger.warn("Could not find Adafruit Feather M0 port")
        schedule_open()
        %{state | uart_pid: nil}
    end
  end

  defp upload_rover_data_now(%LoRaPacket{payload: {:rover_data, %RoverData{} = rover_data}} = lora_packet, rssi) do
    # boat_id = Base.encode16(<<lora_packet.hardwareID::unsigned-integer-32>>)

    boat_serial =
      lora_packet.serial_number
      |> to_string()
      |> String.pad_leading(2, "0")
      |> then(&"Boat-#{&1}")

    data_point =
      DataPoint.new(
        # Zero-out the timestamp to indicate "ASAP", and the server will apply the timestamp after upload
        timestamp: Google.Protobuf.Timestamp.new(),
        sample:
          {:tracker,
           TrackerSample.new(
             rssi: rssi,
             rover_data: rover_data
           )}
      )

    DataSet.new(boat_identifier: boat_serial, data_points: [data_point])
    |> DataSet.encode()
    |> UDPClient.send_data_set()

    :ok
  end

  defp upload_rover_data_now(_, _), do: :ok

  defp println(%{uart_pid: nil} = state, _cmd) do
    state
  end

  defp println(%{uart_pid: uart_pid} = state, cmd) do
    UART.write(uart_pid, cmd <> "\n")
    state
  end

  defp schedule_open do
    Process.send_after(self(), :open, :timer.seconds(1))
  end
end
