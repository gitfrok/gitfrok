#!/usr/bin/env bash
# T-0031 / SPEC-0039 install-time anti-faking gate for the BYO data-plane chart.
#
# Two callouts this gate makes executable, because an install is only real if it
# self-registers and nobody can fake either side of that:
#
#   AC2 (token secrecy): the chart carries no secret. The enrolment token is install-time
#   input only and is NEVER persisted by the chart — not in values.yaml defaults, not in a
#   chart-authored Secret, not as a literal env value, and the DataPlane CR schema accepts
#   a REFERENCE to an operator-held Secret only, never a value. CR status never holds a
#   credential field at all.
#
#   AC8 (no inbound path): the chart opens no door into the customer's cluster. It renders
#   no Service, Ingress, Gateway, or anything else with a cloud load balancer behind it,
#   and no hostNetwork/hostPort. The data plane only ever dials OUT to the control plane
#   (ADR-0011, SPEC-0039 out-of-scope: "any inbound path ... in any form, for any reason"),
#   and the backend agent wiring is asserted to open no listener of its own.
#
# The static assertions always run. The helm-rendered assertions run when `helm` is on
# PATH; without it the gate says so on its own output line and passes on the static half
# alone — declared, never silently omitted (SPEC-0014 AC7 shape).
#
# Exit: 0 clean · 1 violation · 3 environment problem (chart absent)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
chart="$root/deploy/helm/gitfrok-dataplane"

fail=0
report() { echo "BYO-CHART VIOLATION: $1"; fail=1; }

# --- 0. the chart must exist --------------------------------------------------------------------
if [ ! -f "$chart/Chart.yaml" ] || [ ! -f "$chart/values.yaml" ]; then
  echo "byo-chart: expected the chart at deploy/helm/gitfrok-dataplane — not found" >&2
  exit 3
fi

templates="$chart/templates"
crd="$chart/crds/dataplanes-crd.yaml"

# --- 1. AC2: values.yaml carries no token field ---------------------------------------------------
# The only enrolment surface in the defaults is existingSecret: a NAME reference. A chart that
# defaults a token value is a chart that ships secrets.
if grep -nE '^[[:space:]]*token:' "$chart/values.yaml"; then
  report "values.yaml declares a token field — the chart must carry no secret (SPEC-0039 non-functional)"
fi
if ! grep -q 'existingSecret:' "$chart/values.yaml"; then
  report "values.yaml has no enrolment.existingSecret reference — token input must be a reference, never a value"
fi

