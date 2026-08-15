#!/usr/bin/env bash
# dev-provision.sh — bring the *application* layer up on the dev cluster.
#
# `dev-up.sh` converges the cluster (workloads, TLS, buckets); it used to leave two
# runbook steps manual: the database migrations and the Zitadel OIDC client for the
# BFF. This script converges both, idempotently, so `make dev-up` is the whole
# story (dev-up.sh calls this at the end). It also verifies the OIDC roundtrip
# through the BFF itself, which is the Phase-1 exit bar (MVP-RUNBOOK §6).
#
# What it does:
#   1. Applies ALL backend migrations (Phase 0/1 tenancy baseline, audit, identity;
#      Phase 2 audit evidence indexes, identity auditor grants, policy decision
#      records, security findings/triage/scan-report; Phase 3.1 agent enrolment
#      tokens + data-plane registry, T-0036, and the residency declarations +
#      observations store, T-0037) against the app database `gitfrok` — all
#      CREATE/GRANT idempotent, applied as the postgres superuser like the
#      postgres-init ConfigMap does.
#   2. Creates the Zitadel OIDC web application for the BFF, if it does not exist:
#      admin login is driven headlessly through the same API surface the Login V2
#      UI uses (session check API with the setup-written login-client PAT, then
#      OIDC callback), so no browser, no console, no cookies are needed.
#   3. Writes the resulting client id into the ConfigMap `gitfrok-oidc` and
#      restarts the BFF so it picks the client id up from env.
#   4. Verifies: BFF /login redirects to the issuer and the full OIDC code flow
#      completes against the real issuer, proving "OIDC login" end to end.
#
# Requirements: a converged cluster (zitadel + zitadel-login + postgres rollouts)
# and the *.gitsaas.test hosts resolvable (ingress-dns addon or /etc/hosts).
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${MINIKUBE_PROFILE:-gitfrok}"
NS="${KUBE_NS:-default}"
KUBECTL=(kubectl --context "$PROFILE")

ISSUER="https://zitadel.gitsaas.test"
BFF_REDIRECT="https://app.gitsaas.test/callback"
BFF_LOGOUT="https://app.gitsaas.test/"
OIDC_CM="gitfrok-oidc"
OIDC_APP_NAME="Gitfrok BFF"
ADMIN_LOGIN="admin@gitsaas.test"
ADMIN_PASSWORD="ChangeMe123!"
TIMEOUT=20

step() { printf '\n==> %s\n' "$1"; }
die()  { printf 'dev-provision: FAIL — %s\n' "$1" >&2; exit 1; }

# http <path> <curl-args...> — GET unless -X is given; prints the body to stdout.
http() {
  local path="$1"; shift
  HTTP_BODY=$(curl -sk --max-time "$TIMEOUT" "$ISSUER$path" "$@") || return $?
  printf '%s' "$HTTP_BODY"
}

base64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# ------------------------------------------------------------------ 1. migrations
# Phase 0/1 baseline first, then the Phase-2 set in dependency order:
# tenancy baseline → audit → identity → policy decision records → security,
# then the Phase-3.1 agent enrolment/registry migration (T-0036, SPEC-0042)
# and the residency declarations/observations migration (T-0037, SPEC-0042):
# each needs only the tenancy baseline's gitfrok_app role, and they apply in
# landed order so the set still reads as it landed.
# The pinned backend selects Postgres-backed stores whenever GITFROK_DATABASE_URL
# is set (dataplane.yaml sets it), and policy Decide fails closed when
# policy.decision_records is missing — a plane provisioned without the Phase-2
# set denies every protected action, so ALL of these apply here. The agent
# tables are the durable enrolment state (ADR-0062): a plane provisioned
# without them cannot enrol a data plane. The residency tables are the durable
# declaration store (T-0037, SPEC-0042 AC3): a control plane given
# GITFROK_DATABASE_URL breaks hard on the first declaration read or write if
# they are missing, so they apply with the same discipline.
step "Database migrations (tenant, audit, identity, policy, security, agent, residency)"
for m in \
  backend/platform/db/migrations/0001_tenancy_baseline.sql \
  backend/modules/audit/internal/adapters/postgres/migrations/0001_audit_log.sql \
  backend/modules/audit/internal/adapters/postgres/migrations/0002_audit_evidence_indexes.sql \
  backend/modules/identity/internal/adapters/postgres/migrations/0001_identity_credentials.sql \
  backend/modules/identity/internal/adapters/postgres/migrations/0002_identity_auditor_grants.sql \
  backend/modules/policy/internal/adapters/postgres/migrations/0001_policy_decision_records.sql \
  backend/modules/security/internal/adapters/postgres/migrations/0001_security_findings.sql \
  backend/modules/security/internal/adapters/postgres/migrations/0002_security_triage.sql \
  backend/modules/security/internal/adapters/postgres/migrations/0003_security_scan_report.sql \
  backend/modules/agent/internal/adapters/postgres/migrations/0001_agent_enrolment.sql \
  backend/modules/agent/internal/adapters/postgres/migrations/0002_release_trust_plane_state.sql \
  backend/modules/residency/internal/adapters/postgres/migrations/0001_residency_declarations.sql; do
  [ -f "$m" ] || die "migration not found: $m"
  echo "  applying $m"
  "${KUBECTL[@]}" exec -i deployment/postgres -n "$NS" -- \
    psql -U postgres -d gitfrok -v ON_ERROR_STOP=1 -q < "$m" || die "migration $m failed"
