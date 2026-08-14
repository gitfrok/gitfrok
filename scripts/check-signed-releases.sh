#!/usr/bin/env bash
# T-0032 / SPEC-0039 AC3 — the super-repo half of "signed before applied".
#
# The control plane refuses an unsigned or mis-signed release before it reconciles it
# (backend modules/rollout). This gate is the same assertion over THIS tree: every release
# manifest in deploy/releases/ must be verifiable against the release-signing trust bundle,
# or it is not applicable. An unsigned, malformed, or mis-signed release fails the build —
# there is no "unsigned release" that could ever reach desired state.
#
# Two parts:
#   1. Trust bundle integrity (ADR-0044): every *.pub is a PEM public key and its SHA-256
#      fingerprint is recorded in the bundle README. This gate never reads private material.
#   2. Per-release verification: a signature covers `oci_ref@digest` (the exact string the
#      backend verifier hashes), ECDSA over SHA-256. Each release must verify against at
#      least one bundle key. Missing field = malformed; empty signature = unsigned; no key
#      verifies = mis-signed. All three are refusals.
#
# Exit: 0 clean · 1 violation · 3 environment problem (bundle or openssl absent).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
trust="$root/deploy/releases/trust"
releases="$root/deploy/releases"

command -v openssl >/dev/null 2>&1 || { echo "signed-releases: openssl is required" >&2; exit 3; }

fail=0
report() { echo "SIGNED-RELEASE VIOLATION: $1"; fail=1; }

# --- 1. trust bundle integrity ---------------------------------------------------------------
readme="$trust/README.md"
if [ ! -f "$readme" ]; then
  echo "signed-releases: FAIL — $readme is missing" >&2
  exit 3
fi
keys=("$trust"/*.pub)
if [ ! -e "${keys[0]}" ]; then
  echo "signed-releases: FAIL — no public verification key in $trust" >&2
  exit 3
fi
for key in "${keys[@]}"; do
  if ! openssl pkey -pubin -in "$key" -noout 2>/dev/null; then
    report "$key is not a PEM public key"
    continue
  fi
  # sha256sum is GNU-only (SPEC-0014); openssl dgst has the same stable hex output on both lanes.
  fingerprint=$(openssl dgst -sha256 "$key" | sed 's/^.*= //')
  if ! grep -Fq "$fingerprint" "$readme"; then
    report "$key fingerprint ($fingerprint) is not recorded in $readme"
  fi
done

# --- 2. every release manifest must verify ---------------------------------------------------
tmp="$(mktemp -d "${TMPDIR:-/tmp}/signed-releases.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Read a manifest field value: first matching `key=` line, trimmed.
field() { # field <file> <key>
  sed -n "s/^$2=//p" "$1" | head -1
}

count=0
manifests=("$releases"/*.release)
if [ -e "${manifests[0]}" ]; then
  for rel in "${manifests[@]}"; do
    count=$((count + 1))
    name=${rel##*/}
    component=$(field "$rel" component)
    version=$(field "$rel" version)
    oci_ref=$(field "$rel" oci_ref)
    digest=$(field "$rel" digest)
    signature=$(field "$rel" signature)

    # Malformed: any identity field absent. A release that does not say what it is cannot
    # be applied.
    for pair in "component:$component" "version:$version" "oci_ref:$oci_ref" "digest:$digest"; do
      fname=${pair%%:*}; fval=${pair#*:}
      if [ -z "$fval" ]; then
        report "$name is malformed — missing $fname"
      fi
    done
    if [ -z "$component" ] || [ -z "$version" ] || [ -z "$oci_ref" ] || [ -z "$digest" ]; then
      continue
    fi

    # Unsigned: an empty signature is the exact refusal the control plane audits.
    if [ -z "$signature" ]; then
      report "$name is UNSIGNED — no unsigned release is applicable (SPEC-0039 AC3)"
      continue
    fi

    # Reconstruct the signed identity and verify against each bundle key; one hit passes.
    printf '%s' "${oci_ref}@${digest}" > "$tmp/identity"
    if ! printf '%s' "$signature" | openssl base64 -d -A -out "$tmp/sig.der" 2>/dev/null; then
      report "$name signature is not valid base64 — mis-signed"
      continue
    fi
    verified=0
    for key in "${keys[@]}"; do
      if openssl dgst -sha256 -verify "$key" -signature "$tmp/sig.der" "$tmp/identity" >/dev/null 2>&1; then
        verified=1
        break
      fi
    done
    if [ "$verified" -eq 0 ]; then
      report "$name is MIS-SIGNED — no key in the trust bundle verifies ${oci_ref}@${digest}"
    else
      echo "  ok    $name ($component@$version)"
    fi
  done
fi

if [ "$count" -eq 0 ]; then
  echo "signed-releases: no release manifests in deploy/releases/ — nothing to verify (bundle checked)"
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "signed-releases: an unsigned/mis-signed release is applicable — SPEC-0039 AC3, T-0032."
  exit 1
fi
echo "signed-releases: OK — bundle intact, $count release(s) verified against the trust bundle"
