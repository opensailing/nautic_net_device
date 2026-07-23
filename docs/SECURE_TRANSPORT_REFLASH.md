# Secure-Transport Reflash + Enforcement Runbook (one device, end to end)

Operator runbook for the secure-transport rollout of a SINGLE Nautic Net device
against the RacingOrg server, covering: server prep, device provisioning + reflash,
and verification.

> The device firmware is now ALWAYS secure-only for UDP telemetry: each DataSet is
> sealed into an AEAD frame when a live session exists, and DROPPED (never sent in
> the clear) when there is no live session. There is no plaintext fallback and no
> device-side flag to flip — provisioning + verifying secure transport is the whole
> device-side job. The only remaining coordinated cutover is on the SERVER (§4):
> flipping the per-device column so the server REJECTS any plaintext attributed to
> the device.

This is the operational counterpart to the device wiring landed in P9-job-6
(`RacingOrg.Tracker.Pro.SecureTransport.SessionHolder` / `ChannelClient` / `BootProvisioner` in
the supervision tree, and the post-race `BulkUploader` trigger from
`RacingOrg.Tracker.Pro.Race.Archive`).

> Terminology: "device" = the Nerves firmware in `racing_org_tracker_pro`; "server" =
> RacingOrg (`backend`, deployed on Fly). All crypto is Ed25519 + ChaCha20-Poly1305;
> there is no PKI — the device PINS the server's public key and the server records
> the device's self-registered public key (a `DeviceKey`).
>
> Provisioning is TOKENLESS (Phase AC7): there is no claim token / server nonce. On
> boot the device generates its Ed25519 identity and self-registers it with the server
> via proof-of-possession (`POST /api/devices/register`). The device starts UNASSIGNED;
> an admin associates it to an account (by email) in the web panel afterward.

---

## 0. Invariants and ordering (read first)

- **Single-machine UDP invariant.** RacingOrg's UDP telemetry listener binds ONE
  IPv4 socket on the fly-global-services address and command replies egress from
  that same socket. Telemetry ingest, the per-device enforcement gate, and replies
  are all on that single machine. Do not assume multi-machine UDP fan-out.
- **Device is secure-only.** The firmware NEVER emits plaintext telemetry: with a
  live session it sends AEAD; with no live session it drops the datagram. There is
  no device-side flag and nothing to flip on the device — so the only coordinated
  cutover left is on the SERVER (turning ON `requires_secure_transport=true` for the
  device so the server rejects any plaintext attributed to it).
- **Server-side coexistence default.** The server's per-device
  `requires_secure_transport` defaults OFF (it still accepts plaintext from other
  devices). Confirm AEAD telemetry is arriving and the channel session is healthy
  before flipping it ON for this device (§4).

---

## 1. Server prep (Fly / RacingOrg)

### 1.1 Ensure the server identity seed is set (prod REQUIRES it)

The server signs its handshake HELLO with its Ed25519 identity seed. In prod the seed
MUST be configured (`RacingOrg.SecureTransport.ServerIdentity.private_seed/0` raises
otherwise); dev/test falls back to a fixed non-secret seed.

```sh
# 32-byte seed, raw or hex. Generate once, store as a Fly secret.
SEED_HEX=$(openssl rand -hex 32)
fly secrets set SECURE_TRANSPORT_SERVER_SEED="$SEED_HEX" -a <your-app>
```

### 1.2 Obtain the server's pinned PUBLIC key (to pin on the device)

The device authenticates the server against the server's Ed25519 PUBLIC key, derived
from the seed. Derive it ON THE SERVER so it is exactly what the server will sign with:

```sh
fly ssh console -a <your-app> -C \
  "/app/bin/racing_org eval 'IO.puts(Base.encode16(RacingOrg.SecureTransport.ServerIdentity.public_key(), case: :lower))'"
```

This prints a 64-char lowercase hex string — the value you set as
`SECURE_TRANSPORT_SERVER_PUBLIC_KEY` on the device (section 2.1). It is the device's
only server-trust anchor; treat a change to it as a firmware re-pin.

