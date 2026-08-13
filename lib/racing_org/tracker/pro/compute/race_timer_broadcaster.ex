defmodule RacingOrg.Tracker.Pro.Compute.RaceTimerBroadcaster do
  alias RacingOrg.Tracker.Pro.DesiredState.OutputFence

  @moduledoc """
  Broadcasts a sailing race-start COUNTDOWN on the NMEA 2000 bus at ~1 Hz so the
  boat's B&G/Zeus display ticks the same countdown the device is running.

  When the device holds an active race assignment (`RacingOrg.Tracker.Pro.Commands`) carrying a
  gun time (`official_start_time`), each tick computes `gun - now`, encodes the B&G
  "Race Timer" message (PGN 130824, Key 117 — see
  `RacingOrg.Tracker.Pro.Compute.PgnEncode.race_timer_from/2`), and transmits it as a fast-packet
  broadcast. The value counts DOWN to the gun, then UP (elapsed) after it.

  It mirrors `RacingOrg.Tracker.Pro.Nav.Broadcaster` / `RacingOrg.Tracker.Pro.Compute.Broadcaster`: a
  GenServer ticking on a timer, deriving its message from the active assignment and an
  injectable clock, transmitting via an injectable function (the NMEA 2000
  VirtualDevice on the device; captured in host tests). All side effects — clock, tick
  interval, the commands source, the sender — are injectable via `start_link/1` opts,
  so it is fully host-testable without a real CAN bus.

  ## Silence rules

  It emits NOTHING when there is no active assignment, the assignment has no gun time,
  the assignment is cancelled, the wall clock is pre-GPS-sync (unreliable), or the
  feature is DISABLED. A stale/garbage countdown never reaches the bus.

  ## Broadcasting

  PGN 130824 is a reverse-engineered B&G proprietary message; the broadcaster is ALWAYS
  ON and broadcasts whenever the device holds a race assignment with a gun time. (Host
  tests can still suppress it by passing `enabled: false`.)

  ## Start sequence

  `in_start_sequence?/2` reports whether `now` is within `[gun - start_sequence_seconds,
  gun]` — the warning-signal-to-gun window. The sequence length sources from the
  assignment's `sampling_rules.start_window_seconds` (the existing start-window
  concept), falling back to `@default_start_sequence_seconds`. This is the clean,
  observable window the rest of the device reads; it does NOT change sampling behavior
  (that stays in `RacingOrg.Tracker.Pro.Sampling.Phase`).
  """
  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.Commands.Assignment
  alias RacingOrg.Tracker.Pro.Compute.PgnEncode

  # PGN 130824, broadcast, priority 2, 1 Hz (canboat transmit interval 1000 ms).
  @pgn 130_824
  @priority 2
  @rate_ms 1_000

  # Default tick faster than 1 Hz so the per-second rate-limit (not the tick) sets the
  # actual cadence; mirrors the compute broadcaster's faster-than-rate tick.
  @default_tick_ms 200

  # Default start-sequence length (5:00) when the assignment carries no
  # start_window_seconds. Most fleets run a 5- or 3-minute sequence.
  @default_start_sequence_seconds 300

  # --- Client API ---

  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc "Run one broadcast tick now (synchronous); returns the number of frames sent (0 or 1)."
  @spec tick_now(GenServer.server()) :: 0 | 1
  def tick_now(server \\ __MODULE__), do: GenServer.call(server, :tick_now)

  @doc """
  Whether `now` falls within the start sequence `[gun - start_sequence_seconds, gun]`
  for the given assignment. `false` for no assignment, no gun time, or a cancelled
  assignment. Pure; the rest of the device can call it directly.
  """
  @spec in_start_sequence?(Assignment.t() | nil, DateTime.t()) :: boolean()
  def in_start_sequence?(assignment, %DateTime{} = now) do
    case gun_datetime(assignment) do
      %DateTime{} = gun ->
        sequence_start = DateTime.add(gun, -start_sequence_seconds(assignment), :second)
        DateTime.compare(now, sequence_start) != :lt and DateTime.compare(now, gun) != :gt

      nil ->
        false
    end
  end

  # --- Server ---

  @impl true
  def init(opts) do
    tick_ms = opts[:tick_ms] || @default_tick_ms
    if tick_ms > 0, do: Process.send_after(self(), :tick, tick_ms)

    state = %{
      commands: opts[:commands] || Commands,
      enabled: Keyword.get(opts, :enabled, true),
      transmit: opts[:transmit_fn] || (&default_transmit/3),
      output_fence: opts[:output_fence] || OutputFence.default(),
      now_fn: opts[:now_fn] || (&DateTime.utc_now/0),
      tick_ms: tick_ms,
      # Wall-clock unix-ms of the last transmitted frame (1 Hz rate-limit), or nil.
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

  def handle_info(_msg, state), do: {:noreply, state}

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
    now = state.now_fn.()
    assignment = safe_assignment(state.commands)

    with true <- reliable_time?(now),
         %DateTime{} = gun <- gun_datetime(assignment),
         now_ms = DateTime.to_unix(now, :millisecond),
         true <- due?(state.last_sent_ms, now_ms) do
      payload = PgnEncode.race_timer_from(DateTime.to_unix(gun, :millisecond), now_ms)
      safe_transmit(state.transmit, @priority, @pgn, payload)
      {1, %{state | last_sent_ms: now_ms}}
    else
      _ -> {0, state}
    end
  end

  # ~1 Hz rate-limit on the wall clock. Subtract a tiny epsilon so a tick landing
  # exactly on the boundary isn't perpetually one tick late.
  defp due?(nil, _now_ms), do: true
  defp due?(last_ms, now_ms), do: now_ms - last_ms >= @rate_ms - 1

  # --- assignment / clock helpers ---

  # The gun time as a DateTime, or nil when there is no usable race to count down to:
  # no assignment, a cancelled assignment, or a missing official_start_time.
  defp gun_datetime(nil), do: nil
  defp gun_datetime(%Assignment{cancelled: true}), do: nil
  defp gun_datetime(%Assignment{race_assignment: nil}), do: nil

  defp gun_datetime(%Assignment{race_assignment: race}),
    do: proto_dt(race.official_start_time)

  defp proto_dt(nil), do: nil
  defp proto_dt(%{seconds: seconds}), do: DateTime.from_unix!(seconds)

  # Start-sequence length: the assignment's start_window_seconds, else the default.
  defp start_sequence_seconds(%Assignment{race_assignment: race}) when not is_nil(race) do
    case race.sampling_rules do
      %{start_window_seconds: s} when is_integer(s) and s > 0 -> s
      _ -> @default_start_sequence_seconds
    end
  end

  defp start_sequence_seconds(_), do: @default_start_sequence_seconds

  # Refuse to count down off a pre-GPS-sync clock (mirrors Sampling.Phase).
  defp reliable_time?(%DateTime{} = now), do: now.year >= 2020
  defp reliable_time?(_), do: false

  defp safe_assignment(commands) do
    case commands do
      {module, server} -> module.current_assignment(server)
      module when is_atom(module) -> module.current_assignment()
    end
  catch
    :exit, _ -> nil
  end

  # --- transmit (mirrors the other broadcasters) ---

  defp safe_transmit(fun, priority, pgn, payload) do
    fun.(priority, pgn, payload)
  rescue
    error -> Logger.warning("Race timer PGN #{pgn} transmit failed: #{inspect(error)}")
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
end
