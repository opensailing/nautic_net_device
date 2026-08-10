defmodule RacingOrg.Tracker.Pro.Calibration.Checkpoint do
  @moduledoc """
  Pure projection and hydration for the calibration observer's durable learner state.

  `project/1` converts the atom-keyed observer-store snapshot (including estimator
  structs and tuple-keyed `prev_applied`) into the closed, canonical calibration
  content shape owned by `DesiredStateV1.Checkpoint`. `hydrate/1` performs the
  inverse conversion into a snapshot suitable for the existing observer restore
  path. Both directions validate the closed wire contract and fail closed.
  """

  alias RacingOrg.Tracker.Pro.Calibration.Estimate
  alias RacingOrg.Tracker.Pro.Calibration.Estimate.Tracker
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.AwaOffset
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.AwsScale
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.StwScale
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.UpwashBands
  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint, as: ContractCheckpoint

  @schema_version 1
  @error {:error, :invalid_calibration_checkpoint}

  @snapshot_fields ~w(awa_estimators aws_estimators prev_applied seq stw_estimators)a
  @awa_fields ~w(bands pairs_seen pairs_skipped rotation upwash)a
  @stw_fields ~w(bands estimate_opts pairs_seen pairs_skipped)a
  @aws_fields ~w(legs_seen legs_skipped min_legs ratio regimes window_s)a
  @upwash_bands_fields ~w(
    band_opts bands clamp_max clamp_min classic_max_spread classic_min_samples
    excluded_light light_band_opts screened
  )a
  @tracker_fields ~w(
    clamp_max clamp_min count max_drift max_slew max_spread min_samples
    p25 p50 p75 recent stability_window
  )a
  @p_square_fields ~w(buffer count dnp n np p q)a
  @estimate_option_fields ~w(
    clamp_max clamp_min max_drift max_slew max_spread min_samples stability_window
  )a
  @estimate_option_order ~w(
    min_samples max_spread stability_window max_drift clamp_min clamp_max max_slew
  )a

  @doc "Project one calibration observer-store snapshot into checkpoint content."
  @spec project(map()) :: {:ok, map()} | {:error, :invalid_calibration_checkpoint}
  def project(snapshot) do
    with {:ok, content} <- project_snapshot(snapshot),
         {:ok, _bytes} <- ContractCheckpoint.encode_content(:calibration, @schema_version, content) do
      {:ok, content}
    else
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  @doc "Hydrate validated calibration checkpoint content into an observer-store snapshot."
  @spec hydrate(map()) :: {:ok, map()} | {:error, :invalid_calibration_checkpoint}
  def hydrate(content) do
    with {:ok, _bytes} <- ContractCheckpoint.encode_content(:calibration, @schema_version, content),
         {:ok, snapshot} <- hydrate_content(content) do
      {:ok, snapshot}
    else
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  defp project_snapshot(snapshot) when is_map(snapshot) do
    with :ok <- exact_atom_keys(snapshot, @snapshot_fields),
         {:ok, awa_estimators} <- project_estimator_map(snapshot.awa_estimators, &project_awa/2),
         {:ok, stw_estimators} <- project_estimator_map(snapshot.stw_estimators, &project_stw/2),
         {:ok, aws_estimators} <- project_estimator_map(snapshot.aws_estimators, &project_aws/2),
         {:ok, prev_applied} <- project_prev_applied(snapshot.prev_applied) do
      {:ok,
       %{
         "awa_estimators" => awa_estimators,
         "aws_estimators" => aws_estimators,
         "prev_applied" => prev_applied,
         "seq" => snapshot.seq,
         "stw_estimators" => stw_estimators
       }}
    end
  end

  defp project_snapshot(_snapshot), do: @error

  defp project_estimator_map(estimators, projector) when is_map(estimators) and not is_struct(estimators) do
    estimators
    |> Enum.reduce_while({:ok, []}, fn {hardware_identifier, estimator}, {:ok, projected} ->
      case projector.(hardware_identifier, estimator) do
        {:ok, value} -> {:cont, {:ok, [value | projected]}}
        _ -> {:halt, @error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.sort_by(projected, & &1["hardware_identifier"])}
      error -> error
    end
  end

  defp project_estimator_map(_estimators, _projector), do: @error

  defp project_awa(hardware_identifier, estimator) do
    with :ok <- canonical_hardware_identifier(hardware_identifier),
         :ok <- exact_struct(estimator, AwaOffset, @awa_fields),
         {:ok, rotation} <- project_tracker(estimator.rotation),
         {:ok, upwash} <- project_tracker(estimator.upwash),
         {:ok, bands} <- project_upwash_bands(estimator.bands) do
      {:ok,
       %{
         "bands" => bands,
         "hardware_identifier" => hardware_identifier,
         "pairs_seen" => estimator.pairs_seen,
         "pairs_skipped" => estimator.pairs_skipped,
         "rotation" => rotation,
         "upwash" => upwash
       }}
    end
  end

  defp project_stw(hardware_identifier, estimator) do
    with :ok <- canonical_hardware_identifier(hardware_identifier),
         :ok <- exact_struct(estimator, StwScale, @stw_fields),
         {:ok, estimate_options} <- project_options(estimator.estimate_opts),
         {:ok, bands} <- project_stw_bands(estimator.bands) do
      {:ok,
       %{
         "bands" => bands,
         "estimate_options" => estimate_options,
         "hardware_identifier" => hardware_identifier,
         "pairs_seen" => estimator.pairs_seen,
         "pairs_skipped" => estimator.pairs_skipped
       }}
    end
  end

  defp project_aws(hardware_identifier, estimator) do
    with :ok <- canonical_hardware_identifier(hardware_identifier),
         :ok <- exact_struct(estimator, AwsScale, @aws_fields),
         {:ok, ratio} <- project_tracker(estimator.ratio),
         {:ok, regimes} <- project_regimes(estimator.regimes) do
      {:ok,
       %{
         "hardware_identifier" => hardware_identifier,
         "legs_seen" => estimator.legs_seen,
         "legs_skipped" => estimator.legs_skipped,
         "min_legs" => estimator.min_legs,
         "ratio" => ratio,
         "regimes" => regimes,
         "window_s" => estimator.window_s
       }}
    end
  end

  defp project_upwash_bands(bands) do
    with :ok <- exact_struct(bands, UpwashBands, @upwash_bands_fields),
         {:ok, band_tracker_options} <- project_options(bands.band_opts),
         {:ok, light_band_tracker_options} <- project_options(bands.light_band_opts),
         {:ok, projected_bands} <- project_tracker_bands(bands.bands) do
      {:ok,
       %{
         "band_tracker_options" => band_tracker_options,
         "bands" => projected_bands,
         "clamp_max" => bands.clamp_max,
         "clamp_min" => bands.clamp_min,
         "classic_max_spread" => bands.classic_max_spread,
         "classic_min_samples" => bands.classic_min_samples,
         "excluded_light" => bands.excluded_light,
         "light_band_tracker_options" => light_band_tracker_options,
         "screened" => bands.screened
       }}
    end
  end

  defp project_tracker_bands(bands) when is_map(bands) and not is_struct(bands) do
    bands
    |> Enum.reduce_while({:ok, []}, fn {center, tracker}, {:ok, projected} ->
      case project_tracker(tracker) do
        {:ok, value} -> {:cont, {:ok, [%{"center_mps" => center, "tracker" => value} | projected]}}
        _ -> {:halt, @error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.sort_by(projected, & &1["center_mps"])}
      error -> error
    end
  end

  defp project_tracker_bands(_bands), do: @error

  defp project_stw_bands(bands) when is_map(bands) and not is_struct(bands) do
    bands
    |> Enum.reduce_while({:ok, []}, fn {center, band}, {:ok, projected} ->
      with :ok <- exact_atom_keys(band, [:estimate, :p, :theta]),
           {:ok, estimate} <- project_tracker(band.estimate) do
        value = %{
          "center_mps" => center,
          "estimate" => estimate,
          "p" => band.p,
          "theta" => band.theta
        }

        {:cont, {:ok, [value | projected]}}
      else
        _ -> {:halt, @error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.sort_by(projected, & &1["center_mps"])}
      error -> error
    end
  end

  defp project_stw_bands(_bands), do: @error

  defp project_regimes(regimes) when is_map(regimes) and not is_struct(regimes) do
    with :ok <- exact_atom_keys(regimes, [:upwind, :reach, :downwind]),
         {:ok, upwind} <- project_regime_legs(regimes.upwind),
         {:ok, reach} <- project_regime_legs(regimes.reach),
         {:ok, downwind} <- project_regime_legs(regimes.downwind) do
      {:ok,
       [
         %{"legs" => upwind, "name" => "upwind"},
         %{"legs" => reach, "name" => "reach"},
         %{"legs" => downwind, "name" => "downwind"}
       ]}
    end
  end

  defp project_regimes(_regimes), do: @error

  defp project_regime_legs(legs) when is_list(legs) do
    legs
    |> Enum.reduce_while({:ok, []}, fn
      {t_end_s, tws_mps}, {:ok, projected} ->
        {:cont, {:ok, [%{"t_end_s" => t_end_s, "tws_mps" => tws_mps} | projected]}}

      _leg, _projected ->
        {:halt, @error}
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      error -> error
    end
  end

  defp project_regime_legs(_legs), do: @error

  defp project_prev_applied(prev_applied) when is_map(prev_applied) and not is_struct(prev_applied) do
    prev_applied
    |> Enum.reduce_while({:ok, []}, fn
      {{hardware_identifier, parameter}, value}, {:ok, projected} ->
        with :ok <- canonical_hardware_identifier(hardware_identifier),
             true <- parameter in ["awa_offset", "awa_upwash"] do
          entry = %{
            "hardware_identifier" => hardware_identifier,
            "parameter" => parameter,
            "value" => value
          }

          {:cont, {:ok, [entry | projected]}}
        else
          _ -> {:halt, @error}
        end

      _entry, _projected ->
        {:halt, @error}
    end)
    |> case do
      {:ok, projected} ->
        {:ok, Enum.sort_by(projected, &{&1["hardware_identifier"], &1["parameter"]})}

      error ->
        error
    end
  end

  defp project_prev_applied(_prev_applied), do: @error

  defp project_options(options) do
    with :ok <- validate_option_list(options) do
      options
      |> Estimate.new()
      |> project_tracker_options()
    end
  end

  defp validate_option_list(options) when is_list(options) do
    keys = Keyword.keys(options)

    if Keyword.keyword?(options) and length(keys) == length(Enum.uniq(keys)) and
         Enum.all?(keys, &(&1 in @estimate_option_fields)) do
      :ok
    else
      @error
    end
  end

  defp validate_option_list(_options), do: @error

  defp project_tracker_options(%Tracker{} = tracker) do
    {:ok,
     %{
       "clamp_max" => tracker.clamp_max,
       "clamp_min" => tracker.clamp_min,
       "max_drift" => tracker.max_drift,
       "max_slew" => tracker.max_slew,
       "max_spread" => tracker.max_spread,
       "min_samples" => tracker.min_samples,
       "stability_window" => tracker.stability_window
     }}
  end

  defp project_tracker(tracker) do
    with :ok <- exact_struct(tracker, Tracker, @tracker_fields),
         {:ok, p25} <- project_p_square(tracker.p25),
         {:ok, p50} <- project_p_square(tracker.p50),
         {:ok, p75} <- project_p_square(tracker.p75),
         true <- is_list(tracker.recent) do
      {:ok,
       %{
         "clamp_max" => tracker.clamp_max,
         "clamp_min" => tracker.clamp_min,
         "count" => tracker.count,
         "max_drift" => tracker.max_drift,
         "max_slew" => tracker.max_slew,
         "max_spread" => tracker.max_spread,
         "min_samples" => tracker.min_samples,
         "p25" => p25,
         "p50" => p50,
         "p75" => p75,
         "recent" => tracker.recent,
         "stability_window" => tracker.stability_window
       }}
    else
      _ -> @error
    end
  end

  defp project_p_square(quantile) do
    with :ok <- exact_struct(quantile, PSquare, @p_square_fields),
         true <- is_list(quantile.buffer),
         {:ok, q} <- project_optional_tuple(quantile.q),
         {:ok, n} <- project_optional_tuple(quantile.n),
         {:ok, np} <- project_optional_tuple(quantile.np),
         {:ok, dnp} <- project_optional_tuple(quantile.dnp) do
      {:ok,
       %{
         "buffer" => quantile.buffer,
         "count" => quantile.count,
         "dnp" => dnp,
         "n" => n,
         "np" => np,
         "p" => quantile.p,
         "q" => q
       }}
    else
      _ -> @error
    end
  end

  defp project_optional_tuple(nil), do: {:ok, nil}
  defp project_optional_tuple(value) when is_tuple(value) and tuple_size(value) == 5, do: {:ok, Tuple.to_list(value)}
  defp project_optional_tuple(_value), do: @error

  defp hydrate_content(content) do
    {:ok,
     %{
       awa_estimators: hydrate_awa_estimators(content["awa_estimators"]),
       aws_estimators: hydrate_aws_estimators(content["aws_estimators"]),
       prev_applied: hydrate_prev_applied(content["prev_applied"]),
       seq: content["seq"],
       stw_estimators: hydrate_stw_estimators(content["stw_estimators"])
     }}
  end

  defp hydrate_awa_estimators(estimators) do
    Map.new(estimators, fn estimator ->
      hardware_identifier = estimator["hardware_identifier"]
      {hardware_identifier, hydrate_awa(estimator)}
    end)
  end

  defp hydrate_awa(estimator) do
    %AwaOffset{
      bands: hydrate_upwash_bands(estimator["bands"]),
      pairs_seen: estimator["pairs_seen"],
      pairs_skipped: estimator["pairs_skipped"],
      rotation: hydrate_tracker(estimator["rotation"]),
      upwash: hydrate_tracker(estimator["upwash"])
    }
  end

  defp hydrate_upwash_bands(bands) do
    %UpwashBands{
      band_opts: hydrate_options(bands["band_tracker_options"]),
      bands:
        Map.new(bands["bands"], fn band ->
          {band["center_mps"], hydrate_tracker(band["tracker"])}
        end),
      clamp_max: bands["clamp_max"],
      clamp_min: bands["clamp_min"],
      classic_max_spread: bands["classic_max_spread"],
      classic_min_samples: bands["classic_min_samples"],
      excluded_light: bands["excluded_light"],
      light_band_opts: hydrate_options(bands["light_band_tracker_options"]),
      screened: bands["screened"]
    }
  end

  defp hydrate_stw_estimators(estimators) do
    Map.new(estimators, fn estimator ->
      hardware_identifier = estimator["hardware_identifier"]
      {hardware_identifier, hydrate_stw(estimator)}
    end)
  end

  defp hydrate_stw(estimator) do
    %StwScale{
      bands:
        Map.new(estimator["bands"], fn band ->
          {band["center_mps"],
           %{
             estimate: hydrate_tracker(band["estimate"]),
             p: band["p"],
             theta: band["theta"]
           }}
        end),
      estimate_opts: hydrate_options(estimator["estimate_options"]),
      pairs_seen: estimator["pairs_seen"],
      pairs_skipped: estimator["pairs_skipped"]
    }
  end

  defp hydrate_aws_estimators(estimators) do
    Map.new(estimators, fn estimator ->
      hardware_identifier = estimator["hardware_identifier"]
      {hardware_identifier, hydrate_aws(estimator)}
    end)
  end

  defp hydrate_aws(estimator) do
    regimes =
      Map.new(estimator["regimes"], fn regime ->
        {regime_name(regime["name"]), Enum.map(regime["legs"], fn leg -> {leg["t_end_s"], leg["tws_mps"]} end)}
      end)

    %AwsScale{
      legs_seen: estimator["legs_seen"],
      legs_skipped: estimator["legs_skipped"],
      min_legs: estimator["min_legs"],
      ratio: hydrate_tracker(estimator["ratio"]),
      regimes: regimes,
      window_s: estimator["window_s"]
    }
  end

  defp regime_name("upwind"), do: :upwind
  defp regime_name("reach"), do: :reach
  defp regime_name("downwind"), do: :downwind

  defp hydrate_prev_applied(entries) do
    Map.new(entries, fn entry ->
      {{entry["hardware_identifier"], entry["parameter"]}, entry["value"]}
    end)
  end

  defp hydrate_tracker(tracker) do
    %Tracker{
      clamp_max: tracker["clamp_max"],
      clamp_min: tracker["clamp_min"],
      count: tracker["count"],
      max_drift: tracker["max_drift"],
      max_slew: tracker["max_slew"],
      max_spread: tracker["max_spread"],
      min_samples: tracker["min_samples"],
      p25: hydrate_p_square(tracker["p25"]),
      p50: hydrate_p_square(tracker["p50"]),
      p75: hydrate_p_square(tracker["p75"]),
      recent: tracker["recent"],
      stability_window: tracker["stability_window"]
    }
  end

  defp hydrate_p_square(quantile) do
    %PSquare{
      buffer: quantile["buffer"],
      count: quantile["count"],
      dnp: hydrate_optional_tuple(quantile["dnp"]),
      n: hydrate_optional_tuple(quantile["n"]),
      np: hydrate_optional_tuple(quantile["np"]),
      p: quantile["p"],
      q: hydrate_optional_tuple(quantile["q"])
    }
  end

  defp hydrate_optional_tuple(nil), do: nil
  defp hydrate_optional_tuple(values), do: List.to_tuple(values)

  defp hydrate_options(options) do
    Enum.map(@estimate_option_order, fn key -> {key, options[Atom.to_string(key)]} end)
  end

  defp canonical_hardware_identifier(value) when is_binary(value) do
    if byte_size(value) in 1..16 and Regex.match?(~r/\A[0-9A-F]+\z/, value), do: :ok, else: @error
  end

  defp canonical_hardware_identifier(_value), do: @error

  defp exact_struct(value, module, fields) do
    if is_struct(value, module),
      do: exact_atom_keys(value, [:__struct__ | fields]),
      else: @error
  end

  defp exact_atom_keys(value, expected) when is_map(value) do
    if map_size(value) == length(expected) and Enum.all?(expected, &Map.has_key?(value, &1)),
      do: :ok,
      else: @error
  end

  defp exact_atom_keys(_value, _expected), do: @error
end
