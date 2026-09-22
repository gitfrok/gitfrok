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
# No standalone `init`: init without wiring would revoke the only root credential at exit and
# leave a barrier nobody can wire (OpenBao refuses unauthenticated root generation by default).
case "$mode" in
  all|unseal|wire) ;;
  *) die "usage: $0 {all|unseal|wire} <shares-file>" ;;
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
# Defined before the trap is armed: under `set -u` a trap that reads an unset ROOT would itself fail.
ROOT=""
case "$mode" in all|wire) trap cleanup EXIT ;; esac

# ---------------------------------------------------------------------------- init
if [ "$mode" = all ]; then
  init_state=$(status_field 0 initialized)
  if [ "$init_state" = "True" ]; then
    # `all` is RE-RUNNABLE. A run that initialised and then stopped part-way (a standby slow to
    # unseal, a network blip) must be recoverable by running the same command again — not by an
    # operator composing a different one under pressure. Init is skipped; unseal and wire continue.
    printf 'openbao-operator: already initialised — skipping init, continuing with unseal and wire\n'
    [ -r "$outfile" ] || die "already initialised but $outfile is not readable — the shares live there"
  else
    printf 'openbao-operator: initialising %s shares, threshold %s (ADR-0066 decision 4)\n' "$SHARES" "$THRESHOLD"
    umask 077
    # The init output holds the shares AND the initial root credential. Only the shares go to the
    # file. The first version redirected the whole output there while this header promised the
    # root credential "never touches disk" — it did, in the same file as the shares.
    _init=$(bao_in 0 operator init -key-shares="$SHARES" -key-threshold="$THRESHOLD") \
      || die "bao operator init failed — check whether the barrier initialised before retrying"
    : > "$outfile"
    chmod 600 "$outfile"
    printf '%s\n' "$_init" | grep -E '^Unseal Key [0-9]+:' > "$outfile" \
      || die "init output held no shares — NOT written anywhere else; re-init is impossible, inspect the barrier"
    ROOT=$(printf '%s\n' "$_init" | grep -E '^Initial Root Token:' | sed 's/^[^:]*: *//' || true)
    _init=""
    printf 'openbao-operator: shares written to %s (0600). Split them across five holders and DELETE it.\n' "$outfile"
  fi
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
[ "${#KEYS[@]}" -ge "$THRESHOLD" ] || die "$outfile holds ${#KEYS[@]} shares, need at least $THRESHOLD"

# A shares file written by the first version of this script also holds an "Initial Root Token"
# line. That credential was revoked when the run ended, so it is dead — but it is still a root
# token sitting beside the shares, and nothing below reads it. Scrub it, portably (no `sed -i`).
if grep -qE '^Initial Root Token:' "$outfile"; then
  _tmp="$outfile.tmp.$$"
  ( umask 077; grep -vE '^Initial Root Token:' "$outfile" > "$_tmp" ) && mv "$_tmp" "$outfile" && chmod 600 "$outfile"
  printf 'openbao-operator: removed a stale root-token line from %s (it was already revoked)\n' "$outfile"
fi

# ---------------------------------------------------------------------------- unseal one node
unseal_node() {
  n="$1"
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
    return 0
  fi
  i=0
  while [ "$i" -lt "$THRESHOLD" ]; do
    bao_in "$n" operator unseal -- "${KEYS[$i]}" >/dev/null 2>&1 \
      || die "share $((i + 1)) refused by ${STS}-${n}"
    i=$((i + 1))
  done
  # THE THIRD SHARE DOES NOT UNSEAL A JOINING STANDBY SYNCHRONOUSLY. Measured on the dev cluster
  # on 2026-09-23: openbao-1 reported sealed immediately after its third share, the first version
  # of this script died on that, and the node logged "post-unseal setup complete" about a second
  # later. So poll, briefly, before calling it a failure.
  tries=0
  while [ "$(status_field "$n" sealed)" != "False" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 30 ] || die "${STS}-${n} still sealed 30s after $THRESHOLD shares"
    python3 -c 'import time; time.sleep(1)'
  done
  printf '  %s-%s unsealed\n' "$STS" "$n"
}

