# Stateless Tracker Recovery Runbook

Operator procedure for recovering a RacingOrg tracker without treating local
storage, a Raspberry Pi serial, or an old session as permanent authority. The
backend is authoritative for logical device identity and credential epoch; the
tracker preserves exact durable delivery and storage-incarnation lineage.

This runbook describes committed behavior and labels internal seams that do not
yet have an integrated operator workflow. The protocol contracts remain in
[REGISTRATION_RECOVERY_V2.md](REGISTRATION_RECOVERY_V2.md) and
[DESIRED_STATE_CONTROL_V1.md](DESIRED_STATE_CONTROL_V1.md). Reflash steps are in
[SECURE_TRANSPORT_REFLASH.md](SECURE_TRANSPORT_REFLASH.md).

## 1. Scope and non-negotiable rules

Use this runbook for:

- onboarding or migrating a development tracker with a legacy serial binding;
- recovering a lost or replaced device signing key;
- diagnosing recovery conflicts;
- restoring desired state and checkpoints after credential or storage changes;
- managing durable outbox pressure without silent data loss; and
- conducting a safe OTA trial and rollback.

Never:

- deploy tracker support before backend support;
- inspect or quote `.envrc`;
- record a serial, private key, PSK, token, live domain, control plaintext, full
  signed receipt, nonce, session identifier, payload, or complete fingerprint;
- use a serial as authentication or a general production recovery mechanism;
- delete individual bootstrap, storage-epoch, outbox, ledger, checkpoint, or
  hydration files to force progress; or
- treat successful transport send as delivery acknowledgement.

## 2. Backend-first rollout

The safe order is:

1. Deploy additive backend schema and application support.
2. Keep both recovery gates closed and confirm migrations, admin diagnostics,
   secure transport, desired-state persistence, durable receipt ingestion, and
   rollback readiness.
3. Bind only approved legacy development devices.
4. Explicitly enroll only the development recovery cohort.
5. Open runtime recovery for the smallest intended window, optionally with a
   sunset.
6. Reflash or OTA the tracker after the backend is ready.
7. Verify credential lineage, effective desired state, admitted storage epoch,
   receipt progress, and checkpoint hydration.
8. Close runtime recovery immediately after the cohort is complete.
9. Remove serial recovery from production policy after migration.

Tracker firmware is AEAD-only and the backend unconditionally rejects
plaintext UDP telemetry. There is no staged plaintext coexistence rollout.

## 3. Identity and lineage model

### Credential epoch

The backend owns the logical device's `credential_epoch`. Registration starts
or confirms authority; a committed recovery revokes all prior keys and advances
the epoch exactly once. The tracker persists the signed authority and adopts
signed handshake epochs only monotonically.

After recovery:

- old WSS and UDP sessions are evicted or rejected;
- old signed HTTPS requests are fenced;
- the replacement key is valid only at the new epoch; and
- durable writes must not continue under the prior credential leaf.

A lower observed epoch is a downgrade, not a retry condition.

### Storage epoch

The tracker creates a nonzero 16-byte `storage_epoch` once for an empty desired
state storage root and reuses it across ordinary reboots. A transient `boot_id`
changes per BEAM boot; it does not define durable delivery identity.

The backend admits storage epochs append-only under the then-current credential
epoch. Historical admitted credential/storage pairs remain authoritative for
retained durable deliveries after credential recovery. A new storage epoch may
be admitted only at the device's current credential epoch.

If the storage-epoch file is missing while other durable artifacts exist, the
tracker fails closed. Do not generate a replacement epoch beside old artifacts.
Treat the condition as an incident and decide whether the original storage can
be recovered or a genuinely empty replacement incarnation must be created.

### Durable namespaces

Ledger and outbox leaves are bound to the full
`{device_id, credential_epoch, storage_epoch}` identity. Reopening a leaf under
a different device, credential epoch, or storage epoch fails closed and leaves
the previous data intact.

## 4. Legacy serial binding and development enrollment

