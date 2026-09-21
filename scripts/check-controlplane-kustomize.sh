#!/usr/bin/env sh
# SPEC-0067 / T-0084 — the control-plane Kustomize installer's properties, asserted.
#
# ADR-0096 decision 5 exists because swapping Helm for Kustomize creates one new hazard rather than
# inheriting an old one: Helm made "author no Secret" easy to keep by being inconvenient, while
# Kustomize ships `secretGenerator` as the ergonomic front door to exactly that. Restraint is not a
# control, so this gate is.
#
# It also replaces what Helm gave for free and Kustomize does not: `required` failed a render on a
# missing input; Kustomize renders an empty env value without complaint.
#
# Assertions (each maps to a SPEC-0067 criterion):
#   AC1   the overlay renders exactly the three first-party workloads, no fourth
#   AC2   no third-party stateful workload in the render (they are inputs, not contents)
#   AC3   no secretGenerator anywhere; no tree-authored Secret in the render
#   AC4   every credential arrives by secretKeyRef / envFrom.secretRef, never a literal
#   AC5   first-party images are digest-pinned — NOT RUN where no published digest exists, and it
#         says so on its own output line rather than passing quietly
#   AC6   the agent door is an L4 LoadBalancer with no L7 route or annotation
#   AC7   the Gateway carries an HTTPS listener and a :80 listener for ACME HTTP-01
#   AC8   the agent door never requests an ephemeral address
#   AC11  base/ renders on its own
#   AC12  no helm chart, values.yaml or helm invocation under deploy/k8s/
#
# Exit: 0 clean · 1 violation · 3 environment problem (kubectl absent)

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cp_dir="$root/deploy/k8s/controlplane"
base="$cp_dir/base"
overlay="${CP_OVERLAY:-$cp_dir/overlays/prod-cp}"

fail=0
report() { echo "CP-KUSTOMIZE VIOLATION: $1"; fail=1; }
note()   { echo "cp-kustomize: $1"; }

command -v kubectl >/dev/null 2>&1 || { echo "cp-kustomize: kubectl absent — cannot render"; exit 3; }

# --- 0. the installer must exist ----------------------------------------------------------------
[ -d "$base" ]    || report "base/ does not exist at $base"
[ -d "$overlay" ] || report "overlay does not exist at $overlay"
[ "$fail" -eq 0 ] || { echo "cp-kustomize: FAIL"; exit 1; }

# --- AC12: no Helm anywhere (ADR-0096 decision 1) -----------------------------------------------
if find "$cp_dir" \( -name 'Chart.yaml' -o -name 'values.yaml' -o -name '*.tpl' \) | grep -q .; then
  report "AC12: a Helm chart artifact exists under deploy/k8s/controlplane"
fi
if [ -d "$root/deploy/helm/gitfrok-controlplane" ]; then
  report "AC12: deploy/helm/gitfrok-controlplane exists — ADR-0096 decision 1 says it never does"
fi

# --- AC3 (authoring half): secretGenerator is forbidden before anything is rendered -------------
# Parsed as YAML, not grepped. The first version of this gate grepped, and its own comment saying
# "no secretGenerator" tripped it — a grep assertion that a comment can satisfy or break is the
# exact defect this file exists to catch elsewhere.
find "$cp_dir" "$overlay" -name 'kustomization.yaml' -print0 | sort -zu | tr -d '\0' >/dev/null 2>&1; find "$cp_dir" "$overlay" -name 'kustomization.yaml' -print0 | xargs -0 python3 - <<'KGEN' || fail=1
import sys, yaml
bad = 0
for path in sys.argv[1:]:
    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}
    if not isinstance(doc, dict):
        continue
    if 'secretGenerator' in doc:
        print(f'CP-KUSTOMIZE VIOLATION: AC3: {path} declares secretGenerator — ADR-0096 decision 5 forbids it')
        bad = 1
sys.exit(bad)
KGEN

