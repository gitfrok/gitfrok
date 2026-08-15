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
| ~4 CPU / 6 GiB free | the manifests request 1.81 CPU / 2384 MiB; the ingress controller needs the rest |
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
- **CI scan-report ingest is wired; its operational defaults are mirrored here (invariant 13).**
  T-0029 (backend 49d6bfa) has `CIJobFinished` events drive Security's ingester — the runner
  persists the raw report and findings/scans land under the job's own principal. The limits are
  per-environment configuration with these defaults: `GITFROK_CI_SCAN_REPORT_MAX_BYTES` = 16777216
  (16 MiB) — an oversized report is refused at write, never truncated;
  `GITFROK_CI_SCAN_REPORT_RETENTION_DAYS` = 30 — the sweep deletes report objects only, leaving the
  derived findings/scans/audit records untouched; `GITFROK_CI_SCAN_SWEEP_INTERVAL` = 5m — each tick
  runs the backfill (idempotent re-ingest) first, then the retention sweep. Scan dispatch itself
  still awaits the cluster lane (gVisor), so on this host reports arrive only by RPC as above.
- **The agent gateway is wired and closed by default; its operational defaults are mirrored here
  (invariant 13).** T-0030 (backend 8e5d013) mounts the door only when `GITFROK_AGENT_GRPC_ADDR` is
  set — empty means the door stays closed and nothing listens. The rest are per-environment
  configuration with these defaults: `GITFROK_AGENT_SERVER_NAMES` = localhost,
  `GITFROK_AGENT_CERT_LIFETIME` = 1h, `GITFROK_AGENT_ROTATION_LEAD` = 20m,
  `GITFROK_AGENT_ROTATION_RETRY` = 1m, `GITFROK_AGENT_STALE_AFTER` = 5m,
  `GITFROK_AGENT_TOKEN_MAX_LIFETIME` = 24h, `GITFROK_AGENT_HEARTBEAT_INTERVAL` = 30s,
  `GITFROK_AGENT_CLOCK_SKEW_LEEWAY` = 5m. One symptom to know: **clock skew disconnects healthy
  data planes and reads as a network fault** — tokens and heartbeats outside the leeway are refused,
  so check clock sync before chasing network issues.
- **Residency detection's operational defaults are mirrored here (invariant 13).** T-0033 (backend
  c630a1e) reads `GITFROK_RESIDENCY_DETECTION_WINDOW` and `GITFROK_RESIDENCY_MAX_REPORT_INTERVAL`;
  unset → 0 is fail-safe, but it makes every residency section of an evidence pack render a gap.
  Operators must set both for complete evidence packs.
- **Fair-use metering's operational defaults are mirrored here (invariant 13).** T-0034 (backend
  d3f4ad6, bff e2344de) opens the usage door only when `GITFROK_USAGE_GRPC_ADDR` is set — empty
  means the door stays closed; the BFF mounts its usage routes only when `GITFROK_USAGE_ADDR` is
  set — empty means the routes stay unmounted. The metering limits are per-environment configuration
  with these defaults: `GITFROK_METERING_GAP_AFTER` = 15m,
  `GITFROK_METERING_DIVERGENCE_TOLERANCE` = 0.05, `GITFROK_METERING_THROTTLED_CONCURRENCY` = 2,
  `GITFROK_METERING_QUEUE_DEPTH_CAP` = 50, `GITFROK_METERING_CI_MINUTES_NOTIFY` = 8000,
  `GITFROK_METERING_CI_MINUTES_ENVELOPE` = 10000. Enforcement is **throttle-and-notify only — git
  is never blocked**; read-only enforcement is deferred to PR-7 per ADR-0061.
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

## 6a. OpenBao custody service — initialize and quorum unseal (T-0040 AC5)

`dev-up` applies `deploy/dev/openbao.yaml`: three OpenBao 2.6 nodes on integrated Raft storage
(one PVC per node), control-plane-side only (ADR-0066). The pods boot **sealed** and report
NotReady until a quorum of share-holders unseals them — that is the intended state, not a failed
rollout. Nothing in `dev-up` unseals them, and nothing may: unseal is a human quorum act over
Shamir shares (ADR-0066 decision 4), and no auto-unseal exists anywhere in the deployment.

