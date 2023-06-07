defmodule NauticNet.CAN.PiCAN.Server do
  use GenServer

  require Logger

  alias NauticNet.NMEA2000.Frame

  @name __MODULE__

  defmodule State do
    defstruct [
      :interface,
      :socket,
      :rx_data_buffer,
      :mode,
      :last_command,
      :parent_pid
    ]
  end

  def start_link(driver_config) do
    GenServer.start_link(__MODULE__, {driver_config, self()}, name: @name)
  end

  def transmit_frame(frame) do
    GenServer.cast(@name, {:transmit_frame, frame})
  end

  def init({driver_config, parent_pid}) do
    interface = driver_config[:interface] || "can0"

    Logger.info("Bringing up can0 link...")
    {_, _} = System.cmd("ip", ~w[link set can0 up type can bitrate 250000])

    Logger.info("Starting socketcand...")
    Port.open({:spawn, "socketcand --interfaces can0 --listen lo --port 28600"}, [:binary])

    # Lazy: wait for socketcand to start up
    Logger.info("Waiting for socketcand...")
    Process.sleep(1000)

    # Connect to socketcand via TCP
    Logger.info("Connecting to 127.0.0.1:28600...")
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, 28600, [:binary, active: true])

    {:ok,
     %State{
       interface: interface,
       socket: socket,
       rx_data_buffer: "",
       mode: :no_bus,
       last_command: nil,
       parent_pid: parent_pid
     }}
  end

  # gen_tcp
  def handle_info({:tcp, _, data}, state) do
    # socketcand procotol reference: https://github.com/dschanoeh/socketcand/blob/master/doc/protocol.md
    {messages, next_buffer} = extract_messages(data, state.rx_data_buffer)

    state = handle_messages(messages, state)

    {:noreply, %State{state | rx_data_buffer: next_buffer}}
  end

  # gen_tcp
  def handle_info({:tcp_closed, _}, state), do: {:stop, :normal, state}

  # gen_tcp
  def handle_info({:tcp_error, _}, state), do: {:stop, :normal, state}

  # Port
  def handle_info({port, info}, state) when is_port(port) do
    Logger.info("Port event: #{inspect(info)}")
    {:noreply, state}
  end

  def handle_cast({:transmit_frame, %Frame{} = frame}, state) do
    can_id_hex = Integer.to_string(frame.identifier, 16)
    data_length = Frame.data_length(frame)

    data_hex =
      frame.data
      |> :binary.bin_to_list()
      |> Enum.map(&Integer.to_string(&1, 16))
      |> Enum.join(" ")

    # https://github.com/dschanoeh/socketcand/blob/master/doc/protocol.md#send-a-single-frame
    message = "< send #{can_id_hex} #{data_length} #{data_hex} >"
    :gen_tcp.send(state.socket, message)

    Logger.debug("Sent: #{message}")

    {:noreply, state}
  end

  defp extract_messages(new_data, buffer) do
    # Convert TCP stream like "< foo >< bar >< bat >< ..." into individual messages,
    # and track the leftover buffer to accumulate for next time
    {messages, [next_buffer]} =
      (buffer <> new_data)
      |> String.split(" >")
      |> Enum.split(-1)

    messages = Enum.map(messages, fn "< " <> rest -> rest end)

    {messages, next_buffer}
  end

  defp handle_messages([], state), do: state

  defp handle_messages(["hi" | rest], state) do
    Logger.info("Opening #{state.interface}...")
    :gen_tcp.send(state.socket, "< open #{state.interface} >")
    handle_messages(rest, %State{state | last_command: :open})
  end

  defp handle_messages(["ok" | rest], %{last_command: :open} = state) do
    Logger.info("Interface opened. Enabling raw mode...")
    :gen_tcp.send(state.socket, "< rawmode >")
    handle_messages(rest, %State{state | mode: :bcm, last_command: :rawmode})
  end

  defp handle_messages(["ok" | rest], %{last_command: :rawmode} = state) do
    Logger.info("Enabled raw mode!")
    handle_messages(rest, %State{state | mode: :raw, last_command: nil})
  end

  defp handle_messages(["frame " <> _payload = message | rest], state) do
    if frame = parse_frame(message) do
      send(state.parent_pid, {:can_frame, frame})
    end

    handle_messages(rest, %State{state | mode: :raw, last_command: nil})
  end

  defp handle_messages([unknown | rest], state) do
    Logger.info("Unhandled socketcand message: #{inspect(unknown)}")
    handle_messages(rest, state)
  end

  defp parse_frame("frame " <> payload) do
    # CAN messages received are sent in the format: "< frame can_id seconds.useconds [data]* >"
    # e.g. "frame 15FD0634 1660779989.863923 FFFFFF5173FFFFFF"

    case String.split(payload) do
      [identifier, unix_time, data] ->
        %Frame{
          type: :extended,
          identifier: String.to_integer(identifier, 16),
          data: Base.decode16!(data),
          timestamp_ms: trunc(String.to_float(unix_time) * 1000)
        }

      [identifier, unix_time] ->
        %Frame{
          type: :extended,
          identifier: String.to_integer(identifier, 16),
          data: <<>>,
          timestamp_ms: trunc(String.to_float(unix_time) * 1000)
        }

      other ->
        Logger.warn("Bad frame format: #{inspect(other)}")
        nil
    end
  end
end
