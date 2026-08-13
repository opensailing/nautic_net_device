defmodule RacingOrg.Tracker.Pro.WindShift.Observer.Snapshot do
  @moduledoc """
  Closed, versioned Wind Shift runtime boundary.

  The envelope binds the complete learner/runtime to its exact durable device
  authority, effective policy, monotonic source generation, UTC capture anchor,
  statistics, and sampling-timer phase. Monotonic timestamps are represented as
  bounded ages and advanced by powered-off wall time before rebasing at restore.
  Semantic validity is deliberately independent from current control-frame
  capacity so a valid runtime remains suitable for future chunked carriage.
  """

  alias RacingOrg.Tracker.Pro.RuntimeSnapshot
  alias RacingOrg.Tracker.Pro.WindShift.Checkpoint

  @top_fields [
    :authority,
    :captured_at_utc_ms,
    :policy,
    :runtime,
    :source_generation,
    :stats,
    :tick,
    :version
  ]
  @authority_fields [:credential_epoch, :device_id, :storage_epoch]
  @policy_fields [
    :absorb_dwell_ticks,
    :alarms,
    :broadcast_rate_ms,
    :period_every_ms,
    :persist_ms,
    :residual_window,
    :sample_ms,
    :staleness_ms,
    :sync_ms,
    :timeline_ms,
    :version,
    :wally_mode,
    :windows,
    :xing_hysteresis_deg
  ]
  @window_fields [:envelope_s, :fast_s, :mid_s, :slow_s]
  @alarm_fields [:enabled, :new_extreme_margin_deg]
  @stats_fields [:accepted, :reject_reasons, :rejected, :samples]
  @tick_fields [:remaining_ms]
  @reject_reasons [:no_twd, :stale_twd]
  @wally_modes ~w(off shadow on)
  @u32_max 0xFFFF_FFFF
  @u64_max 0xFFFF_FFFF_FFFF_FFFF
  @database_int_max 9_223_372_036_854_775_807
  @max_finite 1.7976931348623157e308
  @max_pending 65_535
  @max_envelope_entries 100_000
  @max_residuals 1_800
  @max_projected_nodes 2_000_000
  @max_projected_canonical_size 8_388_608
  @max_canonical_depth 16
  @max_canonical_key_size 128
  @max_canonical_collection_count 65_535
  @canonical_chunk_size 65_535
  @xing_hysteresis_deg 2.0
  @error {:error, :invalid_wind_shift_runtime_snapshot}

  @type t :: %{
          authority: %{device_id: <<_::128>>, credential_epoch: non_neg_integer(), storage_epoch: <<_::128>>},
          captured_at_utc_ms: non_neg_integer(),
          policy: map(),
          runtime: map(),
          source_generation: non_neg_integer(),
          stats: map(),
          tick: %{remaining_ms: non_neg_integer() | nil},
          version: pos_integer()
        }

  @doc "Project a live Observer state into the exact runtime envelope."
  @spec project(map(), integer(), DateTime.t() | non_neg_integer()) :: {:ok, t()} | {:error, atom()}
  def project(state, captured_at_ms, captured_at_utc)
      when is_map(state) and is_integer(captured_at_ms) do
    with {:ok, captured_at_utc_ms} <- RuntimeSnapshot.utc_ms(captured_at_utc),
         {:ok, authority} <- authority(state),
         {:ok, policy} <- policy(state),
         {:ok, runtime} <- Checkpoint.snapshot_runtime(state, captured_at_ms),
         :ok <- validate_generation(state.source_generation),
         :ok <- validate_stats(state.stats),
         {:ok, tick} <- project_tick(state, captured_at_ms) do
      snapshot = %{
        version: RuntimeSnapshot.version(),
        captured_at_utc_ms: captured_at_utc_ms,
        authority: authority,
        policy: policy,
        source_generation: state.source_generation,
        runtime: runtime,
        stats: state.stats,
        tick: tick
      }

      with :ok <- preflight(snapshot),
           {:ok, _restored} <- restore(snapshot, captured_at_ms, captured_at_utc_ms) do
        {:ok, snapshot}
      else
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

  @doc "Cheap exact-shape preflight before digesting or hydrating the learner."
  @spec preflight(term()) :: :ok | {:error, :invalid_wind_shift_runtime_snapshot}
  def preflight(snapshot) do
    with :ok <- RuntimeSnapshot.exact_keys(snapshot, @top_fields),
         true <- snapshot.version == RuntimeSnapshot.version(),
         {:ok, _captured_at_utc_ms} <- RuntimeSnapshot.utc_ms(snapshot.captured_at_utc_ms),
         :ok <- validate_authority(snapshot.authority),
         :ok <- validate_policy(snapshot.policy),
         :ok <- validate_generation(snapshot.source_generation),
         :ok <- validate_stats(snapshot.stats),
         :ok <- validate_tick(snapshot.tick, snapshot.policy.sample_ms),
         :ok <- validate_projected_budget(snapshot),
         :ok <- preflight_runtime_collections(snapshot.runtime),
         :ok <- validate_projectable_tree(snapshot) do
      :ok
    else
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  @doc "Return the deterministic SHA-256 identity of an exact envelope."
  @spec digest(term()) :: {:ok, <<_::256>>} | {:error, :invalid_wind_shift_runtime_snapshot}
  def digest(snapshot) do
    with :ok <- preflight(snapshot) do
      {:ok, :crypto.hash(:sha256, :erlang.term_to_binary(snapshot, [:deterministic]))}
    else
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  @doc "Validate, advance powered-off ages, and rebase the complete runtime."
  @spec restore(term(), integer(), DateTime.t() | non_neg_integer()) ::
          {:ok, map()} | {:error, :invalid_wind_shift_runtime_snapshot}
  def restore(snapshot, restored_at_ms, restored_at_utc)
      when is_map(snapshot) and is_integer(restored_at_ms) do
    with :ok <- preflight(snapshot),
         {:ok, restored_at_utc_ms} <- RuntimeSnapshot.utc_ms(restored_at_utc),
         {:ok, elapsed_ms} <-
           RuntimeSnapshot.elapsed_wall_ms(snapshot.captured_at_utc_ms, restored_at_utc_ms),
         {:ok, advanced_runtime} <- Checkpoint.advance_runtime(snapshot.runtime, elapsed_ms),
         {:ok, runtime} <- Checkpoint.restore_runtime(advanced_runtime, restored_at_ms, restored_at_utc_ms),
         {:ok, tick_delay_ms} <- restore_tick(snapshot.tick, snapshot.policy.sample_ms, elapsed_ms) do
      {:ok,
       %{
         runtime: runtime,
         source_generation: snapshot.source_generation,
         stats: snapshot.stats,
         tick_delay_ms: tick_delay_ms
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
  def authority(%{authority_fn: authority_fn}) when is_function(authority_fn, 0) do
    with {:ok, identity} <- authority_fn.(),
         authority = Map.take(identity, @authority_fields),
         :ok <- validate_authority(authority) do
      {:ok, authority}
    else
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  def authority(_state), do: @error

  @doc false
  def policy(state) when is_map(state) do
    policy = %{
      version: state.policy_version,
      windows: state.windows,
      alarms: state.alarms,
      wally_mode: state.wally_mode,
      sample_ms: state.sample_ms,
      persist_ms: state.persist_ms,
      sync_ms: state.sync_ms,
      timeline_ms: state.timeline_ms,
      staleness_ms: state.staleness_ms,
      residual_window: state.residual_window,
      period_every_ms: state.period_every_ms,
      xing_hysteresis_deg: state.xing_hysteresis_deg,
      absorb_dwell_ticks: state.absorb_dwell_ticks,
      broadcast_rate_ms: state.broadcast_rate_ms
    }

    if validate_policy(policy) == :ok, do: {:ok, policy}, else: @error
  rescue
    _ -> @error
  end

  def policy(_state), do: @error

  defp validate_authority(authority) do
    with :ok <- RuntimeSnapshot.exact_keys(authority, @authority_fields),
         true <- is_binary(authority.device_id) and byte_size(authority.device_id) == 16,
         true <-
           is_integer(authority.credential_epoch) and authority.credential_epoch >= 0 and
             authority.credential_epoch <= @u32_max,
         true <- is_binary(authority.storage_epoch) and byte_size(authority.storage_epoch) == 16,
         true <- authority.storage_epoch != <<0::128>> do
      :ok
    else
      _ -> @error
    end
  end

  defp validate_policy(policy) do
    with :ok <- RuntimeSnapshot.exact_keys(policy, @policy_fields),
         true <- is_nil(policy.version) or valid_generation?(policy.version),
         :ok <- RuntimeSnapshot.exact_keys(policy.windows, @window_fields),
         true <- Enum.all?(@window_fields, &RuntimeSnapshot.finite_positive?(Map.fetch!(policy.windows, &1))),
         :ok <- RuntimeSnapshot.exact_keys(policy.alarms, @alarm_fields),
         true <- is_boolean(policy.alarms.enabled),
         true <- RuntimeSnapshot.finite_non_negative?(policy.alarms.new_extreme_margin_deg),
         true <- policy.wally_mode in @wally_modes,
         true <- nonnegative_integer?(policy.sample_ms),
         true <- nonnegative_integer?(policy.persist_ms),
         true <- nonnegative_integer?(policy.sync_ms),
         true <- nonnegative_integer?(policy.timeline_ms),
         true <- nonnegative_integer?(policy.staleness_ms),
         true <- positive_integer?(policy.residual_window),
         true <- positive_integer?(policy.period_every_ms),
         true <- policy.xing_hysteresis_deg === @xing_hysteresis_deg,
         true <- positive_integer?(policy.absorb_dwell_ticks),
         true <- positive_integer?(policy.broadcast_rate_ms) do
      :ok
    else
      _ -> @error
    end
  end

  defp validate_generation(value), do: if(valid_generation?(value), do: :ok, else: @error)

  defp valid_generation?(value),
    do: is_integer(value) and value >= 0 and value <= @database_int_max

  defp validate_stats(stats) do
    with :ok <- RuntimeSnapshot.exact_keys(stats, @stats_fields),
         true <- Enum.all?([stats.samples, stats.accepted, stats.rejected], &valid_generation?/1),
         true <- stats.accepted + stats.rejected == stats.samples,
         true <- is_map(stats.reject_reasons) and not is_struct(stats.reject_reasons),
         true <-
           Enum.all?(stats.reject_reasons, fn {reason, count} ->
             reason in @reject_reasons and valid_generation?(count) and count > 0
           end),
         true <- Enum.sum(Map.values(stats.reject_reasons)) == stats.rejected do
      :ok
    else
      _ -> @error
    end
  end

  defp project_tick(%{sample_ms: 0}, _captured_at_ms), do: {:ok, %{remaining_ms: nil}}

  defp project_tick(%{sample_ms: sample_ms, next_tick_ms: next_tick_ms}, captured_at_ms)
       when is_integer(sample_ms) and sample_ms > 0 and is_integer(next_tick_ms) do
    remaining_ms = next_tick_ms - captured_at_ms

    if remaining_ms <= sample_ms do
      {:ok, %{remaining_ms: max(remaining_ms, 0)}}
    else
      @error
    end
  end

  defp project_tick(_state, _captured_at_ms), do: @error

  defp validate_tick(tick, 0) do
    with :ok <- RuntimeSnapshot.exact_keys(tick, @tick_fields),
         true <- is_nil(tick.remaining_ms) do
      :ok
    else
      _ -> @error
    end
  end

  defp validate_tick(tick, sample_ms) when is_integer(sample_ms) and sample_ms > 0 do
    with :ok <- RuntimeSnapshot.exact_keys(tick, @tick_fields),
         true <-
           is_integer(tick.remaining_ms) and tick.remaining_ms >= 0 and
             tick.remaining_ms <= sample_ms do
      :ok
    else
      _ -> @error
    end
  end

  defp validate_tick(_tick, _sample_ms), do: @error

  defp restore_tick(%{remaining_ms: nil}, 0, _elapsed_ms), do: {:ok, nil}

  defp restore_tick(%{remaining_ms: remaining_ms}, sample_ms, elapsed_ms)
       when is_integer(sample_ms) and sample_ms > 0 do
    {:ok, max(remaining_ms - elapsed_ms, 0)}
  end

  defp restore_tick(_tick, _sample_ms, _elapsed_ms), do: @error

  defp preflight_runtime_collections(runtime) when is_map(runtime) do
    with :ok <- RuntimeSnapshot.bounded_list(Map.get(runtime, :pending_timeline), @max_pending),
         :ok <- RuntimeSnapshot.bounded_list(Map.get(runtime, :pending_events), @max_pending),
         :ok <- RuntimeSnapshot.bounded_list(get_in(runtime, [:envelope, :minq]), @max_envelope_entries),
         :ok <- RuntimeSnapshot.bounded_list(get_in(runtime, [:envelope, :maxq]), @max_envelope_entries),
         :ok <- RuntimeSnapshot.bounded_list(get_in(runtime, [:residuals, :values]), @max_residuals),
         true <- strictly_increasing_timestamps?(runtime.pending_timeline),
         true <- unique_terms?(runtime.pending_events) do
      :ok
    else
      _ -> @error
    end
  end

  defp preflight_runtime_collections(_runtime), do: @error

  defp strictly_increasing_timestamps?([]), do: true

  defp strictly_increasing_timestamps?([%{t_ms: t_ms} | rest]) when is_integer(t_ms),
    do: strictly_increasing_timestamps?(rest, t_ms)

  defp strictly_increasing_timestamps?(_rows), do: false

  defp strictly_increasing_timestamps?([], _previous), do: true

  defp strictly_increasing_timestamps?([%{t_ms: t_ms} | rest], previous)
       when is_integer(t_ms) and t_ms > previous,
       do: strictly_increasing_timestamps?(rest, t_ms)

  defp strictly_increasing_timestamps?(_rows, _previous), do: false

  defp unique_terms?(values) when is_list(values) do
    encoded = Enum.map(values, &:erlang.term_to_binary(&1, [:deterministic]))
    length(encoded) == MapSet.size(MapSet.new(encoded))
  rescue
    _ -> false
  end

  defp unique_terms?(_values), do: false

  defp validate_projected_budget(snapshot) do
    case projected_size(snapshot, [], 0, @max_projected_nodes) do
      {:ok, size, _remaining_nodes} when size <= @max_projected_canonical_size -> :ok
      _ -> @error
    end
  end

  defp projected_size(_value, _path, _depth, node_budget) when node_budget <= 0, do: :error

  defp projected_size(value, [queue, :envelope, :runtime], depth, node_budget)
       when queue in [:minq, :maxq] and is_list(value) do
    with true <- depth + 3 < @max_canonical_depth,
         {:ok, rows_size, count, remaining_nodes} <-
           projected_queue_rows(value, depth + 3, node_budget - 4, 0, 0),
         chunks = div(count + @canonical_chunk_size - 1, @canonical_chunk_size),
         true <- chunks <= @max_canonical_collection_count do
      wrapper_size =
        5 +
          (2 + byte_size("count")) + 9 +
          (2 + byte_size("chunks")) + 5 + chunks * 5

      {:ok, wrapper_size + rows_size, remaining_nodes}
    else
      _ -> :error
    end
  end

  defp projected_size(value, [field, :authority], _depth, node_budget)
       when field in [:device_id, :storage_epoch] and is_binary(value) do
    if byte_size(value) + 5 <= @max_projected_canonical_size,
      do: {:ok, byte_size(value) + 5, node_budget - 1},
      else: :error
  end

  defp projected_size(value, path, depth, node_budget)
       when is_map(value) and not is_struct(value) do
    with true <- depth < @max_canonical_depth,
         true <- map_size(value) <= @max_canonical_collection_count,
         {:ok, entries} <- projected_map_entries(value),
         {:ok, entries_size, remaining_nodes} <-
           projected_map_size(entries, path, depth + 1, node_budget - 1, 0) do
      {:ok, 5 + entries_size, remaining_nodes}
    else
      _ -> :error
    end
  end

  defp projected_size(value, path, depth, node_budget) when is_list(value) do
    with true <- depth < @max_canonical_depth,
         {:ok, entries_size, _count, remaining_nodes} <-
           projected_list_size(value, path, depth + 1, node_budget - 1, 0, 0) do
      {:ok, 5 + entries_size, remaining_nodes}
    else
      _ -> :error
    end
  end

  defp projected_size(value, _path, _depth, node_budget)
       when is_integer(value) or is_float(value),
       do: {:ok, 9, node_budget - 1}

  defp projected_size(value, _path, _depth, node_budget) when is_boolean(value) or is_nil(value),
    do: {:ok, 1, node_budget - 1}

  defp projected_size(value, _path, _depth, node_budget) when is_atom(value),
    do: projected_text_size(Atom.to_string(value), node_budget)

  defp projected_size(value, _path, _depth, node_budget) when is_binary(value),
    do: projected_text_size(value, node_budget)

  defp projected_size(_value, _path, _depth, _node_budget), do: :error

  defp projected_queue_rows([], _depth, node_budget, size, count),
    do: {:ok, size, count, node_budget}

  defp projected_queue_rows([entry | rest], depth, node_budget, size, count)
       when count < @max_envelope_entries and node_budget > 2 do
    with :ok <- RuntimeSnapshot.exact_keys(entry, [:age_ms, :value]),
         {:ok, age_size, after_age} <- projected_size(entry.age_ms, [], depth, node_budget - 1),
         {:ok, value_size, after_value} <- projected_size(entry.value, [], depth, after_age) do
      projected_queue_rows(rest, depth, after_value, size + 5 + age_size + value_size, count + 1)
    else
      _ -> :error
    end
  end

  defp projected_queue_rows(_value, _depth, _node_budget, _size, _count), do: :error

  defp projected_map_entries(value) do
    value
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {key, nested}, {:ok, entries, keys} ->
      case projected_key(key) do
        {:ok, normalized} ->
          if MapSet.member?(keys, normalized) do
            {:halt, :error}
          else
            {:cont, {:ok, [{normalized, key, nested} | entries], MapSet.put(keys, normalized)}}
          end

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, entries, _keys} -> {:ok, entries}
      _ -> :error
    end
  end

  defp projected_map_size([], _path, _depth, node_budget, size),
    do: {:ok, size, node_budget}

  defp projected_map_size(
         [{normalized, key, nested} | rest],
         path,
         depth,
         node_budget,
         size
       ) do
    with {:ok, nested_size, remaining_nodes} <-
           projected_size(nested, [key | path], depth, node_budget) do
      projected_map_size(
        rest,
        path,
        depth,
        remaining_nodes,
        size + 2 + byte_size(normalized) + nested_size
      )
    else
      _ -> :error
    end
  end

  defp projected_list_size([], _path, _depth, node_budget, size, count),
    do: {:ok, size, count, node_budget}

  defp projected_list_size([entry | rest], path, depth, node_budget, size, count)
       when count < @max_canonical_collection_count do
    with {:ok, entry_size, remaining_nodes} <- projected_size(entry, path, depth, node_budget) do
      projected_list_size(rest, path, depth, remaining_nodes, size + entry_size, count + 1)
    else
      _ -> :error
    end
  end

  defp projected_list_size(_value, _path, _depth, _node_budget, _size, _count), do: :error

  defp projected_key(key) when is_atom(key), do: key |> Atom.to_string() |> projected_key()

  defp projected_key(key) when is_binary(key) and byte_size(key) <= @max_canonical_key_size do
    if String.valid?(key) do
      normalized = String.normalize(key, :nfc)

      if byte_size(normalized) <= @max_canonical_key_size,
        do: {:ok, normalized},
        else: :error
    else
      :error
    end
  end

  defp projected_key(_key), do: :error

  defp projected_text_size(value, node_budget) do
    if byte_size(value) + 5 <= @max_projected_canonical_size and String.valid?(value) do
      normalized = String.normalize(value, :nfc)
      size = byte_size(normalized) + 5

      if size <= @max_projected_canonical_size,
        do: {:ok, size, node_budget - 1},
        else: :error
    else
      :error
    end
  end

  defp validate_projectable_tree(value) when is_map(value) and not is_struct(value) do
    with :ok <- reject_alias_keys(value) do
      Enum.reduce_while(value, :ok, fn {_key, nested}, :ok ->
        case validate_projectable_tree(nested) do
          :ok -> {:cont, :ok}
          _ -> {:halt, @error}
        end
      end)
    end
  end

  defp validate_projectable_tree(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn nested, :ok ->
      case validate_projectable_tree(nested) do
        :ok -> {:cont, :ok}
        _ -> {:halt, @error}
      end
    end)
  end

  defp validate_projectable_tree(value) when is_integer(value) and value >= 0 and value <= @u64_max,
    do: :ok

  defp validate_projectable_tree(value) when is_integer(value), do: @error

  defp validate_projectable_tree(value) when is_float(value) do
    <<bits::unsigned-big-integer-size(64)>> = <<value::float-big-size(64)>>

    if value == value and value >= -@max_finite and value <= @max_finite and
         bits != 0x8000_0000_0000_0000,
       do: :ok,
       else: @error
  end

  defp validate_projectable_tree(value)
       when is_binary(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp validate_projectable_tree(value)
       when value in [
              :none,
              :high,
              :low,
              :candidate,
              :confirmed,
              :up,
              :down,
              :pos,
              :neg,
              :insufficient_history,
              :calm,
              :oscillating,
              :persistent_ramp,
              :persistent_step,
              :mixed,
              :no_twd,
              :stale_twd
            ],
       do: :ok

  defp validate_projectable_tree(_value), do: @error

  defp reject_alias_keys(value) do
    normalized =
      Enum.map(Map.keys(value), fn
        key when is_atom(key) -> Atom.to_string(key)
        key when is_binary(key) -> key
        _key -> :invalid
      end)

    if :invalid not in normalized and length(normalized) == MapSet.size(MapSet.new(normalized)),
      do: :ok,
      else: @error
  end

  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0 and value <= @database_int_max
  defp positive_integer?(value), do: nonnegative_integer?(value) and value > 0
end
