defmodule RacingOrg.Tracker.Pro.DurableDelivery.Producer.HealthEvent do
  @moduledoc """
  Durably admits one exact validated tracker health-event payload.

  Acceptance is reported only after the Outbox has fsynced the canonical v1
  payload. The Outbox envelope supplies durable device, credential, storage,
  stream, sequence, and payload identity; a domain-separated payload digest
  selects the deterministic retry boundary.
  """

  alias RacingOrg.Tracker.Pro.DurableDelivery.HealthEvent.V1
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner

  @entry_id_domain "RacingOrg-TrackerHealthEventEntryId-v1"
  @u32_max 0xFFFF_FFFF
  @receipt_keys [
    :stream,
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :sequence,
    :payload_hash,
    :cumulative_sequence
  ]
  @zero_id <<0::128>>

  @type receipt :: Owner.receipt()

  @doc "Validate, encode, and durably admit one exact health event."
  @spec admit(term(), keyword()) :: {:ok, receipt()} | {:error, term()}
  def admit(health_event, opts)

  def admit(health_event, opts) when is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, payload} <- V1.encode(health_event),
         {:ok, outbox} <- fetch_option(opts, :outbox, :outbox_required),
         {:ok, adapter} <- adapter(opts) do
      call_adapter(adapter, outbox, payload)
    end
  end

  def admit(_health_event, _opts), do: {:error, :invalid_options}

  defp validate_options(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, :invalid_options}
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

  defp call_adapter(adapter, outbox, payload) do
    adapter.enqueue(outbox, :health, payload,
      entry_id: :crypto.hash(:sha256, [@entry_id_domain, :crypto.hash(:sha256, payload)])
    )
    |> validate_admission_result(payload)
  rescue
    _exception -> {:error, :outbox_adapter_failure}
  catch
    kind, _reason when kind in [:throw, :exit] -> {:error, :outbox_adapter_failure}
  end

  defp validate_admission_result({:ok, receipt}, payload) when is_map(receipt) do
    if exact_receipt?(receipt, payload), do: {:ok, receipt}, else: {:error, :invalid_outbox_response}
  end

  defp validate_admission_result({:error, _reason} = error, _payload), do: error
  defp validate_admission_result(_other, _payload), do: {:error, :invalid_outbox_response}

  defp exact_receipt?(receipt, payload) do
    exact_keys?(receipt, @receipt_keys) and
      receipt.stream == :health and
      valid_id?(receipt.device_id) and
      receipt.credential_epoch in 0..@u32_max and
      valid_id?(receipt.storage_epoch) and
      is_integer(receipt.sequence) and receipt.sequence > 0 and
      receipt.payload_hash == :crypto.hash(:sha256, payload) and
      receipt.cumulative_sequence == 0
  end

  defp valid_id?(<<_::128>> = id), do: id != @zero_id
  defp valid_id?(_id), do: false

  defp exact_keys?(map, keys) do
    map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))
  end

  defp fetch_option(opts, key, missing_error) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, missing_error}
    end
  end
end