# ---------------------------------------------------------------------------- wire
wire() {
  if [ -z "$ROOT" ]; then
    # No root credential from this run's init. OpenBao can mint one from a quorum of shares —
    # BUT `disable_unauthed_generate_root_endpoints` DEFAULTS TO TRUE in OpenBao 2.x, and then the
    # attempt is refused with 403 (measured on the dev image, 2026-09-23). That is a sound default
    # and this script does not weaken it; it says what the choices are instead.
    printf 'openbao-operator: minting a one-time root credential from %s shares (generate-root)\n' "$THRESHOLD"
    bao_in 0 operator generate-root -cancel >/dev/null 2>&1 || true
    _g=$(bao_in 0 operator generate-root -init -format=json 2>&1) || die "generate-root is refused by this barrier:
    $(printf '%s' "$_g" | grep -m1 -iE 'denied|error' )
  OpenBao disables unauthenticated root generation by default (disable_unauthed_generate_root_endpoints).
  The barrier IS UNSEALED. Whether it is wired cannot be checked without a root credential:
    - if the run that initialised it finished ("wired" and "root credential revoked" printed),
      it is wired and nothing more is needed. For restarts, use '$0 unseal <file>', not 'all'.
    - if that run stopped before wiring, no root credential exists to wire it with:
        dev, where the barrier holds nothing yet: delete the openbao PVCs and re-run '$0 all <file>'
        otherwise: set disable_unauthed_generate_root_endpoints = false in the server config for the
        duration, restart and unseal, re-run '$0 wire <file>', then set it back — an owner decision"
    _nonce=$(printf '%s' "$_g" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nonce"])')
    _otp=$(printf '%s' "$_g" | python3 -c 'import json,sys; print(json.load(sys.stdin)["otp"])')
    _g=""; _enc=""; i=0
    while [ "$i" -lt "$THRESHOLD" ]; do
      _r=$(bao_in 0 operator generate-root -format=json -nonce="$_nonce" -- "${KEYS[$i]}") \
        || die "generate-root refused share $((i + 1))"
      _enc=$(printf '%s' "$_r" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("encoded_token") or d.get("encoded_root_token") or "")')
      i=$((i + 1))
    done
    _r=""
    [ -n "$_enc" ] || die "generate-root completed without an encoded credential"
    ROOT=$(bao_in 0 operator generate-root -decode="$_enc" -otp="$_otp") || die "generate-root -decode failed"
    _enc=""; _otp=""; _nonce=""
    [ -n "$ROOT" ] || die "generate-root produced an empty credential"
  fi

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
}

# ---------------------------------------------------------------------------- the order
# WIRE BEFORE THE STANDBYS, and this ordering is the fix for a real failure. The first version
# unsealed all three nodes and only then wired. On 2026-09-23 a standby was slow to report unsealed,
# the script died, the EXIT trap revoked the root credential — and OpenBao's default refuses to mint
# another from the shares. Result: a barrier unsealed and permanently unwireable without a config
# change. Wiring needs only the ACTIVE node (openbao-0, unsealed first so Raft elects it), so the root
# credential is spent and revoked before any standby can fail.
case "$mode" in
  all)
    if [ -n "$ROOT" ]; then
      # This run initialised: a root credential exists and must be spent before anything else can
      # fail. Active node, wire, revoke — then the standbys.
      unseal_node 0
      wire
      cleanup
      n=1; while [ "$n" -lt "$REPLICAS" ]; do unseal_node "$n"; n=$((n + 1)); done
    else
      # Already initialised: no root credential is at risk, so unseal EVERYTHING first. The re-run
      # is most often an unseal after a restart, and it must not leave standbys sealed just because
      # the (already done, or now impossible) wiring step comes afterwards.
      n=0; while [ "$n" -lt "$REPLICAS" ]; do unseal_node "$n"; n=$((n + 1)); done
      wire
    fi
    ;;
  unseal)
    n=0; while [ "$n" -lt "$REPLICAS" ]; do unseal_node "$n"; n=$((n + 1)); done
    ;;
  wire)
    wire
    ;;
esac

cleanup
printf 'openbao-operator: done. Restart the control plane: kubectl -n %s rollout restart deploy/controlplane\n' "$NS"
