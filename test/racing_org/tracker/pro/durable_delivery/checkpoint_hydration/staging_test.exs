defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.StagingTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.Staging
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.WindShift, as: WindShiftRuntime
  alias RacingOrg.Tracker.Pro.WindShift.Observer, as: WindShiftObserver

  defmodule ReplacingReadFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def read(device, count) do
      result = FileSystem.read(device, count)

      case {:persistent_term.get(__MODULE__, nil), result} do
        {{owner, path, true}, {:ok, bytes}} ->
          :persistent_term.erase(__MODULE__)
          replacement = path <> ".replacement"
          File.write!(replacement, File.read!(path))
          File.rename!(replacement, path)
          send(owner, {:staging_path_replaced, byte_size(bytes)})

        _other ->
          :ok
      end

      result
    end

    def lstat(path) do
      case :persistent_term.get(__MODULE__, nil) do
        {owner, ^path, false} -> :persistent_term.put(__MODULE__, {owner, path, true})
        _other -> :ok
      end

      FileSystem.lstat(path)
    end

    defdelegate file_info(device), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate close(device), to: FileSystem
  end

  defmodule CleanupReplacingFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def list_dir(path) do
      case :persistent_term.get(__MODULE__, nil) do
        {owner, ^path, target} ->
          :persistent_term.erase(__MODULE__)
          renamed = path <> ".before-replacement"
          File.rename!(path, renamed)
          File.ln_s!(target, path)
          send(owner, {:staging_directory_replaced, path})

        _other ->
          :ok
      end

      FileSystem.list_dir(path)
    end

    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
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

  defmodule CleanupMutationFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def list_dir(path) do
      case :persistent_term.get(__MODULE__, nil) do
        {owner, :inject_on_relist, ^path, name} ->
          :persistent_term.erase(__MODULE__)
          File.write!(Path.join(path, name), "late-entry")
          send(owner, {:cleanup_late_entry_injected, path})

        _other ->
          :ok
      end

      FileSystem.list_dir(path)
    end

    def remove(path) do
      result = FileSystem.remove(path)

      case :persistent_term.get(__MODULE__, nil) do
        {owner, :fail_after_first_remove} when result == :ok ->
          :persistent_term.erase(__MODULE__)
          send(owner, {:cleanup_first_remove_completed, path, self()})

          receive do
            :continue_cleanup -> :ok
          end

        _other ->
          :ok
      end

      result
    end

    def open(path, modes) do
      case :persistent_term.get(__MODULE__, nil) do
        {owner, :fail_sync_open, ^path} ->
          :persistent_term.erase(__MODULE__)
          send(owner, {:cleanup_sync_open_failed, path})
          {:error, :simulated_sync_open_failure}

        _other ->
          FileSystem.open(path, modes)
      end
    end

    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
  end

  defmodule BlockingReadFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def lstat(path) do
      case :persistent_term.get(__MODULE__, nil) do
        owner when is_pid(owner) ->
          :persistent_term.erase(__MODULE__)
          send(owner, {:staging_read_blocked, self()})

          receive do
            :continue_staging_read -> FileSystem.lstat(path)
          end

        _other ->
          FileSystem.lstat(path)
      end
    end

    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate close(device), to: FileSystem
  end

  defmodule RecordingFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def open(path, modes) do
      case FileSystem.open(path, modes) do
        {:ok, device} -> {:ok, {path, device}}
        error -> error
      end
    end

    def read({_path, device}, count), do: FileSystem.read(device, count)
    def file_info({_path, device}), do: FileSystem.file_info(device)
    def write({_path, device}, contents), do: FileSystem.write(device, contents)

    def sync({path, device}) do
      if owner = :persistent_term.get(__MODULE__, nil), do: send(owner, {:staging_synced, path})
      FileSystem.sync(device)
    end

    def close({_path, device}), do: FileSystem.close(device)
    defdelegate list_dir(path), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
  end

  defmodule PriorChunkReadFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def open(path, modes) do
      case FileSystem.open(path, modes) do
        {:ok, device} -> {:ok, {path, device}}
        error -> error
      end
    end

    def read({path, device}, count) do
      if owner = :persistent_term.get(__MODULE__, nil), do: send(owner, {:staging_bounded_read, path})
      FileSystem.read(device, count)
    end

    def file_info({_path, device}), do: FileSystem.file_info(device)
    def write({_path, device}, contents), do: FileSystem.write(device, contents)
    def sync({_path, device}), do: FileSystem.sync(device)
    def close({_path, device}), do: FileSystem.close(device)
    defdelegate list_dir(path), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate mkdir(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem
  end

  defmodule MalformedStatFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def lstat(path) do
      with {:ok, stat} <- FileSystem.lstat(path), do: {:ok, %{stat | inode: -1}}
    end

    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate close(device), to: FileSystem
  end

  defmodule BoundedOnlyFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def read(path) do
      if owner = :persistent_term.get(__MODULE__, nil), do: send(owner, {:staging_unbounded_read, path})
      {:error, :unbounded_read_forbidden}
    end

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

  @device_id <<1::128>>
  @storage_epoch <<2::128>>
  @origin_storage_epoch <<3::128>>

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "checkpoint_hydration_staging_#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn ->
      :persistent_term.erase(BoundedOnlyFileSystem)
      :persistent_term.erase(BlockingReadFileSystem)
      :persistent_term.erase(CleanupMutationFileSystem)
      :persistent_term.erase(CleanupReplacingFileSystem)
      :persistent_term.erase(ReplacingReadFileSystem)
      :persistent_term.erase(RecordingFileSystem)
      :persistent_term.erase(PriorChunkReadFileSystem)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "rejects invalid per-chunk hash before creating durable staging state", %{root: root} do
    attrs = chunk_attrs() |> Map.put(:chunk_hash, <<0::256>>)

    assert {:error, :checkpoint_chunk_hash_mismatch} = Staging.put(root, attrs)
    refute File.exists?(root)
  end

  test "rejects malformed chunk and checkpoint hashes before persistence", %{root: root} do
    attrs = chunk_attrs()

    assert {:error, :invalid_checkpoint_chunk_hash} =
             Staging.put(root, %{attrs | chunk_hash: <<0>>})

    refute File.exists?(root)

    mismatched_checkpoint =
      attrs
      |> Map.put(:checkpoint_hash, <<0::256>>)
      |> with_chunk_hash()

    assert {:error, :checkpoint_hash_mismatch} =
             Staging.put(root, mismatched_checkpoint)

    refute File.exists?(root)
  end

  test "rejects invalid geometry before creating durable staging state", %{root: root} do
    attrs = chunk_attrs() |> Map.put(:chunk_offset, 1) |> with_chunk_hash()

    assert {:error, :invalid_chunk_offset} = Staging.put(root, attrs)
    refute File.exists?(root)
  end

  test "accepts exact maximum geometry and rejects content above 8 MiB before persistence", %{root: root} do
    maximum = Contract.max_checkpoint_content_size()
    maximum_count = Contract.max_checkpoint_chunks()
    final_index = maximum_count - 1
    attrs = chunk_attrs(total_content_length: maximum, chunk_index: final_index)

    assert attrs.chunk_count == maximum_count
    assert attrs.chunk_offset == final_index * Contract.chunk_size()
    assert byte_size(attrs.chunk) == maximum - attrs.chunk_offset

    assert {:ok,
            %{
              total_content_length: ^maximum,
              chunk_count: ^maximum_count,
              missing_ranges: missing_ranges
            }} = Staging.put(root, attrs)

    assert hd(missing_ranges) == %{first_chunk_index: 0, chunk_count: final_index}

    too_large_root = Path.join(root, "too-large")
    too_large = chunk_attrs(total_content_length: maximum + 1)

    assert {:error, :checkpoint_too_large} = Staging.put(too_large_root, too_large)
    refute File.exists?(too_large_root)
  end

  test "durably stages a validated chunk and reports canonical missing ranges", %{root: root} do
    attrs = chunk_attrs()
    expected_length = attrs.total_content_length

    assert {:ok,
            %{
              total_content_length: ^expected_length,
              chunk_count: 1,
              missing_ranges: []
            }} = Staging.put(root, attrs)

    assert {:ok, content} = Staging.assemble(root, transfer(attrs))
    assert content == attrs.chunk

    staging_dir = Staging.path(root, attrs.checkpoint_hash)
    assert File.stat!(staging_dir).mode |> Bitwise.band(0o777) == 0o700

    for path <- [Path.join(staging_dir, "manifest"), Path.join([staging_dir, "chunks", "00000000.chunk"])] do
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    end
  end

  test "stages out of order and reports exact minimal missing ranges", %{root: root} do
    attrs = chunk_attrs(total_content_length: Contract.chunk_size() * 3, chunk_index: 1)

    assert {:ok,
            %{
              total_content_length: total,
              chunk_count: 3,
              missing_ranges: [
                %{first_chunk_index: 0, chunk_count: 1},
                %{first_chunk_index: 2, chunk_count: 1}
              ]
            }} = Staging.put(root, attrs)

    assert total == Contract.chunk_size() * 3
  end

  test "accepts exact chunk replay and rejects conflicting replay", %{root: root} do
    attrs = chunk_attrs()

    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    conflicting =
      attrs
      |> Map.update!(:chunk, fn <<first, rest::binary>> -> <<Bitwise.bxor(first, 1), rest::binary>> end)
      |> with_chunk_hash()

    assert {:error, :checkpoint_hydration_chunk_conflict} = Staging.put(root, conflicting)
  end

  test "rejects a conflicting manifest for the same checkpoint", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    conflicting = attrs |> Map.put(:credential_epoch, attrs.credential_epoch + 1) |> with_chunk_hash()

    assert {:error, :checkpoint_hydration_transfer_conflict} = Staging.put(root, conflicting)
  end

  test "preserves post-rename uncertainty and re-establishes durability on exact replay", %{root: root} do
    attrs = chunk_attrs()
    {:ok, rename_count} = Agent.start_link(fn -> 0 end)

    assert {:error, {:durability_uncertain, {:fault_injected, :renamed, :simulated_power_loss}}} =
             Staging.put(root, attrs,
               fault_injector: fn
                 :renamed ->
                   count = Agent.get_and_update(rename_count, fn count -> {count + 1, count + 1} end)
                   if count == 3, do: {:error, :simulated_power_loss}, else: :ok

                 _stage ->
                   :ok
               end
             )

    assert {:error, {:durability_uncertain, {:fault_injected, :renamed, :replay_requires_sync}}} =
             Staging.put(root, attrs,
               fault_injector: fn
                 :renamed -> {:error, :replay_requires_sync}
                 _stage -> :ok
               end
             )

    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)
    assert {:ok, content} = Staging.assemble(root, transfer(attrs))
    assert content == attrs.chunk
  end

  test "rejects malformed transition timeouts before lock acquisition", %{root: root} do
    attrs = chunk_attrs()

    for invalid <- [-1, 3_600_001, :eventually, "1000"] do
      assert {:error, :invalid_checkpoint_hydration_staging_options} =
               Staging.put(root, attrs, transition_timeout_ms: invalid)

      refute File.exists?(root)
    end
  end

  test "transition timeout kills the lock holder and releases a waiting caller", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)
    :persistent_term.put(BlockingReadFileSystem, self())

    blocked =
      Task.async(fn ->
        Staging.status(root, transfer(attrs),
          file_system: BlockingReadFileSystem,
          transition_timeout_ms: 25
        )
      end)

    assert_receive {:staging_read_blocked, _holder}

    assert {:error, {:durability_uncertain, :checkpoint_hydration_staging_transition_timeout}} =
             Task.await(blocked, 1_000)

    assert {:ok, %{missing_ranges: []}} = Staging.status(root, transfer(attrs))
  end

  test "uses bounded descriptor reads for durable manifests and chunks", %{root: root} do
    attrs = chunk_attrs()
    :persistent_term.put(BoundedOnlyFileSystem, self())

    assert {:ok, %{missing_ranges: []}} =
             Staging.put(root, attrs, file_system: BoundedOnlyFileSystem)

    assert {:ok, content} =
             Staging.assemble(root, transfer(attrs), file_system: BoundedOnlyFileSystem)

    assert content == attrs.chunk
    refute_received {:staging_unbounded_read, _path}
  end

  test "recovers durable missing ranges after caller restart", %{root: root} do
    attrs = chunk_attrs(total_content_length: Contract.chunk_size() * 3, chunk_index: 1)
    assert {:ok, expected} = Staging.put(root, attrs)

    parent = self()

    task =
      Task.async(fn ->
        send(parent, :fresh_staging_caller)
        Staging.status(root, transfer(attrs))
      end)

    assert_receive :fresh_staging_caller
    assert {:ok, ^expected} = Task.await(task)
  end

  test "resumes a chunk whose durable hash sidecar was lost before commit", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    hash_path = staging_chunk_path(root, attrs) <> ".hash"
    File.rm!(hash_path)

    assert {:ok, %{missing_ranges: [%{first_chunk_index: 0, chunk_count: 1}]}} =
             Staging.status(root, transfer(attrs))

    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)
  end

  test "does not reread prior chunk bodies while staging a new chunk", %{root: root} do
    first = chunk_attrs(total_content_length: Contract.chunk_size() * 3, chunk_index: 0)
    second = chunk_attrs(total_content_length: Contract.chunk_size() * 3, chunk_index: 1)
    assert {:ok, _status} = Staging.put(root, first)
    :persistent_term.put(PriorChunkReadFileSystem, self())

    assert {:ok, _status} =
             Staging.put(root, second, file_system: PriorChunkReadFileSystem)

    first_path = staging_chunk_path(root, first)
    refute_received {:staging_bounded_read, ^first_path}
  end

  test "bounds alternating missing chunks to exactly 69 canonical ranges", %{root: root} do
    attrs = chunk_attrs(total_content_length: Contract.max_checkpoint_content_size(), chunk_index: 1)

    for index <- 1..136//2 do
      assert {:ok, _status} =
               Staging.put(root, chunk_attrs_from_transfer(attrs, index))
    end

    assert {:ok, %{chunk_count: 137, missing_ranges: ranges}} =
             Staging.status(root, transfer(attrs))

    assert length(ranges) == 69
    assert hd(ranges) == %{first_chunk_index: 0, chunk_count: 1}
    assert List.last(ranges) == %{first_chunk_index: 136, chunk_count: 1}
  end

  test "removes complete staging state, orphan temps, and durably syncs parents", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    staging_dir = Staging.path(root, attrs.checkpoint_hash)
    chunks_dir = Path.join(staging_dir, "chunks")
    File.write!(Path.join(chunks_dir, "00000000.chunk.tmp.0123456789abcdef"), "orphan")
    File.write!(Path.join(staging_dir, "manifest.tmp.0123456789abcdef"), "orphan")
    flush_mailbox()
    :persistent_term.put(RecordingFileSystem, self())

    assert :ok =
             Staging.remove(root, attrs.checkpoint_hash, file_system: RecordingFileSystem)

    assert sync_events(4) == [chunks_dir, staging_dir, staging_dir, root]
    refute File.exists?(staging_dir)
    assert :ok = Staging.remove(root, attrs.checkpoint_hash)
  end

  test "cleanup preflights the whole tree before deleting any valid entry", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    staging_dir = Staging.path(root, attrs.checkpoint_hash)
    chunks_dir = Path.join(staging_dir, "chunks")
    valid_chunk = Path.join(chunks_dir, "00000000.chunk")
    valid_hash = valid_chunk <> ".hash"
    unexpected = Path.join(chunks_dir, "unexpected")
    File.write!(unexpected, "reject")

    before = Map.new([valid_chunk, valid_hash, unexpected], &{&1, File.read!(&1)})

    assert {:error, :corrupt_checkpoint_hydration_staging} =
             Staging.remove(root, attrs.checkpoint_hash)

    assert Map.new(Map.keys(before), &{&1, File.read!(&1)}) == before
  end

  test "cleanup rejects unrelated names that merely contain a chunk orphan suffix", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    staging_dir = Staging.path(root, attrs.checkpoint_hash)
    chunks_dir = Path.join(staging_dir, "chunks")
    unrelated = Path.join(chunks_dir, "unrelated.chunk.tmp.0123456789abcdef")
    File.write!(unrelated, "must-survive")

    assert {:error, :corrupt_checkpoint_hydration_staging} =
             Staging.remove(root, attrs.checkpoint_hash)

    assert File.read!(unrelated) == "must-survive"
  end

  test "cleanup rejects a late child added after preflight before deleting anything", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    staging_dir = Staging.path(root, attrs.checkpoint_hash)
    chunks_dir = Path.join(staging_dir, "chunks")
    chunk = Path.join(chunks_dir, "00000000.chunk")
    hash = chunk <> ".hash"
    before = Map.new([chunk, hash], &{&1, File.read!(&1)})

    :persistent_term.put(
      CleanupMutationFileSystem,
      {self(), :inject_on_relist, chunks_dir, "00000001.chunk"}
    )

    assert {:error, :corrupt_checkpoint_hydration_staging} =
             Staging.remove(root, attrs.checkpoint_hash, file_system: CleanupMutationFileSystem)

    assert_receive {:cleanup_late_entry_injected, ^chunks_dir}
    assert Map.new(Map.keys(before), &{&1, File.read!(&1)}) == before
  end

  test "cleanup rejects chunk indices outside manifest geometry", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    staging_dir = Staging.path(root, attrs.checkpoint_hash)
    chunks_dir = Path.join(staging_dir, "chunks")
    impossible = Path.join(chunks_dir, "00000001.chunk.tmp.0123456789abcdef")
    File.write!(impossible, "must-survive")

    assert {:error, :corrupt_checkpoint_hydration_staging} =
             Staging.remove(root, attrs.checkpoint_hash)

    assert File.read!(impossible) == "must-survive"
  end

  test "cleanup reports every failure after its first deletion as durability uncertain", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    staging_dir = Staging.path(root, attrs.checkpoint_hash)
    chunks_dir = Path.join(staging_dir, "chunks")
    :persistent_term.put(CleanupMutationFileSystem, {self(), :fail_after_first_remove})

    task =
      Task.async(fn ->
        Staging.remove(root, attrs.checkpoint_hash, file_system: CleanupMutationFileSystem)
      end)

    assert_receive {:cleanup_first_remove_completed, _path, cleanup_pid}
    :persistent_term.put(CleanupMutationFileSystem, {self(), :fail_sync_open, chunks_dir})
    send(cleanup_pid, :continue_cleanup)

    assert {:error, {:durability_uncertain, _reason}} = Task.await(task)
    assert_receive {:cleanup_sync_open_failed, ^chunks_dir}
  end

  test "cleanup rejects an ancestor replaced between preflight and traversal", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    staging_dir = Staging.path(root, attrs.checkpoint_hash)
    chunks_dir = Path.join(staging_dir, "chunks")
    outside = Path.join(root, "outside-race")
    outside_chunk = Path.join(outside, "00000000.chunk")
    File.mkdir!(outside)
    File.write!(outside_chunk, "must-survive")
    :persistent_term.put(CleanupReplacingFileSystem, {self(), chunks_dir, outside})

    assert {:error, :corrupt_checkpoint_hydration_staging} =
             Staging.remove(root, attrs.checkpoint_hash, file_system: CleanupReplacingFileSystem)

    assert_receive {:staging_directory_replaced, ^chunks_dir}
    assert File.read!(outside_chunk) == "must-survive"
  end

  test "cleanup rejects a symlinked staging root without touching its target", %{root: root} do
    attrs = chunk_attrs()
    outside = root <> "-outside"
    outside_staging = Staging.path(outside, attrs.checkpoint_hash)
    outside_chunks = Path.join(outside_staging, "chunks")
    File.mkdir_p!(outside_chunks)
    File.write!(Path.join(outside_staging, "manifest"), "must-survive")
    File.ln_s!(outside, root)

    assert {:error, :corrupt_checkpoint_hydration_staging} =
             Staging.remove(root, attrs.checkpoint_hash)

    assert File.exists?(outside_staging)
    assert File.exists?(outside_chunks)
  end

  test "cleanup rejects a symlinked chunks directory without touching its target", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    staging_dir = Staging.path(root, attrs.checkpoint_hash)
    chunks_dir = Path.join(staging_dir, "chunks")
    outside = Path.join(root, "outside")
    outside_chunk = Path.join(outside, "00000000.chunk")
    File.mkdir!(outside)
    File.write!(outside_chunk, "must-survive")
    File.rm_rf!(chunks_dir)
    File.ln_s!(outside, chunks_dir)

    assert {:error, :corrupt_checkpoint_hydration_staging} =
             Staging.remove(root, attrs.checkpoint_hash)

    assert File.read!(outside_chunk) == "must-survive"
  end

  test "status rejects same-length corrupt durable chunks instead of marking them present", %{root: root} do
    attrs = chunk_attrs(total_content_length: Contract.chunk_size() * 3, chunk_index: 1)
    assert {:ok, _status} = Staging.put(root, attrs)

    <<first, rest::binary>> = attrs.chunk
    File.write!(staging_chunk_path(root, attrs), <<Bitwise.bxor(first, 1), rest::binary>>)

    assert {:error, :checkpoint_hydration_chunk_hash_mismatch} =
             Staging.status(root, transfer(attrs))
  end

  test "rejects malformed filesystem identity metadata", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    assert {:error, :corrupt_checkpoint_hydration_staging} =
             Staging.assemble(root, transfer(attrs), file_system: MalformedStatFileSystem)
  end

  test "rejects a path replaced during a bounded durable read", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    chunk_path = staging_chunk_path(root, attrs)
    :persistent_term.put(ReplacingReadFileSystem, {self(), chunk_path, false})

    assert {:error, :corrupt_checkpoint_hydration_staging} =
             Staging.assemble(root, transfer(attrs), file_system: ReplacingReadFileSystem)

    assert_receive {:staging_path_replaced, _read_size}
  end

  test "rejects truncated durable chunks", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    chunk_path = staging_chunk_path(root, attrs)
    File.write!(chunk_path, binary_part(attrs.chunk, 0, byte_size(attrs.chunk) - 1))

    assert {:error, :corrupt_checkpoint_hydration_chunk} =
             Staging.assemble(root, transfer(attrs))
  end

  test "rejects symlink and nonregular durable manifest or chunk paths", %{root: root} do
    for target <- [:manifest, :chunk], replacement <- [:symlink, :directory] do
      case_root = Path.join(root, "#{target}-#{replacement}")
      attrs = chunk_attrs()
      assert {:ok, %{missing_ranges: []}} = Staging.put(case_root, attrs)

      staging_dir = Staging.path(case_root, attrs.checkpoint_hash)

      path =
        case target do
          :manifest -> Path.join(staging_dir, "manifest")
          :chunk -> Path.join([staging_dir, "chunks", "00000000.chunk"])
        end

      File.rm!(path)

      case replacement do
        :symlink ->
          target_path = Path.join(case_root, "attacker-#{target}")
          File.write!(target_path, attrs.chunk)
          File.ln_s!(target_path, path)

        :directory ->
          File.mkdir!(path)
      end

      assert {:error, :corrupt_checkpoint_hydration_staging} =
               Staging.assemble(case_root, transfer(attrs))
    end
  end

  test "rejects a symlink in place of a durable chunk", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    staging_dir = Staging.path(root, attrs.checkpoint_hash)
    chunk_path = Path.join([staging_dir, "chunks", "00000000.chunk"])
    target_path = Path.join(root, "attacker-content")
    File.write!(target_path, attrs.chunk)
    File.rm!(chunk_path)
    File.ln_s!(target_path, chunk_path)

    assert {:error, :corrupt_checkpoint_hydration_staging} =
             Staging.assemble(root, transfer(attrs))
  end

  test "validates embedded authority against origin rather than target identity", %{root: root} do
    content = runtime_wind_shift_content()
    target_storage_epoch = <<4::128>>

    attrs =
      chunk_attrs(
        content: content,
        kind: :wind_shift,
        schema_version: 2,
        credential_epoch: 9,
        storage_epoch: target_storage_epoch,
        origin_credential_epoch: 7,
        origin_storage_epoch: @storage_epoch
      )

    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)
    assert {:ok, ^content} = Staging.assemble(root, transfer(attrs))

    mismatch_root = Path.join(root, "authority-mismatch")

    mismatch =
      chunk_attrs(
        content: content,
        kind: :wind_shift,
        schema_version: 2,
        credential_epoch: 9,
        storage_epoch: target_storage_epoch,
        origin_credential_epoch: 8,
        origin_storage_epoch: @storage_epoch
      )

    assert {:ok, %{missing_ranges: []}} = Staging.put(mismatch_root, mismatch)

    assert {:error, :checkpoint_authority_mismatch} =
             Staging.assemble(mismatch_root, transfer(mismatch))
  end

  test "validates assembled content hash before returning bytes", %{root: root} do
    attrs = chunk_attrs()
    assert {:ok, %{missing_ranges: []}} = Staging.put(root, attrs)

    {:ok, different_content} =
      Checkpoint.canonical_content(:calibration, 1, %{
        "awa_estimators" => [],
        "aws_estimators" => [],
        "prev_applied" => [],
        "seq" => 1,
        "stw_estimators" => []
      })

    assert byte_size(different_content) == attrs.total_content_length

    staging_dir = Staging.path(root, attrs.checkpoint_hash)
    chunk_path = Path.join([staging_dir, "chunks", "00000000.chunk"])
    File.write!(chunk_path, different_content)

    assert {:error, :checkpoint_hydration_chunk_hash_mismatch} =
             Staging.assemble(root, transfer(attrs))
  end

  defp chunk_attrs(opts \\ []) do
    content = Keyword.get_lazy(opts, :content, &calibration_content/0)
    kind = Keyword.get(opts, :kind, :calibration)
    schema_version = Keyword.get(opts, :schema_version, 1)
    {:ok, content_hash} = Checkpoint.content_hash(kind, schema_version, content)

    common = %{
      device_id: Keyword.get(opts, :device_id, @device_id),
      credential_epoch: Keyword.get(opts, :credential_epoch, 7),
      storage_epoch: Keyword.get(opts, :storage_epoch, @storage_epoch),
      origin_credential_epoch: Keyword.get(opts, :origin_credential_epoch, 6),
      origin_storage_epoch: Keyword.get(opts, :origin_storage_epoch, @origin_storage_epoch),
      sequence: 1,
      kind: kind,
      schema_version: schema_version,
      source_generation: 0,
      parent_hash: Record.genesis_parent(),
      content_hash: content_hash
    }

    {:ok, checkpoint_hash} =
      Checkpoint.hash(%{
        device_id: common.device_id,
        credential_epoch: common.origin_credential_epoch,
        storage_epoch: common.origin_storage_epoch,
        sequence: common.sequence,
        kind: common.kind,
        schema_version: common.schema_version,
        source_generation: common.source_generation,
        parent_hash: common.parent_hash,
        content_hash: common.content_hash
      })

    total_content_length = Keyword.get(opts, :total_content_length, byte_size(content))
    chunk_index = Keyword.get(opts, :chunk_index, 0)
    chunk_size = RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.chunk_size()
    chunk_count = div(total_content_length + chunk_size - 1, chunk_size)
    chunk_offset = chunk_index * chunk_size
    chunk_length = min(chunk_size, total_content_length - chunk_offset)

    chunk =
      Keyword.get(opts, :chunk, if(chunk_count == 1, do: content, else: :binary.copy(<<chunk_index>>, chunk_length)))

    common
    |> Map.merge(%{
      checkpoint_hash: checkpoint_hash,
      total_content_length: total_content_length,
      chunk_index: chunk_index,
      chunk_count: chunk_count,
      chunk_offset: chunk_offset,
      chunk: chunk
    })
    |> with_chunk_hash()
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
    assert {:ok, wire_content} = WindShiftRuntime.project(snapshot)
    assert {:ok, content} = Checkpoint.canonical_content(:wind_shift, 2, wire_content)
    content
  end

  defp flush_mailbox do
    receive do
      _message -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp sync_events(count) do
    Enum.map(1..count, fn _index ->
      receive do
        {:staging_synced, path} -> path
      after
        1_000 -> flunk("timed out waiting for staging directory sync")
      end
    end)
  end

  defp calibration_content do
    {:ok, content} =
      Checkpoint.canonical_content(:calibration, 1, %{
        "awa_estimators" => [],
        "aws_estimators" => [],
        "prev_applied" => [],
        "seq" => 0,
        "stw_estimators" => []
      })

    content
  end

  defp staging_chunk_path(root, attrs) do
    Path.join([
      Staging.path(root, attrs.checkpoint_hash),
      "chunks",
      String.pad_leading(Integer.to_string(attrs.chunk_index), 8, "0") <> ".chunk"
    ])
  end

  defp chunk_attrs_from_transfer(attrs, index) do
    chunk_offset = index * Contract.chunk_size()
    chunk_length = min(Contract.chunk_size(), attrs.total_content_length - chunk_offset)

    attrs
    |> transfer()
    |> Map.merge(%{
      chunk_index: index,
      chunk_offset: chunk_offset,
      chunk: :binary.copy(<<index>>, chunk_length)
    })
    |> with_chunk_hash()
  end

  defp with_chunk_hash(attrs) do
    {:ok, chunk_hash} =
      Checkpoint.chunk_hash(
        Map.take(attrs, [
          :checkpoint_hash,
          :total_content_length,
          :chunk_index,
          :chunk_count,
          :chunk_offset,
          :chunk
        ])
      )

    Map.put(attrs, :chunk_hash, chunk_hash)
  end

  defp transfer(attrs), do: Map.drop(attrs, [:chunk, :chunk_hash, :chunk_index, :chunk_offset])
end
