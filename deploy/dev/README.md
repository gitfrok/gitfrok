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

Against T-0003's acceptance criteria:

| AC | State |
|---|---|
| AC1 — `make dev-up` starts Minikube with `ingress` + `ingress-dns` | **implemented, unverified** — `scripts/dev-up.sh` does exactly this; never run against a real Minikube |
| AC2 — all services come up from these manifests using `versions.env` tags | **implemented, unverified** — enforced twice (`check-dev-images.sh` on the manifests, `smoke-dev.sh` on running pods); "come up" itself is untested |
| AC3 — services reachable at `*.gitsaas.test` over HTTPS via a mkcert wildcard secret | **implemented, unverified, one manual step** — `dev-up` creates the secret and `ingress.yaml` routes the hosts, but host DNS needs root and is not automated |
| AC4 — no OrbStack, no Docker Compose; macOS and Linux | **holds** — nothing here uses either; the scripts avoid bash 4+ constructs so they run on macOS's bash 3.2 |

Every AC above says *unverified* for the same reason: no cluster has ever run this. That is the
single thing standing between T-0003 and Done, and it needs a machine with `minikube`, `kubectl` and
`mkcert` — not more code.

Also outstanding:

- **run it**, then flip T-0003's ACs in `governance/` — a separate PR from any super-repo change
  (invariant 23)
- ADR-0024 says the same Minikube flow is used in CI; nothing wires that yet, and super-repo CI has
  `contents: read` with no cluster. `check-dev-images.sh` is the only part of this that CI gates.
- `ZITADEL_IMAGE` is `:latest` — warned by `check-dev-images.sh`, still not a pin
- Postgres `PGDATA` (see [Persistent Storage](#persistent-storage)) — the one unverified item that
  silently destroys data rather than failing loudly
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
