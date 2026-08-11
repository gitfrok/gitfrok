#!/usr/bin/env bash
# Super-repo operational gate: apply the ADR-0031 merge-enforcement rulesets to every repo.
#
# INERT SINCE 2026-08-12 (ADR-0053). These repos are private on a plan that gives a private repo
# neither rulesets nor branch protection, so every mode below reports UNAVAILABLE and exits 0. Work
# lands directly on the default branch and CI on push is the only gate. Everything after that probe
# is preserved for the day the repos go public or the org buys Team.
#
# ADR-0031 splits `main` protection into two rulesets so admin bypass covers the human gate and
# never the machine gate:
#   main-integrity — PR required (0 approvals), required status checks, no force-push, no deletion,
#                    conversation resolution.  bypass_actors: NONE.  This is T-0002 AC5.
#   main-review    — 1 approving review + stale dismissal.  bypass_actors: NONE since 2026-08-04,
#                    when a second org member joined. It was admin-bypassable until then only
#                    because GitHub forbids self-approval and a one-member org would have been
#                    unable to merge at all.
#
# Legacy branch protection is DELETED, not left alongside: overlapping rules are evaluated as a
# union and the loosest bypass wins, which is confusing exactly where it matters most.
#
# Org-level rulesets need GitHub Team, so these are per-repo copies — which is why this is a script
# and not five trips through the UI. Not run in CI: it needs an admin token, and super-repo CI has
# `contents: read`. `check` mode is the seed of the ADR-0031 follow-up gate that guards the gates.
#
# Usage: apply-rulesets.sh [plan|apply|check]     (default: plan — reads nothing but the API)
set -euo pipefail
cd "$(dirname "$0")/.."

ORG=gitfrok
MODE=${1:-plan}

# repo:required-status-check-context. Every repo now has one: webfrontend's landed 2026-08-05
# (build/typecheck/vitest/boundaries), closing the last "runs but nothing to require" gap ADR-0031
# recorded. An empty context is still handled — a repo is not exempt from the mechanism because its
# check list is empty — it just no longer occurs.
#
# governance's docs gate (T-0009) runs today but was never a required check, so a broken link in the
# SoT repo could merge. ADR-0031 lists wiring it as a follow-up; it is included here because the
# ruleset is being created anyway and leaving it out would mean editing the same rule twice.
#
# A repo may require MORE THAN ONE context, separated by `|`. That became necessary with SPEC-0014:
# the macOS portability lane cannot be a step inside an existing job, because a job runs on one OS,
# so it is a second job and therefore a second context. Until it is listed here it runs and reports
# without blocking anything, which is the state every macOS lane is in until `apply` is next run.
REPOS=(
  "gitfrok:super-repo fitness gates|macOS portability"
  "backend:build + vet + arch gates|macOS portability"
  "bff:build + vet + arch gates|macOS portability"
  "governance:docs gates|macOS portability"
  "webfrontend:build + typecheck + test + arch gates|macOS portability"
)

# contexts_of <ctx-spec> — one context per line. `|` is the separator because every context here
# contains spaces and several contain `+`, and a newline-delimited list is what jq wants anyway.
contexts_of() {
  printf '%s\n' "$1" | tr '|' '\n' | sed '/^$/d'
}

for cmd in gh jq; do
  command -v "$cmd" >/dev/null || { echo "$cmd not installed"; exit 1; }
done

case "$MODE" in
  plan|apply|check) ;;
  *) echo "usage: $0 [plan|apply|check]"; exit 2 ;;
esac

# ADR-0053: the repos are private, and this plan gives a private repo neither rulesets nor branch
# protection — every rulesets call answers 403 "Upgrade to GitHub Pro or make this repository public".
#
# Reporting that as drift would be a lie in the other direction: nothing has drifted, the mechanism is
# simply unavailable. So say which it is and stop, with 0 — a missing capability is not a failing gate,
# and a red exit here would make `make rulesets-check` permanently broken rather than honestly inert.
#
# The rest of this script is kept intact deliberately. The day these repos go public, or the org buys
# Team, restoring ADR-0031's enforcement is one `apply` away instead of an archaeology exercise.
probe=$(gh api "/repos/$ORG/gitfrok/rulesets" 2>&1 || true)
case "$probe" in
  *"Upgrade to GitHub Pro"*)
    echo "rulesets: UNAVAILABLE — $ORG's repos are private on a plan without rulesets or branch"
    echo "  protection (GitHub answers 403 on both). ADR-0031's enforcement cannot be applied or"
    echo "  verified here; ADR-0053 supersedes it: work lands on the default branch and CI on push is"
    echo "  the gate. This script stays ready for a public repo or a paid plan."
    exit 0
    ;;
esac

fail=0
report() { echo "  FAIL: $1"; fail=1; }

# Conditions target the default branch by name rather than a literal "main" so a repo that renames
# its default branch stays covered.
conditions='{ "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } }'

integrity_body() { # integrity_body <required-check-context-spec>
  local ctx="$1" checks='[]'
  if [ -n "$ctx" ]; then
    checks=$(contexts_of "$ctx" | jq -Rnc '[inputs | {context: .}]')
  fi
  jq -nc --argjson conditions "$conditions" --argjson checks "$checks" '
    {
      name: "main-integrity",
      target: "branch",
      enforcement: "active",
      bypass_actors: [],
      conditions: $conditions,
      rules: (
        [
          # 0 approvals: AC5 is about checks blocking, not about review. The review requirement is
          # main-review'\''s job, because that is the half a one-member org cannot satisfy.
          { type: "pull_request", parameters: {
              required_approving_review_count: 0,
              dismiss_stale_reviews_on_push: false,
              require_code_owner_review: false,
              require_last_push_approval: false,
              required_review_thread_resolution: true } },
          { type: "non_fast_forward" },
          { type: "deletion" }
        ]
        + (if ($checks | length) > 0 then
            [ { type: "required_status_checks", parameters: {
                  # Not strict: requiring every branch to be up to date with main forces a rebase
                  # per merge, which buys little on a tree this small.
                  strict_required_status_checks_policy: false,
                  do_not_enforce_on_create: false,
                  required_status_checks: $checks } } ]
          else [] end)
      )
    }'
}

