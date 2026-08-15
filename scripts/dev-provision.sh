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
#      tokens + data-plane registry, T-0036) against the app database
#      `gitfrok` — all CREATE/GRANT idempotent, applied as the postgres superuser
#      like the postgres-init ConfigMap does.
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
# then the Phase-3.1 agent enrolment/registry migration (T-0036, SPEC-0042):
# it needs only the tenancy baseline's gitfrok_app role, and applies last so
# the set still reads in landed order.
# The pinned backend selects Postgres-backed stores whenever GITFROK_DATABASE_URL
# is set (dataplane.yaml sets it), and policy Decide fails closed when
# policy.decision_records is missing — a plane provisioned without the Phase-2
# set denies every protected action, so ALL of these apply here. The agent
# tables are the durable enrolment state (ADR-0062): a plane provisioned
# without them cannot enrol a data plane.
step "Database migrations (tenant, audit, identity, policy, security, agent)"
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
  backend/modules/agent/internal/adapters/postgres/migrations/0001_agent_enrolment.sql; do
  [ -f "$m" ] || die "migration not found: $m"
  echo "  applying $m"
  "${KUBECTL[@]}" exec -i deployment/postgres -n "$NS" -- \
    psql -U postgres -d gitfrok -v ON_ERROR_STOP=1 -q < "$m" || die "migration $m failed"
done
schema_list=$("${KUBECTL[@]}" exec deployment/postgres -n "$NS" -- psql -U postgres -d gitfrok -tAc \
  "SELECT schema_name FROM information_schema.schemata") || die "cannot list schemas"
missing=""
for s in tenant audit identity policy security agent; do
  printf '%s\n' "$schema_list" | grep -qx "$s" || missing="$missing $s"
done
[ -z "$missing" ] || die "schemas missing after migrations:$missing"
echo "  schemas tenant/audit/identity/policy/security/agent present"
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
  agent.data_planes; do
  printf '%s\n' "$table_list" | grep -qx "$t" || missing="$missing $t"
done
[ -z "$missing" ] || die "tables missing after migrations:$missing"
echo "  all Phase-2 tables + agent enrolment tables present"

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