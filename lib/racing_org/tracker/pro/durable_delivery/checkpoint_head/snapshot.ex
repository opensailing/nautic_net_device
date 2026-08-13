defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Snapshot do
  @moduledoc false

  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record
  alias RacingOrg.Tracker.Pro.RuntimeSnapshot
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint

  @format_version 4
  @legacy_format_version 2
  @snapshot_tag :checkpoint_head_snapshot
  @binding_domain "RacingOrg-TrackerCheckpointHeadSnapshot-v3"
  @legacy_binding_domain "RacingOrg-TrackerCheckpointHeadSnapshot-v1"
  @binding_version 3
  @legacy_binding_version 1
  @max_ancestry_entries 4_096
  @max_encoded_size 4 * 1_024 * 1_024
  @decode_timeout_ms 5_000
  @decode_max_heap_words 4_000_000

  @summary_keys [
    :device_id,
    :origin_credential_epoch,
    :origin_storage_epoch,
    :sequence,
    :kind,
    :schema_version,
    :source_generation,
    :parent_hash,
    :content_hash,
    :checkpoint_hash
  ]

  @accepted_summary_keys @summary_keys ++
                           [
                             :local_credential_epoch,
                             :local_storage_epoch,
                             :binding_hash
                           ]

  @snapshot_keys [:current, :last_accepted, :ancestry, :ancestry_truncated, :snapshot_hash]
  @legacy_snapshot_keys [:current, :last_accepted, :snapshot_hash]

  @type record_summary :: %{
          device_id: <<_::128>>,
          origin_credential_epoch: non_neg_integer(),
          origin_storage_epoch: <<_::128>>,
          sequence: pos_integer(),
          kind: atom(),
          schema_version: pos_integer(),
          source_generation: non_neg_integer(),
          parent_hash: <<_::256>>,
          content_hash: <<_::256>>,
          checkpoint_hash: <<_::256>>
        }

  @type accepted_summary :: %{
          device_id: <<_::128>>,
          local_credential_epoch: non_neg_integer(),
          local_storage_epoch: <<_::128>>,
          origin_credential_epoch: non_neg_integer(),
          origin_storage_epoch: <<_::128>>,
          sequence: pos_integer(),
          kind: atom(),
          schema_version: pos_integer(),
          source_generation: non_neg_integer(),
          parent_hash: <<_::256>>,
          content_hash: <<_::256>>,
          checkpoint_hash: <<_::256>>,
          binding_hash: <<_::256>>
        }

  @type ancestry :: [record_summary()] | :unknown

  @type t :: %{
          current: Record.t(),
          last_accepted: accepted_summary() | nil | :unknown,
          ancestry: ancestry(),
          ancestry_truncated: boolean(),
          snapshot_hash: <<_::256>>
        }

  @spec max_encoded_size() :: pos_integer()
  def max_encoded_size, do: @max_encoded_size

  @spec max_ancestry_entries() :: pos_integer()
  def max_ancestry_entries, do: @max_ancestry_entries

  @spec record_summary(Record.t()) :: {:ok, record_summary()} | {:error, atom()}
  def record_summary(record) when is_map(record) do
    with :ok <- Record.verify(record) do
      {:ok, Map.take(record, @summary_keys)}
    end
  end

  def record_summary(_record), do: {:error, :invalid_checkpoint_record}

  @spec accepted_summary(Record.t()) :: {:ok, accepted_summary()} | {:error, atom()}
  def accepted_summary(%{accepted: true} = record) do
    with :ok <- Record.verify(record) do
      {:ok, Map.take(record, @accepted_summary_keys)}
    end
  end

  def accepted_summary(_record), do: {:error, :invalid_accepted_checkpoint}

  @spec build(Record.t(), accepted_summary() | nil | :unknown) :: {:ok, t()} | {:error, atom()}
  def build(current, last_accepted) when is_map(current) do
    with {:ok, ancestry, ancestry_truncated} <- infer_ancestry(current, last_accepted) do
      build(current, last_accepted, ancestry, ancestry_truncated)
    end
  end

  def build(_current, _last_accepted), do: {:error, :invalid_checkpoint_snapshot}

  @spec build(Record.t(), accepted_summary() | nil | :unknown, ancestry()) ::
          {:ok, t()} | {:error, atom()}
  def build(current, last_accepted, ancestry),
    do: build(current, last_accepted, ancestry, false)

  @spec build(Record.t(), accepted_summary() | nil | :unknown, ancestry(), boolean()) ::
          {:ok, t()} | {:error, atom()}
  def build(current, last_accepted, ancestry, ancestry_truncated) when is_map(current) do
    with :ok <- Record.verify(current),
         :ok <- verify_snapshot_ancestry(current, last_accepted, ancestry, ancestry_truncated) do
      snapshot = %{
        current: current,
        last_accepted: last_accepted,
        ancestry: ancestry,
        ancestry_truncated: ancestry_truncated
      }

      {:ok, Map.put(snapshot, :snapshot_hash, snapshot_hash(snapshot))}
    end
  end

  def build(_current, _last_accepted, _ancestry, _ancestry_truncated),
    do: {:error, :invalid_checkpoint_snapshot}

  @spec successor(t(), Record.t()) :: {:ok, t()} | {:error, atom()}
  def successor(
        %{
          current: current,
          last_accepted: last_accepted,
          ancestry: ancestry,
          ancestry_truncated: ancestry_truncated
        },
        next_current
      )
      when is_list(ancestry) do
    with {:ok, summary} <- record_summary(current),
         {:ok, next_ancestry, next_truncated} <-
           local_successor_ancestry(
             [summary | ancestry],
             last_accepted,
             ancestry_truncated
           ) do
      build(next_current, last_accepted, next_ancestry, next_truncated)
    end
  end

  def successor(%{ancestry: :unknown}, _next_current),
    do: {:error, :checkpoint_ancestry_unknown}

  def successor(_snapshot, _next_current),
    do: {:error, :invalid_checkpoint_snapshot}

  @spec accepted_successor(t(), Record.t()) :: {:ok, t()} | {:error, atom()}
  def accepted_successor(
        %{current: current, ancestry: ancestry, ancestry_truncated: ancestry_truncated},
        %{accepted: true} = next_current
      )
      when is_list(ancestry) do
    with {:ok, summary} <- record_summary(current),
         {:ok, last_accepted} <- accepted_summary(next_current),
         {next_ancestry, next_truncated} <-
           compact_ancestry([summary | ancestry], ancestry_truncated) do
      build(next_current, last_accepted, next_ancestry, next_truncated)
    end
  end

  def accepted_successor(%{ancestry: :unknown}, %{accepted: true}),
    do: {:error, :checkpoint_ancestry_unknown}

  def accepted_successor(_snapshot, _next_current),
    do: {:error, :invalid_accepted_checkpoint}

  @spec accepted_ancestor?(t(), <<_::256>>) :: boolean()
  def accepted_ancestor?(
        %{
          current: current,
          last_accepted: last_accepted,
          ancestry: ancestry,
          ancestry_truncated: ancestry_truncated
        },
        checkpoint_hash
      )
      when is_binary(checkpoint_hash) do
    secure_equal(current.parent_hash, checkpoint_hash) or
      accepted_hash?(last_accepted, checkpoint_hash) or
      retained_hash?(ancestry, checkpoint_hash) or
      retained_boundary_hash?(ancestry, ancestry_truncated, checkpoint_hash)
  end

  def accepted_ancestor?(_snapshot, _checkpoint_hash), do: false

  @spec accepted_replay?(t(), <<_::256>>) :: boolean()
  def accepted_replay?(%{current: %{accepted: true}} = snapshot, checkpoint_hash),
    do: accepted_ancestor?(snapshot, checkpoint_hash)

  def accepted_replay?(
        %{
          last_accepted: last_accepted,
          ancestry: ancestry,
          ancestry_truncated: ancestry_truncated
        },
        checkpoint_hash
      )
      when is_map(last_accepted) and is_list(ancestry) and is_binary(checkpoint_hash) do
    accepted_index = retained_index(ancestry, last_accepted.checkpoint_hash)
    replay_index = retained_index(ancestry, checkpoint_hash)

    secure_equal(last_accepted.checkpoint_hash, checkpoint_hash) or
      (is_integer(accepted_index) and is_integer(replay_index) and
         replay_index >= accepted_index) or
      (is_integer(accepted_index) and
         retained_boundary_hash?(ancestry, ancestry_truncated, checkpoint_hash))
  end

  def accepted_replay?(_snapshot, _checkpoint_hash), do: false

  @spec preserve_acceptance(t(), Record.t(), accepted_summary()) :: {:ok, t()} | {:error, atom()}
  def preserve_acceptance(%{current: current} = snapshot, rebound, accepted) do
    with :ok <- verify_accepted_summary(accepted),
         {:ok, last_accepted, ancestry, ancestry_truncated} <-
           acceptance_update(snapshot, current, accepted) do
      build(rebound, last_accepted, ancestry, ancestry_truncated)
    end
  end

  defp acceptance_update(%{last_accepted: existing} = snapshot, _current, accepted)
       when is_map(existing) do
    if secure_equal(existing.checkpoint_hash, accepted.checkpoint_hash) do
      {:ok, accepted, snapshot.ancestry, snapshot.ancestry_truncated}
    else
      acceptance_update_by_ancestry(snapshot, accepted)
    end
  end

  defp acceptance_update(snapshot, _current, accepted),
    do: acceptance_update_by_ancestry(snapshot, accepted)

  defp acceptance_update_by_ancestry(
         %{current: current, ancestry: ancestry} = snapshot,
         accepted
       )
       when is_list(ancestry) do
    cond do
      index = retained_index(ancestry, accepted.checkpoint_hash) ->
        acceptance_at_retained_index(snapshot, accepted, index)

      secure_equal(current.parent_hash, accepted.checkpoint_hash) and ancestry == [] ->
        ancestry_truncated =
          snapshot.ancestry_truncated or
            not secure_equal(accepted.parent_hash, Record.genesis_parent())

        {:ok, accepted, [ordinary_summary(accepted)], ancestry_truncated}

      retained_boundary_hash?(
        ancestry,
        snapshot.ancestry_truncated,
        accepted.checkpoint_hash
      ) ->
        acceptance_at_retained_boundary(snapshot, accepted)

      true ->
        {:error, :checkpoint_hydration_ambiguous}
    end
  end

  defp acceptance_update_by_ancestry(
         %{current: current, ancestry: :unknown},
         accepted
       ) do
    if secure_equal(current.parent_hash, accepted.checkpoint_hash) do
      ancestry_truncated =
        not secure_equal(accepted.parent_hash, Record.genesis_parent())

      {:ok, accepted, [ordinary_summary(accepted)], ancestry_truncated}
    else
      {:error, :checkpoint_hydration_ambiguous}
    end
  end

  defp acceptance_update_by_ancestry(_snapshot, _accepted),
    do: {:error, :checkpoint_hydration_ambiguous}

  defp acceptance_at_retained_index(snapshot, accepted, accepted_index) do
    case retained_index(snapshot.ancestry, accepted_hash(snapshot.last_accepted)) do
      existing_index when is_integer(existing_index) and existing_index < accepted_index ->
        {:error, :checkpoint_hydration_rollback}

      _newer_or_omitted ->
        ancestry =
          List.replace_at(
            snapshot.ancestry,
            accepted_index,
            ordinary_summary(accepted)
          )

        {:ok, accepted, ancestry, snapshot.ancestry_truncated}
    end
  end

  defp acceptance_at_retained_boundary(snapshot, accepted) do
    case retained_index(snapshot.ancestry, accepted_hash(snapshot.last_accepted)) do
      existing_index when is_integer(existing_index) ->
        {:error, :checkpoint_hydration_rollback}

      _omitted ->
        {:ok, accepted, snapshot.ancestry, true}
    end
  end

  @spec encode(t()) :: {:ok, binary()} | {:error, atom()}
  def encode(snapshot) when is_map(snapshot) do
    with :ok <- exact_keys(snapshot, @snapshot_keys),
         :ok <- verify(snapshot),
         bytes = :erlang.term_to_binary({@format_version, @snapshot_tag, snapshot}),
         true <- byte_size(bytes) <= @max_encoded_size do
      {:ok, bytes}
    else
      false -> {:error, :checkpoint_head_too_large}
      {:error, _reason} = error -> error
    end
  end

  def encode(_snapshot), do: {:error, :invalid_checkpoint_snapshot}

  @spec decode(binary()) :: {:ok, t()} | {:error, :corrupt_checkpoint_head}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_encoded_size,
    do: bounded_decode(bytes)

  def decode(_bytes), do: {:error, :corrupt_checkpoint_head}

  defp bounded_decode(bytes) do
    owner = self()
    result_ref = make_ref()

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          current_worker = self()
          _watcher = spawn(fn -> stop_decode_on_owner_exit(owner, current_worker) end)
          send(owner, {result_ref, decode_now(bytes)})
        end,
        [
          :monitor,
          {:max_heap_size, %{size: @decode_max_heap_words, kill: true, error_logger: false}}
        ]
      )

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :corrupt_checkpoint_head}
    after
      @decode_timeout_ms ->
        Process.exit(worker, :kill)
        await_decode_down(worker, monitor)
        drain_decode_result(result_ref)
        {:error, :corrupt_checkpoint_head}
    end
  end

  defp decode_now(bytes) do
    term = safe_term(bytes)

    case term do
      {@format_version, @snapshot_tag, snapshot} when is_map(snapshot) ->
        decode_current_snapshot(snapshot)

      {@legacy_format_version, @snapshot_tag, snapshot} when is_map(snapshot) ->
        decode_legacy_snapshot(snapshot)

      legacy_or_corrupt ->
        decode_legacy_record(legacy_or_corrupt)
    end
  end

  defp stop_decode_on_owner_exit(owner, worker) do
    owner_monitor = Process.monitor(owner)
    worker_monitor = Process.monitor(worker)

    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        Process.exit(worker, :kill)
        await_decode_down(worker, worker_monitor)

      {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
        :ok
    end
  end

  defp await_decode_down(worker, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      @decode_timeout_ms -> Process.demonitor(monitor, [:flush])
    end
  end

  defp drain_decode_result(result_ref) do
    receive do
      {^result_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  @spec verify(map()) :: :ok | {:error, atom()}
  def verify(snapshot) when is_map(snapshot) do
    with :ok <- exact_keys(snapshot, @snapshot_keys),
         current when is_map(current) <- Map.get(snapshot, :current),
         :ok <- Record.verify(current),
         last_accepted <- Map.get(snapshot, :last_accepted),
         ancestry <- Map.get(snapshot, :ancestry),
         ancestry_truncated <- Map.get(snapshot, :ancestry_truncated),
         :ok <-
           verify_snapshot_ancestry(
             current,
             last_accepted,
             ancestry,
             ancestry_truncated
           ),
         expected when is_binary(expected) <- Map.get(snapshot, :snapshot_hash),
         true <- secure_equal(expected, snapshot_hash(Map.delete(snapshot, :snapshot_hash))) do
      :ok
    else
      _error -> {:error, :corrupt_checkpoint_head}
    end
  end

  def verify(_snapshot), do: {:error, :corrupt_checkpoint_head}

  defp decode_current_snapshot(snapshot) do
    with :ok <- exact_keys(snapshot, @snapshot_keys),
         :ok <- verify(snapshot) do
      {:ok, snapshot}
    else
      _error -> {:error, :corrupt_checkpoint_head}
    end
  end

  defp decode_legacy_snapshot(snapshot) do
    with :ok <- exact_keys(snapshot, @legacy_snapshot_keys),
         :ok <- verify_legacy_snapshot(snapshot),
         {:ok, migrated} <- migrate_legacy_snapshot(snapshot) do
      {:ok, migrated}
    else
      _error -> {:error, :corrupt_checkpoint_head}
    end
  end

  defp verify_legacy_snapshot(snapshot) do
    with current when is_map(current) <- Map.get(snapshot, :current),
         :ok <- Record.verify(current),
         last_accepted <- Map.get(snapshot, :last_accepted),
         :ok <- verify_legacy_last_accepted(current, last_accepted),
         expected when is_binary(expected) <- Map.get(snapshot, :snapshot_hash),
         true <-
           secure_equal(expected, legacy_snapshot_hash(Map.delete(snapshot, :snapshot_hash))) do
      :ok
    else
      _error -> {:error, :corrupt_checkpoint_head}
    end
  end

  defp decode_legacy_record(term) do
    with {:ok, current} <- Record.decode_term(term),
         {:ok, snapshot} <- migrate_legacy_record(current) do
      {:ok, snapshot}
    else
      _error -> {:error, :corrupt_checkpoint_head}
    end
  end

  defp migrate_legacy_snapshot(%{current: %{accepted: true} = current}),
    do: migrate_legacy_record(current)

  defp migrate_legacy_snapshot(%{
         current: %{accepted: false, parent_hash: parent_hash} = current,
         last_accepted: nil
       }) do
    if secure_equal(parent_hash, Record.genesis_parent()),
      do: build(current, nil, [], false),
      else: build(current, :unknown, :unknown, false)
  end

  defp migrate_legacy_snapshot(%{current: %{accepted: false} = current}),
    do: build(current, :unknown, :unknown, false)

  defp migrate_legacy_record(%{accepted: true} = current) do
    with {:ok, last_accepted} <- accepted_summary(current) do
      build(current, last_accepted)
    end
  end

  defp migrate_legacy_record(%{accepted: false} = current),
    do: build(current, :unknown, :unknown, false)

  defp infer_ancestry(%{accepted: true} = current, last_accepted),
    do: infer_accepted_ancestry(current, last_accepted)

  defp infer_ancestry(%{accepted: false, parent_hash: parent_hash}, nil) do
    if secure_equal(parent_hash, Record.genesis_parent()),
      do: {:ok, [], false},
      else: {:error, :invalid_checkpoint_snapshot}
  end

  defp infer_ancestry(%{accepted: false}, :unknown), do: {:ok, :unknown, false}

  defp infer_ancestry(%{accepted: false, parent_hash: parent_hash}, last_accepted)
       when is_map(last_accepted) do
    if secure_equal(parent_hash, Map.get(last_accepted, :checkpoint_hash)) do
      ancestry_truncated =
        not secure_equal(last_accepted.parent_hash, Record.genesis_parent())

      {:ok, [ordinary_summary(last_accepted)], ancestry_truncated}
    else
      {:error, :invalid_checkpoint_snapshot}
    end
  end

  defp infer_ancestry(_current, _last_accepted),
    do: {:error, :invalid_checkpoint_snapshot}

  defp infer_accepted_ancestry(current, last_accepted) when is_map(last_accepted) do
    if secure_equal(current.parent_hash, Record.genesis_parent()),
      do: {:ok, [], false},
      else: {:ok, [], true}
  end

  defp infer_accepted_ancestry(_current, _last_accepted),
    do: {:error, :invalid_checkpoint_snapshot}

  defp verify_snapshot_ancestry(
         %{accepted: true} = current,
         last_accepted,
         ancestry,
         ancestry_truncated
       )
       when is_list(ancestry) and is_boolean(ancestry_truncated) do
    with :ok <- bounded_ancestry(ancestry),
         :ok <- verify_current_acceptance(current, last_accepted),
         :ok <- verify_ancestry_entries(ancestry),
         :ok <- verify_chain_links(current, ancestry),
         :ok <- verify_chain_extent(current, ancestry, ancestry_truncated) do
      :ok
    else
      _error -> {:error, :invalid_checkpoint_snapshot}
    end
  end

  defp verify_snapshot_ancestry(
         %{accepted: false},
         last_accepted,
         :unknown,
         false
       )
       when last_accepted in [nil, :unknown],
       do: :ok

  defp verify_snapshot_ancestry(
         %{accepted: false} = current,
         last_accepted,
         ancestry,
         ancestry_truncated
       )
       when is_list(ancestry) and is_boolean(ancestry_truncated) do
    with :ok <- bounded_ancestry(ancestry),
         :ok <- verify_ancestry_entries(ancestry),
         :ok <- verify_chain_links(current, ancestry),
         :ok <- verify_local_chain_extent(current, last_accepted, ancestry, ancestry_truncated) do
      :ok
    else
      _error -> {:error, :invalid_checkpoint_snapshot}
    end
  end

  defp verify_snapshot_ancestry(
         _current,
         _last_accepted,
         _ancestry,
         _ancestry_truncated
       ),
       do: {:error, :invalid_checkpoint_snapshot}

  defp verify_current_acceptance(current, last_accepted) do
    with :ok <- verify_watermark_identity(current, last_accepted),
         true <- secure_equal(current.checkpoint_hash, last_accepted.checkpoint_hash) do
      :ok
    else
      _error -> {:error, :invalid_checkpoint_snapshot}
    end
  end

  defp verify_watermark_identity(current, last_accepted) do
    with :ok <- verify_accepted_summary(last_accepted),
         true <- secure_equal(current.device_id, last_accepted.device_id),
         true <- current.local_credential_epoch == last_accepted.local_credential_epoch,
         true <- secure_equal(current.local_storage_epoch, last_accepted.local_storage_epoch),
         true <- current.kind == last_accepted.kind do
      :ok
    else
      _error -> {:error, :invalid_checkpoint_snapshot}
    end
  end

  defp verify_unordered_watermark(current, last_accepted) do
    with :ok <- verify_watermark_identity(current, last_accepted),
         false <- secure_equal(current.checkpoint_hash, last_accepted.checkpoint_hash),
         false <- secure_equal(last_accepted.parent_hash, current.checkpoint_hash),
         false <- accepted_watermark_ahead_by_sequence?(current, last_accepted) do
      :ok
    else
      _error -> {:error, :invalid_checkpoint_snapshot}
    end
  end

  defp verify_chain_links(current, ancestry) do
    result =
      Enum.reduce_while(ancestry, {:ok, current.parent_hash, MapSet.new()}, fn summary,
                                                                               {:ok, expected,
                                                                                seen} ->
        cond do
          not secure_equal(expected, summary.checkpoint_hash) ->
            {:halt, {:error, :invalid_checkpoint_snapshot}}

          not secure_equal(current.device_id, summary.device_id) or current.kind != summary.kind ->
            {:halt, {:error, :invalid_checkpoint_snapshot}}

          MapSet.member?(seen, summary.checkpoint_hash) ->
            {:halt, {:error, :invalid_checkpoint_snapshot}}

          true ->
            {:cont, {:ok, summary.parent_hash, MapSet.put(seen, summary.checkpoint_hash)}}
        end
      end)

    case result do
      {:ok, _tail_parent, _seen} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp verify_chain_extent(current, ancestry, false) do
    if secure_equal(tail_parent_hash(current, ancestry), Record.genesis_parent()),
      do: :ok,
      else: {:error, :invalid_checkpoint_snapshot}
  end

  defp verify_chain_extent(current, ancestry, true) do
    if secure_equal(tail_parent_hash(current, ancestry), Record.genesis_parent()),
      do: {:error, :invalid_checkpoint_snapshot},
      else: :ok
  end

  defp verify_local_chain_extent(current, nil, ancestry, ancestry_truncated) do
    verify_chain_extent(current, ancestry, ancestry_truncated)
  end

  defp verify_local_chain_extent(_current, :unknown, _ancestry, _ancestry_truncated),
    do: {:error, :invalid_checkpoint_snapshot}

  defp verify_local_chain_extent(current, last_accepted, ancestry, ancestry_truncated)
       when is_map(last_accepted) do
    with :ok <- verify_watermark_identity(current, last_accepted) do
      cond do
        is_integer(retained_index(ancestry, last_accepted.checkpoint_hash)) ->
          verify_chain_extent(current, ancestry, ancestry_truncated)

        retained_boundary_hash?(
          ancestry,
          ancestry_truncated,
          last_accepted.checkpoint_hash
        ) ->
          verify_chain_extent(current, ancestry, true)

        ancestry_truncated ->
          with :ok <- verify_unordered_watermark(current, last_accepted) do
            verify_chain_extent(current, ancestry, true)
          end

        true ->
          {:error, :invalid_checkpoint_snapshot}
      end
    end
  end

  defp verify_local_chain_extent(_current, _last_accepted, _ancestry, _ancestry_truncated),
    do: {:error, :invalid_checkpoint_snapshot}

  defp tail_parent_hash(current, []), do: current.parent_hash

  defp tail_parent_hash(_current, ancestry),
    do: ancestry |> List.last() |> Map.fetch!(:parent_hash)

  defp bounded_ancestry(ancestry) do
    case RuntimeSnapshot.bounded_list(ancestry, @max_ancestry_entries) do
      :ok -> :ok
      :error -> {:error, :invalid_checkpoint_snapshot}
    end
  end

  defp verify_ancestry_entries(ancestry) do
    Enum.reduce_while(ancestry, :ok, fn summary, :ok ->
      case verify_record_summary(summary) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :invalid_checkpoint_snapshot}}
      end
    end)
  end

  defp verify_legacy_last_accepted(%{accepted: true} = current, last_accepted) do
    with :ok <- verify_record_summary(last_accepted),
         true <- secure_equal(current.checkpoint_hash, last_accepted.checkpoint_hash) do
      :ok
    else
      _error -> {:error, :invalid_checkpoint_snapshot}
    end
  end

  defp verify_legacy_last_accepted(current, nil) do
    if current.accepted,
      do: {:error, :invalid_checkpoint_snapshot},
      else: :ok
  end

  defp verify_legacy_last_accepted(%{accepted: false}, :unknown), do: :ok

  defp verify_legacy_last_accepted(current, last_accepted) do
    with :ok <- verify_record_summary(last_accepted),
         true <- secure_equal(current.device_id, last_accepted.device_id),
         true <- current.kind == last_accepted.kind do
      cond do
        secure_equal(current.parent_hash, last_accepted.checkpoint_hash) ->
          :ok

        secure_equal(current.checkpoint_hash, last_accepted.checkpoint_hash) ->
          {:error, :invalid_checkpoint_snapshot}

        secure_equal(last_accepted.parent_hash, current.checkpoint_hash) ->
          {:error, :invalid_checkpoint_snapshot}

        accepted_watermark_ahead_by_sequence?(current, last_accepted) ->
          {:error, :invalid_checkpoint_snapshot}

        true ->
          :ok
      end
    else
      _error -> {:error, :invalid_checkpoint_snapshot}
    end
  end

  defp accepted_watermark_ahead_by_sequence?(current, last_accepted) do
    current.origin_credential_epoch == last_accepted.origin_credential_epoch and
      secure_equal(current.origin_storage_epoch, last_accepted.origin_storage_epoch) and
      last_accepted.sequence > current.sequence
  end

  defp verify_record_summary(summary) when is_map(summary) do
    with :ok <- exact_keys(summary, @summary_keys),
         {:ok, checkpoint_hash} <-
           Checkpoint.hash(%{
             device_id: summary.device_id,
             credential_epoch: summary.origin_credential_epoch,
             storage_epoch: summary.origin_storage_epoch,
             sequence: summary.sequence,
             kind: summary.kind,
             schema_version: summary.schema_version,
             source_generation: summary.source_generation,
             parent_hash: summary.parent_hash,
             content_hash: summary.content_hash
           }),
         true <- secure_equal(checkpoint_hash, summary.checkpoint_hash) do
      :ok
    else
      _error -> {:error, :invalid_accepted_checkpoint}
    end
  end

  defp verify_record_summary(_summary), do: {:error, :invalid_accepted_checkpoint}

  defp verify_accepted_summary(summary) when is_map(summary) do
    with :ok <- exact_keys(summary, @accepted_summary_keys),
         :ok <- verify_record_summary(ordinary_summary(summary)),
         true <- Record.accepted_binding?(summary) do
      :ok
    else
      _error -> {:error, :invalid_accepted_checkpoint}
    end
  end

  defp verify_accepted_summary(_summary), do: {:error, :invalid_accepted_checkpoint}

  defp snapshot_hash(%{
         current: current,
         last_accepted: last_accepted,
         ancestry: ancestry,
         ancestry_truncated: ancestry_truncated
       }) do
    {:ok, current_bytes} = Record.encode(current)
    accepted_bytes = encode_accepted_summary(last_accepted)
    ancestry_bytes = encode_ancestry(ancestry)
    truncated = if ancestry_truncated, do: 1, else: 0

    :crypto.hash(
      :sha256,
      @binding_domain <>
        <<@binding_version, byte_size(current_bytes)::32, current_bytes::binary,
          byte_size(accepted_bytes)::16, accepted_bytes::binary, truncated,
          byte_size(ancestry_bytes)::32, ancestry_bytes::binary>>
    )
  end

  defp legacy_snapshot_hash(%{current: current, last_accepted: last_accepted}) do
    {:ok, current_bytes} = Record.encode(current)
    accepted_bytes = encode_record_summary(last_accepted)

    :crypto.hash(
      :sha256,
      @legacy_binding_domain <>
        <<@legacy_binding_version, byte_size(current_bytes)::32, current_bytes::binary,
          byte_size(accepted_bytes)::16, accepted_bytes::binary>>
    )
  end

  defp encode_ancestry(:unknown), do: <<0xFF>>

  defp encode_ancestry(ancestry) when is_list(ancestry) do
    [<<length(ancestry)::16>> | Enum.map(ancestry, &encode_record_summary/1)]
    |> IO.iodata_to_binary()
  end

  defp encode_accepted_summary(nil), do: <<>>
  defp encode_accepted_summary(:unknown), do: <<0xFF>>

  defp encode_accepted_summary(summary) do
    encode_record_summary(summary) <>
      <<summary.local_credential_epoch::32, summary.local_storage_epoch::binary-size(16),
        summary.binding_hash::binary-size(32)>>
  end

  defp encode_record_summary(nil), do: <<>>
  defp encode_record_summary(:unknown), do: <<0xFF>>

  defp encode_record_summary(summary) do
    {:ok, kind_code, _schema_version} = Contract.checkpoint_kind(summary.kind)

    <<summary.device_id::binary-size(16), summary.origin_credential_epoch::32,
      summary.origin_storage_epoch::binary-size(16), summary.sequence::64, kind_code,
      summary.schema_version::16, summary.source_generation::64,
      summary.parent_hash::binary-size(32), summary.content_hash::binary-size(32),
      summary.checkpoint_hash::binary-size(32)>>
  end

  defp local_successor_ancestry(ancestry, last_accepted, ancestry_truncated)
       when is_map(last_accepted) do
    case retained_index(ancestry, last_accepted.checkpoint_hash) do
      index when is_integer(index) ->
        {compacted, truncated} = compact_ancestry(ancestry, ancestry_truncated)
        {:ok, compacted, truncated}

      nil when ancestry_truncated ->
        {compacted, truncated} = compact_ancestry(ancestry, true)
        {:ok, compacted, truncated}

      nil ->
        {:error, :invalid_checkpoint_snapshot}
    end
  end

  defp local_successor_ancestry(ancestry, nil, ancestry_truncated) do
    {compacted, truncated} = compact_ancestry(ancestry, ancestry_truncated)
    {:ok, compacted, truncated}
  end

  defp local_successor_ancestry(_ancestry, _last_accepted, _ancestry_truncated),
    do: {:error, :invalid_checkpoint_snapshot}

  defp compact_ancestry(ancestry, ancestry_truncated) do
    case RuntimeSnapshot.bounded_list(ancestry, @max_ancestry_entries) do
      :ok -> {ancestry, ancestry_truncated}
      :error -> {Enum.take(ancestry, @max_ancestry_entries), true}
    end
  end

  defp ordinary_summary(summary), do: Map.take(summary, @summary_keys)

  defp accepted_hash(%{checkpoint_hash: checkpoint_hash}), do: checkpoint_hash
  defp accepted_hash(_last_accepted), do: nil

  defp accepted_hash?(%{checkpoint_hash: accepted_hash}, checkpoint_hash),
    do: secure_equal(accepted_hash, checkpoint_hash)

  defp accepted_hash?(_last_accepted, _checkpoint_hash), do: false

  defp retained_hash?(ancestry, checkpoint_hash) when is_list(ancestry),
    do: is_integer(retained_index(ancestry, checkpoint_hash))

  defp retained_hash?(_ancestry, _checkpoint_hash), do: false

  defp retained_index(ancestry, checkpoint_hash)
       when is_list(ancestry) and is_binary(checkpoint_hash) do
    Enum.find_index(ancestry, &secure_equal(&1.checkpoint_hash, checkpoint_hash))
  end

  defp retained_index(_ancestry, _checkpoint_hash), do: nil

  defp retained_boundary_hash?(ancestry, true, checkpoint_hash)
       when is_list(ancestry) and is_binary(checkpoint_hash) do
    case List.last(ancestry) do
      %{parent_hash: parent_hash} -> secure_equal(parent_hash, checkpoint_hash)
      _empty -> false
    end
  end

  defp retained_boundary_hash?(_ancestry, _ancestry_truncated, _checkpoint_hash),
    do: false

  defp safe_term(<<131, 80, _compressed::binary>>), do: :corrupt

  defp safe_term(bytes) do
    case :erlang.binary_to_term(bytes, [:safe, :used]) do
      {term, used} when used == byte_size(bytes) -> term
      _partial -> :corrupt
    end
  rescue
    _exception -> :corrupt
  catch
    _kind, _reason -> :corrupt
  end

  defp exact_keys(value, expected) when is_map(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(expected),
      do: :ok,
      else: {:error, :invalid_checkpoint_snapshot}
  end

  defp exact_keys(_value, _expected), do: {:error, :invalid_checkpoint_snapshot}

  defp secure_equal(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_equal(_left, _right), do: false
end