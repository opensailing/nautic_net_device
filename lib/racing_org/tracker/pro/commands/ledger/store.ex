defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Store do
  @moduledoc """
  Single-writer durable command-ledger state backed by one atomic snapshot.

  Every successful mutation replaces and fsyncs the complete bounded snapshot.
  If an atomic write reports an error after rename may have happened, the exact
  snapshot is read back as authority before success or failure is reported.
  """

  alias RacingOrg.Tracker.Pro.Commands.Ledger.Snapshot
  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

  @enforce_keys [
    :path,
    :snapshot,
    :max_outcomes,
    :max_result_bytes,
    :file_system,
    :atomic_opts
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          path: Path.t(),
          snapshot: Snapshot.t(),
          max_outcomes: pos_integer(),
          max_result_bytes: pos_integer(),
          file_system: module(),
          atomic_opts: keyword()
        }

  @doc "Open an exact identity-scoped ledger, durably creating its initial snapshot only when absent."
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, store} <- new_store(path, opts) do
      case read_snapshot(store) do
        {:ok, snapshot} -> open_existing(store, snapshot)
        {:error, :enoent} -> initialize(store)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def open(_path, _opts), do: {:error, :invalid_command_ledger_options}

  @doc "Return the current in-memory view of the authoritative durable snapshot."
  @spec snapshot(t()) :: Snapshot.t()
  def snapshot(%__MODULE__{snapshot: snapshot}), do: snapshot

  @doc "Return retained outcome count and exact aggregate result bytes."
  @spec usage(t()) :: %{outcomes: non_neg_integer(), result_bytes: non_neg_integer()}
  def usage(%__MODULE__{snapshot: snapshot}) do
    %{outcomes: map_size(snapshot.outcomes), result_bytes: Snapshot.result_bytes(snapshot)}
  end

  @doc "Return the configured count and aggregate-result-byte budgets."
  @spec limits(t()) :: %{max_outcomes: pos_integer(), max_result_bytes: pos_integer()}
  def limits(%__MODULE__{} = store) do
    %{max_outcomes: store.max_outcomes, max_result_bytes: store.max_result_bytes}
  end

  defp new_store(path, opts) do
    with {:ok, identity} <- identity(opts),
         {:ok, max_outcomes} <- positive_option(opts, :max_outcomes),
         {:ok, max_result_bytes} <- positive_option(opts, :max_result_bytes),
         {:ok, file_system} <- file_system(opts),
         {:ok, snapshot} <- Snapshot.new(identity) do
      expanded_path = Path.expand(path)

      atomic_opts =
        opts
        |> Keyword.take([:fault_injector, :temp_suffix])
        |> Keyword.put(:file_system, file_system)
        |> Keyword.put(:directory_root, Path.dirname(expanded_path))

      {:ok,
       %__MODULE__{
         path: expanded_path,
         snapshot: snapshot,
         max_outcomes: max_outcomes,
         max_result_bytes: max_result_bytes,
         file_system: file_system,
         atomic_opts: atomic_opts
       }}
    end
  end

  defp identity(opts) do
    identity = Map.new([:device_id, :credential_epoch, :storage_epoch], &{&1, Keyword.get(opts, &1)})

    case Snapshot.new(identity) do
      {:ok, _snapshot} -> {:ok, identity}
      {:error, _reason} -> {:error, :invalid_command_ledger_identity}
    end
  end

  defp positive_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {:invalid_command_ledger_option, key}}
    end
  end

  defp file_system(opts) do
    case Keyword.get(opts, :file_system, FileSystem) do
      module when is_atom(module) -> {:ok, module}
      _other -> {:error, {:invalid_command_ledger_option, :file_system}}
    end
  end

  defp initialize(store) do
    case persist_snapshot(store, store.snapshot) do
      {:ok, initialized} -> {:ok, initialized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_existing(store, snapshot) do
    with :ok <- exact_identity(store.snapshot, snapshot),
         :ok <- within_capacity(store, snapshot) do
      {:ok, %{store | snapshot: snapshot}}
    end
  end

  defp exact_identity(expected, actual) do
    if actual.device_id == expected.device_id and
         actual.credential_epoch == expected.credential_epoch and
         actual.storage_epoch == expected.storage_epoch do
      :ok
    else
      {:error, :command_ledger_identity_mismatch}
    end
  end

  defp within_capacity(store, snapshot) do
    cond do
      map_size(snapshot.outcomes) > store.max_outcomes ->
        {:error, :command_ledger_capacity_exceeded}

      Snapshot.result_bytes(snapshot) > store.max_result_bytes ->
        {:error, :command_ledger_capacity_exceeded}

      true ->
        :ok
    end
  end

  defp read_snapshot(store) do
    case store.file_system.read(store.path) do
      {:ok, bytes} -> Snapshot.decode(bytes)
      {:error, :enoent} -> {:error, :enoent}
      {:error, reason} -> {:error, {:read_command_ledger, reason}}
      other -> {:error, {:read_command_ledger, other}}
    end
  end

  defp persist_snapshot(store, snapshot) do
    with {:ok, bytes} <- Snapshot.encode(snapshot) do
      case AtomicFile.write(store.path, bytes, store.atomic_opts) do
        :ok ->
          {:ok, %{store | snapshot: snapshot}}

        {:error, _reason} = write_error ->
          reconcile_ambiguous_write(store, snapshot, write_error)
      end
    end
  end

  defp reconcile_ambiguous_write(store, intended, write_error) do
    case read_snapshot(store) do
      {:ok, ^intended} ->
        {:ok, %{store | snapshot: intended}}

      {:ok, _other} ->
        {:error, wrap_write_error(write_error)}

      {:error, :enoent} ->
        {:error, wrap_write_error(write_error)}

      {:error, read_error} ->
        {:error, {:command_ledger_authority_indeterminate, wrap_write_error(write_error), read_error}}
    end
  end

  defp wrap_write_error({:error, reason}), do: {:write_command_ledger, reason}
end
