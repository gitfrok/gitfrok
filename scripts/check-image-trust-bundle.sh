#!/usr/bin/env bash
# Versioned, non-secret Cosign keys are the offline verification root for
# first-party dev images (ADR-0044). This fitness check fails if the bundle is
# absent or stops being a PEM public key; it never reads private key material.
set -euo pipefail
cd "$(dirname "$0")/.."

bundle=deploy/dev/trust/image-publish
readme="$bundle/README.md"

[ -f "$readme" ] || { echo "trust bundle: FAIL — $readme is missing"; exit 1; }

keys=("$bundle"/*.pub)
if [ ! -e "${keys[0]}" ]; then
  echo "trust bundle: FAIL — no public verification key in $bundle"
  exit 1
fi

for key in "${keys[@]}"; do
  openssl pkey -pubin -in "$key" -noout
  # `sha256sum` is not present on macOS; OpenSSL is required by the local TLS
  # bootstrap already and has the same stable hexadecimal output on both lanes.
  fingerprint=$(openssl dgst -sha256 "$key" | sed 's/^.*= //')
  grep -Fq "$fingerprint" "$readme" || {
    echo "trust bundle: FAIL — $key fingerprint is not recorded in $readme"
    exit 1
  }
  echo "  ok    $key ($fingerprint)"
done

echo "trust bundle: OK"
