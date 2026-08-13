defmodule RacingOrg.Tracker.Pro.FirmwareValidation.Coordinator do
  @moduledoc """
  Waits for exact target authority before starting one firmware health trial.

  The rollback deadline is anchored once at coordinator startup in the same
  boot-relative clock domain as `Trial`. It is never recomputed when identity,
  hydration, session, or target authority later becomes ready. Therefore a target
  first observed after expiry is passed to `Trial` with that original expired
  deadline and immediately receives terminal deadline behavior.
  """

  use GenServer

  alias RacingOrg.Tracker.Pro.FirmwareValidation.{Target, Trial}

  @max_u64 0xFFFF_FFFF_FFFF_FFFF
  @default_retry_ms 250

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

  @doc "Starts the target-authority coordinator."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    opts = Keyword.put_new_lazy(opts, :clock, &boot_relative_clock/0)

    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  def start_link(_opts), do: {:error, :invalid_options}

  @doc "Requests an immediate target-authority check."
  @spec check_now(GenServer.server()) :: :ok | {:error, term()}
  def check_now(server \\ __MODULE__), do: GenServer.call(server, :check_now, :infinity)

  @doc "Returns sanitized coordinator state."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    with {:ok, rollback_after_ms} <- positive_u64(Keyword.get(opts, :rollback_after_ms)),
         {:ok, started_at_ms} <- read_clock(Keyword.fetch!(opts, :clock)) do
      deadline_at_ms = saturating_add(started_at_ms, rollback_after_ms)

      state = %{
        phase: :target_pending,
        deadline_at_ms: deadline_at_ms,
        clock: Keyword.fetch!(opts, :clock),
        target_reader: Keyword.get(opts, :target_reader, &Target.read/0),
        trial_starter: Keyword.get(opts, :trial_starter, &Trial.start_link/1),
        trial_opts: Keyword.get(opts, :trial_opts, []),
        retry_ms: positive_milliseconds(Keyword.get(opts, :retry_ms, @default_retry_ms)),
        timer_ref: nil,
        timer_token: nil,
        trial: nil
      }

      {:ok, state, {:continue, :check_target}}
    else
      {:error, reason} -> {:stop, reason}
    end
  rescue
    _exception -> {:stop, :invalid_options}
  catch
    _kind, _reason -> {:stop, :invalid_options}
  end

  @impl true
  def handle_continue(:check_target, state), do: state |> check_target() |> noreply_result()

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call(:check_now, _from, %{phase: :trial_started} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:check_now, _from, state) do
    state = cancel_timer(state)

    case check_target(state) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:stop, reason, next_state} -> {:stop, reason, {:error, reason}, next_state}
    end
  end

  @impl true
  def handle_info({:check_target, token}, %{timer_token: token, phase: :target_pending} = state) do
    state
    |> clear_timer()
    |> check_target()
    |> noreply_result()
  end

  def handle_info({:check_target, _stale_token}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp check_target(%{phase: :trial_started} = state), do: {:ok, state}

  defp check_target(state) do
    case safe_target_read(state.target_reader) do
      {:ok, target_identity} -> start_trial(state, target_identity)
      :pending -> schedule_check(state)
    end
  end

  defp start_trial(state, target_identity) do
    target = Map.put(target_identity, :deadline_at_ms, state.deadline_at_ms)
    opts = Keyword.put(state.trial_opts, :target, target)
    opts = Keyword.put_new(opts, :clock, state.clock)

    case safe_trial_start(state.trial_starter, opts) do
      {:ok, trial} ->
        {:ok,
         %{
           cancel_timer(state)
           | phase: :trial_started,
             trial: trial
         }}

      {:error, reason} ->
        {:stop, {:trial_start_failed, reason}, state}
    end
  end

  defp safe_target_read(reader) when is_function(reader, 0) do
    case reader.() do
      {:ok, target} when is_map(target) -> {:ok, target}
      _pending_or_invalid -> :pending
    end
  rescue
    _exception -> :pending
  catch
    _kind, _reason -> :pending
  end

  defp safe_target_read(_reader), do: :pending

  defp safe_trial_start(starter, opts) when is_function(starter, 1) do
    case starter.(opts) do
      {:ok, trial} -> {:ok, trial}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_response, other}}
    end
  rescue
    _exception -> {:error, :starter_failed}
  catch
    _kind, _reason -> {:error, :starter_failed}
  end

  defp safe_trial_start(_starter, _opts), do: {:error, :invalid_starter}

  defp schedule_check(state) do
    state = cancel_timer(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:check_target, token}, state.retry_ms)
    {:ok, %{state | timer_ref: timer_ref, timer_token: token}}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(state) do
    _cancelled = Process.cancel_timer(state.timer_ref)
    clear_timer(state)
  end

  defp clear_timer(state), do: %{state | timer_ref: nil, timer_token: nil}

  defp read_clock(clock) when is_function(clock, 0) do
    case clock.() do
      now_ms when is_integer(now_ms) and now_ms >= 0 and now_ms <= @max_u64 -> {:ok, now_ms}
      _invalid -> {:error, :invalid_clock}
    end
  rescue
    _exception -> {:error, :invalid_clock}
  catch
    _kind, _reason -> {:error, :invalid_clock}
  end

  defp read_clock(_clock), do: {:error, :invalid_clock}

  defp positive_u64(value) when value in 1..@max_u64, do: {:ok, value}
  defp positive_u64(_value), do: {:error, :invalid_rollback_after_ms}

  defp positive_milliseconds(value) when is_integer(value) and value > 0, do: value
  defp positive_milliseconds(_value), do: @default_retry_ms

  defp saturating_add(left, right) when left > @max_u64 - right, do: @max_u64
  defp saturating_add(left, right), do: left + right

  defp boot_relative_clock do
    boot_origin_native = :erlang.system_info(:start_time)

    fn ->
      System.monotonic_time()
      |> Kernel.-(boot_origin_native)
      |> System.convert_time_unit(:native, :millisecond)
      |> max(0)
    end
  end

  defp public_status(state) do
    %{phase: state.phase, deadline_at_ms: state.deadline_at_ms}
  end

  defp noreply_result({:ok, state}), do: {:noreply, state}
  defp noreply_result({:stop, reason, state}), do: {:stop, reason, state}
end
