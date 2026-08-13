defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.CoordinatorTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.{Coordinator, RuntimeRegistry}

  @device_id <<1::128>>
  @storage_epoch <<2::128>>
  @origin_storage_epoch <<3::128>>
  @session_id <<4::128>>
  @transaction_id <<5::128>>
  @content "canonical-runtime"

  @binding %{
    device_id: @device_id,
    credential_epoch: 7,
    storage_epoch: @storage_epoch,
    generation: 11,
    manifest_hash: <<6::256>>
  }

  defmodule Backend do
    def start(owner, overrides \\ %{}) do
      state =
        Map.merge(
          %{
            owner: owner,
            operations: [],
            responses: %{},
            journal: nil,
            active: nil,
            identity: nil,
            session: nil,
            manager_blocked?: false,
            manager_finished?: false,
            installed_binding: nil,
            installed_token: nil,
            restored: []
          },
          overrides
        )

      {:ok, pid} = Agent.start_link(fn -> state end)
      :persistent_term.put(__MODULE__, pid)
      pid
    end

    def stop do
      case :persistent_term.get(__MODULE__, nil) do
        pid when is_pid(pid) ->
          :persistent_term.erase(__MODULE__)
          if Process.alive?(pid), do: Agent.stop(pid)

        _other ->
          :ok
      end
    end

    def operation(operation, payload \\ nil) do
      {owner, action} =
        Agent.get_and_update(agent(), fn state ->
          {action, responses} = pop_response(state.responses, operation)

          {{state.owner, action},
           %{state | operations: [{operation, payload} | state.operations], responses: responses}}
        end)

      send(owner, {:coordinator_operation, operation, payload, self()})
      action
    end

    def resolve(:default, _operation, default), do: default.()
    def resolve({:return, result}, _operation, _default), do: result

    def resolve({:put_and_return, key, value, result}, _operation, _default) do
      put(key, value)
      result
    end

    def resolve({:crash, reason}, _operation, _default), do: exit(reason)

    def resolve({:block, next}, operation, default) do
      send(data(:owner), {:coordinator_blocked, operation, self()})

      receive do
        {:continue_coordinator_operation, ^operation} -> resolve(next, operation, default)
      end
    end

    def data(key), do: Agent.get(agent(), &Map.fetch!(&1, key))
    def put(key, value), do: Agent.update(agent(), &Map.put(&1, key, value))
    def update(fun), do: Agent.update(agent(), fun)

    def operations do
      agent()
      |> Agent.get(& &1.operations)
      |> Enum.reverse()
    end

    def clear_operations, do: Agent.update(agent(), &%{&1 | operations: []})
    def respond(operation, action), do: Agent.update(agent(), &put_in(&1, [:responses, operation], action))

    defp agent, do: :persistent_term.get(__MODULE__)

    defp pop_response(responses, operation) do
      case Map.get(responses, operation, :default) do
        [next | rest] ->
          responses = if rest == [], do: Map.delete(responses, operation), else: Map.put(responses, operation, rest)
          {next, responses}

        action ->
          {action, Map.delete(responses, operation)}
      end
    end
  end

  defmodule FakeManager do
    alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.CoordinatorTest.Backend

    def whereis(_server), do: Backend.data(:manager_pid)

    def status(_server) do
      Backend.operation(:manager_status)
      |> Backend.resolve(:manager_status, fn ->
        if Process.alive?(Backend.data(:manager_pid)) do
          %{active: Backend.data(:active), identity: Backend.data(:identity)}
        else
          exit(:noproc)
        end
      end)
    end

    def begin_checkpoint_hydration(_server, token, binding) do
      action = Backend.operation(:manager_begin, %{token: token, binding: binding, coordinator: self()})

      default = fn ->
        Backend.update(fn state ->
          %{
            state
            | manager_blocked?: true,
              manager_finished?: false,
              installed_binding: binding,
              installed_token: token
          }
        end)

        :ok
      end

      case action do
        {:return_and_block, result} ->
          Backend.put(:manager_blocked?, true)
          result

        other ->
          Backend.resolve(other, :manager_begin, default)
      end
    end

    def finish_checkpoint_hydration(_server, token, binding) do
      action = Backend.operation(:manager_finish, %{token: token, binding: binding, coordinator: self()})

      Backend.resolve(action, :manager_finish, fn ->
        if token == Backend.data(:installed_token) and binding == Backend.data(:installed_binding) do
          Backend.update(&%{&1 | manager_blocked?: false, manager_finished?: true})
          :ok
        else
          {:error, :checkpoint_hydration_token_mismatch}
        end
      end)
    end
  end

  defmodule FakeSessionHolder do
    alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.CoordinatorTest.Backend

    def with_session(_server, generation, fun) do
      Backend.operation(:session_with, generation)
      |> Backend.resolve(:session_with, fn ->
        session = Backend.data(:session)

        if session.generation == generation do
          result = fun.(session)

          Backend.update(fn state ->
            Map.update(state, :session_callback_results, [result], &[result | &1])
          end)

          {:ok, result}
        else
          {:error, :stale_session}
        end
      end)
    end
  end

  defmodule FakeJournal do
    alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.CoordinatorTest.Backend

    def read(_path, _opts) do
      Backend.operation(:journal_read)
      |> Backend.resolve(:journal_read, fn ->
        case Backend.data(:journal) do
          nil -> :empty
          record -> {:ok, record}
        end
      end)
    end

    def write(_path, record, _opts) do
      operation = if record.phase == :prepared, do: :journal_write_prepared, else: :journal_write_head_committed
      action = Backend.operation(operation, record)

      case action do
        {:write_and_return, result} ->
          Backend.put(:journal, record)
          result

        other ->
          Backend.resolve(other, operation, fn ->
            Backend.put(:journal, record)
            :ok
          end)
      end
    end

    def remove(_path, _opts) do
      action = Backend.operation(:journal_remove)

      case action do
        {:delete_and_return, result} ->
          Backend.put(:journal, nil)
          result

        other ->
          Backend.resolve(other, :journal_remove, fn ->
            Backend.put(:journal, nil)
            :ok
          end)
      end
    end
  end

  defmodule FakeStore do
    alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.CoordinatorTest.Backend

    def observe_target_head(_store, kind) do
      Backend.operation(:store_observe, kind)
      |> Backend.resolve(:store_observe, fn ->
        {:ok, %{state: :absent, checkpoint_hash: Record.genesis_parent()}}
      end)
    end

    def hydrate(_store, attrs, expected_head) do
      result =
        Backend.operation(:store_hydrate, %{attrs: attrs, expected_head: expected_head})
        |> Backend.resolve(:store_hydrate, fn -> {:ok, selected_record(attrs)} end)

      case result do
        {:ok, record} ->
          Backend.put(:head, record)
          result

        _other ->
          result
      end
    end

    def head(_store, kind) do
      Backend.operation(:store_head, kind)
      |> Backend.resolve(:store_head, fn ->
        case Backend.data(:head) do
          nil -> :empty
          record -> {:ok, record}
        end
      end)
    end

    defp selected_record(attrs) do
      %{
        device_id: attrs.device_id,
        local_credential_epoch: attrs.credential_epoch,
        local_storage_epoch: attrs.storage_epoch,
        origin_credential_epoch: attrs.origin_credential_epoch,
        origin_storage_epoch: attrs.origin_storage_epoch,
        sequence: attrs.sequence,
        kind: attrs.kind,
        schema_version: attrs.schema_version,
        source_generation: attrs.source_generation,
        parent_hash: attrs.parent_hash,
        content: attrs.content,
        content_hash: :crypto.hash(:sha256, attrs.content),
        checkpoint_hash: attrs.checkpoint_hash,
        binding_hash: :crypto.hash(:sha256, "fake-binding"),
        accepted: true
      }
    end
  end

  defmodule FakeRecord do
    def verify(_record), do: :ok
  end

  defmodule FakeCheckpoint do
    alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.CoordinatorTest.Backend

    def decode_canonical_content(kind, schema_version, content) do
      Backend.operation(:checkpoint_decode, %{kind: kind, schema_version: schema_version, content: content})
      |> Backend.resolve(:checkpoint_decode, fn -> {:ok, %{content: content}} end)
    end

    def content_hash(_kind, _schema_version, content), do: {:ok, :crypto.hash(:sha256, content)}
    def validate_authority(_kind, _schema_version, _content, _target), do: :ok

    def hash(attrs),
      do: {:ok, :crypto.hash(:sha256, :erlang.term_to_binary(attrs, [:deterministic]))}
  end

  defmodule FakeAdapter do
    alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.CoordinatorTest.Backend

    def hydrate(wire) do
      Backend.operation(:adapter_hydrate, wire)
      |> Backend.resolve(:adapter_hydrate, fn -> {:ok, %{runtime: wire}} end)
    end
  end

  defmodule FakeRestorer do
    alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.CoordinatorTest.Backend

    def restore(snapshot) do
      Backend.operation(:runtime_restore, snapshot)
      |> Backend.resolve(:runtime_restore, fn ->
        Backend.update(&%{&1 | restored: [snapshot | &1.restored]})
        :ok
      end)
    end
  end

  setup do
    content_hash = :crypto.hash(:sha256, @content)

    base_hash_attrs = %{
      device_id: @device_id,
      credential_epoch: 3,
      storage_epoch: @origin_storage_epoch,
      sequence: 9,
      kind: :calibration,
      schema_version: 2,
      source_generation: 88,
      parent_hash: Record.genesis_parent(),
      content_hash: content_hash
    }

    {:ok, checkpoint_hash} = FakeCheckpoint.hash(base_hash_attrs)

    hydration = %{
      device_id: @device_id,
      credential_epoch: 7,
      storage_epoch: @storage_epoch,
      origin_credential_epoch: 3,
      origin_storage_epoch: @origin_storage_epoch,
      sequence: 9,
      kind: :calibration,
      schema_version: 2,
      source_generation: 88,
      parent_hash: Record.genesis_parent(),
      content_hash: content_hash,
      checkpoint_hash: checkpoint_hash,
      content: @content
    }

    identity = %{
      device_id: @device_id,
      credential_epoch: 7,
      storage_epoch: @storage_epoch,
      boot_id: <<7::128>>
    }

    session = %{
      generation: 42,
      session_id: @session_id,
      credential_epoch: 7
    }

    manager_pid = spawn(fn -> Process.sleep(:infinity) end)

    Backend.start(self(), %{
      active: @binding,
      identity: identity,
      session: session,
      manager_pid: manager_pid
    })

    on_exit(fn ->
      if Process.alive?(manager_pid), do: Process.exit(manager_pid, :kill)
      Backend.stop()
    end)

    {:ok, registry} = RuntimeRegistry.new([{:calibration, 2, FakeAdapter}])

    %{hydration: hydration, registry: registry, identity: identity, session: session}
  end

  test "production empty-journal startup restores current exact heads before releasing the barrier", ctx do
    selected = selected_record(ctx.hydration, content: "startup-current-runtime", sequence: 10)
    Backend.put(:head, selected)

    pid = start_coordinator(ctx, reconcile_empty_journal: true)

    assert Coordinator.status(pid) == %{blocked?: false, phase: nil, recovery_error: nil}
    assert Backend.data(:restored) == [%{runtime: %{content: selected.content}}]
    assert Backend.data(:manager_finished?)
    assert :manager_begin in core_operations()
    assert :store_head in core_operations()
  end

  test "empty-journal head changes before finish retain the startup blocker", ctx do
    selected = selected_record(ctx.hydration, content: "startup-current-runtime", sequence: 10)

    advanced =
      selected_record(ctx.hydration,
        content: "startup-advanced-runtime",
        sequence: 11,
        parent_hash: selected.checkpoint_hash
      )

    Backend.put(:head, selected)
    Backend.respond(:store_head, [{:return, {:ok, selected}}, {:return, {:ok, advanced}}])

    pid = start_coordinator(ctx, reconcile_empty_journal: true)

    assert %{
             blocked?: true,
             phase: nil,
             recovery_error: :checkpoint_hydration_head_changed
           } = Coordinator.status(pid)

    assert Backend.data(:manager_blocked?)
    refute Backend.data(:manager_finished?)

    assert :ok = Coordinator.recover(pid)
    assert Coordinator.status(pid) == %{blocked?: false, phase: nil, recovery_error: nil}
    assert Backend.data(:manager_finished?)
  end

  test "an unreadable journal claims the startup barrier and refuses fresh hydration", ctx do
    selected = selected_record(ctx.hydration, content: "startup-current-runtime", sequence: 10)
    Backend.put(:head, selected)

    Backend.respond(
      :journal_read,
      {:return, {:error, :corrupt_checkpoint_hydration_journal}}
    )

    pid = start_coordinator(ctx, reconcile_empty_journal: true)

    assert %{
             blocked?: true,
             phase: nil,
             recovery_error: :checkpoint_hydration_recovery_required
           } = Coordinator.status(pid)

    assert Backend.data(:manager_blocked?)
    refute Backend.data(:manager_finished?)
    assert Backend.data(:restored) == []

    assert {:error, :checkpoint_hydration_recovery_required} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    refute Backend.data(:manager_finished?)
    assert Backend.data(:journal) == nil

    assert :ok = Coordinator.recover(pid)
    assert Coordinator.status(pid) == %{blocked?: false, phase: nil, recovery_error: nil}
    assert Backend.data(:restored) == [%{runtime: %{content: selected.content}}]
    assert Backend.data(:manager_finished?)
  end

  test "journal read failures expose one bounded recovery category", ctx do
    Backend.respond(
      :journal_read,
      [
        {:return, {:error, {:checkpoint_hydration_journal_io, :eacces}}},
        {:return, {:error, :corrupt_checkpoint_hydration_journal}}
      ]
    )

    pid = start_coordinator(ctx, reconcile_empty_journal: true)

    assert %{
             blocked?: true,
             phase: nil,
             recovery_error: :checkpoint_hydration_recovery_required
           } = Coordinator.status(pid)

    assert Backend.data(:manager_blocked?)
    refute Backend.data(:manager_finished?)

    assert {:error, :checkpoint_hydration_recovery_required} = Coordinator.recover(pid)

    assert %{
             blocked?: true,
             phase: nil,
             recovery_error: :checkpoint_hydration_recovery_required
           } = Coordinator.status(pid)

    refute Backend.data(:manager_finished?)
  end

  test "fresh hydration follows the crash-safe order and binds the session and transaction", ctx do
    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:ok, :hydrated} = Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert core_operations() == [
             :session_with,
             :manager_status,
             :checkpoint_decode,
             :adapter_hydrate,
             :session_with,
             :manager_begin,
             :session_with,
             :manager_status,
             :store_observe,
             :journal_write_prepared,
             :session_with,
             :manager_status,
             :store_hydrate,
             :journal_write_head_committed,
             :checkpoint_decode,
             :adapter_hydrate,
             :session_with,
             :manager_status,
             :runtime_restore,
             :store_head,
             :session_with,
             :manager_status,
             :journal_remove,
             :session_with,
             :store_head,
             :session_with,
             :manager_status,
             :manager_finish
           ]

    writes =
      Backend.operations()
      |> Enum.filter(fn {operation, _payload} ->
        operation in [:journal_write_prepared, :journal_write_head_committed]
      end)
      |> Enum.map(&elem(&1, 1))

    assert [%{phase: :prepared} = prepared, %{phase: :head_committed} = committed] = writes
    assert prepared.transaction_id == @transaction_id
    assert prepared.session_incarnation == @session_id
    assert prepared.session_generation == ctx.session.generation
    assert prepared.version == 2
    assert prepared.target == @binding
    assert Map.delete(prepared, :phase) == Map.delete(committed, :phase)
    assert Backend.data(:journal) == nil
    assert Backend.data(:manager_finished?)
  end

  test "restores the exact Store-selected descendant instead of the delivered ancestor", ctx do
    selected = selected_record(ctx.hydration, content: "newer-canonical-runtime", sequence: 10)
    Backend.respond(:store_hydrate, {:return, {:ok, selected}})

    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:ok, :hydrated} = Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert Backend.data(:restored) == [%{runtime: %{content: selected.content}}]

    assert Backend.operations()
           |> Enum.filter(&match?({:checkpoint_decode, _payload}, &1))
           |> Enum.map(fn {_operation, payload} -> payload.content end) == [
             ctx.hydration.content,
             selected.content
           ]
  end

  test "head-committed recovery restores the actual current Store head", ctx do
    selected = selected_record(ctx.hydration, content: "recovered-newer-runtime", sequence: 10)
    Backend.put(:journal, journal_record(ctx.hydration, :head_committed))
    Backend.put(:head, selected)

    pid = start_coordinator(ctx)

    assert Coordinator.status(pid) == %{blocked?: false, phase: nil, recovery_error: nil}
    assert Backend.data(:restored) == [%{runtime: %{content: selected.content}}]
    assert Backend.data(:journal) == nil
    assert Backend.data(:manager_finished?)
  end

  test "head advancement before cleanup recreates evidence and remains blocked", ctx do
    selected = selected_record(ctx.hydration, content: "selected-runtime", sequence: 10)

    advanced =
      selected_record(ctx.hydration,
        content: "advanced-runtime",
        sequence: 11,
        parent_hash: selected.checkpoint_hash
      )

    Backend.respond(:store_hydrate, {:return, {:ok, selected}})
    Backend.respond(:store_head, [{:return, {:ok, advanced}}])

    pid = start_coordinator(ctx)

    assert {:error, :checkpoint_hydration_head_changed} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert Backend.data(:restored) == [%{runtime: %{content: selected.content}}]
    assert %{phase: :head_committed} = Backend.data(:journal)
    assert %{blocked?: true, phase: :head_committed} = Coordinator.status(pid)
    refute :journal_remove in core_operations()
    refute :manager_finish in core_operations()
  end

  test "head advancement immediately before finish recreates evidence and remains blocked", ctx do
    selected = selected_record(ctx.hydration, content: "selected-runtime", sequence: 10)

    advanced =
      selected_record(ctx.hydration,
        content: "advanced-runtime",
        sequence: 11,
        parent_hash: selected.checkpoint_hash
      )

    Backend.respond(:store_hydrate, {:return, {:ok, selected}})
    Backend.respond(:store_head, [{:return, {:ok, selected}}, {:return, {:ok, advanced}}])

    pid = start_coordinator(ctx)

    assert {:error, :checkpoint_hydration_head_changed} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert Backend.data(:restored) == [%{runtime: %{content: selected.content}}]
    assert %{phase: :head_committed} = Backend.data(:journal)
    assert %{blocked?: true, phase: :head_committed} = Coordinator.status(pid)
    assert :journal_remove in core_operations()
    refute :manager_finish in core_operations()
  end

  test "a selected Store head with the wrong local identity remains blocked", ctx do
    selected =
      ctx.hydration
      |> selected_record(content: "wrong-target-runtime", sequence: 10)
      |> Map.put(:local_storage_epoch, <<99::128>>)

    Backend.respond(:store_hydrate, {:return, {:ok, selected}})

    pid = start_coordinator(ctx)

    assert {:error, :checkpoint_hydration_selected_head_mismatch} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert %{blocked?: true, phase: :head_committed} = Coordinator.status(pid)
    assert %{phase: :head_committed} = Backend.data(:journal)
    assert Backend.data(:restored) == []
    refute Backend.data(:manager_finished?)
  end

  test "unsupported runtime schema and durable identity mismatch fail before mutation", ctx do
    pid = start_coordinator(ctx)
    Backend.clear_operations()

    legacy = %{ctx.hydration | schema_version: 1}

    assert {:error, :unsupported_checkpoint_runtime_schema} =
             Coordinator.hydrate(pid, ctx.session.generation, legacy)

    refute :manager_begin in core_operations()
    refute :journal_write_prepared in core_operations()

    Backend.clear_operations()
    drifted = %{ctx.hydration | storage_epoch: <<99::128>>}

    assert {:error, :checkpoint_hydration_target_mismatch} =
             Coordinator.hydrate(pid, ctx.session.generation, drifted)

    refute :manager_begin in core_operations()
    refute :checkpoint_decode in core_operations()
  end

  test "desired-state generation and manifest drift fence every fresh hydration effect", ctx do
    stages = [
      {:before_prepared, :store_observe, nil},
      {:before_head, :store_hydrate, :prepared},
      {:before_restore, :runtime_restore, :head_committed},
      {:before_remove, :journal_remove, :head_committed},
      {:before_finish, :manager_finish, :head_committed}
    ]

    for {field, value} <- [
          {:generation, @binding.generation + 1},
          {:manifest_hash, <<77::256>>}
        ],
        {stage, fenced_effect, expected_journal_phase} <- stages do
      drifted_binding = Map.put(@binding, field, value)

      Backend.respond(
        {:boundary, stage},
        {:put_and_return, :active, drifted_binding, :ok}
      )

      pid = start_coordinator(ctx)
      Backend.clear_operations()

      assert {:error, :checkpoint_hydration_binding_mismatch} =
               Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

      refute fenced_effect in core_operations()
      refute Backend.data(:manager_finished?)

      case expected_journal_phase do
        nil -> assert Backend.data(:journal) == nil
        phase -> assert %{phase: ^phase} = Backend.data(:journal)
      end

      stop_coordinator(pid)
      restart_backend(ctx)
    end
  end

  test "fresh hydration releases each session lease before checkpoint effects", ctx do
    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:ok, :hydrated} = Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert Backend.data(:session_callback_results)
           |> Enum.reverse()
           |> Enum.all?(&match?({:checkpoint_hydration_authorization, _authorization}, &1))
  end

  test "durable recovery does not require the historical session to remain live", ctx do
    Backend.put(:journal, journal_record(ctx.hydration, :head_committed))
    Backend.put(:head, selected_record(ctx.hydration, content: ctx.hydration.content, sequence: 9))
    Backend.put(:session, %{ctx.session | session_id: <<55::128>>, generation: 99})

    pid = start_coordinator(ctx)

    assert Coordinator.status(pid) == %{blocked?: false, phase: nil, recovery_error: nil}
    assert Backend.data(:journal) == nil
    assert Backend.data(:manager_finished?)
    refute :session_with in core_operations()
  end

  test "session drift before Manager begin prevents all durable effects", ctx do
    drifted = %{ctx.session | session_id: <<43::128>>, generation: ctx.session.generation + 1}

    Backend.respond(
      :checkpoint_decode,
      {:put_and_return, :session, drifted, {:ok, %{content: ctx.hydration.content}}}
    )

    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:error, :stale_session} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    refute Backend.data(:manager_blocked?)
    assert Backend.data(:journal) == nil
    refute :manager_begin in core_operations()
    refute :store_observe in core_operations()
    refute :runtime_restore in core_operations()
  end

  test "session drift before a fresh head effect remains blocked without touching the Store", ctx do
    drifted = %{ctx.session | session_id: <<44::128>>, generation: ctx.session.generation + 1}

    Backend.respond(
      {:boundary, :after_prepared},
      {:put_and_return, :session, drifted, :ok}
    )

    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:error, :stale_session} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert %{phase: :prepared} = Backend.data(:journal)
    assert Backend.data(:manager_blocked?)
    refute :store_hydrate in core_operations()
    refute :runtime_restore in core_operations()
    refute :manager_finish in core_operations()
  end

  test "session drift before fresh runtime restore retains committed evidence", ctx do
    drifted = %{ctx.session | session_id: <<45::128>>, generation: ctx.session.generation + 1}

    Backend.respond(
      {:boundary, :after_head_committed},
      {:put_and_return, :session, drifted, :ok}
    )

    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:error, :stale_session} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert %{phase: :head_committed} = Backend.data(:journal)
    assert Backend.data(:manager_blocked?)
    refute :runtime_restore in core_operations()
    refute :journal_remove in core_operations()
    refute :manager_finish in core_operations()
  end

  test "session drift immediately before cleanup retains committed evidence", ctx do
    drifted = %{ctx.session | session_id: <<46::128>>, generation: ctx.session.generation + 1}

    Backend.respond(
      {:boundary, :before_remove},
      {:put_and_return, :session, drifted, :ok}
    )

    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:error, :stale_session} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert Backend.data(:restored) == [%{runtime: %{content: ctx.hydration.content}}]
    assert %{phase: :head_committed} = Backend.data(:journal)
    assert Backend.data(:manager_blocked?)
    refute :journal_remove in core_operations()
    refute :manager_finish in core_operations()
  end

  test "session drift after cleanup recreates committed evidence before finish", ctx do
    drifted = %{ctx.session | session_id: <<47::128>>, generation: ctx.session.generation + 1}

    Backend.respond(
      {:boundary, :after_remove},
      {:put_and_return, :session, drifted, :ok}
    )

    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:error, :stale_session} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert Backend.data(:restored) == [%{runtime: %{content: ctx.hydration.content}}]
    assert %{phase: :head_committed} = Backend.data(:journal)
    assert Backend.data(:manager_blocked?)
    assert :journal_remove in core_operations()
    refute :manager_finish in core_operations()
  end

  test "session drift immediately before finish recreates committed evidence", ctx do
    drifted = %{ctx.session | session_id: <<48::128>>, generation: ctx.session.generation + 1}

    Backend.respond(
      {:boundary, :before_finish},
      {:put_and_return, :session, drifted, :ok}
    )

    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:error, :stale_session} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert Backend.data(:restored) == [%{runtime: %{content: ctx.hydration.content}}]
    assert %{phase: :head_committed} = Backend.data(:journal)
    assert Backend.data(:manager_blocked?)
    assert :journal_remove in core_operations()
    assert Enum.count(core_operations(), &(&1 == :store_head)) == 2
    refute :manager_finish in core_operations()
  end

  test "a binding race is rejected by Manager without creating a journal", ctx do
    pid = start_coordinator(ctx)
    Backend.clear_operations()

    Backend.respond(
      :manager_begin,
      {:return_and_block, {:error, :checkpoint_hydration_binding_mismatch}}
    )

    assert {:error, :checkpoint_hydration_binding_mismatch} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert Backend.data(:manager_blocked?)
    assert Backend.data(:journal) == nil
    refute :store_observe in core_operations()
    refute :manager_finish in core_operations()
  end

  test "invalid transaction IDs never reach the Manager and a generated zero is retried", ctx do
    generator = Agent.start_link(fn -> [<<0::128>>, @transaction_id] end) |> elem(1)

    transaction_id = fn ->
      Agent.get_and_update(generator, fn [next | rest] -> {next, rest} end)
    end

    pid = start_coordinator(ctx, transaction_id: transaction_id)
    Backend.clear_operations()

    assert {:ok, :hydrated} = Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert {_operation, %{transaction_id: @transaction_id}} =
             Enum.find(Backend.operations(), &match?({:journal_write_prepared, _}, &1))
  end

  test "operation faults retain the last durable phase and never finish the gate", ctx do
    cases = [
      {:journal_write_prepared, {:error, {:pre_rename, :power_loss}}, nil},
      {:store_hydrate, {:error, :expected_target_head_mismatch}, :prepared},
      {:journal_write_head_committed, {:error, {:pre_rename, :power_loss}}, :prepared},
      {:runtime_restore, {:error, :restore_conflict}, :head_committed},
      {:journal_remove, {:error, {:durability_uncertain, :directory_sync}}, :head_committed}
    ]

    for {operation, result, expected_phase} <- cases do
      restart_backend(ctx, %{responses: %{operation => {:return, result}}})

      pid = start_coordinator(ctx)
      Backend.clear_operations()

      assert {:error, _reason} = Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)
      assert Backend.data(:manager_blocked?)
      refute :manager_finish in core_operations()

      case expected_phase do
        nil -> assert Backend.data(:journal) == nil
        phase -> assert %{phase: ^phase} = Backend.data(:journal)
      end

      stop_coordinator(pid)
    end
  end

  test "Manager begin immediately installs the in-memory blocker before journal work", ctx do
    Backend.respond({:boundary, :after_begin}, {:return, {:error, :after_begin_fault}})

    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:error, :after_begin_fault} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert %{blocked?: true, phase: :prepared} = Coordinator.status(pid)
    assert Backend.data(:manager_blocked?)
    assert Backend.data(:journal) == nil
    refute :store_observe in core_operations()
  end

  test "a prepared boundary failure retains the observed head in process state", ctx do
    Backend.respond({:boundary, :after_prepared}, {:return, {:error, :after_prepared_fault}})

    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:error, :after_prepared_fault} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert :sys.get_state(pid).blocker.record.expected_head == %{
             state: :absent,
             checkpoint_hash: Record.genesis_parent()
           }

    assert %{phase: :prepared} = Backend.data(:journal)
    assert Backend.data(:manager_blocked?)
    refute :store_hydrate in core_operations()
  end

  test "uncertain prepared journal write retains the durable prepared phase in memory", ctx do
    Backend.respond(
      :journal_write_prepared,
      {:write_and_return, {:error, {:durability_uncertain, :directory_sync}}}
    )

    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:error, {:durability_uncertain, :directory_sync}} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert %{phase: :prepared} = Backend.data(:journal)
    assert Coordinator.status(pid).phase == :prepared
    assert Backend.data(:manager_blocked?)
    refute :store_hydrate in core_operations()
    refute :manager_finish in core_operations()
  end

  test "uncertain head-committed journal write retains the durable committed phase in memory", ctx do
    Backend.respond(
      :journal_write_head_committed,
      {:write_and_return, {:error, {:durability_uncertain, :directory_sync}}}
    )

    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:error, {:durability_uncertain, :directory_sync}} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert %{phase: :head_committed} = Backend.data(:journal)
    assert Coordinator.status(pid).phase == :head_committed
    assert Backend.data(:manager_blocked?)
    refute :runtime_restore in core_operations()
    refute :manager_finish in core_operations()
  end

  test "recovery reconciles stale process phase from the durable transition identity", ctx do
    Backend.respond(
      :journal_write_head_committed,
      {:return, {:error, {:pre_rename, :power_loss}}}
    )

    Backend.respond(
      :journal_read,
      [
        {:return, :empty},
        {:return, {:error, :temporary_read_fault}}
      ]
    )

    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:error, {:pre_rename, :power_loss}} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert Coordinator.status(pid).phase == :head_committed
    assert %{phase: :prepared} = Backend.data(:journal)

    Backend.clear_operations()
    assert :ok = Coordinator.recover(pid)
    assert Backend.data(:journal) == nil
    assert Backend.data(:manager_finished?)
    assert :store_hydrate in core_operations()
    assert :runtime_restore in core_operations()
    assert :manager_finish in core_operations()
  end

  test "uncertain removal that lost the pathname recreates a head-committed journal", ctx do
    Backend.respond(
      :journal_remove,
      {:delete_and_return, {:error, {:durability_uncertain, :directory_sync}}}
    )

    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:error, {:durability_uncertain, :directory_sync}} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert %{phase: :head_committed} = Backend.data(:journal)
    assert Backend.data(:manager_blocked?)
    refute :manager_finish in core_operations()

    assert Enum.take(core_operations(), -3) == [
             :journal_read,
             :journal_write_prepared,
             :journal_write_head_committed
           ]
  end

  test "Manager finish failure recreates recovery evidence after cleanup", ctx do
    Backend.respond(
      :manager_finish,
      {:return, {:error, :checkpoint_hydration_binding_mismatch}}
    )

    pid = start_coordinator(ctx)
    Backend.clear_operations()

    assert {:error, :checkpoint_hydration_binding_mismatch} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert %{phase: :head_committed} = Backend.data(:journal)
    refute Backend.data(:manager_finished?)
  end

  test "boot replays prepared and head-committed journals idempotently after installing the blocker", ctx do
    for phase <- [:prepared, :head_committed] do
      restart_backend(ctx)
      Backend.put(:journal, journal_record(ctx.hydration, phase))

      if phase == :head_committed do
        Backend.put(:head, selected_record(ctx.hydration, content: ctx.hydration.content, sequence: 9))
      end

      pid = start_coordinator(ctx)

      operations = core_operations()
      assert operation_index(operations, :manager_begin) < operation_index(operations, :checkpoint_decode)
      assert operation_index(operations, :manager_begin) < operation_index(operations, :runtime_restore)
      assert Backend.data(:journal) == nil
      assert Backend.data(:manager_finished?)

      if phase == :prepared do
        assert :store_hydrate in operations
        assert :journal_write_head_committed in operations
      else
        refute :store_hydrate in operations
      end

      stop_coordinator(pid)
    end
  end

  test "boot blocker installation and replay complete synchronously before start_link returns", ctx do
    Backend.put(:journal, journal_record(ctx.hydration, :head_committed))
    Backend.put(:head, selected_record(ctx.hydration, content: ctx.hydration.content, sequence: 9))
    Backend.respond(:runtime_restore, {:block, :default})

    task =
      Task.async(fn ->
        Coordinator.start_link(coordinator_opts(ctx))
      end)

    assert_receive {:coordinator_operation, :manager_begin, _payload, coordinator}, 1_000
    assert_receive {:coordinator_blocked, :runtime_restore, ^coordinator}, 1_000
    refute Task.yield(task, 0)
    assert Backend.data(:manager_blocked?)

    send(coordinator, {:continue_coordinator_operation, :runtime_restore})
    assert {:ok, pid} = Task.await(task, 1_000)
    Process.unlink(pid)
    on_exit(fn -> stop_coordinator(pid) end)
    assert Backend.data(:manager_finished?)
  end

  test "recovery schema and identity failures retain the journal with the Manager blocked", ctx do
    legacy_record =
      ctx.hydration
      |> Map.put(:schema_version, 1)
      |> journal_record(:prepared)

    Backend.put(:journal, legacy_record)
    pid = start_coordinator(ctx)

    assert %{recovery_error: :unsupported_checkpoint_runtime_schema} = Coordinator.status(pid)
    assert Backend.data(:manager_blocked?)
    assert Backend.data(:journal) == legacy_record

    assert operation_index(core_operations(), :manager_begin) <
             operation_index(core_operations(), :checkpoint_decode, :not_found)

    stop_coordinator(pid)
    drifted_binding = %{@binding | storage_epoch: <<77::128>>}

    restart_backend(ctx, %{
      active: drifted_binding,
      identity: %{ctx.identity | storage_epoch: <<77::128>>},
      journal: journal_record(ctx.hydration, :prepared)
    })

    pid = start_coordinator(ctx)

    assert %{
             blocked?: true,
             recovery_error: :checkpoint_hydration_target_mismatch
           } = Coordinator.status(pid)

    assert Backend.data(:manager_blocked?)
    assert %{phase: :prepared} = Backend.data(:journal)
    refute :checkpoint_decode in core_operations()

    Backend.clear_operations()

    assert {:error, :checkpoint_hydration_target_mismatch} = Coordinator.recover(pid)
    refute :checkpoint_decode in core_operations()
    refute :runtime_restore in core_operations()
    refute :manager_finish in core_operations()
  end

  test "manager replacement reclaims committed recovery and retries automatically", ctx do
    record = journal_record(ctx.hydration, :head_committed)
    Backend.put(:journal, record)
    Backend.put(:head, selected_record(ctx.hydration, content: ctx.hydration.content, sequence: 9))
    Backend.respond(:runtime_restore, {:return, {:error, :restore_conflict}})

    pid = start_coordinator(ctx, manager_retry_ms: 10)

    assert %{blocked?: true, recovery_error: :restore_conflict} = Coordinator.status(pid)
    old_manager = Backend.data(:manager_pid)
    Process.exit(old_manager, :kill)
    Process.sleep(30)

    assert Process.alive?(pid)
    assert %{blocked?: true, phase: :head_committed} = Coordinator.status(pid)

    replacement = spawn(fn -> Process.sleep(:infinity) end)
    Backend.put(:manager_pid, replacement)
    Backend.put(:manager_blocked?, false)
    Backend.put(:installed_binding, nil)
    Backend.put(:installed_token, nil)

    eventually(fn ->
      assert Coordinator.status(pid) == %{blocked?: false, phase: nil, recovery_error: nil}
      assert Backend.data(:manager_finished?)
      assert Backend.data(:journal) == nil
      assert Backend.data(:installed_binding) == @binding
    end)
  end

  test "manager replacement reclaims a retained empty-journal blocker and retries automatically", ctx do
    selected = selected_record(ctx.hydration, content: "startup-current-runtime", sequence: 10)

    advanced =
      selected_record(ctx.hydration,
        content: "startup-advanced-runtime",
        sequence: 11,
        parent_hash: selected.checkpoint_hash
      )

    Backend.put(:head, selected)
    Backend.respond(:store_head, [{:return, {:ok, selected}}, {:return, {:ok, advanced}}])

    pid = start_coordinator(ctx, reconcile_empty_journal: true)

    assert %{
             blocked?: true,
             phase: nil,
             recovery_error: :checkpoint_hydration_head_changed
           } = Coordinator.status(pid)

    assert Backend.data(:manager_blocked?)
    refute Backend.data(:manager_finished?)
    assert Backend.data(:journal) == nil

    Backend.put(:head, advanced)
    old_manager = Backend.data(:manager_pid)
    Process.exit(old_manager, :kill)
    Process.sleep(30)

    assert Process.alive?(pid)

    replacement = spawn(fn -> Process.sleep(:infinity) end)
    Backend.put(:manager_pid, replacement)
    Backend.put(:manager_blocked?, false)
    Backend.put(:installed_binding, nil)
    Backend.put(:installed_token, nil)

    eventually(fn ->
      assert Coordinator.status(pid) == %{blocked?: false, phase: nil, recovery_error: nil}
      assert Backend.data(:manager_finished?)
      assert Backend.data(:installed_binding) == @binding

      assert Backend.data(:restored) == [
               %{runtime: %{content: advanced.content}},
               %{runtime: %{content: selected.content}}
             ]
    end)
  end

  test "failed restore can be replayed in place without releasing the gate", ctx do
    record = journal_record(ctx.hydration, :head_committed)
    Backend.put(:journal, record)
    Backend.put(:head, selected_record(ctx.hydration, content: ctx.hydration.content, sequence: 9))
    Backend.respond(:runtime_restore, {:return, {:error, :restore_conflict}})

    pid = start_coordinator(ctx)

    assert %{recovery_error: :restore_conflict} = Coordinator.status(pid)
    assert Backend.data(:journal) == record
    assert Backend.data(:manager_blocked?)
    refute Backend.data(:manager_finished?)

    Backend.clear_operations()
    assert :ok = Coordinator.recover(pid)
    assert Backend.data(:journal) == nil
    assert Backend.data(:manager_finished?)

    assert core_operations() == [
             :journal_read,
             :manager_status,
             :checkpoint_decode,
             :adapter_hydrate,
             :store_head,
             :checkpoint_decode,
             :adapter_hydrate,
             :manager_status,
             :runtime_restore,
             :store_head,
             :manager_status,
             :journal_remove,
             :store_head,
             :manager_status,
             :manager_finish
           ]
  end

  test "coordinator death at every boundary leaves replayable evidence and never finishes early", ctx do
    stages = [
      after_begin: nil,
      before_prepared: nil,
      after_prepared: :prepared,
      before_head: :prepared,
      after_head: :prepared,
      before_head_committed: :prepared,
      after_head_committed: :head_committed,
      before_restore: :head_committed,
      after_restore: :head_committed,
      before_remove: :head_committed,
      after_remove: nil,
      before_finish: nil
    ]

    for {stage, expected_phase} <- stages do
      restart_backend(ctx)
      Backend.respond({:boundary, stage}, {:crash, :kill})

      pid = start_coordinator(ctx)
      monitor = Process.monitor(pid)

      catch_exit(Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration))
      assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 1_000
      assert reason in [:kill, :killed]
      assert Backend.data(:manager_blocked?)
      refute Backend.data(:manager_finished?)

      case expected_phase do
        nil -> assert Backend.data(:journal) == nil
        phase -> assert %{phase: ^phase} = Backend.data(:journal)
      end
    end
  end

  test "finish is not attempted until exact restore and durable cleanup both return", ctx do
    Backend.respond(:runtime_restore, {:block, :default})
    Backend.respond(:journal_remove, {:block, :default})

    pid = start_coordinator(ctx)

    task =
      Task.async(fn ->
        Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)
      end)

    assert_receive {:coordinator_blocked, :runtime_restore, ^pid}, 1_000
    refute :journal_remove in core_operations()
    refute :manager_finish in core_operations()

    send(pid, {:continue_coordinator_operation, :runtime_restore})
    assert_receive {:coordinator_blocked, :journal_remove, ^pid}, 1_000
    refute :manager_finish in core_operations()

    send(pid, {:continue_coordinator_operation, :journal_remove})
    assert {:ok, :hydrated} = Task.await(task, 1_000)
    assert List.last(core_operations()) == :manager_finish
  end

  test "public and crash status omit transition secrets", ctx do
    Backend.respond({:boundary, :after_begin}, {:return, {:error, :after_begin_fault}})

    pid = start_coordinator(ctx)

    assert {:error, :after_begin_fault} =
             Coordinator.hydrate(pid, ctx.session.generation, ctx.hydration)

    assert %{blocked?: true, phase: :prepared, recovery_error: :after_begin_fault} =
             Coordinator.status(pid)

    refute Map.has_key?(Coordinator.status(pid), :transaction_id)

    formatted =
      Coordinator.format_status(%{
        state: %{
          journal_path: "/data/private-checkpoint-journal",
          blocker: %{
            token: make_ref(),
            binding: Map.put(@binding, :secret, "binding-secret"),
            record: %{
              phase: :head_committed,
              transaction_id: @transaction_id,
              session_incarnation: @session_id,
              hydration: %{
                content: "checkpoint-secret",
                content_hash: <<8::256>>,
                checkpoint_hash: <<9::256>>
              }
            }
          },
          recovery_error: {:journal_fault, "recovery-secret"}
        },
        message: {:hydrate, "message-secret"},
        reason: {:badmatch, "reason-secret"},
        log: [{:in, "log-secret"}]
      })

    assert formatted == %{
             state: %{
               blocked?: true,
               phase: :head_committed,
               recovery_error: :checkpoint_hydration_failed
             },
             message: :redacted,
             reason: :redacted,
             log: :redacted
           }

    rendered = formatted |> then(&:io_lib.format(~c"~0p", [&1])) |> IO.iodata_to_binary()

    for secret <- [
          "private-checkpoint-journal",
          "binding-secret",
          "checkpoint-secret",
          "recovery-secret",
          "message-secret",
          "reason-secret",
          "log-secret"
        ] do
      refute rendered =~ secret
    end

    refute rendered =~ Base.encode16(@transaction_id)
    refute rendered =~ Base.encode16(@session_id)
  end

  test "production registry is closed to the three exact runtime schemas" do
    registry = Coordinator.production_registry()

    assert {:ok, _adapter} = RuntimeRegistry.fetch(registry, :calibration, 2)
    assert {:ok, _adapter} = RuntimeRegistry.fetch(registry, :polar, 3)
    assert {:ok, _adapter} = RuntimeRegistry.fetch(registry, :wind_shift, 2)

    assert {:error, :unsupported_checkpoint_runtime_schema} =
             RuntimeRegistry.fetch(registry, :calibration, 1)

    assert {:error, :unsupported_checkpoint_runtime_schema} =
             RuntimeRegistry.fetch(registry, :polar, 2)

    assert {:error, :unsupported_checkpoint_runtime_schema} =
             RuntimeRegistry.fetch(registry, :wind_shift, 1)
  end

  defp restart_backend(ctx, overrides \\ %{}) do
    Backend.stop()

    manager_pid = spawn(fn -> Process.sleep(:infinity) end)

    Backend.start(
      self(),
      Map.merge(
        %{
          active: @binding,
          identity: ctx.identity,
          session: ctx.session,
          manager_pid: manager_pid
        },
        overrides
      )
    )

    manager_pid
  end

  defp start_coordinator(ctx, overrides \\ []) do
    {:ok, pid} = Coordinator.start_link(Keyword.merge(coordinator_opts(ctx), overrides))
    Process.unlink(pid)
    on_exit(fn -> stop_coordinator(pid) end)
    pid
  end

  defp stop_coordinator(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp coordinator_opts(ctx) do
    [
      name: nil,
      journal_path: "/unused/checkpoint-hydration.journal",
      head_store: :fake_store,
      manager: :fake_manager,
      session_holder: :fake_session_holder,
      registry: ctx.registry,
      restorers: %{calibration: {FakeRestorer, :restore}},
      transaction_id: fn -> @transaction_id end,
      journal_module: FakeJournal,
      store_module: FakeStore,
      manager_module: FakeManager,
      session_holder_module: FakeSessionHolder,
      manager_retry_ms: 10,
      checkpoint_module: FakeCheckpoint,
      record_module: FakeRecord,
      journal_opts: [],
      boundary: &boundary/1
    ]
  end

  defp boundary(stage) do
    Backend.operation({:boundary, stage})
    |> Backend.resolve({:boundary, stage}, fn -> :ok end)
  end

  defp selected_record(hydration, overrides) do
    content = Keyword.fetch!(overrides, :content)
    sequence = Keyword.fetch!(overrides, :sequence)
    parent_hash = Keyword.get(overrides, :parent_hash, hydration.checkpoint_hash)
    accepted = Keyword.get(overrides, :accepted, false)
    content_hash = :crypto.hash(:sha256, content)

    record = %{
      device_id: hydration.device_id,
      local_credential_epoch: hydration.credential_epoch,
      local_storage_epoch: hydration.storage_epoch,
      origin_credential_epoch: hydration.origin_credential_epoch,
      origin_storage_epoch: hydration.origin_storage_epoch,
      sequence: sequence,
      kind: hydration.kind,
      schema_version: hydration.schema_version,
      source_generation: hydration.source_generation + 1,
      parent_hash: parent_hash,
      content: content,
      content_hash: content_hash,
      checkpoint_hash:
        fake_hash(:checkpoint, [
          hydration.device_id,
          hydration.origin_credential_epoch,
          hydration.origin_storage_epoch,
          sequence,
          hydration.kind,
          hydration.schema_version,
          hydration.source_generation + 1,
          parent_hash,
          content_hash
        ]),
      accepted: accepted
    }

    Map.put(
      record,
      :binding_hash,
      fake_hash(:binding, [
        record.device_id,
        record.local_credential_epoch,
        record.local_storage_epoch,
        record.checkpoint_hash,
        record.accepted
      ])
    )
  end

  defp fake_hash(domain, values),
    do: :crypto.hash(:sha256, :erlang.term_to_binary({domain, values}, [:deterministic]))

  defp journal_record(hydration, phase) do
    %{
      version: 2,
      phase: phase,
      transaction_id: @transaction_id,
      session_incarnation: @session_id,
      session_generation: 42,
      target: @binding,
      expected_head: %{state: :absent, checkpoint_hash: Record.genesis_parent()},
      hydration: %{
        kind: hydration.kind,
        schema_version: hydration.schema_version,
        origin_credential_epoch: hydration.origin_credential_epoch,
        origin_storage_epoch: hydration.origin_storage_epoch,
        revision: hydration.sequence,
        source_generation: hydration.source_generation,
        parent_hash: hydration.parent_hash,
        content_hash: hydration.content_hash,
        checkpoint_hash: hydration.checkpoint_hash,
        content: hydration.content
      }
    }
  end

  defp core_operations do
    Backend.operations()
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&match?({:boundary, _stage}, &1))
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(fun, attempts - 1)
  end

  defp operation_index(operations, operation, default \\ 1_000_000) do
    Enum.find_index(operations, &(&1 == operation)) || default
  end
end
