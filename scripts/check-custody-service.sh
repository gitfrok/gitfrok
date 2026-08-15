#!/usr/bin/env bash
# T-0040 AC5 / SPEC-0044 AC5 / ADR-0066 decisions 5–7: the custody service is deployed,
# pinned and provable — not assumed.
#
# Static assertions over deploy/dev/openbao.yaml and the data-plane chart, the same shape
# as the other gates in this directory (assert, don't generate):
#
#   node count        the StatefulSet runs exactly three replicas — the Raft minimum
#                     (ADR-0066 decision 6).
#   placement         control-plane-side only: the manifest carries the placement label,
#                     and NO data-plane surface references the custody service at all —
#                     neither the BYO chart nor the data-plane dev manifest.
#   unseal posture    Shamir quorum unseal only: the share shape is recorded on the
#                     StatefulSet, and no auto-unseal seal stanza exists anywhere
#                     (ADR-0066 decision 4).
#   no static creds   no credential-shaped assignment in env, config or values —
#                     Kubernetes auth is the only client path (ADR-0066 decision 5),
#                     whose server-side half (ServiceAccount + token-review delegation)
#                     must be present in the manifest.
#   wired consumer    the backend production composition root reads its custody posture
#                     from env and constructs no dev CA — the deployment-side mirror of
#                     SPEC-0044 AC1/AC3 fitness (backend b0ab32e).
#   consumer pairing  if the controlplane manifest opens the agent door, the custody env
#                     must be paired with it (see section 6) — vacuous while the door is
#                     closed, biting the image bump that opens it.
#   image pin         delegated to check-dev-images.sh (openbao.yaml is a mapped
#                     manifest there), which asserts the tag against versions.env and,
#                     with CHECK_IMAGE_RESOLVE=1, that the registry resolves it.
#
# The helm-rendered assertion (the data-plane chart templated, then grepped for the
# custody service) runs when `helm` is on PATH; without it the gate says so on its own
# output line and passes on the static half alone — declared, never silently omitted
# (the same shape check-byo-chart.sh uses; SPEC-0014 AC7).
#
# Exit: 0 clean · 1 violation
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
manifest="$root/deploy/dev/openbao.yaml"
chart="$root/deploy/helm/gitfrok-dataplane"
dataplane_manifest="$root/deploy/dev/dataplane.yaml"

fail=0
report() { echo "CUSTODY VIOLATION: $1"; fail=1; }

# --- 0. the manifest must exist ---------------------------------------------------------------
if [ ! -f "$manifest" ]; then
  echo "custody-service: FAIL — $manifest is absent (T-0040 AC5)"
  exit 1
fi

# --- 1. node count: exactly three Raft members -------------------------------------------------
if ! grep -qE '^kind:[[:space:]]*StatefulSet[[:space:]]*$' "$manifest"; then
  report "openbao.yaml runs no StatefulSet — HA custody needs stable identities and Raft PVCs"
fi
if ! grep -qE '^[[:space:]]+replicas:[[:space:]]*3[[:space:]]*$' "$manifest"; then
  report "openbao.yaml does not run exactly 3 replicas — Raft HA minimum (ADR-0066 decision 6)"
fi
if ! grep -q 'storage "raft"' "$manifest"; then
  report "openbao.yaml does not use integrated (raft) storage — ADR-0066 decision 6"
fi
if ! grep -q 'volumeClaimTemplates:' "$manifest"; then
  report "openbao.yaml has no volumeClaimTemplates — Raft state must be on per-node PVCs"
fi

# --- 2. placement: control-plane-side only ------------------------------------------------------
if ! grep -q 'placement: control-plane' "$manifest"; then
  report "openbao.yaml lacks the 'placement: control-plane' label — ADR-0066 decision 6"
fi
# The data-plane chart is what installs into CUSTOMER clusters; a reference there is the
# custody service leaking into a data plane. Checked statically here and against the helm
# render below when helm exists.
if [ -d "$chart" ]; then
  if grep -rniE 'openbao|custody|vault|transit' "$chart" 2>/dev/null | grep -v '^Binary'; then
    report "deploy/helm/gitfrok-dataplane references the custody service — no data-plane chart may (ADR-0066 decision 6)"
  else
    echo "  ok    data-plane chart carries no custody reference (static)"
  fi
else
  echo "custody-service: note: $chart absent — chart-reference assertion vacuously holds"
fi
# The data plane's own dev manifest must not consume custody either: the control-plane-side
# rule is about which workloads may address it, and the data plane is not one of them.
if [ -f "$dataplane_manifest" ] && grep -qiE 'openbao|custody' "$dataplane_manifest"; then
  report "deploy/dev/dataplane.yaml references the custody service — custody is control-plane-side only"
fi

# --- 3. unseal posture: Shamir only, never automated ---------------------------------------------
if ! grep -q 'custody.gitsaas/key-shares:' "$manifest"; then
  report "openbao.yaml does not record the Shamir key-shares shape (custody.gitsaas/key-shares)"
fi
if ! grep -q 'custody.gitsaas/key-threshold:' "$manifest"; then
  report "openbao.yaml does not record the Shamir key-threshold (custody.gitsaas/key-threshold)"
fi
if grep -inE 'seal[[:space:]]*"|awskms|gcpckms|azurekeyvault|pkcs11|kmip|auto[-_]?unseal' "$manifest"; then
  report "openbao.yaml carries an auto-unseal shape — Shamir quorum unseal only (ADR-0066 decision 4)"
fi

