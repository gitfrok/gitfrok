#!/usr/bin/env bash
# Super-repo fitness function: dependency direction is one-way (invariant 22).
#   webfrontend -> bff -> backend -> governance(contracts);  governance depends on nothing.
# No repo may import another repo's Go packages (cross-repo coupling); the only shared
# surface is governance/contracts, consumed via generated code under each repo's gen/.
# T-0002 extends this; T-0001 ships the enforceable stub. Any hit fails CI.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
report() { echo "DEP-DIRECTION VIOLATION: $1"; fail=1; }

# Grep real Go source (skip generated gen/ and vendored trees) for forbidden module imports.
#
# Match import *statements* only, not every occurrence of the module path. An import spec is a
# quoted path optionally preceded by `import` and/or an alias (`_`, `.`, or an identifier), and
# nothing else on the line. That deliberately excludes assignments, const declarations, struct
# tags and comments — a repo's own boundary checker has to name the forbidden module in a string
# constant to enforce against it, and that is not itself a dependency (T-0002).
import_re() { # import_re <module>
  printf '^[[:space:]]*(import[[:space:]]+)?([A-Za-z0-9_.]+[[:space:]]+)?"%s(/|")' "$1"
}

scan() { # scan <repo> <forbidden-module-substr...>
  local repo="$1"; shift
  [ -d "$repo" ] || return 0

  # Collect into an array over a NUL-delimited find, not a word-split string. Word splitting was
  # the SC2086 that kept shellcheck out of CI, and it was also a real bug waiting on the first
  # path containing a space.
  local files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$repo" -type f -name '*.go' \
    -not -path '*/gen/*' -not -path '*/node_modules/*' -print0 2>/dev/null)
  [ ${#files[@]} -gt 0 ] || return 0

  local m re
  for m in "$@"; do
    re=$(import_re "$m")
    # Process substitution, not a pipe: a `while` on the right of a pipe runs in a subshell, so
    # report's `fail=1` would be discarded and a violation would print without failing the gate.
    while IFS= read -r f; do
      report "$repo imports $m ($f)"
    done < <(grep -lE "$re" "${files[@]}" 2>/dev/null || true)
  done
}

# backend must not depend on downstream repos.
scan backend     github.com/gitfrok/bff github.com/gitfrok/webfrontend
# bff talks to backend over gRPC via contracts — never imports backend/webfrontend Go packages.
scan bff         github.com/gitfrok/backend github.com/gitfrok/webfrontend
# governance is the sink: no code deps on any consumer.
scan governance  github.com/gitfrok/backend github.com/gitfrok/bff github.com/gitfrok/webfrontend

# webfrontend (TS) must reach backend only through the bff.
if [ -d webfrontend/src ]; then
  if grep -Rns "gitfrok/backend" webfrontend/src >/dev/null 2>&1; then
    report "webfrontend references backend directly (must go through bff)"
  fi
fi

if [ "$fail" -ne 0 ]; then echo "dep-direction: FAIL"; exit 1; fi
echo "dep-direction: OK"
