#!/usr/bin/env sh
# SPEC-0067 AC10 / T-0084: check-controlplane-kustomize.sh is FAILABLE.
#
# A gate that has never failed is a gate nobody has tested. Each fixture below introduces exactly
# one defect and must be refused; the shipped overlay must pass. Both halves matter — a gate that
# fails on everything is as useless as one that fails on nothing.
#
# Exit: 0 all fixtures behaved · 1 a fixture was accepted or the real tree was refused

set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
gate="$root/scripts/check-controlplane-kustomize.sh"
fx="$root/scripts/testdata/cp-kustomize"

fail=0
pass=0

expect_refusal() {
  name=$1
  why=$2
  if CP_OVERLAY="$fx/$name" "$gate" >/dev/null 2>&1; then
    echo "TEST VIOLATION: fixture '$name' was ACCEPTED — the gate does not catch: $why"
    fail=1
  else
    echo "  ok    refused $name ($why)"
    pass=$((pass + 1))
  fi
}

# A gate that refuses everything is as broken as one that refuses nothing, and the custody-CA rule
# is conditional — it must fire on an https address and stay silent on loopback http. That second
# half needs a fixture the gate ACCEPTS, so it gets its own helper rather than being left untested.
expect_acceptance() {
  name=$1
  why=$2
  if CP_OVERLAY="$fx/$name" "$gate" >/dev/null 2>&1; then
    echo "  ok    accepted $name ($why)"
    pass=$((pass + 1))
  else
    echo "TEST VIOLATION: fixture '$name' was REFUSED — the gate over-fires on: $why"
    CP_OVERLAY="$fx/$name" "$gate" 2>&1 | sed 's/^/    /'
    fail=1
  fi
}

echo "check-controlplane-kustomize.sh: negative fixtures"
expect_refusal secret-generator   "AC3 — a secretGenerator in a kustomization"
expect_refusal authored-secret    "AC3 — a Secret authored by the tree"
expect_refusal l7-on-agent-door   "AC6 — an HTTPRoute routing to the agent door"
expect_refusal ephemeral-address  "AC8 — the agent door taking an ephemeral address"
expect_refusal literal-credential "AC4 — a database URL as a literal"
expect_refusal fourth-workload    "AC1/AC2 — a fourth, third-party workload"
expect_refusal no-acme-listener   "AC7 — the Gateway losing its :80 ACME listener"
expect_refusal wrong-address-name "AC8 — a reserved-address name the tofu unit does not reserve"
expect_refusal reader-on-control  "AC10 — a reader address on the control plane, which the binary refuses at boot"
expect_refusal https-no-ca-mount/prod-cp "SPEC-0071 AC11 — an https custody address with no CA mounted"
expect_refusal https-no-ca-env/prod-cp "SPEC-0071 AC11 — a mounted CA that nothing tells the binary to read"
expect_refusal custody-ca-from-tls-secret/prod-cp "SPEC-0071 AC10 — the CA taken from openbao-tls, which holds the server's private key"

echo "check-controlplane-kustomize.sh: positive fixtures (the gate must NOT over-fire)"
expect_acceptance loopback-http-no-ca/prod-cp "SPEC-0071 AC11 — loopback http needs no CA, and dev must stay gateable"

echo "check-controlplane-kustomize.sh: the shipped overlay"
if "$gate" >/dev/null 2>&1; then
  echo "  ok    accepted deploy/k8s/controlplane/overlays/prod-cp"
  pass=$((pass + 1))
else
  echo "TEST VIOLATION: the shipped overlay is REFUSED by its own gate"
  "$gate" 2>&1 | sed 's/^/    /'
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "cp-kustomize-test: FAIL"
  exit 1
fi
echo "cp-kustomize-test: OK — $pass assertions proven failable and the real tree accepted"
