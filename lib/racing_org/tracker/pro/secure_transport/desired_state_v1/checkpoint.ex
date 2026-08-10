defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint do
  @moduledoc """
  Canonical hashing and closed typed content validation for learned-state checkpoints.

  Checkpoint bytes are not an opaque upload format. Version 1 admits only the exact
  normalized calibration, polar, and wind-shift shapes validated here. Every map has a
  closed field set, every collection has typed elements and bounded cardinality, and
  estimator state is checked for structural invariants before it may be hashed or stored.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical

  @device_id_size 16
  @storage_epoch_size 16
  @hash_size 32
  @u32_max 0xFFFF_FFFF
  @u64_max 0xFFFF_FFFF_FFFF_FFFF
  @database_int_max 9_223_372_036_854_775_807
  @max_finite 1.7976931348623157e308
  # Largest integer that still converts to a finite float; beyond it `+ 0.0`
  # raises rather than yielding infinity.
  @max_finite_integer trunc(1.7976931348623157e308)
  # Polar cell indices run 0..u32_max, so an axis may hold at most u32_max + 1
  # bins. Named as a COUNT to keep it distinct from the largest index.
  @polar_axis_bin_count 0xFFFF_FFFF + 1
  @max_estimators 256
  @max_prev_applied 512
  @max_regime_legs 256
  @max_pending_rows 65_535
  @ms_per_utc_day 86_400_000

  @estimate_tracker_fields ~w(
    clamp_max clamp_min count max_drift max_slew max_spread min_samples
    p25 p50 p75 recent stability_window
  )
  @estimate_option_fields ~w(
    clamp_max clamp_min max_drift max_slew max_spread min_samples stability_window
  )
  @p_square_fields ~w(buffer count dnp n np p q)
  @regimes ~w(insufficient_history calm oscillating persistent_ramp persistent_step mixed)

  @doc """
  Canonical bytes for one schema-valid checkpoint value, WITHOUT the single-frame
  capacity cap.

  Content validity and transport capacity are separate verdicts. A checkpoint whose
  closed schema is fully satisfied but whose canonical form exceeds one frame is
  valid content that needs chunked carriage — never invalid content. Callers that
  must place the value in a single frame use `encode_content/3`, which adds the cap
  and reports `:checkpoint_too_large` distinctly.
  """
  def canonical_content(kind, schema_version, content) do
    with {:ok, _kind_code} <- checkpoint_identity(kind, schema_version),
         :ok <- reject_secret_capable(content),
         :ok <- validate_content(kind, content),
         {:ok, bytes} <- Canonical.encode(content) do
      {:ok, bytes}
    end
  end

  @doc "Encode one schema-valid checkpoint value into canonical single-frame bytes."
  def encode_content(kind, schema_version, content) do
    with {:ok, bytes} <- canonical_content(kind, schema_version, content),
         :ok <- checkpoint_size(bytes) do
      {:ok, bytes}
    end
  end

  @doc "Decode canonical checkpoint bytes and revalidate the exact closed content schema."
  def decode_content(kind, schema_version, bytes) when is_binary(bytes) do
    with {:ok, _kind_code} <- checkpoint_identity(kind, schema_version),
         :ok <- checkpoint_size(bytes),
         {:ok, content} <- Canonical.decode(bytes),
         :ok <- reject_secret_capable(content),
         :ok <- validate_content(kind, content),
         {:ok, canonical} <- Canonical.encode(content),
         :ok <- ensure(canonical == bytes, :noncanonical_checkpoint_content) do
      {:ok, content}
    end
  end

  def decode_content(kind, schema_version, _bytes) do
    with {:ok, _kind_code} <- checkpoint_identity(kind, schema_version) do
      {:error, :invalid_checkpoint_content}
    end
  end

  @doc "Hash exact, typed canonical content under the checkpoint-content domain."
  def content_hash(kind, schema_version, bytes) when is_binary(bytes) do
    with {:ok, kind_code} <- checkpoint_identity(kind, schema_version),
         {:ok, _content} <- decode_content(kind, schema_version, bytes) do
      preimage =
        Contract.checkpoint_content_hash_domain() <>
          <<Contract.version(), kind_code, schema_version::16, byte_size(bytes)::64, bytes::binary>>

      {:ok, :crypto.hash(:sha256, preimage)}
    end
  end

  def content_hash(kind, schema_version, _bytes) do
    with {:ok, _kind_code} <- checkpoint_identity(kind, schema_version) do
      {:error, :invalid_checkpoint_content}
    end
  end

  @doc "Hash one exact checkpoint record, including its record-level parent hash."
  def hash(attrs) when is_map(attrs) do
    expected = [
      :device_id,
      :credential_epoch,
      :storage_epoch,
      :sequence,
      :kind,
      :schema_version,
      :source_generation,
      :parent_hash,
      :content_hash
    ]

    with :ok <- exact_atom_keys(attrs, expected, :invalid_checkpoint),
         :ok <- fixed_binary(attrs.device_id, @device_id_size, :invalid_device_id),
         :ok <- u32(attrs.credential_epoch, :invalid_credential_epoch),
         :ok <- nonzero_binary(attrs.storage_epoch, @storage_epoch_size, :invalid_storage_epoch),
         :ok <- positive_database_int(attrs.sequence, :invalid_delivery_sequence),
         {:ok, kind_code} <- checkpoint_identity(attrs.kind, attrs.schema_version),
         :ok <- database_int(attrs.source_generation, :invalid_source_generation),
         :ok <- fixed_binary(attrs.parent_hash, @hash_size, :invalid_parent_hash),
         :ok <- fixed_binary(attrs.content_hash, @hash_size, :invalid_checkpoint_content_hash) do
      preimage =
        Contract.checkpoint_hash_domain() <>
          <<Contract.version(), attrs.device_id::binary-size(@device_id_size), attrs.credential_epoch::32,
            attrs.storage_epoch::binary-size(@storage_epoch_size), attrs.sequence::64, kind_code,
            attrs.schema_version::16, attrs.source_generation::64, attrs.parent_hash::binary-size(@hash_size),
            attrs.content_hash::binary-size(@hash_size)>>

      {:ok, :crypto.hash(:sha256, preimage)}
    end
  end

  def hash(_attrs), do: {:error, :invalid_checkpoint}

  defp checkpoint_identity(kind, schema_version) when is_atom(kind) do
    case Contract.checkpoint_kind(kind) do
      {:ok, code, ^schema_version} -> {:ok, code}
      {:ok, _code, _expected_schema} -> {:error, :unsupported_checkpoint_schema}
      {:error, _reason} = error -> error
    end
  end

  defp checkpoint_identity(_kind, _schema_version), do: {:error, :unknown_checkpoint_kind}

  defp validate_content(:calibration, content), do: validate_calibration(content)
  defp validate_content(:polar, content), do: validate_polar(content)
  defp validate_content(:wind_shift, content), do: validate_wind_shift(content)
  defp validate_content(_kind, _content), do: {:error, :unknown_checkpoint_kind}

  # Calibration checkpoint v1

  defp validate_calibration(content) do
    fields = ~w(awa_estimators aws_estimators prev_applied seq stw_estimators)

    with :ok <- exact_string_keys(content, fields),
         :ok <- nonnegative_u64(content["seq"]),
         :ok <- validate_awa_estimators(content["awa_estimators"]),
         :ok <- validate_stw_estimators(content["stw_estimators"]),
         :ok <- validate_aws_estimators(content["aws_estimators"]),
         :ok <- validate_prev_applied(content["prev_applied"]) do
      :ok
    else
      {:error, :checkpoint_secret_forbidden} = error -> error
      _ -> {:error, :invalid_checkpoint_content}
    end
  end

  defp validate_awa_estimators(estimators) do
    with :ok <- bounded_list(estimators, @max_estimators),
         :ok <- validate_each(estimators, &validate_awa_estimator/1),
         :ok <- strictly_ordered_by(estimators, & &1["hardware_identifier"]) do
      :ok
    end
  end

  defp validate_awa_estimator(estimator) do
    fields = ~w(bands hardware_identifier pairs_seen pairs_skipped rotation upwash)

    with :ok <- exact_string_keys(estimator, fields),
         :ok <- hardware_identifier(estimator["hardware_identifier"]),
         :ok <- nonnegative_u64(estimator["pairs_seen"]),
         :ok <- nonnegative_u64(estimator["pairs_skipped"]),
         :ok <- validate_estimate_tracker(estimator["rotation"], 0.5),
         :ok <- validate_estimate_tracker(estimator["upwash"], 0.5),
         {:ok, band_count, rejected_count} <- validate_upwash_bands(estimator["bands"]),
         :ok <- ensure(estimator["rotation"]["count"] == estimator["pairs_seen"]),
         :ok <- ensure(estimator["upwash"]["count"] == band_count),
         :ok <- ensure(band_count + rejected_count <= estimator["pairs_seen"]) do
      :ok
    end
  end

  defp validate_upwash_bands(bands) do
    fields = ~w(
      band_tracker_options bands clamp_max clamp_min classic_max_spread
      classic_min_samples excluded_light light_band_tracker_options screened
    )

    with :ok <- exact_string_keys(bands, fields),
         :ok <- validate_estimate_options(bands["band_tracker_options"]),
         :ok <- validate_estimate_options(bands["light_band_tracker_options"]),
         :ok <- positive_u64_value(bands["classic_min_samples"]),
         :ok <- positive_float(bands["classic_max_spread"]),
         :ok <- nullable_float(bands["clamp_min"]),
         :ok <- nullable_float(bands["clamp_max"]),
         :ok <- ordered_bounds(bands["clamp_min"], bands["clamp_max"]),
         :ok <- nonnegative_u64(bands["screened"]),
         :ok <- nonnegative_u64(bands["excluded_light"]),
         :ok <- bounded_list(bands["bands"], 6),
         :ok <- validate_each(bands["bands"], &validate_upwash_band(&1, bands)),
         :ok <- strictly_ordered_by(bands["bands"], & &1["center_mps"]),
         :ok <- ensure_options_clamps(bands["band_tracker_options"], bands),
         :ok <- ensure_options_clamps(bands["light_band_tracker_options"], bands) do
      count = Enum.sum(Enum.map(bands["bands"], & &1["tracker"]["count"]))
      {:ok, count, bands["screened"] + bands["excluded_light"]}
    end
  end

  defp validate_upwash_band(band, bands) do
    with :ok <- exact_string_keys(band, ~w(center_mps tracker)),
         :ok <- ensure(band["center_mps"] in [3, 5, 7, 9, 11, 13]),
         :ok <- validate_estimate_tracker(band["tracker"], 0.5),
         options =
           if(band["center_mps"] == 3,
             do: bands["light_band_tracker_options"],
             else: bands["band_tracker_options"]
           ),
         :ok <- ensure_tracker_options(band["tracker"], options) do
      :ok
    end
  end

  defp ensure_options_clamps(options, bands) do
    ensure(
      options["clamp_min"] === bands["clamp_min"] and
        options["clamp_max"] === bands["clamp_max"]
    )
  end

  defp validate_stw_estimators(estimators) do
    with :ok <- bounded_list(estimators, @max_estimators),
         :ok <- validate_each(estimators, &validate_stw_estimator/1),
         :ok <- strictly_ordered_by(estimators, & &1["hardware_identifier"]) do
      :ok
    end
  end

  defp validate_stw_estimator(estimator) do
    fields = ~w(bands estimate_options hardware_identifier pairs_seen pairs_skipped)

    with :ok <- exact_string_keys(estimator, fields),
         :ok <- hardware_identifier(estimator["hardware_identifier"]),
         :ok <- nonnegative_u64(estimator["pairs_seen"]),
         :ok <- nonnegative_u64(estimator["pairs_skipped"]),
         :ok <- validate_estimate_options(estimator["estimate_options"]),
         :ok <- bounded_list(estimator["bands"], 5),
         :ok <-
           validate_each(
             estimator["bands"],
             &validate_stw_band(&1, estimator["estimate_options"])
           ),
         :ok <- strictly_ordered_by(estimator["bands"], & &1["center_mps"]),
         count = Enum.sum(Enum.map(estimator["bands"], & &1["estimate"]["count"])),
         :ok <- ensure(count == estimator["pairs_seen"]) do
      :ok
    end
  end

  defp validate_stw_band(band, options) do
    fields = ~w(center_mps estimate p theta)

    with :ok <- exact_string_keys(band, fields),
         :ok <- ensure(band["center_mps"] in [1, 3, 5, 7, 9]),
         :ok <- positive_float(band["theta"]),
         :ok <- positive_float(band["p"]),
         :ok <- validate_estimate_tracker(band["estimate"], 0.5),
         :ok <- ensure_tracker_options(band["estimate"], options) do
      :ok
    end
  end

  defp validate_aws_estimators(estimators) do
    with :ok <- bounded_list(estimators, @max_estimators),
         :ok <- validate_each(estimators, &validate_aws_estimator/1),
         :ok <- strictly_ordered_by(estimators, & &1["hardware_identifier"]) do
      :ok
    end
  end

  defp validate_aws_estimator(estimator) do
    fields = ~w(
      hardware_identifier legs_seen legs_skipped min_legs ratio regimes window_s
    )

    with :ok <- exact_string_keys(estimator, fields),
         :ok <- hardware_identifier(estimator["hardware_identifier"]),
         :ok <- nonnegative_u64(estimator["legs_seen"]),
         :ok <- nonnegative_u64(estimator["legs_skipped"]),
         :ok <- positive_u64_value(estimator["min_legs"]),
         :ok <- ensure(estimator["min_legs"] <= @max_regime_legs),
         :ok <- positive_float(estimator["window_s"]),
         :ok <- validate_estimate_tracker(estimator["ratio"], 0.5),
         {:ok, retained, times} <- validate_regimes(estimator["regimes"]),
         :ok <- ensure(retained <= estimator["legs_seen"]),
         :ok <- ensure(estimator["ratio"]["count"] <= estimator["legs_seen"]),
         :ok <- validate_regime_window(times, estimator["window_s"]) do
      :ok
    end
  end

  defp validate_regimes(regimes) do
    with :ok <- bounded_list(regimes, 3),
         :ok <- validate_each(regimes, &validate_regime/1),
         :ok <- ensure(Enum.map(regimes, & &1["name"]) == ~w(upwind reach downwind)) do
      legs = Enum.flat_map(regimes, & &1["legs"])
      {:ok, length(legs), Enum.map(legs, & &1["t_end_s"])}
    end
  end

  defp validate_regime(regime) do
    with :ok <- exact_string_keys(regime, ~w(legs name)),
         :ok <- ensure(regime["name"] in ~w(upwind reach downwind)),
         :ok <- bounded_list(regime["legs"], @max_regime_legs),
         :ok <- validate_each(regime["legs"], &validate_regime_leg/1),
         :ok <- nonincreasing_by(regime["legs"], & &1["t_end_s"]) do
      :ok
    end
  end

  defp validate_regime_leg(leg) do
    with :ok <- exact_string_keys(leg, ~w(t_end_s tws_mps)),
         :ok <- finite_float(leg["t_end_s"]),
         :ok <- nonnegative_float(leg["tws_mps"]) do
      :ok
    end
  end

  defp validate_regime_window([], _window_s), do: :ok

  defp validate_regime_window(times, window_s) do
    minimum = Enum.min(times)
    maximum = Enum.max(times)

    ensure(regime_span_within_window?(minimum, maximum, window_s))
  end

  defp regime_span_within_window?(minimum, maximum, window_s)
       when minimum < 0.0 and maximum > 0.0,
       do: maximum <= minimum + window_s

  defp regime_span_within_window?(minimum, maximum, window_s),
    do: maximum - minimum <= window_s

  defp validate_prev_applied(entries) do
    with :ok <- bounded_list(entries, @max_prev_applied),
         :ok <- validate_each(entries, &validate_prev_applied_entry/1),
         :ok <- strictly_ordered_by(entries, &{&1["hardware_identifier"], &1["parameter"]}) do
      :ok
    end
  end

  defp validate_prev_applied_entry(entry) do
    with :ok <- exact_string_keys(entry, ~w(hardware_identifier parameter value)),
         :ok <- hardware_identifier(entry["hardware_identifier"]),
         :ok <- ensure(entry["parameter"] in ~w(awa_offset awa_upwash)),
         :ok <- finite_float(entry["value"]) do
      :ok
    end
  end

  # Polar checkpoint v2
  #
  # A polar cell key is a BARE `{tws_bin, twa_bin}` index pair. An index means
  # nothing without the grid that minted it, so the content binds the exact
  # producing geometry (`tws_width_mps`, `twa_width_deg`, `max_tws_mps`) and the
  # ONE quantile probability every cell was accumulated at. Every cell key must
  # fall inside that declared finite grid, and every per-cell field the grid or
  # the cell count already determines is absent rather than repeated:
  #
  #   * `p`     — one global value; a per-cell copy could disagree with it.
  #   * `count` — the cell's own count is the estimator's sample count.
  #   * `dnp`   — exactly `[0, p/2, p, (1+p)/2, 1]`, a pure function of `p`.
  #   * `n[0]`  — always 1; `n[4]` — always the cell count.
  #
  # `np` is NOT reconstructible (it depends on the whole update history), and
  # neither is `q` or the warmup `buffer`, so all three are carried verbatim.

  @polar_axis_fields ~w(max_tws_mps twa_width_deg tws_width_mps)
  @polar_quantile_fields ~w(buffer n np q)
  @polar_interior_markers 3

  defp validate_polar(content) do
    with :ok <- exact_string_keys(content, ["cells", "p" | @polar_axis_fields]),
         :ok <- between_float(content["p"], 0.0, 1.0, exclusive: true),
         :ok <- positive_float(content["tws_width_mps"]),
         :ok <- positive_float(content["twa_width_deg"]),
         :ok <- positive_float(content["max_tws_mps"]),
         {:ok, grid} <- polar_grid(content),
         :ok <- bounded_list(content["cells"], @max_pending_rows),
         :ok <- validate_each(content["cells"], &validate_polar_cell(&1, content["p"], grid)),
         :ok <- strictly_ordered_by(content["cells"], &{&1["tws_bin"], &1["twa_bin"]}) do
      :ok
    else
      {:error, :checkpoint_secret_forbidden} = error -> error
      _ -> {:error, :invalid_checkpoint_content}
    end
  end

  # The inclusive upper index corner of the declared grid, mirroring
  # `Polar.Observer.Bins.max_key/1` exactly. Both axes must stay inside u32 so
  # every admissible key is representable on the wire.
  defp polar_grid(content) do
    with {:ok, max_tws_bin} <- polar_axis_bins(content["max_tws_mps"], content["tws_width_mps"]),
         {:ok, max_twa_bin} <- polar_axis_bins(180.0, content["twa_width_deg"]) do
      {:ok, {max_tws_bin, max_twa_bin}}
    end
  end

  @doc """
  The largest bin index an axis of `extent` divided into `width` bins can produce,
  or `{:error, :invalid_checkpoint_content}` when that index space does not fit u32.

  Indices run `0..u32_max`, so the admissible BIN COUNT is `u32_max + 1` and the
  largest admissible index is `u32_max`. Both bounds are stated in those terms
  here and in `Polar.Observer.Bins` so the wire grid and the runtime grid admit
  exactly the same geometries — a disagreement at the boundary would mean a
  sailed polar a device can legally accumulate cannot be checkpointed.

  The width is bounded BEFORE the division, not after. `extent / width` for a
  finite but unboundedly small width overflows to `+Inf`, and float overflow
  RAISES `ArithmeticError` on the BEAM — so a check on the quotient never runs,
  and hostile geometry crashes the validator instead of being rejected by it.
  Dividing the extent by the large `@polar_axis_bin_count` constant cannot
  overflow (it can only underflow toward zero), which makes the minimum
  representable width safe to compute for any finite extent.

  Total: this function is public and shared, so it is reachable with whatever a
  caller holds. Non-number, non-finite, and non-positive terms fail closed
  rather than surfacing an arithmetic fault.
  """
  @spec polar_axis_bins(term(), term()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_checkpoint_content}
  def polar_axis_bins(extent, width) do
    with :ok <- ensure(finite_positive_number?(extent)),
         :ok <- ensure(finite_positive_number?(width)),
         extent = extent + 0.0,
         width = width + 0.0,
         :ok <- ensure(width >= extent / @polar_axis_bin_count),
         ratio = extent / width,
         :ok <- ensure(ratio <= @polar_axis_bin_count) do
      {:ok, min(max(trunc(:math.ceil(ratio)) - 1, 0), @u32_max)}
    end
  end

  # An integer is only "finite" here if it survives conversion to a float: every
  # integer satisfies `is_integer/1`, but one beyond the float range raises the
  # moment `+ 0.0` converts it.
  defp finite_positive_number?(value) when is_float(value),
    do: value == value and value > 0.0 and value <= @max_finite

  defp finite_positive_number?(value) when is_integer(value),
    do: value > 0 and value <= @max_finite_integer

  defp finite_positive_number?(_value), do: false

  defp validate_polar_cell(cell, p, {max_tws_bin, max_twa_bin}) do
    with :ok <- exact_string_keys(cell, ~w(count quantile twa_bin tws_bin)),
         :ok <- positive_u64_value(cell["count"]),
         :ok <- u32_value(cell["twa_bin"]),
         :ok <- u32_value(cell["tws_bin"]),
         :ok <- ensure(cell["tws_bin"] <= max_tws_bin),
         :ok <- ensure(cell["twa_bin"] <= max_twa_bin),
         :ok <- validate_polar_quantile(cell["quantile"], p, cell["count"]),
         :ok <- nonnegative_p_square_values(cell["quantile"]) do
      :ok
    end
  end

  # Warmup phase: fewer than five samples, so no markers exist yet and the whole
  # estimator is its sorted buffer.
  defp validate_polar_quantile(quantile, _p, count) when count < 5 do
    with :ok <- exact_string_keys(quantile, @polar_quantile_fields),
         :ok <- bounded_list(quantile["buffer"], 4),
         :ok <- ensure(length(quantile["buffer"]) == count),
         :ok <- validate_each(quantile["buffer"], &finite_float/1),
         :ok <- nondecreasing(quantile["buffer"]),
         :ok <- ensure(is_nil(quantile["q"])),
         :ok <- ensure(is_nil(quantile["n"])),
         :ok <- ensure(is_nil(quantile["np"])) do
      :ok
    end
  end

  # Marker phase. `n` carries ONLY the three interior actual positions; the two
  # endpoints are re-derived here and the full five-marker invariants are checked
  # against the reconstruction, so a compact encoding is accepted only when it
  # decodes back to exactly one well-formed estimator.
  defp validate_polar_quantile(quantile, p, count) do
    with :ok <- exact_string_keys(quantile, @polar_quantile_fields),
         :ok <- ensure(quantile["buffer"] == []),
         :ok <- exact_length_list(quantile["q"], 5),
         :ok <- validate_each(quantile["q"], &finite_float/1),
         :ok <- nondecreasing(quantile["q"]),
         :ok <- exact_length_list(quantile["n"], @polar_interior_markers),
         :ok <- validate_each(quantile["n"], &positive_u64_value/1),
         n = [1 | quantile["n"]] ++ [count],
         :ok <- strictly_increasing(n),
         :ok <- ensure(List.last(quantile["n"]) < count),
         :ok <- exact_length_list(quantile["np"], 5),
         :ok <- validate_each(quantile["np"], &finite_float/1),
         :ok <- nondecreasing(quantile["np"]),
         :ok <- approximate_vector(quantile["np"], expected_np(p, count)) do
      :ok
    end
  end

  # Wind-shift checkpoint v1

  defp validate_wind_shift(content) do
    fields = ~w(last_summary pending_events pending_timeline seq session)

    with :ok <- exact_string_keys(content, fields),
         :ok <- nonnegative_u64(content["seq"]),
         :ok <- validate_session(content["session"]),
         :ok <- validate_timeline(content["pending_timeline"]),
         :ok <- validate_events(content["pending_events"]),
         :ok <- validate_summary(content["last_summary"]),
         :ok <- validate_session_binding(content) do
      :ok
    else
      {:error, :checkpoint_secret_forbidden} = error -> error
      _ -> {:error, :invalid_checkpoint_content}
    end
  end

  defp validate_session(nil), do: :ok

  defp validate_session(session) do
    fields = ~w(lat_sum lon_sum pos_n started_at_ms tws_n tws_sum)

    with :ok <- exact_string_keys(session, fields),
         :ok <- nonnegative_u64(session["started_at_ms"]),
         :ok <- nonnegative_u64(session["pos_n"]),
         :ok <- nonnegative_u64(session["tws_n"]),
         :ok <- finite_float(session["lat_sum"]),
         :ok <- finite_float(session["lon_sum"]),
         :ok <- nonnegative_float(session["tws_sum"]),
         :ok <- validate_position_sums(session),
         :ok <- validate_tws_sum(session) do
      :ok
    end
  end

  defp validate_position_sums(%{"pos_n" => 0, "lat_sum" => lat, "lon_sum" => lon}) do
    ensure(approx_equal?(lat, 0.0) and approx_equal?(lon, 0.0))
  end

  defp validate_position_sums(session) do
    ensure(
      abs(session["lat_sum"]) <= 90.0 * session["pos_n"] and
        abs(session["lon_sum"]) <= 180.0 * session["pos_n"]
    )
  end

  defp validate_tws_sum(%{"tws_n" => 0, "tws_sum" => sum}), do: ensure(approx_equal?(sum, 0.0))
  defp validate_tws_sum(_session), do: :ok

  defp validate_timeline(rows) do
    with :ok <- bounded_list(rows, @max_pending_rows),
         :ok <- validate_each(rows, &validate_timeline_row/1),
         :ok <- nondecreasing_by(rows, & &1["t_ms"]) do
      :ok
    end
  end

  defp validate_timeline_row(row) do
    fields = ~w(amplitude_deg mean_twd_deg period_s phase_deg t_ms trend_deg_per_hr tws_mps)

    with :ok <- exact_string_keys(row, fields),
         :ok <- nonnegative_u64(row["t_ms"]),
         :ok <- nullable_direction(row["mean_twd_deg"]),
         :ok <- nullable_signed_direction(row["phase_deg"]),
         :ok <- nullable_nonnegative_float(row["amplitude_deg"]),
         :ok <- nullable_positive_float(row["period_s"]),
         :ok <- nullable_float(row["trend_deg_per_hr"]),
         :ok <- nullable_nonnegative_float(row["tws_mps"]) do
      :ok
    end
  end

  defp validate_events(events) do
    with :ok <- bounded_list(events, @max_pending_rows),
         :ok <- validate_each(events, &validate_event/1),
         :ok <- nondecreasing_non_extreme_events(events) do
      :ok
    end
  end

  defp nondecreasing_non_extreme_events(events), do: nondecreasing_non_extreme_events(events, nil)
  defp nondecreasing_non_extreme_events([], _previous_t_ms), do: :ok

  defp nondecreasing_non_extreme_events([%{"kind" => kind} | rest], previous_t_ms)
       when kind in ["header_extreme", "lift_extreme"],
       do: nondecreasing_non_extreme_events(rest, previous_t_ms)

  defp nondecreasing_non_extreme_events([event | rest], nil),
    do: nondecreasing_non_extreme_events(rest, event["t_ms"])

  defp nondecreasing_non_extreme_events([event | rest], previous_t_ms) do
    if previous_t_ms <= event["t_ms"],
      do: nondecreasing_non_extreme_events(rest, event["t_ms"]),
      else: {:error, :invalid_checkpoint_content}
  end

  defp validate_event(event) do
    fields = ~w(detail kind magnitude_deg t_ms twd_deg)

    with :ok <- exact_string_keys(event, fields),
         :ok <- nonnegative_u64(event["t_ms"]),
         :ok <- direction(event["twd_deg"]),
         :ok <-
           ensure(event["kind"] in ~w(step new_high new_low regime_change header_extreme lift_extreme)),
         :ok <- validate_event_variant(event) do
      :ok
    end
  end

  defp validate_event_variant(%{"kind" => "step"} = event) do
    with :ok <- finite_float(event["magnitude_deg"]),
         :ok <- exact_string_keys(event["detail"], ["onset_t_ms"]),
         :ok <- nonnegative_u64(event["detail"]["onset_t_ms"]),
         :ok <- ensure(event["detail"]["onset_t_ms"] <= event["t_ms"]) do
      :ok
    end
  end

  defp validate_event_variant(%{"kind" => kind} = event) when kind in ["new_high", "new_low"] do
    with :ok <- nonnegative_float(event["magnitude_deg"]),
         :ok <- exact_string_keys(event["detail"], ~w(max_deg min_deg)),
         :ok <- direction(event["detail"]["min_deg"]),
         :ok <- direction(event["detail"]["max_deg"]) do
      :ok
    end
  end

  defp validate_event_variant(%{"kind" => "regime_change"} = event) do
    with :ok <- ensure(is_nil(event["magnitude_deg"])),
         :ok <- exact_string_keys(event["detail"], ~w(confidence from to)),
         :ok <- ensure(event["detail"]["from"] in @regimes),
         :ok <- ensure(event["detail"]["to"] in @regimes),
         :ok <- ensure(event["detail"]["from"] != event["detail"]["to"]),
         :ok <- between_float(event["detail"]["confidence"], 0.0, 1.0) do
      :ok
    end
  end

  defp validate_event_variant(%{"kind" => kind} = event)
       when kind in ["header_extreme", "lift_extreme"] do
    with :ok <- nonnegative_float(event["magnitude_deg"]),
         :ok <- exact_string_keys(event["detail"], ["phase_deg"]),
         :ok <- signed_direction(event["detail"]["phase_deg"]),
         :ok <- ensure(approx_equal?(event["magnitude_deg"], abs(event["detail"]["phase_deg"]))) do
      :ok
    end
  end

  defp validate_event_variant(_event), do: {:error, :invalid_checkpoint_content}

  defp validate_summary(nil), do: :ok

  defp validate_summary(summary) do
    fields = ~w(
      mean_twd_deg oscillation_amplitude_deg oscillation_period_s regime
      trend_deg_per_hr tws_mean_mps
    )

    with :ok <- exact_string_keys(summary, fields),
         :ok <- nullable_direction(summary["mean_twd_deg"]),
         :ok <- nullable_float(summary["trend_deg_per_hr"]),
         :ok <- nullable_positive_float(summary["oscillation_period_s"]),
         :ok <- nullable_nonnegative_float(summary["oscillation_amplitude_deg"]),
         :ok <- ensure(summary["regime"] in @regimes),
         :ok <- nullable_nonnegative_float(summary["tws_mean_mps"]) do
      :ok
    end
  end

  defp validate_session_binding(%{"session" => nil} = content) do
    ensure(
      content["pending_timeline"] == [] and content["pending_events"] == [] and
        is_nil(content["last_summary"])
    )
  end

  defp validate_session_binding(content) do
    started_at_ms = content["session"]["started_at_ms"]

    timestamps =
      Enum.map(content["pending_timeline"], & &1["t_ms"]) ++
        Enum.flat_map(content["pending_events"], &bound_event_timestamps/1)

    session_utc_day = div(started_at_ms, @ms_per_utc_day)

    ensure(
      Enum.all?(timestamps, fn timestamp ->
        timestamp >= started_at_ms and div(timestamp, @ms_per_utc_day) == session_utc_day
      end)
    )
  end

  defp bound_event_timestamps(%{"kind" => "step"} = event),
    do: [event["t_ms"], event["detail"]["onset_t_ms"]]

  defp bound_event_timestamps(event), do: [event["t_ms"]]

  # Shared estimator validation

  defp validate_estimate_tracker(tracker, expected_p50) do
    with :ok <- exact_string_keys(tracker, @estimate_tracker_fields),
         :ok <- nonnegative_u64(tracker["count"]),
         :ok <- positive_u64_value(tracker["min_samples"]),
         :ok <- positive_u64_value(tracker["stability_window"]),
         :ok <- positive_float(tracker["max_spread"]),
         :ok <- nonnegative_float(tracker["max_drift"]),
         :ok <- nullable_float(tracker["clamp_min"]),
         :ok <- nullable_float(tracker["clamp_max"]),
         :ok <- ordered_bounds(tracker["clamp_min"], tracker["clamp_max"]),
         :ok <- nullable_nonnegative_float(tracker["max_slew"]),
         :ok <- validate_p_square(tracker["p50"], expected_p50),
         :ok <- validate_p_square(tracker["p25"], 0.25),
         :ok <- validate_p_square(tracker["p75"], 0.75),
         :ok <- ensure(tracker["p50"]["count"] == tracker["count"]),
         :ok <- ensure(tracker["p25"]["count"] == tracker["count"]),
         :ok <- ensure(tracker["p75"]["count"] == tracker["count"]),
         :ok <- bounded_list(tracker["recent"], tracker["stability_window"]),
         :ok <- validate_each(tracker["recent"], &finite_float/1),
         :ok <-
           ensure(length(tracker["recent"]) == min(tracker["count"], tracker["stability_window"])) do
      :ok
    end
  end

  defp validate_estimate_options(options) do
    with :ok <- exact_string_keys(options, @estimate_option_fields),
         :ok <- positive_u64_value(options["min_samples"]),
         :ok <- positive_u64_value(options["stability_window"]),
         :ok <- positive_float(options["max_spread"]),
         :ok <- nonnegative_float(options["max_drift"]),
         :ok <- nullable_float(options["clamp_min"]),
         :ok <- nullable_float(options["clamp_max"]),
         :ok <- ordered_bounds(options["clamp_min"], options["clamp_max"]),
         :ok <- nullable_nonnegative_float(options["max_slew"]) do
      :ok
    end
  end

  defp ensure_tracker_options(tracker, options) do
    ensure(
      Enum.all?(@estimate_option_fields, fn field ->
        tracker[field] === options[field]
      end)
    )
  end

  defp validate_p_square(value, expected_p) do
    with :ok <- exact_string_keys(value, @p_square_fields),
         :ok <- between_float(value["p"], 0.0, 1.0, exclusive: true),
         :ok <- ensure(approx_equal?(value["p"], expected_p)),
         :ok <- nonnegative_u64(value["count"]),
         :ok <- validate_p_square_phase(value) do
      :ok
    end
  end

  defp validate_p_square_phase(%{"count" => count} = value) when count < 5 do
    with :ok <- bounded_list(value["buffer"], 4),
         :ok <- ensure(length(value["buffer"]) == count),
         :ok <- validate_each(value["buffer"], &finite_float/1),
         :ok <- nondecreasing(value["buffer"]),
         :ok <- ensure(is_nil(value["q"])),
         :ok <- ensure(is_nil(value["n"])),
         :ok <- ensure(is_nil(value["np"])),
         :ok <- ensure(is_nil(value["dnp"])) do
      :ok
    end
  end

  defp validate_p_square_phase(value) do
    with :ok <- ensure(value["buffer"] == []),
         :ok <- exact_length_list(value["q"], 5),
         :ok <- validate_each(value["q"], &finite_float/1),
         :ok <- nondecreasing(value["q"]),
         :ok <- exact_length_list(value["n"], 5),
         :ok <- validate_each(value["n"], &positive_u64_value/1),
         :ok <- strictly_increasing(value["n"]),
         :ok <- ensure(hd(value["n"]) == 1),
         :ok <- ensure(List.last(value["n"]) == value["count"]),
         :ok <- exact_length_list(value["np"], 5),
         :ok <- validate_each(value["np"], &finite_float/1),
         :ok <- nondecreasing(value["np"]),
         :ok <- exact_length_list(value["dnp"], 5),
         :ok <- validate_each(value["dnp"], &finite_float/1),
         :ok <- validate_p_square_positions(value) do
      :ok
    end
  end

  defp validate_p_square_positions(value) do
    p = value["p"]
    count = value["count"]

    with :ok <- approximate_vector(value["dnp"], expected_dnp(p)),
         :ok <- approximate_vector(value["np"], expected_np(p, count)),
         :ok <- ensure(Enum.all?(value["n"], &(&1 <= count))) do
      :ok
    end
  end

  @doc """
  The P-square desired-position increments `dnp` implied by quantile probability `p`.

  A pure function of `p`, so a checkpoint that already binds `p` never needs to
  carry it per cell — see the polar v2 schema.
  """
  def expected_dnp(p), do: [0.0, p / 2.0, p, (1.0 + p) / 2.0, 1.0]

  @doc """
  The P-square desired marker positions `np` implied by `p` after `count` samples.

  Only the marker-phase (`count >= 5`) estimator has desired positions.
  """
  def expected_np(p, count) do
    [
      1.0,
      1.0 + (count - 1) * p / 2.0,
      1.0 + (count - 1) * p,
      1.0 + (count - 1) * (1.0 + p) / 2.0,
      count / 1
    ]
  end

  defp nonnegative_p_square_values(%{"buffer" => buffer, "q" => q}) do
    values = if is_nil(q), do: buffer, else: q
    ensure(Enum.all?(values, &(&1 >= 0.0)))
  end

  # Secret boundary and primitive validators

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

  defp secret_capable_key?(key) when is_atom(key),
    do: key |> Atom.to_string() |> secret_capable_key?()

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

  defp checkpoint_size(bytes) when is_binary(bytes) do
    if byte_size(bytes) in 1..Contract.max_checkpoint_size(),
      do: :ok,
      else: {:error, :checkpoint_too_large}
  end

  defp exact_string_keys(value, expected) when is_map(value) do
    keys = Map.keys(value)

    ensure(Enum.all?(keys, &is_binary/1) and Enum.sort(keys) == Enum.sort(expected))
  end

  defp exact_string_keys(_value, _expected), do: {:error, :invalid_checkpoint_content}

  defp exact_atom_keys(value, expected, error) do
    if Enum.sort(Map.keys(value)) == Enum.sort(expected), do: :ok, else: {:error, error}
  end

  defp bounded_list(value, max) when is_list(value) and is_integer(max) and max >= 0 do
    with :ok <- proper_list(value),
         :ok <- ensure(length(value) <= max) do
      :ok
    end
  end

  defp bounded_list(_value, _max), do: {:error, :invalid_checkpoint_content}

  defp exact_length_list(value, size) do
    with :ok <- bounded_list(value, size),
         :ok <- ensure(length(value) == size) do
      :ok
    end
  end

  defp proper_list([]), do: :ok
  defp proper_list([_ | rest]), do: proper_list(rest)
  defp proper_list(_value), do: {:error, :invalid_checkpoint_content}

  defp validate_each(values, validator) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validator.(value) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp strictly_ordered_by(values, key_fun), do: ordered_by(values, key_fun, :strictly_increasing)
  defp nondecreasing_by(values, key_fun), do: ordered_by(values, key_fun, :nondecreasing)
  defp nonincreasing_by(values, key_fun), do: ordered_by(values, key_fun, :nonincreasing)

  defp ordered_by([], _key_fun, _order), do: :ok

  defp ordered_by([first | rest], key_fun, order),
    do: ordered_by(rest, key_fun, order, key_fun.(first))

  defp ordered_by([], _key_fun, _order, _previous), do: :ok

  defp ordered_by([current | rest], key_fun, order, previous) do
    key = key_fun.(current)

    valid? =
      case order do
        :strictly_increasing -> previous < key
        :nondecreasing -> previous <= key
        :nonincreasing -> previous >= key
      end

    if valid?,
      do: ordered_by(rest, key_fun, order, key),
      else: {:error, :invalid_checkpoint_content}
  end

  defp nondecreasing(values), do: ordered_scalars(values, &Kernel.<=/2)
  defp strictly_increasing(values), do: ordered_scalars(values, &Kernel.</2)

  defp ordered_scalars([], _comparator), do: :ok
  defp ordered_scalars([first | rest], comparator), do: ordered_scalars(rest, comparator, first)
  defp ordered_scalars([], _comparator, _previous), do: :ok

  defp ordered_scalars([current | rest], comparator, previous) do
    if comparator.(previous, current),
      do: ordered_scalars(rest, comparator, current),
      else: {:error, :invalid_checkpoint_content}
  end

  defp approximate_vector(actual, expected) do
    if Enum.zip(actual, expected)
       |> Enum.all?(fn {left, right} -> approx_equal?(left, right) end),
       do: :ok,
       else: {:error, :invalid_checkpoint_content}
  end

  defp approx_equal?(left, right) when is_float(left) and is_float(right) do
    scale = max(1.0, max(abs(left), abs(right)))
    abs(left - right) <= 1.0e-9 * scale
  end

  defp approx_equal?(_left, _right), do: false

  defp hardware_identifier(value) when is_binary(value) do
    ensure(byte_size(value) in 1..16 and Regex.match?(~r/\A[0-9A-F]+\z/, value))
  end

  defp hardware_identifier(_value), do: {:error, :invalid_checkpoint_content}

  defp direction(value) do
    with :ok <- finite_float(value), :ok <- ensure(value >= 0.0 and value < 360.0), do: :ok
  end

  defp signed_direction(value) do
    with :ok <- finite_float(value), :ok <- ensure(value >= -180.0 and value < 180.0), do: :ok
  end

  defp nullable_direction(nil), do: :ok
  defp nullable_direction(value), do: direction(value)
  defp nullable_signed_direction(nil), do: :ok
  defp nullable_signed_direction(value), do: signed_direction(value)

  defp finite_float(value)
       when is_float(value) and value == value and value <= @max_finite and value >= -@max_finite,
       do: :ok

  defp finite_float(_value), do: {:error, :invalid_checkpoint_content}

  defp nonnegative_float(value) do
    with :ok <- finite_float(value), :ok <- ensure(value >= 0.0), do: :ok
  end

  defp positive_float(value) do
    with :ok <- finite_float(value), :ok <- ensure(value > 0.0), do: :ok
  end

  defp nullable_float(nil), do: :ok
  defp nullable_float(value), do: finite_float(value)
  defp nullable_nonnegative_float(nil), do: :ok
  defp nullable_nonnegative_float(value), do: nonnegative_float(value)
  defp nullable_positive_float(nil), do: :ok
  defp nullable_positive_float(value), do: positive_float(value)

  defp between_float(value, minimum, maximum, opts \\ []) do
    with :ok <- finite_float(value) do
      if Keyword.get(opts, :exclusive, false),
        do: ensure(value > minimum and value < maximum),
        else: ensure(value >= minimum and value <= maximum)
    end
  end

  defp ordered_bounds(nil, _maximum), do: :ok
  defp ordered_bounds(_minimum, nil), do: :ok
  defp ordered_bounds(minimum, maximum), do: ensure(minimum <= maximum)

  defp u32_value(value) when is_integer(value) and value >= 0 and value <= @u32_max, do: :ok
  defp u32_value(_value), do: {:error, :invalid_checkpoint_content}

  defp nonnegative_u64(value) when is_integer(value) and value >= 0 and value <= @u64_max, do: :ok
  defp nonnegative_u64(_value), do: {:error, :invalid_checkpoint_content}

  defp positive_u64_value(value) when is_integer(value) and value > 0 and value <= @u64_max,
    do: :ok

  defp positive_u64_value(_value), do: {:error, :invalid_checkpoint_content}

  defp u32(value, _error) when is_integer(value) and value >= 0 and value <= @u32_max, do: :ok
  defp u32(_value, error), do: {:error, error}

  defp database_int(value, _error)
       when is_integer(value) and value >= 0 and value <= @database_int_max,
       do: :ok

  defp database_int(_value, error), do: {:error, error}

  defp positive_database_int(value, _error)
       when is_integer(value) and value > 0 and value <= @database_int_max,
       do: :ok

  defp positive_database_int(_value, error), do: {:error, error}

  defp fixed_binary(value, size, _error) when is_binary(value) and byte_size(value) == size,
    do: :ok

  defp fixed_binary(_value, _size, error), do: {:error, error}

  defp nonzero_binary(value, size, error) do
    with :ok <- fixed_binary(value, size, error),
         :ok <- ensure(value != :binary.copy(<<0>>, size), error) do
      :ok
    end
  end

  defp ensure(true), do: :ok
  defp ensure(false), do: {:error, :invalid_checkpoint_content}
  defp ensure(true, _reason), do: :ok
  defp ensure(false, reason), do: {:error, reason}
end
