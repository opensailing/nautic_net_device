defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.SegmentFileSystemTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.{FileSystem, SegmentFileSystem}

  setup do
    root = Path.join(canonical_tmp_dir(), "outbox_segment_fs_#{System.unique_integer([:positive])}")
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

  test "holds an advisory root lock until its handle closes", %{root: root} do
    stat = File.stat!(root)
    identity = {stat.major_device, stat.minor_device, stat.inode}

    assert {:ok, first} = SegmentFileSystem.open_root(FileSystem, root, identity)
    assert :ok = SegmentFileSystem.try_lock_root(first)
    assert {:ok, second} = SegmentFileSystem.open_root(FileSystem, root, identity)
    assert {:error, reason} = SegmentFileSystem.try_lock_root(second)
    assert reason in [:eacces, :eagain]
    assert :ok = SegmentFileSystem.close_root(first)
    assert :ok = SegmentFileSystem.try_lock_root(second)
    assert :ok = SegmentFileSystem.close_root(second)
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

  test "adoption prepare pins the source until exclusive commit", %{root: root} do
    source_parent = Path.join(root, "legacy")
    destination_parent = Path.join(root, "durable")
    source = Path.join(source_parent, "ledger")
    destination = Path.join(destination_parent, "ledger")
    File.mkdir_p!(source_parent)
    File.mkdir_p!(destination_parent)
    File.write!(source, "legacy")

    assert {:ok, adoption} = SegmentFileSystem.adoption_prepare(source, destination, root)
    File.rename!(source, source <> ".moved")
    File.write!(source, "substitute")

    assert {:error, :stale_source} = SegmentFileSystem.adoption_commit(adoption, :none)
    assert :ok = SegmentFileSystem.adoption_close(adoption)
    assert File.read!(source) == "substitute"
    assert File.read!(source <> ".moved") == "legacy"
    refute File.exists?(destination)
  end

  test "adoption rejects source and destination parent substitution", %{root: root} do
    for swapped_parent <- [:source, :destination] do
      suffix = Atom.to_string(swapped_parent)
      source_parent = Path.join(root, "legacy-#{suffix}")
      destination_parent = Path.join(root, "durable-#{suffix}")
      source = Path.join(source_parent, "outbox")
      destination = Path.join(destination_parent, "outbox")
      File.mkdir_p!(source_parent)
      File.mkdir_p!(destination_parent)
      File.write!(source, "legacy")

      assert {:ok, adoption} = SegmentFileSystem.adoption_prepare(source, destination, root)
      parent = if swapped_parent == :source, do: source_parent, else: destination_parent
      File.rename!(parent, parent <> ".moved")
      File.mkdir_p!(parent)

      expected = if swapped_parent == :source, do: :stale_source_parent, else: :stale_destination_parent
      assert {:error, ^expected} = SegmentFileSystem.adoption_commit(adoption, :none)
      assert :ok = SegmentFileSystem.adoption_close(adoption)
      refute File.exists?(destination)
      refute File.exists?(Path.join(parent <> ".moved", "outbox")) == (swapped_parent == :destination)
    end
  end

  test "adoption rejects symlink substitution of parent ancestors", %{root: root} do
    for swapped_tree <- [:source, :destination] do
      suffix = Atom.to_string(swapped_tree)
      source_tree = Path.join(root, "source-tree-#{suffix}")
      destination_tree = Path.join(root, "destination-tree-#{suffix}")
      source_parent = Path.join(source_tree, "legacy")
      destination_parent = Path.join(destination_tree, "durable")
      source = Path.join(source_parent, "outbox")
      destination = Path.join(destination_parent, "outbox")
      File.mkdir_p!(source_parent)
      File.mkdir_p!(destination_parent)
      File.write!(source, "legacy")

      assert {:ok, adoption} = SegmentFileSystem.adoption_prepare(source, destination, root)
      tree = if swapped_tree == :source, do: source_tree, else: destination_tree
      File.rename!(tree, tree <> ".moved")
      File.ln_s!(tree <> ".moved", tree)

      expected = if swapped_tree == :source, do: :stale_source_parent, else: :stale_destination_parent
      assert {:error, ^expected} = SegmentFileSystem.adoption_commit(adoption, :none)
      assert :ok = SegmentFileSystem.adoption_close(adoption)
      assert File.read!(source) == "legacy"
      refute File.exists?(destination)
    end
  end

  test "adoption collision leaves both trees unchanged", %{root: root} do
    source_parent = Path.join(root, "legacy-collision")
    destination_parent = Path.join(root, "durable-collision")
    source = Path.join(source_parent, "ledger")
    destination = Path.join(destination_parent, "ledger")
    File.mkdir_p!(source_parent)
    File.mkdir_p!(destination_parent)
    File.write!(source, "legacy")
    File.write!(destination, "current")

    assert {:ok, adoption} = SegmentFileSystem.adoption_prepare(source, destination, root)
    assert {:error, :eexist} = SegmentFileSystem.adoption_commit(adoption, :none)
    assert :ok = SegmentFileSystem.adoption_close(adoption)
    assert File.read!(source) == "legacy"
    assert File.read!(destination) == "current"
  end

  test "source-parent sync failure cannot return native success", %{root: root} do
    source_parent = Path.join(root, "legacy-source-sync")
    destination_parent = Path.join(root, "durable-source-sync")
    source = Path.join(source_parent, "ledger")
    destination = Path.join(destination_parent, "ledger")
    File.mkdir_p!(source_parent)
    File.mkdir_p!(destination_parent)
    File.write!(source, "legacy")
    source_inode = File.stat!(source).inode

    assert {:ok, adoption} = SegmentFileSystem.adoption_prepare(source, destination, root)

    assert {:error, {:adopted, {:source_parent_sync, :eio}}} =
             SegmentFileSystem.adoption_commit(adoption, :source_parent_sync)

    assert :ok = SegmentFileSystem.adoption_close(adoption)
    refute File.exists?(source)
    assert File.stat!(destination).inode == source_inode
  end

  test "destination-parent sync failure cannot return native success", %{root: root} do
    source_parent = Path.join(root, "legacy-destination-sync")
    destination_parent = Path.join(root, "durable-destination-sync")
    source = Path.join(source_parent, "outbox")
    destination = Path.join(destination_parent, "outbox")
    File.mkdir_p!(source_parent)
    File.mkdir_p!(destination_parent)
    File.write!(source, "legacy")
    source_inode = File.stat!(source).inode

    assert {:ok, adoption} = SegmentFileSystem.adoption_prepare(source, destination, root)

    assert {:error, {:adopted, {:destination_parent_sync, :eio}}} =
             SegmentFileSystem.adoption_commit(adoption, :destination_parent_sync)

    assert :ok = SegmentFileSystem.adoption_close(adoption)
    refute File.exists?(source)
    assert File.stat!(destination).inode == source_inode
  end

  test "adoption directory walking is descriptor-bound and component-wise nofollow" do
    source = native_source()

    assert [_, traversal] =
             Regex.run(~r/static int traverse_directory_chain\([^\{]+\) \{(.*?)\n\}/s, source)

    assert traversal =~ "openat(fd, component"
    assert traversal =~ "mkdirat(fd, component"
    assert traversal =~ "O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC"
    refute traversal =~ "open(copy"
    refute traversal =~ "mkdir(copy"

    assert [_, prepare] =
             Regex.run(~r/static ERL_NIF_TERM adoption_prepare_nif\([^\{]+\) \{(.*?)\n\}/s, source)

    assert prepare =~ "open_or_create_relative_directory_chain_nofollow("
    assert prepare =~ "root_fd, destination_parent_relative, 0700"
    refute prepare =~ "open_or_create_directory_chain_nofollow(&destination_parent_binary"
  end

  test "adoption revalidates both parent paths after both durable syncs" do
    source = native_source()

    assert [_, commit] =
             Regex.run(~r/static ERL_NIF_TERM adoption_commit_nif\([^\{]+\) \{(.*?)\n\}/s, source)

    destination_sync = last_index!(commit, "sync_fd(adoption->destination_parent_fd)")

    source_revalidation =
      last_index!(commit, "path_matches_identity_nofollow(adoption->source_parent_path")

    destination_revalidation =
      last_index!(commit, "path_matches_identity_nofollow(adoption->destination_parent_path")

    assert source_revalidation > destination_sync
    assert destination_revalidation > destination_sync
  end

  test "adoption NIF work is scheduled as dirty IO" do
    source = native_source()
    assert source =~ ~s({"adoption_prepare", 3, adoption_prepare_nif, ERL_NIF_DIRTY_JOB_IO_BOUND})
    assert source =~ ~s({"adoption_commit", 2, adoption_commit_nif, ERL_NIF_DIRTY_JOB_IO_BOUND})
    assert source =~ ~s({"adoption_close", 1, adoption_close_nif, ERL_NIF_DIRTY_JOB_IO_BOUND})
  end

  test "native lifecycle keeps cleanup out of destructor scheduler contexts" do
    source = native_source()

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

    assert [_, adoption_destructor] =
             Regex.run(~r/static void adoption_destructor\([^\{]+\) \{(.*?)\n\}/s, source)

    assert adoption_destructor =~ "cleanup_worker_enqueue"
    refute adoption_destructor =~ "close_owned_fd"
    refute adoption_destructor =~ "enif_free"
    refute adoption_destructor =~ "enif_mutex_destroy"
  end

  test "native cleanup worker exits on wake-pipe EOF and fatal reads" do
    source = native_source()

    assert [_, worker_body] =
             Regex.run(~r/static void \*cleanup_worker_main\([^\{]+\) \{(.*?)\n\}/s, source)

    assert worker_body =~ "read_result == 0"
    assert worker_body =~ "errno != EINTR"
    assert worker_body =~ "return NULL"
  end

  test "native constructors reserve cleanup jobs before acquiring descriptors" do
    source = native_source()

    assert [_, open_root] =
             Regex.run(~r/static ERL_NIF_TERM open_root_nif\([^\{]+\) \{(.*?)\n\}/s, source)

    assert cleanup_allocation_precedes?(
             open_root,
             ~r/=\s*open\(path_string/,
             ~r/cleanup\s*=\s*enif_alloc\(sizeof\(\*cleanup\)\)/
           ),
           "open_root_nif opens the directory before reserving its cleanup job"

    assert [_, create] =
             Regex.run(~r/static ERL_NIF_TERM create_nif\([^\{]+\) \{(.*?)\n\}/s, source)

    assert cleanup_allocation_precedes?(
             create,
             ~r/=\s*(?:dup|duplicate_descriptor)\(root->fd/,
             ~r/cleanup\s*=\s*enif_alloc\(sizeof\(\*cleanup\)\)/
           ),
           "create_nif duplicates the root fd before reserving its cleanup job"
  end

  test "process death closes abandoned native descriptors without unlinking", %{root: root} do
    assert {:module, SegmentFileSystem} = Code.ensure_loaded(SegmentFileSystem)

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

  test "process death closes abandoned adoption descriptors without moving the source", %{root: root} do
    descriptor_count = descriptor_count!()
    baseline = descriptor_count.()
    source_parent = Path.join(root, "legacy-abandoned")
    destination_parent = Path.join(root, "durable-abandoned")
    File.mkdir_p!(source_parent)
    File.mkdir_p!(destination_parent)
    parent = self()

    {holder, monitor} =
      spawn_monitor(fn ->
        adoptions =
          for index <- 1..8 do
            source = Path.join(source_parent, "ledger-#{index}")
            destination = Path.join(destination_parent, "ledger-#{index}")
            File.write!(source, "legacy-#{index}")
            assert {:ok, adoption} = SegmentFileSystem.adoption_prepare(source, destination, root)
            adoption
          end

        Process.put({__MODULE__, :abandoned_adoptions}, adoptions)
        send(parent, {:native_adoptions_ready, self(), descriptor_count.()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:native_adoptions_ready, ^holder, live_count}, 1_000
    assert live_count >= baseline + 24
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}, 1_000

    assert eventually(fn -> descriptor_count.() <= baseline + 1 end)

    for index <- 1..8 do
      assert File.read!(Path.join(source_parent, "ledger-#{index}")) == "legacy-#{index}"
      refute File.exists?(Path.join(destination_parent, "ledger-#{index}"))
    end
  end

  test "repeated adoption prepare and close does not leak descriptors", %{root: root} do
    descriptor_count = descriptor_count!()
    source_parent = Path.join(root, "legacy-close")
    destination_parent = Path.join(root, "durable-close")
    File.mkdir_p!(source_parent)
    File.mkdir_p!(destination_parent)
    baseline = descriptor_count.()

    for index <- 1..32 do
      source = Path.join(source_parent, "ledger-#{index}")
      destination = Path.join(destination_parent, "ledger-#{index}")
      File.write!(source, "legacy-#{index}")
      assert {:ok, adoption} = SegmentFileSystem.adoption_prepare(source, destination, root)
      assert :ok = SegmentFileSystem.adoption_close(adoption)
    end

    assert eventually(fn -> descriptor_count.() <= baseline + 1 end)
  end

  defp canonical_tmp_dir do
    case System.tmp_dir!() do
      "/var/" <> rest -> "/private/var/" <> rest
      path -> path
    end
  end

  defp native_source do
    __DIR__
    |> Path.join("../../../../../../c_src/outbox_segment.c")
    |> Path.expand()
    |> File.read!()
  end

  defp cleanup_allocation_precedes?(body, descriptor_pattern, cleanup_pattern) do
    [{cleanup_at, _size}] = Regex.run(cleanup_pattern, body, return: :index)
    [{descriptor_at, _size}] = Regex.run(descriptor_pattern, body, return: :index)
    cleanup_at < descriptor_at
  end

  defp last_index!(body, needle) do
    body
    |> :binary.matches(needle)
    |> List.last()
    |> elem(0)
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
