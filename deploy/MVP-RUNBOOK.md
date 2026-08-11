# MVP deploy runbook

**What this is.** The operational path from a clean host to a running Gitfrok MVP, and an honest
account of which parts of the Phase-1 exit scenario that path can actually demonstrate. It is written
to be handed to someone who was not present for the work.

**What it is not.** A production deployment guide. Every credential below is a dev-only default and
the cluster is a single Minikube node. Production posture is ADR-0035
(supply chain), ADR-0044 (trust bundle) and the cluster lane of T-0003 — none of which this runbook
covers.

**Source of truth.** `governance/` decides; this file only sequences what it decided. Where the two
disagree, governance wins (ADR-0001). The per-manifest detail and the full defect history live in
[`dev/README.md`](dev/README.md); this file is the runbook, not the record.

---

## Status at a glance (2026-08-11)

| Layer | State |
|---|---|
| All ten Phase-1 tasks (T-0010…T-0018, T-0021) | **Done** |
| Cluster bring-up on Linux (`make dev-up` → `make dev-smoke`) | **verified**, including the create path |
| Cluster bring-up on macOS | **not verified** — needs a hypervisor no hosted runner has |
| Host DNS for `*.gitsaas.test` | **manual, needs root** — the script prints, it does not apply; wired and `dev-smoke`-green by name on the verified host |
| Database migrations | **manual** — nothing in the cluster applies them |
| Zitadel OIDC client for the BFF | **manual** — `dev-up` deploys Zitadel, it does not configure an app |
| LFS / artifact / image object tier | **wired to S3 and proved live**; ADR-0050's FUSE mount cannot propagate on this driver — see [step 6](#6-the-object-tier-adr-0050--adr-0051) |
| CI sandbox dispatch (gVisor) | **unavailable** under rootless podman |
| Durability quorum and failover | **proved in tests, not demonstrable here** — one node |

The last two rows are the whole of what stands between this runbook and a full end-to-end
demonstration of the Phase-1 exit scenario. Neither is missing code, and Phase 1 closed with both
recorded as limits of this host against T-0003's cluster lane (governance #130).

---

## 0. Prerequisites

| Requirement | Why |
|---|---|
| `minikube`, `kubectl`, `mkcert` on `PATH` | `dev-up.sh` refuses to start without all three |
| A container driver: rootless podman or docker | `--driver` is left to minikube unless `MINIKUBE_DRIVER` is set |
| ~4 CPU / 6 GiB free for the VM | the manifests request 1.36 CPU / 1.39 GB; the ingress controller needs the rest |
| `git`, and Go ≥ 1.26 / Node ≥ 26 if you intend to rebuild images | floors in `.tool-versions` and `versions.env` |

Clone with submodules first — every gate reads `governance/`:

```bash
make bootstrap
```

## 1. Host preflight (root, once per machine)

Both of these are checked by `dev-up.sh` on the **create** path and reported with the exact fix. They
are listed here because they need root and the script deliberately does not take it.

```bash
# The node runs systemd as PID 1 and needs its own inotify instances. Fedora ships 128 and a
# desktop session can hold ~114 of them, at which point PID 1 exits and minikube reports
# "StartHost failed" while naming nothing about inotify.
printf 'fs.inotify.max_user_instances=512\nfs.inotify.max_user_watches=524288\n' |
  sudo tee /etc/sysctl.d/99-minikube-inotify.conf >/dev/null

# Publishing the node's 80/443 to the host loopback as a non-root user.
echo 'net.ipv4.ip_unprivileged_port_start=0' |
  sudo tee /etc/sysctl.d/99-unprivileged-ports.conf >/dev/null

sudo sysctl --system
```

Skip the second one only if you set `MINIKUBE_PORTS=''` — on a VM driver the node IP routes from the
host and publishing is both unsupported and unnecessary.

## 2. Bring the cluster up

```bash
make dev-up
```

Idempotent by design: re-running it is the normal way to repair a half-up cluster, and a *failed*
create is deleted rather than converged (a half-created profile cannot be repaired in place).

It runs: preflight → assert every manifest's image tag against `versions.env` → `minikube start`
with the `ingress` and `ingress-dns` addons → mkcert wildcard into `secret/gitsaas-tls` → build and
load the five first-party images → publish the policy bundle ConfigMap from `governance/policies` →
apply all manifests with `ingress` last → wait for every rollout → create the object-tier bucket →
print the host-DNS snippet.

