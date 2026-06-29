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

  All side effects (clock, persistence dir, max-age, commands) are injectable via
  `start_link/1` opts so the engine is fully unit-testable on host.
  """

  use GenServer
  require Logger

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.Compute.Expr
  alias RacingOrg.Tracker.Pro.Compute.Library
  alias RacingOrg.Tracker.Pro.Compute.Store
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
      # nil = nothing applied yet, so any incoming version (incl. 0) is newer.
      applied_version: nil,
      defs: [],
      # signal_name => {value_in_catalog_units, mono_ms}
      signals: %{}
    }

    state = reconcile(opts, state)
    attach_telemetry(handler_id, opts)
    state = init_polar(state)

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
  @impl true
  def handle_info({:signal_updates, updates, mono_ms}, state) do
    signals =
      Enum.reduce(updates, state.signals, fn {name, value}, acc ->
        Map.put(acc, name, {value, mono_ms})
      end)

    # Re-inject designated calc outputs (currently the on-device `:true_wind` calc's
    # true_wind_* outputs) back into the signal map as canonical signals so the
    # polar/next-leg calcs drive off an APPARENT-only boat too (no network true-wind
    # PGN). Event-driven (only on a signal change), fresh-timestamped, with NO
    # cross-process call and NO polar rebuild — see feed_back_outputs/3.
    signals = feed_back_outputs(%{state | signals: signals}, mono_ms)

    # Event-driven recompute happens implicitly: current_values/status recompute fresh
    # against state.signals. (Holding per-def cached results is unnecessary for Phase 7
    # and would only risk staleness; Phase 8 reads current_values which is always live.)
    {:noreply, %{state | signals: signals}}
  end

  # A polar-table command was applied -> the polar may have changed; refresh the
  # cached lookup ONCE (off the hot path). Other commands are ignored here.
  def handle_info({:racing_org_command, %DeviceCommand{payload: {:polar_table, _table}}}, state) do
    {:noreply, refresh_polar(state)}
  end

  def handle_info({:racing_org_command, _command}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

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
  # canonical signals (converting units) and forwards them to the engine process.
  def handle_event(event, measurements, metadata, %{target: target}) do
    mono_ms = mono_ms(metadata)

    case decode_signals(event, measurements) do
      [] -> :ok
      updates -> send(target, {:signal_updates, updates, mono_ms})
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

  defp maybe_persist(nil, _config), do: :ok
  defp maybe_persist(dir, config), do: Store.save(dir, config)

  # --- normalization (string OR atom keys -> canonical defs) ---

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

  @library_keys ~w(true_wind vmg vmc polar_performance target_boat_speed target_twa vmg_performance
                   next_leg_twa next_leg_aws next_leg_awa)

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
