# Managed RustDesk Platform

Self-hosted remote access platform with a RustDesk client, managed data plane,
Rust control plane, and React administration portal.

## Repository layout

- `client/`: RustDesk client and Flutter presentation layer.
- `server/`: `hbbs` rendezvous and `hbbr` relay services.
- `libs/hbb_common/`: shared protocol and runtime library.
- `cp/`: control-plane API, domain, database, protocol, and node-agent crates.
- `cp/ui/`: React/Vite administration portal.

## Development checks

Run each workspace independently:

```bash
(cd client && cargo check --lib --features flutter)
(cd server && cargo check)
(cd cp && cargo test --workspace)
(cd cp/ui && npm run build)
```

See `managed-platform-monorepo-plan.md` for the implementation roadmap and
`cp/README.md` for local control-plane setup.

<img width="3456" height="2046" alt="CleanShot 2026-08-30 at 00 28 16@2x" src="https://github.com/user-attachments/assets/65bfe19a-d0a3-4e4b-83e2-0c27e8234fa8" />
