defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointSubmission.BuilderTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Observer
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointSubmission.Builder
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.Calibration
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Messages

  @capture_utc ~U[2026-08-13 12:00:00Z]
  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @accepted_parent Base.decode16!(
                     "7f5bd3f30711a6f43206750ee3d158019a211e341a0038b989ca4f9bf7dfb153",
                     case: :lower
                   )

  test "builds the exact runtime checkpoint under the locked sequence and admits it durably" do
    parent = self()
    snapshot = internal_snapshot()

    observer_snapshot = fn ->
      send(parent, :observer_snapshot)
      {:ok, snapshot}
    end

    runtime_adapter = fn presented ->
      send(parent, {:runtime_adapter, presented})
      Calibration.project(presented)
    end

    durable_identity = fn ->
      send(parent, :durable_identity)
      {:ok, durable_identity()}
    end

    accepted_parent = fn :calibration ->
      send(parent, :accepted_parent)
      {:ok, @accepted_parent}
    end

    enqueue_checkpoint = fn sequence_builder ->
      send(parent, :enqueue_checkpoint)
      assert {:ok, built} = sequence_builder.(41)
      send(parent, {:built_checkpoint, built})

      {:ok,
       %{
         stream: :checkpoint,
         sequence: 41,
         payload_hash: built.payload_hash,
         durable: true
       }}
    end

    assert {:ok, receipt} =
             Builder.submit(:calibration,
               observer_snapshot: observer_snapshot,
               runtime_adapter: runtime_adapter,
               durable_identity: durable_identity,
               accepted_parent: accepted_parent,
               enqueue_checkpoint: enqueue_checkpoint
             )

    assert receipt == %{
             stream: :checkpoint,
             sequence: 41,
             payload_hash: receipt.payload_hash,
             durable: true
           }

    assert_receive :enqueue_checkpoint
    assert_receive :observer_snapshot
    assert_receive {:runtime_adapter, ^snapshot}
    assert_receive :durable_identity
    assert_receive :accepted_parent
    assert_receive {:built_checkpoint, built}

    assert Map.keys(built) |> Enum.sort() == [:payload, :payload_hash]
    assert {:ok, submission} = Messages.decode(:checkpoint_submission, built.payload)

    assert submission.device_id == @device_id
    assert submission.credential_epoch == 7
    assert submission.storage_epoch == @storage_epoch
    assert submission.sequence == 41
    assert submission.kind == :calibration
    assert submission.schema_version == 2
    assert submission.source_generation == snapshot.learner["seq"]
    assert submission.parent_hash == @accepted_parent

    assert {:ok, projected} = Calibration.project(snapshot)
    assert {:ok, canonical_content} = Checkpoint.canonical_content(:calibration, 2, projected)
    assert submission.content == canonical_content
    assert {:ok, submission.content_hash} == Checkpoint.content_hash(:calibration, 2, canonical_content)

    hash_attrs = Map.take(submission, checkpoint_hash_keys())
    assert {:ok, submission.checkpoint_hash} == Checkpoint.hash(hash_attrs)
    assert submission.checkpoint_hash == built.payload_hash
    assert receipt.payload_hash == built.payload_hash
  end

  test "uses the checkpoint genesis parent when no accepted checkpoint exists" do
    snapshot = internal_snapshot()
    parent = self()

    enqueue_checkpoint = fn sequence_builder ->
      assert {:ok, built} = sequence_builder.(1)
      send(parent, {:built_checkpoint, built})
      {:ok, %{sequence: 1, payload_hash: built.payload_hash}}
    end

    assert {:ok, %{sequence: 1}} =
             Builder.submit(:calibration,
               observer_snapshot: fn -> {:ok, snapshot} end,
               runtime_adapter: Calibration,
               durable_identity: fn -> {:ok, durable_identity()} end,
               accepted_parent: fn :calibration -> :empty end,
               enqueue_checkpoint: enqueue_checkpoint
             )

    assert_receive {:built_checkpoint, built}
    assert {:ok, submission} = Messages.decode(:checkpoint_submission, built.payload)
    assert submission.parent_hash == Record.genesis_parent()
  end

  test "does not report acceptance when durable enqueue fails" do
    snapshot = internal_snapshot()
    parent = self()

    enqueue_checkpoint = fn sequence_builder ->
      assert {:ok, built} = sequence_builder.(9)
      send(parent, {:built_checkpoint, built})
      {:error, {:durability_uncertain, :sync}}
    end

    assert {:error, {:durability_uncertain, :sync}} =
             Builder.submit(:calibration,
               observer_snapshot: fn -> {:ok, snapshot} end,
               runtime_adapter: Calibration,
               durable_identity: fn -> {:ok, durable_identity()} end,
               accepted_parent: fn :calibration -> {:ok, @accepted_parent} end,
               enqueue_checkpoint: enqueue_checkpoint
             )

    assert_receive {:built_checkpoint, %{payload_hash: <<_::256>>}}
  end

  test "propagates observer, adapter, identity, parent, and sequence-source errors" do
    snapshot = internal_snapshot()

    cases = [
      {
        :observer_unavailable,
        [observer_snapshot: fn -> {:error, :observer_unavailable} end]
      },
      {
        :runtime_projection_failed,
        [runtime_adapter: fn _snapshot -> {:error, :runtime_projection_failed} end]
      },
      {
        :identity_unbound,
        [durable_identity: fn -> {:error, :identity_unbound} end]
      },
      {
        :accepted_parent_unavailable,
        [accepted_parent: fn :calibration -> {:error, :accepted_parent_unavailable} end]
      }
    ]

    for {reason, overrides} <- cases do
      enqueue_checkpoint = fn sequence_builder -> sequence_builder.(17) end

      assert {:error, ^reason} =
               Builder.submit(
                 :calibration,
                 Keyword.merge(
                   [
                     observer_snapshot: fn -> {:ok, snapshot} end,
                     runtime_adapter: Calibration,
                     durable_identity: fn -> {:ok, durable_identity()} end,
                     accepted_parent: fn :calibration -> {:ok, @accepted_parent} end,
                     enqueue_checkpoint: enqueue_checkpoint
                   ],
                   overrides
                 )
               )
    end

    assert {:error, :outbox_quarantined} =
             Builder.submit(:calibration,
               observer_snapshot: fn -> flunk("snapshot must not run") end,
               runtime_adapter: Calibration,
               durable_identity: fn -> flunk("identity must not run") end,
               accepted_parent: fn _kind -> flunk("parent lookup must not run") end,
               enqueue_checkpoint: fn _sequence_builder -> {:error, :outbox_quarantined} end
             )
  end

  test "propagates canonicalization, hashing, and encoding failures" do
    snapshot = internal_snapshot()
    projected = fn presented -> Calibration.project(presented) end
    sequence_source = fn sequence_builder -> sequence_builder.(11) end

    assert {:error, :checkpoint_secret_forbidden} =
             Builder.submit(:calibration,
               observer_snapshot: fn -> {:ok, snapshot} end,
               runtime_adapter: fn presented ->
                 with {:ok, content} <- projected.(presented) do
                   {:ok, Map.put(content, "password", "must-not-enter-checkpoint-bytes")}
                 end
               end,
               durable_identity: fn -> {:ok, durable_identity()} end,
               accepted_parent: fn _kind -> :empty end,
               enqueue_checkpoint: sequence_source
             )

    assert {:error, :checkpoint_content_hash_failed} =
             Builder.submit(:calibration,
               observer_snapshot: fn -> {:ok, snapshot} end,
               runtime_adapter: Calibration,
               durable_identity: fn -> {:ok, durable_identity()} end,
               accepted_parent: fn _kind -> :empty end,
               enqueue_checkpoint: sequence_source,
               content_hash: fn :calibration, 2, _content ->
                 {:error, :checkpoint_content_hash_failed}
               end
             )

    assert {:error, :checkpoint_record_hash_failed} =
             Builder.submit(:calibration,
               observer_snapshot: fn -> {:ok, snapshot} end,
               runtime_adapter: Calibration,
               durable_identity: fn -> {:ok, durable_identity()} end,
               accepted_parent: fn _kind -> :empty end,
               enqueue_checkpoint: sequence_source,
               checkpoint_hash: fn _attrs -> {:error, :checkpoint_record_hash_failed} end
             )

    assert {:error, :checkpoint_encoding_failed} =
             Builder.submit(:calibration,
               observer_snapshot: fn -> {:ok, snapshot} end,
               runtime_adapter: Calibration,
               durable_identity: fn -> {:ok, durable_identity()} end,
               accepted_parent: fn _kind -> :empty end,
               enqueue_checkpoint: sequence_source,
               message_encoder: fn :checkpoint_submission, _attrs ->
                 {:error, :checkpoint_encoding_failed}
               end
             )
  end

  test "rejects non-runtime schemas and malformed injected dependency results" do
    enqueue_checkpoint = fn _sequence_builder -> flunk("enqueue must not run") end

    assert {:error, :unknown_checkpoint_kind} =
             Builder.submit(:unknown,
               observer_snapshot: fn -> {:ok, %{}} end,
               runtime_adapter: fn snapshot -> {:ok, snapshot} end,
               durable_identity: fn -> {:ok, durable_identity()} end,
               accepted_parent: fn _kind -> :empty end,
               enqueue_checkpoint: enqueue_checkpoint
             )

    assert {:error, :invalid_observer_snapshot_result} =
             Builder.submit(:calibration,
               observer_snapshot: fn -> :snapshot end,
               runtime_adapter: Calibration,
               durable_identity: fn -> {:ok, durable_identity()} end,
               accepted_parent: fn _kind -> :empty end,
               enqueue_checkpoint: fn sequence_builder -> sequence_builder.(1) end
             )

    assert {:error, :invalid_durable_identity} =
             Builder.submit(:calibration,
               observer_snapshot: fn -> {:ok, internal_snapshot()} end,
               runtime_adapter: Calibration,
               durable_identity: fn -> {:ok, Map.put(durable_identity(), :boot_id, <<0::128>>)} end,
               accepted_parent: fn _kind -> :empty end,
               enqueue_checkpoint: fn sequence_builder -> sequence_builder.(1) end
             )

    assert {:error, :invalid_accepted_parent} =
             Builder.submit(:calibration,
               observer_snapshot: fn -> {:ok, internal_snapshot()} end,
               runtime_adapter: Calibration,
               durable_identity: fn -> {:ok, durable_identity()} end,
               accepted_parent: fn _kind -> {:ok, <<0>>} end,
               enqueue_checkpoint: fn sequence_builder -> sequence_builder.(1) end
             )
  end

  defp durable_identity do
    %{device_id: @device_id, credential_epoch: 7, storage_epoch: @storage_epoch}
  end

  defp checkpoint_hash_keys do
    [
      :device_id,
      :credential_epoch,
      :storage_epoch,
      :sequence,
      :kind,
      :schema_version,
      :source_generation,
      :parent_hash,
      :content_hash
    ]
  end

  defp internal_snapshot do
    {:ok, observer} =
      Observer.start_link(
        name: nil,
        sample_ms: 0,
        dir: nil,
        calibration: nil,
        boat_identifier: "boat-authority",
        sender: fn _channel, _update -> :ok end,
        now_fn: fn -> 10_000 end,
        utc_now_fn: fn -> @capture_utc end,
        sync_ms: 60_000,
        persist_ms: 60_000,
        legs: [min_duration_s: 30.0]
      )

    assert {:ok, snapshot} = Observer.snapshot(observer)
    snapshot
  end
end
