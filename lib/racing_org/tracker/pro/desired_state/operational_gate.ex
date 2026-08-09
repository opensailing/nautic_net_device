defmodule RacingOrg.Tracker.Pro.DesiredState.OperationalGate do
  @moduledoc """
  Fail-safe gate for externally observable tracker operation.

  Task #331 owns only this state and the activation lifecycle. Task #332 wires
  external hot paths to `operational?/3`. Reads fetch a `:persistent_term` lease and
  fail closed unless its gate, owner, authoritative dependencies, and all nine exact
  owner-reference bindings remain current. An observed authority mismatch revokes the
  lease permanently; reopening requires a new complete owner-bound lease.
  """

  use GenServer

  alias RacingOrg.Tracker.Pro.DesiredState.OwnerResolver

  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate.{
    AuthorityGuard,
    AuthorityRegistry,
    AuthorityRequest
  }

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  @default_term_key {__MODULE__, :state}
  @default_controller RacingOrg.Tracker.Pro.DesiredState.Manager
  @owner_resolution_timeout_ms 25
  @local_revocation_timeout_ms 25
  @authority_sections MapSet.new(Contract.sections())
  @zero_epoch <<0::128>>

  @type binding :: %{
          credential_epoch: non_neg_integer(),
          storage_epoch: binary(),
          generation: pos_integer(),
          manifest_hash: binary()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Process.whereis(AuthorityRegistry) do
      authority_registry_pid when is_pid(authority_registry_pid) ->
        opts =
          opts
          |> Keyword.put(:authority_registry_pid, authority_registry_pid)
          |> Keyword.put(:starter_pid, self())

        with {:ok, gate_pid} <- start_unlinked(opts),
             :ok <- confirm_start_link(gate_pid) do
          {:ok, gate_pid}
        end

      nil ->
        {:error, :gate_authority_unavailable}
    end
  end

  defp start_unlinked(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start(__MODULE__, opts)
      {:ok, name} -> GenServer.start(__MODULE__, opts, name: name)
      :error -> GenServer.start(__MODULE__, opts, name: __MODULE__)
    end
  end

  defp confirm_start_link(gate_pid) do
    starter_pid = self()
    operation = {:confirm_start_link, starter_pid}

    AuthorityRequest.call(gate_pid, starter_pid, operation, :infinity)
  catch
    :exit, reason -> {:error, reason}
  end

  @type owner_reference :: pid() | atom() | {:global, term()} | {:via, module(), term()}
  @type authority_bindings :: %{optional(atom()) => {owner_reference(), pid()}}

  @type open_error ::
          :invalid_gate_owner
          | :invalid_gate_dependencies
          | :invalid_gate_authority_bindings
          | :invalid_gate_binding
          | :gate_authority_changed
          | :gate_authority_unattested
          | :gate_dependency_unavailable
          | :gate_not_controller
          | :gate_superseded

  @doc "Open the gate only for an authenticated, complete exact-reference authority lease."
  @spec open_owned(
          GenServer.server(),
          reference(),
          pid(),
          [pid()],
          map(),
          authority_bindings()
        ) :: :ok | {:error, open_error()}
  def open_owned(
        server,
        controller_capability,
        owner_pid,
        dependency_pids,
        binding,
        authority_bindings
      )
      when is_reference(controller_capability) and is_pid(owner_pid) and
             is_list(dependency_pids) and is_map(authority_bindings) do
    if Enum.all?(dependency_pids, &is_pid/1) do
      operation =
        {:open_owned, controller_capability, owner_pid, dependency_pids, binding, authority_bindings}

      case AuthorityRequest.call(server, owner_pid, operation) do
        {:error, :invalid_authority_principal} -> {:error, :invalid_gate_owner}
        result -> result
      end
    else
      {:error, :invalid_gate_dependencies}
    end
  end

  def open_owned(
        _server,
        controller_capability,
        _owner_pid,
        _dependency_pids,
        _binding,
        _authority_bindings
      )
      when not is_reference(controller_capability),
      do: {:error, :gate_not_controller}

  def open_owned(
        _server,
        _controller_capability,
        owner_pid,
        _dependency_pids,
        _binding,
        _authority_bindings
      )
      when not is_pid(owner_pid),
      do: {:error, :invalid_gate_owner}

  def open_owned(
        _server,
        _controller_capability,
        _owner_pid,
        dependency_pids,
        _binding,
        _authority_bindings
      )
      when not is_list(dependency_pids),
      do: {:error, :invalid_gate_dependencies}

  def open_owned(
        _server,
        _controller_capability,
        _owner_pid,
        _dependency_pids,
        _binding,
        _authority_bindings
      ),
      do: {:error, :invalid_gate_authority_bindings}

  @doc "Prepare continuous exact-reference authority before applying a generation."
  @spec prepare_transition(GenServer.server(), reference(), pid(), authority_bindings()) ::
          {:ok, reference()} | {:error, open_error()}
  def prepare_transition(server, controller_capability, owner_pid, authority_bindings)
      when is_reference(controller_capability) and is_pid(owner_pid) and
             is_map(authority_bindings) do
    operation =
      {:prepare_transition, controller_capability, owner_pid, authority_bindings}

    case AuthorityRequest.call(server, owner_pid, operation) do
      {:error, :invalid_authority_principal} -> {:error, :invalid_gate_owner}
      result -> result
    end
  end

  def prepare_transition(_server, controller_capability, _owner_pid, _authority_bindings)
      when not is_reference(controller_capability),
      do: {:error, :gate_not_controller}

  def prepare_transition(_server, _controller_capability, owner_pid, _authority_bindings)
      when not is_pid(owner_pid),
      do: {:error, :invalid_gate_owner}

  def prepare_transition(_server, _controller_capability, _owner_pid, _authority_bindings),
    do: {:error, :invalid_gate_authority_bindings}

  @doc "Check that the exact prepared transition remains continuously authoritative."
  @spec transition_current(GenServer.server(), reference(), pid(), reference()) ::
          :ok | {:error, open_error()}
  def transition_current(server, controller_capability, owner_pid, transition_token)
      when is_reference(controller_capability) and is_pid(owner_pid) and
             is_reference(transition_token) do
    operation =
      {:transition_current, controller_capability, owner_pid, transition_token}

    case AuthorityRequest.call(server, owner_pid, operation) do
      {:error, :invalid_authority_principal} -> {:error, :invalid_gate_owner}
      result -> result
    end
  end

  def transition_current(_server, controller_capability, _owner_pid, _transition_token)
      when not is_reference(controller_capability),
      do: {:error, :gate_not_controller}

  def transition_current(_server, _controller_capability, owner_pid, _transition_token)
      when not is_pid(owner_pid),
      do: {:error, :invalid_gate_owner}

  def transition_current(_server, _controller_capability, _owner_pid, _transition_token),
    do: {:error, :gate_authority_changed}

  @doc "Publish a lease by adopting the exact guard created for a prepared transition."
  @spec open_prepared(
          GenServer.server(),
          reference(),
          pid(),
          reference(),
          [pid()],
          map()
        ) :: :ok | {:error, open_error()}
  def open_prepared(
        server,
        controller_capability,
        owner_pid,
        transition_token,
        dependency_pids,
        binding
      )
      when is_reference(controller_capability) and is_pid(owner_pid) and
             is_reference(transition_token) and is_list(dependency_pids) do
    if Enum.all?(dependency_pids, &is_pid/1) do
      operation =
        {:open_prepared, controller_capability, owner_pid, transition_token, dependency_pids, binding}

      case AuthorityRequest.call(server, owner_pid, operation) do
        {:error, :invalid_authority_principal} -> {:error, :invalid_gate_owner}
        result -> result
      end
    else
      {:error, :invalid_gate_dependencies}
    end
  end

  def open_prepared(
        _server,
        controller_capability,
        _owner_pid,
        _transition_token,
        _dependency_pids,
        _binding
      )
      when not is_reference(controller_capability),
      do: {:error, :gate_not_controller}

  def open_prepared(
        _server,
        _controller_capability,
        owner_pid,
        _transition_token,
        _dependency_pids,
        _binding
      )
      when not is_pid(owner_pid),
      do: {:error, :invalid_gate_owner}

  def open_prepared(
        _server,
        _controller_capability,
        _owner_pid,
        _transition_token,
        dependency_pids,
        _binding
      )
      when not is_list(dependency_pids),
      do: {:error, :invalid_gate_dependencies}

  def open_prepared(
        _server,
        _controller_capability,
        _owner_pid,
        _transition_token,
        _dependency_pids,
        _binding
      ),
      do: {:error, :gate_authority_changed}

  @spec close(GenServer.server()) :: :ok
  def close(server \\ __MODULE__), do: GenServer.call(server, :close)

  @spec status(GenServer.server()) :: :closed | {:open, binding()}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Cheap hot-path read for the default or explicitly supplied persistent-term key."
  @spec open?(term()) :: boolean()
  def open?(term_key \\ @default_term_key) do
    case :persistent_term.get(term_key, :closed) do
      {:open, _authority_token, _lease_token, _binding, _lease_pids, _authority_bindings, _controller_reference,
       _authority_guard_pid} = lease ->
        read_current_lease(term_key, lease)

      {:open, _legacy_authority_token, _legacy_lease_token, _binding, _lease_pids, _authority_bindings,
       _controller_reference} = legacy_lease ->
        invalidate_observed_lease(term_key, legacy_lease)
        false

      {:open, _legacy_authority_token, _legacy_lease_token, _binding, _lease_pids, _authority_bindings} = legacy_lease ->
        invalidate_observed_lease(term_key, legacy_lease)
        false

      {:open, _legacy_token, _binding, _lease_pids, _authority_bindings} = legacy_lease ->
        invalidate_observed_lease(term_key, legacy_lease)
        false

      {:open, _legacy_token, _binding, _lease_pids} = legacy_lease ->
        invalidate_observed_lease(term_key, legacy_lease)
        false

      _other ->
        false
    end
  end

  @doc "True only for the exact credential and storage incarnation currently open."
  @spec operational?(non_neg_integer(), binary(), term()) :: boolean()
  def operational?(credential_epoch, storage_epoch, term_key \\ @default_term_key) do
    case :persistent_term.get(term_key, :closed) do
      {:open, _authority_token, _lease_token, %{credential_epoch: ^credential_epoch, storage_epoch: ^storage_epoch},
       _lease_pids, _authority_bindings, _controller_reference, _authority_guard_pid} = lease ->
        read_current_lease(term_key, lease)

      {:open, _legacy_authority_token, _legacy_lease_token, _binding, _lease_pids, _authority_bindings,
       _controller_reference} = legacy_lease ->
        invalidate_observed_lease(term_key, legacy_lease)
        false

      {:open, _legacy_authority_token, _legacy_lease_token, _binding, _lease_pids, _authority_bindings} = legacy_lease ->
        invalidate_observed_lease(term_key, legacy_lease)
        false

      {:open, _legacy_token, _binding, _lease_pids, _authority_bindings} = legacy_lease ->
        invalidate_observed_lease(term_key, legacy_lease)
        false

      {:open, _legacy_token, _binding, _lease_pids} = legacy_lease ->
        invalidate_observed_lease(term_key, legacy_lease)
        false

      _other ->
        false
    end
  end

  @impl true
  def init(opts) do
    term_key = Keyword.get(opts, :term_key, @default_term_key)
    controller_reference = Keyword.get(opts, :controller, @default_controller)
    controller_capability = Keyword.get_lazy(opts, :controller_capability, &make_ref/0)
    authority_registry_pid = Keyword.fetch!(opts, :authority_registry_pid)
    authority_capability = make_ref()
    starter_pid = Keyword.fetch!(opts, :starter_pid)
    starter_monitor_ref = Process.monitor(starter_pid)
    authority_token = make_ref()
    gate_pid = self()

    if valid_owner_reference?(controller_reference) do
      with {:ok, resolved_controller_pid} <-
             resolve_initial_controller_pid(controller_reference),
           claim_token = new_claim_token(),
           claim_capability =
             new_claim_capability(
               gate_pid,
               authority_capability,
               term_key,
               authority_token,
               controller_reference,
               resolved_controller_pid,
               claim_token
             ),
           :ok <-
             AuthorityRegistry.prepare_claim(
               authority_registry_pid,
               term_key,
               authority_token,
               gate_pid,
               controller_reference,
               resolved_controller_pid,
               claim_token,
               claim_capability
             ),
           :ok <- activate_claim_token(claim_token),
           {:ok, controller_pid} <-
             AuthorityRegistry.confirm_claim(
               authority_registry_pid,
               term_key,
               authority_token,
               gate_pid,
               authority_capability,
               claim_token
             ) do
        true = :ets.delete(claim_token)
        authority_registry_monitor_ref = Process.monitor(authority_registry_pid)

        {:ok,
         %{
           term_key: term_key,
           starter_pid: starter_pid,
           starter_monitor_ref: starter_monitor_ref,
           confirmed_starter_pid: nil,
           authority_token: authority_token,
           authority_registry_pid: authority_registry_pid,
           authority_registry_monitor_ref: authority_registry_monitor_ref,
           authority_capability: authority_capability,
           controller_reference: controller_reference,
           controller_pid: controller_pid,
           controller_capability: controller_capability,
           transition_token: nil,
           transition_operation: nil,
           transition_guard: nil,
           lease_token: nil,
           lease: nil,
           open_operation: nil,
           authority_guard_pid: nil,
           status: :closed,
           owner_pid: nil,
           dependency_pids: [],
           authority_bindings: %{},
           monitor_refs: %{}
         }}
      else
        {:error, reason} -> {:stop, reason}
      end
    else
      {:stop, :invalid_gate_controller}
    end
  end

  @impl true
  def handle_call(
        {:authority_request, starter_pid, request_token, {:confirm_start_link, starter_pid} = operation},
        _from,
        %{
          starter_pid: starter_pid,
          starter_monitor_ref: starter_monitor_ref
        } = state
      ) do
    if AuthorityRequest.valid?(request_token, starter_pid, operation) do
      Process.link(starter_pid)
      Process.demonitor(starter_monitor_ref, [:flush])

      {:reply, :ok,
       %{
         state
         | starter_pid: nil,
           starter_monitor_ref: nil,
           confirmed_starter_pid: starter_pid
       }}
    else
      {:reply, {:error, :invalid_gate_starter}, state}
    end
  end

  def handle_call(
        {:authority_request, starter_pid, request_token, {:confirm_start_link, starter_pid} = operation},
        _from,
        %{confirmed_starter_pid: starter_pid} = state
      ) do
    if AuthorityRequest.valid?(request_token, starter_pid, operation),
      do: {:reply, :ok, state},
      else: {:reply, {:error, :invalid_gate_starter}, state}
  end

  def handle_call(
        {:authority_request, _starter_pid, _request_token, {:confirm_start_link, _presented_starter_pid}},
        _from,
        state
      ) do
    {:reply, {:error, :invalid_gate_starter}, state}
  end

  def handle_call(_message, _from, %{starter_pid: starter_pid} = state)
      when is_pid(starter_pid) do
    {:reply, {:error, :gate_starting}, state}
  end

  def handle_call(
        {:authority_request, owner_pid, request_token,
         {:prepare_transition, controller_capability, owner_pid, authority_bindings} = operation},
        _from,
        state
      ) do
    with true <- AuthorityRequest.valid?(request_token, owner_pid, operation),
         :ok <-
           authorize_open(
             state,
             controller_capability,
             owner_pid,
             owner_pid,
             authority_bindings
           ) do
      if exact_transition_current?(state, operation) do
        {:reply, {:ok, state.transition_token}, state}
      else
        prepare_transition_for_owner(state, owner_pid, authority_bindings, operation)
      end
    else
      false -> {:reply, {:error, :gate_not_controller}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(
        {:authority_request, owner_pid, request_token,
         {:transition_current, controller_capability, owner_pid, transition_token} = operation},
        _from,
        state
      ) do
    with true <- AuthorityRequest.valid?(request_token, owner_pid, operation),
         :ok <-
           authorize_open(
             state,
             controller_capability,
             owner_pid,
             owner_pid,
             state.authority_bindings
           ),
         :ok <- prepared_transition_status(state, owner_pid, transition_token) do
      {:reply, :ok, state}
    else
      false -> {:reply, {:error, :gate_not_controller}, state}
      {:error, :gate_not_controller} = error -> {:reply, error, state}
      {:error, :invalid_gate_owner} = error -> {:reply, error, state}
      {:error, _reason} -> {:reply, {:error, :gate_authority_changed}, close_state(state)}
    end
  end

  def handle_call(
        {:authority_request, owner_pid, request_token,
         {:open_prepared, controller_capability, owner_pid, transition_token, dependency_pids, binding} = operation},
        _from,
        state
      ) do
    with true <- AuthorityRequest.valid?(request_token, owner_pid, operation),
         :ok <-
           authorize_open(
             state,
             controller_capability,
             owner_pid,
             owner_pid,
             state.authority_bindings
           ) do
      cond do
        exact_open_current?(state, operation) ->
          {:reply, :ok, state}

        true ->
          case prepared_transition_status(state, owner_pid, transition_token) do
            :ok ->
              open_prepared_for_owner(
                state,
                owner_pid,
                transition_token,
                dependency_pids,
                binding,
                operation
              )

            {:error, _reason} ->
              {:reply, {:error, :gate_authority_changed}, close_state(state)}
          end
      end
    else
      false -> {:reply, {:error, :gate_not_controller}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(
        {:authority_request, owner_pid, request_token,
         {:open_owned, controller_capability, owner_pid, dependency_pids, binding, authority_bindings} = operation},
        _from,
        state
      ) do
    with true <- AuthorityRequest.valid?(request_token, owner_pid, operation),
         :ok <-
           authorize_open(
             state,
             controller_capability,
             owner_pid,
             owner_pid,
             authority_bindings
           ) do
      if exact_open_current?(state, operation) do
        {:reply, :ok, state}
      else
        open_for_owner(
          state,
          owner_pid,
          dependency_pids,
          binding,
          authority_bindings,
          operation
        )
      end
    else
      false -> {:reply, {:error, :gate_not_controller}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(
        {:prepare_transition, _controller_capability, _owner_pid, _authority_bindings},
        _from,
        state
      ) do
    {:reply, {:error, :gate_not_controller}, state}
  end

  def handle_call(
        {:transition_current, _controller_capability, _owner_pid, _transition_token},
        _from,
        state
      ) do
    {:reply, {:error, :gate_not_controller}, state}
  end

  def handle_call(
        {:open_prepared, _controller_capability, _owner_pid, _transition_token, _dependency_pids, _binding},
        _from,
        state
      ) do
    {:reply, {:error, :gate_not_controller}, state}
  end

  def handle_call(
        {:open_owned, _controller_capability, _owner_pid, _dependency_pids, _binding, _authority_bindings},
        _from,
        state
      ) do
    {:reply, {:error, :gate_not_controller}, state}
  end

  def handle_call(
        {:open_owned, _owner_pid, _dependency_pids, _binding, _authority_bindings},
        _from,
        state
      ) do
    {:reply, {:error, :gate_not_controller}, state}
  end

  def handle_call(
        {:invalidate_observed_lease, observed_lease},
        _from,
        %{lease: observed_lease} = state
      ) do
    state = close_local_state(state)
    send(self(), {:invalidate_observed_authority, state.term_key, observed_lease})
    {:reply, :ok, state}
  end

  def handle_call({:invalidate_observed_lease, _stale_lease}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state) do
    state = close_state(state)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, %{status: :closed} = state), do: {:reply, :closed, state}

  def handle_call(:status, _from, state) do
    if owns_current_lease?(state) do
      {:reply, state.status, state}
    else
      state = close_state(state)
      {:reply, :closed, state}
    end
  end

  @impl true
  def handle_info({:invalidate_observed_authority, term_key, observed_lease}, state) do
    _result =
      AuthorityRegistry.invalidate_observed(
        state.authority_registry_pid,
        term_key,
        observed_lease
      )

    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, starter_pid, _reason},
        %{
          starter_pid: starter_pid,
          starter_monitor_ref: monitor_ref
        } = state
      ) do
    {:stop, :gate_starter_unavailable, state}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, registry_pid, _reason},
        %{
          authority_registry_pid: registry_pid,
          authority_registry_monitor_ref: monitor_ref
        } = state
      ) do
    {:stop, :gate_authority_unavailable, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, lease_pid, _reason}, state) do
    case state.monitor_refs do
      %{^monitor_ref => ^lease_pid} -> {:noreply, close_state(state)}
      _other -> {:noreply, state}
    end
  end

  defp authorize_open(
         %{controller_capability: controller_capability},
         presented_capability,
         _caller_pid,
         _owner_pid,
         _authority_bindings
       )
       when presented_capability != controller_capability,
       do: {:error, :gate_not_controller}

  defp authorize_open(
         _state,
         _controller_capability,
         caller_pid,
         owner_pid,
         _authority_bindings
       )
       when caller_pid != owner_pid,
       do: {:error, :invalid_gate_owner}

  defp authorize_open(
         %{
           controller_reference: controller_reference,
           controller_pid: pinned_controller_pid
         },
         _controller_capability,
         caller_pid,
         _owner_pid,
         authority_bindings
       ) do
    with :ok <- controller_handoff_status(pinned_controller_pid, caller_pid) do
      if conflicting_reference_binding?(
           authority_bindings,
           controller_reference,
           caller_pid
         ) do
        {:error, :gate_authority_changed}
      else
        :ok
      end
    end
  end

  defp authorize_open(
         _state,
         _controller_capability,
         _caller_pid,
         _owner_pid,
         _authority_bindings
       ),
       do: {:error, :gate_not_controller}

  defp controller_handoff_status(nil, controller_pid) when is_pid(controller_pid), do: :ok

  defp controller_handoff_status(controller_pid, controller_pid) when is_pid(controller_pid),
    do: :ok

  defp controller_handoff_status(prior_controller_pid, controller_pid)
       when is_pid(prior_controller_pid) and is_pid(controller_pid) do
    if Process.alive?(prior_controller_pid),
      do: {:error, :gate_not_controller},
      else: :ok
  end

  defp controller_handoff_status(_prior_controller_pid, _controller_pid),
    do: {:error, :gate_not_controller}

  defp conflicting_reference_binding?(
         authority_bindings,
         controller_reference,
         controller_pid
       )
       when is_map(authority_bindings) do
    Enum.any?(authority_bindings, fn
      {_section, {^controller_reference, expected_pid}}
      when is_pid(expected_pid) ->
        expected_pid != controller_pid

      _other_binding ->
        false
    end)
  end

  defp conflicting_reference_binding?(
         _authority_bindings,
         _controller_reference,
         _controller_pid
       ),
       do: false

  defp exact_open_current?(%{open_operation: operation} = state, operation),
    do: owns_current_lease?(state)

  defp exact_open_current?(_state, _operation), do: false

  defp exact_transition_current?(
         %{transition_operation: operation, transition_token: transition_token} = state,
         operation
       )
       when is_reference(transition_token) do
    prepared_transition_status(state, state.owner_pid, transition_token) == :ok
  end

  defp exact_transition_current?(_state, _operation), do: false

  defp prepare_transition_for_owner(
         state,
         owner_pid,
         authority_bindings,
         transition_operation
       ) do
    state = close_state(state)

    with :ok <- validate_authority_bindings_shape(authority_bindings),
         authority_pids = authority_bindings |> Map.values() |> Enum.map(&elem(&1, 1)),
         {:ok, transition_pids} <- validate_lease_pids(owner_pid, authority_pids),
         {:ok, transition_guard} <-
           start_authority_guard(
             state.controller_reference,
             owner_pid,
             authority_bindings,
             owner_pid
           ),
         transition_token =
           new_transition_token(
             state,
             owner_pid,
             authority_bindings,
             transition_guard
           ) do
      authority_guard_pid = transition_guard.pid
      transition_pids = Enum.uniq(transition_pids ++ [authority_guard_pid])

      state =
        install_lease_monitors(
          state,
          owner_pid,
          authority_pids ++ [authority_guard_pid],
          authority_bindings,
          authority_guard_pid
        )

      state = %{
        state
        | controller_pid: owner_pid,
          transition_token: transition_token,
          transition_operation: transition_operation,
          transition_guard: transition_guard
      }

      case transition_status(transition_pids, transition_guard) do
        :ok -> {:reply, {:ok, transition_token}, state}
        {:error, reason} -> {:reply, {:error, reason}, close_state(state)}
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp open_prepared_for_owner(
         state,
         owner_pid,
         transition_token,
         dependency_pids,
         binding,
         open_operation
       ) do
    authority_bindings = state.authority_bindings
    authority_pids = authority_bindings |> Map.values() |> Enum.map(&elem(&1, 1))
    transition_guard = state.transition_guard
    authority_guard_pid = transition_guard.pid

    with {:ok, binding} <- validate_binding(binding),
         {:ok, lease_pids} <-
           validate_lease_pids(owner_pid, dependency_pids ++ authority_pids),
         :ok <- prepared_transition_status(state, owner_pid, transition_token) do
      lease_pids = Enum.uniq(lease_pids ++ [authority_guard_pid])

      state =
        state
        |> release_lease_monitors()
        |> install_lease_monitors(
          owner_pid,
          dependency_pids ++ authority_pids ++ [authority_guard_pid],
          authority_bindings,
          authority_guard_pid
        )

      published_lease_pids = Enum.uniq([self() | lease_pids])

      case transition_status(published_lease_pids, transition_guard) do
        :ok ->
          lease_token = new_lease_token()

          lease =
            {:open, state.authority_token, lease_token, binding, published_lease_pids, authority_bindings,
             state.controller_reference, authority_guard_pid}

          state = %{state | lease_token: lease_token}

          with :ok <- publish_lease(state, owner_pid, lease),
               :ok <- transition_status(published_lease_pids, transition_guard),
               :ok <- activate_published_lease(state, owner_pid, lease),
               :ok <- mark_lease_token_confirming(lease_token),
               :ok <- confirm_published_lease(state, owner_pid, lease),
               :ok <- transition_status(published_lease_pids, transition_guard),
               :ok <- current_registry_lease(state.term_key, lease),
               true <- :persistent_term.get(state.term_key, :closed) == lease,
               :ok <- activate_lease_token(lease_token),
               :ok <- adopt_transition_token(transition_token) do
            {:reply, :ok,
             %{
               state
               | controller_pid: owner_pid,
                 lease: lease,
                 open_operation: open_operation,
                 status: {:open, binding}
             }}
          else
            false ->
              {:reply, {:error, :gate_superseded}, close_state(state)}

            {:error, _reason} = error ->
              {:reply, error, close_state(state)}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, close_state(state)}
      end
    else
      {:error, _reason} = error -> {:reply, error, close_state(state)}
    end
  end

  defp open_for_owner(
         state,
         owner_pid,
         dependency_pids,
         binding,
         authority_bindings,
         open_operation
       ) do
    state = close_state(state)

    with {:ok, binding} <- validate_binding(binding),
         :ok <- validate_authority_bindings_shape(authority_bindings),
         authority_pids = authority_bindings |> Map.values() |> Enum.map(&elem(&1, 1)),
         {:ok, lease_pids} <-
           validate_lease_pids(owner_pid, dependency_pids ++ authority_pids),
         {:ok, authority_guard} <-
           start_authority_guard(
             state.controller_reference,
             owner_pid,
             authority_bindings,
             owner_pid
           ) do
      authority_guard_pid = authority_guard.pid
      lease_pids = Enum.uniq(lease_pids ++ [authority_guard_pid])

      state =
        install_lease_monitors(
          state,
          owner_pid,
          dependency_pids ++ authority_pids ++ [authority_guard_pid],
          authority_bindings,
          authority_guard_pid
        )

      published_lease_pids = Enum.uniq([self() | lease_pids])

      case transition_status(published_lease_pids, authority_guard) do
        :ok ->
          lease_token = new_lease_token()

          lease =
            {:open, state.authority_token, lease_token, binding, published_lease_pids, authority_bindings,
             state.controller_reference, authority_guard_pid}

          state = %{state | lease_token: lease_token}

          with :ok <- publish_lease(state, owner_pid, lease),
               :ok <- transition_status(published_lease_pids, authority_guard),
               :ok <- activate_published_lease(state, owner_pid, lease),
               :ok <- mark_lease_token_confirming(lease_token),
               :ok <- confirm_published_lease(state, owner_pid, lease),
               :ok <- transition_status(published_lease_pids, authority_guard),
               :ok <- current_registry_lease(state.term_key, lease),
               true <- :persistent_term.get(state.term_key, :closed) == lease,
               :ok <- activate_lease_token(lease_token) do
            {:reply, :ok,
             %{
               state
               | controller_pid: owner_pid,
                 lease: lease,
                 open_operation: open_operation,
                 status: {:open, binding}
             }}
          else
            false ->
              {:reply, {:error, :gate_superseded}, close_state(state)}

            {:error, _reason} = error ->
              {:reply, error, close_state(state)}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, close_state(state)}
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp owns_current_lease?(%{lease: lease} = state) when is_tuple(lease) do
    with true <- AuthorityRegistry.current_lease?(state.term_key, lease),
         :ok <- current_lease_status(lease),
         true <- AuthorityRegistry.current_lease?(state.term_key, lease),
         true <-
           repair_cached_lease(
             state.authority_registry_pid,
             state.term_key,
             lease
           ) do
      true
    else
      _not_current -> false
    end
  end

  defp owns_current_lease?(_state), do: false

  defp repair_cached_lease(authority_registry_pid, term_key, lease) do
    case :persistent_term.get(term_key, :closed) do
      ^lease ->
        true

      observed ->
        _result =
          AuthorityRegistry.invalidate_observed(
            authority_registry_pid,
            term_key,
            observed
          )

        AuthorityRegistry.current_lease?(term_key, lease) and
          :persistent_term.get(term_key, :closed) == lease
    end
  end

  defp close_state(state) do
    state = close_local_state(state)

    _result =
      AuthorityRegistry.close(
        state.authority_registry_pid,
        state.term_key,
        state.authority_token,
        self(),
        state.authority_capability
      )

    state
  end

  defp close_local_state(state) do
    revoke_lease_token(state.lease_token)
    revoke_transition_token(state.transition_token)
    authority_guard_pid = state.authority_guard_pid
    state = release_lease_monitors(state)
    stop_authority_guard(authority_guard_pid)

    %{
      state
      | transition_token: nil,
        transition_operation: nil,
        transition_guard: nil,
        lease_token: nil,
        lease: nil,
        open_operation: nil,
        authority_guard_pid: nil,
        status: :closed,
        owner_pid: nil,
        dependency_pids: [],
        authority_bindings: %{},
        monitor_refs: %{}
    }
  end

  defp publish_lease(state, controller_pid, lease) do
    AuthorityRegistry.publish_lease(
      state.authority_registry_pid,
      state.term_key,
      state.authority_token,
      self(),
      state.authority_capability,
      controller_pid,
      lease
    )
  end

  defp activate_published_lease(state, controller_pid, lease) do
    AuthorityRegistry.activate_lease(
      state.authority_registry_pid,
      state.term_key,
      state.authority_token,
      self(),
      state.authority_capability,
      controller_pid,
      lease
    )
  end

  defp confirm_published_lease(state, controller_pid, lease) do
    AuthorityRegistry.confirm_lease(
      state.authority_registry_pid,
      state.term_key,
      state.authority_token,
      self(),
      state.authority_capability,
      controller_pid,
      lease
    )
  end

  defp current_registry_lease(term_key, lease) do
    if AuthorityRegistry.current_lease?(term_key, lease),
      do: :ok,
      else: {:error, :gate_superseded}
  end

  defp new_claim_token do
    :ets.new(__MODULE__, [:set, :protected])
  end

  defp new_claim_capability(
         gate_pid,
         gate_capability,
         term_key,
         authority_token,
         controller_reference,
         controller_pid,
         claim_token
       ) do
    fn challenge ->
      {__MODULE__, :claim_capability, challenge, gate_pid, gate_capability, term_key, authority_token,
       controller_reference, controller_pid, claim_token}
    end
  end

  defp activate_claim_token(claim_token) do
    if :ets.insert_new(claim_token, {:state, :active}),
      do: :ok,
      else: {:error, :gate_superseded}
  rescue
    ArgumentError -> {:error, :gate_superseded}
  end

  defp new_transition_token(state, owner_pid, authority_bindings, transition_guard) do
    transition_token = :ets.new(__MODULE__, [:set, :protected])

    true =
      :ets.insert_new(
        transition_token,
        {:transition, state.authority_token, owner_pid, authority_bindings, transition_guard.pid,
         transition_guard.incarnation}
      )

    true = :ets.insert_new(transition_token, {:state, :prepared})
    transition_token
  end

  defp prepared_transition_status(
         %{
           authority_token: authority_token,
           transition_token: transition_token,
           transition_guard:
             %{pid: authority_guard_pid, incarnation: guard_incarnation} =
               transition_guard,
           owner_pid: owner_pid,
           dependency_pids: dependency_pids,
           authority_bindings: authority_bindings
         },
         owner_pid,
         transition_token
       )
       when is_reference(transition_token) do
    with :prepared <-
           transition_token_status(
             transition_token,
             self(),
             authority_token,
             owner_pid,
             authority_bindings,
             authority_guard_pid,
             guard_incarnation
           ),
         :ok <- transition_status([owner_pid | dependency_pids], transition_guard),
         :prepared <-
           transition_token_status(
             transition_token,
             self(),
             authority_token,
             owner_pid,
             authority_bindings,
             authority_guard_pid,
             guard_incarnation
           ) do
      :ok
    else
      _invalid_or_changed -> {:error, :gate_authority_changed}
    end
  end

  defp prepared_transition_status(_state, _owner_pid, _transition_token),
    do: {:error, :gate_authority_changed}

  defp transition_token_status(
         transition_token,
         gate_pid,
         authority_token,
         owner_pid,
         authority_bindings,
         authority_guard_pid,
         guard_incarnation
       ) do
    with ^gate_pid <- :ets.info(transition_token, :owner),
         :protected <- :ets.info(transition_token, :protection),
         [
           {:transition, ^authority_token, ^owner_pid, ^authority_bindings, ^authority_guard_pid, ^guard_incarnation}
         ] <- :ets.lookup(transition_token, :transition) do
      case :ets.lookup(transition_token, :state) do
        [{:state, :prepared}] -> :prepared
        [{:state, :adopted}] -> :adopted
        _invalid_state -> :invalid
      end
    else
      _invalid_token -> :invalid
    end
  rescue
    ArgumentError -> :invalid
  end

  defp adopt_transition_token(transition_token) when is_reference(transition_token) do
    case :ets.lookup(transition_token, :state) do
      [{:state, :prepared}] ->
        true = :ets.insert(transition_token, {:state, :adopted})
        :ok

      [{:state, :adopted}] ->
        :ok

      _invalid_state ->
        {:error, :gate_superseded}
    end
  rescue
    ArgumentError -> {:error, :gate_superseded}
  end

  defp revoke_transition_token(nil), do: :ok

  defp revoke_transition_token(transition_token) when is_reference(transition_token) do
    :ets.delete(transition_token)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp revoke_transition_token(_transition_token), do: :ok

  defp new_lease_token do
    :ets.new(__MODULE__, [:set, :protected])
  end

  defp mark_lease_token_confirming(lease_token) do
    if :ets.insert_new(lease_token, {:state, :confirming}),
      do: :ok,
      else: {:error, :gate_superseded}
  rescue
    ArgumentError -> {:error, :gate_superseded}
  end

  defp activate_lease_token(lease_token) do
    case :ets.lookup(lease_token, :state) do
      [{:state, :confirming}] ->
        true = :ets.insert(lease_token, {:state, :active})
        :ok

      _invalid_state ->
        {:error, :gate_superseded}
    end
  rescue
    ArgumentError -> {:error, :gate_superseded}
  end

  defp revoke_lease_token(nil), do: :ok

  defp revoke_lease_token(lease_token) when is_reference(lease_token) do
    :ets.delete(lease_token)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp revoke_lease_token(_lease_token), do: :ok

  defp stop_authority_guard(nil), do: :ok

  defp stop_authority_guard(authority_guard_pid) when is_pid(authority_guard_pid) do
    if Process.alive?(authority_guard_pid) do
      monitor_ref = Process.monitor(authority_guard_pid)
      Process.exit(authority_guard_pid, :kill)

      receive do
        {:DOWN, ^monitor_ref, :process, ^authority_guard_pid, _reason} -> :ok
      after
        @local_revocation_timeout_ms -> Process.demonitor(monitor_ref, [:flush])
      end
    end

    :ok
  end

  defp stop_authority_guard(_authority_guard_pid), do: :ok

  defp install_lease_monitors(
         state,
         owner_pid,
         dependency_pids,
         authority_bindings,
         authority_guard_pid
       ) do
    monitor_refs =
      [owner_pid | dependency_pids]
      |> Enum.uniq()
      |> Map.new(fn lease_pid -> {Process.monitor(lease_pid), lease_pid} end)

    %{
      state
      | owner_pid: owner_pid,
        dependency_pids: Enum.uniq(dependency_pids),
        authority_bindings: authority_bindings,
        authority_guard_pid: authority_guard_pid,
        monitor_refs: monitor_refs
    }
  end

  defp release_lease_monitors(state) do
    Enum.each(Map.keys(state.monitor_refs), &Process.demonitor(&1, [:flush]))
    %{state | owner_pid: nil, dependency_pids: [], authority_bindings: %{}, monitor_refs: %{}}
  end

  defp validate_lease_pids(owner_pid, dependency_pids)
       when is_pid(owner_pid) and is_list(dependency_pids) do
    if Enum.all?(dependency_pids, &is_pid/1) do
      {:ok, Enum.uniq([owner_pid | dependency_pids])}
    else
      {:error, :invalid_gate_dependencies}
    end
  end

  defp validate_lease_pids(owner_pid, _dependency_pids) when not is_pid(owner_pid),
    do: {:error, :invalid_gate_owner}

  defp validate_lease_pids(_owner_pid, _dependency_pids),
    do: {:error, :invalid_gate_dependencies}

  defp lease_alive?([pid | rest]) when is_pid(pid),
    do: Process.alive?(pid) and lease_pid_tail_alive?(rest)

  defp lease_alive?(_lease_pids), do: false

  defp lease_pid_tail_alive?([]), do: true

  defp lease_pid_tail_alive?([pid | rest]) when is_pid(pid),
    do: Process.alive?(pid) and lease_pid_tail_alive?(rest)

  defp lease_pid_tail_alive?(_improper_or_invalid_tail), do: false

  defp proper_published_lease_pids?([gate_pid, controller_pid | rest])
       when is_pid(gate_pid) and is_pid(controller_pid),
       do: proper_pid_tail?(rest)

  defp proper_published_lease_pids?(_lease_pids), do: false

  defp proper_pid_tail?([]), do: true
  defp proper_pid_tail?([pid | rest]) when is_pid(pid), do: proper_pid_tail?(rest)
  defp proper_pid_tail?(_improper_or_invalid_tail), do: false

  defp read_current_lease(term_key, lease) do
    if AuthorityRegistry.current_lease?(term_key, lease) do
      case current_lease_status(lease) do
        :ok ->
          if AuthorityRegistry.current_lease?(term_key, lease) and
               :persistent_term.get(term_key, :closed) == lease do
            true
          else
            invalidate_observed_lease(term_key, lease)
            false
          end

        {:error, :gate_not_active} ->
          false

        {:error, _reason} ->
          invalidate_observed_lease(term_key, lease)
          false
      end
    else
      invalidate_observed_lease(term_key, lease)
      false
    end
  end

  defp current_lease_status(
         {:open, authority_token, lease_token, binding, [gate_pid, controller_pid | _lease_pids] = published_lease_pids,
          authority_bindings, controller_reference, authority_guard_pid}
       )
       when is_reference(authority_token) and is_reference(lease_token) and
              is_pid(gate_pid) and is_pid(controller_pid) and is_pid(authority_guard_pid) do
    with {:ok, ^binding} <- validate_binding(binding),
         true <- proper_published_lease_pids?(published_lease_pids),
         :active <- lease_token_status(lease_token, gate_pid),
         :ok <- validate_authority_bindings_shape(authority_bindings),
         true <- authority_pids_leased?(authority_bindings, published_lease_pids),
         true <- valid_owner_reference?(controller_reference),
         true <- authority_guard_leased?(authority_guard_pid, published_lease_pids),
         :ok <- lease_status(published_lease_pids, authority_guard_pid),
         :active <- lease_token_status(lease_token, gate_pid) do
      :ok
    else
      token_state when token_state in [:inactive, :confirming] ->
        {:error, :gate_not_active}

      {:error, _reason} = error ->
        error

      _invalid_shape ->
        {:error, :gate_authority_changed}
    end
  end

  defp current_lease_status(_lease), do: {:error, :gate_authority_changed}

  defp lease_token_status(lease_token, gate_pid) do
    with ^gate_pid <- :ets.info(lease_token, :owner),
         :protected <- :ets.info(lease_token, :protection) do
      case :ets.lookup(lease_token, :state) do
        [] -> :inactive
        [{:state, :confirming}] -> :confirming
        [{:state, :active}] -> :active
        _invalid_state -> :invalid
      end
    else
      _invalid_token -> :invalid
    end
  rescue
    ArgumentError -> :invalid
  end

  defp authority_pids_leased?(authority_bindings, published_lease_pids) do
    leased_pids = MapSet.new(published_lease_pids)

    Enum.all?(authority_bindings, fn {_section, {_owner_reference, expected_pid}} ->
      MapSet.member?(leased_pids, expected_pid)
    end)
  end

  defp authority_guard_leased?(authority_guard_pid, published_lease_pids) do
    authority_guard_pid in published_lease_pids
  end

  defp invalidate_observed_lease(term_key, lease) do
    _local_result = revoke_observed_lease_locally(lease)
    _authority_result = AuthorityRegistry.invalidate_observed(term_key, lease)
    :ok
  end

  defp revoke_observed_lease_locally(
         {:open, _authority_token, _lease_token, _binding, [gate_pid | _lease_pids], _authority_bindings,
          _controller_reference, _authority_guard_pid} = lease
       )
       when is_pid(gate_pid) do
    GenServer.call(
      gate_pid,
      {:invalidate_observed_lease, lease},
      @local_revocation_timeout_ms
    )
  catch
    :exit, _reason -> {:error, :gate_unavailable}
  end

  defp revoke_observed_lease_locally(_lease), do: :ok

  defp lease_status(lease_pids, authority_guard_pid),
    do: transition_status(lease_pids, authority_guard_pid)

  defp transition_status(lease_pids, authority_guard) do
    cond do
      not lease_alive?(lease_pids) ->
        {:error, :gate_dependency_unavailable}

      not AuthorityGuard.current?(authority_guard) ->
        {:error, :gate_authority_changed}

      not lease_alive?(lease_pids) ->
        {:error, :gate_dependency_unavailable}

      true ->
        :ok
    end
  end

  defp validate_authority_bindings_shape(authority_bindings) when is_map(authority_bindings) do
    if MapSet.new(Map.keys(authority_bindings)) == @authority_sections and
         Enum.all?(authority_bindings, fn
           {section, {owner_reference, expected_pid}} ->
             is_atom(section) and valid_owner_reference?(owner_reference) and is_pid(expected_pid)

           _invalid_entry ->
             false
         end) do
      :ok
    else
      {:error, :invalid_gate_authority_bindings}
    end
  end

  defp validate_authority_bindings_shape(_authority_bindings),
    do: {:error, :invalid_gate_authority_bindings}

  defp start_authority_guard(
         controller_reference,
         controller_pid,
         authority_bindings,
         cancel_on
       ) do
    bindings = [{controller_reference, controller_pid} | Map.values(authority_bindings)]

    with {:ok, expected_by_reference} <- normalize_reference_bindings(bindings),
         {:ok, guarded_bindings} <-
           build_guarded_bindings(expected_by_reference, cancel_on),
         {:ok, authority_guard} <- AuthorityGuard.start_attested(guarded_bindings) do
      {:ok, authority_guard}
    else
      {:error, :owner_authority_unattested} ->
        {:error, :gate_authority_unattested}

      {:error, reason}
      when reason in [:owner_unavailable, :owner_resolution_cancelled] ->
        {:error, :gate_dependency_unavailable}

      {:error, _reason} ->
        {:error, :gate_authority_changed}
    end
  end

  defp normalize_reference_bindings(bindings) do
    Enum.reduce_while(bindings, {:ok, %{}}, fn
      {owner_reference, expected_pid}, {:ok, acc}
      when is_pid(expected_pid) ->
        cond do
          not valid_owner_reference?(owner_reference) ->
            {:halt, {:error, :invalid_owner_bindings}}

          Map.get(acc, owner_reference, expected_pid) != expected_pid ->
            {:halt, {:error, :owner_reference_conflict}}

          true ->
            {:cont, {:ok, Map.put(acc, owner_reference, expected_pid)}}
        end

      _invalid_binding, _acc ->
        {:halt, {:error, :invalid_owner_bindings}}
    end)
  end

  defp build_guarded_bindings(expected_by_reference, cancel_on) do
    OwnerResolver.run(
      fn ->
        Enum.reduce_while(expected_by_reference, {:ok, []}, fn
          {{:via, _module, _name} = owner_reference, expected_pid}, {:ok, acc} ->
            case attest_via_reference(owner_reference, expected_pid) do
              {:ok, ^expected_pid, incarnation_pid} ->
                {:cont, {:ok, [{owner_reference, expected_pid, incarnation_pid} | acc]}}

              {:error, _reason} = error ->
                {:halt, error}
            end

          {owner_reference, expected_pid}, {:ok, acc} ->
            {:cont, {:ok, [{owner_reference, expected_pid} | acc]}}
        end)
      end,
      timeout_ms: @owner_resolution_timeout_ms,
      cancel_on: cancel_on
    )
  end

  defp attest_via_reference({:via, module, name}, expected_pid) do
    with {:ok, owner_pid, incarnation_pid} <- current_via_authority(module, name),
         ^expected_pid <- owner_pid do
      {:ok, owner_pid, incarnation_pid}
    else
      {:error, _reason} = error -> error
      _owner_mismatch -> {:error, :owner_authority_changed}
    end
  end

  defp attest_initial_via_reference({:via, module, name}) do
    with {:ok, owner_pid, _incarnation_pid} <- current_via_authority(module, name) do
      {:ok, owner_pid}
    end
  end

  defp current_via_authority(module, name) do
    with :ok <- validate_via_authority_contract(module),
         {:ok, owner_pid, incarnation_pid} <- read_via_authority_snapshot(module, name),
         :ok <- validate_via_authority_pids(owner_pid, incarnation_pid),
         :ok <- validate_via_owner_liveness(owner_pid),
         :ok <- validate_via_incarnation_liveness(incarnation_pid),
         ^owner_pid <- module.whereis_name(name) do
      {:ok, owner_pid, incarnation_pid}
    else
      {:error, _reason} = error -> error
      _mismatch_or_unresolved -> {:error, :owner_authority_changed}
    end
  end

  defp validate_via_authority_contract(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :authority_snapshot, 1) and
         function_exported?(module, :whereis_name, 1) do
      :ok
    else
      {:error, :owner_authority_unattested}
    end
  end

  defp read_via_authority_snapshot(module, name) do
    case module.authority_snapshot(name) do
      {:ok, owner_pid, incarnation_pid} -> {:ok, owner_pid, incarnation_pid}
      _invalid_or_unavailable -> {:error, :owner_authority_changed}
    end
  end

  defp validate_via_authority_pids(owner_pid, incarnation_pid)
       when is_pid(owner_pid) and is_pid(incarnation_pid) and owner_pid != incarnation_pid,
       do: :ok

  defp validate_via_authority_pids(_owner_pid, _incarnation_pid),
    do: {:error, :owner_authority_changed}

  defp validate_via_owner_liveness(owner_pid) do
    if Process.alive?(owner_pid),
      do: :ok,
      else: {:error, :owner_unavailable}
  end

  defp validate_via_incarnation_liveness(incarnation_pid) do
    if Process.alive?(incarnation_pid),
      do: :ok,
      else: {:error, :owner_authority_changed}
  end

  defp resolve_initial_controller_pid({:via, _module, _name} = controller_reference) do
    case OwnerResolver.run(
           fn -> attest_initial_via_reference(controller_reference) end,
           timeout_ms: @owner_resolution_timeout_ms
         ) do
      {:ok, controller_pid} -> {:ok, controller_pid}
      {:error, :owner_authority_unattested} -> {:error, :gate_controller_unattested}
      {:error, _reason} -> {:error, :gate_controller_unavailable}
    end
  end

  defp resolve_initial_controller_pid(controller_reference) do
    with {:ok, resolutions} <-
           OwnerResolver.resolve([controller_reference],
             timeout_ms: @owner_resolution_timeout_ms
           ) do
      case Map.fetch!(resolutions, controller_reference) do
        controller_pid when is_pid(controller_pid) ->
          if Process.alive?(controller_pid),
            do: {:ok, controller_pid},
            else: {:error, :gate_controller_unavailable}

        unresolved when unresolved in [nil, :undefined] ->
          {:ok, nil}

        _invalid_resolution ->
          {:error, :gate_controller_unavailable}
      end
    else
      {:error, _reason} -> {:error, :gate_controller_unavailable}
    end
  end

  defp valid_owner_reference?(pid) when is_pid(pid), do: true
  defp valid_owner_reference?(name) when is_atom(name), do: true
  defp valid_owner_reference?({:global, _name}), do: true
  defp valid_owner_reference?({:via, module, _name}) when is_atom(module), do: true
  defp valid_owner_reference?(_owner_reference), do: false

  defp validate_binding(
         %{
           credential_epoch: credential_epoch,
           storage_epoch: storage_epoch,
           generation: generation,
           manifest_hash: manifest_hash
         } = binding
       )
       when is_integer(credential_epoch) and credential_epoch >= 0 and
              is_binary(storage_epoch) and byte_size(storage_epoch) == 16 and
              storage_epoch != @zero_epoch and is_integer(generation) and generation > 0 and
              is_binary(manifest_hash) and byte_size(manifest_hash) == 32 do
    {:ok, Map.take(binding, [:credential_epoch, :storage_epoch, :generation, :manifest_hash])}
  end

  defp validate_binding(_binding), do: {:error, :invalid_gate_binding}
end