done
schema_list=$("${KUBECTL[@]}" exec deployment/postgres -n "$NS" -- psql -U postgres -d gitfrok -tAc \
  "SELECT schema_name FROM information_schema.schemata") || die "cannot list schemas"
missing=""
for s in tenant audit identity policy security agent residency; do
  printf '%s\n' "$schema_list" | grep -qx "$s" || missing="$missing $s"
done
[ -z "$missing" ] || die "schemas missing after migrations:$missing"
echo "  schemas tenant/audit/identity/policy/security/agent/residency present"
# Table-level check, the same shape as the schema guard: one table per Phase-2
# migration plus the Phase-3.1 agent tables, so a silently truncated migration
# set is caught before the plane starts denying on a missing decision_records
# or scan table — or before enrolment fails on a missing token store.
table_list=$("${KUBECTL[@]}" exec deployment/postgres -n "$NS" -- psql -U postgres -d gitfrok -tAc \
  "SELECT table_schema || '.' || table_name FROM information_schema.tables") || die "cannot list tables"
missing=""
for t in \
  audit.entries \
  identity.auditor_grants \
  identity.auditor_grant_transitions \
  policy.decision_records \
  security.scans \
  security.findings \
  security.scan_chunks \
  security.scan_staged_findings \
  security.triages \
  security.triage_requests \
  security.repository_ownership \
  security.scan_report \
  agent.enrolment_tokens \
  agent.data_planes \
  agent.release_trust_plane_state \
  residency.declarations \
  residency.observations; do
  printf '%s\n' "$table_list" | grep -qx "$t" || missing="$missing $t"
done
[ -z "$missing" ] || die "tables missing after migrations:$missing"
echo "  all Phase-2 tables + agent enrolment + residency declaration tables present"

# --------------------------------------------- 1b. Stage C: door credentials
# The Phase 3.1 doors the dev cluster now mounts (deploy/dev/controlplane.yaml)
# resolve operator PATs against the SAME identity schema the data plane issues
# from (ADR-0043). This section converges the two credentials those doors need:
#   1. the PAT verifier key assertion — dev-up.sh creates the Secret create-once;
#      a key shorter than 32 decoded bytes would fail the doors' contract,
#   2. one platform-operator/owner PAT, issued through the data plane's identity
#      door (grpcurl over a port-forward, the RUNBOOK §7 shape) and stored in a
#      Secret for Stage D's enrolment proof — idempotent: re-runs keep the
#      existing Secret, because a plaintext PAT exists in exactly one response
#      and can never be read back,
#   3. the agent CA bundle ConfigMap the data plane pins, derived from the
#      custody snapshot the controlplane persisted on its first custody-backed
#      start (RUNBOOK §6b has no earlier source for it),
#   4. the enrolment-token placeholder Secret assertion (dev-up.sh creates it;
#      the pinned data plane refuses to START without a non-empty token).
step "Stage C door credentials (PAT verifier, operator PAT, agent CA bundle)"
command -v grpcurl >/dev/null || die "grpcurl not installed — the operator PAT is issued over
  the identity door's gRPC surface: brew install grpcurl (or your platform's equivalent)"

