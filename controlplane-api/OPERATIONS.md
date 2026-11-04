# Production Operations

Set `CONTROL_PLANE_DOMAIN`, `NODE_AGENT_DOMAIN`, `NODE_AGENT_CA_FILE`, database credentials, `BOOTSTRAP_TOKEN`,
`DEVICE_CREDENTIAL_SIGNING_KEY`, and `TOTP_ENCRYPTION_KEY` in `.env.production`.
All secrets must come from the deployment secret manager and must not be
committed. `TOTP_ENCRYPTION_KEY` is a 32-byte hexadecimal key and is required
before enabling MFA.

Build the portal, then deploy with `docker compose -f compose.production.yaml up -d --build`.
Caddy obtains and renews public TLS certificates automatically. The API is only
reachable through Caddy; do not publish port 8080 or PostgreSQL. The
`NODE_AGENT_DOMAIN` listener is separate from the public portal and requires a
client certificate chained to `NODE_AGENT_CA_FILE`. It is the only route that
sets `X-Mtls-Verified` for the API; never expose the API container directly or
forward that header from another proxy.

Run the node agent as a supervised service with `NODE_AGENT_CONFIG` containing
its UUID, the `https://NODE_AGENT_DOMAIN/` URL, and PEM CA/client identity.
Set `NODE_AGENT_RUNTIME_URL` to the loopback-only hbbs/hbbr runtime controller
(default `http://127.0.0.1:21116/`). The agent polls desired configuration,
applies it through the loopback controller, rolls back on failure, and reports
its effective revision and rollout result over mTLS.

Run `scripts/postgres-backup.sh` from a scheduled job with `DATABASE_URL` and a
mounted, encrypted `BACKUP_DIR`. Restore drills must use `pg_restore --clean`
into an isolated PostgreSQL instance and include a login, enrollment, and
revocation verification before a backup is accepted.

Run `scripts/restore-drill.sh` at least quarterly with an isolated
`RESTORE_DATABASE_URL` and a recent `BACKUP_FILE`; the script refuses a
non-local/non-test destination. Retain audit and remote-session records for
the approved retention period, encrypt exported backups, and restrict access
to incident responders. Rotate API credentials and webhook secrets in the
secret manager, retry webhook deliveries with bounded backoff, and disable a
failing endpoint rather than repeatedly sending sensitive event data.

For an incident, revoke the affected device in the portal, rotate its
enrollment material, and inspect the control-plane audit log plus the
loopback-only hbbs/hbbr `/events` endpoint. Before a server upgrade, validate
the release in the managed enrollment/direct/relay/revocation/replay test
workflow, roll out through node-agent, and use its reported last-known-good
revision to roll back on failure.

## Zero-touch managed client rollout gates

Implementation is present; general release remains gated. Deploy/test the
additive migration and API v2 first, then validate v1 compatibility and a small
native client cohort. No production migration or release was run during this
implementation. Keep current managed-only compiled bootstrap distribution until
an installer/MDM delivery channel is selected, implemented, and ACL-tested. Do not
ship tokenless generic ZIPs or silently remove the current provisioning path.

Native Windows/macOS account tests are mandatory. Windows `--server` can run as
SYSTEM while Flutter runs as the signed-in user; macOS service launch can use a
different Keychain context. This change uses the existing owner's store and does
not copy keys between accounts. An existing record is read compatibly, including
legacy `StoredCredential`; pending v2 claims resume the same request/key after
restart. Do not interpret a record inaccessible from a different account as
permission to migrate or overwrite it. GUI connection preparation fails closed
when it cannot access the same identity as the owner. Selecting and proving the
owner/account strategy is a blocking native release gate.

