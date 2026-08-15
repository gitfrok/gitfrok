# Release-signing trust bundle

This directory is the versioned, non-secret trust artifact for signed releases the
control plane publishes as desired state and the data plane applies (T-0032, SPEC-0039
AC3). It is deliberately separate from the signing workflow: a verifier receives only
public keys and must never accept a key or a signature from anything but a release
manifest in this tree.

`release-signing-2026-08.pub` is the active ECDSA release-signing verification key. Its
SHA-256 fingerprint is
`98a6c7395960bb407eff26096f581278e602195dac620f8d38e4c4456130c5f3`.

`release-signing-2026-08-gen2.pub` is the staged successor of the T-0041 rotation
window (SPEC-0045 AC2, ADR-0065 decision 2): it sits BESIDE the active key so every
verifier dual-validates both during the overlap. Its SHA-256 fingerprint is
`4045b10667845f736f75a3176171419f4dc39a641b2df733c84846b7cbb45ad8`. Its private half
was a staged throwaway key generated OUTSIDE this tree (the sign-release.sh custody
posture, mirrored) and never committed; the window demonstrates the overlap shape —
`operator-app-0.1.0.release` verifies against it — and the removal step follows the
rotation rule below once the fleet has converged.

The matching private key lives only in the protected release pipeline (the CI
environment secret named for release signing); it is available only to approved release
jobs from `main` or a `v*` tag. It must not be copied here, into an image, into a chart,
or into a release request. A release manifest that cannot be verified against a key in
this bundle is refused before anything is applied.

This bundle is the same mechanism as `deploy/dev/trust/image-publish` — key-based,
offline, versioned — applied to release references rather than images (ADR-0044). The
canonical identity a signature covers is `oci_ref@digest`, exactly the string the backend
rollout verifier hashes (`modules/rollout` `SignedRelease.CanonicalIdentity`), so a
signature produced by `scripts/sign-release.sh` verifies byte-for-byte in the control
plane and by `scripts/check-signed-releases.sh` here.

During key rotation, add the new public key beside this one, keep both in the bundle so
consumers accept either, then remove this file only after active releases have been
re-signed or expired.

See governance ADR-0044 for custody and rotation rules.
