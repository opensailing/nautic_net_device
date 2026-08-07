defmodule RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner do
  @moduledoc """
  Supervised driver for receipt-based bootstrap and serial recovery.

  The durable authority and recovery transcript are owned by `BootstrapStateMachine`;
  this process only runs reconciliation and schedules bounded retries. It remains alive
  after an authority receipt is ready so channel/application integration can use its
  explicit lifecycle and authenticated legacy-enrollment callbacks.

  Legacy marker existence is never authority. During migration, only a structurally
  valid marker whose fingerprint matches the active signer remains temporarily
  connectable, and replacement authority is accepted only through the authenticated
  enrollment callback.
  """

  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.SecureTransport.Backoff
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateMachine
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateStore
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder

  @default_retry_ms 10_000
  @max_retry_ms 60_000
  @keystore_option_keys [:base_path, :file_system, :seed_generator, :fault_injector]

  @type server :: GenServer.server()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Transient child spec; abnormal crashes restart while normal shutdown remains terminal."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name) || __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient,
      shutdown: 5_000
    }
  end

  @doc "Run one synchronous receipt/state reconciliation pass for the supervised coordinator."
  @spec reconcile(keyword()) ::
          {:ready, BootstrapState.t()}
          | {:retry, BootstrapState.t(), atom()}
          | {:blocked, BootstrapState.t(), atom()}
          | {:stop, :not_configured}
  def reconcile(opts \\ []) do
    opts
    |> normalize_bootstrap_opts()
    |> BootstrapStateMachine.reconcile()
    |> normalize_reconcile_result()
  end

  @doc """
  Run one provisioning pass using the legacy public result shape.

  Existing callers continue to receive `{:ok, :already_registered}`, `{:ok, state}`,
  or `{:error, reason}` while the supervised process uses `reconcile/1` internally.
  """
  @spec provision(keyword()) ::
          {:ok, :already_registered | BootstrapState.t()} | {:error, atom()}
  def provision(opts \\ []) do
    cond do
      not trusted_server_configured?(opts) ->
        {:error, :not_configured}

      registered?(opts) ->
        {:ok, :already_registered}

      true ->
        case reconcile(opts) do
          {:ready, state} -> {:ok, state}
          {:retry, _state, reason} -> {:error, reason}
          {:blocked, _state, reason} -> {:error, reason}
          {:stop, :not_configured} -> {:error, :not_configured}
        end
    end
  end

  @doc "Return the last supervised state, or load the durable state before the first attempt."
  @spec current_state(server()) :: BootstrapState.t()
  def current_state(server \\ __MODULE__), do: GenServer.call(server, :current_state)

  @doc """
  Whether verified durable authority matches the active signer and current hardware.

  A plain key-store option list remains supported for v1 callers. Operational callers
  may pass full bootstrap options under `:keystore_opts`, `:state_store_opts`, and the
  hardware/provider test seams.
  """
  @spec registered?(keyword()) :: boolean()
  def registered?(opts \\ []) do
    opts
    |> normalize_bootstrap_opts()
    |> BootstrapStateMachine.authorized?()
  end

  @doc "Read the legacy marker for migration diagnostics; it is never authority by itself."
  @spec read_marker(keyword()) :: {:ok, map()} | {:error, term()}
  def read_marker(opts \\ []) do
    store_opts = opts |> normalize_bootstrap_opts() |> state_store_opts()

    case BootstrapStateStore.read_legacy_marker(store_opts) do
      {:ok, json} -> Jason.decode(json)
      {:error, :enoent} -> {:error, :not_registered}
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  @doc "Return the verified durable/session credential epoch used as the handshake downgrade floor."
  @spec credential_epoch(server()) :: {:ok, non_neg_integer()} | {:error, :no_verified_authority}
  def credential_epoch(server \\ __MODULE__), do: GenServer.call(server, :credential_epoch)

  @doc "Persist a signed-HELLO credential epoch as a monotonic high-water mark."
  @spec adopt_credential_epoch(non_neg_integer(), server()) ::
          {:ok, BootstrapState.t()} | {:error, atom()}
  def adopt_credential_epoch(epoch, server \\ __MODULE__),
    do: GenServer.call(server, {:adopt_credential_epoch, epoch})

  @doc "Callback for a successful secure-channel authentication."
  @spec authenticated(server()) :: {:ok, BootstrapState.t()} | {:error, atom()}
  def authenticated(server \\ __MODULE__), do: GenServer.call(server, :authenticated)

  @doc "Callback for the start of desired-state hydration."
  @spec hydrating(server()) :: {:ok, BootstrapState.t()} | {:error, atom()}
  def hydrating(server \\ __MODULE__), do: GenServer.call(server, :hydrating)

  @doc "Callback after one desired-state generation is fully effective."
  @spec effective(server()) :: {:ok, BootstrapState.t()} | {:error, atom()}
  def effective(server \\ __MODULE__), do: GenServer.call(server, :effective)

  @doc "Clear authenticated readiness after disconnect, topic close, or session eviction."
  @spec session_lost(server()) :: {:ok, BootstrapState.t()} | {:error, atom()}
  def session_lost(server \\ __MODULE__), do: GenServer.call(server, :session_lost)

  @doc "Build a PoP request for authenticated migration of a matching legacy identity."
  @spec legacy_enrollment_request(server()) :: {:ok, map()} | {:error, term()}
  def legacy_enrollment_request(server \\ __MODULE__),
    do: GenServer.call(server, :legacy_enrollment_request)

  @doc "Verify and persist the signed result of authenticated legacy enrollment."
  @spec accept_legacy_enrollment(term(), server()) ::
          {:ok, BootstrapState.t()} | {:error, term()}
  def accept_legacy_enrollment(response, server \\ __MODULE__),
    do: GenServer.call(server, {:accept_legacy_enrollment, response})

  @impl true
  def init(opts) do
    bootstrap_opts = normalize_bootstrap_opts(opts)

    state = %{
      opts: bootstrap_opts,
      retry_attempt: 0,
      bootstrap_state: load_initial_state(bootstrap_opts)
    }

    {:ok, state, {:continue, :attempt}}
  end

  @impl true
  def handle_continue(:attempt, state), do: attempt(state)

  @impl true
  def handle_info(:attempt, state), do: attempt(state)

  @impl true
  def handle_call(:current_state, _from, state), do: {:reply, state.bootstrap_state, state}

  def handle_call(:credential_epoch, _from, state) do
    {:reply, BootstrapState.credential_epoch(state.bootstrap_state), state}
  end

  def handle_call({:adopt_credential_epoch, epoch}, _from, state) do
    callback_transition(&BootstrapStateMachine.adopt_credential_epoch(epoch, &1), state)
  end

  def handle_call(:authenticated, _from, state) do
    callback_transition(&BootstrapStateMachine.mark_authenticated/1, state)
  end

  def handle_call(:hydrating, _from, state) do
    callback_transition(&BootstrapStateMachine.mark_hydrating/1, state)
  end

  def handle_call(:effective, _from, state) do
    callback_transition(&BootstrapStateMachine.mark_effective/1, state)
  end

  def handle_call(:session_lost, _from, state) do
    callback_transition(&BootstrapStateMachine.mark_session_lost/1, state)
  end

  def handle_call(:legacy_enrollment_request, _from, state) do
    result = BootstrapStateMachine.legacy_enrollment_request(state.opts)
    {:reply, result, refresh_state_after_callback(result, state)}
  end

  def handle_call({:accept_legacy_enrollment, response}, _from, state) do
    result = BootstrapStateMachine.accept_legacy_enrollment(response, state.opts)
    {:reply, result, refresh_state_after_callback(result, state)}
  end

  defp attempt(%{opts: opts} = state) do
    reconcile_fun =
      cond do
        is_function(opts[:reconcile_fun], 1) -> opts[:reconcile_fun]
        is_function(opts[:provision_fun], 1) -> opts[:provision_fun]
        true -> &reconcile/1
      end

    opts
    |> safe_reconcile(reconcile_fun)
    |> handle_reconcile_outcome(state)
  end

  defp handle_reconcile_outcome({:ready, %BootstrapState{} = bootstrap_state}, state) do
    bootstrap_state = fence_advanced_credential_epoch(bootstrap_state, state)

    {:noreply,
     %{
       state
       | bootstrap_state: bootstrap_state,
         retry_attempt: 0
     }}
  end

  defp handle_reconcile_outcome({outcome, %BootstrapState{} = bootstrap_state, reason}, state)
       when outcome in [:retry, :blocked] do
    schedule_retry_outcome(bootstrap_state, reason, state)
  end

  defp handle_reconcile_outcome({:stop, :not_configured}, state) do
    Logger.info("[BootProvisioner] trusted server identity is not configured")
    {:stop, :normal, state}
  end

  defp handle_reconcile_outcome(_invalid, state) do
    schedule_retry_outcome(state.bootstrap_state, :transport_unavailable, state)
  end

  defp schedule_retry_outcome(bootstrap_state, reason, state) do
    bootstrap_state = fence_advanced_credential_epoch(bootstrap_state, state)
    next_attempt = state.retry_attempt + 1
    delay = retry_delay(next_attempt, state.opts)

    Logger.info(
      "[BootProvisioner] bootstrap deferred reason=#{safe_reason(reason)} " <>
        "phase=#{bootstrap_state.phase} retry_ms=#{delay}"
    )

    schedule_retry(delay, state.opts)

    {:noreply,
     %{
       state
       | bootstrap_state: bootstrap_state,
         retry_attempt: next_attempt
     }}
  end

  defp callback_transition(fun, state) do
    result = state.opts |> fun.() |> fence_advanced_credential_epoch(state)
    {:reply, result, refresh_state_after_callback(result, state)}
  end

  defp fence_advanced_credential_epoch({:ok, %BootstrapState{} = next_state}, state) do
    {:ok, fence_advanced_credential_epoch(next_state, state)}
  end

  defp fence_advanced_credential_epoch(%BootstrapState{} = next_state, state) do
    with {:ok, next_epoch} <- BootstrapState.credential_epoch(next_state) do
      previous_epoch = credential_epoch_or_before_registration(state.bootstrap_state)
      fence_result = fence_session_holder(state.opts, next_epoch)

      if next_epoch > previous_epoch or match?({:ok, _generation, :evicted}, fence_result) do
        clear_readiness_after_epoch_advance(next_state, state.opts)
      else
        next_state
      end
    else
      _unavailable -> next_state
    end
  end

  defp fence_advanced_credential_epoch(result, _state), do: result

  defp fence_session_holder(opts, credential_epoch) do
    holder = Keyword.get(opts, :session_holder, SessionHolder)
    SessionHolder.fence_for_credential_epoch(holder, credential_epoch)
  rescue
    _exception -> {:error, :session_holder_unavailable}
  catch
    :exit, _reason -> {:error, :session_holder_unavailable}
  end

  defp clear_readiness_after_epoch_advance(next_state, opts) do
    case BootstrapStateMachine.mark_session_lost(next_state, opts) do
      {:ok, %BootstrapState{} = demoted} -> demoted
      {:error, _reason} -> next_state
    end
  end

  defp credential_epoch_or_before_registration(%BootstrapState{} = state) do
    case BootstrapState.credential_epoch(state) do
      {:ok, epoch} -> epoch
      {:error, :no_verified_authority} -> -1
    end
  end

  defp refresh_state_after_callback({:ok, %BootstrapState{} = bootstrap_state}, state) do
    %{state | bootstrap_state: bootstrap_state}
  end

  defp refresh_state_after_callback(_result, state), do: state

  defp safe_reconcile(opts, fun) when is_function(fun, 1) do
    case fun.(opts) do
      {:ready, %BootstrapState{}} = ready ->
        ready

      {outcome, %BootstrapState{} = bootstrap_state, reason} when outcome in [:retry, :blocked] ->
        {outcome, bootstrap_state, safe_reason(reason)}

      {:stop, :not_configured} = stop ->
        stop

      {:ok, :already_registered} ->
        {:ready, load_initial_state(opts)}

      {:ok, %BootstrapState{} = bootstrap_state} ->
        {:ready, bootstrap_state}

      {:error, :not_configured} ->
        {:stop, :not_configured}

      {:error, reason} ->
        {:retry, load_initial_state(opts), safe_reason(reason)}

      _other ->
        {:retry, load_initial_state(opts), :transport_unavailable}
    end
  rescue
    _exception -> {:retry, load_initial_state(opts), :transport_unavailable}
  catch
    _kind, _reason -> {:retry, load_initial_state(opts), :transport_unavailable}
  end

  defp normalize_reconcile_result({:ok, %BootstrapState{} = state}), do: {:ready, state}

  defp normalize_reconcile_result({:retry, reason, %BootstrapState{} = state}),
    do: {:retry, state, safe_reason(reason)}

  defp normalize_reconcile_result({:blocked, reason, %BootstrapState{} = state}),
    do: {:blocked, state, safe_reason(reason)}

  defp normalize_reconcile_result({:error, :not_configured}), do: {:stop, :not_configured}

  defp normalize_reconcile_result(_other),
    do: {:retry, %BootstrapState{}, :transport_unavailable}

  defp schedule_retry(delay, opts) do
    case Keyword.get(opts, :scheduler) do
      fun when is_function(fun, 1) -> fun.(delay)
      _ -> Process.send_after(self(), :attempt, delay)
    end
  end

  defp retry_delay(attempt, opts) do
    base = max(Keyword.get(opts, :retry_ms, @default_retry_ms), 1)
    maximum = max(Keyword.get(opts, :max_retry_ms, @max_retry_ms), base)

    Backoff.delay(attempt - 1,
      base_ms: base,
      cap_ms: maximum,
      jitter: Keyword.get(opts, :retry_jitter, 0.25)
    )
  end

  defp load_initial_state(opts) do
    case BootstrapStateStore.load(state_store_opts(opts)) do
      {:ok, %BootstrapState{phase: phase}} when phase in [:authenticated, :hydrating, :effective] ->
        case BootstrapStateMachine.mark_session_lost(opts) do
          {:ok, demoted} -> demoted
          {:error, _reason} -> %BootstrapState{phase: :limbo, blocked_reason: :state_persistence_failed}
        end

      {:ok, state} ->
        state

      {:error, _reason} ->
        %BootstrapState{phase: :limbo, blocked_reason: :state_persistence_failed}
    end
  end

  defp trusted_server_configured?(opts) do
    opts = normalize_bootstrap_opts(opts)

    case Keyword.fetch(opts, :server_public_key) do
      {:ok, <<_::binary-size(32)>>} -> true
      {:ok, _invalid} -> false
      :error -> ServerIdentity.configured?()
    end
  end

  defp normalize_bootstrap_opts(opts) do
    if Enum.all?(Keyword.keys(opts), &(&1 in @keystore_option_keys)) do
      [
        keystore_opts: opts,
        state_store_opts: BootstrapStateStore.opts_from_keystore(opts)
      ]
    else
      keystore_opts = Keyword.get(opts, :keystore_opts, Keyword.take(opts, @keystore_option_keys))

      opts
      |> Keyword.put_new(:keystore_opts, keystore_opts)
      |> Keyword.put_new(:state_store_opts, BootstrapStateStore.opts_from_keystore(keystore_opts))
    end
  end

  defp state_store_opts(opts), do: Keyword.fetch!(opts, :state_store_opts)

  defp safe_reason(reason) do
    if reason in BootstrapState.allowed_reasons(), do: reason, else: :transport_unavailable
  end
end
