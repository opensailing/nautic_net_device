defmodule RacingOrg.Tracker.Pro.SecureTransport.HandshakeTest do
  @moduledoc """
  Self-interop: the DEVICE plays BOTH roles (initiator + responder) so a full handshake
  completes locally and a Frame sealed on one side opens on the other. Exercised at
  epoch 0 and a non-zero epoch, with random-plaintext round-trips (including empty).
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.IdentityProviderTestSupport
  alias RacingOrg.Tracker.Pro.SecureTransport.{Frame, Handshake, Primitives}

  setup do
    {dev_pub, dev_priv} = identity(<<0xA1>>)
    {srv_pub, srv_priv} = identity(<<0xB2>>)

    %{
      dev_pub: dev_pub,
      dev_priv: dev_priv,
      srv_pub: srv_pub,
      srv_priv: srv_priv,
      device_id: "device-self-interop"
    }
  end

  defp identity(byte), do: gen_ed25519(byte)

  defp gen_ed25519(byte) do
    seed = :binary.copy(byte, 32)
    {Primitives.ed25519_public_from_secret(seed), seed}
  end

  # Drive a full handshake (device as both roles). Returns {dsession, ssession}.
  defp full_handshake(ctx, opts \\ []) do
    epoch = Keyword.get(opts, :epoch, 0)
    resp_extra = Keyword.get(opts, :resp, [])
    init_extra = Keyword.get(opts, :init, [])

    {:ok, hello, rstate} =
      Handshake.responder_hello(
        [
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.dev_pub,
          epoch: epoch
        ] ++ resp_extra
      )

    {:ok, init, dsession} =
      Handshake.initiator_init(
        hello,
        [
          device_identity_private: ctx.dev_priv,
          device_identity_public: ctx.dev_pub,
          server_identity_public: ctx.srv_pub,
          device_id: ctx.device_id,
          epoch: epoch
        ] ++ init_extra
      )

    {:ok, ssession} = Handshake.responder_finalize(rstate, init)
    {dsession, ssession}
  end

  describe "full handshake (device as both roles)" do
    for epoch <- [0, 5] do
      test "matching keys + session_id on both sides at epoch #{epoch}", ctx do
        {d, s} = full_handshake(ctx, epoch: unquote(epoch))

        assert d.epoch == unquote(epoch)
        assert s.epoch == unquote(epoch)
        assert d.session_id == s.session_id
        assert byte_size(d.session_id) == 16
        assert d.transcript_hash == s.transcript_hash

        # initiator out = k_d2s = responder in; initiator in = k_s2d = responder out.
        assert d.out_key == s.in_key
        assert d.in_key == s.out_key
        # Per-direction keys differ.
        assert d.out_key != d.in_key
      end
    end

    test "same ephemerals/nonce at different epochs derive DIFFERENT keys + session_id", ctx do
      {e_s_pub, e_s_priv} = Primitives.generate_ephemeral_keypair()
      {e_d_pub, e_d_priv} = Primitives.generate_ephemeral_keypair()
      nonce = :crypto.strong_rand_bytes(32)

      run = fn epoch ->
        full_handshake(ctx,
          epoch: epoch,
          resp: [ephemeral: {e_s_pub, e_s_priv}, server_nonce: nonce],
          init: [ephemeral: {e_d_pub, e_d_priv}, timestamp_ms: 1]
        )
      end

      {d0, _} = run.(0)
      {d5, _} = run.(5)

      assert d0.session_id != d5.session_id
      assert d0.out_key != d5.out_key
      assert d0.in_key != d5.in_key
    end

    test "two fresh handshakes of the same identities derive DISTINCT keys (FS)", ctx do
      {d1, _} = full_handshake(ctx)
      {d2, _} = full_handshake(ctx)
      assert d1.out_key != d2.out_key
      assert d1.session_id != d2.session_id
    end

    test "operational signer and deterministic raw-seed paths produce byte-identical INIT", ctx do
      assert {:ok, identity} = IdentityProviderTestSupport.identity_from_seed(ctx.dev_priv)
      {server_ephemeral_public, server_ephemeral_private} = Primitives.generate_ephemeral_keypair()
      {device_ephemeral_public, device_ephemeral_private} = Primitives.generate_ephemeral_keypair()
      server_nonce = :binary.copy(<<0x77>>, 32)

      assert {:ok, hello, responder_state} =
               Handshake.responder_hello(
                 server_identity_private: ctx.srv_priv,
                 server_identity_public: ctx.srv_pub,
                 device_identity_public: ctx.dev_pub,
                 ephemeral: {server_ephemeral_public, server_ephemeral_private},
                 server_nonce: server_nonce,
                 epoch: 5
               )

      common = [
        server_identity_public: ctx.srv_pub,
        device_id: ctx.device_id,
        ephemeral: {device_ephemeral_public, device_ephemeral_private},
        timestamp_ms: 1_700_000_000_123,
        epoch: 5
      ]

      assert {:ok, raw_init, raw_session} =
               Handshake.initiator_init(
                 hello,
                 [device_identity_private: ctx.dev_priv, device_identity_public: ctx.dev_pub] ++ common
               )

      assert {:ok, provider_init, provider_session} =
               Handshake.initiator_init(hello, [device_identity: identity] ++ common)

      assert provider_init == raw_init
      assert provider_session == raw_session
      assert {:ok, server_session} = Handshake.responder_finalize(responder_state, provider_init)
      assert server_session.session_id == provider_session.session_id
    end
  end

  describe "Frame round-trip across the established session" do
    test "device seal -> server open and server seal -> device open", ctx do
      {d, s} = full_handshake(ctx, epoch: 3)

      # Device (initiator) -> server.
      {:ok, frame1, d2} = Frame.seal(d, "hello from device")
      assert {:ok, "hello from device", _s2} = Frame.open(s, frame1)
      assert d2.send_counter == 1

      # Server (responder) -> device.
      {:ok, frame2, _s3} = Frame.seal(s, "hello from server")
      assert {:ok, "hello from server", _d3} = Frame.open(d, frame2)
    end

    test "round-trips random plaintexts including empty", ctx do
      {d, s} = full_handshake(ctx)

      plaintexts = [<<>>, "a", :crypto.strong_rand_bytes(1), :crypto.strong_rand_bytes(1500)]

      Enum.reduce(plaintexts, {d, s}, fn pt, {dacc, sacc} ->
        {:ok, frame, dacc2} = Frame.seal(dacc, pt)
        assert {:ok, ^pt, sacc2} = Frame.open(sacc, frame)
        {dacc2, sacc2}
      end)
    end

    test "monotonic counters within an epoch never repeat a nonce", ctx do
      {d, s} = full_handshake(ctx)

      {nonces, _, _} =
        Enum.reduce(0..49, {[], d, s}, fn _i, {acc, dacc, sacc} ->
          counter = dacc.send_counter
          {:ok, frame, dacc2} = Frame.seal(dacc, "msg-#{counter}")
          {:ok, _pt, sacc2} = Frame.open(sacc, frame)
          {[Frame.nonce(dacc.epoch, counter) | acc], dacc2, sacc2}
        end)

      assert length(nonces) == 50
      assert length(Enum.uniq(nonces)) == 50
    end
  end

  describe "derive_purpose_key (external range)" do
    test "external purpose (>= 0x80) returns a 32-byte key != session_id and per-(purpose,dir)", ctx do
      {d, _} = full_handshake(ctx)

      assert {:ok, k80a} = Handshake.derive_purpose_key(d, 0x80, 0x01)
      assert byte_size(k80a) == 32
      assert k80a != d.session_id

      assert {:ok, k80b} = Handshake.derive_purpose_key(d, 0x80, 0x02)
      assert {:ok, k81} = Handshake.derive_purpose_key(d, 0x81, 0x01)

      # Differs per direction and per purpose byte.
      assert k80a != k80b
      assert k80a != k81
    end
  end
end
