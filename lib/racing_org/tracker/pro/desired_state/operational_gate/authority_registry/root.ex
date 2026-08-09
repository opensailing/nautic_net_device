defmodule RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistry.Root do
  @moduledoc false

  use GenServer

  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRequest

  @store_module RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistry.Store
  @table __MODULE__
  @call_timeout_ms 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register_store(store_pid, registration_capability) do
    operation = {:register_store, store_pid, registration_capability}

    AuthorityRequest.call(__MODULE__, store_pid, operation, @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :gate_authority_unavailable}
  end

  def attests_store?(store_attestor, root_pid, store_pid, store_incarnation)
      when is_function(store_attestor, 1) and is_pid(root_pid) and
             is_pid(store_pid) and is_reference(store_incarnation) do
    challenge = make_ref()

    with {:module, __MODULE__} <- :erlang.fun_info(store_attestor, :module),
         {:type, :local} <- :erlang.fun_info(store_attestor, :type),
         {__MODULE__, :store_attestation, ^challenge, root_capability, ^root_pid, ^store_pid, ^store_incarnation, true}
         when is_reference(root_capability) <- store_attestor.(challenge) do
      true
    else
      _invalid_or_stale -> false
    end
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  def attests_store?(_store_attestor, _root_pid, _store_pid, _store_incarnation),
    do: false

  def store_attestation do
    root_pid = Process.whereis(__MODULE__)

    case :ets.lookup(@table, :store) do
      [{:store, store_pid, store_incarnation, store_attestor}]
      when is_pid(root_pid) and is_pid(store_pid) and
             is_reference(store_incarnation) and
             is_function(store_attestor, 1) ->
        if :ets.info(@table, :owner) == root_pid and
             :ets.info(@table, :protection) == :protected and
             Process.alive?(root_pid) and Process.alive?(store_pid) and
             Process.whereis(__MODULE__) == root_pid and
             :ets.info(@table, :owner) == root_pid and
             attests_store?(
               store_attestor,
               root_pid,
               store_pid,
               store_incarnation
             ) do
          {:ok, store_pid, store_incarnation, store_attestor}
        else
          {:error, :gate_authority_unavailable}
        end

      _missing_or_invalid ->
        {:error, :gate_authority_unavailable}
    end
  rescue
    ArgumentError -> {:error, :gate_authority_unavailable}
  end

  @impl true
  def init(_opts) do
    _table =
      :ets.new(@table, [
        :named_table,
        :protected,
        :set,
        read_concurrency: true
      ])

    {:ok,
     %{
       root_capability: make_ref(),
       store_pid: nil,
       store_capability: nil,
       store_incarnation: nil,
       store_attestor: nil,
       store_monitor_ref: nil
     }}
  end

  @impl true
  def handle_call(
        {:authority_request, store_pid, request_token,
         {:register_store, store_pid, registration_capability} = operation},
        _from,
        state
      ) do
    with true <- AuthorityRequest.valid?(request_token, store_pid, operation),
         {:ok, store_capability} <-
           validate_store_capability(registration_capability, store_pid),
         {:ok, state, store_incarnation, store_attestor} <-
           register_store(state, store_pid, store_capability) do
      {:reply, {:ok, store_capability, store_incarnation, store_attestor}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
      false -> {:reply, {:error, :invalid_authority_store}, state}
    end
  end

  def handle_call({:register_store, _store_pid, _registration_capability}, _from, state) do
    {:reply, {:error, :invalid_authority_store}, state}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :invalid_authority_store}, state}
  end

  @impl true
  def handle_info(
        {:DOWN, monitor_ref, :process, store_pid, _reason},
        %{store_pid: store_pid, store_monitor_ref: monitor_ref} = state
      ) do
    {:noreply, release_store(state)}
  end

  defp register_store(state, store_pid, store_capability) do
    cond do
      state.store_pid == store_pid and state.store_capability == store_capability and
        is_reference(state.store_incarnation) and
          is_function(state.store_attestor, 1) ->
        {:ok, state, state.store_incarnation, state.store_attestor}

      is_pid(state.store_pid) and Process.alive?(state.store_pid) ->
        {:error, :authority_store_in_use}

      true ->
        state = release_store(state)
        store_incarnation = make_ref()

        store_attestor =
          new_store_attestor(
            self(),
            state.root_capability,
            store_pid,
            store_incarnation
          )

        store_monitor_ref = Process.monitor(store_pid)

        true =
          :ets.insert(
            @table,
            {:store, store_pid, store_incarnation, store_attestor}
          )

        state = %{
          state
          | store_pid: store_pid,
            store_capability: store_capability,
            store_incarnation: store_incarnation,
            store_attestor: store_attestor,
            store_monitor_ref: store_monitor_ref
        }

        {:ok, state, store_incarnation, store_attestor}
    end
  end

  defp release_store(state) do
    if is_reference(state.store_monitor_ref) do
      Process.demonitor(state.store_monitor_ref, [:flush])
    end

    :ets.delete(@table, :store)

    %{
      state
      | store_pid: nil,
        store_capability: nil,
        store_incarnation: nil,
        store_attestor: nil,
        store_monitor_ref: nil
    }
  end

  defp store_binding_current?(root_pid, store_pid, store_incarnation)
       when is_pid(root_pid) and is_pid(store_pid) and
              is_reference(store_incarnation) do
    Process.whereis(__MODULE__) == root_pid and Process.alive?(root_pid) and
      Process.alive?(store_pid) and :ets.info(@table, :owner) == root_pid and
      :ets.info(@table, :protection) == :protected and
      match?(
        [{:store, ^store_pid, ^store_incarnation, store_attestor}]
        when is_function(store_attestor, 1),
        :ets.lookup(@table, :store)
      ) and
      Process.whereis(__MODULE__) == root_pid and Process.alive?(root_pid) and
      :ets.info(@table, :owner) == root_pid
  rescue
    ArgumentError -> false
  end

  defp store_binding_current?(_root_pid, _store_pid, _store_incarnation),
    do: false

  defp new_store_attestor(
         root_pid,
         root_capability,
         store_pid,
         store_incarnation
       ) do
    fn challenge ->
      {__MODULE__, :store_attestation, challenge, root_capability, root_pid, store_pid, store_incarnation,
       store_binding_current?(root_pid, store_pid, store_incarnation)}
    end
  end

  defp validate_store_capability(registration_capability, store_pid)
       when is_function(registration_capability, 1) and is_pid(store_pid) do
    challenge = make_ref()

    with {:module, @store_module} <-
           :erlang.fun_info(registration_capability, :module),
         {:type, :local} <- :erlang.fun_info(registration_capability, :type),
         {@store_module, :store_capability, ^challenge, ^store_pid, store_capability, registration_token}
         when is_reference(store_capability) and is_reference(registration_token) <-
           registration_capability.(challenge),
         true <-
           valid_registration_token?(
             registration_token,
             store_pid,
             store_capability
           ) do
      {:ok, store_capability}
    else
      _invalid_capability -> {:error, :invalid_authority_store}
    end
  rescue
    _exception -> {:error, :invalid_authority_store}
  catch
    _kind, _reason -> {:error, :invalid_authority_store}
  end

  defp validate_store_capability(_registration_capability, _store_pid),
    do: {:error, :invalid_authority_store}

  defp valid_registration_token?(registration_token, store_pid, store_capability) do
    Process.alive?(store_pid) and
      :ets.info(registration_token, :owner) == store_pid and
      :ets.info(registration_token, :protection) == :protected and
      :ets.lookup(registration_token, :registration) == [
        {:registration, store_capability}
      ] and
      :ets.info(registration_token, :owner) == store_pid and
      Process.alive?(store_pid)
  rescue
    ArgumentError -> false
  end
end
