defmodule RacingOrg.Tracker.Pro.DesiredState.RuntimeIdentity do
  @moduledoc """
  Owns the tracker incarnation identifiers used to bind desired-state traffic.

  `boot_id` is generated once per BEAM boot and retained in `:persistent_term` so
  a supervisor restart cannot create a second boot incarnation. `storage_epoch`
  is generated only when the desired-state storage root has no epoch file and is
  persisted with the same Tier-B atomic-write protocol as secure-transport keys.
  """

  use GenServer

  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

  @identifier_size 16
  @zero_identifier <<0::128>>
  @storage_epoch_filename "storage_epoch"
  @default_base_dir "/data/desired_state"
  @default_boot_term_key {__MODULE__, :boot_id}

  @type readiness :: %{boot_id: binary(), storage_epoch: binary()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @spec readiness(GenServer.server()) :: readiness()
  def readiness(server \\ __MODULE__), do: GenServer.call(server, :readiness)

  @spec boot_id(GenServer.server()) :: binary()
  def boot_id(server \\ __MODULE__), do: GenServer.call(server, :boot_id)

  @spec storage_epoch(GenServer.server()) :: binary()
  def storage_epoch(server \\ __MODULE__), do: GenServer.call(server, :storage_epoch)

  @spec storage_epoch_path(keyword()) :: Path.t()
  def storage_epoch_path(opts \\ []) do
    Path.join(base_dir(opts), @storage_epoch_filename)
  end

  @impl true
  def init(opts) do
    with {:ok, boot_id} <- load_or_create_boot_id(opts),
         {:ok, storage_epoch} <- load_or_create_storage_epoch(opts) do
      {:ok, %{boot_id: boot_id, storage_epoch: storage_epoch}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:readiness, _from, state), do: {:reply, state, state}
  def handle_call(:boot_id, _from, state), do: {:reply, state.boot_id, state}
  def handle_call(:storage_epoch, _from, state), do: {:reply, state.storage_epoch, state}

  defp load_or_create_boot_id(opts) do
    key = Keyword.get(opts, :boot_term_key, @default_boot_term_key)

    case :persistent_term.get(key, :missing) do
      :missing ->
        with {:ok, identifier} <- generate_identifier(opts) do
          :persistent_term.put(key, identifier)
          {:ok, identifier}
        end

      identifier ->
        validate_identifier(identifier)
    end
  end

  defp load_or_create_storage_epoch(opts) do
    path = storage_epoch_path(opts)
    fs = file_system(opts)

    case fs.read(path) do
      {:ok, identifier} ->
        case validate_identifier(identifier) do
          {:ok, identifier} -> {:ok, identifier}
          {:error, _reason} -> {:error, :corrupt_storage_epoch}
        end

      {:error, :enoent} ->
        with :ok <- ensure_storage_root_is_empty(opts),
             {:ok, identifier} <- generate_identifier(opts),
             :ok <- AtomicFile.write(path, identifier, atomic_opts(opts)) do
          {:ok, identifier}
        end

      {:error, reason} ->
        {:error, {:read_storage_epoch, reason}}

      other ->
        {:error, {:read_storage_epoch, other}}
    end
  end

  defp ensure_storage_root_is_empty(opts) do
    root = base_dir(opts)

    case File.ls(root) do
      {:ok, []} ->
        :ok

      {:ok, entries} ->
        if Enum.all?(entries, &atomic_temporary_artifact?/1) do
          with :ok <- remove_temporary_artifacts(root, entries, opts),
               :ok <- storage_root_empty?(root) do
            :ok
          end
        else
          {:error, :storage_epoch_missing_with_artifacts}
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:list_storage_root, reason}}
    end
  end

  defp storage_root_empty?(root) do
    case File.ls(root) do
      {:ok, []} -> :ok
      {:ok, _entries} -> {:error, :storage_epoch_missing_with_artifacts}
      {:error, reason} -> {:error, {:list_storage_root, reason}}
    end
  end

  defp remove_temporary_artifacts(root, entries, opts) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case AtomicFile.remove(Path.join(root, entry), atomic_opts(opts)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:remove_temporary_artifact, reason}}}
      end
    end)
  end

  defp atomic_temporary_artifact?(entry) when is_binary(entry) do
    case :binary.split(entry, ".tmp.") do
      [destination, suffix] -> byte_size(destination) > 0 and byte_size(suffix) > 0
      _other -> false
    end
  end

  defp atomic_temporary_artifact?(_entry), do: false

  defp generate_identifier(opts) do
    entropy = Keyword.get(opts, :entropy, &:crypto.strong_rand_bytes/1)

    case entropy.(@identifier_size) do
      <<identifier::binary-size(@identifier_size)>> -> validate_identifier(identifier)
      _other -> {:error, :invalid_entropy}
    end
  rescue
    _exception -> {:error, :invalid_entropy}
  catch
    _kind, _reason -> {:error, :invalid_entropy}
  end

  defp validate_identifier(@zero_identifier), do: {:error, :zero_identifier}

  defp validate_identifier(<<identifier::binary-size(@identifier_size)>>),
    do: {:ok, identifier}

  defp validate_identifier(_identifier), do: {:error, :invalid_entropy}

  defp base_dir(opts) do
    Keyword.get(opts, :base_dir) ||
      Application.get_env(:racing_org_tracker_pro, :desired_state_directory) ||
      @default_base_dir
  end

  defp file_system(opts), do: Keyword.get(opts, :file_system, FileSystem)

  defp atomic_opts(opts) do
    opts
    |> Keyword.take([:file_system, :fault_injector, :temp_suffix])
    |> Keyword.put(:directory_root, base_dir(opts))
  end
end
