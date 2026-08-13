defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.CalibrationTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.Calibration.Observer
  alias RacingOrg.Tracker.Pro.Calibration.Observer.Snapshot
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint, as: ContractCheckpoint
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.Calibration

  @capture_utc ~U[2026-08-10 12:00:00Z]
  @wire_sha256 "1bd6a9ccf506d2905a3b0470560bf1404f6377f3c9f2f5e8f33c21bb781e228a"
  @wire_size 2266

  test "projects and hydrates the complete exact Observer snapshot" do
    snapshot = internal_snapshot()

    assert {:ok, wire} = Calibration.project(snapshot)
    assert :ok = Calibration.validate(wire)
    assert {:ok, ^snapshot} = Calibration.hydrate(wire)
    assert :ok = Snapshot.preflight(snapshot)

    assert {:ok, bytes} = Canonical.encode(wire)
    assert byte_size(bytes) == @wire_size
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @wire_sha256
    assert {:ok, ^bytes} = ContractCheckpoint.canonical_content(:calibration, 2, wire)
    assert {:ok, ^wire} = ContractCheckpoint.decode_canonical_content(:calibration, 2, bytes)

    assert Map.keys(wire) |> Enum.sort() ==
             ~w(authority captured_at_utc_ms latest learner learner_time_basis legs policy stats sync tack tick version window_binding window_sources)

    window_binding = snapshot.window_binding
    assert %Canonical.Bytes{data: ^window_binding} = wire["window_binding"]
    refute Map.has_key?(wire, "metadata")
  end

  test "rejects unknown fields recursively, atom-keyed input, and closed-enum violations" do
    assert {:ok, wire} = Calibration.project(internal_snapshot())

    assert {:error, :checkpoint_secret_forbidden} = Calibration.validate(Map.put(wire, "metadata", %{}))
    assert {:error, :checkpoint_secret_forbidden} = Calibration.hydrate(Map.put(wire, "metadata", %{}))

    byte_wrapper_with_extra_key = Map.put(wire["window_binding"], "extension", true)

    invalid = [
      Map.put(wire, :extension, %{}),
      put_in(wire, ["policy", "awa_estimator", "global", "extension"], %{}),
      put_in(wire, ["window_binding"], byte_wrapper_with_extra_key),
      put_in(wire, ["window_binding"], Canonical.bytes(:binary.copy(<<0>>, 32))),
      put_in(wire, ["policy", "modes", "awa_offset"], "automatic"),
      Map.put(wire, "captured_at_utc_ms", 9_007_199_254_740_992),
      put_in(wire, ["learner", "seq"], 9_007_199_254_740_992),
      put_in(wire, ["latest"], [
        %{
          "age_ms" => 0,
          "channel" => "temperature",
          "hardware_identifier" => "1A2B",
          "value" => 1.0
        }
      ])
    ]

    Enum.each(invalid, fn candidate ->
      assert {:error, :invalid_checkpoint_content} = Calibration.validate(candidate)
      assert {:error, :invalid_checkpoint_content} = Calibration.hydrate(candidate)
    end)
  end

  test "preserves secret rejection and never creates atoms from input" do
    assert {:ok, wire} = Calibration.project(internal_snapshot())

    unknown = "untrusted_enum_#{System.unique_integer([:positive])}_#{System.monotonic_time()}"
    invalid_enum = put_in(wire, ["policy", "modes", "awa_offset"], unknown)
    non_nfc = put_in(wire, ["authority", "boat_identifier"], "é")

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    assert {:error, :invalid_checkpoint_content} = Calibration.validate(invalid_enum)
    assert {:error, :invalid_checkpoint_content} = Calibration.validate(non_nfc)
    assert {:error, :invalid_checkpoint_content} = Calibration.hydrate(invalid_enum)
    assert {:error, :invalid_checkpoint_content} = Calibration.hydrate(non_nfc)
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    secret = put_in(wire, ["policy", "api_token"], "forbidden")
    assert {:error, :checkpoint_secret_forbidden} = Calibration.validate(secret)
    assert {:error, :checkpoint_secret_forbidden} = Calibration.hydrate(secret)
  end

  test "project calls snapshot preflight and rejects malformed internal state" do
    invalid = Map.put(internal_snapshot(), :metadata, %{})
    assert {:error, :invalid_checkpoint_content} = Calibration.project(invalid)
  end

  defp internal_snapshot do
    {:ok, observer} =
      Observer.start_link(
        name: nil,
        sample_ms: 0,
        dir: nil,
        calibration: nil,
        boat_identifier: "boat-authority",
        sender: fn _channel, _update -> :ok end,
        now_fn: fn -> 10_000 end,
        utc_now_fn: fn -> @capture_utc end,
        sync_ms: 60_000,
        persist_ms: 60_000,
        legs: [min_duration_s: 30.0]
      )

    assert {:ok, snapshot} = Observer.snapshot(observer)
    snapshot
  end
end
