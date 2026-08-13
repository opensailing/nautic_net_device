defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Executor do
  @moduledoc """
  The single durable writer for authenticated Desired State v1 command delivery.

  One serialized delivery path owns the whole lifecycle:

      classify -> persist intent -> run the effect -> persist the terminal
      outcome -> return the exact ACK

  Every step is fenced. Classification (`Commands.Ledger.classify/2`) enforces the
  device, credential epoch, storage epoch, command hash, command epoch/sequence,
  desired generation, manifest, expiry-at-admission, payload/type, operational
  gate, and capacity fences purely, and the durable store re-authorizes the exact
  plan through this module's `authorize/4` before writing anything. Nothing
  external runs until the intent is durable, and no ACK is returned until the
  terminal outcome is durable.

  ## Recovery

  A pending intent found at startup or on the next delivery is resolved by its
  own provider, never by elapsed time. The provider must prove the effect
  applied, prove it did not, or leave the intent pending. A proven
  non-application is rejected through the Store's non-application lease contract.
  An ambiguous intent stays pending and emits NO ACK, which also blocks every
  later command — that is the intended fail-closed behavior.

  ## Secrets

  Command payloads, results, and provider arguments are never logged. Only
  command identifiers, statuses, and reasons appear in telemetry or logs.
  """

  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.Commands.Ledger
  alias RacingOrg.Tracker.Pro.Commands.Ledger.{Registry, Store}
  alias RacingOrg.Tracker.Pro.DesiredState.{AtomicFile, Manager, OperationalGate, Runtime, RuntimeIdentity}

  @default_max_outcomes 64
  @default_max_result_bytes 262_144
  @default_identity_refresh_ms 250
  @u32_max 0xFFFF_FFFF
  @zero_identifier <<0::128>>
  @default_ledger_filename "commands.ledger"

  @type delivery :: map()
  @type ack :: map()

  @doc """
  Start the executor.

  Options:

    * `:path` — the durable ledger path. Derived from the desired-state storage
      root when omitted, so it is stable across reboots.
    * `:device_id` / `:credential_epoch` / `:storage_epoch` — the exact durable
      identity. Resolved from the verified authority at init when omitted.
    * `:providers` — `%{command_type => {module, context}}`. Defaults to the
      closed `Registry.recovery_verifiers/0` set.
    * `:desired_state` — 0-arity returning the active generation/manifest.
    * `:gate` — 0-arity returning `:closed | {:open, binding}`.
    * `:trusted_now_ms` — 0-arity returning `{:ok, ms}` or `:unavailable`.
    * `:identity_refresh_ms` — dynamic identity-source polling interval.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc "Standard supervised worker spec."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__) || __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 10_000
    }
  end

  @doc """
  Route one decoded, authenticated command delivery.

  Returns `{:ack, ack}` with the exact acknowledgement to encode and send, or
  `{:defer, reason}` when nothing is owed — a foreign device, an unusable clock,
  a capacity pause, or an ambiguous pending intent.
  """
  @spec deliver(GenServer.server(), delivery()) :: {:ack, ack()} | {:defer, term()}
  def deliver(server, delivery) when is_map(delivery) do
    GenServer.call(server, {:deliver, delivery}, :infinity)
  end

  def deliver(_server, _delivery), do: {:defer, :invalid_command_delivery}

  @doc "The exact durable identity this executor's ledger is scoped to, or nil while unbound."
  @spec identity(GenServer.server()) :: map() | nil
  def identity(server), do: GenServer.call(server, :identity)

  @doc "The canonical durable ledger path."
  @spec path(GenServer.server()) :: Path.t()
  def path(server), do: GenServer.call(server, :path)

  @doc false
  @spec default_path() :: Path.t()
  def default_path do
    RuntimeIdentity.storage_epoch_path()
    |> Path.dirname()
    |> Path.join(@default_ledger_filename)
  end

  # --- durable admission authority ---

  @doc """
  Re-classify the exact plan inside the store's path lock.

  The store calls this immediately before writing, so a generation, manifest,
  gate, or clock change between classification and persistence is caught with
  the durable snapshot as the authority rather than the caller's stale view.
  """
  @spec authorize(map(), term(), map(), map()) :: :ok | {:error, term()}
  def authorize(plan, snapshot, limits, context) when is_map(plan) do
    expected =
      case plan.action do
        :execute -> {:execute, plan}
        :terminal -> {:terminal, plan}
        _other -> :unauthorized
      end

    classification =
      Ledger.classify(plan.delivery, Map.merge(classification_context(context), %{snapshot: snapshot, limits: limits}))

    if classification == expected, do: :ok, else: {:error, :command_admission_not_authoritative}
  end

  def authorize(_plan, _snapshot, _limits, _context), do: {:error, :command_admission_not_authoritative}

  # --- server ---

  @impl true
  def init(opts) do
    with {:ok, path} <- canonical_ledger_path(configured_path(opts)),
         {:ok, providers} <- resolve_providers(opts),
         {:ok, identity_source} <- resolve_identity_source(opts) do
      state = %{
        path: path,
        store: nil,
        identity: nil,
        identity_source: identity_source,
        identity_refresh_ms: identity_refresh_ms(opts),
        identity_refresh_ref: nil,
        identity_refresh_token: nil,
        rebind_required?: false,
        reconcile_store?: false,
        opts: opts,
        providers: providers,
        desired_state: Keyword.get_lazy(opts, :desired_state, &default_desired_state/0),
        gate: Keyword.get_lazy(opts, :gate, &default_gate/0),
        trusted_now_ms: Keyword.get_lazy(opts, :trusted_now_ms, &default_clock/0)
      }

      case bind_identity(state) do
        {:ok, state} -> {:ok, state, {:continue, :recover_pending}}
        {:unbound, state} -> {:ok, schedule_identity_refresh(state)}
        {:rebind_required, state} -> {:ok, state}
        {:error, reason} -> {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:recover_pending, state) do
    {_resolution, state} = resolve_pending(state)
    {:noreply, schedule_identity_refresh(state)}
  end

  # Any pending intent is resolved before a new delivery is considered, because a
  # pending intent blocks every classification.
  #
  # A resolution that produced an ACK does not send it here: this call answers the
  # delivery in hand. When the delivery IS the recovered command, routing replays
  # its now-retained outcome as a duplicate ACK. When it is a different command,
  # the recovered ACK is not lost either — the server redelivers the unacked
  # command and the ledger replays its retained terminal bytes.
  @impl true
  def handle_call({:deliver, delivery}, _from, state) do
    case refresh_identity(state) do
      {:bound, state} ->
        case reconcile_store_if_needed(state) do
          {:ok, state} ->
            case resolve_pending(state) do
              {:none, state} -> route(delivery, state)
              {{:resolved, _ack}, state} -> route(delivery, state)
              {{:pending, reason}, state} -> {:reply, {:defer, reason}, state}
            end

          {:rebind_required, state} ->
            rebind_reply(state)

          {:error, reason, state} ->
            {:reply, {:defer, reason}, state}
        end

      {:unbound, state} ->
        {:reply, {:defer, :command_executor_unbound}, state}

      {:rebind_required, state} ->
        {:reply, {:defer, :command_executor_rebind_required}, state}

      {:bind_error, reason, state} ->
        {:stop, reason, {:defer, :command_executor_unbound}, state}
    end
  end

  def handle_call(:identity, _from, state), do: {:reply, state.identity, state}

  def handle_call(:path, _from, %{store: nil} = state) do
    {:reply, state.path, state}
  end

  def handle_call(:path, _from, state), do: {:reply, state.store.path, state}

  @impl true
  def handle_info({:refresh_identity, token}, %{identity_refresh_token: token} = state) do
    state = %{state | identity_refresh_ref: nil, identity_refresh_token: nil}
    previously_unbound? = is_nil(state.identity)

    case refresh_identity(state) do
      {:bound, state} when previously_unbound? ->
        {_resolution, state} = resolve_pending(state)
        {:noreply, schedule_identity_refresh(state)}

      {:bound, state} ->
        {:noreply, schedule_identity_refresh(state)}

      {:unbound, state} ->
        {:noreply, schedule_identity_refresh(state)}

      {:rebind_required, state} ->
        {:noreply, state}

      {:bind_error, reason, state} ->
        {:stop, reason, state}
    end
  end

  def handle_info({:refresh_identity, _stale_token}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status), do: redact(status)

  # --- routing ---

  defp route(delivery, state) do
    case Ledger.classify(delivery, context(state)) do
      {:execute, plan} -> execute(plan, state)
      {:terminal, plan} -> record_terminal(plan, state)
      {:duplicate, ack} -> ack_or_rebind(ack, state)
      {:transient, ack} -> ack_or_rebind(ack, state)
      {:defer, reason} -> {:reply, {:defer, reason}, state}
    end
  end

  # Persist the intent FIRST. Only once the intent is durable may the external
  # effect run, so an interrupted effect is always recoverable.
  defp execute(plan, state) do
    case Store.begin_intent(state.store, plan) do
      {:ok, intent, store} ->
        state = %{state | store: store}

        case run_effect(intent, state) do
          {:ok, result, state} ->
            case verify_live_identity(state) do
              {:ok, state} -> complete(intent, result, state)
              {:rebind_required, state} -> rebind_reply(state)
            end

          {:rebind_required, state} ->
            rebind_reply(state)
        end

      {:error, {:command_ledger_durability_uncertain, _reason} = reason} ->
        log_refusal(:intent, plan.delivery, reason)
        reconcile_uncertain_delivery(plan.delivery, mark_store_reconciliation(state, reason))

      {:error, reason} ->
        log_refusal(:intent, plan.delivery, reason)
        {:reply, {:defer, reason}, state}
    end
  end

  # The effect ran (or provably did not). Persist the terminal outcome BEFORE the
  # ACK is returned, so a crash here replays the retained bytes rather than
  # re-running the effect.
  defp complete(intent, {:ok, result_term}, state) do
    case Store.complete_intent(state.store, encoded_result(intent, result_term)) do
      {:ok, ack, store} ->
        ack_or_rebind(ack, %{state | store: store})

      {:error, {:command_ledger_durability_uncertain, _reason} = reason} ->
        log_refusal(:outcome, intent, reason)
        reconcile_uncertain_delivery(intent, mark_store_reconciliation(state, reason))

      {:error, reason} ->
        # The effect already happened but its outcome is not durable, so the
        # intent stays pending for the recovery contract rather than being acked.
        log_refusal(:outcome, intent, reason)
        {:reply, {:defer, reason}, state}
    end
  end

  # A provably unstarted effect leaves the intent for the recovery contract, which
  # is the only path allowed to reject it.
  defp complete(intent, {:error, reason}, state) do
    log_refusal(:effect, intent, reason)
    resolve_failed_effect(intent, reason, state)
  end

  defp complete(intent, _invalid, state) do
    log_refusal(:effect, intent, :invalid_command_provider_return)
    resolve_failed_effect(intent, :invalid_command_provider_return, state)
  end

  defp resolve_failed_effect(_intent, reason, state) do
    {resolution, state} = resolve_pending(state)

    case resolution do
      {:resolved, ack} -> ack_or_rebind(ack, state)
      {:pending, pending_reason} -> {:reply, {:defer, pending_reason}, state}
      :none -> {:reply, {:defer, reason}, state}
    end
  end

  # Encode the provider's result within its admitted reservation. A provider that
  # produces something its own reservation cannot hold still APPLIED its effect,
  # so the command is recorded applied with a bounded, truthful substitute rather
  # than being rejected or retried. The substitute is a fixed small term, so this
  # cannot fail a second time.
  defp encoded_result(intent, result_term) do
    case Registry.encode_result(intent.command_type, result_term) do
      {:ok, result} ->
        result

      {:error, reason} ->
        log_refusal(:result, intent, reason)
        {:ok, substitute} = Registry.encode_result(intent.command_type, %{outcome: :applied})
        substitute
    end
  end

  defp record_terminal(plan, state) do
    case verify_live_identity(state) do
      {:ok, state} ->
        case Store.record_terminal(state.store, plan) do
          {:ok, ack, store} ->
            ack_or_rebind(ack, %{state | store: store})

          {:error, {:command_ledger_durability_uncertain, _reason} = reason} ->
            log_refusal(:terminal, plan.delivery, reason)
            reconcile_uncertain_delivery(plan.delivery, mark_store_reconciliation(state, reason))

          {:error, reason} ->
            log_refusal(:terminal, plan.delivery, reason)
            {:reply, {:defer, reason}, state}
        end

      {:rebind_required, state} ->
        rebind_reply(state)
    end
  end

  # --- pending intent recovery ---

  defp resolve_pending(state) do
    case Ledger.recover_pending(Store.snapshot(state.store)) do
      :none ->
        {:none, state}

      {:recover, intent} ->
        case with_live_identity(state, fn state -> invoke_provider(intent, :recover, state) end) do
          {:ok, recovery, state} -> finish_recovery(intent, recovery, state)
          {:rebind_required, state} -> {{:pending, :command_executor_rebind_required}, state}
        end
    end
  end

  defp finish_recovery(intent, recovery, state) do
    case verify_live_identity(state) do
      {:ok, state} -> resolve_recovery(intent, recovery, state)
      {:rebind_required, state} -> {{:pending, :command_executor_rebind_required}, state}
    end
  end

  defp resolve_recovery(intent, {:applied, result_term}, state),
    do: complete_recovered(intent, result_term, state)

  defp resolve_recovery(intent, {:not_applied, proof}, state),
    do: reject_recovered(intent, proof, state)

  defp resolve_recovery(_intent, :ambiguous, state),
    do: {{:pending, :ambiguous_command_recovery}, state}

  defp resolve_recovery(_intent, _invalid, state),
    do: {{:pending, :ambiguous_command_recovery}, state}

  defp complete_recovered(intent, result_term, state) do
    case Store.complete_intent(state.store, encoded_result(intent, result_term)) do
      {:ok, ack, store} ->
        {{:resolved, ack}, %{state | store: store}}

      {:error, {:command_ledger_durability_uncertain, _reason} = reason} ->
        log_refusal(:recovery_completion, intent, reason)
        reconcile_uncertain_recovery(intent, result_term, mark_store_reconciliation(state, reason))

      {:error, reason} ->
        log_refusal(:recovery_completion, intent, reason)
        {{:pending, reason}, state}
    end
  end

  defp reconcile_uncertain_recovery(intent, result_term, state) do
    case reconcile_store_if_needed(state) do
      {:ok, state} ->
        case Ledger.recover_pending(Store.snapshot(state.store)) do
          :none ->
            {:none, state}

          {:recover, current_intent} when current_intent.command_id == intent.command_id ->
            complete_recovered(current_intent, result_term, state)

          {:recover, _other_intent} ->
            {{:pending, :ambiguous_command_recovery}, state}
        end

      {:rebind_required, state} ->
        {{:pending, :command_executor_rebind_required}, state}

      {:error, reason, state} ->
        {{:pending, reason}, state}
    end
  end

  # Rejection uses the Store's closed non-application plan; the Store hands the
  # transition to this command type's provider lease.
  defp reject_recovered(intent, proof, state) when proof in [:effect_not_started, :effect_verified_absent] do
    plan = %{
      action: :reject,
      command_id: intent.command_id,
      command_hash: intent.command_hash,
      command_type: intent.command_type,
      proof: proof,
      reason: :operational_gate_closed
    }

    case Store.reject_intent(state.store, plan, before_transition: fn -> ensure_live_identity(state) end) do
      {:ok, ack, store} ->
        {{:resolved, ack}, %{state | store: store}}

      {:error, :command_executor_rebind_required} ->
        state = latch_rebind_required(state, :identity_drift)
        {{:pending, :command_executor_rebind_required}, state}

      {:error, {:command_ledger_durability_uncertain, _reason} = reason} ->
        log_refusal(:recovery_rejection, intent, reason)
        reconcile_uncertain_rejection(intent, mark_store_reconciliation(state, reason))

      {:error, reason} ->
        log_refusal(:recovery_rejection, intent, reason)
        {{:pending, reason}, state}
    end
  end

  defp reject_recovered(_intent, _proof, state), do: {{:pending, :ambiguous_command_recovery}, state}

  defp reconcile_uncertain_rejection(intent, state) do
    case reconcile_store_if_needed(state) do
      {:ok, state} ->
        case Ledger.recover_pending(Store.snapshot(state.store)) do
          :none ->
            {:none, state}

          {:recover, current_intent} when current_intent.command_id == intent.command_id ->
            {{:pending, :ambiguous_command_recovery}, state}

          {:recover, _other_intent} ->
            {{:pending, :ambiguous_command_recovery}, state}
        end

      {:rebind_required, state} ->
        {{:pending, :command_executor_rebind_required}, state}

      {:error, reason, state} ->
        {{:pending, reason}, state}
    end
  end

  # --- provider invocation ---

  defp run_effect(intent, state) do
    with_live_identity(state, fn state -> invoke_provider(intent, :execute, state) end)
  end

  defp with_live_identity(state, fun) do
    case verify_live_identity(state) do
      {:ok, state} -> {:ok, fun.(state), state}
      {:rebind_required, state} -> {:rebind_required, state}
    end
  end

  defp verify_live_identity(state) do
    case read_identity(state.identity_source) do
      {:ok, identity} when identity == state.identity -> {:ok, state}
      {:ok, _identity} -> {:rebind_required, latch_rebind_required(state, :identity_drift)}
      {:error, reason} -> {:rebind_required, latch_rebind_required(state, reason)}
    end
  end

  defp ensure_live_identity(state) do
    case read_identity(state.identity_source) do
      {:ok, identity} when identity == state.identity -> :ok
      {:ok, _identity} -> {:error, :command_executor_rebind_required}
      {:error, _reason} -> {:error, :command_executor_rebind_required}
    end
  end

  defp ack_or_rebind(ack, state) do
    case verify_live_identity(state) do
      {:ok, state} -> {:reply, {:ack, ack}, state}
      {:rebind_required, state} -> rebind_reply(state)
    end
  end

  defp rebind_reply(state),
    do: {:reply, {:defer, :command_executor_rebind_required}, state}

  defp reconcile_uncertain_delivery(delivery, state) do
    case reconcile_store_if_needed(state) do
      {:ok, state} ->
        case resolve_pending(state) do
          {:none, state} -> route(delivery, state)
          {{:resolved, _ack}, state} -> route(delivery, state)
          {{:pending, reason}, state} -> {:reply, {:defer, reason}, state}
        end

      {:rebind_required, state} ->
        rebind_reply(state)

      {:error, reason, state} ->
        {:reply, {:defer, reason}, state}
    end
  end

  defp invoke_provider(intent, function, state) do
    case Map.fetch(state.providers, intent.command_type) do
      {:ok, {module, context}} -> apply(module, function, [intent, context])
      :error -> provider_missing(function)
    end
  rescue
    _exception -> provider_failed(function)
  catch
    _kind, _reason -> provider_failed(function)
  end

  defp provider_missing(:execute), do: {:error, :missing_command_provider}
  defp provider_missing(:recover), do: :ambiguous

  defp provider_failed(:execute), do: {:error, :command_provider_failed}
  defp provider_failed(:recover), do: :ambiguous

  # --- classification context ---

  defp context(state) do
    Map.merge(classification_context(state), %{
      snapshot: Store.snapshot(state.store),
      limits: Store.limits(state.store)
    })
  end

  # The mutable half of the classification context, shared by the hot path and by
  # the store's re-authorization so both judge the same fences.
  defp classification_context(state) do
    {generation, manifest_hash} = active_desired_state(state)

    %{
      active_generation: generation,
      active_manifest_hash: manifest_hash,
      trusted_now_ms: trusted_now_ms(state),
      gate: gate(state),
      decode_payload: &Registry.decode_payload/1,
      resolve_type: &Registry.resolve_type/1
    }
  end

  defp active_desired_state(state) do
    case invoke(state.desired_state) do
      {:ok, %{generation: generation, manifest_hash: manifest_hash}} -> {generation, manifest_hash}
      %{generation: generation, manifest_hash: manifest_hash} -> {generation, manifest_hash}
      _unavailable -> {nil, nil}
    end
  end

  defp trusted_now_ms(state) do
    case invoke(state.trusted_now_ms) do
      {:ok, milliseconds} when is_integer(milliseconds) and milliseconds >= 0 -> milliseconds
      milliseconds when is_integer(milliseconds) and milliseconds >= 0 -> milliseconds
      _unavailable -> :unavailable
    end
  end

  defp gate(state) do
    case invoke(state.gate) do
      {:open, binding} when is_map(binding) -> {:open, binding}
      _closed -> :closed
    end
  end

  defp invoke(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _exception -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  defp invoke(_fun), do: :unavailable

  # --- init helpers ---

  defp resolve_identity_source(opts) do
    identity = %{
      device_id: Keyword.get(opts, :device_id),
      credential_epoch: Keyword.get(opts, :credential_epoch),
      storage_epoch: Keyword.get(opts, :storage_epoch)
    }

    configured_fields = Enum.count(Map.values(identity), &(not is_nil(&1)))

    case configured_fields do
      3 ->
        with {:ok, identity} <- validate_identity(identity) do
          {:ok, {:static, identity}}
        end

      0 ->
        provider = Keyword.get_lazy(opts, :identity, fn -> &Runtime.identity/0 end)

        if is_function(provider, 0) do
          {:ok, {:dynamic, provider}}
        else
          {:error, :no_verified_authority}
        end

      _partial ->
        {:error, :invalid_command_executor_identity}
    end
  end

  defp refresh_identity(%{rebind_required?: true} = state), do: {:rebind_required, state}

  defp refresh_identity(%{identity: nil} = state) do
    case bind_identity(state) do
      {:ok, state} ->
        {:bound, state}

      {:unbound, state} ->
        {:unbound, state}

      {:rebind_required, state} ->
        {:rebind_required, state}

      {:error, :command_ledger_identity_mismatch} ->
        {:rebind_required, latch_rebind_required(state, :command_ledger_identity_mismatch)}

      {:error, reason} ->
        {:bind_error, reason, state}
    end
  end

  defp refresh_identity(state) do
    case read_identity(state.identity_source) do
      {:ok, identity} when identity == state.identity ->
        {:bound, state}

      {:ok, _identity} ->
        {:rebind_required, latch_rebind_required(state, :identity_drift)}

      {:error, _reason} ->
        {:rebind_required, latch_rebind_required(state, :identity_unavailable)}
    end
  end

  defp reconcile_store_if_needed(%{reconcile_store?: false} = state), do: {:ok, state}

  defp reconcile_store_if_needed(state) do
    with {:ok, state} <- verify_live_identity(state) do
      case open_store(Keyword.put(state.opts, :canonical_path, state.path), state.identity, state.providers) do
        {:ok, store} ->
          case verify_live_identity(state) do
            {:ok, state} -> {:ok, %{state | store: store, reconcile_store?: false}}
            {:rebind_required, state} -> {:rebind_required, state}
          end

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:rebind_required, state} -> {:rebind_required, state}
    end
  end

  defp mark_store_reconciliation(state, {:command_ledger_durability_uncertain, _reason}),
    do: %{state | reconcile_store?: true}

  defp mark_store_reconciliation(state, _reason), do: state

  defp bind_identity(state) do
    case read_identity(state.identity_source) do
      {:ok, identity} ->
        case verify_configured_path(state) do
          :ok ->
            case open_store(Keyword.put(state.opts, :canonical_path, state.path), identity, state.providers) do
              {:ok, store} -> finish_bind(state, identity, store)
              {:error, reason} -> {:error, reason}
            end

          {:error, :command_executor_path_retargeted} ->
            {:rebind_required, latch_rebind_required(state, :command_executor_path_retargeted)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :no_verified_authority} ->
        {:unbound, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_configured_path(state) do
    case canonical_ledger_path(configured_path(state.opts)) do
      {:ok, path} when path == state.path -> :ok
      {:ok, _retargeted_path} -> {:error, :command_executor_path_retargeted}
      {:error, _reason} = error -> error
    end
  end

  defp finish_bind(%{identity_source: {:static, _identity}} = state, identity, store),
    do: {:ok, %{state | store: store, identity: identity}}

  defp finish_bind(state, identity, store) do
    case read_identity(state.identity_source) do
      {:ok, current} when current == identity ->
        {:ok, %{state | store: store, identity: identity}}

      {:ok, _current} ->
        {:rebind_required, latch_rebind_required(state, :identity_drift)}

      {:error, reason} ->
        {:rebind_required, latch_rebind_required(state, reason)}
    end
  end

  defp read_identity({:static, identity}), do: validate_identity(identity)

  defp read_identity({:dynamic, provider}) do
    case provider.() do
      {:ok, identity} when is_map(identity) ->
        validate_identity(identity)

      {:error, :no_verified_authority} ->
        {:error, :no_verified_authority}

      _invalid ->
        {:error, :invalid_command_executor_identity}
    end
  rescue
    _exception -> {:error, :command_executor_identity_source_failed}
  catch
    _kind, _reason -> {:error, :command_executor_identity_source_failed}
  end

  defp validate_identity(%{
         device_id: device_id,
         credential_epoch: credential_epoch,
         storage_epoch: storage_epoch
       })
       when is_binary(device_id) and byte_size(device_id) == 16 and device_id != @zero_identifier and
              is_integer(credential_epoch) and credential_epoch >= 0 and credential_epoch <= @u32_max and
              is_binary(storage_epoch) and byte_size(storage_epoch) == 16 and
              storage_epoch != @zero_identifier do
    {:ok,
     %{
       device_id: device_id,
       credential_epoch: credential_epoch,
       storage_epoch: storage_epoch
     }}
  end

  defp validate_identity(_identity), do: {:error, :invalid_command_executor_identity}

  defp latch_rebind_required(state, reason) do
    Logger.warning("[CommandExecutor] stopped accepting commands: #{inspect(reason)}")

    state
    |> cancel_identity_refresh()
    |> Map.put(:identity, nil)
    |> Map.put(:rebind_required?, true)
  end

  defp schedule_identity_refresh(%{identity_source: {:dynamic, _provider}} = state) do
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

  defp identity_refresh_ms(opts) do
    case Keyword.get(opts, :identity_refresh_ms, @default_identity_refresh_ms) do
      milliseconds when is_integer(milliseconds) and milliseconds > 0 -> milliseconds
      _invalid -> @default_identity_refresh_ms
    end
  end

  defp resolve_providers(opts) do
    providers = Keyword.get_lazy(opts, :providers, &Registry.recovery_verifiers/0)

    if is_map(providers) and providers != %{} and
         Enum.all?(providers, fn
           {type, {module, _context}} when is_atom(type) and is_atom(module) ->
             Code.ensure_loaded?(module) and function_exported?(module, :execute, 2) and
               function_exported?(module, :recover, 2) and
               function_exported?(module, :with_non_application_lease, 5)

           _other ->
             false
         end) do
      {:ok, providers}
    else
      {:error, :invalid_command_providers}
    end
  end

  defp open_store(opts, identity, providers) do
    Store.open(
      Keyword.get(opts, :canonical_path, configured_path(opts)),
      [
        device_id: identity.device_id,
        credential_epoch: identity.credential_epoch,
        storage_epoch: identity.storage_epoch,
        max_outcomes: Keyword.get(opts, :max_outcomes, @default_max_outcomes),
        max_result_bytes: Keyword.get(opts, :max_result_bytes, @default_max_result_bytes),
        admission_authority: {__MODULE__, admission_context(opts)},
        recovery_verifiers: providers
      ] ++ Keyword.take(opts, [:file_system, :fault_injector, :recovery_timeout_ms])
    )
  end

  # The store re-authorizes with the SAME collaborators the hot path reads, so a
  # fence cannot differ between classification and persistence.
  defp configured_path(opts), do: Keyword.get_lazy(opts, :path, &default_path/0)

  defp canonical_ledger_path(path) when is_binary(path) and path != "" do
    if AtomicFile.reserved_temporary_path?(path) do
      {:error, {:invalid_command_ledger_path, :reserved_atomic_temp_name}}
    else
      path
      |> Path.expand()
      |> resolve_path_symlinks(32)
      |> reject_reserved_canonical_path()
    end
  end

  defp canonical_ledger_path(_path), do: {:error, :invalid_command_ledger_path}

  defp reject_reserved_canonical_path({:ok, path}) do
    if AtomicFile.reserved_temporary_path?(path) do
      {:error, {:invalid_command_ledger_path, :reserved_atomic_temp_name}}
    else
      {:ok, path}
    end
  end

  defp reject_reserved_canonical_path({:error, _reason} = error), do: error

  defp resolve_path_symlinks(_path, 0), do: {:error, :command_ledger_symlink_limit}

  defp resolve_path_symlinks(path, remaining) do
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
          |> resolve_path_symlinks(remaining - 1)
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

  defp admission_context(opts) do
    %{
      desired_state: Keyword.get_lazy(opts, :desired_state, &default_desired_state/0),
      gate: Keyword.get_lazy(opts, :gate, &default_gate/0),
      trusted_now_ms: Keyword.get_lazy(opts, :trusted_now_ms, &default_clock/0)
    }
  end

  defp default_desired_state do
    fn ->
      case Manager.status(Manager) do
        %{active: %{generation: generation, manifest_hash: manifest_hash}} ->
          {:ok, %{generation: generation, manifest_hash: manifest_hash}}

        _unavailable ->
          :unavailable
      end
    end
  end

  defp default_gate, do: fn -> OperationalGate.status(OperationalGate) end

  # System time is the only clock that can judge a server-issued absolute expiry.
  # A device whose clock is not yet set reports the epoch, which would expire
  # every command, so an implausibly early clock is reported as unavailable and
  # the delivery defers instead.
  defp default_clock do
    fn ->
      case System.os_time(:millisecond) do
        milliseconds when is_integer(milliseconds) and milliseconds >= 1_600_000_000_000 -> {:ok, milliseconds}
        _untrusted -> :unavailable
      end
    end
  end

  # --- logging (never payloads, results, or secrets) ---

  defp log_refusal(stage, command, reason) do
    Logger.warning(
      "[CommandExecutor] #{stage} refused for command " <>
        "#{inspect(Base.encode16(command_id(command), case: :lower))}: #{inspect(reason)}"
    )
  end

  defp command_id(%{command_id: command_id}) when is_binary(command_id), do: command_id
  defp command_id(_command), do: <<>>

  # The state holds the durable snapshot (command payloads and result bytes) and
  # provider contexts, none of which may reach a crash report or `:sys` dump. Only
  # the ledger identity is safe to surface.
  defp redact(%{state: state} = status) when is_map(status) do
    %{status | state: redact_state(state)}
  end

  defp redact(status), do: status

  defp redact_state(%{store: _store, identity: identity} = state) do
    %{
      identity: identity,
      rebind_required?: Map.get(state, :rebind_required?, false),
      store: :redacted,
      providers: :redacted,
      collaborators: :redacted
    }
  end

  defp redact_state(_state), do: :redacted
end
