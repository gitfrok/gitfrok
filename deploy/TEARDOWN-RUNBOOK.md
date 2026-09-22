# Teardown and rebuild runbook (GCP)

Companion to [`gcp/README.md`](gcp/README.md) (what the tree provisions) and
[`k8s/README.md`](k8s/README.md) (what gets deployed into it). This file is the reverse
direction, and the verification sweep that says whether it worked.

**Written 2026-09-22, immediately after tearing the environment down.** Every caveat below is
something that actually happened during that run, not something anticipated. The cost figures are
order-of-magnitude, not a quote.

## Why this file exists

`terragrunt run --all destroy` does **not** leave you at zero, and it does not tell you that. On
the run this documents it destroyed 9 of 16 units, exited non-zero, and left behind roughly
**$180/month** of resources — most of it in disks that no unit ever declared. A teardown you have
not swept is a teardown you have not finished.

## Teardown

### 1. Destroy what the tree declares

```sh
cd deploy/gcp/live          # NOT live/prod-cp — run --all discovers from the git root
terragrunt run --all --non-interactive -- destroy -auto-approve
```

Expect this to **fail on both `gke` units** and skip everything downstream of them:

```
Error: Cannot destroy cluster because deletion_protection is set to true.
* Unit '.../prod-cp/network' did not run due to an earlier failure
```

`deletion_protection` is a **provider-side attribute of `google_container_cluster`, not a GKE API
field.** This matters twice over:

- There is no `gcloud container clusters update --no-enable-deletion-protection`. That flag does not
  exist; the SDK will suggest `--enable-autoprovisioning` and waste a minute of your life.
- `gcloud container clusters delete` is **not** subject to it and works immediately.

So either flip `deletion_protection = false` in `modules/gke-cluster` and re-run, or skip straight
to step 2. Step 2 is faster and is what the documented run did.

### 2. Delete the clusters directly

```sh
gcloud container clusters delete prod-cp-gke --region=asia-southeast1 \
  --project=gitfrok-prod-cp --quiet --async
gcloud container clusters delete prod-dp-gke --region=asia-southeast1 \
  --project=gitfrok-prod-dp --quiet --async
```

**A cluster whose node pool was already destroyed by step 1 sits in `RECONCILING` and refuses:**

```
ResponseError: code=400, message=Cluster is running incompatible operation operation-...
```

That is not an error to debug. Wait for `RUNNING`, then issue the delete. It took about four
minutes on the documented run:

```sh
until [ "$(gcloud container clusters list --project=gitfrok-prod-cp \
  --format='value(status)')" != "RECONCILING" ]; do sleep 20; done
```

### 3. Sweep the persistent disks — the step nobody remembers

**Deleting a GKE cluster does not reclaim disks that were provisioned by `PersistentVolumeClaim`s.**
On the documented run this left **13 orphaned `pd-ssd` volumes totalling 550 GB — about $90/month**,
still present after every node was gone: the OpenBao, Postgres, Redpanda and Valkey volumes from
`k8s/platform`. Nothing in `deploy/gcp` declares them, so no `destroy` will ever remove them, and
they do not appear in any plan.

```sh
gcloud compute disks list --project=gitfrok-prod-cp   # expect these to be non-empty
gcloud compute disks list --project=gitfrok-prod-cp --format='value(name,zone.basename())' \
  | while read -r n z; do
      [ -n "$n" ] && gcloud compute disks delete "$n" --zone="$z" \
        --project=gitfrok-prod-cp --quiet
    done
```

Run it for both projects. **This destroys the stateful set's data**, which is the point of a
teardown — but if the cluster held anything you want, CNPG's backup bucket is the only copy, and
step 1 already deleted that bucket.

### 4. Delete the routers if the network units were skipped

Cloud NAT bills per gateway-hour — about **$32/month each**, two of them — and the `network` units
are downstream of `gke`, so step 1's failure skips them.

```sh
gcloud compute routers delete prod-cp-router --region=asia-southeast1 --project=gitfrok-prod-cp --quiet
gcloud compute routers delete prod-dp-router --region=asia-southeast1 --project=gitfrok-prod-dp --quiet
```

Re-running `terragrunt run --all destroy` once the clusters are gone is the tidier route and will
also drop the VPCs and subnets. On the documented run that retry died on a transient
`lookup oauth2.googleapis.com: no such host` on the workstation, which is why the direct commands
are recorded here as the fallback rather than an afterthought.

### 5. Sweep, and only then believe it

Nothing is torn down until this prints zeros. Run for **both** projects:

```sh
for P in gitfrok-prod-cp gitfrok-prod-dp; do
  echo "== $P"
  for R in "container clusters" "compute instances" "compute disks" \
           "compute routers" "compute addresses" "compute forwarding-rules"; do
    printf '%-26s %s\n' "$R" \
      "$(gcloud $R list --project=$P --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
  done
  printf '%-26s %s\n' "artifacts repositories" \
    "$(gcloud artifacts repositories list --project=$P --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
  gcloud storage buckets list --project=$P --format='value(name)' 2>/dev/null
done
```

## What survives a complete teardown, deliberately

