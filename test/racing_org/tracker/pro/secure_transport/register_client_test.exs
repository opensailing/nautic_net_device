defmodule RacingOrg.Tracker.Pro.SecureTransport.RegisterClientTest do
  @moduledoc """
  Device-side TOKENLESS self-registration client (Phase AC7).

  Verifies that, given only the device identity keypair (no claim token, no
  server-issued nonce), the client:

    * builds the EXACT proof-of-possession message the server reconstructs in
      `RacingOrg.Devices.register_pop_message/2` (the domain string + a
      length-prefixed public key + a length-prefixed decimal-ASCII timestamp),
      signs it, and the signature verifies against the presented public key over
      that message;
    * emits a request body whose field names + encodings match what the server's
      `POST /api/devices/register` decoder expects (public key + signature as
      standard base64, the timestamp as an integer, an optional boat identifier);
    * handles a 201 success response (returning the device association) and the
      clear 401 (bad/stale PoP) + 400 (malformed) failure responses, plus a
      transport-level failure.

  Pure construction + a MOCKED Tesla transport — no live server.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.IdentityProviderTestSupport
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.RegisterClient

  # Mirror of the server's PoP message (RacingOrg.Devices.register_pop_message/2):
  #   "RacingOrg-TrackerRegister-v1" || lp(public_key) || lp(Integer.to_string(ts))
  # where lp(x) = u16-big-endian(byte_size(x)) || x and the domain is the literal
  # ASCII bytes (NOT length-prefixed). This is the authoritative signing input; the
  # device MUST reproduce it byte-for-byte.
  @register_pop_domain "RacingOrg-TrackerRegister-v1"

  defp server_pop_message(public_key, timestamp) do
    @register_pop_domain <> lp(public_key) <> lp(Integer.to_string(timestamp))
  end

  defp lp(bin) when byte_size(bin) <= 0xFFFF do
    <<byte_size(bin)::unsigned-big-integer-size(16), bin::binary>>
  end

  setup do
    base = Path.join(System.tmp_dir!(), "nn_register_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, identity} = KeyStore.load_or_generate(base_path: base)
    {:ok, base: base, identity: identity}
  end

  describe "build_register_pop_message/2 + sign_register_pop/2" do
    test "reproduces the server's PoP message byte-for-byte", ctx do
      ts = 1_700_000_000
      built = RegisterClient.build_register_pop_message(ctx.identity.public_key, ts)
      expected = server_pop_message(ctx.identity.public_key, ts)
      assert built == expected
    end

    test "the domain tag is the literal ASCII bytes, NOT length-prefixed", ctx do
      ts = 1_700_000_000
      built = RegisterClient.build_register_pop_message(ctx.identity.public_key, ts)
      assert String.starts_with?(built, @register_pop_domain)
      # The bytes immediately AFTER the domain are the u16 length of the public key
      # (32 = <<0, 32>>), proving the domain itself carries no length prefix.
      domain_len = byte_size(@register_pop_domain)
      assert binary_part(built, domain_len, 2) == <<0, 32>>
    end

    test "the timestamp is length-prefixed as its decimal ASCII string", ctx do
      ts = 1_700_000_000
      built = RegisterClient.build_register_pop_message(ctx.identity.public_key, ts)
      ts_string = Integer.to_string(ts)
      assert String.ends_with?(built, lp(ts_string))
    end

    test "produced signature verifies against the presented public key over that message", ctx do
      ts = 1_700_000_000
      sig = RegisterClient.sign_register_pop(ctx.identity, ts)
      message = server_pop_message(ctx.identity.public_key, ts)

      assert byte_size(sig) == 64
      assert Primitives.ed25519_verify(ctx.identity.public_key, message, sig)
      # A signature is bound to the exact message: a different timestamp won't verify.
      other = server_pop_message(ctx.identity.public_key, ts + 1)
      refute Primitives.ed25519_verify(ctx.identity.public_key, other, sig)
    end

    test "operational signer and deterministic raw-seed paths remain byte-identical" do
      seed = :binary.copy(<<0x5A>>, 32)
      public_key = Primitives.ed25519_public_from_secret(seed)
      timestamp = 1_700_000_000
      assert {:ok, provider} = IdentityProviderTestSupport.identity_from_seed(seed)

      legacy_identity = %{private_key: seed, public_key: public_key}

      assert RegisterClient.sign_register_pop(provider, timestamp) ==
               RegisterClient.sign_register_pop(legacy_identity, timestamp)

      assert RegisterClient.build_register_request(provider, timestamp, "boat-7") ==
               RegisterClient.build_register_request(legacy_identity, timestamp, "boat-7")
    end
  end

  describe "build_register_request/3" do
    test "request body has the exact fields + encodings the server expects", ctx do
      ts = 1_700_000_000
      body = RegisterClient.build_register_request(ctx.identity, ts, "boat-7")

      assert body["public_key"] == Base.encode64(ctx.identity.public_key)
      assert body["timestamp"] == ts
      assert body["boat_identifier"] == "boat-7"

      # The signature field must decode to a 64-byte Ed25519 signature that the
      # server verifies against the decoded public key over the PoP message.
      assert {:ok, sig} = Base.decode64(body["signature"])
      assert {:ok, pub} = Base.decode64(body["public_key"])
      message = server_pop_message(pub, ts)
      assert Primitives.ed25519_verify(pub, message, sig)
    end
  end

  describe "register/2 over a mocked transport" do
    test "201 success returns the device association (no token in the request)", ctx do
      device_id = "11111111-2222-3333-4444-555555555555"
      fingerprint = KeyStore.fingerprint(ctx.identity.public_key)

      adapter = fn %Tesla.Env{} = env ->
        # The client POSTs JSON to the register path with the expected body and NO
        # claim-token / server-nonce fields anywhere.
        assert env.method == :post
        assert String.ends_with?(env.url, "/api/devices/register")
        decoded = decode_body(env.body)
        assert decoded["public_key"] == Base.encode64(ctx.identity.public_key)
        assert is_integer(decoded["timestamp"])
        assert {:ok, _} = Base.decode64(decoded["signature"])
        refute Map.has_key?(decoded, "claim_token_secret")
        refute Map.has_key?(decoded, "server_nonce")

        {:ok,
         %Tesla.Env{
           env
           | status: 201,
             body: %{
               "device_id" => device_id,
               "fingerprint" => fingerprint,
               "status" => "unassigned",
               "assigned" => false
             }
         }}
      end

      assert {:ok, result} =
               RegisterClient.register(ctx.identity, adapter: adapter, boat_identifier: "boat-7")

      assert result.device_id == device_id
      assert result.fingerprint == fingerprint
      assert result.status == "unassigned"
    end

    test "401 (bad / stale PoP) is a clear error", ctx do
      adapter = fn %Tesla.Env{} = env ->
        {:ok, %Tesla.Env{env | status: 401, body: %{"error" => "bad_proof_of_possession"}}}
      end

      assert {:error, {:register_rejected, 401, _body}} =
               RegisterClient.register(ctx.identity, adapter: adapter)
    end

    test "400 (malformed) is a clear error", ctx do
      adapter = fn %Tesla.Env{} = env ->
        {:ok, %Tesla.Env{env | status: 400, body: %{"error" => "malformed"}}}
      end

      assert {:error, {:register_rejected, 400, _body}} =
               RegisterClient.register(ctx.identity, adapter: adapter)
    end

    test "an unexpected status surfaces clearly", ctx do
      adapter = fn %Tesla.Env{} = env ->
        {:ok, %Tesla.Env{env | status: 503, body: %{"error" => "upstream_down"}}}
      end

      assert {:error, {:unexpected_status, 503, %{"error" => "upstream_down"}}} =
               RegisterClient.register(ctx.identity, adapter: adapter)
    end

    test "a transport error surfaces clearly", ctx do
      adapter = fn %Tesla.Env{} -> {:error, :econnrefused} end

      assert {:error, {:transport, :econnrefused}} =
               RegisterClient.register(ctx.identity, adapter: adapter)
    end

    test "re-registering the same identity is safe (server is idempotent)", ctx do
      # Two consecutive registers of the same identity both succeed (the server just
      # refreshes the existing fingerprint). The client carries no single-use state.
      device_id = "abc"

      adapter = fn %Tesla.Env{} = env ->
        {:ok,
         %Tesla.Env{
           env
           | status: 201,
             body: %{"device_id" => device_id, "status" => "unassigned", "assigned" => false}
         }}
      end

      assert {:ok, %{device_id: ^device_id}} = RegisterClient.register(ctx.identity, adapter: adapter)
      assert {:ok, %{device_id: ^device_id}} = RegisterClient.register(ctx.identity, adapter: adapter)
    end
  end

  # Tesla.Middleware.JSON has not run on the mock env's body (the mock receives the
  # already-encoded body), so decode defensively for the assertion.
  defp decode_body(body) when is_binary(body), do: Jason.decode!(body)
  defp decode_body(body) when is_map(body), do: body
end
