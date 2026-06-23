defmodule RacingOrg.Tracker.Pro.Nav.DeviationMonitor do
  @moduledoc """
  The tracker side of the deviation→recalc loop (on-water P3).

  Every 10 SECONDS, while the boat is RACING, it compares the boat's cross-track
  error against the server-pushed deviation threshold and — exactly ONCE per
  excursion — asks the backend (via `RacingOrg.Tracker.Pro.SecureTransport.ChannelClient`)
  to recompute the route from the boat's current position over the remaining course.

  ## What it reuses (does NOT re-derive geometry)

  The cross-track error is the SAME `cross_track_m` `RacingOrg.Tracker.Pro.Nav.State` already
  derives for the active leg (and `RacingOrg.Tracker.Pro.Nav.Broadcaster` broadcasts as PGN
  129283 XTE). On each check the monitor derives `Nav.State` from the current
  assignment (`RacingOrg.Tracker.Pro.Commands`) and the latest GPS fix and reads its
  `cross_track_m` — it never recomputes the leg geometry itself.

  ## When it checks (the racing gate)

  A check only proceeds when ALL of the following hold:

    * the current race phase (from `RacingOrg.Tracker.Pro.Sampling`) is `:racing` or
      `:rounding` — i.e. an active leg exists. NEVER `:idle` / `:pre_start` /
      `:finish` / `:complete`, so a boat maneuvering before the gun (or after the
      finish) never triggers a recalc;
    * the derived `Nav.State` is active AND has a real `cross_track_m` (the first
      mark has no origin, so its XTE is `nil` — not yet a leg to deviate from);
    * the latest GPS fix is FRESH (within `:position_freshness_ms`) — we never
      request a recalc off a stale position.

  ## The threshold (server-pushed, survives reconnects)

  The threshold comes from `RacingOrg.Tracker.Pro.Tracking.Config.deviation_threshold/1`,
  which the server pushes in the SAME `set_tracking` JSON config (default 50.0 m if
  absent) and persists to `/data` (so it survives reboots/reconnects). It is read
  fresh on EVERY check, so a mid-race threshold update takes effect immediately.

  ## Cooldown (no constant recalc — the owner's explicit requirement)

  When `abs(cross_track_m) > threshold` the monitor pushes ONE `request_route_recalc`
  and then SUPPRESSES further requests until EITHER:

    * a NEW route/assignment arrives (a `RacingOrg.Tracker.Pro.Commands` notification — the
      recalc landed, so re-arm), OR
    * a fallback `:cooldown_ms` elapses (so a recalc that never arrives is eventually
      re-requested — no deadlock).

  Below-threshold deviation never requests and never arms the cooldown. This is the
  "I don't want the route recalculating constantly if I slightly deviate" guarantee.

  ## Robustness

  The recalc push is best-effort and fully isolated: it goes through
  `ChannelClient.request_route_recalc/2`, which is itself session-gated + drop-if-no-
  session, and any raise/exit from the push is caught here so the monitor never
  crashes. All collaborators are injectable via `start_link/1` opts so the whole loop
  is host-testable with a manual clock + manual `check_now/1`.
  """
  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.Nav.State

  @position_event [:racing_org, :gps]

  # 10-second deviation cadence (NOT 1 Hz).
  @default_check_interval_ms 10_000
  # A GPS fix older than this is too stale to recalc from.
  @default_position_freshness_ms 30_000
  # Fallback re-arm if a requested recalc never produces a new route.
  @default_cooldown_ms 120_000
  # Safe fallback threshold if the Tracking.Config manager is momentarily unavailable
  # (it owns the authoritative, server-pushed value).
  @default_deviation_threshold_m 50.0

  # Phases that mean "an active leg exists" (so a deviation is meaningful).
  @racing_phases [:racing, :rounding]

  @type position :: {number(), number()}

  # --- Client API ---

  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc """
  Run one deviation check now (synchronous); returns the outcome atom:

    * `:requested`     — deviated past the threshold + armed → a recalc was pushed
    * `:suppressed`    — deviated, but a request is already outstanding (cooldown)
    * `:within`        — racing on a real leg, but within the threshold
    * `:not_racing`    — the phase is not `:racing`/`:rounding`
    * `:no_active_leg` — no assignment / no active mark / first-mark (nil XTE)
    * `:stale_position`— no fresh GPS fix to recalc from
  """
  @spec check_now(GenServer.server()) ::
          :requested | :suppressed | :within | :not_racing | :no_active_leg | :stale_position
  def check_now(server \\ __MODULE__), do: GenServer.call(server, :check_now)

  @doc "Whether the monitor is currently armed (not suppressed). For tests/diagnostics."
  @spec armed?(GenServer.server()) :: boolean()
  def armed?(server \\ __MODULE__), do: GenServer.call(server, :armed?)

  # --- Server ---

  @impl true
  def init(opts) do
    commands = normalize_commands(opts[:commands] || Commands)
    # Re-arm on any new route/assignment command (the recalc landed).
    safe_subscribe(commands)

    # On the device, position comes from the GPS telemetry stream; attach unless an
    # explicit position source is injected (host tests inject :nav_position directly).
    if is_nil(opts[:position_fn]), do: attach_position()

    interval = opts[:check_interval_ms] || @default_check_interval_ms
    if interval > 0, do: Process.send_after(self(), :check_tick, interval)

    state = %{
      commands: commands,
      tracking_config: normalize(Keyword.get(opts, :tracking_config, RacingOrg.Tracker.Pro.Tracking.Config)),
      phase_source: normalize(Keyword.get(opts, :phase_source, RacingOrg.Tracker.Pro.Sampling)),
      channel: Keyword.get(opts, :channel, RacingOrg.Tracker.Pro.SecureTransport.ChannelClient),
      now_ms_fn: opts[:now_ms_fn] || (&monotonic_ms/0),
      check_interval_ms: interval,
      position_freshness_ms: opts[:position_freshness_ms] || @default_position_freshness_ms,
      cooldown_ms: opts[:cooldown_ms] || @default_cooldown_ms,
      # Latest GPS fix + the monotonic-ms it was observed (for freshness).
      position: nil,
      position_mono_ms: nil,
      # nil = armed; a monotonic-ms = suppressed until that cooldown deadline.
      suppressed_until_ms: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    {outcome, state} = do_check(state)
    {:reply, outcome, state}
  end

  def handle_call(:armed?, _from, state), do: {:reply, is_nil(state.suppressed_until_ms), state}

  @impl true
  def handle_info(:check_tick, state) do
    {_outcome, state} = do_check(state)
    if state.check_interval_ms > 0, do: Process.send_after(self(), :check_tick, state.check_interval_ms)
    {:noreply, state}
  end

  def handle_info({:nav_position, {lat, lon}}, state) when is_number(lat) and is_number(lon) do
    {:noreply, %{state | position: {lat, lon}, position_mono_ms: state.now_ms_fn.()}}
  end

  # A new route/assignment landed -> re-arm (clear suppression). This is the
  # primary cooldown-release: the recalc the deviation asked for has arrived.
  def handle_info({:racing_org_command, _command}, state) do
    {:noreply, %{state | suppressed_until_ms: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach({__MODULE__, self()})
    :ok
  end

  # --- the check ---

  defp do_check(state) do
    now_ms = state.now_ms_fn.()
    # Release a lapsed cooldown first so a never-arriving route eventually re-requests.
    state = release_cooldown(state, now_ms)

    # Gate order: racing phase → a fresh GPS fix (a stale/absent fix is meaningless to
    # recalc from, and the leg geometry below depends on it) → a real active leg →
    # the threshold.
    cond do
      not racing?(state) ->
        {:not_racing, state}

      not fresh_position?(state, now_ms) ->
        {:stale_position, state}

      true ->
        case active_cross_track(state) do
          nil -> {:no_active_leg, state}
          xte -> check_threshold(state, xte, now_ms)
        end
    end
  end

  # A real active leg + a fresh fix: request iff over the threshold and armed.
  defp check_threshold(state, xte, now_ms) do
    cond do
      abs(xte) <= threshold(state) -> {:within, state}
      suppressed?(state) -> {:suppressed, state}
      true -> request_recalc(state, xte, now_ms)
    end
  end

  defp request_recalc(state, xte, now_ms) do
    Logger.info("[DeviationMonitor] cross-track #{Float.round(xte / 1, 1)}m exceeded threshold; requesting recalc")
    safe_push(state.channel, state.position)
    {:requested, %{state | suppressed_until_ms: now_ms + state.cooldown_ms}}
  end

  # --- gates ---

  defp racing?(state) do
    phase = safe_current_phase(state.phase_source)
    phase in @racing_phases
  end

  # The active leg's cross-track (m) from the live Nav.State, or nil when there is no
  # real active leg (no assignment / unknown active mark / first mark with no origin).
  defp active_cross_track(state) do
    assignment = safe_assignment(state.commands)

    case State.derive(assignment, state.position) do
      %State{active?: true, cross_track_m: xte} when is_number(xte) -> xte
      _ -> nil
    end
  end

  defp fresh_position?(%{position: nil}, _now_ms), do: false
  defp fresh_position?(%{position_mono_ms: nil}, _now_ms), do: false

  defp fresh_position?(state, now_ms) do
    now_ms - state.position_mono_ms <= state.position_freshness_ms
  end

  # Read the threshold fresh on every check (so a mid-race update takes effect). Falls
  # back to a safe default if the config manager is momentarily unavailable.
  defp threshold(state) do
    {module, server} = state.tracking_config
    module.deviation_threshold(server)
  catch
    :exit, _ -> @default_deviation_threshold_m
  end

  # --- cooldown ---

  defp suppressed?(%{suppressed_until_ms: nil}), do: false
  defp suppressed?(%{suppressed_until_ms: _}), do: true

  defp release_cooldown(%{suppressed_until_ms: nil} = state, _now_ms), do: state

  defp release_cooldown(%{suppressed_until_ms: deadline} = state, now_ms) do
    if now_ms >= deadline, do: %{state | suppressed_until_ms: nil}, else: state
  end

  # --- collaborators ---

  defp safe_push(channel, position) do
    case channel do
      fun when is_function(fun, 1) -> fun.(position)
      {module, server} -> module.request_route_recalc(server, position)
      module when is_atom(module) -> module.request_route_recalc(position)
    end
  rescue
    error -> Logger.warning("[DeviationMonitor] recalc push failed: #{inspect(error)}")
  catch
    :exit, _ -> :ok
  end

  defp safe_assignment({module, server}) do
    module.current_assignment(server)
  catch
    :exit, _ -> nil
  end

  defp safe_current_phase(phase_source) do
    {module, server} = phase_source
    module.current_phase(server)
  catch
    :exit, _ -> :idle
  end

  defp safe_subscribe({module, server}) do
    module.subscribe(server, self())
  catch
    :exit, _ -> :ok
  end

  # The :commands opt is a bare module, a {module, server} pair, OR (in tests) a bare
  # pid/name — which is the server of the standard `Commands` module.
  defp normalize_commands({module, server}) when is_atom(module), do: {module, server}
  defp normalize_commands(module) when is_atom(module), do: {module, module}
  defp normalize_commands(server) when is_pid(server), do: {Commands, server}

  defp attach_position do
    :telemetry.attach({__MODULE__, self()}, @position_event, &__MODULE__.handle_position/4, %{pid: self()})
  end

  @doc false
  def handle_position(_event, %{position: %{lat: lat, lon: lon}}, _meta, %{pid: pid})
      when is_number(lat) and is_number(lon),
      do: send(pid, {:nav_position, {lat, lon}})

  def handle_position(_event, _measurements, _meta, _config), do: :ok

  defp normalize({module, server}) when is_atom(module), do: {module, server}
  defp normalize(module) when is_atom(module), do: {module, module}

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
