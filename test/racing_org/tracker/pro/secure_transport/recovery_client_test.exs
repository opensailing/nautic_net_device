defmodule RacingOrg.Tracker.Pro.SecureTransport.RecoveryClientTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.RecoveryV2TestSupport, as: Support
  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.RecoveryClient
  alias RacingOrg.Tracker.Pro.SecureTransport.TrackerContractV2, as: Contract

  @serial "000000001234abcd"
  @challenge_nonce :binary.copy(<<0x42>>, 32)
  @status_nonce :binary.copy(<<0x61>>, 32)

  setup do
    identity = Support.identity(0x22)
    {:ok, challenge} = Support.challenge_result(identity, @serial, client_nonce: @challenge_nonce)
    %{identity: identity, challenge: challenge}
  end

  test "challenge signs the serial assertion and verifies the exact signed classification", %{identity: identity} do
    {:ok, expected} = Support.challenge_result(identity, @serial, client_nonce: @challenge_nonce)

    adapter = fn %Tesla.Env{} = env ->
      assert env.method == :post
      assert String.ends_with?(env.url, "/api/devices/recovery/challenges")
      assert Support.decode_body(env.body) == expected.request.body
      {:ok, %Tesla.Env{env | status: 200, body: Support.receipt_response(expected.receipt)}}
    end

    assert {:ok, result} =
             RecoveryClient.challenge(identity, @serial,
               client_nonce: @challenge_nonce,
               server_public_key: Support.server_public_key(),
               adapter: adapter,
               base_url: "https://example.test"
             )

    assert result.receipt.payload.classification == :recoverable
    assert result.receipt.payload.expires_at_unix_s == 1
    assert result.request.assertion == expected.request.assertion
  end

  test "commit proves the exact challenge envelope and validates every committed binding", ctx do
    {:ok, expected} =
      Support.lifecycle_result(ctx.identity, ctx.challenge.receipt,
        device_id: Support.device_id(),
        credential_epoch: 9
      )

    adapter = fn %Tesla.Env{} = env ->
      assert env.method == :post

      assert String.ends_with?(
               env.url,
               "/api/devices/recovery/#{Support.uuid_string(Support.attempt_id())}/commit"
             )

      assert Support.decode_body(env.body) == expected.request.body
      {:ok, %Tesla.Env{env | status: 200, body: Support.receipt_response(expected.receipt)}}
    end

    assert {:ok, result} =
             RecoveryClient.commit(ctx.identity, ctx.challenge.receipt,
               server_public_key: Support.server_public_key(),
               adapter: adapter,
               base_url: "https://example.test"
             )

    assert result.receipt.payload.lifecycle == :committed
    assert result.receipt.payload.logical_device_id == Support.device_id()
    assert result.receipt.payload.credential_epoch == 9
    assert result.receipt.payload.challenge_envelope_hash == ctx.challenge.receipt.envelope_hash
    assert result.receipt.payload.candidate_fingerprint == Primitives.sha256(IdentityProvider.public_key(ctx.identity))
    assert result.receipt.payload.accepted_commit_signing_bytes_hash == Primitives.sha256(result.request.assertion)
  end

  test "status uses fresh candidate PoP and accepts byte-identical committed replay", ctx do
    {:ok, expected} =
      Support.status_result(ctx.identity, ctx.challenge.receipt,
        client_nonce: @status_nonce,
        credential_epoch: 9
      )

    adapter = fn %Tesla.Env{} = env ->
      assert env.method == :post

      assert String.ends_with?(
               env.url,
               "/api/devices/recovery/#{Support.uuid_string(Support.attempt_id())}/status"
             )

      assert Support.decode_body(env.body) == expected.request.body
      {:ok, %Tesla.Env{env | status: 200, body: Support.receipt_response(expected.receipt)}}
    end

    assert {:ok, result} =
             RecoveryClient.status(ctx.identity, ctx.challenge.receipt,
               client_nonce: @status_nonce,
               server_public_key: Support.server_public_key(),
               adapter: adapter,
               base_url: "https://example.test"
             )

    assert result.request.client_nonce == @status_nonce
    assert result.receipt.envelope == expected.receipt.envelope
    assert result.receipt.payload.lifecycle == :committed
  end

  test "does not use tracker RTC to reject a server-authorized challenge expiry", %{identity: identity} do
    {:ok, challenge} =
      Support.challenge_result(identity, @serial,
        client_nonce: @challenge_nonce,
        expires_at_unix_s: 1
      )

    {:ok, lifecycle} = Support.lifecycle_result(identity, challenge.receipt, credential_epoch: 2)

    adapter = fn %Tesla.Env{} = env ->
      {:ok, %Tesla.Env{env | status: 200, body: Support.receipt_response(lifecycle.receipt)}}
    end

    assert {:ok, %{receipt: %{payload: %{lifecycle: :committed}}}} =
             RecoveryClient.commit(identity, challenge.receipt,
               server_public_key: Support.server_public_key(),
               adapter: adapter,
               base_url: "https://example.test"
             )
  end

  test "rejects lifecycle receipts bound to another candidate, attempt, or commit", ctx do
    {:ok, valid} = Support.lifecycle_result(ctx.identity, ctx.challenge.receipt, credential_epoch: 9)
    other_identity = Support.identity(0x23)
    {:ok, wrong_candidate} = Support.lifecycle_result(other_identity, ctx.challenge.receipt, credential_epoch: 9)

    {:ok, wrong_attempt} =
      Support.lifecycle_result(ctx.identity, ctx.challenge.receipt,
        attempt_id: :binary.copy(<<0xAB>>, 16),
        credential_epoch: 9
      )

    assert {:error, :candidate_fingerprint_mismatch} =
             RecoveryClient.verify_lifecycle_response(
               valid.request,
               ctx.challenge.receipt,
               Support.receipt_response(wrong_candidate.receipt),
               server_public_key: Support.server_public_key()
             )

    assert {:error, :attempt_id_mismatch} =
             RecoveryClient.verify_lifecycle_response(
               valid.request,
               ctx.challenge.receipt,
               Support.receipt_response(wrong_attempt.receipt),
               server_public_key: Support.server_public_key()
             )

    assert {:error, :accepted_commit_hash_mismatch} =
             RecoveryClient.verify_lifecycle_response(
               %{valid.request | assertion: valid.request.assertion <> <<0>>},
               ctx.challenge.receipt,
               Support.receipt_response(valid.receipt),
               server_public_key: Support.server_public_key()
             )
  end

  test "prepares canonical recovery fields and signatures", ctx do
    assert {:ok, request} =
             RecoveryClient.prepare_status(ctx.identity, ctx.challenge.receipt, client_nonce: @status_nonce)

    assert Map.keys(request.body) |> Enum.sort() ==
             Enum.sort(["candidate_public_key", "challenge_envelope_hash", "client_nonce", "signature"])

    assert request.body["challenge_envelope_hash"] ==
             Base.encode64(Contract.challenge_envelope_hash(ctx.challenge.receipt.envelope))

    assert Primitives.ed25519_verify(request.candidate_public_key, request.assertion, request.signature)
  end
end
