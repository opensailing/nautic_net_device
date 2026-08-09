defmodule RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistry do
  @moduledoc false

  use GenServer

  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate.{
    AuthorityRegistry.Store,
    AuthorityRequest
  }

  @gate_module RacingOrg.Tracker.Pro.DesiredState.OperationalGate
  @call_timeout_ms 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def prepare_claim(
        term_key,
        authority_token,
        gate_pid,
        controller_reference,
        controller_pid,
        claim_token,
        claim_capability
      ) do
    prepare_claim(
      __MODULE__,
      term_key,
      authority_token,
      gate_pid,
      controller_reference,
      controller_pid,
      claim_token,
      claim_capability
    )
  end

  def prepare_claim(
        registry,
        term_key,
        authority_token,
        gate_pid,
        controller_reference,
        controller_pid,
        claim_token,
        claim_capability
      ) do
    gate_request(
      registry,
      gate_pid,
      {:prepare_claim, term_key, authority_token, gate_pid, controller_reference, controller_pid, claim_token,
       claim_capability}
    )
  end

  def confirm_claim(
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        claim_token
      ) do
    confirm_claim(
      __MODULE__,
      term_key,
      authority_token,
      gate_pid,
      gate_capability,
      claim_token
    )
  end

  def confirm_claim(
        registry,
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        claim_token
      ) do
    gate_request(
      registry,
      gate_pid,
      {:confirm_claim, term_key, authority_token, gate_pid, gate_capability, claim_token}
    )
  end

  def publish_lease(
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        controller_pid,
        lease
      ) do
    publish_lease(
      __MODULE__,
      term_key,
      authority_token,
      gate_pid,
      gate_capability,
      controller_pid,
      lease
    )
  end

  def publish_lease(
        registry,
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        controller_pid,
        lease
      ) do
    gate_request(
      registry,
      gate_pid,
      {:publish_lease, term_key, authority_token, gate_pid, gate_capability, controller_pid, lease}
    )
  end

  def activate_lease(
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        controller_pid,
        lease
      ) do
    activate_lease(
      __MODULE__,
      term_key,
      authority_token,
      gate_pid,
      gate_capability,
      controller_pid,
      lease
    )
  end

  def activate_lease(
        registry,
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        controller_pid,
        lease
      ) do
    gate_request(
      registry,
      gate_pid,
      {:activate_lease, term_key, authority_token, gate_pid, gate_capability, controller_pid, lease}
    )
  end

  def confirm_lease(
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        controller_pid,
        lease
      ) do
    confirm_lease(
      __MODULE__,
      term_key,
      authority_token,
      gate_pid,
      gate_capability,
      controller_pid,
      lease
    )
  end

  def confirm_lease(
        registry,
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        controller_pid,
        lease
      ) do
    gate_request(
      registry,
      gate_pid,
      {:confirm_lease, term_key, authority_token, gate_pid, gate_capability, controller_pid, lease}
    )
  end

  def close(term_key, authority_token, gate_pid, gate_capability) do
    close(__MODULE__, term_key, authority_token, gate_pid, gate_capability)
  end

  def close(registry, term_key, authority_token, gate_pid, gate_capability) do
    gate_request(
      registry,
      gate_pid,
      {:close, term_key, authority_token, gate_pid, gate_capability}
    )
  end

  def invalidate_observed(term_key, observed_lease) do
    invalidate_observed(__MODULE__, term_key, observed_lease)
  end

  def invalidate_observed(registry, term_key, observed_lease) do
    GenServer.call(
      registry,
      {:invalidate_observed, term_key, observed_lease},
      @call_timeout_ms
    )
  catch
    :exit, _reason -> {:error, :gate_authority_unavailable}
  end

  defdelegate current_lease?(term_key, lease), to: Store

  @impl true
  def init(opts) do
    registry_pid = self()
    registry_capability = make_ref()
    registration_token = new_registration_token(registry_capability)

    registration_capability =
      new_registration_capability(
        registry_pid,
        registry_capability,
        registration_token
      )

    claim_prepare_observer = Keyword.get(opts, :claim_prepare_observer)
    claim_confirm_observer = Keyword.get(opts, :claim_confirm_observer)

    case Process.whereis(Store) do
      store_pid when is_pid(store_pid) ->
        with {:ok, ^registry_capability} <-
               Store.register_registry(
                 store_pid,
                 self(),
                 registration_capability
               ),
             true <- Process.whereis(Store) == store_pid do
          {:ok,
           %{
             registry_capability: registry_capability,
             store_pid: store_pid,
             store_monitor_ref: Process.monitor(store_pid),
             claim_prepare_observer: claim_prepare_observer,
             claim_confirm_observer: claim_confirm_observer
           }}
        else
          {:error, reason} -> {:stop, reason}
          false -> {:stop, :gate_authority_unavailable}
        end

      nil ->
        {:stop, :gate_authority_unavailable}
    end
  end

  @impl true
  def handle_call(
        {:authority_request, gate_pid, request_token,
         {:prepare_claim, term_key, authority_token, gate_pid, controller_reference, controller_pid, claim_token,
          claim_capability} = operation},
        _from,
        state
      ) do
    with true <- AuthorityRequest.valid?(request_token, gate_pid, operation),
         true <- Process.alive?(gate_pid),
         {:ok, gate_capability} <-
           valid_claim_capability(
             claim_capability,
             gate_pid,
             term_key,
             authority_token,
             controller_reference,
             controller_pid,
             claim_token
           ),
         :ok <-
           Store.prepare_claim(
             state.store_pid,
             state.registry_capability,
             term_key,
             authority_token,
             gate_pid,
             gate_capability,
             controller_reference,
             controller_pid,
             claim_token
           ) do
      observe_claim_prepare(state.claim_prepare_observer, gate_pid)
      {:reply, :ok, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
      _invalid_claimant -> {:reply, {:error, :invalid_gate_claimant}, state}
    end
  end

  def handle_call(
        {:authority_request, gate_pid, request_token,
         {:confirm_claim, term_key, authority_token, gate_pid, gate_capability, claim_token} = operation},
        _from,
        state
      ) do
    if AuthorityRequest.valid?(request_token, gate_pid, operation) do
      result =
        Store.confirm_claim(
          state.store_pid,
          state.registry_capability,
          term_key,
          authority_token,
          gate_pid,
          gate_capability,
          claim_token
        )

      observe_claim_confirm(state.claim_confirm_observer, gate_pid, result)
      {:reply, result, state}
    else
      {:reply, {:error, :invalid_gate_claimant}, state}
    end
  end

  def handle_call(
        {:authority_request, gate_pid, request_token,
         {:publish_lease, term_key, authority_token, gate_pid, gate_capability, controller_pid, lease} = operation},
        _from,
        state
      ) do
    if AuthorityRequest.valid?(request_token, gate_pid, operation) do
      result =
        Store.prepare_lease(
          state.store_pid,
          state.registry_capability,
          term_key,
          authority_token,
          gate_pid,
          gate_capability,
          controller_pid,
          lease
        )

      {:reply, result, state}
    else
      {:reply, {:error, :gate_superseded}, state}
    end
  end

  def handle_call(
        {:authority_request, gate_pid, request_token,
         {:activate_lease, term_key, authority_token, gate_pid, gate_capability, controller_pid, lease} = operation},
        _from,
        state
      ) do
    if AuthorityRequest.valid?(request_token, gate_pid, operation) do
      result =
        Store.activate_lease(
          state.store_pid,
          state.registry_capability,
          term_key,
          authority_token,
          gate_pid,
          gate_capability,
          controller_pid,
          lease
        )

      {:reply, result, state}
    else
      {:reply, {:error, :gate_superseded}, state}
    end
  end

  def handle_call(
        {:authority_request, gate_pid, request_token,
         {:confirm_lease, term_key, authority_token, gate_pid, gate_capability, controller_pid, lease} = operation},
        _from,
        state
      ) do
    if AuthorityRequest.valid?(request_token, gate_pid, operation) do
      result =
        Store.confirm_lease(
          state.store_pid,
          state.registry_capability,
          term_key,
          authority_token,
          gate_pid,
          gate_capability,
          controller_pid,
          lease
        )

      {:reply, result, state}
    else
      {:reply, {:error, :gate_superseded}, state}
    end
  end

  def handle_call(
        {:authority_request, gate_pid, request_token,
         {:close, term_key, authority_token, gate_pid, gate_capability} = operation},
        _from,
        state
      ) do
    if AuthorityRequest.valid?(request_token, gate_pid, operation) do
      result =
        Store.close(
          state.store_pid,
          state.registry_capability,
          term_key,
          authority_token,
          gate_pid,
          gate_capability
        )

      {:reply, result, state}
    else
      {:reply, {:error, :gate_superseded}, state}
    end
  end

  def handle_call(
        {:prepare_claim, _term_key, _authority_token, _gate_pid, _controller_reference, _controller_pid, _claim_token,
         _claim_capability},
        _from,
        state
      ) do
    {:reply, {:error, :invalid_gate_claimant}, state}
  end

  def handle_call(
        {:confirm_claim, _term_key, _authority_token, _gate_pid, _gate_capability, _claim_token},
        _from,
        state
      ) do
    {:reply, {:error, :invalid_gate_claimant}, state}
  end

  def handle_call(
        {operation, _term_key, _authority_token, _gate_pid, _gate_capability, _controller_pid, _lease},
        _from,
        state
      )
      when operation in [:publish_lease, :activate_lease, :confirm_lease] do
    {:reply, {:error, :gate_superseded}, state}
  end

  def handle_call(
        {:close, _term_key, _authority_token, _gate_pid, _gate_capability},
        _from,
        state
      ) do
    {:reply, {:error, :gate_superseded}, state}
  end

  def handle_call({:invalidate_observed, term_key, observed_lease}, _from, state) do
    result =
      Store.invalidate_observed(
        state.store_pid,
        state.registry_capability,
        term_key,
        observed_lease
      )

    {:reply, result, state}
  end

  @impl true
  def handle_info(
        {:DOWN, monitor_ref, :process, store_pid, _reason},
        %{store_pid: store_pid, store_monitor_ref: monitor_ref} = state
      ) do
    {:stop, :gate_authority_unavailable, state}
  end

  defp observe_claim_prepare(nil, _gate_pid), do: :ok

  defp observe_claim_prepare(observer, gate_pid) when is_function(observer, 1) do
    observer.(gate_pid)
  end

  defp observe_claim_confirm(nil, _gate_pid, _result), do: :ok

  defp observe_claim_confirm(observer, gate_pid, {:ok, _controller_pid})
       when is_function(observer, 1) do
    observer.(gate_pid)
  end

  defp observe_claim_confirm(_observer, _gate_pid, _result), do: :ok

  defp valid_claim_capability(
         claim_capability,
         gate_pid,
         term_key,
         authority_token,
         controller_reference,
         controller_pid,
         claim_token
       )
       when is_function(claim_capability, 1) and is_pid(gate_pid) and
              is_reference(authority_token) and
              (is_pid(controller_pid) or is_nil(controller_pid)) and
              is_reference(claim_token) do
    challenge = make_ref()

    with true <- Process.alive?(gate_pid),
         {:module, @gate_module} <-
           :erlang.fun_info(claim_capability, :module),
         {:type, :local} <- :erlang.fun_info(claim_capability, :type),
         {@gate_module, :claim_capability, ^challenge, ^gate_pid, gate_capability, ^term_key, ^authority_token,
          ^controller_reference, ^controller_pid, ^claim_token}
         when is_reference(gate_capability) <- claim_capability.(challenge),
         true <- valid_claim_token?(claim_token, gate_pid),
         true <- Process.alive?(gate_pid) do
      {:ok, gate_capability}
    else
      _invalid_capability -> {:error, :invalid_gate_claimant}
    end
  rescue
    _exception -> {:error, :invalid_gate_claimant}
  catch
    _kind, _reason -> {:error, :invalid_gate_claimant}
  end

  defp valid_claim_capability(
         _claim_capability,
         _gate_pid,
         _term_key,
         _authority_token,
         _controller_reference,
         _controller_pid,
         _claim_token
       ),
       do: {:error, :invalid_gate_claimant}

  defp valid_claim_token?(claim_token, gate_pid) do
    :ets.info(claim_token, :owner) == gate_pid and
      :ets.info(claim_token, :protection) == :protected and
      :ets.first(claim_token) == :"$end_of_table" and
      :ets.info(claim_token, :owner) == gate_pid
  rescue
    ArgumentError -> false
  end

  defp new_registration_token(registry_capability) do
    registration_token = :ets.new(__MODULE__, [:set, :protected])
    true = :ets.insert_new(registration_token, {:registration, registry_capability})
    registration_token
  end

  defp new_registration_capability(
         registry_pid,
         registry_capability,
         registration_token
       ) do
    fn challenge ->
      {__MODULE__, :registry_capability, challenge, registry_pid, registry_capability, registration_token}
    end
  end

  defp gate_request(registry, gate_pid, operation) do
    AuthorityRequest.call(registry, gate_pid, operation, @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :gate_authority_unavailable}
  end
end