Explicit revoke persists a versioned tombstone plus the existing nonsecret revoke
marker. The key is retained for diagnostics/recovery, with no bootstrap reuse.
Failed tombstone writes are retried while memory denies new access. Administrators
can select **Restore access** on a revoked portal row. Restore is an audited,
same-origin admin mutation; it enables retained-key automatic recovery with fresh
signed credential and policy, without bootstrap or re-enrollment. Apply migration
0017 before running the restore-capable API. Recovery remains blocked until an
explicit restore and retains the client tombstone on any validation/store failure.
This is reversible access revoke, not permanent compromised-key recovery. Lost or
compromised keys require new provisioning; do not use Restore access for them.
Older clients deleted the Keychain record on revoke. If the native status has an
empty `device_id` and `recovery_identity_missing`, restoring the portal row cannot
recreate the private key. Retire that old portal identity, then explicitly
reprovision the installation under administrator control. Do not automatically
clear the local revoke marker or reuse bootstrap authorization as a recovery
fallback. Keep the original RustDesk ID when replacing its lost managed identity.
After provisioning, verify both managed readiness and actual rendezvous
connectivity. A successful enrollment/heartbeat alone does not establish either:
the signed deployment configuration must contain hbbs, hbbr, and the server public
key and its signing key must be configured on the API.
Rollback must
retain tombstones and must not restore revoked authorization from old backups.
Linux's current keyring feature set has no durable backend and returns an explicit
unsupported diagnostic. Pre-login support and legacy-proof retirement remain
separate decisions. Existing-session termination requires product/data-plane work.

## Isolated validation

Database integration tests are opt-in, never auto-detect credentials. Supply only
`MANAGED_TEST_DATABASE_URL` pointing to a disposable loopback database named
`managed_test` or `managed_test_*`, then run:

```sh
cargo test -p control-plane-db --test managed_enrollment -- --ignored --nocapture
cargo test -p control-plane-api recovery_route_requires_restore_valid_proof_and_fresh_nonce -- --ignored --nocapture
```

The harness creates a unique schema, applies migrations, and drops the schema even
after a test assertion. It rejects remote/non-test destinations and never reads
environment files. These tests cover response-loss retry after expiry/exhaustion,
changed binding, concurrent consumption, token/device revoke, and ID collisions.
Restore tests additionally cover audit rollback, idempotency, explicit restore
eligibility, active-ID collision rollback, single-use nonce acceptance, and
revoked heartbeat/recovery denial including concurrent revoke transactions.
The API recovery route test exercises purpose separation, bad signatures, restore,
fresh signed response bindings, replay denial, and revoke after recovery.

Restore implementation checkpoint (2026-11-04): the native managed-only executor
suite passed 26 tests with synthetic bootstrap inputs; the standard Flutter runner
passed all 21 tests across `workspace_view_model_test.dart`,
`managed_client_adapter_test.dart`, and `managed_status_card_test.dart`.
`cargo test -p control-plane-api recovery --locked --offline -- --nocapture`
passed three tests and explicitly ignored the PostgreSQL route test.
`cargo test --workspace --locked --offline --no-run` compiled all API/DB tests.
`yarn build`, OpenAPI YAML parsing, and `git diff --check` passed. The full API
workspace execution encountered the existing healthcheck loopback PermissionDenied
restriction. PostgreSQL restore/audit/race and recovery-route execution remains
for a parent-run disposable database; compilation is not transaction evidence.
No production migration, deployment, or native-account/remote-session E2E was run.

The earlier zero-touch implementation session ran native managed executor tests using in-memory
store/HTTP fixtures and virtual UTC beyond both expirations. These exercise the
real executor but do not establish native Keychain/Windows account access, real
HTTP timing, two-process IPC ownership, or database transaction behavior. The
macOS native release library built with synthetic bootstrap inputs. Flutter's
normal runner was blocked by sandbox loopback binding; the actual 21 targeted
Flutter tests passed via the cached engine and Dart direct test runner without
sockets. The full API command hit the pre-existing loopback healthcheck restriction;
the remaining workspace tests passed with that single test explicitly excluded.
PostgreSQL tests were invoked and refused missing disposable configuration;
they are not passing integration evidence. `yarn build` passed (bundle-size warning).

The socket-free Flutter fallback is reproducible with cached dependencies:

```sh
python3 desktop/flutter/tool/run_managed_tests_without_sockets.py
```

Run it from the repository root. It compiles the same three targeted test files
and runs them in `flutter_tester` with VM service disabled; it does not replace
native bridge or two-process testing. Prefer the normal `flutter test` command
on an unrestricted runner.

Before release, run a local API/PostgreSQL E2E and the Windows/macOS matrix: first
startup, lost reply, offline/recovery, two GUI windows/closing both, renewal past
expirations, revoke/restart, and legacy record restore under the real account.
Verify one heartbeat stream and unchanged UUID. Browser-check the portal against
synthetic admin/data: load errors/Retry, active/expired/exhausted/revoked token
states, revoke cancellation/confirmation, and duplicate-click prevention. Browser
validation was not performed in the restricted session. No client lifecycle
telemetry is inferred from last-seen data.
