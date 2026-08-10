defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Receipt do
  @moduledoc """
  Canonical hash construction for one durable-delivery receipt.

  Receipt identity survives a reboot on unchanged storage, so it deliberately binds
  the storage epoch but not the transient boot ID.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  @device_id_size 16
  @storage_epoch_size 16
  @hash_size 32
  @u32_max 0xFFFF_FFFF
  @database_int_max 9_223_372_036_854_775_807
  @keys [
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :stream,
    :sequence,
    :payload_hash,
    :cumulative_sequence
  ]

  @doc "Compute the canonical SHA-256 receipt hash for exact validated fields."
  def hash(attrs) when is_map(attrs) do
    with :ok <- exact_keys(attrs),
         :ok <- fixed_binary(attrs.device_id, @device_id_size, :invalid_device_id),
         :ok <- u32(attrs.credential_epoch, :invalid_credential_epoch),
         :ok <- nonzero_binary(attrs.storage_epoch, @storage_epoch_size, :invalid_storage_epoch),
         {:ok, stream_code} <- delivery_stream_code(attrs.stream),
         :ok <- positive_database_int(attrs.sequence, :invalid_delivery_sequence),
         :ok <- fixed_binary(attrs.payload_hash, @hash_size, :invalid_payload_hash),
         :ok <- database_int(attrs.cumulative_sequence, :invalid_cumulative_sequence) do
      preimage =
        Contract.delivery_receipt_hash_domain() <>
          <<Contract.version(), attrs.device_id::binary-size(@device_id_size), attrs.credential_epoch::32,
            attrs.storage_epoch::binary-size(@storage_epoch_size), stream_code, attrs.sequence::64,
            attrs.payload_hash::binary-size(@hash_size), attrs.cumulative_sequence::64>>

      {:ok, :crypto.hash(:sha256, preimage)}
    end
  end

  def hash(_attrs), do: {:error, :invalid_delivery_receipt}

  defp exact_keys(attrs) do
    if Enum.sort(Map.keys(attrs)) == Enum.sort(@keys),
      do: :ok,
      else: {:error, :invalid_delivery_receipt}
  end

  defp delivery_stream_code(stream) when is_atom(stream) do
    case Contract.delivery_stream(stream) do
      {:ok, code} when is_integer(code) -> {:ok, code}
      {:error, _reason} = error -> error
    end
  end

  defp delivery_stream_code(_stream), do: {:error, :unknown_delivery_stream}

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
