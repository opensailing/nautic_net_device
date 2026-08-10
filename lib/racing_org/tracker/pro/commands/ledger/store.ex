defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Store do
  @moduledoc """
  Single-writer durable command-ledger state backed by one atomic snapshot.

  Every successful mutation replaces and fsyncs the complete bounded snapshot.
  Existing snapshots are rewritten and fsynced before `open/2` returns, and
  every mutation verifies that its immutable handle still matches disk before
  replacing state. A handle retained across an uncertain write therefore cannot
  overwrite the visibly advanced snapshot.
  """

  alias RacingOrg.Tracker.Pro.Commands.Ledger.{Ack, Snapshot}
  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Command
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

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
  @delivery_keys @command_hash_keys ++ [:command_hash, :payload]
  @terminal_reasons [:expired, :unsupported_command, :invalid_payload]
  @recovery_rejection_reasons [:operational_gate_closed]
  @recovery_proofs [:effect_not_started, :effect_verified_absent]
  @rejection_plan_keys [:action, :command_hash, :command_id, :command_type, :proof, :reason]
  @max_command_result_size Contract.max_command_result_size()

  @enforce_keys [
    :path,
    :snapshot,
    :max_outcomes,
    :max_result_bytes,
    :file_system,
    :atomic_opts
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          path: Path.t(),
          snapshot: Snapshot.t(),
          max_outcomes: pos_integer(),
          max_result_bytes: pos_integer(),
          file_system: module(),
          atomic_opts: keyword()
        }

  @doc "Open an exact identity-scoped ledger, durably creating its initial snapshot only when absent."
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, store} <- new_store(path, opts) do
      case read_snapshot(store) do
        {:ok, snapshot} -> open_existing(store, snapshot)
        {:error, :enoent} -> initialize(store)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def open(_path, _opts), do: {:error, :invalid_command_ledger_options}

  @doc "Return the current in-memory view of the authoritative durable snapshot."
  @spec snapshot(t()) :: Snapshot.t()
  def snapshot(%__MODULE__{snapshot: snapshot}), do: snapshot

  @doc "Return retained outcome count and exact aggregate result bytes."
  @spec usage(t()) :: %{outcomes: non_neg_integer(), result_bytes: non_neg_integer()}
  def usage(%__MODULE__{snapshot: snapshot}) do
    %{outcomes: map_size(snapshot.outcomes), result_bytes: Snapshot.result_bytes(snapshot)}
  end

  @doc "Return the configured count and aggregate-result-byte budgets."
  @spec limits(t()) :: %{max_outcomes: pos_integer(), max_result_bytes: pos_integer()}
  def limits(%__MODULE__{} = store) do
    %{max_outcomes: store.max_outcomes, max_result_bytes: store.max_result_bytes}
  end

  @doc "Return the sole unresolved intent that must be recovered before accepting another command."
  @spec pending_intent(t()) :: Snapshot.intent() | nil
  def pending_intent(%__MODULE__{snapshot: snapshot}), do: snapshot.pending_intent

  @doc "Durably persist an execution intent before its external effect may begin."
  @spec begin_intent(t(), map()) :: {:ok, Snapshot.intent(), t()} | {:error, term()}
  def begin_intent(%__MODULE__{} = store, plan) when is_map(plan) do
    with :ok <- exact_keys(plan, [:action, :command_type, :delivery, :reserved_result_bytes, :reset_epoch?]),
         true <- plan.action == :execute,
         :ok <- current_snapshot(store),
         :ok <- no_pending_intent(store.snapshot),
         :ok <- validate_delivery(plan.delivery, store.snapshot),
         {:ok, base} <- transition_base(store.snapshot, plan.delivery, plan.reset_epoch?),
         :ok <- valid_command_type(plan.command_type),
         :ok <- valid_reservation(plan.reserved_result_bytes),
         :ok <- admit(store, base, plan.reserved_result_bytes),
         {:ok, intent} <- build_intent(plan),
         {:ok, persisted} <- persist_snapshot(store, %{base | pending_intent: intent}) do
      {:ok, intent, persisted}
    else
      false -> {:error, :invalid_command_intent}
      {:error, _reason} = error -> error
    end
  end

  def begin_intent(_store, _plan), do: {:error, :invalid_command_intent}

  @doc """
  Atomically retain an applied result, clear its intent, and advance before
  returning an ACK.

  Expiry is checked before intent admission, never after an external effect may
  have started. Completion therefore records a proven applied result even when
  the command's original expiry has elapsed.
  """
  @spec complete_intent(t(), binary()) :: {:ok, map(), t()} | {:error, term()}
  def complete_intent(%__MODULE__{snapshot: %{pending_intent: nil}}, _result),
    do: {:error, :no_pending_command_intent}

  def complete_intent(%__MODULE__{} = store, result) do
    intent = store.snapshot.pending_intent

    with :ok <- current_snapshot(store),
         :ok <- valid_result(result),
         :ok <- within_reservation(result, intent.reserved_result_bytes),
         {:ok, ack} <- Ack.build(intent, :applied, :none, result),
         outcome = retained_outcome(intent, ack),
         intended = retain_and_advance(store.snapshot, intent.command_id, outcome),
         {:ok, persisted} <- persist_snapshot(store, intended) do
      {:ok, ack, persisted}
    end
  end

  def complete_intent(_store, _result), do: {:error, :invalid_command_ledger_store}

  @doc """
  Durably reject a pending intent only after exact proof that its effect did not
  apply.

  The closed rejection plan is bound to the pending command ID, command hash,
  command type, a registered non-application proof, and a reason that remains
  truthful after intent admission. Ambiguous effects remain pending.
  """
  @spec reject_intent(t(), map()) :: {:ok, map(), t()} | {:error, term()}
  def reject_intent(%__MODULE__{snapshot: %{pending_intent: nil}}, _plan),
    do: {:error, :no_pending_command_intent}

  def reject_intent(%__MODULE__{} = store, plan) when is_map(plan) do
    intent = store.snapshot.pending_intent

    with :ok <- current_snapshot(store),
         :ok <- valid_rejection_plan(plan, intent),
         {:ok, ack} <- Ack.build(intent, :rejected, plan.reason, <<>>),
         outcome = retained_outcome(intent, ack),
         intended = retain_and_advance(store.snapshot, intent.command_id, outcome),
         {:ok, persisted} <- persist_snapshot(store, intended) do
      {:ok, ack, persisted}
    end
  end

  def reject_intent(_store, _plan), do: {:error, :invalid_command_rejection_plan}

  @doc "Durably retain a terminal non-execution result and advance before returning an ACK."
  @spec record_terminal(t(), map()) :: {:ok, map(), t()} | {:error, term()}
  def record_terminal(%__MODULE__{} = store, plan) when is_map(plan) do
    with :ok <- exact_keys(plan, [:action, :delivery, :reason, :reset_epoch?, :result, :status]),
         true <- plan.action == :terminal,
         true <- plan.status == :rejected,
         true <- plan.reason in @terminal_reasons,
         :ok <- valid_result(plan.result),
         :ok <- current_snapshot(store),
         :ok <- no_pending_intent(store.snapshot),
         :ok <- validate_delivery(plan.delivery, store.snapshot),
         {:ok, base} <- transition_base(store.snapshot, plan.delivery, plan.reset_epoch?),
         :ok <- admit(store, base, byte_size(plan.result)),
         {:ok, ack} <- Ack.build(plan.delivery, plan.status, plan.reason, plan.result),
         outcome = retained_outcome(plan.delivery, ack),
         intended = retain_and_advance(base, plan.delivery.command_id, outcome),
         {:ok, persisted} <- persist_snapshot(store, intended) do
      {:ok, ack, persisted}
    else
      false -> {:error, :invalid_terminal_command_outcome}
      {:error, _reason} = error -> error
    end
  end

  def record_terminal(_store, _plan), do: {:error, :invalid_terminal_command_outcome}

  defp no_pending_intent(%Snapshot{pending_intent: nil}), do: :ok
  defp no_pending_intent(%Snapshot{}), do: {:error, :pending_command_intent}

  defp validate_delivery(delivery, snapshot) when is_map(delivery) do
    with :ok <- exact_keys(delivery, @delivery_keys),
         true <- delivery.device_id == snapshot.device_id,
         true <- delivery.credential_epoch == snapshot.credential_epoch,
         true <- delivery.storage_epoch == snapshot.storage_epoch,
         {:ok, payload_hash} <- Command.payload_hash(delivery.payload),
         true <- fixed_hash_equal?(payload_hash, delivery.payload_hash),
         {:ok, command_hash} <- Command.hash(Map.take(delivery, @command_hash_keys)),
         true <- fixed_hash_equal?(command_hash, delivery.command_hash) do
      :ok
    else
      _other -> {:error, :invalid_command_delivery}
    end
  end

  defp validate_delivery(_delivery, _snapshot), do: {:error, :invalid_command_delivery}

  defp transition_base(snapshot, delivery, reset_epoch?) do
    cond do
      delivery.command_epoch == snapshot.command_epoch and
        delivery.command_sequence == snapshot.next_expected_sequence and reset_epoch? == false ->
        if Map.has_key?(snapshot.outcomes, delivery.command_id),
          do: {:error, :command_id_already_retained},
          else: {:ok, snapshot}

      delivery.command_epoch > snapshot.command_epoch and
        delivery.command_sequence == 1 and reset_epoch? == true ->
        {:ok,
         %{
           snapshot
           | command_epoch: delivery.command_epoch,
             next_expected_sequence: 1,
             outcomes: %{}
         }}

      true ->
        {:error, :invalid_command_epoch_transition}
    end
  end

  defp valid_command_type(command_type) when is_atom(command_type), do: :ok
  defp valid_command_type(_command_type), do: {:error, :invalid_command_type}

  defp valid_reservation(bytes)
       when is_integer(bytes) and bytes >= 0 and bytes <= @max_command_result_size,
       do: :ok

  defp valid_reservation(_bytes), do: {:error, :invalid_command_result_reservation}

  defp valid_rejection_plan(plan, intent) do
    with :ok <- exact_keys(plan, @rejection_plan_keys),
         true <- plan.action == :reject,
         true <- plan.command_id == intent.command_id,
         true <- fixed_hash_equal?(plan.command_hash, intent.command_hash),
         true <- plan.command_type == intent.command_type,
         true <- plan.proof in @recovery_proofs,
         true <- plan.reason in @recovery_rejection_reasons do
      :ok
    else
      _other -> {:error, :invalid_command_rejection_plan}
    end
  end

  defp valid_result(result) when is_binary(result) and byte_size(result) <= @max_command_result_size,
    do: :ok

  defp valid_result(result) when is_binary(result), do: {:error, :command_result_too_large}
  defp valid_result(_result), do: {:error, :invalid_command_result}

  defp within_reservation(result, reserved_result_bytes) do
    if byte_size(result) <= reserved_result_bytes,
      do: :ok,
      else: {:error, :command_result_reservation_exceeded}
  end

  defp admit(store, snapshot, reserved_result_bytes) do
    with :ok <- admit_outcome_count(store, snapshot),
         :ok <- admit_result_bytes(store, snapshot, reserved_result_bytes) do
      :ok
    end
  end

  defp admit_outcome_count(store, snapshot) do
    if map_size(snapshot.outcomes) < store.max_outcomes,
      do: :ok,
      else: {:error, {:command_ledger_capacity, :outcome_count}}
  end

  defp admit_result_bytes(store, snapshot, additional_bytes) do
    if Snapshot.result_bytes(snapshot) + additional_bytes <= store.max_result_bytes,
      do: :ok,
      else: {:error, {:command_ledger_capacity, :result_bytes}}
  end

  defp build_intent(plan) do
    intent =
      plan.delivery
      |> Map.take(@delivery_keys)
      |> Map.delete(:command_hash)
      |> Map.merge(%{
        command_hash: plan.delivery.command_hash,
        command_type: plan.command_type,
        reserved_result_bytes: plan.reserved_result_bytes
      })

    {:ok, intent}
  end

  defp retained_outcome(command, ack) do
    %{
      hash: command.command_hash,
      status: ack.status,
      reason: ack.reason,
      result: ack.result,
      result_hash: ack.result_hash,
      sequence: command.command_sequence
    }
  end

  defp retain_and_advance(snapshot, command_id, outcome) do
    %{
      snapshot
      | outcomes: Map.put(snapshot.outcomes, command_id, outcome),
        pending_intent: nil,
        next_expected_sequence: snapshot.next_expected_sequence + 1
    }
  end

  defp fixed_hash_equal?(left, right)
       when is_binary(left) and byte_size(left) == 32 and is_binary(right) and byte_size(right) == 32,
       do: :crypto.hash_equals(left, right)

  defp fixed_hash_equal?(_left, _right), do: false

  defp exact_keys(map, expected) do
    if Enum.sort(Map.keys(map)) == Enum.sort(expected),
      do: :ok,
      else: {:error, :invalid_command_ledger_transition}
  end

  defp new_store(path, opts) do
    with {:ok, identity} <- identity(opts),
         {:ok, max_outcomes} <- positive_option(opts, :max_outcomes),
         {:ok, max_result_bytes} <- positive_option(opts, :max_result_bytes),
         {:ok, file_system} <- file_system(opts),
         {:ok, snapshot} <- Snapshot.new(identity) do
      expanded_path = Path.expand(path)

      atomic_opts =
        opts
        |> Keyword.take([:fault_injector, :temp_suffix])
        |> Keyword.put(:file_system, file_system)
        |> Keyword.put(:directory_root, Path.dirname(expanded_path))

      {:ok,
       %__MODULE__{
         path: expanded_path,
         snapshot: snapshot,
         max_outcomes: max_outcomes,
         max_result_bytes: max_result_bytes,
         file_system: file_system,
         atomic_opts: atomic_opts
       }}
    end
  end

  defp identity(opts) do
    identity = Map.new([:device_id, :credential_epoch, :storage_epoch], &{&1, Keyword.get(opts, &1)})

    case Snapshot.new(identity) do
      {:ok, _snapshot} -> {:ok, identity}
      {:error, _reason} -> {:error, :invalid_command_ledger_identity}
    end
  end

  defp positive_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {:invalid_command_ledger_option, key}}
    end
  end

  defp file_system(opts) do
    case Keyword.get(opts, :file_system, FileSystem) do
      module when is_atom(module) -> {:ok, module}
      _other -> {:error, {:invalid_command_ledger_option, :file_system}}
    end
  end

  defp initialize(store) do
    case persist_snapshot(store, store.snapshot) do
      {:ok, initialized} -> {:ok, initialized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_existing(store, snapshot) do
    with :ok <- exact_identity(store.snapshot, snapshot),
         {:ok, reestablished} <- persist_snapshot(store, snapshot) do
      {:ok, reestablished}
    end
  end

  defp exact_identity(expected, actual) do
    if actual.device_id == expected.device_id and
         actual.credential_epoch == expected.credential_epoch and
         actual.storage_epoch == expected.storage_epoch do
      :ok
    else
      {:error, :command_ledger_identity_mismatch}
    end
  end

  defp current_snapshot(store) do
    case read_snapshot(store) do
      {:ok, snapshot} when snapshot == store.snapshot -> :ok
      {:ok, _snapshot} -> {:error, :stale_command_ledger_store}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_snapshot(store) do
    case store.file_system.read(store.path) do
      {:ok, bytes} -> Snapshot.decode(bytes)
      {:error, :enoent} -> {:error, :enoent}
      {:error, reason} -> {:error, {:read_command_ledger, reason}}
      other -> {:error, {:read_command_ledger, other}}
    end
  end

  defp persist_snapshot(store, snapshot) do
    with {:ok, bytes} <- Snapshot.encode(snapshot) do
      case AtomicFile.write(store.path, bytes, store.atomic_opts) do
        :ok ->
          {:ok, %{store | snapshot: snapshot}}

        {:error, {:durability_uncertain, reason}} ->
          {:error, {:command_ledger_durability_uncertain, reason}}

        {:error, reason} ->
          {:error, {:write_command_ledger, reason}}
      end
    end
  end
end