> Equivalent low-level form (same result):
> `Base.encode16(RacingOrg.SecureTransport.Primitives.ed25519_public_from_secret(RacingOrg.SecureTransport.ServerIdentity.private_seed()), case: :lower)`

### 1.3 Create an admin account (for the post-registration association)

There is NO claim token to mint. The device self-registers UNASSIGNED; an admin then
associates it to an account by email (§3.6). Bootstrap an admin in the release:

```sh
fly ssh console -a <your-app> -C \
  "/app/bin/racing_org eval 'RacingOrg.Release.create_admin(\"ops@example.com\", \"a sufficiently long password\")'"
```

Idempotent: re-running with the same email updates the password and re-confirms.

> That is the entire server prep for provisioning: the server seed (§1.1), its pinned
> public key (§1.2), and an admin account to do the association afterward. No token /
> nonce mint step exists anymore.

---

## 2. Device prep — build-host environment (baked into firmware)

`config/config.exs` reads the values below from the **build-host environment at
firmware-compile time** (the same mechanism as the existing `API_ENDPOINT` /
`UDP_ENDPOINT`), so they are baked into the image. You do NOT edit `config/target.exs`
or set anything on the running device — you `export` them in the shell that runs
`mix firmware`. Any value left unset is `nil`/`false`, which leaves the
secure-transport stack dormant (the safe default: `ServerIdentity` unpinned →
`ChannelClient` won't connect AND `BootProvisioner` has no trusted server to register
against → it no-ops).

Provisioning values:

| Env var | Maps to (wired in config.exs) | Purpose |
|---|---|---|
| `SECURE_TRANSPORT_SERVER_PUBLIC_KEY` | `ServerIdentity, public_key:` | The server pubkey from §1.2 (64-char hex or raw 32 bytes). The device's server-trust anchor, the only config the boot self-registration needs, AND the SINGLE enable for the secure-transport children. **Setting it enables secure transport; unset = legacy/plaintext.** |
| `API_ENDPOINT` | `:api_endpoint` | Server HTTPS base (register + bulk upload, and WS derivation). |
| `UDP_ENDPOINT` | `:udp_endpoint` | Server UDP host:port for telemetry. |
| `SECURE_TRANSPORT_WS_URL` (optional) | read directly by `ChannelClient` | Override the WSS channel URL. Default derives from `API_ENDPOINT` (`https`→`wss`, path `/device_socket/websocket`). |

> There is NO `CLAIM_TOKEN_SECRET` / `CLAIM_TOKEN_SERVER_NONCE` anymore. Registration
> is tokenless: the only provisioning secret the device needs is the pinned server
> public key, and the same image is safe to flash onto any number of devices (each
> generates its own identity and registers independently; the server is idempotent).

> There is NO device-side plaintext kill switch / fallback flag. UDP telemetry is
> AEAD-only unconditionally: with a live session the device seals + sends each
> DataSet; with no live session it DROPS the datagram (never plaintext). Nothing to
> set or flip on the device for transport security.

> There is NO separate build-time enable flag. The `BootProvisioner` / `ChannelClient`
> / `BulkUploader` start only on a real device target (`MIX_TARGET` != `host`) AND when
> `SECURE_TRANSPORT_SERVER_PUBLIC_KEY` is set (the pinned key IS the enable), matching
> how NervesHubLink / the UDP path are gated. `SessionHolder` starts in every
> environment (cheap, idle). Even when started, `ChannelClient` self-gates idle until
> registered + identity provisioned + server pinned, so the order of provisioning is
> forgiving.

### 2.1 Reflash the firmware

Export the environment, then build + flash, all in the same shell:

```sh
export API_ENDPOINT="https://racing.org"      # your server base
export UDP_ENDPOINT="racing.org:4001"
export PRODUCT="logger"
export SECURE_TRANSPORT_SERVER_PUBLIC_KEY="<64-char hex from §1.2>"  # the SINGLE enable: setting it turns on register + channel + bulk

MIX_TARGET=<target> mix firmware
MIX_TARGET=<target> mix burn                # or: fwup / NervesHub OTA push
```

