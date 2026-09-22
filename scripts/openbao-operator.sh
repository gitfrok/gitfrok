#!/usr/bin/env bash
# openbao-operator.sh — the ADR-0066 decision 4 ceremony, as ONE command the share-holder runs.
#
# WHO RUNS THIS: a human operator, in their own terminal. Not CI, not an agent, not through any
# tool that records a transcript. The five Shamir shares and the initial root credential appear on
# this script's stdout/stderr path, and ADR-0066 decision 4 says they "never enter this repo, the
# cluster, or any environment file". A transcript is all three at once.
#
# WHAT IT DOES, in the order MVP-RUNBOOK §6a fixes:
#   init    `bao operator init -key-shares=5 -key-threshold=3` on openbao-0
#   unseal  feed the threshold to openbao-0 (leader first, so Raft can elect), then -1 and -2,
#           waiting for each standby to report Initialized before feeding it anything
#   wire    Kubernetes auth + the transit mount + the `agent-ca` policy and role
#   revoke  destroy the root credential, because nothing at runtime may use it
#
# TWO THINGS THIS DOES BETTER THAN THE RUNBOOK BLOCK IT IMPLEMENTS, deliberately:
#
#   1. THE ROOT CREDENTIAL NEVER TOUCHES DISK. §6a holds it in a shell variable `ROOT` and says
#      "never persisted"; a human running eleven commands by hand keeps it in scrollback the whole
#      time. Here it lives in one variable, is used for four writes, and is revoked before exit —
#      including on failure, via the EXIT trap. ADR-0066 decision 5 makes Kubernetes auth the only
#      client path, so a root credential that outlives this script authorizes nothing anyone needs
#      and everything an attacker wants.
#
#   2. THE SHARES ARE WRITTEN ONCE, TO A FILE YOU NAME, AT 0600. §6a says "distributed out of
#      band", which is correct and is not a procedure. The file is the handoff: split it across
#      five distinct holders and delete it. It is written with umask 077 and never echoed.
#
# WHAT IT DELIBERATELY DOES NOT DO: create the transit key. There is exactly one creator of
# `agent-ca` and it is the control plane, on first bootstrap, through the policy's create
# capability (MVP-RUNBOOK §6a, backend 7d5b693). A manual `bao write transit/keys/agent-ca` is
# out of procedure even though this script's root credential could do it.
#
# Usage:
#   scripts/openbao-operator.sh all    ~/gitfrok-openbao-shares.txt   # init + unseal + wire
#   scripts/openbao-operator.sh unseal ~/gitfrok-openbao-shares.txt   # every cold restart, after
#
# Environment: KUBECONFIG must point at the target cluster, and kubectl's current context must BE
# that cluster — the script passes no --context.
#   production:  . ~/.gitfrok/kube-path.sh prod-cp            (namespace gitfrok, TLS — the defaults)
#   dev cluster: KUBECONFIG=~/.kube/config GITFROK_NS=default \
#                GITFROK_OPENBAO_LOCAL_ADDR=http://127.0.0.1:8200 scripts/openbao-operator.sh all <file>
#
# Exit: 0 done · 1 refused or failed · 3 environment problem
set -euo pipefail

NS="${GITFROK_NS:-gitfrok}"
STS="${GITFROK_OPENBAO_STS:-openbao}"
REPLICAS="${GITFROK_OPENBAO_REPLICAS:-3}"
SHARES=5
THRESHOLD=3

# The consumer's identity, read from the control plane rather than assumed. A role bound to the
# wrong ServiceAccount name fails at login with the same 503 a sealed barrier gives, and that is a
# day of debugging nobody needs to spend twice.
ROLE="${GITFROK_CUSTODY_ROLE:-agent-ca}"
CONSUMER_SA="${GITFROK_CUSTODY_SA:-controlplane}"
TRANSIT_MOUNT="${GITFROK_CUSTODY_TRANSIT_MOUNT:-transit}"

# The barrier's own loopback address, as seen from INSIDE each pod. Production serves TLS on it
# (ADR-0104); the dev cluster runs `tls_disable = true` and answers plain HTTP, so an https address
# there fails the very first status check with a TLS handshake error. Loopback either way: the
# Service round-robins across nodes, and an unseal fed to the wrong node advances the wrong counter.
BAO_LOCAL_ADDR="${GITFROK_OPENBAO_LOCAL_ADDR:-https://127.0.0.1:8200}"

die() { printf 'openbao-operator: %s\n' "$1" >&2; exit "${2:-1}"; }

command -v kubectl >/dev/null 2>&1 || die "kubectl not on PATH" 3
[ -n "${KUBECONFIG:-}" ] || die "KUBECONFIG is unset — run: . ~/.gitfrok/kube-path.sh prod-cp" 3

