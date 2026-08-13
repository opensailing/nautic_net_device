defmodule RacingOrg.Tracker.Pro.DesiredState.Manager do
  @moduledoc """
  Coordinates authenticated Desired State delivery and atomic generation activation.

  Every network-triggered call captures a secret-free `SessionHolder`
  authorization. Long staging and owner work runs outside the holder; durable
  authority transitions revalidate the exact session generation, session ID,
  credential epoch, and runtime identity. The logical racing.org device
  identity is injected separately from the operational session key identity.
  """

  use GenServer

  alias RacingOrg.Tracker.Pro.DesiredState.{OperationalGate, OwnerResolver, Store}
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Manifest
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Pro.WiFiManager.Secret

  @identity_keys [:device_id, :credential_epoch, :boot_id, :storage_epoch]
  @durable_identity_keys [:device_id, :credential_epoch, :storage_epoch]
  @pointer_keys [:device_id, :credential_epoch, :storage_epoch, :generation, :manifest_hash]
  @non_network_sections Enum.reject(Contract.sections(), &(&1 == :wifi))
  @owner_sections MapSet.new(Contract.sections())
  @default_owner_retry_base_ms 25
  @default_owner_retry_max_ms 5_000
  @default_owner_resolution_timeout_ms 100
  @default_identity_refresh_ms 250
  @default_lease_heartbeat_ms 1_000
  @default_lease_timeout_ms 5_000
  @zero_identifier <<0::128>>

  @type pointer :: %{
          required(:device_id) => binary(),
          required(:storage_epoch) => binary(),
          required(:credential_epoch) => non_neg_integer(),
          required(:generation) => pos_integer(),
          required(:manifest_hash) => binary()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @spec deliver_manifest(GenServer.server(), SessionHolder.generation(), map()) ::
          {:ok, :staged | :unchanged} | {:error, term()}
  def deliver_manifest(server \\ __MODULE__, session_generation, delivery) do
    GenServer.call(server, {:deliver_manifest, session_generation, delivery}, :infinity)
  end

  @spec deliver_chunk(GenServer.server(), SessionHolder.generation(), map()) ::
          {:ok, :stored | :unchanged} | {:error, term()}
  def deliver_chunk(server \\ __MODULE__, session_generation, payload) do
    GenServer.call(server, {:deliver_chunk, session_generation, payload}, :infinity)
  end

  @doc "Accept a transient secret without putting its plaintext in a Manager message."
  @spec deliver_secret(GenServer.server(), SessionHolder.generation(), map()) ::
          {:ok, :accepted} | {:error, term()}
  def deliver_secret(server \\ __MODULE__, session_generation, delivery)

  def deliver_secret(server, session_generation, delivery) when is_map(delivery) do
    case Map.pop(delivery, :secret) do
      {secret, metadata} when is_binary(secret) ->
        wrapped = Secret.new(secret)

        try do
          GenServer.call(server, {:deliver_secret, session_generation, metadata, wrapped}, :infinity)
        catch
          :exit, _reason -> {:error, :desired_state_manager_unavailable}
        end

      _other ->
        {:error, :secret_reference_mismatch}
    end
  end

  def deliver_secret(_server, _session_generation, _delivery),
    do: {:error, :secret_reference_mismatch}

  @spec replay(GenServer.server(), SessionHolder.generation()) ::
          :ok | {:error, :stale_session}
  def replay(server \\ __MODULE__, session_generation) do
    GenServer.call(server, {:replay, session_generation}, :infinity)
  end

  @doc "Close operational output while the calling coordinator hydrates one exact active binding."
  @spec begin_checkpoint_hydration(GenServer.server(), reference(), pointer()) ::
          :ok | {:error, term()}
  def begin_checkpoint_hydration(server \\ __MODULE__, token, binding) do
    GenServer.call(server, {:begin_checkpoint_hydration, token, binding}, :infinity)
  end

  @doc "Release a checkpoint blocker only for its exact coordinator, token, and current binding."
  @spec finish_checkpoint_hydration(GenServer.server(), reference(), pointer()) ::
          :ok | {:error, term()}
  def finish_checkpoint_hydration(server \\ __MODULE__, token, binding) do
    GenServer.call(server, {:finish_checkpoint_hydration, token, binding}, :infinity)
  end

  @impl true
  def init(opts) do
    identity_source = Keyword.fetch!(opts, :identity)

    owner_retry_base_ms =
      opts
      |> Keyword.get(:owner_retry_base_ms, @default_owner_retry_base_ms)
      |> positive_milliseconds(@default_owner_retry_base_ms)

    owner_retry_max_ms =
      opts
      |> Keyword.get(:owner_retry_max_ms, @default_owner_retry_max_ms)
      |> positive_milliseconds(@default_owner_retry_max_ms)
      |> max(owner_retry_base_ms)

    owner_resolution_timeout_ms =
      opts
      |> Keyword.get(
        :owner_resolution_timeout_ms,
        @default_owner_resolution_timeout_ms
      )
      |> positive_milliseconds(@default_owner_resolution_timeout_ms)

    applier =
      opts
      |> Keyword.fetch!(:applier)
      |> Map.put(:owner_resolution_timeout_ms, owner_resolution_timeout_ms)

    lease_heartbeat_ms =
      opts
      |> Keyword.get(:lease_heartbeat_ms, @default_lease_heartbeat_ms)
      |> positive_milliseconds(@default_lease_heartbeat_ms)

    lease_timeout_ms =
      opts
      |> Keyword.get(:lease_timeout_ms, @default_lease_timeout_ms)
      |> positive_milliseconds(@default_lease_timeout_ms)
      |> max(lease_heartbeat_ms * 2)

    state = %{
      store: Keyword.fetch!(opts, :store),
      gate: Keyword.fetch!(opts, :gate),
      controller_capability: Keyword.fetch!(opts, :controller_capability),
      session_holder: Keyword.fetch!(opts, :session_holder),
      identity_source: identity_source,
      identity: nil,
      identity_refresh_ms:
        opts
        |> Keyword.get(:identity_refresh_ms, @default_identity_refresh_ms)
        |> positive_milliseconds(@default_identity_refresh_ms),
      identity_refresh_ref: nil,
      identity_refresh_token: nil,
      compatibility: Keyword.fetch!(opts, :compatibility),
      applier: applier,
      ack_sink: Keyword.fetch!(opts, :ack_sink),
      owner_resolution_timeout_ms: owner_resolution_timeout_ms,
      gate_pid: nil,
      gate_monitor_ref: nil,
      lease_sentinel_pid: nil,
      lease_sentinel_monitor_ref: nil,
      lease_sentinel_token: nil,
      lease_heartbeat_ms: lease_heartbeat_ms,
      lease_timeout_ms: lease_timeout_ms,
      lease_heartbeat_ref: nil,
      leased_owner_pid_map: nil,
      leased_authority_bindings: nil,
      owner_monitors: %{},
      owner_retry_base_ms: owner_retry_base_ms,
      owner_retry_max_ms: owner_retry_max_ms,
      owner_retry_attempt: 0,
      owner_retry_delay_ms: nil,
      owner_retry_ref: nil,
      owner_retry_token: nil,
      recovery_error: nil,
      recovery_quiescent?: false,
      checkpoint_hydration: checkpoint_hydration_startup_barrier(opts),
      checkpoint_hydration_monitor_ref: nil
    }

    case register_applier_manager(applier) do
      :ok -> {:ok, state |> monitor_gate() |> refresh_identity()}
      {:error, reason} -> {:stop, {:applier_registration_failed, reason}}
    end
  end

  @impl true
  def format_status(status), do: Secret.redact(status)

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       active: active_pointer_status(state.store),
       gate: gate_status(state),
       identity: state.identity,
       recovery_error: state.recovery_error,
       checkpoint_hydration: checkpoint_hydration_status(state)
     }, state}
  end

  def handle_call({:begin_checkpoint_hydration, token, binding}, {coordinator_pid, _tag}, state) do
    {reply, state} = begin_checkpoint_hydration_fenced(state, coordinator_pid, token, binding)
    {:reply, reply, state}
  end

  def handle_call({:finish_checkpoint_hydration, token, binding}, {coordinator_pid, _tag}, state) do
    {reply, state} = finish_checkpoint_hydration_fenced(state, coordinator_pid, token, binding)
    {:reply, reply, state}
  end

  def handle_call({:deliver_manifest, session_generation, delivery}, _from, state) do
    handle_fenced_call(state, session_generation, delivery, fn authorization ->
      deliver_manifest_fenced(state, delivery, authorization)
    end)
  end

  def handle_call({:deliver_chunk, session_generation, payload}, _from, state) do
    handle_fenced_call(state, session_generation, payload, fn authorization ->
      deliver_chunk_fenced(state, payload, authorization)
    end)
  end

  def handle_call(
        {:deliver_secret, session_generation, metadata, %Secret{} = secret},
        _from,
        state
      ) do
    handle_fenced_call(state, session_generation, metadata, fn authorization ->
      deliver_secret_fenced(state, metadata, secret, authorization)
    end)
  end

  def handle_call({:replay, _session_generation}, _from, %{identity: nil} = state) do
    {:reply, {:error, :identity_unavailable}, state}
  end

  def handle_call({:replay, session_generation}, _from, state) do
    case with_current_session(state, session_generation, fn _authorization ->
           replay_current_acks(state)
           {:ok, :none}
         end) do
      {:ok, {:ok, action}} ->
        {:reply, :ok, apply_runtime_action(state, action)}

      {:ok, {{:error, reason}, action}} ->
        {:reply, {:error, reason}, apply_runtime_action(state, action)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(
        {:refresh_identity, token},
        %{identity_refresh_token: token} = state
      ) do
    state = %{state | identity_refresh_ref: nil, identity_refresh_token: nil}
    {:noreply, refresh_identity(state)}
  end

  def handle_info({:refresh_identity, _token}, state), do: {:noreply, state}

  def handle_info(
        {:lease_heartbeat, token},
        %{
          lease_sentinel_token: token,
          lease_sentinel_pid: sentinel_pid,
          leased_owner_pid_map: owner_pid_map,
          leased_authority_bindings: authority_bindings
        } = state
      )
      when is_pid(sentinel_pid) and is_map(owner_pid_map) and is_map(authority_bindings) do
    state = %{state | lease_heartbeat_ref: nil}

    case verify_gate_set(state) do
      :ok ->
        case verify_leased_owner_authority(state.applier, owner_pid_map, authority_bindings) do
          :ok ->
            case gate_status(state) do
              {:open, _binding} ->
                if Process.alive?(sentinel_pid) do
                  send(sentinel_pid, {:lease_heartbeat, self(), token})
                  {:noreply, schedule_lease_heartbeat(state)}
                else
                  {:noreply, state}
                end

              :closed ->
                state =
                  state
                  |> revoke_lease_sentinel()
                  |> close_runtime()
                  |> schedule_owner_reconcile(:gate_lease_revoked)

                {:noreply, state}
            end

          {:error, reason} ->
            state =
              state
              |> revoke_lease_sentinel()
              |> close_runtime()
              |> schedule_owner_reconcile({:owner_resolution_failed, reason})

            {:noreply, state}
        end

      {:error, reason} ->
        state =
          state
          |> revoke_lease_sentinel()
          |> close_runtime()
          |> schedule_owner_reconcile({:gate_resolution_failed, reason})

        {:noreply, state}
    end
  end

  def handle_info({:lease_heartbeat, _stale_token}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor_ref, :process, coordinator_pid, _reason},
        %{
          checkpoint_hydration_monitor_ref: monitor_ref,
          checkpoint_hydration: %{coordinator_pid: coordinator_pid} = hydration
        } = state
      ) do
    state =
      state
      |> Map.put(:checkpoint_hydration_monitor_ref, nil)
      |> Map.put(:checkpoint_hydration, %{hydration | state: :blocked, coordinator_available?: false})
      |> close_runtime_quiescent()

    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, gate_pid, _reason},
        %{gate_monitor_ref: monitor_ref, gate_pid: gate_pid} = state
      ) do
    state =
      state
      |> Map.put(:gate_pid, nil)
      |> Map.put(:gate_monitor_ref, nil)
      |> revoke_lease_sentinel()
      |> clear_owner_monitors()
      |> schedule_owner_reconcile()

    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, sentinel_pid, _reason},
        %{
          lease_sentinel_monitor_ref: monitor_ref,
          lease_sentinel_pid: sentinel_pid
        } = state
      ) do
    state =
      state
      |> clear_lease_sentinel()
      |> close_runtime()
      |> schedule_owner_reconcile(:lease_sentinel_unavailable)

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _owner_pid, _reason}, state) do
    if Map.has_key?(state.owner_monitors, monitor_ref) do
      state =
        state
        |> close_runtime()
        |> schedule_owner_reconcile()

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:reconcile_authoritative_owners, token},
        %{owner_retry_token: token, identity: nil} = state
      ) do
    state = state |> consume_owner_retry() |> monitor_gate() |> close_runtime_quiescent()
    {:noreply, state}
  end

  def handle_info(
        {:reconcile_authoritative_owners, token},
        %{owner_retry_token: token} = state
      ) do
    state = state |> consume_owner_retry() |> monitor_gate()

    state =
      if gate_available?(state) do
        state
        |> recover_interrupted_activation()
        |> reconcile_active_runtime()
      else
        schedule_owner_reconcile(state, :gate_unavailable)
      end

    {:noreply, state}
  end

  def handle_info({:reconcile_authoritative_owners, _stale_token}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp handle_fenced_call(%{identity: nil} = state, _session_generation, _payload, _fun) do
    {:reply, {:error, :identity_unavailable}, state}
  end

  defp handle_fenced_call(state, session_generation, payload, fun) do
    case validate_identity(payload, state.identity) do
      :ok ->
        case with_current_session(state, session_generation, fun) do
          {:ok, {reply, action}} ->
            {:reply, reply, apply_runtime_action(state, action)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp with_current_session(state, session_generation, fun) when is_function(fun, 1) do
    with {:ok, authorization} <- authorize_current_session(state, session_generation),
         {:ok, result} <- invoke_authorized_callback(fun, authorization) do
      {:ok, result}
    end
  end

  defp authorize_current_session(state, session_generation) do
    callback = fn session ->
      if session.credential_epoch == state.identity.credential_epoch do
        {:ok,
         %{
           session_generation: session.generation,
           session_id: session.session_id,
           credential_epoch: session.credential_epoch,
           runtime_identity: state.identity
         }}
      else
        {:error, :credential_epoch_mismatch}
      end
    end

    case with_session_in_manager(state.session_holder, session_generation, callback) do
      {:ok, {:ok, authorization}} ->
        {:ok, authorization}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} when reason in [:no_session, :stale_session, :session_holder_unavailable] ->
        {:error, :stale_session}

      {:error, :session_callback_failed} ->
        {:error, :internal_failure}
    end
  end

  defp invoke_authorized_callback(fun, authorization) do
    {:ok, fun.(authorization)}
  rescue
    _exception -> {:error, :internal_failure}
  catch
    _kind, _reason -> {:error, :internal_failure}
  end

  defp with_authorized_session_transition(state, authorization, fun)
       when is_map(authorization) and is_function(fun, 0) do
    callback = fn session ->
      with :ok <- validate_session_authorization(session, authorization, state.identity) do
        fun.()
      end
    end

    case with_session_in_manager(
           state.session_holder,
           authorization.session_generation,
           callback
         ) do
      {:ok, result} ->
        result

      {:error, reason} when reason in [:no_session, :stale_session, :session_holder_unavailable] ->
        {:error, :stale_session}

      {:error, :session_callback_failed} ->
        {:error, :internal_failure}
    end
  end

  defp validate_session_authorization(session, authorization, current_identity) do
    if session.generation == authorization.session_generation and
         session.session_id == authorization.session_id and
         session.credential_epoch == authorization.credential_epoch and
         current_identity == authorization.runtime_identity do
      :ok
    else
      {:error, :stale_session}
    end
  end

  defp with_session_in_manager(session_holder, session_generation, fun)
       when is_function(fun, 1) do
    # The Manager performs the durable mutation itself, so it must also own the
    # SessionHolder lease. If the bounded lease expires, SessionHolder kills this
    # exact effect executor and waits for its DOWN before applying replacement.
    # Holder death or a restart gap is an unavailable authorization boundary, not
    # permission for the exit from GenServer.call/3 to take down the Manager.
    SessionHolder.with_session(session_holder, session_generation, fun)
  catch
    :exit, _reason -> {:error, :session_holder_unavailable}
  end

  defp deliver_manifest_fenced(state, delivery, authorization) do
    with {:ok, manifest} <- decode_manifest(delivery),
         :ok <- validate_manifest_identity(delivery, manifest),
         :ok <- validate_generation_transition(state.store, manifest),
         :ok <- validate_compatibility(manifest, state.compatibility) do
      case with_authorized_session_transition(state, authorization, fn ->
             Store.stage_manifest(state.store, delivery)
           end) do
        {:ok, disposition} -> {{:ok, disposition}, :none}
        {:error, reason} -> {{:error, storage_or_protocol_error(reason)}, :none}
      end
    else
      {:error, reason} when reason in [:incompatible_firmware, :incompatible_capability] ->
        ack = rejected_ack(state.identity, delivery, :manifest, reason, false, nil)

        case persist_and_send_ack(state, ack) do
          :ok -> {{:error, reason}, :none}
          {:error, storage_reason} -> {{:error, storage_reason}, :none}
        end

      {:error, reason} ->
        {{:error, reason}, :none}
    end
  end

  defp deliver_chunk_fenced(state, payload, authorization) do
    with :ok <- validate_generation_payload(state.store, payload),
         {:ok, disposition} <-
           with_authorized_session_transition(state, authorization, fn ->
             Store.put_chunk(state.store, payload)
           end) do
      complete_generation_after_chunk(state, payload, disposition, authorization)
    else
      {:error, reason} -> {{:error, storage_or_protocol_error(reason)}, :none}
    end
  end

  defp complete_generation_after_chunk(state, payload, disposition, authorization) do
    pointer = pointer_from(payload)

    case Store.active(state.store) do
      {:ok, ^pointer} ->
        {{:ok, disposition}, :none}

      {:ok, _other} ->
        verify_and_activate_generation(state, payload, disposition, pointer, authorization)

      :empty ->
        verify_and_activate_generation(state, payload, disposition, pointer, authorization)

      {:error, reason} ->
        {{:error, storage_or_protocol_error(reason)}, :none}
    end
  end

  defp verify_and_activate_generation(state, payload, disposition, pointer, authorization) do
    case Store.verify_and_stage(state.store, payload.generation, payload.manifest_hash) do
      {:error, :transfer_incomplete, _section} ->
        {{:ok, disposition}, :none}

      {:ok, _generation_state} ->
        with {:ok, generation} <-
               Store.load_generation(state.store, payload.generation, payload.manifest_hash),
             staged = staged_ack(state.identity, generation.manifest),
             :ok <- persist_and_send_ack(state, staged) do
          if secret_required?(generation) do
            {{:ok, disposition}, :none}
          else
            action = activate_candidate(state, pointer, generation, nil, authorization)
            {{:ok, disposition}, action}
          end
        else
          {:error, reason} -> {{:error, storage_or_protocol_error(reason)}, :none}
        end

      {:error, {:read_chunk, _reason} = reason, _section} ->
        {{:error, storage_or_protocol_error(reason)}, :none}

      {:error, reason, section} ->
        reject_transfer(state, payload, reason, section)
        {{:ok, disposition}, :none}

      {:error, reason} ->
        {{:error, storage_or_protocol_error(reason)}, :none}
    end
  end

  defp deliver_secret_fenced(state, metadata, %Secret{} = secret, authorization) do
    pointer = pointer_from(metadata)

    with {:ok, generation} <-
           Store.load_generation(state.store, metadata.generation, metadata.manifest_hash),
         :ok <- validate_secret_binding(generation, metadata) do
      case Store.active(state.store) do
        {:ok, ^pointer} ->
          {{:ok, :accepted}, :none}

        {:ok, _other} ->
          {{:ok, :accepted}, activate_candidate(state, pointer, generation, secret, authorization)}

        :empty ->
          {{:ok, :accepted}, activate_candidate(state, pointer, generation, secret, authorization)}

        {:error, reason} ->
          {{:error, storage_or_protocol_error(reason)}, :none}
      end
    else
      {:error, _reason} -> {{:error, :secret_reference_mismatch}, :none}
    end
  end

  defp activate_candidate(state, pointer, generation, secret, authorization) do
    :ok = invalidate_lease_sentinel(state)

    case gate_close(state) do
      :ok ->
        with_prepared_transition(state, fn transition ->
          activate_candidate_with_closed_gate(
            state,
            pointer,
            generation,
            secret,
            transition,
            authorization
          )
        end)

      {:error, _reason} ->
        :closed
    end
  end

  defp activate_candidate_with_closed_gate(
         state,
         pointer,
         generation,
         secret,
         transition,
         authorization
       ) do
    with :ok <- require_current_transition(state, transition),
         :ok <-
           call_applier(state.applier, :validate, [
             pointer,
             Contract.sections(),
             secret,
             transition.owner_pid_map
           ]),
         :ok <- require_current_transition(state, transition) do
      case Store.prepare_activation(state.store, pointer.generation, pointer.manifest_hash) do
        {:ok, %{decision: nil}} ->
          activate_prepared_candidate(
            state,
            pointer,
            generation,
            secret,
            transition,
            authorization
          )

        {:ok, %{decision: decision}} when decision in [:candidate, :prior] ->
          :reconcile_pending

        {:error, reason} ->
          reject_unprepared_activation(state, pointer, generation, reason)
      end
    else
      {:error, {:gate_transition_changed, reason}} ->
        transition_pending_action(reason)

      {:error, {:validation_failed, section, _reason}} ->
        reject_unprepared_activation(
          state,
          pointer,
          generation,
          {:validation_failed, section}
        )

      {:error, reason} ->
        reject_unprepared_activation(state, pointer, generation, reason)
    end
  end

  defp activate_prepared_candidate(
         state,
         pointer,
         generation,
         secret,
         transition,
         authorization
       ) do
    with :ok <- require_current_transition(state, transition),
         :ok <-
           call_applier(state.applier, :apply_non_network, [
             pointer,
             @non_network_sections,
             transition.owner_pid_map
           ]),
         :ok <- require_current_transition(state, transition) do
      case commit_activation_with_authorization(state, authorization) do
        {:ok, _prior} ->
          activate_committed_candidate(
            state,
            pointer,
            generation,
            secret,
            transition,
            authorization
          )

        {:error, {:apply_failed, section, _reason}} ->
          finalize_rejected_action(
            state,
            pointer,
            generation,
            :apply,
            :section_apply_failed,
            false,
            section,
            transition
          )

        {:error, reason} ->
          {phase, code, retryable} = activation_error(reason)

          finalize_rejected_action(
            state,
            pointer,
            generation,
            phase,
            code,
            retryable,
            nil,
            transition
          )
      end
    else
      {:error, {:gate_transition_changed, reason}} ->
        transition_pending_action(reason)

      {:error, {:apply_failed, section, _reason}} ->
        finalize_rejected_action(
          state,
          pointer,
          generation,
          :apply,
          :section_apply_failed,
          false,
          section,
          transition
        )

      {:error, reason} ->
        {phase, code, retryable} = activation_error(reason)

        finalize_rejected_action(
          state,
          pointer,
          generation,
          phase,
          code,
          retryable,
          nil,
          transition
        )
    end
  end

  defp commit_activation_with_authorization(state, authorization) do
    with_authorized_session_transition(state, authorization, fn ->
      Store.commit_activation(state.store)
    end)
  end

  defp activate_committed_candidate(
         state,
         pointer,
         generation,
         secret,
         transition,
         authorization
       ) do
    with :ok <- require_current_transition(state, transition),
         :ok <-
           call_applier(state.applier, :apply_wifi, [
             pointer,
             secret,
             transition.owner_pid_map
           ]),
         :ok <- require_current_transition(state, transition) do
      finalize_candidate_action(state, pointer, generation, transition, authorization)
    else
      {:error, {:gate_transition_changed, reason}} ->
        restore_prior_after_transition_change(state, reason)

      {:error, {:apply_failed, :wifi, :wifi_authority_indeterminate}} ->
        :reconcile_pending

      {:error, :wifi_authority_indeterminate} ->
        :reconcile_pending

      {:error, {:apply_failed, :wifi, reason}}
      when reason in [
             :confirmation_timeout,
             :confirmation_unavailable,
             :wifi_reconnect_unconfirmed,
             :wifi_trial_failed
           ] ->
        finalize_rejected_action(
          state,
          pointer,
          generation,
          :wifi_trial,
          :wifi_trial_failed,
          true,
          :wifi,
          transition
        )

      {:error, reason}
      when reason in [
             :confirmation_timeout,
             :confirmation_unavailable,
             :wifi_reconnect_unconfirmed,
             :wifi_trial_failed
           ] ->
        finalize_rejected_action(
          state,
          pointer,
          generation,
          :wifi_trial,
          :wifi_trial_failed,
          true,
          :wifi,
          transition
        )

      {:error, {:apply_failed, section, _reason}} ->
        finalize_rejected_action(
          state,
          pointer,
          generation,
          :apply,
          :section_apply_failed,
          false,
          section,
          transition
        )

      {:error, reason} ->
        {phase, code, retryable} = activation_error(reason)

        finalize_rejected_action(
          state,
          pointer,
          generation,
          phase,
          code,
          retryable,
          nil,
          transition
        )
    end
  end

  defp restore_prior_after_transition_change(state, reason) do
    case Store.restore_activation_prior(state.store) do
      :ok ->
        transition_pending_action(reason)

      {:error, restore_reason} ->
        {:reconcile_pending, {:activation_authority_restore_failed, restore_reason}}
    end
  end

  defp reject_unprepared_activation(
         state,
         pointer,
         generation,
         {:validation_failed, section}
       ) do
    reject_without_journal(
      state,
      pointer,
      generation,
      :staging,
      :section_validation_failed,
      false,
      section
    )

    :reconcile_pending
  end

  defp reject_unprepared_activation(state, pointer, generation, reason) do
    {phase, code, retryable} = activation_error(reason)
    reject_without_journal(state, pointer, generation, phase, code, retryable, nil)
    :reconcile_pending
  end

  defp finalize_candidate_action(
         state,
         pointer,
         generation,
         transition,
         authorization
       ) do
    effective = effective_ack(state.identity, pointer)

    case record_and_finalize_activation(
           state,
           :candidate,
           effective,
           false,
           transition,
           {:session, authorization}
         ) do
      :ok ->
        {:open_prepared, transition}

      {:error, :stale_session} ->
        finalize_rejected_action(
          state,
          pointer,
          generation,
          :activation,
          :activation_failed,
          true,
          nil,
          transition
        )

      {:error, {:gate_transition_changed, reason}} ->
        transition_pending_action(reason)

      {:error, _reason} ->
        :reconcile_pending
    end
  end

  defp finalize_rejected_action(
         state,
         pointer,
         generation,
         phase,
         code,
         retryable,
         section,
         transition
       ) do
    section_identity = if section, do: section_identity(generation, section), else: nil
    rejected = rejected_ack(state.identity, pointer, phase, code, retryable, section_identity)

    _result =
      record_and_finalize_activation(
        state,
        :prior,
        rejected,
        true,
        transition,
        :safety
      )

    :reconcile_pending
  end

  defp reject_without_journal(state, pointer, generation, phase, code, retryable, section) do
    section_identity = if section, do: section_identity(generation, section), else: nil
    ack = rejected_ack(state.identity, pointer, phase, code, retryable, section_identity)
    _result = persist_and_send_ack(state, ack)
    :ok
  end

  defp activation_error(reason) do
    if storage_failure?(reason) do
      {:activation, :storage_failed, true}
    else
      {:activation, :activation_failed, true}
    end
  end

  defp record_and_finalize_activation(
         state,
         decision,
         terminal_ack,
         reconcile_owners?,
         transition,
         authority
       ) do
    with :ok <- require_current_transition(state, transition),
         :ok <- record_activation_decision(state, decision, terminal_ack, authority),
         :ok <- require_current_transition(state, transition),
         :ok <-
           finalize_recorded_activation(
             state,
             decision,
             terminal_ack,
             reconcile_owners?,
             transition
           ) do
      :ok
    end
  end

  defp record_activation_decision(
         state,
         :candidate,
         terminal_ack,
         {:session, authorization}
       ) do
    with_authorized_session_transition(state, authorization, fn ->
      Store.record_activation_decision(state.store, :candidate, terminal_ack)
    end)
  end

  defp record_activation_decision(state, :candidate, terminal_ack, :recovery) do
    with {:ok, %{decision: :candidate}} <- Store.activation_journal(state.store) do
      Store.record_activation_decision(state.store, :candidate, terminal_ack)
    else
      _other -> {:error, :candidate_authority_missing}
    end
  end

  defp record_activation_decision(state, :prior, terminal_ack, authority)
       when authority in [:recovery, :safety] do
    Store.record_activation_decision(state.store, :prior, terminal_ack)
  end

  defp record_activation_decision(_state, _decision, _terminal_ack, _authority),
    do: {:error, :activation_decision_authority_invalid}

  defp finalize_recorded_activation(
         state,
         decision,
         terminal_ack,
         reconcile_owners?,
         transition
       ) do
    with :ok <- require_current_transition(state, transition),
         true <- exact_ack_identity?(terminal_ack, state.identity),
         {:ok, %{decision: ^decision, terminal_ack: ^terminal_ack} = journal} <-
           Store.commit_activation_decision(state.store),
         :ok <- require_current_transition(state, transition),
         :ok <- reconcile_decided_owners(state, journal, reconcile_owners?, transition),
         :ok <- require_current_transition(state, transition),
         :ok <- persist_ack(state, terminal_ack),
         :ok <- require_current_transition(state, transition),
         :ok <- Store.complete_activation(state.store),
         :ok <- require_current_transition(state, transition) do
      _result = send_ack(state, terminal_ack)
      :ok
    else
      false -> {:error, :terminal_ack_identity_mismatch}
      {:error, _reason} = error -> error
      _other -> {:error, :activation_decision_mismatch}
    end
  end

  defp reconcile_decided_owners(_state, _journal, false, _transition), do: :ok

  defp reconcile_decided_owners(
         state,
         %{decision: :prior, prior: nil},
         true,
         transition
       ) do
    call_applier(state.applier, :reset, [transition.owner_pid_map])
  end

  defp reconcile_decided_owners(
         state,
         %{decision: decision} = journal,
         true,
         transition
       ) do
    call_applier(state.applier, :reconcile, [
      Map.fetch!(journal, decision),
      transition.owner_pid_map
    ])
  end

  defp reject_transfer(state, payload, reason, section) do
    error_code = if reason == :section_hash_mismatch, do: :section_hash_mismatch, else: :transfer_incomplete

    section_identity =
      case Store.load_generation(state.store, payload.generation, payload.manifest_hash) do
        {:ok, generation} -> section_identity(generation, section)
        {:error, _reason} -> nil
      end

    ack = rejected_ack(state.identity, payload, :transfer, error_code, true, section_identity)
    _result = persist_and_send_ack(state, ack)
    :ok
  end

  defp recover_interrupted_activation(state) do
    case ensure_runtime_closed(state) do
      {:ok, state} ->
        recover_interrupted_activation_with_closed_gate(state)

      {:error, state} ->
        state
    end
  end

  defp recover_interrupted_activation_with_closed_gate(state) do
    case Store.activation_journal(state.store) do
      {:ok, journal} ->
        recover_verified_activation_journal(state, journal)

      :empty ->
        state

      {:error, :corrupt_activation_journal} ->
        quiesce_recovery(
          state,
          {:activation_journal_invalid, :corrupt_activation_journal}
        )

      {:error, reason} ->
        schedule_owner_reconcile(
          state,
          {:activation_journal_read, reason}
        )
    end
  end

  defp recover_verified_activation_journal(state, journal) do
    case activation_journal_identity(state, journal) do
      {:ok, :current} ->
        recover_activation_journal(state, journal)

      {:ok, :superseded} ->
        recover_superseded_activation_journal(state, journal)

      {:mismatch, reason} ->
        quiesce_recovery(
          close_runtime(state),
          {:activation_identity_mismatch, reason}
        )

      {:error, reason} ->
        schedule_owner_reconcile(
          close_runtime(state),
          {:activation_identity_read, reason}
        )
    end
  end

  defp activation_journal_identity(
         state,
         %{decision: :prior} = journal
       ),
       do: activation_prior_decision_identity(state, journal)

  defp activation_journal_identity(state, %{candidate: candidate}),
    do: activation_candidate_identity(state, candidate)

  defp activation_prior_decision_identity(
         state,
         %{prior: nil, candidate: candidate, terminal_ack: terminal_ack}
       ) do
    with :ok <- activation_terminal_ack_binding(state, candidate, terminal_ack) do
      activation_candidate_identity(state, candidate)
    end
  end

  defp activation_prior_decision_identity(
         state,
         %{prior: prior, candidate: candidate, terminal_ack: terminal_ack}
       ) do
    with :ok <- activation_terminal_ack_binding(state, candidate, terminal_ack),
         true <-
           Map.get(prior, :storage_epoch) == state.identity.storage_epoch ||
             {:mismatch, :prior_storage_epoch_mismatch},
         {:ok, %{manifest: manifest}} <-
           Store.load_generation(state.store, prior.generation, prior.manifest_hash),
         true <-
           manifest.device_id == state.identity.device_id ||
             {:mismatch, :prior_device_mismatch},
         true <-
           manifest.credential_epoch == prior.credential_epoch ||
             {:mismatch, :prior_credential_epoch_mismatch} do
      activation_credential_epoch_identity(
        candidate.credential_epoch,
        state.identity.credential_epoch
      )
    else
      {:mismatch, reason} -> {:mismatch, reason}
      {:error, reason} -> {:error, reason}
      false -> {:mismatch, :prior_identity_mismatch}
    end
  end

  defp activation_terminal_ack_binding(state, candidate, terminal_ack) do
    with true <-
           Map.get(candidate, :storage_epoch) == state.identity.storage_epoch ||
             {:mismatch, :storage_epoch_mismatch},
         true <-
           Map.get(terminal_ack, :device_id) == state.identity.device_id ||
             {:mismatch, :terminal_ack_device_mismatch},
         true <-
           Map.get(terminal_ack, :storage_epoch) == state.identity.storage_epoch ||
             {:mismatch, :terminal_ack_storage_epoch_mismatch},
         true <-
           Map.get(terminal_ack, :credential_epoch) == candidate.credential_epoch ||
             {:mismatch, :terminal_ack_credential_epoch_mismatch},
         true <-
           Map.get(terminal_ack, :generation) == candidate.generation ||
             {:mismatch, :terminal_ack_generation_mismatch},
         true <-
           secure_equal(
             Map.get(terminal_ack, :manifest_hash),
             candidate.manifest_hash
           ) || {:mismatch, :terminal_ack_manifest_hash_mismatch} do
      :ok
    else
      {:mismatch, reason} -> {:mismatch, reason}
      false -> {:mismatch, :terminal_ack_identity_mismatch}
    end
  end

  defp activation_candidate_identity(state, candidate) do
    with true <-
           Map.get(candidate, :storage_epoch) == state.identity.storage_epoch ||
             {:mismatch, :storage_epoch_mismatch},
         {:ok, %{manifest: manifest}} <-
           Store.load_generation(state.store, candidate.generation, candidate.manifest_hash),
         true <- manifest.device_id == state.identity.device_id || {:mismatch, :device_mismatch},
         true <-
           manifest.credential_epoch == candidate.credential_epoch ||
             {:mismatch, :credential_epoch_mismatch} do
      activation_credential_epoch_identity(
        candidate.credential_epoch,
        state.identity.credential_epoch
      )
    else
      {:mismatch, reason} -> {:mismatch, reason}
      {:error, reason} -> {:error, reason}
      false -> {:mismatch, :candidate_identity_mismatch}
    end
  end

  defp activation_credential_epoch_identity(candidate_epoch, current_epoch) do
    cond do
      candidate_epoch == current_epoch -> {:ok, :current}
      candidate_epoch < current_epoch -> {:ok, :superseded}
      true -> {:mismatch, :credential_epoch_future}
    end
  end

  defp recover_superseded_activation_journal(
         state,
         %{decision: decision, terminal_ack: terminal_ack} = journal
       )
       when decision in [:candidate, :prior] and is_map(terminal_ack) do
    recover_activation_journal(state, journal)
  end

  defp recover_superseded_activation_journal(
         state,
         %{decision: nil, terminal_ack: nil, candidate: candidate}
       ) do
    stale_identity = %{state.identity | credential_epoch: candidate.credential_epoch}

    terminal_ack =
      rejected_ack(
        stale_identity,
        candidate,
        :activation,
        :activation_failed,
        false,
        nil
      )

    with :ok <- Store.record_activation_decision(state.store, :prior, terminal_ack),
         {:ok, %{decision: :prior, terminal_ack: ^terminal_ack} = decided} <-
           Store.activation_journal(state.store) do
      with_recovery_transition(state, fn transition ->
        case retire_superseded_activation(state, decided, transition) do
          :ok ->
            finish_recovery_transition(state, transition)

          {:error, {:gate_transition_changed, reason}} ->
            transition_recovery_failed(state, reason)

          {:error, reason} ->
            schedule_owner_reconcile(
              close_runtime(state),
              {:superseded_activation_retirement, reason}
            )
        end
      end)
    else
      {:error, reason} ->
        schedule_owner_reconcile(
          close_runtime(state),
          {:superseded_activation_retirement, reason}
        )

      _other ->
        schedule_owner_reconcile(
          close_runtime(state),
          {:superseded_activation_retirement, :activation_decision_mismatch}
        )
    end
  end

  defp recover_superseded_activation_journal(state, _journal) do
    quiesce_recovery(
      close_runtime(state),
      {:activation_identity_mismatch, :invalid_superseded_journal}
    )
  end

  defp recover_activation_journal(
         state,
         %{decision: decision, terminal_ack: terminal_ack} = journal
       )
       when decision in [:candidate, :prior] and is_map(terminal_ack) do
    case terminal_ack_for_current_boot(terminal_ack, state.identity) do
      {:ok, current_ack} ->
        with_recovery_transition(state, fn transition ->
          case record_and_finalize_activation(
                 state,
                 decision,
                 current_ack,
                 true,
                 transition,
                 :recovery
               ) do
            :ok ->
              finish_recovery_transition(state, transition)

            {:error, {:gate_transition_changed, reason}} ->
              transition_recovery_failed(state, reason)

            {:error, reason} ->
              schedule_owner_reconcile(
                close_runtime(state),
                {:activation_recovery_failed, reason}
              )
          end
        end)

      {:error, :credential_epoch_superseded} ->
        with_recovery_transition(state, fn transition ->
          case retire_superseded_activation(state, journal, transition) do
            :ok ->
              finish_recovery_transition(state, transition)

            {:error, {:gate_transition_changed, reason}} ->
              transition_recovery_failed(state, reason)

            {:error, reason} ->
              schedule_owner_reconcile(
                close_runtime(state),
                {:superseded_activation_retirement, reason}
              )
          end
        end)

      {:error, reason} ->
        quiesce_recovery(
          close_runtime(state),
          {:activation_identity_mismatch, reason}
        )
    end
  end

  defp recover_activation_journal(state, %{decision: nil, candidate: candidate}) do
    rejected =
      rejected_ack(
        state.identity,
        candidate,
        :activation,
        :activation_failed,
        true,
        nil
      )

    with_recovery_transition(state, fn transition ->
      case record_and_finalize_activation(
             state,
             :prior,
             rejected,
             true,
             transition,
             :safety
           ) do
        :ok ->
          finish_recovery_transition(state, transition)

        {:error, {:gate_transition_changed, reason}} ->
          transition_recovery_failed(state, reason)

        {:error, reason} ->
          schedule_owner_reconcile(
            close_runtime(state),
            {:activation_recovery_failed, reason}
          )
      end
    end)
  end

  defp recover_activation_journal(state, _journal) do
    schedule_owner_reconcile(
      close_runtime(state),
      {:activation_recovery_failed, :invalid_activation_journal}
    )
  end

  defp retire_superseded_activation(state, journal, transition) do
    with :ok <- require_current_transition(state, transition),
         {:ok,
          %{
            decision: decision,
            terminal_ack: terminal_ack
          } = committed} <- Store.commit_activation_decision(state.store),
         true <- decision == journal.decision and terminal_ack == journal.terminal_ack,
         :ok <- require_current_transition(state, transition),
         :ok <- reconcile_decided_owners(state, committed, true, transition),
         :ok <- require_current_transition(state, transition),
         :ok <- persist_ack(state, terminal_ack),
         :ok <- require_current_transition(state, transition),
         :ok <- Store.complete_activation(state.store),
         :ok <- require_current_transition(state, transition) do
      :ok
    else
      false -> {:error, :activation_decision_mismatch}
      {:error, _reason} = error -> error
      _other -> {:error, :activation_decision_mismatch}
    end
  end

  defp reconcile_active_runtime(%{identity: nil} = state), do: close_runtime_quiescent(state)

  defp reconcile_active_runtime(%{checkpoint_hydration: %{state: :blocked}} = state),
    do: close_runtime_quiescent(state)

  defp reconcile_active_runtime(state) do
    case Store.activation_journal(state.store) do
      :empty ->
        reconcile_active_pointer(state)

      {:ok, _journal} ->
        close_runtime(state)

      {:error, reason} ->
        schedule_owner_reconcile(
          close_runtime(state),
          {:activation_journal_read, reason}
        )
    end
  end

  defp reconcile_active_pointer(state) do
    case Store.active(state.store) do
      :empty ->
        close_runtime_quiescent(state)

      {:ok, pointer} ->
        reconcile_active_pointer(state, pointer)

      {:error, reason} ->
        schedule_owner_reconcile(
          close_runtime(state),
          {:active_pointer_read, reason}
        )
    end
  end

  defp reconcile_active_pointer(state, pointer) do
    cond do
      not pointer_matches_identity?(pointer, state.identity) ->
        close_runtime_quiescent(state)

      not checkpoint_hydration_binding_current?(state, pointer) ->
        state
        |> mark_checkpoint_hydration_stale()
        |> close_runtime_quiescent()

      current_runtime_matches?(state, pointer) ->
        reset_owner_reconcile(state)

      true ->
        case ensure_runtime_closed(state) do
          {:ok, state} ->
            action =
              with_prepared_transition(state, fn transition ->
                with :ok <- require_current_transition(state, transition),
                     :ok <-
                       call_applier(state.applier, :reconcile, [
                         pointer,
                         transition.owner_pid_map
                       ]),
                     :ok <- require_current_transition(state, transition) do
                  {:open_prepared, transition}
                else
                  {:error, {:gate_transition_changed, reason}} ->
                    transition_pending_action(reason)

                  {:error, reason} ->
                    {:reconcile_pending, {:active_owner_reconcile, reason}}
                end
              end)

            apply_runtime_action(state, action)

          {:error, state} ->
            state
        end
    end
  end

  defp current_runtime_matches?(
         %{
           lease_sentinel_pid: sentinel_pid,
           leased_owner_pid_map: owner_pid_map,
           leased_authority_bindings: authority_bindings
         } = state,
         pointer
       )
       when is_pid(sentinel_pid) and is_map(owner_pid_map) and
              is_map(authority_bindings) do
    expected_status = {:open, gate_binding(pointer)}

    with true <- Process.alive?(sentinel_pid),
         :ok <- verify_gate_set(state),
         ^expected_status <- gate_status(state),
         :ok <-
           verify_leased_owner_authority(
             state.applier,
             owner_pid_map,
             authority_bindings
           ),
         ^expected_status <- gate_status(state) do
      true
    else
      _other -> false
    end
  end

  defp current_runtime_matches?(_state, _pointer), do: false

  defp apply_runtime_action(state, :none), do: state
  defp apply_runtime_action(state, :closed), do: close_runtime(state)

  defp apply_runtime_action(state, :reconcile_pending) do
    state
    |> close_runtime()
    |> schedule_owner_reconcile()
  end

  defp apply_runtime_action(state, {:reconcile_pending, reason}) do
    state
    |> close_runtime()
    |> schedule_owner_reconcile(reason)
  end

  defp apply_runtime_action(%{identity: nil} = state, {:open_prepared, _transition}),
    do: close_runtime_quiescent(state)

  defp apply_runtime_action(
         %{checkpoint_hydration: %{state: :blocked}} = state,
         {:open_prepared, _transition}
       ),
       do: close_runtime_quiescent(state)

  defp apply_runtime_action(state, {:open_prepared, transition}) do
    case Store.active(state.store) do
      {:ok, pointer} ->
        if pointer_matches_identity?(pointer, state.identity) do
          open_runtime_prepared(state, pointer, transition)
        else
          quiesce_recovery(
            close_runtime(state),
            :active_pointer_identity_mismatch
          )
        end

      :empty ->
        schedule_owner_reconcile(
          close_runtime(state),
          :active_pointer_missing
        )

      {:error, reason} ->
        schedule_owner_reconcile(
          close_runtime(state),
          {:active_pointer_read, reason}
        )
    end
  end

  defp open_runtime_prepared(state, pointer, transition) do
    state = monitor_gate(state)

    if gate_available?(state) do
      case require_current_transition(state, transition) do
        :ok ->
          owner_pids = transition.owner_pid_map |> Map.values() |> Enum.uniq()

          state =
            state
            |> install_owner_monitors(owner_pids)
            |> install_lease_sentinel(
              transition.owner_pid_map,
              transition.authority_bindings
            )

          case gate_open_prepared(state, pointer, owner_pids, transition.token) do
            :ok ->
              reset_owner_reconcile(state)

            {:error, reason} ->
              schedule_owner_reconcile(
                close_runtime(state),
                {:gate_open_failed, reason}
              )
          end

        {:error, {:gate_transition_changed, reason}} ->
          state
          |> close_runtime()
          |> schedule_owner_reconcile({:owner_resolution_failed, reason})
      end
    else
      schedule_owner_reconcile(close_runtime(state), :gate_unavailable)
    end
  end

  defp close_runtime(state) do
    case attempt_close_runtime(state) do
      {:ok, state} ->
        state

      {:error, state, reason} ->
        schedule_owner_reconcile(state, reason)
    end
  end

  defp close_runtime_quiescent(state) do
    case attempt_close_runtime(state) do
      {:ok, state} ->
        reset_owner_reconcile(state)

      {:error, state, reason} ->
        schedule_owner_reconcile(state, reason)
    end
  end

  defp ensure_runtime_closed(state) do
    case attempt_close_runtime(state) do
      {:ok, state} ->
        {:ok, state}

      {:error, state, reason} ->
        {:error, schedule_owner_reconcile(state, reason)}
    end
  end

  defp attempt_close_runtime(state) do
    state =
      state
      |> revoke_lease_sentinel()
      |> clear_owner_monitors()
      |> monitor_gate()

    if gate_available?(state) do
      case gate_close(state) do
        :ok ->
          {:ok, state}

        {:error, reason} ->
          {:error, clear_gate_monitor(state), {:gate_close_failed, reason}}
      end
    else
      {:error, state, :gate_unavailable}
    end
  end

  defp monitor_gate(%{gate_pid: gate_pid} = state) when is_pid(gate_pid) do
    case resolve_gate_pid(state.gate, state.owner_resolution_timeout_ms) do
      ^gate_pid ->
        if Process.alive?(gate_pid), do: state, else: clear_gate_monitor(state)

      replacement_pid when is_pid(replacement_pid) ->
        state
        |> clear_gate_monitor()
        |> monitor_gate_pid(replacement_pid)

      _other ->
        clear_gate_monitor(state)
    end
  end

  defp monitor_gate(state) do
    case resolve_gate_pid(state.gate, state.owner_resolution_timeout_ms) do
      gate_pid when is_pid(gate_pid) -> monitor_gate_pid(state, gate_pid)
      _other -> state
    end
  end

  defp monitor_gate_pid(state, gate_pid) do
    if Process.alive?(gate_pid) do
      %{state | gate_pid: gate_pid, gate_monitor_ref: Process.monitor(gate_pid)}
    else
      state
    end
  end

  defp clear_gate_monitor(%{gate_monitor_ref: nil} = state),
    do: %{state | gate_pid: nil}

  defp clear_gate_monitor(%{gate_monitor_ref: monitor_ref} = state) do
    Process.demonitor(monitor_ref, [:flush])
    %{state | gate_pid: nil, gate_monitor_ref: nil}
  end

  defp gate_available?(%{gate_pid: gate_pid}) when is_pid(gate_pid),
    do: Process.alive?(gate_pid)

  defp gate_available?(_state), do: false

  defp resolve_gate_pid(gate, timeout_ms) do
    case OwnerResolver.resolve([gate], timeout_ms: timeout_ms) do
      {:ok, %{^gate => gate_pid}} when is_pid(gate_pid) -> gate_pid
      _other -> nil
    end
  end

  defp verify_gate_set(%{
         gate_pid: expected_gate_pid,
         gate: gate,
         owner_resolution_timeout_ms: timeout_ms
       })
       when is_pid(expected_gate_pid) do
    case resolve_gate_pid(gate, timeout_ms) do
      ^expected_gate_pid ->
        if Process.alive?(expected_gate_pid), do: :ok, else: {:error, :gate_unavailable}

      replacement_gate_pid when is_pid(replacement_gate_pid) ->
        {:error, :gate_set_changed}

      _other ->
        {:error, :gate_unavailable}
    end
  end

  defp verify_gate_set(_state), do: {:error, :gate_unavailable}

  defp gate_close(state) do
    case call_gate(fn -> OperationalGate.close(state.gate_pid) end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, _other} -> {:error, :invalid_gate_response}
      {:error, _reason} = error -> error
    end
  end

  defp gate_prepare_transition(state, authority_bindings) do
    case call_gate(fn ->
           OperationalGate.prepare_transition(
             state.gate_pid,
             state.controller_capability,
             self(),
             authority_bindings
           )
         end) do
      {:ok, {:ok, transition_token}} when is_reference(transition_token) ->
        {:ok, transition_token}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, _other} ->
        {:error, :invalid_gate_response}

      {:error, _reason} = error ->
        error
    end
  end

  defp gate_transition_current(state, transition_token) do
    case call_gate(fn ->
           OperationalGate.transition_current(
             state.gate_pid,
             state.controller_capability,
             self(),
             transition_token
           )
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, _other} -> {:error, :invalid_gate_response}
      {:error, _reason} = error -> error
    end
  end

  defp gate_open_prepared(state, pointer, owner_pids, transition_token) do
    dependency_pids =
      Enum.uniq([
        state.lease_sentinel_pid,
        checkpoint_hydration_dependency(state)
        | owner_pids
      ])
      |> Enum.reject(&is_nil/1)

    case call_gate(fn ->
           OperationalGate.open_prepared(
             state.gate_pid,
             state.controller_capability,
             self(),
             transition_token,
             dependency_pids,
             gate_binding(pointer)
           )
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, _other} -> {:error, :invalid_gate_response}
      {:error, _reason} = error -> error
    end
  end

  defp gate_status(state) do
    case call_gate(fn -> OperationalGate.status(state.gate_pid) end) do
      {:ok, :closed} -> :closed
      {:ok, {:open, _binding} = status} -> status
      _other -> :closed
    end
  end

  defp call_gate(fun) do
    {:ok, fun.()}
  rescue
    _exception -> {:error, :gate_unavailable}
  catch
    _kind, _reason -> {:error, :gate_unavailable}
  end

  defp install_lease_sentinel(state, owner_pid_map, authority_bindings) do
    state = revoke_lease_sentinel(state)
    manager_pid = self()
    lease_token = make_ref()

    sentinel_pid =
      spawn(fn ->
        watch_lease_owner(manager_pid, lease_token, state.lease_timeout_ms)
      end)

    state = %{
      state
      | lease_sentinel_pid: sentinel_pid,
        lease_sentinel_monitor_ref: Process.monitor(sentinel_pid),
        lease_sentinel_token: lease_token,
        leased_owner_pid_map: owner_pid_map,
        leased_authority_bindings: authority_bindings
    }

    send(sentinel_pid, {:lease_heartbeat, manager_pid, lease_token})
    schedule_lease_heartbeat(state)
  end

  defp invalidate_lease_sentinel(%{lease_sentinel_pid: nil}), do: :ok

  defp invalidate_lease_sentinel(%{lease_sentinel_pid: sentinel_pid})
       when is_pid(sentinel_pid) do
    monitor_ref = Process.monitor(sentinel_pid)
    Process.exit(sentinel_pid, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, ^sentinel_pid, _reason} -> :ok
    end
  end

  defp invalidate_lease_sentinel(_state), do: :ok

  defp revoke_lease_sentinel(%{lease_sentinel_pid: nil} = state),
    do: clear_lease_sentinel(state)

  defp revoke_lease_sentinel(
         %{
           lease_sentinel_pid: sentinel_pid,
           lease_sentinel_monitor_ref: monitor_ref
         } = state
       )
       when is_pid(sentinel_pid) and is_reference(monitor_ref) do
    state = cancel_lease_heartbeat(state)
    Process.exit(sentinel_pid, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, ^sentinel_pid, _reason} ->
        clear_lease_sentinel(state)
    end
  end

  defp revoke_lease_sentinel(state), do: clear_lease_sentinel(state)

  defp clear_lease_sentinel(%{lease_sentinel_monitor_ref: monitor_ref} = state)
       when is_reference(monitor_ref) do
    state = cancel_lease_heartbeat(state)
    Process.demonitor(monitor_ref, [:flush])

    %{
      state
      | lease_sentinel_pid: nil,
        lease_sentinel_monitor_ref: nil,
        lease_sentinel_token: nil,
        leased_owner_pid_map: nil,
        leased_authority_bindings: nil
    }
  end

  defp clear_lease_sentinel(state) do
    state = cancel_lease_heartbeat(state)

    %{
      state
      | lease_sentinel_pid: nil,
        lease_sentinel_monitor_ref: nil,
        lease_sentinel_token: nil,
        leased_owner_pid_map: nil,
        leased_authority_bindings: nil
    }
  end

  defp schedule_lease_heartbeat(%{lease_sentinel_pid: sentinel_pid, lease_sentinel_token: lease_token} = state)
       when is_pid(sentinel_pid) and is_reference(lease_token) do
    state = cancel_lease_heartbeat(state)

    timer_ref =
      Process.send_after(
        self(),
        {:lease_heartbeat, lease_token},
        state.lease_heartbeat_ms
      )

    %{state | lease_heartbeat_ref: timer_ref}
  end

  defp schedule_lease_heartbeat(state), do: cancel_lease_heartbeat(state)

  defp cancel_lease_heartbeat(%{lease_heartbeat_ref: nil} = state), do: state

  defp cancel_lease_heartbeat(%{lease_heartbeat_ref: timer_ref} = state) do
    _result = Process.cancel_timer(timer_ref)
    %{state | lease_heartbeat_ref: nil}
  end

  defp watch_lease_owner(manager_pid, lease_token, lease_timeout_ms) do
    monitor_ref = Process.monitor(manager_pid)
    watch_lease_owner(manager_pid, monitor_ref, lease_token, lease_timeout_ms)
  end

  defp watch_lease_owner(manager_pid, monitor_ref, lease_token, lease_timeout_ms) do
    receive do
      {:lease_heartbeat, ^manager_pid, ^lease_token} ->
        watch_lease_owner(manager_pid, monitor_ref, lease_token, lease_timeout_ms)

      {:DOWN, ^monitor_ref, :process, ^manager_pid, _reason} ->
        :ok
    after
      lease_timeout_ms -> :ok
    end
  end

  defp install_owner_monitors(state, owner_pids) do
    state = clear_owner_monitors(state)

    monitors =
      Map.new(owner_pids, fn owner_pid ->
        {Process.monitor(owner_pid), owner_pid}
      end)

    %{state | owner_monitors: monitors}
  end

  defp clear_owner_monitors(state) do
    Enum.each(Map.keys(state.owner_monitors), &Process.demonitor(&1, [:flush]))
    %{state | owner_monitors: %{}}
  end

  defp schedule_owner_reconcile(state, reason \\ :reconciliation_pending)

  defp schedule_owner_reconcile(%{recovery_quiescent?: true} = state, _reason), do: state

  defp schedule_owner_reconcile(%{owner_retry_ref: nil} = state, reason) do
    delay = owner_retry_delay(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:reconcile_authoritative_owners, token}, delay)

    %{
      state
      | owner_retry_attempt: state.owner_retry_attempt + 1,
        owner_retry_delay_ms: delay,
        owner_retry_ref: timer_ref,
        owner_retry_token: token,
        recovery_error: preferred_recovery_error(state.recovery_error, reason)
    }
  end

  defp schedule_owner_reconcile(state, reason) do
    %{state | recovery_error: preferred_recovery_error(state.recovery_error, reason)}
  end

  defp preferred_recovery_error(current, :reconciliation_pending) when not is_nil(current),
    do: current

  defp preferred_recovery_error(_current, reason), do: reason

  defp owner_retry_delay(state) do
    multiplier = Integer.pow(2, min(state.owner_retry_attempt, 30))
    min(state.owner_retry_base_ms * multiplier, state.owner_retry_max_ms)
  end

  defp consume_owner_retry(state) do
    %{
      state
      | owner_retry_delay_ms: nil,
        owner_retry_ref: nil,
        owner_retry_token: nil
    }
  end

  defp reset_owner_reconcile(state) do
    if is_reference(state.owner_retry_ref), do: Process.cancel_timer(state.owner_retry_ref)

    %{
      state
      | owner_retry_attempt: 0,
        owner_retry_delay_ms: nil,
        owner_retry_ref: nil,
        owner_retry_token: nil,
        recovery_error: nil,
        recovery_quiescent?: false
    }
  end

  defp quiesce_recovery(state, reason) do
    state
    |> reset_owner_reconcile()
    |> Map.put(:recovery_error, reason)
    |> Map.put(:recovery_quiescent?, true)
  end

  defp refresh_identity(state) do
    case resolve_identity(state.identity_source) do
      {:ok, identity} when identity == state.identity ->
        schedule_identity_refresh(state)

      {:ok, identity} ->
        state =
          state
          |> reset_owner_reconcile()
          |> close_runtime()
          |> Map.put(:identity, identity)
          |> recover_interrupted_activation()
          |> reconcile_active_runtime()

        replay_current_acks(state)
        schedule_identity_refresh(state)

      {:error, _reason} ->
        state
        |> reset_owner_reconcile()
        |> close_runtime_quiescent()
        |> Map.put(:identity, nil)
        |> schedule_identity_refresh()
    end
  end

  defp resolve_identity(identity) when is_map(identity), do: validate_runtime_identity(identity)

  defp resolve_identity(provider) when is_function(provider, 0) do
    case provider.() do
      {:ok, identity} -> validate_runtime_identity(identity)
      identity when is_map(identity) -> validate_runtime_identity(identity)
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_identity_provider_result}
    end
  rescue
    _exception -> {:error, :identity_provider_failed}
  catch
    _kind, _reason -> {:error, :identity_provider_failed}
  end

  defp resolve_identity(_identity), do: {:error, :invalid_identity_provider}

  defp validate_runtime_identity(
         %{
           device_id: device_id,
           credential_epoch: credential_epoch,
           boot_id: boot_id,
           storage_epoch: storage_epoch
         } = identity
       )
       when is_binary(device_id) and byte_size(device_id) == 16 and
              device_id != @zero_identifier and is_integer(credential_epoch) and
              credential_epoch >= 0 and credential_epoch <= 0xFFFF_FFFF and
              is_binary(boot_id) and byte_size(boot_id) == 16 and
              boot_id != @zero_identifier and is_binary(storage_epoch) and
              byte_size(storage_epoch) == 16 and storage_epoch != @zero_identifier do
    {:ok, Map.take(identity, @identity_keys)}
  end

  defp validate_runtime_identity(_identity), do: {:error, :invalid_runtime_identity}

  defp schedule_identity_refresh(%{identity_source: source} = state)
       when is_function(source, 0) do
    state = cancel_identity_refresh(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:refresh_identity, token}, state.identity_refresh_ms)
    %{state | identity_refresh_ref: timer_ref, identity_refresh_token: token}
  end

  defp schedule_identity_refresh(state), do: cancel_identity_refresh(state)

  defp cancel_identity_refresh(%{identity_refresh_ref: nil} = state), do: state

  defp cancel_identity_refresh(%{identity_refresh_ref: timer_ref} = state) do
    _result = Process.cancel_timer(timer_ref)
    %{state | identity_refresh_ref: nil, identity_refresh_token: nil}
  end

  defp positive_milliseconds(value, _default) when is_integer(value) and value > 0,
    do: value

  defp positive_milliseconds(_value, default), do: default

  defp pointer_matches_identity?(pointer, identity) do
    Map.get(pointer, :device_id) == Map.get(identity, :device_id) and
      Map.get(pointer, :credential_epoch) == Map.get(identity, :credential_epoch) and
      Map.get(pointer, :storage_epoch) == Map.get(identity, :storage_epoch)
  end

  defp with_prepared_transition(state, fun) when is_function(fun, 1) do
    case resolve_owner_authority(state.applier) do
      {:ok, owner_pid_map, authority_bindings} ->
        case gate_prepare_transition(state, authority_bindings) do
          {:ok, transition_token} ->
            transition = %{
              token: transition_token,
              owner_pid_map: owner_pid_map,
              authority_bindings: authority_bindings
            }

            case require_current_transition(state, transition) do
              :ok -> fun.(transition)
              {:error, {:gate_transition_changed, reason}} -> transition_pending_action(reason)
            end

          {:error, reason} ->
            transition_pending_action(reason)
        end

      {:error, reason} ->
        {:reconcile_pending, {:owner_resolution_failed, reason}}
    end
  end

  defp with_recovery_transition(state, fun) when is_function(fun, 1) do
    case with_prepared_transition(state, fun) do
      recovered_state when is_map(recovered_state) -> recovered_state
      action -> apply_runtime_action(state, action)
    end
  end

  defp finish_recovery_transition(%{checkpoint_hydration: %{state: :blocked}} = state, _transition),
    do: close_runtime_quiescent(state)

  defp finish_recovery_transition(state, transition) do
    case Store.active(state.store) do
      {:ok, pointer} ->
        if pointer_matches_identity?(pointer, state.identity) do
          open_runtime_prepared(state, pointer, transition)
        else
          close_runtime_quiescent(state)
        end

      :empty ->
        close_runtime_quiescent(state)

      {:error, reason} ->
        schedule_owner_reconcile(
          close_runtime(state),
          {:active_pointer_read, reason}
        )
    end
  end

  defp transition_recovery_failed(state, reason) do
    apply_runtime_action(state, transition_pending_action(reason))
  end

  defp require_current_transition(
         state,
         %{
           token: transition_token,
           owner_pid_map: owner_pid_map,
           authority_bindings: authority_bindings
         }
       ) do
    with :ok <- current_gate_transition(state, transition_token),
         :ok <-
           verify_leased_owner_authority(
             state.applier,
             owner_pid_map,
             authority_bindings
           ),
         :ok <- current_gate_transition(state, transition_token) do
      :ok
    else
      {:error, {:gate_transition_changed, _reason}} = error -> error
      {:error, reason} -> {:error, {:gate_transition_changed, reason}}
    end
  end

  defp current_gate_transition(state, transition_token) do
    case gate_transition_current(state, transition_token) do
      :ok -> :ok
      {:error, reason} -> {:error, {:gate_transition_changed, reason}}
    end
  end

  defp transition_pending_action(:gate_authority_changed),
    do: {:reconcile_pending, {:owner_resolution_failed, :owner_authority_changed}}

  defp transition_pending_action(:gate_dependency_unavailable),
    do: {:reconcile_pending, {:owner_resolution_failed, :owner_unavailable}}

  defp transition_pending_action(reason)
       when reason in [
              :owner_authority_changed,
              :owner_set_changed,
              :owner_unavailable,
              :owner_resolution_timeout,
              :owner_resolver_failed,
              :invalid_owner_resolver,
              :missing_owner_resolver,
              :incomplete_owner_resolver
            ],
       do: {:reconcile_pending, {:owner_resolution_failed, reason}}

  defp transition_pending_action(reason),
    do: {:reconcile_pending, {:gate_transition_failed, reason}}

  defp verify_leased_owner_authority(
         applier,
         expected_owner_pid_map,
         expected_authority_bindings
       ) do
    case resolve_owner_authority(applier) do
      {:ok, ^expected_owner_pid_map, ^expected_authority_bindings} ->
        :ok

      {:ok, ^expected_owner_pid_map, _changed_authority_bindings} ->
        {:error, :owner_authority_changed}

      {:ok, _changed_owner_pid_map, _authority_bindings} ->
        {:error, :owner_set_changed}

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_owner_authority(applier) do
    case Map.get(applier, :owners) do
      nil ->
        {:error, :missing_owner_resolver}

      owners when is_function(owners, 0) ->
        OwnerResolver.run(
          fn -> owners.() |> normalize_owner_authority() end,
          timeout_ms:
            Map.get(
              applier,
              :owner_resolution_timeout_ms,
              @default_owner_resolution_timeout_ms
            )
        )

      _other ->
        {:error, :invalid_owner_resolver}
    end
  rescue
    _exception -> {:error, :owner_resolver_failed}
  catch
    _kind, _reason -> {:error, :owner_resolver_failed}
  end

  defp normalize_owner_authority(owners) when is_map(owners) do
    if MapSet.new(Map.keys(owners)) == @owner_sections do
      owner_references = owners |> Map.values() |> Enum.uniq()

      resolved_by_reference =
        Map.new(owner_references, fn owner_reference ->
          {owner_reference, resolve_owner_pid(owner_reference)}
        end)

      if resolved_owner_references_alive?(resolved_by_reference) do
        owner_pid_map =
          Map.new(owners, fn {section, owner_reference} ->
            {section, Map.fetch!(resolved_by_reference, owner_reference)}
          end)

        authority_bindings =
          Map.new(owners, fn {section, owner_reference} ->
            owner_pid = Map.fetch!(resolved_by_reference, owner_reference)
            {section, {owner_reference, owner_pid}}
          end)

        {:ok, owner_pid_map, authority_bindings}
      else
        {:error, :owner_unavailable}
      end
    else
      {:error, :incomplete_owner_resolver}
    end
  end

  defp normalize_owner_authority(_owners), do: {:error, :invalid_owner_resolver}

  defp resolved_owner_references_alive?(resolved_by_reference) do
    Enum.all?(resolved_by_reference, fn {_owner_reference, owner_pid} ->
      is_pid(owner_pid) and Process.alive?(owner_pid)
    end)
  end

  defp resolve_owner_pid(pid) when is_pid(pid), do: pid
  defp resolve_owner_pid(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_owner_pid({:global, name}), do: :global.whereis_name(name)
  defp resolve_owner_pid({:via, module, name}), do: module.whereis_name(name)
  defp resolve_owner_pid(_owner), do: nil

  defp replay_current_acks(state) do
    case Store.pending_acks(state.store) do
      {:ok, acks} ->
        # An ACK from a prior boot, credential, or logical identity cannot be
        # authenticated by this runtime, but it is still unreceipted durable data.
        # Keep it until the durable-delivery protocol supplies an authenticated
        # receipt or an explicit loss-authorization boundary.
        Enum.each(acks, fn ack ->
          if exact_ack_identity?(ack, state.identity) do
            _result = send_ack(state, ack)
          end
        end)

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  defp terminal_ack_for_current_boot(ack, identity) do
    cond do
      Enum.all?(@durable_identity_keys, &(Map.get(ack, &1) == Map.get(identity, &1))) ->
        {:ok, Map.put(ack, :boot_id, identity.boot_id)}

      Map.get(ack, :device_id) == identity.device_id and
        Map.get(ack, :storage_epoch) == identity.storage_epoch and
        is_integer(Map.get(ack, :credential_epoch)) and
          Map.get(ack, :credential_epoch) < identity.credential_epoch ->
        {:error, :credential_epoch_superseded}

      true ->
        {:error, :terminal_ack_identity_mismatch}
    end
  end

  defp exact_ack_identity?(ack, identity) do
    Enum.all?(@identity_keys, &(Map.get(ack, &1) == Map.get(identity, &1)))
  end

  defp persist_and_send_ack(state, ack) do
    with :ok <- persist_ack(state, ack) do
      _result = send_ack(state, ack)
      :ok
    end
  end

  defp persist_ack(state, ack) do
    case Store.put_pending_ack(state.store, ack) do
      {:ok, _disposition} -> :ok
      {:error, reason} -> {:error, {:storage_failed, reason}}
    end
  end

  defp send_ack(state, ack) do
    case state.ack_sink.(ack) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
      _other -> {:error, :ack_sink_failed}
    end
  rescue
    _exception -> {:error, :ack_sink_failed}
  catch
    _kind, _reason -> {:error, :ack_sink_failed}
  end

  defp register_applier_manager(%{register: register}) when is_function(register, 0) do
    register.()
    |> normalize_applier_result()
  rescue
    _exception -> {:error, :owner_exception}
  catch
    _kind, _reason -> {:error, :owner_exit}
  end

  defp register_applier_manager(applier) when is_map(applier), do: :ok
  defp register_applier_manager(_applier), do: {:error, :missing_applier_callback}

  defp call_applier(applier, name, args) do
    case Map.fetch(applier, name) do
      {:ok, fun} when is_function(fun, length(args)) ->
        fun
        |> apply(args)
        |> normalize_applier_result()

      _other ->
        {:error, :missing_applier_callback}
    end
  rescue
    _exception -> {:error, :owner_exception}
  catch
    _kind, _reason -> {:error, :owner_exit}
  end

  defp normalize_applier_result(:ok), do: :ok
  defp normalize_applier_result({:ok, _value}), do: :ok
  defp normalize_applier_result({:error, _reason} = error), do: error
  defp normalize_applier_result(other), do: {:error, {:invalid_owner_response, other}}

  defp validate_identity(payload, identity) when is_map(payload) do
    cond do
      Map.get(payload, :device_id) != identity.device_id -> {:error, :device_mismatch}
      Map.get(payload, :credential_epoch) != identity.credential_epoch -> {:error, :credential_epoch_mismatch}
      Map.get(payload, :boot_id) != identity.boot_id -> {:error, :boot_id_mismatch}
      Map.get(payload, :storage_epoch) != identity.storage_epoch -> {:error, :storage_epoch_mismatch}
      true -> :ok
    end
  end

  defp validate_identity(_payload, _identity), do: {:error, :device_mismatch}

  defp decode_manifest(%{manifest: bytes}) when is_binary(bytes), do: Manifest.decode(bytes)
  defp decode_manifest(_delivery), do: {:error, :malformed_manifest}

  defp validate_manifest_identity(delivery, manifest) do
    cond do
      manifest.device_id != delivery.device_id -> {:error, :device_mismatch}
      manifest.credential_epoch != delivery.credential_epoch -> {:error, :credential_epoch_mismatch}
      manifest.generation != delivery.generation -> {:error, :stale_generation}
      not secure_equal(manifest.hash, delivery.manifest_hash) -> {:error, :manifest_hash_mismatch}
      true -> :ok
    end
  end

  defp validate_generation_transition(store, manifest) do
    case Store.active(store) do
      :empty ->
        :ok

      {:ok, %{device_id: device_id}} when device_id != manifest.device_id ->
        :ok

      {:ok, %{credential_epoch: epoch, generation: generation, manifest_hash: hash}}
      when epoch == manifest.credential_epoch and generation == manifest.generation ->
        if secure_equal(hash, manifest.hash), do: :ok, else: {:error, :generation_hash_conflict}

      {:ok, %{credential_epoch: epoch, generation: generation}}
      when epoch == manifest.credential_epoch and generation > manifest.generation ->
        {:error, :stale_generation}

      {:ok, %{credential_epoch: epoch}} when epoch > manifest.credential_epoch ->
        {:error, :stale_generation}

      {:ok, _other} ->
        :ok

      {:error, reason} ->
        {:error, {:storage_failed, reason}}
    end
  end

  defp validate_generation_payload(store, payload) do
    case Store.active(store) do
      {:ok, %{device_id: device_id}} when device_id != payload.device_id ->
        :ok

      {:ok, %{credential_epoch: epoch, generation: generation}}
      when epoch == payload.credential_epoch and generation > payload.generation ->
        {:error, :stale_generation}

      {:ok, %{credential_epoch: epoch}} when epoch > payload.credential_epoch ->
        {:error, :stale_generation}

      {:ok, _other} ->
        :ok

      :empty ->
        :ok

      {:error, reason} ->
        {:error, {:storage_failed, reason}}
    end
  end

  defp validate_compatibility(manifest, compatibility) do
    with :ok <- validate_firmware(manifest.minimum_firmware, compatibility.firmware_version),
         :ok <- validate_capabilities(manifest.required_capabilities, compatibility.capabilities) do
      :ok
    end
  end

  defp validate_firmware(nil, _current), do: :ok

  defp validate_firmware(minimum, current) do
    with {:ok, minimum_version} <- Version.parse(minimum),
         {:ok, current_version} <- Version.parse(current),
         ordering <- Version.compare(current_version, minimum_version),
         true <- ordering in [:eq, :gt] do
      :ok
    else
      _other -> {:error, :incompatible_firmware}
    end
  end

  defp validate_capabilities(required, available) do
    available = Map.new(available)

    if Enum.all?(required, fn {name, version} -> Map.get(available, name) == version end) do
      :ok
    else
      {:error, :incompatible_capability}
    end
  end

  defp validate_secret_binding(generation, metadata) do
    with %{descriptor: wifi} <- Map.get(generation.sections, :wifi),
         false <- wifi.tombstone,
         true <- metadata.section == :wifi,
         true <- metadata.section_schema_version == wifi.schema_version,
         true <- secure_equal(metadata.section_hash, wifi.hash),
         descriptor when is_map(descriptor) <-
           Enum.find(wifi.secrets, &secret_descriptor_matches?(&1, metadata)) do
      :ok
    else
      _other -> {:error, :secret_reference_mismatch}
    end
  end

  defp secret_descriptor_matches?(descriptor, metadata) do
    descriptor.kind == metadata.secret_kind and
      descriptor.digest_key_id == metadata.digest_key_id and
      secure_equal(descriptor.ref, metadata.secret_ref) and
      secure_equal(descriptor.digest, metadata.secret_digest)
  end

  defp secret_required?(generation) do
    case Map.get(generation.sections, :wifi) do
      %{descriptor: %{secrets: [_ | _]}} -> true
      _other -> false
    end
  end

  defp staged_ack(identity, manifest) do
    summaries =
      Enum.map(manifest.sections, fn section ->
        %{
          section: section.name,
          section_schema_version: section.schema_version,
          tombstone: section.tombstone,
          section_hash: section.hash
        }
      end)

    Map.merge(identity, %{
      generation: manifest.generation,
      manifest_hash: manifest.hash,
      status: :staged,
      sections: summaries
    })
  end

  defp effective_ack(identity, pointer) do
    Map.merge(identity, %{
      generation: pointer.generation,
      manifest_hash: pointer.manifest_hash,
      status: :effective
    })
  end

  defp rejected_ack(identity, binding, phase, error_code, retryable, section) do
    Map.merge(identity, %{
      generation: Map.fetch!(binding, :generation),
      manifest_hash: Map.fetch!(binding, :manifest_hash),
      status: :rejected,
      phase: phase,
      error_code: error_code,
      retryable: retryable,
      section: section
    })
  end

  defp section_identity(generation, name) do
    case Map.get(generation.sections, name) do
      %{descriptor: descriptor} ->
        %{
          section: name,
          section_schema_version: descriptor.schema_version,
          section_hash: descriptor.hash
        }

      _other ->
        nil
    end
  end

  defp checkpoint_hydration_startup_barrier(opts) do
    if Keyword.get(opts, :checkpoint_hydration_startup_barrier, false) == true do
      %{
        state: :blocked,
        coordinator_pid: nil,
        coordinator_available?: false,
        token: nil,
        binding: nil
      }
    else
      nil
    end
  end

  defp pointer_from(binding) do
    %{
      device_id: binding.device_id,
      storage_epoch: binding.storage_epoch,
      credential_epoch: binding.credential_epoch,
      generation: binding.generation,
      manifest_hash: binding.manifest_hash
    }
  end

  defp gate_binding(pointer) do
    Map.take(pointer, [:credential_epoch, :storage_epoch, :generation, :manifest_hash])
  end

  defp begin_checkpoint_hydration_fenced(state, coordinator_pid, token, binding)
       when is_pid(coordinator_pid) and is_reference(token) do
    with {:ok, binding} <- validate_checkpoint_hydration_binding(binding),
         {:ok, active} <- current_checkpoint_hydration_binding(state),
         true <- active == binding,
         :ok <- validate_checkpoint_hydration_begin(state, coordinator_pid, token, binding) do
      state =
        state
        |> install_checkpoint_hydration(coordinator_pid, token, binding)
        |> close_runtime_quiescent()

      {:ok, state}
    else
      false -> {{:error, :checkpoint_hydration_binding_mismatch}, close_runtime_quiescent(state)}
      {:error, reason} -> {{:error, reason}, close_runtime_quiescent(state)}
    end
  end

  defp begin_checkpoint_hydration_fenced(state, _coordinator_pid, _token, _binding),
    do: {{:error, :invalid_checkpoint_hydration_blocker}, close_runtime_quiescent(state)}

  defp finish_checkpoint_hydration_fenced(state, coordinator_pid, token, binding) do
    with {:ok, binding} <- validate_checkpoint_hydration_binding(binding),
         :ok <- validate_checkpoint_hydration_finish(state, coordinator_pid, token, binding),
         {:ok, active} <- current_checkpoint_hydration_binding(state),
         true <- active == binding do
      state =
        state
        |> Map.update!(:checkpoint_hydration, &%{&1 | state: :ready})
        |> reconcile_active_runtime()

      {:ok, state}
    else
      false -> {{:error, :checkpoint_hydration_binding_mismatch}, close_runtime_quiescent(state)}
      {:error, reason} -> {{:error, reason}, close_runtime_quiescent(state)}
    end
  end

  defp validate_checkpoint_hydration_begin(
         %{checkpoint_hydration: nil},
         _coordinator_pid,
         _token,
         _binding
       ),
       do: :ok

  defp validate_checkpoint_hydration_begin(
         %{checkpoint_hydration: %{coordinator_pid: coordinator_pid, coordinator_available?: true}},
         coordinator_pid,
         _token,
         _binding
       ),
       do: :ok

  defp validate_checkpoint_hydration_begin(
         %{checkpoint_hydration: %{coordinator_available?: false, state: :blocked}},
         _coordinator_pid,
         _token,
         _binding
       ),
       do: :ok

  defp validate_checkpoint_hydration_begin(_state, _coordinator_pid, _token, _binding),
    do: {:error, :checkpoint_hydration_coordinator_mismatch}

  defp validate_checkpoint_hydration_finish(
         %{
           checkpoint_hydration: %{
             coordinator_pid: expected_coordinator_pid,
             coordinator_available?: true,
             token: expected_token,
             binding: expected_binding,
             state: :blocked
           }
         },
         coordinator_pid,
         token,
         binding
       ) do
    cond do
      coordinator_pid != expected_coordinator_pid ->
        {:error, :checkpoint_hydration_coordinator_mismatch}

      token != expected_token ->
        {:error, :checkpoint_hydration_token_mismatch}

      binding != expected_binding ->
        {:error, :checkpoint_hydration_binding_mismatch}

      true ->
        :ok
    end
  end

  defp validate_checkpoint_hydration_finish(_state, _coordinator_pid, _token, _binding),
    do: {:error, :checkpoint_hydration_not_blocked}

  defp install_checkpoint_hydration(state, coordinator_pid, token, binding) do
    state = clear_checkpoint_hydration_monitor(state)

    %{
      state
      | checkpoint_hydration: %{
          state: :blocked,
          coordinator_pid: coordinator_pid,
          coordinator_available?: true,
          token: token,
          binding: binding
        },
        checkpoint_hydration_monitor_ref: Process.monitor(coordinator_pid)
    }
  end

  defp clear_checkpoint_hydration_monitor(%{checkpoint_hydration_monitor_ref: nil} = state),
    do: state

  defp clear_checkpoint_hydration_monitor(%{checkpoint_hydration_monitor_ref: monitor_ref} = state) do
    Process.demonitor(monitor_ref, [:flush])
    %{state | checkpoint_hydration_monitor_ref: nil}
  end

  defp current_checkpoint_hydration_binding(state) do
    case Store.active(state.store) do
      {:ok, pointer} ->
        if pointer_matches_identity?(pointer, state.identity),
          do: {:ok, Map.take(pointer, @pointer_keys)},
          else: {:error, :checkpoint_hydration_binding_mismatch}

      :empty ->
        {:error, :checkpoint_hydration_binding_mismatch}

      {:error, _reason} ->
        {:error, :checkpoint_hydration_binding_unavailable}
    end
  end

  defp validate_checkpoint_hydration_binding(
         %{
           device_id: device_id,
           credential_epoch: credential_epoch,
           storage_epoch: storage_epoch,
           generation: generation,
           manifest_hash: manifest_hash
         } = binding
       )
       when map_size(binding) == 5 and is_binary(device_id) and byte_size(device_id) == 16 and
              device_id != @zero_identifier and is_integer(credential_epoch) and
              credential_epoch >= 0 and credential_epoch <= 0xFFFF_FFFF and
              is_binary(storage_epoch) and byte_size(storage_epoch) == 16 and
              storage_epoch != @zero_identifier and is_integer(generation) and generation > 0 and
              is_binary(manifest_hash) and byte_size(manifest_hash) == 32 do
    {:ok, Map.take(binding, @pointer_keys)}
  end

  defp validate_checkpoint_hydration_binding(_binding),
    do: {:error, :invalid_checkpoint_hydration_binding}

  defp checkpoint_hydration_binding_current?(%{checkpoint_hydration: nil}, _pointer), do: true

  defp checkpoint_hydration_binding_current?(
         %{checkpoint_hydration: %{state: :ready, binding: binding}},
         pointer
       ),
       do: binding == Map.take(pointer, @pointer_keys)

  defp checkpoint_hydration_binding_current?(_state, _pointer), do: false

  defp mark_checkpoint_hydration_stale(%{checkpoint_hydration: nil} = state), do: state

  defp mark_checkpoint_hydration_stale(%{checkpoint_hydration: hydration} = state) do
    %{state | checkpoint_hydration: Map.put(hydration, :state, :blocked)}
  end

  defp checkpoint_hydration_dependency(%{
         checkpoint_hydration: %{
           state: :ready,
           coordinator_available?: true,
           coordinator_pid: coordinator_pid
         }
       }),
       do: coordinator_pid

  defp checkpoint_hydration_dependency(_state), do: nil

  defp checkpoint_hydration_status(%{checkpoint_hydration: nil}), do: nil

  defp checkpoint_hydration_status(%{checkpoint_hydration: hydration}) do
    Map.take(hydration, [:state, :binding, :coordinator_available?])
  end

  defp active_pointer_status(store) do
    case Store.active(store) do
      {:ok, pointer} -> pointer
      :empty -> nil
      {:error, reason} -> {:error, reason}
    end
  end

  defp storage_or_protocol_error({:storage_failed, _reason} = error), do: error

  defp storage_or_protocol_error(reason)
       when reason in [
              :generation_hash_conflict,
              :stale_generation,
              :chunk_bounds,
              :chunk_conflict,
              :storage_epoch_mismatch,
              :secret_reference_mismatch
            ],
       do: reason

  defp storage_or_protocol_error({reason, _section})
       when reason in [:section_hash_mismatch, :transfer_incomplete],
       do: reason

  defp storage_or_protocol_error(reason), do: {:storage_failed, reason}

  defp storage_failure?({:write, _reason}), do: true
  defp storage_failure?({:read, _reason}), do: true
  defp storage_failure?({:storage_failed, _reason}), do: true
  defp storage_failure?(_reason), do: false

  defp secure_equal(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_equal(_left, _right), do: false
end
