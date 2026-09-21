#!/usr/bin/env sh
# SPEC-0069 AC11 / T-0086: check-platform-kustomize.sh is FAILABLE.
#
# Each fixture introduces exactly one defect ADR-0099 decided against, and must be refused. The
# shipped overlays must pass. Both halves matter: a gate that fails on everything is as useless as
# one that fails on nothing — and this gate's first version failed on its own comments twice.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
gate="$root/scripts/check-platform-kustomize.sh"
fx="$root/scripts/testdata/platform"

fail=0
pass=0
expect_refusal() {
  if PLATFORM_OVERLAYS="$fx/$1" "$gate" >/dev/null 2>&1; then
    echo "TEST VIOLATION: fixture '$1' was ACCEPTED — the gate does not catch: $2"
    fail=1
  else
    echo "  ok    refused $1 ($2)"
    pass=$((pass + 1))
  fi
}

echo "check-platform-kustomize.sh: negative fixtures"
expect_refusal deployment-with-pvc "AC2 — a Deployment carrying a PVC, the shape that cannot roll"
expect_refusal scaled-down         "AC3 — Redpanda scaled to 1, where one broker cannot replicate"
expect_refusal secret-generator    "AC4 — a secretGenerator authoring the Postgres superuser"
expect_refusal literal-credential  "AC4 — Zitadel's masterkey as a literal"
expect_refusal loadbalancer        "AC5 — a LoadBalancer on the bus"
expect_refusal no-backup           "AC9 — a CNPG Cluster with its backup stanza removed"
expect_refusal loopback-http       "AC8 — dev's plain-http custody relaxation travelling to production"

echo "check-platform-kustomize.sh: the shipped overlays"
if "$gate" >/dev/null 2>&1; then
  echo "  ok    accepted prod-cp and prod-dp"
  pass=$((pass + 1))
else
  echo "TEST VIOLATION: the shipped overlays are REFUSED by their own gate"
  "$gate" 2>&1 | sed 's/^/    /'
  fail=1
fi

[ "$fail" -eq 0 ] || { echo "platform-test: FAIL"; exit 1; }
echo "platform-test: OK — $pass assertions proven failable and the real tree accepted"
