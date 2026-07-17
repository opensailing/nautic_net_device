Code.require_file("support/wind_gen_helper.exs", __DIR__)

defmodule RacingOrg.Tracker.Pro.WindShift.ObserverTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WindShift.Config
  alias RacingOrg.Tracker.Pro.WindShift.Observer
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
      Agent.start_link(fn -> %{t_ms: 0, twd: nil, tws: nil, twa: nil, lat: nil, lon: nil, stale: false} end)

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
      utc_now_fn: fn -> DateTime.add(@utc_base, Agent.get(script, & &1.t_ms), :millisecond) end,
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

  # --- config reaction -------------------------------------------------------------------

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
end
