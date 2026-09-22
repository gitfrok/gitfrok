#!/usr/bin/env sh
# SPEC-0069 AC11 / T-0086: check-platform-kustomize.sh is FAILABLE, and for the right reasons.
#
# Each fixture introduces exactly one defect ADR-0099 decided against, and must be refused. The
# shipped overlays must pass. Both halves matter: a gate that fails on everything is as useless as
# one that fails on nothing — and this gate's first version failed on its own comments twice.
#
# THIS HARNESS READS THE VIOLATION TEXT, NOT THE EXIT STATUS, and that is a repair rather than a
# refinement. Until 2026-09-22 it read only `$?`, and under that assertion ALL SEVEN fixtures
# passed while proving nothing: each carried `../../../deploy/...` in its kustomization, which
# resolves to `scripts/deploy` and does not exist, so not one of them had ever RENDERED. Every
# refusal was "does not render" plus two unrelated AC7 violations about OpenBao's quorum. The suite
# was green, the exit codes were non-zero, and no assertion in it was being exercised.
#
# So every refusal below now states two things:
#   - the SUBSTRING the violation must contain, so a fixture cannot pass on somebody else's failure
#   - the AC it belongs to, and NO violation outside that AC may appear, so a fixture cannot pass
#     while dragging unrelated breakage along with it — which is exactly how the render failure hid
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
gate="$root/scripts/check-platform-kustomize.sh"
fx="$root/scripts/testdata/platform"

fail=0
pass=0

# expect_refusal <fixture> <AC code> <substring the violation must contain> <what it proves>
expect_refusal() {
  fixture=$1
  ac=$2
  needle=$3
  what=$4

  if out=$(PLATFORM_OVERLAYS="$fx/$fixture" "$gate" 2>&1); then
    echo "TEST VIOLATION: fixture '$fixture' was ACCEPTED — the gate does not catch: $what"
    fail=1
    return
  fi

  case "$out" in
    *"$needle"*) ;;
    *)
      echo "TEST VIOLATION: fixture '$fixture' was refused, but NOT for its own reason."
      echo "  expected a violation containing: $needle"
      echo "$out" | grep -i 'VIOLATION' | sed 's/^/    /'
      fail=1
      return
      ;;
  esac

  # Nothing outside the named AC may fire. This is the assertion that would have caught the broken
  # fixture paths on day one: "does not render" and two AC7 violations are not $ac.
  stray=$(echo "$out" | grep 'PLATFORM VIOLATION:' | grep -v "$ac" || true)
  if [ -n "$stray" ]; then
    echo "TEST VIOLATION: fixture '$fixture' also failed for reasons that are not $ac:"
    echo "$stray" | sed 's/^/    /'
    echo "  a fixture that drags unrelated breakage along is not evidence for $ac"
    fail=1
    return
  fi

  echo "  ok    refused $fixture ($what)"
  pass=$((pass + 1))
}

echo "check-platform-kustomize.sh: negative fixtures"
expect_refusal deployment-with-pvc AC2 \
  "Deployment/valkey-legacy carries a persistentVolumeClaim" \
  "AC2 — a Deployment carrying a PVC, the shape that cannot roll"
expect_refusal scaled-down AC3 \
  "StatefulSet/redpanda has 1" \
  "AC3 — Redpanda scaled to 1, where one broker cannot replicate"
expect_refusal secret-generator AC4 \
  "declares secretGenerator" \
  "AC4 — a secretGenerator authoring the Postgres superuser"
expect_refusal literal-credential AC4 \
  "ZITADEL_MASTERKEY is a LITERAL credential" \
  "AC4 — Zitadel's masterkey as a literal"
expect_refusal loadbalancer AC5 \
  "Service/redpanda is LoadBalancer" \
  "AC5 — a LoadBalancer on the bus"
expect_refusal no-backup AC9 \
  "Cluster/postgres declares no backup" \
  "AC9 — a CNPG Cluster with its backup stanza removed"
expect_refusal loopback-http AC8 \
  "sets GITFROK_CUSTODY_ALLOW_LOOPBACK_HTTP" \
  "AC8 — dev's plain-http custody relaxation travelling to production"

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
