# Zero-touch managed device lifecycle

Status: implementation plan, not implemented. Language: Vietnamese with exact code identifiers preserved.

## Goal

Managed client tự enrollment, đồng bộ, gia hạn và phục hồi mà không yêu cầu người dùng bấm Enroll, Renew, Sync hoặc Remove enrollment; quản trị viên quản lý quyền từ portal.

## Current context and constraints

Workspace: `/Users/eric/Codes/rustdesk`. Branch at inspection: `main`.

Existing user changes MUST be preserved and must not be included in unrelated commits:
- `build/compose.yaml`
- `docker-compose.prod.yml`
- `desktop/flutter/lib/features/workspace/managed_status_card.dart`
- untracked `desktop/flutter/test/managed_status_card_test.dart`

Observed implementation:
- `desktop/src/managed_client.rs`: process-local state and OS credential store; enroll commits server identity before persisting local key; network requests frequently hold the state mutex; six HTTP call sites use `Client::new()` without explicit timeout.
- `desktop/src/flutter_ffi.rs:53-63`: bootstrap is tied to Flutter initialization; periodic refresh only syncs deployment configuration.
- `desktop/src/server.rs:579-669`: desktop server process owns IPC and rendezvous startup. Do not start a new privileged service just for this feature.
- `desktop/src/ipc.rs`: reuse existing authenticated local IPC boundary; inspect dispatch and authorization before adding managed messages.
- `desktop/build.rs:80-100` and `.github/workflows/managed-client-release.yml`: shared bootstrap token is currently compiled into managed artifacts.
- `desktop/Cargo.toml`: existing keyring features enable native macOS/Windows backends, not a Linux backend. Never claim Linux durable enrollment without verifying a real backend.
- API: `controlplane-api/crates/api/src/main.rs`; persistence: `controlplane-api/crates/db/src/lib.rs`; domain/contracts: `controlplane-api/crates/domain/src/lib.rs`, `controlplane-api/crates/protocol/src/lib.rs`.
- `controlplane-api/crates/api/src/main.rs`: credentials last 24h; policy lasts 4h. Current HTTP 401 responses conflate expiry, invalid proof and revoked device.
- `controlplane-ui/src/pages/DevicesPage.tsx`: device revoke exists, token revoke UI does not.
- `desktop/flutter/lib/integration/adapters/managed_client_adapter.dart`: refresh is skipped when `_check` throws.
- `desktop/flutter/lib/features/workspace/workspace_view_model.dart`: currently equates managed-only enrollment with active connectivity.

Previously executed baseline evidence, not verification of this future implementation:
- API `cargo test --workspace --locked`: passed; DB crate has zero tests.
- UI `yarn build`: passed, bundle-size warning.
- Flutter targeted tests: 12 passed, covering initial post-frame refresh and workspace model helpers, not lifecycle E2E.

## Scope

Required: Windows/macOS managed-only desktop lifecycle, durable identity, recoverable/idempotent enrollment, automatic refresh, accurate read-only status, explicit revoke handling, portal visibility and token revocation, migration of existing enrolled clients.

Unmanaged behavior remains unchanged. Do not remove legacy manual FFI exports merely to hide buttons; avoid breaking generated bridge signatures unnecessarily.

Out of scope: new generic device inventory product, remote command framework, arbitrary capability expansion, mobile background execution, hardware attestation, silent acceptance of OS screen-recording/accessibility permission prompts, unapproved production migrations/releases.

Zero-touch refers to managed enrollment/access maintenance. It cannot bypass OS consent or installer elevation requirements.

## Architecture / proposed approach

Use one lifecycle engine in the existing desktop server owner, with durable identity and a pure scheduling/state-transition component; Flutter reads sanitized snapshots through IPC and never owns enrollment or refresh timers. Each reconciliation step performs bounded HTTP outside the state lock, persists validated results, and publishes a new snapshot; reconnect/wake/startup resume the same workflow rather than create a new device. Server enrollment is transactional and idempotent under proof of possession, while server authorization distinguishes expired credentials, revoked identities and transient failures.

## Decisions and release gates

Confirmed by user: client requires no management buttons or token/URL entry.