**Where this sits in the bring-up order.** The composition-root swap has landed (backend
b0ab32e, T-0040 Wave 3b): the control plane composes its CA exclusively through custody, and
the moment it is deployed with the agent door configured (`GITFROK_AGENT_GRPC_ADDR` set),
**unseal must precede control-plane start** — a sealed custody service cannot sign, and the
production composition root holds no other key (the dev CA is unreachable from it by
construction, SPEC-0044 AC1/AC3; fitness-asserted in `internal/arch`). The current dev
deployment still runs the Phase-1 healthz-only image, so on this cluster the step may still run
any time after step 2 until the custody-enabled image ships.

### Initialize — once per cluster, ever

```bash
kubectl --context gitfrok exec -n default openbao-0 -- \
  bao operator init -key-shares=5 -key-threshold=3
```

The 5-share / 3-threshold shape is recorded on the StatefulSet
(`custody.gitsaas/key-shares`, `custody.gitsaas/key-threshold`) so this command and the
deployment assertion cannot drift apart. The output is five unseal keys and an initial root
credential, shown once. **Share custody**: split the five keys across distinct operators (dev:
distinct storage locations you control), distributed **out of band** — never in this repo, never
in the cluster, never in any environment file. The recovery keys are operator-held and out of
band by decision; that is distinct from the CA private-key posture, which never leaves the
barrier at all.

**The initial root credential is the dev-only bootstrap authority.** It authorizes exactly the
one-time wiring below — enabling Kubernetes auth, the transit mount, and the consumer policy and
role — and nothing else: it is held as a shell variable (`ROOT`), never written to disk, never
persisted, and no runtime path uses it (Kubernetes auth is the only client path, ADR-0066
decision 5). It does NOT create the CA key — the control plane is the key's single creator, on
first bootstrap, through Kubernetes auth; that posture and everything it does NOT authorize is
§6b.

### Unseal — every cold restart, before any consumer starts

Each node needs the threshold of shares, and order matters only for the first node: unseal
`openbao-0` first so Raft can elect a leader, then the other two, which rejoin automatically via
their `retry_join` entries.

```bash
kubectl --context gitfrok exec -it -n default openbao-0 -- bao operator unseal
# paste the threshold number of distinct shares when prompted; repeat for openbao-1, openbao-2
```

A share works on every node; a node reports `Sealed: false` once it holds the threshold.

Two sequencing notes from live bring-up:

- A freshly started standby reports `Initialized: false` and refuses unseal until it has pulled
  the initialized Raft state from the leader — wait for `Initialized: true` before feeding it
  shares (it arrives on its own via `retry_join`, typically within seconds).
- **Pod updates** (the StatefulSet uses `OnDelete` because a rolling controller would deadlock
  on never-Ready sealed nodes): delete standbys first and unseal each before the next, then the
  leader last — quorum survives the whole sequence.

### Wire Kubernetes auth and the CA consumer — after the first unseal

The server-side identity is the pod's own ServiceAccount (`openbao`, granted token-review
delegation by the manifest). Wiring is a few writes under the initial root credential — dev
shell variable `ROOT`, never persisted:

```bash
K() { kubectl --context gitfrok exec -i -n default openbao-0 -- env BAO_TOKEN="$ROOT" "$@"; }
K bao auth enable kubernetes
K bao write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"
K bao secrets enable transit
K bao policy write agent-ca - <<'POLICY'
path "transit/keys/agent-ca*" { capabilities = ["create", "read", "update"] }
path "transit/sign/agent-ca*"   { capabilities = ["update"] }
POLICY
K bao write auth/kubernetes/role/agent-ca \
  bound_service_account_names=controlplane bound_service_account_namespaces=default \
  policies=agent-ca ttl=1h
```

No static credential is persisted anywhere — a caller's service-account JWT is exchanged for a
short-lived OpenBao credential at login, which is the only client path allowed (ADR-0066
decision 5). The role binds exactly the `controlplane` ServiceAccount declared by
`deploy/dev/controlplane.yaml` (the consumer's projected SA token is the login credential —
zero static credentials on either side), and the policy admits key creation, public-half reads
and digest signing and nothing else. **The transit key itself is NOT created in this block —
there is exactly one key creator: the control plane.** It creates `agent-ca` on first bootstrap
through the policy's key-create capability (ComposeIssuer, ecdsa-p256, `exportable=false`) and
re-attaches through the key's public half on every later start; operators unseal and hold
shares — they never create the key, and a manual `bao write transit/keys/...` is out of
procedure (Wave-3 review C1 fix, backend 7d5b693). The key rationale and the staged-rotation
reuse of this policy/role shape are §6b; the end-to-end proof from a service-account JWT to a
signature through this exact key is the live test `TestLiveOpenBaoKubernetesAuthConsumer` in
`backend/modules/agent/internal/adapters/custody/`, run against this cluster.

