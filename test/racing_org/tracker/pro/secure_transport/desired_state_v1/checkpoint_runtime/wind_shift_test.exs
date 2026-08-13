defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.WindShiftTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.WindShift,
    as: RuntimeAdapter

  alias RacingOrg.Tracker.Pro.WindShift.Observer
  alias RacingOrg.Tracker.Pro.WindShift.Observer.Snapshot

  @capture_utc ~U[2026-08-12 12:00:00Z]
  @capture_ms 10_000
  @device_id <<1::128>>
  @storage_epoch <<2::128>>
  @content_hash_sha256 "0a261d462e686696cfe6bb1bf2f7e49173fa242c68f7b9151dac4d7e96aa0123"
  @invalid {:error, :invalid_checkpoint_content}

  test "projects, validates, and hydrates the complete exact Observer snapshot" do
    snapshot = snapshot_fixture()

    assert {:ok, wire} = RuntimeAdapter.project(snapshot)
    assert {:ok, canonical} = Checkpoint.canonical_content(:wind_shift, 2, wire)
    assert {:ok, ^wire} = Checkpoint.decode_canonical_content(:wind_shift, 2, canonical)
    assert byte_size(canonical) == 3_204

    assert Base.encode16(:crypto.hash(:sha256, canonical), case: :lower) ==
             "cd2d2e44114ed300fe2af872069be5b6c227ebd0530a6288661ecb8a71973658"

    assert {:ok, content_hash} = Checkpoint.content_hash(:wind_shift, 2, canonical)
    assert Base.encode16(content_hash, case: :lower) == @content_hash_sha256

    assert :ok = RuntimeAdapter.validate(wire)
    assert {:ok, ^snapshot} = RuntimeAdapter.hydrate(wire)

    assert wire["authority"]["device_id"] == Canonical.bytes(@device_id)
    assert wire["authority"]["storage_epoch"] == Canonical.bytes(@storage_epoch)
    assert Map.keys(wire["runtime"]) |> Enum.sort() == runtime_wire_keys()
  end

  test "rebinds only in-memory authority while canonical bytes remain origin-bound" do
    wire = wire_fixture()
    assert {:ok, canonical_before} = Checkpoint.canonical_content(:wind_shift, 2, wire)
    assert {:ok, snapshot} = RuntimeAdapter.hydrate(wire)

    target = %{
      device_id: @device_id,
      credential_epoch: 9,
      storage_epoch: <<3::128>>
    }

    assert {:ok, rebound} = RuntimeAdapter.rebind_authority(snapshot, target)
    assert rebound == %{snapshot | authority: target}
    assert snapshot.authority != target

    assert {:ok, canonical_after} = Checkpoint.canonical_content(:wind_shift, 2, wire)
    assert canonical_after == canonical_before

    assert {:ok, content_hash} = Checkpoint.content_hash(:wind_shift, 2, canonical_after)
    assert Base.encode16(content_hash, case: :lower) == @content_hash_sha256
  end

  test "refuses target rebinding across device identity" do
    assert {:ok, snapshot} = wire_fixture() |> RuntimeAdapter.hydrate()

    target = %{
      device_id: <<9::128>>,
      credential_epoch: 9,
      storage_epoch: <<3::128>>
    }

    assert {:error, :checkpoint_authority_rebind_mismatch} =
             RuntimeAdapter.rebind_authority(snapshot, target)
  end

  test "rejects malformed target authority and non-exact hydrated snapshots" do
    assert {:ok, snapshot} = wire_fixture() |> RuntimeAdapter.hydrate()

    for invalid_target <- [
          Map.put(snapshot.authority, :storage_epoch, <<0::128>>),
          Map.put(snapshot.authority, :device_id, <<1::120>>),
          Map.put(snapshot.authority, :credential_epoch, -1),
          Map.put(snapshot.authority, :credential_epoch, 0x1_0000_0000),
          Map.put(snapshot.authority, :unknown, true),
          Map.delete(snapshot.authority, :storage_epoch)
        ] do
      assert @invalid = RuntimeAdapter.rebind_authority(snapshot, invalid_target)
    end

    assert @invalid = RuntimeAdapter.rebind_authority(Map.delete(snapshot, :tick), snapshot.authority)
  end

  test "rejects crossing hysteresis that the live observer cannot restore" do
    snapshot =
      snapshot_fixture()
      |> put_in([:policy, :xing_hysteresis_deg], 3.0)
      |> put_in([:runtime, :xing, :side], nil)
      |> put_in([:runtime, :xing, :extreme, :phase_deg], 2.5)

    wire =
      wire_fixture()
      |> put_in(["policy", "xing_hysteresis_deg"], 3.0)
      |> put_in(["runtime", "xing", "side"], nil)
      |> put_in(["runtime", "xing", "extreme", "phase_deg"], 2.5)

    assert @invalid = RuntimeAdapter.validate(wire)
    assert @invalid = RuntimeAdapter.project(snapshot)
    assert @invalid = RuntimeAdapter.hydrate(wire)
  end

  test "rejects unknown fields recursively" do
    wire = wire_fixture()

    invalid_values = [
      put_in(wire, ["policy", "windows", "unknown"], true),
      put_in(wire, ["runtime", "means", "fast", "unknown"], true),
      put_in(
        wire,
        ["runtime", "envelope", "minq", "chunks", Access.at(0), Access.at(0)],
        [0, 200.0, "unknown"]
      )
    ]

    for invalid <- invalid_values do
      assert @invalid = RuntimeAdapter.validate(invalid)
      assert @invalid = RuntimeAdapter.hydrate(invalid)
    end
  end

  test "rejects unknown and non-NFC closed enums without creating atoms" do
    unknown = "wind_shift_task_80_unknown_step_status"
    non_nfc = "nóne"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    for value <- [unknown, non_nfc] do
      invalid = put_in(wire_fixture(), ["runtime", "step", "status"], value)
      assert @invalid = RuntimeAdapter.validate(invalid)
      assert @invalid = RuntimeAdapter.hydrate(invalid)
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "rejects malformed or open canonical byte wrappers" do
    invalid_wrappers = [
      %Canonical.Bytes{data: :not_binary},
      Map.put(Canonical.bytes(@device_id), :unknown, true)
    ]

    for wrapper <- invalid_wrappers do
      invalid = put_in(wire_fixture(), ["authority", "device_id"], wrapper)
      assert @invalid = RuntimeAdapter.validate(invalid)
      assert @invalid = RuntimeAdapter.hydrate(invalid)
    end
  end

  test "rejects every nonnegative integer above the canonical u64 ceiling" do
    wire = wire_fixture()
    u64_max = 0xFFFF_FFFF_FFFF_FFFF
    mutations = replace_each_nonnegative_integer(wire, u64_max + 1)
    assert mutations != []

    for invalid <- mutations do
      assert @invalid = RuntimeAdapter.validate(invalid)
      assert @invalid = RuntimeAdapter.hydrate(invalid)
    end
  end

  test "rejects negative-zero floats recursively so canonical decode and hydrate stay exact" do
    wire = wire_fixture()

    for invalid <- [
          put_in(wire, ["runtime", "last_lift"], -0.0),
          put_in(wire, ["runtime", "residuals", "values", Access.at(0)], -0.0)
        ] do
      assert @invalid = RuntimeAdapter.validate(invalid)
      assert @invalid = RuntimeAdapter.hydrate(invalid)
    end
  end

  test "validates exact chunk keys, declared counts, chunk bounds, and total bounds" do
    wire = wire_fixture()
    queue = get_in(wire, ["runtime", "envelope", "minq"])
    row = queue["chunks"] |> hd() |> hd()

    unknown_field =
      put_in(
        wire,
        ["runtime", "envelope", "minq"],
        Map.put(queue, "unknown", true)
      )

    count_mismatch = put_in(wire, ["runtime", "envelope", "minq", "count"], 2)

    oversized_chunk =
      wire
      |> put_in(["runtime", "envelope", "minq", "count"], 65_536)
      |> put_in(
        ["runtime", "envelope", "minq", "chunks"],
        [List.duplicate(row, 65_536)]
      )

    too_many_rows =
      wire
      |> put_in(["runtime", "envelope", "minq", "count"], 100_000)
      |> put_in(
        ["runtime", "envelope", "minq", "chunks"],
        [List.duplicate(row, 50_000), List.duplicate(row, 50_001)]
      )

    empty_chunk =
      wire
      |> put_in(["runtime", "envelope", "minq", "count"], 0)
      |> put_in(["runtime", "envelope", "minq", "chunks"], [[]])

    positive_count_without_chunks =
      wire
      |> put_in(["runtime", "envelope", "minq", "count"], 1)
      |> put_in(["runtime", "envelope", "minq", "chunks"], [])

    short_nonfinal_chunk =
      wire
      |> put_in(["runtime", "envelope", "minq", "count"], 2)
      |> put_in(["runtime", "envelope", "minq", "chunks"], [[[1, 199.0]], [[0, 200.0]]])

    improper_chunk =
      wire
      |> put_in(["runtime", "envelope", "minq", "chunks"], [[row | :improper]])

    for invalid <- [
          unknown_field,
          count_mismatch,
          oversized_chunk,
          too_many_rows,
          empty_chunk,
          positive_count_without_chunks,
          short_nonfinal_chunk,
          improper_chunk
        ] do
      assert @invalid = RuntimeAdapter.validate(invalid)
      assert @invalid = RuntimeAdapter.hydrate(invalid)
    end
  end

  test "validates queue order across canonical chunk boundaries and hydrates the exact original order" do
    minq =
      Enum.map(0..65_535, fn index ->
        [65_535 - index, index * 1.0]
      end)

    maxq =
      Enum.map(0..65_535, fn index ->
        [65_535 - index, (65_536 - index) * 1.0]
      end)

    wire =
      wire_fixture()
      |> put_in(["runtime", "envelope", "first_age_ms"], 65_535)
      |> put_in(["runtime", "envelope", "minq"], chunked_queue(minq, 65_535))
      |> put_in(["runtime", "envelope", "maxq"], chunked_queue(maxq, 65_535))

    assert :ok = RuntimeAdapter.validate(wire)
    assert {:ok, hydrated} = RuntimeAdapter.hydrate(wire)
    assert hydrated.runtime.envelope.minq == atomize_queue(minq)
    assert hydrated.runtime.envelope.maxq == atomize_queue(maxq)

    cross_chunk_violation =
      put_in(
        wire,
        ["runtime", "envelope", "minq", "chunks", Access.at(1), Access.at(0), Access.at(1)],
        197.5
      )

    assert @invalid = RuntimeAdapter.validate(cross_chunk_violation)
    assert @invalid = RuntimeAdapter.hydrate(cross_chunk_violation)
  end

  test "uses projected canonical capacity for combined legal runtime collections" do
    minq =
      Enum.map(0..99_999, fn index ->
        %{age_ms: 99_999 - index, value: index * 1.0}
      end)

    maxq =
      Enum.map(0..99_999, fn index ->
        %{age_ms: 99_999 - index, value: (100_000 - index) * 1.0}
      end)

    snapshot =
      snapshot_fixture()
      |> put_in([:runtime, :envelope, :first_age_ms], 99_999)
      |> put_in([:runtime, :envelope, :minq], minq)
      |> put_in([:runtime, :envelope, :maxq], maxq)

    event = %{
      t_ms: snapshot.captured_at_utc_ms,
      kind: "new_high",
      twd_deg: 200.0,
      magnitude_deg: 1.0,
      detail: %{min_deg: 199.0, max_deg: 201.0}
    }

    events =
      Enum.map(0..14_999, fn index ->
        %{event | detail: %{min_deg: 199.0 - index / 100_000.0, max_deg: 201.0}}
      end)

    snapshot = put_in(snapshot, [:runtime, :pending_events], events)

    assert byte_size(:erlang.term_to_binary(snapshot, [:deterministic])) > 8_388_608
    assert :ok = Snapshot.preflight(snapshot)
    assert {:ok, wire} = RuntimeAdapter.project(snapshot)

    for queue <- ["minq", "maxq"] do
      assert get_in(wire, ["runtime", "envelope", queue, "count"]) == 100_000

      assert wire
             |> get_in(["runtime", "envelope", queue, "chunks"])
             |> Enum.map(&length/1) == [65_535, 34_465]
    end

    assert {:ok, canonical} = Checkpoint.canonical_content(:wind_shift, 2, wire)
    assert byte_size(canonical) <= 8_388_608
    assert {:ok, hydrated} = RuntimeAdapter.hydrate(wire)
    assert hydrated.runtime.envelope.minq == minq
    assert hydrated.runtime.envelope.maxq == maxq
  end

  test "rejects an internal snapshot that fails Observer snapshot preflight" do
    invalid = put_in(snapshot_fixture(), [:runtime, :pending_timeline], :not_a_list)
    assert @invalid = RuntimeAdapter.project(invalid)
  end

  defp wire_fixture do
    assert {:ok, wire} = snapshot_fixture() |> RuntimeAdapter.project()
    wire
  end

  defp chunked_queue(rows, chunk_size) do
    %{"count" => length(rows), "chunks" => Enum.chunk_every(rows, chunk_size)}
  end

  defp atomize_queue(rows) do
    Enum.map(rows, fn [age_ms, value] -> %{age_ms: age_ms, value: value} end)
  end

  defp snapshot_fixture do
    {:ok, clock} = Agent.start_link(fn -> %{monotonic_ms: @capture_ms, utc: @capture_utc} end)

    {:ok, observer} =
      Observer.start_link(
        name: nil,
        sample_ms: 0,
        dir: nil,
        config: nil,
        commands: nil,
        boat_identifier: "boat-test",
        broadcast_enabled: false,
        authority_fn: fn ->
          {:ok, %{device_id: @device_id, credential_epoch: 7, storage_epoch: @storage_epoch}}
        end,
        signals_fn: fn -> %{"true_wind_direction" => {200.0, @capture_ms}} end,
        now_fn: fn -> Agent.get(clock, & &1.monotonic_ms) end,
        utc_now_fn: fn -> Agent.get(clock, & &1.utc) end,
        put_signals_fn: fn _updates, _monotonic_ms -> :ok end,
        sender: fn _channel, _update -> :ok end,
        transmit_fn: fn _priority, _pgn, _payload -> :ok end
      )

    :ok = Observer.tick(observer)
    {:ok, snapshot} = Observer.snapshot(observer)
    snapshot
  end

  defp replace_each_nonnegative_integer(value, replacement) do
    value
    |> nonnegative_integer_paths([])
    |> Enum.map(fn path -> put_in(value, path, replacement) end)
  end

  defp nonnegative_integer_paths(value, path) when is_integer(value) and value >= 0,
    do: [Enum.reverse(path)]

  defp nonnegative_integer_paths(value, path) when is_map(value) and not is_struct(value) do
    Enum.flat_map(value, fn {key, nested} -> nonnegative_integer_paths(nested, [key | path]) end)
  end

  defp nonnegative_integer_paths(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {nested, index} ->
      nonnegative_integer_paths(nested, [Access.at(index) | path])
    end)
  end

  defp nonnegative_integer_paths(_value, _path), do: []

  defp runtime_wire_keys do
    ~w(
      absorb_count cycle envelope last_lift last_period_age_ms last_persist_age_ms
      last_summary last_sync_age_ms last_t_age_ms last_tack last_timeline_age_ms
      last_tx_age_ms last_verdict means pending_events pending_timeline period
      prev_regime prev_step_status residuals seq session step t0_age_ms unwrap xing
    )
    |> Enum.sort()
  end
end
