defmodule RacingOrg.Tracker.Pro.DurableNamespaceTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableNamespace
  alias RacingOrg.Tracker.Pro.DurableNamespace.Leaf

  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @other_device_id Base.decode16!("10112233445566778899aabbccddeeff", case: :lower)
  @storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @other_storage_epoch Base.decode16!("efeeddccbbaa99887766554433221100", case: :lower)

  describe "leaf/3" do
    test "builds a deterministic full-identity ledger leaf in device/storage/credential order" do
      root = canonical_root()

      assert {:ok, %Leaf{} = leaf} = DurableNamespace.leaf(root, :ledger, identity())

      assert leaf.root == root
      assert leaf.kind == :ledger
      assert leaf.identity == identity()
      assert leaf.lineage == {@device_id, @storage_epoch}
      assert leaf.credential_epoch == 7

      assert leaf.relative_path ==
               Path.join([
                 "device-00112233445566778899aabbccddeeff",
                 "storage-ffeeddccbbaa99887766554433221100",
                 "credential-00000007",
                 "ledger"
               ])

      assert leaf.path == Path.join(root, leaf.relative_path)
      assert leaf.device_path == Path.join(root, "device-00112233445566778899aabbccddeeff")

      assert leaf.storage_path ==
               Path.join(leaf.device_path, "storage-ffeeddccbbaa99887766554433221100")

      assert leaf.credential_path == Path.join(leaf.storage_path, "credential-00000007")
    end

    test "builds a distinct outbox leaf under the same full-identity parent" do
      root = canonical_root()

      assert {:ok, ledger} = DurableNamespace.leaf(root, :ledger, identity())
      assert {:ok, outbox} = DurableNamespace.leaf(root, :outbox, identity())

      assert outbox.kind == :outbox
      assert outbox.credential_path == ledger.credential_path
      assert outbox.path == Path.join(outbox.credential_path, "outbox")
      refute outbox.path == ledger.path
    end

    test "changes the leaf path when any durable identity field changes" do
      root = canonical_root()

      identities = [
        identity(),
        identity(%{device_id: @other_device_id}),
        identity(%{credential_epoch: 8}),
        identity(%{storage_epoch: @other_storage_epoch})
      ]

      paths = Enum.map(identities, fn value -> leaf_path!(root, :ledger, value) end)

      assert length(Enum.uniq(paths)) == length(identities)
    end

    test "accepts the complete u32 credential epoch range" do
      root = canonical_root()

      assert {:ok, zero} = DurableNamespace.leaf(root, :ledger, identity(%{credential_epoch: 0}))

      assert zero.credential_path ==
               Path.join(zero.storage_path, "credential-00000000")

      assert {:ok, maximum} =
               DurableNamespace.leaf(root, :ledger, identity(%{credential_epoch: 0xFFFF_FFFF}))

      assert maximum.credential_path ==
               Path.join(maximum.storage_path, "credential-ffffffff")
    end

    test "rejects invalid or open identity shapes exactly" do
      root = canonical_root()

      invalid = [
        {%{}, :invalid_identity},
        {Map.put(identity(), :boot_id, @device_id), :invalid_identity},
        {%{"device_id" => @device_id, "credential_epoch" => 7, "storage_epoch" => @storage_epoch}, :invalid_identity},
        {identity(%{device_id: <<0::128>>}), :invalid_device_id},
        {identity(%{device_id: binary_part(@device_id, 0, 15)}), :invalid_device_id},
        {identity(%{device_id: "00112233445566778899aabbccddeeff"}), :invalid_device_id},
        {identity(%{credential_epoch: -1}), :invalid_credential_epoch},
        {identity(%{credential_epoch: 0x1_0000_0000}), :invalid_credential_epoch},
        {identity(%{credential_epoch: 7.0}), :invalid_credential_epoch},
        {identity(%{storage_epoch: <<0::128>>}), :invalid_storage_epoch},
        {identity(%{storage_epoch: binary_part(@storage_epoch, 0, 15)}), :invalid_storage_epoch},
        {identity(%{storage_epoch: "ffeeddccbbaa99887766554433221100"}), :invalid_storage_epoch}
      ]

      Enum.each(invalid, fn {value, reason} ->
        assert {:error, ^reason} = DurableNamespace.leaf(root, :ledger, value)
      end)
    end

    test "rejects invalid kinds and noncanonical roots" do
      root = canonical_root()

      assert {:error, :invalid_kind} = DurableNamespace.leaf(root, :checkpoint, identity())
      assert {:error, :invalid_root} = DurableNamespace.leaf("relative", :ledger, identity())
      assert {:error, :invalid_root} = DurableNamespace.leaf(root <> "/.", :ledger, identity())
      assert {:error, :invalid_root} = DurableNamespace.leaf(root <> <<0>>, :ledger, identity())
    end
  end

  describe "parse_leaf/2" do
    test "reverses a generated path into stable enumeration metadata" do
      root = canonical_root()
      assert {:ok, generated} = DurableNamespace.leaf(root, :outbox, identity())

      assert {:ok, parsed} = DurableNamespace.parse_leaf(root, generated.path)
      assert parsed == generated
    end

    test "exposes stable lineage and credential metadata for current versus historical classification" do
      root = canonical_root()
      current_identity = identity(%{credential_epoch: 9})
      historical_identity = identity(%{credential_epoch: 8})

      assert {:ok, current_path} = DurableNamespace.leaf(root, :outbox, current_identity)
      assert {:ok, historical_path} = DurableNamespace.leaf(root, :outbox, historical_identity)
      assert {:ok, current} = DurableNamespace.parse_leaf(root, current_path.path)
      assert {:ok, historical} = DurableNamespace.parse_leaf(root, historical_path.path)

      assert current.lineage == historical.lineage
      assert current.credential_epoch == 9
      assert historical.credential_epoch == 8
      refute current.path == historical.path
      assert current.identity == current_identity
      assert historical.identity == historical_identity
    end

    test "rejects paths outside the root, traversal, dot components, and extra depth" do
      root = canonical_root()
      assert {:ok, leaf} = DurableNamespace.leaf(root, :ledger, identity())

      assert {:error, :invalid_leaf_path} =
               DurableNamespace.parse_leaf(Path.dirname(root), leaf.path)

      assert {:error, :invalid_leaf_path} =
               DurableNamespace.parse_leaf(root, root <> "/../" <> Path.basename(leaf.path))

      assert {:error, :invalid_leaf_path} =
               DurableNamespace.parse_leaf(root, root <> "/./" <> leaf.relative_path)

      assert {:error, :invalid_leaf_path} =
               DurableNamespace.parse_leaf(root, Path.join(leaf.path, "extra"))
    end

    test "rejects noncanonical, ambiguous, and unsafe encoded components" do
      root = canonical_root()

      invalid_relative_paths = [
        Path.join([
          "device-00112233445566778899AABBCCDDEEFF",
          "storage-ffeeddccbbaa99887766554433221100",
          "credential-00000007",
          "ledger"
        ]),
        Path.join([
          "device-00112233445566778899aabbccddeef／",
          "storage-ffeeddccbbaa99887766554433221100",
          "credential-00000007",
          "ledger"
        ]),
        Path.join([
          "device-00112233445566778899aabbccddeeff",
          "storage-ffeeddccbbaa99887766554433221100",
          "credential-7",
          "ledger"
        ]),
        Path.join([
          "device-00112233445566778899aabbccddeeff",
          "storage-ffeeddccbbaa99887766554433221100",
          "credential-00000007",
          "commands.ledger"
        ]),
        Path.join([
          "device-00112233445566778899aabbccddeeff",
          "storage-ffeeddccbbaa99887766554433221100",
          "credential-00000007",
          "outbox" <> <<0>> <> "suffix"
        ])
      ]

      Enum.each(invalid_relative_paths, fn relative_path ->
        assert {:error, :invalid_leaf_path} =
                 DurableNamespace.parse_leaf(root, Path.join(root, relative_path))
      end)
    end
  end

  defp canonical_root do
    Path.join(System.tmp_dir!(), "tracker-durable-namespace")
  end

  defp identity(overrides \\ %{}) do
    Map.merge(
      %{
        device_id: @device_id,
        credential_epoch: 7,
        storage_epoch: @storage_epoch
      },
      overrides
    )
  end

  defp leaf_path!(root, kind, value) do
    assert {:ok, leaf} = DurableNamespace.leaf(root, kind, value)
    leaf.path
  end
end