Proposed defaults, not yet approved product/security policy:
1. Per-installation provisioning delivered by installer/MDM; binary contains CP URL and public trust anchor only. Do NOT assume an MDM exists. Release packaging is gated on selecting and testing a delivery channel; development can use synthetic provisioning fixtures.
2. Revocation blocks new managed sessions when learned. Immediate termination of established sessions and an offline session lease require explicit approval and data-plane work; do NOT imply instant global revoke in this phase.
3. Desktop identity is scoped to the existing server account/installation. macOS user Keychain and Windows service-account credential storage are not interchangeable. Native account-access tests are a release gate before moving existing keys between owners.
4. Linux is not part of the initial release gate. If required, select and prove a durable noninteractive credential backend first; an in-memory keyring fallback is unacceptable.
5. Recovery from a revoked or lost identity requires fresh admin provisioning, not automatic reuse of the old bootstrap token. Do not add a speculative remote recovery endpoint in this iteration.

Proceed with isolated engine/API/UI tests while decisions are pending. Do not ship tokenless artifacts or migrate ownership until gates 1 and 3 are resolved.

## Behavioral contract

### Read-only UI

Remove management controls from the managed-only card. Show one label and short guidance, no raw tokens, signatures or private keys:
- `setting_up`: pending enrollment or initial synchronization.
- `ready`: valid credential + valid policy + validated deployment config; connectivity shown separately from actual rendezvous/service status.
- `reconnecting`: transient network failure; cache may still authorize capabilities until expiration.
- `waiting_for_admin`: missing/expired provisioning or unusable credential store; retry non-destructively when conditions change.
- `revoked`: confirmed explicit revocation, persisted across restart.

Do not derive readiness from `device_id != empty`. Preserve last successful sync, next retry and a stable diagnostic code for support; do not expose HTTP bodies as user-visible errors.

### Durable identity and enrollment

Persist pending identity before sending any claim: schema version, installation/request UUID, public-key fingerprint, private signing key, deployment URL binding, trust anchors, generation counter, and lifecycle tombstone. Secrets remain in the native credential store; status metadata contains none.

Add a versioned `POST /v1/enrollment/claim-v2`; retain existing v1 claim for compatibility during rollout.

V2 request fields: existing claim identity/metadata fields plus `request_id` (UUID), `timestamp` (epoch seconds), `signature` (hex Ed25519). Authorization is the provisioning token, never placed in audit logs.

Sign a stable request payload constructed on both sides from the same fixed-order serializable struct: `version`, `purpose` (`enrollment-claim-v2`), `request_id`, `timestamp`, `token_hash`, `public_key`, `rustdesk_id`, `display_name`, `hostname`, `operating_system`, `client_version`. Verify key fingerprint against SHA-256(public key), timestamp freshness, signature and field bounds before mutations. Use shared fixtures in API/client tests to detect serialization drift. A retry reuses request ID and key but refreshes timestamp/signature.

For an existing request ID, verify proof and identity binding, then return the same active device without incrementing token usage, including when the original token has subsequently expired or exhausted. Explicit token revocation denies claim retries; revoked devices return `device_revoked`; changed identity/body binding returns conflict. Request-ID lookup alone must never authorize retrieval.

For a new request ID, lock/check token, insert device and increment token usage in one transaction. Concurrent identical claims must return one device. Unique RustDesk-ID collisions must return a typed conflict, not a 500. No recovery based only on hostname or RustDesk ID.

Suggested migration `controlplane-api/migrations/0016_idempotent_device_enrollment.sql`:

```sql
ALTER TABLE devices ADD COLUMN enrollment_request_id UUID;
CREATE UNIQUE INDEX devices_enrollment_request_id_idx
    ON devices (enrollment_request_id)
    WHERE enrollment_request_id IS NOT NULL;
ALTER TABLE devices ADD COLUMN enrollment_request_binding TEXT;
ALTER TABLE devices ADD CONSTRAINT devices_enrollment_request_binding_pair
    CHECK ((enrollment_request_id IS NULL) = (enrollment_request_binding IS NULL));
```

`enrollment_request_binding` hashes the normalized immutable request fields excluding timestamp/signature/token plaintext; the original enrollment token FK binds the authorization. Existing rows remain NULL. Do not rewrite historical migrations.

### Scheduling

Initial defaults, constants centralized in the engine:

```rust
const HEARTBEAT_INTERVAL_SECS: u64 = 60;
const CONFIG_REFRESH_INTERVAL_SECS: u64 = 300;
const CREDENTIAL_REFRESH_MARGIN_SECS: i64 = 3600;
const POLICY_REFRESH_MARGIN_SECS: i64 = 1800;
const CONNECT_TIMEOUT_SECS: u64 = 5;
const REQUEST_TIMEOUT_SECS: u64 = 15;
const RETRY_INITIAL_SECS: u64 = 2;
const RETRY_MAX_SECS: u64 = 300;
```

