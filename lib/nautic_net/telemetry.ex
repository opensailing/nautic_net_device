defmodule NauticNet.Telemetry do
  @moduledoc """
  Defines metrics and starts the telemetry reporter.

  See `NauticNet.PacketHandler.Telemetry` for where these metrics are emitted.
  """

  alias NauticNet.DataSetRecorder
  alias NauticNet.Protobuf

  def child_spec(_opts) do
    %{
      id: NauticNet.Telemetry,
      start:
        {NauticNet.Telemetry.Reporter, :start_link,
         [[metrics: metrics(), callback: &report_metric/3]]}
    }
  end

  defp metrics do
    import Telemetry.Metrics

    [
      # summary("nautic_net.temperature.kelvin", reporter_options: [every_ms: 1_000]),
      summary("nautic_net.wind.apparent.vector", reporter_options: [every_ms: 1_000]),
      last_value("nautic_net.gps.position", reporter_options: [every_ms: 1_000])
    ]
  end

  @doc """
  Pushes a measurement off the device.

  `metric_name` is a list of atoms for the measurement name, e.g. `[:nautic_net, :gps, :position]`.

  `device_id` is the device identifier tuple.

  For `last_value` of a number, the `value` is just that number.
  For `last_value` of a GPS position, the `value` is the map `%{lat: float, lon: float}`.
  For `last_value` of a vector, the `value` is the map `%{angle: float, magnitude: float}` with the angle in radians.
  For the `summary` of a number or vector, the map has the keys: `:min`, `:max`, `:mean`, `:median`, and `:count`.
  """
  @spec report_metric([atom], NauticNet.DeviceInfo.id(), term) :: term
  def report_metric(metric_name, device_id, value) do
    metric_name
    |> to_proto_data_points(device_id, value)
    |> DataSetRecorder.add_data_points()
  end

  defp to_proto_data_points([:nautic_net, :gps, :position], device_id, value) do
    [
      proto_data_point(device_id,
        sample: {:position, Protobuf.PositionSample.new(latitude: value.lat, longitude: value.lon)}
      )
    ]
  end

  defp to_proto_data_points([:nautic_net, :wind, :apparent, :vector], device_id, %{mean: value}) do
    [
      proto_data_point(device_id,
        sample:
          {:wind_velocity,
           Protobuf.WindVelocitySample.new(
             reference: Protobuf.WindReference.value(:WIND_REFERENCE_APPARENT),
             speed_kt: value.magnitude,
             angle_deg: rad2deg(value.angle)
           )}
      )
    ]
  end

  defp to_proto_data_points(_metric_name, _device_id, _value), do: []

  defp proto_data_point({_, unique_number}, fields) do
    [
      timestamp: Protobuf.to_proto_timestamp(DateTime.utc_now()),
      hw_unique_number: unique_number
    ]
    |> Keyword.merge(fields)
    |> Protobuf.DataSet.DataPoint.new()
  end

  defp rad2deg(rad), do: 180 * rad / :math.pi()
end
