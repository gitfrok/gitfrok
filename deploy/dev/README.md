# Minikube dev manifests — T-0003

Per-manifest record behind [`../MVP-RUNBOOK.md`](../MVP-RUNBOOK.md), which is the ordered operator
path. Read the runbook first; this file answers *why a manifest is the way it is* and keeps the defect
record. Manifests implement ADR-0024; `governance/` owns every decision cited here (ADR-0001).

**T-0003 is Done, AC1–AC4 verified.** Two residuals are named rather than closed: **host DNS** needs
root, so `dev-up.sh` prints the per-OS snippet instead of applying it, and a **cluster bring-up on
macOS** needs a hypervisor no hosted runner has (the scripts themselves run on a real macOS runner).
Written but never exercised in a cluster: **KEDA and the CI `ScaledObject`** — the dev job queue is
in-process, so each replica reports its own depth and the trigger cannot demonstrate real autoscaling.

## Services

```
postgres:5432        PostgreSQL 18 — tenancy + RLS (T-0004)
valkey:6379          Valkey 9.1 — replaces Redis (ADR-0023)
redpanda:9092        Redpanda v26.2 — events; +9644 admin (readiness), 8081/8082 registry/proxy
git-storaged:9000    Git storage tier (ADR-0004/0048); the planes' Git front doors call it
seaweedfs:9333       SeaweedFS 4.40 — +8888 filer, +8333 S3, +18888 filer gRPC
zitadel:8080         OIDC/OAuth2 (T-0013), with zitadel-login for the Login V2 UI
dataplane:8080       data plane — healthz + policy bundle (T-0021)
controlplane:8080    control plane — healthz baseline (Phase 3 agent gateway)
bff:8080             BFF — SPEC-0021 browser surface + OIDC login/session (T-0015)
webfrontend:4321     Astro SSR web app (T-0015)
hello:8080           busybox httpd — the smoke-test fixture, not a real service
keda (ns: keda)      autoscales the data plane on CI queue depth (T-0017 AC2)
```

In-cluster clients use Service names (`postgres:5432`). The `*.gitsaas.test` hostnames are for the
host machine and for S3 clients needing a real hostname; they are routed by `ingress.yaml`, not by
Service DNS.

## Manifests

Every image tag is asserted against `versions.env` by `scripts/check-dev-images.sh`, and
`smoke-dev.sh` asserts the tags **actually running** — neither trusts this table.

| File | Service | Notes |
|---|---|---|
| `postgres.yaml` | PostgreSQL 18 | T-0004 RLS baseline + `gitfrok_app` role from its own ConfigMap |
| `valkey.yaml` | Valkey 9.1 | RDB + AOF; holds the BFF's browser sessions (ADR-0049); no `maxmemory`, so a large working set is an OOMKill — and now that sessions live here, an eviction is a logout |
| `redpanda.yaml` | Redpanda v26.2 | single broker, TLS off, config via `rpk` flags only |
| `seaweedfs.yaml` | SeaweedFS 4.40 | master + filer + S3 in one pod; S3 identity `gitfrok` |
| `seaweedfs-mount.yaml` | ADR-0051 mount DaemonSet | **not applied by default** — `MOUNT_DAEMONSET=1` |
| `zitadel.yaml`, `zitadel-login.yaml` | Zitadel + Login V2 | `start-from-init`, own database and role |
| `git-storaged.yaml` | Git storage tier | block-volume PVC; writable root filesystem (git needs it) |
| `dataplane.yaml` | data plane | healthz 200 with the policy bundle, **exits** without it (AC4) |
| `controlplane.yaml` | control plane | healthz-only baseline |
| `bff.yaml` | BFF | aggregation only (invariant 18); browser sessions in Valkey (ADR-0049/0052), with a `valkey-wait` init container |
| `webfrontend.yaml` | web app (SSR) | reaches the BFF only (invariant 22) |
| `hello.yaml` | smoke fixture | busybox `httpd` over a ConfigMap, non-root, read-only root |
| `ci-scaledobject.yaml` | KEDA `ScaledObject` | written, never exercised in a cluster |
| `ingress.yaml` | — | `hello`, `zitadel`, `s3`, `filer`, `app`, `git` over the mkcert wildcard |
| *(generated)* | policy bundle | ConfigMap `gitfrok-policy-bundle`, built by `dev-up` from `governance/policies` |

`trust/` carries the image-publish trust material (ADR-0044); see its own README.

## What is committed, and what is generated

