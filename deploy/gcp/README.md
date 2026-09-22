# `deploy/gcp` — production infrastructure (OpenTofu + Terragrunt)

**Decision of record: [ADR-0092](../../governance/docs/adr/0092-gcp-as-the-first-party-cloud-provisioned-by-opentofu.md)
(Accepted).** Read it first; it explains every choice this tree makes, and where it and this README
disagree, the ADR wins (ADR-0001).

> **Both environments are up, in a deliberately minimum-cost shape.** As of 2026-09-22, after a
> build, a teardown, a rebuild, a full sweep to zero, a free-scaffolding-only rebuild, and then this
> one. Read the cost table at the bottom before changing any of it.
>
> **The shape, and it is not the shape ADR-0092 was written against:**
>
> - **Both clusters are ZONAL** (`asia-southeast1-a`), not regional. This is the single largest
>   lever in the tree and the one most likely to be re-broken by accident: a regional cluster
>   creates `min_nodes` nodes **per zone**, so a floor of 1 across three zones was three nodes per
>   cluster, six in total. The module (`var.location`) defaults to the region, so **deleting the
>   `location` line from a `gke/terragrunt.hcl` silently triples that environment's node bill.**
>   The trade is the managed control plane's multi-zone spread. Residency is unaffected — the zone
>   is inside the same region (G7).
> - **`e2-standard-4`, `min_nodes = 2`, 100GB `pd-balanced`** on both system pools. Two rather than
>   one because nothing in `../k8s/platform/base` declares CPU or memory requests: every pod is
>   therefore schedulable, the cluster autoscaler never sees a pending pod to scale up *for*, and an
>   undersized floor shows up as **eviction under memory pressure**, not as a pending pod.
> - **prod-dp's runner pool is capped at 4**, down from 20, and is `e2-standard-4` (not shared-core,
>   so ADR-0012's GKE Sandbox constraint still holds). `min_nodes = 0` keeps it free while idle; the
>   ceiling is purely a bound on what a busy queue can spend.
> - **PVCs are `standard-rwo`**, set in the overlays: prod-cp 550Gi→190Gi, prod-dp 710Gi→200Gi. See
>   each overlay's `patch-storage.yaml`. **When the git tier lands it needs its own `premium-rwo`
>   claim** (ADR-0033) — nothing currently deployed carries that contract, which is why this was
>   available at all.
>
> **Applied in both projects:** `project-services`, `workload-identity`, `network` (VPC + subnet +
> Cloud Router + NAT), `gke`, `zt-connector`, `backups`. **prod-cp only:** `addresses`,
> `artifact-registry`, `image-publish-identity`. There is deliberately no `live/prod-dp/addresses`.
>
> **Not running, and not for cost reasons:** the first-party control plane. No image has ever been
> published to Artifact Registry, and OpenBao must be initialised and unsealed by an operator before
> the control-plane overlay can start at all (ADR-0066 decision 4 — the shares never enter this repo,
> the cluster, or any environment file). Both are covered in `../k8s/README.md`.
>
> [`../TEARDOWN-RUNBOOK.md`](../TEARDOWN-RUNBOOK.md) covers both directions, including the disk
> sweep that a cluster deletion does not do for you.

**Updated 2026-09-22.** Both `project_id` values are real (`gitfrok-prod-cp`, `gitfrok-prod-dp`,
created 2026-09-22 on billing `2025-10280-7Solutions`), the DNS apex is gone — ADR-0095 made
Cloudflare authoritative and retired the Cloud DNS unit — and **both** clusters' Kubernetes API
endpoints are private with no authorized networks (ADR-0097 decision 1) — operators reach them
through Cloudflare Zero Trust, not from a public address. An open endpoint was briefly accepted
earlier the same day and reversed within it; `env.hcl` keeps that history because the empty
`admin_networks` list now means the inverse of what it meant then. No gate checks any of this, so
read `env.hcl` before an apply rather than trusting this paragraph.

## What this provisions, and what it refuses to

