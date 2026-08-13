defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointSubmission.BuilderTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Observer
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointSubmission.{Builder, Payload}
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Store
  alias RacingOrg.Tracker.Pro.DurableDelivery.Submission.Planner
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical
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

  test "durably stores and plans valid exact-runtime content above the single-frame cap" do
    content = runtime_polar_content(Contract.max_checkpoint_size() + 1)
    assert byte_size(content) == Contract.max_checkpoint_size() + 1
    assert {:ok, projected} = Checkpoint.decode_canonical_content(:polar, 3, content)

    root = Path.join(System.tmp_dir!(), "builder-large-checkpoint-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, store} =
             Store.open(root,
               device_id: @device_id,
               credential_epoch: 7,
               storage_epoch: @storage_epoch,
               streams: [:checkpoint],
               max_entries: 10,
               max_bytes: 1_000_000,
               segment_max_bytes: 1_000_000
             )

    enqueue_checkpoint = fn sequence_builder ->
      wrapped_builder = fn sequence ->
        with {:ok, built} <- sequence_builder.(sequence) do
          case Payload.decode(built.payload) do
            {:ok, submission} ->
              assert submission.content == content
              assert submission.checkpoint_hash == built.payload_hash
              {:ok, built}

            {:error, reason} ->
              {:error, {:payload_decode_failed, reason}}
          end
        end
      end

      case Store.enqueue_checkpoint(store, wrapped_builder, entry_id: <<1::128>>) do
        {:ok, entry, _store} -> {:ok, entry}
        {:error, reason} -> {:error, reason}
      end
    end

    assert {:ok, entry} =
             Builder.submit(:polar,
               observer_snapshot: fn -> {:ok, :large_runtime_snapshot} end,
               runtime_adapter: fn :large_runtime_snapshot -> {:ok, projected} end,
               durable_identity: fn -> {:ok, durable_identity()} end,
               accepted_parent: fn :polar -> :empty end,
               enqueue_checkpoint: enqueue_checkpoint
             )

    assert entry.payload_hash != entry.payload_checksum
    assert {:error, _reason} = Messages.decode(:checkpoint_submission, entry.payload)

    assert {:ok, reopened} =
             Store.open(root,
               device_id: @device_id,
               credential_epoch: 7,
               storage_epoch: @storage_epoch,
               streams: [:checkpoint],
               max_entries: 10,
               max_bytes: 1_000_000,
               segment_max_bytes: 1_000_000
             )

    assert [replayed] = Store.pending(reopened)
    assert replayed == entry
    assert {:ok, %{entry: ^replayed, payload: nil, frames: frames}} = Planner.plan(replayed)
    assert Enum.map(frames, & &1.type) == List.duplicate(:checkpoint_submission_chunk, 2)
    assert IO.iodata_to_binary(Enum.map(frames, & &1.attrs.chunk)) == content
    assert Enum.all?(frames, &(&1.attrs.checkpoint_hash == entry.payload_hash))
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

  defp runtime_polar_content(target_size) do
    Enum.find_value([polar_checkpoint(), %{polar_checkpoint() | "cells" => []}], fn learner ->
      content = runtime_polar_checkpoint(learner)
      assert {:ok, base} = Canonical.encode(content)
      padding_size = target_size - byte_size(base)

      if padding_size >= 0 and rem(padding_size, 2) == 0 do
        current_authority = content["authority"]["boat_identifier"]
        authority = :binary.copy("x", byte_size(current_authority) + div(padding_size, 2))

        padded =
          content
          |> put_in(["authority", "boat_identifier"], authority)
          |> put_in(["learner", "content", "authority"], authority)

        case Checkpoint.canonical_content(:polar, 3, padded) do
          {:ok, bytes} when byte_size(bytes) == target_size -> bytes
          _other -> nil
        end
      end
    end) || flunk("could not build exact #{target_size}-byte runtime polar checkpoint")
  end

  defp runtime_polar_checkpoint(learner) do
    authority = "boat-runtime"
    policy = runtime_polar_policy()
    assert {:ok, learner_bytes} = Checkpoint.canonical_content(:polar, 2, learner)
    assert {:ok, learner_hash} = Checkpoint.content_hash(:polar, 2, learner_bytes)

    %{
      "runtime_schema_version" => 3,
      "runtime_snapshot_version" => 1,
      "captured_at_utc_ms" => 1_786_536_000_000,
      "authority" => %{"boat_identifier" => authority},
      "policy" => policy,
      "learner" => %{
        "source_generation" => 42,
        "content" => %{
          "authority" => authority,
          "policy_hash" => policy["admission_hash"],
          "kind" => "polar",
          "schema_version" => 2,
          "source_generation" => 42,
          "content_hash" => Canonical.bytes(learner_hash),
          "content" => Canonical.bytes(learner_bytes)
        }
      },
      "upstream_seq" => 0,
      "window" => %{"count" => 0, "chunks" => []},
      "sync" => %{
        "dirty_keys" => %{"count" => 0, "chunks" => []},
        "last_sync_age_ms" => 0
      },
      "persistence_phase" => %{
        "dirty_keys" => %{"count" => 0, "chunks" => []},
        "force" => false,
        "last_persist_age_ms" => 0
      },
      "tick" => %{"remaining_ms" => nil}
    }
  end

  defp runtime_polar_policy do
    gate = %{
      "angle_band_deg" => [25.0, 165.0],
      "heel_band_deg" => [-45.0, 45.0],
      "max_tws_sd_mps" => 0.2572,
      "max_turn_rate_dps" => 3.0,
      "max_accel_mps2" => 0.05,
      "min_dwell" => 1,
      "engine_rpm_idle" => 50.0,
      "angle_key" => "twa_deg"
    }

    hash_content = %{
      "gate" => gate,
      "min_stw_mps" => 0.3,
      "p" => 0.9,
      "window_size" => 1
    }

    assert {:ok, hash_bytes} = Canonical.encode(hash_content)
    admission_hash = :crypto.hash(:sha256, "RacingOrg-PolarObserverPolicy-v1" <> hash_bytes)

    %{
      "admission_hash" => Canonical.bytes(admission_hash),
      "gate" => gate,
      "min_stw_mps" => 0.3,
      "window_size" => 1,
      "p" => 0.9,
      "sample_ms" => 0,
      "sync_ms" => 60_000,
      "persist_ms" => 60_000,
      "persistence_enabled" => true,
      "bins" => %{
        "twa_width_deg" => 5.0,
        "tws_width_mps" => 0.514444,
        "max_tws_mps" => 51.4444
      }
    }
  end

  defp polar_checkpoint do
    %{
      "cells" => [
        %{
          "count" => 5,
          "quantile" => %{
            "buffer" => [],
            "n" => [2, 3, 4],
            "np" => [1.0, 2.8, 4.6, 4.8, 5.0],
            "q" => [1.0, 2.0, 3.0, 4.0, 5.0]
          },
          "twa_bin" => 35,
          "tws_bin" => 3
        }
      ],
      "max_tws_mps" => 51.4444,
      "p" => 0.9,
      "twa_width_deg" => 5.0,
      "tws_width_mps" => 0.514444
    }
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
