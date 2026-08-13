defmodule RacingOrg.Tracker.Pro.DurableDelivery.Producer.DesiredStateAck do
  @moduledoc """
  Durably admits one frozen Desired State ACK before it is accepted as sent.

  The ACK is encoded exactly once with the frozen Desired State v1 codec. Its
  canonical bytes are preserved unchanged in the `:desired_state_ack` Outbox
  stream, and a domain-separated hash of those immutable bytes selects the
  opaque entry id used by journal replay.
  """

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Messages

  @entry_id_domain "RacingOrg-DesiredStateAckEntryId-v1"

  @type receipt :: Owner.receipt()

  @doc "Encode and durably admit one exact Desired State ACK."
  @spec admit(map(), keyword()) :: {:ok, receipt()} | {:error, term()}
  def admit(ack, opts)

  def admit(ack, opts) when is_map(ack) and is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, encoded_ack} <- encode_ack(ack),
         {:ok, outbox} <- fetch_option(opts, :outbox, :outbox_required),
         {:ok, adapter} <- adapter(opts) do
      call_adapter(adapter, outbox, encoded_ack)
    end
  end

  def admit(_ack, opts) when is_list(opts) do
    with :ok <- validate_options(opts), do: {:error, :invalid_ack}
  end

  def admit(_ack, _opts), do: {:error, :invalid_options}

  defp validate_options(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, :invalid_options}
  end

  defp encode_ack(ack) do
    case Messages.encode(:ack, ack) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :invalid_ack}
    end
  rescue
    _exception -> {:error, :invalid_ack}
  catch
    _kind, _reason -> {:error, :invalid_ack}
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

  defp call_adapter(adapter, outbox, encoded_ack) do
    adapter.enqueue(outbox, :desired_state_ack, encoded_ack, entry_id: entry_id(encoded_ack))
    |> validate_admission_result()
  rescue
    _exception -> {:error, :outbox_adapter_failure}
  catch
    kind, _reason when kind in [:throw, :exit] -> {:error, :outbox_adapter_failure}
  end

  defp entry_id(encoded_ack) do
    :crypto.hash(:sha256, [@entry_id_domain, :crypto.hash(:sha256, encoded_ack)])
  end

  defp validate_admission_result(
         {:ok,
          %{
            stream: :desired_state_ack,
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