| | image tags | policy bundle, TLS secret, PAT verifier key |
|---|---|---|
| owned by | the super-repo (a *pin*) | governance (the *content*), or the machine |
| therefore | hardcoded in the manifest, asserted against `versions.env` | produced at bring-up, never committed |

Templating manifests from `versions.env` was rejected: it makes them unappliable without the
bootstrap script, killing the manual `kubectl apply` path. **Assert, don't generate.** A committed
Rego ConfigMap would be a second author for something invariants 13 and 21 give governance alone, and
a committed local-CA key must never exist at all — `dev-up` issues the cert into a temp dir, loads it,
and deletes it on exit, re-issuing every run so an expired secret repairs itself.

### Two ways the policy bundle goes silently wrong

Both produce a bundle that *loads cleanly* and then denies every request — a failure the data plane's
fail-fast cannot catch, because nothing about the bundle is malformed:

1. **`kubectl create configmap --from-file=<dir>` is not recursive.** Pointed at `governance/policies`
   it collects `.manifest` and nothing else, since the rules live under `gitsaas/authz/`. Verified
   in-cluster: a manifest-only bundle evaluates to `{}`. `dev-up.sh` enumerates `.rego` files
   explicitly and refuses a bundle with zero of them.
2. **A flat key namespace collides where a nested tree does not.** ConfigMap keys cannot contain `/`,
   so two policies sharing a basename overwrite each other. `dev-up.sh` fails on a duplicate basename.

Flat keys are otherwise safe — OPA resolves by each file's `package`, not its path. Confirmed against
the nested tree, a flattened copy, and a ConfigMap **volume mount** in-cluster (that mount presents
keys through a `..data` symlink and the loader walks the directory), including on an *allow* case
(`reader` + `repo.read` → `allow: true`); a deny-only test would have passed with zero rules loaded.
`*_test.rego` is excluded, matching the loader's filter in
`backend/modules/policy/internal/adapters/opa/pdp.go`.

The contract a plane manifest must honour:

```yaml
    env:
    - name: GITFROK_POLICY_BUNDLE_DIR
      value: /etc/gitfrok/policy
    volumeMounts:
    - name: policy
      mountPath: /etc/gitfrok/policy
      readOnly: true
  volumes:
  - name: policy
    configMap:
      name: gitfrok-policy-bundle
```

## Why Redpanda is pinned on docker.io

`docker.redpanda.com` — the registry ADR-0034 preferred — is **backwards for this image**: it answers
an unauthenticated manifest query with `toomanyrequests`, and resolves to a Docker-Hub-fronting proxy
(`vectorized.docker.scarf.sh`) delegating auth to `auth.docker.io`. It inherits the exact rate limit
ADR-0034 wanted to avoid and fails that ADR's own rule 4 (resolvability checked, not assumed) —
`check-dev-images.sh` reported `?? inconclusive` on every run. The same tag on `docker.io` resolves
clean. A pin that verifies beats a preferred registry that cannot.

**Redpanda refuses downgrades.** Moving the pin down a minor crash-loops on *"Incompatible downgrade
detected"* — it records a feature-table version in its data directory. Delete `redpanda-pvc`; there is
no in-place path down. Moving up rolls out on the existing volume untouched.

## Resources, probes, storage

Requests across the applied manifests total **1.66 CPU / 2000 MiB** (`seaweedfs-mount.yaml` is opt-in
and excluded), so `dev-up` defaults the VM to 4 CPU / 6144 MiB — Minikube's 2/2 default cannot fit this
plus the ingress controller. Redpanda gets
`--memory=768M` against a 1Gi limit: Seastar pre-reserves what it is told, and a value equal to the
limit gets the pod OOMKilled.

Every service has liveness and readiness probes, hitting a real readiness endpoint where one exists
(Redpanda `/v1/status/ready`, Zitadel `/debug/ready`) rather than a TCP poke, which only proves
something bound the port.

| PVC | Size | Note |
|---|---|---|
| postgres | 10Gi | mounted one level **above** `/var/lib/postgresql/data` — pg18 exits on that mount |
| valkey | 5Gi | RDB + AOF at `/data` |
| redpanda | 10Gi | `/var/lib/redpanda/data` |
| seaweedfs | 20Gi | `/data`, including buckets |
| zitadel | 5Gi | **vestigial** — Zitadel keeps all state in PostgreSQL |

All four stateful deployments use `strategy: Recreate`: `RollingUpdate` against an RWO volume
deadlocks, because the new pod starts before the old releases it.

## Configuration notes