OpenTofu provisions **infrastructure**. It never provisions a **workload** (ADR-0092 decision 4).
The line is the Kubernetes API: if a thing is a Kubernetes object, it is not here — no Deployment, no
StorageClass, no namespace, no Helm release. That side of the line belongs to ADR-0013's chart and
Operator.

So the units end at:

| Unit | Creates |
|---|---|
| `project-services` | the APIs the environment is allowed to use |
| `network` | VPC, subnet with pod/service secondary ranges, Cloud Router + NAT |
| `gke` | the cluster — **zonal in both environments today**, regional if `location` is unset — a `system` node pool, and on the data plane a gVisor `runners` pool |
| `artifact-registry` | the Docker repository, immutable tags (control plane only) |
| `addresses` | the two reserved EXTERNAL addresses ADR-0095 decision 6 requires — a global one for the Gateway, a regional one for the L4 agent door (control plane only) |
| `workload-identity` | Google service accounts and their keyless KSA bindings |
| `zt-connector` | the Cloudflare Zero Trust connector VM, its service account, and the Secret Manager **container** for its tunnel token (ADR-0097) |

Every stateful dependency — Postgres, Valkey, Redpanda, SeaweedFS, OpenBao, Zitadel — runs
**in-cluster** on the pins in `../dev/versions.env` (ADR-0092 decision 5). There is no Cloud SQL, no
Memorystore, no Pub/Sub and no GCS blob bucket, and that is the choice that keeps ADR-0010's port to
EKS/AKS a four-unit change.

## Two environments, two shapes

```
live/prod-cp     control plane — PRIVATE API endpoint (Zero Trust), no DNS zone, no runner pool
live/prod-dp     data plane    — PRIVATE endpoint, no DNS zone, gVisor runner pool, no inbound path
```

`prod-dp` is us as our own first customer. It is not a second control plane, and its lack of any
inbound path is ADR-0011 made structural: the cluster API is private, nothing publishes a name, and
no unit creates a load balancer.

## Before the first run

1. ~~Create the two projects~~ — **done 2026-09-22**: `gitfrok-prod-cp` and `gitfrok-prod-dp`,
   both linked to billing `2025-10280-7Solutions`.
2. ~~Set `dns_name`~~ — **gone.** ADR-0095 decision 4 made Cloudflare authoritative for
   `7.solutions` and decision 10 retired this tree's `dns-zone` unit. The three records
   (`app-gitfrok`, `auth-gitfrok`, `agents-gitfrok`) are created operator-side in Cloudflare, and
   `agents-gitfrok` must stay **DNS-only** — a proxied record terminates TLS and breaks the
   client-certificate mTLS every agent depends on (ADR-0095 decision 5).
3. **`admin_networks` is empty and both endpoints are private** (ADR-0097). There is no operator
   CIDR to set, because Access authorizes a person rather than a network. The `zt-connector` unit
   provides the path, and **it is inert until its tunnel token is added by hand** — see "The Zero
   Trust tunnel token" below. Until then `gcloud container clusters describe` works and `kubectl`
   does not. Break-glass is in `env.hcl`, and it takes both halves.
4. **Authenticate:** `gcloud auth application-default login`. `gcloud auth login` alone does not
   satisfy the provider — it needs Application Default Credentials.

The state bucket is created for you, per environment, as `<project_id>-tfstate` with versioning on.
There is no bootstrap unit.

## Running it

```sh
cd live                          # NOT live/prod-cp — see the discovery note below
terragrunt run --all plan --non-interactive --backend-bootstrap
terragrunt run --all apply --non-interactive --backend-bootstrap
```

A single unit:

```sh
cd live/prod-cp/gke
terragrunt plan
terragrunt apply
```

**Three things verified against Terragrunt 1.1.4 on 2026-09-22, because the older spelling of each
fails:**