Legacy serial binding is an implemented admin workflow in the backend device
detail page.

1. Select the intended logical device in the admin UI.
2. Use the one-time legacy hardware identity binding action.
3. Enter the serial only into that form. The backend normalizes it and
   immediately derives a server-keyed HMAC. Raw serial is not persisted.
4. Confirm that only a four-character redacted suffix and sanitized audit event
   are shown afterward.
5. Separately set recovery policy to `development_serial`.

Binding and enabling are intentionally separate. Operator binding enrolls the
identity in the `development_recovery` cohort but leaves recovery policy
`disabled` until the explicit policy change.

A device is eligible only when the active identity has both:

- recovery cohort `development_recovery`; and
- recovery policy `development_serial`.

It must also pass device status, active-session, recent-activity cooldown,
attempt-limit, rate-limit, global gate, and sunset checks. Missing or malformed
state fails closed.

## 5. Recovery kill switch

Recovery requires two independent backend gates:

- build/release permission: `DEVICE_RECOVERY_RELEASE_PERMITTED`; and
- runtime enablement: `DEVICE_RECOVERY_ENABLED`.

Both default closed. Runtime recovery also requires
`DEVICE_RECOVERY_IDENTIFIER_KEY`, supplied through backend secret management as
a canonical Base64 key of at least 32 decoded bytes. Never print, generate, or
record the value in this runbook.

`DEVICE_RECOVERY_SUNSET_AT` can close the runtime gate at a fixed time. Other
implemented controls include cooldown, challenge TTL, per-identity attempt
limits, attempt windows, and route-specific IP rate limits.

Operational sequence:

1. Verify the development identity and policy in the admin UI.
2. Verify no live session or recent activity remains inside the configured
   cooldown.
3. Open runtime recovery for the approved window only.
4. Observe the sanitized attempt and audit history.
5. Close runtime recovery as soon as the intended devices complete.

Changing runtime enablement does not erase attempts or audit history. It stops
new policy-authorized recovery work.

## 6. Automatic tracker recovery and signed diagnostics

The tracker recovery state machine stages one reusable candidate key when the
active signer is missing or does not match verified authority. It proves
candidate possession before serial lookup, verifies every signed server
receipt, persists the exact committed authority before key promotion, and uses
candidate-authorized status replay when a commit response is uncertain.

Relevant durable phases include:

- `uninitialized`;
- `recovery_candidate`;
- `challenged`;
- `committed`;
- `registered`;
- `authenticated`;
- `hydrating`;
- `effective`;
- `blocked`; and
- `limbo`.

### Attaching a serial console

Attach with a 3.3 V USB-TTL adapter on the Raspberry Pi UART header (GND,
TXD→RX, RXD→TX; never connect 5 V), then:

```shell
picocom -b 115200 /dev/tty.usbserial-*   # macOS; on Linux: /dev/ttyUSB0
```

Press Enter for the IEx prompt. Detach with `C-a C-x`. The serial console is a
local trust boundary: anyone holding it holds the device, so treat transcripts
as sensitive and never paste raw structs from it into tickets.

### Sanitized diagnostics calls

Start with the one-call summary — it is sanitized end to end (closed key set,
truncated hex identifiers, everything else redacted; a dead collaborator
reports `:unavailable` instead of breaking the summary), so its output is safe
to record verbatim:

```elixir
RacingOrg.Tracker.Pro.Diagnostics.summary()
```

For provisioning detail, use the sanitized status projection and epoch reads:

```elixir
RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner.status()
RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner.credential_epoch()
RacingOrg.Tracker.Pro.SecureTransport.SessionHolder.live?()
```

`BootProvisioner.current_state()` remains available for on-console debugging,
but do not copy the complete returned bootstrap struct outside the console: it
can contain exact receipt envelopes and transcript bindings. Record only the
phase, closed blocked reason, retry count, authority kind, and credential
epoch — exactly the fields `status/0` already projects.