Use monotonic time for delays and UTC for signed expirations; inject both clocks and jitter into tests. Renewal/policy timing must cap the margin relative to a short issued lifetime to avoid immediate refresh loops. Startup/wake/network recovery trigger reconciliation; deduplicate signals while a step is running. Retry transient failures exponentially with jitter; credentials and usable policy are retained until expiry, but expiry denies new sessions regardless of retry delay. Re-read snapshots at expiry and publish state even without user interaction.

Reconciliation order: restore identity/tombstone -> obtain provisioning if needed -> ensure pending identity durable -> claim/recover enrollment -> renew missing/near-expiry credential -> refresh missing/near-expiry policy -> sync missing/due config -> heartbeat if due -> publish snapshot. A failed config fetch must not prevent revoke detection in other due requests. Do not restart the mediator unless effective config actually changes.

Snapshot generation fences every asynchronous result: if identity/deployment generation changed while HTTP was running, discard the stale response. Only mark success after persistence succeeds. Serialize mutations via the engine, not across a long-held network mutex.

### Authorization and revoke

Retain legacy `{error}` responses; add stable `code` on managed endpoints. Proposed codes: `device_revoked`, `credential_expired`, `invalid_device_proof`, `clock_skew`, `provisioning_invalid`, `provisioning_expired`, `identity_conflict`, `temporarily_unavailable`.

Only authenticated explicit `device_revoked` transitions to a durable tombstone. Expired credentials trigger renew; invalid proof/clock skew do not delete key material. Unknown 401/403 moves to diagnostic blocked state, not destructive deprovision. Revoked identity never falls back to bootstrap or unmanaged access.

Existing credential/policy/ticket APIs must continue checking the active device in DB. Domain-separate heartbeat and renewal signatures in the versioned protocol; include heartbeat metadata digest in its signed proof. Maintain old proof compatibility only for the declared rollout window, not as a fallback after v2 verification fails.

## Implementation tasks

Each numbered item is a small TDD slice, normally 2–5 minutes; platform integration is split into checkpoints and must not be treated as a single tiny task. All paths below are relative to repository root. New paths are explicitly proposed files, not claims they already exist.

For EVERY code slice: write the named failing test -> run the specified filter and confirm a semantic failure (not missing dependencies) -> implement minimally -> rerun to green. If the slice exceeds five minutes, split it before expanding scope. Commit only after explicit user authorization; otherwise retain small reviewable diffs. Never stage existing user changes wholesale.

### Phase A — deterministic lifecycle first

1. Create `desktop/src/managed_client/lifecycle.rs`; wire it from `desktop/src/managed_client.rs`. Add tests `pending_identity_is_required_before_claim` and `enrollment_alone_is_not_ready`. Define lifecycle inputs/effects and sanitized snapshot fields from the behavioral contract; no HTTP or OS store in reducer.
   Verify: `cd desktop && cargo test --lib managed_client::lifecycle::tests -- --nocapture`; RED then GREEN with both named tests executed (zero selected tests is failure).
2. Same file: add `expired_policy_denies_new_session`, `expiry_publishes_without_ui_poll`, `short_lifetime_does_not_spin`. Implement expiry evaluation and refresh deadline calculation with injected time.
   Verify same command; all named cases pass.
3. Same file: add `transient_failure_preserves_identity`, `retry_is_capped`, `recovery_signal_is_coalesced`, `revoked_never_reenrolls`. Implement backoff/jitter and durable tombstone transitions. Verify same command.
4. Create `desktop/src/managed_client/store.rs`; add fake store tests `pending_is_durable_before_claim`, `failed_write_does_not_publish_ready`, `restart_resumes_same_request`. Extract native-store encoding from `managed_client.rs`; version records and retain a legacy `StoredCredential` reader. Never use real user Keychain in unit tests.
   Verify: `cd desktop && cargo test --lib managed_client::store::tests -- --nocapture`.
5. Create `desktop/src/managed_client/transport.rs`; fake transport tests `request_is_bounded`, `network_does_not_hold_state_lock`, `stale_generation_result_is_discarded`. Centralize reqwest builder with explicit timeouts and typed errors; have engine execute one effect at a time. Verify: `cd desktop && cargo test --lib managed_client -- --nocapture`.

### Phase B — enrollment recovery and error contract

