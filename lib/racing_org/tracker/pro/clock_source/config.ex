defmodule RacingOrg.Tracker.Pro.ClockSource.Config do
  @moduledoc """
  Owns the device's clock-source policy: the server-pushed `set_clock_source`
  config (versioned, idempotent), persisted to `/data` so it survives reboots
  WITHOUT reflashing, and the live "boat-time" timebase derived from GPS/network
  time messages.

  Modeled on `RacingOrg.Tracker.Pro.Tracking.Config`:

    * The persisted config in `RacingOrg.Tracker.Pro.ClockSource.Store` is the
      AUTHORITY. On boot it is loaded and treated as already-applied (so a re-push
      of the same version is a no-op). With no persisted config the device runs the
      SAFE DEFAULT (`tracker_receive_time` — the CURRENT behavior) until the server
      pushes one. Because `applied_version` starts at `nil`, the FIRST config (even
      `version: 0`) is always applied.
    * `apply_config/2` is idempotent on `version`: a version already applied (`<=`
      the last-applied) is a no-op returning `{:ok, :unchanged}`.

  ## Timebase (boat clock)

  In `"sensor_priority"` mode this GenServer is ALSO registered as a
  `NMEA.NMEA2000.VirtualDevice` handler and observes decoded `NMEA.DateTimeParams`
  time messages. When a message comes from a CONFIGURED source (matched by stable
  identity — NMEA NAME / source address / hardware id / uid / label), it records a
  timebase `{gps_datetime, observed_monotonic_ms, active_source}`. Higher-priority
  sources preempt lower ones; a stale active source can be replaced by a
  lower-priority one.

  `resolve_timestamp/3` then computes, for any later telemetry frame:

      gps_datetime + (frame.timestamp_monotonic_ms - observed_monotonic_ms)

  If the mode is `tracker_receive_time`, or there is no valid/matched source, or
  the timebase is stale, it returns the frame's own receive timestamp (the current
  behavior). It NEVER mutates the OS clock — this decision is purely about the
  telemetry timestamp semantics. `timestamp_monotonic_ms` (used for ordering /
  damping) is untouched.

  Only the CONFIG is persisted; the timebase is runtime-only and is reset whenever
  a new config is applied (rebuilt from live time messages under the new policy).

  ## Wire contract (server → device, Slipstream event `"set_clock_source"`)

      %{ "version" => 1,
         "mode" => "tracker_receive_time" | "sensor_priority",
         "fallback" => "tracker_receive_time",
         "sources" => [ %{"priority" => 1, "sensor_id" => "...", "sensor_uid" => "...",
                          "hardware_identifier" => "...", "source_bus" => "nmea2000",
                          "source_address" => "35", "sensor_type" => "gnss",
                          "label" => "...", "metadata" => %{...}} ] }
  """

  use GenServer
  require Logger

  alias RacingOrg.Tracker.Pro.ClockSource.Store
  alias RacingOrg.Tracker.Pro.DeviceInfo

  @default_store_dir "/data/clock_source"
  # A matched source silent for longer than this (ms of monotonic time since its
  # last time sample) is considered stale, and the device falls back to the frame
  # receive timestamp until the source (or a lower-priority one) is heard again.
  @default_stale_ms 30_000
  # Sources with no/invalid priority sort last.
  @default_priority 1_000_000

  @type mode :: :tracker_receive_time | :sensor_priority
  @type source :: %{
          priority: integer(),
          sensor_id: String.t() | nil,
          sensor_uid: String.t() | nil,
          hardware_identifier: String.t() | nil,
          source_bus: String.t() | nil,
          source_address: String.t() | nil,
          sensor_type: String.t() | nil,
          label: String.t() | nil,
          metadata: map()
        }
  @type config :: %{version: integer(), mode: mode(), fallback: mode(), sources: [source()]}

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
  Apply a server-pushed clock-source config (called by the WSS channel handler).
  Accepts string OR atom keys. Idempotent on `version` (a version `<=` the
  last-applied is `{:ok, :unchanged}`; the first config is always applied). Returns
  `{:ok, config}` on apply or `{:error, reason}` for a malformed payload (missing/
  invalid `version`); on error nothing is persisted/applied. Applying a config
  RESETS the live timebase (rebuilt from live time messages under the new policy).
  """
  @spec apply_config(GenServer.server(), map()) ::
          {:ok, config()} | {:ok, :unchanged} | {:error, atom()}
  def apply_config(server \\ __MODULE__, config) when is_map(config) do
    GenServer.call(server, {:apply_config, config})
  end

  @doc """
  Resolve the boat-clock timestamp for a telemetry frame, given the frame's own
  receive timestamp (`fallback_ts`) and its monotonic timestamp. Returns a
  `DateTime`. In `sensor_priority` mode with a valid, fresh, matched timebase this
  is `gps_datetime + monotonic_delta`; otherwise it returns `fallback_ts` (current
  behavior). If the clock-source server is unavailable it also returns
  `fallback_ts`, so telemetry timestamp semantics never depend on this process.
  """
  @spec resolve_timestamp(GenServer.server(), DateTime.t(), integer()) :: DateTime.t()
  def resolve_timestamp(server \\ __MODULE__, fallback_ts, monotonic_ms) do
    GenServer.call(server, {:resolve_timestamp, fallback_ts, monotonic_ms})
  catch
    :exit, _ -> fallback_ts
  end

  @doc """
  The allowlisted clock-source status the server records: applied_version, mode,
  the active source's identity fields, the current timebase (`"sensor"` |
  `"tracker_receive_time"`), fallback_reason, last_gps_time (ISO-8601), status.
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

  # --- Server ---

  @impl true
  def init(opts) do
    state = %{
      store_dir: Keyword.get(opts, :store_dir, @default_store_dir),
      stale_ms: Keyword.get(opts, :stale_ms, @default_stale_ms),
      now_fn: Keyword.get(opts, :now_fn, fn -> System.monotonic_time(:millisecond) end),
      # nil = nothing applied yet, so any incoming version (incl. 0) is newer.
      applied_version: nil,
      mode: :tracker_receive_time,
      fallback: :tracker_receive_time,
      sources: [],
      timebase: nil
    }

    {:ok, reconcile(opts, state)}
  end

  @impl true
  def handle_call({:apply_config, config}, _from, state) do
    {result, state} = do_apply(config, state)
    {:reply, result, state}
  end

  def handle_call({:resolve_timestamp, fallback_ts, monotonic_ms}, _from, state) do
    {:reply, do_resolve(state, fallback_ts, monotonic_ms), state}
  end

  def handle_call(:status, _from, state) do
    {:reply, build_status(state), state}
  end

  def handle_call(:applied_version, _from, state) do
    {:reply, state.applied_version, state}
  end

  # Observe decoded time messages (registered as a VirtualDevice handler). Only
  # NMEA 2000 data carrying a `DateTimeParams` value + source identity can update
  # the timebase; everything else is ignored cheaply.
  @impl true
  def handle_info({:data, %NMEA.Data{values: %{} = values} = data}, state) do
    state =
      case Map.get(values, NMEA.DateTimeParams) do
        %NMEA.DateTimeParams{datetime: %DateTime{} = dt} -> maybe_observe(state, data, dt)
        _ -> state
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Reconcile / apply ---

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
            Logger.info("[ClockSource.Config] reconciling persisted config (version=#{config.version})")
            apply_config_to_state(state, Map.put_new(config, :fallback, :tracker_receive_time))

          :empty ->
            state
        end
    end
  end

  # Apply a normalized config onto the state. ALWAYS resets the live timebase so a
  # policy change re-establishes the boat clock from fresh observations.
  defp apply_config_to_state(state, config) do
    %{
      state
      | mode: config.mode,
        fallback: config.fallback,
        sources: config.sources,
        applied_version: config.version,
        timebase: nil
    }
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
        {{:ok, config}, apply_config_to_state(state, config)}
    end
  end

  defp maybe_persist(nil, _config), do: :ok
  defp maybe_persist(dir, config), do: Store.save(dir, config)

  # --- Timebase observation ---

  defp maybe_observe(%{mode: :sensor_priority} = state, %NMEA.Data{} = data, dt) do
    case source_info(data) do
      {sa, mono} -> observe_time(state, dt, sa, source_name(data), mono)
      :error -> state
    end
  end

  defp maybe_observe(state, _data, _dt), do: state

  defp source_info(%NMEA.Data{source_info: %NMEA.NMEA2000.Frame{source_address: sa, timestamp_monotonic_ms: mono}})
       when not is_nil(mono),
       do: {sa, mono}

  defp source_info(_), do: :error

  defp source_name(%NMEA.Data{metadata: %{} = m}),
    do: Map.get(m, :source_nmea_name) || Map.get(m, "source_nmea_name")

  defp source_name(_), do: nil

  # A time sample from a configured source updates the timebase if there is none,
  # if the source is at least as high priority as the active one, or if the active
  # timebase has gone stale.
  defp observe_time(state, dt, sa, name, mono) do
    observed_hex = canonical_nmea_hardware_id(name)
    observed_text = to_str_or_nil(name)
    sa_s = to_str_or_nil(sa)

    case Enum.find(state.sources, &match_source?(&1, observed_hex, observed_text, sa_s)) do
      nil ->
        state

      source ->
        if adopt?(state, source, mono) do
          %{
            state
            | timebase: %{gps_datetime: dt, observed_monotonic_ms: mono, active_source: source, last_gps_time: dt}
          }
        else
          state
        end
    end
  end

  defp adopt?(%{timebase: nil}, _source, _mono), do: true

  defp adopt?(%{timebase: tb, stale_ms: stale}, source, mono) do
    source.priority <= tb.active_source.priority or mono - tb.observed_monotonic_ms > stale
  end

  # --- Source matching (best available stable identity) ---
  #
  # NMEA NAME identities — the observed `metadata.source_nmea_name` and the
  # configured `hardware_identifier` / `sensor_uid` / `metadata.source_nmea_name` —
  # are CANONICALIZED to the backend's uppercase-hex hardware-id form before
  # comparison, so a backend-selected sensor matches the live NAME whether it
  # arrives on the bus as an 8-byte binary or an integer (the backend derives its
  # hex id from the same NAME during DataSet ingest). `label` is matched as literal
  # text (not hex). The CAN `source_address` is an independent fallback. The backend
  # `sensor_id` is a server-internal id with no on-bus counterpart, so it is not
  # used for matching. NMEA 0183 time sources are not matched (no per-message source
  # identity is available on that path).
  defp match_source?(source, observed_hex, observed_text, sa_s) do
    identity_matches?(source, observed_hex) or label_matches?(source, observed_text) or
      address_matches?(source, sa_s)
  end

  defp identity_matches?(_source, nil), do: false

  defp identity_matches?(source, observed_hex) do
    [source.hardware_identifier, source.sensor_uid, metadata_name(source)]
    |> Enum.map(&canonical_nmea_hardware_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&(&1 == observed_hex))
  end

  defp label_matches?(%{label: nil}, _observed_text), do: false
  defp label_matches?(_source, nil), do: false
  defp label_matches?(source, observed_text), do: source.label == observed_text

  defp address_matches?(%{source_address: nil}, _sa_s), do: false
  defp address_matches?(_source, nil), do: false
  defp address_matches?(source, sa_s), do: source.source_address == sa_s

  defp metadata_name(%{metadata: %{} = m}),
    do: Map.get(m, "source_nmea_name") || Map.get(m, :source_nmea_name)

  defp metadata_name(_), do: nil

  # Canonicalize an NMEA NAME identity — the observed name from the bus OR a
  # configured identifier — into the backend's uppercase-hex hardware-id form, so
  # both sides compare equal:
  #
  #   * `nil` -> `nil`
  #   * a non-negative integer NMEA NAME -> uppercase hex
  #   * a printable hex string (optional `0x`/`0X` prefix) -> trimmed, unprefixed,
  #     UPPERCASE (the configured-identifier case, e.g. `"0x1a2b"` -> `"1A2B"`)
  #   * an 8-byte binary NMEA NAME -> unsigned 64-bit integer -> uppercase hex
  #     (the observed on-bus case; reuses `DeviceInfo.hw_id/1`)
  #   * any other binary (not hex, not 8 bytes) -> its original string, so literal
  #     label-style names still match and invalid text never crashes matching
  #   * anything else -> `to_string/1`
  defp canonical_nmea_hardware_id(nil), do: nil

  defp canonical_nmea_hardware_id(name) when is_integer(name) and name >= 0, do: integer_to_hex(name)

  defp canonical_nmea_hardware_id(name) when is_binary(name) do
    case printable_hex(name) do
      nil -> if byte_size(name) == 8, do: name |> DeviceInfo.hw_id() |> integer_to_hex(), else: name
      hex -> hex
    end
  end

  defp canonical_nmea_hardware_id(name), do: to_str_or_nil(name)

  # The uppercase-hex form of `name` if it is a printable hex string (optional
  # `0x`/`0X` prefix), else `nil`. Guarded on `String.printable?/1` so it is safe to
  # call on a raw (non-UTF-8) NAME binary.
  defp printable_hex(name) do
    if String.printable?(name) do
      candidate = name |> String.trim() |> strip_hex_prefix()
      if hex_string?(candidate), do: String.upcase(candidate)
    end
  end

  defp integer_to_hex(i) when is_integer(i) and i >= 0, do: i |> Integer.to_string(16) |> String.upcase()

  defp strip_hex_prefix("0x" <> rest), do: rest
  defp strip_hex_prefix("0X" <> rest), do: rest
  defp strip_hex_prefix(other), do: other

  defp hex_string?(""), do: false
  defp hex_string?(s) when is_binary(s), do: match?({_int, ""}, Integer.parse(s, 16))

  # --- Timestamp resolution ---

  defp do_resolve(%{mode: :sensor_priority, timebase: %{} = tb, stale_ms: stale}, fallback, mono) do
    delta = mono - tb.observed_monotonic_ms

    if delta <= stale do
      DateTime.add(tb.gps_datetime, delta, :millisecond)
    else
      fallback
    end
  end

  defp do_resolve(_state, fallback, _mono), do: fallback

  # --- Status ---

  defp build_status(state) do
    now = state.now_fn.()
    {timebase, reason, active} = timebase_view(state, now)

    %{
      applied_version: state.applied_version,
      mode: mode_string(state.mode),
      active_source_sensor_id: active && active.sensor_id,
      active_source_label: active && active.label,
      active_hw_id: active && active.hardware_identifier,
      active_source_address: active && active.source_address,
      timebase: timebase,
      fallback_reason: reason,
      last_gps_time: last_gps_iso(state),
      status: "ok"
    }
  end

  defp timebase_view(%{mode: :tracker_receive_time}, _now), do: {"tracker_receive_time", "default_mode", nil}

  defp timebase_view(%{mode: :sensor_priority, timebase: nil}, _now),
    do: {"tracker_receive_time", "no_valid_source", nil}

  defp timebase_view(%{mode: :sensor_priority, timebase: tb, stale_ms: stale}, now) do
    if now - tb.observed_monotonic_ms <= stale do
      {"sensor", nil, tb.active_source}
    else
      {"tracker_receive_time", "stale", nil}
    end
  end

  defp mode_string(:sensor_priority), do: "sensor_priority"
  defp mode_string(_), do: "tracker_receive_time"

  defp last_gps_iso(%{timebase: %{last_gps_time: %DateTime{} = dt}}), do: DateTime.to_iso8601(dt)
  defp last_gps_iso(_), do: nil

  # --- Normalization (string OR atom keys -> canonical) ---

  defp normalize(%{} = raw) do
    with {:ok, version} <- fetch_version(raw) do
      {:ok,
       %{
         version: version,
         mode: parse_mode(fetch(raw, :mode, "mode")),
         fallback: :tracker_receive_time,
         sources: parse_sources(fetch(raw, :sources, "sources"))
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

  defp parse_mode(m) when m in [:sensor_priority, "sensor_priority"], do: :sensor_priority
  defp parse_mode(_), do: :tracker_receive_time

  defp parse_sources(sources) when is_list(sources) do
    sources
    |> Enum.map(&parse_source/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.priority)
  end

  defp parse_sources(_), do: []

  defp parse_source(%{} = s) do
    %{
      priority: parse_priority(fetch(s, :priority, "priority")),
      sensor_id: to_str_or_nil(fetch(s, :sensor_id, "sensor_id")),
      sensor_uid: to_str_or_nil(fetch(s, :sensor_uid, "sensor_uid")),
      hardware_identifier: to_str_or_nil(fetch(s, :hardware_identifier, "hardware_identifier")),
      source_bus: to_str_or_nil(fetch(s, :source_bus, "source_bus")),
      source_address: to_str_or_nil(fetch(s, :source_address, "source_address")),
      sensor_type: to_str_or_nil(fetch(s, :sensor_type, "sensor_type")),
      label: to_str_or_nil(fetch(s, :label, "label")),
      metadata: parse_metadata(fetch(s, :metadata, "metadata"))
    }
  end

  defp parse_source(_), do: nil

  defp parse_priority(p) when is_integer(p), do: p

  defp parse_priority(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, _} -> n
      :error -> @default_priority
    end
  end

  defp parse_priority(_), do: @default_priority

  defp parse_metadata(%{} = m), do: m
  defp parse_metadata(_), do: %{}

  defp to_str_or_nil(nil), do: nil
  defp to_str_or_nil(v) when is_binary(v), do: v
  defp to_str_or_nil(v), do: to_string(v)

  defp fetch(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end
end
