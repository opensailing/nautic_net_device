defmodule RacingOrg.Tracker.Pro.SecureTransport.TrackerContractV2 do
  @moduledoc """
  Pure, byte-exact TRACKER v2 identity registration and serial-recovery contract.

  This module owns only canonical binary construction, local serial normalization,
  canonical receipt-response decoding, pinned/injected Ed25519 receipt verification,
  and strict receipt payload parsing. It performs no HTTP, persistence, clock-based
  expiry authorization, serial lookup, or device lifecycle mutation. Legacy
  `RacingOrg.Tracker.Pro.SecureTransport.RegisterClient` v1 is intentionally separate.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity

  @version 0x02
  @provider "raspberry_pi_soc_serial_v1"

  @registration_domain "RacingOrg-TrackerRegister-v2"
  @challenge_domain "RacingOrg-TrackerRecoveryChallenge-v2"
  @commit_domain "RacingOrg-TrackerRecoveryCommit-v2"
  @status_domain "RacingOrg-TrackerRecoveryStatus-v2"

  @receipt_domain "RacingOrg-ServerReceipt-v2"
  @registration_payload_domain "RacingOrg-ServerRegistrationReceipt-v2"
  @challenge_payload_domain "RacingOrg-ServerRecoveryChallengeReceipt-v2"
  @lifecycle_payload_domain "RacingOrg-ServerRecoveryLifecycleReceipt-v2"

  @receipt_types %{1 => :registration, 2 => :challenge, 3 => :lifecycle}
  @receipt_type_codes Map.new(@receipt_types, fn {code, name} -> {name, code} end)

  @registration_outcomes %{1 => :registered, 2 => :recovery_required, 3 => :blocked}
  @challenge_classifications %{1 => :recoverable, 2 => :not_enrolled, 3 => :blocked}
  @lifecycles %{1 => :pending, 2 => :committed, 3 => :expired, 4 => :blocked}

  @reasons %{
    0 => :none,
    1 => :recovery_disabled,
    2 => :recovery_ineligible,
    3 => :active_session_conflict,
    4 => :identity_conflict,
    5 => :attempt_limit
  }

  @u16_max 0xFFFF
  @candidate_public_key_size 32
  @client_nonce_size 32
  @uuid_size 16
  @hash_size 32
  @server_signature_size 64
  @server_nonce_size 32
  @zero_wire_serial "0000000000000000"

  @max_registration_payload_size byte_size(@registration_payload_domain) + 1 + 34 + 1 + 1 + 18 + 4
  @max_challenge_payload_size byte_size(@challenge_payload_domain) + 1 + 34 + 1 + 1 + 18 + 34 + 8
  @max_lifecycle_payload_size byte_size(@lifecycle_payload_domain) + 1 + 18 + 34 + 34 + 1 + 1 + 18 + 4 + 34
  @max_receipt_payload_sizes %{
    registration: @max_registration_payload_size,
    challenge: @max_challenge_payload_size,
    lifecycle: @max_lifecycle_payload_size
  }
  @max_receipt_payload_size @max_receipt_payload_sizes |> Map.values() |> Enum.max()
  @max_receipt_envelope_size byte_size(@receipt_domain) + 1 + 1 + 2 + @max_receipt_payload_size + 2 +
                               @server_signature_size
  @max_receipt_base64_size 4 * div(@max_receipt_envelope_size + 2, 3)

  @type receipt_type :: :registration | :challenge | :lifecycle
  @type reason ::
          :none
          | :recovery_disabled
          | :recovery_ineligible
          | :active_session_conflict
          | :identity_conflict
          | :attempt_limit

  @doc "The literal protocol version byte (`0x02`)."
  @spec version() :: 0x02
  def version, do: @version

  @doc "The only accepted TRACKER v2 hardware identity provider."
  @spec provider() :: binary()
  def provider, do: @provider

  @doc """
  Normalize one local Raspberry Pi serial source.

  Trailing NUL and ASCII whitespace bytes are stripped. The remaining value may have
  a literal lowercase `0x` prefix followed by 1..16 mixed-case hex digits. Zero is
  rejected and success is exactly 16 lowercase hex ASCII bytes.
  """
  @spec normalize_local_serial(term()) :: {:ok, binary()} | {:error, :invalid_serial}
  def normalize_local_serial(raw) when is_binary(raw) do
    raw
    |> trim_local_serial_suffix()
    |> remove_local_hex_prefix()
    |> normalize_local_hex_digits()
  end

  def normalize_local_serial(_), do: {:error, :invalid_serial}

  @doc """
  Reconcile multiple optional local serial sources without I/O.

  `nil` means that a source was unavailable. Every present source must normalize
  successfully and all normalized values must agree; conflicts and malformed present
  sources fail closed.
  """
  @spec normalize_local_serial_sources(term()) ::
          {:ok, binary()}
          | {:error,
             :serial_unavailable
             | :invalid_serial_source
             | :conflicting_serial_sources
             | :invalid_serial_sources}
  def normalize_local_serial_sources(sources) when is_map(sources) do
    sources
    |> Map.values()
    |> normalize_local_serial_sources()
  end

  def normalize_local_serial_sources(sources) when is_list(sources) do
    if proper_list?(sources) do
      present_sources = Enum.reject(sources, &is_nil/1)

      case present_sources do
        [] ->
          {:error, :serial_unavailable}

        _ ->
          with {:ok, normalized} <- normalize_all_serial_sources(present_sources) do
            case Enum.uniq(normalized) do
              [serial] -> {:ok, serial}
              _ -> {:error, :conflicting_serial_sources}
            end
          end
      end
    else
      {:error, :invalid_serial_sources}
    end
  end

  def normalize_local_serial_sources(_), do: {:error, :invalid_serial_sources}

  @doc "Validate the exact nonzero 16-byte lowercase hexadecimal wire serial."
  @spec validate_wire_serial(term()) :: :ok | {:error, :invalid_serial}
  def validate_wire_serial(serial)
      when is_binary(serial) and byte_size(serial) == 16 and serial != @zero_wire_serial do
    if Enum.all?(:binary.bin_to_list(serial), &wire_hex_byte?/1) do
      :ok
    else
      {:error, :invalid_serial}
    end
  end

  def validate_wire_serial(_), do: {:error, :invalid_serial}

  @doc "Build canonical `RacingOrg-TrackerRegister-v2` candidate signing bytes."
  @spec registration_assertion(binary(), binary(), binary()) :: {:ok, binary()} | {:error, atom()}
  def registration_assertion(serial, candidate_public_key, client_nonce) do
    with :ok <- validate_wire_serial(serial),
         :ok <- exact_binary(candidate_public_key, @candidate_public_key_size, :bad_candidate_public_key_length),
         :ok <- exact_binary(client_nonce, @client_nonce_size, :bad_client_nonce_length) do
      {:ok,
       @registration_domain <>
         <<@version>> <>
         lp(@provider) <>
         lp(serial) <>
         lp(candidate_public_key) <>
         lp(client_nonce)}
    end
  end

  @doc "Build canonical `RacingOrg-TrackerRecoveryChallenge-v2` candidate signing bytes."
  @spec recovery_challenge_assertion(binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, atom()}
  def recovery_challenge_assertion(serial, candidate_public_key, client_nonce) do
    with :ok <- validate_wire_serial(serial),
         :ok <- exact_binary(candidate_public_key, @candidate_public_key_size, :bad_candidate_public_key_length),
         :ok <- exact_binary(client_nonce, @client_nonce_size, :bad_client_nonce_length) do
      {:ok,
       @challenge_domain <>
         <<@version>> <>
         lp(@provider) <>
         lp(serial) <>
         lp(candidate_public_key) <>
         lp(client_nonce)}
    end
  end

  @doc "Build canonical `RacingOrg-TrackerRecoveryCommit-v2` candidate signing bytes."
  @spec recovery_commit_assertion(binary(), binary(), binary()) :: {:ok, binary()} | {:error, atom()}
  def recovery_commit_assertion(attempt_id, candidate_public_key, challenge_envelope_hash) do
    with :ok <- exact_binary(attempt_id, @uuid_size, :bad_attempt_id_length),
         :ok <- exact_binary(candidate_public_key, @candidate_public_key_size, :bad_candidate_public_key_length),
         :ok <- exact_binary(challenge_envelope_hash, @hash_size, :bad_challenge_envelope_hash_length) do
      {:ok,
       @commit_domain <>
         <<@version>> <>
         lp(attempt_id) <>
         lp(candidate_public_key) <>
         lp(challenge_envelope_hash)}
    end
  end

  @doc "Build canonical candidate-PoP `RacingOrg-TrackerRecoveryStatus-v2` signing bytes."
  @spec recovery_status_assertion(binary(), binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, atom()}
  def recovery_status_assertion(attempt_id, candidate_public_key, challenge_envelope_hash, client_nonce) do
    with :ok <- exact_binary(attempt_id, @uuid_size, :bad_attempt_id_length),
         :ok <- exact_binary(candidate_public_key, @candidate_public_key_size, :bad_candidate_public_key_length),
         :ok <- exact_binary(challenge_envelope_hash, @hash_size, :bad_challenge_envelope_hash_length),
         :ok <- exact_binary(client_nonce, @client_nonce_size, :bad_client_nonce_length) do
      {:ok,
       @status_domain <>
         <<@version>> <>
         lp(attempt_id) <>
         lp(candidate_public_key) <>
         lp(challenge_envelope_hash) <>
         lp(client_nonce)}
    end
  end

  @doc "SHA-256 of the exact full signed challenge receipt envelope."
  @spec challenge_envelope_hash(binary()) :: binary()
  def challenge_envelope_hash(envelope) when is_binary(envelope), do: Primitives.sha256(envelope)

  @doc "Build exact outer server-receipt signing bytes for any u16-framed payload."
  @spec receipt_signing_bytes(receipt_type() | 1..3, binary()) :: {:ok, binary()} | {:error, atom()}
  def receipt_signing_bytes(receipt_type, payload) do
    with {:ok, type_code, _type_name} <- receipt_type(receipt_type),
         :ok <- bounded_receipt_payload(payload) do
      {:ok, @receipt_domain <> <<@version, type_code>> <> lp(payload)}
    end
  end

  @doc "Verify and strictly parse a receipt envelope with the configured pinned server key."
  @spec verify_receipt_envelope(binary()) :: {:ok, map()} | {:error, atom()}
  def verify_receipt_envelope(envelope) do
    with {:ok, server_public_key} <- ServerIdentity.fetch_public_key() do
      verify_receipt_envelope(envelope, server_public_key)
    end
  end

  @doc "Verify and strictly parse a receipt envelope with an injected raw Ed25519 public key."
  @spec verify_receipt_envelope(term(), term()) :: {:ok, map()} | {:error, atom()}
  def verify_receipt_envelope(envelope, server_public_key) do
    with :ok <- exact_binary(server_public_key, @candidate_public_key_size, :bad_server_public_key_length),
         {:ok, outer} <- parse_receipt_envelope(envelope),
         signing_bytes =
           @receipt_domain <> <<@version, outer.receipt_type_code>> <> lp(outer.payload_bytes),
         :ok <- verify_server_signature(server_public_key, signing_bytes, outer.server_signature),
         {:ok, _type_code, receipt_type} <- receipt_type(outer.receipt_type_code),
         {:ok, parsed_payload} <- parse_payload(receipt_type, outer.payload_bytes) do
      {:ok,
       %{
         version: @version,
         receipt_type: receipt_type,
         envelope: envelope,
         envelope_hash: Primitives.sha256(envelope),
         payload_bytes: outer.payload_bytes,
         server_signature: outer.server_signature,
         payload: parsed_payload
       }}
    end
  end

  @doc "Decode the exact JSON receipt wrapper and verify with the configured pinned key."
  @spec verify_receipt_response(term()) :: {:ok, map()} | {:error, atom()}
  def verify_receipt_response(response) do
    with {:ok, envelope} <- decode_receipt_response(response) do
      verify_receipt_envelope(envelope)
    end
  end

  @doc "Decode the exact JSON receipt wrapper and verify with an injected server key."
  @spec verify_receipt_response(term(), term()) :: {:ok, map()} | {:error, atom()}
  def verify_receipt_response(response, server_public_key) do
    with {:ok, envelope} <- decode_receipt_response(response) do
      verify_receipt_envelope(envelope, server_public_key)
    end
  end

  defp normalize_all_serial_sources(sources) do
    Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, normalized} ->
      case normalize_local_serial(source) do
        {:ok, serial} -> {:cont, {:ok, [serial | normalized]}}
        {:error, :invalid_serial} -> {:halt, {:error, :invalid_serial_source}}
      end
    end)
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false

  defp trim_local_serial_suffix(<<>>), do: <<>>

  defp trim_local_serial_suffix(serial) do
    offset = byte_size(serial) - 1

    case :binary.at(serial, offset) do
      byte when byte in [0x00, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20] ->
        serial
        |> binary_part(0, offset)
        |> trim_local_serial_suffix()

      _ ->
        serial
    end
  end

  defp remove_local_hex_prefix(<<"0x", digits::binary>>), do: digits
  defp remove_local_hex_prefix(digits), do: digits

  defp normalize_local_hex_digits(digits) do
    if byte_size(digits) in 1..16 and Enum.all?(:binary.bin_to_list(digits), &local_hex_byte?/1) do
      {value, ""} = Integer.parse(digits, 16)

      if value == 0 do
        {:error, :invalid_serial}
      else
        {:ok, value |> Integer.to_string(16) |> String.downcase(:ascii) |> String.pad_leading(16, "0")}
      end
    else
      {:error, :invalid_serial}
    end
  end

  defp local_hex_byte?(byte) when byte in ?0..?9, do: true
  defp local_hex_byte?(byte) when byte in ?a..?f, do: true
  defp local_hex_byte?(byte) when byte in ?A..?F, do: true
  defp local_hex_byte?(_), do: false

  defp wire_hex_byte?(byte) when byte in ?0..?9, do: true
  defp wire_hex_byte?(byte) when byte in ?a..?f, do: true
  defp wire_hex_byte?(_), do: false

  defp exact_binary(value, size, _error) when is_binary(value) and byte_size(value) == size, do: :ok
  defp exact_binary(_value, _size, error), do: {:error, error}

  defp optional_binary(value, size, _error)
       when is_binary(value) and (byte_size(value) == 0 or byte_size(value) == size),
       do: :ok

  defp optional_binary(_value, _size, error), do: {:error, error}

  defp bounded_receipt_payload(value) when is_binary(value) and byte_size(value) <= @u16_max,
    do: :ok

  defp bounded_receipt_payload(_value), do: {:error, :receipt_payload_too_large}

  defp lp(binary), do: <<byte_size(binary)::unsigned-big-integer-size(16), binary::binary>>

  defp receipt_type(type) when is_atom(type) do
    case Map.fetch(@receipt_type_codes, type) do
      {:ok, code} -> {:ok, code, type}
      :error -> {:error, :unknown_receipt_type}
    end
  end

  defp receipt_type(code) when is_integer(code) do
    case Map.fetch(@receipt_types, code) do
      {:ok, type} -> {:ok, code, type}
      :error -> {:error, :unknown_receipt_type}
    end
  end

  defp receipt_type(_), do: {:error, :unknown_receipt_type}

  defp parse_receipt_envelope(envelope) when not is_binary(envelope),
    do: {:error, :invalid_receipt_envelope}

  defp parse_receipt_envelope(envelope) when byte_size(envelope) > @max_receipt_envelope_size,
    do: {:error, :receipt_envelope_too_large}

  defp parse_receipt_envelope(envelope) do
    domain_size = byte_size(@receipt_domain)

    case envelope do
      <<domain::binary-size(domain_size), version, type_code, rest::binary>> ->
        with :ok <- ensure(domain == @receipt_domain, :bad_receipt_domain),
             :ok <- ensure(version == @version, :unsupported_receipt_version),
             {:ok, payload, after_payload} <- take_lp(rest),
             {:ok, signature, trailing} <- take_lp(after_payload),
             :ok <- ensure(trailing == <<>>, :trailing_bytes),
             :ok <- exact_binary(signature, @server_signature_size, :bad_server_signature_length) do
          {:ok,
           %{
             receipt_type_code: type_code,
             payload_bytes: payload,
             server_signature: signature
           }}
        end

      _ ->
        if byte_size(envelope) < domain_size + 2 do
          {:error, :truncated_receipt_envelope}
        else
          {:error, :bad_receipt_domain}
        end
    end
  end

  defp verify_server_signature(server_public_key, signing_bytes, signature) do
    if Primitives.ed25519_verify(server_public_key, signing_bytes, signature) do
      :ok
    else
      {:error, :bad_server_signature}
    end
  end

  defp decode_receipt_response(%{"receipt" => encoded} = response)
       when map_size(response) == 1 and is_binary(encoded) do
    decode_canonical_base64(encoded)
  end

  defp decode_receipt_response(_), do: {:error, :invalid_receipt_response}

  defp decode_canonical_base64(encoded)
       when byte_size(encoded) > 0 and byte_size(encoded) <= @max_receipt_base64_size do
    case Base.decode64(encoded) do
      {:ok, decoded} ->
        if Base.encode64(decoded) == encoded do
          {:ok, decoded}
        else
          {:error, :invalid_receipt_base64}
        end

      :error ->
        {:error, :invalid_receipt_base64}
    end
  end

  defp decode_canonical_base64(_), do: {:error, :invalid_receipt_base64}

  defp parse_payload(:registration, payload), do: parse_registration_payload(payload)
  defp parse_payload(:challenge, payload), do: parse_challenge_payload(payload)
  defp parse_payload(:lifecycle, payload), do: parse_lifecycle_payload(payload)

  defp parse_registration_payload(payload) do
    with {:ok, rest} <- payload_body(payload, @registration_payload_domain),
         {:ok, request_hash, rest} <- take_lp(rest),
         :ok <- exact_binary(request_hash, @hash_size, :bad_request_hash_length),
         {:ok, outcome_code, rest} <- take_u8(rest),
         {:ok, outcome} <- closed_enum(@registration_outcomes, outcome_code, :unknown_registration_outcome),
         {:ok, reason_code, rest} <- take_u8(rest),
         {:ok, reason} <- closed_enum(@reasons, reason_code, :unknown_reason),
         {:ok, logical_device_id, rest} <- take_lp(rest),
         :ok <- optional_binary(logical_device_id, @uuid_size, :bad_logical_device_id_length),
         {:ok, credential_epoch, trailing} <- take_u32(rest),
         :ok <- ensure(trailing == <<>>, :trailing_bytes),
         :ok <- validate_registration_payload(outcome, reason, logical_device_id, credential_epoch) do
      {:ok,
       %{
         request_hash: request_hash,
         outcome: outcome,
         reason: reason,
         logical_device_id: nil_if_empty(logical_device_id),
         credential_epoch: credential_epoch
       }}
    end
  end

  defp validate_registration_payload(:registered, :none, logical_device_id, 0)
       when byte_size(logical_device_id) == @uuid_size,
       do: :ok

  defp validate_registration_payload(:recovery_required, _reason, <<>>, 0), do: :ok

  defp validate_registration_payload(:blocked, reason, <<>>, 0) when reason != :none,
    do: :ok

  defp validate_registration_payload(_outcome, _reason, _logical_device_id, _credential_epoch),
    do: {:error, :noncanonical_registration_payload}

  defp parse_challenge_payload(payload) do
    with {:ok, rest} <- payload_body(payload, @challenge_payload_domain),
         {:ok, request_hash, rest} <- take_lp(rest),
         :ok <- exact_binary(request_hash, @hash_size, :bad_request_hash_length),
         {:ok, classification_code, rest} <- take_u8(rest),
         {:ok, classification} <-
           closed_enum(@challenge_classifications, classification_code, :unknown_challenge_classification),
         {:ok, reason_code, rest} <- take_u8(rest),
         {:ok, reason} <- closed_enum(@reasons, reason_code, :unknown_reason),
         {:ok, attempt_id, rest} <- take_lp(rest),
         :ok <- optional_binary(attempt_id, @uuid_size, :bad_attempt_id_length),
         {:ok, server_nonce, rest} <- take_lp(rest),
         :ok <- optional_binary(server_nonce, @server_nonce_size, :bad_server_nonce_length),
         {:ok, expires_at_unix_s, trailing} <- take_u64(rest),
         :ok <- ensure(trailing == <<>>, :trailing_bytes),
         :ok <-
           validate_challenge_payload(classification, reason, attempt_id, server_nonce, expires_at_unix_s) do
      {:ok,
       %{
         request_hash: request_hash,
         classification: classification,
         reason: reason,
         attempt_id: nil_if_empty(attempt_id),
         server_nonce: nil_if_empty(server_nonce),
         expires_at_unix_s: expires_at_unix_s
       }}
    end
  end

  defp validate_challenge_payload(:recoverable, :none, attempt_id, server_nonce, expires_at_unix_s)
       when byte_size(attempt_id) == @uuid_size and byte_size(server_nonce) == @server_nonce_size and
              expires_at_unix_s > 0,
       do: :ok

  defp validate_challenge_payload(classification, _reason, <<>>, <<>>, 0)
       when classification in [:not_enrolled, :blocked],
       do: :ok

  defp validate_challenge_payload(_classification, _reason, _attempt_id, _server_nonce, _expires_at_unix_s),
    do: {:error, :noncanonical_challenge_payload}

  defp parse_lifecycle_payload(payload) do
    with {:ok, rest} <- payload_body(payload, @lifecycle_payload_domain),
         {:ok, attempt_id, rest} <- take_lp(rest),
         :ok <- exact_binary(attempt_id, @uuid_size, :bad_attempt_id_length),
         {:ok, challenge_envelope_hash, rest} <- take_lp(rest),
         :ok <- exact_binary(challenge_envelope_hash, @hash_size, :bad_challenge_envelope_hash_length),
         {:ok, candidate_fingerprint, rest} <- take_lp(rest),
         :ok <- exact_binary(candidate_fingerprint, @hash_size, :bad_candidate_fingerprint_length),
         {:ok, lifecycle_code, rest} <- take_u8(rest),
         {:ok, lifecycle} <- closed_enum(@lifecycles, lifecycle_code, :unknown_lifecycle),
         {:ok, reason_code, rest} <- take_u8(rest),
         {:ok, reason} <- closed_enum(@reasons, reason_code, :unknown_reason),
         {:ok, logical_device_id, rest} <- take_lp(rest),
         :ok <- optional_binary(logical_device_id, @uuid_size, :bad_logical_device_id_length),
         {:ok, credential_epoch, rest} <- take_u32(rest),
         {:ok, accepted_commit_hash, trailing} <- take_lp(rest),
         :ok <- optional_binary(accepted_commit_hash, @hash_size, :bad_accepted_commit_hash_length),
         :ok <- ensure(trailing == <<>>, :trailing_bytes),
         :ok <-
           validate_lifecycle_payload(
             lifecycle,
             reason,
             logical_device_id,
             credential_epoch,
             accepted_commit_hash
           ) do
      {:ok,
       %{
         attempt_id: attempt_id,
         challenge_envelope_hash: challenge_envelope_hash,
         candidate_fingerprint: candidate_fingerprint,
         lifecycle: lifecycle,
         reason: reason,
         logical_device_id: nil_if_empty(logical_device_id),
         credential_epoch: credential_epoch,
         accepted_commit_signing_bytes_hash: nil_if_empty(accepted_commit_hash)
       }}
    end
  end

  defp validate_lifecycle_payload(:committed, :none, logical_device_id, credential_epoch, accepted_commit_hash)
       when byte_size(logical_device_id) == @uuid_size and credential_epoch > 0 and
              byte_size(accepted_commit_hash) == @hash_size,
       do: :ok

  defp validate_lifecycle_payload(lifecycle, _reason, <<>>, 0, <<>>)
       when lifecycle in [:pending, :expired],
       do: :ok

  defp validate_lifecycle_payload(:blocked, reason, <<>>, 0, <<>>) when reason != :none,
    do: :ok

  defp validate_lifecycle_payload(
         _lifecycle,
         _reason,
         _logical_device_id,
         _credential_epoch,
         _accepted_commit_hash
       ),
       do: {:error, :noncanonical_lifecycle_payload}

  defp payload_body(payload, domain) when is_binary(payload) do
    domain_size = byte_size(domain)

    case payload do
      <<actual_domain::binary-size(domain_size), version, rest::binary>> ->
        cond do
          actual_domain != domain -> {:error, :payload_domain_mismatch}
          version != @version -> {:error, :unsupported_payload_version}
          true -> {:ok, rest}
        end

      _ ->
        if byte_size(payload) >= domain_size and binary_part(payload, 0, domain_size) == domain do
          {:error, :truncated_payload}
        else
          {:error, :payload_domain_mismatch}
        end
    end
  end

  defp payload_body(_, _), do: {:error, :payload_domain_mismatch}

  defp closed_enum(values, code, error) do
    case Map.fetch(values, code) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, error}
    end
  end

  defp take_lp(<<length::unsigned-big-integer-size(16), rest::binary>>) when byte_size(rest) >= length do
    <<value::binary-size(length), trailing::binary>> = rest
    {:ok, value, trailing}
  end

  defp take_lp(_), do: {:error, :truncated}

  defp take_u8(<<value, rest::binary>>), do: {:ok, value, rest}
  defp take_u8(_), do: {:error, :truncated}

  defp take_u32(<<value::unsigned-big-integer-size(32), rest::binary>>), do: {:ok, value, rest}
  defp take_u32(_), do: {:error, :truncated}

  defp take_u64(<<value::unsigned-big-integer-size(64), rest::binary>>), do: {:ok, value, rest}
  defp take_u64(_), do: {:error, :truncated}

  defp nil_if_empty(<<>>), do: nil
  defp nil_if_empty(value), do: value

  defp ensure(true, _error), do: :ok
  defp ensure(false, error), do: {:error, error}
end