6. Create `controlplane-api/crates/db/tests/managed_enrollment.rs` and a test-only local Postgres harness. Add `claim_retry_returns_same_device` before writing migration/code. Harness requires `MANAGED_TEST_DATABASE_URL` pointing to a disposable database; it must reject missing URL and refuse production-like configuration. Use unique isolated schemas, automatic migrations, and cleanup; never inspect `.env` for credentials.
   Verify: `cd controlplane-api && cargo test -p control-plane-db --test managed_enrollment claim_retry_returns_same_device -- --exact --nocapture`. Expected initial semantic failure; later one passing test, not skipped.
7. Add the migration above; in `controlplane-api/crates/db/src/lib.rs` add transactional v2 claim while leaving v1 intact. Extend test file with `concurrent_claim_consumes_token_once`, `same_request_changed_key_conflicts`, `different_tokens_same_rustdesk_id_is_conflict`, `revoked_device_cannot_retry`. Map unique violations to domain conflict. Verify: `cd controlplane-api && cargo test -p control-plane-db --test managed_enrollment -- --nocapture`.
8. In `controlplane-api/crates/domain/src/lib.rs` and `controlplane-api/crates/api/src/main.rs`, add v2 validation/route and typed managed error codes. Add API tests `claim_v2_rejects_bad_proof_without_mutation`, `expired_credential_is_not_revocation`, `revoked_device_has_explicit_code`; use the isolated DB harness, factoring API construction into a testable helper if necessary. Verify: `cd controlplane-api && cargo test -p control-plane-api -- --nocapture` and check named tests actually ran.
9. Add shared synthetic request fixtures at `docs/architecture/fixtures/managed-enrollment-v2.json`; consume them from client/API tests. Extend `controlplane-api/openapi.yaml` and `docs/architecture/managed-protocol-v1.md` with v2 coexistence, canonical payload and retry semantics. Add `heartbeat_metadata_is_bound` and `renewal_proof_cannot_be_used_as_heartbeat` tests; implement purpose-separated v2 proofs in `desktop/src/managed_client/transport.rs` and API verification. Verify API suite plus desktop managed-client filter. Never put a real enrollment token in fixture.
10. In `desktop/src/managed_client.rs`, connect the lifecycle effects to v2 claim/renew/policy/config/heartbeat; replace direct state mutation with persisted effects. Tests `lost_claim_response_recovers_without_new_device`, `revoked_survives_restart`, `unknown_401_preserves_key` must pass using fake transport/store. Verify: `cd desktop && cargo test --lib managed_client -- --nocapture`.

### Phase C — one owner and nonblocking UI

11. Inspect owner startup/account paths in `desktop/src/server.rs`, `desktop/src/core_main.rs`, `desktop/src/platform/windows.rs`, `desktop/src/platform/macos.rs` before editing them. Add an owner guard in the existing server/IPC ownership path, not merely `OnceLock` in every process. Start lifecycle before rendezvous becomes managed-ready; startup must not block the IPC event loop on HTTP. Add `second_owner_cannot_start_worker` test around the owner abstraction. Verify desktop managed-client tests; native two-process validation remains mandatory below.
12. Extend `desktop/src/ipc.rs` with read-only managed snapshot and narrowly authorized connection preparation requests. No private key, raw credential, provisioning secret or ticket should cross IPC. Remove bootstrap/periodic worker from `desktop/src/flutter_ffi.rs`; existing managed status FFI reads owner state. Retain old bridge exports as internal compatibility wrappers without restoring buttons. Tests: `snapshot_contains_no_secret_fields`, `gui_attach_does_not_enroll`, `owner_unavailable_is_not_ready`. Verify desktop managed-client tests.
13. Update `desktop/flutter/lib/integration/adapters/managed_client_adapter.dart` to consume sanitized status and automatically refresh using the existing app lifecycle/service polling pattern. Do not create an enrollment timer here. Refresh after errors if any legacy mutating wrapper remains. Add `desktop/flutter/test/integration/managed_client_adapter_test.dart` covering revoked/error updates and disposal cancellation.
   Verify: `cd desktop/flutter && flutter test test/integration/managed_client_adapter_test.dart` (RED then GREEN).
14. Update `desktop/flutter/lib/features/workspace/managed_status_card.dart` and extend the existing user-owned `desktop/flutter/test/managed_status_card_test.dart` carefully; preserve the post-frame ancestor notification regression. Add tests `managed card has no lifecycle buttons`, `expired access never says Protected`, `revoked state is read only`, `reconnecting explains automatic recovery`. Delete unused dialogs/controllers from this widget, preserve compact existing styling, no new UI library.
   Verify: `cd desktop/flutter && flutter test test/managed_status_card_test.dart`.
