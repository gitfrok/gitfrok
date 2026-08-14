# MVP deploy runbook

The ordered path from a clean host to a running Gitfrok MVP. **Dev only** — every credential here is
a dev default and the cluster is a single Minikube node; production posture is ADR-0035, ADR-0044 and
T-0003's cluster lane, none of which this file covers.

`governance/` decides; this file only sequences it (ADR-0001). Per-manifest detail and the defect
record are in [`dev/README.md`](dev/README.md); where the work stands is [`../HANDOFF.md`](../HANDOFF.md).

**One step is not automated: host DNS (step 3), which needs root.** Everything else is `make dev-up` —
including the database migrations and the Zitadel OIDC client, which `dev-up.sh` converges by calling
`scripts/dev-provision.sh` at the end. Steps 4 and 5 document what that script does and how to do it by
hand when it fails.

## 0. Prerequisites

| Requirement | Why |
|---|---|
| `minikube`, `kubectl`, `mkcert` on `PATH` | `dev-up.sh` refuses to start without all three |
| rootless podman or docker | `--driver` is left to minikube unless `MINIKUBE_DRIVER` is set |
| ~4 CPU / 6 GiB free | the manifests request 1.66 CPU / 2000 MiB; the ingress controller needs the rest |
| `git`; Go ≥ 1.26 / Node ≥ 26 to rebuild images | floors in `.tool-versions` and `versions.env` |

```bash
make bootstrap      # submodules first — every gate reads governance/
```

## 1. Host preflight (root, once per machine)

`dev-up.sh` checks both on the create path and prints the exact fix; they are listed here because they
need root and the script deliberately does not take it.

```bash
# PID 1 in the node needs its own inotify instances. Fedora ships 128 and a desktop session can hold
# ~114, at which point systemd exits and minikube reports "StartHost failed" naming nothing about it.
printf 'fs.inotify.max_user_instances=512\nfs.inotify.max_user_watches=524288\n' |
  sudo tee /etc/sysctl.d/99-minikube-inotify.conf >/dev/null

# Publishing the node's 80/443 to the host loopback as a non-root user.
echo 'net.ipv4.ip_unprivileged_port_start=0' |
  sudo tee /etc/sysctl.d/99-unprivileged-ports.conf >/dev/null

sudo sysctl --system
```

Skip the second only with `MINIKUBE_PORTS=''` — on a VM driver the node IP routes from the host and
publishing is unsupported and unnecessary.

## 2. Bring the cluster up

```bash
make dev-up
```

Idempotent: re-running is the normal repair for a half-up cluster, and a *failed* create is deleted
rather than converged. It runs preflight → assert every manifest tag against `versions.env` →
`minikube start` with the `ingress` and `ingress-dns` addons → mkcert wildcard into
`secret/gitsaas-tls` → build and load the five first-party images → publish the policy bundle
ConfigMap from `governance/policies` → apply all manifests, ingress last → wait for every rollout →
create the object-tier bucket → print the host-DNS snippet.

Knobs (environment variables): `MINIKUBE_PROFILE` (`gitfrok`), `MINIKUBE_DRIVER`, `MINIKUBE_CPUS`
(4), `MINIKUBE_MEMORY` (6144), `MINIKUBE_PORTS` (`80:80,443:443`), `MINIKUBE_RUNTIME`
(`containerd` — never leave this to minikube ≤ 1.38, whose docker default fails to provision).

Two things that waste an afternoon:

- **A cluster created by hand as profile `minikube` needs `MINIKUBE_PROFILE=minikube`**, or every
  script reports six dead deployments that are running fine under another profile.
- **Images are built only when absent from the node** (`build_if_absent`). After changing code: scale
  the deployment to 0, `minikube image rm -p gitfrok docker.io/gitfrok/<image>:0.1.0`, then `dev-up`.
  `image rm` while a pod uses the image fails silently and the old build keeps running.

## 3. Wire host DNS (root, manual)

