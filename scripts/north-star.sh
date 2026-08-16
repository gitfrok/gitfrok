#!/bin/bash
# North Star Stage D proof — the full journey on the live dev cluster.
#
# WHAT THIS PROVES (on minikube profile gitfrok, context gitfrok, namespace default):
#   dev-smoke green -> custody unsealed + CA attached -> enrolment token minted through the
#   :9094 door by the dev-tenant OWNER -> data plane self-enrols -> residency declared
#   through :9093 -> usage view honest through :9092 -> controlplane restart survives on the
#   snapshot (spent token + declaration durable) -> an evidence pack assembles -> the RUNBOOK
#   §8a git flow (clone/push/protection denial/MR/approve/merge) over https://git.gitsaas.test.
#
# HONEST LIMITS THIS SCRIPT CARRIES (printed at the end, never faked):
#   - one node: failover-promotes-replica and durable-push replica ack stay "no"
#   - no gVisor RuntimeClass under rootless podman: CI-jobs-gate-merge stays "no"
#   - GITFROK_CLOUD=gke is a DEV FICTION (deploy/dev/dataplane.yaml annotates it)
#   - the release-trust door is deliberately NOT mounted (no dev-safe seed)
#   - the enrolment door's PDP grants issuance to OWNER ONLY; the owner PAT it uses is
#     dev-provision.sh's durable-store credential (secret gitfrok-owner-pat), never a
#     weakening of the grant
#
# FAILURE CLASSES (one per step; a step either PASSes or dies with its class):
#   1 SMOKE_RED · 2 CUSTODY_UNAVAILABLE · 3 ISSUANCE_REFUSED · 4 SELF_ENROLMENT_FAILED
#   5 RESIDENCY_REFUSED · 6 USAGE_VIEW_BROKEN · 7 DURABILITY_LOST · 8 EVIDENCE_UNAVAILABLE
#   9 GIT_FLOW_BROKEN
#
# Portability: bash 3.2 / BSD userland (SPEC-0014). No GNU-only flags.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
KUBECTL=(kubectl --context gitfrok -n default)
CONTRACTS="$ROOT/governance/contracts"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/north-star.XXXXXX")
RUN_ID=$(date +%s)

pf_pids=()
step_names=()
step_verdicts=()

