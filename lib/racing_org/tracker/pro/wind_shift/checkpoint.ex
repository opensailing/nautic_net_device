defmodule RacingOrg.Tracker.Pro.WindShift.Checkpoint do
  @moduledoc """
  Pure validation and projection for wind-shift state.

  `project/1` and `hydrate/1` preserve the existing closed checkpoint-v1 wire
  content unchanged. `snapshot_runtime/2` and `restore_runtime/2` define a
  separate closed, atom-keyed INTERNAL Observer state shape for exact learner
  continuation. The internal shape is not a wire codec and deliberately excludes
  collaborators, functions, credentials, and open metadata.
  """

  alias RacingOrg.Tracker.Pro.RuntimeSnapshot
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint, as: ContractCheckpoint

  alias RacingOrg.Tracker.Pro.WindShift.{Cycle, Envelope, Means, StepDetect}

  @kind :wind_shift
  @schema_version 1
  @invalid_runtime {:error, :invalid_wind_shift_runtime_snapshot}
  @max_finite 1.7976931348623157e308
  @max_residuals 1_800
  @max_envelope_entries 100_000
  @ms_per_utc_day 86_400_000
  @xing_hysteresis_deg 2.0

  @snapshot_keys [:last_summary, :pending_events, :pending_timeline, :seq, :session]
  @content_keys ~w(last_summary pending_events pending_timeline seq session)

  @runtime_keys [
    :absorb_count,
    :cycle,
    :envelope,
    :last_lift,
    :last_period_age_ms,
    :last_persist_age_ms,
    :last_summary,
    :last_sync_age_ms,
    :last_t_age_ms,
    :last_tack,
    :last_timeline_age_ms,
    :last_tx_age_ms,
    :last_verdict,
    :means,
    :pending_events,
    :pending_timeline,
    :period,
    :prev_regime,
    :prev_step_status,
    :residuals,
    :seq,
    :session,
    :step,
    :t0_age_ms,
    :unwrap,
    :xing
  ]

  @regimes [:insufficient_history, :calm, :oscillating, :persistent_ramp, :persistent_step, :mixed]

  @session_fields [
    {:started_at_ms, "started_at_ms"},
    {:lat_sum, "lat_sum"},
    {:lon_sum, "lon_sum"},
    {:pos_n, "pos_n"},
    {:tws_sum, "tws_sum"},
    {:tws_n, "tws_n"}
  ]

  @timeline_fields [
    {:t_ms, "t_ms"},
    {:mean_twd_deg, "mean_twd_deg"},
    {:phase_deg, "phase_deg"},
    {:amplitude_deg, "amplitude_deg"},
    {:period_s, "period_s"},
    {:trend_deg_per_hr, "trend_deg_per_hr"},
    {:tws_mps, "tws_mps"}
  ]

  @event_fields [
    {:t_ms, "t_ms"},
    {:kind, "kind"},
    {:twd_deg, "twd_deg"},
    {:magnitude_deg, "magnitude_deg"},
    {:detail, "detail"}
  ]

  @summary_fields [
    {:mean_twd_deg, "mean_twd_deg"},
    {:trend_deg_per_hr, "trend_deg_per_hr"},
    {:oscillation_period_s, "oscillation_period_s"},
    {:oscillation_amplitude_deg, "oscillation_amplitude_deg"},
    {:regime, "regime"},
    {:tws_mean_mps, "tws_mean_mps"}
  ]

  @step_detail [{:onset_t_ms, "onset_t_ms"}]
  @extreme_detail [{:min_deg, "min_deg"}, {:max_deg, "max_deg"}]
  @regime_detail [{:from, "from"}, {:to, "to"}, {:confidence, "confidence"}]
  @phase_detail [{:phase_deg, "phase_deg"}]

  @type snapshot :: map()
  @type content :: map()

  @doc "Project one exact Observer.Store snapshot into validated checkpoint-v1 content."
  @spec project(snapshot()) :: {:ok, content()} | {:error, :invalid_wind_shift_snapshot}
  def project(snapshot) do
    with {:ok, content} <- project_snapshot(snapshot),
         {:ok, _bytes} <- ContractCheckpoint.canonical_content(@kind, @schema_version, content) do
      {:ok, content}
    else
      _ -> {:error, :invalid_wind_shift_snapshot}
    end
  end

  @doc "Hydrate validated checkpoint-v1 content into the exact Observer.Store snapshot shape."
  @spec hydrate(content()) :: {:ok, snapshot()} | {:error, term()}
  def hydrate(content) do
    with {:ok, bytes} <- ContractCheckpoint.canonical_content(@kind, @schema_version, content),
         {:ok, canonical_content} <- Canonical.decode(bytes),
         {:ok, canonical_bytes} <- ContractCheckpoint.canonical_content(@kind, @schema_version, canonical_content),
         true <- canonical_bytes == bytes,
         {:ok, snapshot} <- hydrate_content(canonical_content) do
      {:ok, snapshot}
    end
  end

  @doc "Project the complete Observer learner state into the closed internal runtime shape."
  @spec snapshot_runtime(map(), integer()) :: {:ok, map()} | {:error, :invalid_wind_shift_runtime_snapshot}
  def snapshot_runtime(state, now_ms) when is_map(state) and is_integer(now_ms) do
    store_snapshot = Map.take(state, @snapshot_keys)

    with {:ok, content} <- project(store_snapshot),
         {:ok, canonical_store} <- hydrate(content),
         {:ok, means} <- project_means(Map.get(state, :means), now_ms),
         {:ok, envelope} <- project_envelope(Map.get(state, :envelope), now_ms),
         {:ok, cycle} <- project_cycle(Map.get(state, :cycle)),
         {:ok, step} <- project_step(Map.get(state, :step), Map.get(state, :step_clock), now_ms),
         {:ok, last_period_age_ms} <- project_age(Map.get(state, :last_period_ms), now_ms),
         {:ok, last_persist_age_ms} <- project_age(Map.get(state, :last_persist_ms), now_ms),
         {:ok, last_sync_age_ms} <- project_age(Map.get(state, :last_sync_ms), now_ms),
         {:ok, last_timeline_age_ms} <- project_age(Map.get(state, :last_timeline_ms), now_ms),
         {:ok, last_tx_age_ms} <- project_age(Map.get(state, :last_tx_ms), now_ms),
         {:ok, t0_age_ms} <- project_age(Map.get(state, :t0_ms), now_ms),
         {:ok, last_t_age_ms} <- project_age(Map.get(state, :last_t_ms), now_ms),
         {:ok, residuals} <- project_residuals(Map.get(state, :resid)) do
      runtime =
        canonical_store
        |> Map.merge(%{
          means: means,
          envelope: envelope,
          cycle: cycle,
          step: step,
          unwrap: project_unwrap(Map.get(state, :unwrap)),
          residuals: residuals,
          period: Map.get(state, :period),
          last_period_age_ms: last_period_age_ms,
          last_persist_age_ms: last_persist_age_ms,
          last_sync_age_ms: last_sync_age_ms,
          last_timeline_age_ms: last_timeline_age_ms,
          last_tx_age_ms: last_tx_age_ms,
          t0_age_ms: t0_age_ms,
          last_t_age_ms: last_t_age_ms,
          prev_step_status: Map.get(state, :prev_step_status),
          prev_regime: Map.get(state, :prev_regime),
          absorb_count: Map.get(state, :absorb_count),
          last_tack: Map.get(state, :last_tack),
          xing: project_xing(Map.get(state, :xing)),
          last_verdict: Map.get(state, :last_verdict),
          last_lift: Map.get(state, :last_lift)
        })

      case restore_runtime(runtime, now_ms) do
        {:ok, _validated} -> {:ok, runtime}
        @invalid_runtime -> @invalid_runtime
      end
    else
      _ -> @invalid_runtime
    end
  rescue
    _ -> @invalid_runtime
  catch
    _, _ -> @invalid_runtime
  end

  def snapshot_runtime(_state, _now_ms), do: @invalid_runtime

  @doc "Validate and hydrate one complete internal runtime snapshot without side effects."
  @spec restore_runtime(map(), integer()) :: {:ok, map()} | {:error, :invalid_wind_shift_runtime_snapshot}
  def restore_runtime(snapshot, now_ms), do: restore_runtime(snapshot, now_ms, nil)

  @spec restore_runtime(map(), integer(), integer() | nil) ::
          {:ok, map()} | {:error, :invalid_wind_shift_runtime_snapshot}
  def restore_runtime(snapshot, now_ms, current_utc_ms)
      when is_map(snapshot) and is_integer(now_ms) and (is_integer(current_utc_ms) or is_nil(current_utc_ms)) do
    store_snapshot = Map.take(snapshot, @snapshot_keys)

    with :ok <- exact_keys(snapshot, @runtime_keys),
         {:ok, content} <- project(store_snapshot),
         {:ok, canonical_store} <- hydrate(content),
         {:ok, means} <- restore_means(snapshot.means, now_ms),
         {:ok, envelope} <- restore_envelope(snapshot.envelope, now_ms),
         {:ok, cycle} <- restore_cycle(snapshot.cycle),
         {:ok, step, step_clock} <- restore_step(snapshot.step, now_ms, canonical_store.session),
         {:ok, unwrap} <- restore_unwrap(snapshot.unwrap),
         {:ok, resid} <- restore_residuals(snapshot.residuals),
         {:ok, period} <- restore_period(snapshot.period),
         {:ok, last_period_ms} <- restore_age(snapshot.last_period_age_ms, now_ms),
         :ok <- nonnegative_integer(snapshot.last_persist_age_ms),
         :ok <- nonnegative_integer(snapshot.last_sync_age_ms),
         :ok <- nonnegative_integer(snapshot.last_timeline_age_ms),
         {:ok, last_persist_ms} <- restore_age(snapshot.last_persist_age_ms, now_ms),
         {:ok, last_sync_ms} <- restore_age(snapshot.last_sync_age_ms, now_ms),
         {:ok, last_timeline_ms} <- restore_age(snapshot.last_timeline_age_ms, now_ms),
         {:ok, last_tx_ms} <- restore_age(snapshot.last_tx_age_ms, now_ms),
         {:ok, t0_ms} <- restore_age(snapshot.t0_age_ms, now_ms),
         {:ok, last_t_ms} <- restore_age(snapshot.last_t_age_ms, now_ms),
         :ok <- validate_prev_step_status(snapshot.prev_step_status),
         :ok <- validate_prev_regime(snapshot.prev_regime),
         :ok <- nonnegative_integer(snapshot.absorb_count),
         :ok <- ensure(snapshot.absorb_count < 60),
         :ok <- validate_tack(snapshot.last_tack),
         {:ok, xing} <- restore_xing(snapshot.xing, canonical_store.session, current_utc_ms),
         {:ok, last_verdict} <- restore_verdict(snapshot.last_verdict),
         :ok <- nullable_finite_float(snapshot.last_lift),
         :ok <- validate_not_future(canonical_store, step_clock, current_utc_ms),
         :ok <- validate_runtime_relations(snapshot, means, envelope, cycle, step, last_t_ms) do
      {:ok,
       canonical_store
       |> Map.merge(%{
         means: means,
         envelope: envelope,
         cycle: cycle,
         step: step,
         step_clock: step_clock,
         unwrap: unwrap,
         resid: resid,
         period: period,
         last_period_ms: last_period_ms,
         last_persist_ms: last_persist_ms,
         last_sync_ms: last_sync_ms,
         last_timeline_ms: last_timeline_ms,
         last_tx_ms: last_tx_ms,
         t0_ms: t0_ms,
         last_t_ms: last_t_ms,
         prev_step_status: snapshot.prev_step_status,
         prev_regime: snapshot.prev_regime,
         absorb_count: snapshot.absorb_count,
         last_tack: snapshot.last_tack,
         xing: xing,
         last_verdict: last_verdict,
         last_lift: snapshot.last_lift
       })}
    else
      _ -> @invalid_runtime
    end
  rescue
    _ -> @invalid_runtime
  catch
    _, _ -> @invalid_runtime
  end

  def restore_runtime(_snapshot, _now_ms, _current_utc_ms), do: @invalid_runtime

  @doc false
  @spec advance_runtime(map(), non_neg_integer()) ::
          {:ok, map()} | {:error, :invalid_wind_shift_runtime_snapshot}
  def advance_runtime(snapshot, elapsed_ms)
      when is_map(snapshot) and is_integer(elapsed_ms) and elapsed_ms >= 0 do
    with :ok <- exact_keys(snapshot, @runtime_keys),
         {:ok, means} <- advance_means(snapshot.means, elapsed_ms),
         {:ok, envelope} <- advance_envelope(snapshot.envelope, elapsed_ms),
         {:ok, step} <- advance_step(snapshot.step, elapsed_ms),
         {:ok, last_period_age_ms} <- advance_age(snapshot.last_period_age_ms, elapsed_ms),
         {:ok, last_persist_age_ms} <- advance_age(snapshot.last_persist_age_ms, elapsed_ms),
         {:ok, last_sync_age_ms} <- advance_age(snapshot.last_sync_age_ms, elapsed_ms),
         {:ok, last_timeline_age_ms} <- advance_age(snapshot.last_timeline_age_ms, elapsed_ms),
         {:ok, last_tx_age_ms} <- advance_age(snapshot.last_tx_age_ms, elapsed_ms),
         {:ok, t0_age_ms} <- advance_age(snapshot.t0_age_ms, elapsed_ms),
         {:ok, last_t_age_ms} <- advance_age(snapshot.last_t_age_ms, elapsed_ms) do
      {:ok,
       %{
         snapshot
         | means: means,
           envelope: envelope,
           step: step,
           last_period_age_ms: last_period_age_ms,
           last_persist_age_ms: last_persist_age_ms,
           last_sync_age_ms: last_sync_age_ms,
           last_timeline_age_ms: last_timeline_age_ms,
           last_tx_age_ms: last_tx_age_ms,
           t0_age_ms: t0_age_ms,
           last_t_age_ms: last_t_age_ms
       }}
    else
      _ -> @invalid_runtime
    end
  rescue
    _ -> @invalid_runtime
  catch
    _, _ -> @invalid_runtime
  end

  def advance_runtime(_snapshot, _elapsed_ms), do: @invalid_runtime

  defp project_snapshot(snapshot) do
    with :ok <- exact_keys(snapshot, @snapshot_keys),
         {:ok, session} <- project_optional(snapshot.session, @session_fields),
         {:ok, pending_timeline} <- project_list(snapshot.pending_timeline, &project_timeline/1),
         {:ok, pending_events} <- project_list(snapshot.pending_events, &project_event/1),
         {:ok, last_summary} <- project_optional(snapshot.last_summary, @summary_fields) do
      {:ok,
       %{
         "session" => session,
         "seq" => snapshot.seq,
         "pending_timeline" => pending_timeline,
         "pending_events" => pending_events,
         "last_summary" => last_summary
       }}
    end
  end

  defp hydrate_content(content) do
    with :ok <- exact_keys(content, @content_keys),
         {:ok, session} <- hydrate_optional(content["session"], @session_fields),
         {:ok, pending_timeline} <- hydrate_list(content["pending_timeline"], &hydrate_timeline/1),
         {:ok, pending_events} <- hydrate_list(content["pending_events"], &hydrate_event/1),
         {:ok, last_summary} <- hydrate_optional(content["last_summary"], @summary_fields) do
      {:ok,
       %{
         session: session,
         seq: content["seq"],
         pending_timeline: pending_timeline,
         pending_events: pending_events,
         last_summary: last_summary
       }}
    else
      _ -> {:error, :invalid_checkpoint_content}
    end
  end

  defp project_timeline(row), do: project_map(row, @timeline_fields)
  defp hydrate_timeline(row), do: hydrate_map(row, @timeline_fields)

  defp project_event(event) do
    with {:ok, projected} <- project_map(event, @event_fields),
         {:ok, detail} <- project_event_detail(event.kind, event.detail) do
      {:ok, Map.put(projected, "detail", detail)}
    end
  end

  defp hydrate_event(event) do
    with {:ok, hydrated} <- hydrate_map(event, @event_fields),
         {:ok, detail} <- hydrate_event_detail(event["kind"], event["detail"]) do
      {:ok, Map.put(hydrated, :detail, detail)}
    end
  end

  defp project_event_detail("step", detail), do: project_map(detail, @step_detail)
  defp project_event_detail(kind, detail) when kind in ["new_high", "new_low"], do: project_map(detail, @extreme_detail)
  defp project_event_detail("regime_change", detail), do: project_map(detail, @regime_detail)

  defp project_event_detail(kind, detail) when kind in ["header_extreme", "lift_extreme"],
    do: project_map(detail, @phase_detail)

  defp project_event_detail(_kind, _detail), do: {:error, :invalid_shape}

  defp hydrate_event_detail("step", detail), do: hydrate_map(detail, @step_detail)
  defp hydrate_event_detail(kind, detail) when kind in ["new_high", "new_low"], do: hydrate_map(detail, @extreme_detail)
  defp hydrate_event_detail("regime_change", detail), do: hydrate_map(detail, @regime_detail)

  defp hydrate_event_detail(kind, detail) when kind in ["header_extreme", "lift_extreme"],
    do: hydrate_map(detail, @phase_detail)

  defp hydrate_event_detail(_kind, _detail), do: {:error, :invalid_shape}

  defp project_optional(nil, _fields), do: {:ok, nil}
  defp project_optional(value, fields), do: project_map(value, fields)

  defp hydrate_optional(nil, _fields), do: {:ok, nil}
  defp hydrate_optional(value, fields), do: hydrate_map(value, fields)

  defp project_map(map, fields) do
    with :ok <- exact_keys(map, Enum.map(fields, &elem(&1, 0))) do
      {:ok, Map.new(fields, fn {atom_key, string_key} -> {string_key, Map.fetch!(map, atom_key)} end)}
    end
  end

  defp hydrate_map(map, fields) do
    with :ok <- exact_keys(map, Enum.map(fields, &elem(&1, 1))) do
      {:ok, Map.new(fields, fn {atom_key, string_key} -> {atom_key, Map.fetch!(map, string_key)} end)}
    end
  end

  defp project_list(values, mapper), do: map_list(values, mapper)
  defp hydrate_list(values, mapper), do: map_list(values, mapper)

  defp map_list(values, mapper) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case mapper.(value) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp map_list(_values, _mapper), do: {:error, :invalid_shape}

  # --- Complete internal runtime learner shape ----------------------------------

  defp advance_means(means, elapsed_ms) when is_map(means) do
    [:fast, :mid, :slow, :sin, :cos]
    |> Enum.reduce_while({:ok, means}, fn key, {:ok, advanced} ->
      case advance_point(Map.get(means, key), elapsed_ms) do
        {:ok, point} -> {:cont, {:ok, Map.put(advanced, key, point)}}
        _ -> {:halt, @invalid_runtime}
      end
    end)
  end

  defp advance_means(_means, _elapsed_ms), do: @invalid_runtime

  defp advance_envelope(envelope, elapsed_ms) when is_map(envelope) do
    with {:ok, minq} <- advance_queue(envelope.minq, elapsed_ms),
         {:ok, maxq} <- advance_queue(envelope.maxq, elapsed_ms),
         {:ok, first_age_ms} <- advance_age(envelope.first_age_ms, elapsed_ms),
         {:ok, last_alarm_age_ms} <- advance_age(envelope.last_alarm_age_ms, elapsed_ms) do
      {:ok,
       %{
         envelope
         | minq: minq,
           maxq: maxq,
           first_age_ms: first_age_ms,
           last_alarm_age_ms: last_alarm_age_ms
       }}
    else
      _ -> @invalid_runtime
    end
  rescue
    _ -> @invalid_runtime
  end

  defp advance_envelope(_envelope, _elapsed_ms), do: @invalid_runtime

  defp advance_step(step, elapsed_ms) when is_map(step) do
    with {:ok, u_min_age_ms} <- advance_age(step.u_min_age_ms, elapsed_ms),
         {:ok, d_max_age_ms} <- advance_age(step.d_max_age_ms, elapsed_ms),
         {:ok, onset_age_ms} <- advance_age(step.onset_age_ms, elapsed_ms) do
      {:ok,
       %{
         step
         | u_min_age_ms: u_min_age_ms,
           d_max_age_ms: d_max_age_ms,
           onset_age_ms: onset_age_ms
       }}
    else
      _ -> @invalid_runtime
    end
  rescue
    _ -> @invalid_runtime
  end

  defp advance_step(_step, _elapsed_ms), do: @invalid_runtime

  defp advance_queue(entries, elapsed_ms) when is_list(entries) do
    map_list(entries, fn entry ->
      with :ok <- exact_keys(entry, [:age_ms, :value]),
           {:ok, age_ms} <- advance_age(entry.age_ms, elapsed_ms) do
        {:ok, %{entry | age_ms: age_ms}}
      else
        _ -> @invalid_runtime
      end
    end)
  end

  defp advance_queue(_entries, _elapsed_ms), do: @invalid_runtime

  defp advance_point(nil, _elapsed_ms), do: {:ok, nil}

  defp advance_point(point, elapsed_ms) when is_map(point) do
    with :ok <- exact_keys(point, [:value, :age_ms]),
         {:ok, age_ms} <- advance_age(point.age_ms, elapsed_ms) do
      {:ok, %{point | age_ms: age_ms}}
    else
      _ -> @invalid_runtime
    end
  end

  defp advance_point(_point, _elapsed_ms), do: @invalid_runtime

  defp advance_age(nil, _elapsed_ms), do: {:ok, nil}
  defp advance_age(age_ms, elapsed_ms), do: RuntimeSnapshot.add_elapsed(age_ms, elapsed_ms)

  defp project_means(%Means{} = means, now_ms) do
    with {:ok, fast} <- project_point(means.fast, now_ms),
         {:ok, mid} <- project_point(means.mid, now_ms),
         {:ok, slow} <- project_point(means.slow, now_ms),
         {:ok, sin} <- project_point(means.sin, now_ms),
         {:ok, cos} <- project_point(means.cos, now_ms) do
      {:ok,
       %{
         tau_fast_s: means.tau_fast_s,
         tau_mid_s: means.tau_mid_s,
         tau_slow_s: means.tau_slow_s,
         fast: fast,
         mid: mid,
         slow: slow,
         sin: sin,
         cos: cos
       }}
    end
  end

  defp project_means(_means, _now_ms), do: @invalid_runtime

  defp restore_means(means, now_ms) do
    keys = [:tau_fast_s, :tau_mid_s, :tau_slow_s, :fast, :mid, :slow, :sin, :cos]

    with :ok <- exact_keys(means, keys),
         :ok <- positive_float(means.tau_fast_s),
         :ok <- positive_float(means.tau_mid_s),
         :ok <- positive_float(means.tau_slow_s),
         {:ok, fast} <- restore_point(means.fast, now_ms),
         {:ok, mid} <- restore_point(means.mid, now_ms),
         {:ok, slow} <- restore_point(means.slow, now_ms),
         {:ok, sin} <- restore_point(means.sin, now_ms),
         {:ok, cos} <- restore_point(means.cos, now_ms),
         :ok <- all_nil_or_present([fast, mid, slow, sin, cos]),
         :ok <- circular_point(fast),
         :ok <- circular_point(mid),
         :ok <- circular_point(slow),
         :ok <- unit_point(sin),
         :ok <- unit_point(cos),
         :ok <- same_point_time([fast, mid, slow, sin, cos]) do
      {:ok,
       %Means{
         tau_fast_s: means.tau_fast_s,
         tau_mid_s: means.tau_mid_s,
         tau_slow_s: means.tau_slow_s,
         fast: fast,
         mid: mid,
         slow: slow,
         sin: sin,
         cos: cos
       }}
    end
  end

  defp project_envelope(%Envelope{} = envelope, now_ms) do
    with {:ok, minq} <- project_queue(envelope.minq, now_ms),
         {:ok, maxq} <- project_queue(envelope.maxq, now_ms),
         {:ok, first_age_ms} <- project_age(envelope.first_ms, now_ms),
         {:ok, last_alarm_age_ms} <- project_age(envelope.last_alarm_ms, now_ms) do
      {:ok,
       %{
         window_ms: envelope.window_ms,
         margin_deg: envelope.margin_deg,
         debounce_ms: envelope.debounce_ms,
         warmup_ms: envelope.warmup_ms,
         minq: minq,
         maxq: maxq,
         last_input_deg: envelope.last_input_deg,
         last_unwrapped: envelope.last_unwrapped,
         first_age_ms: first_age_ms,
         last_alarm_age_ms: last_alarm_age_ms,
         new_extreme: envelope.new_extreme
       }}
    end
  end

  defp project_envelope(_envelope, _now_ms), do: @invalid_runtime

  defp restore_envelope(envelope, now_ms) do
    keys = [
      :window_ms,
      :margin_deg,
      :debounce_ms,
      :warmup_ms,
      :minq,
      :maxq,
      :last_input_deg,
      :last_unwrapped,
      :first_age_ms,
      :last_alarm_age_ms,
      :new_extreme
    ]

    with :ok <- exact_keys(envelope, keys),
         :ok <- positive_integer(envelope.window_ms),
         :ok <- nonnegative_float(envelope.margin_deg),
         :ok <- nonnegative_integer(envelope.debounce_ms),
         :ok <- nonnegative_integer(envelope.warmup_ms),
         {:ok, minq} <- restore_queue(envelope.minq, :min, now_ms),
         {:ok, maxq} <- restore_queue(envelope.maxq, :max, now_ms),
         :ok <- nullable_direction(envelope.last_input_deg),
         :ok <- nullable_finite_float(envelope.last_unwrapped),
         {:ok, first_ms} <- restore_age(envelope.first_age_ms, now_ms),
         {:ok, last_alarm_ms} <- restore_age(envelope.last_alarm_age_ms, now_ms),
         :ok <- enum(envelope.new_extreme, [:none, :high, :low]),
         :ok <- validate_envelope_relations(envelope, minq, maxq) do
      {:ok,
       %Envelope{
         window_ms: envelope.window_ms,
         margin_deg: envelope.margin_deg,
         debounce_ms: envelope.debounce_ms,
         warmup_ms: envelope.warmup_ms,
         minq: minq,
         maxq: maxq,
         last_input_deg: envelope.last_input_deg,
         last_unwrapped: envelope.last_unwrapped,
         first_ms: first_ms,
         last_alarm_ms: last_alarm_ms,
         new_extreme: envelope.new_extreme
       }}
    end
  end

  defp project_cycle(%Cycle{} = cycle) do
    {:ok,
     %{
       omega: cycle.omega,
       rho_per_s: cycle.rho_per_s,
       obs_var: cycle.obs_var,
       q_level_per_s: cycle.q_level_per_s,
       q_slope_per_s: cycle.q_slope_per_s,
       cycle_var: cycle.cycle_var,
       innovation_tau_s: cycle.innovation_tau_s,
       x: cycle.x,
       p: cycle.p,
       innovation_var: cycle.innovation_var
     }}
  end

  defp project_cycle(_cycle), do: @invalid_runtime

  defp restore_cycle(cycle) do
    keys = [
      :omega,
      :rho_per_s,
      :obs_var,
      :q_level_per_s,
      :q_slope_per_s,
      :cycle_var,
      :innovation_tau_s,
      :x,
      :p,
      :innovation_var
    ]

    with :ok <- exact_keys(cycle, keys),
         :ok <- positive_float(cycle.omega),
         :ok <- positive_float(cycle.rho_per_s),
         :ok <- ensure(cycle.rho_per_s <= 1.0),
         :ok <- positive_float(cycle.obs_var),
         :ok <- nonnegative_float(cycle.q_level_per_s),
         :ok <- nonnegative_float(cycle.q_slope_per_s),
         :ok <- nonnegative_float(cycle.cycle_var),
         :ok <- positive_float(cycle.innovation_tau_s),
         :ok <- validate_cycle_state(cycle.x, cycle.p, cycle.innovation_var) do
      {:ok,
       %Cycle{
         omega: cycle.omega,
         rho_per_s: cycle.rho_per_s,
         obs_var: cycle.obs_var,
         q_level_per_s: cycle.q_level_per_s,
         q_slope_per_s: cycle.q_slope_per_s,
         cycle_var: cycle.cycle_var,
         innovation_tau_s: cycle.innovation_tau_s,
         x: cycle.x,
         p: cycle.p,
         innovation_var: cycle.innovation_var
       }}
    end
  end

  defp project_step(
         %StepDetect{} = step,
         %{u_min_t_ms: u_min_t_ms, d_max_t_ms: d_max_t_ms, onset_t_ms: onset_t_ms},
         now_ms
       ) do
    with {:ok, u_min_age_ms} <- project_age(step.u_min_ms, now_ms),
         {:ok, d_max_age_ms} <- project_age(step.d_max_ms, now_ms),
         {:ok, onset_age_ms} <- project_age(step.onset_ms, now_ms) do
      {:ok,
       %{
         delta_deg: step.delta_deg,
         threshold_deg: step.threshold_deg,
         band_deg: step.band_deg,
         settle_s: step.settle_s,
         min_magnitude_deg: step.min_magnitude_deg,
         fast_confirm_deg: step.fast_confirm_deg,
         fast_confirm_s: step.fast_confirm_s,
         max_confirm_s: step.max_confirm_s,
         period_hint_s: step.period_hint_s,
         status: step.status,
         u: step.u,
         u_min: step.u_min,
         u_min_age_ms: u_min_age_ms,
         u_min_t_ms: u_min_t_ms,
         u_sum: step.u_sum,
         u_n: step.u_n,
         d: step.d,
         d_max: step.d_max,
         d_max_age_ms: d_max_age_ms,
         d_max_t_ms: d_max_t_ms,
         d_sum: step.d_sum,
         d_n: step.d_n,
         dir: step.dir,
         onset_age_ms: onset_age_ms,
         onset_t_ms: onset_t_ms,
         cand_sum: step.cand_sum,
         cand_n: step.cand_n,
         magnitude: step.magnitude
       }}
    end
  end

  defp project_step(_step, _step_clock, _now_ms), do: @invalid_runtime

  defp restore_step(step, now_ms, session) do
    keys = [
      :delta_deg,
      :threshold_deg,
      :band_deg,
      :settle_s,
      :min_magnitude_deg,
      :fast_confirm_deg,
      :fast_confirm_s,
      :max_confirm_s,
      :period_hint_s,
      :status,
      :u,
      :u_min,
      :u_min_age_ms,
      :u_min_t_ms,
      :u_sum,
      :u_n,
      :d,
      :d_max,
      :d_max_age_ms,
      :d_max_t_ms,
      :d_sum,
      :d_n,
      :dir,
      :onset_age_ms,
      :onset_t_ms,
      :cand_sum,
      :cand_n,
      :magnitude
    ]

    with :ok <- exact_keys(step, keys),
         :ok <- nonnegative_float(step.delta_deg),
         :ok <- positive_float(step.threshold_deg),
         :ok <- nonnegative_float(step.band_deg),
         :ok <- nonnegative_float(step.settle_s),
         :ok <- nonnegative_float(step.min_magnitude_deg),
         :ok <- nonnegative_float(step.fast_confirm_deg),
         :ok <- nonnegative_float(step.fast_confirm_s),
         :ok <- positive_float(step.max_confirm_s),
         :ok <- nullable_positive_float(step.period_hint_s),
         :ok <- enum(step.status, [:none, :candidate, :confirmed]),
         :ok <- finite_float(step.u),
         :ok <- finite_float(step.u_min),
         {:ok, u_min_ms} <- restore_age(step.u_min_age_ms, now_ms),
         :ok <- nullable_nonnegative_integer(step.u_min_t_ms),
         :ok <- finite_float(step.u_sum),
         :ok <- nonnegative_integer(step.u_n),
         :ok <- finite_float(step.d),
         :ok <- finite_float(step.d_max),
         {:ok, d_max_ms} <- restore_age(step.d_max_age_ms, now_ms),
         :ok <- nullable_nonnegative_integer(step.d_max_t_ms),
         :ok <- finite_float(step.d_sum),
         :ok <- nonnegative_integer(step.d_n),
         :ok <- nullable_enum(step.dir, [:up, :down]),
         {:ok, onset_ms} <- restore_age(step.onset_age_ms, now_ms),
         :ok <- nullable_nonnegative_integer(step.onset_t_ms),
         :ok <- finite_float(step.cand_sum),
         :ok <- nonnegative_integer(step.cand_n),
         :ok <- nullable_finite_float(step.magnitude),
         :ok <- validate_step_relations(step),
         :ok <- validate_step_clock(step, session) do
      restored_step = %StepDetect{
        delta_deg: step.delta_deg,
        threshold_deg: step.threshold_deg,
        band_deg: step.band_deg,
        settle_s: step.settle_s,
        min_magnitude_deg: step.min_magnitude_deg,
        fast_confirm_deg: step.fast_confirm_deg,
        fast_confirm_s: step.fast_confirm_s,
        max_confirm_s: step.max_confirm_s,
        period_hint_s: step.period_hint_s,
        status: step.status,
        u: step.u,
        u_min: step.u_min,
        u_min_ms: u_min_ms,
        u_sum: step.u_sum,
        u_n: step.u_n,
        d: step.d,
        d_max: step.d_max,
        d_max_ms: d_max_ms,
        d_sum: step.d_sum,
        d_n: step.d_n,
        dir: step.dir,
        onset_ms: onset_ms,
        cand_sum: step.cand_sum,
        cand_n: step.cand_n,
        magnitude: step.magnitude
      }

      {:ok, restored_step, %{u_min_t_ms: step.u_min_t_ms, d_max_t_ms: step.d_max_t_ms, onset_t_ms: step.onset_t_ms}}
    end
  end

  defp project_queue(queue, now_ms) do
    queue
    |> :queue.to_list()
    |> map_list(fn {t_ms, value} ->
      with {:ok, age_ms} <- project_age(t_ms, now_ms) do
        {:ok, %{age_ms: age_ms, value: value}}
      end
    end)
  rescue
    _ -> @invalid_runtime
  end

  defp restore_queue(entries, kind, now_ms) do
    with :ok <- bounded_list(entries, @max_envelope_entries),
         {:ok, restored} <-
           map_list(entries, fn entry ->
             with :ok <- exact_keys(entry, [:age_ms, :value]),
                  :ok <- nonnegative_integer(entry.age_ms),
                  :ok <- finite_float(entry.value) do
               {:ok, {now_ms - entry.age_ms, entry.value}}
             end
           end),
         :ok <- ordered_queue_entries(entries, kind) do
      {:ok, :queue.from_list(restored)}
    end
  end

  defp project_point(nil, _now_ms), do: {:ok, nil}

  defp project_point({value, t_ms}, now_ms) do
    with {:ok, age_ms} <- project_age(t_ms, now_ms) do
      {:ok, %{value: value, age_ms: age_ms}}
    end
  end

  defp project_point(_point, _now_ms), do: @invalid_runtime

  defp restore_point(nil, _now_ms), do: {:ok, nil}

  defp restore_point(point, now_ms) do
    with :ok <- exact_keys(point, [:value, :age_ms]),
         :ok <- finite_float(point.value),
         :ok <- nonnegative_integer(point.age_ms) do
      {:ok, {point.value, now_ms - point.age_ms}}
    end
  end

  defp project_age(nil, _now_ms), do: {:ok, nil}

  defp project_age(t_ms, now_ms) when is_integer(t_ms) and t_ms <= now_ms,
    do: {:ok, now_ms - t_ms}

  defp project_age(_t_ms, _now_ms), do: @invalid_runtime

  defp restore_age(nil, _now_ms), do: {:ok, nil}
  defp restore_age(age_ms, now_ms) when is_integer(age_ms) and age_ms >= 0, do: {:ok, now_ms - age_ms}
  defp restore_age(_age_ms, _now_ms), do: @invalid_runtime

  defp project_residuals({queue, count}) when is_integer(count) do
    {:ok, %{count: count, values: :queue.to_list(queue)}}
  rescue
    _ -> @invalid_runtime
  end

  defp project_residuals(_residuals), do: @invalid_runtime

  defp restore_residuals(residuals) do
    with :ok <- exact_keys(residuals, [:count, :values]),
         :ok <- nonnegative_integer(residuals.count),
         :ok <- bounded_list(residuals.values, @max_residuals),
         :ok <- ensure(residuals.count == length(residuals.values)),
         :ok <- validate_each(residuals.values, &finite_float/1) do
      {:ok, {:queue.from_list(residuals.values), residuals.count}}
    end
  end

  defp project_unwrap(nil), do: nil

  defp project_unwrap({last_input_deg, last_unwrapped}),
    do: %{last_input_deg: last_input_deg, last_unwrapped: last_unwrapped}

  defp project_unwrap(_unwrap), do: :invalid

  defp restore_unwrap(nil), do: {:ok, nil}

  defp restore_unwrap(unwrap) do
    with :ok <- exact_keys(unwrap, [:last_input_deg, :last_unwrapped]),
         :ok <- direction(unwrap.last_input_deg),
         :ok <- finite_float(unwrap.last_unwrapped) do
      {:ok, {unwrap.last_input_deg, unwrap.last_unwrapped}}
    end
  end

  defp restore_period(:none), do: {:ok, :none}

  defp restore_period(period) do
    with :ok <- exact_keys(period, [:period_s, :confidence]),
         :ok <- positive_float(period.period_s),
         :ok <- probability(period.confidence) do
      {:ok, period}
    end
  end

  defp project_xing(%{side: side, extreme: nil}), do: %{side: side, extreme: nil}

  defp project_xing(%{side: side, extreme: {phase_deg, twd_deg, t_ms}}) do
    %{side: side, extreme: %{phase_deg: phase_deg, twd_deg: twd_deg, t_ms: t_ms}}
  end

  defp project_xing(_xing), do: :invalid

  defp restore_xing(xing, session, current_utc_ms) do
    with :ok <- exact_keys(xing, [:side, :extreme]),
         :ok <- nullable_enum(xing.side, [:pos, :neg]),
         {:ok, extreme} <- restore_xing_extreme(xing.extreme),
         :ok <- validate_xing_relations(xing.side, extreme, session, current_utc_ms) do
      restored =
        case extreme do
          nil -> nil
          %{phase_deg: phase_deg, twd_deg: twd_deg, t_ms: t_ms} -> {phase_deg, twd_deg, t_ms}
        end

      {:ok, %{side: xing.side, extreme: restored}}
    end
  end

  defp restore_xing_extreme(nil), do: {:ok, nil}

  defp restore_xing_extreme(extreme) do
    with :ok <- exact_keys(extreme, [:phase_deg, :twd_deg, :t_ms]),
         :ok <- finite_float(extreme.phase_deg),
         :ok <- direction(extreme.twd_deg),
         :ok <- nonnegative_integer(extreme.t_ms) do
      {:ok, extreme}
    end
  end

  defp restore_verdict(nil), do: {:ok, nil}

  defp restore_verdict(verdict) do
    keys = [
      :regime,
      :confidence,
      :oscillation,
      :trend_deg_per_hr,
      :time_to_next_shift_s,
      :ci_s,
      :treat_as_persistent,
      :regime_alarm,
      :phase_deg
    ]

    with :ok <- exact_keys(verdict, keys),
         :ok <- enum(verdict.regime, @regimes),
         :ok <- probability(verdict.confidence),
         {:ok, oscillation} <- restore_oscillation(verdict.oscillation),
         :ok <- nullable_finite_float(verdict.trend_deg_per_hr),
         :ok <- nullable_nonnegative_float(verdict.time_to_next_shift_s),
         :ok <- nullable_nonnegative_float(verdict.ci_s),
         :ok <- boolean(verdict.treat_as_persistent),
         :ok <- boolean(verdict.regime_alarm),
         :ok <- nullable_phase(verdict.phase_deg) do
      {:ok, %{verdict | oscillation: oscillation}}
    end
  end

  defp restore_oscillation(nil), do: {:ok, nil}

  defp restore_oscillation(oscillation) do
    keys = [
      :period_s,
      :amplitude_deg,
      :phase_rad,
      :time_to_next_header_s,
      :phase_frac_to_next_header
    ]

    with :ok <- exact_keys(oscillation, keys),
         :ok <- positive_float(oscillation.period_s),
         :ok <- nonnegative_float(oscillation.amplitude_deg),
         :ok <- finite_float(oscillation.phase_rad),
         :ok <- validate_tack_map(oscillation.time_to_next_header_s, &nonnegative_float/1),
         :ok <- validate_tack_map(oscillation.phase_frac_to_next_header, &probability/1) do
      {:ok, oscillation}
    end
  end

  defp validate_tack_map(values, validator) do
    with :ok <- exact_keys(values, [:starboard, :port]),
         :ok <- validator.(values.starboard),
         :ok <- validator.(values.port) do
      :ok
    end
  end

  defp validate_runtime_relations(snapshot, means, envelope, cycle, step, last_t_ms) do
    with :ok <-
           validate_history_times(snapshot.t0_age_ms, snapshot.last_period_age_ms, snapshot.last_t_age_ms),
         :ok <- validate_learner_presence(snapshot, means, envelope, last_t_ms),
         :ok <- validate_step_transition(step.status, snapshot.prev_step_status),
         :ok <- validate_cycle_frequency(cycle, step),
         :ok <- validate_sessionless_runtime(snapshot) do
      :ok
    end
  end

  defp validate_history_times(nil, nil, nil), do: :ok

  defp validate_history_times(t0_age_ms, last_period_age_ms, last_t_age_ms)
       when is_integer(t0_age_ms) and is_integer(last_period_age_ms) and is_integer(last_t_age_ms) and
              t0_age_ms >= last_period_age_ms and last_period_age_ms >= last_t_age_ms,
       do: :ok

  defp validate_history_times(_t0_age_ms, _last_period_age_ms, _last_t_age_ms), do: @invalid_runtime

  defp validate_learner_presence(snapshot, %Means{fast: nil}, %Envelope{first_ms: nil}, nil) do
    ensure(snapshot.unwrap == nil and snapshot.residuals == %{count: 0, values: []})
  end

  defp validate_learner_presence(snapshot, %Means{fast: {_value, means_ms}}, envelope, last_t_ms)
       when is_integer(last_t_ms) do
    latest_envelope_ms = latest_queue_ms(envelope)

    ensure(
      means_ms == last_t_ms and latest_envelope_ms == last_t_ms and snapshot.unwrap != nil and
        snapshot.residuals.count > 0
    )
  end

  defp validate_learner_presence(_snapshot, _means, _envelope, _last_t_ms), do: @invalid_runtime

  defp validate_sessionless_runtime(%{session: nil} = snapshot) do
    ensure(
      snapshot.unwrap == nil and snapshot.residuals == %{count: 0, values: []} and snapshot.period == :none and
        is_nil(snapshot.last_period_age_ms) and is_nil(snapshot.t0_age_ms) and is_nil(snapshot.last_t_age_ms) and
        snapshot.prev_step_status == :none and is_nil(snapshot.prev_regime) and snapshot.absorb_count == 0 and
        is_nil(snapshot.last_tack) and snapshot.xing == %{side: nil, extreme: nil} and is_nil(snapshot.last_verdict) and
        is_nil(snapshot.last_lift)
    )
  end

  defp validate_sessionless_runtime(_snapshot), do: :ok

  defp validate_not_future(_store, _step_clock, nil), do: :ok

  defp validate_not_future(store, step_clock, current_utc_ms) do
    with :ok <- not_future(store.session && store.session.started_at_ms, current_utc_ms),
         :ok <- validate_each(store.pending_timeline, &not_future(&1.t_ms, current_utc_ms)),
         :ok <- validate_each(store.pending_events, &not_future(&1.t_ms, current_utc_ms)),
         :ok <- not_future(step_clock.u_min_t_ms, current_utc_ms),
         :ok <- not_future(step_clock.d_max_t_ms, current_utc_ms),
         :ok <- not_future(step_clock.onset_t_ms, current_utc_ms) do
      :ok
    end
  end

  defp paired_presence(nil, nil), do: :ok
  defp paired_presence(age_ms, t_ms) when is_integer(age_ms) and is_integer(t_ms), do: :ok
  defp paired_presence(_age_ms, _t_ms), do: @invalid_runtime

  defp session_bound_time(nil, _session), do: :ok
  defp session_bound_time(_t_ms, nil), do: @invalid_runtime

  defp session_bound_time(t_ms, %{started_at_ms: started_at_ms}) do
    ensure(t_ms >= started_at_ms and div(t_ms, @ms_per_utc_day) == div(started_at_ms, @ms_per_utc_day))
  end

  defp not_future(nil, _current_utc_ms), do: :ok
  defp not_future(_t_ms, nil), do: :ok
  defp not_future(t_ms, current_utc_ms), do: ensure(t_ms <= current_utc_ms)

  defp latest_queue_ms(envelope) do
    case :queue.peek_r(envelope.minq) do
      {:value, {t_ms, _value}} -> t_ms
      :empty -> nil
    end
  end

  defp validate_envelope_relations(envelope, minq, maxq) do
    empty? = :queue.is_empty(minq) and :queue.is_empty(maxq)
    populated? = not :queue.is_empty(minq) and not :queue.is_empty(maxq)

    cond do
      empty? ->
        ensure(
          is_nil(envelope.last_input_deg) and is_nil(envelope.last_unwrapped) and is_nil(envelope.first_age_ms) and
            is_nil(envelope.last_alarm_age_ms) and envelope.new_extreme == :none
        )

      populated? ->
        ensure(
          is_float(envelope.last_input_deg) and is_float(envelope.last_unwrapped) and
            is_integer(envelope.first_age_ms) and
            (is_nil(envelope.last_alarm_age_ms) or envelope.first_age_ms >= envelope.last_alarm_age_ms)
        )

      true ->
        @invalid_runtime
    end
  end

  defp validate_cycle_state(nil, nil, nil), do: :ok

  defp validate_cycle_state(x, p, innovation_var) do
    with :ok <- fixed_float_list(x, 4),
         :ok <- fixed_matrix(p, 4),
         :ok <- nonnegative_float(innovation_var),
         :ok <- positive_semidefinite(p) do
      :ok
    end
  end

  defp validate_step_relations(%{status: :none} = step) do
    ensure(
      is_nil(step.dir) and is_nil(step.onset_age_ms) and step.cand_sum == 0.0 and step.cand_n == 0 and
        is_nil(step.magnitude)
    )
  end

  defp validate_step_relations(%{status: :candidate} = step) do
    ensure(step.dir in [:up, :down] and is_integer(step.onset_age_ms) and step.cand_n > 0 and is_nil(step.magnitude))
  end

  defp validate_step_relations(%{status: :confirmed} = step) do
    ensure(step.dir in [:up, :down] and is_integer(step.onset_age_ms) and step.cand_n > 0 and is_float(step.magnitude))
  end

  defp validate_step_clock(step, session) do
    with :ok <- paired_presence(step.u_min_age_ms, step.u_min_t_ms),
         :ok <- paired_presence(step.d_max_age_ms, step.d_max_t_ms),
         :ok <- paired_presence(step.onset_age_ms, step.onset_t_ms),
         :ok <- session_bound_time(step.u_min_t_ms, session),
         :ok <- session_bound_time(step.d_max_t_ms, session),
         :ok <- session_bound_time(step.onset_t_ms, session) do
      :ok
    end
  end

  defp validate_step_transition(status, status), do: :ok
  defp validate_step_transition(:none, :confirmed), do: :ok
  defp validate_step_transition(_status, _previous), do: @invalid_runtime

  defp validate_cycle_frequency(cycle, step) do
    period_s = step.period_hint_s || 480.0
    expected = 2.0 * :math.pi() / period_s
    tolerance = 1.0e-9 * max(abs(expected), 1.0)
    ensure(abs(cycle.omega - expected) <= tolerance)
  end

  defp ordered_queue_entries(entries, kind) do
    entries
    |> Enum.chunk_every(2, 1, :discard)
    |> validate_each(fn [left, right] ->
      age_ordered? = left.age_ms >= right.age_ms

      value_ordered? =
        case kind do
          :min -> left.value < right.value
          :max -> left.value > right.value
        end

      ensure(age_ordered? and value_ordered?)
    end)
  end

  defp validate_xing_relations(nil, nil, _session, _current_utc_ms), do: :ok

  defp validate_xing_relations(side, nil, _session, _current_utc_ms) when side in [:pos, :neg],
    do: @invalid_runtime

  defp validate_xing_relations(_side, _extreme, nil, _current_utc_ms), do: @invalid_runtime

  defp validate_xing_relations(side, extreme, %{started_at_ms: started_at_ms}, current_utc_ms)
       when side in [nil, :pos, :neg] do
    with :ok <-
           ensure(
             extreme.t_ms >= started_at_ms and
               div(extreme.t_ms, @ms_per_utc_day) == div(started_at_ms, @ms_per_utc_day)
           ),
         :ok <- not_future(extreme.t_ms, current_utc_ms) do
      case side do
        nil -> ensure(abs(extreme.phase_deg) <= @xing_hysteresis_deg)
        :pos -> ensure(extreme.phase_deg > @xing_hysteresis_deg and extreme.phase_deg <= 180.0)
        :neg -> ensure(extreme.phase_deg < -@xing_hysteresis_deg and extreme.phase_deg >= -180.0)
      end
    end
  end

  defp validate_prev_step_status(status), do: enum(status, [:none, :candidate, :confirmed])
  defp validate_prev_regime(nil), do: :ok
  defp validate_prev_regime(regime), do: enum(regime, @regimes)

  defp validate_tack(nil), do: :ok
  defp validate_tack(tack), do: ensure(tack in [-1.0, 1.0])

  defp all_nil_or_present(values) do
    ensure(Enum.all?(values, &is_nil/1) or Enum.all?(values, &match?({_value, _t_ms}, &1)))
  end

  defp same_point_time([nil | _rest]), do: :ok

  defp same_point_time([{_value, t_ms} | rest]) do
    ensure(Enum.all?(rest, fn {_value, other_ms} -> other_ms == t_ms end))
  end

  defp circular_point(nil), do: :ok
  defp circular_point({value, _t_ms}), do: ensure(value >= 0.0 and value < 2.0 * :math.pi())

  defp unit_point(nil), do: :ok
  defp unit_point({value, _t_ms}), do: ensure(value >= -1.0 and value <= 1.0)

  defp fixed_float_list(values, size) when is_list(values) do
    with :ok <- ensure(length(values) == size),
         :ok <- validate_each(values, &finite_float/1) do
      :ok
    end
  end

  defp fixed_float_list(_values, _size), do: @invalid_runtime

  defp fixed_matrix(rows, size) when is_list(rows) do
    with :ok <- ensure(length(rows) == size),
         :ok <- validate_each(rows, &fixed_float_list(&1, size)) do
      :ok
    end
  end

  defp fixed_matrix(_rows, _size), do: @invalid_runtime

  defp positive_semidefinite(matrix) do
    indices = Enum.to_list(0..(length(matrix) - 1))
    scale = matrix |> List.flatten() |> Enum.map(&abs/1) |> Enum.max(fn -> 1.0 end) |> max(1.0)
    normalized = Enum.map(matrix, fn row -> Enum.map(row, &(&1 / scale)) end)

    with :ok <- validate_each(indices, fn i -> ensure(matrix |> Enum.at(i) |> Enum.at(i) >= 0.0) end),
         :ok <-
           validate_each(indices, fn i ->
             validate_each(indices, fn j ->
               left = matrix |> Enum.at(i) |> Enum.at(j)
               right = matrix |> Enum.at(j) |> Enum.at(i)
               tolerance = 1.0e-9 * max(max(abs(left), abs(right)), 1.0)
               ensure(abs(left - right) <= tolerance)
             end)
           end),
         :ok <-
           indices
           |> principal_index_sets()
           |> validate_each(fn selected ->
             minor =
               Enum.map(selected, fn i -> Enum.map(selected, fn j -> normalized |> Enum.at(i) |> Enum.at(j) end) end)

             determinant = determinant(minor)

             with :ok <- finite_float(determinant), do: ensure(determinant >= -1.0e-10)
           end) do
      :ok
    end
  end

  defp principal_index_sets(indices) do
    Enum.flat_map(1..length(indices), &combinations(indices, &1))
  end

  defp combinations(_values, 0), do: [[]]
  defp combinations([], _count), do: []

  defp combinations([value | rest], count) do
    Enum.map(combinations(rest, count - 1), &[value | &1]) ++ combinations(rest, count)
  end

  defp determinant([[value]]), do: value

  defp determinant(matrix) do
    matrix
    |> hd()
    |> Enum.with_index()
    |> Enum.reduce(0.0, fn {value, column}, acc ->
      sign = if rem(column, 2) == 0, do: 1.0, else: -1.0
      minor = matrix |> tl() |> Enum.map(&List.delete_at(&1, column))
      acc + sign * value * determinant(minor)
    end)
  end

  defp bounded_list(values, max) when is_list(values), do: ensure(length(values) <= max)
  defp bounded_list(_values, _max), do: @invalid_runtime

  defp validate_each(values, validator) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validator.(value) do
        :ok -> {:cont, :ok}
        _ -> {:halt, @invalid_runtime}
      end
    end)
  end

  defp positive_integer(value), do: ensure(is_integer(value) and value > 0)
  defp nonnegative_integer(value), do: ensure(is_integer(value) and value >= 0)
  defp nullable_nonnegative_integer(nil), do: :ok
  defp nullable_nonnegative_integer(value), do: nonnegative_integer(value)

  defp finite_float(value) do
    ensure(is_float(value) and value == value and value >= -@max_finite and value <= @max_finite)
  end

  defp positive_float(value) do
    with :ok <- finite_float(value), do: ensure(value > 0.0)
  end

  defp nonnegative_float(value) do
    with :ok <- finite_float(value), do: ensure(value >= 0.0)
  end

  defp nullable_finite_float(nil), do: :ok
  defp nullable_finite_float(value), do: finite_float(value)

  defp nullable_positive_float(nil), do: :ok
  defp nullable_positive_float(value), do: positive_float(value)

  defp nullable_nonnegative_float(nil), do: :ok
  defp nullable_nonnegative_float(value), do: nonnegative_float(value)

  defp direction(value) do
    with :ok <- finite_float(value), do: ensure(value >= 0.0 and value < 360.0)
  end

  defp nullable_direction(nil), do: :ok
  defp nullable_direction(value), do: direction(value)

  defp nullable_phase(nil), do: :ok

  defp nullable_phase(value) do
    with :ok <- finite_float(value), do: ensure(value >= -180.0 and value <= 180.0)
  end

  defp probability(value) do
    with :ok <- finite_float(value), do: ensure(value >= 0.0 and value <= 1.0)
  end

  defp boolean(value), do: ensure(is_boolean(value))
  defp enum(value, values), do: ensure(value in values)
  defp nullable_enum(nil, _values), do: :ok
  defp nullable_enum(value, values), do: enum(value, values)

  defp ensure(true), do: :ok
  defp ensure(false), do: @invalid_runtime

  defp exact_keys(map, expected) when is_map(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(expected), do: :ok, else: {:error, :invalid_shape}
  end

  defp exact_keys(_map, _expected), do: {:error, :invalid_shape}
end
