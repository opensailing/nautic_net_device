defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.{FileSystem, Record, RunState, Snapshot, Store}

  @storage_epoch Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @device_id Base.decode16!("0f1e2d3c4b5a69788796a5b4c3d2e1f0", case: :lower)
  @other_device_id Base.decode16!("aabbccddeeff00112233445566778899", case: :lower)
  @credential_epoch 7

  defmodule TracingFileSystem do
    @behaviour FileSystem

    def attach(owner), do: Process.put({__MODULE__, :owner}, owner)
    def fail_segment_sync, do: Process.put({__MODULE__, :fail_segment_sync}, true)
    def fail_segment_append_open, do: Process.put({__MODULE__, :fail_segment_append_open}, true)
    def fail_segment_chmod, do: Process.put({__MODULE__, :fail_segment_chmod}, true)
    def fail_snapshot_read, do: Process.put({__MODULE__, :fail_snapshot_read}, true)
    def fail_run_state_rename, do: Process.put({__MODULE__, :fail_run_state_rename}, true)
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
    def chmod(path, mode) do
      if Process.get({__MODULE__, :fail_segment_chmod}, false) and segment_path?(path) do
        Process.delete({__MODULE__, :fail_segment_chmod})
        {:error, :simulated_chmod_failure}
      else
        FileSystem.chmod(path, mode)
      end
    end

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
        Process.get({__MODULE__, :fail_run_state_rename}, false) and
            Path.basename(destination) == "run-state.bin" ->
          Process.delete({__MODULE__, :fail_run_state_rename})
          {:error, :simulated_rename_failure}

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

  test "appends and fsyncs before enqueue succeeds, then recovers entries and sequences", %{root: root} do
    TracingFileSystem.attach(self())
    assert {:ok, store} = open_store(root, file_system: TracingFileSystem)

    assert {:ok, first, store} =
             Store.enqueue(store, :telemetry, "first", entry_id: entry_id(1), priority: 7)

    events = drain_file_events([])
    segment_path = Enum.find_value(events, &segment_open_path/1)

    write_index =
      event_index(events, fn
        {:write, path, _size} -> path == segment_path
        _event -> false
      end)

    sync_index =
      event_index(events, fn
        {:sync, path} -> path == segment_path
        _event -> false
      end)

    assert write_index < sync_index
    assert Enum.at(events, sync_index + 1) == {:close, segment_path}
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

  test "cleans a newly created segment when append-open or chmod fails", %{root: root} do
    TracingFileSystem.attach(self())

    assert {:ok, store} =
             open_store(root,
               file_system: TracingFileSystem,
               segment_max_bytes: 260
             )

    assert {:ok, _first, store} =
             Store.enqueue(store, :telemetry, String.duplicate("a", 40), entry_id: entry_id(1))

    TracingFileSystem.fail_segment_append_open()

    assert {:error, {:append_open, :simulated_open_failure}} =
             Store.enqueue(store, :telemetry, String.duplicate("b", 40), entry_id: entry_id(2))

    assert length(segment_paths(root)) == 1

    assert {:ok, _second, _store} =
             Store.enqueue(store, :telemetry, String.duplicate("b", 40), entry_id: entry_id(2))

    chmod_root = root <> "_chmod"
    on_exit(fn -> File.rm_rf(chmod_root) end)

    assert {:ok, chmod_store} =
             open_store(chmod_root,
               file_system: TracingFileSystem,
               segment_max_bytes: 260
             )

    TracingFileSystem.fail_segment_chmod()

    assert {:error, {:chmod_segment, :simulated_chmod_failure}} =
             Store.enqueue(chmod_store, :telemetry, "payload", entry_id: entry_id(3))

    assert segment_paths(chmod_root) == []
    assert {:ok, _entry, _store} = Store.enqueue(chmod_store, :telemetry, "payload", entry_id: entry_id(3))
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
    assert length(Store.loss_authorizations(migrated)) == 2
    assert {:error, :duplicate_entry_id} = Store.enqueue(migrated, :telemetry, "duplicate", entry_id: entry_id(9))
    assert {:ok, entry, _store} = Store.enqueue(migrated, :telemetry, "novel", entry_id: entry_id(10))
    assert entry.sequence == 2
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

  defp encoded_entry(sequence, id, payload) do
    {:ok, encoded} =
      Record.encode(%{
        kind: :entry,
        stream: "telemetry",
        device_id: @device_id,
        credential_epoch: @credential_epoch,
        storage_epoch: @storage_epoch,
        sequence: sequence,
        entry_id: id,
        payload_hash: :crypto.hash(:sha256, payload),
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

  defp segment_paths(root) do
    root
    |> File.ls!()
    |> Enum.filter(&String.match?(&1, ~r/^segment-\d{20}\.log$/))
    |> Enum.sort()
    |> Enum.map(&Path.join(root, &1))
  end

  defp segment_open_path({:open, path, modes}) do
    if String.ends_with?(path, ".log") and :append in modes, do: path
  end

  defp segment_open_path(_event), do: nil

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
end
