#!/usr/bin/env bash
# T-0040 AC4 / SPEC-0044 AC4: the runbook's custody operations section is complete and its
# cross-references resolve — asserted, not assumed (the docs-gate check AC4's test plan
# promised "checked by the docs gate once authored").
#
# Static assertions over deploy/MVP-RUNBOOK.md, the same shape as the other gates in this
# directory (assert, don't generate):
#
#   rotation (§6b)      the §6b section exists and carries the stage → overlap → remove
#                       procedure with the removal precondition NAMED (ErrRootStillNeeded).
#   unseal (§6a)        the §6a section exists and carries the quorum-unseal procedure.
#   seal/custody outage the blast-radius entry exists on BOTH sides — §6a owns it, §6b binds
#                       to it (issuance stops; issued certificates stay valid to expiry).
#   clock skew (§4a)    the §4a entry carries the clock-skew symptom (T-0030's bound,
#                       GITFROK_AGENT_CLOCK_SKEW_LEEWAY).
#   mid-flight case     §6b carries SPEC-0042 AC6's enrolment-in-flight behaviour.
#   cross-references    every §6b reference to §6a / §4a resolves to a heading that exists.
#
# What this gate does NOT assert (honest limits, recorded in T-0040's exit record): runtime
# rotation actuation — Bundle.Stage/Bundle.RemoveRoot are test-only in the shipped binary —
# and data-plane application of DesiredState.ca_trust_bundle, which no data-plane consumer
# applies yet (T-0041/T-0042 own that half). §6b states both limits itself.
#
# Exit: 0 clean · 1 violation
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
runbook="$root/deploy/MVP-RUNBOOK.md"

fail=0
report() { echo "RUNBOOK VIOLATION: $1"; fail=1; }

if [ ! -f "$runbook" ]; then
  echo "runbook: FAIL — $runbook is absent (T-0040 AC4)"
  exit 1
fi

# Extract one "## N…" section: from its heading to the next "## " heading.
section() {
  awk -v h="$1" 'index($0, h) == 1 { f = 1; next } f && /^## / { exit } f' "$runbook"
}

sec6b="$(section '## 6b.')"
sec6a="$(section '## 6a.')"
sec4a="$(section '### 4a.')"

# --- 1. rotation procedure in §6b — stage, overlap, remove, precondition named ------------------
if [ -z "$sec6b" ]; then
  report "no §6b section (## 6b.) — the rotation operations section is missing"
else
  grep -q '\*\*Stage\.\*\*' <<<"$sec6b" || report "§6b carries no Stage step"
  grep -q '\*\*Overlap\.\*\*' <<<"$sec6b" || report "§6b carries no Overlap step"
  grep -q '\*\*Remove' <<<"$sec6b" || report "§6b carries no Remove step"
  grep -q 'precondition is named' <<<"$sec6b" || report "§6b does not name the removal precondition"
  grep -q 'ErrRootStillNeeded' <<<"$sec6b" || report "§6b does not name ErrRootStillNeeded (the removal refusal)"
  echo "  ok    §6b rotation procedure: stage → overlap → remove, removal precondition named"
fi

# --- 2. SPEC-0042 AC6 mid-flight case lives in §6b ----------------------------------------------
if [ -n "$sec6b" ]; then
  grep -q 'SPEC-0042 AC6' <<<"$sec6b" || report "§6b carries no SPEC-0042 AC6 enrolment-mid-flight entry"
fi

# --- 3. unseal in §6a ---------------------------------------------------------------------------
if [ -z "$sec6a" ]; then
  report "no §6a section (## 6a.) — the custody-service section is missing"
else
  grep -q '^### Unseal' <<<"$sec6a" || report "§6a carries no Unseal procedure"
  grep -qi 'quorum' <<<"$sec6a" || report "§6a unseal does not name the quorum"
  echo "  ok    §6a quorum-unseal procedure present"
fi

# --- 4. seal/custody-outage entry on both sides ---------------------------------------------------
grep -q '^### Seal or custody outage$' <<<"$sec6a" || report "§6a carries no 'Seal or custody outage' blast-radius entry"
if [ -n "$sec6b" ]; then
  grep -q '^### Seal or custody outage, mid-operation$' <<<"$sec6b" || report "§6b carries no 'Seal or custody outage, mid-operation' binding"
  echo "  ok    seal/custody-outage entry: §6a owns it, §6b binds to it"
fi

# --- 5. clock-skew entry in §4a -----------------------------------------------------------------
if [ -z "$sec4a" ]; then
  report "no §4a section (### 4a.) — the operational-notes section is missing"
else
  grep -q 'GITFROK_AGENT_CLOCK_SKEW_LEEWAY' <<<"$sec4a" || report "§4a carries no clock-skew leeway (GITFROK_AGENT_CLOCK_SKEW_LEEWAY)"
  grep -qi 'clock skew' <<<"$sec4a" || report "§4a carries no clock-skew symptom entry"
  echo "  ok    §4a clock-skew entry present"
fi

# --- 6. §6b's cross-references resolve ------------------------------------------------------------
# Every section §6b names must exist as a heading in the runbook. Today §6b references §6a
# and §4a; the assertions below fail the gate if either heading disappears, and the named
# entries inside them are asserted above.
if [ -n "$sec6b" ]; then
  if grep -q '§6a' <<<"$sec6b"; then
    grep -q '^## 6a\.' "$runbook" || report "§6b cross-references §6a, but no '## 6a.' heading exists"
    echo "  ok    §6b → §6a cross-reference resolves"
  else
    report "§6b lost its §6a cross-reference (quorum unseal must stay linked)"
  fi
  if grep -q '§4a' <<<"$sec6b"; then
    grep -q '^### 4a\.' "$runbook" || report "§6b cross-references §4a, but no '### 4a.' heading exists"
    echo "  ok    §6b → §4a cross-reference resolves"
  else
    report "§6b lost its §4a cross-reference (clock skew must stay linked)"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "runbook: FAIL — T-0040 AC4 / SPEC-0044 AC4 (rotation, unseal, outage, clock skew, cross-references)."
  exit 1
fi
echo "runbook: OK — §6b rotation + AC6 + outage, §6a unseal + outage, §4a clock skew, cross-references resolve"