cleanup() {
  local pid
  if [ ${#pf_pids[@]} -gt 0 ]; then
    for pid in "${pf_pids[@]}"; do
      kill "$pid" >/dev/null 2>&1 || true
    done
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

die() { # die <FAILURE_CLASS> <message>
  echo
  echo "north-star: FAIL [$1] — $2" >&2
  echo "north-star: verdict stopped at step ${#step_verdicts[@]} of 9; earlier steps:"
  print_verdicts
  exit 1
}

step_begin() { # step_begin <n> <name>
  echo
  echo "=== north-star step $1: $2 ==="
}

step_pass() { # step_pass <name> <evidence note>
  step_names[${#step_names[@]}]="$1"
  step_verdicts[${#step_verdicts[@]}]="PASS"
  echo "--- step $1 PASS: $2"
}

print_verdicts() {
  local i=0
  while [ "$i" -lt ${#step_verdicts[@]} ]; do
    echo "  step $((i + 1)) ${step_verdicts[$i]} — ${step_names[$i]}"
    i=$((i + 1))
  done
}

kctl() { "${KUBECTL[@]}" "$@"; }

psqlq() { # psqlq <sql> — RLS-scoped dev-tenant query, SET noise stripped
  kctl exec deploy/postgres -- psql -U gitfrok_app -d gitfrok -tAc \
    "SET app.tenant_id='dev'; $1" 2>/dev/null | sed '/^SET$/d'
}

json_get() { # json_get <json> <dot.path> — prints the value ('' when absent);
              # accepts proto snake_case and grpcurl's camelCase alike
  printf '%s' "$1" | python3 -c '
import json, sys
def camel(s):
    parts = s.split("_")
    return parts[0] + "".join(p.title() for p in parts[1:])
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    if isinstance(d, dict):
        if k in d:
            d = d[k]
        elif camel(k) in d:
            d = d[camel(k)]
        else:
            sys.exit(3)
    else:
        sys.exit(3)
sys.stdout.write(d if isinstance(d, str) else json.dumps(d))
' "$2" 2>/dev/null || true
}

grpc() { # grpc <proto-relpath> <addr> <service.Method> [extra grpcurl args...]
  local proto=$1 addr=$2 method=$3
  shift 3
  grpcurl -plaintext -import-path "$CONTRACTS" -proto "$proto" "$@" "$addr" "$method"
}

grpc_try() { # grpc_try <errfile> <proto> <addr> <method> [args...] — 3 attempts (a
             # freshly established port-forward can drop the very first dial)
  local errfile=$1 n=0
  shift
  while [ "$n" -lt 3 ]; do
    if grpc "$@" 2>"$errfile"; then return 0; fi
    n=$((n + 1))
    sleep 2
  done
  return 1
}

ensure_bare_repo() { # ensure_bare_repo <repo> — storage serves only EXISTING bare repos
                     # (git-storaged prepareWith: os.Stat must pass; the git/v1 contract has
                     # no create-repository RPC). RUNBOOK §8a's documented recovery is to
                     # re-create the bare repo; the storage PVC was wiped before this stage
                     # (dir empty since Aug 15), so the journey re-creates it here — a dev
                     # recovery step, never a weakening of any gate.
  kctl exec deploy/git-storaged -- sh -c \
    "mkdir -p /var/lib/gitfrok/repositories/dev/$1.git && cd /var/lib/gitfrok/repositories/dev/$1.git && git init -q --bare -b main" >/dev/null 2>&1
}

ingest_clean_scan() { # ingest_clean_scan <revision> <request-id> <scan-stamp> — the security merge gate
                      # (T-0025/SPEC-0029) is ENGAGED by construction on this plane: a merge
                      # fails closed unless attribution is materialized, and attribution needs a
                      # scan report at BOTH the head revision and the merge-base revision
                      # (security/internal/app/merge_facts.go). Ingesting a clean (zero-finding)
                      # scan at a revision is the journey's honest prerequisite — the same gate
                      # fact the read surface renders, never a weakening of the gate.
  grpc proto/security/v1/findings.proto 127.0.0.1:19090 \
    gitsaas.security.v1.FindingsService.IngestScanResults \
    -d "{\"context\":{\"tenant_id\":\"dev\",\"repository_id\":\"$REPO\",\"actor_id\":\"user-admin\",\"actor_roles\":[\"owner\"],\"request_id\":\"$2\"},\"revision\":\"$1\",\"scan\":{\"scanner_class\":\"SCANNER_CLASS_SAST\",\"tool_name\":\"north-star-sast\",\"tool_version\":\"1.0\",\"scan_started_at\":\"$3\",\"scan_ended_at\":\"$3\"},\"findings\":[],\"chunk_index\":0,\"final_chunk\":true}" >/dev/null
}

setup_repo() { # setup_repo — the dataplane's identity store is in-memory (RUNBOOK §8a):
               # the dataplane restart in step 4 cleared every PAT, so the flow mints a
               # fresh one through the identity door — exactly the §8a shape.
  local pat_out
  pat_out=$(grpc_try "$WORK/pat.err" proto/identity/v1/identity.proto 127.0.0.1:19090 \
    gitsaas.identity.v1.CredentialAuthenticator.IssuePAT \
    -d '{"tenant_id":"dev","actor_id":"user-admin","label":"north-star","scope_labels":["repo.read","repo.write"],"roles":["owner"]}') \
    || return 1
  GIT_PAT=$(json_get "$pat_out" plaintext_token)
  [ -n "$GIT_PAT" ] || return 1

  CA_PEM=$(mkcert -CAROOT)/rootCA.pem
  [ -f "$CA_PEM" ] || return 1
  export GIT_SSL_CAINFO="$CA_PEM"

  RDIR="$WORK/repo"
  git init -q "$RDIR" || return 1
  git -C "$RDIR" config user.email "north-star@gitsaas.test"
  git -C "$RDIR" config user.name "north-star proof"
  # The credential is in the URL; keep host credential helpers out of the flow —
  # macOS git tries osxkeychain and a store refusal would read as an auth failure.
  # An empty repo-level value RESETS the helper list, so no system/global helper runs.
  git -C "$RDIR" config credential.helper ""
  printf 'north star stage D\n' >"$RDIR/README"
  git -C "$RDIR" add README
  git -C "$RDIR" commit -qm "north-star: seed"
  git -C "$RDIR" branch -M main
  git -C "$RDIR" remote add origin "https://admin:$GIT_PAT@git.gitsaas.test/git/dev/$REPO.git"
  ensure_bare_repo "$REPO" || return 1
  git -C "$RDIR" push -q origin main 2>"$WORK/push1.err" || return 1
  MAIN_REV=$(git -C "$RDIR" rev-parse HEAD)
  # The merge gate needs the merge-base (main) revision scanned — ingest a clean scan here;
  # the head revision's clean scan rides with step 9's feature push.
  ingest_clean_scan "$MAIN_REV" "north-star-$RUN_ID-scan-main" "2026-08-16T00:00:01Z" || return 1
  echo "  bare repo dev/$REPO re-created on the storage PVC (RUNBOOK §8a recovery: the volume was wiped pre-stage)"
  echo "  clean scan ingested at main revision ${MAIN_REV:0:12} (security merge gate precondition, SPEC-0029)"
  echo "  repo dev/$REPO seeded over https://git.gitsaas.test (GIT_SSL_CAINFO=$GIT_SSL_CAINFO)"
}

pf_start() { # pf_start <svc> <local-port> <remote-port> — retry until the forward holds
  local svc=$1 lport=$2 rport=$3 attempt=0 pid
  # The script owns the 1909x range: drop any stale holder from an earlier run first.
  pkill -f "port-forward svc/$svc $lport:$rport" >/dev/null 2>&1 || true
  sleep 1
  while [ "$attempt" -lt 3 ]; do
    kctl port-forward "svc/$svc" "$lport:$rport" >/dev/null 2>&1 &
    pid=$!
    if wait_port "$lport"; then
      pf_pids[${#pf_pids[@]}]=$pid
      return 0
    fi
    kill "$pid" >/dev/null 2>&1 || true
    sleep 1
    attempt=$((attempt + 1))
  done
  return 1
}

pf_stop_all() {
  local pid
  if [ ${#pf_pids[@]} -gt 0 ]; then
    for pid in "${pf_pids[@]}"; do
      kill "$pid" >/dev/null 2>&1 || true
    done
  fi
  pf_pids=()
  sleep 1
}

wait_port() { # wait_port <local-port>
  local i=0
  while [ "$i" -lt 60 ]; do
    if nc -z 127.0.0.1 "$1" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

b64d() { # BSD-first base64 decode
  if base64 -D </dev/null >/dev/null 2>&1; then
    base64 -D
  else
    base64 -d
  fi
}

for tool in kubectl grpcurl python3 nc git mkcert openssl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "north-star: required tool missing: $tool" >&2; exit 3; }
done

echo "north-star: North Star Stage D journey on context gitfrok (run id $RUN_ID)"
echo "north-star: honest limits — one node (no failover/replica-ack), no gVisor CI,"
echo "            GITFROK_CLOUD=gke is dev fiction, release-trust door unmounted"

# ---------------------------------------------------------------------------
# Step 1 — dev-smoke green (failure class SMOKE_RED)
# ---------------------------------------------------------------------------
step_begin 1 "dev-smoke green"
if ! "$ROOT/scripts/smoke-dev.sh" >"$WORK/smoke.log" 2>&1; then
  tail -n 20 "$WORK/smoke.log" >&2
  die SMOKE_RED "dev-smoke is red; the cluster baseline is not what the journey assumes"
fi
tail -n 1 "$WORK/smoke.log"
step_pass "dev-smoke" "$(tail -n 1 "$WORK/smoke.log")"

# ---------------------------------------------------------------------------
# Step 2 — OpenBao unsealed + custody CA attached (failure class CUSTODY_UNAVAILABLE)
# ---------------------------------------------------------------------------
step_begin 2 "OpenBao unsealed + custody CA attached"
bao_status=$(kctl exec openbao-0 -- bao status -format=json 2>"$WORK/bao.err") \
  || die CUSTODY_UNAVAILABLE "bao status unreachable on openbao-0: $(cat "$WORK/bao.err")"
bao_sealed=$(json_get "$bao_status" sealed)
bao_init=$(json_get "$bao_status" initialized)
[ "$bao_sealed" = "false" ] || die CUSTODY_UNAVAILABLE "openbao-0 is SEALED — run RUNBOOK §6a quorum unseal"
[ "$bao_init" = "true" ] || die CUSTODY_UNAVAILABLE "openbao-0 reports initialized=$bao_init"
echo "  openbao-0: initialized=$bao_init sealed=$bao_sealed"

# The durable custody snapshot: key references and public certificates only (SPEC-0044 AC1),
# readable through the busybox sidecar — the only exec window onto the volume.
snap_before="$WORK/snapshot-before.json"
kctl exec deploy/controlplane -c openbao-proxy -- \
  cat /var/lib/gitfrok/custody/snapshot.json >"$snap_before" 2>"$WORK/snap.err" \
  || die CUSTODY_UNAVAILABLE "custody snapshot unreadable: $(cat "$WORK/snap.err")"
[ -s "$snap_before" ] || die CUSTODY_UNAVAILABLE "custody snapshot is empty — Restore has nothing to restore"
snap_rev_before=$(json_get "$(cat "$snap_before")" revision)
echo "  custody snapshot present (revision ${snap_rev_before:-0})"

cp_logs=$(kctl logs deploy/controlplane -c controlplane --tail=200 2>/dev/null)
printf '%s\n' "$cp_logs" | grep -q 'AgentGateway listening on :9091 (custody-backed CA)' \
  || die CUSTODY_UNAVAILABLE "controlplane never logged the custody-backed AgentGateway"
echo "  controlplane-app: AgentGateway listening on :9091 (custody-backed CA)"
step_pass "custody" "openbao unsealed; snapshot rev ${snap_rev_before:-0}; custody-backed CA serving :9091"

# ---------------------------------------------------------------------------
# Step 3 — enrolment token issued via the :9094 door with the OWNER PAT
#          (failure class ISSUANCE_REFUSED)
# ---------------------------------------------------------------------------
step_begin 3 "enrolment token minted through the :9094 door (owner PAT)"
OWNER_PAT=$(kctl get secret gitfrok-owner-pat -o jsonpath='{.data.token}' | b64d)
[ -n "$OWNER_PAT" ] || die ISSUANCE_REFUSED "secret gitfrok-owner-pat absent — run scripts/dev-provision.sh"

audit_issued_before=$(psqlq "SELECT count(*) FROM audit.entries WHERE action='agent.enrolment_token.issued';")

pf_start controlplane 19094 9094 || die ISSUANCE_REFUSED "port-forward to svc/controlplane:9094 never opened"
issue_out=$(grpc_try "$WORK/issue.err" proto/agent/v1/agent.proto 127.0.0.1:19094 \
  gitsaas.agent.v1.EnrolmentService.IssueEnrolmentToken \
  -H "authorization: Bearer $OWNER_PAT" \
  -d '{"lifetime":"3600s"}') \
  || die ISSUANCE_REFUSED "door refused the owner PAT: $(tail -n 3 "$WORK/issue.err" | tr '\n' ' ')"
TOKEN_ID=$(json_get "$issue_out" token_id)
OTT=$(json_get "$issue_out" one_time_token)
[ -n "$TOKEN_ID" ] && [ -n "$OTT" ] || die ISSUANCE_REFUSED "issuance returned no token: $issue_out"
echo "  issued token_id=$TOKEN_ID (secret returned exactly once)"

audit_issued_after=$(psqlq "SELECT count(*) FROM audit.entries WHERE action='agent.enrolment_token.issued';")
[ "$audit_issued_after" -gt "$audit_issued_before" ] \
  || die ISSUANCE_REFUSED "issuance did not append its audit record"
echo "  audit: agent.enrolment_token.issued appended ($audit_issued_before -> $audit_issued_after)"
step_pass "issuance" "token $TOKEN_ID minted via :9094 by the durable owner PAT; audit appended"

# ---------------------------------------------------------------------------
# Step 4 — token into the Secret, dataplane restart, self-enrolment
#          (failure class SELF_ENROLMENT_FAILED)
# ---------------------------------------------------------------------------
step_begin 4 "self-enrolment: token injected, dataplane restarted"
kctl create secret generic gitfrok-enrolment-token \
  --from-literal=token="$OTT" --dry-run=client -o yaml | kctl apply -f - >/dev/null \
  || die SELF_ENROLMENT_FAILED "could not converge secret gitfrok-enrolment-token"
kctl rollout restart deploy/dataplane >/dev/null
kctl rollout status deploy/dataplane --timeout=180s >/dev/null \
  || die SELF_ENROLMENT_FAILED "dataplane rollout did not become ready"

enrolled=""
i=0
while [ "$i" -lt 30 ]; do
  if kctl logs deploy/dataplane --since=3m 2>/dev/null | grep -q 'agentclient: enrolled as'; then
    enrolled=$(kctl logs deploy/dataplane --since=3m 2>/dev/null | grep 'agentclient: enrolled as' | tail -n 1)
    break
  fi
  sleep 2
  i=$((i + 1))
done
[ -n "$enrolled" ] || die SELF_ENROLMENT_FAILED "dataplane never logged 'agentclient: enrolled as' (60s)"
echo "  dataplane: $enrolled"

spent=$(psqlq "SELECT count(*) FROM agent.enrolment_tokens WHERE id='$TOKEN_ID' AND spent_at IS NOT NULL;")
[ "$spent" = "1" ] || die SELF_ENROLMENT_FAILED "token $TOKEN_ID is not spent in agent.enrolment_tokens"
planes=$(psqlq "SELECT count(*) FROM agent.data_planes WHERE last_seen_at IS NOT NULL;")
[ "$planes" -ge 1 ] || die SELF_ENROLMENT_FAILED "no data plane registered in agent.data_planes"
echo "  postgres: token spent_at set; agent.data_planes rows with last_seen: $planes"
step_pass "self-enrolment" "dataplane enrolled; token $TOKEN_ID spent; data plane registered"

# ---------------------------------------------------------------------------
# Step 5 — residency declared via :9093 (failure class RESIDENCY_REFUSED)
# ---------------------------------------------------------------------------
step_begin 5 "residency declared via the :9093 door"
pf_start controlplane 19093 9093 || die RESIDENCY_REFUSED "port-forward to svc/controlplane:9093 never opened"
decl_before=$(psqlq "SELECT count(*) FROM residency.declarations;")
# Cloud vocabulary MUST match what the data plane reports at enrolment: the agent wire
# contract names the enum (agent/v1 Cloud: CLOUD_GKE), and the placement gate compares
# exact strings — a declaration saying "gke" while the plane reports "CLOUD_GKE" is a
# witnessed placement contradiction (SPEC-0040 AC2), which run 5 of this proof hit live.
res_out=$(grpc_try "$WORK/res.err" proto/residency/v1/residency.proto 127.0.0.1:19093 \
  gitsaas.residency.v1.ResidencyService.DeclareResidency \
  -H "authorization: Bearer $OWNER_PAT" \
  -d '{"cloud":"CLOUD_GKE","region":"europe-west1"}') \
  || die RESIDENCY_REFUSED "residency door refused the owner PAT: $(tail -n 3 "$WORK/res.err" | tr '\n' ' ')"
echo "  declared: $(printf '%s' "$res_out" | tr '\n' ' ')"

decl_now=$(psqlq "SELECT cloud || '/' || region FROM residency.declarations ORDER BY chain_seq DESC LIMIT 1;")
[ "$decl_now" = "CLOUD_GKE/europe-west1" ] \
  || die RESIDENCY_REFUSED "latest durable declaration is '$decl_now', not CLOUD_GKE/europe-west1"
decl_after=$(psqlq "SELECT count(*) FROM residency.declarations;")
[ "$decl_after" -gt "$decl_before" ] \
  || die RESIDENCY_REFUSED "no new durable declaration row appended (chain_seq history)"
echo "  postgres: residency.declarations $decl_before -> $decl_after, in force: $decl_now"
step_pass "residency" "declaration durable (chain $decl_after), in force CLOUD_GKE/europe-west1"

# ---------------------------------------------------------------------------
# Step 6 — usage view via :9092 with an owner-role caller (failure class USAGE_VIEW_BROKEN)
# ---------------------------------------------------------------------------
step_begin 6 "usage view honest through the :9092 door"
pf_start controlplane 19092 9092 || die USAGE_VIEW_BROKEN "port-forward to svc/controlplane:9092 never opened"
usage_out=$(grpc_try "$WORK/usage.err" proto/usage/v1/usage.proto 127.0.0.1:19092 \
  gitsaas.usage.v1.UsageService.GetUsageView \
  -d "{\"context\":{\"tenant_id\":\"dev\",\"actor_id\":\"user-admin\",\"actor_roles\":[\"owner\"],\"request_id\":\"north-star-$RUN_ID\"}}") \
  || die USAGE_VIEW_BROKEN "usage door denied the owner-role caller: $(tail -n 3 "$WORK/usage.err" | tr '\n' ' ')"

usage_summary=$(printf '%s' "$usage_out" | python3 -c '
import json, sys
v = json.load(sys.stdin)
dims = v.get("dimensions", [])
if not dims:
    print("EMPTY"); sys.exit(0)
cov = {}
for d in dims:
    c = d.get("coverage", "DIMENSION_COVERAGE_UNSPECIFIED")
    cov[c] = cov.get(c, 0) + 1
print(" ".join("%s=%d" % (k, cov[k]) for k in sorted(cov)))
')
case "$usage_summary" in
  EMPTY) die USAGE_VIEW_BROKEN "usage view returned zero dimensions — no coverage statement" ;;
  *UNSPECIFIED*) die USAGE_VIEW_BROKEN "a dimension carries UNSPECIFIED coverage — dishonest rendering" ;;
esac
echo "  dimensions: $usage_summary"

# Negative control: the reader role has no usage.view grant — the PDP must deny it.
if grpc proto/usage/v1/usage.proto 127.0.0.1:19092 \
  gitsaas.usage.v1.UsageService.GetUsageView \
  -d "{\"context\":{\"tenant_id\":\"dev\",\"actor_id\":\"user-admin\",\"actor_roles\":[\"reader\"],\"request_id\":\"north-star-$RUN_ID-r\"}}" \
  >/dev/null 2>&1; then
  die USAGE_VIEW_BROKEN "reader-role caller was NOT denied — the PDP grant is wrong"
fi
echo "  negative control: reader-role caller denied (PermissionDenied)"
step_pass "usage" "owner view returned ($usage_summary); reader denied"

# ---------------------------------------------------------------------------
# Step 7 — DURABILITY: controlplane restart, snapshot Restore, rows survive
#          (failure class DURABILITY_LOST)
# ---------------------------------------------------------------------------
step_begin 7 "durability: controlplane restart survives on the snapshot"
spent_before=$(psqlq "SELECT count(*) FROM agent.enrolment_tokens WHERE spent_at IS NOT NULL;")
decl_hold=$(psqlq "SELECT count(*) FROM residency.declarations;")
pf_stop_all  # controlplane port-forwards die with the pod anyway; kill them cleanly

kctl rollout restart deploy/controlplane >/dev/null
kctl rollout status deploy/controlplane --timeout=240s >/dev/null \
  || die DURABILITY_LOST "controlplane rollout did not become ready after restart"

i=0
ca_line=""
while [ "$i" -lt 30 ]; do
  ca_line=$(kctl logs deploy/controlplane -c controlplane --since=3m 2>/dev/null \
    | grep 'AgentGateway listening on :9091 (custody-backed CA)' | tail -n 1 || true)
  [ -n "$ca_line" ] && break
  sleep 2
  i=$((i + 1))
done
[ -n "$ca_line" ] || die DURABILITY_LOST "restarted controlplane never re-attached the custody-backed CA"
echo "  restarted controlplane: $ca_line"

snap_after="$WORK/snapshot-after.json"
kctl exec deploy/controlplane -c openbao-proxy -- \
  cat /var/lib/gitfrok/custody/snapshot.json >"$snap_after" 2>/dev/null \
  || die DURABILITY_LOST "snapshot unreadable after restart"
snap_rev_after=$(json_get "$(cat "$snap_after")" revision)
[ "${snap_rev_after:-0}" = "${snap_rev_before:-0}" ] \
  || die DURABILITY_LOST "snapshot revision changed across restart (before=${snap_rev_before:-0} after=${snap_rev_after:-0})"
echo "  snapshot Restore: revision ${snap_rev_after:-0} unchanged across the restart"

spent_after=$(psqlq "SELECT count(*) FROM agent.enrolment_tokens WHERE spent_at IS NOT NULL;")
decl_after2=$(psqlq "SELECT count(*) FROM residency.declarations;")
[ "$spent_after" = "$spent_before" ] && [ "$spent_after" -ge 1 ] \
  || die DURABILITY_LOST "spent-token rows lost across restart ($spent_before -> $spent_after)"
[ "$decl_after2" = "$decl_hold" ] \
  || die DURABILITY_LOST "residency declarations lost across restart ($decl_hold -> $decl_after2)"
recent_seen=$(psqlq "SELECT count(*) FROM agent.data_planes WHERE last_seen_at > now() - interval '10 minutes';")
echo "  postgres: spent tokens $spent_after (unchanged), declarations $decl_after2 (unchanged), data-plane heartbeats in last 10m: $recent_seen"
step_pass "durability" "restart restored snapshot rev ${snap_rev_after:-0}; spent token + declaration survive"

# ---------------------------------------------------------------------------
# Step 8 — evidence pack assembles (failure class EVIDENCE_UNAVAILABLE)
# ---------------------------------------------------------------------------
step_begin 8 "evidence pack assembles via audit/v1 EvidenceService"
pf_start dataplane 19090 9090 || die EVIDENCE_UNAVAILABLE "port-forward to svc/dataplane:9090 never opened"

# Seed the proof repository FIRST: the appendix source lists imports per repository, and
# the import surface refuses a tenant-wide (empty) repository scope outright — a pack with
# no repository scope can therefore never assemble. Scoping the pack to the proof repo is
# the contract's documented shape (RequestEvidencePack.repository_id).
REPO="north-star-$RUN_ID"
setup_repo || die EVIDENCE_UNAVAILABLE "repo seeding failed before evidence: $(tail -n 2 "$WORK/push1.err" 2>/dev/null | tr '\n' ' ')"

range_from=$(psqlq "SELECT to_char(min(occurred_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') FROM audit.entries;")
[ -n "$range_from" ] || die EVIDENCE_UNAVAILABLE "no audit.entries to derive the evidence range from"
range_to=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "  range: $range_from .. $range_to (tenant dev, repository scope: $REPO)"

req_out=$(grpc proto/audit/v1/evidence.proto 127.0.0.1:19090 \
  gitsaas.audit.v1.EvidenceService.RequestEvidencePack \
  -d "{\"context\":{\"tenant_id\":\"dev\",\"actor_id\":\"user-admin\",\"actor_roles\":[\"owner\"],\"request_id\":\"north-star-$RUN_ID\"},\"range_from\":\"$range_from\",\"range_to\":\"$range_to\",\"repository_id\":\"$REPO\"}" \
  2>"$WORK/ev.err") \
  || die EVIDENCE_UNAVAILABLE "evidence door refused the pack request: $(tail -n 3 "$WORK/ev.err" | tr '\n' ' ')"
pack_id=$(json_get "$req_out" pack_id)
[ -n "$pack_id" ] || die EVIDENCE_UNAVAILABLE "no pack_id in response: $req_out"
echo "  pack_id=$pack_id"

pack_state=""
status_out=""
i=0
while [ "$i" -lt 20 ]; do
  status_out=$(grpc proto/audit/v1/evidence.proto 127.0.0.1:19090 \
    gitsaas.audit.v1.EvidenceService.GetEvidencePackStatus \
    -d "{\"context\":{\"tenant_id\":\"dev\",\"actor_id\":\"user-admin\",\"actor_roles\":[\"owner\"],\"request_id\":\"north-star-$RUN_ID\"},\"pack_id\":\"$pack_id\"}" \
    2>/dev/null) || die EVIDENCE_UNAVAILABLE "evidence status read failed"
  pack_state=$(json_get "$status_out" state)
  case "$pack_state" in
    PACK_STATE_READY) break ;;
    PACK_STATE_FAILED)
      die EVIDENCE_UNAVAILABLE "assembly FAILED: $(json_get "$status_out" failure_reason)" ;;
  esac
  sleep 3
  i=$((i + 1))
done
[ "$pack_state" = "PACK_STATE_READY" ] \
  || die EVIDENCE_UNAVAILABLE "pack still $pack_state after 60s"
printf '%s' "$status_out" | python3 -c '
import json, sys
s = json.load(sys.stdin)
for sec in s.get("sections", []):
    print("  section %s: records=%d gaps=%d" % (
        sec.get("type", "?"), sec.get("recordCount", sec.get("record_count", 0)), len(sec.get("gaps", []))))
print("  appendix records: %d" % s.get("appendixRecordCount", s.get("appendix_record_count", 0)))
' 2>/dev/null || true
step_pass "evidence" "pack $pack_id READY (state $pack_state)"

# ---------------------------------------------------------------------------
# Step 9 — the RUNBOOK §8a git flow over https://git.gitsaas.test
#          (failure class GIT_FLOW_BROKEN)
# ---------------------------------------------------------------------------
step_begin 9 "git flow: push / protection denial / MR / approve / merge"
# Repo dev/$REPO was seeded at step 8 (the evidence pack needs its scope); the fresh PAT
# from that step is still the door-issued throwaway credential for this flow.

# Distinct request IDs per command: the module's idempotency guard keys on the
# request_id, so replaying one command's ID on another would read as a replay.
CTX_BASE="{\"tenant_id\":\"dev\",\"repository_id\":\"$REPO\",\"actor_id\":\"user-admin\",\"actor_roles\":[\"owner\"]"
prot_out=$(grpc proto/codereview/v1/codereview.proto 127.0.0.1:19090 \
  gitsaas.codereview.v1.MergeRequestService.SetBranchProtection \
  -d "{\"context\":${CTX_BASE},\"request_id\":\"north-star-$RUN_ID-protect\"},\"target_ref\":\"refs/heads/main\",\"required_approvals\":1,\"expected_version\":0}" \
  2>"$WORK/prot.err") \
  || die GIT_FLOW_BROKEN "SetBranchProtection refused: $(tail -n 3 "$WORK/prot.err" | tr '\n' ' ')"
prot_version=$(json_get "$prot_out" branch_protection.version)
echo "  main protected (required_approvals=1, version ${prot_version:-?})"

printf 'attempt direct push\n' >>"$RDIR/README"
git -C "$RDIR" commit -aqm "north-star: direct push attempt"
if git -C "$RDIR" push -q origin main 2>"$WORK/push2.err"; then
  die GIT_FLOW_BROKEN "direct push to protected main was ACCEPTED — protection is inert"
fi
grep -qi 'protected' "$WORK/push2.err" \
  || die GIT_FLOW_BROKEN "push failed but not with the protected-ref reason: $(tail -n 2 "$WORK/push2.err" | tr '\n' ' ')"
echo "  direct push to refs/heads/main DENIED: $(tail -n 1 "$WORK/push2.err")"

git -C "$RDIR" checkout -qb feature/north-star
printf 'feature change\n' >>"$RDIR/README"
git -C "$RDIR" commit -aqm "north-star: feature"
git -C "$RDIR" push -q origin feature/north-star 2>"$WORK/push3.err" \
  || die GIT_FLOW_BROKEN "feature push failed: $(tail -n 2 "$WORK/push3.err" | tr '\n' ' ')"
HEAD_REV=$(git -C "$RDIR" rev-parse HEAD)
# Scan identity is a deterministic function of the descriptor (the revision is NOT an
# input): the head scan gets a distinct stamp so the two clean scans are two scans.
ingest_clean_scan "$HEAD_REV" "north-star-$RUN_ID-scan-head" "2026-08-16T00:00:02Z" \
  || die GIT_FLOW_BROKEN "clean-scan ingest at the head revision was refused"
echo "  clean scan ingested at head revision ${HEAD_REV:0:12} (merge gate attribution precondition)"

mr_out=$(grpc proto/codereview/v1/codereview.proto 127.0.0.1:19090 \
  gitsaas.codereview.v1.MergeRequestService.CreateMergeRequest \
  -d "{\"context\":${CTX_BASE},\"request_id\":\"north-star-$RUN_ID-open\"},\"source_ref\":\"refs/heads/feature/north-star\",\"target_ref\":\"refs/heads/main\",\"title\":\"north-star proof\"}" \
  2>"$WORK/mr.err") \
  || die GIT_FLOW_BROKEN "CreateMergeRequest refused: $(tail -n 3 "$WORK/mr.err" | tr '\n' ' ')"
MR_ID=$(json_get "$mr_out" merge_request.merge_request_id)
MR_VERSION=$(json_get "$mr_out" merge_request.version)
[ -n "$MR_ID" ] || die GIT_FLOW_BROKEN "no merge_request_id in CreateMergeRequest response"
echo "  MR $MR_ID opened (version ${MR_VERSION:-?}, head $HEAD_REV)"

rev_out=$(grpc proto/codereview/v1/codereview.proto 127.0.0.1:19090 \
  gitsaas.codereview.v1.MergeRequestService.SubmitReview \
  -d "{\"context\":${CTX_BASE},\"request_id\":\"north-star-$RUN_ID-review\"},\"merge_request_id\":\"$MR_ID\",\"disposition\":\"REVIEW_DISPOSITION_APPROVE\",\"comment\":\"north-star approve\",\"head_revision\":\"$HEAD_REV\",\"expected_version\":$MR_VERSION}" \
  2>"$WORK/rev.err") \
  || die GIT_FLOW_BROKEN "SubmitReview refused: $(tail -n 3 "$WORK/rev.err" | tr '\n' ' ')"
echo "  review approved (MR state after review: $(json_get "$rev_out" merge_request.state))"

get_out=$(grpc proto/codereview/v1/codereview.proto 127.0.0.1:19090 \
  gitsaas.codereview.v1.MergeRequestService.GetMergeRequest \
  -d "{\"context\":${CTX_BASE},\"request_id\":\"north-star-$RUN_ID-get\"},\"merge_request_id\":\"$MR_ID\"}" 2>/dev/null) \
  || die GIT_FLOW_BROKEN "GetMergeRequest refused"
MR_VERSION=$(json_get "$get_out" merge_request.version)

# The security projection learns the MR from Code Review's events (async): a merge
# asked before the facts can assemble fails CLOSED by design (SPEC-0029 AC9) — retry
# until attribution materializes instead of reading the first refusal as final.
merge_out=""
MR_STATE=""
i=0
while [ "$i" -lt 10 ]; do
  if merge_out=$(grpc proto/codereview/v1/codereview.proto 127.0.0.1:19090 \
    gitsaas.codereview.v1.MergeRequestService.MergeMergeRequest \
    -d "{\"context\":${CTX_BASE},\"request_id\":\"north-star-$RUN_ID-merge\"},\"merge_request_id\":\"$MR_ID\",\"expected_version\":$MR_VERSION}" \
    2>"$WORK/merge.err"); then
    break
  fi
  i=$((i + 1))
  sleep 2
done
[ -n "$merge_out" ] \
  || die GIT_FLOW_BROKEN "MergeMergeRequest refused after 20s: $(tail -n 3 "$WORK/merge.err" | tr '\n' ' ')"
MR_STATE=$(json_get "$merge_out" merge_request.state)
[ "$MR_STATE" = "MERGE_REQUEST_STATE_MERGED" ] \
  || die GIT_FLOW_BROKEN "merge ended in state $MR_STATE, not MERGED"
echo "  MR $MR_ID MERGED; main moved through the merge gate"

audit_flow=$(psqlq "SELECT count(*) FROM audit.entries;")
genesis_prev=$(psqlq "SELECT count(*) FROM audit.entries WHERE prev_hash = '';")
[ "$genesis_prev" = "1" ] \
  || die GIT_FLOW_BROKEN "audit chain genesis is not exactly one row (got $genesis_prev)"
echo "  audit chain: $audit_flow entries, exactly one genesis root"
step_pass "git-flow" "push, protection denial, MR approve+merge over https://git.gitsaas.test"

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
pf_stop_all
echo
echo "=== north-star verdict (run $RUN_ID) ==="
print_verdicts
echo
echo "rows that STAY honestly 'no' on this one-node dev host:"
echo "  - failover promotes the in-sync replica — one node, no second machine"
echo "  - durable push (primary + in-sync replica ack) — one node"
echo "  - CI job runs and gates merge — no gVisor RuntimeClass under rootless podman"
echo "annotations carried by this run:"
echo "  - GITFROK_CLOUD=gke is dev fiction (deploy/dev/dataplane.yaml)"
echo "  - release-trust door NOT mounted — no dev-safe seed exists"
echo "  - the git-flow PAT is throwaway: in-memory identity store, discarded with the pod"
echo "  - enrolment issuance is OWNER-only by PDP grant; platform_operator stays refused"
echo "  - bare repos are re-created via kubectl exec (RUNBOOK §8a recovery): the git/v1"
echo "    contract has no create-repository RPC and the storage PVC was wiped pre-stage"
echo "  - the merge gate (T-0025/SPEC-0029) is engaged by construction: the journey ingests"
echo "    clean scans at the merge-base and head revisions — a merge without scan reports"
echo "    at BOTH revisions fails closed, and that refusal is the gate working"
echo
echo "north-star: ALL 9 STEPS PASS"
