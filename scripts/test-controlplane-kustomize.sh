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
