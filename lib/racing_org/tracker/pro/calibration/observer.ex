defmodule RacingOrg.Tracker.Pro.Calibration.Observer do
  @moduledoc """
  The on-device AUTO-CALIBRATION observer: the integration layer that ties the
  pure detection/estimation cores (`Calibration.Detect.Legs`/`Tack`, the
  `Calibration.Estimator.*` modules) to the live device. It is BOTH an
  `NMEA.NMEA2000.VirtualDevice` handler (raw per-sensor intake) and a ~1 Hz
  sampler, and it promotes what it learns into
  `RacingOrg.Tracker.Pro.Calibration.Config` — which is the SOLE authority the
  compute engine applies corrections from (locks always win there, and a
  parameter mode of `"off"`/`"shadow"` never compiles, so this process can
  record honestly and blindly).

  ## Raw intake (why NOT the compute engine's signals)

  The engine's signal map is calibration-CORRECTED — fitting against it would
  chase our own corrections. So the Observer reads the RAW decoded params
  straight off the bus (registered as a VirtualDevice handler alongside
  `PacketHandler.EmitTelemetry` / `ClockSource.Config`):

    * apparent wind (`NMEA.WindParams`, `reference: :apparent`) → AWA (bus
      radians 0..2π folded to SIGNED ±180°, starboard positive) + AWS m/s;
    * water speed (`NMEA.SpeedParams`, `speed_reference: :water`) → STW m/s;
    * heading (`NMEA.HeadingParams`) → degrees 0..360;
    * COG/SOG (`NMEA.CourseParams` + `NMEA.SpeedParams :speed_over_ground`);
    * attitude roll → heel degrees.

  Each channel keeps `{value, sensor_hex, mono_ms}` — the sensor identity is the
  frame's NMEA NAME canonicalized via `NmeaIdentity.canonical_hardware_id/1`
  (cached per NAME), because every estimate is attributed PER SENSOR.

  Data with a `nil` NAME is ignored. That is deliberately ALSO the own-output
  guard: frames this device broadcasts itself (e.g. the Phase 8 computed-value
  PGNs) come back around WITHOUT a `source_nmea_name`, so the Observer can never
  fit calibration against its own output.

  ## The 1 Hz tick

  On its own timer (never the compute hot path) each tick builds one
  `Detect.Legs` sample from the fresh `latest` values (staleness ≤ `:staleness_ms`
  against the tick clock): AWA/AWS/STW/heading REQUIRED, COG/SOG/heel optional
  (`nil` when absent/stale), `tws_mps` derived via the wind triangle. A tick with
  a stale/missing required channel, or an at-rest boat (STW < `:min_stw_mps`), is
  skipped and tallied (`stats/1`), mirroring `Polar.Observer`.

  **Source stability**: every sample is stamped with its AWA + STW sensor; if
  either differs from the current window's, the building window is FLUSHED
  (trailing events attributed to the OLD sensors) and detection restarts clean —
  a leg (and thus every pair) is always single-source.

  ## Detection → estimation → promotion

  Samples fold through `Legs.step/2`; every event also feeds `Tack.step/2`:

    * `{:tack_pair, pair}` → `AwaOffset.observe_pair` (per AWA sensor) —
      parameters `"awa_offset"` (rotation) and `"awa_upwash"`;
    * `{:reciprocal_pair, pair}` → `StwScale.observe_pair` (per STW sensor) —
      parameter `"stw_scale"`, valued as the estimator's validated `gain_curve`;
    * `{:leg, leg}` → `AwsScale.observe_leg` (per wind sensor) — the
      shadow-only `"aws_scale"` diagnostic (never promoted to applied).

  After each estimator update the current estimate is ALWAYS recorded via
  `Calibration.Config.put_learned/4` with the honest state: `"learning"` until
  validated; `"shadow"` when validated but the parameter mode is shadow;
  `"applied"` when validated AND the mode is auto. Promotion to `"applied"` goes
  through `Estimate.applied_value/3` — clamped and SLEW-LIMITED against the
  previously applied value (tracked per (sensor, parameter) and persisted), so
  corrections creep, never jump. Parameter modes are cached from
  `Calibration.Config.status/1` and refreshed on the standard
  `{:racing_org_calibration, :updated}` notification.

  `"awa_upwash"` promotes in two phases: while the estimator's published TWS
  curve is empty the GLOBAL upwash tracker takes the scalar slew path above;
  once the curve publishes, the learned value is the `[{tws_center_mps, deg}]`
  list itself — no slew, the curve is already shrunk + clamped (mirroring
  `"stw_scale"`'s gain curve) — with sample_count summed and confidence
  min'ed over the published bands.

  ## Upstream sync (throttled, changed-only, batched)

  Changed estimates are batched upstream as a `"calibration_update"` at most
  every `:sync_ms` (default 60 s) — never per event — through an injectable
  sender (default `ChannelClient.send_calibration_update/2`, best-effort +
  session-gated). Each entry carries
  `hardware_identifier / parameter / value / confidence / sample_count / state /
  residual` (the estimate spread); `stw_scale` entries send the representative
  gain (the most-sampled band) as `value` plus the full `curve` as
  `[%{center:, gain:}]`; curve-phase `awa_upwash` entries send the curve point
  nearest 6.17 m/s (12 kn) as `value` plus the full `curve` as
  `[%{center:, value:}]` (the backend expects `value` keys for awa_upwash).

  ## Persistence

  Estimator states + `prev_applied` (+ the sync `seq`) persist via
  `Calibration.Observer.Store` (`observer.calibration` under
  `:calibration_directory` — separate from `Calibration.Config`'s
  `current.calibration`), throttled to `:persist_ms` (default 60 s) and only
  when dirty, with a final flush on terminate. A missing/corrupt file starts
  clean; `dir: nil` (host/test) disables persistence entirely.
  """

  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.Calibration.Config
  alias RacingOrg.Tracker.Pro.Calibration.Detect.Legs
  alias RacingOrg.Tracker.Pro.Calibration.Detect.Tack
  alias RacingOrg.Tracker.Pro.Calibration.Estimate
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.AwaOffset
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.AwsScale
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.StwScale
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.WindTriangle
  alias RacingOrg.Tracker.Pro.Calibration.Observer.Store
  alias RacingOrg.Tracker.Pro.NmeaIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient

  @deg_per_rad 180.0 / :math.pi()

  @default_sample_ms 1_000
  @default_persist_ms 60_000
  @default_sync_ms 60_000
  # A required channel older than this (ms of monotonic time) cannot support a
  # coherent sample: the wind/speed/heading must describe the SAME second.
  @default_staleness_ms 3_000
  # 0.3 m/s ≈ 0.6 kn: below this the boat is at rest and no leg is forming
  # (mirrors Polar.Observer's admission floor).
  @default_min_stw_mps 0.3

  # Safe defaults matching Calibration.Config's — used only until (or unless)
  # the Config collaborator can be read. Config is the enforcement point either
  # way: a learned "applied" entry only compiles when ITS mode really is auto.
  @default_modes %{
    "awa_offset" => "auto",
    "awa_upwash" => "auto",
    "stw_scale" => "auto",
    "aws_scale" => "shadow"
  }

  # --- Client API ---

  @doc """
  Start the Observer.

  Options:

    * `:name` — registered name (default `__MODULE__`; pass `nil` for anonymous).
    * `:dir` — persistence directory (`observer.calibration`). `nil` (the
      host/test default) DISABLES persistence.
    * `:boat_identifier` — stable device/boat id stamped on every sync (default
      `RacingOrg.Tracker.Pro.boat_identifier/0`).
    * `:calibration` — the `Calibration.Config` collaborator learned estimates are
      promoted into: `{module, server}` or a bare module (default
      `RacingOrg.Tracker.Pro.Calibration.Config`); `nil` disables promotion
      (detection/sync still run).
    * `:sample_ms` — sampling period (default `1000`). `0` disables the timer
      (tests drive `tick/1` directly).
    * `:persist_ms` — minimum interval between flash writes (default `60_000`).
    * `:sync_ms` — minimum interval between upstream syncs (default `60_000`).
    * `:staleness_ms` — maximum age of a required channel (default `3_000`).
    * `:min_stw_mps` — at-rest floor (default `0.3`).
    * `:legs` / `:tack` — `Detect.Legs` / `Detect.Tack` opts (or built structs).
    * `:awa_estimator` / `:stw_estimator` / `:aws_estimator` — opts forwarded to
      each per-sensor estimator's `new/1`.
    * `:sender` — 2-arity fn `(channel_client_module, update) -> :ok` used to emit
      a sync (default `&ChannelClient.send_calibration_update/2`). Injectable.
    * `:now_fn` — 0-arity monotonic-ms clock (default `System.monotonic_time/1`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc "Run one sample→detect→estimate→promote tick synchronously."
  @spec tick(GenServer.server()) :: :ok
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @doc "Persist the current state now (throttling is bypassed); returns `:ok`."
  @spec persist_now(GenServer.server()) :: :ok
  def persist_now(server \\ __MODULE__), do: GenServer.call(server, :persist_now)

  @doc "Emit a sync of changed estimates now (throttling is bypassed); returns `:ok`."
  @spec sync_now(GenServer.server()) :: :ok
  def sync_now(server \\ __MODULE__), do: GenServer.call(server, :sync_now)

  @doc """
  The latest raw per-channel intake: `%{awa | aws | stw | heading | cog | sog |
  heel => {value, sensor_hex, mono_ms}}` (only channels heard so far). For
  inspection / the future web UI.
  """
  @spec latest(GenServer.server()) :: map()
  def latest(server \\ __MODULE__), do: GenServer.call(server, :latest)

  @doc """
  Per-sensor estimator snapshots:
  `%{awa: %{hex => AwaOffset.snapshot}, stw: %{hex => StwScale.snapshot},
  aws: %{hex => AwsScale.snapshot}}`.
  """
  @spec estimates(GenServer.server()) :: map()
  def estimates(server \\ __MODULE__), do: GenServer.call(server, :estimates)

  @doc """
  Observability: `%{samples, accepted, rejected, reject_reasons, legs,
  tack_pairs, gybe_pairs, reciprocal_pairs, source_resets, screened,
  excluded_light}` — reject reasons tallied per tick
  (`:no_awa | :no_aws | :no_stw | :no_heading | :at_rest`); `screened` /
  `excluded_light` are the upwash raws rejected by the shear-day screen / the
  light-air TWS exclusion, summed over the AWA estimators.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # --- Server ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    dir = Keyword.get(opts, :dir)
    now_fn = Keyword.get(opts, :now_fn, fn -> System.monotonic_time(:millisecond) end)
    legs_opts = Keyword.get(opts, :legs, [])
    tack_opts = Keyword.get(opts, :tack, [])
    # Anchor both throttle clocks at boot so the FIRST persist/sync must also
    # wait a full interval (mirrors Polar.Observer).
    boot_ms = now_fn.()
    persisted = restore(dir)

    state = %{
      dir: dir,
      boat_identifier: Keyword.get_lazy(opts, :boat_identifier, &RacingOrg.Tracker.Pro.boat_identifier/0),
      calibration: normalize_calibration(Keyword.get(opts, :calibration, Config)),
      sample_ms: Keyword.get(opts, :sample_ms, @default_sample_ms),
      persist_ms: Keyword.get(opts, :persist_ms, @default_persist_ms),
      sync_ms: Keyword.get(opts, :sync_ms, @default_sync_ms),
      staleness_ms: Keyword.get(opts, :staleness_ms, @default_staleness_ms),
      min_stw_mps: Keyword.get(opts, :min_stw_mps, @default_min_stw_mps),
      sender: Keyword.get(opts, :sender, &ChannelClient.send_calibration_update/2),
      now_fn: now_fn,
      legs_opts: legs_opts,
      tack_opts: tack_opts,
      awa_opts: Keyword.get(opts, :awa_estimator, []),
      stw_opts: Keyword.get(opts, :stw_estimator, []),
      aws_opts: Keyword.get(opts, :aws_estimator, []),
      # Raw intake: channel => {value, sensor_hex, mono_ms}.
      latest: %{},
      # NAME -> canonical hex cache (bus populations are small and stable).
      hex_cache: %{},
      # Detection state + the current window's {awa_hex, stw_hex} source stamp.
      legs: build_legs(legs_opts),
      tack: build_tack(tack_opts),
      window_sources: nil,
      # Per-sensor estimator instances (restored across reboots).
      awa_estimators: Map.get(persisted, :awa_estimators, %{}),
      stw_estimators: Map.get(persisted, :stw_estimators, %{}),
      aws_estimators: Map.get(persisted, :aws_estimators, %{}),
      # The previously APPLIED value per {hex, parameter} the slew limiter
      # continues from (restored so corrections keep creeping, never jump).
      prev_applied: Map.get(persisted, :prev_applied, %{}),
      # Parameter modes cached from Calibration.Config, refreshed on
      # {:racing_org_calibration, :updated}.
      modes: @default_modes,
      # Upstream sync bookkeeping: last-sent entry per {hex, parameter}
      # (changed-only), the batch pending since the last sync, and a monotonic seq.
      synced: %{},
      pending_sync: %{},
      seq: Map.get(persisted, :seq, 0),
      # Throttle clocks (anchored at boot) + the persist dirty flag.
      last_persist_ms: boot_ms,
      last_sync_ms: boot_ms,
      dirty_persist: false,
      stats: %{
        samples: 0,
        accepted: 0,
        rejected: 0,
        reject_reasons: %{},
        legs: 0,
        tack_pairs: 0,
        gybe_pairs: 0,
        reciprocal_pairs: 0,
        source_resets: 0
      }
    }

    subscribe_calibration(state)
    state = %{state | modes: fetch_modes(state)}

    schedule_tick(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, :ok, do_tick(state)}

  def handle_call(:persist_now, _from, state), do: {:reply, :ok, persist(state)}

  def handle_call(:sync_now, _from, state), do: {:reply, :ok, sync(state)}

  def handle_call(:latest, _from, state), do: {:reply, state.latest, state}

  def handle_call(:estimates, _from, state) do
    {:reply,
     %{
       awa: Map.new(state.awa_estimators, fn {hex, est} -> {hex, AwaOffset.snapshot(est)} end),
       stw: Map.new(state.stw_estimators, fn {hex, est} -> {hex, StwScale.snapshot(est)} end),
       aws: Map.new(state.aws_estimators, fn {hex, est} -> {hex, AwsScale.snapshot(est)} end)
     }, state}
  end

  def handle_call(:stats, _from, state), do: {:reply, build_stats(state), state}

  # --- Raw intake (VirtualDevice handler) ---
  #
  # Every decoded bus message lands here; non-matching data falls through to the
  # catch-all cheaply. Data WITHOUT a source NMEA NAME is dropped first: our own
  # broadcast frames carry no NAME, so this is also the own-output guard —
  # calibration can never fit against this device's own output.

  @impl true
  def handle_info({:data, %NMEA.Data{metadata: %{source_nmea_name: nil}}}, state), do: {:noreply, state}

  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{NMEA.WindParams => %NMEA.WindParams{speed: aws, angle: awa, reference: :apparent}},
           source_info: %NMEA.NMEA2000.Frame{timestamp_monotonic_ms: mono},
           metadata: %{source_nmea_name: name}
         }},
        state
      )
      when is_number(aws) and is_number(awa) and is_integer(mono) do
    {hex, state} = hex_for(state, name)
    awa_deg = WindTriangle.wrap180(awa * @deg_per_rad)
    latest = state.latest |> Map.put(:awa, {awa_deg, hex, mono}) |> Map.put(:aws, {aws / 1, hex, mono})
    {:noreply, %{state | latest: latest}}
  end

  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{
             NMEA.CourseParams => %NMEA.CourseParams{course: course},
             NMEA.SpeedParams => %NMEA.SpeedParams{speed: sog, speed_reference: :speed_over_ground}
           },
           source_info: %NMEA.NMEA2000.Frame{timestamp_monotonic_ms: mono},
           metadata: %{source_nmea_name: name}
         }},
        state
      )
      when is_number(course) and is_number(sog) and is_integer(mono) do
    {hex, state} = hex_for(state, name)
    cog_deg = WindTriangle.wrap360(course * @deg_per_rad)
    latest = state.latest |> Map.put(:cog, {cog_deg, hex, mono}) |> Map.put(:sog, {sog / 1, hex, mono})
    {:noreply, %{state | latest: latest}}
  end

  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{NMEA.SpeedParams => %NMEA.SpeedParams{speed: stw, speed_reference: :water}},
           source_info: %NMEA.NMEA2000.Frame{timestamp_monotonic_ms: mono},
           metadata: %{source_nmea_name: name}
         }},
        state
      )
      when is_number(stw) and is_integer(mono) do
    {hex, state} = hex_for(state, name)
    {:noreply, %{state | latest: Map.put(state.latest, :stw, {stw / 1, hex, mono})}}
  end

  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{NMEA.HeadingParams => %NMEA.HeadingParams{heading: heading}},
           source_info: %NMEA.NMEA2000.Frame{timestamp_monotonic_ms: mono},
           metadata: %{source_nmea_name: name}
         }},
        state
      )
      when is_number(heading) and is_integer(mono) do
    {hex, state} = hex_for(state, name)
    heading_deg = WindTriangle.wrap360(heading * @deg_per_rad)
    {:noreply, %{state | latest: Map.put(state.latest, :heading, {heading_deg, hex, mono})}}
  end

  def handle_info(
        {:data,
         %NMEA.Data{
           values: %{NMEA.AttitudeParams => %NMEA.AttitudeParams{roll: roll}},
           source_info: %NMEA.NMEA2000.Frame{timestamp_monotonic_ms: mono},
           metadata: %{source_nmea_name: name}
         }},
        state
      )
      when is_number(roll) and is_integer(mono) do
    {hex, state} = hex_for(state, name)
    {:noreply, %{state | latest: Map.put(state.latest, :heel, {roll * @deg_per_rad, hex, mono})}}
  end

  def handle_info({:data, _data}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = do_tick(state)
    schedule_tick(state)
    {:noreply, state}
  end

  # The calibration policy changed -> refresh the cached parameter modes ONCE.
  def handle_info({:racing_org_calibration, :updated}, state) do
    {:noreply, %{state | modes: fetch_modes(state)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Final flush so accumulated learning is not lost on shutdown.
    _ = persist(state)
    :ok
  end

  # --- The tick: sample -> single-source window -> detect -> estimate -> promote ---

  defp do_tick(state) do
    now = state.now_fn.()

    state =
      case build_sample(state, now) do
        {:ok, sample, awa_hex, stw_hex} ->
          state
          |> bump(:samples)
          |> bump(:accepted)
          |> ensure_single_source(awa_hex, stw_hex)
          |> feed(sample)

        {:reject, reason} ->
          state |> bump(:samples) |> tally_reject(reason)
      end

    state |> maybe_persist() |> maybe_sync()
  end

  # One Legs sample from the fresh `latest` values. AWA/AWS/STW/heading are
  # required (a leg cannot form without them); COG/SOG/heel ride along when
  # fresh, nil otherwise. TWS comes from the RAW wind triangle — never from the
  # (corrected) engine signals.
  defp build_sample(state, now) do
    with {:ok, awa, awa_hex} <- required(state, :awa, now, :no_awa),
         {:ok, aws, _hex} <- required(state, :aws, now, :no_aws),
         {:ok, stw, stw_hex} <- required(state, :stw, now, :no_stw),
         {:ok, heading, _hex} <- required(state, :heading, now, :no_heading),
         :ok <- moving(stw, state) do
      {tws, _twa} = WindTriangle.true_wind(aws, awa, stw)

      sample = %{
        t_ms: now,
        heading_deg: heading,
        cog_deg: optional(state, :cog, now),
        sog_mps: optional(state, :sog, now),
        stw_mps: stw,
        awa_deg: awa,
        aws_mps: aws,
        tws_mps: tws,
        heel_deg: optional(state, :heel, now)
      }

      {:ok, sample, awa_hex, stw_hex}
    end
  end

  defp required(state, key, now, reason) do
    case Map.get(state.latest, key) do
      {value, hex, mono} when now - mono <= state.staleness_ms -> {:ok, value, hex}
      _ -> {:reject, reason}
    end
  end

  defp optional(state, key, now) do
    case Map.get(state.latest, key) do
      {value, _hex, mono} when now - mono <= state.staleness_ms -> value
      _ -> nil
    end
  end

  defp moving(stw, %{min_stw_mps: min}) when stw >= min, do: :ok
  defp moving(_stw, _state), do: {:reject, :at_rest}

  # A leg must be single-source: when the AWA or STW sensor changes, FLUSH the
  # building window (its trailing events belong to — and are attributed to — the
  # OLD sensors) and restart detection clean under the new source stamp.
  defp ensure_single_source(%{window_sources: sources} = state, awa_hex, stw_hex)
       when sources == {awa_hex, stw_hex},
       do: state

  defp ensure_single_source(%{window_sources: nil} = state, awa_hex, stw_hex),
    do: %{state | window_sources: {awa_hex, stw_hex}}

  defp ensure_single_source(state, awa_hex, stw_hex) do
    {legs, events} = Legs.flush(state.legs)
    state = process_events(%{state | legs: legs}, events)

    %{
      state
      | legs: build_legs(state.legs_opts),
        tack: build_tack(state.tack_opts),
        window_sources: {awa_hex, stw_hex}
    }
    |> bump(:source_resets)
  end

  defp feed(state, sample) do
    {legs, events} = Legs.step(state.legs, sample)
    process_events(%{state | legs: legs}, events)
  end

  defp process_events(state, events), do: Enum.reduce(events, state, &process_event(&2, &1))

  # Every Legs event also feeds the tack detector (it ignores non-leg events).
  defp process_event(state, event) do
    {tack, tack_events} = Tack.step(state.tack, event)
    state = handle_leg_event(%{state | tack: tack}, event)
    Enum.reduce(tack_events, state, &handle_tack_event(&2, &1))
  end

  # A completed leg feeds the shadow-only AWS diagnostic, attributed to the
  # wind sensor (AWS and AWA come from the same instrument). AwsScale requires
  # the leg time as :t_end_s.
  defp handle_leg_event(state, {:leg, leg}) do
    {awa_hex, _stw_hex} = state.window_sources

    est =
      state.aws_estimators
      |> Map.get(awa_hex, AwsScale.new(state.aws_opts))
      |> AwsScale.observe_leg(leg |> Map.from_struct() |> Map.put(:t_end_s, leg.ended_ms / 1000))

    %{state | aws_estimators: Map.put(state.aws_estimators, awa_hex, est), dirty_persist: true}
    |> bump(:legs)
    |> publish_aws(awa_hex, est)
  end

  # A reciprocal course pair feeds the STW gain fit, attributed to the speed sensor.
  defp handle_leg_event(state, {:reciprocal_pair, %{a: a, b: b}}) do
    {_awa_hex, stw_hex} = state.window_sources

    est =
      state.stw_estimators
      |> Map.get(stw_hex, StwScale.new(state.stw_opts))
      |> StwScale.observe_pair(%{a: Map.from_struct(a), b: Map.from_struct(b)})

    %{state | stw_estimators: Map.put(state.stw_estimators, stw_hex, est), dirty_persist: true}
    |> bump(:reciprocal_pairs)
    |> publish_stw(stw_hex, est)
  end

  # A matched tack pair feeds the AWA rotation + upwash fits, attributed to the
  # wind sensor.
  defp handle_tack_event(state, {:tack_pair, %{starboard: stbd, port: port}}) do
    {awa_hex, _stw_hex} = state.window_sources

    est =
      state.awa_estimators
      |> Map.get(awa_hex, AwaOffset.new(state.awa_opts))
      |> AwaOffset.observe_pair(%{starboard: Map.from_struct(stbd), port: Map.from_struct(port)})

    %{state | awa_estimators: Map.put(state.awa_estimators, awa_hex, est), dirty_persist: true}
    |> bump(:tack_pairs)
    |> publish_awa_param(awa_hex, "awa_offset", est.rotation)
    |> publish_upwash(awa_hex, est)
  end

  # Gybe pairs are detected but not consumed by any v1 estimator.
  defp handle_tack_event(state, {:gybe_pair, _pair}), do: bump(state, :gybe_pairs)

  # --- Shadow -> promote (put_learned with the honest state) ---

  # Record an AWA-parameter tracker's current estimate: "learning" until
  # validated; "shadow" when validated under a shadow mode; "applied" (the
  # clamped, SLEW-limited value continuing from prev_applied) when validated
  # under auto. Config's locks always win over whatever we record here.
  defp publish_awa_param(state, hex, param, tracker) do
    snap = Estimate.snapshot(tracker)

    if is_number(snap.value) do
      {entry, state} = promote(state, hex, param, tracker, snap)

      state
      |> put_learned(hex, param, entry)
      |> record_sync(hex, param, %{
        hardware_identifier: hex,
        parameter: param,
        value: entry.value,
        confidence: entry.confidence,
        sample_count: entry.sample_count,
        state: entry.state,
        residual: snap.spread
      })
    else
      state
    end
  end

  defp promote(state, hex, param, tracker, snap) do
    base = %{confidence: snap.confidence, sample_count: snap.sample_count}

    case {snap.state, mode(state, param)} do
      {:validated, "auto"} ->
        prev = Map.get(state.prev_applied, {hex, param}, 0.0)
        {applied, _tracker} = Estimate.applied_value(tracker, prev)
        entry = Map.merge(base, %{value: applied, state: "applied"})
        {entry, %{state | prev_applied: Map.put(state.prev_applied, {hex, param}, applied), dirty_persist: true}}

      {:validated, "shadow"} ->
        {Map.merge(base, %{value: snap.value, state: "shadow"}), state}

      {:validated, _off_or_unknown} ->
        {Map.merge(base, %{value: snap.value, state: "validated"}), state}

      {_learning, _mode} ->
        {Map.merge(base, %{value: snap.value, state: "learning"}), state}
    end
  end

  # UpwashBands' backbone anchor (6.17 m/s = 12 kn): the sync entry's scalar
  # representative is the published curve point nearest this TWS.
  @upwash_anchor_mps 6.17

  # Record the TWS-banded upwash fit. While the published curve is empty this
  # is TODAY'S scalar path — the GLOBAL upwash tracker through the
  # Estimate.applied_value slew (unchanged legacy behavior). Once the curve
  # publishes, the learned value is the `[{center_mps, deg}]` list itself,
  # promoted per mode with NO slew (the curve is already shrunk + clamped,
  # mirroring stw_scale's gain_curve); sample_count sums the published bands'
  # trackers and confidence is their minimum. The sync entry carries the
  # representative scalar (the curve point nearest #{@upwash_anchor_mps} m/s)
  # as `value` plus the full curve as `[%{center:, value:}]` maps — the
  # backend expects `value` keys for awa_upwash (stw curves use `gain`).
  defp publish_upwash(state, hex, est) do
    snap = AwaOffset.snapshot(est)

    case snap.upwash_curve do
      [] ->
        publish_awa_param(state, hex, "awa_upwash", est.upwash)

      curve ->
        published = Enum.map(curve, fn {center, _deg} -> snap.upwash_bands[center] end)
        sample_count = published |> Enum.map(& &1.sample_count) |> Enum.sum()
        confidence = published |> Enum.map(& &1.confidence) |> Enum.min()

        state_s =
          case mode(state, "awa_upwash") do
            "auto" -> "applied"
            "shadow" -> "shadow"
            _ -> "validated"
          end

        entry = %{value: curve, confidence: confidence, sample_count: sample_count, state: state_s}
        {rep_center, rep_value} = Enum.min_by(curve, fn {center, _deg} -> abs(center - @upwash_anchor_mps) end)

        state
        |> put_learned(hex, "awa_upwash", entry)
        |> record_sync(hex, "awa_upwash", %{
          hardware_identifier: hex,
          parameter: "awa_upwash",
          value: rep_value,
          confidence: confidence,
          sample_count: sample_count,
          state: state_s,
          residual: snap.upwash_bands[rep_center].spread,
          curve: Enum.map(curve, fn {center, deg} -> %{center: center, value: deg} end)
        })
    end
  end

  # Record the STW gain fit. While learning the value is the most-sampled band's
  # raw RLS gain (a float — honest, never applied by Config); once any band
  # validates, the value is the estimator's validated + clamped gain_curve,
  # promoted to "applied" only under auto mode (the curve itself is already the
  # safe, clamped applied form — no additional slew). The sync entry carries the
  # representative gain (the curve's most-sampled band) plus the full curve.
  defp publish_stw(state, hex, est) do
    %{bands: bands} = StwScale.snapshot(est)

    if map_size(bands) == 0 do
      state
    else
      curve = StwScale.gain_curve(est)
      {rep_center, rep} = representative_band(bands, curve)

      {entry, sync_value} =
        case curve do
          [] ->
            {%{
               value: rep.rls,
               confidence: rep.estimate.confidence,
               sample_count: rep.estimate.sample_count,
               state: "learning"
             }, rep.rls}

          _validated ->
            sample_count =
              curve
              |> Enum.map(fn {center, _gain} -> bands[center].estimate.sample_count end)
              |> Enum.sum()

            state_s =
              case mode(state, "stw_scale") do
                "auto" -> "applied"
                "shadow" -> "shadow"
                _ -> "validated"
              end

            {gain} = {curve |> Enum.find(fn {center, _} -> center == rep_center end) |> elem(1)}

            {%{value: curve, confidence: rep.estimate.confidence, sample_count: sample_count, state: state_s}, gain}
        end

      state
      |> put_learned(hex, "stw_scale", entry)
      |> record_sync(hex, "stw_scale", %{
        hardware_identifier: hex,
        parameter: "stw_scale",
        value: sync_value,
        confidence: entry.confidence,
        sample_count: entry.sample_count,
        state: entry.state,
        residual: rep.estimate.spread,
        curve: Enum.map(curve, fn {center, gain} -> %{center: center, gain: gain} end)
      })
    end
  end

  # The band whose estimate carries the most evidence — among the VALIDATED
  # bands when a curve exists, else among all bands.
  defp representative_band(bands, []) do
    Enum.max_by(bands, fn {_center, band} -> band.estimate.sample_count end)
  end

  defp representative_band(bands, curve) do
    bands
    |> Map.take(Enum.map(curve, &elem(&1, 0)))
    |> Enum.max_by(fn {_center, band} -> band.estimate.sample_count end)
  end

  # Record the shadow-only AWS diagnostic (never "applied": its mode maxes out
  # at shadow and Config never compiles it either way).
  defp publish_aws(state, hex, est) do
    snap = AwsScale.snapshot(est).downwind_over_upwind_ratio

    if is_number(snap.value) do
      state_s =
        case {snap.state, mode(state, "aws_scale")} do
          {:validated, "shadow"} -> "shadow"
          {:validated, _} -> "validated"
          {_learning, _} -> "learning"
        end

      entry = %{value: snap.value, confidence: snap.confidence, sample_count: snap.sample_count, state: state_s}

      state
      |> put_learned(hex, "aws_scale", entry)
      |> record_sync(hex, "aws_scale", %{
        hardware_identifier: hex,
        parameter: "aws_scale",
        value: snap.value,
        confidence: snap.confidence,
        sample_count: snap.sample_count,
        state: state_s,
        residual: snap.spread
      })
    else
      state
    end
  end

  defp mode(state, param), do: Map.get(state.modes, param, "off")

  # Best-effort promotion into Calibration.Config (the enforcement point:
  # locks win, and only applied+auto entries ever compile into corrections).
  defp put_learned(%{calibration: nil} = state, _hex, _param, _entry), do: state

  defp put_learned(%{calibration: {module, server}} = state, hex, param, entry) do
    case module.put_learned(server, hex, param, entry) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Calibration.Observer] put_learned #{param} for #{hex} rejected: #{inspect(reason)}")
    end

    state
  catch
    :exit, _ -> state
  end

  # --- Upstream sync (throttled / changed-only / batched) ---

  defp record_sync(state, hex, param, entry) do
    key = {hex, param}

    if Map.get(state.synced, key) == entry do
      state
    else
      %{state | pending_sync: Map.put(state.pending_sync, key, entry)}
    end
  end

  defp maybe_sync(state) do
    if due?(state.last_sync_ms, state.sync_ms, state) and map_size(state.pending_sync) > 0 do
      sync(state)
    else
      state
    end
  end

  defp sync(%{pending_sync: pending} = state) when map_size(pending) == 0, do: state

  defp sync(state) do
    seq = state.seq + 1

    entries =
      state.pending_sync
      |> Map.values()
      |> Enum.sort_by(&{&1.hardware_identifier, &1.parameter})

    update = %{boat_identifier: state.boat_identifier, seq: seq, entries: entries}
    _ = safe_send(state.sender, update)

    %{
      state
      | synced: Map.merge(state.synced, state.pending_sync),
        pending_sync: %{},
        last_sync_ms: state.now_fn.(),
        seq: seq,
        dirty_persist: true
    }
  end

  defp safe_send(sender, update) do
    sender.(ChannelClient, update)
  rescue
    error -> Logger.warning("[Calibration.Observer] calibration sync failed: #{inspect(error)}")
  catch
    :exit, _ -> :ok
  end

  # --- Throttled persistence ---

  defp maybe_persist(state) do
    if due?(state.last_persist_ms, state.persist_ms, state) and state.dirty_persist do
      persist(state)
    else
      state
    end
  end

  defp persist(%{dir: nil} = state), do: %{state | dirty_persist: false}
  defp persist(%{dirty_persist: false} = state), do: state

  defp persist(state) do
    _ =
      Store.save(state.dir, %{
        awa_estimators: state.awa_estimators,
        stw_estimators: state.stw_estimators,
        aws_estimators: state.aws_estimators,
        prev_applied: state.prev_applied,
        seq: state.seq
      })

    %{state | dirty_persist: false, last_persist_ms: state.now_fn.()}
  end

  defp restore(nil), do: %{}

  defp restore(dir) do
    case Store.load(dir) do
      {:ok, persisted} -> persisted
      :empty -> %{}
    end
  end

  # --- Calibration.Config collaborator (modes cache + subscription) ---

  defp normalize_calibration(nil), do: nil
  defp normalize_calibration({module, server}) when is_atom(module), do: {module, server}
  defp normalize_calibration(module) when is_atom(module), do: {module, module}

  defp subscribe_calibration(%{calibration: nil}), do: :ok

  defp subscribe_calibration(%{calibration: {module, server}}) do
    if function_exported?(module, :subscribe, 2) do
      module.subscribe(server, self())
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp fetch_modes(%{calibration: nil}), do: @default_modes

  defp fetch_modes(%{calibration: {module, server}}) do
    case module.status(server) do
      %{modes: %{} = modes} -> Map.merge(@default_modes, modes)
      _ -> @default_modes
    end
  catch
    :exit, _ -> @default_modes
  end

  # --- helpers ---

  # NAME -> canonical hex, cached (a bus carries a small, stable NAME population,
  # so the cache is bounded in practice).
  defp hex_for(state, name) do
    case Map.get(state.hex_cache, name) do
      nil ->
        hex = NmeaIdentity.canonical_hardware_id(name)
        {hex, %{state | hex_cache: Map.put(state.hex_cache, name, hex)}}

      hex ->
        {hex, state}
    end
  end

  defp bump(state, :samples), do: %{state | stats: Map.update!(state.stats, :samples, &(&1 + 1))}
  defp bump(state, key), do: %{state | stats: Map.update!(state.stats, key, &(&1 + 1))}

  # The tick counters plus the upwash rejection counters, which live inside the
  # per-sensor estimators (summed across AWA sensors at read time — stats is
  # never on the intake hot path).
  defp build_stats(state) do
    {screened, excluded_light} =
      Enum.reduce(state.awa_estimators, {0, 0}, fn {_hex, est}, {screened, excluded} ->
        snap = AwaOffset.snapshot(est)
        {screened + snap.screened, excluded + snap.excluded_light}
      end)

    Map.merge(state.stats, %{screened: screened, excluded_light: excluded_light})
  end

  defp tally_reject(state, reason) do
    stats =
      state.stats
      |> Map.update!(:rejected, &(&1 + 1))
      |> Map.update!(:reject_reasons, &Map.update(&1, reason, 1, fn c -> c + 1 end))

    %{state | stats: stats}
  end

  # A throttle is "due" once `interval` ms have elapsed since the last fire (the
  # clocks are anchored at boot, so even the first fire waits a full interval).
  defp due?(last_ms, interval, state), do: state.now_fn.() - last_ms >= interval

  defp schedule_tick(%{sample_ms: ms}) when ms > 0, do: Process.send_after(self(), :tick, ms)
  defp schedule_tick(_state), do: :ok

  defp build_legs(%Legs{} = legs), do: legs
  defp build_legs(opts) when is_list(opts), do: Legs.new(opts)

  defp build_tack(%Tack{} = tack), do: tack
  defp build_tack(opts) when is_list(opts), do: Tack.new(opts)
end
