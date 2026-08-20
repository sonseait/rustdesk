# RustDesk Managed Control Plane

This is an independent Rust workspace for the single-tenant managed platform.
It deliberately does not join the client or server Cargo workspaces.

## Local development

1. Start PostgreSQL: `docker compose up -d postgres`.
2. Copy `.env.example` to `.env` and set a long, random bootstrap token.
3. Run the API: `cargo run -p control-plane-api`.
4. Call `GET /healthz`, then create the one-time initial administrator with
   `POST /v1/bootstrap/admin` and `Authorization: Bearer <BOOTSTRAP_TOKEN>`.

The bootstrap endpoint is disabled after the first user is created. Replace
the development bootstrap token with a deployment-specific secret before any
non-local use.

## Session and anonymous access policy

`POST /v1/auth/login` creates an opaque, database-backed session and returns a
`HttpOnly`, `SameSite=Strict` cookie. `GET /v1/auth/me` reads it and
`POST /v1/auth/logout` revokes it. Set `SESSION_COOKIE_SECURE=true` whenever
the API is behind HTTPS; its loopback development default is intentionally
insecure only to permit local HTTP development.

The single `server_policy` record is separate from portal authentication and
defaults to disabled. It contains an anonymous-session duration, a concurrent
device cap, and a distinct-device rate limit over a configured time window.
When the `hbbs`/`hbbr` integration applies this policy, it must never create a
portal session, grant a user role, or bypass authorization for managed devices.

## Managed device credentials

Set `DEVICE_CREDENTIAL_SIGNING_KEY` to a 32-byte Ed25519 seed encoded as 64
hexadecimal characters, stored in the deployment secret manager. Enrolled
devices prove possession of their private enrollment key to renew a signed
24-hour credential. Renewal requests are timestamp bounded and their nonce is
single-use; a revoked device cannot renew or heartbeat. If the signing key is
not configured, enrollment and heartbeats still work but credential renewal
returns `503`.

Signed device heartbeats additionally update the device's hostname, operating
system, client version, declared capabilities, and a bounded health object.
They must not include screen content, peer IDs, user identifiers, or session
details.

`POST /v1/device-policy` returns an issuer-signed policy snapshot bound to the
credential device. Clients persist it with their OS credential-store entry and
fail closed for new managed sessions when it is missing or expired. A `401` or
`403` from renewal, heartbeat, or policy refresh deprovisions the local device
state, including cached policy and pending tickets.

`POST /v1/session-tickets` accepts a valid signed device credential and issues
a signed five-minute ticket bound to one source device, target device, and the
currently supported `remote-control` permission. The Rust client places its
opaque public envelope on the versioned punch request; Flutter never receives
the ticket or any private key material.

## Node authorization modes

The node-agent supports `off`, `optional`, and `required` managed modes. In
`required`, registration needs a valid signed device credential. In `optional`,
legacy registration remains available but an invalid supplied credential is
rejected rather than downgraded. Session tickets are verified against the
configured issuer public key, bound to both device IDs, and consumed once in a
short-lived replay cache before the node begins peer lookup or relay pairing.
Desired node configuration is revisioned: the agent exposes its effective
revision in health state and refuses stale or rollback revisions.

Administrators publish the desired mode and issuer public key for this single
server through `GET`/`PUT /v1/current-server/config`. Each update increments
the desired revision and is recorded in the audit log; the signing private key
is never returned by this endpoint.

## Managed wire envelope

`libs/hbb_common/protos/rendezvous.proto` adds versioned,
backward-compatible `ManagedDeviceCredential` and `ManagedSessionTicket`
envelopes. They carry canonical signed claims, their signature, and issuer
public key. A device credential is additionally bound to its RustDesk ID, so
it cannot register another device's rendezvous identity. The ticket envelope
is available on punch/relay requests; device
credentials must not be used as relay authorization. `hbbs` verifies the
session envelope before target peer lookup and consumes its ticket ID in a
short-lived replay cache.

The client attaches an unexpired public credential envelope to its regular
`RegisterPeer` message. It does not expose the private device key or the
credential to Flutter, and legacy rendezvous servers continue to ignore the
new field.

Enrollment also records the device's RustDesk ID separately from its managed
device UUID. This establishes the target mapping required before the client
can request a target-bound session ticket; devices enrolled before this
migration must re-enroll to obtain that mapping.
