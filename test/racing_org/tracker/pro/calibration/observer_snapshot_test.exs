defmodule RacingOrg.Tracker.Pro.Calibration.ObserverSnapshotTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Checkpoint
  alias RacingOrg.Tracker.Pro.Calibration.Detect.Leg
  alias RacingOrg.Tracker.Pro.Calibration.Detect.Legs
  alias RacingOrg.Tracker.Pro.Calibration.Config
  alias RacingOrg.Tracker.Pro.Calibration.Detect.Tack
  alias RacingOrg.Tracker.Pro.Calibration.Estimate
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.AwaOffset
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.AwsScale
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.StwScale
  alias RacingOrg.Tracker.Pro.Calibration.Observer
  alias RacingOrg.Tracker.Pro.Calibration.Observer.Snapshot
  alias RacingOrg.Tracker.Pro.Calibration.Observer.Store

  @wind_hex "1A2B"
  @speed_hex "3C4D"
  @speed_name <<0, 0, 0, 0, 0, 0, 0x3C, 0x4D>>
  @capture_utc ~U[2026-08-10 12:00:00Z]

  defmodule RejectingCalibration do
    @modes %{
      "awa_offset" => "auto",
      "awa_upwash" => "auto",
      "stw_scale" => "auto",
      "aws_scale" => "shadow"
    }

    def subscribe(_server, _subscriber), do: :ok
    def status(_server), do: %{modes: @modes}
    def reconcile_learned(_server, _entries), do: {:error, :rejected}
  end

  defmodule CommitAndRollbackFailingCalibration do
    @modes %{
      "awa_offset" => "auto",
      "awa_upwash" => "auto",
      "stw_scale" => "auto",
      "aws_scale" => "shadow"
    }

    def start_link(dir), do: Agent.start_link(fn -> %{calls: 0, dir: dir, entries: []} end)
    def subscribe(_server, _subscriber), do: :ok
    def status(_server), do: %{modes: @modes}
    def entries(server), do: Agent.get(server, & &1.entries)

    def reconcile_learned(server, entries) do
      Agent.get_and_update(server, fn
        %{calls: 0, dir: dir} = state ->
          File.mkdir!(Path.join(dir, "observer.calibration"))
          {:ok, %{state | calls: 1, entries: entries}}

        %{calls: 1} = state ->
          {{:error, :rollback_rejected}, %{state | calls: 2}}

        state ->
          {:ok, %{state | calls: state.calls + 1, entries: entries}}
      end)
    end
  end

  defp start_clock(now_ms) do
    {:ok, clock} = Agent.start_link(fn -> now_ms end)
    clock
  end

  defp now_fn(clock), do: fn -> Agent.get(clock, & &1) end
  defp set_now(clock, now_ms), do: Agent.update(clock, fn _ -> now_ms end)

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "observer-snapshot-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp start_observer(clock, opts \\ []) do
    defaults = [
      name: nil,
      sample_ms: 0,
      dir: nil,
      calibration: nil,
      boat_identifier: "boat-authority",
      sender: fn _channel, _update -> :ok end,
      now_fn: now_fn(clock),
      utc_now_fn: fn -> @capture_utc end,
      sync_ms: 60_000,
      persist_ms: 60_000,
      legs: [min_duration_s: 30.0]
    ]

    {:ok, observer} = Observer.start_link(Keyword.merge(defaults, opts))
    observer
  end

  test "observer authority is canonical UTF-8 at startup and snapshot preflight" do
    base = [
      name: nil,
      sample_ms: 0,
      dir: nil,
      calibration: nil,
      sender: fn _channel, _update -> :ok end
    ]

    for invalid <- ["é", <<0xFF>>] do
      assert {:error, :invalid_checkpoint_config} =
               Observer.start_link(Keyword.put(base, :boat_identifier, invalid))
    end

    clock = start_clock(10_000)
    observer = start_observer(clock, boat_identifier: "Café")
    assert {:ok, snapshot} = Observer.snapshot(observer)
    assert snapshot.authority == %{boat_identifier: "Café"}
    assert :ok = Snapshot.preflight(snapshot)

    for invalid <- ["é", <<0xFF>>] do
      assert {:error, :invalid_runtime_snapshot} =
               Snapshot.preflight(put_in(snapshot, [:authority, :boat_identifier], invalid))
    end
  end

  defp leg do
    %Leg{
      started_ms: 1_000,
      ended_ms: 8_000,
      duration_s: 7.0,
      samples: 8,
      side: :starboard,
      heading_mean: 320.0,
      heading_sd: 1.0,
      cog_mean: 320.0,
      sog_mean: 3.0,
      stw_mean: 3.0,
      stw_sd: 0.02,
      awa_mean_signed: 30.0,
      awa_abs_mean: 30.0,
      aws_mean: 8.0,
      tws_mean: 6.0,
      tws_sd: 0.1,
      heel_mean: 12.0
    }
  end

  defp long_leg(overrides \\ []) do
    struct!(
      %Leg{
        started_ms: 0,
        ended_ms: 80_000,
        duration_s: 80.0,
        samples: 81,
        side: :starboard,
        heading_mean: 320.0,
        heading_sd: 1.0,
        cog_mean: 320.0,
        sog_mean: 3.0,
        stw_mean: 3.0,
        stw_sd: 0.02,
        awa_mean_signed: 30.0,
        awa_abs_mean: 30.0,
        aws_mean: 8.0,
        tws_mean: 6.0,
        tws_sd: 0.1,
        heel_mean: 12.0
      },
      overrides
    )
  end

  defp raw_speed(timestamp_ms) do
    %NMEA.Data{
      values: %{NMEA.SpeedParams => %NMEA.SpeedParams{speed: 3.0, speed_reference: :water}},
      source_info: %NMEA.NMEA2000.Frame{timestamp_monotonic_ms: timestamp_ms},
      metadata: %{source_nmea_name: @speed_name}
    }
  end

  defp validated_awa do
    tracker = Enum.reduce(List.duplicate(1.0, 8), AwaOffset.new().rotation, &Estimate.observe(&2, &1))
    %{AwaOffset.new() | rotation: tracker, pairs_seen: 8}
  end

  defp seed_runtime(observer) do
    open_sample = %{
      t_ms: 9_000,
      heading_deg: 320.0,
      cog_deg: 320.0,
      sog_mps: 3.0,
      stw_mps: 3.0,
      awa_deg: 30.0,
      aws_mps: 8.0,
      tws_mps: 6.0,
      heel_deg: 12.0
    }

    :sys.replace_state(observer, fn state ->
      {legs, []} = Legs.step(state.legs, open_sample)
      {tack, []} = Tack.step(state.tack, leg())

      aws =
        AwsScale.new()
        |> AwsScale.observe_leg(%{t_end_s: 8.0, tws_mean: 6.0, awa_abs_mean: 30.0})

      %{
        state
        | latest: %{
            awa: {30.0, @wind_hex, 9_500},
            aws: {8.0, @wind_hex, 9_500},
            stw: {3.0, @speed_hex, 9_500},
            heading: {320.0, "5E6F", 9_500},
            cog: {320.0, "7A8B", 9_500},
            sog: {3.0, "7A8B", 9_500}
          },
          legs: legs,
          tack: tack,
          window_sources: {@wind_hex, @speed_hex},
          awa_estimators: %{@wind_hex => validated_awa()},
          stw_estimators: %{@speed_hex => StwScale.new()},
          aws_estimators: %{@wind_hex => aws},
          prev_applied: %{{@wind_hex, "awa_offset"} => 0.5},
          seq: 3,
          last_persist_ms: 8_000,
          last_sync_ms: 7_000,
          dirty_persist: true,
          stats: %{
            samples: 11,
            accepted: 10,
            rejected: 1,
            reject_reasons: %{at_rest: 1},
            legs: 2,
            tack_pairs: 1,
            gybe_pairs: 0,
            reciprocal_pairs: 0,
            source_resets: 0
          }
      }
    end)

    :ok
  end

  test "snapshot is one closed runtime shape and reuses canonical calibration learner content" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)

    assert {:ok, snapshot} = Observer.snapshot(source)

    assert Map.keys(snapshot) |> Enum.sort() ==
             [
               :authority,
               :captured_at_utc_ms,
               :latest,
               :learner,
               :learner_time_basis,
               :legs,
               :policy,
               :stats,
               :sync,
               :tack,
               :tick,
               :version,
               :window_binding,
               :window_sources
             ]

    assert snapshot.version == 1
    assert snapshot.captured_at_utc_ms == DateTime.to_unix(@capture_utc, :millisecond)
    assert snapshot.authority == %{boat_identifier: "boat-authority"}
    assert {:ok, learner} = Checkpoint.hydrate(snapshot.learner)
    assert learner.seq == 3
    assert [{8.0, 6.0}] = learner.aws_estimators[@wind_hex].regimes.upwind

    assert [time_basis] = snapshot.learner_time_basis
    assert time_basis.hardware_identifier == @wind_hex
    assert [%{name: :upwind, ages_s: [age_s]} | _] = time_basis.regimes
    assert_in_delta age_s, 2.0, 1.0e-9

    refute Map.has_key?(snapshot, :persistence)
    refute Map.has_key?(snapshot, :metadata)
    refute Map.has_key?(snapshot, :hex_cache)
    refute Map.has_key?(snapshot, :modes)
    refute Map.has_key?(snapshot, :sender)
    refute Map.has_key?(snapshot.policy, :legs)
    refute Map.has_key?(snapshot.policy, :tack)
    assert Map.has_key?(snapshot.legs, :config)
    assert Map.has_key?(snapshot.tack, :config)

    target_clock = start_clock(50_000)
    target = start_observer(target_clock)

    assert :ok = Observer.restore(target, snapshot)
    assert {:ok, restored_snapshot} = Observer.snapshot(target)
    assert restored_snapshot.learner_time_basis == snapshot.learner_time_basis
    assert restored_snapshot.latest == snapshot.latest
    assert restored_snapshot.stats == snapshot.stats
  end

  test "invalid snapshots fail closed before any GenServer state mutation" do
    clock = start_clock(10_000)
    observer = start_observer(clock)
    :ok = seed_runtime(observer)
    assert {:ok, snapshot} = Observer.snapshot(observer)

    invalid = Map.put(snapshot, :metadata, %{secret: "must-not-restore"})
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(observer, invalid)
    assert {:ok, ^snapshot} = Observer.snapshot(observer)

    invalid = put_in(snapshot, [:latest, Access.at(0), :age_ms], -1)
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(observer, invalid)
    assert {:ok, ^snapshot} = Observer.snapshot(observer)
  end

  test "restore rejects unknown versions, excessive elapsed time, and backward clock skew without mutation" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    version_clock = start_clock(20_000)
    version_target = start_observer(version_clock)
    assert {:ok, before_version} = Observer.snapshot(version_target)

    assert {:error, :invalid_runtime_snapshot} =
             Observer.restore(version_target, %{snapshot | version: snapshot.version + 1})

    assert {:ok, ^before_version} = Observer.snapshot(version_target)

    late_clock = start_clock(20_000)
    too_late = DateTime.add(@capture_utc, 2_592_001, :second)
    late_target = start_observer(late_clock, utc_now_fn: fn -> too_late end)
    assert {:ok, before_late} = Observer.snapshot(late_target)
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(late_target, snapshot)
    assert {:ok, ^before_late} = Observer.snapshot(late_target)

    skew_clock = start_clock(20_000)
    backward = DateTime.add(@capture_utc, -1, :second)
    skew_target = start_observer(skew_clock, utc_now_fn: fn -> backward end)
    assert {:ok, before_skew} = Observer.snapshot(skew_target)
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(skew_target, snapshot)
    assert {:ok, ^before_skew} = Observer.snapshot(skew_target)
  end

  test "restore rejects mismatched authority and runtime policy without mutation" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    authority_clock = start_clock(20_000)
    authority_target = start_observer(authority_clock, boat_identifier: "different-boat")
    assert {:ok, before_authority} = Observer.snapshot(authority_target)
    assert {:error, :authority_mismatch} = Observer.restore(authority_target, snapshot)
    assert {:ok, ^before_authority} = Observer.snapshot(authority_target)

    policy_clock = start_clock(20_000)
    policy_target = start_observer(policy_clock)
    assert {:ok, before_policy} = Observer.snapshot(policy_target)
    mismatched_policy = put_in(snapshot, [:policy, :staleness_ms], snapshot.policy.staleness_ms + 1)
    assert {:error, :policy_mismatch} = Observer.restore(policy_target, mismatched_policy)
    assert {:ok, ^before_policy} = Observer.snapshot(policy_target)
  end

  test "effective estimator defaults normalize while changed policy and spliced learner settings conflict" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    equivalent_clock = start_clock(20_000)

    equivalent =
      start_observer(equivalent_clock,
        awa_estimator: [
          min_samples: 8,
          max_spread: 2.0,
          stability_window: 5,
          clamp_min: -10.0,
          clamp_max: 10.0,
          max_slew: 0.5
        ],
        stw_estimator: [min_samples: 6, max_spread: 0.04, stability_window: 5],
        aws_estimator: [window_s: 7_200.0, min_legs: 3, min_samples: 8, max_spread: 0.15, stability_window: 5]
      )

    assert :ok = Observer.restore(equivalent, snapshot)

    changed_clock = start_clock(20_000)
    changed = start_observer(changed_clock, awa_estimator: [min_samples: 9])
    assert {:error, :policy_mismatch} = Observer.restore(changed, snapshot)

    spliced = update_in(snapshot, [:learner, "awa_estimators", Access.at(0), "rotation", "min_samples"], &(&1 + 1))
    target_clock = start_clock(20_000)
    target = start_observer(target_clock)
    assert {:ok, before_splice} = Observer.snapshot(target)
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(target, spliced)
    assert {:ok, ^before_splice} = Observer.snapshot(target)
  end

  test "detector configuration has one snapshot authority and is fenced against the target" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    assert {:ok, snapshot} = Observer.snapshot(source)

    refute Map.has_key?(snapshot.policy, :legs)
    refute Map.has_key?(snapshot.policy, :tack)
    assert snapshot.legs.config.min_duration_s == 30.0

    target_clock = start_clock(20_000)
    target = start_observer(target_clock, legs: [min_duration_s: 31.0])
    assert {:error, :policy_mismatch} = Observer.restore(target, snapshot)
  end

  test "stale learner sequence is rejected before mutation" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    target_clock = start_clock(20_000)
    target = start_observer(target_clock)
    :sys.replace_state(target, &%{&1 | seq: 4})
    assert {:ok, before_restore} = Observer.snapshot(target)

    assert {:error, :stale_snapshot} = Observer.restore(target, snapshot)
    assert {:ok, ^before_restore} = Observer.snapshot(target)
  end

  test "an identical duplicate restore is an idempotent no-op after live progress" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    target_clock = start_clock(50_000)
    {:ok, target_utc} = Agent.start_link(fn -> @capture_utc end)
    target = start_observer(target_clock, utc_now_fn: fn -> Agent.get(target_utc, & &1) end)
    assert :ok = Observer.restore(target, snapshot)

    set_now(target_clock, 51_000)
    assert :ok = Observer.tick(target)
    assert {:ok, progressed} = Observer.snapshot(target)
    refute progressed == snapshot

    Agent.update(target_utc, &DateTime.add(&1, 31, :day))
    assert :ok = Observer.restore(target, snapshot)
    Agent.update(target_utc, fn _ -> @capture_utc end)
    assert {:ok, ^progressed} = Observer.snapshot(target)

    Agent.update(target_utc, fn _ -> DateTime.add(@capture_utc, -1, :second) end)
    assert :ok = Observer.restore(target, snapshot)
    Agent.update(target_utc, fn _ -> @capture_utc end)
    assert {:ok, ^progressed} = Observer.snapshot(target)

    conflicting = put_in(snapshot, [:stats, :samples], snapshot.stats.samples + 1)
    assert {:error, :restore_conflict} = Observer.restore(target, conflicting)
    assert {:ok, ^progressed} = Observer.snapshot(target)
  end

  test "a newer runtime-only snapshot with the same logical learner is accepted" do
    source_clock = start_clock(10_000)
    {:ok, utc_clock} = Agent.start_link(fn -> @capture_utc end)

    source =
      start_observer(source_clock,
        utc_now_fn: fn -> Agent.get(utc_clock, & &1) end
      )

    :ok = seed_runtime(source)
    assert {:ok, first} = Observer.snapshot(source)

    target_clock = start_clock(50_000)

    target =
      start_observer(target_clock,
        utc_now_fn: fn -> Agent.get(utc_clock, & &1) end
      )

    assert :ok = Observer.restore(target, first)

    set_now(source_clock, 11_000)
    Agent.update(utc_clock, &DateTime.add(&1, 1, :second))
    :sys.replace_state(source, fn state -> update_in(state, [:stats, :samples], &(&1 + 1)) end)
    assert {:ok, newer_runtime} = Observer.snapshot(source)
    assert newer_runtime.learner != first.learner or newer_runtime.learner_time_basis != first.learner_time_basis

    assert :ok = Observer.restore(target, newer_runtime)
    assert Observer.stats(target).samples == first.stats.samples + 1
  end

  test "same-sequence conflict checks include seq even when the local learner maps are empty" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)
    incoming = put_in(snapshot, [:learner, "seq"], 1)

    target_clock = start_clock(20_000)
    target = start_observer(target_clock)
    :sys.replace_state(target, &%{&1 | seq: 1})
    assert {:ok, before_restore} = Observer.snapshot(target)

    assert {:error, :restore_conflict} = Observer.restore(target, incoming)
    assert {:ok, ^before_restore} = Observer.snapshot(target)
  end

  test "a higher learner sequence cannot bypass the accepted capture coordinate" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    target_clock = start_clock(20_000)
    target = start_observer(target_clock)
    assert :ok = Observer.restore(target, snapshot)
    assert {:ok, restored} = Observer.snapshot(target)

    stale =
      snapshot
      |> Map.update!(:captured_at_utc_ms, &(&1 - 1_000))
      |> update_in([:learner, "seq"], &(&1 + 1))

    assert {:error, :stale_snapshot} = Observer.restore(target, stale)
    assert {:ok, ^restored} = Observer.snapshot(target)
  end

  test "a previously restored blank learner still enforces capture conflict and staleness fences" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    assert {:ok, snapshot} = Observer.snapshot(source)

    target_clock = start_clock(20_000)
    target = start_observer(target_clock)
    assert :ok = Observer.restore(target, snapshot)
    assert {:ok, restored} = Observer.snapshot(target)

    conflicting = put_in(snapshot, [:stats, :samples], 1)
    assert {:error, :restore_conflict} = Observer.restore(target, conflicting)
    assert {:ok, ^restored} = Observer.snapshot(target)

    stale = %{conflicting | captured_at_utc_ms: snapshot.captured_at_utc_ms - 1_000}
    assert {:error, :stale_snapshot} = Observer.restore(target, stale)
    assert {:ok, ^restored} = Observer.snapshot(target)
  end

  test "latest atomic sensor pairs and active detector window sources are causally bound" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)

    :sys.replace_state(source, fn state ->
      put_in(state, [:awa_estimators, "BEEF"], AwaOffset.new())
    end)

    assert {:ok, snapshot} = Observer.snapshot(source)

    aws_index = Enum.find_index(snapshot.latest, &(&1.channel == :aws))
    mixed_wind = put_in(snapshot, [:latest, Access.at(aws_index), :hardware_identifier], "FFFF")
    sog_index = Enum.find_index(snapshot.latest, &(&1.channel == :sog))
    mixed_course = put_in(snapshot, [:latest, Access.at(sog_index), :age_ms], 501)

    target_clock = start_clock(20_000)
    target = start_observer(target_clock)
    assert {:ok, before_restore} = Observer.snapshot(target)
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(target, mixed_wind)
    assert {:ok, ^before_restore} = Observer.snapshot(target)
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(target, mixed_course)
    assert {:ok, ^before_restore} = Observer.snapshot(target)

    wrong_window = put_in(snapshot, [:window_sources, :awa], "FFFF")
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(target, wrong_window)
    assert {:ok, ^before_restore} = Observer.snapshot(target)

    known_but_unbound_window = put_in(snapshot, [:window_sources, :awa], "BEEF")
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(target, known_but_unbound_window)
    assert {:ok, ^before_restore} = Observer.snapshot(target)
  end

  test "snapshot projection never returns runtime state that its own preflight rejects" do
    clock = start_clock(10_000)
    observer = start_observer(clock)
    legs = for index <- 0..255, do: {10.0 - index / 1_000, 6.0}

    estimator = %{
      AwsScale.new()
      | regimes: %{upwind: legs, reach: legs, downwind: legs},
        legs_seen: 768
    }

    estimators =
      Map.new(0..21, fn index ->
        hardware_identifier = index |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(4, "0")
        {hardware_identifier, estimator}
      end)

    :sys.replace_state(observer, &%{&1 | aws_estimators: estimators})
    assert {:error, :invalid_runtime_snapshot} = Observer.snapshot(observer)
  end

  test "oversized runtime collections fail closed before canonical learner hydration" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    target_clock = start_clock(20_000)
    target = start_observer(target_clock)
    assert {:ok, before_restore} = Observer.snapshot(target)

    oversized_latest = %{snapshot | latest: List.duplicate(hd(snapshot.latest), 8)}
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(target, oversized_latest)
    assert {:ok, ^before_restore} = Observer.snapshot(target)

    [estimator] = snapshot.learner["awa_estimators"]
    oversized_learner = put_in(snapshot, [:learner, "awa_estimators"], List.duplicate(estimator, 257))
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(target, oversized_learner)
    assert {:ok, ^before_restore} = Observer.snapshot(target)

    hostile_detector = put_in(snapshot, [:legs, :segment, :aws_sum], String.duplicate("x", 2_000_000))
    assert {:error, :invalid_runtime_snapshot} = Snapshot.preflight(hostile_detector)

    aggregate_payload = List.duplicate(List.duplicate(String.duplicate("x", 1_024), 9), 911)
    aggregate_hostile = put_in(snapshot, [:legs, :segment, :aws_sum], aggregate_payload)

    aggregate_hostile = %{
      aggregate_hostile
      | window_binding:
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary(
              {aggregate_hostile.legs, aggregate_hostile.tack, aggregate_hostile.window_sources},
              [:deterministic]
            )
          )
    }

    assert {:error, :invalid_runtime_snapshot} = Snapshot.preflight(aggregate_hostile)
    assert {:ok, ^before_restore} = Observer.snapshot(target)
  end

  test "AWS time sidecars are cardinality and capture-basis bound to canonical learner rows" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)

    :sys.replace_state(source, fn state ->
      estimator =
        state.aws_estimators[@wind_hex]
        |> AwsScale.observe_leg(%{t_end_s: 9.0, tws_mean: 6.5, awa_abs_mean: 30.0})

      put_in(state, [:aws_estimators, @wind_hex], estimator)
    end)

    assert {:ok, snapshot} = Observer.snapshot(source)

    target_clock = start_clock(20_000)
    target = start_observer(target_clock)
    assert {:ok, before_restore} = Observer.snapshot(target)

    missing_age = put_in(snapshot, [:learner_time_basis, Access.at(0), :regimes, Access.at(0), :ages_s], [])
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(target, missing_age)
    assert {:ok, ^before_restore} = Observer.snapshot(target)

    spliced_basis =
      update_in(
        snapshot,
        [:learner_time_basis, Access.at(0), :regimes, Access.at(0), :ages_s, Access.at(0)],
        &(&1 + 1.0)
      )

    assert {:error, :invalid_runtime_snapshot} = Observer.restore(target, spliced_basis)
    assert {:ok, ^before_restore} = Observer.snapshot(target)
  end

  test "a newer same-learner capture cannot rejuvenate AWS regime timestamps" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    [aws_estimator] = snapshot.learner["aws_estimators"]
    upwind_index = Enum.find_index(aws_estimator["regimes"], &(&1["name"] == "upwind"))

    rejuvenated =
      snapshot
      |> Map.update!(:captured_at_utc_ms, &(&1 + 1_000))
      |> update_in(
        [:learner, "aws_estimators", Access.at(0), "regimes", Access.at(upwind_index), "legs", Access.at(0), "t_end_s"],
        &(&1 + 2.0)
      )
      |> update_in(
        [:learner_time_basis, Access.at(0), :regimes, Access.at(0), :ages_s, Access.at(0)],
        &(&1 - 1.0)
      )

    target_clock = start_clock(50_000)
    {:ok, target_utc} = Agent.start_link(fn -> @capture_utc end)
    target = start_observer(target_clock, utc_now_fn: fn -> Agent.get(target_utc, & &1) end)
    assert :ok = Observer.restore(target, snapshot)
    assert {:ok, before_rejuvenation} = Observer.snapshot(target)

    Agent.update(target_utc, &DateTime.add(&1, 1, :second))
    assert {:error, :restore_conflict} = Observer.restore(target, rejuvenated)
    Agent.update(target_utc, fn _ -> @capture_utc end)
    assert {:ok, ^before_rejuvenation} = Observer.snapshot(target)
  end

  test "a higher learner sequence cannot rejuvenate unchanged AWS regime rows" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    [aws_estimator] = snapshot.learner["aws_estimators"]
    upwind_index = Enum.find_index(aws_estimator["regimes"], &(&1["name"] == "upwind"))

    rejuvenated =
      snapshot
      |> Map.update!(:captured_at_utc_ms, &(&1 + 1_000))
      |> update_in([:learner, "seq"], &(&1 + 1))
      |> update_in(
        [:learner, "aws_estimators", Access.at(0), "regimes", Access.at(upwind_index), "legs", Access.at(0), "t_end_s"],
        &(&1 + 2.0)
      )
      |> update_in(
        [:learner_time_basis, Access.at(0), :regimes, Access.at(0), :ages_s, Access.at(0)],
        &(&1 - 1.0)
      )

    target_clock = start_clock(50_000)
    {:ok, target_utc} = Agent.start_link(fn -> @capture_utc end)
    target = start_observer(target_clock, utc_now_fn: fn -> Agent.get(target_utc, & &1) end)
    assert :ok = Observer.restore(target, snapshot)
    assert {:ok, before_rejuvenation} = Observer.snapshot(target)

    Agent.update(target_utc, &DateTime.add(&1, 1, :second))
    assert {:error, :restore_conflict} = Observer.restore(target, rejuvenated)
    Agent.update(target_utc, fn _ -> @capture_utc end)
    assert {:ok, ^before_rejuvenation} = Observer.snapshot(target)
  end

  test "a higher learner sequence may prepend legitimate AWS rows and retain older rows" do
    source_clock = start_clock(10_000)
    {:ok, source_utc} = Agent.start_link(fn -> @capture_utc end)
    source = start_observer(source_clock, utc_now_fn: fn -> Agent.get(source_utc, & &1) end)
    :ok = seed_runtime(source)
    assert {:ok, first} = Observer.snapshot(source)

    set_now(source_clock, 11_000)
    Agent.update(source_utc, &DateTime.add(&1, 1, :second))

    :sys.replace_state(source, fn state ->
      estimator =
        state.aws_estimators[@wind_hex]
        |> AwsScale.observe_leg(%{t_end_s: 10.5, tws_mean: 6.5, awa_abs_mean: 30.0})

      %{state | aws_estimators: Map.put(state.aws_estimators, @wind_hex, estimator), seq: state.seq + 1}
    end)

    assert {:ok, advanced} = Observer.snapshot(source)

    target_clock = start_clock(50_000)
    {:ok, target_utc} = Agent.start_link(fn -> @capture_utc end)
    target = start_observer(target_clock, utc_now_fn: fn -> Agent.get(target_utc, & &1) end)
    assert :ok = Observer.restore(target, first)

    set_now(target_clock, 51_000)
    Agent.update(target_utc, &DateTime.add(&1, 1, :second))
    assert :ok = Observer.restore(target, advanced)

    [newest, retained] = :sys.get_state(target).aws_estimators[@wind_hex].regimes.upwind
    assert newest == {50.5, 6.5}
    assert retained == {48.0, 6.0}
  end

  test "physical channel overflow and hostile learner numerics fail closed" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    target_clock = start_clock(20_000)
    target = start_observer(target_clock)
    assert {:ok, before_restore} = Observer.snapshot(target)

    aws_index = Enum.find_index(snapshot.latest, &(&1.channel == :aws))
    impossible_speed = put_in(snapshot, [:latest, Access.at(aws_index), :value], 656.0)
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(target, impossible_speed)
    assert {:ok, ^before_restore} = Observer.snapshot(target)

    huge_integer = put_in(snapshot, [:learner, "seq"], 1_208_925_819_614_629_174_706_176)
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(target, huge_integer)
    assert {:ok, ^before_restore} = Observer.snapshot(target)

    max_float = put_in(snapshot, [:learner, "seq"], 1.7976931348623157e308)
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(target, max_float)
    assert {:ok, ^before_restore} = Observer.snapshot(target)
  end

  test "accepted restore is durably applied to target-local storage before reply" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    dir = tmp_dir()
    target_clock = start_clock(50_000)
    target = start_observer(target_clock, dir: dir)
    assert :ok = Observer.restore(target, snapshot)

    assert {:ok, persisted} = Store.load(dir)
    assert persisted.learner["seq"] == 3

    Process.unlink(target)
    ref = Process.monitor(target)
    Process.exit(target, :kill)
    assert_receive {:DOWN, ^ref, :process, ^target, :killed}

    restarted = start_observer(target_clock, dir: dir)
    assert :sys.get_state(restarted).seq == 3
  end

  test "target persistence failure does not partially reconcile Calibration.Config" do
    {:ok, calibration} = Config.start_link(name: nil, store_dir: nil)

    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    root = tmp_dir()
    File.mkdir_p!(root)
    blocked_dir = Path.join(root, "not-a-directory")
    File.write!(blocked_dir, "blocked")
    target_clock = start_clock(50_000)
    target = start_observer(target_clock, dir: blocked_dir, calibration: {Config, calibration})
    assert {:ok, before_restore} = Observer.snapshot(target)

    assert {:error, :persistence_failed} = Observer.restore(target, snapshot)
    assert {:ok, ^before_restore} = Observer.snapshot(target)
    assert Config.status(calibration).sensors == []
  end

  test "Config reconciliation failure leaves memory and local learner durability unchanged" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    dir = tmp_dir()
    target_clock = start_clock(50_000)

    target =
      start_observer(target_clock,
        dir: dir,
        calibration: {RejectingCalibration, :unused}
      )

    assert {:ok, before_restore} = Observer.snapshot(target)
    assert {:error, :config_reconciliation_failed} = Observer.restore(target, snapshot)
    assert {:ok, ^before_restore} = Observer.snapshot(target)
    assert :empty = Store.load(dir)
  end

  test "commit plus Config rollback failure stops the writer and leaves boot-healing evidence" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    dir = tmp_dir()
    File.mkdir_p!(dir)
    {:ok, calibration} = CommitAndRollbackFailingCalibration.start_link(dir)
    target_clock = start_clock(50_000)

    target =
      start_observer(target_clock,
        dir: dir,
        calibration: {CommitAndRollbackFailingCalibration, calibration}
      )

    :sys.replace_state(target, &%{&1 | dirty_persist: true})
    Process.unlink(target)
    ref = Process.monitor(target)

    assert {:error, :config_reconciliation_failed} = Observer.restore(target, snapshot)
    assert_receive {:DOWN, ^ref, :process, ^target, :config_reconciliation_failed}
    assert Store.pending?(dir)
    assert CommitAndRollbackFailingCalibration.entries(calibration) != []

    File.rm_rf!(Path.join(dir, "observer.calibration"))

    recovered =
      start_observer(target_clock,
        dir: dir,
        calibration: {CommitAndRollbackFailingCalibration, calibration}
      )

    refute Store.pending?(dir)
    assert Process.alive?(recovered)
    assert CommitAndRollbackFailingCalibration.entries(calibration) == []
  end

  test "boot discards an interrupted staged restore and heals Config back to active learner state" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)

    dir = tmp_dir()
    source_state = :sys.get_state(source)
    assert {:ok, pending} = Snapshot.project_persisted(source_state, 10_000, @capture_utc, nil)
    assert :ok = Store.stage(dir, pending)

    {:ok, calibration} = Config.start_link(name: nil, store_dir: nil)

    assert :ok =
             Config.reconcile_learned(calibration, [
               %{
                 hardware_identifier: @wind_hex,
                 parameter: "awa_offset",
                 entry: %{value: 9.0, confidence: 1.0, sample_count: 8, state: "applied"}
               }
             ])

    target_clock = start_clock(50_000)
    recovered = start_observer(target_clock, dir: dir, calibration: {Config, calibration})

    refute Store.pending?(dir)
    assert :sys.get_state(recovered).seq == 0
    assert Config.status(calibration).sensors == []
    assert :empty = Store.load(dir)
  end

  test "exact retry survives restart, a lower monotonic base, and powered-off elapsed time" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    {:ok, calibration} = Config.start_link(name: nil, store_dir: nil)
    dir = tmp_dir()
    first_clock = start_clock(50_000)
    first = start_observer(first_clock, dir: dir, calibration: {Config, calibration})
    assert :ok = Observer.restore(first, snapshot)
    :ok = GenServer.stop(first)
    assert :ok = Config.reconcile_learned(calibration, [])

    lower_clock = start_clock(1_000)
    one_hour_later = DateTime.add(@capture_utc, 3_600, :second)

    restarted =
      start_observer(lower_clock,
        dir: dir,
        utc_now_fn: fn -> one_hour_later end,
        calibration: {Config, calibration}
      )

    assert Observer.stats(restarted).samples == 0
    assert :ok = Observer.restore(restarted, snapshot)
    state = :sys.get_state(restarted)
    assert state.seq == 3
    assert state.stats == snapshot.stats
    assert state.legs.seg != nil
    assert state.window_sources == {@wind_hex, @speed_hex}
    assert Enum.any?(Config.status(calibration).sensors, &(&1.parameter == "awa_offset"))

    conflicting = put_in(snapshot, [:stats, :samples], snapshot.stats.samples + 1)
    assert {:error, :restore_conflict} = Observer.restore(restarted, conflicting)
    assert :sys.get_state(restarted).seq == 3
  end

  test "restore reconciles learned applied estimates into Calibration.Config" do
    {:ok, calibration} = Config.start_link(name: nil, store_dir: nil)

    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    target_clock = start_clock(50_000)
    target = start_observer(target_clock, calibration: {Config, calibration})
    assert :ok = Observer.restore(target, snapshot)

    assert %{sensors: sensors} = Config.status(calibration)

    assert Enum.any?(sensors, fn sensor ->
             sensor.hardware_identifier == @wind_hex and
               sensor.parameter == "awa_offset" and sensor.state == "applied" and
               sensor.value == 0.5
           end)
  end

  test "restore rebases and reschedules the remaining sampling phase" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock, sample_ms: 1_000)
    assert {:ok, snapshot} = Observer.snapshot(source)
    assert snapshot.tick == %{remaining_ms: 1_000}

    target_clock = start_clock(50_000)
    half_second_later = DateTime.add(@capture_utc, 500, :millisecond)

    target =
      start_observer(target_clock,
        sample_ms: 1_000,
        utc_now_fn: fn -> half_second_later end
      )

    assert :ok = Observer.restore(target, snapshot)
    state = :sys.get_state(target)
    assert state.next_tick_ms == 50_500
    assert is_reference(state.tick_timer_ref)
  end

  test "stale pre-restore timer messages cannot advance restored runtime" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)
    assert {:ok, snapshot} = Observer.snapshot(source)

    target_clock = start_clock(50_000)
    target = start_observer(target_clock)
    stale_token = :sys.get_state(target).tick_token
    assert :ok = Observer.restore(target, snapshot)
    restored_stats = Observer.stats(target)

    send(target, {:tick, stale_token})
    assert Observer.stats(target) == restored_stats
  end

  test "sync recovery carries only learner-derived pending keys and cannot suppress seq-zero delivery" do
    entry = %{
      hardware_identifier: @wind_hex,
      parameter: "awa_offset",
      value: 0.5,
      confidence: 1.0,
      sample_count: 8,
      state: "applied",
      residual: 0.0
    }

    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)

    :sys.replace_state(source, fn state ->
      %{state | seq: 0, synced: %{}, pending_sync: %{{@wind_hex, "awa_offset"} => entry}}
    end)

    assert {:ok, snapshot} = Observer.snapshot(source)
    assert Map.keys(snapshot.sync) |> Enum.sort() == [:last_sync_age_ms, :pending_keys]
    assert snapshot.sync.pending_keys == [%{hardware_identifier: @wind_hex, parameter: "awa_offset"}]

    forged = put_in(snapshot, [:sync, :synced], [])
    target_clock = start_clock(50_000)
    target = start_observer(target_clock)
    assert {:error, :invalid_runtime_snapshot} = Observer.restore(target, forged)

    me = self()
    sender = fn _channel, update -> send(me, {:restored_sync, update}) end
    delivery_target = start_observer(target_clock, sender: sender)
    assert :ok = Observer.restore(delivery_target, snapshot)
    assert :ok = Observer.sync_now(delivery_target)
    assert_receive {:restored_sync, %{seq: 1, entries: [^entry]}}
  end

  test "raw intake before hydration does not create a same-sequence learner conflict" do
    source_clock = start_clock(10_000)
    source = start_observer(source_clock)
    assert {:ok, snapshot} = Observer.snapshot(source)
    assert snapshot.learner["seq"] == 0

    target_clock = start_clock(10_000)
    target = start_observer(target_clock)
    send(target, {:data, raw_speed(10_000)})
    assert %{stw: {3.0, @speed_hex, 10_000}} = Observer.latest(target)

    assert :ok = Observer.restore(target, snapshot)
    assert Observer.latest(target) == %{}
  end

  test "wall-clock elapsed time expires raw values and prevents old/new tack pairing" do
    source_clock = start_clock(100_000)
    source = start_observer(source_clock)
    :ok = seed_runtime(source)

    :sys.replace_state(source, fn state ->
      {tack, []} = Tack.step(Tack.new(), long_leg())

      %{
        state
        | tack: tack,
          latest:
            Map.new(state.latest, fn {channel, {value, hex, _timestamp}} ->
              {channel, {value, hex, 99_500}}
            end)
      }
    end)

    assert {:ok, snapshot} = Observer.snapshot(source)

    target_clock = start_clock(200_000)
    two_hours_later = DateTime.add(@capture_utc, 7_200, :second)
    target = start_observer(target_clock, utc_now_fn: fn -> two_hours_later end)
    assert :ok = Observer.restore(target, snapshot)

    before_tick = Observer.stats(target)
    assert :ok = Observer.tick(target)
    after_tick = Observer.stats(target)
    assert after_tick.accepted == before_tick.accepted
    assert after_tick.rejected == before_tick.rejected + 1

    restored_tack = :sys.get_state(target).tack

    port_leg =
      long_leg(
        started_ms: 210_000,
        ended_ms: 290_000,
        side: :port,
        heading_mean: 40.0,
        cog_mean: 40.0,
        awa_mean_signed: -30.0
      )

    assert {%Tack{pending: ^port_leg}, []} = Tack.step(restored_tack, port_leg)
  end
end
