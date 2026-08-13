defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Store.FileSystem do
  @moduledoc """
  The checkpoint store's injectable filesystem surface.

  The committed key-store adapter predates the bounded descriptor reads and
  canonical-path operations required here. Keeping this adapter checkpoint-local
  avoids expanding that shared API while exposing only the callbacks used by the
  store and by `AtomicFile.write/3` / `cleanup_orphan_temps/2`.
  """

  @type device :: term()
  @type modes :: [atom()]
  @type file_error ::
          File.posix() | :badarg | :terminated | {:no_translation, :unicode, :latin1}

  @callback read(Path.t()) :: {:ok, binary()} | {:error, File.posix()}
  @callback read(device(), non_neg_integer()) ::
              {:ok, binary()} | :eof | {:error, file_error()}
  @callback file_info(device()) :: {:ok, File.Stat.t()} | {:error, File.posix() | :badarg}
  @callback list_dir(Path.t()) :: {:ok, [binary()]} | {:error, File.posix()}
  @callback lstat(Path.t()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  @callback read_link(Path.t()) :: {:ok, binary()} | {:error, File.posix()}
  @callback mkdir_p(Path.t()) :: :ok | {:error, File.posix()}
  @callback mkdir(Path.t()) :: :ok | {:error, File.posix()}
  @callback chmod(Path.t(), non_neg_integer()) :: :ok | {:error, File.posix()}
  @callback open(Path.t(), modes()) :: {:ok, device()} | {:error, File.posix()}
  @callback write(device(), iodata()) :: :ok | {:error, File.posix()}
  @callback sync(device()) :: :ok | {:error, File.posix()}
  @callback close(device()) :: :ok | {:error, File.posix()}
  @callback rename(Path.t(), Path.t()) :: :ok | {:error, File.posix()}
  @callback remove(Path.t()) :: :ok | {:error, File.posix()}
  @callback rmdir(Path.t()) :: :ok | {:error, File.posix()}

  @optional_callbacks read: 1,
                      read: 2,
                      file_info: 1,
                      list_dir: 1,
                      lstat: 1,
                      read_link: 1,
                      mkdir: 1,
                      rmdir: 1

  def read(path), do: File.read(path)
  def read(device, count), do: :file.read(device, count)

  def file_info(device) do
    with {:ok, info} <- :file.read_file_info(device) do
      {:ok, File.Stat.from_record(info)}
    end
  end

  def list_dir(path), do: File.ls(path)
  def lstat(path), do: File.lstat(path)
  def read_link(path), do: File.read_link(path)
  def mkdir_p(path), do: File.mkdir_p(path)
  def mkdir(path), do: File.mkdir(path)
  def chmod(path, mode), do: File.chmod(path, mode)
  def open(path, modes), do: File.open(path, modes)
  def write(device, contents), do: :file.write(device, contents)
  def sync(device), do: :file.sync(device)
  def close(device), do: :file.close(device)
  def rename(source, destination), do: File.rename(source, destination)
  def remove(path), do: File.rm(path)
  def rmdir(path), do: File.rmdir(path)
end

defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Store do
  @moduledoc """
  Durable per-kind checkpoint heads with serialized record-hash compare-and-swap.

  Each persisted format-v3 file is a self-verifying snapshot containing the
  current record, the last backend-accepted record summary, and a bounded ordered
  ancestry chain. Keeping that evidence through later local records prevents
  delayed hydration from rolling the chain behind an acceptance that was already
  observed. Legacy ancestry that cannot be proven is retained as `:unknown` and
  fails closed until authoritative hydration establishes a safe continuation.

  Mutations are serialized by the physical identity of the prepared destination
  directory plus the fixed head filename across cooperative checkpoint writers in
  the tracker VM. Lexical, symlink, case-folding, and Unicode-normalizing aliases
  therefore share one owner according to the host filesystem while distinct
  destinations remain independent. Lock acquisition and filesystem reads are
  bounded, owner death cancels their workers, and same-process callback reentry
  fails closed. Pathname-only filesystem operations do not claim isolation from a
  same-UID process that bypasses this lock; that stronger boundary requires
  descriptor-relative filesystem primitives.

  Every mutation executes inside an injected current-identity authority lease.
  The lease spans the complete read/reconcile/write/rename/parent-sync transition,
  so identity rotation queues behind an in-flight durable mutation and a stale
  handle cannot commit after its authority has changed. An authority provider must
  own the lease synchronously in the callback process and monitor that owner: if
  the owner exits or is killed by the transition deadline, the provider must cancel
  or release the lease before allowing a rotation or another holder to proceed.
  """

  alias RacingOrg.Tracker.Pro.DesiredState.{AtomicFile, OwnerResolver}
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.{Record, Snapshot}
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Store.FileSystem

  @directory "checkpoint_heads"
  @u32_max 0xFFFF_FFFF
  @storage_epoch_size 16
  @device_id_size 16
  @read_chunk_size 16_384
  @max_encoded_size Snapshot.max_encoded_size()
  @lock_wait_ms 1_000
  @lock_retry_ms 2
  @default_transition_timeout_ms 30_000
  @max_transition_timeout_ms 300_000
  @symlink_limit 32
  @path_lock_attempts 8
  @read_retry_count 2
  @read_timeout_ms 1_000
  @corrupt_head_domain "RacingOrg-TrackerCheckpointCorruptHead-v1"

  @put_keys [:kind, :schema_version, :sequence, :source_generation, :parent_hash, :content]

  @hydrate_keys [
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :origin_credential_epoch,
    :origin_storage_epoch,
    :kind,
    :schema_version,
    :sequence,
    :source_generation,
    :parent_hash,
    :content,
    :checkpoint_hash
  ]

  @identity_keys [:device_id, :credential_epoch, :storage_epoch]
  @expected_head_keys [:state, :checkpoint_hash]
  @expected_head_states [:absent, :accepted, :local_unaccepted, :fenced, :corrupt]
  @required_bounded_callbacks [lstat: 1, open: 2, file_info: 1, read: 2, close: 1]

  @enforce_keys [
    :base_dir,
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :identity_source,
    :file_system,
    :transition_timeout_ms
  ]
  defstruct @enforce_keys ++ [:fault_injector, :temp_suffix]

  @type t :: %__MODULE__{
          base_dir: Path.t(),
          device_id: <<_::128>>,
          credential_epoch: non_neg_integer(),
          storage_epoch: <<_::128>>,
          identity_source: ((map() -> term()) -> term()),
          file_system: module(),
          transition_timeout_ms: pos_integer(),
          fault_injector: (atom() -> :ok | {:error, term()}) | nil,
          temp_suffix: (-> binary()) | nil
        }

  @type status :: %{
          kinds: non_neg_integer(),
          present: non_neg_integer(),
          accepted: non_neg_integer(),
          corrupt: non_neg_integer(),
          fenced: non_neg_integer(),
          unavailable: non_neg_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) when is_list(opts) do
    with {:ok, base_dir} <- base_dir(Keyword.get(opts, :base_dir)),
         {:ok, device_id} <- device_id(Keyword.get(opts, :device_id)),
         {:ok, credential_epoch} <- credential_epoch(Keyword.get(opts, :credential_epoch)),
         {:ok, storage_epoch} <- storage_epoch(Keyword.get(opts, :storage_epoch)),
         {:ok, identity_source} <- identity_source(opts),
         {:ok, transition_timeout_ms} <-
           transition_timeout_ms(Keyword.get(opts, :transition_timeout_ms, @default_transition_timeout_ms)) do
      store = %__MODULE__{
        base_dir: base_dir,
        device_id: device_id,
        credential_epoch: credential_epoch,
        storage_epoch: storage_epoch,
        identity_source: identity_source,
        file_system: Keyword.get(opts, :file_system, FileSystem),
        transition_timeout_ms: transition_timeout_ms,
        fault_injector: Keyword.get(opts, :fault_injector),
        temp_suffix: Keyword.get(opts, :temp_suffix)
      }

      with_bounded_authority(store, fn -> {:ok, store} end)
    end
  end

  def new(_opts), do: {:error, :invalid_options}

  @spec head(t(), atom()) :: {:ok, Record.t()} | :empty | {:error, term()}
  def head(%__MODULE__{} = store, kind) do
    with {:ok, kind} <- known_kind(kind) do
      with_bounded_authority(store, fn -> read_head(store, kind) end)
    end
  end

  @doc "Observe the exact target-head state and digest consumed by `hydrate/3` CAS."
  @spec observe_target_head(t(), atom()) ::
          {:ok, %{state: atom(), checkpoint_hash: <<_::256>>}} | {:error, term()}
  def observe_target_head(%__MODULE__{} = store, kind) do
    with {:ok, kind} <- known_kind(kind) do
      with_bounded_authority(store, fn ->
        with_kind_lock(store, kind, fn ->
          case observe_target_head_snapshot(store, kind) do
            {:ok, observed_head, _snapshot} -> {:ok, observed_head}
            {:error, _reason} = error -> error
          end
        end)
      end)
    end
  end

  defp read_head(store, kind) do
    with {:ok, snapshot} <- read_snapshot(store, kind),
         :ok <- fence_record(store, snapshot.current) do
      {:ok, snapshot.current}
    else
      :empty -> :empty
      {:error, _reason} = error -> error
    end
  end

  @spec put(t(), map()) :: {:ok, Record.t()} | {:error, term()}
  def put(%__MODULE__{} = store, attrs) when is_map(attrs) do
    with :ok <- exact_keys(attrs, @put_keys, :invalid_checkpoint_record),
         {:ok, kind} <- known_kind(attrs.kind),
         {:ok, record} <- build_local(store, attrs) do
      with_kind_lock(store, kind, fn -> put_locked(store, kind, record) end)
    end
  end

  def put(%__MODULE__{}, _attrs), do: {:error, :invalid_checkpoint_record}

  @spec hydrate(t(), map()) :: {:ok, Record.t()} | {:error, term()}
  def hydrate(%__MODULE__{} = store, attrs) when is_map(attrs),
    do: hydrate_with_expected(store, attrs, :legacy)

  def hydrate(%__MODULE__{}, _attrs), do: {:error, :invalid_checkpoint_record}

  @doc """
  Hydrate only if the exact discovered target-head state and digest still hold.

  A retry after a durability-uncertain result re-enters the same destination lock
  and identity-authority lease. It either rechecks the expected target state or
  proves that the exact delivered record is already the current record or a retained
  ancestor under the same durable identity. Success still requires an `AtomicFile`
  rewrite plus parent-directory sync, and a descendant is preserved rather than
  rolled back. Terminal accepted results may therefore be replayed without weakening
  the CAS.
  """
  @spec hydrate(t(), map(), map()) :: {:ok, Record.t()} | {:error, term()}
  def hydrate(%__MODULE__{} = store, attrs, expected_head)
      when is_map(attrs) and is_map(expected_head) do
    with {:ok, expected_head} <- validate_expected_head(expected_head) do
      hydrate_with_expected(store, attrs, expected_head)
    end
  end

  def hydrate(%__MODULE__{}, attrs, _expected_head) when not is_map(attrs),
    do: {:error, :invalid_checkpoint_record}

  def hydrate(%__MODULE__{}, _attrs, _expected_head),
    do: {:error, :invalid_expected_target_head}

  defp hydrate_with_expected(store, attrs, expected_head) do
    with :ok <- exact_keys(attrs, @hydrate_keys, :invalid_checkpoint_record),
         {:ok, kind} <- known_kind(attrs.kind),
         :ok <- match_addressed_identity(store, attrs),
         {:ok, record} <- build_hydrated(store, attrs),
         :ok <- match_presented_hash(record, attrs) do
      with_kind_lock(store, kind, fn -> hydrate_locked(store, kind, record, expected_head) end)
    end
  end

  @spec head_path(t(), atom()) :: Path.t()
  def head_path(%__MODULE__{} = store, kind) when is_atom(kind) do
    Path.join([store.base_dir, @directory, Atom.to_string(kind) <> ".head"])
  end

  @spec status(t()) :: status()
  def status(%__MODULE__{} = store) do
    case with_bounded_authority(store, fn -> read_status(store) end) do
      %{} = status ->
        status

      {:error, reason}
      when reason in [:device_mismatch, :credential_epoch_mismatch, :storage_epoch_mismatch] ->
        %{empty_status() | fenced: checkpoint_kind_count()}

      {:error, _reason} ->
        %{empty_status() | unavailable: checkpoint_kind_count()}
    end
  end

  defp read_status(store) do
    Enum.reduce(Contract.checkpoint_kinds(), empty_status(), fn {kind, _code, _schema}, acc ->
      case read_snapshot(store, kind) do
        {:ok, snapshot} ->
          status_for_snapshot(store, snapshot, acc)

        :empty ->
          acc

        {:error, :corrupt_checkpoint_head} ->
          %{acc | corrupt: acc.corrupt + 1}

        {:error, {:checkpoint_head_io, _reason}} ->
          %{acc | unavailable: acc.unavailable + 1}

        {:error, :checkpoint_head_bounded_read_unsupported} ->
          %{acc | unavailable: acc.unavailable + 1}

        {:error, _reason} ->
          %{acc | fenced: acc.fenced + 1}
      end
    end)
  end

  defp empty_status do
    %{
      kinds: checkpoint_kind_count(),
      present: 0,
      accepted: 0,
      corrupt: 0,
      fenced: 0,
      unavailable: 0
    }
  end

  defp checkpoint_kind_count, do: length(Contract.checkpoint_kinds())

  defp status_for_snapshot(store, snapshot, acc) do
    case fence_record(store, snapshot.current) do
      :ok ->
        accepted = if is_map(snapshot.last_accepted), do: 1, else: 0
        %{acc | present: acc.present + 1, accepted: acc.accepted + accepted}

      {:error, _reason} ->
        %{acc | fenced: acc.fenced + 1}
    end
  end

  defp put_locked(store, kind, record) do
    case read_snapshot(store, kind) do
      :empty -> put_first(store, kind, record)
      {:ok, snapshot} -> swap(store, kind, record, snapshot)
      {:error, _reason} = error -> error
    end
  end

  defp put_first(store, kind, record) do
    if secure_equal(record.parent_hash, Record.genesis_parent()) do
      with {:ok, snapshot} <- Snapshot.build(record, nil),
           :ok <- write_snapshot(store, kind, snapshot) do
        {:ok, record}
      end
    else
      {:error, :checkpoint_parent_mismatch}
    end
  end

  defp swap(store, kind, record, snapshot) do
    current = snapshot.current

    with :ok <- fence_record(store, current) do
      cond do
        secure_equal(record.checkpoint_hash, current.checkpoint_hash) ->
          rewrite_current(store, kind, snapshot)

        Snapshot.accepted_ancestor?(snapshot, record.checkpoint_hash) ->
          rewrite_current(store, kind, snapshot)

        not secure_equal(record.parent_hash, current.checkpoint_hash) ->
          {:error, :checkpoint_parent_mismatch}

        true ->
          with {:ok, successor} <- Snapshot.successor(snapshot, record),
               :ok <- write_snapshot(store, kind, successor) do
            {:ok, record}
          end
      end
    end
  end

  defp hydrate_locked(store, kind, record, :legacy) do
    case read_snapshot(store, kind) do
      :empty -> install_accepted(store, kind, record)
      {:ok, snapshot} -> reconcile_hydration(store, kind, record, snapshot)
      {:error, :corrupt_checkpoint_head} -> {:error, :checkpoint_hydration_ambiguous}
      {:error, _reason} = error -> error
    end
  end

  defp hydrate_locked(store, kind, record, expected_head) do
    with {:ok, observed_head, snapshot} <- observe_target_head_snapshot(store, kind),
         {:continue, snapshot} <-
           expected_retry_or_match(store, kind, record, expected_head, observed_head, snapshot) do
      reconcile_expected_hydration(store, kind, record, snapshot)
    else
      {:done, result} -> result
      {:error, _reason} = error -> error
    end
  end

  defp reconcile_hydration(store, kind, record, snapshot) do
    current = snapshot.current

    with :ok <- safe_rebinding(store, current),
         :ok <- verify_unknown_ancestry_acceptance(snapshot, record) do
      cond do
        secure_equal(record.checkpoint_hash, current.checkpoint_hash) ->
          accept_current(store, kind, record, snapshot)

        secure_equal(record.parent_hash, current.checkpoint_hash) ->
          install_accepted_after(store, kind, record, snapshot)

        current.accepted ->
          reconcile_accepted_current(store, kind, record, snapshot)

        true ->
          reconcile_local_current(store, kind, record, snapshot)
      end
    end
  end

  defp verify_unknown_ancestry_acceptance(
         %{current: current, last_accepted: last_accepted, ancestry: :unknown},
         record
       )
       when is_map(last_accepted) do
    accepted_is_current_parent = secure_equal(current.parent_hash, last_accepted.checkpoint_hash)
    accepting_current_parent = secure_equal(record.checkpoint_hash, current.parent_hash)
    accepting_current = secure_equal(record.checkpoint_hash, current.checkpoint_hash)
    accepting_current_child = secure_equal(record.parent_hash, current.checkpoint_hash)

    if accepted_is_current_parent and
         (accepting_current_parent or accepting_current or accepting_current_child),
       do: :ok,
       else: {:error, :checkpoint_hydration_ambiguous}
  end

  defp verify_unknown_ancestry_acceptance(_snapshot, _record), do: :ok

  defp accept_current(store, kind, record, %{ancestry: ancestry} = snapshot)
       when is_list(ancestry),
       do: rebind_accepted(store, kind, record, snapshot)

  defp accept_current(store, kind, record, _snapshot),
    do: install_accepted(store, kind, record)

  defp install_accepted_after(store, kind, record, snapshot) do
    case Snapshot.accepted_successor(snapshot, record) do
      {:ok, successor} ->
        with :ok <- write_snapshot(store, kind, successor), do: {:ok, record}

      {:error, :checkpoint_ancestry_unknown} ->
        install_accepted(store, kind, record)

      {:error, _reason} = error ->
        error
    end
  end

  defp reconcile_accepted_current(store, kind, record, %{current: current} = snapshot) do
    case accepted_relation(record, current) do
      :successor -> install_accepted_successor(store, kind, record, snapshot)
      :same -> rebind_accepted(store, kind, record, snapshot)
      {:error, _reason} = error -> error
    end
  end

  defp reconcile_local_current(store, kind, record, snapshot) do
    last_accepted = snapshot.last_accepted

    cond do
      Snapshot.accepted_ancestor?(snapshot, record.checkpoint_hash) ->
        preserve_current_with_acceptance(store, kind, snapshot, record)

      not is_map(last_accepted) ->
        {:error, :checkpoint_hydration_ambiguous}

      true ->
        case accepted_relation(record, last_accepted) do
          {:error, reason}
          when reason in [:checkpoint_hydration_rollback, :checkpoint_hydration_conflict] ->
            {:error, reason}

          _other ->
            {:error, :checkpoint_hydration_ambiguous}
        end
    end
  end

  defp preserve_current_with_acceptance(store, kind, snapshot, accepted) do
    with {:ok, rebound} <- rebind_local(store, snapshot.current),
         {:ok, last_accepted} <- Snapshot.accepted_summary(accepted),
         {:ok, successor} <- Snapshot.preserve_acceptance(snapshot, rebound, last_accepted),
         :ok <- write_snapshot(store, kind, successor) do
      {:ok, rebound}
    end
  end

  defp rebind_local(store, current) do
    Record.build(%{
      device_id: current.device_id,
      local_credential_epoch: store.credential_epoch,
      local_storage_epoch: store.storage_epoch,
      origin_credential_epoch: current.origin_credential_epoch,
      origin_storage_epoch: current.origin_storage_epoch,
      sequence: current.sequence,
      kind: current.kind,
      schema_version: current.schema_version,
      source_generation: current.source_generation,
      parent_hash: current.parent_hash,
      content: current.content,
      accepted: false
    })
  end

  defp install_accepted(store, kind, record) do
    with {:ok, last_accepted} <- Snapshot.accepted_summary(record),
         {:ok, snapshot} <- Snapshot.build(record, last_accepted),
         :ok <- write_snapshot(store, kind, snapshot) do
      {:ok, record}
    end
  end

  defp install_accepted_successor(store, kind, record, snapshot) do
    with {:ok, successor} <- Snapshot.accepted_successor(snapshot, record),
         :ok <- write_snapshot(store, kind, successor) do
      {:ok, record}
    end
  end

  defp rebind_accepted(store, kind, record, snapshot) do
    with {:ok, last_accepted} <- Snapshot.accepted_summary(record),
         {:ok, rebound} <-
           Snapshot.build(
             record,
             last_accepted,
             snapshot.ancestry,
             snapshot.ancestry_truncated
           ),
         :ok <- write_snapshot(store, kind, rebound) do
      {:ok, record}
    end
  end

  defp expected_retry_or_match(store, kind, record, expected, observed, snapshot) do
    cond do
      accepted_retry?(store, record, snapshot) ->
        {:done, rewrite_current(store, kind, snapshot)}

      expected_head_mismatch?(expected, observed) and
          accepted_ancestor_retry?(store, record, snapshot) ->
        {:done, rewrite_current(store, kind, snapshot)}

      preserved_local_retry?(store, record, expected, snapshot) ->
        {:done, preserve_current_with_acceptance(store, kind, snapshot, record)}

      true ->
        with :ok <- match_expected_head(expected, observed),
             :ok <- safe_expected_rebinding(store, snapshot) do
          {:continue, snapshot}
        end
    end
  end

  defp accepted_retry?(store, record, %{current: %{accepted: true} = current}) do
    secure_equal(record.checkpoint_hash, current.checkpoint_hash) and
      fence_record(store, current) == :ok
  end

  defp accepted_retry?(_store, _record, _snapshot), do: false

  defp accepted_ancestor_retry?(
         store,
         record,
         %{current: %{accepted: false} = current} = snapshot
       ) do
    Snapshot.accepted_replay?(snapshot, record.checkpoint_hash) and
      fence_record(store, current) == :ok
  end

  defp accepted_ancestor_retry?(store, record, %{current: %{accepted: true} = current} = snapshot) do
    Snapshot.accepted_replay?(snapshot, record.checkpoint_hash) and
      fence_record(store, current) == :ok
  end

  defp accepted_ancestor_retry?(_store, _record, _snapshot), do: false

  defp preserved_local_retry?(
         store,
         record,
         %{state: :fenced, checkpoint_hash: expected_hash},
         %{current: %{accepted: false} = current, last_accepted: last_accepted}
       )
       when is_map(last_accepted) do
    secure_equal(expected_hash, current.checkpoint_hash) and
      secure_equal(record.checkpoint_hash, last_accepted.checkpoint_hash) and
      fence_record(store, current) == :ok
  end

  defp preserved_local_retry?(_store, _record, _expected, _snapshot), do: false

  defp reconcile_expected_hydration(store, kind, record, nil),
    do: install_accepted(store, kind, record)

  defp reconcile_expected_hydration(store, kind, record, snapshot) do
    case reconcile_hydration(store, kind, record, snapshot) do
      {:error, :checkpoint_hydration_ambiguous} ->
        replace_ambiguous_expected_hydration(store, kind, record, snapshot)

      result ->
        result
    end
  end

  defp replace_ambiguous_expected_hydration(_store, _kind, _record, %{current: %{accepted: true}}),
    do: {:error, :checkpoint_hydration_ambiguous}

  defp replace_ambiguous_expected_hydration(store, kind, record, snapshot) do
    with :ok <- accepted_watermark_allows(snapshot, record) do
      install_accepted(store, kind, record)
    end
  end

  defp accepted_watermark_allows(%{ancestry: :unknown}, _record),
    do: {:error, :checkpoint_hydration_ambiguous}

  defp accepted_watermark_allows(%{ancestry_truncated: true}, _record),
    do: {:error, :checkpoint_hydration_ambiguous}

  defp accepted_watermark_allows(%{last_accepted: nil}, _record), do: :ok

  defp accepted_watermark_allows(%{last_accepted: :unknown}, _record),
    do: {:error, :checkpoint_hydration_ambiguous}

  defp accepted_watermark_allows(%{last_accepted: last_accepted}, record) do
    case accepted_relation(record, last_accepted) do
      relation when relation in [:same, :successor] -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp accepted_relation(record, accepted) do
    cond do
      secure_equal(record.checkpoint_hash, accepted.checkpoint_hash) ->
        :same

      secure_equal(record.parent_hash, accepted.checkpoint_hash) ->
        :successor

      secure_equal(record.checkpoint_hash, accepted.parent_hash) ->
        {:error, :checkpoint_hydration_rollback}

      same_origin?(record, accepted) and record.sequence < accepted.sequence ->
        {:error, :checkpoint_hydration_rollback}

      same_origin?(record, accepted) and record.sequence == accepted.sequence ->
        {:error, :checkpoint_hydration_conflict}

      true ->
        {:error, :checkpoint_hydration_ambiguous}
    end
  end

  defp safe_rebinding(store, current) do
    cond do
      not secure_equal(current.device_id, store.device_id) ->
        {:error, :device_mismatch}

      current.local_credential_epoch > store.credential_epoch ->
        {:error, :credential_epoch_mismatch}

      true ->
        :ok
    end
  end

  defp observe_target_head_snapshot(store, kind) do
    case read_head_bytes(store, transition_path(store, kind)) do
      :empty ->
        {:ok, %{state: :absent, checkpoint_hash: Record.genesis_parent()}, nil}

      {:ok, bytes} ->
        case Snapshot.decode(bytes) do
          {:ok, %{current: %{kind: ^kind}} = snapshot} ->
            state =
              case fence_record(store, snapshot.current) do
                :ok when snapshot.current.accepted -> :accepted
                :ok -> :local_unaccepted
                {:error, _reason} -> :fenced
              end

            {:ok, %{state: state, checkpoint_hash: snapshot.current.checkpoint_hash}, snapshot}

          _corrupt ->
            {:ok, %{state: :corrupt, checkpoint_hash: corrupt_head_hash(bytes)}, nil}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp corrupt_head_hash(bytes) do
    :crypto.hash(
      :sha256,
      @corrupt_head_domain <> <<byte_size(bytes)::64, bytes::binary>>
    )
  end

  defp expected_head_mismatch?(expected, observed),
    do: match_expected_head(expected, observed) != :ok

  defp match_expected_head(expected, observed) do
    if expected.state == observed.state and
         secure_equal(expected.checkpoint_hash, observed.checkpoint_hash),
       do: :ok,
       else: {:error, :expected_target_head_mismatch}
  end

  defp safe_expected_rebinding(_store, nil), do: :ok
  defp safe_expected_rebinding(store, snapshot), do: safe_rebinding(store, snapshot.current)

  defp same_origin?(record, accepted) do
    record.origin_credential_epoch == accepted.origin_credential_epoch and
      secure_equal(record.origin_storage_epoch, accepted.origin_storage_epoch)
  end

  defp build_local(store, attrs) do
    Record.build(%{
      device_id: store.device_id,
      local_credential_epoch: store.credential_epoch,
      local_storage_epoch: store.storage_epoch,
      origin_credential_epoch: store.credential_epoch,
      origin_storage_epoch: store.storage_epoch,
      sequence: Map.get(attrs, :sequence),
      kind: Map.get(attrs, :kind),
      schema_version: Map.get(attrs, :schema_version),
      source_generation: Map.get(attrs, :source_generation),
      parent_hash: Map.get(attrs, :parent_hash),
      content: Map.get(attrs, :content),
      accepted: false
    })
  end

  defp build_hydrated(store, attrs) do
    Record.build(%{
      device_id: store.device_id,
      local_credential_epoch: store.credential_epoch,
      local_storage_epoch: store.storage_epoch,
      origin_credential_epoch: Map.get(attrs, :origin_credential_epoch),
      origin_storage_epoch: Map.get(attrs, :origin_storage_epoch),
      sequence: Map.get(attrs, :sequence),
      kind: Map.get(attrs, :kind),
      schema_version: Map.get(attrs, :schema_version),
      source_generation: Map.get(attrs, :source_generation),
      parent_hash: Map.get(attrs, :parent_hash),
      content: Map.get(attrs, :content),
      accepted: true
    })
  end

  defp match_addressed_identity(store, attrs) do
    cond do
      not secure_equal(Map.get(attrs, :device_id), store.device_id) ->
        {:error, :device_mismatch}

      Map.get(attrs, :credential_epoch) !== store.credential_epoch ->
        {:error, :credential_epoch_mismatch}

      not secure_equal(Map.get(attrs, :storage_epoch), store.storage_epoch) ->
        {:error, :storage_epoch_mismatch}

      true ->
        :ok
    end
  end

  defp match_presented_hash(record, attrs) do
    if secure_equal(record.checkpoint_hash, Map.get(attrs, :checkpoint_hash)),
      do: :ok,
      else: {:error, :checkpoint_hash_mismatch}
  end

  defp fence_record(store, record) do
    cond do
      not secure_equal(record.device_id, store.device_id) ->
        {:error, :device_mismatch}

      record.local_credential_epoch !== store.credential_epoch ->
        {:error, :credential_epoch_mismatch}

      not secure_equal(record.local_storage_epoch, store.storage_epoch) ->
        {:error, :storage_epoch_mismatch}

      true ->
        :ok
    end
  end

  defp read_snapshot(store, kind) do
    with {:ok, bytes} <- read_head_bytes(store, transition_path(store, kind)),
         {:ok, snapshot} <- Snapshot.decode(bytes),
         true <- snapshot.current.kind == kind do
      {:ok, snapshot}
    else
      :empty -> :empty
      {:error, _reason} = error -> error
      _other -> {:error, :corrupt_checkpoint_head}
    end
  end

  defp read_head_bytes(store, path), do: read_head_bytes(store, path, @read_retry_count)

  defp read_head_bytes(store, path, retries_remaining) do
    result =
      if bounded_file_system?(store.file_system) do
        bounded_head_read(store.file_system, path)
      else
        {:error, :checkpoint_head_bounded_read_unsupported}
      end

    retry_changed_read(store, path, retries_remaining, result)
  end

  defp bounded_head_read(fs, path) do
    owner = self()
    result_ref = make_ref()
    guard_key = {__MODULE__, :transition}
    guarded? = Process.get(guard_key) == true

    {pid, monitor} =
      spawn_monitor(fn ->
        worker = self()
        _watcher = spawn(fn -> stop_worker_on_owner_exit(owner, worker) end)
        if guarded?, do: Process.put(guard_key, true)

        try do
          send(owner, {result_ref, read_head_bytes_now(fs, path)})
        after
          if guarded?, do: Process.delete(guard_key)
        end
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, {:checkpoint_head_io, :read_process_failed}}
    after
      @read_timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        end

        drain_worker_result(result_ref)
        {:error, {:checkpoint_head_io, :read_timeout}}
    end
  end

  defp stop_worker_on_owner_exit(owner, worker) do
    owner_monitor = Process.monitor(owner)
    worker_monitor = Process.monitor(worker)

    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^worker_monitor, :process, ^worker, _reason} -> :ok
        end

      {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
        :ok
    end
  end

  defp drain_worker_result(result_ref) do
    receive do
      {^result_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp read_head_bytes_now(fs, path) do
    case safe_fs_call(fs, :lstat, [path]) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        with :ok <- validate_regular_stat(stat, :invalid_lstat_response) do
          read_regular_file_now(fs, path, stat)
        end

      {:ok, %File.Stat{}} ->
        {:error, :corrupt_checkpoint_head}

      {:error, :enoent} ->
        :empty

      {:error, reason} ->
        {:error, {:checkpoint_head_io, reason}}

      _other ->
        {:error, {:checkpoint_head_io, :invalid_lstat_response}}
    end
  end

  defp retry_changed_read(store, path, retries_remaining, original)
       when retries_remaining > 0 and
              original == {:error, {:checkpoint_head_io, :file_changed_during_read}} do
    case read_head_bytes(store, path, retries_remaining - 1) do
      :empty -> original
      later_result -> later_result
    end
  end

  defp retry_changed_read(_store, _path, _retries_remaining, result), do: result

  defp read_regular_file_now(fs, path, path_stat) do
    case safe_fs_call(fs, :open, [path, [:read, :binary, :raw]]) do
      {:ok, device} ->
        result = read_open_device(fs, path, device, path_stat)
        close_result = safe_fs_call(fs, :close, [device])

        case {result, close_result} do
          {{:ok, _bytes} = ok, :ok} -> ok
          {{:error, _reason} = error, _close_result} -> error
          {_result, {:error, reason}} -> {:error, {:checkpoint_head_io, reason}}
          {_result, _other} -> {:error, {:checkpoint_head_io, :invalid_close_response}}
        end

      {:error, reason} ->
        {:error, {:checkpoint_head_io, reason}}

      _other ->
        {:error, {:checkpoint_head_io, :invalid_open_response}}
    end
  end

  defp read_open_device(fs, path, device, path_stat) do
    with {:ok, descriptor_stat} <- regular_descriptor_info(fs, device),
         :ok <- verify_same_file(path_stat, descriptor_stat),
         true <- descriptor_stat.size <= @max_encoded_size,
         :ok <- revalidate_open_path(fs, path, descriptor_stat),
         {:ok, chunks, total} <- read_chunks(fs, device, @max_encoded_size + 1, [], 0),
         true <- total <= @max_encoded_size,
         :ok <- verify_read_total(total, descriptor_stat.size),
         {:ok, final_stat} <- regular_descriptor_info(fs, device),
         :ok <- verify_same_file(descriptor_stat, final_stat),
         :ok <- revalidate_open_path(fs, path, final_stat) do
      {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    else
      false -> {:error, :corrupt_checkpoint_head}
      {:error, :corrupt_checkpoint_head} = error -> error
      {:error, {:checkpoint_head_io, _reason}} = error -> error
      {:error, reason} -> {:error, {:checkpoint_head_io, reason}}
    end
  end

  defp regular_descriptor_info(fs, device) do
    case safe_fs_call(fs, :file_info, [device]) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        with :ok <- validate_regular_stat(stat, :invalid_file_info_response), do: {:ok, stat}

      {:ok, %File.Stat{}} ->
        {:error, :corrupt_checkpoint_head}

      {:error, reason} ->
        {:error, {:checkpoint_head_io, reason}}

      _other ->
        {:error, {:checkpoint_head_io, :invalid_file_info_response}}
    end
  end

  defp revalidate_open_path(fs, path, descriptor_stat) do
    case safe_fs_call(fs, :lstat, [path]) do
      {:ok, %File.Stat{type: :regular} = path_stat} ->
        with :ok <- validate_regular_stat(path_stat, :invalid_lstat_response) do
          verify_same_file(path_stat, descriptor_stat)
        end

      {:ok, %File.Stat{}} ->
        {:error, :corrupt_checkpoint_head}

      {:error, reason} ->
        {:error, {:checkpoint_head_io, reason}}

      _other ->
        {:error, {:checkpoint_head_io, :invalid_lstat_response}}
    end
  end

  defp validate_regular_stat(%File.Stat{} = stat, error) do
    if non_negative_integer?(stat.size) and non_negative_integer?(stat.inode) and
         non_negative_integer?(stat.major_device) and non_negative_integer?(stat.minor_device) do
      :ok
    else
      {:error, {:checkpoint_head_io, error}}
    end
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp verify_read_total(total, expected) when total == expected, do: :ok

  defp verify_read_total(total, expected) when total < expected,
    do: {:error, {:checkpoint_head_io, :premature_eof}}

  defp verify_read_total(_total, _expected),
    do: {:error, {:checkpoint_head_io, :file_changed_during_read}}

  defp verify_same_file(left, right) do
    if same_file_identity?(left, right) and left.size == right.size,
      do: :ok,
      else: {:error, {:checkpoint_head_io, :file_changed_during_read}}
  end

  defp same_file_identity?(left, right) do
    left.inode == right.inode and
      left.major_device == right.major_device and
      left.minor_device == right.minor_device
  end

  defp read_chunks(_fs, _device, 0, chunks, total), do: {:ok, chunks, total}

  defp read_chunks(fs, device, remaining, chunks, total) when remaining > 0 do
    count = min(remaining, @read_chunk_size)

    case safe_fs_call(fs, :read, [device, count]) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= count ->
        size = byte_size(bytes)
        read_chunks(fs, device, remaining - size, [bytes | chunks], total + size)

      :eof ->
        {:ok, chunks, total}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_read_response}
    end
  end

  defp rewrite_current(store, kind, snapshot) do
    with :ok <- write_snapshot(store, kind, snapshot), do: {:ok, snapshot.current}
  end

  defp write_snapshot(store, kind, snapshot) do
    path = transition_path(store, kind)

    with {:ok, bytes} <- Snapshot.encode(snapshot),
         :ok <- cleanup_orphan_temps(store, path) |> classify_cleanup_result() do
      AtomicFile.write(path, bytes, atomic_opts(store, path))
    end
  end

  defp classify_cleanup_result(:ok), do: :ok

  defp classify_cleanup_result({:error, {:pre_rename, _reason}} = error), do: error

  defp classify_cleanup_result({:error, reason}), do: {:error, {:pre_rename, reason}}

  defp classify_cleanup_result(_other),
    do: {:error, {:pre_rename, {:orphan_temp_cleanup, :invalid_response}}}

  defp cleanup_orphan_temps(store, path) do
    AtomicFile.cleanup_orphan_temps(path, atomic_opts(store, path))
  end

  defp atomic_opts(store, path) do
    [
      file_system: store.file_system,
      fault_injector: &checkpoint_write_boundary(store, &1),
      temp_suffix: store.temp_suffix,
      directory_root: path |> Path.dirname() |> Path.dirname()
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp checkpoint_write_boundary(store, stage),
    do: run_fault_injector(store.fault_injector, stage)

  defp run_fault_injector(nil, _stage), do: :ok
  defp run_fault_injector(injector, stage) when is_function(injector, 1), do: injector.(stage)
  defp run_fault_injector(_injector, _stage), do: {:error, :invalid_injector}

  defp with_kind_lock(store, kind, transition) when is_function(transition, 0) do
    guard_key = {__MODULE__, :transition}

    if Process.get(guard_key) do
      {:error, :checkpoint_head_reentrant_transition}
    else
      Process.put(guard_key, true)

      try do
        run_destination_transition(store, kind, transition, @path_lock_attempts)
      after
        Process.delete(guard_key)
      end
    end
  end

  defp run_destination_transition(_store, _kind, _transition, 0),
    do: {:error, :checkpoint_head_path_unstable}

  defp run_destination_transition(store, kind, transition, attempts_remaining) do
    with {:ok, destination, lock_resource} <-
           canonical_lock_destination(store, head_path(store, kind)) do
      requester = {self(), make_ref()}
      lock_id = {lock_resource, requester}
      deadline = System.monotonic_time(:millisecond) + @lock_wait_ms

      case acquire_lock(lock_id, deadline) do
        {:ok, lock_holder} ->
          result =
            try do
              run_locked_transition(lock_holder, store.transition_timeout_ms, fn ->
                case canonical_lock_destination(store, head_path(store, kind)) do
                  {:ok, ^destination, ^lock_resource} ->
                    with_authority(store, fn ->
                      case canonical_lock_destination(store, head_path(store, kind)) do
                        {:ok, ^destination, ^lock_resource} ->
                          with_transition_path(store, kind, destination, transition)

                        {:ok, _changed, _changed_resource} ->
                          :retry_checkpoint_head_path

                        {:error, _reason} = error ->
                          error
                      end
                    end)

                  {:ok, _changed, _changed_resource} ->
                    :retry_checkpoint_head_path

                  {:error, _reason} = error ->
                    error
                end
              end)
            after
              release_lock(lock_holder)
            end

          case result do
            :retry_checkpoint_head_path ->
              run_destination_transition(store, kind, transition, attempts_remaining - 1)

            other ->
              other
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp with_transition_path(store, kind, path, transition) do
    key = transition_path_key(store, kind)
    Process.put(key, path)

    try do
      transition.()
    after
      Process.delete(key)
    end
  end

  defp transition_path(store, kind) do
    case Process.get(transition_path_key(store, kind)) do
      path when is_binary(path) -> path
      _other -> head_path(store, kind)
    end
  end

  defp transition_path_key(store, kind),
    do: {__MODULE__, :transition_path, head_path(store, kind)}

  defp canonical_lock_destination(store, path) do
    run_bounded_path_operation(fn -> canonical_lock_destination_now(store, path) end)
  end

  defp canonical_lock_destination_now(store, path) do
    with {:ok, destination} <- canonical_destination_path_now(store.file_system, path),
         :ok <- ensure_lock_directory(store, destination),
         {:ok, confirmed} <- canonical_destination_path_now(store.file_system, path),
         true <- confirmed == destination,
         {:ok, lock_resource} <- destination_lock_resource(store, destination) do
      {:ok, destination, lock_resource}
    else
      false -> {:error, :checkpoint_head_path_unstable}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_lock_directory(store, destination) do
    directory = Path.dirname(destination)

    with :ok <-
           lock_directory_result(safe_fs_call(store.file_system, :mkdir_p, [directory]), :mkdir),
         :ok <-
           lock_directory_result(
             safe_fs_call(store.file_system, :chmod, [directory, 0o700]),
             :chmod
           ) do
      :ok
    else
      {:error, reason} -> {:error, {:checkpoint_head_path, {:directory_prepare, reason}}}
    end
  end

  defp lock_directory_result(:ok, _operation), do: :ok
  defp lock_directory_result({:error, reason}, operation), do: {:error, {operation, reason}}
  defp lock_directory_result(_other, operation), do: {:error, {operation, :invalid_response}}

  defp destination_lock_resource(store, destination) do
    parent = Path.dirname(destination)

    case safe_fs_call(store.file_system, :lstat, [parent]) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok, {__MODULE__, :destination, stat.major_device, stat.minor_device, stat.inode, Path.basename(destination)}}

      {:ok, %File.Stat{}} ->
        {:error, {:checkpoint_head_path, :enotdir}}

      {:error, reason} ->
        {:error, {:checkpoint_head_path, reason}}

      _other ->
        {:error, {:checkpoint_head_path, :invalid_lstat_response}}
    end
  end

  defp run_bounded_path_operation(operation) when is_function(operation, 0) do
    owner = self()
    result_ref = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        current_worker = self()
        _watcher = spawn(fn -> stop_worker_on_owner_exit(owner, current_worker) end)
        guard_key = {__MODULE__, :transition}
        Process.put(guard_key, true)

        try do
          send(owner, {result_ref, operation.()})
        after
          Process.delete(guard_key)
        end
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, {:checkpoint_head_path, :resolution_process_failed}}
    after
      @read_timeout_ms ->
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
        end

        drain_worker_result(result_ref)
        {:error, {:checkpoint_head_path, :timeout}}
    end
  end

  defp canonical_destination_path_now(fs, path) do
    absolute = Path.absname(path)

    with :ok <- canonical_path_file_system(fs),
         {:ok, parent} <- absolute |> Path.dirname() |> resolve_symlinks(fs, @symlink_limit) do
      {:ok, Path.join(parent, Path.basename(absolute))}
    end
  end

  defp canonical_path_file_system(fs) when is_atom(fs) do
    cond do
      not Code.ensure_loaded?(fs) ->
        {:error, {:checkpoint_head_path, :filesystem_unavailable}}

      not function_exported?(fs, :lstat, 1) ->
        {:error, {:checkpoint_head_path, :lstat_unsupported}}

      not function_exported?(fs, :read_link, 1) ->
        {:error, {:checkpoint_head_path, :read_link_unsupported}}

      true ->
        :ok
    end
  end

  defp canonical_path_file_system(_fs),
    do: {:error, {:checkpoint_head_path, :filesystem_unavailable}}

  defp resolve_symlinks(path, fs, remaining) do
    case Path.split(path) do
      [root | parts] -> resolve_path_parts(root, parts, fs, remaining)
      [] -> {:error, :invalid_checkpoint_head_path}
    end
  end

  defp resolve_path_parts(path, [], _fs, _remaining), do: {:ok, path}

  defp resolve_path_parts(path, ["." | rest], fs, remaining),
    do: resolve_path_parts(path, rest, fs, remaining)

  defp resolve_path_parts(path, [".." | rest], fs, remaining),
    do: resolve_path_parts(Path.dirname(path), rest, fs, remaining)

  defp resolve_path_parts(path, [part | rest], fs, remaining) do
    candidate = Path.join(path, part)

    case safe_fs_call(fs, :lstat, [candidate]) do
      {:ok, %File.Stat{type: :symlink}} when remaining > 0 ->
        case safe_fs_call(fs, :read_link, [candidate]) do
          {:ok, target} when is_binary(target) ->
            resolve_symlink_target(target, path, rest, fs, remaining - 1)

          {:error, reason} ->
            {:error, {:checkpoint_head_path, reason}}

          _other ->
            {:error, {:checkpoint_head_path, :invalid_read_link_response}}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :checkpoint_head_symlink_limit}

      {:ok, %File.Stat{}} ->
        resolve_path_parts(candidate, rest, fs, remaining)

      {:error, :enoent} ->
        resolve_path_parts(candidate, rest, fs, remaining)

      {:error, reason} ->
        {:error, {:checkpoint_head_path, reason}}

      _other ->
        {:error, {:checkpoint_head_path, :invalid_lstat_response}}
    end
  end

  defp resolve_symlink_target(target, parent, rest, fs, remaining) do
    case {Path.type(target), Path.split(target)} do
      {:absolute, [root | target_parts]} ->
        resolve_path_parts(root, target_parts ++ rest, fs, remaining)

      {_relative, target_parts} ->
        resolve_path_parts(parent, target_parts ++ rest, fs, remaining)
    end
  end

  defp acquire_lock(lock_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :checkpoint_head_lock_timeout}
    else
      owner = self()
      acquired_ref = make_ref()

      {holder, monitor} =
        spawn_monitor(fn ->
          hold_global_lock(owner, acquired_ref, lock_id, deadline)
        end)

      receive do
        {^acquired_ref, :acquired} ->
          {:ok, {holder, monitor}}

        {:DOWN, ^monitor, :process, ^holder, :lock_timeout} ->
          {:error, :checkpoint_head_lock_timeout}

        {:DOWN, ^monitor, :process, ^holder, _reason} ->
          {:error, :checkpoint_head_lock_unavailable}
      after
        remaining ->
          Process.exit(holder, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^holder, _reason} -> :ok
          end

          drain_worker_result(acquired_ref)
          {:error, :checkpoint_head_lock_timeout}
      end
    end
  end

  defp hold_global_lock(owner, acquired_ref, lock_id, deadline) do
    holder = self()
    _watcher = spawn(fn -> stop_worker_on_owner_exit(owner, holder) end)
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
          min(@lock_retry_ms, remaining) ->
            await_global_lock(owner, acquired_ref, lock_id, deadline)
        end
    end
  end

  defp serve_lock_owner(owner, lock_id) do
    receive do
      {:run_checkpoint_head_transition, ^owner, result_ref, transition}
      when is_function(transition, 0) ->
        result = run_lock_holder_transition(transition)
        send(owner, {result_ref, result})
        await_lock_release(owner, lock_id)

      {:release_checkpoint_head_lock, ^owner} ->
        :global.del_lock(lock_id, [node()])
    end
  end

  defp run_lock_holder_transition(transition) do
    guard_key = {__MODULE__, :transition}
    Process.put(guard_key, true)

    try do
      transition.()
    after
      Process.delete(guard_key)
    end
  end

  defp await_lock_release(owner, lock_id) do
    receive do
      {:release_checkpoint_head_lock, ^owner} ->
        :global.del_lock(lock_id, [node()])
    end
  end

  defp run_locked_transition({holder, monitor}, timeout_ms, transition) do
    result_ref = make_ref()
    send(holder, {:run_checkpoint_head_transition, self(), result_ref, transition})

    receive do
      {^result_ref, result} ->
        result

      {:DOWN, ^monitor, :process, ^holder, _reason} = down ->
        send(self(), down)
        {:error, {:durability_uncertain, :checkpoint_head_lock_lost}}
    after
      timeout_ms ->
        Process.exit(holder, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^holder, _reason} = down -> send(self(), down)
        end

        drain_worker_result(result_ref)
        {:error, {:durability_uncertain, :checkpoint_head_transition_timeout}}
    end
  end

  defp release_lock({holder, monitor}) do
    send(holder, {:release_checkpoint_head_lock, self()})

    receive do
      {:DOWN, ^monitor, :process, ^holder, _reason} ->
        :ok
    after
      @lock_wait_ms ->
        Process.exit(holder, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^holder, _reason} -> :ok
        end
    end
  end

  defp with_bounded_authority(store, transition) when is_function(transition, 0) do
    case OwnerResolver.run(
           fn -> with_authority(store, transition) end,
           timeout_ms: store.transition_timeout_ms,
           cancel_on: [self()]
         ) do
      {:error, :owner_resolution_timeout} -> {:error, :identity_authority_timeout}
      {:error, :owner_resolution_cancelled} -> {:error, :identity_authority_cancelled}
      {:error, :owner_resolution_failed} -> {:error, :invalid_identity_authority}
      result -> result
    end
  end

  defp with_authority(store, transition) when is_function(transition, 0) do
    invoke_identity_authority(store.identity_source, fn identity ->
      with {:ok, identity} <- validate_identity(identity),
           :ok <- match_authority(store, identity) do
        transition.()
      end
    end)
  end

  defp invoke_identity_authority(source, transition) do
    owner = self()
    key = {__MODULE__, :identity_authority, make_ref()}
    Process.put(key, :ready)

    guarded_transition = fn identity ->
      case {self() == owner, Process.get(key)} do
        {true, :ready} ->
          Process.put(key, :running)
          result = transition.(identity)
          Process.put(key, {:completed, result})
          result

        _other ->
          {:error, :invalid_identity_authority}
      end
    end

    try do
      _authority_result = invoke_authority_source(source, guarded_transition)

      case Process.get(key) do
        {:completed, result} -> result
        _other -> {:error, :invalid_identity_authority}
      end
    after
      Process.delete(key)
    end
  end

  defp invoke_authority_source(source, transition) do
    source.(transition)
  rescue
    _exception -> {:error, :invalid_identity_authority}
  catch
    _kind, _reason -> {:error, :invalid_identity_authority}
  end

  defp match_authority(store, identity) do
    cond do
      not secure_equal(identity.device_id, store.device_id) ->
        {:error, :device_mismatch}

      identity.credential_epoch !== store.credential_epoch ->
        {:error, :credential_epoch_mismatch}

      not secure_equal(identity.storage_epoch, store.storage_epoch) ->
        {:error, :storage_epoch_mismatch}

      true ->
        :ok
    end
  end

  defp validate_expected_head(expected_head) do
    with :ok <- exact_keys(expected_head, @expected_head_keys, :invalid_expected_target_head),
         state when state in @expected_head_states <- Map.get(expected_head, :state),
         <<checkpoint_hash::binary-size(32)>> <- Map.get(expected_head, :checkpoint_hash),
         :ok <- validate_expected_head_hash(state, checkpoint_hash) do
      {:ok, %{state: state, checkpoint_hash: checkpoint_hash}}
    else
      _error -> {:error, :invalid_expected_target_head}
    end
  end

  defp validate_expected_head_hash(:absent, checkpoint_hash) do
    if secure_equal(checkpoint_hash, Record.genesis_parent()),
      do: :ok,
      else: {:error, :invalid_expected_target_head}
  end

  defp validate_expected_head_hash(:corrupt, checkpoint_hash) do
    if secure_equal(checkpoint_hash, Record.genesis_parent()),
      do: {:error, :invalid_expected_target_head},
      else: :ok
  end

  defp validate_expected_head_hash(_state, checkpoint_hash) do
    if secure_equal(checkpoint_hash, Record.genesis_parent()),
      do: {:error, :invalid_expected_target_head},
      else: :ok
  end

  defp identity_source(opts) do
    case Keyword.fetch(opts, :identity) do
      {:ok, source} when is_function(source, 1) -> {:ok, source}
      {:ok, _source} -> {:error, :invalid_identity_source}
      :error -> {:error, :missing_identity_source}
    end
  end

  defp validate_identity(identity) when is_map(identity) do
    with true <- Enum.all?(@identity_keys, &Map.has_key?(identity, &1)),
         {:ok, device_id} <- device_id(Map.get(identity, :device_id)),
         {:ok, credential_epoch} <- credential_epoch(Map.get(identity, :credential_epoch)),
         {:ok, storage_epoch} <- storage_epoch(Map.get(identity, :storage_epoch)) do
      {:ok,
       %{
         device_id: device_id,
         credential_epoch: credential_epoch,
         storage_epoch: storage_epoch
       }}
    else
      _error -> {:error, :invalid_identity}
    end
  end

  defp validate_identity(_identity), do: {:error, :invalid_identity}

  defp bounded_file_system?(fs) when is_atom(fs) do
    Code.ensure_loaded?(fs) and
      Enum.all?(@required_bounded_callbacks, fn {callback, arity} ->
        function_exported?(fs, callback, arity)
      end)
  end

  defp bounded_file_system?(_fs), do: false

  defp safe_fs_call(fs, callback, args) do
    apply(fs, callback, args)
  rescue
    _exception -> {:error, {:callback_failed, callback, :raise}}
  catch
    :throw, _reason -> {:error, {:callback_failed, callback, :throw}}
    :exit, _reason -> {:error, {:callback_failed, callback, :exit}}
  end

  defp known_kind(kind) do
    case Contract.checkpoint_kind(kind) do
      {:ok, _code, _schema_version} -> {:ok, kind}
      {:error, _reason} -> {:error, :unknown_checkpoint_kind}
    end
  end

  defp base_dir(value) when is_binary(value) and value != "", do: {:ok, Path.absname(value)}
  defp base_dir(_value), do: {:error, :invalid_base_dir}

  defp transition_timeout_ms(value)
       when is_integer(value) and value > 0 and value <= @max_transition_timeout_ms,
       do: {:ok, value}

  defp transition_timeout_ms(_value), do: {:error, :invalid_transition_timeout}

  defp device_id(<<0::size(@device_id_size * 8)>>), do: {:error, :invalid_device_id}
  defp device_id(<<value::binary-size(@device_id_size)>>), do: {:ok, value}
  defp device_id(_value), do: {:error, :invalid_device_id}

  defp credential_epoch(value) when is_integer(value) and value >= 0 and value <= @u32_max,
    do: {:ok, value}

  defp credential_epoch(_value), do: {:error, :invalid_credential_epoch}

  defp storage_epoch(<<0::size(@storage_epoch_size * 8)>>), do: {:error, :invalid_storage_epoch}
  defp storage_epoch(<<value::binary-size(@storage_epoch_size)>>), do: {:ok, value}
  defp storage_epoch(_value), do: {:error, :invalid_storage_epoch}

  defp exact_keys(value, expected, error) when is_map(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(expected), do: :ok, else: {:error, error}
  end

  defp exact_keys(_value, _expected, error), do: {:error, error}

  defp secure_equal(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_equal(_left, _right), do: false
end
