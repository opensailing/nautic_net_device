defmodule RacingOrg.Tracker.Pro.Calibration.Observer.Snapshot do
  @moduledoc """
  Closed internal runtime snapshot for `RacingOrg.Tracker.Pro.Calibration.Observer`.

  The learner remains the canonical `Calibration.Checkpoint` v1 content. Runtime
  state that checkpoint v1 does not own is represented by an exact atom-keyed
  envelope. AWS regime timestamps stay canonical in `:learner`; the closed
  `:learner_time_basis` sidecar carries bounded ages and is validated against the
  canonical rows before hydration rebases them onto the receiver's monotonic
  clock.

  Restore is pure and fail-closed. Cheap shape, authority, policy, collection,
  node, depth, and aggregate binary-byte bounds are checked before hashing or
  canonical hydration. Every returned patch is complete, target-local persistence
  is marked immediately due, and no callback, PID, process name, NMEA metadata,
  secret, or generic metadata is projected.
  """

  alias RacingOrg.Tracker.Pro.Calibration.Checkpoint
  alias RacingOrg.Tracker.Pro.Calibration.Detect.Legs
  alias RacingOrg.Tracker.Pro.Calibration.Detect.Tack
  alias RacingOrg.Tracker.Pro.Calibration.Estimate
  alias RacingOrg.Tracker.Pro.Calibration.Estimate.Tracker
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.AwaOffset
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.AwsScale
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.StwScale
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.UpwashBands
  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare
  alias RacingOrg.Tracker.Pro.RuntimeSnapshot

  @top_fields ~w(
    authority captured_at_utc_ms latest learner learner_time_basis legs policy
    stats sync tack tick version window_binding window_sources
  )a
  @authority_fields [:boat_identifier]
  @policy_fields ~w(
    awa_estimator aws_estimator min_stw_mps modes persist_ms sample_ms
    staleness_ms stw_estimator sync_ms
  )a
  @tracker_config_fields ~w(
    clamp_max clamp_min max_drift max_slew max_spread min_samples stability_window
  )a
  @awa_policy_fields ~w(
    band clamp_max clamp_min classic_max_spread classic_min_samples global light_band
  )a
  @aws_policy_fields [:min_legs, :ratio, :window_s]
  @sync_fields [:last_sync_age_ms, :pending_keys]
  @sync_key_fields [:hardware_identifier, :parameter]
  @latest_fields [:age_ms, :channel, :hardware_identifier, :value]
  @window_source_fields [:awa, :stw]
  @tick_fields [:remaining_ms]
  @stats_fields ~w(
    accepted gybe_pairs legs reciprocal_pairs reject_reasons rejected samples
    source_resets tack_pairs
  )a
  @time_basis_fields [:hardware_identifier, :regimes]
  @regime_basis_fields [:ages_s, :name]
  @persisted_fields [
    :captured_at_utc_ms,
    :last_restore_captured_at_utc_ms,
    :last_restore_digest,
    :learner,
    :learner_time_basis
  ]

  @channels [:awa, :aws, :stw, :heading, :cog, :sog, :heel]
  @regimes [:upwind, :reach, :downwind]
  @reject_reasons [:no_awa, :no_aws, :no_stw, :no_heading, :at_rest]
  @parameters ["awa_offset", "awa_upwash", "stw_scale", "aws_scale"]
  @modes %{
    "awa_offset" => ["off", "shadow", "auto"],
    "awa_upwash" => ["off", "shadow", "auto"],
    "stw_scale" => ["off", "shadow", "auto"],
    "aws_scale" => ["off", "shadow"]
  }

  @max_boat_identifier_bytes 256
  @max_estimators 256
  @max_prev_applied 512
  @max_pending_sync 1_024
  @max_regime_legs 256
  @max_counter 9_007_199_254_740_991
  @max_snapshot_binary_bytes 8_388_608
  @max_tracker_value 1.0e9
  @max_source_speed_mps 655.32
  @max_tws_mps 1_310.64
  @max_roll_deg 188.0
  @basis_tolerance_s 1.0e-6
  @error {:error, :invalid_runtime_snapshot}

  @typedoc "Closed runtime state safe for authenticated external durable ownership."
  @type t :: %{
          required(:version) => pos_integer(),
          required(:captured_at_utc_ms) => non_neg_integer(),
          required(:authority) => %{required(:boat_identifier) => binary()},
          required(:policy) => map(),
          required(:learner) => map(),
          required(:learner_time_basis) => [map()],
          required(:latest) => [map()],
          required(:legs) => Legs.snapshot(),
          required(:tack) => Tack.snapshot(),
          required(:window_binding) => binary(),
          required(:window_sources) => %{required(:awa) => binary(), required(:stw) => binary()} | nil,
          required(:sync) => map(),
          required(:tick) => %{required(:remaining_ms) => non_neg_integer() | nil},
          required(:stats) => map()
        }

  @type restore_patch :: map()

  @doc "Project one live Observer state into the closed runtime shape."
  @spec project(map(), integer(), DateTime.t() | non_neg_integer()) ::
          {:ok, t()} | {:error, :invalid_runtime_snapshot}
  def project(state, captured_at_ms, captured_at_utc)
      when is_map(state) and is_integer(captured_at_ms) do
    with {:ok, captured_at_utc_ms} <- RuntimeSnapshot.utc_ms(captured_at_utc),
         {:ok, authority} <- authority(state),
         {:ok, policy} <- policy(state),
         {:ok, learner} <- learner(state, captured_at_ms),
         {:ok, learner_time_basis} <- project_time_basis(state.aws_estimators, captured_at_ms),
         {:ok, hydrated} <-
           hydrate_and_validate_learner(learner, learner_time_basis, policy, captured_at_ms, 0),
         {:ok, latest} <- project_latest(state.latest, captured_at_ms, state.staleness_ms),
         {:ok, legs} <- Legs.snapshot(state.legs, captured_at_ms),
         {:ok, tack} <- Tack.snapshot(state.tack, captured_at_ms),
         {:ok, window_sources} <- project_window_sources(state.window_sources),
         {:ok, window_binding} <- project_window_binding(legs, tack, window_sources),
         :ok <- validate_runtime_binding(latest, legs, tack, window_sources, hydrated),
         {:ok, current_entries} <- derive_entries(hydrated, state.modes),
         {:ok, sync} <- project_sync(state, current_entries, captured_at_ms),
         {:ok, tick} <- project_tick(state, captured_at_ms),
         :ok <- validate_stats(state.stats) do
      {:ok,
       %{
         version: RuntimeSnapshot.version(),
         captured_at_utc_ms: captured_at_utc_ms,
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
         stats: state.stats
       }}
    else
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  def project(_state, _captured_at_ms, _captured_at_utc), do: @error

  @doc "Cheap closed-shape and size preflight suitable before digesting or hydration."
  @spec preflight(term()) :: :ok | {:error, :invalid_runtime_snapshot}
  def preflight(snapshot) do
    with :ok <- RuntimeSnapshot.exact_keys(snapshot, @top_fields),
         true <- safe_numeric_tree?(snapshot),
         true <- snapshot.version == RuntimeSnapshot.version(),
         {:ok, _captured_at_utc_ms} <- RuntimeSnapshot.utc_ms(snapshot.captured_at_utc_ms),
         :ok <- validate_authority(snapshot.authority),
         :ok <- validate_policy(snapshot.policy),
         :ok <- preflight_learner(snapshot.learner),
         :ok <- RuntimeSnapshot.bounded_list(snapshot.latest, length(@channels)),
         :ok <- preflight_time_basis(snapshot.learner_time_basis),
         :ok <- validate_window_binding(snapshot.legs, snapshot.tack, snapshot.window_sources, snapshot.window_binding),
         :ok <- RuntimeSnapshot.exact_keys(snapshot.sync, @sync_fields),
         :ok <- RuntimeSnapshot.bounded_list(snapshot.sync.pending_keys, @max_pending_sync),
         :ok <- RuntimeSnapshot.exact_keys(snapshot.tick, @tick_fields),
         :ok <- validate_stats(snapshot.stats) do
      :ok
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  @doc "Return a bounded SHA-256 identity for an already preflighted exact snapshot."
  @spec digest(t()) :: {:ok, binary()} | {:error, :invalid_runtime_snapshot}
  def digest(snapshot) do
    with :ok <- preflight(snapshot) do
      {:ok, :crypto.hash(:sha256, :erlang.term_to_binary(snapshot, [:deterministic]))}
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  @doc "Validate and hydrate a complete runtime snapshot against receiver clocks."
  @spec restore(t(), integer(), DateTime.t() | non_neg_integer()) ::
          {:ok, restore_patch()} | {:error, :invalid_runtime_snapshot}
  def restore(snapshot, restored_at_ms, restored_at_utc)
      when is_map(snapshot) and is_integer(restored_at_ms) do
    with :ok <- preflight(snapshot),
         {:ok, captured_at_utc_ms} <- RuntimeSnapshot.utc_ms(snapshot.captured_at_utc_ms),
         {:ok, restored_at_utc_ms} <- RuntimeSnapshot.utc_ms(restored_at_utc),
         {:ok, elapsed_ms} <- RuntimeSnapshot.elapsed_wall_ms(captured_at_utc_ms, restored_at_utc_ms),
         {:ok, learner} <-
           hydrate_and_validate_learner(
             snapshot.learner,
             snapshot.learner_time_basis,
             snapshot.policy,
             restored_at_ms,
             elapsed_ms
           ),
         {:ok, latest} <-
           restore_latest(snapshot.latest, restored_at_ms, snapshot.policy.staleness_ms, elapsed_ms),
         {:ok, legs} <- collapse_detector(Legs.restore(snapshot.legs, restored_at_ms, elapsed_ms)),
         {:ok, tack} <- collapse_detector(Tack.restore(snapshot.tack, restored_at_ms, elapsed_ms)),
         {:ok, window_sources} <- restore_window_sources(snapshot.window_sources),
         :ok <- validate_runtime_binding(latest, snapshot.legs, snapshot.tack, snapshot.window_sources, learner),
         {:ok, current_entries} <- derive_entries(learner, snapshot.policy.modes),
         {:ok, synced, pending_sync, learned_entries, last_sync_ms} <-
           restore_sync(
             snapshot.sync,
             current_entries,
             learner.seq,
             restored_at_ms,
             elapsed_ms,
             snapshot.policy.sync_ms
           ),
         {:ok, tick_delay_ms} <- restore_tick(snapshot.tick, snapshot.policy.sample_ms, elapsed_ms) do
      {:ok,
       Map.merge(learner, %{
         latest: latest,
         legs: legs,
         tack: tack,
         window_sources: window_sources,
         synced: synced,
         pending_sync: pending_sync,
         last_sync_ms: last_sync_ms,
         last_persist_ms: restored_at_ms - snapshot.policy.persist_ms,
         dirty_persist: true,
         tick_delay_ms: tick_delay_ms,
         learned_entries: learned_entries,
         learner_identity: logical_identity(snapshot.learner),
         stats: snapshot.stats
       })}
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
  def authority(%{boat_identifier: boat_identifier}) do
    authority = %{boat_identifier: boat_identifier}
    if validate_authority(authority) == :ok, do: {:ok, authority}, else: @error
  end

  def authority(_state), do: @error

  @doc false
  def policy(state) when is_map(state) do
    with {:ok, awa_estimator} <- awa_policy(AwaOffset.new(state.awa_opts)),
         {:ok, stw_estimator} <- tracker_config(Estimate.new(StwScale.new(state.stw_opts).estimate_opts)),
         aws = AwsScale.new(state.aws_opts),
         {:ok, ratio} <- tracker_config(aws.ratio),
         {:ok, modes} <- normalize_modes(state.modes) do
      policy = %{
        sample_ms: state.sample_ms,
        persist_ms: state.persist_ms,
        sync_ms: state.sync_ms,
        staleness_ms: state.staleness_ms,
        min_stw_mps: state.min_stw_mps,
        modes: modes,
        awa_estimator: awa_estimator,
        stw_estimator: stw_estimator,
        aws_estimator: %{window_s: aws.window_s, min_legs: aws.min_legs, ratio: ratio}
      }

      if validate_policy(policy) == :ok, do: {:ok, policy}, else: @error
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  def policy(_state), do: @error

  @doc false
  def detector_policy(snapshot, state) do
    with true <- snapshot.legs.config == Legs.configuration(state.legs),
         true <- snapshot.tack.config == Tack.configuration(state.tack) do
      :ok
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc false
  def learner(state, _captured_at_ms) when is_map(state) do
    learner = %{
      awa_estimators: state.awa_estimators,
      stw_estimators: state.stw_estimators,
      aws_estimators: state.aws_estimators,
      prev_applied: state.prev_applied,
      seq: state.seq
    }

    case Checkpoint.project(learner) do
      {:ok, content} -> {:ok, content}
      _ -> @error
    end
  rescue
    _ -> @error
  end

  def learner(_state, _captured_at_ms), do: @error

  @doc false
  def learner_identity(state) when is_map(state) do
    with {:ok, content} <- learner(state, 0) do
      {:ok, logical_identity(content)}
    else
      _ -> @error
    end
  end

  @doc false
  def learned_entries(state) when is_map(state) do
    with {:ok, current_entries} <- derive_entries(state, state.modes) do
      {:ok, learned_batch(current_entries)}
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  def learned_entries(_state), do: @error

  @doc false
  def learner_blank?(state) when is_map(state) do
    state.seq == 0 and map_size(state.awa_estimators) == 0 and
      map_size(state.stw_estimators) == 0 and map_size(state.aws_estimators) == 0 and
      map_size(state.prev_applied) == 0
  rescue
    _ -> false
  end

  def learner_blank?(_state), do: false

  @doc false
  def project_persisted(state, captured_at_ms, captured_at_utc, last_restore_digest) do
    with {:ok, captured_at_utc_ms} <- RuntimeSnapshot.utc_ms(captured_at_utc),
         {:ok, policy} <- policy(state),
         {:ok, learner} <- learner(state, captured_at_ms),
         {:ok, learner_time_basis} <- project_time_basis(state.aws_estimators, captured_at_ms),
         {:ok, _hydrated} <-
           hydrate_and_validate_learner(learner, learner_time_basis, policy, captured_at_ms, 0),
         true <- valid_optional_utc_ms?(state.last_restore_captured_at_utc_ms),
         true <- is_nil(last_restore_digest) or valid_digest?(last_restore_digest) do
      {:ok,
       %{
         captured_at_utc_ms: captured_at_utc_ms,
         learner: learner,
         learner_time_basis: learner_time_basis,
         last_restore_captured_at_utc_ms: state.last_restore_captured_at_utc_ms,
         last_restore_digest: last_restore_digest
       }}
    else
      _ -> @error
    end
  end

  @doc false
  def restore_persisted(envelope, state, restored_at_ms, restored_at_utc) do
    with :ok <- RuntimeSnapshot.exact_keys(envelope, @persisted_fields),
         true <- valid_optional_utc_ms?(envelope.last_restore_captured_at_utc_ms),
         true <- is_nil(envelope.last_restore_digest) or valid_digest?(envelope.last_restore_digest),
         {:ok, captured_at_utc_ms} <- RuntimeSnapshot.utc_ms(envelope.captured_at_utc_ms),
         {:ok, restored_at_utc_ms} <- RuntimeSnapshot.utc_ms(restored_at_utc),
         {:ok, elapsed_ms} <- RuntimeSnapshot.elapsed_wall_ms(captured_at_utc_ms, restored_at_utc_ms),
         {:ok, policy} <- policy(state),
         :ok <- preflight_learner(envelope.learner),
         :ok <- preflight_time_basis(envelope.learner_time_basis),
         {:ok, learner} <-
           hydrate_and_validate_learner(
             envelope.learner,
             envelope.learner_time_basis,
             policy,
             restored_at_ms,
             elapsed_ms
           ) do
      {:ok,
       Map.merge(learner, %{
         last_restore_captured_at_utc_ms: envelope.last_restore_captured_at_utc_ms,
         last_restore_digest: envelope.last_restore_digest
       })}
    else
      _ -> @error
    end
  end

  @doc false
  def restore_legacy_learner(legacy, state) do
    with {:ok, content} <- Checkpoint.project(legacy),
         {:ok, policy} <- policy(state),
         {:ok, learner} <- Checkpoint.hydrate(content),
         :ok <- validate_learner_policy(learner, policy),
         :ok <- validate_learner_physical(learner) do
      {:ok,
       Map.merge(learner, %{
         last_restore_captured_at_utc_ms: nil,
         last_restore_digest: nil
       })}
    else
      _ -> @error
    end
  end

  defp preflight_learner(content) do
    with :ok <-
           RuntimeSnapshot.exact_keys(content, [
             "awa_estimators",
             "aws_estimators",
             "prev_applied",
             "seq",
             "stw_estimators"
           ]),
         :ok <- RuntimeSnapshot.bounded_list(content["awa_estimators"], @max_estimators),
         :ok <- RuntimeSnapshot.bounded_list(content["aws_estimators"], @max_estimators),
         :ok <- RuntimeSnapshot.bounded_list(content["stw_estimators"], @max_estimators),
         :ok <- RuntimeSnapshot.bounded_list(content["prev_applied"], @max_prev_applied),
         true <- non_negative_counter(content["seq"]),
         true <- safe_numeric_tree?(content) do
      :ok
    else
      _ -> :error
    end
  end

  defp safe_numeric_tree?(term) do
    match?(
      {:ok, _remaining_nodes, _remaining_binary_bytes},
      safe_numeric_tree(term, 100_000, @max_snapshot_binary_bytes, 0)
    )
  end

  defp safe_numeric_tree(_term, node_budget, _binary_budget, _depth) when node_budget <= 0, do: :error
  defp safe_numeric_tree(_term, _node_budget, binary_budget, _depth) when binary_budget < 0, do: :error
  defp safe_numeric_tree(_term, _node_budget, _binary_budget, depth) when depth > 48, do: :error

  defp safe_numeric_tree(term, node_budget, binary_budget, _depth) when is_atom(term),
    do: {:ok, node_budget - 1, binary_budget}

  defp safe_numeric_tree(term, node_budget, binary_budget, _depth) when is_binary(term) do
    bytes = byte_size(term)

    if bytes <= 1_024 and bytes <= binary_budget,
      do: {:ok, node_budget - 1, binary_budget - bytes},
      else: :error
  end

  defp safe_numeric_tree(term, node_budget, binary_budget, _depth) when is_number(term) do
    if RuntimeSnapshot.finite_between?(term, -@max_counter, @max_counter),
      do: {:ok, node_budget - 1, binary_budget},
      else: :error
  end

  defp safe_numeric_tree(term, node_budget, binary_budget, depth) when is_list(term) do
    with :ok <- RuntimeSnapshot.bounded_list(term, 1_024) do
      reduce_safe_terms(term, node_budget - 1, binary_budget, depth + 1)
    end
  end

  defp safe_numeric_tree(term, node_budget, binary_budget, depth)
       when is_map(term) and not is_struct(term) do
    if map_size(term) <= 64 do
      term
      |> Enum.flat_map(fn {key, value} -> [key, value] end)
      |> reduce_safe_terms(node_budget - 1, binary_budget, depth + 1)
    else
      :error
    end
  end

  defp safe_numeric_tree(term, node_budget, binary_budget, depth) when is_tuple(term) do
    if tuple_size(term) <= 16 do
      term
      |> Tuple.to_list()
      |> reduce_safe_terms(node_budget - 1, binary_budget, depth + 1)
    else
      :error
    end
  end

  defp safe_numeric_tree(_term, _node_budget, _binary_budget, _depth), do: :error

  defp reduce_safe_terms(terms, node_budget, binary_budget, depth) do
    Enum.reduce_while(terms, {:ok, node_budget, binary_budget}, fn
      term, {:ok, remaining_nodes, remaining_binary_bytes} ->
        case safe_numeric_tree(term, remaining_nodes, remaining_binary_bytes, depth) do
          {:ok, next_nodes, next_binary_bytes} ->
            {:cont, {:ok, next_nodes, next_binary_bytes}}

          :error ->
            {:halt, :error}
        end
    end)
  end

  defp hydrate_and_validate_learner(content, time_basis, policy, restored_at_ms, elapsed_ms) do
    with {:ok, learner} <- Checkpoint.hydrate(content),
         :ok <- validate_learner_policy(learner, policy),
         :ok <- validate_learner_physical(learner),
         {:ok, aws_estimators} <-
           restore_aws_estimators(learner.aws_estimators, time_basis, restored_at_ms, elapsed_ms) do
      {:ok, %{learner | aws_estimators: aws_estimators}}
    else
      _ -> @error
    end
  end

  defp validate_learner_policy(learner, policy) do
    with true <-
           Enum.all?(learner.awa_estimators, fn {_id, estimator} ->
             awa_matches_policy?(estimator, policy.awa_estimator)
           end),
         true <-
           Enum.all?(learner.stw_estimators, fn {_id, estimator} ->
             stw_matches_policy?(estimator, policy.stw_estimator)
           end),
         true <-
           Enum.all?(learner.aws_estimators, fn {_id, estimator} ->
             aws_matches_policy?(estimator, policy.aws_estimator)
           end) do
      :ok
    else
      _ -> :error
    end
  end

  defp awa_matches_policy?(%AwaOffset{} = estimator, policy) do
    tracker_config_value(estimator.rotation) == policy.global and
      tracker_config_value(estimator.upwash) == policy.global and
      tracker_config_value(Estimate.new(estimator.bands.band_opts)) == policy.band and
      tracker_config_value(Estimate.new(estimator.bands.light_band_opts)) == policy.light_band and
      estimator.bands.classic_min_samples == policy.classic_min_samples and
      estimator.bands.classic_max_spread == policy.classic_max_spread and
      estimator.bands.clamp_min == policy.clamp_min and estimator.bands.clamp_max == policy.clamp_max and
      Enum.all?(estimator.bands.bands, fn {center, tracker} ->
        expected = if center == 3, do: policy.light_band, else: policy.band
        center in [3, 5, 7, 9, 11, 13] and tracker_config_value(tracker) == expected
      end)
  rescue
    _ -> false
  end

  defp awa_matches_policy?(_estimator, _policy), do: false

  defp stw_matches_policy?(%StwScale{} = estimator, policy) do
    tracker_config_value(Estimate.new(estimator.estimate_opts)) == policy and
      Enum.all?(estimator.bands, fn {center, band} ->
        center in [1, 3, 5, 7, 9] and tracker_config_value(band.estimate) == policy
      end)
  rescue
    _ -> false
  end

  defp stw_matches_policy?(_estimator, _policy), do: false

  defp aws_matches_policy?(%AwsScale{} = estimator, policy) do
    estimator.window_s == policy.window_s and estimator.min_legs == policy.min_legs and
      tracker_config_value(estimator.ratio) == policy.ratio
  rescue
    _ -> false
  end

  defp aws_matches_policy?(_estimator, _policy), do: false

  defp validate_learner_physical(learner) do
    with true <- non_negative_counter(learner.seq),
         true <- map_size(learner.awa_estimators) <= @max_estimators,
         true <- map_size(learner.stw_estimators) <= @max_estimators,
         true <- map_size(learner.aws_estimators) <= @max_estimators,
         true <- map_size(learner.prev_applied) <= @max_prev_applied,
         true <-
           Enum.all?(learner.prev_applied, fn {{id, parameter}, value} ->
             RuntimeSnapshot.canonical_hardware_identifier(id) == :ok and
               parameter in ["awa_offset", "awa_upwash"] and
               RuntimeSnapshot.finite_between?(value, -180.0, 180.0)
           end),
         true <- Enum.all?(learner.awa_estimators, &valid_awa_estimator?/1),
         true <- Enum.all?(learner.stw_estimators, &valid_stw_estimator?/1),
         true <- Enum.all?(learner.aws_estimators, &valid_aws_estimator?/1) do
      :ok
    else
      _ -> :error
    end
  end

  defp valid_awa_estimator?({id, %AwaOffset{} = estimator}) do
    RuntimeSnapshot.canonical_hardware_identifier(id) == :ok and
      non_negative_counter(estimator.pairs_seen) and non_negative_counter(estimator.pairs_skipped) and
      valid_tracker?(estimator.rotation) and valid_tracker?(estimator.upwash) and
      valid_upwash_bands?(estimator.bands)
  end

  defp valid_awa_estimator?(_entry), do: false

  defp valid_upwash_bands?(%UpwashBands{} = bands) do
    non_negative_counter(bands.screened) and non_negative_counter(bands.excluded_light) and
      positive_counter(bands.classic_min_samples) and
      RuntimeSnapshot.finite_between?(bands.classic_max_spread, 0.0, 180.0) and
      RuntimeSnapshot.finite_between_or_nil?(bands.clamp_min, -180.0, 180.0) and
      RuntimeSnapshot.finite_between_or_nil?(bands.clamp_max, -180.0, 180.0) and
      map_size(bands.bands) <= 6 and
      Enum.all?(bands.bands, fn {center, tracker} -> center in [3, 5, 7, 9, 11, 13] and valid_tracker?(tracker) end)
  end

  defp valid_upwash_bands?(_bands), do: false

  defp valid_stw_estimator?({id, %StwScale{} = estimator}) do
    RuntimeSnapshot.canonical_hardware_identifier(id) == :ok and
      non_negative_counter(estimator.pairs_seen) and non_negative_counter(estimator.pairs_skipped) and
      map_size(estimator.bands) <= 5 and
      Enum.all?(estimator.bands, fn {center, band} ->
        center in [1, 3, 5, 7, 9] and RuntimeSnapshot.exact_keys(band, [:estimate, :p, :theta]) == :ok and
          RuntimeSnapshot.finite_between?(band.theta, 0.0, 10.0) and
          RuntimeSnapshot.finite_between?(band.p, 0.0, @max_tracker_value) and valid_tracker?(band.estimate)
      end)
  end

  defp valid_stw_estimator?(_entry), do: false

  defp valid_aws_estimator?({id, %AwsScale{} = estimator}) do
    RuntimeSnapshot.canonical_hardware_identifier(id) == :ok and
      RuntimeSnapshot.finite_between?(estimator.window_s, 0.001, RuntimeSnapshot.max_age_ms() / 1000) and
      positive_counter(estimator.min_legs) and non_negative_counter(estimator.legs_seen) and
      non_negative_counter(estimator.legs_skipped) and valid_tracker?(estimator.ratio) and
      Map.keys(estimator.regimes) |> Enum.sort() == Enum.sort(@regimes) and
      Enum.all?(estimator.regimes, fn {_regime, legs} ->
        RuntimeSnapshot.bounded_list(legs, @max_regime_legs) == :ok and
          Enum.all?(legs, fn {t_end_s, tws_mps} ->
            RuntimeSnapshot.finite_number?(t_end_s) and
              RuntimeSnapshot.finite_between?(tws_mps, 0.0, @max_tws_mps)
          end)
      end)
  rescue
    _ -> false
  end

  defp valid_aws_estimator?(_entry), do: false

  defp valid_tracker?(%Tracker{} = tracker) do
    positive_counter(tracker.min_samples) and positive_counter(tracker.stability_window) and
      non_negative_counter(tracker.count) and
      RuntimeSnapshot.finite_between?(tracker.max_spread, 0.000_000_1, @max_tracker_value) and
      RuntimeSnapshot.finite_between?(tracker.max_drift, 0.0, @max_tracker_value) and
      RuntimeSnapshot.finite_between_or_nil?(tracker.clamp_min, -@max_tracker_value, @max_tracker_value) and
      RuntimeSnapshot.finite_between_or_nil?(tracker.clamp_max, -@max_tracker_value, @max_tracker_value) and
      RuntimeSnapshot.finite_between_or_nil?(tracker.max_slew, 0.0, @max_tracker_value) and
      RuntimeSnapshot.bounded_list(tracker.recent, tracker.stability_window) == :ok and
      Enum.all?(tracker.recent, &RuntimeSnapshot.finite_between?(&1, -@max_tracker_value, @max_tracker_value)) and
      valid_psquare?(tracker.p25) and valid_psquare?(tracker.p50) and valid_psquare?(tracker.p75)
  rescue
    _ -> false
  end

  defp valid_tracker?(_tracker), do: false

  defp valid_psquare?(%PSquare{} = square) do
    RuntimeSnapshot.finite_between?(square.p, 0.0, 1.0) and non_negative_counter(square.count) and
      RuntimeSnapshot.bounded_list(square.buffer, 5) == :ok and
      Enum.all?(square.buffer, &RuntimeSnapshot.finite_between?(&1, -@max_tracker_value, @max_tracker_value)) and
      safe_numeric_tree?(square.q) and safe_numeric_tree?(square.n) and
      safe_numeric_tree?(square.np) and safe_numeric_tree?(square.dnp)
  end

  defp valid_psquare?(_square), do: false

  defp project_time_basis(estimators, captured_at_ms)
       when is_map(estimators) and not is_struct(estimators) do
    captured_at_s = captured_at_ms / 1000

    estimators
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {id, %AwsScale{} = estimator}, {:ok, rows} ->
      result =
        Enum.reduce_while(@regimes, {:ok, []}, fn regime, {:ok, regimes} ->
          ages =
            Enum.reduce_while(estimator.regimes[regime], {:ok, []}, fn {t_end_s, _tws}, {:ok, ages} ->
              case RuntimeSnapshot.validate_age_seconds(captured_at_s - t_end_s) do
                {:ok, age_s} -> {:cont, {:ok, [age_s | ages]}}
                _ -> {:halt, @error}
              end
            end)

          case ages do
            {:ok, values} -> {:cont, {:ok, [%{name: regime, ages_s: Enum.reverse(values)} | regimes]}}
            _ -> {:halt, @error}
          end
        end)

      case result do
        {:ok, regimes} -> {:cont, {:ok, [%{hardware_identifier: id, regimes: Enum.reverse(regimes)} | rows]}}
        _ -> {:halt, @error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      _ -> @error
    end
  rescue
    _ -> @error
  end

  defp project_time_basis(_estimators, _captured_at_ms), do: @error

  defp preflight_time_basis(rows) do
    with :ok <- RuntimeSnapshot.bounded_list(rows, @max_estimators),
         true <-
           Enum.all?(rows, fn row ->
             RuntimeSnapshot.exact_keys(row, @time_basis_fields) == :ok and
               RuntimeSnapshot.canonical_hardware_identifier(row.hardware_identifier) == :ok and
               RuntimeSnapshot.bounded_list(row.regimes, length(@regimes)) == :ok and
               Enum.all?(row.regimes, fn regime ->
                 RuntimeSnapshot.exact_keys(regime, @regime_basis_fields) == :ok and
                   regime.name in @regimes and
                   RuntimeSnapshot.bounded_list(regime.ages_s, @max_regime_legs) == :ok
               end)
           end) do
      :ok
    else
      _ -> :error
    end
  end

  defp restore_aws_estimators(estimators, time_basis, restored_at_ms, elapsed_ms) do
    with :ok <- preflight_time_basis(time_basis),
         true <- Enum.map(time_basis, & &1.hardware_identifier) == estimators |> Map.keys() |> Enum.sort() do
      restored_at_s = restored_at_ms / 1000

      Enum.reduce_while(time_basis, {:ok, %{}}, fn basis, {:ok, restored} ->
        estimator = Map.fetch!(estimators, basis.hardware_identifier)

        case restore_regimes(estimator.regimes, basis.regimes, restored_at_s, elapsed_ms) do
          {:ok, regimes} ->
            {:cont, {:ok, Map.put(restored, basis.hardware_identifier, %{estimator | regimes: regimes})}}

          _ ->
            {:halt, @error}
        end
      end)
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  defp restore_regimes(regimes, basis_rows, restored_at_s, elapsed_ms) do
    with true <- Enum.map(basis_rows, & &1.name) == @regimes do
      Enum.zip(@regimes, basis_rows)
      |> Enum.reduce_while({:ok, %{}, nil}, fn {regime, basis}, {:ok, restored, capture_basis} ->
        legs = regimes[regime]

        with true <- length(legs) == length(basis.ages_s),
             true <- nondecreasing?(basis.ages_s),
             {:ok, restored_legs, capture_basis} <-
               restore_regime_legs(legs, basis.ages_s, restored_at_s, elapsed_ms, capture_basis) do
          {:cont, {:ok, Map.put(restored, regime, restored_legs), capture_basis}}
        else
          _ -> {:halt, @error}
        end
      end)
      |> case do
        {:ok, restored, _capture_basis} -> {:ok, restored}
        _ -> @error
      end
    else
      _ -> @error
    end
  end

  defp restore_regime_legs(legs, ages, restored_at_s, elapsed_ms, capture_basis) do
    Enum.zip(legs, ages)
    |> Enum.reduce_while({:ok, [], capture_basis}, fn {{t_end_s, tws}, age_s}, {:ok, restored, basis} ->
      inferred_basis = t_end_s + age_s

      with true <- RuntimeSnapshot.finite_number?(t_end_s),
           {:ok, _age_s} <- RuntimeSnapshot.validate_age_seconds(age_s),
           true <- is_nil(basis) or abs(inferred_basis - basis) <= @basis_tolerance_s,
           {:ok, effective_age_s} <- RuntimeSnapshot.add_elapsed_seconds(age_s, elapsed_ms) do
        {:cont, {:ok, [{restored_at_s - effective_age_s, tws} | restored], basis || inferred_basis}}
      else
        _ -> {:halt, @error}
      end
    end)
    |> case do
      {:ok, restored, basis} -> {:ok, Enum.reverse(restored), basis}
      _ -> @error
    end
  end

  defp nondecreasing?([]), do: true
  defp nondecreasing?([_one]), do: true
  defp nondecreasing?([a, b | rest]), do: a <= b and nondecreasing?([b | rest])

  defp project_latest(latest, captured_at_ms, staleness_ms)
       when is_map(latest) and not is_struct(latest) and map_size(latest) <= length(@channels) do
    latest
    |> Enum.reduce_while({:ok, []}, fn {channel, value}, {:ok, rows} ->
      with true <- channel in @channels,
           {reading, hardware_identifier, timestamp_ms} <- value,
           true <- valid_channel_value?(channel, reading),
           :ok <- RuntimeSnapshot.canonical_hardware_identifier(hardware_identifier),
           {:ok, age_ms} <- project_stale_age(timestamp_ms, captured_at_ms, staleness_ms) do
        {:cont,
         {:ok,
          [
            %{channel: channel, value: reading, hardware_identifier: hardware_identifier, age_ms: age_ms}
            | rows
          ]}}
      else
        _ -> {:halt, @error}
      end
    end)
    |> case do
      {:ok, rows} ->
        rows = Enum.sort_by(rows, &channel_index(&1.channel))
        if validate_atomic_pairs(rows) == :ok, do: {:ok, rows}, else: @error

      _ ->
        @error
    end
  rescue
    _ -> @error
  end

  defp project_latest(_latest, _captured_at_ms, _staleness_ms), do: @error

  defp restore_latest(rows, restored_at_ms, staleness_ms, elapsed_ms) do
    with :ok <- RuntimeSnapshot.bounded_list(rows, length(@channels)),
         :ok <- strictly_sorted_unique(rows, &channel_index(&1.channel)),
         :ok <- validate_atomic_pairs(rows) do
      Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, latest} ->
        with :ok <- RuntimeSnapshot.exact_keys(row, @latest_fields),
             true <- row.channel in @channels,
             true <- valid_channel_value?(row.channel, row.value),
             :ok <- RuntimeSnapshot.canonical_hardware_identifier(row.hardware_identifier),
             {:ok, age_ms} <- restore_stale_age(row.age_ms, elapsed_ms, staleness_ms) do
          {:cont, {:ok, Map.put(latest, row.channel, {row.value, row.hardware_identifier, restored_at_ms - age_ms})}}
        else
          _ -> {:halt, @error}
        end
      end)
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  defp validate_atomic_pairs(rows) do
    values = Map.new(rows, &{&1.channel, &1})

    with :ok <- paired_rows(values, :awa, :aws),
         :ok <- paired_rows(values, :cog, :sog) do
      :ok
    end
  end

  defp paired_rows(values, first, second) do
    case {Map.get(values, first), Map.get(values, second)} do
      {nil, nil} ->
        :ok

      {%{} = a, %{} = b} ->
        if a.hardware_identifier == b.hardware_identifier and a.age_ms == b.age_ms, do: :ok, else: :error

      _ ->
        :error
    end
  end

  defp valid_channel_value?(:awa, value), do: RuntimeSnapshot.finite_between?(value, -180.0, 180.0)

  defp valid_channel_value?(channel, value) when channel in [:heading, :cog],
    do: RuntimeSnapshot.finite_between?(value, 0.0, 359.999_999_999)

  defp valid_channel_value?(channel, value) when channel in [:aws, :stw, :sog],
    do: RuntimeSnapshot.finite_between?(value, 0.0, @max_source_speed_mps)

  defp valid_channel_value?(:heel, value), do: RuntimeSnapshot.finite_between?(value, -@max_roll_deg, @max_roll_deg)
  defp valid_channel_value?(_channel, _value), do: false

  defp project_window_binding(legs, tack, window_sources) do
    {:ok, window_binding(legs, tack, window_sources)}
  rescue
    _ -> @error
  end

  defp validate_window_binding(legs, tack, window_sources, binding)
       when is_binary(binding) and byte_size(binding) == 32 do
    if binding == window_binding(legs, tack, window_sources), do: :ok, else: :error
  rescue
    _ -> :error
  end

  defp validate_window_binding(_legs, _tack, _window_sources, _binding), do: :error

  defp window_binding(legs, tack, window_sources) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({legs, tack, window_sources}, [:deterministic])
    )
  end

  defp project_window_sources(nil), do: {:ok, nil}

  defp project_window_sources({awa, stw}) do
    sources = %{awa: awa, stw: stw}
    if validate_window_sources(sources) == :ok, do: {:ok, sources}, else: @error
  end

  defp project_window_sources(_sources), do: @error
  defp restore_window_sources(nil), do: {:ok, nil}

  defp restore_window_sources(sources),
    do: if(validate_window_sources(sources) == :ok, do: {:ok, {sources.awa, sources.stw}}, else: @error)

  defp validate_window_sources(sources) do
    with :ok <- RuntimeSnapshot.exact_keys(sources, @window_source_fields),
         :ok <- RuntimeSnapshot.canonical_hardware_identifier(sources.awa),
         :ok <- RuntimeSnapshot.canonical_hardware_identifier(sources.stw) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_runtime_binding(latest, legs, tack, window_sources, learner) do
    active = not is_nil(legs.segment) or legs.pending != [] or not is_nil(tack.pending)
    latest_map = if is_list(latest), do: Map.new(latest, &{&1.channel, &1}), else: latest

    case window_sources do
      nil -> if active, do: :error, else: :ok
      %{awa: awa, stw: stw} -> validate_source_membership(awa, stw, latest_map, learner)
      {awa, stw} -> validate_source_membership(awa, stw, latest_map, learner)
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp validate_source_membership(awa, stw, latest, learner) do
    awa_known =
      channel_id(latest, :awa) == awa or channel_id(latest, :aws) == awa or
        Map.has_key?(learner.awa_estimators, awa) or Map.has_key?(learner.aws_estimators, awa)

    stw_known = channel_id(latest, :stw) == stw or Map.has_key?(learner.stw_estimators, stw)
    if awa_known and stw_known, do: :ok, else: :error
  end

  defp channel_id(latest, channel) do
    case Map.get(latest, channel) do
      %{hardware_identifier: id} -> id
      {_value, id, _timestamp} -> id
      _ -> nil
    end
  end

  defp project_sync(state, current_entries, captured_at_ms) do
    with true <- is_map(state.synced) and is_map(state.pending_sync),
         true <- state.seq != 0 or map_size(state.synced) == 0,
         true <-
           Enum.all?(state.pending_sync, fn {key, entry} ->
             case Map.get(current_entries, key) do
               %{sync: ^entry} -> true
               _ -> false
             end
           end),
         true <- Enum.all?(Map.keys(state.synced), &Map.has_key?(current_entries, &1)),
         {:ok, last_sync_age_ms} <- elapsed_age(state.last_sync_ms, captured_at_ms, state.sync_ms) do
      pending_keys =
        current_entries
        |> Enum.filter(fn {key, _entry} ->
          Map.has_key?(state.pending_sync, key) or
            (not Map.has_key?(state.synced, key) and not Map.has_key?(state.pending_sync, key))
        end)
        |> Enum.map(fn {{hardware_identifier, parameter}, _entry} ->
          %{hardware_identifier: hardware_identifier, parameter: parameter}
        end)
        |> Enum.sort_by(&{&1.hardware_identifier, &1.parameter})

      {:ok, %{pending_keys: pending_keys, last_sync_age_ms: last_sync_age_ms}}
    else
      _ -> @error
    end
  end

  defp restore_sync(sync, current_entries, seq, restored_at_ms, elapsed_ms, sync_ms) do
    with :ok <- RuntimeSnapshot.exact_keys(sync, @sync_fields),
         :ok <- RuntimeSnapshot.bounded_list(sync.pending_keys, @max_pending_sync),
         :ok <- strictly_sorted_unique(sync.pending_keys, &{&1.hardware_identifier, &1.parameter}),
         {:ok, pending_keys} <- restore_pending_keys(sync.pending_keys, current_entries),
         true <- seq != 0 or MapSet.new(Map.keys(current_entries)) == pending_keys,
         {:ok, last_sync_age_ms} <- restore_elapsed(sync.last_sync_age_ms, elapsed_ms, sync_ms) do
      sync_entries = Map.new(current_entries, fn {key, value} -> {key, value.sync} end)
      pending_sync = Map.take(sync_entries, MapSet.to_list(pending_keys))
      synced = Map.drop(sync_entries, MapSet.to_list(pending_keys))

      {:ok, synced, pending_sync, learned_batch(current_entries), restored_at_ms - last_sync_age_ms}
    else
      _ -> @error
    end
  end

  defp restore_pending_keys(rows, current_entries) do
    Enum.reduce_while(rows, {:ok, MapSet.new()}, fn row, {:ok, keys} ->
      with :ok <- RuntimeSnapshot.exact_keys(row, @sync_key_fields),
           :ok <- RuntimeSnapshot.canonical_hardware_identifier(row.hardware_identifier),
           true <- row.parameter in @parameters,
           key = {row.hardware_identifier, row.parameter},
           true <- Map.has_key?(current_entries, key) do
        {:cont, {:ok, MapSet.put(keys, key)}}
      else
        _ -> {:halt, @error}
      end
    end)
  end

  defp learned_batch(current_entries) do
    current_entries
    |> Enum.map(fn {{hardware_identifier, parameter}, value} ->
      %{hardware_identifier: hardware_identifier, parameter: parameter, entry: value.learned}
    end)
    |> Enum.sort_by(&{&1.hardware_identifier, &1.parameter})
  end

  defp derive_entries(learner, modes) do
    state = Map.put(learner, :modes, modes)

    with {:ok, entries} <- derive_awa_entries(state),
         {:ok, entries} <- derive_stw_entries(state, entries),
         {:ok, entries} <- derive_aws_entries(state, entries) do
      {:ok, entries}
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  defp derive_awa_entries(state) do
    Enum.reduce_while(state.awa_estimators, {:ok, %{}}, fn {hex, estimator}, {:ok, entries} ->
      with {:ok, entries} <- derive_awa_scalar(entries, state, hex, "awa_offset", estimator.rotation),
           {:ok, entries} <- derive_upwash(entries, state, hex, estimator) do
        {:cont, {:ok, entries}}
      else
        _ -> {:halt, @error}
      end
    end)
  end

  defp derive_awa_scalar(entries, state, hex, parameter, tracker) do
    snap = Estimate.snapshot(tracker)

    if is_number(snap.value) do
      with {:ok, learned} <- scalar_learned_entry(state, hex, parameter, snap) do
        sync = %{
          hardware_identifier: hex,
          parameter: parameter,
          value: learned.value,
          confidence: learned.confidence,
          sample_count: learned.sample_count,
          state: learned.state,
          residual: snap.spread
        }

        {:ok, Map.put(entries, {hex, parameter}, %{learned: learned, sync: sync})}
      end
    else
      {:ok, entries}
    end
  end

  defp scalar_learned_entry(state, hex, parameter, snap) do
    base = %{confidence: snap.confidence, sample_count: snap.sample_count}

    case {snap.state, Map.get(state.modes, parameter, "off")} do
      {:validated, "auto"} ->
        case Map.fetch(state.prev_applied, {hex, parameter}) do
          {:ok, value} -> {:ok, Map.merge(base, %{value: value, state: "applied"})}
          :error -> @error
        end

      {:validated, "shadow"} ->
        {:ok, Map.merge(base, %{value: snap.value, state: "shadow"})}

      {:validated, _} ->
        {:ok, Map.merge(base, %{value: snap.value, state: "validated"})}

      _ ->
        {:ok, Map.merge(base, %{value: snap.value, state: "learning"})}
    end
  end

  defp derive_upwash(entries, state, hex, estimator) do
    snap = AwaOffset.snapshot(estimator)

    case snap.upwash_curve do
      [] ->
        derive_awa_scalar(entries, state, hex, "awa_upwash", estimator.upwash)

      curve ->
        published = Enum.map(curve, fn {center, _value} -> Map.fetch!(snap.upwash_bands, center) end)
        sample_count = published |> Enum.map(& &1.sample_count) |> Enum.sum()
        confidence = published |> Enum.map(& &1.confidence) |> Enum.min()
        state_s = applied_state(state.modes, "awa_upwash")
        learned = %{value: curve, confidence: confidence, sample_count: sample_count, state: state_s}
        {center, value} = Enum.min_by(curve, fn {center, _value} -> abs(center - 6.17) end)

        sync = %{
          hardware_identifier: hex,
          parameter: "awa_upwash",
          value: value,
          confidence: confidence,
          sample_count: sample_count,
          state: state_s,
          residual: snap.upwash_bands[center].spread,
          curve: Enum.map(curve, fn {c, v} -> %{center: c, value: v} end)
        }

        {:ok, Map.put(entries, {hex, "awa_upwash"}, %{learned: learned, sync: sync})}
    end
  end

  defp derive_stw_entries(state, entries) do
    Enum.reduce_while(state.stw_estimators, {:ok, entries}, fn {hex, estimator}, {:ok, entries} ->
      %{bands: bands} = StwScale.snapshot(estimator)

      if map_size(bands) == 0 do
        {:cont, {:ok, entries}}
      else
        curve = StwScale.gain_curve(estimator)
        {representative_center, representative} = representative_band(bands, curve)

        {learned, sync_value} =
          case curve do
            [] ->
              {%{
                 value: representative.rls,
                 confidence: representative.estimate.confidence,
                 sample_count: representative.estimate.sample_count,
                 state: "learning"
               }, representative.rls}

            _ ->
              sample_count =
                curve
                |> Enum.map(fn {center, _gain} -> bands[center].estimate.sample_count end)
                |> Enum.sum()

              value = curve |> Enum.find(fn {center, _gain} -> center == representative_center end) |> elem(1)

              {%{
                 value: curve,
                 confidence: representative.estimate.confidence,
                 sample_count: sample_count,
                 state: applied_state(state.modes, "stw_scale")
               }, value}
          end

        sync = %{
          hardware_identifier: hex,
          parameter: "stw_scale",
          value: sync_value,
          confidence: learned.confidence,
          sample_count: learned.sample_count,
          state: learned.state,
          residual: representative.estimate.spread,
          curve: Enum.map(curve, fn {center, gain} -> %{center: center, gain: gain} end)
        }

        {:cont, {:ok, Map.put(entries, {hex, "stw_scale"}, %{learned: learned, sync: sync})}}
      end
    end)
  end

  defp derive_aws_entries(state, entries) do
    Enum.reduce_while(state.aws_estimators, {:ok, entries}, fn {hex, estimator}, {:ok, entries} ->
      snap = AwsScale.snapshot(estimator).downwind_over_upwind_ratio

      if is_number(snap.value) do
        state_s =
          case {snap.state, Map.get(state.modes, "aws_scale", "off")} do
            {:validated, "shadow"} -> "shadow"
            {:validated, _} -> "validated"
            _ -> "learning"
          end

        learned = %{value: snap.value, confidence: snap.confidence, sample_count: snap.sample_count, state: state_s}

        sync = %{
          hardware_identifier: hex,
          parameter: "aws_scale",
          value: snap.value,
          confidence: snap.confidence,
          sample_count: snap.sample_count,
          state: state_s,
          residual: snap.spread
        }

        {:cont, {:ok, Map.put(entries, {hex, "aws_scale"}, %{learned: learned, sync: sync})}}
      else
        {:cont, {:ok, entries}}
      end
    end)
  end

  defp applied_state(modes, parameter) do
    case Map.get(modes, parameter, "off") do
      "auto" -> "applied"
      "shadow" -> "shadow"
      _ -> "validated"
    end
  end

  defp representative_band(bands, []) do
    Enum.max_by(bands, fn {_center, band} -> band.estimate.sample_count end)
  end

  defp representative_band(bands, curve) do
    bands
    |> Map.take(Enum.map(curve, &elem(&1, 0)))
    |> Enum.max_by(fn {_center, band} -> band.estimate.sample_count end)
  end

  defp project_tick(%{sample_ms: 0}, _captured_at_ms), do: {:ok, %{remaining_ms: nil}}

  defp project_tick(state, captured_at_ms) when is_integer(state.sample_ms) and state.sample_ms > 0 do
    remaining_ms = state.next_tick_ms - captured_at_ms

    if is_integer(state.next_tick_ms) and remaining_ms <= state.sample_ms do
      {:ok, %{remaining_ms: max(remaining_ms, 0)}}
    else
      @error
    end
  rescue
    _ -> @error
  end

  defp project_tick(_state, _captured_at_ms), do: @error

  defp restore_tick(%{remaining_ms: nil}, 0, _elapsed_ms), do: {:ok, nil}

  defp restore_tick(tick, sample_ms, elapsed_ms) do
    with :ok <- RuntimeSnapshot.exact_keys(tick, @tick_fields),
         true <- is_integer(sample_ms) and sample_ms > 0,
         true <- is_integer(tick.remaining_ms) and tick.remaining_ms >= 0 and tick.remaining_ms <= sample_ms do
      {:ok, max(tick.remaining_ms - elapsed_ms, 0)}
    else
      _ -> @error
    end
  end

  defp validate_authority(authority) do
    with :ok <- RuntimeSnapshot.exact_keys(authority, @authority_fields),
         true <- is_binary(authority.boat_identifier),
         true <- byte_size(authority.boat_identifier) in 1..@max_boat_identifier_bytes do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_policy(policy) do
    with :ok <- RuntimeSnapshot.exact_keys(policy, @policy_fields),
         true <- non_negative_counter(policy.sample_ms),
         true <- non_negative_counter(policy.persist_ms) and policy.persist_ms <= RuntimeSnapshot.max_age_ms(),
         true <- non_negative_counter(policy.sync_ms) and policy.sync_ms <= RuntimeSnapshot.max_age_ms(),
         true <- non_negative_counter(policy.staleness_ms) and policy.staleness_ms < RuntimeSnapshot.max_age_ms(),
         true <- RuntimeSnapshot.finite_between?(policy.min_stw_mps, 0.0, @max_source_speed_mps),
         {:ok, _modes} <- normalize_modes(policy.modes),
         :ok <- validate_awa_policy(policy.awa_estimator),
         :ok <- validate_tracker_config(policy.stw_estimator),
         :ok <- validate_aws_policy(policy.aws_estimator) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_awa_policy(policy) do
    with :ok <- RuntimeSnapshot.exact_keys(policy, @awa_policy_fields),
         :ok <- validate_tracker_config(policy.global),
         :ok <- validate_tracker_config(policy.band),
         :ok <- validate_tracker_config(policy.light_band),
         true <- positive_counter(policy.classic_min_samples),
         true <- RuntimeSnapshot.finite_between?(policy.classic_max_spread, 0.000_000_1, 180.0),
         true <- RuntimeSnapshot.finite_between_or_nil?(policy.clamp_min, -180.0, 180.0),
         true <- RuntimeSnapshot.finite_between_or_nil?(policy.clamp_max, -180.0, 180.0) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_aws_policy(policy) do
    with :ok <- RuntimeSnapshot.exact_keys(policy, @aws_policy_fields),
         true <- RuntimeSnapshot.finite_between?(policy.window_s, 0.001, RuntimeSnapshot.max_age_ms() / 1000),
         true <- positive_counter(policy.min_legs),
         :ok <- validate_tracker_config(policy.ratio) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_tracker_config(config) do
    with :ok <- RuntimeSnapshot.exact_keys(config, @tracker_config_fields),
         true <- positive_counter(config.min_samples),
         true <- positive_counter(config.stability_window),
         true <- RuntimeSnapshot.finite_between?(config.max_spread, 0.000_000_1, @max_tracker_value),
         true <- RuntimeSnapshot.finite_between?(config.max_drift, 0.0, @max_tracker_value),
         true <- RuntimeSnapshot.finite_between_or_nil?(config.clamp_min, -@max_tracker_value, @max_tracker_value),
         true <- RuntimeSnapshot.finite_between_or_nil?(config.clamp_max, -@max_tracker_value, @max_tracker_value),
         true <- RuntimeSnapshot.finite_between_or_nil?(config.max_slew, 0.0, @max_tracker_value) do
      :ok
    else
      _ -> :error
    end
  end

  defp awa_policy(%AwaOffset{} = estimator) do
    with {:ok, global} <- tracker_config(estimator.rotation),
         {:ok, band} <- tracker_config(Estimate.new(estimator.bands.band_opts)),
         {:ok, light_band} <- tracker_config(Estimate.new(estimator.bands.light_band_opts)) do
      {:ok,
       %{
         global: global,
         band: band,
         light_band: light_band,
         classic_min_samples: estimator.bands.classic_min_samples,
         classic_max_spread: estimator.bands.classic_max_spread,
         clamp_min: estimator.bands.clamp_min,
         clamp_max: estimator.bands.clamp_max
       }}
    end
  end

  defp tracker_config(%Tracker{} = tracker) do
    config = tracker_config_value(tracker)
    if validate_tracker_config(config) == :ok, do: {:ok, config}, else: @error
  end

  defp tracker_config_value(%Tracker{} = tracker) do
    Map.take(tracker, @tracker_config_fields)
  end

  defp normalize_modes(modes) when is_map(modes) and not is_struct(modes) do
    if map_size(modes) == map_size(@modes) and
         Enum.all?(@modes, fn {parameter, allowed} -> Map.get(modes, parameter) in allowed end) do
      {:ok, Map.take(modes, Map.keys(@modes))}
    else
      @error
    end
  end

  defp normalize_modes(_modes), do: @error

  defp validate_stats(stats) do
    with :ok <- RuntimeSnapshot.exact_keys(stats, @stats_fields),
         true <- Enum.all?(Map.drop(stats, [:reject_reasons]), fn {_key, value} -> non_negative_counter(value) end),
         true <- is_map(stats.reject_reasons) and not is_struct(stats.reject_reasons),
         true <- map_size(stats.reject_reasons) <= length(@reject_reasons),
         true <-
           Enum.all?(stats.reject_reasons, fn {reason, count} ->
             reason in @reject_reasons and non_negative_counter(count)
           end),
         true <- Enum.sum(Map.values(stats.reject_reasons)) == stats.rejected do
      :ok
    else
      _ -> :error
    end
  end

  defp logical_identity(content) do
    normalized =
      update_in(content, ["aws_estimators"], fn estimators ->
        Enum.map(estimators, fn estimator ->
          update_in(estimator, ["regimes"], fn regimes ->
            Enum.map(regimes, fn regime ->
              update_in(regime, ["legs"], fn legs ->
                Enum.map(legs, &Map.put(&1, "t_end_s", 0.0))
              end)
            end)
          end)
        end)
      end)

    :crypto.hash(:sha256, :erlang.term_to_binary(normalized, [:deterministic]))
  end

  defp valid_digest?(digest), do: is_binary(digest) and byte_size(digest) == 32
  defp valid_optional_utc_ms?(nil), do: true
  defp valid_optional_utc_ms?(value), do: match?({:ok, _utc_ms}, RuntimeSnapshot.utc_ms(value))

  defp project_stale_age(timestamp_ms, captured_at_ms, staleness_ms)
       when is_integer(timestamp_ms) and is_integer(captured_at_ms) and is_integer(staleness_ms) and staleness_ms >= 0 do
    age_ms = captured_at_ms - timestamp_ms
    cap_ms = staleness_ms + 1
    if age_ms >= 0, do: RuntimeSnapshot.advance_capped_age(min(age_ms, cap_ms), 0, cap_ms), else: @error
  end

  defp project_stale_age(_timestamp_ms, _captured_at_ms, _staleness_ms), do: @error

  defp restore_stale_age(age_ms, elapsed_ms, staleness_ms),
    do: RuntimeSnapshot.advance_capped_age(age_ms, elapsed_ms, staleness_ms + 1)

  defp elapsed_age(timestamp_ms, captured_at_ms, interval_ms)
       when is_integer(timestamp_ms) and is_integer(interval_ms) and interval_ms >= 0 do
    age_ms = captured_at_ms - timestamp_ms
    if age_ms >= 0, do: RuntimeSnapshot.advance_capped_age(min(age_ms, interval_ms), 0, interval_ms), else: @error
  end

  defp elapsed_age(_timestamp_ms, _captured_at_ms, _interval_ms), do: @error

  defp restore_elapsed(age_ms, elapsed_ms, interval_ms),
    do: RuntimeSnapshot.advance_capped_age(age_ms, elapsed_ms, interval_ms)

  defp collapse_detector({:ok, detector}), do: {:ok, detector}
  defp collapse_detector(_error), do: @error

  defp strictly_sorted_unique([], _sort_key), do: :ok
  defp strictly_sorted_unique([row | rows], sort_key), do: strictly_sorted_unique(rows, sort_key, sort_key.(row))
  defp strictly_sorted_unique([], _sort_key, _previous), do: :ok

  defp strictly_sorted_unique([row | rows], sort_key, previous) do
    current = sort_key.(row)
    if previous < current, do: strictly_sorted_unique(rows, sort_key, current), else: :error
  rescue
    _ -> :error
  end

  defp channel_index(channel), do: Enum.find_index(@channels, &(&1 == channel))
  defp non_negative_counter(value), do: is_integer(value) and value >= 0 and value <= @max_counter
  defp positive_counter(value), do: is_integer(value) and value > 0 and value <= @max_counter
end
