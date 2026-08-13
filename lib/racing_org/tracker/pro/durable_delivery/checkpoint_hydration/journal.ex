defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.Journal do
  @moduledoc """
  Durable recovery journal for one checkpoint-hydration transition.

  Hydration crosses two separate irreversible stores: the checkpoint head and its
  runtime observer. The journal records the complete authenticated hydration plus
  the exact session, current target identity, and checkpoint-head CAS observation
  needed to resume that transition after a crash. It intentionally persists only
  binary incarnation identifiers, never a process term.

  A journal is created in `:prepared`, may advance once to `:head_committed`, and
  must otherwise remain byte-for-byte identical. Exact rewrites are idempotent;
  replacement and phase regression fail closed until the old transition is durably
  removed.
  """

  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

  @format_version 1
  @record_tag :checkpoint_hydration_journal
  @phases [:prepared, :head_committed]
  @expected_head_states [:absent, :accepted, :local_unaccepted, :fenced, :corrupt]

  @identifier_size 16
  @hash_size 32
  @u32_max 0xFFFF_FFFF
  @u64_max 0xFFFF_FFFF_FFFF_FFFF
  @database_int_max 9_223_372_036_854_775_807
  @max_encoded_size Contract.max_checkpoint_size() + 4_096
  @decode_timeout_ms 1_000
  @decode_max_heap_words 1_000_000
  @lock_wait_ms 1_000
  @lock_retry_ms 2

  @record_keys [
    :version,
    :phase,
    :transaction_id,
    :session_incarnation,
    :session_generation,
    :target,
    :expected_head,
    :hydration
  ]
  @target_keys [:device_id, :credential_epoch, :storage_epoch]
  @expected_head_keys [:state, :checkpoint_hash]
  @hydration_keys [
    :kind,
    :schema_version,
    :origin_credential_epoch,
    :origin_storage_epoch,
    :revision,
    :source_generation,
    :parent_hash,
    :content_hash,
    :checkpoint_hash,
    :content
  ]

  @type phase :: :prepared | :head_committed
  @type target :: %{
          device_id: <<_::128>>,
          credential_epoch: non_neg_integer(),
          storage_epoch: <<_::128>>
        }
  @type expected_head :: %{
          state: :absent | :accepted | :local_unaccepted | :fenced | :corrupt,
          checkpoint_hash: <<_::256>>
        }
  @type hydration :: %{
          kind: atom(),
          schema_version: pos_integer(),
          origin_credential_epoch: non_neg_integer(),
          origin_storage_epoch: <<_::128>>,
          revision: pos_integer(),
          source_generation: non_neg_integer(),
          parent_hash: <<_::256>>,
          content_hash: <<_::256>>,
          checkpoint_hash: <<_::256>>,
          content: binary()
        }
  @type t :: %{
          version: pos_integer(),
          phase: phase(),
          transaction_id: <<_::128>>,
          session_incarnation: <<_::128>>,
          session_generation: non_neg_integer(),
          target: target(),
          expected_head: expected_head(),
          hydration: hydration()
        }

  @doc false
  @spec max_encoded_size() :: pos_integer()
  def max_encoded_size, do: @max_encoded_size

  @doc "Read and fully validate the current journal, or report durable absence."
  @spec read(Path.t(), keyword()) :: :empty | {:ok, t()} | {:error, term()}
  def read(path, opts \\ [])

  def read(path, opts) when is_binary(path) and path != "" and is_list(opts) do
    case safe_fs_call(file_system(opts), :read, [path]) do
      {:ok, bytes} when is_binary(bytes) -> decode(bytes)
      {:error, :enoent} -> :empty
      {:error, reason} -> {:error, {:checkpoint_hydration_journal_io, reason}}
      _other -> {:error, {:checkpoint_hydration_journal_io, :invalid_read_response}}
    end
  end

  def read(_path, _opts), do: {:error, :invalid_checkpoint_hydration_journal_path}

  @doc """
  Create or durably rewrite one journal transition.

  The only non-idempotent update admitted while a journal exists is the exact
  `:prepared` to `:head_committed` phase advance. Success is returned only after
  `AtomicFile` has renamed the complete replacement and synchronized its parent
  directory.
  """
  @spec write(Path.t(), map(), keyword()) :: :ok | {:error, term()}
  def write(path, record, opts \\ [])

  def write(path, record, opts)
      when is_binary(path) and path != "" and is_map(record) and is_list(opts) do
    with {:ok, record} <- validate(record),
         {:ok, bytes} <- encode(record) do
      with_path_lock(path, fn ->
        with :ok <- permit_transition(read(path, opts), record) do
          AtomicFile.write(path, bytes, atomic_opts(path, opts))
        end
      end)
    end
  end

  def write(path, _record, _opts) when not is_binary(path) or path == "",
    do: {:error, :invalid_checkpoint_hydration_journal_path}

  def write(_path, _record, _opts), do: {:error, :invalid_checkpoint_hydration_journal}

  @doc "Durably remove the journal; an already absent journal is idempotent success."
  @spec remove(Path.t(), keyword()) :: :ok | {:error, term()}
  def remove(path, opts \\ [])

  def remove(path, opts) when is_binary(path) and path != "" and is_list(opts),
    do: with_path_lock(path, fn -> AtomicFile.remove(path, atomic_opts(path, opts)) end)

  def remove(_path, _opts), do: {:error, :invalid_checkpoint_hydration_journal_path}

  defp encode(record) do
    bytes = canonical_bytes(record)

    if byte_size(bytes) <= @max_encoded_size,
      do: {:ok, bytes},
      else: {:error, :invalid_checkpoint_hydration_journal}
  end

  defp decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_encoded_size,
    do: bounded_decode(bytes)

  defp decode(_bytes), do: {:error, :corrupt_checkpoint_hydration_journal}

  defp bounded_decode(bytes) do
    owner = self()
    result_ref = make_ref()

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          current_worker = self()
          _watcher = spawn(fn -> stop_decode_on_owner_exit(owner, current_worker) end)
          send(owner, {result_ref, decode_now(bytes)})
        end,
        [
          :monitor,
          {:max_heap_size, %{size: @decode_max_heap_words, kill: true, error_logger: false}}
        ]
      )

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :corrupt_checkpoint_hydration_journal}
    after
      @decode_timeout_ms ->
        Process.exit(worker, :kill)
        await_decode_down(worker, monitor)
        drain_decode_result(result_ref)
        {:error, :corrupt_checkpoint_hydration_journal}
    end
  end

  defp decode_now(bytes) do
    with {@format_version, @record_tag, record} <- safe_term(bytes),
         {:ok, record} <- validate(record),
         true <- secure_equal(canonical_bytes(record), bytes) do
      {:ok, record}
    else
      _other -> {:error, :corrupt_checkpoint_hydration_journal}
    end
  end

  defp validate(record) when is_map(record) do
    with :ok <- exact_keys(record, @record_keys),
         true <- Map.get(record, :version) == @format_version,
         phase when phase in @phases <- Map.get(record, :phase),
         :ok <- nonzero_identifier(Map.get(record, :transaction_id)),
         :ok <- nonzero_identifier(Map.get(record, :session_incarnation)),
         :ok <- u64(Map.get(record, :session_generation)),
         {:ok, target} <- validate_target(Map.get(record, :target)),
         {:ok, expected_head} <- validate_expected_head(Map.get(record, :expected_head)),
         {:ok, hydration} <- validate_hydration(Map.get(record, :hydration), target) do
      {:ok,
       %{
         version: @format_version,
         phase: phase,
         transaction_id: record.transaction_id,
         session_incarnation: record.session_incarnation,
         session_generation: record.session_generation,
         target: target,
         expected_head: expected_head,
         hydration: hydration
       }}
    else
      _other -> {:error, :invalid_checkpoint_hydration_journal}
    end
  end

  defp validate(_record), do: {:error, :invalid_checkpoint_hydration_journal}

  defp validate_target(target) when is_map(target) do
    with :ok <- exact_keys(target, @target_keys),
         :ok <- nonzero_identifier(Map.get(target, :device_id)),
         :ok <- u32(Map.get(target, :credential_epoch)),
         :ok <- nonzero_identifier(Map.get(target, :storage_epoch)) do
      {:ok,
       %{
         device_id: target.device_id,
         credential_epoch: target.credential_epoch,
         storage_epoch: target.storage_epoch
       }}
    end
  end

  defp validate_target(_target), do: {:error, :invalid_checkpoint_hydration_journal}

  defp validate_expected_head(expected) when is_map(expected) do
    with :ok <- exact_keys(expected, @expected_head_keys),
         state when state in @expected_head_states <- Map.get(expected, :state),
         :ok <- fixed_binary(Map.get(expected, :checkpoint_hash), @hash_size),
         :ok <- expected_head_hash(state, expected.checkpoint_hash) do
      {:ok, %{state: state, checkpoint_hash: expected.checkpoint_hash}}
    end
  end

  defp validate_expected_head(_expected),
    do: {:error, :invalid_checkpoint_hydration_journal}

  defp expected_head_hash(:absent, hash) do
    if secure_equal(hash, Record.genesis_parent()),
      do: :ok,
      else: {:error, :invalid_checkpoint_hydration_journal}
  end

  defp expected_head_hash(_state, hash) do
    if secure_equal(hash, Record.genesis_parent()),
      do: {:error, :invalid_checkpoint_hydration_journal},
      else: :ok
  end

  defp validate_hydration(hydration, target) when is_map(hydration) do
    with :ok <- exact_keys(hydration, @hydration_keys),
         {:ok, _kind_code, schema_version} <- Contract.checkpoint_kind(Map.get(hydration, :kind)),
         true <- schema_version == Map.get(hydration, :schema_version),
         :ok <- u32(Map.get(hydration, :origin_credential_epoch)),
         :ok <- nonzero_identifier(Map.get(hydration, :origin_storage_epoch)),
         :ok <- positive_database_int(Map.get(hydration, :revision)),
         :ok <- database_int(Map.get(hydration, :source_generation)),
         :ok <- fixed_binary(Map.get(hydration, :parent_hash), @hash_size),
         :ok <- fixed_binary(Map.get(hydration, :content_hash), @hash_size),
         :ok <- fixed_binary(Map.get(hydration, :checkpoint_hash), @hash_size),
         {:ok, content} <- canonical_content(hydration),
         {:ok, content_hash} <- Checkpoint.content_hash(hydration.kind, schema_version, content),
         true <- secure_equal(content_hash, hydration.content_hash),
         {:ok, checkpoint_hash} <- hydration_hash(target, hydration, content_hash),
         true <- secure_equal(checkpoint_hash, hydration.checkpoint_hash) do
      {:ok,
       %{
         kind: hydration.kind,
         schema_version: schema_version,
         origin_credential_epoch: hydration.origin_credential_epoch,
         origin_storage_epoch: hydration.origin_storage_epoch,
         revision: hydration.revision,
         source_generation: hydration.source_generation,
         parent_hash: hydration.parent_hash,
         content_hash: content_hash,
         checkpoint_hash: checkpoint_hash,
         content: content
       }}
    else
      _other -> {:error, :invalid_checkpoint_hydration_journal}
    end
  end

  defp validate_hydration(_hydration, _target),
    do: {:error, :invalid_checkpoint_hydration_journal}

  defp canonical_content(%{content: content} = hydration) when is_binary(content) do
    with {:ok, decoded} <-
           Checkpoint.decode_content(hydration.kind, hydration.schema_version, content),
         {:ok, canonical} <-
           Checkpoint.encode_content(hydration.kind, hydration.schema_version, decoded),
         true <- secure_equal(canonical, content) do
      {:ok, canonical}
    else
      _other -> {:error, :invalid_checkpoint_hydration_journal}
    end
  end

  defp canonical_content(_hydration),
    do: {:error, :invalid_checkpoint_hydration_journal}

  defp hydration_hash(target, hydration, content_hash) do
    Checkpoint.hash(%{
      device_id: target.device_id,
      credential_epoch: hydration.origin_credential_epoch,
      storage_epoch: hydration.origin_storage_epoch,
      sequence: hydration.revision,
      kind: hydration.kind,
      schema_version: hydration.schema_version,
      source_generation: hydration.source_generation,
      parent_hash: hydration.parent_hash,
      content_hash: content_hash
    })
  end

  defp permit_transition(:empty, %{phase: :prepared}), do: :ok

  defp permit_transition(:empty, _record),
    do: {:error, :checkpoint_hydration_phase_regression}

  defp permit_transition({:ok, existing}, record) do
    cond do
      existing == record ->
        :ok

      same_transition?(existing, record) and existing.phase == :prepared and
          record.phase == :head_committed ->
        :ok

      same_transition?(existing, record) ->
        {:error, :checkpoint_hydration_phase_regression}

      true ->
        {:error, :checkpoint_hydration_transition_conflict}
    end
  end

  defp permit_transition({:error, _reason} = error, _record), do: error

  defp same_transition?(left, right),
    do: Map.delete(left, :phase) == Map.delete(right, :phase)

  defp with_path_lock(path, transition) when is_function(transition, 0) do
    lock_resource = {__MODULE__, :journal_path, Path.expand(path)}
    requester = {self(), make_ref()}
    lock_id = {lock_resource, requester}
    deadline = System.monotonic_time(:millisecond) + @lock_wait_ms

    with {:ok, holder} <- acquire_lock(lock_id, deadline) do
      try do
        run_locked(holder, transition)
      after
        release_lock(holder)
      end
    end
  end

  defp acquire_lock(lock_id, deadline) do
    owner = self()
    acquired_ref = make_ref()

    {holder, monitor} =
      spawn_monitor(fn -> hold_global_lock(owner, acquired_ref, lock_id, deadline) end)

    receive do
      {^acquired_ref, :acquired} -> {:ok, {holder, monitor}}
      {:DOWN, ^monitor, :process, ^holder, :lock_timeout} -> {:error, :checkpoint_hydration_journal_lock_timeout}
      {:DOWN, ^monitor, :process, ^holder, _reason} -> {:error, :checkpoint_hydration_journal_lock_unavailable}
    after
      @lock_wait_ms ->
        Process.exit(holder, :kill)
        await_holder_down(holder, monitor)
        drain_decode_result(acquired_ref)
        {:error, :checkpoint_hydration_journal_lock_timeout}
    end
  end

  defp hold_global_lock(owner, acquired_ref, lock_id, deadline) do
    holder = self()
    _watcher = spawn(fn -> stop_decode_on_owner_exit(owner, holder) end)
    await_global_lock(owner, acquired_ref, lock_id, deadline)
  end

  defp await_global_lock(owner, acquired_ref, lock_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        exit(:lock_timeout)

      :global.set_lock(lock_id, [node()], 0) ->
        send(owner, {acquired_ref, :acquired})
        serve_lock_owner(owner, lock_id)

      true ->
        receive do
        after
          min(@lock_retry_ms, remaining) ->
            await_global_lock(owner, acquired_ref, lock_id, deadline)
        end
    end
  end

  defp serve_lock_owner(owner, lock_id) do
    receive do
      {:run_checkpoint_hydration_journal, ^owner, result_ref, transition}
      when is_function(transition, 0) ->
        send(owner, {result_ref, transition.()})
        serve_lock_owner(owner, lock_id)

      {:release_checkpoint_hydration_journal, ^owner} ->
        :global.del_lock(lock_id, [node()])
    end
  end

  defp run_locked({holder, monitor}, transition) do
    result_ref = make_ref()
    send(holder, {:run_checkpoint_hydration_journal, self(), result_ref, transition})

    receive do
      {^result_ref, result} ->
        result

      {:DOWN, ^monitor, :process, ^holder, _reason} ->
        {:error, {:durability_uncertain, :checkpoint_hydration_journal_lock_lost}}
    after
      @lock_wait_ms ->
        Process.exit(holder, :kill)
        await_holder_down(holder, monitor)
        drain_decode_result(result_ref)
        {:error, {:durability_uncertain, :checkpoint_hydration_journal_transition_timeout}}
    end
  end

  defp release_lock({holder, monitor}) do
    send(holder, {:release_checkpoint_hydration_journal, self()})
    await_holder_down(holder, monitor)
  end

  defp await_holder_down(holder, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^holder, _reason} -> :ok
    after
      @lock_wait_ms ->
        Process.exit(holder, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^holder, _reason} -> :ok
        end
    end
  end

  defp canonical_bytes(record),
    do: :erlang.term_to_binary({@format_version, @record_tag, record}, minor_version: 2)

  defp safe_term(<<131, 80, _compressed::binary>>), do: :corrupt

  defp safe_term(bytes) do
    case :erlang.binary_to_term(bytes, [:safe, :used]) do
      {term, used} when used == byte_size(bytes) -> term
      _partial -> :corrupt
    end
  rescue
    _exception -> :corrupt
  catch
    _kind, _reason -> :corrupt
  end

  defp stop_decode_on_owner_exit(owner, worker) do
    owner_monitor = Process.monitor(owner)
    worker_monitor = Process.monitor(worker)

    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        Process.exit(worker, :kill)
        await_decode_down(worker, worker_monitor)

      {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
        :ok
    end
  end

  defp await_decode_down(worker, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      @decode_timeout_ms -> Process.demonitor(monitor, [:flush])
    end
  end

  defp drain_decode_result(result_ref) do
    receive do
      {^result_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp atomic_opts(path, opts) do
    opts
    |> Keyword.take([:file_system, :fault_injector, :temp_suffix])
    |> Keyword.put(:directory_root, Path.dirname(path))
  end

  defp file_system(opts), do: Keyword.get(opts, :file_system, FileSystem)

  defp safe_fs_call(fs, callback, args) do
    apply(fs, callback, args)
  rescue
    _exception -> {:error, {:callback_failed, :raise}}
  catch
    :throw, _reason -> {:error, {:callback_failed, :throw}}
    :exit, _reason -> {:error, {:callback_failed, :exit}}
  end

  defp exact_keys(value, expected) when is_map(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(expected),
      do: :ok,
      else: {:error, :invalid_checkpoint_hydration_journal}
  end

  defp exact_keys(_value, _expected),
    do: {:error, :invalid_checkpoint_hydration_journal}

  defp fixed_binary(value, size) when is_binary(value) and byte_size(value) == size, do: :ok
  defp fixed_binary(_value, _size), do: {:error, :invalid_checkpoint_hydration_journal}

  defp nonzero_identifier(value) do
    with :ok <- fixed_binary(value, @identifier_size) do
      if value == <<0::size(@identifier_size * 8)>>,
        do: {:error, :invalid_checkpoint_hydration_journal},
        else: :ok
    end
  end

  defp u32(value) when is_integer(value) and value >= 0 and value <= @u32_max, do: :ok
  defp u32(_value), do: {:error, :invalid_checkpoint_hydration_journal}

  defp u64(value) when is_integer(value) and value >= 0 and value <= @u64_max, do: :ok
  defp u64(_value), do: {:error, :invalid_checkpoint_hydration_journal}

  defp database_int(value)
       when is_integer(value) and value >= 0 and value <= @database_int_max,
       do: :ok

  defp database_int(_value), do: {:error, :invalid_checkpoint_hydration_journal}

  defp positive_database_int(value)
       when is_integer(value) and value > 0 and value <= @database_int_max,
       do: :ok

  defp positive_database_int(_value),
    do: {:error, :invalid_checkpoint_hydration_journal}

  defp secure_equal(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_equal(_left, _right), do: false
end
