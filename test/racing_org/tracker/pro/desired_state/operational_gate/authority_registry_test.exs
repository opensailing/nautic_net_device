defmodule RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistryTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate
  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistry
  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistry.Root
  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistry.Store
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  defmodule StartupReplacingRegistry do
    alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistry

    def whereis_name({owner_pid, _incarnation_pid, _observer_pid, _registry_pid}),
      do: owner_pid

    def authority_snapshot({owner_pid, incarnation_pid, observer_pid, registry_pid}) do
      registry_ref = Process.monitor(registry_pid)
      Process.exit(registry_pid, :kill)

      receive do
        {:DOWN, ^registry_ref, :process, ^registry_pid, _reason} -> :ok
      end

      case AuthorityRegistry.start_link() do
        {:ok, replacement_registry_pid} ->
          Process.unlink(replacement_registry_pid)

          :erlang.trace(
            replacement_registry_pid,
            true,
            [:receive, {:tracer, observer_pid}]
          )

          send(
            observer_pid,
            {:startup_registry_replaced, registry_pid, replacement_registry_pid}
          )

          {:ok, owner_pid, incarnation_pid}

        {:error, reason} ->
          send(observer_pid, {:startup_registry_replacement_failed, reason})
          {:error, reason}
      end
    end
  end

  defmodule ControllableRegistry do
    def start_link(owner_pid) do
      Agent.start_link(fn ->
        %{owner_pid: owner_pid, incarnation_pid: new_incarnation(self())}
      end)
    end

    def owner(registry, owner_pid) do
      Agent.update(registry, fn state ->
        Process.exit(state.incarnation_pid, :kill)

        %{
          state
          | owner_pid: owner_pid,
            incarnation_pid: new_incarnation(self())
        }
      end)
    end

    def whereis_name(registry), do: Agent.get(registry, & &1.owner_pid)

    def authority_snapshot(registry) do
      Agent.get(registry, fn state ->
        {:ok, state.owner_pid, state.incarnation_pid}
      end)
    end

    defp new_incarnation(registry_pid) do
      spawn(fn ->
        monitor_ref = Process.monitor(registry_pid)

        receive do
          {:DOWN, ^monitor_ref, :process, ^registry_pid, _reason} -> :ok
        end
      end)
    end
  end

  setup do
    ensure_authority_services()
    on_exit(&ensure_authority_services/0)
    :ok
  end

  test "a fabricated gate claim capability cannot reserve authority" do
    term_key = {__MODULE__, make_ref()}
    launch_ref = make_ref()

    fabricated = fn challenge ->
      {OperationalGate, :claim_capability, challenge, launch_ref}
    end

    claim_token = :ets.new(__MODULE__, [:set, :protected])

    assert {:error, :invalid_gate_claimant} =
             AuthorityRegistry.prepare_claim(
               term_key,
               make_ref(),
               self(),
               self(),
               self(),
               claim_token,
               fabricated
             )

    assert :persistent_term.get(term_key, :closed) == :closed
    :persistent_term.erase(term_key)
  end

  test "a dead Gate claim capability cannot authenticate another process" do
    term_key = {__MODULE__, make_ref()}
    registry = Process.whereis(AuthorityRegistry)
    controller = spawn(fn -> Process.sleep(:infinity) end)
    :erlang.trace(registry, true, [:receive, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(registry, false, [:receive])
      if Process.alive?(controller), do: Process.exit(controller, :kill)
      ensure_authority_services()
      :persistent_term.erase(term_key)
    end)

    {:ok, gate} = OperationalGate.start_link(name: nil, term_key: term_key, controller: controller)
    Process.unlink(gate)

    stolen_capability =
      receive do
        {:trace, ^registry, :receive,
         {:"$gen_call", {^gate, _tag},
          {:authority_request, ^gate, _request_token,
           {:prepare_claim, ^term_key, _authority_token, ^gate, ^controller, ^controller, _claim_token,
            claim_capability}}}} ->
          claim_capability
      after
        1_000 -> flunk("Gate claim capability was not observed")
      end

    :erlang.trace(registry, false, [:receive])
    gate_ref = Process.monitor(gate)
    Process.exit(gate, :kill)
    Process.exit(controller, :kill)
    assert_receive {:DOWN, ^gate_ref, :process, ^gate, :killed}, 250

    eventually(fn ->
      entry = :sys.get_state(Store).entries[term_key]
      assert is_map(entry)
      assert entry.gate_pid == nil
    end)

    parent = self()

    attacker =
      spawn(fn ->
        claim_token = :ets.new(__MODULE__, [:set, :protected])

        result =
          AuthorityRegistry.prepare_claim(
            term_key,
            make_ref(),
            self(),
            controller,
            self(),
            claim_token,
            stolen_capability
          )

        send(parent, {:stale_gate_claim_result, self(), result})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> if Process.alive?(attacker), do: Process.exit(attacker, :kill) end)

    assert_receive {:stale_gate_claim_result, ^attacker, result}, 1_000
    assert {:error, :invalid_gate_claimant} = result
  end

  test "a dead Store registration capability cannot authenticate another process" do
    root = Process.whereis(Root)
    :erlang.trace(root, true, [:receive, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(root, false, [:receive])
      ensure_authority_services()
    end)

    stop_authority_registry()
    stop_authority_store()
    start_authority_store()
    genuine_store = Process.whereis(Store)

    stolen_capability =
      receive do
        {:trace, ^root, :receive,
         {:"$gen_call", {^genuine_store, _tag},
          {:authority_request, ^genuine_store, _request_token,
           {:register_store, ^genuine_store, registration_capability}}}} ->
          registration_capability
      after
        1_000 -> flunk("Store registration capability was not observed")
      end

    :erlang.trace(root, false, [:receive])
    stop_authority_store()

    eventually(fn ->
      assert {:error, :gate_authority_unavailable} = Root.store_attestation()
    end)

    parent = self()

    attacker =
      spawn(fn ->
        send(parent, {:stale_store_registration_result, self(), Root.register_store(self(), stolen_capability)})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> if Process.alive?(attacker), do: Process.exit(attacker, :kill) end)

    assert_receive {:stale_store_registration_result, ^attacker, result}, 1_000
    assert {:error, :invalid_authority_store} = result
  end

  test "a dead Registry registration capability cannot authenticate another process" do
    store = Process.whereis(Store)
    :erlang.trace(store, true, [:receive, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(store, false, [:receive])
      ensure_authority_services()
    end)

    stop_authority_registry()
    start_authority_registry()
    genuine_registry = Process.whereis(AuthorityRegistry)

    stolen_capability =
      receive do
        {:trace, ^store, :receive,
         {:"$gen_call", {^genuine_registry, _tag},
          {:authority_request, ^genuine_registry, _request_token,
           {:register_registry, ^genuine_registry, registration_capability}}}} ->
          registration_capability
      after
        1_000 -> flunk("Registry registration capability was not observed")
      end

    :erlang.trace(store, false, [:receive])
    stop_authority_registry()
    parent = self()

    attacker =
      spawn(fn ->
        send(parent, {
          :stale_registry_registration_result,
          self(),
          Store.register_registry(self(), stolen_capability)
        })

        Process.sleep(:infinity)
      end)

    on_exit(fn -> if Process.alive?(attacker), do: Process.exit(attacker, :kill) end)

    assert_receive {:stale_registry_registration_result, ^attacker, result}, 1_000
    assert {:error, :invalid_authority_registry} = result
  end

  test "raw Root and Store privileged calls fail closed without terminating authority services" do
    root_pid = Process.whereis(Root)
    store_pid = Process.whereis(Store)

    assert {:error, :invalid_authority_registry} =
             GenServer.call(
               Store,
               {:register_registry, self(), make_ref()}
             )

    assert {:error, :gate_authority_unavailable} =
             GenServer.call(
               Store,
               {:close, make_ref(), make_ref(), self(), make_ref()}
             )

    assert {:error, :invalid_authority_store} =
             GenServer.call(
               Root,
               {:register_store, self(), make_ref()}
             )

    assert Process.whereis(Root) == root_pid
    assert Process.whereis(Store) == store_pid
  end

  test "a spoofed GenServer caller cannot close a lease without the private gate capability" do
    term_key = {__MODULE__, make_ref()}
    {:ok, gate} = OperationalGate.start_link(name: nil, term_key: term_key, controller: self())

    on_exit(fn ->
      stop_if_alive(gate)
      :persistent_term.erase(term_key)
    end)

    assert :ok = open_gate(gate, valid_binding())
    assert OperationalGate.open?(term_key)

    {:open, authority_token, _lease_token, _binding, [^gate | _lease_pids], _authority_bindings, _controller_reference,
     _authority_guard_pid} =
      :persistent_term.get(term_key)

    send(
      AuthorityRegistry,
      {:"$gen_call", {gate, make_ref()}, {:close, term_key, authority_token, gate, make_ref()}}
    )

    _state = :sys.get_state(AuthorityRegistry)
    assert OperationalGate.open?(term_key)
  end

  test "replaceable public authority names cannot authenticate a fabricated lease" do
    term_key = {__MODULE__, make_ref()}
    {:ok, gate} = OperationalGate.start_link(name: nil, term_key: term_key, controller: self())
    Process.unlink(gate)

    on_exit(fn ->
      stop_if_alive(gate)
      :persistent_term.erase(term_key)
    end)

    assert :ok = open_gate(gate, valid_binding())
    assert OperationalGate.open?(term_key)

    stolen_root_pid = Process.whereis(Root)
    store_pid = Process.whereis(Store)

    assert {:ok, ^store_pid, stolen_store_incarnation, stolen_root_attestor} =
             Root.store_attestation()

    assert Root.attests_store?(
             stolen_root_attestor,
             stolen_root_pid,
             store_pid,
             stolen_store_incarnation
           )

    registry_pid = Process.whereis(AuthorityRegistry)
    store_ref = Process.monitor(store_pid)
    registry_ref = Process.monitor(registry_pid)
    gate_ref = Process.monitor(gate)

    Process.exit(store_pid, :kill)

    assert_receive {:DOWN, ^store_ref, :process, ^store_pid, :killed}, 250
    assert_receive {:DOWN, ^registry_ref, :process, ^registry_pid, _reason}, 250
    assert_receive {:DOWN, ^gate_ref, :process, ^gate, _reason}, 250

    eventually(fn ->
      refute Process.whereis(Store)
      refute Process.whereis(AuthorityRegistry)
      assert {:error, :gate_authority_unavailable} = Root.store_attestation()

      refute Root.attests_store?(
               stolen_root_attestor,
               stolen_root_pid,
               store_pid,
               stolen_store_incarnation
             )
    end)

    parent = self()

    fake_store =
      spawn(fn ->
        true = Process.register(self(), Store)

        _table =
          :ets.new(Store, [
            :named_table,
            :protected,
            :set,
            read_concurrency: true
          ])

        send(parent, {:fake_store_ready, self()})

        receive do
          {:install_fabricated_entry, entry} ->
            true = :ets.insert(Store, entry)
            send(parent, {:fabricated_entry_installed, self()})
        end

        fake_server_loop(:ok)
      end)

    on_exit(fn -> kill_and_wait(fake_store) end)
    assert_receive {:fake_store_ready, ^fake_store}

    fake_registry =
      spawn(fn ->
        true = Process.register(self(), AuthorityRegistry)
        send(parent, {:fake_registry_ready, self()})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> kill_and_wait(fake_registry) end)
    assert_receive {:fake_registry_ready, ^fake_registry}

    fake_controller = spawn(fn -> Process.sleep(:infinity) end)

    fake_guard =
      spawn(fn ->
        fake_server_loop(fn
          :current? -> true
          _message -> :ok
        end)
      end)

    fake_gate =
      spawn(fn ->
        lease_token = :ets.new(__MODULE__, [:set, :protected])
        true = :ets.insert(lease_token, {:state, :active})
        send(parent, {:fake_gate_ready, self(), lease_token})
        fake_server_loop(:ok)
      end)

    Enum.each([fake_controller, fake_guard, fake_gate], fn pid ->
      on_exit(fn -> kill_and_wait(pid) end)
    end)

    assert_receive {:fake_gate_ready, ^fake_gate, lease_token}

    authority_token = make_ref()
    binding = valid_binding()
    lease_pids = [fake_gate, fake_controller, fake_guard]
    authority_bindings = Map.new(Contract.sections(), &{&1, {fake_controller, fake_controller}})

    fabricated_lease =
      {:open, authority_token, lease_token, binding, lease_pids, authority_bindings, fake_controller, fake_guard}

    send(
      fake_store,
      {:install_fabricated_entry,
       {term_key, stolen_root_attestor, stolen_root_pid, stolen_store_incarnation, fake_registry, authority_token,
        fake_gate, fake_controller, fake_controller, fabricated_lease}}
    )

    assert_receive {:fabricated_entry_installed, ^fake_store}
    :persistent_term.put(term_key, fabricated_lease)

    refute OperationalGate.open?(term_key)
    refute OperationalGate.operational?(7, <<0x71::128>>, term_key)
  end

  test "replacing Root and every public descendant cannot recreate its attestation" do
    term_key = {__MODULE__, make_ref()}
    {:ok, gate} = OperationalGate.start_link(name: nil, term_key: term_key, controller: self())
    Process.unlink(gate)

    on_exit(fn ->
      stop_if_alive(gate)
      :persistent_term.erase(term_key)
    end)

    assert :ok = open_gate(gate, valid_binding())
    assert OperationalGate.open?(term_key)

    root_pid = Process.whereis(Root)
    store_pid = Process.whereis(Store)
    registry_pid = Process.whereis(AuthorityRegistry)

    assert {:ok, ^store_pid, store_incarnation, root_attestor} =
             Root.store_attestation()

    root_ref = Process.monitor(root_pid)
    store_ref = Process.monitor(store_pid)
    registry_ref = Process.monitor(registry_pid)
    gate_ref = Process.monitor(gate)
    Process.exit(root_pid, :kill)

    assert_receive {:DOWN, ^root_ref, :process, ^root_pid, :killed}, 250
    assert_receive {:DOWN, ^store_ref, :process, ^store_pid, _reason}, 250
    assert_receive {:DOWN, ^registry_ref, :process, ^registry_pid, _reason}, 250
    assert_receive {:DOWN, ^gate_ref, :process, ^gate, _reason}, 250

    eventually(fn ->
      refute Process.whereis(Root)
      refute Process.whereis(Store)
      refute Process.whereis(AuthorityRegistry)
    end)

    parent = self()

    fake_root =
      spawn(fn ->
        true = Process.register(self(), Root)

        _table =
          :ets.new(Root, [
            :named_table,
            :protected,
            :set,
            read_concurrency: true
          ])

        send(parent, {:fake_root_ready, self()})

        receive do
          {:install_fabricated_root, entry} ->
            true = :ets.insert(Root, entry)
            send(parent, {:fabricated_root_installed, self()})
        end

        fake_server_loop(:ok)
      end)

    on_exit(fn -> kill_and_wait(fake_root) end)
    assert_receive {:fake_root_ready, ^fake_root}

    fake_store =
      spawn(fn ->
        true = Process.register(self(), Store)

        _table =
          :ets.new(Store, [
            :named_table,
            :protected,
            :set,
            read_concurrency: true
          ])

        send(parent, {:replacement_fake_store_ready, self()})

        receive do
          {:install_fabricated_entry, entry} ->
            true = :ets.insert(Store, entry)
            send(parent, {:replacement_fabricated_entry_installed, self()})
        end

        fake_server_loop(:ok)
      end)

    on_exit(fn -> kill_and_wait(fake_store) end)
    assert_receive {:replacement_fake_store_ready, ^fake_store}

    fake_registry =
      spawn(fn ->
        true = Process.register(self(), AuthorityRegistry)
        send(parent, {:replacement_fake_registry_ready, self()})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> kill_and_wait(fake_registry) end)
    assert_receive {:replacement_fake_registry_ready, ^fake_registry}

    fake_controller = spawn(fn -> Process.sleep(:infinity) end)

    fake_guard =
      spawn(fn ->
        fake_server_loop(fn
          :current? -> true
          _message -> :ok
        end)
      end)

    fake_gate =
      spawn(fn ->
        lease_token = :ets.new(__MODULE__, [:set, :protected])
        true = :ets.insert(lease_token, {:state, :active})
        send(parent, {:replacement_fake_gate_ready, self(), lease_token})
        fake_server_loop(:ok)
      end)

    Enum.each([fake_controller, fake_guard, fake_gate], fn pid ->
      on_exit(fn -> kill_and_wait(pid) end)
    end)

    assert_receive {:replacement_fake_gate_ready, ^fake_gate, lease_token}

    fake_store_incarnation = make_ref()

    send(
      fake_root,
      {:install_fabricated_root, {:store, fake_store, fake_store_incarnation, root_attestor}}
    )

    assert_receive {:fabricated_root_installed, ^fake_root}

    authority_token = make_ref()
    binding = valid_binding()
    lease_pids = [fake_gate, fake_controller, fake_guard]
    authority_bindings = Map.new(Contract.sections(), &{&1, {fake_controller, fake_controller}})

    fabricated_lease =
      {:open, authority_token, lease_token, binding, lease_pids, authority_bindings, fake_controller, fake_guard}

    send(
      fake_store,
      {:install_fabricated_entry,
       {term_key, root_attestor, fake_root, fake_store_incarnation, fake_registry, authority_token, fake_gate,
        fake_controller, fake_controller, fabricated_lease}}
    )

    assert_receive {:replacement_fabricated_entry_installed, ^fake_store}
    :persistent_term.put(term_key, fabricated_lease)

    assert {:error, :gate_authority_unavailable} = Root.store_attestation()

    refute Root.attests_store?(
             root_attestor,
             fake_root,
             fake_store,
             fake_store_incarnation
           )

    refute OperationalGate.open?(term_key)
    refute OperationalGate.operational?(7, <<0x71::128>>, term_key)

    refute Root.attests_store?(
             root_attestor,
             root_pid,
             store_pid,
             store_incarnation
           )
  end

  test "the authority root rejects a fabricated Store-module capability" do
    store_pid = Process.whereis(Store)

    assert {:ok, ^store_pid, store_incarnation, store_attestor} =
             Root.store_attestation()

    fabricated_capability = fn challenge ->
      {Store, :store_capability, challenge, make_ref()}
    end

    assert {:error, :invalid_authority_store} =
             Root.register_store(self(), fabricated_capability)

    assert {:error, :invalid_authority_store} =
             Root.register_store(self(), &Store.start_link/1)

    assert {:ok, ^store_pid, ^store_incarnation, ^store_attestor} =
             Root.store_attestation()
  end

  test "a replacement genuine Store receives a fresh root incarnation" do
    old_store_pid = Process.whereis(Store)
    registry_pid = Process.whereis(AuthorityRegistry)

    assert {:ok, ^old_store_pid, old_store_incarnation, old_store_attestor} = Root.store_attestation()

    old_store_ref = Process.monitor(old_store_pid)
    registry_ref = Process.monitor(registry_pid)
    Process.exit(old_store_pid, :kill)

    assert_receive {:DOWN, ^old_store_ref, :process, ^old_store_pid, :killed}, 250
    assert_receive {:DOWN, ^registry_ref, :process, ^registry_pid, _reason}, 250

    eventually(fn ->
      assert {:error, :gate_authority_unavailable} = Root.store_attestation()
    end)

    start_authority_store()
    new_store_pid = Process.whereis(Store)

    assert {:ok, ^new_store_pid, new_store_incarnation, new_store_attestor} = Root.store_attestation()

    refute new_store_pid == old_store_pid
    refute new_store_incarnation == old_store_incarnation
    refute new_store_attestor == old_store_attestor

    refute Root.attests_store?(
             old_store_attestor,
             Process.whereis(Root),
             old_store_pid,
             old_store_incarnation
           )

    start_authority_registry()
  end

  test "Registry mutations cannot move to a replacement Store before Store-down handling" do
    term_key = {__MODULE__, make_ref()}
    parent = self()

    controller =
      spawn(fn ->
        receive do
          {:open, gate} ->
            send(parent, {:replacement_store_open, open_gate(gate, valid_binding())})
            Process.sleep(:infinity)
        end
      end)

    {:ok, gate} =
      OperationalGate.start_link(
        name: nil,
        term_key: term_key,
        controller: controller
      )

    Process.unlink(gate)
    registry_pid = Process.whereis(AuthorityRegistry)
    old_store_pid = Process.whereis(Store)

    on_exit(fn ->
      resume_if_alive(AuthorityRegistry)
      stop_if_alive(gate)
      if Process.alive?(controller), do: Process.exit(controller, :kill)
      ensure_authority_services()
      :persistent_term.erase(term_key)
    end)

    :sys.suspend(registry_pid)
    send(controller, {:open, gate})

    eventually(fn ->
      {:messages, messages} = Process.info(registry_pid, :messages)

      assert Enum.any?(messages, fn
               {:"$gen_call", _from,
                {:authority_request, ^gate, _request_token,
                 {:publish_lease, ^term_key, _authority_token, ^gate, _gate_capability, ^controller, _lease}}} ->
                 true

               _other ->
                 false
             end)
    end)

    stop_authority_store()
    start_authority_store()
    replacement_store_pid = Process.whereis(Store)
    refute replacement_store_pid == old_store_pid

    :erlang.trace(
      replacement_store_pid,
      true,
      [:receive, {:tracer, self()}]
    )

    :sys.resume(registry_pid)

    refute_receive {:trace, ^replacement_store_pid, :receive,
                    {:"$gen_call", _from,
                     {:authority_request, ^registry_pid, _request_token,
                      {:prepare_lease, _registry_capability, ^term_key, _authority_token, ^gate, _gate_capability,
                       ^controller, _lease}}}},
                   250

    assert_receive {:replacement_store_open, {:error, _reason}}, 1_000
  end

  test "authority root death tears down Store, Registry, and every live gate" do
    term_key = {__MODULE__, make_ref()}
    {:ok, gate} = OperationalGate.start_link(name: nil, term_key: term_key, controller: self())
    Process.unlink(gate)

    on_exit(fn ->
      stop_if_alive(gate)
      ensure_authority_services()
      :persistent_term.erase(term_key)
    end)

    assert :ok = open_gate(gate, valid_binding())
    assert OperationalGate.open?(term_key)

    root_pid = Process.whereis(Root)
    store_pid = Process.whereis(Store)
    registry_pid = Process.whereis(AuthorityRegistry)
    root_ref = Process.monitor(root_pid)
    store_ref = Process.monitor(store_pid)
    registry_ref = Process.monitor(registry_pid)
    gate_ref = Process.monitor(gate)

    Process.exit(root_pid, :kill)

    assert_receive {:DOWN, ^root_ref, :process, ^root_pid, :killed}, 250
    assert_receive {:DOWN, ^store_ref, :process, ^store_pid, _reason}, 250
    assert_receive {:DOWN, ^registry_ref, :process, ^registry_pid, _reason}, 250
    assert_receive {:DOWN, ^gate_ref, :process, ^gate, _reason}, 250

    refute OperationalGate.open?(term_key)
    refute OperationalGate.operational?(7, <<0x71::128>>, term_key)
  end

  test "Gate startup cannot claim through a Registry replacement after sampling its principal" do
    term_key = {__MODULE__, make_ref()}
    old_registry_pid = Process.whereis(AuthorityRegistry)
    observer_pid = self()
    incarnation_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(incarnation_pid), do: Process.exit(incarnation_pid, :kill)
      ensure_authority_services()
      :persistent_term.erase(term_key)
    end)

    candidate =
      Task.async(fn ->
        controller_reference =
          {:via, StartupReplacingRegistry, {self(), incarnation_pid, observer_pid, old_registry_pid}}

        OperationalGate.start_link(
          name: nil,
          term_key: term_key,
          controller: controller_reference
        )
      end)

    assert_receive {:startup_registry_replaced, ^old_registry_pid, replacement_registry_pid},
                   250

    assert {:error, _reason} = Task.await(candidate, 1_000)

    refute_receive {:trace, ^replacement_registry_pid, :receive,
                    {:"$gen_call", _from,
                     {:authority_request, _principal_pid, _request_token,
                      {:prepare_claim, ^term_key, _authority_token, _gate_pid, _controller_reference, _controller_pid,
                       _claim_token, _claim_capability}}}},
                   50
  end

  test "registry restart preserves the pinned controller PID behind a live reference" do
    term_key = {__MODULE__, make_ref()}
    parent = self()

    prior_controller =
      spawn(fn ->
        receive do
          {:open, gate} ->
            send(parent, {:prior_open, open_gate(gate, valid_binding())})
            Process.sleep(:infinity)
        end
      end)

    replacement_controller =
      spawn(fn ->
        receive do
          {:open, gate} ->
            send(parent, {:replacement_open, open_gate(gate, valid_binding())})
            Process.sleep(:infinity)
        end
      end)

    {:ok, resolver} = ControllableRegistry.start_link(prior_controller)
    controller_reference = {:via, ControllableRegistry, resolver}

    {:ok, gate} =
      OperationalGate.start_link(
        name: nil,
        term_key: term_key,
        controller: controller_reference
      )

    Process.unlink(gate)

    on_exit(fn ->
      stop_if_alive(gate)
      if Process.alive?(resolver), do: Agent.stop(resolver)
      if Process.alive?(prior_controller), do: Process.exit(prior_controller, :kill)
      if Process.alive?(replacement_controller), do: Process.exit(replacement_controller, :kill)
      :persistent_term.erase(term_key)
    end)

    send(prior_controller, {:open, gate})
    assert_receive {:prior_open, :ok}
    assert OperationalGate.open?(term_key)

    stop_authority_registry()
    eventually(fn -> refute Process.alive?(gate) end)
    ControllableRegistry.owner(resolver, replacement_controller)
    start_authority_registry()

    assert {:error, :gate_not_controller} =
             OperationalGate.start_link(
               name: nil,
               term_key: term_key,
               controller: controller_reference
             )

    refute OperationalGate.open?(term_key)
    assert Process.alive?(prior_controller)
  end

  test "close revokes the local lease before a suspended registry can respond" do
    term_key = {__MODULE__, make_ref()}
    {:ok, gate} = OperationalGate.start_link(name: nil, term_key: term_key, controller: self())

    on_exit(fn ->
      resume_if_alive(AuthorityRegistry)
      stop_if_alive(gate)
      :persistent_term.erase(term_key)
    end)

    assert :ok = open_gate(gate, valid_binding())
    assert OperationalGate.open?(term_key)
    :sys.suspend(AuthorityRegistry)

    closer = Task.async(fn -> OperationalGate.close(gate) end)
    assert {:ok, :ok} = Task.yield(closer, 250)
    refute OperationalGate.open?(term_key)

    :sys.resume(AuthorityRegistry)
    eventually(fn -> assert OperationalGate.status(gate) == :closed end)
  end

  test "an authority mismatch remains locally revoked while the store is suspended" do
    term_key = {__MODULE__, make_ref()}
    replacement_owner = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, resolver} = ControllableRegistry.start_link(self())
    owner_reference = {:via, ControllableRegistry, resolver}
    {:ok, gate} = OperationalGate.start_link(name: nil, term_key: term_key, controller: self())

    on_exit(fn ->
      resume_if_alive(Store)
      stop_if_alive(gate)
      if Process.alive?(resolver), do: Agent.stop(resolver)
      if Process.alive?(replacement_owner), do: Process.exit(replacement_owner, :kill)
      :persistent_term.erase(term_key)
    end)

    controller_capability = gate |> :sys.get_state() |> Map.fetch!(:controller_capability)

    assert :ok =
             OperationalGate.open_owned(
               gate,
               controller_capability,
               self(),
               [],
               valid_binding(),
               Map.new(Contract.sections(), &{&1, {owner_reference, self()}})
             )

    assert OperationalGate.open?(term_key)
    :sys.suspend(Store)

    ControllableRegistry.owner(resolver, replacement_owner)
    refute OperationalGate.open?(term_key)

    ControllableRegistry.owner(resolver, self())
    refute OperationalGate.open?(term_key)
  end

  test "a timed-out publication cannot become operational when its queued call runs" do
    term_key = {__MODULE__, make_ref()}
    {:ok, gate} = OperationalGate.start_link(name: nil, term_key: term_key, controller: self())

    on_exit(fn ->
      resume_if_alive(AuthorityRegistry)
      stop_if_alive(gate)
      :persistent_term.erase(term_key)
    end)

    :sys.suspend(AuthorityRegistry)

    assert {:error, :gate_authority_unavailable} = open_gate(gate, valid_binding())
    refute OperationalGate.open?(term_key)

    :sys.resume(AuthorityRegistry)
    _state = :sys.get_state(AuthorityRegistry)
    _store_state = :sys.get_state(Store)
    refute OperationalGate.open?(term_key)
    assert OperationalGate.status(gate) == :closed
  end

  test "a timed-out claim from a dead gate cannot pin its controller" do
    term_key = {__MODULE__, make_ref()}
    stale_controller = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      resume_if_alive(AuthorityRegistry)
      if Process.alive?(stale_controller), do: Process.exit(stale_controller, :kill)
      :persistent_term.erase(term_key)
    end)

    :sys.suspend(AuthorityRegistry)

    assert {:error, :gate_authority_unavailable} =
             OperationalGate.start_link(
               name: nil,
               term_key: term_key,
               controller: stale_controller
             )

    :sys.resume(AuthorityRegistry)
    _state = :sys.get_state(AuthorityRegistry)
    _store_state = :sys.get_state(Store)

    assert {:ok, gate} =
             OperationalGate.start_link(
               name: nil,
               term_key: term_key,
               controller: self()
             )

    on_exit(fn -> stop_if_alive(gate) end)
    assert OperationalGate.status(gate) == :closed
  end

  test "a forged startup confirmation cannot consume the starter's real confirmation" do
    term_key = {__MODULE__, make_ref()}
    parent = self()
    old_schedulers = :erlang.system_flag(:schedulers_online, 1)

    on_exit(fn ->
      :erlang.system_flag(:schedulers_online, old_schedulers)
      ensure_authority_services()
      :persistent_term.erase(term_key)
    end)

    stop_authority_registry()

    start_authority_registry(
      claim_confirm_observer: fn gate_pid ->
        send(parent, {:startup_claim_confirmed, self(), gate_pid})

        receive do
          {:release_startup_claim, ^gate_pid} -> :ok
        end
      end
    )

    starter =
      Task.async(fn ->
        Process.flag(:priority, :low)
        send(parent, {:gate_starter, self()})
        OperationalGate.start_link(name: nil, term_key: term_key, controller: self())
      end)

    assert_receive {:gate_starter, starter_pid}, 250
    assert_receive {:startup_claim_confirmed, registry_pid, gate_pid}, 250

    send(
      gate_pid,
      {:"$gen_call", {starter_pid, make_ref()}, {:confirm_start_link, starter_pid}}
    )

    send(registry_pid, {:release_startup_claim, gate_pid})

    assert {:ok, ^gate_pid} = Task.await(starter, 1_000)
    stop_if_alive(gate_pid)
  end

  test "a prepared claim whose reply is lost cannot pin its controller" do
    term_key = {__MODULE__, make_ref()}
    candidate_name = {:global, {__MODULE__, make_ref()}}
    stale_controller = spawn(fn -> Process.sleep(:infinity) end)
    parent = self()

    on_exit(fn ->
      stop_if_alive(GenServer.whereis(candidate_name))
      if Process.alive?(stale_controller), do: Process.exit(stale_controller, :kill)
      ensure_authority_services()
      :persistent_term.erase(term_key)
    end)

    stop_authority_registry()

    start_authority_registry(
      claim_prepare_observer: fn gate_pid ->
        send(parent, {:claim_prepared, self(), gate_pid})

        receive do
          {:release_claim_prepare, ^gate_pid} -> :ok
        end
      end
    )

    candidate =
      Task.async(fn ->
        OperationalGate.start_link(
          name: candidate_name,
          term_key: term_key,
          controller: stale_controller
        )
      end)

    assert_receive {:claim_prepared, registry_pid, gate_pid}, 250
    gate_ref = Process.monitor(gate_pid)

    assert {:error, :gate_authority_unavailable} = Task.await(candidate, 250)
    assert_receive {:DOWN, ^gate_ref, :process, ^gate_pid, _reason}, 250

    _store_state = :sys.get_state(Store)
    send(registry_pid, {:release_claim_prepare, gate_pid})
    _registry_state = :sys.get_state(AuthorityRegistry)

    stop_authority_registry()
    start_authority_registry()

    assert {:ok, gate} =
             OperationalGate.start_link(
               name: nil,
               term_key: term_key,
               controller: self()
             )

    on_exit(fn -> stop_if_alive(gate) end)
    assert OperationalGate.status(gate) == :closed
  end

  test "a claim process killed after preparation cannot leave reserved authority" do
    term_key = {__MODULE__, make_ref()}
    stale_controller = spawn(fn -> Process.sleep(:infinity) end)
    parent = self()

    on_exit(fn ->
      if Process.alive?(stale_controller), do: Process.exit(stale_controller, :kill)
      ensure_authority_services()
      :persistent_term.erase(term_key)
    end)

    stop_authority_registry()

    start_authority_registry(
      claim_prepare_observer: fn gate_pid ->
        send(parent, {:claim_prepared, self(), gate_pid})

        receive do
          {:release_claim_prepare, ^gate_pid} -> :ok
        end
      end
    )

    candidate =
      Task.async(fn ->
        OperationalGate.start_link(
          name: nil,
          term_key: term_key,
          controller: stale_controller
        )
      end)

    assert_receive {:claim_prepared, registry_pid, gate_pid}, 250
    gate_ref = Process.monitor(gate_pid)
    Process.exit(gate_pid, :kill)

    assert {:error, _reason} = Task.await(candidate, 250)
    assert_receive {:DOWN, ^gate_ref, :process, ^gate_pid, :killed}, 250

    _store_state = :sys.get_state(Store)
    send(registry_pid, {:release_claim_prepare, gate_pid})
    _registry_state = :sys.get_state(AuthorityRegistry)

    stop_authority_registry()
    start_authority_registry()

    assert {:ok, gate} =
             OperationalGate.start_link(
               name: nil,
               term_key: term_key,
               controller: self()
             )

    on_exit(fn -> stop_if_alive(gate) end)
    assert OperationalGate.status(gate) == :closed
  end

  test "an exact final claim confirmation replay is idempotent and cannot strand startup" do
    term_key = {__MODULE__, make_ref()}
    parent = self()
    claim_confirm_count = :atomics.new(1, [])

    stop_authority_registry()

    start_authority_registry(
      claim_confirm_observer: fn gate_pid ->
        if :atomics.add_get(claim_confirm_count, 1, 1) == 1 do
          send(parent, {:claim_confirmed, self(), gate_pid})

          receive do
            {:release_claim_confirm, ^gate_pid} -> :ok
          end
        end
      end
    )

    registry_pid = Process.whereis(AuthorityRegistry)
    :erlang.trace(registry_pid, true, [:receive, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(registry_pid, false, [:receive])
      ensure_authority_services()
      :persistent_term.erase(term_key)
    end)

    candidate =
      Task.async(fn ->
        send(parent, {:claim_starter, self()})
        OperationalGate.start_link(name: nil, term_key: term_key, controller: self())
      end)

    assert_receive {:claim_starter, controller_pid}, 250

    assert_receive {:trace, ^registry_pid, :receive,
                    {:"$gen_call", {gate_pid, _tag},
                     {:authority_request, gate_pid, _request_token,
                      {:confirm_claim, ^term_key, _authority_token, gate_pid, _gate_capability, _claim_token}} = request}},
                   250

    assert_receive {:claim_confirmed, ^registry_pid, ^gate_pid}, 250

    on_exit(fn ->
      if Process.alive?(gate_pid) and
           Process.info(gate_pid, :status) == {:status, :suspended} do
        :erlang.resume_process(gate_pid)
      end

      stop_if_alive(gate_pid)
    end)

    true = :erlang.suspend_process(gate_pid)

    replayer = Task.async(fn -> GenServer.call(AuthorityRegistry, request) end)
    send(registry_pid, {:release_claim_confirm, gate_pid})

    replay_result = Task.await(replayer, 1_000)
    true = :erlang.resume_process(gate_pid)

    assert {:ok, ^gate_pid} = Task.await(candidate, 1_000)
    assert {:ok, ^controller_pid} = replay_result
    stop_if_alive(gate_pid)
  end

  test "a lost final claim confirmation preserves only the locally activated controller pin" do
    term_key = {__MODULE__, make_ref()}
    stale_controller = spawn(fn -> Process.sleep(:infinity) end)
    parent = self()

    on_exit(fn ->
      if Process.alive?(stale_controller), do: Process.exit(stale_controller, :kill)
      ensure_authority_services()
      :persistent_term.erase(term_key)
    end)

    stop_authority_registry()

    start_authority_registry(
      claim_confirm_observer: fn gate_pid ->
        send(parent, {:claim_confirmed, self(), gate_pid})

        receive do
          {:release_claim_confirm, ^gate_pid} -> :ok
        end
      end
    )

    candidate =
      Task.async(fn ->
        OperationalGate.start_link(
          name: nil,
          term_key: term_key,
          controller: stale_controller
        )
      end)

    assert_receive {:claim_confirmed, registry_pid, gate_pid}, 250
    gate_ref = Process.monitor(gate_pid)

    assert {:error, :gate_authority_unavailable} = Task.await(candidate, 250)
    assert_receive {:DOWN, ^gate_ref, :process, ^gate_pid, _reason}, 250

    _store_state = :sys.get_state(Store)
    send(registry_pid, {:release_claim_confirm, gate_pid})
    _registry_state = :sys.get_state(AuthorityRegistry)

    stop_authority_registry()
    start_authority_registry()

    assert {:error, :gate_controller_mismatch} =
             OperationalGate.start_link(
               name: nil,
               term_key: term_key,
               controller: self()
             )

    assert {:ok, gate} =
             OperationalGate.start_link(
               name: nil,
               term_key: term_key,
               controller: stale_controller
             )

    on_exit(fn -> stop_if_alive(gate) end)
    assert OperationalGate.status(gate) == :closed
  end

  test "the production gate key rejects a non-default first controller" do
    default_term_key = {OperationalGate, :state}
    :persistent_term.erase(default_term_key)

    assert {:error, :gate_controller_mismatch} =
             OperationalGate.start_link(name: nil, controller: self())

    refute OperationalGate.open?(default_term_key)
    :persistent_term.erase(default_term_key)
  end

  test "authority store death tears down the registry and every live gate fail closed" do
    term_key = {__MODULE__, make_ref()}
    {:ok, gate} = OperationalGate.start_link(name: nil, term_key: term_key, controller: self())
    Process.unlink(gate)

    on_exit(fn ->
      stop_if_alive(gate)
      ensure_authority_services()
      :persistent_term.erase(term_key)
    end)

    assert :ok = open_gate(gate, valid_binding())
    assert OperationalGate.open?(term_key)

    registry_pid = Process.whereis(AuthorityRegistry)
    store_pid = Process.whereis(Store)
    registry_ref = Process.monitor(registry_pid)
    gate_ref = Process.monitor(gate)

    Process.exit(store_pid, :kill)

    assert_receive {:DOWN, ^registry_ref, :process, ^registry_pid, _reason}, 250
    assert_receive {:DOWN, ^gate_ref, :process, ^gate, _reason}, 250
    refute OperationalGate.open?(term_key)
  end

  defp fake_server_loop(reply) do
    receive do
      {:"$gen_call", from, message} ->
        response = if is_function(reply, 1), do: reply.(message), else: reply
        GenServer.reply(from, response)
        fake_server_loop(reply)

      _other ->
        fake_server_loop(reply)
    end
  end

  defp open_gate(gate, binding) do
    owner = self()

    controller_capability = gate |> :sys.get_state() |> Map.fetch!(:controller_capability)

    OperationalGate.open_owned(
      gate,
      controller_capability,
      owner,
      [],
      binding,
      Map.new(Contract.sections(), &{&1, {owner, owner}})
    )
  end

  defp valid_binding do
    %{
      credential_epoch: 7,
      storage_epoch: <<0x71::128>>,
      generation: 17,
      manifest_hash: :binary.copy(<<0x72>>, 32)
    }
  end

  defp ensure_authority_services do
    unless authority_root_healthy?() do
      stop_authority_registry()
      stop_authority_store()
      stop_authority_root()
      start_authority_root()
    end

    unless authority_store_healthy?() do
      stop_authority_registry()
      stop_authority_store()
      start_authority_store()
    end

    stop_authority_registry()
    start_authority_registry()
    :ok
  end

  defp authority_root_healthy? do
    case Process.whereis(Root) do
      root_pid when is_pid(root_pid) ->
        :ets.info(Root, :owner) == root_pid and
          :ets.info(Root, :protection) == :protected

      nil ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp authority_store_healthy? do
    case Root.store_attestation() do
      {:ok, store_pid, store_incarnation, store_attestor} ->
        root_pid = Process.whereis(Root)

        Process.whereis(Store) == store_pid and
          :ets.info(Store, :owner) == store_pid and
          Root.attests_store?(
            store_attestor,
            root_pid,
            store_pid,
            store_incarnation
          )

      {:error, _reason} ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp start_authority_root do
    {:ok, root_pid} = Root.start_link()
    Process.unlink(root_pid)
    :ok
  end

  defp start_authority_store do
    {:ok, store_pid} = Store.start_link()
    Process.unlink(store_pid)
    :ok
  end

  defp start_authority_registry(opts \\ []) do
    {:ok, registry_pid} = AuthorityRegistry.start_link(opts)
    Process.unlink(registry_pid)
    :ok
  end

  defp stop_authority_registry, do: stop_authority_service(AuthorityRegistry)
  defp stop_authority_store, do: stop_authority_service(Store)
  defp stop_authority_root, do: stop_authority_service(Root)

  defp stop_authority_service(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      service_pid ->
        ref = Process.monitor(service_pid)
        Process.exit(service_pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^service_pid, _reason}, 250
    end
  end

  defp resume_if_alive(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        try do
          :sys.resume(pid)
        catch
          :exit, _reason -> :ok
        end

      nil ->
        :ok
    end
  end

  defp kill_and_wait(pid) when is_pid(pid) do
    monitor_ref = Process.monitor(pid)
    if Process.alive?(pid), do: Process.exit(pid, :kill)

    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _reason}, 250
  end

  defp stop_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp stop_if_alive(_pid), do: :ok

  defp eventually(assertion, attempts \\ 50)

  defp eventually(assertion, attempts) when attempts > 0 do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(assertion, attempts - 1)
  end

  defp eventually(assertion, 0), do: assertion.()
end