On the backend, use the admin device detail page. It exposes a sanitized
recovery gate, hardware identity, attempts, and append-only audit history. It
does not expose raw serials, identifier digests, key material, nonces, or full
receipts.

## 7. Conflict recovery

### Active-session conflict

An active session or recent activity blocks recovery as
`active_session_conflict`. First prefer the safe path:

1. Stop or isolate the old tracker.
2. Wait for the configured cooldown.
3. Retry while the runtime recovery window remains open.

If the conflict is known and cannot be cleared, an admin may grant the
implemented override from the device detail page. The override:

- is scoped to the exact pending attempt and exact candidate fingerprint;
- applies only to `active_session_conflict`;
- requires a sanitized human reason;
- is short-lived, defaults to five minutes, and cannot exceed fifteen minutes
  or the attempt expiry; and
- is audited on grant and consumption.

Do not put a serial, token, receipt, key, or full fingerprint in the reason.

### Conflicts that cannot be overridden

Identity conflict, stale credential epoch, duplicate candidate key, invalid
proof, expiry, and internal failures remain fail-closed. The active-session
override must not be used or represented as a way around these conditions.
Investigate the backend audit facts and preserve both tracker and backend
durable evidence.

## 8. Desired state and hydration status

Desired State v1 ACK status has three meanings:

- `staged`: the complete generation was durably received and verified, but it is
  not yet operational authority;
- `effective`: the exact generation was atomically activated and its operational
  gate is open; and
- `rejected`: a closed phase/code diagnostic records why the generation could
  not proceed and whether retry is allowed.

A staged ACK is not permission to operate and is not sufficient checkpoint
source authority. The backend authorizes a checkpoint source only when the
latest exact ACK for its credential epoch, storage epoch, and source generation
is effective. A later rejected ACK outranks an earlier effective one for that
source decision.

Tracker diagnosis:

```elixir
RacingOrg.Tracker.Pro.DesiredState.Manager.status()
```

Record only active generation, credential epoch, gate state, hydration state,
and closed recovery error. Rejected ACKs use fixed phases (`manifest`,
`transfer`, `staging`, `apply`, `wifi_trial`, `activation`) and fixed codes; they
must not contain free-form payloads.

Checkpoint hydration has committed crash-safe foundations:

- exact runtime schema registry;
- checkpoint heads;
- a journal advancing from `prepared` to `head_committed`;
- fenced desired-state begin/finish calls that keep runtime output quiescent;
  and
- restart validation of exact session, target identity, expected head, and
  checkpoint content.

Current integration limit: the authenticated `checkpoint_hydration` control
message is recognized by `ChannelClient`, but its runtime dispatch is still
explicitly unwired. The chunk staging primitive is also current uncommitted
work. Therefore there is no supported operator command to initiate end-to-end
hydration from the live channel yet. Do not fabricate one. Use backend
checkpoint records and tracker manager/journal diagnostics only, and keep the
operational gate closed when hydration is incomplete or blocked.

## 9. Outbox pressure and audited loss authorization

The segmented outbox is bounded by entry count, live bytes, encoded record
size, and total disk bytes. Enqueue returns explicit backpressure:

- `entry_capacity`;
- `byte_capacity`;
- `record_too_large`; or
- `disk_capacity`.

Entries are never evicted to create space. They are resolved only by an already
authenticated exact delivery receipt or an explicit durable loss
authorization. A successful send is not an acknowledgement.

Use the sanitized status surface:

```elixir
RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner.status(
  RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner
)
```

It reports acceptance/quarantine state, pending entry and byte counts, disk
usage, configured limits, storage binding, stream count, and retained loss
authorization count. It omits identifiers, paths, hashes, payloads, credentials,
and process references.

Pressure response:

1. Stop optional producers from adding more durable work.
2. Restore authenticated delivery and allow exact receipts to drain the queue.
3. Inspect whether the owner is quarantined or merely backpressured.
4. Do not delete segments, snapshots, run-state files, or old identity leaves.
5. Escalate before critical pressure can invalidate an OTA trial.