Knobs, all environment variables: `MINIKUBE_PROFILE` (default `gitfrok`), `MINIKUBE_DRIVER`,
`MINIKUBE_CPUS` (4), `MINIKUBE_MEMORY` (6144 MiB), `MINIKUBE_PORTS` (`80:80,443:443`),
`MINIKUBE_RUNTIME` (`containerd` — do not leave this to minikube 1.35, whose default is docker and
fails to provision).

**A cluster created by hand as profile `minikube` needs `MINIKUBE_PROFILE=minikube`,** or every
script reports six dead deployments that are in fact running under another profile.

**Images are built only when absent from the node.** After changing backend, bff or webfrontend code,
`dev-up` will keep the old image unless you remove it first:

```bash
minikube image rm -p gitfrok docker.io/gitfrok/dataplane-app:0.1.0
```

## 3. Wire host DNS (root, manual)

`dev-up` prints the snippet for your OS and stops there: pointing `*.test` at the cluster is a
system-wide DNS change, which is not a side effect a bootstrap script should have. Apply the printed
snippet — a `/etc/resolver/test` file on macOS, a NetworkManager/dnsmasq or systemd-resolved drop-in
on Linux, or `/etc/hosts` lines if you would rather not touch DNS.

Point it at **`127.0.0.1`** when ports are published, not at the node IP. A resolver aimed at an
unroutable address resolves fine and then times out, which reads as a broken cluster.

Until this is done, `make dev-smoke` reaches the ingress with `curl --resolve` and reports the DNS
half as its own distinct failure rather than a generic red.

## 4. Apply the database migrations (manual)

**Nothing in the cluster applies them.** `deploy/dev/postgres.yaml` creates the T-0004 tenancy
baseline from its own ConfigMap, and three migration directories in `backend/` are applied by hand:

```
backend/platform/db/migrations/0001_tenancy_baseline.sql
backend/modules/audit/internal/adapters/postgres/migrations/0001_audit_log.sql
backend/modules/identity/internal/adapters/postgres/migrations/0001_identity_credentials.sql
```

```bash
kubectl --context gitfrok exec -i deploy/postgres -- \
  psql -U postgres -d gitfrok < backend/modules/audit/internal/adapters/postgres/migrations/0001_audit_log.sql
```

Two sources of schema truth across two schemas is a known gap (`../HANDOFF.md`). Do not close it by
editing the manifest — that would make the drift harder to see, not smaller.

**The application must connect as `gitfrok_app`**, never as `postgres`. RLS does not bind a superuser
and does not bind the table owner unless forced; a DSN pointing at `postgres` makes tenant isolation
inert while still reporting as enabled.

## 5. Create the Zitadel OIDC client (manual)

`dev-up` deploys Zitadel and creates nothing inside it. The BFF expects an application whose client
ID is `bff`:

| BFF variable | Value in `deploy/dev/bff.yaml` |
|---|---|
| `GITFROK_OIDC_ISSUER` | `https://zitadel.gitsaas.test` |
| `GITFROK_OIDC_CLIENT_ID` | `bff` |
| `GITFROK_OIDC_REDIRECT_URI` | `https://app.gitsaas.test/callback` |
| `GITFROK_OIDC_SCOPE` | `openid profile email` |

Log in to `https://zitadel.gitsaas.test` as `admin@gitsaas.test` / `ChangeMe123!`, create a web
application with exactly that client ID and redirect URI, and PKCE as the auth method (ADR-0045).
Sessions are `GITFROK_SESSION_STORE=memory` in dev; ADR-0049 decision 5 names Valkey for a shared
store, and wiring it is outstanding.

## 6. The object tier (ADR-0050 / ADR-0051)

**Nothing to do — `dev-up` wires it.** This step is here because what it wires is not what ADR-0050
decides, and the difference matters if you deploy anywhere else.

`git-storaged` and the data plane get the five `GITFROK_SEAWEEDFS_S3_*` variables, `dev-up` upserts
the credentials as a Secret and creates the `gitfrok` bucket before anything can write. LFS works.

### Why S3 here and not the FUSE mount

ADR-0050 decides large objects come from a SeaweedFS FUSE mount; ADR-0051 produces that mount with a
privileged DaemonSet, which is the only shape Kubernetes permits — kubelet rejects
`mountPropagation: Bidirectional` on a container that is not privileged. It is built
(`deploy/dev/seaweedfs-mount.yaml`) and it does not work on this driver:

- the DaemonSet mounts `fuse.seaweedfs` and its mount is `shared` inside the pod
- the node's `/` is `shared`
- **the node's mount table never shows it**, so consumers bind the plain directory underneath

A write from `git-storaged` then lands on node-local disk and reads back fine on that node, while the
filer and the mount pod never see it. **Every gate passed while the data diverged** — `mountpoint`,
a write-then-read probe, and `objectstore.NewMount`'s own writability check. Only comparing the
consumer's view, the mount pod's view and the filer's showed it.

