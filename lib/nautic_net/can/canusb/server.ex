defmodule NauticNet.CAN.CANUSB.Server do
  @moduledoc """
  GenServer implementation for the CANUSB driver that interfaces directly with the serial device.
  """

  use GenServer

  require Logger

  alias NauticNet.NMEA2000.Frame
  alias NauticNet.CAN.CANUSB.Protocol

  @name __MODULE__
  @bit_rate_kbps 250

  defmodule State do
    defstruct uart_pid: nil, parent_pid: nil, log_file: nil, log_start_at: nil
  end

  def start_link(driver_config) do
    GenServer.start_link(__MODULE__, {driver_config, self()}, name: @name)
  end

  def transmit_frame(frame) do
    GenServer.cast(@name, {:transmit_frame, frame})
  end

  def get_version do
    GenServer.cast(@name, :get_version)
  end

  def get_serial_number do
    GenServer.cast(@name, :get_serial_number)
  end

  def start_logging do
    GenServer.call(@name, :start_logging)
  end

  def stop_logging do
    GenServer.call(@name, :stop_logging)
  end

  @impl GenServer
  def init({driver_config, parent_pid}) do
    port = get_canusb_port() || raise "could not locate CANUSB device"
    Logger.info("Found CANUSB device on #{port}")

    {:ok, uart_pid} = Circuits.UART.start_link()
    state = %State{uart_pid: uart_pid, parent_pid: parent_pid}

    :ok =
      Circuits.UART.open(uart_pid, port,
        # Baud can be anything for CANUSB
        speed: 115_200,
        active: true,
        framing: {NauticNet.CAN.CANUSB.Framing, separator: Protocol.separator()}
      )

    start_logging? = Keyword.get(driver_config, :start_logging?, false)

    state =
      if start_logging? do
        {{:ok, _path}, state} = start_logging(state)
        state
      else
        state
      end

    write(state, Protocol.get_version())
    write(state, Protocol.get_serial_number())

    open_channel(state)
    write(state, Protocol.read_status_flags())

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:start_logging, _sender, state) do
    {result, state} = start_logging(state)
    {:reply, result, state}
  end

  def handle_call(:stop_logging, _sender, state) do
    {result, state} = stop_logging(state)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_cast({:transmit_frame, frame}, state) do
    write(state, Protocol.transmit_frame(frame))
    {:noreply, state}
  end

  def handle_cast(:get_version, state) do
    write(state, Protocol.get_version())
    {:noreply, state}
  end

  def handle_cast(:get_serial_number, state) do
    write(state, Protocol.get_serial_number())
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    state =
      data
      |> maybe_log(:rx, state)
      |> Protocol.parse()
      |> handle_parsed(state)

    {:noreply, state}
  end

  def handle_info({:circuits_uart, _port, unknown}, state) do
    Logger.warn("Unexpected UART data: " <> inspect(unknown))
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    close_channel(state)
  end

  defp write(state, line) do
    Circuits.UART.write(state.uart_pid, line)
    maybe_log(line, :tx, state)
    state
  end

  defp handle_parsed({:ok, :ok}, state) do
    Logger.debug("CANUSB OK response")
    state
  end

  defp handle_parsed({:ok, :error}, state) do
    Logger.warn("CANUSB error response")
    state
  end

  defp handle_parsed({:ok, %Frame{} = frame}, state) do
    send(state.parent_pid, {:can_frame, frame})
    state
  end

  defp handle_parsed({:ok, info}, state) do
    Logger.debug("CANUSB response: #{inspect(info)}")
    state
  end

  defp handle_parsed({:error, data}, state) do
    Logger.warn("CANUSB cannot parse: #{inspect(data)}")
    state
  end

  defp get_canusb_port do
    Circuits.UART.enumerate()
    |> Enum.find(fn {_port, info} ->
      match?(%{description: "CANUSB", manufacturer: "LAWICEL"}, info)
    end)
    |> case do
      {port, _info} -> port
      nil -> nil
    end
  end

  defp maybe_log(data, _direction, %State{log_file: nil}), do: data

  defp maybe_log(data, direction, state) do
    prefix =
      case direction do
        :tx -> "->"
        :rx -> "<-"
      end

    timestamp = now_ms() - state.log_start_at
    IO.puts(state.log_file, "#{prefix} #{timestamp} #{data}")
    data
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp start_logging(%State{log_file: nil} = state) do
    # Find /data/canusb-XXXXXX.log with the highest integer XXXXXX
    max_counter =
      File.ls!("/data/")
      |> Enum.reduce(0, fn filename, acc ->
        with ["canusb", counter] <- filename |> Path.basename(".log") |> String.split("-"),
             {int, ""} <- Integer.parse(counter) do
          max(acc, int)
        else
          _ -> acc
        end
      end)

    next_counter = to_string(max_counter + 1) |> String.pad_leading(6, "0")

    # The /data directory is persisted across reboots and remote firmware updates
    # (but not if you burn a new SD card)
    filename = "canusb-#{next_counter}.log"
    path = Path.join(["/data", filename])
    file = File.open!(path, [:write])

    Logger.info("Started CANUSB logging to #{path}")

    {{:ok, path}, %State{state | log_file: file, log_start_at: now_ms()}}
  end

  defp start_logging(state) do
    {:error, state}
  end

  defp stop_logging(%State{log_file: log_file} = state) when is_pid(log_file) do
    File.close(log_file)

    Logger.info("Stopped CANUSB logging")

    {:ok, %State{state | log_file: nil, log_start_at: nil}}
  end

  defp stop_logging(state) do
    {:error, state}
  end

  defp open_channel(state) do
    write(state, Protocol.set_bit_rate(@bit_rate_kbps))
    write(state, Protocol.open_channel())
    Logger.info("Opened CANUSB channel")
  end

  defp close_channel(state) do
    write(state, Protocol.close_channel())
    Logger.info("Closed CANUSB channel")
  end
end
