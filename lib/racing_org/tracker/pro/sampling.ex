defmodule RacingOrg.Tracker.Pro.Sampling do
  @moduledoc """
  Drives the device's telemetry output: the SEND RATE (flush interval) and the EWMA
  DAMPING time constant, autonomously from race context, with no per-decision server
  involvement.

  Re-evaluates the race phase from the active assignment (`RacingOrg.Tracker.Pro.Commands`), the
  current GPS/network time, and the latest boat position (observed from the telemetry
  stream). It maps that phase onto one of three TRACKING STATES and reads that state's
  `{damping_seconds, send_rate_hz}` from `RacingOrg.Tracker.Pro.Tracking.Config` (the
  server-pushed, persisted config), then sets BOTH the
  `RacingOrg.Tracker.Pro.Telemetry.Reporter` flush interval (`round(1000 / send_rate_hz)`) AND the
  Reporter damping τ.

  ## Phase → tracking state

      :idle / :complete           -> :pre_race   (no active race / before start / finished)
      :pre_start                  -> :starting   (start / countdown window)
      :racing / :rounding / :finish -> :race      (official start until finish)

  The legacy `:outing_1hz | :race_5hz | :event_10hz` MODE and the 6-value PHASE are
  retained (exposed via `current_mode/1` / `current_phase/1`) purely so uploads stay
  tagged the same way; the actual rate/damping now come from `Tracking.Config`.

  Re-evaluation is triggered on the periodic tick, on a `RacingOrg.Tracker.Pro.Commands` change,
  and on a `RacingOrg.Tracker.Pro.Tracking.Config` change. Authoritative config application uses
  `reconfigure/2` so the Config callback never synchronously calls back into its own GenServer.
  """
  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.Sampling.Phase
  alias RacingOrg.Tracker.Pro.Telemetry.Reporter
  alias RacingOrg.Tracker.Pro.Tracking.Config

  @position_event [:racing_org, :gps]

  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "The current sample mode (`:outing_1hz` / `:race_5hz` / `:event_10hz`)."
  def current_mode(server \\ __MODULE__), do: GenServer.call(server, :current_mode)

  @doc "The current race phase."
  def current_phase(server \\ __MODULE__), do: GenServer.call(server, :current_phase)

  @doc "The current tracking state (`:pre_race` / `:starting` / `:race`)."
  def current_state(server \\ __MODULE__), do: GenServer.call(server, :current_state)

  @doc "Force a re-evaluation now; returns `{phase, state}`."
  def reevaluate(server \\ __MODULE__), do: GenServer.call(server, :reevaluate)

  @doc """
  Re-read and apply the rate + damping for the current state.

  This fail-safe compatibility path is intended for callers outside
  `RacingOrg.Tracker.Pro.Tracking.Config`.
  """
  @spec reconfigure(GenServer.server()) :: :ok
  def reconfigure(server \\ __MODULE__), do: GenServer.call(server, :reconfigure)

  @doc """
  Authoritatively apply a normalized tracking config without calling back into
  `RacingOrg.Tracker.Pro.Tracking.Config`.
  """
  @spec reconfigure(GenServer.server(), map()) ::
          :ok | {:error, :invalid_tracking_config | :reporter_unavailable}
  def reconfigure(server, config) when is_map(config) do
    GenServer.call(server, {:reconfigure, config})
  end

  @doc """
  The tracking status the device reports to the server: the applied config version
  plus the state/rate/damping currently being applied.
  """
  def tracking_status(server \\ __MODULE__), do: GenServer.call(server, :tracking_status)

  @doc "Subscribe `pid` to `{:sampling_phase, old_phase, new_phase}` notifications."
  def subscribe(server \\ __MODULE__, pid \\ self()), do: GenServer.call(server, {:subscribe, pid})

  # Telemetry handler (runs in the emitting process): forward the latest position.
  @doc false
  def handle_position(_event, %{position: %{lat: lat, lon: lon}}, _meta, %{pid: pid}) do
    send(pid, {:sampling_position, {lat, lon}})
  end

  def handle_position(_event, _measurements, _meta, _config), do: :ok

  @impl true
  def init(opts) do
    commands = opts[:commands] || Commands
    reporter = opts[:reporter] || Reporter
    tracking_config = opts[:tracking_config] || Config
    interval_ms = opts[:reevaluate_interval_ms] || 1_000

    Commands.subscribe(commands, self())

    :telemetry.attach(
      {__MODULE__, self()},
      @position_event,
      &__MODULE__.handle_position/4,
      %{pid: self()}
    )

    state = %{
      commands: commands,
      reporter: reporter,
      tracking_config: tracking_config,
      now_fn: opts[:now_fn] || (&DateTime.utc_now/0),
      reevaluate_interval_ms: interval_ms,
      phase: :idle,
      mode: :outing_1hz,
      tracking_state: :pre_race,
      # The {damping_seconds, send_rate_hz} last pushed to the Reporter (for status).
      applied: nil,
      position: nil,
      phase_subscribers: MapSet.new()
    }

    # Boot at the pre_race state, then converge to the correct phase.
    state = apply_state(state, :pre_race)
    Process.send_after(self(), :reevaluate_tick, interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:current_mode, _from, state), do: {:reply, state.mode, state}
  def handle_call(:current_phase, _from, state), do: {:reply, state.phase, state}
  def handle_call(:current_state, _from, state), do: {:reply, state.tracking_state, state}

  def handle_call(:reevaluate, _from, state) do
    state = do_reevaluate(state)
    {:reply, {state.phase, state.tracking_state}, state}
  end

  def handle_call(:reconfigure, _from, state) do
    # The config changed: re-apply the CURRENT state's (possibly new) rate + damping.
    {:reply, :ok, apply_state(state, state.tracking_state)}
  end

  def handle_call({:reconfigure, config}, _from, state) do
    case apply_supplied_state(state, state.tracking_state, config) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:tracking_status, _from, state) do
    {:reply, build_status(state), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | phase_subscribers: MapSet.put(state.phase_subscribers, pid)}}
  end

  @impl true
  def handle_info(:reevaluate_tick, state) do
    state = do_reevaluate(state)
    Process.send_after(self(), :reevaluate_tick, state.reevaluate_interval_ms)
    {:noreply, state}
  end

  def handle_info({:racing_org_command, _command}, state), do: {:noreply, do_reevaluate(state)}
  def handle_info({:sampling_position, position}, state), do: {:noreply, %{state | position: position}}

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach({__MODULE__, self()})
    :ok
  end

  defp do_reevaluate(state) do
    assignment = safe_current_assignment(state.commands)
    {phase, mode} = Phase.evaluate(assignment, state.now_fn.(), state.position)
    tracking_state = phase_to_state(phase)

    state =
      if tracking_state != state.tracking_state do
        Logger.info("Sampling state #{state.tracking_state} -> #{tracking_state} (phase #{phase})")
        apply_state(state, tracking_state)
      else
        state
      end

    if phase != state.phase do
      for pid <- state.phase_subscribers, do: send(pid, {:sampling_phase, state.phase, phase})
    end

    %{state | phase: phase, mode: mode}
  end

  # Map the 6 race phases onto the 3 tracking states.
  defp phase_to_state(:pre_start), do: :starting
  defp phase_to_state(phase) when phase in [:racing, :rounding, :finish], do: :race
  defp phase_to_state(_idle_or_complete), do: :pre_race

  # Read the state's {damping_seconds, send_rate_hz} from Tracking.Config and push
  # BOTH the flush interval (= round(1000 / hz)) and the damping τ to the Reporter.
  defp apply_state(state, tracking_state) do
    cfg = safe_get_state(state.tracking_config, tracking_state)
    interval = rate_to_interval_ms(cfg.send_rate_hz)

    set_flush_interval(state, interval)
    set_damping(state, cfg.damping_seconds)

    %{state | tracking_state: tracking_state, applied: cfg}
  end

  defp apply_supplied_state(state, tracking_state, config) do
    with {:ok, cfg} <- supplied_state(config, tracking_state),
         :ok <- set_flush_interval_authoritative(state, rate_to_interval_ms(cfg.send_rate_hz)),
         :ok <- set_damping_authoritative(state, cfg.damping_seconds) do
      {:ok, %{state | tracking_state: tracking_state, applied: cfg}}
    end
  end

  defp supplied_state(%{states: states}, tracking_state) when is_map(states) do
    case Map.get(states, tracking_state) do
      %{damping_seconds: damping, send_rate_hz: rate} = config
      when is_number(damping) and damping >= 0 and is_number(rate) and rate > 0 ->
        {:ok, config}

      _other ->
        {:error, :invalid_tracking_config}
    end
  end

  defp supplied_state(_config, _tracking_state), do: {:error, :invalid_tracking_config}

  defp rate_to_interval_ms(hz) when is_number(hz) and hz > 0, do: max(1, round(1000 / hz))
  defp rate_to_interval_ms(_), do: 1000

  defp build_status(state) do
    applied = state.applied || safe_get_state(state.tracking_config, state.tracking_state)

    %{
      applied_version: safe_applied_version(state.tracking_config),
      active_state: state.tracking_state,
      active_rate_hz: applied.send_rate_hz,
      active_damping_seconds: applied.damping_seconds
    }
  end

  defp set_flush_interval(state, ms) do
    Reporter.set_flush_interval(state.reporter, ms)
  catch
    :exit, _ -> :ok
  end

  defp set_damping(state, tau) do
    Reporter.set_damping(state.reporter, tau)
  catch
    :exit, _ -> :ok
  end

  defp set_flush_interval_authoritative(state, ms) do
    reporter_call(fn -> Reporter.set_flush_interval(state.reporter, ms) end)
  end

  defp set_damping_authoritative(state, tau) do
    reporter_call(fn -> Reporter.set_damping(state.reporter, tau) end)
  end

  defp reporter_call(fun) do
    case fun.() do
      :ok -> :ok
      _other -> {:error, :reporter_unavailable}
    end
  rescue
    _error -> {:error, :reporter_unavailable}
  catch
    _kind, _reason -> {:error, :reporter_unavailable}
  end

  defp safe_get_state(config, tracking_state) do
    Config.get_state(config, tracking_state)
  catch
    :exit, _ -> %{damping_seconds: 0.0, send_rate_hz: 1.0}
  end

  defp safe_applied_version(config) do
    Config.applied_version(config)
  catch
    :exit, _ -> nil
  end

  defp safe_current_assignment(commands) do
    Commands.current_assignment(commands)
  catch
    :exit, _ -> nil
  end
end
