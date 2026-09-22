#!/usr/bin/env sh
# SPEC-0072 / T-0091 — every live `gke` unit DECLARES its cluster location.
#
# ADR-0106 put both production environments on zonal clusters and named its own weakest point:
# nothing enforced it. The module's `var.location` defaults to null and resolves to `var.region`,
# so a `gke/terragrunt.hcl` with the line DELETED is valid HCL that plans clean, applies
# successfully, and produces a REGIONAL cluster — whose node pools create `min_nodes` nodes PER
# ZONE. Nothing fails. The plan prints `location = "asia-southeast1"`, which reads like a correct
# region to anyone who does not already know the multiplication, and the bill arrives a month later.
#
# THIS GATE ASSERTS EXPLICITNESS AND NEVER A VALUE, and that is a decision (SPEC-0072, out of
# scope), not an omission. ADR-0106 decision 2 expects the zonal choice to be revisited when an
# availability requirement is finally stated; a gate pinning `asia-southeast1-a` would turn that
# reversal into a gate fight. A region is as explicit as a zone and is accepted. The model is
# check-platform-kustomize.sh AC10, which requires a storageClassName to be STATED and has no
# opinion which.
#
# Assertions:
#   AC1  every discovered `*/gke/terragrunt.hcl` sets `location` as a direct input, named per unit
#   AC3  a commented-out `location` is an absence — the line is visible in a diff, the input is not
#
# Units are DISCOVERED, never listed: a hard-coded pair is a gate that is silently wrong on the day
# a third environment is created, which is exactly when it is most needed.
#
# Offline by construction — this reads the tree. No GCP credentials, no network, no terragrunt.
#
# Exit: 0 clean · 1 violation · 3 environment problem (python3 absent)

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
live="${GKE_LIVE_DIR:-$root/deploy/gcp/live}"

command -v python3 >/dev/null 2>&1 || { echo "gke-location: python3 absent — cannot parse"; exit 3; }
[ -d "$live" ] || { echo "GKE LOCATION VIOLATION: no such directory: $live"; exit 1; }

LIVE_DIR="$live" python3 <<'PY' || exit 1
import glob
import os
import sys

live = os.environ["LIVE_DIR"]
fail = False


def report(msg):
    global fail
    print("GKE LOCATION VIOLATION: " + msg)
    fail = True


def strip_comments(src):
    """Blank out HCL comments, leaving strings intact.

    AC3 lives here. A `# location = "..."` line is VISIBLE in a diff and ABSENT from the parsed
    input, which is the whole shape ADR-0106's consequence describes — so comments are removed
    before anything is matched, and a commented declaration cannot satisfy AC1.

    Strings are preserved because `${get_repo_root()}` carries braces the brace-walker must not
    count, and because a `#` inside a string is not a comment.
    """
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            out.append(c)
            i += 1
            while i < n:
                out.append(src[i])
                if src[i] == "\\":
                    i += 2
                    if i - 1 < n:
                        out[-1] = src[i - 2]
                        out.append(src[i - 1])
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == "#" or (c == "/" and i + 1 < n and src[i + 1] == "/"):
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def inputs_body(src):
    """The text between `inputs = {` and its matching `}`, or None."""
    key = src.find("inputs")
    while key != -1:
        after = src[key + len("inputs"):]
        stripped = after.lstrip()
        if stripped.startswith("="):
            brace = stripped.find("{")
            if brace != -1 and stripped[1:brace].strip() == "":
                start = key + len("inputs") + (len(after) - len(stripped)) + brace + 1
                depth = 1
                i = start
                while i < len(src) and depth:
                    if src[i] == "{":
                        depth += 1
                    elif src[i] == "}":
                        depth -= 1
                    i += 1
                return src[start:i - 1] if depth == 0 else None
        key = src.find("inputs", key + 1)
    return None


def declares_location(body):
    """True when `location` is assigned at the TOP level of the inputs block.

    Depth matters: a `location` nested inside `system_pool` is not an input to the module, and a
    depth-blind match would accept a unit whose cluster is still regional.
    """
    depth = 0
    i, n = 0, len(body)
    while i < n:
        c = body[i]
        if c == "{" or c == "[":
            depth += 1
        elif c == "}" or c == "]":
            depth -= 1
        elif depth == 0 and body.startswith("location", i):
            before = body[i - 1] if i else " "
            rest = body[i + len("location"):]
            if not (before.isalnum() or before in "_-.") and rest.lstrip().startswith("="):
                return True
        i += 1
    return False


units = sorted(glob.glob(os.path.join(live, "*", "gke", "terragrunt.hcl")))
if not units:
    report("no */gke/terragrunt.hcl found under " + live +
           " — the gate found nothing to check, which is not the same as finding nothing wrong")

for path in units:
    name = os.path.relpath(path, live)
    body = inputs_body(strip_comments(open(path, encoding="utf-8").read()))
    if body is None:
        report(name + " has no parseable `inputs` block, so `location` cannot be asserted")
        continue
    if not declares_location(body):
        report(
            name + " declares no `location` input. The module defaults to the region, so this "
            "applies as a REGIONAL cluster and every node pool creates min_nodes nodes PER ZONE "
            "— three times the nodes, with nothing failing (ADR-0106 decision 1). Set a zone, or "
            "set the region explicitly if that is the intent; the gate accepts either, and asserts "
            "only that the choice was made."
        )

if fail:
    print("gke-location: FAIL")
    sys.exit(1)
print("gke-location: OK — %d unit(s) declare their location explicitly" % len(units))
PY