### Verify

```bash
kubectl --context gitfrok exec -n default openbao-0 -- bao status     # Sealed false; HA mode active
kubectl --context gitfrok exec -n default openbao-1 -- bao status     # Sealed false; standby
kubectl --context gitfrok exec -n default openbao-0 -- bao auth list  # kubernetes/ present
```

### Seal or custody outage

- **Issuance and rotation stop; certificates already issued remain valid until expiry.** Loss of
  custody is an availability event, never an integrity event — that bound is the blast radius to
  plan around (ADR-0066 decision 6).
- Writes — transit signing included — serialize through the active node. Losing one standby
  changes nothing; the leader failing promotes a standby automatically. Losing two of three
  nodes stops writes until a quorum is back.
- After any cold restart every node is sealed again: repeat the unseal procedure above before
  starting whatever consumes custody.
- Loss of enough shares to reach the threshold means the barrier cannot be reconstituted. In dev
  that is delete the three `data-openbao-*` PVCs and re-initialize; the posture exists precisely
  so production treats that as a decision, not a command.
  Dev recovery gotcha (hostpath-provisioner): deleting the PVCs does not clear the node's disk,
  so the fresh pods come up reading stale Raft state and refuse to initialize. After deleting the
  PVCs, wipe the data directories before the pods restart into them:

  ```bash
  kubectl --context gitfrok exec -n default openbao-0 -- sh -c 'rm -rf /openbao/data/*'  # each node
  ```

## 6b. Agent CA custody — provisioning and rotation operations (T-0040 AC4)

The control plane composes its CA exclusively through the custody service (backend b0ab32e:
the production composition root has no dev CA and no key-material path — `internal/arch` fitness
asserts both, SPEC-0044 AC1/AC3). This section is the operator side of that posture: provisioning
the key, rotating it, and the failure cases the rotation window creates.

### Provision the CA key — the control plane is the single creator

Key creation is never a manual operator step (Wave-3 review C1 fix, backend 7d5b693): exactly
one creator exists — the control plane creates `agent-ca` on first bootstrap through the
Kubernetes-auth login and the custody policy's key-create capability (ecdsa-p256,
`exportable=false`), and re-attaches through the key's public half on every later start. What
an operator provisions by hand is ONLY the wiring that admits it — the transit mount, the
narrow sign-through policy and the single-SA role, the block in **§6a** ("Wire Kubernetes auth
and the CA consumer"), executed exactly as written there against this cluster. Its posture facts:
`exportable=false` means the private half never leaves the barrier —
the control plane holds the key REFERENCE and signs DIGESTS through the seam (ADR-0064 decision 2);
the policy admits key creation (bootstrap/staging), public-half reads and digest signing and
nothing else — no decrypt, no wrap/unwrap, no secret reads, no deletion; the role binds exactly
one service account (`controlplane` in `default`, declared by `deploy/dev/controlplane.yaml`) —
Kubernetes auth is the only client path (ADR-0066 decision 5). A staged rotation key reuses the
same policy and role: its name matches the `agent-ca*` glob by convention
(`agent-ca-<generation>`); staging it is step 1 of the rotation below.

The consumer's env (the custody-enabled control-plane image; the dev deployment still pins the
pre-custody image 0.1.0 and will take these when it moves): `GITFROK_CUSTODY_OPENBAO_ADDR`
(https enforced — plain http only on loopback behind an explicit dev flag),
`GITFROK_CUSTODY_TRANSIT_MOUNT=transit`, `GITFROK_CUSTODY_KUBERNETES_ROLE=agent-ca`,
`GITFROK_CUSTODY_KEY_NAME=agent-ca`, and `GITFROK_CUSTODY_SNAPSHOT_FILE` (REQUIRED — startup
refuses without it); the login JWT is the pod's projected service-account token, never a file
an operator hands it. The snapshot file carries the bundle's durable staging state — key
references and public certificates only, never key material (SPEC-0044 AC1) — and must be
mounted or volume-backed in a real deployment. Startup branches on what it finds: snapshot
present → Restore (the window comes back exactly where the fleet last saw it); snapshot absent
→ Bootstrap, which persists its own stage through the change hook wired before it; custody
still holds the key but the snapshot is gone → re-attach through the key's public half (fresh
revision, loudly logged). A corrupt or partial snapshot fails startup loudly by design — it never
falls through to a silent re-bootstrap against a custody service that kept its keys. The file
must sit on a PERSISTENT volume to survive pod rescheduling: the current
`deploy/dev/controlplane.yaml` declares NO PVC, so that is a named deployment requirement for
the custody-enabled image when it moves — honestly carried, not added now.

