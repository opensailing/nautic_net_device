defmodule RacingOrg.Tracker.Pro.Commands.Ledger do
  @moduledoc """
  Pure Desired State v1 command classification for the durable command ledger.

  Classification never mutates the supplied snapshot. The returned execution or
  terminal plan is the only input accepted by the durable transition API.
  """

  alias RacingOrg.Tracker.Pro.Commands.Ledger.{Ack, Snapshot}
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Command

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
  @max_command_result_size Contract.max_command_result_size()

  @type classification ::
          {:defer, term()}
          | {:transient, map()}
          | {:duplicate, map()}
          | {:terminal, map()}
          | {:execute, map()}

  @doc "Classify one decoded command delivery without reading or writing filesystem state."
  @spec classify(map(), map()) :: classification()
  def classify(_delivery, %{snapshot: %Snapshot{pending_intent: intent}}) when not is_nil(intent),
    do: {:defer, :pending_command_intent}

  def classify(delivery, %{snapshot: %Snapshot{} = snapshot} = context)
      when is_map(delivery) do
    with :ok <- device_fence(delivery, snapshot),
         :ok <- credential_fence(delivery, snapshot),
         :ok <- storage_fence(delivery, snapshot),
         :ok <- command_hash_fence(delivery),
         {:ok, reset_epoch?} <- epoch_fence(delivery, snapshot),
         :ok <- command_id_fence(delivery, snapshot, reset_epoch?),
         :ok <- generation_fence(delivery, context),
         :ok <- manifest_fence(delivery, context),
         :ok <- sequence_fence(delivery, snapshot, reset_epoch?),
         :ok <- expiry_fence(delivery, context, reset_epoch?),
         {:ok, decoded} <- payload_fence(delivery, context, reset_epoch?),
         {:ok, command_type, reserved_result_bytes} <-
           type_fence(delivery, decoded, context, reset_epoch?),
         :ok <- gate_fence(delivery, context),
         :ok <- execution_capacity(context, reset_epoch?, reserved_result_bytes) do
      {:execute,
       %{
         action: :execute,
         delivery: delivery,
         command_type: command_type,
         reserved_result_bytes: reserved_result_bytes,
         reset_epoch?: reset_epoch?
       }}
    else
      {:stop, classification} -> classification
      {:error, _reason} -> {:defer, :invalid_command_classification_context}
      false -> {:defer, :invalid_command_classification_context}
    end
  rescue
    _exception -> {:defer, :invalid_command_classification_context}
  catch
    _kind, _reason -> {:defer, :invalid_command_classification_context}
  end

  def classify(_delivery, _context), do: {:defer, :invalid_command_classification_context}

  @doc """
  Classify pending-intent recovery against a trusted current time.

  Returns `:none` when no recovery is required, `{:recover, intent}` only while
  the intent remains unexpired, `{:abort, intent, :expired}` at or after its
  expiry boundary, and defers when trusted time is unavailable or invalid.
  """
  @spec recover_pending(Snapshot.t(), non_neg_integer() | :unavailable) ::
          {:recover, Snapshot.intent()}
          | {:abort, Snapshot.intent(), :expired}
          | {:defer, :trusted_clock_unavailable}
          | :none
  def recover_pending(%Snapshot{pending_intent: nil}, _trusted_now_ms), do: :none

  def recover_pending(%Snapshot{pending_intent: _intent}, :unavailable),
    do: {:defer, :trusted_clock_unavailable}

  def recover_pending(%Snapshot{pending_intent: intent}, trusted_now_ms)
      when is_integer(trusted_now_ms) and trusted_now_ms >= 0 do
    if trusted_now_ms >= intent.expires_at_ms,
      do: {:abort, intent, :expired},
      else: {:recover, intent}
  end

  def recover_pending(%Snapshot{}, _trusted_now_ms), do: {:defer, :trusted_clock_unavailable}

  defp device_fence(delivery, snapshot) do
    if delivery.device_id == snapshot.device_id,
      do: :ok,
      else: stop({:defer, :device_mismatch})
  end

  defp credential_fence(delivery, snapshot) do
    if delivery.credential_epoch == snapshot.credential_epoch,
      do: :ok,
      else: transient(delivery, :stale_credential_epoch)
  end

  defp storage_fence(delivery, snapshot) do
    if delivery.storage_epoch == snapshot.storage_epoch,
      do: :ok,
      else: transient(delivery, :storage_epoch_mismatch)
  end

  defp generation_fence(delivery, context) do
    if delivery.required_generation == context.active_generation,
      do: :ok,
      else: transient(delivery, :generation_mismatch)
  end

  defp manifest_fence(delivery, context) do
    if delivery.required_manifest_hash == context.active_manifest_hash,
      do: :ok,
      else: transient(delivery, :manifest_hash_mismatch)
  end

  defp command_hash_fence(delivery) do
    with {:ok, claimed_hash} <- Map.fetch(delivery, :command_hash),
         true <- is_binary(claimed_hash) and byte_size(claimed_hash) == 32,
         {:ok, expected_hash} <- Command.hash(Map.take(delivery, @command_hash_keys)),
         true <- :crypto.hash_equals(expected_hash, claimed_hash) do
      :ok
    else
      _other -> stop({:defer, :invalid_command_delivery})
    end
  end

  defp command_id_fence(_delivery, _snapshot, true), do: :ok

  defp command_id_fence(delivery, snapshot, false) do
    case Map.fetch(snapshot.outcomes, delivery.command_id) do
      {:ok, %{hash: hash} = outcome} when hash == delivery.command_hash ->
        with {:ok, payload_hash} <- Command.payload_hash(delivery.payload),
             true <- :crypto.hash_equals(payload_hash, delivery.payload_hash),
             {:ok, ack} <- Ack.replay(delivery, outcome) do
          stop({:duplicate, ack})
        else
          _other -> stop({:defer, :invalid_command_delivery})
        end

      {:ok, _outcome} ->
        transient(delivery, :command_id_conflict)

      :error ->
        :ok
    end
  end

  defp epoch_fence(delivery, snapshot) do
    cond do
      delivery.command_epoch < snapshot.command_epoch ->
        transient(delivery, :sequence_replay)

      delivery.command_epoch == snapshot.command_epoch ->
        {:ok, false}

      delivery.command_epoch > snapshot.command_epoch ->
        {:ok, true}
    end
  end

  defp sequence_fence(delivery, snapshot, false) do
    cond do
      delivery.command_sequence < snapshot.next_expected_sequence ->
        transient(delivery, :sequence_replay)

      delivery.command_sequence > snapshot.next_expected_sequence ->
        transient(delivery, :sequence_gap)

      true ->
        :ok
    end
  end

  defp sequence_fence(%{command_sequence: 1}, _snapshot, true), do: :ok
  defp sequence_fence(delivery, _snapshot, true), do: transient(delivery, :sequence_gap)

  defp expiry_fence(_delivery, %{trusted_now_ms: :unavailable}, _reset_epoch?),
    do: stop({:defer, :trusted_clock_unavailable})

  defp expiry_fence(delivery, %{trusted_now_ms: now} = context, reset_epoch?)
       when is_integer(now) and now >= 0 do
    if now >= delivery.expires_at_ms,
      do: terminal(delivery, :expired, context, reset_epoch?),
      else: :ok
  end

  defp expiry_fence(_delivery, _context, _reset_epoch?),
    do: stop({:defer, :trusted_clock_unavailable})

  defp payload_fence(delivery, context, reset_epoch?) do
    with {:ok, payload_hash} <- Command.payload_hash(delivery.payload),
         true <- payload_hash == delivery.payload_hash,
         {:ok, {:ok, decoded}} <- invoke(context.decode_payload, delivery.payload) do
      {:ok, decoded}
    else
      _other -> terminal(delivery, :invalid_payload, context, reset_epoch?)
    end
  end

  defp type_fence(delivery, decoded, context, reset_epoch?) do
    case invoke(context.resolve_type, decoded) do
      {:ok, {:ok, command_type, reserved_result_bytes}}
      when is_atom(command_type) and is_integer(reserved_result_bytes) and
             reserved_result_bytes >= 0 and reserved_result_bytes <= @max_command_result_size ->
        {:ok, command_type, reserved_result_bytes}

      _other ->
        terminal(delivery, :unsupported_command, context, reset_epoch?)
    end
  end

  defp gate_fence(delivery, context) do
    expected = %{
      credential_epoch: context.snapshot.credential_epoch,
      storage_epoch: context.snapshot.storage_epoch,
      generation: context.active_generation,
      manifest_hash: context.active_manifest_hash
    }

    case context.gate do
      {:open, binding} when is_map(binding) ->
        if Map.take(binding, Map.keys(expected)) == expected,
          do: :ok,
          else: transient(delivery, :operational_gate_closed)

      _closed ->
        transient(delivery, :operational_gate_closed)
    end
  end

  defp terminal(delivery, reason, context, reset_epoch?) do
    case terminal_capacity(context, reset_epoch?) do
      :ok ->
        stop(
          {:terminal,
           %{
             action: :terminal,
             delivery: delivery,
             status: :rejected,
             reason: reason,
             result: <<>>,
             reset_epoch?: reset_epoch?
           }}
        )

      {:stop, _classification} = stopped ->
        stopped
    end
  end

  defp terminal_capacity(context, reset_epoch?), do: capacity(context, reset_epoch?, 0)

  defp execution_capacity(context, reset_epoch?, reserved_result_bytes),
    do: capacity(context, reset_epoch?, reserved_result_bytes)

  defp capacity(context, reset_epoch?, additional_result_bytes) do
    outcome_count = if reset_epoch?, do: 0, else: map_size(context.snapshot.outcomes)
    result_bytes = if reset_epoch?, do: 0, else: Snapshot.result_bytes(context.snapshot)

    cond do
      outcome_count >= context.limits.max_outcomes ->
        stop({:defer, {:capacity, :outcome_count}})

      result_bytes + additional_result_bytes > context.limits.max_result_bytes ->
        stop({:defer, {:capacity, :result_bytes}})

      true ->
        :ok
    end
  end

  defp transient(delivery, reason) do
    case Ack.build(delivery, :rejected, reason, <<>>) do
      {:ok, ack} -> stop({:transient, ack})
      {:error, _reason} -> stop({:defer, :invalid_command_delivery})
    end
  end

  defp invoke(callback, value) when is_function(callback, 1) do
    {:ok, callback.(value)}
  rescue
    _exception -> {:error, :callback_failed}
  catch
    _kind, _reason -> {:error, :callback_failed}
  end

  defp invoke(_callback, _value), do: {:error, :invalid_callback}

  defp stop(classification), do: {:stop, classification}
end
