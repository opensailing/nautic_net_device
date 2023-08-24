defmodule NauticNet.PacketHandler.CreateGPSLog do
  @behaviour NauticNet.PacketHandler

  alias NauticNet.NMEA2000.J1939.GNSSPositionDataParams
  alias NauticNet.NMEA2000.Packet

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

  @impl NauticNet.PacketHandler
  def init(opts) do
    {format, opts} = Keyword.pop(opts, :format) || raise "required :format option of :gpx or :csv"

    init_format(format, opts)
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

  @impl NauticNet.PacketHandler
  def handle_packet(%Packet{parameters: %GNSSPositionDataParams{} = params}, %{
        format: :gpx,
        file: file
      }) do
    time = params.datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    trkpt = ~s[<trkpt lat="#{params.latitude}" lon="#{params.longitude}"><time>#{time}></time></trkpt>]

    IO.puts(file, trkpt)
  end

  def handle_packet(%Packet{parameters: %GNSSPositionDataParams{} = params}, %{
        format: :csv,
        file: file
      }) do
    time = params.datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    line = "#{time},#{params.latitude},#{params.longitude}"

    IO.puts(file, line)
  end

  def handle_packet(_packet, _config), do: :ok

  @impl NauticNet.PacketHandler
  def handle_data(_data, _config), do: :ok

  @impl NauticNet.PacketHandler
  def handle_closed(%{format: :gpx, file: file}) do
    IO.puts(file, @gpx_footer)
    File.close(file)
  end

  def handle_closed(%{format: :csv, file: file}) do
    File.close(file)
  end
end