**PostgreSQL** — database `gitfrok`; superuser `postgres`/`postgres` (dev only). The `postgres-init`
ConfigMap lays the T-0004 baseline: schema `tenant`, table `tenant.tenants`, policy `tenant_isolation`
on `current_setting('app.tenant_id', true)`, so an unset tenant yields no rows rather than every row.
It also creates **`gitfrok_app`** (`NOSUPERUSER NOBYPASSRLS`, DML only) — **the app must connect as
this role**; RLS never binds a superuser and binds the owner only under `FORCE ROW LEVEL SECURITY`,
which is set. Callers scope each transaction with `SET LOCAL app.tenant_id`.

**SeaweedFS** — there is no `s3.gitsaas.test` Service: Service names must be RFC 1035 labels, so a
dotted name is rejected. Use `seaweedfs:8333` in-cluster or the ingress host from outside. The
`minioadmin` credentials sit on the identity named **`gitfrok`**, never `anonymous`.

**Zitadel** — TLS terminates at the ingress (`--tlsMode=external`, `ExternalSecure: true`), so it
advertises `https://zitadel.gitsaas.test` while serving plaintext in-cluster. `enableServiceLinks:
false` is required: Kubernetes' `ZITADEL_PORT` service-link variable collides with Zitadel's own
`ZITADEL_` config prefix. Dev-only login `admin@gitsaas.test` / `ChangeMe123!`. A gRPC-native client
against the management API needs `nginx.ingress.kubernetes.io/backend-protocol: GRPC`, which cannot
share a host with the console — split it onto its own Ingress when a task needs it.

**Ingress** — six hosts on the `gitsaas-tls` wildcard. Adding a host needs a rule but no new cert; an
Ingress wildcard *host* matches one DNS label and cannot fan out per service, which is why the rules
are listed individually. The `ingress-dns` addon answers `*.test` for the cluster, but the host machine
still has to be told to ask it (runbook step 3).

## The object tier: wired to S3, because the FUSE mount cannot propagate here

`git-storaged` and the data plane carry the five `GITFROK_SEAWEEDFS_S3_*` variables, so this cluster
serves LFS. **That is the S3 adapter, not ADR-0050's FUSE mount**, and the reason is measured.

ADR-0051 produces the mount with a privileged DaemonSet — the only shape Kubernetes allows, since
kubelet rejects `mountPropagation: Bidirectional` on an unprivileged container. It was built
(`seaweedfs-mount.yaml`) and run here, and it does not work on this driver:

| Observation | Value |
|---|---|
| the DaemonSet's own mount | `seaweedfs:8888:/gitfrok /mnt/seaweedfs fuse.seaweedfs rw,…` |
| its propagation inside the pod | `shared:1550` |
| the node's `/` propagation | `shared` |
| **seaweed mounts in the node's table** | **0** |
| what consumers bound instead | the plain directory underneath |
| what a write produced | a file **on node-local disk**, readable on that node, invisible to the filer and to the mount pod |

That last row is the whole problem: **every check passed while the data diverged.** `mountpoint -q`
passed, a write-then-read gate passed, `objectstore.NewMount`'s writability probe passed. Only
comparing three views — consumer, mount pod, filer — showed the objects were never in SeaweedFS. It is
the failure ADR-0050 and ADR-0051 exist to prevent, reproduced inside the checks meant to catch it.

So the DaemonSet is not applied by default. `MOUNT_DAEMONSET=1 make dev-up` deploys it, waits for it
to serve bytes, then patches `git-storaged` and the data plane onto it — a `HostToContainer` hostPath
of `type: Directory` plus `GITFROK_SEAWEEDFS_MOUNT=/mnt/seaweedfs`, which the process prefers over the
S3 variables. The patch is deliberately not in the committed YAML: a `type: Directory` hostPath there
would refuse to start both planes on every node without the DaemonSet, which is the default here.

**Each consumer gets an init container that refuses to start unless `/mnt/seaweedfs` is a
`fuse.seaweedfs` mount in its own namespace** (ADR-0051 decision 3) — the load-bearing part of that
patch, because nothing else catches the failure above. `smoke-dev.sh` reports the mount pod's
readiness and the consumers' actual propagation separately, and says which tier is in use.

Two more defects, both found only by running it:

1. **`weed mount` needs the filer's gRPC port, 18888 (HTTP + 10000), which SeaweedFS never
   announces.** The mount client retried `i/o timeout` indefinitely against a filer healthy on 8888.
   Now in `seaweedfs.yaml`'s container ports and Service.
