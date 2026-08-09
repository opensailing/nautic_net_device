defmodule RacingOrg.Tracker.Pro.DesiredState.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DesiredState.Store
  alias RacingOrg.Tracker.Pro.DesiredStateTestSupport, as: DS
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Canonical, Manifest, Section}
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

  defmodule ReadFaultFileSystem do
    @behaviour FileSystem

    def read(path) do
      if Process.get({__MODULE__, :read_fault_path}) == path do
        {:error, :eacces}
      else
        FileSystem.read(path)
      end
    end

    defdelegate mkdir_p(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
    defdelegate remove(path), to: FileSystem
  end

  setup do
    base = Path.join(System.tmp_dir!(), "desired_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)

    %{base: base, store: Store.new(base_dir: base, storage_epoch: DS.storage_epoch())}
  end

  test "stages an immutable complete manifest under an injectable generation directory", ctx do
    fixture = DS.generation_fixture()

    assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)
    assert {:ok, :unchanged} = Store.stage_manifest(ctx.store, fixture.delivery)

    assert File.read!(Store.manifest_path(ctx.store, 1, fixture.manifest_hash)) == fixture.manifest_bytes
    assert {:ok, state} = Store.generation_state(ctx.store, 1, fixture.manifest_hash)
    assert state.status == :receiving
    assert state.received == %{}

    assert_modes(Store.generation_directory(ctx.store, 1, fixture.manifest_hash), 0o700)
    assert_modes(Store.manifest_path(ctx.store, 1, fixture.manifest_hash), 0o600)
  end

  test "loads all nine staged descriptors with decoded content and explicit tombstones", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())

    assert {:ok, generation} = Store.load_generation(ctx.store, 1, fixture.manifest_hash)
    assert generation.manifest.hash == fixture.manifest_hash
    assert Enum.sort(Map.keys(generation.sections)) == Enum.sort(Contract.sections())

    assert generation.sections.assignment.tombstone
    assert generation.sections.assignment.content == nil
    assert generation.sections.polar.tombstone
    assert generation.sections.polar.content == nil

    refute generation.sections.tracking.tombstone
    assert generation.sections.tracking.content == DS.default_contents().tracking
    assert generation.sections.tracking.descriptor.name == :tracking
  end

  test "rejects outer/embedded manifest mismatches and generation hash conflicts without side effects", ctx do
    fixture = DS.generation_fixture()

    for {field, value, reason} <- [
          {:device_id, <<0x99::128>>, :manifest_device_mismatch},
          {:credential_epoch, 99, :manifest_credential_epoch_mismatch},
          {:generation, 99, :manifest_generation_mismatch},
          {:manifest_hash, <<0x88::256>>, :manifest_hash_mismatch}
        ] do
      assert {:error, ^reason} = Store.stage_manifest(ctx.store, Map.put(fixture.delivery, field, value))
    end

    assert :empty = Store.generation_state(ctx.store, 1, fixture.manifest_hash)
    assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)

    conflict =
      DS.generation_fixture(
        generation: 1,
        contents: %{tracking: put_in(DS.default_contents().tracking["version"], 2)}
      )

    assert {:error, :generation_hash_conflict} = Store.stage_manifest(ctx.store, conflict.delivery)
    refute File.exists?(Store.generation_directory(ctx.store, 1, conflict.manifest_hash))
    assert File.read!(Store.manifest_path(ctx.store, 1, fixture.manifest_hash)) == fixture.manifest_bytes
  end

  test "persists chunk receipts and emits ordered minimal missing ranges after restart", ctx do
    large = String.duplicate("x", Contract.chunk_size() * 3 + 17)

    fixture =
      DS.generation_fixture(
        tombstones: [:polar],
        contents: %{assignment: %{"blob" => large, "version" => 1}}
      )

    assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)
    chunks = DS.chunks_for_section(fixture.binding, fixture.sections_by_name.assignment)

    assert {:ok, :stored} = Store.put_chunk(ctx.store, Enum.at(chunks, 2))
    assert {:ok, :stored} = Store.put_chunk(ctx.store, Enum.at(chunks, 0))

    reloaded = Store.new(base_dir: ctx.base, storage_epoch: DS.storage_epoch())
    assert {:ok, incomplete} = Store.resume(reloaded, 1, fixture.manifest_hash)

    assignment = Enum.find(incomplete, &(&1.section == :assignment))

    assert assignment.missing_ranges == [
             %{first_chunk_index: 1, chunk_count: 1},
             %{first_chunk_index: 3, chunk_count: 1}
           ]

    names = Enum.map(incomplete, & &1.section)
    assert names == Enum.reject(Contract.sections(), &(&1 == :polar))
  end

  test "accepts identical duplicate chunks but rejects conflicting duplicates", ctx do
    fixture = DS.generation_fixture()
    assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)
    chunk = hd(DS.chunks_for_section(fixture.binding, fixture.sections_by_name.tracking))

    assert {:ok, :stored} = Store.put_chunk(ctx.store, chunk)
    assert {:ok, :unchanged} = Store.put_chunk(ctx.store, chunk)

    conflicting = Map.update!(chunk, :chunk, fn <<first, rest::binary>> -> <<Bitwise.bxor(first, 1), rest::binary>> end)
    assert {:error, :chunk_conflict} = Store.put_chunk(ctx.store, conflicting)
    assert File.read!(Store.chunk_path(ctx.store, 1, fixture.manifest_hash, :tracking, 0)) == chunk.chunk
  end

  test "replaces a torn chunk from an interrupted write", ctx do
    fixture = DS.generation_fixture()
    assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)
    chunk = hd(DS.chunks_for_section(fixture.binding, fixture.sections_by_name.tracking))
    path = Store.chunk_path(ctx.store, 1, fixture.manifest_hash, :tracking, 0)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, binary_part(chunk.chunk, 0, byte_size(chunk.chunk) - 1))

    assert {:ok, :stored} = Store.put_chunk(ctx.store, chunk)
    assert File.read!(path) == chunk.chunk
  end

  test "resume removes full-length corrupt chunks and requests a clean retransmit", ctx do
    fixture = DS.generation_fixture()
    assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)

    chunks = DS.chunks_for_section(fixture.binding, fixture.sections_by_name.tracking)
    Enum.each(chunks, &assert({:ok, :stored} = Store.put_chunk(ctx.store, &1)))

    path = Store.chunk_path(ctx.store, 1, fixture.manifest_hash, :tracking, 0)
    <<first, rest::binary>> = File.read!(path)
    File.write!(path, <<Bitwise.bxor(first, 1), rest::binary>>)

    assert {:ok, incomplete} = Store.resume(ctx.store, 1, fixture.manifest_hash)
    tracking = Enum.find(incomplete, &(&1.section == :tracking))
    assert tracking.missing_ranges == [%{first_chunk_index: 0, chunk_count: length(chunks)}]
    refute File.exists?(path)
  end

  test "resume propagates non-absence chunk read failures instead of requesting retransmission", ctx do
    fixture = DS.generation_fixture()
    assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)

    chunk = hd(DS.chunks_for_section(fixture.binding, fixture.sections_by_name.tracking))
    assert {:ok, :stored} = Store.put_chunk(ctx.store, chunk)

    path = Store.chunk_path(ctx.store, 1, fixture.manifest_hash, :tracking, 0)
    Process.put({ReadFaultFileSystem, :read_fault_path}, path)
    on_exit(fn -> Process.delete({ReadFaultFileSystem, :read_fault_path}) end)

    faulted =
      Store.new(
        base_dir: ctx.base,
        storage_epoch: DS.storage_epoch(),
        file_system: ReadFaultFileSystem
      )

    assert {:error, {:read_chunk, :eacces}} =
             Store.resume(faulted, 1, fixture.manifest_hash)
  end

  test "verification distinguishes transient chunk read failures from incomplete transfer", ctx do
    fixture = DS.generation_fixture()
    assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)
    Enum.each(DS.chunks(fixture), &assert({:ok, :stored} = Store.put_chunk(ctx.store, &1)))

    chunk = hd(DS.chunks_for_section(fixture.binding, fixture.sections_by_name.tracking))
    path = Store.chunk_path(ctx.store, 1, fixture.manifest_hash, :tracking, chunk.chunk_index)
    Process.put({ReadFaultFileSystem, :read_fault_path}, path)
    on_exit(fn -> Process.delete({ReadFaultFileSystem, :read_fault_path}) end)

    faulted =
      Store.new(
        base_dir: ctx.base,
        storage_epoch: DS.storage_epoch(),
        file_system: ReadFaultFileSystem
      )

    assert {:error, {:read_chunk, :eacces}, :tracking} =
             Store.verify_and_stage(faulted, 1, fixture.manifest_hash)

    assert {:ok, %{status: :receiving}} =
             Store.generation_state(faulted, 1, fixture.manifest_hash)

    Process.delete({ReadFaultFileSystem, :read_fault_path})

    assert {:ok, %{status: :staged}} =
             Store.verify_and_stage(faulted, 1, fixture.manifest_hash)
  end

  test "missing generations return one explicit error shape from every public operation", ctx do
    hash = :binary.copy(<<0xAB>>, 32)
    chunk = hd(DS.chunks(DS.generation_fixture())) |> Map.merge(%{generation: 99, manifest_hash: hash})

    assert {:error, :generation_not_found} = Store.resume(ctx.store, 99, hash)
    assert {:error, :generation_not_found} = Store.verify_and_stage(ctx.store, 99, hash)
    assert {:error, :generation_not_found} = Store.read_section(ctx.store, 99, hash, :tracking)
    assert {:error, :generation_not_found} = Store.put_chunk(ctx.store, chunk)
    assert {:error, :generation_not_found} = Store.activate(ctx.store, 99, hash)
  end

  test "rejects malformed chunk geometry and descriptor bindings before writing", ctx do
    fixture = DS.generation_fixture()
    assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)
    chunk = hd(DS.chunks_for_section(fixture.binding, fixture.sections_by_name.tracking))

    invalid = [
      Map.put(chunk, :section_schema_version, 99),
      Map.put(chunk, :section_hash, <<0x77::256>>),
      Map.put(chunk, :total_content_length, chunk.total_content_length + 1),
      Map.put(chunk, :chunk_index, chunk.chunk_count),
      Map.put(chunk, :chunk_offset, 1),
      Map.put(chunk, :chunk_count, chunk.chunk_count + 1),
      Map.put(chunk, :chunk, chunk.chunk <> <<0>>)
    ]

    Enum.each(invalid, fn payload ->
      assert {:error, :chunk_bounds} = Store.put_chunk(ctx.store, payload)
    end)

    refute File.exists?(Store.chunk_path(ctx.store, 1, fixture.manifest_hash, :tracking, 0))
  end

  test "binds each chunk to manifest and storage authority fields", ctx do
    fixture = DS.generation_fixture()
    assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)
    chunk = hd(DS.chunks_for_section(fixture.binding, fixture.sections_by_name.tracking))

    assert {:error, :chunk_device_mismatch} =
             Store.put_chunk(ctx.store, Map.put(chunk, :device_id, <<0x99::128>>))

    assert {:error, :chunk_credential_epoch_mismatch} =
             Store.put_chunk(ctx.store, Map.put(chunk, :credential_epoch, 99))

    assert {:error, :storage_epoch_mismatch} =
             Store.put_chunk(ctx.store, Map.put(chunk, :storage_epoch, <<0x99::128>>))

    refute File.exists?(Store.chunk_path(ctx.store, 1, fixture.manifest_hash, :tracking, 0))
  end

  test "verifies every canonical section hash, persists canonical bytes, and marks the generation staged", ctx do
    fixture = DS.generation_fixture()
    assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)

    Enum.each(DS.chunks(fixture), fn chunk ->
      assert {:ok, _} = Store.put_chunk(ctx.store, chunk)
    end)

    assert {:ok, staged} = Store.verify_and_stage(ctx.store, 1, fixture.manifest_hash)
    assert staged.status == :staged
    assert {:ok, []} = Store.resume(ctx.store, 1, fixture.manifest_hash)

    Enum.each(fixture.sections, fn section ->
      assert {:ok, bytes} = Store.read_section(ctx.store, 1, fixture.manifest_hash, section.name)
      assert bytes == if(section.tombstone, do: <<>>, else: section.content)
    end)

    reloaded = Store.new(base_dir: ctx.base, storage_epoch: DS.storage_epoch())
    assert {:ok, %{status: :staged}} = Store.generation_state(reloaded, 1, fixture.manifest_hash)
  end

  test "hash failure never marks a generation staged or changes the active pointer", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)

    candidate = DS.generation_fixture(generation: 2)
    assert {:ok, :staged} = Store.stage_manifest(ctx.store, candidate.delivery)

    chunks = DS.chunks(candidate)
    first = Enum.find(chunks, &(&1.section == :tracking))
    rest = Enum.reject(chunks, &(&1.section == :tracking))
    {:ok, altered_content} = Canonical.encode(Map.put(DS.default_contents().tracking, "version", 2))
    assert byte_size(altered_content) == byte_size(first.chunk)
    corrupt = %{first | chunk: altered_content}
    assert {:ok, :stored} = Store.put_chunk(ctx.store, corrupt)
    Enum.each(rest, &assert({:ok, _} = Store.put_chunk(ctx.store, &1)))

    assert {:error, :section_hash_mismatch, section} =
             Store.verify_and_stage(ctx.store, 2, candidate.manifest_hash)

    assert section == :tracking
    assert {:ok, %{status: :receiving}} = Store.generation_state(ctx.store, 2, candidate.manifest_hash)
    assert {:ok, %{generation: 1, manifest_hash: hash}} = Store.active(ctx.store)
    assert hash == prior.manifest_hash
  end

  test "advances exactly one atomic active pointer only for a fully staged generation", ctx do
    fixture = DS.generation_fixture()
    assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)
    assert {:error, :generation_not_staged} = Store.activate(ctx.store, 1, fixture.manifest_hash)
    assert :empty = Store.active(ctx.store)

    fully_stage(ctx.store, fixture)
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    assert {:ok, pointer} = Store.active(ctx.store)

    assert pointer == %{
             device_id: DS.device_id(),
             credential_epoch: 4,
             storage_epoch: DS.storage_epoch(),
             generation: 1,
             manifest_hash: fixture.manifest_hash
           }
  end

  test "generation references are scoped by logical device and credential epoch", ctx do
    next_epoch =
      DS.generation_fixture(
        generation: 1,
        credential_epoch: 5,
        contents: %{tracking: put_in(DS.default_contents().tracking["version"], 2)}
      )

    foreign_device =
      DS.generation_fixture(
        device_id: <<0x77::128>>,
        generation: 1,
        credential_epoch: 4,
        contents: %{tracking: put_in(DS.default_contents().tracking["version"], 3)}
      )

    fixtures = [DS.generation_fixture(), next_epoch, foreign_device]

    Enum.each(fixtures, fn fixture ->
      assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)

      path =
        generation_reference_path(
          ctx.base,
          fixture.binding.device_id,
          fixture.binding.credential_epoch,
          fixture.binding.generation
        )

      assert {2, :generation_reference, reference} = path |> File.read!() |> :erlang.binary_to_term()

      assert reference == %{
               device_id: fixture.binding.device_id,
               credential_epoch: fixture.binding.credential_epoch,
               storage_epoch: DS.storage_epoch(),
               generation: fixture.binding.generation,
               manifest_hash: fixture.manifest_hash
             }
    end)
  end

  test "legacy unscoped activation authority fails closed and is replaced by rehydration", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())

    legacy_pointer = %{
      credential_epoch: fixture.binding.credential_epoch,
      storage_epoch: DS.storage_epoch(),
      generation: fixture.binding.generation,
      manifest_hash: fixture.manifest_hash
    }

    write_term_record(Store.active_pointer_path(ctx.store), :active_pointer, legacy_pointer)

    write_term_record(Store.activation_journal_path(ctx.store), :activation_journal, %{
      storage_epoch: DS.storage_epoch(),
      prior: nil,
      candidate: legacy_pointer,
      decision: nil,
      terminal_ack: nil
    })

    assert :empty = Store.active(ctx.store)
    assert :empty = Store.activation_journal(ctx.store)

    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)
    assert {:ok, %{device_id: device_id}} = Store.active(ctx.store)
    assert device_id == DS.device_id()

    assert {2, :active_pointer, %{device_id: ^device_id}} =
             ctx.store
             |> Store.active_pointer_path()
             |> File.read!()
             |> :erlang.binary_to_term()
  end

  test "activation is idempotent and rejects credential or generation downgrade", ctx do
    first = fully_stage(ctx.store, DS.generation_fixture(generation: 1, credential_epoch: 4))
    second = fully_stage(ctx.store, DS.generation_fixture(generation: 2, credential_epoch: 4))
    stale_epoch = fully_stage(ctx.store, DS.generation_fixture(generation: 3, credential_epoch: 3))

    assert {:ok, nil} = Store.activate(ctx.store, 2, second.manifest_hash)
    assert {:ok, current} = Store.active(ctx.store)
    assert {:ok, ^current} = Store.activate(ctx.store, 2, second.manifest_hash)

    assert {:error, :generation_downgrade} = Store.activate(ctx.store, 1, first.manifest_hash)
    assert {:error, :credential_epoch_downgrade} = Store.activate(ctx.store, 3, stale_epoch.manifest_hash)
    assert {:ok, ^current} = Store.active(ctx.store)
  end

  test "activation journal durably binds prior and candidate and supports both recovery outcomes", ctx do
    first = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    second = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, first.manifest_hash)
    assert {:ok, prior} = Store.active(ctx.store)

    assert {:ok, journal} = Store.prepare_activation(ctx.store, 2, second.manifest_hash)
    assert journal.prior == prior
    assert journal.candidate.generation == 2
    assert journal.candidate.manifest_hash == second.manifest_hash
    assert {:ok, ^journal} = Store.activation_journal(ctx.store)
    assert {:ok, ^prior} = Store.active(ctx.store)

    assert {:ok, ^prior} = Store.commit_activation(ctx.store)
    assert {:ok, %{generation: 2}} = Store.active(ctx.store)

    assert :ok = Store.recover_activation(ctx.store, :prior)
    assert {:ok, ^prior} = Store.active(ctx.store)
    assert :empty = Store.activation_journal(ctx.store)

    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 2, second.manifest_hash)
    assert :ok = Store.recover_activation(ctx.store, :candidate)
    assert {:ok, %{generation: 2}} = Store.active(ctx.store)
    assert :empty = Store.activation_journal(ctx.store)
  end

  test "restoring the prior pointer preserves the undecided activation journal", ctx do
    first = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    second = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, first.manifest_hash)
    assert {:ok, prior} = Store.active(ctx.store)
    assert {:ok, journal} = Store.prepare_activation(ctx.store, 2, second.manifest_hash)
    assert {:ok, ^prior} = Store.commit_activation(ctx.store)
    assert {:ok, %{generation: 2}} = Store.active(ctx.store)

    assert :ok = Store.restore_activation_prior(ctx.store)
    assert {:ok, ^prior} = Store.active(ctx.store)
    assert {:ok, ^journal} = Store.activation_journal(ctx.store)
  end

  test "activation decisions durably bind their terminal ACK before journal cleanup", ctx do
    first = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    second = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, first.manifest_hash)
    assert {:ok, prior} = Store.active(ctx.store)
    assert {:ok, journal} = Store.prepare_activation(ctx.store, 2, second.manifest_hash)

    effective = %{
      device_id: DS.device_id(),
      credential_epoch: 4,
      boot_id: DS.boot_id(),
      storage_epoch: DS.storage_epoch(),
      generation: 2,
      manifest_hash: second.manifest_hash,
      status: :effective
    }

    assert :ok = Store.record_activation_decision(ctx.store, :candidate, effective)
    assert :ok = Store.record_activation_decision(ctx.store, :candidate, effective)

    assert {:ok, decided} = Store.activation_journal(ctx.store)
    assert decided.prior == prior
    assert decided.candidate == journal.candidate
    assert decided.decision == :candidate
    assert decided.terminal_ack == effective

    assert {:ok, committed} = Store.commit_activation_decision(ctx.store)
    assert committed.decision == :candidate
    assert {:ok, pointer} = Store.active(ctx.store)
    assert pointer == journal.candidate
    assert {:ok, ^decided} = Store.activation_journal(ctx.store)

    assert :ok = Store.complete_activation(ctx.store)
    assert Store.activation_journal(ctx.store) == :empty
  end

  test "a candidate decision remains recoverable after its unselected prior generation is gone", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)
    assert {:ok, journal} = Store.prepare_activation(ctx.store, 2, candidate.manifest_hash)

    effective = %{
      device_id: DS.device_id(),
      credential_epoch: 4,
      boot_id: DS.boot_id(),
      storage_epoch: DS.storage_epoch(),
      generation: 2,
      manifest_hash: candidate.manifest_hash,
      status: :effective
    }

    assert :ok = Store.record_activation_decision(ctx.store, :candidate, effective)
    File.rm_rf!(Store.generation_directory(ctx.store, 1, prior.manifest_hash))
    assert {:error, :active_generation_missing} = Store.active(ctx.store)

    assert {:ok, %{decision: :candidate, terminal_ack: ^effective}} =
             Store.activation_journal(ctx.store)

    assert {:ok, %{decision: :candidate}} = Store.commit_activation_decision(ctx.store)
    assert Store.active(ctx.store) == {:ok, journal.candidate}
  end

  test "a prior decision remains recoverable after its unselected candidate generation is gone", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)
    assert {:ok, journal} = Store.prepare_activation(ctx.store, 2, candidate.manifest_hash)
    assert {:ok, _prior} = Store.commit_activation(ctx.store)

    rejected = %{
      device_id: DS.device_id(),
      credential_epoch: 4,
      boot_id: DS.boot_id(),
      storage_epoch: DS.storage_epoch(),
      generation: 2,
      manifest_hash: candidate.manifest_hash,
      status: :rejected,
      phase: :activation,
      error_code: :activation_failed,
      retryable: true,
      section: nil
    }

    assert :ok = Store.record_activation_decision(ctx.store, :prior, rejected)
    File.rm_rf!(Store.generation_directory(ctx.store, 2, candidate.manifest_hash))
    assert {:error, :active_generation_missing} = Store.active(ctx.store)

    assert {:ok, %{decision: :prior, terminal_ack: ^rejected}} =
             Store.activation_journal(ctx.store)

    assert {:ok, %{decision: :prior}} = Store.commit_activation_decision(ctx.store)
    assert Store.active(ctx.store) == {:ok, journal.prior}
  end

  test "a prior decision ignores corrupt unselected candidate bytes", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)
    assert {:ok, journal} = Store.prepare_activation(ctx.store, 2, candidate.manifest_hash)
    assert {:ok, _prior} = Store.commit_activation(ctx.store)

    rejected = %{
      device_id: DS.device_id(),
      credential_epoch: 4,
      boot_id: DS.boot_id(),
      storage_epoch: DS.storage_epoch(),
      generation: 2,
      manifest_hash: candidate.manifest_hash,
      status: :rejected,
      phase: :activation,
      error_code: :activation_failed,
      retryable: false,
      section: nil
    }

    assert :ok = Store.record_activation_decision(ctx.store, :prior, rejected)
    File.write!(Store.manifest_path(ctx.store, 2, candidate.manifest_hash), <<1, 2, 3>>)

    assert {:ok, %{decision: :prior, terminal_ack: ^rejected}} =
             Store.activation_journal(ctx.store)

    assert {:ok, %{decision: :prior}} = Store.commit_activation_decision(ctx.store)
    assert Store.active(ctx.store) == {:ok, journal.prior}
  end

  test "a selected activation manifest read failure remains retryable", ctx do
    candidate = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 1, candidate.manifest_hash)

    effective = %{
      device_id: DS.device_id(),
      credential_epoch: 4,
      boot_id: DS.boot_id(),
      storage_epoch: DS.storage_epoch(),
      generation: 1,
      manifest_hash: candidate.manifest_hash,
      status: :effective
    }

    assert :ok = Store.record_activation_decision(ctx.store, :candidate, effective)

    manifest_path = Store.manifest_path(ctx.store, 1, candidate.manifest_hash)
    Process.put({ReadFaultFileSystem, :read_fault_path}, manifest_path)
    on_exit(fn -> Process.delete({ReadFaultFileSystem, :read_fault_path}) end)

    faulted =
      Store.new(
        base_dir: ctx.base,
        storage_epoch: DS.storage_epoch(),
        file_system: ReadFaultFileSystem
      )

    assert {:error, {:read_activation_manifest, :eacces}} =
             Store.activation_journal(faulted)
  end

  test "activation decisions reject a terminal ACK for another logical device", ctx do
    candidate = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 1, candidate.manifest_hash)

    foreign_ack = %{
      device_id: <<0x77::128>>,
      credential_epoch: 4,
      boot_id: DS.boot_id(),
      storage_epoch: DS.storage_epoch(),
      generation: 1,
      manifest_hash: candidate.manifest_hash,
      status: :effective
    }

    assert {:error, :activation_ack_mismatch} =
             Store.record_activation_decision(ctx.store, :candidate, foreign_ack)

    assert {:ok, %{decision: nil, terminal_ack: nil}} =
             Store.activation_journal(ctx.store)
  end

  test "a decided rollback rejects a tampered foreign ACK after candidate cleanup", ctx do
    prior = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    candidate = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, prior.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 2, candidate.manifest_hash)

    rejected = %{
      device_id: DS.device_id(),
      credential_epoch: 4,
      boot_id: DS.boot_id(),
      storage_epoch: DS.storage_epoch(),
      generation: 2,
      manifest_hash: candidate.manifest_hash,
      status: :rejected,
      phase: :activation,
      error_code: :activation_failed,
      retryable: false,
      section: nil
    }

    assert :ok = Store.record_activation_decision(ctx.store, :prior, rejected)
    assert {:ok, decided} = Store.activation_journal(ctx.store)

    tampered = %{decided | terminal_ack: Map.put(rejected, :device_id, <<0x77::128>>)}
    write_term_record(Store.activation_journal_path(ctx.store), :activation_journal, tampered, 2)
    File.rm_rf!(Store.generation_directory(ctx.store, 2, candidate.manifest_hash))

    assert {:error, :corrupt_activation_journal} = Store.activation_journal(ctx.store)
  end

  test "a durable activation decision can rebind only its terminal ACK boot identity", ctx do
    first = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    second = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, first.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 2, second.manifest_hash)

    effective = %{
      device_id: DS.device_id(),
      credential_epoch: 4,
      boot_id: DS.boot_id(),
      storage_epoch: DS.storage_epoch(),
      generation: 2,
      manifest_hash: second.manifest_hash,
      status: :effective
    }

    rebound = Map.put(effective, :boot_id, <<0x55::128>>)
    wrong_device = Map.put(rebound, :device_id, <<0x77::128>>)

    assert :ok = Store.record_activation_decision(ctx.store, :candidate, effective)
    assert :ok = Store.record_activation_decision(ctx.store, :candidate, rebound)

    assert {:ok, %{decision: :candidate, terminal_ack: ^rebound}} =
             Store.activation_journal(ctx.store)

    assert {:error, :activation_ack_mismatch} =
             Store.record_activation_decision(ctx.store, :candidate, wrong_device)

    assert {:ok, %{decision: :candidate, terminal_ack: ^rebound}} =
             Store.activation_journal(ctx.store)
  end

  test "an activation decision cannot be changed after it is durable", ctx do
    first = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    second = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    assert {:ok, nil} = Store.activate(ctx.store, 1, first.manifest_hash)
    assert {:ok, _journal} = Store.prepare_activation(ctx.store, 2, second.manifest_hash)

    effective = %{
      device_id: DS.device_id(),
      credential_epoch: 4,
      boot_id: DS.boot_id(),
      storage_epoch: DS.storage_epoch(),
      generation: 2,
      manifest_hash: second.manifest_hash,
      status: :effective
    }

    rejected =
      effective
      |> Map.put(:status, :rejected)
      |> Map.merge(%{
        phase: :activation,
        error_code: :activation_failed,
        retryable: true,
        section: nil
      })

    assert :ok = Store.record_activation_decision(ctx.store, :candidate, effective)

    assert {:error, :activation_decision_conflict} =
             Store.record_activation_decision(ctx.store, :prior, rejected)

    assert {:ok, %{decision: :candidate, terminal_ack: ^effective}} =
             Store.activation_journal(ctx.store)

    assert {:error, :activation_decision_already_recorded} = Store.commit_activation(ctx.store)

    assert {:error, :activation_decision_already_recorded} =
             Store.recover_activation(ctx.store, :prior)

    assert {:ok, %{generation: 1}} = Store.active(ctx.store)
  end

  test "an unresolved activation journal cannot be overwritten by another candidate", ctx do
    first = fully_stage(ctx.store, DS.generation_fixture(generation: 1))
    second = fully_stage(ctx.store, DS.generation_fixture(generation: 2))
    third = fully_stage(ctx.store, DS.generation_fixture(generation: 3))
    assert {:ok, nil} = Store.activate(ctx.store, 1, first.manifest_hash)

    assert {:ok, journal} = Store.prepare_activation(ctx.store, 2, second.manifest_hash)
    assert {:ok, ^journal} = Store.prepare_activation(ctx.store, 2, second.manifest_hash)

    assert {:error, :activation_in_progress} =
             Store.prepare_activation(ctx.store, 3, third.manifest_hash)

    assert {:ok, ^journal} = Store.activation_journal(ctx.store)
    assert {:ok, %{generation: 1}} = Store.active(ctx.store)
  end

  test "active pointer fault boundaries report the durable commit authoritatively", ctx do
    for stage <- [
          :temp_opened,
          :temp_chmodded,
          :temp_written,
          :temp_synced,
          :temp_closed,
          :before_rename,
          :renamed,
          :parent_synced
        ] do
      base = Path.join(ctx.base, Atom.to_string(stage))
      clean = Store.new(base_dir: base, storage_epoch: DS.storage_epoch())
      first = fully_stage(clean, DS.generation_fixture(generation: 1))
      second = fully_stage(clean, DS.generation_fixture(generation: 2))
      assert {:ok, nil} = Store.activate(clean, 1, first.manifest_hash)

      faulted =
        Store.new(
          base_dir: base,
          storage_epoch: DS.storage_epoch(),
          fault_injector: fn
            ^stage -> {:error, :power_loss}
            _ -> :ok
          end
        )

      result = Store.activate(faulted, 2, second.manifest_hash)
      assert {:ok, pointer} = Store.active(clean)

      if stage in [:renamed, :parent_synced] do
        assert {:ok, %{generation: 1}} = result
        assert pointer.generation == 2
        assert pointer.manifest_hash == second.manifest_hash
      else
        assert {:error, {:fault_injected, ^stage, :power_loss}} = result
        assert pointer.generation == 1
        assert pointer.manifest_hash == first.manifest_hash
      end
    end
  end

  test "pending ACK writes report post-rename commits authoritatively", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())

    ack = %{
      device_id: DS.device_id(),
      credential_epoch: 4,
      boot_id: DS.boot_id(),
      storage_epoch: DS.storage_epoch(),
      generation: 1,
      manifest_hash: fixture.manifest_hash,
      status: :effective
    }

    for stage <- [:renamed, :parent_synced] do
      base = Path.join(ctx.base, "pending-#{stage}")

      faulted =
        Store.new(
          base_dir: base,
          storage_epoch: DS.storage_epoch(),
          fault_injector: fn
            ^stage -> {:error, :power_loss}
            _other -> :ok
          end
        )

      assert {:ok, :stored} = Store.put_pending_ack(faulted, ack)

      clean = Store.new(base_dir: base, storage_epoch: DS.storage_epoch())
      assert {:ok, [^ack]} = Store.pending_acks(clean)
    end
  end

  test "storage epoch mismatch fails closed for generations, pointer, and pending ACKs", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())
    assert {:ok, nil} = Store.activate(ctx.store, 1, fixture.manifest_hash)

    ack = %{
      device_id: DS.device_id(),
      credential_epoch: 4,
      boot_id: DS.boot_id(),
      storage_epoch: DS.storage_epoch(),
      generation: 1,
      manifest_hash: fixture.manifest_hash,
      status: :effective
    }

    assert {:ok, :stored} = Store.put_pending_ack(ctx.store, ack)

    other = Store.new(base_dir: ctx.base, storage_epoch: <<0xEE::128>>)
    assert {:error, :storage_epoch_mismatch} = Store.generation_state(other, 1, fixture.manifest_hash)
    assert {:error, :storage_epoch_mismatch} = Store.active(other)
    assert {:error, :storage_epoch_mismatch} = Store.pending_acks(other)
  end

  test "durably de-duplicates only frozen ACK payloads for reconnect replay", ctx do
    fixture = fully_stage(ctx.store, DS.generation_fixture())

    ack = %{
      device_id: DS.device_id(),
      credential_epoch: 4,
      boot_id: DS.boot_id(),
      storage_epoch: DS.storage_epoch(),
      generation: 1,
      manifest_hash: fixture.manifest_hash,
      status: :effective
    }

    assert {:error, :storage_epoch_mismatch} =
             Store.put_pending_ack(ctx.store, Map.put(ack, :storage_epoch, <<0x99::128>>))

    assert {:ok, :stored} = Store.put_pending_ack(ctx.store, ack)
    assert {:ok, :unchanged} = Store.put_pending_ack(ctx.store, ack)
    assert {:ok, [^ack]} = Store.pending_acks(ctx.store)

    reloaded = Store.new(base_dir: ctx.base, storage_epoch: DS.storage_epoch())
    assert {:ok, [^ack]} = Store.pending_acks(reloaded)
    assert :ok = Store.delete_pending_ack(reloaded, ack)
    assert {:ok, []} = Store.pending_acks(ctx.store)

    assert {:error, _reason} = Store.put_pending_ack(ctx.store, Map.put(ack, :secret, "never-persist"))
    refute durable_bytes(ctx.base) =~ "never-persist"
  end

  test "rejects a multi-chunk Wi-Fi descriptor before creating generation storage", ctx do
    content = String.duplicate("x", Contract.chunk_size() + 1)
    fixture = unsafe_wifi_fixture(content)

    assert {:error, :wifi_content_too_large} = Store.stage_manifest(ctx.store, fixture.delivery)
    refute File.exists?(Store.generation_directory(ctx.store, 1, fixture.manifest_hash))
  end

  test "semantically verifies complete Wi-Fi content before persisting its chunk", ctx do
    {:ok, plaintext} =
      Canonical.encode(%{
        "version" => 2,
        "enabled" => true,
        "ssid" => "race-net",
        "psk" => "must-never-reach-desired-state-storage"
      })

    fixture = unsafe_wifi_fixture(plaintext)
    assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)
    chunk = hd(DS.chunks_for_section(fixture.binding, fixture.sections_by_name.wifi))

    assert {:error, :plaintext_wifi_secret_forbidden} = Store.put_chunk(ctx.store, chunk)
    refute File.exists?(Store.chunk_path(ctx.store, 1, fixture.manifest_hash, :wifi, 0))
    refute durable_bytes(ctx.base) =~ "must-never-reach-desired-state-storage"
  end

  test "generation and ACK storage never contain delivered Wi-Fi plaintext", ctx do
    descriptor = DS.secret_descriptor()

    fixture =
      DS.generation_fixture(
        wifi_secrets: [descriptor],
        contents: %{wifi: %{"version" => 2, "enabled" => true, "ssid" => "race-net"}}
      )

    fully_stage(ctx.store, fixture)
    secret = "top-secret-wifi-passphrase"
    _delivery = DS.secret_delivery(fixture, secret)

    refute durable_bytes(ctx.base) =~ secret
    assert durable_bytes(ctx.base) =~ descriptor.ref
    assert durable_bytes(ctx.base) =~ descriptor.digest
  end

  test "structurally valid but incomplete durable maps return corruption errors instead of raising", ctx do
    fixture = DS.generation_fixture()
    state_path = Store.generation_state_path(ctx.store, 1, fixture.manifest_hash)

    write_term_record(state_path, :generation_state, %{
      storage_epoch: DS.storage_epoch(),
      generation: 1,
      status: :receiving,
      received: %{}
    })

    assert {:error, :corrupt_generation_state} =
             Store.generation_state(ctx.store, 1, fixture.manifest_hash)

    write_term_record(
      Store.active_pointer_path(ctx.store),
      :active_pointer,
      %{
        device_id: DS.device_id(),
        storage_epoch: DS.storage_epoch(),
        credential_epoch: 4,
        generation: 1
      },
      2
    )

    assert {:error, :corrupt_active_pointer} = Store.active(ctx.store)
  end

  test "an active pointer cannot authorize a missing or non-staged generation", ctx do
    fixture = DS.generation_fixture()

    pointer = %{
      device_id: DS.device_id(),
      storage_epoch: DS.storage_epoch(),
      credential_epoch: 4,
      generation: 1,
      manifest_hash: fixture.manifest_hash
    }

    write_term_record(Store.active_pointer_path(ctx.store), :active_pointer, pointer, 2)
    assert {:error, :active_generation_missing} = Store.active(ctx.store)

    assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)
    assert {:error, :active_generation_not_staged} = Store.active(ctx.store)
  end

  test "corrupt or truncated state is rejected and never interpreted as active", ctx do
    fixture = DS.generation_fixture()
    assert {:ok, :staged} = Store.stage_manifest(ctx.store, fixture.delivery)

    File.write!(Store.generation_state_path(ctx.store, 1, fixture.manifest_hash), <<1, 2, 3>>)
    assert {:error, :corrupt_generation_state} = Store.generation_state(ctx.store, 1, fixture.manifest_hash)
    assert {:error, :corrupt_generation_state} = Store.put_chunk(ctx.store, hd(DS.chunks(fixture)))

    File.mkdir_p!(ctx.base)
    File.write!(Store.active_pointer_path(ctx.store), <<4, 5, 6>>)
    assert {:error, :corrupt_active_pointer} = Store.active(ctx.store)
  end

  defp unsafe_wifi_fixture(content) do
    base = DS.generation_fixture(tombstones: [:assignment, :polar])
    wifi = %{base.sections_by_name.wifi | content: content, content_length: byte_size(content), hash: nil}
    {:ok, preimage} = Section.preimage(wifi)
    wifi = %{wifi | hash: :crypto.hash(:sha256, preimage)}

    sections = Enum.map(base.sections, &if(&1.name == :wifi, do: wifi, else: &1))

    attrs = %{
      device_id: base.binding.device_id,
      credential_epoch: base.binding.credential_epoch,
      generation: base.binding.generation,
      minimum_firmware: nil,
      required_capabilities: [],
      sections: Enum.map(sections, &Section.descriptor/1)
    }

    {:ok, manifest_bytes} = Manifest.encode(attrs)
    {:ok, manifest} = Manifest.decode(manifest_bytes)
    binding = %{base.binding | manifest_hash: manifest.hash}

    %{
      base
      | binding: binding,
        manifest: manifest,
        manifest_bytes: manifest_bytes,
        manifest_hash: manifest.hash,
        sections: sections,
        sections_by_name: Map.new(sections, &{&1.name, &1}),
        delivery: Map.merge(binding, %{manifest: manifest_bytes})
    }
  end

  defp generation_reference_path(base, device_id, credential_epoch, generation) do
    Path.join([
      base,
      "generation_refs",
      Base.encode16(device_id, case: :lower),
      Integer.to_string(credential_epoch),
      Integer.to_string(generation) <> ".term"
    ])
  end

  defp write_term_record(path, type, value, version \\ 1) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary({version, type, value}))
  end

  defp fully_stage(store, fixture) do
    assert {:ok, _} = Store.stage_manifest(store, fixture.delivery)
    Enum.each(DS.chunks(fixture), &assert({:ok, _} = Store.put_chunk(store, &1)))
    assert {:ok, %{status: :staged}} = Store.verify_and_stage(store, fixture.binding.generation, fixture.manifest_hash)
    fixture
  end

  defp assert_modes(path, expected) do
    assert {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o777) == expected
  end

  defp durable_bytes(base) do
    base
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map_join(&File.read!/1)
  end
end
