defmodule RacingOrg.Tracker.Pro.Compute.Engine do
  @moduledoc """
  The on-device COMPUTE ENGINE (Phase 7): it receives the user-defined
  computed-value definitions from the server, keeps the current value of each raw
  source signal, and RECOMPUTES a computed value whenever one of its source signals
  changes — evaluating BOTH free-form expressions (via `RacingOrg.Tracker.Pro.Compute.Expr`, a
  safe RPN stack machine) AND the shipped native calcs (`RacingOrg.Tracker.Pro.Compute.Library`:
  true wind, VMG, VMC). It holds the latest result per definition, marking a value
  INVALID when a required input is missing or stale.

  This phase PRODUCES the computed values (held in engine state, read by Phase 8 via
  `current_values/1`). It does NOT broadcast onto NMEA2000, apply per-value output
  damping, or stream to the backend — those are Phase 8/10. The output-mapping fields
  on each def (`output_pgn`/`output_field`/.../`broadcast_*`/`stream_to_backend`) are
  carried verbatim with the def for Phase 8 to consume; this engine does not act on
  them.

  ## Config (server → device, Slipstream `"set_computed_values"`)

  Versioned + idempotent, persisted to `/data/computed_values` (survives reboots),
  mirroring `RacingOrg.Tracker.Pro.Tracking.Config`/`Tracking.Store`:

    * the persisted config is the AUTHORITY — on boot it loads and is treated as
      already-applied (a re-push of the same version is a no-op);
    * `applied_version` starts at `nil`, so the FIRST config (even `version: 0`, a
      REAL config — possibly empty `values: []` to CLEAR) is always applied;
    * `apply_config/2` is idempotent: a `version <=` the last applied is a no-op
      returning `{:ok, :unchanged}`; a malformed payload is rejected
      (`{:error, reason}`) and nothing is persisted/applied.

  ## Signals (the contract link to the backend catalog)

  The engine maintains a CURRENT-SIGNALS map `canonical_name => {value, mono_ms}`
  fed from the firmware's decoded `:telemetry` (the events
  `RacingOrg.Tracker.Pro.PacketHandler.EmitTelemetry` emits). Values are stored in CATALOG UNITS:
  speeds in m/s, angles in DEGREES (NMEA angles are RADIANS → converted here), depth
  in m, lat/long in degrees. A signal older than `max_age_ms` is STALE; a def needing
  a missing/stale signal evaluates to INVALID.

  ### Signal mapping (canonical name ⟵ telemetry event/field ⟶ unit conversion)

      apparent_wind_speed   ⟵ [:racing_org, :wind, :apparent] vector.magnitude  (m/s, as-is)
      apparent_wind_angle   ⟵ [:racing_org, :wind, :apparent] vector.angle       (rad → deg)
      true_wind_speed       ⟵ [:racing_org, :wind, <true ref>] vector.magnitude  (m/s, as-is)
      true_wind_direction   ⟵ [:racing_org, :wind, <true ref>] vector.angle       (rad → deg)
      sog                   ⟵ [:racing_org, :velocity, :ground] vector.magnitude (m/s, as-is)
      cog                   ⟵ [:racing_org, :velocity, :ground] vector.angle      (rad → deg)
      boat_speed (=STW)     ⟵ [:racing_org, :speed, :water] speed_m_s.value       (m/s, as-is)
      depth                 ⟵ [:racing_org, :water_depth] depth_m.value           (m, as-is)
      heading               ⟵ [:racing_org, :heading] rad.value                   (rad → deg)
      heel                  ⟵ [:racing_org, :attitude] rad.roll                    (rad → deg)
      pitch                 ⟵ [:racing_org, :attitude] rad.pitch                   (rad → deg)
      roll                  ⟵ [:racing_org, :attitude] rad.roll                    (rad → deg)
      latitude              ⟵ [:racing_org, :gps] position.lat                     (deg, as-is)
      longitude             ⟵ [:racing_org, :gps] position.lon                     (deg, as-is)

  (`heel` is sourced from `roll`: heel IS the roll angle. The `true_wind_*` raw
  signals come from a network-published true-wind PGN if one is present; the
  `true_wind` LIBRARY calc computes its own.)

  ### Output -> signal feedback (apparent-only boats)

  A boat that publishes only APPARENT wind has no network true-wind signals at all,
  so the polar/next-leg calcs would have nothing to read. To make that case work, the
  engine re-injects the on-device `:true_wind` calc's outputs (`true_wind_speed`,
  `true_wind_angle`, `true_wind_direction`) back into the signal map as CANONICAL
  signals after each signal-update pass (`feed_back_outputs/2`). This is done only
  when a `:true_wind` def is configured, is event-driven (on a signal change, never
  per `current_values` read), fresh-timestamped, and adds NO cross-process call and NO
  polar rebuild. There is no feedback-loop hazard: `:true_wind` consumes apparent wind
  + boat motion + heading, none of its own outputs. The fed-back signals are visible
  on the NEXT update's read — a one-tick lag, exactly as if an external device had
  published a true-wind PGN.

  ## Polar interpolant (device state, not a signal)

  The polar-aware calcs (`polar_performance`, `target_boat_speed`, `target_twa`,
  `vmg_performance`) need the precompiled `RacingOrg.Tracker.Pro.Polar.Lookup`, which
  is BOAT-scoped device state held by `RacingOrg.Tracker.Pro.Commands`, NOT a
  telemetry signal. To keep the compute hot path cheap the engine caches the compiled
  lookup (and its polar version) in its OWN state and refreshes it ONLY when the polar
  changes — it subscribes to `Commands` and, on a `:polar_table` command
  notification, does ONE `current_polar_lookup/1` fetch (off the hot path). Per
  compute tick the cached lookup is threaded into the calcs via `Library.compute/3`;
  there is no per-tick `GenServer.call`, no per-tick `Polar.Lookup.build/1`, and no
  per-tick copy of the source polar. The `:commands` collaborator is injectable for
  host tests (`{module, server}` or a bare module).

  ## Calibration corrections (device state, not a signal)

  The auto-calibration layer (`RacingOrg.Tracker.Pro.Calibration.Config`) compiles
  per-sensor corrections `%{hex => %{awa_offset_deg: f,
  awa_upwash: [{tws_center_mps, deg}], stw_gains: [{band_center_mps, gain}]}}`.
  The engine applies them to decoded telemetry BEFORE folding values into the
  signal map, keyed by the event's `metadata.device_id` (the raw NMEA NAME,
  canonicalized to the backend's uppercase-hex id via
  `RacingOrg.Tracker.Pro.NmeaIdentity`):

    * `apparent_wind_angle`: folded to signed (−180, 180], then
      `awa + awa_offset_deg + upwash_at(tws) * shape(|awa|) * sign(awa)`
      (no upwash dead-ahead), the TOTAL correction defensively clamped to ±15°,
      returned in the ORIGINAL convention (0..360 in from the bus -> 0..360 out).
      `upwash_at(tws)` interpolates the `awa_upwash` TWS curve (flat hold beyond
      the ends; a single point — the compiled form of a flat scalar — is a
      constant) at the LAST-KNOWN `true_wind_speed` signal, read from the signal
      map at correction time (one tick stale by construction, which is fine for
      a slowly-varying curve; staleness is deliberately not checked — an aging
      TWS still beats none). With NO TWS ever heard the curve's middle point
      applies: a flat prior beats extrapolating an unheard wind.
      `shape(a) = sin(0.6·(180−a)·π/180)^2.5` (the Ockam angle shape) fades the
      close-hauled-fitted upwash off the wind — it applies to flat single-point
      curves too;
    * `boat_speed`: `v * gain`, gain piecewise-linear over the `stw_gains` bands
      (flat extrapolation; a single pair is a uniform gain), defensively clamped
      to [0.8, 1.2];
    * everything else passes through untouched.

  Exactly like the polar lookup, the corrections map is CACHED in engine state and
  refreshed ONLY on a `{:racing_org_calibration, :updated}` notification — one
  cross-process fetch per change, never per telemetry event. With no calibration
  collaborator (`calibration: nil`) or an empty corrections map every signal value
  is BIT-IDENTICAL to the uncorrected path. Because `feed_back_outputs/2` and all
  calcs read the signal map, true wind and every downstream calc automatically
  compute from the corrected inputs. The raw DataSet upload path
  (`RacingOrg.Tracker.Pro.PacketHandler.EmitTelemetry` consumers) is a PARALLEL
  consumer and stays raw.

  All side effects (clock, persistence dir, max-age, commands, calibration) are
  injectable via `start_link/1` opts so the engine is fully unit-testable on host.
  """

  use GenServer
  require Logger

  alias RacingOrg.Tracker.Pro.Calibration
  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.Compute.Expr
  alias RacingOrg.Tracker.Pro.Compute.Library
  alias RacingOrg.Tracker.Pro.Compute.Store
  alias RacingOrg.Tracker.Pro.NmeaIdentity
  alias RacingOrg.Tracker.Protobuf.DeviceCommand

  @default_store_dir "/data/computed_values"
  # A signal not updated within this many ms is STALE (any dependent computed value
  # becomes INVALID). A few seconds is a sensible default for boat instruments at
  # 1–10 Hz; overridable via the :max_age_ms opt.
  @default_max_age_ms 5_000

  @deg_per_rad 180.0 / :math.pi()

  # The telemetry events the engine subscribes to (the ones EmitTelemetry emits).
  @wind_apparent [:racing_org, :wind, :apparent]
  @wind_true_vessel [:racing_org, :wind, :theoretical_water_vessel]
  @wind_true_ground [:racing_org, :wind, :theoretical_ground_true]
  @velocity_ground [:racing_org, :velocity, :ground]
  @speed_water [:racing_org, :speed, :water]
  @water_depth [:racing_org, :water_depth]
  @heading [:racing_org, :heading]
  @attitude [:racing_org, :attitude]
  @gps [:racing_org, :gps]

  @events [
    @wind_apparent,
    @wind_true_vessel,
    @wind_true_ground,
    @velocity_ground,
    @speed_water,
    @water_depth,
    @heading,
    @attitude,
    @gps
  ]

  @type def_t :: %{
          required(:id) => String.t(),
          required(:definition_type) => :expression | :library,
          optional(any()) => any()
        }

  @type result :: %{
          def: def_t(),
          outputs: %{optional(String.t()) => number()},
          valid?: boolean(),
          computed_at_ms: integer()
        }

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc """
  Apply a server-pushed computed-values config (called by the WSS channel handler).
  Accepts the wire map (string keys): `version` + `values`.

  Idempotent on `version` (`<=` last-applied is `{:ok, :unchanged}`; the first config
  always applies since the last-applied starts `nil`). Returns `{:ok, applied_config}`
  on apply, or `{:error, reason}` if malformed (nothing persisted/applied on error).
  """
  @spec apply_config(GenServer.server(), map()) ::
          {:ok, map()} | {:ok, :unchanged} | {:error, atom()}
  def apply_config(server \\ __MODULE__, config) when is_map(config) do
    GenServer.call(server, {:apply_config, config})
  end

  @doc "Purely validate and normalize a desired computed-values config."
  @spec validate_config(term()) :: {:ok, map()} | {:error, term()}
  def validate_config(config), do: strict_normalize(config)

  @doc "Durably reconcile authoritative desired state, regardless of legacy version order."
  @spec reconcile_config(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def reconcile_config(server \\ __MODULE__, config) when is_map(config) do
    GenServer.call(server, {:reconcile_config, config})
  end

  @doc "Durably clear desired computed-value authority and restore no definitions."
  @spec reset_config(GenServer.server()) :: :ok | {:error, term()}
  def reset_config(server \\ __MODULE__) do
    GenServer.call(server, :reset_config)
  end

  @doc "The currently-applied config version (`nil` if none applied yet)."
  @spec applied_version(GenServer.server()) :: integer() | nil
  def applied_version(server \\ __MODULE__) do
    GenServer.call(server, :applied_version)
  end

  @doc """
  The current computed results — one entry per active definition — for Phase 8 to
  consume. Each entry is `%{def: def, outputs: %{name => value}, valid?: bool,
  computed_at_ms: mono_ms}`. An INVALID value (a missing/stale required signal, a
  div-by-zero/domain error, an unknown library key) is represented by
  `valid?: false` with `outputs: %{}`. Recomputed FRESH against the current signals +
  clock on every call, so staleness is always current.
  """
  @spec current_values(GenServer.server()) :: [result()]
  def current_values(server \\ __MODULE__) do
    GenServer.call(server, :current_values)
  end

  @doc "The current raw-signal map: `canonical_name => {value_in_catalog_units, mono_ms}`."
  @spec signals(GenServer.server()) :: %{optional(String.t()) => {number(), integer()}}
  def signals(server \\ __MODULE__) do
    GenServer.call(server, :signals)
  end

  @doc """
  Inject a raw signal value directly into the engine's signal map (catalog units,
  monotonic ms). This is for signals that are NOT carried on the decoded `:telemetry`
  stream — notably `bearing_to_mark` (degrees), which `RacingOrg.Tracker.Pro.Nav.Broadcaster`
  derives from the active race assignment + current GPS and pushes here on each tick so
  the `vmc` library calc can compute. Same staleness rules apply: an injected signal
  goes stale after `max_age_ms`, so the producer must keep pushing it while it is live.

  Asynchronous (a cast); the value is visible on the next `current_values/1` read.
  """
  @spec put_signal(GenServer.server(), String.t(), number(), integer()) :: :ok
  def put_signal(server \\ __MODULE__, name, value, mono_ms)
      when is_binary(name) and is_number(value) and is_integer(mono_ms) do
    case GenServer.whereis(server) do
      nil -> :ok
      dest -> send(dest, {:signal_updates, [{name, value}], mono_ms})
    end

    :ok
  end

  @doc """
  Inject a BATCH of raw signals in one message (catalog units, a shared monotonic
  timestamp) — the batched form of `put_signal/4`, for producers that emit several
  signals per tick (notably `RacingOrg.Tracker.Pro.WindShift.Observer`, which
  publishes the wind-shift signals at 1 Hz). One message per batch keeps the
  engine's mailbox and the feedback pass at one traversal per tick instead of one
  per signal. Same staleness rules as `put_signal/4`; an empty batch is a no-op.

  Asynchronous; the values are visible on the next `current_values/1` read.
  """
  @spec put_signals(GenServer.server(), [{String.t(), number()}], integer()) :: :ok
  def put_signals(server \\ __MODULE__, updates, mono_ms) when is_list(updates) and is_integer(mono_ms) do
    case GenServer.whereis(server) do
      nil -> :ok
      _dest when updates == [] -> :ok
      dest -> send(dest, {:signal_updates, updates, mono_ms})
    end

    :ok
  end

  @doc """
  Status for the channel: `%{applied_version: int | nil, active_count: int}` where
  `active_count` is the number of currently-VALID computed values.
  """
  @spec status(GenServer.server()) :: %{applied_version: integer() | nil, active_count: non_neg_integer()}
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  # --- Server ---

  @impl true
  def init(opts) do
    handler_id = {__MODULE__, self()}

    state = %{
      store_dir: Keyword.get(opts, :store_dir, @default_store_dir),
      store_opts: Keyword.take(opts, [:file_system, :fault_injector]),
      max_age_ms: Keyword.get(opts, :max_age_ms, @default_max_age_ms),
      now_fn: Keyword.get(opts, :now_fn, fn -> System.monotonic_time(:millisecond) end),
      handler_id: handler_id,
      # The Commands collaborator the cached polar lookup is fetched from. Pass `nil`
      # to disable polar entirely (the polar calcs are then always invalid).
      commands: normalize_commands(Keyword.get(opts, :commands, Commands)),
      # The compiled polar interpolant + its polar version, cached locally so the hot
      # path never rebuilds/refetches. Refreshed only on a polar-change notification.
      polar_lookup: nil,
      polar_version: nil,
      # The Calibration.Config collaborator the cached corrections are fetched from.
      # Pass `nil` to disable calibration entirely (every signal passes through).
      calibration: normalize_calibration(Keyword.get(opts, :calibration, Calibration.Config)),
      # The compiled per-sensor corrections map, cached locally so the telemetry hot
      # path is one map lookup + arithmetic. Refreshed only on a calibration-change
      # notification.
      corrections: %{},
      # nil = nothing applied yet, so any incoming version (incl. 0) is newer.
      applied_version: nil,
      defs: [],
      # signal_name => {value_in_catalog_units, mono_ms}
      signals: %{}
    }

    state = reconcile(opts, state)
    attach_telemetry(handler_id, opts)
    state = init_polar(state)
    state = init_calibration(state)

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  @impl true
  def handle_call({:apply_config, config}, _from, state) do
    {result, state} = do_apply(config, state)
    {:reply, result, state}
  end

  def handle_call({:reconcile_config, config}, _from, state) do
    {result, state} = do_reconcile(config, state)
    {:reply, result, state}
  end

  def handle_call(:reset_config, _from, state) do
    case clear_persisted(state) do
      :ok -> {:reply, :ok, %{state | applied_version: nil, defs: []}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:applied_version, _from, state) do
    {:reply, state.applied_version, state}
  end

  def handle_call(:signals, _from, state) do
    {:reply, state.signals, state}
  end

  def handle_call(:current_values, _from, state) do
    {:reply, compute_all(state), state}
  end

  def handle_call(:status, _from, state) do
    active = compute_all(state) |> Enum.count(& &1.valid?)
    {:reply, %{applied_version: state.applied_version, active_count: active}, state}
  end

  # Telemetry handler runs in the publishing process and just forwards the decoded,
  # unit-converted signal updates here as a message; the GenServer owns the map.
  # Direct injections (put_signal) carry no source identity, so no corrections apply.
  @impl true
  def handle_info({:signal_updates, updates, mono_ms}, state) do
    {:noreply, ingest_updates(updates, mono_ms, state)}
  end

  # Decoded telemetry additionally carries the source sensor identity (the raw
  # `metadata.device_id` NMEA NAME); per-sensor calibration corrections are applied
  # BEFORE the values fold into the signal map. With no corrections cached this is
  # a pass-through (bit-identical values).
  def handle_info({:signal_updates, updates, mono_ms, device_id}, state) do
    {:noreply, ingest_updates(apply_corrections(updates, device_id, state), mono_ms, state)}
  end

  # A polar-table command was applied -> the polar may have changed; refresh the
  # cached lookup ONCE (off the hot path). Other commands are ignored here.
  def handle_info({:racing_org_command, %DeviceCommand{payload: {:polar_table, _table}}}, state) do
    {:noreply, refresh_polar(state)}
  end

  def handle_info({:racing_org_command, _command}, state), do: {:noreply, state}

  # The calibration state changed -> refresh the cached corrections ONCE (off the
  # hot path).
  def handle_info({:racing_org_calibration, :updated}, state) do
    {:noreply, refresh_calibration(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Fold the (possibly corrected) signal updates into the map, then re-inject
  # designated calc outputs (currently the on-device `:true_wind` calc's
  # true_wind_* outputs) back as canonical signals so the polar/next-leg calcs
  # drive off an APPARENT-only boat too (no network true-wind PGN). Event-driven
  # (only on a signal change), fresh-timestamped, with NO cross-process call and
  # NO polar rebuild — see feed_back_outputs/2.
  #
  # Event-driven recompute happens implicitly: current_values/status recompute fresh
  # against state.signals. (Holding per-def cached results is unnecessary for Phase 7
  # and would only risk staleness; Phase 8 reads current_values which is always live.)
  defp ingest_updates(updates, mono_ms, state) do
    signals =
      Enum.reduce(updates, state.signals, fn {name, value}, acc ->
        Map.put(acc, name, {value, mono_ms})
      end)

    signals = feed_back_outputs(%{state | signals: signals}, mono_ms)
    %{state | signals: signals}
  end

  # --- polar lookup cache (built once per polar version, NOT per tick) ---

  # On boot: subscribe to Commands for polar-change notifications, then prime the
  # cache once. Disabled (commands == nil) leaves the lookup nil.
  defp init_polar(%{commands: nil} = state), do: state

  defp init_polar(%{commands: {module, server}} = state) do
    subscribe_commands(module, server)
    refresh_polar(state)
  end

  # Refresh the cached lookup + version from Commands. A single cross-process call,
  # invoked ONLY on boot and on a polar-change notification — never per compute tick.
  defp refresh_polar(%{commands: nil} = state), do: state

  defp refresh_polar(%{commands: {module, server}} = state) do
    %{state | polar_lookup: fetch_polar_lookup(module, server), polar_version: fetch_polar_version(module, server)}
  end

  defp subscribe_commands(module, server) do
    if function_exported?(module, :subscribe, 2) do
      module.subscribe(server, self())
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp fetch_polar_lookup(module, server) do
    module.current_polar_lookup(server)
  catch
    :exit, _ -> nil
  end

  defp fetch_polar_version(module, server) do
    if function_exported?(module, :current_polar_version, 1) do
      module.current_polar_version(server)
    end
  catch
    :exit, _ -> nil
  end

  defp normalize_commands(nil), do: nil
  defp normalize_commands({module, server}) when is_atom(module), do: {module, server}
  defp normalize_commands(module) when is_atom(module), do: {module, module}

  # --- calibration corrections cache (fetched once per change, NOT per event) ---

  # On boot: subscribe to Calibration.Config for change notifications, then prime
  # the cache once. Disabled (calibration == nil) leaves the corrections empty, so
  # every signal passes through untouched.
  defp init_calibration(%{calibration: nil} = state), do: state

  defp init_calibration(%{calibration: {module, server}} = state) do
    subscribe_calibration(module, server)
    refresh_calibration(state)
  end

  # Refresh the cached corrections from the collaborator. A single cross-process
  # call, invoked ONLY on boot and on a calibration-change notification — never
  # per telemetry event.
  defp refresh_calibration(%{calibration: nil} = state), do: state

  defp refresh_calibration(%{calibration: {module, server}} = state) do
    %{state | corrections: fetch_corrections(module, server)}
  end

  defp subscribe_calibration(module, server) do
    if function_exported?(module, :subscribe, 2) do
      module.subscribe(server, self())
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp fetch_corrections(module, server) do
    case module.corrections(server) do
      %{} = corrections -> corrections
      _ -> %{}
    end
  catch
    :exit, _ -> %{}
  end

  defp normalize_calibration(nil), do: nil
  defp normalize_calibration({module, server}) when is_atom(module), do: {module, server}
  defp normalize_calibration(module) when is_atom(module), do: {module, module}

  # --- calibration correction application (the telemetry hot path) ---
  #
  # Per event: one canonicalization + one map lookup + arithmetic; NO GenServer
  # call. With no corrections cached (the common case) the updates pass through
  # UNTOUCHED — bit-identical to the uncorrected path.

  @min_stw_gain 0.8
  @max_stw_gain 1.2
  # The total AWA correction (offset + shaped upwash) is defensively clamped:
  # anything beyond this is a broken sensor, not a calibration.
  @max_awa_correction_deg 15.0

  defp apply_corrections(updates, _device_id, %{corrections: corrections}) when map_size(corrections) == 0,
    do: updates

  defp apply_corrections(updates, device_id, state) do
    case Map.get(state.corrections, NmeaIdentity.canonical_hardware_id(device_id)) do
      nil -> updates
      %{} = entry -> Enum.map(updates, &correct_update(&1, entry, state))
    end
  end

  defp correct_update({"apparent_wind_angle", awa}, entry, state),
    do: {"apparent_wind_angle", correct_awa(awa, entry, last_tws(state))}

  defp correct_update({"boat_speed", stw}, entry, _state), do: {"boat_speed", correct_stw(stw, entry)}
  defp correct_update(update, _entry, _state), do: update

  # The LAST-KNOWN true wind speed from the engine's own signal map (already in
  # scope on the ingest path — no process call). One tick stale by construction
  # and deliberately not staleness-checked: the upwash curve varies slowly with
  # TWS, so an aging value still picks a better curve point than none. `nil`
  # only when no TWS signal has EVER been heard.
  defp last_tws(%{signals: %{"true_wind_speed" => {tws, _mono_ms}}}), do: tws
  defp last_tws(_state), do: nil

  # Fold to signed (−180, 180], apply
  # `awa + offset + upwash_at(tws) * shape(|awa|) * sign(awa)` (the upwash flips
  # with the tack side; sign(0) = 0 so dead-ahead gets no upwash), clamp the
  # total correction to ±@max_awa_correction_deg, re-fold, then return in the
  # ORIGINAL convention: a non-negative input (the bus's 0..360 form) comes back
  # in [0, 360); a negative (signed) input stays signed. A sensor entry with no
  # AWA correction leaves the value untouched.
  defp correct_awa(awa, entry, tws) do
    offset = Map.get(entry, :awa_offset_deg, 0.0)
    upwash = upwash_at(Map.get(entry, :awa_upwash), tws)

    if offset == 0.0 and upwash == 0.0 do
      awa
    else
      signed = fold_signed_deg(awa)
      correction = offset + upwash * upwash_shape(abs(signed)) * tack_sign(signed)
      corrected = fold_signed_deg(signed + clamp_awa_correction(correction))
      restore_awa_convention(awa, corrected)
    end
  end

  # The upwash correction at the current TWS: piecewise-linear over the compiled
  # `awa_upwash` curve (flat hold beyond the ends; a single point — the compiled
  # form of a flat scalar — is a constant). With no TWS ever heard, hold the
  # curve's MIDDLE point flat: a flat prior beats extrapolating an unheard wind
  # toward either curve end.
  defp upwash_at(nil, _tws), do: 0.0
  defp upwash_at([], _tws), do: 0.0
  defp upwash_at(curve, tws) when is_number(tws), do: interpolate_curve(curve, tws)
  defp upwash_at(curve, nil), do: curve |> Enum.at(div(length(curve), 2)) |> elem(1)

  # The Ockam angle shape `sin(0.6·(180−a)·π/180)^2.5` for a = |AWA| in
  # [0, 180]: ≈0.88 dead-ahead, 1.0 at 30°, ≈0.59 at 90°, ≈0.05 at 150°, 0 dead
  # astern — the upwash correction is fitted close-hauled and must fade off the
  # wind. The sine is non-negative over the whole domain (its argument stays in
  # [0°, 108°]); the guard keeps the fractional power total anyway.
  defp upwash_shape(abs_awa) do
    s = :math.sin(0.6 * (180.0 - abs_awa) * :math.pi() / 180.0)
    if s <= 0.0, do: 0.0, else: :math.pow(s, 2.5)
  end

  defp clamp_awa_correction(deg) when deg > @max_awa_correction_deg, do: @max_awa_correction_deg
  defp clamp_awa_correction(deg) when deg < -@max_awa_correction_deg, do: -@max_awa_correction_deg
  defp clamp_awa_correction(deg), do: deg

  defp fold_signed_deg(deg) do
    folded = :math.fmod(deg, 360.0)

    cond do
      folded > 180.0 -> folded - 360.0
      folded <= -180.0 -> folded + 360.0
      true -> folded
    end
  end

  defp tack_sign(signed) when signed > 0, do: 1.0
  defp tack_sign(signed) when signed < 0, do: -1.0
  defp tack_sign(_signed), do: 0.0

  defp restore_awa_convention(original, corrected) when original < 0, do: corrected
  defp restore_awa_convention(_original, corrected) when corrected < 0, do: corrected + 360.0
  defp restore_awa_convention(_original, corrected), do: corrected

  # `v * gain`: piecewise-linear interpolation of the {band_center_mps, gain}
  # bands over v, flat extrapolation beyond the first/last center (a single pair
  # is a uniform gain), with the final gain defensively clamped to
  # [@min_stw_gain, @max_stw_gain]. No stw_gains -> untouched.
  defp correct_stw(stw, entry) do
    case Map.get(entry, :stw_gains) do
      [_ | _] = gains -> stw * clamp_gain(interpolate_curve(gains, stw))
      _ -> stw
    end
  end

  # Shared piecewise-linear lookup over an ascending `[{x, y}]` curve (the
  # stw_gains bands AND the awa_upwash TWS curve): flat hold beyond the first
  # and last points; a single point is a constant.
  defp interpolate_curve([{_x, y}], _v), do: y
  defp interpolate_curve([{x, y} | _rest], v) when v <= x, do: y

  defp interpolate_curve([{x0, y0}, {x1, y1} | rest], v) do
    cond do
      v <= x1 and x1 == x0 -> y1
      v <= x1 -> y0 + (y1 - y0) * (v - x0) / (x1 - x0)
      rest == [] -> y1
      true -> interpolate_curve([{x1, y1} | rest], v)
    end
  end

  defp clamp_gain(gain) when gain < @min_stw_gain, do: @min_stw_gain
  defp clamp_gain(gain) when gain > @max_stw_gain, do: @max_stw_gain
  defp clamp_gain(gain), do: gain

  # --- telemetry attach + decode (signal mapping + unit conversion) ---

  defp attach_telemetry(handler_id, opts) do
    if Keyword.get(opts, :attach_telemetry?, true) do
      target = self()

      :telemetry.attach_many(
        handler_id,
        @events,
        &__MODULE__.handle_event/4,
        %{target: target}
      )
    end

    :ok
  end

  @doc false
  # Telemetry callback (NOT run in the GenServer). Decodes the measurement into
  # canonical signals (converting units) and forwards them to the engine process,
  # along with the source sensor identity (`metadata.device_id`, the raw NMEA
  # NAME) so per-sensor calibration corrections can key off it.
  def handle_event(event, measurements, metadata, %{target: target}) do
    mono_ms = mono_ms(metadata)

    case decode_signals(event, measurements) do
      [] -> :ok
      updates -> send(target, {:signal_updates, updates, mono_ms, device_id(metadata)})
    end
  end

  # Apparent wind: speed m/s as-is, angle rad -> deg.
  defp decode_signals(@wind_apparent, %{vector: %{angle: angle, magnitude: mag}}) do
    [{"apparent_wind_speed", mag / 1}, {"apparent_wind_angle", to_deg(angle)}]
  end

  # Network-published TRUE wind (vessel- or ground-referenced) -> true_wind_* signals.
  defp decode_signals(ev, %{vector: %{angle: angle, magnitude: mag}})
       when ev in [@wind_true_vessel, @wind_true_ground] do
    [{"true_wind_speed", mag / 1}, {"true_wind_direction", to_deg(angle)}]
  end

  # Velocity over ground: magnitude = SOG (m/s), angle = COG (rad -> deg).
  defp decode_signals(@velocity_ground, %{vector: %{angle: angle, magnitude: mag}}) do
    [{"sog", mag / 1}, {"cog", to_deg(angle)}]
  end

  # Speed through water = STW = boat_speed (m/s).
  defp decode_signals(@speed_water, %{speed_m_s: %{value: value}}) do
    [{"boat_speed", value / 1}]
  end

  defp decode_signals(@water_depth, %{depth_m: %{value: value}}) do
    [{"depth", value / 1}]
  end

  # Heading rad -> deg.
  defp decode_signals(@heading, %{rad: %{value: value}}) do
    [{"heading", to_deg(value)}]
  end

  # Attitude: heel <- roll, plus pitch + roll (all rad -> deg). yaw is heading-ish but
  # we take heading from the dedicated heading event.
  defp decode_signals(@attitude, %{rad: %{pitch: pitch, roll: roll}}) do
    [{"heel", to_deg(roll)}, {"pitch", to_deg(pitch)}, {"roll", to_deg(roll)}]
  end

  defp decode_signals(@gps, %{position: %{lat: lat, lon: lon}}) do
    [{"latitude", lat / 1}, {"longitude", lon / 1}]
  end

  defp decode_signals(_event, _measurements), do: []

  defp to_deg(rad) when is_number(rad), do: rad * @deg_per_rad

  defp mono_ms(%{timestamp_monotonic_ms: ms}) when is_integer(ms), do: ms
  defp mono_ms(_metadata), do: System.monotonic_time(:millisecond)

  defp device_id(%{device_id: id}), do: id
  defp device_id(_metadata), do: nil

  # --- output -> signal feedback (designated calc outputs re-injected as signals) ---

  # Library keys whose outputs are re-injected into the signal map as canonical
  # signals after each signal-update pass. Only the on-device `:true_wind` calc
  # qualifies today: it OUTPUTS true_wind_* but CONSUMES none of them (it reads
  # apparent wind + boat motion + heading), so there is NO feedback-loop hazard.
  # Restricting feedback to this fixed set keeps the loop-free guarantee explicit.
  @feedback_library_keys ~w(true_wind)

  # The output names eligible to become signals (the canonical wind signals the
  # polar/next-leg calcs read). An output is fed back only if it both is produced by
  # a feedback calc AND names a canonical wind signal — never an arbitrary key.
  @feedback_signal_names ~w(true_wind_speed true_wind_angle true_wind_direction)

  # Recompute the feedback `:true_wind` defs against the just-updated signals and
  # re-inject their designated outputs as fresh-timestamped signals. Skipped entirely
  # (no allocation, no compute) when the config has no feedback def — the common case.
  # One-tick lag is acceptable: the fed-back signals are visible on the NEXT update's
  # read, exactly like any externally-published true-wind PGN. NO GenServer.call, NO
  # Polar.Lookup.build, NO Commands fetch on this path.
  defp feed_back_outputs(state, mono_ms) do
    case feedback_defs(state.defs) do
      [] ->
        state.signals

      defs ->
        # Recompute against a fixed `now` = mono_ms so freshness checks pass for the
        # signals just delivered in THIS pass (they carry mono_ms too).
        Enum.reduce(defs, state.signals, fn def, signals ->
          inject_feedback(def, %{state | signals: signals}, mono_ms)
        end)
    end
  end

  defp feedback_defs(defs) do
    Enum.filter(defs, fn def ->
      def.definition_type == :library and def.library_key in @feedback_library_keys
    end)
  end

  defp inject_feedback(def, state, mono_ms) do
    case eval_library(def, state, mono_ms) do
      {:ok, outputs} ->
        Enum.reduce(outputs, state.signals, fn {name, value}, acc ->
          if name in @feedback_signal_names and is_number(value) do
            Map.put(acc, name, {value, mono_ms})
          else
            acc
          end
        end)

      :invalid ->
        state.signals
    end
  end

  # --- recompute (shared by current_values + status) ---

  defp compute_all(state) do
    now = state.now_fn.()
    Enum.map(state.defs, fn def -> compute_one(def, state, now) end)
  end

  defp compute_one(def, state, now) do
    outcome =
      case def.definition_type do
        :expression -> eval_expression(def, state, now)
        :library -> eval_library(def, state, now)
      end

    case outcome do
      {:ok, outputs} -> %{def: def, outputs: outputs, valid?: true, computed_at_ms: now}
      :invalid -> %{def: def, outputs: %{}, valid?: false, computed_at_ms: now}
    end
  end

  # Expression: evaluate the compiled RPN over a lookup that only resolves FRESH
  # signals. A single scalar result is exposed under the output key "value".
  defp eval_expression(def, state, now) do
    lookup = signal_lookup(state, now)

    case Expr.eval(def.rpn, lookup) do
      {:ok, value} -> {:ok, %{"value" => value}}
      :invalid -> :invalid
    end
  end

  # Library: gather the def's required signals (FRESH only, honoring input_bindings)
  # into a name=>value map and hand it to the native calc, along with the cached
  # polar context (the polar-aware calcs read `polar_lookup`; the others ignore it).
  defp eval_library(def, state, now) do
    signal_values = resolve_library_signals(def, state, now)
    Library.compute(library_key_atom(def.library_key), signal_values, %{polar_lookup: state.polar_lookup})
  end

  # Build the signals map a library calc sees. Each required raw signal is resolved
  # FRESH (stale/missing dropped). `input_bindings` remaps a library input NAME to a
  # different signal NAME (the catalog feature: input <- bound_signal).
  defp resolve_library_signals(def, state, now) do
    bindings = def.input_bindings || %{}

    Enum.reduce(def.signals, %{}, fn input_name, acc ->
      source_name = Map.get(bindings, input_name, input_name)

      case fresh_value(state, source_name, now) do
        {:ok, value} -> Map.put(acc, input_name, value)
        :error -> acc
      end
    end)
  end

  # A lookup fn for Expr: only FRESH (non-stale, present) signals resolve.
  defp signal_lookup(state, now) do
    fn name -> fresh_value(state, name, now) end
  end

  defp fresh_value(state, name, now) do
    case Map.fetch(state.signals, name) do
      {:ok, {value, mono_ms}} ->
        if now - mono_ms <= state.max_age_ms, do: {:ok, value}, else: :error

      :error ->
        :error
    end
  end

  defp library_key_atom("true_wind"), do: :true_wind
  defp library_key_atom("vmg"), do: :vmg
  defp library_key_atom("vmc"), do: :vmc
  defp library_key_atom("polar_performance"), do: :polar_performance
  defp library_key_atom("target_boat_speed"), do: :target_boat_speed
  defp library_key_atom("target_twa"), do: :target_twa
  defp library_key_atom("vmg_performance"), do: :vmg_performance
  defp library_key_atom("next_leg_twa"), do: :next_leg_twa
  defp library_key_atom("next_leg_aws"), do: :next_leg_aws
  defp library_key_atom("next_leg_awa"), do: :next_leg_awa
  defp library_key_atom(key) when is_atom(key), do: key
  defp library_key_atom(_), do: :unknown

  # --- reconcile / apply (mirrors Tracking.Config) ---

  defp reconcile(opts, state) do
    cond do
      cfg = opts[:initial_config] ->
        case normalize(cfg) do
          {:ok, config} -> %{state | defs: config.values, applied_version: config.version}
          {:error, _} -> state
        end

      is_nil(state.store_dir) ->
        state

      true ->
        case Store.load(state.store_dir) do
          {:ok, config} ->
            Logger.info("[Compute.Engine] reconciling persisted config (version=#{config.version})")
            %{state | defs: config.values, applied_version: config.version}

          :empty ->
            state
        end
    end
  end

  defp do_apply(raw, state) do
    case normalize(raw) do
      {:error, reason} ->
        {{:error, reason}, state}

      {:ok, %{version: version}}
      when is_integer(version) and not is_nil(state.applied_version) and version <= state.applied_version ->
        {{:ok, :unchanged}, state}

      {:ok, config} ->
        _ = maybe_persist(state.store_dir, config)
        state = %{state | defs: config.values, applied_version: config.version}
        {{:ok, config}, state}
    end
  end

  defp do_reconcile(raw, state) do
    with {:ok, config} <- strict_normalize(raw),
         :ok <- maybe_persist(state.store_dir, config) do
      state = %{state | defs: config.values, applied_version: config.version}
      {{:ok, config}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp clear_persisted(%{store_dir: nil}), do: :ok
  defp clear_persisted(state), do: Store.clear(state.store_dir, state.store_opts)

  defp maybe_persist(nil, _config), do: :ok
  defp maybe_persist(dir, config), do: Store.save(dir, config)

  @library_keys ~w(true_wind vmg vmc polar_performance target_boat_speed target_twa vmg_performance
                   next_leg_twa next_leg_aws next_leg_awa)

  # --- Strict Desired State normalization ---
  #
  # The backend projection is COMPLETE and canonical, so unlike the legacy
  # `set_computed_values` channel path below nothing is coerced or defaulted: a
  # field present with the wrong shape (an `input_bindings` LIST instead of the
  # canonical map, a string `version`, a non-numeric damping) rejects the whole
  # generation rather than silently making a half-understood config effective.

  defp strict_normalize(%{} = raw) do
    with {:ok, version} <- strict_version(fetch(raw, :version, "version")),
         {:ok, values} <- strict_values(fetch(raw, :values, "values")) do
      {:ok, %{version: version, values: values}}
    end
  end

  defp strict_normalize(_raw), do: {:error, :malformed}

  defp strict_version(version) when is_integer(version) and version >= 0, do: {:ok, version}
  defp strict_version(_version), do: {:error, :bad_version}

  defp strict_values(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn raw, {:ok, acc, ids} ->
      case strict_value(raw) do
        {:ok, def} ->
          if MapSet.member?(ids, def.id) do
            {:halt, {:error, :duplicate_value_id}}
          else
            {:cont, {:ok, [def | acc], MapSet.put(ids, def.id)}}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, defs, _ids} -> {:ok, Enum.reverse(defs)}
      {:error, _reason} = error -> error
    end
  end

  defp strict_values(_values), do: {:error, :bad_values}

  defp strict_value(%{} = raw) do
    with {:ok, id} <- fetch_id(raw),
         {:ok, type} <- fetch_type(raw),
         {:ok, signals} <- fetch_signals(raw),
         {:ok, type_fields} <- strict_type_fields(type, raw),
         {:ok, name} <- strict_name(fetch(raw, :name, "name")),
         {:ok, bindings} <- strict_bindings(fetch(raw, :input_bindings, "input_bindings")),
         {:ok, output_pgn} <- strict_optional_integer(fetch(raw, :output_pgn, "output_pgn")),
         {:ok, output_field} <- strict_optional_string(fetch(raw, :output_field, "output_field")),
         {:ok, output_reference} <-
           strict_optional_string(fetch(raw, :output_reference, "output_reference")),
         {:ok, output_unit} <- strict_optional_string(fetch(raw, :output_unit, "output_unit")),
         {:ok, output_instance} <-
           strict_optional_integer(fetch(raw, :output_instance, "output_instance")),
         {:ok, damping} <-
           strict_nonnegative_number(fetch(raw, :damping_seconds, "damping_seconds")),
         {:ok, rate} <- strict_positive_number(fetch(raw, :broadcast_rate_hz, "broadcast_rate_hz")),
         {:ok, broadcast?} <-
           strict_boolean(fetch(raw, :broadcast_enabled, "broadcast_enabled")),
         {:ok, stream?} <- strict_boolean(fetch(raw, :stream_to_backend, "stream_to_backend")) do
      {:ok,
       Map.merge(
         %{
           id: id,
           name: name,
           definition_type: type,
           signals: signals,
           input_bindings: bindings,
           output_pgn: output_pgn,
           output_field: output_field,
           output_reference: output_reference,
           output_unit: output_unit,
           output_instance: output_instance,
           damping_seconds: damping,
           broadcast_rate_hz: rate,
           broadcast_enabled: broadcast?,
           stream_to_backend: stream?
         },
         type_fields
       )}
    end
  end

  defp strict_value(_raw), do: {:error, :bad_value}

  # An expression def carries an rpn list AND a nil library_key; a library def is
  # the exact mirror. A projection setting both (or neither) is not canonical.
  defp strict_type_fields(:expression, raw) do
    with rpn when is_list(rpn) <- fetch(raw, :rpn, "rpn"),
         nil <- fetch(raw, :library_key, "library_key") do
      {:ok, %{rpn: rpn, library_key: nil}}
    else
      _other -> {:error, :bad_rpn}
    end
  end

  defp strict_type_fields(:library, raw) do
    with key when is_binary(key) <- fetch(raw, :library_key, "library_key"),
         true <- key in @library_keys,
         nil <- fetch(raw, :rpn, "rpn") do
      {:ok, %{library_key: key, rpn: nil}}
    else
      _other -> {:error, :bad_library_key}
    end
  end

  defp strict_name(name) when is_binary(name), do: {:ok, name}
  defp strict_name(_name), do: {:error, :bad_name}

  defp strict_bindings(nil), do: {:ok, %{}}

  defp strict_bindings(%{} = bindings) do
    if Enum.all?(bindings, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      {:ok, Map.new(bindings)}
    else
      {:error, :bad_input_bindings}
    end
  end

  defp strict_bindings(_bindings), do: {:error, :bad_input_bindings}

  defp strict_optional_string(nil), do: {:ok, nil}
  defp strict_optional_string(value) when is_binary(value), do: {:ok, value}
  defp strict_optional_string(_value), do: {:error, :bad_output_field}

  defp strict_optional_integer(nil), do: {:ok, nil}

  defp strict_optional_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp strict_optional_integer(_value), do: {:error, :bad_output_field}

  defp strict_nonnegative_number(value) when is_number(value) and value >= 0, do: {:ok, value / 1}
  defp strict_nonnegative_number(_value), do: {:error, :bad_damping_seconds}

  defp strict_positive_number(value) when is_number(value) and value > 0, do: {:ok, value / 1}
  defp strict_positive_number(_value), do: {:error, :bad_broadcast_rate_hz}

  defp strict_boolean(value) when is_boolean(value), do: {:ok, value}
  defp strict_boolean(_value), do: {:error, :bad_boolean_flag}

  # --- Legacy normalization (string OR atom keys -> canonical defs) ---

  defp normalize(%{} = raw) do
    with {:ok, version} <- fetch_version(raw),
         {:ok, values} <- fetch_values(raw),
         {:ok, defs} <- normalize_values(values) do
      {:ok, %{version: version, values: defs}}
    end
  end

  defp normalize(_), do: {:error, :malformed}

  defp fetch_version(raw) do
    case fetch(raw, :version, "version") do
      v when is_integer(v) -> {:ok, v}
      v when is_binary(v) -> {:ok, String.to_integer(v)}
      _ -> {:error, :bad_version}
    end
  rescue
    _ -> {:error, :bad_version}
  end

  defp fetch_values(raw) do
    case fetch(raw, :values, "values") do
      values when is_list(values) -> {:ok, values}
      _ -> {:error, :bad_values}
    end
  end

  defp normalize_values(values) do
    Enum.reduce_while(values, {:ok, []}, fn raw, {:ok, acc} ->
      case normalize_value(raw) do
        {:ok, def} -> {:cont, {:ok, [def | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, defs} -> {:ok, Enum.reverse(defs)}
      err -> err
    end
  end

  defp normalize_value(%{} = raw) do
    with {:ok, id} <- fetch_id(raw),
         {:ok, type} <- fetch_type(raw),
         {:ok, signals} <- fetch_signals(raw),
         {:ok, type_fields} <- fetch_type_fields(type, raw) do
      {:ok,
       Map.merge(
         %{
           id: id,
           name: fetch(raw, :name, "name"),
           definition_type: type,
           signals: signals,
           input_bindings: normalize_bindings(fetch(raw, :input_bindings, "input_bindings")),
           output_pgn: fetch(raw, :output_pgn, "output_pgn"),
           output_field: fetch(raw, :output_field, "output_field"),
           output_reference: fetch(raw, :output_reference, "output_reference"),
           output_unit: fetch(raw, :output_unit, "output_unit"),
           output_instance: fetch(raw, :output_instance, "output_instance"),
           damping_seconds: fetch(raw, :damping_seconds, "damping_seconds"),
           broadcast_rate_hz: fetch(raw, :broadcast_rate_hz, "broadcast_rate_hz"),
           broadcast_enabled: fetch(raw, :broadcast_enabled, "broadcast_enabled"),
           stream_to_backend: fetch(raw, :stream_to_backend, "stream_to_backend")
         },
         type_fields
       )}
    end
  end

  defp normalize_value(_), do: {:error, :bad_value}

  defp fetch_id(raw) do
    case fetch(raw, :id, "id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :missing_id}
    end
  end

  defp fetch_type(raw) do
    case fetch(raw, :definition_type, "definition_type") do
      t when t in ["expression", :expression] -> {:ok, :expression}
      t when t in ["library", :library] -> {:ok, :library}
      _ -> {:error, :bad_definition_type}
    end
  end

  defp fetch_signals(raw) do
    case fetch(raw, :signals, "signals") do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: {:error, :bad_signals}

      _ ->
        {:error, :bad_signals}
    end
  end

  # Expression defs MUST carry a list rpn; library defs MUST carry a known key.
  defp fetch_type_fields(:expression, raw) do
    case fetch(raw, :rpn, "rpn") do
      rpn when is_list(rpn) -> {:ok, %{rpn: rpn, library_key: nil}}
      _ -> {:error, :bad_rpn}
    end
  end

  defp fetch_type_fields(:library, raw) do
    case fetch(raw, :library_key, "library_key") do
      key when is_binary(key) or is_atom(key) ->
        if to_string(key) in @library_keys do
          {:ok, %{library_key: to_string(key), rpn: nil}}
        else
          {:error, :bad_library_key}
        end

      _ ->
        {:error, :bad_library_key}
    end
  end

  defp normalize_bindings(%{} = bindings) do
    Map.new(bindings, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_bindings(_), do: %{}

  defp fetch(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end
end
