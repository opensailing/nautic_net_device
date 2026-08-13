defmodule RacingOrg.Tracker.Pro.Commands.Ledger.ExecutorTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands.Ledger.Executor
  alias RacingOrg.Tracker.Pro.Commands.Ledger.Store
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Canonical, Command, Messages}

  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @other_storage_epoch Base.decode16!("102132435465768798a9bacbdcedfe0f", case: :lower)
  @manifest_hash :binary.copy(<<0xB2>>, 32)
  @other_manifest_hash :binary.copy(<<0xC3>>, 32)
  @credential_epoch 7
  @generation 42
  @now_ms 1_700_000_000_000

  # A provider whose effect behavior is scripted per command hash, recording every
  # observation so the tests can prove ordering (intent before effect, outcome
  # before ACK) and lease discipline.
  defmodule LoadedButIncompleteProvider do
  end

  defmodule SequencedIdentitySource do
    def next(state) do
      Agent.get_and_update(state, fn
        %{current: current, remaining: [next | rest]} = script ->
          {current, %{script | current: next, remaining: rest}}

        %{current: current, remaining: []} = script ->
          {current, script}
      end)
    end
  end

  defmodule ScriptedProvider do
    def execute(intent, state) do
      Agent.get_and_update(state, fn script ->
        observed = Map.update(script, :observed, [{:execute, intent.command_id}], &[{:execute, intent.command_id} | &1])
        {Map.get(script, :execute, {:ok, %{outcome: :applied}}), observed}
      end)
    end

    def recover(intent, state) do
      Agent.get_and_update(state, fn script ->
        observed = Map.update(script, :observed, [{:recover, intent.command_id}], &[{:recover, intent.command_id} | &1])
        {Map.get(script, :recover, :ambiguous), observed}
      end)
    end

    def with_non_application_lease(intent, proof, reason, state, transition) do
      Agent.get_and_update(state, fn script ->
        observed =
          Map.update(script, :observed, [{:lease, intent.command_id, proof, reason}], fn seen ->
            [{:lease, intent.command_id, proof, reason} | seen]
          end)

        {transition.(), observed}
      end)
    end

    def observed(state) do
      state |> Agent.get(&Map.get(&1, :observed, [])) |> Enum.reverse()
    end

    def script(state, key, value), do: Agent.update(state, &Map.put(&1, key, value))
  end

  defmodule MalformedReturnProvider do
    def execute(_intent, owner) do
      send(owner, :malformed_provider_execute_called)
      :malformed
    end

    def recover(_intent, owner) do
      send(owner, :malformed_provider_recover_called)
      :malformed
    end

    def with_non_application_lease(_intent, _proof, _reason, _context, transition), do: transition.()
  end

  defmodule RaisingProvider do
    def execute(_intent, owner) do
      send(owner, :provider_execute_called)
      raise "provider failed"
    end

    def recover(_intent, owner) do
      send(owner, :provider_recover_called)
      raise "provider failed"
    end

    def with_non_application_lease(_intent, _proof, _reason, _context, _transition), do: raise("provider failed")
  end

  defmodule SequencedFaultArmingRejectProvider do
    def execute(_intent, _context), do: {:error, :not_used}

    def recover(intent, %{owner: owner, script: script}) do
      case Agent.get_and_update(script, fn [next | rest] -> {next, rest} end) do
        :ambiguous ->
          send(owner, {:rejection_recovery_observed, intent.command_id})
          :ambiguous

        :not_applied ->
          send(owner, {:rejection_recovery_observed, intent.command_id})
          {:not_applied, :effect_not_started}
      end
    end

    def with_non_application_lease(intent, _proof, _reason, %{fault: fault, owner: owner}, transition) do
      Agent.update(fault, fn _disarmed -> :armed end)
      send(owner, {:rejection_lease_observed, intent.command_id})
      transition.()
    end
  end

  defmodule SequencedFaultArmingRecoverProvider do
    def execute(_intent, _context), do: {:error, :not_used}

    def recover(intent, %{fault: fault, owner: owner, script: script}) do
      case Agent.get_and_update(script, fn [next | rest] -> {next, rest} end) do
        :ambiguous ->
          send(owner, {:recovery_observed, intent.command_id})
          :ambiguous

        :applied ->
          Agent.update(fault, fn _disarmed -> :armed end)
          send(owner, {:recovery_observed, intent.command_id})
          {:applied, %{outcome: :applied}}
      end
    end

    def with_non_application_lease(_intent, _proof, _reason, _context, transition), do: transition.()
  end

  defmodule FaultArmingProvider do
    def execute(intent, %{arm_on: :execute} = context) do
      arm_fault(context.fault)
      ScriptedProvider.execute(intent, context.script)
    end

    def execute(intent, context), do: ScriptedProvider.execute(intent, context.script)

    def recover(intent, %{arm_on: :recover} = context) do
      arm_fault(context.fault)
      ScriptedProvider.recover(intent, context.script)
    end

    def recover(intent, context), do: ScriptedProvider.recover(intent, context.script)

    def with_non_application_lease(intent, proof, reason, context, transition) do
      if context.arm_on == :lease, do: arm_fault(context.fault)
      ScriptedProvider.with_non_application_lease(intent, proof, reason, context.script, transition)
    end

    defp arm_fault(fault), do: Agent.update(fault, fn _disarmed -> :armed end)
  end

  defmodule BlockingExecuteProvider do
    def execute(_intent, {owner, token}) do
      send(owner, {:execute_entered, token, self()})

      receive do
        {:finish_execute, ^token} -> {:ok, %{outcome: :applied}}
      end
    end

    def recover(_intent, _context), do: :ambiguous

    def with_non_application_lease(_intent, _proof, _reason, _context, transition),
      do: transition.()
  end

  defmodule SequencedBlockingRecoverProvider do
    def execute(_intent, _context), do: {:error, :not_used}

    def recover(_intent, %{owner: owner, script: script, token: token}) do
      case Agent.get_and_update(script, fn [next | rest] -> {next, rest} end) do
        :ambiguous ->
          send(owner, {:startup_recovery_done, token})
          :ambiguous

        :block_applied ->
          send(owner, {:recover_entered, token, self()})

          receive do
            {:finish_recover, ^token} -> {:applied, %{outcome: :applied}}
          end

        :not_applied ->
          {:not_applied, :effect_not_started}
      end
    end

    def with_non_application_lease(_intent, _proof, _reason, %{owner: owner, token: token}, transition) do
      send(owner, {:recovery_lease_entered, token, self()})

      receive do
        {:finish_recovery_lease, ^token} -> transition.()
      end
    end
  end

  defmodule AdvanceAfterReturnIdentitySource do
    def next(authority) do
      Agent.get_and_update(authority, fn
        %{mode: :unbound} = state ->
          {{:error, :no_verified_authority}, state}

        %{mode: :bind, old: old} = state ->
          {{:ok, old}, %{state | mode: :rotated}}

        %{mode: :rotated, rotated: rotated} = state ->
          {{:ok, rotated}, state}
      end)
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "command_executor_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, script} = Agent.start_link(fn -> %{} end)
    %{root: root, path: Path.join(root, "commands.ledger"), script: script}
  end

  describe "identity lifecycle" do
    test "ignores unrelated info messages and trapped exits without crashing the permanent executor", ctx do
      executor = start_executor(ctx)

      send(executor, {:unexpected_command_executor_message, make_ref()})
      send(executor, {:EXIT, self(), :unrelated_trapped_exit})

      assert Executor.identity(executor) == durable_identity()
      assert Process.alive?(executor)
    end

    test "starts unbound and fails delivery closed while verified authority is unavailable", ctx do
      {:ok, authority} = Agent.start_link(fn -> {:error, :no_verified_authority} end)
      executor = start_dynamic_executor(ctx, authority)

      assert Process.alive?(executor)
      assert Executor.identity(executor) == nil
      assert Path.type(Executor.path(executor)) == :absolute
      assert Path.basename(Executor.path(executor)) == Path.basename(ctx.path)

      command = delivery(command_id: command_id(1), payload: payload(:noop))
      assert {:defer, :command_executor_unbound} = Executor.deliver(executor, command)
      assert {:defer, :command_executor_unbound} = Executor.deliver(executor, command)

      assert Process.alive?(executor)
      refute File.exists?(ctx.path)
      assert ScriptedProvider.observed(ctx.script) == []
    end

    test "binds and opens the ledger when verified authority appears without restarting", ctx do
      {:ok, authority} = Agent.start_link(fn -> {:error, :no_verified_authority} end)
      executor = start_dynamic_executor(ctx, authority)

      assert Executor.identity(executor) == nil
      Agent.update(authority, fn _unavailable -> {:ok, durable_identity()} end)

      assert_eventually(fn -> Executor.identity(executor) == durable_identity() end)
      assert Process.alive?(executor)
      assert File.exists?(ctx.path)

      assert {:ack, ack} =
               Executor.deliver(executor, delivery(command_id: command_id(1), payload: payload(:noop)))

      assert ack.status == :applied
      assert [{:execute, _id}] = ScriptedProvider.observed(ctx.script)
    end

    test "first binding rejects a path redirected after unbound startup", ctx do
      File.mkdir_p!(ctx.root)
      target = Path.join(ctx.root, "redirected")
      File.mkdir_p!(target)
      alias_dir = Path.join(ctx.root, "late_alias")
      configured_path = Path.join(alias_dir, "commands.ledger")
      target_path = Path.join(target, "commands.ledger")
      {:ok, authority} = Agent.start_link(fn -> {:error, :no_verified_authority} end)

      executor =
        start_dynamic_executor(ctx, authority,
          path: configured_path,
          identity_refresh_ms: 10_000
        )

      original_path = Executor.path(executor)
      File.ln_s!(target, alias_dir)
      Agent.update(authority, fn _unavailable -> {:ok, durable_identity()} end)

      assert {:defer, :command_executor_rebind_required} =
               Executor.deliver(executor, delivery(command_id: command_id(1), payload: payload(:noop)))

      assert Executor.identity(executor) == nil
      assert Executor.path(executor) == original_path
      assert Process.alive?(executor)
      refute File.exists?(target_path)
      assert ScriptedProvider.observed(ctx.script) == []
    end

    test "unbound startup cannot bypass the reserved atomic temporary namespace through an alias", ctx do
      File.mkdir_p!(ctx.root)
      reserved = Path.join(ctx.root, "commands.ledger.tmp.ABCD-EFGH_IJKLMN")
      alias_path = Path.join(ctx.root, "command-ledger-alias")
      File.ln_s!(reserved, alias_path)
      {:ok, authority} = Agent.start_link(fn -> {:error, :no_verified_authority} end)

      opts =
        ctx
        |> executor_opts(
          identity: fn -> Agent.get(authority, & &1) end,
          device_id: nil,
          credential_epoch: nil,
          storage_epoch: nil,
          path: alias_path,
          identity_refresh_ms: 10_000
        )
        |> Keyword.put(:name, nil)

      Process.flag(:trap_exit, true)
      assert {:error, {:invalid_command_ledger_path, :reserved_atomic_temp_name}} = Executor.start_link(opts)
      refute File.exists?(reserved)
    end

    test "first late bind recovers a pending intent immediately under the live identity fence", ctx do
      pending = seed_pending_intent(ctx)
      ScriptedProvider.script(ctx.script, :recover, {:applied, %{outcome: :applied}})
      {:ok, authority} = Agent.start_link(fn -> {:error, :no_verified_authority} end)
      executor = start_dynamic_executor(ctx, authority)

      Agent.update(authority, fn _unavailable -> {:ok, durable_identity()} end)

      assert_eventually(fn ->
        case open_store(ctx) do
          {:ok, store} -> Store.pending_intent(store) == nil
          {:error, _reason} -> false
        end
      end)

      assert Executor.identity(executor) == durable_identity()
      assert [{:recover, recovered_id}] = ScriptedProvider.observed(ctx.script)
      assert recovered_id == pending.command_id
    end

    test "startup recovery latches rebind required when authority drifts immediately after open", ctx do
      pending = seed_pending_intent(ctx)

      rotated = %{
        durable_identity()
        | credential_epoch: @credential_epoch + 1,
          storage_epoch: @other_storage_epoch
      }

      {:ok, authority} =
        Agent.start_link(fn ->
          %{current: {:ok, durable_identity()}, remaining: [{:ok, rotated}]}
        end)

      executor =
        start_executor(ctx,
          identity: fn -> SequencedIdentitySource.next(authority) end,
          identity_refresh_ms: 10,
          device_id: nil,
          credential_epoch: nil,
          storage_epoch: nil
        )

      assert_eventually(fn -> Executor.identity(executor) == nil end)
      assert {:defer, :command_executor_rebind_required} = Executor.deliver(executor, pending)
      assert ScriptedProvider.observed(ctx.script) == []

      assert {:ok, old_store} = open_store(ctx)
      assert Store.pending_intent(old_store).command_id == pending.command_id
    end

    test "pending recovery revalidates authority immediately before the external verifier", ctx do
      pending = seed_pending_intent(ctx)

      rotated = %{
        durable_identity()
        | credential_epoch: @credential_epoch + 1,
          storage_epoch: @other_storage_epoch
      }

      {:ok, authority} =
        Agent.start_link(fn ->
          %{
            current: {:ok, durable_identity()},
            remaining: [{:ok, rotated}]
          }
        end)

      executor =
        start_executor(ctx,
          identity: fn -> SequencedIdentitySource.next(authority) end,
          identity_refresh_ms: 10,
          device_id: nil,
          credential_epoch: nil,
          storage_epoch: nil
        )

      assert_eventually(fn -> Executor.identity(executor) == nil end)
      assert {:defer, :command_executor_rebind_required} = Executor.deliver(executor, pending)
      assert ScriptedProvider.observed(ctx.script) == []

      assert {:ok, old_store} = open_store(ctx)
      assert Store.pending_intent(old_store).command_id == pending.command_id
    end

    test "a normal delivery revalidates authority after intent durability and before its effect", ctx do
      rotated = %{
        durable_identity()
        | credential_epoch: @credential_epoch + 1,
          storage_epoch: @other_storage_epoch
      }

      {:ok, authority} =
        Agent.start_link(fn ->
          %{
            current: {:ok, durable_identity()},
            remaining: [{:ok, durable_identity()}, {:ok, durable_identity()}, {:ok, rotated}]
          }
        end)

      executor =
        start_executor(ctx,
          identity: fn -> SequencedIdentitySource.next(authority) end,
          identity_refresh_ms: 10_000,
          device_id: nil,
          credential_epoch: nil,
          storage_epoch: nil
        )

      command = delivery(command_id: command_id(1), payload: payload(:noop))
      assert {:defer, :command_executor_rebind_required} = Executor.deliver(executor, command)
      assert Executor.identity(executor) == nil
      assert ScriptedProvider.observed(ctx.script) == []

      assert {:ok, old_store} = open_store(ctx)
      assert Store.pending_intent(old_store).command_id == command.command_id
      assert Store.snapshot(old_store).next_expected_sequence == 1
    end

    test "identity drift during an effect cannot complete or ACK the retired ledger", ctx do
      {:ok, authority} = Agent.start_link(fn -> {:ok, durable_identity()} end)
      token = make_ref()

      executor =
        start_executor(ctx,
          identity: fn -> Agent.get(authority, & &1) end,
          identity_refresh_ms: 10_000,
          device_id: nil,
          credential_epoch: nil,
          storage_epoch: nil,
          providers: %{noop: {BlockingExecuteProvider, {self(), token}}}
        )

      command = delivery(command_id: command_id(1), payload: payload(:noop))
      task = Task.async(fn -> Executor.deliver(executor, command) end)

      assert_receive {:execute_entered, ^token, provider}
      Agent.update(authority, fn _old -> {:ok, rotated_identity()} end)
      send(provider, {:finish_execute, token})

      assert {:defer, :command_executor_rebind_required} = Task.await(task)
      assert Executor.identity(executor) == nil

      assert {:ok, old_store} = open_store(ctx)
      snapshot = Store.snapshot(old_store)
      assert snapshot.pending_intent.command_id == command.command_id
      refute Map.has_key?(snapshot.outcomes, command.command_id)
    end

    test "delivery-triggered first binding rechecks authority before replaying a retained ACK", ctx do
      duplicate = seed_applied_outcome(ctx)

      {:ok, authority} =
        Agent.start_link(fn ->
          %{mode: :unbound, old: durable_identity(), rotated: rotated_identity()}
        end)

      executor =
        start_executor(ctx,
          identity: fn -> AdvanceAfterReturnIdentitySource.next(authority) end,
          identity_refresh_ms: 10_000,
          device_id: nil,
          credential_epoch: nil,
          storage_epoch: nil
        )

      assert Executor.identity(executor) == nil
      Agent.update(authority, &%{&1 | mode: :bind})

      assert {:defer, :command_executor_rebind_required} = Executor.deliver(executor, duplicate)
      assert Executor.identity(executor) == nil
      assert ScriptedProvider.observed(ctx.script) == []

      assert {:ok, old_store} = open_store(ctx)
      snapshot = Store.snapshot(old_store)
      assert snapshot.pending_intent == nil
      assert snapshot.next_expected_sequence == 2
      assert Map.has_key?(snapshot.outcomes, duplicate.command_id)
    end

    test "bound duplicate replay rechecks authority immediately before ACK exposure", ctx do
      duplicate = seed_applied_outcome(ctx)

      {:ok, authority} =
        Agent.start_link(fn ->
          %{
            current: {:ok, durable_identity()},
            remaining: [{:ok, durable_identity()}, {:ok, durable_identity()}, {:ok, rotated_identity()}]
          }
        end)

      executor =
        start_executor(ctx,
          identity: fn -> SequencedIdentitySource.next(authority) end,
          identity_refresh_ms: 10_000,
          device_id: nil,
          credential_epoch: nil,
          storage_epoch: nil
        )

      assert {:defer, :command_executor_rebind_required} = Executor.deliver(executor, duplicate)
      assert Executor.identity(executor) == nil
      assert ScriptedProvider.observed(ctx.script) == []
    end

    test "post-bind authority loss latches rebind required and preserves the old ledger", ctx do
      {:ok, authority} = Agent.start_link(fn -> {:ok, durable_identity()} end)
      executor = start_dynamic_executor(ctx, authority, identity_refresh_ms: 10_000)
      command = delivery(command_id: command_id(1), payload: payload(:noop))

      assert {:ack, applied} = Executor.deliver(executor, command)
      Agent.update(authority, fn _bound -> {:error, :no_verified_authority} end)

      assert {:defer, :command_executor_rebind_required} = Executor.deliver(executor, command)
      Agent.update(authority, fn _lost -> {:ok, durable_identity()} end)
      assert {:defer, :command_executor_rebind_required} = Executor.deliver(executor, command)
      assert ScriptedProvider.observed(ctx.script) == [{:execute, command.command_id}]

      assert {:ok, old_store} = open_store(ctx)
      outcome = Map.fetch!(Store.snapshot(old_store).outcomes, command.command_id)
      assert outcome.result == applied.result
      assert File.exists?(ctx.path)
    end

    test "credential storage and device drift independently latch before duplicate replay", ctx do
      drifted_identities = [
        %{durable_identity() | credential_epoch: @credential_epoch + 1},
        %{durable_identity() | storage_epoch: @other_storage_epoch},
        %{durable_identity() | device_id: :binary.copy(<<0x4B>>, 16)}
      ]

      for {rotated, index} <- Enum.with_index(drifted_identities, 1) do
        isolated = %{
          ctx
          | path: Path.join(ctx.root, "commands-#{index}.ledger")
        }

        {:ok, authority} = Agent.start_link(fn -> {:ok, durable_identity()} end)

        opts =
          isolated
          |> executor_opts(
            identity: fn -> Agent.get(authority, & &1) end,
            identity_refresh_ms: 10_000,
            device_id: nil,
            credential_epoch: nil,
            storage_epoch: nil
          )
          |> Keyword.put(:name, nil)

        {:ok, executor} = Executor.start_link(opts)

        command = delivery(command_id: command_id(index), payload: payload(:noop))
        assert {:ack, _applied} = Executor.deliver(executor, command)

        Agent.update(authority, fn _bound -> {:ok, rotated} end)
        assert {:defer, :command_executor_rebind_required} = Executor.deliver(executor, command)
        assert Process.alive?(executor)
        GenServer.stop(executor)
      end
    end

    test "stale identity refresh messages cannot create another poll loop", ctx do
      {:ok, authority} = Agent.start_link(fn -> {:error, :no_verified_authority} end)
      executor = start_dynamic_executor(ctx, authority, identity_refresh_ms: 10_000)
      before = Agent.get(authority, & &1)

      send(executor, {:refresh_identity, make_ref()})
      Process.sleep(20)

      assert Process.alive?(executor)
      assert Agent.get(authority, & &1) == before
      assert Executor.identity(executor) == nil
    end

    test "credential and storage identity drift fails closed without deleting the old ledger", ctx do
      {:ok, authority} = Agent.start_link(fn -> {:ok, durable_identity()} end)
      executor = start_dynamic_executor(ctx, authority)
      old_delivery = delivery(command_id: command_id(1), payload: payload(:noop))

      assert {:ack, %{status: :applied}} = Executor.deliver(executor, old_delivery)
      old_path = Executor.path(executor)
      assert File.exists?(old_path)

      rotated = %{
        durable_identity()
        | credential_epoch: @credential_epoch + 1,
          storage_epoch: @other_storage_epoch
      }

      Agent.update(authority, fn _old -> {:ok, rotated} end)

      next_old_delivery =
        delivery(
          command_id: command_id(2),
          command_sequence: 2,
          payload: payload(:noop)
        )

      assert {:defer, :command_executor_rebind_required} =
               Executor.deliver(executor, next_old_delivery)

      assert Executor.identity(executor) == nil
      assert Executor.path(executor) == old_path
      assert Process.alive?(executor)
      assert File.exists?(old_path)
      assert [{:execute, _old}] = ScriptedProvider.observed(ctx.script)

      assert {:ok, old_store} = open_store(ctx)
      assert Store.snapshot(old_store).next_expected_sequence == 2
      assert Map.has_key?(Store.snapshot(old_store).outcomes, old_delivery.command_id)
    end
  end

  describe "identity source validation" do
    test "rejects every partial static identity configuration", ctx do
      fields = [:device_id, :credential_epoch, :storage_epoch]

      for {present_fields, index} <-
            fields
            |> Enum.flat_map(fn field -> [[field]] end)
            |> Kernel.++([
              [:device_id, :credential_epoch],
              [:device_id, :storage_epoch],
              [:credential_epoch, :storage_epoch]
            ])
            |> Enum.with_index(1) do
        identity = durable_identity()

        overrides =
          Enum.map(fields, fn field ->
            {field, if(field in present_fields, do: Map.fetch!(identity, field), else: nil)}
          end)

        opts =
          ctx
          |> Map.put(:path, Path.join(ctx.root, "partial-static-#{index}.ledger"))
          |> executor_opts(Keyword.put(overrides, :name, nil))

        assert {:error, :invalid_command_executor_identity} = GenServer.start(Executor, opts)
      end
    end

    test "non-transient startup identity failures are fatal", ctx do
      rows = [
        fn -> {:error, :bootstrap_failed} end,
        fn -> :invalid end,
        fn -> raise "identity failed" end,
        fn -> throw(:identity_failed) end,
        fn -> exit(:identity_failed) end
      ]

      for source <- rows do
        opts =
          executor_opts(ctx,
            identity: source,
            device_id: nil,
            credential_epoch: nil,
            storage_epoch: nil,
            name: nil
          )

        assert {:error, reason} = GenServer.start(Executor, opts)
        refute reason == :no_verified_authority
      end
    end

    test "static and dynamic identities reject the same malformed durable shapes", ctx do
      invalid = [
        %{durable_identity() | device_id: <<0::128>>},
        %{durable_identity() | device_id: <<1>>},
        %{durable_identity() | credential_epoch: -1},
        %{durable_identity() | credential_epoch: 0x1_0000_0000},
        %{durable_identity() | storage_epoch: <<0::128>>},
        %{durable_identity() | storage_epoch: <<1>>}
      ]

      for {identity, index} <- Enum.with_index(invalid, 1) do
        static_opts =
          executor_opts(%{ctx | path: Path.join(ctx.root, "static-invalid-#{index}.ledger")},
            device_id: identity.device_id,
            credential_epoch: identity.credential_epoch,
            storage_epoch: identity.storage_epoch,
            name: nil
          )

        assert {:error, :invalid_command_executor_identity} = GenServer.start(Executor, static_opts)

        dynamic_opts =
          executor_opts(%{ctx | path: Path.join(ctx.root, "dynamic-invalid-#{index}.ledger")},
            identity: fn -> {:ok, identity} end,
            device_id: nil,
            credential_epoch: nil,
            storage_epoch: nil,
            name: nil
          )

        assert {:error, :invalid_command_executor_identity} = GenServer.start(Executor, dynamic_opts)
      end
    end
  end

  describe "provider configuration" do
    test "rejects a loaded provider that omits durable effect callbacks", ctx do
      assert {:error, :invalid_command_providers} =
               GenServer.start(
                 Executor,
                 executor_opts(ctx,
                   providers: %{noop: {LoadedButIncompleteProvider, nil}}
                 )
               )
    end
  end

  describe "provider failures" do
    test "a malformed execute return stays pending and never repeats the effect", ctx do
      executor =
        start_executor(ctx,
          providers: %{noop: {MalformedReturnProvider, self()}}
        )

      command = delivery(command_id: command_id(1), payload: payload(:noop))

      assert {:defer, :ambiguous_command_recovery} = Executor.deliver(executor, command)
      assert_receive :malformed_provider_execute_called
      assert_receive :malformed_provider_recover_called

      assert {:defer, :ambiguous_command_recovery} = Executor.deliver(executor, command)
      assert_receive :malformed_provider_recover_called
      refute_receive :malformed_provider_execute_called
      assert Process.alive?(executor)

      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened).command_id == command.command_id
      refute Map.has_key?(Store.snapshot(reopened).outcomes, command.command_id)
    end

    test "provider exceptions fail closed and keep the executor alive", ctx do
      executor =
        start_executor(ctx,
          providers: %{noop: {RaisingProvider, self()}}
        )

      command = delivery(command_id: command_id(1), payload: payload(:noop))

      assert {:defer, :ambiguous_command_recovery} = Executor.deliver(executor, command)
      assert_receive :provider_execute_called
      assert_receive :provider_recover_called

      assert {:defer, :ambiguous_command_recovery} = Executor.deliver(executor, command)
      assert_receive :provider_recover_called
      refute_receive :provider_execute_called
      assert Process.alive?(executor)

      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened).command_id == command.command_id
    end
  end

  describe "durable execution ordering" do
    test "persists intent before the effect and the outcome before the ACK", ctx do
      executor = start_executor(ctx)
      delivery = delivery(command_id: command_id(1), payload: payload(:noop))

      assert {:ack, ack} = Executor.deliver(executor, delivery)
      assert ack.status == :applied
      assert ack.reason == :none
      assert ack.command_id == delivery.command_id
      assert ack.command_hash == delivery.command_hash
      assert {:ok, encoded} = Messages.encode(:command_ack, ack)
      assert {:ok, ^ack} = Messages.decode(:command_ack, encoded)

      assert [{:execute, _id}] = ScriptedProvider.observed(ctx.script)

      # The intent had to be durable BEFORE the effect ran, and the outcome
      # durable BEFORE the ACK was returned: a reopened ledger already holds the
      # terminal outcome with no pending intent.
      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened) == nil
      assert Store.snapshot(reopened).next_expected_sequence == 2
      outcome = Map.fetch!(Store.snapshot(reopened).outcomes, delivery.command_id)
      assert outcome.status == :applied
      assert outcome.result == ack.result
      assert outcome.result_hash == ack.result_hash
    end

    test "replays the exact retained terminal bytes without repeating the effect", ctx do
      executor = start_executor(ctx)
      delivery = delivery(command_id: command_id(1), payload: payload(:noop))

      assert {:ack, applied} = Executor.deliver(executor, delivery)
      assert {:ack, replayed} = Executor.deliver(executor, delivery)
      assert {:ack, ^replayed} = Executor.deliver(executor, delivery)

      assert replayed.status == :duplicate
      assert replayed.reason == :none
      # The retained RESULT bytes replay exactly; the result hash legitimately
      # differs because it binds the status, and a replay is a duplicate.
      assert replayed.result == applied.result

      assert {:ok, replayed.result_hash} ==
               Command.result_hash(%{status: :duplicate, reason: :none, result: applied.result})

      assert {:ok, _bytes} = Messages.encode(:command_ack, replayed)

      # Exactly one effect for three deliveries of the same command.
      assert [{:execute, _id}] = ScriptedProvider.observed(ctx.script)
    end

    test "an oversized provider result still records the applied effect, bounded", ctx do
      executor = start_executor(ctx)
      oversized = %{outcome: :applied, detail: Enum.map(1..512, fn _ -> :polar end)}
      ScriptedProvider.script(ctx.script, :execute, {:ok, oversized})
      delivery = delivery(command_id: command_id(1), payload: payload(:noop))

      assert {:ack, ack} = Executor.deliver(executor, delivery)
      assert ack.status == :applied
      assert {:ok, decoded} = Canonical.decode(ack.result)
      assert decoded == %{"outcome" => "applied"}

      # The effect happened, so the intent is resolved, not left pending.
      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened) == nil
    end

    test "a determinate effect failure is a durable applied outcome, never a silent retry", ctx do
      executor = start_executor(ctx)
      ScriptedProvider.script(ctx.script, :execute, {:ok, %{outcome: :failed, detail: :unavailable}})
      delivery = delivery(command_id: command_id(1), payload: payload(:noop))

      assert {:ack, ack} = Executor.deliver(executor, delivery)
      assert ack.status == :applied
      assert {:ok, decoded} = Canonical.decode(ack.result)
      assert decoded["outcome"] == "failed"

      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened) == nil
    end
  end

  describe "fences" do
    test "enforces every delivery fence and answers with the exact rejection reason", ctx do
      executor = start_executor(ctx)

      rows = [
        {delivery(device_id: :binary.copy(<<0x1A>>, 16)), :no_ack},
        {delivery(credential_epoch: 8), :stale_credential_epoch},
        {delivery(storage_epoch: @other_storage_epoch), :storage_epoch_mismatch},
        {delivery(required_generation: @generation + 1), :generation_mismatch},
        {delivery(required_manifest_hash: @other_manifest_hash), :manifest_hash_mismatch},
        {delivery(command_sequence: 5), :sequence_gap}
      ]

      for {command, expected} <- rows do
        case {expected, Executor.deliver(executor, command)} do
          {:no_ack, {:defer, _reason}} ->
            :ok

          {reason, {:ack, ack}} ->
            assert ack.status == :rejected
            assert ack.reason == reason
            assert ack.result == <<>>
            assert {:ok, _bytes} = Messages.encode(:command_ack, ack)

          other ->
            flunk("unexpected result #{inspect(other)}")
        end
      end

      # None of the fenced deliveries reached an effect.
      assert ScriptedProvider.observed(ctx.script) == []
    end

    test "a forged command hash or payload hash never reaches classification state", ctx do
      executor = start_executor(ctx)
      authentic = delivery(command_id: command_id(1), payload: payload(:noop))

      assert {:defer, _} = Executor.deliver(executor, %{authentic | command_hash: :binary.copy(<<0xA5>>, 32)})
      assert {:defer, _} = Executor.deliver(executor, %{authentic | payload_hash: :binary.copy(<<0x5A>>, 32)})
      assert {:defer, _} = Executor.deliver(executor, Map.delete(authentic, :payload))

      assert ScriptedProvider.observed(ctx.script) == []
      assert {:ok, reopened} = open_store(ctx)
      assert Store.snapshot(reopened).next_expected_sequence == 1
    end

    test "expiry is an admission fence answered with a durable terminal outcome", ctx do
      executor = start_executor(ctx, trusted_now_ms: fn -> {:ok, 5_000} end)
      delivery = delivery(command_id: command_id(1), expires_at_ms: 4_999, payload: payload(:noop))

      assert {:ack, ack} = Executor.deliver(executor, delivery)
      assert ack.status == :rejected
      assert ack.reason == :expired
      assert ScriptedProvider.observed(ctx.script) == []

      assert {:ok, reopened} = open_store(ctx)
      assert Map.fetch!(Store.snapshot(reopened).outcomes, delivery.command_id).reason == :expired
    end

    test "identity drift during terminal classification cannot persist or ACK", ctx do
      {:ok, authority} = Agent.start_link(fn -> {:ok, durable_identity()} end)

      executor =
        start_executor(ctx,
          identity: fn -> Agent.get(authority, & &1) end,
          identity_refresh_ms: 10_000,
          device_id: nil,
          credential_epoch: nil,
          storage_epoch: nil,
          trusted_now_ms: fn ->
            Agent.update(authority, fn _old -> {:ok, rotated_identity()} end)
            {:ok, 5_000}
          end
        )

      command = delivery(command_id: command_id(1), expires_at_ms: 4_999, payload: payload(:noop))

      assert {:defer, :command_executor_rebind_required} = Executor.deliver(executor, command)
      assert Executor.identity(executor) == nil

      assert {:ok, old_store} = open_store(ctx)
      snapshot = Store.snapshot(old_store)
      assert snapshot.next_expected_sequence == 1
      assert snapshot.outcomes == %{}
    end

    test "an unusable trusted clock defers without touching the ledger", ctx do
      executor = start_executor(ctx, trusted_now_ms: fn -> :unavailable end)

      assert {:defer, :trusted_clock_unavailable} =
               Executor.deliver(executor, delivery(command_id: command_id(1), payload: payload(:noop)))

      assert ScriptedProvider.observed(ctx.script) == []
      assert {:ok, reopened} = open_store(ctx)
      assert Store.snapshot(reopened).next_expected_sequence == 1
    end

    test "classification collaborators fail closed on raise, throw, and exit", ctx do
      collaborators = [
        {:desired_state, {:ack, :generation_mismatch}},
        {:gate, {:ack, :operational_gate_closed}},
        {:trusted_now_ms, {:defer, :trusted_clock_unavailable}}
      ]

      failures = [fn -> raise "unavailable" end, fn -> throw(:unavailable) end, fn -> exit(:unavailable) end]

      for {{collaborator, expected}, failure} <-
            List.flatten(for item <- collaborators, do: for(failure <- failures, do: {item, failure})) do
        path = ctx.path <> ".#{collaborator}.#{System.unique_integer([:positive])}"
        opts = Keyword.put(executor_opts(ctx, [{collaborator, failure}, {:path, path}]), :name, nil)
        executor = start_supervised!({Executor, opts}, id: make_ref())
        result = Executor.deliver(executor, delivery(command_id: command_id(1), payload: payload(:noop)))

        case expected do
          {:ack, reason} ->
            assert {:ack, %{reason: ^reason}} = result

          expected ->
            assert ^expected = result
        end

        assert Process.alive?(executor)
      end

      assert ScriptedProvider.observed(ctx.script) == []
    end

    test "an unsupported payload or type is a durable terminal outcome, not an effect", ctx do
      executor = start_executor(ctx)

      unsupported = delivery(command_id: command_id(1), payload: <<0xFF, 0xFF>>)
      assert {:ack, ack} = Executor.deliver(executor, unsupported)
      assert ack.status == :rejected
      assert ack.reason in [:invalid_payload, :unsupported_command]
      assert ScriptedProvider.observed(ctx.script) == []
    end

    test "a closed operational gate rejects transiently and never persists or executes", ctx do
      executor = start_executor(ctx, gate: fn -> :closed end)

      assert {:ack, ack} = Executor.deliver(executor, delivery(command_id: command_id(1), payload: payload(:noop)))
      assert ack.status == :rejected
      assert ack.reason == :operational_gate_closed
      assert ScriptedProvider.observed(ctx.script) == []
      assert {:ok, reopened} = open_store(ctx)
      assert Store.snapshot(reopened).next_expected_sequence == 1
    end

    test "a gate binding for another incarnation is not the open gate this command required", ctx do
      binding = %{
        credential_epoch: @credential_epoch,
        storage_epoch: @other_storage_epoch,
        generation: @generation,
        manifest_hash: @manifest_hash
      }

      executor = start_executor(ctx, gate: fn -> {:open, binding} end)

      assert {:ack, ack} = Executor.deliver(executor, delivery(command_id: command_id(1), payload: payload(:noop)))
      assert ack.reason == :operational_gate_closed
      assert ScriptedProvider.observed(ctx.script) == []
    end
  end

  describe "durability-uncertain write reconciliation" do
    test "re-observes a visible uncertain intent before answering the initial delivery", ctx do
      {fault, injector} = disarmed_one_shot_fault_at(:renamed)
      ScriptedProvider.script(ctx.script, :recover, {:applied, %{outcome: :applied}})
      executor = start_executor(ctx, fault_injector: injector)
      command = delivery(command_id: command_id(1), payload: payload(:noop))
      arm_fault(fault)

      assert {:ack, ack} = Executor.deliver(executor, command)
      assert ack.command_id == command.command_id
      assert ack.status in [:applied, :duplicate]
      assert ScriptedProvider.observed(ctx.script) == [{:recover, command.command_id}]

      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened) == nil
      assert Map.fetch!(Store.snapshot(reopened).outcomes, command.command_id).status == :applied
    end

    test "re-observes a visible uncertain applied outcome before answering the initial delivery", ctx do
      {fault, injector} = disarmed_one_shot_fault_at(:renamed)
      provider_context = %{arm_on: :execute, fault: fault, script: ctx.script}

      executor =
        start_executor(ctx,
          fault_injector: injector,
          providers: %{noop: {FaultArmingProvider, provider_context}}
        )

      command = delivery(command_id: command_id(1), payload: payload(:noop))

      assert {:ack, ack} = Executor.deliver(executor, command)
      assert ack.command_id == command.command_id
      assert ack.status == :duplicate
      assert ScriptedProvider.observed(ctx.script) == [{:execute, command.command_id}]

      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened) == nil
      assert Map.fetch!(Store.snapshot(reopened).outcomes, command.command_id).status == :applied
    end

    test "re-observes a visible uncertain terminal before answering the initial delivery", ctx do
      {fault, injector} = disarmed_one_shot_fault_at(:renamed)
      executor = start_executor(ctx, fault_injector: injector, trusted_now_ms: fn -> {:ok, 5_000} end)
      command = delivery(command_id: command_id(1), expires_at_ms: 4_999, payload: payload(:noop))
      arm_fault(fault)

      assert {:ack, ack} = Executor.deliver(executor, command)
      assert ack.command_id == command.command_id
      assert ack.status in [:rejected, :duplicate]
      assert ack.reason == :expired
      assert ScriptedProvider.observed(ctx.script) == []

      assert {:ok, reopened} = open_store(ctx)
      assert Map.fetch!(Store.snapshot(reopened).outcomes, command.command_id).reason == :expired
    end

    test "reopens a visible uncertain intent and recovers without restarting", ctx do
      {fault, injector} = disarmed_fault_at(:renamed)
      executor = start_executor(ctx, fault_injector: injector)
      command = delivery(command_id: command_id(1), payload: payload(:noop))
      arm_fault(fault)

      assert {:defer, {:command_ledger_durability_uncertain, {:fault_injected, :renamed, :power_loss}}} =
               Executor.deliver(executor, command)

      assert ScriptedProvider.observed(ctx.script) == []
      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened).command_id == command.command_id

      disarm_fault(fault)
      ScriptedProvider.script(ctx.script, :recover, {:applied, %{outcome: :applied}})

      assert {:ack, ack} = Executor.deliver(executor, command)
      assert ack.command_id == command.command_id
      assert ack.status in [:applied, :duplicate]
      assert ScriptedProvider.observed(ctx.script) == [{:recover, command.command_id}]

      assert {:ok, reconciled} = open_store(ctx)
      assert Store.pending_intent(reconciled) == nil
      assert Map.fetch!(Store.snapshot(reconciled).outcomes, command.command_id).status == :applied
    end

    test "reopens a visible uncertain applied outcome and replays it without recovery", ctx do
      {fault, injector} = disarmed_fault_at(:renamed)
      provider_context = %{arm_on: :execute, fault: fault, script: ctx.script}

      executor =
        start_executor(ctx,
          fault_injector: injector,
          providers: %{noop: {FaultArmingProvider, provider_context}}
        )

      command = delivery(command_id: command_id(1), payload: payload(:noop))

      assert {:defer, {:command_ledger_durability_uncertain, {:fault_injected, :renamed, :power_loss}}} =
               Executor.deliver(executor, command)

      assert ScriptedProvider.observed(ctx.script) == [{:execute, command.command_id}]
      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened) == nil
      assert Map.fetch!(Store.snapshot(reopened).outcomes, command.command_id).status == :applied

      assert {:defer, {:command_ledger_durability_uncertain, {:fault_injected, :renamed, :power_loss}}} =
               Executor.deliver(executor, command)

      assert ScriptedProvider.observed(ctx.script) == [{:execute, command.command_id}]

      disarm_fault(fault)
      ScriptedProvider.script(ctx.script, :recover, {:applied, %{outcome: :applied}})

      assert {:ack, ack} = Executor.deliver(executor, command)
      assert ack.command_id == command.command_id
      assert ack.status == :duplicate

      assert ScriptedProvider.observed(ctx.script) == [{:execute, command.command_id}]
    end

    test "reopens a visible uncertain classified terminal outcome and replays it", ctx do
      {fault, injector} = disarmed_fault_at(:renamed)
      executor = start_executor(ctx, fault_injector: injector, trusted_now_ms: fn -> {:ok, 5_000} end)
      command = delivery(command_id: command_id(1), expires_at_ms: 4_999, payload: payload(:noop))
      arm_fault(fault)

      assert {:defer, {:command_ledger_durability_uncertain, {:fault_injected, :renamed, :power_loss}}} =
               Executor.deliver(executor, command)

      assert ScriptedProvider.observed(ctx.script) == []
      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened) == nil
      assert Map.fetch!(Store.snapshot(reopened).outcomes, command.command_id).reason == :expired

      disarm_fault(fault)

      assert {:ack, ack} = Executor.deliver(executor, command)
      assert ack.command_id == command.command_id
      assert ack.status in [:rejected, :duplicate]
      assert ack.reason == :expired
      assert ScriptedProvider.observed(ctx.script) == []
    end

    test "re-observes an uncertain recovered outcome before answering the delivery", ctx do
      pending = seed_pending_intent(ctx)
      {fault, injector} = disarmed_one_shot_fault_at(:renamed)
      {:ok, recovery_script} = Agent.start_link(fn -> [:ambiguous, :applied] end)
      provider_context = %{fault: fault, owner: self(), script: recovery_script}

      executor =
        start_executor(ctx,
          fault_injector: injector,
          providers: %{noop: {SequencedFaultArmingRecoverProvider, provider_context}}
        )

      assert_receive {:recovery_observed, command_id}
      assert command_id == pending.command_id

      assert {:ack, ack} = Executor.deliver(executor, pending)
      assert_receive {:recovery_observed, ^command_id}
      assert ack.command_id == pending.command_id
      assert ack.status == :duplicate
      refute_receive {:recovery_observed, ^command_id}

      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened) == nil
      assert Map.fetch!(Store.snapshot(reopened).outcomes, pending.command_id).status == :applied
    end

    test "re-observes an uncertain recovery rejection before answering the delivery", ctx do
      pending = seed_pending_intent(ctx)
      {fault, injector} = disarmed_one_shot_fault_at(:renamed)
      {:ok, recovery_script} = Agent.start_link(fn -> [:ambiguous, :not_applied] end)
      provider_context = %{fault: fault, owner: self(), script: recovery_script}

      executor =
        start_executor(ctx,
          fault_injector: injector,
          providers: %{noop: {SequencedFaultArmingRejectProvider, provider_context}}
        )

      assert_receive {:rejection_recovery_observed, command_id}
      assert command_id == pending.command_id

      assert {:ack, ack} = Executor.deliver(executor, pending)
      assert_receive {:rejection_recovery_observed, ^command_id}
      assert_receive {:rejection_lease_observed, ^command_id}
      assert ack.command_id == pending.command_id
      assert ack.status in [:rejected, :duplicate]
      assert ack.reason == :operational_gate_closed
      refute_receive {:rejection_recovery_observed, ^command_id}
      refute_receive {:rejection_lease_observed, ^command_id}

      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened) == nil
      assert Map.fetch!(Store.snapshot(reopened).outcomes, pending.command_id).status == :rejected
    end

    test "reopens a visible uncertain rejection and replays it without another recovery", ctx do
      pending = seed_pending_intent(ctx)
      {fault, injector} = disarmed_fault_at(:renamed)
      ScriptedProvider.script(ctx.script, :recover, {:not_applied, :effect_not_started})
      provider_context = %{arm_on: :lease, fault: fault, script: ctx.script}

      executor =
        start_executor(ctx,
          fault_injector: injector,
          providers: %{noop: {FaultArmingProvider, provider_context}}
        )

      assert_eventually(fn ->
        case open_store(ctx) do
          {:ok, store} ->
            Store.pending_intent(store) == nil and
              Map.fetch!(Store.snapshot(store).outcomes, pending.command_id).status == :rejected

          {:error, _reason} ->
            false
        end
      end)

      observed = ScriptedProvider.observed(ctx.script)
      assert Enum.count(observed, &match?({:recover, _}, &1)) == 1
      assert Enum.count(observed, &match?({:lease, _, _, _}, &1)) == 1

      disarm_fault(fault)

      assert {:ack, ack} = Executor.deliver(executor, pending)
      assert ack.command_id == pending.command_id
      assert ack.status in [:rejected, :duplicate]
      assert ack.reason == :operational_gate_closed

      assert ScriptedProvider.observed(ctx.script) == observed
    end
  end

  describe "recovery of a pending intent" do
    test "proven application completes the intent and answers the exact ACK", ctx do
      pending = seed_pending_intent(ctx)
      ScriptedProvider.script(ctx.script, :recover, {:applied, %{outcome: :applied}})
      executor = start_executor(ctx)

      assert {:ack, ack} = Executor.deliver(executor, pending)
      assert ack.status in [:applied, :duplicate]
      assert ack.command_id == pending.command_id
      assert [{:recover, _id} | _] = ScriptedProvider.observed(ctx.script)
      refute Enum.any?(ScriptedProvider.observed(ctx.script), &match?({:execute, _}, &1))

      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened) == nil
    end

    test "proven non-application rejects under the command-specific lease with the documented reason", ctx do
      pending = seed_pending_intent(ctx)
      ScriptedProvider.script(ctx.script, :recover, {:not_applied, :effect_not_started})
      executor = start_executor(ctx)

      assert {:ack, ack} = Executor.deliver(executor, pending)
      assert ack.status == :rejected
      assert ack.reason == :operational_gate_closed
      assert ack.result == <<>>
      assert {:ok, _bytes} = Messages.encode(:command_ack, ack)

      observed = ScriptedProvider.observed(ctx.script)

      assert {:lease, _id, :effect_not_started, :operational_gate_closed} =
               Enum.find(observed, &match?({:lease, _, _, _}, &1))

      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened) == nil
      assert Map.fetch!(Store.snapshot(reopened).outcomes, pending.command_id).status == :rejected
    end

    test "a recovered command's outcome is never lost — redelivery replays its retained bytes", ctx do
      pending = seed_pending_intent(ctx)
      ScriptedProvider.script(ctx.script, :recover, {:applied, %{outcome: :applied}})
      executor = start_executor(ctx)

      # A DIFFERENT command is delivered first, so the recovery ACK is not the one
      # returned. The recovered outcome must still be durably retained.
      next = delivery(command_id: command_id(9), command_sequence: 2, payload: payload(:noop))
      assert {:ack, next_ack} = Executor.deliver(executor, next)
      assert next_ack.command_id == next.command_id

      # Redelivering the recovered command replays its exact retained terminal
      # bytes rather than re-running anything.
      assert {:ack, replayed} = Executor.deliver(executor, pending)
      assert replayed.command_id == pending.command_id
      assert replayed.status == :duplicate

      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened) == nil
      assert Map.fetch!(Store.snapshot(reopened).outcomes, pending.command_id).status == :applied
    end

    test "ambiguous recovery stays pending, emits no ACK, and blocks later commands", ctx do
      pending = seed_pending_intent(ctx)
      ScriptedProvider.script(ctx.script, :recover, :ambiguous)
      executor = start_executor(ctx)

      assert {:defer, _reason} = Executor.deliver(executor, pending)

      next = delivery(command_id: command_id(9), command_sequence: 2, payload: payload(:noop))
      assert {:defer, _reason} = Executor.deliver(executor, next)

      refute Enum.any?(ScriptedProvider.observed(ctx.script), &match?({:execute, _}, &1))
      refute Enum.any?(ScriptedProvider.observed(ctx.script), &match?({:lease, _, _, _}, &1))

      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened) != nil
    end

    test "identity drift during recovery cannot complete or replay an ACK", ctx do
      pending = seed_pending_intent(ctx)
      {:ok, authority} = Agent.start_link(fn -> {:ok, durable_identity()} end)
      {:ok, script} = Agent.start_link(fn -> [:ambiguous, :block_applied] end)
      token = make_ref()
      provider_context = %{owner: self(), script: script, token: token}

      executor =
        start_executor(ctx,
          identity: fn -> Agent.get(authority, & &1) end,
          identity_refresh_ms: 10_000,
          device_id: nil,
          credential_epoch: nil,
          storage_epoch: nil,
          providers: %{noop: {SequencedBlockingRecoverProvider, provider_context}}
        )

      assert_receive {:startup_recovery_done, ^token}
      _state = :sys.get_state(executor)

      task = Task.async(fn -> Executor.deliver(executor, pending) end)
      assert_receive {:recover_entered, ^token, provider}
      Agent.update(authority, fn _old -> {:ok, rotated_identity()} end)
      send(provider, {:finish_recover, token})

      assert {:defer, :command_executor_rebind_required} = Task.await(task)
      assert Executor.identity(executor) == nil

      assert {:ok, old_store} = open_store(ctx)
      snapshot = Store.snapshot(old_store)
      assert snapshot.pending_intent.command_id == pending.command_id
      refute Map.has_key?(snapshot.outcomes, pending.command_id)
    end

    test "identity drift during a non-application lease cannot reject or ACK", ctx do
      pending = seed_pending_intent(ctx)
      {:ok, authority} = Agent.start_link(fn -> {:ok, durable_identity()} end)
      {:ok, script} = Agent.start_link(fn -> [:ambiguous, :not_applied] end)
      token = make_ref()
      provider_context = %{owner: self(), script: script, token: token}

      executor =
        start_executor(ctx,
          identity: fn -> Agent.get(authority, & &1) end,
          identity_refresh_ms: 10_000,
          device_id: nil,
          credential_epoch: nil,
          storage_epoch: nil,
          providers: %{noop: {SequencedBlockingRecoverProvider, provider_context}}
        )

      assert_receive {:startup_recovery_done, ^token}
      _state = :sys.get_state(executor)

      task = Task.async(fn -> Executor.deliver(executor, pending) end)
      assert_receive {:recovery_lease_entered, ^token, lease_holder}
      Agent.update(authority, fn _old -> {:ok, rotated_identity()} end)
      send(lease_holder, {:finish_recovery_lease, token})

      assert {:defer, :command_executor_rebind_required} = Task.await(task)
      assert Executor.identity(executor) == nil

      assert {:ok, old_store} = open_store(ctx)
      snapshot = Store.snapshot(old_store)
      assert snapshot.pending_intent.command_id == pending.command_id
      refute Map.has_key?(snapshot.outcomes, pending.command_id)
    end

    test "startup with a pending intent requires the exact verifier and fails closed without wiping", ctx do
      pending = seed_pending_intent(ctx)
      Process.flag(:trap_exit, true)

      opts =
        ctx
        |> executor_opts(providers: %{persist_checkpoints: {ScriptedProvider, ctx.script}})
        |> Keyword.put(:name, nil)

      assert {:error, {:missing_command_recovery_verifier, :noop}} = Executor.start_link(opts)

      # The durable intent survives a refused startup untouched.
      assert {:ok, reopened} = open_store(ctx)
      assert Store.pending_intent(reopened).command_id == pending.command_id
      assert File.exists?(ctx.path)
    end
  end

  describe "single-writer discipline" do
    test "the executor is the sole writer and reports its exact durable identity", ctx do
      executor = start_executor(ctx)

      assert Executor.identity(executor) == %{
               device_id: @device_id,
               credential_epoch: @credential_epoch,
               storage_epoch: @storage_epoch
             }

      # The store resolves symlinks, so the reported path is the canonical one
      # both this executor and a reopened store agree on.
      reported = Executor.path(executor)
      assert Path.type(reported) == :absolute
      assert Path.basename(reported) == Path.basename(ctx.path)
      assert {:ok, reopened} = open_store(ctx)
      assert reopened.path == reported
    end

    test "a process status dump never exposes payloads, results, or the ledger", ctx do
      executor = start_executor(ctx)
      secret_payload = payload(:noop)
      delivery = delivery(command_id: command_id(1), payload: secret_payload)
      assert {:ack, _ack} = Executor.deliver(executor, delivery)

      dumped = inspect(:sys.get_status(executor), limit: :infinity, printable_limit: :infinity)

      refute dumped =~ "noop"
      refute dumped =~ Path.basename(ctx.path)
      refute dumped =~ Base.encode16(secret_payload, case: :lower)
      assert dumped =~ "redacted"
      # The durable identity stays visible — it is not secret and is the only
      # useful thing in a crash report.
      assert dumped =~ "credential_epoch"
    end

    test "a delivery for another device identity is refused without an ACK", ctx do
      executor = start_executor(ctx)
      foreign = delivery(device_id: :binary.copy(<<0x4B>>, 16), command_id: command_id(1), payload: payload(:noop))

      assert {:defer, _reason} = Executor.deliver(executor, foreign)
      assert ScriptedProvider.observed(ctx.script) == []
    end
  end

  # --- helpers ---

  defp start_dynamic_executor(ctx, authority, overrides \\ []) do
    start_executor(
      ctx,
      Keyword.merge(
        [
          identity: fn -> Agent.get(authority, & &1) end,
          identity_refresh_ms: 10,
          device_id: nil,
          credential_epoch: nil,
          storage_epoch: nil
        ],
        overrides
      )
    )
  end

  defp durable_identity do
    %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch
    }
  end

  defp rotated_identity do
    %{
      durable_identity()
      | credential_epoch: @credential_epoch + 1,
        storage_epoch: @other_storage_epoch
    }
  end

  defp assert_eventually(predicate, attempts \\ 100)
  defp assert_eventually(predicate, 0), do: assert(predicate.())

  defp assert_eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(predicate, attempts - 1)
    end
  end

  defp disarmed_fault_at(stage) do
    {:ok, fault} = Agent.start_link(fn -> :disarmed end)

    injector = fn
      ^stage ->
        if Agent.get(fault, &(&1 == :armed)), do: {:error, :power_loss}, else: :ok

      _other ->
        :ok
    end

    {fault, injector}
  end

  defp disarmed_one_shot_fault_at(stage) do
    {:ok, fault} = Agent.start_link(fn -> :disarmed end)

    injector = fn
      ^stage ->
        Agent.get_and_update(fault, fn
          :armed -> {{:error, :power_loss}, :disarmed}
          :disarmed -> {:ok, :disarmed}
        end)

      _other ->
        :ok
    end

    {fault, injector}
  end

  defp arm_fault(fault), do: Agent.update(fault, fn _state -> :armed end)
  defp disarm_fault(fault), do: Agent.update(fault, fn _state -> :disarmed end)

  defp start_executor(ctx, overrides \\ []) do
    start_supervised!({Executor, Keyword.put(executor_opts(ctx, overrides), :name, nil)})
  end

  defp executor_opts(ctx, overrides) do
    binding = %{
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      generation: @generation,
      manifest_hash: @manifest_hash
    }

    Keyword.merge(
      [
        path: ctx.path,
        device_id: @device_id,
        credential_epoch: @credential_epoch,
        storage_epoch: @storage_epoch,
        max_outcomes: 16,
        max_result_bytes: 4_096,
        providers: %{
          noop: {ScriptedProvider, ctx.script},
          persist_checkpoints: {ScriptedProvider, ctx.script},
          sync_checkpoints: {ScriptedProvider, ctx.script},
          validate_firmware: {ScriptedProvider, ctx.script}
        },
        desired_state: fn ->
          {:ok, %{generation: @generation, manifest_hash: @manifest_hash, credential_epoch: @credential_epoch}}
        end,
        gate: fn -> {:open, binding} end,
        trusted_now_ms: fn -> {:ok, @now_ms} end
      ],
      overrides
    )
  end

  defmodule PermissiveAdmissionAuthority do
    def authorize(_plan, _snapshot, _limits, _context), do: :ok
  end

  defp open_store(ctx) do
    Store.open(ctx.path,
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      max_outcomes: 16,
      max_result_bytes: 4_096,
      admission_authority: {PermissiveAdmissionAuthority, nil},
      recovery_verifiers: %{
        noop: {ScriptedProvider, ctx.script},
        persist_checkpoints: {ScriptedProvider, ctx.script},
        sync_checkpoints: {ScriptedProvider, ctx.script},
        validate_firmware: {ScriptedProvider, ctx.script}
      }
    )
  end

  # Leave a durable pending intent behind exactly as an interrupted execution would.
  defp seed_pending_intent(ctx) do
    command = delivery(command_id: command_id(1), payload: payload(:noop))
    assert {:ok, store} = open_store(ctx)

    assert {:ok, _intent, _store} = Store.begin_intent(store, execution_plan(command))

    command
  end

  defp seed_applied_outcome(ctx) do
    command = delivery(command_id: command_id(1), payload: payload(:noop))
    assert {:ok, store} = open_store(ctx)
    assert {:ok, _intent, store} = Store.begin_intent(store, execution_plan(command))
    {:ok, result} = Canonical.encode(%{"outcome" => "applied"})
    assert {:ok, _ack, _store} = Store.complete_intent(store, result)
    command
  end

  defp execution_plan(command) do
    %{
      action: :execute,
      delivery: command,
      command_type: :noop,
      reserved_result_bytes: 256,
      reset_epoch?: false
    }
  end

  defp payload(type, args \\ %{}) do
    {:ok, bytes} = Canonical.encode(%{"type" => Atom.to_string(type), "args" => args})
    bytes
  end

  defp delivery(overrides) do
    body = Keyword.get(overrides, :payload, "command")
    payload_hash = :crypto.hash(:sha256, body)

    attrs = %{
      device_id: Keyword.get(overrides, :device_id, @device_id),
      credential_epoch: Keyword.get(overrides, :credential_epoch, @credential_epoch),
      storage_epoch: Keyword.get(overrides, :storage_epoch, @storage_epoch),
      required_generation: Keyword.get(overrides, :required_generation, @generation),
      required_manifest_hash: Keyword.get(overrides, :required_manifest_hash, @manifest_hash),
      command_epoch: Keyword.get(overrides, :command_epoch, 0),
      command_sequence: Keyword.get(overrides, :command_sequence, 1),
      command_id: Keyword.get(overrides, :command_id, command_id(1)),
      expires_at_ms: Keyword.get(overrides, :expires_at_ms, 1_800_000_000_000),
      payload_hash: payload_hash
    }

    assert {:ok, command_hash} = Command.hash(attrs)
    attrs |> Map.put(:command_hash, command_hash) |> Map.put(:payload, body)
  end

  defp command_id(n), do: <<n::128>>
end
