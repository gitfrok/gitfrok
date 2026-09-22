# `deploy/k8s` — production workloads (Kustomize)

**Decisions of record: [ADR-0093](../../governance/docs/adr/0093-control-plane-chart.md)
(the control plane gets its own installer), [ADR-0096](../../governance/docs/adr/0096-kustomize-only-installers.md)
(Kustomize, never Helm), [ADR-0099](../../governance/docs/adr/0099-third-party-stateful-set.md)
(the third-party stateful set).** Where this README and an ADR disagree, the ADR wins (ADR-0001).

**Updated 2026-09-22.**

## The line this tree sits on

`../gcp` provisions **infrastructure** with OpenTofu and refuses to provision a workload
(ADR-0092 decision 4). This tree is the other side of that line: everything here is a Kubernetes
object, and nothing here creates a cluster, a network, an address or an IAM binding.

```
controlplane/   the first-party workloads — controlplane-app, bff, webfrontend, Gateway, agent door
platform/       the third-party stateful set — Postgres (CNPG), Valkey, Redpanda, OpenBao, Zitadel
platform/operators/  the CNPG operator, applied once before the platform overlay
```

**Helm is not in this tree's vocabulary** (ADR-0096 decision 1). There is no chart, no release and
no `values.yaml`; an overlay varies hostnames, addresses, replicas and image digests, and never
which workloads exist (SPEC-0067 AC11).

## Two overlays, deliberately asymmetric

| | `prod-cp` | `prod-dp` |
|---|---|---|
| Postgres, Valkey, Redpanda | yes | yes |
| OpenBao | **yes** | no — custody is control-plane-side (ADR-0066) |
| Zitadel | **yes** | no — the OIDC issuer serves the browser surface |
| SeaweedFS | no | yes — ADR-0050 scopes it to data-plane large objects |
| first-party workloads | `controlplane/overlays/prod-cp` | ADR-0013's data-plane installer, not here |

`check-platform-kustomize.sh` and `check-controlplane-kustomize.sh` assert this asymmetry. It is
not an accident of what got written first.

## Reaching the clusters at all

Both Kubernetes API endpoints are **private with no authorized networks** (ADR-0097 decision 1), so
`kubectl` does not work from a laptop by default and the fix is not to add a CIDR. The path is the
`zt-connector` VM in the cluster's node subnet, reached over IAP TCP forwarding:

```sh
gcloud compute start-iap-tunnel prod-cp-zt-connector 22 \
  --local-host-port=localhost:2222 --zone=asia-southeast1-a --project=gitfrok-prod-cp &
ssh -i ~/.ssh/google_compute_engine -p 2222 -D 1080 -N -o StrictHostKeyChecking=no \
  "$USER"@localhost &
HTTPS_PROXY=socks5://localhost:1080 kubectl get nodes
```

The connector **must** stay in the node subnet: GKE grants that subnet's primary range access to a
private endpoint by default, and from anywhere else the control plane times out without naming the
cause. See `../gcp/README.md` for why the tunnel token is a manual seam.

## Bring-up order — the sequencing is load-bearing

```sh
export KUBECTL="kubectl"        # with HTTPS_PROXY set as above

# 1. the CNPG operator, once per cluster, before anything claims a Cluster resource
$KUBECTL apply --server-side -f platform/operators/cloudnative-pg/cnpg-1.27.0.yaml
$KUBECTL -n cnpg-system wait --for=condition=Available deploy/cnpg-controller-manager --timeout=300s

# 2. the third-party stateful set
$KUBECTL apply -k platform/overlays/prod-cp

# 3. OpenBao initialise + quorum unseal — A HUMAN ACT, see below
#    Do not proceed to step 4 until `bao status` reports Sealed: false on all three nodes.

# 4. the first-party workloads
$KUBECTL apply -k controlplane/overlays/prod-cp
```

**Step 3 cannot be automated and must not be.** The OpenBao pods boot sealed and report NotReady —
that is the intended state, not a failed rollout. Unseal is a human quorum act over Shamir shares
(ADR-0066 decision 4). The procedure is [`../MVP-RUNBOOK.md` §6a](../MVP-RUNBOOK.md), which applies
here unchanged except for the namespace (`-n gitfrok`, not `-n default`) and the context.

**The five shares never enter this repo, the cluster, or any environment file.** §6a states it and
means it: writing all five into a Kubernetes Secret so that something can unseal automatically
destroys the exact property the 5-of-3 split exists to create. There is no auto-unseal anywhere in
this deployment, by decision.

