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
    def read(device, count), do: RealFileSystem.read(device, count)

    @impl true
    def list_dir(path), do: RealFileSystem.list_dir(path)

    @impl true
    def lstat(path), do: File.lstat(path)

    @impl true
    def file_info(device), do: RealFileSystem.file_info(device)

    @impl true
    def mkdir_p(path) do
      report({:mkdir_p, path})
      RealFileSystem.mkdir_p(path)
    end

    @impl true
    def mkdir(path) do
      report({:mkdir, path})
      RealFileSystem.mkdir(path)
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

    @impl true
    def rmdir(path) do
      report({:rmdir, path})
      RealFileSystem.rmdir(path)
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

  defmodule MissingLstatFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def list_dir(path), do: RealFileSystem.list_dir(path)
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
    def mkdir_p(path), do: invoke(:mkdir_p, fn -> RealFileSystem.mkdir_p(path) end)
    def chmod(path, mode), do: invoke(:chmod, fn -> RealFileSystem.chmod(path, mode) end)
    def open(path, modes), do: invoke(:open, fn -> RealFileSystem.open(path, modes) end)
    def write(device, contents), do: invoke(:write, fn -> RealFileSystem.write(device, contents) end)
    def sync(device), do: invoke(:sync, fn -> RealFileSystem.sync(device) end)
    def close(device), do: invoke(:close, fn -> RealFileSystem.close(device) end)

    def rename(source, destination),
      do: invoke(:rename, fn -> RealFileSystem.rename(source, destination) end)

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

  defmodule MissingWriteCallbacksFileSystem do
  end

  defmodule RenameRaisesAfterCommitFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)
    def open(path, modes), do: RealFileSystem.open(path, modes)
    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)

    def rename(source, destination) do
      case RealFileSystem.rename(source, destination) do
        :ok -> raise "simulated return-path failure after rename"
        other -> other
      end
    end

    def remove(path), do: RealFileSystem.remove(path)
  end

  defmodule RemoveRaisesAfterCommitFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def file_info(device), do: RealFileSystem.file_info(device)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)
    def open(path, modes), do: RealFileSystem.open(path, modes)
    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)
    def rename(source, destination), do: RealFileSystem.rename(source, destination)

    def remove(path) do
      case RealFileSystem.remove(path) do
        :ok -> raise "simulated return-path failure after remove"
        other -> other
      end
    end
  end

  defmodule RenameFailsBeforeCommitFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)
    def open(path, modes), do: RealFileSystem.open(path, modes)
    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)
    def rename(_source, _destination), do: {:error, :eacces}
    def remove(path), do: RealFileSystem.remove(path)
  end

  defmodule RenameFailsWithoutLstatFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)
    def open(path, modes), do: RealFileSystem.open(path, modes)
    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)
    def rename(_source, _destination), do: {:error, :eacces}
    def remove(path), do: RealFileSystem.remove(path)
  end

  defmodule RenameFailsAfterCommitAndRecreatesTempFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)
    def open(path, modes), do: RealFileSystem.open(path, modes)
    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)

    def rename(source, destination) do
      case RealFileSystem.rename(source, destination) do
        :ok ->
          File.write!(source, "other-writer")
          raise "simulated return-path failure after rename"

        other ->
          other
      end
    end

    def remove(path), do: RealFileSystem.remove(path)
  end

  defmodule OpenRaisesAfterCreateFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)

    def open(path, modes) do
      case RealFileSystem.open(path, modes) do
        {:ok, device} = result ->
          if :exclusive in modes do
            :ok = RealFileSystem.close(device)
            raise "simulated return-path failure after open"
          else
            result
          end

        other ->
          other
      end
    end

    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)
    def rename(source, destination), do: RealFileSystem.rename(source, destination)
    def remove(path), do: RealFileSystem.remove(path)
  end

  defmodule OpenRaisesBeforeAcquireFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)

    def open(path, modes) do
      if :exclusive in modes do
        raise "simulated callback failure before exclusive open"
      else
        RealFileSystem.open(path, modes)
      end
    end

    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)
    def rename(source, destination), do: RealFileSystem.rename(source, destination)
    def remove(path), do: RealFileSystem.remove(path)
  end

  defmodule ChmodNoopFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def read(device, count), do: RealFileSystem.read(device, count)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def file_info(device), do: RealFileSystem.file_info(device)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def mkdir(path), do: RealFileSystem.mkdir(path)
    def chmod(_path, _mode), do: :ok
    def open(path, modes), do: RealFileSystem.open(path, modes)
    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)
    def rename(source, destination), do: RealFileSystem.rename(source, destination)
    def remove(path), do: RealFileSystem.remove(path)
    def rmdir(path), do: RealFileSystem.rmdir(path)
  end

  defmodule ParentSwapAfterRenameFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def read(device, count), do: RealFileSystem.read(device, count)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def file_info(device), do: RealFileSystem.file_info(device)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def mkdir(path), do: RealFileSystem.mkdir(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)
    def open(path, modes), do: RealFileSystem.open(path, modes)
    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)

    def rename(source, destination) do
      with :ok <- RealFileSystem.rename(source, destination),
           parent = Path.dirname(destination),
           :ok <- File.rename(parent, parent <> ".moved"),
           :ok <- File.mkdir(parent) do
        :ok
      end
    end

    def remove(path), do: RealFileSystem.remove(path)
    def rmdir(path), do: RealFileSystem.rmdir(path)
  end

  defmodule ParentSwapAfterRemoveFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def read(device, count), do: RealFileSystem.read(device, count)
    def list_dir(path), do: RealFileSystem.list_dir(path)
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

    def remove(path) do
      with :ok <- RealFileSystem.remove(path),
           parent = Path.dirname(path),
           :ok <- File.rename(parent, parent <> ".moved"),
           :ok <- File.mkdir(parent) do
        :ok
      end
    end

    def rmdir(path), do: RealFileSystem.rmdir(path)
  end

  defmodule TempContentMutationFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def read(device, count), do: RealFileSystem.read(device, count)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def file_info(device), do: RealFileSystem.file_info(device)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def mkdir(path), do: RealFileSystem.mkdir(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)

    def open(path, modes) do
      case RealFileSystem.open(path, modes) do
        {:ok, device} = result ->
          if :exclusive in modes, do: Process.put({__MODULE__, :temp_path, device}, path)
          result

        other ->
          other
      end
    end

    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)

    def close(device) do
      temp_path = Process.delete({__MODULE__, :temp_path, device})
      result = RealFileSystem.close(device)

      if result == :ok and is_binary(temp_path) do
        :ok = File.write(temp_path, "substitute")
      end

      result
    end

    def rename(source, destination), do: RealFileSystem.rename(source, destination)
    def remove(path), do: RealFileSystem.remove(path)
    def rmdir(path), do: RealFileSystem.rmdir(path)
  end

  defmodule RenameContentMutationFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def read(device, count), do: RealFileSystem.read(device, count)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def file_info(device), do: RealFileSystem.file_info(device)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def mkdir(path), do: RealFileSystem.mkdir(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)
    def open(path, modes), do: RealFileSystem.open(path, modes)
    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)

    def rename(source, destination) do
      with :ok <- File.write(source, "substitute"),
           :ok <- RealFileSystem.rename(source, destination) do
        :ok
      end
    end

    def remove(path), do: RealFileSystem.remove(path)
    def rmdir(path), do: RealFileSystem.rmdir(path)
  end

  defmodule TempPathSwapFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def read(device, count), do: RealFileSystem.read(device, count)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def file_info(device), do: RealFileSystem.file_info(device)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def mkdir(path), do: RealFileSystem.mkdir(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)

    def open(path, modes) do
      case RealFileSystem.open(path, modes) do
        {:ok, device} = result ->
          if :exclusive in modes, do: Process.put({__MODULE__, :temp_path, device}, path)
          result

        other ->
          other
      end
    end

    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)

    def close(device) do
      temp_path = Process.delete({__MODULE__, :temp_path, device})
      result = RealFileSystem.close(device)

      if result == :ok and is_binary(temp_path) do
        :ok = File.rename(temp_path, temp_path <> ".staged")
        :ok = File.write(temp_path, "substituted")
      end

      result
    end

    def rename(source, destination), do: RealFileSystem.rename(source, destination)
    def remove(path), do: RealFileSystem.remove(path)
    def rmdir(path), do: RealFileSystem.rmdir(path)
  end

  defmodule OrphanRemoveRaisesAfterCommitFileSystem do
    @behaviour RealFileSystem

    def attach(owner), do: :persistent_term.put({__MODULE__, :owner}, owner)
    def detach, do: :persistent_term.erase({__MODULE__, :owner})

    def read(path), do: RealFileSystem.read(path)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)

    def open(path, modes) do
      case RealFileSystem.open(path, modes) do
        {:ok, device} = result ->
          Process.put({__MODULE__, :path, device}, path)
          result

        other ->
          other
      end
    end

    def write(device, contents), do: RealFileSystem.write(device, contents)

    def sync(device) do
      if owner = :persistent_term.get({__MODULE__, :owner}, nil) do
        send(owner, {:orphan_cleanup_synced, Process.get({__MODULE__, :path, device})})
      end

      RealFileSystem.sync(device)
    end

    def close(device) do
      result = RealFileSystem.close(device)
      Process.delete({__MODULE__, :path, device})
      result
    end

    def rename(source, destination), do: RealFileSystem.rename(source, destination)

    def remove(path) do
      case RealFileSystem.remove(path) do
        :ok -> raise "simulated return-path failure after orphan unlink"
        other -> other
      end
    end
  end

  defmodule ConcurrentDirectoryCreateFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def read(device, count), do: RealFileSystem.read(device, count)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def file_info(device), do: RealFileSystem.file_info(device)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)

    def mkdir(path) do
      :ok = RealFileSystem.mkdir(path)
      {:error, :eexist}
    end

    def chmod(_path, _mode), do: raise("simulated chmod failure on concurrently created directory")
    def open(path, modes), do: RealFileSystem.open(path, modes)
    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)
    def rename(source, destination), do: RealFileSystem.rename(source, destination)
    def remove(path), do: RealFileSystem.remove(path)
    def rmdir(path), do: RealFileSystem.rmdir(path)
  end

  defmodule ChmodRaisesAfterMkdirFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def read(device, count), do: RealFileSystem.read(device, count)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def file_info(device), do: RealFileSystem.file_info(device)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def mkdir(path), do: RealFileSystem.mkdir(path)
    def chmod(_path, _mode), do: raise("simulated chmod failure after mkdir")

    def open(path, modes) do
      case RealFileSystem.open(path, modes) do
        {:ok, device} = result ->
          Process.put({__MODULE__, :path, device}, path)
          result

        other ->
          other
      end
    end

    def write(device, contents), do: RealFileSystem.write(device, contents)

    def sync(device) do
      send(self(), {:chmod_cleanup_synced, Process.get({__MODULE__, :path, device})})
      RealFileSystem.sync(device)
    end

    def close(device) do
      result = RealFileSystem.close(device)
      Process.delete({__MODULE__, :path, device})
      result
    end

    def rename(source, destination), do: RealFileSystem.rename(source, destination)
    def remove(path), do: RealFileSystem.remove(path)

    def rmdir(path) do
      result = RealFileSystem.rmdir(path)
      send(self(), {:chmod_cleanup_rmdir, path, result})
      result
    end
  end

  defmodule MissingChmodFileSystem do
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def open(path, modes), do: RealFileSystem.open(path, modes)
    def write(device, contents), do: RealFileSystem.write(device, contents)
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)
    def rename(source, destination), do: RealFileSystem.rename(source, destination)
    def remove(path), do: RealFileSystem.remove(path)
  end

  defmodule TempWriteAndCleanupFailureFileSystem do
    @behaviour RealFileSystem

    def read(path), do: RealFileSystem.read(path)
    def list_dir(path), do: RealFileSystem.list_dir(path)
    def lstat(path), do: RealFileSystem.lstat(path)
    def mkdir_p(path), do: RealFileSystem.mkdir_p(path)
    def chmod(path, mode), do: RealFileSystem.chmod(path, mode)
    def open(path, modes), do: RealFileSystem.open(path, modes)
    def write(_device, _contents), do: raise("simulated temp write failure")
    def sync(device), do: RealFileSystem.sync(device)
    def close(device), do: RealFileSystem.close(device)
    def rename(source, destination), do: RealFileSystem.rename(source, destination)
    def remove(_path), do: raise("simulated temp cleanup failure")
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

    events = collect_file_system_events([])

    synced_paths =
      for {:sync, path} <- events,
          do: path

    assert Path.dirname(ctx.base) in synced_paths
    assert ctx.base in synced_paths
    assert Path.join(ctx.base, "generations") in synced_paths
    assert Path.join([ctx.base, "generations", "candidate"]) in synced_paths
    assert Path.join([ctx.base, "generations", "candidate", "chunks"]) in synced_paths

    for directory <- [
          ctx.base,
          Path.join(ctx.base, "generations"),
          Path.join([ctx.base, "generations", "candidate"]),
          Path.join([ctx.base, "generations", "candidate", "chunks"]),
          Path.join([ctx.base, "generations", "candidate", "chunks", "calibration"])
        ] do
      chmod = Enum.find_index(events, &(&1 == {:chmod, directory, 0o700}))
      assert is_integer(chmod)

      directory_sync =
        events
        |> Enum.with_index()
        |> Enum.find_value(fn
          {{:sync, ^directory}, index} when index > chmod -> index
          _event -> nil
        end)

      assert is_integer(directory_sync)
      parent = Path.dirname(directory)

      parent_sync =
        events
        |> Enum.with_index()
        |> Enum.find_value(fn
          {{:sync, ^parent}, index} when index > directory_sync -> index
          _event -> nil
        end)

      assert is_integer(parent_sync)
      assert chmod < directory_sync
      assert directory_sync < parent_sync
    end
  end

  test "hardens missing ancestors above the directory root one component at a time", ctx do
    root = Path.join([ctx.base, "nested", "root"])
    destination = Path.join([root, "child", "record"])

    assert :ok = AtomicFile.write(destination, "non-sensitive-state", directory_root: root)

    for directory <- [ctx.base, Path.join(ctx.base, "nested"), root, Path.join(root, "child")] do
      assert_mode(directory, 0o700)
    end
  end

  test "rejects a symlink descendant that escapes the directory root", ctx do
    outside =
      Path.join(System.tmp_dir!(), "desired_atomic_outside_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(outside) end)

    File.mkdir_p!(ctx.base)
    File.mkdir_p!(outside)
    escape = Path.join(ctx.base, "escape")
    File.ln_s!(outside, escape)
    destination = Path.join(escape, "record")

    assert {:error, {:pre_rename, {:invalid_directory_type, ^escape, :symlink}}} =
             AtomicFile.write(destination, "non-sensitive-state", directory_root: ctx.base)

    refute File.exists?(Path.join(outside, "record"))
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(escape)
  end

  test "rejects a missing directory root beneath a symlink parent" do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    container = Path.join(System.tmp_dir!(), "desired_atomic_root_parent_#{nonce}")
    outside = Path.join(System.tmp_dir!(), "desired_atomic_root_outside_#{nonce}")
    alias_parent = Path.join(container, "alias")
    root = Path.join(alias_parent, "missing-root")
    destination = Path.join(root, "record")

    on_exit(fn ->
      File.rm_rf(container)
      File.rm_rf(outside)
    end)

    File.mkdir_p!(container)
    File.mkdir_p!(outside)
    File.ln_s!(outside, alias_parent)

    assert {:error, {:pre_rename, {:invalid_directory_type, ^alias_parent, :symlink}}} =
             AtomicFile.write(destination, "non-sensitive-state", directory_root: root)

    refute File.exists?(Path.join([outside, "missing-root", "record"]))
  end

  test "removes and syncs a newly created directory when chmod fails", ctx do
    destination = Path.join(ctx.base, "record")

    assert {:error, {:pre_rename, {:chmod_directory, {:callback_failed, :raise}}}} =
             AtomicFile.write(destination, "non-sensitive-state",
               file_system: ChmodRaisesAfterMkdirFileSystem,
               directory_root: ctx.base
             )

    refute File.exists?(ctx.base)
    assert_receive {:chmod_cleanup_rmdir, base, :ok}
    assert base == ctx.base
    assert_receive {:chmod_cleanup_synced, parent}
    assert parent == Path.dirname(ctx.base)
  end

  test "never removes a directory created concurrently before chmod", ctx do
    destination = Path.join(ctx.base, "record")

    assert {:error, {:pre_rename, {:chmod_directory, {:callback_failed, :raise}}}} =
             AtomicFile.write(destination, "non-sensitive-state",
               file_system: ConcurrentDirectoryCreateFileSystem,
               directory_root: ctx.base
             )

    assert File.dir?(ctx.base)
    refute File.exists?(destination)
  end

  test "a temporary-name collision retries without removing another writer's file", ctx do
    File.mkdir_p!(ctx.base)
    destination = Path.join(ctx.base, "record")
    suffix = "SAMEsameSAMEsame"
    collision = destination <> ".tmp." <> suffix
    File.write!(collision, "other-writer")

    assert :ok = AtomicFile.write(destination, "ours", temp_suffix: fn -> suffix end)

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

  test "cleanup fails closed when a custom filesystem omits list_dir", ctx do
    File.mkdir_p!(ctx.base)
    destination = Path.join(ctx.base, "record")
    orphan = destination <> ".tmp.ABCDEFGHIJKLMNOP"
    File.write!(orphan, "non-sensitive-state")

    assert {:error, {:orphan_temp_cleanup, {:list_directory, {:callback_unavailable, :list_dir}}}} =
             AtomicFile.cleanup_orphan_temps(destination, file_system: LegacyFileSystem)

    assert File.exists?(orphan)
  end

  test "cleanup fails closed when a custom filesystem omits lstat", ctx do
    File.mkdir_p!(ctx.base)
    destination = Path.join(ctx.base, "record")
    orphan = destination <> ".tmp.ABCDEFGHIJKLMNOP"
    File.write!(orphan, "non-sensitive-state")

    assert {:error, {:orphan_temp_cleanup, {:lstat_temp, {:callback_unavailable, :lstat}}}} =
             AtomicFile.cleanup_orphan_temps(destination,
               file_system: MissingLstatFileSystem
             )

    assert File.exists?(orphan)
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

  test "cleanup syncs earlier removals before reporting a later invalid artifact", ctx do
    File.mkdir_p!(ctx.base)
    TracingFileSystem.attach(self())
    destination = Path.join(ctx.base, "record")
    removed = destination <> ".tmp.AAAAAAAAAAAAAAAA"
    rejected = destination <> ".tmp.BBBBBBBBBBBBBBBB"
    File.write!(removed, "non-sensitive-state")
    File.mkdir_p!(rejected)

    assert {:error, {:orphan_temp_cleanup, :invalid_temp_type}} =
             AtomicFile.cleanup_orphan_temps(destination,
               file_system: TracingFileSystem
             )

    refute File.exists?(removed)
    assert File.dir?(rejected)

    events = collect_file_system_events([])
    removal = Enum.find_index(events, &(&1 == {:remove, removed}))
    directory_sync = Enum.find_index(events, &(&1 == {:sync, ctx.base}))
    assert is_integer(removal)
    assert is_integer(directory_sync)
    assert removal < directory_sync
  end

  test "cleanup syncs a first orphan unlink whose callback return is ambiguous", ctx do
    File.mkdir_p!(ctx.base)
    OrphanRemoveRaisesAfterCommitFileSystem.attach(self())

    on_exit(fn ->
      OrphanRemoveRaisesAfterCommitFileSystem.detach()
    end)

    destination = Path.join(ctx.base, "record")
    orphan = destination <> ".tmp.AAAAAAAAAAAAAAAA"
    File.write!(orphan, "non-sensitive-state")

    assert {:error, {:orphan_temp_cleanup, {:remove_temp, {:callback_failed, :raise}}}} =
             AtomicFile.cleanup_orphan_temps(destination,
               file_system: OrphanRemoveRaisesAfterCommitFileSystem
             )

    refute File.exists?(orphan)
    assert_receive {:orphan_cleanup_synced, base}
    assert base == ctx.base
  end

  test "rejects custom temporary suffixes that orphan cleanup cannot recognize", ctx do
    destination = Path.join(ctx.base, "invalid-suffix")

    assert {:error, {:pre_rename, :invalid_temp_suffix}} =
             AtomicFile.write(destination, "non-sensitive-state", temp_suffix: fn -> "same" end)

    refute File.exists?(destination)
    assert [] == Path.wildcard(destination <> ".tmp.*")
  end

  test "missing and raising write callbacks remain typed before rename", ctx do
    missing_destination = Path.join(ctx.base, "missing-mkdir")

    assert {:error, {:pre_rename, {:callback_unavailable, :mkdir_p}}} =
             AtomicFile.write(missing_destination, "non-sensitive-state", file_system: MissingWriteCallbacksFileSystem)

    raised_destination = Path.join(ctx.base, "raising-mkdir")
    CallbackFailureFileSystem.fail(:mkdir_p, :raise)

    assert {:error, {:pre_rename, {:mkdir, {:callback_failed, :raise}}}} =
             AtomicFile.write(raised_destination, "non-sensitive-state", file_system: CallbackFailureFileSystem)

    CallbackFailureFileSystem.reset()
    refute File.exists?(missing_destination)
    refute File.exists?(raised_destination)
  end

  test "a rename callback failure after installation is durability uncertain", ctx do
    destination = Path.join(ctx.base, "rename-return-failure")

    assert {:error, {:durability_uncertain, {:rename, {:callback_failed, :raise}}}} =
             AtomicFile.write(destination, "non-sensitive-state", file_system: RenameRaisesAfterCommitFileSystem)

    assert File.read!(destination) == "non-sensitive-state"
    assert [] == Path.wildcard(destination <> ".tmp.*")
  end

  test "ambiguous rename failure never deletes a reused temporary name", ctx do
    destination = Path.join(ctx.base, "rename-reused-temp")
    suffix = "REUSEDTEMP123456"
    temp_path = destination <> ".tmp." <> suffix

    assert {:error, {:durability_uncertain, {:rename, {:callback_failed, :raise}}}} =
             AtomicFile.write(destination, "ours",
               file_system: RenameFailsAfterCommitAndRecreatesTempFileSystem,
               temp_suffix: fn -> suffix end
             )

    assert File.read!(destination) == "ours"
    assert File.read!(temp_path) == "other-writer"
  end

  test "a definite rename error remains pre-rename without optional lstat", ctx do
    destination = Path.join(ctx.base, "rename-definite-failure")

    assert {:error, {:pre_rename, {:rename, :eacces}}} =
             AtomicFile.write(destination, "non-sensitive-state",
               file_system: RenameFailsWithoutLstatFileSystem,
               temp_suffix: fn -> "DEFINITERENAME01" end
             )

    refute File.exists?(destination)
    assert [] == Path.wildcard(destination <> ".tmp.*")
  end

  test "an ambiguous open callback failure never deletes another writer's temporary path", ctx do
    destination = Path.join(ctx.base, "open-return-failure")
    suffix = "OPENFAILAFTER001"
    temp_path = destination <> ".tmp." <> suffix
    File.mkdir_p!(ctx.base)
    File.write!(temp_path, "other-writer")

    assert {:error, {:pre_rename, {:open, {:callback_failed, :raise}}}} =
             AtomicFile.write(destination, "non-sensitive-state",
               file_system: OpenRaisesBeforeAcquireFileSystem,
               temp_suffix: fn -> suffix end
             )

    refute File.exists?(destination)
    assert File.read!(temp_path) == "other-writer"
  end

  test "verifies restrictive directory mode before publishing its link", ctx do
    destination = Path.join(ctx.base, "directory-mode")

    assert {:error, {:pre_rename, {:invalid_directory_mode, base}}} =
             AtomicFile.write(destination, "ours",
               file_system: ChmodNoopFileSystem,
               directory_root: ctx.base
             )

    assert base == ctx.base
    refute File.exists?(ctx.base)
    refute File.exists?(destination)
  end

  test "verifies restrictive temporary-file mode before rename", ctx do
    File.mkdir_p!(ctx.base)
    File.chmod!(ctx.base, 0o700)
    destination = Path.join(ctx.base, "temp-mode")
    suffix = "TEMPMODECHECK001"
    temp_path = destination <> ".tmp." <> suffix

    assert {:error, {:pre_rename, {:invalid_temporary_file_mode, ^temp_path}}} =
             AtomicFile.write(destination, "ours",
               file_system: ChmodNoopFileSystem,
               directory_root: ctx.base,
               temp_suffix: fn -> suffix end
             )

    refute File.exists?(destination)
    refute File.exists?(temp_path)
  end

  test "rejects same-inode temporary content mutation before rename", ctx do
    destination = Path.join(ctx.base, "temp-content-mutation")
    suffix = "TEMPCONTENTMUT01"
    temp_path = destination <> ".tmp." <> suffix

    assert {:error, {:pre_rename, {:temporary_file_content_mismatch, ^temp_path}}} =
             AtomicFile.write(destination, "authorized",
               file_system: TempContentMutationFileSystem,
               directory_root: ctx.base,
               temp_suffix: fn -> suffix end
             )

    refute File.exists?(destination)
    refute File.exists?(temp_path)
  end

  test "does not report success when rename mutates the staged inode", ctx do
    destination = Path.join(ctx.base, "rename-content-mutation")

    assert {:error, {:durability_uncertain, {:temporary_file_content_mismatch, ^destination}}} =
             AtomicFile.write(destination, "authorized",
               file_system: RenameContentMutationFileSystem,
               directory_root: ctx.base
             )

    assert File.read!(destination) == "substitute"
  end

  test "rejects temporary pathname substitution before rename", ctx do
    destination = Path.join(ctx.base, "temp-path-substitution")
    suffix = "TEMPPATHSWAP0001"
    temp_path = destination <> ".tmp." <> suffix

    assert {:error, {:pre_rename, {:temporary_file_identity_mismatch, ^temp_path}}} =
             AtomicFile.write(destination, "ours",
               file_system: TempPathSwapFileSystem,
               directory_root: ctx.base,
               temp_suffix: fn -> suffix end
             )

    refute File.exists?(destination)
    assert File.read!(temp_path) == "substituted"
    assert File.read!(temp_path <> ".staged") == "ours"
  end

  test "preflights required callbacks before creating directories", ctx do
    destination = Path.join([ctx.base, "missing-chmod", "record"])

    assert {:error, {:pre_rename, {:callback_unavailable, :chmod}}} =
             AtomicFile.write(destination, "non-sensitive-state", file_system: MissingChmodFileSystem)

    refute File.exists?(Path.dirname(destination))
  end

  test "temp operation and cleanup callback failures remain typed", ctx do
    destination = Path.join(ctx.base, "temp-cleanup-failure")

    assert {:error,
            {:pre_rename, {{:write, {:callback_failed, :raise}}, {:temp_cleanup, {:error, {:callback_failed, :raise}}}}}} =
             AtomicFile.write(destination, "non-sensitive-state",
               file_system: TempWriteAndCleanupFailureFileSystem,
               temp_suffix: fn -> "TEMPCLEANUPFAIL1" end
             )

    refute File.exists?(destination)
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

  test "does not report success after the destination parent is replaced", ctx do
    destination = Path.join(ctx.base, "parent-replaced")
    moved_base = ctx.base <> ".moved"
    moved_destination = Path.join(moved_base, "parent-replaced")
    on_exit(fn -> File.rm_rf(moved_base) end)

    assert {:error, {:durability_uncertain, {:parent_directory_identity_mismatch, parent}}} =
             AtomicFile.write(destination, "durable-state",
               file_system: ParentSwapAfterRenameFileSystem,
               directory_root: ctx.base
             )

    assert parent == ctx.base
    refute File.exists?(destination)
    assert File.read!(moved_destination) == "durable-state"
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

  test "durably removes a temporary file after a pre-rename failure", ctx do
    TracingFileSystem.attach(self())
    destination = Path.join(ctx.base, "durable-temp-cleanup")

    assert {:error, {:pre_rename, {:fault_injected, :before_rename, :power_loss}}} =
             AtomicFile.write(destination, "non-sensitive-state",
               file_system: TracingFileSystem,
               temp_suffix: fn -> "TEMPCLEANUPSYNC1" end,
               fault_injector: fail_at(:before_rename)
             )

    temp_path = destination <> ".tmp.TEMPCLEANUPSYNC1"
    events = collect_file_system_events([])
    removal = Enum.find_index(events, &(&1 == {:remove, temp_path}))

    cleanup_sync =
      events
      |> Enum.with_index()
      |> Enum.find_value(fn
        {{:sync, path}, index} when path == ctx.base and index > removal -> index
        _event -> nil
      end)

    assert is_integer(removal)
    assert is_integer(cleanup_sync)
    assert removal < cleanup_sync
    refute File.exists?(temp_path)
  end

  test "distinguishes pre-rename failure, durability uncertainty, and durable success", ctx do
    pre_path = Path.join(ctx.base, "pre")

    assert {:error, {:pre_rename, {:fault_injected, :before_rename, :power_loss}}} =
             AtomicFile.write(pre_path, "pre",
               temp_suffix: fn -> "PREPREPREPREPRE1" end,
               fault_injector: fail_at(:before_rename)
             )

    refute File.exists?(pre_path)
    assert [] == Path.wildcard(pre_path <> ".tmp.*")

    uncertain_path = Path.join(ctx.base, "uncertain")

    assert {:error, {:durability_uncertain, {:fault_injected, :renamed, :power_loss}}} =
             AtomicFile.write(uncertain_path, "visible",
               temp_suffix: fn -> "UNCERTAIN1234567" end,
               fault_injector: fail_at(:renamed)
             )

    assert File.read!(uncertain_path) == "visible"

    durable_path = Path.join(ctx.base, "durable")

    assert :ok =
             AtomicFile.write(durable_path, "durable", fault_injector: fail_at(:parent_synced))

    assert File.read!(durable_path) == "durable"
  end

  test "remove callback failure after unlink re-establishes durable absence", ctx do
    File.mkdir_p!(ctx.base)
    destination = Path.join(ctx.base, "remove-return-failure")
    File.write!(destination, "non-sensitive-state")
    owner = self()

    assert :ok =
             AtomicFile.remove(destination,
               file_system: RemoveRaisesAfterCommitFileSystem,
               fault_injector: fn
                 :parent_synced -> send(owner, :remove_parent_synced)
                 _stage -> :ok
               end
             )

    refute File.exists?(destination)
    assert_receive :remove_parent_synced
  end

  test "does not report durable removal after the parent is replaced", ctx do
    File.mkdir_p!(ctx.base)
    destination = Path.join(ctx.base, "parent-replaced-remove")
    moved_base = ctx.base <> ".moved"
    File.write!(destination, "non-sensitive-state")
    on_exit(fn -> File.rm_rf(moved_base) end)

    assert {:error, {:durability_uncertain, {:parent_directory_identity_mismatch, parent}}} =
             AtomicFile.remove(destination,
               file_system: ParentSwapAfterRemoveFileSystem,
               directory_root: ctx.base
             )

    assert parent == ctx.base
    refute File.exists?(destination)
    refute File.exists?(Path.join(moved_base, "parent-replaced-remove"))
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
