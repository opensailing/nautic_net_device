defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.Polar do
  @moduledoc """
  Reversible exact-runtime wire adapter for sailed-polar checkpoint schema v3.

  The embedded learner remains the established polar learner schema v2. This
  adapter carries the complete `Polar.Observer.RuntimeSnapshot` envelope while
  translating tuples, enum atoms, and arbitrary bytes into the canonical value
  grammar. The rolling window is chunked rather than truncated so every legal
  100,000-row runtime snapshot remains representable.
  """

  alias RacingOrg.Tracker.Pro.Polar.Observer.RuntimeSnapshot
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint

  @runtime_schema_version 3
  @chunk_size 65_535
  @database_int_max 9_223_372_036_854_775_807
  @u64_max 0xFFFF_FFFF_FFFF_FFFF
  @invalid {:error, :invalid_checkpoint_content}

  @spec project(term()) :: {:ok, map()} | {:error, :invalid_checkpoint_content}
  def project(snapshot) do
    with :ok <- RuntimeSnapshot.preflight(snapshot),
         wire = project_snapshot(snapshot),
         :ok <- validate(wire),
         {:ok, _canonical} <- Checkpoint.canonical_content(:polar, @runtime_schema_version, wire) do
      {:ok, wire}
    else
      _ -> @invalid
    end
  rescue
    _ -> @invalid
  catch
    _, _ -> @invalid
  end

  @spec hydrate(term()) :: {:ok, map()} | {:error, :invalid_checkpoint_content}
  def hydrate(wire) do
    with :ok <- validate(wire),
         {:ok, snapshot} <- hydrate_snapshot(wire),
         :ok <- RuntimeSnapshot.preflight(snapshot) do
      {:ok, snapshot}
    else
      _ -> @invalid
    end
  rescue
    _ -> @invalid
  catch
    _, _ -> @invalid
  end

  @spec validate(term()) :: :ok | {:error, :invalid_checkpoint_content}
  def validate(wire) do
    with {:ok, snapshot} <- hydrate_snapshot(wire),
         :ok <- RuntimeSnapshot.preflight(snapshot) do
      :ok
    else
      _ -> @invalid
    end
  rescue
    _ -> @invalid
  catch
    _, _ -> @invalid
  end

  defp project_snapshot(snapshot) do
    authority = String.normalize(snapshot.authority.boat_identifier, :nfc)

    %{
      "runtime_schema_version" => @runtime_schema_version,
      "runtime_snapshot_version" => snapshot.version,
      "captured_at_utc_ms" => snapshot.captured_at_utc_ms,
      "authority" => %{"boat_identifier" => authority},
      "policy" => project_policy(snapshot.policy),
      "learner" => %{
        "source_generation" => snapshot.learner.source_generation,
        "content" => project_learner(snapshot.learner.content, authority)
      },
      "upstream_seq" => snapshot.upstream_seq,
      "window" => project_chunked(snapshot.window, &project_window_row/1),
      "sync" => %{
        "dirty_keys" => project_chunked(snapshot.sync.dirty_keys, &project_key/1),
        "last_sync_age_ms" => snapshot.sync.last_sync_age_ms
      },
      "persistence_phase" => %{
        "dirty_keys" => project_chunked(snapshot.persistence_phase.dirty_keys, &project_key/1),
        "force" => snapshot.persistence_phase.force,
        "last_persist_age_ms" => snapshot.persistence_phase.last_persist_age_ms
      },
      "tick" => %{"remaining_ms" => snapshot.tick.remaining_ms}
    }
  end

  defp project_policy(policy) do
    %{
      "admission_hash" => Canonical.bytes(policy.admission_hash),
      "gate" => %{
        "angle_band_deg" => Tuple.to_list(policy.gate.angle_band_deg),
        "heel_band_deg" => Tuple.to_list(policy.gate.heel_band_deg),
        "max_tws_sd_mps" => policy.gate.max_tws_sd_mps,
        "max_turn_rate_dps" => policy.gate.max_turn_rate_dps,
        "max_accel_mps2" => policy.gate.max_accel_mps2,
        "min_dwell" => policy.gate.min_dwell,
        "engine_rpm_idle" => policy.gate.engine_rpm_idle,
        "angle_key" => project_angle_key(policy.gate.angle_key)
      },
      "min_stw_mps" => policy.min_stw_mps,
      "window_size" => policy.window_size,
      "p" => policy.p,
      "sample_ms" => policy.sample_ms,
      "sync_ms" => policy.sync_ms,
      "persist_ms" => policy.persist_ms,
      "persistence_enabled" => policy.persistence_enabled,
      "bins" => %{
        "twa_width_deg" => policy.bins.twa_width_deg,
        "tws_width_mps" => policy.bins.tws_width_mps,
        "max_tws_mps" => policy.bins.max_tws_mps
      }
    }
  end

  defp project_learner(learner, authority) do
    %{
      "authority" => authority,
      "policy_hash" => Canonical.bytes(learner.policy_hash),
      "kind" => "polar",
      "schema_version" => learner.schema_version,
      "source_generation" => learner.source_generation,
      "content_hash" => Canonical.bytes(learner.content_hash),
      "content" => Canonical.bytes(learner.content)
    }
  end

  defp project_window_row(row) do
    [
      row.age_ms,
      row.tws_mps,
      row.twa_deg,
      row.stw_mps,
      row.heading_deg,
      row.heel_deg,
      row.under_power?,
      row.engine_rpm
    ]
  end

  defp project_key(row), do: %{"tws_bin" => row.tws_bin, "twa_bin" => row.twa_bin}

  defp project_chunked(rows, mapper) do
    %{
      "count" => length(rows),
      "chunks" => rows |> Enum.map(mapper) |> Enum.chunk_every(@chunk_size)
    }
  end

  defp hydrate_snapshot(wire) do
    with :ok <-
           exact_keys(
             wire,
             ~w(runtime_schema_version runtime_snapshot_version captured_at_utc_ms authority policy learner upstream_seq window sync persistence_phase tick)
           ),
         true <- wire["runtime_schema_version"] == @runtime_schema_version,
         true <- canonical_u64?(wire["captured_at_utc_ms"]),
         true <- database_int?(wire["runtime_snapshot_version"]),
         true <- database_int?(wire["upstream_seq"]),
         :ok <- exact_keys(wire["authority"], ~w(boat_identifier)),
         true <- canonical_text?(wire["authority"]["boat_identifier"]),
         {:ok, policy} <- hydrate_policy(wire["policy"]),
         {:ok, learner} <- hydrate_learner(wire["learner"]),
         {:ok, window} <- hydrate_chunked(wire["window"], policy.window_size, &hydrate_window_row/1),
         :ok <- strictly_decreasing_ages(window),
         {:ok, sync} <- hydrate_sync(wire["sync"]),
         {:ok, persistence_phase} <- hydrate_persistence(wire["persistence_phase"]),
         :ok <- exact_keys(wire["tick"], ~w(remaining_ms)) do
      {:ok,
       %{
         version: wire["runtime_snapshot_version"],
         captured_at_utc_ms: wire["captured_at_utc_ms"],
         authority: %{boat_identifier: wire["authority"]["boat_identifier"]},
         policy: policy,
         learner: learner,
         upstream_seq: wire["upstream_seq"],
         window: window,
         sync: sync,
         persistence_phase: persistence_phase,
         tick: %{remaining_ms: wire["tick"]["remaining_ms"]}
       }}
    else
      _ -> @invalid
    end
  end

  defp hydrate_policy(wire) do
    fields = ~w(admission_hash gate min_stw_mps window_size p sample_ms sync_ms persist_ms persistence_enabled bins)

    with :ok <- exact_keys(wire, fields),
         {:ok, admission_hash} <- unwrap_bytes(wire["admission_hash"]),
         {:ok, gate} <- hydrate_gate(wire["gate"]),
         :ok <- exact_keys(wire["bins"], ~w(twa_width_deg tws_width_mps max_tws_mps)) do
      {:ok,
       %{
         admission_hash: admission_hash,
         gate: gate,
         min_stw_mps: wire["min_stw_mps"],
         window_size: wire["window_size"],
         p: wire["p"],
         sample_ms: wire["sample_ms"],
         sync_ms: wire["sync_ms"],
         persist_ms: wire["persist_ms"],
         persistence_enabled: wire["persistence_enabled"],
         bins: %{
           twa_width_deg: wire["bins"]["twa_width_deg"],
           tws_width_mps: wire["bins"]["tws_width_mps"],
           max_tws_mps: wire["bins"]["max_tws_mps"]
         }
       }}
    else
      _ -> @invalid
    end
  end

  defp hydrate_gate(wire) do
    fields =
      ~w(angle_band_deg heel_band_deg max_tws_sd_mps max_turn_rate_dps max_accel_mps2 min_dwell engine_rpm_idle angle_key)

    with :ok <- exact_keys(wire, fields),
         {:ok, angle_band} <- pair(wire["angle_band_deg"]),
         {:ok, heel_band} <- pair(wire["heel_band_deg"]),
         {:ok, angle_key} <- hydrate_angle_key(wire["angle_key"]) do
      {:ok,
       %{
         angle_band_deg: angle_band,
         heel_band_deg: heel_band,
         max_tws_sd_mps: wire["max_tws_sd_mps"],
         max_turn_rate_dps: wire["max_turn_rate_dps"],
         max_accel_mps2: wire["max_accel_mps2"],
         min_dwell: wire["min_dwell"],
         engine_rpm_idle: wire["engine_rpm_idle"],
         angle_key: angle_key
       }}
    else
      _ -> @invalid
    end
  end

  defp hydrate_learner(wire) do
    with :ok <- exact_keys(wire, ~w(source_generation content)),
         true <- database_int?(wire["source_generation"]),
         :ok <-
           exact_keys(
             wire["content"],
             ~w(authority policy_hash kind schema_version source_generation content_hash content)
           ),
         true <- wire["content"]["kind"] == "polar",
         true <- wire["content"]["schema_version"] == 2,
         true <- database_int?(wire["content"]["source_generation"]),
         true <- canonical_text?(wire["content"]["authority"]),
         {:ok, policy_hash} <- unwrap_bytes(wire["content"]["policy_hash"]),
         {:ok, content_hash} <- unwrap_bytes(wire["content"]["content_hash"]),
         {:ok, content} <- unwrap_bytes(wire["content"]["content"]) do
      {:ok,
       %{
         source_generation: wire["source_generation"],
         content: %{
           authority: wire["content"]["authority"],
           policy_hash: policy_hash,
           kind: :polar,
           schema_version: 2,
           source_generation: wire["content"]["source_generation"],
           content_hash: content_hash,
           content: content
         }
       }}
    else
      _ -> @invalid
    end
  end

  defp hydrate_sync(wire) do
    with :ok <- exact_keys(wire, ~w(dirty_keys last_sync_age_ms)),
         {:ok, dirty_keys} <- hydrate_chunked(wire["dirty_keys"], @chunk_size, &hydrate_key/1),
         :ok <- strictly_increasing_keys(dirty_keys) do
      {:ok, %{dirty_keys: dirty_keys, last_sync_age_ms: wire["last_sync_age_ms"]}}
    else
      _ -> @invalid
    end
  end

  defp hydrate_persistence(wire) do
    with :ok <- exact_keys(wire, ~w(dirty_keys force last_persist_age_ms)),
         {:ok, dirty_keys} <- hydrate_chunked(wire["dirty_keys"], @chunk_size, &hydrate_key/1),
         :ok <- strictly_increasing_keys(dirty_keys) do
      {:ok,
       %{
         dirty_keys: dirty_keys,
         force: wire["force"],
         last_persist_age_ms: wire["last_persist_age_ms"]
       }}
    else
      _ -> @invalid
    end
  end

  defp hydrate_window_row([
         age_ms,
         tws_mps,
         twa_deg,
         stw_mps,
         heading_deg,
         heel_deg,
         under_power?,
         engine_rpm
       ]) do
    {:ok,
     %{
       age_ms: age_ms,
       tws_mps: tws_mps,
       twa_deg: twa_deg,
       stw_mps: stw_mps,
       heading_deg: heading_deg,
       heel_deg: heel_deg,
       under_power?: under_power?,
       engine_rpm: engine_rpm
     }}
  end

  defp hydrate_window_row(_wire), do: @invalid

  defp hydrate_key(wire) do
    with :ok <- exact_keys(wire, ~w(tws_bin twa_bin)) do
      {:ok, %{tws_bin: wire["tws_bin"], twa_bin: wire["twa_bin"]}}
    else
      _ -> @invalid
    end
  end

  defp hydrate_chunked(wire, maximum, mapper) do
    with :ok <- exact_keys(wire, ~w(count chunks)),
         true <- is_integer(wire["count"]) and wire["count"] >= 0 and wire["count"] <= maximum,
         true <- proper_list?(wire["chunks"]),
         true <- length(wire["chunks"]) <= 2,
         true <- canonical_chunks?(wire["chunks"], wire["count"]),
         {:ok, rows} <- map_chunks(wire["chunks"], mapper),
         true <- length(rows) == wire["count"] do
      {:ok, rows}
    else
      _ -> @invalid
    end
  end

  defp canonical_chunks?([], 0), do: true
  defp canonical_chunks?([], _count), do: false

  defp canonical_chunks?(chunks, count) do
    proper_list?(chunks) and
      Enum.all?(chunks, &(proper_list?(&1) and &1 != [] and length(&1) <= @chunk_size)) and
      Enum.with_index(chunks)
      |> Enum.all?(fn {chunk, index} ->
        index == length(chunks) - 1 or length(chunk) == @chunk_size
      end) and
      Enum.sum(Enum.map(chunks, &length/1)) == count
  end

  defp map_chunks(chunks, mapper) do
    Enum.reduce_while(chunks, {:ok, []}, fn chunk, {:ok, acc} ->
      Enum.reduce_while(chunk, {:ok, acc}, fn row, {:ok, rows} ->
        case mapper.(row) do
          {:ok, mapped} -> {:cont, {:ok, [mapped | rows]}}
          _ -> {:halt, @invalid}
        end
      end)
      |> case do
        {:ok, rows} -> {:cont, {:ok, rows}}
        _ -> {:halt, @invalid}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      _ -> @invalid
    end
  end

  defp project_angle_key(:twa_deg), do: "twa_deg"
  defp project_angle_key(:awa_deg), do: "awa_deg"

  defp hydrate_angle_key("twa_deg"), do: {:ok, :twa_deg}
  defp hydrate_angle_key("awa_deg"), do: {:ok, :awa_deg}
  defp hydrate_angle_key(_value), do: @invalid

  defp unwrap_bytes(%Canonical.Bytes{data: data} = wrapper)
       when is_binary(data) and map_size(wrapper) == 2,
       do: {:ok, data}

  defp unwrap_bytes(_value), do: @invalid

  defp pair([left, right]), do: {:ok, {left, right}}
  defp pair(_value), do: @invalid

  defp canonical_u64?(value), do: is_integer(value) and value >= 0 and value <= @u64_max
  defp database_int?(value), do: is_integer(value) and value >= 0 and value <= @database_int_max

  defp canonical_text?(value) when is_binary(value),
    do: String.valid?(value) and String.normalize(value, :nfc) == value

  defp canonical_text?(_value), do: false

  defp strictly_decreasing_ages([]), do: :ok
  defp strictly_decreasing_ages([_row]), do: :ok

  defp strictly_decreasing_ages([left, right | rest]) do
    if is_integer(left.age_ms) and is_integer(right.age_ms) and left.age_ms >= right.age_ms,
      do: strictly_decreasing_ages([right | rest]),
      else: :error
  end

  defp strictly_increasing_keys([]), do: :ok
  defp strictly_increasing_keys([_row]), do: :ok

  defp strictly_increasing_keys([left, right | rest]) do
    if {left.tws_bin, left.twa_bin} < {right.tws_bin, right.twa_bin},
      do: strictly_increasing_keys([right | rest]),
      else: :error
  end

  defp exact_keys(map, keys) when is_map(map) and not is_struct(map) do
    if map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1)),
      do: :ok,
      else: :error
  end

  defp exact_keys(_map, _keys), do: :error

  defp proper_list?(value) when is_list(value), do: proper_list_tail?(value)
  defp proper_list?(_value), do: false
  defp proper_list_tail?([]), do: true
  defp proper_list_tail?([_ | tail]), do: proper_list_tail?(tail)
  defp proper_list_tail?(_tail), do: false
end
