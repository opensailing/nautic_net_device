defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.SnapshotTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.{Record, Snapshot}
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  @device_id Base.decode16!("0f1e2d3c4b5a69788796a5b4c3d2e1f0", case: :lower)
  @storage_epoch Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)

  test "round-trips a current local record and accepted high-water" do
    assert {:ok, accepted} = record(accepted: true, sequence: 2)
    assert {:ok, watermark} = Snapshot.accepted_summary(accepted)
    assert {:ok, local} = record(sequence: 3, parent_hash: accepted.checkpoint_hash)
    assert {:ok, snapshot} = Snapshot.build(local, watermark)
    assert {:ok, bytes} = Snapshot.encode(snapshot)
    assert {:ok, ^snapshot} = Snapshot.decode(bytes)
  end

  test "rejects edits to the accepted watermark under intact framing" do
    assert {:ok, accepted} = record(accepted: true, sequence: 2)
    assert {:ok, watermark} = Snapshot.accepted_summary(accepted)
    assert {:ok, local} = record(sequence: 3, parent_hash: accepted.checkpoint_hash)
    assert {:ok, snapshot} = Snapshot.build(local, watermark)

    tampered = put_in(snapshot, [:last_accepted, :sequence], 1)
    bytes = :erlang.term_to_binary({4, :checkpoint_head_snapshot, tampered})

    assert {:error, :corrupt_checkpoint_head} = Snapshot.decode(bytes)
  end

  test "verifies complete multi-hop record-hash ancestry" do
    assert {:ok, accepted} = record(accepted: true, sequence: 5)
    assert {:ok, watermark} = Snapshot.accepted_summary(accepted)

    assert {:ok, intermediate} =
             record(
               sequence: 5,
               source_generation: 43,
               parent_hash: accepted.checkpoint_hash
             )

    assert {:ok, current} =
             record(
               sequence: 5,
               source_generation: 44,
               parent_hash: intermediate.checkpoint_hash
             )

    assert {:ok, intermediate_summary} = Snapshot.record_summary(intermediate)
    assert {:ok, accepted_summary} = Snapshot.record_summary(accepted)

    assert {:ok, snapshot} =
             Snapshot.build(current, watermark, [intermediate_summary, accepted_summary])

    assert {:ok, bytes} = Snapshot.encode(snapshot)
    assert {:ok, ^snapshot} = Snapshot.decode(bytes)
  end

  test "retains ordered ancestry across accepted successors" do
    assert {:ok, accepted_h1} = record(accepted: true, sequence: 1)
    assert {:ok, h1_watermark} = Snapshot.accepted_summary(accepted_h1)
    assert {:ok, h1_snapshot} = Snapshot.build(accepted_h1, h1_watermark)

    assert {:ok, accepted_h2} =
             record(
               accepted: true,
               sequence: 2,
               source_generation: 43,
               parent_hash: accepted_h1.checkpoint_hash
             )

    assert {:ok, h2_snapshot} = Snapshot.accepted_successor(h1_snapshot, accepted_h2)

    assert {:ok, accepted_h3} =
             record(
               accepted: true,
               sequence: 3,
               source_generation: 44,
               parent_hash: accepted_h2.checkpoint_hash
             )

    assert {:ok, h3_snapshot} = Snapshot.accepted_successor(h2_snapshot, accepted_h3)
    assert Snapshot.accepted_ancestor?(h3_snapshot, accepted_h1.checkpoint_hash)
    assert {:ok, bytes} = Snapshot.encode(h3_snapshot)
    assert {:ok, ^h3_snapshot} = Snapshot.decode(bytes)
  end

  test "starts local ancestry at the latest accepted successor" do
    assert {:ok, accepted_h1} = record(accepted: true, sequence: 1)
    assert {:ok, h1_watermark} = Snapshot.accepted_summary(accepted_h1)
    assert {:ok, h1_snapshot} = Snapshot.build(accepted_h1, h1_watermark)

    assert {:ok, accepted_h2} =
             record(
               accepted: true,
               sequence: 2,
               source_generation: 43,
               parent_hash: accepted_h1.checkpoint_hash
             )

    assert {:ok, h2_snapshot} = Snapshot.accepted_successor(h1_snapshot, accepted_h2)

    assert {:ok, local_h3} =
             record(
               sequence: 3,
               source_generation: 44,
               parent_hash: accepted_h2.checkpoint_hash
             )

    assert {:ok, local_snapshot} = Snapshot.successor(h2_snapshot, local_h3)
    assert local_snapshot.last_accepted == h2_snapshot.last_accepted
    assert [latest_accepted, earlier_accepted] = local_snapshot.ancestry
    assert latest_accepted.checkpoint_hash == accepted_h2.checkpoint_hash
    assert earlier_accepted.checkpoint_hash == accepted_h1.checkpoint_hash

    for summary <- local_snapshot.ancestry do
      refute Map.has_key?(summary, :local_credential_epoch)
      refute Map.has_key?(summary, :local_storage_epoch)
      refute Map.has_key?(summary, :binding_hash)
    end

    refute local_snapshot.ancestry_truncated
  end

  test "preserves truncated accepted history through local progress" do
    assert {:ok, omitted_root} = record(sequence: 1)

    assert {:ok, accepted_h2} =
             record(
               accepted: true,
               sequence: 2,
               source_generation: 43,
               parent_hash: omitted_root.checkpoint_hash
             )

    assert {:ok, h2_watermark} = Snapshot.accepted_summary(accepted_h2)
    assert {:ok, h2_snapshot} = Snapshot.build(accepted_h2, h2_watermark)
    assert h2_snapshot.ancestry_truncated

    assert {:ok, accepted_h3} =
             record(
               accepted: true,
               sequence: 3,
               source_generation: 44,
               parent_hash: accepted_h2.checkpoint_hash
             )

    assert {:ok, h3_snapshot} = Snapshot.accepted_successor(h2_snapshot, accepted_h3)
    assert h3_snapshot.ancestry_truncated

    assert {:ok, local_h4} =
             record(
               sequence: 4,
               source_generation: 45,
               parent_hash: accepted_h3.checkpoint_hash
             )

    assert {:ok, local_snapshot} = Snapshot.successor(h3_snapshot, local_h4)
    assert local_snapshot.ancestry_truncated
    assert Snapshot.accepted_ancestor?(local_snapshot, accepted_h2.checkpoint_hash)
  end

  test "rejects moving an accepted watermark backward to an older retained ancestor" do
    assert {:ok, accepted_h1} = record(accepted: true, sequence: 1)
    assert {:ok, h1_watermark} = Snapshot.accepted_summary(accepted_h1)
    assert {:ok, h1_summary} = Snapshot.record_summary(accepted_h1)

    assert {:ok, accepted_h2} =
             record(
               accepted: true,
               sequence: 2,
               source_generation: 43,
               parent_hash: accepted_h1.checkpoint_hash
             )

    assert {:ok, h2_watermark} = Snapshot.accepted_summary(accepted_h2)
    assert {:ok, h2_summary} = Snapshot.record_summary(accepted_h2)

    assert {:ok, local_h3} =
             record(
               sequence: 3,
               source_generation: 44,
               parent_hash: accepted_h2.checkpoint_hash
             )

    assert {:ok, snapshot} =
             Snapshot.build(local_h3, h2_watermark, [h2_summary, h1_summary])

    assert {:error, :checkpoint_hydration_rollback} =
             Snapshot.preserve_acceptance(snapshot, local_h3, h1_watermark)
  end

  test "rejects moving an accepted watermark backward across a truncated boundary" do
    assert {:ok, accepted_h1} = record(accepted: true, sequence: 1)
    assert {:ok, h1_watermark} = Snapshot.accepted_summary(accepted_h1)

    assert {:ok, accepted_h2} =
             record(
               accepted: true,
               sequence: 2,
               source_generation: 43,
               parent_hash: accepted_h1.checkpoint_hash
             )

    assert {:ok, h2_watermark} = Snapshot.accepted_summary(accepted_h2)
    assert {:ok, h2_summary} = Snapshot.record_summary(accepted_h2)

    assert {:ok, local_h3} =
             record(
               sequence: 3,
               source_generation: 44,
               parent_hash: accepted_h2.checkpoint_hash
             )

    assert {:ok, snapshot} =
             Snapshot.build(local_h3, h2_watermark, [h2_summary], true)

    assert {:error, :checkpoint_hydration_rollback} =
             Snapshot.preserve_acceptance(snapshot, local_h3, h1_watermark)
  end

  test "rejects an equal-sequence accepted fork without complete ancestry" do
    assert {:ok, branch_root} = record(sequence: 5)

    assert {:ok, accepted_parent} =
             record(
               sequence: 5,
               source_generation: 43,
               parent_hash: branch_root.checkpoint_hash
             )

    assert {:ok, accepted} =
             record(
               accepted: true,
               sequence: 5,
               source_generation: 44,
               parent_hash: accepted_parent.checkpoint_hash
             )

    assert {:ok, local_fork} =
             record(
               sequence: 5,
               source_generation: 45,
               parent_hash: branch_root.checkpoint_hash
             )

    assert {:ok, watermark} = Snapshot.accepted_summary(accepted)
    assert {:ok, root_summary} = Snapshot.record_summary(branch_root)

    assert {:error, :invalid_checkpoint_snapshot} =
             Snapshot.build(local_fork, watermark, [root_summary])
  end

  test "rejects an origin-reset accepted fork without complete ancestry" do
    other_storage_epoch = Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
    assert {:ok, branch_root} = record(sequence: 100)

    assert {:ok, reset_parent} =
             record(
               origin_credential_epoch: 8,
               origin_storage_epoch: other_storage_epoch,
               sequence: 1,
               source_generation: 43,
               parent_hash: branch_root.checkpoint_hash
             )

    assert {:ok, accepted} =
             record(
               accepted: true,
               origin_credential_epoch: 8,
               origin_storage_epoch: other_storage_epoch,
               sequence: 2,
               source_generation: 44,
               parent_hash: reset_parent.checkpoint_hash
             )

    assert {:ok, local_fork} =
             record(
               sequence: 101,
               source_generation: 45,
               parent_hash: branch_root.checkpoint_hash
             )

    assert {:ok, watermark} = Snapshot.accepted_summary(accepted)
    assert {:ok, root_summary} = Snapshot.record_summary(branch_root)

    assert {:error, :invalid_checkpoint_snapshot} =
             Snapshot.build(local_fork, watermark, [root_summary])
  end

  test "accepts a direct parent across a same-origin sequence reset" do
    assert {:ok, accepted} = record(accepted: true, sequence: 10)
    assert {:ok, watermark} = Snapshot.accepted_summary(accepted)

    assert {:ok, local} =
             record(
               sequence: 1,
               source_generation: 43,
               parent_hash: accepted.checkpoint_hash
             )

    assert {:ok, snapshot} = Snapshot.build(local, watermark)
    assert snapshot.last_accepted == watermark
    assert [accepted_summary] = snapshot.ancestry
    assert accepted_summary.checkpoint_hash == accepted.checkpoint_hash
  end

  test "rejects an accepted watermark bound to another local identity" do
    assert {:ok, accepted} = record(accepted: true)
    assert {:ok, watermark} = Snapshot.accepted_summary(accepted)

    assert {:ok, local} =
             record(
               local_credential_epoch: 8,
               local_storage_epoch:
                 Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower),
               sequence: 2,
               source_generation: 43,
               parent_hash: accepted.checkpoint_hash
             )

    assert {:error, :invalid_checkpoint_snapshot} = Snapshot.build(local, watermark)
  end

  test "rejects an unrelated watermark when ancestry is unknown" do
    assert {:ok, accepted_fork} = record(accepted: true, sequence: 1, source_generation: 41)
    assert {:ok, watermark} = Snapshot.accepted_summary(accepted_fork)
    assert {:ok, local_fork} = record(sequence: 2, source_generation: 42)

    assert {:error, :invalid_checkpoint_snapshot} =
             Snapshot.build(local_fork, watermark, :unknown)
  end

  test "rejects truncated ancestry when the retained chain already reaches genesis" do
    assert {:ok, accepted_fork} = record(accepted: true, sequence: 1, source_generation: 41)
    assert {:ok, watermark} = Snapshot.accepted_summary(accepted_fork)
    assert {:ok, local_fork} = record(sequence: 2, source_generation: 42)

    assert {:error, :invalid_checkpoint_snapshot} =
             Snapshot.build(local_fork, watermark, [], true)
  end

  test "rejects an accepted watermark that is not behind local current" do
    assert {:ok, local} = record(sequence: 1)

    assert {:ok, accepted_same} = record(accepted: true, sequence: 1)
    assert {:ok, same_watermark} = Snapshot.accepted_summary(accepted_same)
    assert {:error, :invalid_checkpoint_snapshot} = Snapshot.build(local, same_watermark)

    assert {:ok, accepted_child} =
             record(accepted: true, sequence: 2, parent_hash: local.checkpoint_hash)

    assert {:ok, child_watermark} = Snapshot.accepted_summary(accepted_child)
    assert {:error, :invalid_checkpoint_snapshot} = Snapshot.build(local, child_watermark)

    assert {:ok, accepted_grandchild} =
             record(
               accepted: true,
               sequence: 3,
               parent_hash: accepted_child.checkpoint_hash
             )

    assert {:ok, grandchild_watermark} = Snapshot.accepted_summary(accepted_grandchild)
    assert {:error, :invalid_checkpoint_snapshot} = Snapshot.build(local, grandchild_watermark)
  end

  test "migrates accepted legacy records and fences unknown local ancestry" do
    assert {:ok, accepted} = record(accepted: true)
    assert {:ok, accepted_bytes} = Record.encode(accepted)
    assert {:ok, accepted_snapshot} = Snapshot.decode(accepted_bytes)
    assert accepted_snapshot.last_accepted.checkpoint_hash == accepted.checkpoint_hash

    assert {:ok, local} = record()
    assert {:ok, local_bytes} = Record.encode(local)
    assert {:ok, local_snapshot} = Snapshot.decode(local_bytes)
    assert local_snapshot.last_accepted == :unknown
  end

  test "migrates a non-genesis accepted legacy record as truncated history" do
    assert {:ok, accepted_parent} = record(accepted: true, sequence: 1)

    assert {:ok, accepted_current} =
             record(
               accepted: true,
               sequence: 2,
               source_generation: 43,
               parent_hash: accepted_parent.checkpoint_hash
             )

    assert {:ok, bytes} = Record.encode(accepted_current)
    assert {:ok, migrated} = Snapshot.decode(bytes)
    assert migrated.current == accepted_current
    assert migrated.last_accepted.checkpoint_hash == accepted_current.checkpoint_hash
    assert migrated.ancestry == []
    assert migrated.ancestry_truncated
  end

  test "migrates a v2 accepted watermark as fenced unknown ancestry" do
    assert {:ok, accepted} = record(accepted: true, sequence: 2)
    assert {:ok, legacy_watermark} = Snapshot.record_summary(accepted)
    assert {:ok, local} = record(sequence: 3, parent_hash: accepted.checkpoint_hash)

    legacy = %{current: local, last_accepted: legacy_watermark}
    bytes = legacy_snapshot_bytes(legacy)

    assert {:ok, migrated} = Snapshot.decode(bytes)
    assert migrated.current == local
    assert migrated.last_accepted == :unknown
    assert migrated.ancestry == :unknown
    refute migrated.ancestry_truncated
  end

  test "migrates a v2 direct-parent watermark across a sequence reset" do
    assert {:ok, accepted} = record(accepted: true, sequence: 10)
    assert {:ok, legacy_watermark} = Snapshot.record_summary(accepted)

    assert {:ok, local} =
             record(
               sequence: 1,
               source_generation: 43,
               parent_hash: accepted.checkpoint_hash
             )

    bytes = legacy_snapshot_bytes(%{current: local, last_accepted: legacy_watermark})

    assert {:ok, migrated} = Snapshot.decode(bytes)
    assert migrated.current == local
    assert migrated.last_accepted == :unknown
    assert migrated.ancestry == :unknown
    refute migrated.ancestry_truncated
  end

  test "migrates a v2 local snapshot without an accepted watermark" do
    assert {:ok, local} = record()
    bytes = legacy_snapshot_bytes(%{current: local, last_accepted: nil})

    assert {:ok, migrated} = Snapshot.decode(bytes)
    assert migrated.current == local
    assert migrated.last_accepted == nil
    assert migrated.ancestry == []
  end

  test "rejects an unknown-ancestry watermark ahead of current" do
    assert {:ok, local} = record()

    assert {:ok, accepted_child} =
             record(accepted: true, sequence: 2, parent_hash: local.checkpoint_hash)

    assert {:ok, watermark} = Snapshot.accepted_summary(accepted_child)

    assert {:error, :invalid_checkpoint_snapshot} =
             Snapshot.build(local, watermark, :unknown)
  end

  test "compacts bounded ancestry without losing the accepted watermark" do
    max_entries = Snapshot.max_ancestry_entries()
    assert {:ok, accepted} = record(accepted: true, sequence: 1, source_generation: 1)
    assert {:ok, watermark} = Snapshot.accepted_summary(accepted)

    {local_records, _parent_hash} =
      Enum.map_reduce(2..(max_entries + 3), accepted.checkpoint_hash, fn sequence, parent_hash ->
        assert {:ok, local} =
                 record(
                   sequence: sequence,
                   source_generation: sequence,
                   parent_hash: parent_hash
                 )

        {local, local.checkpoint_hash}
      end)

    [boundary_parent | _rest] = local_records
    [next, boundary_next] = Enum.take(local_records, -2)
    prior_records = Enum.drop(local_records, -2)
    current = List.last(prior_records)

    ancestry =
      [accepted | Enum.drop(prior_records, -1)]
      |> Enum.reverse()
      |> Enum.map(fn ancestor ->
        assert {:ok, summary} = Snapshot.record_summary(ancestor)
        summary
      end)

    assert length(ancestry) == max_entries
    assert {:ok, snapshot} = Snapshot.build(current, watermark, ancestry)
    assert {:ok, compacted} = Snapshot.successor(snapshot, next)
    assert length(compacted.ancestry) == max_entries
    assert compacted.ancestry_truncated
    assert compacted.last_accepted == watermark
    assert Snapshot.accepted_ancestor?(compacted, accepted.checkpoint_hash)
    refute Enum.any?(compacted.ancestry, &(&1.checkpoint_hash == accepted.checkpoint_hash))

    assert {:ok, replayed} =
             Snapshot.preserve_acceptance(compacted, compacted.current, watermark)

    assert replayed.current == compacted.current
    assert replayed.last_accepted == watermark
    assert replayed.ancestry == compacted.ancestry
    assert replayed.ancestry_truncated

    assert {:ok, compacted_again} = Snapshot.successor(compacted, boundary_next)
    assert compacted_again.ancestry_truncated
    assert Snapshot.accepted_ancestor?(compacted_again, boundary_parent.checkpoint_hash)

    refute Enum.any?(
             compacted_again.ancestry,
             &(&1.checkpoint_hash == boundary_parent.checkpoint_hash)
           )

    assert {:ok, bytes} = Snapshot.encode(compacted_again)
    assert {:ok, ^compacted_again} = Snapshot.decode(bytes)
  end

  test "compacts bounded ancestry without an accepted watermark" do
    max_entries = Snapshot.max_ancestry_entries()

    {records, _parent_hash} =
      Enum.map_reduce(1..(max_entries + 2), Record.genesis_parent(), fn sequence, parent_hash ->
        assert {:ok, local} =
                 record(
                   sequence: sequence,
                   source_generation: sequence,
                   parent_hash: parent_hash
                 )

        {local, local.checkpoint_hash}
      end)

    next = List.last(records)
    prior_records = Enum.drop(records, -1)
    current = List.last(prior_records)

    ancestry =
      prior_records
      |> Enum.drop(-1)
      |> Enum.reverse()
      |> Enum.map(fn ancestor ->
        assert {:ok, summary} = Snapshot.record_summary(ancestor)
        summary
      end)

    assert length(ancestry) == max_entries
    assert {:ok, snapshot} = Snapshot.build(current, nil, ancestry)
    assert {:ok, compacted} = Snapshot.successor(snapshot, next)
    assert compacted.last_accepted == nil
    assert length(compacted.ancestry) == max_entries
    assert compacted.ancestry_truncated
    assert {:ok, bytes} = Snapshot.encode(compacted)
    assert {:ok, ^compacted} = Snapshot.decode(bytes)
  end

  test "rejects an unaccepted record summary as the accepted watermark" do
    assert {:ok, unaccepted} = record(sequence: 1)
    assert {:ok, forged_watermark} = Snapshot.record_summary(unaccepted)

    assert {:ok, current} =
             record(
               sequence: 2,
               source_generation: 43,
               parent_hash: unaccepted.checkpoint_hash
             )

    assert {:error, :invalid_checkpoint_snapshot} =
             Snapshot.build(current, forged_watermark, [forged_watermark])
  end

  test "decodes maximum-size legacy records concurrently within the deadline" do
    assert {:ok, legacy} =
             record(
               kind: :wind_shift,
               content: maximum_wind_shift_content()
             )

    assert byte_size(legacy.content) == 65_298
    assert {:ok, bytes} = Record.encode(legacy)

    results =
      1..16
      |> Task.async_stream(
        fn _index -> Snapshot.decode(bytes) end,
        max_concurrency: 16,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.to_list()

    assert length(results) == 16

    for result <- results do
      assert {:ok, {:ok, %{current: ^legacy}}} = result
    end
  end

  test "contains external-term heap expansion inside the decoder" do
    entries = 1_200_000
    expanding_term = <<131, 108, entries::32, :binary.copy(<<106>>, entries)::binary, 106>>
    owner = self()
    result_ref = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(owner, {result_ref, Snapshot.decode(expanding_term)}) end,
        [:monitor, {:max_heap_size, %{size: 100_000, kill: true, error_logger: false}}]
      )

    assert_receive {^result_ref, {:error, :corrupt_checkpoint_head}}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
  end

  test "rejects malformed current records without crashing hash verification" do
    assert {:ok, local} = record()
    assert {:ok, snapshot} = Snapshot.build(local, nil)
    tampered = put_in(snapshot, [:current, :extra], 1)
    bytes = :erlang.term_to_binary({4, :checkpoint_head_snapshot, tampered})

    assert {:error, :corrupt_checkpoint_head} = Snapshot.decode(bytes)
  end

  test "rejects compressed and oversized snapshots before external-term decoding" do
    assert {:ok, local} = record()
    assert {:ok, snapshot} = Snapshot.build(local, nil)

    compressed =
      :erlang.term_to_binary({2, :checkpoint_head_snapshot, snapshot}, compressed: 9)

    assert {:error, :corrupt_checkpoint_head} = Snapshot.decode(compressed)

    oversized = :binary.copy(<<0>>, Snapshot.max_encoded_size() + 1)
    assert {:error, :corrupt_checkpoint_head} = Snapshot.decode(oversized)
  end

  defp legacy_snapshot_bytes(snapshot) do
    {:ok, current_bytes} = Record.encode(snapshot.current)
    accepted_bytes = encode_summary(snapshot.last_accepted)

    hash =
      :crypto.hash(
        :sha256,
        "RacingOrg-TrackerCheckpointHeadSnapshot-v1" <>
          <<1, byte_size(current_bytes)::32, current_bytes::binary, byte_size(accepted_bytes)::16,
            accepted_bytes::binary>>
      )

    :erlang.term_to_binary(
      {2, :checkpoint_head_snapshot, Map.put(snapshot, :snapshot_hash, hash)}
    )
  end

  defp encode_summary(nil), do: <<>>
  defp encode_summary(:unknown), do: <<0xFF>>

  defp encode_summary(summary) do
    {:ok, kind_code, _schema_version} = Contract.checkpoint_kind(summary.kind)

    <<summary.device_id::binary-size(16), summary.origin_credential_epoch::32,
      summary.origin_storage_epoch::binary-size(16), summary.sequence::64, kind_code,
      summary.schema_version::16, summary.source_generation::64,
      summary.parent_hash::binary-size(32), summary.content_hash::binary-size(32),
      summary.checkpoint_hash::binary-size(32)>>
  end

  defp maximum_wind_shift_content do
    started_at_ms = 1_784_800_800_000

    timeline =
      List.duplicate(
        %{
          "amplitude_deg" => nil,
          "mean_twd_deg" => nil,
          "period_s" => nil,
          "phase_deg" => nil,
          "t_ms" => started_at_ms,
          "trend_deg_per_hr" => nil,
          "tws_mps" => nil
        },
        632
      )

    %{
      "last_summary" => nil,
      "pending_events" => [],
      "pending_timeline" => timeline,
      "seq" => 632,
      "session" => %{
        "lat_sum" => 0.0,
        "lon_sum" => 0.0,
        "pos_n" => 0,
        "started_at_ms" => started_at_ms,
        "tws_n" => 0,
        "tws_sum" => 0.0
      }
    }
  end

  defp record(overrides \\ []) do
    attrs =
      Enum.into(
        overrides,
        %{
          device_id: @device_id,
          local_credential_epoch: 7,
          local_storage_epoch: @storage_epoch,
          origin_credential_epoch: 7,
          origin_storage_epoch: @storage_epoch,
          sequence: 1,
          kind: :calibration,
          schema_version: 1,
          source_generation: 42,
          parent_hash: Record.genesis_parent(),
          content: %{
            "awa_estimators" => [],
            "aws_estimators" => [],
            "prev_applied" => [],
            "seq" => 0,
            "stw_estimators" => []
          },
          accepted: false
        }
      )

    Record.build(attrs)
  end
end