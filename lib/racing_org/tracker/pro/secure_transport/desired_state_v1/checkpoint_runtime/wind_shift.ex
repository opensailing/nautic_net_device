defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.WindShift do
  @moduledoc """
  Closed validator for Wind Shift exact-runtime checkpoint schema v2.

  This schema is deliberately separate from the legacy Wind Shift learner/store
  schema v1. It carries the complete observer snapshot, represents arbitrary
  identity bytes with `Canonical.bytes/1`, and chunks the two envelope deques so
  their legal 100,000-row runtime capacity is not truncated by the canonical
  value grammar's 65,535-element collection limit.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint, as: ContractCheckpoint
  alias RacingOrg.Tracker.Pro.WindShift.Observer.Snapshot

  @invalid {:error, :invalid_checkpoint_content}
  @u32_max 0xFFFF_FFFF
  @u64_max 0xFFFF_FFFF_FFFF_FFFF
  @database_int_max 9_223_372_036_854_775_807
  @max_finite 1.7976931348623157e308
  @negative_zero_bits 0x8000_0000_0000_0000
  @max_envelope_entries 100_000
  @max_chunk_entries 65_535
  @max_residuals 1_800
  @ms_per_utc_day 86_400_000
  @xing_hysteresis_deg 2.0

  @top_fields ~w(authority captured_at_utc_ms policy runtime source_generation stats tick version)
  @authority_fields ~w(credential_epoch device_id storage_epoch)
  @policy_fields ~w(
    absorb_dwell_ticks alarms broadcast_rate_ms period_every_ms persist_ms residual_window
    sample_ms staleness_ms sync_ms timeline_ms version wally_mode windows xing_hysteresis_deg
  )
  @stats_fields ~w(accepted reject_reasons rejected samples)

  @runtime_fields ~w(
    absorb_count cycle envelope last_lift last_period_age_ms last_persist_age_ms
    last_summary last_sync_age_ms last_t_age_ms last_tack last_timeline_age_ms
    last_tx_age_ms last_verdict means pending_events pending_timeline period
    prev_regime prev_step_status residuals seq session step t0_age_ms unwrap xing
  )

  @event_fields ~w(detail kind magnitude_deg t_ms twd_deg)
  @means_fields ~w(cos fast mid sin slow tau_fast_s tau_mid_s tau_slow_s)
  @envelope_fields ~w(
    debounce_ms first_age_ms last_alarm_age_ms last_input_deg last_unwrapped margin_deg maxq minq
    new_extreme warmup_ms window_ms
  )
  @chunked_fields ~w(chunks count)
  @step_fields ~w(
    band_deg cand_n cand_sum d d_max d_max_age_ms d_max_t_ms d_n d_sum delta_deg dir
    fast_confirm_deg fast_confirm_s magnitude max_confirm_s min_magnitude_deg onset_age_ms onset_t_ms
    period_hint_s settle_s status threshold_deg u u_min u_min_age_ms u_min_t_ms u_n u_sum
  )
  @xing_fields ~w(extreme side)
  @verdict_fields ~w(
    ci_s confidence oscillation phase_deg regime regime_alarm time_to_next_shift_s trend_deg_per_hr
    treat_as_persistent
  )
  @oscillation_fields ~w(
    amplitude_deg period_s phase_frac_to_next_header phase_rad time_to_next_header_s
  )
  @doc "Project one complete internal Observer snapshot into Wind Shift runtime schema v2."
  @spec project(term()) :: {:ok, map()} | {:error, :invalid_checkpoint_content}
  def project(internal_snapshot) do
    with :ok <- Snapshot.preflight(internal_snapshot),
         {:ok, wire_content} <- encode_snapshot(internal_snapshot),
         :ok <- validate(wire_content),
         {:ok, _canonical} <- ContractCheckpoint.canonical_content(:wind_shift, 2, wire_content) do
      {:ok, wire_content}
    else
      _ -> @invalid
    end
  rescue
    _ -> @invalid
  catch
    _, _ -> @invalid
  end

  @doc "Hydrate runtime schema v2 into the complete internal Observer snapshot."
  @spec hydrate(term()) :: {:ok, map()} | {:error, :invalid_checkpoint_content}
  def hydrate(wire_content) do
    with {:ok, _canonical} <- ContractCheckpoint.canonical_content(:wind_shift, 2, wire_content),
         {:ok, snapshot} <- decode_snapshot(wire_content),
         :ok <- validate_snapshot(snapshot),
         :ok <- Snapshot.preflight(snapshot) do
      {:ok, snapshot}
    else
      _ -> @invalid
    end
  rescue
    _ -> @invalid
  catch
    _, _ -> @invalid
  end

  @doc "Validate one exact Wind Shift runtime wire value without creating atoms from input."
  @spec validate(term()) :: :ok | {:error, :invalid_checkpoint_content}
  def validate(wire_content) do
    with {:ok, _snapshot} <- validated_snapshot(wire_content) do
      :ok
    end
  rescue
    _ -> @invalid
  catch
    _, _ -> @invalid
  end

  @doc "Extract the validated durable authority embedded in runtime schema v2."
  @spec durable_authority(term()) :: {:ok, map()} | {:error, :invalid_checkpoint_content}
  def durable_authority(wire_content) do
    with {:ok, snapshot} <- validated_snapshot(wire_content) do
      {:ok, snapshot.authority}
    end
  rescue
    _ -> @invalid
  catch
    _, _ -> @invalid
  end

  @doc "Rebind one hydrated runtime snapshot to the current durable target authority."
  @spec rebind_authority(term(), term()) ::
          {:ok, map()}
          | {:error, :invalid_checkpoint_content}
          | {:error, :checkpoint_authority_rebind_mismatch}
  def rebind_authority(snapshot, target_authority) do
    case Snapshot.rebind_authority(snapshot, target_authority) do
      {:ok, rebound} -> {:ok, rebound}
      {:error, :authority_device_mismatch} -> {:error, :checkpoint_authority_rebind_mismatch}
      _ -> @invalid
    end
  rescue
    _ -> @invalid
  catch
    _, _ -> @invalid
  end

  defp validated_snapshot(wire_content) do
    with {:ok, snapshot} <- decode_snapshot(wire_content),
         :ok <- validate_snapshot(snapshot),
         {:ok, _canonical} <- Canonical.encode(wire_content) do
      {:ok, snapshot}
    else
      _ -> @invalid
    end
  end

  defp encode_snapshot(snapshot) do
    encode_value(snapshot, [])
  end

  defp encode_value(value, path) when is_map(value) and not is_struct(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {key, nested}, {:ok, acc} ->
      with {:ok, wire_key} <- wire_key(key),
           {:ok, wire_value} <- encode_value(nested, [key | path]) do
        {:cont, {:ok, Map.put(acc, wire_key, wire_value)}}
      else
        _ -> {:halt, @invalid}
      end
    end)
  end

  defp encode_value(value, [queue, :envelope, :runtime])
       when queue in [:minq, :maxq] and is_list(value) do
    with :ok <- proper_list(value),
         :ok <- ensure(length(value) <= @max_envelope_entries),
         {:ok, entries} <- encode_queue_entries(value) do
      {:ok, %{"count" => length(entries), "chunks" => Enum.chunk_every(entries, @max_chunk_entries)}}
    end
  end

  defp encode_value(value, path) when is_list(value), do: encode_list_values(value, path)

  defp encode_value(value, [field, :authority]) when field in [:device_id, :storage_epoch] and is_binary(value),
    do: {:ok, Canonical.bytes(value)}

  defp encode_value(value, _path)
       when is_binary(value) or is_integer(value) or is_float(value) or
              is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp encode_value(:none, _path), do: {:ok, "none"}
  defp encode_value(:high, _path), do: {:ok, "high"}
  defp encode_value(:low, _path), do: {:ok, "low"}
  defp encode_value(:candidate, _path), do: {:ok, "candidate"}
  defp encode_value(:confirmed, _path), do: {:ok, "confirmed"}
  defp encode_value(:up, _path), do: {:ok, "up"}
  defp encode_value(:down, _path), do: {:ok, "down"}
  defp encode_value(:pos, _path), do: {:ok, "pos"}
  defp encode_value(:neg, _path), do: {:ok, "neg"}
  defp encode_value(:insufficient_history, _path), do: {:ok, "insufficient_history"}
  defp encode_value(:calm, _path), do: {:ok, "calm"}
  defp encode_value(:oscillating, _path), do: {:ok, "oscillating"}
  defp encode_value(:persistent_ramp, _path), do: {:ok, "persistent_ramp"}
  defp encode_value(:persistent_step, _path), do: {:ok, "persistent_step"}
  defp encode_value(:mixed, _path), do: {:ok, "mixed"}
  defp encode_value(:no_twd, _path), do: {:ok, "no_twd"}
  defp encode_value(:stale_twd, _path), do: {:ok, "stale_twd"}
  defp encode_value(_value, _path), do: @invalid

  defp encode_queue_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn
      %{age_ms: age_ms, value: value}, {:ok, acc} ->
        {:cont, {:ok, [[age_ms, value] | acc]}}

      _entry, _acc ->
        {:halt, @invalid}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      _ -> @invalid
    end
  end

  defp encode_list_values(values, path) do
    with :ok <- proper_list(values) do
      values
      |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
        case encode_value(value, path) do
          {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
          _ -> {:halt, @invalid}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        _ -> @invalid
      end
    end
  end

  defp wire_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp wire_key(key) when is_binary(key), do: {:ok, key}
  defp wire_key(_key), do: @invalid

  defp decode_snapshot(value) do
    with :ok <- exact_string_keys(value, @top_fields),
         {:ok, authority} <- decode_authority(value["authority"]),
         {:ok, policy} <- decode_policy(value["policy"]),
         {:ok, runtime} <- decode_runtime(value["runtime"]),
         {:ok, stats} <- decode_stats(value["stats"]),
         {:ok, tick} <- rename_map(value["tick"], [{:remaining_ms, "remaining_ms"}]) do
      {:ok,
       %{
         version: value["version"],
         captured_at_utc_ms: value["captured_at_utc_ms"],
         authority: authority,
         policy: policy,
         source_generation: value["source_generation"],
         runtime: runtime,
         stats: stats,
         tick: tick
       }}
    end
  end

  defp decode_authority(value) do
    with :ok <- exact_string_keys(value, @authority_fields),
         {:ok, device_id} <- bytes(value["device_id"]),
         {:ok, storage_epoch} <- bytes(value["storage_epoch"]) do
      {:ok,
       %{
         device_id: device_id,
         credential_epoch: value["credential_epoch"],
         storage_epoch: storage_epoch
       }}
    end
  end

  defp decode_policy(value) do
    with :ok <- exact_string_keys(value, @policy_fields),
         {:ok, windows} <-
           rename_map(value["windows"], [
             {:fast_s, "fast_s"},
             {:mid_s, "mid_s"},
             {:slow_s, "slow_s"},
             {:envelope_s, "envelope_s"}
           ]),
         {:ok, alarms} <-
           rename_map(value["alarms"], [
             {:new_extreme_margin_deg, "new_extreme_margin_deg"},
             {:enabled, "enabled"}
           ]) do
      {:ok,
       %{
         version: value["version"],
         windows: windows,
         alarms: alarms,
         wally_mode: value["wally_mode"],
         sample_ms: value["sample_ms"],
         persist_ms: value["persist_ms"],
         sync_ms: value["sync_ms"],
         timeline_ms: value["timeline_ms"],
         staleness_ms: value["staleness_ms"],
         residual_window: value["residual_window"],
         period_every_ms: value["period_every_ms"],
         xing_hysteresis_deg: value["xing_hysteresis_deg"],
         absorb_dwell_ticks: value["absorb_dwell_ticks"],
         broadcast_rate_ms: value["broadcast_rate_ms"]
       }}
    end
  end

  defp decode_stats(value) do
    with :ok <- exact_string_keys(value, @stats_fields),
         {:ok, reject_reasons} <- decode_reject_reasons(value["reject_reasons"]) do
      {:ok,
       %{
         samples: value["samples"],
         accepted: value["accepted"],
         rejected: value["rejected"],
         reject_reasons: reject_reasons
       }}
    end
  end

  defp decode_reject_reasons(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn
      {"no_twd", count}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, :no_twd, count)}}
      {"stale_twd", count}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, :stale_twd, count)}}
      {_unknown, _count}, _acc -> {:halt, @invalid}
    end)
  end

  defp decode_reject_reasons(_value), do: @invalid

  defp decode_runtime(value) do
    legacy = Map.take(value, ~w(last_summary pending_events pending_timeline seq session))

    with :ok <- exact_string_keys(value, @runtime_fields),
         {:ok, _canonical} <- ContractCheckpoint.canonical_content(:wind_shift, 1, legacy),
         {:ok, session} <- decode_optional(value["session"], &decode_session/1),
         {:ok, pending_timeline} <- decode_list(value["pending_timeline"], &decode_timeline/1),
         {:ok, pending_events} <- decode_list(value["pending_events"], &decode_event/1),
         {:ok, last_summary} <- decode_optional(value["last_summary"], &decode_summary/1),
         {:ok, means} <- decode_means(value["means"]),
         {:ok, envelope} <- decode_envelope(value["envelope"]),
         {:ok, cycle} <- decode_cycle(value["cycle"]),
         {:ok, step} <- decode_step(value["step"]),
         {:ok, unwrap} <- decode_optional(value["unwrap"], &decode_unwrap/1),
         {:ok, residuals} <- decode_residuals(value["residuals"]),
         {:ok, period} <- decode_period(value["period"]),
         {:ok, prev_step_status} <- step_status(value["prev_step_status"]),
         {:ok, prev_regime} <- optional_regime(value["prev_regime"]),
         {:ok, xing} <- decode_xing(value["xing"]),
         {:ok, last_verdict} <- decode_optional(value["last_verdict"], &decode_verdict/1) do
      {:ok,
       %{
         session: session,
         seq: value["seq"],
         pending_timeline: pending_timeline,
         pending_events: pending_events,
         last_summary: last_summary,
         means: means,
         envelope: envelope,
         cycle: cycle,
         step: step,
         unwrap: unwrap,
         residuals: residuals,
         period: period,
         last_period_age_ms: value["last_period_age_ms"],
         last_persist_age_ms: value["last_persist_age_ms"],
         last_sync_age_ms: value["last_sync_age_ms"],
         last_timeline_age_ms: value["last_timeline_age_ms"],
         last_tx_age_ms: value["last_tx_age_ms"],
         t0_age_ms: value["t0_age_ms"],
         last_t_age_ms: value["last_t_age_ms"],
         prev_step_status: prev_step_status,
         prev_regime: prev_regime,
         absorb_count: value["absorb_count"],
         last_tack: value["last_tack"],
         xing: xing,
         last_verdict: last_verdict,
         last_lift: value["last_lift"]
       }}
    end
  end

  defp decode_session(value) do
    rename_map(value, [
      {:started_at_ms, "started_at_ms"},
      {:lat_sum, "lat_sum"},
      {:lon_sum, "lon_sum"},
      {:pos_n, "pos_n"},
      {:tws_sum, "tws_sum"},
      {:tws_n, "tws_n"}
    ])
  end

  defp decode_timeline(value) do
    rename_map(value, [
      {:t_ms, "t_ms"},
      {:mean_twd_deg, "mean_twd_deg"},
      {:phase_deg, "phase_deg"},
      {:amplitude_deg, "amplitude_deg"},
      {:period_s, "period_s"},
      {:trend_deg_per_hr, "trend_deg_per_hr"},
      {:tws_mps, "tws_mps"}
    ])
  end

  defp decode_event(value) do
    with :ok <- exact_string_keys(value, @event_fields),
         {:ok, detail} <- decode_event_detail(value["kind"], value["detail"]) do
      {:ok,
       %{
         t_ms: value["t_ms"],
         kind: value["kind"],
         twd_deg: value["twd_deg"],
         magnitude_deg: value["magnitude_deg"],
         detail: detail
       }}
    end
  end

  defp decode_event_detail("step", value),
    do: rename_map(value, [{:onset_t_ms, "onset_t_ms"}])

  defp decode_event_detail(kind, value) when kind in ["new_high", "new_low"],
    do: rename_map(value, [{:min_deg, "min_deg"}, {:max_deg, "max_deg"}])

  defp decode_event_detail("regime_change", value),
    do: rename_map(value, [{:from, "from"}, {:to, "to"}, {:confidence, "confidence"}])

  defp decode_event_detail(kind, value) when kind in ["header_extreme", "lift_extreme"],
    do: rename_map(value, [{:phase_deg, "phase_deg"}])

  defp decode_event_detail(_kind, _value), do: @invalid

  defp decode_summary(value) do
    rename_map(value, [
      {:mean_twd_deg, "mean_twd_deg"},
      {:trend_deg_per_hr, "trend_deg_per_hr"},
      {:oscillation_period_s, "oscillation_period_s"},
      {:oscillation_amplitude_deg, "oscillation_amplitude_deg"},
      {:regime, "regime"},
      {:tws_mean_mps, "tws_mean_mps"}
    ])
  end

  defp decode_means(value) do
    with :ok <- exact_string_keys(value, @means_fields),
         {:ok, fast} <- decode_optional(value["fast"], &decode_point/1),
         {:ok, mid} <- decode_optional(value["mid"], &decode_point/1),
         {:ok, slow} <- decode_optional(value["slow"], &decode_point/1),
         {:ok, sin} <- decode_optional(value["sin"], &decode_point/1),
         {:ok, cos} <- decode_optional(value["cos"], &decode_point/1) do
      {:ok,
       %{
         tau_fast_s: value["tau_fast_s"],
         tau_mid_s: value["tau_mid_s"],
         tau_slow_s: value["tau_slow_s"],
         fast: fast,
         mid: mid,
         slow: slow,
         sin: sin,
         cos: cos
       }}
    end
  end

  defp decode_point(value), do: rename_map(value, [{:value, "value"}, {:age_ms, "age_ms"}])

  defp decode_envelope(value) do
    with :ok <- exact_string_keys(value, @envelope_fields),
         {:ok, minq} <- decode_chunked_queue(value["minq"]),
         {:ok, maxq} <- decode_chunked_queue(value["maxq"]),
         {:ok, new_extreme} <- extreme(value["new_extreme"]) do
      {:ok,
       %{
         window_ms: value["window_ms"],
         margin_deg: value["margin_deg"],
         debounce_ms: value["debounce_ms"],
         warmup_ms: value["warmup_ms"],
         minq: minq,
         maxq: maxq,
         last_input_deg: value["last_input_deg"],
         last_unwrapped: value["last_unwrapped"],
         first_age_ms: value["first_age_ms"],
         last_alarm_age_ms: value["last_alarm_age_ms"],
         new_extreme: new_extreme
       }}
    end
  end

  defp decode_chunked_queue(value) do
    with :ok <- exact_string_keys(value, @chunked_fields),
         :ok <- nonnegative_u64(value["count"]),
         :ok <- ensure(value["count"] <= @max_envelope_entries),
         :ok <- canonical_chunks(value["chunks"], value["count"]),
         {:ok, chunks, count} <- decode_queue_chunks(value["chunks"]),
         :ok <- ensure(count == value["count"]) do
      {:ok, List.flatten(chunks)}
    end
  end

  defp canonical_chunks([], 0), do: :ok
  defp canonical_chunks([], _count), do: @invalid

  defp canonical_chunks(chunks, count) when is_list(chunks) do
    with :ok <- proper_list(chunks),
         :ok <- ensure(chunks != []),
         :ok <-
           chunks
           |> Enum.with_index()
           |> validate_each(fn {chunk, index} ->
             with :ok <- proper_list(chunk),
                  :ok <- ensure(chunk != []),
                  :ok <- ensure(length(chunk) <= @max_chunk_entries),
                  :ok <- ensure(index == length(chunks) - 1 or length(chunk) == @max_chunk_entries) do
               :ok
             end
           end),
         :ok <- ensure(Enum.sum(Enum.map(chunks, &length/1)) == count) do
      :ok
    end
  end

  defp canonical_chunks(_chunks, _count), do: @invalid

  defp decode_queue_chunks(chunks) when is_list(chunks) do
    with :ok <- proper_list(chunks),
         :ok <- ensure(length(chunks) <= @max_chunk_entries) do
      chunks
      |> Enum.reduce_while({:ok, [], 0}, fn chunk, {:ok, acc, count} ->
        with :ok <- proper_list(chunk),
             :ok <- ensure(chunk != []),
             :ok <- ensure(length(chunk) <= @max_chunk_entries),
             {:ok, decoded} <- decode_list(chunk, &decode_queue_entry/1),
             :ok <- ensure(count + length(decoded) <= @max_envelope_entries) do
          {:cont, {:ok, [decoded | acc], count + length(decoded)}}
        else
          _ -> {:halt, @invalid}
        end
      end)
      |> case do
        {:ok, reversed, count} -> {:ok, Enum.reverse(reversed), count}
        _ -> @invalid
      end
    end
  end

  defp decode_queue_chunks(_chunks), do: @invalid

  defp decode_queue_entry([age_ms, value]), do: {:ok, %{age_ms: age_ms, value: value}}
  defp decode_queue_entry(_value), do: @invalid

  defp decode_cycle(value) do
    rename_map(value, [
      {:omega, "omega"},
      {:rho_per_s, "rho_per_s"},
      {:obs_var, "obs_var"},
      {:q_level_per_s, "q_level_per_s"},
      {:q_slope_per_s, "q_slope_per_s"},
      {:cycle_var, "cycle_var"},
      {:innovation_tau_s, "innovation_tau_s"},
      {:x, "x"},
      {:p, "p"},
      {:innovation_var, "innovation_var"}
    ])
  end

  defp decode_step(value) do
    with :ok <- exact_string_keys(value, @step_fields),
         {:ok, status} <- step_status(value["status"]),
         {:ok, dir} <- direction_enum(value["dir"]) do
      {:ok,
       %{
         delta_deg: value["delta_deg"],
         threshold_deg: value["threshold_deg"],
         band_deg: value["band_deg"],
         settle_s: value["settle_s"],
         min_magnitude_deg: value["min_magnitude_deg"],
         fast_confirm_deg: value["fast_confirm_deg"],
         fast_confirm_s: value["fast_confirm_s"],
         max_confirm_s: value["max_confirm_s"],
         period_hint_s: value["period_hint_s"],
         status: status,
         u: value["u"],
         u_min: value["u_min"],
         u_min_age_ms: value["u_min_age_ms"],
         u_min_t_ms: value["u_min_t_ms"],
         u_sum: value["u_sum"],
         u_n: value["u_n"],
         d: value["d"],
         d_max: value["d_max"],
         d_max_age_ms: value["d_max_age_ms"],
         d_max_t_ms: value["d_max_t_ms"],
         d_sum: value["d_sum"],
         d_n: value["d_n"],
         dir: dir,
         onset_age_ms: value["onset_age_ms"],
         onset_t_ms: value["onset_t_ms"],
         cand_sum: value["cand_sum"],
         cand_n: value["cand_n"],
         magnitude: value["magnitude"]
       }}
    end
  end

  defp decode_unwrap(value) do
    rename_map(value, [
      {:last_input_deg, "last_input_deg"},
      {:last_unwrapped, "last_unwrapped"}
    ])
  end

  defp decode_residuals(value),
    do: rename_map(value, [{:count, "count"}, {:values, "values"}])

  defp decode_period("none"), do: {:ok, :none}
  defp decode_period(value), do: rename_map(value, [{:period_s, "period_s"}, {:confidence, "confidence"}])

  defp decode_xing(value) do
    with :ok <- exact_string_keys(value, @xing_fields),
         {:ok, side} <- xing_side(value["side"]),
         {:ok, extreme} <- decode_optional(value["extreme"], &decode_xing_extreme/1) do
      {:ok, %{side: side, extreme: extreme}}
    end
  end

  defp decode_xing_extreme(value) do
    rename_map(value, [
      {:phase_deg, "phase_deg"},
      {:twd_deg, "twd_deg"},
      {:t_ms, "t_ms"}
    ])
  end

  defp decode_verdict(value) do
    with :ok <- exact_string_keys(value, @verdict_fields),
         {:ok, regime} <- regime(value["regime"]),
         {:ok, oscillation} <- decode_optional(value["oscillation"], &decode_oscillation/1) do
      {:ok,
       %{
         regime: regime,
         confidence: value["confidence"],
         oscillation: oscillation,
         trend_deg_per_hr: value["trend_deg_per_hr"],
         time_to_next_shift_s: value["time_to_next_shift_s"],
         ci_s: value["ci_s"],
         treat_as_persistent: value["treat_as_persistent"],
         regime_alarm: value["regime_alarm"],
         phase_deg: value["phase_deg"]
       }}
    end
  end

  defp decode_oscillation(value) do
    with :ok <- exact_string_keys(value, @oscillation_fields),
         {:ok, time_to_next_header_s} <- decode_tack_map(value["time_to_next_header_s"]),
         {:ok, phase_frac_to_next_header} <- decode_tack_map(value["phase_frac_to_next_header"]) do
      {:ok,
       %{
         period_s: value["period_s"],
         amplitude_deg: value["amplitude_deg"],
         phase_rad: value["phase_rad"],
         time_to_next_header_s: time_to_next_header_s,
         phase_frac_to_next_header: phase_frac_to_next_header
       }}
    end
  end

  defp decode_tack_map(value),
    do: rename_map(value, [{:starboard, "starboard"}, {:port, "port"}])

  defp validate_snapshot(snapshot) do
    with :ok <- ensure(snapshot.version == 1),
         :ok <- nonnegative_u64(snapshot.captured_at_utc_ms),
         :ok <- validate_authority(snapshot.authority),
         :ok <- validate_policy(snapshot.policy),
         :ok <- database_int(snapshot.source_generation),
         :ok <- validate_stats(snapshot.stats),
         :ok <- validate_tick(snapshot.tick, snapshot.policy.sample_ms),
         :ok <-
           validate_runtime(
             snapshot.runtime,
             snapshot.captured_at_utc_ms,
             snapshot.policy.xing_hysteresis_deg
           ) do
      :ok
    end
  end

  defp validate_authority(authority) do
    with :ok <- fixed_binary(authority.device_id, 16),
         :ok <- u32(authority.credential_epoch),
         :ok <- fixed_binary(authority.storage_epoch, 16),
         :ok <- ensure(authority.storage_epoch != <<0::128>>) do
      :ok
    end
  end

  defp validate_policy(policy) do
    with :ok <- nullable_database_int(policy.version),
         :ok <- positive_number(policy.windows.fast_s),
         :ok <- positive_number(policy.windows.mid_s),
         :ok <- positive_number(policy.windows.slow_s),
         :ok <- positive_number(policy.windows.envelope_s),
         :ok <- boolean(policy.alarms.enabled),
         :ok <- nonnegative_number(policy.alarms.new_extreme_margin_deg),
         :ok <- ensure(policy.wally_mode in ["off", "shadow", "on"]),
         :ok <- database_int(policy.sample_ms),
         :ok <- database_int(policy.persist_ms),
         :ok <- database_int(policy.sync_ms),
         :ok <- database_int(policy.timeline_ms),
         :ok <- database_int(policy.staleness_ms),
         :ok <- positive_database_int(policy.residual_window),
         :ok <- positive_database_int(policy.period_every_ms),
         :ok <- ensure(policy.xing_hysteresis_deg === @xing_hysteresis_deg),
         :ok <- positive_database_int(policy.absorb_dwell_ticks),
         :ok <- positive_database_int(policy.broadcast_rate_ms) do
      :ok
    end
  end

  defp validate_stats(stats) do
    with :ok <- database_int(stats.samples),
         :ok <- database_int(stats.accepted),
         :ok <- database_int(stats.rejected),
         :ok <- ensure(stats.accepted + stats.rejected == stats.samples),
         :ok <-
           validate_each(stats.reject_reasons, fn {_reason, count} ->
             with :ok <- positive_database_int(count), do: :ok
           end),
         :ok <- ensure(Enum.sum(Map.values(stats.reject_reasons)) == stats.rejected) do
      :ok
    end
  end

  defp validate_tick(%{remaining_ms: nil}, 0), do: :ok

  defp validate_tick(%{remaining_ms: remaining_ms}, sample_ms)
       when is_integer(sample_ms) and sample_ms > 0 do
    with :ok <- database_int(remaining_ms), :ok <- ensure(remaining_ms <= sample_ms), do: :ok
  end

  defp validate_tick(_tick, _sample_ms), do: @invalid

  defp validate_runtime(runtime, current_utc_ms, xing_hysteresis_deg) do
    with :ok <- validate_means(runtime.means),
         :ok <- validate_envelope(runtime.envelope),
         :ok <- validate_cycle(runtime.cycle),
         :ok <- validate_step(runtime.step, runtime.session),
         :ok <- validate_unwrap(runtime.unwrap),
         :ok <- validate_residuals(runtime.residuals),
         :ok <- validate_period(runtime.period),
         :ok <- nullable_nonnegative_u64(runtime.last_period_age_ms),
         :ok <- nonnegative_u64(runtime.last_persist_age_ms),
         :ok <- nonnegative_u64(runtime.last_sync_age_ms),
         :ok <- nonnegative_u64(runtime.last_timeline_age_ms),
         :ok <- nullable_nonnegative_u64(runtime.last_tx_age_ms),
         :ok <- nullable_nonnegative_u64(runtime.t0_age_ms),
         :ok <- nullable_nonnegative_u64(runtime.last_t_age_ms),
         :ok <- ensure(runtime.absorb_count < 60),
         :ok <- nonnegative_u64(runtime.absorb_count),
         :ok <- validate_tack(runtime.last_tack),
         :ok <-
           validate_xing(runtime.xing, runtime.session, current_utc_ms, xing_hysteresis_deg),
         :ok <- validate_verdict(runtime.last_verdict),
         :ok <- nullable_finite_float(runtime.last_lift),
         :ok <- strictly_increasing_timestamps(runtime.pending_timeline),
         :ok <- unique_terms(runtime.pending_events),
         :ok <- validate_not_future(runtime, current_utc_ms),
         :ok <- validate_runtime_relations(runtime) do
      :ok
    end
  end

  defp validate_means(means) do
    points = [means.fast, means.mid, means.slow, means.sin, means.cos]

    with :ok <- positive_float(means.tau_fast_s),
         :ok <- positive_float(means.tau_mid_s),
         :ok <- positive_float(means.tau_slow_s),
         :ok <- validate_each(points, &validate_point/1),
         :ok <- all_nil_or_present(points),
         :ok <- circular_point(means.fast),
         :ok <- circular_point(means.mid),
         :ok <- circular_point(means.slow),
         :ok <- unit_point(means.sin),
         :ok <- unit_point(means.cos),
         :ok <- same_point_age(points) do
      :ok
    end
  end

  defp validate_point(nil), do: :ok

  defp validate_point(point) do
    with :ok <- finite_float(point.value), :ok <- nonnegative_u64(point.age_ms), do: :ok
  end

  defp validate_envelope(envelope) do
    with :ok <- positive_u64(envelope.window_ms),
         :ok <- nonnegative_float(envelope.margin_deg),
         :ok <- nonnegative_u64(envelope.debounce_ms),
         :ok <- nonnegative_u64(envelope.warmup_ms),
         :ok <- validate_queue(envelope.minq, :min),
         :ok <- validate_queue(envelope.maxq, :max),
         :ok <- nullable_direction(envelope.last_input_deg),
         :ok <- nullable_finite_float(envelope.last_unwrapped),
         :ok <- nullable_nonnegative_u64(envelope.first_age_ms),
         :ok <- nullable_nonnegative_u64(envelope.last_alarm_age_ms),
         :ok <- validate_envelope_relations(envelope) do
      :ok
    end
  end

  defp validate_queue(entries, kind) do
    with :ok <- ensure(length(entries) <= @max_envelope_entries),
         :ok <-
           validate_each(entries, fn entry ->
             with :ok <- nonnegative_u64(entry.age_ms), :ok <- finite_float(entry.value), do: :ok
           end),
         :ok <- ordered_queue_entries(entries, kind) do
      :ok
    end
  end

  defp validate_cycle(cycle) do
    with :ok <- positive_float(cycle.omega),
         :ok <- positive_float(cycle.rho_per_s),
         :ok <- ensure(cycle.rho_per_s <= 1.0),
         :ok <- positive_float(cycle.obs_var),
         :ok <- nonnegative_float(cycle.q_level_per_s),
         :ok <- nonnegative_float(cycle.q_slope_per_s),
         :ok <- nonnegative_float(cycle.cycle_var),
         :ok <- positive_float(cycle.innovation_tau_s),
         :ok <- validate_cycle_state(cycle.x, cycle.p, cycle.innovation_var) do
      :ok
    end
  end

  defp validate_cycle_state(nil, nil, nil), do: :ok

  defp validate_cycle_state(x, p, innovation_var)
       when is_list(x) and is_list(p) and is_float(innovation_var) do
    with :ok <- fixed_float_list(x, 4),
         :ok <- fixed_matrix(p, 4),
         :ok <- nonnegative_float(innovation_var),
         :ok <- positive_semidefinite(p) do
      :ok
    end
  end

  defp validate_cycle_state(_x, _p, _innovation_var), do: @invalid

  defp validate_step(step, session) do
    with :ok <- nonnegative_float(step.delta_deg),
         :ok <- positive_float(step.threshold_deg),
         :ok <- nonnegative_float(step.band_deg),
         :ok <- nonnegative_float(step.settle_s),
         :ok <- nonnegative_float(step.min_magnitude_deg),
         :ok <- nonnegative_float(step.fast_confirm_deg),
         :ok <- nonnegative_float(step.fast_confirm_s),
         :ok <- positive_float(step.max_confirm_s),
         :ok <- nullable_positive_float(step.period_hint_s),
         :ok <- finite_float(step.u),
         :ok <- finite_float(step.u_min),
         :ok <- nullable_nonnegative_u64(step.u_min_age_ms),
         :ok <- nullable_nonnegative_u64(step.u_min_t_ms),
         :ok <- finite_float(step.u_sum),
         :ok <- nonnegative_u64(step.u_n),
         :ok <- finite_float(step.d),
         :ok <- finite_float(step.d_max),
         :ok <- nullable_nonnegative_u64(step.d_max_age_ms),
         :ok <- nullable_nonnegative_u64(step.d_max_t_ms),
         :ok <- finite_float(step.d_sum),
         :ok <- nonnegative_u64(step.d_n),
         :ok <- nullable_nonnegative_u64(step.onset_age_ms),
         :ok <- nullable_nonnegative_u64(step.onset_t_ms),
         :ok <- finite_float(step.cand_sum),
         :ok <- nonnegative_u64(step.cand_n),
         :ok <- nullable_finite_float(step.magnitude),
         :ok <- validate_step_relations(step),
         :ok <- paired_presence(step.u_min_age_ms, step.u_min_t_ms),
         :ok <- paired_presence(step.d_max_age_ms, step.d_max_t_ms),
         :ok <- paired_presence(step.onset_age_ms, step.onset_t_ms),
         :ok <- session_bound_time(step.u_min_t_ms, session),
         :ok <- session_bound_time(step.d_max_t_ms, session),
         :ok <- session_bound_time(step.onset_t_ms, session) do
      :ok
    end
  end

  defp validate_unwrap(nil), do: :ok

  defp validate_unwrap(unwrap) do
    with :ok <- direction(unwrap.last_input_deg), :ok <- finite_float(unwrap.last_unwrapped), do: :ok
  end

  defp validate_residuals(residuals) do
    with :ok <- nonnegative_u64(residuals.count),
         :ok <- proper_list(residuals.values),
         :ok <- ensure(length(residuals.values) <= @max_residuals),
         :ok <- ensure(residuals.count == length(residuals.values)),
         :ok <- validate_each(residuals.values, &finite_float/1) do
      :ok
    end
  end

  defp validate_period(:none), do: :ok

  defp validate_period(period) do
    with :ok <- positive_float(period.period_s), :ok <- probability(period.confidence), do: :ok
  end

  defp validate_tack(nil), do: :ok
  defp validate_tack(value), do: ensure(value in [-1.0, 1.0])

  defp validate_xing(%{side: nil, extreme: nil}, _session, _current_utc_ms, _hysteresis_deg),
    do: :ok

  defp validate_xing(
         %{side: side, extreme: nil},
         _session,
         _current_utc_ms,
         _hysteresis_deg
       )
       when side in [:pos, :neg],
       do: @invalid

  defp validate_xing(%{extreme: _extreme}, nil, _current_utc_ms, _hysteresis_deg),
    do: @invalid

  defp validate_xing(
         %{side: side, extreme: extreme},
         session,
         current_utc_ms,
         hysteresis_deg
       ) do
    with :ok <- finite_float(extreme.phase_deg),
         :ok <- direction(extreme.twd_deg),
         :ok <- nonnegative_u64(extreme.t_ms),
         :ok <- session_bound_time(extreme.t_ms, session),
         :ok <- not_future(extreme.t_ms, current_utc_ms) do
      case side do
        nil -> ensure(abs(extreme.phase_deg) <= hysteresis_deg)
        :pos -> ensure(extreme.phase_deg > hysteresis_deg and extreme.phase_deg <= 180.0)
        :neg -> ensure(extreme.phase_deg < -hysteresis_deg and extreme.phase_deg >= -180.0)
      end
    end
  end

  defp validate_verdict(nil), do: :ok

  defp validate_verdict(verdict) do
    with :ok <- probability(verdict.confidence),
         :ok <- validate_oscillation(verdict.oscillation),
         :ok <- nullable_finite_float(verdict.trend_deg_per_hr),
         :ok <- nullable_nonnegative_float(verdict.time_to_next_shift_s),
         :ok <- nullable_nonnegative_float(verdict.ci_s),
         :ok <- boolean(verdict.treat_as_persistent),
         :ok <- boolean(verdict.regime_alarm),
         :ok <- nullable_phase(verdict.phase_deg) do
      :ok
    end
  end

  defp validate_oscillation(nil), do: :ok

  defp validate_oscillation(oscillation) do
    with :ok <- positive_float(oscillation.period_s),
         :ok <- nonnegative_float(oscillation.amplitude_deg),
         :ok <- finite_float(oscillation.phase_rad),
         :ok <- validate_tack_map(oscillation.time_to_next_header_s, &nonnegative_float/1),
         :ok <- validate_tack_map(oscillation.phase_frac_to_next_header, &probability/1) do
      :ok
    end
  end

  defp validate_tack_map(values, validator) do
    with :ok <- validator.(values.starboard), :ok <- validator.(values.port), do: :ok
  end

  defp validate_not_future(runtime, current_utc_ms) do
    with :ok <- not_future(runtime.session && runtime.session.started_at_ms, current_utc_ms),
         :ok <- validate_each(runtime.pending_timeline, &not_future(&1.t_ms, current_utc_ms)),
         :ok <- validate_each(runtime.pending_events, &not_future(&1.t_ms, current_utc_ms)),
         :ok <- not_future(runtime.step.u_min_t_ms, current_utc_ms),
         :ok <- not_future(runtime.step.d_max_t_ms, current_utc_ms),
         :ok <- not_future(runtime.step.onset_t_ms, current_utc_ms) do
      :ok
    end
  end

  defp validate_runtime_relations(runtime) do
    with :ok <- validate_history_times(runtime.t0_age_ms, runtime.last_period_age_ms, runtime.last_t_age_ms),
         :ok <- validate_learner_presence(runtime),
         :ok <- validate_step_transition(runtime.step.status, runtime.prev_step_status),
         :ok <- validate_cycle_frequency(runtime.cycle, runtime.step),
         :ok <- validate_sessionless_runtime(runtime) do
      :ok
    end
  end

  defp validate_history_times(nil, nil, nil), do: :ok

  defp validate_history_times(t0, period, last)
       when is_integer(t0) and is_integer(period) and is_integer(last) and t0 >= period and period >= last,
       do: :ok

  defp validate_history_times(_t0, _period, _last), do: @invalid

  defp validate_learner_presence(%{means: %{fast: nil}, envelope: %{first_age_ms: nil}, last_t_age_ms: nil} = runtime) do
    ensure(runtime.unwrap == nil and runtime.residuals == %{count: 0, values: []})
  end

  defp validate_learner_presence(%{means: %{fast: point}, last_t_age_ms: last_t_age_ms} = runtime)
       when is_map(point) and is_integer(last_t_age_ms) do
    ensure(
      point.age_ms == last_t_age_ms and latest_queue_age(runtime.envelope) == last_t_age_ms and
        runtime.unwrap != nil and runtime.residuals.count > 0
    )
  end

  defp validate_learner_presence(_runtime), do: @invalid

  defp validate_sessionless_runtime(%{session: nil} = runtime) do
    ensure(
      runtime.unwrap == nil and runtime.residuals == %{count: 0, values: []} and runtime.period == :none and
        is_nil(runtime.last_period_age_ms) and is_nil(runtime.t0_age_ms) and is_nil(runtime.last_t_age_ms) and
        runtime.prev_step_status == :none and is_nil(runtime.prev_regime) and runtime.absorb_count == 0 and
        is_nil(runtime.last_tack) and runtime.xing == %{side: nil, extreme: nil} and
        is_nil(runtime.last_verdict) and is_nil(runtime.last_lift)
    )
  end

  defp validate_sessionless_runtime(_runtime), do: :ok

  defp validate_envelope_relations(envelope) do
    empty? = envelope.minq == [] and envelope.maxq == []
    populated? = envelope.minq != [] and envelope.maxq != []

    cond do
      empty? ->
        ensure(
          is_nil(envelope.last_input_deg) and is_nil(envelope.last_unwrapped) and
            is_nil(envelope.first_age_ms) and is_nil(envelope.last_alarm_age_ms) and
            envelope.new_extreme == :none
        )

      populated? ->
        ensure(
          is_float(envelope.last_input_deg) and is_float(envelope.last_unwrapped) and
            is_integer(envelope.first_age_ms) and
            (is_nil(envelope.last_alarm_age_ms) or envelope.first_age_ms >= envelope.last_alarm_age_ms)
        )

      true ->
        @invalid
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

  defp validate_step_transition(status, status), do: :ok
  defp validate_step_transition(:none, :confirmed), do: :ok
  defp validate_step_transition(_status, _previous), do: @invalid

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
      value_ordered = if kind == :min, do: left.value < right.value, else: left.value > right.value
      ensure(left.age_ms >= right.age_ms and value_ordered)
    end)
  end

  defp strictly_increasing_timestamps([]), do: :ok

  defp strictly_increasing_timestamps([first | rest]) do
    Enum.reduce_while(rest, {:ok, first.t_ms}, fn row, {:ok, previous} ->
      if row.t_ms > previous, do: {:cont, {:ok, row.t_ms}}, else: {:halt, @invalid}
    end)
    |> case do
      {:ok, _last} -> :ok
      _ -> @invalid
    end
  end

  defp unique_terms(values) do
    encoded = Enum.map(values, &:erlang.term_to_binary(&1, [:deterministic]))
    ensure(length(encoded) == MapSet.size(MapSet.new(encoded)))
  end

  defp latest_queue_age(%{minq: []}), do: nil
  defp latest_queue_age(%{minq: entries}), do: List.last(entries).age_ms

  defp all_nil_or_present(values),
    do: ensure(Enum.all?(values, &is_nil/1) or Enum.all?(values, &is_map/1))

  defp same_point_age([nil | _rest]), do: :ok
  defp same_point_age([first | rest]), do: ensure(Enum.all?(rest, &(&1.age_ms == first.age_ms)))
  defp circular_point(nil), do: :ok
  defp circular_point(point), do: ensure(point.value >= 0.0 and point.value < 2.0 * :math.pi())
  defp unit_point(nil), do: :ok
  defp unit_point(point), do: ensure(point.value >= -1.0 and point.value <= 1.0)

  defp paired_presence(nil, nil), do: :ok
  defp paired_presence(age_ms, t_ms) when is_integer(age_ms) and is_integer(t_ms), do: :ok
  defp paired_presence(_age_ms, _t_ms), do: @invalid

  defp session_bound_time(nil, _session), do: :ok
  defp session_bound_time(_t_ms, nil), do: @invalid

  defp session_bound_time(t_ms, session) do
    ensure(t_ms >= session.started_at_ms and div(t_ms, @ms_per_utc_day) == div(session.started_at_ms, @ms_per_utc_day))
  end

  defp not_future(nil, _current_utc_ms), do: :ok
  defp not_future(t_ms, current_utc_ms), do: ensure(t_ms <= current_utc_ms)

  defp fixed_float_list(values, size) when is_list(values) do
    with :ok <- proper_list(values),
         :ok <- ensure(length(values) == size),
         :ok <- validate_each(values, &finite_float/1) do
      :ok
    end
  end

  defp fixed_float_list(_values, _size), do: @invalid

  defp fixed_matrix(rows, size) when is_list(rows) do
    with :ok <- proper_list(rows),
         :ok <- ensure(length(rows) == size),
         :ok <- validate_each(rows, &fixed_float_list(&1, size)) do
      :ok
    end
  end

  defp fixed_matrix(_rows, _size), do: @invalid

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

  defp principal_index_sets(indices), do: Enum.flat_map(1..length(indices), &combinations(indices, &1))
  defp combinations(_values, 0), do: [[]]
  defp combinations([], _count), do: []

  defp combinations([value | rest], count),
    do: Enum.map(combinations(rest, count - 1), &[value | &1]) ++ combinations(rest, count)

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

  defp rename_map(value, fields) do
    with :ok <- exact_string_keys(value, Enum.map(fields, &elem(&1, 1))) do
      {:ok, Map.new(fields, fn {atom_key, string_key} -> {atom_key, Map.fetch!(value, string_key)} end)}
    end
  end

  defp decode_optional(nil, _decoder), do: {:ok, nil}
  defp decode_optional(value, decoder), do: decoder.(value)

  defp decode_list(values, decoder) when is_list(values) do
    with :ok <- proper_list(values) do
      values
      |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
        case decoder.(value) do
          {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
          _ -> {:halt, @invalid}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        _ -> @invalid
      end
    end
  end

  defp decode_list(_values, _decoder), do: @invalid

  defp bytes(%Canonical.Bytes{data: value} = wrapped)
       when is_binary(value) and map_size(wrapped) == 2,
       do: {:ok, value}

  defp bytes(_value), do: @invalid

  defp extreme("none"), do: {:ok, :none}
  defp extreme("high"), do: {:ok, :high}
  defp extreme("low"), do: {:ok, :low}
  defp extreme(_value), do: @invalid

  defp step_status("none"), do: {:ok, :none}
  defp step_status("candidate"), do: {:ok, :candidate}
  defp step_status("confirmed"), do: {:ok, :confirmed}
  defp step_status(_value), do: @invalid

  defp direction_enum(nil), do: {:ok, nil}
  defp direction_enum("up"), do: {:ok, :up}
  defp direction_enum("down"), do: {:ok, :down}
  defp direction_enum(_value), do: @invalid

  defp xing_side(nil), do: {:ok, nil}
  defp xing_side("pos"), do: {:ok, :pos}
  defp xing_side("neg"), do: {:ok, :neg}
  defp xing_side(_value), do: @invalid

  defp optional_regime(nil), do: {:ok, nil}
  defp optional_regime(value), do: regime(value)
  defp regime("insufficient_history"), do: {:ok, :insufficient_history}
  defp regime("calm"), do: {:ok, :calm}
  defp regime("oscillating"), do: {:ok, :oscillating}
  defp regime("persistent_ramp"), do: {:ok, :persistent_ramp}
  defp regime("persistent_step"), do: {:ok, :persistent_step}
  defp regime("mixed"), do: {:ok, :mixed}
  defp regime(_value), do: @invalid

  defp exact_string_keys(value, expected) when is_map(value) and not is_struct(value) do
    keys = Map.keys(value)
    ensure(Enum.all?(keys, &is_binary/1) and Enum.sort(keys) == Enum.sort(expected))
  end

  defp exact_string_keys(_value, _expected), do: @invalid

  defp proper_list([]), do: :ok
  defp proper_list([_head | tail]), do: proper_list(tail)
  defp proper_list(_value), do: @invalid

  defp validate_each(values, validator) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validator.(value) do
        :ok -> {:cont, :ok}
        _ -> {:halt, @invalid}
      end
    end)
  end

  defp finite_number(value) when is_integer(value), do: ensure(abs(value) <= 9_007_199_254_740_991)
  defp finite_number(value) when is_float(value), do: finite_float(value)
  defp finite_number(_value), do: @invalid
  defp positive_number(value), do: with(:ok <- finite_number(value), do: ensure(value > 0))
  defp nonnegative_number(value), do: with(:ok <- finite_number(value), do: ensure(value >= 0))

  defp finite_float(value)
       when is_float(value) and value == value and value >= -@max_finite and value <= @max_finite do
    <<bits::unsigned-big-integer-size(64)>> = <<value::float-big-size(64)>>
    ensure(bits != @negative_zero_bits)
  end

  defp finite_float(_value), do: @invalid
  defp positive_float(value), do: with(:ok <- finite_float(value), do: ensure(value > 0.0))
  defp nonnegative_float(value), do: with(:ok <- finite_float(value), do: ensure(value >= 0.0))
  defp nullable_finite_float(nil), do: :ok
  defp nullable_finite_float(value), do: finite_float(value)
  defp nullable_positive_float(nil), do: :ok
  defp nullable_positive_float(value), do: positive_float(value)
  defp nullable_nonnegative_float(nil), do: :ok
  defp nullable_nonnegative_float(value), do: nonnegative_float(value)

  defp direction(value), do: with(:ok <- finite_float(value), do: ensure(value >= 0.0 and value < 360.0))
  defp nullable_direction(nil), do: :ok
  defp nullable_direction(value), do: direction(value)
  defp nullable_phase(nil), do: :ok
  defp nullable_phase(value), do: with(:ok <- finite_float(value), do: ensure(value >= -180.0 and value <= 180.0))
  defp probability(value), do: with(:ok <- finite_float(value), do: ensure(value >= 0.0 and value <= 1.0))
  defp boolean(value), do: ensure(is_boolean(value))

  defp nonnegative_u64(value) when is_integer(value) and value >= 0 and value <= @u64_max, do: :ok
  defp nonnegative_u64(_value), do: @invalid
  defp positive_u64(value), do: with(:ok <- nonnegative_u64(value), do: ensure(value > 0))
  defp nullable_nonnegative_u64(nil), do: :ok
  defp nullable_nonnegative_u64(value), do: nonnegative_u64(value)
  defp u32(value) when is_integer(value) and value >= 0 and value <= @u32_max, do: :ok
  defp u32(_value), do: @invalid
  defp database_int(value) when is_integer(value) and value >= 0 and value <= @database_int_max, do: :ok
  defp database_int(_value), do: @invalid
  defp positive_database_int(value), do: with(:ok <- database_int(value), do: ensure(value > 0))
  defp nullable_database_int(nil), do: :ok
  defp nullable_database_int(value), do: database_int(value)
  defp fixed_binary(value, size), do: ensure(is_binary(value) and byte_size(value) == size)

  defp ensure(true), do: :ok
  defp ensure(false), do: @invalid
end
