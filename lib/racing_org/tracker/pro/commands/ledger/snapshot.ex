defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Snapshot do
  @moduledoc false

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Command

  @domain "RacingOrg-CommandLedgerSnapshot-v1"
  @version 1
  @hash_size 32
  @identifier_size 16
  @database_int_max 9_223_372_036_854_775_807
  @next_sequence_max @database_int_max + 1
  @zero_identifier <<0::128>>

  @enforce_keys [
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :command_epoch,
    :next_expected_sequence,
    :outcomes,
    :pending_intent
  ]
  defstruct @enforce_keys

  @type outcome :: %{
          required(:hash) => binary(),
          required(:status) => :applied | :rejected,
          required(:reason) => atom(),
          required(:result) => binary(),
          required(:result_hash) => binary(),
          required(:sequence) => pos_integer()
        }

  @type intent :: %{
          required(:device_id) => binary(),
          required(:credential_epoch) => non_neg_integer(),
          required(:storage_epoch) => binary(),
          required(:required_generation) => pos_integer(),
          required(:required_manifest_hash) => binary(),
          required(:command_epoch) => non_neg_integer(),
          required(:command_sequence) => pos_integer(),
          required(:command_id) => binary(),
          required(:expires_at_ms) => non_neg_integer(),
          required(:payload_hash) => binary(),
          required(:command_hash) => binary(),
          required(:payload) => binary(),
          required(:command_type) => atom(),
          required(:reserved_result_bytes) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          device_id: binary(),
          credential_epoch: non_neg_integer(),
          storage_epoch: binary(),
          command_epoch: non_neg_integer(),
          next_expected_sequence: pos_integer(),
          outcomes: %{optional(binary()) => outcome()},
          pending_intent: intent() | nil
        }

  @doc false
  def domain, do: @domain

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(identity) when is_map(identity) do
    snapshot = %__MODULE__{
      device_id: Map.get(identity, :device_id),
      credential_epoch: Map.get(identity, :credential_epoch),
      storage_epoch: Map.get(identity, :storage_epoch),
      command_epoch: 0,
      next_expected_sequence: 1,
      outcomes: %{},
      pending_intent: nil
    }

    validate(snapshot)
  end

  def new(_identity), do: {:error, :invalid_command_ledger_identity}

  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = snapshot) do
    with {:ok, snapshot} <- validate(snapshot) do
      payload =
        :erlang.term_to_binary(
          {
            :command_ledger_snapshot,
            snapshot.device_id,
            snapshot.credential_epoch,
            snapshot.storage_epoch,
            snapshot.command_epoch,
            snapshot.next_expected_sequence,
            encode_outcomes(snapshot.outcomes),
            encode_intent(snapshot.pending_intent)
          },
          [:deterministic]
        )

      checksum = :crypto.hash(:sha256, @domain <> <<@version, byte_size(payload)::32, payload::binary>>)
      {:ok, @domain <> <<@version, byte_size(payload)::32, payload::binary, checksum::binary>>}
    end
  rescue
    _exception -> {:error, :invalid_command_ledger_snapshot}
  catch
    _kind, _reason -> {:error, :invalid_command_ledger_snapshot}
  end

  def encode(_snapshot), do: {:error, :invalid_command_ledger_snapshot}

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(bytes) when is_binary(bytes) do
    domain = @domain
    domain_size = byte_size(domain)

    case bytes do
      <<^domain::binary-size(domain_size), version, _rest::binary>> when version != @version ->
        {:error, :unsupported_command_ledger_version}

      <<^domain::binary-size(domain_size), @version, payload_size::32, rest::binary>> ->
        decode_payload(payload_size, rest)

      _other ->
        {:error, :corrupt_command_ledger}
    end
  rescue
    _exception -> {:error, :corrupt_command_ledger}
  catch
    _kind, _reason -> {:error, :corrupt_command_ledger}
  end

  def decode(_bytes), do: {:error, :corrupt_command_ledger}

  @spec result_bytes(t()) :: non_neg_integer()
  def result_bytes(%__MODULE__{} = snapshot) do
    Enum.reduce(snapshot.outcomes, 0, fn {_command_id, outcome}, total ->
      total + byte_size(outcome.result)
    end)
  end

  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = snapshot) do
    with :ok <- valid_identifier(snapshot.device_id, :invalid_device_id),
         :ok <- u32(snapshot.credential_epoch, :invalid_credential_epoch),
         :ok <- valid_identifier(snapshot.storage_epoch, :invalid_storage_epoch),
         :ok <- u32(snapshot.command_epoch, :invalid_command_epoch),
         :ok <- next_sequence(snapshot.next_expected_sequence),
         :ok <- validate_outcomes(snapshot.outcomes, snapshot.next_expected_sequence),
         :ok <- validate_intent(snapshot.pending_intent, snapshot) do
      {:ok, snapshot}
    else
      {:error, _reason} -> {:error, :corrupt_command_ledger}
    end
  end

  def validate(_snapshot), do: {:error, :corrupt_command_ledger}

  defp decode_payload(payload_size, rest) do
    with true <- byte_size(rest) == payload_size + @hash_size,
         <<payload::binary-size(payload_size), checksum::binary-size(@hash_size)>> <- rest,
         expected = :crypto.hash(:sha256, @domain <> <<@version, payload_size::32, payload::binary>>),
         true <- :crypto.hash_equals(expected, checksum),
         {:ok, term} <- safe_binary_to_term(payload),
         {:ok, snapshot} <- snapshot_from_term(term),
         {:ok, canonical} <- encode(snapshot),
         true <- canonical == @domain <> <<@version, payload_size::32, payload::binary, checksum::binary>> do
      {:ok, snapshot}
    else
      _other -> {:error, :corrupt_command_ledger}
    end
  end

  defp safe_binary_to_term(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    _exception -> {:error, :corrupt_command_ledger}
  catch
    _kind, _reason -> {:error, :corrupt_command_ledger}
  end

  defp snapshot_from_term({
         :command_ledger_snapshot,
         device_id,
         credential_epoch,
         storage_epoch,
         command_epoch,
         next_expected_sequence,
         encoded_outcomes,
         encoded_intent
       }) do
    with {:ok, outcomes} <- decode_outcomes(encoded_outcomes),
         {:ok, pending_intent} <- decode_intent(encoded_intent) do
      %__MODULE__{
        device_id: device_id,
        credential_epoch: credential_epoch,
        storage_epoch: storage_epoch,
        command_epoch: command_epoch,
        next_expected_sequence: next_expected_sequence,
        outcomes: outcomes,
        pending_intent: pending_intent
      }
      |> validate()
    end
  end

  defp snapshot_from_term(_term), do: {:error, :corrupt_command_ledger}

  defp encode_outcomes(outcomes) do
    outcomes
    |> Enum.map(fn {command_id, outcome} ->
      {
        command_id,
        outcome.hash,
        outcome.status,
        outcome.reason,
        outcome.result,
        outcome.result_hash,
        outcome.sequence
      }
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp decode_outcomes(outcomes) when is_list(outcomes) do
    Enum.reduce_while(outcomes, {:ok, %{}}, fn
      {command_id, hash, status, reason, result, result_hash, sequence}, {:ok, acc} ->
        outcome = %{
          hash: hash,
          status: status,
          reason: reason,
          result: result,
          result_hash: result_hash,
          sequence: sequence
        }

        if Map.has_key?(acc, command_id) do
          {:halt, {:error, :corrupt_command_ledger}}
        else
          {:cont, {:ok, Map.put(acc, command_id, outcome)}}
        end

      _invalid, _acc ->
        {:halt, {:error, :corrupt_command_ledger}}
    end)
  end

  defp decode_outcomes(_outcomes), do: {:error, :corrupt_command_ledger}

  defp encode_intent(nil), do: nil

  defp encode_intent(intent) do
    {
      intent.device_id,
      intent.credential_epoch,
      intent.storage_epoch,
      intent.required_generation,
      intent.required_manifest_hash,
      intent.command_epoch,
      intent.command_sequence,
      intent.command_id,
      intent.expires_at_ms,
      intent.payload_hash,
      intent.command_hash,
      intent.payload,
      intent.command_type,
      intent.reserved_result_bytes
    }
  end

  defp decode_intent(nil), do: {:ok, nil}

  defp decode_intent({
         device_id,
         credential_epoch,
         storage_epoch,
         required_generation,
         required_manifest_hash,
         command_epoch,
         command_sequence,
         command_id,
         expires_at_ms,
         payload_hash,
         command_hash,
         payload,
         command_type,
         reserved_result_bytes
       }) do
    {:ok,
     %{
       device_id: device_id,
       credential_epoch: credential_epoch,
       storage_epoch: storage_epoch,
       required_generation: required_generation,
       required_manifest_hash: required_manifest_hash,
       command_epoch: command_epoch,
       command_sequence: command_sequence,
       command_id: command_id,
       expires_at_ms: expires_at_ms,
       payload_hash: payload_hash,
       command_hash: command_hash,
       payload: payload,
       command_type: command_type,
       reserved_result_bytes: reserved_result_bytes
     }}
  end

  defp decode_intent(_intent), do: {:error, :corrupt_command_ledger}

  defp validate_outcomes(outcomes, next_expected_sequence) when is_map(outcomes) do
    with :ok <- outcome_count(outcomes, next_expected_sequence),
         :ok <- validate_each_outcome(outcomes),
         :ok <- contiguous_outcome_sequences(outcomes, next_expected_sequence) do
      :ok
    end
  end

  defp validate_outcomes(_outcomes, _next_expected_sequence), do: {:error, :invalid_outcomes}

  defp outcome_count(outcomes, next_expected_sequence) do
    if map_size(outcomes) == next_expected_sequence - 1,
      do: :ok,
      else: {:error, :outcome_count_mismatch}
  end

  defp validate_each_outcome(outcomes) do
    Enum.reduce_while(outcomes, :ok, fn {command_id, outcome}, :ok ->
      case validate_outcome(command_id, outcome) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_outcome(command_id, outcome) when is_map(outcome) do
    expected_keys = [:hash, :reason, :result, :result_hash, :sequence, :status]

    with true <- Enum.sort(Map.keys(outcome)) == expected_keys,
         :ok <- fixed_binary(command_id, @identifier_size, :invalid_command_id),
         :ok <- fixed_binary(outcome.hash, @hash_size, :invalid_command_hash),
         true <- outcome.status in [:applied, :rejected],
         true <- is_atom(outcome.reason),
         true <- is_binary(outcome.result),
         true <- byte_size(outcome.result) <= Contract.max_command_result_size(),
         :ok <- fixed_binary(outcome.result_hash, @hash_size, :invalid_result_hash),
         :ok <- positive_database_int(outcome.sequence, :invalid_command_sequence),
         {:ok, expected_hash} <-
           Command.result_hash(%{
             status: outcome.status,
             reason: outcome.reason,
             result: outcome.result
           }),
         true <- :crypto.hash_equals(expected_hash, outcome.result_hash) do
      :ok
    else
      _other -> {:error, :invalid_outcome}
    end
  end

  defp validate_outcome(_command_id, _outcome), do: {:error, :invalid_outcome}

  defp contiguous_outcome_sequences(outcomes, next_expected_sequence) do
    sequences = outcomes |> Map.values() |> Enum.map(& &1.sequence) |> Enum.sort()
    expected = if next_expected_sequence == 1, do: [], else: Enum.to_list(1..(next_expected_sequence - 1))
    if sequences == expected, do: :ok, else: {:error, :outcome_sequence_mismatch}
  end

  defp validate_intent(nil, _snapshot), do: :ok

  defp validate_intent(intent, snapshot) when is_map(intent) do
    expected_keys = [
      :command_epoch,
      :command_hash,
      :command_id,
      :command_sequence,
      :command_type,
      :credential_epoch,
      :device_id,
      :expires_at_ms,
      :payload,
      :payload_hash,
      :required_generation,
      :required_manifest_hash,
      :reserved_result_bytes,
      :storage_epoch
    ]

    with true <- Enum.sort(Map.keys(intent)) == expected_keys,
         true <- intent.device_id == snapshot.device_id,
         true <- intent.credential_epoch == snapshot.credential_epoch,
         true <- intent.storage_epoch == snapshot.storage_epoch,
         true <- intent.command_epoch == snapshot.command_epoch,
         true <- intent.command_sequence == snapshot.next_expected_sequence,
         false <- Map.has_key?(snapshot.outcomes, intent.command_id),
         :ok <- positive_database_int(intent.required_generation, :invalid_required_generation),
         :ok <- fixed_binary(intent.required_manifest_hash, @hash_size, :invalid_required_manifest_hash),
         :ok <- fixed_binary(intent.command_id, @identifier_size, :invalid_command_id),
         :ok <- database_int(intent.expires_at_ms, :invalid_expires_at_ms),
         :ok <- fixed_binary(intent.payload_hash, @hash_size, :invalid_payload_hash),
         :ok <- fixed_binary(intent.command_hash, @hash_size, :invalid_command_hash),
         true <- is_binary(intent.payload),
         true <- is_atom(intent.command_type),
         true <- is_integer(intent.reserved_result_bytes) and intent.reserved_result_bytes >= 0,
         true <- intent.reserved_result_bytes <= Contract.max_command_result_size(),
         {:ok, expected_payload_hash} <- Command.payload_hash(intent.payload),
         true <- :crypto.hash_equals(expected_payload_hash, intent.payload_hash),
         {:ok, expected_command_hash} <- Command.hash(command_hash_attrs(intent)),
         true <- :crypto.hash_equals(expected_command_hash, intent.command_hash) do
      :ok
    else
      _other -> {:error, :invalid_pending_intent}
    end
  end

  defp validate_intent(_intent, _snapshot), do: {:error, :invalid_pending_intent}

  defp command_hash_attrs(intent) do
    Map.take(intent, [
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
    ])
  end

  defp valid_identifier(value, _error)
       when is_binary(value) and byte_size(value) == @identifier_size and value != @zero_identifier,
       do: :ok

  defp valid_identifier(_value, error), do: {:error, error}

  defp fixed_binary(value, size, _error) when is_binary(value) and byte_size(value) == size,
    do: :ok

  defp fixed_binary(_value, _size, error), do: {:error, error}

  defp u32(value, _error) when is_integer(value) and value >= 0 and value <= 0xFFFF_FFFF,
    do: :ok

  defp u32(_value, error), do: {:error, error}

  defp database_int(value, _error)
       when is_integer(value) and value >= 0 and value <= @database_int_max,
       do: :ok

  defp database_int(_value, error), do: {:error, error}

  defp positive_database_int(value, _error)
       when is_integer(value) and value > 0 and value <= @database_int_max,
       do: :ok

  defp positive_database_int(_value, error), do: {:error, error}

  defp next_sequence(value) when is_integer(value) and value > 0 and value <= @next_sequence_max,
    do: :ok

  defp next_sequence(_value), do: {:error, :invalid_next_expected_sequence}
end
