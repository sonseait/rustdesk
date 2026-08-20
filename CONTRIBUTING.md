# Contributing

This repository has independent client, server, and control-plane Rust
workspaces. Run checks from the workspace you changed; do not merge their
Cargo lockfiles or force them into one dependency resolver.

`libs/hbb_common` is shared by the client and server. Treat protobuf changes
as versioned protocol changes: keep fields additive, retain legacy behavior,
and validate both client and server builds.

Never commit control-plane signing keys, enrollment tokens, database dumps, or
production configuration. Keep `hbbs`/`hbbr` management interfaces loopback
only.
