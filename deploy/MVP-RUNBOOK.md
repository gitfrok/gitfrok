# MVP deploy runbook

**What this is.** The operational path from a clean host to a running Gitfrok MVP, and an honest
account of which parts of the Phase-1 exit scenario that path can actually demonstrate. It is written
to be handed to someone who was not present for the work.

**What it is not.** A production deployment guide. Every credential below is a dev-only default, the
S3 endpoint is open, and the cluster is a single Minikube node. Production posture is ADR-0035
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
| Host DNS for `*.gitsaas.test` | **manual, needs root** — the script prints, it does not apply |
| Database migrations | **manual** — nothing in the cluster applies them |
| Zitadel OIDC client for the BFF | **manual** — `dev-up` deploys Zitadel, it does not configure an app |
| LFS / artifact / image object tier (ADR-0050) | **not wired into any manifest** — see [step 6](#6-wire-the-object-tier-adr-0050) |
| CI sandbox dispatch (gVisor) | **unavailable** under rootless podman |
| Durability quorum and failover | **proved in tests, not demonstrable here** — one node |

The last four rows are the whole of what stands between this runbook and the Phase-1 exit scenario.
None of them is missing code.

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
apply all manifests with `ingress` last → wait for every rollout → print the host-DNS snippet.

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

Two sources of schema truth across two schemas is a known gap, recorded in `DOCUMENTATION_INDEX.md`
under *Known governance gaps*. Do not close it by editing the manifest — that would make the drift
harder to see, not smaller.

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

## 6. Wire the object tier (ADR-0050)

**No manifest sets an object tier, so the cluster serves no LFS at all.** The tier is
configured-or-absent by design — a node with none of the variables set serves no large objects, which
is a deployment choice rather than a failure — and in `deploy/dev/` it is absent.

ADR-0050 decides that LFS objects, CI artifacts and container-image blobs come from a **SeaweedFS
FUSE mount**. Both `git-storaged` and the data plane read the same variable and prefer it over S3:

```yaml
- name: GITFROK_SEAWEEDFS_MOUNT
  value: /mnt/seaweedfs
```

The mount must already exist and be writable when the process starts. `NewMount` refuses to create
it, deliberately: a mount point the process had to create is a mount point that was **not** mounted,
and objects written into the empty directory underneath it are invisible to every other node.

Two properties make this safe to build on, and both are enforced in code rather than assumed:

- **Writes stage and commit.** An object is written beside its destination, fsynced, renamed onto its
  content-addressed name, then read back at full length before the write is acknowledged.
- **Reads verify.** `rename()` is *not* atomic on this backend — that is the measured finding behind
  ADR-0033 — so every read hashes the whole object and compares it against the digest in its name
  before a byte reaches a client. A mismatch is reported as absence.

**Live bare repositories stay on block volumes.** ADR-0033 is unchanged and `git-storaged` refuses a
FUSE repository root outright (`ErrFUSERepositoryRoot`, invariant 7). Do not point
`GITFROK_GIT_STORAGE_ROOT` at the mount — it will not start, and that is the guard working.

### The S3 alternative

The S3 adapter is retained for a deployment that has no mount. It is **all-or-nothing**: set all five
variables or none, because a node with three of them has an operator who intended LFS and a
deployment that would refuse it.

```yaml
- {name: GITFROK_SEAWEEDFS_S3_ENDPOINT,   value: "http://seaweedfs:8333"}
- {name: GITFROK_SEAWEEDFS_S3_REGION,     value: "us-east-1"}
- {name: GITFROK_SEAWEEDFS_S3_BUCKET,     value: "gitfrok"}
- {name: GITFROK_SEAWEEDFS_S3_ACCESS_KEY, valueFrom: {secretKeyRef: {name: seaweedfs-s3, key: access-key}}}
- {name: GITFROK_SEAWEEDFS_S3_SECRET_KEY, valueFrom: {secretKeyRef: {name: seaweedfs-s3, key: secret-key}}}
```

Two SeaweedFS behaviours will cost you an afternoon if you meet them without warning:

1. **A PUT into a bucket that does not exist returns 200**, and the object is not there afterwards.
   The tier now reads every object back before acknowledging, which is what turns this into an error
   instead of silent data loss. Create the bucket first:
   `weed shell` → `s3.bucket.create -name gitfrok`.
2. **A bucket written to before it was registered stays poisoned** — reads return `NoSuchBucket`
   permanently. Recover with a freshly registered bucket name; there is no repair.

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
| LFS push/fetch through the plane | **only after step 6** |

Three of those four gaps are the same gap: **this host is one node without a hypervisor.** Closing
them is T-0003's cluster lane — a second physical node running SPEC-0018's production coordinator,
and an attached volume rather than a local partition.

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
