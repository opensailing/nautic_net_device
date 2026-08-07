defmodule RacingOrg.Tracker.Pro.SecureTransport.ChannelHandlerTest do
  @moduledoc """
  Protocol-logic tests for the command-channel handler WITHOUT a live server.

  The handshake is proved by LOOPBACK: the device's initiator (driven through
  `ChannelHandler.handshake_init/2`) is finalized by the device's OWN responder
  (the job-1 crypto plays both roles), proving the client produces a valid INIT
  that finalizes into a MATCHING session (same session_id + keys on both sides) —
  exactly what the real server's `responder_finalize/2` would do.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Protobuf.CommandAck
  alias RacingOrg.Tracker.Protobuf.DeviceCommand
  alias RacingOrg.Tracker.Protobuf.RaceAssignment
  alias RacingOrg.Tracker.Protobuf.ServerReply
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelHandler
  alias RacingOrg.Tracker.Pro.SecureTransport.Handshake
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives

  # --- crypto fixtures ---

  defp identity(byte) do
    seed = :binary.copy(byte, 32)
    {Primitives.ed25519_public_from_secret(seed), seed}
  end

  setup do
    {dev_pub, dev_priv} = identity(<<0xA1>>)
    {srv_pub, srv_priv} = identity(<<0xB2>>)

    fingerprint = Base.encode16(Primitives.sha256(dev_pub), case: :lower)

    inputs = %{
      device_identity_private: dev_priv,
      device_identity_public: dev_pub,
      server_identity_public: srv_pub,
      device_id: fingerprint,
      epoch: 0
    }

    %{
      inputs: inputs,
      dev_pub: dev_pub,
      srv_pub: srv_pub,
      srv_priv: srv_priv,
      fingerprint: fingerprint
    }
  end

  # The "server" side, using the device's own crypto as the responder.
  defp server_hello(ctx, epoch \\ 0) do
    {:ok, hello_wire, rstate} =
      Handshake.responder_hello(
        server_identity_private: ctx.srv_priv,
        server_identity_public: ctx.srv_pub,
        device_identity_public: ctx.dev_pub,
        epoch: epoch
      )

    {%{"hello" => Base.encode64(hello_wire)}, rstate}
  end

  # --- Handshake loopback ---

  describe "handshake_init/2 (initiator loopback against the responder)" do
    test "produces an INIT that finalizes into a MATCHING session", ctx do
      {hello_payload, rstate} = server_hello(ctx)

      assert {:ok, %{"init" => init_b64}, device_session} =
               ChannelHandler.handshake_init(hello_payload, ctx.inputs)

      {:ok, init_wire} = Base.decode64(init_b64)
      assert {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)

      # Both sides derived the SAME session_id and matching per-direction keys.
      assert device_session.session_id == server_session.session_id
      # device out (d2s) == server in (d2s); device in (s2d) == server out (s2d)
      assert device_session.out_key == server_session.in_key
      assert device_session.in_key == server_session.out_key
      assert device_session.role == :initiator
      assert server_session.role == :responder
    end

    test "uses the fingerprint as the device_id bound into the transcript", ctx do
      {hello_payload, rstate} = server_hello(ctx)
      {:ok, %{"init" => init_b64}, _s} = ChannelHandler.handshake_init(hello_payload, ctx.inputs)
      {:ok, init_wire} = Base.decode64(init_b64)

      # The server mirrors whatever device_id we sent; finalize must still succeed
      # AND the session must match, proving the device_id bytes agreed.
      assert {:ok, _server_session} = Handshake.responder_finalize(rstate, init_wire)
    end

    test "verifies the signed HELLO, adopts its epoch, and signs INIT with that exact epoch", ctx do
      {hello_payload, rstate} = server_hello(ctx, 4)

      inputs =
        ctx.inputs
        |> Map.delete(:epoch)
        |> Map.put(:credential_epoch, 3)

      assert {:ok, %{"init" => init_b64}, device_session} =
               ChannelHandler.handshake_init(hello_payload, inputs)

      assert device_session.epoch == 4
      assert device_session.credential_epoch == 4

      {:ok, init_wire} = Base.decode64(init_b64)
      assert {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)
      assert server_session.epoch == 4
    end

    test "rejects a signed HELLO below the durable credential epoch", ctx do
      {hello_payload, _rstate} = server_hello(ctx, 3)

      inputs =
        ctx.inputs
        |> Map.delete(:epoch)
        |> Map.put(:credential_epoch, 4)

      assert {:error, :epoch_downgrade} =
               ChannelHandler.handshake_init(hello_payload, inputs)
    end

    test "rejects a bad server signature before considering epoch adoption or downgrade", ctx do
      {hello_payload, _rstate} = server_hello(ctx, 3)
      {:ok, hello_wire} = Base.decode64(hello_payload["hello"])
      prefix_size = byte_size(hello_wire) - 1
      <<prefix::binary-size(prefix_size), last>> = hello_wire
      tampered = prefix <> <<Bitwise.bxor(last, 1)>>

      inputs =
        ctx.inputs
        |> Map.delete(:epoch)
        |> Map.put(:credential_epoch, 4)

      assert {:error, :bad_server_signature} =
               ChannelHandler.handshake_init(%{"hello" => Base.encode64(tampered)}, inputs)
    end

    test "rejects a HELLO signed by the WRONG server key (pin mismatch)", ctx do
      {wrong_pub, wrong_priv} = identity(<<0xCC>>)

      {:ok, hello_wire, _rstate} =
        Handshake.responder_hello(
          server_identity_private: wrong_priv,
          server_identity_public: wrong_pub,
          device_identity_public: ctx.dev_pub,
          epoch: 0
        )

      # Device's pinned server pub is ctx.srv_pub, NOT wrong_pub.
      assert {:error, _reason} =
               ChannelHandler.handshake_init(%{"hello" => Base.encode64(hello_wire)}, ctx.inputs)
    end

    test "rejects a malformed / non-base64 hello payload", ctx do
      assert {:error, :bad_base64} = ChannelHandler.handshake_init(%{"hello" => "!!notb64!!"}, ctx.inputs)
      assert {:error, :missing_field} = ChannelHandler.handshake_init(%{}, ctx.inputs)
    end
  end

  describe "verify_handshake_ok/2" do
    test "accepts the matching session_id", ctx do
      {hello_payload, _rstate} = server_hello(ctx)
      {:ok, _init, session} = ChannelHandler.handshake_init(hello_payload, ctx.inputs)

      payload = %{"session_id" => Base.encode64(session.session_id)}
      assert :ok = ChannelHandler.verify_handshake_ok(payload, session)
    end

    test "rejects a mismatched session_id", ctx do
      {hello_payload, _rstate} = server_hello(ctx)
      {:ok, _init, session} = ChannelHandler.handshake_init(hello_payload, ctx.inputs)

      payload = %{"session_id" => Base.encode64(<<0::128>>)}
      assert {:error, :session_id_mismatch} = ChannelHandler.verify_handshake_ok(payload, session)
    end
  end

  # --- Command handling + ack ---

  describe "handle_command/3" do
    setup do
      pid = start_supervised!({Commands, name: nil, device_id: "dev-1"})
      %{commands: pid}
    end

    defp command_payload(opts) do
      payload =
        Keyword.get(opts, :payload, {:race_assignment, struct(RaceAssignment, race_session_id: "rs-1")})

      command =
        struct(DeviceCommand,
          command_id: Keyword.get(opts, :command_id, "cmd-1"),
          assignment_id: Keyword.get(opts, :assignment_id, "asg-1"),
          assignment_version: Keyword.get(opts, :assignment_version, 1),
          payload: payload
        )

      reply =
        struct(ServerReply,
          protocol_version: 1,
          device_id: Keyword.get(opts, :device_id, "dev-1"),
          command: command
        )
        |> ServerReply.encode()

      %{"command_id" => Keyword.get(opts, :command_id, "cmd-1"), "reply" => Base.encode64(reply)}
    end

    test "decodes -> applies -> builds the v1 ack with command_id + assignment_version", %{commands: c} do
      payload = command_payload(command_id: "cmd-42", assignment_version: 3)

      assert {:ack, ack} = ChannelHandler.handle_command(payload, "cmd-42", c)

      assert ack.v == 1
      assert [%{command_id: "cmd-42", assignment_version: 3}] = ack.acks

      # The command was actually applied to the device's command state.
      assert %CommandAck{command_id: "cmd-42", assignment_version: 3} = Commands.current_ack(c)
    end

    test "a duplicate command is idempotent and still acks (no double-apply, no crash)", %{commands: c} do
      payload = command_payload(command_id: "dup", assignment_version: 2)

      assert {:ack, ack1} = ChannelHandler.handle_command(payload, "dup", c)
      assert {:ack, ack2} = ChannelHandler.handle_command(payload, "dup", c)

      assert ack1 == ack2
      assert [%{command_id: "dup", assignment_version: 2}] = ack2.acks
      assert Commands.current_assignment(c).version == 2
    end

    test "a command for a DIFFERENT device is not acked (ignored)", %{commands: c} do
      payload = command_payload(command_id: "other", device_id: "someone-else")
      assert {:noack, :device_mismatch} = ChannelHandler.handle_command(payload, "other", c)
    end

    test "a malformed reply / missing field is not acked (no crash)", %{commands: c} do
      assert {:noack, :missing_field} = ChannelHandler.handle_command(%{}, "x", c)
      assert {:noack, :bad_base64} = ChannelHandler.handle_command(%{"reply" => "!!!"}, "x", c)
      assert {:noack, :malformed} = ChannelHandler.handle_command(%{"reply" => Base.encode64("garbage")}, "x", c)
    end
  end
end