verifier_len=$("${KUBECTL[@]}" get secret gitfrok-pat-verifier -n "$NS" \
  -o jsonpath='{.data.key}' 2>/dev/null | base64 -D 2>/dev/null | wc -c | tr -d ' ')
[ "${verifier_len:-0}" -ge 32 ] || die "secret gitfrok-pat-verifier is absent or its key decodes to
  ${verifier_len:-0} bytes — the residency/enrolment doors require base64 of >= 32 bytes. Run dev-up.sh."
echo "  PAT verifier key present ($verifier_len decoded bytes)"

"${KUBECTL[@]}" get secret gitfrok-enrolment-token -n "$NS" >/dev/null 2>&1 \
  || die "secret gitfrok-enrolment-token is absent — dev-up.sh converges the placeholder;
  the data plane cannot start in agent mode without a non-empty GITFROK_ENROLMENT_TOKEN"

# The CA the controlplane's custody-backed issuer minted at startup, read from
# its durable snapshot and published as the pin the data plane connects with.
# Public material only (SPEC-0044 AC1); regenerated on every run so a rotation
# window's roots re-converge here too (Stage D applies it to the data plane).
custody_ca=$(mktemp)
# Read through the busybox sidecar: the controlplane container is a scratch
# image with no `cat`, and controlplane.yaml mounts the snapshot volume into
# the sidecar read-only exactly for this window.
"${KUBECTL[@]}" exec deployment/controlplane -c openbao-proxy -n "$NS" -- \
  cat /var/lib/gitfrok/custody/snapshot.json 2>/dev/null | python3 -c "
import base64, json, sys
snap = json.load(sys.stdin)
roots = snap.get('snapshot', {}).get('Roots') or []
if not roots:
    sys.exit('custody snapshot carries no roots - did the agent door bootstrap?')
sys.stdout.write(''.join(
    '-----BEGIN CERTIFICATE-----\n' + base64.b64encode(base64.b64decode(r['CertDER'])).decode()
    + '\n-----END CERTIFICATE-----\n' for r in roots))" > "$custody_ca" \
  || { rm -f "$custody_ca"; die "could not derive the agent CA from the controlplane custody snapshot —
  is the controlplane's agent door up? kubectl --context $PROFILE logs deployment/controlplane -n $NS"; }
[ -s "$custody_ca" ] || { rm -f "$custody_ca"; die "derived agent CA bundle is empty"; }
"${KUBECTL[@]}" create configmap gitfrok-agent-ca -n "$NS" \
  --from-file=ca.pem="$custody_ca" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null || die "writing gitfrok-agent-ca failed"
rm -f "$custody_ca"
echo "  configmap gitfrok-agent-ca converged from the custody snapshot"

# The platform-operator PAT. Issued ONCE and kept in the Secret: re-issuing on
# every run would litter the identity schema with live credentials nobody holds.
if "${KUBECTL[@]}" get secret gitfrok-operator-pat -n "$NS" >/dev/null 2>&1; then
  echo "  operator PAT secret gitfrok-operator-pat already present (create-once)"
