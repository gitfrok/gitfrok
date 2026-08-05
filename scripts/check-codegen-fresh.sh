#!/usr/bin/env bash
# Super-repo fitness function: every consumer's generated tree matches the contracts it is pinned to.
#
# WHY THIS LIVES HERE and not in each consumer's own CI: backend/, bff/ and webfrontend/ each have a
# buf.gen.yaml whose input is `../governance/contracts` — a sibling checkout that exists only in this
# composition. A standalone CI run in those repos has no contracts to generate from; webfrontend's
# workflow already records that finding in a comment. Publishing generated types per repo is the open
# ADR-0027/0028 follow-up, and until it is decided the composition boundary is the only place this
# check can be honest rather than skipped. T-0020 AC5, ADR-0032.
#
# What drift means: a consumer's gen/ no longer follows from the contracts its pin points at. Either
# someone hand-edited generated code (contracts/README.md: "never hand-edit"), or a contracts change
# merged without the consumer regenerating. Both make the one-way dependency a lie — the consumer is
# no longer a function of the Source of Truth.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
report() { echo "CODEGEN VIOLATION: $1"; fail=1; }

# backend and bff generate Go; webfrontend generates TS with a plugin from its own node_modules.
missing=()
command -v buf >/dev/null || missing+=("buf")
command -v protoc-gen-go >/dev/null || missing+=("protoc-gen-go")
command -v protoc-gen-go-grpc >/dev/null || missing+=("protoc-gen-go-grpc")
[ -x webfrontend/node_modules/.bin/protoc-gen-es ] || missing+=("webfrontend/node_modules (npm ci)")
if [ ${#missing[@]} -ne 0 ]; then
  echo "cannot check codegen freshness, missing: ${missing[*]}"
  echo "This is a hard failure, not a skip: a codegen gate that quietly does nothing is worse than"
  echo "no gate, because the green check is then evidence of something that was never verified."
  exit 1
fi

# repo:generated-path
CONSUMERS=(
  "backend:gen"
  "bff:gen"
  "webfrontend:src/gen"
)

for entry in "${CONSUMERS[@]}"; do
  repo=${entry%%:*}
  gen=${entry#*:}

  # A dirty tree before generating would be indistinguishable from drift afterwards.
  if [ -n "$(git -C "$repo" status --porcelain -- "$gen")" ]; then
    report "$repo/$gen is already dirty before generating — commit or stash it first"
    continue
  fi

  # webfrontend's protoc-gen-es lives in its node_modules, so put that on PATH for its run only.
  if ! out=$(cd "$repo" && PATH="$PWD/node_modules/.bin:$PATH" buf generate 2>&1); then
    report "buf generate failed in $repo:"
    while IFS= read -r line; do printf '          %s\n' "$line"; done <<<"$out"
    continue
  fi

  drift=$(git -C "$repo" status --porcelain -- "$gen")
  if [ -n "$drift" ]; then
    report "$repo/$gen does not match the pinned contracts:"
    while IFS= read -r line; do printf '          %s\n' "$line"; done <<<"$drift"
    echo "          fix: run 'make codegen' and commit the result in $repo"
    # Leave the tree as it was, so a local run is a diagnosis and not an edit. Regeneration only
    # ever rewrites files under $gen, so restoring that path is enough.
    git -C "$repo" checkout -- "$gen" 2>/dev/null || true
    git -C "$repo" clean -qfd -- "$gen" 2>/dev/null || true
  else
    echo "  ok    $repo/$gen matches contracts/"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "codegen: DRIFT (see above) — T-0020, ADR-0032"
  exit 1
fi
echo "codegen: OK"