| Thing | Why it stays | Cost |
|---|---|---|
| `gitfrok-prod-cp-tfstate`, `gitfrok-prod-dp-tfstate` | created by `--backend-bootstrap`, never declared by a unit, so no `destroy` targets them | a few KB — nil |
| The VPCs (`prod-cp-vpc`, `prod-dp-vpc`, `default`) | networks and subnets are not billed | nil |
| Both GCP projects | deleting them is a separate, bigger decision | nil once empty |
| The three Cloudflare DNS records | not in this tree at all (ADR-0095 decision 4 put them in a vendor console) | nil, but they now point at **released addresses** |

**The definitive stop**, if an empty project is not enough assurance:

```sh
gcloud projects delete gitfrok-prod-cp gitfrok-prod-dp
```

Recoverable for 30 days. It also deletes the state buckets, so the next build starts from empty
state — which is correct anyway once nothing exists.

**Remove the Cloudflare records too.** Left alone they resolve to addresses that now belong to
somebody else's project, which is worse than a `NXDOMAIN`.

## Rebuild

```sh
cd deploy/gcp/live
terragrunt run --all --non-interactive --backend-bootstrap -- apply -auto-approve
```

`--backend-bootstrap` is **required** — without it Terragrunt refuses rather than creating the state
buckets. Then follow [`k8s/README.md`](k8s/README.md) in order: CNPG operator → platform overlay →
**OpenBao initialise and quorum unseal** → control-plane overlay.

### The rebuild does not start from zero, and one thing actively refuses

**Workload Identity pools and providers are SOFT-deleted for 30 days, and the name stays
reserved.** This is the one step of the rebuild that fails outright. On the documented rebuild
`live/prod-cp/image-publish-identity` died with:

    Error: Error creating WorkloadIdentityPool: googleapi: Error 409: Requested entity already exists

and took `artifact-registry` down with it, being downstream. The pool is not gone — it is `DELETED`
and holding its name:

```sh
gcloud iam workload-identity-pools list --location=global --project=gitfrok-prod-cp --show-deleted
# prod-cp-github   DELETED

gcloud iam workload-identity-pools undelete prod-cp-github \
  --location=global --project=gitfrok-prod-cp
gcloud iam workload-identity-pools providers undelete github-oidc \
  --workload-identity-pool=prod-cp-github --location=global --project=gitfrok-prod-cp
```

Undeleting is not enough on its own: the restored objects are absent from OpenTofu state, so the
next apply hits the same 409. Import them, then apply:

```sh
cd deploy/gcp/live/prod-cp/image-publish-identity
terragrunt import google_iam_workload_identity_pool.github \
  "projects/gitfrok-prod-cp/locations/global/workloadIdentityPools/prod-cp-github"
terragrunt import google_iam_workload_identity_pool_provider.github \
  "projects/gitfrok-prod-cp/locations/global/workloadIdentityPools/prod-cp-github/providers/github-oidc"
terragrunt apply
cd ../artifact-registry && terragrunt apply     # skipped by the failure above
```

Service accounts soft-delete the same way. On the documented rebuild the publisher SA had already
been recreated within the same run, so only the pool and provider needed this.

**`run --all apply` exits 0 having run 7 of 9 units.** `gcp/README.md` warns about the wrapper's
exit code for `plan`; it is exactly as true for `apply`, and it is how the 409 above was nearly
missed. Count `Apply complete!` lines against the unit count — do not read `$?`.

Two things the rebuild does not restore at all, because they were never in the tree:

- **The Zero Trust tunnel token.** `zt-connector` creates the Secret Manager container and never its
  value. Until it is populated the connector boots, logs that the secret is empty, and exits 0 — a
  healthy instance, no tunnel, and a Kubernetes API nobody can reach. See `gcp/README.md`. Creating
  the tunnel, adding the token, resetting the instance and adding the private-network route are all
  Cloudflare-API calls; the **Access policy naming who may use that route is not**, and until it
  exists every device enrolled on the account can reach the route.
- **The three Cloudflare records**, which must be repointed at the **new** reserved addresses — and
  note *repointed*, not recreated: a teardown leaves them in place, resolving to released IPs. On
  the documented rebuild the global address came back **identical** (`34.98.93.111`, so `app-` and
  `auth-gitfrok` needed no change) while the agent door's did not — and the old agent IP had by then
  been recycled into this same project's **NAT** pool, so `agents-gitfrok` was pointing at our own
  NAT gateway. Check every record against `terragrunt output dns_records`; do not assume either way.
  `agents-gitfrok` must stay **DNS-only**; a proxied record terminates TLS and breaks every agent
  enrolment (ADR-0095 decisions 3–5).

And the OpenBao shares from the previous life are worthless: a rebuilt cluster is a new barrier with
new shares, and `bao operator init` is once per cluster, ever.

## Cost, so the next teardown can be prioritised

Roughly, per month, for what this environment ran:

| | ~Cost | Killed by |
|---|---|---|
| 6 × `n2-standard-4` nodes (2 clusters × 3) | $600 | step 1 or 2 |
| 550 GB `pd-ssd` PVC volumes | $90 | **step 3 only** |
| 2 × Cloud NAT | $64 | step 1 or 4 |
| 2 × GKE cluster management | $150 | step 1 or 2 |
| 2 × `e2-micro` connector VMs | $14 | step 1 |
| Reserved addresses, Artifact Registry, backup buckets | a few $ | step 1 |

If you are tearing down under time pressure, the order that stops the most spend soonest is:
**clusters (steps 1–2), then disks (step 3), then everything else.**
