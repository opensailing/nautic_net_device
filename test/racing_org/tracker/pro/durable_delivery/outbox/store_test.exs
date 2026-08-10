defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.{FileSystem, Store}

  @storage_epoch Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)

  defmodule TracingFileSystem do
    @behaviour FileSystem

    def attach(owner), do: Process.put({__MODULE__, :owner}, owner)
    def fail_segment_sync, do: Process.put({__MODULE__, :fail_segment_sync}, true)

    @impl true
    def read(path), do: FileSystem.read(path)

    @impl true
    def list_dir(path), do: FileSystem.list_dir(path)

    @impl true
    def mkdir_p(path), do: FileSystem.mkdir_p(path)

    @impl true
    def chmod(path, mode), do: FileSystem.chmod(path, mode)

    @impl true
    def open(path, modes) do
      report({:open, path, modes})

      case FileSystem.open(path, modes) do
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
    def rename(source, destination), do: FileSystem.rename(source, destination)

    @impl true
    def remove(path), do: FileSystem.remove(path)

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

  test "rotates bounded segments and truncates only a torn final record", %{root: root} do
    assert {:ok, store} = open_store(root, segment_max_bytes: 260)
    assert {:ok, _first, store} = Store.enqueue(store, :telemetry, String.duplicate("a", 40), entry_id: entry_id(1))
    [first_segment] = segment_paths(root)
    first_size = File.stat!(first_segment).size

    assert {:ok, _second, _store} =
             Store.enqueue(store, :telemetry, String.duplicate("b", 40), entry_id: entry_id(2))

    assert [^first_segment, second_segment] = segment_paths(root)
    second_bytes = File.read!(second_segment)
    File.write!(second_segment, binary_part(second_bytes, 0, byte_size(second_bytes) - 7))

    assert {:ok, recovered} = open_store(root, segment_max_bytes: 260)
    assert Enum.map(Store.pending(recovered), & &1.sequence) == [1]
    assert Store.next_sequence(recovered, :telemetry) == {:ok, 2}
    assert File.stat!(first_segment).size == first_size
    assert File.stat!(second_segment).size == 0
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

    base_receipt = %{
      stream: entry.stream,
      storage_epoch: entry.storage_epoch,
      sequence: entry.sequence,
      payload_hash: entry.payload_hash,
      cumulative_sequence: 0,
      device_id: <<1::128>>,
      credential_epoch: 7,
      receipt_hash: <<2::256>>
    }

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

    receipt = %{
      stream: third.stream,
      storage_epoch: third.storage_epoch,
      sequence: third.sequence,
      payload_hash: third.payload_hash,
      cumulative_sequence: 2
    }

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

    assert {:ok, [^gap_second], gap_store} =
             Store.acknowledge(gap_store, %{
               stream: gap_second.stream,
               storage_epoch: gap_second.storage_epoch,
               sequence: 2,
               payload_hash: gap_second.payload_hash,
               cumulative_sequence: 0
             })

    assert {:error, :non_contiguous_cumulative_prefix} =
             Store.acknowledge(gap_store, %{
               stream: gap_third.stream,
               storage_epoch: gap_third.storage_epoch,
               sequence: 3,
               payload_hash: gap_third.payload_hash,
               cumulative_sequence: 3
             })

    assert Store.pending(gap_store) == [gap_first, gap_third]
  end

  test "explicit loss authorization durably records the exact entry and auditable reason", %{root: root} do
    assert {:ok, store} = open_store(root)
    assert {:ok, entry, store} = Store.enqueue(store, :health, "health", entry_id: entry_id(1))

    identity = Map.take(entry, [:stream, :storage_epoch, :sequence, :payload_hash])

    assert {:error, :invalid_loss_reason} = Store.authorize_loss(store, identity, "")

    assert {:error, :payload_hash_mismatch} =
             Store.authorize_loss(store, %{identity | payload_hash: <<0::256>>}, "operator approved")

    reason = "operator approved loss after irrecoverable media failure ticket RMA-42"
    assert {:ok, ^entry, empty} = Store.authorize_loss(store, identity, reason)
    assert Store.pending(empty) == []

    assert Store.loss_authorizations(empty) == [
             %{
               stream: entry.stream,
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

  defp open_store(root, overrides \\ []) do
    defaults = [
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
