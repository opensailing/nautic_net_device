defmodule RacingOrg.Tracker.Pro.Polar.ObserverRuntimeSnapshotTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.Polar.Observer
  alias RacingOrg.Tracker.Pro.Polar.Observer.Bins
  alias RacingOrg.Tracker.Pro.Polar.Observer.Gate
  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare
  alias RacingOrg.Tracker.Pro.Polar.Observer.RuntimeSnapshot
  alias RacingOrg.Tracker.Pro.Polar.Observer.Snapshot
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint, as: ContractCheckpoint

  @capture_utc ~U[2026-08-12 12:00:00Z]
  @p 0.9

  defp start_clock(now_ms), do: start_agent(now_ms)
  defp now_fn(clock), do: fn -> Agent.get(clock, & &1) end
  defp set_now(clock, now_ms), do: Agent.update(clock, fn _ -> now_ms end)

  defp start_utc_clock(value \\ @capture_utc), do: start_agent(value)
  defp utc_now_fn(clock), do: fn -> Agent.get(clock, & &1) end
  defp set_utc(clock, value), do: Agent.update(clock, fn _ -> value end)

  defp start_signals(initial), do: start_agent(initial)

  defp start_agent(initial) do
    {:ok, agent} = Agent.start(fn -> initial end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
    {:ok, agent}
  end

  defp signals_fn(signals), do: fn -> Agent.get(signals, & &1) end

  defp start_observer(clock, utc_clock, opts) do
    defaults = [
      name: nil,
      sample_ms: 0,
      dir: nil,
      boat_identifier: "boat-runtime",
      signals_fn: fn -> %{} end,
      sender: fn _channel, _update -> :ok end,
      now_fn: now_fn(clock),
      utc_now_fn: utc_now_fn(utc_clock),
      persist_ms: 60_000,
      sync_ms: 60_000
    ]

    {:ok, observer} = Observer.start_link(Keyword.merge(defaults, opts))
    observer
  end

  defp sample(t_ms, overrides \\ %{}) do
    Map.merge(
      %{
        t_ms: t_ms,
        tws_mps: 5.0,
        twa_deg: 45.0,
        stw_mps: 4.0,
        heading_deg: 90.0,
        heel_deg: nil,
        under_power?: nil,
        engine_rpm: nil
      },
      overrides
    )
  end

  defp signals(t_ms, stw) do
    %{
      "boat_speed" => {stw, t_ms},
      "true_wind_speed" => {5.0, t_ms},
      "true_wind_angle" => {45.0, t_ms},
      "heading" => {90.0, t_ms}
    }
  end

  defp feed(values), do: Enum.reduce(values, PSquare.new(@p), &PSquare.add(&2, &1))

  defp seed_runtime(observer) do
    cells = %{
      {5, 9} => {6, feed([3.5, 3.7, 3.9, 4.1, 4.3, 4.5])},
      {6, 18} => {4, feed([2.0, 2.2, 2.4, 2.6])}
    }

    :sys.replace_state(observer, fn state ->
      %{
        state
        | cells: cells,
          source_generation: 10,
          window: [sample(98_000), sample(99_000)],
          dirty_sync: MapSet.new([{5, 9}]),
          dirty_persist: MapSet.new([{6, 18}]),
          force_persist: true,
          last_sync_ms: 55_000,
          last_persist_ms: 70_000,
          seq: 41,
          stats: %{
            admitted: 10,
            rejected: 2,
            samples: 12,
            reject_reasons: %{insufficient_dwell: 1, at_rest: 1}
          }
      }
    end)

    cells
  end

  test "captures one closed versioned full-runtime envelope around canonical polar checkpoint v2" do
    {:ok, clock} = start_clock(100_000)
    {:ok, utc_clock} = start_utc_clock()
    observer = start_observer(clock, utc_clock, window_size: 3, gate: [min_dwell: 3])
    cells = seed_runtime(observer)

    assert {:ok, snapshot} = Observer.runtime_snapshot(observer)

    assert Map.keys(snapshot) |> Enum.sort() ==
             [
               :authority,
               :captured_at_utc_ms,
               :learner,
               :persistence_phase,
               :policy,
               :sync,
               :tick,
               :upstream_seq,
               :version,
               :window
             ]

    assert snapshot.version == 1
    assert snapshot.captured_at_utc_ms == DateTime.to_unix(@capture_utc, :millisecond)
    assert snapshot.authority == %{boat_identifier: "boat-runtime"}
    assert snapshot.learner.source_generation == 10
    assert snapshot.upstream_seq == 41
    assert snapshot.sync == %{dirty_keys: [%{tws_bin: 5, twa_bin: 9}], last_sync_age_ms: 45_000}

    assert snapshot.persistence_phase == %{
             dirty_keys: [%{tws_bin: 6, twa_bin: 18}],
             force: true,
             last_persist_age_ms: 30_000
           }

    assert snapshot.window == [
             Map.put(Map.delete(sample(98_000), :t_ms), :age_ms, 2_000),
             Map.put(Map.delete(sample(99_000), :t_ms), :age_ms, 1_000)
           ]

    assert snapshot.tick == %{remaining_ms: nil}

    assert snapshot.policy == %{
             admission_hash: snapshot.policy.admission_hash,
             bins: %{
               max_tws_mps: 51.4444,
               twa_width_deg: 5.0,
               tws_width_mps: 0.514444
             },
             gate: %{
               angle_band_deg: {25.0, 165.0},
               angle_key: :twa_deg,
               engine_rpm_idle: 50.0,
               heel_band_deg: {-45.0, 45.0},
               max_accel_mps2: 0.05,
               max_turn_rate_dps: 3.0,
               max_tws_sd_mps: 0.2572,
               min_dwell: 3
             },
             min_stw_mps: 0.3,
             p: 0.9,
             persist_ms: 60_000,
             persistence_enabled: false,
             sample_ms: 0,
             sync_ms: 60_000,
             window_size: 3
           }

    assert is_binary(snapshot.policy.admission_hash)
    assert byte_size(snapshot.policy.admission_hash) == 32
    assert snapshot.learner.content.kind == :polar
    assert snapshot.learner.content.schema_version == 2
    assert snapshot.learner.content.source_generation == snapshot.learner.source_generation
    assert {:ok, content} = ContractCheckpoint.decode_content(:polar, 2, snapshot.learner.content.content)
    assert length(content["cells"]) == map_size(cells)

    refute Map.has_key?(snapshot, :metadata)
    refute Map.has_key?(snapshot, :sender)
    refute Map.has_key?(snapshot, :signals_fn)
    refute Map.has_key?(snapshot, :now_fn)
    refute Map.has_key?(snapshot, :utc_now_fn)
    refute Map.has_key?(snapshot, :dir)
    refute Map.has_key?(snapshot, :store_opts)
    refute inspect(snapshot) =~ "token"
    assert :ok = RuntimeSnapshot.preflight(snapshot)
  end

  test "powered-off UTC aging preserves the next Gate admission and P² update exactly" do
    {:ok, source_clock} = start_clock(100_000)
    {:ok, source_utc} = start_utc_clock()
    {:ok, source_signals} = start_signals(signals(100_500, 4.7))

    source =
      start_observer(source_clock, source_utc,
        window_size: 3,
        gate: [min_dwell: 3],
        signals_fn: signals_fn(source_signals)
      )

    :sys.replace_state(source, fn state ->
      %{state | window: [sample(98_000, %{stw_mps: 4.5}), sample(99_000, %{stw_mps: 4.6})]}
    end)

    assert {:ok, snapshot} = Observer.runtime_snapshot(source)

    set_now(source_clock, 100_500)
    set_utc(source_utc, DateTime.add(@capture_utc, 500, :millisecond))

    {:ok, target_clock} = start_clock(50_000)
    {:ok, target_utc} = start_utc_clock(DateTime.add(@capture_utc, 500, :millisecond))
    {:ok, target_signals} = start_signals(signals(50_000, 4.7))

    target =
      start_observer(target_clock, target_utc,
        window_size: 3,
        gate: [min_dwell: 3],
        signals_fn: signals_fn(target_signals)
      )

    assert :ok = Observer.restore_runtime(target, snapshot)
    assert Enum.map(:sys.get_state(target).window, & &1.t_ms) == [47_500, 48_500]

    assert :ok = Observer.tick(source)
    assert :ok = Observer.tick(target)

    source_state = :sys.get_state(source)
    target_state = :sys.get_state(target)
    assert target_state.cells == source_state.cells
    assert target_state.source_generation == source_state.source_generation
    assert target_state.stats == source_state.stats

    assert Enum.map(target_state.window, &Map.delete(&1, :t_ms)) ==
             Enum.map(source_state.window, &Map.delete(&1, :t_ms))
  end

  test "restores exact dirty sets, persistence force/cadence, upstream sequence, and next output" do
    parent = self()
    {:ok, source_clock} = start_clock(100_000)
    {:ok, source_utc} = start_utc_clock()
    source_sender = fn _channel, update -> send(parent, {:source_update, update}) end
    source = start_observer(source_clock, source_utc, sender: source_sender)
    seed_runtime(source)

    assert {:ok, snapshot} = Observer.runtime_snapshot(source)

    {:ok, target_clock} = start_clock(50_000)
    {:ok, target_utc} = start_utc_clock()
    target_sender = fn _channel, update -> send(parent, {:target_update, update}) end
    target = start_observer(target_clock, target_utc, sender: target_sender)

    assert :ok = Observer.restore_runtime(target, snapshot)
    restored = :sys.get_state(target)
    assert restored.dirty_sync == MapSet.new([{5, 9}])
    assert restored.dirty_persist == MapSet.new([{6, 18}])
    assert restored.force_persist
    assert restored.last_sync_ms == 5_000
    assert restored.last_persist_ms == 20_000
    assert restored.seq == 41

    assert :ok = Observer.sync_now(source)
    assert :ok = Observer.sync_now(target)
    assert_receive {:source_update, source_update}
    assert_receive {:target_update, target_update}
    assert target_update == source_update
  end

  test "restores sampling phase and rejects stale pre-restore tick messages by token" do
    {:ok, source_clock} = start_clock(100_000)
    {:ok, source_utc} = start_utc_clock()
    source = start_observer(source_clock, source_utc, sample_ms: 60_000)

    :sys.replace_state(source, fn state -> %{state | next_tick_ms: 99_999} end)
    assert {:ok, due_snapshot} = Observer.runtime_snapshot(source)
    assert due_snapshot.tick == %{remaining_ms: 0}

    :sys.replace_state(source, fn state -> %{state | next_tick_ms: 145_000} end)
    assert {:ok, snapshot} = Observer.runtime_snapshot(source)
    assert snapshot.tick == %{remaining_ms: 45_000}

    {:ok, target_clock} = start_clock(50_000)
    {:ok, target_utc} = start_utc_clock(DateTime.add(@capture_utc, 5, :second))
    target = start_observer(target_clock, target_utc, sample_ms: 60_000)
    stale_token = :sys.get_state(target).tick_token

    assert :ok = Observer.restore_runtime(target, snapshot)
    restored = :sys.get_state(target)
    assert restored.next_tick_ms == 90_000
    assert restored.tick_token != stale_token
    assert is_reference(restored.tick_timer_ref)

    send(target, {:tick, stale_token})
    Process.sleep(10)
    after_stale = :sys.get_state(target)
    assert after_stale.stats == restored.stats
    assert after_stale.next_tick_ms == restored.next_tick_ms
  end

  test "capture clamps overdue cadence ages to their causal intervals" do
    {:ok, clock} = start_clock(100_000)
    {:ok, utc_clock} = start_utc_clock()
    observer = start_observer(clock, utc_clock, persist_ms: 30_000, sync_ms: 20_000)

    :sys.replace_state(observer, fn state ->
      %{state | last_sync_ms: 1_000, last_persist_ms: 2_000}
    end)

    assert {:ok, snapshot} = Observer.runtime_snapshot(observer)
    assert snapshot.sync.last_sync_age_ms == 20_000
    assert snapshot.persistence_phase.last_persist_age_ms == 30_000
  end

  test "projection rejects authoritative alias keys before they can collapse" do
    {:ok, clock} = start_clock(100_000)
    {:ok, utc_clock} = start_utc_clock()
    observer = start_observer(clock, utc_clock, window_size: 1, gate: [min_dwell: 1])
    state = :sys.get_state(observer)

    alias_cases = [
      Map.put(state, "boat_identifier", "shadow-authority"),
      Map.put(state, "seq", state.seq + 1),
      Map.put(state, "source_generation", state.source_generation + 1),
      Map.put(state, "window", [sample(100_000)]),
      Map.put(state, :gate, Map.put(Map.from_struct(state.gate), "min_dwell", state.gate.min_dwell + 1)),
      Map.put(
        state,
        :bins,
        Map.put(Map.from_struct(state.bins), "twa_width_deg", state.bins.twa_width_deg / 2)
      )
    ]

    for aliased <- alias_cases do
      assert {:error, :invalid_runtime_snapshot} =
               RuntimeSnapshot.project(aliased, 100_000, @capture_utc)
    end
  end

  test "projection preserves database-bounded authoritative integers and rejects u64 overflow" do
    {:ok, clock} = start_clock(100_000)
    {:ok, utc_clock} = start_utc_clock()
    observer = start_observer(clock, utc_clock, window_size: 1, gate: [min_dwell: 1])
    state = :sys.get_state(observer)

    assert {:ok, maximum} =
             state
             |> Map.put(:source_generation, 9_223_372_036_854_775_807)
             |> Map.put(:seq, 9_223_372_036_854_775_807)
             |> RuntimeSnapshot.project(100_000, @capture_utc)

    assert maximum.learner.source_generation == 9_223_372_036_854_775_807
    assert maximum.upstream_seq == 9_223_372_036_854_775_807

    for oversized <- [0x1_0000_0000_0000_0000, 9_223_372_036_854_775_808] do
      assert {:error, :invalid_runtime_snapshot} =
               state
               |> Map.put(:source_generation, oversized)
               |> RuntimeSnapshot.project(100_000, @capture_utc)

      assert {:error, :invalid_runtime_snapshot} =
               state
               |> Map.put(:seq, oversized)
               |> RuntimeSnapshot.project(100_000, @capture_utc)
    end
  end

  test "preflight rejects negative zero before canonical encode can change authoritative bits" do
    {:ok, clock} = start_clock(100_000)
    {:ok, utc_clock} = start_utc_clock()
    observer = start_observer(clock, utc_clock, window_size: 1, gate: [min_dwell: 1])
    assert {:ok, snapshot} = Observer.runtime_snapshot(observer)

    negative_zero =
      <<0x8000_0000_0000_0000::64>>
      |> then(fn bits ->
        <<value::float-64>> = bits
        value
      end)

    for candidate <- [
          put_in(snapshot, [:policy, :min_stw_mps], negative_zero),
          put_in(snapshot, [:policy, :gate, :max_accel_mps2], negative_zero),
          put_in(snapshot, [:window], [
            sample(100_000, %{tws_mps: negative_zero}) |> Map.delete(:t_ms) |> Map.put(:age_ms, 0)
          ])
        ] do
      assert {:error, :invalid_runtime_snapshot} = RuntimeSnapshot.preflight(candidate)
    end
  end

  test "preflight rejects rebound gate negative zero rather than relying on policy hash mismatch" do
    {:ok, clock} = start_clock(100_000)
    {:ok, utc_clock} = start_utc_clock()
    observer = start_observer(clock, utc_clock, window_size: 1, gate: [min_dwell: 1])
    assert {:ok, snapshot} = Observer.runtime_snapshot(observer)

    negative_zero =
      <<0x8000_0000_0000_0000::64>>
      |> then(fn bits ->
        <<value::float-64>> = bits
        value
      end)

    gate = Map.put(snapshot.policy.gate, :max_accel_mps2, negative_zero)

    assert {:ok, policy_hash} =
             Snapshot.policy_hash(
               struct!(Gate, gate),
               snapshot.policy.min_stw_mps,
               snapshot.policy.window_size,
               snapshot.policy.p
             )

    rebound =
      snapshot
      |> put_in([:policy, :gate], gate)
      |> put_in([:policy, :admission_hash], policy_hash)
      |> put_in([:learner, :content, :policy_hash], policy_hash)

    assert {:error, :invalid_runtime_snapshot} = RuntimeSnapshot.preflight(rebound)
  end

  test "strict validation rejects open, noncanonical, duplicate, and causally inconsistent state before mutation" do
    {:ok, source_clock} = start_clock(100_000)
    {:ok, source_utc} = start_utc_clock()
    source = start_observer(source_clock, source_utc, window_size: 3, gate: [min_dwell: 3])
    seed_runtime(source)
    assert {:ok, snapshot} = Observer.runtime_snapshot(source)

    {:ok, target_clock} = start_clock(50_000)
    {:ok, target_utc} = start_utc_clock()
    target = start_observer(target_clock, target_utc, window_size: 3, gate: [min_dwell: 3])
    before = :sys.get_state(target)

    [first_dirty] = snapshot.sync.dirty_keys

    invalid = [
      Map.put(snapshot, :metadata, %{token: "forbidden"}),
      put_in(snapshot, [:policy, :metadata], %{}),
      put_in(snapshot, [:policy, :bins, :tws_width_mps], 1.0),
      put_in(snapshot, [:sync, :dirty_keys], [first_dirty, first_dirty]),
      put_in(snapshot, [:sync, :dirty_keys], [%{tws_bin: 6, twa_bin: 18}, first_dirty]),
      put_in(snapshot, [:sync, :dirty_keys], [%{tws_bin: 99, twa_bin: 99}]),
      put_in(snapshot, [:learner, :source_generation], snapshot.learner.source_generation + 1),
      %{snapshot | window: Enum.reverse(snapshot.window)},
      %{snapshot | window: List.duplicate(hd(snapshot.window), 4)},
      put_in(snapshot, [:window, Access.at(0), :secret], "forbidden")
    ]

    for candidate <- invalid do
      assert {:error, :invalid_runtime_snapshot} = Observer.restore_runtime(target, candidate)
      assert :sys.get_state(target) == before
    end
  end

  test "authority, policy, stale, and conflict errors fail before mutation while exact retry is idempotent" do
    {:ok, source_clock} = start_clock(100_000)
    {:ok, source_utc} = start_utc_clock()
    {:ok, source_signals} = start_signals(signals(101_000, 4.0))

    source =
      start_observer(source_clock, source_utc,
        window_size: 1,
        gate: [min_dwell: 1],
        signals_fn: signals_fn(source_signals)
      )

    assert :ok = Observer.tick(source)
    set_now(source_clock, 101_000)
    set_utc(source_utc, DateTime.add(@capture_utc, 1, :second))
    assert {:ok, snapshot} = Observer.runtime_snapshot(source)

    {:ok, authority_clock} = start_clock(50_000)
    {:ok, authority_utc} = start_utc_clock()

    authority_target =
      start_observer(authority_clock, authority_utc,
        boat_identifier: "other-boat",
        window_size: 1,
        gate: [min_dwell: 1]
      )

    authority_before = :sys.get_state(authority_target)
    assert {:error, :authority_mismatch} = Observer.restore_runtime(authority_target, snapshot)
    assert :sys.get_state(authority_target) == authority_before

    {:ok, policy_clock} = start_clock(50_000)
    {:ok, policy_utc} = start_utc_clock()
    policy_target = start_observer(policy_clock, policy_utc, window_size: 1, gate: [min_dwell: 1], sync_ms: 30_000)
    policy_before = :sys.get_state(policy_target)
    assert {:error, :policy_mismatch} = Observer.restore_runtime(policy_target, snapshot)
    assert :sys.get_state(policy_target) == policy_before

    {:ok, geometry_clock} = start_clock(50_000)
    {:ok, geometry_utc} = start_utc_clock(DateTime.add(@capture_utc, 1, :second))

    geometry_target =
      start_observer(geometry_clock, geometry_utc,
        window_size: 1,
        gate: [min_dwell: 1],
        bins: Bins.new(tws_width_mps: 1.0)
      )

    geometry_before = :sys.get_state(geometry_target)
    assert {:error, :policy_mismatch} = Observer.restore_runtime(geometry_target, snapshot)
    assert :sys.get_state(geometry_target) == geometry_before

    {:ok, target_clock} = start_clock(50_000)
    {:ok, target_utc} = start_utc_clock(DateTime.add(@capture_utc, 1, :second))
    {:ok, target_signals} = start_signals(signals(51_000, 4.2))

    target =
      start_observer(target_clock, target_utc,
        window_size: 1,
        gate: [min_dwell: 1],
        signals_fn: signals_fn(target_signals)
      )

    assert :ok = RuntimeSnapshot.preflight(snapshot)
    assert :ok = Observer.restore_runtime(target, snapshot)
    restored = :sys.get_state(target)

    conflict = update_in(snapshot, [:window, Access.at(0), :stw_mps], &(&1 + 0.1))
    assert {:error, :restore_conflict} = Observer.restore_runtime(target, conflict)
    assert :sys.get_state(target) == restored

    assert :ok = Observer.tick(target)
    progressed = :sys.get_state(target)

    assert :ok = Observer.restore_runtime(target, snapshot)
    assert :sys.get_state(target) == progressed

    stale = %{snapshot | captured_at_utc_ms: snapshot.captured_at_utc_ms - 1}
    assert {:error, :stale_snapshot} = Observer.restore_runtime(target, stale)
    assert :sys.get_state(target) == progressed
  end

  test "restore conflicts on equal generation and capture even when learner content is identical" do
    {:ok, source_clock} = start_clock(100_000)
    {:ok, source_utc} = start_utc_clock()
    source = start_observer(source_clock, source_utc, window_size: 1, gate: [min_dwell: 1])

    assert {:ok, snapshot} = Observer.runtime_snapshot(source)

    {:ok, target_clock} = start_clock(50_000)
    {:ok, target_utc} = start_utc_clock()
    target = start_observer(target_clock, target_utc, window_size: 1, gate: [min_dwell: 1])

    assert :ok = Observer.restore_runtime(target, snapshot)
    before = :sys.get_state(target)

    conflict = put_in(snapshot, [:sync, :last_sync_age_ms], 1)
    assert {:error, :restore_conflict} = Observer.restore_runtime(target, conflict)
    assert :sys.get_state(target) == before

    set_utc(target_utc, DateTime.add(@capture_utc, 1, :second))

    newer =
      snapshot
      |> Map.put(:captured_at_utc_ms, snapshot.captured_at_utc_ms + 1_000)
      |> put_in([:sync, :last_sync_age_ms], 1_000)

    assert :ok = Observer.restore_runtime(target, newer)
    assert :sys.get_state(target).last_sync_ms == 49_000
  end

  test "semantic runtime validity remains independent of the 65,327-byte single-frame limit" do
    bins = Bins.new(twa_width_deg: 2.5, tws_width_mps: 0.05, max_tws_mps: 51.4444)
    marker = feed([3.5, 3.7, 3.9, 4.1, 4.3, 4.5])

    cells =
      for tws_bin <- 0..599, into: %{} do
        {{tws_bin, rem(tws_bin, 72)}, {6, marker}}
      end

    {:ok, source_clock} = start_clock(100_000)
    {:ok, source_utc} = start_utc_clock()
    source = start_observer(source_clock, source_utc, bins: bins)

    :sys.replace_state(source, fn state ->
      %{
        state
        | cells: cells,
          source_generation: 600,
          dirty_sync: MapSet.new(),
          dirty_persist: MapSet.new()
      }
    end)

    assert {:ok, snapshot} = Observer.runtime_snapshot(source)
    assert byte_size(snapshot.learner.content.content) > 65_327

    assert {:error, :checkpoint_too_large} =
             ContractCheckpoint.decode_content(:polar, 2, snapshot.learner.content.content)

    {:ok, target_clock} = start_clock(50_000)
    {:ok, target_utc} = start_utc_clock()
    target = start_observer(target_clock, target_utc, bins: bins)
    assert :ok = Observer.restore_runtime(target, snapshot)
    assert :sys.get_state(target).cells == cells
  end
end
