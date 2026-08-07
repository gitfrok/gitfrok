#!/usr/bin/env bash
# T-0003 integration smoke test: the dev cluster is actually up, and reachable over real TLS.
#
# Maps onto the acceptance criteria:
#   AC2 — every deployment is Available, and the images the pods are *running* match versions.env
#   AC3 — https://hello.gitsaas.test returns 200, with the certificate validated against the mkcert
#         root CA (never `curl -k`: skipping verification would pass even with TLS broken, which is
#         the one thing this test exists to prove)
#
# A failure distinguishes "ingress/TLS is broken" from "host DNS is not wired", because those have
# completely different fixes and only the first is the cluster's fault.
#
# Usage: smoke-dev.sh
# Env:   MINIKUBE_PROFILE (default: gitfrok)   SMOKE_HOST (default: hello.gitsaas.test)
#        SMOKE_PROBES (default: 6) — see AC3_PROBES below
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${MINIKUBE_PROFILE:-gitfrok}"
HOST="${SMOKE_HOST:-hello.gitsaas.test}"
# One 200 does not prove the ingress is healthy, because the failure this guards against is
# *intermittent*. ingress-nginx once ran with more nginx workers than the pod's cgroup had PIDs for;
# the workers that died left the survivors still accepting connections and never answering, so 4 of 6
# requests hung and 2 returned a clean 200. A single-probe smoke test had roughly a one-in-three
# chance of reporting OK against that. Probing repeatedly and demanding every probe pass turns a coin
# flip into a verdict.
AC3_PROBES="${SMOKE_PROBES:-6}"
NS=default
TLS_SECRET=gitsaas-tls
EXPECT_BODY='hello over TLS'
KUBECTL=(kubectl --context "$PROFILE")

fail=0
report() { echo "SMOKE FAILURE: $1"; fail=1; }
ok()     { echo "  ok    $1"; }

for cmd in kubectl curl mkcert minikube; do
  command -v "$cmd" >/dev/null || { echo "smoke: FAIL — $cmd not installed"; exit 1; }
done

# A missing context is not a broken cluster, and this script used to be unable to tell the two apart.
# Every query below is `... 2>/dev/null || true`, and `kubectl --context <nonexistent>` errors rather
# than returning data — so pointing at a context that does not exist produced six "no available
# replica" failures and an unreadable verdict. Observed for real: a cluster created by hand as profile
# 'minikube' reported all six deployments down under this script's default profile of 'gitfrok'.
# Checked once, up front, so the failure names the actual problem.
if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "$PROFILE"; then
  echo "smoke: FAIL — no kubectl context named '$PROFILE', so there is nothing to smoke-test."
  have=$(kubectl config get-contexts -o name 2>/dev/null | tr '\n' ' ')
  echo "  contexts on this machine: ${have:-none}"
  echo "  fix: scripts/dev-up.sh creates profile '$PROFILE', or target an existing cluster with"
  echo "       MINIKUBE_PROFILE=<name> make dev-smoke"
  exit 1
fi

set -a
# shellcheck disable=SC1091  # data file, not a script — nothing for shellcheck to follow
. ./deploy/dev/versions.env
set +a

