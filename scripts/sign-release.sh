#!/usr/bin/env bash
# T-0032 / SPEC-0039 AC3 — sign a release reference (ADR-0044 key-based model).
#
# A release is (component, version, oci_ref, digest). Its signature covers the canonical
# identity `oci_ref@digest` — EXACTLY the string the backend rollout verifier hashes
# (modules/rollout SignedRelease.CanonicalIdentity) and the string check-signed-releases.sh
# re-verifies here. One identity, three verifiers, no drift.
#
# The signature is ECDSA over SHA-256 of that identity, DER-encoded, carried as a single
# base64 line. That is byte-compatible with Go's ecdsa.SignASN1/VerifyASN1 over
# sha256.Sum256(identity) — so a manifest this tool signs verifies in the control plane.
#
# CUSTODY (ADR-0044): the private signing key is NEVER read from this tree. It is supplied
# for this run only, either as --key <path> or via RELEASE_SIGNING_KEY. In CI that is an
# environment secret available only to approved release jobs. This script refuses without
# it, and it writes only the public signature — never the key — into the manifest.
#
# Usage:
#   sign-release.sh --component git-rpc --version 0.1.0 \
#     --oci-ref registry.gitsaas.example/gitsaas/git-rpc --digest sha256:<hex> \
#     [--key /path/to/private.pem] [--out deploy/releases/git-rpc-0.1.0.release]
#
# Exit: 0 signed · 1 refusal (missing key/inputs, openssl failure) · 3 usage error.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

component=""; version=""; oci_ref=""; digest=""
key="${RELEASE_SIGNING_KEY:-}"
out=""

while [ $# -gt 0 ]; do
  case "$1" in
    --component) component="${2:-}"; shift 2 ;;
    --version)   version="${2:-}";   shift 2 ;;
    --oci-ref)   oci_ref="${2:-}";   shift 2 ;;
    --digest)    digest="${2:-}";    shift 2 ;;
    --key)       key="${2:-}";       shift 2 ;;
    --out)       out="${2:-}";       shift 2 ;;
    *) echo "sign-release: unknown argument: $1" >&2; exit 3 ;;
  esac
done

for pair in "component:$component" "version:$version" "oci-ref:$oci_ref" "digest:$digest"; do
  name=${pair%%:*}; val=${pair#*:}
  if [ -z "$val" ]; then
    echo "sign-release: --$name is required" >&2
    exit 3
  fi
done

if [ -z "$key" ]; then
  echo "sign-release: no private key — pass --key <path> or set RELEASE_SIGNING_KEY." >&2
  echo "              ADR-0044: the key is a CI secret; it is never read from this tree." >&2
  exit 1
fi
if [ ! -f "$key" ]; then
  echo "sign-release: private key not found: $key" >&2
  exit 1
fi

command -v openssl >/dev/null 2>&1 || { echo "sign-release: openssl is required" >&2; exit 1; }

# The identity the signature covers. Written to a temp file because openssl signs bytes,
# and we must sign exactly `oci_ref@digest` with no trailing-newline ambiguity.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/sign-release.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
identity="$tmp/identity"
sig="$tmp/sig.der"
printf '%s' "${oci_ref}@${digest}" > "$identity"

if ! openssl dgst -sha256 -sign "$key" -out "$sig" "$identity" 2> "$tmp/err"; then
  echo "sign-release: openssl failed to sign:" >&2
  sed 's/^/  /' "$tmp/err" >&2
  exit 1
fi

# Single-line base64 regardless of the platform's default wrap (openssl -A is portable).
signature="$(openssl base64 -A -in "$sig")"
if [ -z "$signature" ]; then
  echo "sign-release: produced an empty signature" >&2
  exit 1
fi

if [ -z "$out" ]; then
  out="$root/deploy/releases/${component}-${version}.release"
fi

{
  echo "component=$component"
  echo "version=$version"
  echo "oci_ref=$oci_ref"
  echo "digest=$digest"
  echo "signature=$signature"
} > "$out"

echo "sign-release: signed $component@$version -> $out"
echo "sign-release: identity ${oci_ref}@${digest}"
