defmodule RacingOrg.Tracker.Pro.Calibration.CheckpointTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Checkpoint, as: CalibrationCheckpoint
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.AwaOffset
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.AwsScale
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.StwScale
  alias RacingOrg.Tracker.Pro.Calibration.Estimate.Tracker
  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint, as: ContractCheckpoint

  describe "project/1" do
    test "projects a real observer store snapshot into deterministic closed calibration content" do
      snapshot = observer_snapshot()

      assert {:ok, content} = CalibrationCheckpoint.project(snapshot)

      assert Enum.map(content["awa_estimators"], & &1["hardware_identifier"]) == ["1A2B", "A0B1"]
      assert Enum.map(content["stw_estimators"], & &1["hardware_identifier"]) == ["2B3C", "C0D1"]
      assert Enum.map(content["aws_estimators"], & &1["hardware_identifier"]) == ["3C4D", "E0F1"]

      assert Enum.map(content["prev_applied"], &{&1["hardware_identifier"], &1["parameter"]}) == [
               {"1A2B", "awa_offset"},
               {"1A2B", "awa_upwash"},
               {"A0B1", "awa_offset"}
             ]

      assert_string_keyed(content)
      assert {:ok, _bytes} = ContractCheckpoint.encode_content(:calibration, 1, content)
    end

    test "normalizes supported integer-valued estimator options into canonical floats" do
      snapshot =
        put_in(
          observer_snapshot(),
          [:awa_estimators, "A0B1"],
          AwaOffset.new(clamp_min: -10, clamp_max: 10, max_slew: 1)
        )

      assert {:ok, content} = CalibrationCheckpoint.project(snapshot)
      estimator = Enum.find(content["awa_estimators"], &(&1["hardware_identifier"] == "A0B1"))

      assert estimator["rotation"]["clamp_min"] === -10.0
      assert estimator["rotation"]["clamp_max"] === 10.0
      assert estimator["rotation"]["max_slew"] === 1.0
      assert estimator["bands"]["clamp_min"] === -10.0
      assert estimator["bands"]["clamp_max"] === 10.0
    end

    test "rejects noncanonical sensor identities and open snapshot metadata" do
      snapshot = observer_snapshot()
      awa = snapshot.awa_estimators["1A2B"]

      for hardware_identifier <- ["1a2b", "0x1A2B", "sensor-name", <<0xFF>>] do
        invalid =
          snapshot
          |> put_in([:awa_estimators], %{hardware_identifier => awa})
          |> put_in([:prev_applied], %{})

        assert {:error, :invalid_calibration_checkpoint} = CalibrationCheckpoint.project(invalid)
      end

      assert {:error, :invalid_calibration_checkpoint} =
               snapshot
               |> Map.put(:metadata, %{token: "must-not-project"})
               |> CalibrationCheckpoint.project()

      estimator_with_metadata = Map.put(awa, :metadata, %{payload: "must-not-project"})
      invalid = put_in(snapshot, [:awa_estimators, "1A2B"], estimator_with_metadata)

      assert {:error, :invalid_calibration_checkpoint} = CalibrationCheckpoint.project(invalid)
    end
  end

  describe "hydrate/1" do
    test "round-trips through the durable Checkpoint codec into restore-ready estimator structs" do
      snapshot = observer_snapshot()

      assert {:ok, projected} = CalibrationCheckpoint.project(snapshot)
      assert {:ok, bytes} = ContractCheckpoint.encode_content(:calibration, 1, projected)
      assert {:ok, decoded} = ContractCheckpoint.decode_content(:calibration, 1, bytes)
      assert {:ok, hydrated} = CalibrationCheckpoint.hydrate(decoded)

      assert %AwaOffset{rotation: %Tracker{p50: %PSquare{q: q}}} = hydrated.awa_estimators["1A2B"]
      assert is_tuple(q)
      assert %StwScale{} = hydrated.stw_estimators["2B3C"]
      assert %AwsScale{} = hydrated.aws_estimators["3C4D"]
      assert hydrated.prev_applied == snapshot.prev_applied
      assert hydrated.seq == snapshot.seq

      assert AwaOffset.snapshot(hydrated.awa_estimators["1A2B"]) ==
               AwaOffset.snapshot(snapshot.awa_estimators["1A2B"])

      assert StwScale.snapshot(hydrated.stw_estimators["2B3C"]) ==
               StwScale.snapshot(snapshot.stw_estimators["2B3C"])

      assert AwsScale.snapshot(hydrated.aws_estimators["3C4D"]) ==
               AwsScale.snapshot(snapshot.aws_estimators["3C4D"])

      assert {:ok, ^decoded} = CalibrationCheckpoint.project(hydrated)
    end

    test "fails closed on malformed, open, or invariant-breaking content" do
      assert {:ok, content} = CalibrationCheckpoint.project(observer_snapshot())
      [awa | rest] = content["awa_estimators"]

      invalid_contents = [
        :not_a_map,
        Map.put(content, "metadata", %{"secret" => "must-not-hydrate"}),
        %{content | "awa_estimators" => [%{awa | "hardware_identifier" => "1a2b"} | rest]},
        %{content | "awa_estimators" => [put_in(awa, ["rotation", "count"], awa["pairs_seen"] + 1) | rest]}
      ]

      for invalid <- invalid_contents do
        assert {:error, :invalid_calibration_checkpoint} = CalibrationCheckpoint.hydrate(invalid)
      end
    end
  end

  defp observer_snapshot do
    awa = Enum.reduce(1..5, AwaOffset.new(), fn _, estimator -> AwaOffset.observe_pair(estimator, awa_pair()) end)

    stw =
      Enum.reduce(1..5, StwScale.new(), fn _, estimator ->
        StwScale.observe_pair(estimator, %{
          a: %{sog_mean: 3.6, stw_mean: 3.5},
          b: %{sog_mean: 3.6, stw_mean: 3.5}
        })
      end)

    aws =
      AwsScale.new(min_legs: 1)
      |> AwsScale.observe_leg(%{t_end_s: 100.0, tws_mean: 5.0, awa_abs_mean: 45.0})
      |> AwsScale.observe_leg(%{t_end_s: 200.0, tws_mean: 5.2, awa_abs_mean: 135.0})
      |> AwsScale.observe_leg(%{t_end_s: 300.0, tws_mean: 5.1, awa_abs_mean: 90.0})

    %{
      awa_estimators: %{"A0B1" => AwaOffset.new(), "1A2B" => awa},
      stw_estimators: %{"C0D1" => StwScale.new(), "2B3C" => stw},
      aws_estimators: %{"E0F1" => AwsScale.new(), "3C4D" => aws},
      prev_applied: %{
        {"A0B1", "awa_offset"} => 0.25,
        {"1A2B", "awa_upwash"} => -0.75,
        {"1A2B", "awa_offset"} => 1.25
      },
      seq: 7
    }
  end

  defp awa_pair do
    %{
      starboard: %{
        heading_mean: 315.0,
        stw_mean: 3.5,
        awa_mean_signed: 26.0,
        awa_abs_mean: 26.0,
        aws_mean: 8.8
      },
      port: %{
        heading_mean: 45.0,
        stw_mean: 3.5,
        awa_mean_signed: -32.0,
        awa_abs_mean: 32.0,
        aws_mean: 8.8
      }
    }
  end

  defp assert_string_keyed(value) when is_map(value) do
    assert Enum.all?(Map.keys(value), &is_binary/1)
    Enum.each(Map.values(value), &assert_string_keyed/1)
  end

  defp assert_string_keyed(value) when is_list(value), do: Enum.each(value, &assert_string_keyed/1)
  defp assert_string_keyed(_value), do: :ok
end
