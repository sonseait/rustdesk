# Managed RustDesk Platform Monorepo Plan

## Status and scope

This document is an implementation plan for this new repository. Existing
files are the starting codebase; preserving or importing prior Git history is
explicitly out of scope.

The target is a self-hosted, single-tenant managed remote-access platform:

- a RustDesk client with the Flutter UI fork;
- the RustDesk `hbbs`/`hbbr` data plane;
- a new Rust control plane and web administration portal; and
- one in-tree copy of `hbb_common` shared by client and server.

The repository starts with the RustDesk client, `server/`, the shared
`libs/hbb_common`, `cp/`, and `cp-ui/`. It is treated as a new project;
there are no source-repository migration, history-preservation, or archival
requirements.

## Target repository layout

Use the repository root as the monorepo root and preserve the existing build
paths.

```text
rustdesk/                              # one Git repository / monorepo root
  src/, flutter/, libs/, ...            # existing client source
  libs/hbb_common/                      # normal tracked directory, not submodule
  server/                               # RustDesk data-plane service
    src/, docs/, docker/, ...
  cp/                                   # Rust control-plane workspace
    crates/
      api/
      domain/
      db/
      auth/
      protocol/
      node-agent/
    migrations/
  cp-ui/                                # React administration portal
  docs/
    architecture/
    adr/
```

## Workspace policy

One Git repository must not become one giant Cargo workspace initially.

The client and server currently have substantially different dependency ages,
target platforms, build scripts, and release profiles. A single Cargo resolver
would create unrelated upgrade pressure and make client builds needlessly
coupled to server/control-plane changes.

- Keep the client Cargo workspace at the monorepo root.
- Keep `server/Cargo.toml` as an independent Cargo workspace.
- Keep `cp/` as an independent Cargo workspace.
- Add `server` and `cp` to the root workspace `exclude` list.
- Use normal path dependencies to the single `libs/hbb_common` directory:
  - client: `../libs/hbb_common`;
  - server: `../libs/hbb_common`.
- Do not share `Cargo.lock` files between client, server, and control plane.

This is a Git monorepo with three independently releasable Rust workspaces.
It can be consolidated further only after dependency and build-target alignment
is an explicit project goal.

## Architecture boundary

```text
React admin portal -- HTTPS --> Rust control plane -- mTLS --> node agent
                                      |                    |
                                      |                    +--> hbbs / hbbr
                                      |
                                      +--> managed RustDesk client
                                              enrollment, heartbeat, tickets
```

- `hbbs` and `hbbr` stay on the latency-sensitive data path.
- The control plane owns users, roles, devices, policy, audit, configuration,
  signing keys, and session authorization.
- The client and server only verify public-key-signed credentials/tickets; the
  control plane private signing key never leaves the control-plane service.
- The node agent connects outbound with mTLS. Runtime consoles and management
  endpoints must not be exposed publicly.
- The existing server SQLite peer database remains protocol state only. The
  control plane uses PostgreSQL and must not write directly to that SQLite file.

## Phase 0: protocol and workspace baseline

1. Confirm client and server build against the same in-tree `hbb_common`.
2. Define the managed protocol v1:
   `DeviceCredential`, proof-of-possession, `SessionTicket`, relay
   authorization, key rotation, revocation, capability negotiation, and legacy
   client behavior.
3. Publish test vectors for valid, expired, revoked, replayed, wrong-target,
   and forged credentials. Client, server, and control plane must all use them.
4. Define release ownership and versioning: client version, server version,
   `hbb_common` protocol version, control-plane API version, and minimum
   compatibility matrix.

Exit criteria: a selected in-tree `hbb_common` baseline and passing protocol
fixtures across client, server, and control plane.

## Phase 1: repository foundation

1. Maintain root ownership and contribution guidance for the new repository.
2. Publish the managed-protocol architecture and compatibility decision.
3. Run client, server, control-plane, portal, and protocol checks independently
   in CI.
4. Maintain the supported client/server/control-plane compatibility matrix.

Exit criteria: documented ownership and protocol boundary, with path-aware CI
entrypoints for all independently releasable workspaces.

## Phase 2: bootstrap the Rust control plane (completed)

Build `cp/` as a separate Rust workspace.

1. Create crates for Axum API, domain services, SQLx/PostgreSQL access, auth,
   shared protocol signing/verification, and a node agent.
2. Add PostgreSQL migrations for users, roles, permissions, devices, device
   keys, groups/tags, enrollment tokens, server nodes, policy revisions,
   session requests/sessions, audit events, and signing-key rotation.
3. Implement local password auth with Argon2id, secure cookie sessions, TOTP
   MFA, RBAC, CSRF/rate limits, structured audit events, health endpoints,
   OpenTelemetry, and Prometheus metrics.
