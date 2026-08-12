defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.SegmentFileSystemTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.{FileSystem, SegmentFileSystem}

  setup do
    root = Path.join(System.tmp_dir!(), "outbox_segment_fs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "opens only the exact full-width root identity", %{root: root} do
    stat = File.stat!(root)
    identity = {stat.major_device, stat.minor_device, stat.inode}

    assert {:ok, handle} = SegmentFileSystem.open_root(FileSystem, root, identity)
    assert :ok = SegmentFileSystem.close_root(handle)

    high_inode = stat.inode + 0x1_0000_0000

    assert {:error, :stale_root} =
             SegmentFileSystem.open_root(FileSystem, root, {stat.major_device, stat.minor_device, high_inode})
  end

  test "creates and durably appends through root-bound handles", %{root: root} do
    stat = File.stat!(root)
    identity = {stat.major_device, stat.minor_device, stat.inode}

    assert {:ok, root_handle} = SegmentFileSystem.open_root(FileSystem, root, identity)
    assert {:ok, segment} = SegmentFileSystem.create(root_handle, "segment.log", 0o600)
    assert :ok = SegmentFileSystem.chmod(segment, 0o600)
    assert :ok = SegmentFileSystem.write(segment, ["payload", "-bytes"])
    assert :ok = SegmentFileSystem.sync_file(segment)
    assert :ok = SegmentFileSystem.sync_directory(segment)
    assert {:ok, %{size: 13, links: 1}} = SegmentFileSystem.file_info(segment)
    assert :ok = SegmentFileSystem.close(segment)
    assert :ok = SegmentFileSystem.close_root(root_handle)
    assert File.read!(Path.join(root, "segment.log")) == "payload-bytes"
  end

  test "returns atom reasons and rejects unsafe basenames", %{root: root} do
    stat = File.stat!(root)
    identity = {stat.major_device, stat.minor_device, stat.inode}

    assert {:ok, root_handle} = SegmentFileSystem.open_root(FileSystem, root, identity)
    assert {:error, :invalid_basename} = SegmentFileSystem.create(root_handle, "../segment.log", 0o600)
    assert {:ok, segment} = SegmentFileSystem.create(root_handle, "segment.log", 0o600)
    assert {:error, reason} = SegmentFileSystem.create(root_handle, "segment.log", 0o600)
    assert is_atom(reason)
    assert reason == :eexist
    assert :ok = SegmentFileSystem.unlink_empty(segment)
    assert :ok = SegmentFileSystem.sync_directory(segment)
    assert :ok = SegmentFileSystem.close(segment)
    assert :ok = SegmentFileSystem.close_root(root_handle)
    refute File.exists?(Path.join(root, "segment.log"))
  end

  test "native lifecycle keeps cleanup out of destructor scheduler contexts" do
    source =
      __DIR__
      |> Path.join("../../../../../../c_src/outbox_segment.c")
      |> Path.expand()
      |> File.read!()

    refute source =~ "ERL_NIF_RT_TAKEOVER"
    assert source =~ "O_NONBLOCK"
    assert source =~ "EAGAIN"

    assert [_, enqueue_body] =
             Regex.run(
               ~r/static void cleanup_worker_enqueue\([^\{]+\) \{(.*?)\n\}/s,
               source
             )

    refute enqueue_body =~ "close_owned_fd"
    refute enqueue_body =~ "enif_free"
  end

  test "process death closes abandoned native descriptors without unlinking", %{root: root} do
    descriptor_count = descriptor_count!()
    stat = File.stat!(root)
    identity = {stat.major_device, stat.minor_device, stat.inode}
    baseline = descriptor_count.()
    parent = self()

    {holder, monitor} =
      spawn_monitor(fn ->
        assert {:ok, root_handle} = SegmentFileSystem.open_root(FileSystem, root, identity)

        segments =
          for index <- 1..8 do
            assert {:ok, segment} = SegmentFileSystem.create(root_handle, "segment-#{index}.log", 0o600)
            assert :ok = SegmentFileSystem.write(segment, "payload-#{index}")
            segment
          end

        Process.put({__MODULE__, :abandoned_handles}, {root_handle, segments})
        send(parent, {:native_handles_ready, self(), descriptor_count.()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:native_handles_ready, ^holder, live_count}, 1_000
    assert live_count >= baseline + 17
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}, 1_000

    assert eventually(fn -> descriptor_count.() <= baseline + 1 end)

    for index <- 1..8 do
      assert File.read!(Path.join(root, "segment-#{index}.log")) == "payload-#{index}"
    end
  end

  defp descriptor_count! do
    directory =
      Enum.find(["/dev/fd", "/proc/self/fd"], &File.dir?/1) ||
        flunk("native descriptor directory is unavailable")

    fn ->
      directory
      |> File.ls!()
      |> length()
    end
  end

  defp eventually(assertion, attempts \\ 100)

  defp eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      true
    else
      Process.sleep(10)
      eventually(assertion, attempts - 1)
    end
  end

  defp eventually(assertion, 0), do: assertion.()
end