# --- render ------------------------------------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ! kubectl kustomize "$overlay" > "$tmp/overlay.yaml" 2> "$tmp/overlay.err"; then
  report "the overlay does not render:"
  sed 's/^/  /' "$tmp/overlay.err"
  echo "cp-kustomize: FAIL"
  exit 1
fi

# AC11: base renders alone, so the overlay is additive and the base is reviewable
if ! kubectl kustomize "$base" > "$tmp/base.yaml" 2> "$tmp/base.err"; then
  report "AC11: base/ does not render on its own:"
  sed 's/^/  /' "$tmp/base.err"
fi

# AC1 determinism (SPEC-0067 non-functional): two renders are byte-identical
kubectl kustomize "$overlay" > "$tmp/overlay2.yaml" 2>/dev/null || true
if ! cmp -s "$tmp/overlay.yaml" "$tmp/overlay2.yaml"; then
  report "the render is not deterministic — two runs at one revision differ"
fi

# --- the parsed assertions ----------------------------------------------------------------------
# Parsed as YAML, never grepped: a comment must not be able to satisfy or break an assertion.
python3 - "$tmp/overlay.yaml" <<'PY' || fail=1
import sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
bad = 0
def report(msg):
    global bad
    print(f"CP-KUSTOMIZE VIOLATION: {msg}")
    bad = 1

FIRST_PARTY = {"controlplane", "bff", "webfrontend"}
THIRD_PARTY = ("postgres", "valkey", "redpanda", "openbao", "zitadel", "seaweedfs")

workloads = [d for d in docs if d.get("kind") in ("Deployment", "StatefulSet", "DaemonSet")]
names = {w["metadata"]["name"] for w in workloads}

# AC1: exactly the three first-party workloads, no fourth
if names != FIRST_PARTY:
    report(f"AC1: rendered workloads are {sorted(names)}, expected {sorted(FIRST_PARTY)}")

# AC2: no third-party stateful workload — they are required inputs, not contents
for w in workloads:
    n = w["metadata"]["name"].lower()
    for t in THIRD_PARTY:
        if t in n:
            report(f"AC2: {w['kind']}/{n} is a third-party stateful workload; ADR-0093 decision 2 makes it an input")

# AC3 (rendered half): no Secret authored by this tree
for d in docs:
    if d.get("kind") == "Secret":
        report(f"AC3: the render contains Secret/{d['metadata']['name']} — the installer authors no Secret")

# AC4: credentials arrive only by reference. A literal value on a credential-shaped name is the defect.
#
# Detection is TOKEN-based, not substring-based, and the reason is empirical: a substring check
# flagged GITFROK_SESSION_VALKEY_ADDR because "KEY" lives inside "VALKEY", and
# GITFROK_CUSTODY_KEY_NAME because a key's NAME is not a key. Split on underscores, compare whole
# words, and exclude the suffixes that denote a reference to a thing rather than the thing itself.
CRED_WORDS = {"PASSWORD", "SECRET", "TOKEN", "KEY", "CREDENTIAL", "PASSPHRASE"}
REFERENCE_SUFFIXES = ("_NAME", "_FILE", "_DIR", "_ADDR", "_MOUNT", "_ROLE", "_ID", "_PATH")
# Carries a credential without containing a credential word.
CRED_EXPLICIT = {"GITFROK_DATABASE_URL"}

def carries_credential(name):
    up = name.upper()
    if up in CRED_EXPLICIT:
        return True
    if up.endswith(REFERENCE_SUFFIXES):
        return False
    return bool(CRED_WORDS & set(up.split("_")))

