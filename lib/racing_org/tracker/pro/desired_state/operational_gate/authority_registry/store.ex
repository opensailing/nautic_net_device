defmodule RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistry.Store do
  @moduledoc false

  use GenServer

  alias RacingOrg.Tracker.Pro.DesiredState.Manager
  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate

  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate.{
    AuthorityGuard,
    AuthorityRegistry,
    AuthorityRequest
  }

  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistry.Root

  @table __MODULE__
  @call_timeout_ms 100
  @default_term_key {OperationalGate, :state}
  @default_controller Manager

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register_registry(registry_pid, registration_capability) do
    register_registry(__MODULE__, registry_pid, registration_capability)
  end

  def register_registry(store, registry_pid, registration_capability) do
    operation = {:register_registry, registry_pid, registration_capability}

    AuthorityRequest.call(store, registry_pid, operation, @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :gate_authority_unavailable}
  end

  def prepare_claim(
        registry_capability,
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        controller_reference,
        controller_pid,
        claim_token
      ) do
    prepare_claim(
      __MODULE__,
      registry_capability,
      term_key,
      authority_token,
      gate_pid,
      gate_capability,
      controller_reference,
      controller_pid,
      claim_token
    )
  end

  def prepare_claim(
        store,
        registry_capability,
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        controller_reference,
        controller_pid,
        claim_token
      ) do
    registry_request(
      store,
      {:prepare_claim, registry_capability, term_key, authority_token, gate_pid, gate_capability, controller_reference,
       controller_pid, claim_token}
    )
  end

  def confirm_claim(
        registry_capability,
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        claim_token
      ) do
    confirm_claim(
      __MODULE__,
      registry_capability,
      term_key,
      authority_token,
      gate_pid,
      gate_capability,
      claim_token
    )
  end

  def confirm_claim(
        store,
        registry_capability,
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        claim_token
      ) do
    registry_request(
      store,
      {:confirm_claim, registry_capability, term_key, authority_token, gate_pid, gate_capability, claim_token}
    )
  end

  def prepare_lease(
        registry_capability,
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        controller_pid,
        lease
      ) do
    prepare_lease(
      __MODULE__,
      registry_capability,
      term_key,
      authority_token,
      gate_pid,
      gate_capability,
      controller_pid,
      lease
    )
  end

  def prepare_lease(
        store,
        registry_capability,
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        controller_pid,
        lease
      ) do
    registry_request(
      store,
      {:prepare_lease, registry_capability, term_key, authority_token, gate_pid, gate_capability, controller_pid, lease}
    )
  end

  def activate_lease(
        registry_capability,
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        controller_pid,
        lease
      ) do
    activate_lease(
      __MODULE__,
      registry_capability,
      term_key,
      authority_token,
      gate_pid,
      gate_capability,
      controller_pid,
      lease
    )
  end

  def activate_lease(
        store,
        registry_capability,
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        controller_pid,
        lease
      ) do
    registry_request(
      store,
      {:activate_lease, registry_capability, term_key, authority_token, gate_pid, gate_capability, controller_pid,
       lease}
    )
  end

  def confirm_lease(
        registry_capability,
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        controller_pid,
        lease
      ) do
    confirm_lease(
      __MODULE__,
      registry_capability,
      term_key,
      authority_token,
      gate_pid,
      gate_capability,
      controller_pid,
      lease
    )
  end

  def confirm_lease(
        store,
        registry_capability,
        term_key,
        authority_token,
        gate_pid,
        gate_capability,
        controller_pid,
        lease
      ) do
    registry_request(
      store,
      {:confirm_lease, registry_capability, term_key, authority_token, gate_pid, gate_capability, controller_pid, lease}
    )
  end

  def close(
        registry_capability,
        term_key,
        authority_token,
        gate_pid,
        gate_capability
      ) do
    close(
      __MODULE__,
      registry_capability,
      term_key,
      authority_token,
      gate_pid,
      gate_capability
    )
  end

  def close(
        store,
        registry_capability,
        term_key,
        authority_token,
        gate_pid,
        gate_capability
      ) do
    registry_request(
      store,
      {:close, registry_capability, term_key, authority_token, gate_pid, gate_capability}
    )
  end

  def invalidate_observed(registry_capability, term_key, observed_lease) do
    invalidate_observed(__MODULE__, registry_capability, term_key, observed_lease)
  end

  def invalidate_observed(store, registry_capability, term_key, observed_lease) do
    registry_request(
      store,
      {:invalidate_observed, registry_capability, term_key, observed_lease}
    )
  end

  def invalidate_observed(term_key, observed_lease) do
    case trusted_store_for_table() do
      {:ok, store_pid, _store_incarnation} ->
        call(store_pid, {:invalidate_observed_public, term_key, observed_lease})

      {:error, _reason} = error ->
        error
    end
  end

  def current_lease?(term_key, lease) do
    table_owner = authority_table_owner()
    store_pid = Process.whereis(__MODULE__)
    registry_pid = Process.whereis(AuthorityRegistry)

    current? =
      with true <- is_pid(table_owner) and table_owner == store_pid,
           true <- is_pid(registry_pid) and Process.alive?(registry_pid),
           :protected <- :ets.info(@table, :protection),
           [
             {^term_key, root_attestor, root_pid, store_incarnation, ^registry_pid, _authority_token, _gate_pid,
              _controller_reference, _controller_pid, ^lease}
           ] <- :ets.lookup(@table, term_key),
           true <-
             Root.attests_store?(
               root_attestor,
               root_pid,
               store_pid,
               store_incarnation
             ) do
        true
      else
        _not_current -> false
      end

    if current? do
      true
    else
      case trusted_store_for_table() do
        {:ok, trusted_store_pid, _store_incarnation} ->
          _result =
            call(
              trusted_store_pid,
              {:invalidate_observed_public, term_key, lease}
            )

        {:error, _reason} ->
          :ok
      end

      false
    end
  rescue
    ArgumentError -> false
  end

  @impl true
  def init(_opts) do
    store_pid = self()
    store_capability = make_ref()
    registration_token = new_registration_token(store_capability)

    registration_capability =
      new_registration_capability(
        store_pid,
        store_capability,
        registration_token
      )

    root_pid = Process.whereis(Root)

    with true <- is_pid(root_pid) and Process.alive?(root_pid),
         {:ok, ^store_capability, store_incarnation, root_attestor} <-
           Root.register_store(self(), registration_capability),
         true <- Process.whereis(Root) == root_pid,
         root_monitor_ref = Process.monitor(root_pid),
         true <-
           Root.attests_store?(
             root_attestor,
             root_pid,
             self(),
             store_incarnation
           ) do
      _table =
        :ets.new(@table, [
          :named_table,
          :protected,
          :set,
          read_concurrency: true
        ])

      {:ok,
       %{
         entries: %{},
         gate_monitors: %{},
         registry_pid: nil,
         registry_capability: nil,
         registry_monitor_ref: nil,
         root_pid: root_pid,
         root_monitor_ref: root_monitor_ref,
         root_attestor: root_attestor,
         store_incarnation: store_incarnation
       }}
    else
      {:error, reason} -> {:stop, reason}
      false -> {:stop, :gate_authority_unavailable}
    end
  end

  @impl true
  def handle_call(
        {:authority_request, registry_pid, request_token,
         {:register_registry, registry_pid, registration_capability} = operation},
        _from,
        state
      ) do
    with true <- AuthorityRequest.valid?(request_token, registry_pid, operation),
         true <- Process.alive?(registry_pid),
         {:ok, registry_capability} <-
           validate_registry_capability(registration_capability, registry_pid),
         {:ok, state} <-
           register_registry_principal(
             state,
             registry_pid,
             registry_capability
           ) do
      {:reply, {:ok, registry_capability}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
      false -> {:reply, {:error, :invalid_authority_registry}, state}
    end
  end

  def handle_call(
        {:authority_request, registry_pid, request_token,
         {:prepare_claim, registry_capability, term_key, authority_token, gate_pid, gate_capability,
          controller_reference, controller_pid, claim_token} = operation},
        _from,
        state
      ) do
    with true <- AuthorityRequest.valid?(request_token, registry_pid, operation),
         :ok <- authorize_registry(state, registry_pid, registry_capability),
         true <- Process.alive?(gate_pid),
         :ok <- validate_default_controller(term_key, controller_reference),
         :ok <- validate_claim_token(claim_token, gate_pid, :inactive),
         {:ok, entry, state} <-
           prepare_claim_entry(
             state,
             term_key,
             authority_token,
             gate_pid,
             gate_capability,
             controller_reference,
             controller_pid,
             claim_token
           ) do
      state = put_entry(state, term_key, entry)
      publish_entry(term_key, entry)
      {:reply, :ok, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
      false -> {:reply, {:error, :invalid_gate_claimant}, state}
    end
  end

  def handle_call(
        {:authority_request, registry_pid, request_token,
         {:confirm_claim, registry_capability, term_key, authority_token, gate_pid, gate_capability, claim_token} =
           operation},
        _from,
        state
      ) do
    with true <- AuthorityRequest.valid?(request_token, registry_pid, operation),
         :ok <- authorize_registry(state, registry_pid, registry_capability),
         {:ok, entry} <-
           fetch_gate_entry(
             state,
             term_key,
             authority_token,
             gate_pid,
             gate_capability
           ),
         true <- Process.alive?(gate_pid),
         :ok <- validate_claim_token(claim_token, gate_pid, :active),
         {:ok, controller_pid, confirmed_entry} <-
           confirm_gate_claim(entry, claim_token, state.registry_pid) do
      if confirmed_entry == entry do
        {:reply, {:ok, controller_pid}, state}
      else
        state = put_entry(state, term_key, confirmed_entry)
        publish_entry(term_key, confirmed_entry)
        {:reply, {:ok, controller_pid}, state}
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
      false -> {:reply, {:error, :invalid_gate_claimant}, state}
    end
  end

  def handle_call(
        {:authority_request, registry_pid, request_token,
         {:prepare_lease, registry_capability, term_key, authority_token, gate_pid, gate_capability, controller_pid,
          lease} = operation},
        _from,
        state
      ) do
    with true <- AuthorityRequest.valid?(request_token, registry_pid, operation),
         :ok <- authorize_registry(state, registry_pid, registry_capability),
         {:ok, entry} <-
           fetch_gate_entry(
             state,
             term_key,
             authority_token,
             gate_pid,
             gate_capability
           ),
         :ok <- validate_confirmed_gate_claim(entry),
         true <- Process.alive?(gate_pid),
         :ok <- validate_controller_handoff(entry.controller_pid, controller_pid),
         :ok <-
           validate_lease_authority(
             lease,
             authority_token,
             gate_pid,
             controller_pid,
             entry.controller_reference,
             :inactive
           ) do
      entry = %{
        entry
        | lease: :closed,
          prepared_lease: lease,
          prepared_controller_pid: controller_pid,
          registry_pid: state.registry_pid
      }

      state = put_entry(state, term_key, entry)
      publish_entry(term_key, entry)
      {:reply, :ok, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
      false -> {:reply, {:error, :gate_superseded}, state}
    end
  end

  def handle_call(
        {:authority_request, registry_pid, request_token,
         {:activate_lease, registry_capability, term_key, authority_token, gate_pid, gate_capability, controller_pid,
          lease} = operation},
        _from,
        state
      ) do
    with true <- AuthorityRequest.valid?(request_token, registry_pid, operation),
         :ok <- authorize_registry(state, registry_pid, registry_capability),
         {:ok, %{prepared_lease: ^lease, prepared_controller_pid: ^controller_pid} = entry} <-
           fetch_gate_entry(
             state,
             term_key,
             authority_token,
             gate_pid,
             gate_capability
           ),
         :ok <- validate_confirmed_gate_claim(entry),
         true <- Process.alive?(gate_pid),
         :ok <- validate_controller_handoff(entry.controller_pid, controller_pid),
         :ok <-
           validate_lease_authority(
             lease,
             authority_token,
             gate_pid,
             controller_pid,
             entry.controller_reference,
             :inactive
           ) do
      entry = %{entry | registry_pid: state.registry_pid, lease: lease}
      state = put_entry(state, term_key, entry)
      publish_entry(term_key, entry)
      {:reply, :ok, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
      false -> {:reply, {:error, :gate_superseded}, state}
    end
  end

  def handle_call(
        {:authority_request, registry_pid, request_token,
         {:confirm_lease, registry_capability, term_key, authority_token, gate_pid, gate_capability, controller_pid,
          lease} = operation},
        _from,
        state
      ) do
    with true <- AuthorityRequest.valid?(request_token, registry_pid, operation),
         :ok <- authorize_registry(state, registry_pid, registry_capability),
         {:ok,
          %{
            lease: ^lease,
            prepared_lease: ^lease,
            prepared_controller_pid: ^controller_pid
          } = entry} <-
           fetch_gate_entry(
             state,
             term_key,
             authority_token,
             gate_pid,
             gate_capability
           ),
         :ok <- validate_confirmed_gate_claim(entry),
         true <- Process.alive?(gate_pid),
         :ok <- validate_controller_handoff(entry.controller_pid, controller_pid),
         :ok <-
           validate_lease_authority(
             lease,
             authority_token,
             gate_pid,
             controller_pid,
             entry.controller_reference,
             :confirming
           ) do
      entry = %{
        entry
        | controller_pid: controller_pid,
          controller_pinned?: true,
          prepared_lease: nil,
          prepared_controller_pid: nil
      }

      state = put_entry(state, term_key, entry)
      publish_entry(term_key, entry)
      {:reply, :ok, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
      false -> {:reply, {:error, :gate_superseded}, state}
    end
  end

  def handle_call(
        {:authority_request, registry_pid, request_token,
         {:close, registry_capability, term_key, authority_token, gate_pid, gate_capability} = operation},
        _from,
        state
      ) do
    with true <- AuthorityRequest.valid?(request_token, registry_pid, operation),
         :ok <- authorize_registry(state, registry_pid, registry_capability),
         {:ok, entry} <-
           fetch_gate_entry(
             state,
             term_key,
             authority_token,
             gate_pid,
             gate_capability
           ),
         :ok <- validate_confirmed_gate_claim(entry) do
      entry = %{
        entry
        | prepared_lease: nil,
          prepared_controller_pid: nil,
          lease: :closed
      }

      state = put_entry(state, term_key, entry)
      publish_entry(term_key, entry)
      {:reply, :ok, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
      false -> {:reply, {:error, :gate_superseded}, state}
    end
  end

  def handle_call(
        {:invalidate_observed_public, term_key, observed_lease},
        _from,
        state
      ) do
    {reply, state} = invalidate_observed_entry(state, term_key, observed_lease)
    {:reply, reply, state}
  end

  def handle_call(
        {:authority_request, registry_pid, request_token,
         {:invalidate_observed, registry_capability, term_key, observed_lease} = operation},
        _from,
        state
      ) do
    with true <- AuthorityRequest.valid?(request_token, registry_pid, operation),
         :ok <- authorize_registry(state, registry_pid, registry_capability) do
      {reply, state} = invalidate_observed_entry(state, term_key, observed_lease)
      {:reply, reply, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
      false -> {:reply, {:error, :gate_authority_unavailable}, state}
    end
  end

  def handle_call(
        {:register_registry, _registry_pid, _registration_capability},
        _from,
        state
      ) do
    {:reply, {:error, :invalid_authority_registry}, state}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :gate_authority_unavailable}, state}
  end

  @impl true
  def handle_info(
        {:DOWN, monitor_ref, :process, root_pid, reason},
        %{root_pid: root_pid, root_monitor_ref: monitor_ref} = state
      ) do
    {:stop, {:authority_root_down, reason}, state}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, registry_pid, _reason},
        %{
          registry_pid: registry_pid,
          registry_monitor_ref: monitor_ref
        } = state
      ) do
    {:noreply, release_registry(state)}
  end

  def handle_info({:DOWN, monitor_ref, :process, gate_pid, _reason}, state) do
    case Map.pop(state.gate_monitors, monitor_ref) do
      {{term_key, authority_token, ^gate_pid}, gate_monitors} ->
        state = %{state | gate_monitors: gate_monitors}

        case Map.get(state.entries, term_key) do
          %{
            authority_token: ^authority_token,
            gate_pid: ^gate_pid,
            monitor_ref: ^monitor_ref
          } = entry ->
            if entry.controller_pinned? do
              entry = clear_gate_claim(entry)
              state = put_entry(state, term_key, entry)
              publish_entry(term_key, entry)
              {:noreply, state}
            else
              {:noreply, delete_entry(state, term_key)}
            end

          _replacement_or_missing ->
            {:noreply, state}
        end

      {nil, gate_monitors} ->
        {:noreply, %{state | gate_monitors: gate_monitors}}
    end
  end

  defp new_registration_token(store_capability) do
    registration_token = :ets.new(__MODULE__, [:set, :protected])
    true = :ets.insert_new(registration_token, {:registration, store_capability})
    registration_token
  end

  defp new_registration_capability(
         store_pid,
         store_capability,
         registration_token
       ) do
    fn challenge ->
      {__MODULE__, :store_capability, challenge, store_pid, store_capability, registration_token}
    end
  end

  defp register_registry_principal(
         state,
         registry_pid,
         registry_capability
       ) do
    cond do
      state.registry_pid == registry_pid and
          state.registry_capability == registry_capability ->
        {:ok, state}

      is_pid(state.registry_pid) and Process.alive?(state.registry_pid) ->
        {:error, :authority_registry_in_use}

      true ->
        state = release_registry(state)
        monitor_ref = Process.monitor(registry_pid)

        {:ok,
         %{
           state
           | registry_pid: registry_pid,
             registry_capability: registry_capability,
             registry_monitor_ref: monitor_ref
         }}
    end
  end

  defp release_registry(state) do
    if is_reference(state.registry_monitor_ref) do
      Process.demonitor(state.registry_monitor_ref, [:flush])
    end

    {entries, state} =
      Enum.reduce(state.entries, {%{}, state}, fn {term_key, entry}, {entries, state} ->
        state = remove_gate_monitor(state, entry.monitor_ref)

        if entry.controller_pinned? do
          entry = clear_gate_claim(entry)
          publish_entry(term_key, entry)
          {Map.put(entries, term_key, entry), state}
        else
          :ets.delete(@table, term_key)
          :persistent_term.put(term_key, :closed)
          {entries, state}
        end
      end)

    %{
      state
      | entries: entries,
        gate_monitors: %{},
        registry_pid: nil,
        registry_capability: nil,
        registry_monitor_ref: nil
    }
  end

  defp prepare_claim_entry(
         state,
         term_key,
         authority_token,
         gate_pid,
         gate_capability,
         controller_reference,
         controller_pid,
         claim_token
       ) do
    case Map.get(state.entries, term_key) do
      %{
        authority_token: ^authority_token,
        gate_pid: ^gate_pid,
        gate_capability: ^gate_capability,
        claim_token: ^claim_token,
        claim_controller_reference: ^controller_reference,
        claim_controller_pid: ^controller_pid
      } = entry ->
        {:ok, entry, state}

      %{gate_pid: current_gate_pid} = entry when is_pid(current_gate_pid) ->
        if Process.alive?(current_gate_pid) do
          {:error, :gate_authority_in_use}
        else
          prepare_claim_replacement(
            state,
            term_key,
            entry,
            authority_token,
            gate_pid,
            gate_capability,
            controller_reference,
            controller_pid,
            claim_token
          )
        end

      entry when is_map(entry) ->
        prepare_claim_replacement(
          state,
          term_key,
          entry,
          authority_token,
          gate_pid,
          gate_capability,
          controller_reference,
          controller_pid,
          claim_token
        )

      nil ->
        with :ok <- validate_controller_claim(nil, controller_pid) do
          prepare_gate_claim(
            state,
            term_key,
            %{
              controller_reference: nil,
              controller_pid: nil,
              controller_pinned?: false,
              monitor_ref: nil
            },
            authority_token,
            gate_pid,
            gate_capability,
            controller_reference,
            controller_pid,
            claim_token
          )
        end
    end
  end

  defp prepare_claim_replacement(
         state,
         term_key,
         entry,
         authority_token,
         gate_pid,
         gate_capability,
         controller_reference,
         controller_pid,
         claim_token
       ) do
    cond do
      entry.controller_pinned? and entry.controller_reference != controller_reference ->
        {:error, :gate_controller_mismatch}

      true ->
        with :ok <- validate_controller_claim(entry.controller_pid, controller_pid) do
          prepare_gate_claim(
            state,
            term_key,
            entry,
            authority_token,
            gate_pid,
            gate_capability,
            controller_reference,
            controller_pid,
            claim_token
          )
        end
    end
  end

  defp prepare_gate_claim(
         state,
         term_key,
         entry,
         authority_token,
         gate_pid,
         gate_capability,
         controller_reference,
         controller_pid,
         claim_token
       ) do
    state = remove_gate_monitor(state, entry.monitor_ref)
    monitor_ref = Process.monitor(gate_pid)

    entry =
      Map.merge(entry, %{
        authority_token: authority_token,
        gate_pid: gate_pid,
        gate_capability: gate_capability,
        claim_token: claim_token,
        confirmed_claim_token: nil,
        claim_controller_reference: controller_reference,
        claim_controller_pid: controller_pid,
        monitor_ref: monitor_ref,
        prepared_lease: nil,
        prepared_controller_pid: nil,
        registry_pid: state.registry_pid,
        root_attestor: state.root_attestor,
        root_pid: state.root_pid,
        store_incarnation: state.store_incarnation,
        lease: :closed
      })

    state = %{
      state
      | gate_monitors:
          Map.put(
            state.gate_monitors,
            monitor_ref,
            {term_key, authority_token, gate_pid}
          )
    }

    {:ok, entry, state}
  end

  defp clear_gate_claim(entry) do
    %{
      entry
      | authority_token: nil,
        gate_pid: nil,
        gate_capability: nil,
        claim_token: nil,
        confirmed_claim_token: nil,
        claim_controller_reference: nil,
        claim_controller_pid: nil,
        monitor_ref: nil,
        prepared_lease: nil,
        prepared_controller_pid: nil,
        registry_pid: nil,
        lease: :closed
    }
  end

  defp confirm_gate_claim(
         %{
           claim_token: claim_token,
           claim_controller_reference: controller_reference,
           claim_controller_pid: controller_pid
         } = entry,
         claim_token,
         registry_pid
       ) do
    with :ok <- validate_controller_claim(entry.controller_pid, controller_pid) do
      {:ok, controller_pid,
       %{
         entry
         | controller_reference: controller_reference,
           controller_pid: controller_pid,
           controller_pinned?: true,
           claim_token: nil,
           confirmed_claim_token: claim_token,
           claim_controller_reference: nil,
           claim_controller_pid: nil,
           registry_pid: registry_pid
       }}
    end
  end

  defp confirm_gate_claim(
         %{
           controller_pinned?: true,
           controller_pid: controller_pid,
           claim_token: nil,
           confirmed_claim_token: claim_token,
           claim_controller_reference: nil,
           claim_controller_pid: nil
         } = entry,
         claim_token,
         _registry_pid
       ) do
    {:ok, controller_pid, entry}
  end

  defp confirm_gate_claim(_entry, _claim_token, _registry_pid),
    do: {:error, :gate_superseded}

  defp fetch_gate_entry(
         state,
         term_key,
         authority_token,
         gate_pid,
         gate_capability
       ) do
    case Map.get(state.entries, term_key) do
      %{
        authority_token: ^authority_token,
        gate_pid: ^gate_pid,
        gate_capability: ^gate_capability
      } = entry ->
        {:ok, entry}

      _stale_or_untrusted ->
        {:error, :gate_superseded}
    end
  end

  defp validate_confirmed_gate_claim(%{
         controller_pinned?: true,
         claim_token: nil,
         claim_controller_reference: nil,
         claim_controller_pid: nil
       }),
       do: :ok

  defp validate_confirmed_gate_claim(_entry), do: {:error, :gate_superseded}

  defp authorize_registry(state, caller_pid, registry_capability) do
    if caller_pid == state.registry_pid and
         registry_capability == state.registry_capability and
         is_pid(state.registry_pid) and Process.alive?(state.registry_pid) do
      :ok
    else
      {:error, :gate_authority_unavailable}
    end
  end

  defp validate_registry_capability(registration_capability, registry_pid)
       when is_function(registration_capability, 1) and is_pid(registry_pid) do
    challenge = make_ref()

    with {:module, AuthorityRegistry} <-
           :erlang.fun_info(registration_capability, :module),
         {:type, :local} <- :erlang.fun_info(registration_capability, :type),
         {AuthorityRegistry, :registry_capability, ^challenge, ^registry_pid, registry_capability, registration_token}
         when is_reference(registry_capability) and is_reference(registration_token) <-
           registration_capability.(challenge),
         true <-
           valid_registry_registration_token?(
             registration_token,
             registry_pid,
             registry_capability
           ) do
      {:ok, registry_capability}
    else
      _invalid_capability -> {:error, :invalid_authority_registry}
    end
  rescue
    _exception -> {:error, :invalid_authority_registry}
  catch
    _kind, _reason -> {:error, :invalid_authority_registry}
  end

  defp validate_registry_capability(_registration_capability, _registry_pid),
    do: {:error, :invalid_authority_registry}

  defp valid_registry_registration_token?(
         registration_token,
         registry_pid,
         registry_capability
       ) do
    Process.alive?(registry_pid) and
      :ets.info(registration_token, :owner) == registry_pid and
      :ets.info(registration_token, :protection) == :protected and
      :ets.lookup(registration_token, :registration) == [
        {:registration, registry_capability}
      ] and
      :ets.info(registration_token, :owner) == registry_pid and
      Process.alive?(registry_pid)
  rescue
    ArgumentError -> false
  end

  defp validate_default_controller(@default_term_key, @default_controller), do: :ok

  defp validate_default_controller(@default_term_key, _controller_reference),
    do: {:error, :gate_controller_mismatch}

  defp validate_default_controller(_term_key, _controller_reference), do: :ok

  defp validate_controller_claim(nil, nil), do: :ok

  defp validate_controller_claim(nil, controller_pid) when is_pid(controller_pid) do
    if Process.alive?(controller_pid), do: :ok, else: {:error, :gate_not_controller}
  end

  defp validate_controller_claim(prior_controller_pid, controller_pid)
       when is_pid(prior_controller_pid) and is_pid(controller_pid) do
    if Process.alive?(controller_pid),
      do: validate_controller_handoff(prior_controller_pid, controller_pid),
      else: {:error, :gate_not_controller}
  end

  defp validate_controller_claim(_prior_controller_pid, _controller_pid),
    do: {:error, :gate_not_controller}

  defp validate_controller_handoff(nil, controller_pid) when is_pid(controller_pid) do
    if Process.alive?(controller_pid), do: :ok, else: {:error, :gate_not_controller}
  end

  defp validate_controller_handoff(controller_pid, controller_pid)
       when is_pid(controller_pid) do
    if Process.alive?(controller_pid), do: :ok, else: {:error, :gate_not_controller}
  end

  defp validate_controller_handoff(prior_controller_pid, controller_pid)
       when is_pid(prior_controller_pid) and is_pid(controller_pid) do
    if Process.alive?(prior_controller_pid),
      do: {:error, :gate_not_controller},
      else: :ok
  end

  defp validate_controller_handoff(_prior_controller_pid, _controller_pid),
    do: {:error, :gate_not_controller}

  defp validate_claim_token(claim_token, gate_pid, token_status)
       when is_reference(claim_token) do
    with ^gate_pid <- :ets.info(claim_token, :owner),
         :protected <- :ets.info(claim_token, :protection),
         true <- claim_token_status?(claim_token, token_status) do
      :ok
    else
      _invalid_token -> {:error, :invalid_gate_claimant}
    end
  rescue
    ArgumentError -> {:error, :invalid_gate_claimant}
  end

  defp validate_claim_token(_claim_token, _gate_pid, _token_status),
    do: {:error, :invalid_gate_claimant}

  defp claim_token_status?(claim_token, :inactive),
    do: :ets.first(claim_token) == :"$end_of_table"

  defp claim_token_status?(claim_token, :active),
    do: :ets.lookup(claim_token, :state) == [{:state, :active}]

  defp validate_lease_authority(
         {:open, authority_token, lease_token, _binding, [gate_pid, controller_pid | _lease_pids] = lease_pids,
          _authority_bindings, controller_reference, authority_guard_pid},
         authority_token,
         gate_pid,
         controller_pid,
         controller_reference,
         token_status
       )
       when is_reference(lease_token) and is_pid(authority_guard_pid) do
    with true <- authority_guard_pid in lease_pids,
         true <- AuthorityGuard.attested?(authority_guard_pid),
         true <- Process.alive?(authority_guard_pid) do
      validate_lease_token(lease_token, gate_pid, token_status)
    else
      false -> {:error, :gate_authority_changed}
    end
  end

  defp validate_lease_authority(
         _lease,
         _authority_token,
         _gate_pid,
         _controller_pid,
         _controller_reference,
         _token_status
       ),
       do: {:error, :gate_authority_changed}

  defp validate_lease_token(lease_token, gate_pid, token_status) do
    with ^gate_pid <- :ets.info(lease_token, :owner),
         :protected <- :ets.info(lease_token, :protection),
         true <- lease_token_status?(lease_token, token_status) do
      :ok
    else
      _invalid_token -> {:error, :gate_authority_changed}
    end
  rescue
    ArgumentError -> {:error, :gate_authority_changed}
  end

  defp lease_token_status?(lease_token, :inactive),
    do: :ets.first(lease_token) == :"$end_of_table"

  defp lease_token_status?(lease_token, :confirming),
    do: :ets.lookup(lease_token, :state) == [{:state, :confirming}]

  defp lease_token_status?(lease_token, :active),
    do: :ets.lookup(lease_token, :state) == [{:state, :active}]

  defp put_entry(state, term_key, entry) do
    %{state | entries: Map.put(state.entries, term_key, entry)}
  end

  defp delete_entry(state, term_key) do
    :ets.delete(@table, term_key)
    :persistent_term.put(term_key, :closed)
    %{state | entries: Map.delete(state.entries, term_key)}
  end

  defp remove_gate_monitor(state, nil), do: state

  defp remove_gate_monitor(state, monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    %{state | gate_monitors: Map.delete(state.gate_monitors, monitor_ref)}
  end

  defp publish_entry(term_key, %{lease: :closed} = entry) do
    :ets.insert(@table, entry_record(term_key, entry))

    if is_reference(entry.authority_token) and is_pid(entry.gate_pid) do
      :persistent_term.put(
        term_key,
        {:closed, entry.authority_token, entry.gate_pid, entry.controller_reference}
      )
    else
      :persistent_term.put(term_key, :closed)
    end
  end

  defp publish_entry(term_key, %{lease: lease} = entry) do
    :ets.insert(@table, entry_record(term_key, entry))
    :persistent_term.put(term_key, lease)
  end

  defp entry_record(term_key, entry) do
    {
      term_key,
      entry.root_attestor,
      entry.root_pid,
      entry.store_incarnation,
      entry.registry_pid,
      entry.authority_token,
      entry.gate_pid,
      entry.controller_reference,
      entry.controller_pid,
      entry.lease
    }
  end

  defp invalidate_observed_entry(state, term_key, observed_lease) do
    case Map.get(state.entries, term_key) do
      %{lease: ^observed_lease} = entry ->
        entry = %{entry | lease: :closed}
        state = put_entry(state, term_key, entry)
        publish_entry(term_key, entry)
        {:ok, state}

      entry when is_map(entry) ->
        publish_entry(term_key, entry)
        {:ok, state}

      nil ->
        :persistent_term.put(term_key, :closed)
        {:ok, state}
    end
  end

  defp trusted_store_for_table do
    root_pid = Process.whereis(Root)

    with {:ok, store_pid, store_incarnation, root_attestor} <-
           Root.store_attestation(),
         ^store_pid <- Process.whereis(__MODULE__),
         ^store_pid <- authority_table_owner(),
         :protected <- :ets.info(@table, :protection),
         true <-
           Root.attests_store?(
             root_attestor,
             root_pid,
             store_pid,
             store_incarnation
           ) do
      {:ok, store_pid, store_incarnation}
    else
      _untrusted_or_unavailable -> {:error, :gate_authority_unavailable}
    end
  rescue
    ArgumentError -> {:error, :gate_authority_unavailable}
  end

  defp authority_table_owner do
    case :ets.info(@table, :owner) do
      owner_pid when is_pid(owner_pid) -> owner_pid
      _missing_or_invalid -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp registry_request(store, operation) do
    AuthorityRequest.call(store, self(), operation, @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :gate_authority_unavailable}
  end

  defp call(server, message) do
    GenServer.call(server, message, @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :gate_authority_unavailable}
  end
end
