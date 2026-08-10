defmodule RacingOrg.Tracker.Pro.FirmwareValidation.Trial do
  @moduledoc """
  Supervised, restart-safe controller for an OTA firmware health trial.

  The controller evaluates `HealthCriteria` on a nonnegative boot-relative
  monotonic clock, requires one uninterrupted healthy soak, and retries until a
  terminal deadline. It persists only the sanitized `DiagnosticsStore` record.
  A rollback decision is durably committed before partition reversion, and a
  second durable phase records that passive reversion completed before an
  explicit reboot is requested.
  """

  use GenServer

  alias RacingOrg.Tracker.Pro.FirmwareValidation.DiagnosticsStore
  alias RacingOrg.Tracker.Pro.FirmwareValidation.HealthCriteria
  alias RacingOrg.Tracker.Pro.FirmwareValidation.Snapshot
  alias RacingOrg.Tracker.Pro.FirmwareValidator

  @max_u64 0xFFFF_FFFF_FFFF_FFFF
  @default_retry_ms 1_000
  @phases [:monitoring, :validated, :rollback_decided, :reboot_pending]
  @effect_statuses [nil, :runtime_unavailable, :revert_failed, :reboot_failed, :reboot_requested]
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

  def handle_continue(:resume, %{phase: phase} = state)
      when phase in [:rollback_decided, :reboot_pending] do
    state
    |> enforce_rollback()
    |> noreply_result()
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

    case if(state.phase == :monitoring, do: run_check(state), else: enforce_rollback(state)) do
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

  def handle_info({:rollback_effect, token}, %{timer_token: token} = state) do
    state
    |> clear_timer()
    |> enforce_rollback()
    |> noreply_result()
  end

  def handle_info({kind, _stale_token}, state) when kind in [:trial_check, :rollback_effect], do: {:noreply, state}
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
      revert_fun: Keyword.get(opts, :revert_fun),
      reboot_fun: Keyword.get(opts, :reboot_fun),
      schedule_fun: Keyword.get(opts, :schedule_fun, &default_schedule/2),
      cancel_timer_fun: Keyword.get(opts, :cancel_timer_fun, &default_cancel_timer/1),
      timer_ref: nil,
      timer_token: nil,
      effect_status: nil
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
    %{
      state
      | phase: record.phase,
        result: record.result,
        remaining_deadline_ms: record.timing.remaining_deadline_ms,
        healthy_since_ms: nil,
        healthy_for_ms: 0
    }
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
      {:pending, _unmet} -> persist_monitoring_and_schedule(state)
      {:rollback_required, _unmet} -> decide_rollback(state, result)
      :ready -> attempt_validation(state)
    end
  end

  defp attempt_validation(state) do
    case firmware_validation(state) do
      result when result in [:validated, :already_valid] ->
        case persist_record(state, :validated, :ready, state.remaining_deadline_ms) do
          :ok -> {:ok, %{cancel_timer(state) | phase: :validated, result: :ready}}
          {:error, reason} -> {:stop, {:diagnostics_persist_failed, reason}, state}
        end

      _failure when state.remaining_deadline_ms > 0 ->
        persist_monitoring_and_schedule(state)

      _failure ->
        decide_rollback(state, {:rollback_required, @invalid_snapshot})
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

    case persist_record(state, :rollback_decided, result, 0) do
      :ok -> enforce_rollback(state)
      {:error, reason} -> {:stop, {:diagnostics_persist_failed, reason}, state}
    end
  end

  defp enforce_rollback(%{phase: :rollback_decided} = state) do
    case rollback_effect(state.revert_fun, :revert) do
      :ok ->
        state = %{state | phase: :reboot_pending, effect_status: nil}

        case persist_record(state, :reboot_pending, state.result, 0) do
          :ok -> enforce_rollback(state)
          {:error, reason} -> {:stop, {:diagnostics_persist_failed, reason}, state}
        end

      {:error, :nerves_runtime_unavailable} ->
        {:ok, %{state | effect_status: :runtime_unavailable}}

      {:error, :effect_failed} ->
        state
        |> Map.put(:effect_status, :revert_failed)
        |> schedule(:rollback_effect, state.retry_ms)
    end
  end

  defp enforce_rollback(%{phase: :reboot_pending} = state) do
    case rollback_effect(state.reboot_fun, :reboot) do
      :ok ->
        {:ok, %{state | effect_status: :reboot_requested}}

      {:error, :nerves_runtime_unavailable} ->
        {:ok, %{state | effect_status: :runtime_unavailable}}

      {:error, :effect_failed} ->
        state
        |> Map.put(:effect_status, :reboot_failed)
        |> schedule(:rollback_effect, state.retry_ms)
    end
  end

  defp firmware_validation(state) do
    []
    |> maybe_put_validator_option(:firmware_valid?, state.status_fun, &safe_status/1)
    |> maybe_put_validator_option(:validate, state.validate_fun, &safe_validate/1)
    |> FirmwareValidator.validate_on_connect()
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

  defp rollback_effect(nil, operation), do: runtime_call(operation)

  defp rollback_effect(fun, _operation) when is_function(fun, 0) do
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

  defp rollback_effect(_invalid, _operation), do: {:error, :effect_failed}

  defp runtime_call(operation) do
    if Code.ensure_loaded?(Nerves.Runtime) and function_exported?(Nerves.Runtime, operation, 0) do
      case apply(Nerves.Runtime, operation, []) do
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
    origin_ms = System.monotonic_time(:millisecond)
    fn -> max(System.monotonic_time(:millisecond) - origin_ms, 0) end
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
