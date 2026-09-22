# `deploy/gcp` — production infrastructure (OpenTofu + Terragrunt)

**Decision of record: [ADR-0092](../../governance/docs/adr/0092-gcp-as-the-first-party-cloud-provisioned-by-opentofu.md)
(Accepted).** Read it first; it explains every choice this tree makes, and where it and this README
disagree, the ADR wins (ADR-0001).

> **Nothing billable is provisioned, and the free scaffolding is.** As of 2026-09-22, after a build,
> a teardown, a rebuild (15/15 units), a full sweep to zero, and then a deliberate partial rebuild of
> only the units that cost nothing.
>
> **Applied and running at ~$0:** `project-services`, `workload-identity` (7 service accounts),
> `image-publish-identity` (the WIF pool and publisher SA), `artifact-registry` (empty, public-read
> per ADR-0098) and `backups` (two empty buckets). The two VPCs and subnets survived every teardown
> and were never re-applied. **Verified absent in both projects:** clusters, instances, disks,
> routers and addresses — all zero.
>
> **Not applied, because these are what cost money:** `gke` (~$750/mo and effectively the whole
> bill), Cloud NAT (~$32/mo per gateway — it lives in the `network` unit but `enable_nat` turns it
> off), `addresses` (~$7/mo each, since a *reserved but unused* static IP still bills) and
> `zt-connector` (~$7/mo each). Applying `network` as written recreates NAT, so the free rebuild
> skips it entirely rather than relying on the VPC being idempotent.
>
> [`../TEARDOWN-RUNBOOK.md`](../TEARDOWN-RUNBOOK.md) covers both directions, including the disk sweep
> that a cluster deletion does not do for you. **Read the present tense below as "what an apply
> creates", not "what is running".**
>
> **OpenTofu state is stale by design here**: the clusters and their downstream resources were
> deleted out of band with `gcloud`, so a `plan` will want to recreate everything. That is correct
> and is how the rebuild is meant to start.

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
| `gke` | the regional cluster, a `system` node pool, and on the data plane a gVisor `runners` pool |
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
