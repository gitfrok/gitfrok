# Minikube Dev Environment Manifests — T-0003

Kubernetes manifests for the local Minikube dev environment per ADR-0024.

> **New here? Read [`../MVP-RUNBOOK.md`](../MVP-RUNBOOK.md) first.** It is the ordered operator path
> — preflight, bring-up, the three manual root steps, and what this cluster can and cannot prove.
> This file is the per-manifest record behind it.
>
> **Status: T-0003 is `Done`, AC1–AC4 verified.** The full stack comes up Available from these
> manifests on the tags in `versions.env`, ingress serves the mkcert wildcard, and `make dev-smoke`
> is green. Getting there cost **ten defects** — seven in the manifests (2026-08-06) and three in
> `dev-up.sh`'s cluster-*create* path (2026-08-08) — every one of them invisible to the static
> validation this directory used to rest on.
>
> Two residuals are named rather than closed: **host DNS** for `*.gitsaas.test` needs root, so the
> script prints the per-OS snippet instead of applying it, and a **cluster bring-up on a Mac** needs
> a hypervisor no hosted runner has (the scripts themselves are exercised on a real macOS runner).
>
> **The object tier is now wired**, and it is the S3 adapter rather than ADR-0050's FUSE mount:
> the mount cannot propagate to the node on this driver, which was measured rather than assumed.
> Two further defects were found doing it — the filer's gRPC port was never exposed, and the S3
> endpoint served every object to unsigned requests. See
> [the object tier](#the-object-tier-wired-to-s3-because-the-fuse-mount-cannot-propagate-here).
>
> **Added since that run and therefore unverified in a cluster:** the `git-storaged` workload, the
> Git front doors now that it exists, KEDA, the CI `ScaledObject`, and the T-0015 web surface
> (`bff` + `webfrontend`, serving `app.gitsaas.test`). Given that the first real run of this
> directory cost nine defects, treat them as written-not-proven — see
> [What is not done yet](#what-is-not-done-yet).

## Service Architecture

```
Local Services (Minikube + ingress-dns)
├── postgres:5432          — PostgreSQL 18 (tenancy + RLS, T-0004)
├── valkey:6379            — Valkey 9.1 (replaces Redis, ADR-0023)
├── redpanda:9092          — Redpanda v26.2 (event broker; ADR-0023 floor is 26.1)
├── git-storaged:9000      — Git storage tier (ADR-0004/0048; the planes' Git front doors call it)
├── keda (ns: keda)        — autoscales the data plane on CI queue depth (T-0017 AC2)
│   ├── :8081              — Schema Registry
│   ├── :8082              — PandaProxy (HTTP proxy)
│   ├── :9644              — Admin API (readiness)
│   └── :33145             — internal RPC
├── seaweedfs:9333         — SeaweedFS 4.40 (S3-compatible blob storage)
│   ├── :8888              — Filer API
│   └── :8333              — S3 API
├── zitadel:8080           — Zitadel (OIDC/OAuth2, T-0013)
├── dataplane:8080         — data plane (healthz + policy bundle; T-0021)
├── controlplane:8080      — control plane (healthz baseline; T-0021)
├── bff:8080               — BFF (SPEC-0021 browser surface + OIDC login + session; T-0015)
├── webfrontend:4321       — Astro SSR web app (tree/file/diff + palette; T-0015), served at app.gitsaas.test
└── hello:8080             — busybox httpd; the smoke-test fixture, not a real service
```

In-cluster clients address these by Service name (`postgres:5432`, `seaweedfs:8333`). The
`*.gitsaas.test` hostnames are for the host machine and for S3 clients that need a real hostname —
they are routed by `ingress.yaml`, not by Service DNS.

## Manifest Files

Images below are the tags actually running, which are the tags in `versions.env` — `smoke-dev.sh`
asserts that correspondence rather than trusting this table.

| File | Service | Image | State |
|------|---------|-------|-------|
| `postgres.yaml` | PostgreSQL 18 | `postgres:18.4` | applied, Available |
| `valkey.yaml` | Valkey 9.1 | `valkey/valkey:9.1.1` | applied, Available |
| `redpanda.yaml` | Redpanda v26.2 | `docker.io/redpandadata/redpanda:v26.2.1` | applied, Available |
| `seaweedfs.yaml` | SeaweedFS 4.40 | `chrislusf/seaweedfs:4.40` | applied, Available |
| `zitadel.yaml` | Zitadel | `ghcr.io/zitadel/zitadel:v4.16.2` | applied, Available |
| `hello.yaml` | smoke-test fixture | `busybox:1.35.0` | applied, Available; serves 200 over TLS |
| `git-storaged.yaml` | Git storage tier | `docker.io/gitfrok/git-storaged:0.1.0` | applied, Available; block-volume PVC, front doors point at it |
| `dataplane.yaml` | data plane | `docker.io/gitfrok/dataplane-app:0.1.0` | applied, Available; healthz 200 with the policy bundle, exits non-zero without it (AC4) |
| `controlplane.yaml` | control plane | `docker.io/gitfrok/controlplane-app:0.1.0` | applied, Available; healthz-only baseline (Phase 3 agent gateway) |
| `bff.yaml` | BFF | `docker.io/gitfrok/bff:0.1.0` | T-0015: SPEC-0021 browser surface + OIDC login + session (ADR-0049) |
| `webfrontend.yaml` | web app (SSR) | `docker.io/gitfrok/webfrontend:0.1.0` | T-0015: tree/file/diff views + palette, BFF-only (invariant 22) |
| `ingress.yaml` | — | — | applied; serves the mkcert wildcard `dev-up` creates, incl. `app.gitsaas.test` |
| *(no file)* | policy bundle | — | ConfigMap `gitfrok-policy-bundle`, generated by `dev-up` from `governance/policies` — see [Policy bundle](#policy-bundle) |

## Version Pinning (ADR-0023)

`versions.env` is the recorded source of truth for image tags, and the manifests still hardcode
their own copy so `kubectl apply -f` works standalone. The two copies are kept honest by
`scripts/check-dev-images.sh`, which fails on any divergence in either direction and on any image in
`deploy/dev/` that `versions.env` never records. `make verify` runs it, so **CI gates it**, and
`dev-up` runs it before applying anything — bringing a cluster up from tags that no longer match the
recorded ones is worse than not bringing it up.

Templating the manifests from `versions.env` was the alternative; it was rejected because it makes
them unappliable without the bootstrap script, which kills the manual `kubectl apply` path this
directory documents. Assert, don't generate.

`ZITADEL_IMAGE=ghcr.io/zitadel/zitadel:latest` remains **not a pin** — it is whatever `latest`
resolved to when the node last pulled, which defeats the reproducibility ADR-0023 asks for. The
check warns on it rather than failing, since it is pre-existing; pinning it to a digest or release
tag is outstanding.

## Policy bundle

The data plane loads an OPA bundle from `GITFROK_POLICY_BUNDLE_DIR` and **exits** without a loadable
one (`backend/cmd/dataplane-app`, ADR-0006, invariant 2) — deliberately, since a plane that started
without rules would deny every request and reach an operator as an unexplained total outage.

`dev-up.sh` builds that bundle into a ConfigMap named `gitfrok-policy-bundle` from
`governance/policies`, and it is **generated, not committed** — the opposite call from image tags in
the section above, for a reason worth being explicit about:

| | image tags | policy bundle |
|---|---|---|
| owned by | the super-repo (a *pin*) | governance (the *content*) |
| therefore | hardcode in the manifest, assert against `versions.env` | read from the submodule at bring-up |

A ConfigMap full of Rego committed here would be a second author for something invariants 13 and 21
say governance alone owns, and it would drift silently. Same reasoning as the mkcert key, which
`dev-up.sh` also generates rather than commits.

### The contract a dataplane manifest must honour

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

**Nothing consumes it yet, and that is not an oversight to fix here.** `deploy/dev/` has no
dataplane manifest, and `backend/` has no Dockerfile to build an image from — so there is no pod to
mount it into. The ConfigMap exists so that the bundle is already correct and already verified when
that image lands; wiring it is the consumer's one-time cost, not a new investigation.

### Two ways this goes silently wrong

Both were found by testing rather than by reading, and both produce a bundle that *loads cleanly*
and then denies every request in the system — a failure the backend's fail-fast **cannot** catch,
because nothing about the bundle is malformed:

1. **`kubectl create configmap --from-file=<dir>` is not recursive.** Pointed at
   `governance/policies` it collects `.manifest` and nothing else, because the rules live under
   `gitsaas/authz/`. The revision is present, so the backend accepts the bundle at boot; every
   query then returns an undefined decision. Verified in-cluster: a manifest-only bundle evaluates
   to `{}`. `dev-up.sh` enumerates `.rego` files explicitly and refuses a bundle with zero of them.
2. **A flat key namespace collides where a nested tree does not.** ConfigMap keys cannot contain
   `/`, so two policies sharing a basename would overwrite each other, last writer winning.
   `dev-up.sh` fails on a duplicate basename rather than shipping the survivor.

Flat keys are otherwise safe: OPA resolves policies by each file's `package` declaration, not by its
path. Confirmed by evaluating the real `gitsaas.authz` policy against both the nested tree and a
flattened copy, and again from a ConfigMap **volume mount** inside the cluster — that last one
matters, because such a mount presents its keys through a `..data` symlink, and the bundle loader
walks the directory. All three agree, including on an *allow* case (`reader` + `repo.read` →
`allow: true`); a deny-only test would have passed with zero rules loaded and proved nothing.

`*_test.rego` is excluded, matching the loader's own filter in
`backend/modules/policy/internal/adapters/opa/pdp.go`: those are governance's tests *of* the policy,
they reference rules that exist only to be tested, and including them can fail compilation.

## Why Redpanda is pinned on docker.io

`REDPANDA_IMAGE` is `docker.io/redpandadata/redpanda:v26.2.1`, not the vendor's own
`docker.redpanda.com` that ADR-0034 preferred — recorded here because it cuts against that ADR's
example rather than following it.

`docker.redpanda.com` turned out to be **backwards for this image**: it answers an unauthenticated
manifest query with `toomanyrequests: You have reached your unauthenticated pull rate limit`, and
`dig`/`curl` show why — it resolves to a Docker-Hub-fronting proxy (`vectorized.docker.scarf.sh`) and
delegates auth to `auth.docker.io`. It is a Docker Hub pull with an extra hop, not an independent
distribution channel, so it inherits exactly the rate limit ADR-0034 wanted to avoid — and fails
ADR-0034's own rule 4 (resolvability checked, not assumed): `check-dev-images.sh` reported
`?? inconclusive` against it on every run. The same tag on `docker.io` resolves clean. A pin that
verifies beats a preferred registry that cannot, which is the ADR's spirit even where it contradicts
its example. The mirror's retention risk is unchanged; the resolvability probe is what turns a
deleted or retagged upstream into a red build instead of a deploy-time 404.

### Redpanda refuses downgrades — clearing the PVC is the only way down

Moving the pin **down** a minor (`v26.2.1 → v26.1.15`) crash-loops on
`Incompatible downgrade detected! My version 18, feature table 19 indicates that all nodes in cluster
were previously >= that version` — Redpanda records a feature-table version in its data directory and
refuses to start against data a newer release wrote. There is no in-place path down; delete
`redpanda-pvc` first. Moving **up** is fine and rolls out on the existing volume untouched.

## Resource Allocation (Minikube Local Dev)

Total requested: **1.36 CPU / 1.39 GB RAM** (limits sum to 2.8 CPU / 2.78 GB). `dev-up` therefore
defaults the VM to 4 CPU / 6144 MiB — Minikube's 2 CPU / 2 GB default cannot fit this plus the
ingress controller. Override with `MINIKUBE_CPUS` / `MINIKUBE_MEMORY`.

| Service | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---------|-------------|-----------|-----------------|--------------|
| PostgreSQL | 250m | 500m | 256Mi | 512Mi |
| Valkey | 100m | 250m | 128Mi | 256Mi |
| Redpanda | 500m | 1000m | 512Mi | 1Gi |
| SeaweedFS | 250m | 500m | 256Mi | 512Mi |
| Zitadel | 250m | 500m | 256Mi | 512Mi |
| hello (fixture) | 10m | 50m | 16Mi | 32Mi |

Redpanda is started with `--memory=768M` against its 1Gi limit: Seastar pre-reserves what it is
told, so a value equal to the limit leaves nothing for the process itself and gets the pod
OOMKilled.

## Health Checks

Each service has a liveness and a readiness probe. Example (PostgreSQL):

```yaml
livenessProbe:
  exec:
    command: ["/bin/sh", "-c", "pg_isready -U postgres -d gitfrok"]
  initialDelaySeconds: 10
  periodSeconds: 10
```

Readiness probes hit a real readiness endpoint where one exists — Redpanda's admin
`/v1/status/ready`, Zitadel's `/debug/ready` — rather than a TCP poke, which only proves something
bound the port.

## Persistent Storage

| Service | PVC | Note |
|---|---|---|
| PostgreSQL | 10Gi | **unverified**: `postgres:18` may use a version-scoped `PGDATA`, in which case the mount at `/var/lib/postgresql/data` persists nothing. Check `docker inspect postgres:18 \| grep PGDATA` before relying on it. |
| Valkey | 5Gi | RDB + AOF at `/data` |
| Redpanda | 10Gi | `/var/lib/redpanda/data` |
| SeaweedFS | 20Gi | `/data`, incl. buckets |
| Zitadel | 5Gi | **unused** — Zitadel keeps all state in PostgreSQL; the PVC is vestigial |

## DNS & Ingress

1. **In-cluster DNS:** `<service>.<namespace>.svc.cluster.local` — e.g. `postgres.default.svc.cluster.local`.
   This is what backend services should use; the hostnames below are for your machine.
2. **Ingress:** `ingress.yaml` routes four hosts over HTTPS with the `gitsaas-tls` wildcard secret:
   `hello.gitsaas.test` → `hello:8080`, `zitadel.gitsaas.test` → `zitadel:8080`,
   `s3.gitsaas.test` → `seaweedfs:8333`, `filer.gitsaas.test` → `seaweedfs:8888`.
3. **Host resolution:** the `ingress-dns` addon answers `*.test` for the cluster, but your machine
   still has to be told to ask it — see [Host DNS](#host-dns) below.

The TLS secret is machine-local and is **not** in this directory — a cert from a local CA must never
be committed. `dev-up` issues it into a temp dir, loads it into the cluster, and deletes it on exit,
so no private key is ever written inside the repo. It re-issues on every run, so an expired or
host-mismatched secret repairs itself.

Adding a host needs a new Ingress rule but no new cert — the wildcard covers it. An Ingress wildcard
*host* matches only one DNS label and cannot fan out per service, which is why the rules are listed
individually.

## Bringing it up

```bash
make dev-up      # scripts/dev-up.sh — idempotent; re-run it to repair a half-up cluster
make dev-smoke   # scripts/smoke-dev.sh — asserts AC2 + AC3
```

`dev-up` runs: preflight (`minikube`, `kubectl`, `mkcert`) → image-pin assertion → `minikube start`
with the `ingress` + `ingress-dns` addons → wait for the ingress controller → mkcert wildcard cert
into `secret/gitsaas-tls` → apply all manifests (ingress last) → wait for every rollout → print the
host-DNS snippet for your OS. It defaults to the `gitfrok` Minikube profile and pins every `kubectl`
call to that context, so a stray `kubectl config use-context` elsewhere cannot redirect the applies.

The manual path still works if you want to bypass the script — the manifests are plain, appliable
YAML, applied in the order `postgres valkey redpanda seaweedfs zitadel hello ingress` with the TLS
secret created first. Zitadel's init container waits for PostgreSQL, so those two can go in any order.

### Host DNS

`dev-up` deliberately does **not** touch your resolver: wiring `*.test` to the cluster needs root and
changes system-wide DNS, which is not a side effect a bootstrap script should have. It prints the
exact snippet instead — `/etc/resolver/test` on macOS, a NetworkManager/dnsmasq or systemd-resolved
drop-in on Linux, or an `/etc/hosts` line if you would rather not touch DNS at all.

This is the one manual step, and `dev-smoke` reports it as its own distinct failure: if the ingress
and TLS work but the hostname does not resolve, it says so and tells you the IP to point at, rather
than reporting a generic red.

## Testing

`make dev-smoke` (`scripts/smoke-dev.sh`) is the T-0003 integration test. Its assertions map onto the
acceptance criteria:

| Assertion | AC |
|---|---|
| every deployment has an available replica | AC2 |
| the images pods are **actually running** all come from `versions.env` | AC2 |
| `secret/gitsaas-tls` exists and is `kubernetes.io/tls` | AC3 |
| `GET https://hello.gitsaas.test/` returns 200 | AC3 |
| that response's certificate validates against the mkcert root CA | AC3 |
| the body is the hello fixture, not some other backend answering | AC3 |

It never uses `curl -k`. Skipping verification would let the test pass with TLS completely broken,
which is the one thing it exists to prove. Failures are classified rather than lumped together —
unresolvable host, untrusted certificate, connection refused, wrong backend and non-200 each report
differently, because they have different fixes. Transient shapes (connection refused, 404/502/503
from a cold ingress) retry for ~30s; TLS and DNS failures report immediately, since retrying cannot
change them.

`hello.yaml` exists to keep that test honest. Asserting against Zitadel or SeaweedFS instead would
mean a red test could not distinguish "TLS is broken" from "that service failed to boot", and Zitadel
is the slowest, least certain thing here. The fixture is busybox `httpd` serving a ConfigMap, runs as
non-root with a read-only root filesystem and no capabilities, and reuses an image already pinned in
`versions.env`.

**What has and has not been verified:** `check-dev-images.sh` was run for real, including against
three deliberately introduced drift cases (manifest ahead, `versions.env` ahead, unrecorded image) —
all caught. `smoke-dev.sh` was driven through every branch with stubbed `kubectl`/`curl`/`mkcert`/
`minikube`: pass, DNS-not-wired, untrusted cert, wrong body, missing replica, unrecorded running
image, and the bounded retry. All seven scripts are `shellcheck`-clean with no suppressions beyond
the two unavoidable `SC1091` data-file directives. Neither script has been run against a real
cluster.

## Configuration Highlights

**PostgreSQL (`postgres.yaml`)** — database `gitfrok`; superuser `postgres`/`postgres` (dev only).
The `postgres-init` ConfigMap lays the T-0004 RLS baseline: schema `tenant`, table
`tenant.tenants`, and policy `tenant_isolation` keyed on `current_setting('app.tenant_id', true)`,
so an unset tenant yields no rows rather than every row.

It also creates **`gitfrok_app`** (`NOSUPERUSER NOBYPASSRLS`, DML-only) — **the app must connect as
this role.** RLS never binds a superuser and does not bind the table owner unless forced, so a DSN
pointing at `postgres` makes the policy inert while still reporting as enabled. `FORCE ROW LEVEL
SECURITY` is set to close the owner case. Callers scope each transaction with
`SET LOCAL app.tenant_id = '<tenant-id>'`.

**Valkey (`valkey.yaml`)** — drop-in Redis replacement (ADR-0023); existing go-redis clients work
unchanged. RDB snapshots + AOF. No `maxmemory` is set against the 256Mi limit, so a large working
set is an OOMKill rather than an eviction.

**Redpanda (`redpanda.yaml`)** — single broker, no replication, TLS off. Configured entirely through
`rpk redpanda start` flags; there is deliberately **no ConfigMap**, because mounting one over
`/etc/redpanda` replaces the config the image generates and makes it read-only to the `rpk` startup
path. Advertised addresses use the Service name so clients survive rescheduling.

**SeaweedFS (`seaweedfs.yaml`)** — master + filer + S3 in one pod (`weed server -filer -s3`). There
is no `s3.gitsaas.test` Service: Service names must be RFC 1035 labels, so a dotted name is rejected
outright, and it would not have produced that hostname anyway. Use `seaweedfs:8333` in-cluster or the
ingress host from outside. The `s3_config.json` credentials `minioadmin`/`minioadmin` are attached to
the identity named `gitfrok`, **not** `anonymous` (SeaweedFS's unauthenticated identity) — see
[the object tier](#the-object-tier-wired-to-s3-because-the-fuse-mount-cannot-propagate-here) for why
that rename mattered.

**Zitadel (`zitadel.yaml`)** — OIDC/OAuth2 provider for T-0013. Runs `start-from-init`, which is
idempotent: first boot creates its schema and the `FirstInstance` org, later restarts skip setup.
Owns its own `zitadel` database and role, created via the `Admin` credentials, rather than sharing
`gitfrok` with the app. TLS terminates at the ingress (`--tls-mode=external`, `TLS.Enabled: false`,
`ExternalSecure: true`), so it advertises `https://zitadel.gitsaas.test` while serving plaintext
inside the cluster. Default login `admin@gitsaas.test` / `ChangeMe123!` and the 32-byte
`ZITADEL_MASTERKEY` are dev-only values that belong in a secret manager anywhere else.

A gRPC-native client against the management API would need
`nginx.ingress.kubernetes.io/backend-protocol: GRPC`, which cannot share a host with the console —
split it onto its own Ingress when T-0013 needs it.

**hello (`hello.yaml`)** — busybox `httpd -f -p 8080 -h /www` serving a one-line ConfigMap. Exists
only so `dev-smoke` can test the ingress + TLS path without depending on a real service booting. Runs
as UID 65534 with a read-only root filesystem and all capabilities dropped.

## What is not done yet

Against T-0003's acceptance criteria — **first real cluster run: 2026-08-06**, rootless podman
driver (`minikube start --driver=podman --container-runtime=containerd`), profile `minikube`:

| AC | State |
|---|---|
| AC1 — `make dev-up` starts Minikube with `ingress` + `ingress-dns` | **VERIFIED** — on 2026-08-08 the *cluster-create* path ran to completion for the first time, against a deleted-and-recreated `gitfrok` profile, and both addons came up. Getting there took the `fs.inotify.max_user_instances` raise the earlier attempt identified **plus a third defect that only a completed create could expose**: this script never passed `--container-runtime`, so minikube 1.35's *docker* default tried to start `dockerd` inside the node and failed (`Job for docker.service failed` → `StartHost failed`). The README had said `containerd` since the first bring-up; the script disagreed, and nothing caught it because the create path had never finished. Now pinned to `containerd`. |
| AC2 — all services come up from these manifests using `versions.env` tags | **VERIFIED** — all six deployments Available, and `smoke-dev.sh` confirmed all six running images come from `versions.env`. Getting here took **seven manifest fixes** (below); as written, three of the five services could never have started. |
| AC3 — services reachable at `*.gitsaas.test` over HTTPS via a mkcert wildcard secret | **verified over the real ingress path, under rootless podman, with no `port-forward`** — `GET https://hello.gitsaas.test/` returns `http_code=200`, `ssl_verify_result=0` (validated against the mkcert CA, never `curl -k`) and the hello fixture, hitting `127.0.0.1:443`. **The previous conclusion here was wrong and is retracted:** it said the rootless node IP being unroutable meant AC3 "needs a rootful driver or KVM". It needed the node's 80/443 *published to the host* — `minikube start --ports=80:80,443:443`, which the podman driver supports and this script now passes by default (`MINIKUBE_PORTS`). Binding those ports rootless also needs `net.ipv4.ip_unprivileged_port_start=0`; the create path checks for it and prints the fix. Still root-requiring, and still not automated: the **host DNS** half. Until `*.gitsaas.test` resolves to `127.0.0.1`, the 200 above is reached with `curl --resolve`. |
| AC4 — no OrbStack, no Docker Compose; macOS and Linux | **verified on both, 2026-08-09** — no compose files exist and every OrbStack/Compose mention in the tree is a prohibition. The macOS half is no longer inference: a `macos-latest` lane in all five repos parses every tracked script under **bash 3.2.57** on `arm64-apple-darwin25` and runs the fitness gates against Darwin's **own BSD userland** — including `governance/scripts/check-docs.sh`, the gate the 2026-08 audit found would have aborted outright on macOS via `find -printf`. Two genuinely macOS-fatal defects had been found and fixed by the audit this replaces: that one, and `bench-storage.sh` using `stat -f -c %T` with the error swallowed by `2>/dev/null \|\| echo unknown`, leaving its RAM-disk guard **silently inert on macOS**. The audit is now a standing gate (`check-shell-portability.sh`, SPEC-0014) rather than something someone remembers to run. `sort -z` is **resolved**: Darwin accepts it, so it was never a defect — dropping it from `dev-up.sh` was still right, being cosmetic there. **What is not verified is a cluster bring-up on a Mac**, which needs a hypervisor a hosted runner has not got; see [What is verified about macOS, and what is not](#what-is-verified-about-macos-and-what-is-not). |

### The object tier: wired to S3, because the FUSE mount cannot propagate here

`git-storaged` and the data plane now carry the five `GITFROK_SEAWEEDFS_S3_*` variables, so this
cluster serves LFS. **That is the S3 adapter and not the FUSE mount ADR-0050 decides on**, and the
reason is measured rather than assumed.

ADR-0051 produces the mount with a privileged DaemonSet — the only shape Kubernetes allows, since
kubelet rejects `mountPropagation: Bidirectional` on any container that is not privileged. It was
built (`seaweedfs-mount.yaml`) and run here, and it does not work on this driver:

| Observation | Value |
|---|---|
| the DaemonSet's own mount | `seaweedfs:8888:/gitfrok /mnt/seaweedfs fuse.seaweedfs rw,…` |
| its propagation flag inside the pod | `shared:1550` |
| the node's `/` propagation | `shared` |
| **seaweed mounts in the node's table** | **0** |
| what the consumers bound instead | the plain directory underneath |
| what a write from `git-storaged` produced | `/mnt/seaweedfs/lfs/roundtrip.txt` **on node-local disk**, readable back on that node, invisible to the filer and to the mount pod |

That last row is the whole problem: **every check passed while the data diverged.** `mountpoint -q`
passed, a write-then-read gate passed, `objectstore.NewMount`'s writability probe passed. Only
comparing three views — consumer, mount pod, filer — showed the objects were never in SeaweedFS at
all. It is precisely the failure ADR-0050 and ADR-0051 exist to prevent, reproduced inside the checks
meant to catch it.

So the DaemonSet is **not applied by default**: `MOUNT_DAEMONSET=1 make dev-up` deploys it on a node
whose driver propagates mounts, waits for it to serve bytes, and only then patches `git-storaged` and
the data plane onto it — a `HostToContainer` hostPath of `type: Directory` and
`GITFROK_SEAWEEDFS_MOUNT=/mnt/seaweedfs`, which the process prefers over the S3 variables. That
patch is deliberately not in the committed manifests: a `type: Directory` hostPath in the tracked
YAML would refuse to start both planes on every node without the DaemonSet, which is the default
path here.

**Each consumer gets an init container that refuses to start unless `/mnt/seaweedfs` is a
`fuse.seaweedfs` mount in its own namespace** (ADR-0051 decision 3), and it is the load-bearing part
of that patch. Nothing else catches the failure above: the DaemonSet's readiness proves only that
`weed` serves its own mount inside its own namespace, `type: Directory` passes because the host
directory exists whether or not anything is mounted over it, and `objectstore.NewMount` probes for a
writable directory, which a plain host directory is. `smoke-dev.sh` reports the two claims
separately for the same reason — the mount pod being Ready and the consumers actually having a
propagated mount are not the same statement. ADR-0050 decision 6 keeps the S3 adapter for exactly this case —
"how a deployment without a mount runs" — and this is that deployment. `smoke-dev.sh` reports which
tier is in use rather than staying silent about it.

Two other defects were found getting here, both by running it:

1. **`weed mount` needs the filer's gRPC port, 18888, and the Service never exposed it.** SeaweedFS
   derives it as HTTP+10000 and does not announce it; the HTTP port is used only to *look it up*.
   The mount client retried `dial tcp …:18888: i/o timeout` indefinitely while the filer sat healthy
   on 8888. Now in `seaweedfs.yaml`'s container ports and Service.
2. **The S3 endpoint served every object to unsigned requests.** The credentials were attached to the
   identity named `anonymous`, which is SeaweedFS's *unauthenticated* identity — so the keys were
   decoration and the gateway was open to anyone who could reach `s3.gitsaas.test`. Tolerable while
   nothing lived there; not once it became the large-object tier holding tenant LFS data. The
   identity is now named `gitfrok`, and `s3.gitsaas.test` answers **403** to an unsigned request.

Caught by running backend's live suite against this cluster, which is also the proof the tier works:

```
--- PASS: TestLiveSeaweedFSRoundTrip
--- PASS: TestLiveSeaweedFSAbsentObject
--- PASS: TestLiveSeaweedFSHonoursOurPresignedURL
--- PASS: TestLiveSeaweedFSRefusesAnUnsignedRequest      # failed before the identity was renamed
--- PASS: TestLiveSeaweedFSRefusesATamperedPresignedURL
```

```bash
kubectl --context gitfrok port-forward -n default svc/seaweedfs 18333:8333 &
cd backend && GITFROK_TEST_SEAWEEDFS_ENDPOINT=http://127.0.0.1:18333 \
  GITFROK_TEST_SEAWEEDFS_BUCKET=gitfrok \
  GITFROK_TEST_SEAWEEDFS_ACCESS_KEY=minioadmin GITFROK_TEST_SEAWEEDFS_SECRET_KEY=minioadmin \
  go test ./platform/objectstore/ -run TestLiveSeaweedFS -count=1
```

**The bucket is created by `dev-up.sh` before anything can write.** SeaweedFS answers **200 to a PUT
into a bucket that does not exist** and keeps nothing, and a bucket written to before it was
registered stays poisoned — reads return `NoSuchBucket` permanently, with no repair but a new name.
Both were found against a live gateway during T-0018.

Live bare repositories are unaffected and stay on the block-backed PVC: ADR-0033 stands,
`GITFROK_GIT_STORAGE_ROOT` points at the PVC, and `git-storaged` refuses a FUSE repository root
outright (invariant 7).

### The Git tier and CI scaling, and what is not proven about them

`git-storaged.yaml` and `ci-scaledobject.yaml` land after the T-0021 run that verified the two
planes, so **neither has run in a cluster**. Four things about them are worth stating rather than
leaving to be discovered:

1. **`git-storaged` is the one first-party image with a base.** Its whole job is to execute git as a
   subprocess, so it cannot ship from `scratch` (ADR-0048). Its root filesystem is also writable,
   unlike the planes': git writes lock files, temporary objects and hooks inside the repository
   tree, and git-storaged rewrites the `pre-receive` hook on every push.
2. **The data plane's Git front doors are configured now** that there is something to call, which
   also means the plane now needs the generated PAT verifier key — `dev-up.sh` upserts it as a
   Secret rather than committing one.
3. **The `ScaledObject` cannot yet demonstrate real autoscaling.** The dev job queue is in-process,
   so each replica reports its own depth and a new replica starts empty. The scaler, the metric and
   the trigger are correct; dividing the work needs the durable queue.
4. **First-party images here are pinned by tag, not digest.** ADR-0035 decision 4 requires a digest.
   The tag is what the verified T-0021 bring-up uses, so it is left alone rather than changed blind;
   closing that gap is a follow-up, and it is a real one.

### Defects found bringing this cluster up

All ten were invisible to review and to `check-dev-images.sh`, because nothing had executed. #1–7
came from the first cluster run (2026-08-06); #8–10 needed a *create* path that had never once run to
completion, which only surfaced on 2026-08-08 once #9 stopped blocking it:

| # | Defect | How it failed → fix |
|---|---|---|
| 1 | postgres PVC at `/var/lib/postgresql/data` | pg18 **exits** on that mount (data belongs one level up; docker-library/postgres#1259) → mounted one level up |
| 2 | `redpandadata/redpanda:v26.1` | never published — Redpanda tags patch releases only, no floating minor → pinned `docker.io/redpandadata/redpanda:v26.2.1` (below: [why `docker.io`](#why-redpanda-is-pinned-on-dockerio)) |
| 3 | seaweedfs `args: [all, …]` | `weed: unknown subcommand "all"` → `server` + `-filer` |
| 4 | zitadel `--tls-mode=external` | flag is camelCase → `--tlsMode` |
| 5 | seaweedfs readiness `path: /status` | 404s on the master, rollout never Ready → `/cluster/status` |
| 6 | zitadel `Port` config | Kubernetes' `ZITADEL_PORT` service-link env collides with Zitadel's own `ZITADEL_` prefix → `enableServiceLinks: false` |
| 7 | RWO PVCs, default `RollingUpdate` | new pod starts before the old releases the volume; rollout deadlocks → `strategy: Recreate` on all four stateful deployments |
| 8 | `dev-up.sh` didn't converge a **failed** create | minikube's retry drops the container but leaves the podman volume, so attempt two dies on `volume already exists` and the profile is stuck taking the create branch forever → `minikube delete` a non-running profile before creating |
| 9 | `fs.inotify.max_user_instances` exhausted | Fedora ships 128; a GUI session had ~114 in use, so PID 1 in the node gets none and exits → preflight check on the create path, prints the `sysctl` fix |
| 10 | `dev-up.sh` never passed `--container-runtime` | minikube 1.35 defaults to docker, which fails to provision → `MINIKUBE_RUNTIME=containerd` (the default here) |

One more, found in passing: `mkcert -install` ran under `set -e` and aborted the whole bring-up on a
host without passwordless sudo, over a step no acceptance criterion depends on. It now warns and
continues when the CA already exists.

### macOS: what's actually verified

AC4 needs both an old **shell** (bash 3.2.57) and a BSD **userland** proven, not just grepped for.

| Claim | Status |
|---|---|
| No OrbStack, no Docker Compose anywhere | verified — every mention in the tree is a prohibition |
| No bash-4 syntax or GNU-only behaviour in the fitness gates | verified — a `macos-latest` lane in all five repos runs them under real bash 3.2.57 on Darwin's own BSD userland |
| No GNU-only tool flags (`grep -P`, `find -printf`, `date -d`, `stat -c`, …) | **two real defects found and fixed** — `check-docs.sh`'s `find -printf` and `bench-storage.sh`'s `stat -f -c` (its failure was swallowed by `2>/dev/null`, leaving the guard silently inert); now a standing gate, `check-shell-portability.sh` |
| `seq`, `sort -z` | fine as written — Darwin ships both; two earlier worries that running the gate for real showed were unfounded |
| `date +%N` (`bench-git-workload.sh`) | known, self-guarded — the script exits with a clear message without GNU `date` |
| The dev cluster comes up on a Mac | **NOT verified** — needs a hypervisor no hosted runner has |

The macOS lane replaced a bash-3.2-in-an-Alpine-container audit, which could prove GNU-extension-free
shell but nothing about Darwin's actual `find`/`stat`/`sed`/`date` — the lane checks it really is
running those before it will report success.

Also outstanding: no CI wires this Minikube flow itself (ADR-0024's stated intent) — only
`check-dev-images.sh` gates from CI; the unused Zitadel PVC; `namespace: default` hardcoded in all 24
objects, so two stacks cannot coexist; Valkey has no `maxmemory`; per-OS Minikube driver docs (an
ADR-0024 follow-up).

## References

- **ADR-0023:** technology stack version floors
- **ADR-0024:** Minikube-only local dev (no OrbStack/Compose)
- **ADR-0016:** git storage tier (SeaweedFS reference)
- **T-0003:** Minikube dev environment (this task)
- **T-0004:** tenancy + RLS baseline (consumes the `postgres-init` ConfigMap and `gitfrok_app`)
- **T-0013:** identity & access — Zitadel + PATs (extends `zitadel.yaml`)
