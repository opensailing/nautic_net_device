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
  """

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.{Entry, FileSystem, Record, Snapshot}

  @dir_mode 0o700
  @file_mode 0o600
  @segment_pattern ~r/^segment-(\d{20})\.log$/

  @enforce_keys [
    :root_path,
    :storage_epoch,
    :stream_names,
    :streams_by_name,
    :max_entries,
    :max_bytes,
    :max_disk_bytes,
    :segment_max_bytes,
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
          storage_epoch: <<_::128>>,
          stream_names: %{required(atom()) => binary()},
          streams_by_name: %{required(binary()) => atom()},
          max_entries: pos_integer(),
          max_bytes: pos_integer(),
          max_disk_bytes: pos_integer(),
          segment_max_bytes: pos_integer(),
          file_system: module(),
          entry_id_generator: (-> binary()),
          entries: [Entry.t()],
          live_bytes: non_neg_integer(),
          disk_bytes: non_neg_integer(),
          snapshot_bytes: non_neg_integer(),
          snapshot_hash: <<_::256>> | nil,
          snapshot_covered_segment_id: non_neg_integer(),
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

  @doc "Open a root and replay all segments into an outbox state handle."
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(root_path, opts) when is_binary(root_path) and is_list(opts) do
    with {:ok, store} <- new_store(root_path, opts),
         :ok <- ensure_root(store),
         :ok <- ensure_not_quarantined(store),
         {:ok, store} <- load_snapshot(store),
         {:ok, segments} <- list_segments(store),
         {:ok, store, active_segments} <- discard_superseded_segments(store, segments),
         :ok <- validate_segment_sequence(active_segments, store.snapshot_covered_segment_id + 1),
         {:ok, active_segments} <- prepare_segments(store, active_segments),
         :ok <- ensure_prepared_disk_capacity(store, active_segments),
         {:ok, store} <- scan_segments(store, active_segments) do
      {:ok, store}
    end
  end

  def open(_root_path, _opts), do: {:error, :invalid_options}

  @doc "Append and fsync one new entry before exposing enqueue success."
  @spec enqueue(t(), atom(), binary(), keyword()) ::
          {:ok, Entry.t(), t()} | {:error, term()}
  def enqueue(%__MODULE__{} = store, stream, payload, opts \\ []) do
    with_mutation_lock(store, fn -> do_enqueue(store, stream, payload, opts) end)
  end

  defp do_enqueue(store, stream, payload, opts) do
    with {:ok, stream_name} <- configured_stream_name(store, stream),
         :ok <- validate_payload(payload),
         {:ok, priority} <- priority(opts),
         {:ok, entry_id} <- entry_id(store, opts),
         :ok <- unique_entry_id(store, entry_id),
         sequence <- Map.fetch!(store.next_sequences, stream),
         payload_hash <- :crypto.hash(:sha256, payload),
         {:ok, encoded} <-
           Record.encode(%{
             kind: :entry,
             stream: stream_name,
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
         {:ok, appended} <- append_encoded(store, encoded, byte_size(snapshot_bytes)) do
      {:ok, entry, add_entry(appended, entry)}
    end
  end

  @doc "Return pending entries in priority order, retaining FIFO within a priority."
  @spec pending(t()) :: [Entry.t()]
  def pending(%__MODULE__{entries: entries}) do
    Enum.sort_by(entries, &{-&1.priority, &1.ordinal})
  end

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
             storage_epoch: normalized.storage_epoch,
             sequence: normalized.sequence,
             payload_hash: normalized.payload_hash,
             cumulative_sequence: normalized.cumulative_sequence
           }),
         covered_segment_id <- append_segment_id(store, byte_size(encoded)),
         resolved = remove_entries(store, removed),
         {:ok, snapshot_bytes} <- encode_snapshot(resolved, covered_segment_id),
         {:ok, appended} <- append_encoded(store, encoded, byte_size(snapshot_bytes)),
         resolved = remove_entries(appended, removed),
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
             storage_epoch: entry.storage_epoch,
             sequence: entry.sequence,
             entry_id: entry.entry_id,
             payload_hash: entry.payload_hash,
             reason: reason
           }),
         authorization = authorization_from_entry(entry, reason),
         resolved = %{
           remove_entries(store, [entry])
           | loss_authorizations: store.loss_authorizations ++ [authorization]
         },
         covered_segment_id <- append_segment_id(store, byte_size(encoded)),
         {:ok, snapshot_bytes} <- encode_snapshot(resolved, covered_segment_id),
         {:ok, appended} <- append_encoded(store, encoded, byte_size(snapshot_bytes)),
         resolved = %{
           remove_entries(appended, [entry])
           | loss_authorizations: appended.loss_authorizations ++ [authorization]
         },
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
    with {:ok, storage_epoch} <- option_storage_epoch(opts),
         {:ok, stream_names, streams_by_name} <- option_streams(opts),
         {:ok, max_entries} <- positive_option(opts, :max_entries),
         {:ok, max_bytes} <- positive_option(opts, :max_bytes),
         {:ok, segment_max_bytes} <- positive_option(opts, :segment_max_bytes),
         {:ok, max_disk_bytes} <- option_max_disk_bytes(opts, max_bytes, segment_max_bytes),
         {:ok, file_system} <- option_file_system(opts),
         {:ok, entry_id_generator} <- option_entry_id_generator(opts) do
      {:ok,
       %__MODULE__{
         root_path: Path.expand(root_path),
         storage_epoch: storage_epoch,
         stream_names: stream_names,
         streams_by_name: streams_by_name,
         max_entries: max_entries,
         max_bytes: max_bytes,
         max_disk_bytes: max_disk_bytes,
         segment_max_bytes: segment_max_bytes,
         file_system: file_system,
         entry_id_generator: entry_id_generator,
         next_sequences: Map.new(stream_names, fn {stream, _name} -> {stream, 1} end)
       }}
    end
  end

  defp option_storage_epoch(opts) do
    case Keyword.fetch(opts, :storage_epoch) do
      {:ok, <<_::128>> = epoch} -> {:ok, epoch}
      _other -> {:error, :invalid_storage_epoch}
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

  defp load_snapshot(store) do
    path = snapshot_path(store)
    fs = store.file_system

    case fs.stat(path) do
      {:error, :enoent} ->
        {:ok, store}

      {:ok, %File.Stat{type: :regular, size: size}} when size <= store.max_disk_bytes ->
        with :ok <- fs_result(fs.chmod(path, @file_mode), :chmod_snapshot),
             {:ok, bytes} <- read_result(fs.read(path), :read_snapshot),
             {:ok, snapshot} <- Snapshot.decode(bytes),
             {:ok, hydrated} <- hydrate_snapshot(store, snapshot, size) do
          {:ok, %{hydrated | snapshot_hash: :crypto.hash(:sha256, bytes)}}
        else
          {:error, reason} -> quarantine_segment(store, path, reason)
        end

      {:ok, %File.Stat{type: :regular}} ->
        quarantine_segment(store, path, :snapshot_too_large)

      {:ok, %File.Stat{}} ->
        quarantine_segment(store, path, :invalid_snapshot_type)

      {:error, reason} ->
        {:error, {:stat_snapshot, reason}}

      other ->
        {:error, {:stat_snapshot, other}}
    end
  end

  defp hydrate_snapshot(
         store,
         %{
           "covered_segment_id" => covered_segment_id,
           "storage_epoch" => storage_epoch,
           "next_sequences" => next_sequences,
           "entries" => entries,
           "loss_authorizations" => loss_authorizations
         },
         snapshot_bytes
       ) do
    with true <- is_integer(covered_segment_id) and covered_segment_id >= 0,
         :ok <- exact_storage_epoch(store, storage_epoch),
         {:ok, next_sequences} <- hydrate_next_sequences(store, next_sequences),
         {:ok, entries, live_bytes, seen_entry_ids} <-
           hydrate_entries(store, entries, next_sequences),
         {:ok, loss_authorizations} <- hydrate_loss_authorizations(store, loss_authorizations) do
      {:ok,
       %{
         store
         | entries: entries,
           live_bytes: live_bytes,
           disk_bytes: snapshot_bytes,
           snapshot_bytes: snapshot_bytes,
           snapshot_covered_segment_id: covered_segment_id,
           next_sequences: next_sequences,
           seen_entry_ids: seen_entry_ids,
           loss_authorizations: loss_authorizations,
           next_ordinal: length(entries) + 1,
           current_segment_id: covered_segment_id
       }}
    else
      false -> {:error, :invalid_snapshot}
      error -> error
    end
  end

  defp hydrate_snapshot(_store, _snapshot, _snapshot_bytes), do: {:error, :invalid_snapshot}

  defp hydrate_next_sequences(store, values) when is_list(values) do
    result =
      Enum.reduce_while(values, {:ok, %{}}, fn
        {stream_name, sequence}, {:ok, acc}
        when is_binary(stream_name) and is_integer(sequence) and sequence > 0 ->
          case configured_stream(store, stream_name) do
            {:ok, stream} ->
              if Map.has_key?(acc, stream),
                do: {:halt, {:error, :invalid_snapshot}},
                else: {:cont, {:ok, Map.put(acc, stream, sequence)}}

            {:error, _reason} ->
              {:halt, {:error, :unknown_stream}}
          end

        _value, _acc ->
          {:halt, {:error, :invalid_snapshot}}
      end)

    case result do
      {:ok, sequences} when map_size(sequences) == map_size(store.stream_names) ->
        {:ok, sequences}

      {:ok, _sequences} ->
        {:error, :invalid_snapshot}

      error ->
        error
    end
  end

  defp hydrate_next_sequences(_store, _values), do: {:error, :invalid_snapshot}

  defp hydrate_entries(store, values, next_sequences) when is_list(values) do
    result =
      Enum.reduce_while(values, {:ok, [], 0, MapSet.new(), MapSet.new(), 1}, fn value,
                                                                                {:ok, entries, live_bytes, entry_ids,
                                                                                 identities, ordinal} ->
        with {:ok, entry, encoded_size} <- hydrate_entry(store, value, next_sequences, ordinal),
             false <- MapSet.member?(entry_ids, entry.entry_id),
             identity = {entry.stream, entry.sequence},
             false <- MapSet.member?(identities, identity) do
          hydrated = %{entry | encoded_size: encoded_size}

          {:cont,
           {:ok, entries ++ [hydrated], live_bytes + encoded_size, MapSet.put(entry_ids, entry.entry_id),
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
             storage_epoch: storage_epoch,
             sequence: sequence,
             entry_id: entry_id,
             payload_hash: payload_hash,
             payload: payload,
             priority: priority
           }) do
      entry = %Entry{
        stream: stream,
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
           "storage_epoch" => storage_epoch,
           "sequence" => sequence,
           "entry_id" => entry_id,
           "payload_hash" => payload_hash,
           "reason" => reason
         }
       ) do
    with {:ok, stream} <- configured_stream(store, stream_name),
         :ok <- exact_storage_epoch(store, storage_epoch),
         true <- is_integer(sequence) and sequence > 0,
         true <- is_binary(entry_id) and byte_size(entry_id) > 0,
         true <- is_binary(payload_hash) and byte_size(payload_hash) == 32,
         :ok <- validate_loss_reason(reason) do
      {:ok,
       %{
         stream: stream,
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
    total = store.snapshot_bytes + segment_bytes

    if total <= store.max_disk_bytes,
      do: :ok,
      else: {:error, {:disk_capacity_exceeded, total, store.max_disk_bytes}}
  end

  defp scan_segments(store, []), do: {:ok, store}

  defp scan_segments(store, segments) do
    {final_id, _final_path, _final_size} = List.last(segments)

    result =
      Enum.reduce_while(segments, {:ok, store}, fn {id, path, _size}, {:ok, acc} ->
        final? = id == final_id

        case store.file_system.read(path) do
          {:ok, bytes} ->
            case scan_segment(acc, path, bytes, 0, final?) do
              {:ok, scanned, valid_size} ->
                current = %{
                  scanned
                  | current_segment_id: id,
                    current_segment_path: path,
                    current_segment_bytes: valid_size,
                    segment_paths: scanned.segment_paths ++ [path],
                    segment_sizes: Map.put(scanned.segment_sizes, path, valid_size),
                    disk_bytes: scanned.disk_bytes + valid_size
                }

                {:cont, {:ok, current}}

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

    result
  end

  defp scan_segment(store, _path, <<>>, offset, _final?), do: {:ok, store, offset}

  defp scan_segment(store, path, bytes, offset, final?) do
    case Record.decode_next(bytes) do
      {:ok, record, trailing, consumed} ->
        case replay_record(store, record, consumed) do
          {:ok, store} -> scan_segment(store, path, trailing, offset + consumed, final?)
          {:error, reason} -> {:corrupt, reason}
        end

      {:incomplete, _expected_size} when final? ->
        case truncate_path(store, path, offset) do
          :ok -> {:ok, store, offset}
          {:error, reason} -> {:error, reason}
        end

      {:incomplete, _expected_size} ->
        {:corrupt, {:incomplete_record, offset}}

      {:error, reason} ->
        {:corrupt, reason}
    end
  end

  defp replay_record(store, %{kind: :entry} = record, encoded_size) do
    with :ok <- exact_storage_epoch(store, record.storage_epoch),
         {:ok, stream} <- configured_stream(store, record.stream),
         :ok <- expected_sequence(store, stream, record.sequence),
         :ok <- unique_entry_id(store, record.entry_id) do
      entry = %Entry{
        stream: stream,
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
    with :ok <- exact_storage_epoch(store, record.storage_epoch),
         {:ok, stream} <- configured_stream(store, record.stream),
         normalized = %{record | stream: stream},
         {:ok, removed} <- acknowledged_entries(store, normalized) do
      {:ok, remove_entries(store, removed)}
    end
  end

  defp replay_record(store, %{kind: :loss_authorization} = record, _encoded_size) do
    with :ok <- exact_storage_epoch(store, record.storage_epoch),
         {:ok, stream} <- configured_stream(store, record.stream),
         normalized = %{record | stream: stream},
         {:ok, entry} <- matching_entry(store, normalized),
         true <- entry.entry_id == record.entry_id do
      authorization = authorization_from_entry(entry, record.reason)

      {:ok,
       %{
         remove_entries(store, [entry])
         | loss_authorizations: store.loss_authorizations ++ [authorization]
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
    destination = Path.join(directory, Path.basename(path) <> ".corrupt-" <> quarantine_suffix())

    result =
      with :ok <- fs_result(fs.mkdir_p(directory), :quarantine_mkdir),
           :ok <- fs_result(fs.chmod(directory, @dir_mode), :quarantine_chmod),
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

  defp unique_entry_id(store, entry_id) do
    if MapSet.member?(store.seen_entry_ids, entry_id),
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
         {:ok, segments} <- list_segments(store),
         :ok <- validate_segment_sequence(segments, store.snapshot_covered_segment_id + 1),
         {:ok, prepared} <- prepare_segments(store, segments) do
      paths = Enum.map(prepared, fn {_id, path, _size} -> path end)
      sizes = Map.new(prepared, fn {_id, path, size} -> {path, size} end)
      segment_bytes = Enum.reduce(prepared, 0, fn {_id, _path, size}, total -> total + size end)

      if paths == store.segment_paths and sizes == store.segment_sizes and
           segment_bytes + store.snapshot_bytes == store.disk_bytes,
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

  defp encode_snapshot(store, covered_segment_id) do
    Snapshot.encode(%{
      "covered_segment_id" => covered_segment_id,
      "storage_epoch" => store.storage_epoch,
      "next_sequences" =>
        store.next_sequences
        |> Enum.map(fn {stream, sequence} -> {Map.fetch!(store.stream_names, stream), sequence} end)
        |> Enum.sort(),
      "entries" => Enum.map(store.entries, &snapshot_entry(store, &1)),
      "loss_authorizations" => Enum.map(store.loss_authorizations, &snapshot_loss_authorization(store, &1))
    })
  end

  defp snapshot_entry(store, entry) do
    %{
      "stream" => Map.fetch!(store.stream_names, entry.stream),
      "storage_epoch" => entry.storage_epoch,
      "sequence" => entry.sequence,
      "entry_id" => entry.entry_id,
      "payload_hash" => entry.payload_hash,
      "payload" => entry.payload,
      "priority" => entry.priority
    }
  end

  defp snapshot_loss_authorization(store, authorization) do
    %{
      "stream" => Map.fetch!(store.stream_names, authorization.stream),
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
    temporary = destination <> ".tmp." <> temporary_suffix()

    with :ok <- write_snapshot_temp(store, temporary, snapshot_bytes),
         :ok <- activate_snapshot(store, temporary, destination),
         :ok <- remove_segments(store, store.segment_paths) do
      size = byte_size(snapshot_bytes)

      {:ok,
       %{
         store
         | disk_bytes: size,
           snapshot_bytes: size,
           snapshot_hash: :crypto.hash(:sha256, snapshot_bytes),
           snapshot_covered_segment_id: store.current_segment_id,
           segment_paths: [],
           segment_sizes: %{},
           current_segment_path: nil,
           current_segment_bytes: 0
       }}
    else
      {:error, reason} = error ->
        _ = store.file_system.remove(temporary)

        if snapshot_activated?(store, destination, snapshot_bytes),
          do: {:error, {:durability_uncertain, reason}},
          else: error
    end
  end

  defp write_snapshot_temp(store, path, snapshot_bytes) do
    fs = store.file_system

    case fs.open(path, [:write, :binary, :raw, :exclusive]) do
      {:ok, device} ->
        operation =
          with :ok <- fs_result(fs.chmod(path, @file_mode), :chmod_snapshot),
               :ok <- fs_result(fs.write(device, snapshot_bytes), :write_snapshot),
               :ok <- fs_result(fs.sync(device), :snapshot_sync) do
            :ok
          end

        close_result = fs_result(fs.close(device), :close)
        combine_results(operation, close_result)

      {:error, reason} ->
        {:error, {:snapshot_open, reason}}

      other ->
        {:error, {:snapshot_open, other}}
    end
  end

  defp activate_snapshot(store, temporary, destination) do
    with :ok <- fs_result(store.file_system.rename(temporary, destination), :snapshot_rename),
         :ok <- sync_directory(store, store.root_path) do
      :ok
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
        seen_entry_ids: MapSet.put(store.seen_entry_ids, entry.entry_id),
        next_ordinal: store.next_ordinal + 1
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

  defp validate_receipt(store, receipt) do
    with {:ok, identity} <- validate_identity(store, receipt),
         {:ok, cumulative_sequence} <- map_nonnegative_integer(receipt, :cumulative_sequence),
         true <- cumulative_sequence <= identity.sequence do
      {:ok, Map.put(identity, :cumulative_sequence, cumulative_sequence)}
    else
      false -> {:error, :invalid_cumulative_sequence}
      error -> error
    end
  end

  defp validate_identity(store, identity) do
    with {:ok, stream} <- map_stream(store, identity),
         {:ok, storage_epoch} <- map_storage_epoch(identity),
         :ok <- exact_storage_epoch(store, storage_epoch),
         {:ok, sequence} <- map_positive_integer(identity, :sequence),
         {:ok, payload_hash} <- map_hash(identity) do
      {:ok,
       %{
         stream: stream,
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

  defp matching_entry(store, identity) do
    case Enum.find(store.entries, &(&1.stream == identity.stream and &1.sequence == identity.sequence)) do
      nil ->
        {:error, :receipt_entry_not_found}

      entry ->
        cond do
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
    prefix =
      store.entries
      |> Enum.filter(&(&1.stream == stream and &1.sequence <= cumulative_sequence))
      |> Enum.sort_by(& &1.sequence)

    cond do
      prefix == [] ->
        {:ok, []}

      List.last(prefix).sequence != cumulative_sequence ->
        {:error, :non_contiguous_cumulative_prefix}

      contiguous_entries?(prefix) ->
        {:ok, prefix}

      true ->
        {:error, :non_contiguous_cumulative_prefix}
    end
  end

  defp contiguous_entries?([_entry]), do: true

  defp contiguous_entries?([first, second | rest]) do
    second.sequence == first.sequence + 1 and contiguous_entries?([second | rest])
  end

  defp authorization_from_entry(entry, reason) do
    %{
      stream: entry.stream,
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

  defp entry_identity(entry), do: {entry.stream, entry.storage_epoch, entry.sequence, entry.payload_hash}

  defp segment_path(store, id) do
    Path.join(store.root_path, "segment-" <> String.pad_leading(Integer.to_string(id), 20, "0") <> ".log")
  end

  defp snapshot_path(store), do: Path.join(store.root_path, "snapshot.bin")
  defp quarantine_dir(store), do: Path.join(store.root_path, "quarantine")
  defp quarantine_suffix, do: Integer.to_string(System.unique_integer([:positive, :monotonic]))
  defp temporary_suffix, do: quarantine_suffix()

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
