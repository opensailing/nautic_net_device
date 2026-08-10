defmodule RacingOrg.Tracker.Pro.WindShift.Observer do
  @moduledoc """
  The wind-shift predictor's integration layer: a `Polar.Observer`-pattern
  GenServer that ticks at ~1 Hz off the compute engine's signals, drives the
  pure wind-shift cores (`Means` / `Envelope` / `Cycle` / `Period` /
  `StepDetect` / `Classifier` — the exact wiring the acceptance suite defines),
  and fans the results out three ways:

    1. **Engine signals** (`Compute.Engine.put_signals/3`, one batched message
       per tick) so displays/expressions/streamback can consume them;
    2. **B&G bus** — PGN 130824 keys 336/337/338 (`average_twd` /
       `wind_phase_deg` / `wind_lift_deg`) at 1 Hz via the injectable transmit
       fn (mirroring `Compute.RaceTimerBroadcaster`), only while values are
       valid;
    3. **Backend sync** — a throttled (60 s), changed-only
       `"wind_shift_update"` batch through
       `ChannelClient.send_wind_shift_update/2` (best-effort + session-gated,
       exactly like the calibration observer's sync).

  ## The 1 Hz tick

  Each tick reads `Compute.Engine.signals/0` ONCE (injectable `:signals_fn`).
  `true_wind_direction` is REQUIRED and must be fresh (≤ `:staleness_ms`); a
  missing/stale tick is skipped and tallied (`stats/1`, mirroring
  `Polar.Observer`). `true_wind_speed` / `true_wind_angle` / `latitude` /
  `longitude` ride along when fresh, `nil` otherwise. Per accepted tick the
  cores advance exactly as in the acceptance harness: incremental unwrap of
  TWD → `Means.update` + `Envelope.update` (raw TWD), `Cycle.step` (unwrapped),
  `StepDetect.step` (wrap-aware deviation from the slow mean); the residual
  `unwrapped − cycle.level` feeds a 30-minute ring (a bounded `:queue`, never a
  list append) from which `Period.estimate/1` re-runs every ~60 s, retuning the
  cycle + step detector when confidence ≥ 0.5.

  ## Wind lift (tack-resolved phase)

  `Means.snapshot.phase_deg` is positive when VEERED right of the reference.
  On starboard tack (signed TWA ≥ 0, wind over the starboard side —
  `Compute.Library.resolve_twa` semantics) a veer is a LIFT; on port tack a
  back is the lift. So `wind_lift_deg = phase_deg × tack_sign` with tack_sign
  +1 starboard / −1 port from the sign of the resolved TWA — the live
  `true_wind_angle` signal when fresh, else `wrap180(true_wind_direction −
  heading)` (the same fallback `Compute.Library.resolve_twa` uses, so boats
  publishing direction + speed but no angle still get the lift). When neither
  resolves the lift is simply omitted (the phase still flows).

  ## Engine signals (numeric only) and the regime code

  Signals are numbers, so the regime is published as a small integer code:

      0 insufficient_history | 1 calm | 2 oscillating
      3 persistent_ramp      | 4 persistent_step | 5 mixed

  Batch per tick (a value that is currently `nil` is omitted): `average_twd`
  (slow mean), `wind_phase_deg`, `wind_lift_deg`, `twd_range_deg`,
  `twd_trend_deg_per_hr`, `oscillation_period_s`, `oscillation_amplitude_deg`,
  `time_to_next_shift_s`, `shift_confidence` (0–100), `wind_regime` (code),
  and `wally_mode` (0 off / 1 shadow / 2 on — the cached `WindShift.Config`
  policy as `RacingOrg.Tracker.Pro.WindShift.Wally.mode_code/1`, threading the
  Wally mode into the pure `target_boat_speed`/`target_twa` calcs with zero
  new plumbing).

  ## Session, timeline, events (the `"wind_shift_update"` batch)

  Session identity is `started_at_ms` — the WALL-clock time (injectable
  `:utc_now_fn`) of the first valid wind sample after boot/day-start, persisted
  via `Observer.Store` so a mid-day reboot keeps the same session (a snapshot
  from a PREVIOUS UTC day starts a fresh session; `seq` stays monotonic either
  way). A device powered THROUGH midnight UTC rotates the same way mid-run:
  the old session is flushed with a final sync under its own identity, then a
  fresh session (fresh centroid/summary accumulators) starts on the next
  accepted tick — `seq` continues monotonically across the rotation. The session also carries a running position centroid and TWS mean, and
  `race_session_id` is read from the active assignment once per sync (never on
  the tick hot path). Timeline rows accumulate every 60 s; events fire on
  envelope alarms (`new_high`/`new_low`, suppressed when the config disables
  alarms), confirmed steps (`step`, onset backdated), regime changes
  (`regime_change`), and oscillation extrema (`header_extreme`/`lift_extreme`
  via hysteresis zero crossings of the phase — the extreme of the half-cycle
  just ended, tack-resolved like the lift; skipped when the tack is unknown).

  A sync goes out at most every `:sync_ms` and ONLY when there is something
  new (pending timeline/events) or the session summary changed — nothing new
  AND an unchanged summary is skipped entirely.

  ## Persistence / reboot semantics

  Only the session identity + not-yet-synced batch persists (throttled to
  `:persist_ms` + a terminate flush). The cores deliberately restart fresh
  after a reboot: a mid-day reboot loses the ~20 min model warmup (the
  classifier honestly reports `:insufficient_history` again) but session
  continuity is preserved — see `Observer.Store`.

  ## Config reaction

  Subscribes to `WindShift.Config`; when a new policy lands with CHANGED
  windows/alarm margin the cores are REBUILT. This resets the predictor's
  warmup (accepted — a window change redefines every mean, so carrying old
  filter state across would be dishonest); the session and sync sequence carry
  over untouched. A WALLY-MODE-ONLY change does NOT rebuild (the mode shapes
  no core): flipping Wally on/shadow/off mid-race keeps the live oscillation
  verdict, so the target modulation engages/reverts on the very next tick.
  `alarms.enabled` is live-only the same way — per-tick event suppression
  reads it — so toggling alarms mid-run never costs the warmup either.

  ## Step absorption

  A confirmed step freezes the detector and pins `:persistent_step` (the
  classifier override). Once the SLOW reference has absorbed the new direction
  — `|phase_deg|` inside the detector's revert band for 60 consecutive
  accepted ticks (~2.7·τ_slow ≈ 68 min after a 30° front at defaults) — the
  detector is reset so the next front can be caught. The regime change back
  out of `:persistent_step` is emitted like any other.

  ## `near_mark_s` (v2)

  The classifier accepts a seconds-to-mark hint (`treat_as_persistent` near a
  rounding). Deriving it needs the active assignment + position + VMG on every
  tick (`Nav.State.derive/2` requires a per-tick `Commands` fetch — NOT
  trivially cheap), so v1 passes `nil` and the near-mark policy stays inert.
  Documented as v2: wire it when `Nav` exposes a cached distance-to-mark.
  """

  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.Calibration.Detect.Circular
  alias RacingOrg.Tracker.Pro.Compute.Engine
  alias RacingOrg.Tracker.Pro.Compute.PgnEncode
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient
  alias RacingOrg.Tracker.Pro.WindShift.Classifier
  alias RacingOrg.Tracker.Pro.WindShift.Config
  alias RacingOrg.Tracker.Pro.WindShift.Cycle
  alias RacingOrg.Tracker.Pro.WindShift.Envelope
  alias RacingOrg.Tracker.Pro.WindShift.Means
  alias RacingOrg.Tracker.Pro.WindShift.Observer.Store
  alias RacingOrg.Tracker.Pro.WindShift.Period
  alias RacingOrg.Tracker.Pro.WindShift.StepDetect
  alias RacingOrg.Tracker.Pro.WindShift.Wally

  @default_sample_ms 1_000
  @default_persist_ms 60_000
  @default_sync_ms 60_000
  @default_timeline_ms 60_000
  @max_finite 1.7976931348623157e308
  # A TWD older than this (ms of monotonic time) cannot drive the predictor.
  @default_staleness_ms 3_000

  # Residual ring for Period: last 30 min at 1 Hz (the acceptance harness value).
  @resid_window 1800
  # Re-estimate the oscillation period once a minute (the acceptance harness value).
  @period_every_ms 60_000

  # Hysteresis for the extrema zero-crossing tracker (deg of phase deviation) —
  # matches the default envelope alarm margin.
  @xing_hysteresis_deg 2.0
  # Consecutive accepted ticks with |phase| inside the step detector's revert
  # band before a confirmed step is considered ABSORBED by the slow reference.
  @absorb_dwell_ticks 60

  # B&G broadcast: PGN 130824, broadcast, priority 2, 1 Hz (like the race timer).
  @pgn 130_824
  @priority 2
  @rate_ms 1_000
  @bandg_fields ~w(average_twd wind_phase_deg wind_lift_deg)

  # Safe defaults matching WindShift.Config's — used only until (or unless) the
  # Config collaborator can be read.
  @default_windows %{fast_s: 30.0, mid_s: 300.0, slow_s: 1500.0, envelope_s: 1800.0}
  @default_alarms %{new_extreme_margin_deg: 2.0, enabled: true}

  @regime_codes %{
    insufficient_history: 0,
    calm: 1,
    oscillating: 2,
    persistent_ramp: 3,
    persistent_step: 4,
    mixed: 5
  }

  # --- Client API ---

  @doc """
  Start the Observer.

  Options:

    * `:name` — registered name (default `__MODULE__`; pass `nil` for anonymous).
    * `:dir` — persistence directory (`observer.wind_shift`). `nil` (the
      host/test default) DISABLES persistence.
    * `:boat_identifier` — stable device/boat id stamped on every sync (default
      `RacingOrg.Tracker.Pro.boat_identifier/0`).
    * `:config` — the `WindShift.Config` collaborator the policy is read from:
      `{module, server}` or a bare module (default
      `RacingOrg.Tracker.Pro.WindShift.Config`); `nil` runs the built-in defaults.
    * `:commands` — the `Commands` collaborator `race_session_id` is read from at
      sync time (default `RacingOrg.Tracker.Pro.Commands`); `nil` disables.
    * `:sample_ms` — sampling period (default `1000`). `0` disables the timer
      (tests drive `tick/1` directly).
    * `:persist_ms` / `:sync_ms` / `:timeline_ms` — throttles (all default `60_000`).
    * `:staleness_ms` — maximum age of the TWD signal (default `3_000`).
    * `:signals_fn` — 0-arity fn returning the raw-signal map (default reads
      `Compute.Engine.signals/0`). Injectable for tests.
    * `:put_signals_fn` — 2-arity fn `(batch, mono_ms)` publishing the tick's
      signal batch (default `Compute.Engine.put_signals/3`). Injectable.
    * `:transmit_fn` — 3-arity fn `(priority, pgn, payload)` for the B&G frames
      (default the NMEA 2000 VirtualDevice broadcast, mirroring
      `RaceTimerBroadcaster`); `:broadcast_enabled` (default `true`) disables it.
    * `:sender` — 2-arity fn `(channel_client_module, update)` used to emit a
      sync (default `&ChannelClient.send_wind_shift_update/2`). Injectable.
    * `:now_fn` — 0-arity monotonic-ms clock (default `System.monotonic_time/1`).
    * `:utc_now_fn` — 0-arity wall clock (default `&DateTime.utc_now/0`); stamps
      the session identity, timeline rows, and events.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc "Run one sample→cores→publish tick synchronously; returns `:ok`."
  @spec tick(GenServer.server()) :: :ok
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @doc "Persist the session state now (throttling is bypassed); returns `:ok`."
  @spec persist_now(GenServer.server()) :: :ok
  def persist_now(server \\ __MODULE__), do: GenServer.call(server, :persist_now)

  @doc "Emit a sync now if there is anything to send (throttling is bypassed); returns `:ok`."
  @spec sync_now(GenServer.server()) :: :ok
  def sync_now(server \\ __MODULE__), do: GenServer.call(server, :sync_now)

  @doc """
  The LIVE half of the channel's `"wind_shift_status"` reply: `%{regime,
  confidence, oscillation_period_s, oscillation_amplitude_deg,
  trend_deg_per_hr, wind_phase_deg, wind_lift_deg, twd_range_deg, status}`.
  The policy half (`applied_version` + `wally_mode`) comes from
  `WindShift.Config.status/1`; the channel composes the two.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "The current session identity (`%{started_at_ms, centroid}`), or `nil` before the first valid sample."
  @spec session(GenServer.server()) :: map() | nil
  def session(server \\ __MODULE__), do: GenServer.call(server, :session)

  @doc "Observability: `%{samples, accepted, rejected, reject_reasons}` (reject reasons `:no_twd` | `:stale_twd`)."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @doc """
  The integer code the `wind_regime` engine signal carries (signals are
  numeric): 0 insufficient_history, 1 calm, 2 oscillating, 3 persistent_ramp,
  4 persistent_step, 5 mixed.
  """
  @spec regime_code(Classifier.regime()) :: 0..5
  def regime_code(regime), do: Map.fetch!(@regime_codes, regime)

  # --- Server ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    dir = Keyword.get(opts, :dir)
    now_fn = Keyword.get(opts, :now_fn, fn -> System.monotonic_time(:millisecond) end)
    utc_now_fn = Keyword.get(opts, :utc_now_fn, &DateTime.utc_now/0)
    config = normalize_collaborator(Keyword.get(opts, :config, Config))
    # Anchor the throttle clocks at boot so the FIRST persist/sync/timeline row
    # must also wait a full interval (mirrors Polar.Observer).
    boot_ms = now_fn.()
    persisted = restore(dir, utc_now_fn)

    state =
      %{
        dir: dir,
        boat_identifier: Keyword.get_lazy(opts, :boat_identifier, &RacingOrg.Tracker.Pro.boat_identifier/0),
        config: config,
        commands: normalize_collaborator(Keyword.get(opts, :commands, RacingOrg.Tracker.Pro.Commands)),
        sample_ms: Keyword.get(opts, :sample_ms, @default_sample_ms),
        persist_ms: Keyword.get(opts, :persist_ms, @default_persist_ms),
        sync_ms: Keyword.get(opts, :sync_ms, @default_sync_ms),
        timeline_ms: Keyword.get(opts, :timeline_ms, @default_timeline_ms),
        staleness_ms: Keyword.get(opts, :staleness_ms, @default_staleness_ms),
        signals_fn: Keyword.get(opts, :signals_fn, fn -> safe_signals() end),
        put_signals_fn: Keyword.get(opts, :put_signals_fn, &Engine.put_signals/2),
        transmit: Keyword.get(opts, :transmit_fn, &default_transmit/3),
        broadcast_enabled: Keyword.get(opts, :broadcast_enabled, true),
        sender: Keyword.get(opts, :sender, &ChannelClient.send_wind_shift_update/2),
        now_fn: now_fn,
        utc_now_fn: utc_now_fn,
        # Policy (from WindShift.Config; safe defaults until readable).
        windows: @default_windows,
        alarms: @default_alarms,
        wally_mode_code: 0,
        # Session identity + upstream sync bookkeeping (restored across reboots).
        session: Map.get(persisted, :session),
        seq: Map.get(persisted, :seq, 0),
        pending_timeline: Map.get(persisted, :pending_timeline, []),
        pending_events: Map.get(persisted, :pending_events, []),
        last_summary: Map.get(persisted, :last_summary),
        # Throttle clocks (anchored at boot) + persist dirty flag + tx limiter.
        last_persist_ms: boot_ms,
        last_sync_ms: boot_ms,
        last_timeline_ms: boot_ms,
        last_tx_ms: nil,
        dirty_persist: false,
        stats: %{samples: 0, accepted: 0, rejected: 0, reject_reasons: %{}}
      }
      |> put_policy(fetch_policy(config))
      |> build_cores()

    subscribe_config(config)
    schedule_tick(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, :ok, do_tick(state)}

  def handle_call(:persist_now, _from, state), do: {:reply, :ok, persist(state)}

  def handle_call(:sync_now, _from, state), do: {:reply, :ok, sync(state)}

  def handle_call(:status, _from, state), do: {:reply, build_status(state), state}

  def handle_call(:session, _from, state), do: {:reply, session_view(state.session), state}

  def handle_call(:stats, _from, state), do: {:reply, state.stats, state}

  @impl true
  def handle_info(:tick, state) do
    state = do_tick(state)
    schedule_tick(state)
    {:noreply, state}
  end

  # The wind-shift policy changed -> refetch it, and REBUILD the cores ONLY when
  # the core-shaping half (windows / alarm margin) actually changed. The warmup
  # reset is accepted for those (a window change redefines every mean), but a
  # WALLY-MODE-ONLY flip must NOT rebuild: toggling Wally mid-race keeps the
  # live oscillation verdict, so engagement/reversion is immediate and
  # glitch-free. `alarms.enabled` is a LIVE-ONLY flag exactly the same way —
  # per-tick event suppression reads it off the state, no core carries it — so
  # toggling alarms mid-run must not cost the ~20 min warmup either.
  # Session/seq/pending batches carry over either way.
  def handle_info({:racing_org_wind_shift, :updated}, state) do
    policy = fetch_policy(state.config)

    rebuild? =
      policy.windows != state.windows or
        policy.alarms.new_extreme_margin_deg != state.alarms.new_extreme_margin_deg

    state = put_policy(state, policy)
    {:noreply, if(rebuild?, do: build_cores(state), else: state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Final flush so the session identity + unsynced batch survive shutdown.
    _ = persist(state)
    :ok
  end

  # --- The tick: sample -> cores -> classify -> events/timeline -> publish ---

  defp do_tick(state) do
    now = state.now_fn.()
    signals = state.signals_fn.()

    state =
      case fetch_twd(signals, now, state.staleness_ms) do
        {:ok, twd} ->
          state |> bump(:samples) |> bump(:accepted) |> accept(signals, twd, now)

        {:error, reason} ->
          state |> bump(:samples) |> tally_reject(reason)
      end

    state |> maybe_persist() |> maybe_sync()
  end

  defp accept(state, signals, twd, now) do
    tws = optional_fresh(signals, "true_wind_speed", now, state.staleness_ms, &valid_tws?/1)
    twa = resolve_twa(signals, twd, now, state.staleness_ms)
    lat = optional_fresh(signals, "latitude", now, state.staleness_ms, &valid_latitude?/1)
    lon = optional_fresh(signals, "longitude", now, state.staleness_ms, &valid_longitude?/1)
    wall_ms = DateTime.to_unix(state.utc_now_fn.(), :millisecond)

    state =
      state
      |> ensure_session(wall_ms)
      |> fold_session(lat, lon, tws)
      |> step_cores(twd, now)
      |> maybe_estimate_period(now)

    means_snap = Means.snapshot(state.means)
    env_snap = Envelope.snapshot(state.envelope)
    step_snap = StepDetect.snapshot(state.step)

    verdict =
      Classifier.classify(%{
        means: means_snap,
        envelope: env_snap,
        cycle: Cycle.snapshot(state.cycle),
        period: state.period,
        step: step_snap,
        history_s: (now - state.t0_ms) / 1000.0,
        tws_mps: tws,
        # v2: seconds to the next mark rounding (needs a cached Nav distance).
        near_mark_s: nil
      })

    tack = tack_sign(twa)
    lift = if is_number(means_snap.phase_deg) and is_number(tack), do: means_snap.phase_deg * tack

    state = %{state | last_verdict: verdict, last_lift: lift, last_tack: tack, dirty_persist: true}

    state
    |> detect_events(verdict, means_snap, env_snap, step_snap, twd, wall_ms, now)
    |> maybe_absorb(means_snap, step_snap)
    |> maybe_timeline_row(verdict, means_snap, tws, wall_ms, now)
    |> publish_signals(verdict, means_snap, env_snap, lift, now)
    |> maybe_broadcast(means_snap, lift, now)
  end

  # --- Cores (the acceptance-harness wiring, verbatim) ---

  defp step_cores(state, twd, now) do
    unwrapped =
      case state.unwrap do
        nil -> twd / 1
        {last_in, last_un} -> last_un + Circular.wrapped_delta(last_in, twd)
      end

    dt_s = if state.last_t_ms, do: max((now - state.last_t_ms) / 1000.0, 1.0e-3), else: 1.0

    means = Means.update(state.means, twd, now)
    envelope = Envelope.update(state.envelope, twd, now)
    cycle = Cycle.step(state.cycle, unwrapped, dt_s)

    # Residual for the period estimator: observation minus the structural level
    # (trend removed by the filter), i.e. cycle + noise.
    resid = unwrapped - Cycle.snapshot(cycle).level_deg

    # Residual for step detection: wrap-aware deviation from the slow mean.
    step_resid = Circular.wrapped_delta(Means.snapshot(means).slow, twd)
    step = StepDetect.step(state.step, step_resid, now)

    %{
      state
      | means: means,
        envelope: envelope,
        cycle: cycle,
        step: step,
        unwrap: {twd / 1, unwrapped},
        resid: ring_push(state.resid, resid),
        t0_ms: state.t0_ms || now,
        last_t_ms: now
    }
  end

  # Bounded FIFO ring (a :queue + count, never a list append on the hot path).
  defp ring_push({queue, n}, value) do
    queue = :queue.in(value, queue)
    if n + 1 > @resid_window, do: {:queue.drop(queue), n}, else: {queue, n + 1}
  end

  defp maybe_estimate_period(state, now) do
    if state.last_period_ms == nil or now - state.last_period_ms >= @period_every_ms do
      {queue, _n} = state.resid
      estimate = Period.estimate(:queue.to_list(queue))
      state = %{state | period: estimate, last_period_ms: now}

      case estimate do
        %{period_s: period_s, confidence: conf} when conf >= 0.5 ->
          %{state | cycle: Cycle.retune(state.cycle, period_s), step: StepDetect.put_period_hint(state.step, period_s)}

        _ ->
          state
      end
    else
      state
    end
  end

  # --- Session (identity + running centroid / TWS mean) ---

  defp ensure_session(%{session: nil} = state, wall_ms), do: start_session(state, wall_ms)

  # A device powered through midnight UTC must not accumulate one multi-day
  # session: once the wall clock's UTC date has advanced past the session's,
  # the old session is ROTATED — flushed with a final sync under its own
  # identity (throttle bypassed), then a fresh identity starts with fresh
  # centroid/summary accumulators. `seq` continues monotonically across the
  # rotation (the flush increments it; the backend orders per boat by seq).
  defp ensure_session(%{session: %{started_at_ms: started_ms}} = state, wall_ms) do
    if Date.compare(utc_date(wall_ms), utc_date(started_ms)) == :gt do
      rotate_session(state, wall_ms)
    else
      state
    end
  end

  defp start_session(state, wall_ms) do
    Logger.info("[WindShift.Observer] wind-shift session started (started_at_ms=#{wall_ms})")

    %{
      state
      | session: %{started_at_ms: wall_ms, lat_sum: 0.0, lon_sum: 0.0, pos_n: 0, tws_sum: 0.0, tws_n: 0},
        dirty_persist: true
    }
  end

  defp rotate_session(state, wall_ms) do
    Logger.info("[WindShift.Observer] UTC day rollover: rotating the wind-shift session")
    state = sync(state)

    # The flush can only be skipped while no verdict exists yet (a batch
    # restored at boot, rotated before the first classified tick). Old-day rows
    # must never attach to the new session, so they are dropped — the same
    # policy restore/2 applies to a previous-day snapshot at boot.
    if state.pending_timeline != [] or state.pending_events != [] do
      Logger.warning("[WindShift.Observer] dropping unsynced previous-day rows at UTC rollover")
    end

    # last_summary resets so the new session's FIRST sync always goes out. A
    # candidate or confirmed step is session-scoped because its onset wall time
    # is derived from the detector's monotonic onset. Re-arm it at rotation so a
    # later confirmation cannot backdate into the previous UTC session.
    %{
      state
      | session: nil,
        pending_timeline: [],
        pending_events: [],
        last_summary: nil,
        step: StepDetect.reset(state.step),
        prev_step_status: :none,
        absorb_count: 0,
        xing: %{side: nil, extreme: nil}
    }
    |> start_session(wall_ms)
  end

  defp utc_date(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date()

  defp fold_session(state, lat, lon, tws) do
    session = state.session

    session =
      if is_number(lat) and is_number(lon) do
        %{session | lat_sum: session.lat_sum + lat, lon_sum: session.lon_sum + lon, pos_n: session.pos_n + 1}
      else
        session
      end

    session =
      if is_number(tws) do
        %{session | tws_sum: session.tws_sum + tws, tws_n: session.tws_n + 1}
      else
        session
      end

    %{state | session: session}
  end

  defp centroid(%{pos_n: 0}), do: nil
  defp centroid(%{lat_sum: lat_sum, lon_sum: lon_sum, pos_n: n}), do: %{lat: lat_sum / n, lon: lon_sum / n}

  defp tws_mean(%{tws_n: 0}), do: nil
  defp tws_mean(%{tws_sum: sum, tws_n: n}), do: sum / n

  defp session_view(nil), do: nil
  defp session_view(session), do: %{started_at_ms: session.started_at_ms, centroid: centroid(session)}

  # --- Events (envelope alarms, step confirmations, regime changes, extrema) ---

  defp detect_events(state, verdict, means_snap, env_snap, step_snap, twd, wall_ms, now) do
    {state, events} =
      {state, []}
      |> step_event(step_snap, twd, wall_ms, now)
      |> envelope_event(env_snap, twd, wall_ms)
      |> regime_event(verdict, twd, wall_ms)
      |> extrema_event(verdict, means_snap.phase_deg, twd, wall_ms)

    case events do
      [] -> state
      _ -> %{state | pending_events: state.pending_events ++ Enum.reverse(events), dirty_persist: true}
    end
  end

  # A step CONFIRMATION (the :none/:candidate -> :confirmed transition), with the
  # onset backdated onto the wall clock.
  defp step_event({state, events}, step_snap, twd, wall_ms, now) do
    events =
      if step_snap.status == :confirmed and state.prev_step_status != :confirmed do
        onset_t_ms = wall_ms - (now - step_snap.onset_ms)

        [
          %{
            t_ms: wall_ms,
            kind: "step",
            twd_deg: twd,
            magnitude_deg: step_snap.magnitude_deg,
            detail: %{onset_t_ms: onset_t_ms}
          }
          | events
        ]
      else
        events
      end

    {%{state | prev_step_status: step_snap.status}, events}
  end

  # An envelope breakout on THIS update (already warmed up + debounced by the
  # Envelope core); suppressed when the config disables alarms.
  defp envelope_event({state, events}, env_snap, twd, wall_ms) do
    events =
      if env_snap.new_extreme in [:high, :low] and state.alarms.enabled do
        kind = if env_snap.new_extreme == :high, do: "new_high", else: "new_low"

        [
          %{
            t_ms: wall_ms,
            kind: kind,
            twd_deg: twd,
            magnitude_deg: env_snap.range_deg,
            detail: %{
              min_deg: Circular.normalize(env_snap.min_deg),
              max_deg: Circular.normalize(env_snap.max_deg)
            }
          }
          | events
        ]
      else
        events
      end

    {state, events}
  end

  defp regime_event({%{prev_regime: nil} = state, events}, verdict, _twd, _wall_ms) do
    {%{state | prev_regime: verdict.regime}, events}
  end

  defp regime_event({state, events}, verdict, twd, wall_ms) do
    if verdict.regime == state.prev_regime do
      {state, events}
    else
      event = %{
        t_ms: wall_ms,
        kind: "regime_change",
        twd_deg: twd,
        magnitude_deg: nil,
        detail: %{from: to_string(state.prev_regime), to: to_string(verdict.regime), confidence: verdict.confidence}
      }

      {%{state | prev_regime: verdict.regime}, [event | events]}
    end
  end

  # Oscillation extrema via hysteresis zero crossings of the phase deviation
  # (the Period.zero_crossings idea, run incrementally): when the phase flips
  # sign, the largest |phase| since the previous flip is the extreme of the
  # half-cycle just ended. Emitted only while an oscillation verdict is live
  # and the tack is known (the kind is tack-resolved like the lift).
  defp extrema_event({state, events}, verdict, phase_deg, twd, wall_ms) when is_number(phase_deg) do
    %{side: side, extreme: extreme} = state.xing

    new_side =
      cond do
        phase_deg > @xing_hysteresis_deg -> :pos
        phase_deg < -@xing_hysteresis_deg -> :neg
        true -> side
      end

    if side != nil and new_side != side do
      events =
        case extreme_event(verdict, state.last_tack, extreme) do
          nil -> events
          event -> [event | events]
        end

      {%{state | xing: %{side: new_side, extreme: {phase_deg, twd, wall_ms}}}, events}
    else
      extreme =
        case extreme do
          nil -> {phase_deg, twd, wall_ms}
          {best, _, _} when abs(phase_deg) > abs(best) -> {phase_deg, twd, wall_ms}
          keep -> keep
        end

      {%{state | xing: %{side: new_side, extreme: extreme}}, events}
    end
  end

  defp extrema_event({state, events}, _verdict, _phase, _twd, _wall_ms), do: {state, events}

  defp extreme_event(%{oscillation: nil}, _tack, _extreme), do: nil
  defp extreme_event(_verdict, nil, _extreme), do: nil
  defp extreme_event(_verdict, _tack, nil), do: nil

  defp extreme_event(_verdict, tack, {phase_deg, twd, t_ms}) do
    kind = if phase_deg * tack > 0, do: "lift_extreme", else: "header_extreme"
    %{t_ms: t_ms, kind: kind, twd_deg: twd, magnitude_deg: abs(phase_deg), detail: %{phase_deg: phase_deg}}
  end

  # --- Step absorption (re-arm detection once the slow reference caught up) ---

  defp maybe_absorb(state, means_snap, %{status: :confirmed}) do
    if is_number(means_snap.phase_deg) and abs(means_snap.phase_deg) < state.step.band_deg do
      count = state.absorb_count + 1

      if count >= @absorb_dwell_ticks do
        %{state | step: StepDetect.reset(state.step), absorb_count: 0}
      else
        %{state | absorb_count: count}
      end
    else
      %{state | absorb_count: 0}
    end
  end

  defp maybe_absorb(state, _means_snap, _step_snap), do: %{state | absorb_count: 0}

  # --- Timeline (60 s cadence) ---

  defp maybe_timeline_row(state, verdict, means_snap, tws, wall_ms, now) do
    if now - state.last_timeline_ms >= state.timeline_ms do
      osc = verdict.oscillation

      row = %{
        t_ms: wall_ms,
        mean_twd_deg: normalize_optional_direction(means_snap.slow),
        phase_deg: means_snap.phase_deg,
        amplitude_deg: osc && osc.amplitude_deg,
        period_s: osc && osc.period_s,
        trend_deg_per_hr: verdict.trend_deg_per_hr,
        tws_mps: tws
      }

      %{state | pending_timeline: state.pending_timeline ++ [row], last_timeline_ms: now, dirty_persist: true}
    else
      state
    end
  end

  # --- Engine signal batch (numeric only; nil values omitted) ---

  defp publish_signals(state, verdict, means_snap, env_snap, lift, now) do
    osc = verdict.oscillation

    batch =
      [
        {"average_twd", means_snap.slow},
        {"wind_phase_deg", means_snap.phase_deg},
        {"wind_lift_deg", lift},
        {"twd_range_deg", env_snap.range_deg},
        {"twd_trend_deg_per_hr", verdict.trend_deg_per_hr},
        {"oscillation_period_s", osc && osc.period_s},
        {"oscillation_amplitude_deg", osc && osc.amplitude_deg},
        {"time_to_next_shift_s", verdict.time_to_next_shift_s},
        {"shift_confidence", verdict.confidence * 100.0},
        {"wind_regime", regime_code(verdict.regime)},
        {"wally_mode", state.wally_mode_code}
      ]
      |> Enum.filter(fn {_name, value} -> is_number(value) end)

    safe_put_signals(state.put_signals_fn, batch, now)
    state
  end

  defp safe_put_signals(_fun, [], _now), do: :ok

  defp safe_put_signals(fun, batch, now) do
    fun.(batch, now)
  rescue
    error -> Logger.warning("[WindShift.Observer] signal publish failed: #{inspect(error)}")
  catch
    :exit, _ -> :ok
  end

  # --- B&G broadcast (PGN 130824 keys 336/337/338 at 1 Hz, valid values only) ---

  defp maybe_broadcast(%{broadcast_enabled: false} = state, _means_snap, _lift, _now), do: state

  defp maybe_broadcast(state, means_snap, lift, now) do
    if tx_due?(state.last_tx_ms, now) do
      sent =
        [means_snap.slow, means_snap.phase_deg, lift]
        |> Enum.zip(@bandg_fields)
        |> Enum.reduce(0, fn {value, field}, count ->
          transmit_field(state, field, value, count)
        end)

      if sent > 0, do: %{state | last_tx_ms: now}, else: state
    else
      state
    end
  end

  defp transmit_field(_state, _field, value, count) when not is_number(value), do: count

  defp transmit_field(state, field, value, count) do
    def_map = %{output_pgn: @pgn, output_field: field, output_reference: nil, output_instance: nil}

    case PgnEncode.encode(def_map, %{field => value}) do
      {:ok, payload} ->
        safe_transmit(state.transmit, @priority, @pgn, payload)
        count + 1

      :error ->
        count
    end
  end

  # ~1 Hz rate-limit; the epsilon keeps a tick landing exactly on the boundary
  # from running perpetually one tick late (mirrors RaceTimerBroadcaster).
  defp tx_due?(nil, _now), do: true
  defp tx_due?(last_ms, now), do: now - last_ms >= @rate_ms - 1

  defp safe_transmit(fun, priority, pgn, payload) do
    fun.(priority, pgn, payload)
  rescue
    error -> Logger.warning("[WindShift.Observer] PGN #{pgn} transmit failed: #{inspect(error)}")
  catch
    :exit, _ -> :ok
  end

  # On the device, transmit through the NMEA 2000 VirtualDevice as a broadcast
  # (destination address 0xFF). No-op if the VirtualDevice isn't available.
  defp default_transmit(priority, pgn, payload) do
    case RacingOrg.Tracker.Pro.virtual_device() do
      nil -> :ok
      vd -> NMEA.NMEA2000.VirtualDevice.send_data(vd, priority, pgn, payload, 0xFF)
    end
  end

  # --- Upstream sync (throttled, changed-only, session-scoped) ---

  defp maybe_sync(state) do
    if due?(state.last_sync_ms, state.sync_ms, state) and syncable?(state) do
      sync(state)
    else
      state
    end
  end

  # Nothing new AND an unchanged summary -> skip entirely (the empty-batch drop).
  defp syncable?(%{session: nil}), do: false
  defp syncable?(%{last_verdict: nil}), do: false

  defp syncable?(state) do
    state.pending_timeline != [] or state.pending_events != [] or current_summary(state) != state.last_summary
  end

  defp sync(state) do
    if syncable?(state) do
      seq = state.seq + 1
      summary = current_summary(state)

      update = %{
        boat_identifier: state.boat_identifier,
        seq: seq,
        session: %{
          started_at_ms: state.session.started_at_ms,
          centroid: centroid(state.session),
          race_session_id: race_session_id(state),
          summary: summary
        },
        timeline: state.pending_timeline,
        events: state.pending_events
      }

      _ = safe_send(state.sender, update)

      %{
        state
        | pending_timeline: [],
          pending_events: [],
          last_summary: summary,
          last_sync_ms: state.now_fn.(),
          seq: seq,
          dirty_persist: true
      }
    else
      state
    end
  end

  # The summary doubles as the sync change-detection key, so its floats are
  # rounded to 0.01 — far beyond sensor reality — to keep pure floating-point
  # drift (e.g. a circular EWMA idling on a constant TWD) from re-arming syncs.
  defp current_summary(state) do
    verdict = state.last_verdict
    osc = verdict.oscillation

    %{
      mean_twd_deg: round_direction2(Means.snapshot(state.means).slow),
      trend_deg_per_hr: round2(verdict.trend_deg_per_hr),
      oscillation_period_s: round2(osc && osc.period_s),
      oscillation_amplitude_deg: round2(osc && osc.amplitude_deg),
      regime: to_string(verdict.regime),
      tws_mean_mps: round2(tws_mean(state.session))
    }
  end

  defp round_direction2(nil), do: nil
  defp round_direction2(value), do: value |> round2() |> Circular.normalize()

  defp round2(nil), do: nil
  defp round2(value), do: Float.round(value / 1, 2)

  # One cross-process read per SYNC (never per tick): the active assignment's
  # race_session_id, when there is one.
  defp race_session_id(%{commands: nil}), do: nil

  defp race_session_id(%{commands: {module, server}}) do
    case module.current_assignment(server) do
      %{race_assignment: %{race_session_id: id}} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp safe_send(sender, update) do
    sender.(ChannelClient, update)
  rescue
    error -> Logger.warning("[WindShift.Observer] wind-shift sync failed: #{inspect(error)}")
  catch
    :exit, _ -> :ok
  end

  # --- Throttled persistence (session identity + unsynced batch ONLY) ---

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
        session: state.session,
        seq: state.seq,
        pending_timeline: state.pending_timeline,
        pending_events: state.pending_events,
        last_summary: state.last_summary
      })

    %{state | dirty_persist: false, last_persist_ms: state.now_fn.()}
  end

  # A same-UTC-day persisted session is adopted whole (mid-day reboot keeps the
  # session + unsynced batch); an older one starts a fresh session but keeps the
  # monotonic seq (the backend orders per boat by seq).
  defp restore(nil, _utc_now_fn), do: %{}

  defp restore(dir, utc_now_fn) do
    case Store.load(dir) do
      {:ok, persisted} ->
        if same_utc_day?(Map.get(persisted, :session), utc_now_fn.()) do
          persisted
        else
          %{seq: Map.get(persisted, :seq, 0)}
        end

      :empty ->
        %{}
    end
  end

  defp same_utc_day?(%{started_at_ms: ms}, %DateTime{} = now) when is_integer(ms) do
    DateTime.to_date(DateTime.from_unix!(ms, :millisecond)) == DateTime.to_date(now)
  end

  defp same_utc_day?(_session, _now), do: false

  # --- Status (the live half of "wind_shift_status") ---

  defp build_status(state) do
    verdict = state.last_verdict
    osc = verdict && verdict.oscillation

    %{
      regime: to_string((verdict && verdict.regime) || :insufficient_history),
      confidence: (verdict && verdict.confidence) || 0.0,
      oscillation_period_s: osc && osc.period_s,
      oscillation_amplitude_deg: osc && osc.amplitude_deg,
      trend_deg_per_hr: verdict && verdict.trend_deg_per_hr,
      wind_phase_deg: Means.snapshot(state.means).phase_deg,
      wind_lift_deg: state.last_lift,
      twd_range_deg: Envelope.snapshot(state.envelope).range_deg,
      status: "ok"
    }
  end

  # --- Policy (WindShift.Config collaborator) ---

  defp put_policy(state, %{windows: windows, alarms: alarms, wally_mode_code: code}),
    do: %{state | windows: windows, alarms: alarms, wally_mode_code: code}

  # Wally.mode_code(nil) == 0 (off) — the fail-safe default policy.
  @default_policy %{windows: @default_windows, alarms: @default_alarms, wally_mode_code: 0}

  defp fetch_policy(nil), do: @default_policy

  defp fetch_policy({module, server}) do
    case module.current(server) do
      %{windows: %{} = windows, alarms: %{} = alarms} = policy ->
        %{windows: windows, alarms: alarms, wally_mode_code: Wally.mode_code(Map.get(policy, :wally_mode))}

      _ ->
        @default_policy
    end
  catch
    :exit, _ -> @default_policy
  end

  defp subscribe_config(nil), do: :ok

  defp subscribe_config({module, server}) do
    if function_exported?(module, :subscribe, 2) do
      module.subscribe(server, self())
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  # (Re)build the estimation cores from the current policy. Everything the
  # cores derive (unwrap chain, residual ring, period, classifier history,
  # event trackers) resets with them; the session and sync bookkeeping do NOT.
  defp build_cores(state) do
    windows = state.windows

    Map.merge(state, %{
      means: Means.new(tau_fast_s: windows.fast_s, tau_mid_s: windows.mid_s, tau_slow_s: windows.slow_s),
      envelope: Envelope.new(window_s: windows.envelope_s, margin_deg: state.alarms.new_extreme_margin_deg),
      cycle: Cycle.new(),
      step: StepDetect.new(),
      unwrap: nil,
      resid: {:queue.new(), 0},
      period: :none,
      last_period_ms: nil,
      t0_ms: nil,
      last_t_ms: nil,
      prev_step_status: :none,
      prev_regime: nil,
      absorb_count: 0,
      last_tack: nil,
      xing: %{side: nil, extreme: nil},
      last_verdict: nil,
      last_lift: nil
    })
  end

  # --- Signal reads ---

  defp fetch_twd(signals, now, staleness_ms) do
    case Map.get(signals, "true_wind_direction") do
      {value, mono_ms} when is_number(value) and is_integer(mono_ms) ->
        if now - mono_ms <= staleness_ms,
          do: {:ok, Circular.normalize(value)},
          else: {:error, :stale_twd}

      _ ->
        {:error, :no_twd}
    end
  end

  defp optional_fresh(signals, name, now, staleness_ms),
    do: optional_fresh(signals, name, now, staleness_ms, fn _value -> true end)

  defp optional_fresh(signals, name, now, staleness_ms, validator) do
    case Map.get(signals, name) do
      {value, mono_ms} when is_number(value) and is_integer(mono_ms) and now - mono_ms <= staleness_ms ->
        value = value / 1
        if validator.(value), do: value, else: nil

      _ ->
        nil
    end
  end

  defp valid_tws?(value), do: finite_float?(value) and value >= 0.0
  defp valid_latitude?(value), do: finite_float?(value) and value >= -90.0 and value <= 90.0
  defp valid_longitude?(value), do: finite_float?(value) and value >= -180.0 and value <= 180.0

  defp finite_float?(value),
    do: is_float(value) and value == value and value >= -@max_finite and value <= @max_finite

  # Signed TWA >= 0 = wind over the starboard side = starboard tack (see
  # Compute.Library.resolve_twa); dead ahead resolves starboard.
  defp tack_sign(twa) when is_number(twa) and twa >= 0, do: 1.0
  defp tack_sign(twa) when is_number(twa), do: -1.0
  defp tack_sign(_twa), do: nil

  # The Observer-side mirror of `Compute.Library.resolve_twa/1` (which reads the
  # calc-signals map; the raw-signal freshness semantics here are the same
  # names): the signed TWA is the live `true_wind_angle` signal when fresh,
  # otherwise `wrap180(true_wind_direction - heading)` — the instrumented-boat
  # case where the network true-wind PGN carries direction + speed but no
  # angle. `twd` is the tick's already-validated fresh true_wind_direction.
  # nil when neither resolves (the lift is then simply omitted).
  defp resolve_twa(signals, twd, now, staleness_ms) do
    case optional_fresh(signals, "true_wind_angle", now, staleness_ms) do
      twa when is_number(twa) ->
        twa

      nil ->
        case optional_fresh(signals, "heading", now, staleness_ms) do
          heading when is_number(heading) -> wrap180(twd - heading)
          nil -> nil
        end
    end
  end

  defp normalize_optional_direction(nil), do: nil
  defp normalize_optional_direction(value), do: Circular.normalize(value)

  # Signed wrap to (-180, 180] — Compute.Library.wrap180 semantics, so the
  # derived TWA resolves dead astern to starboard exactly like resolve_twa.
  defp wrap180(deg) do
    wrapped = :math.fmod(deg, 360.0)
    wrapped = if wrapped < 0.0, do: wrapped + 360.0, else: wrapped
    if wrapped > 180.0, do: wrapped - 360.0, else: wrapped
  end

  defp safe_signals do
    Engine.signals()
  catch
    :exit, _ -> %{}
  end

  # --- misc helpers ---

  defp bump(state, key), do: %{state | stats: Map.update!(state.stats, key, &(&1 + 1))}

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

  defp normalize_collaborator(nil), do: nil
  defp normalize_collaborator({module, server}) when is_atom(module), do: {module, server}
  defp normalize_collaborator(module) when is_atom(module), do: {module, module}
end
