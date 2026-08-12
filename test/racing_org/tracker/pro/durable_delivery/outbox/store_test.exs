defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.{
    FileSystem,
    Record,
    RunState,
    SegmentFileSystem,
    Snapshot,
    Store
  }

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{
    Checkpoint,
    Messages
  }

  @storage_epoch Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @device_id Base.decode16!("0f1e2d3c4b5a69788796a5b4c3d2e1f0", case: :lower)
  @other_device_id Base.decode16!("aabbccddeeff00112233445566778899", case: :lower)
  @credential_epoch 7
  @database_int_max 9_223_372_036_854_775_807
  @next_sequence_max @database_int_max + 1

  defmodule TracingFileSystem do
    @behaviour FileSystem

    def attach(owner), do: Process.put({__MODULE__, :owner}, owner)
    def fail_segment_sync, do: Process.put({__MODULE__, :fail_segment_sync}, true)
    def fail_segment_append_open, do: Process.put({__MODULE__, :fail_segment_append_open}, true)
    def fail_snapshot_read, do: Process.put({__MODULE__, :fail_snapshot_read}, true)
    def fail_run_state_rename, do: fail_run_state_rename_after(0)

    def fail_run_state_rename_after(successful_renames)
        when is_integer(successful_renames) and successful_renames >= 0,
        do: Process.put({__MODULE__, :fail_run_state_rename_after}, successful_renames)

    def fail_snapshot_rename, do: Process.put({__MODULE__, :fail_snapshot_rename}, true)

    def fail_snapshot_temp_remove,
      do: Process.put({__MODULE__, :fail_snapshot_temp_remove}, true)

    @impl true
    def read(path) do
      report({:read, path})

      if Process.get({__MODULE__, :fail_snapshot_read}, false) and
           Path.basename(path) == "snapshot.bin" do
        Process.delete({__MODULE__, :fail_snapshot_read})
        {:error, :simulated_read_failure}
      else
        FileSystem.read(path)
      end
    end

    @impl true
    def stat(path), do: FileSystem.stat(path)

    @impl true
    def list_dir(path), do: FileSystem.list_dir(path)

    @impl true
    def mkdir_p(path), do: FileSystem.mkdir_p(path)

    @impl true
    def chmod(path, mode), do: FileSystem.chmod(path, mode)

    @impl true
    def open(path, modes) do
      report({:open, path, modes})

      result =
        if Process.get({__MODULE__, :fail_segment_append_open}, false) and
             segment_path?(path) and :append in modes do
          Process.delete({__MODULE__, :fail_segment_append_open})
          {:error, :simulated_open_failure}
        else
          FileSystem.open(path, modes)
        end

      case result do
        {:ok, device} = result ->
          Process.put({__MODULE__, :path, device}, path)
          result

        error ->
          error
      end
    end

    @impl true
    def write(device, contents) do
      report({:write, device_path(device), IO.iodata_length(contents)})
      FileSystem.write(device, contents)
    end

    @impl true
    def sync(device) do
      path = device_path(device)
      report({:sync, path})

      if Process.get({__MODULE__, :fail_segment_sync}, false) and segment_path?(path) do
        Process.delete({__MODULE__, :fail_segment_sync})
        {:error, :simulated_sync_failure}
      else
        FileSystem.sync(device)
      end
    end

    @impl true
    def close(device) do
      path = device_path(device)
      report({:close, path})
      result = FileSystem.close(device)
      Process.delete({__MODULE__, :path, device})
      result
    end

    @impl true
    def rename(source, destination) do
      cond do
        is_integer(Process.get({__MODULE__, :fail_run_state_rename_after})) and
            Path.basename(destination) == "run-state.bin" ->
          case Process.get({__MODULE__, :fail_run_state_rename_after}) do
            0 ->
              Process.delete({__MODULE__, :fail_run_state_rename_after})
              {:error, :simulated_rename_failure}

            remaining ->
              Process.put({__MODULE__, :fail_run_state_rename_after}, remaining - 1)
              FileSystem.rename(source, destination)
          end

        Process.get({__MODULE__, :fail_snapshot_rename}, false) and
            Path.basename(destination) == "snapshot.bin" ->
          Process.delete({__MODULE__, :fail_snapshot_rename})
          {:error, :simulated_rename_failure}

        true ->
          FileSystem.rename(source, destination)
      end
    end

    @impl true
    def remove(path) do
      if Process.get({__MODULE__, :fail_snapshot_temp_remove}, false) and
           String.starts_with?(Path.basename(path), "snapshot.bin.tmp.") do
        Process.delete({__MODULE__, :fail_snapshot_temp_remove})
        {:error, :simulated_remove_failure}
      else
        FileSystem.remove(path)
      end
    end

    @impl true
    def position(device, location), do: FileSystem.position(device, location)

    @impl true
    def truncate(device), do: FileSystem.truncate(device)

    defp device_path(device), do: Process.get({__MODULE__, :path, device})
    defp segment_path?(path), do: is_binary(path) and String.ends_with?(path, ".log")

    defp report(event) do
      if owner = Process.get({__MODULE__, :owner}), do: send(owner, {:outbox_file_system, event})
    end
  end

  defmodule TracingSegmentFileSystem do
    @behaviour SegmentFileSystem

    def attach(owner), do: Process.put({__MODULE__, :owner}, owner)

    def fail(operations) when is_list(operations) do
      Process.put({__MODULE__, :failures}, MapSet.new(operations))
    end

    def fail(operation), do: fail([operation])

    @impl true
    def open_root(file_system, path, identity) do
      report({:open_root, path, identity})

      cond do
        fail?(:stale_root) ->
          {:error, :stale_root}

        fail?(:open_root) ->
          {:error, :simulated_open_root_failure}

        true ->
          open_root(file_system, path, identity, SegmentFileSystem.open_root(file_system, path, identity))
      end
    end

    defp open_root(_file_system, path, _identity, result) do
      case result do
        {:ok, root} = result ->
          Process.put({__MODULE__, :root_path, root}, path)
          result

        error ->
          error
      end
    end

    @impl true
    def close_root(root) do
      report({:close_root, root_path(root)})
      result = SegmentFileSystem.close_root(root)
      Process.delete({__MODULE__, :root_path, root})

      if fail?(:close_root),
        do: {:error, :simulated_close_root_failure},
        else: result
    end

    @impl true
    def try_lock_root(root), do: SegmentFileSystem.try_lock_root(root)

    @impl true
    def create(root, basename, mode) do
      path = Path.join(root_path(root), basename)
      report({:create, path, mode})

      result =
        if fail?(:create),
          do: {:error, :simulated_open_failure},
          else: SegmentFileSystem.create(root, basename, mode)

      case result do
        {:ok, segment} = success ->
          Process.put({__MODULE__, :segment_path, segment}, path)
          success

        error ->
          error
      end
    end

    @impl true
    def chmod(segment, mode) do
      report({:chmod, segment_path(segment), mode})

      if fail?(:chmod),
        do: {:error, :simulated_chmod_failure},
        else: SegmentFileSystem.chmod(segment, mode)
    end

    @impl true
    def write(segment, contents) do
      report({:write, segment_path(segment), IO.iodata_length(contents)})

      if fail?(:write),
        do: {:error, :simulated_write_failure},
        else: SegmentFileSystem.write(segment, contents)
    end

    @impl true
    def sync_file(segment) do
      report({:sync_file, segment_path(segment)})

      if fail?(:sync_file),
        do: {:error, :simulated_sync_file_failure},
        else: SegmentFileSystem.sync_file(segment)
    end

    @impl true
    def sync_directory(segment) do
      report({:sync_directory, segment_path(segment)})

      if fail?(:sync_directory),
        do: {:error, :simulated_sync_directory_failure},
        else: SegmentFileSystem.sync_directory(segment)
    end

    @impl true
    def unlink_empty(segment) do
      report({:unlink_empty, segment_path(segment)})

      if fail?(:unlink_empty),
        do: {:error, :simulated_unlink_failure},
        else: SegmentFileSystem.unlink_empty(segment)
    end

    @impl true
    def file_info(segment), do: SegmentFileSystem.file_info(segment)

    @impl true
    def close(segment) do
      report({:close, segment_path(segment)})
      result = SegmentFileSystem.close(segment)
      Process.delete({__MODULE__, :segment_path, segment})

      if fail?(:close),
        do: {:error, :simulated_close_failure},
        else: result
    end

    defp fail?(operation) do
      failures = Process.get({__MODULE__, :failures}, MapSet.new())

      if MapSet.member?(failures, operation) do
        Process.put({__MODULE__, :failures}, MapSet.delete(failures, operation))
        true
      else
        false
      end
    end

    defp root_path(root), do: Process.get({__MODULE__, :root_path, root})
    defp segment_path(segment), do: Process.get({__MODULE__, :segment_path, segment})

    defp report(event) do
      if owner = Process.get({__MODULE__, :owner}), do: send(owner, {:outbox_segment_file_system, event})
    end
  end

  defmodule BlockingRecoveryFileSystem do
    @behaviour FileSystem

    def block_truncate(root, owner) do
      {:ok, canonical_root} = Store.canonical_root(root)
      :persistent_term.put({__MODULE__, canonical_root}, owner)
    end

    @impl true
    def read(path), do: FileSystem.read(path)

    @impl true
    def stat(path), do: FileSystem.stat(path)

    @impl true
    def list_dir(path), do: FileSystem.list_dir(path)

    @impl true
    def mkdir_p(path), do: FileSystem.mkdir_p(path)

    @impl true
    def chmod(path, mode), do: FileSystem.chmod(path, mode)

    @impl true
    def open(path, modes) do
      root = Path.dirname(path)
      owner = :persistent_term.get({__MODULE__, root}, nil)

      if String.ends_with?(path, ".log") and :read in modes and :write in modes and owner do
        send(owner, {:recovery_blocked, self()})

        receive do
          :continue_recovery -> :persistent_term.erase({__MODULE__, root})
        end
      end

      FileSystem.open(path, modes)
    end

    @impl true
    def write(device, contents), do: FileSystem.write(device, contents)

    @impl true
    def sync(device), do: FileSystem.sync(device)

    @impl true
    def close(device), do: FileSystem.close(device)

    @impl true
    def rename(source, destination), do: FileSystem.rename(source, destination)

    @impl true
    def remove(path), do: FileSystem.remove(path)

    @impl true
    def position(device, location), do: FileSystem.position(device, location)

    @impl true
    def truncate(device), do: FileSystem.truncate(device)
  end

  defmodule BlockingMkdirFileSystem do
    @behaviour FileSystem

    def arm(owner) do
      counter = :atomics.new(1, signed: false)
      :persistent_term.put({__MODULE__, :state}, {owner, counter})
    end

    def disarm, do: :persistent_term.erase({__MODULE__, :state})

    @impl true
    def read(path), do: FileSystem.read(path)

    @impl true
    def stat(path), do: FileSystem.stat(path)

    @impl true
    def list_dir(path), do: FileSystem.list_dir(path)

    @impl true
    def mkdir_p(path) do
      case :persistent_term.get({__MODULE__, :state}, nil) do
        {owner, counter} ->
          call = :atomics.add_get(counter, 1, 1)
          send(owner, {:mkdir_entered, call, self()})

          if call == 1 do
            receive do
              :continue_mkdir -> :ok
            end
          end

        nil ->
          :ok
      end

      FileSystem.mkdir_p(path)
    end

    @impl true
    def chmod(path, mode), do: FileSystem.chmod(path, mode)

    @impl true
    def open(path, modes), do: FileSystem.open(path, modes)

    @impl true
    def write(device, contents), do: FileSystem.write(device, contents)

    @impl true
    def sync(device), do: FileSystem.sync(device)

    @impl true
    def close(device), do: FileSystem.close(device)

    @impl true
    def rename(source, destination), do: FileSystem.rename(source, destination)

    @impl true
    def remove(path), do: FileSystem.remove(path)

    @impl true
    def position(device, location), do: FileSystem.position(device, location)

    @impl true
    def truncate(device), do: FileSystem.truncate(device)
  end

  defmodule BlockingEveryMkdirFileSystem do
    @behaviour FileSystem

    def arm(owner), do: :persistent_term.put({__MODULE__, :owner}, owner)
    def disarm, do: :persistent_term.erase({__MODULE__, :owner})

    @impl true
    def read(path), do: FileSystem.read(path)

    @impl true
    def stat(path), do: FileSystem.stat(path)

    @impl true
    def list_dir(path), do: FileSystem.list_dir(path)

    @impl true
    def mkdir_p(path) do
      if owner = :persistent_term.get({__MODULE__, :owner}, nil) do
        send(owner, {:every_mkdir_blocked, self(), path})

        receive do
          :continue_every_mkdir -> :ok
        end
      end

      FileSystem.mkdir_p(path)
    end

    @impl true
    def chmod(path, mode), do: FileSystem.chmod(path, mode)

    @impl true
    def open(path, modes), do: FileSystem.open(path, modes)

    @impl true
    def write(device, contents), do: FileSystem.write(device, contents)

    @impl true
    def sync(device), do: FileSystem.sync(device)

    @impl true
    def close(device), do: FileSystem.close(device)

    @impl true
    def rename(source, destination), do: FileSystem.rename(source, destination)

    @impl true
    def remove(path), do: FileSystem.remove(path)

    @impl true
    def position(device, location), do: FileSystem.position(device, location)

    @impl true
    def truncate(device), do: FileSystem.truncate(device)
  end

  defmodule BlockingAfterMkdirFileSystem do
    @behaviour FileSystem

    def arm(owner) do
      counter = :atomics.new(1, signed: false)
      :persistent_term.put({__MODULE__, :state}, {owner, counter})
    end

    def disarm, do: :persistent_term.erase({__MODULE__, :state})

    @impl true
    def read(path), do: FileSystem.read(path)

    @impl true
    def stat(path), do: FileSystem.stat(path)

    @impl true
    def list_dir(path), do: FileSystem.list_dir(path)

    @impl true
    def mkdir_p(path) do
      with :ok <- FileSystem.mkdir_p(path) do
        case :persistent_term.get({__MODULE__, :state}, nil) do
          {owner, counter} ->
            if :atomics.add_get(counter, 1, 1) <= 2 do
              send(owner, {:mkdir_completed, self(), path})

              receive do
                :continue_completed_mkdir -> :ok
              end
            else
              :ok
            end

          nil ->
            :ok
        end
      end
    end

    @impl true
    def chmod(path, mode), do: FileSystem.chmod(path, mode)

    @impl true
    def open(path, modes), do: FileSystem.open(path, modes)

    @impl true
    def write(device, contents), do: FileSystem.write(device, contents)

    @impl true
    def sync(device), do: FileSystem.sync(device)

    @impl true
    def close(device), do: FileSystem.close(device)

    @impl true
    def rename(source, destination), do: FileSystem.rename(source, destination)

    @impl true
    def remove(path), do: FileSystem.remove(path)

    @impl true
    def position(device, location), do: FileSystem.position(device, location)

    @impl true
    def truncate(device), do: FileSystem.truncate(device)
  end

  defmodule BlockingAppendOpenFileSystem do
    @behaviour FileSystem

    def arm(owner) do
      counter = :atomics.new(1, signed: false)
      :persistent_term.put({__MODULE__, :state}, {owner, counter})
    end

    def disarm, do: :persistent_term.erase({__MODULE__, :state})

    @impl true
    def read(path), do: FileSystem.read(path)

    @impl true
    def stat(path), do: FileSystem.stat(path)

    @impl true
    def list_dir(path), do: FileSystem.list_dir(path)

    @impl true
    def mkdir_p(path), do: FileSystem.mkdir_p(path)

    @impl true
    def chmod(path, mode), do: FileSystem.chmod(path, mode)

    @impl true
    def open(path, modes) do
      case :persistent_term.get({__MODULE__, :state}, nil) do
        {owner, counter} when is_binary(path) ->
          if String.ends_with?(path, ".log") and :append in modes and
               :atomics.add_get(counter, 1, 1) == 1 do
            send(owner, {:append_open_blocked, self()})

            receive do
              :continue_append_open -> :ok
            end
          end

        _state ->
          :ok
      end

      FileSystem.open(path, modes)
    end

    @impl true
    def write(device, contents), do: FileSystem.write(device, contents)

    @impl true
    def sync(device), do: FileSystem.sync(device)

    @impl true
    def close(device), do: FileSystem.close(device)

    @impl true
    def rename(source, destination), do: FileSystem.rename(source, destination)

    @impl true
    def remove(path), do: FileSystem.remove(path)

    @impl true
    def position(device, location), do: FileSystem.position(device, location)

    @impl true
    def truncate(device), do: FileSystem.truncate(device)
  end

  defmodule MutateAfterAppendOpenFileSystem do
    @behaviour FileSystem

    def arm, do: Process.put({__MODULE__, :armed}, true)

    @impl true
    def read(path), do: FileSystem.read(path)

    @impl true
    def stat(path), do: FileSystem.stat(path)

    @impl true
    def list_dir(path), do: FileSystem.list_dir(path)

    @impl true
    def mkdir_p(path), do: FileSystem.mkdir_p(path)

    @impl true
    def chmod(path, mode), do: FileSystem.chmod(path, mode)

    @impl true
    def open(path, modes) do
      result = FileSystem.open(path, modes)

      if Process.get({__MODULE__, :armed}, false) and is_binary(path) and :append in modes do
        Process.delete({__MODULE__, :armed})
        File.write!(path, "X", [:append])
      end

      result
    end

    @impl true
    def write(device, contents), do: FileSystem.write(device, contents)

    @impl true
    def sync(device), do: FileSystem.sync(device)

    @impl true
    def close(device), do: FileSystem.close(device)

    @impl true
    def rename(source, destination), do: FileSystem.rename(source, destination)

    @impl true
    def remove(path), do: FileSystem.remove(path)

    @impl true
    def position(device, location), do: FileSystem.position(device, location)

    @impl true
    def truncate(device), do: FileSystem.truncate(device)
  end

  defmodule AppendDescriptorRootAbaFileSystem do
    @behaviour FileSystem

    def arm(root, replacement, displaced) do
      :persistent_term.put({__MODULE__, :swap}, {root, replacement, displaced})
    end

    def disarm, do: :persistent_term.erase({__MODULE__, :swap})

    @impl true
    def read(path), do: FileSystem.read(path)

    @impl true
    def stat(path), do: FileSystem.stat(path)

    @impl true
    def list_dir(path), do: FileSystem.list_dir(path)

    @impl true
    def mkdir_p(path), do: FileSystem.mkdir_p(path)

    @impl true
    def chmod(path, mode), do: FileSystem.chmod(path, mode)

    @impl true
    def open(path, modes) do
      case :persistent_term.get({__MODULE__, :swap}, nil) do
        {root, replacement, displaced} ->
          if is_binary(path) and :append in modes and Path.dirname(path) == root do
            disarm()
            File.rename!(root, displaced)
            File.rename!(replacement, root)

            try do
              FileSystem.open(path, modes)
            after
              File.rename!(root, replacement)
              File.rename!(displaced, root)
            end
          else
            FileSystem.open(path, modes)
          end

        nil ->
          FileSystem.open(path, modes)
      end
    end

    @impl true
    def write(device, contents), do: FileSystem.write(device, contents)

    @impl true
    def sync(device), do: FileSystem.sync(device)

    @impl true
    def close(device), do: FileSystem.close(device)

    @impl true
    def rename(source, destination), do: FileSystem.rename(source, destination)

    @impl true
    def remove(path), do: FileSystem.remove(path)

    @impl true
    def position(device, location), do: FileSystem.position(device, location)

    @impl true
    def truncate(device), do: FileSystem.truncate(device)
  end

  defmodule CreateSegmentRootAbaFileSystem do
    @behaviour SegmentFileSystem

    def arm(owner, root, replacement, displaced) do
      Process.put({__MODULE__, :swap}, {owner, root, replacement, displaced})
    end

    def disarm, do: Process.delete({__MODULE__, :swap})

    @impl true
    def open_root(file_system, path, identity), do: SegmentFileSystem.open_root(file_system, path, identity)

    @impl true
    def close_root(root), do: SegmentFileSystem.close_root(root)

    @impl true
    def try_lock_root(root), do: SegmentFileSystem.try_lock_root(root)

    @impl true
    def create(root_resource, basename, mode) do
      case Process.get({__MODULE__, :swap}) do
        {owner, root, replacement, displaced} ->
          disarm()
          File.rename!(root, displaced)
          File.rename!(replacement, root)

          try do
            result = SegmentFileSystem.create(root_resource, basename, mode)
            send(owner, {:create_segment_root_aba_fired, basename})
            result
          after
            File.rename!(root, replacement)
            File.rename!(displaced, root)
          end

        nil ->
          SegmentFileSystem.create(root_resource, basename, mode)
      end
    end

    @impl true
    def chmod(segment, mode), do: SegmentFileSystem.chmod(segment, mode)

    @impl true
    def write(segment, contents), do: SegmentFileSystem.write(segment, contents)

    @impl true
    def sync_file(segment), do: SegmentFileSystem.sync_file(segment)

    @impl true
    def sync_directory(segment), do: SegmentFileSystem.sync_directory(segment)

    @impl true
    def unlink_empty(segment), do: SegmentFileSystem.unlink_empty(segment)

    @impl true
    def file_info(segment), do: SegmentFileSystem.file_info(segment)

    @impl true
    def close(segment), do: SegmentFileSystem.close(segment)
  end

  defmodule SwapAfterDirectoryCloseFileSystem do
    @behaviour FileSystem

    def arm(root, replacement, displaced) do
      :persistent_term.put({__MODULE__, :swap}, {root, replacement, displaced})
    end

    def disarm, do: :persistent_term.erase({__MODULE__, :swap})

    @impl true
    def read(path), do: FileSystem.read(path)

    @impl true
    def stat(path), do: FileSystem.stat(path)

    @impl true
    def list_dir(path), do: FileSystem.list_dir(path)

    @impl true
    def mkdir_p(path), do: FileSystem.mkdir_p(path)

    @impl true
    def chmod(path, mode), do: FileSystem.chmod(path, mode)

    @impl true
    def open(path, modes) do
      case FileSystem.open(path, modes) do
        {:ok, device} = result ->
          Process.put({__MODULE__, :path, device}, path)
          result

        error ->
          error
      end
    end

    @impl true
    def write(device, contents), do: FileSystem.write(device, contents)

    @impl true
    def sync(device), do: FileSystem.sync(device)

    @impl true
    def close(device) do
      path = Process.get({__MODULE__, :path, device})
      result = FileSystem.close(device)
      Process.delete({__MODULE__, :path, device})

      case :persistent_term.get({__MODULE__, :swap}, nil) do
        {^path, replacement, displaced} when result == :ok ->
          disarm()
          File.rename!(path, displaced)
          File.rename!(replacement, path)
          :ok

        _state ->
          result
      end
    end

    @impl true
    def rename(source, destination), do: FileSystem.rename(source, destination)

    @impl true
    def remove(path), do: FileSystem.remove(path)

    @impl true
    def position(device, location), do: FileSystem.position(device, location)

    @impl true
    def truncate(device), do: FileSystem.truncate(device)
  end

  defmodule ReentrantAppendFileSystem do
    @behaviour FileSystem

    def arm(store, owner, entry_id) do
      Process.put({__MODULE__, :store}, store)
      Process.put({__MODULE__, :owner}, owner)
      Process.put({__MODULE__, :entry_id}, entry_id)
      Process.put({__MODULE__, :armed}, true)
    end

    @impl true
    def read(path), do: FileSystem.read(path)

    @impl true
    def stat(path), do: FileSystem.stat(path)

    @impl true
    def list_dir(path), do: FileSystem.list_dir(path)

    @impl true
    def mkdir_p(path), do: FileSystem.mkdir_p(path)

    @impl true
    def chmod(path, mode), do: FileSystem.chmod(path, mode)

    @impl true
    def open(path, modes) do
      if Process.get({__MODULE__, :armed}, false) and String.ends_with?(path, ".log") and
           :append in modes do
        Process.delete({__MODULE__, :armed})
        store = Process.get({__MODULE__, :store})
        owner = Process.get({__MODULE__, :owner})
        entry_id = Process.get({__MODULE__, :entry_id})
        result = Store.enqueue(store, :telemetry, "nested-append", entry_id: entry_id)
        send(owner, {:reentrant_append, result})
      end

      FileSystem.open(path, modes)
    end

    @impl true
    def write(device, contents), do: FileSystem.write(device, contents)

    @impl true
    def sync(device), do: FileSystem.sync(device)

    @impl true
    def close(device), do: FileSystem.close(device)

    @impl true
    def rename(source, destination), do: FileSystem.rename(source, destination)

    @impl true
    def remove(path), do: FileSystem.remove(path)

    @impl true
    def position(device, location), do: FileSystem.position(device, location)

    @impl true
    def truncate(device), do: FileSystem.truncate(device)
  end

  defmodule CollisionFileSystem do
    @behaviour FileSystem

    @impl true
    def read(path), do: FileSystem.read(path)

    @impl true
    def stat(path), do: FileSystem.stat(path)

    @impl true
    def list_dir(path), do: FileSystem.list_dir(path)

    @impl true
    def mkdir_p(path), do: FileSystem.mkdir_p(path)

    @impl true
    def chmod(path, mode), do: FileSystem.chmod(path, mode)

    @impl true
    def open(path, modes) do
      if String.contains?(path, "/quarantine/") and :exclusive in modes and
           :persistent_term.get({__MODULE__, :inject_collision}, true) do
        File.write!(path, "prior-forensic-copy")
        :persistent_term.put({__MODULE__, :inject_collision}, false)
        {:error, :eexist}
      else
        FileSystem.open(path, modes)
      end
    end

    @impl true
    def write(device, contents), do: FileSystem.write(device, contents)

    @impl true
    def sync(device), do: FileSystem.sync(device)

    @impl true
    def close(device), do: FileSystem.close(device)

    @impl true
    def rename(source, destination), do: FileSystem.rename(source, destination)

    @impl true
    def remove(path), do: FileSystem.remove(path)

    @impl true
    def position(device, location), do: FileSystem.position(device, location)

    @impl true
    def truncate(device), do: FileSystem.truncate(device)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "durable_outbox_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "allocates only wire-safe sequences and stops generic enqueue at the frozen bound", %{
    root: root
  } do
    assert {:ok, store} = open_store(root)
    assert {:ok, seed, store} = Store.enqueue(store, :telemetry, "seed", entry_id: entry_id(1))
    assert {:ok, [^seed], _store} = Store.acknowledge(store, receipt_for(seed))
    rewrite_next_sequence!(root, "telemetry", @database_int_max)

    test_pid = self()

    generator = fn ->
      send(test_pid, :generic_entry_id_generated)
      entry_id(2)
    end

    assert {:ok, store} = open_store(root, entry_id_generator: generator)
    assert Store.next_sequence(store, :telemetry) == {:ok, @database_int_max}

    assert {:ok, entry, exhausted} = Store.enqueue(store, :telemetry, "last-wire-safe")
    assert_receive :generic_entry_id_generated
    assert entry.sequence == @database_int_max
    assert Store.next_sequence(exhausted, :telemetry) == {:ok, @next_sequence_max}

    assert {:error, :sequence_exhausted} =
             Store.enqueue(exhausted, :telemetry, "cannot-transmit")

    refute_receive :generic_entry_id_generated
    assert Enum.map(Store.pending(exhausted), & &1.sequence) == [@database_int_max]

    assert {:ok, reopened} = open_store(root, entry_id_generator: generator)
    assert Store.next_sequence(reopened, :telemetry) == {:ok, @next_sequence_max}
    assert {:error, :sequence_exhausted} = Store.enqueue(reopened, :telemetry, "still-exhausted")
    refute_receive :generic_entry_id_generated
  end

  test "stops checkpoint allocation before entry-id generation or builder execution", %{root: root} do
    assert {:ok, store} = open_store(root, streams: [:checkpoint])

    assert {:ok, seed, store} =
             Store.enqueue_checkpoint(
               store,
               fn 1 -> checkpoint_delivery(1, <<0::256>>) end,
               entry_id: entry_id(1)
             )

    assert {:ok, [^seed], _store} = Store.acknowledge(store, receipt_for(seed))
    rewrite_next_sequence!(root, "checkpoint", @database_int_max)

    test_pid = self()

    generator = fn ->
      send(test_pid, :checkpoint_entry_id_generated)
      entry_id(2)
    end

    assert {:ok, store} =
             open_store(root, streams: [:checkpoint], entry_id_generator: generator)

    assert {:ok, entry, exhausted} =
             Store.enqueue_checkpoint(store, fn sequence ->
               send(test_pid, {:checkpoint_builder_ran, sequence})
               checkpoint_delivery(sequence, <<0::256>>)
             end)

    assert_receive :checkpoint_entry_id_generated
    assert_receive {:checkpoint_builder_ran, @database_int_max}
    assert entry.sequence == @database_int_max
    assert Store.next_sequence(exhausted, :checkpoint) == {:ok, @next_sequence_max}

    assert {:error, :sequence_exhausted} =
             Store.enqueue_checkpoint(exhausted, fn sequence ->
               send(test_pid, {:exhausted_checkpoint_builder_ran, sequence})
               {:error, :builder_ran_after_exhaustion}
             end)

    refute_receive :checkpoint_entry_id_generated
    refute_receive {:exhausted_checkpoint_builder_ran, _sequence}
  end

  test "appends and fsyncs before enqueue succeeds, then recovers entries and sequences", %{root: root} do
    TracingSegmentFileSystem.attach(self())

    assert {:ok, store} =
             open_store(root,
               segment_file_system: TracingSegmentFileSystem
             )

    assert {:ok, first, store} =
             Store.enqueue(store, :telemetry, "first", entry_id: entry_id(1), priority: 7)

    events = drain_segment_events([])
    segment_path = Enum.find_value(events, &created_segment_path/1)

    write_index =
      event_index(events, fn
        {:write, path, _size} -> path == segment_path
        _event -> false
      end)

    file_sync_index =
      event_index(events, fn
        {:sync_file, path} -> path == segment_path
        _event -> false
      end)

    directory_sync_index =
      event_index(events, fn
        {:sync_directory, path} -> path == segment_path
        _event -> false
      end)

    close_index =
      event_index(events, fn
        {:close, path} -> path == segment_path
        _event -> false
      end)

    assert write_index < file_sync_index
    assert file_sync_index < directory_sync_index
    assert directory_sync_index < close_index
    assert first.sequence == 1
    assert first.storage_epoch == @storage_epoch
    assert first.payload_hash == :crypto.hash(:sha256, "first")

    assert {:ok, second, store} =
             Store.enqueue(store, :health, "second", entry_id: entry_id(2), priority: 3)

    assert second.sequence == 1
    assert Store.next_sequence(store, :telemetry) == {:ok, 2}
    assert Store.next_sequence(store, :health) == {:ok, 2}

    assert {:ok, recovered} = open_store(root)

    assert Enum.map(Store.pending(recovered), &{&1.stream, &1.sequence, &1.payload}) == [
             {:telemetry, 1, "first"},
             {:health, 1, "second"}
           ]

    assert Store.next_sequence(recovered, :telemetry) == {:ok, 2}
    assert Store.next_sequence(recovered, :health) == {:ok, 2}
  end

  test "selects pending entries by stream and limit before and after replay", %{root: root} do
    assert {:ok, store} = open_store(root)

    assert {:ok, _telemetry_low, store} =
             Store.enqueue(store, :telemetry, "telemetry-low",
               entry_id: entry_id(1),
               priority: 1
             )

    assert {:ok, _health_high, store} =
             Store.enqueue(store, :health, "health-high",
               entry_id: entry_id(2),
               priority: 9
             )

    assert {:ok, _telemetry_high, store} =
             Store.enqueue(store, :telemetry, "telemetry-high",
               entry_id: entry_id(3),
               priority: 7
             )

    assert Enum.map(Store.pending(store, limit: 2), & &1.payload) == [
             "health-high",
             "telemetry-high"
           ]

    assert Enum.map(Store.pending(store, stream: :telemetry), & &1.payload) == [
             "telemetry-high",
             "telemetry-low"
           ]

    assert Enum.map(Store.pending(store, stream: :telemetry, limit: 1), & &1.payload) == [
             "telemetry-high"
           ]

    assert {:error, :unknown_stream} = Store.pending(store, stream: :not_configured)
    assert {:error, :invalid_limit} = Store.pending(store, limit: 0)

    assert {:ok, recovered} = open_store(root)

    assert Enum.map(Store.pending(recovered, stream: :telemetry, limit: 1), & &1.payload) == [
             "telemetry-high"
           ]
  end

  test "keeps scoped pending selection consistent across acknowledgement and loss", %{root: root} do
    assert {:ok, store} = open_store(root)

    assert {:ok, telemetry_first, store} =
             Store.enqueue(store, :telemetry, "telemetry-first",
               entry_id: entry_id(1),
               priority: 1
             )

    assert {:ok, health, store} =
             Store.enqueue(store, :health, "health",
               entry_id: entry_id(2),
               priority: 9
             )

    assert {:ok, telemetry_second, store} =
             Store.enqueue(store, :telemetry, "telemetry-second",
               entry_id: entry_id(3),
               priority: 7
             )

    assert {:ok, [^telemetry_second], store} =
             Store.acknowledge(store, receipt_for(telemetry_second))

    assert Store.pending(store, stream: :telemetry) == [telemetry_first]

    health_identity =
      Map.take(health, [
        :stream,
        :device_id,
        :credential_epoch,
        :storage_epoch,
        :sequence,
        :payload_hash
      ])

    assert {:ok, ^health, store} =
             Store.authorize_loss(store, health_identity, "operator approved")

    assert Store.pending(store, limit: 1) == [telemetry_first]

    assert {:ok, telemetry_third, store} =
             Store.enqueue(store, :telemetry, "telemetry-third",
               entry_id: entry_id(4),
               priority: 5
             )

    cumulative_receipt = %{receipt_for(telemetry_third) | cumulative_sequence: 1}

    assert {:ok, [^telemetry_first, ^telemetry_third], empty} =
             Store.acknowledge(store, cumulative_receipt)

    assert Store.pending(empty, stream: :telemetry, limit: 1) == []

    assert {:ok, recovered} = open_store(root)
    assert Store.pending(recovered, stream: :telemetry, limit: 1) == []
  end

  test "raw enqueue cannot write the reserved checkpoint stream", %{root: root} do
    assert {:ok, store} = open_store(root, streams: [:checkpoint])

    assert {:error, :checkpoint_builder_required} =
             Store.enqueue(
               store,
               :checkpoint,
               "arbitrary-checkpoint-bytes",
               entry_id: entry_id(1),
               priority: 255
             )

    assert Store.pending(store) == []
    assert Store.next_sequence(store, :checkpoint) == {:ok, 1}
  end

  test "checkpoint builder receives the locked sequence before hashing and append", %{root: root} do
    assert {:ok, store} = open_store(root, streams: [:checkpoint])

    assert {:ok, entry, store} =
             Store.enqueue_checkpoint(
               store,
               fn 1 -> checkpoint_delivery(1, <<0::256>>) end,
               entry_id: entry_id(1)
             )

    assert entry.stream == :checkpoint
    assert entry.sequence == 1
    assert {:ok, submission} = Messages.decode(:checkpoint_submission, entry.payload)
    assert submission.sequence == 1
    assert entry.payload_hash == submission.checkpoint_hash
    assert entry.priority == 0
    assert Store.next_sequence(store, :checkpoint) == {:ok, 2}

    assert {:ok, recovered} = open_store(root, streams: [:checkpoint])

    assert [%{stream: :checkpoint, sequence: 1, priority: 0} = replayed] =
             Store.pending(recovered)

    assert replayed.payload == entry.payload
    assert replayed.payload_hash == entry.payload_hash
    assert replayed.payload_checksum == entry.payload_checksum
  end

  test "segment replay preserves legacy checkpoint payloads that resemble canonical headers", %{root: root} do
    File.mkdir_p!(root)

    payload =
      Contract.payload_domain(:checkpoint_submission) <>
        <<Contract.version(), 0x31, 0, 1, 2, 3>>

    payload_hash = :crypto.hash(:sha256, payload)

    assert {:ok, encoded} =
             Record.encode(%{
               kind: :entry,
               stream: "checkpoint",
               device_id: @device_id,
               credential_epoch: @credential_epoch,
               storage_epoch: @storage_epoch,
               sequence: 1,
               entry_id: entry_id(1),
               payload_hash: payload_hash,
               payload: payload,
               priority: 0
             })

    File.write!(Path.join(root, "segment-00000000000000000001.log"), encoded)

    assert {:ok, recovered} = open_store(root, streams: [:checkpoint])
    assert [entry] = Store.pending(recovered)
    assert entry.payload == payload
    assert entry.payload_hash == payload_hash
    assert entry.payload_checksum == payload_hash
  end

  test "segment replay rejects canonical checkpoint submissions with stale durable identity", %{
    root: root
  } do
    File.mkdir_p!(root)
    {:ok, delivery} = checkpoint_delivery(1, <<0::256>>)
    {:ok, submission} = Messages.decode(:checkpoint_submission, delivery.payload)
    stale_submission = %{submission | storage_epoch: <<0x11::128>>}

    assert {:ok, checkpoint_hash} =
             stale_submission
             |> Map.drop([:checkpoint_hash, :content])
             |> Checkpoint.hash()

    assert {:ok, payload} =
             stale_submission
             |> Map.put(:checkpoint_hash, checkpoint_hash)
             |> then(&Messages.encode(:checkpoint_submission, &1))

    assert {:ok, encoded} =
             Record.encode(%{
               kind: :entry,
               stream: "checkpoint",
               device_id: @device_id,
               credential_epoch: @credential_epoch,
               storage_epoch: @storage_epoch,
               sequence: 1,
               entry_id: entry_id(1),
               payload_hash: :crypto.hash(:sha256, payload),
               payload: payload,
               priority: 0
             })

    segment = Path.join(root, "segment-00000000000000000001.log")
    File.write!(segment, encoded)

    assert {:error, {:quarantined, :checkpoint_submission_mismatch, quarantine_path}} =
             open_store(root, streams: [:checkpoint])

    assert File.exists?(quarantine_path)
  end

  test "segment replay preserves arbitrary-binary legacy checkpoint entries", %{root: root} do
    File.mkdir_p!(root)
    payload = "legacy-checkpoint-payload"
    payload_hash = :crypto.hash(:sha256, payload)

    assert {:ok, encoded} =
             Record.encode(%{
               kind: :entry,
               stream: "checkpoint",
               device_id: @device_id,
               credential_epoch: @credential_epoch,
               storage_epoch: @storage_epoch,
               sequence: 1,
               entry_id: entry_id(1),
               payload_hash: payload_hash,
               payload: payload,
               priority: 0
             })

    File.write!(Path.join(root, "segment-00000000000000000001.log"), encoded)

    assert {:ok, recovered} = open_store(root, streams: [:checkpoint])
    assert [entry] = Store.pending(recovered)
    assert entry.payload == payload
    assert entry.payload_hash == payload_hash
    assert entry.payload_checksum == payload_hash
  end

  test "legacy arbitrary-binary checkpoint entries survive current snapshot compaction", %{root: root} do
    File.mkdir_p!(root)
    payload = "legacy-checkpoint-payload"
    payload_hash = :crypto.hash(:sha256, payload)

    assert {:ok, encoded} =
             Record.encode(%{
               kind: :entry,
               stream: "checkpoint",
               device_id: @device_id,
               credential_epoch: @credential_epoch,
               storage_epoch: @storage_epoch,
               sequence: 1,
               entry_id: entry_id(1),
               payload_hash: payload_hash,
               payload: payload,
               priority: 0
             })

    File.write!(Path.join(root, "segment-00000000000000000001.log"), encoded)
    assert {:ok, recovered} = open_store(root, streams: [:checkpoint])

    assert {:ok, second, recovered} =
             Store.enqueue_checkpoint(
               recovered,
               fn 2 -> checkpoint_delivery(2, <<0::256>>) end,
               entry_id: entry_id(2)
             )

    assert {:ok, [^second], compacted} = Store.acknowledge(recovered, receipt_for(second))
    assert segment_paths(root) == []
    assert [legacy] = Store.pending(compacted)
    assert legacy.payload_hash == payload_hash
    assert legacy.payload_checksum == payload_hash

    assert {:ok, reopened} = open_store(root, streams: [:checkpoint])
    assert [hydrated] = Store.pending(reopened)
    assert hydrated.payload == payload
    assert hydrated.payload_hash == payload_hash
    assert hydrated.payload_checksum == payload_hash
  end

  test "checkpoint durable identity survives segment replay and current snapshot hydration", %{root: root} do
    assert {:ok, store} = open_store(root, streams: [:checkpoint])

    assert {:ok, fresh, _store} =
             Store.enqueue_checkpoint(
               store,
               fn 1 -> checkpoint_delivery(1, <<0::256>>) end,
               entry_id: entry_id(1)
             )

    assert fresh.payload_hash != fresh.payload_checksum

    assert {:ok, segment_replayed} = open_store(root, streams: [:checkpoint])
    assert [segment_entry] = Store.pending(segment_replayed)

    assert Map.take(segment_entry, [:payload_hash, :payload_checksum, :payload]) ==
             Map.take(fresh, [:payload_hash, :payload_checksum, :payload])

    assert {:ok, second, segment_replayed} =
             Store.enqueue_checkpoint(
               segment_replayed,
               fn 2 -> checkpoint_delivery(2, fresh.payload_hash) end,
               entry_id: entry_id(2)
             )

    assert {:ok, [^second], compacted} = Store.acknowledge(segment_replayed, receipt_for(second))
    assert Store.pending(compacted) == [fresh]
    assert segment_paths(root) == []

    assert {:ok, snapshot} =
             root
             |> Path.join("snapshot.bin")
             |> File.read!()
             |> Snapshot.decode()

    assert snapshot["schema_version"] == 4

    assert {:ok, snapshot_replayed} = open_store(root, streams: [:checkpoint])
    assert [snapshot_entry] = Store.pending(snapshot_replayed)

    assert Map.take(snapshot_entry, [:payload_hash, :payload_checksum, :payload]) ==
             Map.take(fresh, [:payload_hash, :payload_checksum, :payload])
  end

  test "checkpoint builder rejects malformed semantic identities without consuming storage", %{root: root} do
    assert {:ok, store} = open_store(root, streams: [:checkpoint])

    for result <- [
          {:ok, "legacy-payload"},
          {:ok, %{payload: "checkpoint", payload_hash: <<0::248>>}},
          {:ok, %{payload: "checkpoint", payload_hash: <<0::256>>, extra: true}}
        ] do
      assert {:error, :invalid_checkpoint_builder_result} =
               Store.enqueue_checkpoint(
                 store,
                 fn 1 -> result end,
                 entry_id: entry_id(1)
               )

      assert Store.pending(store) == []
      assert Store.next_sequence(store, :checkpoint) == {:ok, 1}
      assert segment_paths(root) == []
    end
  end

  test "checkpoint builder cannot decouple payload from the locked receipt identity", %{root: root} do
    assert {:ok, store} = open_store(root, streams: [:checkpoint])

    invalid_builders = [
      fn sequence ->
        {:ok, delivery} = checkpoint_delivery(sequence, <<0::256>>)
        {:ok, %{delivery | payload_hash: <<0xA5::256>>}}
      end,
      fn sequence -> checkpoint_delivery(sequence + 1, <<0::256>>) end,
      fn sequence ->
        {:ok, delivery} = checkpoint_delivery(sequence, <<0::256>>)
        {:ok, submission} = Messages.decode(:checkpoint_submission, delivery.payload)
        submission = %{submission | storage_epoch: <<0x11::128>>}

        {:ok, checkpoint_hash} =
          submission
          |> Map.drop([:checkpoint_hash, :content])
          |> Checkpoint.hash()

        submission = %{submission | checkpoint_hash: checkpoint_hash}
        {:ok, payload} = Messages.encode(:checkpoint_submission, submission)
        {:ok, %{payload: payload, payload_hash: checkpoint_hash}}
      end
    ]

    for builder <- invalid_builders do
      assert {:error, :checkpoint_submission_mismatch} =
               Store.enqueue_checkpoint(store, builder, entry_id: entry_id(1))

      assert Store.pending(store) == []
      assert Store.next_sequence(store, :checkpoint) == {:ok, 1}
      assert segment_paths(root) == []
    end
  end

  test "checkpoint builder failure consumes neither sequence nor storage", %{root: root} do
    assert {:ok, store} = open_store(root, streams: [:checkpoint])

    assert {:error, :checkpoint_build_failed} =
             Store.enqueue_checkpoint(
               store,
               fn 1 -> {:error, :checkpoint_build_failed} end,
               entry_id: entry_id(1)
             )

    assert Store.pending(store) == []
    assert Store.next_sequence(store, :checkpoint) == {:ok, 1}
    assert segment_paths(root) == []

    assert {:ok, entry, _store} =
             Store.enqueue_checkpoint(
               store,
               fn 1 -> checkpoint_delivery(1, <<0::256>>) end,
               entry_id: entry_id(1)
             )

    assert entry.sequence == 1
  end

  test "a sync failure never returns enqueue success and reboot recovers any uncertain append", %{root: root} do
    assert {:ok, store} = open_store(root, file_system: TracingFileSystem)
    assert {:ok, _first, store} = Store.enqueue(store, :telemetry, "first", entry_id: entry_id(1))

    TracingFileSystem.attach(self())
    TracingFileSystem.fail_segment_sync()

    assert {:error, {:durability_uncertain, {:file_sync, :simulated_sync_failure}}} =
             Store.enqueue(store, :telemetry, "written-before-failed-sync", entry_id: entry_id(2))

    assert {:ok, recovered} = open_store(root)
    assert Enum.map(Store.pending(recovered), & &1.payload) == ["first", "written-before-failed-sync"]
    assert Store.next_sequence(recovered, :telemetry) == {:ok, 3}
  end

  test "a run-state publication failure is uncertain and reboot advances it from the durable append", %{root: root} do
    assert {:ok, store} = open_store(root, file_system: TracingFileSystem)
    TracingFileSystem.fail_run_state_rename()

    assert {:error, {:durability_uncertain, {:run_state_rename, :simulated_rename_failure}}} =
             Store.enqueue(store, :telemetry, "durable-before-sidecar", entry_id: entry_id(1))

    assert Enum.any?(File.ls!(root), &String.starts_with?(&1, "run-state.bin.tmp."))

    assert {:ok, recovered} = open_store(root)
    assert Enum.map(Store.pending(recovered), & &1.payload) == ["durable-before-sidecar"]
    assert Store.next_sequence(recovered, :telemetry) == {:ok, 2}
    refute Enum.any?(File.ls!(root), &String.starts_with?(&1, "run-state.bin.tmp."))
  end

  test "compacts resolved history so repeated delivery has no finite write lifetime", %{root: root} do
    assert {:ok, store} =
             open_store(root,
               segment_max_bytes: 300,
               max_disk_bytes: 2_400,
               max_entry_id_tombstones: 1,
               max_resolved_receipts: 1
             )

    store =
      Enum.reduce(1..20, store, fn sequence, acc ->
        assert {:ok, entry, acc} =
                 Store.enqueue(acc, :telemetry, "payload-#{sequence}", entry_id: entry_id(sequence))

        assert {:ok, [^entry], acc} = Store.acknowledge(acc, receipt_for(entry))
        assert Store.pending(acc) == []
        assert length(acc.entry_id_tombstones) == 1
        assert length(acc.resolved_receipts) == 1
        assert %{disk_bytes: disk_bytes} = Store.usage(acc)
        assert disk_bytes <= 2_400
        assert disk_bytes == disk_bytes_on_disk(root)
        acc
      end)

    assert Store.next_sequence(store, :telemetry) == {:ok, 21}

    assert {:ok, recovered} =
             open_store(root,
               segment_max_bytes: 300,
               max_disk_bytes: 2_400,
               max_entry_id_tombstones: 1,
               max_resolved_receipts: 1
             )

    assert Store.pending(recovered) == []
    assert Store.next_sequence(recovered, :telemetry) == {:ok, 21}
  end

  test "cleans a newly created segment when create or chmod fails", %{root: root} do
    TracingSegmentFileSystem.attach(self())

    assert {:ok, store} =
             open_store(root,
               segment_file_system: TracingSegmentFileSystem,
               segment_max_bytes: 260
             )

    assert {:ok, _first, store} =
             Store.enqueue(store, :telemetry, String.duplicate("a", 40), entry_id: entry_id(1))

    TracingSegmentFileSystem.fail(:create)

    assert {:error, {:segment_open, :simulated_open_failure}} =
             Store.enqueue(store, :telemetry, String.duplicate("b", 40), entry_id: entry_id(2))

    assert length(segment_paths(root)) == 1

    assert {:ok, _second, _store} =
             Store.enqueue(store, :telemetry, String.duplicate("b", 40), entry_id: entry_id(2))

    chmod_root = root <> "_chmod"
    on_exit(fn -> File.rm_rf(chmod_root) end)

    assert {:ok, chmod_store} =
             open_store(chmod_root,
               segment_file_system: TracingSegmentFileSystem,
               segment_max_bytes: 260
             )

    TracingSegmentFileSystem.fail(:chmod)

    assert {:error, {:chmod_segment, :simulated_chmod_failure}} =
             Store.enqueue(chmod_store, :telemetry, "payload", entry_id: entry_id(3))

    assert segment_paths(chmod_root) == []
    assert {:ok, _entry, _store} = Store.enqueue(chmod_store, :telemetry, "payload", entry_id: entry_id(3))
  end

  test "fails closed on new-segment write and synchronization failures without cleaning the segment", %{
    root: root
  } do
    failures = [
      {:write, {:write, :simulated_write_failure}},
      {:sync_file, {:file_sync, :simulated_sync_file_failure}},
      {:sync_directory, {:directory_sync, :simulated_sync_directory_failure}}
    ]

    Enum.each(failures, fn {operation, expected} ->
      case_root = root <> "_#{operation}"
      on_exit(fn -> File.rm_rf(case_root) end)

      assert {:ok, store} =
               open_store(case_root,
                 segment_file_system: TracingSegmentFileSystem
               )

      TracingSegmentFileSystem.fail(operation)

      assert {:error, {:durability_uncertain, ^expected}} =
               Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(10))

      assert [_segment] = segment_paths(case_root)
    end)
  end

  test "fails durability closed when pre-write cleanup cannot unlink or synchronize", %{root: root} do
    failures = [
      {[:chmod, :unlink_empty],
       {:segment_cleanup_failed, {:chmod_segment, :simulated_chmod_failure},
        {:remove_segment, :simulated_unlink_failure}}},
      {[:chmod, :sync_directory],
       {:segment_cleanup_failed, {:chmod_segment, :simulated_chmod_failure},
        {:directory_sync, :simulated_sync_directory_failure}}}
    ]

    Enum.each(failures, fn {operations, expected} ->
      case_root = root <> "_#{Enum.join(operations, "_")}"
      on_exit(fn -> File.rm_rf(case_root) end)

      assert {:ok, store} =
               open_store(case_root,
                 segment_file_system: TracingSegmentFileSystem
               )

      TracingSegmentFileSystem.fail(operations)

      assert {:error, {:durability_uncertain, ^expected}} =
               Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(11))
    end)
  end

  test "fails durability closed when segment or root close fails", %{root: root} do
    cases = [
      {:close, {:close, :simulated_close_failure}},
      {:close_root, {:segment_root_close, :simulated_close_root_failure}}
    ]

    Enum.each(cases, fn {operation, expected} ->
      case_root = root <> "_#{operation}"
      on_exit(fn -> File.rm_rf(case_root) end)

      assert {:ok, store} =
               open_store(case_root,
                 segment_file_system: TracingSegmentFileSystem
               )

      TracingSegmentFileSystem.fail(operation)

      assert {:error, {:durability_uncertain, ^expected}} =
               Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(12))

      assert [_segment] = segment_paths(case_root)
    end)
  end

  test "combines create and root-close failures as durability uncertainty", %{root: root} do
    assert {:ok, store} =
             open_store(root,
               segment_file_system: TracingSegmentFileSystem
             )

    TracingSegmentFileSystem.fail([:create, :close_root])

    assert {:error,
            {:durability_uncertain,
             {:segment_root_close_failed, {:segment_open, :simulated_open_failure},
              {:segment_root_close, :simulated_close_root_failure}}}} =
             Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(13))
  end

  test "maps a stale native root binding to a stale store", %{root: root} do
    assert {:ok, store} =
             open_store(root,
               segment_file_system: TracingSegmentFileSystem
             )

    TracingSegmentFileSystem.fail(:stale_root)

    assert {:error, :stale_store} =
             Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(14))
  end

  test "surfaces ordinary native root open failures", %{root: root} do
    assert {:ok, store} =
             open_store(root,
               segment_file_system: TracingSegmentFileSystem
             )

    TracingSegmentFileSystem.fail(:open_root)

    assert {:error, {:segment_root_open, :simulated_open_root_failure}} =
             Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(15))
  end

  test "creates a rotated segment in the bound root across a pathname ABA", %{root: root} do
    replacement_root = root <> "_replacement"
    displaced_root = root <> "_displaced"
    on_exit(fn -> File.rm_rf(replacement_root) end)
    on_exit(fn -> File.rm_rf(displaced_root) end)
    on_exit(&CreateSegmentRootAbaFileSystem.disarm/0)

    assert {:ok, original} = open_store(root, segment_max_bytes: 260)
    assert {:ok, replacement} = open_store(replacement_root, segment_max_bytes: 260)

    assert {:ok, _first, original} =
             Store.enqueue(
               original,
               :telemetry,
               String.duplicate("a", 80),
               entry_id: entry_id(1)
             )

    assert {:ok, _replacement_entry, replacement} =
             Store.enqueue(
               replacement,
               :telemetry,
               String.duplicate("r", 80),
               entry_id: entry_id(2)
             )

    assert original.current_segment_bytes * 2 > original.segment_max_bytes
    replacement_next_id = replacement.current_segment_id + 1

    replacement_foreign_segment_path =
      Path.join(
        replacement.root_path,
        "segment-" <> String.pad_leading(Integer.to_string(replacement_next_id), 20, "0") <> ".log"
      )

    assert {:ok, original} =
             open_store(root,
               segment_file_system: CreateSegmentRootAbaFileSystem,
               segment_max_bytes: 260
             )

    canonical_root = original.root_path
    assert {:ok, canonical_replacement} = Store.canonical_root(replacement_root)
    canonical_displaced = Path.join(Path.dirname(canonical_root), Path.basename(displaced_root))

    CreateSegmentRootAbaFileSystem.arm(
      self(),
      canonical_root,
      canonical_replacement,
      canonical_displaced
    )

    assert {:ok, %{sequence: 2}, _store} =
             Store.enqueue(
               original,
               :telemetry,
               String.duplicate("b", 80),
               entry_id: entry_id(3)
             )

    assert_receive {:create_segment_root_aba_fired, "segment-00000000000000000002.log"}
    assert length(segment_paths(root)) == 2
    assert length(segment_paths(replacement_root)) == 1
    refute File.exists?(replacement_foreign_segment_path)

    assert {:ok, recovered_original} = open_store(root, segment_max_bytes: 260)

    assert Enum.map(Store.pending(recovered_original), & &1.payload) == [
             String.duplicate("a", 80),
             String.duplicate("b", 80)
           ]

    assert {:ok, recovered_replacement} = open_store(replacement_root, segment_max_bytes: 260)
    assert Enum.map(Store.pending(recovered_replacement), & &1.payload) == [String.duplicate("r", 80)]
  end

  test "creates a rotated segment in the bound root when the replacement has the same name", %{
    root: root
  } do
    replacement_root = root <> "_replacement_collision"
    displaced_root = root <> "_displaced_collision"
    on_exit(fn -> File.rm_rf(replacement_root) end)
    on_exit(fn -> File.rm_rf(displaced_root) end)
    on_exit(&CreateSegmentRootAbaFileSystem.disarm/0)

    assert {:ok, original} = open_store(root, segment_max_bytes: 260)
    assert {:ok, replacement} = open_store(replacement_root, segment_max_bytes: 260)

    assert {:ok, _first, original} =
             Store.enqueue(
               original,
               :telemetry,
               String.duplicate("a", 80),
               entry_id: entry_id(1)
             )

    assert original.current_segment_bytes * 2 > original.segment_max_bytes

    assert {:ok, _replacement_first, replacement} =
             Store.enqueue(
               replacement,
               :telemetry,
               String.duplicate("r", 80),
               entry_id: entry_id(2)
             )

    assert {:ok, _replacement_second, replacement} =
             Store.enqueue(
               replacement,
               :telemetry,
               String.duplicate("s", 80),
               entry_id: entry_id(3)
             )

    assert replacement.current_segment_id == 2

    assert {:ok, original} =
             open_store(root,
               segment_file_system: CreateSegmentRootAbaFileSystem,
               segment_max_bytes: 260
             )

    canonical_root = original.root_path
    assert {:ok, canonical_replacement} = Store.canonical_root(replacement_root)
    canonical_displaced = Path.join(Path.dirname(canonical_root), Path.basename(displaced_root))

    CreateSegmentRootAbaFileSystem.arm(
      self(),
      canonical_root,
      canonical_replacement,
      canonical_displaced
    )

    assert {:ok, %{sequence: 2}, _store} =
             Store.enqueue(
               original,
               :telemetry,
               String.duplicate("b", 80),
               entry_id: entry_id(4)
             )

    assert_receive {:create_segment_root_aba_fired, "segment-00000000000000000002.log"}
    assert length(segment_paths(root)) == 2
    assert length(segment_paths(replacement_root)) == 2

    assert {:ok, recovered_original} = open_store(root, segment_max_bytes: 260)

    assert Enum.map(Store.pending(recovered_original), & &1.payload) == [
             String.duplicate("a", 80),
             String.duplicate("b", 80)
           ]

    assert {:ok, recovered_replacement} = open_store(replacement_root, segment_max_bytes: 260)

    assert Enum.map(Store.pending(recovered_replacement), & &1.payload) == [
             String.duplicate("r", 80),
             String.duplicate("s", 80)
           ]
  end

  test "rejects a stale second handle before it can append a duplicate sequence", %{root: root} do
    assert {:ok, first_handle} = open_store(root)
    assert {:ok, stale_handle} = open_store(root)

    assert {:ok, _first, _first_handle} =
             Store.enqueue(first_handle, :telemetry, "first", entry_id: entry_id(1))

    assert {:error, :stale_store} =
             Store.enqueue(stale_handle, :telemetry, "duplicate-sequence", entry_id: entry_id(2))

    assert {:ok, second_handle} = open_store(root)
    assert {:ok, stale_existing_handle} = open_store(root)

    assert {:ok, _second, _second_handle} =
             Store.enqueue(second_handle, :telemetry, "second", entry_id: entry_id(2))

    assert {:error, :stale_store} =
             Store.enqueue(stale_existing_handle, :telemetry, "duplicate-second", entry_id: entry_id(3))

    assert {:ok, recovered} = open_store(root)
    assert Enum.map(Store.pending(recovered), & &1.sequence) == [1, 2]
  end

  test "rejects a stale handle before its checkpoint builder runs", %{root: root} do
    assert {:ok, first_handle} = open_store(root, streams: [:checkpoint])
    assert {:ok, stale_handle} = open_store(root, streams: [:checkpoint])

    assert {:ok, _parent, _first_handle} =
             Store.enqueue_checkpoint(
               first_handle,
               fn 1 -> checkpoint_delivery(1, <<0::256>>) end,
               entry_id: entry_id(1)
             )

    test_pid = self()

    assert {:error, :stale_store} =
             Store.enqueue_checkpoint(
               stale_handle,
               fn _sequence ->
                 send(test_pid, :stale_builder_ran)
                 checkpoint_delivery(1, <<0::256>>)
               end,
               entry_id: entry_id(2)
             )

    refute_receive :stale_builder_ran
  end

  test "rejects a handle after its root directory is replaced", %{root: root} do
    replacement_root = root <> "_replacement"
    displaced_root = root <> "_displaced"
    on_exit(fn -> File.rm_rf(replacement_root) end)
    on_exit(fn -> File.rm_rf(displaced_root) end)

    assert {:ok, original} = open_store(root)
    assert {:ok, replacement} = open_store(replacement_root)

    assert {:ok, _original_entry, original} =
             Store.enqueue(original, :telemetry, "AAAA", entry_id: entry_id(1))

    assert {:ok, _replacement_entry, _replacement} =
             Store.enqueue(replacement, :telemetry, "BBBB", entry_id: entry_id(2))

    [original_segment] = segment_paths(root)
    [replacement_segment] = segment_paths(replacement_root)
    assert File.stat!(original_segment).size == File.stat!(replacement_segment).size

    File.rename!(root, displaced_root)
    File.rename!(replacement_root, root)

    assert {:error, :stale_store} =
             Store.enqueue(original, :telemetry, "CCCC", entry_id: entry_id(3))

    assert {:ok, recovered_replacement} = open_store(root)
    assert Enum.map(Store.pending(recovered_replacement), & &1.payload) == ["BBBB"]

    assert {:ok, recovered_original} = open_store(displaced_root)
    assert Enum.map(Store.pending(recovered_original), & &1.payload) == ["AAAA"]
  end

  test "serializes root replacement against an in-flight mutation", %{root: root} do
    displaced_root = root <> "_displaced"
    on_exit(fn -> File.rm_rf(displaced_root) end)

    assert {:ok, store} = open_store(root, streams: [:checkpoint])

    assert {:ok, _seed, store} =
             Store.enqueue_checkpoint(
               store,
               fn 1 -> checkpoint_delivery(1, <<0::256>>) end,
               entry_id: entry_id(1)
             )

    owner = self()

    in_flight =
      Task.async(fn ->
        Store.enqueue_checkpoint(
          store,
          fn 2 ->
            send(owner, {:replacement_builder_waiting, self()})

            receive do
              :continue_replaced_builder -> checkpoint_delivery(2, <<0::256>>)
            end
          end,
          entry_id: entry_id(2)
        )
      end)

    assert_receive {:replacement_builder_waiting, in_flight_pid}
    File.rename!(root, displaced_root)
    File.cp_r!(displaced_root, root)

    replacement =
      Task.async(fn ->
        with {:ok, replacement_store} <- open_store(root, streams: [:checkpoint]) do
          send(owner, {:replacement_opened, self()})

          receive do
            :continue_replacement ->
              Store.enqueue_checkpoint(
                replacement_store,
                fn 2 -> checkpoint_delivery(2, <<0::256>>) end,
                entry_id: entry_id(3)
              )
          end
        end
      end)

    replacement_entered_while_locked =
      receive do
        {:replacement_opened, replacement_pid} -> replacement_pid
      after
        100 -> nil
      end

    send(in_flight_pid, :continue_replaced_builder)
    in_flight_result = Task.await(in_flight)

    replacement_pid =
      replacement_entered_while_locked ||
        receive do
          {:replacement_opened, replacement_pid} -> replacement_pid
        end

    send(replacement_pid, :continue_replacement)
    replacement_result = Task.await(replacement)

    refute replacement_entered_while_locked
    assert {:error, :stale_store} = in_flight_result
    assert {:ok, %{sequence: 2}, _store} = replacement_result

    assert {:ok, recovered_replacement} = open_store(root, streams: [:checkpoint])
    assert Enum.map(Store.pending(recovered_replacement), & &1.sequence) == [1, 2]

    assert {:ok, recovered_original} = open_store(displaced_root, streams: [:checkpoint])
    assert Enum.map(Store.pending(recovered_original), & &1.sequence) == [1]
  end

  test "revalidates root identity after append open before writing", %{root: root} do
    replacement_root = root <> "_replacement"
    displaced_root = root <> "_displaced"
    on_exit(fn -> File.rm_rf(replacement_root) end)
    on_exit(fn -> File.rm_rf(displaced_root) end)
    on_exit(&BlockingAppendOpenFileSystem.disarm/0)

    assert {:ok, original} = open_store(root)
    assert {:ok, replacement} = open_store(replacement_root)

    assert {:ok, _original_entry, _original} =
             Store.enqueue(original, :telemetry, "AAAA", entry_id: entry_id(1))

    assert {:ok, _replacement_entry, _replacement} =
             Store.enqueue(replacement, :telemetry, "BBBB", entry_id: entry_id(2))

    assert {:ok, original} = open_store(root, file_system: BlockingAppendOpenFileSystem)
    BlockingAppendOpenFileSystem.arm(self())

    stale_append =
      Task.async(fn ->
        Store.enqueue(original, :telemetry, "CCCC", entry_id: entry_id(3))
      end)

    assert_receive {:append_open_blocked, stale_append_pid}
    File.rename!(root, displaced_root)
    File.rename!(replacement_root, root)
    owner = self()

    replacement_append =
      Task.async(fn ->
        with {:ok, replacement} <- open_store(root) do
          send(owner, :post_open_replacement_opened)
          Store.enqueue(replacement, :telemetry, "DDDD", entry_id: entry_id(4))
        end
      end)

    refute_receive :post_open_replacement_opened, 100
    send(stale_append_pid, :continue_append_open)

    assert {:error, :stale_store} = Task.await(stale_append)
    assert {:ok, %{sequence: 2, payload: "DDDD"}, _store} = Task.await(replacement_append)
    assert_receive :post_open_replacement_opened

    assert {:ok, recovered_replacement} = open_store(root)
    assert Enum.map(Store.pending(recovered_replacement), & &1.payload) == ["BBBB", "DDDD"]

    assert {:ok, recovered_original} = open_store(displaced_root)
    assert Enum.map(Store.pending(recovered_original), & &1.payload) == ["AAAA"]
  end

  test "rejects an append descriptor whose file changed after the pre-open stat", %{root: root} do
    assert {:ok, store} = open_store(root)

    assert {:ok, _entry, _store} =
             Store.enqueue(store, :telemetry, "AAAA", entry_id: entry_id(1))

    assert {:ok, store} = open_store(root, file_system: MutateAfterAppendOpenFileSystem)
    segment_path = store.current_segment_path
    size_before = File.stat!(segment_path).size
    MutateAfterAppendOpenFileSystem.arm()

    assert {:error, :stale_store} =
             Store.enqueue(store, :telemetry, "BBBB", entry_id: entry_id(2))

    assert File.stat!(segment_path).size == size_before + 1
  end

  test "rejects an append descriptor redirected through a root ABA", %{root: root} do
    replacement_root = root <> "_replacement"
    displaced_root = root <> "_displaced"
    on_exit(fn -> File.rm_rf(replacement_root) end)
    on_exit(fn -> File.rm_rf(displaced_root) end)
    on_exit(&AppendDescriptorRootAbaFileSystem.disarm/0)

    assert {:ok, original} = open_store(root)
    assert {:ok, replacement} = open_store(replacement_root)

    assert {:ok, _original_entry, _original} =
             Store.enqueue(original, :telemetry, "AAAA", entry_id: entry_id(1))

    assert {:ok, _replacement_entry, _replacement} =
             Store.enqueue(replacement, :telemetry, "BBBB", entry_id: entry_id(2))

    assert {:ok, original} = open_store(root, file_system: AppendDescriptorRootAbaFileSystem)
    canonical_root = original.root_path
    assert {:ok, canonical_replacement} = Store.canonical_root(replacement_root)
    canonical_displaced = Path.join(Path.dirname(canonical_root), Path.basename(displaced_root))

    AppendDescriptorRootAbaFileSystem.arm(
      canonical_root,
      canonical_replacement,
      canonical_displaced
    )

    assert {:error, :stale_store} =
             Store.enqueue(original, :telemetry, "CCCC", entry_id: entry_id(3))

    assert {:ok, recovered_original} = open_store(root)
    assert Enum.map(Store.pending(recovered_original), & &1.payload) == ["AAAA"]

    assert {:ok, recovered_replacement} = open_store(replacement_root)
    assert Enum.map(Store.pending(recovered_replacement), & &1.payload) == ["BBBB"]
  end

  test "fails durability closed if the root changes after the durable write", %{root: root} do
    replacement_root = root <> "_replacement"
    displaced_root = root <> "_displaced"
    on_exit(fn -> File.rm_rf(replacement_root) end)
    on_exit(fn -> File.rm_rf(displaced_root) end)
    on_exit(&SwapAfterDirectoryCloseFileSystem.disarm/0)

    assert {:ok, original} = open_store(root)
    assert {:ok, replacement} = open_store(replacement_root)

    assert {:ok, _original_entry, _original} =
             Store.enqueue(original, :telemetry, "AAAA", entry_id: entry_id(1))

    assert {:ok, _replacement_entry, _replacement} =
             Store.enqueue(replacement, :telemetry, "BBBB", entry_id: entry_id(2))

    assert {:ok, original} = open_store(root, file_system: SwapAfterDirectoryCloseFileSystem)
    canonical_root = original.root_path
    assert {:ok, canonical_replacement} = Store.canonical_root(replacement_root)
    canonical_displaced = Path.join(Path.dirname(canonical_root), Path.basename(displaced_root))

    SwapAfterDirectoryCloseFileSystem.arm(
      canonical_root,
      canonical_replacement,
      canonical_displaced
    )

    assert {:error, {:durability_uncertain, :stale_store}} =
             Store.enqueue(original, :telemetry, "CCCC", entry_id: entry_id(3))

    assert {:ok, recovered_replacement} = open_store(root)
    assert Enum.map(Store.pending(recovered_replacement), & &1.payload) == ["BBBB"]

    assert {:ok, recovered_original} = open_store(displaced_root)
    assert Enum.map(Store.pending(recovered_original), & &1.payload) == ["AAAA", "CCCC"]
  end

  test "rebinds an open if the root changes after its final durable write", %{root: root} do
    replacement_root = root <> "_replacement"
    displaced_root = root <> "_displaced"
    on_exit(fn -> File.rm_rf(replacement_root) end)
    on_exit(fn -> File.rm_rf(displaced_root) end)
    on_exit(&SwapAfterDirectoryCloseFileSystem.disarm/0)

    assert {:ok, replacement} = open_store(replacement_root)

    assert {:ok, _replacement_entry, _replacement} =
             Store.enqueue(replacement, :telemetry, "replacement", entry_id: entry_id(1))

    assert {:ok, canonical_root} = Store.canonical_root(root)
    assert {:ok, canonical_replacement} = Store.canonical_root(replacement_root)
    canonical_displaced = Path.join(Path.dirname(canonical_root), Path.basename(displaced_root))

    SwapAfterDirectoryCloseFileSystem.arm(
      canonical_root,
      canonical_replacement,
      canonical_displaced
    )

    assert {:ok, opened} =
             open_store(root, file_system: SwapAfterDirectoryCloseFileSystem)

    assert Enum.map(Store.pending(opened), & &1.payload) == ["replacement"]

    assert {:ok, displaced} = open_store(displaced_root)
    assert Store.pending(displaced) == []
  end

  test "allows a callback to mutate an independent root", %{root: root} do
    independent_root = root <> "_independent"
    on_exit(fn -> File.rm_rf(independent_root) end)
    assert {:ok, store} = open_store(root, streams: [:checkpoint])
    owner = self()

    assert {:ok, %{sequence: 1} = outer_entry, _store} =
             Store.enqueue_checkpoint(
               store,
               fn 1 ->
                 result =
                   with {:ok, independent} <- open_store(independent_root),
                        {:ok, entry, _independent} <-
                          Store.enqueue(
                            independent,
                            :telemetry,
                            "independent-payload",
                            entry_id: entry_id(2)
                          ) do
                     {:ok, entry}
                   end

                 send(owner, {:independent_mutation, result})

                 case result do
                   {:ok, _entry} -> checkpoint_delivery(1, <<0::256>>)
                   {:error, reason} -> {:error, {:side_effect_failed, reason}}
                 end
               end,
               entry_id: entry_id(1)
             )

    assert {:ok, outer_submission} = Messages.decode(:checkpoint_submission, outer_entry.payload)
    assert outer_entry.payload_hash == outer_submission.checkpoint_hash
    assert_receive {:independent_mutation, {:ok, %{sequence: 1, payload: "independent-payload"}}}
    assert {:ok, recovered} = open_store(independent_root)
    assert Enum.map(Store.pending(recovered), & &1.payload) == ["independent-payload"]
  end

  test "does not deadlock opposing independent-root callback mutations", %{root: root} do
    independent_root = root <> "_independent"
    on_exit(fn -> File.rm_rf(independent_root) end)

    assert {:ok, first_store} = open_store(root, streams: [:checkpoint, :telemetry])

    assert {:ok, second_store} =
             open_store(independent_root, streams: [:checkpoint, :telemetry])

    owner = self()

    start_outer = fn label, outer_store, inner_store, outer_id, inner_id ->
      Task.async(fn ->
        Store.enqueue_checkpoint(
          outer_store,
          fn 1 ->
            send(owner, {:opposing_mutation_ready, label, self()})

            receive do
              :attempt_opposing_mutation ->
                case Store.enqueue(
                       inner_store,
                       :telemetry,
                       "nested-#{label}",
                       entry_id: entry_id(inner_id)
                     ) do
                  {:ok, _entry, _store} -> checkpoint_delivery(1, <<0::256>>)
                  {:error, reason} -> {:error, {:nested_failed, reason}}
                end
            end
          end,
          entry_id: entry_id(outer_id)
        )
      end)
    end

    first = start_outer.(:first, first_store, second_store, 1, 2)
    second = start_outer.(:second, second_store, first_store, 3, 4)

    assert_receive {:opposing_mutation_ready, :first, first_pid}
    assert_receive {:opposing_mutation_ready, :second, second_pid}
    send(first_pid, :attempt_opposing_mutation)
    send(second_pid, :attempt_opposing_mutation)

    yielded = Task.yield_many([first, second], 1_000)

    Enum.each(yielded, fn
      {task, nil} -> Task.shutdown(task, :brutal_kill)
      {_task, _result} -> :ok
    end)

    assert Enum.all?(yielded, fn {_task, result} -> result != nil end)

    results = Enum.map(yielded, fn {_task, {:ok, result}} -> result end)

    assert Enum.any?(results, fn
             {:error, {:nested_failed, {:mutation_lock, :contended}}} -> true
             _result -> false
           end)
  end

  test "a nested same-root mutation cannot release the outer checkpoint lock", %{root: root} do
    assert {:ok, outer_handle} = open_store(root, streams: [:checkpoint])
    assert {:ok, second_handle} = open_store(root, streams: [:checkpoint])
    owner = self()

    outer =
      Task.async(fn ->
        Store.enqueue_checkpoint(
          outer_handle,
          fn 1 ->
            assert {:error, :reentrant_mutation} =
                     Store.enqueue(
                       outer_handle,
                       :checkpoint,
                       "nested-rejected-mutation",
                       entry_id: entry_id(99)
                     )

            send(owner, {:outer_builder_waiting, self()})

            receive do
              :continue_outer_builder -> checkpoint_delivery(1, <<0::256>>)
            end
          end,
          entry_id: entry_id(1)
        )
      end)

    assert_receive {:outer_builder_waiting, outer_pid}

    second =
      Task.async(fn ->
        send(owner, :second_task_started)

        Store.enqueue_checkpoint(
          second_handle,
          fn 1 ->
            send(owner, :second_builder_ran)
            checkpoint_delivery(1, <<0::256>>)
          end,
          entry_id: entry_id(2)
        )
      end)

    assert_receive :second_task_started
    refute_receive :second_builder_ran, 100
    send(outer_pid, :continue_outer_builder)

    assert {:ok, %{sequence: 1}, _store} = Task.await(outer)
    assert {:error, :stale_store} = Task.await(second)
    refute_receive :second_builder_ran
  end

  test "rejects a same-root mutation reentered from an append callback", %{root: root} do
    assert {:ok, store} = open_store(root, file_system: ReentrantAppendFileSystem)

    assert {:ok, _first, store} =
             Store.enqueue(store, :telemetry, "first", entry_id: entry_id(1))

    ReentrantAppendFileSystem.arm(store, self(), entry_id(3))

    assert {:ok, outer, _store} =
             Store.enqueue(store, :telemetry, "outer-append", entry_id: entry_id(2))

    assert outer.sequence == 2
    assert_receive {:reentrant_append, {:error, :reentrant_mutation}}

    assert {:ok, recovered} = open_store(root)

    assert Enum.map(Store.pending(recovered), &{&1.sequence, &1.payload}) == [
             {1, "first"},
             {2, "outer-append"}
           ]
  end

  test "serializes simultaneous handles so only one sequence append succeeds", %{root: root} do
    assert {:ok, first_handle} = open_store(root)
    assert {:ok, second_handle} = open_store(root)
    owner = self()

    tasks =
      for {handle, id} <- [{first_handle, 1}, {second_handle, 2}] do
        Task.async(fn ->
          send(owner, {:ready, self()})

          receive do
            :go -> Store.enqueue(handle, :telemetry, "payload-#{id}", entry_id: entry_id(id))
          end
        end)
      end

    pids =
      for _task <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :go))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, _entry, _store}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_store})) == 1

    assert {:ok, recovered} = open_store(root)
    assert Enum.map(Store.pending(recovered), & &1.sequence) == [1]
    assert Store.next_sequence(recovered, :telemetry) == {:ok, 2}
  end

  test "canonicalizes symlink aliases before taking the per-root mutation lock", %{root: root} do
    assert {:ok, real_handle} = open_store(root)
    alias_root = root <> "_alias"
    File.ln_s!(root, alias_root)
    on_exit(fn -> File.rm(alias_root) end)

    assert {:ok, alias_handle} = open_store(alias_root)
    assert real_handle.root_path == alias_handle.root_path
    owner = self()

    tasks =
      for {handle, id} <- [{real_handle, 1}, {alias_handle, 2}] do
        Task.async(fn ->
          send(owner, {:alias_ready, self()})

          receive do
            :go -> Store.enqueue(handle, :telemetry, "payload-#{id}", entry_id: entry_id(id))
          end
        end)
      end

    pids =
      for _task <- tasks do
        assert_receive {:alias_ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :go))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, _entry, _store}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_store})) == 1
  end

  test "canonicalizes case aliases before taking the per-root mutation lock", %{root: root} do
    assert {:ok, real_handle} = open_store(root, streams: [:checkpoint])
    alias_root = case_variant(root)

    if same_file?(root, alias_root) do
      assert {:ok, alias_handle} = open_store(alias_root, streams: [:checkpoint])
      owner = self()

      first =
        Task.async(fn ->
          Store.enqueue_checkpoint(
            real_handle,
            fn 1 ->
              send(owner, {:case_builder_waiting, self()})

              receive do
                :continue_case_builder -> checkpoint_delivery(1, <<0::256>>)
              end
            end,
            entry_id: entry_id(1)
          )
        end)

      assert_receive {:case_builder_waiting, first_pid}

      aliased =
        Task.async(fn ->
          send(owner, :aliased_case_task_started)

          Store.enqueue_checkpoint(
            alias_handle,
            fn 1 ->
              send(owner, :aliased_case_builder_ran)
              checkpoint_delivery(1, <<0::256>>)
            end,
            entry_id: entry_id(2)
          )
        end)

      assert_receive :aliased_case_task_started
      refute_receive :aliased_case_builder_ran, 100
      send(first_pid, :continue_case_builder)

      assert {:ok, %{sequence: 1}, _store} = Task.await(first)
      assert {:error, :stale_store} = Task.await(aliased)
      refute_receive :aliased_case_builder_ran
      assert real_handle.root_path == alias_handle.root_path
    end
  end

  test "canonicalizes Unicode case aliases to one mutation-lock root", %{root: root} do
    unicode_root = root <> "_É"
    alias_root = root <> "_é"
    on_exit(fn -> File.rm_rf(unicode_root) end)

    assert {:ok, real_handle} = open_store(unicode_root)

    if same_file?(unicode_root, alias_root) do
      assert {:ok, alias_handle} = open_store(alias_root)
      assert real_handle.root_path == alias_handle.root_path
    end
  end

  test "canonicalizes full Unicode case folds to one mutation-lock root", %{root: root} do
    sigma_root = root <> "_σ"
    alias_root = root <> "_ς"
    on_exit(fn -> File.rm_rf(sigma_root) end)

    assert {:ok, real_handle} = open_store(sigma_root)

    if same_file?(sigma_root, alias_root) do
      assert {:ok, alias_handle} = open_store(alias_root)
      assert real_handle.root_path == alias_handle.root_path
    end
  end

  test "keys mutations by filesystem identity across firmlink aliases" do
    real_parent = "/private/tmp"
    alias_parent = "/System/Volumes/Data/private/tmp"

    if same_file?(real_parent, alias_parent) do
      name = "durable_outbox_firmlink_#{System.unique_integer([:positive])}"
      root = Path.join(real_parent, name)
      alias_root = Path.join(alias_parent, name)
      on_exit(fn -> File.rm_rf(root) end)

      assert {:ok, real_handle} = open_store(root, streams: [:checkpoint])

      assert {:ok, _first, real_handle} =
               Store.enqueue_checkpoint(
                 real_handle,
                 fn 1 -> checkpoint_delivery(1, <<0::256>>) end,
                 entry_id: entry_id(1)
               )

      assert {:ok, alias_handle} = open_store(alias_root, streams: [:checkpoint])
      owner = self()

      first =
        Task.async(fn ->
          Store.enqueue_checkpoint(
            real_handle,
            fn 2 ->
              send(owner, {:firmlink_builder_waiting, self()})

              receive do
                :continue_firmlink_builder -> checkpoint_delivery(2, <<0::256>>)
              end
            end,
            entry_id: entry_id(2)
          )
        end)

      assert_receive {:firmlink_builder_waiting, first_pid}

      aliased =
        Task.async(fn ->
          send(owner, :firmlink_alias_task_started)

          Store.enqueue_checkpoint(
            alias_handle,
            fn 2 ->
              send(owner, :firmlink_alias_builder_ran)
              checkpoint_delivery(2, <<0::256>>)
            end,
            entry_id: entry_id(3)
          )
        end)

      assert_receive :firmlink_alias_task_started
      refute_receive :firmlink_alias_builder_ran, 100
      send(first_pid, :continue_firmlink_builder)

      assert {:ok, %{sequence: 2}, _store} = Task.await(first)
      assert {:error, :stale_store} = Task.await(aliased)
      refute_receive :firmlink_alias_builder_ran
    end
  end

  test "binds the final namespace when opening a root with missing parent directories", %{root: root} do
    tree_root = root <> "_tree"
    nested_root = Path.join([tree_root, "missing", "parents", "outbox"])
    on_exit(fn -> File.rm_rf(tree_root) end)

    assert {:ok, store} = open_store(nested_root)

    assert {:ok, %{sequence: 1}, _store} =
             Store.enqueue(store, :telemetry, "nested-root", entry_id: entry_id(1))

    assert {:ok, recovered} = open_store(nested_root)
    assert Enum.map(Store.pending(recovered), & &1.payload) == ["nested-root"]
  end

  test "rebinds a queued open after missing parent directories are created", %{root: root} do
    tree_root = root <> "_queued_tree"
    nested_root = Path.join([tree_root, "missing", "parents", "outbox"])
    on_exit(fn -> File.rm_rf(tree_root) end)
    on_exit(&BlockingMkdirFileSystem.disarm/0)
    BlockingMkdirFileSystem.arm(self())

    first = Task.async(fn -> open_store(nested_root, file_system: BlockingMkdirFileSystem) end)
    assert_receive {:mkdir_entered, 1, first_pid}
    owner = self()

    second =
      Task.async(fn ->
        send(owner, :queued_nested_open_started)
        open_store(nested_root, file_system: BlockingMkdirFileSystem)
      end)

    assert_receive :queued_nested_open_started
    refute_receive {:mkdir_entered, 2, _pid}, 100
    send(first_pid, :continue_mkdir)

    assert {:ok, _store} = Task.await(first)
    assert {:ok, _store} = Task.await(second)
    assert_receive {:mkdir_entered, 2, _second_pid}
  end

  test "does not deadlock concurrent opens when root directories are swapped", %{root: root} do
    left_root = root <> "_left"
    right_root = root <> "_right"
    swap_root = root <> "_swap"
    on_exit(fn -> File.rm_rf(left_root) end)
    on_exit(fn -> File.rm_rf(right_root) end)
    on_exit(fn -> File.rm_rf(swap_root) end)
    on_exit(&BlockingEveryMkdirFileSystem.disarm/0)

    assert {:ok, left} = open_store(left_root)
    assert {:ok, right} = open_store(right_root)
    assert {:ok, _entry, _left} = Store.enqueue(left, :telemetry, "left", entry_id: entry_id(1))
    assert {:ok, _entry, _right} = Store.enqueue(right, :telemetry, "right", entry_id: entry_id(2))
    assert {:ok, canonical_left_root} = Store.canonical_root(left_root)
    assert {:ok, canonical_right_root} = Store.canonical_root(right_root)

    BlockingEveryMkdirFileSystem.arm(self())

    left_open =
      Task.async(fn -> open_store(left_root, file_system: BlockingEveryMkdirFileSystem) end)

    right_open =
      Task.async(fn -> open_store(right_root, file_system: BlockingEveryMkdirFileSystem) end)

    assert_receive {:every_mkdir_blocked, left_pid, ^canonical_left_root}
    assert_receive {:every_mkdir_blocked, right_pid, ^canonical_right_root}

    File.rename!(left_root, swap_root)
    File.rename!(right_root, left_root)
    File.rename!(swap_root, right_root)
    send(left_pid, :continue_every_mkdir)
    send(right_pid, :continue_every_mkdir)

    assert {:ok, opened_left} = Task.await(left_open)
    assert {:ok, opened_right} = Task.await(right_open)
    assert Enum.map(Store.pending(opened_left), & &1.payload) == ["right"]
    assert Enum.map(Store.pending(opened_right), & &1.payload) == ["left"]
  end

  test "does not deadlock when parent namespaces are swapped during open", %{root: root} do
    tree_root = root <> "_parent_swap"
    left_parent = Path.join(tree_root, "left")
    right_parent = Path.join(tree_root, "right")
    left_root = Path.join(left_parent, "outbox")
    right_root = Path.join(right_parent, "outbox")
    swap_parent = Path.join(tree_root, "swap")
    on_exit(fn -> File.rm_rf(tree_root) end)
    on_exit(&BlockingAfterMkdirFileSystem.disarm/0)

    assert {:ok, left} = open_store(left_root)
    assert {:ok, right} = open_store(right_root)
    assert {:ok, _entry, _left} = Store.enqueue(left, :telemetry, "left", entry_id: entry_id(1))
    assert {:ok, _entry, _right} = Store.enqueue(right, :telemetry, "right", entry_id: entry_id(2))
    assert {:ok, canonical_left_root} = Store.canonical_root(left_root)
    assert {:ok, canonical_right_root} = Store.canonical_root(right_root)

    BlockingAfterMkdirFileSystem.arm(self())

    left_open =
      Task.async(fn -> open_store(left_root, file_system: BlockingAfterMkdirFileSystem) end)

    right_open =
      Task.async(fn -> open_store(right_root, file_system: BlockingAfterMkdirFileSystem) end)

    assert_receive {:mkdir_completed, left_pid, ^canonical_left_root}
    assert_receive {:mkdir_completed, right_pid, ^canonical_right_root}

    File.rename!(left_parent, swap_parent)
    File.rename!(right_parent, left_parent)
    File.rename!(swap_parent, right_parent)
    send(left_pid, :continue_completed_mkdir)
    send(right_pid, :continue_completed_mkdir)

    left_result = Task.yield(left_open, 1_000)
    right_result = Task.yield(right_open, 1_000)
    if is_nil(left_result), do: Task.shutdown(left_open, :brutal_kill)
    if is_nil(right_result), do: Task.shutdown(right_open, :brutal_kill)

    assert {:ok, {:ok, opened_left}} = left_result
    assert {:ok, {:ok, opened_right}} = right_result
    assert Enum.map(Store.pending(opened_left), & &1.payload) == ["right"]
    assert Enum.map(Store.pending(opened_right), & &1.payload) == ["left"]
  end

  test "serializes missing-root creation across firmlink aliases" do
    real_parent = "/private/tmp"
    alias_parent = "/System/Volumes/Data/private/tmp"

    if same_file?(real_parent, alias_parent) do
      name = "durable_outbox_missing_firmlink_#{System.unique_integer([:positive])}"
      root = Path.join(real_parent, name)
      alias_root = Path.join(alias_parent, name)
      on_exit(fn -> File.rm_rf(root) end)
      on_exit(&BlockingMkdirFileSystem.disarm/0)
      BlockingMkdirFileSystem.arm(self())

      first =
        Task.async(fn -> open_store(root, file_system: BlockingMkdirFileSystem) end)

      assert_receive {:mkdir_entered, 1, first_pid}
      owner = self()

      aliased =
        Task.async(fn ->
          send(owner, :aliased_open_started)
          open_store(alias_root, file_system: BlockingMkdirFileSystem)
        end)

      assert_receive :aliased_open_started
      refute_receive {:mkdir_entered, 2, _pid}, 100
      send(first_pid, :continue_mkdir)

      assert {:ok, _store} = Task.await(first)
      assert {:ok, _store} = Task.await(aliased)
      assert_receive {:mkdir_entered, 2, _second_pid}
    end
  end

  test "rotates bounded segments and truncates only a torn final record", %{root: root} do
    assert {:ok, store} = open_store(root, segment_max_bytes: 260)

    assert {:ok, _first, _store} =
             Store.enqueue(store, :telemetry, String.duplicate("a", 40), entry_id: entry_id(1))

    [first_segment] = segment_paths(root)
    first_size = File.stat!(first_segment).size

    second_segment = Path.join(root, "segment-00000000000000000002.log")
    second_bytes = encoded_entry(2, entry_id(2), String.duplicate("b", 40))
    File.write!(second_segment, binary_part(second_bytes, 0, byte_size(second_bytes) - 7))

    assert [^first_segment, ^second_segment] = segment_paths(root)

    assert {:ok, recovered} = open_store(root, segment_max_bytes: 260)
    assert Enum.map(Store.pending(recovered), & &1.sequence) == [1]
    assert Store.next_sequence(recovered, :telemetry) == {:ok, 2}
    assert File.stat!(first_segment).size == first_size
    assert File.stat!(second_segment).size == 0
  end

  test "recovers a NUL-extended final segment without accepting interior NUL corruption", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, _entry, _store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))
    [segment] = segment_paths(root)
    valid_size = File.stat!(segment).size
    File.write!(segment, :binary.copy(<<0>>, 512), [:append])

    assert {:ok, recovered} = open_store(root)
    assert Enum.map(Store.pending(recovered), & &1.sequence) == [1]
    assert File.stat!(segment).size == valid_size

    interior_root = root <> "_interior_nul"
    on_exit(fn -> File.rm_rf(interior_root) end)
    File.mkdir_p!(interior_root)

    first = encoded_entry(1, entry_id(11), "first")
    second = encoded_entry(2, entry_id(12), "second")
    interior_segment = Path.join(interior_root, "segment-00000000000000000001.log")
    File.write!(interior_segment, first <> <<0, 0, 0, 0>> <> second)

    assert {:error, {:quarantined, :invalid_magic, quarantine_path}} = open_store(interior_root)
    assert File.exists?(quarantine_path)
  end

  test "recovers a zero-padded delayed-allocation torn final record", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, _entry, _store} = Store.enqueue(store, :telemetry, "first", entry_id: entry_id(1))
    [segment] = segment_paths(root)
    valid_size = File.stat!(segment).size
    second = encoded_entry(2, entry_id(2), String.duplicate("payload", 8))
    prefix_size = byte_size(second) - 32
    <<prefix::binary-size(prefix_size), _missing::binary>> = second
    File.write!(segment, prefix <> :binary.copy(<<0>>, 512), [:append])

    assert {:ok, recovered} = open_store(root)
    assert Enum.map(Store.pending(recovered), &{&1.sequence, &1.payload}) == [{1, "first"}]
    assert Store.next_sequence(recovered, :telemetry) == {:ok, 2}
    assert File.stat!(segment).size == valid_size
  end

  test "serializes destructive open recovery with mutations", %{root: root} do
    assert {:ok, store} = open_store(root, file_system: BlockingRecoveryFileSystem)

    assert {:ok, _entry, store} =
             Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))

    [segment] = segment_paths(root)
    File.write!(segment, "RO", [:append])
    BlockingRecoveryFileSystem.block_truncate(root, self())

    recovery =
      Task.async(fn -> open_store(root, file_system: BlockingRecoveryFileSystem) end)

    assert_receive {:recovery_blocked, recovery_pid}

    mutation =
      Task.async(fn ->
        Store.enqueue(store, :telemetry, "after-recovery", entry_id: entry_id(2))
      end)

    refute Task.yield(mutation, 100)
    send(recovery_pid, :continue_recovery)
    assert {:ok, _recovered} = Task.await(recovery)
    assert {:ok, _entry, _store} = Task.await(mutation)
  end

  test "rejects missing trailing segments and sequence rollback using durable high-water state", %{root: root} do
    assert {:ok, store} = open_store(root, segment_max_bytes: 260)

    assert {:ok, _first, store} =
             Store.enqueue(store, :telemetry, String.duplicate("a", 40), entry_id: entry_id(1))

    [first_segment] = segment_paths(root)
    first_size = File.stat!(first_segment).size

    assert {:ok, _second, _store} =
             Store.enqueue(store, :telemetry, String.duplicate("b", 40), entry_id: entry_id(2))

    [_first_segment, second_segment] = segment_paths(root)
    File.rm!(second_segment)

    assert {:error, {:missing_trailing_segments, 2, 1}} =
             open_store(root, segment_max_bytes: 260)

    floor_root = root <> "_sequence_floor"
    on_exit(fn -> File.rm_rf(floor_root) end)
    assert {:ok, floor_store} = open_store(floor_root)
    assert {:ok, _first, floor_store} = Store.enqueue(floor_store, :telemetry, "first", entry_id: entry_id(11))
    [floor_segment] = segment_paths(floor_root)
    floor_first_size = File.stat!(floor_segment).size
    assert {:ok, _second, _floor_store} = Store.enqueue(floor_store, :telemetry, "second", entry_id: entry_id(12))
    truncate_file!(floor_segment, floor_first_size)

    assert {:error, {:sequence_floor_violation, :telemetry, 3, 2}} = open_store(floor_root)
    assert File.stat!(first_segment).size == first_size
  end

  test "a durable marker rejects missing run state before a final segment can roll back", %{root: root} do
    assert {:ok, store} = open_store(root, segment_max_bytes: 260)
    assert File.exists?(Path.join(root, "run-state.required"))

    assert {:ok, _first, store} =
             Store.enqueue(store, :telemetry, String.duplicate("a", 40), entry_id: entry_id(1))

    assert {:ok, _second, _store} =
             Store.enqueue(store, :telemetry, String.duplicate("b", 40), entry_id: entry_id(2))

    [first_segment, final_segment] = segment_paths(root)
    File.rm!(Path.join(root, "run-state.bin"))
    File.rm!(final_segment)

    assert {:error, :run_state_missing} = open_store(root, segment_max_bytes: 260)
    assert File.exists?(first_segment)
    refute File.exists?(Path.join(root, "quarantine"))
  end

  test "byte floors protect committed acknowledgements in every active segment", %{root: root} do
    assert {:ok, store} =
             open_store(root, file_system: TracingFileSystem, segment_max_bytes: 500, max_disk_bytes: 10_000)

    assert {:ok, first, store} =
             Store.enqueue(store, :telemetry, String.duplicate("a", 40), entry_id: entry_id(1))

    [first_segment] = segment_paths(root)
    before_ack = File.stat!(first_segment).size
    TracingFileSystem.fail_snapshot_rename()

    assert {:error, {:durability_uncertain, {:snapshot_rename, :simulated_rename_failure}}} =
             Store.acknowledge(store, receipt_for(first))

    assert File.stat!(first_segment).size > before_ack
    assert {:ok, recovered} = open_store(root, segment_max_bytes: 500, max_disk_bytes: 10_000)
    assert Store.pending(recovered) == []

    assert {:ok, _second, _store} =
             Store.enqueue(
               recovered,
               :telemetry,
               String.duplicate("b", 200),
               entry_id: entry_id(2)
             )

    assert [^first_segment, _second_segment] = segment_paths(root)
    truncate_file!(first_segment, before_ack)

    assert {:error, {:segment_byte_floor_violation, 1, committed_bytes, ^before_ack}} =
             open_store(root, segment_max_bytes: 500, max_disk_bytes: 10_000)

    assert committed_bytes > before_ack
  end

  test "checkpoint acknowledgement replay uses the v2 physical entry hash", %{root: root} do
    assert {:ok, store} =
             open_store(root,
               streams: [:checkpoint],
               file_system: TracingFileSystem
             )

    assert {:ok, entry, store} =
             Store.enqueue_checkpoint(
               store,
               fn 1 -> checkpoint_delivery(1, <<0::256>>) end,
               entry_id: entry_id(1)
             )

    assert entry.payload_hash != entry.payload_checksum
    TracingFileSystem.fail_snapshot_rename()

    assert {:error, {:durability_uncertain, {:snapshot_rename, :simulated_rename_failure}}} =
             Store.acknowledge(store, receipt_for(entry))

    [segment] = segment_paths(root)
    segment_bytes = File.read!(segment)

    assert {:ok, %{kind: :entry} = entry_record, remainder, _encoded_size} =
             Record.decode_next(segment_bytes)

    assert {:ok, %{kind: :acknowledgement} = acknowledgement, <<>>, _encoded_size} =
             Record.decode_next(remainder)

    assert entry_record.payload_hash == entry.payload_checksum
    assert acknowledgement.payload_hash == entry_record.payload_hash

    assert {:ok, recovered} =
             open_store(root,
               streams: [:checkpoint],
               file_system: TracingFileSystem
             )

    assert Store.pending(recovered) == []
  end

  test "semantic checkpoint resolution records from the split-identity transition still replay", %{root: root} do
    assert {:ok, store} = open_store(root, streams: [:checkpoint])

    assert {:ok, entry, _store} =
             Store.enqueue_checkpoint(
               store,
               fn 1 -> checkpoint_delivery(1, <<0::256>>) end,
               entry_id: entry_id(1)
             )

    assert entry.payload_hash != entry.payload_checksum
    [segment] = segment_paths(root)

    assert {:ok, acknowledgement} =
             Record.encode(%{
               kind: :acknowledgement,
               stream: "checkpoint",
               device_id: entry.device_id,
               credential_epoch: entry.credential_epoch,
               storage_epoch: entry.storage_epoch,
               sequence: entry.sequence,
               payload_hash: entry.payload_hash,
               cumulative_sequence: 0
             })

    File.write!(segment, acknowledgement, [:append])

    assert {:ok, recovered} = open_store(root, streams: [:checkpoint])
    assert Store.pending(recovered) == []
    assert Store.resolved_receipt?(recovered, receipt_for(entry))
  end

  test "semantic checkpoint loss records from the split-identity transition still replay", %{root: root} do
    assert {:ok, store} = open_store(root, streams: [:checkpoint])

    assert {:ok, entry, _store} =
             Store.enqueue_checkpoint(
               store,
               fn 1 -> checkpoint_delivery(1, <<0::256>>) end,
               entry_id: entry_id(1)
             )

    assert entry.payload_hash != entry.payload_checksum
    [segment] = segment_paths(root)

    assert {:ok, authorization} =
             Record.encode(%{
               kind: :loss_authorization,
               stream: "checkpoint",
               device_id: entry.device_id,
               credential_epoch: entry.credential_epoch,
               storage_epoch: entry.storage_epoch,
               sequence: entry.sequence,
               entry_id: entry.entry_id,
               payload_hash: entry.payload_hash,
               reason: "operator ticket"
             })

    File.write!(segment, authorization, [:append])

    assert {:ok, recovered} = open_store(root, streams: [:checkpoint])
    assert Store.pending(recovered) == []

    assert [loss] = Store.loss_authorizations(recovered)
    assert loss.payload_hash == entry.payload_hash
  end

  test "checkpoint cumulative acknowledgement retries retain the v2 physical anchor hash", %{root: root} do
    assert {:ok, store} =
             open_store(root,
               streams: [:checkpoint],
               file_system: TracingFileSystem
             )

    assert {:ok, first, store} =
             Store.enqueue_checkpoint(
               store,
               fn 1 -> checkpoint_delivery(1, <<0::256>>) end,
               entry_id: entry_id(1)
             )

    assert {:ok, second, store} =
             Store.enqueue_checkpoint(
               store,
               fn 2 -> checkpoint_delivery(2, first.payload_hash) end,
               entry_id: entry_id(2)
             )

    assert {:ok, [^second], store} = Store.acknowledge(store, receipt_for(second))
    TracingFileSystem.fail_snapshot_rename()

    assert {:error, {:durability_uncertain, {:snapshot_rename, :simulated_rename_failure}}} =
             Store.acknowledge(
               store,
               %{receipt_for(second) | cumulative_sequence: second.sequence}
             )

    [segment] = segment_paths(root)

    assert {:ok, %{kind: :acknowledgement} = acknowledgement, <<>>, _encoded_size} =
             segment
             |> File.read!()
             |> Record.decode_next()

    assert acknowledgement.payload_hash == second.payload_checksum

    assert {:ok, recovered} =
             open_store(root,
               streams: [:checkpoint],
               file_system: TracingFileSystem
             )

    assert Store.pending(recovered) == []
  end

  test "checkpoint loss replay uses the v2 physical entry hash", %{root: root} do
    assert {:ok, store} =
             open_store(root,
               streams: [:checkpoint],
               file_system: TracingFileSystem
             )

    assert {:ok, entry, store} =
             Store.enqueue_checkpoint(
               store,
               fn 1 -> checkpoint_delivery(1, <<0::256>>) end,
               entry_id: entry_id(1)
             )

    assert entry.payload_hash != entry.payload_checksum
    TracingFileSystem.fail_snapshot_rename()

    assert {:error, {:durability_uncertain, {:snapshot_rename, :simulated_rename_failure}}} =
             Store.authorize_loss(store, receipt_for(entry), "operator ticket")

    [segment] = segment_paths(root)
    segment_bytes = File.read!(segment)

    assert {:ok, %{kind: :entry} = entry_record, remainder, _encoded_size} =
             Record.decode_next(segment_bytes)

    assert {:ok, %{kind: :loss_authorization} = authorization, <<>>, _encoded_size} =
             Record.decode_next(remainder)

    assert entry_record.payload_hash == entry.payload_checksum
    assert authorization.payload_hash == entry_record.payload_hash

    assert {:ok, recovered} =
             open_store(root,
               streams: [:checkpoint],
               file_system: TracingFileSystem
             )

    assert Store.pending(recovered) == []
  end

  test "run state requires committed byte floors for every active segment", %{root: root} do
    assert {:ok, store} =
             open_store(root, file_system: TracingFileSystem)

    assert {:ok, entry, store} =
             Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))

    [segment] = segment_paths(root)
    before_ack = File.stat!(segment).size
    TracingFileSystem.fail_snapshot_rename()

    assert {:error, {:durability_uncertain, {:snapshot_rename, :simulated_rename_failure}}} =
             Store.acknowledge(store, receipt_for(entry))

    run_state_path = Path.join(root, "run-state.bin")
    assert {:ok, run_state} = run_state_path |> File.read!() |> RunState.decode()
    assert [{1, committed_size}] = Map.fetch!(run_state, "committed_segment_sizes")
    assert committed_size > before_ack

    assert {:ok, bytes} =
             run_state
             |> Map.put("committed_segment_sizes", [])
             |> RunState.encode()

    File.write!(run_state_path, bytes)
    truncate_file!(segment, before_ack)

    assert {:error, :invalid_run_state} =
             open_store(root, file_system: TracingFileSystem)
  end

  test "legacy run state requires an explicit byte floor for exactly one active segment", %{root: root} do
    assert {:ok, store} = open_store(root)

    assert {:ok, _entry, _store} =
             Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))

    run_state_path = Path.join(root, "run-state.bin")
    assert {:ok, run_state} = run_state_path |> File.read!() |> RunState.decode()

    assert {:ok, missing_floor_bytes} =
             run_state
             |> Map.delete("committed_segment_sizes")
             |> Map.delete("committed_segment_bytes")
             |> RunState.encode()

    File.write!(run_state_path, missing_floor_bytes)
    assert {:error, :invalid_run_state} = open_store(root)

    single_root = root <> "_single_legacy_floor"
    on_exit(fn -> File.rm_rf(single_root) end)
    assert {:ok, single_store} = open_store(single_root)

    assert {:ok, _entry, _single_store} =
             Store.enqueue(single_store, :telemetry, "payload", entry_id: entry_id(2))

    [single_segment] = segment_paths(single_root)
    single_run_state_path = Path.join(single_root, "run-state.bin")
    assert {:ok, single_run_state} = single_run_state_path |> File.read!() |> RunState.decode()

    assert {:ok, single_legacy_bytes} =
             single_run_state
             |> Map.delete("committed_segment_sizes")
             |> Map.put("committed_segment_bytes", File.stat!(single_segment).size)
             |> RunState.encode()

    File.write!(single_run_state_path, single_legacy_bytes)
    assert {:ok, _recovered} = open_store(single_root)

    multiple_root = root <> "_multiple_legacy_floors"
    on_exit(fn -> File.rm_rf(multiple_root) end)
    assert {:ok, multiple_store} = open_store(multiple_root, segment_max_bytes: 260)

    assert {:ok, _first, multiple_store} =
             Store.enqueue(
               multiple_store,
               :telemetry,
               String.duplicate("a", 40),
               entry_id: entry_id(3)
             )

    assert {:ok, _second, _multiple_store} =
             Store.enqueue(
               multiple_store,
               :telemetry,
               String.duplicate("b", 40),
               entry_id: entry_id(4)
             )

    [_first_segment, final_segment] = segment_paths(multiple_root)
    multiple_run_state_path = Path.join(multiple_root, "run-state.bin")
    assert {:ok, multiple_run_state} = multiple_run_state_path |> File.read!() |> RunState.decode()

    assert {:ok, multiple_legacy_bytes} =
             multiple_run_state
             |> Map.delete("committed_segment_sizes")
             |> Map.put("committed_segment_bytes", File.stat!(final_segment).size)
             |> RunState.encode()

    File.write!(multiple_run_state_path, multiple_legacy_bytes)
    assert {:error, :invalid_run_state} = open_store(multiple_root, segment_max_bytes: 260)
  end

  test "legacy byte floors covered by the active snapshot are safely superseded", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, entry, store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))
    assert {:ok, [^entry], _store} = Store.acknowledge(store, receipt_for(entry))
    assert segment_paths(root) == []

    snapshot_path = Path.join(root, "snapshot.bin")
    assert {:ok, snapshot} = snapshot_path |> File.read!() |> Snapshot.decode()
    assert snapshot["covered_segment_id"] > 0

    run_state_path = Path.join(root, "run-state.bin")
    assert {:ok, run_state} = run_state_path |> File.read!() |> RunState.decode()
    assert run_state["segment_high_water"] == snapshot["covered_segment_id"]

    assert {:ok, legacy_bytes} =
             run_state
             |> Map.delete("committed_segment_sizes")
             |> Map.put("committed_segment_bytes", 1)
             |> RunState.encode()

    File.write!(run_state_path, legacy_bytes)

    assert {:ok, recovered} = open_store(root)
    assert Store.pending(recovered) == []
  end

  test "run state requires positive historical exact-history limits", %{root: root} do
    assert {:ok, _store} = open_store(root)
    run_state_path = Path.join(root, "run-state.bin")
    assert {:ok, run_state} = run_state_path |> File.read!() |> RunState.decode()

    for {field, invalid_limit, index} <-
          Enum.with_index(
            for field <- ["entry_id_tombstone_limit", "resolved_receipt_limit"],
                invalid_limit <- [0, -1, "1", nil],
                do: {field, invalid_limit}
          )
          |> Enum.map(fn {{field, invalid_limit}, index} -> {field, invalid_limit, index} end) do
      case_root = root <> "_invalid_history_limit_#{index}"
      on_exit(fn -> File.rm_rf(case_root) end)
      File.mkdir_p!(case_root)

      assert {:ok, bytes} =
               run_state
               |> Map.put(field, invalid_limit)
               |> RunState.encode()

      File.write!(Path.join(case_root, "run-state.bin"), bytes)
      File.write!(Path.join(case_root, "run-state.required"), "RODM\x01")

      assert {:error, :invalid_run_state} = open_store(case_root)
    end

    for {missing_field, index} <-
          Enum.with_index(["entry_id_tombstone_limit", "resolved_receipt_limit"]) do
      case_root = root <> "_missing_history_limit_#{index}"
      on_exit(fn -> File.rm_rf(case_root) end)
      File.mkdir_p!(case_root)

      assert {:ok, bytes} = run_state |> Map.delete(missing_field) |> RunState.encode()
      File.write!(Path.join(case_root, "run-state.bin"), bytes)
      File.write!(Path.join(case_root, "run-state.required"), "RODM\x01")

      assert {:error, :invalid_run_state} = open_store(case_root)
    end
  end

  test "a legacy segment without run state cannot borrow the current receipt limit", %{root: root} do
    File.mkdir_p!(root)
    payload = "legacy"
    entry_bytes = encoded_entry(1, entry_id(1), payload)

    assert {:ok, acknowledgement_bytes} =
             Record.encode(%{
               kind: :acknowledgement,
               stream: "telemetry",
               device_id: @device_id,
               credential_epoch: @credential_epoch,
               storage_epoch: @storage_epoch,
               sequence: 1,
               payload_hash: :crypto.hash(:sha256, payload),
               cumulative_sequence: 0
             })

    segment = Path.join(root, "segment-00000000000000000001.log")
    File.write!(segment, entry_bytes <> acknowledgement_bytes)

    assert {:error, :legacy_resolved_receipt_limit_unknown} =
             open_store(root, max_resolved_receipts: 3)

    assert File.exists?(segment)
    refute File.exists?(Path.join(root, "quarantine"))
    refute File.exists?(Path.join(root, "run-state.bin"))
  end

  test "a legacy loss record without run state cannot borrow the current tombstone limit", %{
    root: root
  } do
    File.mkdir_p!(root)
    payload = "legacy"
    entry_bytes = encoded_entry(1, entry_id(1), payload)

    assert {:ok, loss_bytes} =
             Record.encode(%{
               kind: :loss_authorization,
               stream: "telemetry",
               device_id: @device_id,
               credential_epoch: @credential_epoch,
               storage_epoch: @storage_epoch,
               sequence: 1,
               entry_id: entry_id(1),
               payload_hash: :crypto.hash(:sha256, payload),
               reason: "operator ticket"
             })

    segment = Path.join(root, "segment-00000000000000000001.log")
    File.write!(segment, entry_bytes <> loss_bytes)

    assert {:error, :legacy_entry_id_tombstone_limit_unknown} =
             open_store(root, max_entry_id_tombstones: 3)

    assert File.exists?(segment)
    refute File.exists?(Path.join(root, "quarantine"))
    refute File.exists?(Path.join(root, "run-state.bin"))
  end

  test "legacy run state fails closed when an active acknowledgement needs an unknown limit", %{
    root: root
  } do
    assert {:ok, store} = open_store(root, file_system: TracingFileSystem)

    assert {:ok, entry, store} =
             Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))

    TracingFileSystem.fail_snapshot_rename()

    assert {:error, {:durability_uncertain, {:snapshot_rename, :simulated_rename_failure}}} =
             Store.acknowledge(store, receipt_for(entry))

    run_state_path = Path.join(root, "run-state.bin")
    assert {:ok, run_state} = run_state_path |> File.read!() |> RunState.decode()

    assert {:ok, legacy_bytes} =
             run_state
             |> Map.delete("entry_id_tombstone_limit")
             |> Map.delete("resolved_receipt_limit")
             |> RunState.encode()

    File.write!(run_state_path, legacy_bytes)

    [segment] = segment_paths(root)

    assert {:error, :legacy_resolved_receipt_limit_unknown} =
             open_store(root, file_system: TracingFileSystem)

    assert File.exists?(segment)
    refute File.exists?(Path.join(root, "quarantine"))
  end

  test "requires durable run state once a schema-v2 snapshot marks the root", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, entry, store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))
    assert {:ok, [^entry], _store} = Store.acknowledge(store, receipt_for(entry))

    run_state = Path.join(root, "run-state.bin")
    File.rm!(run_state)

    assert {:error, :run_state_missing} = open_store(root)
    assert File.exists?(Path.join(root, "snapshot.bin"))
    refute File.exists?(Path.join(root, "quarantine"))
    refute File.exists?(run_state)
  end

  test "replays stronger cumulative retries after the exact-history bound shrinks", %{root: root} do
    assert {:ok, store} =
             open_store(
               root,
               file_system: TracingFileSystem,
               max_resolved_receipts: 3
             )

    assert {:ok, telemetry_first, store} =
             Store.enqueue(store, :telemetry, "telemetry-1", entry_id: entry_id(1))

    assert {:ok, telemetry_second, store} =
             Store.enqueue(store, :telemetry, "telemetry-2", entry_id: entry_id(2))

    assert {:ok, telemetry_third, store} =
             Store.enqueue(store, :telemetry, "telemetry-3", entry_id: entry_id(3))

    assert {:ok, health_first, store} =
             Store.enqueue(store, :health, "health-1", entry_id: entry_id(4))

    assert {:ok, [^telemetry_first], store} =
             Store.acknowledge(store, receipt_for(telemetry_first))

    assert {:ok, [^telemetry_third], store} =
             Store.acknowledge(store, receipt_for(telemetry_third))

    assert {:ok, [^health_first], store} =
             Store.acknowledge(store, receipt_for(health_first))

    TracingFileSystem.fail_snapshot_rename()

    assert {:error, {:durability_uncertain, {:snapshot_rename, :simulated_rename_failure}}} =
             Store.acknowledge(
               store,
               %{receipt_for(telemetry_third) | cumulative_sequence: 3}
             )

    assert {:ok, recovered} =
             open_store(
               root,
               file_system: TracingFileSystem,
               max_resolved_receipts: 1
             )

    assert Store.pending(recovered) == []
    assert Store.next_sequence(recovered, :telemetry) == {:ok, telemetry_second.sequence + 2}
    assert segment_paths(root) == []

    assert {:ok, transitioned_run_state} =
             root
             |> Path.join("run-state.bin")
             |> File.read!()
             |> RunState.decode()

    assert transitioned_run_state["resolved_receipt_limit"] == 1
    assert transitioned_run_state["committed_segment_sizes"] == []

    assert {:ok, recovered} =
             open_store(
               root,
               file_system: TracingFileSystem,
               max_resolved_receipts: 1
             )

    assert Store.pending(recovered) == []
    assert recovered.acknowledged_floors.telemetry == 3

    assert {:ok, telemetry_fourth, recovered} =
             Store.enqueue(recovered, :telemetry, "telemetry-4", entry_id: entry_id(5))

    assert {:ok, [^telemetry_fourth], empty} =
             Store.acknowledge(
               recovered,
               %{receipt_for(telemetry_fourth) | cumulative_sequence: 4}
             )

    assert Store.pending(empty) == []
  end

  test "replay rejects a cumulative record without exact allocated receipt proof", %{root: root} do
    assert {:ok, store} = open_store(root)

    assert {:ok, _first, store} =
             Store.enqueue(store, :telemetry, "first", entry_id: entry_id(1))

    assert {:ok, _second, _store} =
             Store.enqueue(store, :telemetry, "second", entry_id: entry_id(2))

    assert {:ok, encoded} =
             Record.encode(%{
               kind: :acknowledgement,
               stream: "telemetry",
               device_id: @device_id,
               credential_epoch: @credential_epoch,
               storage_epoch: @storage_epoch,
               sequence: 99,
               payload_hash: <<7::256>>,
               cumulative_sequence: 2
             })

    [segment] = segment_paths(root)
    File.write!(segment, encoded, [:append])

    assert {:error, {:quarantined, :receipt_entry_not_found, quarantine_path}} =
             open_store(root)

    assert File.exists?(quarantine_path)
  end

  test "replay rejects a cumulative record anchored by explicit loss", %{root: root} do
    assert {:ok, store} = open_store(root)

    assert {:ok, lost, store} =
             Store.enqueue(store, :telemetry, "lost", entry_id: entry_id(1))

    loss_identity =
      Map.take(lost, [
        :stream,
        :device_id,
        :credential_epoch,
        :storage_epoch,
        :sequence,
        :payload_hash
      ])

    assert {:ok, ^lost, store} =
             Store.authorize_loss(store, loss_identity, "operator ticket")

    assert {:ok, _pending, _store} =
             Store.enqueue(store, :telemetry, "pending", entry_id: entry_id(2))

    assert {:ok, encoded} =
             Record.encode(%{
               kind: :acknowledgement,
               stream: "telemetry",
               device_id: lost.device_id,
               credential_epoch: lost.credential_epoch,
               storage_epoch: lost.storage_epoch,
               sequence: lost.sequence,
               payload_hash: lost.payload_hash,
               cumulative_sequence: 2
             })

    [segment] = segment_paths(root)
    File.write!(segment, encoded, [:append])

    assert {:error, {:quarantined, :receipt_entry_not_found, quarantine_path}} =
             open_store(root)

    assert File.exists?(quarantine_path)
  end

  test "replay preserves fail-closed receipt eviction semantics", %{root: root} do
    assert {:ok, store} = open_store(root, max_resolved_receipts: 1)

    {[first, second, third, fourth], _store} =
      Enum.map_reduce(1..4, store, fn n, acc ->
        {:ok, entry, acc} =
          Store.enqueue(acc, :telemetry, "payload-#{n}", entry_id: entry_id(n))

        {entry, acc}
      end)

    append_acknowledgement_record!(root, receipt_for(second))
    append_acknowledgement_record!(root, receipt_for(third))

    append_acknowledgement_record!(
      root,
      %{receipt_for(fourth) | cumulative_sequence: 3}
    )

    assert {:error, {:quarantined, :non_contiguous_cumulative_prefix, quarantine_path}} =
             open_store(root, max_resolved_receipts: 1)

    assert File.exists?(quarantine_path)
    assert first.sequence == 1
  end

  test "no-segment limit transitions durably canonicalize exact histories", %{root: root} do
    assert {:ok, store} =
             open_store(root,
               max_entry_id_tombstones: 3,
               max_resolved_receipts: 3
             )

    {[first, second, third], store} =
      Enum.map_reduce(1..3, store, fn n, acc ->
        {:ok, entry, acc} =
          Store.enqueue(acc, :telemetry, "payload-#{n}", entry_id: entry_id(n))

        {entry, acc}
      end)

    assert {:ok, [^first], store} = Store.acknowledge(store, receipt_for(first))
    assert {:ok, [^second], store} = Store.acknowledge(store, receipt_for(second))
    assert {:ok, [^third], _store} = Store.acknowledge(store, receipt_for(third))
    assert segment_paths(root) == []

    assert {:ok, shrunk} =
             open_store(root,
               max_entry_id_tombstones: 1,
               max_resolved_receipts: 1
             )

    assert length(shrunk.entry_id_tombstones) == 1
    refute Store.resolved_receipt?(shrunk, receipt_for(first))
    assert Store.resolved_receipt?(shrunk, receipt_for(third))

    assert {:ok, reused_first, _shrunk} =
             Store.enqueue(shrunk, :telemetry, "reused-first", entry_id: first.entry_id)

    assert reused_first.sequence == 4

    assert {:ok, expanded} =
             open_store(root,
               max_entry_id_tombstones: 3,
               max_resolved_receipts: 3
             )

    assert length(expanded.entry_id_tombstones) == 1
    refute Store.resolved_receipt?(expanded, receipt_for(first))

    assert {:ok, reopened} =
             open_store(root,
               max_entry_id_tombstones: 3,
               max_resolved_receipts: 3
             )

    assert length(reopened.entry_id_tombstones) == 1
    refute Store.resolved_receipt?(reopened, receipt_for(first))
    refute Store.resolved_receipt?(reopened, receipt_for(second))
    assert Store.resolved_receipt?(reopened, receipt_for(third))

    assert {:ok, _reused, _store} =
             Store.enqueue(reopened, :telemetry, "reused", entry_id: second.entry_id)
  end

  test "snapshot-only legacy migration persists run state before activating the current schema", %{
    root: root
  } do
    File.mkdir_p!(root)
    File.write!(Path.join(root, "snapshot.bin"), legacy_snapshot_v1())
    TracingFileSystem.fail_run_state_rename()

    assert {:error, {:run_state_rename, :simulated_rename_failure}} =
             open_store(root, file_system: TracingFileSystem)

    assert {:ok, legacy_snapshot} =
             root
             |> Path.join("snapshot.bin")
             |> File.read!()
             |> Snapshot.decode()

    assert Map.get(legacy_snapshot, "schema_version", 1) == 1
    refute File.exists?(Path.join(root, "run-state.bin"))

    assert {:ok, recovered} = open_store(root, file_system: TracingFileSystem)
    assert Store.pending(recovered) == []
  end

  test "receipt-limit transition crash points preserve one replay regime", %{root: root} do
    cases = [
      {:snapshot_rename, &TracingFileSystem.fail_snapshot_rename/0, true},
      {:run_state_rename, fn -> TracingFileSystem.fail_run_state_rename_after(1) end, false}
    ]

    for {operation, fail_next, segment_survives?} <- cases do
      case_root = root <> "_limit_transition_#{operation}"
      on_exit(fn -> File.rm_rf(case_root) end)
      {first, _second, _third} = prepare_active_limit_three_retry!(case_root)
      fail_next.()

      expected_error =
        case operation do
          :snapshot_rename ->
            {:error, {:durability_uncertain, {:snapshot_rename, :simulated_rename_failure}}}

          :run_state_rename ->
            {:error, {:run_state_rename, :simulated_rename_failure}}
        end

      assert ^expected_error =
               open_store(
                 case_root,
                 file_system: TracingFileSystem,
                 max_entry_id_tombstones: 1,
                 max_resolved_receipts: 1
               )

      assert segment_paths(case_root) != [] == segment_survives?

      assert {:ok, old_run_state} =
               case_root
               |> Path.join("run-state.bin")
               |> File.read!()
               |> RunState.decode()

      assert old_run_state["entry_id_tombstone_limit"] == 3
      assert old_run_state["resolved_receipt_limit"] == 3

      assert {:ok, old_regime} =
               open_store(
                 case_root,
                 file_system: TracingFileSystem,
                 max_entry_id_tombstones: 3,
                 max_resolved_receipts: 3
               )

      assert Store.resolved_receipt?(old_regime, receipt_for(first))

      assert {:error, :duplicate_entry_id} =
               Store.enqueue(old_regime, :telemetry, "duplicate", entry_id: first.entry_id)

      assert {:ok, recovered} =
               open_store(
                 case_root,
                 file_system: TracingFileSystem,
                 max_entry_id_tombstones: 1,
                 max_resolved_receipts: 1
               )

      assert Store.pending(recovered) == []
      assert segment_paths(case_root) == []

      assert {:ok, transitioned_run_state} =
               case_root
               |> Path.join("run-state.bin")
               |> File.read!()
               |> RunState.decode()

      assert transitioned_run_state["entry_id_tombstone_limit"] == 1
      assert transitioned_run_state["resolved_receipt_limit"] == 1
      refute Store.resolved_receipt?(recovered, receipt_for(first))

      assert {:ok, _reused, _store} =
               Store.enqueue(recovered, :telemetry, "reused", entry_id: first.entry_id)
    end
  end

  test "transition recovery publishes a rotated high-water before snapshot activation", %{root: root} do
    opts = [
      file_system: TracingFileSystem,
      max_resolved_receipts: 3,
      segment_max_bytes: 260,
      max_disk_bytes: 10_000
    ]

    assert {:ok, store} = open_store(root, opts)

    assert {:ok, entry, store} =
             Store.enqueue(
               store,
               :telemetry,
               String.duplicate("payload", 6),
               entry_id: entry_id(1)
             )

    assert length(segment_paths(root)) == 1
    TracingFileSystem.fail_run_state_rename()

    assert {:error, {:durability_uncertain, {:run_state_rename, :simulated_rename_failure}}} =
             Store.acknowledge(store, receipt_for(entry))

    assert length(segment_paths(root)) == 2

    run_state_path = Path.join(root, "run-state.bin")
    assert {:ok, stale_run_state} = run_state_path |> File.read!() |> RunState.decode()
    assert stale_run_state["segment_high_water"] == 1

    TracingFileSystem.fail_run_state_rename_after(1)

    assert {:error, {:run_state_rename, :simulated_rename_failure}} =
             open_store(
               root,
               Keyword.put(opts, :max_resolved_receipts, 1)
             )

    assert segment_paths(root) == []
    assert {:ok, recovered_run_state} = run_state_path |> File.read!() |> RunState.decode()
    assert recovered_run_state["segment_high_water"] == 2
    assert recovered_run_state["resolved_receipt_limit"] == 3

    assert {:ok, recovered} =
             open_store(
               root,
               Keyword.put(opts, :max_resolved_receipts, 1)
             )

    assert Store.pending(recovered) == []
    assert recovered.acknowledged_floors.telemetry == 1
  end

  test "a receipt-limit transition governs every future active acknowledgement", %{root: root} do
    assert {:ok, store} =
             open_store(
               root,
               file_system: TracingFileSystem,
               max_resolved_receipts: 3
             )

    {[first, second, third], store} =
      Enum.map_reduce(1..3, store, fn n, acc ->
        {:ok, entry, acc} =
          Store.enqueue(acc, :telemetry, "old-#{n}", entry_id: entry_id(n))

        {entry, acc}
      end)

    assert {:ok, [^third], store} = Store.acknowledge(store, receipt_for(third))
    TracingFileSystem.fail_snapshot_rename()

    assert {:error, {:durability_uncertain, {:snapshot_rename, :simulated_rename_failure}}} =
             Store.acknowledge(
               store,
               %{receipt_for(third) | cumulative_sequence: 3}
             )

    assert first.sequence == 1
    assert second.sequence == 2

    assert {:ok, transitioned} =
             open_store(
               root,
               file_system: TracingFileSystem,
               max_resolved_receipts: 1
             )

    assert Store.pending(transitioned) == []
    assert segment_paths(root) == []

    {[fourth, fifth, sixth, seventh], _store} =
      Enum.map_reduce(4..7, transitioned, fn n, acc ->
        {:ok, entry, acc} =
          Store.enqueue(acc, :telemetry, "new-#{n}", entry_id: entry_id(n))

        {entry, acc}
      end)

    append_acknowledgement_record!(root, receipt_for(fifth))
    append_acknowledgement_record!(root, receipt_for(sixth))

    append_acknowledgement_record!(
      root,
      %{receipt_for(seventh) | cumulative_sequence: 6}
    )

    assert {:error, {:quarantined, :non_contiguous_cumulative_prefix, quarantine_path}} =
             open_store(
               root,
               file_system: TracingFileSystem,
               max_resolved_receipts: 1
             )

    assert File.exists?(quarantine_path)
    assert fourth.sequence == 4
  end

  test "migrates schema-v2 contiguous proof before applying a smaller history bound", %{root: root} do
    assert {:ok, store} = open_store(root, max_resolved_receipts: 2)

    {[first, second, third], store} =
      Enum.map_reduce(1..3, store, fn n, acc ->
        {:ok, entry, acc} =
          Store.enqueue(acc, :telemetry, "payload-#{n}", entry_id: entry_id(n))

        {entry, acc}
      end)

    assert {:ok, [^first], store} = Store.acknowledge(store, receipt_for(first))
    assert {:ok, [^second], _store} = Store.acknowledge(store, receipt_for(second))

    downgrade_snapshot_to_v2!(root)

    assert {:ok, recovered} = open_store(root, max_resolved_receipts: 1)
    assert recovered.run_state_required
    assert recovered.acknowledged_floors == %{health: 0, telemetry: 2}
    assert Enum.map(recovered.resolved_receipts, & &1.sequence) == [2]

    assert {:ok, [removed_third], empty} =
             Store.acknowledge(
               recovered,
               %{receipt_for(third) | cumulative_sequence: 3}
             )

    assert receipt_for(removed_third) == receipt_for(third)
    assert Store.pending(empty) == []
  end

  test "schema-v2 migration does not invent evicted contiguous proof", %{root: root} do
    opts = [max_resolved_receipts: 1]
    assert {:ok, store} = open_store(root, opts)

    {[first, second, third], store} =
      Enum.map_reduce(1..3, store, fn n, acc ->
        {:ok, entry, acc} =
          Store.enqueue(acc, :telemetry, "payload-#{n}", entry_id: entry_id(n))

        {entry, acc}
      end)

    assert {:ok, [^first], store} = Store.acknowledge(store, receipt_for(first))
    assert {:ok, [^second], _store} = Store.acknowledge(store, receipt_for(second))

    downgrade_snapshot_to_v2!(root)

    assert {:ok, recovered} = open_store(root, opts)
    assert recovered.acknowledged_floors == %{health: 0, telemetry: 0}

    assert {:error, :non_contiguous_cumulative_prefix} =
             Store.acknowledge(
               recovered,
               %{receipt_for(third) | cumulative_sequence: 3}
             )

    assert Enum.map(Store.pending(recovered), & &1.sequence) == [3]
  end

  test "quarantines a replayed entry at the terminal next-sequence sentinel", %{root: root} do
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "snapshot.bin"),
      legacy_snapshot_v1(%{
        "next_sequences" => [{"health", 1}, {"telemetry", @next_sequence_max}]
      })
    )

    File.write!(
      Path.join(root, "segment-00000000000000000001.log"),
      encoded_entry(@next_sequence_max, entry_id(1), "cannot-transmit")
    )

    assert {:error, {:quarantined, :sequence_out_of_range, quarantine_path}} = open_store(root)
    assert File.exists?(quarantine_path)
  end

  test "rejects hydrated sequence counters beyond the terminal wire-safe sentinel", %{root: root} do
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "snapshot.bin"),
      legacy_snapshot_v1(%{
        "next_sequences" => [{"health", 1}, {"telemetry", @next_sequence_max + 1}]
      })
    )

    assert {:error, {:quarantined, :invalid_snapshot, quarantine_path}} = open_store(root)
    assert File.exists?(quarantine_path)

    run_state_root = root <> "_run_state_sequence_bound"
    on_exit(fn -> File.rm_rf(run_state_root) end)
    assert {:ok, _store} = open_store(run_state_root)

    run_state_path = Path.join(run_state_root, "run-state.bin")
    assert {:ok, run_state} = run_state_path |> File.read!() |> RunState.decode()

    assert {:ok, bytes} =
             run_state
             |> Map.put("sequence_floors", [
               {"health", 1},
               {"telemetry", @next_sequence_max + 1}
             ])
             |> RunState.encode()

    File.write!(run_state_path, bytes)
    assert {:error, :invalid_run_state} = open_store(run_state_root)
    assert File.exists?(run_state_path)
    refute File.exists?(Path.join(run_state_root, "quarantine"))
  end

  test "schema-v4 snapshots require explicit entry-id history metadata", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, entry, store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))
    assert {:ok, [^entry], _store} = Store.acknowledge(store, receipt_for(entry))

    assert {:ok, valid_snapshot} =
             root
             |> Path.join("snapshot.bin")
             |> File.read!()
             |> Snapshot.decode()

    for {field, index} <-
          Enum.with_index([
            "entry_id_history_complete",
            "entry_id_tombstones",
            "resolved_receipts"
          ]) do
      case_root = root <> "_entry_id_metadata_#{index}"
      on_exit(fn -> File.rm_rf(case_root) end)
      File.mkdir_p!(case_root)

      assert {:ok, bytes} =
               valid_snapshot
               |> Map.delete(field)
               |> Snapshot.encode()

      File.write!(Path.join(case_root, "snapshot.bin"), bytes)

      assert {:error, {:quarantined, :invalid_snapshot, quarantine_path}} =
               open_store(case_root)

      assert File.exists?(quarantine_path)
    end
  end

  test "schema-v2 snapshots require explicit bounded-history metadata", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, entry, store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))
    assert {:ok, [^entry], _store} = Store.acknowledge(store, receipt_for(entry))

    assert {:ok, valid_snapshot} =
             root
             |> Path.join("snapshot.bin")
             |> File.read!()
             |> Snapshot.decode()

    valid_snapshot =
      valid_snapshot
      |> Map.put("schema_version", 2)
      |> Map.delete("acknowledged_floors")

    for {field, index} <-
          Enum.with_index([
            "entry_id_history_complete",
            "entry_id_tombstones",
            "resolved_receipts"
          ]) do
      case_root = root <> "_v2_history_metadata_#{index}"
      on_exit(fn -> File.rm_rf(case_root) end)
      File.mkdir_p!(case_root)

      assert {:ok, bytes} =
               valid_snapshot
               |> Map.delete(field)
               |> Snapshot.encode()

      File.write!(Path.join(case_root, "snapshot.bin"), bytes)

      assert {:error, {:quarantined, :invalid_snapshot, quarantine_path}} =
               open_store(case_root)

      assert File.exists?(quarantine_path)
    end
  end

  test "schema-v4 snapshots require a complete valid acknowledged frontier", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, entry, store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))
    assert {:ok, [^entry], _store} = Store.acknowledge(store, receipt_for(entry))

    assert {:ok, valid_snapshot} =
             root
             |> Path.join("snapshot.bin")
             |> File.read!()
             |> Snapshot.decode()

    invalid_frontiers = [
      :missing,
      [{"health", 0}, {"telemetry", -1}],
      [{"health", 0}, {"health", 0}, {"telemetry", 1}],
      [{"telemetry", 1}],
      [{"health", 0}, {"other", 0}],
      [{"health", 0}, {"telemetry", 0}]
    ]

    Enum.with_index(invalid_frontiers, fn frontier, index ->
      case_root = root <> "_frontier_#{index}"
      on_exit(fn -> File.rm_rf(case_root) end)
      File.mkdir_p!(case_root)

      snapshot =
        if frontier == :missing,
          do: Map.delete(valid_snapshot, "acknowledged_floors"),
          else: Map.put(valid_snapshot, "acknowledged_floors", frontier)

      assert {:ok, bytes} = Snapshot.encode(snapshot)
      File.write!(Path.join(case_root, "snapshot.bin"), bytes)

      assert {:error, {:quarantined, :invalid_snapshot, quarantine_path}} =
               open_store(case_root)

      assert File.exists?(quarantine_path)
    end)
  end

  test "schema-v4 snapshots reject contradictory resolved receipt proof", %{root: root} do
    assert {:ok, store} = open_store(root)

    assert {:ok, live, store} =
             Store.enqueue(store, :telemetry, "live", entry_id: entry_id(1))

    assert {:ok, resolved, store} =
             Store.enqueue(store, :health, "resolved", entry_id: entry_id(2))

    assert {:ok, [^resolved], store} = Store.acknowledge(store, receipt_for(resolved))

    assert {:ok, lost, store} =
             Store.enqueue(store, :health, "lost", entry_id: entry_id(3))

    loss_identity =
      Map.take(lost, [
        :stream,
        :device_id,
        :credential_epoch,
        :storage_epoch,
        :sequence,
        :payload_hash
      ])

    assert {:ok, ^lost, _store} =
             Store.authorize_loss(store, loss_identity, "operator ticket")

    assert {:ok, valid_snapshot} =
             root
             |> Path.join("snapshot.bin")
             |> File.read!()
             |> Snapshot.decode()

    valid_receipts = Map.fetch!(valid_snapshot, "resolved_receipts")

    contradictions = [
      [snapshot_resolved_receipt(live)],
      [snapshot_resolved_receipt(lost)],
      [snapshot_resolved_receipt(%{live | sequence: 2})],
      valid_receipts ++
        [snapshot_resolved_receipt(%{resolved | payload_hash: <<7::256>>})]
    ]

    Enum.with_index(contradictions, fn receipts, index ->
      case_root = root <> "_receipt_#{index}"
      on_exit(fn -> File.rm_rf(case_root) end)
      File.mkdir_p!(case_root)

      assert {:ok, bytes} =
               valid_snapshot
               |> Map.put("resolved_receipts", receipts)
               |> Snapshot.encode()

      File.write!(Path.join(case_root, "snapshot.bin"), bytes)

      assert {:error, {:quarantined, :invalid_snapshot, quarantine_path}} =
               open_store(case_root)

      assert File.exists?(quarantine_path)
    end)
  end

  test "schema-v4 snapshots reject contradictory loss authorization proof", %{root: root} do
    assert {:ok, store} = open_store(root)

    assert {:ok, live, store} =
             Store.enqueue(store, :telemetry, "live", entry_id: entry_id(1))

    assert {:ok, resolved, store} =
             Store.enqueue(store, :health, "resolved", entry_id: entry_id(2))

    assert {:ok, [^resolved], store} = Store.acknowledge(store, receipt_for(resolved))

    assert {:ok, lost, store} =
             Store.enqueue(store, :health, "lost", entry_id: entry_id(3))

    loss_identity =
      Map.take(lost, [
        :stream,
        :device_id,
        :credential_epoch,
        :storage_epoch,
        :sequence,
        :payload_hash
      ])

    assert {:ok, ^lost, _store} =
             Store.authorize_loss(store, loss_identity, "operator ticket")

    assert {:ok, valid_snapshot} =
             root
             |> Path.join("snapshot.bin")
             |> File.read!()
             |> Snapshot.decode()

    valid_losses = Map.fetch!(valid_snapshot, "loss_authorizations")

    contradictions = [
      [snapshot_loss_authorization(live)],
      [snapshot_loss_authorization(%{live | sequence: 2})],
      valid_losses ++ [snapshot_loss_authorization(lost)]
    ]

    Enum.with_index(contradictions, fn losses, index ->
      case_root = root <> "_loss_#{index}"
      on_exit(fn -> File.rm_rf(case_root) end)
      File.mkdir_p!(case_root)

      assert {:ok, bytes} =
               valid_snapshot
               |> Map.put("loss_authorizations", losses)
               |> Snapshot.encode()

      File.write!(Path.join(case_root, "snapshot.bin"), bytes)

      assert {:error, {:quarantined, :invalid_snapshot, quarantine_path}} =
               open_store(case_root)

      assert File.exists?(quarantine_path)
    end)
  end

  test "schema-v4 acknowledged floors cannot cross an explicitly lost sequence", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, entry, store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))

    identity =
      Map.take(entry, [
        :stream,
        :device_id,
        :credential_epoch,
        :storage_epoch,
        :sequence,
        :payload_hash
      ])

    assert {:ok, ^entry, _store} = Store.authorize_loss(store, identity, "operator ticket")

    snapshot_path = Path.join(root, "snapshot.bin")
    assert {:ok, snapshot} = snapshot_path |> File.read!() |> Snapshot.decode()

    assert {:ok, bytes} =
             snapshot
             |> Map.put("acknowledged_floors", [{"health", 0}, {"telemetry", 1}])
             |> Snapshot.encode()

    File.write!(snapshot_path, bytes)

    assert {:error, {:quarantined, :invalid_snapshot, quarantine_path}} = open_store(root)
    assert File.exists?(quarantine_path)
  end

  test "snapshot decoding rejects compressed external terms before inflation without quarantine", %{root: root} do
    expanded = %{"entries" => List.duplicate(String.duplicate("x", 1_024), 1_024)}
    payload = :erlang.term_to_binary(expanded, compressed: 9)
    assert <<131, 80, _rest::binary>> = payload
    framed = snapshot_frame(1, payload)
    assert {:error, :compressed_snapshot} = Snapshot.decode(framed)

    File.mkdir_p!(root)
    snapshot = Path.join(root, "snapshot.bin")
    File.write!(snapshot, framed)
    assert {:error, :compressed_snapshot} = open_store(root)
    assert File.exists?(snapshot)
    refute File.exists?(Path.join(root, "quarantine"))

    assert {:ok, encoded} = Snapshot.encode(%{"entries" => []})
    <<"RODS", 1, _payload_size::64, _checksum::binary-size(32), term::binary>> = encoded
    refute match?(<<131, 80, _rest::binary>>, term)
  end

  test "current snapshots require exact payload checksums", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, _first, store} = Store.enqueue(store, :telemetry, "first", entry_id: entry_id(1))
    assert {:ok, second, store} = Store.enqueue(store, :telemetry, "second", entry_id: entry_id(2))
    assert {:ok, [^second], _store} = Store.acknowledge(store, receipt_for(second))

    snapshot_path = Path.join(root, "snapshot.bin")
    assert {:ok, snapshot} = snapshot_path |> File.read!() |> Snapshot.decode()
    assert snapshot["schema_version"] == 4

    [entry] = snapshot["entries"]
    assert {:ok, bytes} = Snapshot.encode(%{snapshot | "entries" => [Map.delete(entry, "payload_checksum")]})
    File.write!(snapshot_path, bytes)

    assert {:error, {:quarantined, :invalid_snapshot, quarantine_path}} = open_store(root)
    assert File.exists?(quarantine_path)
  end

  test "current snapshots require checkpoint resolved receipt checksums", %{root: root} do
    assert {:ok, store} = open_store(root, streams: [:checkpoint])

    assert {:ok, entry, store} =
             Store.enqueue_checkpoint(
               store,
               fn 1 -> checkpoint_delivery(1, <<0::256>>) end,
               entry_id: entry_id(1)
             )

    assert {:ok, [^entry], _store} = Store.acknowledge(store, receipt_for(entry))

    snapshot_path = Path.join(root, "snapshot.bin")
    assert {:ok, snapshot} = snapshot_path |> File.read!() |> Snapshot.decode()
    assert [receipt] = snapshot["resolved_receipts"]
    assert receipt["payload_checksum"] == entry.payload_checksum

    assert {:ok, bytes} =
             snapshot
             |> Map.put("resolved_receipts", [Map.delete(receipt, "payload_checksum")])
             |> Snapshot.encode()

    File.write!(snapshot_path, bytes)

    assert {:error, {:quarantined, :invalid_snapshot, quarantine_path}} =
             open_store(root, streams: [:checkpoint])

    assert File.exists?(quarantine_path)
  end

  test "legacy snapshots cannot authorize split checkpoint identity", %{root: root} do
    assert {:ok, store} = open_store(root, streams: [:checkpoint])

    assert {:ok, entry, store} =
             Store.enqueue_checkpoint(
               store,
               fn 1 -> checkpoint_delivery(1, <<0::256>>) end,
               entry_id: entry_id(1)
             )

    assert {:ok, _resolved, _store} = Store.authorize_loss(store, receipt_for(entry), "force snapshot")

    snapshot_path = Path.join(root, "snapshot.bin")
    assert {:ok, snapshot} = snapshot_path |> File.read!() |> Snapshot.decode()

    legacy_entry =
      entry
      |> then(fn pending ->
        %{
          "stream" => "checkpoint",
          "device_id" => pending.device_id,
          "credential_epoch" => pending.credential_epoch,
          "storage_epoch" => pending.storage_epoch,
          "sequence" => pending.sequence,
          "entry_id" => pending.entry_id,
          "payload_hash" => pending.payload_hash,
          "payload_checksum" => pending.payload_checksum,
          "payload" => pending.payload,
          "priority" => pending.priority
        }
      end)

    legacy =
      snapshot
      |> Map.put("schema_version", 3)
      |> Map.put("next_sequences", [{"checkpoint", 2}])
      |> Map.put("entries", [legacy_entry])
      |> Map.put("loss_authorizations", [])
      |> Map.put("entry_id_tombstones", [])
      |> Map.put("resolved_receipts", [])
      |> Map.put("acknowledged_floors", [{"checkpoint", 0}])

    assert {:ok, bytes} = Snapshot.encode(legacy)
    File.write!(snapshot_path, bytes)

    assert {:error, {:quarantined, :invalid_snapshot, quarantine_path}} =
             open_store(root, streams: [:checkpoint])

    assert File.exists?(quarantine_path)
  end

  test "malformed snapshot payloads quarantine instead of crashing hydration", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, _first, store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))
    assert {:ok, second, store} = Store.enqueue(store, :telemetry, "resolved", entry_id: entry_id(2))
    assert {:ok, [^second], _store} = Store.acknowledge(store, receipt_for(second))

    snapshot_path = Path.join(root, "snapshot.bin")
    assert {:ok, snapshot} = snapshot_path |> File.read!() |> Snapshot.decode()
    [entry] = Map.fetch!(snapshot, "entries")

    assert {:ok, bytes} =
             snapshot
             |> Map.put("entries", [%{entry | "payload" => %{not: "binary"}}])
             |> Snapshot.encode()

    File.write!(snapshot_path, bytes)

    assert {:error, {:quarantined, :invalid_snapshot, quarantine_path}} = open_store(root)
    assert File.exists?(quarantine_path)
  end

  test "hostile sequence-list shapes fail closed instead of crashing hydration", %{root: root} do
    File.mkdir_p!(root)
    File.write!(Path.join(root, "snapshot.bin"), legacy_snapshot_v1(%{"next_sequences" => [123]}))

    assert {:error, {:quarantined, :invalid_snapshot, quarantine_path}} = open_store(root)
    assert File.exists?(quarantine_path)

    run_state_root = root <> "_malformed_run_state"
    on_exit(fn -> File.rm_rf(run_state_root) end)
    File.mkdir_p!(run_state_root)

    assert {:ok, bytes} =
             RunState.encode(%{
               "device_id" => @device_id,
               "credential_epoch" => @credential_epoch,
               "storage_epoch" => @storage_epoch,
               "streams" => ["health", "telemetry"],
               "segment_high_water" => 0,
               "committed_segment_bytes" => 0,
               "committed_segment_sizes" => [],
               "sequence_floors" => [123]
             })

    run_state = Path.join(run_state_root, "run-state.bin")
    File.write!(run_state, bytes)
    assert {:error, :invalid_run_state} = open_store(run_state_root)
    assert File.exists?(run_state)
    refute File.exists?(Path.join(run_state_root, "quarantine"))
  end

  test "does not quarantine transient snapshot I/O, version, or stream-set mismatches", %{root: root} do
    assert {:ok, store} = open_store(root, file_system: TracingFileSystem)
    assert {:ok, entry, store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))
    assert {:ok, [^entry], _store} = Store.acknowledge(store, receipt_for(entry))
    snapshot = Path.join(root, "snapshot.bin")

    TracingFileSystem.fail_snapshot_read()

    assert {:error, {:read_snapshot, :simulated_read_failure}} =
             open_store(root, file_system: TracingFileSystem)

    assert File.exists?(snapshot)
    refute File.exists?(Path.join(root, "quarantine"))

    legacy_root = root <> "_legacy_snapshot"
    on_exit(fn -> File.rm_rf(legacy_root) end)
    File.mkdir_p!(legacy_root)
    File.write!(Path.join(legacy_root, "snapshot.bin"), legacy_snapshot_v1())
    assert {:ok, legacy_store} = open_store(legacy_root)
    assert Store.pending(legacy_store) == []
    assert File.exists?(Path.join(legacy_root, "snapshot.bin"))
    refute File.exists?(Path.join(legacy_root, "quarantine"))

    version_root = root <> "_unsupported_version"
    on_exit(fn -> File.rm_rf(version_root) end)
    File.mkdir_p!(version_root)
    File.write!(Path.join(version_root, "snapshot.bin"), snapshot_frame(2, :erlang.term_to_binary(%{})))
    assert {:error, :unsupported_snapshot_version} = open_store(version_root)
    assert File.exists?(Path.join(version_root, "snapshot.bin"))
    refute File.exists?(Path.join(version_root, "quarantine"))

    stream_root = root <> "_stream_set"
    on_exit(fn -> File.rm_rf(stream_root) end)
    assert {:ok, stream_store} = open_store(stream_root)

    assert {:ok, stream_entry, stream_store} =
             Store.enqueue(stream_store, :health, "health", entry_id: entry_id(2))

    assert {:ok, [^stream_entry], _stream_store} =
             Store.acknowledge(stream_store, receipt_for(stream_entry))

    assert {:error, :stream_set_mismatch} = open_store(stream_root, streams: [:telemetry])
    assert File.exists?(Path.join(stream_root, "snapshot.bin"))
    refute File.exists?(Path.join(stream_root, "quarantine"))
  end

  test "quarantines checksum-corrupt snapshots but never overwrites forensic copies", %{root: root} do
    :persistent_term.put({CollisionFileSystem, :inject_collision}, true)
    on_exit(fn -> :persistent_term.erase({CollisionFileSystem, :inject_collision}) end)

    assert {:ok, store} = open_store(root, file_system: CollisionFileSystem)
    assert {:ok, entry, store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))
    assert {:ok, [^entry], _store} = Store.acknowledge(store, receipt_for(entry))
    snapshot = Path.join(root, "snapshot.bin")
    bytes = File.read!(snapshot)
    <<prefix::binary-size(byte_size(bytes) - 1), byte>> = bytes
    File.write!(snapshot, prefix <> <<Bitwise.bxor(byte, 1)>>)

    assert {:error, {:quarantined, :snapshot_checksum_mismatch, quarantine_path}} =
             open_store(root, file_system: CollisionFileSystem)

    quarantine_files = Path.join(root, "quarantine") |> File.ls!() |> Enum.sort()
    assert length(quarantine_files) == 2

    assert Enum.any?(quarantine_files, fn filename ->
             File.read!(Path.join(root, "quarantine/#{filename}")) == "prior-forensic-copy"
           end)

    assert File.exists?(quarantine_path)
  end

  test "reclaims orphan snapshot temps and fails closed when reclamation cannot complete", %{root: root} do
    File.mkdir_p!(root)
    orphan = Path.join(root, "snapshot.bin.tmp.1")
    File.write!(orphan, :binary.copy(<<0>>, 2_048))

    assert {:ok, store} = open_store(root, max_disk_bytes: 1_024)
    refute File.exists?(orphan)
    assert Store.usage(store).disk_bytes == disk_bytes_on_disk(root)

    failed_root = root <> "_failed_temp_cleanup"
    on_exit(fn -> File.rm_rf(failed_root) end)
    File.mkdir_p!(failed_root)
    failed_orphan = Path.join(failed_root, "snapshot.bin.tmp.1")
    File.write!(failed_orphan, :binary.copy(<<0>>, 2_048))
    TracingFileSystem.fail_snapshot_temp_remove()

    assert {:error, {:orphan_temp_cleanup, {:remove_snapshot_temp, :simulated_remove_failure}}} =
             open_store(failed_root,
               file_system: TracingFileSystem,
               max_disk_bytes: 1_024
             )

    assert File.exists?(failed_orphan)
  end

  test "validates snapshot and run-state identity before reclaiming orphan temps", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, entry, store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))
    assert {:ok, [^entry], _store} = Store.acknowledge(store, receipt_for(entry))

    snapshot_temp = Path.join(root, "snapshot.bin.tmp.deadbeef")
    run_state_temp = Path.join(root, "run-state.bin.tmp.deadbeef")
    File.write!(snapshot_temp, "snapshot evidence")
    File.write!(run_state_temp, "run-state evidence")

    assert {:error, :device_id_mismatch} = open_store(root, device_id: @other_device_id)
    assert File.read!(snapshot_temp) == "snapshot evidence"
    assert File.read!(run_state_temp) == "run-state evidence"

    assert {:ok, _recovered} = open_store(root)
    refute File.exists?(snapshot_temp)
    refute File.exists?(run_state_temp)

    sidecar_root = root <> "_sidecar_authority"
    on_exit(fn -> File.rm_rf(sidecar_root) end)
    assert {:ok, sidecar_store} = open_store(sidecar_root)

    assert {:ok, _entry, _sidecar_store} =
             Store.enqueue(sidecar_store, :telemetry, "payload", entry_id: entry_id(2))

    sidecar_temp = Path.join(sidecar_root, "run-state.bin.tmp.cafebabe")
    File.write!(sidecar_temp, "sidecar evidence")
    assert {:error, :device_id_mismatch} = open_store(sidecar_root, device_id: @other_device_id)
    assert File.read!(sidecar_temp) == "sidecar evidence"
  end

  test "rejects entry id reuse across restart and bounds durable loss audit history", %{root: root} do
    assert {:ok, store} = open_store(root, max_entries: 100, max_disk_bytes: 100_000)
    assert {:ok, entry, store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))
    assert {:ok, [^entry], _store} = Store.acknowledge(store, receipt_for(entry))
    assert {:ok, recovered} = open_store(root, max_entries: 100, max_disk_bytes: 100_000)

    assert {:error, :duplicate_entry_id} =
             Store.enqueue(recovered, :telemetry, "replacement", entry_id: entry_id(1))

    audit_root = root <> "_bounded_audit"
    on_exit(fn -> File.rm_rf(audit_root) end)

    assert {:ok, audit_store} =
             open_store(audit_root,
               max_entries: 100,
               max_disk_bytes: 100_000,
               max_loss_authorizations: 32
             )

    audit_store =
      Enum.reduce(1..40, audit_store, fn n, acc ->
        assert {:ok, audit_entry, acc} =
                 Store.enqueue(acc, :health, "health-#{n}", entry_id: entry_id(n + 100))

        identity =
          Map.take(audit_entry, [
            :stream,
            :device_id,
            :credential_epoch,
            :storage_epoch,
            :sequence,
            :payload_hash
          ])

        assert {:ok, ^audit_entry, acc} = Store.authorize_loss(acc, identity, "operator ticket #{n}")
        acc
      end)

    assert length(Store.loss_authorizations(audit_store)) == 32
    assert Enum.map(Store.loss_authorizations(audit_store), & &1.sequence) == Enum.to_list(9..40)

    assert {:ok, recovered_audit} =
             open_store(audit_root,
               max_entries: 100,
               max_disk_bytes: 100_000,
               max_loss_authorizations: 32
             )

    assert Store.loss_authorizations(recovered_audit) == Store.loss_authorizations(audit_store)
  end

  test "entry id tombstones enforce a documented bounded reuse window across restart", %{root: root} do
    opts = [max_disk_bytes: 100_000, max_entry_id_tombstones: 2, max_resolved_receipts: 2]
    assert {:ok, store} = open_store(root, opts)

    store =
      Enum.reduce(1..3, store, fn n, acc ->
        assert {:ok, entry, acc} = Store.enqueue(acc, :telemetry, "payload-#{n}", entry_id: entry_id(n))
        assert {:ok, [^entry], acc} = Store.acknowledge(acc, receipt_for(entry))
        acc
      end)

    assert length(store.entry_id_tombstones) == 2
    assert {:error, :duplicate_entry_id} = Store.enqueue(store, :telemetry, "duplicate", entry_id: entry_id(3))

    assert {:ok, recovered} = open_store(root, opts)
    assert {:ok, reused, _store} = Store.enqueue(recovered, :telemetry, "reused", entry_id: entry_id(1))
    assert reused.sequence == 4
  end

  test "entry-id tombstone transitions replay under the historical bound", %{root: root} do
    opts = [max_disk_bytes: 100_000, max_entry_id_tombstones: 3, max_resolved_receipts: 3]
    assert {:ok, store} = open_store(root, opts)

    store =
      Enum.reduce(1..3, store, fn n, acc ->
        assert {:ok, entry, acc} =
                 Store.enqueue(acc, :telemetry, "payload-#{n}", entry_id: entry_id(n))

        assert {:ok, [^entry], acc} = Store.acknowledge(acc, receipt_for(entry))
        acc
      end)

    assert length(store.entry_id_tombstones) == 3
    assert segment_paths(root) == []

    assert {:ok, snapshot} =
             root
             |> Path.join("snapshot.bin")
             |> File.read!()
             |> Snapshot.decode()

    segment_id = Map.fetch!(snapshot, "covered_segment_id") + 1

    segment =
      Path.join(
        root,
        "segment-" <> String.pad_leading(Integer.to_string(segment_id), 20, "0") <> ".log"
      )

    File.write!(segment, encoded_entry(4, entry_id(1), "reused"))

    assert {:error, {:quarantined, :duplicate_entry_id, quarantine_path}} =
             open_store(
               root,
               Keyword.merge(opts,
                 max_entry_id_tombstones: 2,
                 max_resolved_receipts: 2
               )
             )

    assert File.exists?(quarantine_path)
  end

  test "legacy entry-id reuse with an unknown historical limit fails closed without quarantine", %{
    root: root
  } do
    opts = [max_disk_bytes: 100_000, max_entry_id_tombstones: 3, max_resolved_receipts: 3]
    assert {:ok, store} = open_store(root, opts)

    store =
      Enum.reduce(1..3, store, fn n, acc ->
        assert {:ok, entry, acc} =
                 Store.enqueue(acc, :telemetry, "payload-#{n}", entry_id: entry_id(n))

        assert {:ok, [^entry], acc} = Store.acknowledge(acc, receipt_for(entry))
        acc
      end)

    assert length(store.entry_id_tombstones) == 3
    assert segment_paths(root) == []

    assert {:ok, snapshot} =
             root
             |> Path.join("snapshot.bin")
             |> File.read!()
             |> Snapshot.decode()

    segment_id = Map.fetch!(snapshot, "covered_segment_id") + 1
    encoded = encoded_entry(4, entry_id(1), "valid-under-the-legacy-limit")

    segment =
      Path.join(
        root,
        "segment-" <> String.pad_leading(Integer.to_string(segment_id), 20, "0") <> ".log"
      )

    File.write!(segment, encoded)

    run_state_path = Path.join(root, "run-state.bin")
    assert {:ok, run_state} = run_state_path |> File.read!() |> RunState.decode()

    assert {:ok, legacy_run_state} =
             run_state
             |> Map.delete("entry_id_tombstone_limit")
             |> Map.delete("resolved_receipt_limit")
             |> Map.put("segment_high_water", segment_id)
             |> Map.put("committed_segment_sizes", [{segment_id, byte_size(encoded)}])
             |> Map.put("sequence_floors", [{"health", 1}, {"telemetry", 5}])
             |> RunState.encode()

    File.write!(run_state_path, legacy_run_state)

    assert {:error, :legacy_entry_id_tombstone_limit_unknown} =
             open_store(root,
               max_disk_bytes: 100_000,
               max_entry_id_tombstones: 2,
               max_resolved_receipts: 2
             )

    assert File.exists?(segment)
    refute File.exists?(Path.join(root, "quarantine"))
  end

  test "legacy migration checks huge allocated spans without expanding every sequence", %{root: root} do
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "snapshot.bin"),
      legacy_snapshot_v1(%{"next_sequences" => [{"health", 1}, {"telemetry", 1_000_001}]})
    )

    owner = self()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(owner, {:large_history_result, open_store(root)}) end,
        [:monitor, {:max_heap_size, %{size: 100_000, kill: true, error_logger: false}}]
      )

    assert_receive {:large_history_result, {:ok, migrated}}, 5_000
    assert migrated.entry_id_history_complete == false
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "legacy snapshots with unknown acknowledged IDs migrate fail closed", %{root: root} do
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "snapshot.bin"),
      legacy_snapshot_v1(%{"next_sequences" => [{"health", 1}, {"telemetry", 2}]})
    )

    assert {:ok, migrated} = open_store(root)
    assert Store.next_sequence(migrated, :telemetry) == {:ok, 2}

    assert {:error, :entry_id_history_incomplete} =
             Store.enqueue(migrated, :telemetry, "cannot-prove-novel", entry_id: entry_id(1))

    assert {:ok, reopened} = open_store(root)

    assert {:error, :entry_id_history_incomplete} =
             Store.enqueue(reopened, :telemetry, "still-fenced", entry_id: entry_id(2))
  end

  test "legacy migration deduplicates repeated loss IDs without losing the reuse fence", %{root: root} do
    loss = %{
      "stream" => "telemetry",
      "device_id" => @device_id,
      "credential_epoch" => @credential_epoch,
      "storage_epoch" => @storage_epoch,
      "sequence" => 1,
      "entry_id" => entry_id(9),
      "payload_hash" => :crypto.hash(:sha256, "lost"),
      "reason" => "legacy retry"
    }

    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "snapshot.bin"),
      legacy_snapshot_v1(%{
        "next_sequences" => [{"health", 1}, {"telemetry", 2}],
        "loss_authorizations" => [loss, loss]
      })
    )

    assert {:ok, migrated} = open_store(root)
    assert length(Store.loss_authorizations(migrated)) == 1
    assert {:error, :duplicate_entry_id} = Store.enqueue(migrated, :telemetry, "duplicate", entry_id: entry_id(9))
    assert {:ok, entry, migrated} = Store.enqueue(migrated, :telemetry, "novel", entry_id: entry_id(10))
    assert entry.sequence == 2
    assert {:ok, [^entry], _store} = Store.acknowledge(migrated, receipt_for(entry))

    assert {:ok, recovered} = open_store(root)
    assert length(Store.loss_authorizations(recovered)) == 1
  end

  test "legacy migration rejects conflicting loss claims for one durable sequence", %{root: root} do
    loss = %{
      "stream" => "telemetry",
      "device_id" => @device_id,
      "credential_epoch" => @credential_epoch,
      "storage_epoch" => @storage_epoch,
      "sequence" => 1,
      "entry_id" => entry_id(9),
      "payload_hash" => :crypto.hash(:sha256, "lost"),
      "reason" => "legacy retry"
    }

    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "snapshot.bin"),
      legacy_snapshot_v1(%{
        "next_sequences" => [{"health", 1}, {"telemetry", 2}],
        "loss_authorizations" => [loss, %{loss | "entry_id" => entry_id(10)}]
      })
    )

    assert {:error, {:quarantined, :invalid_snapshot, quarantine_path}} = open_store(root)
    assert File.exists?(quarantine_path)
  end

  test "legacy migration tolerates a historical loss ID that is currently live again", %{root: root} do
    reused_id = entry_id(9)
    payload = "reused before migration"

    loss = %{
      "stream" => "telemetry",
      "device_id" => @device_id,
      "credential_epoch" => @credential_epoch,
      "storage_epoch" => @storage_epoch,
      "sequence" => 1,
      "entry_id" => reused_id,
      "payload_hash" => :crypto.hash(:sha256, "old lost payload"),
      "reason" => "legacy loss"
    }

    live = %{
      "stream" => "telemetry",
      "device_id" => @device_id,
      "credential_epoch" => @credential_epoch,
      "storage_epoch" => @storage_epoch,
      "sequence" => 2,
      "entry_id" => reused_id,
      "payload_hash" => :crypto.hash(:sha256, payload),
      "payload" => payload,
      "priority" => 0
    }

    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "snapshot.bin"),
      legacy_snapshot_v1(%{
        "next_sequences" => [{"health", 1}, {"telemetry", 3}],
        "entries" => [live],
        "loss_authorizations" => [loss]
      })
    )

    assert {:ok, migrated} = open_store(root)
    assert [entry] = Store.pending(migrated)
    assert entry.sequence == 2
    assert entry.entry_id == reused_id
    assert {:error, :duplicate_entry_id} = Store.enqueue(migrated, :telemetry, "duplicate", entry_id: reused_id)

    assert {:ok, [^entry], _store} = Store.acknowledge(migrated, receipt_for(entry))
    assert {:ok, recovered} = open_store(root)
    assert {:error, :duplicate_entry_id} = Store.enqueue(recovered, :telemetry, "duplicate", entry_id: reused_id)
  end

  test "rejects an oversized segment before reading it into memory", %{root: root} do
    File.mkdir_p!(root)
    segment = Path.join(root, "segment-00000000000000000001.log")
    File.write!(segment, :binary.copy(<<0>>, 301))
    TracingFileSystem.attach(self())

    assert {:error, {:quarantined, :segment_too_large, quarantine_path}} =
             open_store(root,
               file_system: TracingFileSystem,
               segment_max_bytes: 300,
               max_disk_bytes: 1_000
             )

    assert File.exists?(quarantine_path)

    refute Enum.any?(drain_file_events([]), fn
             {:read, ^segment} -> true
             _event -> false
           end)
  end

  test "refuses to truncate an incomplete record in a non-final segment and quarantines it", %{root: root} do
    assert {:ok, store} = open_store(root, segment_max_bytes: 260)
    assert {:ok, _first, store} = Store.enqueue(store, :telemetry, String.duplicate("a", 40), entry_id: entry_id(1))
    assert {:ok, _second, _store} = Store.enqueue(store, :telemetry, String.duplicate("b", 40), entry_id: entry_id(2))
    [first_segment, _second_segment] = segment_paths(root)
    File.write!(first_segment, <<"RO">>, [:append])

    assert {:error, {:quarantined, {:incomplete_record, _offset}, quarantine_path}} =
             open_store(root, segment_max_bytes: 260)

    assert File.exists?(quarantine_path)
    refute File.exists?(first_segment)
    assert {:error, {:quarantined, _files}} = open_store(root, segment_max_bytes: 260)
  end

  test "quarantines an implausible short suffix in the final segment", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, _entry, _store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))
    [segment] = segment_paths(root)
    File.write!(segment, "XX", [:append])

    assert {:error, {:quarantined, :invalid_partial_header, quarantine_path}} = open_store(root)
    assert File.exists?(quarantine_path)
  end

  test "does not disguise a complete corrupt zero-tailed record as a torn write", %{root: root} do
    File.mkdir_p!(root)
    segment = Path.join(root, "segment-00000000000000000001.log")
    payload = "payload" <> :binary.copy(<<0>>, 16)
    encoded = encoded_entry(1, entry_id(1), payload)
    corruption_offset = byte_size(encoded) - 17

    <<prefix::binary-size(corruption_offset), byte, suffix::binary>> = encoded
    corrupt = prefix <> <<Bitwise.bxor(byte, 1)>> <> suffix
    File.write!(segment, corrupt)

    assert {:error, {:quarantined, :checksum_mismatch, quarantine_path}} = open_store(root)
    assert File.read!(quarantine_path) == corrupt
    assert {:error, {:quarantined, _files}} = open_store(root)
  end

  test "future record versions fail closed without quarantining intact durable data", %{root: root} do
    File.mkdir_p!(root)
    segment = Path.join(root, "segment-00000000000000000001.log")
    body_length = 0
    guard = Bitwise.bxor(body_length, 0xFFFFFFFF)
    bytes = <<"RODO", 4, 1, body_length::32, guard::32>>
    File.write!(segment, bytes)

    assert {:error, :future_record_version} = open_store(root)
    assert File.read!(segment) == bytes
    refute File.exists?(Path.join(root, "quarantine"))
  end

  test "quarantines checksum and semantic corruption instead of skipping entries", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, _entry, _store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))
    [segment] = segment_paths(root)
    bytes = File.read!(segment)
    <<prefix::binary-size(byte_size(bytes) - 2), byte, suffix>> = bytes
    File.write!(segment, prefix <> <<Bitwise.bxor(byte, 1), suffix>>)

    assert {:error, {:quarantined, :checksum_mismatch, quarantine_path}} = open_store(root)
    assert File.exists?(quarantine_path)

    semantic_root = root <> "_semantic"
    on_exit(fn -> File.rm_rf(semantic_root) end)
    File.mkdir_p!(semantic_root)

    payload = "unknown-stream"

    assert {:ok, encoded} =
             RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Record.encode(%{
               kind: :entry,
               stream: "not_configured",
               device_id: @device_id,
               credential_epoch: @credential_epoch,
               storage_epoch: @storage_epoch,
               sequence: 1,
               entry_id: entry_id(9),
               payload_hash: :crypto.hash(:sha256, payload),
               payload: payload,
               priority: 0
             })

    File.write!(Path.join(semantic_root, "segment-00000000000000000001.log"), encoded)

    assert {:error, {:quarantined, :unknown_stream, semantic_quarantine}} = open_store(semantic_root)
    assert File.exists?(semantic_quarantine)
  end

  test "current snapshots cannot understate entry byte-capacity accounting", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, first, store} = Store.enqueue(store, :telemetry, "first", entry_id: entry_id(1))
    assert {:ok, second, store} = Store.enqueue(store, :telemetry, "second", entry_id: entry_id(2))
    assert {:ok, [^second], _store} = Store.acknowledge(store, receipt_for(second))

    snapshot_path = Path.join(root, "snapshot.bin")
    assert {:ok, snapshot} = snapshot_path |> File.read!() |> Snapshot.decode()
    [entry] = snapshot["entries"]
    assert entry["encoded_size"] == first.encoded_size

    assert {:ok, bytes} =
             snapshot
             |> Map.put("entries", [%{entry | "encoded_size" => first.encoded_size - 1}])
             |> Snapshot.encode()

    File.write!(snapshot_path, bytes)

    assert {:error, {:quarantined, :invalid_snapshot, quarantine_path}} = open_store(root)
    assert File.exists?(quarantine_path)
  end

  test "legacy segment entries retain stable byte-capacity accounting through compaction", %{root: root} do
    File.mkdir_p!(root)
    segment = Path.join(root, "segment-00000000000000000001.log")
    File.write!(segment, legacy_v2_encoded_entry(1, entry_id(1), "legacy"))

    assert {:ok, replayed} = open_store(root)
    %{bytes: replayed_bytes} = Store.usage(replayed)

    assert {:ok, second, replayed} =
             Store.enqueue(replayed, :telemetry, "second", entry_id: entry_id(2))

    assert {:ok, [^second], compacted} = Store.acknowledge(replayed, receipt_for(second))
    %{bytes: compacted_bytes} = Store.usage(compacted)
    assert compacted_bytes == replayed_bytes

    assert {:ok, reopened} = open_store(root)
    assert Store.usage(reopened).bytes == replayed_bytes
  end

  test "enforces entry and byte capacity as explicit backpressure without eviction", %{root: root} do
    assert {:ok, store} = open_store(root, max_entries: 1)
    assert {:ok, first, store} = Store.enqueue(store, :telemetry, "first", entry_id: entry_id(1))

    assert {:error, {:backpressure, :entry_capacity}} =
             Store.enqueue(store, :telemetry, "second", entry_id: entry_id(2))

    assert Store.pending(store) == [first]

    bytes_root = root <> "_bytes"
    on_exit(fn -> File.rm_rf(bytes_root) end)
    assert {:ok, roomy} = open_store(bytes_root, max_bytes: 10_000)
    assert {:ok, only, roomy} = Store.enqueue(roomy, :telemetry, "only", entry_id: entry_id(3))
    %{bytes: used_bytes} = Store.usage(roomy)

    assert {:ok, bounded} = open_store(bytes_root, max_bytes: used_bytes)

    assert {:error, {:backpressure, :byte_capacity}} =
             Store.enqueue(bounded, :health, "one-more", entry_id: entry_id(4))

    assert Store.pending(bounded) == [only]
  end

  test "deletes only after an authenticated receipt exactly matches durable identity", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, entry, store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))

    base_receipt = Map.put(receipt_for(entry), :receipt_hash, <<2::256>>)

    assert {:error, :storage_epoch_mismatch} =
             Store.acknowledge(store, %{base_receipt | storage_epoch: <<9::128>>})

    assert {:error, :payload_hash_mismatch} =
             Store.acknowledge(store, %{base_receipt | payload_hash: <<9::256>>})

    assert {:error, :receipt_entry_not_found} =
             Store.acknowledge(store, %{base_receipt | sequence: 2})

    assert Store.pending(store) == [entry]
    assert {:ok, [^entry], empty} = Store.acknowledge(store, base_receipt)
    assert Store.pending(empty) == []
    assert {:ok, recovered} = open_store(root)
    assert Store.pending(recovered) == []
    assert Store.next_sequence(recovered, :telemetry) == {:ok, 2}
  end

  test "a cumulative receipt removes only its matching contiguous prefix", %{root: root} do
    assert {:ok, store} = open_store(root)

    {entries, store} =
      Enum.map_reduce(1..4, store, fn n, acc ->
        {:ok, entry, acc} = Store.enqueue(acc, :telemetry, "payload-#{n}", entry_id: entry_id(n))
        {entry, acc}
      end)

    [first, second, third, fourth] = entries

    receipt = %{receipt_for(third) | cumulative_sequence: 2}

    assert {:ok, [^first, ^second, ^third], store} = Store.acknowledge(store, receipt)
    assert Store.pending(store) == [fourth]

    gap_root = root <> "_gap"
    on_exit(fn -> File.rm_rf(gap_root) end)
    assert {:ok, gap_store} = open_store(gap_root)

    {[gap_first, gap_second, gap_third], gap_store} =
      Enum.map_reduce(1..3, gap_store, fn n, acc ->
        {:ok, entry, acc} = Store.enqueue(acc, :telemetry, "gap-#{n}", entry_id: entry_id(n + 10))
        {entry, acc}
      end)

    assert {:ok, [^gap_second], gap_store} = Store.acknowledge(gap_store, receipt_for(gap_second))

    assert {:ok, [^gap_first, ^gap_third], gap_store} =
             Store.acknowledge(gap_store, %{receipt_for(gap_third) | cumulative_sequence: 3})

    assert Store.pending(gap_store) == []
  end

  test "stronger cumulative retries refresh their retained exact anchor", %{root: root} do
    assert {:ok, store} = open_store(root, max_resolved_receipts: 1)

    {[first, second, third, anchor], store} =
      Enum.map_reduce(1..4, store, fn n, acc ->
        {:ok, entry, acc} =
          Store.enqueue(acc, :telemetry, "payload-#{n}", entry_id: entry_id(n))

        {entry, acc}
      end)

    assert {:ok, [^anchor], store} = Store.acknowledge(store, receipt_for(anchor))

    assert {:ok, [^first], store} =
             Store.acknowledge(
               store,
               %{receipt_for(anchor) | cumulative_sequence: 1}
             )

    assert Store.resolved_receipt?(store, receipt_for(anchor))

    assert {:ok, [^second], store} =
             Store.acknowledge(
               store,
               %{receipt_for(anchor) | cumulative_sequence: 2}
             )

    assert Store.resolved_receipt?(store, receipt_for(anchor))

    assert {:ok, recovered} = open_store(root, max_resolved_receipts: 1)

    assert {:ok, [removed_third], empty} =
             Store.acknowledge(
               recovered,
               %{receipt_for(anchor) | cumulative_sequence: 3}
             )

    assert receipt_for(removed_third) == receipt_for(third)
    assert Store.pending(empty) == []
  end

  test "persists a contiguous acknowledged floor beyond bounded exact receipt history", %{root: root} do
    opts = [max_resolved_receipts: 1]
    assert {:ok, store} = open_store(root, opts)

    {[first, second, third], store} =
      Enum.map_reduce(1..3, store, fn n, acc ->
        {:ok, entry, acc} =
          Store.enqueue(acc, :telemetry, "payload-#{n}", entry_id: entry_id(n))

        {entry, acc}
      end)

    assert {:ok, [^first], store} = Store.acknowledge(store, receipt_for(first))
    assert {:ok, [^second], _store} = Store.acknowledge(store, receipt_for(second))

    assert {:ok, recovered} = open_store(root, opts)

    assert {:ok, [removed_third], empty} =
             Store.acknowledge(recovered, %{receipt_for(third) | cumulative_sequence: 3})

    assert receipt_for(removed_third) == receipt_for(third)
    assert Store.pending(empty) == []

    assert {:ok, recovered} = open_store(root, opts)

    assert {:ok, fourth, recovered} =
             Store.enqueue(recovered, :telemetry, "payload-4", entry_id: entry_id(4))

    assert {:ok, [^fourth], empty} =
             Store.acknowledge(recovered, %{receipt_for(fourth) | cumulative_sequence: 4})

    assert Store.pending(empty) == []
  end

  test "binds device id and credential epoch into durable identity and fails closed on mismatch", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, entry, store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))

    assert entry.device_id == @device_id
    assert entry.credential_epoch == @credential_epoch

    base_receipt = receipt_for(entry)

    assert {:error, :device_id_mismatch} =
             Store.acknowledge(store, %{base_receipt | device_id: @other_device_id})

    assert {:error, :credential_epoch_mismatch} =
             Store.acknowledge(store, %{base_receipt | credential_epoch: @credential_epoch + 1})

    assert {:error, :invalid_device_id} =
             Store.acknowledge(store, Map.delete(base_receipt, :device_id))

    assert {:error, :invalid_credential_epoch} =
             Store.acknowledge(store, Map.delete(base_receipt, :credential_epoch))

    identity = Map.take(entry, [:stream, :device_id, :credential_epoch, :storage_epoch, :sequence, :payload_hash])

    assert {:error, :device_id_mismatch} =
             Store.authorize_loss(store, %{identity | device_id: @other_device_id}, "operator approved")

    assert {:error, :credential_epoch_mismatch} =
             Store.authorize_loss(
               store,
               %{identity | credential_epoch: @credential_epoch + 1},
               "operator approved"
             )

    assert Store.pending(store) == [entry]
    assert {:ok, [^entry], empty} = Store.acknowledge(store, base_receipt)
    assert Store.pending(empty) == []
  end

  test "refuses to reopen a root recorded under a different device or credential epoch", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, _entry, _store} = Store.enqueue(store, :telemetry, "payload", entry_id: entry_id(1))

    assert {:error, :device_id_mismatch} = open_store(root, device_id: @other_device_id)

    assert {:error, :credential_epoch_mismatch} =
             open_store(root, credential_epoch: @credential_epoch + 1)

    assert {:error, :invalid_device_id} = open_store(root, device_id: <<0::128>>)
    assert {:error, :invalid_device_id} = open_store(root, device_id: <<0::120>>)
    assert {:error, :invalid_credential_epoch} = open_store(root, credential_epoch: -1)

    assert {:ok, recovered} = open_store(root)
    assert Enum.map(Store.pending(recovered), & &1.sequence) == [1]
  end

  test "explicit loss authorization durably records the exact entry and auditable reason", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, entry, store} = Store.enqueue(store, :health, "health", entry_id: entry_id(1))

    identity =
      Map.take(entry, [:stream, :device_id, :credential_epoch, :storage_epoch, :sequence, :payload_hash])

    assert {:error, :invalid_loss_reason} = Store.authorize_loss(store, identity, "")

    assert {:error, :payload_hash_mismatch} =
             Store.authorize_loss(store, %{identity | payload_hash: <<0::256>>}, "operator approved")

    reason = "operator approved loss after irrecoverable media failure ticket RMA-42"
    assert {:ok, ^entry, empty} = Store.authorize_loss(store, identity, reason)
    assert Store.pending(empty) == []

    assert Store.loss_authorizations(empty) == [
             %{
               stream: entry.stream,
               device_id: entry.device_id,
               credential_epoch: entry.credential_epoch,
               storage_epoch: entry.storage_epoch,
               sequence: entry.sequence,
               entry_id: entry.entry_id,
               payload_hash: entry.payload_hash,
               reason: reason
             }
           ]

    assert {:ok, recovered} = open_store(root)
    assert Store.pending(recovered) == []
    assert Store.loss_authorizations(recovered) == Store.loss_authorizations(empty)
  end

  defp prepare_active_limit_three_retry!(root) do
    assert {:ok, store} =
             open_store(
               root,
               file_system: TracingFileSystem,
               max_entry_id_tombstones: 3,
               max_resolved_receipts: 3
             )

    {[first, second, third], store} =
      Enum.map_reduce(1..3, store, fn n, acc ->
        {:ok, entry, acc} =
          Store.enqueue(acc, :telemetry, "payload-#{n}", entry_id: entry_id(n))

        {entry, acc}
      end)

    assert {:ok, [^third], store} = Store.acknowledge(store, receipt_for(third))
    TracingFileSystem.fail_snapshot_rename()

    assert {:error, {:durability_uncertain, {:snapshot_rename, :simulated_rename_failure}}} =
             Store.acknowledge(
               store,
               %{receipt_for(third) | cumulative_sequence: 3}
             )

    assert first.sequence == 1
    assert second.sequence == 2
    assert segment_paths(root) != []
    {first, second, third}
  end

  defp checkpoint_delivery(sequence, parent_hash) do
    assert {:ok, content} =
             Checkpoint.encode_content(:calibration, 1, %{
               "awa_estimators" => [],
               "aws_estimators" => [],
               "prev_applied" => [],
               "seq" => 0,
               "stw_estimators" => []
             })

    assert {:ok, content_hash} = Checkpoint.content_hash(:calibration, 1, content)

    attrs = %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      sequence: sequence,
      kind: :calibration,
      schema_version: 1,
      source_generation: 42,
      parent_hash: parent_hash,
      content_hash: content_hash
    }

    assert {:ok, checkpoint_hash} = Checkpoint.hash(attrs)

    submission =
      attrs
      |> Map.put(:checkpoint_hash, checkpoint_hash)
      |> Map.put(:content, content)

    assert {:ok, payload} = Messages.encode(:checkpoint_submission, submission)
    {:ok, %{payload: payload, payload_hash: checkpoint_hash}}
  end

  defp legacy_v2_encoded_entry(sequence, id, payload) do
    stream = "telemetry"
    sequence_bytes = :binary.encode_unsigned(sequence)
    payload_hash = :crypto.hash(:sha256, payload)

    prefix =
      <<byte_size(stream)::16, stream::binary, @device_id, @credential_epoch::32, @storage_epoch,
        byte_size(sequence_bytes)::16, sequence_bytes::binary, byte_size(id)::16, id::binary,
        payload_hash::binary-size(32), byte_size(payload)::64>>

    kind_code = 1

    checksum =
      :crypto.hash(:sha256, [
        "RacingOrg-DurableOutboxRecordChecksum-v1",
        <<2, kind_code>>,
        prefix,
        payload,
        <<0>>
      ])

    body = prefix <> checksum <> payload <> <<0>>
    body_length = byte_size(body)
    guard = Bitwise.bxor(body_length, 0xFFFFFFFF)
    <<"RODO", 2, kind_code, body_length::32, guard::32, body::binary>>
  end

  defp encoded_entry(sequence, id, payload) do
    payload_checksum = :crypto.hash(:sha256, payload)

    {:ok, encoded} =
      Record.encode(%{
        kind: :entry,
        stream: "telemetry",
        device_id: @device_id,
        credential_epoch: @credential_epoch,
        storage_epoch: @storage_epoch,
        sequence: sequence,
        entry_id: id,
        payload_hash: payload_checksum,
        payload: payload,
        priority: 0
      })

    encoded
  end

  defp legacy_snapshot_v1(overrides \\ %{}) do
    snapshot =
      Map.merge(
        %{
          "covered_segment_id" => 0,
          "device_id" => @device_id,
          "credential_epoch" => @credential_epoch,
          "storage_epoch" => @storage_epoch,
          "next_sequences" => [{"health", 1}, {"telemetry", 1}],
          "entries" => [],
          "loss_authorizations" => []
        },
        overrides
      )

    {:ok, bytes} = Snapshot.encode(snapshot)
    bytes
  end

  defp rewrite_next_sequence!(root, stream_name, sequence) do
    path = Path.join(root, "snapshot.bin")
    {:ok, snapshot} = path |> File.read!() |> Snapshot.decode()

    next_sequences =
      Enum.map(snapshot["next_sequences"], fn
        {^stream_name, _current} -> {stream_name, sequence}
        stream -> stream
      end)

    assert {:ok, bytes} =
             snapshot
             |> Map.put("next_sequences", next_sequences)
             |> Snapshot.encode()

    File.write!(path, bytes)
  end

  defp downgrade_snapshot_to_v2!(root) do
    path = Path.join(root, "snapshot.bin")
    {:ok, snapshot} = path |> File.read!() |> Snapshot.decode()

    {:ok, bytes} =
      snapshot
      |> Map.put("schema_version", 2)
      |> Map.delete("acknowledged_floors")
      |> Snapshot.encode()

    File.write!(path, bytes)
  end

  defp snapshot_frame(version, payload) do
    payload_size = byte_size(payload)

    checksum =
      :crypto.hash(:sha256, [
        "RacingOrg-DurableOutboxSnapshotChecksum-v1",
        <<version, payload_size::64>>,
        payload
      ])

    <<"RODS", version, payload_size::64, checksum::binary, payload::binary>>
  end

  defp truncate_file!(path, size) do
    {:ok, device} = File.open(path, [:read, :write, :binary, :raw])
    {:ok, ^size} = :file.position(device, size)
    :ok = :file.truncate(device)
    :ok = :file.close(device)
  end

  defp append_acknowledgement_record!(
         root,
         receipt
       ) do
    assert {:ok, encoded} =
             Record.encode(%{
               kind: :acknowledgement,
               stream: Atom.to_string(receipt.stream),
               device_id: receipt.device_id,
               credential_epoch: receipt.credential_epoch,
               storage_epoch: receipt.storage_epoch,
               sequence: receipt.sequence,
               payload_hash: receipt.payload_hash,
               cumulative_sequence: receipt.cumulative_sequence
             })

    [segment] = segment_paths(root)
    File.write!(segment, encoded, [:append])
  end

  defp snapshot_loss_authorization(entry) do
    %{
      "stream" => Atom.to_string(entry.stream),
      "device_id" => entry.device_id,
      "credential_epoch" => entry.credential_epoch,
      "storage_epoch" => entry.storage_epoch,
      "sequence" => entry.sequence,
      "entry_id" => entry.entry_id,
      "payload_hash" => entry.payload_hash,
      "reason" => "operator ticket"
    }
  end

  defp snapshot_resolved_receipt(entry) do
    %{
      "stream" => Atom.to_string(entry.stream),
      "device_id" => entry.device_id,
      "credential_epoch" => entry.credential_epoch,
      "storage_epoch" => entry.storage_epoch,
      "sequence" => entry.sequence,
      "payload_hash" => entry.payload_hash
    }
  end

  defp receipt_for(entry) do
    %{
      stream: entry.stream,
      device_id: entry.device_id,
      credential_epoch: entry.credential_epoch,
      storage_epoch: entry.storage_epoch,
      sequence: entry.sequence,
      payload_hash: entry.payload_hash,
      cumulative_sequence: 0
    }
  end

  defp disk_bytes_on_disk(root) do
    root
    |> File.ls!()
    |> Enum.filter(
      &(&1 in ["snapshot.bin", "run-state.bin", "run-state.required"] or
          String.match?(&1, ~r/^segment-\d{20}\.log$/))
    )
    |> Enum.map(&Path.join(root, &1))
    |> Enum.reduce(0, fn path, total -> File.stat!(path).size + total end)
  end

  defp open_store(root, overrides \\ []) do
    defaults = [
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      streams: [:telemetry, :health],
      max_entries: 10,
      max_bytes: 10_000,
      segment_max_bytes: 4_096
    ]

    Store.open(root, Keyword.merge(defaults, overrides))
  end

  defp entry_id(n), do: <<n::128>>

  defp case_variant(path) do
    Path.join(Path.dirname(path), toggle_first_ascii_case(Path.basename(path)))
  end

  defp toggle_first_ascii_case(<<character, rest::binary>>)
       when character >= ?a and character <= ?z,
       do: <<character - 32, rest::binary>>

  defp toggle_first_ascii_case(<<character, rest::binary>>)
       when character >= ?A and character <= ?Z,
       do: <<character + 32, rest::binary>>

  defp toggle_first_ascii_case(<<character, rest::binary>>),
    do: <<character>> <> toggle_first_ascii_case(rest)

  defp toggle_first_ascii_case(<<>>), do: <<>>

  defp same_file?(left_path, right_path) do
    with {:ok, left} <- File.stat(left_path),
         {:ok, right} <- File.stat(right_path) do
      {left.major_device, left.minor_device, left.inode, left.type} ==
        {right.major_device, right.minor_device, right.inode, right.type}
    else
      _error -> false
    end
  end

  defp segment_paths(root) do
    root
    |> File.ls!()
    |> Enum.filter(&String.match?(&1, ~r/^segment-\d{20}\.log$/))
    |> Enum.sort()
    |> Enum.map(&Path.join(root, &1))
  end

  defp created_segment_path({:create, path, _mode}), do: path
  defp created_segment_path(_event), do: nil

  defp event_index(events, predicate) do
    Enum.find_index(events, predicate) || flunk("expected event in #{inspect(events)}")
  end

  defp drain_file_events(acc) do
    receive do
      {:outbox_file_system, event} -> drain_file_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_segment_events(acc) do
    receive do
      {:outbox_segment_file_system, event} -> drain_segment_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
