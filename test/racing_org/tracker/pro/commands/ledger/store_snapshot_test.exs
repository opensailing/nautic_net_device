defmodule RacingOrg.Tracker.Pro.Commands.Ledger.StoreSnapshotTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands.Ledger.{Snapshot, Store}

  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @other_device_id Base.decode16!("11112233445566778899aabbccddeeff", case: :lower)
  @storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @other_storage_epoch Base.decode16!("102132435465768798a9bacbdcedfe0f", case: :lower)

  @pre_rename_faults [
    :temp_opened,
    :temp_chmodded,
    :temp_written,
    :temp_synced,
    :temp_closed,
    :before_rename
  ]
  @post_rename_faults [:renamed, :parent_synced]

  setup do
    root = Path.join(System.tmp_dir!(), "command_ledger_snapshot_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, path: Path.join(root, "ledger.snapshot")}
  end

  test "creates and reopens one exact identity-scoped snapshot", %{path: path} do
    assert {:ok, store} = open_store(path)

    assert %Snapshot{
             device_id: @device_id,
             credential_epoch: 7,
             storage_epoch: @storage_epoch,
             command_epoch: 0,
             next_expected_sequence: 1,
             outcomes: %{},
             pending_intent: nil
           } = Store.snapshot(store)

    assert Store.usage(store) == %{outcomes: 0, result_bytes: 0}
    assert {:ok, reopened} = open_store(path)
    assert Store.snapshot(reopened) == Store.snapshot(store)
  end

  test "corrupt state blocks fail-closed and is never replaced with empty state", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "corrupt-ledger")
    before = File.read!(path)

    assert {:error, :corrupt_command_ledger} = open_store(path)
    assert File.read!(path) == before
  end

  test "unknown snapshot versions block fail-closed and are never replaced", %{path: path} do
    assert {:ok, _store} = open_store(path)
    bytes = File.read!(path)
    domain = Snapshot.domain()
    <<^domain::binary, _version, rest::binary>> = bytes
    unknown = domain <> <<2>> <> rest
    File.write!(path, unknown)

    assert {:error, :unsupported_command_ledger_version} = open_store(path)
    assert File.read!(path) == unknown
  end

  test "every durable identity mismatch blocks without rewriting authority", %{path: path} do
    assert {:ok, _store} = open_store(path)
    before = File.read!(path)

    for overrides <- [
          [device_id: @other_device_id],
          [credential_epoch: 8],
          [storage_epoch: @other_storage_epoch]
        ] do
      assert {:error, :command_ledger_identity_mismatch} = open_store(path, overrides)
      assert File.read!(path) == before
    end
  end

  test "pre-rename failures do not claim initialization and post-rename failures use authoritative read-back", %{
    root: root
  } do
    for stage <- @pre_rename_faults do
      path = Path.join([root, Atom.to_string(stage), "ledger.snapshot"])

      assert {:error, {:write_command_ledger, {:fault_injected, ^stage, :power_loss}}} =
               open_store(path, fault_injector: fail_at(stage))

      refute File.exists?(path)
      assert {:ok, clean} = open_store(path)
      assert Store.snapshot(clean).next_expected_sequence == 1
    end

    for stage <- @post_rename_faults do
      path = Path.join([root, Atom.to_string(stage), "ledger.snapshot"])

      assert {:ok, store} = open_store(path, fault_injector: fail_at(stage))
      assert File.exists?(path)
      assert Store.snapshot(store).next_expected_sequence == 1
      assert {:ok, reopened} = open_store(path)
      assert Store.snapshot(reopened) == Store.snapshot(store)
    end
  end

  test "invalid options never create authority", %{path: path} do
    for overrides <- [
          [device_id: <<0::128>>],
          [credential_epoch: -1],
          [storage_epoch: <<0::128>>],
          [max_outcomes: 0],
          [max_result_bytes: 0]
        ] do
      assert {:error, _reason} = open_store(path, overrides)
      refute File.exists?(path)
    end
  end

  defp open_store(path, overrides \\ []) do
    defaults = [
      device_id: @device_id,
      credential_epoch: 7,
      storage_epoch: @storage_epoch,
      max_outcomes: 8,
      max_result_bytes: 1_024
    ]

    Store.open(path, Keyword.merge(defaults, overrides))
  end

  defp fail_at(stage) do
    fn
      ^stage -> {:error, :power_loss}
      _other -> :ok
    end
  end
end