- The flag is **`--non-interactive`**, not `--terragrunt-non-interactive`. The old prefixed form is
  rejected outright with *"flag `-terragrunt-non-interactive` is not a Terragrunt flag"* and exits
  before doing anything. Harmless, but if you run it backgrounded the wrapper's exit code can read 0
  — read the log, not the exit code.
- **`--backend-bootstrap` is required** for the state bucket to be created. Without it Terragrunt
  refuses rather than creating it, so "the bucket is created for you" below is true only with this
  flag. (`--backend-require-bootstrap` is the opposite switch: fail if the bucket is absent.)
- **`run --all` discovers units from the git root, not the working directory.** `cd live/prod-cp`
  then `run --all` plans **prod-dp as well**. Scope it with `--filter`, or run from `live/` and
  accept both, which is what the recipe above does.

**Reauth (`invalid_rapt`).** This organization enforces periodic reauthentication. When ADC's proof
token expires, every API call fails with
`oauth2: "invalid_grant" "reauth related error (invalid_rapt)"` and no resource is created — a clean
failure, not a partial one. Fix it with `gcloud auth application-default login`; nothing else in this
tree can.

`plan` works before anything exists because each `dependency` block carries `mock_outputs` for
`validate` and `plan` only — an apply always uses real outputs.

Tool versions are constrained in `root.hcl` (OpenTofu ≥ 1.12.6, Terragrunt ≥ 1.1.3, provider
`hashicorp/google` ~> 7.45). They are **not** in `.tool-versions`, which means
`scripts/check-version-floors.sh` does not gate them — recorded as an ADR-0092 follow-up.

## The two manual seams

These exist because they cross a boundary OpenTofu should not cross silently.

**~~Cross-project image pull.~~ Closed by ADR-0098, and this section was stale.** It used to say
that after both environments apply you take `prod-dp`'s
`workload_identity.service_account_emails["dataplane"]` and add it to `reader_members` in
`live/prod-cp/artifact-registry/terragrunt.hcl`. **Do not.** ADR-0098 decision 2 made the
repository publicly readable (`reader_members = ["allUsers"]`) precisely so that a data plane — ours
or a customer's — pulls with no vendor credential. The unit already says so in its own comment.
A named per-plane grant now adds nothing and implies a credential requirement that ADR-0047
explicitly forbids operator manifests from carrying.

**The three Cloudflare DNS records.** `addresses` outputs `dns_records`, which is the actual answer
to "what do I type into Cloudflare": `app-gitfrok` and `auth-gitfrok` point at the global address and
**may** be proxied; `agents-gitfrok` points at the regional address and must stay **DNS-only**. That
last one is not a preference — the agent pins our CA to verify the server certificate, so a proxy
that terminates TLS is untrusted by every agent and enrolment fails as a TLS error rather than as the
topology mistake it is (ADR-0095 decisions 3–5). Cloudflare's dashboard defaults new A records to
proxied, so the safe click and the correct click differ here.

**The Zero Trust tunnel token.** `zt-connector` creates the Secret Manager secret and never its
value — ADR-0092 decision 6 forbids a secret as an OpenTofu input, so the token would otherwise land
in state. Read the unit's `manual_seam` output for the exact steps; the short version is: create the
tunnel in Cloudflare, `gcloud secrets versions add`, reset the instance, then add the private-network
route and an Access policy. **Until that is done the connector boots, logs that the secret is empty
and exits 0** — a healthy instance, no tunnel, and a Kubernetes API nobody can reach. It does not
look broken, which is why it is written down here.

The connector must stay in the cluster's **node subnet**. GKE grants the primary range of that subnet
access to a private control-plane endpoint by default; from anywhere else the control plane refuses
it with a timeout rather than an error naming the cause, and the fix would be maintaining the
authorized-network list ADR-0097 decision 2 exists to avoid.

**KSA annotations.** `workload-identity` outputs `ksa_annotations` — the annotation each Kubernetes
service account needs to assume its Google identity. OpenTofu does not apply them (decision 4). Hand
them to whatever renders the manifests.

## What is missing, and is not an oversight

