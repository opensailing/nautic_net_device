defmodule RacingOrg.Tracker.Pro.SecureTransport.BootstrapClientTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.RecoveryV2TestSupport, as: Support
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapClient
  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.TrackerContractV2, as: Contract

  @serial "000000001234abcd"
  @nonce :binary.copy(<<0x41>>, 32)

  setup do
    %{identity: Support.identity(0x11)}
  end

  test "prepares the exact v2 registration assertion and canonical JSON body", %{identity: identity} do
    assert {:ok, request} =
             BootstrapClient.prepare_registration(identity, @serial, client_nonce: @nonce)

    assert Map.keys(request.body) |> Enum.sort() ==
             Enum.sort(["provider", "serial", "candidate_public_key", "client_nonce", "signature"])

    assert request.body["provider"] == Contract.provider()
    assert request.body["serial"] == @serial
    assert request.body["candidate_public_key"] == Base.encode64(IdentityProvider.public_key(identity))
    assert request.body["client_nonce"] == Base.encode64(@nonce)
    assert request.candidate_public_key == IdentityProvider.public_key(identity)
    assert request.client_nonce == @nonce

    assert {:ok, expected} =
             Contract.registration_assertion(@serial, IdentityProvider.public_key(identity), @nonce)

    assert request.assertion == expected
    assert Primitives.ed25519_verify(request.candidate_public_key, request.assertion, request.signature)
  end

  test "posts registration v2 and verifies the signed receipt against the exact request", %{identity: identity} do
    {:ok, result} = Support.registration_result(identity, @serial, client_nonce: @nonce)
    response = Support.receipt_response(result.receipt)

    adapter = fn %Tesla.Env{} = env ->
      assert env.method == :post
      assert String.ends_with?(env.url, "/api/devices/register/v2")
      assert Support.decode_body(env.body) == result.request.body
      {:ok, %Tesla.Env{env | status: 200, body: response}}
    end

    assert {:ok, verified} =
             BootstrapClient.register(identity, @serial,
               client_nonce: @nonce,
               server_public_key: Support.server_public_key(),
               adapter: adapter,
               base_url: "https://example.test"
             )

    assert verified.request == result.request
    assert verified.receipt.envelope == result.receipt.envelope
    assert verified.receipt.payload.outcome == :registered
  end

  test "rejects a validly signed receipt for a different registration request", %{identity: identity} do
    {:ok, result} = Support.registration_result(identity, @serial, client_nonce: @nonce)
    wrong_receipt = Support.tamper_request_hash(result.receipt, :binary.copy(<<0xAA>>, 32))

    assert {:error, :receipt_request_mismatch} =
             BootstrapClient.verify_registration_response(
               result.request,
               Support.receipt_response(wrong_receipt),
               server_public_key: Support.server_public_key()
             )
  end

  test "collapses non-success HTTP bodies and transport failures without returning body contents", %{identity: identity} do
    rejected = fn %Tesla.Env{} = env ->
      {:ok, %Tesla.Env{env | status: 409, body: %{"serial" => @serial, "secret" => "do-not-return"}}}
    end

    assert {:error, :registration_conflict} =
             BootstrapClient.register(identity, @serial,
               client_nonce: @nonce,
               adapter: rejected,
               base_url: "https://example.test"
             )

    transport = fn %Tesla.Env{} -> {:error, :econnrefused} end

    assert {:error, {:transport, :econnrefused}} =
             BootstrapClient.register(identity, @serial,
               client_nonce: @nonce,
               adapter: transport,
               base_url: "https://example.test"
             )
  end
end