# ------------------------------------------------------------------ AC2: workloads are up
echo "AC2 — deployments Available"
for d in postgres valkey redpanda seaweedfs zitadel hello; do
  # .status.availableReplicas is absent (not 0) before the first pod is ready, hence the default.
  avail=$("${KUBECTL[@]}" get "deployment/$d" -n "$NS" \
            -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
  if [ "${avail:-0}" -ge 1 ] 2>/dev/null; then
    ok "deployment/$d available"
  else
    report "deployment/$d has no available replica — kubectl describe deployment/$d -n $NS"
  fi
done

# ------------------------------------------------------- AC2: running images match versions.env
# dev-up.sh asserts this against the manifest text; this asserts it against what the cluster is
# actually running, which is the claim AC2 makes. A stale ReplicaSet or a hand-edited deployment
# would pass the first check and fail this one.
echo "AC2 — running images match versions.env"
running=$("${KUBECTL[@]}" get pods -n "$NS" -o \
  jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
  2>/dev/null | sed '/^$/d' | sort -u)
expected=$(printf '%s\n' "$POSTGRES_IMAGE" "$VALKEY_IMAGE" "$REDPANDA_IMAGE" \
  "$SEAWEEDFS_IMAGE" "$ZITADEL_IMAGE" "$BUSYBOX_IMAGE" | sort -u)

unexpected=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$running"))
missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$running"))
if [ -n "$unexpected" ]; then
  report "pods running images absent from versions.env: $(echo "$unexpected" | tr '\n' ' ')"
fi
if [ -n "$missing" ]; then
  report "versions.env images with no running pod: $(echo "$missing" | tr '\n' ' ')"
fi
[ -n "$unexpected$missing" ] || ok "$(echo "$running" | wc -l | tr -d ' ') images, all from versions.env"

# ------------------------------------------------------------------ AC3: TLS secret is present
echo "AC3 — mkcert TLS over ingress"
secret_type=$("${KUBECTL[@]}" get "secret/$TLS_SECRET" -n "$NS" \
                -o jsonpath='{.type}' 2>/dev/null || true)
if [ "$secret_type" = "kubernetes.io/tls" ]; then
  ok "secret/$TLS_SECRET present"
else
  report "secret/$TLS_SECRET missing or wrong type (got '${secret_type:-none}') — run scripts/dev-up.sh"
fi

# A deterministic check for the specific regression the repeated probes only catch statistically.
# nginx defaults `worker_processes` to the host CPU count, which on a machine with enough cores
# exceeds the PIDs the controller pod's cgroup allows; dev-up.sh pins it instead. This asserts the
# pin is still there, so a cluster brought up by an older dev-up.sh — or one where the ConfigMap was
# hand-edited — is named as the cause rather than left to show up as an intermittent timeout.
worker_procs=$("${KUBECTL[@]}" get configmap ingress-nginx-controller -n ingress-nginx \
                 -o jsonpath='{.data.worker-processes}' 2>/dev/null || true)
if [ -n "$worker_procs" ]; then
  ok "ingress-nginx worker-processes pinned to $worker_procs"
else
  report "ingress-nginx ConfigMap has no 'worker-processes' — nginx will default to this host's CPU
    count, which can exceed the pod's PID limit and leave the ingress accepting connections it never
    answers. Re-run scripts/dev-up.sh, which pins it."
fi

CA="$(mkcert -CAROOT)/rootCA.pem"
[ -f "$CA" ] || report "mkcert root CA not found at $CA — run 'mkcert -install'"

IP=$(minikube ip -p "$PROFILE" 2>/dev/null || true)
body=$(mktemp)
trap 'rm -f "$body"' EXIT

# Bounded retry: ingress-nginx needs a moment to program a newly applied host, and a smoke test that
# flakes on a cold ingress teaches people to ignore it. Only transient shapes are retried — a TLS
# or DNS failure is reported immediately, because retrying will not change it.
request() { # request [extra curl args...] -> sets rc, code
  rc=0
  code=$(curl -sS --cacert "$CA" -o "$body" -w '%{http_code}' \
           --max-time 20 "$@" "https://$HOST/" 2>/dev/null) || rc=$?
}

# Repeat a request that has already succeeded once, and record every probe that does not come back
# 0:200. Deliberately not retried: a retry here would paper over exactly the flapping being measured.
# Leaves rc/code set to the last *failing* probe when there is one, so the caller's existing
# per-exit-code diagnosis still fires on the right shape.
probe_repeatedly() { # probe_repeatedly [extra curl args...] -> sets probe_fails, probe_shapes
  probe_fails=0
  probe_shapes=""
  probe_n=1
  while [ "$probe_n" -lt "$AC3_PROBES" ]; do
    probe_n=$((probe_n + 1))
    request "$@"
    if [ "$rc" != "0" ] || [ "$code" != "200" ]; then
      probe_fails=$((probe_fails + 1))
      probe_shapes="$probe_shapes rc=$rc/code=$code"
      last_rc=$rc
      last_code=$code
    fi
  done
  if [ "$probe_fails" -eq 0 ]; then
    rc=0
    code=200
  else
    rc=$last_rc
    code=$last_code
  fi
}

tries=0
while : ; do
  request
  tries=$((tries + 1))
  case "$rc:$code" in
    0:200)            break ;;
    7:*|0:404|0:502|0:503) [ "$tries" -lt 15 ] || break; sleep 2 ;;
    *)                break ;;
  esac
done

# The warm-up loop above is allowed to retry, so its 200 only means "answered at least once". Confirm
# the ingress answers *consistently* before believing it.
probe_fails=0
probe_shapes=""
if [ "$rc" = "0" ] && [ "$code" = "200" ]; then
  probe_repeatedly
fi

