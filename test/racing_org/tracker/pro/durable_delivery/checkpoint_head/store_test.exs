defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.{Record, Store}
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  @device_id Base.decode16!("0f1e2d3c4b5a69788796a5b4c3d2e1f0", case: :lower)
  @other_device_id Base.decode16!("aabbccddeeff00112233445566778899", case: :lower)
  @storage_epoch Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @other_storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @credential_epoch 7

  setup do
    base = Path.join(System.tmp_dir!(), "checkpoint_head_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  describe "new/1" do
    test "requires an exact bound identity", ctx do
      assert {:error, :invalid_device_id} = Store.new(opts(ctx, device_id: <<0::128>>))
      assert {:error, :invalid_device_id} = Store.new(opts(ctx, device_id: <<1, 2>>))

      assert {:error, :invalid_credential_epoch} =
               Store.new(opts(ctx, credential_epoch: -1))

      assert {:error, :invalid_credential_epoch} =
               Store.new(opts(ctx, credential_epoch: 0x1_0000_0000))

      assert {:error, :invalid_storage_epoch} = Store.new(opts(ctx, storage_epoch: <<0::128>>))
      assert {:error, :invalid_storage_epoch} = Store.new(opts(ctx, storage_epoch: <<1, 2, 3>>))
      assert {:error, :invalid_base_dir} = Store.new(opts(ctx, base_dir: ""))
      assert {:error, :invalid_options} = Store.new(:not_a_list)
    end
  end

  describe "head/2" do
    test "is empty for every registered kind on a fresh store", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      for {kind, _code, _schema} <- Contract.checkpoint_kinds() do
        assert :empty = Store.head(store, kind)
      end
    end

    test "rejects unknown kinds", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:error, :unknown_checkpoint_kind} = Store.head(store, :telemetry)
      assert {:error, :unknown_checkpoint_kind} = Store.head(store, "calibration")
    end
  end

  describe "put/2 record-hash parent compare-and-swap" do
    test "accepts a first record only against the genesis parent", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:error, :checkpoint_parent_mismatch} =
               Store.put(store, put_attrs(parent_hash: :binary.copy(<<0xB2>>, 32)))

      assert {:ok, first} = Store.put(store, put_attrs())
      assert first.parent_hash == Record.genesis_parent()
      assert {:ok, ^first} = Store.head(store, :calibration)
    end

    test "chains the next record from the current record hash", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, second} =
               Store.put(
                 store,
                 put_attrs(sequence: 2, source_generation: 43, parent_hash: first.checkpoint_hash)
               )

      assert second.parent_hash == first.checkpoint_hash
      assert {:ok, ^second} = Store.head(store, :calibration)
    end

    test "rejects a stale parent from a superseded head", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, second} =
               Store.put(
                 store,
                 put_attrs(sequence: 2, source_generation: 43, parent_hash: first.checkpoint_hash)
               )

      assert {:error, :checkpoint_parent_mismatch} =
               Store.put(
                 store,
                 put_attrs(sequence: 3, source_generation: 44, parent_hash: first.checkpoint_hash)
               )

      assert {:ok, ^second} = Store.head(store, :calibration)
    end

    test "rejects an ABA write whose parent has the same sequence and content but a different record hash",
         ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      # The writer observed head A and prepared a successor chained from it.
      assert {:ok, observed} = Store.put(store, put_attrs(sequence: 5, source_generation: 42))

      # The head is then replaced by A' — SAME sequence, SAME content, different
      # record hash, because the source generation differs.
      assert {:ok, replacement} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 5,
                   source_generation: 43,
                   parent_hash: observed.checkpoint_hash
                 )
               )

      assert replacement.sequence == observed.sequence
      assert replacement.content == observed.content
      refute replacement.checkpoint_hash == observed.checkpoint_hash

      # A sequence-only fence would admit this; a record-hash fence must not.
      assert {:error, :checkpoint_parent_mismatch} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 6,
                   source_generation: 44,
                   parent_hash: observed.checkpoint_hash
                 )
               )

      assert {:ok, ^replacement} = Store.head(store, :calibration)
    end

    test "keeps each kind's chain independent", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, calibration} = Store.put(store, put_attrs())

      assert {:ok, polar} =
               Store.put(store, put_attrs(kind: :polar, schema_version: 2, content: content(:polar)))

      assert {:ok, wind} =
               Store.put(
                 store,
                 put_attrs(kind: :wind_shift, content: content(:wind_shift))
               )

      assert polar.parent_hash == Record.genesis_parent()
      assert wind.parent_hash == Record.genesis_parent()

      assert {:ok, ^calibration} = Store.head(store, :calibration)
      assert {:ok, ^polar} = Store.head(store, :polar)
      assert {:ok, ^wind} = Store.head(store, :wind_shift)

      # A calibration parent can never advance the polar chain.
      assert {:error, :checkpoint_parent_mismatch} =
               Store.put(
                 store,
                 put_attrs(
                   kind: :polar,
                   schema_version: 2,
                   content: content(:polar),
                   sequence: 2,
                   parent_hash: calibration.checkpoint_hash
                 )
               )
    end

    test "is idempotent for an exact replay of the current head", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())
      assert {:ok, ^first} = Store.put(store, put_attrs())
      assert {:ok, ^first} = Store.head(store, :calibration)
    end

    test "rejects a replay that collides on identity but differs in content", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())

      divergent = content(:calibration) |> Map.put("seq", 9)

      assert {:error, :checkpoint_parent_mismatch} =
               Store.put(store, put_attrs(content: divergent))
    end

    test "rejects malformed kinds, schemas, content, and secrets without touching the head", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      chained = [sequence: 2, source_generation: 43, parent_hash: first.checkpoint_hash]

      assert {:error, :unknown_checkpoint_kind} =
               Store.put(store, put_attrs(chained ++ [kind: :telemetry]))

      assert {:error, :unsupported_checkpoint_schema} =
               Store.put(store, put_attrs(chained ++ [schema_version: 7]))

      assert {:error, :invalid_checkpoint_content} =
               Store.put(store, put_attrs(chained ++ [content: %{"seq" => 0}]))

      assert {:error, :checkpoint_secret_forbidden} =
               Store.put(
                 store,
                 put_attrs(chained ++ [content: content(:calibration) |> Map.put("wifi_psk", "hunter2")])
               )

      assert {:error, :invalid_delivery_sequence} =
               Store.put(store, put_attrs(chained ++ [sequence: 0]))

      assert {:ok, ^first} = Store.head(store, :calibration)
    end
  end

  describe "hydrate/2" do
    test "installs a backend-accepted record bound to the CURRENT identity", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:ok, hydrated} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   origin_credential_epoch: 3,
                   origin_storage_epoch: @other_storage_epoch
                 )
               )

      assert hydrated.accepted
      assert hydrated.local_credential_epoch == @credential_epoch
      assert hydrated.local_storage_epoch == @storage_epoch
      assert hydrated.origin_credential_epoch == 3
      assert hydrated.origin_storage_epoch == @other_storage_epoch

      assert {:ok, ^hydrated} = Store.head(store, :calibration)
    end

    test "lets a later local record chain from the hydrated record hash", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:ok, hydrated} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   origin_credential_epoch: 3,
                   origin_storage_epoch: @other_storage_epoch
                 )
               )

      assert {:ok, next} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: hydrated.sequence + 1,
                   source_generation: 43,
                   parent_hash: hydrated.checkpoint_hash
                 )
               )

      refute next.accepted
      assert next.origin_credential_epoch == @credential_epoch
      assert next.origin_storage_epoch == @storage_epoch
      assert next.parent_hash == hydrated.checkpoint_hash
    end

    test "replaces a divergent local head without a parent match", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, local} = Store.put(store, put_attrs(sequence: 9, source_generation: 99))

      assert {:ok, hydrated} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   origin_credential_epoch: 3,
                   origin_storage_epoch: @other_storage_epoch
                 )
               )

      refute hydrated.checkpoint_hash == local.checkpoint_hash
      assert {:ok, ^hydrated} = Store.head(store, :calibration)
    end

    test "verifies the presented record hash against the frozen preimage", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:error, :checkpoint_hash_mismatch} =
               Store.hydrate(
                 store,
                 hydrate_attrs(checkpoint_hash: :binary.copy(<<0xDD>>, 32))
               )

      assert :empty = Store.head(store, :calibration)
    end

    test "rejects hydration addressed to another device", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:error, :device_mismatch} =
               Store.hydrate(store, hydrate_attrs(device_id: @other_device_id))

      assert :empty = Store.head(store, :calibration)
    end

    test "rejects hydration bound to a stale credential or storage identity", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:error, :credential_epoch_mismatch} =
               Store.hydrate(store, hydrate_attrs(credential_epoch: @credential_epoch - 1))

      assert {:error, :storage_epoch_mismatch} =
               Store.hydrate(store, hydrate_attrs(storage_epoch: @other_storage_epoch))

      assert :empty = Store.head(store, :calibration)
    end

    test "rejects secret-capable hydrated content", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      poisoned = content(:calibration) |> Map.put("credential", "x")

      # The secret screen must fire BEFORE the presented record hash is compared,
      # so a poisoned payload is never hashed even to reject it.
      assert {:error, :checkpoint_secret_forbidden} =
               Store.hydrate(
                 store,
                 hydrate_attrs(content: poisoned, checkpoint_hash: :binary.copy(<<0xAB>>, 32))
               )

      assert :empty = Store.head(store, :calibration)
    end
  end

  describe "identity fencing on reopen" do
    test "fails closed and preserves bytes when the persisted device differs", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, foreign} = Store.new(opts(ctx, device_id: @other_device_id))
      assert {:error, :device_mismatch} = Store.head(foreign, :calibration)
      assert {:error, :device_mismatch} = Store.put(foreign, put_attrs())

      assert {:ok, ^first} = Store.head(store, :calibration)
    end

    test "fails closed when the persisted local credential epoch is stale", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, rotated} = Store.new(opts(ctx, credential_epoch: @credential_epoch + 1))
      assert {:error, :credential_epoch_mismatch} = Store.head(rotated, :calibration)

      assert {:error, :credential_epoch_mismatch} =
               Store.put(rotated, put_attrs(parent_hash: first.checkpoint_hash))

      assert {:ok, ^first} = Store.head(store, :calibration)
    end

    test "fails closed when the persisted storage epoch differs", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, replaced} = Store.new(opts(ctx, storage_epoch: @other_storage_epoch))
      assert {:error, :storage_epoch_mismatch} = Store.head(replaced, :calibration)
      assert {:ok, ^first} = Store.head(store, :calibration)
    end

    test "lets hydration rebind a fenced head to the new identity", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, rotated} = Store.new(opts(ctx, credential_epoch: @credential_epoch + 1))
      assert {:error, :credential_epoch_mismatch} = Store.head(rotated, :calibration)

      assert {:ok, hydrated} =
               Store.hydrate(
                 rotated,
                 hydrate_attrs(
                   credential_epoch: @credential_epoch + 1,
                   sequence: first.sequence,
                   source_generation: first.source_generation,
                   parent_hash: first.parent_hash,
                   origin_credential_epoch: @credential_epoch,
                   origin_storage_epoch: @storage_epoch
                 )
               )

      assert hydrated.checkpoint_hash == first.checkpoint_hash
      assert {:ok, ^hydrated} = Store.head(rotated, :calibration)
    end

    test "reopening under the same identity restores the exact head", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, reopened} = Store.new(opts(ctx))
      assert {:ok, ^first} = Store.head(reopened, :calibration)
    end
  end

  describe "corruption" do
    test "reports a corrupt head per kind without blocking the others", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _calibration} = Store.put(store, put_attrs())

      assert {:ok, polar} =
               Store.put(store, put_attrs(kind: :polar, schema_version: 2, content: content(:polar)))

      File.write!(Store.head_path(store, :calibration), <<0xDE, 0xAD, 0xBE, 0xEF>>)

      assert {:error, :corrupt_checkpoint_head} = Store.head(store, :calibration)
      assert {:ok, ^polar} = Store.head(store, :polar)
    end

    test "refuses to advance a corrupt chain rather than silently restarting it", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())
      File.write!(Store.head_path(store, :calibration), <<0>>)

      assert {:error, :corrupt_checkpoint_head} = Store.put(store, put_attrs())

      assert {:error, :corrupt_checkpoint_head} =
               Store.put(store, put_attrs(parent_hash: Record.genesis_parent()))
    end

    test "lets hydration replace a corrupt head", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())
      File.write!(Store.head_path(store, :calibration), <<0>>)

      assert {:ok, hydrated} = Store.hydrate(store, hydrate_attrs())
      assert {:ok, ^hydrated} = Store.head(store, :calibration)
    end

    test "treats a truncated tail as corruption, never as an empty chain", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())

      path = Store.head_path(store, :calibration)
      bytes = File.read!(path)
      File.write!(path, binary_part(bytes, 0, byte_size(bytes) - 3))

      assert {:error, :corrupt_checkpoint_head} = Store.head(store, :calibration)
    end
  end

  describe "atomic persistence outcomes" do
    test "a pre-rename failure is typed and leaves the previous head intact", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      faulted = fault_store(ctx, :before_rename)

      assert {:error, {:pre_rename, _reason}} =
               Store.put(
                 faulted,
                 put_attrs(sequence: 2, source_generation: 43, parent_hash: first.checkpoint_hash)
               )

      assert {:ok, ^first} = Store.head(store, :calibration)
      refute_temporary_artifacts(store, :calibration)
    end

    test "a post-rename failure is reported as durability-uncertain", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      faulted = fault_store(ctx, :renamed)

      assert {:error, {:durability_uncertain, _reason}} =
               Store.put(
                 faulted,
                 put_attrs(sequence: 2, source_generation: 43, parent_hash: first.checkpoint_hash)
               )

      # The rename itself already happened, so the successor is the head on reopen.
      assert {:ok, second} = Store.head(store, :calibration)
      assert second.sequence == 2
      assert second.parent_hash == first.checkpoint_hash
    end

    test "a pre-rename hydration failure leaves the store empty", ctx do
      faulted = fault_store(ctx, :before_rename)

      assert {:error, {:pre_rename, _reason}} = Store.hydrate(faulted, hydrate_attrs())

      assert {:ok, store} = Store.new(opts(ctx))
      assert :empty = Store.head(store, :calibration)
    end

    test "writes head files with restrictive permissions", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())

      assert {:ok, %File.Stat{mode: mode}} = File.stat(Store.head_path(store, :calibration))
      assert Bitwise.band(mode, 0o777) == 0o600

      assert {:ok, %File.Stat{mode: dir_mode}} =
               File.stat(Path.dirname(Store.head_path(store, :calibration)))

      assert Bitwise.band(dir_mode, 0o777) == 0o700
    end
  end

  describe "secret and identifier hygiene" do
    test "never writes plaintext secrets or raw identifiers into head bytes", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())

      bytes = File.read!(Store.head_path(store, :calibration))

      refute String.contains?(bytes, "hunter2")
      refute String.contains?(bytes, "psk")
      refute String.contains?(bytes, "passphrase")
    end

    test "sanitized status reports counts and flags only", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())

      assert %{} = status = Store.status(store)

      assert status == %{
               kinds: length(Contract.checkpoint_kinds()),
               present: 1,
               accepted: 0,
               corrupt: 0,
               fenced: 0
             }

      assert {:ok, _hydrated} =
               Store.hydrate(store, hydrate_attrs(kind: :wind_shift, content: content(:wind_shift)))

      assert %{present: 2, accepted: 1} = Store.status(store)

      File.write!(Store.head_path(store, :calibration), <<0>>)
      assert %{corrupt: 1} = Store.status(store)
    end
  end

  defp opts(ctx, overrides \\ []) do
    Keyword.merge(
      [
        base_dir: ctx.base,
        device_id: @device_id,
        credential_epoch: @credential_epoch,
        storage_epoch: @storage_epoch
      ],
      overrides
    )
  end

  defp fault_store(ctx, stage) do
    assert {:ok, store} =
             Store.new(
               opts(ctx,
                 fault_injector: fn
                   ^stage -> {:error, :simulated}
                   _other -> :ok
                 end
               )
             )

    store
  end

  defp refute_temporary_artifacts(store, kind) do
    directory = Path.dirname(Store.head_path(store, kind))
    assert {:ok, entries} = File.ls(directory)
    assert Enum.reject(entries, &(not String.contains?(&1, ".tmp."))) == []
  end

  defp put_attrs(overrides \\ []) do
    Enum.into(
      overrides,
      %{
        kind: :calibration,
        schema_version: 0x0001,
        sequence: 1,
        source_generation: 42,
        parent_hash: Record.genesis_parent(),
        content: content(:calibration)
      }
    )
  end

  defp hydrate_attrs(overrides \\ []) do
    attrs =
      Enum.into(
        overrides,
        %{
          device_id: @device_id,
          credential_epoch: @credential_epoch,
          storage_epoch: @storage_epoch,
          origin_credential_epoch: @credential_epoch,
          origin_storage_epoch: @storage_epoch,
          kind: :calibration,
          schema_version: 0x0001,
          sequence: 1,
          source_generation: 42,
          parent_hash: Record.genesis_parent(),
          content: content(:calibration)
        }
      )

    Map.put_new_lazy(attrs, :checkpoint_hash, fn -> expected_hash(attrs) end)
  end

  defp expected_hash(attrs) do
    assert {:ok, record} =
             Record.build(%{
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
               accepted: true
             })

    record.checkpoint_hash
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
    %{
      "last_summary" => nil,
      "pending_events" => [],
      "pending_timeline" => [],
      "seq" => 0,
      "session" => nil
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
end