mode="${1:-}"
outfile="${2:-}"
case "$mode" in
  all|init|unseal|wire) ;;
  *) die "usage: $0 {all|init|unseal|wire} <shares-file>" ;;
esac
[ -n "$outfile" ] || die "name the shares file, e.g. ~/gitfrok-openbao-shares.txt"

# bao in pod N, with the CA the pod already mounts. BAO_CACERT is set on the container
# (deploy/k8s/platform/base/openbao); only the address is missing, and it must be loopback —
# the Service round-robins across three nodes and an unseal fed to the wrong one silently
# advances the wrong node's progress counter.
bao_in() {
  local n="$1"; shift
  kubectl -n "$NS" exec -i "${STS}-${n}" -c openbao -- \
    env BAO_ADDR="$BAO_LOCAL_ADDR" bao "$@"
}
bao_root() {
  local n="$1"; shift
  kubectl -n "$NS" exec -i "${STS}-${n}" -c openbao -- \
    env BAO_ADDR="$BAO_LOCAL_ADDR" BAO_TOKEN="$ROOT" bao "$@"
}

# TWO THINGS ABOUT `bao status` THAT BREAK THE OBVIOUS IMPLEMENTATION, both measured against the
# live sealed barrier on 2026-09-23 rather than assumed:
#
#   1. IT EXITS 2 WHEN SEALED. Not 1, and not 0 — sealed is a reportable state, not an error, and
#      `bao` says so in its exit code. Under `set -o pipefail` a bare pipeline therefore fails, so
#      the output is captured FIRST and parsed second. Writing it as
#      `bao_in ... | python3 ... || echo unknown` appends "unknown" to the real answer, and every
#      later comparison silently fails against "False\nunknown".
#   2. THE JSON KEYS ARE LOWERCASE snake_case — `initialized`, `sealed` — while the human-readable
#      table prints `Initialized` and `Sealed`. Reading the table's spelling out of the JSON yields
#      None on every call, so the unseal loop would wait for a condition that can never be true and
#      die after its retry budget with the barrier initialised, the shares on disk, and the root
#      token still live.
status_field() {
  _out=$(bao_in "$1" status -format=json 2>/dev/null || true)
  [ -n "$_out" ] || { echo unknown; return 0; }
  printf '%s' "$_out" | python3 -c \
    "import json,sys
try: print(json.load(sys.stdin).get('$2'))
except Exception: print('unknown')" 2>/dev/null || echo unknown
}

ROOT=""
cleanup() {
  # The root credential is revoked whether we succeeded or not. A failed wiring run that leaves a
  # live root token behind is strictly worse than one that leaves nothing wired.
  #
  # ARMED ONLY WHERE A ROOT CREDENTIAL IS ACTUALLY USED. Revoking on every mode is a trap in the
  # other sense: `init` alone would try to revoke against a still-sealed barrier (harmless), and
  # then a later `unseal` alone would SUCCEED at revoking — destroying the credential `wire` has
  # not spent yet and leaving the cluster unwireable with the shares intact. `all` is the path.
  if [ -n "$ROOT" ]; then
    bao_root 0 token revoke -self >/dev/null 2>&1 || true
    printf 'openbao-operator: root credential revoked.\n'
    ROOT=""
  fi
}
case "$mode" in all|wire) trap cleanup EXIT ;; esac

# ---------------------------------------------------------------------------- init
if [ "$mode" = all ] || [ "$mode" = init ]; then
  init_state=$(status_field 0 initialized)
  if [ "$init_state" = "True" ]; then
    die "already initialised — init runs ONCE per cluster, ever. Use '$0 unseal $outfile'."
  fi
  printf 'openbao-operator: initialising %s shares, threshold %s (ADR-0066 decision 4)\n' "$SHARES" "$THRESHOLD"
  umask 077
  : > "$outfile"
  bao_in 0 operator init -key-shares="$SHARES" -key-threshold="$THRESHOLD" > "$outfile" \
    || die "bao operator init failed; $outfile may be partial — inspect and delete it"
  chmod 600 "$outfile"
  printf 'openbao-operator: shares written to %s (0600). Split them across five holders and DELETE it.\n' "$outfile"
fi

[ -r "$outfile" ] || die "cannot read $outfile"

