# `deploy/gcp` — production infrastructure (OpenTofu + Terragrunt)

**Decision of record: [ADR-0092](../../governance/docs/adr/0092-gcp-as-the-first-party-cloud-provisioned-by-opentofu.md)
(Accepted).** Read it first; it explains every choice this tree makes, and where it and this README
disagree, the ADR wins (ADR-0001).

Accepted decides *where* the control plane runs. It does not make this tree appliable: both
`project_id` values and the DNS apex are placeholders, and `prod-cp`'s `admin_networks` is
`0.0.0.0/0`. Set all four before any `terragrunt apply` — no gate checks them.

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
| `dns-zone` | the public zone (control plane only) |
| `workload-identity` | Google service accounts and their keyless KSA bindings |

Every stateful dependency — Postgres, Valkey, Redpanda, SeaweedFS, OpenBao, Zitadel — runs
**in-cluster** on the pins in `../dev/versions.env` (ADR-0092 decision 5). There is no Cloud SQL, no
Memorystore, no Pub/Sub and no GCS blob bucket, and that is the choice that keeps ADR-0010's port to
EKS/AKS a four-unit change.

## Two environments, two shapes

```
live/prod-cp     control plane — public API endpoint (authorized networks), a DNS zone, no runner pool
live/prod-dp     data plane    — PRIVATE endpoint, no DNS zone, gVisor runner pool, no inbound path
```

`prod-dp` is us as our own first customer. It is not a second control plane, and its lack of any
inbound path is ADR-0011 made structural: the cluster API is private, nothing publishes a name, and
no unit creates a load balancer.

## Before the first run

1. **Create the two projects** and set `project_id` in both `env.hcl` files. Nothing here invents a
   project.
2. **Set `dns_name`** in `live/prod-cp/env.hcl` to the real apex, trailing dot included.
3. **Set `admin_networks`** in `live/prod-cp/env.hcl` to the real operator CIDR. It ships as
   `0.0.0.0/0` with a TODO, and that is not merely insecure — GKE's master-authorized-networks API
   has historically refused `0.0.0.0/0` as an entry, so the placeholder may fail the apply outright.
4. **Authenticate:** `gcloud auth application-default login`.

The state bucket is created for you, per environment, as `<project_id>-tfstate` with versioning on.
There is no bootstrap unit.

## Running it

```sh
cd live/prod-cp
terragrunt run --all plan        # dependency order is derived from the dependency blocks
terragrunt run --all apply
```

A single unit:

```sh
cd live/prod-cp/gke
terragrunt plan
terragrunt apply
```

`plan` works before anything exists because each `dependency` block carries `mock_outputs` for
`validate` and `plan` only — an apply always uses real outputs.

Tool versions are constrained in `root.hcl` (OpenTofu ≥ 1.12.6, Terragrunt ≥ 1.1.3, provider
`hashicorp/google` ~> 7.45). They are **not** in `.tool-versions`, which means
`scripts/check-version-floors.sh` does not gate them — recorded as an ADR-0092 follow-up.

## The two manual seams

These exist because they cross a boundary OpenTofu should not cross silently.

**Cross-project image pull.** `prod-dp` has no registry; it reads `prod-cp`'s. After both
environments apply, take `prod-dp`'s `workload_identity.service_account_emails["dataplane"]` and add
it to `reader_members` in `live/prod-cp/artifact-registry/terragrunt.hcl`:

```hcl
reader_members = ["serviceAccount:prod-dp-dataplane@gitfrok-prod-dp.iam.gserviceaccount.com"]
```

It is two steps rather than a `dependency` block because the two environments hold separate state,
and a read grant across a project boundary is worth seeing in a diff.

**KSA annotations.** `workload-identity` outputs `ksa_annotations` — the annotation each Kubernetes
service account needs to assume its Google identity. OpenTofu does not apply them (decision 4). Hand
them to whatever renders the manifests.

## What is missing, and is not an oversight

**The control plane has no chart.** `../dev/*.yaml` is Minikube-only by ADR-0024, and ADR-0013's
chart is the *data-plane* installer. So this tree can provision the control-plane cluster and
nothing can yet deploy the control plane into it. That is an open ADR-0092 follow-up and it blocks a
first real deployment — it is not something to work around here.

Also open, per the ADR: ingress/TLS/DNS records for the public surface, backup and restore for the
in-cluster stateful set, and a staging environment.
