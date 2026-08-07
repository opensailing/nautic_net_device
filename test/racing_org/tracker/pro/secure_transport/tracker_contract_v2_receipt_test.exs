defmodule RacingOrg.Tracker.Pro.SecureTransport.TrackerContractV2ReceiptTest do
  @moduledoc """
  Strict verification and parsing of signed TRACKER v2 server receipts.

  Every test envelope is independently encoded and Ed25519-signed in the test. The
  implementation under test may inspect a payload only after the outer signature has
  verified, and must then enforce the receipt-type/payload-domain agreement and all
  closed enum, exact-size, empty-field, epoch, and commit-hash invariants.
  """

  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.TrackerContractV2, as: Contract

  @version 0x02
  @receipt_domain "RacingOrg-ServerReceipt-v2"
  @registration_payload_domain "RacingOrg-ServerRegistrationReceipt-v2"
  @challenge_payload_domain "RacingOrg-ServerRecoveryChallengeReceipt-v2"
  @lifecycle_payload_domain "RacingOrg-ServerRecoveryLifecycleReceipt-v2"

  @golden_path Application.app_dir(
                 :racing_org_tracker_pro,
                 "priv/secure_transport/registration_recovery_v2_kat.json"
               )

  setup_all do
    golden = @golden_path |> File.read!() |> Jason.decode!()
    inputs = golden["inputs"]
    assertions = golden["assertions"]
    receipts = golden["receipts"]

    %{
      inputs: %{
        "server_public" => inputs["server_public_key_hex"],
        "server_seed" => inputs["server_private_seed_hex"],
        "logical_device_id" => inputs["logical_device_id_raw_hex"],
        "attempt_id" => inputs["attempt_id_raw_hex"],
        "server_nonce" => inputs["server_nonce_hex"],
        "expires_at_unix_s" => inputs["expires_at_unix_s"],
        "credential_epoch" => inputs["credential_epoch"]
      },
      hashes: %{
        "registration_request" => assertions["registration_request_hash_hex"],
        "challenge_request" => assertions["challenge_request_hash_hex"],
        "challenge_envelope" => receipts["challenge_envelope_hash_hex"],
        "candidate_fingerprint" => inputs["candidate_public_key_hex"] |> hex() |> Primitives.sha256() |> hex_string(),
        "accepted_commit_signing_bytes" => assertions["commit_signing_bytes_hash_hex"]
      },
      receipts: %{
        "registration_payload" => receipts["registration_payload_hex"],
        "registration_envelope" => receipts["registration_envelope_hex"],
        "challenge_payload" => receipts["challenge_payload_hex"],
        "challenge_envelope" => receipts["challenge_envelope_hex"],
        "lifecycle_payload" => receipts["lifecycle_payload_hex"],
        "lifecycle_envelope" => receipts["lifecycle_envelope_hex"]
      }
    }
  end

  describe "receipt-envelope golden vectors" do
    test "registration receipt verifies and parses byte-identically", ctx do
      envelope = hex(ctx.receipts["registration_envelope"])
      payload = hex(ctx.receipts["registration_payload"])
      server_public = hex(ctx.inputs["server_public"])

      assert {:ok, signing_bytes} = Contract.receipt_signing_bytes(:registration, payload)
      assert signing_bytes == binary_part(envelope, 0, byte_size(envelope) - 66)

      assert {:ok, receipt} = Contract.verify_receipt_envelope(envelope, server_public)

      assert receipt.version == @version
      assert receipt.receipt_type == :registration
      assert receipt.envelope == envelope
      assert receipt.envelope_hash == Primitives.sha256(envelope)
      assert receipt.payload_bytes == payload
      assert byte_size(receipt.server_signature) == 64

      assert receipt.payload == %{
               request_hash: hex(ctx.hashes["registration_request"]),
               outcome: :registered,
               reason: :none,
               logical_device_id: hex(ctx.inputs["logical_device_id"]),
               credential_epoch: 0
             }
    end

    test "challenge receipt verifies, parses, and hashes the exact signed envelope", ctx do
      envelope = hex(ctx.receipts["challenge_envelope"])

      assert {:ok, receipt} =
               Contract.verify_receipt_envelope(envelope, hex(ctx.inputs["server_public"]))

      assert receipt.receipt_type == :challenge
      assert receipt.envelope == envelope
      assert receipt.envelope_hash == hex(ctx.hashes["challenge_envelope"])

      assert receipt.payload == %{
               request_hash: hex(ctx.hashes["challenge_request"]),
               classification: :recoverable,
               reason: :none,
               attempt_id: hex(ctx.inputs["attempt_id"]),
               server_nonce: hex(ctx.inputs["server_nonce"]),
               expires_at_unix_s: ctx.inputs["expires_at_unix_s"]
             }
    end

    test "committed lifecycle receipt preserves the exact signed envelope", ctx do
      envelope = hex(ctx.receipts["lifecycle_envelope"])
      server_public = hex(ctx.inputs["server_public"])

      assert {:ok, first} = Contract.verify_receipt_envelope(envelope, server_public)
      assert {:ok, replay} = Contract.verify_receipt_envelope(envelope, server_public)
      assert first.envelope === envelope
      assert replay.envelope === envelope
      assert first.envelope === replay.envelope

      assert first.receipt_type == :lifecycle

      assert first.payload == %{
               attempt_id: hex(ctx.inputs["attempt_id"]),
               challenge_envelope_hash: hex(ctx.hashes["challenge_envelope"]),
               candidate_fingerprint: hex(ctx.hashes["candidate_fingerprint"]),
               lifecycle: :committed,
               reason: :none,
               logical_device_id: hex(ctx.inputs["logical_device_id"]),
               credential_epoch: ctx.inputs["credential_epoch"],
               accepted_commit_signing_bytes_hash: hex(ctx.hashes["accepted_commit_signing_bytes"])
             }
    end

    test "uses the configured pinned Ed25519 key when no key is injected", ctx do
      previous = Application.get_env(:racing_org_tracker_pro, ServerIdentity)
      on_exit(fn -> restore_server_identity(previous) end)

      Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: hex(ctx.inputs["server_public"]))

      assert {:ok, %{receipt_type: :registration}} =
               ctx.receipts["registration_envelope"]
               |> hex()
               |> Contract.verify_receipt_envelope()
    end

    test "frames any u16-sized payload exactly like the backend and rejects only u16 overflow" do
      max_payload = :binary.copy(<<0xA5>>, 0xFFFF)

      for {receipt_type, type_code} <- [registration: 1, challenge: 2, lifecycle: 3] do
        assert {:ok, signing_bytes} =
                 Contract.receipt_signing_bytes(receipt_type, max_payload)

        assert signing_bytes ==
                 @receipt_domain <> <<@version, type_code, 0xFF, 0xFF>> <> max_payload

        assert {:error, :receipt_payload_too_large} =
                 Contract.receipt_signing_bytes(receipt_type, max_payload <> <<0>>)
      end
    end
  end

  describe "strict receipt JSON/base64 boundary" do
    test "accepts only the exact receipt field with canonical padded standard base64", ctx do
      envelope = hex(ctx.receipts["registration_envelope"])
      response = %{"receipt" => Base.encode64(envelope)}

      assert {:ok, %{envelope: ^envelope}} =
               Contract.verify_receipt_response(response, hex(ctx.inputs["server_public"]))
    end

    test "rejects unknown/missing fields, wrong key types, and non-string receipt values", ctx do
      encoded = Base.encode64(hex(ctx.receipts["registration_envelope"]))
      server_public = hex(ctx.inputs["server_public"])

      for invalid <- [
            %{},
            %{"receipt" => encoded, "extra" => true},
            %{receipt: encoded},
            %{"receipt" => nil},
            %{"receipt" => 123},
            [receipt: encoded]
          ] do
        assert {:error, :invalid_receipt_response} =
                 Contract.verify_receipt_response(invalid, server_public)
      end
    end

    test "rejects unpadded, overpadded, URL-safe, whitespace, and otherwise noncanonical base64", ctx do
      server_public = hex(ctx.inputs["server_public"])
      envelope = hex(ctx.receipts["registration_envelope"])
      canonical = Base.encode64(envelope)
      unpadded = String.trim_trailing(canonical, "=")

      assert canonical != unpadded

      for invalid <- [unpadded, canonical <> "=", canonical <> "\n", "_w==", "!!!!"] do
        assert {:error, :invalid_receipt_base64} =
                 Contract.verify_receipt_response(%{"receipt" => invalid}, server_public)
      end
    end
  end

  describe "verification order and envelope tamper rejection" do
    test "rejects wrong key sizes before crypto", ctx do
      envelope = hex(ctx.receipts["registration_envelope"])
      assert {:error, :bad_server_public_key_length} = Contract.verify_receipt_envelope(envelope, <<0::248>>)
      assert {:error, :bad_server_public_key_length} = Contract.verify_receipt_envelope(envelope, nil)
    end

    test "rejects domain/version/type/length/trailing structural failures", ctx do
      envelope = hex(ctx.receipts["registration_envelope"])
      server_public = hex(ctx.inputs["server_public"])
      domain_size = byte_size(@receipt_domain)

      invalid = [
        flip_byte(envelope, 0),
        replace_byte(envelope, domain_size, 0x01),
        replace_byte(envelope, domain_size + 1, 0xFF),
        binary_part(envelope, 0, byte_size(envelope) - 1),
        envelope <> <<0>>,
        @receipt_domain <> <<@version, 1, 0xFF, 0xFF, 0>>
      ]

      for bytes <- invalid do
        assert {:error, _reason} = Contract.verify_receipt_envelope(bytes, server_public)
      end
    end

    test "type, payload, signature, and pinned-key tampering cannot verify", ctx do
      envelope = hex(ctx.receipts["registration_envelope"])
      server_public = hex(ctx.inputs["server_public"])
      domain_size = byte_size(@receipt_domain)
      payload_offset = domain_size + 4

      assert {:error, :bad_server_signature} =
               envelope
               |> replace_byte(domain_size + 1, 2)
               |> Contract.verify_receipt_envelope(server_public)

      assert {:error, :bad_server_signature} =
               envelope
               |> flip_byte(payload_offset)
               |> Contract.verify_receipt_envelope(server_public)

      assert {:error, :bad_server_signature} =
               envelope
               |> flip_byte(byte_size(envelope) - 1)
               |> Contract.verify_receipt_envelope(server_public)

      wrong_server_public =
        <<0xA5::unsigned-integer-size(8), binary_part(server_public, 1, byte_size(server_public) - 1)::binary>>

      assert {:error, :bad_server_signature} =
               Contract.verify_receipt_envelope(envelope, wrong_server_public)
    end

    test "does not inspect payload domain or semantics until the outer signature verifies", ctx do
      malformed_payload = "not-a-registration-payload"
      server_public = hex(ctx.inputs["server_public"])
      invalid_signature_envelope = raw_envelope(1, malformed_payload, <<0::512>>)

      assert {:error, :bad_server_signature} =
               Contract.verify_receipt_envelope(invalid_signature_envelope, server_public)

      validly_signed = signed_envelope(1, malformed_payload, hex(ctx.inputs["server_seed"]))

      assert {:error, :payload_domain_mismatch} =
               Contract.verify_receipt_envelope(validly_signed, server_public)
    end

    test "does not consume a closed receipt type until the outer signature verifies", ctx do
      payload = "opaque"
      server_seed = hex(ctx.inputs["server_seed"])
      server_public = hex(ctx.inputs["server_public"])

      assert {:error, :bad_server_signature} =
               0xFF
               |> raw_envelope(payload, <<0::512>>)
               |> Contract.verify_receipt_envelope(server_public)

      assert {:error, :unknown_receipt_type} =
               0xFF
               |> signed_envelope(payload, server_seed)
               |> Contract.verify_receipt_envelope(server_public)
    end

    test "enforces receipt type to payload domain agreement only after signature verification", ctx do
      server_seed = hex(ctx.inputs["server_seed"])
      server_public = hex(ctx.inputs["server_public"])

      mismatches = [
        {1, hex(ctx.receipts["challenge_payload"])},
        {2, hex(ctx.receipts["lifecycle_payload"])},
        {3, hex(ctx.receipts["registration_payload"])}
      ]

      for {type, payload} <- mismatches do
        assert {:error, :payload_domain_mismatch} =
                 type
                 |> signed_envelope(payload, server_seed)
                 |> Contract.verify_receipt_envelope(server_public)
      end
    end
  end

  describe "registration payload invariants" do
    test "accepts the three closed outcomes with their authoritative field shapes", ctx do
      request_hash = hex(ctx.hashes["registration_request"])
      device_id = hex(ctx.inputs["logical_device_id"])

      assert {:ok, %{payload: %{outcome: :registered, reason: :none, logical_device_id: ^device_id}}} =
               verify_payload(ctx, 1, registration_payload(request_hash, 1, 0, device_id, 0))

      assert {:ok,
              %{
                payload: %{
                  outcome: :recovery_required,
                  reason: :identity_conflict,
                  logical_device_id: nil,
                  credential_epoch: 0
                }
              }} =
               verify_payload(ctx, 1, registration_payload(request_hash, 2, 4, <<>>, 0))

      assert {:ok,
              %{
                payload: %{
                  outcome: :blocked,
                  reason: :active_session_conflict,
                  logical_device_id: nil,
                  credential_epoch: 0
                }
              }} =
               verify_payload(ctx, 1, registration_payload(request_hash, 3, 3, <<>>, 0))
    end

    test "rejects bad hashes/enums and every forbidden outcome field combination", ctx do
      request_hash = hex(ctx.hashes["registration_request"])
      device_id = hex(ctx.inputs["logical_device_id"])

      invalid_payloads = [
        registration_payload(<<0::248>>, 1, 0, device_id, 0),
        registration_payload(request_hash, 0, 0, device_id, 0),
        registration_payload(request_hash, 4, 0, device_id, 0),
        registration_payload(request_hash, 1, 6, device_id, 0),
        registration_payload(request_hash, 1, 1, device_id, 0),
        registration_payload(request_hash, 1, 0, <<>>, 0),
        registration_payload(request_hash, 1, 0, <<0::120>>, 0),
        registration_payload(request_hash, 1, 0, device_id, 1),
        registration_payload(request_hash, 2, 2, device_id, 0),
        registration_payload(request_hash, 2, 2, <<>>, 1),
        registration_payload(request_hash, 3, 0, <<>>, 0),
        registration_payload(request_hash, 3, 5, device_id, 0),
        registration_payload(request_hash, 3, 5, <<>>, 1)
      ]

      assert_all_payloads_rejected(ctx, 1, invalid_payloads)
    end
  end

  describe "challenge payload invariants" do
    test "accepts closed classifications and never authorizes expiry against tracker RTC", ctx do
      request_hash = hex(ctx.hashes["challenge_request"])
      attempt_id = hex(ctx.inputs["attempt_id"])
      server_nonce = hex(ctx.inputs["server_nonce"])

      assert {:ok,
              %{
                payload: %{
                  classification: :recoverable,
                  reason: :none,
                  attempt_id: ^attempt_id,
                  server_nonce: ^server_nonce,
                  expires_at_unix_s: 1
                }
              }} =
               verify_payload(ctx, 2, challenge_payload(request_hash, 1, 0, attempt_id, server_nonce, 1))

      assert {:ok,
              %{
                payload: %{
                  classification: :not_enrolled,
                  reason: :recovery_ineligible,
                  attempt_id: nil,
                  server_nonce: nil,
                  expires_at_unix_s: 0
                }
              }} =
               verify_payload(ctx, 2, challenge_payload(request_hash, 2, 2, <<>>, <<>>, 0))

      assert {:ok, %{payload: %{classification: :blocked, reason: :attempt_limit}}} =
               verify_payload(ctx, 2, challenge_payload(request_hash, 3, 5, <<>>, <<>>, 0))
    end

    test "rejects bad hashes/enums and forbidden attempt/nonce/expiry combinations", ctx do
      request_hash = hex(ctx.hashes["challenge_request"])
      attempt_id = hex(ctx.inputs["attempt_id"])
      server_nonce = hex(ctx.inputs["server_nonce"])

      invalid_payloads = [
        challenge_payload(<<0::248>>, 1, 0, attempt_id, server_nonce, 1),
        challenge_payload(request_hash, 0, 0, attempt_id, server_nonce, 1),
        challenge_payload(request_hash, 4, 0, attempt_id, server_nonce, 1),
        challenge_payload(request_hash, 1, 6, attempt_id, server_nonce, 1),
        challenge_payload(request_hash, 1, 1, attempt_id, server_nonce, 1),
        challenge_payload(request_hash, 1, 0, <<>>, server_nonce, 1),
        challenge_payload(request_hash, 1, 0, <<0::120>>, server_nonce, 1),
        challenge_payload(request_hash, 1, 0, attempt_id, <<>>, 1),
        challenge_payload(request_hash, 1, 0, attempt_id, <<0::248>>, 1),
        challenge_payload(request_hash, 1, 0, attempt_id, server_nonce, 0),
        challenge_payload(request_hash, 2, 2, attempt_id, <<>>, 0),
        challenge_payload(request_hash, 2, 2, <<>>, server_nonce, 0),
        challenge_payload(request_hash, 2, 2, <<>>, <<>>, 1),
        challenge_payload(request_hash, 3, 5, attempt_id, <<>>, 0),
        challenge_payload(request_hash, 3, 5, <<>>, server_nonce, 0),
        challenge_payload(request_hash, 3, 5, <<>>, <<>>, 1)
      ]

      assert_all_payloads_rejected(ctx, 2, invalid_payloads)
    end
  end

  describe "lifecycle payload invariants" do
    test "accepts pending, committed, expired, and blocked canonical shapes", ctx do
      attempt_id = hex(ctx.inputs["attempt_id"])
      challenge_hash = hex(ctx.hashes["challenge_envelope"])
      fingerprint = hex(ctx.hashes["candidate_fingerprint"])
      device_id = hex(ctx.inputs["logical_device_id"])
      commit_hash = hex(ctx.hashes["accepted_commit_signing_bytes"])

      assert {:ok, %{payload: %{lifecycle: :pending, reason: :none, logical_device_id: nil}}} =
               verify_payload(
                 ctx,
                 3,
                 lifecycle_payload(attempt_id, challenge_hash, fingerprint, 1, 0, <<>>, 0, <<>>)
               )

      assert {:ok,
              %{
                payload: %{
                  lifecycle: :committed,
                  reason: :none,
                  logical_device_id: ^device_id,
                  credential_epoch: 7,
                  accepted_commit_signing_bytes_hash: ^commit_hash
                }
              }} =
               verify_payload(
                 ctx,
                 3,
                 lifecycle_payload(attempt_id, challenge_hash, fingerprint, 2, 0, device_id, 7, commit_hash)
               )

      assert {:ok, %{payload: %{lifecycle: :expired, logical_device_id: nil}}} =
               verify_payload(
                 ctx,
                 3,
                 lifecycle_payload(attempt_id, challenge_hash, fingerprint, 3, 2, <<>>, 0, <<>>)
               )

      assert {:ok, %{payload: %{lifecycle: :blocked, reason: :attempt_limit}}} =
               verify_payload(
                 ctx,
                 3,
                 lifecycle_payload(attempt_id, challenge_hash, fingerprint, 4, 5, <<>>, 0, <<>>)
               )
    end

    test "rejects malformed fixed fields, unknown enums, and forbidden lifecycle combinations", ctx do
      attempt_id = hex(ctx.inputs["attempt_id"])
      challenge_hash = hex(ctx.hashes["challenge_envelope"])
      fingerprint = hex(ctx.hashes["candidate_fingerprint"])
      device_id = hex(ctx.inputs["logical_device_id"])
      commit_hash = hex(ctx.hashes["accepted_commit_signing_bytes"])

      invalid_payloads = [
        lifecycle_payload(<<0::120>>, challenge_hash, fingerprint, 1, 0, <<>>, 0, <<>>),
        lifecycle_payload(attempt_id, <<0::248>>, fingerprint, 1, 0, <<>>, 0, <<>>),
        lifecycle_payload(attempt_id, challenge_hash, <<0::248>>, 1, 0, <<>>, 0, <<>>),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 0, 0, <<>>, 0, <<>>),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 5, 0, <<>>, 0, <<>>),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 1, 6, <<>>, 0, <<>>),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 2, 1, device_id, 7, commit_hash),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 2, 0, <<>>, 7, commit_hash),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 2, 0, <<0::120>>, 7, commit_hash),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 2, 0, device_id, 0, commit_hash),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 2, 0, device_id, 7, <<>>),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 2, 0, device_id, 7, <<0::248>>),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 1, 0, device_id, 0, <<>>),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 1, 0, <<>>, 1, <<>>),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 1, 0, <<>>, 0, commit_hash),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 3, 2, device_id, 0, <<>>),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 3, 2, <<>>, 1, <<>>),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 3, 2, <<>>, 0, commit_hash),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 4, 0, <<>>, 0, <<>>),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 4, 5, device_id, 0, <<>>),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 4, 5, <<>>, 1, <<>>),
        lifecycle_payload(attempt_id, challenge_hash, fingerprint, 4, 5, <<>>, 0, commit_hash)
      ]

      assert_all_payloads_rejected(ctx, 3, invalid_payloads)
    end
  end

  describe "payload canonical framing" do
    test "rejects payload version changes, truncation, trailing bytes, and alternate domains", ctx do
      server_public = hex(ctx.inputs["server_public"])
      server_seed = hex(ctx.inputs["server_seed"])
      payload = hex(ctx.receipts["registration_payload"])
      domain_size = byte_size(@registration_payload_domain)

      invalid_payloads = [
        replace_byte(payload, domain_size, 0x01),
        binary_part(payload, 0, byte_size(payload) - 1),
        payload <> <<0>>,
        "RacingOrg-ServerRegistrationReceipt-v2x" <> binary_part(payload, domain_size, byte_size(payload) - domain_size)
      ]

      for invalid_payload <- invalid_payloads do
        assert {:error, _reason} =
                 1
                 |> signed_envelope(invalid_payload, server_seed)
                 |> Contract.verify_receipt_envelope(server_public)
      end
    end
  end

  defp verify_payload(ctx, type, payload) do
    type
    |> signed_envelope(payload, hex(ctx.inputs["server_seed"]))
    |> Contract.verify_receipt_envelope(hex(ctx.inputs["server_public"]))
  end

  defp assert_all_payloads_rejected(ctx, type, payloads) do
    for payload <- payloads do
      assert {:error, _reason} = verify_payload(ctx, type, payload)
    end
  end

  defp registration_payload(request_hash, outcome, reason, logical_device_id, credential_epoch) do
    @registration_payload_domain <>
      <<@version>> <>
      lp(request_hash) <>
      <<outcome, reason>> <>
      lp(logical_device_id) <>
      <<credential_epoch::unsigned-big-integer-size(32)>>
  end

  defp challenge_payload(
         request_hash,
         classification,
         reason,
         attempt_id,
         server_nonce,
         expires_at_unix_s
       ) do
    @challenge_payload_domain <>
      <<@version>> <>
      lp(request_hash) <>
      <<classification, reason>> <>
      lp(attempt_id) <>
      lp(server_nonce) <>
      <<expires_at_unix_s::unsigned-big-integer-size(64)>>
  end

  defp lifecycle_payload(
         attempt_id,
         challenge_envelope_hash,
         candidate_fingerprint,
         lifecycle,
         reason,
         logical_device_id,
         credential_epoch,
         accepted_commit_signing_bytes_hash
       ) do
    @lifecycle_payload_domain <>
      <<@version>> <>
      lp(attempt_id) <>
      lp(challenge_envelope_hash) <>
      lp(candidate_fingerprint) <>
      <<lifecycle, reason>> <>
      lp(logical_device_id) <>
      <<credential_epoch::unsigned-big-integer-size(32)>> <>
      lp(accepted_commit_signing_bytes_hash)
  end

  defp signed_envelope(type, payload, server_seed) do
    signing_bytes = @receipt_domain <> <<@version, type>> <> lp(payload)
    signature = Primitives.ed25519_sign(server_seed, signing_bytes)
    signing_bytes <> lp(signature)
  end

  defp raw_envelope(type, payload, signature) do
    @receipt_domain <> <<@version, type>> <> lp(payload) <> lp(signature)
  end

  defp lp(binary), do: <<byte_size(binary)::unsigned-big-integer-size(16), binary::binary>>
  defp hex(value), do: Base.decode16!(value, case: :lower)
  defp hex_string(value), do: Base.encode16(value, case: :lower)

  defp flip_byte(binary, offset) do
    <<prefix::binary-size(offset), byte, suffix::binary>> = binary
    <<prefix::binary, Bitwise.bxor(byte, 0x01), suffix::binary>>
  end

  defp replace_byte(binary, offset, replacement) do
    <<prefix::binary-size(offset), _byte, suffix::binary>> = binary
    <<prefix::binary, replacement, suffix::binary>>
  end

  defp restore_server_identity(nil), do: Application.delete_env(:racing_org_tracker_pro, ServerIdentity)

  defp restore_server_identity(value),
    do: Application.put_env(:racing_org_tracker_pro, ServerIdentity, value)
end