4. Make OpenAPI the source contract and generate a TypeScript API client for
   the React/Vite portal.
5. Deliver the first portal slice: bootstrap admin, login, Users and Roles,
   Devices, Server Nodes, and Audit Log.
6. Add self-hosted deployment: PostgreSQL, API, portal/Caddy, backups,
   migration job, TLS documentation, and a non-production Compose environment.

Exit criteria: a self-hosted installation creates an admin, manages users,
issues an enrollment token, and records every mutation in audit logs.

## Phase 3: managed client changes (completed)

The Flutter UI remains a presentation layer. Enrollment and credentials belong
to the Rust client core and are surfaced through the existing Flutter-Rust
bridge.

1. [x] Add a `managed_client` Rust module for bootstrap configuration, per-device
   Ed25519 key generation, enrollment, secure OS credential storage, renewal,
   revocation handling, heartbeat, and local policy cache.
2. [x] Add narrow FFI methods/events for managed status, enrollment, device info,
   policy state, and connection errors. Flutter must not access private keys or
   refresh tokens.
3. [x] Add Flutter views for enrollment/sign-in, managed-device status, server
   identity, policy status, and controlled connection initiation.
4. [x] Have heartbeats report device ID, public-key fingerprint, hostname, OS,
   version, capabilities, and health with data minimization.
5. [x] Request a short-lived session ticket from the control plane before a managed
   remote-session attempt. Bind it to source device, target device, permissions,
   expiry, and a single-use identifier.
6. [x] Add client-side target verification before granting a session, even when the
   server has already authorized it.

Exit criteria: completed in the managed-client implementation. Signed,
target-bound tickets are verified before use; policy snapshots are persisted in
the OS credential store and expire fail-closed while offline; a `401`/`403`
from heartbeat, renewal, or policy refresh deprovisions local credential,
ticket, and policy state.

## Phase 4: server enforcement and node management (completed)

1. Update the in-tree `hbb_common` protobuf protocol with additive,
version-gated managed credential and session authorization fields.
2. In `server/hbbs`, verify device credentials and proof-of-possession during
   registration. Support `off`, `optional`, and `required` managed modes.
3. Verify a session ticket before online lookup, hole punching, or relay
   authorization. Keep a bounded TTL cache of used ticket IDs to reject replay.
4. In `server/hbbr`, verify short-lived relay authorization before pairing
   streams. Do not accept long-lived device credentials as relay authorization.
5. Add internal-only server health/metrics/event surfaces. Emit authorization
   decision reasons without logging secrets or ticket contents.
6. Implement `node-agent` with outbound mTLS: collect health/config state,
   apply versioned desired config, call loopback runtime controls where
   appropriate, restart processes safely, and report rollout/rollback result.
7. Build portal screens for node health, desired/effective configuration,
   configuration diff/history, rollout progress, maintenance mode, and relay
   usage.

Exit criteria: completed. Expired, forged, replayed, wrong-device, and revoked
requests are rejected by server and target client; the portal can safely roll
out and roll back a server configuration through an outbound mTLS node agent.

## Phase 5: policy, sessions, and operations (completed)

1. Implement ACLs over user, role, device group, tags, ownership, time window,
   unattended access, MFA, and approval requirements.
2. Record the session lifecycle: requested, approved, authorized, direct or
   relayed, connected, ended, and failure reason.
3. Add policy flags for clipboard, file transfer, terminal, port forwarding,
   and recording metadata. Enforce each capability in the client, not only in
   the portal.
4. Add alerts, backup/restore drills, retention, export, webhooks/API keys,
   upgrade automation, and load/security tests.

Exit criteria: completed. The platform has an auditable, policy-enforced
remote-access flow and an operator runbook for recovery, upgrades, and
incident response.

## CI and release plan

- Path-filtered CI runs client, server, control-plane, common-library, Flutter,
  migrations, and deployment checks independently.
- A mandatory integration workflow runs control plane + hbbs + hbbr + two
  managed test clients and exercises enrollment, direct session, relay session,
  denial, revocation, and replay rejection.
- Use separate release tags/artifacts initially: `client/v*`, `server/v*`, and
  `cp/v*`; the root tag only marks a tested platform bundle.
- Maintain a published compatibility table. Block a release when a protocol
  change has no migration path for the supported client/server versions.

## Risks and non-goals

- A monorepo does not remove the need for protocol compatibility discipline.
- Do not force the three Rust workspaces into one dependency resolver during
  initial development.
- Do not expose hbbs/hbbr loopback consoles or control-plane signing keys.
- Do not rely on the existing SQLite `peer.user`/`peer.status` columns for
  authentication or authorization.
- Legacy RustDesk clients cannot be reliably governed by portal RBAC until they
  participate in the managed credential/session-ticket protocol.
