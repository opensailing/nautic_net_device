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

  ## Wind-domain admission (fail-closed) — orthogonal to steadiness

  Binning is bounds-checked at step 3 and the sample is DROPPED when `(tws, twa)`
  falls outside the `Bins` operating domain (`:tws_out_of_domain` /
  `:twa_out_of_domain` in `stats/1`). The steadiness gates cannot catch this: a
  wind sensor stuck at an absurd value is perfectly steady, on-angle and
  non-accelerating, so it sails straight through every `Gate` check. Rejection is
  deliberately FAIL-CLOSED rather than clamped — clamping a 1e9 m/s reading into
  the top wind bin would fold garbage into a legitimate learned percentile,
  whereas leaving it unbounded would mint an arbitrary cell key that is persisted
  to flash and synced upstream forever. On restore, cells whose keys fall outside
  the domain (a file written before this check existed) are dropped for the same
  reason.

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
  alias RacingOrg.Tracker.Pro.Polar.Checkpoint, as: PolarCheckpoint
  alias RacingOrg.Tracker.Pro.Polar.Observer.Bins
  alias RacingOrg.Tracker.Pro.Polar.Observer.Gate
  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare
  alias RacingOrg.Tracker.Pro.Polar.Observer.Snapshot
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
  @database_int_max 9_223_372_036_854_775_807
  @max_finite 1.7976931348623157e308
  @max_finite_integer trunc(1.7976931348623157e308)

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
    with :ok <- validate_checkpoint_config(opts) do
      case Keyword.fetch(opts, :name) do
        {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
        {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
        :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end
    end
  end

  @doc "Run one sample→gate→accumulate tick synchronously; returns this server."
  @spec tick(GenServer.server()) :: :ok
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @doc "Persist the current cells now (throttling is bypassed). Persistence failures are returned."
  @spec persist_now(GenServer.server()) :: :ok | {:error, term()}
  def persist_now(server \\ __MODULE__), do: GenServer.call(server, :persist_now)

  @doc "Emit a sync of changed cells now (throttling is bypassed); returns `:ok`."
  @spec sync_now(GenServer.server()) :: :ok
  def sync_now(server \\ __MODULE__), do: GenServer.call(server, :sync_now)

  @doc """
  Capture the exact call-time learned polar as canonical checkpoint schema-v2
  content. The closed snapshot contains no process or persistence-local state.
  """
  @spec snapshot(GenServer.server()) ::
          {:ok, Snapshot.t()} | {:error, Snapshot.error_reason()}
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc """
  Reconcile one canonical polar snapshot into this Observer.

  The Observer remains the sole writer. When `:dir` is configured, accepted
  content is made target-locally durable before the call replies and before
  restored cells become observable. With persistence disabled (`dir: nil`), the
  same transition is atomic but intentionally memory-only. Repeating an accepted
  canonical identity is a no-op, including after reboot and newer live samples.

  Canonical hashes provide integrity and identity, not authenticity. A production
  caller must authenticate and authorize the envelope before invoking this API.
  """
  @spec restore(GenServer.server(), Snapshot.t()) ::
          :ok
          | {:error,
             Snapshot.error_reason()
             | :authority_mismatch
             | :policy_mismatch
             | {:persistence_failed, term()}
             | :geometry_mismatch
             | :stale_checkpoint
             | :checkpoint_conflict}
  def restore(server \\ __MODULE__, snapshot), do: GenServer.call(server, {:restore, snapshot})

  @doc """
  The populated sailed cells as `[{key, {tws_mps, twa_deg}, %{boat_speed_mps, count}}]`
  (bin center + percentile boat speed + count). For inspection / the future web UI.
  """
  @spec cells(GenServer.server()) :: [{key(), {float(), float()}, map()}]
  def cells(server \\ __MODULE__), do: GenServer.call(server, :cells)

  @doc """
  Observability: `%{admitted, rejected, samples, populated_cells, reject_reasons}`.
  `reject_reasons` is a `%{reason => count}` tally (incl. `:at_rest` for the min-STW
  floor, `:no_true_wind` when true wind could not be derived, and
  `:tws_out_of_domain` / `:twa_out_of_domain` for readings outside the `Bins`
  operating domain).
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
    persist_ms = Keyword.get(opts, :persist_ms, @default_persist_ms)
    min_stw_mps = Keyword.get(opts, :min_stw_mps, @default_min_stw_mps)
    window_size = Keyword.get(opts, :window_size, @default_window_size)
    boat_identifier = Keyword.get_lazy(opts, :boat_identifier, &RacingOrg.Tracker.Pro.boat_identifier/0)
    gate = build_gate(Keyword.get(opts, :gate, []))
    bins = build_bins(Keyword.get(opts, :bins, []))

    with {:ok, policy_hash} <- Snapshot.policy_hash(gate, min_stw_mps, window_size, p),
         {:ok, _empty_snapshot} <- Snapshot.capture(boat_identifier, policy_hash, bins, p, 0, %{}) do
      restored = restore_runtime(dir, boat_identifier, policy_hash, p, bins)
      now_fn = Keyword.get(opts, :now_fn, fn -> System.monotonic_time(:millisecond) end)
      # Anchor both throttle clocks at boot so the FIRST ordinary persist/sync must
      # also wait a full interval. A rejected or legacy persisted runtime is marked
      # immediately due for canonical scrubbing.
      boot_ms = now_fn.()

      state = %{
        dir: dir,
        boat_identifier: boat_identifier,
        sample_ms: sample_ms,
        persist_ms: persist_ms,
        sync_ms: Keyword.get(opts, :sync_ms, @default_sync_ms),
        p: p,
        min_stw_mps: min_stw_mps,
        window_size: window_size,
        bins: bins,
        gate: gate,
        policy_hash: policy_hash,
        signals_fn: Keyword.get(opts, :signals_fn, fn -> safe_signals() end),
        sender: Keyword.get(opts, :sender, &ChannelClient.send_sailed_polar_update/2),
        now_fn: now_fn,
        # Accumulated cells: %{key => {count, PSquare.t()}}.
        cells: restored.cells,
        source_generation: restored.source_generation,
        # Rolling window of recent samples (most-recent LAST).
        window: [],
        # Keys touched since the last persist / last sync. `force_persist` also
        # represents an EMPTY repair, for which there is no key to mark.
        dirty_persist: MapSet.new(),
        dirty_sync: MapSet.new(),
        force_persist: restored.force_persist,
        # Persisted fixed canonical fingerprint of the last accepted restore, so a
        # retry remains idempotent across reboot and subsequent live progress.
        last_restore_fingerprint: restored.last_restore_fingerprint,
        # Throttle clocks (monotonic ms of the last write/sync).
        last_persist_ms: if(restored.force_persist, do: boot_ms - persist_ms, else: boot_ms),
        last_sync_ms: boot_ms,
        # Monotonic sync sequence the server orders/merges by.
        seq: restored.seq,
        stats: %{admitted: 0, rejected: 0, samples: 0, reject_reasons: %{}}
      }

      schedule_tick(state)
      {:ok, state}
    else
      _invalid -> {:stop, :invalid_checkpoint_config}
    end
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, :ok, do_tick(state)}

  def handle_call(:persist_now, _from, state) do
    case persist(state, :force) do
      {:ok, persisted} -> {:reply, :ok, persisted}
      {:error, reason, failed} -> {:reply, {:error, reason}, failed}
    end
  end

  def handle_call(:sync_now, _from, state), do: {:reply, :ok, sync(state, :force)}

  def handle_call(:snapshot, _from, state) do
    {:reply, capture_snapshot(state), state}
  end

  def handle_call({:restore, snapshot}, _from, state) do
    case restore_snapshot(state, snapshot) do
      {:ok, restored} -> {:reply, :ok, restored}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

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
    _ = persist(state, :throttled)
    :ok
  end

  # --- Canonical call-time checkpoint reconciliation ---

  defp capture_snapshot(state) do
    Snapshot.capture(
      state.boat_identifier,
      state.policy_hash,
      state.bins,
      state.p,
      state.source_generation,
      state.cells
    )
  end

  defp restore_snapshot(state, snapshot) do
    with {:ok, incoming} <- Snapshot.hydrate(snapshot),
         :ok <- same_authority(state, incoming),
         :ok <- same_policy(state, incoming),
         :ok <- same_geometry(state, incoming) do
      reconcile_snapshot(state, incoming)
    end
  end

  defp same_authority(state, incoming) do
    if state.boat_identifier == incoming.authority,
      do: :ok,
      else: {:error, :authority_mismatch}
  end

  defp same_policy(state, incoming) do
    if state.p === incoming.p and :crypto.hash_equals(state.policy_hash, incoming.policy_hash),
      do: :ok,
      else: {:error, :policy_mismatch}
  end

  defp same_geometry(state, incoming) do
    if state.bins === incoming.bins, do: :ok, else: {:error, :geometry_mismatch}
  end

  defp same_fingerprint?(left, right)
       when is_binary(left) and byte_size(left) == 32 and is_binary(right) and byte_size(right) == 32,
       do: :crypto.hash_equals(left, right)

  defp same_fingerprint?(_left, _right), do: false

  defp reconcile_snapshot(state, incoming) do
    cond do
      same_fingerprint?(incoming.fingerprint, state.last_restore_fingerprint) ->
        {:ok, state}

      incoming.source_generation < state.source_generation ->
        {:error, :stale_checkpoint}

      incoming.source_generation > state.source_generation ->
        persist_restored_snapshot(state, incoming)

      true ->
        reconcile_same_generation(state, incoming)
    end
  end

  defp reconcile_same_generation(state, incoming) do
    with {:ok, current} <- capture_snapshot(state) do
      if same_fingerprint?(incoming.fingerprint, Snapshot.fingerprint(current)),
        do: persist_restored_snapshot(state, incoming),
        else: {:error, :checkpoint_conflict}
    end
  end

  defp persist_restored_snapshot(state, incoming) do
    candidate = install_snapshot(state, incoming)

    case persist(candidate, :restore) do
      {:ok, persisted} -> {:ok, persisted}
      {:error, reason, _failed_candidate} -> {:error, {:persistence_failed, reason}}
    end
  end

  defp install_snapshot(state, incoming) do
    now_ms = state.now_fn.()

    %{
      state
      | cells: incoming.cells,
        source_generation: incoming.source_generation,
        dirty_persist: MapSet.new(Map.keys(incoming.cells)),
        dirty_sync: MapSet.new(Map.keys(incoming.cells)),
        force_persist: true,
        last_persist_ms: now_ms - state.persist_ms,
        last_restore_fingerprint: incoming.fingerprint
    }
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
        |> maybe_sync()
        |> maybe_persist()

      :no_true_wind ->
        state
        |> bump_samples()
        |> tally_reject(:no_true_wind)
        |> maybe_sync()
        |> maybe_persist()
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
         heading_deg: optional_number(plain, "heading"),
         heel_deg: optional_number(plain, "heel"),
         under_power?: Map.get(plain, "under_power?"),
         engine_rpm: optional_number(plain, "engine_rpm")
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
          {:ok, %{"true_wind_speed" => tws, "true_wind_angle" => twa}} ->
            with {:ok, finite_tws} <- normalize_number(tws),
                 {:ok, finite_twa} <- normalize_number(twa) do
              {:ok, finite_tws, finite_twa}
            end

          _ ->
            :error
        end
    end
  rescue
    _error -> :error
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
  #
  # The (TWS, TWA) pair is bounds-checked FIRST and the sample is dropped when it
  # falls outside the binning domain. This is deliberately FAIL-CLOSED rather than
  # clamped: a wind sensor reading 1e9 m/s would otherwise either mint an
  # unbounded junk cell key (persisted to flash and synced upstream forever) or,
  # if clamped, fold its boat speed into the highest REAL wind cell and poison a
  # legitimate learned percentile. The steadiness gates cannot catch this — a
  # stuck-high sensor is perfectly steady. See `Bins` for the domain and its
  # justification.
  defp accumulate(state, %{tws_mps: tws, twa_deg: twa, stw_mps: stw}) do
    case Bins.fetch_cell(state.bins, tws, twa) do
      {:ok, key} -> add_observation(state, key, stw)
      {:error, reason} -> tally_reject(state, reason)
    end
  end

  defp add_observation(%{source_generation: @database_int_max} = state, _key, _stw),
    do: tally_reject(state, :source_generation_exhausted)

  defp add_observation(state, key, stw) do
    {count, ps} = Map.get(state.cells, key) || {0, PSquare.new(state.p)}

    if count < @database_int_max do
      next_ps = PSquare.add(ps, stw)

      if PSquare.count(next_ps) == PSquare.count(ps) + 1 do
        %{
          state
          | cells: Map.put(state.cells, key, {count + 1, next_ps}),
            source_generation: state.source_generation + 1,
            dirty_persist: MapSet.put(state.dirty_persist, key),
            dirty_sync: MapSet.put(state.dirty_sync, key),
            stats: Map.update!(state.stats, :admitted, &(&1 + 1))
        }
      else
        tally_reject(state, :invalid_boat_speed)
      end
    else
      tally_reject(state, :cell_count_exhausted)
    end
  rescue
    _error -> tally_reject(state, :invalid_boat_speed)
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
    if due?(state.last_persist_ms, state.persist_ms, state) and persistence_dirty?(state) do
      case persist(state, :throttled) do
        {:ok, persisted} -> persisted
        {:error, _reason, failed} -> failed
      end
    else
      state
    end
  end

  defp persist(%{dir: nil} = state, _mode),
    do: {:ok, persistence_succeeded(state)}

  defp persist(state, mode) do
    if mode in [:force, :restore] or persistence_dirty?(state) do
      case Store.save_runtime(state.dir, persisted_runtime(state)) do
        :ok -> {:ok, persistence_succeeded(state)}
        {:error, reason} -> {:error, reason, persistence_failed(state)}
      end
    else
      {:ok, state}
    end
  end

  defp persisted_runtime(state) do
    %{
      authority: state.boat_identifier,
      policy_hash: state.policy_hash,
      source_generation: state.source_generation,
      seq: state.seq,
      last_restore_fingerprint: state.last_restore_fingerprint,
      p: state.p,
      bins: state.bins,
      cells: state.cells
    }
  end

  defp persistence_succeeded(state) do
    %{
      state
      | dirty_persist: MapSet.new(),
        force_persist: false,
        last_persist_ms: state.now_fn.()
    }
  end

  defp persistence_failed(state), do: %{state | last_persist_ms: state.now_fn.()}

  defp persistence_dirty?(state),
    do: state.force_persist or not Enum.empty?(state.dirty_persist)

  defp restore_runtime(nil, _authority, _policy_hash, _p, _bins),
    do: empty_restored(false)

  defp restore_runtime(dir, authority, policy_hash, p, bins) do
    case Store.load_runtime(dir) do
      :empty ->
        empty_restored(false)

      :invalid ->
        empty_restored(true)

      {:ok, %{legacy?: true} = runtime} ->
        restore_legacy_runtime(runtime, p, bins)

      {:ok, runtime} ->
        restore_bound_runtime(runtime, authority, policy_hash, p, bins)
    end
  end

  defp restore_legacy_runtime(runtime, p, bins) do
    with {:ok, cells, _repaired?} <- validated_cells(runtime.cells, p, bins),
         {:ok, source_generation} <- legacy_generation(cells) do
      %{
        cells: cells,
        source_generation: source_generation,
        seq: runtime.seq,
        last_restore_fingerprint: nil,
        force_persist: true
      }
    else
      _invalid -> empty_restored(true)
    end
  end

  defp restore_bound_runtime(runtime, authority, policy_hash, p, bins) do
    with true <- runtime.authority == authority,
         true <- :crypto.hash_equals(runtime.policy_hash, policy_hash),
         true <- runtime.p === p,
         true <- runtime.bins === bins,
         {:ok, cells, repaired?} <- validated_cells(runtime.cells, p, bins) do
      upgrade? = Map.get(runtime, :upgrade?, false)

      %{
        cells: cells,
        source_generation: runtime.source_generation,
        seq: runtime.seq,
        last_restore_fingerprint: if(repaired?, do: nil, else: runtime.last_restore_fingerprint),
        force_persist: repaired? or upgrade?
      }
    else
      _mismatch -> empty_restored(true)
    end
  end

  defp validated_cells(cells, p, bins) when is_map(cells) do
    with {:ok, _empty_content} <- PolarCheckpoint.project(bins, p, %{}) do
      {in_domain, domain_repaired?} = drop_out_of_domain(cells, bins)

      {valid, rejected} =
        Enum.reduce(in_domain, {%{}, []}, fn {key, cell}, {accepted, rejected} ->
          case PolarCheckpoint.project(bins, p, %{key => cell}) do
            {:ok, _content} -> {Map.put(accepted, key, cell), rejected}
            {:error, :invalid_checkpoint_content} -> {accepted, [key | rejected]}
          end
        end)

      if rejected != [] do
        Logger.warning(
          "[Polar.Observer] dropped #{length(rejected)} malformed sailed-polar cell(s) on restore: " <>
            inspect(Enum.take(rejected, 5))
        )
      end

      {:ok, valid, domain_repaired? or rejected != []}
    end
  rescue
    _error -> :error
  end

  defp validated_cells(_cells, _p, _bins), do: :error

  defp legacy_generation(cells) do
    Enum.reduce_while(cells, {:ok, 0}, fn
      {_key, {count, _quantile}}, {:ok, total}
      when is_integer(count) and count > 0 and total <= @database_int_max - count ->
        {:cont, {:ok, total + count}}

      _cell, _total ->
        {:halt, :error}
    end)
  end

  defp empty_restored(force_persist) do
    %{
      cells: %{},
      source_generation: 0,
      seq: 0,
      last_restore_fingerprint: nil,
      force_persist: force_persist
    }
  end

  # A file written before the binning domain was enforced (or a tampered one) can
  # carry unbounded junk keys minted from a bad sensor reading. Restoring them
  # would resurrect the poisoned state and re-sync it upstream forever, so they
  # are dropped on load — the same fail-closed stance as ingestion.
  defp drop_out_of_domain(cells, bins) do
    {kept, dropped} = Map.split_with(cells, fn {key, _cell} -> Bins.valid_key?(bins, key) end)
    repaired? = map_size(dropped) > 0

    if repaired? do
      Logger.warning(
        "[Polar.Observer] dropped #{map_size(dropped)} out-of-domain sailed-polar cell(s) on restore: " <>
          inspect(Map.keys(dropped) |> Enum.take(5))
      )
    end

    {kept, repaired?}
  end

  # --- Throttled / batched upstream sync ---

  defp maybe_sync(state) do
    if due?(state.last_sync_ms, state.sync_ms, state) and not Enum.empty?(state.dirty_sync) do
      sync(state, :throttled)
    else
      state
    end
  end

  defp sync(%{seq: @database_int_max} = state, _mode) do
    Logger.warning("[Polar.Observer] sailed-polar sync sequence exhausted")
    state
  end

  defp sync(state, _mode) do
    if Enum.empty?(state.dirty_sync) do
      state
    else
      seq = state.seq + 1
      changed = MapSet.to_list(state.dirty_sync)
      update = %{boat_identifier: state.boat_identifier, seq: seq, cells: encode_cells(state, changed)}
      candidate = %{state | seq: seq, force_persist: true}

      case persist(candidate, :force) do
        {:ok, persisted} ->
          _ = safe_send(persisted.sender, update)
          %{persisted | dirty_sync: MapSet.new(), last_sync_ms: persisted.now_fn.()}

        {:error, _reason, failed} ->
          %{state | last_persist_ms: failed.last_persist_ms, last_sync_ms: state.now_fn.()}
      end
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

  defp validate_checkpoint_config(opts) do
    p = Keyword.get(opts, :p, @default_p)
    min_stw_mps = Keyword.get(opts, :min_stw_mps, @default_min_stw_mps)
    window_size = Keyword.get(opts, :window_size, @default_window_size)
    boat_identifier = Keyword.get_lazy(opts, :boat_identifier, &RacingOrg.Tracker.Pro.boat_identifier/0)
    gate = build_gate(Keyword.get(opts, :gate, []))
    bins = build_bins(Keyword.get(opts, :bins, []))

    with {:ok, policy_hash} <- Snapshot.policy_hash(gate, min_stw_mps, window_size, p),
         {:ok, _empty_snapshot} <- Snapshot.capture(boat_identifier, policy_hash, bins, p, 0, %{}) do
      :ok
    else
      _invalid -> {:error, :invalid_checkpoint_config}
    end
  rescue
    _invalid -> {:error, :invalid_checkpoint_config}
  end

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
    with {:ok, value} <- Map.fetch(plain, name),
         {:ok, finite} <- normalize_number(value) do
      {:ok, finite}
    else
      _error -> :error
    end
  end

  defp optional_number(plain, name) do
    case Map.fetch(plain, name) do
      {:ok, value} ->
        case normalize_number(value) do
          {:ok, finite} -> finite
          :error -> nil
        end

      :error ->
        nil
    end
  end

  defp normalize_number(value) when is_float(value) do
    if value == value and value <= @max_finite and value >= -@max_finite,
      do: {:ok, value},
      else: :error
  end

  defp normalize_number(value)
       when is_integer(value) and value <= @max_finite_integer and value >= -@max_finite_integer,
       do: {:ok, value + 0.0}

  defp normalize_number(_value), do: :error

  defp safe_signals do
    Engine.signals()
  catch
    :exit, _ -> %{}
  end
end
