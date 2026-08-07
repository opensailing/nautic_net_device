defmodule RacingOrg.Tracker.Pro.SecureTransport.KeyStore do
  @moduledoc """
  Durable storage for the device's active and staged Ed25519 identity seeds.

  Operational callers use an `IdentityProvider` handle for public key, fingerprint,
  and signing operations. The handle contains only a non-secret seed-file path and the
  expected public identity; private seed bytes are read only inside a signing call.
  The active seed remains at
  `device_ed25519.key`; recovery candidates are durably staged in a separate file and
  never replace the last active seed until `promote_candidate/1` is explicitly called
  after the server receipt has been verified.

  Every seed write uses a same-directory exclusive temporary file, applies `0600`
  before writing secret bytes, fsyncs the file, closes it, atomically renames it, and
  fsyncs the parent directory. Filesystem operations and durability-boundary fault
  injection are configurable for host tests.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider.FileSeed
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives

  @type identity :: IdentityProvider.t()
  @type fault_stage ::
          :temp_opened
          | :temp_chmodded
          | :temp_written
          | :temp_synced
          | :temp_closed
          | :before_rename
          | :renamed
          | :parent_synced
          | :candidate_removed

  @default_base_path "/data/secure_transport"
  @key_filename "device_ed25519.key"
  @candidate_key_filename "device_ed25519.candidate.key"
  @seed_size 32
  @dir_mode 0o700
  @file_mode 0o600

  @doc "The default base path for device identity seed files."
  @spec default_base_path() :: String.t()
  def default_base_path, do: @default_base_path

  @doc "Load the active identity, generating and durably persisting it on first use."
  @spec load_or_generate(keyword()) :: {:ok, identity()} | {:error, term()}
  def load_or_generate(opts \\ []) do
    path = key_path(opts)

    case read_seed(path, opts) do
      {:ok, seed} -> identity_from_seed(path, seed, opts)
      {:error, :enoent} -> generate_and_persist(path, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc "Load the existing active identity without generating one."
  @spec load(keyword()) :: {:ok, identity()} | {:error, term()}
  def load(opts \\ []) do
    path = key_path(opts)

    case read_seed(path, opts) do
      {:ok, seed} -> identity_from_seed(path, seed, opts)
      {:error, :enoent} -> {:error, :not_provisioned}
      {:error, _reason} = error -> error
    end
  end

  @doc "Load the staged recovery candidate without changing the active identity."
  @spec load_candidate(keyword()) :: {:ok, identity()} | {:error, term()}
  def load_candidate(opts \\ []) do
    path = candidate_key_path(opts)

    case read_seed(path, opts) do
      {:ok, seed} -> identity_from_seed(path, seed, opts)
      {:error, :enoent} -> {:error, :candidate_not_staged}
      {:error, _reason} = error -> error
    end
  end

  @doc "Generate and durably stage a recovery candidate, reusing one already staged."
  @spec stage_candidate(keyword()) :: {:ok, identity()} | {:error, term()}
  def stage_candidate(opts \\ []) do
    path = candidate_key_path(opts)

    case read_seed(path, opts) do
      {:ok, seed} -> identity_from_seed(path, seed, opts)
      {:error, :enoent} -> generate_and_persist(path, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Atomically promote the staged candidate to the active identity.

  This is the sole operation that replaces the active seed. Recovery orchestration
  must call it only after verifying the committed server receipt for this candidate.
  """
  @spec promote_candidate(keyword()) :: {:ok, identity()} | {:error, term()}
  def promote_candidate(opts \\ []) do
    candidate_path = candidate_key_path(opts)

    active_path = key_path(opts)

    with {:ok, seed} <- read_candidate_seed(candidate_path, opts),
         :ok <- durable_rename(candidate_path, active_path, opts),
         {:ok, identity} <- identity_from_seed(active_path, seed, opts) do
      {:ok, identity}
    end
  end

  @doc "Durably discard a staged candidate without changing the active identity."
  @spec discard_candidate(keyword()) :: :ok | {:error, term()}
  def discard_candidate(opts \\ []) do
    path = candidate_key_path(opts)
    file_system = file_system(opts)

    case file_system.remove(path) do
      :ok ->
        with :ok <- inject_fault(:candidate_removed, opts),
             :ok <- sync_parent_directory(path, opts),
             :ok <- inject_fault(:parent_synced, opts) do
          :ok
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:remove, reason}}

      other ->
        {:error, {:remove, other}}
    end
  end

  @doc "Canonical lowercase hexadecimal SHA-256 fingerprint of a raw Ed25519 public key."
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(public_key), do: IdentityProvider.fingerprint_for_public_key(public_key)

  @doc "Absolute path of the active identity seed file."
  @spec key_path(keyword()) :: String.t()
  def key_path(opts \\ []), do: Path.join(base_path(opts), @key_filename)

  @doc "Absolute path of the staged recovery-candidate seed file."
  @spec candidate_key_path(keyword()) :: String.t()
  def candidate_key_path(opts \\ []), do: Path.join(base_path(opts), @candidate_key_filename)

  defp base_path(opts) do
    Keyword.get(opts, :base_path) || configured_base_path() || @default_base_path
  end

  defp configured_base_path do
    :racing_org_tracker_pro
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:base_path)
  end

  defp file_system(opts), do: Keyword.get(opts, :file_system, FileSystem)

  defp read_candidate_seed(path, opts) do
    case read_seed(path, opts) do
      {:error, :enoent} -> {:error, :candidate_not_staged}
      result -> result
    end
  end

  defp read_seed(path, opts) do
    case file_system(opts).read(path) do
      {:ok, <<seed::binary-size(@seed_size)>>} -> {:ok, seed}
      {:ok, _other} -> {:error, :corrupt_seed}
      {:error, :enoent} -> {:error, :enoent}
      {:error, reason} -> {:error, {:read, reason}}
      other -> {:error, {:read, other}}
    end
  end

  defp generate_and_persist(path, opts) do
    with {:ok, seed} <- generate_seed(opts),
         :ok <- durable_write(path, seed, opts),
         {:ok, identity} <- identity_from_seed(path, seed, opts) do
      {:ok, identity}
    end
  end

  defp identity_from_seed(path, seed, opts) do
    public_key = Primitives.ed25519_public_from_secret(seed)
    FileSeed.from_path(path, public_key, file_system: file_system(opts))
  end

  defp generate_seed(opts) do
    generator = Keyword.get(opts, :seed_generator, &default_seed_generator/0)

    case generator.() do
      <<seed::binary-size(@seed_size)>> ->
        {:ok, seed}

      {<<public_key::binary-size(@seed_size)>>, <<seed::binary-size(@seed_size)>>} ->
        if Primitives.secure_compare(public_key, Primitives.ed25519_public_from_secret(seed)) do
          {:ok, seed}
        else
          {:error, :generated_keypair_mismatch}
        end

      _other ->
        {:error, :invalid_generated_seed}
    end
  rescue
    exception -> {:error, {:seed_generation_failed, exception}}
  catch
    kind, reason -> {:error, {:seed_generation_failed, kind, reason}}
  end

  defp default_seed_generator do
    {_public_key, seed} = Primitives.generate_identity_keypair()
    seed
  end

  defp durable_write(path, contents, opts) do
    temp_path = temporary_path(path)

    result =
      with :ok <- ensure_directory(Path.dirname(path), opts),
           :ok <- write_and_sync_temp(temp_path, contents, opts),
           :ok <- inject_fault(:before_rename, opts),
           :ok <- rename(temp_path, path, opts),
           :ok <- inject_fault(:renamed, opts),
           :ok <- sync_parent_directory(path, opts),
           :ok <- inject_fault(:parent_synced, opts) do
        :ok
      end

    if result != :ok do
      _ = file_system(opts).remove(temp_path)
    end

    result
  end

  defp durable_rename(source, destination, opts) do
    with :ok <- inject_fault(:before_rename, opts),
         :ok <- rename(source, destination, opts),
         :ok <- inject_fault(:renamed, opts),
         :ok <- sync_parent_directory(destination, opts),
         :ok <- inject_fault(:parent_synced, opts) do
      :ok
    end
  end

  defp write_and_sync_temp(temp_path, contents, opts) do
    file_system = file_system(opts)

    case file_system.open(temp_path, [:write, :binary, :raw, :exclusive]) do
      {:ok, device} ->
        operation_result =
          with :ok <- inject_fault(:temp_opened, opts),
               :ok <- fs_result(file_system.chmod(temp_path, @file_mode), :chmod),
               :ok <- inject_fault(:temp_chmodded, opts),
               :ok <- fs_result(file_system.write(device, contents), :write),
               :ok <- inject_fault(:temp_written, opts),
               :ok <- fs_result(file_system.sync(device), :file_sync),
               :ok <- inject_fault(:temp_synced, opts) do
            :ok
          end

        close_result = fs_result(file_system.close(device), :close)

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
    file_system = file_system(opts)

    with :ok <- fs_result(file_system.mkdir_p(directory), :mkdir),
         :ok <- fs_result(file_system.chmod(directory, @dir_mode), :chmod_directory) do
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
    file_system = file_system(opts)

    case file_system.open(directory, [:read, :raw, :directory]) do
      {:ok, device} ->
        sync_result = fs_result(file_system.sync(device), :directory_sync)
        close_result = fs_result(file_system.close(device), :directory_close)

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

  defp temporary_path(path) do
    suffix = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    path <> ".tmp." <> suffix
  end
end