15. Update `desktop/flutter/lib/features/workspace/workspace_view_model.dart` and `desktop/flutter/test/integration/workspace_view_model_test.dart`: distinguish enrollment, authorization readiness and actual connectivity; do not force `isOnline` merely from enrollment. In `desktop/src/client.rs`, `desktop/src/rendezvous_mediator.rs` and existing connection authorization paths, enforce core readiness and obtain per-connection target-bound tickets automatically. Do not reuse a single global pending ticket across simultaneous targets; add `parallel_targets_get_distinct_tickets` and `expired_policy_cannot_open_session`. Keep normal user Connect behavior; only lifecycle actions disappear.
   Verify: `cd desktop/flutter && flutter test test/integration/workspace_view_model_test.dart`; `cd desktop && cargo test --lib managed_client -- --nocapture`.

### Phase D — provisioning and portal

16. GATED on provisioning delivery decision: create `desktop/src/managed_client/provisioning.rs` with a provider abstraction, fake provider tests `missing_provisioning_waits_without_dialog`, `provisioning_bound_to_deployment`, `successful_claim_does_not_reuse_authorization`. Native store is secret storage; install/MDM input is a protected admin-delivered source, never executable-directory plaintext. Review ACL/account access on Windows/macOS. Verify desktop managed-client tests and native persistence matrix before step 17.
17. Update `desktop/build.rs` and `.github/workflows/managed-client-release.yml` to stop requiring/embedding `MANAGED_BOOTSTRAP_TOKEN` only once the installer/MDM input path is operational. Keep URL/public trust anchor compile-time validation. Add an artifact scanner using a synthetic marker, not real secret output; ensure no marker in distributable binaries/logs. Release workflow must fail if provisioning packaging prerequisites are absent; generic ZIP download alone is not proof of a provisioned installation. Add migration instructions to `controlplane-api/OPERATIONS.md`: existing enrolled clients restore without reenrollment, unprovisioned clients wait, rollback never reenables revoked identities. Do not rotate real secrets or publish a release during implementation.
18. Update `controlplane-ui/src/api.ts` and `controlplane-ui/src/pages/DevicesPage.tsx`: token revoke action using existing DELETE endpoint; show revoked/expired/exhausted state, device last seen and load/error/retry states. Disable mutation controls while pending and confirm destructive revoke. Do not fabricate client lifecycle telemetry from last-seen; add telemetry only if its wire contract is separately implemented. Since no UI test runner exists, introduce no framework just for this slice; use API integration tests and a documented browser validation against local synthetic data. Verify: `cd controlplane-ui && yarn build` (exit 0); manual checks listed below.

### Phase E — fault tests and rollout

19. Add `controlplane-api/crates/api/tests/managed_lifecycle.rs` after extracting a reusable router test harness; a test process must be able to start only a local API and isolated Postgres schema. Scenarios: enrollment reply lost after commit; server unavailable on startup; token exhausted after successful claim; explicit token revoked on retry; process termination between persistence steps; simultaneous claim; device revoke while refresh is running. Verify: `cd controlplane-api && cargo test --workspace --locked`; each named integration scenario must execute, not skip.
20. Extend `desktop/src/managed_client/lifecycle.rs` fake-clock tests to run beyond both issued expirations and simulate wake/network recovery. Verify no button/event is necessary to reach ready; tests must complete through virtual time, not sleep for hours. Run full targeted gates below; record exact commands/results and remaining native blockers. Update `docs/architecture/managed-protocol-v1.md` and `controlplane-api/OPERATIONS.md` in place, not a second competing design.

## Validation and acceptance

### Commands

Run from root using subshells to avoid accidental relative-directory mistakes:

```sh
(cd controlplane-api && cargo test --workspace --locked)
(cd controlplane-ui && yarn build)
(cd desktop && cargo test --lib managed_client -- --nocapture)
(cd desktop/flutter && flutter test test/managed_status_card_test.dart test/integration/managed_client_adapter_test.dart test/integration/workspace_view_model_test.dart)
git diff --check
git status --short
```

Expected: all named tests execute and pass, all commands exit 0, no whitespace errors; original user changes remain. Do not claim the future commands passed based on baseline output. Desktop native dependency failures are blockers, not permission to claim fake tests proved process integration.

Native managed build on the existing prepared platform runner, with synthetic test configuration and provisioning supplied by that runner:

```sh
(cd desktop && cargo build --locked --release --lib --features flutter,managed-only)
```