# --- 4. Kubernetes auth server side present, static credentials absent ---------------------------
if ! grep -qE '^kind:[[:space:]]*ServiceAccount[[:space:]]*$' "$manifest"; then
  report "openbao.yaml defines no ServiceAccount — Kubernetes auth has no server identity (ADR-0066 decision 5)"
fi
if ! grep -q 'system:auth-delegator' "$manifest"; then
  report "openbao.yaml grants no token-review delegation — Kubernetes auth cannot validate callers"
fi
# A credential-shaped assignment anywhere in the manifest — env value, HCL key, annotation —
# is a static credential, which AC5 forbids in values or environment.
if grep -inE '(password|passwd|secret_id|client_secret|access_key|secret_key|api_key|private_key|root_token|[a-z0-9_]*token)[[:space:]]*[:=]' "$manifest"; then
  report "openbao.yaml carries a credential-shaped assignment — no static credential anywhere (ADR-0066 decision 5)"
fi

# --- 5. wired-consumer posture: the production composition root is custody-only ----------------
# The backend composition root (backend b0ab32e onward) composes its CA exclusively through the
# custody service; internal/arch fitness asserts the same property in-tree. From the deployment
# side we assert the wiring exists at all: the root reads the custody posture from env and never
# constructs the dev CA (SPEC-0044 AC1/AC3, mirrored; T-0040 AC5).
backend_root="$root/backend/cmd/controlplane-app"
if [ -d "$backend_root" ]; then
  if ! grep -rq 'GITFROK_CUSTODY_OPENBAO_ADDR' "$backend_root"; then
    report "backend composition root reads no custody address (GITFROK_CUSTODY_OPENBAO_ADDR) — the CA is not wired through the custody service"
  fi
  if grep -rl 'NewDevCA(' "$backend_root" --include='*.go' 2>/dev/null | grep -v '_test\.go$' | grep -q .; then
    report "backend composition root constructs the dev CA in a non-test source — custody must be the only CA path (SPEC-0044 AC3)"
  else
    echo "  ok    control-plane composition root is custody-only (no dev CA in non-test sources)"
  fi
else
  echo "custody-service: note: $backend_root absent (submodule not checked out) — wired-consumer assertion NOT run, declared"
fi

# --- 6. consumer env pairing: an open agent door implies the custody env -----------------------
# The production composition root constructs ONLY the custody-backed CA (SPEC-0044 AC1), and
# since backend 28f729f its startup REFUSES without both GITFROK_CUSTODY_OPENBAO_ADDR and
# GITFROK_CUSTODY_SNAPSHOT_FILE. So the moment the controlplane manifest opens the agent door
# (GITFROK_AGENT_GRPC_ADDR set), both custody variables must be present in the same manifest.
# Today the door is CLOSED (the dev deployment still pins the pre-custody image), so this
# assertion passes vacuously — it is written to bite on the future image bump that opens the
# door without the custody env.
controlplane_manifest="$root/deploy/dev/controlplane.yaml"
if [ -f "$controlplane_manifest" ] && grep -q 'GITFROK_AGENT_GRPC_ADDR' "$controlplane_manifest"; then
  if ! grep -q 'GITFROK_CUSTODY_OPENBAO_ADDR' "$controlplane_manifest"; then
    report "controlplane.yaml opens the agent door without GITFROK_CUSTODY_OPENBAO_ADDR — the custody CA cannot compose (SPEC-0044 AC1)"
  fi
  if ! grep -q 'GITFROK_CUSTODY_SNAPSHOT_FILE' "$controlplane_manifest"; then
    report "controlplane.yaml opens the agent door without GITFROK_CUSTODY_SNAPSHOT_FILE — startup refuses without it (backend 28f729f)"
  fi
  echo "  ok    agent door open in controlplane.yaml: custody env paired (OPENBAO_ADDR + SNAPSHOT_FILE)"
else
  echo "custody-service: note: agent door closed in controlplane.yaml (no GITFROK_AGENT_GRPC_ADDR) — custody-env pairing assertion vacuously holds; it bites when the door opens"
fi

# --- 7. rendered assertion: the chart, templated, still carries no custody ----------------------
if command -v helm >/dev/null 2>&1; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/custody-chart.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  render="$tmp/rendered.yaml"
  if helm template test-release "$chart" \
      --set agent.gatewayAddr=agent.gitsaas.example:8443 \
      --set agent.caBundleConfigMap=gitfrok-agent-ca \
      --set policy.bundleConfigMap=gitfrok-policy-bundle \
      --set region=eu-west1 \
      --set enrolment.existingSecret.name=dp-enrolment \
      > "$render" 2> "$tmp/template.err"; then
    if grep -qiE 'openbao|custody|vault|transit' "$render"; then
      report "rendered data-plane chart references the custody service"
    else
      echo "  ok    rendered data-plane chart carries no custody reference"
    fi
  else
    report "helm template of the data-plane chart failed — cannot render-assert custody absence:"
    sed 's/^/  /' "$tmp/template.err"
  fi
  echo "custody-service: helm assertions ran (helm $(helm version --short 2>/dev/null))"
else
  echo "custody-service: helm not on PATH — rendered chart assertions NOT run; static assertions above still bind"
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "custody-service: FAIL — T-0040 AC5 / SPEC-0044 AC5 (ADR-0066 decisions 5–7)."
  exit 1
fi
echo "custody-service: OK — 3-node Raft, control-plane-side, Shamir-only unseal, no static credential, custody-only consumer"
