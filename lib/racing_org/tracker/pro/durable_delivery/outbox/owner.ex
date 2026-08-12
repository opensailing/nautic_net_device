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

  Any `{:durability_uncertain, _}` result, and any identity drift, latches the
  Owner into a quarantined state: it stops accepting work and fails closed on
  every subsequent call until it is restarted and durable state is replayed.

  `status/1` is deliberately sanitized. It reports only counters, limits, and
  booleans — never payload bytes, hashes, identifiers, credentials, Wi-Fi data,
  filesystem paths, PIDs, or the internal `Store` handle.
  """

  use GenServer

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.{Entry, Store}

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
          pending_entries: non_neg_integer(),
          pending_bytes: non_neg_integer(),
          disk_bytes: non_neg_integer(),
          max_entries: pos_integer(),
          max_bytes: pos_integer(),
          max_disk_bytes: pos_integer(),
          loss_authorizations: non_neg_integer(),
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
          (pos_integer() -> {:ok, binary()} | {:error, term()})
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
         {:ok, identity} <- read_identity(identity_source),
         :ok <- claim_root(root),
         {:ok, store} <- open_store(root, identity, opts) do
      Process.flag(:trap_exit, true)

      {:ok,
       %{
         store: store,
         identity: identity,
         identity_source: identity_source,
         quarantined: false
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, sanitized_status(state), state}

  def handle_call(_message, _from, %{quarantined: true} = state) do
    {:reply, {:error, :quarantined}, state}
  end

  def handle_call({:pending, opts}, _from, state) do
    {:reply, select_pending(state, opts), state}
  end

  def handle_call({:enqueue, stream, payload, opts}, _from, state) do
    case verify_identity(state) do
      :ok ->
        case Store.enqueue(state.store, stream, payload, opts) do
          {:ok, entry, store} -> {:reply, {:ok, receipt_for(entry)}, %{state | store: store}}
          {:error, reason} -> {:reply, {:error, reason}, latch_storage_fault(state, reason)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | quarantined: true}}
    end
  end

  def handle_call({:enqueue_checkpoint, builder}, _from, state) do
    case verify_identity(state) do
      :ok ->
        case Store.enqueue_checkpoint(state.store, builder) do
          {:ok, entry, store} -> {:reply, {:ok, receipt_for(entry)}, %{state | store: store}}
          {:error, reason} -> {:reply, {:error, reason}, latch_storage_fault(state, reason)}
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

  defp select_pending(state, opts), do: Store.pending(state.store, opts)

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

  defp open_store(root, identity, opts) do
    store_opts =
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

    Store.open(root, store_opts)
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
