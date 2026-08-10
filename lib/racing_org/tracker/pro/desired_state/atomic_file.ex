defmodule RacingOrg.Tracker.Pro.DesiredState.AtomicFile do
  @moduledoc false

  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

  @dir_mode 0o700
  @file_mode 0o600
  @temp_attempts 8
  @temp_suffix_pattern ~r/\A[A-Za-z0-9_-]{16}(?:\.[2-8])?\z/
  @reserved_temp_path_pattern ~r/\A.+\.tmp\.[A-Za-z0-9_-]{16}(?:\.[2-8])?\z/s

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
    with :ok <- ensure_directory(Path.dirname(path), opts),
         {:ok, temp_path} <- write_exclusive_temp(path, contents, opts, @temp_attempts) do
      commit_temp(temp_path, path, opts)
    else
      {:error, reason} -> {:error, {:pre_rename, reason}}
    end
  end

  @type remove_error ::
          {:pre_remove, term()}
          | {:durability_uncertain, term()}

  @spec remove(Path.t(), keyword()) :: :ok | {:error, remove_error()}
  def remove(path, opts \\ []) do
    with :ok <- ensure_directory(Path.dirname(path), opts) do
      case file_system(opts).remove(path) do
        :ok -> finish_removed(path, opts)
        {:error, :enoent} -> establish_durable_absence(path, opts)
        {:error, reason} -> {:error, {:pre_remove, {:remove, reason}}}
        other -> {:error, {:pre_remove, {:remove, other}}}
      end
    else
      {:error, reason} -> {:error, {:pre_remove, reason}}
    end
  end

  @spec ensure_directory(Path.t(), keyword()) :: :ok | {:error, term()}
  def ensure_directory(directory, opts \\ []) do
    directory
    |> directory_chain(opts)
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case create_harden_and_link(path, opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
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

    with {:ok, filenames, directory_state} <- list_orphan_temps(fs, directory, destination),
         :ok <- remove_orphan_temps(fs, directory, filenames),
         :ok <- sync_existing_cleanup_directory(fs, directory, directory_state) do
      :ok
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
    Enum.reduce_while(filenames, :ok, fn filename, :ok ->
      path = Path.join(directory, filename)

      case lstat_temp(fs, path) do
        {:ok, %File.Stat{type: :regular}} ->
          case cleanup_fs_call(fs, :remove, [path]) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, cleanup_error({:remove_temp, reason})}
            other -> {:halt, cleanup_error({:remove_temp, other})}
          end

        {:ok, %File.Stat{}} ->
          {:halt, cleanup_error(:invalid_temp_type)}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
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

  defp cleanup_fs_call(fs, callback, args) do
    if is_atom(fs) and Code.ensure_loaded?(fs) and function_exported?(fs, callback, length(args)) do
      safe_fs_operation(fn -> apply(fs, callback, args) end)
    else
      {:error, {:callback_unavailable, callback}}
    end
  end

  defp fs_callback(fs, callback, args),
    do: safe_fs_operation(fn -> apply(fs, callback, args) end)

  defp safe_fs_operation(operation) do
    operation.()
  rescue
    _exception -> {:error, {:callback_failed, :raise}}
  catch
    :throw, _reason -> {:error, {:callback_failed, :throw}}
    :exit, _reason -> {:error, {:callback_failed, :exit}}
  end

  defp cleanup_error(reason), do: {:error, {:orphan_temp_cleanup, reason}}

  defp commit_temp(temp_path, path, opts) do
    case inject_fault(:before_rename, opts) do
      :ok ->
        case rename(temp_path, path, opts) do
          :ok -> finish_renamed(path, opts)
          {:error, reason} -> cleanup_pre_rename(temp_path, reason, opts)
        end

      {:error, reason} ->
        cleanup_pre_rename(temp_path, reason, opts)
    end
  end

  defp finish_renamed(path, opts) do
    with :ok <- inject_fault(:renamed, opts),
         :ok <- sync_parent_directory(path, opts) do
      _durable_fault = inject_fault(:parent_synced, opts)
      :ok
    else
      {:error, reason} -> {:error, {:durability_uncertain, reason}}
    end
  end

  defp cleanup_pre_rename(temp_path, reason, opts) do
    cleanup_result = file_system(opts).remove(temp_path)

    case cleanup_result do
      :ok -> {:error, {:pre_rename, reason}}
      {:error, :enoent} -> {:error, {:pre_rename, reason}}
      other -> {:error, {:pre_rename, {reason, {:temp_cleanup, other}}}}
    end
  end

  defp finish_removed(path, opts) do
    with :ok <- inject_fault(:removed, opts),
         :ok <- sync_parent_directory(path, opts) do
      _durable_fault = inject_fault(:parent_synced, opts)
      :ok
    else
      {:error, reason} -> {:error, {:durability_uncertain, reason}}
    end
  end

  defp establish_durable_absence(path, opts) do
    case sync_parent_directory(path, opts) do
      :ok ->
        _durable_fault = inject_fault(:parent_synced, opts)
        :ok

      {:error, reason} ->
        {:error, {:durability_uncertain, reason}}
    end
  end

  defp directory_chain(directory, opts) do
    case Keyword.get(opts, :directory_root) do
      nil ->
        [directory]

      root ->
        root = Path.expand(root)
        directory = Path.expand(directory)
        relative = Path.relative_to(directory, root)

        if relative == directory or relative == ".." or String.starts_with?(relative, "../") do
          [directory]
        else
          relative
          |> Path.split()
          |> Enum.reject(&(&1 in ["", "."]))
          |> Enum.scan(root, &Path.join(&2, &1))
          |> then(&[root | &1])
          |> Enum.uniq()
        end
    end
  end

  defp create_harden_and_link(directory, opts) do
    fs = file_system(opts)

    with :ok <- fs_result(fs.mkdir_p(directory), :mkdir),
         :ok <- fs_result(fs.chmod(directory, @dir_mode), :chmod_directory),
         :ok <- sync_directory(Path.dirname(directory), opts) do
      :ok
    end
  end

  defp write_exclusive_temp(_path, _contents, _opts, 0), do: {:error, {:open, :eexist}}

  defp write_exclusive_temp(path, contents, opts, attempts) do
    temp_path = temporary_path(path, opts, attempts)

    case open_and_sync_temp(temp_path, contents, opts) do
      :ok ->
        {:ok, temp_path}

      {:error, {:open, :eexist}} when attempts > 1 ->
        write_exclusive_temp(path, contents, opts, attempts - 1)

      {:error, _reason} = error ->
        error
    end
  end

  defp open_and_sync_temp(temp_path, contents, opts) do
    fs = file_system(opts)

    case fs.open(temp_path, [:write, :binary, :raw, :exclusive]) do
      {:ok, device} ->
        operation_result =
          with :ok <- inject_fault(:temp_opened, opts),
               :ok <- fs_result(fs.chmod(temp_path, @file_mode), :chmod),
               :ok <- inject_fault(:temp_chmodded, opts),
               :ok <- fs_result(fs.write(device, contents), :write),
               :ok <- inject_fault(:temp_written, opts),
               :ok <- fs_result(fs.sync(device), :file_sync),
               :ok <- inject_fault(:temp_synced, opts) do
            :ok
          end

        close_result = fs_result(fs.close(device), :close)

        result =
          case {operation_result, close_result} do
            {:ok, :ok} -> inject_fault(:temp_closed, opts)
            {{:error, _reason} = error, _close_result} -> error
            {:ok, {:error, _reason} = error} -> error
          end

        if result != :ok, do: fs.remove(temp_path)
        result

      {:error, reason} ->
        {:error, {:open, reason}}

      other ->
        {:error, {:open, other}}
    end
  end

  defp rename(source, destination, opts) do
    opts
    |> file_system()
    |> then(&fs_result(&1.rename(source, destination), :rename))
  end

  defp sync_parent_directory(path, opts), do: sync_directory(Path.dirname(path), opts)

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
    suffix = suffix_fun.()
    attempt = @temp_attempts - attempts_remaining + 1
    attempt_suffix = if attempt == 1, do: suffix, else: suffix <> "." <> Integer.to_string(attempt)
    path <> ".tmp." <> attempt_suffix
  end

  defp default_temp_suffix do
    12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
