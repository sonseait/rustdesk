# Managed Protocol V1

`libs/hbb_common` is the sole shared protocol source for `desktop/` and
`server/`. Managed fields are additive protobuf fields so legacy peers ignore
them safely.

- A control-plane-signed device credential binds a managed device UUID and its
  RustDesk ID; `hbbs` verifies it at registration.
- A five-minute session ticket binds source device, target device,
  `remote-control`, expiry, and a single-use ticket UUID.
- Data-plane services receive only the Ed25519 issuer public key. The private
  signing key remains in `controlplane-api/`.
- `off`, `optional`, and `required` modes define the legacy rollout boundary.
  Invalid supplied managed credentials never downgrade to legacy access.

Compatibility is v1 while client and server both consume the versioned
credential and ticket envelopes. New fields must be additive and version-gated.

## Recoverable enrollment and automatic maintenance (HTTP v2)

The additive migration `0016_idempotent_device_enrollment.sql` adds an optional
request UUID and immutable binding to devices. Existing rows and v1 enrollment
remain valid. Deploy this API before the new client; the client intentionally
does not downgrade a failed v2 claim to a nonrecoverable v1 claim.

`POST /v1/enrollment/claim-v2` carries the existing identity/metadata fields plus
`request_id`, epoch-second `timestamp`, and hex Ed25519 `signature`. The token
is authorization, never audit detail. The shared implementation in
`libs/managed_claim.rs` signs UTF-8 compact JSON with exactly these ordered fields:

```text
version=2, purpose="enrollment-claim-v2", request_id, timestamp,
token_hash=hex(SHA256(token)), public_key, rustdesk_id, display_name,
hostname, operating_system, client_version
```

Identity strings are bounded, nonempty, and already trimmed. Public keys are
canonical lowercase hex; the fingerprint must equal SHA-256(public key).
Signatures and timestamp freshness (300 seconds) are checked before database
access. `docs/architecture/fixtures/managed-enrollment-v2.json` contains synthetic
canonical bytes, signature, and binding and is executed by both client and API tests.

The binding hashes that payload with timestamp zero. The original token FK
also binds authorization. Request-ID advisory locking, token row locking, device
insertion, audit insertion, and token consumption are one transaction. A retry
proves possession again and returns the same active device without consuming
another use, including after token expiry/exhaustion. A revoked token denies
retries; a revoked device returns `device_revoked`; a changed binding or unique
identity collision returns `identity_conflict` (409). Request UUID, hostname,
and RustDesk ID alone never authorize recovery.

Renewal and heartbeat accept additive `proof_version: 2`. Their signed bytes are:

```text
2:{purpose}:{device_uuid}:{timestamp}:{nonce_uuid}:{hex(SHA256(metadata_json))}
```

Purpose is `credential-renew` or `heartbeat`. Renewal metadata is JSON `null`.
Heartbeat metadata is the exact validated metadata serialized as compact JSON
with sorted object keys (including nested keys). Existing v1 proof handling is
selected only by omitted/1 `proof_version`; failed v2 verification never falls
back. Legacy proof retirement is a rollout gate still requiring a selected
compatibility window. Credential/policy/ticket wire envelopes remain version 1.

Managed errors retain `{error}` and add `code`: `device_revoked`,
`credential_expired`, `invalid_device_proof`, `clock_skew`,
`provisioning_invalid`, `provisioning_expired`, `identity_conflict`, or
`temporarily_unavailable`. Only an explicit authenticated `device_revoked`
creates a local tombstone. Expiry renews access; unknown 401/403, bad proofs,
and skew preserve the identity. Database-backed active-device checks remain
on credentials, policy, and tickets. Revoked proof requests are authenticated
against their stored key before the API reports revocation.

## Desktop ownership and authorization

### Reversible access revoke and restore

`POST /v1/devices/:id/restore` requires the existing administrator session and
same-origin protection. Migration `0017_device_access_restore.sql` records an
explicit restore on the device row. Restore and its `device_restored` audit event
commit together; repeated restore of an active row returns 204 without another
event. Unknown rows return 404; an active RustDesk ID collision returns 409.
Revoke clears the restore marker. This is reversible **access revoke**, not
permanent compromised-key recovery. Lost or compromised keys require new
provisioning and a new identity; do not restore an identity whose key is unsafe.

