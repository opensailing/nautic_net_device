defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.StoreTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.Calibration.Observer, as: CalibrationObserver
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.{Record, Snapshot, Store}
  alias RacingOrg.Tracker.Pro.Polar.Observer.{Bins, Gate}
  alias RacingOrg.Tracker.Pro.Polar.Observer.Snapshot, as: PolarSnapshot
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.Calibration,
    as: CalibrationRuntime

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.Polar,
    as: PolarRuntime

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.WindShift,
    as: WindShiftRuntime

  alias RacingOrg.Tracker.Pro.WindShift.Observer, as: WindShiftObserver

  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Store.FileSystem

  defmodule PathReadObserverFileSystem do
    @behaviour FileSystem

    def read(path) do
      case :persistent_term.get({__MODULE__, path}, nil) do
        nil ->
          FileSystem.read(path)

        {pid, result} ->
          send(pid, {:checkpoint_head_path_read, path})
          result
      end
    end

    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
  end

  defmodule TransientLstatFileSystem do
    @behaviour FileSystem

    def lstat(path) do
      case :persistent_term.get({__MODULE__, path}, :persistent_term.get(__MODULE__, nil)) do
        nil ->
          FileSystem.lstat(path)

        {pid, basename, result} ->
          if Path.basename(path) == basename do
            send(pid, {:checkpoint_head_lstat, path})
            result
          else
            FileSystem.lstat(path)
          end

        {pid, result} ->
          send(pid, {:checkpoint_head_lstat, path})
          result
      end
    end

    defdelegate read(path), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
    defdelegate list_dir(path), to: FileSystem
  end

  defmodule SymlinkSwapFileSystem do
    @behaviour FileSystem

    def lstat(path) do
      case :persistent_term.get({__MODULE__, path}, nil) do
        nil ->
          FileSystem.lstat(path)

        {pid, target} ->
          result = FileSystem.lstat(path)
          :persistent_term.erase({__MODULE__, path})
          File.rename!(path, path <> ".before-swap")
          File.ln_s!(target, path)
          send(pid, {:checkpoint_head_swapped, path})
          result
      end
    end

    defdelegate read(path), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
    defdelegate list_dir(path), to: FileSystem
  end

  defmodule OversizedReadFileSystem do
    @behaviour FileSystem

    def read(device, count) do
      case :persistent_term.get(__MODULE__, nil) do
        nil ->
          FileSystem.read(device, count)

        pid when is_pid(pid) and count >= 0 ->
          send(pid, {:checkpoint_head_read_count, count})
          {:ok, :binary.copy(<<0>>, count + 1)}

        pid when is_pid(pid) ->
          send(pid, {:checkpoint_head_negative_read_count, count})
          {:error, :negative_count}
      end
    end

    defdelegate read(path), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
    defdelegate list_dir(path), to: FileSystem
  end

  defmodule BoundedReadFileSystem do
    defdelegate lstat(path), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate close(device), to: FileSystem
  end

  defmodule NoReadLinkFileSystem do
    @behaviour FileSystem

    defdelegate read(path), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate list_dir(path), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
  end

  defmodule RenameDuringOpenFileSystem do
    @behaviour FileSystem

    def lstat(path) do
      case :persistent_term.get({__MODULE__, path}, nil) do
        nil ->
          FileSystem.lstat(path)

        owner when is_pid(owner) ->
          :persistent_term.erase({__MODULE__, path})
          result = FileSystem.lstat(path)
          send(owner, {:checkpoint_head_initial_lstat, self(), path})

          receive do
            :continue_checkpoint_head_open -> result
          end
      end
    end

    defdelegate read(path), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
    defdelegate list_dir(path), to: FileSystem
  end

  defmodule MalformedFileInfoFileSystem do
    @behaviour FileSystem

    def file_info(device) do
      case :persistent_term.get(__MODULE__, nil) do
        nil -> FileSystem.file_info(device)
        %File.Stat{} = stat -> {:ok, stat}
      end
    end

    defdelegate read(path), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
    defdelegate list_dir(path), to: FileSystem
  end

  defmodule BlockingLstatFileSystem do
    @behaviour FileSystem

    def lstat(path) do
      case :persistent_term.get(__MODULE__, nil) do
        {pid, basename} ->
          if Path.basename(path) == basename do
            send(pid, {:checkpoint_head_lstat_blocked, path})
            send(pid, {:checkpoint_head_lstat_worker, self()})

            receive do
              :release_checkpoint_head_lstat -> FileSystem.lstat(path)
            end
          else
            FileSystem.lstat(path)
          end

        nil ->
          FileSystem.lstat(path)
      end
    end

    defdelegate read(path), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate list_dir(path), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
  end

  defmodule KillingLstatFileSystem do
    @behaviour FileSystem

    def lstat(_path), do: Process.exit(self(), :kill)
    defdelegate read(path), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate list_dir(path), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
  end

  defmodule BlockingOpenFileSystem do
    @behaviour FileSystem

    def open(path, modes) do
      case :persistent_term.get(__MODULE__, nil) do
        {pid, basename} ->
          if Path.basename(path) == basename and :directory not in modes do
            send(pid, {:checkpoint_head_open_blocked, path})

            receive do
              :release_checkpoint_head_open -> FileSystem.open(path, modes)
            end
          else
            FileSystem.open(path, modes)
          end

        nil ->
          FileSystem.open(path, modes)
      end
    end

    defdelegate read(path), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
    defdelegate list_dir(path), to: FileSystem
  end

  defmodule PrematureEofFileSystem do
    @behaviour FileSystem

    def read(device, count) do
      case :persistent_term.get(__MODULE__, nil) do
        pid when is_pid(pid) ->
          send(pid, {:checkpoint_head_premature_eof, count})
          :eof

        nil ->
          FileSystem.read(device, count)
      end
    end

    defdelegate read(path), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
    defdelegate list_dir(path), to: FileSystem
  end

  defmodule FinalPathSwapFileSystem do
    @behaviour FileSystem

    def file_info(device) do
      case :persistent_term.get(__MODULE__, nil) do
        {pid, path, replacement, counter} ->
          result = FileSystem.file_info(device)

          if :atomics.add_get(counter, 1, 1) == 2 do
            :persistent_term.erase(__MODULE__)
            File.rename!(path, path <> ".before-final-swap")
            File.rename!(replacement, path)
            send(pid, {:checkpoint_head_final_path_swapped, path})
          end

          result

        nil ->
          FileSystem.file_info(device)
      end
    end

    defdelegate read(path), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
    defdelegate list_dir(path), to: FileSystem
  end

  defmodule ChangedThenMissingFileSystem do
    @behaviour FileSystem

    def file_info(device) do
      case :persistent_term.get(__MODULE__, nil) do
        {pid, path, replacement, file_info_counter, _lstat_counter, _retry_lstat_result} ->
          result = FileSystem.file_info(device)

          if :atomics.add_get(file_info_counter, 1, 1) == 2 do
            File.rename!(path, path <> ".before-changed-read")
            File.rename!(replacement, path)
            send(pid, {:checkpoint_head_changed_before_retry, path})
          end

          result

        nil ->
          FileSystem.file_info(device)
      end
    end

    def lstat(path) do
      case :persistent_term.get(__MODULE__, nil) do
        {pid, configured_path, _replacement, _file_info_counter, lstat_counter, retry_lstat_result} ->
          if Path.basename(path) == Path.basename(configured_path) do
            count = :atomics.add_get(lstat_counter, 1, 1)
            send(pid, {:checkpoint_head_changed_read_lstat, count})

            case count do
              4 -> retry_lstat_result
              _count -> FileSystem.lstat(path)
            end
          else
            FileSystem.lstat(path)
          end

        _other ->
          FileSystem.lstat(path)
      end
    end

    defdelegate read(path), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate list_dir(path), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
  end

  defmodule CleanupUnavailableFileSystem do
    @behaviour FileSystem

    def list_dir(_path), do: {:error, :eacces}

    defdelegate read(path), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
  end

  defmodule BlockingListDirFileSystem do
    @behaviour FileSystem

    def list_dir(path) do
      case :persistent_term.get(__MODULE__, nil) do
        pid when is_pid(pid) ->
          send(pid, {:checkpoint_head_list_dir_blocked, self(), path})

          receive do
            :release_checkpoint_head_list_dir -> FileSystem.list_dir(path)
          end

        nil ->
          FileSystem.list_dir(path)
      end
    end

    defdelegate read(path), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
  end

  defmodule DirectoryPreparationRaceFileSystem do
    @behaviour FileSystem

    def chmod(path, mode) do
      case :persistent_term.get(__MODULE__, nil) do
        {test_pid, chmod_counter, _list_counter} ->
          if Path.basename(path) == "checkpoint_heads" and
               :atomics.add_get(chmod_counter, 1, 1) == 1 do
            send(test_pid, {:checkpoint_lock_directory_chmod_blocked, self(), path})

            receive do
              :release_checkpoint_lock_directory_chmod -> {:error, :eacces}
            end
          else
            FileSystem.chmod(path, mode)
          end

        nil ->
          FileSystem.chmod(path, mode)
      end
    end

    def list_dir(path) do
      case :persistent_term.get(__MODULE__, nil) do
        {test_pid, _chmod_counter, list_counter} ->
          if :atomics.add_get(list_counter, 1, 1) == 1 do
            send(test_pid, {:checkpoint_old_inode_writer_blocked, self(), path})

            receive do
              :release_checkpoint_old_inode_writer -> FileSystem.list_dir(path)
            end
          else
            FileSystem.list_dir(path)
          end

        nil ->
          FileSystem.list_dir(path)
      end
    end

    defdelegate read(path), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
  end

  defmodule ReentrantCanonicalFileSystem do
    @behaviour FileSystem

    def lstat(path) do
      case :persistent_term.get(__MODULE__, nil) do
        {test_pid, store, attrs, counter} ->
          if :atomics.add_get(counter, 1, 1) == 1 do
            result =
              RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Store.put(store, attrs)

            send(test_pid, {:canonical_checkpoint_reentry, result})
          end

        nil ->
          :ok
      end

      FileSystem.lstat(path)
    end

    defdelegate read(path), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate list_dir(path), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
  end

  defmodule ReentrantReadFileSystem do
    @behaviour FileSystem

    def lstat(path) do
      case :persistent_term.get(__MODULE__, nil) do
        {test_pid, store, attrs, counter} ->
          if String.ends_with?(path, ".head") and :atomics.add_get(counter, 1, 1) == 1 do
            result =
              RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Store.put(store, attrs)

            send(test_pid, {:read_checkpoint_reentry, result})
          end

        nil ->
          :ok
      end

      FileSystem.lstat(path)
    end

    defdelegate read(path), to: FileSystem
    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate list_dir(path), to: FileSystem
    defdelegate read_link(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
  end

  defmodule IdentityAuthority do
    use GenServer

    def start_link(identity), do: GenServer.start_link(__MODULE__, identity)

    def with_lease(server, transition) when is_function(transition, 1) do
      case GenServer.call(server, {:acquire, self()}) do
        {:ok, identity, lease_ref} ->
          try do
            transition.(identity)
          after
            GenServer.call(server, {:release, lease_ref})
          end

        {:error, _reason} = error ->
          error
      end
    end

    def rotate(server, identity, observer),
      do: GenServer.call(server, {:rotate, identity, observer})

    @impl true
    def init(identity), do: {:ok, %{identity: identity, lease: nil, waiting: :queue.new()}}

    @impl true
    def handle_call({:acquire, owner}, _from, %{lease: nil} = state) do
      lease = lease(owner)
      {:reply, grant(owner, state.identity, lease.ref), %{state | lease: lease}}
    end

    def handle_call({:acquire, owner}, from, state) do
      {:noreply, %{state | waiting: :queue.in({:acquire, from, owner}, state.waiting)}}
    end

    def handle_call({:rotate, identity, observer}, _from, %{lease: nil} = state) do
      send(observer, :checkpoint_identity_rotation_submitted)
      {:reply, :ok, %{state | identity: identity}}
    end

    def handle_call({:rotate, identity, observer}, from, state) do
      send(observer, :checkpoint_identity_rotation_submitted)
      {:noreply, %{state | waiting: :queue.in({:rotate, from, identity}, state.waiting)}}
    end

    def handle_call({:release, lease_ref}, _from, %{lease: %{ref: lease_ref}} = state) do
      Process.demonitor(state.lease.monitor, [:flush])
      {:reply, :ok, advance(%{state | lease: nil})}
    end

    def handle_call({:release, _lease_ref}, _from, state), do: {:reply, :ok, state}

    @impl true
    def handle_info(
          {:DOWN, monitor, :process, _owner, _reason},
          %{lease: %{monitor: monitor}} = state
        ) do
      {:noreply, advance(%{state | lease: nil})}
    end

    defp advance(%{lease: nil} = state) do
      case :queue.out(state.waiting) do
        {{:value, {:rotate, from, identity}}, waiting} ->
          GenServer.reply(from, :ok)
          advance(%{state | identity: identity, waiting: waiting})

        {{:value, {:acquire, from, owner}}, waiting} ->
          lease = lease(owner)
          GenServer.reply(from, grant(owner, state.identity, lease.ref))
          %{state | lease: lease, waiting: waiting}

        {:empty, _waiting} ->
          state
      end
    end

    defp lease(owner), do: %{owner: owner, ref: make_ref(), monitor: Process.monitor(owner)}
    defp grant(_owner, identity, lease_ref), do: {:ok, identity, lease_ref}
  end

  @device_id Base.decode16!("0f1e2d3c4b5a69788796a5b4c3d2e1f0", case: :lower)
  @other_device_id Base.decode16!("aabbccddeeff00112233445566778899", case: :lower)
  @storage_epoch Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @other_storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @credential_epoch 7

  setup do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    base = Path.join(System.tmp_dir!(), "checkpoint_head_#{nonce}")
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  describe "new/1" do
    test "requires an exact bound identity", ctx do
      assert {:error, :invalid_device_id} = Store.new(opts(ctx, device_id: <<0::128>>))
      assert {:error, :invalid_device_id} = Store.new(opts(ctx, device_id: <<1, 2>>))

      assert {:error, :invalid_credential_epoch} =
               Store.new(opts(ctx, credential_epoch: -1))

      assert {:error, :invalid_credential_epoch} =
               Store.new(opts(ctx, credential_epoch: 0x1_0000_0000))

      assert {:error, :invalid_storage_epoch} = Store.new(opts(ctx, storage_epoch: <<0::128>>))
      assert {:error, :invalid_storage_epoch} = Store.new(opts(ctx, storage_epoch: <<1, 2, 3>>))
      assert {:error, :invalid_base_dir} = Store.new(opts(ctx, base_dir: ""))

      assert {:error, :missing_identity_source} =
               Store.new(Keyword.delete(opts(ctx), :identity))

      assert {:error, :invalid_identity_source} = Store.new(opts(ctx, identity: :not_a_function))

      assert {:error, :invalid_transition_timeout} =
               Store.new(opts(ctx, transition_timeout_ms: 0))

      assert {:error, :invalid_transition_timeout} =
               Store.new(opts(ctx, transition_timeout_ms: :infinity))

      assert {:error, :invalid_options} = Store.new(:not_a_list)
    end

    test "ignores transient identity metadata outside the durable identity tuple", ctx do
      current_identity = Map.put(identity(), :boot_id, "transient-boot")
      identity_authority = fn transition -> transition.(current_identity) end

      assert {:ok, _store} = Store.new(opts(ctx, identity: identity_authority))
    end

    test "rejects an authority that does not invoke the guarded transition", ctx do
      assert {:error, :invalid_identity_authority} =
               Store.new(opts(ctx, identity: fn _transition -> {:ok, :forged} end))
    end

    test "rejects a guarded transition retained beyond the authority lifetime", ctx do
      test_pid = self()

      retaining_authority = fn transition ->
        send(test_pid, {:retained_identity_transition, transition})
        {:ok, :forged}
      end

      assert {:error, :invalid_identity_authority} =
               Store.new(opts(ctx, identity: retaining_authority))

      assert_receive {:retained_identity_transition, retained_transition}
      assert {:error, :invalid_identity_authority} = retained_transition.(identity())
    end

    test "executes an authority transition only once and preserves its result", ctx do
      test_pid = self()

      duplicate_authority = fn transition ->
        first = transition.(identity())
        second = transition.(identity())
        send(test_pid, {:identity_transition_results, first, second})
        {:ok, :forged}
      end

      assert {:ok, store} = Store.new(opts(ctx, identity: duplicate_authority))

      assert_receive {:identity_transition_results, {:ok, ^store}, {:error, :invalid_identity_authority}}
    end

    test "bounds an authority that never invokes the constructor transition", ctx do
      test_pid = self()

      blocking_authority = fn _transition ->
        send(test_pid, {:checkpoint_constructor_authority_blocked, self()})

        receive do
          :release_checkpoint_constructor_authority -> {:error, :released}
        end
      end

      constructor =
        Task.async(fn ->
          Store.new(opts(ctx, identity: blocking_authority, transition_timeout_ms: 100))
        end)

      assert_receive {:checkpoint_constructor_authority_blocked, authority_owner}, 2_000
      result = Task.yield(constructor, 1_000)
      if result == nil, do: Task.shutdown(constructor, :brutal_kill)

      assert {:ok, {:error, :identity_authority_timeout}} = result
      refute Process.alive?(authority_owner)
    end

    test "bounds an authority that invokes the constructor transition but never returns", ctx do
      test_pid = self()

      blocking_authority = fn transition ->
        result = transition.(identity())
        send(test_pid, {:checkpoint_constructor_authority_release_blocked, self()})

        receive do
          :release_checkpoint_constructor_authority -> result
        end
      end

      constructor =
        Task.async(fn ->
          Store.new(opts(ctx, identity: blocking_authority, transition_timeout_ms: 100))
        end)

      assert_receive {:checkpoint_constructor_authority_release_blocked, authority_owner}, 2_000
      result = Task.yield(constructor, 1_000)
      if result == nil, do: Task.shutdown(constructor, :brutal_kill)

      assert {:ok, {:error, :identity_authority_timeout}} = result
      refute Process.alive?(authority_owner)
    end
  end

  describe "head/2" do
    test "is empty for every registered kind on a fresh store", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      for {kind, _code, _schema} <- Contract.checkpoint_kinds() do
        assert :empty = Store.head(store, kind)
      end
    end

    test "rejects unknown kinds", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:error, :unknown_checkpoint_kind} = Store.head(store, :telemetry)
      assert {:error, :unknown_checkpoint_kind} = Store.head(store, "calibration")
    end

    test "puts and explicitly reopens every exact runtime schema", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      installed =
        for {kind, schema_version, content} <- runtime_schema_fixtures(), into: %{} do
          assert {:ok, record} =
                   Store.put(
                     store,
                     put_attrs(kind: kind, schema_version: schema_version, content: content)
                   )

          assert record.kind == kind
          assert record.schema_version == schema_version
          {kind, record}
        end

      assert {:ok, reopened} = Store.new(opts(ctx))

      for {kind, record} <- installed do
        assert {:ok, ^record} = Store.head(reopened, kind)
      end
    end

    test "fails closed when a stale handle reads after identity rotation", ctx do
      {:ok, authority} = Agent.start_link(fn -> identity() end)
      identity_source = fn transition -> transition.(Agent.get(authority, & &1)) end
      assert {:ok, stale_store} = Store.new(opts(ctx, identity: identity_source))
      assert {:ok, _installed} = Store.put(stale_store, put_attrs())

      Agent.update(authority, &%{&1 | credential_epoch: @credential_epoch + 1})

      assert {:error, :credential_epoch_mismatch} = Store.head(stale_store, :calibration)

      assert %{
               kinds: kinds,
               present: 0,
               accepted: 0,
               corrupt: 0,
               fenced: kinds,
               unavailable: 0
             } = Store.status(stale_store)
    end
  end

  describe "put/2 record-hash parent compare-and-swap" do
    test "accepts a first record only against the genesis parent", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:error, :checkpoint_parent_mismatch} =
               Store.put(store, put_attrs(parent_hash: :binary.copy(<<0xB2>>, 32)))

      assert {:ok, first} = Store.put(store, put_attrs())
      assert first.parent_hash == Record.genesis_parent()
      assert {:ok, ^first} = Store.head(store, :calibration)
    end

    test "rejects local and hydrated schema downgrade after exact-runtime adoption", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      for {kind, runtime_schema, runtime_content} <- runtime_schema_fixtures() do
        assert {:ok, runtime} =
                 Store.put(
                   store,
                   put_attrs(kind: kind, schema_version: runtime_schema, content: runtime_content)
                 )

        {legacy_schema, legacy_content} = legacy_schema_fixture(kind)

        legacy_successor = [
          kind: kind,
          schema_version: legacy_schema,
          sequence: runtime.sequence + 1,
          source_generation: runtime.source_generation + 1,
          parent_hash: runtime.checkpoint_hash,
          content: legacy_content
        ]

        assert {:error, :checkpoint_schema_downgrade} =
                 Store.put(store, put_attrs(legacy_successor))

        assert {:error, :checkpoint_schema_downgrade} =
                 Store.hydrate(store, hydrate_attrs(legacy_successor))

        assert {:ok, ^runtime} = Store.head(store, kind)
      end
    end

    test "persists and exactly reopens a schema-valid record near the semantic cap", ctx do
      assert {:ok, store} = Store.new(opts(ctx, transition_timeout_ms: 180_000))
      semantic_cap = Contract.max_checkpoint_content_size()
      content = near_semantic_cap_polar_content()

      assert {:ok, canonical} = Checkpoint.canonical_content(:polar, 2, content)
      assert byte_size(canonical) == 8_285_599
      assert byte_size(canonical) > semantic_cap - 262_144
      assert byte_size(canonical) <= semantic_cap

      assert {:ok, installed} =
               Store.put(
                 store,
                 put_attrs(kind: :polar, schema_version: 2, content: canonical)
               )

      persisted = File.read!(Store.head_path(store, :polar))
      assert byte_size(persisted) == 8_286_230
      assert byte_size(persisted) > semantic_cap - 262_144
      assert byte_size(persisted) <= Snapshot.max_encoded_size()

      assert {:ok, reopened} = Store.new(opts(ctx))
      assert {:ok, ^installed} = Store.head(reopened, :polar)
      assert installed.content === canonical
    end

    test "chains the next record from the current record hash", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, second} =
               Store.put(
                 store,
                 put_attrs(sequence: 2, source_generation: 43, parent_hash: first.checkpoint_hash)
               )

      assert second.parent_hash == first.checkpoint_hash
      assert {:ok, ^second} = Store.head(store, :calibration)
    end

    test "rejects a stale parent from a superseded head", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, second} =
               Store.put(
                 store,
                 put_attrs(sequence: 2, source_generation: 43, parent_hash: first.checkpoint_hash)
               )

      assert {:error, :checkpoint_parent_mismatch} =
               Store.put(
                 store,
                 put_attrs(sequence: 3, source_generation: 44, parent_hash: first.checkpoint_hash)
               )

      assert {:ok, ^second} = Store.head(store, :calibration)
    end

    test "rejects an ABA write whose parent has the same sequence and content but a different record hash",
         ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      # The writer observed head A and prepared a successor chained from it.
      assert {:ok, observed} = Store.put(store, put_attrs(sequence: 5, source_generation: 42))

      # The head is then replaced by A' — SAME sequence, SAME content, different
      # record hash, because the source generation differs.
      assert {:ok, replacement} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 5,
                   source_generation: 43,
                   parent_hash: observed.checkpoint_hash
                 )
               )

      assert replacement.sequence == observed.sequence
      assert replacement.content == observed.content
      refute replacement.checkpoint_hash == observed.checkpoint_hash

      # A sequence-only fence would admit this; a record-hash fence must not.
      assert {:error, :checkpoint_parent_mismatch} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 6,
                   source_generation: 44,
                   parent_hash: observed.checkpoint_hash
                 )
               )

      assert {:ok, ^replacement} = Store.head(store, :calibration)
    end

    test "keeps each kind's chain independent", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, calibration} = Store.put(store, put_attrs())

      assert {:ok, polar} =
               Store.put(
                 store,
                 put_attrs(kind: :polar, schema_version: 2, content: content(:polar))
               )

      assert {:ok, wind} =
               Store.put(
                 store,
                 put_attrs(kind: :wind_shift, content: content(:wind_shift))
               )

      assert polar.parent_hash == Record.genesis_parent()
      assert wind.parent_hash == Record.genesis_parent()

      assert {:ok, ^calibration} = Store.head(store, :calibration)
      assert {:ok, ^polar} = Store.head(store, :polar)
      assert {:ok, ^wind} = Store.head(store, :wind_shift)

      # A calibration parent can never advance the polar chain.
      assert {:error, :checkpoint_parent_mismatch} =
               Store.put(
                 store,
                 put_attrs(
                   kind: :polar,
                   schema_version: 2,
                   content: content(:polar),
                   sequence: 2,
                   parent_hash: calibration.checkpoint_hash
                 )
               )
    end

    test "is idempotent for an exact replay of the current head", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())
      assert {:ok, ^first} = Store.put(store, put_attrs())
      assert {:ok, ^first} = Store.head(store, :calibration)
    end

    test "rejects a replay that collides on identity but differs in content", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())

      divergent = content(:calibration) |> Map.put("seq", 9)

      assert {:error, :checkpoint_parent_mismatch} =
               Store.put(store, put_attrs(content: divergent))
    end

    test "rejects malformed kinds, schemas, content, and secrets without touching the head",
         ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      chained = [sequence: 2, source_generation: 43, parent_hash: first.checkpoint_hash]

      assert {:error, :unknown_checkpoint_kind} =
               Store.put(store, put_attrs(chained ++ [kind: :telemetry]))

      assert {:error, :unsupported_checkpoint_schema} =
               Store.put(store, put_attrs(chained ++ [schema_version: 7]))

      assert {:error, :invalid_checkpoint_content} =
               Store.put(store, put_attrs(chained ++ [content: %{"seq" => 0}]))

      assert {:error, :checkpoint_secret_forbidden} =
               Store.put(
                 store,
                 put_attrs(chained ++ [content: content(:calibration) |> Map.put("wifi_psk", "hunter2")])
               )

      assert {:error, :invalid_delivery_sequence} =
               Store.put(store, put_attrs(chained ++ [sequence: 0]))

      assert {:ok, ^first} = Store.head(store, :calibration)
    end
  end

  describe "observe_target_head/2" do
    test "returns the exact absent, accepted, and local-unaccepted CAS observations", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      genesis = Record.genesis_parent()

      assert {:ok, %{state: :absent, checkpoint_hash: ^genesis}} =
               Store.observe_target_head(store, :calibration)

      assert {:ok, accepted} = Store.hydrate(store, hydrate_attrs())

      assert {:ok, %{state: :accepted, checkpoint_hash: accepted_hash}} =
               Store.observe_target_head(store, :calibration)

      assert accepted_hash == accepted.checkpoint_hash

      assert {:ok, local} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: accepted.checkpoint_hash
                 )
               )

      assert {:ok, %{state: :local_unaccepted, checkpoint_hash: local_hash}} =
               Store.observe_target_head(store, :calibration)

      assert local_hash == local.checkpoint_hash
    end

    test "classifies fenced and corrupt heads with the exact hashes accepted by hydrate/3", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, local} = Store.put(store, put_attrs())

      assert {:ok, rotated} = Store.new(opts(ctx, credential_epoch: @credential_epoch + 1))

      assert {:ok, %{state: :fenced, checkpoint_hash: fenced_hash} = fenced} =
               Store.observe_target_head(rotated, :calibration)

      assert fenced_hash == local.checkpoint_hash

      assert {:ok, rebound} =
               Store.hydrate(
                 rotated,
                 hydrate_attrs(
                   credential_epoch: @credential_epoch + 1,
                   sequence: local.sequence,
                   source_generation: local.source_generation,
                   parent_hash: local.parent_hash,
                   origin_credential_epoch: @credential_epoch,
                   origin_storage_epoch: @storage_epoch
                 ),
                 fenced
               )

      assert rebound.checkpoint_hash == local.checkpoint_hash

      corrupt = <<0xDE, 0xAD, 0xBE, 0xEF>>
      File.write!(Store.head_path(rotated, :calibration), corrupt)

      assert {:ok, %{state: :corrupt, checkpoint_hash: corrupt_hash} = corrupt_head} =
               Store.observe_target_head(rotated, :calibration)

      assert corrupt_hash == corrupt_head_hash(corrupt)

      assert {:ok, hydrated} =
               Store.hydrate(
                 rotated,
                 hydrate_attrs(
                   credential_epoch: @credential_epoch + 1,
                   sequence: rebound.sequence + 1,
                   source_generation: rebound.source_generation + 1,
                   parent_hash: rebound.checkpoint_hash
                 ),
                 corrupt_head
               )

      assert hydrated.accepted
    end

    test "fails closed for unknown kinds and stale current identity authority", ctx do
      {:ok, authority} = Agent.start_link(fn -> identity() end)
      identity_source = fn transition -> transition.(Agent.get(authority, & &1)) end
      assert {:ok, store} = Store.new(opts(ctx, identity: identity_source))

      assert {:error, :unknown_checkpoint_kind} = Store.observe_target_head(store, :telemetry)

      Agent.update(authority, &%{&1 | credential_epoch: @credential_epoch + 1})

      assert {:error, :credential_epoch_mismatch} =
               Store.observe_target_head(store, :calibration)
    end
  end

  describe "hydrate/2" do
    test "installs a backend-accepted record bound to the CURRENT identity", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:ok, hydrated} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   origin_credential_epoch: 3,
                   origin_storage_epoch: @other_storage_epoch
                 )
               )

      assert hydrated.accepted
      assert hydrated.local_credential_epoch == @credential_epoch
      assert hydrated.local_storage_epoch == @storage_epoch
      assert hydrated.origin_credential_epoch == 3
      assert hydrated.origin_storage_epoch == @other_storage_epoch

      assert {:ok, ^hydrated} = Store.head(store, :calibration)
    end

    test "a stale exact retry replays an older accepted ancestor behind local progress", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      expected_absent = %{state: :absent, checkpoint_hash: Record.genesis_parent()}
      assert {:ok, accepted_h1} = Store.hydrate(store, hydrate_attrs(), expected_absent)

      assert {:ok, accepted_h2} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: accepted_h1.checkpoint_hash
                 ),
                 %{state: :accepted, checkpoint_hash: accepted_h1.checkpoint_hash}
               )

      assert {:ok, local_h3} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 3,
                   source_generation: 44,
                   parent_hash: accepted_h2.checkpoint_hash
                 )
               )

      assert {:ok, ^local_h3} = Store.hydrate(store, hydrate_attrs(), expected_absent)
      assert {:ok, ^local_h3} = Store.head(store, :calibration)
    end

    test "expected-head CAS rejects an older accepted ancestor behind an accepted head", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, accepted_h1} = Store.hydrate(store, hydrate_attrs())

      assert {:ok, accepted_h2} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: accepted_h1.checkpoint_hash
                 )
               )

      observed = %{state: :accepted, checkpoint_hash: accepted_h2.checkpoint_hash}

      assert {:error, :checkpoint_hydration_rollback} =
               Store.hydrate(store, hydrate_attrs(), observed)

      assert {:ok, ^accepted_h2} = Store.head(store, :calibration)
    end

    test "installs under an exact absent-head CAS", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:ok, hydrated} =
               Store.hydrate(
                 store,
                 hydrate_attrs(),
                 %{state: :absent, checkpoint_hash: Record.genesis_parent()}
               )

      assert {:ok, ^hydrated} = Store.head(store, :calibration)
    end

    test "rejects malformed expected-head states before taking the lock", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:error, :invalid_expected_target_head} =
               Store.hydrate(
                 store,
                 hydrate_attrs(),
                 %{state: :accepted, checkpoint_hash: Record.genesis_parent()}
               )

      assert {:error, :invalid_expected_target_head} =
               Store.hydrate(
                 store,
                 hydrate_attrs(),
                 %{state: :unknown, checkpoint_hash: Record.genesis_parent()}
               )

      assert :empty = Store.head(store, :calibration)
    end

    test "classifies malformed checkpoint attributes independently of a valid expected head",
         ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      expected_absent = %{state: :absent, checkpoint_hash: Record.genesis_parent()}

      assert {:error, :invalid_checkpoint_record} =
               Store.hydrate(store, :not_a_checkpoint_record, expected_absent)

      assert :empty = Store.head(store, :calibration)
    end

    test "lets a later local record chain from the hydrated record hash", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:ok, hydrated} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   origin_credential_epoch: 3,
                   origin_storage_epoch: @other_storage_epoch
                 )
               )

      assert {:ok, next} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: hydrated.sequence + 1,
                   source_generation: 43,
                   parent_hash: hydrated.checkpoint_hash
                 )
               )

      refute next.accepted
      assert next.origin_credential_epoch == @credential_epoch
      assert next.origin_storage_epoch == @storage_epoch
      assert next.parent_hash == hydrated.checkpoint_hash
    end

    test "fails closed on divergent local state without an expected-head CAS", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, local} = Store.put(store, put_attrs(sequence: 9, source_generation: 99))

      assert {:error, :checkpoint_hydration_ambiguous} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   origin_credential_epoch: 3,
                   origin_storage_epoch: @other_storage_epoch
                 )
               )

      assert {:ok, ^local} = Store.head(store, :calibration)
    end

    test "replaces divergent local state only under an exact expected-head CAS", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, local} = Store.put(store, put_attrs(sequence: 9, source_generation: 99))

      backend =
        hydrate_attrs(
          origin_credential_epoch: 3,
          origin_storage_epoch: @other_storage_epoch
        )

      assert {:error, :expected_target_head_mismatch} =
               Store.hydrate(
                 store,
                 backend,
                 %{state: :absent, checkpoint_hash: Record.genesis_parent()}
               )

      assert {:ok, accepted} =
               Store.hydrate(
                 store,
                 backend,
                 %{state: :local_unaccepted, checkpoint_hash: local.checkpoint_hash}
               )

      assert accepted.accepted
      assert {:ok, ^accepted} = Store.head(store, :calibration)
    end

    test "verifies the presented record hash against the frozen preimage", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:error, :checkpoint_hash_mismatch} =
               Store.hydrate(
                 store,
                 hydrate_attrs(checkpoint_hash: :binary.copy(<<0xDD>>, 32))
               )

      assert :empty = Store.head(store, :calibration)
    end

    test "rejects hydration addressed to another device", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:error, :device_mismatch} =
               Store.hydrate(store, hydrate_attrs(device_id: @other_device_id))

      assert :empty = Store.head(store, :calibration)
    end

    test "rejects hydration bound to a stale credential or storage identity", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:error, :credential_epoch_mismatch} =
               Store.hydrate(store, hydrate_attrs(credential_epoch: @credential_epoch - 1))

      assert {:error, :storage_epoch_mismatch} =
               Store.hydrate(store, hydrate_attrs(storage_epoch: @other_storage_epoch))

      assert :empty = Store.head(store, :calibration)
    end

    test "rejects secret-capable hydrated content", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      poisoned = content(:calibration) |> Map.put("credential", "x")

      # The secret screen must fire BEFORE the presented record hash is compared,
      # so a poisoned payload is never hashed even to reject it.
      assert {:error, :checkpoint_secret_forbidden} =
               Store.hydrate(
                 store,
                 hydrate_attrs(content: poisoned, checkpoint_hash: :binary.copy(<<0xAB>>, 32))
               )

      assert :empty = Store.head(store, :calibration)
    end

    test "preserves the accepted high-water through local progress", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:ok, accepted_h2} =
               Store.hydrate(store, hydrate_attrs(sequence: 2, source_generation: 43))

      assert {:ok, local_h3} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 3,
                   source_generation: 44,
                   parent_hash: accepted_h2.checkpoint_hash
                 )
               )

      assert {:ok, ^local_h3} =
               Store.hydrate(store, hydrate_attrs(sequence: 2, source_generation: 43))

      assert {:ok, ^local_h3} = Store.head(store, :calibration)
      assert %{accepted: 1} = Store.status(store)

      assert {:error, :checkpoint_hydration_rollback} =
               Store.hydrate(store, hydrate_attrs(sequence: 1, source_generation: 42))

      assert {:ok, ^local_h3} = Store.head(store, :calibration)
    end

    test "expected-head CAS cannot roll back an accepted watermark hidden behind local progress",
         ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:ok, accepted_h5} =
               Store.hydrate(store, hydrate_attrs(sequence: 5, source_generation: 50))

      assert {:ok, local_h6} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 6,
                   source_generation: 60,
                   parent_hash: accepted_h5.checkpoint_hash
                 )
               )

      assert {:ok, local_h7} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 7,
                   source_generation: 70,
                   parent_hash: local_h6.checkpoint_hash
                 )
               )

      observed = %{state: :local_unaccepted, checkpoint_hash: local_h7.checkpoint_hash}

      assert {:ok, ^local_h7} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   sequence: 6,
                   source_generation: 60,
                   parent_hash: accepted_h5.checkpoint_hash
                 )
               )

      assert {:error, :checkpoint_hydration_rollback} =
               Store.hydrate(store, hydrate_attrs(sequence: 5, source_generation: 50), observed)

      assert {:ok, ^local_h7} = Store.head(store, :calibration)
    end

    test "expected-head CAS cannot replace deliberately truncated history", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      omitted_parent = :binary.copy(<<0x44>>, 32)

      assert {:ok, accepted_h1} =
               Store.hydrate(store, hydrate_attrs(parent_hash: omitted_parent))

      assert {:ok, local_h2} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: accepted_h1.checkpoint_hash
                 )
               )

      expected = %{state: :local_unaccepted, checkpoint_hash: local_h2.checkpoint_hash}

      assert {:error, :checkpoint_hydration_ambiguous} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   sequence: 2,
                   source_generation: 44,
                   parent_hash: accepted_h1.checkpoint_hash
                 ),
                 expected
               )

      assert {:ok, ^local_h2} = Store.head(store, :calibration)
    end

    test "accepts the current local parent even when the accepted watermark is multiple hops behind",
         ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, accepted_h1} = Store.hydrate(store, hydrate_attrs())

      assert {:ok, local_h2} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: accepted_h1.checkpoint_hash
                 )
               )

      assert {:ok, local_h3} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 3,
                   source_generation: 44,
                   parent_hash: local_h2.checkpoint_hash
                 )
               )

      assert {:ok, local_h4} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 4,
                   source_generation: 45,
                   parent_hash: local_h3.checkpoint_hash
                 )
               )

      assert {:ok, ^local_h4} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   sequence: 3,
                   source_generation: 44,
                   parent_hash: local_h2.checkpoint_hash
                 )
               )

      assert {:ok, ^local_h4} = Store.head(store, :calibration)
      assert %{accepted: 1} = Store.status(store)
    end

    test "does not discard newer local progress for a delayed accepted ancestor", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:ok, accepted_h2} =
               Store.hydrate(store, hydrate_attrs(sequence: 2, source_generation: 43))

      assert {:ok, local_h3} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 3,
                   source_generation: 44,
                   parent_hash: accepted_h2.checkpoint_hash
                 )
               )

      assert {:ok, local_h4} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 4,
                   source_generation: 45,
                   parent_hash: local_h3.checkpoint_hash
                 )
               )

      assert {:ok, local_h5} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 5,
                   source_generation: 46,
                   parent_hash: local_h4.checkpoint_hash
                 )
               )

      assert {:ok, ^local_h5} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   sequence: 3,
                   source_generation: 44,
                   parent_hash: accepted_h2.checkpoint_hash
                 )
               )

      assert {:ok, ^local_h5} = Store.head(store, :calibration)
      assert %{accepted: 1} = Store.status(store)
    end

    test "accepts a same-sequence successor when record-hash ancestry proves it", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:ok, accepted_a} =
               Store.hydrate(store, hydrate_attrs(sequence: 5, source_generation: 42))

      assert {:ok, accepted_b} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   sequence: 5,
                   source_generation: 43,
                   parent_hash: accepted_a.checkpoint_hash
                 )
               )

      assert accepted_b.parent_hash == accepted_a.checkpoint_hash
      assert {:ok, ^accepted_b} = Store.head(store, :calibration)
    end

    test "rejects a higher-sequence accepted record without proven record-hash ancestry", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, accepted_h1} = Store.hydrate(store, hydrate_attrs())

      assert {:ok, accepted_h2} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: accepted_h1.checkpoint_hash
                 )
               )

      assert {:error, :checkpoint_hydration_ambiguous} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   sequence: 3,
                   source_generation: 44,
                   parent_hash: accepted_h1.checkpoint_hash
                 )
               )

      assert {:ok, ^accepted_h2} = Store.head(store, :calibration)
    end

    test "orders an origin reset by record-hash ancestry rather than sequence", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      old_origin =
        hydrate_attrs(
          origin_credential_epoch: 3,
          origin_storage_epoch: @other_storage_epoch,
          sequence: 100,
          source_generation: 100
        )

      assert {:ok, old_h100} = Store.hydrate(store, old_origin)

      new_origin =
        hydrate_attrs(
          sequence: 1,
          source_generation: 101,
          parent_hash: old_h100.checkpoint_hash
        )

      assert {:ok, new_h1} = Store.hydrate(store, new_origin)
      assert new_h1.sequence == 1

      assert {:error, :checkpoint_hydration_rollback} = Store.hydrate(store, old_origin)
      assert {:ok, ^new_h1} = Store.head(store, :calibration)
    end

    test "does not let a stale identity handle overwrite a newer fenced head", ctx do
      {:ok, authority} = Agent.start_link(fn -> identity() end)
      identity_source = fn transition -> transition.(Agent.get(authority, & &1)) end

      assert {:ok, old_store} = Store.new(opts(ctx, identity: identity_source))

      assert {:ok, old_h100} =
               Store.hydrate(
                 old_store,
                 hydrate_attrs(
                   origin_credential_epoch: 3,
                   origin_storage_epoch: @other_storage_epoch,
                   sequence: 100,
                   source_generation: 100
                 )
               )

      Agent.update(authority, &%{&1 | credential_epoch: @credential_epoch + 1})

      assert {:ok, current_store} =
               Store.new(
                 opts(ctx,
                   credential_epoch: @credential_epoch + 1,
                   identity: identity_source
                 )
               )

      current_attrs =
        hydrate_attrs(
          credential_epoch: @credential_epoch + 1,
          origin_credential_epoch: @credential_epoch + 1,
          sequence: 1,
          source_generation: 101,
          parent_hash: old_h100.checkpoint_hash
        )

      assert {:ok, current_h1} = Store.hydrate(current_store, current_attrs)

      assert {:error, :credential_epoch_mismatch} =
               Store.hydrate(
                 old_store,
                 hydrate_attrs(
                   origin_credential_epoch: 3,
                   origin_storage_epoch: @other_storage_epoch,
                   sequence: 100,
                   source_generation: 100
                 )
               )

      assert {:ok, ^current_h1} = Store.head(current_store, :calibration)
    end

    test "does not replace intact state when a head read fails transiently", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, accepted_h10} = Store.hydrate(store, hydrate_attrs(sequence: 10))

      :persistent_term.put(
        TransientLstatFileSystem,
        {self(), "calibration.head", {:error, :eio}}
      )

      on_exit(fn ->
        :persistent_term.erase(TransientLstatFileSystem)
      end)

      assert {:ok, failing_store} =
               Store.new(opts(ctx, file_system: TransientLstatFileSystem))

      assert {:error, {:checkpoint_head_io, :eio}} =
               Store.hydrate(failing_store, hydrate_attrs(sequence: 9))

      assert_receive {:checkpoint_head_lstat, _canonical_path}
      assert %{unavailable: 1, corrupt: 0, fenced: 0} = Store.status(failing_store)
      assert {:ok, ^accepted_h10} = Store.head(store, :calibration)
    end

    test "treats malformed filesystem responses as unavailable, not corruption", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, accepted_h10} = Store.hydrate(store, hydrate_attrs(sequence: 10))

      :persistent_term.put(TransientLstatFileSystem, {self(), "calibration.head", :bogus})

      on_exit(fn ->
        :persistent_term.erase(TransientLstatFileSystem)
      end)

      assert {:ok, failing_store} =
               Store.new(opts(ctx, file_system: TransientLstatFileSystem))

      assert {:error, {:checkpoint_head_io, :invalid_lstat_response}} =
               Store.hydrate(failing_store, hydrate_attrs(sequence: 9))

      assert_receive {:checkpoint_head_lstat, _canonical_path}
      assert %{unavailable: 1, corrupt: 0} = Store.status(failing_store)
      assert {:ok, ^accepted_h10} = Store.head(store, :calibration)
    end
  end

  describe "identity fencing on reopen" do
    test "fails closed and preserves bytes when the persisted device differs", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, foreign} = Store.new(opts(ctx, device_id: @other_device_id))
      assert {:error, :device_mismatch} = Store.head(foreign, :calibration)
      assert {:error, :device_mismatch} = Store.put(foreign, put_attrs())

      assert {:ok, ^first} = Store.head(store, :calibration)
    end

    test "fails closed when the persisted local credential epoch is stale", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, rotated} = Store.new(opts(ctx, credential_epoch: @credential_epoch + 1))
      assert {:error, :credential_epoch_mismatch} = Store.head(rotated, :calibration)

      assert {:error, :credential_epoch_mismatch} =
               Store.put(rotated, put_attrs(parent_hash: first.checkpoint_hash))

      assert {:ok, ^first} = Store.head(store, :calibration)
    end

    test "fails closed when the persisted storage epoch differs", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, replaced} = Store.new(opts(ctx, storage_epoch: @other_storage_epoch))
      assert {:error, :storage_epoch_mismatch} = Store.head(replaced, :calibration)
      assert {:ok, ^first} = Store.head(store, :calibration)
    end

    test "rebinds preserved local progress to the current recovered identity", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, local_h1} = Store.put(store, put_attrs())

      assert {:ok, local_h2} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: local_h1.checkpoint_hash
                 )
               )

      recovered_epoch = @credential_epoch + 1

      assert {:ok, recovered_store} =
               Store.new(
                 opts(ctx,
                   credential_epoch: recovered_epoch,
                   storage_epoch: @other_storage_epoch
                 )
               )

      assert {:error, :credential_epoch_mismatch} =
               Store.head(recovered_store, :calibration)

      assert {:ok, rebound_h2} =
               Store.hydrate(
                 recovered_store,
                 hydrate_attrs(
                   credential_epoch: recovered_epoch,
                   storage_epoch: @other_storage_epoch,
                   sequence: 1,
                   source_generation: 42
                 )
               )

      assert rebound_h2.checkpoint_hash == local_h2.checkpoint_hash
      assert rebound_h2.local_credential_epoch == recovered_epoch
      assert rebound_h2.local_storage_epoch == @other_storage_epoch
      assert rebound_h2.origin_credential_epoch == local_h2.origin_credential_epoch
      assert rebound_h2.origin_storage_epoch == local_h2.origin_storage_epoch
      assert {:ok, ^rebound_h2} = Store.head(recovered_store, :calibration)
    end

    test "does not treat a stale expected head as credential-recovery authority", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, accepted} = Store.hydrate(store, hydrate_attrs())
      recovered_epoch = @credential_epoch + 1
      assert {:ok, recovered_store} = Store.new(opts(ctx, credential_epoch: recovered_epoch))

      recovered_attrs = hydrate_attrs(credential_epoch: recovered_epoch)
      expected_absent = %{state: :absent, checkpoint_hash: Record.genesis_parent()}

      assert {:error, :expected_target_head_mismatch} =
               Store.hydrate(recovered_store, recovered_attrs, expected_absent)

      assert {:error, :credential_epoch_mismatch} =
               Store.head(recovered_store, :calibration)

      expected_fenced = %{state: :fenced, checkpoint_hash: accepted.checkpoint_hash}
      assert {:ok, rebound} = Store.hydrate(recovered_store, recovered_attrs, expected_fenced)
      assert rebound.checkpoint_hash == accepted.checkpoint_hash
      assert rebound.local_credential_epoch == recovered_epoch
    end

    test "does not treat a stale expected head as descendant-retry recovery authority", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, accepted} = Store.hydrate(store, hydrate_attrs())

      assert {:ok, local} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: accepted.checkpoint_hash
                 )
               )

      recovered_epoch = @credential_epoch + 1
      assert {:ok, recovered_store} = Store.new(opts(ctx, credential_epoch: recovered_epoch))

      assert {:error, :expected_target_head_mismatch} =
               Store.hydrate(
                 recovered_store,
                 hydrate_attrs(credential_epoch: recovered_epoch),
                 %{state: :absent, checkpoint_hash: Record.genesis_parent()}
               )

      assert {:error, :credential_epoch_mismatch} =
               Store.head(recovered_store, :calibration)

      assert local.checkpoint_hash != accepted.checkpoint_hash
    end

    test "lets hydration rebind a fenced head to the new identity", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, rotated} = Store.new(opts(ctx, credential_epoch: @credential_epoch + 1))
      assert {:error, :credential_epoch_mismatch} = Store.head(rotated, :calibration)

      assert {:ok, hydrated} =
               Store.hydrate(
                 rotated,
                 hydrate_attrs(
                   credential_epoch: @credential_epoch + 1,
                   sequence: first.sequence,
                   source_generation: first.source_generation,
                   parent_hash: first.parent_hash,
                   origin_credential_epoch: @credential_epoch,
                   origin_storage_epoch: @storage_epoch
                 )
               )

      assert hydrated.checkpoint_hash == first.checkpoint_hash
      assert {:ok, ^hydrated} = Store.head(rotated, :calibration)
    end

    test "lets hydration rebind a fenced head after storage replacement", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, replaced} = Store.new(opts(ctx, storage_epoch: @other_storage_epoch))
      assert {:error, :storage_epoch_mismatch} = Store.head(replaced, :calibration)

      assert {:ok, hydrated} =
               Store.hydrate(
                 replaced,
                 hydrate_attrs(
                   storage_epoch: @other_storage_epoch,
                   sequence: first.sequence,
                   source_generation: first.source_generation,
                   parent_hash: first.parent_hash,
                   origin_credential_epoch: @credential_epoch,
                   origin_storage_epoch: @storage_epoch
                 )
               )

      assert hydrated.checkpoint_hash == first.checkpoint_hash
      assert hydrated.local_storage_epoch == @other_storage_epoch
      assert {:ok, ^hydrated} = Store.head(replaced, :calibration)
    end

    test "reopening under the same identity restores the exact head", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, reopened} = Store.new(opts(ctx))
      assert {:ok, ^first} = Store.head(reopened, :calibration)
    end

    test "fails closed when a legacy local record has no provable accepted watermark", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:ok, legacy} =
               Record.build(%{
                 device_id: @device_id,
                 local_credential_epoch: @credential_epoch,
                 local_storage_epoch: @storage_epoch,
                 origin_credential_epoch: @credential_epoch,
                 origin_storage_epoch: @storage_epoch,
                 sequence: 9,
                 kind: :calibration,
                 schema_version: 1,
                 source_generation: 99,
                 parent_hash: Record.genesis_parent(),
                 content: content(:calibration),
                 accepted: false
               })

      assert {:ok, legacy_bytes} = Record.encode(legacy)
      path = Store.head_path(store, :calibration)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, legacy_bytes)

      assert {:ok, ^legacy} = Store.head(store, :calibration)

      assert {:error, :checkpoint_hydration_ambiguous} =
               Store.hydrate(store, hydrate_attrs(sequence: 10, source_generation: 100))

      assert {:ok, ^legacy} = Store.head(store, :calibration)

      assert {:error, :checkpoint_hydration_ambiguous} =
               Store.hydrate(
                 store,
                 hydrate_attrs(sequence: 10, source_generation: 100),
                 %{state: :local_unaccepted, checkpoint_hash: legacy.checkpoint_hash}
               )

      assert {:ok, ^legacy} = Store.head(store, :calibration)
    end

    test "preserves a legacy local descendant when hydration proves its direct parent", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:ok, accepted_parent} =
               Record.build(%{
                 device_id: @device_id,
                 local_credential_epoch: @credential_epoch,
                 local_storage_epoch: @storage_epoch,
                 origin_credential_epoch: @credential_epoch,
                 origin_storage_epoch: @storage_epoch,
                 sequence: 8,
                 kind: :calibration,
                 schema_version: 1,
                 source_generation: 80,
                 parent_hash: Record.genesis_parent(),
                 content: content(:calibration),
                 accepted: true
               })

      assert {:ok, legacy_local} =
               Record.build(%{
                 device_id: @device_id,
                 local_credential_epoch: @credential_epoch,
                 local_storage_epoch: @storage_epoch,
                 origin_credential_epoch: @credential_epoch,
                 origin_storage_epoch: @storage_epoch,
                 sequence: 9,
                 kind: :calibration,
                 schema_version: 1,
                 source_generation: 90,
                 parent_hash: accepted_parent.checkpoint_hash,
                 content: content(:calibration),
                 accepted: false
               })

      assert {:ok, legacy_bytes} = Record.encode(legacy_local)
      path = Store.head_path(store, :calibration)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, legacy_bytes)

      expected = %{state: :local_unaccepted, checkpoint_hash: legacy_local.checkpoint_hash}

      assert {:ok, ^legacy_local} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   sequence: accepted_parent.sequence,
                   source_generation: accepted_parent.source_generation,
                   parent_hash: accepted_parent.parent_hash
                 ),
                 expected
               )

      assert {:ok, ^legacy_local} = Store.head(store, :calibration)
      assert %{accepted: 1} = Store.status(store)
    end

    test "does not erase an unproven legacy accepted watermark", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      assert {:ok, accepted} =
               Record.build(%{
                 device_id: @device_id,
                 local_credential_epoch: @credential_epoch,
                 local_storage_epoch: @storage_epoch,
                 origin_credential_epoch: @credential_epoch,
                 origin_storage_epoch: @storage_epoch,
                 sequence: 2,
                 kind: :calibration,
                 schema_version: 1,
                 source_generation: 42,
                 parent_hash: Record.genesis_parent(),
                 content: content(:calibration),
                 accepted: true
               })

      assert {:ok, legacy_watermark} = Snapshot.record_summary(accepted)

      assert {:ok, local_fork} =
               Record.build(%{
                 device_id: @device_id,
                 local_credential_epoch: @credential_epoch,
                 local_storage_epoch: @storage_epoch,
                 origin_credential_epoch: @credential_epoch,
                 origin_storage_epoch: @storage_epoch,
                 sequence: 3,
                 kind: :calibration,
                 schema_version: 1,
                 source_generation: 43,
                 parent_hash: Record.genesis_parent(),
                 content: content(:calibration),
                 accepted: false
               })

      path = Store.head_path(store, :calibration)
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        legacy_snapshot_bytes(%{current: local_fork, last_accepted: legacy_watermark})
      )

      assert {:error, :checkpoint_hydration_ambiguous} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   sequence: local_fork.sequence,
                   source_generation: local_fork.source_generation + 1,
                   parent_hash: local_fork.parent_hash
                 )
               )

      assert {:ok, ^local_fork} = Store.head(store, :calibration)
      assert %{accepted: 0} = Store.status(store)
    end
  end

  describe "serialized mutations" do
    test "rejects a terminal head symlink instead of mutating its target", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      path = Store.head_path(store, :calibration)
      target = Path.join([ctx.base, "outside", "checkpoint_heads", "calibration.head"])
      File.mkdir_p!(Path.dirname(target))
      File.rename!(path, target)
      target_bytes = File.read!(target)
      File.ln_s!(target, path)

      assert {:error, :corrupt_checkpoint_head} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: first.checkpoint_hash
                 )
               )

      assert File.read!(target) == target_bytes
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(path)
    end

    test "revalidates the original head path if authority retargets its alias", ctx do
      real_base = Path.join(ctx.base, "real")
      other_base = Path.join(ctx.base, "other")
      alias_base = Path.join(ctx.base, "alias")
      File.mkdir_p!(real_base)
      File.mkdir_p!(other_base)
      File.ln_s!(real_base, alias_base)

      assert {:ok, store} = Store.new(opts(%{ctx | base: alias_base}))

      retargeting_authority = fn transition ->
        File.rm!(alias_base)
        File.ln_s!(other_base, alias_base)
        transition.(identity())
      end

      retargeted_store = %{store | identity_source: retargeting_authority}
      assert {:ok, installed} = Store.put(retargeted_store, put_attrs())

      real_path = Path.join([real_base, "checkpoint_heads", "calibration.head"])
      other_path = Path.join([other_base, "checkpoint_heads", "calibration.head"])
      refute File.exists?(real_path)
      assert File.exists?(other_path)
      assert {:ok, ^installed} = Store.head(retargeted_store, :calibration)
    end

    test "resolves configured dot segments after preceding symlink components", ctx do
      container = Path.join(ctx.base, "configured-container")
      local_state = Path.join(container, "state")
      outside = Path.join(ctx.base, "configured-outside")
      outside_child = Path.join(outside, "child")
      outside_state = Path.join(outside, "state")
      gate = Path.join(container, "gate")

      File.mkdir_p!(local_state)
      File.mkdir_p!(outside_child)
      File.mkdir_p!(outside_state)
      File.ln_s!(outside_child, gate)

      configured_base = Path.join([container, "gate", "..", "state"])
      assert {:ok, store} = Store.new(opts(%{ctx | base: configured_base}))
      assert {:ok, installed} = Store.put(store, put_attrs())

      outside_path = Path.join([outside_state, "checkpoint_heads", "calibration.head"])
      local_path = Path.join([local_state, "checkpoint_heads", "calibration.head"])
      assert File.exists?(outside_path)
      refute File.exists?(local_path)
      assert {:ok, ^installed} = Store.head(%{store | base_dir: outside_state}, :calibration)
    end

    test "resolves dot segments only after preceding symlink components", ctx do
      container = Path.join(ctx.base, "container")
      local_state = Path.join(container, "state")
      outside = Path.join(ctx.base, "outside")
      outside_child = Path.join(outside, "child")
      outside_state = Path.join(outside, "state")
      alias_base = Path.join(container, "alias")

      File.mkdir_p!(local_state)
      File.mkdir_p!(outside_child)
      File.mkdir_p!(outside_state)
      File.ln_s!(outside_child, Path.join(container, "gate"))
      File.ln_s!("gate/../state", alias_base)

      assert {:ok, store} = Store.new(opts(%{ctx | base: alias_base}))
      assert {:ok, installed} = Store.put(store, put_attrs())

      outside_path = Path.join([outside_state, "checkpoint_heads", "calibration.head"])
      local_path = Path.join([local_state, "checkpoint_heads", "calibration.head"])
      assert File.exists?(outside_path)
      refute File.exists?(local_path)
      assert {:ok, ^installed} = Store.head(%{store | base_dir: outside_state}, :calibration)
    end

    test "normalizes dot segments remaining after a missing symlink target component", ctx do
      container = Path.join(ctx.base, "missing-container")
      alias_base = Path.join(container, "alias")
      expected_base = Path.join([container, "missing", "state"])

      File.mkdir_p!(container)
      File.ln_s!("missing/sub/../state", alias_base)

      assert {:ok, store} = Store.new(opts(%{ctx | base: alias_base}))
      assert {:ok, installed} = Store.put(store, put_attrs())

      expected_path = Path.join([expected_base, "checkpoint_heads", "calibration.head"])
      assert File.exists?(expected_path)
      assert {:ok, ^installed} = Store.head(%{store | base_dir: expected_base}, :calibration)
    end

    test "accepts exactly the configured symlink traversal limit", ctx do
      File.mkdir_p!(ctx.base)
      physical_base = File.cd!(ctx.base, fn -> File.cwd!() end)
      target_base = Path.join(physical_base, "symlink-limit-target")
      File.mkdir_p!(target_base)

      links =
        for index <- 1..32 do
          Path.join(physical_base, "symlink-limit-#{index}")
        end

      Enum.zip(links, tl(links) ++ [target_base])
      |> Enum.each(fn {link, target} -> File.ln_s!(target, link) end)

      assert {:ok, store} = Store.new(opts(%{ctx | base: hd(links)}))
      assert {:ok, installed} = Store.put(store, put_attrs())
      assert {:ok, ^installed} = Store.head(%{store | base_dir: target_base}, :calibration)
    end

    test "requires canonicalization callbacks from one filesystem namespace", ctx do
      assert {:ok, store} = Store.new(opts(ctx, file_system: NoReadLinkFileSystem))

      assert {:error, {:checkpoint_head_path, :read_link_unsupported}} =
               Store.put(store, put_attrs())

      refute File.exists?(Store.head_path(store, :calibration))
    end

    test "preserves a completed transition result when authority teardown fails", ctx do
      assert {:ok, store} = Store.new(opts(ctx))

      teardown_failure = fn transition ->
        _result = transition.(identity())
        raise "simulated authority release failure"
      end

      faulted_store = %{store | identity_source: teardown_failure}
      assert {:ok, installed} = Store.put(faulted_store, put_attrs())
      assert {:ok, ^installed} = Store.head(store, :calibration)
    end

    test "relocks when the captured canonical ancestor is retargeted", ctx do
      original_base = Path.join(ctx.base, "original")
      moved_base = Path.join(ctx.base, "moved")
      other_base = Path.join(ctx.base, "other")
      File.mkdir_p!(original_base)
      File.mkdir_p!(other_base)
      test_pid = self()

      assert {:ok, original_store} = Store.new(opts(%{ctx | base: original_base}))

      assert {:ok, other_store} =
               Store.new(
                 opts(%{ctx | base: other_base},
                   fault_injector: fn
                     :before_rename ->
                       send(test_pid, {:other_writer_reached_rename, self()})

                       receive do
                         :release_other_writer -> :ok
                       end

                     _stage ->
                       :ok
                   end
                 )
               )

      other_writer =
        Task.async(fn ->
          Store.put(other_store, put_attrs(source_generation: 43))
        end)

      assert_receive {:other_writer_reached_rename, other_writer_callback}, 2_000

      retargeting_authority = fn transition ->
        File.rename!(original_base, moved_base)
        File.ln_s!(other_base, original_base)
        transition.(identity())
      end

      retargeted_store = %{original_store | identity_source: retargeting_authority}
      assert {:error, :checkpoint_head_lock_timeout} = Store.put(retargeted_store, put_attrs())

      send(other_writer_callback, :release_other_writer)
      assert {:ok, installed} = Task.await(other_writer, 2_000)
      assert installed.source_generation == 43
      assert {:ok, ^installed} = Store.head(other_store, :calibration)
    end

    test "serializes pathname aliases under one canonical destination owner", ctx do
      real_base = Path.join(ctx.base, "real")
      alias_base = Path.join(ctx.base, "alias")
      File.mkdir_p!(real_base)
      File.ln_s!(real_base, alias_base)
      test_pid = self()

      assert {:ok, real_store} =
               Store.new(
                 opts(%{ctx | base: real_base},
                   fault_injector: fn
                     :before_rename ->
                       send(test_pid, {:first_checkpoint_writer_reached_rename, self()})

                       receive do
                         :release_first_checkpoint_writer -> :ok
                       end

                     _stage ->
                       :ok
                   end
                 )
               )

      assert {:ok, alias_store} =
               Store.new(opts(%{ctx | base: alias_base}, device_id: @other_device_id))

      first = Task.async(fn -> Store.put(real_store, put_attrs()) end)
      assert_receive {:first_checkpoint_writer_reached_rename, first_callback}, 2_000

      second =
        Task.async(fn ->
          send(test_pid, :second_checkpoint_writer_started)
          Store.put(alias_store, put_attrs())
        end)

      assert_receive :second_checkpoint_writer_started
      assert {:error, :checkpoint_head_lock_timeout} = Task.await(second, 2_000)

      send(first_callback, :release_first_checkpoint_writer)
      assert {:ok, installed} = Task.await(first, 2_000)
      assert {:ok, ^installed} = Store.head(real_store, :calibration)
      assert {:error, :device_mismatch} = Store.head(alias_store, :calibration)
    end

    test "does not split ownership when a concurrent directory preparer fails", ctx do
      chmod_counter = :atomics.new(1, signed: false)
      list_counter = :atomics.new(1, signed: false)

      :persistent_term.put(
        DirectoryPreparationRaceFileSystem,
        {self(), chmod_counter, list_counter}
      )

      on_exit(fn -> :persistent_term.erase(DirectoryPreparationRaceFileSystem) end)

      assert {:ok, creator_store} =
               Store.new(opts(ctx, file_system: DirectoryPreparationRaceFileSystem))

      assert {:ok, first_store} =
               Store.new(opts(ctx, file_system: DirectoryPreparationRaceFileSystem))

      assert {:ok, second_store} =
               Store.new(opts(ctx, file_system: DirectoryPreparationRaceFileSystem))

      creator = Task.async(fn -> Store.put(creator_store, put_attrs()) end)

      assert_receive {:checkpoint_lock_directory_chmod_blocked, creator_callback, _path},
                     2_000

      first = Task.async(fn -> Store.put(first_store, put_attrs()) end)
      assert_receive {:checkpoint_old_inode_writer_blocked, first_callback, _path}, 2_000

      send(creator_callback, :release_checkpoint_lock_directory_chmod)

      assert {:error, {:checkpoint_head_path, {:directory_prepare, _reason}}} =
               Task.await(creator, 2_000)

      assert {:error, :checkpoint_head_lock_timeout} =
               Task.async(fn -> Store.put(second_store, put_attrs(source_generation: 43)) end)
               |> Task.await(2_000)

      send(first_callback, :release_checkpoint_old_inode_writer)
      assert {:ok, installed} = Task.await(first, 2_000)
      assert {:ok, ^installed} = Store.head(first_store, :calibration)
    end

    test "serializes case-equivalent destination aliases when the filesystem does", ctx do
      actual_base = Path.join(ctx.base, "CaseEquivalentState")
      alias_base = Path.join(ctx.base, "caseequivalentstate")
      File.mkdir_p!(actual_base)

      if File.exists?(alias_base) do
        test_pid = self()

        assert {:ok, actual_store} =
                 Store.new(
                   opts(%{ctx | base: actual_base},
                     fault_injector: fn
                       :before_rename ->
                         send(test_pid, {:case_alias_first_reached_rename, self()})

                         receive do
                           :release_case_alias_first -> :ok
                         end

                       _stage ->
                         :ok
                     end
                   )
                 )

        assert {:ok, alias_store} = Store.new(opts(%{ctx | base: alias_base}))
        first = Task.async(fn -> Store.put(actual_store, put_attrs()) end)
        assert_receive {:case_alias_first_reached_rename, first_callback}, 2_000

        assert {:error, :checkpoint_head_lock_timeout} =
                 Task.async(fn ->
                   Store.put(alias_store, put_attrs(source_generation: 43))
                 end)
                 |> Task.await(2_000)

        send(first_callback, :release_case_alias_first)
        assert {:ok, installed} = Task.await(first, 2_000)
        assert {:ok, ^installed} = Store.head(alias_store, :calibration)
      end
    end

    test "keeps case-distinct destinations independent when the filesystem does", ctx do
      actual_base = Path.join(ctx.base, "CaseDistinctState")
      other_base = Path.join(ctx.base, "casedistinctstate")
      File.mkdir_p!(actual_base)

      unless File.exists?(other_base) do
        File.mkdir_p!(other_base)
        test_pid = self()

        assert {:ok, actual_store} =
                 Store.new(
                   opts(%{ctx | base: actual_base},
                     fault_injector: fn
                       :before_rename ->
                         send(test_pid, {:case_distinct_first_reached_rename, self()})

                         receive do
                           :release_case_distinct_first -> :ok
                         end

                       _stage ->
                         :ok
                     end
                   )
                 )

        assert {:ok, other_store} =
                 Store.new(opts(%{ctx | base: other_base}, device_id: @other_device_id))

        first = Task.async(fn -> Store.put(actual_store, put_attrs()) end)
        assert_receive {:case_distinct_first_reached_rename, first_callback}, 2_000

        assert {:ok, second} = Store.put(other_store, put_attrs())
        assert second.device_id == @other_device_id

        send(first_callback, :release_case_distinct_first)
        assert {:ok, _installed} = Task.await(first, 2_000)
      end
    end

    test "serializes Unicode-equivalent destination aliases when the filesystem does", ctx do
      actual_base = Path.join(ctx.base, "Σ")
      alias_base = Path.join(ctx.base, "ς")
      File.mkdir_p!(actual_base)

      if File.exists?(alias_base) do
        test_pid = self()

        assert {:ok, actual_store} =
                 Store.new(
                   opts(%{ctx | base: actual_base},
                     fault_injector: fn
                       :before_rename ->
                         send(test_pid, {:unicode_alias_first_reached_rename, self()})

                         receive do
                           :release_unicode_alias_first -> :ok
                         end

                       _stage ->
                         :ok
                     end
                   )
                 )

        assert {:ok, alias_store} = Store.new(opts(%{ctx | base: alias_base}))
        first = Task.async(fn -> Store.put(actual_store, put_attrs()) end)
        assert_receive {:unicode_alias_first_reached_rename, first_callback}, 2_000

        assert {:error, :checkpoint_head_lock_timeout} =
                 Task.async(fn ->
                   Store.put(alias_store, put_attrs(source_generation: 43))
                 end)
                 |> Task.await(2_000)

        send(first_callback, :release_unicode_alias_first)
        assert {:ok, installed} = Task.await(first, 2_000)
        assert {:ok, ^installed} = Store.head(alias_store, :calibration)
      end
    end

    test "reuses one holder while waiting for a busy global lock", ctx do
      test_pid = self()

      assert {:ok, blocking_store} =
               Store.new(
                 opts(ctx,
                   fault_injector: fn
                     :before_rename ->
                       send(test_pid, {:busy_lock_owner_reached_rename, self()})

                       receive do
                         :release_busy_lock_owner -> :ok
                       end

                     _stage ->
                       :ok
                   end
                 )
               )

      assert {:ok, waiting_store} = Store.new(opts(ctx))
      owner = Task.async(fn -> Store.put(blocking_store, put_attrs()) end)
      assert_receive {:busy_lock_owner_reached_rename, busy_owner_callback}, 2_000

      waiter =
        spawn(fn ->
          receive do
            :begin_busy_lock_wait ->
              send(test_pid, {:busy_lock_wait_result, Store.put(waiting_store, put_attrs())})
          end
        end)

      waiter_monitor = Process.monitor(waiter)
      assert 1 == :erlang.trace(waiter, true, [:procs])
      send(waiter, :begin_busy_lock_wait)
      assert_receive {:trace, ^waiter, :spawn, path_worker, _spawned}, 2_000
      path_worker_monitor = Process.monitor(path_worker)
      assert_receive {:DOWN, ^path_worker_monitor, :process, ^path_worker, path_reason}, 2_000
      assert path_reason in [:normal, :noproc]
      assert_receive {:trace, ^waiter, :spawn, holder, _spawned}, 2_000
      holder_monitor = Process.monitor(holder)

      assert_receive {:busy_lock_wait_result, {:error, :checkpoint_head_lock_timeout}}, 2_000
      assert_receive {:DOWN, ^holder_monitor, :process, ^holder, holder_reason}, 2_000
      assert holder_reason in [:lock_timeout, :killed]
      assert_receive {:DOWN, ^waiter_monitor, :process, ^waiter, :normal}, 2_000
      refute_receive {:trace, ^waiter, :spawn, _replacement, _spawned}, 100

      send(busy_owner_callback, :release_busy_lock_owner)
      assert {:ok, _installed} = Task.await(owner, 2_000)
    end

    test "hands a contended destination to the existing waiting holder", ctx do
      test_pid = self()

      assert {:ok, first_store} =
               Store.new(
                 opts(ctx,
                   fault_injector: fn
                     :before_rename ->
                       send(test_pid, {:handoff_first_reached_rename, self()})

                       receive do
                         :release_handoff_first -> :ok
                       end

                     _stage ->
                       :ok
                   end
                 )
               )

      assert {:ok, second_store} = Store.new(opts(ctx))
      first = Task.async(fn -> Store.put(first_store, put_attrs()) end)
      assert_receive {:handoff_first_reached_rename, first_callback}, 2_000

      second =
        Task.async(fn ->
          receive do
            :begin_handoff_second -> Store.put(second_store, put_attrs())
          end
        end)

      assert 1 == :erlang.trace(second.pid, true, [:procs])
      :erlang.trace_pattern({:global, :set_lock, 3}, true, [:local])

      on_exit(fn ->
        :erlang.trace_pattern({:global, :set_lock, 3}, false, [:local])
      end)

      send(second.pid, :begin_handoff_second)

      assert_receive {:trace, second_pid, :spawn, path_worker, _spawned}
                     when second_pid == second.pid,
                     2_000

      path_worker_monitor = Process.monitor(path_worker)
      assert_receive {:DOWN, ^path_worker_monitor, :process, ^path_worker, _reason}, 2_000

      assert_receive {:trace, second_pid, :spawn, holder, _spawned} when second_pid == second.pid,
                     2_000

      assert 1 == :erlang.trace(holder, true, [:call])
      assert_receive {:trace, ^holder, :call, {:global, :set_lock, _arguments}}, 2_000
      assert Task.yield(second, 100) == nil
      send(first_callback, :release_handoff_first)

      assert {:ok, installed} = Task.await(first, 2_000)
      assert {:ok, ^installed} = Task.await(second, 2_000)
      assert {:ok, ^installed} = Store.head(second_store, :calibration)
    end

    test "bounds canonical path resolution through the injected filesystem", ctx do
      File.mkdir_p!(Path.join(ctx.base, "checkpoint_heads"))
      :persistent_term.put(BlockingLstatFileSystem, {self(), "checkpoint_heads"})

      on_exit(fn ->
        :persistent_term.erase(BlockingLstatFileSystem)
      end)

      assert {:ok, store} = Store.new(opts(ctx, file_system: BlockingLstatFileSystem))
      writer = Task.async(fn -> Store.put(store, put_attrs()) end)

      assert_receive {:checkpoint_head_lstat_blocked, _canonical_component}, 2_000
      assert_receive {:checkpoint_head_lstat_worker, worker}, 2_000
      worker_monitor = Process.monitor(worker)

      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 2_000
      assert {:ok, {:error, {:checkpoint_head_path, :timeout}}} = Task.yield(writer, 2_000)

      :persistent_term.erase(BlockingLstatFileSystem)
      assert {:ok, recovered_store} = Store.new(opts(ctx))
      assert {:ok, installed} = Store.put(recovered_store, put_attrs())
      assert {:ok, ^installed} = Store.head(recovered_store, :calibration)
      refute_temporary_artifacts(recovered_store, :calibration)
    end

    test "bounds the complete locked filesystem transition", ctx do
      :persistent_term.put(BlockingListDirFileSystem, self())

      on_exit(fn ->
        :persistent_term.erase(BlockingListDirFileSystem)
      end)

      assert {:ok, store} =
               Store.new(opts(ctx, file_system: BlockingListDirFileSystem, transition_timeout_ms: 5_000))

      bounded_store = Map.put(store, :transition_timeout_ms, 1_000)
      writer = Task.async(fn -> Store.put(bounded_store, put_attrs()) end)

      assert_receive {:checkpoint_head_list_dir_blocked, holder, _directory}, 2_000
      holder_monitor = Process.monitor(holder)
      on_exit(fn -> Process.exit(holder, :kill) end)

      assert {:ok, {:error, {:durability_uncertain, :checkpoint_head_transition_timeout}}} =
               Task.yield(writer, 2_000)

      assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :killed}, 2_000
      :persistent_term.erase(BlockingListDirFileSystem)
      assert :empty = Store.head(store, :calibration)
      assert {:ok, recovered_store} = Store.new(opts(ctx))
      assert {:ok, installed} = Store.put(recovered_store, put_attrs())
      assert {:ok, ^installed} = Store.head(recovered_store, :calibration)
    end

    test "bounds an identity authority that does not return after committing", ctx do
      assert {:ok, store} = Store.new(opts(ctx, transition_timeout_ms: 5_000))
      test_pid = self()

      hanging_authority = fn transition ->
        result = transition.(identity())
        send(test_pid, {:checkpoint_identity_authority_stalled, self()})

        receive do
          :release_checkpoint_identity_authority -> result
        end
      end

      bounded_store =
        store
        |> Map.put(:identity_source, hanging_authority)
        |> Map.put(:transition_timeout_ms, 1_000)

      writer = Task.async(fn -> Store.put(bounded_store, put_attrs()) end)
      assert_receive {:checkpoint_identity_authority_stalled, holder}, 2_000
      holder_monitor = Process.monitor(holder)
      on_exit(fn -> Process.exit(holder, :kill) end)

      assert {:ok, {:error, {:durability_uncertain, :checkpoint_head_transition_timeout}}} =
               Task.yield(writer, 2_000)

      assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :killed}, 2_000
      assert {:ok, installed} = Store.head(store, :calibration)
      assert {:ok, ^installed} = Store.put(store, put_attrs())
    end

    test "bounds a stalled global lock coordinator", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      global_name_server = Process.whereis(:global_name_server)
      assert is_pid(global_name_server)
      on_exit(fn -> :sys.resume(global_name_server) end)
      :ok = :sys.suspend(global_name_server)

      writer = Task.async(fn -> Store.put(store, put_attrs()) end)
      observed = Task.yield(writer, 2_000)
      :ok = :sys.resume(global_name_server)

      if observed == nil do
        _late_result = Task.await(writer, 2_000)
      end

      assert {:ok, {:error, :checkpoint_head_lock_timeout}} = observed
    end

    test "terminates a stalled global lock holder when its owner dies", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      global_name_server = Process.whereis(:global_name_server)
      assert is_pid(global_name_server)
      on_exit(fn -> :sys.resume(global_name_server) end)
      :ok = :sys.suspend(global_name_server)

      caller =
        spawn(fn ->
          receive do
            :begin_stalled_lock -> Store.put(store, put_attrs())
          end
        end)

      caller_monitor = Process.monitor(caller)
      assert 1 == :erlang.trace(caller, true, [:procs])
      send(caller, :begin_stalled_lock)
      assert_receive {:trace, ^caller, :spawn, path_worker, _spawned}, 2_000
      path_worker_monitor = Process.monitor(path_worker)
      assert_receive {:DOWN, ^path_worker_monitor, :process, ^path_worker, path_reason}, 2_000
      assert path_reason in [:normal, :noproc]
      assert_receive {:trace, ^caller, :spawn, holder, _spawned}, 2_000
      holder_monitor = Process.monitor(holder)

      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 2_000
      assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :killed}, 2_000

      :ok = :sys.resume(global_name_server)
      assert {:ok, installed} = Store.put(store, put_attrs())
      assert {:ok, ^installed} = Store.head(store, :calibration)
    end

    test "aborts a transition if its acquired lock holder dies", ctx do
      test_pid = self()

      assert {:ok, faulted_store} =
               Store.new(
                 opts(ctx,
                   fault_injector: fn
                     :before_rename ->
                       send(test_pid, {:checkpoint_lock_holder_reached_rename, self()})

                       receive do
                         :release_checkpoint_lock_holder -> :ok
                       end

                     _stage ->
                       :ok
                   end
                 )
               )

      writer =
        Task.async(fn ->
          receive do
            :begin_checkpoint_lock_holder -> Store.put(faulted_store, put_attrs())
          end
        end)

      send(writer.pid, :begin_checkpoint_lock_holder)
      assert_receive {:checkpoint_lock_holder_reached_rename, holder}, 2_000
      holder_monitor = Process.monitor(holder)

      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :killed}, 2_000

      assert {:error, {:durability_uncertain, :checkpoint_head_lock_lost}} =
               Task.await(writer, 2_000)

      assert :empty = Store.head(faulted_store, :calibration)

      assert {:ok, replacement_store} = Store.new(opts(ctx))
      assert {:ok, installed} = Store.put(replacement_store, put_attrs())
      assert {:ok, ^installed} = Store.head(replacement_store, :calibration)
    end

    test "bounds a stalled global lock release", ctx do
      global_name_server = Process.whereis(:global_name_server)
      assert is_pid(global_name_server)
      test_pid = self()
      on_exit(fn -> :sys.resume(global_name_server) end)

      assert {:ok, store} =
               Store.new(
                 opts(ctx,
                   fault_injector: fn
                     :before_rename ->
                       :ok = :sys.suspend(global_name_server)
                       send(test_pid, :global_lock_release_suspended)
                       {:error, :simulated_pre_rename_failure}

                     _stage ->
                       :ok
                   end
                 )
               )

      writer = Task.async(fn -> Store.put(store, put_attrs()) end)
      assert_receive :global_lock_release_suspended, 2_000

      assert {:ok, {:error, {:pre_rename, {:fault_injected, :before_rename, :simulated_pre_rename_failure}}}} =
               Task.yield(writer, 2_500)

      :ok = :sys.resume(global_name_server)
      assert {:ok, replacement_store} = Store.new(opts(ctx))
      assert {:ok, _installed} = Store.put(replacement_store, put_attrs())
    end

    test "serializes one canonical destination even across differently configured devices", ctx do
      test_pid = self()

      assert {:ok, first_store} =
               Store.new(
                 opts(ctx,
                   fault_injector: fn
                     :before_rename ->
                       send(test_pid, {:canonical_first_reached_rename, self()})

                       receive do
                         :release_canonical_first -> :ok
                       end

                     _stage ->
                       :ok
                   end
                 )
               )

      assert {:ok, second_store} = Store.new(opts(ctx, device_id: @other_device_id))
      first = Task.async(fn -> Store.put(first_store, put_attrs()) end)
      assert_receive {:canonical_first_reached_rename, canonical_first_callback}, 2_000

      assert {:error, :checkpoint_head_lock_timeout} =
               Task.async(fn -> Store.put(second_store, put_attrs()) end)
               |> Task.await(2_000)

      send(canonical_first_callback, :release_canonical_first)
      assert {:ok, _first} = Task.await(first, 2_000)
    end

    test "does not alias independent devices into one lock domain", ctx do
      first_ctx = %{ctx | base: Path.join(ctx.base, "first")}
      second_ctx = %{ctx | base: Path.join(ctx.base, "second")}
      test_pid = self()

      assert {:ok, first_store} =
               Store.new(
                 opts(first_ctx,
                   fault_injector: fn
                     :before_rename ->
                       send(test_pid, {:independent_first_reached_rename, self()})

                       receive do
                         :release_independent_first -> :ok
                       end

                     _stage ->
                       :ok
                   end
                 )
               )

      assert {:ok, second_store} = Store.new(opts(second_ctx, device_id: @other_device_id))
      first = Task.async(fn -> Store.put(first_store, put_attrs()) end)
      assert_receive {:independent_first_reached_rename, independent_first_callback}, 2_000

      assert {:ok, second} = Store.put(second_store, put_attrs())
      assert second.device_id == @other_device_id

      send(independent_first_callback, :release_independent_first)
      assert {:ok, _first} = Task.await(first)
    end

    test "holds the identity-authority lease through rename and parent sync", ctx do
      {:ok, authority} = start_supervised({IdentityAuthority, identity()})

      identity_authority = fn transition ->
        IdentityAuthority.with_lease(authority, transition)
      end

      test_pid = self()

      assert {:ok, stale_store} =
               Store.new(
                 opts(ctx,
                   identity: identity_authority,
                   fault_injector: fn
                     :before_rename ->
                       send(test_pid, {:checkpoint_writer_holds_authority, self()})

                       receive do
                         :release_checkpoint_writer -> :ok
                       end

                     :parent_synced ->
                       send(test_pid, :checkpoint_parent_synced)
                       :ok

                     _stage ->
                       :ok
                   end
                 )
               )

      writer = Task.async(fn -> Store.put(stale_store, put_attrs()) end)
      assert_receive {:checkpoint_writer_holds_authority, authority_callback}, 2_000

      rotated_identity = identity(%{credential_epoch: @credential_epoch + 1})

      rotation =
        Task.async(fn ->
          result = IdentityAuthority.rotate(authority, rotated_identity, test_pid)
          send(test_pid, {:checkpoint_identity_rotated, result})
          result
        end)

      assert_receive :checkpoint_identity_rotation_submitted, 2_000
      refute_receive {:checkpoint_identity_rotated, _result}, 100
      send(authority_callback, :release_checkpoint_writer)

      assert {:ok, installed} = Task.await(writer, 2_000)
      assert_receive :checkpoint_parent_synced, 2_000
      assert :ok = Task.await(rotation, 2_000)
      assert_receive {:checkpoint_identity_rotated, :ok}

      assert {:error, :credential_epoch_mismatch} =
               Store.put(
                 stale_store,
                 put_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: installed.checkpoint_hash
                 )
               )
    end

    test "scopes the locked transition path to its originating store", ctx do
      first_ctx = %{ctx | base: Path.join(ctx.base, "first")}
      second_ctx = %{ctx | base: Path.join(ctx.base, "second")}
      assert {:ok, second_store} = Store.new(opts(second_ctx))
      assert {:ok, second_head} = Store.put(second_store, put_attrs())
      test_pid = self()

      assert {:ok, first_store} =
               Store.new(
                 opts(first_ctx,
                   fault_injector: fn
                     :before_rename ->
                       send(test_pid, {
                         :other_store_during_transition,
                         Store.head(second_store, :calibration),
                         Store.status(second_store)
                       })

                       :ok

                     _stage ->
                       :ok
                   end
                 )
               )

      assert {:ok, _first_head} = Store.put(first_store, put_attrs())

      assert_receive {:other_store_during_transition, {:ok, ^second_head}, %{present: 1, unavailable: 0}}
    end

    test "rejects canonical-path callback reentry in its bounded worker", ctx do
      counter = :atomics.new(1, signed: false)

      assert {:ok, store} =
               Store.new(opts(ctx, file_system: ReentrantCanonicalFileSystem))

      :persistent_term.put(
        ReentrantCanonicalFileSystem,
        {self(), store, put_attrs(source_generation: 43), counter}
      )

      on_exit(fn -> :persistent_term.erase(ReentrantCanonicalFileSystem) end)

      assert {:ok, outer} = Store.put(store, put_attrs())

      assert_receive {:canonical_checkpoint_reentry, {:error, :checkpoint_head_reentrant_transition}},
                     2_000

      assert outer.source_generation == 42
      assert {:ok, ^outer} = Store.head(store, :calibration)
    end

    test "rejects locked read callback reentry in its bounded worker", ctx do
      counter = :atomics.new(1, signed: false)

      assert {:ok, store} = Store.new(opts(ctx, file_system: ReentrantReadFileSystem))

      nested_attrs =
        put_attrs(
          kind: :polar,
          schema_version: 2,
          content: content(:polar)
        )

      :persistent_term.put(ReentrantReadFileSystem, {self(), store, nested_attrs, counter})
      on_exit(fn -> :persistent_term.erase(ReentrantReadFileSystem) end)

      assert {:ok, outer} = Store.put(store, put_attrs())

      assert_receive {:read_checkpoint_reentry, {:error, :checkpoint_head_reentrant_transition}},
                     2_000

      assert {:ok, ^outer} = Store.head(store, :calibration)
      assert :empty = Store.head(store, :polar)
    end

    test "rejects same-process callback reentry", ctx do
      assert {:ok, plain_store} = Store.new(opts(ctx))
      test_pid = self()

      reentrant_store = %{
        plain_store
        | fault_injector: fn
            :before_rename ->
              send(test_pid, {:nested_checkpoint_write, Store.put(plain_store, put_attrs())})
              :ok

            _stage ->
              :ok
          end
      }

      assert {:ok, outer} = Store.put(reentrant_store, put_attrs())

      assert_receive {:nested_checkpoint_write, {:error, :checkpoint_head_reentrant_transition}}

      assert {:ok, ^outer} = Store.head(plain_store, :calibration)
    end
  end

  describe "corruption" do
    test "reports a corrupt head per kind without blocking the others", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _calibration} = Store.put(store, put_attrs())

      assert {:ok, polar} =
               Store.put(
                 store,
                 put_attrs(kind: :polar, schema_version: 2, content: content(:polar))
               )

      File.write!(Store.head_path(store, :calibration), <<0xDE, 0xAD, 0xBE, 0xEF>>)

      assert {:error, :corrupt_checkpoint_head} = Store.head(store, :calibration)
      assert {:ok, ^polar} = Store.head(store, :polar)
    end

    test "rejects a snapshot copied into another kind's head path", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, calibration} = Store.put(store, put_attrs())

      polar_path = Store.head_path(store, :polar)
      File.mkdir_p!(Path.dirname(polar_path))
      File.cp!(Store.head_path(store, :calibration), polar_path)

      assert {:error, :corrupt_checkpoint_head} = Store.head(store, :polar)
      assert {:ok, ^calibration} = Store.head(store, :calibration)
    end

    test "refuses to advance a corrupt chain rather than silently restarting it", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())
      File.write!(Store.head_path(store, :calibration), <<0>>)

      assert {:error, :corrupt_checkpoint_head} = Store.put(store, put_attrs())

      assert {:error, :corrupt_checkpoint_head} =
               Store.put(store, put_attrs(parent_hash: Record.genesis_parent()))
    end

    test "does not let legacy hydration erase an unreadable accepted watermark", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _accepted} = Store.hydrate(store, hydrate_attrs(sequence: 10))
      File.write!(Store.head_path(store, :calibration), <<0>>)

      assert {:error, :checkpoint_hydration_ambiguous} =
               Store.hydrate(store, hydrate_attrs(sequence: 9))

      assert {:error, :corrupt_checkpoint_head} = Store.head(store, :calibration)
    end

    test "replaces corrupt state only under an exact corrupt-state CAS", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _accepted} = Store.hydrate(store, hydrate_attrs(sequence: 10))
      path = Store.head_path(store, :calibration)
      first_corrupt = <<0>>
      second_corrupt = <<1>>
      File.write!(path, first_corrupt)
      first_expected = %{state: :corrupt, checkpoint_hash: corrupt_head_hash(first_corrupt)}
      File.write!(path, second_corrupt)

      assert {:error, :expected_target_head_mismatch} =
               Store.hydrate(store, hydrate_attrs(sequence: 9), first_expected)

      assert File.read!(path) == second_corrupt
      second_expected = %{state: :corrupt, checkpoint_hash: corrupt_head_hash(second_corrupt)}

      assert {:ok, replacement} =
               Store.hydrate(store, hydrate_attrs(sequence: 9), second_expected)

      assert replacement.sequence == 9
      assert {:ok, ^replacement} = Store.head(store, :calibration)
    end

    test "treats a truncated tail as corruption, never as an empty chain", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())

      path = Store.head_path(store, :calibration)
      bytes = File.read!(path)
      File.write!(path, binary_part(bytes, 0, byte_size(bytes) - 3))

      assert {:error, :corrupt_checkpoint_head} = Store.head(store, :calibration)
    end

    test "fails closed without a bounded descriptor-read adapter", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())

      path = Store.head_path(store, :calibration)
      :persistent_term.put({PathReadObserverFileSystem, path}, {self(), File.read(path)})

      on_exit(fn ->
        :persistent_term.erase({PathReadObserverFileSystem, path})
      end)

      assert {:ok, unsupported_store} =
               Store.new(opts(ctx, file_system: PathReadObserverFileSystem))

      assert {:error, :checkpoint_head_bounded_read_unsupported} =
               Store.head(unsupported_store, :calibration)

      refute_receive {:checkpoint_head_path_read, ^path}
    end

    test "reads through an adapter that omits write-only directory listing", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      assert {:ok, read_only_store} = Store.new(opts(ctx, file_system: BoundedReadFileSystem))
      assert {:ok, ^first} = Store.head(read_only_store, :calibration)
      assert %{present: 1, unavailable: 0} = Store.status(read_only_store)
    end

    test "retries a benign atomic rename between lstat and descriptor open", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())
      path = Store.head_path(store, :calibration)
      :persistent_term.put({RenameDuringOpenFileSystem, path}, self())

      on_exit(fn ->
        :persistent_term.erase({RenameDuringOpenFileSystem, path})
      end)

      assert {:ok, raced_store} = Store.new(opts(ctx, file_system: RenameDuringOpenFileSystem))
      reader = Task.async(fn -> Store.head(raced_store, :calibration) end)
      assert_receive {:checkpoint_head_initial_lstat, reader_pid, ^path}, 2_000

      assert {:ok, second} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: first.checkpoint_hash
                 )
               )

      send(reader_pid, :continue_checkpoint_head_open)
      assert {:ok, ^second} = Task.await(reader, 2_000)
    end

    test "classifies malformed descriptor metadata as unavailable rather than corrupt", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, accepted} = Store.hydrate(store, hydrate_attrs(sequence: 10))
      path = Store.head_path(store, :calibration)
      assert {:ok, stat} = File.stat(path)
      :persistent_term.put(MalformedFileInfoFileSystem, %{stat | size: :invalid})

      on_exit(fn ->
        :persistent_term.erase(MalformedFileInfoFileSystem)
      end)

      assert {:ok, malformed_store} =
               Store.new(opts(ctx, file_system: MalformedFileInfoFileSystem))

      assert {:error, {:checkpoint_head_io, :invalid_file_info_response}} =
               Store.head(malformed_store, :calibration)

      assert %{unavailable: 1, corrupt: 0} = Store.status(malformed_store)
      assert {:ok, ^accepted} = Store.head(store, :calibration)
    end

    test "times out pathname metadata that cannot complete", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())
      :persistent_term.put(BlockingLstatFileSystem, {self(), "calibration.head"})

      on_exit(fn ->
        :persistent_term.erase(BlockingLstatFileSystem)
      end)

      assert {:ok, blocking_store} =
               Store.new(opts(ctx, file_system: BlockingLstatFileSystem))

      reader = Task.async(fn -> Store.head(blocking_store, :calibration) end)
      assert_receive {:checkpoint_head_lstat_blocked, _canonical_path}, 2_000

      assert {:ok, {:error, {:checkpoint_head_io, :read_timeout}}} =
               Task.yield(reader, 2_000)
    end

    test "terminates a blocked read worker when its caller dies", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())
      :persistent_term.put(BlockingLstatFileSystem, {self(), "calibration.head"})

      on_exit(fn ->
        :persistent_term.erase(BlockingLstatFileSystem)
      end)

      assert {:ok, blocking_store} =
               Store.new(opts(ctx, file_system: BlockingLstatFileSystem))

      caller = spawn(fn -> Store.head(blocking_store, :calibration) end)
      caller_monitor = Process.monitor(caller)
      assert_receive {:checkpoint_head_lstat_blocked, _canonical_path}, 2_000
      assert_receive {:checkpoint_head_lstat_worker, worker}, 2_000
      worker_monitor = Process.monitor(worker)

      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 2_000
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 2_000
    end

    test "contains an untrappable read-worker exit", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())
      assert {:ok, killing_store} = Store.new(opts(ctx, file_system: KillingLstatFileSystem))

      assert {:error, {:checkpoint_head_io, :read_process_failed}} =
               Store.head(killing_store, :calibration)
    end

    test "times out a pathname open that cannot complete", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())
      :persistent_term.put(BlockingOpenFileSystem, {self(), "calibration.head"})

      on_exit(fn ->
        :persistent_term.erase(BlockingOpenFileSystem)
      end)

      assert {:ok, blocking_store} =
               Store.new(opts(ctx, file_system: BlockingOpenFileSystem))

      reader = Task.async(fn -> Store.head(blocking_store, :calibration) end)
      assert_receive {:checkpoint_head_open_blocked, _canonical_path}, 2_000

      assert {:ok, {:error, {:checkpoint_head_io, :read_timeout}}} =
               Task.yield(reader, 2_000)
    end

    test "classifies premature descriptor EOF as unavailable", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, accepted} = Store.hydrate(store, hydrate_attrs(sequence: 10))
      :persistent_term.put(PrematureEofFileSystem, self())

      on_exit(fn ->
        :persistent_term.erase(PrematureEofFileSystem)
      end)

      assert {:ok, short_store} = Store.new(opts(ctx, file_system: PrematureEofFileSystem))

      assert {:error, {:checkpoint_head_io, :premature_eof}} =
               Store.head(short_store, :calibration)

      assert_receive {:checkpoint_head_premature_eof, count}
      assert count > 0
      assert %{unavailable: 1, corrupt: 0} = Store.status(short_store)
      assert {:ok, ^accepted} = Store.head(store, :calibration)
    end

    test "retries if the pathname is replaced after the descriptor read", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())
      path = Store.head_path(store, :calibration)
      first_bytes = File.read!(path)

      assert {:ok, second} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: first.checkpoint_hash
                 )
               )

      replacement = path <> ".replacement"
      File.rename!(path, replacement)
      File.write!(path, first_bytes)
      counter = :atomics.new(1, signed: false)
      :persistent_term.put(FinalPathSwapFileSystem, {self(), path, replacement, counter})

      on_exit(fn ->
        :persistent_term.erase(FinalPathSwapFileSystem)
      end)

      assert {:ok, raced_store} = Store.new(opts(ctx, file_system: FinalPathSwapFileSystem))
      assert {:ok, ^second} = Store.head(raced_store, :calibration)
      assert_receive {:checkpoint_head_final_path_swapped, ^path}
    end

    test "does not treat a transiently missing changed-read retry as empty", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())
      path = Store.head_path(store, :calibration)
      first_bytes = File.read!(path)

      assert {:ok, second} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: first.checkpoint_hash
                 )
               )

      replacement = path <> ".changed-replacement"
      File.rename!(path, replacement)
      File.write!(path, first_bytes)
      file_info_counter = :atomics.new(1, signed: false)
      lstat_counter = :atomics.new(1, signed: false)

      :persistent_term.put(
        ChangedThenMissingFileSystem,
        {self(), path, replacement, file_info_counter, lstat_counter, {:error, :enoent}}
      )

      on_exit(fn ->
        :persistent_term.erase(ChangedThenMissingFileSystem)
      end)

      assert {:ok, raced_store} = Store.new(opts(ctx, file_system: ChangedThenMissingFileSystem))

      result = Store.head(raced_store, :calibration)

      assert_receive {:checkpoint_head_changed_read_lstat, 1}
      assert_receive {:checkpoint_head_changed_read_lstat, 2}
      assert_receive {:checkpoint_head_changed_read_lstat, 3}
      assert_receive {:checkpoint_head_changed_read_lstat, 4}
      assert {:error, {:checkpoint_head_io, :file_changed_during_read}} = result
      assert_receive {:checkpoint_head_changed_before_retry, ^path}
      assert {:ok, ^second} = Store.head(store, :calibration)
    end

    test "reports a concrete changed-read retry failure instead of stale uncertainty", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())
      path = Store.head_path(store, :calibration)
      first_bytes = File.read!(path)

      assert {:ok, second} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: first.checkpoint_hash
                 )
               )

      replacement = path <> ".denied-replacement"
      File.rename!(path, replacement)
      File.write!(path, first_bytes)
      file_info_counter = :atomics.new(1, signed: false)
      lstat_counter = :atomics.new(1, signed: false)

      :persistent_term.put(
        ChangedThenMissingFileSystem,
        {self(), path, replacement, file_info_counter, lstat_counter, {:error, :eacces}}
      )

      on_exit(fn ->
        :persistent_term.erase(ChangedThenMissingFileSystem)
      end)

      assert {:ok, raced_store} = Store.new(opts(ctx, file_system: ChangedThenMissingFileSystem))

      assert {:error, {:checkpoint_head_io, :eacces}} =
               Store.head(raced_store, :calibration)

      assert_receive {:checkpoint_head_changed_before_retry, ^path}
      assert {:ok, ^second} = Store.head(store, :calibration)
    end

    test "rejects a symlink head without following it", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())

      path = Store.head_path(store, :calibration)
      target = path <> ".target"
      File.rename!(path, target)
      File.ln_s!(target, path)

      assert {:error, :corrupt_checkpoint_head} = Store.head(store, :calibration)
    end

    test "rejects a symlink substituted between lstat and descriptor open", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())

      path = Store.head_path(store, :calibration)
      target = path <> ".target"
      File.cp!(path, target)
      :persistent_term.put({SymlinkSwapFileSystem, path}, {self(), target})

      on_exit(fn ->
        :persistent_term.erase({SymlinkSwapFileSystem, path})
      end)

      assert {:ok, raced_store} = Store.new(opts(ctx, file_system: SymlinkSwapFileSystem))

      assert {:error, :corrupt_checkpoint_head} = Store.head(raced_store, :calibration)

      assert_receive {:checkpoint_head_swapped, ^path}
    end

    test "rejects adapter chunks larger than the requested bounded read", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())
      :persistent_term.put(OversizedReadFileSystem, self())

      on_exit(fn ->
        :persistent_term.erase(OversizedReadFileSystem)
      end)

      assert {:ok, oversized_store} =
               Store.new(opts(ctx, file_system: OversizedReadFileSystem))

      assert {:error, {:checkpoint_head_io, :invalid_read_response}} =
               Store.head(oversized_store, :calibration)

      assert_receive {:checkpoint_head_read_count, count}
      assert count > 0
      refute_receive {:checkpoint_head_negative_read_count, _count}
    end
  end

  describe "atomic persistence outcomes" do
    test "classifies orphan cleanup failures as pre-rename write failures", ctx do
      assert {:ok, store} =
               Store.new(opts(ctx, file_system: CleanupUnavailableFileSystem))

      assert {:error, {:pre_rename, {:orphan_temp_cleanup, {:list_directory, :eacces}}}} =
               Store.put(store, put_attrs())
    end

    test "a pre-rename failure is typed and leaves the previous head intact", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      faulted = fault_store(ctx, :before_rename)

      assert {:error, {:pre_rename, _reason}} =
               Store.put(
                 faulted,
                 put_attrs(sequence: 2, source_generation: 43, parent_hash: first.checkpoint_hash)
               )

      assert {:ok, ^first} = Store.head(store, :calibration)
      refute_temporary_artifacts(store, :calibration)
    end

    test "a post-rename failure is reported as durability-uncertain", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, first} = Store.put(store, put_attrs())

      faulted = fault_store(ctx, :renamed)

      assert {:error, {:durability_uncertain, _reason}} =
               Store.put(
                 faulted,
                 put_attrs(sequence: 2, source_generation: 43, parent_hash: first.checkpoint_hash)
               )

      # The rename itself already happened, so the successor is the head on reopen.
      assert {:ok, second} = Store.head(store, :calibration)
      assert second.sequence == 2
      assert second.parent_hash == first.checkpoint_hash
    end

    test "an exact retry re-establishes parent-directory durability", ctx do
      counter = :atomics.new(1, signed: false)
      test_pid = self()

      assert {:ok, store} =
               Store.new(
                 opts(ctx,
                   fault_injector: fn
                     :renamed ->
                       case :atomics.add_get(counter, 1, 1) do
                         1 ->
                           {:error, :simulated_parent_sync_uncertainty}

                         count ->
                           send(test_pid, {:checkpoint_head_renamed, count})
                           :ok
                       end

                     _stage ->
                       :ok
                   end
                 )
               )

      assert {:error, {:durability_uncertain, _reason}} = Store.put(store, put_attrs())
      assert {:ok, first} = Store.head(store, :calibration)

      assert {:ok, ^first} = Store.put(store, put_attrs())
      assert_receive {:checkpoint_head_renamed, 2}
      assert :atomics.get(counter, 1) == 2
    end

    test "an exact put retry preserves a later descendant and re-establishes durability", ctx do
      counter = :atomics.new(1, signed: false)

      assert {:ok, store} =
               Store.new(
                 opts(ctx,
                   fault_injector: fn
                     :renamed ->
                       if :atomics.add_get(counter, 1, 1) == 1,
                         do: {:error, :simulated_parent_sync_uncertainty},
                         else: :ok

                     _stage ->
                       :ok
                   end
                 )
               )

      assert {:error, {:durability_uncertain, _reason}} = Store.put(store, put_attrs())
      assert {:ok, first} = Store.head(store, :calibration)

      assert {:ok, second} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: first.checkpoint_hash
                 )
               )

      assert {:ok, ^second} = Store.put(store, put_attrs())
      assert :atomics.get(counter, 1) == 3
      assert {:ok, ^second} = Store.head(store, :calibration)
    end

    test "an expected-head hydration retry re-establishes uncertain directory durability", ctx do
      counter = :atomics.new(1, signed: false)
      test_pid = self()

      assert {:ok, store} =
               Store.new(
                 opts(ctx,
                   fault_injector: fn
                     :renamed ->
                       case :atomics.add_get(counter, 1, 1) do
                         1 ->
                           {:error, :simulated_parent_sync_uncertainty}

                         count ->
                           send(test_pid, {:checkpoint_hydration_renamed, count})
                           :ok
                       end

                     _stage ->
                       :ok
                   end
                 )
               )

      expected_absent = %{state: :absent, checkpoint_hash: Record.genesis_parent()}

      assert {:error, {:durability_uncertain, _reason}} =
               Store.hydrate(store, hydrate_attrs(), expected_absent)

      assert {:ok, installed} = Store.head(store, :calibration)
      assert {:ok, ^installed} = Store.hydrate(store, hydrate_attrs(), expected_absent)
      assert_receive {:checkpoint_hydration_renamed, 2}
      assert :atomics.get(counter, 1) == 2
    end

    test "an exact hydration retry preserves a later descendant and re-establishes durability",
         ctx do
      counter = :atomics.new(1, signed: false)

      assert {:ok, store} =
               Store.new(
                 opts(ctx,
                   fault_injector: fn
                     :renamed ->
                       if :atomics.add_get(counter, 1, 1) == 1,
                         do: {:error, :simulated_parent_sync_uncertainty},
                         else: :ok

                     _stage ->
                       :ok
                   end
                 )
               )

      expected_absent = %{state: :absent, checkpoint_hash: Record.genesis_parent()}

      assert {:error, {:durability_uncertain, _reason}} =
               Store.hydrate(store, hydrate_attrs(), expected_absent)

      assert {:ok, accepted} = Store.head(store, :calibration)

      assert {:ok, local} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: accepted.checkpoint_hash
                 )
               )

      assert {:ok, ^local} = Store.hydrate(store, hydrate_attrs(), expected_absent)
      assert :atomics.get(counter, 1) == 3
      assert {:ok, ^local} = Store.head(store, :calibration)
    end

    test "an exact hydration retry survives later acceptance of a local descendant", ctx do
      counter = :atomics.new(1, signed: false)

      assert {:ok, store} =
               Store.new(
                 opts(ctx,
                   fault_injector: fn
                     :renamed ->
                       if :atomics.add_get(counter, 1, 1) == 1,
                         do: {:error, :simulated_parent_sync_uncertainty},
                         else: :ok

                     _stage ->
                       :ok
                   end
                 )
               )

      expected_absent = %{state: :absent, checkpoint_hash: Record.genesis_parent()}

      assert {:error, {:durability_uncertain, _reason}} =
               Store.hydrate(store, hydrate_attrs(), expected_absent)

      assert {:ok, accepted_h1} = Store.head(store, :calibration)

      assert {:ok, local_h2} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: accepted_h1.checkpoint_hash
                 )
               )

      assert {:ok, local_h3} =
               Store.put(
                 store,
                 put_attrs(
                   sequence: 3,
                   source_generation: 44,
                   parent_hash: local_h2.checkpoint_hash
                 )
               )

      assert {:ok, accepted_h3} =
               Store.hydrate(
                 store,
                 hydrate_attrs(
                   sequence: 3,
                   source_generation: 44,
                   parent_hash: local_h2.checkpoint_hash
                 ),
                 %{state: :local_unaccepted, checkpoint_hash: local_h3.checkpoint_hash}
               )

      assert {:ok, ^accepted_h3} = Store.hydrate(store, hydrate_attrs(), expected_absent)
      assert :atomics.get(counter, 1) == 5
      assert {:ok, ^accepted_h3} = Store.head(store, :calibration)
    end

    test "an exact hydration retry preserves a later accepted descendant", ctx do
      counter = :atomics.new(1, signed: false)

      assert {:ok, store} =
               Store.new(
                 opts(ctx,
                   fault_injector: fn
                     :renamed ->
                       if :atomics.add_get(counter, 1, 1) == 1,
                         do: {:error, :simulated_parent_sync_uncertainty},
                         else: :ok

                     _stage ->
                       :ok
                   end
                 )
               )

      expected_absent = %{state: :absent, checkpoint_hash: Record.genesis_parent()}

      assert {:error, {:durability_uncertain, _reason}} =
               Store.hydrate(store, hydrate_attrs(), expected_absent)

      assert {:ok, accepted_h1} = Store.head(store, :calibration)

      accepted_h2_attrs =
        hydrate_attrs(
          sequence: 2,
          source_generation: 43,
          parent_hash: accepted_h1.checkpoint_hash
        )

      assert {:ok, accepted_h2} =
               Store.hydrate(
                 store,
                 accepted_h2_attrs,
                 %{state: :accepted, checkpoint_hash: accepted_h1.checkpoint_hash}
               )

      accepted_h3_attrs =
        hydrate_attrs(
          sequence: 3,
          source_generation: 44,
          parent_hash: accepted_h2.checkpoint_hash
        )

      assert {:ok, accepted_h3} =
               Store.hydrate(
                 store,
                 accepted_h3_attrs,
                 %{state: :accepted, checkpoint_hash: accepted_h2.checkpoint_hash}
               )

      assert {:ok, snapshot_bytes} = File.read(Store.head_path(store, :calibration))
      assert {:ok, accepted_snapshot} = Snapshot.decode(snapshot_bytes)
      assert Snapshot.accepted_ancestor?(accepted_snapshot, accepted_h1.checkpoint_hash)

      assert {:ok, ^accepted_h3} = Store.hydrate(store, hydrate_attrs(), expected_absent)
      assert :atomics.get(counter, 1) == 4
      assert {:ok, ^accepted_h3} = Store.head(store, :calibration)
    end

    test "a fenced local hydration retry re-establishes uncertain directory durability", ctx do
      assert {:ok, original_store} = Store.new(opts(ctx))
      assert {:ok, local_h1} = Store.put(original_store, put_attrs())

      assert {:ok, local_h2} =
               Store.put(
                 original_store,
                 put_attrs(
                   sequence: 2,
                   source_generation: 43,
                   parent_hash: local_h1.checkpoint_hash
                 )
               )

      counter = :atomics.new(1, signed: false)
      test_pid = self()
      recovered_epoch = @credential_epoch + 1

      assert {:ok, recovered_store} =
               Store.new(
                 opts(ctx,
                   credential_epoch: recovered_epoch,
                   storage_epoch: @other_storage_epoch,
                   fault_injector: fn
                     :renamed ->
                       case :atomics.add_get(counter, 1, 1) do
                         1 ->
                           {:error, :simulated_parent_sync_uncertainty}

                         count ->
                           send(test_pid, {:rebound_checkpoint_hydration_renamed, count})
                           :ok
                       end

                     _stage ->
                       :ok
                   end
                 )
               )

      accepted_parent =
        hydrate_attrs(
          credential_epoch: recovered_epoch,
          storage_epoch: @other_storage_epoch
        )

      expected_fenced = %{state: :fenced, checkpoint_hash: local_h2.checkpoint_hash}

      assert {:error, {:durability_uncertain, _reason}} =
               Store.hydrate(recovered_store, accepted_parent, expected_fenced)

      assert {:ok, rebound_h2} = Store.head(recovered_store, :calibration)
      assert rebound_h2.checkpoint_hash == local_h2.checkpoint_hash
      assert rebound_h2.local_credential_epoch == recovered_epoch
      assert rebound_h2.local_storage_epoch == @other_storage_epoch

      assert {:ok, ^rebound_h2} =
               Store.hydrate(recovered_store, accepted_parent, expected_fenced)

      assert_receive {:rebound_checkpoint_hydration_renamed, 2}
      assert :atomics.get(counter, 1) == 2
    end

    test "a pre-rename hydration failure leaves the store empty", ctx do
      faulted = fault_store(ctx, :before_rename)

      assert {:error, {:pre_rename, _reason}} = Store.hydrate(faulted, hydrate_attrs())

      assert {:ok, store} = Store.new(opts(ctx))
      assert :empty = Store.head(store, :calibration)
    end

    test "writes head files with restrictive permissions", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())

      assert {:ok, %File.Stat{mode: mode}} = File.stat(Store.head_path(store, :calibration))
      assert Bitwise.band(mode, 0o777) == 0o600

      assert {:ok, %File.Stat{mode: dir_mode}} =
               File.stat(Path.dirname(Store.head_path(store, :calibration)))

      assert Bitwise.band(dir_mode, 0o777) == 0o700
    end
  end

  describe "secret and identifier hygiene" do
    test "never writes plaintext secrets or raw identifiers into head bytes", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())

      bytes = File.read!(Store.head_path(store, :calibration))

      refute String.contains?(bytes, "hunter2")
      refute String.contains?(bytes, "psk")
      refute String.contains?(bytes, "passphrase")
    end

    test "sanitized status reports counts and flags only", ctx do
      assert {:ok, store} = Store.new(opts(ctx))
      assert {:ok, _first} = Store.put(store, put_attrs())

      assert %{} = status = Store.status(store)

      assert status == %{
               kinds: length(Contract.checkpoint_kinds()),
               present: 1,
               accepted: 0,
               corrupt: 0,
               fenced: 0,
               unavailable: 0
             }

      assert {:ok, _hydrated} =
               Store.hydrate(
                 store,
                 hydrate_attrs(kind: :wind_shift, content: content(:wind_shift))
               )

      assert %{present: 2, accepted: 1} = Store.status(store)

      File.write!(Store.head_path(store, :calibration), <<0>>)
      assert %{corrupt: 1} = Store.status(store)
    end
  end

  defp identity(overrides \\ %{}) do
    Map.merge(
      %{
        device_id: @device_id,
        credential_epoch: @credential_epoch,
        storage_epoch: @storage_epoch
      },
      overrides
    )
  end

  defp opts(ctx, overrides \\ []) do
    opts =
      Keyword.merge(
        [
          base_dir: ctx.base,
          device_id: @device_id,
          credential_epoch: @credential_epoch,
          storage_epoch: @storage_epoch
        ],
        overrides
      )

    Keyword.put_new_lazy(opts, :identity, fn ->
      identity =
        Map.new([:device_id, :credential_epoch, :storage_epoch], fn key ->
          {key, Keyword.fetch!(opts, key)}
        end)

      fn transition -> transition.(identity) end
    end)
  end

  defp fault_store(ctx, stage) do
    assert {:ok, store} =
             Store.new(
               opts(ctx,
                 fault_injector: fn
                   ^stage -> {:error, :simulated}
                   _other -> :ok
                 end
               )
             )

    store
  end

  defp refute_temporary_artifacts(store, kind) do
    directory = Path.dirname(Store.head_path(store, kind))
    assert {:ok, entries} = File.ls(directory)
    assert Enum.reject(entries, &(not String.contains?(&1, ".tmp."))) == []
  end

  defp put_attrs(overrides \\ []) do
    Enum.into(
      overrides,
      %{
        kind: :calibration,
        schema_version: 0x0001,
        sequence: 1,
        source_generation: 42,
        parent_hash: Record.genesis_parent(),
        content: content(:calibration)
      }
    )
  end

  defp hydrate_attrs(overrides \\ []) do
    attrs =
      Enum.into(
        overrides,
        %{
          device_id: @device_id,
          credential_epoch: @credential_epoch,
          storage_epoch: @storage_epoch,
          origin_credential_epoch: @credential_epoch,
          origin_storage_epoch: @storage_epoch,
          kind: :calibration,
          schema_version: 0x0001,
          sequence: 1,
          source_generation: 42,
          parent_hash: Record.genesis_parent(),
          content: content(:calibration)
        }
      )

    Map.put_new_lazy(attrs, :checkpoint_hash, fn -> expected_hash(attrs) end)
  end

  defp expected_hash(attrs) do
    assert {:ok, record} =
             Record.build(%{
               device_id: attrs.device_id,
               local_credential_epoch: attrs.credential_epoch,
               local_storage_epoch: attrs.storage_epoch,
               origin_credential_epoch: attrs.origin_credential_epoch,
               origin_storage_epoch: attrs.origin_storage_epoch,
               sequence: attrs.sequence,
               kind: attrs.kind,
               schema_version: attrs.schema_version,
               source_generation: attrs.source_generation,
               parent_hash: attrs.parent_hash,
               content: attrs.content,
               accepted: true
             })

    record.checkpoint_hash
  end

  defp legacy_snapshot_bytes(snapshot) do
    {:ok, current_bytes} = Record.encode(snapshot.current)
    accepted_bytes = encode_checkpoint_summary(snapshot.last_accepted)

    hash =
      :crypto.hash(
        :sha256,
        "RacingOrg-TrackerCheckpointHeadSnapshot-v1" <>
          <<1, byte_size(current_bytes)::32, current_bytes::binary, byte_size(accepted_bytes)::16,
            accepted_bytes::binary>>
      )

    :erlang.term_to_binary({2, :checkpoint_head_snapshot, Map.put(snapshot, :snapshot_hash, hash)})
  end

  defp encode_checkpoint_summary(nil), do: <<>>
  defp encode_checkpoint_summary(:unknown), do: <<0xFF>>

  defp encode_checkpoint_summary(summary) do
    {:ok, kind_code, _schema_version} = Contract.checkpoint_kind(summary.kind)

    <<summary.device_id::binary-size(16), summary.origin_credential_epoch::32,
      summary.origin_storage_epoch::binary-size(16), summary.sequence::64, kind_code, summary.schema_version::16,
      summary.source_generation::64, summary.parent_hash::binary-size(32), summary.content_hash::binary-size(32),
      summary.checkpoint_hash::binary-size(32)>>
  end

  defp corrupt_head_hash(bytes) do
    :crypto.hash(
      :sha256,
      "RacingOrg-TrackerCheckpointCorruptHead-v1" <>
        <<byte_size(bytes)::64, bytes::binary>>
    )
  end

  defp near_semantic_cap_polar_content, do: polar_content(36_500)

  defp polar_content(cell_count) do
    %{
      "cells" =>
        for tws_bin <- 0..(cell_count - 1) do
          %{
            "count" => 5,
            "quantile" => %{
              "buffer" => [],
              "n" => [2, 3, 4],
              "np" => [1.0, 2.8, 4.6, 4.8, 5.0],
              "q" => [1.0, 2.0, 3.0, 4.0, 5.0]
            },
            "twa_bin" => rem(tws_bin, 72),
            "tws_bin" => tws_bin
          }
        end,
      "max_tws_mps" => 65_535.0,
      "p" => 0.9,
      "twa_width_deg" => 2.5,
      "tws_width_mps" => 1.0
    }
  end

  defp runtime_schema_fixtures do
    [
      {:calibration, 2, runtime_calibration_content()},
      {:polar, 3, runtime_polar_content()},
      {:wind_shift, 2, runtime_wind_shift_content()}
    ]
  end

  defp legacy_schema_fixture(:calibration), do: {1, content(:calibration)}
  defp legacy_schema_fixture(:polar), do: {2, content(:polar)}
  defp legacy_schema_fixture(:wind_shift), do: {1, content(:wind_shift)}

  defp runtime_calibration_content do
    {:ok, observer} =
      CalibrationObserver.start_link(
        name: nil,
        sample_ms: 0,
        dir: nil,
        calibration: nil,
        boat_identifier: "boat-runtime",
        sender: fn _channel, _update -> :ok end,
        now_fn: fn -> 10_000 end,
        utc_now_fn: fn -> ~U[2026-08-10 12:00:00Z] end,
        sync_ms: 60_000,
        persist_ms: 60_000,
        legs: [min_duration_s: 30.0]
      )

    assert {:ok, snapshot} = CalibrationObserver.snapshot(observer)
    assert {:ok, content} = CalibrationRuntime.project(snapshot)
    content
  end

  defp runtime_polar_content do
    bins = Bins.new()
    gate = Gate.new(min_dwell: 1)
    assert {:ok, admission_hash} = PolarSnapshot.policy_hash(gate, 0.3, 1, 0.9)
    assert {:ok, learner} = PolarSnapshot.capture("boat-runtime", admission_hash, bins, 0.9, 10, %{})

    internal = %{
      version: 1,
      captured_at_utc_ms: 1_786_536_000_000,
      authority: %{boat_identifier: "boat-runtime"},
      policy: %{
        admission_hash: admission_hash,
        gate: Map.from_struct(gate),
        min_stw_mps: 0.3,
        window_size: 1,
        p: 0.9,
        sample_ms: 60_000,
        sync_ms: 60_000,
        persist_ms: 60_000,
        persistence_enabled: true,
        bins: Map.from_struct(bins)
      },
      learner: %{source_generation: 10, content: learner},
      upstream_seq: 41,
      window: [],
      sync: %{dirty_keys: [], last_sync_age_ms: 45_000},
      persistence_phase: %{dirty_keys: [], force: true, last_persist_age_ms: 30_000},
      tick: %{remaining_ms: 45_000}
    }

    assert {:ok, content} = PolarRuntime.project(internal)
    content
  end

  defp runtime_wind_shift_content do
    {:ok, clock} =
      Agent.start_link(fn ->
        %{monotonic_ms: 10_000, utc: ~U[2026-08-12 12:00:00Z]}
      end)

    {:ok, observer} =
      WindShiftObserver.start_link(
        name: nil,
        sample_ms: 0,
        dir: nil,
        config: nil,
        commands: nil,
        boat_identifier: "boat-runtime",
        broadcast_enabled: false,
        authority_fn: fn ->
          {:ok, %{device_id: @device_id, credential_epoch: 7, storage_epoch: @storage_epoch}}
        end,
        signals_fn: fn -> %{"true_wind_direction" => {200.0, 10_000}} end,
        now_fn: fn -> Agent.get(clock, & &1.monotonic_ms) end,
        utc_now_fn: fn -> Agent.get(clock, & &1.utc) end,
        put_signals_fn: fn _updates, _monotonic_ms -> :ok end,
        sender: fn _channel, _update -> :ok end,
        transmit_fn: fn _priority, _pgn, _payload -> :ok end
      )

    :ok = WindShiftObserver.tick(observer)
    assert {:ok, snapshot} = WindShiftObserver.snapshot(observer)
    assert {:ok, content} = WindShiftRuntime.project(snapshot)
    content
  end

  defp content(:calibration) do
    %{
      "awa_estimators" => [],
      "aws_estimators" => [],
      "prev_applied" => [],
      "seq" => 0,
      "stw_estimators" => []
    }
  end

  defp content(:wind_shift) do
    %{
      "last_summary" => nil,
      "pending_events" => [],
      "pending_timeline" => [],
      "seq" => 0,
      "session" => nil
    }
  end

  defp content(:polar) do
    %{
      "cells" => [
        %{
          "count" => 5,
          "quantile" => %{
            "buffer" => [],
            "n" => [2, 3, 4],
            "np" => [1.0, 2.8, 4.6, 4.8, 5.0],
            "q" => [1.0, 2.0, 3.0, 4.0, 5.0]
          },
          "twa_bin" => 35,
          "tws_bin" => 3
        }
      ],
      "max_tws_mps" => 51.4444,
      "p" => 0.9,
      "twa_width_deg" => 5.0,
      "tws_width_mps" => 0.514444
    }
  end
end
