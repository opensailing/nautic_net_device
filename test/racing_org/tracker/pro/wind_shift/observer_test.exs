Code.require_file("support/wind_gen_helper.exs", __DIR__)

defmodule RacingOrg.Tracker.Pro.WindShift.ObserverTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WindShift.Checkpoint, as: WindCheckpoint
  alias RacingOrg.Tracker.Pro.WindShift.Config
  alias RacingOrg.Tracker.Pro.WindShift.Observer
  alias RacingOrg.Tracker.Pro.WindShift.Observer.Store
  alias RacingOrg.Tracker.Pro.WindShift.StepDetect
  alias RacingOrg.Tracker.Pro.WindShift.WindGen

  @utc_base ~U[2026-07-17 10:00:00.000Z]
  @wall_base DateTime.to_unix(@utc_base, :millisecond)

  # --- scripted-signal harness -------------------------------------------------
  #
  # A script agent holds the CURRENT sample; the injected signals_fn / now_fn /
  # utc_now_fn all read it, so a driven tick sees a coherent instant. A second
  # sink agent captures the Engine.put_signals batches (an agent, not the test
  # mailbox, so long streams don't flood messages). Syncs and B&G transmits go to
  # the test mailbox (they are rare).

  defp new_script do
    {:ok, script} =
      Agent.start_link(fn ->
        %{
          t_ms: 0,
          wall_offset_ms: 0,
          twd: nil,
          tws: nil,
          twa: nil,
          heading: nil,
          lat: nil,
          lon: nil,
          stale: false
        }
      end)

    {:ok, sink} = Agent.start_link(fn -> [] end)
    %{script: script, sink: sink}
  end

  defp observer_opts(%{script: script, sink: sink}, opts) do
    parent = self()
    staleness_ms = Keyword.get(opts, :staleness_ms, 3_000)

    signals_fn = fn ->
      s = Agent.get(script, & &1)
      mono = if s.stale, do: s.t_ms - staleness_ms - 1, else: s.t_ms

      [
        {"true_wind_direction", s.twd},
        {"true_wind_speed", s.tws},
        {"true_wind_angle", s.twa},
        {"heading", s.heading},
        {"latitude", s.lat},
        {"longitude", s.lon}
      ]
      |> Enum.reject(fn {_name, v} -> is_nil(v) end)
      |> Map.new(fn {name, v} -> {name, {v, mono}} end)
    end

    base = [
      name: nil,
      sample_ms: 0,
      dir: nil,
      config: nil,
      commands: nil,
      boat_identifier: "boat-test",
      broadcast_enabled: false,
      signals_fn: signals_fn,
      now_fn: fn -> Agent.get(script, & &1.t_ms) end,
      utc_now_fn: fn ->
        %{t_ms: t_ms, wall_offset_ms: wall_offset_ms} = Agent.get(script, & &1)
        DateTime.add(@utc_base, t_ms + wall_offset_ms, :millisecond)
      end,
      put_signals_fn: fn updates, mono -> Agent.update(sink, &[{updates, mono} | &1]) end,
      sender: fn _cc, update -> send(parent, {:sync, update}) end,
      transmit_fn: fn priority, pgn, payload -> send(parent, {:tx, priority, pgn, payload}) end
    ]

    Keyword.merge(base, opts)
  end

  defp start_observer(ctx, opts \\ []) do
    start_supervised!({Observer, observer_opts(ctx, opts)}, id: make_ref())
  end

  # Drive one WindGen sample (plus fixed extras like twa/lat/lon) through a tick.
  defp drive(observer, %{script: script}, samples, extra \\ %{}) do
    Enum.each(samples, fn sample ->
      Agent.update(script, fn s ->
        %{s | t_ms: sample.t_ms, twd: sample.twd_deg, tws: sample.tws_mps}
        |> Map.merge(extra)
      end)

      Observer.tick(observer)
    end)
  end

  defp last_batch(%{sink: sink}) do
    case Agent.get(sink, &List.first/1) do
      {updates, _mono} -> Map.new(updates)
      nil -> nil
    end
  end

  defp collect_syncs(acc \\ []) do
    receive do
      {:sync, update} -> collect_syncs([update | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp gen(script, opts \\ []), do: WindGen.generate(script, opts)

  # --- regime int codes (documented mapping) ------------------------------------

  test "regime_code/1 maps every regime to its documented integer code" do
    assert Observer.regime_code(:insufficient_history) == 0
    assert Observer.regime_code(:calm) == 1
    assert Observer.regime_code(:oscillating) == 2
    assert Observer.regime_code(:persistent_ramp) == 3
    assert Observer.regime_code(:persistent_step) == 4
    assert Observer.regime_code(:mixed) == 5
  end

  # --- engine signals -------------------------------------------------------------

  test "an oscillating stream publishes the full signal batch, oscillation events, and live status" do
    ctx = new_script()
    observer = start_observer(ctx)

    samples = gen([%{dur_s: 2400, base: 200.0, osc: {10.0, 480}}], noise_sigma: 1.5)
    drive(observer, ctx, samples, %{twa: 40.0, lat: 41.0, lon: -71.0})

    batch = last_batch(ctx)
    assert_in_delta batch["average_twd"], 200.0, 3.0
    assert batch["wind_regime"] == 2
    assert_in_delta batch["oscillation_period_s"], 480.0, 60.0
    assert_in_delta batch["oscillation_amplitude_deg"], 10.0, 3.0
    assert batch["shift_confidence"] >= 50.0
    assert is_number(batch["wind_phase_deg"])
    assert is_number(batch["wind_lift_deg"])
    assert is_number(batch["time_to_next_shift_s"])
    assert batch["time_to_next_shift_s"] <= 600.0
    # The +/-10 deg oscillation shows up as a TWD band of roughly 20 deg.
    assert batch["twd_range_deg"] >= 14.0
    assert is_number(batch["twd_trend_deg_per_hr"])

    # The live status carries the same fields for the channel composition.
    status = Observer.status(observer)
    assert status.regime == "oscillating"
    assert status.confidence >= 0.5
    assert_in_delta status.oscillation_period_s, 480.0, 60.0
    assert is_number(status.oscillation_amplitude_deg)
    assert is_number(status.trend_deg_per_hr)
    assert is_number(status.wind_phase_deg)
    assert is_number(status.wind_lift_deg)
    assert is_number(status.twd_range_deg)
    assert status.status == "ok"
    assert {:ok, _complete_runtime} = Observer.snapshot(observer)

    # Zero-crossing extrema flow as header/lift events once the oscillation is live.
    events = collect_syncs() |> Enum.flat_map(& &1.events)
    kinds = Enum.map(events, & &1.kind) |> MapSet.new()
    assert "header_extreme" in kinds
    assert "lift_extreme" in kinds

    # On starboard tack (+TWA), a VEERED extreme (positive phase) is the LIFT extreme.
    for %{kind: "lift_extreme", detail: %{phase_deg: phase}} <- events, do: assert(phase > 0.0)
    for %{kind: "header_extreme", detail: %{phase_deg: phase}} <- events, do: assert(phase < 0.0)
  end

  test "wind lift is tack-resolved: starboard veer = positive lift, port veer = negative" do
    # 5 min settled at 200, then a +12 deg veer for 60 s: phase_deg goes positive.
    samples = gen([%{dur_s: 300, base: 200.0}, %{dur_s: 60, step: 12.0}])

    # Starboard tack: signed TWA positive (wind over the starboard side) -> a veer is a LIFT.
    ctx = new_script()
    observer = start_observer(ctx)
    drive(observer, ctx, samples, %{twa: 40.0})
    starboard = last_batch(ctx)
    assert starboard["wind_phase_deg"] > 5.0
    assert starboard["wind_lift_deg"] > 5.0
    assert_in_delta starboard["wind_lift_deg"], starboard["wind_phase_deg"], 1.0e-9

    # Port tack: signed TWA negative -> the SAME veer is a HEADER (negative lift).
    ctx2 = new_script()
    observer2 = start_observer(ctx2)
    drive(observer2, ctx2, samples, %{twa: -40.0})
    port = last_batch(ctx2)
    assert port["wind_phase_deg"] > 5.0
    assert port["wind_lift_deg"] < -5.0
    assert_in_delta port["wind_lift_deg"], -port["wind_phase_deg"], 1.0e-9
  end

  test "without a live TWA the lift signal is simply omitted (phase still flows)" do
    ctx = new_script()
    observer = start_observer(ctx)
    drive(observer, ctx, gen([%{dur_s: 30, base: 200.0}]))

    batch = last_batch(ctx)
    assert is_number(batch["wind_phase_deg"])
    refute Map.has_key?(batch, "wind_lift_deg")
    assert Observer.status(observer).wind_lift_deg == nil
  end

  test "without a TWA signal the tack falls back to direction - heading (Library.resolve_twa parity)" do
    # 5 min settled at 200, then a +12 deg veer for 60 s: phase_deg goes positive.
    samples = gen([%{dur_s: 300, base: 200.0}, %{dur_s: 60, step: 12.0}])

    # No true_wind_angle published; heading 160 -> wrap180(TWD - heading) stays
    # positive (wind over the starboard side) -> the veer is a LIFT.
    ctx = new_script()
    observer = start_observer(ctx)
    drive(observer, ctx, samples, %{heading: 160.0})
    starboard = last_batch(ctx)
    assert starboard["wind_phase_deg"] > 5.0
    assert starboard["wind_lift_deg"] > 5.0
    assert_in_delta starboard["wind_lift_deg"], starboard["wind_phase_deg"], 1.0e-9
    assert is_number(Observer.status(observer).wind_lift_deg)

    # Heading 240 -> derived TWA negative (port tack) -> the SAME veer is a HEADER.
    ctx2 = new_script()
    observer2 = start_observer(ctx2)
    drive(observer2, ctx2, samples, %{heading: 240.0})
    port = last_batch(ctx2)
    assert port["wind_phase_deg"] > 5.0
    assert port["wind_lift_deg"] < -5.0
    assert_in_delta port["wind_lift_deg"], -port["wind_phase_deg"], 1.0e-9

    # A fresh true_wind_angle signal stays the canonical source: it wins over
    # the direction-heading derivation when both are available.
    ctx3 = new_script()
    observer3 = start_observer(ctx3)
    drive(observer3, ctx3, samples, %{twa: -40.0, heading: 160.0})
    canonical = last_batch(ctx3)
    assert canonical["wind_phase_deg"] > 5.0
    assert_in_delta canonical["wind_lift_deg"], -canonical["wind_phase_deg"], 1.0e-9
  end

  # --- timeline -------------------------------------------------------------------

  test "timeline rows accumulate on the 60 s cadence with the frozen row shape" do
    ctx = new_script()
    observer = start_observer(ctx)

    drive(observer, ctx, gen([%{dur_s: 300, base: 200.0}], noise_sigma: 1.0), %{twa: 40.0})

    rows = collect_syncs() |> Enum.flat_map(& &1.timeline)
    assert length(rows) >= 4

    for row <- rows do
      assert Map.keys(row) |> Enum.sort() ==
               [:amplitude_deg, :mean_twd_deg, :period_s, :phase_deg, :t_ms, :trend_deg_per_hr, :tws_mps]

      assert_in_delta row.mean_twd_deg, 200.0, 2.0
      assert is_number(row.phase_deg)
      assert_in_delta row.tws_mps, 6.0, 0.01
    end

    # Rows land once a minute (wall-clock stamped).
    gaps = rows |> Enum.map(& &1.t_ms) |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
    assert Enum.all?(gaps, &(&1 == 60_000))
    assert hd(rows).t_ms == @wall_base + 60_000
  end

  # --- events ----------------------------------------------------------------------

  test "a scripted +30 deg front raises new_high and a sized step event" do
    ctx = new_script()
    observer = start_observer(ctx)

    samples = gen([%{dur_s: 900, base: 200.0}, %{dur_s: 480, step: 30.0}], noise_sigma: 1.5)
    drive(observer, ctx, samples, %{twa: 40.0})

    events = collect_syncs() |> Enum.flat_map(& &1.events)

    assert %{twd_deg: twd, magnitude_deg: range} = Enum.find(events, &(&1.kind == "new_high"))
    assert twd > 220.0
    assert is_number(range)

    assert %{magnitude_deg: magnitude, detail: %{onset_t_ms: onset}} = Enum.find(events, &(&1.kind == "step"))
    assert_in_delta magnitude, 30.0, 5.0
    # Onset backdated to the scripted front (wall clock), within 30 s.
    assert_in_delta onset, @wall_base + 900_000, 30_000

    # The step is a regime override once history allows classification.
    assert Enum.any?(events, &(&1.kind == "regime_change" and &1.detail.to == "persistent_step"))
    assert last_batch(ctx)["wind_regime"] == 4
    assert Observer.status(observer).regime == "persistent_step"
  end

  test "clamps a derived step onset to the current session start" do
    ctx = new_script()

    observer =
      start_observer(ctx,
        sync_ms: 3_600_000_000,
        timeline_ms: 3_600_000_000
      )

    drive(observer, ctx, [%{t_ms: 0, twd_deg: 200.0, tws_mps: 6.0}])
    Agent.update(ctx.script, &%{&1 | t_ms: 1_000, twd: 230.0, tws: 6.0})

    :sys.replace_state(observer, fn state ->
      confirmed_step = %{
        state.step
        | status: :confirmed,
          dir: :up,
          onset_ms: -1_000,
          magnitude: 30.0
      }

      %{state | step: confirmed_step, prev_step_status: :candidate}
    end)

    Observer.tick(observer)

    assert %{detail: %{onset_t_ms: @wall_base}} =
             :sys.get_state(observer).pending_events
             |> Enum.find(&(&1.kind == "step"))
  end

  test "keeps current events before a delayed older oscillation extreme" do
    ctx = new_script()
    observer = start_observer(ctx)

    drive(observer, ctx, [%{t_ms: 0, twd_deg: 200.0, tws_mps: 6.0}], %{twa: 40.0})

    now = 1_200_000
    current_wall_ms = @wall_base + now
    delayed_wall_ms = current_wall_ms - 120_000
    to_rad = fn degrees -> :math.pi() * degrees / 180.0 end

    Agent.update(ctx.script, &%{&1 | t_ms: now, twd: 190.0, tws: 6.0, twa: 40.0})

    :sys.replace_state(observer, fn state ->
      means = %{
        state.means
        | fast: {to_rad.(190.0), now - 1_000},
          mid: {to_rad.(195.0), now - 1_000},
          slow: {to_rad.(200.0), now - 1_000},
          sin: {:math.sin(to_rad.(200.0)), now - 1_000},
          cos: {:math.cos(to_rad.(200.0)), now - 1_000}
      }

      %{
        state
        | means: means,
          cycle: %{state.cycle | x: [200.0, 0.0, 10.0, 0.0]},
          period: %{period_s: 480.0, confidence: 1.0},
          last_period_ms: now,
          t0_ms: 0,
          last_t_ms: now - 1_000,
          unwrap: {200.0, 200.0},
          prev_regime: :calm,
          xing: %{side: :pos, extreme: {8.0, 208.0, delayed_wall_ms}}
      }
    end)

    Observer.tick(observer)

    assert [%{events: events}] = collect_syncs()
    assert length(events) >= 2
    assert List.last(events).kind == "lift_extreme"
    assert List.last(events).t_ms == delayed_wall_ms

    events
    |> Enum.drop(-1)
    |> Enum.each(fn event -> assert event.t_ms == current_wall_ms end)
  end

  test "envelope alarm events are suppressed when alarms are disabled" do
    ctx = new_script()
    config = start_supervised!({Config, name: nil, store_dir: nil}, id: make_ref())
    {:ok, _} = Config.apply_config(config, %{"version" => 1, "alarms" => %{"enabled" => false}})
    observer = start_observer(ctx, config: {Config, config})

    samples = gen([%{dur_s: 400, base: 200.0}, %{dur_s: 120, step: 15.0}], noise_sigma: 1.0)
    drive(observer, ctx, samples)

    events = collect_syncs() |> Enum.flat_map(& &1.events)
    refute Enum.any?(events, &(&1.kind in ["new_high", "new_low"]))
  end

  # --- sync payload (frozen wire contract) ------------------------------------------

  test "the sync payload matches the frozen wind_shift_update contract after a Jason round-trip" do
    ctx = new_script()
    observer = start_observer(ctx)

    drive(observer, ctx, gen([%{dur_s: 70, base: 200.0}]), %{twa: 40.0, lat: 41.0, lon: -71.0})

    assert_receive {:sync, update}
    decoded = update |> Jason.encode!() |> Jason.decode!()

    assert Map.keys(decoded) |> Enum.sort() == ["boat_identifier", "events", "seq", "session", "timeline"]

    assert %{
             "boat_identifier" => "boat-test",
             "seq" => 1,
             "events" => [],
             "session" => session,
             "timeline" => [row]
           } = decoded

    assert Map.keys(session) |> Enum.sort() == ["centroid", "race_session_id", "started_at_ms", "summary"]
    assert %{"lat" => lat, "lon" => lon} = session["centroid"]
    assert_in_delta lat, 41.0, 1.0e-9
    assert_in_delta lon, -71.0, 1.0e-9
    assert session["race_session_id"] == nil
    assert session["started_at_ms"] == @wall_base

    summary = session["summary"]

    assert Map.keys(summary) |> Enum.sort() ==
             [
               "mean_twd_deg",
               "oscillation_amplitude_deg",
               "oscillation_period_s",
               "regime",
               "trend_deg_per_hr",
               "tws_mean_mps"
             ]

    assert_in_delta summary["mean_twd_deg"], 200.0, 1.0
    assert summary["regime"] == "insufficient_history"
    assert_in_delta summary["tws_mean_mps"], 6.0, 0.01

    assert Map.keys(row) |> Enum.sort() ==
             ["amplitude_deg", "mean_twd_deg", "period_s", "phase_deg", "t_ms", "trend_deg_per_hr", "tws_mps"]
  end

  test "race_session_id rides along from the active assignment at sync time" do
    defmodule FakeCommands do
      def current_assignment(_server), do: %{race_assignment: %{race_session_id: "rs-42"}}
    end

    ctx = new_script()
    observer = start_observer(ctx, commands: {FakeCommands, :ignored})

    drive(observer, ctx, gen([%{dur_s: 70, base: 200.0}]))

    assert_receive {:sync, %{session: %{race_session_id: "rs-42"}}}
    assert Observer.stats(observer).accepted == 70
  end

  # --- sync throttle / seq / skip -----------------------------------------------------

  test "sync throttles to the 60 s cadence with a monotonic seq" do
    ctx = new_script()
    observer = start_observer(ctx)

    drive(observer, ctx, gen([%{dur_s: 185, base: 200.0}], noise_sigma: 1.0))

    syncs = collect_syncs()
    assert length(syncs) == 3
    assert Enum.map(syncs, & &1.seq) == [1, 2, 3]
  end

  test "nothing new AND an unchanged summary -> no sync (empty-batch drop)" do
    ctx = new_script()
    observer = start_observer(ctx)

    flat = fn range -> for i <- range, do: %{t_ms: i * 1000, twd_deg: 200.0, tws_mps: 6.0} end

    # No valid wind at all: never a session, never a sync.
    drive(observer, ctx, flat.(0..130), %{stale: true})
    assert collect_syncs() == []

    # Constant, noise-free wind: one sync (it carries the first timeline row).
    drive(observer, ctx, flat.(131..185), %{stale: false})
    assert [%{seq: 1}] = collect_syncs()

    # The wind dies: the cores freeze, the summary stops changing, nothing is
    # pending -> no further updates go out.
    drive(observer, ctx, flat.(186..320), %{stale: true})
    assert collect_syncs() == []
  end

  # --- reject tallies -------------------------------------------------------------------

  test "missing and stale TWD ticks are tallied like Polar.Observer.stats" do
    ctx = new_script()
    observer = start_observer(ctx)

    # Missing entirely.
    Agent.update(ctx.script, &%{&1 | t_ms: 0, twd: nil})
    Observer.tick(observer)
    # Present but stale.
    Agent.update(ctx.script, &%{&1 | t_ms: 1000, twd: 200.0, tws: 6.0, stale: true})
    Observer.tick(observer)
    # Fresh.
    Agent.update(ctx.script, &%{&1 | t_ms: 2000, stale: false})
    Observer.tick(observer)

    assert %{samples: 3, accepted: 1, rejected: 2, reject_reasons: %{no_twd: 1, stale_twd: 1}} =
             Observer.stats(observer)
  end

  # --- session persistence (reboot continuity) ---------------------------------------------

  describe "persistence" do
    setup do
      dir = Path.join(System.tmp_dir!(), "wind_shift_observer_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "normalizes raw negative and 360-degree event directions before persistence", %{dir: dir} do
      ctx = new_script()

      {:ok, observer} =
        Observer.start_link(
          observer_opts(ctx,
            dir: dir,
            persist_ms: 3_600_000_000,
            sync_ms: 3_600_000_000,
            timeline_ms: 3_600_000_000
          )
        )

      :sys.replace_state(observer, &%{&1 | prev_regime: :calm})
      drive(observer, ctx, [%{t_ms: 0, twd_deg: -1.0, tws_mps: 6.0}])

      :sys.replace_state(observer, &%{&1 | prev_regime: :calm})
      drive(observer, ctx, [%{t_ms: 1_000, twd_deg: 360.0, tws_mps: 6.0}])

      :ok = Observer.persist_now(observer)
      assert {:ok, snapshot} = Store.load(dir)
      assert Enum.map(snapshot.pending_events, & &1.twd_deg) == [359.0, 0.0]
    end

    test "normalizes a rounded 360-degree summary after rounding and persists that canonical value", %{dir: dir} do
      ctx = new_script()

      {:ok, observer} =
        Observer.start_link(
          observer_opts(ctx,
            dir: dir,
            persist_ms: 3_600_000_000,
            sync_ms: 3_600_000_000,
            timeline_ms: 3_600_000_000
          )
        )

      drive(observer, ctx, [%{t_ms: 0, twd_deg: 359.999, tws_mps: 6.0}])
      :ok = Observer.sync_now(observer)

      assert_receive {:sync, %{session: %{summary: %{mean_twd_deg: mean_twd_deg}}}}
      assert mean_twd_deg == 0.0

      :ok = Observer.persist_now(observer)
      assert {:ok, snapshot} = Store.load(dir)
      assert snapshot.last_summary.mean_twd_deg == 0.0
    end

    test "treats invalid optional TWS and position samples as absent before persistence", %{dir: dir} do
      ctx = new_script()

      {:ok, observer} =
        Observer.start_link(
          observer_opts(ctx,
            dir: dir,
            persist_ms: 3_600_000_000,
            sync_ms: 3_600_000_000,
            timeline_ms: 0
          )
        )

      drive(observer, ctx, [%{t_ms: 0, twd_deg: 200.0, tws_mps: 6.0}], %{lat: 41.0, lon: -71.0})
      drive(observer, ctx, [%{t_ms: 1_000, twd_deg: 201.0, tws_mps: -1.0}], %{lat: 91.0, lon: -181.0})

      :ok = Observer.persist_now(observer)
      assert {:ok, snapshot} = Store.load(dir)

      assert snapshot.session == %{
               started_at_ms: @wall_base,
               lat_sum: 41.0,
               lon_sum: -71.0,
               pos_n: 1,
               tws_sum: 6.0,
               tws_n: 1
             }

      assert Enum.map(snapshot.pending_timeline, & &1.tws_mps) == [6.0, nil]
      assert {:ok, _content} = WindCheckpoint.project(snapshot)
      assert Observer.stats(observer).accepted == 2
    end

    test "a failed save keeps persistence dirty without advancing its cadence timestamp", %{dir: dir} do
      File.mkdir_p!(dir)
      blocked_dir = Path.join(dir, "not-a-directory")
      File.write!(blocked_dir, "blocks observer persistence")

      ctx = new_script()
      observer = start_observer(ctx, dir: blocked_dir, persist_ms: 60_000, sync_ms: 3_600_000)

      drive(observer, ctx, [%{t_ms: 60_000, twd_deg: 200.0, tws_mps: 6.0}])

      assert %{dirty_persist: true, last_persist_ms: 0} = :sys.get_state(observer)
    end

    test "session started_at_ms is stable across a simulated reboot and seq stays monotonic", %{dir: dir} do
      ctx = new_script()
      {:ok, observer} = Observer.start_link(observer_opts(ctx, dir: dir))

      drive(observer, ctx, gen([%{dur_s: 90, base: 200.0}]))
      assert_receive {:sync, %{seq: 1}}

      session = Observer.session(observer)
      assert session.started_at_ms == @wall_base
      # A clean stop runs the terminate flush (the "reboot").
      :ok = GenServer.stop(observer)

      # A fresh Observer on the same directory, later the same day.
      ctx2 = new_script()
      Agent.update(ctx2.script, &%{&1 | t_ms: 90_000})
      observer2 = start_observer(ctx2, dir: dir)

      assert Observer.session(observer2).started_at_ms == @wall_base

      drive(observer2, ctx2, for(i <- 90..155, do: %{t_ms: i * 1000, twd_deg: 200.0, tws_mps: 6.0}))
      assert_receive {:sync, %{seq: 2, session: %{started_at_ms: started}}}
      assert started == @wall_base
    end

    test "normalizes same-day legacy persisted directions without changing durable ordering or sequence", %{
      dir: dir
    } do
      legacy = %{
        session: %{
          started_at_ms: @wall_base,
          lat_sum: 41.0,
          lon_sum: -71.0,
          pos_n: 1,
          tws_sum: 6.0,
          tws_n: 1
        },
        seq: 9,
        pending_timeline: [
          %{
            t_ms: @wall_base + 10_000,
            mean_twd_deg: -1.0,
            phase_deg: -2.0,
            amplitude_deg: 4.0,
            period_s: 480.0,
            trend_deg_per_hr: 1.0,
            tws_mps: 6.0
          },
          %{
            t_ms: @wall_base + 20_000,
            mean_twd_deg: 360.0,
            phase_deg: 2.0,
            amplitude_deg: 4.0,
            period_s: 480.0,
            trend_deg_per_hr: 1.0,
            tws_mps: 6.0
          }
        ],
        pending_events: [
          %{
            t_ms: @wall_base + 20_000,
            kind: "new_high",
            twd_deg: -1.0,
            magnitude_deg: 2.0,
            detail: %{min_deg: -2.0, max_deg: 360.0}
          },
          %{
            t_ms: @wall_base + 10_000,
            kind: "lift_extreme",
            twd_deg: 360.0,
            magnitude_deg: 4.0,
            detail: %{phase_deg: -4.0}
          },
          %{
            t_ms: @wall_base + 30_000,
            kind: "new_low",
            twd_deg: 721.0,
            magnitude_deg: 2.0,
            detail: %{min_deg: 360.0, max_deg: -1.0}
          }
        ],
        last_summary: %{
          mean_twd_deg: 720.0,
          trend_deg_per_hr: 1.0,
          oscillation_period_s: 480.0,
          oscillation_amplitude_deg: 4.0,
          regime: "oscillating",
          tws_mean_mps: 6.0
        }
      }

      :ok = Store.save(dir, legacy)
      ctx = new_script()
      observer = start_observer(ctx, dir: dir)
      state = :sys.get_state(observer)

      assert state.session == legacy.session
      assert state.seq == 9

      assert state.pending_timeline == [
               %{Enum.at(legacy.pending_timeline, 0) | mean_twd_deg: 359.0},
               %{Enum.at(legacy.pending_timeline, 1) | mean_twd_deg: 0.0}
             ]

      assert state.pending_events == [
               %{
                 Enum.at(legacy.pending_events, 0)
                 | twd_deg: 359.0,
                   detail: %{min_deg: 358.0, max_deg: 0.0}
               },
               %{Enum.at(legacy.pending_events, 1) | twd_deg: 0.0},
               %{
                 Enum.at(legacy.pending_events, 2)
                 | twd_deg: 1.0,
                   detail: %{min_deg: 0.0, max_deg: 359.0}
               }
             ]

      assert state.last_summary == %{legacy.last_summary | mean_twd_deg: 0.0}

      assert {:ok, runtime} = Observer.snapshot(observer)
      assert Enum.map(runtime.pending_timeline, & &1.mean_twd_deg) == [359.0, 0.0]
      assert Enum.map(runtime.pending_events, & &1.twd_deg) == [359.0, 0.0, 1.0]
      assert runtime.last_summary.mean_twd_deg == 0.0

      :ok = Observer.persist_now(observer)
      assert {:ok, migrated} = Store.load(dir)
      assert migrated.seq == 9
      assert {:ok, _content} = WindCheckpoint.project(migrated)
    end

    test "a persisted session from a previous UTC day starts a fresh session (seq still monotonic)", %{dir: dir} do
      alias RacingOrg.Tracker.Pro.WindShift.Observer.Store

      yesterday = @wall_base - 24 * 60 * 60 * 1000

      :ok =
        Store.save(dir, %{
          session: %{started_at_ms: yesterday, lat_sum: 0.0, lon_sum: 0.0, pos_n: 0, tws_sum: 0.0, tws_n: 0},
          seq: 9,
          pending_timeline: [],
          pending_events: [],
          last_summary: nil
        })

      ctx = new_script()
      observer = start_observer(ctx, dir: dir)
      assert Observer.session(observer) == nil

      drive(observer, ctx, gen([%{dur_s: 70, base: 200.0}]))
      assert_receive {:sync, %{seq: 10, session: %{started_at_ms: started}}}
      assert started == @wall_base
    end
  end

  # --- UTC-day rollover (mid-run session rotation) ------------------------------------------

  test "a UTC-day rollover mid-run rotates the session: old one flushed, fresh accumulators, monotonic seq" do
    ctx = new_script()
    # Park the sync throttle out of the way so ONLY the rotation flush (throttle
    # bypassed) and the explicit sync_now emit updates.
    observer = start_observer(ctx, sync_ms: 3_600_000_000)

    drive(observer, ctx, gen([%{dur_s: 70, base: 200.0}]), %{lat: 41.0, lon: -71.0})
    assert Observer.session(observer).started_at_ms == @wall_base

    # @utc_base is 10:00Z, so +14 h crosses midnight into the NEXT UTC day.
    jump_ms = 14 * 60 * 60 * 1000
    next_day = for i <- 0..69, do: %{t_ms: jump_ms + i * 1000, twd_deg: 200.0, tws_mps: 6.0}
    drive(observer, ctx, next_day, %{lat: 42.0, lon: -72.0})

    # The rotation flushed the OLD session first (final sync under its identity,
    # carrying its pending timeline row).
    assert_receive {:sync, %{seq: 1, session: %{started_at_ms: @wall_base}} = flush}
    assert [%{t_ms: t_ms}] = flush.timeline
    assert t_ms == @wall_base + 60_000
    assert_in_delta flush.session.centroid.lat, 41.0, 1.0e-9

    # The NEW session starts at the first accepted tick past midnight with FRESH
    # accumulators (the centroid reflects only the new day's positions).
    session = Observer.session(observer)
    assert session.started_at_ms == @wall_base + jump_ms
    assert_in_delta session.centroid.lat, 42.0, 1.0e-9
    assert_in_delta session.centroid.lon, -72.0, 1.0e-9

    # seq continues strictly monotonically across the rotation, and the new
    # session's rows all belong to the new day.
    :ok = Observer.sync_now(observer)
    assert_receive {:sync, %{seq: 2, session: %{started_at_ms: started}} = update}
    assert started == @wall_base + jump_ms
    assert update.timeline != []
    assert Enum.all?(update.timeline, &(&1.t_ms >= started))
    refute_receive {:sync, _}, 20
  end

  test "a backward wall-clock correction to the previous UTC date rotates the session" do
    ctx = new_script()

    observer =
      start_observer(ctx,
        sync_ms: 3_600_000_000,
        timeline_ms: 3_600_000_000
      )

    drive(observer, ctx, [%{t_ms: 0, twd_deg: 200.0, tws_mps: 6.0}])

    corrected_started_at_ms = @wall_base - 24 * 60 * 60 * 1_000 - 1_000

    drive(
      observer,
      ctx,
      [%{t_ms: 1_000, twd_deg: 210.0, tws_mps: 7.0}],
      %{wall_offset_ms: -24 * 60 * 60 * 1_000 - 2_000}
    )

    assert_receive {:sync, %{seq: 1, session: %{started_at_ms: @wall_base}}}
    assert Observer.session(observer).started_at_ms == corrected_started_at_ms
  end

  test "a backward same-day wall-clock correction rotates the session and preserves projectable state" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "wind_shift_clock_rollback_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)
    ctx = new_script()

    {:ok, observer} =
      Observer.start_link(
        observer_opts(ctx,
          dir: dir,
          persist_ms: 3_600_000_000,
          sync_ms: 3_600_000_000,
          timeline_ms: 60_000
        )
      )

    drive(observer, ctx, gen([%{dur_s: 70, base: 200.0}]), %{
      lat: 41.0,
      lon: -71.0
    })

    old_extreme_ms = @wall_base + 30_000

    :sys.replace_state(observer, fn state ->
      candidate_step = %{
        state.step
        | status: :candidate,
          dir: :up,
          onset_ms: 60_000,
          magnitude: 12.0
      }

      %{
        state
        | step: candidate_step,
          prev_step_status: :candidate,
          xing: %{side: :pos, extreme: {5.0, 205.0, old_extreme_ms}}
      }
    end)

    correction_mono_ms = 70_000
    wall_offset_ms = -3_670_000
    corrected_started_at_ms = @wall_base - 3_600_000

    drive(
      observer,
      ctx,
      [%{t_ms: correction_mono_ms, twd_deg: 210.0, tws_mps: 7.0}],
      %{wall_offset_ms: wall_offset_ms, lat: 42.0, lon: -72.0}
    )

    assert_receive {:sync, %{seq: 1, session: %{started_at_ms: @wall_base}} = old_session}
    assert [%{t_ms: old_timeline_ms}] = old_session.timeline
    assert old_timeline_ms == @wall_base + 60_000

    state = :sys.get_state(observer)

    assert state.session == %{
             started_at_ms: corrected_started_at_ms,
             lat_sum: 42.0,
             lon_sum: -72.0,
             pos_n: 1,
             tws_sum: 7.0,
             tws_n: 1
           }

    assert StepDetect.snapshot(state.step).status == :none
    assert state.prev_step_status == :none
    refute state.xing.extreme == {5.0, 205.0, old_extreme_ms}

    if state.xing.extreme do
      assert elem(state.xing.extreme, 2) >= corrected_started_at_ms
    end

    :ok = Observer.sync_now(observer)

    assert_receive {:sync, %{seq: 2, session: %{started_at_ms: ^corrected_started_at_ms}}}

    :ok = Observer.persist_now(observer)
    assert {:ok, snapshot} = Store.load(dir)
    assert snapshot.seq == 2
    assert {:ok, _content} = WindCheckpoint.project(snapshot)
  end

  test "UTC rotation resets a step candidate before any new-session confirmation" do
    ctx = new_script()

    observer =
      start_observer(ctx,
        sync_ms: 3_600_000_000,
        timeline_ms: 3_600_000_000
      )

    drive(observer, ctx, gen([%{dur_s: 60, base: 200.0}]))

    pre_rotation_front =
      for i <- 60..64, do: %{t_ms: i * 1_000, twd_deg: 230.0, tws_mps: 6.0}

    drive(observer, ctx, pre_rotation_front)
    assert StepDetect.snapshot(:sys.get_state(observer).step).status == :candidate

    jump_ms = 14 * 60 * 60 * 1_000
    drive(observer, ctx, [%{t_ms: jump_ms, twd_deg: 230.0, tws_mps: 6.0}])

    assert [%{session: %{started_at_ms: @wall_base}}] = collect_syncs()

    state = :sys.get_state(observer)
    started_at_ms = @wall_base + jump_ms
    assert state.session.started_at_ms == started_at_ms
    assert StepDetect.snapshot(state.step).status == :none
    assert state.prev_step_status == :none

    refute Enum.any?(state.pending_events, fn
             %{kind: "step", detail: %{onset_t_ms: onset_t_ms}} -> onset_t_ms < started_at_ms
             _event -> false
           end)

    post_rotation_baseline =
      for i <- 1..30,
          do: %{t_ms: jump_ms + i * 1_000, twd_deg: 230.0, tws_mps: 6.0}

    post_rotation_front =
      for i <- 31..160,
          do: %{t_ms: jump_ms + i * 1_000, twd_deg: 260.0, tws_mps: 6.0}

    drive(observer, ctx, post_rotation_baseline ++ post_rotation_front)
    assert StepDetect.snapshot(:sys.get_state(observer).step).status == :confirmed

    :ok = Observer.sync_now(observer)
    assert [%{session: %{started_at_ms: ^started_at_ms}, events: events}] = collect_syncs()

    step_events = Enum.filter(events, &(&1.kind == "step"))
    assert step_events != []
    assert Enum.all?(step_events, &(&1.detail.onset_t_ms >= started_at_ms))
  end

  test "UTC rotation preserves a confirmed step without duplicate events or regime loss" do
    ctx = new_script()

    observer =
      start_observer(ctx,
        sync_ms: 3_600_000_000,
        timeline_ms: 3_600_000_000
      )

    drive(observer, ctx, [%{t_ms: 0, twd_deg: 200.0, tws_mps: 6.0}])

    now = 14 * 60 * 60 * 1_000
    started_at_ms = @wall_base + now
    to_rad = fn degrees -> :math.pi() * degrees / 180.0 end

    Agent.update(ctx.script, &%{&1 | t_ms: now, twd: 230.0, tws: 6.0})

    :sys.replace_state(observer, fn state ->
      means = %{
        state.means
        | fast: {to_rad.(230.0), now - 1_000},
          mid: {to_rad.(225.0), now - 1_000},
          slow: {to_rad.(200.0), now - 1_000},
          sin: {:math.sin(to_rad.(200.0)), now - 1_000},
          cos: {:math.cos(to_rad.(200.0)), now - 1_000}
      }

      confirmed_step = %{
        state.step
        | status: :confirmed,
          dir: :up,
          onset_ms: now - 120_000,
          magnitude: 30.0
      }

      %{
        state
        | means: means,
          cycle: %{state.cycle | x: [230.0, 0.0, 0.0, 0.0]},
          step: confirmed_step,
          last_period_ms: now,
          t0_ms: 0,
          last_t_ms: now - 1_000,
          unwrap: {230.0, 230.0},
          prev_step_status: :confirmed,
          prev_regime: :persistent_step,
          absorb_count: 17
      }
    end)

    Observer.tick(observer)
    assert [%{session: %{started_at_ms: @wall_base}}] = collect_syncs()

    state = :sys.get_state(observer)
    assert state.session.started_at_ms == started_at_ms
    assert StepDetect.snapshot(state.step).status == :confirmed
    assert state.prev_step_status == :confirmed
    assert state.pending_events == []

    post_rotation =
      for i <- 1..120,
          do: %{t_ms: now + i * 1_000, twd_deg: 230.0, tws_mps: 6.0}

    drive(observer, ctx, post_rotation)
    :ok = Observer.sync_now(observer)

    assert [%{session: %{started_at_ms: ^started_at_ms}, events: events}] = collect_syncs()
    refute Enum.any?(events, &(&1.kind in ["step", "regime_change"]))
    refute Enum.any?(events, &(&1.t_ms < started_at_ms))
  end

  test "UTC rotation clears a pre-session oscillation crossing extreme" do
    ctx = new_script()

    observer =
      start_observer(ctx,
        sync_ms: 3_600_000_000,
        timeline_ms: 3_600_000_000
      )

    drive(observer, ctx, [%{t_ms: 0, twd_deg: 200.0, tws_mps: 6.0}], %{twa: 40.0})

    now = 14 * 60 * 60 * 1_000
    started_at_ms = @wall_base + now
    old_extreme_ms = @wall_base + 60_000
    to_rad = fn degrees -> :math.pi() * degrees / 180.0 end

    Agent.update(ctx.script, &%{&1 | t_ms: now, twd: 190.0, tws: 6.0, twa: 40.0})

    :sys.replace_state(observer, fn state ->
      means = %{
        state.means
        | fast: {to_rad.(190.0), now - 1_000},
          mid: {to_rad.(195.0), now - 1_000},
          slow: {to_rad.(200.0), now - 1_000},
          sin: {:math.sin(to_rad.(200.0)), now - 1_000},
          cos: {:math.cos(to_rad.(200.0)), now - 1_000}
      }

      %{
        state
        | means: means,
          cycle: %{state.cycle | x: [200.0, 0.0, 10.0, 0.0]},
          period: %{period_s: 480.0, confidence: 1.0},
          last_period_ms: now,
          t0_ms: 0,
          last_t_ms: now - 1_000,
          unwrap: {200.0, 200.0},
          prev_regime: :oscillating,
          xing: %{side: :pos, extreme: {8.0, 208.0, old_extreme_ms}}
      }
    end)

    Observer.tick(observer)

    assert [%{session: %{started_at_ms: @wall_base}}] = collect_syncs()

    state = :sys.get_state(observer)
    assert state.session.started_at_ms == started_at_ms

    refute Enum.any?(state.pending_events, &(&1.t_ms < started_at_ms))
    assert %{side: :neg, extreme: {_phase_deg, _twd_deg, extreme_ms}} = state.xing
    assert extreme_ms >= started_at_ms
  end

  # --- authoritative runtime snapshot / restore -----------------------------------------

  describe "authoritative runtime snapshot / restore" do
    test "round-trips every learner field exactly across monotonic clock origins" do
      source_ctx = new_script()

      source =
        start_observer(source_ctx,
          sync_ms: 3_600_000_000,
          timeline_ms: 3_600_000_000,
          persist_ms: 3_600_000_000
        )

      samples =
        for i <- 0..9,
            do: %{t_ms: i * 1_000, twd_deg: 200.0 + i, tws_mps: 6.0}

      drive(source, source_ctx, samples, %{twa: 40.0, lat: 41.0, lon: -71.0})
      source_now = 9_000

      :sys.replace_state(source, fn state ->
        %{
          state
          | period: %{period_s: 480.0, confidence: 0.8},
            last_period_ms: source_now,
            step: StepDetect.put_period_hint(state.step, 480.0),
            prev_regime: :oscillating,
            xing: %{side: :pos, extreme: {5.0, 209.0, @wall_base + source_now}},
            last_verdict: oscillating_verdict()
        }
      end)

      assert {:ok, snapshot} = Observer.snapshot(source)

      assert Map.keys(snapshot) |> Enum.sort() ==
               [
                 :absorb_count,
                 :cycle,
                 :envelope,
                 :last_lift,
                 :last_period_age_ms,
                 :last_persist_age_ms,
                 :last_summary,
                 :last_sync_age_ms,
                 :last_t_age_ms,
                 :last_tack,
                 :last_timeline_age_ms,
                 :last_tx_age_ms,
                 :last_verdict,
                 :means,
                 :pending_events,
                 :pending_timeline,
                 :period,
                 :prev_regime,
                 :prev_step_status,
                 :residuals,
                 :seq,
                 :session,
                 :step,
                 :t0_age_ms,
                 :unwrap,
                 :xing
               ]

      store_snapshot =
        Map.take(snapshot, [:session, :seq, :pending_timeline, :pending_events, :last_summary])

      assert {:ok, _canonical_content} = WindCheckpoint.project(store_snapshot)

      assert Map.keys(snapshot.means) |> Enum.sort() ==
               [:cos, :fast, :mid, :sin, :slow, :tau_fast_s, :tau_mid_s, :tau_slow_s]

      assert Map.keys(snapshot.envelope) |> Enum.sort() ==
               [
                 :debounce_ms,
                 :first_age_ms,
                 :last_alarm_age_ms,
                 :last_input_deg,
                 :last_unwrapped,
                 :margin_deg,
                 :maxq,
                 :minq,
                 :new_extreme,
                 :warmup_ms,
                 :window_ms
               ]

      assert Map.keys(snapshot.cycle) |> Enum.sort() ==
               [
                 :cycle_var,
                 :innovation_tau_s,
                 :innovation_var,
                 :obs_var,
                 :omega,
                 :p,
                 :q_level_per_s,
                 :q_slope_per_s,
                 :rho_per_s,
                 :x
               ]

      assert Map.keys(snapshot.step) |> Enum.sort() ==
               [
                 :band_deg,
                 :cand_n,
                 :cand_sum,
                 :d,
                 :d_max,
                 :d_max_age_ms,
                 :d_max_t_ms,
                 :d_n,
                 :d_sum,
                 :delta_deg,
                 :dir,
                 :fast_confirm_deg,
                 :fast_confirm_s,
                 :magnitude,
                 :max_confirm_s,
                 :min_magnitude_deg,
                 :onset_age_ms,
                 :onset_t_ms,
                 :period_hint_s,
                 :settle_s,
                 :status,
                 :threshold_deg,
                 :u,
                 :u_min,
                 :u_min_age_ms,
                 :u_min_t_ms,
                 :u_n,
                 :u_sum
               ]

      assert_closed_runtime_value(snapshot)
      refute Map.has_key?(snapshot, :metadata)

      target_ctx = new_script()
      target_now = 50_000

      Agent.update(target_ctx.script, fn script ->
        %{script | t_ms: target_now, wall_offset_ms: source_now - target_now}
      end)

      target =
        start_observer(target_ctx,
          sync_ms: 3_600_000_000,
          timeline_ms: 3_600_000_000,
          persist_ms: 3_600_000_000
        )

      assert :ok = Observer.restore(target, snapshot)
      assert Observer.snapshot(target) == {:ok, snapshot}
      assert Observer.status(target) == Observer.status(source)

      next_twd = 211.0

      Agent.update(source_ctx.script, fn script ->
        %{script | t_ms: source_now + 1_000, twd: next_twd, tws: 6.0, twa: 40.0, lat: 41.0, lon: -71.0}
      end)

      Agent.update(target_ctx.script, fn script ->
        %{
          script
          | t_ms: target_now + 1_000,
            wall_offset_ms: source_now - target_now,
            twd: next_twd,
            tws: 6.0,
            twa: 40.0,
            lat: 41.0,
            lon: -71.0
        }
      end)

      assert :ok = Observer.tick(source)
      assert :ok = Observer.tick(target)
      assert Observer.snapshot(target) == Observer.snapshot(source)
      assert Observer.status(target) == Observer.status(source)
    end

    test "preserves the canonical partial order for a delayed older extreme event" do
      source_ctx = new_script()
      source = start_observer(source_ctx, sync_ms: 3_600_000_000, timeline_ms: 3_600_000_000)

      drive(
        source,
        source_ctx,
        [
          %{t_ms: 0, twd_deg: 200.0, tws_mps: 6.0},
          %{t_ms: 3_000, twd_deg: 205.0, tws_mps: 6.0}
        ],
        %{twa: 40.0}
      )

      newer_current = %{
        t_ms: @wall_base + 3_000,
        kind: "regime_change",
        twd_deg: 205.0,
        magnitude_deg: nil,
        detail: %{from: "calm", to: "oscillating", confidence: 0.8}
      }

      delayed_extreme = %{
        t_ms: @wall_base + 1_000,
        kind: "lift_extreme",
        twd_deg: 203.0,
        magnitude_deg: 4.0,
        detail: %{phase_deg: 4.0}
      }

      :sys.replace_state(source, &%{&1 | pending_events: [newer_current, delayed_extreme]})
      assert {:ok, authoritative} = Observer.snapshot(source)

      target_ctx = new_script()
      Agent.update(target_ctx.script, &%{&1 | t_ms: 3_000})
      target = start_observer(target_ctx, sync_ms: 3_600_000_000, timeline_ms: 3_600_000_000)

      assert :ok = Observer.restore(target, authoritative)
      assert :sys.get_state(target).pending_events == [newer_current, delayed_extreme]
    end

    test "continues timeline cadence across a different monotonic clock origin" do
      source_ctx = new_script()
      source = start_observer(source_ctx, timeline_ms: 10_000, sync_ms: 10_000)

      drive(source, source_ctx, [%{t_ms: 9_000, twd_deg: 200.0, tws_mps: 6.0}])
      assert {:ok, authoritative} = Observer.snapshot(source)

      target_ctx = new_script()
      Agent.update(target_ctx.script, &%{&1 | t_ms: 50_000, wall_offset_ms: -41_000})
      target = start_observer(target_ctx, timeline_ms: 10_000, sync_ms: 10_000)

      assert :ok = Observer.restore(target, authoritative)

      drive(source, source_ctx, [%{t_ms: 10_000, twd_deg: 201.0, tws_mps: 6.0}])
      drive(target, target_ctx, [%{t_ms: 51_000, twd_deg: 201.0, tws_mps: 6.0}], %{wall_offset_ms: -41_000})

      assert Observer.snapshot(target) == Observer.snapshot(source)
    end

    test "continues persistence and broadcast throttles across restore" do
      suffix = System.unique_integer([:positive])
      source_dir = Path.join(System.tmp_dir!(), "wind_shift_runtime_source_#{suffix}")
      target_dir = Path.join(System.tmp_dir!(), "wind_shift_runtime_target_#{suffix}")

      on_exit(fn ->
        File.rm_rf(source_dir)
        File.rm_rf(target_dir)
      end)

      parent = self()

      source_ctx = new_script()

      source =
        start_observer(source_ctx,
          dir: source_dir,
          persist_ms: 10_000,
          sync_ms: 3_600_000_000,
          timeline_ms: 3_600_000_000,
          broadcast_enabled: true,
          transmit_fn: fn _priority, _pgn, _payload -> send(parent, :source_tx) end
        )

      drive(source, source_ctx, [%{t_ms: 0, twd_deg: 200.0, tws_mps: 6.0}])
      assert_receive :source_tx
      assert_receive :source_tx
      refute_receive :source_tx
      Agent.update(source_ctx.script, &%{&1 | t_ms: 500})
      assert {:ok, authoritative} = Observer.snapshot(source)

      target_ctx = new_script()
      Agent.update(target_ctx.script, &%{&1 | t_ms: 50_000, wall_offset_ms: -49_500})

      target =
        start_observer(target_ctx,
          dir: target_dir,
          persist_ms: 10_000,
          sync_ms: 3_600_000_000,
          timeline_ms: 3_600_000_000,
          broadcast_enabled: true,
          transmit_fn: fn _priority, _pgn, _payload -> send(parent, :target_tx) end
        )

      assert :ok = Observer.restore(target, authoritative)

      drive(source, source_ctx, [%{t_ms: 501, twd_deg: 201.0, tws_mps: 6.0}])
      drive(target, target_ctx, [%{t_ms: 50_001, twd_deg: 201.0, tws_mps: 6.0}], %{wall_offset_ms: -49_500})
      refute_receive :source_tx
      refute_receive :target_tx

      drive(source, source_ctx, [%{t_ms: 10_000, twd_deg: 202.0, tws_mps: 6.0}])
      drive(target, target_ctx, [%{t_ms: 59_500, twd_deg: 202.0, tws_mps: 6.0}], %{wall_offset_ms: -49_500})
      assert_receive :source_tx
      assert_receive :target_tx
      assert {:ok, _persisted} = Store.load(target_dir)
      assert Observer.snapshot(target) == Observer.snapshot(source)
    end

    test "validates the complete snapshot before mutation and fails closed" do
      source_ctx = new_script()
      source = start_observer(source_ctx, sync_ms: 3_600_000_000, timeline_ms: 3_600_000_000)
      drive(source, source_ctx, for(i <- 0..3, do: %{t_ms: i * 1_000, twd_deg: 200.0 + i, tws_mps: 6.0}))
      assert {:ok, snapshot} = Observer.snapshot(source)

      target_ctx = new_script()
      Agent.update(target_ctx.script, &%{&1 | t_ms: 3_000})
      target = start_observer(target_ctx, sync_ms: 3_600_000_000, timeline_ms: 3_600_000_000)
      assert {:ok, before} = Observer.snapshot(target)

      invalid_learner =
        snapshot
        |> put_in([:seq], 999)
        |> put_in([:cycle, :p, Access.at(0), Access.at(0)], "not-a-number")

      invalid_crossing_date =
        put_in(
          snapshot,
          [:xing],
          %{side: :pos, extreme: %{phase_deg: 5.0, twd_deg: 203.0, t_ms: @wall_base + 24 * 60 * 60 * 1_000}}
        )

      future_crossing =
        put_in(
          snapshot,
          [:xing],
          %{side: :pos, extreme: %{phase_deg: 5.0, twd_deg: 203.0, t_ms: @wall_base + 60_000}}
        )

      invalid_crossing_sign =
        put_in(
          snapshot,
          [:xing],
          %{side: :pos, extreme: %{phase_deg: -5.0, twd_deg: 203.0, t_ms: @wall_base + 2_000}}
        )

      invalid_crossing_domain =
        put_in(
          snapshot,
          [:xing],
          %{side: :pos, extreme: %{phase_deg: 500.0, twd_deg: 203.0, t_ms: @wall_base + 2_000}}
        )

      invalid_step_transition =
        put_in(
          snapshot,
          [:step],
          %{
            snapshot.step
            | status: :confirmed,
              dir: :up,
              onset_age_ms: 1_000,
              onset_t_ms: @wall_base + 2_000,
              cand_sum: 20.0,
              cand_n: 1,
              magnitude: 20.0
          }
        )

      invalid_covariance =
        snapshot
        |> put_in([:cycle, :p, Access.at(0), Access.at(0)], 1.0)
        |> put_in([:cycle, :p, Access.at(1), Access.at(1)], 1.0)
        |> put_in([:cycle, :p, Access.at(0), Access.at(1)], 2.0)
        |> put_in([:cycle, :p, Access.at(1), Access.at(0)], 2.0)

      for invalid <- [
            nil,
            invalid_learner,
            invalid_crossing_date,
            future_crossing,
            invalid_crossing_sign,
            invalid_crossing_domain,
            invalid_step_transition,
            invalid_covariance,
            Map.put(snapshot, :metadata, %{arbitrary: true})
          ] do
        assert {:error, :invalid_wind_shift_runtime_snapshot} = Observer.restore(target, invalid)
        assert Observer.snapshot(target) == {:ok, before}
      end
    end

    test "does not install prior-day live state and preserves only the monotonic sequence" do
      source_ctx = new_script()
      source = start_observer(source_ctx, timeline_ms: 1, sync_ms: 3_600_000_000)

      drive(
        source,
        source_ctx,
        [
          %{t_ms: 0, twd_deg: 200.0, tws_mps: 6.0},
          %{t_ms: 1_000, twd_deg: 210.0, tws_mps: 6.0}
        ],
        %{wall_offset_ms: -86_400_000, twa: 40.0}
      )

      assert {:ok, authoritative} = Observer.snapshot(source)
      authoritative = %{authoritative | seq: 7}
      assert authoritative.session != nil
      assert authoritative.pending_timeline != []

      target_ctx = new_script()
      Agent.update(target_ctx.script, &%{&1 | t_ms: 1_000})
      target = start_observer(target_ctx, sync_ms: 3_600_000_000, timeline_ms: 3_600_000_000)

      assert :ok = Observer.restore(target, authoritative)
      assert {:ok, restored} = Observer.snapshot(target)
      assert restored.seq == 7
      assert restored.session == nil
      assert restored.pending_timeline == []
      assert restored.pending_events == []
      assert restored.last_summary == nil
      assert restored.means.fast == nil
      assert restored.last_verdict == nil
    end

    test "rejects runtime tunables that do not match the current wind policy" do
      source_ctx = new_script()
      source = start_observer(source_ctx, sync_ms: 3_600_000_000, timeline_ms: 3_600_000_000)
      drive(source, source_ctx, [%{t_ms: 0, twd_deg: 200.0, tws_mps: 6.0}])
      assert {:ok, authoritative} = Observer.snapshot(source)

      config = start_supervised!({Config, name: nil, store_dir: nil}, id: make_ref())
      {:ok, _} = Config.apply_config(config, %{"version" => 1, "windows" => %{"fast_s" => 10}})
      target_ctx = new_script()
      target = start_observer(target_ctx, config: {Config, config})
      assert {:ok, before} = Observer.snapshot(target)

      assert {:error, :invalid_wind_shift_runtime_snapshot} = Observer.restore(target, authoritative)
      assert Observer.snapshot(target) == {:ok, before}
    end

    test "reconciles a legacy split fingerprint and runtime across an immediate hard restart" do
      dir = Path.join(System.tmp_dir!(), "wind_shift_runtime_split_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      source_ctx = new_script()
      source = start_observer(source_ctx, sync_ms: 3_600_000_000, timeline_ms: 3_600_000_000)
      drive(source, source_ctx, for(i <- 0..3, do: %{t_ms: i * 1_000, twd_deg: 200.0 + i, tws_mps: 6.0}))
      assert {:ok, authoritative} = Observer.snapshot(source)

      fingerprint = :crypto.hash(:sha256, :erlang.term_to_binary(authoritative, [:deterministic]))

      assert :ok =
               Store.save(dir, %{
                 session: nil,
                 seq: 0,
                 pending_timeline: [],
                 pending_events: [],
                 last_summary: nil
               })

      File.write!(Path.join(dir, "observer.wind_shift.authoritative"), <<"WSAF", 1, fingerprint::binary>>)

      target_ctx = new_script()
      Agent.update(target_ctx.script, &%{&1 | t_ms: 30_000, wall_offset_ms: -27_000})

      {:ok, target} =
        Observer.start_link(
          observer_opts(target_ctx,
            dir: dir,
            sync_ms: 3_600_000_000,
            timeline_ms: 3_600_000_000
          )
        )

      refute Observer.snapshot(target) == {:ok, authoritative}
      assert :ok = Observer.restore(target, authoritative)
      assert Observer.snapshot(target) == {:ok, authoritative}

      captured_at_utc_ms = @wall_base + 3_000

      assert {:ok,
              %{
                authoritative_runtime: %{
                  captured_at_utc_ms: ^captured_at_utc_ms,
                  fingerprint: ^fingerprint,
                  snapshot: ^authoritative
                }
              }} = Store.load(dir)

      Process.unlink(target)
      ref = Process.monitor(target)
      Process.exit(target, :kill)
      assert_receive {:DOWN, ^ref, :process, ^target, :killed}

      Agent.update(source_ctx.script, &%{&1 | t_ms: 8_000})
      assert {:ok, expected_after_outage} = Observer.snapshot(source)

      restarted_ctx = new_script()
      Agent.update(restarted_ctx.script, &%{&1 | t_ms: 80_000, wall_offset_ms: -72_000})

      {:ok, restarted} =
        Observer.start_link(
          observer_opts(restarted_ctx,
            dir: dir,
            sync_ms: 3_600_000_000,
            timeline_ms: 3_600_000_000
          )
        )

      assert Observer.snapshot(restarted) == {:ok, expected_after_outage}

      Agent.update(restarted_ctx.script, &%{&1 | t_ms: 81_000, twd: 220.0, tws: 6.0})
      assert :ok = Observer.tick(restarted)
      assert {:ok, progressed} = Observer.snapshot(restarted)
      refute progressed == authoritative

      assert :ok = Observer.restore(restarted, authoritative)
      assert Observer.snapshot(restarted) == {:ok, progressed}
      GenServer.stop(restarted)
    end

    test "retains a fingerprint tombstone when reboot wall time precedes its durable capture" do
      dir = Path.join(System.tmp_dir!(), "wind_shift_runtime_clock_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      source_ctx = new_script()
      source = start_observer(source_ctx, sync_ms: 3_600_000_000, timeline_ms: 3_600_000_000)
      drive(source, source_ctx, for(i <- 0..3, do: %{t_ms: i * 1_000, twd_deg: 200.0 + i, tws_mps: 6.0}))
      Agent.update(source_ctx.script, &%{&1 | t_ms: 10_000})
      assert {:ok, authoritative} = Observer.snapshot(source)
      fingerprint = :crypto.hash(:sha256, :erlang.term_to_binary(authoritative, [:deterministic]))

      target_ctx = new_script()
      Agent.update(target_ctx.script, &%{&1 | t_ms: 30_000, wall_offset_ms: -20_000})

      {:ok, target} =
        Observer.start_link(
          observer_opts(target_ctx,
            dir: dir,
            sync_ms: 3_600_000_000,
            timeline_ms: 3_600_000_000
          )
        )

      assert :ok = Observer.restore(target, authoritative)
      Process.unlink(target)
      ref = Process.monitor(target)
      Process.exit(target, :kill)
      assert_receive {:DOWN, ^ref, :process, ^target, :killed}

      backward_ctx = new_script()
      Agent.update(backward_ctx.script, &%{&1 | t_ms: 80_000, wall_offset_ms: -75_000})

      {:ok, restarted} =
        Observer.start_link(
          observer_opts(backward_ctx,
            dir: dir,
            sync_ms: 3_600_000_000,
            timeline_ms: 3_600_000_000
          )
        )

      assert {:ok, before_redelivery} = Observer.snapshot(restarted)
      refute before_redelivery == authoritative
      assert :sys.get_state(restarted).last_authoritative_fingerprint == fingerprint
      assert :sys.get_state(restarted).restore_durability_pending

      assert :ok = Observer.restore(restarted, authoritative)
      assert Observer.snapshot(restarted) == {:ok, before_redelivery}
      refute :sys.get_state(restarted).restore_durability_pending
      GenServer.stop(restarted)

      corrected_ctx = new_script()
      Agent.update(corrected_ctx.script, &%{&1 | t_ms: 120_000, wall_offset_ms: -100_000})

      {:ok, corrected} =
        Observer.start_link(
          observer_opts(corrected_ctx,
            dir: dir,
            sync_ms: 3_600_000_000,
            timeline_ms: 3_600_000_000
          )
        )

      assert {:ok, before_corrected_redelivery} = Observer.snapshot(corrected)
      assert before_corrected_redelivery.means.fast == nil
      assert :ok = Observer.restore(corrected, authoritative)
      assert Observer.snapshot(corrected) == {:ok, before_corrected_redelivery}
      GenServer.stop(corrected)
    end

    test "does not acknowledge or install a restore that cannot reach the durable store" do
      source_ctx = new_script()
      source = start_observer(source_ctx, sync_ms: 3_600_000_000, timeline_ms: 3_600_000_000)
      drive(source, source_ctx, [%{t_ms: 0, twd_deg: 200.0, tws_mps: 6.0}])
      assert {:ok, authoritative} = Observer.snapshot(source)

      blocked_dir = Path.join(System.tmp_dir!(), "wind_shift_runtime_blocked_#{System.unique_integer([:positive])}")
      File.write!(blocked_dir, "not a directory")
      on_exit(fn -> File.rm(blocked_dir) end)

      target_ctx = new_script()
      target = start_observer(target_ctx, dir: blocked_dir)
      assert {:ok, before} = Observer.snapshot(target)

      assert {:error, {:persistence_failed, {:pre_rename, _reason}}} =
               Observer.restore(target, authoritative)

      assert Observer.snapshot(target) == {:ok, before}
    end

    test "retries a post-rename uncertain restore without rolling memory backward" do
      dir = Path.join(System.tmp_dir!(), "wind_shift_runtime_uncertain_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      source_ctx = new_script()
      source = start_observer(source_ctx, sync_ms: 3_600_000_000, timeline_ms: 3_600_000_000)
      drive(source, source_ctx, [%{t_ms: 0, twd_deg: 200.0, tws_mps: 6.0}])
      assert {:ok, authoritative} = Observer.snapshot(source)

      {:ok, inject_fault?} = Agent.start_link(fn -> true end)

      fault_injector = fn
        :renamed ->
          Agent.get_and_update(inject_fault?, fn
            true -> {{:error, :power_loss}, false}
            false -> {:ok, false}
          end)

        _stage ->
          :ok
      end

      target_ctx = new_script()

      target =
        start_observer(target_ctx,
          dir: dir,
          store_opts: [fault_injector: fault_injector]
        )

      assert {:error, {:persistence_failed, {:durability_uncertain, _reason}}} =
               Observer.restore(target, authoritative)

      assert Observer.snapshot(target) == {:ok, authoritative}
      assert :sys.get_state(target).restore_durability_pending

      assert :ok = Observer.restore(target, authoritative)
      refute :sys.get_state(target).restore_durability_pending
    end

    test "duplicate authoritative restore remains non-regressive across progress, core rebuild, and restart" do
      dir = Path.join(System.tmp_dir!(), "wind_shift_runtime_head_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      source_ctx = new_script()
      source = start_observer(source_ctx, sync_ms: 3_600_000_000, timeline_ms: 3_600_000_000)
      drive(source, source_ctx, for(i <- 0..3, do: %{t_ms: i * 1_000, twd_deg: 200.0 + i, tws_mps: 6.0}))
      assert {:ok, authoritative} = Observer.snapshot(source)

      config = start_supervised!({Config, name: nil, store_dir: nil}, id: make_ref())
      target_ctx = new_script()
      Agent.update(target_ctx.script, &%{&1 | t_ms: 3_000})

      {:ok, target} =
        Observer.start_link(
          observer_opts(target_ctx,
            dir: dir,
            config: {Config, config},
            sync_ms: 3_600_000_000,
            timeline_ms: 3_600_000_000
          )
        )

      assert :ok = Observer.restore(target, authoritative)

      Agent.update(target_ctx.script, &%{&1 | t_ms: 4_000, twd: 220.0, tws: 6.0})
      assert :ok = Observer.tick(target)
      assert {:ok, progressed} = Observer.snapshot(target)
      refute progressed == authoritative

      assert :ok = Observer.restore(target, authoritative)
      assert Observer.snapshot(target) == {:ok, progressed}

      {:ok, _} = Config.apply_config(config, %{"version" => 1, "windows" => %{"fast_s" => 10}})
      assert {:ok, rebuilt} = Observer.snapshot(target)
      assert rebuilt.means.fast == nil
      assert :ok = Observer.restore(target, authoritative)
      assert Observer.snapshot(target) == {:ok, rebuilt}

      GenServer.stop(target)

      {:ok, restarted} =
        Observer.start_link(
          observer_opts(target_ctx,
            dir: dir,
            config: {Config, config},
            sync_ms: 3_600_000_000,
            timeline_ms: 3_600_000_000
          )
        )

      assert {:ok, before_duplicate} = Observer.snapshot(restarted)
      assert :ok = Observer.restore(restarted, authoritative)
      assert Observer.snapshot(restarted) == {:ok, before_duplicate}
      GenServer.stop(restarted)
    end

    test "preserves the historical UTC onset when a restored candidate confirms later" do
      source_ctx = new_script()
      source = start_observer(source_ctx, sync_ms: 3_600_000_000, timeline_ms: 3_600_000_000)
      drive(source, source_ctx, [%{t_ms: 0, twd_deg: 200.0, tws_mps: 6.0}])
      Agent.update(source_ctx.script, &%{&1 | t_ms: 100_000})
      onset_t_ms = @wall_base

      :sys.replace_state(source, fn state ->
        candidate = %{
          state.step
          | status: :candidate,
            dir: :up,
            onset_ms: 0,
            cand_sum: 30.0,
            cand_n: 1
        }

        %{
          state
          | step: candidate,
            step_clock: %{state.step_clock | onset_t_ms: onset_t_ms},
            prev_step_status: :candidate
        }
      end)

      assert {:ok, authoritative} = Observer.snapshot(source)

      target_ctx = new_script()
      Agent.update(target_ctx.script, &%{&1 | t_ms: 500_000, wall_offset_ms: 100_000})
      target = start_observer(target_ctx, sync_ms: 3_600_000_000, timeline_ms: 3_600_000_000)
      assert :ok = Observer.restore(target, authoritative)

      drive(
        target,
        target_ctx,
        [%{t_ms: 501_000, twd_deg: 240.0, tws_mps: 6.0}],
        %{wall_offset_ms: 100_000}
      )

      assert Enum.any?(:sys.get_state(target).pending_events, fn
               %{kind: "step", detail: %{onset_t_ms: ^onset_t_ms}} -> true
               _event -> false
             end)
    end

    test "preserves confirmed-step learning and resets the restored crossing on wall-clock rotation" do
      source_ctx = new_script()
      source = start_observer(source_ctx, sync_ms: 3_600_000_000, timeline_ms: 3_600_000_000)
      drive(source, source_ctx, for(i <- 0..2, do: %{t_ms: i * 1_000, twd_deg: 200.0, tws_mps: 6.0}), %{twa: 40.0})

      old_extreme_ms = @wall_base + 1_000

      :sys.replace_state(source, fn state ->
        confirmed_step = %{
          state.step
          | status: :confirmed,
            dir: :up,
            onset_ms: 1_000,
            cand_sum: 30.0,
            cand_n: 1,
            magnitude: 30.0
        }

        %{
          state
          | step: confirmed_step,
            step_clock: %{state.step_clock | onset_t_ms: @wall_base + 1_000},
            prev_step_status: :confirmed,
            absorb_count: 17,
            xing: %{side: :pos, extreme: {8.0, 208.0, old_extreme_ms}}
        }
      end)

      assert {:ok, authoritative} = Observer.snapshot(source)

      target_ctx = new_script()
      Agent.update(target_ctx.script, &%{&1 | t_ms: 2_000})
      target = start_observer(target_ctx, sync_ms: 3_600_000_000, timeline_ms: 3_600_000_000)
      assert :ok = Observer.restore(target, authoritative)

      restored = :sys.get_state(target)
      assert StepDetect.snapshot(restored.step).status == :confirmed
      assert restored.prev_step_status == :confirmed
      assert restored.absorb_count == 17
      assert restored.xing == %{side: :pos, extreme: {8.0, 208.0, old_extreme_ms}}

      Agent.update(target_ctx.script, fn script ->
        %{
          script
          | t_ms: 3_000,
            wall_offset_ms: -24 * 60 * 60 * 1_000 - 4_000,
            twd: 230.0,
            tws: 6.0,
            twa: 40.0
        }
      end)

      assert :ok = Observer.tick(target)
      rotated = :sys.get_state(target)
      assert StepDetect.snapshot(rotated.step).status == :confirmed
      assert rotated.prev_step_status == :confirmed
      refute rotated.xing.extreme == {8.0, 208.0, old_extreme_ms}

      if rotated.xing.extreme do
        assert elem(rotated.xing.extreme, 2) >= rotated.session.started_at_ms
      end
    end
  end

  # --- wally mode signal -----------------------------------------------------------------

  test "wally_mode from the config policy publishes as an int signal each tick" do
    ctx = new_script()
    config = start_supervised!({Config, name: nil, store_dir: nil}, id: make_ref())
    {:ok, _} = Config.apply_config(config, %{"version" => 1, "wally" => %{"mode" => "shadow"}})
    observer = start_observer(ctx, config: {Config, config})

    drive(observer, ctx, gen([%{dur_s: 5, base: 200.0}]))
    assert last_batch(ctx)["wally_mode"] == 1
    assert Observer.stats(observer).accepted == 5
  end

  test "with no config collaborator wally_mode publishes as 0 (off)" do
    ctx = new_script()
    observer = start_observer(ctx)

    drive(observer, ctx, gen([%{dur_s: 5, base: 200.0}]))
    assert last_batch(ctx)["wally_mode"] == 0
  end

  test "a wally-mode-only config change does NOT rebuild the cores (mode flips are glitch-free)" do
    ctx = new_script()
    config = start_supervised!({Config, name: nil, store_dir: nil}, id: make_ref())
    {:ok, _} = Config.apply_config(config, %{"version" => 1, "wally" => %{"mode" => "shadow"}})
    observer = start_observer(ctx, config: {Config, config})

    drive(observer, ctx, gen([%{dur_s: 120, base: 200.0}], noise_sigma: 1.0))
    assert is_number(Observer.status(observer).twd_range_deg)
    assert last_batch(ctx)["wally_mode"] == 1

    # Mode-only flip: the signal follows on the next tick; the envelope (a core)
    # survives — unlike a window change, which rebuilds and empties it.
    {:ok, _} = Config.apply_config(config, %{"version" => 2, "wally" => %{"mode" => "on"}})
    drive(observer, ctx, [%{t_ms: 120_000, twd_deg: 200.0, tws_mps: 6.0}])
    assert last_batch(ctx)["wally_mode"] == 2
    assert is_number(Observer.status(observer).twd_range_deg)
  end

  # --- config reaction -------------------------------------------------------------------

  test "an alarms-enabled-only config change does NOT rebuild the cores (a live-only flag)" do
    ctx = new_script()
    config = start_supervised!({Config, name: nil, store_dir: nil}, id: make_ref())
    observer = start_observer(ctx, config: {Config, config})

    samples = gen([%{dur_s: 900, base: 200.0}, %{dur_s: 480, step: 30.0}], noise_sigma: 1.5)
    {warmup, front} = Enum.split(samples, 900)

    drive(observer, ctx, warmup, %{twa: 40.0})
    status_before = Observer.status(observer)
    assert is_number(status_before.twd_range_deg)

    # Flip ONLY alarms.enabled mid-run: the cores retain their state (the
    # envelope stays warm, the regime is unchanged on the next tick).
    {:ok, _} = Config.apply_config(config, %{"version" => 1, "alarms" => %{"enabled" => false}})
    assert is_number(Observer.status(observer).twd_range_deg)

    drive(observer, ctx, Enum.take(front, 1), %{twa: 40.0})
    status_after = Observer.status(observer)
    assert is_number(status_after.twd_range_deg)
    assert status_after.regime == status_before.regime

    # Event suppression honors the new flag: the +30 deg front breaks out of the
    # (warm) envelope, but no new_high/new_low is emitted while disabled...
    drive(observer, ctx, Enum.drop(front, 1), %{twa: 40.0})
    flip_wall_ms = @wall_base + 900_000
    events = collect_syncs() |> Enum.flat_map(& &1.events)
    refute Enum.any?(events, &(&1.kind in ["new_high", "new_low"] and &1.t_ms >= flip_wall_ms))

    # ...and the warmup was preserved: 900 s + 480 s of history classify the
    # front as a persistent step (a rebuild at the flip would still be warming up).
    assert Observer.status(observer).regime == "persistent_step"

    # A margin change still rebuilds (the envelope empties again).
    {:ok, _} =
      Config.apply_config(config, %{"version" => 2, "alarms" => %{"new_extreme_margin_deg" => 5.0}})

    assert Observer.status(observer).twd_range_deg == nil
  end

  test "a config change rebuilds the cores (warmup resets) but preserves the session" do
    ctx = new_script()
    config = start_supervised!({Config, name: nil, store_dir: nil}, id: make_ref())
    observer = start_observer(ctx, config: {Config, config})

    drive(observer, ctx, gen([%{dur_s: 120, base: 200.0}], noise_sigma: 1.0))
    assert is_number(Observer.status(observer).twd_range_deg)
    session_before = Observer.session(observer)

    {:ok, _} = Config.apply_config(config, %{"version" => 1, "windows" => %{"fast_s" => 10}})

    # Cores were rebuilt (the envelope is empty again); the session carried over.
    assert Observer.status(observer).twd_range_deg == nil
    assert Observer.session(observer).started_at_ms == session_before.started_at_ms
  end

  # --- B&G broadcast ------------------------------------------------------------------------

  test "broadcasts keys 336/337/338 at 1 Hz with exact bytes, only when values are valid" do
    ctx = new_script()
    observer = start_observer(ctx, broadcast_enabled: true)

    # First tick: fast == slow == 200 -> phase 0, lift 0 (starboard tack).
    Agent.update(ctx.script, &%{&1 | t_ms: 0, twd: 200.0, tws: 6.0, twa: 40.0})
    Observer.tick(observer)

    # 200 deg -> 3.4906585 rad -> 34907 = 0x885B -> LE 5B 88.
    assert_receive {:tx, 2, 130_824, <<0x7D, 0x99, 0x50, 0x21, 0x5B, 0x88>>}
    assert_receive {:tx, 2, 130_824, <<0x7D, 0x99, 0x51, 0x21, 0x00, 0x00>>}
    assert_receive {:tx, 2, 130_824, <<0x7D, 0x99, 0x52, 0x21, 0x00, 0x00>>}

    # A second tick at the SAME instant is rate-limited: nothing more goes out.
    Observer.tick(observer)
    refute_receive {:tx, _, _, _}, 20

    # One second later the trio goes out again.
    Agent.update(ctx.script, &%{&1 | t_ms: 1000})
    Observer.tick(observer)
    assert_receive {:tx, 2, 130_824, <<0x7D, 0x99, 0x50, 0x21, _, _>>}
    assert_receive {:tx, 2, 130_824, <<0x7D, 0x99, 0x51, 0x21, _, _>>}
    assert_receive {:tx, 2, 130_824, <<0x7D, 0x99, 0x52, 0x21, _, _>>}
  end

  test "without TWA only the two tack-independent keys broadcast (no lift frame)" do
    ctx = new_script()
    observer = start_observer(ctx, broadcast_enabled: true)

    Agent.update(ctx.script, &%{&1 | t_ms: 0, twd: 200.0, tws: 6.0, twa: nil})
    Observer.tick(observer)

    assert_receive {:tx, 2, 130_824, <<0x7D, 0x99, 0x50, 0x21, _, _>>}
    assert_receive {:tx, 2, 130_824, <<0x7D, 0x99, 0x51, 0x21, _, _>>}
    refute_receive {:tx, _, _, <<0x7D, 0x99, 0x52, _, _, _>>}, 20
  end

  defp oscillating_verdict do
    %{
      regime: :oscillating,
      confidence: 0.8,
      oscillation: %{
        period_s: 480.0,
        amplitude_deg: 8.0,
        phase_rad: 0.5,
        time_to_next_header_s: %{starboard: 120.0, port: 360.0},
        phase_frac_to_next_header: %{starboard: 0.25, port: 0.75}
      },
      trend_deg_per_hr: 1.5,
      time_to_next_shift_s: 60.0,
      ci_s: 48.0,
      treat_as_persistent: false,
      regime_alarm: false,
      phase_deg: 5.0
    }
  end

  defp assert_closed_runtime_value(value) when is_map(value) do
    assert Enum.all?(Map.keys(value), &is_atom/1)
    Enum.each(Map.values(value), &assert_closed_runtime_value/1)
  end

  defp assert_closed_runtime_value(value) when is_list(value),
    do: Enum.each(value, &assert_closed_runtime_value/1)

  defp assert_closed_runtime_value(value)
       when is_atom(value) or is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_nil(value),
       do: :ok
end
