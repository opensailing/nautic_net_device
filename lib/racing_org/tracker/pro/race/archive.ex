defmodule RacingOrg.Tracker.Pro.Race.Archive do
  @moduledoc """
  Orchestrates durable local race archiving and reconciliation with RacingOrg.

  Watches the sampling phase: when a race becomes active it opens a
  `RacingOrg.Tracker.Pro.Race.Recording`, appends every sampled `DataSet` produced during the
  race, and on finish finalizes the recording, uploads its manifest, and prunes
  to the most recent recordings. The recording is kept on disk until RacingOrg
  confirms the archive is complete; until then the device re-sends any chunks the
  server reports missing. An in-progress recording left by a power loss is
  recovered and finalized at boot.

  Reconciliation reads recordings from disk by id, so it works for recordings
  finalized before a reboot too.
  """
  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.DurableDelivery.Producer.RaceRecording, as: RaceRecordingProducer
  alias RacingOrg.Tracker.Protobuf.DataSet
  alias RacingOrg.Tracker.Protobuf.DeviceCommand
  alias RacingOrg.Tracker.Pro.Race.BulkUploader
  alias RacingOrg.Tracker.Pro.Race.Recording
  alias RacingOrg.Tracker.Pro.Race.Retention

  @active_phases [:pre_start, :racing, :rounding, :finish]
  @default_keep 10

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Append a sampled, encoded `DataSet` to the active recording (no-op if not racing)."
  def record(server \\ __MODULE__, binary), do: GenServer.cast(server, {:record, binary})

  @doc "The id of the recording currently being written, or `nil`."
  def current_recording_id(server \\ __MODULE__), do: GenServer.call(server, :current_recording_id)

  @impl true
  def init(opts) do
    commands = opts[:commands] || Commands
    Commands.subscribe(commands, self())
    if sampling = opts[:sampling], do: RacingOrg.Tracker.Pro.Sampling.subscribe(sampling, self())

    state = %{
      base_dir: opts[:base_dir],
      commands: commands,
      enqueue: opts[:enqueue_fn] || (&RacingOrg.Tracker.Pro.DataSetRecorder.enqueue_encoded/1),
      now_fn: opts[:now_fn] || (&DateTime.utc_now/0),
      device_id: opts[:device_id],
      keep: opts[:keep] || @default_keep,
      durable_enqueue_fn: opts[:durable_enqueue_fn],
      durable_pending_fn: opts[:durable_pending_fn],
      retention_prune_fn: opts[:retention_prune_fn] || (&Retention.prune/3),
      # Post-race signed bulk upload trigger. Defaults to the config-gated
      # BulkUploader.upload_async; injectable for tests. See `maybe_bulk_upload/3`.
      bulk_upload_fn: opts[:bulk_upload_fn] || (&default_bulk_upload/1),
      recording: nil
    }

    {:ok, recover(state)}
  end

  @impl true
  def handle_call(:current_recording_id, _from, state) do
    {:reply, state.recording && state.recording.recording_id, state}
  end

  @impl true
  def handle_cast({:record, _binary}, %{recording: nil} = state), do: {:noreply, state}

  def handle_cast({:record, binary}, state) do
    recording =
      try do
        Recording.append(state.recording, binary)
      rescue
        error ->
          Logger.warning("Failed to archive sample: #{inspect(error)}")
          state.recording
      end

    {:noreply, %{state | recording: recording}}
  end

  @impl true
  def handle_info({:sampling_phase, _old, new}, state) do
    state =
      cond do
        new in @active_phases and is_nil(state.recording) -> open_recording(state)
        new == :complete and not is_nil(state.recording) -> finalize_recording(state)
        true -> state
      end

    {:noreply, state}
  end

  def handle_info({:racing_org_command, %DeviceCommand{payload: {:manifest_verification_result, result}}}, state) do
    {:noreply, handle_verification(result, state)}
  end

  def handle_info({:racing_org_command, %DeviceCommand{payload: {:missing_chunk_request, request}}}, state) do
    {:noreply, handle_missing_chunks(request, state)}
  end

  def handle_info({:racing_org_command, _command}, state), do: {:noreply, state}

  # --- recording lifecycle ---

  defp open_recording(%{base_dir: nil} = state), do: state

  defp open_recording(state) do
    assignment = safe_assignment(state.commands)
    attrs = recording_attrs(assignment, state)
    recording = Recording.open(state.base_dir, attrs)
    Logger.info("Race recording started: #{attrs.recording_id}")
    %{state | recording: recording}
  end

  defp finalize_recording(state) do
    {recording, manifest} =
      Recording.finalize(state.recording, finished_at: state.now_fn.(), device_status: "complete")

    case admit_recording(state, recording) do
      :ok ->
        send_manifest(state, manifest)
        # Post-race: legacy UDP and HTTP bulk paths remain compatibility transports,
        # not authoritative durable receipts. Durable Outbox admission protects the
        # exact sealed local artifacts until authenticated receipt or audited loss.
        maybe_bulk_upload(state, recording)
        prune_recordings(state)
        Logger.info("Race recording finalized and durably admitted: #{recording.recording_id}")
        %{state | recording: nil}

      {:error, reason} ->
        Logger.warning(
          "Race recording durable admission failed; retaining #{recording.recording_id}: #{inspect(reason)}"
        )

        %{state | recording: recording}
    end
  end

  # Trigger the bulk upload for a just-finalized recording. We need the server-side
  # race_session_id to route the manifest; it travels on the active RaceAssignment
  # (`race_assignment.race_session_id`). With no base_dir (host/test) or no session id
  # we skip — the legacy UDP manifest path still reconciles the recording.
  defp maybe_bulk_upload(%{base_dir: nil}, _recording), do: :ok

  defp maybe_bulk_upload(state, recording) do
    case race_session_id(state) do
      session_id when is_binary(session_id) and session_id != "" ->
        state.bulk_upload_fn.(
          base_dir: state.base_dir,
          recording_id: recording.recording_id,
          race_session_id: session_id
        )

      _ ->
        Logger.info("Bulk upload skipped for #{recording.recording_id}: no race_session_id on the assignment")

        :ok
    end
  end

  defp race_session_id(state) do
    with %{race_assignment: %{race_session_id: id}} <- safe_assignment(state.commands) do
      id
    else
      _ -> nil
    end
  end

  # Default trigger: only fire the bulk upload when secure transport is configured
  # (the pinned server public key is present — the single secure-transport enable)
  # AND the device has a provisioned identity (the uploader signs every request).
  # Otherwise no-op — the uploader itself also no-ops cleanly with no identity, but
  # gating here avoids the async cast + log noise on un-provisioned devices.
  defp default_bulk_upload(opts) do
    if secure_transport_configured?() and provisioned?() do
      BulkUploader.upload_async(opts)
    else
      :ok
    end
  end

  defp secure_transport_configured? do
    RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity.configured?()
  end

  defp provisioned? do
    match?({:ok, _}, RacingOrg.Tracker.Pro.SecureTransport.KeyStore.load())
  end

  # --- reconciliation ---

  defp handle_verification(%{complete: true, race_recording_id: id}, state) when id != "" do
    Logger.info(
      "Legacy manifest verification is non-authoritative for durable race recording #{id}; retaining local artifacts"
    )

    state
  end

  defp handle_verification(%{complete: false, race_recording_id: id, missing_chunk_ids: missing}, state) do
    with_recording(state, id, fn recording ->
      resend_chunks(state, recording, missing)
      send_manifest(state, Recording.build_manifest(recording, state.now_fn.(), "complete"))
    end)

    state
  end

  defp handle_verification(_result, state), do: state

  defp handle_missing_chunks(%{race_recording_id: id, chunk_ids: ids}, state) do
    with_recording(state, id, fn recording -> resend_chunks(state, recording, ids) end)
    state
  end

  defp with_recording(%{base_dir: nil}, _id, _fun), do: :ok

  defp with_recording(%{base_dir: base}, id, fun) do
    case Recording.load(base, id) do
      {:ok, recording} -> fun.(recording)
      :error -> Logger.warning("No local recording #{id} to reconcile")
    end
  end

  defp resend_chunks(state, recording, chunk_ids) do
    for chunk_id <- chunk_ids do
      case Recording.read_chunk(recording, chunk_id) do
        {:ok, records} -> for record <- records, do: state.enqueue.(record)
        _ -> Logger.warning("Missing chunk #{chunk_id} for #{recording.recording_id}")
      end
    end
  end

  # --- boot recovery ---

  defp recover(%{base_dir: nil} = state), do: state

  defp recover(state) do
    for id <- Recording.list(state.base_dir) do
      with {:ok, recording} <- Recording.load(state.base_dir, id) do
        recording = recover_recording(recording, state)

        case admit_recording(state, recording) do
          :ok ->
            if {:ok, %{manifest: manifest}} = Recording.manifest_artifact(recording) do
              send_manifest(state, manifest)
            end

            Logger.info("Recovered and durably admitted race recording: #{id}")

          {:error, reason} ->
            Logger.warning("Recovered race recording durable admission failed; retaining #{id}: #{inspect(reason)}")
        end
      end
    end

    state
  end

  defp recover_recording(recording, state) do
    if Recording.finalized?(recording) do
      recording
    else
      {recording, _manifest} =
        Recording.finalize(recording, finished_at: state.now_fn.(), device_status: "recovered")

      recording
    end
  end

  # --- helpers ---

  defp admit_recording(
         %{durable_enqueue_fn: enqueue, durable_pending_fn: pending},
         recording
       )
       when is_function(enqueue, 3) and is_function(pending, 0) do
    with {:ok, chunks} <- Recording.sealed_chunk_artifacts(recording),
         :ok <- admit_chunks(enqueue, pending, recording.recording_id, chunks),
         {:ok, %{manifest: manifest, bytes: manifest_bytes}} <- Recording.manifest_artifact(recording),
         entry_id = RaceRecordingProducer.manifest_entry_id(recording.recording_id),
         result <- RaceRecordingProducer.admit_manifest(enqueue, recording.recording_id, manifest),
         :ok <- admitted_or_exact_pending(result, pending, :race_recording_manifest, entry_id, manifest_bytes) do
      :ok
    end
  end

  defp admit_recording(_state, _recording), do: {:error, :durable_admission_unconfigured}

  defp admit_chunks(enqueue, pending, recording_id, chunks) do
    Enum.reduce_while(chunks, :ok, fn %{descriptor: descriptor, bytes: bytes}, :ok ->
      entry_id = RaceRecordingProducer.chunk_entry_id(recording_id, descriptor.chunk_id)
      result = RaceRecordingProducer.admit_chunk(enqueue, recording_id, descriptor.chunk_id, bytes)

      case admitted_or_exact_pending(result, pending, :race_recording_chunk, entry_id, bytes) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp admitted_or_exact_pending({:ok, _receipt}, _pending, _stream, _entry_id, _payload), do: :ok

  defp admitted_or_exact_pending({:error, :duplicate_entry_id}, pending, stream, entry_id, payload) do
    case pending.() do
      entries when is_list(entries) ->
        if Enum.any?(entries, &exact_pending_entry?(&1, stream, entry_id, payload)),
          do: :ok,
          else: {:error, :duplicate_entry_id}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :invalid_pending_result}
    end
  rescue
    _exception -> {:error, :pending_failed}
  catch
    _kind, _reason -> {:error, :pending_failed}
  end

  defp admitted_or_exact_pending({:error, _reason} = error, _pending, _stream, _entry_id, _payload),
    do: error

  defp exact_pending_entry?(entry, stream, entry_id, payload) do
    match?(
      %{stream: ^stream, entry_id: ^entry_id, payload: ^payload},
      entry
    )
  end

  defp prune_recordings(%{durable_pending_fn: pending} = state) when is_function(pending, 0) do
    state.retention_prune_fn.(state.base_dir, state.keep, pending: pending)
  end

  defp prune_recordings(_state), do: []

  defp send_manifest(state, manifest) do
    RacingOrg.Tracker.Pro.data_set([], manifest: manifest) |> DataSet.encode() |> state.enqueue.()
  end

  defp recording_attrs(assignment, state) do
    race = assignment && assignment.race_assignment
    recording_id = recording_id_for(assignment, state)

    %{
      recording_id: recording_id,
      device_id: state.device_id,
      assignment_id: assignment && assignment.assignment_id,
      assignment_version: (assignment && assignment.version) || 0,
      started_at: state.now_fn.(),
      course_hash: assignment && assignment.hash,
      route_hash: (assignment && assignment.route_hash) || (race && race.route_hash)
    }
  end

  defp recording_id_for(assignment, state) do
    race = assignment && assignment.race_assignment

    case race && race.race_recording_id do
      id when is_binary(id) and id != "" -> id
      _ -> derive_recording_id(state)
    end
  end

  # Fallback id YYYY-MM-DD-N when the server didn't supply one.
  defp derive_recording_id(state) do
    date = state.now_fn.() |> DateTime.to_date() |> Date.to_iso8601()
    existing = if state.base_dir, do: Recording.list(state.base_dir), else: []
    n = Enum.count(existing, &String.starts_with?(&1, date <> "-")) + 1
    "#{date}-#{n}"
  end

  defp safe_assignment(commands) do
    Commands.current_assignment(commands)
  catch
    :exit, _ -> nil
  end
end
