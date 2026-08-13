defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointSubmission.SchedulerTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Observer, as: CalibrationObserver
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Store, as: HeadStore
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointSubmission.Payload
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointSubmission.Scheduler
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Entry
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.Calibration

  @moduletag :capture_log

  @device_id <<0xC1::128>>
  @storage_epoch <<0xC2::128>>
  @credential_epoch 7
  @identity %{
    device_id: @device_id,
    credential_epoch: @credential_epoch,
    storage_epoch: @storage_epoch
  }

  defmodule FakeOutbox do
    alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Entry

    def initial(identity), do: %{identity: identity, entries: [], sequence: 0, fail_next: nil}

    def fail_next(agent, reason), do: Agent.update(agent, &%{&1 | fail_next: reason})

    def entries(agent), do: Agent.get(agent, &Enum.reverse(&1.entries))

    def retire(agent, entry),
      do: Agent.update(agent, fn state -> %{state | entries: List.delete(state.entries, entry)} end)

    def pending(agent, opts) do
      stream = Keyword.get(opts, :stream)

      agent
      |> Agent.get(&Enum.reverse(&1.entries))
      |> Enum.filter(fn entry -> is_nil(stream) or entry.stream == stream end)
    end

    def enqueue_checkpoint(agent, builder) do
      case Agent.get_and_update(agent, fn state ->
             case state.fail_next do
               nil -> {{:ok, state.identity, state.sequence + 1}, %{state | sequence: state.sequence + 1}}
               reason -> {{:error, reason}, %{state | fail_next: nil}}
             end
           end) do
        {:error, reason} ->
          {:error, reason}

        {:ok, identity, sequence} ->
          case builder.(sequence) do
            {:ok, %{payload: payload, payload_hash: payload_hash}} ->
              entry = %Entry{
                stream: :checkpoint,
                device_id: identity.device_id,
                credential_epoch: identity.credential_epoch,
                storage_epoch: identity.storage_epoch,
                sequence: sequence,
                entry_id: <<sequence::128>>,
                payload_hash: payload_hash,
                payload_checksum: :crypto.hash(:sha256, payload),
                payload: payload,
                priority: 0,
                encoded_size: byte_size(payload) + 128,
                ordinal: sequence
              }

              Agent.update(agent, fn state -> %{state | entries: [entry | state.entries]} end)

              {:ok,
               %{
                 stream: :checkpoint,
                 device_id: identity.device_id,
                 credential_epoch: identity.credential_epoch,
                 storage_epoch: identity.storage_epoch,
                 sequence: sequence,
                 payload_hash: payload_hash,
                 cumulative_sequence: 0
               }}

            {:error, _reason} = error ->
              error
          end
      end
    end
  end

  setup do
    base = Path.join(System.tmp_dir!(), "checkpoint_scheduler_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    {:ok, head_store} =
      HeadStore.new(
        base_dir: base,
        device_id: @identity.device_id,
        credential_epoch: @identity.credential_epoch,
        storage_epoch: @identity.storage_epoch,
        identity: fn transition -> transition.(@identity) end,
        transition_timeout_ms: 30_000
      )

    outbox =
      start_supervised!(
        {Agent, fn -> FakeOutbox.initial(@identity) end},
        id: {:fake_outbox, System.unique_integer([:positive])}
      )

    observer =
      start_supervised!(
        {CalibrationObserver,
         name: nil,
         sample_ms: 0,
         dir: nil,
         calibration: nil,
         boat_identifier: "checkpoint-scheduler-boat",
         sender: fn _channel, _update -> :ok end,
         now_fn: fn -> 10_000 end,
         utc_now_fn: fn -> ~U[2026-08-13 12:00:00Z] end,
         sync_ms: 60_000,
         persist_ms: 60_000,
         legs: [min_duration_s: 30.0]},
        id: {:calibration_observer, System.unique_integer([:positive])}
      )

    generation_bump =
      start_supervised!(
        {Agent, fn -> 0 end},
        id: {:generation_bump, System.unique_integer([:positive])}
      )

    adapter = fn snapshot ->
      with {:ok, wire} <- Calibration.project(snapshot) do
        case Agent.get(generation_bump, & &1) do
          0 -> {:ok, wire}
          bump -> {:ok, update_in(wire, ["learner", "seq"], &(&1 + bump))}
        end
      end
    end

    scheduler_opts = [
      name: nil,
      sync_ms: 3_600_000,
      identity: fn -> {:ok, @identity} end,
      head_store: fn -> {:ok, head_store} end,
      outbox: outbox,
      outbox_module: FakeOutbox,
      sources: %{
        calibration: %{
          snapshot: fn -> CalibrationObserver.snapshot(observer) end,
          adapter: adapter
        }
      }
    ]

    scheduler =
      start_supervised!(
        {Scheduler, scheduler_opts},
        id: {:checkpoint_scheduler, System.unique_integer([:positive])}
      )

    %{
      base: base,
      head_store: head_store,
      outbox: outbox,
      observer: observer,
      generation_bump: generation_bump,
      scheduler: scheduler,
      scheduler_opts: scheduler_opts
    }
  end

  test "submits the current runtime when no accepted head exists", ctx do
    assert :ok = Scheduler.tick(ctx.scheduler)

    assert [entry] = FakeOutbox.entries(ctx.outbox)
    assert entry.stream == :checkpoint
    assert {:ok, submission} = Payload.decode(entry.payload)
    assert submission.kind == :calibration
    assert submission.schema_version == 2
    assert submission.device_id == @device_id
    assert submission.credential_epoch == @credential_epoch
    assert submission.storage_epoch == @storage_epoch
    assert submission.parent_hash == Record.genesis_parent()
    assert submission.checkpoint_hash == entry.payload_hash
  end

  test "skips resubmission while the previous submission is pending", ctx do
    assert :ok = Scheduler.tick(ctx.scheduler)
    assert :ok = Scheduler.tick(ctx.scheduler)
    assert [_only] = FakeOutbox.entries(ctx.outbox)
  end

  test "records the backend-accepted head and skips unchanged runtimes", ctx do
    assert :ok = Scheduler.tick(ctx.scheduler)
    assert [entry] = FakeOutbox.entries(ctx.outbox)
    FakeOutbox.retire(ctx.outbox, entry)

    assert :ok = Scheduler.record_accepted(ctx.scheduler, [entry])
    assert :ok = Scheduler.tick(ctx.scheduler)

    assert {:ok, head} = HeadStore.head(ctx.head_store, :calibration)
    assert head.checkpoint_hash == entry.payload_hash
    assert head.accepted

    assert :ok = Scheduler.tick(ctx.scheduler)
    assert FakeOutbox.entries(ctx.outbox) == []
  end

  test "submits a descendant bound to the accepted parent when the runtime advances", ctx do
    assert :ok = Scheduler.tick(ctx.scheduler)
    assert [first] = FakeOutbox.entries(ctx.outbox)
    FakeOutbox.retire(ctx.outbox, first)
    assert :ok = Scheduler.record_accepted(ctx.scheduler, [first])

    Agent.update(ctx.generation_bump, fn _bump -> 1 end)
    assert :ok = Scheduler.tick(ctx.scheduler)

    assert [second] = FakeOutbox.entries(ctx.outbox)
    assert {:ok, submission} = Payload.decode(second.payload)
    assert submission.parent_hash == first.payload_hash
    assert submission.sequence == 2

    {:ok, first_submission} = Payload.decode(first.payload)
    assert submission.source_generation == first_submission.source_generation + 1
  end

  test "identity unavailability skips the tick without submitting", ctx do
    opts = Keyword.put(ctx.scheduler_opts, :identity, fn -> {:error, :no_verified_authority} end)

    scheduler =
      start_supervised!(
        {Scheduler, opts},
        id: {:unavailable_identity_scheduler, System.unique_integer([:positive])}
      )

    assert :ok = Scheduler.tick(scheduler)
    assert FakeOutbox.entries(ctx.outbox) == []
  end

  test "enqueue failures are retried on the next tick", ctx do
    FakeOutbox.fail_next(ctx.outbox, {:backpressure, :entry_capacity})

    assert :ok = Scheduler.tick(ctx.scheduler)
    assert FakeOutbox.entries(ctx.outbox) == []
    assert Process.alive?(ctx.scheduler)

    assert :ok = Scheduler.tick(ctx.scheduler)
    assert [_entry] = FakeOutbox.entries(ctx.outbox)
  end

  test "non-checkpoint retirements never touch the head store", ctx do
    telemetry_entry = %Entry{
      stream: :telemetry,
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      sequence: 1,
      entry_id: <<1::128>>,
      payload_hash: :crypto.hash(:sha256, "telemetry"),
      payload_checksum: :crypto.hash(:sha256, "telemetry"),
      payload: "telemetry",
      priority: 0,
      encoded_size: 137,
      ordinal: 1
    }

    assert :ok = Scheduler.record_accepted(ctx.scheduler, [telemetry_entry])
    assert :ok = Scheduler.tick(ctx.scheduler)
    assert HeadStore.head(ctx.head_store, :calibration) == :empty
  end
end
