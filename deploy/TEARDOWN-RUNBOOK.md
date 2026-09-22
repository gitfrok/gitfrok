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
gcloud container clusters delete prod-cp-gke --zone=asia-southeast1-a \
  --project=gitfrok-prod-cp --quiet --async
gcloud container clusters delete prod-dp-gke --zone=asia-southeast1-a \
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
`k8s/platform`. (Those overlays now claim `standard-rwo` and less of it — 390 GB across both
environments — so the bill for forgetting this step is smaller than it was, and the step is not.) Nothing in `deploy/gcp` declares them, so no `destroy` will ever remove them, and
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

### 4a. Delete what the Git door created by hand — no unit declares any of it

Since 2026-09-23 (ADR-0107, ADR-0108) `prod-dp` publishes the Git door, and **everything that
publishes it was created with gcloud, not OpenTofu** (T-0092). `terragrunt destroy` does not know it
exists. Deleting the cluster removes the Gateway's forwarding rule and URL map, but **not** the
reserved address — which keeps billing — and not the certificates.

```sh
P=gitfrok-prod-dp
gcloud certificate-manager maps entries delete git-gitfrok --map=gitfrok-dp-certmap --project=$P --quiet
gcloud certificate-manager maps entries delete gitfrok-apex --map=gitfrok-dp-certmap --project=$P --quiet
gcloud certificate-manager maps delete gitfrok-dp-certmap --project=$P --quiet
gcloud certificate-manager certificates delete git-gitfrok-cert gitfrok-apex-cert --project=$P --quiet
gcloud certificate-manager dns-authorizations delete git-gitfrok-dnsauth gitfrok-apex-dnsauth --project=$P --quiet
gcloud compute addresses delete prod-dp-git-gateway --global --project=$P --quiet
```

Order matters: a map entry holds its certificate, and a map attached to a live target proxy refuses
deletion — so the cluster (step 2) goes first. The step-5 sweep catches the address; **it does not
look at Certificate Manager**, so check that by hand:
`gcloud certificate-manager certificates list --project=gitfrok-prod-dp`.

### 5. Sweep, and only then believe it

Nothing is torn down until this prints zeros. Run for **both** projects — and note the shell:
**this script was wrong until 2026-09-22, and wrong in the direction that reassures.** It used
`gcloud $R list ... 2>/dev/null`; zsh does not word-split an unquoted parameter, so gcloud received
`"compute instances"` as a single argument, exited 2, and `2>/dev/null` turned that into a count of
zero. On a zsh login shell the sweep certified an untouched environment as fully torn down. It was
caught by disbelieving a row — the sweep claimed no instances while the connector VM was plainly
running — which is the habit this section actually depends on:

```sh
for P in gitfrok-prod-cp gitfrok-prod-dp; do
  echo "== $P"
  for R in "container clusters" "compute instances" "compute disks" \
           "compute routers" "compute addresses" "compute forwarding-rules"; do
    # `eval` and NOT `gcloud $R list`: zsh does not word-split an unquoted parameter, so the
    # unevalled form passes "compute instances" as ONE argument and gcloud exits 2 with
    # "Invalid choice". Paired with the 2>/dev/null this section used to carry, that printed a
    # reassuring 0 for every row — a sweep that reports a perfect teardown on a full environment.
    # Errors are surfaced rather than counted, for the same reason.
    out=$(eval gcloud $R list --project="$P" --format="'value(name)'" 2>&1) || {
      printf '%-26s ERROR: %s\n' "$R" "$(printf '%s' "$out" | head -1)"; continue; }
    printf '%-26s %s\n' "$R" "$(printf '%s' "$out" | grep -c .)"
  done
  out=$(gcloud artifacts repositories list --project="$P" --format='value(name)' 2>&1) \
    && printf '%-26s %s\n' "artifacts repositories" "$(printf '%s' "$out" | grep -c .)" \
    || printf '%-26s ERROR: %s\n' "artifacts repositories" "$(printf '%s' "$out" | head -1)"
  gcloud storage buckets list --project=$P --format='value(name)' 2>/dev/null
done
```

### What the 2026-09-23 purge added to this runbook

The second complete teardown, run after the environment had served Git to a real tenant. Three
things it hit that the first did not, each now worth doing on purpose:

- **Take local backups BEFORE step 1, when the clusters hold anything real.** Step 1 deletes the CNPG
  backup buckets and step 3 deletes the volumes, so after them there is no copy. On this run:
  `git bundle create … --all` per repository (verify with `git bundle verify` and compare heads to
  the server), `kubectl exec postgres-1 -- pg_dump -Fc <db>` per database, and validation by piping
  each dump back into `pg_restore -l` inside the pod when no local `pg_restore` exists. Stored under
  `~/.gitfrok/backups/<date>/`, mode 0700.
- **Delete Gateways and `type=LoadBalancer` Services BEFORE the clusters.** The controller then
  removes its own forwarding rules, URL maps, backend services and health checks. Even so, GKE left a
  `k8s-…-node-http-hc` **firewall rule** and two **NEGs** behind, and the firewall rule made
  `prod-cp/network`'s destroy fail with *"network resource … is already being used by … firewalls/k8s-…"*.
  Delete `k8s-*` firewall rules and all NEGs, then re-run destroy for `network` and `project-services`.
- **`modules/backups` has `force_destroy = false`**, so destroy refuses a bucket CNPG has written WAL
  into. Empty it first (`gcloud storage rm -r gs://<bucket>/**`) — which is the moment the last remote
  copy of the database goes, so the local backup above comes first.

**Two false positives in any sweep that adds more resource types:** `gcloud compute images list`
prints Google's ~250 public images (use `--no-standard-images`), and `gcloud artifacts repositories
list` prints a "Listing items under project…" line that `grep -c .` counts as a repository.

## What survives a complete teardown, deliberately

| Thing | Why it stays | Cost |
|---|---|---|
| `gitfrok-prod-cp-tfstate`, `gitfrok-prod-dp-tfstate` | created by `--backend-bootstrap`, never declared by a unit, so no `destroy` targets them | a few KB — nil |
| The VPCs (`prod-cp-vpc`, `prod-dp-vpc`, `default`) | networks and subnets are not billed | nil |
| Both GCP projects | deleting them is a separate, bigger decision | nil once empty |
| The Cloudflare DNS records — `app-`, `auth-`, `agents-`, `git-gitfrok` and `gitfrok`, plus the two `_acme-challenge` CNAMEs | not in this tree at all (ADR-0095 decision 4 put them in a vendor console) | nil, but the A records now point at **released addresses** |

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
- **Everything step 4a deleted**, recreated by hand in the same order reversed: reserve
  `prod-dp-git-gateway`, create both DNS authorizations and put their `_acme-challenge` CNAMEs in
  Cloudflare (DNS-only), create the two certificates and the map, then apply the dataplane overlay.
  The Gateway references the map by name and the address by name, so neither may be renamed.
- **The Cloudflare records**, which must be repointed at the **new** reserved addresses — and
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

Roughly, per month. **The right-hand column is the shape as of 2026-09-22's minimum-cost rebuild;
the left is what the environment cost before it**, and the difference is worth knowing before a
teardown is justified on cost grounds alone.

| | First shape | Now | Killed by |
|---|---|---|---|
| Nodes | 6 × `n2-standard-4` — $600 | 4 × `e2-standard-4` | step 1 or 2 |
| PVC volumes | 550 GB `pd-ssd` — $90 | 390 GB `pd-balanced` | **step 3 only** |
| Cloud NAT | 2 × — $64 | unchanged | step 1 or 4 |
| GKE cluster management | 2 × — $150 | unchanged | step 1 or 2 |
| `e2-micro` connector VMs | 2 × — $14 | unchanged | step 1 |
| Reserved addresses, Artifact Registry, backup buckets | a few $ | unchanged | step 1 |

Roughly **$920/month → $500–600**. The floor matters more than the saving: **cluster management,
NAT and the connector are per-cluster fixed costs**, so no further parameter change moves them. The
only lever left is collapsing the two environments into one — which ADR-0092 considered by name and
rejected, because it collapses ADR-0011's inbound asymmetry. Cost is not a reason to revisit that
without an ADR.

If you are tearing down under time pressure, the order that stops the most spend soonest is:
**clusters (steps 1–2), then disks (step 3), then everything else.**
