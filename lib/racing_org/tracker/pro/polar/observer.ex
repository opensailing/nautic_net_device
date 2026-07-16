defmodule RacingOrg.Tracker.Pro.Polar.Observer do
  @moduledoc """
  The SECONDARY observational ("sailed") polar, built live on the device from the
  boat's own steady-state sailing — purely OBSERVED, cells empty until sailed,
  cumulative over time, persisted across reboots, and synced upstream as
  incremental deltas.

  It is fully INDEPENDENT of the reference polar (`RacingOrg.Tracker.Pro.Commands.current_polar`):
  it never reads, writes, or replaces it. The reference polar is the server-pushed
  "design" polar; this is what the boat has actually achieved.

  ## The loop (≈ 1 Hz, off the compute hot path)

  On its OWN timer (default 1 s — NOT the per-signal compute tick), each `:tick`:

    1. **Sample.** Read the current raw-signal map from the compute engine
       (`Compute.Engine.signals/1`) once. Derive **STW-based true wind** from it via
       `Compute.Library.compute(:true_wind, …)` — apparent wind + boat speed (STW)
       are ESSENTIAL; heel, pitch, and heading are optional refinements. This is
       deliberately STW-based (NOT SOG-based) and is computed HERE from raw signals,
       so the sailed polar works WITHOUT depending on the reference polar or a
       server-pushed `:true_wind` computed-value def. If the network already
       publishes `true_wind_*` signals they are used as-is; otherwise the STW
       triangle supplies them. A boat with no heel sensor still samples: the sample
       simply carries `heel_deg: nil`.

    2. **Window + admission.** Push the sample onto a rolling window
       (most-recent-last, capped at `:window_size`). A sample is accumulated only if
       (a) the boat is MOVING — `stw_mps > :min_stw_mps` (default 0.3 m/s, ≈ 0.6 kn)
       — AND (b) `Observer.Gate.evaluate/2` returns `:admit` over the window (settled,
       on-angle, level, steady wind, no turn, no accel, not motoring). Heel is an
       accuracy ENHANCER, never an availability gate: the Gate's heel-band check runs
       only when the sample carries a heel and is skipped when it is absent (like its
       motoring skip), so heel-less boats still accumulate. The min-STW floor is
       applied in the Observer (NOT folded into the Gate) so the Gate stays a pure
       STEADINESS filter; see "Min-STW" below. Reject reasons are tallied cheaply for
       observability (`stats/1`).

    3. **Accumulate.** On `:admit`, map `(tws, twa)` to a `Bins` cell key, fold the
       sample's `boat_speed` (STW) into that cell's streaming `PSquare` quantile
       (default p = 0.90) in O(1), and bump the cell's count. The touched cell is
       marked dirty for the next persist + sync.

  ## Min-STW (admission floor) — why in the Observer, not the Gate

  `Gate` answers "is the boat in quasi-steady sailing state?" — its filters are all
  about steadiness/maneuvering/motoring. A boat sitting at anchor in steady wind on a
  valid angle would PASS the gate yet must never seed a cell. "Is the boat moving at
  all?" is an orthogonal precondition, not a steadiness test, so it lives here as a
  cheap pre-filter. This keeps `Gate`'s contract pure and reusable, avoids a per-sample
  STW field inside its window-wide reduction, and lets the floor be tuned per deployment
  without touching the steady-state logic.

  ## Persistence (throttled atomic flash writes)

  Cells are persisted to `<dir>/sailed.polar` via `Observer.Store` (the same atomic,
  versioned, corruption-safe `term_to_binary`/`:safe` pattern as the reference
  `Polar.Store`). Writes are THROTTLED to limit flash wear: a persist happens at most
  every `:persist_ms` (default 30 s) AND only when at least one cell changed since the
  last write, plus a final flush on `terminate`. On boot the Observer restores the
  persisted cells and RESUMES accumulation (counts/percentiles continue). A missing /
  corrupt / unknown-version file starts empty without crashing. With `dir == nil`
  (the host/test default, mirroring `Commands`) persistence is disabled entirely.

  ## Upstream sync (throttled / batched incremental deltas)

  Changed cells are emitted upstream as incremental deltas at most every `:sync_ms`
  (default 30 s) — NEVER per sample. Each sync sends ONLY the cells that changed since
  the last sync (a cell whose count/percentile moved), as
  `%{tws_mps, twa_deg, boat_speed_mps, count}` (bin center + percentile speed + count),
  tagged with a stable `:boat_identifier` and a monotonic `:seq` so the backend can
  order/merge (later `seq` wins per cell). The emission goes through an INJECTABLE
  sender (`:sender`, default `ChannelClient.send_sailed_polar_update/2`) so it is
  testable with a stub; the backend ingest is a separate job. Unchanged cells are not
  re-sent.
  """

  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.Compute.Engine
  alias RacingOrg.Tracker.Pro.Compute.Library
  alias RacingOrg.Tracker.Pro.Polar.Observer.Bins
  alias RacingOrg.Tracker.Pro.Polar.Observer.Gate
  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare
  alias RacingOrg.Tracker.Pro.Polar.Observer.Store
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient

  @default_sample_ms 1_000
  @default_persist_ms 30_000
  @default_sync_ms 30_000
  @default_p 0.90
  # 0.3 m/s ≈ 0.6 kn: below this the boat is at rest / drifting and must not seed cells.
  @default_min_stw_mps 0.3
  # Rolling window length. Must be ≥ the gate's dwell; the default gate dwell is 10.
  @default_window_size 10

  @type key :: {non_neg_integer(), non_neg_integer()}
  @type cell :: {non_neg_integer(), PSquare.t()}

  # --- Client API ---

  @doc """
  Start the Observer.

  Options:

    * `:name` — registered name (default `__MODULE__`; pass `nil` for anonymous).
    * `:dir` — persistence directory for `sailed.polar`. `nil` (the host/test default)
      DISABLES persistence, mirroring `Commands`.
    * `:boat_identifier` — stable device/boat id stamped on every sync (default
      `RacingOrg.Tracker.Pro.boat_identifier/0`).
    * `:sample_ms` — sampling period (default `1000`). `0` disables the timer (tests
      drive `tick/1` directly).
    * `:persist_ms` — minimum interval between flash writes (default `30_000`).
    * `:sync_ms` — minimum interval between upstream syncs (default `30_000`).
    * `:p` — per-cell boat-speed quantile (default `0.90`).
    * `:min_stw_mps` — minimum speed-through-water to admit (default `0.3`).
    * `:window_size` — rolling window length (default `10`).
    * `:bins` — `Bins` opts (`:tws_width_mps`, `:twa_width_deg`) or a `Bins.t()`.
    * `:gate` — `Gate` opts (thresholds) or a `Gate.t()`.
    * `:signals_fn` — 0-arity fn returning the raw-signal map (default reads
      `Compute.Engine.signals/0`). Injectable for tests.
    * `:sender` — 2-arity fn `(channel_client_module, update) -> :ok` used to emit a
      sync. The first arg is the `ChannelClient` collaborator module (NOT a boat id —
      the boat is already carried in `state.boat_identifier` / `update.boat_identifier`).
      Default `&ChannelClient.send_sailed_polar_update/2`. Injectable for tests.
    * `:now_fn` — 0-arity monotonic-ms clock (default `System.monotonic_time/1`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc "Run one sample→gate→accumulate tick synchronously; returns this server."
  @spec tick(GenServer.server()) :: :ok
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @doc "Persist the current cells now (throttling is bypassed); returns `:ok`."
  @spec persist_now(GenServer.server()) :: :ok
  def persist_now(server \\ __MODULE__), do: GenServer.call(server, :persist_now)

  @doc "Emit a sync of changed cells now (throttling is bypassed); returns `:ok`."
  @spec sync_now(GenServer.server()) :: :ok
  def sync_now(server \\ __MODULE__), do: GenServer.call(server, :sync_now)

  @doc """
  The populated sailed cells as `[{key, {tws_mps, twa_deg}, %{boat_speed_mps, count}}]`
  (bin center + percentile boat speed + count). For inspection / the future web UI.
  """
  @spec cells(GenServer.server()) :: [{key(), {float(), float()}, map()}]
  def cells(server \\ __MODULE__), do: GenServer.call(server, :cells)

  @doc """
  Observability: `%{admitted, rejected, samples, populated_cells, reject_reasons}`.
  `reject_reasons` is a `%{reason => count}` tally (incl. `:at_rest` for the min-STW
  floor and `:no_true_wind` when true wind could not be derived).
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # --- Server ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    sample_ms = Keyword.get(opts, :sample_ms, @default_sample_ms)
    p = Keyword.get(opts, :p, @default_p)
    dir = Keyword.get(opts, :dir)
    now_fn = Keyword.get(opts, :now_fn, fn -> System.monotonic_time(:millisecond) end)
    # Anchor both throttle clocks at boot so the FIRST persist/sync must also wait a
    # full interval — the device never writes flash or hits the network on tick 1.
    boot_ms = now_fn.()

    state = %{
      dir: dir,
      boat_identifier: Keyword.get_lazy(opts, :boat_identifier, &RacingOrg.Tracker.Pro.boat_identifier/0),
      sample_ms: sample_ms,
      persist_ms: Keyword.get(opts, :persist_ms, @default_persist_ms),
      sync_ms: Keyword.get(opts, :sync_ms, @default_sync_ms),
      p: p,
      min_stw_mps: Keyword.get(opts, :min_stw_mps, @default_min_stw_mps),
      window_size: Keyword.get(opts, :window_size, @default_window_size),
      bins: build_bins(Keyword.get(opts, :bins, [])),
      gate: build_gate(Keyword.get(opts, :gate, [])),
      signals_fn: Keyword.get(opts, :signals_fn, fn -> safe_signals() end),
      sender: Keyword.get(opts, :sender, &ChannelClient.send_sailed_polar_update/2),
      now_fn: now_fn,
      # Accumulated cells: %{key => {count, PSquare.t()}}.
      cells: restore(dir),
      # Rolling window of recent samples (most-recent LAST).
      window: [],
      # Keys touched since the last persist / last sync.
      dirty_persist: MapSet.new(),
      dirty_sync: MapSet.new(),
      # Throttle clocks (monotonic ms of the last write/sync), anchored at boot so the
      # first fire also waits a full interval.
      last_persist_ms: boot_ms,
      last_sync_ms: boot_ms,
      # Monotonic sync sequence the server orders/merges by.
      seq: 0,
      stats: %{admitted: 0, rejected: 0, samples: 0, reject_reasons: %{}}
    }

    schedule_tick(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, :ok, do_tick(state)}

  def handle_call(:persist_now, _from, state), do: {:reply, :ok, persist(state, :force)}

  def handle_call(:sync_now, _from, state), do: {:reply, :ok, sync(state, :force)}

  def handle_call(:cells, _from, state), do: {:reply, project_cells(state), state}

  def handle_call(:stats, _from, state) do
    summary =
      state.stats
      |> Map.put(:populated_cells, map_size(state.cells))

    {:reply, summary, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = do_tick(state)
    schedule_tick(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Final flush so the last accumulation window is not lost on shutdown.
    _ = persist(state, :force)
    :ok
  end

  # --- The tick: sample -> window -> admit -> accumulate -> throttled persist/sync ---

  defp do_tick(state) do
    signals = state.signals_fn.()

    case build_sample(signals, state) do
      {:ok, sample} ->
        state
        |> push_window(sample)
        |> admit(sample)
        |> bump_samples()
        |> maybe_persist()
        |> maybe_sync()

      :no_true_wind ->
        state
        |> bump_samples()
        |> tally_reject(:no_true_wind)
    end
  end

  # Build the Gate sample from the current raw signals. True wind is STW-based:
  # prefer live network `true_wind_*` signals, else derive them from the apparent-wind
  # / STW triangle via Library.compute(:true_wind, …) (heel/pitch/heading are optional
  # refinements there). Without boat_speed (STW) or a derivable true wind there is no
  # admissible sample. heel/heading/motoring are carried as-is (nil when absent) — the
  # Gate skips the checks it has no signal for, so none of them gate availability.
  defp build_sample(signals, state) do
    plain = strip_timestamps(signals)

    with {:ok, stw} <- fetch(plain, "boat_speed"),
         {:ok, tws, twa} <- true_wind(plain) do
      {:ok,
       %{
         t_ms: signal_time(signals) || state.now_fn.(),
         tws_mps: tws,
         twa_deg: twa,
         stw_mps: stw,
         heading_deg: Map.get(plain, "heading"),
         heel_deg: Map.get(plain, "heel"),
         under_power?: Map.get(plain, "under_power?"),
         engine_rpm: Map.get(plain, "engine_rpm")
       }}
    else
      _ -> :no_true_wind
    end
  end

  # STW-based true wind. Uses live network true_wind_* signals if present (they are
  # the same STW-referenced quantities on an instrumented boat), else computes the
  # STW triangle. Decoupled from the reference polar / server-pushed defs.
  defp true_wind(plain) do
    with {:ok, tws} <- fetch(plain, "true_wind_speed"),
         {:ok, twa} <- fetch(plain, "true_wind_angle") do
      {:ok, tws, twa}
    else
      _ ->
        case Library.compute(:true_wind, plain) do
          {:ok, %{"true_wind_speed" => tws, "true_wind_angle" => twa}} -> {:ok, tws, twa}
          _ -> :error
        end
    end
  end

  defp push_window(state, sample) do
    window = (state.window ++ [sample]) |> Enum.take(-state.window_size)
    %{state | window: window}
  end

  # Min-STW floor first (orthogonal to steadiness), then the Gate over the window.
  defp admit(state, %{stw_mps: stw}) when stw <= 0.0 or is_nil(stw),
    do: tally_reject(state, :at_rest)

  defp admit(state, %{stw_mps: stw} = sample) do
    if stw > state.min_stw_mps do
      case Gate.evaluate(state.gate, state.window) do
        :admit -> accumulate(state, sample)
        {:reject, reason} -> tally_reject(state, reason)
      end
    else
      tally_reject(state, :at_rest)
    end
  end

  # Fold STW into the cell's PSquare, bump its count, mark it dirty for persist+sync.
  defp accumulate(state, %{tws_mps: tws, twa_deg: twa, stw_mps: stw}) do
    key = Bins.cell(state.bins, tws, twa)
    {count, ps} = Map.get(state.cells, key) || {0, PSquare.new(state.p)}
    cell = {count + 1, PSquare.add(ps, stw)}

    %{
      state
      | cells: Map.put(state.cells, key, cell),
        dirty_persist: MapSet.put(state.dirty_persist, key),
        dirty_sync: MapSet.put(state.dirty_sync, key),
        stats: Map.update!(state.stats, :admitted, &(&1 + 1))
    }
  end

  defp bump_samples(state),
    do: %{state | stats: Map.update!(state.stats, :samples, &(&1 + 1))}

  defp tally_reject(state, reason) do
    stats =
      state.stats
      |> Map.update!(:rejected, &(&1 + 1))
      |> Map.update!(:reject_reasons, &Map.update(&1, reason, 1, fn c -> c + 1 end))

    %{state | stats: stats}
  end

  # --- Throttled persistence ---

  defp maybe_persist(state) do
    if due?(state.last_persist_ms, state.persist_ms, state) and
         not Enum.empty?(state.dirty_persist) do
      persist(state, :throttled)
    else
      state
    end
  end

  defp persist(%{dir: nil} = state, _mode), do: %{state | dirty_persist: MapSet.new()}

  defp persist(state, _mode) do
    if Enum.empty?(state.dirty_persist) do
      state
    else
      _ = Store.save(state.dir, state.cells)
      %{state | dirty_persist: MapSet.new(), last_persist_ms: state.now_fn.()}
    end
  end

  defp restore(nil), do: %{}

  defp restore(dir) do
    case Store.load(dir) do
      {:ok, cells} -> cells
      :empty -> %{}
    end
  end

  # --- Throttled / batched upstream sync ---

  defp maybe_sync(state) do
    if due?(state.last_sync_ms, state.sync_ms, state) and not Enum.empty?(state.dirty_sync) do
      sync(state, :throttled)
    else
      state
    end
  end

  defp sync(state, _mode) do
    if Enum.empty?(state.dirty_sync) do
      state
    else
      seq = state.seq + 1
      changed = MapSet.to_list(state.dirty_sync)
      update = %{boat_identifier: state.boat_identifier, seq: seq, cells: encode_cells(state, changed)}

      _ = safe_send(state.sender, update)
      %{state | dirty_sync: MapSet.new(), last_sync_ms: state.now_fn.(), seq: seq}
    end
  end

  defp encode_cells(state, keys) do
    Enum.map(keys, fn key ->
      {count, ps} = Map.fetch!(state.cells, key)
      {tws_c, twa_c} = Bins.center(state.bins, key)
      %{tws_mps: tws_c, twa_deg: twa_c, boat_speed_mps: PSquare.value(ps), count: count}
    end)
  end

  defp safe_send(sender, update) do
    sender.(ChannelClient, update)
  rescue
    error -> Logger.warning("[Polar.Observer] sailed-polar sync failed: #{inspect(error)}")
  catch
    :exit, _ -> :ok
  end

  # --- Projections / helpers ---

  defp project_cells(state) do
    Bins.populated(state.bins, state.cells)
    |> Enum.map(fn {key, center, {count, ps}} ->
      {key, center, %{boat_speed_mps: PSquare.value(ps), count: count}}
    end)
  end

  # A throttle is "due" once `interval` ms have elapsed since the last fire (the
  # clocks are anchored at boot, so even the first fire waits a full interval).
  defp due?(last_ms, interval, state), do: state.now_fn.() - last_ms >= interval

  defp schedule_tick(%{sample_ms: ms}) when ms > 0, do: Process.send_after(self(), :tick, ms)
  defp schedule_tick(_state), do: :ok

  defp build_bins(%Bins{} = b), do: b
  defp build_bins(opts) when is_list(opts), do: Bins.new(opts)

  defp build_gate(%Gate{} = g), do: g
  defp build_gate(opts) when is_list(opts), do: Gate.new(opts)

  # Engine.signals/0 returns %{name => {value, mono_ms}}; Library wants %{name => value}.
  defp strip_timestamps(signals) do
    Map.new(signals, fn
      {name, {value, _mono_ms}} -> {name, value}
      {name, value} -> {name, value}
    end)
  end

  defp signal_time(signals) do
    signals
    |> Map.values()
    |> Enum.reduce(nil, fn
      {_value, mono_ms}, acc when is_integer(mono_ms) -> max(acc || mono_ms, mono_ms)
      _, acc -> acc
    end)
  end

  defp fetch(plain, name) do
    case Map.fetch(plain, name) do
      {:ok, v} when is_number(v) -> {:ok, v / 1}
      _ -> :error
    end
  end

  defp safe_signals do
    Engine.signals()
  catch
    :exit, _ -> %{}
  end
end
