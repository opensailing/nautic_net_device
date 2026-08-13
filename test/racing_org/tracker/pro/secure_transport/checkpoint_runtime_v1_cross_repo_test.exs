Code.require_file(Path.expand("../../../../support/backend_checkpoint_runtime_direct_source.exs", __DIR__))

defmodule RacingOrg.Tracker.Pro.SecureTransport.CheckpointRuntimeV1CrossRepoTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.Calibration.Observer, as: CalibrationObserver
  alias RacingOrg.Tracker.Pro.Polar.Observer, as: PolarObserver
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.Calibration,
    as: CalibrationRuntime

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.Polar,
    as: PolarRuntime

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.WindShift,
    as: WindShiftRuntime

  alias RacingOrg.Tracker.Pro.TestSupport.BackendCheckpointRuntimeDirectSource,
    as: Backend

  alias RacingOrg.Tracker.Pro.WindShift.Observer, as: WindShiftObserver

  @capture_utc ~U[2026-08-12 12:00:00Z]
  @capture_ms 10_000
  @device_id <<1::128>>
  @storage_epoch <<2::128>>
  @authority %{
    device_id: @device_id,
    credential_epoch: 7,
    storage_epoch: @storage_epoch
  }

  setup_all do
    fixtures = runtime_fixtures()
    {:ok, backend: Backend.snapshot!(Enum.map(fixtures, &backend_fixture/1)), fixtures: fixtures}
  end

  test "direct backend source is isolated and discovered independently of the caller cwd", %{
    backend: backend
  } do
    expected_root = Path.expand("../../../../../../racing_org/website/backend", __DIR__)

    assert Backend.default_backend_root() == expected_root
    assert backend.isolation.mix_loaded? == false
    assert backend.isolation.racing_org_started? == false
    assert backend.isolation.launcher_basename == "elixir"
    assert backend.isolation.launcher == System.find_executable("elixir")
    assert backend.runtime_schemas == [calibration: 2, polar: 3, wind_shift: 2]
  end

  test "exact runtime codecs produce byte-identical canonical content, hashes, and decoded values",
       %{backend: backend, fixtures: fixtures} do
    for fixture <- fixtures do
      tracker = tracker_result(fixture)
      backend_result = Map.fetch!(backend.results, fixture.id)

      assert backend_result.canonical_content == tracker.canonical_content,
             parity_failure(fixture, :canonical_content, tracker, backend_result)

      assert backend_result.content_hash == tracker.content_hash,
             parity_failure(fixture, :content_hash, tracker, backend_result)

      assert backend_result.checkpoint_hash == tracker.checkpoint_hash,
             parity_failure(fixture, :checkpoint_hash, tracker, backend_result)

      assert backend_result.decoded == tracker.decoded,
             parity_failure(fixture, :decoded, tracker, backend_result)

      assert tracker.decoded == portable(fixture.wire)
    end
  end

  test "wind_shift v2 durable authority validation has identical verdicts", %{
    backend: backend,
    fixtures: fixtures
  } do
    for fixture <- Enum.filter(fixtures, &(&1.kind == :wind_shift)) do
      tracker = tracker_result(fixture)
      backend_result = Map.fetch!(backend.results, fixture.id)

      assert tracker.authority_validation == :ok
      assert backend_result.authority_validation == tracker.authority_validation

      mismatched = %{@authority | credential_epoch: @authority.credential_epoch + 1}

      assert Checkpoint.validate_authority(
               fixture.kind,
               fixture.schema_version,
               tracker.canonical_content,
               mismatched
             ) == {:error, :checkpoint_authority_mismatch}

      assert backend_result.mismatched_authority_validation ==
               {:error, :checkpoint_authority_mismatch}
    end
  end

  test "a deterministic wind_shift v2 runtime exceeds one frame without losing parity", %{
    backend: backend,
    fixtures: fixtures
  } do
    fixture = Enum.find(fixtures, &(&1.id == :wind_shift_v2_large))
    tracker = tracker_result(fixture)
    backend_result = Map.fetch!(backend.results, fixture.id)

    assert byte_size(tracker.canonical_content) > 65_327
    assert get_in(fixture.wire, ["runtime", "envelope", "minq", "count"]) == 3_000
    assert get_in(fixture.wire, ["runtime", "envelope", "maxq", "count"]) == 3_000
    assert backend_result.canonical_content == tracker.canonical_content
    assert backend_result.content_hash == tracker.content_hash
    assert backend_result.checkpoint_hash == tracker.checkpoint_hash
  end

  defp runtime_fixtures do
    calibration = calibration_wire!()
    polar = polar_wire!()
    wind_shift_snapshot = wind_shift_snapshot!()
    {:ok, wind_shift} = WindShiftRuntime.project(wind_shift_snapshot)
    {:ok, large_wind_shift} = WindShiftRuntime.project(enlarge_wind_shift(wind_shift_snapshot))

    [
      fixture(:calibration_v2, :calibration, 2, calibration, 1),
      fixture(:polar_v3, :polar, 3, polar, 1),
      fixture(:wind_shift_v2, :wind_shift, 2, wind_shift, 1, @authority),
      fixture(:wind_shift_v2_large, :wind_shift, 2, large_wind_shift, 2, @authority)
    ]
  end

  defp fixture(id, kind, schema_version, wire, sequence, authority \\ nil) do
    %{
      id: id,
      kind: kind,
      schema_version: schema_version,
      wire: wire,
      authority: authority,
      checkpoint_attrs: %{
        device_id: @device_id,
        credential_epoch: 7,
        storage_epoch: @storage_epoch,
        sequence: sequence,
        kind: kind,
        schema_version: schema_version,
        source_generation: 1,
        parent_hash: <<0::256>>
      }
    }
  end

  defp backend_fixture(fixture) do
    fixture
    |> Map.update!(:wire, &portable/1)
    |> Map.update(:authority, nil, &portable/1)
  end

  defp tracker_result(fixture) do
    assert {:ok, canonical_content} =
             Checkpoint.canonical_content(fixture.kind, fixture.schema_version, fixture.wire)

    assert {:ok, content_hash} =
             Checkpoint.content_hash(fixture.kind, fixture.schema_version, canonical_content)

    checkpoint_attrs = Map.put(fixture.checkpoint_attrs, :content_hash, content_hash)
    assert {:ok, checkpoint_hash} = Checkpoint.hash(checkpoint_attrs)

    assert {:ok, decoded} =
             Checkpoint.decode_canonical_content(
               fixture.kind,
               fixture.schema_version,
               canonical_content
             )

    authority_validation =
      if fixture.authority do
        Checkpoint.validate_authority(
          fixture.kind,
          fixture.schema_version,
          canonical_content,
          fixture.authority
        )
      end

    %{
      canonical_content: canonical_content,
      content_hash: content_hash,
      checkpoint_hash: checkpoint_hash,
      decoded: portable(decoded),
      authority_validation: authority_validation
    }
  end

  defp calibration_wire! do
    {:ok, observer} =
      CalibrationObserver.start_link(
        name: nil,
        sample_ms: 0,
        dir: nil,
        calibration: nil,
        boat_identifier: "boat-runtime",
        sender: fn _channel, _update -> :ok end,
        now_fn: fn -> @capture_ms end,
        utc_now_fn: fn -> @capture_utc end,
        sync_ms: 60_000,
        persist_ms: 60_000,
        legs: [min_duration_s: 30.0]
      )

    try do
      assert {:ok, snapshot} = CalibrationObserver.snapshot(observer)
      assert {:ok, wire} = CalibrationRuntime.project(snapshot)
      wire
    after
      GenServer.stop(observer)
    end
  end

  defp polar_wire! do
    signals = %{
      "boat_speed" => {4.0, @capture_ms},
      "true_wind_speed" => {5.0, @capture_ms},
      "true_wind_angle" => {45.0, @capture_ms},
      "heading" => {90.0, @capture_ms}
    }

    {:ok, observer} =
      PolarObserver.start_link(
        name: nil,
        sample_ms: 0,
        dir: nil,
        boat_identifier: "boat-runtime",
        signals_fn: fn -> signals end,
        sender: fn _channel, _update -> :ok end,
        now_fn: fn -> @capture_ms end,
        utc_now_fn: fn -> @capture_utc end,
        persist_ms: 60_000,
        sync_ms: 60_000,
        window_size: 1,
        gate: [min_dwell: 1]
      )

    try do
      :ok = PolarObserver.tick(observer)
      assert {:ok, snapshot} = PolarObserver.runtime_snapshot(observer)
      assert {:ok, wire} = PolarRuntime.project(snapshot)
      wire
    after
      GenServer.stop(observer)
    end
  end

  defp wind_shift_snapshot! do
    {:ok, observer} =
      WindShiftObserver.start_link(
        name: nil,
        sample_ms: 0,
        dir: nil,
        config: nil,
        commands: nil,
        boat_identifier: "boat-runtime",
        broadcast_enabled: false,
        authority_fn: fn -> {:ok, @authority} end,
        signals_fn: fn -> %{"true_wind_direction" => {200.0, @capture_ms}} end,
        now_fn: fn -> @capture_ms end,
        utc_now_fn: fn -> @capture_utc end,
        put_signals_fn: fn _updates, _monotonic_ms -> :ok end,
        sender: fn _channel, _update -> :ok end,
        transmit_fn: fn _priority, _pgn, _payload -> :ok end
      )

    try do
      :ok = WindShiftObserver.tick(observer)
      assert {:ok, snapshot} = WindShiftObserver.snapshot(observer)
      snapshot
    after
      GenServer.stop(observer)
    end
  end

  defp enlarge_wind_shift(snapshot) do
    minq =
      Enum.map(0..2_999, fn index ->
        %{age_ms: 2_999 - index, value: index * 1.0}
      end)

    maxq =
      Enum.map(0..2_999, fn index ->
        %{age_ms: 2_999 - index, value: (3_000 - index) * 1.0}
      end)

    snapshot
    |> put_in([:runtime, :envelope, :first_age_ms], 2_999)
    |> put_in([:runtime, :envelope, :minq], minq)
    |> put_in([:runtime, :envelope, :maxq], maxq)
  end

  defp portable(%Canonical.Bytes{data: data}), do: {:canonical_bytes, data}

  defp portable(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {portable(key), portable(nested)} end)
  end

  defp portable(value) when is_list(value), do: Enum.map(value, &portable/1)

  defp portable(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&portable/1)
    |> List.to_tuple()
  end

  defp portable(value), do: value

  defp parity_failure(fixture, field, tracker, backend) do
    tracker_value = Map.fetch!(tracker, field)
    backend_value = Map.fetch!(backend, field)

    """
    #{fixture.id} #{field} mismatch
    tracker: #{inspect(tracker_value, limit: :infinity, printable_limit: :infinity)}
    backend: #{inspect(backend_value, limit: :infinity, printable_limit: :infinity)}
    """
  end
end
