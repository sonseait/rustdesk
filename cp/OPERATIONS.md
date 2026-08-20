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
