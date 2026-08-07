# Tracker Registration and Serial Recovery V2

This document defines the tracker-side pure contract foundation for registration and
serial-based credential recovery. It covers canonical bytes, local serial normalization,
and verification of signed server receipts. HTTP orchestration, persistence, serial
lookup, and lifecycle mutation are outside this foundation.

Legacy `POST /api/devices/register` and the literal
`RacingOrg-TrackerRegister-v1` contract remain unchanged. V2 application layers use:

- `POST /api/devices/register/v2`
- `POST /api/devices/recovery/challenges`
- `POST /api/devices/recovery/:attempt_id/commit`
- candidate-PoP `POST /api/devices/recovery/:attempt_id/status`

## Canonical encoding

Domains are literal, case-sensitive ASCII and are not length-prefixed. Each V2 message
then carries version byte `0x02`.

- `lp(b) = u16-BE(byte_size(b)) || b`
- Integers are unsigned big-endian (`u32` or `u64`).
- UUIDs are raw 16-byte values, never UUID text.
- Ed25519 public keys and signatures are raw 32-byte and 64-byte values.
- SHA-256 values and nonces are raw 32-byte values.
- Decoders reject bad domains or versions, oversized or wrong-length fields, truncation,
  trailing bytes, unknown closed codes, and noncanonical semantic combinations.

## Raspberry Pi serial identity

The provider is exactly `raspberry_pi_soc_serial_v1`. A wire serial is exactly 16
lowercase hexadecimal ASCII bytes and cannot be `0000000000000000`.

Local normalization strips only trailing NUL and ASCII whitespace bytes (`09`, `0a`,
`0b`, `0c`, `0d`, `20`), accepts an optional lowercase `0x`, accepts 1..16 mixed-case
hexadecimal digits, lowercases, and left-pads to 16 bytes. Leading or embedded
whitespace, uppercase `0X`, signs, malformed or overlong hex, and zero are rejected.
Every present local source must normalize successfully and all present sources must
agree; malformed or conflicting sources fail closed.

## Candidate assertions

Candidate Ed25519 signatures are detached raw 64-byte values over these exact signing
bytes:

```text
registration_signed =
  "RacingOrg-TrackerRegister-v2" || 0x02 ||
  lp(provider) || lp(serial) || lp(candidate_pub32) || lp(client_nonce32)

challenge_signed =
  "RacingOrg-TrackerRecoveryChallenge-v2" || 0x02 ||
  lp(provider) || lp(serial) || lp(candidate_pub32) || lp(client_nonce32)

commit_signed =
  "RacingOrg-TrackerRecoveryCommit-v2" || 0x02 ||
  lp(attempt_uuid_raw16) || lp(candidate_pub32) ||
  lp(SHA256(exact_full_signed_challenge_envelope))

status_signed =
  "RacingOrg-TrackerRecoveryStatus-v2" || 0x02 ||
  lp(attempt_uuid_raw16) || lp(candidate_pub32) ||
  lp(SHA256(exact_full_signed_challenge_envelope)) || lp(fresh_client_nonce32)
```

The server verifies candidate PoP before any serial lookup. The accepted commit hash in
a committed lifecycle receipt is `SHA256(commit_signed)`.

## Signed server receipts

Receipt types are `registration=1`, `challenge=2`, and `lifecycle=3`.

```text
receipt_signing_bytes =
  "RacingOrg-ServerReceipt-v2" || 0x02 || u8(receipt_type) || lp(payload)

receipt_envelope = receipt_signing_bytes || lp(server_sig64)
```

The tracker verifies `server_sig64` with the injected or firmware-pinned Ed25519 server
public key before interpreting the closed receipt type or enforcing type-to-payload-domain
agreement. Verification retains the exact original envelope bytes and their SHA-256 hash.

Closed shared reason codes are `none=0`, `recovery_disabled=1`,
`recovery_ineligible=2`, `active_session_conflict=3`, `identity_conflict=4`, and
`attempt_limit=5`.

### Registration payload

```text
"RacingOrg-ServerRegistrationReceipt-v2" || 0x02 ||
lp(request_hash32) || u8(outcome) || u8(reason) ||
lp(logical_device_uuid_raw16_or_empty) || u32(credential_epoch)
```

`request_hash32 = SHA256(registration_signed)`. Outcomes are `registered=1`,
`recovery_required=2`, and `blocked=3`.

- `registered`: reason `none`, a raw16 logical device UUID, and epoch exactly `0`.
- `recovery_required`: empty device UUID and epoch `0`; reason is closed.
- `blocked`: empty device UUID, epoch `0`, and a nonzero closed reason.

### Recovery challenge payload

```text
"RacingOrg-ServerRecoveryChallengeReceipt-v2" || 0x02 ||
lp(request_hash32) || u8(classification) || u8(reason) ||
lp(attempt_uuid_raw16_or_empty) || lp(server_nonce32_or_empty) ||
u64(expires_at_unix_s)
```

`request_hash32 = SHA256(challenge_signed)`. Classifications are `recoverable=1`,
`not_enrolled=2`, and `blocked=3`.

- `recoverable`: reason `none`, raw16 attempt UUID, nonce32, and positive server-clock
  expiry.
- `not_enrolled` or `blocked`: empty attempt and nonce fields and expiry exactly `0`;
  reason is closed.

The tracker never uses its RTC to authorize challenge expiry; the server authorizes it.

### Recovery lifecycle payload

```text
"RacingOrg-ServerRecoveryLifecycleReceipt-v2" || 0x02 ||
lp(attempt_uuid_raw16) || lp(challenge_envelope_hash32) ||
lp(candidate_fingerprint32) || u8(lifecycle) || u8(reason) ||
lp(logical_device_uuid_raw16_or_empty) || u32(credential_epoch) ||
lp(accepted_commit_signing_bytes_hash32_or_empty)
```

`candidate_fingerprint32 = SHA256(candidate_pub32)`. Lifecycles are `pending=1`,
`committed=2`, `expired=3`, and `blocked=4`.

- `committed`: reason `none`, preserved raw16 logical device UUID, epoch
  `1..0xffffffff`, and the accepted commit signing-bytes hash.
- `pending` or `expired`: empty device UUID, epoch `0`, and empty commit hash.
- `blocked`: the same empty fields and epoch `0`, plus a nonzero closed reason.

The exact signed committed envelope is persisted and returned byte-identically for the
commit response, idempotent replay, and candidate-authorized status.

## JSON boundary and vectors

Binary JSON values use canonical padded standard base64; URL-safe, unpadded, overpadded,
whitespace-bearing, malformed, or wrong-size values are rejected. Objects use exact
string-key allowlists. A proof-valid semantic response is HTTP 200 with exactly
`{"receipt":"<canonical padded standard base64 envelope>"}`.

Malformed shape, version, base64, size, or candidate-PoP failures are generic and must
perform no serial lookup. Known serial registration never creates a duplicate; fresh
registration starts at epoch zero; eligible offline development recovery is automatic.

Deterministic cross-implementation known-answer vectors are in
`priv/secure_transport/registration_recovery_v2_kat.json`.
