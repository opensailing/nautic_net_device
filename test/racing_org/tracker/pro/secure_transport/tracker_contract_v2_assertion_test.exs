defmodule RacingOrg.Tracker.Pro.SecureTransport.TrackerContractV2AssertionTest do
  @moduledoc """
  Pure TRACKER v2 candidate assertions and Raspberry Pi serial canonicalization.

  The golden bytes are generated independently from the implementation and pin the
  literal domains, version byte, field order, u16-big-endian framing, Ed25519 signing
  inputs, and exact full-envelope hashing used by commit/status candidate PoP.
  """

  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.TrackerContractV2, as: Contract

  @golden_path Application.app_dir(
                 :racing_org_tracker_pro,
                 "priv/secure_transport/registration_recovery_v2_kat.json"
               )

  setup_all do
    golden = @golden_path |> File.read!() |> Jason.decode!()

    %{
      inputs: golden["inputs"],
      assertions: golden["assertions"],
      receipts: golden["receipts"],
      hashes: %{
        "challenge_envelope" => golden["receipts"]["challenge_envelope_hash_hex"],
        "accepted_commit_signing_bytes" => golden["assertions"]["commit_signing_bytes_hash_hex"]
      }
    }
  end

  describe "protocol constants" do
    test "pins the authoritative version and provider" do
      assert Contract.version() == 0x02
      assert Contract.provider() == "raspberry_pi_soc_serial_v1"
    end
  end

  describe "local Raspberry Pi serial normalization" do
    test "accepts 1..16 mixed-case hex digits, optional lowercase 0x, and pads lowercase" do
      assert {:ok, "0000000000000001"} = Contract.normalize_local_serial("1")
      assert {:ok, "000000000000abcd"} = Contract.normalize_local_serial("AbCd")
      assert {:ok, "000000001234abcd"} = Contract.normalize_local_serial("0x1234ABCD")
      assert {:ok, "ffffffffffffffff"} = Contract.normalize_local_serial("FFFFFFFFFFFFFFFF")
    end

    test "strips only trailing NUL and ASCII whitespace" do
      assert {:ok, "000000000000abcd"} = Contract.normalize_local_serial("AbCd\0 \t\n\v\f\r\0")

      assert {:error, :invalid_serial} = Contract.normalize_local_serial(" AbCd")
      assert {:error, :invalid_serial} = Contract.normalize_local_serial("Ab Cd")
      assert {:error, :invalid_serial} = Contract.normalize_local_serial("AbCd ")
      assert {:error, :invalid_serial} = Contract.normalize_local_serial("AbCd\0x")
    end

    test "rejects empty, zero, overlong, malformed, signed, and noncanonical prefixes" do
      for invalid <- [
            "",
            "\0\r\n",
            "0",
            "0000000000000000",
            "0x0",
            "1234567890abcdef0",
            "0x1234567890abcdef0",
            "0X1",
            "+1",
            "-1",
            "xyz",
            <<0xFF>>,
            nil
          ] do
        assert {:error, :invalid_serial} = Contract.normalize_local_serial(invalid)
      end
    end

    test "reconciles agreeing sources and fails closed on conflicts or malformed present sources" do
      assert {:ok, "0000000000000001"} =
               Contract.normalize_local_serial_sources([nil, "1\n", "0x0001\0", "0000000000000001"])

      assert {:ok, "0000000000000001"} =
               Contract.normalize_local_serial_sources(%{
                 cpuinfo: "1\n",
                 device_tree: "0x0001\0",
                 unavailable: nil
               })

      assert {:error, :serial_unavailable} = Contract.normalize_local_serial_sources([])
      assert {:error, :serial_unavailable} = Contract.normalize_local_serial_sources([nil, nil])

      assert {:error, :conflicting_serial_sources} =
               Contract.normalize_local_serial_sources(["1", "2"])

      assert {:error, :invalid_serial_source} =
               Contract.normalize_local_serial_sources(["1", "not-hex"])

      assert {:error, :invalid_serial_sources} = Contract.normalize_local_serial_sources(:not_a_list)

      assert {:error, :invalid_serial_sources} =
               Contract.normalize_local_serial_sources(["1" | :not_a_proper_list])
    end

    test "wire serial is exactly 16 lowercase nonzero hex ASCII bytes" do
      assert :ok = Contract.validate_wire_serial("000000001234abcd")
      assert :ok = Contract.validate_wire_serial("ffffffffffffffff")

      for invalid <- [
            "",
            "1",
            "0000000000000000",
            "000000001234ABCD",
            "0x000000001234ab",
            "000000001234abcg",
            <<0xFF, 0::size(120)>>,
            nil
          ] do
        assert {:error, :invalid_serial} = Contract.validate_wire_serial(invalid)
      end
    end
  end

  describe "candidate assertion golden vectors" do
    test "registration assertion and detached signature are byte-identical", ctx do
      serial = ctx.inputs["serial"]
      candidate_public = hex(ctx.inputs["candidate_public_key_hex"])
      client_nonce = hex(ctx.inputs["client_nonce_hex"])
      candidate_seed = hex(ctx.inputs["candidate_private_seed_hex"])

      assert {:ok, assertion} = Contract.registration_assertion(serial, candidate_public, client_nonce)
      assert hex_string(assertion) == ctx.assertions["registration_signing_bytes_hex"]

      expected_prefix =
        "RacingOrg-TrackerRegister-v2" <>
          <<0x02>> <>
          lp("raspberry_pi_soc_serial_v1") <>
          lp(serial)

      assert String.starts_with?(assertion, expected_prefix)
      signature = Primitives.ed25519_sign(candidate_seed, assertion)
      assert hex_string(signature) == ctx.assertions["registration_signature_hex"]
      assert Primitives.ed25519_verify(candidate_public, assertion, signature)
    end

    test "recovery challenge assertion has its distinct literal domain", ctx do
      candidate_public = hex(ctx.inputs["candidate_public_key_hex"])
      client_nonce = hex(ctx.inputs["client_nonce_hex"])

      assert {:ok, assertion} =
               Contract.recovery_challenge_assertion(ctx.inputs["serial"], candidate_public, client_nonce)

      assert hex_string(assertion) == ctx.assertions["challenge_signing_bytes_hex"]
      assert String.starts_with?(assertion, "RacingOrg-TrackerRecoveryChallenge-v2" <> <<0x02>>)
      refute String.starts_with?(assertion, "RacingOrg-TrackerRegister-v2")

      signature = Primitives.ed25519_sign(hex(ctx.inputs["candidate_private_seed_hex"]), assertion)
      assert hex_string(signature) == ctx.assertions["challenge_signature_hex"]
    end

    test "commit hashes the exact full signed challenge envelope before framing", ctx do
      attempt_id = hex(ctx.inputs["attempt_id_raw_hex"])
      candidate_public = hex(ctx.inputs["candidate_public_key_hex"])
      challenge_envelope = hex(ctx.receipts["challenge_envelope_hex"])

      assert Contract.challenge_envelope_hash(challenge_envelope) == hex(ctx.hashes["challenge_envelope"])

      assert {:ok, assertion} =
               Contract.recovery_commit_assertion(
                 attempt_id,
                 candidate_public,
                 Contract.challenge_envelope_hash(challenge_envelope)
               )

      assert hex_string(assertion) == ctx.assertions["commit_signing_bytes_hex"]
      assert Primitives.sha256(assertion) == hex(ctx.hashes["accepted_commit_signing_bytes"])

      signature = Primitives.ed25519_sign(hex(ctx.inputs["candidate_private_seed_hex"]), assertion)
      assert hex_string(signature) == ctx.assertions["commit_signature_hex"]

      tampered_envelope = flip_byte(challenge_envelope, byte_size(challenge_envelope) - 1)
      tampered_hash = Contract.challenge_envelope_hash(tampered_envelope)
      refute tampered_hash == Contract.challenge_envelope_hash(challenge_envelope)

      assert {:ok, tampered_assertion} =
               Contract.recovery_commit_assertion(attempt_id, candidate_public, tampered_hash)

      refute tampered_assertion == assertion
    end

    test "candidate-PoP status binds attempt, key, challenge hash, and fresh nonce", ctx do
      assert {:ok, assertion} =
               Contract.recovery_status_assertion(
                 hex(ctx.inputs["attempt_id_raw_hex"]),
                 hex(ctx.inputs["candidate_public_key_hex"]),
                 hex(ctx.hashes["challenge_envelope"]),
                 hex(ctx.inputs["status_client_nonce_hex"])
               )

      assert hex_string(assertion) == ctx.assertions["status_signing_bytes_hex"]
      signature = Primitives.ed25519_sign(hex(ctx.inputs["candidate_private_seed_hex"]), assertion)
      assert hex_string(signature) == ctx.assertions["status_signature_hex"]
    end
  end

  describe "assertion input validation" do
    setup ctx do
      %{
        serial: ctx.inputs["serial"],
        public_key: hex(ctx.inputs["candidate_public_key_hex"]),
        nonce: hex(ctx.inputs["client_nonce_hex"]),
        attempt_id: hex(ctx.inputs["attempt_id_raw_hex"]),
        challenge_hash: hex(ctx.hashes["challenge_envelope"])
      }
    end

    test "registration/challenge reject non-wire serials and wrong key/nonce sizes", ctx do
      for builder <- [&Contract.registration_assertion/3, &Contract.recovery_challenge_assertion/3] do
        assert {:error, :invalid_serial} = builder.("1234", ctx.public_key, ctx.nonce)
        assert {:error, :bad_candidate_public_key_length} = builder.(ctx.serial, <<0::248>>, ctx.nonce)
        assert {:error, :bad_candidate_public_key_length} = builder.(ctx.serial, <<0::264>>, ctx.nonce)
        assert {:error, :bad_client_nonce_length} = builder.(ctx.serial, ctx.public_key, <<0::248>>)
        assert {:error, :bad_client_nonce_length} = builder.(ctx.serial, ctx.public_key, <<0::264>>)
        assert {:error, :bad_candidate_public_key_length} = builder.(ctx.serial, nil, ctx.nonce)
      end
    end

    test "commit/status reject malformed raw UUIDs, hashes, keys, and status nonces", ctx do
      assert {:error, :bad_attempt_id_length} =
               Contract.recovery_commit_assertion(<<0::120>>, ctx.public_key, ctx.challenge_hash)

      assert {:error, :bad_candidate_public_key_length} =
               Contract.recovery_commit_assertion(ctx.attempt_id, <<0::248>>, ctx.challenge_hash)

      assert {:error, :bad_challenge_envelope_hash_length} =
               Contract.recovery_commit_assertion(ctx.attempt_id, ctx.public_key, <<0::248>>)

      assert {:error, :bad_client_nonce_length} =
               Contract.recovery_status_assertion(ctx.attempt_id, ctx.public_key, ctx.challenge_hash, <<0::248>>)

      assert {:error, :bad_attempt_id_length} =
               Contract.recovery_status_assertion(nil, ctx.public_key, ctx.challenge_hash, ctx.nonce)
    end
  end

  defp lp(bin), do: <<byte_size(bin)::unsigned-big-integer-size(16), bin::binary>>
  defp hex(value), do: Base.decode16!(value, case: :lower)
  defp hex_string(value), do: Base.encode16(value, case: :lower)

  defp flip_byte(binary, offset) do
    <<prefix::binary-size(offset), byte, suffix::binary>> = binary
    <<prefix::binary, Bitwise.bxor(byte, 0x01), suffix::binary>>
  end
end
