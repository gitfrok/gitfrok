#!/usr/bin/env bash
# Super-repo operational gate: hold the ADR-0054 `main-guard` ruleset on every repo.
#
# ADR-0054 keeps ADR-0053's working mode — work lands directly on `main`, CI on push is the gate — and
# restores the two protections that cost nothing to keep: `main` cannot be force-pushed and cannot be
# deleted. Nothing else. In particular:
#
#   * NO pull-request requirement. That is the whole point of the mode: a push to main is the normal
#     way work lands, and a rule demanding a PR would forbid it.
#   * NO required status checks. GitHub evaluates those when a pull request merges; with direct pushes
#     allowed they would gate nothing, and listing them would imply a protection that is not there.
#     CI on push is the gate, and a red `main` is a stop-everything condition — procedure, not API.
#
# This replaces ADR-0031's `main-integrity` + `main-review` pair, which required a PR and (latterly) an
# approving review. Both are DELETED here rather than left dormant: an inactive ruleset nobody reads is
# how a tree ends up claiming a gate it does not have, which is the failure ADR-0053 was written about.
#
# Rulesets need a public repo on this plan (a private one answers 403 on every rulesets call). All five
# repos are public; if that changes, `probe` below says so and exits 0 rather than reporting drift.
#
# Not run in CI: it needs an admin token, and super-repo CI has `contents: read`.
#
# Usage: apply-rulesets.sh [plan|apply|check]     (default: plan — reads nothing but the API)
set -euo pipefail
cd "$(dirname "$0")/.."

ORG=gitfrok
MODE=${1:-plan}

REPOS=(gitfrok backend bff governance webfrontend)

# The two ADR-0031 rulesets this replaces. Named so `apply` can remove them by name and `check` can
# assert they stayed gone.
SUPERSEDED=("main-integrity" "main-review")

for cmd in gh jq; do
  command -v "$cmd" >/dev/null || { echo "$cmd not installed"; exit 1; }
done

case "$MODE" in
  plan|apply|check) ;;
  *) echo "usage: $0 [plan|apply|check]"; exit 2 ;;
esac

# A missing capability is not a failing gate. If these repos ever go private again on a plan without
# rulesets, say which it is and exit 0 — a red exit here would leave `make rulesets-check` permanently
# broken rather than honestly inert, and nothing would have drifted.
probe=$(gh api "/repos/$ORG/gitfrok/rulesets" 2>&1 || true)
case "$probe" in
  *"Upgrade to GitHub Pro"*)
    echo "rulesets: UNAVAILABLE — the repos are private on a plan without rulesets or branch"
    echo "  protection (GitHub answers 403 on both). ADR-0054's main-guard cannot be applied or"
    echo "  verified; the working mode is unchanged (ADR-0053: main-only, CI on push is the gate)."
    exit 0
    ;;
esac

fail=0
report() { echo "  FAIL: $1"; fail=1; }

# Conditions target the default branch by name rather than a literal "main", so a repo that renames its
# default branch stays covered.
conditions='{ "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } }'

guard_body() {
  jq -nc --argjson conditions "$conditions" '
    {
      name: "main-guard",
      target: "branch",
      enforcement: "active",
      # No bypass, and there is nothing here worth bypassing: neither rule obstructs ordinary work.
      # A force-push or a branch deletion is either an accident or a rewrite of shared history, and
      # both want a deliberate, visible act — turning the rule off — rather than a silent exemption.
      bypass_actors: [],
      conditions: $conditions,
      rules: [
        { type: "non_fast_forward" },
        { type: "deletion" }
      ]
    }'
}

ruleset_id() { # ruleset_id <repo> <name>
  gh api "/repos/$ORG/$1/rulesets" --jq ".[] | select(.name == \"$2\") | .id" 2>/dev/null || true
}

