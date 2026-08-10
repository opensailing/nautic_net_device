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
    def remove(path), do: RealFileSystem.remove(path)

    defp report(event) do
      if owner = :persistent_term.get({__MODULE__, :owner}, nil), do: send(owner, {:file_system, event})
    end
  end

  setup do
    base = Path.join(System.tmp_dir!(), "desired_atomic_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf(base)
      TracingFileSystem.detach()
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
