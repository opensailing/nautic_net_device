defmodule RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityGuardTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityGuard

  test "a guard cannot outlive the process that established its authority" do
    owner = start_owner()
    test_pid = self()

    creator =
      spawn(fn ->
        {:ok, guard} = AuthorityGuard.start([{owner, owner}])
        send(test_pid, {:owned_guard, self(), guard})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:owned_guard, ^creator, guard}

    on_exit(fn ->
      if Process.alive?(creator), do: Process.exit(creator, :kill)
      if Process.alive?(guard), do: Process.exit(guard, :kill)
    end)

    guard_ref = Process.monitor(guard)
    Process.exit(creator, :kill)

    assert_receive {:DOWN, ^guard_ref, :process, ^guard, _reason}, 250
    refute Process.alive?(guard)
  end

  test "a local registered-name ABA permanently invalidates its authority incarnation" do
    owner = start_owner()
    name = unique_name(:local_owner)
    true = Process.register(owner, name)

    on_exit(fn ->
      if Process.whereis(name), do: Process.unregister(name)
    end)

    assert {:ok, guard} = AuthorityGuard.start([{name, owner}])
    assert AuthorityGuard.current?(guard)

    true = Process.unregister(name)
    true = Process.register(owner, name)

    refute AuthorityGuard.current?(guard)
  end

  test "a global registered-name ABA permanently invalidates its authority incarnation" do
    owner = start_owner()
    name = {__MODULE__, make_ref()}
    assert :yes = :global.register_name(name, owner)

    on_exit(fn -> :global.unregister_name(name) end)

    assert {:ok, guard} = AuthorityGuard.start([{{:global, name}, owner}])
    assert AuthorityGuard.current?(guard)

    :ok = :global.unregister_name(name)
    assert :yes = :global.register_name(name, owner)

    refute AuthorityGuard.current?(guard)
  end

  test "a global register_ext mutation permanently invalidates guarded authority" do
    owner = start_owner()
    name = {__MODULE__, make_ref()}
    assert :yes = :global.register_name(name, owner)

    on_exit(fn -> :global.unregister_name(name) end)

    assert {:ok, guard} = AuthorityGuard.start([{{:global, name}, owner}])
    global_server = Process.whereis(:global_name_server)

    send(
      guard,
      {:trace, global_server, :receive,
       {:"$gen_call", {self(), make_ref()}, {:register_ext, name, owner, :random_exit_name, node()}}}
    )

    refute AuthorityGuard.current?(guard)
  end

  test "distributed global reconciliation permanently invalidates guarded authority" do
    owner = start_owner()
    name = {__MODULE__, make_ref()}
    assert :yes = :global.register_name(name, owner)

    on_exit(fn -> :global.unregister_name(name) end)

    messages = [
      {:exchange_ops, node(), make_ref(), [{:insert, {name, owner, :random_exit_name}}], []},
      {:resolved, node(), [], [], :unused, [], make_ref()},
      {:new_nodes, node(), [{:delete, name}], [], [node()], []}
    ]

    Enum.each(messages, fn message ->
      assert {:ok, guard} = AuthorityGuard.start([{{:global, name}, owner}])
      global_server = Process.whereis(:global_name_server)
      send(guard, {:trace, global_server, :receive, {:"$gen_cast", message}})
      refute AuthorityGuard.current?(guard)
    end)
  end

  test "all OTP 28 global name mutation paths permanently invalidate guarded authority" do
    owner = start_owner()
    name = {__MODULE__, make_ref()}
    assert :yes = :global.register_name(name, owner)

    on_exit(fn -> :global.unregister_name(name) end)

    mutation_messages = [
      {:"$gen_cast", {:init_connect, {7, make_ref()}, node(), {:locker, :none, %{}, self()}}},
      {:group_nodedown, node(), make_ref()},
      {:cancel_connect, node(), make_ref()},
      {:init_connect_ack, node(), make_ref(), make_ref()},
      {:DOWN, make_ref(), :process, owner, :noconnection}
    ]

    Enum.each(mutation_messages, fn message ->
      assert {:ok, guard} = AuthorityGuard.start([{{:global, name}, owner}])
      global_server = Process.whereis(:global_name_server)
      send(guard, {:trace, global_server, :receive, message})
      refute AuthorityGuard.current?(guard)
    end)
  end

  test "unrelated local and global registrations do not invalidate the guarded authority" do
    owner = start_owner()
    local_name = unique_name(:guarded_local_owner)
    global_name = {__MODULE__, make_ref(), :guarded}
    true = Process.register(owner, local_name)
    assert :yes = :global.register_name(global_name, owner)

    other = start_owner()
    other_local_name = unique_name(:other_local_owner)
    other_global_name = {__MODULE__, make_ref(), :other}

    on_exit(fn ->
      if Process.whereis(local_name), do: Process.unregister(local_name)
      if Process.whereis(other_local_name), do: Process.unregister(other_local_name)
      :global.unregister_name(global_name)
      :global.unregister_name(other_global_name)
    end)

    assert {:ok, guard} =
             AuthorityGuard.start([
               {local_name, owner},
               {{:global, global_name}, owner}
             ])

    true = Process.register(other, other_local_name)
    true = Process.unregister(other_local_name)
    assert :yes = :global.register_name(other_global_name, other)
    :ok = :global.unregister_name(other_global_name)

    assert AuthorityGuard.current?(guard)
  end

  test "a via reference requires a cooperative incarnation token" do
    owner = start_owner()

    assert {:error, :owner_authority_unattested} =
             AuthorityGuard.start([{{:via, __MODULE__, :owner}, owner}])
  end

  test "a via incarnation-token death permanently invalidates authority" do
    owner = start_owner()
    incarnation = start_owner()
    reference = {:via, __MODULE__, :owner}

    assert {:ok, guard} = AuthorityGuard.start([{reference, owner, incarnation}])
    assert AuthorityGuard.current?(guard)

    monitor_ref = Process.monitor(incarnation)
    Process.exit(incarnation, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^incarnation, :killed}

    refute AuthorityGuard.current?(guard)
  end

  test "startup rejects a name that is not bound to the expected live process" do
    owner = start_owner()
    replacement = start_owner()
    local_name = unique_name(:mismatched_local_owner)
    true = Process.register(replacement, local_name)

    on_exit(fn ->
      if Process.whereis(local_name), do: Process.unregister(local_name)
    end)

    assert {:error, :owner_authority_changed} =
             AuthorityGuard.start([{local_name, owner}])
  end

  test "concurrent authority checks cannot consume another caller's request" do
    owner = start_owner()
    name = unique_name(:concurrent_owner)
    true = Process.register(owner, name)

    on_exit(fn ->
      if Process.whereis(name), do: Process.unregister(name)
    end)

    assert {:ok, guard} = AuthorityGuard.start([{name, owner}])
    on_exit(fn -> if Process.alive?(guard), do: Process.exit(guard, :kill) end)

    :ok = :sys.suspend(guard)

    first = Task.async(fn -> GenServer.call(guard, :current?, 250) end)
    await_mailbox_size(guard, 1)
    second = Task.async(fn -> GenServer.call(guard, :current?, 250) end)
    await_mailbox_size(guard, 2)
    :ok = :sys.resume(guard)

    assert Task.await(first, 500)
    assert Task.await(second, 500)
  end

  test "unrelated mailbox traffic cannot extend an authority check past its deadline" do
    owner = start_owner()
    name = unique_name(:noisy_owner)
    true = Process.register(owner, name)

    on_exit(fn ->
      if Process.whereis(name), do: Process.unregister(name)
    end)

    assert {:ok, guard} = AuthorityGuard.start([{name, owner}])
    on_exit(fn -> if Process.alive?(guard), do: Process.exit(guard, :kill) end)

    :ok = :sys.suspend(guard)
    check = Task.async(fn -> GenServer.call(guard, :current?, 1_000) end)
    await_mailbox_size(guard, 1)

    Enum.each(1..250_000, fn suffix ->
      send(guard, {:trace, self(), :register, {:unrelated_name, suffix}})
    end)

    started_at = System.monotonic_time(:millisecond)
    :ok = :sys.resume(guard)

    refute Task.await(check, 1_000)
    assert System.monotonic_time(:millisecond) - started_at < 250
  end

  test "a queued authority mutation is processed before a successful check response" do
    owner = start_owner()
    name = unique_name(:queued_mutation_owner)
    true = Process.register(owner, name)

    on_exit(fn ->
      if Process.whereis(name), do: Process.unregister(name)
    end)

    assert {:ok, guard} = AuthorityGuard.start([{name, owner}])
    on_exit(fn -> if Process.alive?(guard), do: Process.exit(guard, :kill) end)

    :ok = :sys.suspend(guard)
    check = Task.async(fn -> GenServer.call(guard, :current?, 250) end)
    await_mailbox_size(guard, 1)

    true = Process.unregister(name)
    true = Process.register(owner, name)
    :ok = :sys.resume(guard)

    refute Task.await(check, 500)
  end

  test "an ABA after the first trace barrier cannot pass the authority check" do
    owner = start_owner()
    name = unique_name(:post_barrier_aba_owner)
    true = Process.register(owner, name)
    old_schedulers = :erlang.system_flag(:schedulers_online, 1)
    old_priority = Process.flag(:priority, :max)

    on_exit(fn ->
      if Process.whereis(name), do: Process.unregister(name)
      Process.flag(:priority, old_priority)
      :erlang.system_flag(:schedulers_online, old_schedulers)
      :erlang.trace_pattern({AuthorityGuard, :bindings_current?, 1}, false, [:local])
    end)

    assert {:ok, guard} = AuthorityGuard.start([{name, owner}])
    on_exit(fn -> if Process.alive?(guard), do: Process.exit(guard, :kill) end)

    :erlang.trace_pattern({AuthorityGuard, :bindings_current?, 1}, true, [:local])
    :erlang.trace(guard, true, [:call, {:tracer, self()}])

    check = Task.async(fn -> AuthorityGuard.current?(guard) end)

    assert_receive {:trace, ^guard, :call, {AuthorityGuard, :bindings_current?, [_state]}},
                   1_000

    true = :erlang.suspend_process(guard)
    true = Process.unregister(name)
    true = Process.register(owner, name)
    true = :erlang.resume_process(guard)

    refute Task.await(check, 2_000)
  end

  test "a process that only replies true cannot forge a guard attestation" do
    owner = start_owner()
    assert {:ok, genuine_guard} = AuthorityGuard.start_attested([{owner, owner}])
    assert AuthorityGuard.current?(genuine_guard)

    fake_guard =
      spawn(fn ->
        receive do
          {:"$gen_call", from, :current?} -> GenServer.reply(from, true)
        end
      end)

    fabricated_attestor = fn challenge ->
      {AuthorityGuard, :guard_attestation, challenge, make_ref(), fake_guard, make_ref(), true}
    end

    refute AuthorityGuard.current?(%{
             pid: fake_guard,
             incarnation: make_ref(),
             attestor: fabricated_attestor
           })
  end

  test "a genuine attestor cannot authenticate a substituted guard identity" do
    owner = start_owner()
    replacement = start_owner()

    assert {:ok, genuine_guard} = AuthorityGuard.start_attested([{owner, owner}])
    assert AuthorityGuard.attested?(genuine_guard)

    refute AuthorityGuard.attested?(%{genuine_guard | pid: replacement})
    refute AuthorityGuard.attested?(%{genuine_guard | incarnation: make_ref()})
    refute AuthorityGuard.current?(%{genuine_guard | pid: replacement})
    refute AuthorityGuard.current?(%{genuine_guard | incarnation: make_ref()})
  end

  defp start_owner do
    start_supervised!(
      Supervisor.child_spec({Task, fn -> Process.sleep(:infinity) end},
        id: make_ref(),
        restart: :temporary
      )
    )
  end

  defp unique_name(prefix) do
    String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
  end

  defp await_mailbox_size(pid, minimum, attempts \\ 100)

  defp await_mailbox_size(_pid, _minimum, 0), do: flunk("mailbox did not reach expected size")

  defp await_mailbox_size(pid, minimum, attempts) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, size} when size >= minimum ->
        :ok

      _other ->
        Process.sleep(1)
        await_mailbox_size(pid, minimum, attempts - 1)
    end
  end
end
