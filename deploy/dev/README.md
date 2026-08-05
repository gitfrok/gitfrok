# Minikube Dev Environment Manifests — T-0003

Kubernetes manifests for the local Minikube dev environment per ADR-0024.

> **Status: complete enough to run, but never actually run.** T-0003 is still `Todo` in
> `governance/docs/tasks/T-0003-minikube-dev-env.md`. `make dev-up` and `make dev-smoke` now exist
> and the manifests are statically validated (YAML parses, object names are legal, volume/ConfigMap
> references resolve, ingress backends match real Services and ports). But **nothing here has been
> applied to a cluster** — no `kubectl apply`, not even a server-side dry-run, because this repo has
> no `minikube`/`kubectl`/`mkcert` installed. Image-behaviour details (entrypoints, config schemas,
> probe paths) get their first real test on your first `make dev-up`; expect to fix forward.
> See [What is not done yet](#what-is-not-done-yet).

## Service Architecture

```
Local Services (Minikube + ingress-dns)
├── postgres:5432          — PostgreSQL 18 (tenancy + RLS, T-0004)
├── valkey:6379            — Valkey 9.1 (replaces Redis, ADR-0023)
├── redpanda:9092          — Redpanda v26.1 (event broker)
│   ├── :8081              — Schema Registry
│   ├── :8082              — PandaProxy (HTTP proxy)
│   ├── :9644              — Admin API (readiness)
│   └── :33145             — internal RPC
├── seaweedfs:9333         — SeaweedFS 4.40 (S3-compatible blob storage)
│   ├── :8888              — Filer API
│   └── :8333              — S3 API
├── zitadel:8080           — Zitadel (OIDC/OAuth2, T-0013)
└── hello:8080             — busybox httpd; the smoke-test fixture, not a real service
```

In-cluster clients address these by Service name (`postgres:5432`, `seaweedfs:8333`). The
`*.gitsaas.test` hostnames are for the host machine and for S3 clients that need a real hostname —
they are routed by `ingress.yaml`, not by Service DNS.

## Manifest Files

| File | Service | Image | State |
|------|---------|-------|-------|
| `postgres.yaml` | PostgreSQL 18 | `postgres:18` | written, unapplied |
| `valkey.yaml` | Valkey 9.1 | `valkey/valkey:9.1` | written, unapplied |
| `redpanda.yaml` | Redpanda v26.1 | `redpandadata/redpanda:v26.1` | written, unapplied |
| `seaweedfs.yaml` | SeaweedFS 4.40 | `chrislusf/seaweedfs:4.40` | written, unapplied |
| `zitadel.yaml` | Zitadel | `ghcr.io/zitadel/zitadel:latest` | written, unapplied |
| `hello.yaml` | smoke-test fixture | `busybox:1.35` | written, unapplied |
| `ingress.yaml` | — | — | written, unapplied; needs the TLS secret `dev-up` creates |

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

**SeaweedFS (`seaweedfs.yaml`)** — master + filer + S3 in one pod (`weed all`). There is no
`s3.gitsaas.test` Service: Service names must be RFC 1035 labels, so a dotted name is rejected
outright, and it would not have produced that hostname anyway. Use `seaweedfs:8333` in-cluster or
the ingress host from outside. The `s3_config.json` credentials `minioadmin`/`minioadmin` are
attached to the identity named `anonymous`, which is SeaweedFS's *unauthenticated* identity — as
written the S3 endpoint is open Read/Write/List without credentials. Acceptable for a local cluster,
not a model for anything else.

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
| AC1 — `make dev-up` starts Minikube with `ingress` + `ingress-dns` | **partially verified** — `dev-up.sh` ran end to end and enabled both addons (they were `disabled` beforehand, so that half is a real test). Its *cluster-create* path was skipped: the cluster already existed, and the script converges rather than recreating. Verifying the create path needs a profile `dev-up` makes itself. |
| AC2 — all services come up from these manifests using `versions.env` tags | **VERIFIED** — all six deployments Available, and `smoke-dev.sh` confirmed all six running images come from `versions.env`. Getting here took **seven manifest fixes** (below); as written, three of the five services could never have started. |
| AC3 — services reachable at `*.gitsaas.test` over HTTPS via a mkcert wildcard secret | **verified in substance, not by the specified path** — ingress serves the mkcert wildcard for `hello.gitsaas.test` and returns the fixture: `http_code=200`, `ssl_verify_result=0` (validated against the mkcert CA, never `curl -k`). That was reached through `kubectl port-forward`, because under **rootless** podman the node IP is unroutable from the host — `ping 192.168.49.2` is 100% loss, and `smoke-dev.sh`'s `--resolve` fallback times out (`rc=28`). No host-DNS or `/etc/hosts` entry can fix that; it needs a rootful driver or KVM. |
| AC4 — no OrbStack, no Docker Compose; macOS and Linux | **holds, Linux now demonstrated** — no compose files exist and every OrbStack/Compose mention in the tree is a prohibition. The scripts ran on Linux for real; `macOS` remains unverified, and the bash-3.2 claim was re-checked by grep (no `declare -A`, `mapfile`, `readarray`, or `${var,,}`). |

### The seven defects the first run found

Each was invisible to review and to `check-dev-images.sh`, because nothing had executed:

| # | Defect | How it failed |
|---|---|---|
| 1 | postgres PVC mounted at `/var/lib/postgresql/data` | pg18 stores data in major-version subdirectories and **exits** rather than ignore that mount: *"there appears to be PostgreSQL data in /var/lib/postgresql/data (unused mount/volume)"*. Fixed to a single mount one level up (docker-library/postgres#1259). |
| 2 | `redpandadata/redpanda:v26.1` | never published — the registry answers `not found`. The v26.1 **series** exists (v26.1.2…v26.1.14) but Redpanda tags patch releases only, so there is no floating minor tag to pin. Now `docker.redpanda.com/redpandadata/redpanda:v26.2.1`. |
| 3 | seaweedfs `args: [all, …]` | `weed: unknown subcommand "all"`. The set is `master\|volume\|filer\|s3\|server`; combined mode is `server`, and `-filer` must be asked for explicitly or nothing serves `filer.gitsaas.test:8888`. |
| 4 | zitadel `--tls-mode=external` | `Error: unknown flag`. The flag is `--tlsMode` — camelCase. |
| 5 | seaweedfs readiness `path: /status` | 404s on the master (*"volume id status not found"*), so the pod never became Ready and the rollout blocked forever. `/cluster/status` is the health endpoint and returns `{"IsLeader":true,…}`. |
| 6 | zitadel `Port` config | Kubernetes injects `<SVC>_PORT=tcp://<ip>:<port>` for every Service in the namespace. The Service is named `zitadel`, Zitadel's config reader consumes `ZITADEL_`-prefixed env vars, so it received `ZITADEL_PORT=tcp://10.97.6.84:8080` where it wanted a `uint16`. Fixed with `enableServiceLinks: false`. **Only visible after #4** — the unknown-flag error killed it before config parsing. |
| 7 | RWO PVCs with the default `RollingUpdate` | the replacement pod starts while the old one still holds the volume: redpanda died with *"failed to lock pidfile. already locked"*, and the rollout deadlocks — the old pod will not terminate until the new is Ready, and the new cannot be Ready until the old lets go. `strategy: Recreate` added to postgres, valkey, redpanda and seaweedfs (zitadel already had it). Redpanda's *first* rollout squeaked through, which is worse than a clean failure because it hides the bug. |

One script change came with them: `dev-up.sh` called `mkcert -install` under `set -e`. That step writes
the **system** trust store and needs root, so on a host without passwordless sudo it aborted the whole
bring-up before applying a single manifest — over a step no acceptance criterion depends on
(`smoke-dev.sh` validates with `--cacert` against `rootCA.pem`). It now warns and continues when the CA
exists, matching how the script already treats host DNS: print the root-requiring step, don't do it.

Also outstanding:

- **AC1's create path and AC3's specified path need a different host** — a rootful Docker/podman
  driver or KVM. Everything else about this environment is now demonstrated rather than asserted.
- ADR-0024 says the same Minikube flow is used in CI; nothing wires that yet, and super-repo CI has
  `contents: read` with no cluster. `check-dev-images.sh` is the only part of this that CI gates.
- `ZITADEL_IMAGE` is `:latest` — warned by `check-dev-images.sh`, still not a pin
- The scripts default to profile `gitfrok`; a cluster created by hand as `minikube` needs
  `MINIKUBE_PROFILE=minikube`. `smoke-dev.sh` now says so in one line instead of reporting six
  dead deployments — every query in it is `2>/dev/null || true`, so a nonexistent context used to be
  indistinguishable from a cluster whose services had all failed
- the unused Zitadel PVC; `namespace: default` hardcoded in all 24 objects, so two stacks cannot
  coexist; Valkey has no `maxmemory`; SeaweedFS's S3 endpoint is open
- per-OS Minikube driver docs (an ADR-0024 follow-up)

## References

- **ADR-0023:** technology stack version floors
- **ADR-0024:** Minikube-only local dev (no OrbStack/Compose)
- **ADR-0016:** git storage tier (SeaweedFS reference)
- **T-0003:** Minikube dev environment (this task)
- **T-0004:** tenancy + RLS baseline (consumes the `postgres-init` ConfigMap and `gitfrok_app`)
- **T-0013:** identity & access — Zitadel + PATs (extends `zitadel.yaml`)
