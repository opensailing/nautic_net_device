defmodule RacingOrg.Tracker.Pro.DesiredState.OperationalGateTest do
  # These tests share the singleton authority Root/Store/Registry started by test_helper.
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  defmodule SequencedRegistry do
    def start_link(owner_pids) do
      Agent.start_link(fn -> owner_pids end)
    end

    def whereis_name(registry) do
      Agent.get_and_update(registry, fn
        [owner_pid, next_owner_pid | rest] -> {owner_pid, [next_owner_pid | rest]}
        [owner_pid] -> {owner_pid, [owner_pid]}
      end)
    end
  end

  defmodule ControllableRegistry do
    def start_link(owner_pid) do
      Agent.start_link(fn ->
        %{
          owner_pid: owner_pid,
          incarnation_pid: new_incarnation(self()),
          block_next: nil,
          snapshot_calls: 0,
          whereis_calls: 0
        }
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

    def block_next(registry, listener) do
      Agent.update(registry, &%{&1 | block_next: listener})
    end

    def incarnation_pid(registry), do: Agent.get(registry, & &1.incarnation_pid)

    def call_counts(registry) do
      Agent.get(registry, &{&1.snapshot_calls, &1.whereis_calls})
    end

    def whereis_name(registry) do
      Agent.get_and_update(registry, fn state ->
        {state.owner_pid, %{state | whereis_calls: state.whereis_calls + 1}}
      end)
    end

    def authority_snapshot(registry) do
      case Agent.get_and_update(registry, fn state ->
             state = %{state | snapshot_calls: state.snapshot_calls + 1}

             case state do
               %{block_next: listener} when is_pid(listener) ->
                 reply = {:block, listener, state.owner_pid, state.incarnation_pid}
                 {reply, %{state | block_next: nil}}

               state ->
                 {{:snapshot, state.owner_pid, state.incarnation_pid}, state}
             end
           end) do
        {:snapshot, owner_pid, incarnation_pid} ->
          {:ok, owner_pid, incarnation_pid}

        {:block, listener, owner_pid, incarnation_pid} ->
          Process.flag(:trap_exit, true)
          send(listener, {:owner_resolution_blocked, self()})

          receive do
            {:resolve_owner_as, resolved_owner_pid} ->
              {:ok, resolved_owner_pid || owner_pid, incarnation_pid}
          end
      end
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

  defmodule IncarnatedRegistry do
    def start_link(owner_pid) do
      Agent.start_link(fn ->
        %{owner_pid: owner_pid, incarnation_pid: new_incarnation(self())}
      end)
    end

    def whereis_name(registry) do
      Agent.get(registry, & &1.owner_pid)
    end

    def authority_snapshot(registry) do
      Agent.get(registry, fn state ->
        {:ok, state.owner_pid, state.incarnation_pid}
      end)
    end

    def rebind_aba(registry, replacement_pid, listener) do
      Agent.update(registry, fn state ->
        Process.exit(state.incarnation_pid, :kill)
        send(listener, {:incarnated_owner_rebound, replacement_pid})

        replacement_incarnation = new_incarnation(self())
        Process.exit(replacement_incarnation, :kill)
        send(listener, {:incarnated_owner_restored, state.owner_pid})

        %{state | incarnation_pid: new_incarnation(self())}
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

  test "exports only the fully owner-bound opening API" do
    Code.ensure_loaded!(OperationalGate)

    assert function_exported?(OperationalGate, :open_owned, 6)
    refute function_exported?(OperationalGate, :open, 2)
    refute function_exported?(OperationalGate, :open_owned, 3)
    refute function_exported?(OperationalGate, :open_owned, 4)
    refute function_exported?(OperationalGate, :open_owned, 5)
  end

  test "a copied controller capability and forged GenServer from tuple cannot authorize an open" do
    term_key = {__MODULE__, make_ref()}
    controller = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, gate} =
      OperationalGate.start_link(
        name: nil,
        term_key: term_key,
        controller: controller
      )

    binding = %{
      credential_epoch: 7,
      storage_epoch: <<0x21::128>>,
      generation: 40,
      manifest_hash: :binary.copy(<<0x32>>, 32)
    }

    on_exit(fn ->
      stop_if_alive(gate)
      if Process.alive?(controller), do: Process.exit(controller, :kill)
      :persistent_term.erase(term_key)
    end)

    copied_capability = controller_capability(gate)

    send(
      gate,
      {:"$gen_call", {controller, make_ref()},
       {:open_owned, copied_capability, controller, [], binding, authority_bindings(controller, controller)}}
    )

    _state = :sys.get_state(gate)
    refute OperationalGate.open?(term_key)
    assert OperationalGate.status(gate) == :closed
  end

  setup do
    term_key = {__MODULE__, make_ref()}
    {:ok, gate} = OperationalGate.start_link(name: nil, term_key: term_key, controller: self())

    on_exit(fn ->
      stop_if_alive(gate)
      :persistent_term.erase(term_key)
    end)

    %{gate: gate, term_key: term_key}
  end

  test "an exact open replay is idempotent", ctx do
    binding = valid_binding()

    assert :ok = open_gate(ctx.gate, binding)
    lease = :persistent_term.get(ctx.term_key)

    assert :ok = open_gate(ctx.gate, binding)
    assert :persistent_term.get(ctx.term_key) == lease
  end

  test "a prepared transition adopts its exact authority guard into the published lease", ctx do
    capability = controller_capability(ctx.gate)
    authority_bindings = authority_bindings(self(), self())

    assert {:ok, transition_token} =
             OperationalGate.prepare_transition(
               ctx.gate,
               capability,
               self(),
               authority_bindings
             )

    prepared_guard = :sys.get_state(ctx.gate).authority_guard_pid
    assert is_pid(prepared_guard)

    assert :ok =
             OperationalGate.transition_current(
               ctx.gate,
               capability,
               self(),
               transition_token
             )

    assert :ok =
             OperationalGate.open_prepared(
               ctx.gate,
               capability,
               self(),
               transition_token,
               [],
               valid_binding()
             )

    {:open, _authority_token, _lease_token, _binding, _lease_pids, _authority_bindings, _controller_reference,
     published_guard} = :persistent_term.get(ctx.term_key)

    assert published_guard == prepared_guard
  end

  test "an exact prepared transition replay is idempotent", ctx do
    capability = controller_capability(ctx.gate)
    authority_bindings = authority_bindings(self(), self())

    assert {:ok, transition_token} =
             OperationalGate.prepare_transition(
               ctx.gate,
               capability,
               self(),
               authority_bindings
             )

    prepared_guard = :sys.get_state(ctx.gate).authority_guard_pid

    assert {:ok, ^transition_token} =
             OperationalGate.prepare_transition(
               ctx.gate,
               capability,
               self(),
               authority_bindings
             )

    assert :sys.get_state(ctx.gate).authority_guard_pid == prepared_guard
  end

  test "an observed ABA permanently invalidates a prepared transition", ctx do
    owner_name = String.to_atom("prepared_gate_owner_#{System.unique_integer([:positive])}")
    true = Process.register(self(), owner_name)

    on_exit(fn ->
      if Process.whereis(owner_name), do: Process.unregister(owner_name)
    end)

    capability = controller_capability(ctx.gate)
    authority_bindings = authority_bindings(owner_name, self())

    assert {:ok, transition_token} =
             OperationalGate.prepare_transition(
               ctx.gate,
               capability,
               self(),
               authority_bindings
             )

    true = Process.unregister(owner_name)
    true = Process.register(self(), owner_name)

    assert {:error, :gate_authority_changed} =
             OperationalGate.transition_current(
               ctx.gate,
               capability,
               self(),
               transition_token
             )

    assert {:error, :gate_authority_changed} =
             OperationalGate.open_prepared(
               ctx.gate,
               capability,
               self(),
               transition_token,
               [],
               valid_binding()
             )

    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "legacy PID-only lease representations fail closed", ctx do
    binding = %{
      credential_epoch: 7,
      storage_epoch: <<0x21::128>>,
      generation: 40,
      manifest_hash: :binary.copy(<<0x32>>, 32)
    }

    :persistent_term.put(ctx.term_key, {:open, make_ref(), binding, [ctx.gate, self()]})

    refute OperationalGate.open?(ctx.term_key)
    refute OperationalGate.operational?(7, <<0x21::128>>, ctx.term_key)
  end

  test "owner-bound leases without a unique publication token fail closed", ctx do
    binding = %{
      credential_epoch: 7,
      storage_epoch: <<0x21::128>>,
      generation: 40,
      manifest_hash: :binary.copy(<<0x32>>, 32)
    }

    :persistent_term.put(
      ctx.term_key,
      {:open, make_ref(), binding, [ctx.gate, self()], authority_bindings(self(), self())}
    )

    refute OperationalGate.open?(ctx.term_key)
    refute OperationalGate.operational?(7, <<0x21::128>>, ctx.term_key)
  end

  test "current-shape leases without complete authority fail closed", ctx do
    binding = %{
      credential_epoch: 7,
      storage_epoch: <<0x21::128>>,
      generation: 40,
      manifest_hash: :binary.copy(<<0x32>>, 32)
    }

    gate = ctx.gate
    controller = self()
    {:closed, authority_token, ^gate, ^controller} = :persistent_term.get(ctx.term_key)

    :persistent_term.put(
      ctx.term_key,
      {:open, authority_token, make_ref(), binding, [ctx.gate, controller], %{}, controller}
    )

    refute OperationalGate.open?(ctx.term_key)
    refute OperationalGate.operational?(7, <<0x21::128>>, ctx.term_key)
  end

  test "an improper current-shape lease PID list fails closed without raising", ctx do
    binding = %{
      credential_epoch: 7,
      storage_epoch: <<0x21::128>>,
      generation: 40,
      manifest_hash: :binary.copy(<<0x32>>, 32)
    }

    gate = ctx.gate
    controller = self()
    {:closed, authority_token, ^gate, ^controller} = :persistent_term.get(ctx.term_key)

    :persistent_term.put(
      ctx.term_key,
      {:open, authority_token, make_ref(), binding, [ctx.gate, controller | :invalid_tail],
       authority_bindings(controller, controller), controller}
    )

    refute OperationalGate.open?(ctx.term_key)
    refute OperationalGate.operational?(7, <<0x21::128>>, ctx.term_key)
  end

  test "a malformed lease controller cannot replace the live gate controller authority", ctx do
    binding = %{
      credential_epoch: 7,
      storage_epoch: <<0x21::128>>,
      generation: 40,
      manifest_hash: :binary.copy(<<0x32>>, 32)
    }

    gate = ctx.gate
    controller = self()
    {:closed, authority_token, ^gate, ^controller} = :persistent_term.get(ctx.term_key)
    attacker = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn -> if Process.alive?(attacker), do: Process.exit(attacker, :kill) end)

    :persistent_term.put(
      ctx.term_key,
      {:open, authority_token, make_ref(), binding, [gate, controller], authority_bindings(controller, controller),
       attacker}
    )

    refute OperationalGate.open?(ctx.term_key)

    assert {:closed, ^authority_token, ^gate, ^controller} =
             :persistent_term.get(ctx.term_key)
  end

  test "a forged process marker cannot publish an operational lease" do
    term_key = {__MODULE__, make_ref()}
    authority_token = make_ref()
    lease_token = make_ref()
    parent = self()

    binding = %{
      credential_epoch: 7,
      storage_epoch: <<0x23::128>>,
      generation: 42,
      manifest_hash: :binary.copy(<<0x34>>, 32)
    }

    forger =
      spawn(fn ->
        Process.put(
          {OperationalGate, :authority},
          {term_key, authority_token, self()}
        )

        send(parent, {:forger_ready, self()})
        Process.sleep(:infinity)
      end)

    on_exit(fn ->
      if Process.alive?(forger), do: Process.exit(forger, :kill)
      :persistent_term.erase(term_key)
    end)

    assert_receive {:forger_ready, ^forger}

    :persistent_term.put(
      term_key,
      {:open, authority_token, lease_token, binding, [forger, forger], authority_bindings(forger, forger), forger}
    )

    refute OperationalGate.open?(term_key)
    refute OperationalGate.operational?(7, <<0x23::128>>, term_key)
  end

  test "is fail-safe closed before any generation is effective", ctx do
    refute OperationalGate.open?(ctx.term_key)
    refute OperationalGate.operational?(3, <<0x11::128>>, ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "output stays permitted for legacy devices and fences once authority exists", ctx do
    on_exit(fn -> OperationalGate.clear_authority_established(ctx.term_key) end)

    # Before any v1 desired-state authority exists, output keeps flowing so a
    # legacy or unprovisioned device is never silenced by the closed gate.
    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.output_permitted?(ctx.term_key)

    # The first activation marks the incarnation; a closed gate now fences.
    assert :ok = OperationalGate.record_authority_established(ctx.term_key)
    assert OperationalGate.authority_established?(ctx.term_key)
    refute OperationalGate.output_permitted?(ctx.term_key)

    # An open gate permits output again.
    assert :ok = open_gate(ctx.gate, valid_binding())
    assert OperationalGate.output_permitted?(ctx.term_key)

    # Closing for a reload fences immediately.
    assert :ok = OperationalGate.close(ctx.gate)
    refute OperationalGate.output_permitted?(ctx.term_key)

    # The marker survives independent of lease state and is idempotent.
    assert :ok = OperationalGate.record_authority_established(ctx.term_key)
    assert OperationalGate.authority_established?(ctx.term_key)
  end

  test "an untrusted process cannot win the first open", ctx do
    binding = %{
      credential_epoch: 7,
      storage_epoch: <<0x22::128>>,
      generation: 41,
      manifest_hash: :binary.copy(<<0x33>>, 32)
    }

    parent = self()

    attacker =
      spawn(fn ->
        send(parent, {:first_open_result, open_gate(ctx.gate, binding)})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> if Process.alive?(attacker), do: Process.exit(attacker, :kill) end)

    assert_receive {:first_open_result, {:error, :gate_not_controller}}
    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed

    assert :ok = open_gate(ctx.gate, binding)
    assert OperationalGate.open?(ctx.term_key)
  end

  test "opens only for the exact credential epoch and storage epoch", ctx do
    binding = %{
      credential_epoch: 7,
      storage_epoch: <<0x22::128>>,
      generation: 41,
      manifest_hash: :binary.copy(<<0x33>>, 32)
    }

    assert :ok = open_gate(ctx.gate, binding)
    assert OperationalGate.open?(ctx.term_key)
    assert OperationalGate.operational?(7, <<0x22::128>>, ctx.term_key)
    refute OperationalGate.operational?(6, <<0x22::128>>, ctx.term_key)
    refute OperationalGate.operational?(7, <<0x23::128>>, ctx.term_key)
    assert OperationalGate.status(ctx.gate) == {:open, binding}
  end

  test "closes synchronously before activation work proceeds", ctx do
    assert :ok =
             open_gate(ctx.gate, %{
               credential_epoch: 1,
               storage_epoch: <<0x44::128>>,
               generation: 1,
               manifest_hash: :binary.copy(<<0x55>>, 32)
             })

    assert :ok = OperationalGate.close(ctx.gate)
    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "rejects malformed or zero incarnation bindings and stays closed", ctx do
    invalid = [
      %{},
      %{credential_epoch: -1, storage_epoch: <<1::128>>, generation: 1, manifest_hash: <<1::256>>},
      %{credential_epoch: 0, storage_epoch: <<0::128>>, generation: 1, manifest_hash: <<1::256>>},
      %{credential_epoch: 0, storage_epoch: <<1::128>>, generation: 0, manifest_hash: <<1::256>>},
      %{credential_epoch: 0, storage_epoch: <<1::128>>, generation: 1, manifest_hash: <<1, 2>>}
    ]

    Enum.each(invalid, fn binding ->
      assert {:error, :invalid_gate_binding} = open_gate(ctx.gate, binding)
      refute OperationalGate.open?(ctx.term_key)
    end)
  end

  test "rejects incomplete owner authority bindings and stays closed", ctx do
    binding = %{
      credential_epoch: 2,
      storage_epoch: <<0x64::128>>,
      generation: 6,
      manifest_hash: :binary.copy(<<0x75>>, 32)
    }

    incomplete_authority =
      self()
      |> authority_bindings(self())
      |> Map.delete(:wifi)

    assert {:error, :invalid_gate_authority_bindings} =
             OperationalGate.open_owned(
               ctx.gate,
               controller_capability(ctx.gate),
               self(),
               [],
               binding,
               incomplete_authority
             )

    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "a failed replacement open revokes the prior lease", ctx do
    binding = %{
      credential_epoch: 2,
      storage_epoch: <<0x65::128>>,
      generation: 7,
      manifest_hash: :binary.copy(<<0x76>>, 32)
    }

    assert :ok = open_gate(ctx.gate, binding)
    assert OperationalGate.open?(ctx.term_key)

    assert {:error, :invalid_gate_binding} = open_gate(ctx.gate, %{})
    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "a different live process cannot replace the established lease controller", ctx do
    binding = %{
      credential_epoch: 2,
      storage_epoch: <<0x64::128>>,
      generation: 6,
      manifest_hash: :binary.copy(<<0x75>>, 32)
    }

    assert :ok = open_gate(ctx.gate, binding)
    parent = self()

    attacker =
      spawn(fn ->
        send(parent, {:replacement_result, open_gate(ctx.gate, binding)})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> if Process.alive?(attacker), do: Process.exit(attacker, :kill) end)

    assert_receive {:replacement_result, {:error, :gate_not_controller}}
    assert OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == {:open, binding}
  end

  test "a replacement under the configured controller reference can reopen after controller death" do
    prior_binding = %{
      credential_epoch: 2,
      storage_epoch: <<0x64::128>>,
      generation: 6,
      manifest_hash: :binary.copy(<<0x75>>, 32)
    }

    replacement_binding = %{
      credential_epoch: 2,
      storage_epoch: <<0x65::128>>,
      generation: 7,
      manifest_hash: :binary.copy(<<0x76>>, 32)
    }

    parent = self()

    prior_controller =
      spawn(fn ->
        receive do
          {:open, gate} ->
            send(parent, {:prior_open, open_gate(gate, prior_binding)})
            Process.sleep(:infinity)
        end
      end)

    {:ok, registry} = ControllableRegistry.start_link(prior_controller)
    controller_reference = {:via, ControllableRegistry, registry}
    term_key = {__MODULE__, make_ref()}

    {:ok, gate} =
      OperationalGate.start_link(
        name: nil,
        term_key: term_key,
        controller: controller_reference
      )

    on_exit(fn ->
      stop_if_alive(gate)
      stop_if_alive(registry)
      if Process.alive?(prior_controller), do: Process.exit(prior_controller, :kill)
      :persistent_term.erase(term_key)
    end)

    send(prior_controller, {:open, gate})
    assert_receive {:prior_open, :ok}
    assert OperationalGate.open?(term_key)

    monitor_ref = Process.monitor(prior_controller)
    Process.exit(prior_controller, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^prior_controller, :killed}
    eventually(fn -> refute OperationalGate.open?(term_key) end)

    replacement_controller =
      spawn(fn ->
        receive do
          {:open, replacement_gate} ->
            send(parent, {:replacement_open, open_gate(replacement_gate, replacement_binding)})
            Process.sleep(:infinity)
        end
      end)

    on_exit(fn ->
      if Process.alive?(replacement_controller), do: Process.exit(replacement_controller, :kill)
    end)

    ControllableRegistry.owner(registry, replacement_controller)
    send(replacement_controller, {:open, gate})

    assert_receive {:replacement_open, :ok}, 250
    assert OperationalGate.open?(term_key)
    assert OperationalGate.operational?(2, <<0x65::128>>, term_key)
    assert OperationalGate.status(gate) == {:open, replacement_binding}
  end

  test "a configured controller reference cannot hand off before the first lease while its startup PID remains alive" do
    binding = %{
      credential_epoch: 2,
      storage_epoch: <<0x66::128>>,
      generation: 8,
      manifest_hash: :binary.copy(<<0x77>>, 32)
    }

    prior_controller = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, registry} = ControllableRegistry.start_link(prior_controller)
    controller_reference = {:via, ControllableRegistry, registry}
    term_key = {__MODULE__, make_ref()}

    {:ok, gate} =
      OperationalGate.start_link(
        name: nil,
        term_key: term_key,
        controller: controller_reference
      )

    parent = self()

    attacker =
      spawn(fn ->
        receive do
          {:open, target_gate} ->
            send(parent, {:first_lease_rebind, open_gate(target_gate, binding)})
            Process.sleep(:infinity)
        end
      end)

    on_exit(fn ->
      stop_if_alive(gate)
      stop_if_alive(registry)
      if Process.alive?(prior_controller), do: Process.exit(prior_controller, :kill)
      if Process.alive?(attacker), do: Process.exit(attacker, :kill)
      :persistent_term.erase(term_key)
    end)

    ControllableRegistry.owner(registry, attacker)
    send(attacker, {:open, gate})

    assert_receive {:first_lease_rebind, {:error, :gate_not_controller}}
    assert Process.alive?(prior_controller)
    refute OperationalGate.open?(term_key)
    assert OperationalGate.status(gate) == :closed
  end

  test "a closed gate reattests the current controller incarnation before opening" do
    binding = %{
      credential_epoch: 2,
      storage_epoch: <<0x66::128>>,
      generation: 8,
      manifest_hash: :binary.copy(<<0x77>>, 32)
    }

    {:ok, registry} = ControllableRegistry.start_link(self())
    controller_reference = {:via, ControllableRegistry, registry}
    term_key = {__MODULE__, make_ref()}

    {:ok, gate} =
      OperationalGate.start_link(
        name: nil,
        term_key: term_key,
        controller: controller_reference
      )

    on_exit(fn ->
      stop_if_alive(gate)
      stop_if_alive(registry)
      :persistent_term.erase(term_key)
    end)

    first_incarnation = ControllableRegistry.incarnation_pid(registry)
    first_ref = Process.monitor(first_incarnation)
    ControllableRegistry.owner(registry, self())
    assert_receive {:DOWN, ^first_ref, :process, ^first_incarnation, :killed}

    assert Process.alive?(gate)
    assert OperationalGate.status(gate) == :closed
    assert :ok = open_gate(gate, binding)
    assert OperationalGate.open?(term_key)

    leased_incarnation = ControllableRegistry.incarnation_pid(registry)
    leased_ref = Process.monitor(leased_incarnation)
    ControllableRegistry.owner(registry, self())
    assert_receive {:DOWN, ^leased_ref, :process, ^leased_incarnation, :killed}

    refute OperationalGate.open?(term_key)
    assert OperationalGate.status(gate) == :closed
  end

  test "a configured controller reference cannot hand off while its prior PID remains alive" do
    binding = %{
      credential_epoch: 2,
      storage_epoch: <<0x66::128>>,
      generation: 8,
      manifest_hash: :binary.copy(<<0x77>>, 32)
    }

    parent = self()

    prior_controller =
      spawn(fn ->
        receive do
          {:open, gate} ->
            send(parent, {:live_prior_open, open_gate(gate, binding)})
            Process.sleep(:infinity)
        end
      end)

    {:ok, registry} = ControllableRegistry.start_link(prior_controller)
    controller_reference = {:via, ControllableRegistry, registry}
    term_key = {__MODULE__, make_ref()}

    {:ok, gate} =
      OperationalGate.start_link(
        name: nil,
        term_key: term_key,
        controller: controller_reference
      )

    attacker =
      spawn(fn ->
        receive do
          {:open, target_gate} ->
            send(parent, {:live_controller_rebind, open_gate(target_gate, binding)})
            Process.sleep(:infinity)
        end
      end)

    on_exit(fn ->
      stop_if_alive(gate)
      stop_if_alive(registry)
      if Process.alive?(prior_controller), do: Process.exit(prior_controller, :kill)
      if Process.alive?(attacker), do: Process.exit(attacker, :kill)
      :persistent_term.erase(term_key)
    end)

    send(prior_controller, {:open, gate})
    assert_receive {:live_prior_open, :ok}
    assert OperationalGate.open?(term_key)

    ControllableRegistry.owner(registry, attacker)
    send(attacker, {:open, gate})

    assert_receive {
      :live_controller_rebind,
      {:error, :gate_not_controller}
    }

    refute OperationalGate.open?(term_key)
    assert OperationalGate.status(gate) == :closed
  end

  test "one reference cannot authorize different controller and section-owner PIDs" do
    binding = %{
      credential_epoch: 2,
      storage_epoch: <<0x66::128>>,
      generation: 8,
      manifest_hash: :binary.copy(<<0x77>>, 32)
    }

    controller = self()
    section_owner = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, registry} = IncarnatedRegistry.start_link(controller)
    shared_reference = {:via, IncarnatedRegistry, registry}
    term_key = {__MODULE__, make_ref()}

    {:ok, gate} =
      OperationalGate.start_link(
        name: nil,
        term_key: term_key,
        controller: shared_reference
      )

    on_exit(fn ->
      stop_if_alive(gate)
      stop_if_alive(registry)
      if Process.alive?(section_owner), do: Process.exit(section_owner, :kill)
      :persistent_term.erase(term_key)
    end)

    assert {:error, :gate_authority_changed} =
             OperationalGate.open_owned(
               gate,
               controller_capability(gate),
               controller,
               [section_owner],
               binding,
               authority_bindings(shared_reference, section_owner)
             )

    refute OperationalGate.open?(term_key)
    assert OperationalGate.status(gate) == :closed
  end

  test "closes when the authoritative opener dies without an explicit close" do
    binding = %{
      credential_epoch: 2,
      storage_epoch: <<0x65::128>>,
      generation: 7,
      manifest_hash: :binary.copy(<<0x76>>, 32)
    }

    parent = self()

    owner =
      spawn(fn ->
        receive do
          {:open, gate} ->
            :ok = open_gate(gate, binding)
            send(parent, :opened)
            Process.sleep(:infinity)
        end
      end)

    term_key = {__MODULE__, make_ref()}
    {:ok, gate} = OperationalGate.start_link(name: nil, term_key: term_key, controller: owner)

    on_exit(fn ->
      stop_if_alive(gate)
      if Process.alive?(owner), do: Process.exit(owner, :kill)
      :persistent_term.erase(term_key)
    end)

    send(owner, {:open, gate})
    assert_receive :opened
    assert OperationalGate.open?(term_key)

    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

    eventually(fn ->
      refute OperationalGate.open?(term_key)
      assert OperationalGate.status(gate) == :closed
    end)
  end

  test "a process cannot nominate another lease owner", ctx do
    binding = %{
      credential_epoch: 2,
      storage_epoch: <<0x65::128>>,
      generation: 7,
      manifest_hash: :binary.copy(<<0x76>>, 32)
    }

    owner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

    assert {:error, :invalid_gate_owner} = open_gate(ctx.gate, binding, owner: owner)
    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "a dead dependency fails hot reads closed before the gate handles its DOWN", ctx do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x67::128>>,
      generation: 9,
      manifest_hash: :binary.copy(<<0x78>>, 32)
    }

    dependency = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok = open_gate(ctx.gate, binding, dependencies: [dependency])
    assert OperationalGate.open?(ctx.term_key)
    assert OperationalGate.operational?(3, <<0x67::128>>, ctx.term_key)

    :sys.suspend(ctx.gate)
    on_exit(fn -> if Process.alive?(ctx.gate), do: :sys.resume(ctx.gate) end)

    ref = Process.monitor(dependency)
    Process.exit(dependency, :kill)
    assert_receive {:DOWN, ^ref, :process, ^dependency, :killed}

    refute OperationalGate.open?(ctx.term_key)
    refute OperationalGate.operational?(3, <<0x67::128>>, ctx.term_key)

    :sys.resume(ctx.gate)
    eventually(fn -> assert OperationalGate.status(ctx.gate) == :closed end)
  end

  test "a dependency death during open-time owner attestation prevents publication" do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x67::128>>,
      generation: 9,
      manifest_hash: :binary.copy(<<0x78>>, 32)
    }

    parent = self()

    controller =
      spawn(fn ->
        receive do
          {:open, gate, capability, dependency, owner_reference} ->
            result =
              OperationalGate.open_owned(
                gate,
                capability,
                self(),
                [dependency],
                binding,
                authority_bindings(owner_reference, self())
              )

            send(parent, {:dependency_attestation_result, result})
            Process.sleep(:infinity)
        end
      end)

    {:ok, registry} = ControllableRegistry.start_link(controller)
    owner_reference = {:via, ControllableRegistry, registry}
    dependency = spawn(fn -> Process.sleep(:infinity) end)
    term_key = {__MODULE__, make_ref()}

    {:ok, gate} =
      OperationalGate.start_link(name: nil, term_key: term_key, controller: controller)

    on_exit(fn ->
      stop_if_alive(gate)
      stop_if_alive(registry)
      if Process.alive?(controller), do: Process.exit(controller, :kill)
      if Process.alive?(dependency), do: Process.exit(dependency, :kill)
      :persistent_term.erase(term_key)
    end)

    ControllableRegistry.block_next(registry, self())

    send(
      controller,
      {:open, gate, controller_capability(gate), dependency, owner_reference}
    )

    assert_receive {:owner_resolution_blocked, resolver_pid}

    dependency_ref = Process.monitor(dependency)
    Process.exit(dependency, :kill)
    assert_receive {:DOWN, ^dependency_ref, :process, ^dependency, :killed}

    send(resolver_pid, {:resolve_owner_as, controller})

    assert_receive {:dependency_attestation_result, {:error, :gate_dependency_unavailable}},
                   250

    refute OperationalGate.open?(term_key)
    assert OperationalGate.status(gate) == :closed
  end

  test "a via incarnation handoff during an in-flight hot read fails closed", ctx do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x67::128>>,
      generation: 9,
      manifest_hash: :binary.copy(<<0x78>>, 32)
    }

    replacement = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, registry} = ControllableRegistry.start_link(self())
    owner_reference = {:via, ControllableRegistry, registry}

    on_exit(fn ->
      stop_if_alive(registry)
      if Process.alive?(replacement), do: Process.exit(replacement, :kill)
    end)

    assert :ok = open_gate(ctx.gate, binding, owner_reference: owner_reference)

    {:open, _authority_token, _lease_token, _binding, _lease_pids, _authority_bindings, _controller_reference,
     authority_guard_pid} =
      :persistent_term.get(ctx.term_key)

    :ok = :sys.suspend(authority_guard_pid)
    parent = self()

    reader =
      spawn(fn ->
        send(parent, {:in_flight_handoff_result, OperationalGate.open?(ctx.term_key)})
      end)

    on_exit(fn -> if Process.alive?(reader), do: Process.exit(reader, :kill) end)

    eventually(fn ->
      assert {:message_queue_len, size} = Process.info(authority_guard_pid, :message_queue_len)
      assert size >= 1
    end)

    incarnation_pid = ControllableRegistry.incarnation_pid(registry)
    incarnation_ref = Process.monitor(incarnation_pid)
    ControllableRegistry.owner(registry, replacement)
    assert_receive {:DOWN, ^incarnation_ref, :process, ^incarnation_pid, :killed}

    :ok = :sys.resume(authority_guard_pid)

    assert_receive {:in_flight_handoff_result, false}, 250
    refute OperationalGate.open?(ctx.term_key)
    eventually(fn -> assert OperationalGate.status(ctx.gate) == :closed end)
  end

  test "hot reads do not invoke via registry callbacks", ctx do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x67::128>>,
      generation: 9,
      manifest_hash: :binary.copy(<<0x78>>, 32)
    }

    {:ok, registry} = ControllableRegistry.start_link(self())
    owner_reference = {:via, ControllableRegistry, registry}

    on_exit(fn ->
      stop_if_alive(registry)
    end)

    assert :ok = open_gate(ctx.gate, binding, owner_reference: owner_reference)
    call_counts = ControllableRegistry.call_counts(registry)
    ControllableRegistry.block_next(registry, self())

    assert OperationalGate.open?(ctx.term_key)
    assert OperationalGate.operational?(3, <<0x67::128>>, ctx.term_key)
    assert ControllableRegistry.call_counts(registry) == call_counts
    refute_receive {:owner_resolution_blocked, _resolver_pid}
  end

  test "open-time via attestation is bounded and kills its blocked resolver" do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x67::128>>,
      generation: 9,
      manifest_hash: :binary.copy(<<0x78>>, 32)
    }

    parent = self()

    controller =
      spawn(fn ->
        receive do
          {:open, gate, capability, owner_reference} ->
            started_at = System.monotonic_time(:millisecond)

            result =
              OperationalGate.open_owned(
                gate,
                capability,
                self(),
                [],
                binding,
                authority_bindings(owner_reference, self())
              )

            elapsed_ms = System.monotonic_time(:millisecond) - started_at
            send(parent, {:bounded_attestation_result, result, elapsed_ms})
            Process.sleep(:infinity)
        end
      end)

    {:ok, registry} = ControllableRegistry.start_link(controller)
    owner_reference = {:via, ControllableRegistry, registry}
    term_key = {__MODULE__, make_ref()}

    {:ok, gate} =
      OperationalGate.start_link(name: nil, term_key: term_key, controller: controller)

    on_exit(fn ->
      stop_if_alive(gate)
      stop_if_alive(registry)
      if Process.alive?(controller), do: Process.exit(controller, :kill)
      :persistent_term.erase(term_key)
    end)

    ControllableRegistry.block_next(registry, self())
    send(controller, {:open, gate, controller_capability(gate), owner_reference})

    assert_receive {:owner_resolution_blocked, resolver_pid}
    resolver_ref = Process.monitor(resolver_pid)

    assert_receive {:DOWN, ^resolver_ref, :process, ^resolver_pid, :killed}, 250

    assert_receive {
                     :bounded_attestation_result,
                     {:error, :gate_authority_changed},
                     elapsed_ms
                   },
                   250

    assert elapsed_ms < 250
    refute OperationalGate.open?(term_key)
    assert OperationalGate.status(gate) == :closed
  end

  test "a read during open-time attestation cannot poison a successful publication" do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x68::128>>,
      generation: 10,
      manifest_hash: :binary.copy(<<0x79>>, 32)
    }

    parent = self()

    opener =
      spawn(fn ->
        receive do
          {:open, gate, capability, owner_reference} ->
            result =
              OperationalGate.open_owned(
                gate,
                capability,
                self(),
                [],
                binding,
                authority_bindings(owner_reference, self())
              )

            send(parent, {:prepared_open_result, result})
            Process.sleep(:infinity)
        end
      end)

    {:ok, registry} = ControllableRegistry.start_link(opener)
    owner_reference = {:via, ControllableRegistry, registry}
    term_key = {__MODULE__, make_ref()}

    {:ok, gate} =
      OperationalGate.start_link(name: nil, term_key: term_key, controller: opener)

    on_exit(fn ->
      stop_if_alive(gate)
      if Process.alive?(opener), do: Process.exit(opener, :kill)
      stop_if_alive(registry)
      :persistent_term.erase(term_key)
    end)

    ControllableRegistry.block_next(registry, self())
    send(opener, {:open, gate, controller_capability(gate), owner_reference})

    assert_receive {:owner_resolution_blocked, resolver_pid}
    refute OperationalGate.open?(term_key)
    refute OperationalGate.operational?(3, <<0x68::128>>, term_key)

    send(resolver_pid, {:resolve_owner_as, opener})

    assert_receive {:prepared_open_result, :ok}, 250
    assert OperationalGate.open?(term_key)
    assert OperationalGate.status(gate) == {:open, binding}
  end

  test "an unattested via registry cannot establish lease authority", ctx do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x68::128>>,
      generation: 10,
      manifest_hash: :binary.copy(<<0x79>>, 32)
    }

    {:ok, registry} = SequencedRegistry.start_link([self()])
    owner_reference = {:via, SequencedRegistry, registry}

    on_exit(fn ->
      stop_if_alive(registry)
    end)

    assert {:error, :gate_authority_unattested} =
             open_gate(ctx.gate, binding, owner_reference: owner_reference)

    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "an attested via registry with a dead owner is unavailable rather than unattested", ctx do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x68::128>>,
      generation: 10,
      manifest_hash: :binary.copy(<<0x79>>, 32)
    }

    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, registry} = ControllableRegistry.start_link(owner)
    owner_reference = {:via, ControllableRegistry, registry}
    owner_ref = Process.monitor(owner)

    on_exit(fn ->
      stop_if_alive(registry)
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}

    assert {:error, :gate_dependency_unavailable} =
             open_gate(ctx.gate, binding,
               owner_reference: owner_reference,
               expected_owner: owner
             )

    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "an attested via registry with a dead incarnation has changed authority", ctx do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x68::128>>,
      generation: 10,
      manifest_hash: :binary.copy(<<0x79>>, 32)
    }

    {:ok, registry} = ControllableRegistry.start_link(self())
    owner_reference = {:via, ControllableRegistry, registry}
    incarnation_pid = ControllableRegistry.incarnation_pid(registry)
    incarnation_ref = Process.monitor(incarnation_pid)

    on_exit(fn ->
      stop_if_alive(registry)
    end)

    Process.exit(incarnation_pid, :kill)
    assert_receive {:DOWN, ^incarnation_ref, :process, ^incarnation_pid, :killed}

    assert {:error, :gate_authority_changed} =
             open_gate(ctx.gate, binding, owner_reference: owner_reference)

    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "a local registered-name ABA permanently revokes an open lease", ctx do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x68::128>>,
      generation: 10,
      manifest_hash: :binary.copy(<<0x79>>, 32)
    }

    owner_name = String.to_atom("gate_owner_#{System.unique_integer([:positive])}")
    true = Process.register(self(), owner_name)

    on_exit(fn ->
      if Process.whereis(owner_name), do: Process.unregister(owner_name)
    end)

    assert :ok = open_gate(ctx.gate, binding, owner_reference: owner_name)
    assert OperationalGate.open?(ctx.term_key)

    true = Process.unregister(owner_name)
    true = Process.register(self(), owner_name)

    refute OperationalGate.open?(ctx.term_key)
    refute OperationalGate.operational?(3, <<0x68::128>>, ctx.term_key)
  end

  test "an attested via ABA permanently revokes an open lease", ctx do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x68::128>>,
      generation: 10,
      manifest_hash: :binary.copy(<<0x79>>, 32)
    }

    replacement = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, registry} = IncarnatedRegistry.start_link(self())
    owner_reference = {:via, IncarnatedRegistry, registry}

    on_exit(fn ->
      stop_if_alive(registry)
      if Process.alive?(replacement), do: Process.exit(replacement, :kill)
    end)

    assert :ok = open_gate(ctx.gate, binding, owner_reference: owner_reference)
    assert OperationalGate.open?(ctx.term_key)

    IncarnatedRegistry.rebind_aba(registry, replacement, self())
    assert_receive {:incarnated_owner_rebound, ^replacement}
    assert_receive {:incarnated_owner_restored, owner_pid}
    assert owner_pid == self()

    refute OperationalGate.open?(ctx.term_key)
    refute OperationalGate.operational?(3, <<0x68::128>>, ctx.term_key)
  end

  test "a middle owner ABA across three references revokes the lease", ctx do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x68::128>>,
      generation: 10,
      manifest_hash: :binary.copy(<<0x79>>, 32)
    }

    owner_pid = self()
    replacement = spawn(fn -> Process.sleep(:infinity) end)

    registries =
      Map.new(1..3, fn position ->
        {:ok, registry} = IncarnatedRegistry.start_link(owner_pid)
        {position, registry}
      end)

    references =
      Map.new(registries, fn {position, registry} ->
        {position, {:via, IncarnatedRegistry, registry}}
      end)

    authority_bindings =
      Contract.sections()
      |> Enum.with_index()
      |> Map.new(fn {section, index} ->
        position = min(index + 1, 3)
        {section, {Map.fetch!(references, position), owner_pid}}
      end)

    on_exit(fn ->
      Enum.each(registries, fn {_position, registry} ->
        stop_if_alive(registry)
      end)

      if Process.alive?(replacement), do: Process.exit(replacement, :kill)
    end)

    assert :ok =
             OperationalGate.open_owned(
               ctx.gate,
               controller_capability(ctx.gate),
               owner_pid,
               [],
               binding,
               authority_bindings
             )

    assert OperationalGate.open?(ctx.term_key)
    middle_registry = Map.fetch!(registries, 2)
    IncarnatedRegistry.rebind_aba(middle_registry, replacement, self())

    assert_receive {:incarnated_owner_rebound, ^replacement}
    assert_receive {:incarnated_owner_restored, ^owner_pid}
    refute OperationalGate.open?(ctx.term_key)
    refute OperationalGate.open?(ctx.term_key)
  end

  test "owner reference handoff fails hot reads before the gate processes a heartbeat", ctx do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x68::128>>,
      generation: 10,
      manifest_hash: :binary.copy(<<0x79>>, 32)
    }

    first_owner = spawn(fn -> Process.sleep(:infinity) end)
    replacement = spawn(fn -> Process.sleep(:infinity) end)
    owner_name = {:desired_state_gate_owner, make_ref()}
    owner_ref = {:global, owner_name}
    assert :yes = :global.register_name(owner_name, first_owner)

    on_exit(fn ->
      :global.unregister_name(owner_name)
      if Process.alive?(first_owner), do: Process.exit(first_owner, :kill)
      if Process.alive?(replacement), do: Process.exit(replacement, :kill)
    end)

    assert :ok =
             OperationalGate.open_owned(
               ctx.gate,
               controller_capability(ctx.gate),
               self(),
               [first_owner],
               binding,
               authority_bindings(owner_ref, first_owner)
             )

    assert OperationalGate.open?(ctx.term_key)
    assert OperationalGate.operational?(3, <<0x68::128>>, ctx.term_key)

    :ok = :global.unregister_name(owner_name)
    assert :yes = :global.register_name(owner_name, replacement)
    assert Process.alive?(first_owner)

    refute OperationalGate.open?(ctx.term_key)
    refute OperationalGate.operational?(3, <<0x68::128>>, ctx.term_key)

    :ok = :global.unregister_name(owner_name)
    assert :yes = :global.register_name(owner_name, first_owner)

    refute OperationalGate.open?(ctx.term_key)
    refute OperationalGate.operational?(3, <<0x68::128>>, ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "an old valid lease tuple cannot replace the gate's current publication", ctx do
    first_binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x69::128>>,
      generation: 11,
      manifest_hash: :binary.copy(<<0x7A>>, 32)
    }

    second_binding = %{
      credential_epoch: 4,
      storage_epoch: <<0x6A::128>>,
      generation: 12,
      manifest_hash: :binary.copy(<<0x7B>>, 32)
    }

    assert :ok = open_gate(ctx.gate, first_binding)
    old_lease = :persistent_term.get(ctx.term_key)
    assert :ok = OperationalGate.close(ctx.gate)
    assert :ok = open_gate(ctx.gate, second_binding)
    :persistent_term.put(ctx.term_key, old_lease)

    refute OperationalGate.operational?(3, <<0x69::128>>, ctx.term_key)
    assert OperationalGate.operational?(4, <<0x6A::128>>, ctx.term_key)
    assert OperationalGate.status(ctx.gate) == {:open, second_binding}
  end

  test "a stale reader cannot revoke a fresh identical lease", ctx do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x69::128>>,
      generation: 11,
      manifest_hash: :binary.copy(<<0x7A>>, 32)
    }

    assert :ok = open_gate(ctx.gate, binding)
    assert OperationalGate.open?(ctx.term_key)

    old_lease =
      {:open, _authority_token, _lease_token, _binding, _lease_pids, _authority_bindings, _controller_reference,
       authority_guard_pid} =
      :persistent_term.get(ctx.term_key)

    :ok = :sys.suspend(authority_guard_pid)
    parent = self()

    stale_reader =
      spawn(fn ->
        send(parent, {:stale_reader_result, OperationalGate.open?(ctx.term_key)})
      end)

    on_exit(fn ->
      resume_if_suspended(stale_reader)
      if Process.alive?(stale_reader), do: Process.exit(stale_reader, :kill)
    end)

    eventually(fn ->
      assert {:message_queue_len, size} = Process.info(authority_guard_pid, :message_queue_len)
      assert size >= 1
    end)

    true = :erlang.suspend_process(stale_reader)
    assert :ok = OperationalGate.close(ctx.gate)
    assert :ok = open_gate(ctx.gate, binding)
    fresh_lease = :persistent_term.get(ctx.term_key)
    assert fresh_lease != old_lease
    assert OperationalGate.open?(ctx.term_key)

    true = :erlang.resume_process(stale_reader)
    assert_receive {:stale_reader_result, false}, 250

    assert :persistent_term.get(ctx.term_key) == fresh_lease
    assert OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == {:open, binding}
  end

  test "a stale successful reader cannot outlive a completed close", ctx do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x6A::128>>,
      generation: 12,
      manifest_hash: :binary.copy(<<0x7B>>, 32)
    }

    assert :ok = open_gate(ctx.gate, binding)
    assert OperationalGate.open?(ctx.term_key)

    {:open, _authority_token, _lease_token, _binding, _lease_pids, _authority_bindings, _controller_reference,
     authority_guard_pid} =
      :persistent_term.get(ctx.term_key)

    :ok = :sys.suspend(authority_guard_pid)
    parent = self()

    stale_reader =
      spawn(fn ->
        result = OperationalGate.operational?(3, <<0x6A::128>>, ctx.term_key)
        send(parent, {:stale_success_result, result})
      end)

    on_exit(fn ->
      resume_if_suspended(stale_reader)
      if Process.alive?(stale_reader), do: Process.exit(stale_reader, :kill)
    end)

    eventually(fn ->
      assert {:message_queue_len, size} = Process.info(authority_guard_pid, :message_queue_len)
      assert size >= 1
    end)

    true = :erlang.suspend_process(stale_reader)
    assert :ok = OperationalGate.close(ctx.gate)
    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed

    true = :erlang.resume_process(stale_reader)
    assert_receive {:stale_success_result, false}, 250
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "refuses to open for an unavailable dependency", ctx do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x68::128>>,
      generation: 10,
      manifest_hash: :binary.copy(<<0x79>>, 32)
    }

    dependency = spawn(fn -> Process.sleep(:infinity) end)

    ref = Process.monitor(dependency)
    Process.exit(dependency, :kill)
    assert_receive {:DOWN, ^ref, :process, ^dependency, :killed}

    assert {:error, :gate_dependency_unavailable} =
             open_gate(ctx.gate, binding, dependencies: [dependency])

    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
  end

  test "a second gate cannot seize authority from a live controller", ctx do
    binding = %{
      credential_epoch: 3,
      storage_epoch: <<0x69::128>>,
      generation: 11,
      manifest_hash: :binary.copy(<<0x7A>>, 32)
    }

    assert :ok = open_gate(ctx.gate, binding)
    assert OperationalGate.open?(ctx.term_key)

    parent = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      result = OperationalGate.start_link(name: nil, term_key: ctx.term_key)
      send(parent, {:replacement_result, result})
    end)

    assert_receive {:replacement_result, replacement_result}

    case replacement_result do
      {:ok, replacement} -> on_exit(fn -> stop_if_alive(replacement) end)
      {:error, _reason} -> :ok
    end

    assert {:error, :gate_authority_in_use} = replacement_result
    assert OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == {:open, binding}
  end

  test "a hot read fails closed without waiting for the gate transition lock", ctx do
    parent = self()

    lock_holder =
      spawn(fn ->
        lock_id = {{OperationalGate, ctx.term_key}, self()}
        true = :global.set_lock(lock_id, [node()], 0)
        send(parent, :gate_transition_lock_held)

        receive do
          :release -> :global.del_lock(lock_id, [node()])
        end
      end)

    on_exit(fn ->
      send(lock_holder, :release)
      if Process.alive?(lock_holder), do: Process.exit(lock_holder, :kill)
    end)

    assert_receive :gate_transition_lock_held

    :persistent_term.put(
      ctx.term_key,
      {:open, make_ref(), valid_binding(), [ctx.gate, self()]}
    )

    reader =
      spawn(fn ->
        send(parent, {:lock_contended_hot_read, OperationalGate.open?(ctx.term_key)})
      end)

    on_exit(fn -> if Process.alive?(reader), do: Process.exit(reader, :kill) end)
    assert_receive {:lock_contended_hot_read, false}, 250
  end

  test "gate startup does not wait indefinitely for the transition lock" do
    term_key = {__MODULE__, make_ref()}
    parent = self()

    lock_holder =
      spawn(fn ->
        lock_id = {{OperationalGate, term_key}, self()}
        true = :global.set_lock(lock_id, [node()], 0)
        send(parent, :startup_transition_lock_held)

        receive do
          :release -> :global.del_lock(lock_id, [node()])
        end
      end)

    starter =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        receive do
          :start ->
            result =
              OperationalGate.start_link(
                name: nil,
                term_key: term_key,
                controller: parent
              )

            send(parent, {:lock_contended_gate_start, result})

            receive do
              :stop ->
                case result do
                  {:ok, gate} -> stop_if_alive(gate)
                  {:error, _reason} -> :ok
                end
            end
        end
      end)

    on_exit(fn ->
      send(lock_holder, :release)
      send(starter, :stop)
      if Process.alive?(lock_holder), do: Process.exit(lock_holder, :kill)
      if Process.alive?(starter), do: Process.exit(starter, :kill)
      :persistent_term.erase(term_key)
    end)

    assert_receive :startup_transition_lock_held
    send(starter, :start)
    assert_receive {:lock_contended_gate_start, _result}, 250
  end

  test "a malformed closed authority cannot pin gate startup to an unrelated live process" do
    term_key = {__MODULE__, make_ref()}
    :persistent_term.put(term_key, {:closed, make_ref(), self()})
    parent = self()

    starter =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        result =
          OperationalGate.start_link(
            name: nil,
            term_key: term_key,
            controller: parent
          )

        send(parent, {:malformed_authority_start, result})

        receive do
          :stop ->
            case result do
              {:ok, gate} -> stop_if_alive(gate)
              {:error, _reason} -> :ok
            end
        end
      end)

    on_exit(fn ->
      if Process.alive?(starter), do: Process.exit(starter, :kill)
      :persistent_term.erase(term_key)
    end)

    assert_receive {:malformed_authority_start, {:ok, gate}}
    refute OperationalGate.open?(term_key)
    assert OperationalGate.status(gate) == :closed
    send(starter, :stop)
  end

  test "an untrappable gate-process death closes the persistent-term read side", ctx do
    assert :ok =
             open_gate(ctx.gate, %{
               credential_epoch: 2,
               storage_epoch: <<0x66::128>>,
               generation: 8,
               manifest_hash: :binary.copy(<<0x77>>, 32)
             })

    assert OperationalGate.open?(ctx.term_key)
    Process.unlink(ctx.gate)
    ref = Process.monitor(ctx.gate)
    Process.exit(ctx.gate, :kill)
    assert_receive {:DOWN, ^ref, :process, _gate, :killed}

    eventually(fn -> refute OperationalGate.open?(ctx.term_key) end)
  end

  test "a dead gate authority cannot be reclaimed for a different controller", ctx do
    assert :ok =
             open_gate(ctx.gate, %{
               credential_epoch: 2,
               storage_epoch: <<0x66::128>>,
               generation: 8,
               manifest_hash: :binary.copy(<<0x77>>, 32)
             })

    GenServer.stop(ctx.gate)
    eventually(fn -> refute OperationalGate.open?(ctx.term_key) end)
    parent = self()

    attacker =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        result =
          OperationalGate.start_link(
            name: nil,
            term_key: ctx.term_key,
            controller: self()
          )

        send(parent, {:dead_gate_reclaim, result})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> if Process.alive?(attacker), do: Process.exit(attacker, :kill) end)

    assert_receive {:dead_gate_reclaim, {:error, :gate_controller_mismatch}}

    {:ok, restarted} =
      OperationalGate.start_link(name: nil, term_key: ctx.term_key, controller: self())

    on_exit(fn -> stop_if_alive(restarted) end)
    assert OperationalGate.status(restarted) == :closed
  end

  test "a controller named like the legacy sentinel remains authoritative after gate death" do
    assert Process.whereis(:unknown) == nil
    term_key = {__MODULE__, make_ref()}
    parent = self()

    controller =
      spawn(fn ->
        Process.register(self(), :unknown)
        send(parent, :unknown_controller_registered)
        Process.sleep(:infinity)
      end)

    assert_receive :unknown_controller_registered
    {:ok, gate} = OperationalGate.start_link(name: nil, term_key: term_key, controller: :unknown)

    attacker =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        receive do
          :claim ->
            result =
              OperationalGate.start_link(
                name: nil,
                term_key: term_key,
                controller: self()
              )

            send(parent, {:unknown_controller_reclaim, result})
            Process.sleep(:infinity)
        end
      end)

    on_exit(fn ->
      stop_if_alive(gate)
      if Process.alive?(attacker), do: Process.exit(attacker, :kill)
      if Process.alive?(controller), do: Process.exit(controller, :kill)
      :persistent_term.erase(term_key)
    end)

    GenServer.stop(gate)
    eventually(fn -> refute OperationalGate.open?(term_key) end)
    send(attacker, :claim)

    assert_receive {
      :unknown_controller_reclaim,
      {:error, :gate_controller_mismatch}
    }

    {:ok, restarted} =
      OperationalGate.start_link(name: nil, term_key: term_key, controller: :unknown)

    on_exit(fn -> stop_if_alive(restarted) end)
    assert OperationalGate.status(restarted) == :closed
  end

  test "a gate process restart always returns to fail-safe closed", ctx do
    assert :ok =
             open_gate(ctx.gate, %{
               credential_epoch: 2,
               storage_epoch: <<0x66::128>>,
               generation: 8,
               manifest_hash: :binary.copy(<<0x77>>, 32)
             })

    GenServer.stop(ctx.gate)

    {:ok, restarted} =
      OperationalGate.start_link(name: nil, term_key: ctx.term_key, controller: self())

    on_exit(fn -> stop_if_alive(restarted) end)

    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(restarted) == :closed
  end

  defp valid_binding do
    %{
      credential_epoch: 3,
      storage_epoch: <<0x69::128>>,
      generation: 11,
      manifest_hash: :binary.copy(<<0x7A>>, 32)
    }
  end

  defp open_gate(server, binding, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    dependencies = Keyword.get(opts, :dependencies, [])
    owner_reference = Keyword.get(opts, :owner_reference, owner)
    expected_owner = Keyword.get(opts, :expected_owner, owner)

    OperationalGate.open_owned(
      server,
      controller_capability(server),
      owner,
      dependencies,
      binding,
      authority_bindings(owner_reference, expected_owner)
    )
  end

  defp controller_capability(server) do
    server
    |> GenServer.whereis()
    |> :sys.get_state()
    |> Map.fetch!(:controller_capability)
  end

  defp authority_bindings(owner_reference, expected_owner) do
    Map.new(Contract.sections(), &{&1, {owner_reference, expected_owner}})
  end

  defp resume_if_suspended(pid) when is_pid(pid) do
    if Process.alive?(pid), do: :erlang.resume_process(pid)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

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