# --- 2. AC2: the chart authors no Secret object ---------------------------------------------------
for f in "$templates"/*.yaml "$templates"/*.tpl; do
  [ -f "$f" ] || continue
  if grep -nE '^kind:[[:space:]]*Secret[[:space:]]*$' "$f"; then
    report "$f templates a Secret — the operator creates and deletes their own; the chart persists nothing"
  fi
done

# --- 3. AC2: the token reaches the container only by secretKeyRef, never as a literal ------------
dep="$templates/deployment.yaml"
if [ ! -f "$dep" ]; then
  report "templates/deployment.yaml is absent — no data-plane install path"
else
  # The env entry for GITFROK_ENROLMENT_TOKEN and the next five lines (its valueFrom block) must
  # name secretKeyRef and must NOT carry `value:` — a literal env value is persisted in the
  # Deployment object, which is exactly a written-back file.
  block=$(grep -A 5 'GITFROK_ENROLMENT_TOKEN' "$dep" || true)
  if [ -z "$block" ]; then
    report "deployment.yaml does not wire GITFROK_ENROLMENT_TOKEN at all — install cannot self-register"
  else
    if ! printf '%s\n' "$block" | grep -q 'secretKeyRef'; then
      report "GITFROK_ENROLMENT_TOKEN is not sourced from secretKeyRef"
    fi
    if printf '%s\n' "$block" | grep -qE '^[[:space:]]*-?[[:space:]]*value:'; then
      report "GITFROK_ENROLMENT_TOKEN carries a literal value: — that persists the token into the Deployment"
    fi
  fi
fi

# --- 4. AC2: the DataPlane CR schema is reference-only and its status holds no credential --------
if [ ! -f "$crd" ]; then
  report "$crd is absent — the Operator seam has no CRD"
else
  if ! grep -q 'enrolmentSecretRef:' "$crd"; then
    report "CRD spec has no enrolmentSecretRef — enrolment must enter the CR as a reference"
  fi
  # status: no credential-shaped property may ever appear under the CR's status schema. status is
  # the schema's last section, so "from status: to EOF" is the whole of it. The anchored match
  # skips the `status: {}` subresource declaration, which is not the schema node.
  status_block=$(awk '/^[[:space:]]+status:[[:space:]]*$/{f=1} f' "$crd")
  for word in token secret credential privateKey certificatePem; do
    if printf '%s\n' "$status_block" | grep -qi "$word"; then
      report "CRD status schema mentions '$word' — CR status never holds credential material (AC2)"
    fi
  done
  # The spec's enrolment surface is a {name, key} reference and nothing more: an inline `token:`
  # property anywhere in the schema is a values-shaped hole for a secret.
  if grep -nE '^[[:space:]]+token:' "$crd"; then
    report "CRD schema declares a token property — enrolment is a Secret reference only"
  fi
fi

# --- 5. AC8: no inbound path into the customer's cluster -----------------------------------------
for f in "$templates"/*.yaml "$templates"/*.tpl; do
  [ -f "$f" ] || continue
  if grep -nE '^kind:[[:space:]]*(Service|Ingress|Gateway|HTTPRoute|TCPRoute|VirtualService)[[:space:]]*$' "$f"; then
    report "$f templates an inbound surface — the chart opens no door into the customer's cluster"
  fi
  if grep -nE '(hostNetwork|hostPort):[[:space:]]*true|[[:space:]]hostPort:' "$f"; then
    report "$f binds a host port or host network — that is an inbound path"
  fi
  if grep -nE 'type:[[:space:]]*(LoadBalancer|NodePort)' "$f"; then
    report "$f exposes a LoadBalancer/NodePort — that is an inbound path"
  fi
done

# --- 6. AC8: the backend agent wiring opens no listener -------------------------------------------
# The install-time agent (backend commit for T-0031) must consume the channel outbound only. If
# the backend pin predates that work the files are absent and we say so rather than fake a pass.
agent_files=("$root/backend/cmd/dataplane-app/agent.go" "$root/backend/platform/agentclient/agentclient.go")
# The Operator seam runs inside the customer's cluster too (T-0032/T-0041): its non-test Go
# sources get the same outbound-only scan, file by file, so a listener anywhere in the
# data-plane binaries is an inbound path regardless of which binary opens it.
for f in "$root"/backend/cmd/operator-app/*.go; do
  case "$f" in *_test.go) continue ;; esac
  [ -f "$f" ] && agent_files+=("$f")
done
missing=0
for f in "${agent_files[@]}"; do
  if [ ! -f "$f" ]; then missing=1; echo "byo-chart: note: $f absent (super-repo backend pin predates T-0031?)"; fi
done
if [ "$missing" -eq 0 ]; then
  for f in "${agent_files[@]}"; do
    if grep -nE 'net\.Listen|\.Serve\(|ListenAndServe' "$f"; then
      report "$f opens a listener — the data-plane agent dials OUT only (ADR-0011)"
    fi
  done
fi

# --- 7. AC3/AC4/AC6 (T-0032): the reconcile contract is named, not implied ----------------------
# The Operator converges spec.version onto the workload and reports actual state back. These
# tripwires hold the CRD/chart to that contract so it cannot silently regress:
#   - spec.version is the desired-state driver (the control plane publishes it, AC4).
#   - status carries exactly the rollout-report fields the backend feeds back (AC6):
#     observedVersion, phase, message, lastHeartbeatTime — never a version invented here.
#   - the operator mounts the release-signing trust bundle: signed-before-apply (AC3).
if ! grep -qE '^[[:space:]]+version:' "$crd"; then
  report "CRD spec has no version field — reconcile has no desired-state driver (SPEC-0039 AC4)"
fi
for fld in observedVersion phase message lastHeartbeatTime; do
  if ! printf '%s\n' "${status_block:-}" | grep -q "$fld:"; then
    report "CRD status schema lacks $fld — the rollout report has nowhere to land (SPEC-0039 AC6)"
  fi
done
op="$templates/operator.yaml"
if [ -f "$op" ]; then
  if ! grep -q 'GITFROK_RELEASE_TRUST_DIR' "$op"; then
    report "operator template does not mount a release trust root — it could apply an unsigned release (AC3)"
  fi
  if ! grep -q 'releaseTrust.configMap' "$op"; then
    report "operator template does not source the release trust bundle from operator.releaseTrust.configMap"
  fi
  # --- 7b. AC1 (T-0041): the operator is the vendor's digest-pinned image, not a customer input ---
  # The install stops depending on a customer-supplied operator image (SPEC-0045 AC1,
  # ADR-0065 decision 1): the template references the image ONLY as repository@digest,
  # requires no repository/tag values, and a mutable tag is not a legal reference.
  if grep -qE 'required "operator\.image\.(repository|tag)' "$op"; then
    report "operator template requires a customer-supplied operator image value — the operator ships only as the vendor's digest-pinned signed release (SPEC-0045 AC1)"
  fi
  # operator.image.tag may appear ONLY inside its retirement tripwire (the fail guard at the
  # template's head refuses a legacy values file); any OTHER reference is a regression.
  if grep -n 'operator.image.tag' "$op" | grep -vE 'fail |\.Values\.operator\.image\.tag' | grep -q .; then
    report "operator template references operator.image.tag outside its retirement tripwire — a mutable tag is never a legal operator image reference (SPEC-0045 AC1)"
  fi
  if ! grep -q 'fail.*operator\.image\.tag is retired' "$op"; then
    report "operator template lost its retirement tripwire — a legacy operator.image.tag must FAIL the install, never be silently discarded (SPEC-0045 AC1)"
  fi
  if ! grep -q 'operator.image.digest' "$op"; then
    report "operator template does not pin the operator image by operator.image.digest (SPEC-0045 AC1)"
  fi
  if ! grep -q 'operator.image.repository }}@' "$op"; then
    report "operator template does not render the operator image as repository@digest (SPEC-0045 AC1)"
  fi
  # values.yaml: the pin is a non-empty default, and the operator section declares no tag.
  if ! grep -qE '^[[:space:]]+digest:[[:space:]]*"sha256:[0-9a-f]{64}"' "$chart/values.yaml"; then
    report "values.yaml carries no defaulted operator.image.digest pin (sha256:...) — the install would depend on a customer-supplied image (SPEC-0045 AC1)"
  fi
  if awk '/^operator:/{f=1} f && /^[[:space:]]+tag:/{found=1} END{exit !found}' "$chart/values.yaml"; then
    report "values.yaml's operator section still declares an image tag — the operator is digest-pinned only (SPEC-0045 AC1)"
  fi
fi

# --- 8. rendered assertions (only with helm) -------------------------------------------------------
if command -v helm >/dev/null 2>&1; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/byo-chart.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  render="$tmp/rendered.yaml"
  sentinel="tok-harness-1qaz2wsx"

  if ! helm lint "$chart" \
      --set agent.gatewayAddr=agent.gitsaas.example:8443 \
      --set agent.caBundleConfigMap=gitfrok-agent-ca \
      --set policy.bundleConfigMap=gitfrok-policy-bundle \
      --set region=eu-west1 \
      --set enrolment.existingSecret.name=dp-enrolment \
      > "$tmp/lint.log" 2>&1; then
    report "helm lint failed:"; sed 's/^/  /' "$tmp/lint.log"
  fi

  if ! helm template test-release "$chart" \
      --set agent.gatewayAddr=agent.gitsaas.example:8443 \
      --set agent.caBundleConfigMap=gitfrok-agent-ca \
      --set policy.bundleConfigMap=gitfrok-policy-bundle \
      --set region=eu-west1 \
      --set enrolment.existingSecret.name=dp-enrolment \
      --set enrolment.token="$sentinel" \
      > "$render" 2> "$tmp/template.err"; then
    report "helm template failed:"; sed 's/^/  /' "$tmp/template.err"
  else
    if grep -q "$sentinel" "$render"; then
      report "a --set enrolment.token value reached the rendered manifests — the chart must ignore token literals"
    fi
    if grep -nE '^kind:[[:space:]]*(Secret|Service|Ingress)[[:space:]]*$' "$render"; then
      report "rendered manifests carry a Secret or inbound surface"
    fi
    if ! grep -q 'secretKeyRef' "$render"; then
      report "rendered Deployment does not source the token via secretKeyRef"
    fi
  fi

  # The operator-enabled shape (T-0041, SPEC-0045 AC1): with NO image values supplied the
  # chart must render the vendor's digest-pinned operator image — the install depends on
  # no customer-supplied operator image — and still render zero inbound surface.
  if ! helm template test-operator "$chart" \
      --set agent.gatewayAddr=agent.gitsaas.example:8443 \
      --set agent.caBundleConfigMap=gitfrok-agent-ca \
      --set policy.bundleConfigMap=gitfrok-policy-bundle \
      --set region=eu-west1 \
      --set enrolment.existingSecret.name=dp-enrolment \
      --set operator.enabled=true \
      --set operator.releaseTrust.configMap=gitfrok-release-trust \
      > "$tmp/render-operator.yaml" 2> "$tmp/template-op.err"; then
    report "helm template with operator.enabled=true failed (no image values supplied):"; sed 's/^/  /' "$tmp/template-op.err"
  else
    if ! grep -qE 'image:[[:space:]]*"?docker.io/gitfrok/operator-app@sha256:[0-9a-f]{64}' "$tmp/render-operator.yaml"; then
      report "rendered operator Deployment does not carry the vendor's digest-pinned image with zero image values supplied (SPEC-0045 AC1)"
    fi
    if grep -qE 'docker\.io/gitfrok/operator-app:[^@]' "$tmp/render-operator.yaml"; then
      report "the operator image is referenced by mutable tag instead of its digest pin"
    fi
    if grep -nE '^kind:[[:space:]]*(Secret|Service|Ingress)[[:space:]]*$' "$tmp/render-operator.yaml"; then
      report "rendered operator manifests carry a Secret or inbound surface"
    fi
  fi
  echo "byo-chart: helm assertions ran (helm $(helm version --short 2>/dev/null))"
else
  echo "byo-chart: helm not on PATH — rendered assertions NOT run; static assertions above still bind"
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "byo-chart: the install-time path is failable — SPEC-0039 AC2/AC8 (install scope), T-0031."
  exit 1
fi
echo "byo-chart: OK — chart carries no secret, token is reference-only input, no inbound path opened"