`dev-up` prints the snippet for your OS and stops: pointing `*.test` at the cluster is a system-wide
DNS change, not a side effect a bootstrap script should have. Apply it — `/etc/resolver/test` on
macOS, a NetworkManager/dnsmasq or systemd-resolved drop-in on Linux, or `/etc/hosts` lines.

Point it at **`127.0.0.1`** when ports are published, not at the node IP: a resolver aimed at an
unroutable address resolves fine and then times out, which reads as a broken cluster. Until this is
done, `make dev-smoke` reaches the ingress with `curl --resolve` and reports the DNS half as its own
distinct failure. On the verified host (dnsmasq + systemd-resolved) `dev-smoke` passes every host by
name.

## 4. Database migrations — `dev-provision` applies them

`deploy/dev/postgres.yaml` creates the T-0004 tenancy baseline from its own ConfigMap, and
`scripts/dev-provision.sh` (which `dev-up` runs, and `make dev-provision` re-runs idempotently) applies
the full backend migration set — the Phase-0/1 baseline and every Phase-2 migration, in dependency
order — as the postgres superuser. Nothing in the *cluster* applies them, so a `kubectl apply` without
the script leaves you to do it by hand:

```
backend/platform/db/migrations/0001_tenancy_baseline.sql
backend/modules/audit/internal/adapters/postgres/migrations/0001_audit_log.sql
backend/modules/audit/internal/adapters/postgres/migrations/0002_audit_evidence_indexes.sql
backend/modules/identity/internal/adapters/postgres/migrations/0001_identity_credentials.sql
backend/modules/identity/internal/adapters/postgres/migrations/0002_identity_auditor_grants.sql
backend/modules/policy/internal/adapters/postgres/migrations/0001_policy_decision_records.sql
backend/modules/security/internal/adapters/postgres/migrations/0001_security_findings.sql
backend/modules/security/internal/adapters/postgres/migrations/0002_security_triage.sql
backend/modules/security/internal/adapters/postgres/migrations/0003_security_scan_report.sql
```

Order matters: the tenancy baseline creates the schemas and the `gitfrok_app` role the module
migrations grant to; audit 0002 indexes the tables audit 0001 creates; identity 0002 and policy 0001
build on the baseline's RLS pattern; security 0002/0003 extend 0001's tables. The provisioning script
verifies after applying — schemas `tenant/audit/identity/policy/security` present, and one table per
Phase-2 migration (including `policy.decision_records` and the security scan/triage set).

Skipping the Phase-2 set is not a partial state: the pinned backend selects Postgres-backed stores
whenever `GITFROK_DATABASE_URL` is set (`deploy/dev/dataplane.yaml` sets it), and policy `Decide`
fails closed when `policy.decision_records` is missing — a plane provisioned without it denies every
protected action.

```bash
kubectl --context gitfrok exec -i deploy/postgres -- \
  psql -U postgres -d gitfrok < backend/modules/audit/internal/adapters/postgres/migrations/0001_audit_log.sql
```

Two sources of schema truth is a known gap (`../HANDOFF.md`). Do not close it by editing the
manifest — that hides the drift instead of shrinking it.

**The application connects as `gitfrok_app`, never `postgres`.** RLS does not bind a superuser, and
binds the table owner only when forced; a DSN pointing at `postgres` makes tenant isolation inert
while still reporting as enabled.

### 4a. Operational notes for the Phase-2 schema

- **The security merge gate engages on every storage-backed plane.** Once the security migrations are
  applied, merge decisions compose the findings facts and deny any merge whose head or base revision
  lacks an ingested, complete scan. Rollout prerequisite: **scan coverage before enabling the gate on
  existing repositories** — every repo that must keep merging needs a scan ingested first, or its
  merges fail closed. In dev there is **no scan-dispatch path at all** (no gVisor RuntimeClass on this
  host; scans can only be ingested by RPC), so the gate can deny everything a CI flow would otherwise
  have gated; that dispatch capability is T-0003's cluster lane.
