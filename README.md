# Managed RustDesk Platform

Self-hosted remote access platform with a RustDesk client, managed data plane,
Rust control plane, and React administration portal.

## Repository layout

- `desktop/`: RustDesk client and Flutter presentation layer.
- `server/`: `hbbs` rendezvous and `hbbr` relay services.
- `libs/hbb_common/`: shared protocol and runtime library.
- `controlplane-api/`: control-plane API, domain, database, protocol, and node-agent crates.
- `controlplane-ui/`: React/Vite administration portal.
- `build/`: Docker Compose configuration for building Docker images.

## Docker images

Build all images from the repository root:

```bash
docker compose -f build/compose.yaml build
```

Build selected images by specifying `server` or `controlplane-api`:

```bash
docker compose -f build/compose.yaml build controlplane-api
```

Set `SERVER_IMAGE`, `CP_IMAGE`, and `IMAGE_TAG` to override
image names and tags. Images target `linux/amd64`; `S6_ARCH` defaults to
`x86_64` for the server's s6 overlay.

```bash
IMAGE_TAG=v1 docker compose -f build/compose.yaml build
IMAGE_TAG=v1 docker compose -f build/compose.yaml push
```

Use this Compose file to build and push Docker images. The Makefiles contain
only native build and development targets.

The `controlplane-api` image bundles the portal and API in a non-root distroless runtime.
It serves the portal at `/` and API at `/api` on port `8080`; direct API paths
such as `/v1` and `/healthz` remain available for managed clients. Route the
public control-plane domain to this one container without stripping `/api`.
The server image retains Debian slim because its s6 services and key-loading
scripts require a shell and system utilities.

## Development checks

Run each workspace independently:

```bash
(cd desktop && cargo check --lib --features flutter)
(cd server && cargo check)
(cd controlplane-api && cargo test --workspace)
(cd controlplane-ui && npm run build)
```

See `managed-platform-monorepo-plan.md` for the implementation roadmap and
`controlplane-api/README.md` for local control-plane setup.

<img width="3456" height="2046" alt="CleanShot 2026-08-30 at 00 28 16@2x" src="https://github.com/user-attachments/assets/65bfe19a-d0a3-4e4b-83e2-0c27e8234fa8" />
