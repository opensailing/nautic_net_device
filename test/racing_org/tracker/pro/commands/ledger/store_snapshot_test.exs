defmodule RacingOrg.Tracker.Pro.Commands.Ledger.StoreSnapshotTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands.Ledger.{Snapshot, Store}
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem, as: RealFileSystem

  defmodule CleanupFailureFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def read(device, count), do: RealFileSystem.read(device, count)
    def list_dir(path), do: File.ls(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def file_info(device), do: RealFileSystem.file_info(device)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def mkdir(path), do: RealFileSystem.mkdir(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)
    def open(path, modes), do: RealFileSystem.open(path, modes)
    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)
    def rename(source, destination), do: RealFileSystem.rename(source, destination)
    def remove(_path), do: {:error, :simulated_remove_failure}
    def rmdir(path), do: RealFileSystem.rmdir(path)
  end

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
  @uncertain_faults [:renamed]
  @durable_faults [:parent_synced]

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

  test "reopen reclaims only exact ledger orphan temporary artifacts", %{root: root, path: path} do
    assert {:ok, store} = open_store(path)
    authority = File.read!(path)
    orphan = path <> ".tmp.ABCDEFGHIJKLMNOP"
    malformed = path <> ".tmp.not-random"
    unrelated = Path.join(root, "other.snapshot.tmp.ABCDEFGHIJKLMNOP")

    for artifact <- [orphan, malformed, unrelated], do: File.write!(artifact, "non-sensitive-state")

    assert {:ok, reopened} = open_store(path)
    assert Store.snapshot(reopened) == Store.snapshot(store)
    assert File.read!(path) == authority
    refute File.exists?(orphan)
    assert File.exists?(malformed)
    assert File.exists?(unrelated)
  end

  test "initial open reclaims orphan temps before creating authority", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    orphan = path <> ".tmp.ABCDEFGHIJKLMNOP"
    File.write!(orphan, "non-sensitive-state")

    assert {:ok, store} = open_store(path)
    assert File.exists?(path)
    refute File.exists?(orphan)
    assert Store.snapshot(store).next_expected_sequence == 1
  end

  test "initial open fails closed when orphan cleanup cannot complete", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    orphan = path <> ".tmp.ABCDEFGHIJKLMNOP"
    File.write!(orphan, "non-sensitive-state")

    assert {:error, {:orphan_temp_cleanup, {:remove_temp, :simulated_remove_failure}}} =
             open_store(path, file_system: CleanupFailureFileSystem)

    refute File.exists?(path)
    assert File.exists?(orphan)
  end

  test "reopen validates durable identity before reclaiming orphan temps", %{path: path} do
    assert {:ok, _store} = open_store(path)
    orphan = path <> ".tmp.ABCDEFGHIJKLMNOP"
    File.write!(orphan, "non-sensitive-state")

    assert {:error, :command_ledger_identity_mismatch} =
             open_store(path, device_id: @other_device_id)

    assert File.exists?(orphan)
  end

  test "reopen fails closed with typed orphan cleanup errors", %{path: path} do
    assert {:ok, _store} = open_store(path)
    orphan = path <> ".tmp.ABCDEFGHIJKLMNOP"
    File.write!(orphan, "non-sensitive-state")

    assert {:error, {:orphan_temp_cleanup, {:remove_temp, :simulated_remove_failure}}} =
             open_store(path, file_system: CleanupFailureFileSystem)

    assert File.exists?(orphan)
  end

  test "corrupt state blocks fail-closed and is never replaced with empty state", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "corrupt-ledger")
    orphan = path <> ".tmp.ABCDEFGHIJKLMNOP"
    File.write!(orphan, "non-sensitive-state")
    before = File.read!(path)

    assert {:error, :corrupt_command_ledger} = open_store(path)
    assert File.read!(path) == before
    assert File.exists?(orphan)
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

  test "initialization releases success only after the parent directory is durable", %{root: root} do
    for stage <- @pre_rename_faults do
      path = Path.join([root, Atom.to_string(stage), "ledger.snapshot"])

      assert {:error, {:write_command_ledger, {:pre_rename, {:fault_injected, ^stage, :power_loss}}}} =
               open_store(path, fault_injector: fail_at(stage))

      refute File.exists?(path)
      assert {:ok, clean} = open_store(path)
      assert Store.snapshot(clean).next_expected_sequence == 1
    end

    for stage <- @uncertain_faults do
      path = Path.join([root, Atom.to_string(stage), "ledger.snapshot"])

      assert {:error, {:command_ledger_durability_uncertain, {:fault_injected, ^stage, :power_loss}}} =
               open_store(path, fault_injector: fail_at(stage))

      assert File.exists?(path)
      assert {:ok, reopened} = open_store(path)
      assert Store.snapshot(reopened).next_expected_sequence == 1
    end

    for stage <- @durable_faults do
      path = Path.join([root, Atom.to_string(stage), "ledger.snapshot"])

      assert {:ok, store} = open_store(path, fault_injector: fail_at(stage))
      assert {:ok, reopened} = open_store(path)
      assert Store.snapshot(reopened) == Store.snapshot(store)
    end
  end

  test "temp-shaped destinations are reserved before filesystem I/O", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    ambiguous_path = path <> ".tmp.ABCD-EFGH_IJKLMN"
    File.write!(path, "existing-authority-sentinel")
    File.write!(ambiguous_path, "ambiguous-authority-sentinel")

    assert {:error, {:invalid_command_ledger_path, :reserved_atomic_temp_name}} =
             open_store(ambiguous_path)

    assert File.read!(path) == "existing-authority-sentinel"
    assert File.read!(ambiguous_path) == "ambiguous-authority-sentinel"
  end

  test "reserved temporary paths include destination names containing newlines", %{root: root} do
    File.mkdir_p!(root)
    path = Path.join(root, "ledger\n.snapshot")
    ambiguous_path = path <> ".tmp.ABCD-EFGH_IJKLMN"
    File.write!(path, "existing-authority-sentinel")
    File.write!(ambiguous_path, "ambiguous-authority-sentinel")

    assert {:error, {:invalid_command_ledger_path, :reserved_atomic_temp_name}} =
             open_store(ambiguous_path)

    assert File.read!(path) == "existing-authority-sentinel"
    assert File.read!(ambiguous_path) == "ambiguous-authority-sentinel"
  end

  test "symlink aliases cannot bypass the reserved temporary namespace", %{root: root} do
    File.mkdir_p!(root)
    ambiguous_path = Path.join(root, "ledger.snapshot.tmp.ABCD-EFGH_IJKLMN")
    alias_path = Path.join(root, "ledger-alias.snapshot")
    File.ln_s!(ambiguous_path, alias_path)

    assert {:error, {:invalid_command_ledger_path, :reserved_atomic_temp_name}} =
             open_store(alias_path)

    refute File.exists?(ambiguous_path)
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(alias_path)
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
