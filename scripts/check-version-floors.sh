#!/usr/bin/env bash
# Super-repo fitness function: toolchain floors hold across the composition (ADR-0023).
# Go 1.26 (backend, bff), Node >=26 (webfrontend). Guards against a submodule silently
# dropping below the pinned floor. T-0001 wires this; CI runs it on the super-repo.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
report() { echo "VERSION-FLOOR VIOLATION: $1"; fail=1; }

GO_FLOOR="1.26"
NODE_FLOOR="26"

check_go_mod() { # check_go_mod <path>
  local mod="$1"
  [ -f "$mod" ] || return 0
  local v
  v=$(awk '/^go [0-9]/ {print $2; exit}' "$mod")
  case "$v" in
    "$GO_FLOOR"|"$GO_FLOOR".*) : ;;
    *) report "$mod declares go $v, floor is $GO_FLOOR" ;;
  esac
}

check_go_mod backend/go.mod
check_go_mod bff/go.mod

# webfrontend engines.node must require >=26.
if [ -f webfrontend/package.json ]; then
  if ! grep -qE '"node"[[:space:]]*:[[:space:]]*">=?[[:space:]]*'"$NODE_FLOOR" webfrontend/package.json; then
    report "webfrontend/package.json engines.node does not pin >= $NODE_FLOOR"
  fi
fi

if [ "$fail" -ne 0 ]; then echo "version-floors: FAIL"; exit 1; fi
echo "version-floors: OK"
