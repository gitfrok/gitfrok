# Dev image-publish trust bundle

This directory is the versioned, non-secret trust artifact for first-party
images published to the development environment. It is deliberately separate
from the signing workflow: a verifier receives only public keys and must never
accept a key or a signature from a release request.

`image-publish-2026-08.pub` is the active ECDSA Cosign verification key. Its
SHA-256 fingerprint is
`547f43d0d7b89a9fc7c12c5c3a4961725b0f42c5cda199e5431393a884533e6f`.

The matching private key and passphrase are GitHub Actions environment secrets
named `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD`; they are available only to
approved `image-publish` deployments from `main` or a `v*` release tag. They
must not be copied here, into an image, or into a release request.

The operator/agent delivery work consumes this artifact and records its mount
location before it applies any release. During key rotation, add the new public
key beside this one, configure consumers to accept both, then remove this file
only after active releases have been re-signed or expired.

See governance ADR-0044 for custody and rotation rules.
