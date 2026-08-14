# Desired State v1 and `control_v1` byte contract

Status: frozen pure contract foundation for task #67.

This document specifies the language-neutral bytes shared by the racing.org backend and Tracker Pro. It covers capability negotiation, canonical values, complete desired-state manifests, desired-state payloads, and the desired-state-only authenticated control envelope. It does not specify database persistence, a runtime desired-state manager, an operational gate, durable outbox/checkpoint behavior, command fences, or OTA behavior.

All integers are unsigned big-endian unless a field explicitly says signed. Fixed-size byte fields do not have a length prefix. `lp16(value)` means `u16(byte_size(value)) || value`.

## 1. Versions, purpose, algorithms, and limits

```text
desired-state contract version     0x01
desired_state_version              0x0001
section_set_version                0x0001
control_v1 HKDF purpose            0x81
control AEAD id                    0x01 (ChaCha20-Poly1305 IETF)
control frame magic                "ROC1"
section chunk size                 61,440 bytes
maximum control plaintext          65,536 bytes
maximum manifest                   16,384 bytes
maximum canonical section          16,777,216 bytes
maximum aggregate generation       33,554,432 bytes
maximum delivered secret           1,024 bytes
maximum advertised capabilities    64
maximum ranges per resume section  512
maximum ranges in one resume       1,024
```

Purpose `0x81` is independent from the Secure Transport data-plane keys and from purpose `0x80` HTTPS bulk keys. Its send counters and replay windows are also independent.

## 2. Closed domains and registries

### Hash and negotiation domains

```text
RacingOrg-ControlOffer-v1
RacingOrg-DesiredStateManifest-v1
RacingOrg-DesiredStateSection-v1
RacingOrg-DesiredStateSecretDigest-v1
```

### Payload types

| Code | Direction | Name | Domain |
|---:|---|---|---|
| `0x01` | server to device | `control_accept` | `RacingOrg-ControlAccept-v1` |
| `0x02` | device to server | `readiness` | `RacingOrg-ControlReadiness-v1` |
| `0x03` | server to device | `manifest_delivery` | `RacingOrg-DesiredStateManifestDelivery-v1` |
| `0x04` | server to device | `section_chunk` | `RacingOrg-DesiredStateSectionChunk-v1` |
| `0x05` | device to server | `resume` | `RacingOrg-DesiredStateResume-v1` |
| `0x06` | server to device | `secret_delivery` | `RacingOrg-DesiredStateSecret-v1` |
| `0x07` | device to server | `ack` | `RacingOrg-DesiredStateAck-v1` |

Unregistered types are rejected. The following ranges are reserved without implementing their behavior here:

```text
0x08..0x1f desired-state extensions
0x20..0x2f commands (task #69)
0x30..0x4f durable receipts/checkpoints (task #68)
0x50..0x5f health/OTA (task #70)
0x60..0x7f future standardized messages
0x80..0xff unassigned/private
```

## 3. Capability negotiation

Phoenix connection parameters are:

```text
control_versions
desired_state_versions
```

Omitting both selects explicit legacy behavior. Supplying exactly one is an incomplete offer and rejects. Unrelated connection parameters, including the existing fingerprint parameter, are ignored by this parser.

Each value is a comma-separated list of one to eight positive decimal u16 values. Values must be in ascending order, contain no duplicates, and use their minimal decimal spelling.

Canonical offer bytes place control versions first:

```text
"RacingOrg-ControlOffer-v1" ||
u8(0x01) ||
control_count:u8 ||
control_versions[control_count]:u16 ||
desired_count:u8 ||
desired_state_versions[desired_count]:u16
```

```text
offer_hash = SHA-256(offer_bytes)
```

Version selection chooses the highest mutually supported control and desired-state versions. v1 currently supports only version `1` for each list. Negotiation chooses byte compatibility only and confers no device, owner, section, or command authority.

## 4. Canonical value encoding

Desired-state section content is not JSON, Erlang external terms, or Base64. The canonical grammar is:

| Tag | Value | Encoding after tag |
|---:|---|---|
| `0x00` | null | none |
| `0x01` | false | none |
| `0x02` | true | none |
| `0x03` | unsigned integer | `u64` |
| `0x04` | negative integer | signed two's-complement `i64` |
| `0x05` | finite float | IEEE-754 binary64 bits |
| `0x06` | bytes | `u32(length) || bytes` |
| `0x07` | text | `u32(length) || NFC UTF-8` |
| `0x08` | list | `u32(count) || encoded values` |
| `0x09` | map | `u32(count) || encoded entries` |