Audited loss authorization is implemented internally as
`Outbox.Owner.authorize_loss/3`. It targets one exact live entry, requires a
non-empty human-auditable reason, appends and fsyncs a loss-authorization
record, resolves only that entry, and retains bounded replayable audit history.

Current integration limit: no authenticated backend/admin operator workflow or
safe entry-selection UI is wired to this function. There is no supported
operator command for routine use. Do not call it ad hoc from a console: doing
so would require exposing exact entry identity and would bypass centralized
operator authorization. Until an operator surface exists, unresolved pressure
must be drained by authenticated delivery or handled as an engineering
incident. Never describe manual file deletion as loss authorization.

## 10. Safe OTA trial and rollback

Committed OTA safety foundations include:

- closed health criteria for firmware version/Git commit, authenticated session,
  credential epoch, desired generation and effective state, process health,
  control and telemetry receipt round trips, outbox integrity/pressure, and a
  continuous soak;
- sanitized crash-safe trial diagnostics;
- a fixed terminal deadline;
- durable `validation_decided` before firmware validation;
- durable `rollback_decided` before passive partition reversion;
- durable `reboot_pending` before reboot; and
- restart recovery that retries uncertain validation or rollback effects
  without guessing.

At or after the deadline, unmet or untrustworthy health requires rollback.
Clock regression, malformed snapshots, unavailable diagnostics, uncertain
firmware status, outbox corruption, or critical pressure fail closed.
Rollback uses passive `Nerves.Runtime.revert(reboot: false)`, persists the
resulting phase, and then requests reboot.

Current integration limit: the committed `Trial`, diagnostics, and retired
command-provider fencing exist, but the target-authority coordinator and its
production snapshot readers are uncommitted work and are not in the application
supervision tree. The legacy `FirmwareValidator.validate_on_connect/1` module is
not an active channel call site. Therefore the complete automatic health-trial
operator flow is not yet integrated in the committed runtime.

Until that integration lands:

- use only the established external NervesHub/future release workflow to deliver
  a signed image;
- do not send or replay a `validate_firmware` command—the provider refuses new
  execution so it cannot bypass the trial;
- do not manually call firmware validation as an operator shortcut;
- retain the prior partition/image; and
- classify lack of integrated trial status as a rollout blocker, not as a
  successful trial.

## 11. Production migration away from serial recovery

Serial recovery is temporary, lower-assurance development migration support.
Production exit requires:

1. Every production device has signed v2 authority and current credential epoch.
2. Desired state is effective and durable delivery is draining under admitted
   storage lineage.
3. No production identity depends on `development_serial` policy or the
   `development_recovery` cohort.
4. Runtime recovery is disabled and the sunset has elapsed or been removed only
   after closure.
5. The release permission is disabled in subsequent production builds.
6. Legacy markers and operator binding needs are eliminated through the signed
   enrollment path, not by copying or storing serials.
7. Audit evidence confirms no unexpected recovery attempt after closure.

Retain append-only audit, credential, receipt, storage-epoch, and checkpoint
lineage according to normal retention policy. Removing the recovery path must
not mean erasing historical evidence.

## 12. Completion checklist

- [ ] Backend support deployed before tracker update.
- [ ] Recovery gates closed by default; opening window recorded.
- [ ] Legacy binding used only for an approved development device.
- [ ] Development cohort and policy separately confirmed.
- [ ] Conflict classification and any exact override recorded in backend audit.
- [ ] Replacement credential epoch advanced exactly once.
- [ ] Old sessions rejected or evicted.
- [ ] Storage epoch admitted at the current credential epoch.
- [ ] Desired state effective; staged/rejected diagnostics dispositioned.
- [ ] Hydration integration limitation acknowledged where applicable.
- [ ] Outbox accepting and below limits; no silent deletion performed.
- [ ] No unsupported loss-authorization command used.
- [ ] OTA trial integration status explicitly checked; rollback retained.
- [ ] Runtime recovery closed after completion.
- [ ] No prohibited sensitive material copied into evidence.
