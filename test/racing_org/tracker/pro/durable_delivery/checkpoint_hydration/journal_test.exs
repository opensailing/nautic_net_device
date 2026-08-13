defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.JournalTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.Journal
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint

  @device_id Base.decode16!("0f1e2d3c4b5a69788796a5b4c3d2e1f0", case: :lower)
  @storage_epoch Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @origin_storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @session_incarnation Base.decode16!("102132435465768798a9bacbdcedfe0f", case: :lower)
  @transaction_id Base.decode16!("98badcfe1032547698badcfe10325476", case: :lower)

  defmodule BlockingReadFileSystem do
    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def read(path) do
      case :persistent_term.get(__MODULE__, nil) do
        pid when is_pid(pid) ->
          send(pid, {:journal_read_started, self()})

          receive do
            :continue_journal_read -> FileSystem.read(path)
          end

        _other ->
          FileSystem.read(path)
      end
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

  test "classifies read and atomic persistence failures deterministically", %{path: path} do
    directory_path = Path.join(path, "not-a-file")
    File.mkdir_p!(directory_path)
    assert {:error, {:checkpoint_hydration_journal_io, :eisdir}} = Journal.read(directory_path)

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

  defp checkpoint_hash, do: checkpoint_hash(hydration_attributes())

  defp checkpoint_hash(attrs) do
    {:ok, hash} =
      Checkpoint.hash(%{
        device_id: @device_id,
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
    :crypto.hash(:sha256, Atom.to_string(state)) |> binary_part(0, 16)
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
