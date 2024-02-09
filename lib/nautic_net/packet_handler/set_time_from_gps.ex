defmodule NauticNet.PacketHandler.SetTimeFromGPS do
  @moduledoc """
  Packet Handler that accepts data from either a NMEA.NMEA2000.VirtualDevice (via handle_info) or
  from an 0183 source (via handle_data) and sets the system clock if the time is "reasonable".

  A "reasonable" time is computes as being more then 10 seconds in the future. This threshold is used
  to throw out GPSs that report erronious times (like years in the past).

  Future work should include unifying the handle_info and handle_data into. They are seperate only because
  a full refactor has not been completed.
  """
  use GenServer
  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_) do
    GenServer.start_link(__MODULE__, [])
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{NMEA.DateTimeParams => %NMEA.DateTimeParams{datetime: datetime}}
         }},
        state
      ) do
    maybe_set_system_clock(datetime)
    {:noreply, state}
  end

  def handle_info(_data, state), do: {:noreply, state}

  @spec handle_data(%NMEA.Data{}, any()) :: :ok
  def handle_data(%NMEA.Data{values: %NMEA.DateTimeParams{datetime: gps_datetime = %DateTime{}}}, _config) do
    maybe_set_system_clock(gps_datetime)
  end

  def handle_data(_packet, _config), do: :ok

  @spec handle_closed(any()) :: :ok
  def handle_closed(_config), do: :ok

  # If the system time differs from the GPS time by more than 10 seconds and the new time is in the future
  # then update the system time (assumes the system is in the UTC timezone)
  defp maybe_set_system_clock(gps_datetime) do
    diff = abs(DateTime.diff(gps_datetime, DateTime.utc_now()))
    direction = DateTime.compare(gps_datetime, DateTime.utc_now())

    if diff > 10 and direction == :gt do
      gps_datetime
      |> DateTime.to_naive()
      |> NervesTime.set_system_time()
    end

    :ok
  end
end
