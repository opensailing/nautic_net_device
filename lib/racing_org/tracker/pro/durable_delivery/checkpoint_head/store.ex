defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Store do
  @moduledoc """
  Durable per-kind local checkpoint heads with record-hash compare-and-swap.

  One file per registered checkpoint kind holds that kind's current head record.
  Kinds never share a file, so a corrupt calibration head cannot block polar or
  wind-shift progress, and a parent hash minted by one kind can never advance
  another.

  ## Why the fence is the RECORD hash, not the sequence

  A sequence-only fence admits two distinct failures this store must reject:

    * **Stale write.** A producer that read head *A*, then lost a race to another
      producer that installed *B*, would still be allowed to write if it only had
      to present a fresh sequence number.

    * **ABA.** A head may legitimately be replaced by a record with the SAME
      sequence and byte-identical content but a different record hash — the
      source generation, or the origin identity a hydration carries, is part of
      the record hash and not of the sequence. A writer holding the pre-swap
      record hash must be rejected, because the state it reasoned about is gone
      even though every sequence-visible field is unchanged.

  So `put/2` requires the caller's `:parent_hash` to equal the CURRENT head's
  `checkpoint_hash` exactly, and a first record must present
  `Record.genesis_parent/0`.

  ## Identity binding

  Every store handle is bound to one device ID, one credential epoch, and one
  storage epoch, and every persisted record carries a binding hash over exactly
  that triple. Reading or writing a head persisted under another device, a
  superseded credential epoch, or a replaced storage epoch fails closed with a
  typed mismatch and leaves the bytes untouched — a foreign or superseded head is
  intact data belonging to another incarnation, not corruption to be discarded.

  `hydrate/2` is the one path that installs a head under a NEW local identity: it
  carries the backend-accepted record with its original acceptance identity in
  `origin_credential_epoch` / `origin_storage_epoch` while binding locally to the
  current identity. That keeps the record hash stable across rotation, so the
  next local write can legally chain from a hydrated head. Because acceptance is
  authoritative, hydration replaces whatever local head exists — divergent,
  fenced, or corrupt — without a parent match.

  Persistence goes through `DesiredState.AtomicFile`, so a caller sees typed
  `{:pre_rename, _}` (nothing changed) and `{:durability_uncertain, _}` (the
  rename may have landed; reopen to learn the truth) outcomes rather than a bare
  error. No secret can reach these bytes: content passes the contract's
  secret-capable key screen before hashing, and the record carries no free-form
  metadata field.
  """

  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

  @directory "checkpoint_heads"
  @u32_max 0xFFFF_FFFF
  @storage_epoch_size 16
  @device_id_size 16

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

  @enforce_keys [:base_dir, :device_id, :credential_epoch, :storage_epoch, :file_system]
  defstruct @enforce_keys ++ [:fault_injector, :temp_suffix]

  @type t :: %__MODULE__{
          base_dir: Path.t(),
          device_id: <<_::128>>,
          credential_epoch: non_neg_integer(),
          storage_epoch: <<_::128>>,
          file_system: module(),
          fault_injector: (atom() -> :ok | {:error, term()}) | nil,
          temp_suffix: (-> binary()) | nil
        }

  @type status :: %{
          kinds: non_neg_integer(),
          present: non_neg_integer(),
          accepted: non_neg_integer(),
          corrupt: non_neg_integer(),
          fenced: non_neg_integer()
        }

  @doc """
  Open a store handle bound to one exact identity.

  Nothing is read or written here; the handle is a pure value. Identity is
  validated eagerly so a malformed device ID or a zero storage epoch cannot
  reach a persisted record.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) when is_list(opts) do
    with {:ok, base_dir} <- base_dir(Keyword.get(opts, :base_dir)),
         {:ok, device_id} <- device_id(Keyword.get(opts, :device_id)),
         {:ok, credential_epoch} <- credential_epoch(Keyword.get(opts, :credential_epoch)),
         {:ok, storage_epoch} <- storage_epoch(Keyword.get(opts, :storage_epoch)) do
      {:ok,
       %__MODULE__{
         base_dir: base_dir,
         device_id: device_id,
         credential_epoch: credential_epoch,
         storage_epoch: storage_epoch,
         file_system: Keyword.get(opts, :file_system, FileSystem),
         fault_injector: Keyword.get(opts, :fault_injector),
         temp_suffix: Keyword.get(opts, :temp_suffix)
       }}
    end
  end

  def new(_opts), do: {:error, :invalid_options}

  @doc """
  The current head for one kind, or `:empty` when the chain has not started.

  A head persisted under another identity is reported as a typed mismatch rather
  than as `:empty`, so a caller can never mistake a fenced chain for a fresh one
  and restart it.
  """
  @spec head(t(), atom()) :: {:ok, Record.t()} | :empty | {:error, atom()}
  def head(%__MODULE__{} = store, kind) do
    with {:ok, kind} <- known_kind(kind) do
      read_head(store, kind)
    end
  end

  @doc """
  Append one locally produced checkpoint under record-hash compare-and-swap.

  The record is bound to the store's current identity as BOTH its local and its
  origin identity: a locally produced checkpoint originates here. An exact replay
  of the current head is idempotent; anything else that presents a non-current
  parent is `:checkpoint_parent_mismatch`.
  """
  @spec put(t(), map()) :: {:ok, Record.t()} | {:error, term()}
  def put(%__MODULE__{} = store, attrs) when is_map(attrs) do
    with :ok <- exact_keys(attrs, @put_keys, :invalid_checkpoint_record),
         {:ok, kind} <- known_kind(attrs.kind),
         {:ok, record} <- build_local(store, attrs),
         {:ok, current} <- read_head(store, kind) do
      swap(store, kind, record, current)
    else
      :empty -> put_first(store, attrs)
      {:error, _reason} = error -> error
    end
  end

  def put(%__MODULE__{}, _attrs), do: {:error, :invalid_checkpoint_record}

  @doc """
  Install one backend-accepted checkpoint as the head for its kind.

  Acceptance is authoritative, so this path takes no parent-hash fence: it
  replaces a divergent, fenced, or corrupt local head. The presented
  `:checkpoint_hash` is verified against the frozen record-hash preimage over the
  ORIGIN identity, so a hydration cannot install a record the backend never
  hashed. `:device_id`, `:credential_epoch`, and `:storage_epoch` name the
  identity the message is addressed to and must equal the store's binding.
  """
  @spec hydrate(t(), map()) :: {:ok, Record.t()} | {:error, term()}
  def hydrate(%__MODULE__{} = store, attrs) when is_map(attrs) do
    with :ok <- exact_keys(attrs, @hydrate_keys, :invalid_checkpoint_record),
         {:ok, kind} <- known_kind(attrs.kind),
         :ok <- match_addressed_identity(store, attrs),
         {:ok, record} <- build_hydrated(store, attrs),
         :ok <- match_presented_hash(record, attrs) do
      case write_head(store, kind, record) do
        :ok -> {:ok, record}
        {:error, _reason} = error -> error
      end
    end
  end

  def hydrate(%__MODULE__{}, _attrs), do: {:error, :invalid_checkpoint_record}

  @doc "The absolute path of one kind's head file."
  @spec head_path(t(), atom()) :: Path.t()
  def head_path(%__MODULE__{} = store, kind) when is_atom(kind) do
    Path.join([store.base_dir, @directory, Atom.to_string(kind) <> ".head"])
  end

  @doc """
  Sanitized counters across every registered kind.

  Deliberately carries no identifiers, hashes, paths, content, or reasons — only
  how many kinds exist and how many heads are present, accepted, corrupt, or
  fenced to another identity.
  """
  @spec status(t()) :: status()
  def status(%__MODULE__{} = store) do
    Contract.checkpoint_kinds()
    |> Enum.reduce(
      %{kinds: length(Contract.checkpoint_kinds()), present: 0, accepted: 0, corrupt: 0, fenced: 0},
      fn {kind, _code, _schema}, acc ->
        case read_head(store, kind) do
          {:ok, %{accepted: true}} -> %{acc | present: acc.present + 1, accepted: acc.accepted + 1}
          {:ok, _record} -> %{acc | present: acc.present + 1}
          :empty -> acc
          {:error, :corrupt_checkpoint_head} -> %{acc | corrupt: acc.corrupt + 1}
          {:error, _reason} -> %{acc | fenced: acc.fenced + 1}
        end
      end
    )
  end

  # A first write is the only one whose parent is the genesis value, and it is
  # reachable only when the chain is genuinely empty — never when the head is
  # corrupt or fenced.
  defp put_first(store, attrs) do
    with {:ok, record} <- build_local(store, attrs) do
      if secure_equal(record.parent_hash, Record.genesis_parent()) do
        case write_head(store, record.kind, record) do
          :ok -> {:ok, record}
          {:error, _reason} = error -> error
        end
      else
        {:error, :checkpoint_parent_mismatch}
      end
    end
  end

  defp swap(store, kind, record, current) do
    cond do
      # An exact replay of the installed head is a no-op, so a retry after a
      # durability-uncertain write converges instead of failing.
      secure_equal(record.checkpoint_hash, current.checkpoint_hash) ->
        {:ok, current}

      not secure_equal(record.parent_hash, current.checkpoint_hash) ->
        {:error, :checkpoint_parent_mismatch}

      true ->
        case write_head(store, kind, record) do
          :ok -> {:ok, record}
          {:error, _reason} = error -> error
        end
    end
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
      not secure_equal(Map.get(attrs, :device_id), store.device_id) -> {:error, :device_mismatch}
      Map.get(attrs, :credential_epoch) !== store.credential_epoch -> {:error, :credential_epoch_mismatch}
      not secure_equal(Map.get(attrs, :storage_epoch), store.storage_epoch) -> {:error, :storage_epoch_mismatch}
      true -> :ok
    end
  end

  defp match_presented_hash(record, attrs) do
    if secure_equal(record.checkpoint_hash, Map.get(attrs, :checkpoint_hash)),
      do: :ok,
      else: {:error, :checkpoint_hash_mismatch}
  end

  defp read_head(store, kind) do
    case store.file_system.read(head_path(store, kind)) do
      {:ok, bytes} -> decode_and_fence(store, bytes)
      {:error, :enoent} -> :empty
      {:error, _reason} -> {:error, :corrupt_checkpoint_head}
      _other -> {:error, :corrupt_checkpoint_head}
    end
  end

  # Identity is checked AFTER decoding, so a record persisted by another
  # incarnation is reported as the specific mismatch rather than as corruption —
  # the bytes are intact and must be preserved, not quarantined.
  defp decode_and_fence(store, bytes) do
    with {:ok, record} <- Record.decode(bytes) do
      cond do
        not secure_equal(record.device_id, store.device_id) ->
          {:error, :device_mismatch}

        record.local_credential_epoch !== store.credential_epoch ->
          {:error, :credential_epoch_mismatch}

        not secure_equal(record.local_storage_epoch, store.storage_epoch) ->
          {:error, :storage_epoch_mismatch}

        true ->
          {:ok, record}
      end
    end
  end

  defp write_head(store, kind, record) do
    with {:ok, bytes} <- Record.encode(record) do
      AtomicFile.write(head_path(store, kind), bytes, atomic_opts(store))
    end
  end

  defp atomic_opts(store) do
    [
      file_system: store.file_system,
      fault_injector: store.fault_injector,
      temp_suffix: store.temp_suffix,
      directory_root: store.base_dir
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp known_kind(kind) do
    case Contract.checkpoint_kind(kind) do
      {:ok, _code, _schema_version} -> {:ok, kind}
      {:error, _reason} -> {:error, :unknown_checkpoint_kind}
    end
  end

  defp base_dir(value) when is_binary(value) and value != "", do: {:ok, Path.expand(value)}
  defp base_dir(_value), do: {:error, :invalid_base_dir}

  defp device_id(<<0::size(@device_id_size * 8)>>), do: {:error, :invalid_device_id}
  defp device_id(<<value::binary-size(@device_id_size)>>), do: {:ok, value}
  defp device_id(_value), do: {:error, :invalid_device_id}

  defp credential_epoch(value) when is_integer(value) and value >= 0 and value <= @u32_max, do: {:ok, value}
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