upsert() { # upsert <repo> <name> <body>
  local repo="$1" name="$2" body="$3" id
  id=$(ruleset_id "$repo" "$name")
  if [ -n "$id" ]; then
    printf '%s' "$body" | gh api -X PUT "/repos/$ORG/$repo/rulesets/$id" --input - >/dev/null
    echo "  $name: updated (id $id)"
  else
    printf '%s' "$body" | gh api -X POST "/repos/$ORG/$repo/rulesets" --input - >/dev/null
    echo "  $name: created"
  fi
}

drop_superseded() { # drop_superseded <repo>
  local repo="$1" name id
  for name in "${SUPERSEDED[@]}"; do
    id=$(ruleset_id "$repo" "$name")
    if [ -n "$id" ]; then
      gh api -X DELETE "/repos/$ORG/$repo/rulesets/$id" >/dev/null
      echo "  $name: deleted (ADR-0031, superseded)"
    fi
  done
}

drop_legacy() { # drop_legacy <repo> <default-branch>
  local repo="$1" branch="$2"
  if gh api "/repos/$ORG/$repo/branches/$branch/protection" >/dev/null 2>&1; then
    gh api -X DELETE "/repos/$ORG/$repo/branches/$branch/protection" >/dev/null
    echo "  legacy branch protection on $branch: deleted"
  fi
}

check_repo() { # check_repo <repo> <default-branch>
  local repo="$1" branch="$2" id rs types bypass name

  id=$(ruleset_id "$repo" "main-guard")
  if [ -z "$id" ]; then
    report "main-guard missing"
  else
    rs=$(gh api "/repos/$ORG/$repo/rulesets/$id")
    [ "$(jq -r '.enforcement' <<<"$rs")" = "active" ] || report "main-guard not active"

    bypass=$(jq -r '.bypass_actors | length' <<<"$rs")
    [ "$bypass" = "0" ] || report "main-guard has $bypass bypass actor(s)"

    types=$(jq -r '[.rules[].type] | sort | join(",")' <<<"$rs")
    for t in deletion non_fast_forward; do
      [[ ",$types," == *",$t,"* ]] || report "main-guard missing rule $t"
    done
    # A pull_request rule reappearing here is someone reinstating ADR-0031's gate without an ADR —
    # and under this mode it would block every push, so it fails loudly rather than quietly.
    #
    # `if`, not `&&`: under `set -e` a false `[[ ]] && cmd` is a failing AND-list and would exit the
    # script wherever it sits, turning "no pull_request rule" — the healthy case — into a crash.
    if [[ ",$types," == *",pull_request,"* ]]; then
      report "main-guard requires a pull request — that contradicts ADR-0053/0054"
    fi
  fi

  for name in "${SUPERSEDED[@]}"; do
    [ -z "$(ruleset_id "$repo" "$name")" ] || report "$name still present — ADR-0031 is superseded"
  done

  if gh api "/repos/$ORG/$repo/branches/$branch/protection" >/dev/null 2>&1; then
    report "legacy branch protection still present on $branch — its rules union with the ruleset"
  fi
}

echo "ADR-0054 main-guard — mode: $MODE"
for repo in "${REPOS[@]}"; do
  branch=$(gh api "/repos/$ORG/$repo" --jq '.default_branch')
  echo "$ORG/$repo ($branch):"

  case "$MODE" in
    plan)
      echo "  main-guard: bypass none; no force-push, no deletion. No PR required, no required checks."
      for name in "${SUPERSEDED[@]}"; do
        if [ -n "$(ruleset_id "$repo" "$name")" ]; then
          echo "  $name: would be deleted (superseded)"
        fi
      done
      ;;
    apply)
      upsert "$repo" "main-guard" "$(guard_body)"
      drop_superseded "$repo"
      drop_legacy "$repo" "$branch"
      ;;
    check)
      check_repo "$repo" "$branch"
      ;;
  esac
done

if [ "$fail" -ne 0 ]; then
  echo "rulesets: DRIFT (see FAIL above) — ADR-0054"
  exit 1
fi
echo "rulesets: OK ($MODE)"
