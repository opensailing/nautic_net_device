defmodule RacingOrg.Tracker.Pro.Upstream.TelemetryFilterTest do
  # async: false — exercises the module-registered (default-named) Upstream.Config
  # instance that Telemetry's hot path reads.
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.Telemetry
  alias RacingOrg.Tracker.Pro.Upstream.Config
  alias RacingOrg.Tracker.Protobuf

  @persistent_term_key {Config, :disabled_signals}

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_upstream_tel_#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    :persistent_term.erase(@persistent_term_key)

    on_exit(fn ->
      File.rm_rf(dir)
      :persistent_term.erase(@persistent_term_key)
    end)

    start_supervised!({Config, store_dir: dir})
    :ok
  end

  defp point(sample) do
    struct(Protobuf.DataSet.DataPoint, sample: sample)
  end

  defp all_sample_points do
    [
      point({:heading, struct(Protobuf.HeadingSample, angle_mrad: 1)}),
      point({:speed, struct(Protobuf.SpeedSample, speed_cm_s: 2)}),
      point({:velocity, struct(Protobuf.VelocitySample, speed_cm_s: 3)}),
      point({:wind_velocity, struct(Protobuf.WindVelocitySample, speed_cm_s: 4)}),
      point({:water_depth, struct(Protobuf.WaterDepthSample, depth_cm: 5)}),
      point({:attitude, struct(Protobuf.AttitudeSample, yaw_mrad: 6)}),
      point({:position, struct(Protobuf.PositionSample, latitude: 42.0, longitude: -70.0)})
    ]
  end

  test "with no config applied every sample type passes" do
    assert Telemetry.upstream_filtered(all_sample_points()) == all_sample_points()
  end

  test "a disabled signal's sample type is dropped; the rest pass" do
    {:ok, _} =
      Config.apply_config(Config, %{
        "version" => 1,
        "signals" => %{"wind" => false, "attitude" => false}
      })

    kept = Telemetry.upstream_filtered(all_sample_points())
    tags = Enum.map(kept, fn %{sample: {tag, _}} -> tag end)

    assert :wind_velocity not in tags
    assert :attitude not in tags
    assert :heading in tags
    assert :speed in tags
    assert :velocity in tags
    assert :water_depth in tags
    assert :position in tags
  end

  test "position always passes even when everything else is off" do
    {:ok, _} =
      Config.apply_config(Config, %{
        "version" => 2,
        "signals" => %{
          "heading" => false,
          "speed" => false,
          "velocity" => false,
          "wind" => false,
          "water_depth" => false,
          "attitude" => false
        }
      })

    kept = Telemetry.upstream_filtered(all_sample_points())
    assert [%{sample: {:position, _}}] = kept
  end

  test "unknown/tracker sample tags always pass (health is not filterable)" do
    {:ok, _} =
      Config.apply_config(Config, %{
        "version" => 3,
        "signals" => %{
          "heading" => false,
          "speed" => false,
          "velocity" => false,
          "wind" => false,
          "water_depth" => false,
          "attitude" => false
        }
      })

    tracker_point = point({:tracker, struct(Protobuf.TrackerSample)})
    assert Telemetry.upstream_filtered([tracker_point]) == [tracker_point]
  end
end
