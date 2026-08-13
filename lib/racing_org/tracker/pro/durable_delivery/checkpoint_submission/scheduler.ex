defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointSubmission.Scheduler do
  @moduledoc """
  Produces exact-runtime checkpoints from live observer state.

  Each tick projects every configured runtime and durably admits a checkpoint
  submission when its semantic learner generation advanced past the accepted
  head — idle re-projections never resubmit, and at most one submission per
  kind is in flight. Backend acceptance arrives through the Outbox owner's
  retirement notification; the accepted record is installed into the checkpoint
  head store so the next submission binds the correct parent hash.
  """

  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.Calibration.Observer, as: CalibrationObserver
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Store, as: HeadStore
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointSubmission.Builder
  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointSubmission.Payload
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Entry
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner, as: OutboxOwner
  alias RacingOrg.Tracker.Pro.Polar.Observer, as: PolarObserver
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime
  alias RacingOrg.Tracker.Pro.WindShift.Observer, as: WindShiftObserver

  @default_sync_ms 60_000
  @identity_keys [:device_id, :credential_epoch, :storage_epoch]

  @runtime_schemas Map.new(Contract.checkpoint_runtime_schemas(), fn {kind, _code, schema_version} ->
                     {kind, schema_version}
                   end)

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

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Run one synchronous submission pass across every configured runtime."
  @spec tick(GenServer.server()) :: :ok
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, :infinity)

  @doc """
  Record backend-accepted checkpoint retirements into the head store.

  Asynchronous by contract: the Outbox owner invokes this from inside its
  acknowledgement handler, and the scheduler's follow-up tick calls back into
  the owner, so a synchronous notification would deadlock. A missing scheduler
  is a no-op, non-checkpoint entries are ignored, and head-store failures are
  retried implicitly by the backend's next hydration.
  """
  @spec record_accepted(GenServer.server(), [Entry.t()]) :: :ok
  def record_accepted(server \\ __MODULE__, entries) when is_list(entries) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:record_accepted, entries})
      _unavailable -> :ok
    end
  end

  @doc "Return the production observer sources for every exact runtime."
  @spec production_sources() :: map()
  def production_sources do
    %{
      calibration: %{
        snapshot: fn -> CalibrationObserver.snapshot(CalibrationObserver) end,
        adapter: CheckpointRuntime.Calibration
      },
      polar: %{
        snapshot: fn -> PolarObserver.runtime_snapshot(PolarObserver) end,
        adapter: CheckpointRuntime.Polar
      },
      wind_shift: %{
        snapshot: fn -> WindShiftObserver.snapshot(WindShiftObserver) end,
        adapter: CheckpointRuntime.WindShift
      }
    }
  end

  @impl true
  def init(opts) do
    state = %{
      identity: Keyword.fetch!(opts, :identity),
      head_store: Keyword.fetch!(opts, :head_store),
      outbox: Keyword.get(opts, :outbox, OutboxOwner),
      outbox_module: Keyword.get(opts, :outbox_module, OutboxOwner),
      sources: Keyword.get_lazy(opts, :sources, &production_sources/0),
      builder: Keyword.get(opts, :builder, &Builder.submit/2),
      sync_ms: Keyword.get(opts, :sync_ms, @default_sync_ms),
      timer_ref: nil,
      timer_token: nil
    }

    {:ok, schedule_tick(state)}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    run_tick(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:record_accepted, entries}, state) do
    install_accepted(state, entries)
    run_tick(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:scheduled_tick, token}, %{timer_token: token} = state) do
    run_tick(state)
    {:noreply, schedule_tick(state)}
  end

  def handle_info({:scheduled_tick, _stale_token}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_tick(state) do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:scheduled_tick, token}, state.sync_ms)
    %{state | timer_ref: timer_ref, timer_token: token}
  end

  defp run_tick(state) do
    with {:ok, identity} <- current_identity(state),
         {:ok, head_store} <- current_head_store(state),
         {:ok, pending_kinds} <- pending_kinds(state) do
      state.sources
      |> Enum.sort_by(fn {kind, _source} -> kind end)
      |> Enum.each(fn {kind, source} ->
        if kind in pending_kinds do
          :ok
        else
          submit_if_advanced(state, kind, source, identity, head_store)
        end
      end)
    else
      {:error, reason} ->
        Logger.debug("[CheckpointScheduler] tick skipped: #{inspect(reason)}")
        :ok
    end
  end

  defp submit_if_advanced(state, kind, source, identity, head_store) do
    with {:ok, schema_version} <- runtime_schema(kind),
         {:ok, snapshot} <- acquire_snapshot(source.snapshot),
         {:ok, content} <- project(source.adapter, snapshot),
         {:ok, source_generation} <- Builder.source_generation(kind, schema_version, content),
         :submit <- submission_decision(head_store, kind, source_generation) do
      submit(state, kind, source, snapshot, identity, head_store)
    else
      :skip ->
        :ok

      {:error, reason} ->
        Logger.debug("[CheckpointScheduler] #{kind} submission not attempted: #{inspect(reason)}")

        :ok
    end
  end

  defp submit(state, kind, source, snapshot, identity, head_store) do
    result =
      state.builder.(kind,
        observer_snapshot: fn -> {:ok, snapshot} end,
        runtime_adapter: source.adapter,
        durable_identity: fn -> {:ok, Map.take(identity, @identity_keys)} end,
        accepted_parent: fn parent_kind -> accepted_parent(head_store, parent_kind) end,
        enqueue_checkpoint: fn builder ->
          state.outbox_module.enqueue_checkpoint(state.outbox, builder)
        end
      )

    case result do
      {:ok, _receipt} ->
        :ok

      {:error, reason} ->
        Logger.info("[CheckpointScheduler] #{kind} submission remains pending: #{inspect(reason)}")

        :ok
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp submission_decision(head_store, kind, source_generation) do
    case HeadStore.head(head_store, kind) do
      :empty -> :submit
      {:ok, head} when source_generation > head.source_generation -> :submit
      {:ok, _head} -> :skip
      {:error, reason} -> {:error, reason}
    end
  end

  defp accepted_parent(head_store, kind) do
    case HeadStore.head(head_store, kind) do
      {:ok, head} -> {:ok, head.checkpoint_hash}
      :empty -> :empty
      {:error, _reason} = error -> error
    end
  end

  defp install_accepted(state, entries) do
    checkpoint_entries =
      Enum.filter(entries, &match?(%Entry{stream: :checkpoint}, &1))

    case checkpoint_entries do
      [] ->
        :ok

      _accepted ->
        case current_head_store(state) do
          {:ok, head_store} ->
            Enum.each(checkpoint_entries, &install_entry(head_store, &1))

          {:error, reason} ->
            Logger.warning("[CheckpointScheduler] accepted checkpoint not recorded: #{inspect(reason)}")

            :ok
        end
    end
  end

  defp install_entry(head_store, entry) do
    with {:ok, submission} <- Payload.decode(entry.payload),
         {:ok, _record} <- HeadStore.hydrate(head_store, hydrate_attrs(submission)) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[CheckpointScheduler] accepted checkpoint not recorded: #{inspect(reason)}")

        :ok
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp hydrate_attrs(submission) do
    submission
    |> Map.take([
      :device_id,
      :credential_epoch,
      :storage_epoch,
      :kind,
      :schema_version,
      :sequence,
      :source_generation,
      :parent_hash,
      :content,
      :checkpoint_hash
    ])
    |> Map.put(:origin_credential_epoch, submission.credential_epoch)
    |> Map.put(:origin_storage_epoch, submission.storage_epoch)
  end

  defp pending_kinds(state) do
    case safe_pending(state) do
      entries when is_list(entries) ->
        {:ok,
         entries
         |> Enum.flat_map(fn entry ->
           case Payload.decode(entry.payload) do
             {:ok, %{kind: kind}} -> [kind]
             {:error, _reason} -> []
           end
         end)
         |> MapSet.new()}

      {:error, _reason} = error ->
        error
    end
  end

  defp safe_pending(state) do
    state.outbox_module.pending(state.outbox, stream: :checkpoint)
  rescue
    _exception -> {:error, :outbox_owner_unavailable}
  catch
    :exit, _reason -> {:error, :outbox_owner_unavailable}
    _kind, _reason -> {:error, :outbox_owner_unavailable}
  end

  defp current_identity(state) do
    case state.identity.() do
      {:ok, identity} when is_map(identity) -> {:ok, identity}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_identity_result}
    end
  rescue
    _exception -> {:error, :identity_unavailable}
  catch
    _kind, _reason -> {:error, :identity_unavailable}
  end

  defp current_head_store(state) do
    case state.head_store.() do
      {:ok, %HeadStore{} = head_store} -> {:ok, head_store}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_head_store_result}
    end
  rescue
    _exception -> {:error, :checkpoint_head_store_unavailable}
  catch
    _kind, _reason -> {:error, :checkpoint_head_store_unavailable}
  end

  defp runtime_schema(kind) do
    case Map.fetch(@runtime_schemas, kind) do
      {:ok, schema_version} -> {:ok, schema_version}
      :error -> {:error, :unknown_checkpoint_kind}
    end
  end

  defp acquire_snapshot(snapshot_fun) when is_function(snapshot_fun, 0) do
    case snapshot_fun.() do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_observer_snapshot_result}
    end
  rescue
    _exception -> {:error, :observer_unavailable}
  catch
    :exit, _reason -> {:error, :observer_unavailable}
    _kind, _reason -> {:error, :observer_unavailable}
  end

  defp acquire_snapshot(_snapshot_fun), do: {:error, :invalid_observer_snapshot_source}

  defp project(adapter, snapshot) when is_function(adapter, 1) do
    normalize_projection(adapter.(snapshot))
  rescue
    _exception -> {:error, :invalid_runtime_adapter_result}
  catch
    _kind, _reason -> {:error, :invalid_runtime_adapter_result}
  end

  defp project(adapter, snapshot) when is_atom(adapter) do
    normalize_projection(adapter.project(snapshot))
  rescue
    _exception -> {:error, :invalid_runtime_adapter_result}
  catch
    _kind, _reason -> {:error, :invalid_runtime_adapter_result}
  end

  defp normalize_projection({:ok, content}) when is_map(content), do: {:ok, content}
  defp normalize_projection({:error, reason}), do: {:error, reason}
  defp normalize_projection(_other), do: {:error, :invalid_runtime_adapter_result}
end
