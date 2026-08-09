defmodule RacingOrg.Tracker.Pro.DesiredState.Store do
  @moduledoc """
  Durable immutable desired-state generation storage.

  Generation files are content-addressed by generation and manifest hash. Every
  mutable record (receipt state, activation journal, active pointer, and pending
  ACK replay state) is replaced through `DesiredState.AtomicFile`, so the only
  authoritative effective-generation switch is one atomic pointer file.

  Active pointers, activation journals, and generation references use the
  runtime-identity-scoped version 2 envelope. Version 1 authority records lacked
  a logical device ID; they are ignored fail-closed so authenticated rehydration
  can replace them without reopening ambiguous local authority.
  """

  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Canonical, Manifest, Messages, Section}
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

  @format_version 1
  @identity_format_version 2
  @active_filename "active_generation"
  @zero_identifier <<0::128>>
  @pending_acks_filename "pending_acks"
  @activation_filename "activation_journal"

  @enforce_keys [:base_dir, :storage_epoch]
  defstruct [:base_dir, :storage_epoch, :file_system, :fault_injector, :temp_suffix]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    %__MODULE__{
      base_dir: Keyword.fetch!(opts, :base_dir),
      storage_epoch: Keyword.fetch!(opts, :storage_epoch),
      file_system: Keyword.get(opts, :file_system, FileSystem),
      fault_injector: Keyword.get(opts, :fault_injector),
      temp_suffix: Keyword.get(opts, :temp_suffix)
    }
  end

  @spec stage_manifest(t(), map()) :: {:ok, :staged | :unchanged} | {:error, term()}
  def stage_manifest(%__MODULE__{} = store, delivery) when is_map(delivery) do
    with :ok <- validate_store_epoch(store),
         {:ok, manifest_bytes} <- fetch_binary(delivery, :manifest, :malformed_manifest),
         {:ok, manifest} <- Manifest.decode(manifest_bytes),
         :ok <- validate_manifest_delivery(store, delivery, manifest),
         :ok <- validate_wifi_descriptor(manifest),
         :ok <- claim_generation(store, manifest),
         {:ok, disposition} <- persist_manifest_and_state(store, manifest) do
      {:ok, disposition}
    end
  end

  def stage_manifest(%__MODULE__{}, _delivery), do: {:error, :malformed_manifest}

  @spec put_chunk(t(), map()) :: {:ok, :stored | :unchanged} | {:error, term()}
  def put_chunk(%__MODULE__{} = store, payload) when is_map(payload) do
    generation = Map.get(payload, :generation)
    manifest_hash = Map.get(payload, :manifest_hash)

    with {:ok, state} <- fetch_generation_state(store, generation, manifest_hash),
         {:ok, manifest} <- load_manifest(store, generation, manifest_hash),
         {:ok, descriptor} <- validate_chunk_payload(store, payload, manifest),
         {:ok, disposition} <- persist_chunk(store, state, descriptor, payload) do
      {:ok, disposition}
    end
  end

  def put_chunk(%__MODULE__{}, _payload), do: {:error, :chunk_bounds}

  @spec resume(t(), pos_integer(), binary()) :: {:ok, [map()]} | {:error, term()}
  def resume(%__MODULE__{} = store, generation, manifest_hash) do
    with {:ok, state} <- fetch_generation_state(store, generation, manifest_hash),
         {:ok, manifest} <- load_manifest(store, generation, manifest_hash),
         {:ok, state, incomplete} <- build_resume(store, state, manifest) do
      if state.received != Map.get(state, :persisted_received, state.received) do
        case write_generation_state(store, state) do
          :ok -> {:ok, incomplete}
          {:error, _reason} = error -> error
        end
      else
        {:ok, incomplete}
      end
    end
  end

  @spec verify_and_stage(t(), pos_integer(), binary()) ::
          {:ok, map()} | {:error, term()} | {:error, term(), atom()}
  def verify_and_stage(%__MODULE__{} = store, generation, manifest_hash) do
    with {:ok, state} <- fetch_generation_state(store, generation, manifest_hash),
         {:ok, manifest} <- load_manifest(store, generation, manifest_hash),
         {:ok, verified} <- verify_sections(store, manifest),
         :ok <- persist_verified_sections(store, generation, manifest_hash, verified),
         staged = %{state | status: :staged, received: complete_receipts(manifest)},
         :ok <- write_generation_state(store, staged) do
      {:ok, staged}
    end
  end

  @spec read_section(t(), pos_integer(), binary(), atom()) :: {:ok, binary()} | {:error, term()}
  def read_section(%__MODULE__{} = store, generation, manifest_hash, name) do
    with {:ok, %{status: :staged}} <- fetch_generation_state(store, generation, manifest_hash),
         {:ok, manifest} <- load_manifest(store, generation, manifest_hash),
         %{} = descriptor <- Enum.find(manifest.sections, &(&1.name == name)),
         {:ok, bytes} <- read_file(store, section_path(store, generation, manifest_hash, name)),
         {:ok, _verified} <- Section.verify(descriptor, bytes) do
      {:ok, bytes}
    else
      {:ok, _state} -> {:error, :generation_not_staged}
      nil -> {:error, :unknown_section}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Load one fully staged generation with all descriptors and decoded section content."
  @spec load_generation(t(), pos_integer(), binary()) :: {:ok, map()} | {:error, term()}
  def load_generation(%__MODULE__{} = store, generation, manifest_hash) do
    with {:ok, %{status: :staged}} <- fetch_generation_state(store, generation, manifest_hash),
         {:ok, manifest} <- load_manifest(store, generation, manifest_hash),
         {:ok, sections} <- load_decoded_sections(store, manifest) do
      {:ok, %{manifest: manifest, sections: sections}}
    else
      {:ok, _state} -> {:error, :generation_not_staged}
      {:error, _reason} = error -> error
    end
  end

  @spec generation_state(t(), term(), term()) :: {:ok, map()} | :empty | {:error, term()}
  def generation_state(%__MODULE__{} = store, generation, manifest_hash)
      when is_integer(generation) and generation > 0 and is_binary(manifest_hash) and byte_size(manifest_hash) == 32 do
    path = generation_state_path(store, generation, manifest_hash)

    case read_file(store, path) do
      {:ok, bytes} -> decode_generation_state(bytes, store, generation, manifest_hash)
      {:error, :enoent} -> :empty
      {:error, reason} -> {:error, {:read_generation_state, reason}}
    end
  end

  def generation_state(%__MODULE__{}, _generation, _manifest_hash), do: :empty

  defp fetch_generation_state(store, generation, manifest_hash) do
    case generation_state(store, generation, manifest_hash) do
      :empty -> {:error, :generation_not_found}
      result -> result
    end
  end

  defp load_decoded_sections(store, manifest) do
    Enum.reduce_while(manifest.sections, {:ok, %{}}, fn descriptor, {:ok, acc} ->
      result =
        if descriptor.tombstone do
          {:ok, %{descriptor: descriptor, tombstone: true, content: nil}}
        else
          with {:ok, bytes} <-
                 read_section(store, manifest.generation, manifest.hash, descriptor.name),
               {:ok, %{} = content} <- Canonical.decode(bytes) do
            {:ok, %{descriptor: descriptor, tombstone: false, content: content}}
          else
            {:ok, _other} -> {:error, :section_content_must_be_map}
            {:error, _reason} = error -> error
          end
        end

      case result do
        {:ok, section} -> {:cont, {:ok, Map.put(acc, descriptor.name, section)}}
        {:error, reason} -> {:halt, {:error, {descriptor.name, reason}}}
      end
    end)
  end

  @spec activate(t(), pos_integer(), binary()) :: {:ok, map() | nil} | {:error, term()}
  def activate(%__MODULE__{} = store, generation, manifest_hash) do
    with {:ok, candidate} <- candidate_pointer(store, generation, manifest_hash),
         {:ok, active} <- active_or_nil(store),
         previous = prior_for_candidate(active, candidate),
         :ok <- validate_activation_transition(previous, candidate) do
      if previous == candidate do
        {:ok, previous}
      else
        with {:ok, _journal} <- prepare_activation(store, generation, manifest_hash),
             {:ok, ^previous} <- commit_activation(store),
             :ok <- complete_activation(store) do
          {:ok, previous}
        end
      end
    end
  end

  @spec prepare_activation(t(), pos_integer(), binary()) :: {:ok, map()} | {:error, term()}
  def prepare_activation(%__MODULE__{} = store, generation, manifest_hash) do
    with {:ok, candidate} <- candidate_pointer(store, generation, manifest_hash) do
      case activation_journal(store) do
        :empty ->
          create_activation_journal(store, candidate)

        {:ok, %{candidate: ^candidate} = journal} ->
          {:ok, journal}

        {:ok, _journal} ->
          {:error, :activation_in_progress}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp create_activation_journal(store, candidate) do
    with {:ok, active} <- active_or_nil(store),
         previous = prior_for_candidate(active, candidate),
         :ok <- validate_activation_transition(previous, candidate),
         journal = %{
           storage_epoch: store.storage_epoch,
           prior: previous,
           candidate: candidate,
           decision: nil,
           terminal_ack: nil
         },
         :ok <-
           write_identity_record_authoritative(
             store,
             activation_journal_path(store),
             :activation_journal,
             journal
           ) do
      {:ok, journal}
    end
  end

  @spec activation_journal(t()) :: {:ok, map()} | :empty | {:error, term()}
  def activation_journal(%__MODULE__{} = store) do
    case read_identity_record(store, activation_journal_path(store), :activation_journal) do
      {:ok, journal} -> validate_activation_journal(journal, store)
      status when status in [:empty, :legacy] -> :empty
      {:error, :corrupt_record} -> {:error, :corrupt_activation_journal}
      {:error, _reason} = error -> error
    end
  end

  @spec commit_activation(t()) :: {:ok, map() | nil} | {:error, term()}
  def commit_activation(%__MODULE__{} = store) do
    with {:ok, %{prior: prior, candidate: candidate} = journal} <- activation_journal(store),
         :ok <- ensure_undecided_activation(journal),
         {:ok, active} <- active_or_nil(store),
         current = prior_for_candidate(active, candidate),
         :ok <- validate_commit_position(current, prior, candidate),
         :ok <- write_active_pointer_authoritative(store, candidate) do
      {:ok, prior}
    else
      :empty -> {:error, :activation_journal_missing}
      {:error, _reason} = error -> error
    end
  end

  @doc "Restore the prior pointer while retaining the undecided journal for guarded retry."
  @spec restore_activation_prior(t()) :: :ok | {:error, term()}
  def restore_activation_prior(%__MODULE__{} = store) do
    with {:ok, %{prior: prior, candidate: candidate} = journal} <- activation_journal(store),
         :ok <- ensure_undecided_activation(journal),
         {:ok, active} <- activation_position_or_nil(store),
         current = prior_for_candidate(active, candidate),
         :ok <- validate_commit_position(current, prior, candidate),
         :ok <- recover_pointer(store, prior) do
      :ok
    else
      :empty -> {:error, :activation_journal_missing}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Durably bind an activation outcome to the exact terminal ACK that reports it.

  A decided outcome is immutable. After a reboot, the same outcome may replace
  only the ACK's boot identity so the recovered authority can be reported by
  the current boot.
  """
  @spec record_activation_decision(t(), :candidate | :prior, map()) ::
          :ok | {:error, term()}
  def record_activation_decision(%__MODULE__{} = store, decision, terminal_ack)
      when decision in [:candidate, :prior] and is_map(terminal_ack) do
    with {:ok, journal} <- activation_journal(store),
         :ok <- validate_terminal_decision(decision, terminal_ack, journal, store) do
      case {journal.decision, journal.terminal_ack} do
        {nil, nil} ->
          persist_activation_decision(store, journal, decision, terminal_ack)

        {^decision, ^terminal_ack} ->
          :ok

        {^decision, prior_ack} ->
          if terminal_ack_boot_rebind?(prior_ack, terminal_ack) do
            persist_activation_decision(store, journal, decision, terminal_ack)
          else
            {:error, :activation_decision_conflict}
          end

        {_other_decision, _other_ack} ->
          {:error, :activation_decision_conflict}
      end
    else
      :empty -> {:error, :activation_journal_missing}
      {:error, _reason} = error -> error
    end
  end

  def record_activation_decision(%__MODULE__{}, _decision, _terminal_ack),
    do: {:error, :invalid_activation_decision}

  defp persist_activation_decision(store, journal, decision, terminal_ack) do
    decided = %{journal | decision: decision, terminal_ack: terminal_ack}

    write_identity_record_authoritative(
      store,
      activation_journal_path(store),
      :activation_journal,
      decided
    )
  end

  defp terminal_ack_boot_rebind?(prior_ack, terminal_ack) do
    Map.get(prior_ack, :boot_id) != Map.get(terminal_ack, :boot_id) and
      Map.delete(prior_ack, :boot_id) == Map.delete(terminal_ack, :boot_id)
  end

  @doc "Make the pointer selected by a durable activation decision authoritative."
  @spec commit_activation_decision(t()) :: {:ok, map()} | {:error, term()}
  def commit_activation_decision(%__MODULE__{} = store) do
    with {:ok, %{decision: decision, terminal_ack: terminal_ack} = journal}
         when decision in [:candidate, :prior] and is_map(terminal_ack) <-
           activation_journal(store),
         {:ok, active} <- activation_position_or_nil(store),
         current = prior_for_candidate(active, journal.candidate),
         :ok <- validate_commit_position(current, journal.prior, journal.candidate),
         :ok <- recover_pointer(store, Map.fetch!(journal, decision)) do
      {:ok, journal}
    else
      :empty -> {:error, :activation_journal_missing}
      {:ok, _undecided} -> {:error, :activation_decision_missing}
      {:error, _reason} = error -> error
    end
  end

  @spec complete_activation(t()) :: :ok | {:error, term()}
  def complete_activation(%__MODULE__{} = store) do
    remove_record_authoritative(store, activation_journal_path(store))
  end

  @spec recover_activation(t(), :candidate | :prior) :: :ok | {:error, term()}
  def recover_activation(%__MODULE__{} = store, decision) when decision in [:candidate, :prior] do
    with {:ok, journal} <- activation_journal(store),
         :ok <- ensure_undecided_activation(journal),
         :ok <- recover_pointer(store, Map.fetch!(journal, decision)),
         :ok <- complete_activation(store) do
      :ok
    else
      :empty -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec active(t()) :: {:ok, map()} | :empty | {:error, term()}
  def active(%__MODULE__{} = store) do
    case read_identity_record(store, active_pointer_path(store), :active_pointer) do
      {:ok, pointer} -> validate_active_pointer(pointer, store)
      status when status in [:empty, :legacy] -> :empty
      {:error, :corrupt_record} -> {:error, :corrupt_active_pointer}
      {:error, _reason} = error -> error
    end
  end

  @spec put_pending_ack(t(), map()) :: {:ok, :stored | :unchanged} | {:error, term()}
  def put_pending_ack(%__MODULE__{} = store, ack) when is_map(ack) do
    with :ok <- validate_ack_epoch(ack, store),
         {:ok, encoded} <- Messages.encode(:ack, ack),
         {:ok, entries} <- pending_ack_bytes(store) do
      if encoded in entries do
        {:ok, :unchanged}
      else
        record = %{storage_epoch: store.storage_epoch, entries: entries ++ [encoded]}

        case write_record_authoritative(store, pending_acks_path(store), :pending_acks, record) do
          :ok -> {:ok, :stored}
          {:error, _reason} = error -> error
        end
      end
    end
  end

  def put_pending_ack(%__MODULE__{}, _ack), do: {:error, :invalid_ack}

  @spec pending_acks(t()) :: {:ok, [map()]} | {:error, term()}
  def pending_acks(%__MODULE__{} = store) do
    with {:ok, entries} <- pending_ack_bytes(store) do
      Enum.reduce_while(entries, {:ok, []}, fn encoded, {:ok, acc} ->
        case Messages.decode(:ack, encoded) do
          {:ok, ack} ->
            case validate_ack_epoch(ack, store) do
              :ok -> {:cont, {:ok, [ack | acc]}}
              {:error, :storage_epoch_mismatch} = error -> {:halt, error}
              {:error, _reason} -> {:halt, {:error, :corrupt_pending_acks}}
            end

          {:error, _reason} ->
            {:halt, {:error, :corrupt_pending_acks}}
        end
      end)
      |> case do
        {:ok, acks} -> {:ok, Enum.reverse(acks)}
        error -> error
      end
    end
  end

  @doc """
  Delete an exact pending ACK after its durable-delivery boundary is established.

  A successful socket send is not that boundary. Callers must first verify an
  authenticated backend receipt or an explicitly authorized durable-data loss.
  """
  @spec delete_pending_ack(t(), map()) :: :ok | {:error, term()}
  def delete_pending_ack(%__MODULE__{} = store, ack) when is_map(ack) do
    with :ok <- validate_ack_epoch(ack, store),
         {:ok, encoded} <- Messages.encode(:ack, ack),
         {:ok, entries} <- pending_ack_bytes(store) do
      record = %{storage_epoch: store.storage_epoch, entries: Enum.reject(entries, &(&1 == encoded))}
      write_record_authoritative(store, pending_acks_path(store), :pending_acks, record)
    end
  end

  @spec generation_directory(t(), pos_integer(), binary()) :: Path.t()
  def generation_directory(%__MODULE__{} = store, generation, manifest_hash) do
    Path.join([
      store.base_dir,
      "generations",
      "#{generation}-#{Base.encode16(manifest_hash, case: :lower)}"
    ])
  end

  @spec manifest_path(t(), pos_integer(), binary()) :: Path.t()
  def manifest_path(store, generation, manifest_hash),
    do: Path.join(generation_directory(store, generation, manifest_hash), "manifest.bin")

  @spec generation_state_path(t(), pos_integer(), binary()) :: Path.t()
  def generation_state_path(store, generation, manifest_hash),
    do: Path.join(generation_directory(store, generation, manifest_hash), "state.term")

  @spec chunk_path(t(), pos_integer(), binary(), atom(), non_neg_integer()) :: Path.t()
  def chunk_path(store, generation, manifest_hash, section, index) do
    Path.join([
      generation_directory(store, generation, manifest_hash),
      "chunks",
      Atom.to_string(section),
      Integer.to_string(index) <> ".bin"
    ])
  end

  @spec section_path(t(), pos_integer(), binary(), atom()) :: Path.t()
  def section_path(store, generation, manifest_hash, section) do
    Path.join([
      generation_directory(store, generation, manifest_hash),
      "sections",
      Atom.to_string(section) <> ".bin"
    ])
  end

  @spec active_pointer_path(t()) :: Path.t()
  def active_pointer_path(%__MODULE__{} = store), do: Path.join(store.base_dir, @active_filename)

  @spec pending_acks_path(t()) :: Path.t()
  def pending_acks_path(%__MODULE__{} = store), do: Path.join(store.base_dir, @pending_acks_filename)

  @spec activation_journal_path(t()) :: Path.t()
  def activation_journal_path(%__MODULE__{} = store), do: Path.join(store.base_dir, @activation_filename)

  defp validate_store_epoch(%{storage_epoch: epoch})
       when is_binary(epoch) and byte_size(epoch) == 16 and epoch != <<0::128>>,
       do: :ok

  defp validate_store_epoch(_store), do: {:error, :invalid_storage_epoch}

  defp validate_manifest_delivery(store, delivery, manifest) do
    cond do
      Map.get(delivery, :device_id) != manifest.device_id -> {:error, :manifest_device_mismatch}
      Map.get(delivery, :credential_epoch) != manifest.credential_epoch -> {:error, :manifest_credential_epoch_mismatch}
      Map.get(delivery, :generation) != manifest.generation -> {:error, :manifest_generation_mismatch}
      not secure_equal(Map.get(delivery, :manifest_hash), manifest.hash) -> {:error, :manifest_hash_mismatch}
      Map.get(delivery, :storage_epoch) != store.storage_epoch -> {:error, :storage_epoch_mismatch}
      true -> :ok
    end
  end

  defp validate_wifi_descriptor(manifest) do
    case Enum.find(manifest.sections, &(&1.name == :wifi)) do
      %{tombstone: true} ->
        :ok

      %{content_length: length} ->
        if length <= Contract.chunk_size(), do: :ok, else: {:error, :wifi_content_too_large}

      nil ->
        {:error, :missing_section}
    end
  end

  defp claim_generation(store, manifest) do
    reference = %{
      device_id: manifest.device_id,
      credential_epoch: manifest.credential_epoch,
      storage_epoch: store.storage_epoch,
      generation: manifest.generation,
      manifest_hash: manifest.hash
    }

    path =
      generation_reference_path(
        store,
        manifest.device_id,
        manifest.credential_epoch,
        manifest.generation
      )

    case read_identity_record(store, path, :generation_reference) do
      :empty ->
        write_identity_record(store, path, :generation_reference, reference)

      {:ok, existing} ->
        validate_generation_claim(existing, reference, store)

      :legacy ->
        {:error, :corrupt_generation_reference}

      {:error, _reason} ->
        {:error, :corrupt_generation_reference}
    end
  end

  defp validate_generation_claim(
         %{
           device_id: device_id,
           credential_epoch: credential_epoch,
           storage_epoch: storage_epoch,
           generation: generation,
           manifest_hash: manifest_hash
         },
         expected,
         store
       ) do
    with :ok <- ensure_epoch(%{storage_epoch: storage_epoch}, store),
         true <- secure_equal(device_id, expected.device_id),
         true <- credential_epoch == expected.credential_epoch,
         true <- generation == expected.generation,
         true <- secure_equal(manifest_hash, expected.manifest_hash) do
      :ok
    else
      {:error, :storage_epoch_mismatch} = error -> error
      _other -> {:error, :generation_hash_conflict}
    end
  end

  defp validate_generation_claim(_existing, _expected, _store),
    do: {:error, :generation_hash_conflict}

  defp persist_manifest_and_state(store, manifest) do
    case generation_state(store, manifest.generation, manifest.hash) do
      {:ok, _state} ->
        with {:ok, bytes} <- read_file(store, manifest_path(store, manifest.generation, manifest.hash)),
             true <- bytes == manifest.bytes || {:error, :generation_hash_conflict} do
          {:ok, :unchanged}
        else
          false -> {:error, :generation_hash_conflict}
          {:error, _reason} = error -> error
        end

      :empty ->
        state = %{
          storage_epoch: store.storage_epoch,
          credential_epoch: manifest.credential_epoch,
          generation: manifest.generation,
          manifest_hash: manifest.hash,
          status: :receiving,
          received: %{}
        }

        with :ok <- write_file(store, manifest_path(store, manifest.generation, manifest.hash), manifest.bytes),
             :ok <- write_generation_state(store, state) do
          {:ok, :staged}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_chunk_payload(store, payload, manifest) do
    descriptor = Enum.find(manifest.sections, &(&1.name == Map.get(payload, :section)))

    cond do
      Map.get(payload, :storage_epoch) != store.storage_epoch ->
        {:error, :storage_epoch_mismatch}

      Map.get(payload, :device_id) != manifest.device_id ->
        {:error, :chunk_device_mismatch}

      Map.get(payload, :credential_epoch) != manifest.credential_epoch ->
        {:error, :chunk_credential_epoch_mismatch}

      is_nil(descriptor) ->
        {:error, :chunk_bounds}

      descriptor.tombstone ->
        {:error, :chunk_bounds}

      Map.get(payload, :generation) != manifest.generation ->
        {:error, :chunk_bounds}

      not secure_equal(Map.get(payload, :manifest_hash), manifest.hash) ->
        {:error, :chunk_bounds}

      Map.get(payload, :section_schema_version) != descriptor.schema_version ->
        {:error, :chunk_bounds}

      not secure_equal(Map.get(payload, :section_hash), descriptor.hash) ->
        {:error, :chunk_bounds}

      Map.get(payload, :total_content_length) != descriptor.content_length ->
        {:error, :chunk_bounds}

      not valid_chunk_geometry?(payload, descriptor.content_length) ->
        {:error, :chunk_bounds}

      descriptor.name == :wifi ->
        case Section.verify(descriptor, Map.fetch!(payload, :chunk)) do
          {:ok, _section} -> {:ok, descriptor}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:ok, descriptor}
    end
  end

  defp valid_chunk_geometry?(payload, total_length) do
    count = div(total_length + Contract.chunk_size() - 1, Contract.chunk_size())
    index = Map.get(payload, :chunk_index)
    offset = Map.get(payload, :chunk_offset)
    chunk = Map.get(payload, :chunk)

    is_integer(index) and index >= 0 and index < count and Map.get(payload, :chunk_count) == count and
      offset == index * Contract.chunk_size() and is_binary(chunk) and
      byte_size(chunk) == min(Contract.chunk_size(), total_length - offset)
  end

  defp persist_chunk(store, state, descriptor, payload) do
    path = chunk_path(store, state.generation, state.manifest_hash, descriptor.name, payload.chunk_index)

    case read_file(store, path) do
      {:ok, existing} when existing == payload.chunk ->
        with :ok <- persist_receipt(store, state, descriptor.name, payload.chunk_index) do
          {:ok, :unchanged}
        end

      {:ok, existing} when byte_size(existing) != byte_size(payload.chunk) ->
        with :ok <- write_file(store, path, payload.chunk),
             :ok <- persist_receipt(store, state, descriptor.name, payload.chunk_index) do
          {:ok, :stored}
        end

      {:ok, _different} ->
        {:error, :chunk_conflict}

      {:error, :enoent} ->
        with :ok <- write_file(store, path, payload.chunk),
             :ok <- persist_receipt(store, state, descriptor.name, payload.chunk_index) do
          {:ok, :stored}
        end

      {:error, reason} ->
        {:error, {:read_chunk, reason}}
    end
  end

  defp persist_receipt(store, state, name, index) do
    indices = state.received |> Map.get(name, []) |> then(&Enum.sort(Enum.uniq([index | &1])))
    write_generation_state(store, %{state | received: Map.put(state.received, name, indices)})
  end

  defp build_resume(store, state, manifest) do
    Enum.reduce_while(manifest.sections, {:ok, %{}, []}, fn descriptor, {:ok, received_acc, incomplete_acc} ->
      if descriptor.tombstone do
        {:cont, {:ok, received_acc, incomplete_acc}}
      else
        count = chunk_count(descriptor.content_length)

        case verified_present_chunk_indices(store, manifest, descriptor) do
          {:ok, present} ->
            missing = missing_ranges(count, present)
            received_acc = Map.put(received_acc, descriptor.name, present)

            incomplete_acc =
              if missing == [] do
                incomplete_acc
              else
                [
                  %{
                    section: descriptor.name,
                    section_schema_version: descriptor.schema_version,
                    section_hash: descriptor.hash,
                    total_content_length: descriptor.content_length,
                    missing_ranges: missing
                  }
                  | incomplete_acc
                ]
              end

            {:cont, {:ok, received_acc, incomplete_acc}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end
    end)
    |> case do
      {:ok, received, incomplete} ->
        updated = %{state | received: received} |> Map.put(:persisted_received, state.received)
        {:ok, updated, Enum.reverse(incomplete)}

      {:error, _reason} = error ->
        error
    end
  end

  defp verified_present_chunk_indices(store, manifest, descriptor) do
    count = chunk_count(descriptor.content_length)

    result =
      Enum.reduce_while(0..(count - 1), {:ok, []}, fn index, {:ok, present} ->
        path = chunk_path(store, manifest.generation, manifest.hash, descriptor.name, index)

        case read_file(store, path) do
          {:ok, chunk} ->
            if byte_size(chunk) == expected_chunk_length(index, count, descriptor.content_length) do
              {:cont, {:ok, [index | present]}}
            else
              {:cont, {:ok, present}}
            end

          {:error, :enoent} ->
            {:cont, {:ok, present}}

          {:error, reason} ->
            {:halt, {:error, {:read_chunk, reason}}}
        end
      end)

    with {:ok, reversed_present} <- result do
      present = Enum.reverse(reversed_present)

      if length(present) == count do
        with {:ok, content} <- read_complete_content(store, manifest, descriptor) do
          case Section.verify(descriptor, content) do
            {:ok, _section} -> {:ok, present}
            {:error, _reason} -> remove_section_chunks(store, manifest, descriptor)
          end
        end
      else
        {:ok, present}
      end
    end
  end

  defp remove_section_chunks(store, manifest, descriptor) do
    count = chunk_count(descriptor.content_length)

    Enum.reduce_while(0..(count - 1), :ok, fn index, :ok ->
      path = chunk_path(store, manifest.generation, manifest.hash, descriptor.name, index)

      case AtomicFile.remove(path, atomic_opts(store)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  defp missing_ranges(count, present) do
    present = MapSet.new(present)

    0..(count - 1)
    |> Enum.reject(&MapSet.member?(present, &1))
    |> Enum.reduce([], fn index, acc ->
      case acc do
        [%{first_chunk_index: first, chunk_count: range_count} = current | rest]
        when first + range_count == index ->
          [%{current | chunk_count: range_count + 1} | rest]

        _ ->
          [%{first_chunk_index: index, chunk_count: 1} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp verify_sections(store, manifest) do
    Enum.reduce_while(manifest.sections, {:ok, []}, fn descriptor, {:ok, acc} ->
      content_result =
        if descriptor.tombstone do
          {:ok, <<>>}
        else
          read_complete_content(store, manifest, descriptor)
        end

      case content_result do
        {:ok, content} ->
          case Section.verify(descriptor, content) do
            {:ok, _section} -> {:cont, {:ok, [{descriptor.name, content} | acc]}}
            {:error, reason} -> {:halt, {:error, reason, descriptor.name}}
          end

        {:error, reason} ->
          {:halt, {:error, reason, descriptor.name}}
      end
    end)
    |> case do
      {:ok, verified} -> {:ok, Enum.reverse(verified)}
      error -> error
    end
  end

  defp read_complete_content(store, manifest, descriptor) do
    count = chunk_count(descriptor.content_length)

    Enum.reduce_while(0..(count - 1), {:ok, []}, fn index, {:ok, acc} ->
      path = chunk_path(store, manifest.generation, manifest.hash, descriptor.name, index)

      case read_file(store, path) do
        {:ok, chunk} ->
          if byte_size(chunk) == expected_chunk_length(index, count, descriptor.content_length) do
            {:cont, {:ok, [chunk | acc]}}
          else
            {:halt, {:error, :chunk_bounds}}
          end

        {:error, :enoent} ->
          {:halt, {:error, :transfer_incomplete}}

        {:error, reason} ->
          {:halt, {:error, {:read_chunk, reason}}}
      end
    end)
    |> case do
      {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp persist_verified_sections(store, generation, manifest_hash, verified) do
    Enum.reduce_while(verified, :ok, fn {name, content}, :ok ->
      case write_file(store, section_path(store, generation, manifest_hash, name), content) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp complete_receipts(manifest) do
    Map.new(Enum.reject(manifest.sections, & &1.tombstone), fn descriptor ->
      {descriptor.name, Enum.to_list(0..(chunk_count(descriptor.content_length) - 1))}
    end)
  end

  defp chunk_count(length), do: div(length + Contract.chunk_size() - 1, Contract.chunk_size())

  defp expected_chunk_length(index, count, total_length) when index == count - 1,
    do: total_length - index * Contract.chunk_size()

  defp expected_chunk_length(_index, _count, _total_length), do: Contract.chunk_size()

  defp write_generation_state(store, state) do
    state = Map.delete(state, :persisted_received)
    write_record(store, generation_state_path(store, state.generation, state.manifest_hash), :generation_state, state)
  end

  defp decode_generation_state(bytes, store, generation, manifest_hash) do
    with {:ok,
          %{
            storage_epoch: storage_epoch,
            credential_epoch: credential_epoch,
            generation: stored_generation,
            manifest_hash: stored_hash,
            status: status,
            received: received
          } = state} <- decode_record(bytes, :generation_state),
         :ok <- ensure_epoch(%{storage_epoch: storage_epoch}, store),
         true <- is_integer(credential_epoch) and credential_epoch >= 0,
         true <- stored_generation == generation,
         true <- secure_equal(stored_hash, manifest_hash),
         true <- status in [:receiving, :staged],
         true <- valid_receipts?(received) do
      {:ok, state}
    else
      {:error, :storage_epoch_mismatch} = error -> error
      _other -> {:error, :corrupt_generation_state}
    end
  end

  defp valid_receipts?(received) when is_map(received) do
    Enum.all?(received, fn
      {name, indices} when is_atom(name) and is_list(indices) ->
        name in Contract.sections() and
          Enum.all?(indices, &(is_integer(&1) and &1 >= 0)) and
          indices == Enum.sort(Enum.uniq(indices))

      _other ->
        false
    end)
  end

  defp valid_receipts?(_received), do: false

  defp load_manifest(store, generation, manifest_hash) do
    with {:ok, bytes} <- read_file(store, manifest_path(store, generation, manifest_hash)) do
      decode_manifest(bytes, generation, manifest_hash)
    else
      {:error, :enoent} -> {:error, :manifest_missing}
      {:error, _reason} = error -> error
    end
  end

  defp load_activation_manifest(store, generation, manifest_hash) do
    case read_file(store, manifest_path(store, generation, manifest_hash)) do
      {:ok, bytes} ->
        decode_manifest(bytes, generation, manifest_hash)

      {:error, :enoent} ->
        {:error, :manifest_missing}

      {:error, reason} ->
        {:error, {:read_activation_manifest, reason}}
    end
  end

  defp decode_manifest(bytes, generation, manifest_hash) do
    with {:ok, manifest} <- Manifest.decode(bytes),
         true <- manifest.generation == generation || {:error, :corrupt_manifest},
         true <- secure_equal(manifest.hash, manifest_hash) || {:error, :corrupt_manifest} do
      {:ok, manifest}
    else
      {:error, _reason} = error -> error
      false -> {:error, :corrupt_manifest}
    end
  end

  defp active_or_nil(store) do
    case active(store) do
      {:ok, pointer} -> {:ok, pointer}
      :empty -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp activation_position_or_nil(store) do
    case read_identity_record(store, active_pointer_path(store), :active_pointer) do
      status when status in [:empty, :legacy] ->
        {:ok, nil}

      {:ok, pointer} ->
        case validate_pointer_shape(pointer, store) do
          {:ok, pointer} -> {:ok, pointer}
          {:error, :storage_epoch_mismatch} = error -> error
          {:error, _reason} -> {:error, :corrupt_active_pointer}
        end

      {:error, :corrupt_record} ->
        {:error, :corrupt_active_pointer}

      {:error, _reason} = error ->
        error
    end
  end

  defp candidate_pointer(store, generation, manifest_hash) do
    case fetch_generation_state(store, generation, manifest_hash) do
      {:ok, %{status: :staged, credential_epoch: credential_epoch}} ->
        with {:ok, manifest} <- load_manifest(store, generation, manifest_hash),
             true <- manifest.credential_epoch == credential_epoch || {:error, :active_generation_mismatch},
             pointer = %{
               device_id: manifest.device_id,
               credential_epoch: credential_epoch,
               storage_epoch: store.storage_epoch,
               generation: generation,
               manifest_hash: manifest_hash
             },
             :ok <- validate_pointer_target(pointer, store) do
          {:ok, pointer}
        else
          false -> {:error, :active_generation_mismatch}
          {:error, _reason} = error -> error
        end

      {:ok, _state} ->
        {:error, :generation_not_staged}

      {:error, _reason} = error ->
        error
    end
  end

  defp prior_for_candidate(nil, _candidate), do: nil

  defp prior_for_candidate(previous, candidate) do
    if secure_equal(previous.device_id, candidate.device_id), do: previous, else: nil
  end

  defp validate_activation_transition(nil, _candidate), do: :ok
  defp validate_activation_transition(pointer, pointer), do: :ok

  defp validate_activation_transition(previous, candidate) do
    cond do
      not secure_equal(candidate.device_id, previous.device_id) ->
        {:error, :device_mismatch}

      candidate.credential_epoch < previous.credential_epoch ->
        {:error, :credential_epoch_downgrade}

      candidate.credential_epoch == previous.credential_epoch and
          candidate.generation < previous.generation ->
        {:error, :generation_downgrade}

      candidate.credential_epoch == previous.credential_epoch and
          candidate.generation == previous.generation ->
        {:error, :generation_hash_conflict}

      true ->
        :ok
    end
  end

  defp validate_commit_position(current, prior, candidate) when current == prior or current == candidate,
    do: :ok

  defp validate_commit_position(_current, _prior, _candidate), do: {:error, :activation_position_changed}

  defp validate_active_pointer(pointer, store) do
    with {:ok, pointer} <- validate_pointer_shape(pointer, store),
         :ok <- validate_pointer_target(pointer, store) do
      {:ok, pointer}
    else
      {:error, :storage_epoch_mismatch} = error ->
        error

      {:error, reason} when reason in [:active_generation_missing, :active_generation_not_staged] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :corrupt_active_pointer}
    end
  end

  defp validate_pointer_shape(
         %{
           device_id: device_id,
           storage_epoch: storage_epoch,
           credential_epoch: credential_epoch,
           generation: generation,
           manifest_hash: manifest_hash
         },
         store
       ) do
    with :ok <- ensure_epoch(%{storage_epoch: storage_epoch}, store),
         true <- valid_device_id?(device_id),
         true <- is_integer(credential_epoch) and credential_epoch >= 0,
         true <- is_integer(generation) and generation > 0,
         true <- is_binary(manifest_hash) and byte_size(manifest_hash) == 32 do
      {:ok,
       %{
         device_id: device_id,
         storage_epoch: storage_epoch,
         credential_epoch: credential_epoch,
         generation: generation,
         manifest_hash: manifest_hash
       }}
    else
      {:error, :storage_epoch_mismatch} = error -> error
      _other -> {:error, :corrupt_pointer}
    end
  end

  defp validate_pointer_shape(_pointer, _store), do: {:error, :corrupt_pointer}

  defp validate_pointer_target(pointer, store) do
    case generation_state(store, pointer.generation, pointer.manifest_hash) do
      :empty ->
        {:error, :active_generation_missing}

      {:ok, %{status: :receiving}} ->
        {:error, :active_generation_not_staged}

      {:ok, %{status: :staged, credential_epoch: credential_epoch}}
      when credential_epoch == pointer.credential_epoch ->
        with {:ok, manifest} <- load_pointer_manifest(store, pointer),
             :ok <- validate_pointer_manifest(pointer, manifest),
             :ok <- validate_generation_reference(store, pointer) do
          validate_persisted_sections(store, pointer, manifest)
        end

      {:ok, _state} ->
        {:error, :active_generation_mismatch}

      {:error, _reason} = error ->
        error
    end
  end

  defp load_pointer_manifest(store, pointer) do
    case load_manifest(store, pointer.generation, pointer.manifest_hash) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, _reason} -> {:error, :active_generation_missing}
    end
  end

  defp validate_pointer_manifest(pointer, manifest) do
    cond do
      not secure_equal(pointer.device_id, manifest.device_id) ->
        {:error, :active_generation_mismatch}

      pointer.credential_epoch != manifest.credential_epoch ->
        {:error, :active_generation_mismatch}

      true ->
        :ok
    end
  end

  defp validate_generation_reference(store, pointer) do
    path =
      generation_reference_path(
        store,
        pointer.device_id,
        pointer.credential_epoch,
        pointer.generation
      )

    case read_identity_record(store, path, :generation_reference) do
      {:ok, reference} -> validate_generation_claim(reference, pointer, store)
      :empty -> {:error, :active_generation_missing}
      :legacy -> {:error, :corrupt_generation_reference}
      {:error, _reason} -> {:error, :corrupt_generation_reference}
    end
  end

  defp validate_persisted_sections(store, pointer, manifest) do
    Enum.reduce_while(manifest.sections, :ok, fn descriptor, :ok ->
      case read_section(store, pointer.generation, pointer.manifest_hash, descriptor.name) do
        {:ok, _bytes} -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :active_generation_missing}}
      end
    end)
  end

  defp validate_activation_journal(
         %{storage_epoch: storage_epoch, prior: prior, candidate: candidate} = journal,
         store
       ) do
    decision = Map.get(journal, :decision)
    terminal_ack = Map.get(journal, :terminal_ack)

    with :ok <- ensure_epoch(%{storage_epoch: storage_epoch}, store),
         {:ok, candidate} <- validate_pointer_shape(candidate, store),
         {:ok, prior} <- validate_optional_pointer_shape(prior, store),
         :ok <- validate_activation_transition(prior, candidate),
         :ok <-
           validate_optional_terminal_decision(
             decision,
             terminal_ack,
             prior,
             candidate,
             store
           ),
         :ok <- validate_activation_journal_targets(decision, prior, candidate, store) do
      {:ok,
       %{
         storage_epoch: storage_epoch,
         prior: prior,
         candidate: candidate,
         decision: decision,
         terminal_ack: terminal_ack
       }}
    else
      {:error, :storage_epoch_mismatch} = error -> error
      {:error, {:read_activation_manifest, _reason}} = error -> error
      _other -> {:error, :corrupt_activation_journal}
    end
  end

  defp validate_activation_journal(_journal, _store), do: {:error, :corrupt_activation_journal}

  defp validate_optional_pointer_shape(nil, _store), do: {:ok, nil}
  defp validate_optional_pointer_shape(pointer, store), do: validate_pointer_shape(pointer, store)

  defp validate_activation_journal_targets(nil, prior, candidate, store) do
    with :ok <- validate_pointer_target(candidate, store),
         :ok <- validate_optional_pointer_target(prior, store) do
      :ok
    end
  end

  defp validate_activation_journal_targets(:candidate, _prior, candidate, store),
    do: validate_pointer_target(candidate, store)

  defp validate_activation_journal_targets(:prior, prior, _candidate, store),
    do: validate_optional_pointer_target(prior, store)

  defp validate_activation_journal_targets(_decision, _prior, _candidate, _store),
    do: {:error, :invalid_activation_decision}

  defp validate_optional_pointer_target(nil, _store), do: :ok
  defp validate_optional_pointer_target(pointer, store), do: validate_pointer_target(pointer, store)

  defp validate_optional_terminal_decision(nil, nil, _prior, _candidate, _store), do: :ok

  defp validate_optional_terminal_decision(decision, terminal_ack, prior, candidate, store)
       when decision in [:candidate, :prior] and is_map(terminal_ack) do
    validate_terminal_decision(
      decision,
      terminal_ack,
      %{prior: prior, candidate: candidate},
      store
    )
  end

  defp validate_optional_terminal_decision(
         _decision,
         _terminal_ack,
         _prior,
         _candidate,
         _store
       ),
       do: {:error, :invalid_activation_decision}

  defp validate_terminal_decision(decision, terminal_ack, journal, store) do
    candidate = Map.fetch!(journal, :candidate)
    expected_status = if decision == :candidate, do: :effective, else: :rejected

    with :ok <- validate_ack_epoch(terminal_ack, store),
         {:ok, _encoded} <- Messages.encode(:ack, terminal_ack),
         true <- Map.get(terminal_ack, :status) == expected_status,
         true <- Map.get(terminal_ack, :credential_epoch) == candidate.credential_epoch,
         true <- Map.get(terminal_ack, :generation) == candidate.generation,
         true <- secure_equal(Map.get(terminal_ack, :manifest_hash), candidate.manifest_hash),
         :ok <- validate_terminal_ack_device(decision, terminal_ack, journal, store) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, :activation_ack_mismatch}
    end
  end

  defp validate_terminal_ack_device(
         :candidate,
         terminal_ack,
         %{prior: prior, candidate: candidate},
         store
       ) do
    with {:ok, device_id} <- pointer_manifest_device_id(store, candidate),
         true <- secure_equal(Map.get(terminal_ack, :device_id), device_id),
         :ok <- validate_unselected_pointer_device(store, prior, device_id) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, :activation_ack_mismatch}
    end
  end

  defp validate_terminal_ack_device(
         :prior,
         terminal_ack,
         %{prior: nil, candidate: candidate},
         store
       ) do
    with {:ok, device_id} <- pointer_manifest_device_id(store, candidate),
         true <- secure_equal(Map.get(terminal_ack, :device_id), device_id) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, :activation_ack_mismatch}
    end
  end

  defp validate_terminal_ack_device(
         :prior,
         terminal_ack,
         %{prior: prior, candidate: candidate},
         store
       ) do
    with {:ok, device_id} <- pointer_manifest_device_id(store, prior),
         true <- secure_equal(Map.get(terminal_ack, :device_id), device_id),
         :ok <- validate_unselected_pointer_device(store, candidate, device_id) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, :activation_ack_mismatch}
    end
  end

  defp pointer_manifest_device_id(store, pointer) do
    with {:ok, manifest} <-
           load_activation_manifest(store, pointer.generation, pointer.manifest_hash) do
      {:ok, manifest.device_id}
    end
  end

  defp validate_unselected_pointer_device(_store, nil, _device_id), do: :ok

  defp validate_unselected_pointer_device(store, pointer, device_id) do
    case pointer_manifest_device_id(store, pointer) do
      {:ok, unselected_device_id} ->
        if secure_equal(unselected_device_id, device_id),
          do: :ok,
          else: {:error, :activation_ack_mismatch}

      {:error, _reason} ->
        :ok
    end
  end

  defp ensure_undecided_activation(%{decision: nil, terminal_ack: nil}), do: :ok

  defp ensure_undecided_activation(_journal),
    do: {:error, :activation_decision_already_recorded}

  defp write_active_pointer_authoritative(store, pointer) do
    write_identity_record_authoritative(store, active_pointer_path(store), :active_pointer, pointer)
  end

  defp recover_pointer(store, nil) do
    remove_record_authoritative(store, active_pointer_path(store))
  end

  defp recover_pointer(store, pointer) do
    with :ok <- validate_pointer_target(pointer, store),
         :ok <- write_active_pointer_authoritative(store, pointer) do
      :ok
    end
  end

  defp validate_ack_epoch(%{storage_epoch: epoch}, %{storage_epoch: epoch}), do: :ok

  defp validate_ack_epoch(%{storage_epoch: _other}, _store),
    do: {:error, :storage_epoch_mismatch}

  defp validate_ack_epoch(_ack, _store), do: {:error, :invalid_ack}

  defp pending_ack_bytes(store) do
    case read_record(store, pending_acks_path(store), :pending_acks) do
      :empty ->
        {:ok, []}

      {:ok, %{storage_epoch: _epoch, entries: entries} = record} when is_list(entries) ->
        with :ok <- ensure_epoch(record, store),
             true <- Enum.all?(entries, &is_binary/1) || {:error, :corrupt_pending_acks} do
          {:ok, entries}
        else
          {:error, :storage_epoch_mismatch} = error -> error
          _other -> {:error, :corrupt_pending_acks}
        end

      {:ok, _other} ->
        {:error, :corrupt_pending_acks}

      {:error, _reason} ->
        {:error, :corrupt_pending_acks}
    end
  end

  defp ensure_epoch(%{storage_epoch: epoch}, %{storage_epoch: epoch}), do: :ok
  defp ensure_epoch(%{storage_epoch: _other}, _store), do: {:error, :storage_epoch_mismatch}
  defp ensure_epoch(_record, _store), do: {:error, :corrupt_record}

  defp generation_reference_path(store, device_id, credential_epoch, generation) do
    Path.join([
      store.base_dir,
      "generation_refs",
      Base.encode16(device_id, case: :lower),
      Integer.to_string(credential_epoch),
      Integer.to_string(generation) <> ".term"
    ])
  end

  defp write_identity_record(store, path, type, value) do
    write_file(store, path, :erlang.term_to_binary({@identity_format_version, type, value}))
  end

  defp write_identity_record_authoritative(store, path, type, value) do
    case write_identity_record(store, path, type, value) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        case read_identity_record(store, path, type) do
          {:ok, ^value} -> :ok
          _other -> error
        end
    end
  end

  defp write_record(store, path, type, value) do
    write_file(store, path, :erlang.term_to_binary({@format_version, type, value}))
  end

  defp write_record_authoritative(store, path, type, value) do
    case write_record(store, path, type, value) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        case read_record(store, path, type) do
          {:ok, ^value} -> :ok
          _other -> error
        end
    end
  end

  defp remove_record_authoritative(store, path) do
    case AtomicFile.remove(path, atomic_opts(store)) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        case read_file(store, path) do
          {:error, :enoent} -> :ok
          _other -> error
        end
    end
  end

  defp read_identity_record(store, path, type) do
    case read_file(store, path) do
      {:ok, bytes} -> decode_identity_record(bytes, type)
      {:error, :enoent} -> :empty
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  defp read_record(store, path, type) do
    case read_file(store, path) do
      {:ok, bytes} -> decode_record(bytes, type)
      {:error, :enoent} -> :empty
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  defp decode_identity_record(bytes, type) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      {@identity_format_version, ^type, value} -> {:ok, value}
      {@format_version, ^type, _value} -> :legacy
      _other -> {:error, :corrupt_record}
    end
  rescue
    _exception -> {:error, :corrupt_record}
  end

  defp decode_record(bytes, type) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      {@format_version, ^type, value} -> {:ok, value}
      _other -> {:error, :corrupt_record}
    end
  rescue
    _exception -> {:error, :corrupt_record}
  end

  defp write_file(store, path, bytes), do: AtomicFile.write(path, bytes, atomic_opts(store))
  defp read_file(store, path), do: store.file_system.read(path)

  defp atomic_opts(store) do
    [
      file_system: store.file_system,
      fault_injector: store.fault_injector,
      temp_suffix: store.temp_suffix,
      directory_root: store.base_dir
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp fetch_binary(map, key, reason) do
    case Map.get(map, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, reason}
    end
  end

  defp valid_device_id?(device_id) do
    is_binary(device_id) and byte_size(device_id) == 16 and device_id != @zero_identifier
  end

  defp secure_equal(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_equal(_left, _right), do: false
end
