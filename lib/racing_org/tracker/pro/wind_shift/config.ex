defmodule RacingOrg.Tracker.Pro.WindShift.Config do
  @moduledoc """
  Owns the device's wind-shift POLICY: the server-pushed `set_wind_shift`
  config (versioned, idempotent), persisted to `/data/wind_shift` so a runtime
  change survives reboots WITHOUT reflashing.

  Modeled on `RacingOrg.Tracker.Pro.ClockSource.Config`:

    * The persisted config in `RacingOrg.Tracker.Pro.WindShift.Store` is the
      AUTHORITY. On boot it is loaded and treated as already-applied (so a
      re-push of the same version is a no-op). With no persisted config the
      device runs the built-in defaults until the server pushes one. Because
      `applied_version` starts at `nil`, the FIRST config (even `version: 0`)
      is always applied.
    * `apply_config/2` is idempotent on `version`: a version already applied
      (`<=` the last-applied) is a no-op returning `{:ok, :unchanged}`.

  ## Design: policy only (status composition lives in the channel)

  This process owns ONLY the policy triple (windows / alarms / wally mode) —
  it never touches the live predictor. The live wind-shift state (regime,
  confidence, oscillation, phase/lift, range) is owned by
  `RacingOrg.Tracker.Pro.WindShift.Observer`, and the channel's
  `"wind_shift_status"` reply is COMPOSED there from BOTH collaborators
  (`Config.status/1` supplies `applied_version` + `wally_mode`; the Observer
  supplies the live fields) — exactly the two-collaborator split the tracking
  config already uses (`Tracking.Config` applies, `Sampling` reports).

  The `RacingOrg.Tracker.Pro.WindShift.Observer` subscribes via `subscribe/2`
  and rebuilds its estimation cores when a new config lands (window changes
  reset the predictor's warmup — accepted; see the Observer moduledoc).

  ## Wire contract (server → device, Slipstream event `"set_wind_shift"`)

      %{ "version" => 1,
         "windows" => %{"fast_s" => 30, "mid_s" => 300, "slow_s" => 1500, "envelope_s" => 1800},
         "alarms"  => %{"new_extreme_margin_deg" => 2.0, "enabled" => true},
         "wally"   => %{"mode" => "off" | "shadow" | "on"} }

  Every field except `version` defaults on omission; unknown keys are ignored;
  invalid window/alarm values fall back to their defaults. The ONLY rejections
  are a missing/invalid `version` (`{:error, :bad_version}`) and an invalid
  wally mode (`{:error, :bad_wally_mode}` — the backend validates before
  pushing, but the device stays defensive). On error nothing is
  persisted/applied.
  """

  use GenServer
  require Logger

  alias RacingOrg.Tracker.Pro.WindShift.Store

  @default_store_dir "/data/wind_shift"

  @default_windows %{fast_s: 30.0, mid_s: 300.0, slow_s: 1500.0, envelope_s: 1800.0}
  @default_alarms %{new_extreme_margin_deg: 2.0, enabled: true}
  @default_wally_mode "off"
  @wally_modes ~w(off shadow on)

  @type config :: %{
          version: integer() | nil,
          windows: %{fast_s: float(), mid_s: float(), slow_s: float(), envelope_s: float()},
          alarms: %{new_extreme_margin_deg: float(), enabled: boolean()},
          wally_mode: String.t()
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
  Apply a server-pushed wind-shift config (called by the WSS channel handler).
  Accepts string OR atom keys. Idempotent on `version` (a version `<=` the
  last-applied is `{:ok, :unchanged}`; the first config is always applied).
  Returns `{:ok, config}` on apply, or `{:error, :bad_version}` /
  `{:error, :bad_wally_mode}` for a malformed payload; on error nothing is
  persisted/applied. On apply the config is persisted and subscribers are
  notified.
  """
  @spec apply_config(GenServer.server(), map()) :: {:ok, config()} | {:ok, :unchanged} | {:error, atom()}
  def apply_config(server \\ __MODULE__, config) when is_map(config) do
    GenServer.call(server, {:apply_config, config})
  end

  @doc """
  The full current policy (defaults when nothing is applied yet):
  `%{version, windows, alarms, wally_mode}`. The Observer reads this on boot
  and on every change notification to (re)build its cores.
  """
  @spec current(GenServer.server()) :: config()
  def current(server \\ __MODULE__) do
    GenServer.call(server, :current)
  end

  @doc """
  The policy half of the channel's `"wind_shift_status"` reply:
  `%{applied_version, wally_mode, status}`. The live predictor fields come from
  `RacingOrg.Tracker.Pro.WindShift.Observer.status/1`; the channel composes the
  two.
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
  Subscribe `pid` to config-change notifications. Subscribers receive
  `{:racing_org_wind_shift, :updated}` whenever a config is applied (loose
  contract, like `RacingOrg.Tracker.Pro.Calibration.Config.subscribe/2`).
  """
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server \\ __MODULE__, pid \\ self()), do: GenServer.call(server, {:subscribe, pid})

  # --- Server ---

  @impl true
  def init(opts) do
    state = %{
      store_dir: Keyword.get(opts, :store_dir, @default_store_dir),
      # nil = nothing applied yet, so any incoming version (incl. 0) is newer.
      applied_version: nil,
      windows: @default_windows,
      alarms: @default_alarms,
      wally_mode: @default_wally_mode,
      subscribers: MapSet.new()
    }

    {:ok, reconcile(opts, state)}
  end

  @impl true
  def handle_call({:apply_config, config}, _from, state) do
    {result, state} = do_apply(config, state)
    {:reply, result, state}
  end

  def handle_call(:current, _from, state) do
    {:reply, build_config(state), state}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{applied_version: state.applied_version, wally_mode: state.wally_mode, status: "ok"}, state}
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
            Logger.info("[WindShift.Config] reconciling persisted config (version=#{config.version})")
            apply_config_to_state(state, config)

          :empty ->
            state
        end
    end
  end

  defp apply_config_to_state(state, config) do
    %{
      state
      | applied_version: config.version,
        windows: config.windows,
        alarms: config.alarms,
        wally_mode: config.wally_mode
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
        state = apply_config_to_state(state, config)
        notify(state)
        {{:ok, config}, state}
    end
  end

  defp maybe_persist(nil, _config), do: :ok
  defp maybe_persist(dir, config), do: Store.save(dir, config)

  defp notify(state) do
    for pid <- state.subscribers, do: send(pid, {:racing_org_wind_shift, :updated})
    :ok
  end

  defp build_config(state) do
    %{version: state.applied_version, windows: state.windows, alarms: state.alarms, wally_mode: state.wally_mode}
  end

  # --- Normalization (string OR atom keys -> canonical) ---

  defp normalize(%{} = raw) do
    with {:ok, version} <- fetch_version(raw),
         {:ok, wally_mode} <- parse_wally(fetch(raw, :wally, "wally")) do
      {:ok,
       %{
         version: version,
         windows: parse_windows(fetch(raw, :windows, "windows")),
         alarms: parse_alarms(fetch(raw, :alarms, "alarms")),
         wally_mode: wally_mode
       }}
    end
  end

  defp normalize(_), do: {:error, :bad_version}

  defp fetch_version(raw) do
    case fetch(raw, :version, "version") do
      v when is_integer(v) -> {:ok, v}
      v when is_binary(v) -> {:ok, String.to_integer(v)}
      _ -> {:error, :bad_version}
    end
  rescue
    _ -> {:error, :bad_version}
  end

  # A missing wally block (or missing mode) defaults to "off"; only an
  # explicitly BAD mode rejects.
  defp parse_wally(%{} = wally) do
    case fetch(wally, :mode, "mode") do
      nil -> {:ok, @default_wally_mode}
      mode when is_binary(mode) and mode in @wally_modes -> {:ok, mode}
      mode when is_atom(mode) -> parse_wally(%{mode: to_string(mode)})
      _ -> {:error, :bad_wally_mode}
    end
  end

  defp parse_wally(nil), do: {:ok, @default_wally_mode}
  defp parse_wally(_), do: {:error, :bad_wally_mode}

  # Windows/alarms default per-key: a missing or invalid value falls back to
  # its default (only bad version / bad wally mode reject); unknown keys are
  # ignored.
  defp parse_windows(%{} = windows) do
    %{
      fast_s: positive_number(fetch(windows, :fast_s, "fast_s"), @default_windows.fast_s),
      mid_s: positive_number(fetch(windows, :mid_s, "mid_s"), @default_windows.mid_s),
      slow_s: positive_number(fetch(windows, :slow_s, "slow_s"), @default_windows.slow_s),
      envelope_s: positive_number(fetch(windows, :envelope_s, "envelope_s"), @default_windows.envelope_s)
    }
  end

  defp parse_windows(_), do: @default_windows

  defp parse_alarms(%{} = alarms) do
    %{
      new_extreme_margin_deg:
        positive_number(
          fetch(alarms, :new_extreme_margin_deg, "new_extreme_margin_deg"),
          @default_alarms.new_extreme_margin_deg
        ),
      enabled: boolean(fetch(alarms, :enabled, "enabled"), @default_alarms.enabled)
    }
  end

  defp parse_alarms(_), do: @default_alarms

  defp positive_number(v, _default) when is_number(v) and v > 0, do: v / 1
  defp positive_number(_v, default), do: default

  defp boolean(v, _default) when is_boolean(v), do: v
  defp boolean(_v, default), do: default

  defp fetch(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end
end
