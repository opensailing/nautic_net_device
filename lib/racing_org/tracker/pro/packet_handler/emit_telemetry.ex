defmodule RacingOrg.Tracker.Pro.PacketHandler.EmitTelemetry do
  use GenServer
  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(args) do
    filters = Keyword.get(args, :filters, %{})
    filter_mode = Keyword.get(args, :filter_mode)
    clock_source = Keyword.get(args, :clock_source, RacingOrg.Tracker.Pro.ClockSource.Config)
    Logger.info("Starting #{__MODULE__} in #{inspect(filter_mode)} mode\nwith filters: #{inspect(filters)}")
    {:ok, %{filters: filters, filter_mode: filter_mode, clock_source: clock_source}}
  end

  @impl true
  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{NMEA.WindParams => %NMEA.WindParams{speed: speed, angle: angle, reference: reference}},
           source_info: %NMEA.NMEA2000.Frame{timestamp: timestamp, timestamp_monotonic_ms: timestamp_monotonic_ms},
           metadata: %{source_nmea_name: source_name}
         }},
        state
      ) do
    if desired_device_or_permissive_mode?(state.filters, state.filter_mode, NMEA.WindData, source_name) do
      timestamp = boat_time(state.clock_source, timestamp, timestamp_monotonic_ms)

      :telemetry.execute(
        [:racing_org, :wind, reference],
        %{
          vector: %{
            timestamp: timestamp,
            angle: angle,
            magnitude: speed
          }
        },
        %{device_id: source_name, timestamp_monotonic_ms: timestamp_monotonic_ms}
      )
    end

    {:noreply, state}
  end

  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{NMEA.PositionParams => %NMEA.PositionParams{latitude: latitude, longitude: longitude}},
           source_info: %NMEA.NMEA2000.Frame{timestamp: timestamp, timestamp_monotonic_ms: timestamp_monotonic_ms},
           metadata: %{source_nmea_name: source_name}
         }},
        state
      ) do
    if desired_device_or_permissive_mode?(state.filters, state.filter_mode, NMEA.WindData, source_name) do
      timestamp = boat_time(state.clock_source, timestamp, timestamp_monotonic_ms)

      :telemetry.execute(
        [:racing_org, :gps],
        %{
          position: %{
            timestamp: timestamp,
            lat: latitude,
            lon: longitude
          }
        },
        %{device_id: source_name, timestamp_monotonic_ms: timestamp_monotonic_ms}
      )
    end

    {:noreply, state}
  end

  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{NMEA.TemperatureParams => %NMEA.TemperatureParams{temperature_k: temp}},
           source_info: %NMEA.NMEA2000.Frame{timestamp: timestamp, timestamp_monotonic_ms: timestamp_monotonic_ms},
           metadata: %{source_nmea_name: source_name}
         }},
        state
      ) do
    if desired_device_or_permissive_mode?(state.filters, state.filter_mode, NMEA.WindData, source_name) do
      timestamp = boat_time(state.clock_source, timestamp, timestamp_monotonic_ms)

      :telemetry.execute(
        [:racing_org, :temperature],
        %{
          timestamp: timestamp,
          kelvin: temp
        },
        %{device_id: source_name, timestamp_monotonic_ms: timestamp_monotonic_ms}
      )
    end

    {:noreply, state}
  end

  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{
             NMEA.CourseParams => %NMEA.CourseParams{
               course: course
             },
             NMEA.SpeedParams => %NMEA.SpeedParams{
               speed: speed,
               speed_reference: :speed_over_ground
             }
           },
           source_info: %NMEA.NMEA2000.Frame{timestamp: timestamp, timestamp_monotonic_ms: timestamp_monotonic_ms},
           metadata: %{source_nmea_name: source_name}
         }},
        state
      ) do
    if desired_device_or_permissive_mode?(state.filters, state.filter_mode, NMEA.WindData, source_name) do
      timestamp = boat_time(state.clock_source, timestamp, timestamp_monotonic_ms)

      :telemetry.execute(
        [:racing_org, :velocity, :ground],
        %{
          vector: %{
            timestamp: timestamp,
            angle: course,
            magnitude: speed
          }
        },
        %{device_id: source_name, timestamp_monotonic_ms: timestamp_monotonic_ms}
      )
    end

    {:noreply, state}
  end

  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{NMEA.SpeedParams => %NMEA.SpeedParams{speed: water_speed}},
           source_info: %NMEA.NMEA2000.Frame{timestamp: timestamp, timestamp_monotonic_ms: timestamp_monotonic_ms},
           metadata: %{source_nmea_name: source_name}
         }},
        state
      ) do
    if desired_device_or_permissive_mode?(state.filters, state.filter_mode, NMEA.WindData, source_name) do
      timestamp = boat_time(state.clock_source, timestamp, timestamp_monotonic_ms)

      :telemetry.execute(
        [:racing_org, :speed, :water],
        %{
          speed_m_s: %{
            timestamp: timestamp,
            value: water_speed
          }
        },
        %{device_id: source_name, timestamp_monotonic_ms: timestamp_monotonic_ms}
      )
    end

    {:noreply, state}
  end

  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{NMEA.DepthParams => %NMEA.DepthParams{depth: depth_m}},
           source_info: %NMEA.NMEA2000.Frame{timestamp: timestamp, timestamp_monotonic_ms: timestamp_monotonic_ms},
           metadata: %{source_nmea_name: source_name}
         }},
        state
      ) do
    if desired_device_or_permissive_mode?(state.filters, state.filter_mode, NMEA.WindData, source_name) do
      timestamp = boat_time(state.clock_source, timestamp, timestamp_monotonic_ms)

      :telemetry.execute(
        [:racing_org, :water_depth],
        %{
          depth_m: %{
            timestamp: timestamp,
            value: depth_m
          }
        },
        %{device_id: source_name, timestamp_monotonic_ms: timestamp_monotonic_ms}
      )
    end

    {:noreply, state}
  end

  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{NMEA.HeadingParams => %NMEA.HeadingParams{heading: heading}},
           source_info: %NMEA.NMEA2000.Frame{timestamp: timestamp, timestamp_monotonic_ms: timestamp_monotonic_ms},
           metadata: %{source_nmea_name: source_name}
         }},
        state
      ) do
    if desired_device_or_permissive_mode?(state.filters, state.filter_mode, NMEA.WindData, source_name) do
      timestamp = boat_time(state.clock_source, timestamp, timestamp_monotonic_ms)

      :telemetry.execute(
        [:racing_org, :heading],
        %{
          rad: %{
            timestamp: timestamp,
            value: heading
          }
        },
        %{device_id: source_name, timestamp_monotonic_ms: timestamp_monotonic_ms}
      )
    end

    {:noreply, state}
  end

  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{NMEA.AttitudeParams => %NMEA.AttitudeParams{yaw: yaw, pitch: pitch, roll: roll}},
           source_info: %NMEA.NMEA2000.Frame{timestamp: timestamp, timestamp_monotonic_ms: timestamp_monotonic_ms},
           metadata: %{source_nmea_name: source_name}
         }},
        state
      ) do
    if desired_device_or_permissive_mode?(state.filters, state.filter_mode, NMEA.WindData, source_name) do
      timestamp = boat_time(state.clock_source, timestamp, timestamp_monotonic_ms)

      :telemetry.execute(
        [:racing_org, :attitude],
        %{
          rad: %{
            timestamp: timestamp,
            yaw: yaw,
            pitch: pitch,
            roll: roll
          }
        },
        %{device_id: source_name, timestamp_monotonic_ms: timestamp_monotonic_ms}
      )
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    # Logger.debug("Unknown Data received: #{inspect(msg)}")
    {:noreply, state}
  end

  # The telemetry wall-clock timestamp: the boat clock resolved by the clock-source
  # policy (default RacingOrg.Tracker.Pro.ClockSource.Config). Falls back to the
  # frame's own receive timestamp (the current behavior) when no GPS timebase is
  # active or the clock-source server is unavailable. `timestamp_monotonic_ms` is
  # left untouched for ordering/damping.
  defp boat_time(clock_source, receive_ts, monotonic_ms) do
    RacingOrg.Tracker.Pro.ClockSource.Config.resolve_timestamp(clock_source, receive_ts, monotonic_ms)
  end

  defp desired_device_or_permissive_mode?(_filters, :permissive, _, _), do: true

  defp desired_device_or_permissive_mode?(filters, _, data_type, data_source) do
    allowed_source = Map.get(filters, data_type)
    allowed_source == data_source
  end
end
