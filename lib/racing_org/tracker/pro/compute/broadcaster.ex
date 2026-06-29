defmodule RacingOrg.Tracker.Pro.Compute.Broadcaster do
  @moduledoc """
  Periodically takes the engine's COMPUTED VALUES, damps them, encodes each to its
  target NMEA 2000 PGN, and BROADCASTS it on the bus at (approximately) the value's own
  `broadcast_rate_hz` (Phase 8). It mirrors `RacingOrg.Tracker.Pro.Nav.Broadcaster`: a GenServer
  that on a periodic tick builds PGN payloads and transmits via an injectable function
  (the NMEA 2000 VirtualDevice on the device; captured in host tests).

  ## What it sends

  On each tick it reads `RacingOrg.Tracker.Pro.Compute.Engine.current_values/1` and, for every def
  that is

    * `valid?` (a missing/stale input or domain error makes it invalid — we NEVER emit
      a stale/garbage value to the bus), AND
    * `broadcast_enabled`, AND
    * **due** per its own `broadcast_rate_hz` (a per-def last-sent timestamp rate-limits
      each value to ~its Hz, independent of the faster tick),

  it DAMPS the output(s) then ENCODEs (`RacingOrg.Tracker.Pro.Compute.PgnEncode`) and SENDs. The
  tick runs faster than any value's rate (default 10 Hz / 100 ms) so a slow value
  (e.g. 2 Hz) is emitted at its rate, not at the tick rate.

  ## Output damping

  Per def, an EWMA (`RacingOrg.Tracker.Pro.Telemetry.Ewma`, the Phase 5 time-constant filter) is
  kept **per output value** with time constant `τ = damping_seconds` (`τ = 0` ⇒
  pass-through). Δt comes from the monotonic clock between successive emissions of that
  output, so smoothing is cadence-independent. Each output is classified as

    * `:circular` — angles/bearings that wrap 0⇄360: `true_wind_angle`,
      `true_wind_direction`, `wind_angle`, `heading`, `cog`, `yaw`, `target_twa`,
      `next_leg_awa` (smoothed via the unit-vector sin/cos components so the mean goes
      "the short way" across the wrap);
    * `:linear` — everything else: speeds (`true_wind_speed`, `sog`, `boat_speed`,
      `value`, `target_boat_speed`, `next_leg_aws`), `depth`, temperature, `vmg`,
      `vmg_performance`, `vmc`, `pitch`, `roll`.

  The Ewma works in RADIANS for circular quantities; outputs are catalog DEGREES, so a
  circular output is converted deg→rad before the filter and rad→deg after.

  ## Status

  `broadcasting?/1` reports whether the most recent tick actually transmitted at least
  one value — the device surfaces this as the `broadcasting` field of
  `computed_values_status`.

  All side effects (clock, tick interval, the sender, the engine) are injectable via
  `start_link/1` opts, so the broadcaster is fully host-testable without a real CAN bus.
  """

  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.Compute.Engine
  alias RacingOrg.Tracker.Pro.Compute.PgnEncode
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient
  alias RacingOrg.Tracker.Pro.Telemetry.Ewma

  # 10 Hz tick: faster than any value's broadcast_rate_hz so per-def rate-limiting,
  # not the tick, sets each value's actual cadence.
  @default_tick_ms 100

  # ~2 Hz backend stream cadence (per value). The streamback is for live DISPLAY, so
  # it is capped LOW and independent of the (up to 50 Hz) bus broadcast rate, and all
  # due values are batched into ONE message per flush to keep channel traffic minimal.
  @default_stream_interval_ms 500

  # Outputs whose values are compass/relative bearings and must be damped circularly
  # (averaged the short way across the 0⇄360 wrap), never linearly. `target_twa` and
  # `next_leg_awa` are the Phase-2 polar ANGLE outputs (relative wind angles, like
  # `true_wind_angle`); the speeds/percent targets stay linear.
  @circular_outputs MapSet.new([
                      "true_wind_angle",
                      "true_wind_direction",
                      "wind_angle",
                      "wind_direction",
                      "heading",
                      "cog",
                      "yaw",
                      "target_twa",
                      "next_leg_awa"
                    ])

  @deg_per_rad 180.0 / :math.pi()
  @rad_per_deg :math.pi() / 180.0

  # --- Client API ---

  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc "Run one broadcast tick now (synchronous); returns the number of values sent."
  @spec tick_now(GenServer.server()) :: non_neg_integer()
  def tick_now(server \\ __MODULE__), do: GenServer.call(server, :tick_now)

  @doc "Whether the most recent tick actually transmitted at least one computed value."
  @spec broadcasting?(GenServer.server()) :: boolean()
  def broadcasting?(server \\ __MODULE__), do: GenServer.call(server, :broadcasting?)

  # --- Server ---

  @impl true
  def init(opts) do
    tick_ms = opts[:tick_ms] || @default_tick_ms
    if tick_ms > 0, do: Process.send_after(self(), :tick, tick_ms)

    state = %{
      engine: normalize_engine(opts[:engine]),
      transmit: opts[:transmit_fn] || (&default_transmit/3),
      # The backend streamback collaborator: a 1-arity fn taking the batch of
      # `%{id, value}` maps. Defaults to the channel client (best-effort, no-op when no
      # session); injectable so host tests capture the streamed payload without a socket.
      stream: opts[:stream_fn] || (&ChannelClient.send_computed_values_data/1),
      now_fn: opts[:now_fn] || fn -> System.monotonic_time(:millisecond) end,
      tick_ms: tick_ms,
      # The backend stream is for live DISPLAY only, so it is rate-limited LOW and
      # independent of broadcast_rate_hz (which can be up to 50 Hz for the bus).
      stream_interval_ms: opts[:stream_interval_ms] || @default_stream_interval_ms,
      # def_id => last-sent monotonic ms (bus broadcast rate-limit)
      last_sent: %{},
      # def_id => last-streamed monotonic ms (backend stream rate-limit)
      last_streamed: %{},
      # def_id => the damped outputs map from the most recent BUS emission, so the
      # stream sends the SAME smoothed value the bus got (no second EWMA).
      last_damped: %{},
      # {def_id, output_name} => Ewma.state
      damp: %{},
      broadcasting?: false
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:tick_now, _from, state) do
    {count, state} = do_tick(state)
    {:reply, count, state}
  end

  def handle_call(:broadcasting?, _from, state), do: {:reply, state.broadcasting?, state}

  @impl true
  def handle_info(:tick, state) do
    {_count, state} = do_tick(state)
    if state.tick_ms > 0, do: Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- tick ---

  defp do_tick(state) do
    now = state.now_fn.()
    values = current_values(state.engine)

    # 1) Bus broadcast pass (Phase 8 — unchanged): damp + encode + transmit each
    #    eligible+due value, caching the damped outputs so the stream can reuse them.
    {count, state} =
      Enum.reduce(values, {0, state}, fn result, {sent, st} ->
        maybe_broadcast(result, now, sent, st)
      end)

    # 2) Backend stream pass (Phase 10): batch every valid + stream_to_backend value
    #    that is due (~2 Hz) into ONE flush, sending the SAME damped value the bus got.
    state = stream_due_values(values, now, state)

    {count, %{state | broadcasting?: count > 0}}
  end

  defp maybe_broadcast(result, now, sent, state) do
    def = result.def

    if eligible?(result) and due?(def, now, state.last_sent) do
      {damped_outputs, damp} = damp_outputs(def, result.outputs, now, state.damp)

      case PgnEncode.encode(def, damped_outputs) do
        {:ok, payload} ->
          safe_transmit(state.transmit, priority_for(def.output_pgn), def.output_pgn, payload)
          last_sent = Map.put(state.last_sent, def.id, now)
          last_damped = Map.put(state.last_damped, def.id, damped_outputs)
          {sent + 1, %{state | last_sent: last_sent, damp: damp, last_damped: last_damped}}

        :error ->
          # Encoder couldn't build a frame (unsupported PGN / missing field). Keep the
          # damp state we may have updated, but do not mark as sent / advance last_sent.
          {sent, %{state | damp: damp}}
      end
    else
      {sent, state}
    end
  end

  # --- backend stream (Phase 10) ---

  # For every VALID + stream_to_backend def that is due per the stream interval, collect
  # `%{id, value}` (the DAMPED primary-output value) and flush them as ONE batch via the
  # injected stream fn. Streaming is gated only on validity + stream_to_backend — NOT on
  # broadcast_enabled — so a stream-only value is still sent.
  defp stream_due_values(values, now, state) do
    {batch, state} =
      Enum.reduce(values, {[], state}, fn result, {acc, st} ->
        def = result.def

        if stream_eligible?(result) and stream_due?(def, now, st.last_streamed, st.stream_interval_ms) do
          {damped_outputs, st} = stream_damped_outputs(def, result.outputs, now, st)

          case primary_value(def, damped_outputs) do
            {:ok, value} ->
              last_streamed = Map.put(st.last_streamed, def.id, now)
              {[%{id: def.id, value: value} | acc], %{st | last_streamed: last_streamed}}

            :error ->
              {acc, st}
          end
        else
          {acc, st}
        end
      end)

    # One message per flush (never one per value); skip the call entirely when empty.
    case batch do
      [] -> state
      list -> flush_stream(state, Enum.reverse(list))
    end
  end

  # A value is streamed to the backend only when VALID and stream_to_backend is on.
  defp stream_eligible?(%{valid?: true, def: %{stream_to_backend: true}}), do: true
  defp stream_eligible?(_), do: false

  # Low-cadence rate-limit: due if never streamed, or stream_interval_ms has elapsed.
  # Subtract a tiny epsilon so a value scheduled exactly on a tick boundary (interval an
  # exact multiple of the tick) isn't perpetually one tick late.
  defp stream_due?(def, now, last_streamed, interval_ms) do
    case Map.get(last_streamed, def.id) do
      nil -> true
      last_ms -> now - last_ms >= interval_ms - 1
    end
  end

  # The damped outputs to stream. Prefer the value the BUS just emitted this tick (so
  # the stream is byte-identical to the bus); else, for a value not put on the bus
  # (broadcast disabled, or not yet broadcast at its slower rate), damp it here. The
  # shared `damp` map keys each output, so a broadcast-disabled value is smoothed by a
  # SINGLE EWMA chain (driven only by the stream) — never double-smoothed.
  defp stream_damped_outputs(def, outputs, now, state) do
    case Map.fetch(state.last_damped, def.id) do
      {:ok, damped} ->
        {damped, state}

      :error ->
        {damped, damp} = damp_outputs(def, outputs, now, state.damp)
        {damped, %{state | damp: damp}}
    end
  end

  # The def's PRIMARY output value: output_field, falling back to the calc's main
  # output / "value" (mirrors the encoder's first_value). Must be numeric.
  defp primary_value(def, outputs) do
    candidates = Enum.uniq([def.output_field, "value"])

    Enum.find_value(candidates, :error, fn key ->
      case Map.get(outputs, key) do
        v when is_number(v) -> {:ok, v / 1}
        _ -> nil
      end
    end)
  end

  defp flush_stream(state, batch) do
    state.stream.(batch)
    state
  rescue
    error ->
      Logger.warning("Compute backend stream failed: #{inspect(error)}")
      state
  catch
    :exit, _ -> state
  end

  # A value is eligible to go on the bus only when VALID and broadcast-enabled.
  defp eligible?(%{valid?: true, def: %{broadcast_enabled: true}}), do: true
  defp eligible?(_), do: false

  # Rate-limit: due if no prior send, or at least 1/Hz seconds have elapsed. A
  # non-positive / missing rate falls back to "every tick" (treat as due).
  defp due?(def, now, last_sent) do
    case Map.get(last_sent, def.id) do
      nil ->
        true

      last_ms ->
        case def.broadcast_rate_hz do
          hz when is_number(hz) and hz > 0 ->
            # Subtract a tiny epsilon so a value scheduled exactly on a tick boundary
            # (period an exact multiple of the tick) isn't perpetually one tick late.
            now - last_ms >= 1000.0 / hz - 1

          _ ->
            true
        end
    end
  end

  # --- output damping ---

  # Damp every output value of the def with τ = damping_seconds, classified circular
  # vs linear by output name. Returns {damped_outputs, new_damp_state}.
  defp damp_outputs(def, outputs, now, damp) do
    tau = damping_seconds(def)

    Enum.reduce(outputs, {%{}, damp}, fn {name, value}, {acc, dmp} ->
      if is_number(value) do
        key = {def.id, name}
        kind = output_kind(name)
        prev = Map.get(dmp, key)
        {emitted, new_state} = damp_one(prev, value, now, tau, kind)
        {Map.put(acc, name, emitted), Map.put(dmp, key, new_state)}
      else
        {Map.put(acc, name, value), dmp}
      end
    end)
  end

  # Linear: filter the value directly. Circular: convert deg→rad, filter, rad→deg.
  defp damp_one(prev, value, now, tau, :linear) do
    Ewma.update(prev, value, now, tau, :linear)
  end

  defp damp_one(prev, value_deg, now, tau, :circular) do
    {rad, state} = Ewma.update(prev, value_deg * @rad_per_deg, now, tau, :circular)
    {rad * @deg_per_rad, state}
  end

  defp output_kind(name) do
    if MapSet.member?(@circular_outputs, name), do: :circular, else: :linear
  end

  defp damping_seconds(%{damping_seconds: s}) when is_number(s) and s >= 0, do: s
  defp damping_seconds(_), do: 0.0

  # --- transmit (mirrors Nav.Broadcaster) ---

  # Priorities mirror the typical bus priorities for these information PGNs.
  defp priority_for(127_250), do: 2
  defp priority_for(127_257), do: 2
  defp priority_for(129_026), do: 2
  defp priority_for(130_306), do: 2
  defp priority_for(128_259), do: 3
  defp priority_for(128_267), do: 3
  defp priority_for(130_312), do: 5
  defp priority_for(_), do: 6

  defp safe_transmit(fun, priority, pgn, payload) do
    fun.(priority, pgn, payload)
  rescue
    error -> Logger.warning("Compute PGN #{pgn} transmit failed: #{inspect(error)}")
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

  # --- engine collaborator ---

  defp current_values({module, server}) do
    module.current_values(server)
  catch
    :exit, _ -> []
  end

  defp normalize_engine({module, server}) when is_atom(module), do: {module, server}
  defp normalize_engine(module) when is_atom(module) and not is_nil(module), do: {module, module}
  defp normalize_engine(nil), do: {Engine, Engine}
end