> This image carries NO per-device secret (registration is tokenless), so the SAME
> image is safe to flash onto any number of devices: each generates its own Ed25519
> identity on first boot and self-registers independently. The server is idempotent —
> re-flashing / rebooting a device just refreshes its existing `DeviceKey`.

### 2.2 What the device does on boot (automatic)

1. `KeyStore.load_or_generate/1` generates the device's long-term Ed25519 identity on
   first boot and persists the 32-byte seed `0600` at `/data/secure_transport/device_ed25519.key`
   (reloaded unchanged on every later boot).
2. `BootProvisioner` self-registers the device: `POST /api/devices/register` with the
   PoP signature over `("RacingOrg-TrackerRegister-v1", public_key, timestamp)` — no
   claim token, no server nonce. On success it persists a register marker
   (`/data/secure_transport/register_marker.json`). The device is recorded UNASSIGNED;
   an admin associates it to an account in §3.6. A rejected registration is logged, NOT
   crash-looped — the device retries on the next boot.
3. `ChannelClient` connects the WSS channel (`/device_socket`), joins `device:<fp>`,
   runs the initiator handshake, and on `handshake_ok` publishes the live `Session`
   into `SessionHolder`.
4. UDP telemetry is AEAD-only (the `UDPClient` reserves a counter from
   `SessionHolder` and seals each DataSet). Any moment without a live session DROPS
   the datagram — the device never falls back to plaintext.
5. Post-race, `Race.Archive` finalizes the recording and triggers
   `BulkUploader.upload_async` (signed HTTPS bulk plane). Local recordings are kept
   until the server confirms completeness via `manifest_verification_result`.

---

## 3. Verification

### 3.1 Confirm the device registered (a `device_key` row exists)

```sh
# Find the device key by the device's identity fingerprint (see 3.2 for the fp).
fly ssh console -a <your-app> -C \
  "/app/bin/racing_org eval 'IO.inspect(RacingOrg.Devices.get_device_key_by_fingerprint(\"<fingerprint-hex>\"))'"
```

A non-nil `DeviceKey` with the expected `device_id` confirms the registration landed.
The device starts UNASSIGNED until an admin associates it (§3.6).

### 3.2 Find the device's fingerprint (from the device)

On the device console (`/data` identity), the fingerprint is lowercase hex
`SHA-256(public_key)`:

```elixir
{:ok, id} = RacingOrg.Tracker.Pro.SecureTransport.KeyStore.load()
id.fingerprint
```

It is the SAME id used as the WSS connect param and the `device:<fp>` topic, and the
value to use in §3.1 and §4.

### 3.3 Confirm the channel session is live

- Device side: `RacingOrg.Tracker.Pro.SecureTransport.SessionHolder.live?()` returns `true`, and
  device logs show `"[ChannelClient] secure session established"`.
- Server side: the session is in the `SessionStore` (routed by `session_id`), and the
  device log line above only prints after the server's `handshake_ok`.

### 3.4 Confirm AEAD telemetry is arriving (not plaintext)

On the server, `SecureUDPIngest` routes AEAD frames through the secure path. Watch the
UDP audit / ingest: AEAD datagrams ingest normally and do NOT show
`:plaintext_rejected`. The device is secure-only, so you should see NO plaintext
telemetry from it at all — a no-session window shows up as a gap (dropped datagrams),
never as plaintext.

### 3.5 Confirm a bulk upload completed

After a race finishes, the device logs `"Bulk upload starting: recording=..."` and
then `"Bulk upload complete: recording=..."`. Server side, check the manifest status:

```sh
curl -sS https://<host>/api/race_recordings/<recording_id>/manifest_status
# -> verification_status: "complete", no missing_chunk_indexes
```

### 3.6 Associate the registered device to an account (admin, replaces the old claim)

The device registers UNASSIGNED. An admin then associates it to an account by email
in the web admin panel (the post-registration step that replaces the old owner claim).
Identify the device by its fingerprint (§3.2) or the `device_id` from §3.1, find the
account by email (§1.3), and associate them in the panel. Once associated, the device's
telemetry and channel session are attributed to that account.