review_body() {
  jq -nc --argjson conditions "$conditions" '
    {
      name: "main-review",
      target: "branch",
      enforcement: "active",
      # No bypass. The admin exemption here was time-boxed by a condition, not a date — a second org
      # member who can approve — and that condition was met on 2026-08-04 when webenable-asia joined.
      # GitHub forbids self-approval at every role, so four-eyes review on main is now real for
      # everyone including owners (ADR-0031 follow-up, closed).
      bypass_actors: [],
      conditions: $conditions,
      rules: [
        { type: "pull_request", parameters: {
            required_approving_review_count: 1,
            dismiss_stale_reviews_on_push: true,
            require_code_owner_review: false,
            require_last_push_approval: false,
            required_review_thread_resolution: false } }
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

drop_legacy() { # drop_legacy <repo> <default-branch>
  local repo="$1" branch="$2"
  if gh api "/repos/$ORG/$repo/branches/$branch/protection" >/dev/null 2>&1; then
    gh api -X DELETE "/repos/$ORG/$repo/branches/$branch/protection" >/dev/null
    echo "  legacy branch protection on $branch: deleted"
  else
    echo "  legacy branch protection on $branch: none"
  fi
}

check_repo() { # check_repo <repo> <expected-check-context> <default-branch>
  local repo="$1" ctx="$2" branch="$3" id rs types bypass got

  id=$(ruleset_id "$repo" "main-integrity")
  if [ -z "$id" ]; then
    report "main-integrity missing"
  else
    rs=$(gh api "/repos/$ORG/$repo/rulesets/$id")
    [ "$(jq -r '.enforcement' <<<"$rs")" = "active" ] || report "main-integrity not active"

    # The rule this whole ADR exists for: no bypass on the machine gate, ever.
    bypass=$(jq -r '.bypass_actors | length' <<<"$rs")
    [ "$bypass" = "0" ] || report "main-integrity has $bypass bypass actor(s) — AC5 is re-opened"

    types=$(jq -r '[.rules[].type] | sort | join(",")' <<<"$rs")
    for t in deletion non_fast_forward pull_request; do
      [[ ",$types," == *",$t,"* ]] || report "main-integrity missing rule $t"
    done

    # Sorted on both sides: the API returns contexts in whatever order they were written, and a
    # ruleset that requires the right two checks in the other order is not drift.
    got=$(jq -r '[.rules[] | select(.type == "required_status_checks")
                 | .parameters.required_status_checks[].context] | sort | join(", ")' <<<"$rs")
    want=$(contexts_of "$ctx" | sort | paste -sd, - | sed 's/,/, /g')
    [ "$got" = "$want" ] || report "main-integrity required checks are [$got], expected [$want]"
  fi

  id=$(ruleset_id "$repo" "main-review")
  if [ -z "$id" ]; then
    report "main-review missing"
  else
    rs=$(gh api "/repos/$ORG/$repo/rulesets/$id")
    [ "$(jq -r '.enforcement' <<<"$rs")" = "active" ] || report "main-review not active"

    # Since the org has a second member, the review gate is bound too — including for owners. A
    # bypass reappearing here is someone quietly opting out of four-eyes review.
    bypass=$(jq -r '.bypass_actors | length' <<<"$rs")
    [ "$bypass" = "0" ] || report "main-review has $bypass bypass actor(s) — four-eyes review is optional again"

    got=$(jq -r '[.rules[] | select(.type == "pull_request")
                 | .parameters.required_approving_review_count] | join(",")' <<<"$rs")
    [ "$got" = "1" ] || report "main-review required approvals are [$got], expected [1]"
  fi

  if gh api "/repos/$ORG/$repo/branches/$branch/protection" >/dev/null 2>&1; then
    report "legacy branch protection still present on $branch — its bypass unions with the rulesets"
  fi
}

echo "ADR-0031 rulesets — mode: $MODE"
for entry in "${REPOS[@]}"; do
  repo=${entry%%:*}
  ctx=${entry#*:}
  branch=$(gh api "/repos/$ORG/$repo" --jq '.default_branch')
  echo "$ORG/$repo ($branch):"

  case "$MODE" in
    plan)
      echo "  main-integrity: bypass none; PR+0 approvals, no force-push, no deletion, threads resolved"
      if [ -n "$ctx" ]; then
        contexts_of "$ctx" | sed 's/^/                  required check: /'
      else
        echo "                  required check: none (no workflow in this repo yet)"
      fi
      echo "  main-review:    bypass none; 1 approval, dismiss stale"
      echo "  legacy branch protection on $branch: would be deleted"
      ;;
    apply)
      # Rulesets first, legacy protection second — never a window with main unprotected.
      upsert "$repo" "main-integrity" "$(integrity_body "$ctx")"
      upsert "$repo" "main-review" "$(review_body)"
      drop_legacy "$repo" "$branch"
      ;;
    check)
      check_repo "$repo" "$ctx" "$branch"
      ;;
  esac
done

if [ "$fail" -ne 0 ]; then
  echo "rulesets: DRIFT (see FAIL above) — ADR-0031"
  exit 1
fi
echo "rulesets: OK ($MODE)"
