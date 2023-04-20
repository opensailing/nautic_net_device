defmodule NauticNet.Telemetry.Reporter do
  @moduledoc """
  Telemetry reporter

  Based heavily on the source of `Telemetry.Metrics.ConsoleReporter`.

  ## Supported metric types

      [
        # Report every single measurement as soon as it happens
        last_value("some.metric.value", reporter_options: [asap?: true]),

        # Report the latest measurement at a minimum time interval; if there are no
        # measurements, nothing is reported
        last_value("some.metric.value", reporter_options: [every_ms: 10]),

        # Report a measurement summary at a minimum time interval; if there are no
        # measurements, nothing is reported
        summary("some.metric.value", reporter_options: [every_ms: 10])
      ]
  """

  use GenServer
  require Logger

  alias Telemetry.Metrics.LastValue
  alias Telemetry.Metrics.Summary

  @doc """
  Starts the reporter.

  ## Options

  - `:metrics` - required; a list of telemetry metrics
  - `:callback` - required; 3-arity function to invoke when a metric is ready to report (metric_name, device_id, and value)
  """
  def start_link(opts) do
    server_opts = Keyword.take(opts, [:name])

    metrics =
      opts[:metrics] ||
        raise ArgumentError, "the :metrics option is required by #{inspect(__MODULE__)}"

    callback =
      opts[:callback] ||
        raise ArgumentError, "the :callback option is required by #{inspect(__MODULE__)}"

    GenServer.start_link(__MODULE__, %{metrics: metrics, callback: callback}, server_opts)
  end

  @doc false
  def report(pid, metric) do
    GenServer.call(pid, {:report, metric})
  end

  @impl true
  @doc false
  def init(%{metrics: metrics, callback: callback}) do
    Process.flag(:trap_exit, true)
    groups = Enum.group_by(metrics, & &1.event_name)

    # Tables need to be public because handle_event/4 is invoked from a different process
    tables = %{
      LastValue => :ets.new(__MODULE__.LastValue, [:public, :duplicate_bag]),
      Summary => :ets.new(__MODULE__.Summary, [:public, :duplicate_bag])
    }

    # Attach Telemetry event handlers
    for {event, event_metrics} <- groups do
      id = {__MODULE__, event, self()}

      # The fourth arg passed to handle_event/4
      config = %{
        tables: tables,
        callback: callback,
        metrics: event_metrics,
        reporter_pid: self()
      }

      # Capture the public handle_event/4 API for Telemetry performance reasons
      :telemetry.attach(id, event, &__MODULE__.handle_event/4, config)
    end

    state = %{
      tables: tables,
      events: Map.keys(groups),
      callback: callback
    }

    {:ok, state}
  end

  def needs_report_at?(metric, current_monotonic_ms, config) do
    cond do
      metric.reporter_options[:asap?] ->
        true

      every_ms = metric.reporter_options[:every_ms] ->
        table = config.tables[metric.__struct__]
        rows = :ets.lookup(table, metric.name)

        if rows == [] do
          # Nothing to report
          false
        else
          # Determine if enough time has elapsed by comparing the earliest timestamp in ETS to now
          earliest_monotonic_ms =
            rows
            |> Enum.map(fn {_metric_name, _measurement, metadata} ->
              metadata.timestamp_monotonic_ms
            end)
            |> Enum.min()

          current_monotonic_ms - earliest_monotonic_ms > every_ms
        end
    end
  end

  @impl true
  def handle_call({:report, metric}, _, state) do
    table = state.tables[metric.__struct__]
    rows = :ets.lookup(table, metric.name)
    :ets.delete(table, metric.name)

    device_ids =
      rows
      |> Enum.map(fn {_metric_name, _measurement, metadata} -> metadata.device_id end)
      |> Enum.uniq()

    for device_id <- device_ids do
      measurements =
        rows
        |> Enum.filter(fn {_, _, %{device_id: id}} -> id == device_id end)
        |> Enum.map(fn {_, m, _} -> m end)

      report_on(metric, device_id, measurements, state.callback)
    end

    {:reply, :ok, state}
  end

  @impl true
  def terminate(_, state) do
    for event <- state.events do
      :telemetry.detach({__MODULE__, event, self()})
    end

    :ok
  end

  # Telemetry callback (not run in the GenServer)
  def handle_event(event_name, measurements, metadata, config) do
    for metric <- config.metrics do
      measurement = extract_measurement(metric, measurements, metadata)
      tags = extract_tags(metric, metadata)

      if keep?(metric, metadata) do
        # Check for reportability BEFORE recording this measurement, so that we know when the last measurement
        # was received so that we can compare the current event's timestamp to the previous events'
        if needs_report_at?(metric, metadata.timestamp_monotonic_ms, config) do
          # This is a blocking call... not ideal, but it was done this way to ensure we only report on EXISTING
          # measurements only, before aggregating the current measurement
          report(config.reporter_pid, metric)
        end

        aggregate(metric, event_name, measurement, metadata, tags, config)
      end
    end
  end

  # Telemetry boilerplate
  defp extract_measurement(metric, measurements, metadata) do
    case metric.measurement do
      fun when is_function(fun, 2) -> fun.(measurements, metadata)
      fun when is_function(fun, 1) -> fun.(measurements)
      key -> measurements[key]
    end
  end

  # Telemetry boilerplate
  defp extract_tags(metric, metadata) do
    tag_values = metric.tag_values.(metadata)
    Map.take(tag_values, metric.tags)
  end

  # Telemetry boilerplate
  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(metric, metadata), do: metric.keep.(metadata)

  # Time to record something to ETS
  defp aggregate(%LastValue{} = metric, _event_name, measurement, metadata, _tags, config) do
    :ets.insert(config.tables[LastValue], {metric.name, measurement, metadata})
  end

  defp aggregate(%Summary{} = metric, _event_name, measurement, metadata, _tags, config) do
    :ets.insert(config.tables[Summary], {metric.name, measurement, metadata})
  end

  # Time to report it to the world
  defp report_on(%LastValue{} = _metric, _device_id, [], _callback), do: :noop

  defp report_on(%LastValue{} = metric, device_id, measurements, callback) do
    callback.(metric.name, device_id, List.last(measurements))
  end

  defp report_on(%Summary{} = _metric, _device_id, [], _callback), do: :noop

  # Compute vector (angle & magnitude) summaries for wind, etc.
  defp report_on(
         %Summary{} = metric,
         device_id,
         [%{angle: _, magnitude: _} | _] = measurements,
         callback
       ) do
    # The summary periods will be very short, so this timestamp is close enough
    timestamp = hd(measurements).timestamp

    count = length(measurements)

    # Pick the min and max vectors based purely on magnitude
    {min, max} = Enum.min_max_by(measurements, & &1.magnitude)

    # Pick the median vector based purely on magnitude... I have no idea if this makes any sense or
    # is meaningful in any way.
    median = Enum.sort_by(measurements, & &1.magnitude) |> Enum.at(trunc(count / 2))

    # To find the mean, first add up all the vectors in Cartesian coordinates
    {x_sum, y_sum} =
      Enum.reduce(
        measurements,
        {0, 0},
        fn %{angle: angle_rad, magnitude: magnitude}, {x_sum, y_sum} ->
          {x_sum + magnitude * :math.cos(angle_rad), y_sum + magnitude * :math.sin(angle_rad)}
        end
      )

    # Then calculate the mean vector in Cartesian coordinates
    {x_mean, y_mean} = {x_sum / count, y_sum / count}

    # Finally, convert back to polar coordinates
    mean = %{
      magnitude: :math.sqrt(x_mean * x_mean + y_mean * y_mean),
      angle: if(x_mean == 0, do: 0, else: :math.atan(y_mean / x_mean))
    }

    callback.(metric.name, device_id, %{
      timestamp: timestamp,
      min: min,
      max: max,
      mean: mean,
      median: median,
      count: count
    })
  end

  defp report_on(%Summary{} = metric, device_id, [measurement | _] = measurements, callback)
       when is_number(measurement) do
    # The summary periods will be very short, so this timestamp is close enough
    timestamp = hd(measurements).timestamp

    # TODO: Make this more efficient
    count = length(measurements)
    {min, max} = Enum.min_max(measurements)
    median = Enum.sort(measurements) |> Enum.at(trunc(count / 2))
    sum = Enum.sum(measurements)

    callback.(metric.name, device_id, %{
      timestamp: timestamp,
      min: min,
      max: max,
      mean: sum / count,
      median: median,
      count: count
    })
  end
end
