defmodule RacingOrg.Tracker.Pro.Calibration.ObserverTest do
  @moduledoc """
  Tests for the auto-calibration Observer: the GenServer that ties the pure
  detection/estimation cores to the live device — raw NMEA intake (VirtualDevice
  handler), 1 Hz sampling, per-sensor estimator attribution, shadow→promote via
  `Calibration.Config.put_learned/4`, throttled upstream sync, and persistence.

  Async-safe: the Observer is driven with synthetic `{:data, %NMEA.Data{}}`
  messages + explicit `tick/1` calls on an injected Agent-backed monotonic clock
  (no timers, no global :telemetry — the integration Engine is started with
  `attach_telemetry?: false` and fed `:signal_updates` directly).
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Config
  alias RacingOrg.Tracker.Pro.Calibration.Observer
  alias RacingOrg.Tracker.Pro.Compute.Engine

  @deg_per_rad 180.0 / :math.pi()
  @rad_per_deg :math.pi() / 180.0

  # Stable NMEA NAMEs (8-byte on-bus binaries) and their canonical hex ids.
  @wind_name <<0, 0, 0, 0, 0, 0, 0x1A, 0x2B>>
  @wind_hex "1A2B"
  @wind_name_b <<0, 0, 0, 0, 0, 0, 0x9F, 0x01>>
  @wind_hex_b "9F01"
  @speed_name <<0, 0, 0, 0, 0, 0, 0x3C, 0x4D>>
  @speed_hex "3C4D"
  @compass_name <<0, 0, 0, 0, 0, 0, 0x5E, 0x6F>>
  @compass_hex "5E6F"
  @gps_name <<0, 0, 0, 0, 0, 0, 0x7A, 0x8B>>

  # --- injected monotonic clock ------------------------------------------

  defp start_clock do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    clock
  end

  defp set_now(clock, t_ms), do: Agent.update(clock, fn _ -> t_ms end)
  defp now_fn(clock), do: fn -> Agent.get(clock, & &1) end

  # --- raw NMEA.Data builders (the exact shapes the VirtualDevice hands out) ---

  defp data(values, name, mono) do
    %NMEA.Data{
      values: values,
      source_info: %NMEA.NMEA2000.Frame{timestamp_monotonic_ms: mono},
      metadata: %{source_nmea_name: name}
    }
  end

  # Apparent wind: bus angle in RADIANS 0..2pi (a signed-negative AWA arrives as
  # its 0..360 equivalent), speed m/s.
  defp wind_data(awa_deg_signed, aws_mps, name, mono) do
    angle_rad = wrap360(awa_deg_signed) * @rad_per_deg

    data(
      %{NMEA.WindParams => %NMEA.WindParams{speed: aws_mps, angle: angle_rad, reference: :apparent}},
      name,
      mono
    )
  end

  defp water_speed_data(stw_mps, name, mono) do
    data(%{NMEA.SpeedParams => %NMEA.SpeedParams{speed: stw_mps, speed_reference: :water}}, name, mono)
  end

  defp heading_data(heading_deg, name, mono) do
    data(%{NMEA.HeadingParams => %NMEA.HeadingParams{heading: heading_deg * @rad_per_deg}}, name, mono)
  end

  defp cog_sog_data(cog_deg, sog_mps, name, mono) do
    data(
      %{
        NMEA.CourseParams => %NMEA.CourseParams{course: cog_deg * @rad_per_deg},
        NMEA.SpeedParams => %NMEA.SpeedParams{speed: sog_mps, speed_reference: :speed_over_ground}
      },
      name,
      mono
    )
  end

  defp attitude_data(roll_rad, name, mono) do
    data(%{NMEA.AttitudeParams => %NMEA.AttitudeParams{yaw: 0.0, pitch: 0.0, roll: roll_rad}}, name, mono)
  end

  # Send a raw frame and synchronize (the following call is processed after the
  # info, so `latest` is updated before we assert).
  defp observe(pid, d) do
    send(pid, {:data, d})
    _ = Observer.stats(pid)
    :ok
  end

  # --- observer under test -------------------------------------------------

  defp start_observer(clock, opts \\ []) do
    defaults = [
      name: nil,
      sample_ms: 0,
      dir: nil,
      calibration: nil,
      boat_identifier: "boat-test",
      sender: fn _channel, _update -> :ok end,
      now_fn: now_fn(clock),
      # Tests drive sync/persist explicitly unless a throttle is under test.
      sync_ms: 10_000_000,
      persist_ms: 10_000_000,
      # Short legs keep the synthetic scripts fast (Tack's min_leg_s stays 30).
      legs: [min_duration_s: 30.0]
    ]

    {:ok, pid} = Observer.start_link(Keyword.merge(defaults, opts))
    pid
  end

  defp collecting_sender do
    me = self()

    fn _channel, update ->
      send(me, {:calibration_update, update})
      :ok
    end
  end

  # One simulated second: advance the clock, deliver each channel's raw frame, tick.
  defp step(pid, clock, t_ms, ch) do
    set_now(clock, t_ms)
    if ch[:awa], do: send(pid, {:data, wind_data(ch.awa, ch.aws, ch[:wind_name] || @wind_name, t_ms)})
    if ch[:stw], do: send(pid, {:data, water_speed_data(ch.stw, ch[:speed_name] || @speed_name, t_ms)})
    if ch[:heading], do: send(pid, {:data, heading_data(ch.heading, @compass_name, t_ms)})
    if ch[:cog], do: send(pid, {:data, cog_sog_data(ch.cog, ch.sog, @gps_name, t_ms)})
    :ok = Observer.tick(pid)
  end

  # --- scripted truth ------------------------------------------------------

  # Forward wind triangle (independent of the module under test).
  defp apparent(tws, twa_deg, stw) do
    twa = twa_deg * @rad_per_deg
    ax = tws * :math.cos(twa) + stw
    ay = tws * :math.sin(twa)
    {:math.sqrt(ax * ax + ay * ay), :math.atan2(ay, ax) * @deg_per_rad}
  end

  defp wrap360(deg) do
    r = :math.fmod(deg, 360.0)
    if r < 0, do: r + 360.0, else: r + 0.0
  end

  # Close-hauled truth: TWD 0, TWS `:tws` (default 6), STW 3.5, 45 deg off the
  # wind on each tack, with vane ROTATION and UPWASH errors injected on the
  # measured AWA (`awa_meas = awa_true - rotation + upwash_err * sign(awa_true)`;
  # the additive corrections are +rotation and -upwash_err).
  defp beat_channels(side, rotation, opts \\ []) do
    tws = Keyword.get(opts, :tws, 6.0)
    upwash_err = Keyword.get(opts, :upwash_err, 0.0)
    sign = if side == :starboard, do: 1.0, else: -1.0
    heading = wrap360(0.0 - sign * 45.0)
    {aws, awa_true} = apparent(tws, sign * 45.0, 3.5)
    %{awa: awa_true - rotation + upwash_err * sign, aws: aws, stw: 3.5, heading: heading, cog: heading, sog: 3.5}
  end

  # Drive `legs` alternating-tack legs of `leg_s` samples each at 1 Hz. Leg k's
  # first sample breaks leg k-1 (90 deg heading jump + AWA side flip), so pair N
  # completes at the first sample of leg 2N (0-based).
  defp drive_beat(pid, clock, opts \\ []) do
    legs = Keyword.get(opts, :legs, 21)
    leg_s = Keyword.get(opts, :leg_s, 40)
    rotation = Keyword.get(opts, :rotation, 3.0)
    t0 = Keyword.get(opts, :t0_ms, 0)
    first_leg = Keyword.get(opts, :first_leg, 0)
    wind_name = Keyword.get(opts, :wind_name, @wind_name)
    channel_opts = Keyword.take(opts, [:tws, :upwash_err])

    for leg <- 0..(legs - 1), i <- 0..(leg_s - 1) do
      side = if rem(first_leg + leg, 2) == 0, do: :starboard, else: :port
      t = t0 + (leg * leg_s + i) * 1000
      step(pid, clock, t, beat_channels(side, rotation, channel_opts) |> Map.put(:wind_name, wind_name))
    end

    :ok
  end

  # Reciprocal motoring truth: heading 0/180 in TWD 90 / TWS 5, true STW 2.0 with
  # an injected speedo GAIN error (`stw_meas = stw_true / gain`), no current
  # (SOG = true STW). AWA ~68 deg keeps Tack (<=60) and the gybe band (>=120) out.
  defp motor_channels(direction, gain) do
    heading = if direction == :out, do: 0.0, else: 180.0
    twa = if direction == :out, do: 90.0, else: -90.0
    {aws, awa} = apparent(5.0, twa, 2.0)
    %{awa: awa, aws: aws, stw: 2.0 / gain, heading: heading, cog: heading, sog: 2.0}
  end

  defp drive_reciprocals(pid, clock, opts \\ []) do
    legs = Keyword.get(opts, :legs, 15)
    leg_s = Keyword.get(opts, :leg_s, 40)
    gain = Keyword.get(opts, :gain, 1.1)

    for leg <- 0..(legs - 1), i <- 0..(leg_s - 1) do
      direction = if rem(leg, 2) == 0, do: :out, else: :back
      t = (leg * leg_s + i) * 1000
      step(pid, clock, t, motor_channels(direction, gain))
    end

    :ok
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() ->
        true

      retries <= 0 ->
        false

      true ->
        Process.sleep(5)
        eventually(fun, retries - 1)
    end
  end

  # =====================================================================
  # Raw intake (VirtualDevice handler)
  # =====================================================================

  describe "raw intake" do
    test "wind/speed/heading/cog+sog/attitude frames populate latest with catalog units + sensor hex" do
      clock = start_clock()
      pid = start_observer(clock)

      # AWA arrives on the bus as 0..2pi radians; 330 deg folds to signed -30.
      observe(pid, wind_data(-30.0, 8.0, @wind_name, 5))
      observe(pid, water_speed_data(4.0, @speed_name, 6))
      observe(pid, heading_data(180.0, @compass_name, 7))
      observe(pid, cog_sog_data(90.0, 3.0, @gps_name, 8))
      observe(pid, attitude_data(0.1, @compass_name, 9))

      latest = Observer.latest(pid)

      assert {awa, @wind_hex, 5} = latest.awa
      assert_in_delta awa, -30.0, 1.0e-9
      assert {8.0, @wind_hex, 5} = latest.aws
      assert {4.0, @speed_hex, 6} = latest.stw
      assert {heading, @compass_hex, 7} = latest.heading
      assert_in_delta heading, 180.0, 1.0e-9
      assert {cog, _hex, 8} = latest.cog
      assert_in_delta cog, 90.0, 1.0e-9
      assert {3.0, _hex, 8} = latest.sog
      assert {heel, @compass_hex, 9} = latest.heel
      assert_in_delta heel, 0.1 * @deg_per_rad, 1.0e-9
    end

    test "nil-NAME data is ignored (own-output guard: our own frames carry no NAME)" do
      clock = start_clock()
      pid = start_observer(clock)

      observe(pid, wind_data(30.0, 8.0, nil, 5))
      observe(pid, water_speed_data(4.0, nil, 6))

      latest = Observer.latest(pid)
      refute Map.has_key?(latest, :awa)
      refute Map.has_key?(latest, :stw)
    end

    test "non-apparent wind references never touch the apparent channels" do
      clock = start_clock()
      pid = start_observer(clock)

      true_wind =
        data(
          %{NMEA.WindParams => %NMEA.WindParams{speed: 6.0, angle: 1.0, reference: :theoretical_water_vessel}},
          @wind_name,
          5
        )

      observe(pid, true_wind)
      refute Map.has_key?(Observer.latest(pid), :awa)
    end
  end

  # =====================================================================
  # Tick admission (staleness / required channels / at-rest floor)
  # =====================================================================

  describe "tick admission" do
    test "missing and stale required channels are rejected with tallied reasons" do
      clock = start_clock()
      pid = start_observer(clock)

      # Nothing received yet.
      set_now(clock, 0)
      :ok = Observer.tick(pid)
      assert Observer.stats(pid).reject_reasons[:no_awa] == 1

      # Wind + speed fresh, heading missing.
      observe(pid, wind_data(-30.0, 8.0, @wind_name, 0))
      observe(pid, water_speed_data(4.0, @speed_name, 0))
      :ok = Observer.tick(pid)
      assert Observer.stats(pid).reject_reasons[:no_heading] == 1

      # Heading arrives, but the wind sample goes stale (> 3 s old by mono).
      observe(pid, heading_data(10.0, @compass_name, 0))
      set_now(clock, 5_000)
      observe(pid, water_speed_data(4.0, @speed_name, 5_000))
      observe(pid, heading_data(10.0, @compass_name, 5_000))
      :ok = Observer.tick(pid)
      assert Observer.stats(pid).reject_reasons[:no_awa] == 2

      stats = Observer.stats(pid)
      assert stats.samples == 3
      assert stats.accepted == 0
      assert stats.rejected == 3
    end

    test "an at-rest boat (STW below the floor) is rejected as :at_rest" do
      clock = start_clock()
      pid = start_observer(clock)

      step(pid, clock, 0, %{awa: 30.0, aws: 8.0, stw: 0.2, heading: 10.0})

      stats = Observer.stats(pid)
      assert stats.reject_reasons[:at_rest] == 1
      assert stats.accepted == 0
    end
  end

  # =====================================================================
  # Source stability (a leg must be single-source)
  # =====================================================================

  describe "source stability" do
    test "a mid-stream AWA sensor change flushes the old window (attributed to the old sensor) and starts clean" do
      clock = start_clock()
      pid = start_observer(clock)

      # 35 s on wind sensor A, then 35 s on wind sensor B, then a heading break.
      for i <- 0..34, do: step(pid, clock, i * 1000, beat_channels(:starboard, 0.0))

      for i <- 35..69 do
        step(pid, clock, i * 1000, beat_channels(:starboard, 0.0) |> Map.put(:wind_name, @wind_name_b))
      end

      # Break B's segment (90 deg heading jump at constant AWA source).
      broken = beat_channels(:starboard, 0.0) |> Map.merge(%{heading: 45.0, cog: 45.0, wind_name: @wind_name_b})
      step(pid, clock, 70_000, broken)

      stats = Observer.stats(pid)
      assert stats.source_resets == 1
      # A's 35 s segment flushed at the switch; B's 35 s segment closed at the break.
      assert stats.legs == 2

      # Each leg fed the AWS diagnostic keyed by ITS OWN wind sensor.
      %{aws: aws} = Observer.estimates(pid)
      assert Map.keys(aws) |> Enum.sort() == Enum.sort([@wind_hex, @wind_hex_b])
    end
  end

  # =====================================================================
  # End-to-end: beat -> AwaOffset -> Config -> Engine
  # =====================================================================

  describe "end-to-end AWA rotation fit" do
    test "an injected rotation error validates, promotes SLEWED into Config, and corrects the Engine's AWA" do
      clock = start_clock()
      {:ok, config} = Config.start_link(name: nil, store_dir: nil)
      pid = start_observer(clock, calibration: {Config, config})

      # 21 legs -> 10 matched tack pairs with a +3 deg rotation error.
      drive_beat(pid, clock, legs: 21, rotation: 3.0)

      # The estimator recovered the error exactly and validated.
      %{awa: %{@wind_hex => %{rotation: rotation, upwash: upwash}}} = Observer.estimates(pid)
      assert rotation.state == :validated
      assert_in_delta rotation.value, 3.0, 1.0e-6
      assert rotation.sample_count == 10
      assert_in_delta upwash.value, 0.0, 1.0e-6

      # Mode auto -> the APPLIED value creeps: validated at pair 8, slewed 0.5 per
      # pair -> 1.5 after pair 10 (never a 3.0 jump). The upwash validated too
      # (single band at TWS 6 through the classic gate), promoting a ~0 curve.
      assert %{@wind_hex => corrections} = Config.corrections(config)
      assert_in_delta corrections.awa_offset_deg, 1.5, 1.0e-9
      assert [{7, upwash7}] = corrections.awa_upwash
      assert_in_delta upwash7, 0.0, 1.0e-6

      # A REAL Engine wired to the REAL Config sees the corrected AWA
      # (emitted at |awa| = 30 where the upwash angle shape is exactly 1.0).
      engine =
        start_supervised!(
          {Engine, name: nil, store_dir: nil, commands: nil, attach_telemetry?: false, calibration: {Config, config}},
          id: {Engine, System.unique_integer([:positive])}
        )

      send(engine, {:signal_updates, [{"apparent_wind_angle", 30.0}], 0, @wind_name})
      assert {awa, _mono} = Engine.signals(engine)["apparent_wind_angle"]
      assert_in_delta awa, 31.5, 1.0e-5

      # One more pair slews to 2.0; the Config change notifies the Engine, which
      # refreshes its cached corrections and applies the new offset live.
      drive_beat(pid, clock, legs: 3, rotation: 3.0, t0_ms: 21 * 40 * 1000, first_leg: 21)
      assert_in_delta Config.corrections(config)[@wind_hex].awa_offset_deg, 2.0, 1.0e-9

      assert eventually(fn ->
               send(engine, {:signal_updates, [{"apparent_wind_angle", 30.0}], 0, @wind_name})
               {awa, _} = Engine.signals(engine)["apparent_wind_angle"]
               abs(awa - 32.0) < 1.0e-5
             end)
    end

    test "a TWS-dependent upwash curve promotes into Config and the Engine applies the band value at the current TWS" do
      clock = start_clock()
      {:ok, config} = Config.start_link(name: nil, store_dir: nil)
      pid = start_observer(clock, calibration: {Config, config}, sender: collecting_sender())

      # Two TWS regimes with DIFFERENT injected upwash errors: 9 legs -> 4 pairs
      # at TWS 4.5 (band 5) with error -3 (correction +3), then 9 legs -> 4
      # pairs at TWS 9.0 (band 9) with error -1 (correction +1). The cross-band
      # boundary pair is rejected by the tack detector's TWS-match gate, so each
      # band learns only its own regime; with two published bands the backbone
      # publishes both through the pooled posterior gate.
      drive_beat(pid, clock, legs: 9, rotation: 0.0, tws: 4.5, upwash_err: -3.0)

      drive_beat(pid, clock,
        legs: 9,
        rotation: 0.0,
        tws: 9.0,
        upwash_err: -1.0,
        t0_ms: 9 * 40 * 1000,
        first_leg: 9
      )

      assert %{awa_upwash: [{5, v5}, {9, v9}]} = corrections = Config.corrections(config)[@wind_hex]
      assert_in_delta v5, 3.0, 0.4
      assert_in_delta v9, 1.0, 0.4
      offset = Map.get(corrections, :awa_offset_deg, 0.0)

      engine =
        start_supervised!(
          {Engine, name: nil, store_dir: nil, commands: nil, attach_telemetry?: false, calibration: {Config, config}},
          id: {Engine, System.unique_integer([:positive])}
        )

      # All asserted at |awa| = 30 where the upwash angle shape is exactly 1.0.
      # At TWS 4.5 the band-5 value applies (flat hold below the first center).
      send(engine, {:signal_updates, [{"true_wind_speed", 4.5}], 0})
      send(engine, {:signal_updates, [{"apparent_wind_angle", 30.0}], 0, @wind_name})
      assert {awa, _mono} = Engine.signals(engine)["apparent_wind_angle"]
      assert_in_delta awa, 30.0 + offset + v5, 1.0e-9

      # At TWS 9.0 the band-9 value applies instead — same sensor, same AWA.
      send(engine, {:signal_updates, [{"true_wind_speed", 9.0}], 0})
      send(engine, {:signal_updates, [{"apparent_wind_angle", 30.0}], 0, @wind_name})
      assert {awa, _mono} = Engine.signals(engine)["apparent_wind_angle"]
      assert_in_delta awa, 30.0 + offset + v9, 1.0e-9

      # Between the centers (TWS 7.0) the engine interpolates the curve.
      send(engine, {:signal_updates, [{"true_wind_speed", 7.0}], 0})
      send(engine, {:signal_updates, [{"apparent_wind_angle", 30.0}], 0, @wind_name})
      assert {awa, _mono} = Engine.signals(engine)["apparent_wind_angle"]
      assert_in_delta awa, 30.0 + offset + (v5 + v9) / 2, 1.0e-9

      # WIRE-LEVEL SANITY after the multi-band promotion. The status (pushed
      # verbatim as "calibration_status") must survive JSON encoding with the
      # curve rendered as [%{center:, value:}] maps...
      assert {:ok, encoded} = Jason.encode(Config.status(config))

      assert %{"parameter" => "awa_upwash", "state" => "applied", "value" => [point5, point9]} =
               encoded |> Jason.decode!() |> Map.fetch!("sensors") |> Enum.find(&(&1["parameter"] == "awa_upwash"))

      assert %{"center" => 5, "value" => wire5} = point5
      assert %{"center" => 9, "value" => wire9} = point9
      assert_in_delta wire5, v5, 1.0e-9
      assert_in_delta wire9, v9, 1.0e-9

      # ...and the "calibration_update" sync entry carries the same curve
      # (value = the point nearest 6.17 m/s, i.e. band 5's).
      :ok = Observer.sync_now(pid)
      assert_received {:calibration_update, update}

      assert %{state: "applied", value: rep, curve: sync_curve} =
               Enum.find(update.entries, &(&1.parameter == "awa_upwash"))

      assert [%{center: 5, value: sync5}, %{center: 9, value: sync9}] = sync_curve
      assert_in_delta sync5, v5, 1.0e-9
      assert_in_delta sync9, v9, 1.0e-9
      assert rep == sync5
    end
  end

  # =====================================================================
  # Upwash curve promotion (scalar slew path until the curve publishes)
  # =====================================================================

  describe "upwash curve promotion" do
    test "the learned value is the scalar estimate until the curve publishes, then the {center, deg} list" do
      clock = start_clock()
      {:ok, config} = Config.start_link(name: nil, store_dir: nil)
      pid = start_observer(clock, calibration: {Config, config}, sender: collecting_sender())

      # 5 legs -> 2 pairs at TWS 6: the single band is far from the classic
      # k = 1 gate (>= 8 validated pairs), so the curve is empty and the learned
      # entry is TODAY'S scalar path — a float, honestly "learning".
      drive_beat(pid, clock, legs: 5, rotation: 0.0, upwash_err: 2.0)
      assert Config.corrections(config) == %{}

      assert %{state: "learning", value: value} =
               Enum.find(Config.status(config).sensors, &(&1.parameter == "awa_upwash"))

      assert is_number(value)
      assert_in_delta value, -2.0, 0.4

      # Through the classic gate (10 pairs total): the curve publishes and the
      # learned value becomes the curve list, applied under auto mode — no slew
      # (the curve is already shrunk + clamped).
      drive_beat(pid, clock, legs: 16, rotation: 0.0, upwash_err: 2.0, t0_ms: 5 * 40 * 1000, first_leg: 5)

      assert %{awa_upwash: [{7, v7}]} = Config.corrections(config)[@wind_hex]
      assert_in_delta v7, -2.0, 0.4

      # The sync entry carries the representative scalar (the curve point
      # nearest 6.17 m/s) as value plus the full curve as maps with VALUE keys
      # (the backend's awa_upwash contract; stw curves use gain keys).
      :ok = Observer.sync_now(pid)
      assert_received {:calibration_update, update}

      assert %{state: "applied", sample_count: 10, curve: curve, value: rep} =
               Enum.find(update.entries, &(&1.parameter == "awa_upwash"))

      assert curve == [%{center: 7, value: v7}]
      assert rep == v7
    end
  end

  # =====================================================================
  # Upwash screen/light-air observability
  # =====================================================================

  describe "upwash counters in stats" do
    test "light-air pairs are tallied as excluded_light (rotation still learns)" do
      clock = start_clock()
      pid = start_observer(clock)

      # TWS 1.5 m/s < the 2 m/s cutoff: both pairs feed rotation but their
      # upwash raws are excluded from the bands.
      drive_beat(pid, clock, legs: 5, rotation: 3.0, tws: 1.5)

      stats = Observer.stats(pid)
      assert stats.excluded_light == 2
      assert stats.screened == 0

      %{awa: %{@wind_hex => snap}} = Observer.estimates(pid)
      assert snap.rotation.sample_count == 2
      assert snap.upwash.sample_count == 0
    end
  end

  # =====================================================================
  # Shadow mode
  # =====================================================================

  describe "shadow mode" do
    test "shadow modes record honest shadow entries, keep corrections empty, and still sync" do
      clock = start_clock()
      {:ok, config} = Config.start_link(name: nil, store_dir: nil)
      pid = start_observer(clock, calibration: {Config, config}, sender: collecting_sender())

      # Push the shadow policy AFTER the Observer subscribed: the change
      # notification must refresh its cached modes.
      {:ok, _} =
        Config.apply_config(config, %{
          "version" => 1,
          "parameters" => %{"awa_offset" => %{"mode" => "shadow"}, "awa_upwash" => %{"mode" => "shadow"}}
        })

      # Barrier: the {:racing_org_calibration, :updated} notification is processed.
      _ = Observer.stats(pid)

      drive_beat(pid, clock, legs: 21, rotation: 3.0)

      # Validated but shadow: recorded with the honest state, nothing applied.
      assert Config.corrections(config) == %{}

      sensors = Config.status(config).sensors
      assert %{state: "shadow", value: value} = Enum.find(sensors, &(&1.parameter == "awa_offset"))
      assert_in_delta value, 3.0, 1.0e-6

      # The published upwash curve is recorded as a shadow LIST too (rendered
      # as maps in the status), never compiled into corrections.
      assert %{state: "shadow", value: [%{center: 7, value: _}]} =
               Enum.find(sensors, &(&1.parameter == "awa_upwash"))

      # The upstream sync still reports the shadow estimates.
      :ok = Observer.sync_now(pid)
      assert_received {:calibration_update, update}
      assert %{state: "shadow"} = Enum.find(update.entries, &(&1.parameter == "awa_offset"))

      assert %{state: "shadow", curve: [%{center: 7, value: _}]} =
               Enum.find(update.entries, &(&1.parameter == "awa_upwash"))
    end
  end

  # =====================================================================
  # Reciprocal runs -> StwScale -> corrections carry the gain curve
  # =====================================================================

  describe "reciprocal STW gain fit" do
    test "scripted reciprocal legs with a gain error promote the gain curve into corrections and the Engine" do
      clock = start_clock()
      {:ok, config} = Config.start_link(name: nil, store_dir: nil)
      pid = start_observer(clock, calibration: {Config, config}, sender: collecting_sender())

      # 15 legs -> 7 reciprocal pairs at gain_obs exactly 1.1 (band center 1).
      drive_reciprocals(pid, clock, legs: 15, gain: 1.1)

      assert Observer.stats(pid).reciprocal_pairs == 7
      # No tack pairs from a beam-ish reciprocal script (AWA ~68 deg).
      assert Observer.stats(pid).tack_pairs == 0

      # Mode auto -> the validated band's RLS gain compiles into corrections,
      # attributed to the SPEED sensor.
      assert %{@speed_hex => %{stw_gains: [{1, gain}]}} = Config.corrections(config)
      assert gain > 1.04 and gain < 1.1001

      # The sync entry carries the representative gain AND the full curve.
      :ok = Observer.sync_now(pid)
      assert_received {:calibration_update, update}
      assert [entry] = update.entries
      assert entry.parameter == "stw_scale"
      assert entry.hardware_identifier == @speed_hex
      assert entry.state == "applied"
      assert_in_delta entry.value, gain, 1.0e-9
      assert entry.curve == [%{center: 1, gain: gain}]

      # A REAL Engine wired to the REAL Config corrects boat_speed by the curve.
      engine =
        start_supervised!(
          {Engine, name: nil, store_dir: nil, commands: nil, attach_telemetry?: false, calibration: {Config, config}},
          id: {Engine, System.unique_integer([:positive])}
        )

      send(engine, {:signal_updates, [{"boat_speed", 2.0}], 0, @speed_name})
      assert {stw, _mono} = Engine.signals(engine)["boat_speed"]
      assert_in_delta stw, 2.0 * gain, 1.0e-9
    end
  end

  # =====================================================================
  # Upstream sync (throttled, changed-only, batched)
  # =====================================================================

  describe "upstream sync" do
    test "the throttle holds (no per-event sends); sync_now emits one batched update" do
      clock = start_clock()
      pid = start_observer(clock, sender: collecting_sender())

      # 5 legs -> 2 tack pairs; the 10_000_000 ms throttle never fires on its own.
      drive_beat(pid, clock, legs: 5, rotation: 3.0)
      refute_received {:calibration_update, _}

      :ok = Observer.sync_now(pid)
      assert_received {:calibration_update, update}
      assert update.boat_identifier == "boat-test"
      assert update.seq == 1

      assert [rot, up] = update.entries
      assert %{hardware_identifier: @wind_hex, parameter: "awa_offset", state: "learning", sample_count: 2} = rot
      assert_in_delta rot.value, 3.0, 1.0e-6
      assert is_number(rot.confidence)
      assert is_number(rot.residual)
      refute Map.has_key?(rot, :curve)
      assert %{parameter: "awa_upwash"} = up
    end

    test "changed-only: an unchanged state is not re-sent" do
      clock = start_clock()
      pid = start_observer(clock, sender: collecting_sender())

      drive_beat(pid, clock, legs: 5, rotation: 3.0)
      :ok = Observer.sync_now(pid)
      assert_received {:calibration_update, _}

      # Nothing new observed -> nothing to send.
      :ok = Observer.sync_now(pid)
      refute_received {:calibration_update, _}
    end

    test "seq is monotonic across syncs" do
      clock = start_clock()
      pid = start_observer(clock, sender: collecting_sender())

      drive_beat(pid, clock, legs: 5, rotation: 3.0)
      :ok = Observer.sync_now(pid)
      assert_received {:calibration_update, %{seq: 1}}

      drive_beat(pid, clock, legs: 4, rotation: 3.0, t0_ms: 5 * 40 * 1000, first_leg: 5)
      :ok = Observer.sync_now(pid)
      assert_received {:calibration_update, %{seq: 2}}
    end

    test "the sync fires on its own once the interval is due and something changed" do
      clock = start_clock()
      pid = start_observer(clock, sender: collecting_sender(), sync_ms: 60_000)

      # First pair completes at t = 80 s > the 60 s throttle anchor -> auto-sync.
      drive_beat(pid, clock, legs: 3, rotation: 3.0)
      assert_received {:calibration_update, %{seq: 1}}
    end
  end

  # =====================================================================
  # Persistence
  # =====================================================================

  describe "persistence" do
    setup do
      dir = Path.join(System.tmp_dir!(), "nn_cal_observer_#{System.unique_integer([:positive])}")
      # The Observer's terminate flush is asynchronous (linked + trap_exit) and
      # can land AFTER on_exit's cleanup; unique_integer sequences repeat across
      # BEAM runs, so a later run can inherit that leftover file. Pre-clean so
      # every test starts from a genuinely empty dir.
      File.rm_rf(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "restart restores estimator state AND prev_applied (slew continues, not from scratch)", %{dir: dir} do
      clock = start_clock()
      {:ok, config} = Config.start_link(name: nil, store_dir: nil)
      pid = start_observer(clock, calibration: {Config, config}, dir: dir)

      drive_beat(pid, clock, legs: 21, rotation: 3.0)
      assert_in_delta Config.corrections(config)[@wind_hex].awa_offset_deg, 1.5, 1.0e-9
      :ok = Observer.persist_now(pid)
      GenServer.stop(pid)

      # Fresh Observer + fresh Config over the same dir: the estimator resumes at
      # 10 pairs, and the NEXT applied value slews from 1.5 -> 2.0 (not 0.5).
      clock2 = start_clock()
      {:ok, config2} = Config.start_link(name: nil, store_dir: nil)
      pid2 = start_observer(clock2, calibration: {Config, config2}, dir: dir)

      %{awa: %{@wind_hex => %{rotation: restored}}} = Observer.estimates(pid2)
      assert restored.sample_count == 10

      drive_beat(pid2, clock2, legs: 3, rotation: 3.0)
      assert_in_delta Config.corrections(config2)[@wind_hex].awa_offset_deg, 2.0, 1.0e-9
    end

    test "the persist throttle holds; terminate flushes the final state", %{dir: dir} do
      clock = start_clock()
      pid = start_observer(clock, dir: dir)

      drive_beat(pid, clock, legs: 3, rotation: 3.0)
      # Throttle (10_000_000 ms) not due -> nothing written yet.
      refute File.exists?(Path.join(dir, "observer.calibration"))

      GenServer.stop(pid)
      assert File.exists?(Path.join(dir, "observer.calibration"))

      clock2 = start_clock()
      pid2 = start_observer(clock2, dir: dir)
      %{awa: %{@wind_hex => %{rotation: restored}}} = Observer.estimates(pid2)
      assert restored.sample_count == 1
    end

    test "the persist fires on its own once due and dirty", %{dir: dir} do
      clock = start_clock()
      pid = start_observer(clock, dir: dir, persist_ms: 60_000)

      # First pair (dirty) completes at t = 80 s > the 60 s anchor -> auto-persist.
      drive_beat(pid, clock, legs: 3, rotation: 3.0)
      assert File.exists?(Path.join(dir, "observer.calibration"))
    end

    test "a corrupt persisted file starts clean without crashing", %{dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "observer.calibration"), "garbage")

      clock = start_clock()
      pid = start_observer(clock, dir: dir)
      assert Observer.estimates(pid) == %{awa: %{}, stw: %{}, aws: %{}}

      # Still functional: it accumulates fresh.
      drive_beat(pid, clock, legs: 3, rotation: 3.0)
      %{awa: %{@wind_hex => %{rotation: rotation}}} = Observer.estimates(pid)
      assert rotation.sample_count == 1
    end

    test "with dir nil, persistence is disabled (no crash)", %{dir: _dir} do
      clock = start_clock()
      pid = start_observer(clock, dir: nil)
      drive_beat(pid, clock, legs: 3, rotation: 3.0)
      assert :ok = Observer.persist_now(pid)
    end
  end
end
