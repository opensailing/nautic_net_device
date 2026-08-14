defmodule RacingOrg.Tracker.Pro.E2E.MultiStreamLossSurvivalTest do
  @moduledoc """
  Multi-stream loss survival: durable outbox entries pending across MULTIPLE
  streams (telemetry/dataset, health, desired-state ACK, checkpoint) survive a
  session drop + reconnect, redispatch in per-stream sequence order, and drain
  exactly once under receipt discipline — receipts are stream/entry scoped and a
  rejected delivery on one stream never stalls the others beyond its own retry.

  Chain boundary: this module chains a REAL slice end to end — the real stream
  producers (Producer.DataSet, Producer.HealthEvent, Producer.DesiredStateAck)
  and Owner.enqueue_checkpoint admit into one real DurableDelivery.Outbox.Owner
  on a private fsynced tmp root; the real Submission.Planner plans every frame;
  and a real SecureTransport.ChannelClient (default outbox/planner wiring)
  transmits over Slipstream.SocketTest's fake socket backend. This test process
  plays the backend: it completes the handshake, negotiates control, opens every
  sealed control frame, and issues (or corrupts/withholds) authenticated
  delivery receipts. The session drop is simulated at the TRANSPORT layer — a
  Slipstream ChannelClosed (`disconnect/2`) followed by the client's own backoff
  reconnect, a fresh handshake, and fresh control negotiation. Outside the
  chain: the real Phoenix backend (its receipt issuance policy and server-side
  persistence) and a real network/websocket.
  """
  use Slipstream.SocketTest

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Entry
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner
  alias RacingOrg.Tracker.Pro.DurableDelivery.Producer.DataSet, as: DataSetProducer
  alias RacingOrg.Tracker.Pro.DurableDelivery.Producer.DesiredStateAck, as: DesiredStateAckProducer
  alias RacingOrg.Tracker.Pro.DurableDelivery.Producer.HealthEvent, as: HealthEventProducer
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient
  alias RacingOrg.Tracker.Pro.SecureTransport.Handshake
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Protobuf.DataSet
  alias RacingOrg.Tracker.Protobuf.DataSet.DataPoint
  alias RacingOrg.Tracker.Protobuf.SpeedSample

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{
    Checkpoint,
    Control,
    Messages,
    Negotiation,
    Receipt
  }

  @moduletag :capture_log

  @device_id <<0xE1::128>>
  @boot_id <<0xE2::128>>
  @storage_epoch <<0xE3::128>>
  @credential_epoch 7
  @manifest_hash :binary.copy(<<0xA5>>, 32)

  setup do
    base = Path.join(System.tmp_dir!(), "e2e_loss_base_#{System.unique_integer([:positive])}")
    outbox_root = Path.join(System.tmp_dir!(), "e2e_loss_outbox_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    on_exit(fn ->
      File.rm_rf(base)
      File.rm_rf(outbox_root)
    end)

    {:ok, identity} = KeyStore.load_or_generate(base_path: base)
    server_private = :binary.copy(<<0xB4>>, 32)
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
      outbox_root: outbox_root,
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

  test "pending entries on every stream survive a session drop, redispatch in per-stream order, and drain exactly once by receipt",
       ctx do
    owner = start_owner!(ctx.outbox_root)

    # Durably admit pending work on all four streams through the REAL producers
    # before any transport exists. Per-stream sequence spaces are independent.
    assert {:ok, tel1} = admit_data_set(owner, 1)
    assert {:ok, tel2} = admit_data_set(owner, 2)
    assert {:ok, health1} = admit_health_event(owner, 123)
    assert {:ok, health2} = admit_health_event(owner, 124)
    assert {:ok, dsack1} = admit_desired_state_ack(owner, 42)
    assert {:ok, dsack2} = admit_desired_state_ack(owner, 43)
    assert {:ok, ckpt1} = Owner.enqueue_checkpoint(owner, &checkpoint_delivery(&1, <<0::256>>))
    assert {:ok, ckpt2} = Owner.enqueue_checkpoint(owner, &checkpoint_delivery(&1, ckpt1.payload_hash))

    assert {tel1.sequence, tel2.sequence} == {1, 2}
    assert {health1.sequence, health2.sequence} == {1, 2}
    assert {dsack1.sequence, dsack2.sequence} == {1, 2}
    assert {ckpt1.sequence, ckpt2.sequence} == {1, 2}
    assert length(Owner.pending(owner)) == 8

    {client, topic, holder} = start_client!(ctx, owner)

    # --- First session: readiness auto-dispatches checkpoints, then generic
    # entries in priority/FIFO (ordinal) order, without retiring anything.
    server_control = establish_session(client, topic, ctx)
    {frames_before, server_control} = receive_frames(topic, server_control, 14)

    expected_order = [
      {:checkpoint_submission, :checkpoint, 1},
      {:checkpoint_submission, :checkpoint, 2},
      {:delivery_submission, :telemetry, 1},
      {:delivery_payload, :telemetry, 1},
      {:delivery_submission, :telemetry, 2},
      {:delivery_payload, :telemetry, 2},
      {:delivery_submission, :health, 1},
      {:delivery_payload, :health, 1},
      {:delivery_submission, :health, 2},
      {:delivery_payload, :health, 2},
      {:delivery_submission, :desired_state_ack, 1},
      {:delivery_payload, :desired_state_ack, 1},
      {:delivery_submission, :desired_state_ack, 2},
      {:delivery_payload, :desired_state_ack, 2}
    ]

    assert Enum.map(frames_before, &frame_identity/1) == expected_order

    # Transport carried the exact durable bytes: every payload frame hashes to
    # its submission identity, and the checkpoint chain parent links hold.
    for %{type: :delivery_payload, attrs: attrs} <- frames_before do
      assert :crypto.hash(:sha256, attrs.payload) == attrs.payload_hash
    end

    [ckpt_frame1, ckpt_frame2] = for %{type: :checkpoint_submission, attrs: attrs} <- frames_before, do: attrs
    assert ckpt_frame1.checkpoint_hash == ckpt1.payload_hash
    assert ckpt_frame2.checkpoint_hash == ckpt2.payload_hash
    assert ckpt_frame2.parent_hash == ckpt_frame1.checkpoint_hash

    hashes_before = submission_hashes(frames_before)

    assert hashes_before == %{
             {:checkpoint, 1} => ckpt1.payload_hash,
             {:checkpoint, 2} => ckpt2.payload_hash,
             {:telemetry, 1} => tel1.payload_hash,
             {:telemetry, 2} => tel2.payload_hash,
             {:health, 1} => health1.payload_hash,
             {:health, 2} => health2.payload_hash,
             {:desired_state_ack, 1} => dsack1.payload_hash,
             {:desired_state_ack, 2} => dsack2.payload_hash
           }

    # Retire exactly ONE entry (telemetry seq 1) with an authenticated receipt
    # before the drop; every other receipt is "lost" with the session.
    # The control state seals one receipt and then dies with the session drop.
    _pre_drop_control = push_receipt(client, topic, server_control, receipt_for(tel1))
    assert_receive {:retired, [%Entry{stream: :telemetry, sequence: 1}]}, 2_000
    assert pending_sequences(owner, :telemetry) == [2]
    assert length(Owner.pending(owner)) == 7

    # --- Session drop at the transport layer.
    disconnect(client, :network_lost)
    assert eventually(fn -> not SessionHolder.live?(holder) end)
    assert Process.alive?(client)
    assert length(Owner.pending(owner)) == 7

    # --- Reconnect: fresh join, fresh handshake, fresh control negotiation.
    # Readiness re-dispatches EVERY still-pending entry; the receipt-retired
    # telemetry seq 1 is never resurrected.
    server_control = establish_session(client, topic, ctx)
    {frames_after, server_control} = receive_frames(topic, server_control, 12)
    refute_push(^topic, "control_v1", _extra, 50)

    assert Enum.map(frames_after, &frame_identity/1) == [
             {:checkpoint_submission, :checkpoint, 1},
             {:checkpoint_submission, :checkpoint, 2},
             {:delivery_submission, :telemetry, 2},
             {:delivery_payload, :telemetry, 2},
             {:delivery_submission, :health, 1},
             {:delivery_payload, :health, 1},
             {:delivery_submission, :health, 2},
             {:delivery_payload, :health, 2},
             {:delivery_submission, :desired_state_ack, 1},
             {:delivery_payload, :desired_state_ack, 1},
             {:delivery_submission, :desired_state_ack, 2},
             {:delivery_payload, :desired_state_ack, 2}
           ]

    # Nothing lost, nothing mutated across the drop: identical durable identity
    # and identical payload bytes for every surviving entry.
    assert submission_hashes(frames_after) == Map.delete(hashes_before, {:telemetry, 1})
    assert payload_bytes(frames_after) == Map.delete(payload_bytes(frames_before), {:telemetry, 1})

    # --- Failure injection on ONE stream: the server rejects telemetry seq 2 by
    # answering with a corrupted receipt (wrong payload hash). The durable owner
    # refuses it; every OTHER stream keeps draining under receipt discipline.
    bad_telemetry_receipt = %{receipt_for(tel2) | payload_hash: :crypto.hash(:sha256, "not-the-payload")}
    server_control = push_receipt(client, topic, server_control, bad_telemetry_receipt)

    server_control =
      Enum.reduce(
        [
          {receipt_for(ckpt1), :checkpoint, 1},
          {receipt_for(ckpt2), :checkpoint, 2},
          {receipt_for(health1), :health, 1},
          {receipt_for(health2), :health, 2},
          {receipt_for(dsack1), :desired_state_ack, 1},
          {receipt_for(dsack2), :desired_state_ack, 2}
        ],
        server_control,
        fn {receipt, stream, sequence}, control ->
          control = push_receipt(client, topic, control, receipt)
          assert_receive {:retired, [%Entry{stream: ^stream, sequence: ^sequence}]}, 2_000
          control
        end
      )

    # The rejected stream is the ONLY one still pending; it stalled nobody else.
    assert Enum.map(Owner.pending(owner), &{&1.stream, &1.sequence}) == [{:telemetry, 2}]

    # --- The failed stream's own retry: a dispatch kick retransmits exactly the
    # still-pending telemetry entry and nothing else.
    assert :ok = ChannelClient.dispatch_durable_deliveries(client)
    {retry_frames, server_control} = receive_frames(topic, server_control, 2)
    refute_push(^topic, "control_v1", _extra, 50)

    assert Enum.map(retry_frames, &frame_identity/1) == [
             {:delivery_submission, :telemetry, 2},
             {:delivery_payload, :telemetry, 2}
           ]

    assert submission_hashes(retry_frames) == %{{:telemetry, 2} => tel2.payload_hash}

    # A correct receipt now retires it; the outbox is fully drained.
    server_control = push_receipt(client, topic, server_control, receipt_for(tel2))
    assert_receive {:retired, [%Entry{stream: :telemetry, sequence: 2}]}, 2_000
    assert Owner.pending(owner) == []

    # Exactly-once: a redelivered duplicate receipt is idempotent — it retires
    # nothing and disturbs nothing.
    _server_control = push_receipt(client, topic, server_control, receipt_for(tel2))
    refute_receive {:retired, _entries}, 50
    assert Owner.pending(owner) == []
    refute_receive {:retired, _entries}, 50
    assert Process.alive?(client)
  end

  test "receipts stay stream-scoped across a drop: a receipt for one stream/entry never retires another", ctx do
    owner = start_owner!(ctx.outbox_root)

    assert {:ok, tel1} = admit_data_set(owner, 1)
    assert {:ok, health1} = admit_health_event(owner, 123)
    assert {tel1.sequence, health1.sequence} == {1, 1}
    refute tel1.payload_hash == health1.payload_hash

    {client, topic, holder} = start_client!(ctx, owner)

    server_control = establish_session(client, topic, ctx)
    {frames_before, _server_control} = receive_frames(topic, server_control, 4)

    assert Enum.map(frames_before, &frame_identity/1) == [
             {:delivery_submission, :telemetry, 1},
             {:delivery_payload, :telemetry, 1},
             {:delivery_submission, :health, 1},
             {:delivery_payload, :health, 1}
           ]

    # Drop with EVERY receipt outstanding, then reconnect.
    disconnect(client, :network_lost)
    assert eventually(fn -> not SessionHolder.live?(holder) end)

    server_control = establish_session(client, topic, ctx)
    {frames_after, server_control} = receive_frames(topic, server_control, 4)
    assert Enum.map(frames_after, &frame_identity/1) == Enum.map(frames_before, &frame_identity/1)
    assert submission_hashes(frames_after) == submission_hashes(frames_before)

    # Cross-contamination probes: authentically sealed receipts that name one
    # stream with the other stream's durable payload identity (both directions),
    # and a receipt for a sequence that exists in no stream. All are refused and
    # none may retire anything.
    cross_receipts = [
      %{receipt_for(health1) | payload_hash: tel1.payload_hash},
      %{receipt_for(tel1) | payload_hash: health1.payload_hash},
      %{receipt_for(health1) | sequence: 2}
    ]

    server_control =
      Enum.reduce(cross_receipts, server_control, fn receipt, control ->
        push_receipt(client, topic, control, receipt)
      end)

    # Sync point: a CORRECT cumulative health receipt is processed strictly
    # after the probes; its retirement proves the probes were seen and refused.
    # Cumulative closure is also stream-scoped — it retires health seq 1 only
    # and never touches telemetry seq 1.
    server_control = push_receipt(client, topic, server_control, %{receipt_for(health1) | cumulative_sequence: 1})
    assert_receive {:retired, [%Entry{stream: :health, sequence: 1}]}, 2_000
    assert pending_sequences(owner, :health) == []
    assert pending_sequences(owner, :telemetry) == [1]

    # The surviving telemetry entry still drains under its own exact receipt.
    _server_control = push_receipt(client, topic, server_control, receipt_for(tel1))
    assert_receive {:retired, [%Entry{stream: :telemetry, sequence: 1}]}, 2_000
    assert Owner.pending(owner) == []
    refute_receive {:retired, _entries}, 50
    assert Process.alive?(client)
  end

  # --- durable admission helpers (real producers, real owner) ---

  defp start_owner!(root) do
    test = self()

    start_supervised!(
      {Owner,
       root: root,
       identity: fn -> {:ok, durable_identity()} end,
       streams: [:telemetry, :health, :desired_state_ack, :checkpoint],
       max_entries: 50,
       max_bytes: 1_000_000,
       segment_max_bytes: 65_536,
       on_acknowledge: fn entries -> send(test, {:retired, entries}) end},
      id: {Owner, System.unique_integer([:positive])}
    )
  end

  defp admit_data_set(owner, counter) do
    data_set =
      struct(DataSet,
        counter: counter,
        ref: "dataset-ref-#{counter}",
        boat_identifier: "logger-e2e",
        data_points: [
          struct(DataPoint,
            timestamp: %Google.Protobuf.Timestamp{seconds: 1_723_456_789 + counter, nanos: 123_000_000},
            hw_id: 42,
            sample: {:speed, %SpeedSample{speed_cm_s: 500 + counter}}
          )
        ]
      )

    DataSetProducer.admit(DataSet.encode(data_set),
      outbox: owner,
      source_id: "legacy/datasets/dataset-ref-#{counter}"
    )
  end

  defp admit_health_event(owner, occurred_at_ms) do
    HealthEventProducer.admit(
      %{
        event_type: :receipt_progress,
        occurred_at_ms: occurred_at_ms,
        firmware_version: "0.7.0-rc.1",
        firmware_git_sha: String.duplicate("a", 40),
        target: %{
          credential_epoch: @credential_epoch,
          desired_generation: 42,
          manifest_hash: @manifest_hash
        },
        stream: :telemetry,
        cumulative_sequence: 91
      },
      outbox: owner
    )
  end

  defp admit_desired_state_ack(owner, generation) do
    DesiredStateAckProducer.admit(
      Map.merge(durable_identity(), %{
        boot_id: @boot_id,
        generation: generation,
        manifest_hash: @manifest_hash,
        status: :effective
      }),
      outbox: owner
    )
  end

  defp checkpoint_delivery(sequence, parent_hash) do
    assert {:ok, content} =
             Checkpoint.encode_content(:calibration, 1, %{
               "awa_estimators" => [],
               "aws_estimators" => [],
               "prev_applied" => [],
               "seq" => 0,
               "stw_estimators" => []
             })

    assert {:ok, content_hash} = Checkpoint.content_hash(:calibration, 1, content)

    attrs = %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      sequence: sequence,
      kind: :calibration,
      schema_version: 1,
      source_generation: 42,
      parent_hash: parent_hash,
      content_hash: content_hash
    }

    assert {:ok, checkpoint_hash} = Checkpoint.hash(attrs)

    submission =
      attrs
      |> Map.put(:checkpoint_hash, checkpoint_hash)
      |> Map.put(:content, content)

    assert {:ok, payload} = Messages.encode(:checkpoint_submission, submission)
    {:ok, %{payload: payload, payload_hash: checkpoint_hash}}
  end

  defp durable_identity do
    %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch
    }
  end

  defp pending_sequences(owner, stream) do
    owner |> Owner.pending(stream: stream) |> Enum.map(& &1.sequence)
  end

  # --- transport helpers (fake backend played by this test process) ---

  defp start_client!(ctx, owner) do
    id = {:e2e_channel_client, System.unique_integer([:positive])}
    holder_id = {:e2e_session_holder, System.unique_integer([:positive])}
    {:ok, holder} = start_supervised({SessionHolder, name: nil}, id: holder_id)
    topic = "device:" <> ctx.identity.fingerprint

    client =
      start_supervised!(
        {ChannelClient,
         name: nil,
         auto_connect?: true,
         test_mode?: true,
         url: "wss://test.local/device_socket/websocket",
         session_holder: holder,
         boot_provisioner: {FakeBootstrap, :e2e_bootstrap},
         backoff: [base_ms: 10, cap_ms: 10, jitter: 0],
         desired_state_identity: fn -> {:ok, control_identity()} end,
         desired_state_compatibility: fn ->
           %{
             firmware_version: "0.7.0",
             firmware_git_sha: "0123abc",
             capabilities: []
           }
         end,
         desired_state_status: fn -> %{active: nil} end,
         receipt_evidence: fn _class -> :ok end,
         outbox: owner,
         keystore_opts: [base_path: ctx.base]},
        id: id
      )

    {client, topic, holder}
  end

  # Full session establishment: socket join, authenticated handshake, control
  # negotiation, readiness. Used for the first connect AND every reconnect.
  defp establish_session(client, topic, ctx) do
    connect_and_assert_join(client, ^topic, %{}, :ok)
    server_session = complete_handshake(client, topic, ctx)
    assert_push(^topic, "wifi_status", _status, _ref, 2_000)
    assert {:ok, server_control} = Control.new(:server, server_session)
    accept_control(client, topic, server_control)
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
    assert_push(^topic, "handshake_init", %{"init" => init_b64}, _ref, 2_000)
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

  defp push_receipt(client, topic, server_control, receipt) do
    assert {:ok, receipt_hash} = Receipt.hash(receipt)
    push_control(client, topic, server_control, :delivery_receipt, Map.put(receipt, :receipt_hash, receipt_hash))
  end

  defp receive_control(topic, server_control) do
    assert_push(^topic, "control_v1", carrier, _ref, 2_000)
    assert {:ok, frame} = Control.decode_carrier(carrier)
    assert {:ok, type, bytes, server_control} = Control.open(server_control, frame)
    assert {:ok, attrs} = Messages.decode(type, bytes)
    {server_control, %{type: type, attrs: attrs}}
  end

  defp receive_frames(topic, server_control, count) do
    Enum.map_reduce(1..count, server_control, fn _index, control ->
      {control, frame} = receive_control(topic, control)
      {frame, control}
    end)
  end

  # --- receipt / frame shape helpers ---

  # The exact seven-field authenticated receipt echoed by an honest server for
  # one durably admitted entry (from the producer's admission receipt).
  defp receipt_for(admission_receipt) do
    %{
      stream: admission_receipt.stream,
      device_id: admission_receipt.device_id,
      credential_epoch: admission_receipt.credential_epoch,
      storage_epoch: admission_receipt.storage_epoch,
      sequence: admission_receipt.sequence,
      payload_hash: admission_receipt.payload_hash,
      cumulative_sequence: 0
    }
  end

  defp frame_identity(%{type: :checkpoint_submission, attrs: attrs}),
    do: {:checkpoint_submission, :checkpoint, attrs.sequence}

  defp frame_identity(%{type: type, attrs: attrs}), do: {type, attrs.stream, attrs.sequence}

  defp submission_hashes(frames) do
    for %{type: type, attrs: attrs} <- frames,
        type in [:delivery_submission, :checkpoint_submission],
        into: %{} do
      case type do
        :delivery_submission -> {{attrs.stream, attrs.sequence}, attrs.payload_hash}
        :checkpoint_submission -> {{:checkpoint, attrs.sequence}, attrs.checkpoint_hash}
      end
    end
  end

  defp payload_bytes(frames) do
    for %{type: :delivery_payload, attrs: attrs} <- frames, into: %{} do
      {{attrs.stream, attrs.sequence}, attrs.payload}
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

  defp eventually(assertion, attempts \\ 100) when attempts > 0 do
    if assertion.() do
      true
    else
      if attempts == 1 do
        assertion.()
      else
        Process.sleep(10)
        eventually(assertion, attempts - 1)
      end
    end
  end
end