A locally revoked worker retains its key and polls only
`POST /v1/devices/:id/recovery`, using bounded retries (2–300 seconds with jitter).
It never bootstraps or re-enrolls. The request is a v2 proof with purpose
`device-recovery`, JSON null metadata, a fresh random UUID nonce, and epoch-second
timestamp within 300 seconds. No v1 or purpose-less payload fallback is accepted.
After authenticating the retained key, the API locks the device row and checks
that it is active and explicitly restored while consuming the single-use nonce
in the same transaction. Heartbeat/renewal nonce acceptance now also locks and
checks active status in its transaction, closing the authenticate/revoke race.

The response is `{claims, signature, issuer_public_key}`. Its Ed25519 signature
covers compact JSON in shared `RecoveryClaims` field order:

```text
version=1, purpose="device-recovery", device_id, nonce, timestamp,
issued_at, expires_at, credential, policy
```

`issued_at` and `expires_at` are epoch seconds, at most 60 seconds apart. The
nonce and timestamp exactly echo the request. Both nested credential and policy
are freshly issued, independently signed v1 envelopes. The outer signature binds
these artifacts to this request. The client validates the pinned issuer (when
already learned), all three signatures, device UUID, retained-key fingerprint,
local RustDesk ID, exact nonce/timestamp, credential issuance time, and expiry.
Unexpired artifacts from an earlier attempt cannot authorize a new recovery.

Local revoke increments the durable identity generation, invalidates config,
clears tickets, and retains the tombstone even if persistence fails. A response
from an older generation cannot clear a newer tombstone. Recovery persists both
verified artifacts and the non-revoked state as one secret-store record before
clearing the auxiliary local marker, under the generation lock. Any validation,
transport, replay, or persistence failure leaves access blocked, including after
restart. A crash between record write and marker clear conservatively retries
recovery. Successful recovery resumes ordinary configuration reconciliation;
readiness still requires a validated configuration. No client recovery button is
exposed. A revoke not yet learned locally still has the existing heartbeat/offline
detection limits; restore does not add instant push or terminate existing sessions.

The process binding the existing main IPC listener starts one managed lifecycle
worker. Flutter initialization only starts a read-only snapshot reader. It does
not enroll or renew. The worker restores the existing account's credential,
persists pending key/request/body before claiming, renews credentials, refreshes
policy/config, and heartbeats without user interaction. HTTP uses a 5-second
connect timeout and 15-second total timeout, with redirects disabled and no HTTP
under the status mutex. A separate operation lock serializes mutations; every
published response is fenced by identity generation. Persistence precedes publication.

Scheduling uses monotonic delays and UTC expiration checks. Heartbeats run every
60 seconds, configuration every 300 seconds, credential renewal before expiry
with a margin capped to one-quarter of issued lifetime, policy before expiry,
and failures retry from 2 to 300 seconds with jitter. One sequential worker
coalesces work. Sleep/wake and network restoration resume on the next tick/retry;
there is no dedicated native wake subscription in this iteration.

Read-only snapshots expose readiness, enrollment, expirations, stable diagnostic
codes, last successful synchronization, and next retry. No private key, token,
raw credential, policy envelope, or session ticket crosses IPC. Snapshot reads
on Flutter use a short-lived Rust-side cache; owner unavailability fails closed.
Readiness requires valid credential, policy, and a validated deployment config;
rendezvous connectivity comes separately from the existing service status.
New outgoing native connections automatically request a target-bound ticket;
concurrent targets use separate entries. New incoming login requests also check
readiness. Expired policy/credential and learned revoke deny new sessions.
Existing-session termination and instantaneous offline revocation are not claimed.

Connection preparation reopens the native record under the existing GUI account
and verifies it matches the server owner's public device UUID. If the accounts
cannot access the same record it returns `credential_owner_unavailable`, without
moving keys, enrolling in the GUI, or sending credentials/tickets through IPC.
This account boundary must be resolved and tested before native release.
