defmodule RacingOrg.Tracker.Pro.Nav.Broadcaster do
  alias RacingOrg.Tracker.Pro.DesiredState.OutputFence

  @moduledoc """
  Periodically broadcasts NMEA 2000 navigation *display* PGNs (active waypoint,
  bearing/range, active leg, cross-track error, and the route list) onto the bus
  so B&G displays can show route/navigation state during a race.

  It derives the nav state from the active assignment (`RacingOrg.Tracker.Pro.Commands`) and
  the latest boat position (from the telemetry stream), and transmits via an
  injectable function (the NMEA 2000 VirtualDevice on the device; captured in
  tests). It only emits information PGNs — never autopilot heading/track-control
  PGNs — and emits nothing when there is no active waypoint.
  """
  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.Nav.PGN
  alias RacingOrg.Tracker.Pro.Nav.State

  @position_event [:racing_org, :gps]

  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "Derive and broadcast now; returns `{nav_state, message_count}`."
  def broadcast_now(server \\ __MODULE__), do: GenServer.call(server, :broadcast)

  @doc false
  def handle_position(_event, %{position: %{lat: lat, lon: lon}}, _meta, %{pid: pid}),
    do: send(pid, {:nav_position, {lat, lon}})

  def handle_position(_event, _measurements, _meta, _config), do: :ok

  @impl true
  def init(opts) do
    :telemetry.attach({__MODULE__, self()}, @position_event, &__MODULE__.handle_position/4, %{pid: self()})

    interval = opts[:interval_ms] || 1_000
    Process.send_after(self(), :tick, interval)

    state = %{
      commands: opts[:commands] || Commands,
      transmit: opts[:transmit_fn] || (&default_transmit/3),
      output_fence: opts[:output_fence] || OutputFence.default(),
      # The compute engine to feed `bearing_to_mark` into (so the `vmc` library calc can
      # compute). `{module, server}` or a bare module (used as both). Defaults to the
      # named Compute.Engine; pass `nil` to disable the push (host tests not exercising
      # it). See `feed_bearing_to_mark/2`.
      compute: normalize_compute(Keyword.get(opts, :compute, RacingOrg.Tracker.Pro.Compute.Engine)),
      interval: interval,
      route_name: opts[:route_name] || "Course",
      position: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    do_broadcast(state)
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  def handle_info({:nav_position, position}, state), do: {:noreply, %{state | position: position}}

  @impl true
  def handle_call(:broadcast, _from, state), do: {:reply, do_broadcast(state), state}

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach({__MODULE__, self()})
    :ok
  end

  defp do_broadcast(state) do
    assignment = safe_assignment(state.commands)
    nav = State.derive(assignment, state.position)

    # External NMEA output stays fenced while a desired-state generation reloads
    # (OutputFence keeps the legacy carve-out); the compute-engine feeds below are
    # internal signal plumbing and keep running so calcs stay warm.
    messages =
      if OutputFence.permitted?(state.output_fence),
        do: PGN.nav_messages(nav, waypoints(assignment), state.route_name),
        else: []

    for {priority, pgn, payload} <- messages, do: safe_transmit(state.transmit, priority, pgn, payload)

    # Feed the bearing-to-active-mark (degrees) into the compute engine so `vmc` can
    # compute. The same nav geometry that drives the display PGNs sources it: when
    # there is an active mark + a current position, `bearing_position_to_dest_rad` is
    # the bearing from the boat to the mark. With no active mark it is simply not
    # pushed (and vmc stays invalid — correct).
    feed_bearing_to_mark(state.compute, nav)

    # Feed the bearing of the NEXT leg (active mark -> the following mark in sequence,
    # `bearing_dest_to_next_rad`) into the compute engine so the next-leg apparent-wind
    # calcs (`next_leg_twa`/`next_leg_aws`/`next_leg_awa`) can compute. Same source
    # geometry / same injection path as `bearing_to_mark`; mark-to-mark so no position
    # is needed. Absent when there is no next mark (active mark is the finish) -> the
    # signal is simply not pushed and the dependent calcs stay invalid.
    feed_next_leg_bearing(state.compute, nav)

    {nav, length(messages)}
  end

  defp feed_bearing_to_mark(nil, _nav), do: :ok

  defp feed_bearing_to_mark({module, server}, %{active?: true, bearing_position_to_dest_rad: rad})
       when is_number(rad) do
    push_signal({module, server}, "bearing_to_mark", rad)
  end

  defp feed_bearing_to_mark(_compute, _nav), do: :ok

  defp feed_next_leg_bearing(nil, _nav), do: :ok

  defp feed_next_leg_bearing({module, server}, %{active?: true, bearing_dest_to_next_rad: rad})
       when is_number(rad) do
    push_signal({module, server}, "next_leg_bearing", rad)
  end

  defp feed_next_leg_bearing(_compute, _nav), do: :ok

  # Push a radian bearing into the compute engine as a DEGREE signal (the catalog unit).
  defp push_signal({module, server}, name, rad) do
    deg = rad * 180.0 / :math.pi()

    try do
      module.put_signal(server, name, deg, System.monotonic_time(:millisecond))
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp waypoints(nil), do: []
  defp waypoints(%{race_assignment: nil}), do: []

  defp waypoints(%{race_assignment: race}) do
    for mark <- race.course_marks || [], pos = mark.position, is_map(pos) do
      %{code: mark.code, lat: pos.latitude, lon: pos.longitude}
    end
  end

  defp safe_transmit(fun, priority, pgn, payload) do
    fun.(priority, pgn, payload)
  rescue
    error -> Logger.warning("Nav PGN #{pgn} transmit failed: #{inspect(error)}")
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

  defp safe_assignment(commands) do
    Commands.current_assignment(commands)
  catch
    :exit, _ -> nil
  end

  defp normalize_compute(nil), do: nil
  defp normalize_compute({module, server}) when is_atom(module), do: {module, server}
  defp normalize_compute(module) when is_atom(module), do: {module, module}
end