- **The MR-findings projection is in-process memory.** A dataplane restart drops the per-MR findings
  projection, and MRs opened before the restart merge-block until a new push or retarget re-emits the
  events that rebuild it. Rollout impact: after any dataplane restart, open MRs need a touch (push or
  retarget) before their merge decisions see findings facts again. Follow-up: seed the projection at
  startup from the durable stores (tracked against the findings plane, not a dev-env item).
- **Decision-record append is async and fail-closed at admission.** Appends run off the `Decide`
  hot path through a bounded queue (`backend/modules/policy/internal/app/recorder.go`): an enforced
  decision that cannot be admitted — the queue saturated — still fails the decision, exactly as a
  failing synchronous append did. Once admitted, a store failure inside the worker can no longer fail
  the decision: it is counted and logged. SPEC-0029 AC1 ("every enforced decision is recorded and
  retrievable") therefore holds up to store availability, plus a queue-depth window on a non-clean
  exit (a graceful shutdown drains the queue; the `os.Exit(1)` paths skip the drain). That is an
  operational availability contract as much as an evidence one: **alert on decision-record lag** —
  monitor the `FailedRecords` (records the store refused inside the worker) and `DroppedRecords`
  (dry-run records shed under backpressure) counters, because a sick database now reads as missing
  audit data behind admission refusals, not as a plane that denies everything.

## 5. Zitadel OIDC client — `dev-provision` creates it

`dev-provision.sh` creates the BFF's OIDC web application if it does not exist, driving the admin login
headlessly through the same API surface the Login V2 UI uses — no browser, no console. It writes the
resulting client ID into the ConfigMap `gitfrok-oidc`, restarts the BFF, and then **verifies the full
code flow against the real issuer**, which is the scenario's "OIDC login" step proved rather than
assumed.

Its configuration, matching `deploy/dev/bff.yaml`:

| Variable | Value |
|---|---|
| `GITFROK_OIDC_ISSUER` | `https://zitadel.gitsaas.test` |
| `GITFROK_OIDC_CLIENT_ID` | `bff` |
| `GITFROK_OIDC_REDIRECT_URI` | `https://app.gitsaas.test/callback` |
| `GITFROK_OIDC_SCOPE` | `openid profile email` |

To do it by hand after a provisioning failure: log in at `https://zitadel.gitsaas.test` as
`admin@gitsaas.test` / `ChangeMe123!` and create a web application with exactly that client ID and
redirect URI, PKCE as the auth method (ADR-0045).

Browser sessions live in **Valkey** (`GITFROK_SESSION_STORE=valkey`, ADR-0049 decision 5), which the
BFF opens itself under the single waiver ADR-0052 grants. A configured store it cannot reach is fatal
at startup, so a broken cache shows up as a BFF that refuses to start rather than one that silently
logs everyone out; an init container waits for `valkey:6379` so a cold cluster does not race it.

## 6. The object tier — nothing to do

`dev-up` wires it: `git-storaged` and the data plane get the five `GITFROK_SEAWEEDFS_S3_*` variables,
the credentials are upserted as a Secret, and the `gitfrok` bucket is created before anything can
write. LFS works.

**Bucket creation is the one step `dev-up` warns about instead of dying on** — the cluster is otherwise
usable and only LFS is affected, but writes into a missing bucket are *accepted and lost*. If you see
that warning, run the command it prints:

```bash
echo 's3.bucket.create -name gitfrok' |
  kubectl --context gitfrok exec -i -n default deployment/seaweedfs -- weed shell
```

What runs here is the **S3 adapter**, not ADR-0050's FUSE mount, because the mount does not propagate
to the node on this driver — measured, with the full evidence and the two defects it exposed in
[`dev/README.md`](dev/README.md#the-object-tier-wired-to-s3-because-the-fuse-mount-cannot-propagate-here).
ADR-0050 decision 6 keeps the S3 adapter for exactly this case, and `dev-smoke` reports which tier is
in use. On a driver that does propagate mounts: `MOUNT_DAEMONSET=1 make dev-up`.

Live bare repositories touch neither tier: `GITFROK_GIT_STORAGE_ROOT` stays on the block-backed PVC
(ADR-0033) and `git-storaged` refuses a FUSE repository root (invariant 7).

## 7. Verify

```bash
make dev-smoke
```

Asserts T-0003's AC2/AC3: every deployment has an available replica; every image actually running
comes from `versions.env`; `secret/gitsaas-tls` exists and is a TLS secret; `GET
https://hello.gitsaas.test/` returns 200; the certificate validates against the mkcert root CA; the
body is the hello fixture rather than another backend answering. It never uses `curl -k`, and
classifies failures — unresolvable host, untrusted certificate, connection refused, wrong backend,
non-200 — because they have different fixes.

Then by hand: `https://app.gitsaas.test` (the web app; Ctrl+K opens the palette),
`https://zitadel.gitsaas.test` (console), `https://hello.gitsaas.test` (the fixture line),
`https://s3.gitsaas.test` and `https://filer.gitsaas.test` (SeaweedFS S3 and filer).

Proving the object tier end to end:

```bash
kubectl --context gitfrok port-forward -n default svc/seaweedfs 18333:8333 &
cd backend && GITFROK_TEST_SEAWEEDFS_ENDPOINT=http://127.0.0.1:18333 \
  GITFROK_TEST_SEAWEEDFS_BUCKET=gitfrok \
  GITFROK_TEST_SEAWEEDFS_ACCESS_KEY=minioadmin GITFROK_TEST_SEAWEEDFS_SECRET_KEY=minioadmin \
  go test ./platform/objectstore/ -run TestLiveSeaweedFS -count=1
```

Five tests: round trip, absent object, presigned fetch, unsigned request refused, tampered presigned
URL refused. All pass against this cluster.

## 8. The MVP scenario

The Phase-1 exit bar is one run: **OIDC login → clone → durable push → open MR → direct push to a
protected ref denied → approve and merge → CI job runs and gates merge → audit trail → failover
promotes the in-sync replica.**

| Step | On this cluster |
|---|---|
| OIDC login | **yes**, once step 5 is done |
| clone / push over HTTPS and SSH | **yes** |
| durable push (primary + in-sync replica ack) | **no** — one node; proved by T-0012's tests and T-0018's two-node suite |
| open MR, direct push to a protected ref denied | **yes** — the denial is a PDP decision, not a UI affordance |
| approve and merge | **yes** |
| CI job runs, status gates merge | **no** — no gVisor RuntimeClass under rootless podman |
| audit trail | **yes**, once step 4 is done |
| failover promotes the in-sync replica | **no** — one node |
| LFS push/fetch through the plane | **yes** |

Two of those three gaps are the same gap: **this host is one node without a hypervisor.** Closing it
is T-0003's cluster lane — a second physical node running SPEC-0018's production coordinator, and an
attached volume rather than a local partition. Phase 1 closed with both recorded as limits of this
host, not as open code (governance #130).

### 8a. Verified end-to-end run (2026-08-11)

The code-driven half was executed live and passed: PAT issuance over the gRPC door, push,
protected-ref direct push **denied and audited**, `SetBranchProtection` forwarded to the storage node,
MR open (refs announced cross-process via `GitStorage.SubscribeRefUpdates`), review approve, merge,
`main` moved, audit chain intact.

```bash
# 1. PAT via the identity door (port-forward dataplane 9090)
grpcurl -plaintext -import-path ../governance/contracts \
  -proto proto/identity/v1/identity.proto \
  -d '{"tenant_id":"dev","actor_id":"user-admin","label":"phase1",
       "scope_labels":["repo.read","repo.write"],"roles":["owner"]}' \
  127.0.0.1:9090 gitsaas.identity.v1.CredentialAuthenticator.IssuePAT

# 2. push / protected-ref denial (smart HTTP over the ingress; the TLS CA is not in the system store)
export GIT_SSL_CAINFO="$(mkcert -CAROOT)/rootCA.pem"
git remote set-url origin "https://admin:$PAT@git.gitsaas.test/git/dev/acme.git"
git push origin main        # first push, no protection yet
grpcurl -plaintext -import-path ../governance/contracts \
  -proto proto/codereview/v1/codereview.proto \
  -d '{"context":{"tenant_id":"dev","repository_id":"acme","actor_id":"user-admin",
       "request_id":"r1","actor_roles":["owner"]},
       "target_ref":"refs/heads/main","required_approvals":1}' \
  127.0.0.1:9090 gitsaas.codereview.v1.MergeRequestService.SetBranchProtection
git push origin main        # now rejected: "refs/heads/main is protected"

# 3. MR flow — refs are FULL names; "main" is denied before any store lookup
git push -u origin feature/mr-flow
grpcurl … CreateMergeRequest   # source_ref:"refs/heads/feature/mr-flow" target_ref:"refs/heads/main"
grpcurl … SubmitReview         # REVIEW_DISPOSITION_APPROVE, expected_version:1
grpcurl … MergeMergeRequest    # expected_version:2 → state MERGED, main moves

# 4. Audit chain (RLS-scoped read; dev denies without SET)
kubectl exec deploy/postgres -- psql -U gitfrok_app -d gitfrok -c \
  "SET app.tenant_id='dev'; SELECT tenant_seq, action, outcome, left(hash,12)
   FROM audit.entries ORDER BY tenant_seq;"
# entry 1 is the genesis root (prev_hash NULL); every later row chains.
```

**In-memory stores reset with the plane.** A dataplane or git-storaged restart clears the ref
projection, protection rules and every issued PAT — re-create or re-push the bare repo, re-apply
`SetBranchProtection`, and re-issue the PAT before re-running the flow.

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `StartHost failed`, nothing about inotify | PID 1 in the node got no inotify instances | step 1's first sysctl |
| `volume with name gitfrok already exists` | a failed create orphaned the podman volume | `dev-up` sweeps these; otherwise remove it by hand |
| `Job for docker.service failed` while provisioning | `MINIKUBE_RUNTIME` unset on minikube ≤ 1.38 | `MINIKUBE_RUNTIME=containerd` |
| six deployments reported dead, cluster is fine | wrong profile | `MINIKUBE_PROFILE=minikube` |
| hosts resolve but every request times out | resolver points at the unroutable node IP | point it at `127.0.0.1` |
| Redpanda crash-loops, *"Incompatible downgrade detected"* | the pin moved **down** a minor | delete `redpanda-pvc`; there is no in-place path |
| the data plane exits at boot | no loadable policy bundle | re-run `dev-up` to republish the ConfigMap from `governance/policies` |
| every authorization decision denies | the bundle loaded with zero `.rego` files | `dev-up` refuses this now; confirm the ConfigMap holds rules, not just `.manifest` |
| an RWO-backed pod deadlocks on rollout | `RollingUpdate` against a single-writer volume | `strategy: Recreate` (already set on the four stateful deployments) |
| rebuilt image has no effect | `build_if_absent` | scale to 0, `minikube image rm`, re-run `dev-up` |
| data plane crash-loops: `RegisterService called after Server.Serve` | the policy gRPC door raced registration | fixed in `ServePolicy()` (backend #54); rebuild the image |
| fresh repo pushes but MR open or `refs` lookups fail | a plane restart cleared the ref projection | re-push the bare repo, re-apply protection, re-issue the PAT |
| MR open denied despite valid refs | short ref names | pass full ref names in codereview RPCs |

## 10. Teardown

```bash
minikube delete -p gitfrok        # removes the node container and its podman volume
```

Delete the profile **before** removing anything by hand: once the registration is gone minikube can
no longer clean its own volume, and the next create fails on a name collision.

## References

ADR-0024 Minikube-only dev · ADR-0023 stack floors · ADR-0034 image pinning · ADR-0033 block volumes
· ADR-0050 / ADR-0051 large objects · ADR-0045 OIDC · ADR-0049 BFF sessions · ADR-0035 supply chain ·
SPEC-0018 durability quorum · SPEC-0023 LFS transport · T-0003 dev environment · T-0018 import.