**Why step 3 gates step 4:** the control plane composes its agent CA exclusively through custody and
holds no other key (SPEC-0044 AC1/AC3, fitness-asserted in `internal/arch`). Deployed against a
sealed custody service, the agent door cannot sign and enrolment issuance refuses. Cold restarts
have the same ordering constraint, every time.

## What blocks a first real deployment today

Two things, both operator-held. Neither is a code defect and neither is worked around here.

**1. The first-party images are not published.** `controlplane/overlays/prod-cp/kustomization.yaml`
pins `newTag: 0.1.0` against `asia-southeast1-docker.pkg.dev/gitfrok-prod-cp/gitfrok/*`, and nothing
has pushed those tags. `check-controlplane-kustomize.sh` reports AC5 (pin by digest) as **NOT RUN**
with that cause on its own output line rather than passing quietly. To publish, set on the GitHub
repository:

| Variable | Value |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/837367170054/locations/global/workloadIdentityPools/prod-cp-github/providers/github-oidc` |
| `GCP_IMAGE_PUBLISHER_SA` | `prod-cp-image-publisher@gitfrok-prod-cp.iam.gserviceaccount.com` |

plus an `image-publish` environment holding `COSIGN_PRIVATE_KEY`, `COSIGN_PASSWORD` and
`RELEASE_SIGNING_KEY`, then `workflow_dispatch` at `0.1.0`. **The cosign signing key does not exist
yet** — it has to be generated and stored before the first publish, and it is a separate trust chain
from the `.release` manifest signature (ADR-0098). When the workflow runs, each `images:` entry
gains `digest: sha256:...` and drops `newTag`, read from the `.release` manifest the same run signs.

**2. OpenBao is uninitialised and sealed** on the live `prod-cp` cluster — step 3 above, awaiting a
share quorum.

## Live state: nothing is deployed, 2026-09-22

**Both clusters were torn down on 2026-09-22 to stop billing, so there is nothing running to
inspect.** Verified zero across both projects: clusters, nodes, disks, routers, addresses,
forwarding rules and registries. See [`../TEARDOWN-RUNBOOK.md`](../TEARDOWN-RUNBOOK.md) for what
that took and how to rebuild.

What was proven while it was up, and is therefore a property of these manifests rather than a
property of that cluster:

- `platform/overlays/prod-cp` applied and reached **12 pods 1/1** — OpenBao 3/3 (Raft, TLS,
  uninitialised and sealed, as intended), Postgres 3/3 via CNPG reporting healthy, Redpanda 3/3,
  Valkey, Zitadel 2/2 — with `connected as gitfrok_app to gitfrok ssl=on` verified from inside.
- `controlplane/overlays/prod-cp` **dry-ran 13/13 clean** against that live cluster. It was never
  applied, because its images still do not exist.
- `prod-dp`'s platform overlay was never applied.

Three fixes in the base manifests came out of that run and would not have been found by dry-running
(`redpanda-internal` needing `publishNotReadyAddresses: true`, OpenBao's readiness probe dropping
`sealedcode=204`, Zitadel needing `enableServiceLinks: false`), which is the argument for treating
the list above as evidence rather than deleting it along with the cluster.

## Gates

```sh
./scripts/check-platform-kustomize.sh        # 7 fixtures
./scripts/check-controlplane-kustomize.sh    # 10 fixtures
```

Both render the overlays and assert over the **rendered output**, not the source text — an earlier
revision of each grepped the YAML and was tripped by its own explanatory comments. They assert the
prod-cp/prod-dp asymmetry above, that no installer authors a Secret (`secretKeyRef` only), that the
overlay's address names match the `addresses` unit in `../gcp`, and the ADR-0100 route partition.

## What is deliberately absent

**No Secret is authored by any manifest here.** Every credential arrives by `secretKeyRef` against a
Secret an operator created out of band. A `secretGenerator` in an overlay would put plaintext in
git, and the platform gate fails on one.

**`agents-gitfrok.7.solutions` has no Gateway route and must stay DNS-only in Cloudflare.** The agent
pins our CA to verify the *server* certificate, so any TLS-terminating proxy in front of the agent
door is untrusted by every agent and enrolment fails as a TLS error rather than as the topology
mistake it is (ADR-0095 decisions 3–5). Cloudflare defaults new A records to proxied, so the safe
click and the correct click differ here.

**Backup and restore for the stateful set is still open**, as is a staging environment (ADR-0099).
The `addresses` unit reserves the two external addresses this tree consumes **by name**; a rename on
either side fails at GKE programming time with no diff to read.