A map entry is:

```text
key_length:u16 || normalized_key_utf8 || canonical_value
```

Rules:

- Plain binaries are text. Arbitrary bytes require the explicit bytes type.
- Atom values and atom map keys become their textual atom names.
- Text and map keys are normalized to Unicode NFC before encoding.
- Map keys are sorted by normalized UTF-8 bytes.
- Duplicate normalized keys, including atom/string or Unicode-normalization collisions, reject.
- Positive integers use only tag `0x03`; tag `0x04` must decode to a negative value.
- Integers and floats remain distinct types.
- NaN and infinities reject.
- Negative floating-point zero encodes as positive zero; a presented negative-zero encoding rejects.
- Unknown tags, improper lists, noncanonical ordering, truncation, and trailing bytes reject.
- Maximum collection nesting depth is 16.
- Maximum map-key length is 128 bytes.
- Maximum list/map count is 65,535.
- Maximum complete encoded value is 16 MiB.

Non-tombstone section content must be one canonical top-level map.

## 5. Section set and tombstones

`section_set_version = 1` contains exactly these nine sections, in this order:

| Code | Section | Schema | Tombstone allowed |
|---:|---|---:|---|
| `0x01` | `assignment` | `1` | yes |
| `0x02` | `calibration` | `1` | no |
| `0x03` | `clock_source` | `1` | no |
| `0x04` | `computed_values` | `1` | no |
| `0x05` | `polar` | `1` | yes |
| `0x06` | `tracking` | `1` | no |
| `0x07` | `upstream` | `1` | no |
| `0x08` | `wifi` | `1` | yes |
| `0x09` | `wind_shift` | `1` | no |

The assignment section is the complete assignment projection, including race policy/start-sequence, route, and active-waypoint state. Those values share one existing authority and are not independent v1 sections. Empty computed values are present content, not a tombstone.

Every manifest contains every section exactly once. Missing, duplicate, unknown, or out-of-order sections reject. A tombstone has zero content, zero secret descriptors, and a real domain-separated hash.

### Secret descriptor

```text
secret_kind:u8 ||
digest_key_id:u32 ||
secret_ref[16] ||
secret_digest[32]
```

v1 registers only secret kind `0x01`. A secret reference is nonzero and exactly 16 bytes. Only the Wi-Fi section may have a secret descriptor, and v1 allows at most one.

### Section hash

```text
section_preimage =
  "RacingOrg-DesiredStateSection-v1" ||
  u8(0x01) ||
  lp16(section_name) ||
  section_schema_version:u16 ||
  tombstone:u8 ||
  content_length:u64 ||
  secret_count:u8 ||
  secret_descriptors ||
  canonical_content

section_hash = SHA-256(section_preimage)
```

`tombstone` is exactly `0` or `1`. Section hashes do not include generation identity, allowing identical content to be reused by multiple immutable generations.

### Manifest section descriptor

```text
section_code:u8 ||
section_schema_version:u16 ||
tombstone:u8 ||
content_length:u64 ||
secret_count:u8 ||
secret_descriptors ||
section_hash[32]
```

## 6. Wi-Fi secret boundary

Ensure no real Wi-Fi secret material enters persisted/loggable/KAT bytes.

Canonical Wi-Fi content accepts only these top-level public fields:

```text
enabled  boolean
ssid     null or NFC UTF-8 text, at most 32 bytes
version  u64
```

Unknown Wi-Fi fields reject. The field names `psk`, `password`, `passphrase`, and `wifi_psk` reject case-insensitively as plaintext secret material. The same validation runs both when building a section and when verifying received canonical section bytes.

The server-keyed digest preimage is:

```text
"RacingOrg-DesiredStateSecretDigest-v1" ||
u8(0x01) ||
device_id[16] ||
lp16("wifi") ||
section_schema_version:u16 ||
secret_kind:u8 ||
digest_key_id:u32 ||
secret_ref[16] ||
secret_length:u16 ||
secret_bytes
```

```text
secret_digest = HMAC-SHA256(digest_key[digest_key_id], preimage)
```

The HMAC key is at least 32 bytes and is separate from Cloak keys, recovery-identifier keys, Secure Transport PRKs, and signing keys. Persisted and loggable generation material contains only public Wi-Fi fields, the key ID, reference, and keyed digest. Plaintext crosses only the authenticated `secret_delivery` boundary. The shared KAT uses explicitly synthetic noncredential bytes rather than a real credential.

## 7. Complete manifest

Required capabilities are exact `(id, version)` pairs, sorted by ID:

```text
0x0001 atomic_generation          version 1
0x0002 secret_injection           version 1
0x0003 bounded_wifi_trial         version 1
0x0101 assignment                 version 1
0x0102 calibration                version 1
0x0103 clock_source               version 1
0x0104 computed_values            version 1
0x0105 polar                      version 1
0x0106 tracking                   version 1
0x0107 upstream                   version 1
0x0108 wifi                       version 1
0x0109 wind_shift                 version 1
```

The manifest body is:

```text
"RacingOrg-DesiredStateManifest-v1" ||
u8(0x01) ||
device_id[16] ||
credential_epoch:u32 ||
generation:u64 ||
desired_state_version:u16 ||
section_set_version:u16 ||
minimum_firmware_present:u8 ||
[lp16(canonical_semver)] ||
required_capability_count:u16 ||
required_capabilities ||
section_count:u16 ||
section_descriptors
```

Each capability is `capability_id:u16 || exact_version:u16`.

The self-contained complete hash is:

```text
complete_hash = SHA-256(manifest_body)
manifest_bytes = manifest_body || u16(32) || complete_hash[32]
manifest_hash = complete_hash
```

The outer `manifest_delivery` hash must equal the embedded complete hash. Decoding reconstructs the canonical manifest and requires byte equality. Generation zero is invalid. Minimum firmware is optional canonical SemVer 2.0 text, at most 80 bytes, with build metadata forbidden.

## 8. Authenticated payloads

Every plaintext begins with:

```text
payload_domain || u8(0x01) || message_type:u8 || body
```

The decoder is expected-type-specific and rejects domain, version, or type substitution.

Shared incarnation identity is:

```text
device_id[16] ||
credential_epoch:u32 ||
boot_id[16] ||
storage_epoch[16]
```

`boot_id` and `storage_epoch` must be nonzero.

### `control_accept` (`0x01`)

```text
device_id[16] ||
credential_epoch:u32 ||
selected_control_version:u16 ||
selected_desired_version:u16 ||
offer_hash[32]
```

### `readiness` (`0x02`)

```text
identity ||
selected_control_version:u16 ||
selected_desired_version:u16 ||
offer_hash[32] ||
lp16(firmware_version) ||
lp16(firmware_git_sha) ||
capability_count:u16 ||
capabilities ||
effective_present:u8 ||
[
  effective_credential_epoch:u32 ||
  effective_generation:u64 ||
  effective_manifest_hash[32]
]
```

The presence byte is exactly `0` or `1`. Firmware version is canonical SemVer without build metadata and at most 80 bytes. Git SHA is 7–40 lowercase hexadecimal bytes.

### `manifest_delivery` (`0x03`)

```text
identity ||
generation:u64 ||
manifest_hash[32] ||
manifest_length:u32 ||
manifest_bytes
```

The outer device, credential epoch, generation, and hash must equal the embedded manifest.

### `section_chunk` (`0x04`)

```text
identity ||
generation:u64 ||
manifest_hash[32] ||
section_code:u8 ||
section_schema_version:u16 ||
section_hash[32] ||
total_content_length:u64 ||
chunk_index:u32 ||
chunk_count:u32 ||
chunk_offset:u64 ||
chunk_length:u32 ||
chunk_bytes
```

```text
chunk_count  = ceil(total_content_length / 61,440)
chunk_offset = chunk_index * 61,440
```

Every non-final chunk is exactly 61,440 bytes. The final chunk is the exact remainder.

### `resume` (`0x05`)

```text
identity ||
generation:u64 ||
manifest_hash[32] ||
incomplete_section_count:u16 ||
incomplete_sections
```

Each incomplete section is:

```text
section_code:u8 ||
section_schema_version:u16 ||
section_hash[32] ||
total_content_length:u64 ||
missing_range_count:u16 ||
missing_ranges
```

Each range is `first_chunk_index:u32 || chunk_count:u32`. Sections and ranges are ordered. Ranges must be nonempty, nonoverlapping, nonadjacent, in bounds, and minimally coalesced.

### `secret_delivery` (`0x06`)

```text
identity ||
generation:u64 ||
manifest_hash[32] ||
section_code:u8 ||
section_schema_version:u16 ||
section_hash[32] ||
secret_kind:u8 ||
digest_key_id:u32 ||
secret_ref[16] ||
secret_digest[32] ||
secret_length:u16 ||
secret_bytes
```

v1 secret delivery is allowed only for the Wi-Fi section and is not chunked.

### `ack` (`0x07`)

Common prefix:

