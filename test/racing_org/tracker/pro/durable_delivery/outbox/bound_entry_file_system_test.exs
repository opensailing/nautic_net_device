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
             SegmentFileSystem.bind_entry(
               root,
               path,
               :regular,
               wrong_entry,
               parent_identity,
               parent_identity
             )

    assert {:error, :stale_entry} =
             SegmentFileSystem.bind_entry(
               root,
               path,
               :regular,
               identity(stat),
               {parent.major_device, parent.minor_device, parent.inode + 1},
               parent_identity
             )
  end

  test "rejects a stale root identity", %{root: root} do
    path = Path.join(root, "entry")
    File.write!(path, "bytes")
    stat = File.lstat!(path)
    root_stat = File.lstat!(root)

    assert {:error, :stale_entry} =
             SegmentFileSystem.bind_entry(
               root,
               path,
               :regular,
               identity(stat),
               identity(root_stat),
               {root_stat.major_device, root_stat.minor_device, root_stat.inode + 1}
             )
  end

  test "rejects a replaced relative ancestor", %{root: root} do
    parent = Path.join(root, "parent")
    moved = parent <> ".moved"
    path = Path.join(parent, "entry")
    File.mkdir!(parent)
    File.write!(path, "original")

    entry_identity = identity(File.lstat!(path))
    parent_identity = identity(File.lstat!(parent))
    root_identity = identity(File.lstat!(root))

    File.rename!(parent, moved)
    File.mkdir!(parent)
    File.write!(Path.join(parent, "entry"), "replacement")

    assert {:error, :stale_entry} =
             SegmentFileSystem.bind_entry(
               root,
               path,
               :regular,
               entry_identity,
               parent_identity,
               root_identity
             )

    assert File.read!(Path.join(parent, "entry")) == "replacement"
    assert File.read!(Path.join(moved, "entry")) == "original"
  end

  test "bound operations remain attached after the root pathname is replaced", %{root: root} do
    path = Path.join(root, "entry")
    moved_root = root <> ".moved"
    File.write!(path, "original")
    assert {:ok, entry} = bind(path, :regular)

    File.rename!(root, moved_root)
    File.mkdir!(root)
    File.write!(Path.join(root, "entry"), "replacement")

    assert {:ok, "original"} = SegmentFileSystem.read_bound(entry, 64)
    assert :ok = SegmentFileSystem.remove_bound(entry)
    refute File.exists?(Path.join(moved_root, "entry"))
    assert File.read!(Path.join(root, "entry")) == "replacement"
    assert :ok = SegmentFileSystem.close_bound(entry)
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
               root,
               Path.join(parent_link, "entry"),
               :regular,
               identity(outside_stat),
               identity(outside_parent),
               identity(File.lstat!(root))
             )

    entry_link = Path.join(root, "entry-link")
    File.ln_s!(Path.join(outside, "entry"), entry_link)
    link_stat = File.lstat!(entry_link)

    assert {:error, _reason} =
             SegmentFileSystem.bind_entry(
               root,
               entry_link,
               :regular,
               identity(link_stat),
               identity(File.lstat!(root)),
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
    root = Path.dirname(path)

    SegmentFileSystem.bind_entry(
      root,
      path,
      type,
      identity(stat),
      identity(parent),
      identity(File.lstat!(root))
    )
  end

  defp identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}
end
