defmodule RacingOrg.Tracker.Pro.DesiredState.Applier do
  @moduledoc """
  Pre-validates and reconciles complete Desired State generations into their
  authoritative runtime owners.

  Every mutation is bound to the exact all-section owner PID map selected by the
  Manager. Wi-Fi is deliberately last; activation decisions, rollback authority,
  durable acknowledgements, and operational-gate transitions remain exclusively
  coordinated by the Manager.
  """

  use GenServer

  alias RacingOrg.Tracker.Pro.Calibration.Config, as: CalibrationConfig
  alias RacingOrg.Tracker.Pro.ClockSource.Config, as: ClockSourceConfig
  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.Compute.Engine
  alias RacingOrg.Tracker.Pro.DesiredState.{OwnerResolver, Store}
  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRequest
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.Tracking.Config, as: TrackingConfig
  alias RacingOrg.Tracker.Pro.Upstream.Config, as: UpstreamConfig
  alias RacingOrg.Tracker.Pro.WiFiManager
  alias RacingOrg.Tracker.Pro.WindShift.Config, as: WindShiftConfig

  @apply_order Enum.reject(Contract.sections(), &(&1 == :wifi)) ++ [:wifi]
  @reset_order @apply_order |> Enum.reject(&(&1 == :wifi)) |> Enum.reverse()
  @owner_sections MapSet.new(Contract.sections())
  @owner_resolution_timeout_ms 100

  @type pointer :: %{
          required(:storage_epoch) => binary(),
          required(:credential_epoch) => non_neg_integer(),
          required(:generation) => pos_integer(),
          required(:manifest_hash) => binary()
        }

  @type owner_pid_map :: %{required(atom()) => pid()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc "Bind privileged mutations to the exact live Manager incarnation."
  @spec register_manager(GenServer.server(), reference()) :: :ok | {:error, term()}
  def register_manager(server, manager_capability) when is_reference(manager_capability) do
    manager_pid = self()
    operation = {:register_manager, manager_capability, manager_pid}
    AuthorityRequest.call(server, manager_pid, operation, :infinity)
  end

  def register_manager(_server, _manager_capability),
    do: {:error, :invalid_applier_manager}

  @doc "Apply every non-network section to the exact Manager-selected owner PIDs."
  @spec apply_non_network(GenServer.server(), pointer(), owner_pid_map()) ::
          :ok | {:error, term()}
  def apply_non_network(server, pointer, owner_pid_map) do
    manager_call(server, {:apply_non_network, pointer, owner_pid_map}, :infinity)
  end

  @doc "Apply only the Wi-Fi section to the exact Manager-selected owner PID."
  @spec apply_wifi(GenServer.server(), pointer(), term(), owner_pid_map()) ::
          :ok | {:error, term()}
  def apply_wifi(server, pointer, wifi_secret, owner_pid_map) do
    manager_call(server, {:apply_wifi, pointer, wifi_secret, owner_pid_map}, :infinity)
  end

  @doc "Reconcile all exact owner PIDs to an already-authoritative generation."
  @spec reconcile_generation(GenServer.server(), pointer(), owner_pid_map()) ::
          {:ok, pointer()} | {:error, term()}
  def reconcile_generation(server, pointer, owner_pid_map) do
    manager_call(server, {:reconcile_generation, pointer, owner_pid_map}, :infinity)
  end

  @doc "Load and pre-validate every section against the exact owner PID set."
  @spec validate_generation(GenServer.server(), pointer(), term(), owner_pid_map()) ::
          :ok | {:error, term()}
  def validate_generation(server, pointer, wifi_secret, owner_pid_map) do
    manager_call(server, {:validate_generation, pointer, wifi_secret, owner_pid_map}, 5_000)
  end

  @doc "Durably reset the exact non-network owner PIDs to compile-time defaults."
  @spec reset_to_compile_default(GenServer.server(), owner_pid_map()) ::
          :ok | {:error, term()}
  def reset_to_compile_default(server, owner_pid_map) do
    manager_call(server, {:reset_to_compile_default, owner_pid_map}, :infinity)
  end

  @doc "Return the configured authoritative owner references for process monitoring."
  @spec owners(GenServer.server()) :: map()
  def owners(server \\ __MODULE__), do: GenServer.call(server, :owners)

  defp manager_call(server, operation, timeout) do
    manager_pid = self()

    case AuthorityRequest.call(server, manager_pid, operation, timeout) do
      {:error, :invalid_authority_principal} -> {:error, :invalid_applier_manager}
      result -> result
    end
  end

  @impl true
  def init(opts) do
    owners = Keyword.get(opts, :owners, default_owners())
    adapters = Keyword.get(opts, :adapters, default_adapters())
    manager_pid = Keyword.get(opts, :manager_pid)

    manager_monitor_ref =
      if is_pid(manager_pid), do: Process.monitor(manager_pid), else: nil

    {:ok,
     %{
       store: Keyword.fetch!(opts, :store),
       owners: owners,
       adapters: adapters,
       manager_reference:
         Keyword.get(
           opts,
           :manager,
           RacingOrg.Tracker.Pro.DesiredState.Manager
         ),
       manager_capability: Keyword.fetch!(opts, :manager_capability),
       manager_pid: manager_pid,
       manager_monitor_ref: manager_monitor_ref,
       owner_resolution_timeout_ms: Keyword.get(opts, :owner_resolution_timeout_ms, @owner_resolution_timeout_ms)
     }}
  end

  @impl true
  def format_status(status), do: WiFiManager.Secret.redact(status)

  @impl true
  def handle_call(
        {:authority_request, manager_pid, request_token,
         {:register_manager, manager_capability, manager_pid} = operation},
        _from,
        state
      ) do
    with true <- AuthorityRequest.valid?(request_token, manager_pid, operation),
         :ok <- authorize_manager_registration(state, manager_pid, manager_capability) do
      {:reply, :ok, pin_manager(state, manager_pid)}
    else
      _invalid_or_unauthorized -> {:reply, {:error, :invalid_applier_manager}, state}
    end
  end

  def handle_call(
        {:authority_request, manager_pid, request_token, {:apply_non_network, pointer, owner_pid_map} = operation},
        _from,
        state
      ) do
    result =
      with_authorized_manager(state, manager_pid, request_token, operation, fn ->
        with_expected_owner_pids(state, owner_pid_map, manager_pid, fn ->
          apply_pointer_sections(
            state,
            pointer,
            Enum.reject(@apply_order, &(&1 == :wifi)),
            nil,
            owner_pid_map,
            manager_pid
          )
        end)
      end)

    {:reply, result, state}
  end

  def handle_call(
        {:authority_request, manager_pid, request_token,
         {:apply_wifi, pointer, wifi_secret, owner_pid_map} = operation},
        _from,
        state
      ) do
    result =
      with_authorized_manager(state, manager_pid, request_token, operation, fn ->
        with_expected_owner_pids(state, owner_pid_map, manager_pid, fn ->
          apply_pointer_sections(
            state,
            pointer,
            [:wifi],
            wifi_secret,
            owner_pid_map,
            manager_pid
          )
        end)
      end)

    {:reply, result, state}
  end

  def handle_call(
        {:authority_request, manager_pid, request_token, {:reconcile_generation, pointer, owner_pid_map} = operation},
        _from,
        state
      ) do
    result =
      with_authorized_manager(state, manager_pid, request_token, operation, fn ->
        with_expected_owner_pids(state, owner_pid_map, manager_pid, fn ->
          reconcile_pointer(
            state,
            pointer,
            :reconcile,
            nil,
            owner_pid_map,
            manager_pid
          )
        end)
      end)

    {:reply, result, state}
  end

  def handle_call(
        {:authority_request, manager_pid, request_token,
         {:validate_generation, pointer, wifi_secret, owner_pid_map} = operation},
        _from,
        state
      ) do
    result =
      with_authorized_manager(state, manager_pid, request_token, operation, fn ->
        with_expected_owner_pids(state, owner_pid_map, manager_pid, fn ->
          validate_pointer(state, pointer, wifi_secret, owner_pid_map, manager_pid)
        end)
      end)

    {:reply, result, state}
  end

  def handle_call(
        {:authority_request, manager_pid, request_token, {:reset_to_compile_default, owner_pid_map} = operation},
        _from,
        state
      ) do
    result =
      with_authorized_manager(state, manager_pid, request_token, operation, fn ->
        with_expected_owner_pids(state, owner_pid_map, manager_pid, fn ->
          reset_owners(state, owner_pid_map, manager_pid)
        end)
      end)

    {:reply, result, state}
  end

  def handle_call({:register_manager, _manager_capability, _manager_pid}, _from, state),
    do: {:reply, {:error, :invalid_applier_manager}, state}

  def handle_call({:apply_non_network, _pointer, _owner_pid_map}, _from, state),
    do: {:reply, {:error, :invalid_applier_manager}, state}

  def handle_call({:apply_wifi, _pointer, _wifi_secret, _owner_pid_map}, _from, state),
    do: {:reply, {:error, :invalid_applier_manager}, state}

  def handle_call({:reconcile_generation, _pointer, _owner_pid_map}, _from, state),
    do: {:reply, {:error, :invalid_applier_manager}, state}

  def handle_call({:validate_generation, _pointer, _wifi_secret, _owner_pid_map}, _from, state),
    do: {:reply, {:error, :invalid_applier_manager}, state}

  def handle_call({:reset_to_compile_default, _owner_pid_map}, _from, state),
    do: {:reply, {:error, :invalid_applier_manager}, state}

  def handle_call(:owners, _from, state), do: {:reply, state.owners, state}

  @impl true
  def handle_info(
        {:DOWN, monitor_ref, :process, manager_pid, _reason},
        %{manager_monitor_ref: monitor_ref, manager_pid: manager_pid} = state
      ) do
    {:noreply, %{state | manager_pid: nil, manager_monitor_ref: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp apply_pointer_sections(
         state,
         pointer,
         names,
         wifi_secret,
         owner_pid_map,
         manager_pid
       ) do
    with :ok <- ensure_manager_current(state, manager_pid),
         {:ok, generation} <- load_pointer(state.store, pointer),
         :ok <-
           normalize_apply_result(
             apply_sections(
               state,
               generation,
               pointer,
               wifi_secret,
               :candidate,
               names,
               owner_pid_map,
               manager_pid
             )
           ),
         :ok <- ensure_manager_current(state, manager_pid) do
      :ok
    end
  end

  defp validate_pointer(state, pointer, wifi_secret, owner_pid_map, manager_pid) do
    with :ok <- ensure_manager_current(state, manager_pid),
         {:ok, generation} <- load_pointer(state.store, pointer),
         :ok <-
           validate_sections(
             state,
             generation,
             pointer,
             wifi_secret,
             :candidate,
             owner_pid_map,
             manager_pid
           ),
         :ok <- ensure_manager_current(state, manager_pid) do
      :ok
    end
  end

  defp reconcile_pointer(
         state,
         pointer,
         mode,
         wifi_secret,
         owner_pid_map,
         manager_pid
       ) do
    with :ok <- ensure_manager_current(state, manager_pid),
         {:ok, generation} <- load_pointer(state.store, pointer),
         :ok <-
           validate_sections(
             state,
             generation,
             pointer,
             wifi_secret,
             mode,
             owner_pid_map,
             manager_pid
           ),
         :ok <-
           normalize_apply_result(
             apply_sections(
               state,
               generation,
               pointer,
               wifi_secret,
               mode,
               @apply_order,
               owner_pid_map,
               manager_pid
             )
           ),
         :ok <- ensure_manager_current(state, manager_pid) do
      {:ok, pointer}
    end
  end

  defp reset_owners(state, owner_pid_map, manager_pid) do
    failures =
      Enum.reduce(@reset_order, [], fn name, failures ->
        result =
          with :ok <- ensure_manager_current(state, manager_pid),
               {:ok, adapter} <- Map.fetch(state.adapters, name),
               reset when is_function(reset, 1) <- Map.get(adapter, :reset),
               {:ok, owner_pid} <- Map.fetch(owner_pid_map, name),
               :ok <- call_reset_adapter(reset, owner_pid),
               :ok <- ensure_manager_current(state, manager_pid) do
            :ok
          else
            :error -> {:error, :missing_adapter}
            nil -> {:error, :missing_reset_callback}
            {:error, _reason} = error -> error
            _other -> {:error, :missing_reset_callback}
          end

        case result do
          :ok -> failures
          {:error, reason} -> failures ++ [{name, reason}]
        end
      end)

    case failures do
      [] -> :ok
      failures -> {:error, {:reset_failed, failures}}
    end
  end

  defp call_reset_adapter(fun, owner_pid) do
    fun.(%{mode: :reset, activation_id: nil, wifi_secret: nil, owner_pid: owner_pid})
    |> normalize_owner_result()
  rescue
    _error -> {:error, :owner_exception}
  catch
    _kind, _reason -> {:error, :owner_exit}
  end

  defp load_pointer(store, pointer) when is_map(pointer) do
    generation = Map.get(pointer, :generation)
    manifest_hash = Map.get(pointer, :manifest_hash)

    with :ok <- validate_pointer_shape(store, pointer),
         {:ok, loaded} <- Store.load_generation(store, generation, manifest_hash),
         true <- loaded.manifest.credential_epoch == Map.get(pointer, :credential_epoch) do
      {:ok, loaded}
    else
      false -> {:error, :credential_epoch_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp load_pointer(_store, _pointer), do: {:error, :invalid_generation_pointer}

  defp validate_pointer_shape(store, pointer) do
    cond do
      Map.get(pointer, :storage_epoch) != store.storage_epoch ->
        {:error, :storage_epoch_mismatch}

      not (is_integer(Map.get(pointer, :credential_epoch)) and
               Map.get(pointer, :credential_epoch) >= 0) ->
        {:error, :invalid_generation_pointer}

      not (is_integer(Map.get(pointer, :generation)) and Map.get(pointer, :generation) > 0) ->
        {:error, :invalid_generation_pointer}

      not (is_binary(Map.get(pointer, :manifest_hash)) and
               byte_size(Map.get(pointer, :manifest_hash)) == 32) ->
        {:error, :invalid_generation_pointer}

      true ->
        :ok
    end
  end

  defp validate_sections(
         state,
         generation,
         pointer,
         wifi_secret,
         mode,
         owner_pid_map,
         manager_pid
       ) do
    Enum.reduce_while(Contract.sections(), :ok, fn name, :ok ->
      with :ok <- ensure_manager_current(state, manager_pid),
           {:ok, adapter} <- fetch_adapter(state.adapters, name),
           {:ok, section} <- Map.fetch(generation.sections, name),
           {:ok, owner_pid} <- Map.fetch(owner_pid_map, name),
           context = context(pointer, wifi_secret, mode, owner_pid),
           :ok <- call_adapter(adapter.validate, section, context),
           :ok <- ensure_manager_current(state, manager_pid) do
        {:cont, :ok}
      else
        :error -> {:halt, {:error, {:validation_failed, name, :missing_section}}}
        {:error, reason} -> {:halt, {:error, {:validation_failed, name, reason}}}
      end
    end)
  end

  defp apply_sections(
         state,
         generation,
         pointer,
         wifi_secret,
         mode,
         names,
         owner_pid_map,
         manager_pid
       ) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      with :ok <- ensure_manager_current(state, manager_pid) do
        adapter = Map.fetch!(state.adapters, name)
        section = Map.fetch!(generation.sections, name)
        owner_pid = Map.fetch!(owner_pid_map, name)
        context = context(pointer, wifi_secret, mode, owner_pid)

        case call_adapter(adapter.apply, section, context) do
          :ok ->
            case ensure_manager_current(state, manager_pid) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, name, reason}}
            end

          {:error, reason} ->
            {:halt, {:error, name, reason}}
        end
      else
        {:error, reason} -> {:halt, {:error, name, reason}}
      end
    end)
  end

  defp context(pointer, wifi_secret, mode, owner_pid) do
    %{
      mode: mode,
      activation_id: Map.fetch!(pointer, :manifest_hash),
      wifi_secret: wifi_secret,
      owner_pid: owner_pid
    }
  end

  defp fetch_adapter(adapters, name) do
    case Map.fetch(adapters, name) do
      {:ok, %{validate: validate, apply: apply_fun} = adapter}
      when is_function(validate, 2) and is_function(apply_fun, 2) ->
        {:ok, adapter}

      _other ->
        {:error, :missing_adapter}
    end
  end

  defp call_adapter(fun, section, context) do
    fun.(section, context)
    |> normalize_owner_result()
  rescue
    _error -> {:error, :owner_exception}
  catch
    _kind, _reason -> {:error, :owner_exit}
  end

  defp normalize_owner_result(:ok), do: :ok
  defp normalize_owner_result({:ok, _value}), do: :ok
  defp normalize_owner_result({:error, reason}), do: {:error, reason}
  defp normalize_owner_result(other), do: {:error, {:invalid_owner_response, other}}

  defp normalize_apply_result(:ok), do: :ok

  defp normalize_apply_result({:error, section, reason}),
    do: {:error, {:apply_failed, section, reason}}

  defp with_authorized_manager(state, manager_pid, request_token, operation, fun)
       when is_pid(manager_pid) and is_function(fun, 0) do
    with true <- AuthorityRequest.valid?(request_token, manager_pid, operation),
         :ok <- ensure_manager_current(state, manager_pid),
         result <- fun.(),
         :ok <- ensure_manager_current(state, manager_pid) do
      result
    else
      _invalid_or_stale -> {:error, :invalid_applier_manager}
    end
  end

  defp authorize_manager_registration(
         %{manager_capability: manager_capability} = state,
         manager_pid,
         manager_capability
       )
       when is_pid(manager_pid) do
    with true <- Process.alive?(manager_pid),
         ^manager_pid <- resolve_manager_reference(state.manager_reference),
         :ok <- manager_handoff_status(state.manager_pid, manager_pid),
         true <- Process.alive?(manager_pid) do
      :ok
    else
      _invalid_or_stale -> {:error, :invalid_applier_manager}
    end
  end

  defp authorize_manager_registration(_state, _manager_pid, _manager_capability),
    do: {:error, :invalid_applier_manager}

  defp manager_handoff_status(nil, manager_pid) when is_pid(manager_pid), do: :ok
  defp manager_handoff_status(manager_pid, manager_pid) when is_pid(manager_pid), do: :ok

  defp manager_handoff_status(prior_manager_pid, manager_pid)
       when is_pid(prior_manager_pid) and is_pid(manager_pid) do
    if Process.alive?(prior_manager_pid),
      do: {:error, :invalid_applier_manager},
      else: :ok
  end

  defp manager_handoff_status(_prior_manager_pid, _manager_pid),
    do: {:error, :invalid_applier_manager}

  defp pin_manager(%{manager_pid: manager_pid} = state, manager_pid), do: state

  defp pin_manager(state, manager_pid) do
    if is_reference(state.manager_monitor_ref),
      do: Process.demonitor(state.manager_monitor_ref, [:flush])

    %{
      state
      | manager_pid: manager_pid,
        manager_monitor_ref: Process.monitor(manager_pid)
    }
  end

  defp ensure_manager_current(%{manager_pid: manager_pid} = state, manager_pid)
       when is_pid(manager_pid) do
    if Process.alive?(manager_pid) and
         resolve_manager_reference(state.manager_reference) == manager_pid,
       do: :ok,
       else: {:error, :invalid_applier_manager}
  end

  defp ensure_manager_current(_state, _manager_pid),
    do: {:error, :invalid_applier_manager}

  defp resolve_manager_reference(manager_reference) do
    GenServer.whereis(manager_reference)
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp with_expected_owner_pids(state, expected_owner_pid_map, caller_pid, fun)
       when is_pid(caller_pid) and is_function(fun, 0) do
    with :ok <- validate_owner_pid_map(expected_owner_pid_map),
         {:ok, configured_owner_pid_map} <-
           resolve_owner_pids(
             state.owners,
             state.owner_resolution_timeout_ms,
             caller_pid
           ),
         true <- configured_owner_pid_map == expected_owner_pid_map,
         true <- Process.alive?(caller_pid),
         result <- fun.(),
         true <- Process.alive?(caller_pid) do
      result
    else
      false -> {:error, :owner_set_changed}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_owner_pids(owners, timeout_ms, caller_pid) when is_map(owners) do
    if MapSet.new(Map.keys(owners)) == @owner_sections do
      owner_references = owners |> Map.values() |> Enum.uniq()

      with {:ok, resolved_by_reference} <-
             OwnerResolver.resolve(owner_references,
               timeout_ms: timeout_ms,
               cancel_on: caller_pid
             ),
           true <- resolved_owner_references_alive?(resolved_by_reference) do
        {:ok,
         Map.new(owners, fn {section, owner_reference} ->
           {section, Map.fetch!(resolved_by_reference, owner_reference)}
         end)}
      else
        false -> {:error, :owner_unavailable}
        {:error, _reason} = error -> error
      end
    else
      {:error, :incomplete_owner_resolver}
    end
  rescue
    _exception -> {:error, :owner_resolver_failed}
  catch
    _kind, _reason -> {:error, :owner_resolver_failed}
  end

  defp resolve_owner_pids(_owners, _timeout_ms, _caller_pid),
    do: {:error, :invalid_owner_resolver}

  defp resolved_owner_references_alive?(resolved_by_reference) do
    Enum.all?(resolved_by_reference, fn {_owner_reference, owner_pid} ->
      is_pid(owner_pid) and Process.alive?(owner_pid)
    end)
  end

  defp validate_owner_pid_map(owner_pid_map) when is_map(owner_pid_map) do
    cond do
      MapSet.new(Map.keys(owner_pid_map)) != @owner_sections ->
        {:error, :incomplete_owner_pid_map}

      Enum.all?(Map.values(owner_pid_map), &(is_pid(&1) and Process.alive?(&1))) ->
        :ok

      true ->
        {:error, :owner_unavailable}
    end
  end

  defp validate_owner_pid_map(_owner_pid_map), do: {:error, :invalid_owner_pid_map}

  defp default_owners do
    %{
      assignment: Commands,
      calibration: CalibrationConfig,
      clock_source: ClockSourceConfig,
      computed_values: Engine,
      polar: Commands,
      tracking: TrackingConfig,
      upstream: UpstreamConfig,
      wifi: WiFiManager,
      wind_shift: WindShiftConfig
    }
  end

  defp default_adapters do
    %{
      assignment: command_adapter(:assignment),
      calibration: config_adapter(CalibrationConfig),
      clock_source: config_adapter(ClockSourceConfig),
      computed_values: config_adapter(Engine),
      polar: command_adapter(:polar),
      tracking: config_adapter(TrackingConfig),
      upstream: config_adapter(UpstreamConfig),
      wifi: wifi_adapter(),
      wind_shift: config_adapter(WindShiftConfig)
    }
  end

  defp config_adapter(module) do
    %{
      validate: fn section, _context ->
        if section.tombstone do
          {:error, :unexpected_tombstone}
        else
          apply(module, :validate_config, [section.content])
        end
      end,
      apply: fn section, context ->
        if section.tombstone do
          {:error, :unexpected_tombstone}
        else
          apply(module, :reconcile_config, [context.owner_pid, section.content])
        end
      end,
      reset: fn context -> apply(module, :reset_config, [context.owner_pid]) end
    }
  end

  defp command_adapter(:assignment) do
    %{
      validate: fn section, _context ->
        if section.tombstone, do: :ok, else: Commands.validate_assignment(section.content)
      end,
      apply: fn section, context ->
        if section.tombstone,
          do: Commands.clear_assignment(context.owner_pid),
          else: Commands.reconcile_assignment(context.owner_pid, section.content)
      end,
      reset: fn context -> Commands.clear_assignment(context.owner_pid) end
    }
  end

  defp command_adapter(:polar) do
    %{
      validate: fn section, _context ->
        if section.tombstone, do: :ok, else: Commands.validate_polar(section.content)
      end,
      apply: fn section, context ->
        if section.tombstone,
          do: Commands.clear_polar(context.owner_pid),
          else: Commands.reconcile_polar(context.owner_pid, section.content)
      end,
      reset: fn context -> Commands.clear_polar(context.owner_pid) end
    }
  end

  defp wifi_adapter do
    %{
      validate: fn section, context -> validate_wifi(section, context) end,
      apply: fn section, context -> apply_wifi_section(section, context) end
    }
  end

  defp validate_wifi(%{tombstone: true}, _context), do: :ok

  defp validate_wifi(%{content: content}, %{mode: :candidate, wifi_secret: secret}) do
    with {:ok, public} <- WiFiManager.validate_desired_config(content),
         :ok <- validate_candidate_wifi_secret(public, secret) do
      :ok
    end
  end

  defp validate_wifi(%{content: content}, _context) do
    case WiFiManager.validate_desired_config(content) do
      {:ok, _public} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_candidate_wifi_secret(%{enabled: true}, %WiFiManager.Secret{}), do: :ok
  defp validate_candidate_wifi_secret(%{enabled: true}, _secret), do: {:error, :wifi_secret_required}
  defp validate_candidate_wifi_secret(%{enabled: false}, _secret), do: :ok

  defp apply_wifi_section(section, %{mode: :candidate} = context) do
    if section.tombstone do
      WiFiManager.apply_desired_tombstone(context.owner_pid, context.activation_id)
    else
      WiFiManager.trial_config(
        context.owner_pid,
        section.content,
        context.wifi_secret,
        context.activation_id
      )
    end
  end

  defp apply_wifi_section(_section, context) do
    WiFiManager.reconcile_desired_activation(context.owner_pid, context.activation_id)
  end
end