else
  "${KUBECTL[@]}" port-forward svc/dataplane -n "$NS" 19090:9090 >/dev/null 2>&1 &
  OP_PF=$!
  trap 'kill "$OP_PF" 2>/dev/null || true' EXIT
  op_tries=0
  # No gRPC reflection on the door, so `grpcurl list` cannot probe it; a real
  # method call serves instead. AuthenticatePAT is the probe of choice: unlike
  # the lifecycle methods it is NOT authorization-gated (the door answers an
  # empty OK response for an unknown token), so it exits 0 exactly when the
  # door is serving.
  until grpcurl -plaintext -import-path governance/contracts \
      -proto proto/identity/v1/identity.proto \
      -d '{"personal_access_token":"gfp_provision-probe_probe"}' \
      127.0.0.1:19090 gitsaas.identity.v1.CredentialAuthenticator/AuthenticatePAT >/dev/null 2>&1; do
    op_tries=$((op_tries + 1))
    [ "$op_tries" -lt 30 ] || die "identity door never answered on the port-forward"
    sleep 1
  done
  op_pat=$(grpcurl -plaintext -import-path governance/contracts \
    -proto proto/identity/v1/identity.proto \
    -d '{"tenant_id":"dev","actor_id":"user-admin","label":"platform-operator","scope_labels":["repo.read","repo.write"],"roles":["owner"]}' \
    127.0.0.1:19090 gitsaas.identity.v1.CredentialAuthenticator/IssuePAT \
    | python3 -c "import json,sys;print(json.load(sys.stdin).get('plaintextToken',''))") \
    || die "IssuePAT against the identity door failed"
  [ -n "$op_pat" ] || die "IssuePAT returned no plaintext token"
  "${KUBECTL[@]}" create secret generic gitfrok-operator-pat -n "$NS" \
    --from-literal=token="$op_pat" >/dev/null || die "writing gitfrok-operator-pat failed"
  unset op_pat
  kill "$OP_PF" 2>/dev/null || true
  trap - EXIT
  echo "  operator PAT issued through gitsaas.identity.v1.CredentialAuthenticator/IssuePAT -> secret gitfrok-operator-pat"
fi

# Prove the credential round-trips before Stage D is asked to spend it: the
# verifier key the doors read and the key the PAT was issued under must agree.
"${KUBECTL[@]}" port-forward svc/dataplane -n "$NS" 19090:9090 >/dev/null 2>&1 &
OP_PF=$!
trap 'kill "$OP_PF" 2>/dev/null || true' EXIT
op_tries=0
# Same probe shape as above: AuthenticatePAT answers OK for any token shape,
# so it signals "door serving" without needing an authorized principal.
until grpcurl -plaintext -import-path governance/contracts \
    -proto proto/identity/v1/identity.proto \
    -d '{"personal_access_token":"gfp_provision-probe_probe"}' \
    127.0.0.1:19090 gitsaas.identity.v1.CredentialAuthenticator/AuthenticatePAT >/dev/null 2>&1; do
  op_tries=$((op_tries + 1))
  [ "$op_tries" -lt 30 ] || die "identity door never answered for the PAT roundtrip"
  sleep 1
done
op_token=$("${KUBECTL[@]}" get secret gitfrok-operator-pat -n "$NS" -o jsonpath='{.data.token}' | base64 -D)
# The door answers OK with an EMPTY body for an unknown token, so "the RPC
# succeeded" is not the assertion — the resolved principal is.
op_auth=$(grpcurl -plaintext -import-path governance/contracts \
  -proto proto/identity/v1/identity.proto \
  -d "{\"personal_access_token\":\"$op_token\"}" \
  127.0.0.1:19090 gitsaas.identity.v1.CredentialAuthenticator/AuthenticatePAT) \
  || die "AuthenticatePAT RPC failed for the operator PAT"
printf '%s' "$op_auth" | grep -q '"principal"' \
  || die "operator PAT did not resolve to a principal — verifier key rotated under an issued PAT?
  (dev-up.sh creates gitfrok-pat-verifier create-once precisely to prevent this)"
unset op_token op_auth
kill "$OP_PF" 2>/dev/null || true
trap - EXIT
echo "  operator PAT authenticates against the identity door"

# ------------------------------------------------------------------ 2. Zitadel client
step "Zitadel OIDC client for the BFF (headless, idempotent)"
# The login-client PAT: written once by the FirstInstance setup into the bootstrap
# PVC, readable from the Login V2 UI pod (which mounts it read-only).
PAT=$("${KUBECTL[@]}" exec deployment/zitadel-login -n "$NS" -- \
  cat /zitadel/bootstrap/login-client.pat 2>/dev/null | tr -d '\r') \
  || die "cannot read the login-client PAT — is zitadel-login up? re-run dev-up"
[ -n "$PAT" ] || die "login-client PAT is empty — did Zitadel setup run on a fresh instance?"

# Console client id, read from Zitadel's own projections (created by FirstInstance).
CONSOLE_CLIENT=$("${KUBECTL[@]}" exec deployment/postgres -n "$NS" -- \
  psql -U postgres -d zitadel -tAc \
  "SELECT oc.client_id FROM projections.apps7_oidc_configs oc JOIN projections.apps7 a ON a.id=oc.app_id AND a.instance_id=oc.instance_id WHERE a.name='Management Console'") \
  || die "cannot resolve the console client id from Zitadel projections"
