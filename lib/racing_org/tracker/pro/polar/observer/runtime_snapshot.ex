defmodule RacingOrg.Tracker.Pro.Polar.Observer.RuntimeSnapshot do
  @moduledoc """
  Closed full-runtime snapshot for the sailed-polar observer.

  The learner is the existing canonical polar checkpoint-v2 envelope. This module
  adds only causal Observer state: exact authority and policy, the rolling Gate
  window, upstream sequencing, dirty persistence/sync subsets and cadence phases,
  plus the remaining sample-timer phase. Monotonic timestamps cross the boundary
  as bounded ages and are advanced by elapsed UTC time before rebasing.

  Collaborators, filesystem paths, timer references/tokens, secrets, and generic
  metadata are deliberately excluded. Validation is independent of the durable
  transport's current single-frame ceiling; the learner keeps the larger local
  reconciliation ceiling owned by `Observer.Snapshot`.
  """

  alias RacingOrg.Tracker.Pro.Polar.Observer.Bins
  alias RacingOrg.Tracker.Pro.Polar.Observer.Gate
  alias RacingOrg.Tracker.Pro.Polar.Observer.Snapshot
  alias RacingOrg.Tracker.Pro.RuntimeSnapshot, as: Shared

  @version 1
  @database_int_max 9_223_372_036_854_775_807
  @max_window_size 100_000
  @max_speed_mps 1_310.64
  @max_engine_rpm 10_000_000.0
  @max_finite 9_007_199_254_740_991
  @error {:error, :invalid_runtime_snapshot}

  @top_fields [
    :version,
    :captured_at_utc_ms,
    :authority,
    :policy,
    :learner,
    :upstream_seq,
    :window,
    :sync,
    :persistence_phase,
    :tick
  ]
  @authority_fields [:boat_identifier]
  @policy_fields [
    :admission_hash,
    :gate,
    :min_stw_mps,
    :window_size,
    :p,
    :sample_ms,
    :sync_ms,
    :persist_ms,
    :persistence_enabled,
    :bins
  ]
  @bins_fields [:twa_width_deg, :tws_width_mps, :max_tws_mps]
  @gate_fields [
    :angle_band_deg,
    :heel_band_deg,
    :max_tws_sd_mps,
    :max_turn_rate_dps,
    :max_accel_mps2,
    :min_dwell,
    :engine_rpm_idle,
    :angle_key
  ]
  @learner_fields [:source_generation, :content]
  @window_fields [
    :age_ms,
    :tws_mps,
    :twa_deg,
    :stw_mps,
    :heading_deg,
    :heel_deg,
    :under_power?,
    :engine_rpm
  ]
  @sync_fields [:dirty_keys, :last_sync_age_ms]
  @persistence_fields [:dirty_keys, :force, :last_persist_age_ms]
  @key_fields [:tws_bin, :twa_bin]
  @tick_fields [:remaining_ms]

  @type t :: map()
  @type restored :: %{
          cells: map(),
          source_generation: non_neg_integer(),
          window: [map()],
          dirty_sync: MapSet.t(),
          dirty_persist: MapSet.t(),
          force_persist: boolean(),
          last_sync_ms: integer(),
          last_persist_ms: integer(),
          seq: non_neg_integer(),
          tick_delay_ms: non_neg_integer() | nil,
          checkpoint_fingerprint: binary()
        }

  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Project one Observer state into the exact closed runtime envelope."
  @spec project(map(), integer(), DateTime.t() | non_neg_integer()) ::
          {:ok, t()} | {:error, :invalid_runtime_snapshot}
  def project(state, captured_at_ms, captured_at_utc)
      when is_map(state) and is_integer(captured_at_ms) do
    with {:ok, captured_at_utc_ms} <- Shared.utc_ms(captured_at_utc),
         {:ok, authority} <- project_authority(state),
         {:ok, policy} <- project_policy(state),
         {:ok, checkpoint} <-
           Snapshot.capture(
             state.boat_identifier,
             state.policy_hash,
             state.bins,
             state.p,
             state.source_generation,
             state.cells
           ),
         {:ok, window} <- project_window(state.window, captured_at_ms, state.window_size),
         {:ok, dirty_sync} <- project_dirty_keys(state.dirty_sync, state.cells),
         {:ok, dirty_persist} <- project_dirty_keys(state.dirty_persist, state.cells),
         {:ok, last_sync_age_ms} <- project_cadence_age(state.last_sync_ms, captured_at_ms, state.sync_ms),
         {:ok, last_persist_age_ms} <-
           project_cadence_age(state.last_persist_ms, captured_at_ms, state.persist_ms),
         {:ok, tick} <- project_tick(state, captured_at_ms),
         true <- database_int?(state.source_generation),
         true <- database_int?(state.seq),
         true <- is_boolean(state.force_persist) do
      snapshot = %{
        version: @version,
        captured_at_utc_ms: captured_at_utc_ms,
        authority: authority,
        policy: policy,
        learner: %{source_generation: state.source_generation, content: checkpoint},
        upstream_seq: state.seq,
        window: window,
        sync: %{dirty_keys: dirty_sync, last_sync_age_ms: last_sync_age_ms},
        persistence_phase: %{
          dirty_keys: dirty_persist,
          force: state.force_persist,
          last_persist_age_ms: last_persist_age_ms
        },
        tick: tick
      }

      case preflight(snapshot) do
        :ok -> {:ok, snapshot}
        _ -> @error
      end
    else
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  def project(_state, _captured_at_ms, _captured_at_utc), do: @error

  @doc "Cheap exact-shape and bounded semantic validation before restore fencing."
  @spec preflight(term()) :: :ok | {:error, :invalid_runtime_snapshot}
  def preflight(snapshot) do
    with :ok <- Shared.exact_keys(snapshot, @top_fields),
         true <- snapshot.version == @version,
         {:ok, _captured_at_utc_ms} <- Shared.utc_ms(snapshot.captured_at_utc_ms),
         :ok <- validate_authority(snapshot.authority),
         {:ok, gate, policy_bins} <- validate_policy(snapshot.policy),
         :ok <- Shared.exact_keys(snapshot.learner, @learner_fields),
         true <- database_int?(snapshot.learner.source_generation),
         {:ok, learner} <- Snapshot.hydrate(snapshot.learner.content),
         true <- learner.source_generation == snapshot.learner.source_generation,
         true <- learner.bins === policy_bins,
         true <- learner.authority == snapshot.authority.boat_identifier,
         true <- secure_equal?(learner.policy_hash, snapshot.policy.admission_hash),
         true <- learner.p === snapshot.policy.p,
         true <- gate.min_dwell <= snapshot.policy.window_size,
         :ok <- validate_window(snapshot.window, snapshot.policy.window_size),
         :ok <- validate_phase(snapshot.sync, @sync_fields),
         :ok <- validate_phase(snapshot.persistence_phase, @persistence_fields),
         true <- is_boolean(snapshot.persistence_phase.force),
         :ok <- validate_dirty_keys(snapshot.sync.dirty_keys, learner.cells, learner.bins),
         :ok <- validate_dirty_keys(snapshot.persistence_phase.dirty_keys, learner.cells, learner.bins),
         :ok <- validate_cadence_age(snapshot.sync.last_sync_age_ms, snapshot.policy.sync_ms),
         :ok <-
           validate_cadence_age(
             snapshot.persistence_phase.last_persist_age_ms,
             snapshot.policy.persist_ms
           ),
         true <- database_int?(snapshot.upstream_seq),
         :ok <- validate_tick(snapshot.tick, snapshot.policy.sample_ms) do
      :ok
    else
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  @doc "Return the deterministic identity of one already closed runtime snapshot."
  @spec digest(term()) :: {:ok, binary()} | {:error, :invalid_runtime_snapshot}
  def digest(snapshot) do
    with :ok <- preflight(snapshot) do
      {:ok, :crypto.hash(:sha256, :erlang.term_to_binary(snapshot, [:deterministic]))}
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  @doc "Validate, advance powered-off ages, and hydrate a complete runtime patch."
  @spec restore(t(), integer(), DateTime.t() | non_neg_integer()) ::
          {:ok, restored()} | {:error, :invalid_runtime_snapshot}
  def restore(snapshot, restored_at_ms, restored_at_utc)
      when is_map(snapshot) and is_integer(restored_at_ms) do
    with :ok <- preflight(snapshot),
         {:ok, restored_at_utc_ms} <- Shared.utc_ms(restored_at_utc),
         {:ok, elapsed_ms} <-
           Shared.elapsed_wall_ms(snapshot.captured_at_utc_ms, restored_at_utc_ms),
         {:ok, learner} <- Snapshot.hydrate(snapshot.learner.content),
         {:ok, window} <- restore_window(snapshot.window, restored_at_ms, elapsed_ms),
         {:ok, last_sync_age_ms} <-
           advance_cadence_age(snapshot.sync.last_sync_age_ms, elapsed_ms, snapshot.policy.sync_ms),
         {:ok, last_persist_age_ms} <-
           advance_cadence_age(
             snapshot.persistence_phase.last_persist_age_ms,
             elapsed_ms,
             snapshot.policy.persist_ms
           ),
         {:ok, tick_delay_ms} <- restore_tick(snapshot.tick, snapshot.policy.sample_ms, elapsed_ms) do
      {:ok,
       %{
         cells: learner.cells,
         source_generation: snapshot.learner.source_generation,
         window: window,
         dirty_sync: restore_dirty_keys(snapshot.sync.dirty_keys),
         dirty_persist: restore_dirty_keys(snapshot.persistence_phase.dirty_keys),
         force_persist: snapshot.persistence_phase.force,
         last_sync_ms: restored_at_ms - last_sync_age_ms,
         last_persist_ms: restored_at_ms - last_persist_age_ms,
         seq: snapshot.upstream_seq,
         tick_delay_ms: tick_delay_ms,
         checkpoint_fingerprint: learner.fingerprint
       }}
    else
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  def restore(_snapshot, _restored_at_ms, _restored_at_utc), do: @error

  @doc false
  def policy(state) when is_map(state) do
    project_policy(state)
  end

  def policy(_state), do: @error

  defp project_authority(%{boat_identifier: boat_identifier}) do
    authority = %{boat_identifier: boat_identifier}
    if validate_authority(authority) == :ok, do: {:ok, authority}, else: @error
  end

  defp project_authority(_state), do: @error

  defp project_policy(state) do
    gate = Map.take(state.gate, @gate_fields)

    policy = %{
      admission_hash: state.policy_hash,
      gate: gate,
      min_stw_mps: state.min_stw_mps,
      window_size: state.window_size,
      p: state.p,
      sample_ms: state.sample_ms,
      sync_ms: state.sync_ms,
      persist_ms: state.persist_ms,
      persistence_enabled: not is_nil(state.dir),
      bins: Map.take(state.bins, @bins_fields)
    }

    case validate_policy(policy) do
      {:ok, _gate, _bins} -> {:ok, policy}
      _ -> @error
    end
  rescue
    _ -> @error
  end

  defp validate_authority(authority) do
    with :ok <- Shared.exact_keys(authority, @authority_fields),
         :ok <- Snapshot.validate_authority(authority.boat_identifier) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_policy(policy) do
    with :ok <- Shared.exact_keys(policy, @policy_fields),
         true <- fixed_hash?(policy.admission_hash),
         {:ok, gate} <- validate_gate(policy.gate),
         true <- finite_between?(policy.min_stw_mps, 0.0, @max_speed_mps),
         true <-
           is_integer(policy.window_size) and policy.window_size > 0 and
             policy.window_size <= @max_window_size,
         true <- finite_between?(policy.p, 0.0, 1.0) and policy.p > 0.0 and policy.p < 1.0,
         true <- valid_interval?(policy.sample_ms),
         true <- valid_interval?(policy.sync_ms),
         true <- valid_interval?(policy.persist_ms),
         true <- is_boolean(policy.persistence_enabled),
         {:ok, bins} <- validate_bins(policy.bins),
         {:ok, expected_hash} <-
           Snapshot.policy_hash(gate, policy.min_stw_mps, policy.window_size, policy.p),
         true <- secure_equal?(expected_hash, policy.admission_hash) do
      {:ok, gate, bins}
    else
      _ -> @error
    end
  end

  defp validate_bins(bins) do
    with :ok <- Shared.exact_keys(bins, @bins_fields),
         true <- Shared.finite_positive?(bins.twa_width_deg),
         true <- Shared.finite_positive?(bins.tws_width_mps),
         true <- Shared.finite_positive?(bins.max_tws_mps),
         rebuilt <-
           Bins.new(
             twa_width_deg: bins.twa_width_deg,
             tws_width_mps: bins.tws_width_mps,
             max_tws_mps: bins.max_tws_mps
           ) do
      {:ok, rebuilt}
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  defp validate_gate(gate) do
    with :ok <- Shared.exact_keys(gate, @gate_fields),
         true <- ordered_band?(gate.angle_band_deg, 0.0, 180.0),
         true <- ordered_band?(gate.heel_band_deg, -180.0, 180.0),
         true <- finite_non_negative?(gate.max_tws_sd_mps),
         true <- finite_non_negative?(gate.max_turn_rate_dps),
         true <- finite_non_negative?(gate.max_accel_mps2),
         true <-
           is_integer(gate.min_dwell) and gate.min_dwell > 0 and
             gate.min_dwell <= @max_window_size,
         true <- finite_non_negative?(gate.engine_rpm_idle),
         true <- gate.angle_key in [:twa_deg, :awa_deg] do
      {:ok, struct!(Gate, gate)}
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  defp project_window(window, captured_at_ms, window_size)
       when is_list(window) and is_integer(window_size) and window_size >= 0 do
    with :ok <- Shared.bounded_list(window, window_size) do
      window
      |> Enum.reduce_while({:ok, []}, fn sample, {:ok, rows} ->
        with :ok <- validate_live_sample(sample),
             {:ok, age_ms} <- Shared.timestamp_age(sample.t_ms, captured_at_ms) do
          row = sample |> Map.delete(:t_ms) |> Map.put(:age_ms, age_ms)
          {:cont, {:ok, [row | rows]}}
        else
          _ -> {:halt, @error}
        end
      end)
      |> case do
        {:ok, rows} ->
          rows = Enum.reverse(rows)
          if oldest_first?(rows), do: {:ok, rows}, else: @error

        _ ->
          @error
      end
    else
      _ -> @error
    end
  end

  defp project_window(_window, _captured_at_ms, _window_size), do: @error

  defp validate_window(rows, window_size) do
    with :ok <- Shared.bounded_list(rows, window_size),
         true <- oldest_first?(rows),
         true <- Enum.all?(rows, &valid_window_row?/1) do
      :ok
    else
      _ -> :error
    end
  end

  defp restore_window(rows, restored_at_ms, elapsed_ms) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, samples} ->
      with {:ok, effective_age_ms} <- Shared.add_elapsed(row.age_ms, elapsed_ms) do
        sample = row |> Map.delete(:age_ms) |> Map.put(:t_ms, restored_at_ms - effective_age_ms)
        {:cont, {:ok, [sample | samples]}}
      else
        _ -> {:halt, @error}
      end
    end)
    |> case do
      {:ok, samples} -> {:ok, Enum.reverse(samples)}
      _ -> @error
    end
  end

  defp validate_live_sample(sample) do
    expected = [:t_ms | Enum.reject(@window_fields, &(&1 == :age_ms))]

    with :ok <- Shared.exact_keys(sample, expected),
         true <- is_integer(sample.t_ms),
         true <- valid_sample_values?(sample) do
      :ok
    else
      _ -> :error
    end
  end

  defp valid_window_row?(row) do
    Shared.exact_keys(row, @window_fields) == :ok and
      match?({:ok, _}, Shared.validate_age(row.age_ms)) and valid_sample_values?(row)
  end

  defp valid_sample_values?(sample) do
    finite_between?(sample.tws_mps, 0.0, @max_speed_mps) and
      finite_between?(sample.twa_deg, -360.0, 360.0) and
      finite_between?(sample.stw_mps, 0.0, @max_speed_mps) and
      finite_or_nil_between?(sample.heading_deg, 0.0, 360.0) and
      finite_or_nil_between?(sample.heel_deg, -180.0, 180.0) and
      (is_nil(sample.under_power?) or is_boolean(sample.under_power?)) and
      finite_or_nil_between?(sample.engine_rpm, 0.0, @max_engine_rpm)
  end

  defp oldest_first?([]), do: true
  defp oldest_first?([_one]), do: true

  defp oldest_first?([older, newer | rest]) do
    is_integer(older.age_ms) and is_integer(newer.age_ms) and older.age_ms >= newer.age_ms and
      oldest_first?([newer | rest])
  rescue
    _ -> false
  end

  defp project_dirty_keys(keys, cells) do
    if match?(%MapSet{}, keys) and is_map(cells) do
      rows =
        keys
        |> MapSet.to_list()
        |> Enum.map(fn {tws_bin, twa_bin} -> %{tws_bin: tws_bin, twa_bin: twa_bin} end)
        |> Enum.sort_by(&{&1.tws_bin, &1.twa_bin})

      if Enum.all?(keys, &Map.has_key?(cells, &1)), do: {:ok, rows}, else: @error
    else
      @error
    end
  rescue
    _ -> @error
  end

  defp validate_phase(phase, fields), do: Shared.exact_keys(phase, fields)

  defp validate_dirty_keys(rows, cells, bins) do
    with :ok <- Shared.bounded_list(rows, map_size(cells)),
         true <- strictly_sorted_unique?(rows),
         true <-
           Enum.all?(rows, fn row ->
             key = {row.tws_bin, row.twa_bin}

             Shared.exact_keys(row, @key_fields) == :ok and Bins.valid_key?(bins, key) and
               Map.has_key?(cells, key)
           end) do
      :ok
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp strictly_sorted_unique?([]), do: true
  defp strictly_sorted_unique?([_one]), do: true

  defp strictly_sorted_unique?([left, right | rest]) do
    {left.tws_bin, left.twa_bin} < {right.tws_bin, right.twa_bin} and
      strictly_sorted_unique?([right | rest])
  rescue
    _ -> false
  end

  defp restore_dirty_keys(rows) do
    MapSet.new(rows, &{&1.tws_bin, &1.twa_bin})
  end

  defp project_cadence_age(last_ms, captured_at_ms, interval_ms)
       when is_integer(last_ms) and is_integer(captured_at_ms) and is_integer(interval_ms) and
              interval_ms >= 0 do
    age_ms = captured_at_ms - last_ms

    if age_ms >= 0,
      do: Shared.advance_capped_age(min(age_ms, interval_ms), 0, interval_ms),
      else: @error
  end

  defp project_cadence_age(_last_ms, _captured_at_ms, _interval_ms), do: @error

  defp validate_cadence_age(age_ms, interval_ms) do
    case Shared.advance_capped_age(age_ms, 0, interval_ms) do
      {:ok, ^age_ms} -> :ok
      _ -> :error
    end
  end

  defp advance_cadence_age(age_ms, elapsed_ms, interval_ms),
    do: Shared.advance_capped_age(age_ms, elapsed_ms, interval_ms)

  defp project_tick(%{sample_ms: 0}, _captured_at_ms), do: {:ok, %{remaining_ms: nil}}

  defp project_tick(state, captured_at_ms) do
    remaining_ms = state.next_tick_ms - captured_at_ms

    if is_integer(state.sample_ms) and state.sample_ms > 0 and is_integer(state.next_tick_ms) and
         remaining_ms <= state.sample_ms do
      {:ok, %{remaining_ms: max(remaining_ms, 0)}}
    else
      @error
    end
  rescue
    _ -> @error
  end

  defp validate_tick(tick, 0) do
    if Shared.exact_keys(tick, @tick_fields) == :ok and is_nil(tick.remaining_ms),
      do: :ok,
      else: :error
  end

  defp validate_tick(tick, sample_ms) do
    with :ok <- Shared.exact_keys(tick, @tick_fields),
         true <- is_integer(sample_ms) and sample_ms > 0,
         true <-
           is_integer(tick.remaining_ms) and tick.remaining_ms >= 0 and
             tick.remaining_ms <= sample_ms do
      :ok
    else
      _ -> :error
    end
  end

  defp restore_tick(%{remaining_ms: nil}, 0, _elapsed_ms), do: {:ok, nil}

  defp restore_tick(tick, sample_ms, elapsed_ms) do
    with :ok <- validate_tick(tick, sample_ms) do
      {:ok, max(tick.remaining_ms - elapsed_ms, 0)}
    else
      _ -> @error
    end
  end

  defp valid_interval?(value),
    do: is_integer(value) and value >= 0 and value <= Shared.max_age_ms()

  defp ordered_band?({lower, upper}, minimum, maximum),
    do: finite_between?(lower, minimum, maximum) and finite_between?(upper, minimum, maximum) and lower <= upper

  defp ordered_band?(_band, _minimum, _maximum), do: false

  defp fixed_hash?(value), do: is_binary(value) and byte_size(value) == 32

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false

  defp database_int?(value),
    do: is_integer(value) and value >= 0 and value <= @database_int_max

  defp finite_non_negative?(value), do: Shared.finite_non_negative?(value)

  defp finite_between?(value, minimum, maximum),
    do: Shared.finite_number?(value) and value >= minimum and value <= maximum and abs_number?(value)

  defp finite_or_nil_between?(nil, _minimum, _maximum), do: true
  defp finite_or_nil_between?(value, minimum, maximum), do: finite_between?(value, minimum, maximum)

  defp abs_number?(value) when is_integer(value), do: value >= -@max_finite and value <= @max_finite
  defp abs_number?(value) when is_float(value), do: true
  defp abs_number?(_value), do: false
end
