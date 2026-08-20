# Managed Protocol V1

`libs/hbb_common` is the sole shared protocol source for `client/` and
`server/`. Managed fields are additive protobuf fields so legacy peers ignore
them safely.

- A control-plane-signed device credential binds a managed device UUID and its
  RustDesk ID; `hbbs` verifies it at registration.
- A five-minute session ticket binds source device, target device,
  `remote-control`, expiry, and a single-use ticket UUID.
- Data-plane services receive only the Ed25519 issuer public key. The private
  signing key remains in `cp/`.
- `off`, `optional`, and `required` modes define the legacy rollout boundary.
  Invalid supplied managed credentials never downgrade to legacy access.

Compatibility is v1 while client and server both consume the versioned
credential and ticket envelopes. New fields must be additive and version-gated.
