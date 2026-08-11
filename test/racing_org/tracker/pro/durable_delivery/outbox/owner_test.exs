defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.OwnerTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner

  @storage_epoch Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @other_storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @device_id Base.decode16!("0f1e2d3c4b5a69788796a5b4c3d2e1f0", case: :lower)
  @credential_epoch 7

  setup do
    root = Path.join(System.tmp_dir!(), "durable_owner_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "single-writer ownership" do
    test "one owner is the sole live writer for one root", %{root: root} do
      assert {:ok, owner} = start_owner(root)
      assert {:error, {:root_already_owned, _existing}} = start_owner(root)

      alias_root = root <> "_alias"
      File.ln_s!(root, alias_root)
      on_exit(fn -> File.rm(alias_root) end)
      assert {:error, {:root_already_owned, _existing}} = start_owner(alias_root)

      other_root = root <> "_other"
      on_exit(fn -> File.rm_rf(other_root) end)
      assert {:ok, _other} = start_owner(other_root)

      assert :ok = stop_owner(owner)
      assert {:ok, _reclaimed} = start_owner(root)
    end

    test "a real supervisor can restart the owner immediately after a crash", %{root: root} do
      children = [
        Map.put(
          Owner.child_spec(owner_opts(root)),
          :id,
          {Owner, root}
        )
      ]

      {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one, max_restarts: 5)

      on_exit(fn ->
        try do
          Supervisor.stop(supervisor)
        catch
          :exit, _reason -> :ok
        end
      end)

      [{_id, first, _type, _modules}] = Supervisor.which_children(supervisor)
      assert {:ok, _receipt} = Owner.enqueue(first, :telemetry, "before-crash")

      reference = Process.monitor(first)
      Process.exit(first, :kill)
      assert_receive {:DOWN, ^reference, :process, _pid, :killed}, 5_000

      restarted = wait_for_restart(supervisor, first)
      refute restarted == first

      assert Enum.map(Owner.pending(restarted), & &1.payload) == ["before-crash"]
      assert {:ok, _receipt} = Owner.enqueue(restarted, :telemetry, "after-restart")
    end

    test "releases ownership when the owner exits so a supervisor can restart it", %{root: root} do
      assert {:ok, owner} = start_owner(root)
      assert {:ok, _receipt} = Owner.enqueue(owner, :telemetry, "payload")

      assert :ok = stop_owner(owner)

      assert {:ok, restarted} = start_owner(root)
      assert [%{sequence: 1}] = Owner.pending(restarted)
    end
  end

  describe "storage epoch" do
    test "obtains the storage epoch from an injected identity source", %{root: root} do
      assert {:ok, owner} = start_owner(root)
      assert %{storage_epoch_bound: true} = Owner.status(owner)

      assert {:ok, %{storage_epoch: @storage_epoch}} = Owner.enqueue(owner, :telemetry, "payload")
    end

    test "refuses to start when the identity source cannot supply an identity", %{root: root} do
      assert {:error, :identity_unavailable} =
               start_owner(root, identity: fn -> {:error, :identity_unavailable} end)

      assert {:error, :invalid_storage_epoch} =
               start_owner(root, identity: fn -> {:ok, identity(storage_epoch: <<0::128>>)} end)

      assert {:error, :invalid_storage_epoch} =
               start_owner(root, identity: fn -> {:ok, identity(storage_epoch: <<0::120>>)} end)

      assert {:error, :invalid_device_id} =
               start_owner(root, identity: fn -> {:ok, identity(device_id: <<0::128>>)} end)

      assert {:error, :invalid_credential_epoch} =
               start_owner(root, identity: fn -> {:ok, identity(credential_epoch: -1)} end)
    end

    test "fails closed when persisted storage epoch does not match the live identity", %{root: root} do
      assert {:ok, owner} = start_owner(root)
      assert {:ok, _receipt} = Owner.enqueue(owner, :telemetry, "payload")
      assert :ok = stop_owner(owner)

      assert {:error, :storage_epoch_mismatch} =
               start_owner(root, identity: fn -> {:ok, identity(storage_epoch: @other_storage_epoch)} end)

      assert {:error, :credential_epoch_mismatch} =
               start_owner(root, identity: fn -> {:ok, identity(credential_epoch: @credential_epoch + 1)} end)
    end

    test "rejects an enqueue whose identity drifted from the bound storage epoch", %{root: root} do
      {:ok, agent} = Agent.start_link(fn -> identity() end)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      assert {:ok, owner} = start_owner(root, identity: fn -> {:ok, Agent.get(agent, & &1)} end)
      assert {:ok, _receipt} = Owner.enqueue(owner, :telemetry, "before-drift")

      Agent.update(agent, fn current -> %{current | storage_epoch: @other_storage_epoch} end)

      assert {:error, :storage_epoch_mismatch} = Owner.enqueue(owner, :telemetry, "after-drift")
      assert %{quarantined: true, accepting: false} = Owner.status(owner)
      assert {:error, :quarantined} = Owner.enqueue(owner, :telemetry, "later")
    end
  end

  describe "acknowledgement" do
    test "deletes only on an authenticated matching receipt, never on transport send", %{root: root} do
      assert {:ok, owner} = start_owner(root)
      assert {:ok, receipt} = Owner.enqueue(owner, :telemetry, "payload")
      assert [pending] = Owner.pending(owner)
      assert pending.sequence == receipt.sequence

      assert {:error, :payload_hash_mismatch} =
               Owner.acknowledge(owner, %{receipt | payload_hash: <<0::256>>})

      assert {:error, :storage_epoch_mismatch} =
               Owner.acknowledge(owner, %{receipt | storage_epoch: @other_storage_epoch})

      assert {:error, :device_id_mismatch} =
               Owner.acknowledge(owner, %{receipt | device_id: :binary.copy(<<0xAB>>, 16)})

      assert {:error, :credential_epoch_mismatch} =
               Owner.acknowledge(owner, %{receipt | credential_epoch: @credential_epoch + 1})

      assert [^pending] = Owner.pending(owner)
      assert {:ok, [_removed]} = Owner.acknowledge(owner, receipt)
      assert Owner.pending(owner) == []
    end

    test "a stale receipt for an already resolved entry is rejected", %{root: root} do
      assert {:ok, owner} = start_owner(root)
      assert {:ok, first} = Owner.enqueue(owner, :telemetry, "first")
      assert {:ok, _second} = Owner.enqueue(owner, :telemetry, "second")

      assert {:ok, [_removed]} = Owner.acknowledge(owner, first)
      assert {:error, :receipt_entry_not_found} = Owner.acknowledge(owner, first)
      assert [%{sequence: 2}] = Owner.pending(owner)
    end

    test "a duplicate acknowledgement is idempotent and never removes a later entry", %{root: root} do
      assert {:ok, owner} = start_owner(root)
      assert {:ok, first} = Owner.enqueue(owner, :telemetry, "first")
      assert {:ok, _second} = Owner.enqueue(owner, :telemetry, "second")

      assert {:ok, [removed]} = Owner.acknowledge(owner, first)
      assert removed.sequence == 1

      assert {:ok, []} = Owner.acknowledge(owner, first, idempotent: true)
      assert {:ok, []} = Owner.acknowledge(owner, first, idempotent: true)

      assert [%{sequence: 2}] = Owner.pending(owner)
      assert %{pending_entries: 1} = Owner.status(owner)
    end

    test "idempotence requires durable proof of the exact six-field resolved receipt", %{root: root} do
      assert {:ok, owner} = start_owner(root)
      assert {:ok, receipt} = Owner.enqueue(owner, :telemetry, "payload")
      assert {:ok, [_removed]} = Owner.acknowledge(owner, receipt)
      GenServer.stop(owner)

      assert {:ok, reopened} = start_owner(root)
      assert {:ok, []} = Owner.acknowledge(reopened, receipt, idempotent: true)

      assert {:error, :receipt_entry_not_found} =
               Owner.acknowledge(
                 reopened,
                 %{receipt | sequence: receipt.sequence + 100},
                 idempotent: true
               )

      assert {:error, :receipt_entry_not_found} =
               Owner.acknowledge(reopened, %{receipt | payload_hash: <<7::256>>}, idempotent: true)
    end

    test "a cumulative receipt can close only gaps proven by exact resolved history", %{root: root} do
      assert {:ok, owner} = start_owner(root)
      assert {:ok, first} = Owner.enqueue(owner, :telemetry, "first", priority: 0)
      assert {:ok, second} = Owner.enqueue(owner, :telemetry, "second", priority: 10)
      assert Enum.map(Owner.pending(owner), & &1.sequence) == [2, 1]

      assert {:ok, [_second]} = Owner.acknowledge(owner, second)
      cumulative = %{first | cumulative_sequence: 2}
      assert {:ok, [removed]} = Owner.acknowledge(owner, cumulative)
      assert removed.sequence == 1
      assert Owner.pending(owner) == []
      assert {:ok, []} = Owner.acknowledge(owner, cumulative, idempotent: true)

      refute_result = %{cumulative | payload_hash: <<9::256>>}

      assert {:error, :receipt_entry_not_found} =
               Owner.acknowledge(owner, refute_result, idempotent: true)
    end

    test "a cumulative receipt durably proves every exact entry it resolves", %{root: root} do
      assert {:ok, owner} = start_owner(root)
      assert {:ok, first} = Owner.enqueue(owner, :telemetry, "first")
      assert {:ok, _second} = Owner.enqueue(owner, :telemetry, "second")
      assert {:ok, third} = Owner.enqueue(owner, :telemetry, "third")

      assert {:ok, removed} = Owner.acknowledge(owner, %{third | cumulative_sequence: 3})
      assert Enum.map(removed, & &1.sequence) == [1, 2, 3]
      GenServer.stop(owner)

      assert {:ok, reopened} = start_owner(root)
      assert {:ok, []} = Owner.acknowledge(reopened, first, idempotent: true)
      assert {:ok, fourth} = Owner.enqueue(reopened, :telemetry, "fourth")
      assert {:ok, [removed_fourth]} = Owner.acknowledge(reopened, %{fourth | cumulative_sequence: 4})
      assert removed_fourth.sequence == fourth.sequence
    end

    test "a cumulative receipt cannot infer an unproven missing acceptance", %{root: root} do
      assert {:ok, owner} = start_owner(root)
      assert {:ok, first} = Owner.enqueue(owner, :telemetry, "first")
      assert {:ok, second} = Owner.enqueue(owner, :telemetry, "second")
      assert {:ok, third} = Owner.enqueue(owner, :telemetry, "third")

      assert {:ok, [_first]} = Owner.acknowledge(owner, first)
      GenServer.stop(owner)

      snapshot = Path.join(root, "snapshot.bin")
      bytes = File.read!(snapshot)
      File.write!(snapshot, bytes)
      assert {:ok, reopened} = start_owner(root, max_resolved_receipts: 1)
      assert {:ok, [_second]} = Owner.acknowledge(reopened, second)

      assert {:error, :non_contiguous_cumulative_prefix} =
               Owner.acknowledge(reopened, %{third | cumulative_sequence: 3})

      assert Enum.map(Owner.pending(reopened), & &1.sequence) == [3]
    end

    test "a stale receipt from a superseded storage epoch is refused", %{root: root} do
      assert {:ok, owner} = start_owner(root)
      assert {:ok, receipt} = Owner.enqueue(owner, :telemetry, "payload")

      stale = %{receipt | storage_epoch: @other_storage_epoch}
      assert {:error, :storage_epoch_mismatch} = Owner.acknowledge(owner, stale)
      assert {:error, :storage_epoch_mismatch} = Owner.acknowledge(owner, stale, idempotent: true)
      assert [_pending] = Owner.pending(owner)
    end
  end

  describe "capacity" do
    test "surfaces backpressure explicitly without evicting durable entries", %{root: root} do
      assert {:ok, owner} = start_owner(root, max_entries: 2)
      assert {:ok, first} = Owner.enqueue(owner, :telemetry, "first")
      assert {:ok, _second} = Owner.enqueue(owner, :telemetry, "second")

      assert {:error, {:backpressure, :entry_capacity}} = Owner.enqueue(owner, :telemetry, "third")

      assert %{pending_entries: 2, accepting: true, quarantined: false} = Owner.status(owner)
      assert length(Owner.pending(owner)) == 2

      assert {:ok, [_removed]} = Owner.acknowledge(owner, first)
      assert {:ok, _third} = Owner.enqueue(owner, :telemetry, "third")
    end

    test "byte capacity backpressure keeps the owner accepting after resolution", %{root: root} do
      assert {:ok, owner} = start_owner(root, max_bytes: 200)

      assert {:error, {:backpressure, :byte_capacity}} =
               Owner.enqueue(owner, :telemetry, String.duplicate("a", 300))

      assert %{quarantined: false, accepting: true} = Owner.status(owner)
      assert {:ok, _receipt} = Owner.enqueue(owner, :telemetry, "small")
    end
  end

  describe "quarantine latch" do
    test "latches durability uncertainty and fails closed thereafter", %{root: root} do
      assert {:ok, owner} = start_owner(root, file_system: __MODULE__.FailingSyncFileSystem)
      assert {:ok, _receipt} = Owner.enqueue(owner, :telemetry, "first")

      __MODULE__.FailingSyncFileSystem.fail_next_segment_sync(owner)

      assert {:error, {:durability_uncertain, _reason}} = Owner.enqueue(owner, :telemetry, "second")

      assert %{quarantined: true, accepting: false} = Owner.status(owner)

      assert {:error, :quarantined} = Owner.enqueue(owner, :telemetry, "third")
      assert {:error, :quarantined} = Owner.acknowledge(owner, fake_receipt())
      assert {:error, :quarantined} = Owner.authorize_loss(owner, fake_receipt(), "operator approved")
      assert {:error, :quarantined} = Owner.pending(owner)
    end

    test "a restart after latched uncertainty recovers durable state", %{root: root} do
      assert {:ok, owner} = start_owner(root, file_system: __MODULE__.FailingSyncFileSystem)
      assert {:ok, _receipt} = Owner.enqueue(owner, :telemetry, "first")

      __MODULE__.FailingSyncFileSystem.fail_next_segment_sync(owner)
      assert {:error, {:durability_uncertain, _reason}} = Owner.enqueue(owner, :telemetry, "second")
      assert :ok = stop_owner(owner)

      assert {:ok, restarted} = start_owner(root)
      assert %{quarantined: false, accepting: true} = Owner.status(restarted)
      assert Enum.map(Owner.pending(restarted), & &1.sequence) == [1, 2]
    end
  end

  describe "authorize_loss" do
    test "requires an exact identity and an auditable reason", %{root: root} do
      assert {:ok, owner} = start_owner(root)
      assert {:ok, receipt} = Owner.enqueue(owner, :health, "health")

      assert {:error, :invalid_loss_reason} = Owner.authorize_loss(owner, receipt, "")

      assert {:error, :payload_hash_mismatch} =
               Owner.authorize_loss(owner, %{receipt | payload_hash: <<0::256>>}, "operator approved")

      assert [_pending] = Owner.pending(owner)

      reason = "operator approved loss after irrecoverable media failure ticket RMA-42"
      assert {:ok, removed} = Owner.authorize_loss(owner, receipt, reason)
      assert removed.sequence == receipt.sequence
      assert Owner.pending(owner) == []
      assert %{loss_authorizations: 1} = Owner.status(owner)
    end
  end

  describe "serialization" do
    test "serializes concurrent callers into one durable sequence per stream", %{root: root} do
      assert {:ok, owner} = start_owner(root, max_entries: 50)
      caller_count = 12

      results =
        1..caller_count
        |> Task.async_stream(
          fn n -> Owner.enqueue(owner, :telemetry, "payload-#{n}") end,
          max_concurrency: caller_count,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      sequences =
        results
        |> Enum.map(fn {:ok, receipt} -> receipt.sequence end)
        |> Enum.sort()

      assert sequences == Enum.to_list(1..caller_count)
      assert Enum.map(Owner.pending(owner), & &1.sequence) == Enum.to_list(1..caller_count)

      assert :ok = stop_owner(owner)
      assert {:ok, restarted} = start_owner(root, max_entries: 50)
      assert Enum.map(Owner.pending(restarted), & &1.sequence) == Enum.to_list(1..caller_count)
    end
  end

  describe "checkpoint enqueue" do
    test "rejects arbitrary checkpoint payloads from generic enqueue", %{root: root} do
      assert {:ok, owner} = start_owner(root, streams: [:checkpoint])

      assert {:error, :checkpoint_builder_required} =
               Owner.enqueue(owner, :checkpoint, "forged-child", priority: 255)

      assert Owner.pending(owner, stream: :checkpoint) == []
    end

    test "builds checkpoint payloads from authoritative sequences in parent-first order", %{root: root} do
      assert {:ok, owner} = start_owner(root, streams: [:checkpoint])

      assert {:ok, first} =
               Owner.enqueue_checkpoint(owner, fn 1 ->
                 {:ok, "parent-sequence-1"}
               end)

      assert {:ok, second} =
               Owner.enqueue_checkpoint(owner, fn 2 ->
                 {:ok, "child-sequence-2"}
               end)

      assert first.sequence == 1
      assert first.payload_hash == :crypto.hash(:sha256, "parent-sequence-1")
      assert second.sequence == 2
      assert second.payload_hash == :crypto.hash(:sha256, "child-sequence-2")

      assert Enum.map(
               Owner.pending(owner, stream: :checkpoint),
               &{&1.sequence, &1.payload, &1.priority}
             ) == [
               {1, "parent-sequence-1", 0},
               {2, "child-sequence-2", 0}
             ]

      assert :ok = stop_owner(owner)
      assert {:ok, restarted} = start_owner(root, streams: [:checkpoint])

      assert Enum.map(
               Owner.pending(restarted, stream: :checkpoint),
               &{&1.sequence, &1.payload}
             ) == [
               {1, "parent-sequence-1"},
               {2, "child-sequence-2"}
             ]
    end
  end

  describe "status sanitization" do
    test "contains no payload bytes, hashes, credentials, paths, or pids", %{root: root} do
      secret_payload = "wifi-psk-hunter2-and-a-bearer-token"
      assert {:ok, owner} = start_owner(root)
      assert {:ok, receipt} = Owner.enqueue(owner, :telemetry, secret_payload)

      status = Owner.status(owner)

      assert %{
               accepting: true,
               quarantined: false,
               storage_epoch_bound: true,
               pending_entries: 1,
               loss_authorizations: 0
             } = status

      assert Enum.sort(Map.keys(status)) ==
               Enum.sort([
                 :accepting,
                 :quarantined,
                 :storage_epoch_bound,
                 :pending_entries,
                 :pending_bytes,
                 :disk_bytes,
                 :max_entries,
                 :max_bytes,
                 :max_disk_bytes,
                 :loss_authorizations,
                 :streams
               ])

      encoded = :erlang.term_to_binary(status)

      refute contains?(encoded, secret_payload)
      refute contains?(encoded, receipt.payload_hash)
      refute contains?(encoded, :crypto.hash(:sha256, secret_payload))
      refute contains?(encoded, @storage_epoch)
      refute contains?(encoded, @device_id)
      refute contains?(encoded, root)
      refute contains?(encoded, "/data")

      refute status |> Map.values() |> Enum.any?(&is_pid/1)
      refute status |> Map.values() |> Enum.any?(&is_binary/1)
      refute Map.has_key?(status, :root)
      refute Map.has_key?(status, :storage_epoch)
      refute Map.has_key?(status, :device_id)
      refute Map.has_key?(status, :credential_epoch)
      refute Map.has_key?(status, :entries)
      refute Map.has_key?(status, :store)
    end

    test "a quarantined status still leaks nothing sensitive", %{root: root} do
      assert {:ok, owner} = start_owner(root, file_system: __MODULE__.FailingSyncFileSystem)
      assert {:ok, _receipt} = Owner.enqueue(owner, :telemetry, "secret-payload-value")

      __MODULE__.FailingSyncFileSystem.fail_next_segment_sync(owner)
      assert {:error, {:durability_uncertain, _reason}} = Owner.enqueue(owner, :telemetry, "second")

      status = Owner.status(owner)
      assert %{quarantined: true, accepting: false} = status

      encoded = :erlang.term_to_binary(status)
      refute contains?(encoded, "secret-payload-value")
      refute contains?(encoded, root)
      refute contains?(encoded, @storage_epoch)
    end
  end

  describe "pending" do
    test "filters by stream and bounds the returned batch", %{root: root} do
      assert {:ok, owner} = start_owner(root)
      assert {:ok, _first} = Owner.enqueue(owner, :telemetry, "t1")
      assert {:ok, _second} = Owner.enqueue(owner, :health, "h1")
      assert {:ok, _third} = Owner.enqueue(owner, :telemetry, "t2")

      assert Enum.map(Owner.pending(owner), & &1.stream) == [:telemetry, :health, :telemetry]

      assert Enum.map(Owner.pending(owner, stream: :telemetry), & &1.payload) == ["t1", "t2"]
      assert Enum.map(Owner.pending(owner, limit: 2), & &1.payload) == ["t1", "h1"]
      assert Enum.map(Owner.pending(owner, stream: :telemetry, limit: 1), & &1.payload) == ["t1"]

      assert {:error, :unknown_stream} = Owner.pending(owner, stream: :not_configured)
      assert {:error, :invalid_limit} = Owner.pending(owner, limit: 0)
    end

    test "returns higher priority entries first", %{root: root} do
      assert {:ok, owner} = start_owner(root)
      assert {:ok, _low} = Owner.enqueue(owner, :telemetry, "low", priority: 1)
      assert {:ok, _high} = Owner.enqueue(owner, :telemetry, "high", priority: 9)

      assert Enum.map(Owner.pending(owner), & &1.payload) == ["high", "low"]
    end
  end

  describe "configuration" do
    test "the root is independently configurable and never defaults implicitly", %{root: root} do
      assert {:error, :missing_root} =
               start_supervised_owner(owner_opts(root) |> Keyword.delete(:root))

      assert {:error, :invalid_root} = start_owner("relative/path")
      assert {:ok, owner} = start_owner(root)
      assert File.dir?(root)
      assert :ok = stop_owner(owner)
    end
  end

  defmodule FailingSyncFileSystem do
    @moduledoc false
    @behaviour RacingOrg.Tracker.Pro.DurableDelivery.Outbox.FileSystem

    alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.FileSystem

    def fail_next_segment_sync(owner) do
      :persistent_term.put({__MODULE__, owner_pid(owner)}, true)
    end

    defp owner_pid(owner) when is_pid(owner), do: owner
    defp owner_pid(owner), do: GenServer.whereis(owner)

    defp fail_now? do
      key = {__MODULE__, self()}

      case :persistent_term.get(key, false) do
        true ->
          :persistent_term.erase(key)
          true

        false ->
          false
      end
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
    def sync(device) do
      path = Process.get({__MODULE__, :path, device})

      if is_binary(path) and String.ends_with?(path, ".log") and fail_now?() do
        {:error, :simulated_sync_failure}
      else
        FileSystem.sync(device)
      end
    end

    @impl true
    def close(device) do
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
  end

  defp identity(overrides \\ []) do
    %{
      device_id: Keyword.get(overrides, :device_id, @device_id),
      credential_epoch: Keyword.get(overrides, :credential_epoch, @credential_epoch),
      storage_epoch: Keyword.get(overrides, :storage_epoch, @storage_epoch)
    }
  end

  defp owner_opts(root, overrides \\ []) do
    defaults = [
      root: root,
      identity: fn -> {:ok, identity()} end,
      streams: [:telemetry, :health],
      max_entries: 10,
      max_bytes: 10_000,
      segment_max_bytes: 4_096
    ]

    Keyword.merge(defaults, overrides)
  end

  defp start_owner(root, overrides \\ []) do
    start_supervised_owner(owner_opts(root, overrides))
  end

  # A failed init/1 exits the linked caller, so trap exits around start_link and
  # normalize the {:error, reason} the tests assert on.
  defp start_supervised_owner(opts) do
    previous = Process.flag(:trap_exit, true)

    try do
      case Owner.start_link(opts) do
        {:ok, pid} = result ->
          on_exit(fn -> stop_owner(pid) end)
          result

        {:error, reason} ->
          flush_exit()
          {:error, reason}
      end
    after
      Process.flag(:trap_exit, previous)
    end
  end

  defp wait_for_restart(supervisor, previous, attempts \\ 100) do
    case Supervisor.which_children(supervisor) do
      [{_id, pid, _type, _modules}] when is_pid(pid) and pid != previous ->
        pid

      _other when attempts > 0 ->
        Process.sleep(20)
        wait_for_restart(supervisor, previous, attempts - 1)

      other ->
        flunk("owner was not restarted: #{inspect(other)}")
    end
  end

  defp flush_exit do
    receive do
      {:EXIT, _pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  # Monitor before signalling: an already-dead process still delivers :DOWN, so
  # this stays correct whether or not the owner is alive on entry.
  defp stop_owner(owner) do
    reference = Process.monitor(owner)
    Process.unlink(owner)
    Process.exit(owner, :shutdown)

    receive do
      {:DOWN, ^reference, :process, _pid, _reason} -> :ok
    after
      5_000 -> {:error, :timeout}
    end
  end

  defp fake_receipt do
    %{
      stream: :telemetry,
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      sequence: 1,
      payload_hash: :crypto.hash(:sha256, "payload"),
      cumulative_sequence: 0
    }
  end

  defp contains?(haystack, needle) when is_binary(needle) do
    :binary.match(haystack, needle) != :nomatch
  end
end
