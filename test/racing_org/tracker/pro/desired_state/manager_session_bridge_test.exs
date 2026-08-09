defmodule RacingOrg.Tracker.Pro.DesiredState.ManagerSessionBridgeTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DesiredState.Manager.SessionBridge
  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRequest
  alias RacingOrg.Tracker.Pro.SecureTransport.{Session, SessionHolder}

  setup do
    holder = start_supervised!({SessionHolder, name: nil})
    {:ok, session} = SessionHolder.publish(holder, session())

    %{holder: holder, session: session}
  end

  test "manager death terminates a worker queued behind an unavailable SessionHolder", ctx do
    manager = start_manager_probe(self())
    request_token = make_ref()
    :ok = :sys.suspend(ctx.holder)

    on_exit(fn ->
      if Process.alive?(ctx.holder), do: :sys.resume(ctx.holder)
    end)

    {worker, worker_ref} =
      SessionBridge.start_worker(
        manager,
        ctx.holder,
        ctx.session.generation,
        request_token
      )

    await_mailbox_size(ctx.holder, 1)
    Process.exit(manager, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 250
    refute Process.alive?(worker)
  end

  test "manager death releases a SessionHolder waiting for its callback result", ctx do
    manager = start_manager_probe(self())
    manager_ref = Process.monitor(manager)
    request_token = make_ref()

    {worker, worker_ref} =
      SessionBridge.start_worker(
        manager,
        ctx.holder,
        ctx.session.generation,
        request_token
      )

    assert_receive {:manager_probe, ^manager,
                    {:run_session_callback, ^request_token, callback_pid, callback_request_token,
                     %Session{} = current_session}}

    assert SessionBridge.valid_callback_request?(
             manager,
             request_token,
             callback_pid,
             callback_request_token,
             current_session
           )

    refute SessionBridge.valid_callback_request?(
             manager,
             request_token,
             callback_pid,
             callback_request_token,
             %{current_session | credential_epoch: current_session.credential_epoch + 1}
           )

    attacker = start_authority_principal()

    attacker_request_token =
      authority_token(
        attacker,
        {:run_session_callback, request_token, manager, attacker, current_session}
      )

    assert SessionBridge.valid_callback_request?(
             manager,
             request_token,
             attacker,
             attacker_request_token,
             current_session
           )

    refute SessionBridge.valid_callback_request?(
             manager,
             request_token,
             callback_pid,
             attacker,
             attacker_request_token,
             current_session
           )

    Process.exit(manager, :kill)

    assert_receive {:DOWN, ^manager_ref, :process, ^manager, :killed}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}
    assert holder_generation(ctx.holder) == ctx.session.generation
    refute Process.alive?(worker)
  end

  test "manager death releases a worker waiting for callback acknowledgement", ctx do
    manager = start_manager_probe(self())
    manager_ref = Process.monitor(manager)
    request_token = make_ref()

    {worker, worker_ref} =
      SessionBridge.start_worker(
        manager,
        ctx.holder,
        ctx.session.generation,
        request_token
      )

    assert_receive {:manager_probe, ^manager,
                    {:run_session_callback, ^request_token, callback_pid, _callback_request_token, %Session{}}}

    _result_token =
      send_callback_result(
        manager,
        callback_pid,
        request_token,
        {:ok, :callback_complete}
      )

    assert_receive {:manager_probe, ^manager,
                    {:session_callback_complete, ^request_token, ^worker, completion_token, {:ok, :callback_complete}}}

    assert SessionBridge.valid_completion?(
             manager,
             request_token,
             worker,
             completion_token,
             {:ok, :callback_complete}
           )

    refute SessionBridge.valid_completion?(
             manager,
             request_token,
             worker,
             completion_token,
             {:ok, :substituted_result}
           )

    assert Process.alive?(worker)
    Process.exit(manager, :kill)

    assert_receive {:DOWN, ^manager_ref, :process, ^manager, :killed}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}
    assert holder_generation(ctx.holder) == ctx.session.generation
    refute Process.alive?(worker)
  end

  test "completion acknowledgement requires a manager-owned exact-operation token", ctx do
    manager = start_manager_probe(self())
    request_token = make_ref()

    {worker, worker_ref} =
      SessionBridge.start_worker(
        manager,
        ctx.holder,
        ctx.session.generation,
        request_token
      )

    assert_receive {:manager_probe, ^manager,
                    {:run_session_callback, ^request_token, callback_pid, _callback_request_token, %Session{}}}

    _result_token =
      send_callback_result(
        manager,
        callback_pid,
        request_token,
        {:ok, :done}
      )

    assert_receive {:manager_probe, ^manager,
                    {:session_callback_complete, ^request_token, ^worker, _completion_token, {:ok, :done}}}

    send(worker, {:session_callback_ack, request_token})

    refute_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 20
    assert Process.alive?(worker)

    result = {:ok, :done}
    attacker = start_authority_principal()

    attacker_ack_token =
      authority_token(
        attacker,
        {:session_callback_ack, request_token, manager, worker, result}
      )

    refute SessionBridge.valid_completion_ack?(
             manager,
             request_token,
             worker,
             attacker_ack_token,
             result
           )

    send(
      worker,
      {:session_callback_ack, request_token, manager, attacker_ack_token, result}
    )

    refute_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 20
    assert Process.alive?(worker)

    _ack_token =
      send_completion_ack(
        manager,
        worker,
        request_token,
        result
      )

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}
  end

  test "the worker exits only after normal completion is acknowledged", ctx do
    manager = start_manager_probe(self())
    request_token = make_ref()

    {worker, worker_ref} =
      SessionBridge.start_worker(
        manager,
        ctx.holder,
        ctx.session.generation,
        request_token
      )

    assert_receive {:manager_probe, ^manager,
                    {:run_session_callback, ^request_token, callback_pid, _callback_request_token, %Session{}}}

    _result_token =
      send_callback_result(
        manager,
        callback_pid,
        request_token,
        {:ok, :done}
      )

    assert_receive {:manager_probe, ^manager,
                    {:session_callback_complete, ^request_token, ^worker, _completion_token, {:ok, :done}}}

    assert Process.alive?(worker)

    _ack_token =
      send_completion_ack(
        manager,
        worker,
        request_token,
        {:ok, :done}
      )

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}
    assert holder_generation(ctx.holder) == ctx.session.generation
  end

  defp start_manager_probe(test_pid) do
    manager = spawn(fn -> manager_probe_loop(test_pid) end)

    on_exit(fn ->
      if Process.alive?(manager), do: Process.exit(manager, :kill)
    end)

    manager
  end

  defp manager_probe_loop(test_pid) do
    receive do
      {:send_completion_ack, reply_to, worker_pid, request_token, result} ->
        ack_token =
          SessionBridge.send_completion_ack(
            worker_pid,
            request_token,
            result
          )

        send(reply_to, {:completion_ack_sent, self(), ack_token})
        manager_probe_loop(test_pid)

      {:send_callback_result, reply_to, callback_pid, request_token, result} ->
        result_token =
          SessionBridge.send_callback_result(
            callback_pid,
            request_token,
            result
          )

        send(reply_to, {:callback_result_sent, self(), result_token})
        manager_probe_loop(test_pid)

      message ->
        send(test_pid, {:manager_probe, self(), message})
        manager_probe_loop(test_pid)
    end
  end

  defp send_callback_result(manager, callback_pid, request_token, result) do
    send(
      manager,
      {:send_callback_result, self(), callback_pid, request_token, result}
    )

    assert_receive {:callback_result_sent, ^manager, result_token}
    result_token
  end

  defp send_completion_ack(manager, worker, request_token, result) do
    send(
      manager,
      {:send_completion_ack, self(), worker, request_token, result}
    )

    assert_receive {:completion_ack_sent, ^manager, ack_token}
    ack_token
  end

  defp start_authority_principal do
    principal = spawn(fn -> authority_principal_loop() end)

    on_exit(fn ->
      if Process.alive?(principal), do: Process.exit(principal, :kill)
    end)

    principal
  end

  defp authority_principal_loop do
    receive do
      {:new_authority_token, reply_to, operation} ->
        request_token = AuthorityRequest.new(operation)
        send(reply_to, {:authority_token, self(), request_token})
        authority_principal_loop()
    end
  end

  defp authority_token(principal, operation) do
    send(principal, {:new_authority_token, self(), operation})
    assert_receive {:authority_token, ^principal, request_token}
    request_token
  end

  defp await_mailbox_size(pid, minimum, attempts \\ 100)

  defp await_mailbox_size(_pid, _minimum, 0),
    do: flunk("mailbox did not reach expected size")

  defp await_mailbox_size(pid, minimum, attempts) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, size} when size >= minimum ->
        :ok

      _other ->
        Process.sleep(1)
        await_mailbox_size(pid, minimum, attempts - 1)
    end
  end

  defp holder_generation(holder) do
    holder
    |> then(fn holder -> Task.async(fn -> SessionHolder.generation(holder) end) end)
    |> Task.await(500)
  end

  defp session do
    Session.new(
      role: :initiator,
      session_id: <<1::128>>,
      epoch: 0,
      credential_epoch: 4,
      out_key: :binary.copy(<<0xAA>>, 32),
      in_key: :binary.copy(<<0xBB>>, 32)
    )
  end
end
