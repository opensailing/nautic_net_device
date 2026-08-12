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

  setup do
    root = Path.join(System.tmp_dir!(), "command_executor_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, script} = Agent.start_link(fn -> %{} end)
    %{root: root, path: Path.join(root, "commands.ledger"), script: script}
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

    test "an unusable trusted clock defers without touching the ledger", ctx do
      executor = start_executor(ctx, trusted_now_ms: fn -> :unavailable end)

      assert {:defer, :trusted_clock_unavailable} =
               Executor.deliver(executor, delivery(command_id: command_id(1), payload: payload(:noop)))

      assert ScriptedProvider.observed(ctx.script) == []
      assert {:ok, reopened} = open_store(ctx)
      assert Store.snapshot(reopened).next_expected_sequence == 1
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

    assert {:ok, _intent, _store} =
             Store.begin_intent(store, %{
               action: :execute,
               delivery: command,
               command_type: :noop,
               reserved_result_bytes: 256,
               reset_epoch?: false
             })

    command
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
