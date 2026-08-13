defmodule RacingOrg.Tracker.Pro.DurableDelivery.Producer.DataSet do
  @moduledoc """
  Durably admits an existing encoded DataSet before its producer accepts it.

  The encoded protobuf bytes are passed to the Outbox unchanged. Admission is
  complete only when the Outbox confirms its `:telemetry` append; transport
  success is outside this boundary and never retires the durable entry.
  """

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner

  @entry_id_domain "RacingOrg-DurableDataSet-v1"
  @max_source_id_bytes 65_535

  @type receipt :: Owner.receipt()

  @doc "Durably append exact encoded DataSet bytes to the telemetry stream."
  @spec admit(binary(), keyword()) :: {:ok, receipt()} | {:error, term()}
  def admit(encoded_data_set, opts)

  def admit(encoded_data_set, opts) when is_binary(encoded_data_set) and is_list(opts) do
    with :ok <- validate_options(opts),
         :ok <- validate_encoded_data_set(encoded_data_set),
         {:ok, outbox} <- fetch_option(opts, :outbox, :outbox_required),
         {:ok, source_id} <- source_id(opts),
         {:ok, adapter} <- adapter(opts) do
      call_adapter(adapter, outbox, encoded_data_set, source_id)
    end
  end

  def admit(_encoded_data_set, _opts), do: {:error, :invalid_options}

  defp validate_options(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, :invalid_options}
  end

  defp validate_encoded_data_set(encoded_data_set) when byte_size(encoded_data_set) > 0, do: :ok
  defp validate_encoded_data_set(_encoded_data_set), do: {:error, :invalid_encoded_data_set}

  defp source_id(opts) do
    with {:ok, source_id} <- fetch_option(opts, :source_id, :source_id_required),
         true <- is_binary(source_id) and byte_size(source_id) in 1..@max_source_id_bytes do
      {:ok, source_id}
    else
      false -> {:error, :invalid_source_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp adapter(opts) do
    case Keyword.get(opts, :adapter, Owner) do
      module when is_atom(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, :enqueue, 4),
          do: {:ok, module},
          else: {:error, :invalid_adapter}

      _invalid ->
        {:error, :invalid_adapter}
    end
  end

  defp call_adapter(adapter, outbox, encoded_data_set, source_id) do
    adapter.enqueue(outbox, :telemetry, encoded_data_set,
      entry_id: :crypto.hash(:sha256, [@entry_id_domain, source_id])
    )
    |> validate_admission_result()
  rescue
    _exception -> {:error, :outbox_adapter_failure}
  catch
    kind, _reason when kind in [:throw, :exit] -> {:error, :outbox_adapter_failure}
  end

  defp validate_admission_result(
         {:ok,
          %{
            stream: :telemetry,
            device_id: <<_::128>>,
            credential_epoch: credential_epoch,
            storage_epoch: <<_::128>>,
            sequence: sequence,
            payload_hash: <<_::256>>,
            cumulative_sequence: cumulative_sequence
          } = receipt}
       )
       when is_integer(credential_epoch) and credential_epoch >= 0 and is_integer(sequence) and sequence > 0 and
              is_integer(cumulative_sequence) and cumulative_sequence >= 0,
       do: {:ok, receipt}

  defp validate_admission_result({:error, _reason} = error), do: error
  defp validate_admission_result(_other), do: {:error, :invalid_outbox_response}

  defp fetch_option(opts, key, missing_error) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, missing_error}
    end
  end
end
