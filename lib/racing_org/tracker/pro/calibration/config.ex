defmodule RacingOrg.Tracker.Pro.Calibration.Config do
  @moduledoc """
  Owns the device's sensor-calibration state: the server-pushed `set_calibration`
  POLICY (versioned, idempotent — which parameters may auto-apply, plus explicit
  per-sensor locks) AND the LEARNED per-sensor corrections the on-device
  estimation layer records via `put_learned/4`. Both are persisted to `/data`
  (`RacingOrg.Tracker.Pro.Calibration.Store`) so they survive reboots WITHOUT
  reflashing.

  Modeled on `RacingOrg.Tracker.Pro.ClockSource.Config`:

    * The persisted state is the AUTHORITY. On boot it is loaded and treated as
      already-applied (a re-push of the same version is a no-op). With nothing
      persisted the device runs the SAFE DEFAULTS (modes below, no locks, nothing
      learned — i.e. NO corrections, the current behavior). Because
      `applied_version` starts at `nil`, the FIRST config (even `version: 0`) is
      always applied.
    * `apply_config/2` is idempotent on `version`: a version already applied
      (`<=` the last-applied) is a no-op returning `{:ok, :unchanged}`.

  ## Parameters and modes

  Four calibration parameters, each with a server-set mode:

      awa_offset   "off" | "shadow" | "auto"   (default "auto")
      awa_upwash   "off" | "shadow" | "auto"   (default "auto")
      stw_scale    "off" | "shadow" | "auto"   (default "auto")
      aws_scale    "off" | "shadow"            (default "shadow", never auto-applied)

  Unknown parameter names/modes in a push are IGNORED (logged) — they never
  reject the whole config. A missing/invalid `version` rejects it
  (`{:error, :bad_version}`).

  ## Corrections (what the compute engine applies)

  `corrections/1` compiles the state into the map
  `RacingOrg.Tracker.Pro.Compute.Engine` caches:

      %{hex => %{awa_offset_deg: f,
                 awa_upwash: [{tws_center_mps, deg}],
                 stw_gains: [{band_center_mps, gain}]}}

  `awa_upwash` is a TWS curve the engine interpolates at apply time (a learned
  or locked flat float compiles to the single point `[{0.0, deg}]`); every
  point is clamped to ±10° at compile time.

  including ONLY:

    * LOCKED pins (`locked: true` + a numeric value) — explicit operator intent,
      applied even in `shadow` mode; excluded only when the parameter mode is
      `"off"`;
    * learned entries whose `state == "applied"` AND whose parameter mode is
      `"auto"` (a locked (sensor, parameter) always wins over its learned entry).

  `aws_scale` never compiles into corrections (its maximum mode is shadow); it is
  still recorded/reported for the server to observe.

  ## Wire contract (server → device, Slipstream event `"set_calibration"`)

      %{"version" => 3,
        "parameters" => %{"awa_offset" => %{"mode" => "auto"}, ...},
        "sensors" => [%{"hardware_identifier" => "1A2B", "parameter" => "awa_offset",
                        "locked" => true, "value" => 2.5}]}

  Sensor `hardware_identifier`s are canonicalized to the backend's uppercase-hex
  form via `RacingOrg.Tracker.Pro.NmeaIdentity.canonical_hardware_id/1`, the same
  identity the engine derives from each telemetry event's NMEA NAME.

  ## Wire contract (device → server)

  `status/1` is pushed verbatim as the `"calibration_status"` event and must
  stay JSON-encodable: scalar learned/locked values pass through as numbers,
  and curve-valued parameters render as maps — `stw_scale` as
  `[%{center: band_center_mps, gain: g}]`, `awa_upwash` as
  `[%{center: tws_center_mps, value: deg}]` (the key names the backend
  expects). The Observer's throttled `"calibration_update"` entries carry the
  SAME curve rendering under a `curve` key, alongside a scalar representative
  `value` (see `RacingOrg.Tracker.Pro.Calibration.Observer`).
  """

  use GenServer
  require Logger

  alias RacingOrg.Tracker.Pro.Calibration.Store
  alias RacingOrg.Tracker.Pro.NmeaIdentity

  @default_store_dir "/data/calibration"

  @parameters ~w(awa_offset awa_upwash stw_scale aws_scale)
  # The parameters that can compile into engine corrections (aws_scale is
  # shadow-only: observed + reported, never applied).
  @corrected_parameters ~w(awa_offset awa_upwash stw_scale)
  @learned_states ~w(learning validated applied shadow)

  @default_modes %{
    "awa_offset" => "auto",
    "awa_upwash" => "auto",
    "stw_scale" => "auto",
    "aws_scale" => "shadow"
  }

  @type learned_entry :: %{
          value: number() | [{number(), number()}],
          confidence: number(),
          sample_count: non_neg_integer(),
          state: String.t()
        }
  @type corrections :: %{
          optional(String.t()) => %{
            optional(:awa_offset_deg) => number(),
            optional(:awa_upwash) => [{number(), number()}],
            optional(:stw_gains) => [{number(), number()}]
          }
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
  Apply a server-pushed calibration config (called by the WSS channel handler).
  Accepts string OR atom keys. Idempotent on `version` (a version `<=` the
  last-applied is `{:ok, :unchanged}`; the first config is always applied).
  Returns `{:ok, config}` on apply or `{:error, reason}` for a malformed payload
  (missing/invalid `version`); on error nothing is persisted/applied. Unknown
  parameter names/modes and unusable sensor entries are ignored (logged), never
  rejecting the config. On apply the state is persisted and subscribers are
  notified.
  """
  @spec apply_config(GenServer.server(), map()) :: {:ok, map()} | {:ok, :unchanged} | {:error, atom()}
  def apply_config(server \\ __MODULE__, config) when is_map(config) do
    GenServer.call(server, {:apply_config, config})
  end

  @doc "Purely validate and normalize a complete desired calibration policy."
  @spec validate_config(term()) :: {:ok, map()} | {:error, term()}
  def validate_config(config), do: strict_normalize(config)

  @doc "Durably reconcile desired policy while preserving owner-learned calibration state."
  @spec reconcile_config(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def reconcile_config(server \\ __MODULE__, config) when is_map(config) do
    GenServer.call(server, {:reconcile_config, config})
  end

  @doc "Durably clear desired calibration authority and restore compile-time defaults."
  @spec reset_config(GenServer.server()) :: :ok | {:error, term()}
  def reset_config(server \\ __MODULE__) do
    GenServer.call(server, :reset_config)
  end

  @doc """
  Record a learned calibration estimate for `(sensor, parameter)` — called by the
  on-device estimation layer. `entry` is `%{value: v, confidence: f,
  sample_count: n, state: s}` with `state` one of `"learning" | "validated" |
  "applied" | "shadow"`. For `stw_scale` the value may be a single float (a
  uniform gain) or a list of `{band_center_mps, gain}` pairs; for `awa_upwash`
  a single float (flat) or a list of `{tws_center_mps, deg}` curve points —
  lists are normalized to sorted pair lists. The sensor id is canonicalized to
  uppercase hex. A LOCKED
  (sensor, parameter) still stores the entry, but the lock always wins in the
  compiled corrections. Persisted; subscribers are notified ONLY when the
  APPLIED corrections map actually changes.
  """
  @spec put_learned(GenServer.server(), term(), String.t(), map()) :: :ok | {:error, atom()}
  def put_learned(server \\ __MODULE__, sensor_id, parameter, entry) when is_map(entry) do
    GenServer.call(server, {:put_learned, sensor_id, parameter, entry})
  end

  @doc """
  Atomically reconcile a complete batch of observer-learned entries.

  Every row is validated before a candidate state is persisted. Persistence
  failure or one invalid row leaves the Config process unchanged. The batch is
  complete observer authority, so stale learned rows absent from it are removed;
  operator-owned modes and locks are preserved.
  """
  @spec reconcile_learned(GenServer.server(), [map()]) :: :ok | {:error, atom() | term()}
  def reconcile_learned(server \\ __MODULE__, entries) when is_list(entries) do
    GenServer.call(server, {:reconcile_learned, entries})
  end

  @doc """
  The compiled per-sensor corrections map the compute engine caches — see the
  module doc for the inclusion rules. `%{}` when nothing is applied.
  """
  @spec corrections(GenServer.server()) :: corrections()
  def corrections(server \\ __MODULE__) do
    GenServer.call(server, :corrections)
  end

  @doc """
  The allowlisted calibration status the server records: applied_version, modes
  (parameter => mode string), sensors (flattened from learned + locks; a locked
  (sensor, parameter) reports `state: "locked"` with the pinned value), status.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc "The currently-applied config version (`nil` if none applied yet)."
  @spec applied_version(GenServer.server()) :: integer() | nil
  def applied_version(server \\ __MODULE__) do
    GenServer.call(server, :applied_version)
  end

  @doc """
  Subscribe `pid` to calibration-change notifications. Subscribers receive
  `{:racing_org_calibration, :updated}` whenever a config is applied or the
  compiled corrections change (loose contract, like
  `RacingOrg.Tracker.Pro.Commands.subscribe/2`).
  """
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server \\ __MODULE__, pid \\ self()), do: GenServer.call(server, {:subscribe, pid})

  # --- Server ---

  @impl true
  def init(opts) do
    state = %{
      store_dir: Keyword.get(opts, :store_dir, @default_store_dir),
      store_opts: Keyword.take(opts, [:file_system, :fault_injector]),
      # nil = nothing applied yet, so any incoming version (incl. 0) is newer.
      applied_version: nil,
      modes: @default_modes,
      locks: %{},
      learned: %{},
      subscribers: MapSet.new()
    }

    {:ok, reconcile(state)}
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
        state = %{
          state
          | applied_version: nil,
            modes: @default_modes,
            locks: %{},
            learned: %{}
        }

        notify(state)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_learned, sensor_id, parameter, entry}, _from, state) do
    {result, state} = do_put_learned(sensor_id, parameter, entry, state)
    {:reply, result, state}
  end

  def handle_call({:reconcile_learned, entries}, _from, state) do
    {result, state} = do_reconcile_learned(entries, state)
    {:reply, result, state}
  end

  def handle_call(:corrections, _from, state) do
    {:reply, compile_corrections(state), state}
  end

  def handle_call(:status, _from, state) do
    {:reply, build_status(state), state}
  end

  def handle_call(:applied_version, _from, state) do
    {:reply, state.applied_version, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Reconcile / apply ---

  # Boot: the persisted state is the authority and is treated as already-applied.
  defp reconcile(%{store_dir: nil} = state), do: state

  defp reconcile(state) do
    case Store.load(state.store_dir) do
      {:ok, persisted} ->
        Logger.info(
          "[Calibration.Config] reconciling persisted state (version=#{inspect(persisted[:applied_version])})"
        )

        %{
          state
          | applied_version: Map.get(persisted, :applied_version),
            modes: Map.get(persisted, :modes, @default_modes),
            locks: Map.get(persisted, :locks, %{}),
            learned: Map.get(persisted, :learned, %{})
        }

      :empty ->
        state
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
        state = %{state | applied_version: config.version, modes: config.modes, locks: config.locks}
        _ = maybe_persist(state)
        notify(state)
        {{:ok, config}, state}
    end
  end

  defp do_reconcile(raw, state) do
    with {:ok, config} <- strict_normalize(raw) do
      candidate = %{
        state
        | applied_version: config.version,
          modes: config.modes,
          locks: config.locks
      }

      case maybe_persist(candidate) do
        :ok ->
          notify(candidate)
          {{:ok, config}, candidate}

        {:error, reason} ->
          {{:error, reason}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp do_put_learned(sensor_id, parameter, entry, state) do
    with {:ok, parameter} <- validate_parameter(parameter),
         {:ok, entry} <- validate_entry(parameter, entry) do
      hex = NmeaIdentity.canonical_hardware_id(sensor_id)
      before = compile_corrections(state)

      learned = Map.update(state.learned, hex, %{parameter => entry}, &Map.put(&1, parameter, entry))
      state = %{state | learned: learned}

      _ = maybe_persist(state)
      # Locks always win in the compiled map, so a learned entry under a locked
      # (sensor, parameter) — or one that is not applied+auto — changes nothing
      # applied and must NOT wake the engine.
      if compile_corrections(state) != before, do: notify(state)
      {:ok, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp do_reconcile_learned(entries, state) do
    with {:ok, normalized} <- normalize_learned_batch(entries) do
      before = compile_corrections(state)

      learned =
        Enum.reduce(normalized, %{}, fn {hex, parameter, entry}, learned ->
          Map.update(learned, hex, %{parameter => entry}, &Map.put(&1, parameter, entry))
        end)

      candidate = %{state | learned: learned}

      case maybe_persist(candidate) do
        :ok ->
          if compile_corrections(candidate) != before, do: notify(candidate)
          {:ok, candidate}

        {:error, reason} ->
          {{:error, reason}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp normalize_learned_batch(entries) do
    Enum.reduce_while(entries, {:ok, [], MapSet.new()}, fn row, {:ok, normalized, seen} ->
      with %{hardware_identifier: sensor_id, parameter: raw_parameter, entry: raw_entry} <- row,
           true <- map_size(row) == 3,
           {:ok, parameter} <- validate_parameter(raw_parameter),
           {:ok, entry} <- validate_entry(parameter, raw_entry),
           hex when is_binary(hex) and hex != "" <- NmeaIdentity.canonical_hardware_id(sensor_id),
           key = {hex, parameter},
           false <- MapSet.member?(seen, key) do
        {:cont, {:ok, [{hex, parameter, entry} | normalized], MapSet.put(seen, key)}}
      else
        _ -> {:halt, {:error, :bad_learned_batch}}
      end
    end)
    |> case do
      {:ok, normalized, _seen} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  rescue
    _ -> {:error, :bad_learned_batch}
  end

  defp validate_parameter(parameter) do
    parameter = to_string(parameter)
    if parameter in @parameters, do: {:ok, parameter}, else: {:error, :bad_parameter}
  end

  defp validate_entry(parameter, %{value: value, confidence: confidence, sample_count: sample_count, state: state})
       when is_number(confidence) and is_integer(sample_count) and sample_count >= 0 do
    with true <- to_string(state) in @learned_states,
         {:ok, value} <- validate_value(parameter, value) do
      {:ok, %{value: value, confidence: confidence, sample_count: sample_count, state: to_string(state)}}
    else
      _ -> {:error, :bad_entry}
    end
  end

  defp validate_entry(_parameter, _entry), do: {:error, :bad_entry}

  # stw_scale accepts a uniform float gain OR a {band_center_mps, gain} list;
  # awa_upwash accepts a flat float OR a {band_center_mps, deg} TWS curve.
  # Lists are normalized here to sorted pair lists so the engine interpolates
  # directly.
  defp validate_value("stw_scale", value) when is_list(value), do: validate_curve(value)
  defp validate_value("awa_upwash", value) when is_list(value), do: validate_curve(value)

  defp validate_value(_parameter, value) when is_number(value), do: {:ok, value}
  defp validate_value(_parameter, _value), do: {:error, :bad_entry}

  defp validate_curve(value) do
    if value != [] and Enum.all?(value, &match?({c, v} when is_number(c) and is_number(v), &1)) do
      {:ok, value |> Enum.sort_by(&elem(&1, 0)) |> Enum.uniq_by(&elem(&1, 0))}
    else
      {:error, :bad_entry}
    end
  end

  defp clear_persisted(%{store_dir: nil}), do: :ok
  defp clear_persisted(state), do: Store.clear(state.store_dir, state.store_opts)

  defp maybe_persist(%{store_dir: nil}), do: :ok

  defp maybe_persist(state) do
    Store.save(state.store_dir, %{
      applied_version: state.applied_version,
      modes: state.modes,
      locks: state.locks,
      learned: state.learned
    })
  end

  defp notify(state) do
    for pid <- state.subscribers, do: send(pid, {:racing_org_calibration, :updated})
    :ok
  end

  # --- Corrections compilation (what the compute engine caches) ---

  defp compile_corrections(state) do
    (Map.keys(state.learned) ++ Enum.map(Map.keys(state.locks), &elem(&1, 0)))
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn hex, acc ->
      case compile_sensor(state, hex) do
        empty when map_size(empty) == 0 -> acc
        entry -> Map.put(acc, hex, entry)
      end
    end)
  end

  defp compile_sensor(state, hex) do
    Enum.reduce(@corrected_parameters, %{}, fn parameter, acc ->
      case effective_value(state, hex, parameter) do
        nil -> acc
        value -> Map.put(acc, correction_field(parameter), normalize_correction(parameter, value))
      end
    end)
  end

  # The value the engine should apply for (hex, parameter), honoring the mode +
  # lock precedence: `off` disables everything; a locked numeric pin wins (even in
  # shadow — explicit operator intent); otherwise a learned `applied` estimate
  # only when the mode is `auto`.
  defp effective_value(state, hex, parameter) do
    mode = Map.get(state.modes, parameter, "off")

    cond do
      mode == "off" -> nil
      (pin = locked_pin(state, hex, parameter)) != nil -> pin
      mode == "auto" -> applied_learned_value(state, hex, parameter)
      true -> nil
    end
  end

  defp locked_pin(state, hex, parameter) do
    case Map.get(state.locks, {hex, parameter}) do
      %{locked: true, value: value} when is_number(value) -> value
      _ -> nil
    end
  end

  defp applied_learned_value(state, hex, parameter) do
    case get_in(state.learned, [hex, parameter]) do
      %{state: "applied", value: value} -> value
      _ -> nil
    end
  end

  # The compiled upwash curve is clamped point-by-point: corrections beyond a
  # few degrees are physically implausible and must not reach the engine even
  # via a locked pin.
  @max_upwash_deg 10.0

  defp correction_field("awa_offset"), do: :awa_offset_deg
  defp correction_field("awa_upwash"), do: :awa_upwash
  defp correction_field("stw_scale"), do: :stw_gains

  # stw_scale compiles to a gain-band list and awa_upwash to a {center_mps, deg}
  # TWS curve: a (locked or learned) uniform float becomes a single flat point;
  # learned lists are already normalized (sorted + uniq) on write. Every upwash
  # point is clamped to +/-#{@max_upwash_deg} degrees at compile time.
  defp normalize_correction("stw_scale", value) when is_number(value), do: [{0.0, value}]
  defp normalize_correction("stw_scale", value) when is_list(value), do: value

  defp normalize_correction("awa_upwash", value) when is_number(value), do: [{0.0, clamp_upwash(value)}]

  defp normalize_correction("awa_upwash", value) when is_list(value),
    do: Enum.map(value, fn {center, deg} -> {center, clamp_upwash(deg)} end)

  defp normalize_correction(_parameter, value), do: value

  defp clamp_upwash(deg), do: deg |> min(@max_upwash_deg) |> max(-@max_upwash_deg)

  # --- Status ---

  defp build_status(state) do
    %{
      applied_version: state.applied_version,
      modes: state.modes,
      sensors: sensor_status(state),
      status: "ok"
    }
  end

  # Flatten learned + locks into one entry per (sensor, parameter). A locked
  # (sensor, parameter) reports state "locked" with the PINNED value (what is
  # applied); learned diagnostics (confidence/sample_count) ride along when known.
  defp sensor_status(state) do
    learned_keys = for {hex, params} <- state.learned, {parameter, _} <- params, do: {hex, parameter}
    locked_keys = for {key, %{locked: true}} <- state.locks, do: key

    (learned_keys ++ locked_keys)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn {hex, parameter} ->
      learned = get_in(state.learned, [hex, parameter])
      lock = Map.get(state.locks, {hex, parameter})

      {state_s, value} =
        case lock do
          %{locked: true, value: pinned} -> {"locked", pinned}
          _ -> {learned.state, learned.value}
        end

      %{
        hardware_identifier: hex,
        parameter: parameter,
        state: state_s,
        value: status_value(parameter, value),
        confidence: learned && learned.confidence,
        sample_count: learned && learned.sample_count
      }
    end)
  end

  # Curve values are {center, y} tuple lists internally — not JSON-encodable.
  # The status (pushed verbatim as "calibration_status") renders them as maps:
  # stw curves as [%{center:, gain:}], upwash curves as [%{center:, value:}]
  # (the keys the backend expects). Scalars pass through.
  defp status_value("stw_scale", value) when is_list(value),
    do: Enum.map(value, fn {center, gain} -> %{center: center, gain: gain} end)

  defp status_value("awa_upwash", value) when is_list(value),
    do: Enum.map(value, fn {center, deg} -> %{center: center, value: deg} end)

  defp status_value(_parameter, value), do: value

  # --- Strict Desired State normalization ---

  defp strict_normalize(%{} = raw) do
    with {:ok, version} <- strict_version(raw),
         {:ok, modes} <- strict_parameters(fetch(raw, :parameters, "parameters")),
         {:ok, locks} <- strict_sensors(fetch(raw, :sensors, "sensors")) do
      {:ok, %{version: version, modes: modes, locks: locks}}
    end
  end

  defp strict_normalize(_raw), do: {:error, :malformed}

  defp strict_version(raw) do
    case fetch(raw, :version, "version") do
      version when is_integer(version) and version >= 0 -> {:ok, version}
      _other -> {:error, :bad_version}
    end
  end

  defp strict_parameters(%{} = parameters) do
    if map_size(parameters) == length(@parameters) do
      Enum.reduce_while(@parameters, {:ok, %{}}, fn parameter, {:ok, acc} ->
        case fetch(parameters, String.to_atom(parameter), parameter) do
          %{} = entry ->
            mode = fetch(entry, :mode, "mode")

            if is_binary(mode) and mode in allowed_modes(parameter) do
              {:cont, {:ok, Map.put(acc, parameter, mode)}}
            else
              {:halt, {:error, {:invalid_parameter_mode, parameter}}}
            end

          _other ->
            {:halt, {:error, {:invalid_parameter, parameter}}}
        end
      end)
    else
      {:error, :invalid_parameters}
    end
  end

  defp strict_parameters(_parameters), do: {:error, :invalid_parameters}

  defp strict_sensors(sensors) when is_list(sensors) do
    Enum.reduce_while(sensors, {:ok, %{}}, fn sensor, {:ok, acc} ->
      case strict_sensor(sensor) do
        {:ok, key, lock} ->
          if Map.has_key?(acc, key) do
            {:halt, {:error, :duplicate_sensor_lock}}
          else
            {:cont, {:ok, Map.put(acc, key, lock)}}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp strict_sensors(_sensors), do: {:error, :invalid_sensors}

  defp strict_sensor(%{} = sensor) do
    hardware_identifier = fetch(sensor, :hardware_identifier, "hardware_identifier")
    parameter = fetch(sensor, :parameter, "parameter")
    locked = fetch(sensor, :locked, "locked")
    value = fetch(sensor, :value, "value")

    with true <- is_binary(hardware_identifier) and hardware_identifier != "",
         hex when is_binary(hex) and hex != "" <-
           NmeaIdentity.canonical_hardware_id(hardware_identifier),
         true <- is_binary(parameter) and parameter in @parameters,
         true <- is_boolean(locked),
         true <- is_nil(value) or is_number(value),
         true <- not locked or is_number(value) do
      {:ok, {hex, parameter}, %{locked: locked, value: value}}
    else
      _other -> {:error, :invalid_sensor_lock}
    end
  end

  defp strict_sensor(_sensor), do: {:error, :invalid_sensor_lock}

  # --- Legacy normalization (string OR atom keys -> canonical) ---

  defp normalize(%{} = raw) do
    with {:ok, version} <- fetch_version(raw) do
      {:ok,
       %{
         version: version,
         modes: parse_parameters(fetch(raw, :parameters, "parameters")),
         locks: parse_sensors(fetch(raw, :sensors, "sensors"))
       }}
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

  # Defaults overlaid with the valid pushed entries; unknown parameter names or
  # modes are ignored (logged) so one bad entry never rejects the config.
  defp parse_parameters(%{} = parameters) do
    Enum.reduce(parameters, @default_modes, fn {name, entry}, acc ->
      name = to_string(name)

      case parse_mode(name, entry) do
        {:ok, mode} ->
          Map.put(acc, name, mode)

        :error ->
          Logger.warning("[Calibration.Config] ignoring unknown calibration parameter/mode: #{inspect({name, entry})}")
          acc
      end
    end)
  end

  defp parse_parameters(_), do: @default_modes

  defp parse_mode(name, %{} = entry) do
    mode = fetch(entry, :mode, "mode")

    if name in @parameters and not is_nil(mode) and to_string(mode) in allowed_modes(name) do
      {:ok, to_string(mode)}
    else
      :error
    end
  end

  defp parse_mode(_name, _entry), do: :error

  defp allowed_modes("aws_scale"), do: ~w(off shadow)
  defp allowed_modes(_), do: ~w(off shadow auto)

  defp parse_sensors(sensors) when is_list(sensors) do
    Enum.reduce(sensors, %{}, fn sensor, acc ->
      case parse_sensor(sensor) do
        {:ok, key, lock} ->
          Map.put(acc, key, lock)

        :error ->
          Logger.warning("[Calibration.Config] ignoring unusable calibration sensor entry: #{inspect(sensor)}")
          acc
      end
    end)
  end

  defp parse_sensors(_), do: %{}

  defp parse_sensor(%{} = sensor) do
    hex = NmeaIdentity.canonical_hardware_id(fetch(sensor, :hardware_identifier, "hardware_identifier"))
    parameter = fetch(sensor, :parameter, "parameter")
    parameter = if is_nil(parameter), do: nil, else: to_string(parameter)

    if is_binary(hex) and parameter in @parameters do
      {:ok, {hex, parameter},
       %{locked: fetch(sensor, :locked, "locked") == true, value: parse_value(fetch(sensor, :value, "value"))}}
    else
      :error
    end
  end

  defp parse_sensor(_), do: :error

  defp parse_value(value) when is_number(value), do: value
  defp parse_value(_), do: nil

  defp fetch(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end
end