CONSOLE_CLIENT=$(printf '%s' "$CONSOLE_CLIENT" | tr -d '\r ')

# Admin access token via the same surface the Login V2 UI uses:
#   session check API (login-client PAT) -> OIDC authRequest -> callback -> code -> token.
ADMIN_TOKEN=""
console_token() {
  local body sid token verifier challenge q loc authreq code
  body=$(http /v2/sessions -X POST \
    -H "Authorization: Bearer $PAT" -H "Content-Type: application/json" \
    -d "{\"checks\":{\"user\":{\"loginName\":\"$ADMIN_LOGIN\"},\"password\":{\"password\":\"$ADMIN_PASSWORD\"}}}") \
    || die "session check failed (login-client PAT stale?)"
  sid=$(printf '%s' "$body" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('sessionId',''))")
  token=$(printf '%s' "$body" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('sessionToken',''))")
  [ -n "$sid" ] && [ -n "$token" ] || die "session check: no sessionId/sessionToken"

  verifier=$(head -c 48 /dev/urandom | base64url)
  challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | base64url)
  q=$(python3 - "$CONSOLE_CLIENT" "$challenge" <<'PYEOF'
import sys, urllib.parse
print(urllib.parse.urlencode({
  "client_id": sys.argv[1],
  "redirect_uri": "https://zitadel.gitsaas.test/ui/console/auth/callback",
  "response_type": "code", "scope": "openid profile email", "state": "prov",
  "code_challenge": sys.argv[2], "code_challenge_method": "S256"}))
PYEOF
    )
  loc=$(curl -sk --max-time "$TIMEOUT" -o /dev/null -w '%{redirect_url}' \
        "$ISSUER/oauth/v2/authorize?$q") || die "authorize failed"
  authreq=$(printf '%s' "$loc" | python3 -c "import sys,urllib.parse;print(urllib.parse.parse_qs(urllib.parse.urlparse(sys.stdin.read()).query)['authRequest'][0])")
  [ -n "$authreq" ] || die "no authRequest from authorize ($loc)"

  code=$(http "/v2/oidc/auth_requests/$authreq" -X POST \
    -H "Authorization: Bearer $PAT" -H "Content-Type: application/json" \
    -d "{\"session\":{\"sessionId\":\"$sid\",\"sessionToken\":\"$token\"}}" \
    | python3 -c "import sys,urllib.parse,json;print(urllib.parse.parse_qs(urllib.parse.urlparse(json.load(sys.stdin)['callbackUrl']).query)['code'][0])")
  [ -n "$code" ] || die "no code from callback"

  ADMIN_TOKEN=$(http /oauth/v2/token -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=authorization_code&code=$code&redirect_uri=https%3A%2F%2Fzitadel.gitsaas.test%2Fui%2Fconsole%2Fauth%2Fcallback&client_id=$CONSOLE_CLIENT&code_verifier=$verifier" \
    | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))")
  [ -n "$ADMIN_TOKEN" ] || die "no access token from code exchange"
}

# Already provisioned? The ConfigMap records what we created. A placeholder
# (dev-up seeds `bff`) or a stale value is treated as absent — the find below
# recovers the real app by name and the CM is re-converged afterwards.
CLIENT_ID=$("${KUBECTL[@]}" get configmap "$OIDC_CM" -n "$NS" -o jsonpath='{.data.client-id}' 2>/dev/null || true)
[ "$CLIENT_ID" = "bff" ] && CLIENT_ID=
[ -n "$CLIENT_ID" ] && echo "  client id already recorded ($CLIENT_ID)"

console_token

PROJECT_ID=$(http /management/v1/projects/_search -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d '{"queries":[]}' \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['result'][0]['id'])") \
  || die "project search failed"
[ -n "$PROJECT_ID" ] || die "no project found in the default org"