---

## 4. SERVER ENFORCEMENT (the only coordinated cutover)

The device is ALREADY secure-only: the firmware never emits plaintext telemetry (with
a live session it sends AEAD; with no live session it drops the datagram). There is no
plaintext-fallback stage and NO device flag to flip — provisioning + verifying secure
transport (§2–§3) is the entire device-side job.

The only remaining cutover is on the SERVER: flip the per-device
`requires_secure_transport` column so the server REJECTS any plaintext that is
attributed to this device. Because the device never sends plaintext, this is a safe,
no-window change — there is no "turn off device plaintext first" step and no rollback
ordering hazard.

Do NOT proceed until §3.3 + §3.4 are green for this device.

> **SERVER-ENFORCEMENT FINDING (verified read-only for this runbook):**
> The server's per-device `requires_secure_transport` column IS actually ENFORCED.
> The live UDP listener (`RacingOrg.UDPServer.process_datagram/5`) calls
> `SecureUDPIngest.handle_datagram/3` for EVERY datagram; on the legacy plaintext
> branch it resolves the attributable `%Device{}` and
> `plaintext_rejected?/1` rejects (`{:error, {:auth_error, :plaintext_rejected}}`,
> not ingested) when `match?(%Device{requires_secure_transport: true}, device)` — i.e.
> the per-device DB column is read and acted on. Covered by
> `backend/test/racing_org/racing_org/secure_udp_coexistence_test.exs`
> ("plaintext from a secure-capable device is REJECTED").

### Step A — Pre-checks
Confirm: device sending AEAD (§3.4), channel session healthy (§3.3), device-key row
present (§3.1) and associated (§3.6). The device emits no plaintext, so there is
nothing to change on the device.

### Step B — Turn ON server rejection for this device
Flip the per-device column so the server rejects any (now-impossible) plaintext from it:

```sh
fly ssh console -a <your-app> -C \
  "/app/bin/racing_org eval '
    fp = \"<fingerprint-hex>\"
    %{device_id: id} = RacingOrg.Devices.get_device_key_by_fingerprint(fp)
    dev = RacingOrg.Devices.get_device(id)
    {:ok, _} = RacingOrg.Devices.update_device(dev, %{requires_secure_transport: true})
  '"
```

From now on, a plaintext datagram attributable to this device is rejected
(`:plaintext_rejected`) and only its AEAD frames are accepted. The device only ever
sends AEAD, so telemetry keeps flowing unaffected.

### Rollback
Set the device's `requires_secure_transport` back to `false`
(`RacingOrg.Devices.update_device(dev, %{requires_secure_transport: false})`). The
server again accepts plaintext from it — though this device never sends any. There is
no device-side rollback step.

---

## 5. The GLOBAL device-transport flag (separate, fleet-wide — NOT this device)

> User-facing web/API auth is NO LONGER a flag. It is ALWAYS ON (the old
> `WEB_AUTH_ENFORCE` / `:web_auth` flag was removed): every web/API user surface
> requires a logged-in user + bearer token and is owner-scoped. The iOS app + web log
> in with an account; device telemetry ingest is device-authenticated and unaffected.
> So the only remaining global cutover is the UDP plaintext kill switch below.

The per-device server flip above (§4) is one device. One global SERVER flag remains;
do it ONLY after the WHOLE fleet is reflashed + verified:

- **`require_authenticated_device` (UDP telemetry kill switch).**
  `config :racing_org, :device_auth, require_authenticated_device: true`. When ON, the
  server rejects ALL plaintext telemetry from ANY device (even unknown), regardless of
  the per-device column — same `:plaintext_rejected` path
  (`SecureUDPIngest.plaintext_rejected?/1`). This bricks any not-yet-reflashed device,
  so it is the LAST step after the entire fleet is on AEAD.

Both `requires_secure_transport` (per-device DB column) and
`require_authenticated_device` (global config) are SERVER-side switches; the device
itself carries no transport flag (it is unconditionally secure-only).
