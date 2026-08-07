defmodule RacingOrg.Tracker.Pro.SecureTransport.SignedRequestTest do
  @moduledoc """
  Device-side signed-request assertion for the Phase 6 HTTPS bulk plane.

  Verifies the device reproduces the server's canonical assertion
  (`RacingOrg.SecureTransport.SignedRequest.canonical/5`) BYTE-FOR-BYTE, signs it
  with the device identity key (a signature the server's `SignedRequest.verify/7`
  would accept, via the same `Primitives.ed25519_verify` core), and emits exactly
  the headers the server's `RacingOrgWeb.Plugs.DeviceSignedRequest` reads, with the
  encodings it expects (base64 signature, lowercase-hex fingerprint, unix-seconds
  timestamp). The body hash is lowercase hex of SHA-256 over the RAW body, computed
  the same way the server recomputes it.

  Pure construction — no transport.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.SignedRequest

  # Authoritative server-side canonical builder, replicated from
  # RacingOrg.SecureTransport.SignedRequest.canonical/5:
  #
  #   "racingorg-bulk-v1" \n METHOD \n path \n lower-hex(sha256(body)) \n ts \n fingerprint
  #
  # joined with "\n". The device MUST reproduce this exactly.
  defp server_canonical(method, path, body, ts, fingerprint) do
    Enum.join(
      [
        "racingorg-bulk-v1",
        String.upcase(method),
        path,
        Base.encode16(:crypto.hash(:sha256, body), case: :lower),
        to_string(ts),
        fingerprint
      ],
      "\n"
    )
  end

  setup do
    base = Path.join(System.tmp_dir!(), "nn_signed_req_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, identity} = KeyStore.load_or_generate(base_path: base)
    {:ok, identity: identity}
  end

  describe "canonical/5" do
    test "reproduces the server's canonical assertion byte-for-byte", %{identity: identity} do
      body = Jason.encode!(%{"data" => "AAAA", "chunk_index" => 0})
      ts = 1_750_000_000
      path = "/api/bulk/race_recordings/2026-06-03-1/chunks"

      built = SignedRequest.canonical("POST", path, body, ts, identity.fingerprint)
      expected = server_canonical("POST", path, body, ts, identity.fingerprint)

      assert built == expected
    end

    test "upcases the method and uses lowercase-hex sha256 of the raw body", %{identity: id} do
      built = SignedRequest.canonical("post", "/api/bulk/race_manifests", "hello", 42, id.fingerprint)

      [tag, method, path, body_hash, ts, fp] = String.split(built, "\n")
      assert tag == "racingorg-bulk-v1"
      assert method == "POST"
      assert path == "/api/bulk/race_manifests"
      assert body_hash == Base.encode16(:crypto.hash(:sha256, "hello"), case: :lower)
      assert body_hash == String.downcase(body_hash)
      assert ts == "42"
      assert fp == id.fingerprint
    end
  end

  describe "sign/6 + verify (server side)" do
    test "the signature verifies against the device public key over the assertion", %{identity: id} do
      body = "the-body-bytes"
      ts = 1_750_000_123
      path = "/api/bulk/race_manifests"

      sig = SignedRequest.sign(id, "POST", path, body, ts, id.fingerprint)
      message = server_canonical("POST", path, body, ts, id.fingerprint)

      assert byte_size(sig) == 64
      # The server verifies with this exact primitive over this exact message.
      assert Primitives.ed25519_verify(id.public_key, message, sig)
      # A tampered body yields a different canonical string -> verify fails.
      tampered = server_canonical("POST", path, "other-body", ts, id.fingerprint)
      refute Primitives.ed25519_verify(id.public_key, tampered, sig)
    end
  end

  describe "headers/5" do
    test "emits exactly the header names + encodings the server plug reads", %{identity: id} do
      body = Jason.encode!(%{"manifest_protobuf" => "AAAA"})
      ts = 1_750_000_456
      path = "/api/bulk/race_manifests"

      headers = SignedRequest.headers(id, "POST", path, body, ts)

      assert Map.keys(headers) |> Enum.sort() == [
               "x-racingorg-device-fingerprint",
               "x-racingorg-signature",
               "x-racingorg-timestamp"
             ]

      # Fingerprint: lowercase hex SHA-256(public_key) (== KeyStore.fingerprint/1).
      assert headers["x-racingorg-device-fingerprint"] == id.fingerprint
      assert headers["x-racingorg-device-fingerprint"] == KeyStore.fingerprint(id.public_key)

      # Timestamp: unix seconds as an integer string.
      assert headers["x-racingorg-timestamp"] == Integer.to_string(ts)

      # Signature: STANDARD base64 of the 64-byte Ed25519 signature that the server
      # verifies against the assertion built from (method, path, body, ts, fp).
      assert {:ok, sig} = Base.decode64(headers["x-racingorg-signature"])
      assert byte_size(sig) == 64
      message = server_canonical("POST", path, body, ts, id.fingerprint)
      assert Primitives.ed25519_verify(id.public_key, message, sig)
    end

    test "the timestamp in the header equals the one baked into the signed assertion", %{identity: id} do
      body = "body"
      ts = 1_750_000_789
      path = "/api/bulk/race_manifests"

      headers = SignedRequest.headers(id, "POST", path, body, ts)
      {:ok, sig} = Base.decode64(headers["x-racingorg-signature"])

      # Verify ONLY succeeds with the timestamp the header advertises (so the
      # server's window check + verify agree on the same ts).
      header_ts = String.to_integer(headers["x-racingorg-timestamp"])
      ok_msg = server_canonical("POST", path, body, header_ts, id.fingerprint)
      bad_msg = server_canonical("POST", path, body, header_ts + 1, id.fingerprint)

      assert Primitives.ed25519_verify(id.public_key, ok_msg, sig)
      refute Primitives.ed25519_verify(id.public_key, bad_msg, sig)
    end
  end
end
