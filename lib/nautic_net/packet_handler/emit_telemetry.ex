defmodule NauticNet.PacketHandler.EmitTelemetry do
  use GenServer

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
           values: %{NMEA.WindParams => %NMEA.WindParams{speed: speed, angle: angle, reference: reference}},
           source_info: %NMEA.NMEA2000.Frame{timestamp: timestamp, timestamp_monotonic_ms: timestamp_monotonic_ms},
           metadata: %{source_nmea_name: source_name}
         }},
        state
      ) do
    :telemetry.execute(
      [:nautic_net, :wind, reference],
      %{
        vector: %{
          timestamp: timestamp,
          angle: angle,
          magnitude: speed
        }
      },
      %{device_id: source_name, timestamp_monotonic_ms: timestamp_monotonic_ms}
    )

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
    :telemetry.execute(
      [:nautic_net, :gps],
      %{
        position: %{
          timestamp: timestamp,
          lat: latitude,
          lon: longitude
        }
      },
      %{device_id: source_name, timestamp_monotonic_ms: timestamp_monotonic_ms}
    )

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
    :telemetry.execute(
      [:nautic_net, :temperature],
      %{
        timestamp: timestamp,
        kelvin: temp
      },
      %{device_id: source_name, timestamp_monotonic_ms: timestamp_monotonic_ms}
    )

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
    :telemetry.execute(
      [:nautic_net, :velocity, :ground],
      %{
        vector: %{
          timestamp: timestamp,
          angle: course,
          magnitude: speed
        }
      },
      %{device_id: source_name, timestamp_monotonic_ms: timestamp_monotonic_ms}
    )

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
    :telemetry.execute(
      [:nautic_net, :speed, :water],
      %{
        speed_m_s: %{
          timestamp: timestamp,
          value: water_speed
        }
      },
      %{device_id: source_name, timestamp_monotonic_ms: timestamp_monotonic_ms}
    )

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
    :telemetry.execute(
      [:nautic_net, :water_depth],
      %{
        depth_m: %{
          timestamp: timestamp,
          value: depth_m
        }
      },
      %{device_id: source_name, timestamp_monotonic_ms: timestamp_monotonic_ms}
    )

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
    :telemetry.execute(
      [:nautic_net, :heading],
      %{
        rad: %{
          timestamp: timestamp,
          value: heading
        }
      },
      %{device_id: source_name, timestamp_monotonic_ms: timestamp_monotonic_ms}
    )

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
    :telemetry.execute(
      [:nautic_net, :heading],
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

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    # Logger.debug("Unknown Data received: #{inspect(msg)}")
    {:noreply, state}
  end
end
