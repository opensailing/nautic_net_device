defmodule RacingOrg.Tracker.Pro.SecureTransport.ChannelClientGenericDeliveryTest do
  use Slipstream.SocketTest

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Entry
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient
  alias RacingOrg.Tracker.Pro.SecureTransport.Handshake
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Pro.SecureTransport, as: SecureTransport

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{
    Control,
    Messages,
    Negotiation
  }

  @device_id <<0xE1::128>>
  @storage_epoch <<0xE3::128>>
  @credential_epoch 7

  setup do
    base = Path.join(System.tmp_dir!(), "cc_generic_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

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

  test "the legacy direct desired-state ACK sender is removed" do
    Code.ensure_loaded!(ChannelClient)
    refute function_exported?(ChannelClient, :send_desired_state_ack, 1)
    refute function_exported?(ChannelClient, :send_desired_state_ack, 2)
  end

  describe "generic durable delivery dispatch" do
    test "readiness dispatches pending generic entries in priority/FIFO order without retiring", ctx do
      low = generic_entry(:telemetry, 1, priority: 1, ordinal: 3)
      high_first = generic_entry(:desired_state_ack, 2, priority: 9, ordinal: 1)
      high_second = generic_entry(:health, 3, priority: 9, ordinal: 2)
      owner = self()

      pending = fn outbox, opts ->
        send(owner, {:delivery_pending, outbox, opts})
        [low, high_second, high_first]
      end

      {client, _id, topic, server_control, _holder} =
        start_generic_client(ctx,
          outbox: :generic_outbox,
          delivery_pending: pending
        )

      assert_receive {:delivery_pending, :generic_outbox, _opts}, 1_000

      frames =
        Enum.map_reduce(1..6, server_control, fn _index, control ->
          {control, frame} = receive_control(topic, control)
          {frame, control}
        end)
        |> elem(0)

      assert Enum.map(frames, &{&1.type, &1.attrs.sequence}) == [
               {:delivery_submission, 2},
               {:delivery_payload, 2},
               {:delivery_submission, 3},
               {:delivery_payload, 3},
               {:delivery_submission, 1},
               {:delivery_payload, 1}
             ]

      assert Enum.map(frames, & &1.attrs.stream) == [
               :desired_state_ack,
               :desired_state_ack,
               :health,
               :health,
               :telemetry,
               :telemetry
             ]

      for %{type: :delivery_payload, attrs: attrs} <- frames do
        assert :crypto.hash(:sha256, attrs.payload) == attrs.payload_hash
      end

      assert Process.alive?(client)
    end

    test "checkpoint entries are never planned by the generic dispatcher", ctx do
      checkpoint = %{generic_entry(:telemetry, 7, priority: 9, ordinal: 1) | stream: :checkpoint}
      generic = generic_entry(:health, 8, priority: 1, ordinal: 2)
      owner = self()

      planner = fn entry ->
        send(owner, {:delivery_plan, entry.stream, entry.sequence})
        {:ok, %{entry: entry, payload: nil, frames: [submission_frame(entry)]}}
      end

      {client, _id, topic, server_control, _holder} =
        start_generic_client(ctx,
          delivery_pending: fn _outbox, _opts -> [checkpoint, generic] end,
          delivery_planner: planner
        )

      {_server_control, frame} = receive_control(topic, server_control)
      assert frame.type == :delivery_submission
      assert frame.attrs.stream == :health

      assert_received {:delivery_plan, :health, 8}
      refute_received {:delivery_plan, :checkpoint, _sequence}
      assert Process.alive?(client)
    end

    test "stops at a planner failure and leaves later generic entries pending", ctx do
      first = generic_entry(:desired_state_ack, 1, priority: 9, ordinal: 1)
      later = generic_entry(:health, 2, priority: 1, ordinal: 2)
      owner = self()

      planner = fn
        %Entry{sequence: 1} = entry ->
          send(owner, {:delivery_plan_failed, entry.sequence})
          {:error, :delivery_unavailable}

        entry ->
          send(owner, {:unexpected_delivery_plan, entry.sequence})
          {:ok, %{entry: entry, payload: nil, frames: [submission_frame(entry)]}}
      end

      {client, _id, topic, _server_control, _holder} =
        start_generic_client(ctx,
          delivery_pending: fn _outbox, _opts -> [later, first] end,
          delivery_planner: planner
        )

      assert_receive {:delivery_plan_failed, 1}
      refute_receive {:unexpected_delivery_plan, _sequence}, 100
      refute_push(^topic, "control_v1", _carrier, 50)
      assert Process.alive?(client)
    end

    test "stops after an outbound frame failure without planning later entries", ctx do
      first = generic_entry(:desired_state_ack, 4, priority: 9, ordinal: 1)
      later = generic_entry(:health, 5, priority: 1, ordinal: 2)
      owner = self()

      planner = fn
        %Entry{sequence: 4} = entry ->
          send(owner, {:delivery_send_plan, entry.sequence})
          {:ok, %{entry: entry, payload: nil, frames: frames(entry)}}

        entry ->
          send(owner, {:unexpected_delivery_plan, entry.sequence})
          {:ok, %{entry: entry, payload: nil, frames: frames(entry)}}
      end

      {client, _id, topic, server_control, holder} =
        start_generic_client(ctx,
          accept_control?: false,
          delivery_pending: fn _outbox, _opts -> [first, later] end,
          delivery_planner: planner
        )

      :sys.replace_state(holder, fn state ->
        %{state | control: %{state.control | send_counter: SecureTransport.rekey_after() - 2}}
      end)

      server_control = accept_control(client, topic, server_control)
      {_server_control, submission} = receive_control(topic, server_control)
      assert submission.type == :delivery_submission
      assert submission.attrs.sequence == 4
      assert_disconnect()

      assert_received {:delivery_send_plan, 4}
      refute_receive {:unexpected_delivery_plan, _sequence}, 100
      assert Process.alive?(client)
    end

    test "a dispatch kick also retransmits still-pending checkpoint submissions", ctx do
      owner = self()
      counter = :counters.new(1, [])

      checkpoint_pending = fn _outbox, opts ->
        :counters.add(counter, 1, 1)
        send(owner, {:checkpoint_pending_call, :counters.get(counter, 1), opts})
        []
      end

      {client, _id, _topic, _server_control, _holder} =
        start_generic_client(ctx, checkpoint_pending: checkpoint_pending)

      assert_receive {:checkpoint_pending_call, 1, [stream: :checkpoint]}

      assert :ok = ChannelClient.dispatch_durable_deliveries(client)
      assert_receive {:checkpoint_pending_call, 2, [stream: :checkpoint]}
    end

    test "a dispatch kick after readiness retransmits still-pending entries", ctx do
      entry = generic_entry(:health, 6, priority: 1, ordinal: 1)
      owner = self()
      counter = :counters.new(1, [])

      pending = fn _outbox, _opts ->
        :counters.add(counter, 1, 1)
        send(owner, {:delivery_pending_call, :counters.get(counter, 1)})
        [entry]
      end

      {client, _id, topic, server_control, _holder} =
        start_generic_client(ctx, delivery_pending: pending)

      assert_receive {:delivery_pending_call, 1}
      {server_control, first_submission} = receive_control(topic, server_control)
      {server_control, _first_payload} = receive_control(topic, server_control)
      assert first_submission.type == :delivery_submission

      assert :ok = ChannelClient.dispatch_durable_deliveries(client)
      assert_receive {:delivery_pending_call, 2}
      {server_control, second_submission} = receive_control(topic, server_control)
      {_server_control, second_payload} = receive_control(topic, server_control)
      assert second_submission.type == :delivery_submission
      assert second_payload.type == :delivery_payload
      assert second_payload.attrs.sequence == 6
    end
  end

  defp frames(entry) do
    [
      submission_frame(entry),
      %{
        type: :delivery_payload,
        attrs: %{
          device_id: entry.device_id,
          credential_epoch: entry.credential_epoch,
          storage_epoch: entry.storage_epoch,
          stream: entry.stream,
          sequence: entry.sequence,
          payload_hash: entry.payload_hash,
          payload: entry.payload
        }
      }
    ]
  end

  defp submission_frame(entry) do
    %{
      type: :delivery_submission,
      attrs: %{
        device_id: entry.device_id,
        credential_epoch: entry.credential_epoch,
        storage_epoch: entry.storage_epoch,
        stream: entry.stream,
        sequence: entry.sequence,
        payload_hash: entry.payload_hash
      }
    }
  end

  defp generic_entry(stream, sequence, opts) do
    payload = "durable-#{stream}-#{sequence}"

    %Entry{
      stream: stream,
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      sequence: sequence,
      entry_id: <<sequence::128>>,
      payload_hash: :crypto.hash(:sha256, payload),
      payload_checksum: :crypto.hash(:sha256, payload),
      payload: payload,
      priority: Keyword.fetch!(opts, :priority),
      encoded_size: byte_size(payload) + 128,
      ordinal: Keyword.fetch!(opts, :ordinal)
    }
  end

  defp start_generic_client(ctx, opts) do
    accept_control? = Keyword.get(opts, :accept_control?, true)
    id = {:generic_channel_client, System.unique_integer([:positive])}
    holder_id = {:generic_session_holder, System.unique_integer([:positive])}
    {:ok, holder} = start_supervised({SessionHolder, name: nil}, id: holder_id)
    topic = "device:" <> ctx.identity.fingerprint

    defaults = [
      name: nil,
      auto_connect?: true,
      test_mode?: true,
      url: "wss://test.local/device_socket/websocket",
      session_holder: holder,
      boot_provisioner: {FakeBootstrap, :generic_bootstrap},
      desired_state_identity: fn -> {:ok, control_identity()} end,
      desired_state_compatibility: fn ->
        %{
          firmware_version: "0.7.0",
          firmware_git_sha: "0123abc",
          capabilities: []
        }
      end,
      desired_state_status: fn -> %{active: nil} end,
      checkpoint_pending: fn _outbox, _opts -> [] end,
      checkpoint_planner: fn _entry -> {:error, :unexpected_checkpoint_entry} end,
      delivery_pending: fn _outbox, _opts -> [] end,
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
    assert_push(^topic, "control_v1", carrier, _ref, 2_000)
    assert {:ok, frame} = Control.decode_carrier(carrier)
    assert {:ok, type, bytes, server_control} = Control.open(server_control, frame)
    assert {:ok, attrs} = Messages.decode(type, bytes)
    {server_control, %{type: type, attrs: attrs}}
  end

  defp control_identity do
    %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      boot_id: <<0xE2::128>>,
      storage_epoch: @storage_epoch
    }
  end
end
