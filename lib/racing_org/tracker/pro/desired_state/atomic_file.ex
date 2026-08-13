defmodule RacingOrg.Tracker.Pro.DesiredState.AtomicFile do
  @moduledoc false

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.SegmentFileSystem, as: Native
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

  @dir_mode 0o700
  @file_mode 0o600
  @temp_attempts 8
  @temp_read_chunk_bytes 16_384
  @base_temp_suffix_pattern ~r/\A[A-Za-z0-9_-]{16}\z/
  @temp_suffix_pattern ~r/\A[A-Za-z0-9_-]{16}(?:\.[2-8])?\z/
  @reserved_temp_path_pattern ~r/\A.+\.tmp\.[A-Za-z0-9_-]{16}(?:\.[2-8])?\z/s
  @write_callbacks [mkdir_p: 1, chmod: 2, open: 2, write: 2, sync: 1, close: 1, rename: 2, remove: 1]
  @remove_callbacks [
    mkdir_p: 1,
    chmod: 2,
    open: 2,
    sync: 1,
    close: 1,
    remove: 1,
    lstat: 1,
    file_info: 1
  ]
  @directory_callbacks [mkdir_p: 1, chmod: 2, open: 2, sync: 1, close: 1]

  @type fault_stage ::
          :temp_opened
          | :temp_chmodded
          | :temp_written
          | :temp_synced
          | :temp_closed
          | :before_rename
          | :renamed
          | :parent_synced
          | :removed

  @type write_error ::
          {:pre_rename, term()}
          | {:durability_uncertain, term()}

  @spec write(Path.t(), iodata(), keyword()) :: :ok | {:error, write_error()}
  def write(path, contents, opts \\ []) do
    fs = file_system(opts)

    with :ok <- require_callbacks(fs, @write_callbacks),
         :ok <- require_temp_identity_callbacks(fs, opts),
         {:ok, content_evidence} <- temp_content_evidence(contents, opts),
         :ok <- ensure_directory(Path.dirname(path), opts),
         {:ok, temp_path, temp_identity} <-
           write_exclusive_temp(path, contents, content_evidence, opts, @temp_attempts) do
      commit_temp(temp_path, temp_identity, path, opts)
    else
      {:error, reason} -> {:error, {:pre_rename, reason}}
    end
  end

  @type remove_error ::
          {:pre_remove, term()}
          | {:durability_uncertain, term()}

  @spec remove(Path.t(), keyword()) :: :ok | {:error, remove_error()}
  def remove(path, opts \\ []) do
    fs = file_system(opts)

    with :ok <- require_callbacks(fs, @remove_callbacks),
         :ok <- ensure_directory(Path.dirname(path), opts),
         {:ok, parent_identity} <- capture_parent_identity(fs, path, :verified) do
      case fs_callback(fs, :remove, [path]) do
        :ok ->
          finish_removed(path, parent_identity, opts)

        {:error, :enoent} ->
          establish_durable_absence(path, parent_identity, opts)

        {:error, {:callback_failed, _kind} = reason} ->
          classify_failed_remove(path, parent_identity, {:remove, reason}, opts)

        {:error, reason} ->
          {:error, {:pre_remove, {:remove, reason}}}

        other ->
          classify_failed_remove(path, parent_identity, {:remove, other}, opts)
      end
    else
      {:error, reason} -> {:error, {:pre_remove, reason}}
    end
  end

  @type adopt_error ::
          {:pre_adopt, term()}
          | {:durability_uncertain, term()}

  @doc "Durably move one existing entry into an absent destination without copying or overwriting."
  @spec adopt(Path.t(), Path.t(), keyword()) :: :ok | {:error, adopt_error()}
  def adopt(source, destination, opts \\ [])

  def adopt(source, destination, opts)
      when is_binary(source) and source != "" and is_binary(destination) and destination != "" and
             is_list(opts) do
    with :ok <- validate_adoption_path(source),
         :ok <- validate_adoption_path(destination),
         {:ok, root} <- adoption_root(destination, opts),
         :ok <- ensure_adoption_file_system(opts),
         {:ok, adoption} <- adoption_prepare(source, destination, root, opts) do
      commit_adoption(adoption, source, destination, opts)
    else
      {:error, reason} -> {:error, {:pre_adopt, normalize_adoption_error(reason, source, destination)}}
    end
  end

  def adopt(_source, _destination, _opts), do: {:error, {:pre_adopt, :invalid_adoption}}

  @spec ensure_directory(Path.t(), keyword()) :: :ok | {:error, term()}
  def ensure_directory(directory, opts \\ []) do
    fs = file_system(opts)

    with :ok <- require_callbacks(fs, @directory_callbacks),
         :ok <- require_directory_root_callbacks(fs, opts),
         {:ok, chain} <- directory_chain(fs, directory, opts) do
      Enum.reduce_while(chain, :ok, fn path, :ok ->
        case create_harden_and_link(path, opts) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc false
  @spec reserved_temporary_path?(Path.t()) :: boolean()
  def reserved_temporary_path?(path) when is_binary(path),
    do: Regex.match?(@reserved_temp_path_pattern, Path.basename(path))

  def reserved_temporary_path?(_path), do: false

  @type cleanup_error :: {:orphan_temp_cleanup, term()}

  @doc """
  Remove this destination's abandoned random temporary files.

  The caller must hold the destination store's canonical path or ownership lock
  for the complete call. This function is intentionally not part of `write/3`:
  without that external exclusion, a matching file may belong to a live writer.
  """
  @spec cleanup_orphan_temps(Path.t(), keyword()) :: :ok | {:error, cleanup_error()}
  def cleanup_orphan_temps(path, opts \\ [])

  def cleanup_orphan_temps(path, opts) when is_binary(path) and path != "" and is_list(opts) do
    directory = Path.dirname(path)
    destination = Path.basename(path)
    fs = file_system(opts)

    with {:ok, filenames, directory_state} <- list_orphan_temps(fs, directory, destination) do
      fs
      |> remove_orphan_temps(directory, filenames)
      |> finish_orphan_cleanup(fs, directory, directory_state)
    end
  end

  def cleanup_orphan_temps(_path, _opts),
    do: {:error, {:orphan_temp_cleanup, :invalid_destination}}

  defp list_orphan_temps(fs, directory, destination) do
    result = cleanup_fs_call(fs, :list_dir, [directory])

    case result do
      {:ok, filenames} when is_list(filenames) ->
        {:ok,
         filenames
         |> Enum.filter(&orphan_temp?(&1, destination))
         |> Enum.sort(), :present}

      {:error, :enoent} ->
        {:ok, [], :missing}

      {:error, reason} ->
        cleanup_error({:list_directory, reason})

      other ->
        cleanup_error({:list_directory, other})
    end
  end

  defp orphan_temp?(filename, destination) when is_binary(filename) do
    prefix = destination <> ".tmp."

    if String.starts_with?(filename, prefix) do
      suffix = binary_part(filename, byte_size(prefix), byte_size(filename) - byte_size(prefix))
      Regex.match?(@temp_suffix_pattern, suffix)
    else
      false
    end
  end

  defp orphan_temp?(_filename, _destination), do: false

  defp remove_orphan_temps(fs, directory, filenames) do
    Enum.reduce_while(filenames, {:ok, false}, fn filename, {:ok, removed?} ->
      path = Path.join(directory, filename)

      case lstat_temp(fs, path) do
        {:ok, %File.Stat{type: :regular}} ->
          case cleanup_fs_call(fs, :remove, [path]) do
            :ok -> {:cont, {:ok, true}}
            {:error, reason} -> {:halt, {:error, cleanup_error({:remove_temp, reason}), true}}
            other -> {:halt, {:error, cleanup_error({:remove_temp, other}), true}}
          end

        {:ok, %File.Stat{}} ->
          {:halt, {:error, cleanup_error(:invalid_temp_type), removed?}}

        {:error, _reason} = error ->
          {:halt, {:error, error, removed?}}
      end
    end)
  end

  defp finish_orphan_cleanup({:ok, _removed?}, fs, directory, directory_state),
    do: sync_existing_cleanup_directory(fs, directory, directory_state)

  defp finish_orphan_cleanup({:error, error, false}, _fs, _directory, _directory_state), do: error

  defp finish_orphan_cleanup({:error, error, true}, fs, directory, directory_state) do
    case sync_existing_cleanup_directory(fs, directory, directory_state) do
      :ok -> error
      {:error, sync_reason} -> cleanup_error({:partial_cleanup, error, sync_reason})
    end
  end

  defp lstat_temp(fs, path) do
    case cleanup_fs_call(fs, :lstat, [path]) do
      {:ok, %File.Stat{} = stat} -> {:ok, stat}
      {:error, reason} -> cleanup_error({:lstat_temp, reason})
      other -> cleanup_error({:lstat_temp, other})
    end
  end

  defp sync_existing_cleanup_directory(_fs, _directory, :missing), do: :ok

  defp sync_existing_cleanup_directory(fs, directory, :present) do
    open_result = cleanup_fs_call(fs, :open, [directory, [:read, :raw, :directory]])

    case open_result do
      {:ok, device} ->
        sync_result = cleanup_fs_call(fs, :sync, [device])
        close_result = cleanup_fs_call(fs, :close, [device])

        case {sync_result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close_result} -> cleanup_error({:sync_directory, {:directory_sync, reason}})
          {other, _close_result} when other != :ok -> cleanup_error({:sync_directory, {:directory_sync, other}})
          {:ok, {:error, reason}} -> cleanup_error({:sync_directory, {:directory_close, reason}})
          {:ok, other} -> cleanup_error({:sync_directory, {:directory_close, other}})
        end

      {:error, reason} ->
        cleanup_error({:sync_directory, {:directory_open, reason}})

      other ->
        cleanup_error({:sync_directory, {:directory_open, other}})
    end
  end

  defp cleanup_fs_call(fs, callback, args), do: fs_callback(fs, callback, args)

  defp require_callbacks(fs, callbacks) do
    if is_atom(fs) and Code.ensure_loaded?(fs) do
      case Enum.find(callbacks, fn {callback, arity} ->
             not function_exported?(fs, callback, arity)
           end) do
        nil -> :ok
        {callback, _arity} -> {:error, {:callback_unavailable, callback}}
      end
    else
      {:error, {:callback_unavailable, :file_system}}
    end
  end

  defp require_directory_root_callbacks(fs, opts) do
    case Keyword.get(opts, :directory_root) do
      nil -> :ok
      _root -> require_callbacks(fs, lstat: 1)
    end
  end

  defp require_temp_identity_callbacks(fs, opts) do
    case Keyword.get(opts, :directory_root) do
      nil -> :ok
      _root -> require_callbacks(fs, read: 2, lstat: 1, file_info: 1)
    end
  end

  defp temp_content_evidence(_contents, opts) when not is_list(opts),
    do: {:error, :invalid_options}

  defp temp_content_evidence(contents, opts) do
    case Keyword.get(opts, :directory_root) do
      nil ->
        {:ok, :unverified}

      _root ->
        try do
          expected_contents = IO.iodata_to_binary(contents)
          {:ok, %{byte_size: byte_size(expected_contents), contents: expected_contents}}
        rescue
          _exception -> {:error, :invalid_contents}
        catch
          _kind, _reason -> {:error, :invalid_contents}
        end
    end
  end

  defp fs_callback(fs, callback, args) do
    if is_atom(fs) and Code.ensure_loaded?(fs) and function_exported?(fs, callback, length(args)) do
      safe_fs_operation(fn -> apply(fs, callback, args) end)
    else
      {:error, {:callback_unavailable, callback}}
    end
  end

  defp safe_fs_operation(operation) do
    operation.()
  rescue
    _exception -> {:error, {:callback_failed, :raise}}
  catch
    :throw, _reason -> {:error, {:callback_failed, :throw}}
    :exit, _reason -> {:error, {:callback_failed, :exit}}
  end

  defp cleanup_error(reason), do: {:error, {:orphan_temp_cleanup, reason}}

  defp commit_temp(temp_path, temp_identity, path, opts) do
    case inject_fault(:before_rename, opts) do
      :ok ->
        fs = file_system(opts)

        with :ok <- verify_temp_path_identity(fs, temp_path, temp_identity) do
          case verify_temp_contents(fs, temp_path, temp_identity) do
            :ok ->
              case capture_parent_identity(fs, path, temp_identity) do
                {:ok, parent_identity} ->
                  case rename(temp_path, path, opts) do
                    :ok ->
                      finish_renamed(path, temp_identity, parent_identity, opts)

                    {:error, {:definite, reason}} ->
                      cleanup_pre_rename(temp_path, temp_identity, reason, opts)

                    {:error, {:uncertain, reason}} ->
                      {:error, {:durability_uncertain, reason}}
                  end

                {:error, reason} ->
                  cleanup_pre_rename(temp_path, temp_identity, reason, opts)
              end

            {:error, reason} ->
              cleanup_pre_rename(temp_path, temp_identity, reason, opts)
          end
        else
          {:error, reason} -> {:error, {:pre_rename, reason}}
        end

      {:error, reason} ->
        cleanup_pre_rename(temp_path, temp_identity, reason, opts)
    end
  end

  defp finish_renamed(path, temp_identity, parent_identity, opts) do
    fs = file_system(opts)

    with :ok <- inject_fault(:renamed, opts),
         :ok <- verify_parent_path_identity(fs, path, parent_identity),
         :ok <- verify_destination_path_identity(fs, path, temp_identity),
         :ok <- verify_temp_contents(fs, path, temp_identity),
         :ok <- sync_destination_file(fs, path, temp_identity),
         :ok <- verify_temp_contents(fs, path, temp_identity),
         :ok <- sync_parent_directory(path, parent_identity, opts),
         :ok <- verify_destination_path_identity(fs, path, temp_identity),
         :ok <- verify_temp_contents(fs, path, temp_identity) do
      _durable_fault = inject_fault(:parent_synced, opts)
      :ok
    else
      {:error, reason} -> {:error, {:durability_uncertain, reason}}
    end
  end

  defp cleanup_pre_rename(temp_path, temp_identity, reason, opts) do
    fs = file_system(opts)

    with :ok <- verify_temp_path_identity(fs, temp_path, temp_identity) do
      case fs_callback(fs, :remove, [temp_path]) do
        :ok -> finish_pre_rename_cleanup(temp_path, reason, opts)
        {:error, :enoent} -> finish_pre_rename_cleanup(temp_path, reason, opts)
        other -> {:error, {:pre_rename, {reason, {:temp_cleanup, other}}}}
      end
    else
      {:error, identity_reason} ->
        {:error, {:pre_rename, {reason, {:temp_cleanup_identity, identity_reason}}}}
    end
  end

  defp finish_pre_rename_cleanup(temp_path, reason, opts) do
    case sync_parent_directory(temp_path, opts) do
      :ok ->
        {:error, {:pre_rename, reason}}

      {:error, sync_reason} ->
        {:error, {:pre_rename, {reason, {:temp_cleanup_sync, sync_reason}}}}
    end
  end

  defp finish_removed(path, parent_identity, opts) do
    with :ok <- inject_fault(:removed, opts),
         :ok <- verify_parent_path_identity(file_system(opts), path, parent_identity),
         :ok <- sync_parent_directory(path, parent_identity, opts) do
      _durable_fault = inject_fault(:parent_synced, opts)
      :ok
    else
      {:error, reason} -> {:error, {:durability_uncertain, reason}}
    end
  end

  defp establish_durable_absence(path, parent_identity, opts) do
    with :ok <- verify_parent_path_identity(file_system(opts), path, parent_identity),
         :ok <- sync_parent_directory(path, parent_identity, opts) do
      _durable_fault = inject_fault(:parent_synced, opts)
      :ok
    else
      {:error, reason} -> {:error, {:durability_uncertain, reason}}
    end
  end

  defp classify_failed_remove(path, parent_identity, reason, opts) do
    case fs_callback(file_system(opts), :lstat, [path]) do
      {:error, :enoent} -> establish_durable_absence(path, parent_identity, opts)
      {:ok, %File.Stat{}} -> {:error, {:pre_remove, reason}}
      _unknown -> {:error, {:durability_uncertain, reason}}
    end
  end

  defp directory_chain(fs, directory, opts) do
    case Keyword.get(opts, :directory_root) do
      nil ->
        {:ok, [directory]}

      root when is_binary(root) and root != "" and is_binary(directory) and directory != "" ->
        root = Path.expand(root)
        directory = Path.expand(directory)
        relative = Path.relative_to(directory, root)

        if relative == directory or relative == ".." or String.starts_with?(relative, "../") do
          {:error, {:directory_outside_root, directory, root}}
        else
          descendants =
            relative
            |> Path.split()
            |> Enum.reject(&(&1 in ["", "."]))
            |> Enum.scan(root, &Path.join(&2, &1))

          with {:ok, root_chain} <- missing_root_chain(fs, root) do
            {:ok, Enum.uniq(root_chain ++ descendants)}
          end
        end

      root ->
        {:error, {:invalid_directory_root, root}}
    end
  end

  defp missing_root_chain(fs, root) do
    parent = Path.dirname(root)

    if parent == root do
      {:ok, [root]}
    else
      case fs_callback(fs, :lstat, [parent]) do
        {:ok, %File.Stat{type: :directory}} ->
          {:ok, [root]}

        {:ok, %File.Stat{type: type}} ->
          {:error, {:invalid_directory_type, parent, type}}

        {:error, :enoent} ->
          with {:ok, ancestors} <- missing_root_chain(fs, parent) do
            {:ok, ancestors ++ [root]}
          end

        {:error, reason} ->
          {:error, {:directory_lstat, parent, reason}}

        other ->
          {:error, {:directory_lstat, parent, other}}
      end
    end
  end

  defp create_harden_and_link(directory, opts) do
    fs = file_system(opts)

    with {:ok, directory_state} <- directory_state(fs, directory, opts),
         :ok <- require_directory_creation_callbacks(fs, directory_state),
         {:ok, ownership} <- establish_directory(fs, directory, directory_state, opts),
         :ok <- validate_directory_type(fs, directory, opts, :must_exist) do
      case fs_result(fs_callback(fs, :chmod, [directory, @dir_mode]), :chmod_directory) do
        :ok ->
          case validate_hardened_directory(fs, directory, opts) do
            :ok ->
              with :ok <- sync_directory(directory, opts),
                   :ok <- sync_directory(Path.dirname(directory), opts) do
                :ok
              end

            {:error, reason} ->
              cleanup_created_directory(directory, ownership, reason, opts)
          end

        {:error, reason} ->
          cleanup_created_directory(directory, ownership, reason, opts)
      end
    end
  end

  defp establish_directory(fs, directory, :missing, opts) do
    case fs_callback(fs, :mkdir, [directory]) do
      :ok ->
        {:ok, :created}

      {:error, :eexist} ->
        with :ok <- validate_directory_type(fs, directory, opts, :must_exist) do
          {:ok, :present}
        end

      {:error, reason} ->
        {:error, {:mkdir, reason}}

      other ->
        {:error, {:mkdir, other}}
    end
  end

  defp establish_directory(_fs, _directory, :present, _opts), do: {:ok, :present}

  defp establish_directory(fs, directory, :unknown, _opts) do
    case fs_result(fs_callback(fs, :mkdir_p, [directory]), :mkdir) do
      :ok -> {:ok, :unknown}
      {:error, _reason} = error -> error
    end
  end

  defp directory_state(_fs, _directory, opts) when not is_list(opts),
    do: {:error, :invalid_options}

  defp directory_state(fs, directory, opts) do
    case Keyword.get(opts, :directory_root) do
      nil ->
        {:ok, :unknown}

      _root ->
        case fs_callback(fs, :lstat, [directory]) do
          {:ok, %File.Stat{type: :directory}} -> {:ok, :present}
          {:ok, %File.Stat{type: type}} -> {:error, {:invalid_directory_type, directory, type}}
          {:error, :enoent} -> {:ok, :missing}
          {:error, reason} -> {:error, {:directory_lstat, directory, reason}}
          other -> {:error, {:directory_lstat, directory, other}}
        end
    end
  end

  defp require_directory_creation_callbacks(fs, :missing),
    do: require_callbacks(fs, mkdir: 1, rmdir: 1)

  defp require_directory_creation_callbacks(_fs, _directory_state), do: :ok

  defp cleanup_created_directory(_directory, ownership, reason, _opts)
       when ownership != :created,
       do: {:error, reason}

  defp cleanup_created_directory(directory, :created, reason, opts) do
    fs = file_system(opts)

    case fs_callback(fs, :rmdir, [directory]) do
      :ok -> finish_created_directory_cleanup(directory, reason, opts)
      {:error, :enoent} -> finish_created_directory_cleanup(directory, reason, opts)
      other -> {:error, {reason, {:directory_cleanup, other}}}
    end
  end

  defp finish_created_directory_cleanup(directory, reason, opts) do
    case sync_directory(Path.dirname(directory), opts) do
      :ok -> {:error, reason}
      {:error, sync_reason} -> {:error, {reason, {:directory_cleanup_sync, sync_reason}}}
    end
  end

  defp validate_hardened_directory(fs, directory, opts) do
    with :ok <- validate_directory_type(fs, directory, opts, :must_exist),
         :ok <- validate_directory_mode(fs, directory, opts) do
      :ok
    end
  end

  defp validate_directory_mode(_fs, _directory, opts) when not is_list(opts),
    do: {:error, :invalid_options}

  defp validate_directory_mode(fs, directory, opts) do
    case Keyword.get(opts, :directory_root) do
      nil ->
        :ok

      _root ->
        case fs_callback(fs, :lstat, [directory]) do
          {:ok, %File.Stat{type: :directory, mode: mode}} ->
            if Bitwise.band(mode, 0o777) == @dir_mode,
              do: :ok,
              else: {:error, {:invalid_directory_mode, directory}}

          {:ok, %File.Stat{type: type}} ->
            {:error, {:invalid_directory_type, directory, type}}

          {:error, reason} ->
            {:error, {:directory_lstat, directory, reason}}

          other ->
            {:error, {:directory_lstat, directory, other}}
        end
    end
  end

  defp validate_directory_type(_fs, _directory, opts, _existence)
       when not is_list(opts),
       do: {:error, :invalid_options}

  defp validate_directory_type(fs, directory, opts, existence) do
    case Keyword.get(opts, :directory_root) do
      nil ->
        :ok

      _root ->
        case fs_callback(fs, :lstat, [directory]) do
          {:ok, %File.Stat{type: :directory}} ->
            :ok

          {:ok, %File.Stat{type: type}} ->
            {:error, {:invalid_directory_type, directory, type}}

          {:error, :enoent} when existence == :allow_missing ->
            :ok

          {:error, reason} ->
            {:error, {:directory_lstat, directory, reason}}

          other ->
            {:error, {:directory_lstat, directory, other}}
        end
    end
  end

  defp write_exclusive_temp(_path, _contents, _content_evidence, _opts, 0),
    do: {:error, {:open, :eexist}}

  defp write_exclusive_temp(path, contents, content_evidence, opts, attempts) do
    with {:ok, temp_path} <- temporary_path(path, opts, attempts) do
      case open_and_sync_temp(temp_path, contents, content_evidence, opts) do
        {:ok, temp_identity} ->
          {:ok, temp_path, temp_identity}

        {:error, {:open, :eexist}} when attempts > 1 ->
          write_exclusive_temp(path, contents, content_evidence, opts, attempts - 1)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp open_and_sync_temp(temp_path, contents, content_evidence, opts) do
    fs = file_system(opts)

    case fs_callback(fs, :open, [temp_path, [:write, :binary, :raw, :exclusive]]) do
      {:ok, device} ->
        operation_result =
          case capture_temp_identity(fs, device, temp_path, content_evidence, opts) do
            {:ok, temp_identity} ->
              result =
                with :ok <- inject_fault(:temp_opened, opts),
                     :ok <- fs_result(fs_callback(fs, :chmod, [temp_path, @file_mode]), :chmod),
                     :ok <- verify_temp_descriptor(fs, device, temp_path, temp_identity),
                     :ok <- inject_fault(:temp_chmodded, opts),
                     :ok <- fs_result(fs_callback(fs, :write, [device, contents]), :write),
                     :ok <- inject_fault(:temp_written, opts),
                     :ok <- fs_result(fs_callback(fs, :sync, [device]), :file_sync),
                     :ok <- verify_temp_descriptor(fs, device, temp_path, temp_identity),
                     :ok <- inject_fault(:temp_synced, opts) do
                  :ok
                end

              {result, temp_identity}

            {:error, reason} ->
              {{:error, reason}, :untrusted}
          end

        close_result = fs_result(fs_callback(fs, :close, [device]), :close)
        finish_temp_write(operation_result, close_result, fs, temp_path, opts)

      {:error, reason} ->
        {:error, {:open, reason}}

      other ->
        {:error, {:open, other}}
    end
  end

  defp finish_temp_write({:ok, temp_identity}, :ok, _fs, temp_path, opts) do
    case inject_fault(:temp_closed, opts) do
      :ok -> {:ok, temp_identity}
      {:error, reason} -> cleanup_failed_temp(temp_path, reason, temp_identity, opts)
    end
  end

  defp finish_temp_write({{:error, reason}, temp_identity}, _close_result, _fs, temp_path, opts),
    do: cleanup_failed_temp(temp_path, reason, temp_identity, opts)

  defp finish_temp_write({:ok, temp_identity}, {:error, reason}, _fs, temp_path, opts),
    do: cleanup_failed_temp(temp_path, reason, temp_identity, opts)

  defp cleanup_failed_temp(_temp_path, reason, :untrusted, _opts),
    do: {:error, {reason, {:temp_cleanup_identity, :untrusted}}}

  defp cleanup_failed_temp(temp_path, reason, temp_identity, opts) do
    fs = file_system(opts)

    with :ok <- verify_temp_path_identity(fs, temp_path, temp_identity) do
      case fs_callback(fs, :remove, [temp_path]) do
        :ok -> finish_failed_temp_cleanup(temp_path, reason, opts)
        {:error, :enoent} -> finish_failed_temp_cleanup(temp_path, reason, opts)
        other -> {:error, {reason, {:temp_cleanup, other}}}
      end
    else
      {:error, identity_reason} ->
        {:error, {reason, {:temp_cleanup_identity, identity_reason}}}
    end
  end

  defp finish_failed_temp_cleanup(temp_path, reason, opts) do
    case sync_parent_directory(temp_path, opts) do
      :ok -> {:error, reason}
      {:error, sync_reason} -> {:error, {reason, {:temp_cleanup_sync, sync_reason}}}
    end
  end

  defp verify_temp_descriptor(_fs, _device, _temp_path, :unverified), do: :ok

  defp verify_temp_descriptor(fs, device, temp_path, %{file_identity: expected_identity}) do
    case fs_callback(fs, :file_info, [device]) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        cond do
          file_identity(stat) != expected_identity ->
            {:error, {:temporary_file_identity_mismatch, temp_path}}

          Bitwise.band(stat.mode, 0o777) != @file_mode ->
            {:error, {:invalid_temporary_file_mode, temp_path}}

          true ->
            :ok
        end

      {:ok, %File.Stat{}} ->
        {:error, {:temporary_file_identity_mismatch, temp_path}}

      {:error, reason} ->
        {:error, {:temporary_file_info, reason}}

      other ->
        {:error, {:temporary_file_info, other}}
    end
  end

  defp capture_temp_identity(_fs, _device, _temp_path, :unverified, _opts),
    do: {:ok, :unverified}

  defp capture_temp_identity(fs, device, temp_path, content_evidence, opts) do
    case Keyword.get(opts, :directory_root) do
      nil -> {:ok, :unverified}
      _root -> capture_verified_temp_identity(fs, device, temp_path, content_evidence)
    end
  end

  defp capture_verified_temp_identity(fs, device, temp_path, content_evidence) do
    case fs_callback(fs, :file_info, [device]) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        temp_identity = Map.put(content_evidence, :file_identity, file_identity(stat))

        case verify_temp_path_identity(fs, temp_path, temp_identity) do
          :ok -> {:ok, temp_identity}
          {:error, _reason} = error -> error
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, {:invalid_temporary_file_type, type}}

      {:error, reason} ->
        {:error, {:temporary_file_info, reason}}

      other ->
        {:error, {:temporary_file_info, other}}
    end
  end

  defp verify_temp_path_identity(_fs, _temp_path, :unverified), do: :ok

  defp verify_temp_path_identity(fs, temp_path, %{file_identity: expected_identity}) do
    case fs_callback(fs, :lstat, [temp_path]) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        if file_identity(stat) == expected_identity,
          do: :ok,
          else: {:error, {:temporary_file_identity_mismatch, temp_path}}

      {:ok, %File.Stat{}} ->
        {:error, {:temporary_file_identity_mismatch, temp_path}}

      {:error, :enoent} ->
        {:error, {:temporary_file_missing, temp_path}}

      {:error, reason} ->
        {:error, {:temporary_file_lstat, temp_path, reason}}

      other ->
        {:error, {:temporary_file_lstat, temp_path, other}}
    end
  end

  defp verify_temp_contents(_fs, _temp_path, :unverified), do: :ok

  defp verify_temp_contents(fs, temp_path, temp_identity) do
    case fs_callback(fs, :open, [temp_path, [:read, :binary, :raw]]) do
      {:ok, device} ->
        verification_result =
          with :ok <- verify_temp_descriptor(fs, device, temp_path, temp_identity),
               :ok <- verify_temp_descriptor_size(fs, device, temp_path, temp_identity),
               :ok <- compare_temp_contents(fs, device, temp_path, temp_identity, 0),
               :ok <- verify_temp_descriptor(fs, device, temp_path, temp_identity),
               :ok <- verify_temp_descriptor_size(fs, device, temp_path, temp_identity) do
            :ok
          end

        close_result = fs_callback(fs, :close, [device])

        case {verification_result, close_result} do
          {:ok, :ok} -> verify_temp_path_identity(fs, temp_path, temp_identity)
          {{:error, _reason} = error, _close_result} -> error
          {:ok, {:error, reason}} -> {:error, {:temporary_file_close, reason}}
          {:ok, other} -> {:error, {:temporary_file_close, other}}
        end

      {:error, reason} ->
        {:error, {:temporary_file_open, reason}}

      other ->
        {:error, {:temporary_file_open, other}}
    end
  end

  defp sync_destination_file(_fs, _path, :unverified), do: :ok

  defp sync_destination_file(fs, path, temp_identity) do
    case fs_callback(fs, :open, [path, [:read, :binary, :raw]]) do
      {:ok, device} ->
        sync_result =
          with :ok <- verify_temp_descriptor(fs, device, path, temp_identity),
               :ok <- verify_temp_descriptor_size(fs, device, path, temp_identity),
               :ok <- fs_result(fs_callback(fs, :sync, [device]), :destination_file_sync),
               :ok <- verify_temp_descriptor(fs, device, path, temp_identity),
               :ok <- verify_temp_descriptor_size(fs, device, path, temp_identity) do
            :ok
          end

        close_result = fs_result(fs_callback(fs, :close, [device]), :destination_file_close)

        with :ok <- sync_result,
             :ok <- close_result,
             :ok <- verify_destination_path_identity(fs, path, temp_identity) do
          :ok
        end

      {:error, reason} ->
        {:error, {:destination_file_open, reason}}

      other ->
        {:error, {:destination_file_open, other}}
    end
  end

  defp verify_temp_descriptor_size(fs, device, temp_path, %{byte_size: expected_size}) do
    case fs_callback(fs, :file_info, [device]) do
      {:ok, %File.Stat{type: :regular, size: ^expected_size}} ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        {:error, {:temporary_file_content_mismatch, temp_path}}

      {:ok, %File.Stat{}} ->
        {:error, {:temporary_file_identity_mismatch, temp_path}}

      {:error, reason} ->
        {:error, {:temporary_file_info, reason}}

      other ->
        {:error, {:temporary_file_info, other}}
    end
  end

  defp compare_temp_contents(fs, device, temp_path, temp_identity, offset) do
    %{byte_size: expected_size, contents: expected_contents} = temp_identity
    remaining = expected_size - offset
    read_size = min(@temp_read_chunk_bytes, max(remaining, 1))

    case fs_callback(fs, :read, [device, read_size]) do
      :eof when offset == expected_size ->
        :ok

      :eof ->
        {:error, {:temporary_file_content_mismatch, temp_path}}

      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= read_size ->
        count = byte_size(bytes)

        if count <= remaining and binary_part(expected_contents, offset, count) == bytes do
          compare_temp_contents(fs, device, temp_path, temp_identity, offset + count)
        else
          {:error, {:temporary_file_content_mismatch, temp_path}}
        end

      {:ok, _bytes} ->
        {:error, {:temporary_file_read, :invalid_result}}

      {:error, reason} ->
        {:error, {:temporary_file_read, reason}}

      other ->
        {:error, {:temporary_file_read, other}}
    end
  end

  defp capture_parent_identity(_fs, _path, :unverified), do: {:ok, :unverified}

  defp capture_parent_identity(fs, path, _temp_identity) do
    parent = Path.dirname(path)

    case fs_callback(fs, :lstat, [parent]) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok, file_identity(stat)}

      {:ok, %File.Stat{}} ->
        {:error, {:parent_directory_identity_mismatch, parent}}

      {:error, reason} ->
        {:error, {:parent_directory_lstat, parent, reason}}

      other ->
        {:error, {:parent_directory_lstat, parent, other}}
    end
  end

  defp verify_parent_path_identity(_fs, _path, :unverified), do: :ok

  defp verify_parent_path_identity(fs, path, expected_identity),
    do: verify_directory_path_identity(fs, Path.dirname(path), expected_identity)

  defp verify_directory_path_identity(fs, directory, expected_identity) do
    case fs_callback(fs, :lstat, [directory]) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        if file_identity(stat) == expected_identity,
          do: :ok,
          else: {:error, {:parent_directory_identity_mismatch, directory}}

      {:ok, %File.Stat{}} ->
        {:error, {:parent_directory_identity_mismatch, directory}}

      {:error, _reason} ->
        {:error, {:parent_directory_identity_mismatch, directory}}

      _other ->
        {:error, {:parent_directory_identity_mismatch, directory}}
    end
  end

  defp verify_destination_path_identity(_fs, _path, :unverified), do: :ok

  defp verify_destination_path_identity(fs, path, %{file_identity: expected_identity}) do
    case fs_callback(fs, :lstat, [path]) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        if file_identity(stat) == expected_identity,
          do: :ok,
          else: {:error, {:destination_file_identity_mismatch, path}}

      {:ok, %File.Stat{}} ->
        {:error, {:destination_file_identity_mismatch, path}}

      {:error, _reason} ->
        {:error, {:destination_file_identity_mismatch, path}}

      _other ->
        {:error, {:destination_file_identity_mismatch, path}}
    end
  end

  defp file_identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}

  defp rename(source, destination, opts) do
    case fs_callback(file_system(opts), :rename, [source, destination]) do
      :ok -> :ok
      {:error, {:callback_failed, _kind} = reason} -> {:error, {:uncertain, {:rename, reason}}}
      {:error, reason} -> {:error, {:definite, {:rename, reason}}}
      other -> {:error, {:uncertain, {:rename, other}}}
    end
  end

  defp sync_parent_directory(path, opts), do: sync_directory(Path.dirname(path), opts)

  defp sync_parent_directory(path, :unverified, opts),
    do: sync_parent_directory(path, opts)

  defp sync_parent_directory(path, expected_identity, opts),
    do: sync_bound_directory(Path.dirname(path), expected_identity, opts)

  defp sync_bound_directory(directory, expected_identity, opts) do
    fs = file_system(opts)

    case fs_callback(fs, :open, [directory, [:read, :raw, :directory]]) do
      {:ok, device} ->
        verification_before =
          verify_directory_descriptor_identity(fs, device, directory, expected_identity)

        sync_result =
          case verification_before do
            :ok -> fs_result(fs_callback(fs, :sync, [device]), :directory_sync)
            {:error, _reason} = error -> error
          end

        verification_after =
          case sync_result do
            :ok -> verify_directory_descriptor_identity(fs, device, directory, expected_identity)
            {:error, _reason} = error -> error
          end

        close_result = fs_result(fs_callback(fs, :close, [device]), :directory_close)

        with :ok <- verification_before,
             :ok <- sync_result,
             :ok <- verification_after,
             :ok <- close_result,
             :ok <- verify_directory_path_identity(fs, directory, expected_identity) do
          :ok
        end

      {:error, reason} ->
        {:error, {:directory_open, reason}}

      other ->
        {:error, {:directory_open, other}}
    end
  end

  defp verify_directory_descriptor_identity(fs, device, directory, expected_identity) do
    case fs_callback(fs, :file_info, [device]) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        if file_identity(stat) == expected_identity,
          do: :ok,
          else: {:error, {:parent_directory_identity_mismatch, directory}}

      {:ok, %File.Stat{}} ->
        {:error, {:parent_directory_identity_mismatch, directory}}

      {:error, reason} ->
        {:error, {:parent_directory_info, directory, reason}}

      other ->
        {:error, {:parent_directory_info, directory, other}}
    end
  end

  defp sync_directory(directory, opts) do
    fs = file_system(opts)

    case fs_callback(fs, :open, [directory, [:read, :raw, :directory]]) do
      {:ok, device} ->
        sync_result = fs_result(fs_callback(fs, :sync, [device]), :directory_sync)
        close_result = fs_result(fs_callback(fs, :close, [device]), :directory_close)

        case {sync_result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, _reason} = error, _close_result} -> error
          {:ok, {:error, _reason} = error} -> error
        end

      {:error, reason} ->
        {:error, {:directory_open, reason}}

      other ->
        {:error, {:directory_open, other}}
    end
  end

  defp validate_adoption_path(path) do
    if Path.type(path) == :absolute and Path.expand(path) == path and
         :binary.match(path, <<0>>) == :nomatch do
      :ok
    else
      {:error, :invalid_adoption_path}
    end
  end

  defp adoption_root(destination, opts) do
    case Keyword.get(opts, :directory_root) do
      root when is_binary(root) and root != "" ->
        if Path.type(root) == :absolute and Path.expand(root) == root and
             :binary.match(root, <<0>>) == :nomatch do
          relative = Path.relative_to(destination, root)

          if relative == destination or relative == ".." or String.starts_with?(relative, "../") do
            {:error, {:directory_outside_root, destination, root}}
          else
            {:ok, root}
          end
        else
          {:error, {:invalid_directory_root, root}}
        end

      root ->
        {:error, {:invalid_directory_root, root}}
    end
  end

  defp ensure_adoption_file_system(opts) do
    case Keyword.get(opts, :file_system, FileSystem) do
      FileSystem -> :ok
      _other -> {:error, :unsupported_adoption_file_system}
    end
  end

  defp adoption_prepare(source, destination, root, opts) do
    native = Keyword.get(opts, :native, Native)

    safe_fs_operation(fn -> native.adoption_prepare(source, destination, root) end)
  end

  defp commit_adoption(adoption, source, destination, opts) do
    native = Keyword.get(opts, :native, Native)

    try do
      case inject_fault(:before_adopt, opts) do
        :ok ->
          native_fault = adoption_native_fault(opts)

          case safe_fs_operation(fn -> native.adoption_commit(adoption, native_fault) end) do
            :ok ->
              :ok

            {:error, {:adopted, :fault_injected}} ->
              {:error, adoption_fault_result(opts)}

            {:error, {:adopted, reason}} ->
              {:error, {:durability_uncertain, reason}}

            {:error, reason} ->
              {:error, {:pre_adopt, normalize_adoption_error(reason, source, destination)}}

            other ->
              {:error, {:pre_adopt, {:adoption_commit, other}}}
          end

        {:error, reason} ->
          {:error, {:pre_adopt, reason}}
      end
    after
      _ = safe_fs_operation(fn -> native.adoption_close(adoption) end)
    end
  end

  defp adoption_native_fault(opts) do
    case inject_fault(:adopted, opts) do
      :ok -> :none
      {:error, _reason} -> :after_rename
    end
  end

  defp adoption_fault_result(opts) do
    case inject_fault(:adopted, opts) do
      {:error, reason} -> {:durability_uncertain, reason}
      :ok -> {:durability_uncertain, :fault_injected}
    end
  end

  defp normalize_adoption_error(:eexist, _source, destination),
    do: {:destination_exists, destination}

  defp normalize_adoption_error(:exdev, source, destination),
    do: {:cross_device, source, destination}

  defp normalize_adoption_error(reason, _source, _destination), do: reason

  defp inject_fault(stage, opts) do
    case Keyword.get(opts, :fault_injector) do
      nil ->
        :ok

      injector when is_function(injector, 1) ->
        case injector.(stage) do
          :ok -> :ok
          {:error, reason} -> {:error, {:fault_injected, stage, reason}}
          other -> {:error, {:fault_injected, stage, {:invalid_response, other}}}
        end

      _other ->
        {:error, {:fault_injected, stage, :invalid_injector}}
    end
  rescue
    exception -> {:error, {:fault_injected, stage, {:exception, exception}}}
  catch
    kind, reason -> {:error, {:fault_injected, stage, {kind, reason}}}
  end

  defp file_system(opts), do: Keyword.get(opts, :file_system, FileSystem)

  defp fs_result(:ok, _operation), do: :ok
  defp fs_result({:error, reason}, operation), do: {:error, {operation, reason}}
  defp fs_result(other, operation), do: {:error, {operation, other}}

  defp temporary_path(path, opts, attempts_remaining) do
    suffix_fun = Keyword.get(opts, :temp_suffix, &default_temp_suffix/0)

    case safe_fs_operation(suffix_fun) do
      suffix when is_binary(suffix) ->
        if Regex.match?(@base_temp_suffix_pattern, suffix) do
          attempt = @temp_attempts - attempts_remaining + 1
          attempt_suffix = if attempt == 1, do: suffix, else: suffix <> "." <> Integer.to_string(attempt)
          {:ok, path <> ".tmp." <> attempt_suffix}
        else
          {:error, :invalid_temp_suffix}
        end

      _other ->
        {:error, :invalid_temp_suffix}
    end
  end

  defp default_temp_suffix do
    12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
