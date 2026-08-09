defmodule RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityGuard do
  @moduledoc false

  use GenServer

  @call_timeout_ms 25
  @max_trace_messages_per_check 1_024

  @type owner_reference ::
          pid()
          | atom()
          | {:global, term()}
          | {:via, module(), term()}

  @type binding ::
          {owner_reference(), pid()}
          | {{:via, module(), term()}, pid(), pid()}

  @type attested_guard :: %{
          pid: pid(),
          incarnation: reference(),
          attestor: (reference() -> term())
        }

  @spec start([binding()]) :: GenServer.on_start()
  def start(bindings) when is_list(bindings) do
    case start_attested(bindings) do
      {:ok, %{pid: guard_pid}} -> {:ok, guard_pid}
      {:error, _reason} = error -> error
    end
  end

  @spec start_attested([binding()]) :: {:ok, attested_guard()} | {:error, term()}
  def start_attested(bindings) when is_list(bindings) do
    case GenServer.start(__MODULE__, {bindings, self()}) do
      {:ok, guard_pid} ->
        case fetch_attestation(guard_pid) do
          {:ok, attested_guard} ->
            {:ok, attested_guard}

          {:error, _reason} = error ->
            Process.exit(guard_pid, :kill)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec attested?(pid() | attested_guard()) :: boolean()
  def attested?(guard_pid) when is_pid(guard_pid) do
    case fetch_attestation(guard_pid) do
      {:ok, attested_guard} -> valid_attestation?(attested_guard)
      {:error, _reason} -> false
    end
  end

  def attested?(attested_guard) when is_map(attested_guard),
    do: valid_attestation?(attested_guard)

  def attested?(_guard), do: false

  @spec current?(pid() | attested_guard()) :: boolean()
  def current?(guard_pid) when is_pid(guard_pid) do
    case fetch_attestation(guard_pid) do
      {:ok, attested_guard} -> current?(attested_guard)
      {:error, _reason} -> false
    end
  end

  def current?(%{pid: guard_pid, incarnation: incarnation} = attested_guard)
      when is_pid(guard_pid) and is_reference(incarnation) do
    valid_attestation?(attested_guard) and
      GenServer.call(
        guard_pid,
        {:current?, incarnation},
        @call_timeout_ms
      ) == true
  catch
    :exit, _reason -> false
  end

  def current?(_guard), do: false

  @impl true
  def init({bindings, guard_owner_pid}) when is_list(bindings) and is_pid(guard_owner_pid) do
    guard_owner_monitor_ref = Process.monitor(guard_owner_pid)

    with {:ok, normalized} <- normalize_bindings(bindings),
         {:ok, state} <- start_tracing(normalized),
         state =
           Map.merge(state, %{
             guard_owner_pid: guard_owner_pid,
             guard_owner_monitor_ref: guard_owner_monitor_ref
           }),
         state = put_guard_attestation(state),
         true <- bindings_current?(state),
         :ok <- synchronize_traces(state) do
      {:ok, state}
    else
      false -> {:stop, :owner_authority_changed}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:attestation, _from, state) do
    {:reply, {:ok, attested_guard(state)}, state}
  end

  def handle_call(:current?, _from, state), do: current_reply(state)

  def handle_call(
        {:current?, guard_incarnation},
        _from,
        %{guard_incarnation: guard_incarnation} = state
      ) do
    current_reply(state)
  end

  def handle_call({:current?, _stale_incarnation}, _from, state) do
    {:reply, false, state}
  end

  @impl true
  def handle_info(message, state) do
    if authority_change?(message, state) do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, %{session: session}) do
    _destroyed? = :trace.session_destroy(session)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp normalize_bindings(bindings) do
    initial = %{
      direct_bindings: %{},
      local_bindings: %{},
      global_bindings: %{},
      via_bindings: %{}
    }

    Enum.reduce_while(bindings, {:ok, initial}, fn
      {owner_pid, expected_pid}, {:ok, normalized}
      when is_pid(owner_pid) and is_pid(expected_pid) ->
        put_normalized_binding(normalized, :direct_bindings, owner_pid, expected_pid)

      {name, expected_pid}, {:ok, normalized}
      when is_atom(name) and is_pid(expected_pid) ->
        put_normalized_binding(normalized, :local_bindings, name, expected_pid)

      {{:global, name}, expected_pid}, {:ok, normalized}
      when is_pid(expected_pid) ->
        put_normalized_binding(normalized, :global_bindings, name, expected_pid)

      {{:via, module, name}, expected_pid, incarnation_pid}, {:ok, normalized}
      when is_atom(module) and is_pid(expected_pid) and is_pid(incarnation_pid) and
             expected_pid != incarnation_pid ->
        owner_reference = {:via, module, name}

        case put_via_binding(
               normalized.via_bindings,
               owner_reference,
               expected_pid,
               incarnation_pid
             ) do
          {:ok, via_bindings} ->
            {:cont, {:ok, %{normalized | via_bindings: via_bindings}}}

          {:error, _reason} = error ->
            {:halt, error}
        end

      {{:via, module, _name}, expected_pid}, _acc
      when is_atom(module) and is_pid(expected_pid) ->
        {:halt, {:error, :owner_authority_unattested}}

      _invalid_binding, _acc ->
        {:halt, {:error, :invalid_owner_bindings}}
    end)
  end

  defp put_normalized_binding(normalized, key, name, expected_pid) do
    case put_expected(Map.fetch!(normalized, key), name, expected_pid) do
      {:ok, bindings} -> {:cont, {:ok, Map.put(normalized, key, bindings)}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp put_expected(bindings, name, expected_pid) do
    case Map.fetch(bindings, name) do
      {:ok, ^expected_pid} -> {:ok, bindings}
      {:ok, _conflicting_pid} -> {:error, :owner_reference_conflict}
      :error -> {:ok, Map.put(bindings, name, expected_pid)}
    end
  end

  defp put_via_binding(bindings, owner_reference, expected_pid, incarnation_pid) do
    case Map.fetch(bindings, owner_reference) do
      {:ok, {^expected_pid, ^incarnation_pid}} ->
        {:ok, bindings}

      {:ok, _conflicting_incarnation} ->
        {:error, :owner_reference_conflict}

      :error ->
        {:ok, Map.put(bindings, owner_reference, {expected_pid, incarnation_pid})}
    end
  end

  defp start_tracing(normalized) do
    session = :trace.session_create(__MODULE__, self(), [])

    with :ok <- trace_local_owners(session, normalized.local_bindings),
         {:ok, global_server_pid, global_server_monitor_ref} <-
           trace_global_registry(session, normalized.global_bindings) do
      tracees =
        normalized.local_bindings
        |> Map.values()
        |> maybe_add_global_server(global_server_pid)
        |> Enum.uniq()

      incarnation_monitor_refs =
        normalized.via_bindings
        |> Map.values()
        |> Enum.map(&elem(&1, 1))
        |> Enum.uniq()
        |> Map.new(fn incarnation_pid ->
          {Process.monitor(incarnation_pid), incarnation_pid}
        end)

      {:ok,
       normalized
       |> Map.merge(%{
         session: session,
         global_server_pid: global_server_pid,
         global_server_monitor_ref: global_server_monitor_ref,
         incarnation_monitor_refs: incarnation_monitor_refs,
         tracees: tracees
       })}
    else
      {:error, _reason} = error ->
        :trace.session_destroy(session)
        error
    end
  rescue
    _exception -> {:error, :owner_authority_unavailable}
  catch
    _kind, _reason -> {:error, :owner_authority_unavailable}
  end

  defp trace_local_owners(session, local_bindings) do
    local_bindings
    |> Map.values()
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn owner_pid, :ok ->
      case :trace.process(session, owner_pid, true, [:procs]) do
        1 -> {:cont, :ok}
        _not_traced -> {:halt, {:error, :owner_authority_unavailable}}
      end
    end)
  end

  defp trace_global_registry(_session, global_bindings) when map_size(global_bindings) == 0,
    do: {:ok, nil, nil}

  defp trace_global_registry(session, _global_bindings) do
    case Process.whereis(:global_name_server) do
      global_server_pid when is_pid(global_server_pid) ->
        case :trace.process(session, global_server_pid, true, [:receive]) do
          1 ->
            {:ok, global_server_pid, Process.monitor(global_server_pid)}

          _not_traced ->
            {:error, :owner_authority_unavailable}
        end

      nil ->
        {:error, :owner_authority_unavailable}
    end
  end

  defp maybe_add_global_server(owner_pids, nil), do: owner_pids
  defp maybe_add_global_server(owner_pids, global_server_pid), do: [global_server_pid | owner_pids]

  defp synchronize_traces(%{session: session, tracees: tracees} = state) do
    deadline =
      System.monotonic_time() +
        System.convert_time_unit(@call_timeout_ms, :millisecond, :native)

    barriers =
      Map.new(tracees, fn tracee ->
        {:trace.delivered(session, tracee), tracee}
      end)

    await_trace_barriers(
      barriers,
      state,
      deadline,
      @max_trace_messages_per_check
    )
  rescue
    _exception -> {:error, :owner_authority_unavailable}
  catch
    _kind, _reason -> {:error, :owner_authority_unavailable}
  end

  defp await_trace_barriers(barriers, _state, deadline, _remaining_messages)
       when map_size(barriers) == 0 do
    if System.monotonic_time() <= deadline,
      do: :ok,
      else: {:error, :owner_authority_unavailable}
  end

  defp await_trace_barriers(_barriers, _state, _deadline, 0),
    do: {:error, :owner_authority_unavailable}

  defp await_trace_barriers(barriers, state, deadline, remaining_messages) do
    remaining_native = deadline - System.monotonic_time()

    if remaining_native <= 0 do
      {:error, :owner_authority_unavailable}
    else
      remaining_ms =
        remaining_native
        |> System.convert_time_unit(:native, :microsecond)
        |> then(&max(div(&1 + 999, 1_000), 1))

      receive do
        {:trace_delivered, tracee, barrier_ref} ->
          case Map.pop(barriers, barrier_ref) do
            {^tracee, remaining} ->
              await_trace_barriers(
                remaining,
                state,
                deadline,
                remaining_messages - 1
              )

            {nil, _unchanged} ->
              await_trace_barriers(
                barriers,
                state,
                deadline,
                remaining_messages - 1
              )
          end

        {:trace, _tracee, :register, _name} = message ->
          await_authority_trace(
            message,
            barriers,
            state,
            deadline,
            remaining_messages - 1
          )

        {:trace, _tracee, :unregister, _name} = message ->
          await_authority_trace(
            message,
            barriers,
            state,
            deadline,
            remaining_messages - 1
          )

        {:trace, _tracee, :receive, _received_message} = message ->
          await_authority_trace(
            message,
            barriers,
            state,
            deadline,
            remaining_messages - 1
          )

        {:DOWN, _monitor_ref, :process, _monitored_pid, _reason} = message ->
          await_authority_trace(
            message,
            barriers,
            state,
            deadline,
            remaining_messages - 1
          )
      after
        remaining_ms -> {:error, :owner_authority_unavailable}
      end
    end
  end

  defp await_authority_trace(
         message,
         barriers,
         state,
         deadline,
         remaining_messages
       ) do
    if authority_change?(message, state),
      do: {:error, :owner_authority_changed},
      else:
        await_trace_barriers(
          barriers,
          state,
          deadline,
          remaining_messages
        )
  end

  defp current_reply(state) do
    with true <- bindings_current?(state),
         :ok <- synchronize_traces(state) do
      {:reply, true, state}
    else
      _changed_or_unavailable -> {:stop, :normal, false, state}
    end
  end

  defp put_guard_attestation(state) do
    guard_pid = self()
    guard_capability = make_ref()
    guard_incarnation = make_ref()
    attestation_token = :ets.new(__MODULE__, [:set, :protected])

    true =
      :ets.insert_new(
        attestation_token,
        {:attestation, guard_capability, guard_pid, guard_incarnation}
      )

    attestor =
      new_guard_attestor(
        guard_pid,
        guard_capability,
        guard_incarnation,
        attestation_token
      )

    Map.merge(state, %{
      guard_pid: guard_pid,
      guard_capability: guard_capability,
      guard_incarnation: guard_incarnation,
      attestation_token: attestation_token,
      attestor: attestor
    })
  end

  defp new_guard_attestor(
         guard_pid,
         guard_capability,
         guard_incarnation,
         attestation_token
       ) do
    fn challenge ->
      {__MODULE__, :guard_attestation, challenge, guard_capability, guard_pid, guard_incarnation, attestation_token}
    end
  end

  defp attested_guard(state) do
    %{
      pid: state.guard_pid,
      incarnation: state.guard_incarnation,
      attestor: state.attestor
    }
  end

  defp fetch_attestation(guard_pid) do
    case GenServer.call(guard_pid, :attestation, @call_timeout_ms) do
      {:ok, %{pid: ^guard_pid} = attested_guard} ->
        if valid_attestation?(attested_guard),
          do: {:ok, attested_guard},
          else: {:error, :invalid_guard_attestation}

      _invalid_attestation ->
        {:error, :invalid_guard_attestation}
    end
  catch
    :exit, _reason -> {:error, :invalid_guard_attestation}
  end

  defp valid_attestation?(%{
         pid: guard_pid,
         incarnation: guard_incarnation,
         attestor: attestor
       })
       when is_pid(guard_pid) and is_reference(guard_incarnation) and
              is_function(attestor, 1) do
    challenge = make_ref()

    with true <- Process.alive?(guard_pid),
         {:module, __MODULE__} <- :erlang.fun_info(attestor, :module),
         {:type, :local} <- :erlang.fun_info(attestor, :type),
         {__MODULE__, :guard_attestation, ^challenge, guard_capability, ^guard_pid, ^guard_incarnation,
          attestation_token}
         when is_reference(guard_capability) and
                is_reference(attestation_token) <- attestor.(challenge),
         true <-
           valid_attestation_token?(
             attestation_token,
             guard_pid,
             guard_capability,
             guard_incarnation
           ),
         true <- Process.alive?(guard_pid) do
      true
    else
      _invalid_or_stale -> false
    end
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp valid_attestation?(_attested_guard), do: false

  defp valid_attestation_token?(
         attestation_token,
         guard_pid,
         guard_capability,
         guard_incarnation
       ) do
    :ets.info(attestation_token, :owner) == guard_pid and
      :ets.info(attestation_token, :protection) == :protected and
      :ets.lookup(attestation_token, :attestation) == [
        {:attestation, guard_capability, guard_pid, guard_incarnation}
      ] and
      :ets.info(attestation_token, :owner) == guard_pid
  rescue
    ArgumentError -> false
  end

  defp bindings_current?(state) do
    Process.alive?(state.guard_owner_pid) and
      direct_bindings_current?(state.direct_bindings) and
      local_bindings_current?(state.local_bindings) and
      global_bindings_current?(state.global_bindings, state.global_server_pid) and
      via_bindings_current?(state.via_bindings)
  end

  defp direct_bindings_current?(direct_bindings) do
    Enum.all?(direct_bindings, fn {owner_pid, expected_pid} ->
      owner_pid == expected_pid and Process.alive?(expected_pid)
    end)
  end

  defp local_bindings_current?(local_bindings) do
    Enum.all?(local_bindings, fn {name, expected_pid} ->
      Process.alive?(expected_pid) and Process.whereis(name) == expected_pid
    end)
  end

  defp global_bindings_current?(global_bindings, global_server_pid) do
    (map_size(global_bindings) == 0 or
       (is_pid(global_server_pid) and Process.alive?(global_server_pid))) and
      Enum.all?(global_bindings, fn {name, expected_pid} ->
        Process.alive?(expected_pid) and :global.whereis_name(name) == expected_pid
      end)
  end

  defp via_bindings_current?(via_bindings) do
    Enum.all?(via_bindings, fn {_owner_reference, {expected_pid, incarnation_pid}} ->
      Process.alive?(expected_pid) and Process.alive?(incarnation_pid)
    end)
  end

  defp unwrap_global_message({:"$gen_call", _from, message}), do: message
  defp unwrap_global_message({:"$gen_cast", message}), do: message
  defp unwrap_global_message(message), do: message

  defp global_authority_change?(
         {:register, name, _owner_pid, _method},
         global_bindings
       ) do
    Map.has_key?(global_bindings, name)
  end

  defp global_authority_change?({:unregister, name}, global_bindings) do
    Map.has_key?(global_bindings, name)
  end

  defp global_authority_change?(
         {:register_ext, name, _owner_pid, _method, _registration_node},
         global_bindings
       ) do
    Map.has_key?(global_bindings, name)
  end

  defp global_authority_change?(
         {:exchange_ops, _node, _tag, _operations, _resolved},
         global_bindings
       ) do
    map_size(global_bindings) > 0
  end

  defp global_authority_change?(
         {:resolved, _node, _resolved, _known, _unused, _names_ext, _tag},
         global_bindings
       ) do
    map_size(global_bindings) > 0
  end

  defp global_authority_change?(
         {:new_nodes, _node, _operations, _names_ext, _nodes, _extra_info},
         global_bindings
       ) do
    map_size(global_bindings) > 0
  end

  defp global_authority_change?(
         {:init_connect, _version, _node, _init_message},
         global_bindings
       ) do
    map_size(global_bindings) > 0
  end

  defp global_authority_change?(
         {:group_nodedown, _node, _connection_id},
         global_bindings
       ) do
    map_size(global_bindings) > 0
  end

  defp global_authority_change?(
         {:cancel_connect, _node, _tag},
         global_bindings
       ) do
    map_size(global_bindings) > 0
  end

  defp global_authority_change?(
         {:init_connect_ack, _node, _own_tag, _peer_tag},
         global_bindings
       ) do
    map_size(global_bindings) > 0
  end

  defp global_authority_change?(
         {:DOWN, _monitor_ref, :process, _pid, _reason},
         global_bindings
       ) do
    map_size(global_bindings) > 0
  end

  defp global_authority_change?(_message, _global_bindings), do: false

  defp authority_change?(
         {:DOWN, monitor_ref, :process, guard_owner_pid, _reason},
         %{
           guard_owner_monitor_ref: monitor_ref,
           guard_owner_pid: guard_owner_pid
         }
       )
       when is_reference(monitor_ref) and is_pid(guard_owner_pid),
       do: true

  defp authority_change?(
         {:trace, owner_pid, :unregister, name},
         %{local_bindings: local_bindings}
       ) do
    Map.get(local_bindings, name) == owner_pid
  end

  defp authority_change?(
         {:trace, owner_pid, :register, name},
         %{local_bindings: local_bindings}
       ) do
    Map.has_key?(local_bindings, name) and Map.get(local_bindings, name) == owner_pid
  end

  defp authority_change?(
         {:trace, global_server_pid, :receive, received_message},
         %{global_server_pid: global_server_pid} = state
       )
       when is_pid(global_server_pid) do
    received_message
    |> unwrap_global_message()
    |> global_authority_change?(state.global_bindings)
  end

  defp authority_change?(
         {:DOWN, monitor_ref, :process, global_server_pid, _reason},
         %{
           global_server_monitor_ref: monitor_ref,
           global_server_pid: global_server_pid
         }
       )
       when is_reference(monitor_ref) and is_pid(global_server_pid),
       do: true

  defp authority_change?(
         {:DOWN, monitor_ref, :process, incarnation_pid, _reason},
         %{incarnation_monitor_refs: incarnation_monitor_refs}
       ) do
    Map.get(incarnation_monitor_refs, monitor_ref) == incarnation_pid
  end

  defp authority_change?(_message, _state), do: false
end
