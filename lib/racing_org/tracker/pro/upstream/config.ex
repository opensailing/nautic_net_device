defmodule RacingOrg.Tracker.Pro.Upstream.Config do
  @moduledoc """
  Owns the device's upstream signal selection: WHICH telemetry sample types the
  tracker streams to the backend — the server-pushed `set_upstream` config
  (versioned, idempotent), persisted to `/data` so it survives reboots WITHOUT
  reflashing, and consumed per-sample by `RacingOrg.Tracker.Pro.Telemetry` via a
  zero-cost `:persistent_term` read.

  Mirrors `RacingOrg.Tracker.Pro.Tracking.Config` exactly:

    * The persisted config in `RacingOrg.Tracker.Pro.Upstream.Store` is the
      AUTHORITY. On boot it is loaded and treated as already-applied (a re-push of
      the same version is a no-op). With no persisted config the device streams
      EVERYTHING (all-on default) until the server pushes one — and because
      `applied_version` starts at `nil`, the FIRST config (even `version: 0`) is
      always applied.
    * `apply_config/2` is idempotent on `version`: a `version` already applied is a
      no-op returning `{:ok, :unchanged}`. Otherwise it persists the new config,
      records the version, publishes the disabled-signal set to `:persistent_term`
      (the hot-path read), and returns `{:ok, config}`.

  ## The wire contract (server → device, Slipstream event `"set_upstream"`)

      %{ "version" => 0,
         "signals" => %{
           "heading" => true, "speed" => true, "velocity" => true,
           "wind" => true, "water_depth" => true, "attitude" => true } }

  `version` is a monotonic integer starting at 0 (0 is a real config, not
  "unset"). The signal set mirrors the backend's `Device.upstream_signals/0`;
  POSITION (and the tracker's own health sample) is deliberately NOT in the set —
  it always streams (it is how tracks and races exist), and a payload attempting
  `"position" => false` is ignored. Unknown signal keys are tolerated and dropped
  (forward compatibility with a newer server). Missing signals resolve ON —
  absence must never silently mute telemetry.

  ## The hot path

  `RacingOrg.Tracker.Pro.Telemetry.report_metric/3` runs at sample rate for every
  signal on the bus; a GenServer call per sample is unacceptable there. The
  default-named instance therefore publishes the DISABLED signal set (usually
  empty) to `:persistent_term` on every apply — writes happen only when the owner
  changes the selection (rare), reads are effectively free. `stream_signal?/1` is
  that read, defaulting to true (fail-open: dropping telemetry because a config
  process is down would be data loss).
  """

  use GenServer
  require Logger

  alias RacingOrg.Tracker.Pro.Upstream.Store

  # The filterable signals — mirrors the backend's Device.upstream_signals/0.
  # :position is deliberately absent: it always streams.
  @signals [:heading, :speed, :velocity, :wind, :water_depth, :attitude]

  @persistent_term_key {__MODULE__, :disabled_signals}

  @default_store_dir "/data/upstream"

  @type config :: %{version: integer(), signals: %{atom() => boolean()}}

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
  Apply a server-pushed upstream config (public API, called by the WSS channel
  handler). Accepts a map with string OR atom keys: `version` + `signals`.

  Idempotent on `version`: if `version <= last-applied version`, this is a no-op
  returning `{:ok, :unchanged}`. The first config is always applied because the
  last-applied version starts at `nil`. Returns `{:ok, applied_config}` on apply,
  or `{:error, reason}` if the payload is malformed (a malformed payload never
  changes state).
  """
  @spec apply_config(GenServer.server(), map()) ::
          {:ok, config()} | {:ok, :unchanged} | {:error, term()}
  def apply_config(server, payload) when is_map(payload) do
    GenServer.call(server, {:apply_config, payload})
  end

  @doc "Purely validate and normalize a desired upstream config."
  @spec validate_config(term()) :: {:ok, config()} | {:error, term()}
  def validate_config(payload), do: strict_normalize(payload)

  @doc "Durably reconcile authoritative desired state, regardless of legacy version order."
  @spec reconcile_config(GenServer.server(), map()) :: {:ok, config()} | {:error, term()}
  def reconcile_config(server, payload) when is_map(payload) do
    GenServer.call(server, {:reconcile_config, payload})
  end

  @doc "Durably clear desired upstream authority and restore all signals enabled."
  @spec reset_config(GenServer.server()) :: :ok | {:error, term()}
  def reset_config(server) do
    GenServer.call(server, :reset_config)
  end

  @doc "The last applied config version, or nil before any config."
  @spec applied_version(GenServer.server()) :: integer() | nil
  def applied_version(server), do: GenServer.call(server, :applied_version)

  @doc "Whether `signal` currently streams, read from this instance's state."
  @spec stream?(GenServer.server(), atom()) :: boolean()
  def stream?(server, signal), do: GenServer.call(server, {:stream?, signal})

  @doc """
  The `"upstream_status"` echo the channel pushes back to the server (the backend
  allowlists `applied_version` + `reported_at`; the channel stamps `reported_at`).
  """
  @spec upstream_status(GenServer.server()) :: %{applied_version: integer() | nil}
  def upstream_status(server), do: GenServer.call(server, :upstream_status)

  @doc """
  The HOT-PATH read: whether `signal`'s samples should be packaged for upstream.
  Reads the default-named instance's `:persistent_term` disabled-set directly —
  no process call. Defaults to true (everything streams) when no instance has
  published, and for any signal outside the filterable set (:position, :tracker,
  future sample types).
  """
  @spec stream_signal?(atom()) :: boolean()
  def stream_signal?(signal) do
    signal not in :persistent_term.get(@persistent_term_key, [])
  end

  @doc "The filterable signal set (mirrors the backend's Device.upstream_signals/0)."
  @spec signals() :: [atom()]
  def signals, do: @signals

  # --- GenServer ---

  @impl true
  def init(opts) do
    store_dir = Keyword.get(opts, :store_dir) || @default_store_dir
    # Only the default-named instance owns the global persistent_term (tests run
    # anonymous instances against their own tmp stores without fighting over it).
    publishes? = Keyword.get(opts, :name, __MODULE__) == __MODULE__

    state =
      case Store.load(store_dir) do
        {:ok, %{version: version, signals: signals}} ->
          %{
            store_dir: store_dir,
            store_opts: Keyword.take(opts, [:file_system, :fault_injector]),
            version: version,
            signals: resolve_signals(signals),
            publishes?: publishes?
          }

        :empty ->
          %{
            store_dir: store_dir,
            store_opts: Keyword.take(opts, [:file_system, :fault_injector]),
            version: nil,
            signals: all_on(),
            publishes?: publishes?
          }
      end

    if publishes?, do: publish(state.signals)
    {:ok, state}
  end

  @impl true
  def handle_call({:apply_config, payload}, _from, state) do
    with {:ok, config} <- normalize(payload) do
      cond do
        is_integer(state.version) and config.version <= state.version ->
          {:reply, {:ok, :unchanged}, state}

        true ->
          _ = Store.save(state.store_dir, config)
          new_state = install_config(state, config)
          {:reply, {:ok, config}, new_state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reconcile_config, payload}, _from, state) do
    with {:ok, config} <- strict_normalize(payload),
         :ok <- Store.save(state.store_dir, config) do
      {:reply, {:ok, config}, install_config(state, config)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:reset_config, _from, state) do
    case Store.clear(state.store_dir, state.store_opts) do
      :ok -> {:reply, :ok, install_config(state, %{version: nil, signals: all_on()})}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:applied_version, _from, state), do: {:reply, state.version, state}

  def handle_call({:stream?, signal}, _from, state) do
    {:reply, Map.get(state.signals, signal, true), state}
  end

  def handle_call(:upstream_status, _from, state) do
    {:reply, %{applied_version: state.version}, state}
  end

  @impl true
  def terminate(_reason, state) do
    # The selection must survive the process: the persistent_term stays published
    # (still the last applied truth); a restart reloads from the store and
    # republishes. Only note the shutdown.
    _ = state
    :ok
  end

  # --- Parsing (string or atom keys; malformed input never changes state) ---

  defp normalize(payload) when is_map(payload) do
    with {:ok, version} <- parse_version(payload),
         {:ok, signals} <- parse_signals(payload) do
      {:ok, %{version: version, signals: signals}}
    end
  end

  defp normalize(_payload), do: {:error, :malformed}

  # --- Strict Desired State normalization ---
  #
  # The backend projection is COMPLETE, so every filterable signal must be
  # present with a boolean value. The legacy `set_upstream` path above
  # deliberately resolves a MISSING signal to ON (absence must never silently
  # mute telemetry from an older server); here an absent signal means the
  # generation does not match the contract and is rejected outright.
  defp strict_normalize(payload) when is_map(payload) do
    with {:ok, version} <- parse_version(payload),
         {:ok, signals} <- strict_signals(Map.get(payload, "signals", Map.get(payload, :signals))) do
      {:ok, %{version: version, signals: signals}}
    end
  end

  defp strict_normalize(_payload), do: {:error, :malformed}

  defp strict_signals(%{} = raw) do
    Enum.reduce_while(@signals, {:ok, %{}}, fn signal, {:ok, acc} ->
      case Map.get(raw, Atom.to_string(signal), Map.get(raw, signal)) do
        value when is_boolean(value) -> {:cont, {:ok, Map.put(acc, signal, value)}}
        _other -> {:halt, {:error, {:invalid_signal_value, signal}}}
      end
    end)
  end

  defp strict_signals(_raw), do: {:error, :invalid_signals}

  defp install_config(state, config) do
    if state.publishes?, do: publish(config.signals)
    %{state | version: config.version, signals: config.signals}
  end

  defp parse_version(%{"version" => version}) when is_integer(version) and version >= 0, do: {:ok, version}
  defp parse_version(%{version: version}) when is_integer(version) and version >= 0, do: {:ok, version}
  defp parse_version(_payload), do: {:error, :invalid_version}

  defp parse_signals(payload) do
    raw = Map.get(payload, "signals") || Map.get(payload, :signals) || %{}

    if is_map(raw) do
      Enum.reduce_while(@signals, {:ok, %{}}, fn signal, {:ok, acc} ->
        case Map.get(raw, Atom.to_string(signal), Map.get(raw, signal, true)) do
          value when is_boolean(value) -> {:cont, {:ok, Map.put(acc, signal, value)}}
          _other -> {:halt, {:error, {:invalid_signal_value, signal}}}
        end
      end)
    else
      {:error, :invalid_signals}
    end
  end

  # A loaded (possibly older-format) signal map resolved to the full current set;
  # missing signals stream (absence never mutes telemetry).
  defp resolve_signals(signals) do
    Map.new(@signals, fn signal -> {signal, Map.get(signals, signal, true)} end)
  end

  defp all_on, do: Map.new(@signals, fn signal -> {signal, true} end)

  defp publish(signals) do
    disabled = for {signal, false} <- signals, do: signal
    :persistent_term.put(@persistent_term_key, disabled)
  end
end
