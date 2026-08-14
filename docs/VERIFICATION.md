# Verification evidence — stateless tracker recovery (tracker)

Status of record for branch `feat/stateless-tracker-completion` as of
2026-08-13. The backend repository keeps its own `docs/VERIFICATION.md`
(branch `feat/stateless-tracker-delivery`); cross-repository contract
evidence is recorded in both.

## 1. How this repository is verified

Every `mix` invocation (test, format, compile) needs the host test
environment:

```shell
API_ENDPOINT=http://127.0.0.1 UDP_ENDPOINT=127.0.0.1:9999 PRODUCT=logger mix test <files>
```

Two suite families require different invocations, so **no single aggregate
`mix test` run covers the repository** — this split is the documented
deviation from a one-shot `mix test.all`-style gate:

- `test/racing_org/tracker/pro/durable_delivery/**` runs with `--no-start`
  (the suites own their process trees and on-disk roots);
- everything else runs with the application started (telemetry handlers,
  nav/compute registries).

Commit gating for every change on this branch: focused suites green with
`set -o pipefail` on any piped run, `mix format --check-formatted`,
`mix compile --warnings-as-errors`, `git diff --check`, and a staged-path
audit (never `.claude/`, worktrees, `.envrc`, firmware images, or dumps).

## 2. Final evidence sweeps (run 2026-08-13)

| Sweep | Invocation | Result |
| --- | --- | --- |
| e2e + secure_transport + desired_state + diagnostics + nav + compute + web_clients | app-started | 1268 tests, 0 failures |
| durable_delivery (outbox, checkpoint pipeline, hydration, native segment) | `--no-start` | 584 tests, 0 failures |
| Backend counterpart sweeps | see backend `docs/VERIFICATION.md` | all green |

## 3. Evidence by gap-closure milestone

Commit messages carry the per-change RED/GREEN narrative; deterministic RED
preceded every production change.

| Milestone | Commits | Evidence |
| --- | --- | --- |
| Checkpoint production scheduler (periodic exact-checkpoint submission, receipt-driven accepted-head install) | `0289f5c` | 7 scheduler tests; RED first |
| OTA receipt health evidence + Wi-Fi reconnect confirmation | `630613b` | receipt-evidence, reconnect-confirmation, channel and application-integration tests; RED first |
| External output fencing on the operational gate (UDP, Nav PGNs, compute broadcasters, estimator publications; legacy carve-out) | `e7404dc` | 224-test milestone sweep + 73-test channel client suite; RED first |
| Contract freezes: KAT sha-pin, command_v1 golden vectors | `bc3c9f6`, `a16811a` | 727-test secure_transport+commands sanity run; freeze tests green immediately (expected) |
| E2E matrix: reconnect-without-rotation, lost-status/storage loss, ENOSPC + no-validate, multi-stream loss, blank-to-operational, legacy rollout compat, durable command payload characterization, checkpoint-transfer gaps | `9444671`, `044732f`, `5a09014`, `e65c8d1`, `95e2b12`, `ca73844`, `60e4596`, `1d5f3f9` | 26 tests across 7 e2e files + widened checkpoint-transfer suite; test-only (no defects exposed) |
| Sanitized operator diagnostics (`Diagnostics.summary/0`, `BootProvisioner.status/1`) + serial-console runbook | `26fd909` | 29 tests; RED first |
| Frozen-doc sha correction | `3096652` | doc-only; sha is test-pinned both repos |

## 4. Cross-repository contract pins

- `priv/secure_transport/desired_state_v1_kat.json` — byte-identical in both
  repositories, SHA-256
  `3973265021ae78274938883ee9169ecdfd2cb291a4e02f4ec24856f8fa19055a`,
  sha-pinned by a test on each side. Changing it is a wire-contract break
  requiring cross-repo coordination.
- `priv/secure_transport/command_v1_vectors.json` — canonical here, mirrored
  byte-identically in the backend, SHA-256
  `a108f15d2368f221ede5fc5d6ead0c02e71a685a71044e115f5b7767750fb26d`,
  sha-pinned on both sides.
- Known frozen divergence (characterized, deliberately not redesigned): the
  backend fence stores protobuf ServerReply bytes as the durable
  `command_delivery` payload while the tracker ledger accepts only the
  Canonical `{"type","args"}` envelope. The e2e characterization proves the
  protobuf shape is rejected **safely** (`:invalid_payload` terminal ack, no
  crash, no wedge, sequence advances, canonical commands still apply). Both
  shapes are pinned in the shared vectors so neither can drift silently.

## 5. Flake census

- No currently known flaky tests on this branch; suites are seed-randomized
  and the final sweeps above ran clean.
- Fixed during the phase: checkpoint-scheduler test lifecycle races (owned
  processes moved to `start_supervised!` with unique ids); a broken commit
  from the `assert_push/5` ref-position + unpiped-exit-code combination
  (`e0d45a5`, corrected by `3891197`) — both gotchas are captured in §1's
  gating rules.
- Backend flake census (test-DB contamination, resolved) is recorded in the
  backend `docs/VERIFICATION.md`.

## 6. Environment-blocked / not attempted

- **Nerves target build (RPi3)**: not built in this phase. System releases
  build locally via the documented Docker flow; the target build belongs to
  the separately approved submission workflow, along with any push, PR,
  deploy, or hardware operation.
- **Hardware-in-the-loop** (CAN/NMEA bus, real Wi-Fi trials, serial console):
  host-simulated only; the injectable seams used are the production ones.
- **Two-app live harness — decision recorded (Phase-0 item 6)**: a live
  paired run of the real backend and real tracker was **not attempted**, in
  bounded form or otherwise. Rationale: the SocketTest fake-backend exercises
  the real client, codec, outbox, and desired-state stack against frozen
  shared vectors, and both repositories pin byte-identical KAT/vector files
  plus per-repo goldens, so a live pairing adds mostly environment coupling
  (coordinated PostgreSQL, Phoenix endpoint, and device supervision trees)
  rather than contract coverage. Revisit after launch if wire-contract churn
  resumes; until then the sha-pinned vectors are the cross-repo authority.