if [ "$probe_fails" -ne 0 ]; then
  report "ingress answers intermittently: $probe_fails of $AC3_PROBES probes to https://$HOST/ failed
    ($(printf '%s' "${probe_shapes# }")) while the others returned 200. An ingress that answers
    sometimes is not a passing AC3, and a single probe would have called this OK.
    A hung probe (rc=28) with the connection still being accepted usually means the ingress-nginx
    workers are dying: kubectl logs -n ingress-nginx deploy/ingress-nginx-controller | grep -i alert"
else
case "$rc" in
  0)
    if [ "$code" = "200" ]; then
      ok "GET https://$HOST/ -> 200 on all $AC3_PROBES probes, certificate validated against the mkcert CA"
      if grep -q "$EXPECT_BODY" "$body"; then
        ok "response body is the hello fixture"
      else
        report "200 from https://$HOST/ but body is not the hello fixture — something else answered:
    $(head -c 200 "$body")"
      fi
    else
      report "GET https://$HOST/ -> HTTP $code (want 200); ingress reached but the backend did not answer"
    fi
    ;;
  6)
    # Resolution failed. Re-run pinning the host to an address that should reach ingress: if that
    # works, ingress and TLS are fine and only host DNS is missing — a different fix, and not a
    # cluster fault.
    #
    # Two candidates, in this order, because which one works depends on the driver's rootlessness:
    #
    #   127.0.0.1  — the node's 80/443 published to the host (dev-up.sh's MINIKUBE_PORTS). This is
    #                the only one that works under *rootless* podman, where the node IP sits in a
    #                namespace the host cannot route into. Tried first for that reason.
    #   $IP        — the node IP. Correct on a rootful driver, and the only option when the cluster
    #                was created without published ports.
    #
    # The previous version tried the node IP alone and concluded from its `rc=28` timeout that AC3
    # needed a rootful driver or KVM. It did not — it needed the ports published. Reporting only the
    # unroutable address turned a fixable setup gap into a wrong architectural conclusion.
    # Probed repeatedly for the same reason the direct path is: this branch is where the claim
    # "AC3's ingress half passes" gets made, and one 200 is not enough to make it.
    pinned=""
    for candidate in 127.0.0.1 "$IP"; do
      [ -n "$candidate" ] || continue
      request --resolve "$HOST:443:$candidate"
      if [ "$rc" = "0" ] && [ "$code" = "200" ]; then
        probe_repeatedly --resolve "$HOST:443:$candidate"
        pinned="$candidate"
        break
      fi
    done
    if [ -n "$pinned" ] && [ "$probe_fails" -ne 0 ]; then
      report "ingress answers intermittently when pinned to $pinned: $probe_fails of $AC3_PROBES
    probes failed ($(printf '%s' "${probe_shapes# }")). Host DNS is also unwired, but fix the
    flapping first — kubectl logs -n ingress-nginx deploy/ingress-nginx-controller | grep -i alert"
    elif [ -n "$pinned" ]; then
      report "host DNS is not wired: ingress + TLS work ($AC3_PROBES/$AC3_PROBES probes returned 200
    with --resolve $HOST:443:$pinned) but '$HOST' does not resolve. Add it to /etc/hosts pointing at
    $pinned, or point a resolver for the .test TLD there — scripts/dev-up.sh prints the snippet for
    this OS. AC3's ingress half passes."
    elif [ -n "$IP" ]; then
      report "'$HOST' does not resolve, and pinning it to 127.0.0.1 or $IP did not work either
    (last rc=$rc code=$code). If the cluster was created without published ports, re-run
    scripts/dev-up.sh — under a rootless driver the node IP alone is not reachable from the host."
    else
      report "'$HOST' does not resolve and 'minikube ip -p $PROFILE' gave nothing — is the cluster up?"
    fi
    ;;
  60)
    report "TLS verification failed against $CA. The ingress is serving a certificate this CA did
    not sign — re-run scripts/dev-up.sh to reissue secret/$TLS_SECRET, and check 'mkcert -install'
    has been run for this user."
    ;;
  7)
    report "connection refused at https://$HOST/ after $tries tries — the ingress-nginx controller
    is not accepting traffic. kubectl get pods -n ingress-nginx"
    ;;
  *)
    report "curl failed with exit $rc (HTTP '$code') for https://$HOST/"
    ;;
esac
fi

if [ "$fail" -ne 0 ]; then
  echo "smoke: FAIL"
  exit 1
fi
echo "smoke: OK (AC2 workloads + images, AC3 TLS over ingress)"
