defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.BoundEntryFileSystemTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.SegmentFileSystem

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "bound_entry_file_system_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "binds an exact regular entry for bounded reads, EOF, sync, and close", %{root: root} do
    path = Path.join(root, "entry")
    File.write!(path, "bound-bytes")

    assert {:ok, entry} = bind(path, :regular)
    assert {:ok, %{size: 11}} = SegmentFileSystem.bound_info(entry)
    assert {:ok, "bound"} = SegmentFileSystem.read_bound(entry, 5)
    assert {:ok, "-bytes"} = SegmentFileSystem.read_bound(entry, 64)
    assert :eof = SegmentFileSystem.read_bound(entry, 1)
    assert :ok = SegmentFileSystem.sync_bound(entry)
    assert :ok = SegmentFileSystem.close_bound(entry)
    assert {:error, :closed} = SegmentFileSystem.close_bound(entry)
  end

  test "rejects wrong entry and parent identities", %{root: root} do
    path = Path.join(root, "entry")
    File.write!(path, "bytes")
    stat = File.lstat!(path)
    parent = File.lstat!(root)

    wrong_entry = {stat.major_device, stat.minor_device, stat.inode + 1}
    parent_identity = identity(parent)

    assert {:error, :stale_entry} =
             SegmentFileSystem.bind_entry(path, :regular, wrong_entry, parent_identity)

    assert {:error, :stale_entry} =
             SegmentFileSystem.bind_entry(path, :regular, identity(stat), {
               parent.major_device,
               parent.minor_device,
               parent.inode + 1
             })
  end

  test "never follows a symlinked parent or entry", %{root: root} do
    outside = root <> "-outside"
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "entry"), "outside")

    parent_link = Path.join(root, "parent-link")
    File.ln_s!(outside, parent_link)
    outside_stat = File.lstat!(Path.join(outside, "entry"))
    outside_parent = File.lstat!(outside)

    assert {:error, _reason} =
             SegmentFileSystem.bind_entry(
               Path.join(parent_link, "entry"),
               :regular,
               identity(outside_stat),
               identity(outside_parent)
             )

    entry_link = Path.join(root, "entry-link")
    File.ln_s!(Path.join(outside, "entry"), entry_link)
    link_stat = File.lstat!(entry_link)

    assert {:error, _reason} =
             SegmentFileSystem.bind_entry(
               entry_link,
               :regular,
               identity(link_stat),
               identity(File.lstat!(root))
             )
  end

  test "refuses to unlink a name replaced after binding", %{root: root} do
    path = Path.join(root, "entry")
    moved = path <> ".moved"
    File.write!(path, "original")
    assert {:ok, entry} = bind(path, :regular)

    File.rename!(path, moved)
    File.write!(path, "replacement")

    assert {:error, :name_changed} = SegmentFileSystem.remove_bound(entry)
    assert File.read!(path) == "replacement"
    assert File.read!(moved) == "original"
    assert :ok = SegmentFileSystem.close_bound(entry)
  end

  test "atomically removes the exact verified regular entry and directory", %{root: root} do
    file = Path.join(root, "entry")
    File.write!(file, "bytes")
    assert {:ok, file_entry} = bind(file, :regular)
    assert :ok = SegmentFileSystem.remove_bound(file_entry)
    refute File.exists?(file)
    assert :ok = SegmentFileSystem.close_bound(file_entry)

    directory = Path.join(root, "empty")
    File.mkdir!(directory)
    assert {:ok, directory_entry} = bind(directory, :directory)
    assert :ok = SegmentFileSystem.remove_bound(directory_entry)
    refute File.exists?(directory)
    assert :ok = SegmentFileSystem.close_bound(directory_entry)
  end

  test "resource destruction closes an abandoned bound entry", %{root: root} do
    path = Path.join(root, "entry")
    File.write!(path, "bytes")

    parent = self()

    pid =
      spawn(fn ->
        assert {:ok, _entry} = bind(path, :regular)
        send(parent, :bound_entry_abandoned)
      end)

    ref = Process.monitor(pid)
    assert_receive :bound_entry_abandoned
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert File.read!(path) == "bytes"
  end

  defp bind(path, type) do
    stat = File.lstat!(path)
    parent = File.lstat!(Path.dirname(path))
    SegmentFileSystem.bind_entry(path, type, identity(stat), identity(parent))
  end

  defp identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}
end
