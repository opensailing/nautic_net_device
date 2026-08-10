defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Command do
  @moduledoc """
  Pure canonical hashing for Desired State v1 command delivery and acknowledgement records.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  @uuid_size 16
  @storage_epoch_size 16
  @hash_size 32
  @u32_max 0xFFFF_FFFF
  @database_int_max 9_223_372_036_854_775_807

  @command_hash_keys [
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :required_generation,
    :required_manifest_hash,
    :command_epoch,
    :command_sequence,
    :command_id,
    :expires_at_ms,
    :payload_hash
  ]
  @result_hash_keys [:status, :reason, :result]

  @doc "Compute the raw SHA-256 hash of one bounded command payload."
  def payload_hash(payload) when is_binary(payload) do
    if byte_size(payload) <= Contract.max_command_payload_size(),
      do: {:ok, :crypto.hash(:sha256, payload)},
      else: {:error, :command_payload_too_large}
  end

  def payload_hash(_payload), do: {:error, :invalid_command_payload}

  @doc "Compute the domain-separated canonical hash of one command-delivery record."
  def hash(attrs) when is_map(attrs) do
    with :ok <- exact_keys(attrs, @command_hash_keys, :invalid_command_record),
         {:ok, device_id} <- normalize_uuid(attrs.device_id, :invalid_device_id),
         :ok <- u32(attrs.credential_epoch, :invalid_credential_epoch),
         :ok <- nonzero_binary(attrs.storage_epoch, @storage_epoch_size, :invalid_storage_epoch),
         :ok <- positive_database_int(attrs.required_generation, :invalid_required_generation),
         :ok <- fixed_binary(attrs.required_manifest_hash, @hash_size, :invalid_required_manifest_hash),
         :ok <- u32(attrs.command_epoch, :invalid_command_epoch),
         :ok <- positive_database_int(attrs.command_sequence, :invalid_command_sequence),
         {:ok, command_id} <- normalize_uuid(attrs.command_id, :invalid_command_id),
         :ok <- database_int(attrs.expires_at_ms, :invalid_expires_at_ms),
         :ok <- fixed_binary(attrs.payload_hash, @hash_size, :invalid_payload_hash),
         {:ok, type_code, :server_to_device} <- Contract.message_type(:command_delivery) do
      preimage =
        Contract.command_record_hash_domain() <>
          <<Contract.version(), type_code, device_id::binary-size(@uuid_size), attrs.credential_epoch::32,
            attrs.storage_epoch::binary-size(@storage_epoch_size), attrs.required_generation::64,
            attrs.required_manifest_hash::binary-size(@hash_size), attrs.command_epoch::32, attrs.command_sequence::64,
            command_id::binary-size(@uuid_size), attrs.expires_at_ms::64, attrs.payload_hash::binary-size(@hash_size)>>

      {:ok, :crypto.hash(:sha256, preimage)}
    end
  end

  def hash(_attrs), do: {:error, :invalid_command_record}

  @doc "Compute the domain-separated canonical hash of one command acknowledgement result."
  def result_hash(attrs) when is_map(attrs) do
    with :ok <- exact_keys(attrs, @result_hash_keys, :invalid_command_result_record),
         {:ok, status_code} <- status_code(attrs.status),
         {:ok, reason_code} <- reason_code(attrs.reason),
         :ok <- status_reason(attrs.status, attrs.reason),
         :ok <- result_size(attrs.result) do
      preimage =
        Contract.command_result_hash_domain() <>
          <<Contract.version(), status_code, reason_code, byte_size(attrs.result)::32, attrs.result::binary>>

      {:ok, :crypto.hash(:sha256, preimage)}
    end
  end

  def result_hash(_attrs), do: {:error, :invalid_command_result_record}

  @doc false
  def normalize_uuid(<<uuid::binary-size(@uuid_size)>>, _error), do: {:ok, uuid}

  def normalize_uuid(
        <<a::binary-size(8), "-", b::binary-size(4), "-", c::binary-size(4), "-", d::binary-size(4), "-",
          e::binary-size(12)>>,
        error
      ) do
    case Base.decode16(a <> b <> c <> d <> e, case: :mixed) do
      {:ok, <<uuid::binary-size(@uuid_size)>>} -> {:ok, uuid}
      :error -> {:error, error}
    end
  end

  def normalize_uuid(_value, error), do: {:error, error}

  defp status_code(status) when is_atom(status) do
    case Contract.command_status(status) do
      {:ok, code} when is_integer(code) -> {:ok, code}
      {:error, _reason} = error -> error
    end
  end

  defp status_code(_status), do: {:error, :unknown_command_status}

  defp reason_code(reason) when is_atom(reason) do
    case Contract.command_reason(reason) do
      {:ok, code} when is_integer(code) -> {:ok, code}
      {:error, _reason} = error -> error
    end
  end

  defp reason_code(_reason), do: {:error, :unknown_command_reason}

  defp status_reason(status, :none) when status in [:applied, :duplicate], do: :ok
  defp status_reason(:rejected, reason) when reason != :none, do: :ok
  defp status_reason(_status, _reason), do: {:error, :invalid_command_status_reason}

  defp result_size(result) when is_binary(result) do
    if byte_size(result) <= Contract.max_command_result_size(),
      do: :ok,
      else: {:error, :command_result_too_large}
  end

  defp result_size(_result), do: {:error, :invalid_command_result}

  defp exact_keys(attrs, expected, error) do
    if Enum.sort(Map.keys(attrs)) == Enum.sort(expected), do: :ok, else: {:error, error}
  end

  defp fixed_binary(value, size, _error) when is_binary(value) and byte_size(value) == size,
    do: :ok

  defp fixed_binary(_value, _size, error), do: {:error, error}

  defp nonzero_binary(value, size, error) do
    with :ok <- fixed_binary(value, size, error),
         true <- value != :binary.copy(<<0>>, size) do
      :ok
    else
      false -> {:error, error}
      {:error, _reason} = failure -> failure
    end
  end

  defp u32(value, _error) when is_integer(value) and value >= 0 and value <= @u32_max, do: :ok
  defp u32(_value, error), do: {:error, error}

  defp database_int(value, _error)
       when is_integer(value) and value >= 0 and value <= @database_int_max,
       do: :ok

  defp database_int(_value, error), do: {:error, error}

  defp positive_database_int(value, _error)
       when is_integer(value) and value > 0 and value <= @database_int_max,
       do: :ok

  defp positive_database_int(_value, error), do: {:error, error}
end
