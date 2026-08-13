defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.RuntimeRegistryTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.RuntimeRegistry

  defmodule CalibrationV2Adapter do
  end

  defmodule PolarV3Adapter do
  end

  defmodule WindShiftV2Adapter do
  end

  test "dispatches only the exact runtime schemas supplied by the injected registry" do
    assert {:ok, registry} =
             RuntimeRegistry.new([
               {:calibration, 2, CalibrationV2Adapter},
               {:polar, 3, PolarV3Adapter},
               {:wind_shift, 2, WindShiftV2Adapter}
             ])

    assert {:ok, CalibrationV2Adapter} = RuntimeRegistry.fetch(registry, :calibration, 2)
    assert {:ok, PolarV3Adapter} = RuntimeRegistry.fetch(registry, :polar, 3)
    assert {:ok, WindShiftV2Adapter} = RuntimeRegistry.fetch(registry, :wind_shift, 2)

    assert RuntimeRegistry.entries(registry) == [
             {:calibration, 2, CalibrationV2Adapter},
             {:polar, 3, PolarV3Adapter},
             {:wind_shift, 2, WindShiftV2Adapter}
           ]

    assert {:error, :unsupported_checkpoint_runtime_schema} =
             RuntimeRegistry.fetch(registry, :calibration, 1)

    assert {:error, :unsupported_checkpoint_runtime_schema} =
             RuntimeRegistry.fetch(registry, :polar, 2)

    assert {:error, :unsupported_checkpoint_runtime_schema} =
             RuntimeRegistry.fetch(registry, :wind_shift, 1)
  end

  test "does not infer a latest schema from the legacy learner checkpoint contract" do
    assert {:ok, registry} = RuntimeRegistry.new([{:calibration, 9, CalibrationV2Adapter}])

    assert {:ok, CalibrationV2Adapter} = RuntimeRegistry.fetch(registry, :calibration, 9)

    assert {:error, :unsupported_checkpoint_runtime_schema} =
             RuntimeRegistry.fetch(registry, :calibration, 1)
  end

  test "fails closed for unregistered kinds, duplicate schemas, and malformed entries" do
    assert {:ok, registry} = RuntimeRegistry.new([{:calibration, 2, CalibrationV2Adapter}])

    assert {:error, :unknown_checkpoint_runtime_kind} =
             RuntimeRegistry.fetch(registry, :telemetry, 2)

    assert {:error, :invalid_checkpoint_runtime_identity} =
             RuntimeRegistry.fetch(registry, "calibration", 2)

    assert {:error, :invalid_checkpoint_runtime_identity} =
             RuntimeRegistry.fetch(registry, :calibration, 0)

    assert {:error, :duplicate_checkpoint_runtime_schema} =
             RuntimeRegistry.new([
               {:calibration, 2, CalibrationV2Adapter},
               {:calibration, 2, PolarV3Adapter}
             ])

    for invalid <- [
          :not_a_registry,
          [{:calibration, 0, CalibrationV2Adapter}],
          [{"calibration", 2, CalibrationV2Adapter}],
          [{:calibration, 2, self()}],
          [{:calibration, 2}],
          [metadata: %{}]
        ] do
      assert {:error, :invalid_checkpoint_runtime_registry} = RuntimeRegistry.new(invalid)
    end
  end
end
