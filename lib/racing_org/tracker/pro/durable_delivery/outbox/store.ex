defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Store do
  @moduledoc """
  Pure state handle for a bounded, durable, segmented outbox.

  Mutations append one checksummed record and fsync the segment before returning
  success. Acknowledgements and explicit loss authorizations are themselves
  durable records, so restart replay never treats an in-memory deletion as
  authoritative. Complete corrupt records quarantine their segment and block the
  store; only an incomplete final record may be truncated to its last valid
  boundary. A caller receiving `{:durability_uncertain, reason}` must discard
  that handle and reopen the root before attempting another mutation.

  The caller must authenticate and decode delivery receipts before passing the
  resulting map to `acknowledge/2`. This module intentionally does not depend on
  a wire receipt implementation; it revalidates the exact durable identity at
  the storage boundary.

  Durable identity is `device_id + credential_epoch + storage_epoch + stream +
  sequence + payload_hash`. The transient boot ID is deliberately excluded, so
  identity survives a reboot on unchanged storage. Reopening a root under a
  different device ID or credential epoch fails closed rather than adopting the
  persisted origin.
  """

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.{Entry, FileSystem, Record, RunState, Snapshot}

  @dir_mode 0o700
  @file_mode 0o600
  @segment_pattern ~r/^segment-(\d{20})\.log$/
  @snapshot_temp_pattern ~r/^snapshot\.bin\.tmp\.[0-9a-f]+$/
  @run_state_temp_pattern ~r/^run-state\.bin\.tmp\.[0-9a-f]+$/
  @run_state_marker "RODM\x01"
  @snapshot_schema_version 3
  @default_max_loss_authorizations 128
  @default_max_entry_id_tombstones 4_096
  @default_max_resolved_receipts 4_096
  @checkpoint_priority 0
  @entry_id_tombstone_domain "RacingOrg-DurableOutboxEntryIdTombstone-v1"
  @max_symlink_hops 40
  @u32_max 0xFFFF_FFFF
  @zero_device_id <<0::128>>

  # A root recorded under a different origin identity is intact data belonging to
  # another incarnation, not corruption. Fail closed and leave it untouched
  # rather than quarantining (and thereby destroying) it.
  @origin_mismatch_reasons [:device_id_mismatch, :credential_epoch_mismatch, :storage_epoch_mismatch]

  @enforce_keys [
    :root_path,
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :stream_names,
    :streams_by_name,
    :max_entries,
    :max_bytes,
    :max_disk_bytes,
    :segment_max_bytes,
    :max_loss_authorizations,
    :max_entry_id_tombstones,
    :max_resolved_receipts,
    :file_system,
    :entry_id_generator
  ]
  defstruct @enforce_keys ++
              [
                entries: [],
                live_bytes: 0,
                disk_bytes: 0,
                snapshot_bytes: 0,
                snapshot_hash: nil,
                snapshot_covered_segment_id: 0,
                run_state_bytes: 0,
                run_state_hash: nil,
                run_state_marker_bytes: 0,
                segment_high_water: 0,
                committed_segment_sizes: %{},
                run_state_required: false,
                sequence_floors: %{},
                acknowledged_floors: %{},
                entry_id_history_complete: true,
                entry_id_tombstones: [],
                resolved_receipts: [],
                segment_paths: [],
                segment_sizes: %{},
                next_sequences: %{},
                seen_entry_ids: MapSet.new(),
                loss_authorizations: [],
                next_ordinal: 1,
                current_segment_id: 0,
                current_segment_path: nil,
                current_segment_bytes: 0
              ]

  @type t :: %__MODULE__{
          root_path: Path.t(),
          device_id: <<_::128>>,
          credential_epoch: non_neg_integer(),
          storage_epoch: <<_::128>>,
          stream_names: %{required(atom()) => binary()},
          streams_by_name: %{required(binary()) => atom()},
          max_entries: pos_integer(),
          max_bytes: pos_integer(),
          max_disk_bytes: pos_integer(),
          segment_max_bytes: pos_integer(),
          max_loss_authorizations: pos_integer(),
          max_entry_id_tombstones: pos_integer(),
          max_resolved_receipts: pos_integer(),
          file_system: module(),
          entry_id_generator: (-> binary()),
          entries: [Entry.t()],
          live_bytes: non_neg_integer(),
          disk_bytes: non_neg_integer(),
          snapshot_bytes: non_neg_integer(),
          snapshot_hash: <<_::256>> | nil,
          snapshot_covered_segment_id: non_neg_integer(),
          run_state_bytes: non_neg_integer(),
          run_state_hash: <<_::256>> | nil,
          run_state_marker_bytes: non_neg_integer(),
          segment_high_water: non_neg_integer(),
          committed_segment_sizes: %{optional(pos_integer()) => non_neg_integer()},
          run_state_required: boolean(),
          sequence_floors: %{required(atom()) => pos_integer()},
          acknowledged_floors: %{required(atom()) => non_neg_integer()},
          entry_id_history_complete: boolean(),
          entry_id_tombstones: [<<_::256>>],
          resolved_receipts: [map()],
          segment_paths: [Path.t()],
          segment_sizes: %{required(Path.t()) => non_neg_integer()},
          next_sequences: %{required(atom()) => pos_integer()},
          seen_entry_ids: MapSet.t(binary()),
          loss_authorizations: [map()],
          next_ordinal: pos_integer(),
          current_segment_id: non_neg_integer(),
          current_segment_path: Path.t() | nil,
          current_segment_bytes: non_neg_integer()
        }

  @doc false
  @spec canonical_root(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonical_root(root_path) when is_binary(root_path) and root_path != "" do
    root_path
    |> Path.expand()
    |> canonicalize_path(@max_symlink_hops)
  end

  def canonical_root(_root_path), do: {:error, :invalid_root}

  @doc "Open a root and replay all segments into an outbox state handle."
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(root_path, opts) when is_binary(root_path) and is_list(opts) do
    with {:ok, store} <- new_store(root_path, opts) do
      with_mutation_lock(store, fn -> do_open(store) end)
    end
  end

  def open(_root_path, _opts), do: {:error, :invalid_options}

  defp do_open(store) do
    with :ok <- ensure_root(store),
         :ok <- ensure_not_quarantined(store),
         {:ok, store} <- load_snapshot(store),
         {:ok, store} <- load_run_state_marker(store),
         {:ok, store} <- load_run_state(store),
         :ok <- reclaim_orphan_temps(store),
         {:ok, segments} <- list_segments(store),
         {:ok, store, active_segments} <- discard_superseded_segments(store, segments),
         :ok <- validate_segment_sequence(active_segments, store.snapshot_covered_segment_id + 1),
         :ok <- validate_segment_high_water(store, active_segments),
         {:ok, active_segments} <- prepare_segments(store, active_segments),
         :ok <- ensure_prepared_disk_capacity(store, active_segments),
         {:ok, store, truncation} <- scan_segments(store, active_segments),
         :ok <- validate_sequence_floors(store),
         {:ok, store} <- apply_recovery_truncation(store, truncation),
         {:ok, store} <- persist_run_state(store),
         {:ok, store} <- ensure_run_state_marker(store) do
      {:ok, store}
    end
  end

  @doc "Append and fsync one new entry before exposing enqueue success."
  @spec enqueue(t(), atom(), binary(), keyword()) ::
          {:ok, Entry.t(), t()} | {:error, term()}
  def enqueue(%__MODULE__{} = store, stream, payload, opts \\ []) do
    with_mutation_lock(store, fn -> do_enqueue(store, stream, payload, opts) end)
  end

  @doc "Build and durably append one checkpoint payload under its exact locked sequence."
  @spec enqueue_checkpoint(t(), (pos_integer() -> {:ok, binary()} | {:error, term()}), keyword()) ::
          {:ok, Entry.t(), t()} | {:error, term()}
  def enqueue_checkpoint(store, builder, opts \\ [])

  def enqueue_checkpoint(%__MODULE__{} = store, builder, opts) when is_function(builder, 1) do
    with_mutation_lock(store, fn -> do_enqueue_checkpoint(store, builder, opts) end)
  end

  def enqueue_checkpoint(%__MODULE__{}, _builder, _opts), do: {:error, :invalid_checkpoint_builder}

  defp do_enqueue(store, stream, payload, opts) do
    with :ok <- complete_entry_id_history(store),
         {:ok, stream_name} <- configured_stream_name(store, stream),
         :ok <- generic_enqueue_stream(stream),
         :ok <- validate_payload(payload),
         {:ok, priority} <- priority(opts),
         {:ok, entry_id} <- entry_id(store, opts),
         :ok <- unique_entry_id(store, entry_id),
         sequence <- Map.fetch!(store.next_sequences, stream) do
      append_entry(store, stream, stream_name, sequence, entry_id, payload, priority)
    end
  end

  defp do_enqueue_checkpoint(store, builder, opts) do
    with :ok <- complete_entry_id_history(store),
         {:ok, stream_name} <- configured_stream_name(store, :checkpoint),
         :ok <- verify_fresh(store),
         {:ok, entry_id} <- entry_id(store, opts),
         :ok <- unique_entry_id(store, entry_id),
         sequence <- Map.fetch!(store.next_sequences, :checkpoint),
         {:ok, payload} <- checkpoint_payload(builder, sequence),
         :ok <- validate_payload(payload) do
      append_entry(
        store,
        :checkpoint,
        stream_name,
        sequence,
        entry_id,
        payload,
        @checkpoint_priority
      )
    end
  end

  defp append_entry(store, stream, stream_name, sequence, entry_id, payload, priority) do
    payload_hash = :crypto.hash(:sha256, payload)

    with {:ok, encoded} <-
           Record.encode(%{
             kind: :entry,
             stream: stream_name,
             device_id: store.device_id,
             credential_epoch: store.credential_epoch,
             storage_epoch: store.storage_epoch,
             sequence: sequence,
             entry_id: entry_id,
             payload_hash: payload_hash,
             payload: payload,
             priority: priority
           }),
         :ok <- capacity_available(store, byte_size(encoded)),
         entry = %Entry{
           stream: stream,
           device_id: store.device_id,
           credential_epoch: store.credential_epoch,
           storage_epoch: store.storage_epoch,
           sequence: sequence,
           entry_id: entry_id,
           payload_hash: payload_hash,
           payload: payload,
           priority: priority,
           encoded_size: byte_size(encoded),
           ordinal: store.next_ordinal
         },
         prospective = add_entry(store, entry),
         covered_segment_id <- append_segment_id(store, byte_size(encoded)),
         {:ok, snapshot_bytes} <- encode_snapshot(prospective, covered_segment_id),
         {:ok, appended} <- append_encoded(store, encoded, byte_size(snapshot_bytes)),
         committed = add_entry(appended, entry),
         {:ok, committed} <- persist_run_state_after_append(committed) do
      {:ok, entry, committed}
    end
  end

  @doc "Return pending entries in priority order, retaining FIFO within a priority."
  @spec pending(t(), keyword()) :: [Entry.t()] | {:error, term()}
  def pending(store, opts \\ [])

  def pending(%__MODULE__{} = store, opts) when is_list(opts) do
    with {:ok, stream} <- pending_stream(store, opts),
         {:ok, limit} <- pending_limit(opts) do
      store.entries
      |> filter_pending_stream(stream)
      |> Enum.sort_by(&{-&1.priority, &1.ordinal})
      |> limit_pending(limit)
    end
  end

  def pending(%__MODULE__{}, _opts), do: {:error, :invalid_options}

  @doc "Return the next sequence that will be allocated for a configured stream."
  @spec next_sequence(t(), atom()) :: {:ok, pos_integer()} | {:error, :unknown_stream}
  def next_sequence(%__MODULE__{next_sequences: sequences}, stream) do
    case Map.fetch(sequences, stream) do
      {:ok, sequence} -> {:ok, sequence}
      :error -> {:error, :unknown_stream}
    end
  end

  @doc "Return current live entry and encoded-byte capacity usage."
  @spec usage(t()) :: %{
          entries: non_neg_integer(),
          bytes: non_neg_integer(),
          disk_bytes: non_neg_integer()
        }
  def usage(%__MODULE__{} = store) do
    %{entries: length(store.entries), bytes: store.live_bytes, disk_bytes: store.disk_bytes}
  end

  @doc "Return replayed explicit loss authorization audit records."
  @spec loss_authorizations(t()) :: [map()]
  def loss_authorizations(%__MODULE__{loss_authorizations: authorizations}), do: authorizations

  @doc "Return whether bounded durable history proves this exact six-field receipt identity was resolved."
  @spec resolved_receipt?(t(), map()) :: boolean()
  def resolved_receipt?(%__MODULE__{} = store, receipt) when is_map(receipt) do
    case validate_identity(store, receipt) do
      {:ok, identity} -> Enum.any?(store.resolved_receipts, &same_receipt_identity?(&1, identity))
      {:error, _reason} -> false
    end
  end

  def resolved_receipt?(%__MODULE__{}, _receipt), do: false

  @doc """
  Durably apply an already authenticated receipt map.

  The exact stream, storage epoch, sequence, and payload hash must match a live
  entry. A cumulative sequence may additionally remove only a numerically
  contiguous prefix of the currently pending entries for that stream.
  """
  @spec acknowledge(t(), map()) :: {:ok, [Entry.t()], t()} | {:error, term()}
  def acknowledge(%__MODULE__{} = store, receipt) when is_map(receipt) do
    with_mutation_lock(store, fn -> do_acknowledge(store, receipt) end)
  end

  def acknowledge(%__MODULE__{}, _receipt), do: {:error, :invalid_receipt}

  defp do_acknowledge(store, receipt) do
    with {:ok, normalized} <- validate_receipt(store, receipt),
         {:ok, removed} <- acknowledged_entries(store, normalized),
         {:ok, stream_name} <- configured_stream_name(store, normalized.stream),
         {:ok, encoded} <-
           Record.encode(%{
             kind: :acknowledgement,
             stream: stream_name,
             device_id: normalized.device_id,
             credential_epoch: normalized.credential_epoch,
             storage_epoch: normalized.storage_epoch,
             sequence: normalized.sequence,
             payload_hash: normalized.payload_hash,
             cumulative_sequence: normalized.cumulative_sequence
           }),
         covered_segment_id <- append_segment_id(store, byte_size(encoded)),
         resolved = apply_acknowledgement_state(store, removed),
         {:ok, snapshot_bytes} <- encode_snapshot(resolved, covered_segment_id),
         {:ok, appended} <- append_encoded(store, encoded, byte_size(snapshot_bytes)),
         resolved = apply_acknowledgement_state(appended, removed),
         {:ok, resolved} <- persist_run_state_after_append(resolved),
         {:ok, compacted} <- compact_store(resolved, snapshot_bytes) do
      {:ok, removed, compacted}
    end
  end

  @doc "Durably authorize exact entry loss with a non-empty human-auditable reason."
  @spec authorize_loss(t(), map(), binary()) :: {:ok, Entry.t(), t()} | {:error, term()}
  def authorize_loss(%__MODULE__{} = store, identity, reason) when is_map(identity) do
    with_mutation_lock(store, fn -> do_authorize_loss(store, identity, reason) end)
  end

  def authorize_loss(%__MODULE__{}, _identity, _reason), do: {:error, :invalid_loss_identity}

  defp do_authorize_loss(store, identity, reason) do
    with :ok <- validate_loss_reason(reason),
         {:ok, normalized} <- validate_identity(store, identity),
         {:ok, entry} <- matching_entry(store, normalized),
         {:ok, stream_name} <- configured_stream_name(store, normalized.stream),
         {:ok, encoded} <-
           Record.encode(%{
             kind: :loss_authorization,
             stream: stream_name,
             device_id: entry.device_id,
             credential_epoch: entry.credential_epoch,
             storage_epoch: entry.storage_epoch,
             sequence: entry.sequence,
             entry_id: entry.entry_id,
             payload_hash: entry.payload_hash,
             reason: reason
           }),
         authorization = authorization_from_entry(entry, reason),
         resolved = %{
           resolve_entries(store, [entry])
           | loss_authorizations:
               retain_latest(store.loss_authorizations ++ [authorization], store.max_loss_authorizations)
         },
         covered_segment_id <- append_segment_id(store, byte_size(encoded)),
         {:ok, snapshot_bytes} <- encode_snapshot(resolved, covered_segment_id),
         {:ok, appended} <- append_encoded(store, encoded, byte_size(snapshot_bytes)),
         resolved = %{
           resolve_entries(appended, [entry])
           | loss_authorizations:
               retain_latest(
                 appended.loss_authorizations ++ [authorization],
                 appended.max_loss_authorizations
               )
         },
         {:ok, resolved} <- persist_run_state_after_append(resolved),
         {:ok, compacted} <- compact_store(resolved, snapshot_bytes) do
      {:ok, entry, compacted}
    end
  end

  defp with_mutation_lock(store, operation) do
    lock = {{__MODULE__, store.root_path}, self()}

    case :global.trans(lock, operation) do
      {:aborted, reason} -> {:error, {:mutation_lock, reason}}
      result -> result
    end
  end

  defp new_store(root_path, opts) do
    with {:ok, root_path} <- canonical_root(root_path),
         {:ok, device_id} <- option_device_id(opts),
         {:ok, credential_epoch} <- option_credential_epoch(opts),
         {:ok, storage_epoch} <- option_storage_epoch(opts),
         {:ok, stream_names, streams_by_name} <- option_streams(opts),
         {:ok, max_entries} <- positive_option(opts, :max_entries),
         {:ok, max_bytes} <- positive_option(opts, :max_bytes),
         {:ok, segment_max_bytes} <- positive_option(opts, :segment_max_bytes),
         {:ok, max_disk_bytes} <- option_max_disk_bytes(opts, max_bytes, segment_max_bytes),
         {:ok, max_loss_authorizations} <-
           positive_option_default(opts, :max_loss_authorizations, @default_max_loss_authorizations),
         {:ok, max_entry_id_tombstones} <-
           positive_option_default(opts, :max_entry_id_tombstones, @default_max_entry_id_tombstones),
         {:ok, max_resolved_receipts} <-
           positive_option_default(opts, :max_resolved_receipts, @default_max_resolved_receipts),
         {:ok, file_system} <- option_file_system(opts),
         {:ok, entry_id_generator} <- option_entry_id_generator(opts) do
      {:ok,
       %__MODULE__{
         root_path: root_path,
         device_id: device_id,
         credential_epoch: credential_epoch,
         storage_epoch: storage_epoch,
         stream_names: stream_names,
         streams_by_name: streams_by_name,
         max_entries: max_entries,
         max_bytes: max_bytes,
         max_disk_bytes: max_disk_bytes,
         segment_max_bytes: segment_max_bytes,
         max_loss_authorizations: max_loss_authorizations,
         max_entry_id_tombstones: max_entry_id_tombstones,
         max_resolved_receipts: max_resolved_receipts,
         file_system: file_system,
         entry_id_generator: entry_id_generator,
         next_sequences: Map.new(stream_names, fn {stream, _name} -> {stream, 1} end),
         sequence_floors: Map.new(stream_names, fn {stream, _name} -> {stream, 1} end),
         acknowledged_floors: Map.new(stream_names, fn {stream, _name} -> {stream, 0} end)
       }}
    end
  end

  defp option_storage_epoch(opts) do
    case Keyword.fetch(opts, :storage_epoch) do
      {:ok, <<_::128>> = epoch} -> {:ok, epoch}
      _other -> {:error, :invalid_storage_epoch}
    end
  end

  defp option_device_id(opts) do
    case Keyword.fetch(opts, :device_id) do
      {:ok, @zero_device_id} -> {:error, :invalid_device_id}
      {:ok, <<_::128>> = device_id} -> {:ok, device_id}
      _other -> {:error, :invalid_device_id}
    end
  end

  defp option_credential_epoch(opts) do
    case Keyword.fetch(opts, :credential_epoch) do
      {:ok, epoch} when is_integer(epoch) and epoch >= 0 and epoch <= @u32_max -> {:ok, epoch}
      _other -> {:error, :invalid_credential_epoch}
    end
  end

  defp option_streams(opts) do
    case Keyword.fetch(opts, :streams) do
      {:ok, streams} when is_list(streams) and streams != [] ->
        names =
          Enum.map(streams, fn
            stream when is_atom(stream) -> Atom.to_string(stream)
            _stream -> nil
          end)

        if Enum.all?(streams, &is_atom/1) and length(Enum.uniq(streams)) == length(streams) and
             length(Enum.uniq(names)) == length(names) do
          {:ok, Map.new(Enum.zip(streams, names)), Map.new(Enum.zip(names, streams))}
        else
          {:error, :invalid_streams}
        end

      _other ->
        {:error, :invalid_streams}
    end
  end

  defp positive_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {:invalid_option, key}}
    end
  end

  defp positive_option_default(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {:invalid_option, key}}
    end
  end

  defp option_max_disk_bytes(opts, max_bytes, segment_max_bytes) do
    case Keyword.get(opts, :max_disk_bytes, max_bytes + segment_max_bytes) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {:invalid_option, :max_disk_bytes}}
    end
  end

  defp option_file_system(opts) do
    case Keyword.get(opts, :file_system, FileSystem) do
      module when is_atom(module) -> {:ok, module}
      _other -> {:error, {:invalid_option, :file_system}}
    end
  end

  defp option_entry_id_generator(opts) do
    case Keyword.get(opts, :entry_id_generator, fn -> :crypto.strong_rand_bytes(16) end) do
      generator when is_function(generator, 0) -> {:ok, generator}
      _other -> {:error, {:invalid_option, :entry_id_generator}}
    end
  end

  defp ensure_root(store) do
    fs = store.file_system

    with :ok <- fs_result(fs.mkdir_p(store.root_path), :mkdir),
         :ok <- fs_result(fs.chmod(store.root_path, @dir_mode), :chmod_directory),
         :ok <- sync_directory(store, Path.dirname(store.root_path)) do
      :ok
    end
  end

  defp ensure_not_quarantined(store) do
    case store.file_system.list_dir(quarantine_dir(store)) do
      {:ok, []} -> :ok
      {:ok, files} -> {:error, {:quarantined, Enum.sort(files)}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:quarantine_list, reason}}
      other -> {:error, {:quarantine_list, other}}
    end
  end

  defp reclaim_orphan_temps(store) do
    fs = store.file_system

    with {:ok, files} <- list_dir_result(fs.list_dir(store.root_path), :list_orphan_temps),
         temps <-
           Enum.filter(files, fn filename ->
             Regex.match?(@snapshot_temp_pattern, filename) or
               Regex.match?(@run_state_temp_pattern, filename)
           end),
         :ok <- remove_orphan_temps(store, temps) do
      :ok
    end
  end

  defp remove_orphan_temps(_store, []), do: :ok

  defp remove_orphan_temps(store, filenames) do
    result =
      Enum.reduce_while(filenames, :ok, fn filename, :ok ->
        path = Path.join(store.root_path, filename)

        case store.file_system.stat(path) do
          {:ok, %File.Stat{type: :regular}} ->
            case store.file_system.remove(path) do
              :ok ->
                {:cont, :ok}

              {:error, reason} ->
                operation =
                  if String.starts_with?(filename, "snapshot.bin.tmp."),
                    do: :remove_snapshot_temp,
                    else: :remove_run_state_temp

                {:halt, {:error, {:orphan_temp_cleanup, {operation, reason}}}}

              other ->
                {:halt, {:error, {:orphan_temp_cleanup, {:remove_temp, other}}}}
            end

          {:ok, %File.Stat{}} ->
            {:halt, {:error, {:orphan_temp_cleanup, :invalid_temp_type}}}

          {:error, reason} ->
            {:halt, {:error, {:orphan_temp_cleanup, {:stat_temp, reason}}}}

          other ->
            {:halt, {:error, {:orphan_temp_cleanup, {:stat_temp, other}}}}
        end
      end)

    with :ok <- result,
         :ok <- sync_directory(store, store.root_path) do
      :ok
    end
  end

  defp load_run_state_marker(store) do
    path = run_state_marker_path(store)
    fs = store.file_system

    case fs.stat(path) do
      {:error, :enoent} ->
        {:ok, store}

      {:ok, %File.Stat{type: :regular, size: size}} when size == byte_size(@run_state_marker) ->
        with :ok <- fs_result(fs.chmod(path, @file_mode), :chmod_run_state_marker),
             {:ok, @run_state_marker} <- read_result(fs.read(path), :read_run_state_marker) do
          {:ok,
           %{
             store
             | disk_bytes: store.disk_bytes + size,
               run_state_marker_bytes: size,
               run_state_required: true
           }}
        else
          {:ok, _other} -> {:error, :invalid_run_state_marker}
          {:error, _reason} = error -> error
        end

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :invalid_run_state_marker}

      {:ok, %File.Stat{}} ->
        {:error, :invalid_run_state_marker_type}

      {:error, reason} ->
        {:error, {:stat_run_state_marker, reason}}

      other ->
        {:error, {:stat_run_state_marker, other}}
    end
  end

  defp load_run_state(store) do
    path = run_state_path(store)
    fs = store.file_system

    case fs.stat(path) do
      {:error, :enoent} when store.run_state_required ->
        {:error, :run_state_missing}

      {:error, :enoent} ->
        {:ok, store}

      {:ok, %File.Stat{type: :regular, size: size}} when size <= store.max_disk_bytes ->
        with :ok <- fs_result(fs.chmod(path, @file_mode), :chmod_run_state),
             {:ok, bytes} <- read_result(fs.read(path), :read_run_state),
             {:ok, state} <- RunState.decode(bytes),
             {:ok, hydrated} <- hydrate_run_state(store, state, size) do
          {:ok, %{hydrated | run_state_hash: :crypto.hash(:sha256, bytes)}}
        end

      {:ok, %File.Stat{type: :regular, size: size}} ->
        {:error, {:run_state_capacity_exceeded, size, store.max_disk_bytes}}

      {:ok, %File.Stat{}} ->
        {:error, :invalid_run_state_type}

      {:error, reason} ->
        {:error, {:stat_run_state, reason}}

      other ->
        {:error, {:stat_run_state, other}}
    end
  end

  defp hydrate_run_state(
         store,
         %{
           "device_id" => device_id,
           "credential_epoch" => credential_epoch,
           "storage_epoch" => storage_epoch,
           "streams" => streams,
           "segment_high_water" => segment_high_water,
           "sequence_floors" => sequence_floors
         } = state,
         size
       ) do
    with :ok <- exact_device_id(store, device_id),
         :ok <- exact_credential_epoch(store, credential_epoch),
         :ok <- exact_storage_epoch(store, storage_epoch),
         :ok <- hydrate_stream_set(store, streams, :invalid_run_state),
         true <- is_integer(segment_high_water) and segment_high_water >= store.snapshot_covered_segment_id,
         {:ok, committed_segment_sizes} <- hydrate_committed_segment_sizes(state, segment_high_water),
         {:ok, floors} <- hydrate_next_sequences(store, sequence_floors, :invalid_run_state) do
      {:ok,
       %{
         store
         | run_state_bytes: size,
           disk_bytes: store.disk_bytes + size,
           segment_high_water: segment_high_water,
           committed_segment_sizes: committed_segment_sizes,
           sequence_floors: floors,
           run_state_required: true
       }}
    else
      false -> {:error, :invalid_run_state}
      error -> error
    end
  end

  defp hydrate_run_state(_store, _state, _size), do: {:error, :invalid_run_state}

  defp hydrate_stream_set(store, streams, invalid_reason) when is_list(streams) do
    if Enum.all?(streams, &is_binary/1) and length(Enum.uniq(streams)) == length(streams) do
      if MapSet.new(streams) == MapSet.new(Map.values(store.stream_names)),
        do: :ok,
        else: {:error, :stream_set_mismatch}
    else
      {:error, invalid_reason}
    end
  end

  defp hydrate_stream_set(_store, _streams, invalid_reason), do: {:error, invalid_reason}

  defp hydrate_committed_segment_sizes(state, segment_high_water) do
    case Map.fetch(state, "committed_segment_sizes") do
      {:ok, values} -> validate_committed_segment_sizes(values, segment_high_water)
      :error -> hydrate_legacy_committed_segment_size(state, segment_high_water)
    end
  end

  defp validate_committed_segment_sizes(values, segment_high_water) when is_list(values) do
    valid? =
      Enum.all?(values, fn
        {segment_id, size} ->
          is_integer(segment_id) and segment_id > 0 and segment_id <= segment_high_water and
            is_integer(size) and size >= 0

        _value ->
          false
      end)

    ids =
      Enum.flat_map(values, fn
        {segment_id, _size} -> [segment_id]
        _value -> []
      end)

    if valid? and length(Enum.uniq(ids)) == length(ids),
      do: {:ok, Map.new(values)},
      else: {:error, :invalid_run_state}
  end

  defp validate_committed_segment_sizes(_values, _segment_high_water),
    do: {:error, :invalid_run_state}

  defp hydrate_legacy_committed_segment_size(state, segment_high_water) do
    case Map.get(state, "committed_segment_bytes", 0) do
      size when is_integer(size) and size >= 0 and segment_high_water > 0 and size > 0 ->
        {:ok, %{segment_high_water => size}}

      size when is_integer(size) and size >= 0 ->
        {:ok, %{}}

      _size ->
        {:error, :invalid_run_state}
    end
  end

  defp load_snapshot(store) do
    path = snapshot_path(store)
    fs = store.file_system

    case fs.stat(path) do
      {:error, :enoent} ->
        {:ok, store}

      {:ok, %File.Stat{type: :regular, size: size}} when size <= store.max_disk_bytes ->
        with :ok <- fs_result(fs.chmod(path, @file_mode), :chmod_snapshot),
             {:ok, bytes} <- read_result(fs.read(path), :read_snapshot) do
          case Snapshot.decode(bytes) do
            {:ok, snapshot} ->
              case hydrate_snapshot(store, snapshot, size) do
                {:ok, hydrated} ->
                  {:ok, %{hydrated | snapshot_hash: :crypto.hash(:sha256, bytes)}}

                {:error, reason}
                when reason in @origin_mismatch_reasons or
                       reason in [:stream_set_mismatch, :unsupported_snapshot_schema] ->
                  {:error, reason}

                {:error, reason} ->
                  quarantine_segment(store, path, reason)
              end

            {:error, reason}
            when reason in [
                   :unsupported_snapshot_version,
                   :snapshot_too_large,
                   :compressed_snapshot
                 ] ->
              {:error, reason}

            {:error, reason} ->
              quarantine_segment(store, path, reason)
          end
        end

      {:ok, %File.Stat{type: :regular, size: size}} ->
        {:error, {:snapshot_capacity_exceeded, size, store.max_disk_bytes}}

      {:ok, %File.Stat{}} ->
        quarantine_segment(store, path, :invalid_snapshot_type)

      {:error, reason} ->
        {:error, {:stat_snapshot, reason}}

      other ->
        {:error, {:stat_snapshot, other}}
    end
  end

  defp hydrate_snapshot(store, snapshot, snapshot_bytes) when is_map(snapshot) do
    case Map.get(snapshot, "schema_version", 1) do
      version when version in [1, 2, @snapshot_schema_version] ->
        do_hydrate_snapshot(store, snapshot, snapshot_bytes, version)

      _version ->
        {:error, :unsupported_snapshot_schema}
    end
  end

  defp hydrate_snapshot(_store, _snapshot, _snapshot_bytes), do: {:error, :invalid_snapshot}

  defp do_hydrate_snapshot(
         store,
         %{
           "covered_segment_id" => covered_segment_id,
           "device_id" => device_id,
           "credential_epoch" => credential_epoch,
           "storage_epoch" => storage_epoch,
           "next_sequences" => next_sequences,
           "entries" => entries,
           "loss_authorizations" => loss_authorizations
         } = snapshot,
         snapshot_bytes,
         schema_version
       ) do
    with true <- is_integer(covered_segment_id) and covered_segment_id >= 0,
         :ok <- exact_device_id(store, device_id),
         :ok <- exact_credential_epoch(store, credential_epoch),
         :ok <- exact_storage_epoch(store, storage_epoch),
         {:ok, next_sequences} <- hydrate_next_sequences(store, next_sequences, :invalid_snapshot),
         {:ok, entries, live_bytes, live_entry_ids} <-
           hydrate_entries(store, entries, next_sequences),
         {:ok, loss_authorizations} <- hydrate_loss_authorizations(store, loss_authorizations),
         {:ok, entry_id_history_complete} <-
           hydrate_entry_id_history_complete(
             snapshot,
             schema_version,
             next_sequences,
             entries,
             loss_authorizations
           ),
         {:ok, entry_id_tombstones} <-
           hydrate_entry_id_tombstones(store, snapshot, schema_version, live_entry_ids),
         {:ok, resolved_receipts} <- hydrate_resolved_receipts(store, snapshot, schema_version),
         {:ok, acknowledged_floors} <-
           hydrate_acknowledged_floors(
             store,
             snapshot,
             schema_version,
             next_sequences,
             entries,
             loss_authorizations
           ) do
      {:ok,
       %{
         store
         | entries: entries,
           live_bytes: live_bytes,
           disk_bytes: snapshot_bytes,
           snapshot_bytes: snapshot_bytes,
           snapshot_covered_segment_id: covered_segment_id,
           segment_high_water: covered_segment_id,
           run_state_required: schema_version >= 2,
           next_sequences: next_sequences,
           sequence_floors: next_sequences,
           acknowledged_floors: acknowledged_floors,
           entry_id_history_complete: entry_id_history_complete,
           seen_entry_ids: rebuild_seen_entry_ids(entries, entry_id_tombstones),
           entry_id_tombstones: entry_id_tombstones,
           resolved_receipts: resolved_receipts,
           loss_authorizations: retain_latest(loss_authorizations, store.max_loss_authorizations),
           next_ordinal: length(entries) + 1,
           current_segment_id: covered_segment_id
       }}
    else
      false -> {:error, :invalid_snapshot}
      error -> error
    end
  end

  defp hydrate_next_sequences(store, values, invalid_reason) do
    hydrate_stream_counters(
      store,
      values,
      invalid_reason,
      &(is_integer(&1) and &1 > 0)
    )
  end

  defp hydrate_stream_counters(store, values, invalid_reason, valid_counter?)
       when is_list(values) do
    valid_values? =
      Enum.all?(values, fn
        {stream_name, counter} ->
          is_binary(stream_name) and valid_counter?.(counter)

        _value ->
          false
      end)

    if valid_values? do
      names = Enum.map(values, fn {stream_name, _counter} -> stream_name end)
      configured_names = Map.values(store.stream_names)

      cond do
        length(Enum.uniq(names)) != length(names) ->
          {:error, invalid_reason}

        MapSet.new(names) != MapSet.new(configured_names) ->
          {:error, :stream_set_mismatch}

        true ->
          {:ok,
           Map.new(values, fn {stream_name, counter} ->
             {Map.fetch!(store.streams_by_name, stream_name), counter}
           end)}
      end
    else
      {:error, invalid_reason}
    end
  end

  defp hydrate_stream_counters(_store, _values, invalid_reason, _valid_counter?),
    do: {:error, invalid_reason}

  defp hydrate_entries(store, values, next_sequences) when is_list(values) do
    result =
      Enum.reduce_while(values, {:ok, [], 0, MapSet.new(), MapSet.new(), 1}, fn value,
                                                                                {:ok, entries, live_bytes, entry_ids,
                                                                                 identities, ordinal} ->
        with {:ok, entry, encoded_size} <- hydrate_entry(store, value, next_sequences, ordinal),
             entry_id_hash = entry_id_hash(entry.entry_id),
             false <- MapSet.member?(entry_ids, entry_id_hash),
             identity = {entry.stream, entry.sequence},
             false <- MapSet.member?(identities, identity) do
          hydrated = %{entry | encoded_size: encoded_size}

          {:cont,
           {:ok, entries ++ [hydrated], live_bytes + encoded_size, MapSet.put(entry_ids, entry_id_hash),
            MapSet.put(identities, identity), ordinal + 1}}
        else
          true -> {:halt, {:error, :invalid_snapshot}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, entries, live_bytes, entry_ids, _identities, _ordinal} ->
        {:ok, entries, live_bytes, entry_ids}

      error ->
        error
    end
  end

  defp hydrate_entries(_store, _values, _next_sequences), do: {:error, :invalid_snapshot}

  defp hydrate_entry(
         store,
         %{
           "stream" => stream_name,
           "device_id" => device_id,
           "credential_epoch" => credential_epoch,
           "storage_epoch" => storage_epoch,
           "sequence" => sequence,
           "entry_id" => entry_id,
           "payload_hash" => payload_hash,
           "payload" => payload,
           "priority" => priority
         },
         next_sequences,
         ordinal
       ) do
    with {:ok, stream} <- configured_stream(store, stream_name),
         :ok <- exact_device_id(store, device_id),
         :ok <- exact_credential_epoch(store, credential_epoch),
         :ok <- exact_storage_epoch(store, storage_epoch),
         true <- is_integer(sequence) and sequence > 0 and sequence < Map.fetch!(next_sequences, stream),
         true <- is_binary(entry_id) and byte_size(entry_id) > 0 and byte_size(entry_id) <= 65_535,
         true <- is_binary(payload_hash) and byte_size(payload_hash) == 32,
         true <- is_binary(payload) and :crypto.hash(:sha256, payload) == payload_hash,
         true <- is_integer(priority) and priority in 0..255,
         {:ok, encoded} <-
           Record.encode(%{
             kind: :entry,
             stream: stream_name,
             device_id: device_id,
             credential_epoch: credential_epoch,
             storage_epoch: storage_epoch,
             sequence: sequence,
             entry_id: entry_id,
             payload_hash: payload_hash,
             payload: payload,
             priority: priority
           }) do
      entry = %Entry{
        stream: stream,
        device_id: device_id,
        credential_epoch: credential_epoch,
        storage_epoch: storage_epoch,
        sequence: sequence,
        entry_id: entry_id,
        payload_hash: payload_hash,
        payload: payload,
        priority: priority,
        encoded_size: 0,
        ordinal: ordinal
      }

      {:ok, entry, byte_size(encoded)}
    else
      false -> {:error, :invalid_snapshot}
      error -> error
    end
  end

  defp hydrate_entry(_store, _value, _next_sequences, _ordinal), do: {:error, :invalid_snapshot}

  defp hydrate_loss_authorizations(store, values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case hydrate_loss_authorization(store, value) do
        {:ok, authorization} -> {:cont, {:ok, acc ++ [authorization]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp hydrate_loss_authorizations(_store, _values), do: {:error, :invalid_snapshot}

  defp hydrate_loss_authorization(
         store,
         %{
           "stream" => stream_name,
           "device_id" => device_id,
           "credential_epoch" => credential_epoch,
           "storage_epoch" => storage_epoch,
           "sequence" => sequence,
           "entry_id" => entry_id,
           "payload_hash" => payload_hash,
           "reason" => reason
         }
       ) do
    with {:ok, stream} <- configured_stream(store, stream_name),
         :ok <- exact_device_id(store, device_id),
         :ok <- exact_credential_epoch(store, credential_epoch),
         :ok <- exact_storage_epoch(store, storage_epoch),
         true <- is_integer(sequence) and sequence > 0,
         true <- is_binary(entry_id) and byte_size(entry_id) > 0,
         true <- is_binary(payload_hash) and byte_size(payload_hash) == 32,
         :ok <- validate_loss_reason(reason) do
      {:ok,
       %{
         stream: stream,
         device_id: device_id,
         credential_epoch: credential_epoch,
         storage_epoch: storage_epoch,
         sequence: sequence,
         entry_id: entry_id,
         payload_hash: payload_hash,
         reason: reason
       }}
    else
      false -> {:error, :invalid_snapshot}
      error -> error
    end
  end

  defp hydrate_loss_authorization(_store, _value), do: {:error, :invalid_snapshot}

  defp hydrate_entry_id_history_complete(_snapshot, 1, next_sequences, entries, loss_authorizations) do
    complete? =
      Enum.all?(next_sequences, fn {stream, next_sequence} ->
        allocated = next_sequence - 1

        known_sequences =
          entries
          |> Enum.filter(&(&1.stream == stream))
          |> Enum.map(& &1.sequence)
          |> Kernel.++(
            loss_authorizations
            |> Enum.filter(&(&1.stream == stream))
            |> Enum.map(& &1.sequence)
          )
          |> MapSet.new()

        MapSet.size(known_sequences) == allocated and
          Enum.all?(known_sequences, &(&1 >= 1 and &1 <= allocated))
      end)

    {:ok, complete?}
  end

  defp hydrate_entry_id_history_complete(snapshot, schema_version, _next, _entries, _losses)
       when schema_version in [2, @snapshot_schema_version] do
    case Map.get(snapshot, "entry_id_history_complete", true) do
      complete? when is_boolean(complete?) -> {:ok, complete?}
      _complete? -> {:error, :invalid_snapshot}
    end
  end

  defp hydrate_entry_id_tombstones(store, snapshot, 1, live_entry_ids) do
    tombstones =
      snapshot
      |> Map.get("loss_authorizations", [])
      |> Enum.flat_map(fn
        %{"entry_id" => entry_id} when is_binary(entry_id) -> [entry_id_hash(entry_id)]
        _authorization -> []
      end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(live_entry_ids, &1))

    validate_entry_id_tombstones(store, tombstones, live_entry_ids)
  end

  defp hydrate_entry_id_tombstones(store, snapshot, schema_version, live_entry_ids)
       when schema_version in [2, @snapshot_schema_version] do
    validate_entry_id_tombstones(
      store,
      Map.get(snapshot, "entry_id_tombstones", []),
      live_entry_ids
    )
  end

  defp validate_entry_id_tombstones(store, tombstones, live_entry_ids) when is_list(tombstones) do
    retained = retain_latest(tombstones, store.max_entry_id_tombstones)

    cond do
      not Enum.all?(tombstones, &(is_binary(&1) and byte_size(&1) == 32)) ->
        {:error, :invalid_snapshot}

      length(Enum.uniq(tombstones)) != length(tombstones) ->
        {:error, :invalid_snapshot}

      Enum.any?(retained, &MapSet.member?(live_entry_ids, &1)) ->
        {:error, :invalid_snapshot}

      true ->
        {:ok, retained}
    end
  end

  defp validate_entry_id_tombstones(_store, _tombstones, _live_entry_ids),
    do: {:error, :invalid_snapshot}

  defp hydrate_resolved_receipts(_store, _snapshot, 1), do: {:ok, []}

  defp hydrate_resolved_receipts(store, snapshot, schema_version)
       when schema_version in [2, @snapshot_schema_version] do
    values = Map.get(snapshot, "resolved_receipts", [])

    if is_list(values) do
      values
      |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
        case hydrate_resolved_receipt(store, value) do
          {:ok, receipt} -> {:cont, {:ok, acc ++ [receipt]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, receipts} -> {:ok, retain_latest(receipts, store.max_resolved_receipts)}
        error -> error
      end
    else
      {:error, :invalid_snapshot}
    end
  end

  defp hydrate_resolved_receipt(
         store,
         %{
           "stream" => stream_name,
           "device_id" => device_id,
           "credential_epoch" => credential_epoch,
           "storage_epoch" => storage_epoch,
           "sequence" => sequence,
           "payload_hash" => payload_hash
         }
       ) do
    with {:ok, stream} <- configured_stream(store, stream_name),
         :ok <- exact_device_id(store, device_id),
         :ok <- exact_credential_epoch(store, credential_epoch),
         :ok <- exact_storage_epoch(store, storage_epoch),
         true <- is_integer(sequence) and sequence > 0,
         true <- is_binary(payload_hash) and byte_size(payload_hash) == 32 do
      {:ok,
       %{
         stream: stream,
         device_id: device_id,
         credential_epoch: credential_epoch,
         storage_epoch: storage_epoch,
         sequence: sequence,
         payload_hash: payload_hash
       }}
    else
      false -> {:error, :invalid_snapshot}
      error -> error
    end
  end

  defp hydrate_resolved_receipt(_store, _value), do: {:error, :invalid_snapshot}

  defp hydrate_acknowledged_floors(
         store,
         _snapshot,
         schema_version,
         _next_sequences,
         _entries,
         _loss_authorizations
       )
       when schema_version in [1, 2] do
    {:ok, Map.new(store.stream_names, fn {stream, _name} -> {stream, 0} end)}
  end

  defp hydrate_acknowledged_floors(
         store,
         snapshot,
         @snapshot_schema_version,
         next_sequences,
         entries,
         loss_authorizations
       ) do
    with {:ok, values} <- Map.fetch(snapshot, "acknowledged_floors"),
         {:ok, floors} <-
           hydrate_stream_counters(
             store,
             values,
             :invalid_snapshot,
             &(is_integer(&1) and &1 >= 0)
           ),
         true <-
           Enum.all?(floors, fn {stream, floor} ->
             floor < Map.fetch!(next_sequences, stream)
           end),
         false <-
           Enum.any?(entries, fn entry ->
             entry.sequence <= Map.fetch!(floors, entry.stream)
           end),
         false <-
           Enum.any?(loss_authorizations, fn authorization ->
             authorization.sequence <= Map.fetch!(floors, authorization.stream)
           end) do
      {:ok, floors}
    else
      :error -> {:error, :invalid_snapshot}
      false -> {:error, :invalid_snapshot}
      true -> {:error, :invalid_snapshot}
      error -> error
    end
  end

  defp discard_superseded_segments(store, segments) do
    {superseded, active} =
      Enum.split_with(segments, fn {id, _path} -> id <= store.snapshot_covered_segment_id end)

    case remove_segments(store, Enum.map(superseded, &elem(&1, 1))) do
      :ok -> {:ok, store, active}
      {:error, reason} -> {:error, {:snapshot_cleanup, reason}}
    end
  end

  defp list_segments(store) do
    case store.file_system.list_dir(store.root_path) do
      {:ok, files} ->
        segments =
          files
          |> Enum.flat_map(fn filename ->
            case Regex.run(@segment_pattern, filename, capture: :all_but_first) do
              [id] -> [{String.to_integer(id), Path.join(store.root_path, filename)}]
              _other -> []
            end
          end)
          |> Enum.sort_by(&elem(&1, 0))

        {:ok, segments}

      {:error, reason} ->
        {:error, {:list_segments, reason}}

      other ->
        {:error, {:list_segments, other}}
    end
  end

  defp validate_segment_sequence([], _first_id), do: :ok

  defp validate_segment_sequence(segments, first_id) do
    ids = Enum.map(segments, &elem(&1, 0))
    expected = Enum.to_list(first_id..(first_id + length(ids) - 1))

    if ids == expected, do: :ok, else: {:error, {:segment_gap, ids}}
  end

  defp validate_segment_high_water(store, segments) do
    observed =
      case List.last(segments) do
        {id, _path} -> id
        nil -> store.snapshot_covered_segment_id
      end

    if observed < store.segment_high_water,
      do: {:error, {:missing_trailing_segments, store.segment_high_water, observed}},
      else: :ok
  end

  defp prepare_segments(store, segments) do
    result =
      Enum.reduce_while(segments, {:ok, [], 0}, fn {id, path}, {:ok, prepared, total} ->
        with :ok <- fs_result(store.file_system.chmod(path, @file_mode), :chmod_segment),
             {:ok, stat} <- stat_result(store.file_system.stat(path), path),
             :ok <- validate_segment_stat(stat, store.segment_max_bytes) do
          {:cont, {:ok, [{id, path, stat.size} | prepared], total + stat.size}}
        else
          {:error, reason} when reason in [:segment_too_large, :invalid_segment_type] ->
            {:halt, quarantine_segment(store, path, reason)}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, prepared, total} when total <= store.max_disk_bytes ->
        {:ok, Enum.reverse(prepared)}

      {:ok, _prepared, total} ->
        {:error, {:disk_capacity_exceeded, total, store.max_disk_bytes}}

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_prepared_disk_capacity(store, segments) do
    segment_bytes = Enum.reduce(segments, 0, fn {_id, _path, size}, total -> total + size end)
    total = store.snapshot_bytes + store.run_state_bytes + store.run_state_marker_bytes + segment_bytes

    if total <= store.max_disk_bytes,
      do: :ok,
      else: {:error, {:disk_capacity_exceeded, total, store.max_disk_bytes}}
  end

  defp scan_segments(store, []), do: {:ok, store, nil}

  defp scan_segments(store, segments) do
    {final_id, _final_path, _final_size} = List.last(segments)

    Enum.reduce_while(segments, {:ok, store, nil}, fn {id, path, _size}, {:ok, acc, pending_truncation} ->
      final? = id == final_id

      case store.file_system.read(path) do
        {:ok, bytes} ->
          case scan_segment(acc, path, bytes, 0, final?) do
            {:ok, scanned, valid_size, truncation} ->
              current = %{
                scanned
                | current_segment_id: id,
                  current_segment_path: path,
                  current_segment_bytes: valid_size,
                  segment_paths: scanned.segment_paths ++ [path],
                  segment_sizes: Map.put(scanned.segment_sizes, path, valid_size),
                  disk_bytes: scanned.disk_bytes + valid_size
              }

              {:cont, {:ok, current, truncation || pending_truncation}}

            {:corrupt, reason} ->
              {:halt, quarantine_segment(acc, path, reason)}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, {:read_segment, path, reason}}}

        other ->
          {:halt, {:error, {:read_segment, path, other}}}
      end
    end)
  end

  defp scan_segment(store, _path, <<>>, offset, _final?), do: {:ok, store, offset, nil}

  defp scan_segment(store, path, bytes, offset, final?) do
    case Record.decode_next(bytes) do
      {:ok, record, trailing, consumed} ->
        case replay_record(store, record, consumed) do
          {:ok, store} ->
            scan_segment(store, path, trailing, offset + consumed, final?)

          {:error, reason} when reason in @origin_mismatch_reasons ->
            {:error, reason}

          {:error, reason} ->
            {:corrupt, reason}
        end

      {:incomplete, _expected_size} when final? ->
        {:ok, store, offset, {path, offset}}

      {:incomplete, _expected_size} ->
        {:corrupt, {:incomplete_record, offset}}

      {:error, reason} ->
        if final? and recoverable_zero_padded_tail?(store, path, bytes, offset),
          do: {:ok, store, offset, {path, offset}},
          else: {:corrupt, reason}
    end
  end

  defp validate_sequence_floors(store) do
    sequence_result =
      Enum.reduce_while(store.sequence_floors, :ok, fn {stream, persisted_floor}, :ok ->
        recovered = Map.fetch!(store.next_sequences, stream)

        if recovered < persisted_floor,
          do: {:halt, {:error, {:sequence_floor_violation, stream, persisted_floor, recovered}}},
          else: {:cont, :ok}
      end)

    with :ok <- sequence_result do
      validate_segment_byte_floors(store)
    end
  end

  defp validate_segment_byte_floors(store) do
    observed_sizes =
      Enum.reduce(store.segment_paths, %{}, fn path, acc ->
        Map.put(acc, segment_id_from_path(path), Map.fetch!(store.segment_sizes, path))
      end)

    Enum.reduce_while(store.committed_segment_sizes, :ok, fn {segment_id, committed_size}, :ok ->
      cond do
        segment_id <= store.snapshot_covered_segment_id ->
          {:cont, :ok}

        Map.get(observed_sizes, segment_id, -1) < committed_size ->
          recovered_size = Map.get(observed_sizes, segment_id, 0)

          {:halt, {:error, {:segment_byte_floor_violation, segment_id, committed_size, recovered_size}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp apply_recovery_truncation(store, nil), do: {:ok, store}

  defp apply_recovery_truncation(store, {path, offset}) do
    case truncate_path(store, path, offset) do
      :ok -> {:ok, store}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recoverable_zero_padded_tail?(store, path, bytes, offset) do
    trimmed = trim_trailing_zeroes(bytes)
    zero_padding_size = byte_size(bytes) - byte_size(trimmed)

    cond do
      trimmed == <<>> ->
        true

      zero_padding_size < 8 ->
        false

      committed_segment_boundary?(store, path, offset) ->
        match?({:incomplete, _expected_size}, Record.decode_next(trimmed))

      true ->
        false
    end
  end

  defp committed_segment_boundary?(store, path, offset) do
    segment_id = segment_id_from_path(path)
    Map.get(store.committed_segment_sizes, segment_id) == offset
  end

  defp trim_trailing_zeroes(bytes), do: trim_trailing_zeroes(bytes, byte_size(bytes))

  defp trim_trailing_zeroes(_bytes, 0), do: <<>>

  defp trim_trailing_zeroes(bytes, size) do
    if :binary.at(bytes, size - 1) == 0,
      do: trim_trailing_zeroes(bytes, size - 1),
      else: binary_part(bytes, 0, size)
  end

  defp replay_record(store, %{kind: :entry} = record, encoded_size) do
    with :ok <- exact_device_id(store, record.device_id),
         :ok <- exact_credential_epoch(store, record.credential_epoch),
         :ok <- exact_storage_epoch(store, record.storage_epoch),
         {:ok, stream} <- configured_stream(store, record.stream),
         :ok <- expected_sequence(store, stream, record.sequence),
         :ok <- unique_entry_id(store, record.entry_id) do
      entry = %Entry{
        stream: stream,
        device_id: record.device_id,
        credential_epoch: record.credential_epoch,
        storage_epoch: record.storage_epoch,
        sequence: record.sequence,
        entry_id: record.entry_id,
        payload_hash: record.payload_hash,
        payload: record.payload,
        priority: record.priority,
        encoded_size: encoded_size,
        ordinal: store.next_ordinal
      }

      {:ok, add_entry(store, entry)}
    end
  end

  defp replay_record(store, %{kind: :acknowledgement} = record, _encoded_size) do
    with :ok <- exact_device_id(store, record.device_id),
         :ok <- exact_credential_epoch(store, record.credential_epoch),
         :ok <- exact_storage_epoch(store, record.storage_epoch),
         {:ok, stream} <- configured_stream(store, record.stream),
         normalized = %{record | stream: stream},
         {:ok, removed} <- acknowledged_entries(store, normalized) do
      {:ok, apply_acknowledgement_state(store, removed)}
    end
  end

  defp replay_record(store, %{kind: :loss_authorization} = record, _encoded_size) do
    with :ok <- exact_device_id(store, record.device_id),
         :ok <- exact_credential_epoch(store, record.credential_epoch),
         :ok <- exact_storage_epoch(store, record.storage_epoch),
         {:ok, stream} <- configured_stream(store, record.stream),
         normalized = %{record | stream: stream},
         {:ok, entry} <- matching_entry(store, normalized),
         true <- entry.entry_id == record.entry_id do
      authorization = authorization_from_entry(entry, record.reason)

      {:ok,
       %{
         resolve_entries(store, [entry])
         | loss_authorizations:
             retain_latest(store.loss_authorizations ++ [authorization], store.max_loss_authorizations)
       }}
    else
      false -> {:error, :entry_id_mismatch}
      error -> error
    end
  end

  defp truncate_path(store, path, offset) do
    fs = store.file_system

    case fs.open(path, [:read, :write, :binary, :raw]) do
      {:ok, device} ->
        operation =
          with {:ok, ^offset} <- position_result(fs.position(device, offset), offset),
               :ok <- fs_result(fs.truncate(device), :truncate),
               :ok <- fs_result(fs.sync(device), :file_sync) do
            :ok
          end

        close_result = fs_result(fs.close(device), :close)
        combine_results(operation, close_result)

      {:error, reason} ->
        {:error, {:truncate_open, reason}}

      other ->
        {:error, {:truncate_open, other}}
    end
  end

  defp quarantine_segment(store, path, reason) do
    fs = store.file_system
    directory = quarantine_dir(store)

    result =
      with :ok <- fs_result(fs.mkdir_p(directory), :quarantine_mkdir),
           :ok <- fs_result(fs.chmod(directory, @dir_mode), :quarantine_chmod),
           {:ok, destination} <- claim_quarantine_destination(store, path, directory, 8),
           :ok <- fs_result(fs.rename(path, destination), :quarantine_rename),
           :ok <- sync_directory(store, directory),
           :ok <- sync_directory(store, store.root_path) do
        {:error, {:quarantined, reason, destination}}
      end

    case result do
      {:error, {:quarantined, _reason, _destination}} = quarantined -> quarantined
      {:error, quarantine_error} -> {:error, {:corruption_detected, reason, quarantine_error}}
    end
  end

  defp claim_quarantine_destination(_store, _path, _directory, 0),
    do: {:error, :quarantine_name_exhausted}

  defp claim_quarantine_destination(store, path, directory, attempts) do
    destination = Path.join(directory, Path.basename(path) <> ".corrupt-" <> quarantine_suffix())
    fs = store.file_system

    case fs.open(destination, [:write, :binary, :raw, :exclusive]) do
      {:ok, device} ->
        operation = fs_result(fs.chmod(destination, @file_mode), :quarantine_destination_chmod)
        close_result = fs_result(fs.close(device), :close)

        case combine_results(operation, close_result) do
          :ok ->
            {:ok, destination}

          {:error, reason} ->
            _ = fs.remove(destination)
            {:error, reason}
        end

      {:error, :eexist} ->
        claim_quarantine_destination(store, path, directory, attempts - 1)

      {:error, reason} ->
        {:error, {:quarantine_destination_open, reason}}

      other ->
        {:error, {:quarantine_destination_open, other}}
    end
  end

  defp configured_stream_name(store, stream) when is_atom(stream) do
    case Map.fetch(store.stream_names, stream) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, :unknown_stream}
    end
  end

  defp configured_stream_name(_store, _stream), do: {:error, :unknown_stream}

  defp configured_stream(store, stream_name) do
    case Map.fetch(store.streams_by_name, stream_name) do
      {:ok, stream} -> {:ok, stream}
      :error -> {:error, :unknown_stream}
    end
  end

  defp pending_stream(store, opts) do
    case Keyword.fetch(opts, :stream) do
      :error ->
        {:ok, :all}

      {:ok, stream} when is_atom(stream) ->
        if Map.has_key?(store.stream_names, stream),
          do: {:ok, stream},
          else: {:error, :unknown_stream}

      {:ok, _stream} ->
        {:error, :unknown_stream}
    end
  end

  defp pending_limit(opts) do
    case Keyword.fetch(opts, :limit) do
      :error -> {:ok, :all}
      {:ok, limit} when is_integer(limit) and limit > 0 -> {:ok, limit}
      {:ok, _limit} -> {:error, :invalid_limit}
    end
  end

  defp filter_pending_stream(entries, :all), do: entries
  defp filter_pending_stream(entries, stream), do: Enum.filter(entries, &(&1.stream == stream))

  defp limit_pending(entries, :all), do: entries
  defp limit_pending(entries, limit), do: Enum.take(entries, limit)

  defp generic_enqueue_stream(:checkpoint),
    do: {:error, :checkpoint_builder_required}

  defp generic_enqueue_stream(_stream),
    do: :ok

  defp checkpoint_payload(builder, sequence) do
    case builder.(sequence) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :invalid_checkpoint_builder_result}
    end
  rescue
    _exception ->
      {:error, :checkpoint_builder_failed}
  catch
    _kind, _reason ->
      {:error, :checkpoint_builder_failed}
  end

  defp validate_payload(payload) when is_binary(payload), do: :ok
  defp validate_payload(_payload), do: {:error, :invalid_payload}

  defp priority(opts) do
    case Keyword.get(opts, :priority, 0) do
      value when is_integer(value) and value in 0..255 -> {:ok, value}
      _other -> {:error, :invalid_priority}
    end
  end

  defp entry_id(store, opts) do
    value =
      case Keyword.fetch(opts, :entry_id) do
        {:ok, entry_id} -> entry_id
        :error -> store.entry_id_generator.()
      end

    if is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 65_535,
      do: {:ok, value},
      else: {:error, :invalid_entry_id}
  rescue
    _exception -> {:error, :invalid_entry_id}
  catch
    _kind, _reason -> {:error, :invalid_entry_id}
  end

  defp complete_entry_id_history(%__MODULE__{entry_id_history_complete: true}), do: :ok
  defp complete_entry_id_history(%__MODULE__{}), do: {:error, :entry_id_history_incomplete}

  defp unique_entry_id(store, entry_id) do
    if MapSet.member?(store.seen_entry_ids, entry_id_hash(entry_id)),
      do: {:error, :duplicate_entry_id},
      else: :ok
  end

  defp expected_sequence(store, stream, sequence) do
    if Map.fetch!(store.next_sequences, stream) == sequence,
      do: :ok,
      else: {:error, :sequence_discontinuity}
  end

  defp capacity_available(store, encoded_size) do
    cond do
      length(store.entries) >= store.max_entries -> {:error, {:backpressure, :entry_capacity}}
      store.live_bytes + encoded_size > store.max_bytes -> {:error, {:backpressure, :byte_capacity}}
      encoded_size > store.segment_max_bytes -> {:error, {:backpressure, :record_too_large}}
      true -> :ok
    end
  end

  defp verify_fresh(store) do
    with :ok <- ensure_not_quarantined(store),
         :ok <- verify_snapshot_fresh(store),
         :ok <- verify_run_state_fresh(store),
         :ok <- verify_run_state_marker_fresh(store),
         {:ok, segments} <- list_segments(store),
         :ok <- validate_segment_sequence(segments, store.snapshot_covered_segment_id + 1),
         {:ok, prepared} <- prepare_segments(store, segments) do
      paths = Enum.map(prepared, fn {_id, path, _size} -> path end)
      sizes = Map.new(prepared, fn {_id, path, size} -> {path, size} end)
      segment_bytes = Enum.reduce(prepared, 0, fn {_id, _path, size}, total -> total + size end)

      if paths == store.segment_paths and sizes == store.segment_sizes and
           segment_bytes + store.snapshot_bytes + store.run_state_bytes + store.run_state_marker_bytes ==
             store.disk_bytes,
         do: :ok,
         else: {:error, :stale_store}
    end
  end

  defp verify_snapshot_fresh(%__MODULE__{snapshot_hash: nil} = store) do
    case store.file_system.stat(snapshot_path(store)) do
      {:error, :enoent} -> :ok
      _other -> {:error, :stale_store}
    end
  end

  defp verify_snapshot_fresh(store) do
    path = snapshot_path(store)

    with {:ok, %File.Stat{type: :regular, size: size}} <- store.file_system.stat(path),
         true <- size == store.snapshot_bytes,
         {:ok, bytes} <- store.file_system.read(path),
         true <- :crypto.hash(:sha256, bytes) == store.snapshot_hash do
      :ok
    else
      _other -> {:error, :stale_store}
    end
  end

  defp verify_run_state_fresh(%__MODULE__{run_state_hash: nil} = store) do
    case store.file_system.stat(run_state_path(store)) do
      {:error, :enoent} -> :ok
      _other -> {:error, :stale_store}
    end
  end

  defp verify_run_state_fresh(store) do
    path = run_state_path(store)

    with {:ok, %File.Stat{type: :regular, size: size}} <- store.file_system.stat(path),
         true <- size == store.run_state_bytes,
         {:ok, bytes} <- store.file_system.read(path),
         true <- :crypto.hash(:sha256, bytes) == store.run_state_hash do
      :ok
    else
      _other -> {:error, :stale_store}
    end
  end

  defp verify_run_state_marker_fresh(%__MODULE__{run_state_marker_bytes: 0} = store) do
    case store.file_system.stat(run_state_marker_path(store)) do
      {:error, :enoent} -> :ok
      _other -> {:error, :stale_store}
    end
  end

  defp verify_run_state_marker_fresh(store) do
    path = run_state_marker_path(store)

    with {:ok, %File.Stat{type: :regular, size: size}} <- store.file_system.stat(path),
         true <- size == store.run_state_marker_bytes,
         {:ok, @run_state_marker} <- store.file_system.read(path) do
      :ok
    else
      _other -> {:error, :stale_store}
    end
  end

  defp disk_capacity_available(store, encoded_size, reserve_bytes) do
    if store.disk_bytes + encoded_size + reserve_bytes <= store.max_disk_bytes,
      do: :ok,
      else: {:error, {:backpressure, :disk_capacity}}
  end

  defp append_encoded(store, encoded, reserve_bytes) do
    encoded_size = byte_size(encoded)

    cond do
      encoded_size > store.segment_max_bytes ->
        {:error, {:backpressure, :record_too_large}}

      true ->
        with :ok <- verify_fresh(store),
             :ok <- disk_capacity_available(store, encoded_size, reserve_bytes),
             {:ok, selected, created?} <- select_segment(store, encoded_size) do
          case append_and_sync(selected, encoded) do
            :ok ->
              path = selected.current_segment_path
              size = selected.current_segment_bytes + encoded_size

              {:ok,
               %{
                 selected
                 | current_segment_bytes: size,
                   segment_sizes: Map.put(selected.segment_sizes, path, size),
                   disk_bytes: selected.disk_bytes + encoded_size
               }}

            {:error, {:append_open, _reason} = error} when created? ->
              cleanup_created_segment(selected, error)

            {:error, _reason} = error ->
              error
          end
        end
    end
  end

  defp append_segment_id(%__MODULE__{current_segment_path: nil} = store, _encoded_size),
    do: store.current_segment_id + 1

  defp append_segment_id(store, encoded_size) do
    if store.current_segment_bytes > 0 and
         store.current_segment_bytes + encoded_size > store.segment_max_bytes,
       do: store.current_segment_id + 1,
       else: store.current_segment_id
  end

  defp select_segment(%__MODULE__{current_segment_path: nil} = store, _encoded_size),
    do: create_segment(store, store.current_segment_id + 1)

  defp select_segment(store, encoded_size) do
    if store.current_segment_bytes > 0 and
         store.current_segment_bytes + encoded_size > store.segment_max_bytes do
      create_segment(store, store.current_segment_id + 1)
    else
      {:ok, store, false}
    end
  end

  defp create_segment(store, id) do
    path = segment_path(store, id)
    fs = store.file_system

    case fs.open(path, [:write, :binary, :raw, :exclusive]) do
      {:ok, device} ->
        operation = fs_result(fs.chmod(path, @file_mode), :chmod_segment)
        close_result = fs_result(fs.close(device), :close)

        created = %{
          store
          | current_segment_id: id,
            current_segment_path: path,
            current_segment_bytes: 0,
            segment_paths: store.segment_paths ++ [path],
            segment_sizes: Map.put(store.segment_sizes, path, 0)
        }

        case combine_results(operation, close_result) do
          :ok ->
            case sync_directory(store, store.root_path) do
              :ok -> {:ok, created, true}
              {:error, reason} -> cleanup_created_segment(created, reason)
            end

          {:error, reason} ->
            cleanup_created_segment(created, reason)
        end

      {:error, reason} ->
        {:error, {:segment_open, reason}}

      other ->
        {:error, {:segment_open, other}}
    end
  end

  defp cleanup_created_segment(store, original_error) do
    fs = store.file_system
    path = store.current_segment_path

    cleanup =
      with :ok <- remove_result(fs.remove(path)),
           :ok <- sync_directory(store, store.root_path) do
        :ok
      end

    case cleanup do
      :ok ->
        {:error, original_error}

      {:error, cleanup_error} ->
        {:error, {:durability_uncertain, {:segment_cleanup_failed, original_error, cleanup_error}}}
    end
  end

  defp append_and_sync(store, encoded) do
    fs = store.file_system

    case fs.open(store.current_segment_path, [:append, :binary, :raw]) do
      {:ok, device} ->
        operation =
          with :ok <- fs_result(fs.write(device, encoded), :write),
               :ok <- fs_result(fs.sync(device), :file_sync) do
            :ok
          end

        close_result = fs_result(fs.close(device), :close)

        case combine_results(operation, close_result) do
          :ok -> :ok
          {:error, reason} -> {:error, {:durability_uncertain, reason}}
        end

      {:error, reason} ->
        {:error, {:append_open, reason}}

      other ->
        {:error, {:append_open, other}}
    end
  end

  defp persist_run_state_after_append(store) do
    case persist_run_state(store) do
      {:ok, persisted} -> {:ok, persisted}
      {:error, {:durability_uncertain, _reason}} = error -> error
      {:error, reason} -> {:error, {:durability_uncertain, reason}}
    end
  end

  defp persist_run_state(store) do
    segment_high_water = max(store.segment_high_water, store.current_segment_id)

    committed_segment_sizes =
      store.segment_paths
      |> Enum.map(fn path -> {segment_id_from_path(path), Map.fetch!(store.segment_sizes, path)} end)
      |> Enum.sort()

    state = %{
      "device_id" => store.device_id,
      "credential_epoch" => store.credential_epoch,
      "storage_epoch" => store.storage_epoch,
      "streams" => store.stream_names |> Map.values() |> Enum.sort(),
      "segment_high_water" => segment_high_water,
      "committed_segment_sizes" => committed_segment_sizes,
      "sequence_floors" => encode_stream_counters(store, store.next_sequences)
    }

    with {:ok, bytes} <- RunState.encode(state),
         marker_reserve =
           if(store.run_state_bytes == 0 and store.run_state_marker_bytes == 0,
             do: byte_size(@run_state_marker),
             else: 0
           ),
         :ok <- ensure_atomic_replace_capacity(store, byte_size(bytes) + marker_reserve),
         :ok <- atomic_replace(store, run_state_path(store), bytes, :run_state) do
      size = byte_size(bytes)

      {:ok,
       %{
         store
         | disk_bytes: store.disk_bytes - store.run_state_bytes + size,
           run_state_bytes: size,
           run_state_hash: :crypto.hash(:sha256, bytes),
           segment_high_water: segment_high_water,
           committed_segment_sizes: Map.new(committed_segment_sizes),
           sequence_floors: store.next_sequences,
           run_state_required: true
       }}
    end
  end

  defp ensure_run_state_marker(%__MODULE__{run_state_marker_bytes: size} = store) when size > 0,
    do: {:ok, store}

  defp ensure_run_state_marker(store) do
    size = byte_size(@run_state_marker)

    if store.disk_bytes + size > store.max_disk_bytes do
      {:error, {:backpressure, :disk_capacity}}
    else
      create_run_state_marker(store, size)
    end
  end

  defp create_run_state_marker(store, size) do
    path = run_state_marker_path(store)
    fs = store.file_system

    case fs.open(path, [:write, :binary, :raw, :exclusive]) do
      {:ok, device} ->
        operation =
          with :ok <- fs_result(fs.chmod(path, @file_mode), :chmod_run_state_marker),
               :ok <- fs_result(fs.write(device, @run_state_marker), :write_run_state_marker),
               :ok <- fs_result(fs.sync(device), :run_state_marker_sync) do
            :ok
          end

        close_result = fs_result(fs.close(device), :close)

        case combine_results(operation, close_result) do
          :ok ->
            case sync_directory(store, store.root_path) do
              :ok ->
                {:ok,
                 %{
                   store
                   | disk_bytes: store.disk_bytes + size,
                     run_state_marker_bytes: size,
                     run_state_required: true
                 }}

              {:error, reason} ->
                {:error, {:durability_uncertain, reason}}
            end

          {:error, reason} ->
            _ = fs.remove(path)
            {:error, reason}
        end

      {:error, :eexist} ->
        load_run_state_marker(store)

      {:error, reason} ->
        {:error, {:run_state_marker_open, reason}}

      other ->
        {:error, {:run_state_marker_open, other}}
    end
  end

  defp ensure_atomic_replace_capacity(store, replacement_size) do
    if store.disk_bytes + replacement_size <= store.max_disk_bytes,
      do: :ok,
      else: {:error, {:backpressure, :disk_capacity}}
  end

  defp atomic_replace(store, destination, bytes, kind) do
    with {:ok, temporary} <- write_atomic_temp(store, destination, bytes, kind, 8),
         :ok <- fs_result(store.file_system.rename(temporary, destination), atomic_rename_operation(kind)),
         :ok <- sync_directory(store, store.root_path) do
      :ok
    end
  end

  defp write_atomic_temp(_store, _destination, _bytes, _kind, 0),
    do: {:error, :temporary_name_exhausted}

  defp write_atomic_temp(store, destination, bytes, kind, attempts) do
    temporary = destination <> ".tmp." <> temporary_suffix()
    fs = store.file_system

    case fs.open(temporary, [:write, :binary, :raw, :exclusive]) do
      {:ok, device} ->
        operation =
          with :ok <- fs_result(fs.chmod(temporary, @file_mode), atomic_chmod_operation(kind)),
               :ok <- fs_result(fs.write(device, bytes), atomic_write_operation(kind)),
               :ok <- fs_result(fs.sync(device), atomic_sync_operation(kind)) do
            :ok
          end

        close_result = fs_result(fs.close(device), :close)

        case combine_results(operation, close_result) do
          :ok ->
            {:ok, temporary}

          {:error, reason} ->
            _ = fs.remove(temporary)
            {:error, reason}
        end

      {:error, :eexist} ->
        write_atomic_temp(store, destination, bytes, kind, attempts - 1)

      {:error, reason} ->
        {:error, {atomic_open_operation(kind), reason}}

      other ->
        {:error, {atomic_open_operation(kind), other}}
    end
  end

  defp atomic_open_operation(:run_state), do: :run_state_open
  defp atomic_open_operation(:snapshot), do: :snapshot_open
  defp atomic_chmod_operation(:run_state), do: :chmod_run_state
  defp atomic_chmod_operation(:snapshot), do: :chmod_snapshot
  defp atomic_write_operation(:run_state), do: :write_run_state
  defp atomic_write_operation(:snapshot), do: :write_snapshot
  defp atomic_sync_operation(:run_state), do: :run_state_sync
  defp atomic_sync_operation(:snapshot), do: :snapshot_sync
  defp atomic_rename_operation(:run_state), do: :run_state_rename
  defp atomic_rename_operation(:snapshot), do: :snapshot_rename

  defp encode_snapshot(store, covered_segment_id) do
    Snapshot.encode(%{
      "schema_version" => @snapshot_schema_version,
      "run_state_required" => true,
      "covered_segment_id" => covered_segment_id,
      "device_id" => store.device_id,
      "credential_epoch" => store.credential_epoch,
      "storage_epoch" => store.storage_epoch,
      "next_sequences" => encode_stream_counters(store, store.next_sequences),
      "acknowledged_floors" => encode_stream_counters(store, store.acknowledged_floors),
      "entries" => Enum.map(store.entries, &snapshot_entry(store, &1)),
      "entry_id_history_complete" => store.entry_id_history_complete,
      "entry_id_tombstones" => store.entry_id_tombstones,
      "resolved_receipts" => Enum.map(store.resolved_receipts, &snapshot_resolved_receipt(store, &1)),
      "loss_authorizations" => Enum.map(store.loss_authorizations, &snapshot_loss_authorization(store, &1))
    })
  end

  defp encode_stream_counters(store, counters) do
    counters
    |> Enum.map(fn {stream, counter} ->
      {Map.fetch!(store.stream_names, stream), counter}
    end)
    |> Enum.sort()
  end

  defp snapshot_entry(store, entry) do
    %{
      "stream" => Map.fetch!(store.stream_names, entry.stream),
      "device_id" => entry.device_id,
      "credential_epoch" => entry.credential_epoch,
      "storage_epoch" => entry.storage_epoch,
      "sequence" => entry.sequence,
      "entry_id" => entry.entry_id,
      "payload_hash" => entry.payload_hash,
      "payload" => entry.payload,
      "priority" => entry.priority
    }
  end

  defp snapshot_resolved_receipt(store, receipt) do
    %{
      "stream" => Map.fetch!(store.stream_names, receipt.stream),
      "device_id" => receipt.device_id,
      "credential_epoch" => receipt.credential_epoch,
      "storage_epoch" => receipt.storage_epoch,
      "sequence" => receipt.sequence,
      "payload_hash" => receipt.payload_hash
    }
  end

  defp snapshot_loss_authorization(store, authorization) do
    %{
      "stream" => Map.fetch!(store.stream_names, authorization.stream),
      "device_id" => authorization.device_id,
      "credential_epoch" => authorization.credential_epoch,
      "storage_epoch" => authorization.storage_epoch,
      "sequence" => authorization.sequence,
      "entry_id" => authorization.entry_id,
      "payload_hash" => authorization.payload_hash,
      "reason" => authorization.reason
    }
  end

  defp compact_store(store, snapshot_bytes) do
    if store.disk_bytes + byte_size(snapshot_bytes) > store.max_disk_bytes do
      {:error, {:durability_uncertain, {:backpressure, :disk_capacity}}}
    else
      case do_compact_store(store, snapshot_bytes) do
        {:ok, compacted} -> {:ok, compacted}
        {:error, {:durability_uncertain, _reason}} = error -> error
        {:error, reason} -> {:error, {:durability_uncertain, reason}}
      end
    end
  end

  defp do_compact_store(store, snapshot_bytes) do
    destination = snapshot_path(store)

    with :ok <- atomic_replace(store, destination, snapshot_bytes, :snapshot),
         :ok <- remove_segments(store, store.segment_paths) do
      size = byte_size(snapshot_bytes)

      {:ok,
       %{
         store
         | disk_bytes: size + store.run_state_bytes + store.run_state_marker_bytes,
           snapshot_bytes: size,
           snapshot_hash: :crypto.hash(:sha256, snapshot_bytes),
           snapshot_covered_segment_id: store.current_segment_id,
           committed_segment_sizes: %{},
           segment_paths: [],
           segment_sizes: %{},
           current_segment_path: nil,
           current_segment_bytes: 0
       }}
    else
      {:error, reason} = error ->
        if snapshot_activated?(store, destination, snapshot_bytes),
          do: {:error, {:durability_uncertain, reason}},
          else: error
    end
  end

  defp snapshot_activated?(store, destination, snapshot_bytes) do
    case store.file_system.stat(destination) do
      {:ok, %File.Stat{type: :regular, size: size}} -> size == byte_size(snapshot_bytes)
      _other -> false
    end
  end

  defp remove_segments(_store, []), do: :ok

  defp remove_segments(store, paths) do
    result =
      Enum.reduce_while(paths, :ok, fn path, :ok ->
        case remove_result(store.file_system.remove(path)) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with :ok <- result,
         :ok <- sync_directory(store, store.root_path) do
      :ok
    end
  end

  defp add_entry(store, entry) do
    %{
      store
      | entries: store.entries ++ [entry],
        live_bytes: store.live_bytes + entry.encoded_size,
        next_sequences: Map.put(store.next_sequences, entry.stream, entry.sequence + 1),
        seen_entry_ids: MapSet.put(store.seen_entry_ids, entry_id_hash(entry.entry_id)),
        next_ordinal: store.next_ordinal + 1
    }
  end

  defp resolve_entries(store, entries) do
    removed = remove_entries(store, entries)

    tombstones =
      store.entry_id_tombstones
      |> Kernel.++(Enum.map(entries, &entry_id_hash(&1.entry_id)))
      |> Enum.uniq()
      |> retain_latest(store.max_entry_id_tombstones)

    %{
      removed
      | entry_id_tombstones: tombstones,
        seen_entry_ids: rebuild_seen_entry_ids(removed.entries, tombstones)
    }
  end

  defp remove_entries(store, entries) do
    identities = MapSet.new(entries, &entry_identity/1)
    removed_bytes = Enum.reduce(entries, 0, &(&1.encoded_size + &2))

    %{
      store
      | entries: Enum.reject(store.entries, &MapSet.member?(identities, entry_identity(&1))),
        live_bytes: store.live_bytes - removed_bytes
    }
  end

  defp apply_acknowledgement_state(store, entries) do
    store
    |> resolve_entries(entries)
    |> remember_resolved_entries(entries)
  end

  defp remember_resolved_entries(store, entries) do
    identities =
      Enum.map(entries, fn entry ->
        Map.take(entry, [
          :stream,
          :device_id,
          :credential_epoch,
          :storage_epoch,
          :sequence,
          :payload_hash
        ])
      end)

    acknowledged_floors =
      advance_acknowledged_floors(
        store.acknowledged_floors,
        store.resolved_receipts ++ identities,
        Enum.map(identities, & &1.stream)
      )

    identity_keys = MapSet.new(identities, &receipt_identity/1)

    receipts =
      store.resolved_receipts
      |> Enum.reject(&MapSet.member?(identity_keys, receipt_identity(&1)))
      |> Kernel.++(identities)
      |> retain_latest(store.max_resolved_receipts)

    %{
      store
      | acknowledged_floors: acknowledged_floors,
        resolved_receipts: receipts
    }
  end

  defp advance_acknowledged_floors(floors, receipts, streams) do
    sequences_by_stream =
      Enum.reduce(receipts, %{}, fn receipt, acc ->
        Map.update(
          acc,
          receipt.stream,
          MapSet.new([receipt.sequence]),
          &MapSet.put(&1, receipt.sequence)
        )
      end)

    streams
    |> Enum.uniq()
    |> Enum.reduce(floors, fn stream, acc ->
      sequences = Map.get(sequences_by_stream, stream, MapSet.new())
      Map.update!(acc, stream, &advance_contiguous_floor(&1, sequences))
    end)
  end

  defp advance_contiguous_floor(floor, sequences) do
    next = floor + 1

    if MapSet.member?(sequences, next),
      do: advance_contiguous_floor(next, sequences),
      else: floor
  end

  defp same_receipt_identity?(left, right),
    do: receipt_identity(left) == receipt_identity(right)

  defp receipt_identity(receipt) do
    {
      receipt.stream,
      receipt.device_id,
      receipt.credential_epoch,
      receipt.storage_epoch,
      receipt.sequence,
      receipt.payload_hash
    }
  end

  defp rebuild_seen_entry_ids(entries, tombstones) do
    Enum.reduce(entries, MapSet.new(tombstones), fn entry, acc ->
      MapSet.put(acc, entry_id_hash(entry.entry_id))
    end)
  end

  defp entry_id_hash(entry_id), do: :crypto.hash(:sha256, [@entry_id_tombstone_domain, entry_id])

  defp retain_latest(values, limit), do: Enum.take(values, -limit)

  defp validate_receipt(store, receipt) do
    with {:ok, identity} <- validate_identity(store, receipt),
         {:ok, cumulative_sequence} <- map_nonnegative_integer(receipt, :cumulative_sequence),
         true <- cumulative_sequence < Map.fetch!(store.next_sequences, identity.stream) do
      {:ok, Map.put(identity, :cumulative_sequence, cumulative_sequence)}
    else
      false -> {:error, :invalid_cumulative_sequence}
      error -> error
    end
  end

  defp validate_identity(store, identity) do
    with {:ok, stream} <- map_stream(store, identity),
         {:ok, device_id} <- map_device_id(identity),
         :ok <- exact_device_id(store, device_id),
         {:ok, credential_epoch} <- map_credential_epoch(identity),
         :ok <- exact_credential_epoch(store, credential_epoch),
         {:ok, storage_epoch} <- map_storage_epoch(identity),
         :ok <- exact_storage_epoch(store, storage_epoch),
         {:ok, sequence} <- map_positive_integer(identity, :sequence),
         {:ok, payload_hash} <- map_hash(identity) do
      {:ok,
       %{
         stream: stream,
         device_id: device_id,
         credential_epoch: credential_epoch,
         storage_epoch: storage_epoch,
         sequence: sequence,
         payload_hash: payload_hash
       }}
    end
  end

  defp map_stream(store, map) do
    case Map.fetch(map, :stream) do
      {:ok, stream} ->
        case configured_stream_name(store, stream) do
          {:ok, _name} -> {:ok, stream}
          {:error, _reason} -> {:error, :unknown_stream}
        end

      :error ->
        {:error, :invalid_receipt}
    end
  end

  defp map_storage_epoch(map) do
    case Map.fetch(map, :storage_epoch) do
      {:ok, <<_::128>> = epoch} -> {:ok, epoch}
      _other -> {:error, :invalid_storage_epoch}
    end
  end

  defp map_device_id(map) do
    case Map.fetch(map, :device_id) do
      {:ok, @zero_device_id} -> {:error, :invalid_device_id}
      {:ok, <<_::128>> = device_id} -> {:ok, device_id}
      _other -> {:error, :invalid_device_id}
    end
  end

  defp map_credential_epoch(map) do
    case Map.fetch(map, :credential_epoch) do
      {:ok, epoch} when is_integer(epoch) and epoch >= 0 and epoch <= @u32_max -> {:ok, epoch}
      _other -> {:error, :invalid_credential_epoch}
    end
  end

  defp map_positive_integer(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, :invalid_sequence}
    end
  end

  defp map_nonnegative_integer(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> {:error, :invalid_cumulative_sequence}
    end
  end

  defp map_hash(map) do
    case Map.fetch(map, :payload_hash) do
      {:ok, <<_::256>> = hash} -> {:ok, hash}
      _other -> {:error, :invalid_payload_hash}
    end
  end

  defp exact_storage_epoch(%__MODULE__{storage_epoch: epoch}, epoch), do: :ok
  defp exact_storage_epoch(_store, _epoch), do: {:error, :storage_epoch_mismatch}

  defp exact_device_id(%__MODULE__{device_id: device_id}, device_id), do: :ok
  defp exact_device_id(_store, _device_id), do: {:error, :device_id_mismatch}

  defp exact_credential_epoch(%__MODULE__{credential_epoch: epoch}, epoch), do: :ok
  defp exact_credential_epoch(_store, _epoch), do: {:error, :credential_epoch_mismatch}

  defp matching_entry(store, identity) do
    case Enum.find(store.entries, &(&1.stream == identity.stream and &1.sequence == identity.sequence)) do
      nil ->
        {:error, :receipt_entry_not_found}

      entry ->
        cond do
          entry.device_id != identity.device_id -> {:error, :device_id_mismatch}
          entry.credential_epoch != identity.credential_epoch -> {:error, :credential_epoch_mismatch}
          entry.storage_epoch != identity.storage_epoch -> {:error, :storage_epoch_mismatch}
          entry.payload_hash != identity.payload_hash -> {:error, :payload_hash_mismatch}
          true -> {:ok, entry}
        end
    end
  end

  defp acknowledged_entries(store, receipt) do
    with {:ok, exact} <- matching_entry(store, receipt),
         {:ok, prefix} <- cumulative_prefix(store, receipt.stream, receipt.cumulative_sequence) do
      removed =
        store.entries
        |> Enum.filter(fn entry -> entry == exact or entry in prefix end)

      {:ok, removed}
    end
  end

  defp cumulative_prefix(_store, _stream, 0), do: {:ok, []}

  defp cumulative_prefix(store, stream, cumulative_sequence) do
    acknowledged_floor = Map.fetch!(store.acknowledged_floors, stream)

    prefix =
      store.entries
      |> Enum.filter(fn entry ->
        entry.stream == stream and entry.sequence > acknowledged_floor and
          entry.sequence <= cumulative_sequence
      end)
      |> Enum.sort_by(& &1.sequence)

    accepted_sequences =
      store.resolved_receipts
      |> Enum.filter(fn receipt ->
        receipt.stream == stream and receipt.sequence > acknowledged_floor and
          receipt.sequence <= cumulative_sequence
      end)
      |> Enum.map(& &1.sequence)
      |> Kernel.++(Enum.map(prefix, & &1.sequence))
      |> MapSet.new()

    if advance_contiguous_floor(acknowledged_floor, accepted_sequences) >= cumulative_sequence,
      do: {:ok, prefix},
      else: {:error, :non_contiguous_cumulative_prefix}
  end

  defp authorization_from_entry(entry, reason) do
    %{
      stream: entry.stream,
      device_id: entry.device_id,
      credential_epoch: entry.credential_epoch,
      storage_epoch: entry.storage_epoch,
      sequence: entry.sequence,
      entry_id: entry.entry_id,
      payload_hash: entry.payload_hash,
      reason: reason
    }
  end

  defp validate_loss_reason(reason)
       when is_binary(reason) and byte_size(reason) > 0 and byte_size(reason) <= 4_096 do
    if String.valid?(reason), do: :ok, else: {:error, :invalid_loss_reason}
  end

  defp validate_loss_reason(_reason), do: {:error, :invalid_loss_reason}

  defp entry_identity(entry) do
    {entry.stream, entry.device_id, entry.credential_epoch, entry.storage_epoch, entry.sequence, entry.payload_hash}
  end

  defp segment_path(store, id) do
    Path.join(store.root_path, "segment-" <> String.pad_leading(Integer.to_string(id), 20, "0") <> ".log")
  end

  defp segment_id_from_path(path) do
    [id] = Regex.run(@segment_pattern, Path.basename(path), capture: :all_but_first)
    String.to_integer(id)
  end

  defp snapshot_path(store), do: Path.join(store.root_path, "snapshot.bin")
  defp run_state_path(store), do: Path.join(store.root_path, "run-state.bin")
  defp run_state_marker_path(store), do: Path.join(store.root_path, "run-state.required")
  defp quarantine_dir(store), do: Path.join(store.root_path, "quarantine")
  defp quarantine_suffix, do: random_suffix()

  defp canonicalize_path(path, symlink_hops) do
    case Path.split(path) do
      [root | components] -> canonicalize_components(root, components, symlink_hops)
      _parts -> {:error, :invalid_root}
    end
  end

  defp canonicalize_components(current, [], _symlink_hops), do: {:ok, Path.expand(current)}

  defp canonicalize_components(current, [component | rest], symlink_hops) do
    candidate = Path.join(current, component)

    case :file.read_link(String.to_charlist(candidate)) do
      {:ok, target} when symlink_hops > 0 ->
        target = List.to_string(target)

        resolved =
          if Path.type(target) == :absolute,
            do: Path.expand(target),
            else: Path.expand(target, Path.dirname(candidate))

        continued = Enum.reduce(rest, resolved, fn part, acc -> Path.join(acc, part) end)
        canonicalize_path(continued, symlink_hops - 1)

      {:ok, _target} ->
        {:error, :too_many_symlinks}

      {:error, :einval} ->
        canonicalize_components(candidate, rest, symlink_hops)

      {:error, :enoent} ->
        {:ok, Enum.reduce(rest, candidate, fn part, acc -> Path.join(acc, part) end)}

      {:error, reason} ->
        {:error, {:root_realpath, reason}}
    end
  end

  defp temporary_suffix, do: random_suffix()
  defp random_suffix, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp sync_directory(store, directory) do
    fs = store.file_system

    case fs.open(directory, [:read, :raw, :directory]) do
      {:ok, device} ->
        sync_result = fs_result(fs.sync(device), :directory_sync)
        close_result = fs_result(fs.close(device), :directory_close)
        combine_results(sync_result, close_result)

      {:error, reason} ->
        {:error, {:directory_open, reason}}

      other ->
        {:error, {:directory_open, other}}
    end
  end

  defp list_dir_result({:ok, files}, _operation) when is_list(files), do: {:ok, files}
  defp list_dir_result({:error, reason}, operation), do: {:error, {operation, reason}}
  defp list_dir_result(other, operation), do: {:error, {operation, other}}

  defp read_result({:ok, bytes}, _operation) when is_binary(bytes), do: {:ok, bytes}
  defp read_result({:error, reason}, operation), do: {:error, {operation, reason}}
  defp read_result(other, operation), do: {:error, {operation, other}}

  defp stat_result({:ok, %File.Stat{} = stat}, _path), do: {:ok, stat}
  defp stat_result({:error, reason}, path), do: {:error, {:stat_segment, path, reason}}
  defp stat_result(other, path), do: {:error, {:stat_segment, path, other}}

  defp validate_segment_stat(%File.Stat{type: :regular, size: size}, max_size)
       when size <= max_size,
       do: :ok

  defp validate_segment_stat(%File.Stat{type: :regular}, _max_size), do: {:error, :segment_too_large}
  defp validate_segment_stat(%File.Stat{}, _max_size), do: {:error, :invalid_segment_type}

  defp remove_result(:ok), do: :ok
  defp remove_result({:error, :enoent}), do: :ok
  defp remove_result({:error, reason}), do: {:error, {:remove_segment, reason}}
  defp remove_result(other), do: {:error, {:remove_segment, other}}

  defp fs_result(:ok, _operation), do: :ok
  defp fs_result({:error, reason}, operation), do: {:error, {operation, reason}}
  defp fs_result(other, operation), do: {:error, {operation, other}}

  defp position_result({:ok, offset}, offset), do: {:ok, offset}
  defp position_result({:error, reason}, _offset), do: {:error, {:position, reason}}
  defp position_result(other, _offset), do: {:error, {:position, other}}

  defp combine_results(:ok, :ok), do: :ok
  defp combine_results({:error, _reason} = error, _close_result), do: error
  defp combine_results(:ok, {:error, _reason} = error), do: error
end
