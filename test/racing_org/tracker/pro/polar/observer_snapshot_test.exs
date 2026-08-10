defmodule RacingOrg.Tracker.Pro.Polar.ObserverSnapshotTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Polar.Checkpoint, as: PolarCheckpoint
  alias RacingOrg.Tracker.Pro.Polar.Observer
  alias RacingOrg.Tracker.Pro.Polar.Observer.Bins
  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare
  alias RacingOrg.Tracker.Pro.Polar.Observer.Store
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint, as: ContractCheckpoint

  @p 0.9
  @reconciliation_ceiling 1_048_576
  @database_int_max 9_223_372_036_854_775_807

  defp start_observer(opts \\ []) do
    defaults = [
      name: nil,
      sample_ms: 0,
      dir: nil,
      boat_identifier: "boat-test",
      signals_fn: fn -> %{} end,
      sender: fn _channel, _update -> :ok end,
      now_fn: fn -> 100_000 end,
      persist_ms: 60_000,
      sync_ms: 60_000
    ]

    {:ok, observer} = Observer.start_link(Keyword.merge(defaults, opts))
    observer
  end

  defp cells(p \\ @p, offset \\ 0.0) do
    marker = feed(p, Enum.map([4.0, 4.2, 4.4, 4.6, 4.8, 5.0], &(&1 + offset)))
    warmup = feed(p, Enum.map([1.0, 2.0, 3.0, 4.0], &(&1 + offset)))

    %{
      {5, 9} => {marker.count, marker},
      {6, 18} => {warmup.count, warmup}
    }
  end

  defp put_cells(observer, cells, source_generation \\ nil) do
    source_generation =
      source_generation ||
        Enum.reduce(cells, 0, fn {_key, {count, _quantile}}, total -> total + count end)

    :sys.replace_state(observer, fn state ->
      state
      |> Map.put(:cells, cells)
      |> Map.put(:source_generation, source_generation)
    end)

    :ok
  end

  defp snapshot_with_content(snapshot, content) do
    {:ok, bytes} = Canonical.encode(content)
    %{snapshot | content: bytes, content_hash: content_hash(bytes)}
  end

  defp snapshot_with_nonfinite_p(snapshot) do
    finite_p = <<0x05, @p::float-big-size(64)>>
    nonfinite_p = <<0x05, 0x7FF0_0000_0000_0000::unsigned-big-size(64)>>
    assert [_one_match] = :binary.matches(snapshot.content, finite_p)
    bytes = :binary.replace(snapshot.content, finite_p, nonfinite_p)
    %{snapshot | content: bytes, content_hash: content_hash(bytes)}
  end

  defp content_hash(bytes) do
    {:ok, kind_code, schema_version} = Contract.checkpoint_kind(:polar)

    :crypto.hash(
      :sha256,
      Contract.checkpoint_content_hash_domain() <>
        <<Contract.version(), kind_code, schema_version::16, byte_size(bytes)::64, bytes::binary>>
    )
  end

  describe "snapshot/1" do
    test "captures canonical polar-v2 content and hash at GenServer call time" do
      bins = Bins.new(twa_width_deg: 2.5, tws_width_mps: 1.0, max_tws_mps: 30.0)
      observer = start_observer(p: @p, bins: bins)
      source_cells = cells()
      :ok = put_cells(observer, source_cells)

      :sys.replace_state(observer, fn state ->
        %{
          state
          | seq: 17,
            dirty_persist: MapSet.new(Map.keys(source_cells)),
            dirty_sync: MapSet.new(Map.keys(source_cells)),
            last_persist_ms: 12_345,
            last_sync_ms: 23_456
        }
      end)

      assert {:ok, snapshot} = Observer.snapshot(observer)

      assert Map.keys(snapshot) |> Enum.sort() ==
               [
                 :authority,
                 :content,
                 :content_hash,
                 :kind,
                 :policy_hash,
                 :schema_version,
                 :source_generation
               ]

      assert snapshot.authority == "boat-test"
      assert byte_size(snapshot.policy_hash) == 32
      assert snapshot.kind == :polar
      assert snapshot.schema_version == 2
      assert snapshot.source_generation == 10
      assert byte_size(snapshot.content) <= @reconciliation_ceiling
      assert snapshot.content_hash == content_hash(snapshot.content)
      expected_content_hash = snapshot.content_hash
      assert {:ok, ^expected_content_hash} = ContractCheckpoint.content_hash(:polar, 2, snapshot.content)

      assert {:ok, content} = ContractCheckpoint.decode_content(:polar, 2, snapshot.content)
      assert content["p"] === @p
      assert content["twa_width_deg"] === bins.twa_width_deg
      assert content["tws_width_mps"] === bins.tws_width_mps
      assert content["max_tws_mps"] === bins.max_tws_mps

      assert {:ok, hydrated} = PolarCheckpoint.hydrate(content)
      assert hydrated.cells == source_cells

      {_count, marker} = source_cells[{5, 9}]
      {_count, restored_marker} = hydrated.cells[{5, 9}]
      assert restored_marker == marker
      assert restored_marker.np === marker.np

      refute Map.has_key?(snapshot, :seq)
      refute Map.has_key?(snapshot, :persistence)
      refute Map.has_key?(snapshot, :dirty_persist)
      refute Map.has_key?(snapshot, :last_persist_ms)
      refute Map.has_key?(snapshot, :dirty_sync)
      refute Map.has_key?(snapshot, :sender)
      refute Map.has_key?(snapshot, :pid)
      refute Map.has_key?(snapshot, :metadata)
      refute Map.has_key?(snapshot, :raw_nmea)
    end

    test "preserves the exact u32 maximum-index boundary" do
      exact_twa = 180.0 / (0xFFFF_FFFF + 1)
      exact_tws = 51.4444 / (0xFFFF_FFFF + 1)
      bins = Bins.new(twa_width_deg: exact_twa, tws_width_mps: exact_tws, max_tws_mps: 51.4444)
      boundary_cells = %{{0xFFFF_FFFF, 0xFFFF_FFFF} => {1, feed(@p, [4.0])}}
      source = start_observer(bins: bins)
      :ok = put_cells(source, boundary_cells)

      assert {:ok, snapshot} = Observer.snapshot(source)
      target = start_observer(bins: bins)
      assert :ok = Observer.restore(target, snapshot)
      assert :sys.get_state(target).cells == boundary_cells
    end

    test "rejects malformed source state and a revision outside durable database range" do
      observer = start_observer()
      malformed = %{{100, 0} => {1, feed(@p, [4.0])}}
      :ok = put_cells(observer, malformed)
      assert {:error, :invalid_checkpoint} = Observer.snapshot(observer)

      :ok = put_cells(observer, cells(), @database_int_max + 1)
      assert {:error, :invalid_checkpoint} = Observer.snapshot(observer)
    end

    test "rejects nonfinite or unrepresentable boat speed without corrupting cell counts" do
      huge = 10 ** 400

      observer =
        start_observer(
          window_size: 1,
          gate: [min_dwell: 1],
          signals_fn: fn ->
            %{
              "boat_speed" => {huge, 101_000},
              "true_wind_speed" => {3.0, 101_000},
              "true_wind_angle" => {45.0, 101_000},
              "heading" => {0.0, 101_000}
            }
          end
        )

      assert :ok = Observer.tick(observer)
      assert :sys.get_state(observer).cells == %{}
      assert {:ok, snapshot} = Observer.snapshot(observer)
      assert snapshot.source_generation == 0
    end

    test "rejects otherwise valid call-time state above the one MiB reconciliation ceiling" do
      bins =
        Bins.new(
          twa_width_deg: 5.0,
          tws_width_mps: 51.4444 / (0xFFFF_FFFF + 1),
          max_tws_mps: 51.4444
        )

      marker = feed(@p, [4.0, 4.2, 4.4, 4.6, 4.8, 5.0])

      oversized =
        for tws_bin <- 0..5_999, into: %{} do
          {{tws_bin, 0}, {marker.count, marker}}
        end

      source = start_observer(bins: bins)
      :ok = put_cells(source, oversized)
      assert {:error, :checkpoint_too_large} = Observer.snapshot(source)
    end

    test "keeps the saturated default grid below the one MiB reconciliation ceiling" do
      bins = Bins.new()
      {max_tws_bin, max_twa_bin} = Bins.max_key(bins)
      marker = feed(@p, [4.0, 4.2, 4.4, 4.6, 4.8, 5.0])

      saturated =
        for tws_bin <- 0..max_tws_bin, twa_bin <- 0..max_twa_bin, into: %{} do
          {{tws_bin, twa_bin}, {marker.count, marker}}
        end

      source = start_observer(bins: bins)
      :ok = put_cells(source, saturated)

      assert {:ok, snapshot} = Observer.snapshot(source)
      assert map_size(saturated) == 3_600
      assert byte_size(snapshot.content) < @reconciliation_ceiling
      assert {:error, :checkpoint_too_large} = ContractCheckpoint.decode_content(:polar, 2, snapshot.content)

      target = start_observer(bins: bins)
      assert :ok = Observer.restore(target, snapshot)
      assert :sys.get_state(target).cells == saturated
    end
  end

  describe "restore/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "polar_runtime_restore_#{System.unique_integer([:positive])}")
      File.rm_rf(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "durably restores cells before reply while preserving target-local collaborators", %{
      dir: dir
    } do
      source = start_observer()
      source_cells = cells()
      :ok = put_cells(source, source_cells)
      assert {:ok, snapshot} = Observer.snapshot(source)

      target_sender = fn _channel, _update -> :ok end
      target = start_observer(dir: dir, sender: target_sender)

      :sys.replace_state(target, fn state ->
        %{
          state
          | seq: 43,
            dirty_persist: MapSet.new(),
            dirty_sync: MapSet.new([{0, 0}]),
            last_persist_ms: 99_999,
            last_sync_ms: 88_888
        }
      end)

      assert :ok = Observer.restore(target, snapshot)
      state = :sys.get_state(target)

      assert state.cells == source_cells
      assert state.dir == dir
      assert state.sender === target_sender
      assert state.seq == 43
      assert state.last_sync_ms == 88_888
      assert state.dirty_sync == MapSet.new()
      assert state.source_generation == snapshot.source_generation
      assert is_binary(state.last_restore_fingerprint)
      refute state.force_persist
      assert state.dirty_persist == MapSet.new()
      assert state.last_persist_ms == 100_000
      assert {:ok, ^source_cells} = Store.load(dir)
    end

    test "forces an accepted empty polar to clear stale target-local persistence", %{dir: dir} do
      source = start_observer()
      assert {:ok, empty_snapshot} = Observer.snapshot(source)

      target = start_observer(dir: dir)
      stale_cells = cells()
      assert :ok = Store.save(dir, stale_cells)
      assert {:ok, ^stale_cells} = Store.load(dir)

      assert :ok = Observer.restore(target, empty_snapshot)
      state = :sys.get_state(target)
      assert state.cells == %{}
      assert state.dirty_persist == MapSet.new()
      refute state.force_persist
      assert state.last_persist_ms == 100_000
      assert {:ok, persisted} = Store.load(dir)
      assert persisted == %{}
    end

    test "does not expose a restore that target-local persistence cannot commit", %{dir: dir} do
      File.mkdir_p!(dir)
      blocker = Path.join(dir, "not-a-directory")
      File.write!(blocker, "blocked")
      bad_dir = Path.join(blocker, "child")

      source = start_observer()
      :ok = put_cells(source, cells(), 10)
      assert {:ok, snapshot} = Observer.snapshot(source)

      target = start_observer(dir: bad_dir)
      assert {:ok, before_restore} = Observer.snapshot(target)

      assert {:error, {:persistence_failed, _reason}} = Observer.restore(target, snapshot)
      assert {:ok, ^before_restore} = Observer.snapshot(target)
      refute :sys.get_state(target).force_persist
    end

    test "a failed ordinary persist remains dirty and immediately retryable", %{dir: dir} do
      File.mkdir_p!(dir)
      blocker = Path.join(dir, "not-a-directory")
      File.write!(blocker, "blocked")
      bad_dir = Path.join(blocker, "child")

      target =
        start_observer(
          dir: bad_dir,
          window_size: 1,
          gate: [min_dwell: 1],
          signals_fn: fn ->
            %{
              "boat_speed" => {4.0, 101_000},
              "true_wind_speed" => {3.0, 101_000},
              "true_wind_angle" => {45.0, 101_000},
              "heading" => {0.0, 101_000}
            }
          end
        )

      assert :ok = Observer.tick(target)
      dirty = :sys.get_state(target)
      refute Enum.empty?(dirty.dirty_persist)
      assert dirty.last_persist_ms == 100_000

      assert {:error, _reason} = Observer.persist_now(target)
      failed = :sys.get_state(target)
      assert failed.dirty_persist == dirty.dirty_persist
      assert failed.last_persist_ms == 100_000
    end

    test "startup rejects locally persisted authority, policy, probability, or geometry drift and scrubs it", %{
      dir: dir
    } do
      mismatches = [
        [boat_identifier: "other-boat"],
        [p: 0.8],
        [gate: [min_dwell: 5]],
        [bins: [twa_width_deg: 2.5]]
      ]

      for {target_opts, index} <- Enum.with_index(mismatches) do
        case_dir = Path.join(dir, Integer.to_string(index))
        writer = start_observer(dir: case_dir)
        :ok = put_cells(writer, cells(), 10)
        assert :ok = Observer.persist_now(writer)
        GenServer.stop(writer)

        target = start_observer(Keyword.merge([dir: case_dir], target_opts))
        state = :sys.get_state(target)
        assert state.cells == %{}
        assert state.force_persist
        assert :ok = Observer.persist_now(target)
        assert {:ok, persisted} = Store.load(case_dir)
        assert persisted == %{}
      end
    end

    test "startup semantically validates legacy cells and durably scrubs rejected state", %{dir: dir} do
      malformed_dir = Path.join(dir, "malformed")
      malformed = %{{0, 0} => {1, PSquare.new(@p)}}
      assert :ok = Store.save(malformed_dir, malformed)

      malformed_target = start_observer(dir: malformed_dir)
      malformed_state = :sys.get_state(malformed_target)
      assert malformed_state.cells == %{}
      assert malformed_state.force_persist
      assert {:ok, snapshot} = Observer.snapshot(malformed_target)
      assert snapshot.source_generation == 0
      assert :ok = Observer.persist_now(malformed_target)
      assert {:ok, persisted} = Store.load(malformed_dir)
      assert persisted == %{}

      bounded_dir = Path.join(dir, "bounded")
      valid_cell = {{0, 0}, {1, feed(@p, [4.0])}}
      out_of_domain_cell = {{100, 0}, {1, feed(@p, [5.0])}}
      assert :ok = Store.save(bounded_dir, Map.new([valid_cell, out_of_domain_cell]))

      bounded_target = start_observer(dir: bounded_dir)
      bounded_state = :sys.get_state(bounded_target)
      assert bounded_state.cells == Map.new([valid_cell])
      assert bounded_state.force_persist
      assert :ok = Observer.persist_now(bounded_target)
      assert {:ok, persisted} = Store.load(bounded_dir)
      assert persisted == Map.new([valid_cell])
    end

    test "rejects authority, admission policy, and grid geometry mismatch without mutation" do
      source = start_observer()
      :ok = put_cells(source, cells())
      assert {:ok, snapshot} = Observer.snapshot(source)

      for {target, reason} <- [
            {start_observer(boat_identifier: "other-boat"), :authority_mismatch},
            {start_observer(p: 0.8), :policy_mismatch},
            {start_observer(min_stw_mps: 0.8), :policy_mismatch},
            {start_observer(window_size: 20), :policy_mismatch},
            {start_observer(gate: [min_dwell: 5]), :policy_mismatch},
            {start_observer(bins: [twa_width_deg: 2.5]), :geometry_mismatch}
          ] do
        assert {:ok, before_restore} = Observer.snapshot(target)
        assert {:error, ^reason} = Observer.restore(target, snapshot)
        assert {:ok, ^before_restore} = Observer.snapshot(target)
      end
    end

    test "rejects malformed, nonfinite, out-of-domain, oversized, and source-local state without mutation" do
      source = start_observer()
      :ok = put_cells(source, cells())
      assert {:ok, snapshot} = Observer.snapshot(source)

      target = start_observer()
      assert {:ok, before_restore} = Observer.snapshot(target)
      assert {:ok, content} = Canonical.decode(snapshot.content)
      [first | rest] = content["cells"]

      invalid = [
        Map.put(snapshot, :metadata, %{}),
        Map.put(snapshot, :dir, "/source/device"),
        Map.put(snapshot, :dirty_persist, true),
        Map.put(snapshot, :last_persist_ms, 1),
        Map.put(snapshot, :last_sync_ms, 1),
        Map.put(snapshot, :seq, 99),
        Map.put(snapshot, :sender, fn _, _ -> :ok end),
        Map.put(snapshot, :pid, self()),
        Map.put(snapshot, :raw_nmea, <<0, 1, 2>>),
        %{snapshot | kind: :calibration},
        %{snapshot | schema_version: 1},
        %{snapshot | authority: ""},
        %{snapshot | policy_hash: <<0>>},
        %{snapshot | content_hash: <<0::256>>},
        snapshot_with_nonfinite_p(snapshot),
        snapshot_with_content(snapshot, %{content | "cells" => [%{first | "tws_bin" => 0x1_0000_0000} | rest]}),
        snapshot_with_content(snapshot, %{
          content
          | "cells" => [Map.put(first, "psk", "synthetic-noncredential") | rest]
        }),
        snapshot_with_content(snapshot, Map.put(content, "metadata", %{}))
      ]

      for candidate <- invalid do
        assert {:error, _reason} = Observer.restore(target, candidate)
        assert {:ok, ^before_restore} = Observer.snapshot(target)
      end

      oversized = %{
        snapshot
        | content: :binary.copy(<<0>>, @reconciliation_ceiling + 1),
          content_hash: <<0::256>>
      }

      assert {:error, :checkpoint_too_large} = Observer.restore(target, oversized)
      assert {:ok, ^before_restore} = Observer.snapshot(target)
    end

    test "uses authoritative revision for stale rollback and same-revision conflict fencing" do
      older_source = start_observer()
      older_cells = %{{5, 9} => {6, feed(@p, [4.0, 4.2, 4.4, 4.6, 4.8, 5.0])}}
      :ok = put_cells(older_source, older_cells, 10)
      assert {:ok, older} = Observer.snapshot(older_source)

      conflict_source = start_observer()
      conflicting_cells = %{{5, 9} => {6, feed(@p, [5.0, 5.2, 5.4, 5.6, 5.8, 6.0])}}
      :ok = put_cells(conflict_source, conflicting_cells, 10)
      assert {:ok, conflicting} = Observer.snapshot(conflict_source)
      assert conflicting.source_generation == older.source_generation
      refute conflicting.content_hash == older.content_hash

      newer_source = start_observer()
      newer_cells = %{{5, 9} => {1, feed(@p, [5.2])}}
      :ok = put_cells(newer_source, newer_cells, 11)
      assert {:ok, newer} = Observer.snapshot(newer_source)

      high_total_stale_source = start_observer()
      high_total_stale_cells = %{{5, 9} => {100, feed(@p, Enum.map(1..100, &(&1 / 10)))}}
      :ok = put_cells(high_total_stale_source, high_total_stale_cells, 9)
      assert {:ok, high_total_stale} = Observer.snapshot(high_total_stale_source)

      conflict_target = start_observer()
      assert :ok = Observer.restore(conflict_target, older)
      assert {:error, :checkpoint_conflict} = Observer.restore(conflict_target, conflicting)
      assert {:ok, ^older} = Observer.snapshot(conflict_target)

      stale_target = start_observer()
      assert :ok = Observer.restore(stale_target, newer)
      assert {:error, :stale_checkpoint} = Observer.restore(stale_target, older)
      assert {:error, :stale_checkpoint} = Observer.restore(stale_target, high_total_stale)
      assert {:ok, ^newer} = Observer.snapshot(stale_target)
    end

    test "a newer authoritative revision can intentionally reset a nonempty polar" do
      populated_source = start_observer()
      :ok = put_cells(populated_source, cells(), 50)
      assert {:ok, populated} = Observer.snapshot(populated_source)

      reset_source = start_observer()
      :ok = put_cells(reset_source, %{}, 51)
      assert {:ok, reset} = Observer.snapshot(reset_source)

      target = start_observer()
      assert :ok = Observer.restore(target, populated)
      assert :ok = Observer.restore(target, reset)
      assert {:ok, ^reset} = Observer.snapshot(target)
      assert :sys.get_state(target).cells == %{}
    end

    test "an accepted canonical identity is an idempotent no-op after live progress" do
      source = start_observer(window_size: 1, gate: [min_dwell: 1])
      source_cells = %{{5, 9} => {6, feed(@p, [4.0, 4.2, 4.4, 4.6, 4.8, 5.0])}}
      :ok = put_cells(source, source_cells)
      assert {:ok, snapshot} = Observer.snapshot(source)

      target =
        start_observer(
          window_size: 1,
          gate: [min_dwell: 1],
          signals_fn: fn ->
            %{
              "boat_speed" => {4.0, 101_000},
              "true_wind_speed" => {3.0, 101_000},
              "true_wind_angle" => {45.0, 101_000},
              "heading" => {0.0, 101_000}
            }
          end
        )

      assert :ok = Observer.restore(target, snapshot)
      assert :ok = Observer.tick(target)
      assert {:ok, progressed} = Observer.snapshot(target)
      assert progressed.source_generation == snapshot.source_generation + 1

      assert :ok = Observer.restore(target, snapshot)
      assert {:ok, ^progressed} = Observer.snapshot(target)
    end

    test "persists accepted identity so its retry remains idempotent after reboot and live progress", %{dir: dir} do
      policy = [window_size: 1, gate: [min_dwell: 1]]
      source = start_observer(policy)
      source_cells = %{{5, 9} => {6, feed(@p, [4.0, 4.2, 4.4, 4.6, 4.8, 5.0])}}
      :ok = put_cells(source, source_cells, 10)
      assert {:ok, snapshot} = Observer.snapshot(source)

      target = start_observer(Keyword.merge(policy, dir: dir))
      assert :ok = Observer.restore(target, snapshot)
      GenServer.stop(target)

      rebooted =
        start_observer(
          Keyword.merge(policy,
            dir: dir,
            signals_fn: fn ->
              %{
                "boat_speed" => {4.0, 101_000},
                "true_wind_speed" => {3.0, 101_000},
                "true_wind_angle" => {45.0, 101_000},
                "heading" => {0.0, 101_000}
              }
            end
          )
        )

      assert :ok = Observer.tick(rebooted)
      assert {:ok, progressed} = Observer.snapshot(rebooted)
      assert progressed.source_generation == 11

      assert :ok = Observer.restore(rebooted, snapshot)
      assert {:ok, ^progressed} = Observer.snapshot(rebooted)
    end
  end

  defp feed(p, values), do: Enum.reduce(values, PSquare.new(p), &PSquare.add(&2, &1))
end
