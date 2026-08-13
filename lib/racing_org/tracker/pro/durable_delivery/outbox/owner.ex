defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner do
  @moduledoc """
  Supervised single-writer owner for one durable outbox root.

  Exactly one Owner may hold a root at a time. Ownership is claimed at `init/1`
  against a global registration keyed by the expanded root path, so a second
  Owner for the same root refuses to start rather than racing the first one's
  appends. The claim is released when the owning process exits, letting a
  supervisor restart the Owner and replay durable state.

  The Owner obtains its durable origin identity — device ID, credential epoch,
  and storage epoch — from an injectable identity source, and binds it into the
  `Store` for the lifetime of the process. Every mutation revalidates that the
  live identity still matches the bound identity, so a rotation or a storage
  wipe cannot be written under the previous origin.

  Entries are removed only by `acknowledge/3` after `Store.acknowledge/2`
  matches an authenticated receipt against the exact durable identity, or by an
  explicit `authorize_loss/4`. A successful transport send is never sufficient.

  When verified authority is not yet available at startup, the permanent Owner
  stays alive and identity-unbound, failing mutations closed until a later
  refresh can open the Store. Any `{:durability_uncertain, _}` result, and any
  identity drift after binding, latches the Owner into quarantine until restart.

  `status/1` is deliberately sanitized. It reports only counters, limits, and
  booleans — never payload bytes, hashes, identifiers, credentials, Wi-Fi data,
  filesystem paths, PIDs, or the internal `Store` handle.
  """

  use GenServer

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.{Entry, FileSystem, SegmentFileSystem, Store}

  @u32_max 0xFFFF_FFFF
  @zero_device_id <<0::128>>
  @zero_storage_epoch <<0::128>>
  @default_streams [
    :telemetry,
    :race_recording_chunk,
    :race_recording_manifest,
    :desired_state_ack,
    :checkpoint,
    :health
  ]
  @default_max_entries 10_000
  @default_max_bytes 32 * 1_024 * 1_024
  @default_segment_max_bytes 1_024 * 1_024
  @default_identity_refresh_ms 250
  @root_lock_retry_attempts 50
  @root_lock_retry_ms 10
  @identity_keys [:device_id, :credential_epoch, :storage_epoch]

  @type receipt :: %{
          required(:stream) => atom(),
          required(:device_id) => <<_::128>>,
          required(:credential_epoch) => non_neg_integer(),
          required(:storage_epoch) => <<_::128>>,
          required(:sequence) => pos_integer(),
          required(:payload_hash) => <<_::256>>,
          required(:cumulative_sequence) => non_neg_integer()
        }

  @type status :: %{
          accepting: boolean(),
          quarantined: boolean(),
          storage_epoch_bound: boolean(),
          pending_entries: non_neg_integer() | :unavailable,
          pending_bytes: non_neg_integer() | :unavailable,
          disk_bytes: non_neg_integer() | :unavailable,
          max_entries: pos_integer(),
          max_bytes: pos_integer(),
          max_disk_bytes: pos_integer(),
          loss_authorizations: non_neg_integer() | :unavailable,
          streams: non_neg_integer()
        }

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc """
  Start the sole writer for one root.

  `:root` is required and must be an absolute path; it is never defaulted, so a
  misconfiguration cannot silently write to an unintended location. `:identity`
  is a zero-arity function returning `{:ok, %{device_id:, credential_epoch:,
  storage_epoch:}}`, injectable so host tests need no real runtime identity.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  def start_link(_opts), do: {:error, :invalid_options}

  @doc """
  Durably append one payload and return its durable receipt identity.

  Returns only after the record is written and fsynced. Capacity limits surface
  as an explicit `{:error, {:backpressure, reason}}` — entries are never evicted
  to make room.
  """
  @spec enqueue(GenServer.server(), atom(), binary(), keyword()) ::
          {:ok, receipt()} | {:error, term()}
  def enqueue(server, stream, payload, opts \\ []) do
    call(server, {:enqueue, stream, payload, opts})
  end

  @doc """
  Build and durably append one checkpoint payload under its exact sequence.

  The builder runs only after identity validation and while the Store holds its
  mutation lock. It receives the authoritative checkpoint sequence before the
  payload is hashed or appended.
  """
  @spec enqueue_checkpoint(
          GenServer.server(),
          (pos_integer() ->
             {:ok, %{payload: binary(), payload_hash: <<_::256>>}} | {:error, term()})
        ) :: {:ok, receipt()} | {:error, term()}
  def enqueue_checkpoint(server, builder) do
    call(server, {:enqueue_checkpoint, builder})
  end

  @doc """
  Durably resolve entries covered by an already authenticated receipt.

  The caller must authenticate and decode the wire receipt first; this boundary
  revalidates the exact durable identity before anything is removed. Pass
  `idempotent: true` to treat a receipt whose entries are already resolved as a
  success returning `[]`, which keeps a redelivered acknowledgement harmless.
  """
  @spec acknowledge(GenServer.server(), map(), keyword()) ::
          {:ok, [Entry.t()]} | {:error, term()}
  def acknowledge(server, receipt, opts \\ []) do
    call(server, {:acknowledge, receipt, opts})
  end

  @doc "Durably authorize the loss of one exact entry with an auditable reason."
  @spec authorize_loss(GenServer.server(), map(), binary()) ::
          {:ok, Entry.t()} | {:error, term()}
  def authorize_loss(server, identity, reason) do
    call(server, {:authorize_loss, identity, reason})
  end

  @doc "Return pending entries in priority order, retaining FIFO within a priority."
  @spec pending(GenServer.server(), keyword()) :: [Entry.t()] | {:error, term()}
  def pending(server, opts \\ []) do
    call(server, {:pending, opts})
  end

  @doc """
  Return the sanitized operational status.

  Contains only counters, configured limits, and booleans. No payload bytes, no
  hashes, no identifiers, no credentials, no paths, no PIDs.
  """
  @spec status(GenServer.server()) :: status() | {:error, term()}
  def status(server), do: call(server, :status)

  defp call(server, message) do
    GenServer.call(server, message, :infinity)
  catch
    :exit, _reason -> {:error, :outbox_owner_unavailable}
  end

  @impl true
  def init(opts) do
    with {:ok, root} <- option_root(opts),
         {:ok, identity_source} <- option_identity_source(opts),
         {:ok, store_opts} <- validate_store_options(opts),
         :ok <- claim_root(root),
         {:ok, root_lock} <- claim_root_across_vms(root, opts) do
      Process.flag(:trap_exit, true)

      state = %{
        root: root,
        root_lock: root_lock,
        store: nil,
        store_opts: store_opts,
        identity: nil,
        identity_source: identity_source,
        identity_refresh_ms: identity_refresh_ms(opts),
        identity_refresh_ref: nil,
        identity_refresh_token: nil,
        binding_error: :identity_unbound,
        on_admit: Keyword.get(opts, :on_admit),
        quarantined: false
      }

      case read_identity(identity_source) do
        {:ok, identity} -> start_bound(state, identity)
        {:error, :no_verified_authority} -> {:ok, schedule_identity_refresh(state)}
        {:error, reason} -> stop_unbound(state, reason)
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, sanitized_status(state), state}

  def handle_call(_message, _from, %{quarantined: true} = state) do
    {:reply, {:error, :quarantined}, state}
  end

  def handle_call(_message, _from, %{store: nil} = state) do
    {:reply, {:error, state.binding_error}, state}
  end

  def handle_call({:pending, opts}, _from, state) do
    {:reply, select_pending(state, opts), state}
  end

  def handle_call({:enqueue, stream, payload, opts}, _from, state) do
    case verify_identity(state) do
      :ok ->
        case Store.enqueue(state.store, stream, payload, opts) do
          {:ok, entry, store} ->
            notify_admit(state, entry.stream)
            {:reply, {:ok, receipt_for(entry)}, %{state | store: store}}

          {:error, reason} ->
            {:reply, {:error, reason}, latch_storage_fault(state, reason)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | quarantined: true}}
    end
  end

  def handle_call({:enqueue_checkpoint, builder}, _from, state) do
    case verify_identity(state) do
      :ok ->
        case Store.enqueue_checkpoint(state.store, builder) do
          {:ok, entry, store} ->
            notify_admit(state, entry.stream)
            {:reply, {:ok, receipt_for(entry)}, %{state | store: store}}

          {:error, reason} ->
            {:reply, {:error, reason}, latch_storage_fault(state, reason)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | quarantined: true}}
    end
  end

  def handle_call({:acknowledge, receipt, opts}, _from, state) do
    case verify_identity(state) do
      :ok -> apply_acknowledgement(state, receipt, opts)
      {:error, reason} -> {:reply, {:error, reason}, %{state | quarantined: true}}
    end
  end

  def handle_call({:authorize_loss, identity, reason}, _from, state) do
    case verify_identity(state) do
      :ok ->
        case Store.authorize_loss(state.store, identity, reason) do
          {:ok, entry, store} -> {:reply, {:ok, entry}, %{state | store: store}}
          {:error, failure} -> {:reply, {:error, failure}, latch_storage_fault(state, failure)}
        end

      {:error, failure} ->
        {:reply, {:error, failure}, %{state | quarantined: true}}
    end
  end

  # An unmatched receipt is remote input, not a durability fault: reject it
  # without latching, so a peer cannot wedge the Owner by replaying junk. Only
  # the identity check above and a durability fault below can latch.
  defp apply_acknowledgement(state, receipt, opts) do
    case Store.acknowledge(state.store, receipt) do
      {:ok, removed, store} ->
        {:reply, {:ok, removed}, %{state | store: store}}

      {:error, :receipt_entry_not_found} ->
        if Keyword.get(opts, :idempotent, false) and Store.resolved_receipt?(state.store, receipt) do
          {:reply, {:ok, []}, state}
        else
          {:reply, {:error, :receipt_entry_not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, latch_storage_fault(state, reason)}
    end
  end

  @impl true
  def handle_info(
        {:refresh_identity, token},
        %{identity_refresh_token: token, store: nil} = state
      ) do
    state = %{state | identity_refresh_ref: nil, identity_refresh_token: nil}

    case refresh_identity(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:stop, reason, release_root_lock(state)}
    end
  end

  def handle_info({:refresh_identity, _token}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  # Latch only on faults that make durability or single-writer ownership
  # uncertain. Rejected caller input (bad receipt, unknown stream, backpressure)
  # must stay recoverable, or any peer could wedge the Owner on demand.
  defp latch_storage_fault(state, reason) do
    if latching_reason?(reason), do: %{state | quarantined: true}, else: state
  end

  defp latching_reason?({:durability_uncertain, _reason}), do: true
  defp latching_reason?({:quarantined, _reason}), do: true
  defp latching_reason?({:quarantined, _reason, _destination}), do: true
  defp latching_reason?(:stale_store), do: true
  defp latching_reason?({:mutation_lock, _reason}), do: true
  defp latching_reason?(_reason), do: false

  defp verify_identity(state) do
    case read_identity(state.identity_source) do
      {:ok, current} -> compare_identity(state.identity, current)
      {:error, :no_verified_authority} -> {:error, :identity_unbound}
      {:error, _reason} -> {:error, :identity_unavailable}
    end
  end

  defp compare_identity(bound, current) do
    cond do
      bound.device_id != current.device_id -> {:error, :device_id_mismatch}
      bound.credential_epoch != current.credential_epoch -> {:error, :credential_epoch_mismatch}
      bound.storage_epoch != current.storage_epoch -> {:error, :storage_epoch_mismatch}
      true -> :ok
    end
  end

  defp refresh_identity(state) do
    case read_identity(state.identity_source) do
      {:ok, identity} ->
        case open_store(state.root, identity, state.store_opts) do
          {:ok, store} ->
            finish_deferred_bind(state, identity, store)

          {:error, reason}
          when reason in [:device_id_mismatch, :credential_epoch_mismatch, :storage_epoch_mismatch] ->
            {:ok,
             %{
               state
               | binding_error: reason,
                 quarantined: true
             }}

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, :no_verified_authority} ->
        {:ok,
         state
         |> Map.put(:binding_error, :identity_unbound)
         |> schedule_identity_refresh()}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp finish_deferred_bind(state, identity, store) do
    case read_identity(state.identity_source) do
      {:ok, current} when current == identity ->
        {:ok,
         %{
           state
           | store: store,
             identity: identity,
             binding_error: nil
         }}

      {:ok, current} ->
        {:ok, quarantine_unopened(state, compare_identity(identity, current))}

      {:error, :no_verified_authority} ->
        {:ok, quarantine_unopened(state, :identity_unbound)}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp quarantine_unopened(state, :ok), do: %{state | binding_error: :identity_unavailable, quarantined: true}

  defp quarantine_unopened(state, {:error, reason}) do
    %{state | binding_error: reason, quarantined: true}
  end

  defp quarantine_unopened(state, reason) do
    %{state | binding_error: reason, quarantined: true}
  end

  defp schedule_identity_refresh(state) do
    if is_reference(state.identity_refresh_ref), do: Process.cancel_timer(state.identity_refresh_ref)

    token = make_ref()
    timer_ref = Process.send_after(self(), {:refresh_identity, token}, state.identity_refresh_ms)
    %{state | identity_refresh_ref: timer_ref, identity_refresh_token: token}
  end

  defp start_bound(state, identity) do
    case open_store(state.root, identity, state.store_opts) do
      {:ok, store} ->
        {:ok, %{state | store: store, identity: identity, binding_error: nil}}

      {:error, reason} ->
        stop_unbound(state, reason)
    end
  end

  defp release_root_lock(state) do
    _ = close_root_lock(state.root_lock)
    %{state | root_lock: nil}
  end

  defp stop_unbound(state, reason) do
    _state = release_root_lock(state)
    {:stop, reason}
  end

  defp identity_refresh_ms(opts) do
    case Keyword.get(opts, :identity_refresh_ms, @default_identity_refresh_ms) do
      milliseconds when is_integer(milliseconds) and milliseconds > 0 -> milliseconds
      _invalid -> @default_identity_refresh_ms
    end
  end

  defp select_pending(state, opts), do: Store.pending(state.store, opts)

  # Fire-and-forget admit notification so a live transport can transmit the new
  # durable entry immediately. Runs only after the durable append succeeded and
  # must never disturb the owner: notifier faults are swallowed.
  defp notify_admit(%{on_admit: on_admit}, stream) when is_function(on_admit, 1) do
    _ = on_admit.(stream)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp notify_admit(_state, _stream), do: :ok

  defp receipt_for(%Entry{} = entry) do
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

  defp sanitized_status(%{store: nil} = state) do
    max_entries = Keyword.get(state.store_opts, :max_entries, @default_max_entries)
    max_bytes = Keyword.get(state.store_opts, :max_bytes, @default_max_bytes)
    segment_max_bytes = Keyword.get(state.store_opts, :segment_max_bytes, @default_segment_max_bytes)

    %{
      accepting: false,
      quarantined: state.quarantined,
      storage_epoch_bound: false,
      pending_entries: :unavailable,
      pending_bytes: :unavailable,
      disk_bytes: :unavailable,
      max_entries: max_entries,
      max_bytes: max_bytes,
      max_disk_bytes: Keyword.get(state.store_opts, :max_disk_bytes, max_bytes + segment_max_bytes),
      loss_authorizations: :unavailable,
      streams: state.store_opts |> Keyword.fetch!(:streams) |> length()
    }
  end

  defp sanitized_status(state) do
    %{entries: entries, bytes: bytes, disk_bytes: disk_bytes} = Store.usage(state.store)

    %{
      accepting: not state.quarantined,
      quarantined: state.quarantined,
      storage_epoch_bound: true,
      pending_entries: entries,
      pending_bytes: bytes,
      disk_bytes: disk_bytes,
      max_entries: state.store.max_entries,
      max_bytes: state.store.max_bytes,
      max_disk_bytes: state.store.max_disk_bytes,
      loss_authorizations: length(Store.loss_authorizations(state.store)),
      streams: map_size(state.store.stream_names)
    }
  end

  defp claim_root_across_vms(root, opts) do
    file_system = Keyword.get(opts, :file_system, FileSystem)
    segment_file_system = Keyword.get(opts, :segment_file_system, SegmentFileSystem)

    with :ok <- ensure_lockable_root(file_system, root),
         {:ok, %File.Stat{type: :directory} = stat} <- file_system.stat(root) do
      claim_native_root_lock(
        file_system,
        segment_file_system,
        root,
        {stat.major_device, stat.minor_device, stat.inode},
        @root_lock_retry_attempts
      )
    else
      {:ok, %File.Stat{}} -> {:error, :invalid_root}
      {:error, reason} -> {:error, {:root_lock, reason}}
    end
  end

  defp claim_native_root_lock(file_system, segment_file_system, root, identity, attempts_left) do
    case segment_file_system.open_root(file_system, root, identity) do
      {:ok, handle} ->
        case segment_file_system.try_lock_root(handle) do
          :ok ->
            {:ok, {segment_file_system, handle}}

          {:error, reason} when reason in [:eacces, :eagain] and attempts_left > 0 ->
            _ = segment_file_system.close_root(handle)
            Process.sleep(@root_lock_retry_ms)

            claim_native_root_lock(
              file_system,
              segment_file_system,
              root,
              identity,
              attempts_left - 1
            )

          {:error, reason} when reason in [:eacces, :eagain] ->
            _ = segment_file_system.close_root(handle)
            {:error, :root_already_owned}

          {:error, reason} ->
            _ = segment_file_system.close_root(handle)
            {:error, {:root_lock, reason}}
        end

      {:error, reason} ->
        {:error, {:root_lock, reason}}
    end
  end

  defp ensure_lockable_root(file_system, root) do
    with :ok <- file_system.mkdir_p(root),
         :ok <- file_system.chmod(root, 0o700) do
      :ok
    end
  end

  defp close_root_lock({segment_file_system, handle}) do
    segment_file_system.close_root(handle)
  rescue
    _exception -> {:error, :root_close_failed}
  catch
    _kind, _reason -> {:error, :root_close_failed}
  end

  defp open_store(root, identity, opts) do
    Store.open(root, store_options(identity, opts))
  end

  defp validate_store_options(opts) do
    identity = %{
      device_id: <<1::128>>,
      credential_epoch: 0,
      storage_epoch: <<1::128>>
    }

    store_opts = store_options(identity, opts)

    with :ok <- valid_streams(Keyword.fetch!(store_opts, :streams)),
         :ok <- positive_store_option(store_opts, :max_entries),
         :ok <- positive_store_option(store_opts, :max_bytes),
         :ok <- positive_store_option(store_opts, :segment_max_bytes),
         :ok <- positive_optional_store_option(store_opts, :max_disk_bytes),
         :ok <- positive_optional_store_option(store_opts, :max_loss_authorizations),
         :ok <- positive_optional_store_option(store_opts, :max_entry_id_tombstones),
         :ok <- positive_optional_store_option(store_opts, :max_resolved_receipts),
         :ok <- store_adapter(store_opts, :file_system, FileSystem, FileSystem),
         :ok <-
           store_adapter(
             store_opts,
             :segment_file_system,
             SegmentFileSystem,
             SegmentFileSystem
           ),
         :ok <- entry_id_generator(store_opts) do
      {:ok, store_opts}
    end
  end

  defp valid_streams(streams) when is_list(streams) and streams != [] do
    if Enum.all?(streams, &is_atom/1) and length(Enum.uniq(streams)) == length(streams),
      do: :ok,
      else: {:error, :invalid_streams}
  end

  defp valid_streams(_streams), do: {:error, :invalid_streams}

  defp positive_store_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 -> :ok
      _invalid -> {:error, {:invalid_option, key}}
    end
  end

  defp positive_optional_store_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 -> :ok
      {:ok, _invalid} -> {:error, {:invalid_option, key}}
      :error -> :ok
    end
  end

  defp store_adapter(opts, key, default, behaviour) do
    case Keyword.get(opts, key, default) do
      module when is_atom(module) ->
        callbacks = behaviour.behaviour_info(:callbacks)

        if Code.ensure_loaded?(module) and
             Enum.all?(callbacks, fn {function, arity} ->
               function_exported?(module, function, arity)
             end) do
          :ok
        else
          {:error, {:invalid_option, key}}
        end

      _invalid ->
        {:error, {:invalid_option, key}}
    end
  end

  defp entry_id_generator(opts) do
    case Keyword.get(opts, :entry_id_generator, fn -> :crypto.strong_rand_bytes(16) end) do
      generator when is_function(generator, 0) -> :ok
      _invalid -> {:error, {:invalid_option, :entry_id_generator}}
    end
  end

  defp store_options(identity, opts) do
    [
      device_id: identity.device_id,
      credential_epoch: identity.credential_epoch,
      storage_epoch: identity.storage_epoch,
      streams: Keyword.get(opts, :streams, @default_streams),
      max_entries: Keyword.get(opts, :max_entries, @default_max_entries),
      max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes),
      segment_max_bytes: Keyword.get(opts, :segment_max_bytes, @default_segment_max_bytes)
    ] ++
      Keyword.take(opts, [
        :max_disk_bytes,
        :max_loss_authorizations,
        :max_entry_id_tombstones,
        :max_resolved_receipts,
        :file_system,
        :segment_file_system,
        :entry_id_generator
      ])
  end

  defp option_root(opts) do
    case Keyword.fetch(opts, :root) do
      {:ok, root} when is_binary(root) and root != "" ->
        if Path.type(root) == :absolute, do: Store.canonical_root(root), else: {:error, :invalid_root}

      {:ok, _root} ->
        {:error, :invalid_root}

      :error ->
        {:error, :missing_root}
    end
  end

  defp option_identity_source(opts) do
    case Keyword.fetch(opts, :identity) do
      {:ok, source} when is_function(source, 0) -> {:ok, source}
      {:ok, _source} -> {:error, :invalid_identity_source}
      :error -> {:error, :missing_identity_source}
    end
  end

  defp read_identity(source) do
    case source.() do
      {:ok, identity} when is_map(identity) -> validate_identity(identity)
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_identity}
    end
  rescue
    _exception -> {:error, :invalid_identity}
  catch
    _kind, _reason -> {:error, :invalid_identity}
  end

  defp validate_identity(identity) do
    with :ok <- validate_device_id(Map.get(identity, :device_id)),
         :ok <- validate_credential_epoch(Map.get(identity, :credential_epoch)),
         :ok <- validate_storage_epoch(Map.get(identity, :storage_epoch)) do
      {:ok, Map.take(identity, @identity_keys)}
    end
  end

  defp validate_device_id(@zero_device_id), do: {:error, :invalid_device_id}
  defp validate_device_id(<<_::128>>), do: :ok
  defp validate_device_id(_device_id), do: {:error, :invalid_device_id}

  defp validate_credential_epoch(epoch)
       when is_integer(epoch) and epoch >= 0 and epoch <= @u32_max,
       do: :ok

  defp validate_credential_epoch(_epoch), do: {:error, :invalid_credential_epoch}

  defp validate_storage_epoch(@zero_storage_epoch), do: {:error, :invalid_storage_epoch}
  defp validate_storage_epoch(<<_::128>>), do: :ok
  defp validate_storage_epoch(_storage_epoch), do: {:error, :invalid_storage_epoch}

  defp claim_root(root, attempts_left \\ 3) do
    case :global.register_name(claim_key(root), self()) do
      :yes ->
        :ok

      :no ->
        case {:global.whereis_name(claim_key(root)), attempts_left} do
          # The previous holder died between our register and this lookup; the
          # name is free again, so retry a bounded number of times.
          {:undefined, remaining} when remaining > 0 -> claim_root(root, remaining - 1)
          {:undefined, _remaining} -> {:error, :root_claim_contended}
          {pid, _remaining} -> {:error, {:root_already_owned, pid}}
        end
    end
  end

  defp claim_key(root), do: {__MODULE__, :root, root}
end