```text
identity || generation:u64 || manifest_hash[32] || status:u8
```

Statuses:

```text
0x01 staged
0x02 effective
0x03 rejected
```

A staged ACK appends:

```text
section_count:u16 || section_summaries
```

Each summary is:

```text
section_code:u8 || section_schema_version:u16 || tombstone:u8 || section_hash[32]
```

It contains the complete ordered nine-section set.

An effective ACK has no additional body.

A rejected ACK appends:

```text
phase:u8 ||
error_code:u16 ||
retryable:u8 ||
section_present:u8 ||
[section_code:u8 || section_schema_version:u16 || section_hash[32]]
```

Status, phase, and error codes are closed registries. Rejection details contain only stable codes and optional section identity, never arbitrary text or secret bytes.

Rejection phases are:

```text
0x01 manifest
0x02 transfer
0x03 staging
0x04 apply
0x05 wifi_trial
0x06 activation
```

Rejection error codes are:

```text
0x0001 malformed_manifest
0x0002 incompatible_desired_state_version
0x0003 incompatible_section_set
0x0004 incompatible_firmware
0x0005 incompatible_capability
0x0006 duplicate_section
0x0007 missing_section
0x0008 unknown_section
0x0009 unsupported_section_schema
0x000a manifest_hash_mismatch
0x000b section_hash_mismatch
0x000c stale_generation
0x000d generation_hash_conflict
0x000e boot_id_mismatch
0x000f storage_epoch_mismatch
0x0010 chunk_bounds
0x0011 chunk_conflict
0x0012 transfer_incomplete
0x0013 missing_secret
0x0014 unexpected_secret
0x0015 secret_reference_mismatch
0x0016 section_validation_failed
0x0017 section_apply_failed
0x0018 storage_failed
0x0019 wifi_trial_failed
0x001a activation_failed
0x001b internal_failure
```

## 9. `control_v1` AEAD envelope

Directional keys are derived from the established Secure Transport session with the existing `derive_purpose_key` construction:

```text
purpose   = 0x81
direction = 0x01 device-to-server or 0x02 server-to-device
```

The complete header is authenticated as AEAD additional data:

```text
magic                    "ROC1"       4 bytes
control_version          0x01         1 byte
aead_id                  0x01         1 byte
direction                              1 byte
message_type                           1 byte
session_id                            16 bytes
credential_epoch                      4 bytes, u32
counter                               8 bytes, u64
ciphertext_length                     4 bytes, u32
------------------------------------------------
header                               40 bytes
```

```text
AAD   = header
nonce = credential_epoch:u32 || counter:u64
frame = header || ciphertext || tag[16]
```

Rules:

- A fresh endpoint state starts its send counter at zero and its receive replay window empty.
- Direction and message type must match the closed registry before sealing or opening.
- Session ID and credential epoch must match the established session.
- The receive side uses the existing 64-counter sliding replay window; duplicates and counters that have fallen out of the window reject.
- Counter reuse, malformed lengths, wrong direction, wrong session, and wrong epoch reject.
- Forged frames do not commit a replay counter.
- After successful AEAD authentication, the replay counter commits before the authenticated payload header is checked. Therefore a payload with an authenticated wrong domain, version, or type cannot be retried with the same counter.
- Rekey is required at the Secure Transport threshold `2^48`; counters never wrap.

The Phoenix textual carrier is exactly:

```json
{"frame":"<strict padded standard Base64>"}
```

No additional keys are accepted. URL-safe, unpadded, whitespace-containing, or otherwise noncanonical Base64 rejects.

## 10. Shared known-answer vector

Both repositories contain byte-identical files at:

```text
priv/secure_transport/desired_state_v1_kat.json
```

The vector freezes the canonical offer and hash, canonical scalar/map/list bytes, all nine sections, two tombstones, the complete manifest, all seven payload types and all three ACK forms, purpose-`0x81` directional keys, complete frames, and strict padded Base64 carriers.

The vector uses only deterministic synthetic identifiers, keys, and explicitly synthetic noncredential bytes. Its SHA-256 is:

```text
3973265021ae78274938883ee9169ecdfd2cb291a4e02f4ec24856f8fa19055a
```

## 11. Deferred behavior

This contract intentionally does not implement or authorize:

- database migrations or desired-generation persistence;
- a runtime desired-state manager or atomic activation process;
- an operational gate;
- durable outbox, receipt, or checkpoint state;
- commands or command-generation fences;
- OTA validation or health gating;
- deployment or firmware installation behavior.

Those layers may consume these bytes, but they must not change this frozen v1 encoding.
