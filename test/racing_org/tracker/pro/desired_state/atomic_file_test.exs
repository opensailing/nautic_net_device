defmodule RacingOrg.Tracker.Pro.DesiredState.AtomicFileTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem, as: RealFileSystem

  defmodule TracingFileSystem do
    @behaviour RealFileSystem

    def attach(owner), do: :persistent_term.put({__MODULE__, :owner}, owner)
    def detach, do: :persistent_term.erase({__MODULE__, :owner})

    @impl true
    def read(path), do: RealFileSystem.read(path)

    @impl true
    def list_dir(path), do: RealFileSystem.list_dir(path)

    @impl true
    def lstat(path), do: File.lstat(path)

    @impl true
    def mkdir_p(path) do
      report({:mkdir_p, path})
      RealFileSystem.mkdir_p(path)
    end

    @impl true
    def chmod(path, mode) do
      report({:chmod, path, mode})
      RealFileSystem.chmod(path, mode)
    end

    @impl true
    def open(path, modes) do
      report({:open, path, modes})

      case RealFileSystem.open(path, modes) do
        {:ok, device} = result ->
          Process.put({__MODULE__, :path, device}, path)
          result

        error ->
          error
      end
    end

    @impl true
    def write(device, contents), do: RealFileSystem.write(device, contents)

    @impl true
    def sync(device) do
      report({:sync, Process.get({__MODULE__, :path, device})})
      RealFileSystem.sync(device)
    end

    @impl true
    def close(device) do
      result = RealFileSystem.close(device)
      Process.delete({__MODULE__, :path, device})
      result
    end

    @impl true
    def rename(source, destination), do: RealFileSystem.rename(source, destination)

    @impl true
    def remove(path) do
      report({:remove, path})
      RealFileSystem.remove(path)
    end

    defp report(event) do
      if owner = :persistent_term.get({__MODULE__, :owner}, nil), do: send(owner, {:file_system, event})
    end
  end

  defmodule CleanupFailureFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: File.lstat(path)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)
    def open(path, modes), do: RealFileSystem.open(path, modes)
    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)
    def rename(source, destination), do: RealFileSystem.rename(source, destination)
    def remove(_path), do: {:error, :simulated_remove_failure}
  end

  defmodule LegacyFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)
    def open(path, modes), do: RealFileSystem.open(path, modes)
    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)
    def rename(source, destination), do: RealFileSystem.rename(source, destination)
    def remove(path), do: RealFileSystem.remove(path)
  end

  defmodule CallbackFailureFileSystem do
    @behaviour RealFileSystem

    def fail(stage, kind), do: Process.put({__MODULE__, :failure}, {stage, kind})
    def reset, do: Process.delete({__MODULE__, :failure})

    def read(path), do: RealFileSystem.read(path)
    def list_dir(path), do: invoke(:list_dir, fn -> RealFileSystem.list_dir(path) end)
    def lstat(path), do: invoke(:lstat, fn -> File.lstat(path) end)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)
    def open(path, modes), do: invoke(:open, fn -> RealFileSystem.open(path, modes) end)
    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: invoke(:sync, fn -> RealFileSystem.sync(device) end)
    def close(device), do: invoke(:close, fn -> RealFileSystem.close(device) end)
    def rename(source, destination), do: RealFileSystem.rename(source, destination)
    def remove(path), do: invoke(:remove, fn -> RealFileSystem.remove(path) end)

    defp invoke(stage, callback) do
      case Process.get({__MODULE__, :failure}) do
        {^stage, :raise} -> raise "simulated cleanup callback failure"
        {^stage, :throw} -> throw(:simulated_cleanup_callback_failure)
        {^stage, :exit} -> exit(:simulated_cleanup_callback_failure)
        _other -> callback.()
      end
    end
  end

  defmodule PostRenameCallbackFailureFileSystem do
    @behaviour RealFileSystem

    def fail(callback, kind) do
      Process.put({__MODULE__, :failure}, {callback, kind})
      Process.delete({__MODULE__, :renamed?})
    end

    def reset do
      Process.delete({__MODULE__, :failure})
      Process.delete({__MODULE__, :renamed?})
    end

    def read(path), do: RealFileSystem.read(path)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)
    def open(path, modes), do: invoke(:open, fn -> RealFileSystem.open(path, modes) end)
    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: invoke(:sync, fn -> RealFileSystem.sync(device) end)
    def close(device), do: invoke(:close, fn -> RealFileSystem.close(device) end)

    def rename(source, destination) do
      case RealFileSystem.rename(source, destination) do
        :ok ->
          Process.put({__MODULE__, :renamed?}, true)
          :ok

        other ->
          other
      end
    end

    def remove(path), do: RealFileSystem.remove(path)

    defp invoke(callback, fallback) do
      case {Process.get({__MODULE__, :renamed?}), Process.get({__MODULE__, :failure})} do
        {true, {^callback, :raise}} -> raise "simulated post-rename callback failure"
        {true, {^callback, :throw}} -> throw(:simulated_post_rename_callback_failure)
        {true, {^callback, :exit}} -> exit(:simulated_post_rename_callback_failure)
        _other -> fallback.()
      end
    end
  end

  defmodule DirectorySyncFailureFileSystem do
    @behaviour RealFileSystem

    def fail_for(directory), do: Process.put({__MODULE__, :directory}, directory)
    def reset, do: Process.delete({__MODULE__, :directory})

    def read(path), do: RealFileSystem.read(path)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: File.lstat(path)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)

    def open(path, modes) do
      case RealFileSystem.open(path, modes) do
        {:ok, device} = result ->
          Process.put({__MODULE__, :path, device}, path)
          result

        error ->
          error
      end
    end

    def write(device, contents), do: RealFileSystem.write(device, contents)

    def sync(device) do
      if Process.get({__MODULE__, :path, device}) == Process.get({__MODULE__, :directory}),
        do: {:error, :simulated_directory_sync_failure},
        else: RealFileSystem.sync(device)
    end

    def close(device) do
      result = RealFileSystem.close(device)
      Process.delete({__MODULE__, :path, device})
      result
    end

    def rename(source, destination), do: RealFileSystem.rename(source, destination)
    def remove(path), do: RealFileSystem.remove(path)
  end

  setup do
    base = Path.join(System.tmp_dir!(), "desired_atomic_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf(base)
      TracingFileSystem.detach()
      CallbackFailureFileSystem.reset()
      PostRenameCallbackFailureFileSystem.reset()
      DirectorySyncFailureFileSystem.reset()
    end)

    %{base: base}
  end

  test "hardens every created directory and durably links each parent", ctx do
    TracingFileSystem.attach(self())
    path = Path.join([ctx.base, "generations", "candidate", "chunks", "calibration", "0.bin"])

    assert :ok =
             AtomicFile.write(path, "payload",
               file_system: TracingFileSystem,
               directory_root: ctx.base
             )

    for directory <- [
          ctx.base,
          Path.join(ctx.base, "generations"),
          Path.join([ctx.base, "generations", "candidate"]),
          Path.join([ctx.base, "generations", "candidate", "chunks"]),
          Path.join([ctx.base, "generations", "candidate", "chunks", "calibration"])
        ] do
      assert_mode(directory, 0o700)
    end

    synced_paths = collect_synced_paths([])

    assert Path.dirname(ctx.base) in synced_paths
    assert ctx.base in synced_paths
    assert Path.join(ctx.base, "generations") in synced_paths
    assert Path.join([ctx.base, "generations", "candidate"]) in synced_paths
    assert Path.join([ctx.base, "generations", "candidate", "chunks"]) in synced_paths
  end

  test "a temporary-name collision retries without removing another writer's file", ctx do
    File.mkdir_p!(ctx.base)
    destination = Path.join(ctx.base, "record")
    collision = destination <> ".tmp.same"
    File.write!(collision, "other-writer")

    assert :ok = AtomicFile.write(destination, "ours", temp_suffix: fn -> "same" end)

    assert File.read!(collision) == "other-writer"
    assert File.read!(destination) == "ours"
  end

  test "cleanup removes only exact destination-specific random temporary names", ctx do
    File.mkdir_p!(ctx.base)
    TracingFileSystem.attach(self())
    destination = Path.join(ctx.base, "record")
    first_attempt = destination <> ".tmp.ABCD-EFGH_IJKLMN"
    retry_attempt = destination <> ".tmp.abcdefghijklmnop.8"

    ignored = [
      destination <> ".tmp.same",
      destination <> ".tmp.abcdefghijklmno",
      destination <> ".tmp.abcdefghijklmnop.1",
      destination <> ".tmp.abcdefghijklmnop.9",
      destination <> ".tmp.abcdefghijklmnop.extra",
      Path.join(ctx.base, "other.tmp.ABCDEFGHIJKLMNOP")
    ]

    for path <- [first_attempt, retry_attempt | ignored], do: File.write!(path, "non-sensitive-state")

    assert :ok =
             AtomicFile.cleanup_orphan_temps(destination,
               file_system: TracingFileSystem
             )

    refute File.exists?(first_attempt)
    refute File.exists?(retry_attempt)
    assert Enum.all?(ignored, &File.exists?/1)

    events = collect_file_system_events([])
    first_remove = Enum.find_index(events, &(&1 == {:remove, first_attempt}))
    directory_sync = Enum.find_index(events, &(&1 == {:sync, ctx.base}))
    assert is_integer(first_remove)
    assert is_integer(directory_sync)
    assert first_remove < directory_sync
  end

  test "cleanup remains compatible with legacy filesystem adapters", ctx do
    File.mkdir_p!(ctx.base)
    destination = Path.join(ctx.base, "record")
    orphan = destination <> ".tmp.ABCDEFGHIJKLMNOP"
    File.write!(orphan, "non-sensitive-state")

    assert :ok = AtomicFile.cleanup_orphan_temps(destination, file_system: LegacyFileSystem)
    refute File.exists?(orphan)
  end

  test "cleanup fsyncs an existing empty parent directory", ctx do
    File.mkdir_p!(ctx.base)
    TracingFileSystem.attach(self())
    destination = Path.join(ctx.base, "record")

    assert :ok = AtomicFile.cleanup_orphan_temps(destination, file_system: TracingFileSystem)
    assert {:sync, ctx.base} in collect_file_system_events([])
  end

  test "cleanup callback failures are typed across raise throw and exit", ctx do
    File.mkdir_p!(ctx.base)
    destination = Path.join(ctx.base, "record")
    orphan = destination <> ".tmp.ABCDEFGHIJKLMNOP"
    File.write!(orphan, "non-sensitive-state")

    for {stage, kind, expected} <- [
          {:list_dir, :raise, {:list_directory, {:callback_failed, :raise}}},
          {:lstat, :throw, {:lstat_temp, {:callback_failed, :throw}}},
          {:remove, :exit, {:remove_temp, {:callback_failed, :exit}}}
        ] do
      CallbackFailureFileSystem.fail(stage, kind)

      assert {:error, {:orphan_temp_cleanup, ^expected}} =
               AtomicFile.cleanup_orphan_temps(destination,
                 file_system: CallbackFailureFileSystem
               )

      CallbackFailureFileSystem.reset()
      assert File.exists?(orphan)
    end
  end

  test "cleanup uses no-follow metadata and never removes matching symlinks", ctx do
    File.mkdir_p!(ctx.base)
    destination = Path.join(ctx.base, "record")
    target = Path.join(ctx.base, "target")
    matching_symlink = destination <> ".tmp.ABCDEFGHIJKLMNOP"
    File.write!(target, "non-sensitive-state")
    File.ln_s!(target, matching_symlink)

    assert {:error, {:orphan_temp_cleanup, :invalid_temp_type}} =
             AtomicFile.cleanup_orphan_temps(destination)

    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(matching_symlink)
    assert File.read!(target) == "non-sensitive-state"
  end

  test "cleanup reports directory-sync failure after removing the temp", ctx do
    File.mkdir_p!(ctx.base)
    DirectorySyncFailureFileSystem.fail_for(ctx.base)
    destination = Path.join(ctx.base, "record")
    orphan = destination <> ".tmp.ABCDEFGHIJKLMNOP"
    File.write!(orphan, "non-sensitive-state")

    assert {:error, {:orphan_temp_cleanup, {:sync_directory, {:directory_sync, :simulated_directory_sync_failure}}}} =
             AtomicFile.cleanup_orphan_temps(destination,
               file_system: DirectorySyncFailureFileSystem
             )

    refute File.exists?(orphan)
  end

  test "cleanup failure is typed and leaves authority unopened", ctx do
    File.mkdir_p!(ctx.base)
    destination = Path.join(ctx.base, "record")
    orphan = destination <> ".tmp.ABCDEFGHIJKLMNOP"
    File.write!(orphan, "non-sensitive-state")

    assert {:error, {:orphan_temp_cleanup, {:remove_temp, :simulated_remove_failure}}} =
             AtomicFile.cleanup_orphan_temps(destination,
               file_system: CleanupFailureFileSystem
             )

    assert File.exists?(orphan)
  end

  test "cleanup fails closed on a matching non-regular artifact", ctx do
    File.mkdir_p!(ctx.base)
    destination = Path.join(ctx.base, "record")
    matching_directory = destination <> ".tmp.ABCDEFGHIJKLMNOP"
    File.mkdir_p!(matching_directory)

    assert {:error, {:orphan_temp_cleanup, :invalid_temp_type}} =
             AtomicFile.cleanup_orphan_temps(destination)

    assert File.dir?(matching_directory)
  end

  test "filesystem callback failures before rename retain pre-rename typing", ctx do
    for {callback, kind, operation} <- [
          {:open, :raise, :directory_open},
          {:sync, :throw, :directory_sync},
          {:close, :exit, :directory_close}
        ] do
      destination = Path.join(ctx.base, "pre-#{callback}-#{kind}")
      CallbackFailureFileSystem.fail(callback, kind)

      assert {:error, {:pre_rename, {^operation, {:callback_failed, ^kind}}}} =
               AtomicFile.write(destination, "non-sensitive-state", file_system: CallbackFailureFileSystem)

      CallbackFailureFileSystem.reset()
      refute File.exists?(destination)
    end
  end

  test "post-rename parent-sync callback failures are durability uncertain", ctx do
    for callback <- [:open, :sync, :close],
        kind <- [:raise, :throw, :exit] do
      operation =
        case callback do
          :open -> :directory_open
          :sync -> :directory_sync
          :close -> :directory_close
        end

      destination = Path.join(ctx.base, "post-#{callback}-#{kind}")
      PostRenameCallbackFailureFileSystem.fail(callback, kind)

      assert {:error, {:durability_uncertain, {^operation, {:callback_failed, ^kind}}}} =
               AtomicFile.write(destination, "non-sensitive-state", file_system: PostRenameCallbackFailureFileSystem)

      PostRenameCallbackFailureFileSystem.reset()
      assert File.read!(destination) == "non-sensitive-state"
    end
  end

  test "distinguishes pre-rename failure, durability uncertainty, and durable success", ctx do
    pre_path = Path.join(ctx.base, "pre")

    assert {:error, {:pre_rename, {:fault_injected, :before_rename, :power_loss}}} =
             AtomicFile.write(pre_path, "pre",
               temp_suffix: fn -> "pre" end,
               fault_injector: fail_at(:before_rename)
             )

    refute File.exists?(pre_path)
    assert [] == Path.wildcard(pre_path <> ".tmp.*")

    uncertain_path = Path.join(ctx.base, "uncertain")

    assert {:error, {:durability_uncertain, {:fault_injected, :renamed, :power_loss}}} =
             AtomicFile.write(uncertain_path, "visible",
               temp_suffix: fn -> "uncertain" end,
               fault_injector: fail_at(:renamed)
             )

    assert File.read!(uncertain_path) == "visible"

    durable_path = Path.join(ctx.base, "durable")

    assert :ok =
             AtomicFile.write(durable_path, "durable", fault_injector: fail_at(:parent_synced))

    assert File.read!(durable_path) == "durable"
  end

  test "idempotent remove syncs durable absence and reports post-remove uncertainty", ctx do
    File.mkdir_p!(ctx.base)
    TracingFileSystem.attach(self())
    absent = Path.join(ctx.base, "absent")

    assert :ok =
             AtomicFile.remove(absent,
               file_system: TracingFileSystem,
               directory_root: ctx.base
             )

    assert ctx.base in collect_synced_paths([])

    present = Path.join(ctx.base, "present")
    File.write!(present, "value")

    assert {:error, {:durability_uncertain, {:fault_injected, :removed, :power_loss}}} =
             AtomicFile.remove(present,
               directory_root: ctx.base,
               fault_injector: fail_at(:removed)
             )

    refute File.exists?(present)
  end

  defp fail_at(stage) do
    fn
      ^stage -> {:error, :power_loss}
      _other -> :ok
    end
  end

  defp collect_file_system_events(acc) do
    receive do
      {:file_system, event} -> collect_file_system_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_synced_paths(acc) do
    receive do
      {:file_system, {:sync, path}} -> collect_synced_paths([path | acc])
      {:file_system, _event} -> collect_synced_paths(acc)
    after
      0 -> acc
    end
  end

  defp assert_mode(path, expected) do
    assert {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o777) == expected
  end
end