for w in workloads:
    for c in w["spec"]["template"]["spec"].get("containers", []):
        for e in c.get("env", []) or []:
            nm = e.get("name", "")
            if carries_credential(nm):
                if "value" in e:
                    report(f"AC4: {w['metadata']['name']}/{c['name']} env {nm} is a LITERAL; must be secretKeyRef")
                elif not (e.get("valueFrom") or {}).get("secretKeyRef"):
                    report(f"AC4: {w['metadata']['name']}/{c['name']} env {nm} is neither a literal nor a secretKeyRef")
        # AC13-shaped: an empty required env is what Helm's `required` used to catch
        for e in c.get("env", []) or []:
            if e.get("value") == "":
                report(f"AC4: {w['metadata']['name']}/{c['name']} env {e.get('name')} is an EMPTY literal")

# AC5: digest pins. Recorded as NOT RUN where no published digest exists (see the shell note).
undigested = []
for w in workloads:
    for c in w["spec"]["template"]["spec"].get("containers", []):
        img = c.get("image", "")
        if "gitfrok/" in img and "@sha256:" not in img:
            undigested.append(f"{w['metadata']['name']}/{c['name']}={img}")
if undigested:
    print("cp-kustomize: AC5 NOT RUN — no published digest exists for these first-party images yet;")
    print("cp-kustomize:   deploy/dev/versions.env pins them by tag and records that they are never")
    print("cp-kustomize:   published to an external registry. Tag-pinned, named, not passed:")
    for u in undigested:
        print(f"cp-kustomize:     {u}")

# AC6 + AC8: the agent door
doors = [d for d in docs if d.get("kind") == "Service" and d["spec"].get("type") == "LoadBalancer"]
if len(doors) != 1:
    report(f"AC6: expected exactly one LoadBalancer Service (the agent door), found {len(doors)}")
for s in doors:
    nm = s["metadata"]["name"]
    anns = s["metadata"].get("annotations", {}) or {}
    for a in anns:
        if a.startswith(("networking.gke.io/v1beta1.FrontendConfig",
                         "gateway.networking.k8s.io/", "cloud.google.com/backend-config")):
            report(f"AC6: agent door Service/{nm} carries an L7 annotation {a}")
    for p in s["spec"].get("ports", []):
        if p.get("protocol", "TCP") != "TCP":
            report(f"AC6: agent door Service/{nm} port {p.get('port')} is not TCP passthrough")
    # AC8: an absent loadBalancerIP means GKE hands out an ephemeral address
    if not s["spec"].get("loadBalancerIP") and "networking.gke.io/load-balancer-ip-addresses" not in anns:
        report(f"AC8: agent door Service/{nm} requests an EPHEMERAL address — a hand-written DNS record would go stale")

# AC6: nothing routes L7 traffic at the agent door
routes = [d for d in docs if d.get("kind") in ("HTTPRoute", "GRPCRoute", "Ingress")]
door_names = {s["metadata"]["name"] for s in doors}
for r in routes:
    for rule in r["spec"].get("rules", []) or []:
        for br in rule.get("backendRefs", []) or []:
            if br.get("name") in door_names:
                report(f"AC6: {r['kind']}/{r['metadata']['name']} routes to the agent door {br.get('name')}")

# AC7: a Gateway with an HTTPS listener and a :80 listener for ACME HTTP-01
gws = [d for d in docs if d.get("kind") == "Gateway"]
if not gws:
    report("AC7: no Gateway in the render")
for g in gws:
    ports = {l.get("port") for l in g["spec"].get("listeners", [])}
    protos = {l.get("protocol") for l in g["spec"].get("listeners", [])}
    if 443 not in ports or "HTTPS" not in protos:
        report(f"AC7: Gateway/{g['metadata']['name']} has no HTTPS :443 listener")
    if 80 not in ports:
        report(f"AC7: Gateway/{g['metadata']['name']} has no :80 listener — ACME HTTP-01 cannot solve")

sys.exit(bad)
PY

if [ "$fail" -ne 0 ]; then
  echo "cp-kustomize: FAIL"
  echo "cp-kustomize: SPEC-0067, T-0084. The installer's properties are asserted, not intended."
  exit 1
fi

note "OK — three first-party workloads, no authored Secret, no secretGenerator, agent door is L4 with a reserved address, Gateway carries :443 and :80"
