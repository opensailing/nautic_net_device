defmodule RacingOrg.Tracker.Pro.WindShift.ObserverSnapshotTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.RuntimeSnapshot
  alias RacingOrg.Tracker.Pro.WindShift.Config
  alias RacingOrg.Tracker.Pro.WindShift.Observer

  @capture_utc ~U[2026-08-12 12:00:00Z]
  @device_id <<1::128>>
  @storage_epoch <<2::128>>
  @authority %{
    device_id: @device_id,
    credential_epoch: 7,
    storage_epoch: @storage_epoch
  }

  defp start_clock(monotonic_ms, utc \\ @capture_utc) do
    {:ok, clock} = Agent.start_link(fn -> %{monotonic_ms: monotonic_ms, utc: utc} end)
    clock
  end

  defp set_clock(clock, monotonic_ms, utc) do
    Agent.update(clock, fn _ -> %{monotonic_ms: monotonic_ms, utc: utc} end)
  end

  defp start_observer(clock, opts \\ []) do
    defaults = [
      name: nil,
      sample_ms: 0,
      dir: nil,
      config: nil,
      commands: nil,
      boat_identifier: "boat-test",
      broadcast_enabled: false,
      authority_fn: fn -> {:ok, @authority} end,
      signals_fn: fn -> %{} end,
      now_fn: fn -> Agent.get(clock, & &1.monotonic_ms) end,
      utc_now_fn: fn -> Agent.get(clock, & &1.utc) end,
      put_signals_fn: fn _updates, _monotonic_ms -> :ok end,
      sender: fn _channel, _update -> :ok end,
      transmit_fn: fn _priority, _pgn, _payload -> :ok end
    ]

    {:ok, observer} = Observer.start_link(Keyword.merge(defaults, opts))
    observer
  end

  defp accept_sample(observer, clock, monotonic_ms, utc, twd \\ 200.0) do
    set_clock(clock, monotonic_ms, utc)

    :sys.replace_state(observer, fn state ->
      %{state | signals_fn: fn -> %{"true_wind_direction" => {twd, monotonic_ms}} end}
    end)

    :ok = Observer.tick(observer)
  end

  test "snapshot is a closed versioned full-runtime envelope with exact authority and policy" do
    clock = start_clock(10_000)
    observer = start_observer(clock)
    accept_sample(observer, clock, 10_000, @capture_utc)

    assert {:ok, snapshot} = Observer.snapshot(observer)

    assert Map.keys(snapshot) |> Enum.sort() ==
             [
               :authority,
               :captured_at_utc_ms,
               :policy,
               :runtime,
               :source_generation,
               :stats,
               :tick,
               :version
             ]

    assert snapshot.version == RuntimeSnapshot.version()
    assert snapshot.captured_at_utc_ms == DateTime.to_unix(@capture_utc, :millisecond)
    assert snapshot.authority == @authority
    assert snapshot.source_generation == 1
    assert snapshot.stats == %{samples: 1, accepted: 1, rejected: 0, reject_reasons: %{}}
    assert snapshot.tick == %{remaining_ms: nil}

    assert snapshot.policy == %{
             version: nil,
             windows: %{fast_s: 30.0, mid_s: 300.0, slow_s: 1500.0, envelope_s: 1800.0},
             alarms: %{new_extreme_margin_deg: 2.0, enabled: true},
             wally_mode: "off",
             sample_ms: 0,
             persist_ms: 60_000,
             sync_ms: 60_000,
             timeline_ms: 60_000,
             staleness_ms: 3_000,
             residual_window: 1_800,
             period_every_ms: 60_000,
             xing_hysteresis_deg: 2.0,
             absorb_dwell_ticks: 60,
             broadcast_rate_ms: 1_000
           }

    assert snapshot.runtime.session.started_at_ms == DateTime.to_unix(@capture_utc, :millisecond)
    assert snapshot.runtime.means.fast != nil
    assert snapshot.runtime.seq == 0
    assert_closed_value(snapshot)
    refute forbidden_key?(snapshot)

    target_clock = start_clock(50_000)
    target = start_observer(target_clock)
    assert :ok = Observer.restore(target, snapshot)
    assert Observer.snapshot(target) == {:ok, snapshot}
    assert Observer.stats(target) == snapshot.stats
  end

  test "restore fences authority, complete policy, version, stale generations, and same-generation conflicts" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    accept_sample(source, source_clock, 10_000, @capture_utc)
    assert {:ok, snapshot} = Observer.snapshot(source)

    target_clock = start_clock(50_000)
    target = start_observer(target_clock)
    assert {:ok, before} = Observer.snapshot(target)

    assert {:error, :authority_mismatch} =
             Observer.restore(target, put_in(snapshot, [:authority, :credential_epoch], 8))

    assert {:error, :policy_mismatch} =
             Observer.restore(target, put_in(snapshot, [:policy, :staleness_ms], 3_001))

    assert {:error, :invalid_wind_shift_runtime_snapshot} =
             Observer.restore(target, %{snapshot | version: snapshot.version + 1})

    assert Observer.snapshot(target) == {:ok, before}

    assert :ok = Observer.restore(target, snapshot)

    conflicting = put_in(snapshot, [:runtime, :seq], snapshot.runtime.seq + 1)
    assert {:error, :snapshot_conflict} = Observer.restore(target, conflicting)

    accept_sample(target, target_clock, 51_000, DateTime.add(@capture_utc, 1, :second), 201.0)
    assert {:ok, progressed} = Observer.snapshot(target)
    assert progressed.source_generation > snapshot.source_generation

    stale = %{conflicting | source_generation: snapshot.source_generation - 1}
    assert {:error, :stale_snapshot} = Observer.restore(target, stale)
    assert Observer.snapshot(target) == {:ok, progressed}

    assert :ok = Observer.restore(target, snapshot)
    assert Observer.snapshot(target) == {:ok, progressed}
  end

  test "complete config policy version, alarms, windows, and wally mode are bound exactly" do
    config = start_supervised!({Config, name: nil, store_dir: nil}, id: make_ref())

    assert {:ok, _policy} =
             Config.apply_config(config, %{
               "version" => 4,
               "windows" => %{
                 "fast_s" => 20,
                 "mid_s" => 200,
                 "slow_s" => 1_200,
                 "envelope_s" => 1_500
               },
               "alarms" => %{"new_extreme_margin_deg" => 3.5, "enabled" => false},
               "wally" => %{"mode" => "shadow"}
             })

    source_clock = start_clock(10_000)
    source = start_observer(source_clock, config: {Config, config})
    assert {:ok, snapshot} = Observer.snapshot(source)

    assert snapshot.policy.version == 4
    assert snapshot.policy.windows == %{fast_s: 20.0, mid_s: 200.0, slow_s: 1_200.0, envelope_s: 1_500.0}
    assert snapshot.policy.alarms == %{new_extreme_margin_deg: 3.5, enabled: false}
    assert snapshot.policy.wally_mode == "shadow"

    target_clock = start_clock(50_000)
    target = start_observer(target_clock)
    assert {:error, :policy_mismatch} = Observer.restore(target, snapshot)
  end

  test "powered-off elapsed time advances ages and timer phase while restore regenerates timer identity" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock, sample_ms: 1_000)
    accept_sample(source, source_clock, 10_000, @capture_utc)

    capture_utc = DateTime.add(@capture_utc, 400, :millisecond)
    set_clock(source_clock, 10_400, capture_utc)
    assert {:ok, snapshot} = Observer.snapshot(source)
    assert snapshot.tick == %{remaining_ms: 600}
    assert snapshot.runtime.means.fast.age_ms == 400

    target_clock = start_clock(50_000, DateTime.add(capture_utc, 250, :millisecond))
    target = start_observer(target_clock, sample_ms: 1_000)
    before = :sys.get_state(target)
    old_ref = before.tick_timer_ref
    old_token = before.tick_token

    assert :ok = Observer.restore(target, snapshot)
    restored = :sys.get_state(target)

    assert restored.tick_timer_ref != old_ref
    assert restored.tick_token != old_token
    assert is_reference(restored.tick_timer_ref)
    assert is_reference(restored.tick_token)
    assert restored.next_tick_ms == 50_350

    assert {:ok, advanced} = Observer.snapshot(target)
    assert advanced.tick == %{remaining_ms: 350}
    assert advanced.runtime.means.fast.age_ms == 650

    send(target, {:tick, old_token})
    Process.sleep(10)
    after_stale = :sys.get_state(target)
    assert after_stale.tick_token == restored.tick_token
    assert after_stale.source_generation == restored.source_generation
  end

  test "restore rejects open, duplicate, and malformed runtime collections before mutation" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    accept_sample(source, source_clock, 10_000, @capture_utc)
    assert {:ok, snapshot} = Observer.snapshot(source)

    row = %{
      t_ms: DateTime.to_unix(@capture_utc, :millisecond),
      mean_twd_deg: 200.0,
      phase_deg: 0.0,
      amplitude_deg: nil,
      period_s: nil,
      trend_deg_per_hr: nil,
      tws_mps: nil
    }

    target_clock = start_clock(50_000)
    target = start_observer(target_clock)
    assert {:ok, before} = Observer.snapshot(target)

    for invalid <- [
          Map.put(snapshot, :metadata, %{}),
          put_in(snapshot, [:runtime, :pending_timeline], [row, row]),
          put_in(snapshot, [:runtime, :pending_events], [%{payload: "open"}]),
          put_in(snapshot, [:stats, :reject_reasons], %{unknown: 1}),
          put_in(snapshot, [:authority, :storage_epoch], <<0::128>>)
        ] do
      assert {:error, :invalid_wind_shift_runtime_snapshot} = Observer.restore(target, invalid)
      assert Observer.snapshot(target) == {:ok, before}
    end
  end

  defp forbidden_key?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      key in [
        :metadata,
        :payload,
        :secret,
        :credentials,
        :token,
        "metadata",
        "payload",
        "secret",
        "credentials",
        "token"
      ] or
        forbidden_key?(value)
    end)
  end

  defp forbidden_key?(list) when is_list(list), do: Enum.any?(list, &forbidden_key?/1)
  defp forbidden_key?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.any?(&forbidden_key?/1)
  defp forbidden_key?(_value), do: false

  defp assert_closed_value(value) when is_map(value),
    do:
      Enum.each(value, fn {key, nested} ->
        assert_closed_value(key)
        assert_closed_value(nested)
      end)

  defp assert_closed_value(value) when is_list(value), do: Enum.each(value, &assert_closed_value/1)

  defp assert_closed_value(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.each(&assert_closed_value/1)

  defp assert_closed_value(value)
       when is_atom(value) or is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_nil(value),
       do: :ok
end