if [ -z "$CLIENT_ID" ]; then
  # A previous run may have created the app without recording it (or the CM was
  # deleted); find by name rather than creating a duplicate.
  found=$("${KUBECTL[@]}" exec deployment/postgres -n "$NS" -- \
    psql -U postgres -d zitadel -tAc \
    "SELECT oc.client_id FROM projections.apps7_oidc_configs oc JOIN projections.apps7 a ON a.id=oc.app_id AND a.instance_id=oc.instance_id WHERE a.name='$OIDC_APP_NAME' AND oc.client_id != ''" 2>/dev/null || true)
  found=$(printf '%s' "$found" | tr -d '\r ')
  if [ -n "$found" ]; then
    CLIENT_ID="$found"
    echo "  existing app '$OIDC_APP_NAME' found: client id $CLIENT_ID"
  fi
fi

if [ -z "$CLIENT_ID" ]; then
  APP_ID=$(http "/management/v1/projects/$PROJECT_ID/apps/oidc" -X POST \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
    -d "{\"projectId\":\"$PROJECT_ID\",\"name\":\"$OIDC_APP_NAME\",\"redirectUris\":[\"$BFF_REDIRECT\"],\
\"responseTypes\":[\"OIDC_RESPONSE_TYPE_CODE\"],\"grantTypes\":[\"OIDC_GRANT_TYPE_AUTHORIZATION_CODE\"],\
\"appType\":\"OIDC_APP_TYPE_WEB\",\"authMethodType\":\"OIDC_AUTH_METHOD_TYPE_NONE\",\
\"postLogoutRedirectUris\":[\"$BFF_LOGOUT\"],\"version\":\"OIDC_VERSION_1_0\"}" \
    | python3 -c "import json,sys;print(json.load(sys.stdin).get('appId',''))")
  [ -n "$APP_ID" ] || die "AddOIDCApp failed: $HTTP_BODY"
  CLIENT_ID=$(http "/management/v1/projects/$PROJECT_ID/apps/$APP_ID" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['app']['oidcConfig']['clientId'])")
  echo "  created app '$OIDC_APP_NAME': appId $APP_ID, clientId $CLIENT_ID"
fi

# ------------------------------------------------------------------ 3. BFF wiring
step "BFF client id ($CLIENT_ID)"
# The tenant mapping needs the org id of the dev instance's users — instance
# ids are generated at FirstInstance setup and differ on every fresh cluster.
# Any user of the default org resolves to it (result[0] of an unfiltered
# search is a machine user; admin is the other one — same resource owner).
ORG_ID=$(http /management/v1/users/_search -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d '{"pagination":{"limit":"1"}}' \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['result'][0]['details']['resourceOwner'])") \
  || die "cannot resolve the dev org id"
[ -n "$ORG_ID" ] || die "no org id from the user search"
"${KUBECTL[@]}" create configmap "$OIDC_CM" -n "$NS" \
  --from-literal=client-id="$CLIENT_ID" --from-literal=issuer="$ISSUER" \
  --from-literal=tenant-mapping="$ORG_ID=dev" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - || die "writing $OIDC_CM failed"
echo "  configmap $OIDC_CM updated ($ORG_ID maps to the dev tenant)"
# The data plane restart below must see the enrolment placeholder: its pinned
# binary treats an absent GITFROK_ENROLMENT_TOKEN as a config error when the
# gateway address is set (Stage C's un-enrolled-start contract).
"${KUBECTL[@]}" get secret gitfrok-enrolment-token -n "$NS" >/dev/null 2>&1 \
  || die "secret gitfrok-enrolment-token vanished before the dataplane restart — re-run dev-up.sh"
# Both consumers read from the ConfigMap (bff.yaml: client-id+issuer;
# dataplane.yaml: client-id+issuer+tenant-mapping), so both converge.
"${KUBECTL[@]}" rollout restart deployment/bff -n "$NS" >/dev/null || die "restarting bff failed"
"${KUBECTL[@]}" rollout status deployment/bff -n "$NS" --timeout=120s >/dev/null || die "bff did not come back up"
"${KUBECTL[@]}" rollout restart deployment/dataplane -n "$NS" >/dev/null || die "restarting dataplane failed"
"${KUBECTL[@]}" rollout status deployment/dataplane -n "$NS" --timeout=120s >/dev/null || die "dataplane did not come back up"

