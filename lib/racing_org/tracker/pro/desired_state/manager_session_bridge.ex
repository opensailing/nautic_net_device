defmodule RacingOrg.Tracker.Pro.DesiredState.Manager.SessionBridge do
  @moduledoc false

  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRequest
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder

  @spec callback_principal(GenServer.server()) ::
          {:ok, pid()} | {:error, :session_callback_failed}
  def callback_principal(session_holder) do
    case GenServer.whereis(session_holder) do
      callback_pid when is_pid(callback_pid) -> {:ok, callback_pid}
      nil -> {:error, :session_callback_failed}
    end
  rescue
    ArgumentError -> {:error, :session_callback_failed}
  catch
    :exit, _reason -> {:error, :session_callback_failed}
  end

  @spec start_worker(pid(), GenServer.server(), SessionHolder.generation(), reference()) ::
          {pid(), reference()}
  def start_worker(manager_pid, session_holder, session_generation, request_token)
      when is_pid(manager_pid) and is_integer(session_generation) and session_generation >= 0 and
             is_reference(request_token) do
    case callback_principal(session_holder) do
      {:ok, callback_pid} ->
        start_worker(
          manager_pid,
          session_holder,
          session_generation,
          request_token,
          callback_pid
        )

      {:error, :session_callback_failed} ->
        start_failed_worker(manager_pid, request_token)
    end
  end

  @spec start_worker(pid(), GenServer.server(), SessionHolder.generation(), reference(), pid()) ::
          {pid(), reference()}
  def start_worker(
        manager_pid,
        session_holder,
        session_generation,
        request_token,
        callback_pid
      )
      when is_pid(manager_pid) and is_integer(session_generation) and session_generation >= 0 and
             is_reference(request_token) and is_pid(callback_pid) do
    spawn_monitor(fn ->
      start_manager_watchdog(manager_pid, self())
      manager_ref = Process.monitor(manager_pid)

      result =
        invoke_session_holder(
          manager_pid,
          session_holder,
          session_generation,
          request_token,
          callback_pid
        )

      complete(manager_pid, manager_ref, request_token, result)
    end)
  end

  @spec valid_callback_request?(pid(), reference(), pid(), reference(), term()) :: boolean()
  def valid_callback_request?(
        manager_pid,
        request_token,
        callback_pid,
        callback_request_token,
        session
      )
      when is_pid(manager_pid) and is_reference(request_token) and is_pid(callback_pid) and
             is_reference(callback_request_token) do
    AuthorityRequest.valid?(
      callback_request_token,
      callback_pid,
      callback_request_operation(
        manager_pid,
        request_token,
        callback_pid,
        session
      )
    )
  end

  def valid_callback_request?(
        _manager_pid,
        _request_token,
        _callback_pid,
        _callback_request_token,
        _session
      ),
      do: false

  @spec valid_callback_request?(pid(), reference(), pid(), pid(), reference(), term()) :: boolean()
  def valid_callback_request?(
        manager_pid,
        request_token,
        expected_callback_pid,
        callback_pid,
        callback_request_token,
        session
      )
      when expected_callback_pid == callback_pid do
    valid_callback_request?(
      manager_pid,
      request_token,
      callback_pid,
      callback_request_token,
      session
    )
  end

  def valid_callback_request?(
        _manager_pid,
        _request_token,
        _expected_callback_pid,
        _callback_pid,
        _callback_request_token,
        _session
      ),
      do: false

  @spec send_callback_result(pid(), reference(), term()) :: reference()
  def send_callback_result(callback_pid, request_token, result)
      when is_pid(callback_pid) and is_reference(request_token) do
    manager_pid = self()

    result_token =
      AuthorityRequest.new(
        callback_result_operation(
          manager_pid,
          request_token,
          callback_pid,
          result
        )
      )

    send(
      callback_pid,
      {:session_callback_result, request_token, manager_pid, result_token, result}
    )

    result_token
  end

  @spec send_completion_ack(pid(), reference(), term()) :: reference()
  def send_completion_ack(worker_pid, request_token, result)
      when is_pid(worker_pid) and is_reference(request_token) do
    manager_pid = self()

    ack_token =
      AuthorityRequest.new(
        completion_ack_operation(
          manager_pid,
          request_token,
          worker_pid,
          result
        )
      )

    send(
      worker_pid,
      {:session_callback_ack, request_token, manager_pid, ack_token, result}
    )

    ack_token
  end

  @spec valid_completion?(pid(), reference(), pid(), reference(), term()) :: boolean()
  def valid_completion?(
        manager_pid,
        request_token,
        worker_pid,
        completion_token,
        result
      )
      when is_pid(manager_pid) and is_reference(request_token) and is_pid(worker_pid) and
             is_reference(completion_token) do
    AuthorityRequest.valid?(
      completion_token,
      worker_pid,
      completion_operation(
        manager_pid,
        request_token,
        worker_pid,
        result
      )
    )
  end

  def valid_completion?(
        _manager_pid,
        _request_token,
        _worker_pid,
        _completion_token,
        _result
      ),
      do: false

  @spec valid_completion_ack?(pid(), reference(), pid(), reference(), term()) :: boolean()
  def valid_completion_ack?(
        manager_pid,
        request_token,
        worker_pid,
        ack_token,
        result
      )
      when is_pid(manager_pid) and is_reference(request_token) and is_pid(worker_pid) and
             is_reference(ack_token) do
    AuthorityRequest.valid?(
      ack_token,
      manager_pid,
      completion_ack_operation(
        manager_pid,
        request_token,
        worker_pid,
        result
      )
    )
  end

  def valid_completion_ack?(
        _manager_pid,
        _request_token,
        _worker_pid,
        _ack_token,
        _result
      ),
      do: false

  defp start_failed_worker(manager_pid, request_token) do
    spawn_monitor(fn ->
      start_manager_watchdog(manager_pid, self())
      manager_ref = Process.monitor(manager_pid)
      complete(manager_pid, manager_ref, request_token, {:error, :session_callback_failed})
    end)
  end

  defp start_manager_watchdog(manager_pid, worker_pid) do
    spawn(fn ->
      manager_ref = Process.monitor(manager_pid)
      worker_ref = Process.monitor(worker_pid)

      receive do
        {:DOWN, ^manager_ref, :process, ^manager_pid, _reason} ->
          Process.exit(worker_pid, :kill)

        {:DOWN, ^worker_ref, :process, ^worker_pid, _reason} ->
          :ok
      end
    end)
  end

  defp complete(manager_pid, manager_ref, request_token, result) do
    completion_token =
      AuthorityRequest.new(
        completion_operation(
          manager_pid,
          request_token,
          self(),
          result
        )
      )

    try do
      send(
        manager_pid,
        {:session_callback_complete, request_token, self(), completion_token, result}
      )

      await_manager_ack(manager_pid, manager_ref, request_token, result)
    after
      AuthorityRequest.delete(completion_token)
    end
  end

  defp invoke_session_holder(
         manager_pid,
         session_holder,
         session_generation,
         request_token,
         callback_pid
       ) do
    SessionHolder.with_session(
      session_holder,
      session_generation,
      fn session ->
        if self() == callback_pid do
          await_manager_callback(
            manager_pid,
            request_token,
            session
          )
        else
          exit(:session_callback_principal_changed)
        end
      end
    )
  catch
    :exit, _reason -> {:error, :session_callback_failed}
  end

  defp await_manager_callback(manager_pid, request_token, session) do
    manager_ref = Process.monitor(manager_pid)
    callback_pid = self()

    callback_request_token =
      AuthorityRequest.new(
        callback_request_operation(
          manager_pid,
          request_token,
          callback_pid,
          session
        )
      )

    try do
      send(
        manager_pid,
        {:run_session_callback, request_token, callback_pid, callback_request_token, session}
      )

      await_callback_result(
        manager_pid,
        manager_ref,
        request_token,
        callback_pid
      )
    after
      AuthorityRequest.delete(callback_request_token)
    end
  end

  defp await_callback_result(
         manager_pid,
         manager_ref,
         request_token,
         callback_pid
       ) do
    receive do
      {:session_callback_result, ^request_token, ^manager_pid, result_token, result}
      when is_reference(result_token) ->
        if valid_callback_result?(
             manager_pid,
             request_token,
             callback_pid,
             result_token,
             result
           ) do
          Process.demonitor(manager_ref, [:flush])
          unwrap_callback_result(result)
        else
          await_callback_result(
            manager_pid,
            manager_ref,
            request_token,
            callback_pid
          )
        end

      {:DOWN, ^manager_ref, :process, ^manager_pid, _reason} ->
        exit(:session_callback_manager_down)
    end
  end

  defp valid_callback_result?(
         manager_pid,
         request_token,
         callback_pid,
         result_token,
         result
       ) do
    AuthorityRequest.valid?(
      result_token,
      manager_pid,
      callback_result_operation(
        manager_pid,
        request_token,
        callback_pid,
        result
      )
    )
  end

  defp unwrap_callback_result({:ok, callback_result}), do: callback_result
  defp unwrap_callback_result({:error, :session_callback_failed}), do: raise("session callback failed")
  defp unwrap_callback_result(_result), do: raise("invalid session callback result")

  defp await_manager_ack(manager_pid, manager_ref, request_token, result) do
    worker_pid = self()

    receive do
      {:session_callback_ack, ^request_token, ^manager_pid, ack_token, ^result}
      when is_reference(ack_token) ->
        if valid_completion_ack?(
             manager_pid,
             request_token,
             worker_pid,
             ack_token,
             result
           ) do
          Process.demonitor(manager_ref, [:flush])
          :ok
        else
          await_manager_ack(manager_pid, manager_ref, request_token, result)
        end

      {:DOWN, ^manager_ref, :process, ^manager_pid, _reason} ->
        :ok
    end
  end

  defp callback_request_operation(manager_pid, request_token, callback_pid, session) do
    {:run_session_callback, request_token, manager_pid, callback_pid, session}
  end

  defp callback_result_operation(manager_pid, request_token, callback_pid, result) do
    {:session_callback_result, request_token, manager_pid, callback_pid, result}
  end

  defp completion_operation(manager_pid, request_token, worker_pid, result) do
    {:session_callback_complete, request_token, manager_pid, worker_pid, result}
  end

  defp completion_ack_operation(manager_pid, request_token, worker_pid, result) do
    {:session_callback_ack, request_token, manager_pid, worker_pid, result}
  end
end
