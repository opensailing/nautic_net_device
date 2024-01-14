defmodule NauticNet.PacketHandler.CreateGPSLog do
  use GenServer

  @gpx_header """
  <?xml version="1.0" encoding="UTF-8"?>
  <gpx version="1.0">
    <trk><name>NauticNet Track</name><number>1</number><trkseg>
  """

  @gpx_footer """
    </trkseg></trk>
  </gpx>
  """

  @csv_header """
  time,lat,lon
  """

  @impl true
  def init(opts) do
    {format, opts} = Keyword.pop(opts, :format) || raise "required :format option of :gpx or :csv"

    state = init_format(format, opts)
    {:ok, state}
  end

  defp init_format(:gpx, _opts) do
    # apps/nautic_net_device/tmp/[timestamp].gpx
    path =
      Path.join([
        __DIR__,
        "..",
        "..",
        "..",
        "tmp",
        "#{DateTime.utc_now() |> DateTime.to_unix()}.gpx"
      ])

    file = File.open!(path, [:write])
    IO.puts(file, @gpx_header)
    %{format: :gpx, file: file}
  end

  defp init_format(:csv, _opts) do
    # apps/nautic_net_device/tmp/[timestamp].csv
    path =
      Path.join([
        __DIR__,
        "..",
        "..",
        "..",
        "tmp",
        "#{DateTime.utc_now() |> DateTime.to_unix()}.csv"
      ])

    file = File.open!(path, [:write])
    IO.write(file, @csv_header)
    %{format: :csv, file: file}
  end

  @impl true
  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{NMEA.PositionParams => %NMEA.PositionParams{latitude: latitude, longitude: longitude}},
           source_info: %NMEA.NMEA2000.Frame{timestamp: timestamp}
         }},
        %{
          format: :gpx,
          file: file
        } = state
      ) do
    time = timestamp |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    trkpt = ~s[<trkpt lat="#{latitude}" lon="#{longitude}"><time>#{time}></time></trkpt>]

    IO.puts(file, trkpt)

    {:noreply, state}
  end

  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{NMEA.PositionParams => %NMEA.PositionParams{latitude: latitude, longitude: longitude}},
           source_info: %NMEA.NMEA2000.Frame{timestamp: timestamp}
         }},
        %{
          format: :csv,
          file: file
        } = state
      ) do
    time = timestamp |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    line = "#{time},#{latitude},#{longitude}"

    IO.puts(file, line)

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  def handle_data(_data, _config), do: :ok

  # TODO: FIXME: Need to handle stopping of the GenServer to trigger this function
  def handle_closed(%{format: :gpx, file: file}) do
    IO.puts(file, @gpx_footer)
    File.close(file)
  end

  def handle_closed(%{format: :csv, file: file}) do
    File.close(file)
  end
end
