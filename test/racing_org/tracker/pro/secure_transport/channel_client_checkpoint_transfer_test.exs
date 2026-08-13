defmodule RacingOrg.Tracker.Pro.SecureTransport.ChannelClientCheckpointTransferTest do
  use Slipstream.SocketTest

  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.Staging
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Entry
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient
  alias RacingOrg.Tracker.Pro.SecureTransport.Handshake
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Pro.SecureTransport, as: SecureTransport
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{
    Canonical,
    Checkpoint,
    Control,
    Messages,
    Negotiation
  }

  @device_id <<0xD1::128>>
  @boot_id <<0xD2::128>>
  @storage_epoch <<0xD3::128>>
  @origin_storage_epoch <<0xD4::128>>
  @manifest_hash <<0xD5::256>>
  @credential_epoch 7
  @desired_generation 11

  setup do
    base = Path.join(System.tmp_dir!(), "cc_checkpoint_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    {:ok, identity} = KeyStore.load_or_generate(base_path: base)
    server_private = :binary.copy(<<0xB2>>, 32)
    server_public = Primitives.ed25519_public_from_secret(server_private)

    previous = Application.get_env(:racing_org_tracker_pro, ServerIdentity)
    Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: server_public)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:racing_org_tracker_pro, ServerIdentity)
        value -> Application.put_env(:racing_org_tracker_pro, ServerIdentity, value)
      end
    end)

    %{
      base: base,
      identity: identity,
      server_private: server_private,
      server_public: server_public
    }
  end

  defmodule FakeBootstrap do
    alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState

    def credential_epoch(_server), do: {:ok, 7}

    def adopt_credential_epoch(epoch, _server),
      do: {:ok, %BootstrapState{phase: :registered, verified_credential_epoch: epoch}}

    def authenticated(_server),
      do: {:ok, %BootstrapState{phase: :authenticated, verified_credential_epoch: 7}}

    def session_lost(_server), do: {:error, :bootstrap_unavailable}
    def legacy_enrollment_request(_server), do: {:error, :bootstrap_unavailable}
  end

  defmodule FakeCoordinator do
    def hydrate({owner, result}, generation, attrs) do
      send(owner, {:checkpoint_hydrate, generation, attrs})
      result
    end
  end

  defmodule FakeStaging do
    def put(root, attrs, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:staging_put, root, attrs})
      Keyword.get(opts, :put_result, {:ok, %{}})
    end

    def status(root, transfer, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:staging_status, root, transfer})
      result(opts, :status_result, transfer)
    end

    def assemble(root, transfer, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:staging_assemble, root, transfer})
      result(opts, :assemble_result, transfer)
    end

    def remove(root, checkpoint_hash, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:staging_remove, root, checkpoint_hash})
      result(opts, :remove_result, checkpoint_hash)
    end

    defp result(opts, key, value) do
      case Keyword.fetch!(opts, key) do
        fun when is_function(fun, 1) -> fun.(value)
        result -> result
      end
    end
  end

  describe "durable checkpoint submission dispatch" do
    test "dispatches exact planner frames in priority/FIFO order without retiring entries", ctx do
      low = single_frame_entry(1, priority: 1, ordinal: 1)
      high_first = single_frame_entry(2, priority: 9, ordinal: 2)
      high_second = single_frame_entry(3, priority: 9, ordinal: 3)
      entries = [low.entry, high_second.entry, high_first.entry]

      frame_by_entry = %{
        low.entry.entry_id => low.frame,
        high_first.entry.entry_id => high_first.frame,
        high_second.entry.entry_id => high_second.frame
      }

      owner = self()

      pending = fn outbox, opts ->
        send(owner, {:checkpoint_pending, outbox, opts})
        entries
      end

      planner = fn entry ->
        send(owner, {:checkpoint_plan, entry.entry_id})
        {:ok, %{entry: entry, payload: nil, frames: [Map.fetch!(frame_by_entry, entry.entry_id)]}}
      end

      {client, _id, topic, server_control, _holder} =
        start_checkpoint_client(ctx,
          outbox: :checkpoint_outbox,
          checkpoint_pending: pending,
          checkpoint_planner: planner
        )

      assert_receive {:checkpoint_pending, :checkpoint_outbox, [stream: :checkpoint]}, 1_000

      {server_control, first} = receive_control(topic, server_control)
      {server_control, second} = receive_control(topic, server_control)
      {_server_control, third} = receive_control(topic, server_control)

      assert Enum.map([first, second, third], &{&1.type, &1.attrs.sequence}) == [
               {:checkpoint_submission, 2},
               {:checkpoint_submission, 3},
               {:checkpoint_submission, 1}
             ]

      assert_received {:checkpoint_plan, entry_id} when entry_id == high_first.entry.entry_id
      assert_received {:checkpoint_plan, entry_id} when entry_id == high_second.entry.entry_id
      assert_received {:checkpoint_plan, entry_id} when entry_id == low.entry.entry_id
      refute_receive {:acknowledge, _, _}
      assert Process.alive?(client)
    end

    test "stops after an outbound frame failure and does not plan a later entry", ctx do
      first = submission_chunk_transfer(2, sequence: 4)
      later = single_frame_entry(5, priority: 1, ordinal: 2)
      owner = self()

      pending = fn _outbox, _opts -> [first.entry, later.entry] end

      planner = fn
        %Entry{entry_id: entry_id} when entry_id == first.entry.entry_id ->
          send(owner, {:checkpoint_send_plan, entry_id})
          {:ok, %{entry: first.entry, payload: nil, frames: first.frames}}

        entry ->
          send(owner, {:unexpected_checkpoint_plan, entry.entry_id})
          {:ok, %{entry: entry, payload: nil, frames: [later.frame]}}
      end

      {client, _id, topic, server_control, holder} =
        start_checkpoint_client(ctx,
          accept_control?: false,
          checkpoint_pending: pending,
          checkpoint_planner: planner
        )

      :sys.replace_state(holder, fn state ->
        %{state | control: %{state.control | send_counter: SecureTransport.rekey_after() - 2}}
      end)

      server_control = accept_control(client, topic, server_control)
      {_server_control, first_frame} = receive_control(topic, server_control)
      assert first_frame.attrs.chunk_index == 0
      assert_disconnect()
      assert_received {:checkpoint_send_plan, entry_id} when entry_id == first.entry.entry_id
      refute_receive {:unexpected_checkpoint_plan, _}, 100
      assert Process.alive?(client)
    end

    test "stops at a planner failure and leaves later checkpoint entries pending", ctx do
      first = single_frame_entry(1, priority: 9, ordinal: 1)
      later = single_frame_entry(2, priority: 1, ordinal: 2)
      owner = self()

      pending = fn _outbox, _opts -> [later.entry, first.entry] end

      planner = fn
        %Entry{entry_id: entry_id} when entry_id == first.entry.entry_id ->
          send(owner, {:checkpoint_plan_failed, entry_id})
          {:error, :checkpoint_unavailable}

        entry ->
          send(owner, {:unexpected_checkpoint_plan, entry.entry_id})
          {:ok, %{entry: entry, payload: nil, frames: [later.frame]}}
      end

      {client, _id, topic, _server_control, _holder} =
        start_checkpoint_client(ctx,
          checkpoint_pending: pending,
          checkpoint_planner: planner
        )

      assert_receive {:checkpoint_plan_failed, entry_id} when entry_id == first.entry.entry_id
      refute_receive {:unexpected_checkpoint_plan, _}, 100
      refute_push(^topic, "control_v1", _carrier, 50)
      assert Process.alive?(client)
    end
  end

  describe "authenticated checkpoint submission resume" do
    test "binds the resume to one exact pending transfer and resends only requested chunks ascending", ctx do
      transfer = submission_chunk_transfer(3)
      owner = self()
      counter = :counters.new(1, [])

      pending = fn _outbox, _opts ->
        :counters.add(counter, 1, 1)
        call = :counters.get(counter, 1)
        send(owner, {:checkpoint_resume_pending, call})

        if call == 1 do
          []
        else
          [transfer.entry]
        end
      end

      planner = fn entry ->
        send(owner, {:checkpoint_resume_plan, entry.entry_id})
        {:ok, %{entry: entry, payload: nil, frames: transfer.frames}}
      end

      {client, _id, topic, server_control, _holder} =
        start_checkpoint_client(ctx,
          checkpoint_pending: pending,
          checkpoint_planner: planner
        )

      assert_receive {:checkpoint_resume_pending, 1}, 1_000

      resume =
        transfer.resume
        |> Map.put(:missing_ranges, [
          %{first_chunk_index: 0, chunk_count: 1},
          %{first_chunk_index: 2, chunk_count: 1}
        ])

      server_control = push_control(client, topic, server_control, :checkpoint_submission_resume, resume)

      {server_control, first} = receive_control(topic, server_control)
      {server_control, second} = receive_control(topic, server_control)

      assert {first.type, first.attrs} == {:checkpoint_submission_chunk, Enum.at(transfer.frames, 0).attrs}
      assert {second.type, second.attrs} == {:checkpoint_submission_chunk, Enum.at(transfer.frames, 2).attrs}
      assert_received {:checkpoint_resume_plan, entry_id} when entry_id == transfer.entry.entry_id

      foreign = submission_chunk_transfer(2, sequence: 99)

      server_control =
        push_control(
          client,
          topic,
          server_control,
          :checkpoint_submission_resume,
          Map.put(foreign.resume, :missing_ranges, [%{first_chunk_index: 0, chunk_count: 1}])
        )

      refute_push(^topic, "control_v1", _carrier, 75)
      assert %Control{} = server_control
      assert Process.alive?(client)
    end

    test "refuses a resume before control readiness without consulting pending durable state", ctx do
      transfer = submission_chunk_transfer(2)
      owner = self()

      pending = fn _outbox, _opts ->
        send(owner, :checkpoint_pending_before_ready)
        [transfer.entry]
      end

      {client, _id, topic, server_control, _holder} =
        start_checkpoint_client(ctx,
          accept_control?: false,
          checkpoint_pending: pending,
          checkpoint_planner: fn entry ->
            {:ok, %{entry: entry, payload: nil, frames: transfer.frames}}
          end
        )

      resume = Map.put(transfer.resume, :missing_ranges, [%{first_chunk_index: 0, chunk_count: 1}])
      _server_control = push_control(client, topic, server_control, :checkpoint_submission_resume, resume)

      refute_receive :checkpoint_pending_before_ready, 100
      refute_push(^topic, "control_v1", _carrier, 50)
      assert Process.alive?(client)
    end
  end

  describe "authenticated checkpoint hydration" do
    test "routes a small hydration through the coordinator with the owning session generation", ctx do
      hydration = small_hydration(21)

      {client, _id, topic, server_control, holder} =
        start_checkpoint_client(ctx,
          checkpoint_hydration_coordinator: {self(), {:error, :runtime_restore_failed}}
        )

      generation = SessionHolder.generation(holder)
      _server_control = push_control(client, topic, server_control, :checkpoint_hydration, hydration)

      assert_receive {:checkpoint_hydrate, ^generation, ^hydration}, 1_000
      refute_push(^topic, "control_v1", _carrier, 50)
      assert Process.alive?(client)
    end

    test "refuses small and chunked hydration before control readiness", ctx do
      hydration = small_hydration(22)
      [chunk | _] = hydration_chunk_frames(large_hydration(23))

      {client, _id, topic, server_control, _holder} =
        start_checkpoint_client(ctx,
          accept_control?: false,
          checkpoint_hydration_coordinator: {self(), {:ok, :hydrated}},
          checkpoint_hydration_staging_module: FakeStaging,
          checkpoint_hydration_staging_opts: [
            test_pid: self(),
            status_result: {:error, :unexpected},
            assemble_result: {:error, :unexpected},
            remove_result: :ok
          ]
        )

      server_control = push_control(client, topic, server_control, :checkpoint_hydration, hydration)
      _server_control = push_control(client, topic, server_control, :checkpoint_hydration_chunk, chunk.attrs)

      refute_receive {:checkpoint_hydrate, _, _}, 100
      refute_receive {:staging_put, _, _}, 100
      refute_push(^topic, "control_v1", _carrier, 50)
      assert Process.alive?(client)
    end

    test "requires current identity plus active generation and manifest authority before staging or hydration", ctx do
      hydration = small_hydration(24)
      [chunk | _] = hydration_chunk_frames(large_hydration(25))

      invalid_status = fn ->
        %{
          active: %{
            device_id: @device_id,
            credential_epoch: @credential_epoch,
            storage_epoch: @storage_epoch,
            generation: @desired_generation,
            manifest_hash: <<0xAA>>
          }
        }
      end

      status_counter = :counters.new(1, [])

      status = fn ->
        :counters.add(status_counter, 1, 1)
        if :counters.get(status_counter, 1) == 1, do: %{active: active_authority()}, else: invalid_status.()
      end

      {client, _id, topic, server_control, _holder} =
        start_checkpoint_client(ctx,
          desired_state_status: status,
          checkpoint_hydration_coordinator: {self(), {:ok, :hydrated}},
          checkpoint_hydration_staging_module: FakeStaging,
          checkpoint_hydration_staging_opts: [
            test_pid: self(),
            status_result: {:error, :unexpected},
            assemble_result: {:error, :unexpected},
            remove_result: :ok
          ]
        )

      server_control = push_control(client, topic, server_control, :checkpoint_hydration, hydration)
      _server_control = push_control(client, topic, server_control, :checkpoint_hydration_chunk, chunk.attrs)

      refute_receive {:checkpoint_hydrate, _, _}, 100
      refute_receive {:staging_put, _, _}, 100
      refute_push(^topic, "control_v1", _carrier, 50)
      assert Process.alive?(client)
    end
  end

  describe "crash-safe chunked checkpoint hydration" do
    test "recovers staged chunks after a client restart, resumes exact gaps, hydrates, and removes only after success",
         ctx do
      staging_root = Path.join(ctx.base, "checkpoint_hydration_staging")
      hydration = large_hydration(31)
      [first, final] = hydration_chunk_frames(hydration)

      {first_client, first_id, topic, server_control, _holder} =
        start_checkpoint_client(ctx,
          checkpoint_hydration_coordinator: {self(), {:ok, :hydrated}},
          checkpoint_hydration_staging_root: staging_root
        )

      server_control =
        push_control(first_client, topic, server_control, :checkpoint_hydration_chunk, first.attrs)

      {_server_control, resume} = receive_control(topic, server_control)
      assert resume.type == :checkpoint_hydration_resume

      assert resume.attrs ==
               hydration
               |> Map.delete(:content)
               |> Map.merge(%{
                 total_content_length: byte_size(hydration.content),
                 chunk_count: 2,
                 missing_ranges: [%{first_chunk_index: 1, chunk_count: 1}]
               })

      assert :ok = stop_supervised(first_id)
      assert File.dir?(Staging.path(staging_root, hydration.checkpoint_hash))

      {second_client, _second_id, ^topic, second_control, second_holder} =
        start_checkpoint_client(ctx,
          checkpoint_hydration_coordinator: {self(), {:ok, :hydrated}},
          checkpoint_hydration_staging_root: staging_root
        )

      generation = SessionHolder.generation(second_holder)

      _second_control =
        push_control(second_client, topic, second_control, :checkpoint_hydration_chunk, final.attrs)

      assert_receive {:checkpoint_hydrate, ^generation, hydrated}, 2_000
      assert hydrated == hydration
      refute_push(^topic, "control_v1", _carrier, 75)

      assert eventually(fn ->
               not File.exists?(Staging.path(staging_root, hydration.checkpoint_hash))
             end)
    end

    test "represents completion with no resume and retains staged bytes when coordinator hydration fails", ctx do
      staging_root = Path.join(ctx.base, "checkpoint_hydration_failure")
      hydration = large_hydration(32)
      [first, final] = hydration_chunk_frames(hydration)

      {client, _id, topic, server_control, holder} =
        start_checkpoint_client(ctx,
          checkpoint_hydration_coordinator: {self(), {:error, :checkpoint_hydration_recovery_required}},
          checkpoint_hydration_staging_root: staging_root
        )

      server_control = push_control(client, topic, server_control, :checkpoint_hydration_chunk, first.attrs)
      {server_control, resume} = receive_control(topic, server_control)
      assert resume.type == :checkpoint_hydration_resume

      generation = SessionHolder.generation(holder)
      _server_control = push_control(client, topic, server_control, :checkpoint_hydration_chunk, final.attrs)

      assert_receive {:checkpoint_hydrate, ^generation, ^hydration}, 2_000
      refute_push(^topic, "control_v1", _carrier, 75)
      assert File.dir?(Staging.path(staging_root, hydration.checkpoint_hash))
      assert Process.alive?(client)
    end
  end

  defp start_checkpoint_client(ctx, opts) do
    accept_control? = Keyword.get(opts, :accept_control?, true)
    id = {:checkpoint_channel_client, System.unique_integer([:positive])}
    holder_id = {:checkpoint_session_holder, System.unique_integer([:positive])}
    {:ok, holder} = start_supervised({SessionHolder, name: nil}, id: holder_id)
    topic = "device:" <> ctx.identity.fingerprint

    defaults = [
      name: nil,
      auto_connect?: true,
      test_mode?: true,
      url: "wss://test.local/device_socket/websocket",
      session_holder: holder,
      boot_provisioner: {FakeBootstrap, :checkpoint_bootstrap},
      desired_state_identity: fn -> {:ok, control_identity()} end,
      desired_state_compatibility: fn ->
        %{
          firmware_version: "0.7.0",
          firmware_git_sha: "0123abc",
          capabilities: []
        }
      end,
      desired_state_status: fn -> %{active: active_authority()} end,
      desired_state_replay: fn _generation -> :ok end,
      checkpoint_pending: fn _outbox, _opts -> [] end,
      checkpoint_planner: fn _entry -> {:error, :unexpected_checkpoint_entry} end,
      checkpoint_hydration_coordinator: {self(), {:ok, :hydrated}},
      checkpoint_hydration_coordinator_module: FakeCoordinator,
      checkpoint_hydration_staging_root: Path.join(ctx.base, "checkpoint_hydration_staging"),
      keystore_opts: [base_path: ctx.base]
    ]

    channel_opts =
      defaults
      |> Keyword.merge(Keyword.drop(opts, [:accept_control?]))

    client = start_supervised!({ChannelClient, channel_opts}, id: id)
    connect_and_assert_join(client, ^topic, %{}, :ok)
    server_session = complete_handshake(client, topic, ctx)
    assert_push(^topic, "wifi_status", _wifi_status)
    assert {:ok, server_control} = Control.new(:server, server_session)

    server_control =
      if accept_control? do
        accept_control(client, topic, server_control)
      else
        server_control
      end

    {client, id, topic, server_control, holder}
  end

  defp complete_handshake(client, topic, ctx) do
    {:ok, hello, responder} =
      Handshake.responder_hello(
        server_identity_private: ctx.server_private,
        server_identity_public: ctx.server_public,
        device_identity_public: ctx.identity.public_key,
        epoch: @credential_epoch
      )

    push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello)})
    assert_push(^topic, "handshake_init", %{"init" => init_b64})
    {:ok, init} = Base.decode64(init_b64)
    {:ok, server_session} = Handshake.responder_finalize(responder, init)
    push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})
    server_session
  end

  defp accept_control(client, topic, server_control) do
    {:ok, selection} = Negotiation.select(%{control_versions: [1], desired_state_versions: [1]})

    attrs = %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      selected_control_version: selection.selected_control_version,
      selected_desired_version: selection.selected_desired_version,
      offer_hash: selection.offer_hash
    }

    server_control = push_control(client, topic, server_control, :control_accept, attrs)
    {server_control, readiness} = receive_control(topic, server_control)
    assert readiness.type == :readiness
    server_control
  end

  defp push_control(client, topic, server_control, type, attrs) do
    assert {:ok, bytes} = Messages.encode(type, attrs)
    assert {:ok, frame, server_control} = Control.seal(server_control, type, bytes)
    push(client, topic, "control_v1", Control.encode_carrier(frame))
    server_control
  end

  defp receive_control(topic, server_control) do
    assert_push(^topic, "control_v1", carrier)
    assert {:ok, frame} = Control.decode_carrier(carrier)
    assert {:ok, type, bytes, server_control} = Control.open(server_control, frame)
    assert {:ok, attrs} = Messages.decode(type, bytes)
    {server_control, %{type: type, attrs: attrs}}
  end

  defp single_frame_entry(sequence, opts) do
    attrs = submission_attrs(sequence, small_content())

    entry =
      entry(attrs,
        priority: Keyword.fetch!(opts, :priority),
        ordinal: Keyword.fetch!(opts, :ordinal)
      )

    %{entry: entry, frame: %{type: :checkpoint_submission, attrs: attrs}}
  end

  defp submission_chunk_transfer(chunk_count, opts \\ []) do
    sequence = Keyword.get(opts, :sequence, 41)
    total_content_length = max(Contract.max_checkpoint_size() + 1, (chunk_count - 1) * Contract.chunk_size() + 3)
    content = runtime_polar_content(total_content_length)
    common = submission_attrs(sequence, content) |> Map.delete(:content)

    frames =
      for chunk_index <- 0..(chunk_count - 1) do
        chunk_offset = chunk_index * Contract.chunk_size()
        chunk_length = min(Contract.chunk_size(), total_content_length - chunk_offset)
        chunk = binary_part(content, chunk_offset, chunk_length)

        hash_attrs = %{
          checkpoint_hash: common.checkpoint_hash,
          total_content_length: total_content_length,
          chunk_index: chunk_index,
          chunk_count: chunk_count,
          chunk_offset: chunk_offset,
          chunk: chunk
        }

        {:ok, chunk_hash} = Checkpoint.chunk_hash(hash_attrs)

        %{
          type: :checkpoint_submission_chunk,
          attrs: Map.merge(common, Map.put(hash_attrs, :chunk_hash, chunk_hash))
        }
      end

    %{
      entry: entry(common, priority: 5, ordinal: 1),
      frames: frames,
      resume: Map.merge(common, %{total_content_length: total_content_length, chunk_count: chunk_count})
    }
  end

  defp entry(attrs, opts) do
    payload = Map.get(attrs, :content, "checkpoint-payload-#{attrs.sequence}")

    %Entry{
      stream: :checkpoint,
      device_id: attrs.device_id,
      credential_epoch: attrs.credential_epoch,
      storage_epoch: attrs.storage_epoch,
      sequence: attrs.sequence,
      entry_id: <<attrs.sequence::128>>,
      payload_hash: attrs.checkpoint_hash,
      payload_checksum: :crypto.hash(:sha256, payload),
      payload: payload,
      priority: Keyword.fetch!(opts, :priority),
      encoded_size: byte_size(payload) + 128,
      ordinal: Keyword.fetch!(opts, :ordinal)
    }
  end

  defp submission_attrs(sequence, content) do
    schema_version = if byte_size(content) > Contract.max_checkpoint_size(), do: 3, else: 2
    {:ok, content_hash} = Checkpoint.content_hash(:polar, schema_version, content)

    common = %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      sequence: sequence,
      kind: :polar,
      schema_version: schema_version,
      source_generation: sequence,
      parent_hash: <<0::256>>,
      content_hash: content_hash
    }

    {:ok, checkpoint_hash} = Checkpoint.hash(common)
    common |> Map.put(:checkpoint_hash, checkpoint_hash) |> Map.put(:content, content)
  end

  defp small_hydration(sequence), do: hydration(sequence, small_content())
  defp large_hydration(sequence), do: hydration(sequence, runtime_polar_content(Contract.chunk_size() + 1))

  defp hydration(sequence, content) do
    kind = if byte_size(content) > Contract.chunk_size(), do: :polar, else: :polar
    schema_version = if byte_size(content) > Contract.chunk_size(), do: 3, else: 2
    {:ok, content_hash} = Checkpoint.content_hash(kind, schema_version, content)

    checkpoint = %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      origin_credential_epoch: @credential_epoch - 1,
      origin_storage_epoch: @origin_storage_epoch,
      sequence: sequence,
      kind: kind,
      schema_version: schema_version,
      source_generation: 42,
      parent_hash: <<0::256>>,
      content_hash: content_hash
    }

    {:ok, checkpoint_hash} =
      Checkpoint.hash(%{
        device_id: checkpoint.device_id,
        credential_epoch: checkpoint.origin_credential_epoch,
        storage_epoch: checkpoint.origin_storage_epoch,
        sequence: checkpoint.sequence,
        kind: checkpoint.kind,
        schema_version: checkpoint.schema_version,
        source_generation: checkpoint.source_generation,
        parent_hash: checkpoint.parent_hash,
        content_hash: checkpoint.content_hash
      })

    checkpoint |> Map.put(:checkpoint_hash, checkpoint_hash) |> Map.put(:content, content)
  end

  defp hydration_chunk_frames(hydration) do
    content = hydration.content
    common = Map.delete(hydration, :content)
    total_content_length = byte_size(content)
    chunk_count = div(total_content_length + Contract.chunk_size() - 1, Contract.chunk_size())

    for chunk_index <- 0..(chunk_count - 1) do
      chunk_offset = chunk_index * Contract.chunk_size()
      chunk_length = min(Contract.chunk_size(), total_content_length - chunk_offset)
      chunk = binary_part(content, chunk_offset, chunk_length)

      hash_attrs = %{
        checkpoint_hash: common.checkpoint_hash,
        total_content_length: total_content_length,
        chunk_index: chunk_index,
        chunk_count: chunk_count,
        chunk_offset: chunk_offset,
        chunk: chunk
      }

      {:ok, chunk_hash} = Checkpoint.chunk_hash(hash_attrs)

      %{
        type: :checkpoint_hydration_chunk,
        attrs: Map.merge(common, Map.put(hash_attrs, :chunk_hash, chunk_hash))
      }
    end
  end

  defp control_identity do
    %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      boot_id: @boot_id,
      storage_epoch: @storage_epoch
    }
  end

  defp active_authority do
    %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      generation: @desired_generation,
      manifest_hash: @manifest_hash
    }
  end

  defp small_content do
    {:ok, content} = Checkpoint.canonical_content(:polar, 2, polar_checkpoint())
    content
  end

  defp runtime_polar_content(target_size) do
    Enum.find_value([polar_checkpoint(), %{polar_checkpoint() | "cells" => []}], fn learner ->
      content = runtime_polar_checkpoint(learner)
      {:ok, base} = Canonical.encode(content)
      padding_size = target_size - byte_size(base)

      if padding_size >= 0 and rem(padding_size, 2) == 0 do
        current_authority = content["authority"]["boat_identifier"]
        authority = :binary.copy("x", byte_size(current_authority) + div(padding_size, 2))

        padded =
          content
          |> put_in(["authority", "boat_identifier"], authority)
          |> put_in(["learner", "content", "authority"], authority)

        case Checkpoint.canonical_content(:polar, 3, padded) do
          {:ok, bytes} when byte_size(bytes) == target_size -> bytes
          _other -> nil
        end
      end
    end) || flunk("could not build exact #{target_size}-byte runtime polar checkpoint")
  end

  defp runtime_polar_checkpoint(learner) do
    authority = "boat-runtime"
    policy = runtime_polar_policy()
    {:ok, learner_bytes} = Checkpoint.canonical_content(:polar, 2, learner)
    {:ok, learner_hash} = Checkpoint.content_hash(:polar, 2, learner_bytes)

    %{
      "runtime_schema_version" => 3,
      "runtime_snapshot_version" => 1,
      "captured_at_utc_ms" => 1_786_536_000_000,
      "authority" => %{"boat_identifier" => authority},
      "policy" => policy,
      "learner" => %{
        "source_generation" => 42,
        "content" => %{
          "authority" => authority,
          "policy_hash" => policy["admission_hash"],
          "kind" => "polar",
          "schema_version" => 2,
          "source_generation" => 42,
          "content_hash" => Canonical.bytes(learner_hash),
          "content" => Canonical.bytes(learner_bytes)
        }
      },
      "upstream_seq" => 0,
      "window" => %{"count" => 0, "chunks" => []},
      "sync" => %{
        "dirty_keys" => %{"count" => 0, "chunks" => []},
        "last_sync_age_ms" => 0
      },
      "persistence_phase" => %{
        "dirty_keys" => %{"count" => 0, "chunks" => []},
        "force" => false,
        "last_persist_age_ms" => 0
      },
      "tick" => %{"remaining_ms" => nil}
    }
  end

  defp runtime_polar_policy do
    gate = %{
      "angle_band_deg" => [25.0, 165.0],
      "heel_band_deg" => [-45.0, 45.0],
      "max_tws_sd_mps" => 0.2572,
      "max_turn_rate_dps" => 3.0,
      "max_accel_mps2" => 0.05,
      "min_dwell" => 1,
      "engine_rpm_idle" => 50.0,
      "angle_key" => "twa_deg"
    }

    hash_content = %{
      "gate" => gate,
      "min_stw_mps" => 0.3,
      "p" => 0.9,
      "window_size" => 1
    }

    {:ok, hash_bytes} = Canonical.encode(hash_content)
    admission_hash = :crypto.hash(:sha256, "RacingOrg-PolarObserverPolicy-v1" <> hash_bytes)

    %{
      "admission_hash" => Canonical.bytes(admission_hash),
      "gate" => gate,
      "min_stw_mps" => 0.3,
      "window_size" => 1,
      "p" => 0.9,
      "sample_ms" => 0,
      "sync_ms" => 60_000,
      "persist_ms" => 60_000,
      "persistence_enabled" => true,
      "bins" => %{
        "twa_width_deg" => 5.0,
        "tws_width_mps" => 0.514444,
        "max_tws_mps" => 51.4444
      }
    }
  end

  defp polar_checkpoint do
    %{
      "cells" => [
        %{
          "count" => 5,
          "quantile" => %{
            "buffer" => [],
            "n" => [2, 3, 4],
            "np" => [1.0, 2.8, 4.6, 4.8, 5.0],
            "q" => [1.0, 2.0, 3.0, 4.0, 5.0]
          },
          "twa_bin" => 35,
          "tws_bin" => 3
        }
      ],
      "max_tws_mps" => 51.4444,
      "p" => 0.9,
      "twa_width_deg" => 5.0,
      "tws_width_mps" => 0.514444
    }
  end

  defp eventually(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    eventually_until(fun, deadline)
  end

  defp eventually_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(10)
        eventually_until(fun, deadline)
      end
    end
  end
end
