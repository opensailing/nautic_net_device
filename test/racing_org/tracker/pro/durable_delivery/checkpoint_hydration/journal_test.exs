defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.JournalTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.Calibration.Observer, as: CalibrationObserver
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.Journal
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

  @device_id Base.decode16!("0f1e2d3c4b5a69788796a5b4c3d2e1f0", case: :lower)
  @storage_epoch Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @origin_storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @replacement_storage_epoch Base.decode16!("102132435465768798a9bacbdcedfe0f", case: :lower)
  @session_incarnation Base.decode16!("102132435465768798a9bacbdcedfe0f", case: :lower)
  @transaction_id Base.decode16!("98badcfe1032547698badcfe10325476", case: :lower)

  defmodule BlockingReadFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def lstat(path) do
      case :persistent_term.get(__MODULE__, nil) do
        pid when is_pid(pid) ->
          :persistent_term.erase(__MODULE__)
          send(pid, {:journal_read_started, self()})

          receive do
            :continue_journal_read -> FileSystem.lstat(path)
          end

        _other ->
          FileSystem.lstat(path)
      end
    end

    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
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

  defmodule IncompleteBoundedReadFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def read(path) do
      if owner = :persistent_term.get(__MODULE__, nil), do: send(owner, :journal_path_read_invoked)
      FileSystem.read(path)
    end
  end

  defmodule BoundedReadFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate close(device), to: FileSystem
  end

  defmodule ProbedBoundedReadFileSystem do
    alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.Journal
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def lstat(path) do
      with {:ok, stat} <- FileSystem.lstat(path) do
        {:ok, %{stat | size: Journal.max_encoded_size()}}
      end
    end

    def file_info(device) do
      with {:ok, stat} <- FileSystem.file_info(device) do
        {:ok, %{stat | size: Journal.max_encoded_size()}}
      end
    end

    def read(device, count) do
      case :persistent_term.get(__MODULE__, nil) do
        {owner, counter} ->
          :atomics.add(counter, 1, 1)
          :atomics.add(counter, 2, count)
          send(owner, {:journal_descriptor_read, count})

        _other ->
          :ok
      end

      FileSystem.read(device, count)
    end

    defdelegate open(path, modes), to: FileSystem
    defdelegate close(device), to: FileSystem
  end

  defmodule FaultyBoundedReadFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def read(device, count) do
      case :persistent_term.get(__MODULE__) do
        {owner, :oversized_chunk} ->
          send(owner, {:journal_read_fault, :oversized_chunk, count})
          {:ok, :binary.copy(<<0xAA>>, count + 1)}

        {owner, :premature_eof} ->
          send(owner, {:journal_read_fault, :premature_eof, count})
          :eof

        {_owner, _mode} ->
          FileSystem.read(device, count)
      end
    end

    def file_info(device) do
      case :persistent_term.get(__MODULE__) do
        {_owner, :malformed_file_info} -> {:ok, %File.Stat{size: -1, type: :regular}}
        {_owner, _mode} -> FileSystem.file_info(device)
      end
    end

    def lstat(path) do
      case :persistent_term.get(__MODULE__) do
        {_owner, :malformed_lstat} -> {:ok, %File.Stat{size: -1, type: :regular}}
        {_owner, _mode} -> FileSystem.lstat(path)
      end
    end

    defdelegate open(path, modes), to: FileSystem

    def close(device) do
      {owner, mode} = :persistent_term.get(__MODULE__)
      result = FileSystem.close(device)
      send(owner, {:journal_descriptor_closed, mode, result})
      result
    end
  end

  defmodule ReplacingBoundedReadFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def read(device, count) do
      result = FileSystem.read(device, count)

      case {:persistent_term.get(__MODULE__), result} do
        {{owner, path, replacements} = state, {:ok, bytes}} when replacements == :always or replacements > 0 ->
          remaining = if replacements == :always, do: :always, else: replacements - 1
          :persistent_term.put(__MODULE__, put_elem(state, 2, remaining))
          replacement = path <> ".replacement.#{System.unique_integer([:positive])}"
          File.write!(replacement, File.read!(path))
          File.rename!(replacement, path)
          send(owner, {:journal_path_replaced, byte_size(bytes)})

        _other ->
          :ok
      end

      result
    end

    defdelegate file_info(device), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate close(device), to: FileSystem
  end

  defmodule SymlinkSwapFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    defdelegate read(device, count), to: FileSystem
    defdelegate file_info(device), to: FileSystem

    def lstat(path) do
      case :persistent_term.get(__MODULE__, nil) do
        nil ->
          FileSystem.lstat(path)

        {owner, target} ->
          result = FileSystem.lstat(path)
          :persistent_term.erase(__MODULE__)
          :persistent_term.put({__MODULE__, :owner}, owner)
          File.rename!(path, path <> ".before-swap")
          File.ln_s!(target, path)
          send(owner, :journal_path_replaced_by_symlink)
          result
      end
    end

    defdelegate open(path, modes), to: FileSystem

    def close(device) do
      owner = :persistent_term.get({__MODULE__, :owner})
      result = FileSystem.close(device)
      send(owner, {:journal_symlink_descriptor_closed, result})
      result
    end
  end

  setup do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    base = Path.join(System.tmp_dir!(), "checkpoint_hydration_journal_#{nonce}")
    path = Path.join(base, "transition.journal")
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base, path: path}
  end

  test "writes and reads an exact prepared transition", %{path: path} do
    record = transition()

    assert :ok = Journal.write(path, record)
    assert {:ok, ^record} = Journal.read(path)
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700
  end

  test "fails closed when an adapter cannot provide bounded descriptor reads", %{path: path} do
    assert :ok = Journal.write(path, transition())
    :persistent_term.put(IncompleteBoundedReadFileSystem, self())
    on_exit(fn -> :persistent_term.erase(IncompleteBoundedReadFileSystem) end)

    assert {:error, :checkpoint_hydration_journal_bounded_read_unsupported} =
             Journal.read(path, file_system: IncompleteBoundedReadFileSystem)

    refute_receive :journal_path_read_invoked
  end

  test "reads through an adapter exposing only the bounded descriptor callbacks", %{path: path} do
    record = transition()
    assert :ok = Journal.write(path, record)

    assert {:ok, ^record} = Journal.read(path, file_system: BoundedReadFileSystem)
  end

  test "reads no more than max encoded size plus one through bounded chunks", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :binary.copy(<<0>>, Journal.max_encoded_size() + 1))
    counter = :atomics.new(2, signed: false)
    :persistent_term.put(ProbedBoundedReadFileSystem, {self(), counter})
    on_exit(fn -> :persistent_term.erase(ProbedBoundedReadFileSystem) end)

    assert {:error, :corrupt_checkpoint_hydration_journal} =
             Journal.read(path, file_system: ProbedBoundedReadFileSystem)

    assert :atomics.get(counter, 1) > 200
    assert :atomics.get(counter, 2) == Journal.max_encoded_size() + 1
    assert_receive {:journal_descriptor_read, count}
    assert count > 0
    assert count <= 16_384
  end

  test "binds Wind runtime authority to hydration origin while permitting target rotation", %{
    path: path
  } do
    content = runtime_wind_shift_content()
    assert {:ok, content} = Checkpoint.encode_content(:wind_shift, 2, content)

    valid =
      transition()
      |> put_in([:target, :credential_epoch], 8)
      |> put_in([:target, :storage_epoch], @replacement_storage_epoch)
      |> Map.put(
        :hydration,
        hydration(
          kind: :wind_shift,
          schema_version: 2,
          origin_credential_epoch: 7,
          origin_storage_epoch: @storage_epoch,
          content: content,
          content_hash: checkpoint_content_hash(:wind_shift, 2, content)
        )
      )
      |> rebuild_hydration_hash()

    assert :ok = Journal.write(path, valid)
    assert {:ok, ^valid} = Journal.read(path)

    assert :ok = Journal.remove(path)

    for invalid <- [
          valid
          |> put_in([:target, :device_id], <<0xAA::128>>)
          |> rebuild_hydration_hash(),
          valid
          |> put_in([:hydration, :origin_credential_epoch], 8)
          |> rebuild_hydration_hash(),
          valid
          |> put_in([:hydration, :origin_storage_epoch], @origin_storage_epoch)
          |> rebuild_hydration_hash()
        ] do
      assert {:error, :invalid_checkpoint_hydration_journal} = Journal.write(path, invalid)
      refute File.exists?(path)
    end
  end

  test "advances prepared to head-committed and permits exact idempotent rewrites", %{path: path} do
    prepared = transition()
    committed = %{prepared | phase: :head_committed}

    assert :ok = Journal.write(path, prepared)
    assert :ok = Journal.write(path, prepared)
    assert :ok = Journal.write(path, committed)
    assert :ok = Journal.write(path, committed)
    assert {:ok, ^committed} = Journal.read(path)
  end

  test "rejects regression or replacement of an existing transition", %{path: path} do
    prepared = transition()
    committed = %{prepared | phase: :head_committed}

    assert :ok = Journal.write(path, prepared)

    for replacement <- [
          %{prepared | transaction_id: <<0xAA::128>>},
          %{prepared | session_incarnation: <<0xBB::128>>},
          %{prepared | session_generation: prepared.session_generation + 1},
          put_in(prepared, [:target, :credential_epoch], 8),
          prepared
          |> put_in([:expected_head, :state], :accepted)
          |> put_in([:expected_head, :checkpoint_hash], <<0xCC::256>>),
          %{prepared | hydration: hydration(revision: 10)}
        ] do
      assert {:error, :checkpoint_hydration_transition_conflict} = Journal.write(path, replacement)
      assert {:ok, ^prepared} = Journal.read(path)
    end

    assert :ok = Journal.write(path, committed)

    assert {:error, :checkpoint_hydration_phase_regression} = Journal.write(path, prepared)
    assert {:ok, ^committed} = Journal.read(path)
  end

  test "serializes concurrent create-or-replace transitions", %{path: path} do
    :persistent_term.put(BlockingReadFileSystem, self())
    on_exit(fn -> :persistent_term.erase(BlockingReadFileSystem) end)

    first_record = transition()
    second_record = %{transition() | transaction_id: <<0xDD::128>>}

    first =
      Task.async(fn ->
        Journal.write(path, first_record, file_system: BlockingReadFileSystem)
      end)

    assert_receive {:journal_read_started, first_reader}

    second = Task.async(fn -> Journal.write(path, second_record) end)
    assert Task.yield(second, 100) == nil

    send(first_reader, :continue_journal_read)
    assert :ok = Task.await(first, 2_000)
    assert {:error, :checkpoint_hydration_transition_conflict} = Task.await(second, 2_000)
    assert {:ok, ^first_record} = Journal.read(path)
  end

  test "durability success follows rename and parent-directory sync", %{path: path} do
    test_pid = self()

    assert :ok =
             Journal.write(path, transition(),
               temp_suffix: fn -> "0123456789abcdef" end,
               fault_injector: fn
                 :renamed ->
                   send(test_pid, :journal_renamed)
                   :ok

                 :parent_synced ->
                   send(test_pid, :journal_parent_synced)
                   :ok

                 _stage ->
                   :ok
               end
             )

    assert_receive :journal_renamed
    assert_receive :journal_parent_synced
  end

  test "returns durability uncertainty after the journal rename", %{path: path} do
    assert {:error, {:durability_uncertain, {:fault_injected, :renamed, :simulated_power_loss}}} =
             Journal.write(path, transition(), fault_injector: fail_at(:renamed))

    assert {:ok, record} = Journal.read(path)
    assert record == transition()
  end

  test "removes durably and treats durable absence as idempotent", %{path: path} do
    assert :ok = Journal.write(path, transition())
    assert :ok = Journal.remove(path)
    assert :empty = Journal.read(path)
    assert :ok = Journal.remove(path)
  end

  test "classifies removal uncertainty after unlink and preserves absence", %{path: path} do
    assert :ok = Journal.write(path, transition())

    assert {:error, {:durability_uncertain, {:fault_injected, :removed, :simulated_power_loss}}} =
             Journal.remove(path, fault_injector: fail_at(:removed))

    assert :empty = Journal.read(path)
  end

  test "closes every record and nested envelope key set", %{path: path} do
    invalid_records = [
      Map.put(transition(), :metadata, %{}),
      put_in(transition(), [:target, :metadata], %{}),
      put_in(transition(), [:expected_head, :extra], true),
      put_in(transition(), [:hydration, :payload], <<1>>)
    ]

    for invalid <- invalid_records do
      assert {:error, :invalid_checkpoint_hydration_journal} = Journal.write(path, invalid)
      refute File.exists?(path)
    end
  end

  test "rejects process terms and zero or malformed incarnation identifiers", %{path: path} do
    for invalid <- [
          %{transition() | transaction_id: <<0::128>>},
          %{transition() | transaction_id: <<1, 2>>},
          %{transition() | session_incarnation: <<0::128>>},
          %{transition() | session_incarnation: self()},
          %{transition() | session_incarnation: make_ref()},
          %{transition() | session_incarnation: fn -> :not_durable end},
          %{transition() | session_generation: -1}
        ] do
      assert {:error, :invalid_checkpoint_hydration_journal} = Journal.write(path, invalid)
      refute File.exists?(path)
    end
  end

  test "rejects malformed current target identity", %{path: path} do
    for invalid <- [
          put_in(transition(), [:target, :device_id], <<0::128>>),
          put_in(transition(), [:target, :device_id], <<1, 2>>),
          put_in(transition(), [:target, :credential_epoch], -1),
          put_in(transition(), [:target, :credential_epoch], 0x1_0000_0000),
          put_in(transition(), [:target, :storage_epoch], <<0::128>>),
          put_in(transition(), [:target, :storage_epoch], self())
        ] do
      assert {:error, :invalid_checkpoint_hydration_journal} = Journal.write(path, invalid)
      refute File.exists?(path)
    end
  end

  test "rejects malformed expected target-head state and hash", %{path: path} do
    for invalid <- [
          put_in(transition(), [:expected_head, :state], :unknown),
          put_in(transition(), [:expected_head, :checkpoint_hash], <<1, 2>>),
          transition()
          |> put_in([:expected_head, :state], :accepted)
          |> put_in([:expected_head, :checkpoint_hash], Record.genesis_parent()),
          transition()
          |> put_in([:expected_head, :state], :corrupt)
          |> put_in([:expected_head, :checkpoint_hash], Record.genesis_parent())
        ] do
      assert {:error, :invalid_checkpoint_hydration_journal} = Journal.write(path, invalid)
      refute File.exists?(path)
    end
  end

  test "accepts every public expected target-head state with its exact hash rules", %{path: path} do
    for state <- [:accepted, :local_unaccepted, :fenced, :corrupt] do
      expected = %{state: state, checkpoint_hash: <<0xAA::256>>}
      record = %{transition() | transaction_id: transaction_id(state), expected_head: expected}
      current_path = path <> ".#{state}"

      assert :ok = Journal.write(current_path, record)
      assert {:ok, ^record} = Journal.read(current_path)
    end
  end

  test "preserves the complete stable-origin hydration envelope", %{path: path} do
    record = transition()

    assert :ok = Journal.write(path, record)
    assert {:ok, restored} = Journal.read(path)

    assert restored.hydration == record.hydration
    assert restored.hydration.origin_credential_epoch == 3
    assert restored.hydration.origin_storage_epoch == @origin_storage_epoch
    assert restored.hydration.content_hash == content_hash()
    assert restored.hydration.checkpoint_hash == checkpoint_hash()
    assert restored.hydration.parent_hash == Record.genesis_parent()
  end

  test "writes and explicitly reopens every exact runtime schema", %{path: path} do
    for {{kind, schema_version, content}, index} <- Enum.with_index(runtime_schema_fixtures(), 1) do
      current_path = path <> ".runtime.#{kind}"
      assert {:ok, canonical} = Checkpoint.canonical_content(kind, schema_version, content)
      content_hash = checkpoint_content_hash(kind, schema_version, canonical)

      origin =
        if kind == :wind_shift,
          do: [origin_credential_epoch: 7, origin_storage_epoch: @storage_epoch],
          else: []

      record =
        transition()
        |> Map.put(:transaction_id, transaction_id({kind, schema_version}))
        |> put_in(
          [:hydration],
          hydration(
            origin ++
              [
                kind: kind,
                schema_version: schema_version,
                revision: index,
                source_generation: 88 + index,
                content: canonical,
                content_hash: content_hash
              ]
          )
        )

      assert :ok = Journal.write(current_path, record)
      assert {:ok, ^record} = Journal.read(current_path)
    end
  end

  test "rejects unknown kinds, schema versions, malformed hashes, and excessive content", %{path: path} do
    invalid_records = [
      put_in(transition(), [:hydration, :kind], :telemetry),
      put_in(transition(), [:hydration, :schema_version], 2),
      put_in(transition(), [:hydration, :content_hash], <<1, 2>>),
      put_in(transition(), [:hydration, :checkpoint_hash], <<1, 2>>),
      put_in(transition(), [:hydration, :parent_hash], <<1, 2>>),
      put_in(transition(), [:hydration, :content], :binary.copy(<<0>>, 65_328))
    ]

    for invalid <- invalid_records do
      assert {:error, :invalid_checkpoint_hydration_journal} = Journal.write(path, invalid)
      refute File.exists?(path)
    end
  end

  test "persists a schema-valid hydration beyond the single-frame carriage cap", %{path: path} do
    content = large_polar_content()
    assert {:ok, canonical} = Checkpoint.canonical_content(:polar, 2, content)
    assert byte_size(canonical) > Contract.max_checkpoint_size()
    assert byte_size(canonical) <= Contract.max_checkpoint_content_size()

    content_hash = checkpoint_content_hash(:polar, 2, canonical)

    hydration =
      hydration(
        kind: :polar,
        schema_version: 2,
        content: canonical,
        content_hash: content_hash
      )

    record = put_in(transition(), [:hydration], hydration)

    assert :ok = Journal.write(path, record)
    assert {:ok, ^record} = Journal.read(path)
  end

  test "persists and exactly reopens canonical hydration near the semantic cap", %{path: path} do
    semantic_cap = Contract.max_checkpoint_content_size()
    content = near_semantic_cap_polar_content()

    assert {:ok, canonical} = Checkpoint.canonical_content(:polar, 2, content)
    assert byte_size(canonical) > semantic_cap - 262_144
    assert byte_size(canonical) <= semantic_cap

    content_hash = checkpoint_content_hash(:polar, 2, canonical)

    hydration =
      hydration(
        kind: :polar,
        schema_version: 2,
        content: canonical,
        content_hash: content_hash
      )

    record = put_in(transition(), [:hydration], hydration)

    assert :ok = Journal.write(path, record)

    persisted = File.read!(path)
    assert byte_size(canonical) == 8_285_599
    assert byte_size(persisted) == 8_286_277
    assert byte_size(persisted) > semantic_cap - 262_144
    assert byte_size(persisted) <= Journal.max_encoded_size()

    assert {:ok, reopened} = Journal.read(path)
    assert reopened.hydration.content === canonical
    assert reopened.hydration.content_hash === record.hydration.content_hash
    assert reopened.hydration.checkpoint_hash === record.hydration.checkpoint_hash
    assert reopened === record
  end

  test "rejects noncanonical content and hashes that do not bind the envelope", %{path: path} do
    canonical = content_bytes()
    noncanonical = canonical <> <<0>>

    for invalid <- [
          put_in(transition(), [:hydration, :content], noncanonical),
          put_in(transition(), [:hydration, :content_hash], :binary.copy(<<0xA1>>, 32)),
          put_in(transition(), [:hydration, :checkpoint_hash], :binary.copy(<<0xB2>>, 32)),
          put_in(transition(), [:hydration, :revision], 0),
          put_in(transition(), [:hydration, :source_generation], -1)
        ] do
      assert {:error, :invalid_checkpoint_hydration_journal} = Journal.write(path, invalid)
      refute File.exists?(path)
    end
  end

  test "classifies persisted framing, trailing bytes, and noncanonical external terms as corruption", %{
    path: path
  } do
    assert :ok = Journal.write(path, transition())
    canonical = File.read!(path)

    corruptions = [
      canonical <> <<0xAA>>,
      :erlang.term_to_binary({2, :checkpoint_hydration_journal, transition()}),
      :erlang.term_to_binary({1, :other_journal, transition()}),
      :erlang.term_to_binary({1, :checkpoint_hydration_journal, transition()}, compressed: 9),
      noncanonical_external_term(canonical)
    ]

    for corruption <- corruptions do
      File.write!(path, corruption)
      assert {:error, :corrupt_checkpoint_hydration_journal} = Journal.read(path)
    end
  end

  test "rejects persisted PID, function, and reference terms safely", %{path: path} do
    for forbidden <- [self(), fn -> :unsafe end, make_ref()] do
      bytes =
        :erlang.term_to_binary(
          {1, :checkpoint_hydration_journal, %{transition() | session_incarnation: forbidden}},
          minor_version: 2
        )

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
      assert {:error, :corrupt_checkpoint_hydration_journal} = Journal.read(path)
    end
  end

  test "rejects oversized and heap-expanding terms inside a bounded decoder", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :binary.copy(<<0>>, Journal.max_encoded_size() + 1))
    assert {:error, :corrupt_checkpoint_hydration_journal} = Journal.read(path)

    entries = 300_000
    expanding_term = <<131, 108, entries::32, :binary.copy(<<106>>, entries)::binary, 106>>
    File.write!(path, expanding_term)

    task = Task.async(fn -> Journal.read(path) end)
    assert {:error, :corrupt_checkpoint_hydration_journal} = Task.await(task, 2_000)
  end

  test "rejects non-regular paths and a symlink substituted after lstat", %{path: path} do
    directory_path = path <> ".directory"
    File.mkdir_p!(directory_path)
    assert {:error, :corrupt_checkpoint_hydration_journal} = Journal.read(directory_path)

    assert :ok = Journal.write(path, transition())
    target_path = path <> ".target"
    File.cp!(path, target_path)
    File.rm!(path)
    File.ln_s!(target_path, path)
    assert {:error, :corrupt_checkpoint_hydration_journal} = Journal.read(path)

    File.rm!(path)
    File.cp!(target_path, path)
    :persistent_term.put(SymlinkSwapFileSystem, {self(), target_path})

    on_exit(fn ->
      :persistent_term.erase(SymlinkSwapFileSystem)
      :persistent_term.erase({SymlinkSwapFileSystem, :owner})
    end)

    assert {:error, :corrupt_checkpoint_hydration_journal} =
             Journal.read(path, file_system: SymlinkSwapFileSystem)

    assert_receive :journal_path_replaced_by_symlink
    assert_receive {:journal_symlink_descriptor_closed, :ok}
  end

  test "closes descriptors for malformed metadata, premature eof, and oversized chunks", %{path: path} do
    assert :ok = Journal.write(path, transition())

    for mode <- [:malformed_file_info, :premature_eof, :oversized_chunk] do
      :persistent_term.put(FaultyBoundedReadFileSystem, {self(), mode})

      assert {:error, expected} = Journal.read(path, file_system: FaultyBoundedReadFileSystem)

      assert expected in [
               :corrupt_checkpoint_hydration_journal,
               {:checkpoint_hydration_journal_io, :invalid_file_info_response},
               {:checkpoint_hydration_journal_io, :premature_eof},
               {:checkpoint_hydration_journal_io, :invalid_read_response}
             ]

      assert_receive {:journal_descriptor_closed, ^mode, :ok}
    end

    :persistent_term.erase(FaultyBoundedReadFileSystem)
  end

  test "retries benign path replacement and fails closed when the path never stabilizes", %{path: path} do
    record = transition()
    assert :ok = Journal.write(path, record)
    :persistent_term.put(ReplacingBoundedReadFileSystem, {self(), path, 1})
    on_exit(fn -> :persistent_term.erase(ReplacingBoundedReadFileSystem) end)

    assert {:ok, ^record} = Journal.read(path, file_system: ReplacingBoundedReadFileSystem)
    assert_receive {:journal_path_replaced, _bytes}

    :persistent_term.put(ReplacingBoundedReadFileSystem, {self(), path, :always})

    assert {:error, {:checkpoint_hydration_journal_io, :file_changed_during_read}} =
             Journal.read(path, file_system: ReplacingBoundedReadFileSystem)
  end

  test "does not convert a changed-read retry ending in absence into empty", %{path: path} do
    assert :ok = Journal.write(path, transition())
    :persistent_term.put(ReplacingBoundedReadFileSystem, {self(), path, 1})
    on_exit(fn -> :persistent_term.erase(ReplacingBoundedReadFileSystem) end)

    task = Task.async(fn -> Journal.read(path, file_system: ReplacingBoundedReadFileSystem) end)
    assert_receive {:journal_path_replaced, _bytes}
    File.rm!(path)

    assert {:error, {:checkpoint_hydration_journal_io, :enoent}} = Task.await(task, 2_000)
  end

  test "classifies read and atomic persistence failures deterministically", %{path: path} do
    write_path = path <> ".write"

    assert {:error, {:pre_rename, _reason}} =
             Journal.write(write_path, transition(), fault_injector: fail_at(:temp_written))

    assert :empty = Journal.read(write_path)
  end

  defp transition do
    %{
      version: 1,
      phase: :prepared,
      transaction_id: @transaction_id,
      session_incarnation: @session_incarnation,
      session_generation: 42,
      target: %{
        device_id: @device_id,
        credential_epoch: 7,
        storage_epoch: @storage_epoch
      },
      expected_head: %{
        state: :absent,
        checkpoint_hash: Record.genesis_parent()
      },
      hydration: hydration()
    }
  end

  defp hydration(overrides \\ []) do
    attrs =
      Enum.into(overrides, %{
        kind: :calibration,
        schema_version: 1,
        origin_credential_epoch: 3,
        origin_storage_epoch: @origin_storage_epoch,
        revision: 9,
        source_generation: 88,
        parent_hash: Record.genesis_parent(),
        content_hash: content_hash(),
        content: content_bytes()
      })

    Map.put(attrs, :checkpoint_hash, checkpoint_hash(attrs))
  end

  defp content do
    %{
      "awa_estimators" => [],
      "aws_estimators" => [],
      "prev_applied" => [],
      "seq" => 0,
      "stw_estimators" => []
    }
  end

  defp content_bytes do
    {:ok, bytes} = Checkpoint.encode_content(:calibration, 1, content())
    bytes
  end

  defp content_hash do
    {:ok, hash} = Checkpoint.content_hash(:calibration, 1, content_bytes())
    hash
  end

  defp checkpoint_content_hash(kind, schema_version, content) when is_binary(content) do
    assert {:ok, hash} = Checkpoint.content_hash(kind, schema_version, content),
           "expected #{kind} v#{schema_version} runtime fixture to be canonical"

    hash
  end

  defp checkpoint_content_hash(kind, schema_version, content) do
    assert {:ok, canonical} = Checkpoint.canonical_content(kind, schema_version, content),
           "expected #{kind} v#{schema_version} runtime fixture to be schema-valid"

    checkpoint_content_hash(kind, schema_version, canonical)
  end

  defp runtime_schema_fixtures do
    [
      {:calibration, 2, runtime_calibration_content()},
      {:polar, 3, runtime_polar_content()},
      {:wind_shift, 2, runtime_wind_shift_content()}
    ]
  end

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

    snapshot = %{
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

    assert {:ok, content} = PolarRuntime.project(snapshot)
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

  defp large_polar_content, do: polar_content(600, 51.4444, 0.05)

  defp near_semantic_cap_polar_content, do: polar_content(36_500, 65_535.0, 1.0)

  defp polar_content(cell_count, max_tws_mps, tws_width_mps) do
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
      "max_tws_mps" => max_tws_mps,
      "p" => 0.9,
      "twa_width_deg" => 2.5,
      "tws_width_mps" => tws_width_mps
    }
  end

  defp rebuild_hydration_hash(record) do
    put_in(
      record,
      [:hydration, :checkpoint_hash],
      checkpoint_hash(record.hydration, record.target.device_id)
    )
  end

  defp checkpoint_hash, do: checkpoint_hash(hydration_attributes())
  defp checkpoint_hash(attrs), do: checkpoint_hash(attrs, @device_id)

  defp checkpoint_hash(attrs, device_id) do
    {:ok, hash} =
      Checkpoint.hash(%{
        device_id: device_id,
        credential_epoch: attrs.origin_credential_epoch,
        storage_epoch: attrs.origin_storage_epoch,
        sequence: attrs.revision,
        kind: attrs.kind,
        schema_version: attrs.schema_version,
        source_generation: attrs.source_generation,
        parent_hash: attrs.parent_hash,
        content_hash: attrs.content_hash
      })

    hash
  end

  defp hydration_attributes do
    %{
      origin_credential_epoch: 3,
      origin_storage_epoch: @origin_storage_epoch,
      revision: 9,
      kind: :calibration,
      schema_version: 1,
      source_generation: 88,
      parent_hash: Record.genesis_parent(),
      content_hash: content_hash()
    }
  end

  defp transaction_id(state) do
    :crypto.hash(:sha256, :erlang.term_to_binary(state, [:deterministic])) |> binary_part(0, 16)
  end

  defp fail_at(stage) do
    fn
      ^stage -> {:error, :simulated_power_loss}
      _other -> :ok
    end
  end

  defp noncanonical_external_term(canonical) do
    # Canonical encoding uses SMALL_TUPLE_EXT for the three-element root tuple.
    # LARGE_TUPLE_EXT is semantically identical but not byte-canonical.
    <<131, 104, 3, rest::binary>> = canonical
    <<131, 105, 0, 0, 0, 3, rest::binary>>
  end
end