**~~The control plane has no installer yet.~~ Built, and applied.** T-0084 built it at
`deploy/k8s/controlplane/` per ADR-0093 and ADR-0096, and T-0086 built the third-party stateful set
at `deploy/k8s/platform/`. As of 2026-09-22 both `platform` overlays are **applied and running** on
the two clusters this tree provisions. What still cannot be applied is the *first-party* half, for
want of a published image — see `../k8s/README.md`, which is the source of truth for the workload
side and lists all three remaining blockers.

**Helm is gone from this tree's vocabulary** (ADR-0096 decision 1). Where a sentence above says
"chart", read "installer": `deploy/helm/gitfrok-dataplane` is the last one left and T-0085 converts
it.

**~~The third-party stateful set has no production artifact.~~ Built (T-0086) and running.**
`../k8s/platform/overlays/{prod-cp,prod-dp}` are applied on both clusters, Postgres archiving WAL to
the `backups` bucket in each project.

Ingress/TLS/DNS is **no longer open** — ADR-0095 (Accepted 2026-09-22) decided it, and this tree
carries its two cluster-level halves: `gateway_api_config` and the L7 addon the managed Gateway
controller needs. The **reserved static addresses** ADR-0095 decision 6 requires now exist as the `addresses`
unit, because `deploy/k8s/controlplane` began consuming them. They are referenced **by name**
from the overlay, and `scripts/check-controlplane-kustomize.sh` asserts the two layers agree —
a rename on either side otherwise fails at GKE programming time with no diff to read, while a
hand-written Cloudflare record keeps pointing at whatever answered before.

Still open per the ADRs: backup and restore for the in-cluster stateful set, and a staging
environment.

## Cost, and which line each lever moves

The environment ran at roughly **$920/month** in its first shape. The table is what changed, in
units — the dollar figures come from `../TEARDOWN-RUNBOOK.md`'s reading of the actual bill and are
ratios to reason with, not a quote.

| Line | Was | Is | Lever |
|---|---|---|---|
| Nodes | 6 × `n2-standard-4` (2 clusters × 3 zones) | **4** × `e2-standard-4` (2 × 2) | `location` — zonal |
| Cluster management | 2 | 2 | unchanged; one zonal cluster may fall under GKE's free-tier credit |
| Boot disks | 6 × 200–500GB `pd-ssd` | 4 × 100GB `pd-balanced` | `system_pool.disk_*` |
| PVCs | 1,260Gi `premium-rwo` | **390Gi** `standard-rwo` | the overlays' `patch-storage.yaml` |
| Cloud NAT | 2 | 2 | required by private nodes (ADR-0011) — not reducible |
| Connector VMs | 2 × `e2-micro` | 2 × `e2-micro` | required by ADR-0097 — not reducible |
| CI runner ceiling | 20 × `n2-standard-8` | **4** × `e2-standard-4` | idle cost is zero either way; this bounds a busy queue |

**The two levers that look free and are not.** Deleting a `location` line triples that
environment's nodes, and it looks like tidying. Raising a PVC is easy; *lowering* one is not
possible without destroying the volume, so the sizes here were chosen while the disks held nothing
and should be raised deliberately rather than restored by reflex.

**`scripts/check-gke-location.sh` guards the first of those** (T-0091, SPEC-0072): every
`live/*/gke/terragrunt.hcl` must declare `location`, and `make verify` fails if one does not. Units
are discovered rather than listed, so a third environment is covered the day it is created.

**What that gate deliberately does NOT assert is the value.** A *region* is accepted exactly as
readily as a zone — the property under test is that somebody chose, not what they chose. So
restoring multi-zone HA stays a one-line edit and never becomes an argument with a fitness function:
set `location` to `asia-southeast1` and the gate is satisfied. ADR-0106 decision 2 asks only that
whoever does it can name the availability requirement that made it necessary.

**Spot VMs were considered and rejected.** OpenBao, Postgres and Redpanda are quorum workloads;
preemption costs a quorum, not a pod.
