#!/usr/bin/env sh
# SPEC-0069 / T-0086 — the third-party stateful set's properties, asserted.
#
# The defect this gate exists to prevent is the one ADR-0099 found in deploy/dev: five of six
# components there are a `Deployment` carrying a ReadWriteOnce PVC, which cannot roll — the incoming
# pod cannot attach the volume the outgoing one still holds. That shape deploys, and then fails on
# its first upgrade looking like a storage fault. AC2 is the assertion that keeps it out.
#
# Assertions:
#   AC1   each overlay renders its own components; OpenBao and Zitadel are control-plane-only
#   AC2   every stateful component is a StatefulSet with volumeClaimTemplates (Zitadel exempt)
#   AC3   replica counts are exactly ADR-0099 decision 4's, so a scale-down is a failed build
#   AC4   no authored Secret, no secretGenerator, credentials by reference only
#   AC5   nothing publicly reachable: no LoadBalancer/NodePort/Gateway/HTTPRoute/hostPort
#   AC6   images digest-pinned — NOT RUN where no digest is published, with the cause named
#   AC7   OpenBao carries the properties check-custody-service.sh asserts of the dev manifest
#   AC8   OpenBao terminates TLS; no loopback-http relaxation travels from dev
#   AC9   the CNPG Cluster declares a backup target
#   AC10  storage classes are explicit; nothing relies on the cluster default
#   AC12  renders are deterministic
#   plus  EVERY vendored operator manifest matches the digest its README records
#
# Exit: 0 clean · 1 violation · 3 environment problem (kubectl absent)

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
plat="$root/deploy/k8s/platform"

fail=0
report() { echo "PLATFORM VIOLATION: $1"; fail=1; }

command -v kubectl >/dev/null 2>&1 || { echo "platform: kubectl absent — cannot render"; exit 3; }

for d in "$plat/base" "$plat/overlays/prod-cp" "$plat/overlays/prod-dp"; do
  [ -d "$d" ] || report "missing: $d"
done
[ "$fail" -eq 0 ] || { echo "platform: FAIL"; exit 1; }

# --- every vendored operator matches its pin ----------------------------------------------------
# A vendored megabyte is trustworthy only by digest; ADR-0099 accepted a controller to own, not a
# file nobody checks.
#
# OPERATORS ARE DISCOVERED, NOT LISTED, and that is the same correction T-0091 made to the location
# gate. This block named `cloudnative-pg` explicitly while it was the only operator, so the day a
# second one was vendored — cert-manager, 2026-09-23, a megabyte carrying cluster-wide RBAC and a
# webhook that intercepts admission — it was covered by nothing and the gate still said OK. A
# hard-coded list is a gate that is silently wrong exactly when it is most needed.
#
# The convention it discovers: one directory per operator, one *.yaml release manifest over 100 KiB
# (the small ones beside it are local additions, not the vendored artifact), and a README carrying
# its SHA-256 as an indented 64-hex line.
operators_dir="$plat/operators"
if [ ! -d "$operators_dir" ]; then
  report "no operators/ directory under $plat"
