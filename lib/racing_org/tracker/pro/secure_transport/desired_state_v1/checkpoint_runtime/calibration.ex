defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.Calibration do
  @moduledoc """
  Reversible adapter for the complete Calibration observer runtime checkpoint v2.

  Calibration learner checkpoint v1 remains nested unchanged in `learner`; this
  module owns only the exact runtime envelope and its atom/string/byte
  translations.
  """

  alias RacingOrg.Tracker.Pro.Calibration.Observer.Snapshot
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint, as: ContractCheckpoint

  @invalid {:error, :invalid_checkpoint_content}

  @top_fields ~w(
    authority captured_at_utc_ms latest learner learner_time_basis legs policy
    stats sync tack tick version window_binding window_sources
  )
  @policy_fields ~w(
    awa_estimator aws_estimator min_stw_mps modes persist_ms sample_ms
    staleness_ms stw_estimator sync_ms
  )
  @awa_policy_fields ~w(
    band clamp_max clamp_min classic_max_spread classic_min_samples global light_band
  )
  @aws_policy_fields ~w(min_legs ratio window_s)
  @latest_fields ~w(age_ms channel hardware_identifier value)
  @time_basis_fields ~w(hardware_identifier regimes)
  @regime_basis_fields ~w(ages_s name)
  @legs_fields ~w(config pending segment)
  @legs_config_fields ~w(
    awa_side_min_deg max_gap_ms max_heading_rate_dps max_heading_sd_deg
    max_stw_accel_mps2 min_duration_s pair_window_ms reciprocal_tol_deg
    speed_match_frac
  )
  @segment_fields ~w(
    awa_abs_sum awa_sum aws_sum cog_cos cog_n cog_sin hdg_cos hdg_sin
    heel_n heel_sum last_age_ms last_heading last_stw n side sog_n sog_sum
    started_age_ms stw_sq stw_sum tws_n tws_sq tws_sum
  )
  @leg_fields ~w(
    awa_abs_mean awa_mean_signed aws_mean cog_mean ended_age_ms heading_mean
    heading_sd heel_mean samples sog_mean started_age_ms stw_mean stw_sd
    tws_mean tws_sd
  )
  @tack_fields ~w(config pending)
  @tack_config_fields ~w(
    close_hauled_max_deg gybe_min_awa_deg max_pair_span_s max_transition_s
    min_leg_s min_swing_deg tws_match_mps
  )
  @sync_fields ~w(last_sync_age_ms pending_keys)
  @sync_key_fields ~w(hardware_identifier parameter)
  @stats_fields ~w(
    accepted gybe_pairs legs reciprocal_pairs reject_reasons rejected samples
    source_resets tack_pairs
  )

  @doc "Project one complete internal Calibration Observer snapshot."
  @spec project(term()) ::
          {:ok, map()}
          | {:error, :invalid_checkpoint_content}
          | {:error, :checkpoint_secret_forbidden}
  def project(internal_snapshot) do
    with :ok <- Snapshot.preflight(internal_snapshot),
         {:ok, _restored} <- validate_internal(internal_snapshot),
         {:ok, wire_content} <- encode_value(internal_snapshot, []),
         :ok <- validate(wire_content) do
      {:ok, wire_content}
    else
      {:error, :checkpoint_secret_forbidden} = error -> error
      _ -> @invalid
    end
  rescue
    _ -> @invalid
  catch
    _, _ -> @invalid
  end

  @doc "Hydrate runtime checkpoint v2 into the complete internal Observer snapshot."
  @spec hydrate(term()) ::
          {:ok, map()}
          | {:error, :invalid_checkpoint_content}
          | {:error, :checkpoint_secret_forbidden}
  def hydrate(wire_content) do
    with :ok <- reject_secret_capable(wire_content),
         {:ok, snapshot} <- decode_snapshot(wire_content),
         :ok <- Snapshot.preflight(snapshot),
         {:ok, _restored} <- validate_internal(snapshot),
         :ok <- canonical_texts(wire_content),
         {:ok, _canonical} <- Canonical.encode(wire_content) do
      {:ok, snapshot}
    else
      {:error, :checkpoint_secret_forbidden} = error -> error
      _ -> @invalid
    end
  rescue
    _ -> @invalid
  catch
    _, _ -> @invalid
  end

  @doc "Validate one exact Calibration runtime checkpoint v2 wire value."
  @spec validate(term()) ::
          :ok | {:error, :invalid_checkpoint_content} | {:error, :checkpoint_secret_forbidden}
  def validate(wire_content) do
    with :ok <- reject_secret_capable(wire_content),
         {:ok, snapshot} <- decode_snapshot(wire_content),
         :ok <- Snapshot.preflight(snapshot),
         {:ok, _restored} <- validate_internal(snapshot),
         :ok <- canonical_texts(wire_content),
         {:ok, _canonical} <- Canonical.encode(wire_content) do
      :ok
    else
      {:error, :checkpoint_secret_forbidden} = error -> error
      _ -> @invalid
    end
  rescue
    _ -> @invalid
  catch
    _, _ -> @invalid
  end

  defp validate_internal(snapshot) do
    Snapshot.restore(snapshot, 0, snapshot.captured_at_utc_ms)
  end

  defp encode_value(value, [:window_binding]) when is_binary(value),
    do: {:ok, Canonical.bytes(value)}

  defp encode_value(value, path) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, nested}, {:ok, acc} ->
      with {:ok, wire_key} <- wire_key(key),
           {:ok, wire_value} <- encode_value(nested, [key | path]) do
        {:cont, {:ok, Map.put(acc, wire_key, wire_value)}}
      else
        _ -> {:halt, @invalid}
      end
    end)
  end

  defp encode_value(value, path) when is_list(value) do
    with :ok <- proper_list(value) do
      value
      |> Enum.reduce_while({:ok, []}, fn nested, {:ok, acc} ->
        case encode_value(nested, path) do
          {:ok, wire_value} -> {:cont, {:ok, [wire_value | acc]}}
          _ -> {:halt, @invalid}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        _ -> @invalid
      end
    end
  end

  defp encode_value(nil, _path), do: {:ok, nil}
  defp encode_value(true, _path), do: {:ok, true}
  defp encode_value(false, _path), do: {:ok, false}

  defp encode_value(value, _path)
       when is_binary(value) or is_integer(value) or is_float(value),
       do: {:ok, value}

  defp encode_value(:awa, _path), do: {:ok, "awa"}
  defp encode_value(:aws, _path), do: {:ok, "aws"}
  defp encode_value(:stw, _path), do: {:ok, "stw"}
  defp encode_value(:heading, _path), do: {:ok, "heading"}
  defp encode_value(:cog, _path), do: {:ok, "cog"}
  defp encode_value(:sog, _path), do: {:ok, "sog"}
  defp encode_value(:heel, _path), do: {:ok, "heel"}
  defp encode_value(:upwind, _path), do: {:ok, "upwind"}
  defp encode_value(:reach, _path), do: {:ok, "reach"}
  defp encode_value(:downwind, _path), do: {:ok, "downwind"}
  defp encode_value(:starboard, _path), do: {:ok, "starboard"}
  defp encode_value(:port, _path), do: {:ok, "port"}
  defp encode_value(:no_awa, _path), do: {:ok, "no_awa"}
  defp encode_value(:no_aws, _path), do: {:ok, "no_aws"}
  defp encode_value(:no_stw, _path), do: {:ok, "no_stw"}
  defp encode_value(:no_heading, _path), do: {:ok, "no_heading"}
  defp encode_value(:at_rest, _path), do: {:ok, "at_rest"}
  defp encode_value(_value, _path), do: @invalid

  defp wire_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp wire_key(key) when is_binary(key), do: {:ok, key}
  defp wire_key(_key), do: @invalid

  defp decode_snapshot(value) do
    with :ok <- exact_string_keys(value, @top_fields),
         {:ok, authority} <- rename_map(value["authority"], [{:boat_identifier, "boat_identifier"}]),
         {:ok, policy} <- decode_policy(value["policy"]),
         {:ok, learner} <- decode_learner(value["learner"]),
         {:ok, learner_time_basis} <- decode_list(value["learner_time_basis"], &decode_time_basis/1),
         {:ok, latest} <- decode_list(value["latest"], &decode_latest/1),
         {:ok, legs} <- decode_legs(value["legs"]),
         {:ok, tack} <- decode_tack(value["tack"]),
         {:ok, window_binding} <- bytes(value["window_binding"]),
         {:ok, window_sources} <- decode_optional(value["window_sources"], &decode_window_sources/1),
         {:ok, sync} <- decode_sync(value["sync"]),
         {:ok, tick} <- rename_map(value["tick"], [{:remaining_ms, "remaining_ms"}]),
         {:ok, stats} <- decode_stats(value["stats"]) do
      {:ok,
       %{
         version: value["version"],
         captured_at_utc_ms: value["captured_at_utc_ms"],
         authority: authority,
         policy: policy,
         learner: learner,
         learner_time_basis: learner_time_basis,
         latest: latest,
         legs: legs,
         tack: tack,
         window_binding: window_binding,
         window_sources: window_sources,
         sync: sync,
         tick: tick,
         stats: stats
       }}
    else
      {:error, :checkpoint_secret_forbidden} = error -> error
      _ -> @invalid
    end
  end

  defp decode_policy(value) do
    with :ok <- exact_string_keys(value, @policy_fields),
         {:ok, awa_estimator} <- decode_awa_policy(value["awa_estimator"]),
         {:ok, stw_estimator} <- decode_tracker_config(value["stw_estimator"]),
         {:ok, aws_estimator} <- decode_aws_policy(value["aws_estimator"]),
         {:ok, modes} <- decode_modes(value["modes"]) do
      {:ok,
       %{
         sample_ms: value["sample_ms"],
         persist_ms: value["persist_ms"],
         sync_ms: value["sync_ms"],
         staleness_ms: value["staleness_ms"],
         min_stw_mps: value["min_stw_mps"],
         modes: modes,
         awa_estimator: awa_estimator,
         stw_estimator: stw_estimator,
         aws_estimator: aws_estimator
       }}
    else
      _ -> @invalid
    end
  end

  defp decode_awa_policy(value) do
    with :ok <- exact_string_keys(value, @awa_policy_fields),
         {:ok, global} <- decode_tracker_config(value["global"]),
         {:ok, band} <- decode_tracker_config(value["band"]),
         {:ok, light_band} <- decode_tracker_config(value["light_band"]) do
      {:ok,
       %{
         global: global,
         band: band,
         light_band: light_band,
         classic_min_samples: value["classic_min_samples"],
         classic_max_spread: value["classic_max_spread"],
         clamp_min: value["clamp_min"],
         clamp_max: value["clamp_max"]
       }}
    else
      _ -> @invalid
    end
  end

  defp decode_aws_policy(value) do
    with :ok <- exact_string_keys(value, @aws_policy_fields),
         {:ok, ratio} <- decode_tracker_config(value["ratio"]) do
      {:ok, %{window_s: value["window_s"], min_legs: value["min_legs"], ratio: ratio}}
    else
      _ -> @invalid
    end
  end

  defp decode_tracker_config(value) do
    rename_map(value, [
      {:min_samples, "min_samples"},
      {:max_spread, "max_spread"},
      {:stability_window, "stability_window"},
      {:max_drift, "max_drift"},
      {:clamp_min, "clamp_min"},
      {:clamp_max, "clamp_max"},
      {:max_slew, "max_slew"}
    ])
  end

  defp decode_modes(value) do
    with :ok <- exact_string_keys(value, ~w(awa_offset awa_upwash aws_scale stw_scale)),
         :ok <- mode("awa_offset", value["awa_offset"]),
         :ok <- mode("awa_upwash", value["awa_upwash"]),
         :ok <- mode("stw_scale", value["stw_scale"]),
         :ok <- mode("aws_scale", value["aws_scale"]) do
      {:ok, value}
    else
      _ -> @invalid
    end
  end

  defp mode(parameter, value)
       when parameter in ["awa_offset", "awa_upwash", "stw_scale"] and value in ["off", "shadow", "auto"], do: :ok

  defp mode("aws_scale", value) when value in ["off", "shadow"], do: :ok
  defp mode(_parameter, _value), do: @invalid

  defp decode_learner(value) do
    case ContractCheckpoint.canonical_content(:calibration, 1, value) do
      {:ok, _bytes} -> {:ok, value}
      {:error, :checkpoint_secret_forbidden} = error -> error
      _ -> @invalid
    end
  end

  defp decode_latest(value) do
    with :ok <- exact_string_keys(value, @latest_fields),
         {:ok, channel} <- channel(value["channel"]) do
      {:ok,
       %{
         age_ms: value["age_ms"],
         channel: channel,
         hardware_identifier: value["hardware_identifier"],
         value: value["value"]
       }}
    else
      _ -> @invalid
    end
  end

  defp decode_time_basis(value) do
    with :ok <- exact_string_keys(value, @time_basis_fields),
         {:ok, regimes} <- decode_list(value["regimes"], &decode_regime_basis/1) do
      {:ok, %{hardware_identifier: value["hardware_identifier"], regimes: regimes}}
    else
      _ -> @invalid
    end
  end

  defp decode_regime_basis(value) do
    with :ok <- exact_string_keys(value, @regime_basis_fields),
         {:ok, name} <- regime(value["name"]),
         :ok <- proper_list(value["ages_s"]) do
      {:ok, %{name: name, ages_s: value["ages_s"]}}
    else
      _ -> @invalid
    end
  end

  defp decode_legs(value) do
    with :ok <- exact_string_keys(value, @legs_fields),
         {:ok, config} <- rename_map(value["config"], atom_string_fields(@legs_config_fields)),
         {:ok, segment} <- decode_optional(value["segment"], &decode_segment/1),
         {:ok, pending} <- decode_list(value["pending"], &decode_leg/1) do
      {:ok, %{config: config, segment: segment, pending: pending}}
    else
      _ -> @invalid
    end
  end

  defp decode_segment(value) do
    with :ok <- exact_string_keys(value, @segment_fields),
         {:ok, side} <- side(value["side"]),
         {:ok, segment} <- rename_map(value, atom_string_fields(@segment_fields)) do
      {:ok, %{segment | side: side}}
    else
      _ -> @invalid
    end
  end

  defp decode_leg(value), do: rename_map(value, atom_string_fields(@leg_fields))

  defp decode_tack(value) do
    with :ok <- exact_string_keys(value, @tack_fields),
         {:ok, config} <- rename_map(value["config"], atom_string_fields(@tack_config_fields)),
         {:ok, pending} <- decode_optional(value["pending"], &decode_leg/1) do
      {:ok, %{config: config, pending: pending}}
    else
      _ -> @invalid
    end
  end

  defp decode_window_sources(value) do
    rename_map(value, [{:awa, "awa"}, {:stw, "stw"}])
  end

  defp decode_sync(value) do
    with :ok <- exact_string_keys(value, @sync_fields),
         {:ok, pending_keys} <- decode_list(value["pending_keys"], &decode_sync_key/1) do
      {:ok, %{last_sync_age_ms: value["last_sync_age_ms"], pending_keys: pending_keys}}
    else
      _ -> @invalid
    end
  end

  defp decode_sync_key(value), do: rename_map(value, atom_string_fields(@sync_key_fields))

  defp decode_stats(value) do
    with :ok <- exact_string_keys(value, @stats_fields),
         {:ok, reject_reasons} <- decode_reject_reasons(value["reject_reasons"]),
         {:ok, stats} <- rename_map(value, atom_string_fields(@stats_fields)) do
      {:ok, %{stats | reject_reasons: reject_reasons}}
    else
      _ -> @invalid
    end
  end

  defp decode_reject_reasons(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn
      {"no_awa", count}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, :no_awa, count)}}
      {"no_aws", count}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, :no_aws, count)}}
      {"no_stw", count}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, :no_stw, count)}}
      {"no_heading", count}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, :no_heading, count)}}
      {"at_rest", count}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, :at_rest, count)}}
      {_key, _count}, _acc -> {:halt, @invalid}
    end)
  end

  defp decode_reject_reasons(_value), do: @invalid

  defp channel("awa"), do: {:ok, :awa}
  defp channel("aws"), do: {:ok, :aws}
  defp channel("stw"), do: {:ok, :stw}
  defp channel("heading"), do: {:ok, :heading}
  defp channel("cog"), do: {:ok, :cog}
  defp channel("sog"), do: {:ok, :sog}
  defp channel("heel"), do: {:ok, :heel}
  defp channel(_value), do: @invalid

  defp regime("upwind"), do: {:ok, :upwind}
  defp regime("reach"), do: {:ok, :reach}
  defp regime("downwind"), do: {:ok, :downwind}
  defp regime(_value), do: @invalid

  defp side(nil), do: {:ok, nil}
  defp side("starboard"), do: {:ok, :starboard}
  defp side("port"), do: {:ok, :port}
  defp side(_value), do: @invalid

  defp atom_string_fields(fields),
    do: Enum.map(fields, fn field -> {String.to_existing_atom(field), field} end)

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

  defp exact_string_keys(value, expected) when is_map(value) and not is_struct(value) do
    keys = Map.keys(value)
    if Enum.all?(keys, &is_binary/1) and Enum.sort(keys) == Enum.sort(expected), do: :ok, else: @invalid
  end

  defp exact_string_keys(_value, _expected), do: @invalid

  defp proper_list([]), do: :ok
  defp proper_list([_head | tail]), do: proper_list(tail)
  defp proper_list(_value), do: @invalid

  defp canonical_texts(%Canonical.Bytes{}), do: :ok

  defp canonical_texts(value) when is_binary(value) do
    if String.valid?(value) and String.normalize(value, :nfc) == value, do: :ok, else: @invalid
  end

  defp canonical_texts(value) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, nested}, :ok ->
      with :ok <- canonical_texts(key),
           :ok <- canonical_texts(nested) do
        {:cont, :ok}
      else
        _ -> {:halt, @invalid}
      end
    end)
  end

  defp canonical_texts(value) when is_list(value) do
    with :ok <- proper_list(value) do
      Enum.reduce_while(value, :ok, fn nested, :ok ->
        case canonical_texts(nested) do
          :ok -> {:cont, :ok}
          _ -> {:halt, @invalid}
        end
      end)
    end
  end

  defp canonical_texts(_value), do: :ok

  defp reject_secret_capable(%Canonical.Bytes{} = wrapped) do
    if map_size(wrapped) == 2 and is_binary(wrapped.data), do: :ok, else: @invalid
  end

  defp reject_secret_capable(value) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, nested}, :ok ->
      cond do
        secret_capable_key?(key) ->
          {:halt, {:error, :checkpoint_secret_forbidden}}

        true ->
          case reject_secret_capable(nested) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
      end
    end)
  end

  defp reject_secret_capable(value) when is_list(value), do: reject_secret_list(value)
  defp reject_secret_capable(_value), do: :ok

  defp reject_secret_list([]), do: :ok

  defp reject_secret_list([nested | rest]) do
    with :ok <- reject_secret_capable(nested),
         :ok <- reject_secret_list(rest) do
      :ok
    end
  end

  defp reject_secret_list(_improper_tail), do: :ok

  defp secret_capable_key?(key) when is_atom(key), do: secret_capable_key?(Atom.to_string(key))

  defp secret_capable_key?(key) when is_binary(key) do
    if String.valid?(key) do
      normalized = key |> String.normalize(:nfc) |> String.downcase()

      normalized in ~w(metadata payload raw_payload blob data bytes auth authorization) or
        Enum.any?(
          ~w(psk password passphrase secret credential private_key api_key token),
          &String.contains?(normalized, &1)
        )
    else
      false
    end
  end

  defp secret_capable_key?(_key), do: false
end
