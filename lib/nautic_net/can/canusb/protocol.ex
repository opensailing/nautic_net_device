defmodule NauticNet.CAN.CANUSB.Protocol do
  @moduledoc """
  Generates and parses command messages for the CANUSB serial interface device.

  Documentation: http://www.can232.com/docs/canusb_manual.pdf
  """

  alias NauticNet.NMEA2000.Frame

  def separator, do: "\r"

  def set_bit_rate(10), do: "S0"
  def set_bit_rate(20), do: "S1"
  def set_bit_rate(50), do: "S2"
  def set_bit_rate(100), do: "S3"
  def set_bit_rate(125), do: "S4"
  def set_bit_rate(250), do: "S5"
  def set_bit_rate(500), do: "S6"
  def set_bit_rate(800), do: "S7"
  def set_bit_rate(1_000), do: "S8"

  def set_btr_bit_rates(btr0, btr1) do
    "s" <> to_hex(btr0) <> to_hex(btr1)
  end

  def open_channel, do: "O"

  def close_channel, do: "C"

  def transmit_frame(%Frame{} = frame) do
    command = if frame.type == :standard, do: "t", else: "T"
    identifier = to_identifier(frame.identifier, frame.type)
    data_length = to_string(Frame.data_length(frame))
    data = to_hex(frame.data)

    command <> identifier <> data_length <> data
  end

  def transmit_rtr_frame(%Frame{} = frame) do
    command = if frame.type == :standard, do: "r", else: "R"
    identifier = to_identifier(frame.identifier, frame.type)
    data_length = to_string(Frame.data_length(frame))

    command <> identifier <> data_length
  end

  defp to_identifier(identifier, :standard) do
    to_hex(identifier, length: 3)
  end

  defp to_identifier(identifier, :extended) do
    to_hex(identifier, length: 8)
  end

  def read_status_flags, do: "F"

  def set_acceptance_code(code) do
    "M" <> to_hex(code, length: 8)
  end

  def set_acceptance_mask(mask) do
    "m" <> to_hex(mask, length: 8)
  end

  def get_version, do: "V"

  def get_serial_number, do: "N"

  def set_timestamps(on) do
    value = if on, do: "1", else: "0"
    "Z" <> value
  end

  defp to_hex(value, opts \\ [])

  defp to_hex(binary, _opts) when is_binary(binary) do
    Base.encode16(binary, case: :upper)
  end

  defp to_hex(int, opts) when is_integer(int) do
    length = opts[:length] || 2

    int
    |> Integer.to_string(16)
    |> String.pad_leading(length, "0")
  end

  defp from_hex(string) when is_binary(string) do
    String.to_integer(string, 16)
  end

  def parse("\a"), do: {:ok, :error}
  def parse(""), do: {:ok, :ok}
  def parse("z"), do: {:ok, :ok}
  def parse("Z"), do: {:ok, :ok}

  def parse(<<"t", identifier_hex::binary-3, data_length_hex::binary-1, payload::binary>> = data) do
    identifier = from_hex(identifier_hex)

    case parse_frame_payload(data_length_hex, payload) do
      {:ok, data, timestamp} ->
        {:ok,
         %Frame{
           type: :standard,
           identifier: identifier,
           data: data,
           timestamp_ms: timestamp
         }}

      :error ->
        {:error, data}
    end
  end

  def parse(<<"T", identifier_hex::binary-8, data_length_hex::binary-1, payload::binary>> = data) do
    identifier = from_hex(identifier_hex)

    case parse_frame_payload(data_length_hex, payload) do
      {:ok, data, timestamp} ->
        {:ok,
         %Frame{
           type: :extended,
           identifier: identifier,
           data: data,
           timestamp_ms: timestamp
         }}

      :error ->
        {:error, data}
    end
  end

  def parse(<<"F", hex_value::binary-2>>) do
    flags = from_hex(hex_value)

    <<
      bus_error?::1,
      arbitration_lost?::1,
      error_passive?::1,
      _::1,
      data_overrun?::1,
      error_warning?::1,
      transmit_fifo_queue_full?::1,
      receive_fifo_queue_full?::1
    >> = <<flags>>

    {:ok,
     {:status_flags,
      %{
        receive_fifo_queue_full?: receive_fifo_queue_full?,
        transmit_fifo_queue_full?: transmit_fifo_queue_full?,
        error_warning?: error_warning?,
        data_overrun?: data_overrun?,
        error_passive?: error_passive?,
        arbitration_lost?: arbitration_lost?,
        bus_error?: bus_error?
      }}}
  end

  def parse(<<"V", hw_version_hex::binary-2, sw_version_hex::binary-2>>) do
    hw_version = from_hex(hw_version_hex)
    sw_version = from_hex(sw_version_hex)

    {:ok,
     {:version,
      %{
        software_version: sw_version,
        hardware_version: hw_version
      }}}
  end

  def parse(<<"N", serial_number::binary-4>>) do
    {:ok, {:serial_number, serial_number}}
  end

  def parse(data), do: {:error, data}

  defp parse_frame_payload(data_length_hex, payload) do
    data_hex_length = from_hex(data_length_hex) * 2

    case payload do
      <<data_hex::binary-size(data_hex_length)>> ->
        data = Base.decode16!(data_hex)
        {:ok, data, 0}

      <<data_hex::binary-size(data_hex_length), timestamp_hex::binary-4>> ->
        data = Base.decode16!(data_hex)
        timestamp = from_hex(timestamp_hex)
        {:ok, data, timestamp}

      _else ->
        :error
    end
  end
end
