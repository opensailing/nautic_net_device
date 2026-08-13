defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.RecordTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Observer, as: CalibrationObserver
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record
  alias RacingOrg.Tracker.Pro.Polar.Observer.{Bins, Gate}
  alias RacingOrg.Tracker.Pro.Polar.Observer.Snapshot, as: PolarSnapshot
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.Calibration,
    as: CalibrationRuntime

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.Polar,
    as: PolarRuntime

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.WindShift,
    as: WindShiftRuntime

  alias RacingOrg.Tracker.Pro.WindShift.Observer, as: WindShiftObserver

  @device_id Base.decode16!("0f1e2d3c4b5a69788796a5b4c3d2e1f0", case: :lower)
  @other_device_id Base.decode16!("aabbccddeeff00112233445566778899", case: :lower)
  @storage_epoch Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @origin_storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @parent_hash :binary.copy(<<0xB2>>, 32)
  @binding_domain "RacingOrg-TrackerCheckpointHeadBinding-v1"
  @binding_version 1

  describe "genesis parent" do
    test "is the all-zero record hash and is distinct from any real record hash" do
      assert Record.genesis_parent() == <<0::256>>
      assert byte_size(Record.genesis_parent()) == 32

      assert {:ok, record} = Record.build(attrs())
      refute record.checkpoint_hash == Record.genesis_parent()
    end
  end

  describe "build/1" do
    test "derives the content, record, and binding hashes from the frozen preimages" do
      assert {:ok, record} = Record.build(attrs())

      assert {:ok, content_hash} =
               Checkpoint.content_hash(:calibration, 0x0001, record.content)

      assert record.content_hash == content_hash

      # The record hash commits to the ORIGIN identity, never the local binding.
      assert {:ok, checkpoint_hash} =
               Checkpoint.hash(%{
                 device_id: @device_id,
                 credential_epoch: record.origin_credential_epoch,
                 storage_epoch: record.origin_storage_epoch,
                 sequence: record.sequence,
                 kind: record.kind,
                 schema_version: record.schema_version,
                 source_generation: record.source_generation,
                 parent_hash: record.parent_hash,
                 content_hash: record.content_hash
               })

      assert record.checkpoint_hash == checkpoint_hash

      device_id = @device_id
      storage_epoch = @storage_epoch

      expected_binding =
        :crypto.hash(
          :sha256,
          @binding_domain <>
            <<@binding_version, Contract.version(), device_id::binary-size(16), 7::32, storage_epoch::binary-size(16),
              0, checkpoint_hash::binary-size(32)>>
        )

      assert record.binding_hash == expected_binding
    end

    test "binds the acceptance flag so a local record cannot be relabelled accepted" do
      assert {:ok, local} = Record.build(attrs())
      assert {:ok, accepted} = Record.build(attrs(%{accepted: true}))

      assert local.checkpoint_hash == accepted.checkpoint_hash
      refute local.binding_hash == accepted.binding_hash
    end

    test "separates the local binding identity from the acceptance identity" do
      assert {:ok, record} =
               Record.build(
                 attrs(%{
                   origin_credential_epoch: 3,
                   origin_storage_epoch: @origin_storage_epoch,
                   accepted: true
                 })
               )

      assert record.local_credential_epoch == 7
      assert record.local_storage_epoch == @storage_epoch
      assert record.origin_credential_epoch == 3
      assert record.origin_storage_epoch == @origin_storage_epoch

      assert {:ok, checkpoint_hash} =
               Checkpoint.hash(%{
                 device_id: @device_id,
                 credential_epoch: 3,
                 storage_epoch: @origin_storage_epoch,
                 sequence: record.sequence,
                 kind: record.kind,
                 schema_version: record.schema_version,
                 source_generation: record.source_generation,
                 parent_hash: record.parent_hash,
                 content_hash: record.content_hash
               })

      assert record.checkpoint_hash == checkpoint_hash
    end

    test "rejects Wind runtime authority that disagrees with the record origin" do
      content = runtime_wind_shift_content()

      for overrides <- [
            %{device_id: @other_device_id},
            %{origin_credential_epoch: 8},
            %{origin_storage_epoch: @origin_storage_epoch}
          ] do
        assert {:error, :checkpoint_authority_mismatch} =
                 Record.build(
                   attrs(
                     Map.merge(
                       %{
                         kind: :wind_shift,
                         schema_version: 2,
                         source_generation: 42,
                         content: content
                       },
                       overrides
                     )
                   )
                 )
      end
    end

    test "accepts every kind in the closed registry at its registered schema" do
      for {kind, _code, schema_version} <- Contract.checkpoint_kinds() do
        assert {:ok, record} =
                 Record.build(attrs(%{kind: kind, schema_version: schema_version, content: content(kind)}))

        assert record.kind == kind
        assert record.schema_version == schema_version
      end
    end

    test "builds, encodes, and decodes every exact runtime schema" do
      for {kind, schema_version, content} <- runtime_schema_fixtures() do
        assert {:ok, record} =
                 Record.build(attrs(%{kind: kind, schema_version: schema_version, content: content}))

        assert record.kind == kind
        assert record.schema_version == schema_version
        assert {:ok, encoded} = Record.encode(record)
        assert {:ok, ^record} = Record.decode(encoded)
      end
    end

    test "rejects unknown kinds and unregistered schema versions" do
      assert {:error, :unknown_checkpoint_kind} =
               Record.build(attrs(%{kind: :telemetry}))

      assert {:error, :unknown_checkpoint_kind} =
               Record.build(attrs(%{kind: "calibration"}))

      assert {:error, :unsupported_checkpoint_schema} =
               Record.build(attrs(%{schema_version: 3}))

      assert {:error, :invalid_checkpoint_content} =
               Record.build(attrs(%{schema_version: 2}))

      # The retired polar v1 schema is rejected as firmly as an unreached one.
      assert {:error, :unsupported_checkpoint_schema} =
               Record.build(attrs(%{kind: :polar, schema_version: 1, content: content(:polar)}))
    end

    test "persists schema-valid content beyond the single-frame carriage cap" do
      content = large_polar_content()

      assert {:ok, canonical} = Checkpoint.canonical_content(:polar, 2, content)
      assert byte_size(canonical) > Contract.max_checkpoint_size()
      assert byte_size(canonical) <= Contract.max_checkpoint_content_size()

      assert {:ok, record} =
               Record.build(attrs(%{kind: :polar, schema_version: 2, content: content}))

      assert record.content == canonical
      assert {:ok, bytes} = Record.encode(record)
      assert byte_size(bytes) <= Record.max_encoded_size()
      assert {:ok, ^record} = Record.decode(bytes)
    end

    test "rejects malformed content, non-canonical content, and oversized content" do
      assert {:error, :invalid_checkpoint_content} =
               Record.build(attrs(%{content: %{"seq" => 0}}))

      assert {:error, :invalid_checkpoint_content} =
               Record.build(attrs(%{content: content(:calibration) |> Map.put("seq", -1)}))

      assert {:error, :invalid_checkpoint_content} =
               Record.build(attrs(%{content: <<0xFF, 0xFF>>}))

      assert {:ok, bytes} = Checkpoint.encode_content(:calibration, 0x0001, content(:calibration))

      assert {:error, :noncanonical_checkpoint_content} =
               Record.build(attrs(%{content: bytes <> <<0>>}))
               |> normalize_trailing()
    end

    test "rejects secret-capable content before it can be hashed or persisted" do
      secret = content(:calibration) |> Map.put("psk", "hunter2")

      assert {:error, :checkpoint_secret_forbidden} = Record.build(attrs(%{content: secret}))

      generic = content(:calibration) |> Map.put("metadata", %{"a" => 1})

      assert {:error, :checkpoint_secret_forbidden} = Record.build(attrs(%{content: generic}))

      nested =
        content(:calibration)
        |> Map.put("prev_applied", [%{"passphrase" => "s"}])

      assert {:error, :checkpoint_secret_forbidden} = Record.build(attrs(%{content: nested}))
    end

    test "rejects malformed identity, sequence, and parent-hash fields" do
      assert {:error, :invalid_device_id} = Record.build(attrs(%{device_id: <<0>>}))

      assert {:error, :invalid_credential_epoch} =
               Record.build(attrs(%{local_credential_epoch: -1}))

      assert {:error, :invalid_credential_epoch} =
               Record.build(attrs(%{origin_credential_epoch: 0x1_0000_0000}))

      assert {:error, :invalid_storage_epoch} =
               Record.build(attrs(%{local_storage_epoch: <<0::128>>}))

      assert {:error, :invalid_storage_epoch} =
               Record.build(attrs(%{origin_storage_epoch: <<1, 2, 3>>}))

      assert {:error, :invalid_delivery_sequence} = Record.build(attrs(%{sequence: 0}))

      assert {:error, :invalid_source_generation} =
               Record.build(attrs(%{source_generation: -1}))

      assert {:error, :invalid_parent_hash} = Record.build(attrs(%{parent_hash: <<0>>}))

      assert {:error, :invalid_acceptance} = Record.build(attrs(%{accepted: :yes}))

      assert {:error, :invalid_checkpoint_record} = Record.build(%{})
      assert {:error, :invalid_checkpoint_record} = Record.build(:not_a_map)

      assert {:error, :invalid_checkpoint_record} =
               Record.build(attrs() |> Map.put(:extra, 1))
    end

    test "accepts the genesis parent for a first record" do
      assert {:ok, record} = Record.build(attrs(%{parent_hash: Record.genesis_parent()}))
      assert record.parent_hash == Record.genesis_parent()
    end
  end

  describe "encode/1 and decode/1" do
    test "round-trip one exact record" do
      assert {:ok, record} = Record.build(attrs())
      assert {:ok, bytes} = Record.encode(record)
      assert {:ok, ^record} = Record.decode(bytes)
    end

    test "round-trips canonical content near the semantic cap through the bounded decoder" do
      semantic_cap = Contract.max_checkpoint_content_size()
      content = near_semantic_cap_polar_content()

      assert {:ok, canonical} = Checkpoint.canonical_content(:polar, 2, content)
      assert byte_size(canonical) > semantic_cap - 262_144
      assert byte_size(canonical) <= semantic_cap

      assert {:ok, record} =
               Record.build(
                 attrs(%{
                   kind: :polar,
                   schema_version: 2,
                   content: canonical
                 })
               )

      assert record.content === canonical
      assert {:ok, expected_content_hash} = Checkpoint.content_hash(:polar, 2, canonical)
      assert record.content_hash === expected_content_hash
      assert {:ok, encoded} = Record.encode(record)
      assert byte_size(encoded) > semantic_cap - 262_144
      assert byte_size(encoded) <= Record.max_encoded_size()
      assert {:ok, reopened} = Record.decode(encoded)
      assert reopened.content === canonical
      assert reopened.content_hash === record.content_hash
      assert reopened.checkpoint_hash === record.checkpoint_hash
      assert reopened.binding_hash === record.binding_hash
      assert reopened === record
    end

    test "reject truncation, garbage, and unknown framing" do
      assert {:ok, record} = Record.build(attrs())
      assert {:ok, bytes} = Record.encode(record)

      assert {:error, :corrupt_checkpoint_head} =
               Record.decode(binary_part(bytes, 0, byte_size(bytes) - 1))

      assert {:error, :corrupt_checkpoint_head} = Record.decode(<<>>)
      assert {:error, :corrupt_checkpoint_head} = Record.decode(<<0xFF, 0xFE, 0xFD>>)
      assert {:error, :corrupt_checkpoint_head} = Record.decode(:erlang.term_to_binary(:ok))
      assert {:error, :corrupt_checkpoint_head} = Record.decode(bytes <> <<0>>)
      assert {:error, :corrupt_checkpoint_head} = Record.decode(:not_a_binary)
    end

    test "rejects compressed or oversized external-term input before decoding" do
      assert {:ok, record} = Record.build(attrs())

      compressed =
        :erlang.term_to_binary(
          {Record.format_version(), :checkpoint_head, record},
          compressed: 9
        )

      assert {:error, :corrupt_checkpoint_head} = Record.decode(compressed)

      oversized = :binary.copy(<<0>>, Record.max_encoded_size() + 1)
      assert {:error, :corrupt_checkpoint_head} = Record.decode(oversized)
      assert Record.max_encoded_size() < Contract.max_checkpoint_content_size() + 8_192
    end

    test "contains external-term heap expansion inside the decoder" do
      entries = 60_000
      expanding_term = <<131, 108, entries::32, :binary.copy(<<106>>, entries)::binary, 106>>
      owner = self()
      result_ref = make_ref()

      {pid, monitor} =
        :erlang.spawn_opt(
          fn -> send(owner, {result_ref, Record.decode(expanding_term)}) end,
          [:monitor, {:max_heap_size, %{size: 100_000, kill: true, error_logger: false}}]
        )

      assert_receive {^result_ref, {:error, :corrupt_checkpoint_head}}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
    end

    test "reject a wrong format version or record tag" do
      assert {:ok, record} = Record.build(attrs())

      assert {:error, :corrupt_checkpoint_head} =
               Record.decode(:erlang.term_to_binary({99, :checkpoint_head, record}))

      assert {:error, :corrupt_checkpoint_head} =
               Record.decode(:erlang.term_to_binary({1, :active_pointer, record}))
    end

    test "reject a decodable record whose derived hashes no longer agree" do
      assert {:ok, record} = Record.build(attrs())

      for field <- [:content_hash, :checkpoint_hash, :binding_hash] do
        tampered = Map.put(record, field, :binary.copy(<<0xEE>>, 32))

        assert {:error, :corrupt_checkpoint_head} =
                 Record.decode(:erlang.term_to_binary({1, :checkpoint_head, tampered}))
      end
    end

    test "reject a record whose semantic fields were edited under intact framing" do
      assert {:ok, record} = Record.build(attrs())

      edits = [
        {:sequence, record.sequence + 1},
        {:source_generation, record.source_generation + 1},
        {:parent_hash, :binary.copy(<<0xA1>>, 32)},
        {:local_credential_epoch, record.local_credential_epoch + 1},
        {:origin_credential_epoch, record.origin_credential_epoch + 1},
        {:local_storage_epoch, @origin_storage_epoch},
        {:origin_storage_epoch, @origin_storage_epoch},
        {:device_id, @other_device_id},
        {:accepted, true}
      ]

      for {field, value} <- edits do
        tampered = Map.put(record, field, value)

        assert {:error, :corrupt_checkpoint_head} =
                 Record.decode(:erlang.term_to_binary({1, :checkpoint_head, tampered})),
               "editing #{field} must not survive reopen validation"
      end
    end

    test "reject content bytes edited under an intact hash chain" do
      assert {:ok, record} = Record.build(attrs())
      tampered = Map.put(record, :content, record.content <> <<0>>)

      assert {:error, :corrupt_checkpoint_head} =
               Record.decode(:erlang.term_to_binary({1, :checkpoint_head, tampered}))
    end

    test "rejects extra record keys during in-memory verification" do
      assert {:ok, record} = Record.build(attrs())
      assert {:error, :corrupt_checkpoint_head} = Record.verify(Map.put(record, :extra, 1))
    end

    test "never persist a decoded content map alongside the canonical bytes" do
      assert {:ok, record} = Record.build(attrs())

      refute Map.has_key?(record, :content_map)
      refute Map.has_key?(record, :decoded)
      assert is_binary(record.content)
    end
  end

  defp normalize_trailing({:error, :invalid_checkpoint_content}),
    do: {:error, :noncanonical_checkpoint_content}

  defp normalize_trailing(other), do: other

  defp runtime_schema_fixtures do
    [
      {:calibration, 2, runtime_calibration_content()},
      {:polar, 3, runtime_polar_content()},
      {:wind_shift, 2, runtime_wind_shift_content()}
    ]
  end

  defp runtime_calibration_content do
    {:ok, observer} =
      CalibrationObserver.start_link(
        name: nil,
        sample_ms: 0,
        dir: nil,
        calibration: nil,
        boat_identifier: "boat-runtime",
        sender: fn _channel, _update -> :ok end,
        now_fn: fn -> 10_000 end,
        utc_now_fn: fn -> ~U[2026-08-10 12:00:00Z] end,
        sync_ms: 60_000,
        persist_ms: 60_000,
        legs: [min_duration_s: 30.0]
      )

    assert {:ok, snapshot} = CalibrationObserver.snapshot(observer)
    assert {:ok, content} = CalibrationRuntime.project(snapshot)
    content
  end

  defp runtime_polar_content do
    bins = Bins.new()
    gate = Gate.new(min_dwell: 1)
    assert {:ok, admission_hash} = PolarSnapshot.policy_hash(gate, 0.3, 1, 0.9)
    assert {:ok, learner} = PolarSnapshot.capture("boat-runtime", admission_hash, bins, 0.9, 10, %{})

    snapshot = %{
      version: 1,
      captured_at_utc_ms: 1_786_536_000_000,
      authority: %{boat_identifier: "boat-runtime"},
      policy: %{
        admission_hash: admission_hash,
        gate: Map.from_struct(gate),
        min_stw_mps: 0.3,
        window_size: 1,
        p: 0.9,
        sample_ms: 60_000,
        sync_ms: 60_000,
        persist_ms: 60_000,
        persistence_enabled: true,
        bins: Map.from_struct(bins)
      },
      learner: %{source_generation: 10, content: learner},
      upstream_seq: 41,
      window: [],
      sync: %{dirty_keys: [], last_sync_age_ms: 45_000},
      persistence_phase: %{dirty_keys: [], force: true, last_persist_age_ms: 30_000},
      tick: %{remaining_ms: 45_000}
    }

    assert {:ok, content} = PolarRuntime.project(snapshot)
    content
  end

  defp runtime_wind_shift_content do
    {:ok, clock} =
      Agent.start_link(fn ->
        %{monotonic_ms: 10_000, utc: ~U[2026-08-12 12:00:00Z]}
      end)

    {:ok, observer} =
      WindShiftObserver.start_link(
        name: nil,
        sample_ms: 0,
        dir: nil,
        config: nil,
        commands: nil,
        boat_identifier: "boat-runtime",
        broadcast_enabled: false,
        authority_fn: fn ->
          {:ok, %{device_id: @device_id, credential_epoch: 7, storage_epoch: @storage_epoch}}
        end,
        signals_fn: fn -> %{"true_wind_direction" => {200.0, 10_000}} end,
        now_fn: fn -> Agent.get(clock, & &1.monotonic_ms) end,
        utc_now_fn: fn -> Agent.get(clock, & &1.utc) end,
        put_signals_fn: fn _updates, _monotonic_ms -> :ok end,
        sender: fn _channel, _update -> :ok end,
        transmit_fn: fn _priority, _pgn, _payload -> :ok end
      )

    :ok = WindShiftObserver.tick(observer)
    assert {:ok, snapshot} = WindShiftObserver.snapshot(observer)
    assert {:ok, content} = WindShiftRuntime.project(snapshot)
    content
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        device_id: @device_id,
        local_credential_epoch: 7,
        local_storage_epoch: @storage_epoch,
        origin_credential_epoch: 7,
        origin_storage_epoch: @storage_epoch,
        sequence: 11,
        kind: :calibration,
        schema_version: 0x0001,
        source_generation: 42,
        parent_hash: @parent_hash,
        content: content(:calibration),
        accepted: false
      },
      overrides
    )
  end

  defp content(:calibration) do
    %{
      "awa_estimators" => [],
      "aws_estimators" => [],
      "prev_applied" => [],
      "seq" => 0,
      "stw_estimators" => []
    }
  end

  defp content(:wind_shift) do
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

  defp content(:polar) do
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

  defp large_polar_content do
    polar_content(600)
  end

  defp near_semantic_cap_polar_content do
    polar_content(36_500)
  end

  defp polar_content(cell_count) do
    %{
      "cells" =>
        for(
          tws_bin <- 0..(cell_count - 1),
          do: polar_cell(tws_bin, rem(tws_bin, 72))
        ),
      "max_tws_mps" => 65_535.0,
      "p" => 0.9,
      "twa_width_deg" => 2.5,
      "tws_width_mps" => 1.0
    }
  end

  defp polar_cell(tws_bin, twa_bin) do
    %{
      "count" => 5,
      "quantile" => %{
        "buffer" => [],
        "n" => [2, 3, 4],
        "np" => [1.0, 2.8, 4.6, 4.8, 5.0],
        "q" => [1.0, 2.0, 3.0, 4.0, 5.0]
      },
      "twa_bin" => twa_bin,
      "tws_bin" => tws_bin
    }
  end
end
