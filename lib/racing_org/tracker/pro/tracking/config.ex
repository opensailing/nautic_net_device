defmodule RacingOrg.Tracker.Pro.Tracking.Config do
  @moduledoc """
  Owns the device's per-tracking-state damping + send-rate config: the
  server-pushed `set_tracking` config (versioned, idempotent), persisted to `/data`
  so it survives reboots WITHOUT reflashing, and applied to the telemetry pipeline
  via an injected side effect.

  Mirrors `RacingOrg.Tracker.Pro.WiFiManager` exactly:

    * The persisted config in `RacingOrg.Tracker.Pro.Tracking.Store` is the AUTHORITY. On boot it
      is loaded and treated as already-applied (so a re-push of the same version is a
      no-op). With no persisted config the device runs SAFE DEFAULTS (1 Hz / no
      damping) until the server pushes one — and because `applied_version` starts at
      `nil`, the FIRST config (even `version: 0`, which is a REAL config — the server
      defaults) is always applied.
    * `apply_config/2` is idempotent on `version`: a `version` already applied (`<=`
      the last-applied) is a no-op returning `{:ok, :unchanged}`. Otherwise it
      persists the new config, invokes the injected `on_apply` side effect (which
      re-drives `RacingOrg.Tracker.Pro.Sampling`), and only then publishes the version
      in memory and returns `{:ok, config}`.

  ## The wire contract (server → device, Slipstream event `"set_tracking"`)

      %{ "version" => 0,
         "states" => %{
           "pre_race" => %{"damping_seconds" => 2.0, "send_rate_hz" => 1.0},
           "starting" => %{"damping_seconds" => 1.0, "send_rate_hz" => 5.0},
           "race"     => %{"damping_seconds" => 0.5, "send_rate_hz" => 10.0} } }

  `version` is a monotonic integer starting at 0 (0 is a real config, not "unset").
  Each state carries `damping_seconds` (float >= 0; 0 = pass-through) and
  `send_rate_hz` (float > 0). All three states are always present.

  All side effects are injectable via `start_link/1` opts so the apply logic is fully
  unit-testable on host.
  """

  use GenServer
  require Logger

  alias RacingOrg.Tracker.Pro.Tracking.Store

  @states [:pre_race, :starting, :race]

  # Safe defaults until the server pushes a config: 1 Hz, no smoothing.
  @default_state %{damping_seconds: 0.0, send_rate_hz: 1.0}

  # Route-deviation threshold (meters of cross-track error) at which the device
  # requests a route recalc (P3). Pushed in the same set_tracking payload; this is
  # the default when the server omits it (older server) or sends a bad value.
  @default_deviation_threshold_m 50.0

  @default_store_dir "/data/tracking"

  @type state_name :: :pre_race | :starting | :race
  @type state_config :: %{damping_seconds: float(), send_rate_hz: float()}
  @type config :: %{
          version: integer(),
          states: %{state_name() => state_config()},
          deviation_threshold_meters: float()
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
  Apply a server-pushed tracking config (public API, called by the WSS channel
  handler). Accepts a map with string OR atom keys: `version` + `states`.

  Idempotent on `version`: if `version <= last-applied version`, this is a no-op
  returning `{:ok, :unchanged}`. The first config is always applied because the
  last-applied version starts at `nil` (so even `version: 0` is newer). Returns
  `{:ok, applied_config}` on apply, or `{:error, reason}` if validation,
  persistence, or the required side effect fails. A durably persisted candidate is
  retained for an idempotent retry when only the side effect fails.
  """
  @spec apply_config(GenServer.server(), map()) ::
          {:ok, config()} | {:ok, :unchanged} | {:error, term()}
  def apply_config(server \\ __MODULE__, config) when is_map(config) do
    GenServer.call(server, {:apply_config, config})
  end

  @doc "Purely validate and normalize a desired tracking config."
  @spec validate_config(term()) :: {:ok, config()} | {:error, term()}
  def validate_config(config), do: strict_normalize(config)

  @doc "Durably reconcile authoritative desired state, regardless of legacy version order."
  @spec reconcile_config(GenServer.server(), map()) :: {:ok, config()} | {:error, term()}
  def reconcile_config(server \\ __MODULE__, config) when is_map(config) do
    GenServer.call(server, {:reconcile_config, config})
  end

  @doc "Durably clear desired tracking authority and restore compile-time defaults."
  @spec reset_config(GenServer.server()) :: :ok | {:error, term()}
  def reset_config(server \\ __MODULE__) do
    GenServer.call(server, :reset_config)
  end

  @doc "The `{damping_seconds, send_rate_hz}` config for one tracking state."
  @spec get_state(GenServer.server(), state_name()) :: state_config()
  def get_state(server \\ __MODULE__, state_name) when state_name in @states do
    GenServer.call(server, {:get_state, state_name})
  end

  @doc "The currently-applied version (`nil` if none applied yet)."
  @spec applied_version(GenServer.server()) :: integer() | nil
  def applied_version(server \\ __MODULE__) do
    GenServer.call(server, :applied_version)
  end

  @doc """
  The current route-deviation threshold in meters of cross-track error (the
  `RacingOrg.Tracker.Pro.Nav.DeviationMonitor` reads this). Defaults to 50.0 m
  until the server pushes a config carrying `deviation_threshold_meters`.
  """
  @spec deviation_threshold(GenServer.server()) :: float()
  def deviation_threshold(server \\ __MODULE__) do
    GenServer.call(server, :deviation_threshold)
  end

  @doc "The full status: applied version + all three states + deviation threshold."
  @spec status(GenServer.server()) ::
          %{applied_version: integer() | nil, states: map(), deviation_threshold_meters: float()}
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  # --- Server ---

  @impl true
  def init(opts) do
    state = %{
      store_dir: Keyword.get(opts, :store_dir, @default_store_dir),
      store_opts: Keyword.take(opts, [:file_system, :fault_injector]),
      on_apply: Keyword.get(opts, :on_apply, fn _config -> :ok end),
      # nil = nothing applied yet, so any incoming version (incl. 0) is newer.
      applied_version: nil,
      states: default_states(),
      deviation_threshold_meters: @default_deviation_threshold_m
    }

    {:ok, reconcile(opts, state)}
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
      :ok ->
        config = %{
          version: nil,
          states: default_states(),
          deviation_threshold_meters: @default_deviation_threshold_m
        }

        state = apply_config_to_state(state, config)

        case safe_on_apply(state.on_apply, config) do
          :ok -> {:reply, :ok, state}
          {:error, reason} -> {:reply, {:error, {:on_apply_failed, reason}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_state, state_name}, _from, state) do
    {:reply, Map.get(state.states, state_name, @default_state), state}
  end

  def handle_call(:applied_version, _from, state) do
    {:reply, state.applied_version, state}
  end

  def handle_call(:deviation_threshold, _from, state) do
    {:reply, state.deviation_threshold_meters, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      applied_version: state.applied_version,
      states: state.states,
      deviation_threshold_meters: state.deviation_threshold_meters
    }

    {:reply, status, state}
  end

  # --- Reconcile / apply pipeline ---

  # Boot: a persisted config wins and is treated as already applied. An explicit
  # `:initial_config` opt (used by tests) is applied the same way. Otherwise SAFE
  # DEFAULTS until the server pushes one.
  defp reconcile(opts, state) do
    cond do
      cfg = opts[:initial_config] ->
        case normalize(cfg) do
          {:ok, config} -> apply_config_to_state(state, config)
          {:error, _} -> state
        end

      is_nil(state.store_dir) ->
        state

      true ->
        case Store.load(state.store_dir) do
          {:ok, config} ->
            Logger.info("[Tracking.Config] reconciling persisted config (version=#{config.version})")
            # A config persisted by an older build has no threshold key; fall back to
            # the default so the in-memory value is always a real float.
            apply_config_to_state(
              state,
              Map.put_new(config, :deviation_threshold_meters, @default_deviation_threshold_m)
            )

          :empty ->
            state
        end
    end
  end

  # Apply a normalized config map onto the GenServer state (states + version +
  # deviation threshold). Used by both boot reconciliation and a live apply.
  defp apply_config_to_state(state, config) do
    %{
      state
      | states: config.states,
        applied_version: config.version,
        deviation_threshold_meters: Map.get(config, :deviation_threshold_meters, state.deviation_threshold_meters)
    }
  end

  # Malformed payload: do not half-apply. A version <= the last-applied version is
  # an idempotent no-op (nil applied = nothing applied yet, so any version is newer).
  defp do_apply(raw, state) do
    case normalize(raw) do
      {:error, reason} ->
        {{:error, reason}, state}

      {:ok, %{version: version}}
      when is_integer(version) and not is_nil(state.applied_version) and version <= state.applied_version ->
        {{:ok, :unchanged}, state}

      {:ok, config} ->
        with :ok <- maybe_persist(state.store_dir, config) do
          case safe_on_apply(state.on_apply, config) do
            :ok ->
              {{:ok, config}, apply_config_to_state(state, config)}

            {:error, reason} ->
              {{:error, {:on_apply_failed, reason}}, state}
          end
        else
          {:error, reason} -> {{:error, reason}, state}
        end
    end
  end

  defp do_reconcile(raw, state) do
    with {:ok, config} <- strict_normalize(raw),
         :ok <- maybe_persist(state.store_dir, config) do
      case safe_on_apply(state.on_apply, config) do
        :ok ->
          {{:ok, config}, apply_config_to_state(state, config)}

        {:error, reason} ->
          {{:error, {:on_apply_failed, reason}}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  # --- Strict Desired State normalization ---
  #
  # The backend projection is COMPLETE, so the route-deviation threshold is
  # REQUIRED and must be a positive number here — unlike the legacy channel path
  # below, where an older server legitimately omits it and the safe default
  # applies. `version` is likewise an integer only: no string coercion.
  defp strict_normalize(%{} = raw) do
    with {:ok, version} <- strict_version(fetch(raw, :version, "version")),
         {:ok, states_map} <- fetch_states(raw),
         {:ok, states} <- normalize_states(states_map),
         {:ok, threshold} <-
           strict_threshold(fetch(raw, :deviation_threshold_meters, "deviation_threshold_meters")) do
      {:ok, %{version: version, states: states, deviation_threshold_meters: threshold}}
    end
  end

  defp strict_normalize(_raw), do: {:error, :malformed}

  defp strict_version(version) when is_integer(version) and version >= 0, do: {:ok, version}
  defp strict_version(_version), do: {:error, :bad_version}

  defp strict_threshold(value) when is_number(value) and value > 0, do: {:ok, value / 1}
  defp strict_threshold(_value), do: {:error, :bad_deviation_threshold}

  defp clear_persisted(%{store_dir: nil}), do: :ok
  defp clear_persisted(state), do: Store.clear(state.store_dir, state.store_opts)

  defp maybe_persist(nil, _config), do: :ok
  defp maybe_persist(dir, config), do: Store.save(dir, config)

  defp safe_on_apply(fun, config) do
    case fun.(config) do
      {:error, reason} -> {:error, reason}
      _other -> :ok
    end
  rescue
    _error ->
      Logger.warning("[Tracking.Config] on_apply raised")
      {:error, :exception}
  catch
    :exit, _reason -> {:error, :exit}
    _kind, _reason -> {:error, :failure}
  end

  # --- Normalization (string OR atom keys -> canonical) ---

  defp normalize(%{} = raw) do
    with {:ok, version} <- fetch_version(raw),
         {:ok, states_map} <- fetch_states(raw),
         {:ok, states} <- normalize_states(states_map) do
      {:ok,
       %{
         version: version,
         states: states,
         deviation_threshold_meters: fetch_deviation_threshold(raw)
       }}
    end
  end

  defp normalize(_), do: {:error, :malformed}

  # The route-deviation threshold is OPTIONAL (an older server omits it) and never
  # invalidates the whole config: a missing / non-numeric / non-positive value falls
  # back to the safe default rather than rejecting the payload.
  defp fetch_deviation_threshold(raw) do
    case fetch(raw, :deviation_threshold_meters, "deviation_threshold_meters") do
      n when is_number(n) and n > 0 -> n / 1
      _ -> @default_deviation_threshold_m
    end
  end

  defp fetch_version(raw) do
    case fetch(raw, :version, "version") do
      v when is_integer(v) -> {:ok, v}
      v when is_binary(v) -> {:ok, String.to_integer(v)}
      _ -> {:error, :bad_version}
    end
  rescue
    _ -> {:error, :bad_version}
  end

  defp fetch_states(raw) do
    case fetch(raw, :states, "states") do
      %{} = states -> {:ok, states}
      _ -> {:error, :bad_states}
    end
  end

  defp normalize_states(states_map) do
    Enum.reduce_while(@states, {:ok, %{}}, fn name, {:ok, acc} ->
      case normalize_one(states_map, name) do
        {:ok, sc} -> {:cont, {:ok, Map.put(acc, name, sc)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp normalize_one(states_map, name) do
    raw = fetch(states_map, name, Atom.to_string(name))

    case raw do
      %{} ->
        damping = fetch(raw, :damping_seconds, "damping_seconds")
        rate = fetch(raw, :send_rate_hz, "send_rate_hz")

        with {:ok, damping} <- to_damping(damping),
             {:ok, rate} <- to_rate(rate) do
          {:ok, %{damping_seconds: damping, send_rate_hz: rate}}
        end

      _ ->
        {:error, {:missing_state, name}}
    end
  end

  # damping >= 0 (0 = pass-through).
  defp to_damping(n) when is_number(n) and n >= 0, do: {:ok, n / 1}
  defp to_damping(_), do: {:error, :bad_damping}

  # send rate strictly > 0.
  defp to_rate(n) when is_number(n) and n > 0, do: {:ok, n / 1}
  defp to_rate(_), do: {:error, :bad_rate}

  defp fetch(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end

  defp default_states do
    Map.new(@states, fn name -> {name, @default_state} end)
  end
end
