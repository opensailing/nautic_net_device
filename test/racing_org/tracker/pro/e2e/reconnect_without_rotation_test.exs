defmodule RacingOrg.Tracker.Pro.E2E.ReconnectWithoutRotationTest do
  @moduledoc """
  Chained end-to-end reconnect-without-rotation scenario: a device with a live
  secure-transport session and pending durable outbox entries loses the socket
  and reconnects under the SAME credential epoch (no rotation).

  The chain, in order, on one device incarnation:

    1. First connection: join, secure-transport handshake at the unchanged
       credential epoch, session published (generation 1), control_v1
       accept/readiness, and the pre-enqueued durable outbox entries dispatched
       through the REAL Outbox.Owner -> Submission.Planner -> sealed control
       frame path (frozen submission identity, then payload bytes).
    2. Receipt discipline before the drop: fully transmitted bytes retire
       nothing — every entry stays pending until the server's authenticated
       `delivery_receipt` retires entry #1, exactly once; a re-sent receipt is
       accepted idempotently and retires nothing more.
    3. The socket drops (server-side `:network_lost`): the live session clears
       and the SessionHolder generation fence advances.
    4. Reconnect WITHOUT rotation: the client reconnects on its jittered
       backoff, re-handshakes at the SAME credential epoch, and the replacement
       session publishes under an advanced generation with a fresh session id.
    5. Exactly-once re-delivery by receipt: after the new session's control
       accept/readiness, ONLY the still-unreceipted entry #2 is retransmitted
       (the receipted entry #1 is never re-sent); the receipt for #2 retires it
       exactly once, a duplicate receipt is idempotent, and a dispatch kick
       after full retirement transmits nothing. A receipt sealed under the
       dropped session's keys can never retire the re-delivered entry (second
       test case).
    6. Throughout: desired-state authority carries over unchanged — the
       ISOLATED OperationalGate's published lease term is identical before and
       after the reconnect, still open and operational for the same
       credential/storage epochs, output still permitted, and the authority
       marker intact.

  Process boundaries: everything device-side is REAL and chained in-process —
  the ChannelClient Slipstream state machine (test-mode transport), the
  SessionHolder generation fencing, the on-disk KeyStore and Ed25519 secure
  session handshake crypto, a REAL DurableDelivery.Outbox.Owner + Store
  persisting to a per-test tmp root (retirement only via
  `Owner.acknowledge/3`), the production Submission.Planner, and a live
  OperationalGate GenServer under an ISOLATED persistent_term key (never the
  default key). The chain stops at three seams: the backend is the
  Slipstream.SocketTest conceptual server driven by this test process (no real
  websocket/Phoenix/network — server-side delivery receipts are produced here
  with the same Receipt/Messages/Control contract code the real backend
  speaks); the OperationalGate's production controller (DesiredState.Manager)
  is not started, so desired-state authority carry-over is asserted as
  lease-term identity across the reconnect with this test process as the gate
  controller rather than through Manager activation; and the WiFi/firmware
  collaborators are the inert host-test defaults.
  """

  use Slipstream.SocketTest

  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient
  alias RacingOrg.Tracker.Pro.SecureTransport.Handshake
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: DesiredStateV1
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Control, Messages, Negotiation, Receipt}

  @logical_device_id <<0xD1::128>>
  @boot_id <<0xD2::128>>
  @storage_epoch <<0xD3::128>>
  # The credential epoch NEVER changes in this scenario — both handshakes and
  # the durable identity are bound to this one value.
  @control_epoch 0

  # Per-test KeyStore in a temp dir + a pinned server keypair (the
  # channel_client_test harness pattern), plus an OperationalGate on an
  # ISOLATED term_key — never the default persistent_term key (shared test VM).
  setup do
    base = Path.join(System.tmp_dir!(), "reconnect_no_rotation_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    {:ok, identity} = KeyStore.load_or_generate(base_path: base)

    srv_seed = :binary.copy(<<0xB2>>, 32)
    srv_pub = Primitives.ed25519_public_from_secret(srv_seed)
    prev = Application.get_env(:racing_org_tracker_pro, ServerIdentity)
    Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: srv_pub)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:racing_org_tracker_pro, ServerIdentity)
        prev -> Application.put_env(:racing_org_tracker_pro, ServerIdentity, prev)
      end
    end)

    term_key = {__MODULE__, make_ref()}
    {:ok, gate} = OperationalGate.start_link(name: nil, term_key: term_key, controller: self())

    on_exit(fn ->
      stop_if_alive(gate)
      OperationalGate.clear_authority_established(term_key)
      :persistent_term.erase(term_key)
    end)

    %{
      base: base,
      identity: identity,
      srv_pub: srv_pub,
      srv_priv: srv_seed,
      gate: gate,
      term_key: term_key
    }
  end

  test "reconnecting without rotation re-handshakes on the same epoch, advances the generation, re-delivers only unreceipted entries exactly once, and leaves desired-state authority untouched",
       ctx do
    {:ok, holder} = start_supervised({SessionHolder, name: nil})
    owner = start_outbox_owner(ctx.base)

    # Two durable entries are pending BEFORE the first connection. The enqueue
    # receipts are the exact durable identities the server must echo to retire.
    payload_one = "durable-health-1"
    payload_two = "durable-health-2"
    assert {:ok, receipt_one} = Owner.enqueue(owner, :health, payload_one)
    assert {:ok, receipt_two} = Owner.enqueue(owner, :health, payload_two)
    assert receipt_one.sequence == 1
    assert receipt_two.sequence == 2

    # Desired-state authority: the isolated gate is opened by its controller
    # (this test process) for the SAME credential/storage epochs the session
    # uses. Its published lease is the carry-over baseline for the reconnect.
    assert :ok = OperationalGate.record_authority_established(ctx.term_key)

    gate_binding = %{
      credential_epoch: @control_epoch,
      storage_epoch: @storage_epoch,
      generation: 1,
      manifest_hash: :binary.copy(<<0x5A>>, 32)
    }

    assert :ok =
             OperationalGate.open_owned(
               ctx.gate,
               controller_capability(ctx.gate),
               self(),
               [],
               gate_binding,
               authority_bindings()
             )

    assert OperationalGate.open?(ctx.term_key)
    assert OperationalGate.operational?(@control_epoch, @storage_epoch, ctx.term_key)
    lease_before_drop = :persistent_term.get(ctx.term_key)

    topic = "device:" <> ctx.identity.fingerprint
    client = start_reconnect_client(ctx, holder, owner)
    connect_and_assert_join(client, ^topic, %{}, :ok)

    # -- Phase 1: first handshake at the unchanged credential epoch; the
    # session publishes under generation 1.
    first_server_session = complete_handshake(client, topic, ctx)
    assert_push(^topic, "wifi_status", _initial_status, _ref, 2_000)
    assert eventually(fn -> SessionHolder.live?(holder) end)
    assert {:ok, first_session} = SessionHolder.get_current_session(holder)
    assert first_session.session_id == first_server_session.session_id
    assert first_session.credential_epoch == @control_epoch
    assert first_session.generation == 1

    assert {:ok, server_control} = Control.new(:server, first_server_session)
    {server_control, readiness} = accept_control(client, topic, server_control)
    assert readiness.device_id == @logical_device_id
    assert readiness.credential_epoch == @control_epoch
    assert readiness.boot_id == @boot_id
    assert readiness.storage_epoch == @storage_epoch

    # Readiness dispatches BOTH pending entries in FIFO order: the frozen
    # submission identity first, then the payload bytes, per entry.
    server_control = receive_delivery(topic, server_control, 1, payload_one)
    server_control = receive_delivery(topic, server_control, 2, payload_two)

    # -- Phase 2: bytes on the wire are NOT retirement — with no receipt, both
    # entries are still pending in the durable outbox.
    assert pending_sequences(owner) == [1, 2]

    # The server's authenticated receipt retires entry #1 — exactly once.
    server_control = push_delivery_receipt(client, topic, server_control, receipt_one)
    assert_receive {:retired, [health: 1]}, 2_000
    assert_receive {:receipt_evidence, :control}, 2_000
    assert pending_sequences(owner) == [2]

    # A re-sent receipt (fresh frame, same durable identity) is accepted
    # idempotently: the client still records round-trip evidence, but nothing
    # more is retired.
    server_control = push_delivery_receipt(client, topic, server_control, receipt_one)
    assert_receive {:receipt_evidence, :control}, 2_000
    refute_received {:retired, _sequences}
    assert pending_sequences(owner) == [2]
    _consumed_first_connection_control = server_control

    # -- Phase 3: the socket drops. The live session clears and the holder
    # generation fence advances so nothing stale can ever act again.
    disconnect(client, :network_lost)
    assert eventually(fn -> not SessionHolder.live?(holder) end)
    assert SessionHolder.generation(holder) == first_session.generation + 1

    # -- Phase 4: reconnect WITHOUT rotation — the client reconnects on its
    # backoff and re-handshakes at the SAME credential epoch.
    connect_and_assert_join(client, ^topic, %{}, :ok)
    second_server_session = complete_handshake(client, topic, ctx)
    assert_push(^topic, "wifi_status", _reconnect_status, _ref, 2_000)
    assert eventually(fn -> SessionHolder.live?(holder) end)
    assert {:ok, second_session} = SessionHolder.get_current_session(holder)
    assert second_session.session_id == second_server_session.session_id
    refute second_session.session_id == first_session.session_id
    assert second_session.credential_epoch == @control_epoch
    # The equal-epoch re-handshake adds no epoch fence: the disconnect clear
    # advanced the generation once (+1) and the replacement publication once
    # more (+1) — the session generation strictly advances across a reconnect.
    assert second_session.generation == first_session.generation + 2

    assert {:ok, reconnect_control} = Control.new(:server, second_server_session)
    {reconnect_control, reconnect_readiness} = accept_control(client, topic, reconnect_control)
    assert reconnect_readiness.credential_epoch == @control_epoch
    assert reconnect_readiness.device_id == @logical_device_id

    # -- Phase 5: ONLY the still-unreceipted entry #2 is re-delivered; the
    # receipted entry #1 stays retired and is never retransmitted.
    reconnect_control = receive_delivery(topic, reconnect_control, 2, payload_two)
    refute_push(^topic, "control_v1", _unexpected_redelivery, 50)
    assert pending_sequences(owner) == [2]

    # The receipt for entry #2 retires it exactly once...
    reconnect_control = push_delivery_receipt(client, topic, reconnect_control, receipt_two)
    assert_receive {:retired, [health: 2]}, 2_000
    assert_receive {:receipt_evidence, :control}, 2_000
    assert pending_sequences(owner) == []

    # ...and its duplicate is idempotent: accepted, nothing re-retired.
    _reconnect_control = push_delivery_receipt(client, topic, reconnect_control, receipt_two)
    assert_receive {:receipt_evidence, :control}, 2_000
    refute_received {:retired, _sequences}
    assert pending_sequences(owner) == []

    # A dispatch kick after full retirement transmits nothing.
    assert :ok = ChannelClient.dispatch_durable_deliveries(client)
    refute_push(^topic, "control_v1", _post_retirement_frame, 50)

    # -- Phase 6: desired-state authority carried over UNCHANGED across the
    # reconnect — the exact published lease term, still open and operational
    # for the same epochs, output permitted, authority marker intact.
    assert :persistent_term.get(ctx.term_key) == lease_before_drop
    assert OperationalGate.open?(ctx.term_key)
    assert OperationalGate.operational?(@control_epoch, @storage_epoch, ctx.term_key)
    assert OperationalGate.output_permitted?(ctx.term_key)
    assert OperationalGate.authority_established?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == {:open, gate_binding}
    assert Process.alive?(client)
    assert SessionHolder.live?(holder)
  end

  test "a delivery receipt sealed under the dropped session cannot retire the re-delivered entry after an equal-epoch reconnect",
       ctx do
    {:ok, holder} = start_supervised({SessionHolder, name: nil})
    owner = start_outbox_owner(ctx.base)

    payload = "durable-health-fenced-receipt"
    assert {:ok, receipt} = Owner.enqueue(owner, :health, payload)
    assert receipt.sequence == 1

    topic = "device:" <> ctx.identity.fingerprint
    client = start_reconnect_client(ctx, holder, owner)
    connect_and_assert_join(client, ^topic, %{}, :ok)

    # First connection transmits the entry but no receipt ever arrives.
    first_server_session = complete_handshake(client, topic, ctx)
    assert_push(^topic, "wifi_status", _initial_status, _ref, 2_000)
    assert eventually(fn -> SessionHolder.live?(holder) end)
    assert {:ok, stale_control} = Control.new(:server, first_server_session)
    {stale_control, _readiness} = accept_control(client, topic, stale_control)
    stale_control = receive_delivery(topic, stale_control, 1, payload)
    assert pending_sequences(owner) == [1]

    disconnect(client, :network_lost)
    assert eventually(fn -> not SessionHolder.live?(holder) end)

    # Equal-epoch reconnect: the entry is re-delivered under the new session.
    connect_and_assert_join(client, ^topic, %{}, :ok)
    second_server_session = complete_handshake(client, topic, ctx)
    assert_push(^topic, "wifi_status", _reconnect_status, _ref, 2_000)
    assert eventually(fn -> SessionHolder.live?(holder) end)
    assert {:ok, live_control} = Control.new(:server, second_server_session)
    {live_control, _reconnect_readiness} = accept_control(client, topic, live_control)
    live_control = receive_delivery(topic, live_control, 1, payload)

    # A receipt sealed with the DROPPED session's control keys is fenced: the
    # replacement session cannot authenticate it, so nothing is retired and no
    # round-trip evidence is recorded. (:sys.get_state is a serialization
    # barrier proving the client already processed the stale frame.)
    _stale_control = push_delivery_receipt(client, topic, stale_control, receipt)
    _barrier = :sys.get_state(client)
    refute_received {:retired, _sequences}
    refute_received {:receipt_evidence, _class}
    assert pending_sequences(owner) == [1]
    assert Process.alive?(client)

    # Only the live session's authenticated receipt retires — exactly once.
    _live_control = push_delivery_receipt(client, topic, live_control, receipt)
    assert_receive {:retired, [health: 1]}, 2_000
    assert_receive {:receipt_evidence, :control}, 2_000
    assert pending_sequences(owner) == []
  end

  # --- harness helpers (channel_client_test / generic delivery patterns) ---

  # A REAL durable outbox owner rooted in the per-test tmp dir, bound to the
  # exact durable identity the control plane negotiates. `on_acknowledge` fires
  # only when entries are actually removed, which is the exactly-once
  # observable the receipt assertions use.
  defp start_outbox_owner(base) do
    test_pid = self()

    start_supervised!(
      {Owner,
       name: nil,
       root: Path.join(base, "outbox"),
       identity: fn ->
         {:ok,
          %{
            device_id: @logical_device_id,
            credential_epoch: @control_epoch,
            storage_epoch: @storage_epoch
          }}
       end,
       on_acknowledge: fn entries ->
         send(test_pid, {:retired, Enum.map(entries, &{&1.stream, &1.sequence})})
       end}
    )
  end

  defp start_reconnect_client(ctx, holder, owner) do
    test_pid = self()

    start_supervised!({
      ChannelClient,
      # A tight deterministic backoff so the drop is followed by a prompt
      # reconnect attempt the conceptual server can accept.
      # The REAL outbox owner: pending/planner/acknowledge all run the
      # production durable delivery path against it.
      name: nil,
      auto_connect?: true,
      test_mode?: true,
      url: "wss://test.local/device_socket/websocket",
      session_holder: holder,
      firmware_validator: fn -> :ok end,
      backoff: [base_ms: 10, cap_ms: 10, jitter: 0],
      outbox: owner,
      receipt_evidence: fn class -> send(test_pid, {:receipt_evidence, class}) end,
      desired_state_identity: fn -> {:ok, control_identity()} end,
      desired_state_compatibility: fn ->
        %{
          firmware_version: "0.7.0",
          firmware_git_sha: "0123abc",
          capabilities: Enum.map(DesiredStateV1.capabilities(), fn {name, _id, version} -> {name, version} end)
        }
      end,
      desired_state_status: fn -> %{active: nil} end,
      keystore_opts: [base_path: ctx.base]
    })
  end

  # The conceptual server builds a real HELLO at the UNCHANGED credential
  # epoch, verifies the client's INIT, and confirms with handshake_ok.
  defp complete_handshake(client, topic, ctx) do
    {:ok, hello_wire, responder_state} =
      Handshake.responder_hello(
        server_identity_private: ctx.srv_priv,
        server_identity_public: ctx.srv_pub,
        device_identity_public: ctx.identity.public_key,
        epoch: @control_epoch
      )

    push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
    assert_push(^topic, "handshake_init", %{"init" => init_b64}, _ref, 2_000)
    {:ok, init_wire} = Base.decode64(init_b64)
    {:ok, server_session} = Handshake.responder_finalize(responder_state, init_wire)

    push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})
    server_session
  end

  defp accept_control(client, topic, server_control) do
    {:ok, selection} = Negotiation.select(%{control_versions: [1], desired_state_versions: [1]})

    attrs = %{
      device_id: @logical_device_id,
      credential_epoch: @control_epoch,
      selected_control_version: selection.selected_control_version,
      selected_desired_version: selection.selected_desired_version,
      offer_hash: selection.offer_hash
    }

    {:ok, bytes} = Messages.encode(:control_accept, attrs)
    {:ok, frame, server_control} = Control.seal(server_control, :control_accept, bytes)
    push(client, topic, "control_v1", Control.encode_carrier(frame))

    {server_control, readiness} = receive_control(topic, server_control)
    assert readiness.type == :readiness
    {server_control, readiness.attrs}
  end

  defp receive_control(topic, server_control) do
    assert_push(^topic, "control_v1", carrier, _ref, 2_000)
    assert {:ok, frame} = Control.decode_carrier(carrier)
    assert {:ok, type, bytes, server_control} = Control.open(server_control, frame)
    assert {:ok, attrs} = Messages.decode(type, bytes)
    {server_control, %{type: type, attrs: attrs}}
  end

  # One dispatched generic delivery: the frozen submission identity frame, then
  # the payload frame whose bytes hash to the durable payload hash.
  defp receive_delivery(topic, server_control, sequence, payload) do
    {server_control, submission} = receive_control(topic, server_control)
    assert submission.type == :delivery_submission
    assert submission.attrs.stream == :health
    assert submission.attrs.sequence == sequence
    assert submission.attrs.device_id == @logical_device_id
    assert submission.attrs.credential_epoch == @control_epoch
    assert submission.attrs.storage_epoch == @storage_epoch
    assert submission.attrs.payload_hash == :crypto.hash(:sha256, payload)

    {server_control, delivery_payload} = receive_control(topic, server_control)
    assert delivery_payload.type == :delivery_payload
    assert delivery_payload.attrs.stream == :health
    assert delivery_payload.attrs.sequence == sequence
    assert delivery_payload.attrs.payload == payload
    assert :crypto.hash(:sha256, delivery_payload.attrs.payload) == delivery_payload.attrs.payload_hash

    server_control
  end

  # Seals a fresh authenticated delivery_receipt frame (new control counter)
  # carrying the exact durable receipt identity — the way a server re-send
  # looks on the wire.
  defp push_delivery_receipt(client, topic, server_control, receipt) do
    assert {:ok, receipt_hash} = Receipt.hash(receipt)
    assert {:ok, bytes} = Messages.encode(:delivery_receipt, Map.put(receipt, :receipt_hash, receipt_hash))
    assert {:ok, frame, server_control} = Control.seal(server_control, :delivery_receipt, bytes)
    push(client, topic, "control_v1", Control.encode_carrier(frame))
    server_control
  end

  defp pending_sequences(owner) do
    assert entries = Owner.pending(owner)
    assert is_list(entries)
    Enum.map(entries, & &1.sequence)
  end

  defp control_identity do
    %{
      device_id: @logical_device_id,
      credential_epoch: @control_epoch,
      boot_id: @boot_id,
      storage_epoch: @storage_epoch
    }
  end

  defp controller_capability(gate) do
    gate |> :sys.get_state() |> Map.fetch!(:controller_capability)
  end

  defp authority_bindings do
    Map.new(DesiredStateV1.sections(), &{&1, {self(), self()}})
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() ->
        true

      retries <= 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, retries - 1)
    end
  end
end
