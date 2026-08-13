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
  @database_int_max 9_223_372_036_854_775_807
  @max_snapshot_bytes 8_388_608
  @max_pending 65_535
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
         :ok <- preflight_runtime_collections(snapshot.runtime),
         true <- safe_term_size(snapshot) <= @max_snapshot_bytes do
      :ok
    else
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  @doc "Return the bounded deterministic SHA-256 identity of an exact envelope."
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
         true <- RuntimeSnapshot.finite_positive?(policy.xing_hysteresis_deg),
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

  defp safe_term_size(value), do: value |> :erlang.term_to_binary([:deterministic]) |> byte_size()
  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0 and value <= @database_int_max
  defp positive_integer?(value), do: nonnegative_integer?(value) and value > 0
end