# Parse without echoing. `bao operator init` prints "Unseal Key N: <share>" and
# "Initial Root Token: <token>".
#
# NOT `mapfile`. It is a bash 4+ builtin and macOS ships 3.2.57 and always will, where it parses
# cleanly and then does nothing — so KEYS would be empty and the first unseal would report a
# refused share rather than a missing one. scripts/portability-flags.tsv codifies exactly this.
KEYS=()
while IFS= read -r _share; do
  # `[ -n ... ] && KEYS[...]=...` would be the last command in this body, so a trailing blank line
  # makes the AND-list return 1 and `set -e` kills the script mid-parse. An `if` cannot.
  if [ -n "$_share" ]; then KEYS[${#KEYS[@]}]="$_share"; fi
done <<EOF
$(grep -E '^Unseal Key [0-9]+:' "$outfile" | sed 's/^[^:]*: *//')
EOF
ROOT=$(grep -E '^Initial Root Token:' "$outfile" | sed 's/^[^:]*: *//' || true)
[ "${#KEYS[@]}" -ge "$THRESHOLD" ] || die "$outfile holds ${#KEYS[@]} shares, need at least $THRESHOLD"

# ---------------------------------------------------------------------------- unseal
if [ "$mode" = all ] || [ "$mode" = unseal ]; then
  n=0
  while [ "$n" -lt "$REPLICAS" ]; do
    # A freshly started standby reports Initialized=false and REFUSES a share until it has pulled
    # the initialised Raft state from the leader via retry_join. Feeding it early is not an error
    # the operator sees — it is a refusal that looks like a wrong share (MVP-RUNBOOK §6a).
    tries=0
    while [ "$(status_field "$n" initialized)" != "True" ]; do
      tries=$((tries + 1))
      [ "$tries" -lt 60 ] || die "${STS}-${n} never reported Initialized — check retry_join"
      printf '  waiting for %s-%s to join the raft (%s)\n' "$STS" "$n" "$tries"
      python3 -c 'import time; time.sleep(2)'
    done
    if [ "$(status_field "$n" sealed)" = "False" ]; then
      printf '  %s-%s already unsealed\n' "$STS" "$n"
      n=$((n + 1)); continue
    fi
    i=0
    while [ "$i" -lt "$THRESHOLD" ]; do
      bao_in "$n" operator unseal -- "${KEYS[$i]}" >/dev/null 2>&1 \
        || die "share $((i + 1)) refused by ${STS}-${n}"
      i=$((i + 1))
    done
    [ "$(status_field "$n" sealed)" = "False" ] || die "${STS}-${n} still sealed after $THRESHOLD shares"
    printf '  %s-%s unsealed\n' "$STS" "$n"
    n=$((n + 1))
  done
fi

# ---------------------------------------------------------------------------- wire
if [ "$mode" = all ] || [ "$mode" = wire ]; then
  [ -n "$ROOT" ] || die "no root credential in $outfile — wiring needs the initial root token"

  # Every write below is idempotent: re-running after a partial failure must converge, not refuse.
  if ! bao_root 0 auth list -format=json 2>/dev/null | grep -q '"kubernetes/"'; then
    bao_root 0 auth enable kubernetes >/dev/null || die "auth enable kubernetes failed"
  fi
  bao_root 0 write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443" >/dev/null \
    || die "auth/kubernetes/config failed"

  if ! bao_root 0 secrets list -format=json 2>/dev/null | grep -q "\"${TRANSIT_MOUNT}/\""; then
    bao_root 0 secrets enable -path="$TRANSIT_MOUNT" transit >/dev/null || die "secrets enable transit failed"
  fi

  # Create, read, update on the key; update on sign. NOT delete, and NOT export — the key is
  # non-exportable by construction and the policy should not pretend otherwise.
  printf 'path "%s/keys/%s*" { capabilities = ["create", "read", "update"] }\npath "%s/sign/%s*" { capabilities = ["update"] }\n' \
    "$TRANSIT_MOUNT" "$ROLE" "$TRANSIT_MOUNT" "$ROLE" \
    | bao_root 0 policy write "$ROLE" - >/dev/null || die "policy write failed"

  # bound_service_account_namespaces is the NAMESPACE THE CONTROL PLANE ACTUALLY RUNS IN. §6a says
  # `default` because that is the dev cluster; production is `gitfrok`, and a role bound to the
  # wrong namespace fails login with a 503 indistinguishable from a sealed barrier.
  bao_root 0 write "auth/kubernetes/role/$ROLE" \
    bound_service_account_names="$CONSUMER_SA" \
    bound_service_account_namespaces="$NS" \
    policies="$ROLE" ttl=1h >/dev/null || die "role write failed"

  printf 'openbao-operator: kubernetes auth, %s mount, policy %s and role %s wired (ns=%s sa=%s)\n' \
    "$TRANSIT_MOUNT" "$ROLE" "$ROLE" "$NS" "$CONSUMER_SA"
  printf 'openbao-operator: the transit key was NOT created here — the control plane is its only creator.\n'
fi

cleanup
printf 'openbao-operator: done. Restart the control plane: kubectl -n %s rollout restart deploy/controlplane\n' "$NS"
