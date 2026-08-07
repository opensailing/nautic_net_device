defmodule RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateStore do
  @moduledoc """
  Durable atomic storage for receipt-driven bootstrap state.

  The complete exact receipt/transcript bundle is encoded as one versioned Erlang term,
  written through a same-directory exclusive temporary file, fsynced, renamed, and
  followed by a parent-directory fsync. The state file is mode `0600` under a `0700`
  directory. Filesystem and durability fault hooks are injectable for host tests.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

  @format_version 1
  @filename "bootstrap_state.term"
  @legacy_marker_filename "register_marker.json"
  @dir_mode 0o700
  @file_mode 0o600

  @doc "Load the durable state; absence is the explicit uninitialized state."
  @spec load(keyword()) :: {:ok, BootstrapState.t()} | {:error, atom() | term()}
  def load(opts \\ []) do
    case file_system(opts).read(path(opts)) do
      {:ok, binary} -> decode(binary)
      {:error, :enoent} -> {:ok, %BootstrapState{}}
      {:error, reason} -> {:error, {:read, reason}}
      other -> {:error, {:read, other}}
    end
  end

  @doc "Durably replace the complete bootstrap state bundle."
  @spec save(BootstrapState.t(), keyword()) :: :ok | {:error, term()}
  def save(state, opts \\ [])

  def save(%BootstrapState{} = state, opts) do
    if BootstrapState.valid?(state) do
      durable_write(path(opts), :erlang.term_to_binary({@format_version, state}), opts)
    else
      {:error, :invalid_state}
    end
  end

  def save(_state, _opts), do: {:error, :invalid_state}

  @doc "Durably save or raise; intended for setup and explicit operator tooling."
  @spec save!(BootstrapState.t(), keyword()) :: :ok
  def save!(%BootstrapState{} = state, opts \\ []) do
    case save(state, opts) do
      :ok -> :ok
      {:error, reason} -> raise "bootstrap state persistence failed: #{inspect(reason)}"
    end
  end

  @doc "Absolute path of the bootstrap state bundle."
  @spec path(keyword()) :: Path.t()
  def path(opts \\ []), do: Path.join(base_path(opts), @filename)

  @doc "Absolute path of the legacy v1 registration marker."
  @spec legacy_marker_path(keyword()) :: Path.t()
  def legacy_marker_path(opts \\ []), do: Path.join(base_path(opts), @legacy_marker_filename)

  @doc "Read the legacy marker through the same injectable filesystem seam as state."
  @spec read_legacy_marker(keyword()) :: {:ok, binary()} | {:error, term()}
  def read_legacy_marker(opts \\ []), do: file_system(opts).read(legacy_marker_path(opts))

  @doc "Derive state-store location/filesystem options from key-store options."
  @spec opts_from_keystore(keyword()) :: keyword()
  def opts_from_keystore(keystore_opts) when is_list(keystore_opts) do
    Keyword.take(keystore_opts, [:base_path, :file_system])
  end

  @doc "Durably remove the legacy marker after a verified replacement receipt exists."
  @spec remove_legacy_marker(keyword()) :: :ok | {:error, term()}
  def remove_legacy_marker(opts \\ []) do
    marker_path = legacy_marker_path(opts)

    case file_system(opts).remove(marker_path) do
      :ok ->
        with :ok <- inject_fault(:legacy_marker_removed, opts),
             :ok <- sync_parent_directory(marker_path, opts),
             :ok <- inject_fault(:parent_synced, opts) do
          :ok
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:remove_legacy_marker, reason}}

      other ->
        {:error, {:remove_legacy_marker, other}}
    end
  end

  defp decode(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      {@format_version, %BootstrapState{} = state} ->
        state = normalize_state(state)
        if BootstrapState.valid?(state), do: {:ok, state}, else: {:error, :invalid_state}

      {version, %BootstrapState{}} when is_integer(version) ->
        {:error, :unsupported_state_version}

      _other ->
        {:error, :invalid_state}
    end
  rescue
    _exception -> {:error, :corrupt_state}
  catch
    _kind, _reason -> {:error, :corrupt_state}
  end

  defp normalize_state(%BootstrapState{} = state) do
    state
    |> Map.from_struct()
    |> then(&struct(BootstrapState, &1))
  end

  defp durable_write(destination, contents, opts) do
    temp_path = temporary_path(destination)

    result =
      with :ok <- ensure_directory(Path.dirname(destination), opts),
           :ok <- write_and_sync_temp(temp_path, contents, opts),
           :ok <- inject_fault(:before_rename, opts),
           :ok <- rename(temp_path, destination, opts),
           :ok <- inject_fault(:renamed, opts),
           :ok <- sync_parent_directory(destination, opts),
           :ok <- inject_fault(:parent_synced, opts) do
        :ok
      end

    if result != :ok do
      _ = file_system(opts).remove(temp_path)
    end

    result
  end

  defp write_and_sync_temp(temp_path, contents, opts) do
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

        case {operation_result, close_result} do
          {:ok, :ok} -> inject_fault(:temp_closed, opts)
          {{:error, _reason} = error, _close_result} -> error
          {:ok, {:error, _reason} = error} -> error
        end

      {:error, reason} ->
        {:error, {:open, reason}}

      other ->
        {:error, {:open, other}}
    end
  end

  defp ensure_directory(directory, opts) do
    fs = file_system(opts)

    with :ok <- fs_result(fs.mkdir_p(directory), :mkdir),
         :ok <- fs_result(fs.chmod(directory, @dir_mode), :chmod_directory) do
      :ok
    end
  end

  defp rename(source, destination, opts) do
    opts
    |> file_system()
    |> then(&fs_result(&1.rename(source, destination), :rename))
  end

  defp sync_parent_directory(path, opts) do
    directory = Path.dirname(path)
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

  defp fs_result(:ok, _operation), do: :ok
  defp fs_result({:error, reason}, operation), do: {:error, {operation, reason}}
  defp fs_result(other, operation), do: {:error, {operation, other}}

  defp file_system(opts), do: Keyword.get(opts, :file_system, FileSystem)
  defp base_path(opts), do: Keyword.get(opts, :base_path, KeyStore.default_base_path())

  defp temporary_path(path) do
    suffix = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    path <> ".tmp." <> suffix
  end
end
