defmodule RacingOrg.Tracker.Pro.WindShift.Checkpoint do
  @moduledoc """
  Pure projection between the durable `WindShift.Observer.Store` snapshot and the
  closed `:wind_shift` checkpoint-v1 content schema.

  Only the session, sequence, pending timeline/events, and last summary cross the
  boundary. Estimation cores are deliberately excluded so hydration preserves the
  observer's existing behavior of rebuilding them from fresh samples after restart.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint, as: ContractCheckpoint

  @kind :wind_shift
  @schema_version 1

  @snapshot_keys [:last_summary, :pending_events, :pending_timeline, :seq, :session]
  @content_keys ~w(last_summary pending_events pending_timeline seq session)

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
         {:ok, _bytes} <- ContractCheckpoint.encode_content(@kind, @schema_version, content) do
      {:ok, content}
    else
      _ -> {:error, :invalid_wind_shift_snapshot}
    end
  end

  @doc "Hydrate validated checkpoint-v1 content into the exact Observer.Store snapshot shape."
  @spec hydrate(content()) :: {:ok, snapshot()} | {:error, term()}
  def hydrate(content) do
    with {:ok, bytes} <- ContractCheckpoint.encode_content(@kind, @schema_version, content),
         {:ok, canonical_content} <- ContractCheckpoint.decode_content(@kind, @schema_version, bytes),
         {:ok, snapshot} <- hydrate_content(canonical_content) do
      {:ok, snapshot}
    end
  end

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

  defp exact_keys(map, expected) when is_map(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(expected), do: :ok, else: {:error, :invalid_shape}
  end

  defp exact_keys(_map, _expected), do: {:error, :invalid_shape}
end