Do not invent a bridge-generation command. If FFI signatures change, inspect repository generator scripts and pinned FRB 1.80 tooling first; prefer keeping signatures stable.

### Acceptance matrix

- AC-01 Fresh provisioned install: first startup reaches ready without interacting with client UI; API contains exactly one active device. Evidence: local E2E and native Windows/macOS smoke.
- AC-02 Retry after committed response loss: same device ID and one token consumption; isolated DB test verifies counts directly.
- AC-03 Offline startup then network restoration: automatic progress, same key/request identity; fake-clock + local fault test.
- AC-04 Credential/policy expiration: proactive renewal and no access after actual expiry; deterministic time tests.
- AC-05 Explicit revoke: next successful authenticated check persists revoked, denies new sessions, restart cannot bootstrap again; integration/native tests. Existing-session termination is not claimed until policy is approved and implemented.
- AC-06 Bad proof, clock skew, unknown authorization failure: no key deletion, no fallback to unmanaged; transport/reducer tests.
- AC-07 Credential store failure: no claim sent before initial persistence, no false ready state, retry recovers safely; fake store test.
- AC-08 Multiple GUI windows and closing GUI: one owner/worker, background maintenance continues while existing server remains running; native two-process inspection, no secret IPC payloads.
- AC-09 Read-only UI: no Enroll/Renew/Sync/Remove lifecycle buttons; truthful readiness/online labels and diagnostics; Flutter widget tests.
- AC-10 Legacy installed device: durable credential restored under same owner; no duplicate device or unsolicited reenrollment; native migration test using synthetic legacy record.
- AC-11 Portal: administrator can revoke token/device, cannot duplicate pending actions, sees explicit error on 403/5xx rather than empty success; local browser check with synthetic admin/data.
- AC-12 Provisioning security: native store survives restart under actual server account; unauthorized local users cannot read provisioning input; distributable artifact excludes synthetic bootstrap secret marker. Windows/macOS native checks required.

### Manual local-only checklist

Use disposable API/DB and synthetic provisioning; never production.
1. Install/provision a fresh Windows/macOS test installation, start only server owner, verify background enrollment before opening GUI.
2. Open two windows; close both; observe one heartbeat stream and unchanged device ID while server remains active.
3. Interrupt API connectivity at each lifecycle phase, restore it, observe automatic recovery without clicking anything.
4. Revoke from portal, verify client read-only revoked state after next successful check; restart and confirm no fresh claim.
5. Restart under the real native account context; verify credential persistence and no OS credential prompt requirement during routine refresh.
6. Validate initial OS permission prompts separately; do not mislabel unavailable capture permission as enrollment failure.

## Rollout / rollback

Deploy backward-compatible migration and API v2 first; validate old clients against unchanged v1 routes. Then deploy lifecycle client to a small test group with existing enrollment restore, followed by provisioned fresh installations. Remove legacy shared-token distribution only after provisioning gates pass; invalidate distributed old bootstrap tokens administratively as a separate approved operation. Rollback client/API only to versions compatible with the additive migration, retaining revoked tombstones and never restoring revoked authorization from stale backups.

## Risks and open questions

- BLOCKING for release: installer/MDM provisioning delivery channel not selected; repository currently packages generic ZIPs.
- BLOCKING for owner migration: actual credential-store owner/account model must be tested on Windows and macOS. A process-local once guard does not enforce machine-wide ownership.
- Product decision pending: immediately terminate existing remote sessions on revoke? If yes, add active-session cancellation and bounded offline lease as a separate approved phase; current plan guarantees new-session denial after revoke is learned, not instantaneous revocation while offline.
- Product decision pending: is unattended pre-login availability required? This changes credential storage and service identity; do not infer it from zero-click enrollment.
- Linux durable backend absent in inspected manifest; keep explicitly unsupported for this rollout until resolved.
- New versioned signing payloads require client/API fixture agreement and an explicit legacy compatibility window.
- A stolen per-installation authorization can still be raced before binding without hardware attestation. Limit exposure/TTL and document that assumption; do not claim hardware-bound trust.
- UI and widget test files have user changes. Review and merge, never replace their existing content blindly.

## Commit checkpoints

Only after user authorization, commit passing slices separately: lifecycle reducer/store; API v2 + migration; transport/error contract; owner/IPC; read-only UI; provisioning/release; integration evidence/docs. Use explicit paths and inspect staged diff; never `git add .`. No commits, builds, migrations, external operations or implementation were performed as part of writing this plan.
