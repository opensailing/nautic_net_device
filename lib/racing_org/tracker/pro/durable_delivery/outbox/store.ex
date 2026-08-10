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

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.{Entry, FileSystem, Record}

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
    :segment_max_bytes,
    :file_system,
    :entry_id_generator
  ]
  defstruct @enforce_keys ++
              [
                entries: [],
                live_bytes: 0,
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
          segment_max_bytes: pos_integer(),
          file_system: module(),
          entry_id_generator: (-> binary()),
          entries: [Entry.t()],
          live_bytes: non_neg_integer(),
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
         {:ok, segments} <- list_segments(store),
         :ok <- validate_segment_sequence(segments),
         {:ok, store} <- scan_segments(store, segments) do
      {:ok, store}
    end
  end

  def open(_root_path, _opts), do: {:error, :invalid_options}

  @doc "Append and fsync one new entry before exposing enqueue success."
  @spec enqueue(t(), atom(), binary(), keyword()) ::
          {:ok, Entry.t(), t()} | {:error, term()}
  def enqueue(%__MODULE__{} = store, stream, payload, opts \\ []) do
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
         {:ok, store} <- append_encoded(store, encoded) do
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
      }

      updated = add_entry(store, entry)
      {:ok, entry, updated}
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
  @spec usage(t()) :: %{entries: non_neg_integer(), bytes: non_neg_integer()}
  def usage(%__MODULE__{} = store) do
    %{entries: length(store.entries), bytes: store.live_bytes}
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
         {:ok, store} <- append_encoded(store, encoded) do
      {:ok, removed, remove_entries(store, removed)}
    end
  end

  def acknowledge(%__MODULE__{}, _receipt), do: {:error, :invalid_receipt}

  @doc "Durably authorize exact entry loss with a non-empty human-auditable reason."
  @spec authorize_loss(t(), map(), binary()) :: {:ok, Entry.t(), t()} | {:error, term()}
  def authorize_loss(%__MODULE__{} = store, identity, reason) when is_map(identity) do
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
         {:ok, store} <- append_encoded(store, encoded) do
      authorization = authorization_from_entry(entry, reason)

      updated = %{
        remove_entries(store, [entry])
        | loss_authorizations: store.loss_authorizations ++ [authorization]
      }

      {:ok, entry, updated}
    end
  end

  def authorize_loss(%__MODULE__{}, _identity, _reason), do: {:error, :invalid_loss_identity}

  defp new_store(root_path, opts) do
    with {:ok, storage_epoch} <- option_storage_epoch(opts),
         {:ok, stream_names, streams_by_name} <- option_streams(opts),
         {:ok, max_entries} <- positive_option(opts, :max_entries),
         {:ok, max_bytes} <- positive_option(opts, :max_bytes),
         {:ok, segment_max_bytes} <- positive_option(opts, :segment_max_bytes),
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

  defp validate_segment_sequence([]), do: :ok

  defp validate_segment_sequence(segments) do
    ids = Enum.map(segments, &elem(&1, 0))

    if ids == Enum.to_list(1..length(ids)) do
      :ok
    else
      {:error, {:segment_gap, ids}}
    end
  end

  defp scan_segments(store, []), do: {:ok, store}

  defp scan_segments(store, segments) do
    final_id = segments |> List.last() |> elem(0)

    result =
      Enum.reduce_while(segments, {:ok, store}, fn {id, path}, {:ok, acc} ->
        final? = id == final_id

        case store.file_system.read(path) do
          {:ok, bytes} ->
            case scan_segment(acc, path, bytes, 0, final?) do
              {:ok, scanned, valid_size} ->
                current = %{
                  scanned
                  | current_segment_id: id,
                    current_segment_path: path,
                    current_segment_bytes: valid_size
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

  defp append_encoded(store, encoded) do
    if byte_size(encoded) > store.segment_max_bytes do
      {:error, {:backpressure, :record_too_large}}
    else
      with {:ok, store} <- select_segment(store, byte_size(encoded)),
           :ok <- append_and_sync(store, encoded) do
        {:ok, %{store | current_segment_bytes: store.current_segment_bytes + byte_size(encoded)}}
      end
    end
  end

  defp select_segment(%__MODULE__{current_segment_path: nil} = store, _encoded_size),
    do: create_segment(store, 1)

  defp select_segment(store, encoded_size) do
    if store.current_segment_bytes > 0 and
         store.current_segment_bytes + encoded_size > store.segment_max_bytes do
      create_segment(store, store.current_segment_id + 1)
    else
      {:ok, store}
    end
  end

  defp create_segment(store, id) do
    path = segment_path(store, id)
    fs = store.file_system

    case fs.open(path, [:write, :binary, :raw, :exclusive]) do
      {:ok, device} ->
        operation = fs_result(fs.chmod(path, @file_mode), :chmod_segment)
        close_result = fs_result(fs.close(device), :close)

        with :ok <- combine_results(operation, close_result),
             :ok <- sync_directory(store, store.root_path) do
          {:ok,
           %{
             store
             | current_segment_id: id,
               current_segment_path: path,
               current_segment_bytes: 0
           }}
        end

      {:error, reason} ->
        {:error, {:segment_open, reason}}

      other ->
        {:error, {:segment_open, other}}
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

  defp quarantine_dir(store), do: Path.join(store.root_path, "quarantine")
  defp quarantine_suffix, do: Integer.to_string(System.unique_integer([:positive, :monotonic]))

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
