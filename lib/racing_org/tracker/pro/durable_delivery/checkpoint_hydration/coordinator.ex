defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.Coordinator do
  @moduledoc """
  Serializes crash-safe installation of exact-runtime checkpoint hydrations.

  The coordinator closes the active Desired State runtime before observing or
  mutating a checkpoint head. Its journal is the recovery authority across the
  checkpoint-head and observer stores; the Manager blocker is released only after
  the exact observer restore and durable journal removal both succeed.
  """

  use GenServer

  alias RacingOrg.Tracker.Pro.Calibration.Observer, as: CalibrationObserver
  alias RacingOrg.Tracker.Pro.DesiredState.Manager
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.{Record, Store}
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.{Journal, RuntimeRegistry}
  alias RacingOrg.Tracker.Pro.Polar.Observer, as: PolarObserver
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Pro.WindShift.Observer, as: WindShiftObserver

  @zero_identifier <<0::128>>
  @default_manager_retry_ms 100
  @manager_retry_errors [
    :checkpoint_hydration_manager_unavailable,
    :checkpoint_hydration_binding_unavailable,
    :checkpoint_hydration_coordinator_mismatch,
    :checkpoint_hydration_token_mismatch,
    :checkpoint_hydration_not_blocked
  ]
  @hydrate_keys [
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :origin_credential_epoch,
    :origin_storage_epoch,
    :sequence,
    :kind,
    :schema_version,
    :source_generation,
    :parent_hash,
    :content_hash,
    :checkpoint_hash,
    :content
  ]

  @type hydration :: %{
          required(:device_id) => <<_::128>>,
          required(:credential_epoch) => non_neg_integer(),
          required(:storage_epoch) => <<_::128>>,
          required(:origin_credential_epoch) => non_neg_integer(),
          required(:origin_storage_epoch) => <<_::128>>,
          required(:sequence) => pos_integer(),
          required(:kind) => atom(),
          required(:schema_version) => pos_integer(),
          required(:source_generation) => non_neg_integer(),
          required(:parent_hash) => <<_::256>>,
          required(:content_hash) => <<_::256>>,
          required(:checkpoint_hash) => <<_::256>>,
          required(:content) => binary()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Install one already-authenticated exact-runtime checkpoint."
  @spec hydrate(GenServer.server(), SessionHolder.generation(), hydration()) ::
          {:ok, :hydrated} | {:error, term()}
  def hydrate(server \\ __MODULE__, session_generation, hydration) do
    GenServer.call(server, {:hydrate, session_generation, hydration}, :infinity)
  end

  @doc "Retry the retained recovery transition synchronously."
  @spec recover(GenServer.server()) :: :ok | {:error, term()}
  def recover(server \\ __MODULE__), do: GenServer.call(server, :recover, :infinity)

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Return the production closed dispatch for exact observer runtimes."
  @spec production_registry() :: RuntimeRegistry.t()
  def production_registry do
    {:ok, registry} =
      RuntimeRegistry.new([
        {:calibration, 2, CheckpointRuntime.Calibration},
        {:polar, 3, CheckpointRuntime.Polar},
        {:wind_shift, 2, CheckpointRuntime.WindShift}
      ])

    registry
  end

  @doc false
  @spec production_restorers() :: map()
  def production_restorers do
    %{
      calibration: {CalibrationObserver, :restore},
      polar: {PolarObserver, :restore_runtime},
      wind_shift: {WindShiftObserver, :restore}
    }
  end

  @impl true
  def init(opts) do
    state = %{
      journal_path: Keyword.fetch!(opts, :journal_path),
      head_store: Keyword.fetch!(opts, :head_store),
      manager: Keyword.get(opts, :manager, Manager),
      session_holder: Keyword.get(opts, :session_holder, SessionHolder),
      registry: Keyword.get_lazy(opts, :registry, &production_registry/0),
      restorers: Keyword.get_lazy(opts, :restorers, &production_restorers/0),
      transaction_id: Keyword.get(opts, :transaction_id, fn -> :crypto.strong_rand_bytes(16) end),
      journal_module: Keyword.get(opts, :journal_module, Journal),
      store_module: Keyword.get(opts, :store_module, Store),
      manager_module: Keyword.get(opts, :manager_module, Manager),
      manager_retry_ms: Keyword.get(opts, :manager_retry_ms, @default_manager_retry_ms),
      manager_monitor_ref: nil,
      manager_pid: nil,
      manager_retry_ref: nil,
      manager_retry_token: nil,
      session_holder_module: Keyword.get(opts, :session_holder_module, SessionHolder),
      checkpoint_module: Keyword.get(opts, :checkpoint_module, Checkpoint),
      record_module: Keyword.get(opts, :record_module, Record),
      journal_opts: Keyword.get(opts, :journal_opts, []),
      boundary: Keyword.get(opts, :boundary, fn _stage -> :ok end),
      reconcile_empty_journal?: Keyword.get(opts, :reconcile_empty_journal, false) == true,
      blocker: nil,
      selected_head: nil,
      reconciliation_heads: %{},
      fresh_request?: false,
      recovery_required?: false,
      recovery_error: nil
    }

    state = monitor_manager(state)

    case recover_state(state) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason, %{blocker: nil} = state} ->
        cond do
          retryable_manager_error?(state, reason) ->
            state = %{state | recovery_required?: true, recovery_error: reason}
            {:ok, schedule_manager_retry(state)}

          reason == :checkpoint_hydration_binding_failed ->
            {:ok, %{state | recovery_required?: true, recovery_error: reason}}

          true ->
            {:ok, %{state | recovery_error: reason}}
        end

      {:error, reason, state} ->
        {:ok, state |> Map.put(:recovery_error, reason) |> maybe_retry_manager(reason)}
    end
  end

  @impl true
  def format_status(status) when is_map(status) do
    state = Map.get(status, :state)

    %{
      state: safe_status(state),
      message: :redacted,
      reason: :redacted,
      log: :redacted
    }
  end

  def format_status(_status) do
    %{
      state: safe_status(nil),
      message: :redacted,
      reason: :redacted,
      log: :redacted
    }
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, safe_status(state), state}
  end

  def handle_call(:recover, _from, %{recovery_required?: true} = state) do
    case recover_unreadable_journal(state) do
      {:ok, state} ->
        {:reply, :ok, cancel_manager_retry(state)}

      {:error, reason, state} ->
        {:reply, {:error, public_recovery_error(state, reason)}, %{state | recovery_error: reason}}
    end
  end

  def handle_call(:recover, _from, %{blocker: nil} = state) do
    case recover_state(state) do
      {:ok, state} -> {:reply, :ok, cancel_manager_retry(state)}
      {:error, reason, state} -> {:reply, {:error, reason}, %{state | recovery_error: reason}}
    end
  end

  def handle_call(:recover, _from, state) do
    case recover_blocked_state(state) do
      {:ok, state} -> {:reply, :ok, cancel_manager_retry(state)}
      {:error, reason, state} -> {:reply, {:error, reason}, %{state | recovery_error: reason}}
    end
  end

  def handle_call(
        {:hydrate, _session_generation, _hydration},
        _from,
        %{recovery_required?: true} = state
      ) do
    {:reply, {:error, :checkpoint_hydration_recovery_required}, state}
  end

  def handle_call({:hydrate, _session_generation, _hydration}, _from, %{blocker: blocker} = state)
      when not is_nil(blocker) do
    {:reply, {:error, :checkpoint_hydration_recovery_required}, state}
  end

  def handle_call({:hydrate, session_generation, hydration}, _from, state) do
    case start_hydration(state, session_generation, hydration) do
      {:ok, state} ->
        {:reply, {:ok, :hydrated}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, %{state | fresh_request?: false, recovery_error: reason}}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, monitor_ref, :process, manager_pid, _reason},
        %{manager_monitor_ref: monitor_ref, manager_pid: manager_pid} = state
      ) do
    state =
      state
      |> Map.put(:manager_monitor_ref, nil)
      |> Map.put(:manager_pid, nil)
      |> Map.put(:recovery_required?, true)
      |> Map.put(:recovery_error, :checkpoint_hydration_manager_unavailable)
      |> schedule_manager_retry()

    {:noreply, state}
  end

  def handle_info(
        {:retry_manager_recovery, token},
        %{manager_retry_token: token} = state
      ) do
    state =
      state
      |> Map.put(:manager_retry_ref, nil)
      |> Map.put(:manager_retry_token, nil)
      |> monitor_manager()

    state =
      case recover_for_retry(state) do
        {:ok, state} -> state
        {:error, reason, state} -> state |> Map.put(:recovery_error, reason) |> maybe_retry_manager(reason)
      end

    {:noreply, state}
  end

  def handle_info({:retry_manager_recovery, _stale_token}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp start_hydration(state, session_generation, hydration) do
    with {:ok, hydration} <- validate_hydration_shape(hydration),
         {:ok, authorization} <- current_session_authorization(state, session_generation) do
      start_authorized_hydration(state, authorization, hydration)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp start_authorized_hydration(state, authorization, hydration) do
    with {:ok, binding} <- current_binding(state),
         :ok <- match_target(hydration, binding),
         :ok <- match_session(authorization, binding),
         {:ok, adapter} <- RuntimeRegistry.fetch(state.registry, hydration.kind, hydration.schema_version),
         :ok <- validate_hydration_integrity(state, hydration),
         {:ok, runtime} <- decode_runtime(state, adapter, hydration, binding),
         {:ok, transaction_id} <- transaction_id(state) do
      begin_transition(state, authorization, transaction_id, binding, hydration, runtime)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp begin_transition(state, authorization, transaction_id, binding, hydration, runtime) do
    token = make_ref()

    case revalidate_authorization(state, authorization) do
      :ok ->
        begin_authorized_transition(
          state,
          token,
          binding,
          authorization,
          transaction_id,
          hydration,
          runtime
        )

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp begin_authorized_transition(
         state,
         token,
         binding,
         authorization,
         transaction_id,
         hydration,
         runtime
       ) do
    case manager_begin(state, token, binding) do
      :ok ->
        state = %{
          state
          | blocker: blocker(token, binding, authorization, transaction_id, hydration),
            fresh_request?: true
        }

        case boundary(state, :after_begin) do
          :ok ->
            case prepare_transition(state, runtime) do
              {:ok, state} -> complete_transition(state, runtime)
              {:error, reason, state} -> {:error, reason, state}
            end

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp recover_state(state) do
    case journal_read(state) do
      :empty when state.reconcile_empty_journal? ->
        reconcile_empty_journal(state)

      :empty ->
        {:ok,
         %{
           state
           | blocker: nil,
             selected_head: nil,
             recovery_required?: false,
             recovery_error: nil
         }}

      {:ok, record} ->
        recover_record(state, record)

      {:error, reason} ->
        retain_unreadable_journal_barrier(state, reason)
    end
  end

  defp retain_unreadable_journal_barrier(state, reason) do
    state = %{state | recovery_required?: true}

    with {:ok, manager_state} <- manager_state(state),
         {:ok, binding} <- active_binding(manager_state),
         :ok <- match_target(binding, manager_state.identity),
         token = make_ref(),
         :ok <- manager_begin(state, token, binding) do
      {:error, reason,
       %{
         state
         | blocker: %{token: token, binding: binding, record: nil},
           selected_head: nil,
           reconciliation_heads: %{}
       }}
    else
      {:error, _barrier_reason} -> {:error, reason, state}
    end
  end

  defp recover_unreadable_journal(state) do
    case journal_read(state) do
      :empty ->
        reconcile_empty_journal(%{
          state
          | blocker: nil,
            selected_head: nil,
            reconciliation_heads: %{},
            recovery_required?: false
        })

      {:ok, record} ->
        recover_record(
          %{
            state
            | blocker: nil,
              selected_head: nil,
              reconciliation_heads: %{},
              recovery_required?: false
          },
          record
        )

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp reconcile_empty_journal(state) do
    with {:ok, manager_state} <- manager_state(state),
         {:ok, binding} <- active_binding(manager_state),
         :ok <- match_target(binding, manager_state.identity),
         token = make_ref(),
         :ok <- manager_begin(state, token, binding) do
      state = %{
        state
        | blocker: %{token: token, binding: binding, record: nil},
          selected_head: nil,
          reconciliation_heads: %{},
          fresh_request?: false
      }

      with {:ok, state} <- restore_current_heads(state, RuntimeRegistry.entries(state.registry)),
           :ok <- revalidate_binding_without_record(state),
           :ok <- ensure_reconciliation_heads_current(state),
           :ok <- manager_finish(state) do
        {:ok,
         %{
           state
           | blocker: nil,
             selected_head: nil,
             reconciliation_heads: %{},
             recovery_required?: false,
             recovery_error: nil
         }}
      else
        {:error, reason, %{} = state} -> {:error, reason, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp restore_current_heads(state, entries) do
    Enum.reduce_while(entries, {:ok, state}, fn {kind, schema_version, adapter}, {:ok, state} ->
      case state.store_module.head(state.head_store, kind) do
        :empty ->
          {:cont, {:ok, state}}

        {:ok, selected_head} ->
          with true <- selected_head.schema_version == schema_version,
               :ok <- state.record_module.verify(selected_head),
               :ok <- match_reconciliation_head(state, selected_head),
               {:ok, runtime} <- decode_runtime(state, adapter, selected_head, state.blocker.binding),
               {:ok, {module, function}} <- Map.fetch(state.restorers, kind),
               :ok <- restore_with(module, function, runtime) do
            state = put_in(state.reconciliation_heads[kind], selected_head)
            {:cont, {:ok, state}}
          else
            false -> {:halt, {:error, :checkpoint_hydration_head_schema_mismatch, state}}
            :error -> {:halt, {:error, :unknown_checkpoint_runtime_restorer, state}}
            {:error, reason} -> {:halt, {:error, reason, state}}
          end

        {:error, reason} ->
          {:halt, {:error, reason, state}}
      end
    end)
  end

  defp ensure_reconciliation_heads_current(state) do
    Enum.reduce_while(state.reconciliation_heads, :ok, fn {kind, selected_head}, :ok ->
      case state.store_module.head(state.head_store, kind) do
        {:ok, current_head} ->
          if same_selected_head?(selected_head, current_head),
            do: {:cont, :ok},
            else: {:halt, {:error, :checkpoint_hydration_head_changed}}

        :empty ->
          {:halt, {:error, :checkpoint_hydration_head_changed}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp revalidate_binding_without_record(%{blocker: %{binding: binding}} = state) do
    with {:ok, manager_state} <- manager_state(state),
         {:ok, active_binding} <- active_binding(manager_state),
         :ok <- match_binding(active_binding, binding),
         :ok <- match_target(binding, manager_state.identity) do
      :ok
    end
  end

  defp match_reconciliation_head(%{blocker: %{binding: binding}}, selected_head) do
    if selected_head.device_id == binding.device_id and
         selected_head.local_credential_epoch == binding.credential_epoch and
         selected_head.local_storage_epoch == binding.storage_epoch do
      :ok
    else
      {:error, :checkpoint_hydration_selected_head_mismatch}
    end
  end

  defp recover_blocked_state(%{blocker: %{record: nil}, reconcile_empty_journal?: true} = state),
    do: retry_empty_journal_reconciliation(state)

  defp recover_blocked_state(state) do
    case journal_read(state) do
      {:ok, record} ->
        recover_record(state, record)

      :empty ->
        {:error, :checkpoint_hydration_recovery_evidence_missing, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp recover_for_retry(%{recovery_required?: true, blocker: nil} = state) do
    state = %{state | recovery_required?: false}

    case recover_state(state) do
      {:error, reason, %{blocker: nil} = errored} ->
        if retryable_manager_error?(errored, reason) or
             reason == :checkpoint_hydration_binding_failed do
          {:error, reason, %{state | recovery_required?: true}}
        else
          {:error, reason, errored}
        end

      result ->
        result
    end
  end

  defp recover_for_retry(%{blocker: nil} = state), do: recover_state(state)

  defp recover_for_retry(%{blocker: %{record: nil}, reconcile_empty_journal?: true} = state),
    do: retry_empty_journal_reconciliation(state)

  defp recover_for_retry(state) do
    case journal_read(state) do
      {:ok, record} ->
        case recover_record(%{state | blocker: nil, selected_head: nil}, record) do
          {:error, reason, %{blocker: nil}} -> {:error, reason, state}
          result -> result
        end

      :empty ->
        {:error, :checkpoint_hydration_recovery_evidence_missing, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp retry_empty_journal_reconciliation(state) do
    case reconcile_empty_journal(%{state | blocker: nil, reconciliation_heads: %{}}) do
      {:error, reason, %{blocker: nil}} -> {:error, reason, state}
      result -> result
    end
  end

  defp recover_record(%{blocker: blocker} = state, record) when not is_nil(blocker) do
    if same_transition?(blocker.record, record) do
      state = put_record(state, record)

      with {:ok, manager_state} <- manager_state(state),
           {:ok, binding} <- active_binding(manager_state),
           :ok <- match_binding(binding, state.blocker.binding),
           :ok <- match_target(record.target, binding),
           :ok <- match_target(record.target, manager_state.identity) do
        replay_record(state, record)
      else
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error, :checkpoint_hydration_transition_conflict, state}
    end
  end

  defp recover_record(%{blocker: nil} = state, record) do
    with {:ok, manager_state} <- manager_state(state),
         {:ok, binding} <- active_binding(manager_state),
         token = make_ref(),
         :ok <- manager_begin(state, token, binding) do
      state = %{state | blocker: %{token: token, binding: binding, record: record}}

      with :ok <- match_target(record.target, binding),
           :ok <- match_target(record.target, manager_state.identity) do
        replay_record(state, record)
      else
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp recover_record(state, _record),
    do: {:error, :checkpoint_hydration_transition_conflict, state}

  defp replay_record(state, record) do
    with {:ok, adapter} <-
           RuntimeRegistry.fetch(
             state.registry,
             record.hydration.kind,
             record.hydration.schema_version
           ),
         :ok <- validate_hydration_integrity(state, record.hydration, record.target),
         {:ok, runtime} <- decode_runtime(state, adapter, record.hydration, record.target),
         {:ok, state} <- replay_phase(state) do
      complete_transition(state, runtime)
    else
      {:error, reason, %{} = state} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp prepare_transition(state, _runtime) do
    with :ok <- boundary(state, :before_prepared),
         :ok <- authorize_fresh_effect(state),
         :ok <- revalidate_binding(state),
         {:ok, expected_head} <- observe_target_head(state) do
      record = %{state.blocker.record | expected_head: expected_head}
      state = put_record(state, record)

      with :ok <- journal_write(state, record),
           :ok <- boundary(state, :after_prepared) do
        prepare_head_transition(state)
      else
        {:error, reason} -> {:error, reason, recover_written_record(state)}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp prepare_head_transition(state) do
    with :ok <- boundary(state, :before_head),
         :ok <- authorize_fresh_effect(state),
         :ok <- revalidate_binding(state),
         {:ok, selected_head} <- hydrate_head(state) do
      state = %{state | selected_head: selected_head}

      with :ok <- boundary(state, :after_head),
           :ok <- boundary(state, :before_head_committed) do
        commit_head_transition(state)
      else
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp commit_head_transition(state) do
    committed = %{state.blocker.record | phase: :head_committed}
    state = put_record(state, committed)

    with :ok <- journal_write(state, committed),
         :ok <- boundary(state, :after_head_committed) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason, recover_written_record(state)}
    end
  end

  defp replay_phase(%{blocker: %{record: %{phase: :prepared}}} = state),
    do: prepare_head_transition(state)

  defp replay_phase(%{blocker: %{record: %{phase: :head_committed}}} = state) do
    case state.store_module.head(state.head_store, state.blocker.record.hydration.kind) do
      {:ok, selected_head} -> {:ok, %{state | selected_head: selected_head}}
      :empty -> {:error, :checkpoint_hydration_head_missing, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp complete_transition(state, delivered_runtime) do
    evidence = state.blocker.record

    with {:ok, runtime} <- selected_runtime(state, delivered_runtime),
         :ok <- boundary(state, :before_restore),
         :ok <- authorize_fresh_effect(state),
         :ok <- revalidate_binding(state),
         :ok <- restore_runtime(state, runtime),
         :ok <- boundary(state, :after_restore),
         :ok <- ensure_selected_head_current(state),
         :ok <- boundary(state, :before_remove),
         :ok <- authorize_fresh_effect(state),
         :ok <- revalidate_binding(state),
         :ok <- journal_remove(state),
         :ok <- boundary(state, :after_remove),
         :ok <- authorize_fresh_effect(state),
         :ok <- ensure_selected_head_current(state),
         :ok <- boundary(state, :before_finish),
         :ok <- authorize_fresh_effect(state),
         :ok <- revalidate_binding(state),
         :ok <- manager_finish(state) do
      {:ok,
       %{
         state
         | blocker: nil,
           selected_head: nil,
           fresh_request?: false,
           recovery_required?: false,
           recovery_error: nil
       }}
    else
      {:error, reason} ->
        state =
          state
          |> retain_recovery_evidence(evidence)
          |> maybe_retry_manager(reason)

        {:error, reason, state}
    end
  end

  defp recover_written_record(state) do
    case journal_read(state) do
      {:ok, record} -> reconcile_written_record(state, record)
      _empty_or_error -> state
    end
  end

  defp reconcile_written_record(state, record) do
    current = state.blocker.record

    if same_transition?(current, record) do
      put_record(state, record)
    else
      state
    end
  end

  defp same_transition?(left, right),
    do: Map.delete(left, :phase) == Map.delete(right, :phase)

  defp retain_recovery_evidence(state, record) do
    case journal_read(state) do
      {:ok, ^record} ->
        state

      _empty_or_error ->
        prepared = %{record | phase: :prepared}

        case journal_write(state, prepared) do
          :ok ->
            case journal_write(state, record) do
              :ok -> state
              {:error, _reason} -> state
            end

          {:error, _reason} ->
            state
        end
    end
  end

  defp current_session_authorization(state, session_generation) do
    callback = fn session ->
      {:checkpoint_hydration_authorization,
       %{
         session_generation: session.generation,
         session_id: session.session_id,
         credential_epoch: session.credential_epoch
       }}
    end

    case state.session_holder_module.with_session(
           state.session_holder,
           session_generation,
           callback
         ) do
      {:ok, {:checkpoint_hydration_authorization, authorization}} when is_map(authorization) ->
        {:ok, authorization}

      {:error, reason} when reason in [:no_session, :stale_session, :session_holder_unavailable] ->
        {:error, :stale_session}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_session_authorization}
    end
  end

  defp authorize_fresh_effect(%{fresh_request?: false}), do: :ok

  defp authorize_fresh_effect(%{fresh_request?: true, blocker: %{record: record}} = state),
    do: authorize_fresh_effect(state, record)

  defp authorize_fresh_effect(_state), do: {:error, :invalid_session_authorization}

  defp revalidate_authorization(state, authorization) do
    record = %{
      session_generation: authorization.session_generation,
      session_incarnation: authorization.session_id,
      target: %{credential_epoch: authorization.credential_epoch}
    }

    authorize_fresh_effect(state, record)
  end

  defp authorize_fresh_effect(state, record) do
    if fresh_transition?(record) do
      with {:ok, authorization} <-
             current_session_authorization(state, record.session_generation),
           :ok <- match_authorization(authorization, record) do
        :ok
      end
    else
      :ok
    end
  end

  defp fresh_transition?(record),
    do: not is_nil(record.session_generation) and not is_nil(record.session_incarnation)

  defp match_authorization(authorization, record) do
    if authorization.session_generation == record.session_generation and
         authorization.session_id == record.session_incarnation and
         authorization.credential_epoch == record.target.credential_epoch do
      :ok
    else
      {:error, :stale_session}
    end
  end

  defp monitor_manager(state) do
    case manager_pid(state) do
      pid when is_pid(pid) and pid == state.manager_pid and is_reference(state.manager_monitor_ref) ->
        state

      pid when is_pid(pid) ->
        state = clear_manager_monitor(state)
        %{state | manager_pid: pid, manager_monitor_ref: Process.monitor(pid)}

      _other ->
        state
    end
  end

  defp manager_pid(state) do
    manager_pid =
      if function_exported?(state.manager_module, :whereis, 1) do
        state.manager_module.whereis(state.manager)
      else
        GenServer.whereis(state.manager)
      end

    case manager_pid do
      pid when is_pid(pid) -> pid
      {_name, _node} = remote -> remote
      _other -> nil
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp clear_manager_monitor(%{manager_monitor_ref: nil} = state), do: state

  defp clear_manager_monitor(%{manager_monitor_ref: monitor_ref} = state) do
    Process.demonitor(monitor_ref, [:flush])
    %{state | manager_monitor_ref: nil, manager_pid: nil}
  end

  defp maybe_retry_manager(state, reason) do
    if retryable_manager_error?(state, reason),
      do: schedule_manager_retry(state),
      else: state
  end

  # A Manager-side binding mismatch before any blocker exists is a startup race:
  # activation advanced between the Coordinator's binding read and the Manager's
  # authoritative re-read. Reconciliation re-reads the current binding on retry,
  # so only the pre-blocker empty-journal path treats it as transient. Mismatches
  # against retained durable records stay terminal.
  defp retryable_manager_error?(_state, reason) when reason in @manager_retry_errors, do: true

  defp retryable_manager_error?(
         %{blocker: nil, reconcile_empty_journal?: true},
         :checkpoint_hydration_binding_mismatch
       ),
       do: true

  defp retryable_manager_error?(_state, _reason), do: false

  defp schedule_manager_retry(%{blocker: nil, recovery_required?: false} = state), do: state

  defp schedule_manager_retry(%{manager_retry_ref: nil} = state) do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:retry_manager_recovery, token}, state.manager_retry_ms)
    %{state | manager_retry_ref: timer_ref, manager_retry_token: token}
  end

  defp schedule_manager_retry(state), do: state

  defp cancel_manager_retry(%{manager_retry_ref: nil} = state), do: state

  defp cancel_manager_retry(state) do
    Process.cancel_timer(state.manager_retry_ref)
    %{state | manager_retry_ref: nil, manager_retry_token: nil}
  end

  defp current_binding(state) do
    with {:ok, manager_state} <- manager_state(state),
         {:ok, binding} <- active_binding(manager_state),
         :ok <- match_target(binding, manager_state.identity) do
      {:ok, binding}
    end
  end

  defp revalidate_binding(%{blocker: %{binding: binding, record: record}} = state) do
    with {:ok, manager_state} <- manager_state(state),
         {:ok, active_binding} <- active_binding(manager_state),
         :ok <- match_binding(active_binding, binding),
         :ok <- match_binding(record.target, binding),
         :ok <- match_target(binding, manager_state.identity) do
      :ok
    end
  end

  defp revalidate_binding(_state), do: {:error, :checkpoint_hydration_binding_unavailable}

  defp manager_state(state) do
    case state.manager_module.status(state.manager) do
      %{active: active, identity: identity} when is_map(active) and is_map(identity) ->
        {:ok, %{active: active, identity: identity}}

      %{active: {:error, _reason}} ->
        {:error, :checkpoint_hydration_binding_failed}

      _other ->
        {:error, :checkpoint_hydration_binding_unavailable}
    end
  rescue
    _exception -> {:error, :checkpoint_hydration_manager_unavailable}
  catch
    :exit, _reason -> {:error, :checkpoint_hydration_manager_unavailable}
    _kind, _reason -> {:error, :checkpoint_hydration_manager_unavailable}
  end

  defp active_binding(%{active: active}) when is_map(active) do
    {:ok,
     Map.take(active, [
       :device_id,
       :credential_epoch,
       :storage_epoch,
       :generation,
       :manifest_hash
     ])}
  end

  defp match_binding(left, right) do
    if left == right,
      do: :ok,
      else: {:error, :checkpoint_hydration_binding_mismatch}
  end

  defp match_target(left, right) do
    if Map.take(left, [:device_id, :credential_epoch, :storage_epoch]) ==
         Map.take(right, [:device_id, :credential_epoch, :storage_epoch]) do
      :ok
    else
      {:error, :checkpoint_hydration_target_mismatch}
    end
  end

  defp match_session(authorization, binding) do
    if authorization.credential_epoch == binding.credential_epoch,
      do: :ok,
      else: {:error, :stale_session}
  end

  defp validate_hydration_integrity(state, hydration, target \\ nil) do
    target =
      target || Map.take(hydration, [:device_id, :credential_epoch, :storage_epoch])

    with {:ok, content_hash} <-
           state.checkpoint_module.content_hash(
             hydration.kind,
             hydration.schema_version,
             hydration.content
           ),
         true <- secure_equal(content_hash, hydration.content_hash),
         :ok <-
           state.checkpoint_module.validate_authority(
             hydration.kind,
             hydration.schema_version,
             hydration.content,
             %{
               device_id: target.device_id,
               credential_epoch: hydration.origin_credential_epoch,
               storage_epoch: hydration.origin_storage_epoch
             }
           ),
         {:ok, checkpoint_hash} <-
           state.checkpoint_module.hash(%{
             device_id: target.device_id,
             credential_epoch: hydration.origin_credential_epoch,
             storage_epoch: hydration.origin_storage_epoch,
             sequence: sequence(hydration),
             kind: hydration.kind,
             schema_version: hydration.schema_version,
             source_generation: hydration.source_generation,
             parent_hash: hydration.parent_hash,
             content_hash: hydration.content_hash
           }),
         true <- secure_equal(checkpoint_hash, hydration.checkpoint_hash) do
      :ok
    else
      false -> {:error, :checkpoint_hydration_hash_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_runtime(state, adapter, hydration, target) do
    with {:ok, wire} <-
           state.checkpoint_module.decode_canonical_content(
             hydration.kind,
             hydration.schema_version,
             hydration.content
           ),
         {:ok, runtime} <- invoke_adapter(adapter, wire),
         {:ok, runtime} <-
           rebind_runtime_authority(
             adapter,
             hydration.kind,
             hydration.schema_version,
             runtime,
             target
           ) do
      {:ok, runtime}
    end
  end

  defp invoke_adapter(adapter, wire) do
    adapter.hydrate(wire)
  rescue
    _exception -> {:error, :invalid_checkpoint_runtime}
  catch
    _kind, _reason -> {:error, :invalid_checkpoint_runtime}
  end

  defp rebind_runtime_authority(adapter, :wind_shift, 2, runtime, target) do
    case adapter.rebind_authority(runtime, target_authority(target)) do
      {:ok, rebound} -> {:ok, rebound}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :checkpoint_runtime_authority_rebind_failed}
    end
  rescue
    _exception -> {:error, :checkpoint_runtime_authority_rebind_failed}
  catch
    _kind, _reason -> {:error, :checkpoint_runtime_authority_rebind_failed}
  end

  defp rebind_runtime_authority(_adapter, _kind, _schema_version, runtime, _target),
    do: {:ok, runtime}

  defp target_authority(target),
    do: Map.take(target, [:device_id, :credential_epoch, :storage_epoch])

  defp selected_runtime(%{selected_head: nil}, delivered_runtime), do: {:ok, delivered_runtime}

  defp selected_runtime(%{selected_head: selected_head} = state, _delivered_runtime) do
    with :ok <- state.record_module.verify(selected_head),
         :ok <- match_selected_head(state, selected_head),
         {:ok, adapter} <-
           RuntimeRegistry.fetch(state.registry, selected_head.kind, selected_head.schema_version) do
      decode_runtime(state, adapter, selected_head, state.blocker.record.target)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_selected_head_current(%{selected_head: selected_head} = state)
       when not is_nil(selected_head) do
    case state.store_module.head(state.head_store, selected_head.kind) do
      {:ok, current_head} ->
        if same_selected_head?(selected_head, current_head),
          do: :ok,
          else: {:error, :checkpoint_hydration_head_changed}

      :empty ->
        {:error, :checkpoint_hydration_head_changed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_selected_head_current(_state), do: {:error, :checkpoint_hydration_head_missing}

  defp same_selected_head?(left, right) do
    left.checkpoint_hash == right.checkpoint_hash and
      left.binding_hash == right.binding_hash and
      left.accepted == right.accepted
  end

  defp match_selected_head(state, selected_head) do
    record = state.blocker.record

    if selected_head.kind == record.hydration.kind and
         selected_head.device_id == record.target.device_id and
         selected_head.local_credential_epoch == record.target.credential_epoch and
         selected_head.local_storage_epoch == record.target.storage_epoch do
      :ok
    else
      {:error, :checkpoint_hydration_selected_head_mismatch}
    end
  end

  defp restore_runtime(state, runtime) do
    with {:ok, {module, function}} <- Map.fetch(state.restorers, state.blocker.record.hydration.kind) do
      restore_with(module, function, runtime)
    else
      :error -> {:error, :unknown_checkpoint_runtime_restorer}
    end
  end

  defp restore_with(module, function, runtime) do
    case apply(module, function, [runtime]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_checkpoint_runtime_restore}
    end
  rescue
    _exception -> {:error, :checkpoint_runtime_restore_failed}
  catch
    _kind, _reason -> {:error, :checkpoint_runtime_restore_failed}
  end

  defp observe_target_head(state),
    do: state.store_module.observe_target_head(state.head_store, state.blocker.record.hydration.kind)

  defp hydrate_head(state) do
    record = state.blocker.record
    state.store_module.hydrate(state.head_store, store_attrs(record), record.expected_head)
  end

  defp store_attrs(record) do
    hydration = record.hydration

    %{
      device_id: record.target.device_id,
      credential_epoch: record.target.credential_epoch,
      storage_epoch: record.target.storage_epoch,
      origin_credential_epoch: hydration.origin_credential_epoch,
      origin_storage_epoch: hydration.origin_storage_epoch,
      kind: hydration.kind,
      schema_version: hydration.schema_version,
      sequence: hydration.revision,
      source_generation: hydration.source_generation,
      parent_hash: hydration.parent_hash,
      content: hydration.content,
      checkpoint_hash: hydration.checkpoint_hash
    }
  end

  defp manager_begin(state, token, binding) do
    state.manager_module.begin_checkpoint_hydration(state.manager, token, binding)
  rescue
    _exception -> {:error, :checkpoint_hydration_manager_unavailable}
  catch
    :exit, _reason -> {:error, :checkpoint_hydration_manager_unavailable}
    _kind, _reason -> {:error, :checkpoint_hydration_manager_unavailable}
  end

  defp manager_finish(state) do
    state.manager_module.finish_checkpoint_hydration(
      state.manager,
      state.blocker.token,
      state.blocker.binding
    )
  rescue
    _exception -> {:error, :checkpoint_hydration_manager_unavailable}
  catch
    :exit, _reason -> {:error, :checkpoint_hydration_manager_unavailable}
    _kind, _reason -> {:error, :checkpoint_hydration_manager_unavailable}
  end

  defp journal_read(state),
    do: state.journal_module.read(state.journal_path, state.journal_opts)

  defp journal_write(state, record),
    do: state.journal_module.write(state.journal_path, record, state.journal_opts)

  defp journal_remove(state),
    do: state.journal_module.remove(state.journal_path, state.journal_opts)

  defp boundary(state, stage) do
    case state.boundary.(stage) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_checkpoint_hydration_boundary}
    end
  end

  defp blocker(token, binding, authorization, transaction_id, hydration) do
    %{
      token: token,
      binding: binding,
      record: %{
        version: 2,
        phase: :prepared,
        transaction_id: transaction_id,
        session_incarnation: authorization.session_id,
        session_generation: authorization.session_generation,
        target:
          Map.take(binding, [
            :device_id,
            :credential_epoch,
            :storage_epoch,
            :generation,
            :manifest_hash
          ]),
        expected_head: nil,
        hydration: %{
          kind: hydration.kind,
          schema_version: hydration.schema_version,
          origin_credential_epoch: hydration.origin_credential_epoch,
          origin_storage_epoch: hydration.origin_storage_epoch,
          revision: hydration.sequence,
          source_generation: hydration.source_generation,
          parent_hash: hydration.parent_hash,
          content_hash: hydration.content_hash,
          checkpoint_hash: hydration.checkpoint_hash,
          content: hydration.content
        }
      }
    }
  end

  defp put_record(state, record), do: put_in(state.blocker.record, record)

  defp safe_status(%{blocker: blocker, recovery_error: recovery_error} = state) do
    phase = if is_map(blocker) and is_map(blocker.record), do: blocker.record.phase, else: nil
    recovery_required? = Map.get(state, :recovery_required?, false) == true

    %{
      blocked?: recovery_required? or not is_nil(blocker),
      phase: phase,
      recovery_error: public_recovery_error(recovery_required?, recovery_error)
    }
  end

  defp safe_status(_state) do
    %{
      blocked?: true,
      phase: nil,
      recovery_error: :checkpoint_hydration_failed
    }
  end

  defp public_recovery_error(%{recovery_required?: recovery_required?}, reason),
    do: public_recovery_error(recovery_required?, reason)

  defp public_recovery_error(true, _reason), do: :checkpoint_hydration_recovery_required
  defp public_recovery_error(false, reason), do: safe_recovery_error(reason)

  defp safe_recovery_error(nil), do: nil
  defp safe_recovery_error(reason) when is_atom(reason), do: reason
  defp safe_recovery_error(_reason), do: :checkpoint_hydration_failed

  defp sequence(%{sequence: sequence}), do: sequence
  defp sequence(%{revision: revision}), do: revision

  defp secure_equal(left, right) when is_binary(left) and is_binary(right),
    do: byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)

  defp secure_equal(_left, _right), do: false

  defp transaction_id(state), do: transaction_id(state.transaction_id, 8)

  defp transaction_id(_generator, 0), do: {:error, :checkpoint_hydration_transaction_id_unavailable}

  defp transaction_id(generator, attempts) do
    case generator.() do
      <<transaction_id::binary-size(16)>> when transaction_id != @zero_identifier ->
        {:ok, transaction_id}

      _invalid ->
        transaction_id(generator, attempts - 1)
    end
  rescue
    _exception -> {:error, :checkpoint_hydration_transaction_id_unavailable}
  catch
    _kind, _reason -> {:error, :checkpoint_hydration_transaction_id_unavailable}
  end

  defp validate_hydration_shape(hydration) when is_map(hydration) do
    if Enum.sort(Map.keys(hydration)) == Enum.sort(@hydrate_keys),
      do: {:ok, hydration},
      else: {:error, :invalid_checkpoint_hydration}
  end

  defp validate_hydration_shape(_hydration), do: {:error, :invalid_checkpoint_hydration}
end