So the DaemonSet is not applied by default. On a node whose driver propagates mounts:

```bash
MOUNT_DAEMONSET=1 make dev-up
```

ADR-0050 decision 6 keeps the S3 adapter for exactly this case, and `make dev-smoke` says which tier
is in use rather than leaving you to guess.

### Two things that will cost you an afternoon elsewhere

1. **`weed mount` needs the filer's gRPC port — 8888+10000 = 18888 — which SeaweedFS never
   announces.** Expose it or the mount client retries `i/o timeout` forever against a filer that is
   healthy on 8888.
2. **A PUT into a bucket that does not exist returns 200** and keeps nothing, and a bucket written to
   before it was registered stays poisoned — `NoSuchBucket` on every read, no repair but a new name.
   Create the bucket first: `echo 's3.bucket.create -name gitfrok' | kubectl exec -i deploy/seaweedfs -- weed shell`.

### The credentials must not be on the `anonymous` identity

SeaweedFS's `anonymous` identity is its *unauthenticated* one: attaching keys to it grants those
actions to every unsigned request. This cluster shipped that way, so the gateway served any object to
anyone who could reach `s3.gitsaas.test`. The identity is now named `gitfrok`, and that host answers
**403** without a signature.

### Live repositories never touch either tier

`GITFROK_GIT_STORAGE_ROOT` stays on the block-backed PVC (ADR-0033), and `git-storaged` refuses a
FUSE repository root outright (invariant 7). Pointing it at a mount does not corrupt anything — the
process fails to start.

### Proving the tier works

```bash
kubectl --context gitfrok port-forward -n default svc/seaweedfs 18333:8333 &
cd backend && GITFROK_TEST_SEAWEEDFS_ENDPOINT=http://127.0.0.1:18333 \
  GITFROK_TEST_SEAWEEDFS_BUCKET=gitfrok \
  GITFROK_TEST_SEAWEEDFS_ACCESS_KEY=minioadmin GITFROK_TEST_SEAWEEDFS_SECRET_KEY=minioadmin \
  go test ./platform/objectstore/ -run TestLiveSeaweedFS -count=1
```

Five tests: round trip, absent object, presigned fetch, **unsigned request refused**, tampered
presigned URL refused. All pass against this cluster.

## 7. Verify

```bash
make dev-smoke
```

Its assertions map onto T-0003's acceptance criteria: every deployment has an available replica; the
images pods are *actually running* all come from `versions.env`; `secret/gitsaas-tls` exists and is a
TLS secret; `GET https://hello.gitsaas.test/` returns 200; that response's certificate validates
against the mkcert root CA; and the body is the hello fixture rather than some other backend
answering.

It never uses `curl -k`. Failures are classified — unresolvable host, untrusted certificate,
connection refused, wrong backend, non-200 — because they have different fixes.

Then the surfaces, by hand:

| URL | Expect |
|---|---|
| `https://app.gitsaas.test` | the web app; Ctrl+K opens the palette |
| `https://zitadel.gitsaas.test` | the Zitadel console |
| `https://hello.gitsaas.test` | `gitfrok dev cluster: hello over TLS` |
| `https://s3.gitsaas.test`, `https://filer.gitsaas.test` | SeaweedFS S3 and filer |

## 8. The MVP scenario, and what this cluster can prove of it

The Phase-1 exit bar is one end-to-end run: **OIDC login → clone → durable push → open MR → direct
push to a protected ref denied → approve and merge → CI job runs and its status gates merge → audit
trail → git-node failover promotes the in-sync replica.**

| Step | On this cluster |
|---|---|
| OIDC login | **yes**, once step 5 is done |
| clone / push over HTTPS and SSH | **yes** |
| durable push (primary + in-sync replica ack) | **no** — one node. Proved by T-0012's tests and T-0018's two-node integration suite |
| open MR, direct push to a protected ref denied | **yes** — the denial is a PDP decision, not a UI affordance |
| approve and merge | **yes** |
| CI job runs, status gates merge | **no** — no gVisor RuntimeClass under rootless podman, so dispatch is unconfigured |
| audit trail | **yes**, once step 4 is done |
| failover promotes the in-sync replica | **no** — one node |
| LFS push/fetch through the plane | **yes** — the object tier is wired and its live suite passes against this cluster |

Two of those three gaps are the same gap: **this host is one node without a hypervisor.** Closing
them is T-0003's cluster lane — a second physical node running SPEC-0018's production coordinator,
and an attached volume rather than a local partition.