# ------------------------------------------------------------------ 4. verify roundtrip
# The browser surface for login is the Astro SSR app (webfrontend → bff, invariant 22),
# which has no login route yet — surfacing is a webfrontend task. So the verify runs
# against the BFF directly via a port-forward: same client, same issuer, same code
# exchange — the exact roundtrip the webfrontend will proxy once it exposes /login.
step "OIDC roundtrip through the BFF ($ISSUER, client $CLIENT_ID)"
"${KUBECTL[@]}" port-forward svc/bff -n "$NS" 18080:8080 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
sleep 2
BFF_BASE="http://127.0.0.1:18080"

# Simulate the browser in ONE request chain: a single /login begins a single
# PKCE flow. The BFF's first 302 carries the flow cookie (the handle the state
# check is done against); following it to the login UI yields the auth-request
# handle (the v2 UI mints it as `requestId` on the loginname page). Two /login
# calls would create TWO flows — the callback would then present the first
# flow's cookie/verifier against the second flow's code, and the issuer would
# refuse the PKCE exchange (the exact failure a browser never hits).
reqout=$(curl -skL --max-time "$TIMEOUT" -D - -o /dev/null -w '\n%{url_effective}' "$BFF_BASE/login") \
  || die "BFF /login not answering — is bff up?"
headers=$(printf '%s' "${reqout%$'\n'*}")
loc=$(printf '%s' "${reqout##*$'\n'}")
flow_cookie=$(printf '%s' "$headers" | tr -d '\r' | sed -n 's/^Set-Cookie: __Host-gitfrok_login=\([^;]*\).*/\1/p')
state=$flow_cookie
printf '%s' "$loc" | grep -q "$ISSUER" || die "BFF /login did not reach the issuer: $loc"
authreq=$(printf '%s' "$loc" | python3 -c "import sys,urllib.parse;print(urllib.parse.parse_qs(urllib.parse.urlparse(sys.stdin.read()).query)['requestId'][0].replace('oidc_','',1))")
[ -n "$flow_cookie" ] || die "no flow cookie from BFF /login"
[ -n "$authreq" ] || die "no requestId from the login UI"

# Land a session on the BFF's own auth request and complete it.
body=$(http /v2/sessions -X POST \
  -H "Authorization: Bearer $PAT" -H "Content-Type: application/json" \
  -d "{\"checks\":{\"user\":{\"loginName\":\"$ADMIN_LOGIN\"},\"password\":{\"password\":\"$ADMIN_PASSWORD\"}}}") \
  || die "session for roundtrip failed"
sid=$(printf '%s' "$body" | python3 -c "import json,sys;print(json.load(sys.stdin).get('sessionId',''))")
token=$(printf '%s' "$body" | python3 -c "import json,sys;print(json.load(sys.stdin).get('sessionToken',''))")
[ -n "$sid" ] || die "no session id — Zitadel session check failed: $body"
code=$(http "/v2/oidc/auth_requests/$authreq" -X POST \
  -H "Authorization: Bearer $PAT" -H "Content-Type: application/json" \
  -d "{\"session\":{\"sessionId\":\"$sid\",\"sessionToken\":\"$token\"}}" \
  | python3 -c "import sys,urllib.parse,json;print(urllib.parse.parse_qs(urllib.parse.urlparse(json.load(sys.stdin)['callbackUrl']).query)['code'][0])")
[ -n "$code" ] || die "no code for the BFF auth request"

# The BFF flow cookie is Secure — the port-forward is plain http, so a real
# browser would not send it back. Simulate the browser's cooperation by passing
# the cookie explicitly; state must equal the flow handle the BFF issued.
cb=$(curl -sk --max-time "$TIMEOUT" -D - -o /dev/null -H "Cookie: __Host-gitfrok_login=$flow_cookie" \
  "${BFF_BASE}/callback?code=$code&state=$state" 2>/dev/null | tr -d '\r') || die "callback exchange failed"
grep -qiE '^HTTP/1\.[01] 302|^HTTP/2 302' <<<"$cb" \
  || die "BFF callback did not complete: $(grep -i '^HTTP' <<<"$cb" | head -1)"
echo "  BFF /login -> issuer -> code exchange -> session OK"
kill "$PF_PID" 2>/dev/null || true
trap - EXIT

printf '\ndev-provision: OK — migrations applied, OIDC client %s live, BFF roundtrip verified\n' "$CLIENT_ID"