else
  found_any=0
  for op in "$operators_dir"/*/; do
    [ -d "$op" ] || continue
    name=$(basename "$op")
    found_any=1
    manifest=""
    for cand in "$op"*.yaml; do
      [ -f "$cand" ] || continue
      # 100 KiB floor: the vendored upstream release, never a local patch or kustomization.
      size=$(wc -c < "$cand" | tr -d ' ')
      [ "$size" -gt 102400 ] && { manifest="$cand"; break; }
    done
    if [ -z "$manifest" ]; then
      report "operators/$name has no vendored release manifest (no *.yaml over 100 KiB)"
      continue
    fi
    recorded=$(grep -oE '^    [0-9a-f]{64}$' "$op/README.md" 2>/dev/null | tr -d ' ' | head -1)
    actual=$(shasum -a 256 "$manifest" | awk '{print $1}')
    if [ -z "$recorded" ]; then
      report "operators/$name/README.md records no SHA-256 for $(basename "$manifest")"
    elif [ "$recorded" != "$actual" ]; then
      report "vendored $name digest mismatch: README says $recorded, file is $actual"
    fi
  done
  [ "$found_any" -eq 1 ] || report "operators/ is empty — the gate found nothing to check, which is not the same as finding nothing wrong"
fi

# --- secretGenerator, parsed rather than grepped ------------------------------------------------
# NO PIPE INTO xargs HERE, and that is a fix rather than a style choice. The previous form was
#     find ... -print0 | xargs -0 python3 - <<'KGEN'
# in which the heredoc redirects XARGS's stdin, so xargs read the Python source as its item list
# instead of the file list, and ran `python3 -` with stdin on /dev/null — an empty program, exit 0.
# This assertion had therefore NEVER RUN. shellcheck called it (SC2259, an error, not a note) and
# it was true. Python walks the roots itself, so there is no second stdin to fight over.
python3 - "$plat" ${PLATFORM_OVERLAYS:+"$PLATFORM_OVERLAYS"} <<'KGEN' || fail=1
import os
import sys

import yaml

roots = sys.argv[1:]
paths = sorted(
    os.path.join(d, "kustomization.yaml")
    for root in roots
    for d, _, files in os.walk(root)
    if "kustomization.yaml" in files
)

# The tripwire that would have caught the dead pipe on day one: a check that reads zero files
# passes silently and is indistinguishable from a check that found nothing wrong.
if not paths:
    print("PLATFORM VIOLATION: AC4: no kustomization.yaml found under " + ", ".join(roots) +
          " — the secretGenerator assertion had nothing to read, which is not the same as clean")
    sys.exit(1)

bad = 0
for path in paths:
    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}
    if isinstance(doc, dict) and "secretGenerator" in doc:
        print(f"PLATFORM VIOLATION: AC4: {path} declares secretGenerator — ADR-0096 decision 5 forbids it")
        bad = 1
sys.exit(bad)
KGEN

# --- AC8: the dev loopback relaxation must not travel -------------------------------------------
# Checked against the RENDER, not the files. The first version of this grepped deploy/k8s and was
# tripped by the manifests' own comments explaining that the flag must not appear — the same defect
# the AC4 secretGenerator check hit in check-controlplane-kustomize.sh, and the same lesson: an
# assertion a comment can satisfy or break is not an assertion. Renders carry no comments.

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# A fixture overlay can be substituted so the failability test exercises the same code path the
# real tree does, rather than a parallel implementation of it.
if [ -n "${PLATFORM_OVERLAYS:-}" ]; then
  set -- "$PLATFORM_OVERLAYS"
else
  set -- "$plat/overlays/prod-cp" "$plat/overlays/prod-dp"
fi

for ov in "$@"; do
  env=$(basename "$ov")
  if ! kubectl kustomize "$ov" > "$tmp/$env.yaml" 2> "$tmp/$env.err"; then
    report "$env does not render:"; sed 's/^/  /' "$tmp/$env.err"; continue
  fi
  kubectl kustomize "$ov" > "$tmp/$env.2.yaml" 2>/dev/null || true
  cmp -s "$tmp/$env.yaml" "$tmp/$env.2.yaml" || report "AC12: $env render is not deterministic"
  python3 - "$tmp/$env.yaml" "$env" <<'PY' || fail=1
import sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
env = sys.argv[2]
bad = 0
def report(m):
    global bad
    print(f"PLATFORM VIOLATION: {m}")
    bad = 1

# ADR-0099 decision 4, verbatim. A number changed here is a number changed in the ADR.
REPLICAS = {"postgres": 3, "openbao": 3, "redpanda": 3, "zitadel": 2, "valkey": 1, "seaweedfs": 1}
CP_ONLY = {"openbao", "zitadel"}
DP_ONLY = {"seaweedfs"}
STATELESS = {"zitadel"}

sets = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "StatefulSet"}
deps = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "Deployment"}
clusters = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "Cluster"}

# AC1: placement
present = set(sets) | set(deps) | set(clusters)
if env == "prod-dp":
    for n in CP_ONLY:
        if any(n in p for p in present):
            report(f"AC1: {n} renders in prod-dp; ADR-0066/0099 make it control-plane-only")
if env == "prod-cp":
    for n in DP_ONLY:
        if any(n in p for p in present):
            report(f"AC1: {n} renders in prod-cp; it is the data plane's object tier (ADR-0050)")

# AC2: a Deployment carrying a PVC is the shape that cannot roll
for name, d in deps.items():
    if any(k in name for k in STATELESS):
        continue
    vols = d["spec"]["template"]["spec"].get("volumes") or []
    if any("persistentVolumeClaim" in v for v in vols):
        report(f"AC2: Deployment/{name} carries a persistentVolumeClaim — it cannot roll, because the "
               f"incoming pod cannot attach the volume the outgoing one holds. Use a StatefulSet")

# AC2: stateful components have volumeClaimTemplates
for name, d in sets.items():
    if not d["spec"].get("volumeClaimTemplates"):
        report(f"AC2: StatefulSet/{name} has no volumeClaimTemplates — its data would not survive rescheduling")
    # AC10
    for vct in d["spec"].get("volumeClaimTemplates", []):
        if not (vct.get("spec") or {}).get("storageClassName"):
            report(f"AC10: StatefulSet/{name} claim {vct['metadata']['name']} has no storageClassName — it would take the cluster default")

# AC3: replica counts
for name, want in REPLICAS.items():
    obj = None
    for coll in (sets, deps, clusters):
        for k, v in coll.items():
            if name in k:
                obj = v
                break
        if obj:
            break
    if obj is None:
        continue
    got = obj["spec"].get("instances") if obj.get("kind") == "Cluster" else obj["spec"].get("replicas")
    if got != want:
        report(f"AC3: {obj['kind']}/{obj['metadata']['name']} has {got}, ADR-0099 decision 4 says {want}")

# AC4: no authored Secret; credentials by reference
CRED_WORDS = {"PASSWORD", "SECRET", "TOKEN", "KEY", "CREDENTIAL", "PASSPHRASE", "MASTERKEY"}
REF_SUFFIX = ("_NAME", "_FILE", "_DIR", "_ADDR", "_MOUNT", "_ROLE", "_ID", "_PATH")
for d in docs:
    if d.get("kind") == "Secret":
        report(f"AC4: the render authors Secret/{d['metadata']['name']}")
for coll in (sets, deps):
    for name, d in coll.items():
        for c in d["spec"]["template"]["spec"].get("containers", []) or []:
            for e in c.get("env", []) or []:
                nm = (e.get("name") or "").upper()
                if nm.endswith(REF_SUFFIX):
                    continue
                if CRED_WORDS & set(nm.split("_")) and "value" in e:
                    report(f"AC4: {name}/{c['name']} env {e['name']} is a LITERAL credential")

# AC8: the dev loopback relaxation must not travel. An env NAME in the render, never text in a file.
for coll in (sets, deps):
    for name, d in coll.items():
        for c in d["spec"]["template"]["spec"].get("containers", []) or []:
            for e in c.get("env", []) or []:
                if e.get("name") == "GITFROK_CUSTODY_ALLOW_LOOPBACK_HTTP":
                    report(f"AC8: {name}/{c['name']} sets GITFROK_CUSTODY_ALLOW_LOOPBACK_HTTP — "
                           f"that relaxation is dev's alone (ADR-0099 decision 6)")

# AC5: nothing publicly reachable
for d in docs:
    k = d.get("kind")
    if k == "Service" and d["spec"].get("type") in ("LoadBalancer", "NodePort"):
        report(f"AC5: Service/{d['metadata']['name']} is {d['spec']['type']} — the stateful set is ClusterIP only")
    if k in ("Gateway", "HTTPRoute", "Ingress"):
        report(f"AC5: {k}/{d['metadata']['name']} exposes the stateful set; Zitadel is reached through the control-plane Gateway alone")
for coll in (sets, deps):
    for name, d in coll.items():
        for c in d["spec"]["template"]["spec"].get("containers", []) or []:
            for p in c.get("ports", []) or []:
                if p.get("hostPort"):
                    report(f"AC5: {name}/{c['name']} declares hostPort {p['hostPort']}")

# AC9: the CNPG Cluster must back up
for name, c in clusters.items():
    if not c["spec"].get("backup"):
        report(f"AC9: Cluster/{name} declares no backup — ADR-0099 decision 5 requires a target that leaves the cluster")

# AC6: digest pins, reported honestly where unpublished
undigested = []
for coll in (sets, deps):
    for name, d in coll.items():
        for c in d["spec"]["template"]["spec"].get("containers", []) or []:
            img = c.get("image", "")
            if img and "@sha256:" not in img:
                undigested.append(f"{name}/{c['name']}={img}")
if undigested:
    print(f"platform: AC6 NOT RUN for {env} — these images have no published digest to pin to yet")
    print("platform:   (the first-party publish path exists but has not run; third-party pins are by tag")
    print("platform:   in deploy/dev/versions.env, which ADR-0034's follow-up already records):")
    for u in sorted(undigested):
        print(f"platform:     {u}")

sys.exit(bad)
PY
done

# --- AC7: OpenBao's gated properties, in the production manifest --------------------------------
cp_render="${PLATFORM_OVERLAYS:+$tmp/$(basename "$PLATFORM_OVERLAYS").yaml}"
[ -n "$cp_render" ] || cp_render="$tmp/prod-cp.yaml"
if [ -f "$cp_render" ]; then
  grep -q 'retry_join' "$cp_render" || report "AC7: no raft retry_join in the prod-cp render — OpenBao would not form a quorum"
  if grep -qE '^[[:space:]]*seal[[:space:]]+"' "$cp_render"; then
    report "AC7: a seal stanza exists — ADR-0066 decision 4 is Shamir quorum unseal only"
  fi
  grep -q 'tokenreview\|TokenReview\|system:auth-delegator' "$cp_render" || report "AC7: no token-review delegation — Kubernetes auth is OpenBao's only client path (ADR-0066 decision 5)"
  grep -q 'tls_disable[[:space:]]*=[[:space:]]*true\|tls_disable[[:space:]]*:[[:space:]]*true' "$cp_render" && report "AC8: OpenBao has tls_disable true — production terminates TLS (ADR-0099 decision 6)"
fi

if [ "$fail" -ne 0 ]; then
  echo "platform: FAIL"
  echo "platform: SPEC-0069, T-0086. The stateful set's properties are asserted, not intended."
  exit 1
fi
echo "platform: OK — StatefulSets with claims, ADR-0099 replica counts, no authored Secret, nothing publicly reachable, CNPG pinned and backing up"
