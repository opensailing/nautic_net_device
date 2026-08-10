defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record do
  @moduledoc """
  One exact, self-verifying local checkpoint-head record.

  A record is the tracker's durable claim about the latest checkpoint for one
  kind. It carries three independent hashes, each over a distinct preimage:

    * `content_hash` — the frozen `DesiredStateV1.Checkpoint` content-hash domain
      over the exact canonical content bytes. Content validity is decided by the
      closed per-kind schema, never by an opaque byte blob.

    * `checkpoint_hash` — the frozen `DesiredStateV1.Checkpoint` record-hash
      domain. This is the value the backend's parent-hash compare-and-swap
      compares against, so it MUST commit to the ORIGIN identity (the credential
      and storage epoch under which the checkpoint was produced or accepted) and
      never to whatever identity happens to hold the device today. A record
      hydrated after credential rotation keeps its original record hash, which is
      what makes a hydrated head a legal parent for the next local write.

    * `binding_hash` — a LOCAL-only hash under this module's own domain, binding
      the record hash to the exact device, current credential epoch, current
      storage epoch, and acceptance flag that the local store is fenced to. It
      never leaves the device and is never a wire value. Its purpose is reopen
      validation: a head file moved between devices, surviving a credential
      rotation, or relabelled from local to accepted fails to re-derive.

  Because the record hash and the binding hash have different preimages, a record
  cannot be relabelled `accepted` without breaking the binding, and cannot be
  reused under a different local identity without breaking it either — while the
  record hash itself stays stable across rotation so chain continuity survives.

  The canonical content BYTES are the durable payload; the decoded map is never
  persisted. Reopen re-derives all three hashes from those bytes and the record's
  own fields, so any edit under intact framing fails closed as corruption.

  Nothing here admits a secret: content is rejected by the contract's
  secret-capable key screen before it may be hashed, and the record carries no
  free-form metadata field into which one could be smuggled.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint

  @format_version 1
  @record_tag :checkpoint_head
  @binding_domain "RacingOrg-TrackerCheckpointHeadBinding-v1"
  @binding_version 1

  @device_id_size 16
  @storage_epoch_size 16
  @hash_size 32
  @u32_max 0xFFFF_FFFF
  @database_int_max 9_223_372_036_854_775_807
  @genesis_parent <<0::256>>
  @max_encoded_size Contract.max_checkpoint_size() + 4_096

  @build_keys [
    :device_id,
    :local_credential_epoch,
    :local_storage_epoch,
    :origin_credential_epoch,
    :origin_storage_epoch,
    :sequence,
    :kind,
    :schema_version,
    :source_generation,
    :parent_hash,
    :content,
    :accepted
  ]

  @record_keys [
    :device_id,
    :local_credential_epoch,
    :local_storage_epoch,
    :origin_credential_epoch,
    :origin_storage_epoch,
    :sequence,
    :kind,
    :schema_version,
    :source_generation,
    :parent_hash,
    :content,
    :content_hash,
    :checkpoint_hash,
    :binding_hash,
    :accepted
  ]

  @type t :: %{
          device_id: <<_::128>>,
          local_credential_epoch: non_neg_integer(),
          local_storage_epoch: <<_::128>>,
          origin_credential_epoch: non_neg_integer(),
          origin_storage_epoch: <<_::128>>,
          sequence: pos_integer(),
          kind: atom(),
          schema_version: pos_integer(),
          source_generation: non_neg_integer(),
          parent_hash: <<_::256>>,
          content: binary(),
          content_hash: <<_::256>>,
          checkpoint_hash: <<_::256>>,
          binding_hash: <<_::256>>,
          accepted: boolean()
        }

  @doc """
  The parent hash a first record in a chain must present.

  All-zero is not a reachable SHA-256 record hash in practice, and the frozen
  wire contract already accepts it as the root parent, so the local chain uses
  the same value rather than minting a second convention.
  """
  @spec genesis_parent() :: <<_::256>>
  def genesis_parent, do: @genesis_parent

  @doc "The persisted format version; bumping it retires every older head file."
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc false
  @spec max_encoded_size() :: pos_integer()
  def max_encoded_size, do: @max_encoded_size

  @doc """
  Build one complete record, validating the closed kind/schema/content registry
  and deriving all three hashes.

  `:content` may be the decoded content map or the exact canonical bytes; either
  way the stored payload is the canonical bytes and non-canonical bytes are
  rejected rather than silently re-encoded.
  """
  @spec build(map()) :: {:ok, t()} | {:error, atom()}
  def build(attrs) when is_map(attrs) do
    with :ok <- exact_keys(attrs, @build_keys),
         :ok <- fixed_binary(attrs.device_id, @device_id_size, :invalid_device_id),
         :ok <- u32(attrs.local_credential_epoch, :invalid_credential_epoch),
         :ok <- u32(attrs.origin_credential_epoch, :invalid_credential_epoch),
         :ok <- nonzero_binary(attrs.local_storage_epoch, :invalid_storage_epoch),
         :ok <- nonzero_binary(attrs.origin_storage_epoch, :invalid_storage_epoch),
         :ok <- positive_database_int(attrs.sequence, :invalid_delivery_sequence),
         :ok <- database_int(attrs.source_generation, :invalid_source_generation),
         :ok <- fixed_binary(attrs.parent_hash, @hash_size, :invalid_parent_hash),
         :ok <- boolean(attrs.accepted, :invalid_acceptance),
         {:ok, content} <- canonical_content(attrs.kind, attrs.schema_version, attrs.content),
         {:ok, content_hash} <- Checkpoint.content_hash(attrs.kind, attrs.schema_version, content),
         {:ok, checkpoint_hash} <- record_hash(attrs, content_hash) do
      record =
        %{
          device_id: attrs.device_id,
          local_credential_epoch: attrs.local_credential_epoch,
          local_storage_epoch: attrs.local_storage_epoch,
          origin_credential_epoch: attrs.origin_credential_epoch,
          origin_storage_epoch: attrs.origin_storage_epoch,
          sequence: attrs.sequence,
          kind: attrs.kind,
          schema_version: attrs.schema_version,
          source_generation: attrs.source_generation,
          parent_hash: attrs.parent_hash,
          content: content,
          content_hash: content_hash,
          checkpoint_hash: checkpoint_hash,
          accepted: attrs.accepted
        }

      {:ok, Map.put(record, :binding_hash, binding_hash(record))}
    end
  end

  def build(_attrs), do: {:error, :invalid_checkpoint_record}

  @doc "Serialize one already-built record for durable storage."
  @spec encode(t()) :: {:ok, binary()} | {:error, atom()}
  def encode(record) when is_map(record) do
    with :ok <- exact_keys(record, @record_keys),
         :ok <- verify(record),
         bytes = :erlang.term_to_binary({@format_version, @record_tag, record}),
         true <- byte_size(bytes) <= @max_encoded_size do
      {:ok, bytes}
    else
      false -> {:error, :checkpoint_head_too_large}
      {:error, _reason} = error -> error
    end
  end

  def encode(_record), do: {:error, :invalid_checkpoint_record}

  @doc """
  Decode and completely revalidate one persisted record.

  Every hash is re-derived from the canonical content bytes and the record's own
  fields, so an edit that survives the term framing still fails here. Any
  failure — framing, schema, content, or hash — is reported as the single opaque
  `:corrupt_checkpoint_head`, so a caller cannot use the error shape to
  distinguish a tampering strategy.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, :corrupt_checkpoint_head}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_encoded_size do
    with {@format_version, @record_tag, record} when is_map(record) <- safe_term(bytes),
         :ok <- exact_keys(record, @record_keys),
         :ok <- verify(record) do
      {:ok, record}
    else
      _other -> {:error, :corrupt_checkpoint_head}
    end
  end

  def decode(_bytes), do: {:error, :corrupt_checkpoint_head}

  @doc """
  Re-derive and compare every hash on one record.

  Public so a store can revalidate an in-memory record without a serialization
  round trip.
  """
  @spec verify(map()) :: :ok | {:error, atom()}
  def verify(record) when is_map(record) do
    with :ok <- exact_keys(record, @record_keys),
         {:ok, rebuilt} <- build(Map.take(record, @build_keys)) do
      if secure_equal(rebuilt.content_hash, Map.get(record, :content_hash)) and
           secure_equal(rebuilt.checkpoint_hash, Map.get(record, :checkpoint_hash)) and
           secure_equal(rebuilt.binding_hash, Map.get(record, :binding_hash)) and
           rebuilt.content == Map.get(record, :content) do
        :ok
      else
        {:error, :corrupt_checkpoint_head}
      end
    else
      _error -> {:error, :corrupt_checkpoint_head}
    end
  end

  def verify(_record), do: {:error, :corrupt_checkpoint_head}

  @doc "Whether one record's local binding matches an exact current identity."
  @spec bound_to?(map(), map()) :: boolean()
  def bound_to?(record, identity) when is_map(record) and is_map(identity) do
    secure_equal(Map.get(record, :device_id), Map.get(identity, :device_id)) and
      Map.get(record, :local_credential_epoch) === Map.get(identity, :credential_epoch) and
      secure_equal(Map.get(record, :local_storage_epoch), Map.get(identity, :storage_epoch))
  end

  def bound_to?(_record, _identity), do: false

  defp record_hash(attrs, content_hash) do
    Checkpoint.hash(%{
      device_id: attrs.device_id,
      credential_epoch: attrs.origin_credential_epoch,
      storage_epoch: attrs.origin_storage_epoch,
      sequence: attrs.sequence,
      kind: attrs.kind,
      schema_version: attrs.schema_version,
      source_generation: attrs.source_generation,
      parent_hash: attrs.parent_hash,
      content_hash: content_hash
    })
  end

  defp binding_hash(record) do
    accepted = if record.accepted, do: 1, else: 0

    :crypto.hash(
      :sha256,
      @binding_domain <>
        <<@binding_version, Contract.version(), record.device_id::binary-size(@device_id_size),
          record.local_credential_epoch::32, record.local_storage_epoch::binary-size(@storage_epoch_size), accepted,
          record.checkpoint_hash::binary-size(@hash_size)>>
    )
  end

  # Content arrives either decoded or already canonical. Both paths end at the
  # same canonical bytes, and a byte input that is not already canonical is
  # rejected rather than re-encoded, so the caller's bytes and the stored bytes
  # are always identical.
  defp canonical_content(kind, schema_version, content) when is_binary(content) do
    with {:ok, decoded} <- normalize_content_error(Checkpoint.decode_content(kind, schema_version, content)),
         {:ok, canonical} <- normalize_content_error(Checkpoint.encode_content(kind, schema_version, decoded)) do
      if canonical == content, do: {:ok, canonical}, else: {:error, :noncanonical_checkpoint_content}
    end
  end

  defp canonical_content(kind, schema_version, content) when is_map(content),
    do: normalize_content_error(Checkpoint.encode_content(kind, schema_version, content))

  defp canonical_content(kind, schema_version, _content) do
    case Contract.checkpoint_kind(kind) do
      {:ok, _code, ^schema_version} -> {:error, :invalid_checkpoint_content}
      {:ok, _code, _expected} -> {:error, :unsupported_checkpoint_schema}
      {:error, _reason} = error -> error
    end
  end

  # The canonical codec reports many distinct parse faults. A checkpoint-head
  # caller acts on none of them individually, so they collapse into one closed
  # typed set. Only the verdicts a caller must distinguish survive: an unknown
  # kind, an unregistered schema, a secret-capable shape, a value that exceeds
  # single-frame capacity, and a value that decodes but is not canonical.
  @preserved_content_errors [
    :unknown_checkpoint_kind,
    :unsupported_checkpoint_schema,
    :checkpoint_secret_forbidden,
    :checkpoint_too_large,
    :noncanonical_checkpoint_content
  ]

  defp normalize_content_error({:ok, _value} = ok), do: ok

  defp normalize_content_error({:error, reason}) when reason in @preserved_content_errors,
    do: {:error, reason}

  defp normalize_content_error({:error, :trailing_bytes}), do: {:error, :noncanonical_checkpoint_content}
  defp normalize_content_error({:error, _reason}), do: {:error, :invalid_checkpoint_content}

  # `binary_to_term/2` ignores bytes after a complete term, so appended garbage
  # would otherwise decode successfully. `:used` makes that trailing input an
  # explicit failure.
  defp safe_term(<<131, 80, _compressed::binary>>), do: :corrupt

  defp safe_term(bytes) do
    case :erlang.binary_to_term(bytes, [:safe, :used]) do
      {term, used} when used == byte_size(bytes) -> term
      _partial -> :corrupt
    end
  rescue
    _exception -> :corrupt
  catch
    _kind, _reason -> :corrupt
  end

  defp exact_keys(value, expected) when is_map(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(expected),
      do: :ok,
      else: {:error, :invalid_checkpoint_record}
  end

  defp exact_keys(_value, _expected), do: {:error, :invalid_checkpoint_record}

  defp fixed_binary(value, size, _error) when is_binary(value) and byte_size(value) == size, do: :ok
  defp fixed_binary(_value, _size, error), do: {:error, error}

  defp nonzero_binary(value, error) do
    with :ok <- fixed_binary(value, @storage_epoch_size, error) do
      if value == <<0::size(@storage_epoch_size * 8)>>, do: {:error, error}, else: :ok
    end
  end

  defp u32(value, _error) when is_integer(value) and value >= 0 and value <= @u32_max, do: :ok
  defp u32(_value, error), do: {:error, error}

  defp database_int(value, _error) when is_integer(value) and value >= 0 and value <= @database_int_max, do: :ok
  defp database_int(_value, error), do: {:error, error}

  defp positive_database_int(value, _error) when is_integer(value) and value > 0 and value <= @database_int_max, do: :ok
  defp positive_database_int(_value, error), do: {:error, error}

  defp boolean(value, _error) when is_boolean(value), do: :ok
  defp boolean(_value, error), do: {:error, error}

  defp secure_equal(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_equal(_left, _right), do: false
end
