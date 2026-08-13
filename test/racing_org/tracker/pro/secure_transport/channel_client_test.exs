defmodule RacingOrg.Tracker.Pro.SecureTransport.ChannelClientTest do
  @moduledoc """
  Tests for the gating logic (safe-to-start-idle) and a socket-layer smoke test
  using `Slipstream.SocketTest` (a conceptual server, no real websocket): the
  client connects, joins `device:<fp>`, and on a server `handshake_hello` push
  pushes a `handshake_init` back.
  """
  use Slipstream.SocketTest

  alias RacingOrg.Tracker.Pro.RecoveryV2TestSupport, as: RecoverySupport
  alias RacingOrg.Tracker.Pro.SecureTransport, as: SecureTransport
  alias RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateMachine
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateStore
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient
  alias RacingOrg.Tracker.Pro.SecureTransport.Handshake
  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.Session
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: DesiredStateV1
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Control, Messages, Negotiation}

  @serial "000000001234abcd"
  @logical_device_id <<0xD1::128>>
  @boot_id <<0xD2::128>>
  @storage_epoch <<0xD3::128>>
  @control_epoch 0

  # A per-test KeyStore in a temp dir + a pinned server keypair.
  setup do
    base = Path.join(System.tmp_dir!(), "cc_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    {:ok, identity} = KeyStore.load_or_generate(base_path: base)

    {srv_pub, srv_priv} = identity(<<0xB2>>)
    prev = Application.get_env(:racing_org_tracker_pro, ServerIdentity)
    Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: srv_pub)
    on_exit(fn -> restore_env(ServerIdentity, prev) end)

    %{base: base, identity: identity, srv_pub: srv_pub, srv_priv: srv_priv}
  end

  defp identity(byte) do
    seed = :binary.copy(byte, 32)
    {Primitives.ed25519_public_from_secret(seed), seed}
  end

  defp restore_env(key, nil), do: Application.delete_env(:racing_org_tracker_pro, key)
  defp restore_env(key, prev), do: Application.put_env(:racing_org_tracker_pro, key, prev)

  defp registration_authority(%{request: request, receipt: receipt}) do
    %{
      kind: :registration,
      public_key: request.candidate_public_key,
      client_nonce: request.client_nonce,
      receipt: receipt.envelope,
      logical_device_id: receipt.payload.logical_device_id,
      credential_epoch: receipt.payload.credential_epoch
    }
  end

  defp recovery_authority(identity, challenge, lifecycle) do
    %{
      kind: :recovery,
      public_key: IdentityProvider.public_key(identity),
      challenge_client_nonce: challenge.request.client_nonce,
      challenge_receipt: challenge.receipt.envelope,
      commit_signing_bytes_hash: Primitives.sha256(lifecycle.request.assertion),
      lifecycle_receipt: lifecycle.receipt.envelope,
      logical_device_id: lifecycle.receipt.payload.logical_device_id,
      credential_epoch: lifecycle.receipt.payload.credential_epoch
    }
  end

  defp bootstrap_opts(base, extra \\ []) do
    Keyword.merge(
      [
        keystore_opts: [base_path: base],
        state_store_opts: [base_path: base],
        hardware_identity_fun: fn -> {:ok, @serial} end,
        server_public_key: RecoverySupport.server_public_key()
      ],
      extra
    )
  end

  defp start_boot_provisioner(base, extra \\ []) do
    opts = bootstrap_opts(base, extra)
    start_supervised!({BootProvisioner, Keyword.put(opts, :name, nil)})
  end

  defp complete_handshake(client, topic, ctx, epoch \\ 0) do
    {:ok, hello_wire, responder_state} =
      Handshake.responder_hello(
        server_identity_private: ctx.srv_priv,
        server_identity_public: ctx.srv_pub,
        device_identity_public: ctx.identity.public_key,
        epoch: epoch
      )

    push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
    assert_push(^topic, "handshake_init", %{"init" => init_b64})
    {:ok, init_wire} = Base.decode64(init_b64)
    {:ok, server_session} = Handshake.responder_finalize(responder_state, init_wire)

    push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})
    server_session
  end

  # --- gating: safe to start idle, never connects when not configured ---

  describe "gating / connectable?" do
    test "host/unclaimed device is NOT connectable (stays idle)", %{base: base} do
      # On host the :target is :host and there is no claim marker -> not connectable.
      refute ChannelClient.connectable?(keystore_opts: [base_path: base])
    end

    test "starts and stays idle when not auto-connecting (no crash loop)", %{base: base} do
      pid =
        start_supervised!({ChannelClient, name: nil, auto_connect?: false, keystore_opts: [base_path: base]})

      assert Process.alive?(pid)
      # Give it a beat; it must NOT crash or busy-loop.
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "idle client polls :recheck and reschedules without crashing", %{base: base} do
      # Provisioning can complete after boot (BootProvisioner is async), so an idle
      # client must keep re-checking connectable?/1 rather than idle forever. With a
      # tiny recheck interval, several timers fire; auto_connect? stays false so it
      # reschedules each time and never connects/crashes.
      pid =
        start_supervised!(
          {ChannelClient, name: nil, auto_connect?: false, recheck_ms: 15, keystore_opts: [base_path: base]}
        )

      Process.sleep(80)
      assert Process.alive?(pid)
    end

    test "only the active key with verified authority is connectable; a staged candidate is never used", ctx do
      previous_target = Application.get_env(:racing_org_tracker_pro, :target)
      Application.put_env(:racing_org_tracker_pro, :target, :racing_org_rpi3)
      on_exit(fn -> Application.put_env(:racing_org_tracker_pro, :target, previous_target) end)

      {:ok, active_registration} = RecoverySupport.registration_result(ctx.identity, @serial)

      BootstrapStateStore.save!(
        %BootstrapState{
          phase: :registered,
          hardware_identity_digest:
            BootstrapStateMachine.hardware_identity_digest("raspberry_pi_soc_serial_v1", @serial),
          authority: registration_authority(active_registration)
        },
        base_path: ctx.base
      )

      channel_opts = [
        keystore_opts: [base_path: ctx.base],
        bootstrap_opts: bootstrap_opts(ctx.base)
      ]

      assert ChannelClient.connectable?(channel_opts)

      {:ok, candidate} =
        KeyStore.stage_candidate(
          base_path: ctx.base,
          seed_generator: fn -> :binary.copy(<<0xC4>>, 32) end
        )

      {:ok, candidate_registration} = RecoverySupport.registration_result(candidate, @serial)

      BootstrapStateStore.save!(
        %BootstrapState{
          phase: :registered,
          hardware_identity_digest:
            BootstrapStateMachine.hardware_identity_digest("raspberry_pi_soc_serial_v1", @serial),
          authority: registration_authority(candidate_registration),
          recovery: %{
            public_key: IdentityProvider.public_key(candidate),
            source: :staged,
            challenge_client_nonce: nil,
            challenge_receipt: nil,
            classification_receipt: nil,
            commit_uncertain: false
          }
        },
        base_path: ctx.base
      )

      refute ChannelClient.connectable?(channel_opts)
    end
  end

  # --- control_v1 capability offer ---

  describe "control_v1 connection offer" do
    test "advertises the complete offer and retains its exact canonical selection", ctx do
      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           keystore_opts: [base_path: ctx.base]}
        )

      assert eventually(fn -> not is_nil(:sys.get_state(client).channel_config) end)
      socket = :sys.get_state(client)
      params = socket.channel_config.uri.query |> URI.decode_query()

      assert params["control_versions"] == "1"
      assert params["desired_state_versions"] == "1"
      assert params["fingerprint"] == ctx.identity.fingerprint

      offer = %{control_versions: [1], desired_state_versions: [1]}
      assert {:ok, expected_selection} = Negotiation.select(offer)
      assert socket.assigns.control_offer == offer
      assert socket.assigns.control_selection == expected_selection
    end

    test "supports explicit legacy negotiation without either capability parameter", ctx do
      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           control_offer: :legacy,
           url: "wss://test.local/device_socket/websocket",
           keystore_opts: [base_path: ctx.base]}
        )

      assert eventually(fn -> not is_nil(:sys.get_state(client).channel_config) end)
      socket = :sys.get_state(client)
      params = socket.channel_config.uri.query |> URI.decode_query()

      assert params == %{"fingerprint" => ctx.identity.fingerprint}
      assert socket.assigns.control_offer == :legacy
      assert socket.assigns.control_selection == nil
    end
  end

  # --- authenticated control_v1 carrier ---

  describe "control_v1 carrier (SocketTest)" do
    test "verifies control_accept, sends readiness on its originating topic, and dispatches durable deliveries", ctx do
      {client, holder, topic} = start_control_client(ctx)
      server_session = complete_handshake(client, topic, ctx, @control_epoch)
      assert_push(^topic, "wifi_status", _wifi_status)
      assert eventually(fn -> SessionHolder.live?(holder) end)
      assert {:ok, server_control} = Control.new(:server, server_session)

      origin_topic = topic
      wrong_topic = topic <> ":wrong"
      {server_control, accept_frame} = push_control_accept(client, wrong_topic, server_control)

      refute_push(^wrong_topic, "control_v1", _readiness, 50)
      refute_receive {:delivery_pending, _opts}

      push(client, origin_topic, "control_v1", Control.encode_carrier(accept_frame))
      assert_push(^origin_topic, "control_v1", readiness_carrier)
      assert {:ok, readiness_frame} = Control.decode_carrier(readiness_carrier)
      assert {:ok, :readiness, readiness_bytes, server_control} = Control.open(server_control, readiness_frame)
      assert {:ok, readiness} = Messages.decode(:readiness, readiness_bytes)

      assert readiness.device_id == @logical_device_id
      assert readiness.credential_epoch == @control_epoch
      assert readiness.boot_id == @boot_id
      assert readiness.storage_epoch == @storage_epoch
      assert readiness.selected_control_version == 1
      assert readiness.selected_desired_version == 1
      assert readiness.firmware_version == "0.7.0"
      assert readiness.firmware_git_sha == "0123abc"
      assert readiness.effective == nil
      assert :sys.get_state(client).assigns.control_topic == origin_topic
      assert_receive {:delivery_pending, _opts}

      push(client, origin_topic, "control_v1", Control.encode_carrier(accept_frame))
      refute_push(^origin_topic, "control_v1", _duplicate_readiness, 50)
    end

    test "does not accept control or send readiness before session publication", ctx do
      {client, _holder, topic} = start_control_client(ctx)

      {:ok, hello_wire, responder_state} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: @control_epoch
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)
      {:ok, server_session} = Handshake.responder_finalize(responder_state, init_wire)
      assert {:ok, server_control} = Control.new(:server, server_session)
      {server_control, accept_frame} = push_control_accept(client, topic, server_control)

      refute_push(^topic, "control_v1", _readiness, 50)
      refute_receive {:delivery_pending, _opts}

      push(client, topic, "handshake_ok", %{
        "session_id" => Base.encode64(server_session.session_id)
      })

      assert_push(^topic, "wifi_status", _wifi_status)
      push(client, topic, "control_v1", Control.encode_carrier(accept_frame))
      assert_push(^topic, "control_v1", readiness_carrier)
      assert {:ok, readiness_frame} = Control.decode_carrier(readiness_carrier)

      assert {:ok, :readiness, _readiness_bytes, _server_control} =
               Control.open(server_control, readiness_frame)
    end

    test "fails closed on accept binding mismatches, malformed carriers, and valid delivery messages", ctx do
      {client, _holder, topic} = start_control_client(ctx)
      server_session = complete_handshake(client, topic, ctx, @control_epoch)
      assert_push(^topic, "wifi_status", _wifi_status)
      assert {:ok, server_control} = Control.new(:server, server_session)

      push(client, topic, "control_v1", %{"frame" => "not base64"})
      refute_push(^topic, "control_v1", _readiness, 20)

      mismatches = [
        %{device_id: <<0xEE::128>>},
        %{credential_epoch: 8},
        %{offer_hash: :binary.copy(<<0xEE>>, 32)}
      ]

      server_control =
        Enum.reduce(mismatches, server_control, fn mismatch, control ->
          {control, _frame} = push_control_accept(client, topic, control, mismatch)
          refute_push(^topic, "control_v1", _readiness, 20)
          control
        end)

      secret_delivery =
        control_identity(@control_epoch)
        |> Map.merge(%{
          generation: 1,
          manifest_hash: :binary.copy(<<0x11>>, 32),
          section: :wifi,
          section_schema_version: 1,
          section_hash: :binary.copy(<<0x12>>, 32),
          secret_kind: :wifi_psk,
          digest_key_id: 1,
          secret_ref: :binary.copy(<<0x13>>, 16),
          secret_digest: :binary.copy(<<0x14>>, 32),
          secret: "synthetic-not-a-credential"
        })

      {:ok, secret_bytes} = Messages.encode(:secret_delivery, secret_delivery)
      {:ok, secret_frame, _server_control} = Control.seal(server_control, :secret_delivery, secret_bytes)
      push(client, topic, "control_v1", Control.encode_carrier(secret_frame))

      refute_push(^topic, "control_v1", _response, 50)
      refute_receive {:delivery_pending, _opts}
      assert Process.alive?(client)
    end

    test "drops control frames fenced by a replacement session", ctx do
      {client, holder, topic} = start_control_client(ctx)
      server_session = complete_handshake(client, topic, ctx, @control_epoch)
      assert_push(^topic, "wifi_status", _wifi_status)
      assert {:ok, server_control} = Control.new(:server, server_session)
      assert {:ok, current} = SessionHolder.get_current_session(holder)

      replacement = %{current | session_id: <<0xF1::128>>, generation: nil}
      assert {:ok, replacement} = SessionHolder.publish(holder, replacement, current.generation)
      assert replacement.generation > current.generation

      {_server_control, _accept_frame} = push_control_accept(client, topic, server_control)
      refute_push(^topic, "control_v1", _readiness, 50)
      refute_receive {:delivery_pending, _opts}
      assert Process.alive?(client)
    end

    # A TRANSIENT desired-state status/compatibility failure during control_accept
    # must not wedge the client. The server sends control_accept exactly once per
    # session and the accept frame's control counter is consumed on receipt, so the
    # identical frame can never be replayed (the replay window rejects it). If the
    # client just swallows the error and leaves `control_ready?` false, the control
    # plane is dead for the whole session with no path back: no readiness was sent,
    # no ACK replay was scheduled, and no reconnect was triggered. The client must
    # therefore fail CLOSED and reconnect, so a fresh session re-runs negotiation.
    @tag :control_accept_transient_failure
    test "a transient readiness failure reconnects instead of wedging the control plane", ctx do
      counter = :counters.new(1, [])

      {client, _holder, topic} =
        start_control_client(ctx,
          # Fails the FIRST readiness attempt only — the transient case.
          desired_state_status: fn ->
            :counters.add(counter, 1, 1)

            if :counters.get(counter, 1) == 1 do
              {:error, :desired_state_manager_unavailable}
            else
              %{active: nil}
            end
          end,
          backoff: [base_ms: 10, cap_ms: 10, jitter: 0]
        )

      server_session = complete_handshake(client, topic, ctx, @control_epoch)
      assert_push(^topic, "wifi_status", _wifi_status)
      assert {:ok, server_control} = Control.new(:server, server_session)

      {_server_control, _accept_frame} = push_control_accept(client, topic, server_control)

      # No readiness could be produced for this accept.
      refute_push(^topic, "control_v1", _readiness, 50)
      refute_receive {:delivery_pending, _opts}

      # The client must NOT sit wedged with a dead control plane. It has to drop the
      # unusable session and reconnect so negotiation can run again.
      assert eventually(fn ->
               state = :sys.get_state(client)
               state.assigns.control_ready? == false and is_nil(state.assigns.session)
             end),
             "client stayed wedged after a transient readiness failure"

      assert Process.alive?(client)
    end

    test "reconnects when outbound control requires rekey", ctx do
      payload = "durable-rekey-payload"

      entry = %RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Entry{
        stream: :health,
        device_id: @logical_device_id,
        credential_epoch: @control_epoch,
        storage_epoch: @storage_epoch,
        sequence: 11,
        entry_id: <<11::128>>,
        payload_hash: :crypto.hash(:sha256, payload),
        payload_checksum: :crypto.hash(:sha256, payload),
        payload: payload,
        priority: 1,
        encoded_size: byte_size(payload) + 128,
        ordinal: 1
      }

      {client, holder, topic} =
        start_control_client(ctx, delivery_pending: fn _outbox, _opts -> [entry] end)

      server_session = complete_handshake(client, topic, ctx, @control_epoch)
      assert_push(^topic, "wifi_status", _wifi_status)
      assert eventually(fn -> SessionHolder.live?(holder) end)
      assert {:ok, server_control} = Control.new(:server, server_session)

      :sys.replace_state(holder, fn state ->
        %{state | control: %{state.control | send_counter: SecureTransport.rekey_after() - 2}}
      end)

      {server_control, _accept_frame} = push_control_accept(client, topic, server_control)

      assert_push(^topic, "control_v1", readiness_carrier)
      assert {:ok, readiness_frame} = Control.decode_carrier(readiness_carrier)

      assert {:ok, :readiness, _readiness_bytes, server_control} =
               Control.open(server_control, readiness_frame)

      # The delivery_submission frame consumes the last pre-rekey counter; the
      # payload frame then requires rekey, which must reconnect rather than wedge.
      assert_push(^topic, "control_v1", submission_carrier)
      assert {:ok, submission_frame} = Control.decode_carrier(submission_carrier)

      assert {:ok, :delivery_submission, _submission_bytes, _server_control} =
               Control.open(server_control, submission_frame)

      assert_disconnect()
      assert eventually(fn -> not SessionHolder.live?(holder) end)
    end
  end

  # --- socket-layer smoke test (conceptual server) ---

  describe "handshake over the channel (SocketTest)" do
    test "connects, joins device:<fp>, and answers handshake_hello with handshake_init", ctx do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           keystore_opts: [base_path: ctx.base]}
        )

      # Connect + join (the conceptual server accepts).
      connect_and_assert_join(client, ^topic, %{}, :ok)

      # Server (us) builds a real HELLO and pushes it.
      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})

      # The client must push back a valid handshake_init.
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)

      # And the INIT finalizes server-side into a matching session.
      assert {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)

      # When the server confirms with handshake_ok, the client publishes the live
      # session to the holder.
      push(client, topic, "handshake_ok", %{
        "session_id" => Base.encode64(server_session.session_id)
      })

      # Wait for the holder to be populated.
      assert eventually(fn -> SessionHolder.live?(holder) end)
      {:ok, device_session} = SessionHolder.get_current_session(holder)
      assert device_session.session_id == server_session.session_id
      assert device_session.out_key == server_session.in_key
      assert device_session.generation == 1
    end

    test "a duplicate handshake_ok cannot republish keys or reset the send counter", ctx do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           firmware_validator: fn -> :ok end,
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      server_session = complete_handshake(client, topic, ctx)
      assert_push(^topic, "wifi_status", _status)
      assert {:ok, published} = SessionHolder.get_current_session(holder)
      assert {:ok, %{counter: 0}} = SessionHolder.take_send_counter(holder, published.generation)

      push(client, topic, "handshake_ok", %{
        "session_id" => Base.encode64(server_session.session_id)
      })

      Process.sleep(20)
      assert SessionHolder.generation(holder) == published.generation
      assert {:ok, %{counter: 1}} = SessionHolder.take_send_counter(holder, published.generation)
    end

    test "a delayed handshake_ok cannot replace a session published after its HELLO", ctx do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      first =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           firmware_validator: fn -> :ok end,
           backoff: [base_ms: 60_000, cap_ms: 60_000, jitter: 0],
           keystore_opts: [base_path: ctx.base]},
          id: :first_fenced_channel_client
        )

      second =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           firmware_validator: fn -> :ok end,
           backoff: [base_ms: 60_000, cap_ms: 60_000, jitter: 0],
           keystore_opts: [base_path: ctx.base]},
          id: :second_fenced_channel_client
        )

      connect_and_assert_join(first, ^topic, %{}, :ok)
      connect_and_assert_join(second, ^topic, %{}, :ok)

      {:ok, first_hello, first_responder} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(first, topic, "handshake_hello", %{"hello" => Base.encode64(first_hello)})
      assert_push(^topic, "handshake_init", %{"init" => first_init_b64})
      {:ok, first_init} = Base.decode64(first_init_b64)
      {:ok, first_server_session} = Handshake.responder_finalize(first_responder, first_init)

      {:ok, second_hello, second_responder} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(second, topic, "handshake_hello", %{"hello" => Base.encode64(second_hello)})
      assert_push(^topic, "handshake_init", %{"init" => second_init_b64})
      {:ok, second_init} = Base.decode64(second_init_b64)
      {:ok, second_server_session} = Handshake.responder_finalize(second_responder, second_init)

      push(second, topic, "handshake_ok", %{
        "session_id" => Base.encode64(second_server_session.session_id)
      })

      assert eventually(fn ->
               match?(
                 {:ok, %{session_id: session_id}} when session_id == second_server_session.session_id,
                 SessionHolder.get_current_session(holder)
               )
             end)

      push(first, topic, "handshake_ok", %{
        "session_id" => Base.encode64(first_server_session.session_id)
      })

      Process.sleep(20)
      assert {:ok, current} = SessionHolder.get_current_session(holder)
      assert current.session_id == second_server_session.session_id
      assert current.generation == 1
    end

    test "a failed pending equal-epoch handshake cannot clear the live session or readiness", ctx do
      {:ok, registration} = RecoverySupport.registration_result(ctx.identity, @serial)

      BootstrapStateStore.save!(
        %BootstrapState{
          phase: :registered,
          hardware_identity_digest:
            BootstrapStateMachine.hardware_identity_digest("raspberry_pi_soc_serial_v1", @serial),
          authority: registration_authority(registration)
        },
        base_path: ctx.base
      )

      boot_provisioner = start_boot_provisioner(ctx.base)
      assert eventually(fn -> BootProvisioner.current_state(boot_provisioner).phase == :registered end)

      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      live_client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           boot_provisioner: {BootProvisioner, boot_provisioner},
           firmware_validator: fn -> :ok end,
           backoff: [base_ms: 60_000, cap_ms: 60_000, jitter: 0],
           keystore_opts: [base_path: ctx.base]},
          id: :live_equal_epoch_channel_client
        )

      pending_client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           boot_provisioner: {BootProvisioner, boot_provisioner},
           firmware_validator: fn -> :ok end,
           backoff: [base_ms: 60_000, cap_ms: 60_000, jitter: 0],
           keystore_opts: [base_path: ctx.base]},
          id: :pending_equal_epoch_channel_client
        )

      connect_and_assert_join(live_client, ^topic, %{}, :ok)
      live_server_session = complete_handshake(live_client, topic, ctx)
      assert_push(^topic, "wifi_status", _status)
      assert eventually(fn -> BootProvisioner.current_state(boot_provisioner).phase == :authenticated end)

      assert {:ok, live_session} = SessionHolder.get_current_session(holder)
      assert live_session.session_id == live_server_session.session_id

      connect_and_assert_join(pending_client, ^topic, %{}, :ok)

      {:ok, pending_hello, _pending_responder} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(pending_client, topic, "handshake_hello", %{"hello" => Base.encode64(pending_hello)})
      assert_push(^topic, "handshake_init", %{"init" => _pending_init_b64})

      push(pending_client, topic, "handshake_error", %{"reason" => "rejected"})
      Process.sleep(20)

      assert {:ok, current} = SessionHolder.get_current_session(holder)
      assert current.session_id == live_session.session_id
      assert current.generation == live_session.generation
      assert BootProvisioner.current_state(boot_provisioner).phase == :authenticated
    end

    test "a failed rehandshake clears the live session owned by the same connection", ctx do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           firmware_validator: fn -> :ok end,
           backoff: [base_ms: 60_000, cap_ms: 60_000, jitter: 0],
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      complete_handshake(client, topic, ctx)
      assert_push(^topic, "wifi_status", _status)
      assert {:ok, live_session} = SessionHolder.get_current_session(holder)

      {:ok, replacement_hello, _replacement_responder} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(replacement_hello)})
      assert_push(^topic, "handshake_init", %{"init" => _replacement_init_b64})

      push(client, topic, "handshake_error", %{"reason" => "rejected"})
      Process.sleep(20)

      assert {:error, :no_session} = SessionHolder.get_current_session(holder)
      assert SessionHolder.generation(holder) == live_session.generation + 1
    end

    test "a stale client's disconnect and delayed callbacks cannot clear or use its replacement", ctx do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      first =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           firmware_validator: fn -> :ok end,
           backoff: [base_ms: 60_000, cap_ms: 60_000, jitter: 0],
           keystore_opts: [base_path: ctx.base]},
          id: :first_replaced_channel_client
        )

      second =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           firmware_validator: fn -> :ok end,
           backoff: [base_ms: 60_000, cap_ms: 60_000, jitter: 0],
           keystore_opts: [base_path: ctx.base]},
          id: :second_replacement_channel_client
        )

      connect_and_assert_join(first, ^topic, %{}, :ok)
      first_server_session = complete_handshake(first, topic, ctx)
      assert eventually(fn -> SessionHolder.live?(holder) end)
      assert_push(^topic, "wifi_status", _first_status)

      connect_and_assert_join(second, ^topic, %{}, :ok)
      second_server_session = complete_handshake(second, topic, ctx)
      assert_push(^topic, "wifi_status", _second_status)

      assert eventually(fn ->
               match?(
                 {:ok, %{session_id: session_id}} when session_id == second_server_session.session_id,
                 SessionHolder.get_current_session(holder)
               )
             end)

      ChannelClient.send_computed_values_data(first, [%{name: "stale", value: 1}])
      refute_push(^topic, "computed_values_data", _payload, 50)

      send(first, {VintageNet, ["interface", "wlan0", "connection"], :internet, :lan, %{}})
      refute_push(^topic, "wifi_status", _payload, 50)

      disconnect(first, :network_lost)

      assert {:ok, current} = SessionHolder.get_current_session(holder)
      assert current.session_id == second_server_session.session_id
      refute current.session_id == first_server_session.session_id
      assert current.generation == 2
    end

    test "session eviction clears the owned session and invalidates its generation", ctx do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           firmware_validator: fn -> :ok end,
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      complete_handshake(client, topic, ctx)
      assert_push(^topic, "wifi_status", _status)
      assert {:ok, published} = SessionHolder.get_current_session(holder)

      push(client, topic, "session_evicted", %{"reason" => "credential_recovered"})

      assert eventually(fn -> not SessionHolder.live?(holder) end)
      assert SessionHolder.generation(holder) == published.generation + 1

      assert {:error, :stale_session} =
               SessionHolder.take_send_counter(holder, published.generation)
    end

    # A Slipstream push BLOCKS until the server (here, the test process) answers the
    # transport `GenServer.call`. The SessionHolder is the single writer that
    # serializes nonce allocation for every subsystem, so it must never be the
    # process parked on that reply. When the fenced streamback push runs INSIDE a
    # holder callback the holder sits in `:gen.do_call` for the whole push timeout,
    # and every other holder API — `live?/1`, `take_send_counter/1`, `clear/1` —
    # queues behind unrelated channel transport. Generation fencing happens before
    # the push, so authorization, not the socket write, is what the holder owns.
    @tag :holder_block_regression
    test "a pending streamback push never blocks the session holder", ctx do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           firmware_validator: fn -> :ok end,
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      complete_handshake(client, topic, ctx)

      # Park the client mid-push: the post-handshake wifi_status push is left
      # deliberately UNANSWERED, exactly as it is whenever a test asserts on
      # anything else first.
      assert eventually(fn ->
               match?(
                 {:current_function, {:gen, :do_call, 4}},
                 Process.info(client, :current_function)
               )
             end)

      # The holder must answer PROMPTLY while that push is still outstanding.
      # Pre-fix the holder is itself blocked inside the push and only recovers when
      # the 5s transport timeout fires, so a bounded probe fails deterministically
      # rather than racing two 5s deadlines against each other.
      probe = Task.async(fn -> SessionHolder.live?(holder) end)
      probed = Task.yield(probe, 500)
      _ = Task.shutdown(probe, :brutal_kill)

      assert probed == {:ok, true},
             "SessionHolder blocked behind an in-flight channel push"

      # The parked push is still pending and must still reach the wire.
      assert_push(^topic, "wifi_status", _status)
    end

    # The liveness fix must NOT weaken the 881ae91 guarantee: a replacement may not
    # overtake a send this client already authorized. The holder keeps the two
    # mutually exclusive with a send lease, so `publish` blocks for as long as the
    # authorized push is in flight — it just no longer blocks unrelated readers.
    @tag :holder_block_regression
    test "a replacement cannot overtake an authorized in-flight push", ctx do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           firmware_validator: fn -> :ok end,
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      complete_handshake(client, topic, ctx)

      # Park the client inside its authorized wifi_status push.
      assert eventually(fn ->
               match?(
                 {:current_function, {:gen, :do_call, 4}},
                 Process.info(client, :current_function)
               )
             end)

      assert {:ok, current} = SessionHolder.get_current_session(holder)

      replacement = %{current | session_id: <<0xF7::128>>, generation: nil}

      replace_task =
        Task.async(fn -> SessionHolder.publish(holder, replacement, current.generation) end)

      # The replacement MUST NOT land while the authorized push is still in flight.
      assert Task.yield(replace_task, 200) == nil

      assert {:ok, still_current} = SessionHolder.get_current_session(holder)
      assert still_current.session_id == current.session_id

      # Draining the push releases the lease and lets the replacement proceed.
      assert_push(^topic, "wifi_status", _status)

      assert {:ok, published} = Task.await(replace_task)
      assert published.generation > current.generation
      assert published.session_id == replacement.session_id
    end

    test "uses the verified recovery epoch for the signed HELLO, INIT, and published session", ctx do
      {:ok, challenge} = RecoverySupport.challenge_result(ctx.identity, @serial)
      {:ok, lifecycle} = RecoverySupport.lifecycle_result(ctx.identity, challenge.receipt, credential_epoch: 4)

      BootstrapStateStore.save!(
        %BootstrapState{
          phase: :committed,
          hardware_identity_digest:
            BootstrapStateMachine.hardware_identity_digest("raspberry_pi_soc_serial_v1", @serial),
          authority: recovery_authority(ctx.identity, challenge, lifecycle)
        },
        base_path: ctx.base
      )

      boot_provisioner = start_boot_provisioner(ctx.base)
      assert eventually(fn -> BootProvisioner.credential_epoch(boot_provisioner) == {:ok, 4} end)

      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           boot_provisioner: {BootProvisioner, boot_provisioner},
           firmware_validator: fn -> :ok end,
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      server_session = complete_handshake(client, topic, ctx, 4)

      assert eventually(fn -> SessionHolder.live?(holder) end)
      assert {:ok, device_session} = SessionHolder.get_current_session(holder)
      assert device_session.session_id == server_session.session_id
      assert device_session.epoch == 4
      assert device_session.credential_epoch == 4
      assert {:ok, 4} = BootProvisioner.credential_epoch(boot_provisioner)
    end

    test "an authenticated higher epoch evicts the old live session before INIT can complete", ctx do
      {:ok, challenge} = RecoverySupport.challenge_result(ctx.identity, @serial)
      {:ok, lifecycle} = RecoverySupport.lifecycle_result(ctx.identity, challenge.receipt, credential_epoch: 3)

      BootstrapStateStore.save!(
        %BootstrapState{
          phase: :committed,
          hardware_identity_digest:
            BootstrapStateMachine.hardware_identity_digest("raspberry_pi_soc_serial_v1", @serial),
          authority: recovery_authority(ctx.identity, challenge, lifecycle)
        },
        base_path: ctx.base
      )

      boot_provisioner = start_boot_provisioner(ctx.base)
      assert eventually(fn -> BootProvisioner.credential_epoch(boot_provisioner) == {:ok, 3} end)

      {:ok, holder} = start_supervised({SessionHolder, name: nil})

      old_session =
        Session.new(
          role: :initiator,
          session_id: :crypto.strong_rand_bytes(16),
          epoch: 3,
          credential_epoch: 3,
          identity_fingerprint: Base.decode16!(ctx.identity.fingerprint, case: :mixed),
          out_key: :crypto.strong_rand_bytes(32),
          in_key: :crypto.strong_rand_bytes(32)
        )

      assert {:ok, old_session} = SessionHolder.publish(holder, old_session)
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           boot_provisioner: {BootProvisioner, boot_provisioner},
           firmware_validator: fn -> :ok end,
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)

      {:ok, hello_wire, responder_state} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 4
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})

      assert {:error, :no_session} = SessionHolder.get_current_session(holder)
      assert SessionHolder.generation(holder) == old_session.generation + 1

      assert {:error, :stale_session} =
               SessionHolder.take_send_counter(holder, old_session.generation)

      {:ok, init_wire} = Base.decode64(init_b64)
      {:ok, server_session} = Handshake.responder_finalize(responder_state, init_wire)
      push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})

      assert eventually(fn ->
               match?(
                 {:ok, %{credential_epoch: 4, generation: 3}},
                 SessionHolder.get_current_session(holder)
               )
             end)
    end

    test "a recovery epoch advance invalidates an older handshake awaiting confirmation", ctx do
      {:ok, challenge} = RecoverySupport.challenge_result(ctx.identity, @serial)
      {:ok, lifecycle} = RecoverySupport.lifecycle_result(ctx.identity, challenge.receipt, credential_epoch: 3)

      BootstrapStateStore.save!(
        %BootstrapState{
          phase: :committed,
          hardware_identity_digest:
            BootstrapStateMachine.hardware_identity_digest("raspberry_pi_soc_serial_v1", @serial),
          authority: recovery_authority(ctx.identity, challenge, lifecycle)
        },
        base_path: ctx.base
      )

      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      boot_provisioner = start_boot_provisioner(ctx.base, session_holder: holder)
      assert eventually(fn -> BootProvisioner.credential_epoch(boot_provisioner) == {:ok, 3} end)

      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           boot_provisioner: {BootProvisioner, boot_provisioner},
           firmware_validator: fn -> :ok end,
           backoff: [base_ms: 60_000, cap_ms: 60_000, jitter: 0],
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)

      {:ok, hello_wire, responder_state} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 3
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)
      {:ok, old_server_session} = Handshake.responder_finalize(responder_state, init_wire)

      pending_generation = SessionHolder.generation(holder)
      refute SessionHolder.live?(holder)

      assert {:ok, %BootstrapState{verified_credential_epoch: 4}} =
               BootProvisioner.adopt_credential_epoch(4, boot_provisioner)

      assert SessionHolder.generation(holder) == pending_generation + 1

      push(client, topic, "handshake_ok", %{
        "session_id" => Base.encode64(old_server_session.session_id)
      })

      refute eventually(fn -> SessionHolder.live?(holder) end, 100)
      assert {:ok, 4} = BootProvisioner.credential_epoch(boot_provisioner)
    end

    test "rejects a signed HELLO below the verified recovery epoch and publishes no session", ctx do
      {:ok, challenge} = RecoverySupport.challenge_result(ctx.identity, @serial)
      {:ok, lifecycle} = RecoverySupport.lifecycle_result(ctx.identity, challenge.receipt, credential_epoch: 4)

      BootstrapStateStore.save!(
        %BootstrapState{
          phase: :committed,
          hardware_identity_digest:
            BootstrapStateMachine.hardware_identity_digest("raspberry_pi_soc_serial_v1", @serial),
          authority: recovery_authority(ctx.identity, challenge, lifecycle)
        },
        base_path: ctx.base
      )

      boot_provisioner = start_boot_provisioner(ctx.base)
      assert eventually(fn -> BootProvisioner.credential_epoch(boot_provisioner) == {:ok, 4} end)

      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           boot_provisioner: {BootProvisioner, boot_provisioner},
           backoff: [base_ms: 60_000, cap_ms: 60_000, jitter: 0],
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)

      {:ok, hello_wire, _responder_state} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})

      refute_push(^topic, "handshake_init", _payload, 100)
      refute SessionHolder.live?(holder)
      assert {:ok, 4} = BootProvisioner.credential_epoch(boot_provisioner)
    end

    test "an authenticated WSS handshake does not invoke firmware validation", ctx do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      parent = self()
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           firmware_validator: fn -> send(parent, :firmware_validated) end,
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)

      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)
      assert {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)

      push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})

      assert_push(^topic, "wifi_status", _status)
      assert SessionHolder.live?(holder)
      refute_received :firmware_validated
    end

    test "reports authenticated readiness and clears it with the live session on disconnect", ctx do
      {:ok, registration} = RecoverySupport.registration_result(ctx.identity, @serial)

      BootstrapStateStore.save!(
        %BootstrapState{
          phase: :registered,
          hardware_identity_digest:
            BootstrapStateMachine.hardware_identity_digest("raspberry_pi_soc_serial_v1", @serial),
          authority: registration_authority(registration)
        },
        base_path: ctx.base
      )

      boot_provisioner = start_boot_provisioner(ctx.base)
      assert eventually(fn -> BootProvisioner.current_state(boot_provisioner).phase == :registered end)

      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           boot_provisioner: {BootProvisioner, boot_provisioner},
           firmware_validator: fn -> :ok end,
           backoff: [base_ms: 60_000, cap_ms: 60_000, jitter: 0],
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      complete_handshake(client, topic, ctx)

      assert eventually(fn -> SessionHolder.live?(holder) end)
      assert eventually(fn -> BootProvisioner.current_state(boot_provisioner).phase == :authenticated end)
      assert_push(^topic, "wifi_status", _status)
      assert {:ok, published} = SessionHolder.get_current_session(holder)

      disconnect(client, :network_lost)

      assert eventually(fn -> not SessionHolder.live?(holder) end)
      assert SessionHolder.generation(holder) == published.generation + 1

      assert {:error, :stale_session} =
               SessionHolder.take_send_counter(holder, published.generation)

      assert eventually(fn -> BootProvisioner.current_state(boot_provisioner).phase == :registered end)
    end

    test "a matching v1 device enrolls hardware only after authentication and adopts the signed receipt", ctx do
      marker_path = Path.join(ctx.base, "register_marker.json")

      File.write!(
        marker_path,
        Jason.encode!(%{
          "device_id" => "legacy-device",
          "fingerprint" => IdentityProvider.fingerprint(ctx.identity),
          "status" => "assigned"
        })
      )

      nonce = :binary.copy(<<0x45>>, 32)
      boot_provisioner = start_boot_provisioner(ctx.base, client_nonce: nonce)

      assert eventually(fn ->
               match?(
                 %BootstrapState{phase: :limbo, blocked_reason: :legacy_enrollment_required},
                 BootProvisioner.current_state(boot_provisioner)
               )
             end)

      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           boot_provisioner: {BootProvisioner, boot_provisioner},
           firmware_validator: fn -> :ok end,
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      refute_push(^topic, "enroll_hardware_identity", %{}, 50)

      complete_handshake(client, topic, ctx)

      assert_push(^topic, "enroll_hardware_identity", request_body, request_ref)
      assert request_body["provider"] == "raspberry_pi_soc_serial_v1"
      assert request_body["serial"] == @serial
      assert request_body["client_nonce"] == Base.encode64(nonce)
      assert SessionHolder.live?(holder)
      assert_push(^topic, "wifi_status", _status)

      {:ok, enrollment} =
        RecoverySupport.registration_result(ctx.identity, @serial, client_nonce: nonce)

      reply(
        client,
        request_ref,
        {:ok, RecoverySupport.receipt_response(enrollment.receipt)}
      )

      assert eventually(fn -> BootProvisioner.current_state(boot_provisioner).phase == :authenticated end)
      refute File.exists?(marker_path)
    end

    test "a v1 device stays authenticated when an older backend rejects the enrollment event", ctx do
      marker_path = Path.join(ctx.base, "register_marker.json")

      File.write!(
        marker_path,
        Jason.encode!(%{
          "device_id" => "legacy-device",
          "fingerprint" => IdentityProvider.fingerprint(ctx.identity),
          "status" => "assigned"
        })
      )

      boot_provisioner = start_boot_provisioner(ctx.base, client_nonce: :binary.copy(<<0x46>>, 32))

      assert eventually(fn ->
               match?(
                 %BootstrapState{phase: :limbo, blocked_reason: :legacy_enrollment_required},
                 BootProvisioner.current_state(boot_provisioner)
               )
             end)

      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           boot_provisioner: {BootProvisioner, boot_provisioner},
           firmware_validator: fn -> :ok end,
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      complete_handshake(client, topic, ctx)
      assert_push(^topic, "enroll_hardware_identity", _request_body, request_ref)
      assert_push(^topic, "wifi_status", _status)

      reply(client, request_ref, {:error, %{"reason" => "unsupported_event"}})

      assert eventually(fn -> SessionHolder.live?(holder) end)
      assert Process.alive?(client)
      assert File.exists?(marker_path)

      assert %BootstrapState{phase: :limbo, blocked_reason: :legacy_enrollment_required} =
               BootProvisioner.current_state(boot_provisioner)
    end
  end

  # --- remote WiFi management (J5): set_wifi / wifi_status over the channel ---

  describe "set_wifi / wifi_status (SocketTest)" do
    # A fake WiFi collaborator (mirrors the RacingOrg.Tracker.Pro.WiFiManager API surface J5
    # uses) that records apply_config/2 calls to the test process and returns a
    # canned current_status/1 — so no real WiFiManager / VintageNet is needed.
    defmodule FakeWiFi do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts) do
        {:ok,
         %{
           parent: Keyword.fetch!(opts, :parent),
           status: Keyword.get(opts, :status, %{enabled: true, ssid: "boat-net", connection: :internet, signal: -55}),
           apply_result:
             Keyword.get(opts, :apply_result, {:ok, %{version: 0, enabled: true, ssid: "boat-net", psk: "secret"}})
         }}
      end

      def apply_config(server, config), do: GenServer.call(server, {:apply_config, config})
      def current_status(server), do: GenServer.call(server, :current_status)

      @impl true
      def handle_call({:apply_config, config}, _from, state) do
        send(state.parent, {:apply_config_called, config})
        {:reply, state.apply_result, state}
      end

      def handle_call(:current_status, _from, state) do
        {:reply, state.status, state}
      end
    end

    defp connect_client(ctx, wifi_opts) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, wifi} = start_supervised({FakeWiFi, [parent: self()] ++ wifi_opts})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           wifi: {FakeWiFi, wifi},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      {client, topic, wifi}
    end

    test "server set_wifi (enable) → apply_config called + wifi_status pushed without psk", ctx do
      {client, topic, _wifi} =
        connect_client(ctx,
          apply_result: {:ok, %{version: 2, enabled: true, ssid: "boat-net", psk: "secret"}},
          status: %{enabled: true, ssid: "boat-net", connection: :internet, signal: -55}
        )

      push(client, topic, "set_wifi", %{
        "ssid" => "boat-net",
        "psk" => "secret",
        "enabled" => true,
        "version" => 2
      })

      # The injected wifi fake's apply_config was called with the server config.
      assert_receive {:apply_config_called, config}
      assert config["ssid"] == "boat-net"
      assert config["version"] == 2
      assert config["enabled"] == true

      # The client reports status back to the server, echoing applied_version.
      assert_push(^topic, "wifi_status", status)
      assert status.applied_version == 2
      assert status.enabled == true
      assert status.ssid == "boat-net"
      assert Map.has_key?(status, :connection)
      assert Map.has_key?(status, :signal)

      # The status NEVER leaks the psk.
      refute Map.has_key?(status, :psk)
      refute Map.has_key?(status, "psk")
    end

    test "server set_wifi (disable) → apply_config called + wifi_status pushed", ctx do
      {client, topic, _wifi} =
        connect_client(ctx,
          apply_result: {:ok, %{version: 3, enabled: false, ssid: nil, psk: nil}},
          status: %{enabled: false, ssid: nil, connection: :disconnected, signal: nil}
        )

      push(client, topic, "set_wifi", %{"enabled" => false, "version" => 3})

      assert_receive {:apply_config_called, config}
      assert config["enabled"] == false
      assert config["version"] == 3

      assert_push(^topic, "wifi_status", status)
      assert status.enabled == false
      assert status.applied_version == 3
      refute Map.has_key?(status, :psk)
    end

    test "set_wifi apply error → still pushes status without falsely acknowledging the version", ctx do
      {client, topic, _wifi} =
        connect_client(ctx,
          apply_result: {:error, :ssid_required},
          status: %{enabled: false, ssid: nil, connection: :disconnected, signal: nil}
        )

      push(client, topic, "set_wifi", %{"enabled" => true, "psk" => "p", "version" => 4})

      assert_receive {:apply_config_called, _config}
      assert_push(^topic, "wifi_status", status)
      assert Map.has_key?(status, :enabled)
      refute Map.has_key?(status, :applied_version)
      refute Map.has_key?(status, :psk)
      assert Process.alive?(client)
    end

    test "indeterminate WiFi authority never reports the incoming version as applied", ctx do
      {client, topic, _wifi} =
        connect_client(ctx,
          apply_result: {:error, :wifi_authority_indeterminate},
          status: %{enabled: true, ssid: "candidate", connection: :lan, signal: -61}
        )

      push(client, topic, "set_wifi", %{
        "enabled" => true,
        "ssid" => "candidate",
        "psk" => "candidate-secret",
        "version" => 7
      })

      assert_receive {:apply_config_called, _config}
      assert_push(^topic, "wifi_status", status)
      refute Map.has_key?(status, :applied_version)
      refute Map.has_key?(status, :psk)
      assert Process.alive?(client)
    end

    test "set_wifi unchanged replay acknowledges the requested durable version", ctx do
      {client, topic, _wifi} =
        connect_client(ctx,
          apply_result: {:ok, :unchanged},
          status: %{enabled: true, ssid: "boat-net", connection: :internet, signal: -55}
        )

      push(client, topic, "set_wifi", %{
        "enabled" => true,
        "ssid" => "boat-net",
        "psk" => "secret",
        "version" => 5
      })

      assert_receive {:apply_config_called, _config}
      assert_push(^topic, "wifi_status", status)
      assert status.applied_version == 5
      refute Map.has_key?(status, :psk)
    end

    test "an authenticated simulated wlan0 connection-change pushes a fresh wifi_status", ctx do
      {client, topic, _wifi} =
        connect_client(ctx, status: %{enabled: true, ssid: "boat-net", connection: :lan, signal: -60})

      complete_handshake(client, topic, ctx)
      assert_push(^topic, "wifi_status", _initial_status)

      # Drive the VintageNet property-change handler directly (the real subscription
      # is a no-op in test_mode, so we simulate the message it would deliver).
      send(client, {VintageNet, ["interface", "wlan0", "connection"], :disconnected, :lan, %{}})

      assert_push(^topic, "wifi_status", status)
      assert status.connection == :lan
      assert status.enabled == true
      refute Map.has_key?(status, :psk)
    end

    test "drops delayed wifi_status callbacks after the authenticated session disconnects", ctx do
      {client, topic, _wifi} =
        connect_client(ctx, status: %{enabled: true, ssid: "boat-net", connection: :lan, signal: -60})

      complete_handshake(client, topic, ctx)
      assert_push(^topic, "wifi_status", _initial_status)

      disconnect(client, :network_lost)
      send(client, {VintageNet, ["interface", "wlan0", "connection"], :internet, :lan, %{}})

      refute_push(^topic, "wifi_status", _status, 100)
    end

    test "pushes an initial wifi_status shortly after a successful handshake", ctx do
      {client, topic, _wifi} =
        connect_client(ctx, status: %{enabled: true, ssid: "boat-net", connection: :internet, signal: -50})

      # Complete the handshake so the session goes live, which should trigger an
      # initial status report to the server.
      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)
      {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)

      push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})

      assert_push(^topic, "wifi_status", status)
      assert status.enabled == true
      assert status.ssid == "boat-net"
      refute Map.has_key?(status, :psk)
    end
  end

  # --- upstream signal selection: set_upstream / upstream_status ---

  describe "set_upstream / upstream_status (SocketTest)" do
    # A fake Upstream collaborator mirroring the RacingOrg.Tracker.Pro.Upstream.Config
    # API surface the channel uses: apply_config/2 (records the call) + upstream_status/1.
    defmodule FakeUpstream do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts) do
        {:ok,
         %{
           parent: Keyword.fetch!(opts, :parent),
           status: Keyword.get(opts, :status, %{applied_version: 0}),
           apply_result: Keyword.get(opts, :apply_result, {:ok, %{version: 0}})
         }}
      end

      def apply_config(server, config), do: GenServer.call(server, {:apply_config, config})
      def upstream_status(server), do: GenServer.call(server, :upstream_status)

      @impl true
      def handle_call({:apply_config, config}, _from, state) do
        send(state.parent, {:apply_upstream_called, config})
        {:reply, state.apply_result, state}
      end

      def handle_call(:upstream_status, _from, state), do: {:reply, state.status, state}
    end

    defp connect_upstream_client(ctx, upstream_opts) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, upstream} = start_supervised({FakeUpstream, [parent: self()] ++ upstream_opts})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           upstream: {FakeUpstream, upstream},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      {client, topic, upstream}
    end

    test "server set_upstream → apply_config called + upstream_status pushed", ctx do
      {client, topic, _upstream} =
        connect_upstream_client(ctx, apply_result: {:ok, %{version: 2}}, status: %{applied_version: 2})

      push(client, topic, "set_upstream", %{
        "version" => 2,
        "signals" => %{
          "heading" => true,
          "speed" => true,
          "velocity" => true,
          "wind" => false,
          "water_depth" => true,
          "attitude" => false
        }
      })

      assert_receive {:apply_upstream_called, config}
      assert config["version"] == 2
      assert config["signals"]["wind"] == false

      assert_push(^topic, "upstream_status", status)
      assert status.applied_version == 2
      assert is_binary(status.reported_at)
    end

    test "an apply error still reports the current status (server never left stale)", ctx do
      {client, topic, _upstream} =
        connect_upstream_client(ctx, apply_result: {:error, :bad_payload}, status: %{applied_version: 1})

      push(client, topic, "set_upstream", %{"version" => "garbage"})

      assert_receive {:apply_upstream_called, _config}
      assert_push(^topic, "upstream_status", status)
      assert status.applied_version == 1
    end
  end

  # --- per-state tracking config (Phase 5): set_tracking / tracking_status ---

  describe "set_tracking / tracking_status (SocketTest)" do
    # A fake Tracking collaborator mirroring the RacingOrg.Tracker.Pro.Tracking.Config API
    # surface the channel uses: apply_config/2 (records the call) + status/1.
    defmodule FakeTracking do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts) do
        {:ok,
         %{
           parent: Keyword.fetch!(opts, :parent),
           status:
             Keyword.get(opts, :status, %{
               applied_version: 0,
               active_state: :race,
               active_rate_hz: 10.0,
               active_damping_seconds: 0.5
             }),
           apply_result: Keyword.get(opts, :apply_result, {:ok, %{version: 0}})
         }}
      end

      def apply_config(server, config), do: GenServer.call(server, {:apply_config, config})
      def tracking_status(server), do: GenServer.call(server, :tracking_status)

      @impl true
      def handle_call({:apply_config, config}, _from, state) do
        send(state.parent, {:apply_tracking_called, config})
        {:reply, state.apply_result, state}
      end

      def handle_call(:tracking_status, _from, state), do: {:reply, state.status, state}
    end

    defp connect_tracking_client(ctx, tracking_opts) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, tracking} = start_supervised({FakeTracking, [parent: self()] ++ tracking_opts})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           tracking: {FakeTracking, tracking},
           tracking_status: {FakeTracking, tracking},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      {client, topic, tracking}
    end

    test "server set_tracking → apply_config called + tracking_status pushed", ctx do
      {client, topic, _tracking} =
        connect_tracking_client(ctx,
          apply_result: {:ok, %{version: 0}},
          status: %{applied_version: 0, active_state: :race, active_rate_hz: 10.0, active_damping_seconds: 0.5}
        )

      push(client, topic, "set_tracking", %{
        "version" => 0,
        "states" => %{
          "pre_race" => %{"damping_seconds" => 2.0, "send_rate_hz" => 1.0},
          "starting" => %{"damping_seconds" => 1.0, "send_rate_hz" => 5.0},
          "race" => %{"damping_seconds" => 0.5, "send_rate_hz" => 10.0}
        }
      })

      assert_receive {:apply_tracking_called, config}
      assert config["version"] == 0
      assert config["states"]["race"]["send_rate_hz"] == 10.0

      assert_push(^topic, "tracking_status", status)
      assert status.applied_version == 0
      assert status.active_state == :race
      assert status.active_rate_hz == 10.0
      assert status.active_damping_seconds == 0.5
      assert Map.has_key?(status, :reported_at)
    end

    test "set_tracking apply error → still pushes status (no crash)", ctx do
      {client, topic, _tracking} =
        connect_tracking_client(ctx,
          apply_result: {:error, :malformed},
          status: %{applied_version: 0, active_state: :pre_race, active_rate_hz: 1.0, active_damping_seconds: 2.0}
        )

      push(client, topic, "set_tracking", %{"version" => 9, "states" => %{}})

      assert_receive {:apply_tracking_called, _config}
      assert_push(^topic, "tracking_status", status)
      assert Map.has_key?(status, :active_state)
      assert Process.alive?(client)
    end
  end

  # --- clock-source policy: set_clock_source / clock_source_status ---

  describe "set_clock_source / clock_source_status (SocketTest)" do
    # A fake ClockSource collaborator mirroring the API the channel uses:
    # apply_config/2 (records the call) + status/1.
    defmodule FakeClockSource do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts) do
        {:ok,
         %{
           parent: Keyword.fetch!(opts, :parent),
           status:
             Keyword.get(opts, :status, %{
               applied_version: 2,
               mode: "sensor_priority",
               active_source_sensor_id: "sensor-abc",
               active_source_label: "Masthead GPS",
               active_hw_id: "hw-1",
               active_source_address: "35",
               timebase: "sensor",
               fallback_reason: nil,
               last_gps_time: "2026-06-30T12:00:00.000Z",
               status: "ok"
             }),
           apply_result: Keyword.get(opts, :apply_result, {:ok, %{version: 2}})
         }}
      end

      def apply_config(server, config), do: GenServer.call(server, {:apply_config, config})
      def status(server), do: GenServer.call(server, :status)

      @impl true
      def handle_call({:apply_config, config}, _from, state) do
        send(state.parent, {:apply_clock_source_called, config})
        {:reply, state.apply_result, state}
      end

      def handle_call(:status, _from, state), do: {:reply, state.status, state}
    end

    defp connect_clock_source_client(ctx, clock_opts) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, clock} = start_supervised({FakeClockSource, [parent: self()] ++ clock_opts})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           clock_source: {FakeClockSource, clock},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      {client, topic, clock}
    end

    test "server set_clock_source → apply_config called + clock_source_status pushed", ctx do
      {client, topic, _clock} = connect_clock_source_client(ctx, [])

      push(client, topic, "set_clock_source", %{
        "version" => 2,
        "mode" => "sensor_priority",
        "fallback" => "tracker_receive_time",
        "sources" => [
          %{"priority" => 1, "sensor_id" => "sensor-abc", "source_address" => "35", "label" => "Masthead GPS"}
        ]
      })

      assert_receive {:apply_clock_source_called, config}
      assert config["version"] == 2
      assert config["mode"] == "sensor_priority"

      assert_push(^topic, "clock_source_status", status)
      assert status.applied_version == 2
      assert status.mode == "sensor_priority"
      assert status.timebase == "sensor"
      assert status.active_source_sensor_id == "sensor-abc"
      assert status.active_source_label == "Masthead GPS"
      assert status.active_hw_id == "hw-1"
      assert status.active_source_address == "35"
      assert status.fallback_reason == nil
      assert status.last_gps_time == "2026-06-30T12:00:00.000Z"
      assert status.status == "ok"
      assert Map.has_key?(status, :reported_at)
    end

    test "set_clock_source apply error → still pushes status (no crash)", ctx do
      {client, topic, _clock} =
        connect_clock_source_client(ctx,
          apply_result: {:error, :bad_version},
          status: %{
            applied_version: nil,
            mode: "tracker_receive_time",
            timebase: "tracker_receive_time",
            fallback_reason: "default_mode"
          }
        )

      push(client, topic, "set_clock_source", %{"mode" => "sensor_priority"})

      assert_receive {:apply_clock_source_called, _config}
      assert_push(^topic, "clock_source_status", status)
      assert status.mode == "tracker_receive_time"
      assert status.timebase == "tracker_receive_time"
      assert Process.alive?(client)
    end
  end

  # --- wind-shift policy: set_wind_shift / wind_shift_status ---

  describe "set_wind_shift / wind_shift_status (SocketTest)" do
    # A fake WindShift.Config collaborator mirroring the API the channel uses:
    # apply_config/2 (records the call) + status/1 (the POLICY half).
    defmodule FakeWindShift do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts) do
        {:ok,
         %{
           parent: Keyword.fetch!(opts, :parent),
           status: Keyword.get(opts, :status, %{applied_version: 3, wally_mode: "shadow", status: "ok"}),
           apply_result: Keyword.get(opts, :apply_result, {:ok, %{version: 3}})
         }}
      end

      def apply_config(server, config), do: GenServer.call(server, {:apply_config, config})
      def status(server), do: GenServer.call(server, :status)

      @impl true
      def handle_call({:apply_config, config}, _from, state) do
        send(state.parent, {:apply_wind_shift_called, config})
        {:reply, state.apply_result, state}
      end

      def handle_call(:status, _from, state), do: {:reply, state.status, state}
    end

    # A fake WindShift.Observer collaborator: status/1 (the LIVE half).
    defmodule FakeWindShiftObserver do
      use Agent

      @default %{
        regime: "oscillating",
        confidence: 0.72,
        oscillation_period_s: 480.0,
        oscillation_amplitude_deg: 9.5,
        trend_deg_per_hr: 1.2,
        wind_phase_deg: 4.0,
        wind_lift_deg: 4.0,
        twd_range_deg: 21.0,
        status: "ok"
      }

      def start_link(opts), do: Agent.start_link(fn -> Keyword.get(opts, :status, @default) end)
      def status(agent), do: Agent.get(agent, & &1)
    end

    defp connect_wind_shift_client(ctx, wind_shift_opts, observer_opts \\ []) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, wind_shift} = start_supervised({FakeWindShift, [parent: self()] ++ wind_shift_opts})
      {:ok, observer} = start_supervised({FakeWindShiftObserver, observer_opts})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           wind_shift: {FakeWindShift, wind_shift},
           wind_shift_observer: {FakeWindShiftObserver, observer},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      {client, topic, wind_shift}
    end

    test "server set_wind_shift → apply_config called + the exact 12-key status pushed", ctx do
      {client, topic, _wind_shift} = connect_wind_shift_client(ctx, [])

      push(client, topic, "set_wind_shift", %{
        "version" => 3,
        "windows" => %{"fast_s" => 30, "mid_s" => 300, "slow_s" => 1500, "envelope_s" => 1800},
        "alarms" => %{"new_extreme_margin_deg" => 2.0, "enabled" => true},
        "wally" => %{"mode" => "shadow"}
      })

      assert_receive {:apply_wind_shift_called, config}
      assert config["version"] == 3
      assert config["wally"]["mode"] == "shadow"

      assert_push(^topic, "wind_shift_status", status)
      assert status.applied_version == 3
      assert status.regime == "oscillating"
      assert status.confidence == 0.72
      assert status.oscillation_period_s == 480.0
      assert status.oscillation_amplitude_deg == 9.5
      assert status.trend_deg_per_hr == 1.2
      assert status.wind_phase_deg == 4.0
      assert status.wind_lift_deg == 4.0
      assert status.twd_range_deg == 21.0
      assert status.wally_mode == "shadow"
      assert status.status == "ok"
      assert Map.has_key?(status, :reported_at)

      # Allowlist: EXACTLY the 12 contract fields, nothing more.
      assert Map.keys(status) |> Enum.sort() == [
               :applied_version,
               :confidence,
               :oscillation_amplitude_deg,
               :oscillation_period_s,
               :regime,
               :reported_at,
               :status,
               :trend_deg_per_hr,
               :twd_range_deg,
               :wally_mode,
               :wind_lift_deg,
               :wind_phase_deg
             ]
    end

    test "set_wind_shift apply error → still pushes status (no crash)", ctx do
      {client, topic, _wind_shift} =
        connect_wind_shift_client(
          ctx,
          [apply_result: {:error, :bad_wally_mode}, status: %{applied_version: nil, wally_mode: "off", status: "ok"}],
          status: %{
            regime: "insufficient_history",
            confidence: 0.0,
            oscillation_period_s: nil,
            oscillation_amplitude_deg: nil,
            trend_deg_per_hr: nil,
            wind_phase_deg: nil,
            wind_lift_deg: nil,
            twd_range_deg: nil,
            status: "ok"
          }
        )

      push(client, topic, "set_wind_shift", %{"version" => 1, "wally" => %{"mode" => "bogus"}})

      assert_receive {:apply_wind_shift_called, _config}
      assert_push(^topic, "wind_shift_status", status)
      assert status.applied_version == nil
      assert status.regime == "insufficient_history"
      assert status.wally_mode == "off"
      assert Process.alive?(client)
    end
  end

  # --- calibration policy: set_calibration / calibration_status ---

  describe "set_calibration / calibration_status (SocketTest)" do
    # A fake Calibration.Config collaborator mirroring the API the channel uses:
    # apply_config/2 (records the call) + status/1.
    defmodule FakeCalibration do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts) do
        {:ok,
         %{
           parent: Keyword.fetch!(opts, :parent),
           status:
             Keyword.get(opts, :status, %{
               applied_version: 3,
               modes: %{
                 "awa_offset" => "auto",
                 "awa_upwash" => "auto",
                 "stw_scale" => "auto",
                 "aws_scale" => "shadow"
               },
               sensors: [
                 %{
                   hardware_identifier: "1A2B",
                   parameter: "awa_offset",
                   state: "applied",
                   value: 2.5,
                   confidence: 0.9,
                   sample_count: 500
                 }
               ],
               status: "ok"
             }),
           apply_result: Keyword.get(opts, :apply_result, {:ok, %{version: 3}})
         }}
      end

      def apply_config(server, config), do: GenServer.call(server, {:apply_config, config})
      def status(server), do: GenServer.call(server, :status)

      @impl true
      def handle_call({:apply_config, config}, _from, state) do
        send(state.parent, {:apply_calibration_called, config})
        {:reply, state.apply_result, state}
      end

      def handle_call(:status, _from, state), do: {:reply, state.status, state}
    end

    defp connect_calibration_client(ctx, calibration_opts) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, calibration} = start_supervised({FakeCalibration, [parent: self()] ++ calibration_opts})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           calibration: {FakeCalibration, calibration},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      {client, topic, calibration}
    end

    test "server set_calibration → apply_config called + calibration_status pushed", ctx do
      {client, topic, _calibration} = connect_calibration_client(ctx, [])

      push(client, topic, "set_calibration", %{
        "version" => 3,
        "parameters" => %{"awa_offset" => %{"mode" => "auto"}, "aws_scale" => %{"mode" => "shadow"}},
        "sensors" => [
          %{"hardware_identifier" => "1A2B", "parameter" => "awa_offset", "locked" => true, "value" => 2.5}
        ]
      })

      assert_receive {:apply_calibration_called, config}
      assert config["version"] == 3
      assert config["parameters"]["awa_offset"]["mode"] == "auto"

      assert_push(^topic, "calibration_status", status)
      assert status.applied_version == 3
      assert status.modes["awa_offset"] == "auto"
      assert status.modes["aws_scale"] == "shadow"
      assert [%{hardware_identifier: "1A2B", parameter: "awa_offset", state: "applied"}] = status.sensors
      assert status.status == "ok"
      assert Map.has_key?(status, :reported_at)
      # Allowlist: nothing beyond the contract fields.
      assert Map.keys(status) |> Enum.sort() == [:applied_version, :modes, :reported_at, :sensors, :status]
    end

    test "calibration_status with curve-valued learned entries is JSON-encodable", ctx do
      # A REAL Calibration.Config holding CURVE-valued learned entries (tuple
      # lists internally): the status it reports must already be rendered into
      # JSON-encodable maps, or the channel push would crash the serializer.
      alias RacingOrg.Tracker.Pro.Calibration.Config, as: CalConfig

      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, calibration} = start_supervised({CalConfig, name: nil, store_dir: nil})
      topic = "device:" <> ctx.identity.fingerprint

      entry = %{confidence: 0.9, sample_count: 8, state: "applied"}

      assert :ok =
               CalConfig.put_learned(calibration, "1A2B", "awa_upwash", Map.put(entry, :value, [{5, 3.0}, {9, 1.0}]))

      assert :ok = CalConfig.put_learned(calibration, "3C4D", "stw_scale", Map.put(entry, :value, [{1, 1.05}]))

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           calibration: {CalConfig, calibration},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      push(client, topic, "set_calibration", %{"version" => 1, "parameters" => %{}, "sensors" => []})

      assert_push(^topic, "calibration_status", status)

      assert %{value: [%{center: 5, value: 3.0}, %{center: 9, value: 1.0}]} =
               Enum.find(status.sensors, &(&1.parameter == "awa_upwash"))

      assert %{value: [%{center: 1, gain: 1.05}]} = Enum.find(status.sensors, &(&1.parameter == "stw_scale"))
      assert is_binary(Jason.encode!(status))
    end

    test "set_calibration apply error → still pushes status (no crash)", ctx do
      {client, topic, _calibration} =
        connect_calibration_client(ctx,
          apply_result: {:error, :bad_version},
          status: %{
            applied_version: nil,
            modes: %{
              "awa_offset" => "auto",
              "awa_upwash" => "auto",
              "stw_scale" => "auto",
              "aws_scale" => "shadow"
            },
            sensors: []
          }
        )

      push(client, topic, "set_calibration", %{"parameters" => %{}})

      assert_receive {:apply_calibration_called, _config}
      assert_push(^topic, "calibration_status", status)
      assert status.applied_version == nil
      assert status.sensors == []
      assert Process.alive?(client)
    end
  end

  # --- computed values (Phase 7): set_computed_values / computed_values_status ---

  describe "set_computed_values / computed_values_status (SocketTest)" do
    # A fake Compute.Engine collaborator mirroring the API the channel uses:
    # apply_config/2 (records the call) + status/1.
    defmodule FakeCompute do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts) do
        {:ok,
         %{
           parent: Keyword.fetch!(opts, :parent),
           status: Keyword.get(opts, :status, %{applied_version: 0, active_count: 2}),
           apply_result: Keyword.get(opts, :apply_result, {:ok, %{version: 0}})
         }}
      end

      def apply_config(server, config), do: GenServer.call(server, {:apply_config, config})
      def status(server), do: GenServer.call(server, :status)

      @impl true
      def handle_call({:apply_config, config}, _from, state) do
        send(state.parent, {:apply_computed_called, config})
        {:reply, state.apply_result, state}
      end

      def handle_call(:status, _from, state), do: {:reply, state.status, state}
    end

    # A fake Compute.Broadcaster collaborator: broadcasting?/1 returns a fixed bool.
    defmodule FakeBroadcaster do
      use Agent

      def start_link(opts), do: Agent.start_link(fn -> Keyword.get(opts, :broadcasting?, false) end)
      def broadcasting?(agent), do: Agent.get(agent, & &1)
    end

    defp connect_compute_client(ctx, compute_opts) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, compute} = start_supervised({FakeCompute, [parent: self()] ++ compute_opts})

      {:ok, broadcaster} =
        start_supervised({FakeBroadcaster, broadcasting?: Keyword.get(compute_opts, :broadcasting?, false)})

      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           compute: {FakeCompute, compute},
           compute_broadcaster: {FakeBroadcaster, broadcaster},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      {client, topic, compute}
    end

    test "server set_computed_values → apply_config called + computed_values_status pushed", ctx do
      {client, topic, _compute} =
        connect_compute_client(ctx,
          apply_result: {:ok, %{version: 3}},
          status: %{applied_version: 3, active_count: 2}
        )

      push(client, topic, "set_computed_values", %{
        "version" => 3,
        "values" => [
          %{
            "id" => "abc",
            "name" => "AWS x2",
            "definition_type" => "expression",
            "library_key" => nil,
            "input_bindings" => %{},
            "rpn" => [%{"signal" => "apparent_wind_speed"}, %{"const" => 2.0}, %{"op" => "*"}],
            "signals" => ["apparent_wind_speed"],
            "output_pgn" => 128_259,
            "output_field" => "speed_water_referenced",
            "output_reference" => nil,
            "output_unit" => "m/s",
            "output_instance" => nil,
            "damping_seconds" => 0.5,
            "broadcast_rate_hz" => 2.0,
            "broadcast_enabled" => true,
            "stream_to_backend" => true
          }
        ]
      })

      assert_receive {:apply_computed_called, config}
      assert config["version"] == 3
      assert [value] = config["values"]
      assert value["id"] == "abc"

      assert_push(^topic, "computed_values_status", status)
      assert status.applied_version == 3
      assert status.active_count == 2
      assert Map.has_key?(status, :reported_at)
      # broadcasting reflects the Compute.Broadcaster (default fake: not broadcasting).
      assert status.broadcasting == false
    end

    test "computed_values_status reports broadcasting=true when the broadcaster is active", ctx do
      {client, topic, _compute} =
        connect_compute_client(ctx,
          apply_result: {:ok, %{version: 1}},
          status: %{applied_version: 1, active_count: 1},
          broadcasting?: true
        )

      push(client, topic, "set_computed_values", %{"version" => 1, "values" => []})

      assert_receive {:apply_computed_called, _config}
      assert_push(^topic, "computed_values_status", status)
      assert status.broadcasting == true
    end

    test "set_computed_values apply error → still pushes status (no crash)", ctx do
      {client, topic, _compute} =
        connect_compute_client(ctx,
          apply_result: {:error, :malformed},
          status: %{applied_version: 0, active_count: 0}
        )

      push(client, topic, "set_computed_values", %{"version" => 9, "values" => "bad"})

      assert_receive {:apply_computed_called, _config}
      assert_push(^topic, "computed_values_status", status)
      assert Map.has_key?(status, :active_count)
      assert Map.has_key?(status, :applied_version)
      assert Process.alive?(client)
    end
  end

  # --- computed-value streamback (Phase 10): send_computed_values_data/2 ---

  describe "send_computed_values_data (SocketTest)" do
    # Bring a client all the way to a LIVE session (handshake complete) so a
    # subsequent streamback push has a joined topic + session to push over. A fake
    # WiFi collaborator is injected so the post-handshake :report_wifi_status read does
    # not depend on a real (target-only) WiFiManager.
    # A minimal WiFi collaborator: current_status/1 returns a canned status so the
    # post-handshake :report_wifi_status read never depends on a real WiFiManager.
    defmodule StreamFakeWiFi do
      use Agent

      def start_link(_opts),
        do: Agent.start_link(fn -> %{enabled: false, ssid: nil, connection: :disconnected, signal: nil} end)

      def current_status(agent), do: Agent.get(agent, & &1)
    end

    defp connect_live(ctx) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, wifi} = start_supervised(StreamFakeWiFi)
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           wifi: {StreamFakeWiFi, wifi},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)

      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)
      {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)
      push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})

      # handshake_ok triggers an initial :report_wifi_status push; drain it so the
      # client isn't blocked on that synchronous push when the streamback arrives.
      assert_push(^topic, "wifi_status", _wifi)

      assert eventually(fn -> SessionHolder.live?(holder) end)
      {client, topic}
    end

    test "pushes computed_values_data over the channel when a session is live", ctx do
      {client, topic} = connect_live(ctx)

      values = [%{id: "abc", value: 12.3}, %{id: "def", value: 4.0}]
      assert :ok = ChannelClient.send_computed_values_data(client, values)

      assert_push(^topic, "computed_values_data", payload)
      assert payload.values == values
      # No batch/per-sample timestamp — the server stamps receipt time.
      refute Map.has_key?(payload, :at)
    end

    test "no-ops (no push) when there is no live session", ctx do
      # An idle client (never connected/handshaked) has no joined topic — streamback
      # must be a best-effort no-op, exactly like telemetry is dropped with no session.
      client =
        start_supervised!({ChannelClient, name: nil, auto_connect?: false, keystore_opts: [base_path: ctx.base]})

      assert :ok = ChannelClient.send_computed_values_data(client, [%{id: "abc", value: 1.0}])
      # The conceptual server must NOT receive any streamback push.
      refute_push("computed_values_data", _payload, 50)
      assert Process.alive?(client)
    end

    test "no-ops safely when the target process is not running" do
      # Best-effort: a streamback to a dead/unregistered name never raises.
      assert :ok = ChannelClient.send_computed_values_data(:no_such_channel_client, [%{id: "x", value: 1.0}])
    end
  end

  # --- route-deviation recalc (P3): request_route_recalc over the channel ---

  describe "request_route_recalc (SocketTest)" do
    # Bring a client to a LIVE session, reusing the streamback fakes/flow.
    defmodule RecalcFakeWiFi do
      use Agent

      def start_link(_opts),
        do: Agent.start_link(fn -> %{enabled: false, ssid: nil, connection: :disconnected, signal: nil} end)

      def current_status(agent), do: Agent.get(agent, & &1)
    end

    defp connect_live_recalc(ctx) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, wifi} = start_supervised(RecalcFakeWiFi)
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           wifi: {RecalcFakeWiFi, wifi},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)

      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)
      {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)
      push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})

      assert_push(^topic, "wifi_status", _wifi)
      assert eventually(fn -> SessionHolder.live?(holder) end)
      {client, topic}
    end

    test "pushes request_route_recalc with the current position when a session is live", ctx do
      {client, topic} = connect_live_recalc(ctx)

      assert :ok = ChannelClient.request_route_recalc(client, {42.5, -70.83})

      assert_push(^topic, "request_route_recalc", payload)
      assert payload.position.latitude == 42.5
      assert payload.position.longitude == -70.83
    end

    test "pushes request_route_recalc with no position when none is available", ctx do
      {client, topic} = connect_live_recalc(ctx)

      assert :ok = ChannelClient.request_route_recalc(client, nil)

      assert_push(^topic, "request_route_recalc", payload)
      # The server resolves the device→active race + position from telemetry, so an
      # absent position is a valid (empty) request, never a crash.
      refute Map.has_key?(payload, :position)
    end

    test "no-ops (no push) when there is no live session", ctx do
      client =
        start_supervised!({ChannelClient, name: nil, auto_connect?: false, keystore_opts: [base_path: ctx.base]})

      assert :ok = ChannelClient.request_route_recalc(client, {42.0, -71.0})
      refute_push("request_route_recalc", _payload, 50)
      assert Process.alive?(client)
    end

    test "no-ops safely when the target process is not running" do
      assert :ok = ChannelClient.request_route_recalc(:no_such_channel_client, {42.0, -71.0})
    end
  end

  # --- sailed-polar streamback (Phase 4): send_sailed_polar_update/2 ---

  describe "send_sailed_polar_update (SocketTest)" do
    defmodule SailedFakeWiFi do
      use Agent

      def start_link(_opts),
        do: Agent.start_link(fn -> %{enabled: false, ssid: nil, connection: :disconnected, signal: nil} end)

      def current_status(agent), do: Agent.get(agent, & &1)
    end

    defp connect_live_sailed(ctx) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, wifi} = start_supervised(SailedFakeWiFi)
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           wifi: {SailedFakeWiFi, wifi},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)

      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)
      {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)
      push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})

      assert_push(^topic, "wifi_status", _wifi)
      assert eventually(fn -> SessionHolder.live?(holder) end)
      {client, topic}
    end

    test "pushes sailed_polar_update over the channel when a session is live", ctx do
      {client, topic} = connect_live_sailed(ctx)

      update = %{
        boat_identifier: "boat-42",
        seq: 7,
        cells: [%{tws_mps: 4.9, twa_deg: 52.5, boat_speed_mps: 4.0, count: 12}]
      }

      assert :ok = ChannelClient.send_sailed_polar_update(client, update)

      assert_push(^topic, "sailed_polar_update", payload)
      assert payload.boat_identifier == "boat-42"
      assert payload.seq == 7
      assert [%{tws_mps: 4.9, twa_deg: 52.5, boat_speed_mps: 4.0, count: 12}] = payload.cells
    end

    test "no-ops (no push) when there is no live session", ctx do
      client =
        start_supervised!({ChannelClient, name: nil, auto_connect?: false, keystore_opts: [base_path: ctx.base]})

      update = %{
        boat_identifier: "boat-42",
        seq: 1,
        cells: [%{tws_mps: 4.9, twa_deg: 52.5, boat_speed_mps: 4.0, count: 1}]
      }

      assert :ok = ChannelClient.send_sailed_polar_update(client, update)
      refute_push("sailed_polar_update", _payload, 50)
      assert Process.alive?(client)
    end

    test "no-ops safely when the target process is not running" do
      update = %{boat_identifier: "boat-42", seq: 1, cells: []}
      assert :ok = ChannelClient.send_sailed_polar_update(:no_such_channel_client, update)
    end
  end

  # --- calibration streamback (auto-calibration): send_calibration_update/2 ---

  describe "send_calibration_update (SocketTest)" do
    defmodule CalibrationFakeWiFi do
      use Agent

      def start_link(_opts),
        do: Agent.start_link(fn -> %{enabled: false, ssid: nil, connection: :disconnected, signal: nil} end)

      def current_status(agent), do: Agent.get(agent, & &1)
    end

    defp connect_live_calibration(ctx) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, wifi} = start_supervised(CalibrationFakeWiFi)
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           wifi: {CalibrationFakeWiFi, wifi},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)

      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)
      {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)
      push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})

      assert_push(^topic, "wifi_status", _wifi)
      assert eventually(fn -> SessionHolder.live?(holder) end)
      {client, topic}
    end

    test "pushes calibration_update over the channel when a session is live", ctx do
      {client, topic} = connect_live_calibration(ctx)

      update = %{
        boat_identifier: "boat-42",
        seq: 3,
        entries: [
          %{
            hardware_identifier: "1A2B",
            parameter: "awa_offset",
            value: 2.5,
            confidence: 1.0,
            sample_count: 9,
            state: "applied",
            residual: 0.1
          },
          %{
            hardware_identifier: "3C4D",
            parameter: "stw_scale",
            value: 1.05,
            confidence: 0.9,
            sample_count: 7,
            state: "applied",
            residual: 0.01,
            curve: [%{center: 1, gain: 1.05}]
          }
        ]
      }

      assert :ok = ChannelClient.send_calibration_update(client, update)

      assert_push(^topic, "calibration_update", payload)
      assert payload.boat_identifier == "boat-42"
      assert payload.seq == 3
      assert [awa, stw] = payload.entries
      assert awa.parameter == "awa_offset"
      assert awa.state == "applied"
      assert stw.parameter == "stw_scale"
      assert stw.curve == [%{center: 1, gain: 1.05}]
    end

    test "an empty-entries update is not pushed", ctx do
      {client, _topic} = connect_live_calibration(ctx)

      assert :ok = ChannelClient.send_calibration_update(client, %{boat_identifier: "boat-42", seq: 1, entries: []})
      refute_push("calibration_update", _payload, 50)
    end

    test "no-ops (no push) when there is no live session", ctx do
      client =
        start_supervised!({ChannelClient, name: nil, auto_connect?: false, keystore_opts: [base_path: ctx.base]})

      update = %{
        boat_identifier: "boat-42",
        seq: 1,
        entries: [
          %{
            hardware_identifier: "1A2B",
            parameter: "awa_offset",
            value: 2.5,
            confidence: 1.0,
            sample_count: 9,
            state: "applied",
            residual: 0.1
          }
        ]
      }

      assert :ok = ChannelClient.send_calibration_update(client, update)
      refute_push("calibration_update", _payload, 50)
      assert Process.alive?(client)
    end

    test "no-ops safely when the target process is not running" do
      update = %{boat_identifier: "boat-42", seq: 1, entries: []}
      assert :ok = ChannelClient.send_calibration_update(:no_such_channel_client, update)
    end
  end

  # --- wind-shift streamback: send_wind_shift_update/2 ---

  describe "send_wind_shift_update (SocketTest)" do
    defmodule WindShiftFakeWiFi do
      use Agent

      def start_link(_opts),
        do: Agent.start_link(fn -> %{enabled: false, ssid: nil, connection: :disconnected, signal: nil} end)

      def current_status(agent), do: Agent.get(agent, & &1)
    end

    defp connect_live_wind_shift(ctx) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, wifi} = start_supervised(WindShiftFakeWiFi)
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           wifi: {WindShiftFakeWiFi, wifi},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)

      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)
      {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)
      push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})

      assert_push(^topic, "wifi_status", _wifi)
      assert eventually(fn -> SessionHolder.live?(holder) end)
      {client, topic}
    end

    defp wind_shift_update(overrides \\ %{}) do
      Map.merge(
        %{
          boat_identifier: "boat-42",
          seq: 4,
          session: %{
            started_at_ms: 1_784_800_800_000,
            centroid: %{lat: 41.0, lon: -71.0},
            race_session_id: nil,
            summary: %{
              mean_twd_deg: 201.5,
              trend_deg_per_hr: nil,
              oscillation_period_s: 480.0,
              oscillation_amplitude_deg: 9.5,
              regime: "oscillating",
              tws_mean_mps: 6.1
            }
          },
          timeline: [
            %{
              t_ms: 1_784_800_860_000,
              mean_twd_deg: 201.5,
              phase_deg: 3.0,
              amplitude_deg: 9.5,
              period_s: 480.0,
              trend_deg_per_hr: nil,
              tws_mps: 6.1
            }
          ],
          events: [
            %{
              t_ms: 1_784_800_870_000,
              kind: "header_extreme",
              twd_deg: 192.0,
              magnitude_deg: 9.5,
              detail: %{phase_deg: -9.5}
            }
          ]
        },
        overrides
      )
    end

    test "pushes wind_shift_update over the channel when a session is live", ctx do
      {client, topic} = connect_live_wind_shift(ctx)

      assert :ok = ChannelClient.send_wind_shift_update(client, wind_shift_update())

      assert_push(^topic, "wind_shift_update", payload)
      assert payload.boat_identifier == "boat-42"
      assert payload.seq == 4
      assert payload.session.started_at_ms == 1_784_800_800_000
      assert payload.session.summary.regime == "oscillating"
      assert [%{mean_twd_deg: 201.5}] = payload.timeline
      assert [%{kind: "header_extreme"}] = payload.events
    end

    test "a summary-only update (empty timeline/events, session present) still pushes", ctx do
      {client, topic} = connect_live_wind_shift(ctx)

      assert :ok = ChannelClient.send_wind_shift_update(client, wind_shift_update(%{timeline: [], events: []}))
      assert_push(^topic, "wind_shift_update", payload)
      assert payload.timeline == []
      assert payload.events == []
    end

    test "a degenerate empty update (no session, nothing pending) is not pushed", ctx do
      {client, _topic} = connect_live_wind_shift(ctx)

      update = %{boat_identifier: "boat-42", seq: 1, session: nil, timeline: [], events: []}
      assert :ok = ChannelClient.send_wind_shift_update(client, update)
      refute_push("wind_shift_update", _payload, 50)
    end

    test "no-ops (no push) when there is no live session", ctx do
      client =
        start_supervised!({ChannelClient, name: nil, auto_connect?: false, keystore_opts: [base_path: ctx.base]})

      assert :ok = ChannelClient.send_wind_shift_update(client, wind_shift_update())
      refute_push("wind_shift_update", _payload, 50)
      assert Process.alive?(client)
    end

    test "no-ops safely when the target process is not running" do
      assert :ok = ChannelClient.send_wind_shift_update(:no_such_channel_client, wind_shift_update())
    end
  end

  defp start_control_client(ctx, extra_opts \\ []) do
    test_pid = self()
    {:ok, holder} = start_supervised({SessionHolder, name: nil})
    topic = "device:" <> ctx.identity.fingerprint

    opts =
      Keyword.merge(
        [
          name: nil,
          auto_connect?: true,
          test_mode?: true,
          url: "wss://test.local/device_socket/websocket",
          session_holder: holder,
          firmware_validator: fn -> :ok end,
          desired_state_identity: fn -> {:ok, control_identity(@control_epoch)} end,
          desired_state_compatibility: fn ->
            %{
              firmware_version: "0.7.0",
              firmware_git_sha: "0123abc",
              capabilities:
                Enum.map(DesiredStateV1.capabilities(), fn {name, _id, version} ->
                  {name, version}
                end)
            }
          end,
          desired_state_status: fn -> %{active: nil} end,
          checkpoint_pending: fn _outbox, _opts -> [] end,
          delivery_pending: fn _outbox, opts ->
            send(test_pid, {:delivery_pending, opts})
            []
          end,
          keystore_opts: [base_path: ctx.base]
        ],
        extra_opts
      )

    client = start_supervised!({ChannelClient, opts})
    connect_and_assert_join(client, ^topic, %{}, :ok)
    {client, holder, topic}
  end

  defp push_control_accept(client, topic, server_control, overrides \\ %{}) do
    offer = %{control_versions: [1], desired_state_versions: [1]}
    {:ok, selection} = Negotiation.select(offer)

    attrs =
      %{
        device_id: @logical_device_id,
        credential_epoch: @control_epoch,
        selected_control_version: selection.selected_control_version,
        selected_desired_version: selection.selected_desired_version,
        offer_hash: selection.offer_hash
      }
      |> Map.merge(overrides)

    {:ok, bytes} = Messages.encode(:control_accept, attrs)
    {:ok, frame, server_control} = Control.seal(server_control, :control_accept, bytes)
    push(client, topic, "control_v1", Control.encode_carrier(frame))
    {server_control, frame}
  end

  defp control_identity(credential_epoch) do
    %{
      device_id: @logical_device_id,
      credential_epoch: credential_epoch,
      boot_id: @boot_id,
      storage_epoch: @storage_epoch
    }
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
