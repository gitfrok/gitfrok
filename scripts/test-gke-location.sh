#!/usr/bin/env sh
# SPEC-0072 AC4/AC5 / T-0091: check-gke-location.sh is FAILABLE, and for the right reasons.
#
# This harness reads the VIOLATION TEXT, not the exit status, and that is the whole point of it.
# T-0090's exit record is the precedent: three fixtures there were refused by an unrelated rule
# firing on their own directory name, `expect_refusal` read only `$?`, and they looked like proof
# for a day. A fixture whose refusal cannot be attributed to the assertion under test is not
# evidence — so every refusal below names the substring that must appear.
#
# The acceptance cases are not decoration either. A gate that refuses everything satisfies every
# negative fixture ever written, and `regional` is the one that matters most: it is what forbids
# the cheapest implementation of AC1 (grep for the shipped zone), which would pass every refusal
# here and then refuse ADR-0106 decision 2's own reversal path.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
gate="$root/scripts/check-gke-location.sh"
fx="$root/scripts/testdata/gke-location"

fail=0
pass=0

# expect_refusal <fixture> <substring the violation must contain> <what it proves>
expect_refusal() {
  out=$(GKE_LIVE_DIR="$fx/$1" "$gate" 2>&1) && {
    echo "TEST VIOLATION: fixture '$1' was ACCEPTED — the gate does not catch: $3"
    fail=1
    return
  }
  case "$out" in
    *"$2"*)
      echo "  ok    refused $1 ($3)"
      pass=$((pass + 1))
      ;;
    *)
      echo "TEST VIOLATION: fixture '$1' was refused, but NOT for its own reason."
      echo "  expected the violation to mention: $2"
      echo "  got:"
      echo "$out" | sed 's/^/    /'
      fail=1
      ;;
  esac
}

# expect_acceptance <fixture> <what it proves>
expect_acceptance() {
  if out=$(GKE_LIVE_DIR="$fx/$1" "$gate" 2>&1); then
    echo "  ok    accepted $1 ($2)"
    pass=$((pass + 1))
  else
    echo "TEST VIOLATION: fixture '$1' was REFUSED — the gate over-fires on: $2"
    echo "$out" | sed 's/^/    /'
    fail=1
  fi
}

echo "check-gke-location.sh: negative fixtures"
expect_refusal missing-location    "prod-cp/gke" "AC1 — no location input at all"
expect_refusal commented-location  "prod-cp/gke" "AC3 — location present but commented out"
expect_refusal nested-only         "prod-cp/gke" "AC1 — location only inside a nested input"

echo "check-gke-location.sh: positive fixtures — the gate asserts EXPLICITNESS, never a value"
expect_acceptance zonal    "AC2 — an explicit zone"
expect_acceptance regional "AC2 — an explicit REGION, equally a decision"

echo "check-gke-location.sh: the shipped units"
if out=$("$gate" 2>&1); then
  echo "  ok    accepted the live prod-cp and prod-dp gke units"
  pass=$((pass + 1))
else
  echo "TEST VIOLATION: the shipped units are REFUSED by their own gate"
  echo "$out" | sed 's/^/    /'
  fail=1
fi

[ "$fail" -eq 0 ] || { echo "gke-location-test: FAIL"; exit 1; }
echo "gke-location-test: OK — $pass assertions proven failable and the real tree accepted"