### 8a. Verified end-to-end run (2026-08-11)

The full MVP flow was executed live against this cluster and passed: PAT issuance over the gRPC door,
push, protected-ref direct push **denied and audited**, `SetBranchProtection` forwarded to the storage
node, MR open (refs announced cross-process via `GitStorage.SubscribeRefUpdates`), review approve,
merge, `main` moved, audit chain intact.

```bash
# 1. PAT via the identity door (port-forward dataplane 9090)
grpcurl -plaintext -import-path ../governance/contracts \
  -proto proto/identity/v1/identity.proto \
  -d '{"tenant_id":"dev","actor_id":"user-admin","label":"phase1",
       "scope_labels":["repo.read","repo.write"],"roles":["owner"]}' \
  127.0.0.1:9090 gitsaas.identity.v1.CredentialAuthenticator.IssuePAT

# 2. push / protected-ref denial (smart HTTP over the ingress; TLS CA NOT in system store)
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

# 3. MR flow (refs are FULL names — "main" is rejected, "refs/heads/main" works)
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

Gotchas that cost an afternoon each:
- **`build_if_absent`**: `minikube image rm` while a pod uses the image fails silently — scale the
  deployment to 0 first, then `rm`, then `dev-up`. Otherwise the cluster keeps running the previous
  build and "new" behavior never appears.
- **In-memory stores reset with the plane**: a dataplane/git-storaged restart clears the ref
  projection, protection rules, and every issued PAT. Re-create the bare repo (or re-push), re-apply
  `SetBranchProtection`, and re-issue the PAT before re-running the flow.
- **MR open needs full ref names** (`refs/heads/...`); short names are denied before any store lookup.

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `StartHost failed`, nothing about inotify | PID 1 in the node got no inotify instances | step 1's first sysctl |
| `volume with name gitfrok already exists` | a previous create failed and orphaned the podman volume | `dev-up` now sweeps these; otherwise remove it by hand |
| `Job for docker.service failed` during provisioning | `MINIKUBE_RUNTIME` unset on minikube ≤ 1.38 | `MINIKUBE_RUNTIME=containerd` (the default here) |
| six deployments reported dead, cluster is fine | wrong profile | `MINIKUBE_PROFILE=minikube` |
| host resolves `*.gitsaas.test` but every request times out | resolver points at the unroutable node IP | point it at `127.0.0.1` |
| Redpanda crash-loops with *"Incompatible downgrade detected"* | the pin moved **down** a minor | delete `redpanda-pvc`; there is no in-place path |
| the data plane exits at boot | no loadable policy bundle | re-run `dev-up`, which republishes the ConfigMap from `governance/policies` |
| every authorization decision denies | the bundle loaded with zero `.rego` files | `dev-up` refuses this now; confirm the ConfigMap has the rules, not just `.manifest` |
| an RWO-backed pod deadlocks on rollout | `RollingUpdate` against a single-writer volume | `strategy: Recreate` (already set on the four stateful deployments) |
| rebuilt image has no effect | `build_if_absent` — the pod still runs the old build | scale replicas to 0, `minikube image rm docker.io/gitfrok/<plane>:0.1.0`, re-run `dev-up` |
| data plane crash-loops: `RegisterService called after Server.Serve` | the policy gRPC door raced registration | fixed in `ServePolicy()` (backend #54); rebuild the dataplane image |
| fresh repo pushes but MR open/`refs` lookups fail | plane restart cleared the ref projection | re-create or re-push the bare repo, re-apply `SetBranchProtection`, re-issue the PAT |
| MR open denied despite valid refs | short ref names (`main`) instead of full (`refs/heads/main`) | always pass full ref names in codereview RPCs |

## 10. Teardown

```bash
minikube delete -p gitfrok        # removes the node container and its podman volume
```

Delete the profile **before** removing anything by hand: once the registration is gone, minikube can
no longer clean its own volume and the next create fails on a name collision.

## References

- **ADR-0024** Minikube-only local dev · **ADR-0023** stack floors · **ADR-0034** image pinning
- **ADR-0033** live repos on block volumes · **ADR-0050** large objects over a SeaweedFS FUSE mount
- **ADR-0045** OIDC · **ADR-0049** BFF sessions · **ADR-0035** supply chain
- **SPEC-0018** durability quorum · **SPEC-0023** Git LFS transport
- **T-0003** Minikube dev environment · **T-0018** repository and review-history import
- [`deploy/dev/README.md`](dev/README.md) — per-manifest detail and the full defect history
- [`../HANDOFF.md`](../HANDOFF.md) — what an incoming session should read first
