# ADR 0001: One Root Shared Protocol Library

## Decision

Use `libs/hbb_common` as the single shared protocol library. Client and server
remain independent Cargo workspaces and reference it with path dependencies.

## Consequences

The workspaces retain independent lockfiles and release cadence, while protobuf
and managed authorization envelope changes are built together. A protocol
change requires client and server validation before release.
