defmodule RacingOrg.Tracker.Pro.RecoveryV2TestSupport do
  alias RacingOrg.Tracker.Pro.IdentityProviderTestSupport
  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.TrackerContractV2, as: Contract

  @version 0x02
  @receipt_domain "RacingOrg-ServerReceipt-v2"
  @registration_payload_domain "RacingOrg-ServerRegistrationReceipt-v2"
  @challenge_payload_domain "RacingOrg-ServerRecoveryChallengeReceipt-v2"
  @lifecycle_payload_domain "RacingOrg-ServerRecoveryLifecycleReceipt-v2"

  @server_seed :binary.copy(<<0xB2>>, 32)
  @default_device_id <<0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA, 0x99, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00>>
  @default_attempt_id <<0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
  @default_server_nonce :binary.copy(<<0x83>>, 32)

  def server_seed, do: @server_seed
  def server_public_key, do: Primitives.ed25519_public_from_secret(@server_seed)
  def device_id, do: @default_device_id
  def attempt_id, do: @default_attempt_id

  def identity(seed_byte) when is_integer(seed_byte) do
    {:ok, identity} =
      IdentityProviderTestSupport.identity_from_seed(:binary.copy(<<seed_byte>>, 32))

    identity
  end

  def request_context(identity, serial, kind, nonce) do
    public_key = IdentityProvider.public_key(identity)

    assertion =
      case kind do
        :registration -> elem(Contract.registration_assertion(serial, public_key, nonce), 1)
        :challenge -> elem(Contract.recovery_challenge_assertion(serial, public_key, nonce), 1)
      end

    {:ok, signature} = IdentityProvider.sign(identity, assertion)

    %{
      assertion: assertion,
      body: %{
        "provider" => Contract.provider(),
        "serial" => serial,
        "candidate_public_key" => Base.encode64(public_key),
        "client_nonce" => Base.encode64(nonce),
        "signature" => Base.encode64(signature)
      },
      candidate_public_key: public_key,
      client_nonce: nonce,
      signature: signature
    }
  end

  def registration_result(identity, serial, opts \\ []) do
    nonce = Keyword.get(opts, :client_nonce, :binary.copy(<<0x41>>, 32))
    request = request_context(identity, serial, :registration, nonce)
    outcome = Keyword.get(opts, :outcome, :registered)
    reason = Keyword.get(opts, :reason, default_registration_reason(outcome))
    device_id = if outcome == :registered, do: Keyword.get(opts, :device_id, @default_device_id), else: <<>>
    epoch = 0

    payload =
      @registration_payload_domain <>
        <<@version>> <>
        lp(Primitives.sha256(request.assertion)) <>
        <<registration_outcome_code(outcome), reason_code(reason)>> <>
        lp(device_id) <>
        <<epoch::unsigned-big-integer-size(32)>>

    receipt = verified_receipt(1, payload)
    {:ok, %{request: request, receipt: receipt}}
  end

  def challenge_result(identity, serial, opts \\ []) do
    nonce = Keyword.get(opts, :client_nonce, :binary.copy(<<0x42>>, 32))
    request = request_context(identity, serial, :challenge, nonce)
    classification = Keyword.get(opts, :classification, :recoverable)
    reason = Keyword.get(opts, :reason, default_challenge_reason(classification))

    {attempt_id, server_nonce, expires_at} =
      if classification == :recoverable do
        {
          Keyword.get(opts, :attempt_id, @default_attempt_id),
          Keyword.get(opts, :server_nonce, @default_server_nonce),
          Keyword.get(opts, :expires_at_unix_s, 1)
        }
      else
        {<<>>, <<>>, 0}
      end

    payload =
      @challenge_payload_domain <>
        <<@version>> <>
        lp(Primitives.sha256(request.assertion)) <>
        <<challenge_classification_code(classification), reason_code(reason)>> <>
        lp(attempt_id) <>
        lp(server_nonce) <>
        <<expires_at::unsigned-big-integer-size(64)>>

    receipt = verified_receipt(2, payload)
    {:ok, %{request: request, receipt: receipt}}
  end

  def lifecycle_result(identity, challenge_receipt, opts \\ []) do
    public_key = IdentityProvider.public_key(identity)
    challenge_attempt_id = challenge_receipt.payload.attempt_id
    receipt_attempt_id = Keyword.get(opts, :attempt_id, challenge_attempt_id)
    challenge_hash = challenge_receipt.envelope_hash
    {:ok, assertion} = Contract.recovery_commit_assertion(challenge_attempt_id, public_key, challenge_hash)
    {:ok, signature} = IdentityProvider.sign(identity, assertion)
    lifecycle = Keyword.get(opts, :lifecycle, :committed)
    reason = Keyword.get(opts, :reason, default_lifecycle_reason(lifecycle))

    {device_id, epoch, accepted_hash} =
      if lifecycle == :committed do
        {
          Keyword.get(opts, :device_id, @default_device_id),
          Keyword.get(opts, :credential_epoch, 1),
          Keyword.get(opts, :accepted_commit_hash, Primitives.sha256(assertion))
        }
      else
        {<<>>, 0, <<>>}
      end

    payload =
      @lifecycle_payload_domain <>
        <<@version>> <>
        lp(receipt_attempt_id) <>
        lp(challenge_hash) <>
        lp(Primitives.sha256(public_key)) <>
        <<lifecycle_code(lifecycle), reason_code(reason)>> <>
        lp(device_id) <>
        <<epoch::unsigned-big-integer-size(32)>> <>
        lp(accepted_hash)

    receipt = verified_receipt(3, payload)

    {:ok,
     %{
       request: %{
         kind: :commit,
         assertion: assertion,
         body: %{
           "candidate_public_key" => Base.encode64(public_key),
           "challenge_envelope_hash" => Base.encode64(challenge_hash),
           "signature" => Base.encode64(signature)
         },
         candidate_public_key: public_key,
         challenge_envelope_hash: challenge_hash,
         signature: signature
       },
       receipt: receipt
     }}
  end

  def status_result(identity, challenge_receipt, opts \\ []) do
    nonce = Keyword.get(opts, :client_nonce, :binary.copy(<<0x61>>, 32))
    public_key = IdentityProvider.public_key(identity)
    attempt_id = challenge_receipt.payload.attempt_id
    challenge_hash = challenge_receipt.envelope_hash

    {:ok, assertion} = Contract.recovery_status_assertion(attempt_id, public_key, challenge_hash, nonce)
    {:ok, signature} = IdentityProvider.sign(identity, assertion)

    lifecycle_opts = Keyword.delete(opts, :client_nonce)
    {:ok, %{receipt: receipt}} = lifecycle_result(identity, challenge_receipt, lifecycle_opts)

    {:ok,
     %{
       request: %{
         kind: :status,
         assertion: assertion,
         body: %{
           "candidate_public_key" => Base.encode64(public_key),
           "challenge_envelope_hash" => Base.encode64(challenge_hash),
           "client_nonce" => Base.encode64(nonce),
           "signature" => Base.encode64(signature)
         },
         candidate_public_key: public_key,
         challenge_envelope_hash: challenge_hash,
         client_nonce: nonce,
         signature: signature
       },
       receipt: receipt
     }}
  end

  def receipt_response(%{envelope: envelope}), do: %{"receipt" => Base.encode64(envelope)}

  def tamper_request_hash(%{payload_bytes: payload}, replacement) when byte_size(replacement) == 32 do
    domain_size = byte_size(@registration_payload_domain)
    request_hash_offset = domain_size + 1 + 2
    <<prefix::binary-size(request_hash_offset), _old::binary-size(32), suffix::binary>> = payload
    replacement_payload = prefix <> replacement <> suffix
    verified_receipt(1, replacement_payload)
  end

  def uuid_string(<<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2), e::binary-size(6)>>) do
    Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
  end

  def decode_body(body) when is_binary(body), do: Jason.decode!(body)
  def decode_body(body) when is_map(body), do: body

  defp verified_receipt(type, payload) do
    envelope = signed_envelope(type, payload)
    {:ok, receipt} = Contract.verify_receipt_envelope(envelope, server_public_key())
    receipt
  end

  defp signed_envelope(type, payload) do
    signing_bytes = @receipt_domain <> <<@version, type>> <> lp(payload)
    signature = Primitives.ed25519_sign(@server_seed, signing_bytes)
    signing_bytes <> lp(signature)
  end

  defp registration_outcome_code(:registered), do: 1
  defp registration_outcome_code(:recovery_required), do: 2
  defp registration_outcome_code(:blocked), do: 3

  defp challenge_classification_code(:recoverable), do: 1
  defp challenge_classification_code(:not_enrolled), do: 2
  defp challenge_classification_code(:blocked), do: 3

  defp lifecycle_code(:pending), do: 1
  defp lifecycle_code(:committed), do: 2
  defp lifecycle_code(:expired), do: 3
  defp lifecycle_code(:blocked), do: 4

  defp reason_code(:none), do: 0
  defp reason_code(:recovery_disabled), do: 1
  defp reason_code(:recovery_ineligible), do: 2
  defp reason_code(:active_session_conflict), do: 3
  defp reason_code(:identity_conflict), do: 4
  defp reason_code(:attempt_limit), do: 5

  defp default_registration_reason(:registered), do: :none
  defp default_registration_reason(:recovery_required), do: :none
  defp default_registration_reason(:blocked), do: :recovery_disabled

  defp default_challenge_reason(:recoverable), do: :none
  defp default_challenge_reason(:not_enrolled), do: :none
  defp default_challenge_reason(:blocked), do: :recovery_disabled

  defp default_lifecycle_reason(:committed), do: :none
  defp default_lifecycle_reason(:pending), do: :none
  defp default_lifecycle_reason(:expired), do: :none
  defp default_lifecycle_reason(:blocked), do: :recovery_disabled

  defp lp(binary), do: <<byte_size(binary)::unsigned-big-integer-size(16), binary::binary>>
end
