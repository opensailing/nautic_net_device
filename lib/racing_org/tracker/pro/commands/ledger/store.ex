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
  @path_lock_attempts 8

  @enforce_keys [
    :path,
    :snapshot,
    :max_outcomes,
    :max_result_bytes,
    :admission_authority,
    :recovery_verifiers,
    :recovery_timeout_ms,
    :file_system,
    :atomic_opts
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          path: Path.t(),
          snapshot: Snapshot.t(),
          max_outcomes: pos_integer(),
          max_result_bytes: pos_integer(),
          admission_authority: nil | {module(), term()},
          recovery_verifiers: %{optional(atom()) => {module(), term()}},
          recovery_timeout_ms: pos_integer(),
          file_system: module(),
          atomic_opts: keyword()
        }

  @doc "Open an exact identity-scoped ledger, durably creating its initial snapshot only when absent."
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, store} <- new_store(path, opts) do
      open_with_path_lock(store, @path_lock_attempts)
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

  @doc "Durably persist an intent only after the registered authority reclassifies the exact plan."
  @spec begin_intent(t(), map()) :: {:ok, Snapshot.intent(), t()} | {:error, term()}
  def begin_intent(%__MODULE__{} = store, plan) when is_map(plan) do
    with_path_lock(store, fn -> begin_intent_locked(store, plan) end)
  end

  def begin_intent(_store, _plan), do: {:error, :invalid_command_intent}

  defp begin_intent_locked(store, plan) do
    with :ok <- exact_keys(plan, [:action, :command_type, :delivery, :reserved_result_bytes, :reset_epoch?]),
         true <- plan.action == :execute,
         :ok <- current_snapshot(store),
         :ok <- no_pending_intent(store.snapshot),
         :ok <- validate_delivery(plan.delivery, store.snapshot),
         :ok <- authorize_plan(store, plan),
         {:ok, base} <- transition_base(store.snapshot, plan.delivery, plan.reset_epoch?),
         :ok <- valid_command_type(plan.command_type),
         :ok <- recovery_verifier_available(store, plan.command_type),
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

  @doc """
  Atomically retain an applied result, clear its intent, and advance before
  returning an ACK.

  Expiry is checked before intent admission, never after an external effect may
  have started. Completion therefore records a proven applied result even when
  the command's original expiry has elapsed.
  """
  @spec complete_intent(t(), binary()) :: {:ok, map(), t()} | {:error, term()}
  def complete_intent(%__MODULE__{} = store, result) do
    with_path_lock(store, fn -> complete_intent_locked(store, result) end)
  end

  def complete_intent(_store, _result), do: {:error, :invalid_command_ledger_store}

  defp complete_intent_locked(store, result) do
    with :ok <- current_snapshot(store),
         {:ok, intent} <- fetch_pending_intent(store.snapshot),
         :ok <- valid_result(result),
         :ok <- within_reservation(result, intent.reserved_result_bytes),
         {:ok, ack} <- Ack.build(intent, :applied, :none, result),
         outcome = retained_outcome(intent, ack),
         intended = retain_and_advance(store.snapshot, intent.command_id, outcome),
         {:ok, persisted} <- persist_snapshot(store, intended) do
      {:ok, ack, persisted}
    end
  end

  @doc """
  Durably reject a pending intent only after exact proof that its effect did not
  apply.

  The closed rejection plan is bound to the pending command ID, command hash,
  command type, a registered non-application proof, and a reason that remains
  truthful after intent admission. Ambiguous effects remain pending.

  Recovery-verifier modules are trusted authorities. Their
  `with_non_application_lease/5` callback must invoke the supplied transition
  synchronously and exactly once from the process that owns the command-specific
  non-application lease, retaining that lease until the transition returns.
  Once a transition starts, this store retains its path lock until the executor
  finishes or dies; the configured timeout only bounds a verifier that has not
  started a transition.
  """
  @spec reject_intent(t(), map()) :: {:ok, map(), t()} | {:error, term()}
  def reject_intent(%__MODULE__{} = store, plan) when is_map(plan) do
    with_path_lock(store, fn -> reject_intent_locked(store, plan) end)
  end

  def reject_intent(_store, _plan), do: {:error, :invalid_command_rejection_plan}

  defp reject_intent_locked(store, plan) do
    with :ok <- current_snapshot(store),
         {:ok, intent} <- fetch_pending_intent(store.snapshot),
         :ok <- valid_rejection_plan(plan, intent),
         {:ok, ack} <- Ack.build(intent, :rejected, plan.reason, <<>>),
         outcome = retained_outcome(intent, ack),
         intended = retain_and_advance(store.snapshot, intent.command_id, outcome),
         {:ok, persisted} <- persist_verified_rejection(store, intent, plan, intended) do
      {:ok, ack, persisted}
    end
  end

  @doc "Durably retain a terminal non-execution result and advance before returning an ACK."
  @spec record_terminal(t(), map()) :: {:ok, map(), t()} | {:error, term()}
  def record_terminal(%__MODULE__{} = store, plan) when is_map(plan) do
    with_path_lock(store, fn -> record_terminal_locked(store, plan) end)
  end

  def record_terminal(_store, _plan), do: {:error, :invalid_terminal_command_outcome}

  defp record_terminal_locked(store, plan) do
    with :ok <- exact_keys(plan, [:action, :delivery, :reason, :reset_epoch?, :result, :status]),
         true <- plan.action == :terminal,
         true <- plan.status == :rejected,
         true <- plan.reason in @terminal_reasons,
         :ok <- valid_result(plan.result),
         :ok <- current_snapshot(store),
         :ok <- no_pending_intent(store.snapshot),
         :ok <- validate_delivery(plan.delivery, store.snapshot),
         :ok <- authorize_plan(store, plan),
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

  defp no_pending_intent(%Snapshot{pending_intent: nil}), do: :ok
  defp no_pending_intent(%Snapshot{}), do: {:error, :pending_command_intent}

  defp fetch_pending_intent(%Snapshot{pending_intent: nil}), do: {:error, :no_pending_command_intent}
  defp fetch_pending_intent(%Snapshot{pending_intent: intent}), do: {:ok, intent}

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

  defp authorize_plan(%__MODULE__{admission_authority: {module, context}} = store, plan) do
    case module.authorize(plan, store.snapshot, limits(store), context) do
      :ok -> :ok
      {:error, _reason} = error -> error
      _other -> {:error, :command_admission_not_authoritative}
    end
  rescue
    _exception -> {:error, :command_admission_unavailable}
  catch
    _kind, _reason -> {:error, :command_admission_unavailable}
  end

  defp authorize_plan(%__MODULE__{}, _plan), do: {:error, :command_admission_unavailable}

  defp valid_command_type(command_type) when is_atom(command_type), do: :ok
  defp valid_command_type(_command_type), do: {:error, :invalid_command_type}

  defp recovery_verifier_available(store, command_type) do
    if Map.has_key?(store.recovery_verifiers, command_type),
      do: :ok,
      else: {:error, {:missing_command_recovery_verifier, command_type}}
  end

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

  defp persist_verified_rejection(store, intent, plan, intended) do
    case Map.fetch(store.recovery_verifiers, intent.command_type) do
      {:ok, {module, context}} ->
        run_recovery_verifier(
          store,
          fn transition ->
            module.with_non_application_lease(
              intent,
              plan.proof,
              plan.reason,
              context,
              transition
            )
          end,
          fn -> persist_snapshot(store, intended) end
        )

      :error ->
        {:error, :effect_non_application_unverified}
    end
  end

  defp run_recovery_verifier(store, verifier, transition) do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      do_run_recovery_verifier(store, verifier, transition)
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp do_run_recovery_verifier(store, verifier, transition) do
    caller = self()
    result_ref = make_ref()
    transition_ref = make_ref()
    transition_state = :atomics.new(1, signed: false)
    transition_results = :ets.new(__MODULE__, [:set, :public])

    {pid, monitor_ref} =
      :erlang.spawn_opt(
        fn ->
          result =
            invoke_recovery_verifier(
              verifier,
              transition,
              transition_state,
              transition_results,
              caller,
              transition_ref
            )

          send(caller, {result_ref, result})
        end,
        [:link, :monitor]
      )

    result =
      receive do
        {^result_ref, result} ->
          Process.unlink(pid)
          Process.demonitor(monitor_ref, [:flush])
          result

        {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
          recovery_verifier_down(
            transition_state,
            transition_results,
            transition_ref
          )
      after
        store.recovery_timeout_ms ->
          cancel_recovery_verifier(
            pid,
            monitor_ref,
            result_ref,
            transition_state,
            transition_results,
            transition_ref
          )
      end

    Process.unlink(pid)
    flush_link_exit(pid)
    :ets.delete(transition_results)
    result
  end

  defp flush_link_exit(pid) do
    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp cancel_recovery_verifier(
         pid,
         monitor_ref,
         _result_ref,
         transition_state,
         transition_results,
         transition_ref
       ) do
    state =
      case :atomics.compare_exchange(transition_state, 1, 0, 3) do
        :ok ->
          3

        1 ->
          await_recovery_transition(transition_state, transition_results, transition_ref)

        4 ->
          if :ets.lookup(transition_results, :result) == [],
            do: await_recovery_transition(transition_state, transition_results, transition_ref),
            else: 4

        completed_state ->
          completed_state
      end

    Process.exit(pid, :kill)
    await_recovery_verifier_down(pid, monitor_ref)
    recovery_timeout_result(state)
  end

  defp recovery_timeout_result(3), do: {:error, :command_recovery_verifier_timeout}

  defp recovery_timeout_result(5) do
    {:error, {:command_ledger_durability_uncertain, :command_recovery_transition_failed}}
  end

  defp recovery_timeout_result(_completed_or_invalid_state) do
    {:error, {:command_ledger_durability_uncertain, :command_recovery_verifier_timeout}}
  end

  defp recovery_verifier_down(transition_state, transition_results, transition_ref) do
    transition_state
    |> close_or_await_recovery_transition(transition_results, transition_ref)
    |> recovery_verifier_failure_result(transition_results)
  end

  defp recovery_verifier_failure_result(3, _transition_results),
    do: {:error, :effect_non_application_unverified}

  defp recovery_verifier_failure_result(4, transition_results) do
    if :ets.lookup(transition_results, :result) == [] do
      {:error, {:command_ledger_durability_uncertain, :command_recovery_transition_failed}}
    else
      {:error, {:command_ledger_durability_uncertain, :command_recovery_verifier_invalid_transition}}
    end
  end

  defp recovery_verifier_failure_result(5, _transition_results) do
    {:error, {:command_ledger_durability_uncertain, :command_recovery_transition_failed}}
  end

  defp recovery_verifier_failure_result(_completed_state, _transition_results) do
    {:error, {:command_ledger_durability_uncertain, :command_recovery_verifier_failed}}
  end

  defp await_recovery_verifier_down(pid, monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp invoke_recovery_verifier(
         verifier,
         transition,
         transition_state,
         transition_results,
         transition_observer,
         transition_ref
       ) do
    verifier_process = self()

    transition_once = fn ->
      case :atomics.compare_exchange(transition_state, 1, 0, 1) do
        :ok ->
          execute_recovery_transition(
            transition,
            transition_state,
            transition_results,
            verifier_process,
            transition_observer,
            transition_ref
          )

        closed_state when closed_state in [3, 5] ->
          {:error, :recovery_transition_unavailable}

        _already_called ->
          :atomics.put(transition_state, 1, 4)
          {:error, :recovery_transition_already_called}
      end
    end

    verifier_result = invoke_recovery_provider(verifier, transition_once)

    transition_state
    |> close_or_await_recovery_transition(transition_results, transition_ref)
    |> normalize_recovery_verifier_result(transition_results, verifier_result)
  end

  defp execute_recovery_transition(
         transition,
         transition_state,
         transition_results,
         verifier_process,
         transition_observer,
         transition_ref
       ) do
    executor = {self(), make_ref()}
    true = :ets.insert(transition_results, {:executor, executor})

    if :atomics.get(transition_state, 1) == 1 do
      result = invoke_recovery_transition(transition, transition_observer)
      true = :ets.insert(transition_results, {:result, result})
      completion = :atomics.compare_exchange(transition_state, 1, 1, 2)
      :ets.delete_object(transition_results, {:executor, executor})
      send(verifier_process, {transition_ref, :finished})
      send(transition_observer, {transition_ref, :finished})

      case completion do
        :ok -> result
        _duplicate_call -> {:error, :recovery_transition_already_called}
      end
    else
      :ets.delete_object(transition_results, {:executor, executor})
      send(verifier_process, {transition_ref, :finished})
      send(transition_observer, {transition_ref, :finished})
      {:error, :recovery_transition_already_called}
    end
  end

  defp invoke_recovery_provider(verifier, transition_once) do
    verifier.(transition_once)
  rescue
    _exception -> {:error, :effect_non_application_unverified}
  catch
    _kind, _reason -> {:error, :effect_non_application_unverified}
  end

  defp invoke_recovery_transition(transition, lock_holder) do
    {:links, links} = Process.info(self(), :links)
    already_linked? = lock_holder in links

    if Process.info(self(), :trap_exit) == {:trap_exit, false} do
      unless already_linked?, do: Process.link(lock_holder)

      try do
        transition.()
      after
        unless already_linked?, do: Process.unlink(lock_holder)
      end
    else
      {:error, {:command_ledger_durability_uncertain, :command_recovery_transition_failed}}
    end
  rescue
    _exception ->
      {:error, {:command_ledger_durability_uncertain, :command_recovery_transition_failed}}
  catch
    _kind, _reason ->
      {:error, {:command_ledger_durability_uncertain, :command_recovery_transition_failed}}
  end

  defp close_or_await_recovery_transition(transition_state, transition_results, transition_ref) do
    case :atomics.compare_exchange(transition_state, 1, 0, 3) do
      :ok ->
        3

      1 ->
        await_recovery_transition(transition_state, transition_results, transition_ref)

      4 ->
        case :ets.lookup(transition_results, :result) do
          [] -> await_recovery_transition(transition_state, transition_results, transition_ref)
          [{:result, _result}] -> 4
        end

      completed_state ->
        completed_state
    end
  end

  defp await_recovery_transition(transition_state, transition_results, transition_ref) do
    case :ets.lookup(transition_results, :executor) do
      [{:executor, {executor, _claim_ref}}] ->
        executor_monitor_ref = Process.monitor(executor)

        receive do
          {^transition_ref, :finished} ->
            Process.demonitor(executor_monitor_ref, [:flush])
            :atomics.get(transition_state, 1)

          {:DOWN, ^executor_monitor_ref, :process, ^executor, _reason} ->
            case :atomics.compare_exchange(transition_state, 1, 1, 5) do
              :ok -> 5
              completed_state -> completed_state
            end
        end

      [] ->
        case :atomics.compare_exchange(transition_state, 1, 1, 5) do
          :ok ->
            5

          4 ->
            :atomics.put(transition_state, 1, 5)
            5

          completed_state ->
            completed_state
        end
    end
  end

  defp normalize_recovery_verifier_result(state, transition_results, verifier_result) do
    case {state, :ets.lookup(transition_results, :result), verifier_result} do
      {2, [{:result, transition_result}], verifier_result}
      when transition_result === verifier_result ->
        transition_result

      {2, [{:result, _transition_result}], _mismatched_result} ->
        {:error, {:command_ledger_durability_uncertain, :command_recovery_verifier_result_mismatch}}

      {3, [], {:error, :effect_non_application_unverified} = error} ->
        error

      {4, [{:result, _transition_result}], _verifier_result} ->
        {:error, {:command_ledger_durability_uncertain, :command_recovery_verifier_invalid_transition}}

      {5, _result, _verifier_result} ->
        {:error, {:command_ledger_durability_uncertain, :command_recovery_transition_failed}}

      _other ->
        {:error, :effect_non_application_unverified}
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
    with :ok <- available_destination_path(path),
         {:ok, identity} <- identity(opts),
         {:ok, max_outcomes} <- positive_option(opts, :max_outcomes),
         {:ok, max_result_bytes} <- positive_option(opts, :max_result_bytes),
         {:ok, admission_authority} <- admission_authority(opts),
         {:ok, recovery_verifiers} <- recovery_verifiers(opts),
         {:ok, recovery_timeout_ms} <- recovery_timeout(opts),
         {:ok, file_system} <- file_system(opts),
         {:ok, canonical_path} <- canonical_ledger_path(path),
         :ok <- available_destination_path(canonical_path),
         {:ok, snapshot} <- Snapshot.new(identity) do
      atomic_opts =
        opts
        |> Keyword.take([:fault_injector, :temp_suffix])
        |> Keyword.put(:file_system, file_system)
        |> Keyword.put(:directory_root, Path.dirname(canonical_path))

      {:ok,
       %__MODULE__{
         path: canonical_path,
         snapshot: snapshot,
         max_outcomes: max_outcomes,
         max_result_bytes: max_result_bytes,
         admission_authority: admission_authority,
         recovery_verifiers: recovery_verifiers,
         recovery_timeout_ms: recovery_timeout_ms,
         file_system: file_system,
         atomic_opts: atomic_opts
       }}
    end
  end

  defp available_destination_path(path) do
    if AtomicFile.reserved_temporary_path?(path),
      do: {:error, {:invalid_command_ledger_path, :reserved_atomic_temp_name}},
      else: :ok
  end

  defp canonical_ledger_path(path) do
    path
    |> Path.expand()
    |> resolve_symlinks(32)
  end

  defp resolve_symlinks(_path, 0), do: {:error, :command_ledger_symlink_limit}

  defp resolve_symlinks(path, remaining) do
    case Path.split(path) do
      [root | parts] -> resolve_path_parts(root, parts, remaining)
      [] -> {:error, :invalid_command_ledger_path}
    end
  end

  defp resolve_path_parts(current, [], _remaining), do: {:ok, current}

  defp resolve_path_parts(current, [part | rest], remaining) do
    candidate = Path.join(current, part)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(candidate) do
          target
          |> symlink_target(current)
          |> append_path_parts(rest)
          |> resolve_symlinks(remaining - 1)
        end

      {:ok, _stat} ->
        resolve_path_parts(candidate, rest, remaining)

      {:error, :enoent} ->
        {:ok, append_path_parts(candidate, rest)}

      {:error, reason} ->
        {:error, {:command_ledger_path, reason}}
    end
  end

  defp symlink_target(target, parent) do
    case Path.type(target) do
      :absolute -> Path.expand(target)
      :relative -> Path.expand(target, parent)
      :volumerelative -> Path.expand(target, parent)
    end
  end

  defp append_path_parts(path, parts), do: Enum.reduce(parts, path, &Path.join(&2, &1))

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

  defp recovery_timeout(opts) do
    case Keyword.get(opts, :recovery_timeout_ms, 5_000) do
      value when is_integer(value) and value > 0 and value <= 60_000 -> {:ok, value}
      _other -> {:error, {:invalid_command_ledger_option, :recovery_timeout_ms}}
    end
  end

  defp admission_authority(opts) do
    case Keyword.get(opts, :admission_authority) do
      nil ->
        {:ok, nil}

      {module, context} when is_atom(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, :authorize, 4),
          do: {:ok, {module, context}},
          else: {:error, {:invalid_command_ledger_option, :admission_authority}}

      _other ->
        {:error, {:invalid_command_ledger_option, :admission_authority}}
    end
  end

  defp recovery_verifiers(opts) do
    verifiers = Keyword.get(opts, :recovery_verifiers, %{})

    if is_map(verifiers) and
         Enum.all?(verifiers, fn
           {command_type, {module, _context}} when is_atom(command_type) and is_atom(module) ->
             Code.ensure_loaded?(module) and
               function_exported?(module, :with_non_application_lease, 5)

           _other ->
             false
         end) do
      {:ok, verifiers}
    else
      {:error, {:invalid_command_ledger_option, :recovery_verifiers}}
    end
  end

  defp file_system(opts) do
    case Keyword.get(opts, :file_system, FileSystem) do
      module when is_atom(module) -> {:ok, module}
      _other -> {:error, {:invalid_command_ledger_option, :file_system}}
    end
  end

  defp open_with_path_lock(_store, 0), do: {:error, :command_ledger_path_unstable}

  defp open_with_path_lock(store, attempts_remaining) do
    case with_path_lock(store, fn -> prepare_and_open_locked(store) end, classify_holder_death?: false) do
      {:retry_command_ledger_path, canonical_path} ->
        store
        |> rebase_store_path(canonical_path)
        |> open_with_path_lock(attempts_remaining - 1)

      result ->
        result
    end
  end

  defp prepare_and_open_locked(store) do
    with :ok <- prepare_parent_directory(store),
         {:ok, canonical_path} <- canonical_ledger_path(store.path),
         :ok <- available_destination_path(canonical_path) do
      if canonical_path == store.path do
        case read_snapshot(store) do
          {:ok, snapshot} -> open_existing(store, snapshot)
          {:error, :enoent} -> initialize(store)
          {:error, reason} -> {:error, reason}
        end
      else
        {:retry_command_ledger_path, canonical_path}
      end
    end
  end

  defp prepare_parent_directory(store) do
    case AtomicFile.ensure_directory(Path.dirname(store.path), store.atomic_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:prepare_command_ledger_directory, reason}}
    end
  end

  defp rebase_store_path(store, canonical_path) do
    atomic_opts = Keyword.put(store.atomic_opts, :directory_root, Path.dirname(canonical_path))
    %{store | path: canonical_path, atomic_opts: atomic_opts}
  end

  defp initialize(store) do
    with :ok <- cleanup_orphan_temps(store),
         {:ok, initialized} <- persist_snapshot(store, store.snapshot) do
      {:ok, initialized}
    end
  end

  defp open_existing(store, snapshot) do
    with :ok <- exact_identity(store.snapshot, snapshot),
         :ok <- pending_recovery_available(store, snapshot),
         :ok <- cleanup_orphan_temps(store),
         {:ok, reestablished} <- persist_snapshot(store, snapshot) do
      {:ok, reestablished}
    end
  end

  defp cleanup_orphan_temps(store),
    do: AtomicFile.cleanup_orphan_temps(store.path, store.atomic_opts)

  defp pending_recovery_available(_store, %Snapshot{pending_intent: nil}), do: :ok

  defp pending_recovery_available(store, %Snapshot{pending_intent: intent}),
    do: recovery_verifier_available(store, intent.command_type)

  defp exact_identity(expected, actual) do
    if actual.device_id == expected.device_id and
         actual.credential_epoch == expected.credential_epoch and
         actual.storage_epoch == expected.storage_epoch do
      :ok
    else
      {:error, :command_ledger_identity_mismatch}
    end
  end

  defp with_path_lock(store, transition, opts \\ []) when is_function(transition, 0) do
    if Process.get(path_lock_marker(store.path)) do
      {:error, :command_ledger_path_reentry}
    else
      caller = self()
      result_ref = make_ref()

      {holder, monitor_ref} =
        spawn_monitor(fn ->
          lock_id = {{__MODULE__, store.path}, self()}
          result = run_path_transition(lock_id, store.path, transition)
          send(caller, {result_ref, result})
        end)

      receive do
        {^result_ref, result} ->
          Process.demonitor(monitor_ref, [:flush])
          result

        {:DOWN, ^monitor_ref, :process, ^holder, _reason} ->
          holder_failure_result(store, opts)
      end
    end
  end

  defp holder_failure_result(store, opts) do
    if Keyword.get(opts, :classify_holder_death?, true) do
      case read_snapshot(store) do
        {:ok, snapshot} when snapshot == store.snapshot ->
          {:error, :command_ledger_lock_holder_failed}

        _changed_or_unreadable ->
          {:error, {:command_ledger_durability_uncertain, :command_ledger_lock_holder_failed}}
      end
    else
      {:error, :command_ledger_lock_holder_failed}
    end
  end

  defp run_path_transition(lock_id, path, transition) do
    case :global.trans(lock_id, fn -> run_marked_path_transition(path, transition) end) do
      {:aborted, reason} -> {:error, {:command_ledger_lock_aborted, reason}}
      result -> result
    end
  rescue
    _exception -> {:error, :command_ledger_lock_holder_failed}
  catch
    _kind, _reason -> {:error, :command_ledger_lock_holder_failed}
  end

  defp run_marked_path_transition(path, transition) do
    marker = path_lock_marker(path)
    Process.put(marker, true)

    try do
      transition.()
    after
      Process.delete(marker)
    end
  end

  defp path_lock_marker(path), do: {__MODULE__, :path_lock, path}

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
