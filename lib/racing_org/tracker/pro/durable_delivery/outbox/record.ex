defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Record do
  @moduledoc """
  Versioned binary codec for durable outbox entry and resolution records.

  Sequence numbers use a canonical positive signed-bigint representation rather
  than a fixed-width machine integer. A guarded outer length distinguishes an
  incomplete final append from a corrupt framing header. Every complete record
  carries a SHA-256 checksum over its semantic fields.
  """

  import Bitwise

  @magic "RODO"
  @version 1
  @header_size 14
  @checksum_size 32
  @max_body_size 64 * 1_024 * 1_024
  @max_reason_size 4_096
  @checksum_domain "RacingOrg-DurableOutboxRecordChecksum-v1"

  @kind_codes %{entry: 1, acknowledgement: 2, loss_authorization: 3}
  @code_kinds Map.new(@kind_codes, fn {kind, code} -> {code, kind} end)

  @type entry_record :: %{
          required(:kind) => :entry,
          required(:stream) => binary(),
          required(:storage_epoch) => <<_::128>>,
          required(:sequence) => pos_integer(),
          required(:entry_id) => binary(),
          required(:payload_hash) => <<_::256>>,
          required(:payload) => binary(),
          required(:priority) => 0..255
        }

  @type acknowledgement_record :: %{
          required(:kind) => :acknowledgement,
          required(:stream) => binary(),
          required(:storage_epoch) => <<_::128>>,
          required(:sequence) => pos_integer(),
          required(:payload_hash) => <<_::256>>,
          required(:cumulative_sequence) => non_neg_integer()
        }

  @type loss_authorization_record :: %{
          required(:kind) => :loss_authorization,
          required(:stream) => binary(),
          required(:storage_epoch) => <<_::128>>,
          required(:sequence) => pos_integer(),
          required(:entry_id) => binary(),
          required(:payload_hash) => <<_::256>>,
          required(:reason) => binary()
        }

  @type t :: entry_record() | acknowledgement_record() | loss_authorization_record()

  @doc "Encode one complete, checksummed record."
  @spec encode(map()) :: {:ok, binary()} | {:error, atom()}
  def encode(%{kind: :entry} = record), do: encode_entry(record)
  def encode(%{kind: :acknowledgement} = record), do: encode_acknowledgement(record)
  def encode(%{kind: :loss_authorization} = record), do: encode_loss_authorization(record)
  def encode(_record), do: {:error, :invalid_record_kind}

  @doc "Decode the first record, preserving any following bytes."
  @spec decode_next(binary()) ::
          {:ok, t(), binary(), pos_integer()}
          | {:incomplete, pos_integer()}
          | {:error, atom()}
  def decode_next(binary) when is_binary(binary) and byte_size(binary) < @header_size,
    do: {:incomplete, @header_size}

  def decode_next(<<magic::binary-size(4), version, kind_code, body_length::32, length_guard::32, rest::binary>>) do
    with :ok <- validate_magic(magic),
         :ok <- validate_version(version),
         {:ok, kind} <- decode_kind(kind_code),
         :ok <- validate_length_guard(body_length, length_guard),
         :ok <- validate_body_length(body_length) do
      total_size = @header_size + body_length

      if byte_size(rest) < body_length do
        {:incomplete, total_size}
      else
        <<body::binary-size(body_length), trailing::binary>> = rest

        with {:ok, record} <- decode_body(kind, kind_code, body) do
          {:ok, record, trailing, total_size}
        end
      end
    end
  end

  def decode_next(_binary), do: {:error, :invalid_record}

  @doc false
  @spec version() :: pos_integer()
  def version, do: @version

  defp encode_entry(record) do
    with {:ok, stream} <- required_stream(record),
         {:ok, storage_epoch} <- required_storage_epoch(record),
         {:ok, sequence_bytes} <- required_positive_sequence(record),
         {:ok, entry_id} <- required_entry_id(record),
         {:ok, payload} <- required_binary(record, :payload, :invalid_payload),
         {:ok, payload_hash} <- required_hash(record),
         :ok <- validate_payload_hash(payload, payload_hash),
         {:ok, priority} <- required_priority(record) do
      prefix =
        encode_sized(stream) <>
          storage_epoch <>
          encode_sized(sequence_bytes) <>
          encode_sized(entry_id) <>
          payload_hash <>
          <<byte_size(payload)::64>>

      kind_code = Map.fetch!(@kind_codes, :entry)
      checksum = checksum(kind_code, [prefix, payload, <<priority>>])
      encode_framed(kind_code, [prefix, checksum, payload, <<priority>>])
    end
  end

  defp encode_acknowledgement(record) do
    with {:ok, stream} <- required_stream(record),
         {:ok, storage_epoch} <- required_storage_epoch(record),
         {:ok, sequence_bytes} <- required_positive_sequence(record),
         {:ok, payload_hash} <- required_hash(record),
         {:ok, cumulative_bytes} <- required_nonnegative_sequence(record, :cumulative_sequence) do
      prefix =
        encode_sized(stream) <>
          storage_epoch <>
          encode_sized(sequence_bytes) <>
          payload_hash <>
          encode_sized(cumulative_bytes)

      kind_code = Map.fetch!(@kind_codes, :acknowledgement)
      encode_framed(kind_code, [prefix, checksum(kind_code, prefix)])
    end
  end

  defp encode_loss_authorization(record) do
    with {:ok, stream} <- required_stream(record),
         {:ok, storage_epoch} <- required_storage_epoch(record),
         {:ok, sequence_bytes} <- required_positive_sequence(record),
         {:ok, entry_id} <- required_entry_id(record),
         {:ok, payload_hash} <- required_hash(record),
         {:ok, reason} <- required_reason(record) do
      prefix =
        encode_sized(stream) <>
          storage_epoch <>
          encode_sized(sequence_bytes) <>
          encode_sized(entry_id) <>
          payload_hash <>
          <<byte_size(reason)::16>>

      kind_code = Map.fetch!(@kind_codes, :loss_authorization)
      encode_framed(kind_code, [prefix, checksum(kind_code, [prefix, reason]), reason])
    end
  end

  defp encode_framed(kind_code, body_iodata) do
    body = IO.iodata_to_binary(body_iodata)
    body_length = byte_size(body)

    if body_length <= @max_body_size do
      length_guard = bxor(body_length, 0xFFFFFFFF)
      {:ok, <<@magic, @version, kind_code, body_length::32, length_guard::32, body::binary>>}
    else
      {:error, :record_too_large}
    end
  end

  defp decode_body(:entry, kind_code, body) do
    with {:ok, stream, rest} <- take_sized(body),
         :ok <- validate_stream(stream),
         {:ok, storage_epoch, rest} <- take_fixed(rest, 16),
         :ok <- validate_storage_epoch(storage_epoch),
         {:ok, sequence_bytes, rest} <- take_sized(rest),
         {:ok, sequence} <- decode_positive_signed(sequence_bytes),
         {:ok, entry_id, rest} <- take_sized(rest),
         :ok <- validate_entry_id(entry_id),
         {:ok, payload_hash, rest} <- take_fixed(rest, 32),
         {:ok, payload_length, rest} <- take_u64(rest),
         {:ok, stored_checksum, rest} <- take_fixed(rest, @checksum_size),
         {:ok, payload, priority} <- take_payload_and_priority(rest, payload_length),
         :ok <- validate_priority(priority) do
      prefix =
        encode_sized(stream) <>
          storage_epoch <>
          encode_sized(sequence_bytes) <>
          encode_sized(entry_id) <>
          payload_hash <>
          <<payload_length::64>>

      with :ok <- validate_checksum(stored_checksum, checksum(kind_code, [prefix, payload, <<priority>>])),
           :ok <- validate_payload_hash(payload, payload_hash) do
        {:ok,
         %{
           kind: :entry,
           stream: stream,
           storage_epoch: storage_epoch,
           sequence: sequence,
           entry_id: entry_id,
           payload_hash: payload_hash,
           payload: payload,
           priority: priority
         }}
      end
    end
  end

  defp decode_body(:acknowledgement, kind_code, body) do
    with {:ok, stream, rest} <- take_sized(body),
         :ok <- validate_stream(stream),
         {:ok, storage_epoch, rest} <- take_fixed(rest, 16),
         :ok <- validate_storage_epoch(storage_epoch),
         {:ok, sequence_bytes, rest} <- take_sized(rest),
         {:ok, sequence} <- decode_positive_signed(sequence_bytes),
         {:ok, payload_hash, rest} <- take_fixed(rest, 32),
         {:ok, cumulative_bytes, rest} <- take_sized(rest),
         {:ok, cumulative_sequence} <- decode_nonnegative_signed(cumulative_bytes),
         {:ok, stored_checksum, <<>>} <- take_fixed(rest, @checksum_size) do
      prefix =
        encode_sized(stream) <>
          storage_epoch <>
          encode_sized(sequence_bytes) <>
          payload_hash <>
          encode_sized(cumulative_bytes)

      with :ok <- validate_checksum(stored_checksum, checksum(kind_code, prefix)) do
        {:ok,
         %{
           kind: :acknowledgement,
           stream: stream,
           storage_epoch: storage_epoch,
           sequence: sequence,
           payload_hash: payload_hash,
           cumulative_sequence: cumulative_sequence
         }}
      end
    else
      {:ok, _checksum, _trailing} -> {:error, :trailing_record_bytes}
      error -> error
    end
  end

  defp decode_body(:loss_authorization, kind_code, body) do
    with {:ok, stream, rest} <- take_sized(body),
         :ok <- validate_stream(stream),
         {:ok, storage_epoch, rest} <- take_fixed(rest, 16),
         :ok <- validate_storage_epoch(storage_epoch),
         {:ok, sequence_bytes, rest} <- take_sized(rest),
         {:ok, sequence} <- decode_positive_signed(sequence_bytes),
         {:ok, entry_id, rest} <- take_sized(rest),
         :ok <- validate_entry_id(entry_id),
         {:ok, payload_hash, rest} <- take_fixed(rest, 32),
         {:ok, reason_length, rest} <- take_u16(rest),
         :ok <- validate_reason_length(reason_length),
         {:ok, stored_checksum, rest} <- take_fixed(rest, @checksum_size),
         {:ok, reason, <<>>} <- take_fixed(rest, reason_length),
         :ok <- validate_reason(reason) do
      prefix =
        encode_sized(stream) <>
          storage_epoch <>
          encode_sized(sequence_bytes) <>
          encode_sized(entry_id) <>
          payload_hash <>
          <<reason_length::16>>

      with :ok <- validate_checksum(stored_checksum, checksum(kind_code, [prefix, reason])) do
        {:ok,
         %{
           kind: :loss_authorization,
           stream: stream,
           storage_epoch: storage_epoch,
           sequence: sequence,
           entry_id: entry_id,
           payload_hash: payload_hash,
           reason: reason
         }}
      end
    else
      {:ok, _reason, _trailing} -> {:error, :trailing_record_bytes}
      error -> error
    end
  end

  defp required_stream(record) do
    with {:ok, stream} <- fetch(record, :stream, :invalid_stream),
         :ok <- validate_stream(stream) do
      {:ok, stream}
    end
  end

  defp required_storage_epoch(record) do
    with {:ok, storage_epoch} <- fetch(record, :storage_epoch, :invalid_storage_epoch),
         :ok <- validate_storage_epoch(storage_epoch) do
      {:ok, storage_epoch}
    end
  end

  defp required_positive_sequence(record) do
    with {:ok, sequence} <- fetch(record, :sequence, :invalid_sequence),
         {:ok, bytes} <- encode_positive_signed(sequence),
         true <- byte_size(bytes) <= 65_535 do
      {:ok, bytes}
    else
      false -> {:error, :invalid_sequence}
      error -> error
    end
  end

  defp required_nonnegative_sequence(record, field) do
    with {:ok, sequence} <- fetch(record, field, :invalid_cumulative_sequence),
         {:ok, bytes} <- encode_nonnegative_signed(sequence),
         true <- byte_size(bytes) <= 65_535 do
      {:ok, bytes}
    else
      false -> {:error, :invalid_cumulative_sequence}
      error -> error
    end
  end

  defp required_entry_id(record) do
    with {:ok, entry_id} <- fetch(record, :entry_id, :invalid_entry_id),
         :ok <- validate_entry_id(entry_id) do
      {:ok, entry_id}
    end
  end

  defp required_hash(record) do
    with {:ok, hash} <- fetch(record, :payload_hash, :invalid_payload_hash),
         :ok <- validate_hash(hash) do
      {:ok, hash}
    end
  end

  defp required_priority(record) do
    with {:ok, priority} <- fetch(record, :priority, :invalid_priority),
         :ok <- validate_priority(priority) do
      {:ok, priority}
    end
  end

  defp required_reason(record) do
    with {:ok, reason} <- fetch(record, :reason, :invalid_loss_reason),
         :ok <- validate_reason(reason) do
      {:ok, reason}
    end
  end

  defp required_binary(record, field, error) do
    case Map.fetch(record, field) do
      {:ok, binary} when is_binary(binary) -> {:ok, binary}
      _other -> {:error, error}
    end
  end

  defp fetch(record, field, error) do
    case Map.fetch(record, field) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, error}
    end
  end

  defp validate_magic(@magic), do: :ok
  defp validate_magic(_magic), do: {:error, :invalid_magic}

  defp validate_version(@version), do: :ok
  defp validate_version(_version), do: {:error, :unsupported_record_version}

  defp decode_kind(code) do
    case Map.fetch(@code_kinds, code) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, :invalid_record_kind}
    end
  end

  defp validate_length_guard(body_length, length_guard) do
    if bxor(body_length, length_guard) == 0xFFFFFFFF,
      do: :ok,
      else: {:error, :invalid_length_guard}
  end

  defp validate_body_length(length) when length <= @max_body_size, do: :ok
  defp validate_body_length(_length), do: {:error, :record_too_large}

  defp validate_stream(stream)
       when is_binary(stream) and byte_size(stream) > 0 and byte_size(stream) <= 65_535 do
    if String.valid?(stream), do: :ok, else: {:error, :invalid_stream}
  end

  defp validate_stream(_stream), do: {:error, :invalid_stream}

  defp validate_storage_epoch(<<_::128>>), do: :ok
  defp validate_storage_epoch(_storage_epoch), do: {:error, :invalid_storage_epoch}

  defp validate_entry_id(entry_id)
       when is_binary(entry_id) and byte_size(entry_id) > 0 and byte_size(entry_id) <= 65_535,
       do: :ok

  defp validate_entry_id(_entry_id), do: {:error, :invalid_entry_id}

  defp validate_hash(<<_::256>>), do: :ok
  defp validate_hash(_hash), do: {:error, :invalid_payload_hash}

  defp validate_payload_hash(payload, expected) do
    if :crypto.hash(:sha256, payload) == expected,
      do: :ok,
      else: {:error, :payload_hash_mismatch}
  end

  defp validate_priority(priority) when is_integer(priority) and priority in 0..255, do: :ok
  defp validate_priority(_priority), do: {:error, :invalid_priority}

  defp validate_reason(reason)
       when is_binary(reason) and byte_size(reason) > 0 and byte_size(reason) <= @max_reason_size do
    if String.valid?(reason), do: :ok, else: {:error, :invalid_loss_reason}
  end

  defp validate_reason(_reason), do: {:error, :invalid_loss_reason}

  defp validate_reason_length(length) when length > 0 and length <= @max_reason_size, do: :ok
  defp validate_reason_length(_length), do: {:error, :invalid_loss_reason}

  defp validate_checksum(checksum, checksum), do: :ok
  defp validate_checksum(_stored, _expected), do: {:error, :checksum_mismatch}

  defp checksum(kind_code, contents) do
    :crypto.hash(:sha256, [@checksum_domain, <<@version, kind_code>>, contents])
  end

  defp encode_sized(binary), do: <<byte_size(binary)::16, binary::binary>>

  defp encode_positive_signed(value) when is_integer(value) and value > 0 do
    {:ok, signed_bytes(value)}
  end

  defp encode_positive_signed(_value), do: {:error, :invalid_sequence}

  defp encode_nonnegative_signed(value) when is_integer(value) and value >= 0 do
    {:ok, signed_bytes(value)}
  end

  defp encode_nonnegative_signed(_value), do: {:error, :invalid_cumulative_sequence}

  defp signed_bytes(0), do: <<0>>

  defp signed_bytes(value) do
    unsigned = :binary.encode_unsigned(value)
    <<first, _rest::binary>> = unsigned
    if band(first, 0x80) == 0, do: unsigned, else: <<0, unsigned::binary>>
  end

  defp decode_positive_signed(bytes) do
    with {:ok, value} <- decode_signed(bytes),
         true <- value > 0 do
      {:ok, value}
    else
      false -> {:error, :invalid_sequence}
      error -> error
    end
  end

  defp decode_nonnegative_signed(bytes), do: decode_signed(bytes)

  defp decode_signed(<<>>), do: {:error, :invalid_sequence_encoding}
  defp decode_signed(<<first, _rest::binary>>) when band(first, 0x80) != 0, do: {:error, :negative_sequence}

  defp decode_signed(<<0, second, _rest::binary>>) when band(second, 0x80) == 0,
    do: {:error, :noncanonical_sequence}

  defp decode_signed(bytes), do: {:ok, :binary.decode_unsigned(bytes)}

  defp take_sized(binary) do
    with {:ok, size, rest} <- take_u16(binary),
         {:ok, value, trailing} <- take_fixed(rest, size) do
      {:ok, value, trailing}
    end
  end

  defp take_u16(<<value::16, rest::binary>>), do: {:ok, value, rest}
  defp take_u16(_binary), do: {:error, :invalid_record_body}

  defp take_u64(<<value::64, rest::binary>>), do: {:ok, value, rest}
  defp take_u64(_binary), do: {:error, :invalid_record_body}

  defp take_fixed(binary, size) when byte_size(binary) >= size do
    <<value::binary-size(size), rest::binary>> = binary
    {:ok, value, rest}
  end

  defp take_fixed(_binary, _size), do: {:error, :invalid_record_body}

  defp take_payload_and_priority(rest, payload_length) when byte_size(rest) == payload_length + 1 do
    <<payload::binary-size(payload_length), priority>> = rest
    {:ok, payload, priority}
  end

  defp take_payload_and_priority(_rest, _payload_length), do: {:error, :invalid_payload_length}
end
