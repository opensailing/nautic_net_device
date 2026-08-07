defmodule RacingOrg.Tracker.Pro.HardwareIdentity.RaspberryPiSoCSerial do
  @moduledoc """
  Raspberry Pi SoC serial hardware-identity provider.

  The device-tree serial is the primary local source and the `Serial` field in
  `/proc/cpuinfo` is the fallback. Every source that is present must be valid and all
  present sources must identify the same SoC. Canonicalization is delegated to the
  versioned tracker contract so local and wire rules cannot diverge.

  File readers are injectable for host-side tests. A reader receives its exact source
  path and returns the same shape as `File.read/1`.
  """

  @behaviour RacingOrg.Tracker.Pro.HardwareIdentity

  alias RacingOrg.Tracker.Pro.SecureTransport.TrackerContractV2

  @device_tree_path "/proc/device-tree/serial-number"
  @cpuinfo_path "/proc/cpuinfo"
  @absent_read_reasons [:enoent, :enotdir]

  @type source :: :device_tree | :cpuinfo
  @type reader :: (binary() -> {:ok, binary()} | {:error, term()})
  @type error_reason ::
          :serial_unavailable
          | :invalid_serial_source
          | :ambiguous_serial_source
          | :conflicting_serial_sources
          | :invalid_serial_sources
          | {:serial_source_read_failed, source(), term()}

  @impl true
  @spec provider() :: binary()
  def provider, do: TrackerContractV2.provider()

  @impl true
  @spec identifier() :: {:ok, binary()} | {:error, error_reason()}
  def identifier, do: identifier([])

  @doc "Read the SoC serial using optional injected device-tree and cpuinfo readers."
  @spec identifier(keyword()) :: {:ok, binary()} | {:error, error_reason()}
  def identifier(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      device_tree_reader = Keyword.get(opts, :device_tree_reader, &File.read/1)
      cpuinfo_reader = Keyword.get(opts, :cpuinfo_reader, &File.read/1)

      with {:ok, device_tree_serial} <-
             read_optional_source(device_tree_reader, @device_tree_path, :device_tree),
           {:ok, cpuinfo} <- read_optional_source(cpuinfo_reader, @cpuinfo_path, :cpuinfo),
           {:ok, cpuinfo_serial} <- extract_cpuinfo_serial(cpuinfo) do
        TrackerContractV2.normalize_local_serial_sources([
          device_tree_serial,
          cpuinfo_serial
        ])
      end
    else
      {:error, :invalid_serial_sources}
    end
  end

  def identifier(_opts), do: {:error, :invalid_serial_sources}

  defp read_optional_source(reader, path, source) when is_function(reader, 1) do
    case reader.(path) do
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:error, reason} when reason in @absent_read_reasons ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {:serial_source_read_failed, source, reason}}

      _other ->
        {:error, {:serial_source_read_failed, source, :invalid_reader_result}}
    end
  rescue
    _exception -> {:error, {:serial_source_read_failed, source, :reader_failed}}
  catch
    _kind, _reason -> {:error, {:serial_source_read_failed, source, :reader_failed}}
  end

  defp read_optional_source(_reader, _path, source),
    do: {:error, {:serial_source_read_failed, source, :invalid_reader}}

  defp extract_cpuinfo_serial(nil), do: {:ok, nil}

  defp extract_cpuinfo_serial(cpuinfo) do
    cpuinfo
    |> :binary.split("\n", [:global])
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, serials} ->
      case parse_cpuinfo_line(line) do
        :not_serial -> {:cont, {:ok, serials}}
        {:ok, serial} -> {:cont, {:ok, [serial | serials]}}
        {:error, :invalid_serial_source} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:ok, nil}
      {:ok, [serial]} -> {:ok, serial}
      {:ok, _multiple} -> {:error, :ambiguous_serial_source}
      {:error, :invalid_serial_source} = error -> error
    end
  end

  defp parse_cpuinfo_line(line) do
    case :binary.match(line, ":") do
      {separator_offset, 1} ->
        key = line |> binary_part(0, separator_offset) |> trim_horizontal()

        if key == "Serial" do
          value_offset = separator_offset + 1
          value_size = byte_size(line) - value_offset
          {:ok, line |> binary_part(value_offset, value_size) |> trim_horizontal_leading()}
        else
          :not_serial
        end

      :nomatch ->
        if serial_key_without_separator?(line) do
          {:error, :invalid_serial_source}
        else
          :not_serial
        end
    end
  end

  defp serial_key_without_separator?(line) do
    case trim_horizontal_leading(line) do
      "Serial" -> true
      <<"Serial", byte, _rest::binary>> when byte in [0x09, 0x20] -> true
      _other -> false
    end
  end

  defp trim_horizontal(binary) do
    binary
    |> trim_horizontal_leading()
    |> trim_horizontal_trailing()
  end

  defp trim_horizontal_leading(<<byte, rest::binary>>) when byte in [0x09, 0x20],
    do: trim_horizontal_leading(rest)

  defp trim_horizontal_leading(binary), do: binary

  defp trim_horizontal_trailing(<<>>), do: <<>>

  defp trim_horizontal_trailing(binary) do
    offset = byte_size(binary) - 1

    if :binary.at(binary, offset) in [0x09, 0x20] do
      binary
      |> binary_part(0, offset)
      |> trim_horizontal_trailing()
    else
      binary
    end
  end
end
