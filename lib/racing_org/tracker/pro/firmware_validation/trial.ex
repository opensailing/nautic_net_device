defmodule RacingOrg.Tracker.Pro.FirmwareValidation.Trial do
  @moduledoc """
  Supervised, restart-safe controller for an OTA firmware health trial.

  The controller evaluates `HealthCriteria` on a nonnegative boot-relative
  monotonic clock, requires one uninterrupted healthy soak, and retries until a
  terminal deadline. It persists only the sanitized `DiagnosticsStore` record.
  A validation decision is durably committed before firmware validity changes;
  recovery proves existing validity or retries exact validation before any
  bounded rollback. A rollback decision is likewise committed before partition
  reversion, and a second durable phase records passive reversion before reboot.
  """

  use GenServer

  alias RacingOrg.Tracker.Pro.FirmwareValidation.DiagnosticsStore
  alias RacingOrg.Tracker.Pro.FirmwareValidation.HealthCriteria
  alias RacingOrg.Tracker.Pro.FirmwareValidation.Snapshot
  alias RacingOrg.Tracker.Pro.FirmwareValidator

  @max_u64 0xFFFF_FFFF_FFFF_FFFF
  @default_retry_ms 1_000
  @phases [:monitoring, :validation_decided, :validated, :rollback_decided, :reboot_pending]
  @effect_statuses [
    nil,
    :runtime_unavailable,
    :validation_failed,
    :validation_uncertain,
    :revert_failed,
    :reboot_failed,
    :reboot_requested
  ]
  @invalid_snapshot [%{criterion: :input, diagnostic_code: :invalid_snapshot}]

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc "Starts an OTA health trial process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.put_new_lazy(opts, :clock, &boot_relative_clock/0)

    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc "Requests an immediate health evaluation, cancelling the outstanding retry timer."
  @spec check_now(GenServer.server()) :: :ok | {:error, term()}
  def check_now(server \\ __MODULE__), do: GenServer.call(server, :check_now, :infinity)

  @doc "Returns the sanitized current trial status."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    with {:ok, target_identity, initial_deadline_at_ms} <- validate_target(Keyword.fetch!(opts, :target)),
         :ok <- ensure_validation_available(opts),
         {:ok, now_ms} <- read_clock(Keyword.fetch!(opts, :clock)),
         {:ok, state} <- initial_state(opts, target_identity, initial_deadline_at_ms, now_ms) do
      {:ok, state, {:continue, :resume}}
    else
      {:error, reason} -> {:stop, reason}
    end
  rescue
    _exception -> {:stop, :invalid_trial_options}
  catch
    _kind, _reason -> {:stop, :invalid_trial_options}
  end

  @impl true
  def handle_continue(:resume, %{phase: :validated} = state), do: {:noreply, state}

  def handle_continue(:resume, %{phase: :validation_decided} = state) do
    case reestablish_recovered_record(state) do
      {:ok, state} -> state |> run_validation_effect() |> noreply_result()
      {:stop, reason, state} -> {:stop, reason, state}
    end
  end

  def handle_continue(:resume, %{phase: phase} = state)
      when phase in [:rollback_decided, :reboot_pending] do
    case reestablish_recovered_record(state) do
      {:ok, state} -> state |> enforce_rollback() |> noreply_result()
      {:stop, reason, state} -> {:stop, reason, state}
    end
  end

  def handle_continue(:resume, state) do
    state
    |> run_check()
    |> noreply_result()
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call(:check_now, _from, %{phase: :validated} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:check_now, _from, state) do
    state = cancel_timer(state)

    result =
      case state.phase do
        :monitoring -> run_check(state)
        :validation_decided -> run_validation_effect(state)
        _rollback_phase -> enforce_rollback(state)
      end

    case result do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:stop, reason, next_state} -> {:stop, reason, {:error, reason}, next_state}
    end
  end

  @impl true
  def handle_info({:trial_check, token}, %{timer_token: token, phase: :monitoring} = state) do
    state
    |> clear_timer()
    |> run_check()
    |> noreply_result()
  end

  def handle_info({:validation_effect, token}, %{timer_token: token, phase: :validation_decided} = state) do
    state
    |> clear_timer()
    |> run_validation_effect()
    |> noreply_result()
  end

  def handle_info({:rollback_effect, token}, %{timer_token: token} = state) do
    state
    |> clear_timer()
    |> enforce_rollback()
    |> noreply_result()
  end

  def handle_info({kind, _stale_token}, state)
      when kind in [:trial_check, :validation_effect, :rollback_effect],
      do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status) when is_map(status) do
    %{
      state: format_state(Map.get(status, :state)),
      message: :redacted,
      reason: :redacted,
      log: :redacted
    }
  end

  def format_status(_status), do: %{state: :redacted, message: :redacted, reason: :redacted, log: :redacted}

  defp initial_state(opts, target_identity, initial_deadline_at_ms, now_ms) do
    store_dir = Keyword.fetch!(opts, :store_dir)
    store_opts = Keyword.get(opts, :store_opts, [])

    base = %{
      store_dir: store_dir,
      store_opts: store_opts,
      target_identity: target_identity,
      phase: :monitoring,
      result: {:pending, @invalid_snapshot},
      remaining_deadline_ms: max(initial_deadline_at_ms - now_ms, 0),
      healthy_since_ms: nil,
      healthy_for_ms: 0,
      last_now_ms: now_ms,
      retry_ms: positive_milliseconds(Keyword.get(opts, :retry_ms, @default_retry_ms)),
      clock: Keyword.fetch!(opts, :clock),
      snapshot_opts: Keyword.get(opts, :snapshot_opts, []),
      status_fun: Keyword.get(opts, :status_fun),
      validate_fun: Keyword.get(opts, :validate_fun),
      runtime_module: Keyword.get(opts, :runtime_module, Nerves.Runtime),
      revert_fun: Keyword.get(opts, :revert_fun),
      reboot_fun: Keyword.get(opts, :reboot_fun),
      schedule_fun: Keyword.get(opts, :schedule_fun, &default_schedule/2),
      cancel_timer_fun: Keyword.get(opts, :cancel_timer_fun, &default_cancel_timer/1),
      timer_ref: nil,
      timer_token: nil,
      effect_status: nil,
      recovery_record: nil,
      health_event_sink: Keyword.get(opts, :health_event_sink),
      health_event_context: Keyword.get(opts, :health_event_context, %{}),
      last_health_event: nil
    }

    case DiagnosticsStore.load(store_dir, store_opts) do
      :empty -> initialize_new_record(base)
      {:ok, %{target: ^target_identity} = record} -> {:ok, recover_record(base, record)}
      {:ok, _different_target} -> initialize_new_record(base)
      {:error, reason} -> {:error, {:diagnostics_unavailable, reason}}
    end
  end

  defp initialize_new_record(state) do
    case persist_record(state, :monitoring, state.result, state.remaining_deadline_ms) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, {:diagnostics_persist_failed, reason}}
    end
  end

  defp recover_record(state, record) do
    recovery_record =
      if record.phase in [:validation_decided, :rollback_decided, :reboot_pending],
        do: record,
        else: nil

    %{
      state
      | phase: record.phase,
        result: record.result,
        remaining_deadline_ms: record.timing.remaining_deadline_ms,
        healthy_since_ms: nil,
        healthy_for_ms: 0,
        recovery_record: recovery_record
    }
  end

  defp reestablish_recovered_record(%{recovery_record: nil} = state), do: {:ok, state}

  defp reestablish_recovered_record(%{recovery_record: record} = state) do
    case DiagnosticsStore.save(state.store_dir, record, state.store_opts) do
      :ok -> {:ok, %{state | recovery_record: nil}}
      {:error, reason} -> {:stop, {:diagnostics_persist_failed, reason}, state}
    end
  end

  defp run_check(%{phase: :monitoring} = state) do
    with {:ok, now_ms} <- read_clock(state.clock) do
      if now_ms < state.last_now_ms do
        state
        |> Map.merge(%{
          remaining_deadline_ms: 0,
          healthy_since_ms: nil,
          healthy_for_ms: 0,
          last_now_ms: now_ms,
          result: {:rollback_required, @invalid_snapshot}
        })
        |> decide_rollback({:rollback_required, @invalid_snapshot})
      else
        evaluate_at(state, now_ms)
      end
    else
      {:error, _reason} ->
        state
        |> Map.merge(%{
          remaining_deadline_ms: 0,
          healthy_since_ms: nil,
          healthy_for_ms: 0,
          result: {:rollback_required, @invalid_snapshot}
        })
        |> decide_rollback({:rollback_required, @invalid_snapshot})
    end
  end

  defp evaluate_at(state, now_ms) do
    elapsed_ms = now_ms - state.last_now_ms
    remaining_ms = max(state.remaining_deadline_ms - elapsed_ms, 0)
    deadline_at_ms = saturating_add(now_ms, remaining_ms)
    soak_started_at_ms = state.healthy_since_ms || now_ms

    snapshot =
      Snapshot.build(
        %{observed_at_ms: now_ms, soak_started_at_ms: soak_started_at_ms},
        state.snapshot_opts
      )

    target = Map.put(state.target_identity, :deadline_at_ms, deadline_at_ms)
    result = HealthCriteria.evaluate(snapshot, target)
    healthy_since_ms = next_healthy_since(state.healthy_since_ms, now_ms, result)
    healthy_for_ms = healthy_duration(healthy_since_ms, now_ms)

    state = %{
      state
      | result: result,
        remaining_deadline_ms: remaining_ms,
        healthy_since_ms: healthy_since_ms,
        healthy_for_ms: healthy_for_ms,
        last_now_ms: now_ms,
        effect_status: nil
    }

    case result do
      {:pending, unmet} ->
        state
        |> emit_health_event(:validation_pending, pending_reason(unmet))
        |> persist_monitoring_and_schedule()

      {:rollback_required, _unmet} ->
        decide_rollback(state, result)

      :ready ->
        attempt_validation(state)
    end
  end

  defp attempt_validation(state) do
    state = %{
      cancel_timer(state)
      | phase: :validation_decided,
        result: :ready,
        effect_status: nil
    }

    case persist_record(state, :validation_decided, :ready, state.remaining_deadline_ms) do
      :ok -> enforce_validation(state)
      {:error, reason} -> {:stop, {:diagnostics_persist_failed, reason}, state}
    end
  end

  defp enforce_validation(%{phase: :validation_decided} = state) do
    case firmware_validation(state) do
      result when result in [:validated, :already_valid] ->
        persist_validated(state)

      :unavailable ->
        state = %{cancel_timer(state) | effect_status: :runtime_unavailable}
        {:stop, :firmware_validation_unavailable, state}

      _failure ->
        handle_validation_failure(state)
    end
  end

  defp handle_validation_failure(state) do
    case firmware_status(state) do
      :valid ->
        persist_validated(state)

      :invalid when state.remaining_deadline_ms > 0 ->
        persist_validation_failure_and_schedule(state)

      :invalid ->
        decide_rollback(state, {:rollback_required, @invalid_snapshot})

      :uncertain ->
        persist_validation_uncertainty_and_schedule(state)
    end
  end

  defp persist_validated(state) do
    case persist_record(state, :validated, :ready, state.remaining_deadline_ms) do
      :ok ->
        state = emit_health_event(state, :validation_succeeded, nil)
        {:ok, %{cancel_timer(state) | phase: :validated, result: :ready, effect_status: nil}}

      {:error, reason} ->
        {:stop, {:diagnostics_persist_failed, reason}, state}
    end
  end

  defp run_validation_effect(%{effect_status: effect_status} = state)
       when effect_status in [:validation_failed, :validation_uncertain] do
    case read_clock(state.clock) do
      {:ok, now_ms} when now_ms >= state.last_now_ms ->
        elapsed_ms = now_ms - state.last_now_ms

        state
        |> Map.merge(%{
          remaining_deadline_ms: max(state.remaining_deadline_ms - elapsed_ms, 0),
          last_now_ms: now_ms
        })
        |> enforce_validation()

      {:ok, now_ms} ->
        state
        |> Map.merge(%{remaining_deadline_ms: 0, last_now_ms: now_ms})
        |> enforce_validation()

      {:error, _reason} ->
        state
        |> Map.put(:remaining_deadline_ms, 0)
        |> enforce_validation()
    end
  end

  defp run_validation_effect(state), do: enforce_validation(state)

  defp persist_validation_failure_and_schedule(state) do
    state =
      state
      |> Map.put(:effect_status, :validation_failed)
      |> emit_health_event(:validation_failed, :firmware_validation_failed)
      |> anchor_validation_retry_clock()

    if state.remaining_deadline_ms > 0 do
      delay_ms = min(state.retry_ms, state.remaining_deadline_ms)
      recoverable_remaining_ms = max(state.remaining_deadline_ms - delay_ms, 0)

      case persist_record(state, :validation_decided, :ready, recoverable_remaining_ms) do
        :ok -> schedule(state, :validation_effect, delay_ms)
        {:error, reason} -> {:stop, {:diagnostics_persist_failed, reason}, state}
      end
    else
      decide_rollback(state, {:rollback_required, @invalid_snapshot})
    end
  end

  defp persist_validation_uncertainty_and_schedule(state) do
    state =
      state
      |> Map.put(:effect_status, :validation_uncertain)
      |> emit_health_event(:validation_failed, :firmware_validation_uncertain)
      |> anchor_validation_retry_clock()

    if state.remaining_deadline_ms > 0 do
      delay_ms = min(state.retry_ms, state.remaining_deadline_ms)
      recoverable_remaining_ms = max(state.remaining_deadline_ms - delay_ms, 0)

      case persist_record(state, :validation_decided, :ready, recoverable_remaining_ms) do
        :ok -> schedule(state, :validation_effect, delay_ms)
        {:error, reason} -> {:stop, {:diagnostics_persist_failed, reason}, state}
      end
    else
      decide_rollback(state, {:rollback_required, @invalid_snapshot})
    end
  end

  defp anchor_validation_retry_clock(state) do
    case read_clock(state.clock) do
      {:ok, now_ms} when now_ms >= state.last_now_ms -> %{state | last_now_ms: now_ms}
      _untrusted_clock -> %{state | remaining_deadline_ms: 0}
    end
  end

  defp persist_monitoring_and_schedule(state) do
    delay_ms = min(state.retry_ms, state.remaining_deadline_ms)
    recoverable_remaining_ms = max(state.remaining_deadline_ms - delay_ms, 0)

    case persist_record(state, :monitoring, state.result, recoverable_remaining_ms) do
      :ok -> schedule(state, :trial_check, delay_ms)
      {:error, reason} -> {:stop, {:diagnostics_persist_failed, reason}, state}
    end
  end

  defp decide_rollback(state, result) do
    state = %{
      cancel_timer(state)
      | phase: :rollback_decided,
        result: result,
        remaining_deadline_ms: 0,
        effect_status: nil
    }

    state = emit_health_event(state, :rollback_deadline_expired, :rollback_deadline_expired)

    case persist_record(state, :rollback_decided, result, 0) do
      :ok -> enforce_rollback(state)
      {:error, reason} -> {:stop, {:diagnostics_persist_failed, reason}, state}
    end
  end

  defp enforce_rollback(%{phase: :rollback_decided} = state) do
    case rollback_effect(state.revert_fun, state.runtime_module, :revert) do
      :ok ->
        state = %{state | phase: :reboot_pending, effect_status: nil}

        case persist_record(state, :reboot_pending, state.result, 0) do
          :ok -> enforce_rollback(state)
          {:error, reason} -> {:stop, {:diagnostics_persist_failed, reason}, state}
        end

      {:error, :nerves_runtime_unavailable} ->
        state
        |> Map.put(:effect_status, :runtime_unavailable)
        |> schedule(:rollback_effect, state.retry_ms)

      {:error, :effect_failed} ->
        state
        |> Map.put(:effect_status, :revert_failed)
        |> schedule(:rollback_effect, state.retry_ms)
    end
  end

  defp enforce_rollback(%{phase: :reboot_pending} = state) do
    case rollback_effect(state.reboot_fun, state.runtime_module, :reboot) do
      :ok ->
        {:ok, %{state | effect_status: :reboot_requested}}

      {:error, :nerves_runtime_unavailable} ->
        state
        |> Map.put(:effect_status, :runtime_unavailable)
        |> schedule(:rollback_effect, state.retry_ms)

      {:error, :effect_failed} ->
        state
        |> Map.put(:effect_status, :reboot_failed)
        |> schedule(:rollback_effect, state.retry_ms)
    end
  end

  defp firmware_validation(state) do
    [runtime_module: state.runtime_module]
    |> maybe_put_validator_option(:firmware_valid?, state.status_fun, &safe_status/1)
    |> maybe_put_validator_option(:validate, state.validate_fun, &safe_validate/1)
    |> FirmwareValidator.validate_on_connect()
  end

  defp firmware_status(%{status_fun: fun}) when is_function(fun, 0), do: exact_firmware_status(fun)

  defp firmware_status(state) do
    exact_firmware_status(fn -> apply(state.runtime_module, :firmware_valid?, []) end)
  end

  defp exact_firmware_status(fun) do
    case fun.() do
      true -> :valid
      false -> :invalid
      _other -> :uncertain
    end
  rescue
    _exception -> :uncertain
  catch
    _kind, _reason -> :uncertain
  end

  defp ensure_validation_available(opts) do
    [runtime_module: Keyword.get(opts, :runtime_module, Nerves.Runtime)]
    |> maybe_put_validator_option(:firmware_valid?, Keyword.get(opts, :status_fun), &Function.identity/1)
    |> maybe_put_validator_option(:validate, Keyword.get(opts, :validate_fun), &Function.identity/1)
    |> FirmwareValidator.validation_available?()
    |> case do
      true -> :ok
      false -> {:error, :firmware_validation_unavailable}
    end
  end

  defp maybe_put_validator_option(opts, _key, nil, _wrapper), do: opts

  defp maybe_put_validator_option(opts, key, fun, wrapper) when is_function(fun, 0) do
    Keyword.put(opts, key, fn -> wrapper.(fun) end)
  end

  defp maybe_put_validator_option(opts, _key, _invalid, _wrapper), do: opts

  defp safe_status(fun) do
    case fun.() do
      true -> true
      _other -> false
    end
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp safe_validate(fun) do
    case fun.() do
      :ok -> :ok
      _other -> :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp rollback_effect(nil, runtime_module, operation), do: runtime_call(runtime_module, operation)

  defp rollback_effect(fun, _runtime_module, _operation) when is_function(fun, 0) do
    case fun.() do
      :ok -> :ok
      {:error, :nerves_runtime_unavailable} -> {:error, :nerves_runtime_unavailable}
      _other -> {:error, :effect_failed}
    end
  rescue
    _exception -> {:error, :effect_failed}
  catch
    _kind, _reason -> {:error, :effect_failed}
  end

  defp rollback_effect(_invalid, _runtime_module, _operation), do: {:error, :effect_failed}

  defp runtime_call(runtime_module, :revert) do
    runtime_call(runtime_module, :revert, 1, [[reboot: false]])
  end

  defp runtime_call(runtime_module, :reboot) do
    runtime_call(runtime_module, :reboot, 0, [])
  end

  defp runtime_call(runtime_module, operation, arity, arguments) do
    if Code.ensure_loaded?(runtime_module) and function_exported?(runtime_module, operation, arity) do
      case apply(runtime_module, operation, arguments) do
        :ok -> :ok
        _other -> {:error, :effect_failed}
      end
    else
      {:error, :nerves_runtime_unavailable}
    end
  rescue
    _exception -> {:error, :effect_failed}
  catch
    _kind, _reason -> {:error, :effect_failed}
  end

  defp persist_record(state, phase, result, remaining_deadline_ms) do
    DiagnosticsStore.save(
      state.store_dir,
      %{
        phase: phase,
        result: result,
        timing: %{
          remaining_deadline_ms: remaining_deadline_ms,
          healthy_for_ms: state.healthy_for_ms
        },
        target: state.target_identity
      },
      state.store_opts
    )
  end

  defp schedule(state, kind, delay_ms) do
    state = cancel_timer(state)
    token = make_ref()
    message = {kind, token}

    case safe_schedule(state.schedule_fun, message, delay_ms) do
      {:ok, timer_ref} -> {:ok, %{state | timer_ref: timer_ref, timer_token: token}}
      {:error, reason} -> {:stop, {:timer_schedule_failed, reason}, state}
    end
  end

  defp safe_schedule(fun, message, delay_ms) do
    {:ok, fun.(message, delay_ms)}
  rescue
    _exception -> {:error, :schedule_failed}
  catch
    _kind, _reason -> {:error, :schedule_failed}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(state) do
    _result = safe_cancel_timer(state.cancel_timer_fun, state.timer_ref)
    clear_timer(state)
  end

  defp safe_cancel_timer(fun, timer_ref) do
    fun.(timer_ref)
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp clear_timer(state), do: %{state | timer_ref: nil, timer_token: nil}

  defp next_healthy_since(current, now_ms, :ready), do: current || now_ms

  defp next_healthy_since(current, now_ms, {:pending, unmet}) do
    if Enum.all?(unmet, &(&1 == %{criterion: :soak_period, diagnostic_code: :soak_period_incomplete})) do
      current || now_ms
    else
      nil
    end
  end

  defp next_healthy_since(_current, _now_ms, {:rollback_required, _unmet}), do: nil

  defp healthy_duration(nil, _now_ms), do: 0
  defp healthy_duration(started_at_ms, now_ms), do: max(now_ms - started_at_ms, 0)

  defp validate_target(target) do
    case HealthCriteria.evaluate(%{timing: %{observed_at_ms: 0, soak_started_at_ms: 0}}, target) do
      {:rollback_required, [%{criterion: :input, diagnostic_code: :invalid_target}]} ->
        {:error, :invalid_target}

      _valid_target_result ->
        {:ok, Map.delete(target, :deadline_at_ms), target.deadline_at_ms}
    end
  rescue
    _exception -> {:error, :invalid_target}
  catch
    _kind, _reason -> {:error, :invalid_target}
  end

  # Durable health evidence is best-effort observation: an event is emitted only
  # on a (type, reason) transition, and neither sink nor context faults may ever
  # disturb the trial's validation or rollback decisions.
  defp emit_health_event(%{health_event_sink: nil} = state, _event_type, _reason_code), do: state

  defp emit_health_event(state, event_type, reason_code) do
    key = {event_type, reason_code}

    if state.last_health_event == key do
      state
    else
      case build_health_event(state, event_type, reason_code) do
        {:ok, event} ->
          deliver_health_event(state.health_event_sink, event)
          %{state | last_health_event: key}

        :error ->
          state
      end
    end
  end

  defp build_health_event(state, event_type, reason_code) do
    with %{firmware: %{version: version, git_sha: git_sha}} <- state.target_identity,
         {:ok, manifest_hash} <- read_manifest_hash(state.health_event_context) do
      common = %{
        event_type: event_type,
        occurred_at_ms: state.last_now_ms,
        firmware_version: version,
        firmware_git_sha: git_sha,
        target: %{
          credential_epoch: state.target_identity.credential_epoch,
          desired_generation: state.target_identity.desired_generation,
          manifest_hash: manifest_hash
        }
      }

      if reason_code == nil,
        do: {:ok, common},
        else: {:ok, Map.put(common, :reason_code, reason_code)}
    else
      _unavailable -> :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp read_manifest_hash(%{manifest_hash_reader: reader}) when is_function(reader, 0) do
    case reader.() do
      %{active: %{manifest_hash: <<_::256>> = manifest_hash}} -> {:ok, manifest_hash}
      _other -> :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp read_manifest_hash(_context), do: :error

  defp deliver_health_event(sink, event) when is_function(sink, 1) do
    _ = sink.(event)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp deliver_health_event(_sink, _event), do: :ok

  defp pending_reason(unmet) when is_list(unmet) do
    diagnostic_codes =
      RacingOrg.Tracker.Pro.DurableDelivery.HealthEvent.V1.reason_codes()

    unmet
    |> Enum.find_value(fn
      %{diagnostic_code: code} when is_atom(code) ->
        if code in diagnostic_codes, do: code

      _entry ->
        nil
    end)
    |> Kernel.||(:invalid_snapshot)
  end

  defp pending_reason(_unmet), do: :invalid_snapshot

  defp read_clock(clock) when is_function(clock, 0) do
    case clock.() do
      now_ms when is_integer(now_ms) -> {:ok, max(now_ms, 0)}
      _other -> {:error, :invalid_clock}
    end
  rescue
    _exception -> {:error, :invalid_clock}
  catch
    _kind, _reason -> {:error, :invalid_clock}
  end

  defp read_clock(_clock), do: {:error, :invalid_clock}

  defp boot_relative_clock do
    boot_origin_native = :erlang.system_info(:start_time)

    fn ->
      System.monotonic_time()
      |> Kernel.-(boot_origin_native)
      |> System.convert_time_unit(:native, :millisecond)
      |> max(0)
    end
  end

  defp saturating_add(left, right) when left > @max_u64 - right, do: @max_u64
  defp saturating_add(left, right), do: left + right

  defp positive_milliseconds(value) when is_integer(value) and value > 0, do: value
  defp positive_milliseconds(_value), do: @default_retry_ms

  defp default_schedule(message, delay_ms), do: Process.send_after(self(), message, delay_ms)
  defp default_cancel_timer(timer_ref), do: Process.cancel_timer(timer_ref)

  defp public_status(state) do
    %{
      phase: state.phase,
      result: state.result,
      remaining_deadline_ms: state.remaining_deadline_ms,
      healthy_for_ms: state.healthy_for_ms,
      effect_status: state.effect_status
    }
  end

  defp format_state(state) when is_map(state) do
    %{
      phase: safe_member(Map.get(state, :phase), @phases, :unknown),
      result: safe_result_status(Map.get(state, :result)),
      remaining_deadline_ms: safe_nonnegative_integer(Map.get(state, :remaining_deadline_ms)),
      healthy_for_ms: safe_nonnegative_integer(Map.get(state, :healthy_for_ms)),
      effect_status: safe_member(Map.get(state, :effect_status), @effect_statuses, :unknown)
    }
  end

  defp format_state(_state), do: :redacted

  defp safe_result_status(:ready), do: :ready
  defp safe_result_status({status, _unmet}) when status in [:pending, :rollback_required], do: status
  defp safe_result_status(_result), do: :unknown

  defp safe_nonnegative_integer(value) when is_integer(value) and value >= 0, do: value
  defp safe_nonnegative_integer(_value), do: :unknown

  defp safe_member(value, allowed, fallback) do
    if value in allowed, do: value, else: fallback
  end

  defp noreply_result({:ok, state}), do: {:noreply, state}
  defp noreply_result({:stop, reason, state}), do: {:stop, reason, state}
end
