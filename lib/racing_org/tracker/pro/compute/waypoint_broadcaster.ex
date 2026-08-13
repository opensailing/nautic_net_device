defmodule RacingOrg.Tracker.Pro.Compute.WaypointBroadcaster do
  alias RacingOrg.Tracker.Pro.DesiredState.OutputFence

  @moduledoc """
  Broadcasts the NEXT WAYPOINT to steer to on the NMEA 2000 bus at ~1 Hz so the boat's
  B&G/Zeus plotter shows bearing + distance to the next mark (and, where the plotter
  accepts it, the active waypoint).

  When the device holds an active race assignment (`RacingOrg.Tracker.Pro.Commands`) whose course
  carries the next mark's position AND the device has a recent own-position fix, each
  tick computes the great-circle distance and bearing (own-position → destination) and
  transmits:

    * PGN 129284 "Navigation Data" (priority 3) — the data-box numbers: distance, the
      live steer-to bearing, the destination lat/lon, and the destination waypoint
      number. This is the PRIMARY message.
    * PGN 129285 "Navigation - Route/WP Information" (priority 6) — a one-waypoint route
      whose WP ID equals 129284's Destination Waypoint Number and whose name is the
      mark code, so the plotter can LABEL the waypoint.

  See `RacingOrg.Tracker.Pro.Compute.PgnEncode.navigation_data_129284/1` and `route_wp_129285/1`
  for the wire layouts.

  It mirrors `RacingOrg.Tracker.Pro.Compute.RaceTimerBroadcaster`: a GenServer ticking on a timer,
  deriving its destination from the active assignment, computing geometry against an
  injectable position source, rate-limiting on an injectable monotonic clock, and
  transmitting via an injectable function (the NMEA 2000 VirtualDevice on the device;
  captured in host tests). All side effects are injectable via `start_link/1` opts, so
  it is fully host-testable without a real CAN bus or GPS.

  ## Destination from the assignment

  The destination is the `course_marks` entry whose `code` equals the assignment's
  `active_mark_code` ("next mark to round"). Its `position` (a `LatLon` in degrees) is
  the destination lat/lon. This is the SAME derivation `RacingOrg.Tracker.Pro.Nav.State` uses. The
  destination position therefore does NOT depend on a route analysis having been run —
  it is present as soon as the assignment carries marks with positions. The optimized
  `route_geometry`, when present, is an overlay for the chart track; the steer-to
  destination is always the active MARK.

  The `Destination Waypoint Number` / `WP ID` is the mark's 1-based index in the
  sequence-sorted course. For a given mark this is STABLE across ticks, so the plotter
  does not churn the label.

  ## Silence rules

  Emits NOTHING when there is no active assignment, the assignment is cancelled, there
  is no `active_mark_code`, the active mark has no position on the device, there is no
  own-position fix, or the feature is DISABLED.

  ## Broadcasting

  The broadcaster is ALWAYS ON and broadcasts whenever the device holds a race
  assignment whose active mark has a position and a recent GPS fix is available.
  129284/129285 are STANDARD navigation PGNs; whether a given Navico/Zeus plotter
  ADOPTS an externally-sourced active waypoint onto the chart (vs only rendering the
  data-box numbers) is plotter-dependent. (Host tests can suppress it via
  `enabled: false`.)

  ## NMEA-0183 fallback

  The documented fallback for plotters that won't adopt an externally-sourced active
  waypoint is NMEA-0183 RMB/APB/BWC into the plotter's 0183 input. This device has NO
  0183 OUTPUT path (its only serial port is the SixFab LTE-modem GPS *input*), so that
  fallback is not buildable here; the N2K 129284 data-box is the reliable target.
  """
  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.Commands.Assignment
  alias RacingOrg.Tracker.Pro.Compute.PgnEncode
  alias RacingOrg.Tracker.Pro.Nav.Geo

  @pgn_nav_data 129_284
  @pgn_route 129_285
  @priority_nav_data 3
  @priority_route 6
  @rate_ms 1_000

  # Tick faster than 1 Hz so the per-second rate-limit (not the tick) sets the actual
  # cadence; mirrors the race-timer broadcaster.
  @default_tick_ms 200

  @position_event [:racing_org, :gps]

  # --- Client API ---

  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc "Run one broadcast tick now (synchronous); returns the number of frames sent (0, or 2 = 129284 + 129285)."
  @spec tick_now(GenServer.server()) :: non_neg_integer()
  def tick_now(server \\ __MODULE__), do: GenServer.call(server, :tick_now)

  # --- Server ---

  @impl true
  def init(opts) do
    tick_ms = opts[:tick_ms] || @default_tick_ms
    if tick_ms > 0, do: Process.send_after(self(), :tick, tick_ms)

    # On the device, position comes from the GPS telemetry stream; attach unless an
    # explicit position source was injected (host tests inject `position_fn`).
    position_fn = opts[:position_fn]
    if is_nil(position_fn), do: attach_position()

    state = %{
      commands: opts[:commands] || Commands,
      enabled: Keyword.get(opts, :enabled, true),
      transmit: opts[:transmit_fn] || (&default_transmit/3),
      output_fence: opts[:output_fence] || OutputFence.default(),
      # Source of own-position as `{lat, lon}` or nil. Defaults to the last telemetry fix.
      position_fn: position_fn,
      # Monotonic-ms clock for the 1 Hz rate-limit (injectable for deterministic tests).
      now_ms_fn: opts[:now_ms_fn] || opts[:clock] || (&monotonic_ms/0),
      tick_ms: tick_ms,
      # Last own-position fix seen on the telemetry stream (when not injected).
      position: nil,
      # Monotonic-ms of the last transmitted 129284 frame (1 Hz rate-limit), or nil.
      last_sent_ms: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:tick_now, _from, state) do
    {count, state} = do_tick(state)
    {:reply, count, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_count, state} = do_tick(state)
    if state.tick_ms > 0, do: Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  end

  def handle_info({:nav_position, position}, state), do: {:noreply, %{state | position: position}}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach({__MODULE__, self()})
    :ok
  end

  @doc false
  def handle_position(_event, %{position: %{lat: lat, lon: lon}}, _meta, %{pid: pid})
      when is_number(lat) and is_number(lon),
      do: send(pid, {:nav_position, {lat, lon}})

  def handle_position(_event, _measurements, _meta, _config), do: :ok

  # --- tick ---

  defp do_tick(%{enabled: false} = state), do: {0, state}

  # External output stays fenced while a desired-state generation reloads.
  defp do_tick(state) do
    if OutputFence.permitted?(state.output_fence) do
      do_permitted_tick(state)
    else
      {0, state}
    end
  end

  defp do_permitted_tick(state) do
    assignment = safe_assignment(state.commands)
    position = current_position(state)

    with {:ok, dest} <- destination(assignment),
         {:ok, pos} <- own_position(position),
         now_ms = state.now_ms_fn.(),
         true <- due?(state.last_sent_ms, now_ms) do
      count = transmit_waypoint(state, pos, dest)
      {count, %{state | last_sent_ms: now_ms}}
    else
      _ -> {0, state}
    end
  end

  # Transmit 129284 (the data-box) + 129285 (the label). Returns the frame count.
  defp transmit_waypoint(state, pos, dest) do
    bearing = Geo.bearing_rad(pos, dest.position)
    distance = Geo.distance_m(pos, dest.position)

    nav_payload =
      PgnEncode.navigation_data_129284(%{
        sid: 0,
        distance_to_dest_m: distance,
        reference: true,
        perpendicular_crossed?: false,
        arrival_circle_entered?: false,
        calculation_type: :great_circle,
        bearing_origin_to_dest_rad: nil,
        bearing_position_to_dest_rad: bearing,
        origin_wp_number: nil,
        destination_wp_number: dest.wp_number,
        destination: dest.position,
        closing_velocity_m_s: nil
      })

    route_payload =
      PgnEncode.route_wp_129285(%{
        wp_id: dest.wp_number,
        name: dest.code,
        lat: elem(dest.position, 0),
        lon: elem(dest.position, 1)
      })

    safe_transmit(state.transmit, @priority_nav_data, @pgn_nav_data, nav_payload)
    safe_transmit(state.transmit, @priority_route, @pgn_route, route_payload)
    2
  end

  # ~1 Hz rate-limit on the monotonic clock (epsilon so a boundary tick isn't late).
  defp due?(nil, _now_ms), do: true
  defp due?(last_ms, now_ms), do: now_ms - last_ms >= @rate_ms - 1

  # --- destination derivation (mirrors RacingOrg.Tracker.Pro.Nav.State) -------------------------

  # The next-mark destination as `{:ok, %{code, position: {lat, lon}, wp_number}}` or
  # `:error` when there is no usable destination on the device.
  defp destination(nil), do: :error
  defp destination(%Assignment{cancelled: true}), do: :error
  defp destination(%Assignment{race_assignment: nil}), do: :error

  defp destination(%Assignment{race_assignment: race, active_mark_code: code})
       when is_binary(code) and code != "" do
    marks = sort_marks(race.course_marks || [])

    with idx when is_integer(idx) <- Enum.find_index(marks, &(&1.code == code)),
         mark = Enum.at(marks, idx),
         {lat, lon} <- latlon(mark.position) do
      {:ok, %{code: mark.code, position: {lat, lon}, wp_number: idx + 1}}
    else
      _ -> :error
    end
  end

  defp destination(_), do: :error

  defp sort_marks(marks), do: Enum.sort_by(marks, &(&1.sequence || 0))

  defp latlon(%{latitude: lat, longitude: lon}) when is_number(lat) and is_number(lon), do: {lat, lon}
  defp latlon(_), do: nil

  # --- own position -----------------------------------------------------------------

  defp own_position({lat, lon}) when is_number(lat) and is_number(lon), do: {:ok, {lat, lon}}
  defp own_position(_), do: :error

  defp current_position(%{position_fn: fun}) when is_function(fun, 0), do: fun.()
  defp current_position(%{position: position}), do: position

  defp attach_position do
    :telemetry.attach({__MODULE__, self()}, @position_event, &__MODULE__.handle_position/4, %{pid: self()})
  end

  # --- assignment / transmit (mirrors the other broadcasters) -----------------------

  defp safe_assignment(commands) do
    case commands do
      {module, server} -> module.current_assignment(server)
      module when is_atom(module) -> module.current_assignment()
    end
  catch
    :exit, _ -> nil
  end

  defp safe_transmit(fun, priority, pgn, payload) do
    fun.(priority, pgn, payload)
  rescue
    error -> Logger.warning("Waypoint PGN #{pgn} transmit failed: #{inspect(error)}")
  catch
    :exit, _ -> :ok
  end

  # On the device, transmit through the NMEA 2000 VirtualDevice as a broadcast
  # (destination address 0xFF), which fast-packet-frames the >8-byte payload. No-op if
  # the VirtualDevice isn't available.
  defp default_transmit(priority, pgn, payload) do
    case RacingOrg.Tracker.Pro.virtual_device() do
      nil -> :ok
      vd -> NMEA.NMEA2000.VirtualDevice.send_data(vd, priority, pgn, payload, 0xFF)
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
