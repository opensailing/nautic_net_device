defmodule NauticNet.CAN.Fake.Server do
  @moduledoc """
  GenServer implementation for a test CAN interface driver.
  """

  use GenServer

  require Logger

  alias NauticNet.CAN.CANUSB.Protocol
  alias NauticNet.NMEA2000.Frame

  @name __MODULE__
  @one_day_in_seconds 24 * 60 * 60

  defmodule State do
    defstruct close_device_fn: nil,
              latest_replay_timestamp: 0,
              replay_device: nil,
              replay_opts: [],
              replay_started_at: nil,
              replay_started_at_monotonic_ms: nil,
              parent_pid: nil
  end

  def replay_canusb_log(filename_or_list, opts \\ []) do
    GenServer.call(@name, {:replay_canusb_log, filename_or_list, opts}, :infinity)
  end

  def stop_replay do
    GenServer.call(@name, :stop_replay)
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, self(), name: @name)
  end

  def transmit_frame(frame) do
    GenServer.cast(@name, {:transmit_frame, frame})
  end

  def receive_frame(frame) do
    GenServer.cast(@name, {:receive_frame, frame})
  end

  @impl GenServer
  def init(parent_pid) do
    {:ok, %State{parent_pid: parent_pid}}
  end

  @impl GenServer
  def handle_call(
        {:replay_canusb_log, filename_or_list, opts},
        _sender,
        %State{replay_device: nil} = state
      ) do
    case open_log_device(filename_or_list, state) do
      {:ok, device, close_device_fn} ->
        NauticNet.Discovery.forget_all()

        state =
          %{
            state
            | latest_replay_timestamp: 0,
              replay_device: device,
              replay_started_at: DateTime.utc_now(),
              replay_started_at_monotonic_ms: System.monotonic_time(:millisecond),
              replay_opts: opts,
              close_device_fn: close_device_fn
          }
          |> read_next_log()

        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:stop_replay, _, %{replay_device: nil} = state), do: {:reply, :error, state}

  def handle_call(:stop_replay, _, state) do
    state.close_device_fn.()
    {:reply, :ok, %{state | replay_device: nil}}
  end

  @impl GenServer
  def handle_cast({:transmit_frame, _frame}, state) do
    # TODO: Persist frame in state for later assertion
    {:noreply, state}
  end

  def handle_cast({:receive_frame, frame}, state) do
    send(state.parent_pid, {:can_frame, frame})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:emit, command, timestamp_ms}, state) do
    if state.replay_device do
      emit_now(command, timestamp_ms, state)
    end

    {:noreply, read_next_log(state)}
  end

  defp read_next_log(%State{replay_device: nil} = state), do: state

  defp read_next_log(state) do
    state.replay_device
    |> IO.read(:line)
    |> case do
      :eof ->
        state.close_device_fn.()
        %{state | replay_device: nil}

      line when is_binary(line) ->
        line
        |> String.trim_trailing()
        |> String.split(" ")
        |> handle_log_line(state)
    end
  end

  # RX command
  defp handle_log_line(["<-", timestamp_ms, command], state) do
    timestamp_ms = String.to_integer(timestamp_ms)

    if state.replay_opts[:realtime?] do
      delay_ms = timestamp_ms - state.latest_replay_timestamp

      Process.send_after(self(), {:emit, command, timestamp_ms}, delay_ms)

      %{state | latest_replay_timestamp: timestamp_ms}
    else
      emit_now(command, timestamp_ms, state)
      read_next_log(state)
    end
  end

  # TX command
  defp handle_log_line(["->", _timestamp_ms, _command], state), do: read_next_log(state)

  # Comment
  defp handle_log_line(["#", _timestamp_ms, _comment], state), do: read_next_log(state)

  # Something wacky
  defp handle_log_line(_, state), do: read_next_log(state)

  defp emit_now(command, timestamp_ms, state) do
    with {:ok, %Frame{} = frame} <- Protocol.parse(command) do
      # We are emitting frames faster than realtime, so fudge the frame timestamp. Put it ~1 day
      # in the past so that we don't receive data from the "future".
      timestamp =
        state.replay_started_at
        |> DateTime.add(timestamp_ms, :millisecond)
        |> DateTime.add(-@one_day_in_seconds, :second)

      timestamp_monotonic_ms = state.replay_started_at_monotonic_ms + timestamp_ms
      frame = %{frame | timestamp: timestamp, timestamp_monotonic_ms: timestamp_monotonic_ms}

      send(state.parent_pid, {:can_frame, frame})
    end
  end

  defp open_log_device(filename, state) when is_binary(filename) do
    with {:ok, device} <- File.open(filename) do
      Logger.info("Starting replay of #{filename}")

      {:ok, device,
       fn ->
         File.close(device)
         Logger.info("Finished replay of #{filename}")
         send(state.parent_pid, :can_closed)
       end}
    end
  end

  defp open_log_device(list, state) when is_list(list) do
    with {:ok, device} <- list |> Enum.join("\n") |> StringIO.open() do
      {:ok, device,
       fn ->
         StringIO.close(device)
         send(state.parent_pid, :can_closed)
       end}
    end
  end
end
