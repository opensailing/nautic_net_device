defmodule RacingOrg.Tracker.Pro.Race.BulkUploader do
  @moduledoc """
  Post-race signed HTTPS BULK upload of a finished race recording to RacingOrg.

  After a race finishes, the device holds a finalized `RacingOrg.Tracker.Pro.Race.Recording`
  on `/data` (size-bounded, per-chunk SHA-256-checksummed). This module uploads
  that recording over the Phase 6 signed bulk plane
  (`RacingOrgWeb.BulkUploadController`), authenticating EVERY request with an
  Ed25519 signed-request assertion (`RacingOrg.Tracker.Pro.SecureTransport.SignedRequest` over
  the device's `KeyStore` identity).

  ## The flow (resumable + idempotent)

    1. Build the `RaceManifest` from the recording's sealed chunks (each
       `ChunkDescriptor` = `chunk_id`, `byte_count`, `checksum` = SHA-256 HEX of
       the chunk's raw on-disk bytes, `sample_count`).
    2. SUBMIT the manifest — `POST /api/bulk/race_manifests` — as a base64 protobuf
       blob under `manifest_protobuf`, plus a JSON envelope carrying the routing
       keys the server reconciliation requires (`race_session_id`, `chunk_count`,
       `version`). The server is the AUTHORITATIVE oracle: completeness derives
       from SERVER-VERIFIED chunk bytes only, so the response's
       `missing_chunk_indexes` tells us which chunks still need uploading.
    3. For each missing chunk INDEX, `POST /api/bulk/race_recordings/:recording_id/chunks`
       with the raw chunk bytes base64-encoded under `data`, declaring
       `chunk_index`, `chunk_key`, `byte_count`, `checksum`, `sample_count`. The
       server recomputes the hash over the received bytes and marks the chunk
       `verified`/`corrupt`.
    4. RE-SUBMIT the manifest to re-read completeness from the now-verified rows;
       repeat (bounded) until `verification_status == "complete"`.

  ## Chunk index alignment (server contract)

  The on-disk `Recording` numbers chunks 1-based (`"0001"`, `"0002"`, ...). The
  server's reconciliation expects a DENSE 0-based index space
  (`expected_indexes(chunk_count) == 0..chunk_count-1`) and derives each chunk's
  integer index from its `chunk_id` (`"0000" -> 0`). To make the device's declared
  indexes line up EXACTLY with the server's expected space (so no phantom index 0
  is ever permanently missing), the bulk manifest re-numbers chunks to 0-based
  `chunk_id`s (`"0000"`, `"0001"`, ...) in sealed order, and every chunk upload
  sends the matching 0-based `chunk_index` explicitly. The raw bytes are still read
  from the recording's original on-disk file for that position.

  ## Resumability / idempotency / robustness

    * A re-run submits the manifest, uploads ONLY the chunks the server still
      reports missing, and is safe to call repeatedly. If the server already
      reports complete, NOTHING is uploaded.
    * A single chunk upload failing (network/transport/non-2xx) is LOGGED and does
      not abort the run; remaining chunks are still attempted and the next run
      retries whatever is still missing (already-verified chunks are left in
      place). Each request is retried with bounded, jittered backoff
      (`RacingOrg.Tracker.Pro.SecureTransport.Backoff`).
    * The local recording is NEVER deleted here. It is deleted only when RacingOrg
      independently confirms completeness via the `manifest_verification_result`
      device command (handled by `RacingOrg.Tracker.Pro.Race.Archive`); this uploader returns
      `{:ok, :complete}` so a caller MAY choose to delete, but the conservative
      default is to leave the bytes until the server's command arrives.

  ## Gating

  Not started in the supervision tree. Triggering is a job-6 concern; expose
  `upload/2` (callable) and a thin `GenServer` (`start_link/1` + `upload_async/2`).
  Requires a provisioned identity (`KeyStore.load/1`); with no identity it no-ops
  cleanly with `{:error, :not_provisioned}`.
  """

  use GenServer

  require Logger

  alias RacingOrg.Tracker.Protobuf.ChunkDescriptor
  alias RacingOrg.Tracker.Protobuf.RaceManifest
  alias RacingOrg.Tracker.Pro.Race.Recording
  alias RacingOrg.Tracker.Pro.SecureTransport.Backoff
  alias RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner
  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Pro.SecureTransport.SignedRequest

  @manifests_path "/api/bulk/race_manifests"
  @chunks_path_template "/api/bulk/race_recordings/:recording_id/chunks"

  @default_max_passes 5
  @default_max_attempts 3

  @typedoc "A logical chunk to upload: its 0-based bulk index, on-disk id, declared bytes."
  @type chunk_plan :: %{
          index: non_neg_integer(),
          chunk_id: String.t(),
          disk_chunk_id: String.t(),
          byte_count: non_neg_integer(),
          checksum: String.t(),
          sample_count: non_neg_integer()
        }

  ## --- GenServer (thin, not auto-started) ----------------------------------

  @doc "Start a thin uploader server (NOT in the supervision tree; job-6 wires this)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @doc """
  Asynchronously upload a finished recording (fire-and-forget via the server).
  Replies are logged; use `upload/2` for a synchronous result.
  """
  @spec upload_async(GenServer.server(), keyword()) :: :ok
  def upload_async(server \\ __MODULE__, opts), do: GenServer.cast(server, {:upload, opts})

  @impl true
  def handle_cast({:upload, opts}, state) do
    _ = upload(merge_opts(state, opts))
    {:noreply, state}
  end

  @impl true
  def handle_call({:upload, opts}, _from, state) do
    {:reply, upload(merge_opts(state, opts)), state}
  end

  defp merge_opts(state, opts) when is_map(state), do: Keyword.merge(Map.to_list(state), opts)

  ## --- Public callable API -------------------------------------------------

  @doc """
  Upload the finished race recording identified by `opts[:recording_id]` from
  `opts[:base_dir]` over the signed bulk plane, returning when the server reports
  the recording complete or the bounded pass budget is exhausted.

  Required options:

    * `:base_dir` — the race archive root (`/data/races` on target).
    * `:recording_id` — the recording directory id to upload.
    * `:race_session_id` — the server race-session id the manifest reconciles
      against (the server REQUIRES this to route the manifest; obtained from the
      `RaceAssignment` command — see `RacingOrg.Tracker.Pro.Commands.Assignment`).

  Optional options:

    * `:identity` — a `KeyStore.identity/0`; defaults to `KeyStore.load(opts)`.
      With no provisioned identity, returns `{:error, :not_provisioned}` (no-op).
    * `:adapter` — a Tesla adapter (used to inject a mock transport in tests).
    * `:base_url` — API base (defaults to the configured `:api_endpoint`).
    * `:version` — manifest version (default `1`).
    * `:device_status` — manifest device_status (default `"complete"`).
    * `:max_passes` — manifest submit/upload passes (default #{@default_max_passes}).
    * `:max_attempts` — per-request retry attempts (default #{@default_max_attempts}).
    * `:now` — unix-seconds clock fun for the assertion (default
      `&System.system_time/1`-based).
    * `:sleep_fn` — sleep fun for backoff (default `Process.sleep/1`; tests pass a
      no-op).

  Returns:

    * `{:ok, :complete}` — the server reports the recording fully verified.
    * `{:ok, :incomplete, missing_indexes}` — pass budget exhausted with chunks
      still missing (safe to call again later to resume).
    * `{:error, reason}` — could not load the recording / no identity / required
      option missing.
  """
  @spec upload(keyword()) ::
          {:ok, :complete}
          | {:ok, :incomplete, [non_neg_integer()]}
          | {:error, term()}
  def upload(opts) do
    with {:ok, base_dir} <- require_opt(opts, :base_dir),
         {:ok, recording_id} <- require_opt(opts, :recording_id),
         {:ok, race_session_id} <- require_opt(opts, :race_session_id),
         {:ok, identity} <- resolve_identity(opts),
         {:ok, recording} <- load_recording(base_dir, recording_id),
         {:ok, secure_session} <- secure_session_context(identity, opts) do
      plans = chunk_plans(recording)
      manifest_blob = build_manifest_blob(recording, race_session_id, plans, opts)
      opts = Keyword.put(opts, :secure_session, secure_session)

      Logger.info("Bulk upload starting: recording=#{recording_id} chunks=#{length(plans)} session=#{race_session_id}")

      run_passes(recording, identity, race_session_id, plans, manifest_blob, opts)
    end
  end

  ## --- the resumable pass loop ---------------------------------------------

  defp run_passes(recording, identity, race_session_id, plans, manifest_blob, opts) do
    max_passes = Keyword.get(opts, :max_passes, @default_max_passes)
    do_pass(recording, identity, race_session_id, plans, manifest_blob, opts, 1, max_passes)
  end

  defp do_pass(_rec, _id, _sess, _plans, _blob, _opts, pass, max_passes) when pass > max_passes do
    {:ok, :incomplete, []}
  end

  defp do_pass(recording, identity, race_session_id, plans, manifest_blob, opts, pass, max_passes) do
    case submit_manifest(identity, race_session_id, manifest_blob, plans, opts) do
      {:ok, :complete, _missing} ->
        Logger.info("Bulk upload complete: recording=#{recording.recording_id}")
        {:ok, :complete}

      {:ok, :incomplete, missing} ->
        Logger.info("Bulk upload pass #{pass}/#{max_passes}: server reports missing indexes #{inspect(missing)}")

        upload_missing(recording, identity, plans, missing, opts)

        do_pass(
          recording,
          identity,
          race_session_id,
          plans,
          manifest_blob,
          opts,
          pass + 1,
          max_passes
        )

      {:error, reason} ->
        # A manifest submit failure ends THIS run; the recording is untouched, so a
        # later run resumes from wherever the server's verified rows stand.
        Logger.warning("Bulk upload manifest submit failed: #{inspect(reason)}")
        {:ok, :incomplete, last_known_missing(plans)}
    end
  end

  # When we never got a manifest response, treat every planned index as missing.
  defp last_known_missing(plans), do: Enum.map(plans, & &1.index)

  ## --- manifest submit -----------------------------------------------------

  defp submit_manifest(identity, race_session_id, manifest_blob, plans, opts) do
    body =
      %{
        "manifest_protobuf" => Base.encode64(manifest_blob),
        "race_session_id" => race_session_id,
        "chunk_count" => length(plans),
        "version" => Keyword.get(opts, :version, 1)
      }

    case signed_post(@manifests_path, body, identity, opts) do
      {:ok, status, resp} when status in 200..299 ->
        {:ok, completeness(resp), missing_indexes(resp)}

      {:ok, status, resp} ->
        {:error, {:unexpected_status, status, resp}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp completeness(resp) do
    case resp do
      %{"verification_status" => "complete"} -> :complete
      _ -> :incomplete
    end
  end

  defp missing_indexes(resp) do
    resp
    |> Map.get("missing_chunk_indexes", [])
    |> List.wrap()
    |> Enum.map(&to_integer/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  ## --- chunk uploads -------------------------------------------------------

  # Upload exactly the chunks the server reports missing. A failure for one chunk is
  # logged and skipped (not fatal); the next pass / run retries it.
  defp upload_missing(recording, identity, plans, missing, opts) do
    plans_by_index = Map.new(plans, &{&1.index, &1})

    Enum.each(missing, fn index ->
      case Map.get(plans_by_index, index) do
        nil ->
          Logger.warning("Server requested unknown chunk index #{index}; skipping")

        plan ->
          upload_one_chunk(recording, identity, plan, opts)
      end
    end)
  end

  defp upload_one_chunk(recording, identity, plan, opts) do
    case read_chunk_bytes(recording, plan.disk_chunk_id) do
      {:ok, bytes} ->
        body = chunk_body(plan, bytes)
        path = chunks_path(recording.recording_id)

        case signed_post(path, body, identity, opts) do
          {:ok, status, resp} when status in 200..299 ->
            log_chunk_result(plan, resp)
            :ok

          {:ok, status, resp} ->
            Logger.warning("Chunk #{plan.chunk_id} upload non-2xx (#{status}): #{inspect(resp)}; will retry next pass")

            :error

          {:error, reason} ->
            Logger.warning("Chunk #{plan.chunk_id} upload failed: #{inspect(reason)}; will retry next pass")

            :error
        end

      {:error, reason} ->
        Logger.warning("Cannot read local chunk #{plan.disk_chunk_id}: #{inspect(reason)}")
        :error
    end
  end

  defp chunk_body(plan, bytes) do
    %{
      "data" => Base.encode64(bytes),
      "chunk_index" => plan.index,
      "chunk_key" => plan.chunk_id,
      "byte_count" => plan.byte_count,
      "checksum" => plan.checksum,
      "sample_count" => plan.sample_count
    }
  end

  defp log_chunk_result(plan, %{"verification" => "verified"}) do
    Logger.info("Chunk #{plan.chunk_id} verified by server")
  end

  defp log_chunk_result(plan, resp) do
    Logger.warning("Chunk #{plan.chunk_id} not verified: #{inspect(Map.get(resp, "verification"))}; will retry")
  end

  ## --- manifest + chunk plan construction ----------------------------------

  # Build the bulk-plane RaceManifest protobuf bytes, re-numbering chunk ids to a
  # dense 0-based space so the server's expected index space matches exactly.
  defp build_manifest_blob(recording, race_session_id, plans, opts) do
    chunks =
      Enum.map(plans, fn plan ->
        struct(ChunkDescriptor,
          chunk_id: plan.chunk_id,
          byte_count: plan.byte_count,
          checksum: plan.checksum,
          sample_count: plan.sample_count
        )
      end)

    manifest =
      struct(RaceManifest,
        race_recording_id: recording.recording_id,
        device_id: recording.device_id || "",
        assignment_id: recording.assignment_id || "",
        assignment_version: recording.assignment_version || 0,
        started_at: proto_ts(recording.started_at),
        finished_at: proto_ts(now_datetime(opts)),
        chunks: chunks,
        total_sample_count: Enum.sum(Enum.map(plans, & &1.sample_count)),
        course_hash: recording.course_hash || "",
        route_hash: recording.route_hash || "",
        device_status: Keyword.get(opts, :device_status, "complete")
      )

    # race_session_id is NOT a protobuf field; it travels in the JSON envelope (the
    # server's ManifestDecoder merges routing keys from the request params).
    _ = race_session_id
    RaceManifest.encode(manifest)
  end

  # Map the recording's sealed chunks to 0-based bulk plans, preserving each
  # chunk's original on-disk id (for reading the raw bytes) and its declared
  # byte_count / checksum / sample_count (already SHA-256-hex over the on-disk
  # bytes — see RacingOrg.Tracker.Pro.Race.Recording).
  defp chunk_plans(%Recording{sealed_chunks: sealed}) do
    sealed
    |> Enum.with_index()
    |> Enum.map(fn {descriptor, index} ->
      %{
        index: index,
        chunk_id: bulk_chunk_id(index),
        disk_chunk_id: descriptor.chunk_id,
        byte_count: descriptor.byte_count,
        checksum: descriptor.checksum,
        sample_count: descriptor.sample_count
      }
    end)
  end

  defp bulk_chunk_id(index), do: index |> Integer.to_string() |> String.pad_leading(4, "0")

  # Read the RAW on-disk chunk file bytes (length-delimited records). This is the
  # exact byte stream the manifest checksum was computed over, so the server's
  # recomputed SHA-256 will match.
  defp read_chunk_bytes(%Recording{dir: dir}, disk_chunk_id) do
    File.read(Path.join(dir, "chunk-#{disk_chunk_id}"))
  end

  ## --- signed POST with bounded retry/backoff ------------------------------

  # POST JSON to `path`, signing the request with the device identity. Retries on
  # transport errors AND 5xx (server-side transient), with jittered backoff, up to
  # `:max_attempts`. A 4xx is returned immediately (not retried — it is a contract
  # error, not transient).
  defp signed_post(path, body, identity, opts) do
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)
    do_signed_post(path, body, identity, opts, 0, max_attempts)
  end

  defp do_signed_post(path, body, identity, opts, attempt, max_attempts) do
    json_body = Jason.encode!(body)
    timestamp = now_unix(opts)
    headers = SignedRequest.header_list(identity, "POST", path, json_body, timestamp)

    case post(path, json_body, headers, opts) do
      {:ok, %Tesla.Env{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, status, decode_resp(resp_body)}

      {:ok, %Tesla.Env{status: status, body: resp_body}} when status in 400..499 ->
        # Client/contract error — not retried.
        {:ok, status, decode_resp(resp_body)}

      {:ok, %Tesla.Env{status: status, body: resp_body}} ->
        maybe_retry(path, body, identity, opts, attempt, max_attempts, {:ok, status, decode_resp(resp_body)})

      {:error, {:security_gate, _reason} = reason} ->
        {:error, reason}

      {:error, reason} ->
        maybe_retry(path, body, identity, opts, attempt, max_attempts, {:error, reason})
    end
  end

  defp maybe_retry(path, body, identity, opts, attempt, max_attempts, last) do
    if attempt + 1 < max_attempts do
      sleep_fn = Keyword.get(opts, :sleep_fn, &Process.sleep/1)
      sleep_fn.(Backoff.delay(attempt))
      do_signed_post(path, body, identity, opts, attempt + 1, max_attempts)
    else
      last
    end
  end

  # Build a Tesla client (JSON request encoding; we hand-encode for signing so the
  # SIGNED bytes match the wire bytes exactly — only DECODE responses) and POST the
  # pre-encoded body with the signed headers.
  defp post(path, json_body, headers, opts) do
    middleware = [{Tesla.Middleware.Headers, [{"content-type", "application/json"}]}]

    client =
      case Keyword.fetch(opts, :adapter) do
        {:ok, adapter} -> Tesla.client(middleware, adapter)
        :error -> Tesla.client(middleware)
      end

    url = base_url(opts) <> path

    with {:ok, secure_session} <- Keyword.fetch(opts, :secure_session),
         :ok <- recheck_durable_epoch(secure_session, opts) do
      fenced_post(secure_session, fn -> Tesla.post(client, url, json_body, headers: headers) end)
    else
      :error -> {:error, {:security_gate, :no_live_secure_session}}
      {:error, reason} -> {:error, {:security_gate, reason}}
    end
  end

  defp recheck_durable_epoch(secure_session, opts) do
    case credential_epoch(opts) do
      {:ok, epoch} when epoch == secure_session.credential_epoch -> :ok
      {:ok, _advanced_epoch} -> {:error, :stale_credential_epoch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fenced_post(secure_session, post_fun) do
    result =
      SessionHolder.with_session(
        secure_session.holder,
        secure_session.generation,
        fn current ->
          cond do
            current.session_id != secure_session.session_id ->
              {:error, {:security_gate, :stale_secure_session}}

            current.credential_epoch != secure_session.credential_epoch ->
              {:error, {:security_gate, :stale_credential_epoch}}

            session_identity_fingerprint(current) != secure_session.identity_fingerprint ->
              {:error, {:security_gate, :session_identity_mismatch}}

            true ->
              post_fun.()
          end
        end
      )

    case result do
      {:ok, post_result} -> post_result
      {:error, :stale_session} -> {:error, {:security_gate, :stale_secure_session}}
      {:error, :no_session} -> {:error, {:security_gate, :no_live_secure_session}}
      {:error, _reason} -> {:error, {:security_gate, :secure_request_failed}}
    end
  rescue
    _ -> {:error, {:security_gate, :secure_request_failed}}
  catch
    :exit, _ -> {:error, {:security_gate, :secure_request_failed}}
  end

  ## --- helpers -------------------------------------------------------------

  defp secure_session_context(identity, opts) do
    holder = Keyword.get(opts, :session_holder, SessionHolder)

    with {:ok, durable_epoch} <- credential_epoch(opts),
         {:ok, session} <- current_session(holder),
         :ok <- ensure_session_epoch(session, durable_epoch),
         :ok <- ensure_session_identity(session, identity) do
      {:ok,
       %{
         holder: holder,
         generation: session.generation,
         session_id: session.session_id,
         credential_epoch: durable_epoch,
         identity_fingerprint: identity_fingerprint(identity)
       }}
    end
  end

  defp current_session(holder) do
    case SessionHolder.get_current_session(holder) do
      {:ok, %{generation: generation} = session} when is_integer(generation) -> {:ok, session}
      _ -> {:error, :no_live_secure_session}
    end
  rescue
    _ -> {:error, :no_live_secure_session}
  catch
    :exit, _ -> {:error, :no_live_secure_session}
  end

  defp credential_epoch(opts) do
    case Keyword.get(opts, :credential_epoch_fun) do
      fun when is_function(fun, 0) ->
        normalize_credential_epoch(fun.())

      _ ->
        server = Keyword.get(opts, :boot_provisioner, BootProvisioner)
        normalize_credential_epoch(BootProvisioner.credential_epoch(server))
    end
  rescue
    _ -> {:error, :credential_epoch_unavailable}
  catch
    :exit, _ -> {:error, :credential_epoch_unavailable}
  end

  defp normalize_credential_epoch({:ok, epoch})
       when is_integer(epoch) and epoch >= 0 and epoch <= 0xFFFF_FFFF,
       do: {:ok, epoch}

  defp normalize_credential_epoch(_), do: {:error, :credential_epoch_unavailable}

  defp ensure_session_epoch(%{credential_epoch: epoch}, epoch), do: :ok
  defp ensure_session_epoch(_session, _durable_epoch), do: {:error, :stale_credential_epoch}

  defp ensure_session_identity(session, identity) do
    if session_identity_fingerprint(session) == identity_fingerprint(identity) do
      :ok
    else
      {:error, :session_identity_mismatch}
    end
  end

  defp session_identity_fingerprint(%{identity_fingerprint: fingerprint}) when is_binary(fingerprint) do
    Base.encode16(fingerprint, case: :lower)
  end

  defp session_identity_fingerprint(_), do: nil

  defp identity_fingerprint(%IdentityProvider{} = identity), do: IdentityProvider.fingerprint(identity)
  defp identity_fingerprint(%{fingerprint: fingerprint}) when is_binary(fingerprint), do: fingerprint

  defp chunks_path(recording_id) do
    String.replace(@chunks_path_template, ":recording_id", to_string(recording_id))
  end

  defp resolve_identity(opts) do
    case Keyword.fetch(opts, :identity) do
      {:ok, %IdentityProvider{} = identity} ->
        {:ok, identity}

      {:ok, %{private_key: _, fingerprint: _} = identity} ->
        {:ok, identity}

      _ ->
        case KeyStore.load(opts) do
          {:ok, identity} -> {:ok, identity}
          {:error, :not_provisioned} -> {:error, :not_provisioned}
          {:error, reason} -> {:error, {:identity, reason}}
        end
    end
  end

  defp load_recording(base_dir, recording_id) do
    case Recording.load(base_dir, recording_id) do
      {:ok, recording} -> {:ok, recording}
      :error -> {:error, {:recording_not_found, recording_id}}
    end
  end

  defp require_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing, key}}
      "" -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp base_url(opts) do
    Keyword.get(opts, :base_url) || Application.get_env(:racing_org_tracker_pro, :api_endpoint, "")
  end

  defp now_unix(opts) do
    case Keyword.get(opts, :now) do
      fun when is_function(fun, 0) -> fun.()
      ts when is_integer(ts) -> ts
      _ -> System.system_time(:second)
    end
  end

  defp now_datetime(opts) do
    case Keyword.get(opts, :finished_at) do
      %DateTime{} = dt -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp proto_ts(nil), do: nil
  defp proto_ts(%DateTime{} = dt), do: RacingOrg.Tracker.Protobuf.to_proto_timestamp(dt)

  # Tesla.Middleware.JSON is NOT in the client stack (we hand-encode requests), so a
  # 2xx response body may arrive as a raw JSON string; decode defensively.
  defp decode_resp(body) when is_map(body), do: body

  defp decode_resp(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_resp(_), do: %{}

  defp to_integer(n) when is_integer(n), do: n

  defp to_integer(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      _ -> nil
    end
  end

  defp to_integer(_), do: nil
end