### Rotate the CA — stage → overlap → remove

**What executes today vs. the named follow-up (board #20, honest):** the dual-validate window, the
distribution of staged bundles over reconcile, and removal-precondition enforcement WHEN removal
is invoked are proven in the shipped composition (T-0040's exit record names the suites).
Runtime rotation actuation is the NAMED follow-up: `Bundle.Stage` and `Bundle.RemoveRoot` have
NO production caller in the shipped binary — the rotation suites exercise them, but no operator
surface invokes them yet; the actuation seam rides with T-0041/T-0042. The procedure below is
written as it will run once the seam exists; every property it names is proven on the
distribution and window side today.

1. **Stage.** Stage the next custody key (name `agent-ca-<generation>`; created through the
   same custody seam — the policy's key-create capability admits it, so staging needs no
   manual `bao write`) into the bundle. From that instant the dual-validate window is open: BOTH roots
   validate, and new issuance chains to the NEW root. The reconcile channel distributes the change
   as `DesiredState.ca_trust_bundle` — revision is the staging epoch, and the CHANNEL distributes
   BOTH roots during the window. Honest limit today: no data-plane consumer applies the bundle
   yet — that application half rides with T-0041/T-0042 — so "no re-enrolment" is the window's
   designed property, proven on the distribution side, not behaviour data planes already execute.
2. **Overlap.** Wait out every certificate the OLD root issued. Leaf lifetime is
   `GITFROK_AGENT_CERT_LIFETIME` (default 1h, §4a), so an overlap beyond that bound drains the
   old root's live certificates on its own — no per-plane action.
3. **Remove — the precondition is named:** the old root leaves ONLY after every certificate it
   signed has expired. Removal before then is REFUSED (`ErrRootStillNeeded`), changes nothing and
   distributes nothing — including while a signature for that root is still in flight. After the
   overlap, removal lands, the staging revision advances, and the channel converges on the
   surviving root (data-plane application of that convergence is the T-0041/T-0042 carry above).

A control-plane restart mid-window changes nothing: the window state (roots, ledger, staging
revision) persists to the configured `GITFROK_CUSTODY_SNAPSHOT_FILE` — written atomically
(temp file, fsync, rename, mode 0600), so a torn write leaves the previous complete snapshot
or none — and the restarted control plane restores it and re-publishes exactly the revision
the fleet last saw.

### Cold restart of the custody service

Every OpenBao node boots sealed after any restart: the quorum-unseal procedure in **§6a** must
complete before the control plane can issue or rotate. Unseal order, share custody and the
standby-initialization wait are all there.

### Seal or custody outage, mid-operation

The blast-radius entry lives in §6a ("Seal or custody outage") and binds here: issuance and
rotation stop; certificates already issued remain valid to expiry. Availability, never integrity.

### Enrolment in flight when custody is down (SPEC-0042 AC6)

Chosen behaviour, proven by the signer-failure test: **the control plane releases the enrolment
claim when issuance fails**, so the customer's one-time token stays spendable. Operator action:
restore custody (§6a unseal), then let the data plane retry with the SAME token — the retry
re-binds the SAME `data_plane_id` the claim recorded; one token never mints a second identity
(ADR-0060), whichever side of the failure the retry lands.

### Clock skew, the symptom that reads as a network fault

A skewed CUSTOMER cluster presents as disconnects and failed heartbeats that look like network
failure — the leeway and the diagnostic order are recorded in §4a's agent-gateway entry
(`GITFROK_AGENT_CLOCK_SKEW_LEEWAY`, T-0030). Rotation does not change that bound: a data plane
outside the leeway is refused before trust-bundle state is ever consulted. Check clock sync
before chasing networks, and before suspecting a rotation.

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
| `openbao-*` pods Never Ready | sealed — the intended state until quorum-unsealed | §6a unseal procedure (init first if the cluster never was) |

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
