defmodule RacingOrg.Tracker.Pro.DesiredState.ApplierTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DesiredState.{Applier, Store}
  alias RacingOrg.Tracker.Pro.DesiredStateTestSupport, as: DS
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  defmodule SequencedOwnerRegistry do
    def start_link(owner_pids), do: Agent.start_link(fn -> owner_pids end)

    def whereis_name(registry) do
      Agent.get_and_update(registry, fn
        [owner_pid, next_owner_pid | rest] -> {owner_pid, [next_owner_pid | rest]}
        [owner_pid] -> {owner_pid, [owner_pid]}
      end)
    end
  end

  defmodule BlockingOwnerRegistry do
    def start_link(listener, owner_pid) do
      Agent.start_link(fn -> %{listener: listener, owner_pid: owner_pid} end)
    end

    def whereis_name(registry) do
      %{listener: listener, owner_pid: owner_pid} = Agent.get(registry, & &1)
      send(listener, {:owner_resolution_blocked, self()})

      receive do
        :continue_owner_resolution -> owner_pid
      end
    end
  end

  defmodule TrappingOwnerRegistry do
    def whereis_name({listener, owner_pid}) do
      Process.flag(:trap_exit, true)
      send(listener, {:trapping_owner_resolution_blocked, self()})
      await_resolution(owner_pid)
    end

    defp await_resolution(owner_pid) do
      receive do
        :continue_owner_resolution -> owner_pid
        _exit_signal -> await_resolution(owner_pid)
      end
    end
  end

  @apply_order [
    :assignment,
    :calibration,
    :clock_source,
    :computed_values,
    :polar,
    :tracking,
    :upstream,
    :wind_shift,
    :wifi
  ]

  setup do
    base = Path.join(System.tmp_dir!(), "desired_applier_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)

    store = Store.new(base_dir: base, storage_epoch: DS.storage_epoch())
    %{store: store}
  end

  test "exports only owner-bound mutation APIs" do
    Code.ensure_loaded!(Applier)

    assert function_exported?(Applier, :apply_non_network, 3)
    assert function_exported?(Applier, :apply_wifi, 4)
    assert function_exported?(Applier, :reconcile_generation, 3)
    assert function_exported?(Applier, :validate_generation, 4)
    assert function_exported?(Applier, :reset_to_compile_default, 2)

    refute function_exported?(Applier, :apply_candidate, 3)
    refute function_exported?(Applier, :apply_candidate, 4)
    refute function_exported?(Applier, :apply_non_network, 2)
    refute function_exported?(Applier, :apply_wifi, 3)
    refute function_exported?(Applier, :reconcile_generation, 2)
    refute function_exported?(Applier, :validate_generation, 2)
    refute function_exported?(Applier, :validate_generation, 3)
    refute function_exported?(Applier, :reset_to_compile_default, 1)
  end

  test "a forged GenServer from tuple cannot authorize an owner mutation", %{store: store} do
    pid = start_applier(store, adapters(self()))
    tag = make_ref()

    send(
      pid,
      {:"$gen_call", {self(), tag}, {:reset_to_compile_default, owner_map(self())}}
    )

    assert_receive {^tag, {:error, :invalid_applier_manager}}
    refute_receive {:owner_event, :reset, _name, nil}
  end

  test "pre-validates all nine sections before applying them in deterministic order", %{store: store} do
    fixture = fully_stage(store, DS.generation_fixture())
    pid = start_applier(store, adapters(self()))

    pointer = pointer(fixture)
    owner_pid_map = owner_map(self())

    assert :ok = Applier.validate_generation(pid, pointer, nil, owner_pid_map)
    assert :ok = Applier.apply_non_network(pid, pointer, owner_pid_map)
    assert :ok = Applier.apply_wifi(pid, pointer, nil, owner_pid_map)

    assert_events(:validate, Contract.sections(), fixture.manifest_hash)
    assert_events({:apply, :candidate}, @apply_order, fixture.manifest_hash)
  end

  test "exposes separate validation, non-network apply, and Wi-Fi apply phases", %{store: store} do
    fixture = fully_stage(store, DS.generation_fixture())
    pid = start_applier(store, adapters(self()))
    pointer = pointer(fixture)
    owner_pid_map = owner_map(self())

    assert :ok = Applier.validate_generation(pid, pointer, nil, owner_pid_map)
    assert_events(:validate, Contract.sections(), fixture.manifest_hash)
    refute_receive {:owner_event, {:apply, _mode}, _name, _hash}

    assert :ok = Applier.apply_non_network(pid, pointer, owner_pid_map)
    assert_events({:apply, :candidate}, Enum.reject(@apply_order, &(&1 == :wifi)), fixture.manifest_hash)
    refute_receive {:owner_event, {:apply, :candidate}, :wifi, _hash}

    assert :ok = Applier.apply_wifi(pid, pointer, nil, owner_pid_map)
    assert_receive {:owner_event, {:apply, :candidate}, :wifi, hash}
    assert hash == fixture.manifest_hash
  end

  test "owner-bound apply uses exact PIDs across a live reference handoff", %{store: store} do
    fixture = fully_stage(store, DS.generation_fixture())

    first_owner = start_owner()
    replacement = start_owner()

    owner_name = {:desired_state_applier_owner, make_ref()}
    owner_ref = {:global, owner_name}
    assert :yes = :global.register_name(owner_name, first_owner)
    on_exit(fn -> :global.unregister_name(owner_name) end)

    owners = owner_map(owner_ref)
    expected_owner_pids = owner_map(first_owner)
    test_pid = self()

    adapters =
      Map.new(Contract.sections(), fn name ->
        adapter = %{
          validate: fn _section, _context -> :ok end,
          apply: fn _section, context ->
            if name == :tracking do
              :ok = :global.unregister_name(owner_name)
              :yes = :global.register_name(owner_name, replacement)
            end

            send(test_pid, {:bound_owner_apply, name, context.owner_pid})
            :ok
          end,
          reset: fn _context -> :ok end
        }

        {name, adapter}
      end)

    pid = start_applier(store, adapters, owners: owners)

    assert :ok =
             Applier.apply_non_network(
               pid,
               pointer(fixture),
               expected_owner_pids
             )

    Enum.each(Enum.reject(@apply_order, &(&1 == :wifi)), fn name ->
      assert_receive {:bound_owner_apply, ^name, ^first_owner}
    end)

    assert :global.whereis_name(owner_name) == replacement
  end

  test "owner-bound apply rejects a stale PID map before mutating owners", %{store: store} do
    fixture = fully_stage(store, DS.generation_fixture())
    first_owner = start_owner()
    replacement = start_owner()
    owner_name = {:desired_state_applier_owner, make_ref()}
    owner_ref = {:global, owner_name}
    assert :yes = :global.register_name(owner_name, first_owner)
    on_exit(fn -> :global.unregister_name(owner_name) end)

    test_pid = self()

    adapters =
      Map.new(Contract.sections(), fn name ->
        {name,
         %{
           validate: fn _section, _context -> :ok end,
           apply: fn _section, _context ->
             send(test_pid, {:unexpected_owner_apply, name})
             :ok
           end,
           reset: fn _context -> :ok end
         }}
      end)

    pid = start_applier(store, adapters, owners: owner_map(owner_ref))
    expected_owner_pids = owner_map(first_owner)
    :ok = :global.unregister_name(owner_name)
    assert :yes = :global.register_name(owner_name, replacement)

    assert {:error, :owner_set_changed} =
             Applier.apply_non_network(pid, pointer(fixture), expected_owner_pids)

    refute_receive {:unexpected_owner_apply, _name}
  end

  test "one shared owner reference cannot resolve to different section PIDs", %{store: store} do
    first_owner = start_owner()
    replacement = start_owner()
    {:ok, registry} = SequencedOwnerRegistry.start_link([first_owner, replacement])
    shared_reference = {:via, SequencedOwnerRegistry, registry}

    on_exit(fn ->
      if Process.alive?(registry), do: Agent.stop(registry)
    end)

    owners =
      self()
      |> owner_map()
      |> Map.put(:assignment, shared_reference)
      |> Map.put(:polar, shared_reference)

    expected_owner_pids =
      self()
      |> owner_map()
      |> Map.put(:assignment, first_owner)
      |> Map.put(:polar, replacement)

    test_pid = self()

    adapters =
      Map.new(Contract.sections(), fn name ->
        {name,
         %{
           validate: fn _section, _context -> :ok end,
           apply: fn _section, _context -> :ok end,
           reset: fn context ->
             send(test_pid, {:unexpected_mixed_owner_reset, name, context.owner_pid})
             :ok
           end
         }}
      end)

    pid = start_applier(store, adapters, owners: owners)

    assert {:error, :owner_set_changed} =
             Applier.reset_to_compile_default(pid, expected_owner_pids)

    refute_receive {:unexpected_mixed_owner_reset, _name, _owner_pid}
  end

  test "a hung owner resolver fails a mutation within a bounded interval", %{store: store} do
    owner_pid = self()
    {:ok, registry} = BlockingOwnerRegistry.start_link(self(), owner_pid)
    owner_reference = {:via, BlockingOwnerRegistry, registry}

    on_exit(fn ->
      if Process.alive?(registry), do: Agent.stop(registry)
    end)

    caller =
      Task.async(fn ->
        receive do
          {:run, applier} ->
            Applier.reset_to_compile_default(applier, owner_map(owner_pid))
        end
      end)

    pid =
      start_applier(store, adapters(self()),
        owners: owner_map(owner_reference),
        owner_resolution_timeout_ms: 25,
        manager: caller.pid,
        manager_pid: caller.pid
      )

    send(caller.pid, {:run, pid})
    assert_receive {:owner_resolution_blocked, resolver_pid}
    assert resolver_pid != pid
    assert {:error, :owner_resolution_timeout} = Task.await(caller, 250)
    assert Process.alive?(pid)
  end

  test "a timed-out resolver is killed even when its callback traps exits", %{store: store} do
    owner_pid = self()
    owner_reference = {:via, TrappingOwnerRegistry, {self(), owner_pid}}

    caller =
      Task.async(fn ->
        receive do
          {:run, applier} ->
            Applier.reset_to_compile_default(applier, owner_map(owner_pid))
        end
      end)

    pid =
      start_applier(store, adapters(self()),
        owners: owner_map(owner_reference),
        owner_resolution_timeout_ms: 25,
        manager: caller.pid,
        manager_pid: caller.pid
      )

    send(caller.pid, {:run, pid})
    assert_receive {:trapping_owner_resolution_blocked, resolver_pid}
    resolver_ref = Process.monitor(resolver_pid)

    assert {:error, :owner_resolution_timeout} = Task.await(caller, 250)
    assert_receive {:DOWN, ^resolver_ref, :process, ^resolver_pid, :killed}, 250
    refute Process.alive?(resolver_pid)
    assert Process.alive?(pid)
  end

  test "killing a blocked mutation caller terminates its owner resolver", %{store: store} do
    owner_pid = self()
    {:ok, registry} = BlockingOwnerRegistry.start_link(self(), owner_pid)
    owner_reference = {:via, BlockingOwnerRegistry, registry}

    on_exit(fn ->
      if Process.alive?(registry), do: Agent.stop(registry)
    end)

    caller =
      spawn(fn ->
        receive do
          {:run, applier} ->
            Applier.reset_to_compile_default(applier, owner_map(owner_pid))
        end
      end)

    pid =
      start_applier(store, adapters(self()),
        owners: owner_map(owner_reference),
        owner_resolution_timeout_ms: 5_000,
        manager: caller,
        manager_pid: caller
      )

    send(caller, {:run, pid})
    assert_receive {:owner_resolution_blocked, resolver_pid}
    assert resolver_pid != pid
    resolver_ref = Process.monitor(resolver_pid)
    caller_ref = Process.monitor(caller)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    assert_receive {:DOWN, ^resolver_ref, :process, ^resolver_pid, _reason}, 250
    assert Process.alive?(pid)
  end

  test "crash-report formatting redacts a transient Wi-Fi secret from owner calls" do
    secret = "top-secret-wifi-passphrase"
    wrapped = RacingOrg.Tracker.Pro.WiFiManager.Secret.new(secret)

    status = %{
      state: %{store: :opaque},
      message: {:apply_wifi, %{generation: 2}, wrapped},
      reason: {:badmatch, wrapped},
      log: [{:in, {:"$gen_call", {self(), make_ref()}, {:validate_generation, %{}, wrapped}}}]
    }

    rendered =
      status
      |> Applier.format_status()
      |> then(&:io_lib.format(~c"~0p", [&1]))
      |> IO.iodata_to_binary()

    refute rendered =~ secret
  end

  test "a section validation failure mutates no owner", %{store: store} do
    fixture = fully_stage(store, DS.generation_fixture())
    pid = start_applier(store, adapters(self(), invalid: :tracking))

    assert {:error, {:validation_failed, :tracking, :invalid_tracking}} =
             Applier.validate_generation(pid, pointer(fixture), nil, owner_map(self()))

    assert_events(
      :validate,
      Enum.take_while(Contract.sections(), &(&1 != :tracking)) ++ [:tracking],
      fixture.manifest_hash
    )

    refute_receive {:owner_event, {:apply, _mode}, _name, _hash}
  end

  test "a non-network apply failure stops without running a second activation state machine", %{
    store: store
  } do
    candidate = fully_stage(store, DS.generation_fixture(generation: 2))

    pid =
      start_applier(
        store,
        adapters(self(), fail_apply: {:upstream, candidate.manifest_hash})
      )

    assert {:error, {:apply_failed, :upstream, :owner_failed}} =
             Applier.apply_non_network(pid, pointer(candidate), owner_map(self()))

    candidate_prefix = Enum.take_while(@apply_order, &(&1 != :upstream)) ++ [:upstream]
    assert_events({:apply, :candidate}, candidate_prefix, candidate.manifest_hash)
    refute_receive {:owner_event, :validate, _name, _hash}
    refute_receive {:owner_event, {:apply, :rollback}, _name, _hash}
    refute_receive {:owner_event, {:apply, :candidate}, :wifi, _hash}
  end

  test "resets every non-network owner to compile defaults in reverse apply order", %{store: store} do
    pid = start_applier(store, adapters(self()))

    assert :ok = Applier.reset_to_compile_default(pid, owner_map(self()))

    assert_reset_events(@apply_order |> Enum.reject(&(&1 == :wifi)) |> Enum.reverse())
    refute_receive {:owner_event, :reset, :wifi, nil}
  end

  test "attempts every owner reset and returns all failures", %{store: store} do
    pid =
      start_applier(
        store,
        adapters(self(), fail_reset: %{tracking: :tracking_store_failed, assignment: :assignment_store_failed})
      )

    assert {:error, {:reset_failed, [tracking: :tracking_store_failed, assignment: :assignment_store_failed]}} =
             Applier.reset_to_compile_default(pid, owner_map(self()))

    assert_reset_events(@apply_order |> Enum.reject(&(&1 == :wifi)) |> Enum.reverse())
  end

  defp adapters(test_pid, opts \\ []) do
    invalid = Keyword.get(opts, :invalid)
    fail_apply = Keyword.get(opts, :fail_apply)
    fail_reset = Keyword.get(opts, :fail_reset, %{})

    Map.new(Contract.sections(), fn name ->
      adapter = %{
        validate: fn _section, context ->
          send(test_pid, {:owner_event, :validate, name, context.activation_id})

          if invalid == name,
            do: {:error, String.to_atom("invalid_#{name}")},
            else: :ok
        end,
        apply: fn _section, context ->
          send(test_pid, {:owner_event, {:apply, context.mode}, name, context.activation_id})

          if fail_apply == {name, context.activation_id},
            do: {:error, :owner_failed},
            else: :ok
        end,
        reset: fn _context ->
          send(test_pid, {:owner_event, :reset, name, nil})

          case Map.fetch(fail_reset, name) do
            {:ok, reason} -> {:error, reason}
            :error -> :ok
          end
        end
      }

      {name, adapter}
    end)
  end

  defp start_applier(store, adapters, opts \\ []) do
    defaults = [
      name: nil,
      store: store,
      adapters: adapters,
      owners: owner_map(self()),
      manager: self(),
      manager_pid: self(),
      manager_capability: make_ref()
    ]

    start_supervised!({Applier, Keyword.merge(defaults, opts)})
  end

  defp owner_map(owner) do
    Map.new(Contract.sections(), &{&1, owner})
  end

  defp start_owner do
    start_supervised!(
      Supervisor.child_spec({Task, fn -> Process.sleep(:infinity) end},
        id: make_ref(),
        restart: :temporary
      )
    )
  end

  defp fully_stage(store, fixture) do
    assert {:ok, _} = Store.stage_manifest(store, fixture.delivery)
    Enum.each(DS.chunks(fixture), &assert({:ok, _} = Store.put_chunk(store, &1)))

    assert {:ok, %{status: :staged}} =
             Store.verify_and_stage(store, fixture.binding.generation, fixture.manifest_hash)

    fixture
  end

  defp pointer(fixture) do
    %{
      storage_epoch: DS.storage_epoch(),
      credential_epoch: fixture.binding.credential_epoch,
      generation: fixture.binding.generation,
      manifest_hash: fixture.manifest_hash
    }
  end

  defp assert_events(kind, names, hash) do
    Enum.each(names, fn name ->
      assert_receive {:owner_event, ^kind, ^name, ^hash}
    end)
  end

  defp assert_reset_events(names) do
    Enum.each(names, fn name ->
      assert_receive {:owner_event, :reset, ^name, nil}
    end)
  end
end