2. **The S3 endpoint served every object to unsigned requests** — the credentials were attached to
   `anonymous`, SeaweedFS's *unauthenticated* identity, so the keys were decoration. The identity is
   now `gitfrok`, and `s3.gitsaas.test` answers **403** without a signature.

**The bucket is created by `dev-up.sh` before anything can write.** SeaweedFS answers **200 to a PUT
into a bucket that does not exist** and keeps nothing; a bucket written to before it was registered
stays poisoned — `NoSuchBucket` on every read, with no repair but a new name.

Backend's live suite is both the proof and what caught the two defects (runbook step 7 has the
command): round trip, absent object, presigned fetch, **unsigned request refused**, tampered
presigned URL refused — five passes against this cluster.

Live bare repositories are unaffected: ADR-0033 stands, `GITFROK_GIT_STORAGE_ROOT` points at the
block-backed PVC, and `git-storaged` refuses a FUSE repository root outright (invariant 7).

## Defects found bringing this cluster up

All ten were invisible to review and to `check-dev-images.sh`, because nothing had executed. #1–7 came
from the first cluster run (2026-08-06); #8–10 needed a *create* path that had never once run to
completion, which only surfaced on 2026-08-08 once #9 stopped blocking it.

| # | Defect | How it failed → fix |
|---|---|---|
| 1 | postgres PVC at `/var/lib/postgresql/data` | pg18 **exits** on that mount (docker-library/postgres#1259) → mount one level up |
| 2 | `redpandadata/redpanda:v26.1` | never published — Redpanda tags patch releases only → pin `v26.2.1` |
| 3 | seaweedfs `args: [all, …]` | `weed: unknown subcommand "all"` → `server` + `-filer` |
| 4 | zitadel `--tls-mode=external` | flag is camelCase → `--tlsMode` |
| 5 | seaweedfs readiness `path: /status` | 404s on the master, never Ready → `/cluster/status` |
| 6 | zitadel `Port` config | `ZITADEL_PORT` service-link collision → `enableServiceLinks: false` |
| 7 | RWO PVCs on default `RollingUpdate` | rollout deadlocks → `strategy: Recreate` |
| 8 | `dev-up.sh` did not converge a **failed** create | minikube drops the container but leaves the podman volume, so attempt two dies on `volume already exists` → delete a non-running profile before creating |
| 9 | `fs.inotify.max_user_instances` exhausted | PID 1 in the node gets none and exits → preflight check prints the `sysctl` fix |
| 10 | `dev-up.sh` never passed `--container-runtime` | minikube 1.35 defaults to docker, which fails to provision → `containerd` |

One more in passing: `mkcert -install` under `set -e` aborted the whole bring-up on a host without
passwordless sudo, over a step no acceptance criterion depends on. It now warns and continues when the
CA already exists.

## macOS: what is verified

AC4 needs an old **shell** (bash 3.2.57) and a BSD **userland** proven, not grepped for. A
`macos-latest` lane in all five repos runs the fitness gates under real bash 3.2.57 on Darwin's own
userland; `check-shell-portability.sh` (SPEC-0014) is the standing gate.

| Claim | Status |
|---|---|
| no OrbStack, no Docker Compose anywhere | verified — every mention in the tree is a prohibition |
| no bash-4 syntax or GNU-only behaviour in the gates | verified on the macOS lane |
| no GNU-only tool flags | **two real defects found and fixed** — `check-docs.sh`'s `find -printf`, and `bench-storage.sh`'s `stat -f -c` whose failure was swallowed by `2>/dev/null`, leaving its RAM-disk guard silently inert |
| `seq`, `sort -z` | fine — Darwin ships both; two earlier worries were unfounded |
| `date +%N` (`bench-git-workload.sh`) | known, self-guarded — exits with a clear message without GNU `date` |
| the dev cluster comes up on a Mac | **not verified** — needs a hypervisor no hosted runner has |

## Also outstanding

No CI wires this Minikube flow itself (ADR-0024's stated intent) — only `check-dev-images.sh` gates
from CI. First-party images are pinned by tag, not digest (ADR-0035 decision 4). `namespace: default`
is hardcoded in every object, so two stacks cannot coexist. Valkey has no `maxmemory`. Per-OS
Minikube driver docs are an ADR-0024 follow-up.

## References

ADR-0023 stack floors · ADR-0024 Minikube-only dev · ADR-0033 block volumes · ADR-0034 image pinning ·
ADR-0048 git-storaged base · ADR-0050 / ADR-0051 large objects · SPEC-0014 shell portability ·
T-0003 (this task) · T-0004 tenancy + RLS · T-0013 identity · T-0015 web surface · T-0021 images.
