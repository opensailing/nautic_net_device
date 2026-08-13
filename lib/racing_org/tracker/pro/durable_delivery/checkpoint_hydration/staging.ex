defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.Staging do
  @moduledoc """
  Crash-safe durable staging for chunked checkpoint hydration.

  The immutable manifest binds one checkpoint transfer to its complete authenticated
  envelope and geometry. Chunks are validated before any filesystem mutation and are
  committed independently with `AtomicFile`; presence is recovered from the durable
  chunk files themselves, so a crash never depends on an in-memory receipt bitmap.
  """

  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.SegmentFileSystem, as: NativeFileSystem
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

  @format_version 1
  @manifest_tag :checkpoint_hydration_staging_manifest
  @hash_size 32
  @read_chunk_size 16_384
  @max_manifest_size 4_096
  @lock_wait_ms 1_000
  @lock_retry_ms 2
  @transition_timeout_ms :infinity
  @common_keys [
    :device_id,
    :credential_epoch,
    :storage_epoch,
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
  @chunk_keys @common_keys ++
                [
                  :total_content_length,
                  :chunk_index,
                  :chunk_count,
                  :chunk_offset,
                  :chunk_hash,
                  :chunk
                ]
  @transfer_keys @common_keys ++ [:total_content_length, :chunk_count]

  @spec path(Path.t(), <<_::256>>) :: Path.t()
  def path(root, <<hash::binary-size(@hash_size)>>) when is_binary(root) and root != "" do
    Path.join(root, Base.encode16(hash, case: :lower))
  end

  @spec put(Path.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def put(root, attrs, opts \\ [])

  def put(root, attrs, opts) when is_binary(root) and root != "" and is_map(attrs) and is_list(opts) do
    with {:ok, manifest, chunk} <- validate_chunk(attrs) do
      with_lock(root, manifest.checkpoint_hash, opts, fn -> put_locked(root, manifest, chunk, opts) end)
    end
  end

  def put(_root, _attrs, _opts), do: {:error, :invalid_checkpoint_hydration_chunk}

  @spec status(Path.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(root, transfer, opts \\ [])

  def status(root, transfer, opts)
      when is_binary(root) and root != "" and is_map(transfer) and is_list(opts) do
    with {:ok, expected} <- validate_transfer(transfer) do
      with_lock(root, expected.checkpoint_hash, opts, fn -> status_locked(root, expected, opts) end)
    end
  end

  def status(_root, _transfer, _opts), do: {:error, :invalid_checkpoint_hydration_transfer}

  @spec assemble(Path.t(), map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def assemble(root, transfer, opts \\ [])

  def assemble(root, transfer, opts)
      when is_binary(root) and root != "" and is_map(transfer) and is_list(opts) do
    with {:ok, expected} <- validate_transfer(transfer) do
      with_lock(root, expected.checkpoint_hash, opts, fn -> assemble_locked(root, expected, opts) end)
    end
  end

  def assemble(_root, _transfer, _opts), do: {:error, :invalid_checkpoint_hydration_transfer}

  @spec remove(Path.t(), <<_::256>>, keyword()) :: :ok | {:error, term()}
  def remove(root, checkpoint_hash, opts \\ [])

  def remove(root, <<checkpoint_hash::binary-size(@hash_size)>>, opts)
      when is_binary(root) and root != "" and is_list(opts) do
    with_lock(root, checkpoint_hash, opts, fn -> remove_locked(root, checkpoint_hash, opts) end)
  end

  def remove(_root, _checkpoint_hash, _opts), do: {:error, :invalid_checkpoint_hash}

  defp put_locked(root, manifest, %{index: index, bytes: bytes}, opts) do
    opts = Keyword.put(opts, :staging_root, Path.expand(root))

    with :ok <- ensure_manifest(root, manifest, opts),
         :ok <- ensure_chunk(root, manifest, index, bytes, opts),
         {:ok, result} <- staged_presence_status(root, manifest, opts) do
      {:ok, result}
    end
  end

  defp status_locked(root, expected, opts) do
    opts = Keyword.put(opts, :staging_root, Path.expand(root))

    with {:ok, manifest} <- read_manifest(root, expected.checkpoint_hash, opts),
         :ok <- match_manifest(manifest, expected),
         {:ok, present} <- observe_chunks(root, manifest, opts) do
      {:ok,
       %{
         total_content_length: manifest.total_content_length,
         chunk_count: manifest.chunk_count,
         missing_ranges: missing_ranges(present, manifest.chunk_count)
       }}
    end
  end

  defp assemble_locked(root, expected, opts) do
    opts = Keyword.put(opts, :staging_root, Path.expand(root))

    with {:ok, manifest} <- read_manifest(root, expected.checkpoint_hash, opts),
         :ok <- match_manifest(manifest, expected),
         {:ok, chunks} <- read_all_chunks(root, manifest, opts),
         content = IO.iodata_to_binary(chunks),
         true <- byte_size(content) == manifest.total_content_length,
         {:ok, content_hash} <- Checkpoint.content_hash(manifest.kind, manifest.schema_version, content),
         true <- secure_equal(content_hash, manifest.content_hash),
         :ok <-
           Checkpoint.validate_authority(manifest.kind, manifest.schema_version, content, %{
             device_id: manifest.device_id,
             credential_epoch: manifest.origin_credential_epoch,
             storage_epoch: manifest.origin_storage_epoch
           }) do
      {:ok, content}
    else
      false -> {:error, :checkpoint_content_hash_mismatch}
      {:error, :checkpoint_chunk_missing} = error -> error
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_checkpoint_content}
    end
  end

  defp ensure_manifest(root, manifest, opts) do
    destination = manifest_path(root, manifest.checkpoint_hash)
    bytes = manifest_bytes(manifest)

    case read_bounded(destination, @max_manifest_size, opts) do
      :empty -> write_exact(destination, bytes, root, opts)
      {:ok, ^bytes} -> rewrite_exact(destination, bytes, root, opts)
      {:ok, existing} -> classify_manifest_existing(existing, manifest)
      {:error, _reason} = error -> error
    end
  end

  defp classify_manifest_existing(bytes, expected) do
    case decode_manifest(bytes) do
      {:ok, existing} -> match_manifest(existing, expected)
      {:error, _reason} -> {:error, :corrupt_checkpoint_hydration_manifest}
    end
  end

  defp ensure_chunk(root, manifest, index, bytes, opts) do
    destination = chunk_path(root, manifest.checkpoint_hash, index)

    with :ok <- ensure_exact_file(destination, bytes, root, :checkpoint_hydration_chunk_conflict, opts),
         {:ok, hash} <-
           Checkpoint.chunk_hash(%{
             checkpoint_hash: manifest.checkpoint_hash,
             total_content_length: manifest.total_content_length,
             chunk_index: index,
             chunk_count: manifest.chunk_count,
             chunk_offset: index * Contract.chunk_size(),
             chunk: bytes
           }),
         :ok <-
           ensure_exact_file(
             chunk_hash_path(root, manifest.checkpoint_hash, index),
             hash,
             root,
             :checkpoint_hydration_chunk_conflict,
             opts
           ) do
      :ok
    end
  end

  defp ensure_exact_file(destination, bytes, root, conflict, opts) do
    case read_bounded(destination, byte_size(bytes), opts) do
      :empty -> write_exact(destination, bytes, root, opts)
      {:ok, ^bytes} -> rewrite_exact(destination, bytes, root, opts)
      {:ok, _different} -> {:error, conflict}
      {:error, _reason} = error -> error
    end
  end

  defp write_exact(path, bytes, root, opts), do: atomic_write(path, bytes, root, opts)

  # Seeing exact bytes after a previous uncertain rename is not durable evidence. An
  # exact replay rewrites and syncs the file so success always corresponds to a fresh
  # fsync of the file and its parent directory.
  defp rewrite_exact(path, bytes, root, opts), do: atomic_write(path, bytes, root, opts)

  defp atomic_write(path, bytes, root, opts) do
    case AtomicFile.write(path, bytes, atomic_opts(root, opts)) do
      :ok ->
        :ok

      {:error, {:durability_uncertain, _reason}} = uncertain ->
        uncertain

      {:error, _reason} = error ->
        error
    end
  end

  defp read_manifest(root, checkpoint_hash, opts) do
    case read_bounded(manifest_path(root, checkpoint_hash), @max_manifest_size, opts) do
      {:ok, bytes} -> decode_manifest(bytes)
      :empty -> {:error, :checkpoint_hydration_manifest_missing}
      {:error, _reason} = error -> error
    end
  end

  defp observe_chunks(root, manifest, opts) do
    Enum.reduce_while(0..(manifest.chunk_count - 1), {:ok, MapSet.new()}, fn index, {:ok, present} ->
      case read_expected_chunk(root, manifest, index, opts) do
        {:ok, _bytes} -> {:cont, {:ok, MapSet.put(present, index)}}
        :empty -> {:cont, {:ok, present}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp staged_presence_status(root, manifest, opts) do
    with {:ok, present} <- observe_chunk_names(root, manifest, opts) do
      {:ok,
       %{
         total_content_length: manifest.total_content_length,
         chunk_count: manifest.chunk_count,
         missing_ranges: missing_ranges(present, manifest.chunk_count)
       }}
    end
  end

  defp observe_chunk_names(root, manifest, opts) do
    fs = file_system(opts)
    directory = Path.join(path(root, manifest.checkpoint_hash), "chunks")

    with {:ok, names} <- list_directory(fs, directory) do
      names = MapSet.new(names)

      present =
        Enum.reduce(0..(manifest.chunk_count - 1), MapSet.new(), fn index, present ->
          basename = chunk_basename(index)

          if MapSet.member?(names, basename) and MapSet.member?(names, basename <> ".hash"),
            do: MapSet.put(present, index),
            else: present
        end)

      {:ok, present}
    end
  end

  defp read_all_chunks(root, manifest, opts) do
    Enum.reduce_while(0..(manifest.chunk_count - 1), {:ok, []}, fn index, {:ok, chunks} ->
      case read_expected_chunk(root, manifest, index, opts) do
        {:ok, bytes} -> {:cont, {:ok, [bytes | chunks]}}
        :empty -> {:halt, {:error, :checkpoint_chunk_missing}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, chunks} -> {:ok, Enum.reverse(chunks)}
      {:error, _reason} = error -> error
    end
  end

  defp read_expected_chunk(root, manifest, index, opts) do
    expected_length = expected_chunk_length(manifest.total_content_length, index)

    case read_bounded(chunk_path(root, manifest.checkpoint_hash, index), expected_length, opts) do
      {:ok, bytes} when byte_size(bytes) == expected_length ->
        with {:ok, expected_hash} <-
               Checkpoint.chunk_hash(%{
                 checkpoint_hash: manifest.checkpoint_hash,
                 total_content_length: manifest.total_content_length,
                 chunk_index: index,
                 chunk_count: manifest.chunk_count,
                 chunk_offset: index * Contract.chunk_size(),
                 chunk: bytes
               }),
             {:ok, stored_hash} <- read_chunk_hash(root, manifest.checkpoint_hash, index, opts),
             true <- secure_equal(expected_hash, stored_hash) do
          {:ok, bytes}
        else
          false -> {:error, :checkpoint_hydration_chunk_hash_mismatch}
          :empty -> :empty
          {:error, _reason} = error -> error
        end

      {:ok, _bytes} ->
        {:error, :corrupt_checkpoint_hydration_chunk}

      other ->
        other
    end
  end

  defp read_chunk_hash(root, checkpoint_hash, index, opts) do
    case read_bounded(chunk_hash_path(root, checkpoint_hash, index), @hash_size, opts) do
      {:ok, hash} when byte_size(hash) == @hash_size -> {:ok, hash}
      {:ok, _hash} -> {:error, :corrupt_checkpoint_hydration_chunk}
      other -> other
    end
  end

  defp remove_locked(root, checkpoint_hash, opts) do
    fs = file_system(opts)
    root = Path.expand(root)
    opts = Keyword.put(opts, :staging_root, root)
    directory = path(root, checkpoint_hash)
    chunks = Path.join(directory, "chunks")

    with {:ok, plan} <- preflight_cleanup(fs, root, directory, chunks, checkpoint_hash, opts),
         :ok <- execute_cleanup(fs, plan) do
      :ok
    else
      :empty -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp preflight_cleanup(fs, root, directory, chunks, checkpoint_hash, opts) do
    with {:ok, ancestors} <- capture_directory_chain(fs, root),
         {:ok, directory_stat} <- required_directory(fs, directory),
         {:ok, manifest} <- read_cleanup_manifest(root, checkpoint_hash, opts),
         {:ok, chunk_entries, chunk_names, chunks_stat} <-
           preflight_chunks(fs, chunks, manifest.chunk_count),
         {:ok, manifest_entries, manifest_names} <- preflight_manifest(fs, directory),
         :ok <- revalidate_directories(fs, ancestors ++ [{directory, directory_stat}]),
         :ok <- revalidate_optional_directory(fs, chunks, chunks_stat) do
      {:ok,
       %{
         root: root,
         root_stat: List.last(ancestors) |> elem(1),
         ancestors: ancestors,
         directory: directory,
         directory_stat: directory_stat,
         chunks: chunks,
         chunks_stat: chunks_stat,
         chunk_entries: chunk_entries,
         chunk_names: chunk_names,
         manifest_entries: manifest_entries,
         manifest_names: manifest_names
       }}
    else
      :empty -> :empty
      {:error, _reason} = error -> error
    end
  end

  defp read_cleanup_manifest(root, checkpoint_hash, opts) do
    case read_manifest(root, checkpoint_hash, opts) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, :checkpoint_hydration_manifest_missing} -> {:ok, %{chunk_count: Contract.max_checkpoint_chunks()}}
      {:error, _reason} -> corrupt_staging()
    end
  end

  defp capture_directory_chain(fs, root) do
    case required_directory(fs, root) do
      {:ok, stat} -> {:ok, [{root, stat}]}
      :empty -> :empty
      {:error, _reason} = error -> error
    end
  end

  defp required_directory(fs, directory) do
    case safe_fs_call(fs, :lstat, [directory]) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        if valid_stat?(stat), do: {:ok, stat}, else: corrupt_staging()

      {:ok, %File.Stat{}} ->
        corrupt_staging()

      {:error, :enoent} ->
        :empty

      {:error, reason} ->
        staging_io(reason)

      _other ->
        staging_io(:invalid_lstat_response)
    end
  end

  defp preflight_chunks(fs, chunks, chunk_count) do
    case required_directory(fs, chunks) do
      {:ok, chunks_stat} ->
        with {:ok, names} <- list_directory(fs, chunks),
             true <- Enum.all?(names, &removable_chunk_entry?(&1, chunk_count)),
             {:ok, entries} <- capture_regular_entries(fs, chunks, names) do
          {:ok, entries, names, chunks_stat}
        else
          false -> corrupt_staging()
          {:error, _reason} = error -> error
        end

      :empty ->
        {:ok, [], [], nil}

      {:error, _reason} = error ->
        error
    end
  end

  defp preflight_manifest(fs, directory) do
    with {:ok, names} <- list_directory(fs, directory),
         names = Enum.reject(names, &(&1 == "chunks")),
         true <- Enum.all?(names, &removable_manifest_entry?/1),
         {:ok, entries} <- capture_regular_entries(fs, directory, names) do
      {:ok, entries, names}
    else
      false -> corrupt_staging()
      {:error, _reason} = error -> error
    end
  end

  defp list_directory(fs, directory) do
    case safe_fs_call(fs, :list_dir, [directory]) do
      {:ok, names} when is_list(names) ->
        if Enum.all?(names, &is_binary/1),
          do: {:ok, Enum.sort(names)},
          else: staging_io(:invalid_list_dir_response)

      {:error, reason} ->
        staging_io(reason)

      _other ->
        staging_io(:invalid_list_dir_response)
    end
  end

  defp capture_regular_entries(fs, directory, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, entries} ->
      path = Path.join(directory, name)

      case safe_fs_call(fs, :lstat, [path]) do
        {:ok, %File.Stat{type: :regular} = stat} ->
          if valid_stat?(stat),
            do: {:cont, {:ok, entries ++ [{path, stat}]}},
            else: {:halt, corrupt_staging()}

        {:ok, %File.Stat{}} ->
          {:halt, corrupt_staging()}

        {:error, reason} ->
          {:halt, staging_io(reason)}

        _other ->
          {:halt, staging_io(:invalid_lstat_response)}
      end
    end)
  end

  defp execute_cleanup(fs, plan) do
    with :ok <- revalidate_cleanup_plan(fs, plan),
         :ok <- revalidate_cleanup_names(fs, plan),
         {:ok, mutated?} <- remove_entries(fs, plan.chunk_entries, plan, :full, false),
         {:ok, mutated?} <-
           cleanup_observation(sync_optional_directory(fs, plan.chunks, plan.chunks_stat), mutated?),
         {:ok, mutated?} <-
           cleanup_mutation(
             remove_optional_directory(fs, plan.chunks, plan.chunks_stat, plan),
             mutated?,
             plan.chunks_stat != nil
           ),
         {:ok, mutated?} <- cleanup_observation(sync_directory(fs, plan.directory, plan.directory_stat), mutated?),
         {:ok, mutated?} <- remove_entries(fs, plan.manifest_entries, plan, :without_chunks, mutated?),
         {:ok, mutated?} <- cleanup_observation(sync_directory(fs, plan.directory, plan.directory_stat), mutated?),
         {:ok, mutated?} <-
           cleanup_mutation(remove_directory(fs, plan.directory, plan.directory_stat, plan), mutated?, true),
         {:ok, _mutated?} <- cleanup_observation(sync_directory(fs, plan.root, plan.root_stat), mutated?) do
      :ok
    end
  end

  defp revalidate_cleanup_names(fs, plan) do
    with {:ok, chunk_names} <- list_optional_directory(fs, plan.chunks, plan.chunks_stat),
         true <- chunk_names == plan.chunk_names,
         {:ok, names} <- list_directory(fs, plan.directory),
         manifest_names = Enum.reject(names, &(&1 == "chunks")),
         true <- manifest_names == plan.manifest_names do
      :ok
    else
      false -> corrupt_staging()
      {:error, _reason} = error -> error
    end
  end

  defp list_optional_directory(_fs, _path, nil), do: {:ok, []}
  defp list_optional_directory(fs, path, _stat), do: list_directory(fs, path)

  defp remove_entries(fs, entries, plan, stage, mutated?) do
    Enum.reduce_while(entries, {:ok, mutated?}, fn {path, stat}, {:ok, mutated?} ->
      result =
        with :ok <- revalidate_cleanup_plan(fs, plan, stage),
             :ok <- remove_verified(fs, path, stat, :regular, plan.root) do
          {:ok, true}
        end

      case result do
        {:ok, true} -> {:cont, {:ok, true}}
        {:error, _reason} = error -> {:halt, cleanup_result(error, mutated?)}
      end
    end)
  end

  defp cleanup_observation(:ok, mutated?), do: {:ok, mutated?}

  defp cleanup_observation({:error, _reason} = error, mutated?),
    do: cleanup_result(error, mutated?)

  defp cleanup_mutation(:ok, mutated?, happened?), do: {:ok, mutated? or happened?}

  defp cleanup_mutation({:error, _reason} = error, mutated?, _happened?),
    do: cleanup_result(error, mutated?)

  defp cleanup_result({:error, {:durability_uncertain, _reason}} = error, _mutated?), do: error
  defp cleanup_result({:error, reason}, true), do: durability_uncertain(reason)
  defp cleanup_result({:error, _reason} = error, false), do: error

  defp remove_verified(FileSystem, path, stat, type, root) do
    identity = {stat.major_device, stat.minor_device, stat.inode}

    with {:ok, parent_identity} <- native_parent_identity(path),
         {:ok, root_identity} <- native_directory_identity(root),
         {:ok, entry} <- bind_native_entry(root, path, type, identity, parent_identity, root_identity) do
      result = NativeFileSystem.remove_bound(entry)
      close = NativeFileSystem.close_bound(entry)

      case {result, close} do
        {:ok, :ok} -> :ok
        {{:error, _reason}, _close} -> corrupt_staging()
        {_result, {:error, reason}} -> durability_uncertain({:bound_entry_close, reason})
      end
    else
      {:error, _reason} -> corrupt_staging()
    end
  end

  defp remove_verified(fs, path, stat, :regular, _root) do
    with :ok <- verify_path_identity(fs, path, stat) do
      case safe_fs_call(fs, :remove, [path]) do
        :ok -> :ok
        {:error, :enoent} -> corrupt_staging()
        {:error, reason} -> staging_io(reason)
        _other -> staging_io(:invalid_remove_response)
      end
    end
  end

  defp remove_verified(fs, path, stat, :directory, _root) do
    with :ok <- verify_path_identity(fs, path, stat, :directory) do
      case safe_fs_call(fs, :rmdir, [path]) do
        :ok -> :ok
        {:error, :enoent} -> corrupt_staging()
        {:error, reason} -> staging_io(reason)
        _other -> staging_io(:invalid_rmdir_response)
      end
    end
  end

  defp remove_optional_directory(_fs, _path, nil, _plan), do: :ok

  defp remove_optional_directory(fs, path, stat, plan) do
    with :ok <- revalidate_cleanup_plan(fs, plan, :without_chunks),
         :ok <- remove_verified(fs, path, stat, :directory, plan.root) do
      :ok
    end
  end

  defp remove_directory(fs, path, stat, plan) do
    with :ok <- revalidate_directories(fs, plan.ancestors ++ [{path, stat}]),
         :ok <- remove_verified(fs, path, stat, :directory, plan.root) do
      :ok
    end
  end

  defp revalidate_cleanup_plan(fs, plan, stage \\ :full) do
    with :ok <- revalidate_directories(fs, plan.ancestors ++ [{plan.directory, plan.directory_stat}]),
         :ok <- revalidate_cleanup_stage(fs, plan, stage) do
      :ok
    end
  end

  defp revalidate_cleanup_stage(fs, plan, :full),
    do: revalidate_optional_directory(fs, plan.chunks, plan.chunks_stat)

  defp revalidate_cleanup_stage(_fs, _plan, :without_chunks), do: :ok

  defp revalidate_directories(fs, identities) do
    Enum.reduce_while(identities, :ok, fn {path, stat}, :ok ->
      case verify_path_identity(fs, path, stat, :directory) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp revalidate_optional_directory(_fs, _path, nil), do: :ok
  defp revalidate_optional_directory(fs, path, stat), do: verify_path_identity(fs, path, stat, :directory)

  defp verify_path_identity(fs, path, expected, type \\ :regular) do
    case safe_fs_call(fs, :lstat, [path]) do
      {:ok, %File.Stat{type: ^type} = current} ->
        if valid_stat?(current) and same_identity?(current, expected), do: :ok, else: corrupt_staging()

      _other ->
        corrupt_staging()
    end
  end

  defp sync_optional_directory(_fs, _path, nil), do: :ok
  defp sync_optional_directory(fs, path, stat), do: sync_directory(fs, path, stat)

  defp sync_directory(fs, directory, expected_stat) do
    with :ok <- verify_path_identity(fs, directory, expected_stat, :directory) do
      case safe_fs_call(fs, :open, [directory, [:read, :raw, :directory]]) do
        {:ok, device} ->
          result = sync_open_directory(fs, device, directory, expected_stat)
          close_result = safe_fs_call(fs, :close, [device])

          case {result, close_result} do
            {:ok, :ok} -> :ok
            {{:error, _reason} = error, _close} -> error
            {_result, {:error, reason}} -> durability_uncertain({:directory_close, reason})
            _other -> durability_uncertain(:invalid_directory_close_response)
          end

        {:error, reason} ->
          staging_io(reason)

        _other ->
          staging_io(:invalid_open_response)
      end
    end
  end

  defp sync_open_directory(fs, device, directory, expected_stat) do
    with {:ok, %File.Stat{type: :directory} = descriptor_stat} <- safe_fs_call(fs, :file_info, [device]),
         true <- valid_stat?(descriptor_stat) and same_identity?(descriptor_stat, expected_stat),
         :ok <- safe_fs_call(fs, :sync, [device]),
         :ok <- verify_path_identity(fs, directory, expected_stat, :directory) do
      :ok
    else
      {:error, reason} -> durability_uncertain({:directory_sync, reason})
      _other -> durability_uncertain(:directory_identity_changed)
    end
  end

  defp removable_chunk_entry?(name, chunk_count) when is_binary(name) do
    case Regex.run(
           ~r/\A(\d{8})\.chunk(?:\.hash)?(?:\.tmp\.[A-Za-z0-9_-]{16}(?:\.[2-8])?)?\z/,
           name,
           capture: :all_but_first
         ) do
      [index] ->
        case Integer.parse(index) do
          {index, ""} -> index < chunk_count and index < Contract.max_checkpoint_chunks()
          _other -> false
        end

      _other ->
        false
    end
  end

  defp removable_chunk_entry?(_name, _chunk_count), do: false

  defp removable_manifest_entry?("manifest"), do: true

  defp removable_manifest_entry?(name) when is_binary(name),
    do: Regex.match?(~r/\Amanifest\.tmp\.[A-Za-z0-9_-]{16}(?:\.[2-8])?\z/, name)

  defp removable_manifest_entry?(_name), do: false

  defp same_identity?(left, right) do
    left.inode == right.inode and left.major_device == right.major_device and
      left.minor_device == right.minor_device
  end

  defp corrupt_staging, do: {:error, :corrupt_checkpoint_hydration_staging}
  defp staging_io(reason), do: {:error, {:checkpoint_hydration_staging_io, reason}}
  defp durability_uncertain(reason), do: {:error, {:durability_uncertain, reason}}

  defp validate_chunk(attrs) do
    with :ok <- exact_keys(attrs, @chunk_keys, :invalid_checkpoint_hydration_chunk),
         {:ok, manifest} <- validate_transfer(Map.take(attrs, @transfer_keys)),
         :ok <- u32(attrs.chunk_index, :invalid_chunk_index),
         :ok <- ensure(attrs.chunk_index < manifest.chunk_count, :invalid_chunk_index),
         expected_offset = attrs.chunk_index * Contract.chunk_size(),
         :ok <- ensure(attrs.chunk_offset == expected_offset, :invalid_chunk_offset),
         expected_length = expected_chunk_length(manifest.total_content_length, attrs.chunk_index),
         :ok <- ensure(is_binary(attrs.chunk) and byte_size(attrs.chunk) == expected_length, :invalid_chunk_length),
         :ok <-
           ensure(
             is_binary(attrs.chunk_hash) and byte_size(attrs.chunk_hash) == @hash_size,
             :invalid_checkpoint_chunk_hash
           ),
         {:ok, chunk_hash} <-
           Checkpoint.chunk_hash(
             Map.take(attrs, [
               :checkpoint_hash,
               :total_content_length,
               :chunk_index,
               :chunk_count,
               :chunk_offset,
               :chunk
             ])
           ),
         true <- secure_equal(chunk_hash, attrs.chunk_hash) do
      {:ok, manifest, %{index: attrs.chunk_index, bytes: attrs.chunk}}
    else
      false -> chunk_validation_error(attrs)
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_checkpoint_hydration_chunk}
    end
  end

  defp chunk_validation_error(attrs) do
    case expected_chunk_hash(attrs) do
      {:ok, expected} ->
        if secure_equal(expected, Map.get(attrs, :chunk_hash)),
          do: {:error, :invalid_checkpoint_chunk_geometry},
          else: {:error, :checkpoint_chunk_hash_mismatch}

      _other ->
        {:error, :invalid_checkpoint_chunk_geometry}
    end
  end

  defp expected_chunk_hash(attrs) when is_map(attrs) do
    Checkpoint.chunk_hash(
      Map.take(attrs, [
        :checkpoint_hash,
        :total_content_length,
        :chunk_index,
        :chunk_count,
        :chunk_offset,
        :chunk
      ])
    )
  end

  defp validate_transfer(attrs) do
    with :ok <- exact_keys(attrs, @transfer_keys, :invalid_checkpoint_hydration_transfer),
         true <- is_binary(attrs.device_id) and byte_size(attrs.device_id) == 16,
         :ok <- u32(attrs.credential_epoch, :invalid_credential_epoch),
         true <-
           is_binary(attrs.storage_epoch) and byte_size(attrs.storage_epoch) == 16 and attrs.storage_epoch != <<0::128>>,
         :ok <- u32(attrs.origin_credential_epoch, :invalid_origin_credential_epoch),
         true <-
           is_binary(attrs.origin_storage_epoch) and byte_size(attrs.origin_storage_epoch) == 16 and
             attrs.origin_storage_epoch != <<0::128>>,
         true <- is_integer(attrs.sequence) and attrs.sequence > 0 and attrs.sequence <= 9_223_372_036_854_775_807,
         {:ok, _kind_code} <- Contract.checkpoint_schema(attrs.kind, attrs.schema_version),
         true <-
           is_integer(attrs.source_generation) and attrs.source_generation >= 0 and
             attrs.source_generation <= 9_223_372_036_854_775_807,
         true <- fixed_hashes(attrs),
         :ok <-
           ensure(
             is_integer(attrs.total_content_length) and attrs.total_content_length > 0,
             :invalid_total_content_length
           ),
         :ok <- ensure(attrs.total_content_length <= Contract.max_checkpoint_content_size(), :checkpoint_too_large),
         expected_count = div(attrs.total_content_length + Contract.chunk_size() - 1, Contract.chunk_size()),
         true <- attrs.chunk_count == expected_count and attrs.chunk_count <= Contract.max_checkpoint_chunks(),
         {:ok, checkpoint_hash} <- hydration_checkpoint_hash(attrs),
         :ok <- ensure(secure_equal(checkpoint_hash, attrs.checkpoint_hash), :checkpoint_hash_mismatch) do
      {:ok, Map.take(attrs, @transfer_keys)}
    else
      false -> {:error, :invalid_checkpoint_hydration_transfer}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_checkpoint_hydration_transfer}
    end
  end

  defp hydration_checkpoint_hash(attrs) do
    Checkpoint.hash(%{
      device_id: attrs.device_id,
      credential_epoch: attrs.origin_credential_epoch,
      storage_epoch: attrs.origin_storage_epoch,
      sequence: attrs.sequence,
      kind: attrs.kind,
      schema_version: attrs.schema_version,
      source_generation: attrs.source_generation,
      parent_hash: attrs.parent_hash,
      content_hash: attrs.content_hash
    })
  end

  defp fixed_hashes(attrs) do
    Enum.all?([:parent_hash, :content_hash, :checkpoint_hash], fn key ->
      value = Map.get(attrs, key)
      is_binary(value) and byte_size(value) == @hash_size
    end)
  end

  defp manifest_bytes(manifest),
    do: :erlang.term_to_binary({@format_version, @manifest_tag, manifest}, minor_version: 2)

  defp decode_manifest(bytes) do
    with {@format_version, @manifest_tag, manifest} <- safe_term(bytes),
         {:ok, validated} <- validate_transfer(manifest),
         true <- secure_equal(manifest_bytes(validated), bytes) do
      {:ok, validated}
    else
      _other -> {:error, :corrupt_checkpoint_hydration_manifest}
    end
  end

  defp safe_term(<<131, 80, _compressed::binary>>), do: :corrupt

  defp safe_term(bytes) do
    case :erlang.binary_to_term(bytes, [:safe, :used]) do
      {term, used} when used == byte_size(bytes) -> term
      _other -> :corrupt
    end
  rescue
    _exception -> :corrupt
  catch
    _kind, _reason -> :corrupt
  end

  defp match_manifest(existing, expected) do
    if existing == expected,
      do: :ok,
      else: {:error, :checkpoint_hydration_transfer_conflict}
  end

  defp missing_ranges(present, chunk_count) do
    0..(chunk_count - 1)
    |> Enum.reject(&MapSet.member?(present, &1))
    |> Enum.reduce([], fn
      index, [%{first_chunk_index: first, chunk_count: count} | rest]
      when index == first + count ->
        [%{first_chunk_index: first, chunk_count: count + 1} | rest]

      index, ranges ->
        [%{first_chunk_index: index, chunk_count: 1} | ranges]
    end)
    |> Enum.reverse()
    |> bound_missing_ranges()
  end

  defp range(first, last), do: %{first_chunk_index: first, chunk_count: last - first + 1}

  # A resume frame has a fixed range budget. If pathological out-of-order delivery
  # creates more exact gaps, deterministically widen adjacent ranges across the
  # smallest already-present gap. Re-requesting a durable chunk is safe and keeps the
  # response canonical and representable.
  defp bound_missing_ranges(ranges) do
    if length(ranges) <= Contract.max_checkpoint_missing_ranges() do
      ranges
    else
      ranges
      |> merge_smallest_gap()
      |> bound_missing_ranges()
    end
  end

  defp merge_smallest_gap([_first, _second | _rest] = ranges) do
    {_gap, index} =
      ranges
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index()
      |> Enum.map(fn {[left, right], index} ->
        left_last = left.first_chunk_index + left.chunk_count - 1
        {right.first_chunk_index - left_last - 1, index}
      end)
      |> Enum.min()

    {left, [right | tail]} = Enum.split(ranges, index + 1)
    previous = List.last(left)
    prefix = Enum.drop(left, -1)
    final = right.first_chunk_index + right.chunk_count - 1
    prefix ++ [range(previous.first_chunk_index, final)] ++ tail
  end

  defp merge_smallest_gap(ranges), do: ranges

  defp expected_chunk_length(total, index),
    do: min(Contract.chunk_size(), total - index * Contract.chunk_size())

  defp manifest_path(root, checkpoint_hash), do: Path.join(path(root, checkpoint_hash), "manifest")

  defp chunk_path(root, checkpoint_hash, index) do
    Path.join([path(root, checkpoint_hash), "chunks", chunk_basename(index)])
  end

  defp chunk_hash_path(root, checkpoint_hash, index) do
    Path.join([path(root, checkpoint_hash), "chunks", chunk_basename(index) <> ".hash"])
  end

  defp chunk_basename(index), do: String.pad_leading(Integer.to_string(index), 8, "0") <> ".chunk"

  defp read_bounded(destination, maximum, opts) do
    fs = file_system(opts)

    with true <- bounded_file_system?(fs),
         :ok <- validate_ancestor_chain(fs, destination, opts) do
      case safe_fs_call(fs, :lstat, [destination]) do
        {:ok, %File.Stat{type: :regular} = path_stat} ->
          if valid_stat?(path_stat) and path_stat.size <= maximum,
            do: read_regular(fs, destination, path_stat, maximum, Keyword.get(opts, :staging_root)),
            else: {:error, :corrupt_checkpoint_hydration_staging}

        {:ok, %File.Stat{}} ->
          {:error, :corrupt_checkpoint_hydration_staging}

        {:error, :enoent} ->
          :empty

        {:error, reason} ->
          {:error, {:checkpoint_hydration_staging_io, reason}}

        _other ->
          {:error, {:checkpoint_hydration_staging_io, :invalid_lstat_response}}
      end
    else
      false -> {:error, :checkpoint_hydration_staging_bounded_read_unsupported}
      {:error, _reason} = error -> error
    end
  end

  defp validate_ancestor_chain(fs, destination, opts) do
    case Keyword.get(opts, :staging_root) do
      nil ->
        :ok

      root ->
        parent = Path.dirname(destination)

        if inside_root?(parent, root) do
          root
          |> ancestor_paths(parent)
          |> Enum.reduce_while(:ok, fn directory, :ok ->
            case safe_fs_call(fs, :lstat, [directory]) do
              {:ok, %File.Stat{type: :directory} = stat} ->
                if valid_stat?(stat), do: {:cont, :ok}, else: {:halt, {:error, :corrupt_checkpoint_hydration_staging}}

              {:ok, %File.Stat{}} ->
                {:halt, {:error, :corrupt_checkpoint_hydration_staging}}

              {:error, :enoent} ->
                {:cont, :ok}

              {:error, reason} ->
                {:halt, {:error, {:checkpoint_hydration_staging_io, reason}}}

              _other ->
                {:halt, {:error, {:checkpoint_hydration_staging_io, :invalid_lstat_response}}}
            end
          end)
        else
          {:error, :corrupt_checkpoint_hydration_staging}
        end
    end
  end

  defp ancestor_paths(root, parent) do
    root = Path.expand(root)
    parent = Path.expand(parent)

    Stream.iterate(parent, &Path.dirname/1)
    |> Enum.take_while(&inside_root?(&1, root))
    |> Enum.reverse()
  end

  defp inside_root?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  defp read_regular(FileSystem, destination, path_stat, maximum, root) do
    identity = file_identity(path_stat)

    with true <- is_binary(root),
         {:ok, parent_identity} <- native_parent_identity(destination),
         {:ok, root_identity} <- native_directory_identity(root),
         {:ok, entry} <-
           bind_native_entry(root, destination, :regular, identity, parent_identity, root_identity) do
      result = read_bound_entry(entry, path_stat, maximum)
      close = NativeFileSystem.close_bound(entry)
      if close == :ok, do: result, else: {:error, {:checkpoint_hydration_staging_io, :close_failed}}
    else
      {:error, :enoent} -> :empty
      {:error, _reason} -> {:error, :corrupt_checkpoint_hydration_staging}
      false -> {:error, :corrupt_checkpoint_hydration_staging}
    end
  end

  defp read_regular(fs, destination, path_stat, maximum, _root) do
    case safe_fs_call(fs, :open, [destination, [:read, :binary, :raw]]) do
      {:ok, device} ->
        result = read_device(fs, device, path_stat, maximum)
        result = revalidate_path_after_read(fs, destination, path_stat, result)
        close = safe_fs_call(fs, :close, [device])
        if close == :ok, do: result, else: {:error, {:checkpoint_hydration_staging_io, :close_failed}}

      {:error, reason} ->
        {:error, {:checkpoint_hydration_staging_io, reason}}

      _other ->
        {:error, {:checkpoint_hydration_staging_io, :invalid_open_response}}
    end
  end

  defp read_bound_entry(entry, path_stat, maximum) do
    with {:ok, %{size: size} = first} <- NativeFileSystem.bound_info(entry),
         true <- bound_identity?(first, path_stat) and size <= maximum,
         {:ok, chunks, total} <- read_bound_chunks(entry, maximum + 1, [], 0),
         true <- total == size and total <= maximum,
         {:ok, %{size: ^size} = final} <- NativeFileSystem.bound_info(entry),
         true <- bound_identity?(final, path_stat) do
      {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    else
      _other -> {:error, :corrupt_checkpoint_hydration_staging}
    end
  end

  defp read_bound_chunks(_entry, 0, chunks, total), do: {:ok, chunks, total}

  defp read_bound_chunks(entry, remaining, chunks, total) do
    count = min(remaining, @read_chunk_size)

    case NativeFileSystem.read_bound(entry, count) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) in 1..count//1 ->
        read_bound_chunks(entry, remaining - byte_size(bytes), [bytes | chunks], total + byte_size(bytes))

      :eof ->
        {:ok, chunks, total}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_read_response}
    end
  end

  defp bound_identity?(info, stat) do
    info.inode == stat.inode and info.major_device == stat.major_device and
      info.minor_device == stat.minor_device
  end

  defp bind_native_entry(root, path, type, identity, parent_identity, root_identity) do
    NativeFileSystem.bind_entry(root, path, type, identity, parent_identity, root_identity)
  end

  defp native_parent_identity(path), do: native_directory_identity(Path.dirname(path))

  defp native_directory_identity(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        if valid_stat?(stat),
          do: {:ok, file_identity(stat)},
          else: {:error, :corrupt_checkpoint_hydration_staging}

      {:ok, %File.Stat{}} ->
        {:error, :corrupt_checkpoint_hydration_staging}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp file_identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}

  defp revalidate_path_after_read(fs, destination, original_stat, result) do
    case safe_fs_call(fs, :lstat, [destination]) do
      {:ok, %File.Stat{type: :regular} = current_stat} ->
        if valid_stat?(current_stat) and same_file?(original_stat, current_stat),
          do: result,
          else: {:error, :corrupt_checkpoint_hydration_staging}

      _other ->
        {:error, :corrupt_checkpoint_hydration_staging}
    end
  end

  defp read_device(fs, device, path_stat, maximum) do
    with {:ok, %File.Stat{type: :regular} = descriptor_stat} <- safe_fs_call(fs, :file_info, [device]),
         true <- valid_stat?(descriptor_stat),
         true <- same_file?(path_stat, descriptor_stat),
         true <- descriptor_stat.size <= maximum,
         {:ok, chunks, total} <- read_chunks(fs, device, maximum + 1, [], 0),
         true <- total == descriptor_stat.size and total <= maximum,
         {:ok, %File.Stat{type: :regular} = final_stat} <- safe_fs_call(fs, :file_info, [device]),
         true <- valid_stat?(final_stat),
         true <- same_file?(descriptor_stat, final_stat) do
      {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    else
      _other -> {:error, :corrupt_checkpoint_hydration_staging}
    end
  end

  defp valid_stat?(%File.Stat{} = stat) do
    Enum.all?([stat.size, stat.inode, stat.major_device, stat.minor_device], fn value ->
      is_integer(value) and value >= 0
    end)
  end

  defp read_chunks(_fs, _device, 0, chunks, total), do: {:ok, chunks, total}

  defp read_chunks(fs, device, remaining, chunks, total) do
    count = min(remaining, @read_chunk_size)

    case safe_fs_call(fs, :read, [device, count]) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) in 1..count//1 ->
        read_chunks(fs, device, remaining - byte_size(bytes), [bytes | chunks], total + byte_size(bytes))

      :eof ->
        {:ok, chunks, total}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_read_response}
    end
  end

  defp same_file?(left, right) do
    left.inode == right.inode and left.major_device == right.major_device and
      left.minor_device == right.minor_device and left.size == right.size
  end

  defp bounded_file_system?(fs) do
    is_atom(fs) and Code.ensure_loaded?(fs) and
      Enum.all?([lstat: 1, open: 2, file_info: 1, read: 2, close: 1], fn {callback, arity} ->
        function_exported?(fs, callback, arity)
      end)
  end

  defp with_lock(root, checkpoint_hash, opts, transition) when is_function(transition, 0) do
    with {:ok, transition_timeout} <- transition_timeout(opts) do
      lock_resource = {__MODULE__, :staging_path, Path.expand(root), checkpoint_hash}
      requester = {self(), make_ref()}
      lock_id = {lock_resource, requester}
      deadline = System.monotonic_time(:millisecond) + @lock_wait_ms

      with {:ok, holder} <- acquire_lock(lock_id, deadline) do
        run_locked(holder, transition, transition_timeout)
      end
    end
  end

  defp transition_timeout(opts) do
    case Keyword.get(opts, :transition_timeout_ms, @transition_timeout_ms) do
      :infinity -> {:ok, :infinity}
      timeout when is_integer(timeout) and timeout >= 0 and timeout <= 3_600_000 -> {:ok, timeout}
      _other -> {:error, :invalid_checkpoint_hydration_staging_options}
    end
  end

  defp acquire_lock(lock_id, deadline) do
    owner = self()
    acquired_ref = make_ref()

    {holder, monitor} =
      spawn_monitor(fn -> hold_global_lock(owner, acquired_ref, lock_id, deadline) end)

    receive do
      {^acquired_ref, :acquired} -> {:ok, {holder, monitor}}
      {:DOWN, ^monitor, :process, ^holder, :lock_timeout} -> {:error, :checkpoint_hydration_staging_lock_timeout}
      {:DOWN, ^monitor, :process, ^holder, _reason} -> {:error, :checkpoint_hydration_staging_lock_unavailable}
    after
      @lock_wait_ms ->
        Process.exit(holder, :kill)
        await_holder_down(holder, monitor)
        drain_result(acquired_ref)
        {:error, :checkpoint_hydration_staging_lock_timeout}
    end
  end

  defp hold_global_lock(owner, acquired_ref, lock_id, deadline) do
    holder = self()
    _watcher = spawn(fn -> stop_on_owner_exit(owner, holder) end)
    await_global_lock(owner, acquired_ref, lock_id, deadline)
  end

  defp await_global_lock(owner, acquired_ref, lock_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        exit(:lock_timeout)

      :global.set_lock(lock_id, [node()], 0) ->
        send(owner, {acquired_ref, :acquired})
        serve_lock_owner(owner, lock_id)

      true ->
        receive do
        after
          min(@lock_retry_ms, remaining) -> await_global_lock(owner, acquired_ref, lock_id, deadline)
        end
    end
  end

  defp serve_lock_owner(owner, lock_id) do
    receive do
      {:run_checkpoint_hydration_staging, ^owner, result_ref, transition} when is_function(transition, 0) ->
        send(owner, {result_ref, transition.()})
        serve_lock_owner(owner, lock_id)

      {:release_checkpoint_hydration_staging, ^owner} ->
        :global.del_lock(lock_id, [node()])
    end
  end

  defp run_locked({holder, monitor}, transition, transition_timeout) do
    result_ref = make_ref()
    send(holder, {:run_checkpoint_hydration_staging, self(), result_ref, transition})

    receive do
      {^result_ref, result} ->
        send(holder, {:release_checkpoint_hydration_staging, self()})
        await_holder_down(holder, monitor)
        result

      {:DOWN, ^monitor, :process, ^holder, _reason} ->
        {:error, {:durability_uncertain, :checkpoint_hydration_staging_lock_lost}}
    after
      transition_timeout ->
        Process.exit(holder, :kill)
        await_holder_down(holder, monitor)
        drain_result(result_ref)
        {:error, {:durability_uncertain, :checkpoint_hydration_staging_transition_timeout}}
    end
  end

  defp await_holder_down(holder, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^holder, _reason} -> :ok
    after
      @lock_wait_ms ->
        Process.exit(holder, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^holder, _reason} -> :ok
        end
    end
  end

  defp drain_result(ref) do
    receive do
      {^ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp stop_on_owner_exit(owner, holder) do
    owner_monitor = Process.monitor(owner)
    holder_monitor = Process.monitor(holder)

    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} -> Process.exit(holder, :kill)
      {:DOWN, ^holder_monitor, :process, ^holder, _reason} -> :ok
    end
  end

  defp atomic_opts(root, opts) do
    opts
    |> Keyword.take([:file_system, :fault_injector, :temp_suffix])
    |> Keyword.put(:directory_root, Path.expand(root))
  end

  defp file_system(opts), do: Keyword.get(opts, :file_system, FileSystem)

  defp safe_fs_call(fs, callback, args) do
    apply(fs, callback, args)
  rescue
    _exception -> {:error, {:callback_failed, callback, :raise}}
  catch
    _kind, _reason -> {:error, {:callback_failed, callback, :exit}}
  end

  defp exact_keys(value, expected, error) when is_map(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(expected), do: :ok, else: {:error, error}
  end

  defp exact_keys(_value, _expected, error), do: {:error, error}

  defp ensure(true, _error), do: :ok
  defp ensure(false, error), do: {:error, error}

  defp u32(value, _error) when is_integer(value) and value >= 0 and value <= 0xFFFF_FFFF, do: :ok
  defp u32(_value, error), do: {:error, error}

  defp secure_equal(left, right) when is_binary(left) and is_binary(right),
    do: byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)

  defp secure_equal(_left, _right), do: false
end
