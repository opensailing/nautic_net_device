# Secure Transport Reflash Runbook

Operator procedure for building, installing, and verifying one RacingOrg tracker
image with Secure Transport v2. Stateless identity recovery, desired-state
hydration, durable delivery, and migration policy are covered in
[STATELESS_RECOVERY_RUNBOOK.md](STATELESS_RECOVERY_RUNBOOK.md).

The backend must already support the image before it is installed. Do not use a
tracker reflash as the first rollout step.

## 1. Security invariants

- Tracker telemetry is AEAD-only. With a live authenticated session, telemetry
  is sealed; without one, telemetry is dropped. The tracker never sends a
  plaintext fallback.
- Backend UDP ingest also rejects non-AEAD telemetry unconditionally. There is
  no per-device plaintext cutover column and no fleet-wide plaintext kill
  switch to operate.
- The tracker pins the backend Ed25519 public key. The corresponding private
  material remains backend-only and must never be copied into firmware notes,
  shell history, tickets, or this repository.
- Registration and development serial recovery are proof-of-possession flows.
  The Raspberry Pi serial is not a credential and must not be printed or
  recorded in operator evidence.
- A new image must preserve `/data` unless replacement of the storage
  incarnation is intentional. The device identity, bootstrap authority,
  desired-state storage epoch, outbox, command ledger, and recovery journals
  are durable state.

## 2. Backend-first preflight

Before building or installing firmware, the backend operator must confirm:

1. Schema and application support for the firmware version are deployed.
2. Secure transport is healthy and the pinned public key for the image is the
   currently intended trust anchor.
3. The device is visible in the admin device detail page and its current
   credential epoch, desired-state status, and recovery gate are understood.
4. If legacy serial recovery will be needed, the one-time binding and explicit
   development enrollment are completed while both recovery kill switches
   remain under operator control.
5. Rollback remains available. For a local reflash, retain the prior known-good
   image or media. For OTA, retain the prior Nerves partition/image and use the
   safe trial procedure in the stateless recovery runbook.

Do not install firmware first and hope that a later backend deployment will
make it operable.

## 3. Build-host configuration

Use `.envrc-example` as the configuration template, but never copy a PSK,
token-shaped value, live domain, serial, or private key into operational notes.
Do not inspect or quote `.envrc`.

Safe local placeholders from `.envrc-example` are:

```sh
export MIX_TARGET='racing_org_rpi3'
export PRODUCT='logger'
export API_ENDPOINT='http://localhost:4000'
export UDP_ENDPOINT='localhost:4001'
export NERVES_DL_DIR='/Volumes/Nerves/dl'
export NERVES_ARTIFACTS_DIR='/Volumes/Nerves/artifacts'
```

For a non-local build, set the endpoints through the normal secret-managed
operator environment without recording their values here.

Set `SECURE_TRANSPORT_SERVER_PUBLIC_KEY` in the build environment to the
approved 32-byte Ed25519 public key representation. This value is a public
trust anchor, not private signing material, but it should still be handled as
controlled configuration because changing it changes which backend the image
trusts. There is no separate secure-transport enable flag: a real device target
plus this configured pin starts the secure-transport children.

NervesHub configuration is optional. If it is used, provide its host and
credentials through the existing operator secret path; never paste them into a
runbook or command transcript.

## 4. Build and install

Build in the configured shell:

```sh
mix firmware
```

For an SD-card installation, use the repository's existing alias:

```sh
mix firmware.burn
```

For the repository's direct network upload path:

```sh
mix firmware && mix upload nerves.local
```

Do not invent an OTA release or signing command. The repository contains
NervesHubLink configuration and pinned fwup public keys, but release signing,
upload, cohort assignment, and deployment remain the operator's external
release workflow.

## 5. First-boot expectations

On boot, the tracker reconciles durable bootstrap state with the current SoC
identity and the active or staged signing key.

- A fresh, unbound tracker may register through the signed v2 registration
  flow.
- A tracker with verified authority reuses it and refuses credential-epoch
  downgrade.
- A missing or mismatched active signer stages a candidate; it does not
  overwrite the previous authority before a signed recovery commit is durably
  persisted.
- A lost recovery commit response is reconciled through signed status replay.
- A legacy marker that cannot yet be enrolled leaves the tracker in a closed
  limbo state rather than silently replacing identity.
- Hardware-identity mismatch, invalid signed authority, corrupt durable state,
  or unavailable identity keeps the tracker blocked or retrying; it must not be
  bypassed by deleting individual files.

## 6. Verification

Use sanitized runtime surfaces only. Do not print complete signed receipts,
public-key fingerprints, serials, session keys, nonces, payloads, or filesystem
contents.

On the tracker console, the following implemented read-only calls are safe when
their returned maps are kept in the operator session rather than copied
verbatim into a ticket:

```elixir
RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner.current_state()
RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner.credential_epoch()
RacingOrg.Tracker.Pro.SecureTransport.SessionHolder.live?()
RacingOrg.Tracker.Pro.DesiredState.Manager.status()
RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner.status(
  RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner
)
```

Expected evidence:

1. Bootstrap phase progresses to `registered` or `committed`, then to
   `authenticated`, `hydrating`, and `effective` as the channel and desired
   state become ready.
2. The verified credential epoch agrees with the backend device detail page.
3. `SessionHolder.live?/0` is `true` while the secure channel is established.
4. Desired State reports an active generation and an open gate only after the
   exact generation is effective.
5. Outbox status is accepting, storage-epoch-bound, not quarantined, and below
   its entry, byte, and disk limits.
6. Backend diagnostics show AEAD traffic and current signed device readiness;
   no plaintext coexistence check is necessary or possible.

A gap in telemetry while the session is down is expected secure behavior. It is
not permission to enable plaintext or clear durable state.

## 7. Abort and rollback

Abort the installation or trial when any of the following occurs:

- the backend cannot authenticate the tracker at the expected credential epoch;
- bootstrap enters a durable mismatch or invalid-receipt limbo state;
- desired state is rejected or never becomes effective;
- the outbox is quarantined or reaches critical pressure;
- required control or telemetry receipt round trips do not complete; or
- the new firmware cannot meet its validation deadline.

For a local reflash, restore the prior known-good image while preserving `/data`
unless the incident has been explicitly classified as storage loss. If storage
must be replaced, follow the storage-epoch procedure in
[STATELESS_RECOVERY_RUNBOOK.md](STATELESS_RECOVERY_RUNBOOK.md); do not copy
selected durable files into a new storage incarnation.

For OTA, retain the prior Nerves partition/image and follow the integration
status in [STATELESS_RECOVERY_RUNBOOK.md](STATELESS_RECOVERY_RUNBOOK.md). The
health-trial foundations exist, but the complete production coordinator is not
yet integrated; do not manually mark firmware valid merely because it booted or
connected once, and do not classify the OTA as safely validated without that
integration.

## 8. Completion record

Record only:

- firmware version and Git commit;
- build target and product;
- installation method;
- backend application/schema version;
- sanitized bootstrap phase and credential epoch;
- desired-state generation/status and closed rejection diagnostics, if any;
- sanitized outbox counters and limits; and
- validation or rollback outcome.

Never include a serial, private key, PSK, token, live endpoint, control
plaintext, full receipt, nonce, session identifier, payload, or complete
fingerprint in the completion record.
