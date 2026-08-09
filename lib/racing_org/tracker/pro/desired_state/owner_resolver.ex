defmodule RacingOrg.Tracker.Pro.DesiredState.OwnerResolver do
  @moduledoc false

  @default_timeout_ms 25

  @type owner_reference ::
          pid()
          | atom()
          | {:global, term()}
          | {:via, module(), term()}

  @type resolution_error ::
          :owner_resolution_timeout
          | :owner_resolution_failed
          | :owner_resolution_cancelled

  @spec resolve([owner_reference()], keyword()) ::
          {:ok, %{owner_reference() => pid() | nil | :undefined}}
          | {:error, resolution_error()}
  def resolve(owner_references, opts \\ [])

  def resolve(owner_references, opts) when is_list(owner_references) do
    owner_references = Enum.uniq(owner_references)

    run(
      fn ->
        {:ok,
         Map.new(owner_references, fn owner_reference ->
           {owner_reference, resolve_owner_pid(owner_reference)}
         end)}
      end,
      opts
    )
  end

  def resolve(_owner_references, _opts), do: {:error, :owner_resolution_failed}

  @spec run((-> term()), keyword()) :: term()
  def run(fun, opts \\ [])

  def run(fun, opts) when is_function(fun, 0) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    cancel_on = opts |> Keyword.get(:cancel_on, []) |> List.wrap()

    if valid_timeout?(timeout_ms) and Enum.all?(cancel_on, &is_pid/1) do
      run_bounded(fun, timeout_ms, cancel_on)
    else
      {:error, :owner_resolution_failed}
    end
  end

  def run(_fun, _opts), do: {:error, :owner_resolution_failed}

  defp run_bounded(fun, timeout_ms, cancel_on) do
    caller = self()
    reply_token = make_ref()
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    {guardian_pid, guardian_ref} =
      spawn_monitor(fn ->
        guard_resolver(caller, reply_token, fun, cancel_on)
      end)

    receive do
      {^reply_token, :resolver_started, resolver_pid} ->
        resolver_ref = Process.monitor(resolver_pid)
        send(guardian_pid, {reply_token, :start_resolver, resolver_pid})

        await_result(
          reply_token,
          guardian_pid,
          guardian_ref,
          resolver_pid,
          resolver_ref,
          deadline_ms,
          timeout_ms
        )

      {:DOWN, ^guardian_ref, :process, ^guardian_pid, _reason} ->
        receive do
          {^reply_token, :result, result} -> result
        after
          0 -> {:error, :owner_resolution_failed}
        end
    after
      timeout_ms ->
        cancel_before_start(reply_token, guardian_pid, guardian_ref, timeout_ms)
        {:error, :owner_resolution_timeout}
    end
  end

  defp await_result(
         reply_token,
         guardian_pid,
         guardian_ref,
         resolver_pid,
         resolver_ref,
         deadline_ms,
         timeout_ms
       ) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^reply_token, :result, result} ->
        demonitor_if_reference(resolver_ref)
        Process.demonitor(guardian_ref, [:flush])
        result

      {:DOWN, ^resolver_ref, :process, ^resolver_pid, _reason} ->
        await_result(
          reply_token,
          guardian_pid,
          guardian_ref,
          resolver_pid,
          nil,
          deadline_ms,
          timeout_ms
        )

      {:DOWN, ^guardian_ref, :process, ^guardian_pid, _reason} ->
        stop_resolver(resolver_pid, resolver_ref, timeout_ms)

        receive do
          {^reply_token, :result, result} -> result
        after
          0 -> {:error, :owner_resolution_failed}
        end
    after
      remaining_ms ->
        stop_resolver(resolver_pid, resolver_ref, timeout_ms)
        stop_guardian(reply_token, guardian_pid, guardian_ref, timeout_ms)
        {:error, :owner_resolution_timeout}
    end
  end

  defp guard_resolver(caller, reply_token, fun, cancel_on) do
    Process.flag(:trap_exit, true)

    target_refs =
      [caller | cancel_on]
      |> Enum.uniq()
      |> Map.new(fn pid -> {Process.monitor(pid), pid} end)

    guardian = self()

    resolver_pid =
      spawn_link(fn ->
        receive do
          {^reply_token, :invoke, resolver_fun} ->
            send(guardian, {reply_token, :resolver_result, invoke(resolver_fun)})
        end
      end)

    resolver_ref = Process.monitor(resolver_pid)
    send(caller, {reply_token, :resolver_started, resolver_pid})

    await_resolver_start(
      caller,
      reply_token,
      fun,
      target_refs,
      resolver_pid,
      resolver_ref
    )
  end

  defp await_resolver_start(
         caller,
         reply_token,
         fun,
         target_refs,
         resolver_pid,
         resolver_ref
       ) do
    receive do
      {^reply_token, :start_resolver, ^resolver_pid} ->
        send(resolver_pid, {reply_token, :invoke, fun})

        await_guarded_result(
          caller,
          reply_token,
          target_refs,
          resolver_pid,
          resolver_ref
        )

      {:DOWN, ^resolver_ref, :process, ^resolver_pid, _reason} ->
        demonitor_all(target_refs)
        send(caller, {reply_token, :result, {:error, :owner_resolution_failed}})

      {:DOWN, target_ref, :process, target_pid, _reason} ->
        if Map.get(target_refs, target_ref) == target_pid do
          cancel_guarded_resolver(
            caller,
            reply_token,
            target_refs,
            resolver_pid,
            resolver_ref,
            target_pid
          )
        else
          await_resolver_start(
            caller,
            reply_token,
            fun,
            target_refs,
            resolver_pid,
            resolver_ref
          )
        end

      {^reply_token, :cancel} ->
        kill_resolver(resolver_pid, resolver_ref)
        demonitor_all(target_refs)
        send(caller, {reply_token, :cancelled})

      {:EXIT, ^resolver_pid, _reason} ->
        await_resolver_start(
          caller,
          reply_token,
          fun,
          target_refs,
          resolver_pid,
          resolver_ref
        )
    end
  end

  defp await_guarded_result(
         caller,
         reply_token,
         target_refs,
         resolver_pid,
         resolver_ref
       ) do
    receive do
      {^reply_token, :resolver_result, result} ->
        await_resolver_down(resolver_ref, resolver_pid)
        demonitor_all(target_refs)
        send(caller, {reply_token, :result, result})

      {:DOWN, ^resolver_ref, :process, ^resolver_pid, _reason} ->
        result =
          receive do
            {^reply_token, :resolver_result, result} -> result
          after
            0 -> {:error, :owner_resolution_failed}
          end

        demonitor_all(target_refs)
        send(caller, {reply_token, :result, result})

      {:DOWN, target_ref, :process, target_pid, _reason} ->
        if Map.get(target_refs, target_ref) == target_pid do
          cancel_guarded_resolver(
            caller,
            reply_token,
            target_refs,
            resolver_pid,
            resolver_ref,
            target_pid
          )
        else
          await_guarded_result(
            caller,
            reply_token,
            target_refs,
            resolver_pid,
            resolver_ref
          )
        end

      {^reply_token, :cancel} ->
        kill_resolver(resolver_pid, resolver_ref)
        demonitor_all(target_refs)
        send(caller, {reply_token, :cancelled})

      {:EXIT, ^resolver_pid, _reason} ->
        await_guarded_result(
          caller,
          reply_token,
          target_refs,
          resolver_pid,
          resolver_ref
        )
    end
  end

  defp cancel_guarded_resolver(
         caller,
         reply_token,
         target_refs,
         resolver_pid,
         resolver_ref,
         target_pid
       ) do
    kill_resolver(resolver_pid, resolver_ref)
    demonitor_all(target_refs)

    if target_pid != caller do
      send(caller, {reply_token, :result, {:error, :owner_resolution_cancelled}})
    end
  end

  defp invoke(fun) do
    fun.()
  rescue
    _exception -> {:error, :owner_resolution_failed}
  catch
    _kind, _reason -> {:error, :owner_resolution_failed}
  end

  defp resolve_owner_pid(pid) when is_pid(pid), do: pid
  defp resolve_owner_pid(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_owner_pid({:global, name}), do: :global.whereis_name(name)
  defp resolve_owner_pid({:via, module, name}), do: module.whereis_name(name)
  defp resolve_owner_pid(_owner), do: nil

  defp stop_resolver(_resolver_pid, nil, _timeout_ms), do: :ok

  defp stop_resolver(resolver_pid, resolver_ref, timeout_ms) do
    Process.exit(resolver_pid, :kill)

    receive do
      {:DOWN, ^resolver_ref, :process, ^resolver_pid, _reason} -> :ok
    after
      timeout_ms -> Process.demonitor(resolver_ref, [:flush])
    end
  end

  defp stop_guardian(reply_token, guardian_pid, guardian_ref, timeout_ms) do
    send(guardian_pid, {reply_token, :cancel})

    receive do
      {^reply_token, :cancelled} ->
        await_guardian_down(guardian_ref, guardian_pid, timeout_ms)

      {:DOWN, ^guardian_ref, :process, ^guardian_pid, _reason} ->
        :ok

      {^reply_token, :result, _late_result} ->
        await_guardian_down(guardian_ref, guardian_pid, timeout_ms)
    after
      timeout_ms ->
        Process.exit(guardian_pid, :kill)
        await_guardian_down(guardian_ref, guardian_pid, timeout_ms)
    end
  end

  defp cancel_before_start(reply_token, guardian_pid, guardian_ref, timeout_ms) do
    send(guardian_pid, {reply_token, :cancel})

    receive do
      {^reply_token, :resolver_started, resolver_pid} ->
        resolver_ref = Process.monitor(resolver_pid)
        stop_resolver(resolver_pid, resolver_ref, timeout_ms)
        stop_guardian(reply_token, guardian_pid, guardian_ref, timeout_ms)

      {^reply_token, :cancelled} ->
        await_guardian_down(guardian_ref, guardian_pid, timeout_ms)

      {:DOWN, ^guardian_ref, :process, ^guardian_pid, _reason} ->
        :ok
    after
      timeout_ms ->
        Process.exit(guardian_pid, :kill)
        await_guardian_down(guardian_ref, guardian_pid, timeout_ms)
    end
  end

  defp kill_resolver(resolver_pid, resolver_ref) do
    Process.exit(resolver_pid, :kill)
    await_resolver_down(resolver_ref, resolver_pid)
  end

  defp await_resolver_down(resolver_ref, resolver_pid) do
    receive do
      {:DOWN, ^resolver_ref, :process, ^resolver_pid, _reason} -> :ok
    end
  end

  defp await_guardian_down(guardian_ref, guardian_pid, timeout_ms) do
    receive do
      {:DOWN, ^guardian_ref, :process, ^guardian_pid, _reason} -> :ok
    after
      timeout_ms -> Process.demonitor(guardian_ref, [:flush])
    end
  end

  defp demonitor_all(target_refs) do
    Enum.each(target_refs, fn {monitor_ref, _pid} ->
      Process.demonitor(monitor_ref, [:flush])
    end)
  end

  defp demonitor_if_reference(monitor_ref) when is_reference(monitor_ref),
    do: Process.demonitor(monitor_ref, [:flush])

  defp demonitor_if_reference(_monitor_ref), do: :ok

  defp valid_timeout?(timeout_ms), do: is_integer(timeout_ms) and timeout_ms > 0
end
