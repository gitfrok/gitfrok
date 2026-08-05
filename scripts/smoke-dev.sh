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
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${MINIKUBE_PROFILE:-gitfrok}"
HOST="${SMOKE_HOST:-hello.gitsaas.test}"
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

case "$rc" in
  0)
    if [ "$code" = "200" ]; then
      ok "GET https://$HOST/ -> 200, certificate validated against the mkcert CA"
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
    # Resolution failed. Re-run pinning the host to the cluster IP: if that works, ingress and TLS
    # are fine and only host DNS is missing — a different fix, and not a cluster fault.
    if [ -n "$IP" ]; then
      request --resolve "$HOST:443:$IP"
      if [ "$rc" = "0" ] && [ "$code" = "200" ]; then
        report "host DNS is not wired: ingress + TLS work (200 with --resolve $HOST:443:$IP) but
    '$HOST' does not resolve. Point a resolver for the .test TLD at $IP — scripts/dev-up.sh
    prints the snippet for this OS — or add it to /etc/hosts. AC3's ingress half passes."
      else
        report "'$HOST' does not resolve, and pinning it to $IP did not work either (rc=$rc code=$code)"
      fi
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

if [ "$fail" -ne 0 ]; then
  echo "smoke: FAIL"
  exit 1
fi
echo "smoke: OK (AC2 workloads + images, AC3 TLS over ingress)"
