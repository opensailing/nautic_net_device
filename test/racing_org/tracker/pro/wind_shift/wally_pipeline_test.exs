Code.require_file("support/wind_gen_helper.exs", __DIR__)

defmodule RacingOrg.Tracker.Pro.WindShift.WallyPipelineTest do
  @moduledoc """
  End-to-end WALLY: WindShift.Observer (scripted 1 Hz TWD stream) publishes the
  wind-shift signal batch — including `wally_mode` from the WindShift.Config
  policy — into a real Compute.Engine with a polar applied; the engine's
  `target_twa` / `target_boat_speed` library defs then modulate (or shadow, or
  pass through) per the Wally gates.

  The stack is fully scripted: a shared clock agent drives the Observer tick,
  the engine's staleness clock, and the signal timestamps, so every tick sees
  one coherent instant. The Observer reads `Engine.signals/1` and publishes via
  `Engine.put_signals/3` — the exact production wiring, minus telemetry attach.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Compute.Engine
  alias RacingOrg.Tracker.Pro.Polar
  alias RacingOrg.Tracker.Pro.Polar.Lookup
  alias RacingOrg.Tracker.Pro.WindShift.Config
  alias RacingOrg.Tracker.Pro.WindShift.Observer
  alias RacingOrg.Tracker.Pro.WindShift.Wally
  alias RacingOrg.Tracker.Pro.WindShift.WindGen

  @utc_base ~U[2026-07-17 10:00:00.000Z]
  @rad_per_deg :math.pi() / 180.0

  # The single-TWS fixture: beat optimum twa=45 exactly, bsp = 4/cos(45) exactly
  # (Lookup recovers bsp as abs(vmg/cos(twa)), the same float expression).
  @base_beat_twa 45.0
  @base_beat_bsp abs(4.0 / :math.cos(45.0 * @rad_per_deg))

  defmodule StubCommands do
    use Agent

    def start_link(opts), do: Agent.start_link(fn -> %{lookup: opts[:lookup]} end)
    def current_polar_lookup(agent), do: Agent.get(agent, & &1.lookup)
    def current_polar_version(_agent), do: 1
    def subscribe(_agent, _pid), do: :ok
  end

  defp polar do
    %Polar{
      polar_id: "t",
      version: 1,
      rows: [
        %{
          tws_mps: 10.0,
          cells: [
            %{twa_deg: 45.0, boat_speed_mps: 5.65685},
            %{twa_deg: 60.0, boat_speed_mps: 6.0},
            %{twa_deg: 90.0, boat_speed_mps: 7.0},
            %{twa_deg: 120.0, boat_speed_mps: 6.5},
            %{twa_deg: 150.0, boat_speed_mps: 5.7735},
            %{twa_deg: 180.0, boat_speed_mps: 4.0}
          ]
        }
      ],
      optima: [%{tws_mps: 10.0, beat_twa: 45.0, beat_vmg: 4.0, run_twa: 150.0, run_vmg: 5.0}]
    }
  end

  defp lookup do
    {:ok, lk} = Lookup.build(polar())
    lk
  end

  # Library defs listing the wind-shift signals as OPTIONAL inputs (the Wave-4
  # backend def provisioning ships this same signal list).
  @wally_inputs ~w(wally_mode wind_lift_deg wind_regime shift_confidence)

  defp library_value(id, key) do
    %{
      "id" => id,
      "name" => id,
      "definition_type" => "library",
      "library_key" => key,
      "signals" => ["true_wind_angle", "true_wind_speed" | @wally_inputs]
    }
  end

  defp start_stack(wally_mode) do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    now_fn = fn -> Agent.get(clock, & &1) end

    {:ok, cmds} = StubCommands.start_link(lookup: lookup())

    engine =
      start_supervised!(
        {Engine, name: nil, store_dir: nil, commands: {StubCommands, cmds}, attach_telemetry?: false, now_fn: now_fn},
        id: make_ref()
      )

    defs = [library_value("ttwa", "target_twa"), library_value("tbs", "target_boat_speed")]
    {:ok, _} = Engine.apply_config(engine, %{"version" => 0, "values" => defs})

    config = start_supervised!({Config, name: nil, store_dir: nil}, id: make_ref())
    {:ok, _} = Config.apply_config(config, %{"version" => 1, "wally" => %{"mode" => wally_mode}})

    observer =
      start_supervised!(
        {Observer,
         name: nil,
         sample_ms: 0,
         dir: nil,
         commands: nil,
         boat_identifier: "boat-test",
         broadcast_enabled: false,
         config: {Config, config},
         signals_fn: fn -> Engine.signals(engine) end,
         put_signals_fn: fn batch, mono -> Engine.put_signals(engine, batch, mono) end,
         now_fn: now_fn,
         utc_now_fn: fn -> DateTime.add(@utc_base, Agent.get(clock, & &1), :millisecond) end,
         sender: fn _cc, _update -> :ok end,
         transmit_fn: fn _priority, _pgn, _payload -> :ok end},
        id: make_ref()
      )

    %{engine: engine, observer: observer, config: config, clock: clock}
  end

  # One production-shaped tick per sample: raw wind signals land in the engine,
  # then the Observer samples the engine and publishes its batch back. The
  # interposed Engine.signals call serializes the raw-signal fold before the
  # Observer's read.
  defp drive(%{engine: engine, observer: observer, clock: clock}, samples, twa_deg) do
    Enum.each(samples, fn s ->
      Agent.update(clock, fn _ -> s.t_ms end)

      :ok =
        Engine.put_signals(
          engine,
          [{"true_wind_direction", s.twd_deg}, {"true_wind_speed", s.tws_mps}, {"true_wind_angle", twa_deg}],
          s.t_ms
        )

      _ = Engine.signals(engine)
      Observer.tick(observer)
    end)
  end

  defp engine_values(engine), do: Map.new(Engine.current_values(engine), &{&1.def.id, &1})

  defp signal(engine, name) do
    case Engine.signals(engine)[name] do
      {value, _mono_ms} -> value
      nil -> nil
    end
  end

  defp assert_gate_open(engine) do
    assert signal(engine, "wind_regime") == 2
    assert signal(engine, "shift_confidence") >= 50.0
    lift = signal(engine, "wind_lift_deg")
    assert is_number(lift) and abs(lift) >= 2.0
    lift
  end

  defp assert_modulated(engine, lift) do
    delta = Wally.delta_deg(lift)
    tws = signal(engine, "true_wind_speed")
    {:ok, expected_bsp} = Lookup.boat_speed(lookup(), @base_beat_twa + delta, tws)

    v = engine_values(engine)
    assert v["ttwa"].valid? and v["tbs"].valid?

    assert v["ttwa"].outputs == %{
             "target_twa" => @base_beat_twa + delta,
             "wally_delta_deg" => delta,
             "wally_active" => 1.0
           }

    assert v["tbs"].outputs == %{
             "target_boat_speed" => expected_bsp,
             "wally_delta_deg" => delta,
             "wally_active" => 1.0
           }

    delta
  end

  defp assert_base(engine) do
    v = engine_values(engine)
    assert v["ttwa"].valid? and v["tbs"].valid?
    assert v["ttwa"].outputs == %{"target_twa" => @base_beat_twa}
    assert v["tbs"].outputs == %{"target_boat_speed" => @base_beat_bsp}
  end

  # 5.25 periods of a +/-10 deg, 480 s oscillation: t = 2520 s lands ON the
  # veered (lift) extreme; 240 s more (5.75 periods) lands on the backed
  # (header) extreme. Starboard tack (twa +40) makes the veer the LIFT.
  defp oscillating_samples(dur_s) do
    WindGen.generate([%{dur_s: dur_s, base: 200.0, osc: {10.0, 480}}], noise_sigma: 1.5)
  end

  test "mode on: engine targets follow the lift with the half-rule, on both phases of the oscillation" do
    stack = start_stack("on")
    {lift_leg, header_leg} = Enum.split(oscillating_samples(2760), 2520)

    drive(stack, lift_leg, 40.0)

    # On the LIFTED phase: FOOT — TWA widens, speed is the (faster) polar value
    # at the footed angle.
    lift = assert_gate_open(stack.engine)
    assert lift > 0.0
    delta = assert_modulated(stack.engine, lift)
    assert delta > 0.0
    {:ok, footed_bsp} = Lookup.boat_speed(lookup(), @base_beat_twa + delta, 6.0)
    assert footed_bsp > @base_beat_bsp

    # Ride the oscillation to the HEADED phase: PINCH — TWA narrows.
    drive(stack, header_leg, 40.0)
    header = assert_gate_open(stack.engine)
    assert header < 0.0
    delta = assert_modulated(stack.engine, header)
    assert delta < 0.0
  end

  test "mode shadow: primaries stay the base optimum while wally_target_* ride along" do
    stack = start_stack("shadow")
    drive(stack, oscillating_samples(2520), 40.0)

    lift = assert_gate_open(stack.engine)
    delta = Wally.delta_deg(lift)
    {:ok, expected_bsp} = Lookup.boat_speed(lookup(), @base_beat_twa + delta, 6.0)

    v = engine_values(stack.engine)
    assert v["ttwa"].outputs["target_twa"] == @base_beat_twa
    assert v["tbs"].outputs["target_boat_speed"] == @base_beat_bsp
    assert v["ttwa"].outputs["wally_target_twa"] == @base_beat_twa + delta
    assert v["ttwa"].outputs["wally_target_boat_speed"] == expected_bsp
    assert v["ttwa"].outputs["wally_delta_deg"] == delta
    assert v["ttwa"].outputs["wally_active"] == 1.0
    assert v["tbs"].outputs["wally_target_boat_speed"] == expected_bsp
    assert v["tbs"].outputs["wally_active"] == 1.0
  end

  test "mode flips take effect on the next tick without a core rebuild; a confidence drop reverts to base" do
    stack = start_stack("on")

    # The scripted truth: 2530 s of clean oscillation, then the wind degrades
    # into a random walk (the oscillation dies -> the classifier must drop the
    # oscillating verdict / its confidence).
    [osc, walk] =
      [%{dur_s: 2530, base: 200.0, osc: {10.0, 480}}, %{dur_s: 1800, walk_sigma: 2.0}]
      |> WindGen.generate(noise_sigma: 1.5)
      |> then(fn samples ->
        {a, b} = Enum.split(samples, 2520)
        [a, b]
      end)

    drive(stack, osc, 40.0)
    lift = assert_gate_open(stack.engine)
    assert_modulated(stack.engine, lift)

    {next_ticks, walk_rest} = Enum.split(walk, 5)
    [flip_off_tick, flip_on_tick | settle_ticks] = next_ticks

    # Flip to OFF: the very next tick reverts the primaries to the base optimum,
    # and the predictor cores were NOT rebuilt (the oscillating verdict survives).
    {:ok, _} = Config.apply_config(stack.config, %{"version" => 2, "wally" => %{"mode" => "off"}})
    drive(stack, [flip_off_tick], 40.0)
    assert_base(stack.engine)
    assert signal(stack.engine, "wind_regime") == 2

    # Flip back to ON: modulation re-engages on the next tick (no warmup lost).
    {:ok, _} = Config.apply_config(stack.config, %{"version" => 3, "wally" => %{"mode" => "on"}})
    drive(stack, [flip_on_tick], 40.0)
    lift = assert_gate_open(stack.engine)
    assert_modulated(stack.engine, lift)
    drive(stack, settle_ticks, 40.0)

    # Feed the random walk tick by tick: the FIRST classifier update that fails
    # the gate (regime leaves :oscillating or confidence drops below 50) must
    # already see base-optimum targets — reversion within one update.
    gate_failed? =
      Enum.reduce_while(walk_rest, false, fn sample, _acc ->
        drive(stack, [sample], 40.0)
        regime = signal(stack.engine, "wind_regime")
        confidence = signal(stack.engine, "shift_confidence")

        if regime != 2 or confidence < 50.0 do
          {:halt, true}
        else
          {:cont, false}
        end
      end)

    assert gate_failed?, "the random walk never dropped the oscillating verdict/confidence"
    assert_base(stack.engine)
  end
end
