#!/usr/bin/env bash
# Super-repo fitness function: the authorization path works across the repos that make it up.
#
# WHY THIS LIVES HERE, and it is the same reason as check-codegen-fresh.sh. Three repos each own a
# piece of one decision — governance authors the Rego, backend evaluates it, bff asks over gRPC —
# and each generates its own copy of contracts/proto/policy/v1. Every one of them is green in
# isolation while the composition is broken, because no repo can see the other two. T-0005's ACs are
# satisfied by per-repo tests; this is the only check that the pieces actually meet.
#
# What it would catch that nothing else does: the two generated copies of the contract drifting out
# of wire compatibility, the PDP failing to load the *real* bundle (as opposed to each repo's
# fixtures), the bundle revision being lost somewhere along the path — which would silently disable
# cache invalidation — and a policy change that alters who is allowed what.
#
# Checks:
#   1. the composed path answers at all: bff PEP -> gRPC -> backend PDP -> governance/policies
#   2. it answers *correctly* — every case's verdict is asserted, not just that a response came back
#   3. both verdicts occur, so a PDP that allowed everything and one that denied everything each fail
#   4. the bundle revision survives the whole path and matches governance/policies/.manifest
#   5. no denied request reached the data — the guard runs before the read, not after
#
# The two harness programs are real, reviewable Go in scripts/testdata/policy-composition/. They are
# copied into a temporary package inside each repo so they build against that repo's own go.mod and
# its own generated contract, then removed. They are not committed inside backend/ or bff/ because
# they are not part of what either repo ships.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
report() { echo "COMPOSITION VIOLATION: $1"; fail=1; }

indent() {
  while IFS= read -r line; do
    printf '          %s\n' "$line"
  done <<<"$1"
}

command -v go >/dev/null || { echo "go not installed: https://go.dev/dl/"; exit 1; }

BUNDLE=governance/policies
if [ ! -f "$BUNDLE/.manifest" ]; then
  echo "no policy bundle at $BUNDLE — run 'make bootstrap' to materialise the submodules."
  echo "This is a hard failure, not a skip: a composition check that quietly does nothing is worse"
  echo "than no check, because the green tick is then evidence of something never verified."
  exit 1
fi

# Temporary package directories inside each consumer. Named so a leftover is obviously not source.
PDPD_DIR=backend/cmd/zz-policy-composition-pdpd
PEPC_DIR=bff/cmd/zz-policy-composition-pepc

for d in "$PDPD_DIR" "$PEPC_DIR"; do
  if [ -e "$d" ]; then
    echo "$d already exists — a previous run did not clean up. Remove it and re-run."
    exit 1
  fi
done

workdir=$(mktemp -d)
server_pid=""

cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
  rm -rf "$PDPD_DIR" "$PEPC_DIR" "$workdir"
}
trap cleanup EXIT

mkdir -p "$PDPD_DIR" "$PEPC_DIR"
cp scripts/testdata/policy-composition/pdpd/main.go "$PDPD_DIR/main.go"
cp scripts/testdata/policy-composition/pepc/main.go "$PEPC_DIR/main.go"

# --- build both halves, each against its own module -----------------------------------------------

if ! out=$(cd backend && go build -o "$workdir/pdpd" ./cmd/zz-policy-composition-pdpd 2>&1); then
  report "the PDP harness does not build against backend/:"
  indent "$out"
  echo "composition: FAIL — SPEC-0002, T-0005"
  exit 1
fi
if ! out=$(cd bff && go build -o "$workdir/pepc" ./cmd/zz-policy-composition-pepc 2>&1); then
  report "the PEP harness does not build against bff/:"
  indent "$out"
  echo "composition: FAIL — SPEC-0002, T-0005"
  exit 1
fi
echo "  ok    both halves build against their own go.mod and generated contract"

# --- run the composed path ------------------------------------------------------------------------

addr_file="$workdir/addr"
GITFROK_POLICY_BUNDLE_DIR="$PWD/$BUNDLE" PDP_ADDR_FILE="$addr_file" \
  "$workdir/pdpd" >"$workdir/pdpd.log" 2>&1 &
server_pid=$!

# The server writes its address once it is listening, so this waits on readiness rather than on a
# fixed sleep — the difference between a check and a flaky check.
for _ in $(seq 1 100); do
  [ -s "$addr_file" ] && break
  if ! kill -0 "$server_pid" 2>/dev/null; then
    report "the PDP exited before it could serve:"
    indent "$(cat "$workdir/pdpd.log")"
    echo "composition: FAIL — SPEC-0002, T-0005"
    exit 1
  fi
  sleep 0.1
done
if [ ! -s "$addr_file" ]; then
  report "the PDP never reported an address within 10s:"
  indent "$(cat "$workdir/pdpd.log")"
  echo "composition: FAIL — SPEC-0002, T-0005"
  exit 1
fi

if ! output=$(PDP_ADDR="$(cat "$addr_file")" "$workdir/pepc" 2>&1); then
  report "the PEP could not complete against the PDP:"
  indent "$output"
  echo "composition: FAIL — SPEC-0002, T-0005"
  exit 1
fi
echo "  ok    bff PEP reached the backend PDP over gRPC"

# --- assert every verdict --------------------------------------------------------------------------

# Asserting the specific outcomes, not merely that answers came back. A response proves the wire
# works; only the verdicts prove the policy is the one governance wrote.
while IFS=' ' read -r name want; do
  [ -n "$name" ] || continue
  got=$(awk -v n="$name" '$1=="CASE" && $2==n {print $3}' <<<"$output")
  if [ -z "$got" ]; then
    report "case $name produced no verdict"
  elif [ "$got" != "$want" ]; then
    report "case $name was $got, want $want"
  fi
done <<'CASES'
reader-in-tenant ALLOW
owner-in-tenant ALLOW
reader-other-tenant DENY
no-roles DENY
anonymous DENY
unknown-role DENY
CASES

# Both verdicts must occur. Without this the case table above could be satisfied by a policy stuck
# in one position if someone ever "fixed" a failing expectation by editing it.
if ! grep -q ' ALLOW$' <<<"$output" || ! grep -q ' DENY$' <<<"$output"; then
  report "the run produced only one kind of verdict — a PDP stuck open or shut would look like this:"
  indent "$output"
else
  echo "  ok    verdicts match the policy, in both directions"
fi

# --- the revision survives the path ------------------------------------------------------------------

want_rev=$(sed -n 's/.*"revision"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$BUNDLE/.manifest" | head -1)
got_rev=$(awk '$1=="REVISION" {print $2}' <<<"$output")
if [ -z "$got_rev" ]; then
  report "no bundle revision reached the PEP — decision caching would key on an empty string"
elif [ "$got_rev" != "$want_rev" ]; then
  report "revision at the PEP is '$got_rev', but $BUNDLE/.manifest says '$want_rev'"
else
  echo "  ok    bundle revision $got_rev survived policy -> PDP -> wire -> PEP"
fi

# --- denials never reached the data --------------------------------------------------------------------

# Two of the six cases are allowed, so exactly two reads should have happened. More would mean a
# denied request still touched the repository — the guard running after the fetch instead of before.
reads=$(awk '$1=="READS" {print $2}' <<<"$output")
if [ "$reads" != "2" ]; then
  report "the backing store was read $reads times for 2 allowed cases — a denied request reached the data"
else
  echo "  ok    denied requests never reached the data"
fi

if [ "$fail" -ne 0 ]; then
  echo "composition: FAIL (see above) — SPEC-0002, T-0005"
  exit 1
fi
echo "composition: OK"
