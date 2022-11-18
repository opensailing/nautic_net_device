defmodule NauticNet.CAN.CANUSB.Framing do
  @moduledoc """
  Special framing for the CANUSB device that is based almost entirely on
  `Circuits.UART.Framing.Line` with an extra affordance for the bell character "\a".
  """
  @behaviour Circuits.UART.Framing

  defmodule State do
    @moduledoc false
    defstruct max_length: nil, separator: nil, processed: <<>>, in_process: <<>>
  end

  @impl true
  def init(args) do
    max_length = Keyword.get(args, :max_length, 4096)
    separator = Keyword.get(args, :separator, "\r")

    state = %State{max_length: max_length, separator: separator}
    {:ok, state}
  end

  @impl true
  def add_framing(data, state) do
    {:ok, data <> state.separator, state}
  end

  @impl true
  def remove_framing(data, state) do
    {new_processed, new_in_process, lines} =
      process_data(
        state.separator,
        byte_size(state.separator),
        state.max_length,
        state.processed,
        state.in_process <> data,
        []
      )

    new_state = %{state | processed: new_processed, in_process: new_in_process}
    rc = if buffer_empty?(new_state), do: :ok, else: :in_frame
    {rc, lines, new_state}
  end

  @impl true
  def flush(direction, state) when direction == :receive or direction == :both do
    %{state | processed: <<>>, in_process: <<>>}
  end

  def flush(:transmit, state) do
    state
  end

  @impl true
  def frame_timeout(state) do
    partial_line = {:partial, state.processed <> state.in_process}
    new_state = %{state | processed: <<>>, in_process: <<>>}
    {:ok, [partial_line], new_state}
  end

  defp buffer_empty?(%State{processed: <<>>, in_process: <<>>}), do: true
  defp buffer_empty?(_state), do: false

  # Handle not enough data case
  defp process_data(_separator, sep_length, _max_length, processed, to_process, lines)
       when byte_size(to_process) < sep_length do
    {processed, to_process, lines}
  end

  # Process data until separator or next char
  defp process_data(separator, sep_length, max_length, processed, to_process, lines) do
    case to_process do
      # CANUSB: Emit a bell line immediately
      <<"\a", rest::binary>> ->
        new_lines = lines ++ ["\a"]
        process_data(separator, sep_length, max_length, <<>>, rest, new_lines)

      # Handle separater
      <<^separator::binary-size(sep_length), rest::binary>> ->
        new_lines = lines ++ [processed]
        process_data(separator, sep_length, max_length, <<>>, rest, new_lines)

      # Handle line too long case
      to_process
      when byte_size(processed) == max_length and to_process != <<>> ->
        new_lines = lines ++ [{:partial, processed}]
        process_data(separator, sep_length, max_length, <<>>, to_process, new_lines)

      # Handle next char
      <<next_char::binary-size(1), rest::binary>> ->
        process_data(separator, sep_length, max_length, processed <> next_char, rest, lines)
    end
  end
end
