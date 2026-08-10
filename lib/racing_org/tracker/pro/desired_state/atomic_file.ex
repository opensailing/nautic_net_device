defmodule RacingOrg.Tracker.Pro.DesiredState.AtomicFile do
  @moduledoc false

  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

  @dir_mode 0o700
  @file_mode 0o600
  @temp_attempts 8

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

    case fs.open(directory, [:read, :raw, :directory]) do
      {:ok, device} ->
        sync_result = fs_result(fs.sync(device), :directory_sync)
        close_result = fs_result(fs.close(device), :directory_close)

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
