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
| first-party workloads | `controlplane/overlays/prod-cp` | `dataplane/overlays/prod-dp` (ADR-0107, Accepted) |
| a public inbound path | the Gateway on `app-`/`auth-gitfrok` | **yes** — the Git door on `gitfrok` and `git-gitfrok` (ADR-0107, ADR-0108) |

`check-platform-kustomize.sh` and `check-controlplane-kustomize.sh` assert this asymmetry. It is
not an accident of what got written first.

**Two rows in that table changed on 2026-09-23 and one of them is a decision, not a fact.** The
data plane now has a first-party overlay *and* a public inbound path, which ADR-0095 decision 11
explicitly left open and ADR-0107 takes up. ADR-0107 was **Accepted on 2026-09-23**, after the
overlay had been live and proven for most of a day — the order is recorded rather than tidied.

**Nothing in `make verify` reads `deploy/k8s/dataplane/`.** Both Kustomize gates are hard-coded to
their own trees, so the newest overlay — the only one that opens a port to the internet — is the
one with no gate. It renders no Secret and states its `storageClassName`, and *nothing checks
either*. That is a filed follow-up on ADR-0107, not a claim that it is fine.

## Reaching the clusters at all

Both Kubernetes API endpoints are **private with no authorized networks** (ADR-0097 decision 1), so
`kubectl` does not work from a laptop by default and the fix is not to add a CIDR. The path is the
`zt-connector` VM in the cluster's node subnet, reached over IAP TCP forwarding:

```sh
gcloud compute ssh prod-cp-zt-connector --zone=asia-southeast1-a --project=gitfrok-prod-cp \
  --tunnel-through-iap --ssh-flag=-D --ssh-flag=1080 --ssh-flag=-N --ssh-flag=-f
gcloud container clusters get-credentials prod-cp-gke --zone=asia-southeast1-a \
  --project=gitfrok-prod-cp --internal-ip
HTTPS_PROXY=socks5://localhost:1080 kubectl get nodes
```

**Use `gcloud compute ssh --tunnel-through-iap`, not `start-iap-tunnel` plus your own `ssh -i`.**
An earlier revision of this section recommended the hand-rolled pair; against a *freshly created*
connector it fails with `Permission denied (publickey)`, because gcloud is what provisions the
key onto the instance, and the backgrounded tunnel process also dies with the shell that started
it. This matters exactly when you need it — right after a rebuild.

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

Two things, both operator-held. A third — the control plane could not trust the custody CA — was
found during the 2026-09-22 rebuild and is now closed; it is kept below rather than deleted,
because a blocker that was real and got fixed is evidence, and the next reader should not have to
rediscover why the CA mount is there.

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
`RELEASE_SIGNING_KEY`, then `workflow_dispatch` at `0.1.0`. When the workflow runs, each `images:`
entry gains `digest: sha256:...` and drops `newTag`, read from the `.release` manifest the same run
signs. Both variables above are non-secret and are `terragrunt output workflow_inputs` from
`../gcp/live/prod-cp/image-publish-identity`; both were re-verified after the 2026-09-22 rebuild.

**On the cosign key, precisely — an earlier revision of this file said it "does not exist yet",
and that is not what the tree shows.** `deploy/dev/trust/image-publish/image-publish-2026-08.pub`
is committed, with fingerprint `547f43d0d7b89a9fc7c12c5c3a4961725b0f42c5cda199e5431393a884533e6f`.
So a keypair *was* generated in August and its public half is the pinned verification key. What is
unknown from the tree is whether anyone still holds the private half. The two cases are different
work and only the owner can tell them apart:

- **The private key is held** → load it as `COSIGN_PRIVATE_KEY`/`COSIGN_PASSWORD` in the
  `image-publish` environment. Nothing else changes; no governance commit.
- **The private key is lost** → this is an **ADR-0044 rotation**, not a fresh generation. Generate
  a new pair, add the new `.pub` *beside* the existing one, let consumers accept both, and remove
  the old file only once nothing is signed by it. That is a governance change and a versioned
  trust-bundle commit, not a secret paste.

**2. OpenBao is uninitialised and sealed** on the live `prod-cp` cluster — step 3 above, awaiting a
share quorum.

**~~3. The control plane cannot trust the custody CA.~~ Closed 2026-09-22** by ADR-0104 (Accepted),
SPEC-0071 (Implemented), T-0089 (`backend@7a8dccd`) and T-0090 (`super-repo@a3d59c3`). The client
takes a CA appended to the system pool and refuses an unusable one at construction; the installer
mounts `openbao-ca`; and `check-controlplane-kustomize.sh` now refuses an `https` custody address
that travels without a mounted CA. The Secret exists on `prod-cp`, created from the CA that signed
the running `openbao-tls` — verified by fingerprint and by `openssl verify` against the serving
certificate, not by assuming the file on disk was the right one. With it in place
`kubectl apply -k controlplane/overlays/prod-cp --dry-run=server` is **13/13 clean** against the live
cluster.

So two blockers remain, not three, and both are operator-held.

**3. The control plane has no way to trust the custody CA, and this blocks step 4 independently of
both of the above.** `openbao-tls` is necessarily signed by a private CA — its SANs are
`openbao-{0,1,2}.openbao-internal`, which no public CA will ever issue for. The custody adapter
(`backend/modules/agent/internal/adapters/custody/openbao.go`) enforces `https` and dials with a
default `http.Client`, so it verifies against the system root pool only: it takes no CA-file option
and `controlplane/overlays/prod-cp` mounts no CA and sets no CA env var. The image is `FROM
scratch` carrying just `/etc/ssl/certs/ca-certificates.crt`, so the private CA is not in that pool
and `apply -k controlplane/overlays/prod-cp` would fail at TLS to custody even with images
published and OpenBao unsealed. **[ADR-0104](../../governance/docs/adr/0104-custody-tls-trust-for-the-control-plane.md) (Accepted
2026-09-22) decides the fix**: an explicit `Config.CAFile` / `GITFROK_CUSTODY_CA_FILE` and an
operator-created `openbao-ca` Secret holding `ca.crt` alone — never `openbao-tls`, which holds the
server's private key — rather than `SSL_CERT_FILE`, which Go uses *instead of* the default root file
and would silently drop the public roots every other TLS destination needs. **Accepted and not yet
built**: decisions 1–2 are a `backend` change and 4/6 are this tree's installer and its gate, each
wanting a SPEC and a task first. So this remains a blocker — but a decided one, with no open question
left in the way.

Note also why no gate caught this: the custody TLS branch has never been taken anywhere. `deploy/dev`
serves custody with `tls_disable = true` over loopback HTTP, and the platform gate's `loopback-http`
fixture correctly refuses that relaxation reaching production — so both doors are shut at once.

## Live state: both clusters torn down again, 2026-09-22 (after the second build)

**Built, and stripped to zero the same day.** Both GKE clusters were deleted on 2026-09-22 after the
second build, and then everything they left behind was swept: 23 orphaned PVC disks, both
`zt-connector` VMs, both Cloud NAT routers, both reserved addresses, the (empty) Artifact Registry
repository and both backup buckets. The three Cloudflare records were deleted too, rather than left
resolving to addresses that now belong to someone else. **Nothing below is running** — read the table
as what the second build reached and proved, not as what exists. `deploy/TEARDOWN-RUNBOOK.md` has the
sweep and the rebuild.

What the second build proved, and is therefore a property of these manifests rather than of that
cluster: `deploy/gcp` applied **15/15 units** across both projects, both platform overlays converged,
and the control-plane overlay dry-ran **13/13 clean** with the ADR-0104 CA mount in place.

| | `prod-cp` | `prod-dp` |
|---|---|---|
| GKE, private endpoint | 3 nodes Ready | 3 nodes Ready |
| Platform overlay | applied — 12 pods | applied — 7 pods |
| OpenBao | 3/3 Running, **uninitialised and sealed** | n/a |
| Postgres (CNPG) | 3/3, `ContinuousArchiving=True` | 3/3, `ContinuousArchiving=True` |
| Redpanda / Valkey / SeaweedFS | 3/3, 1/1, n/a | 3/3, n/a, 1/1 |
| Zitadel | 2/2 Running | n/a |
| First-party workloads | applied — `bff` 1/1, `webfrontend` 1/1, `controlplane` **0/1 CrashLoopBackOff** (sealed barrier) | applied — `dataplane` 1/1, `git-storaged` 1/1 |
| Public surface | `app-`/`auth-gitfrok`, **Let's Encrypt at the origin** | **`gitfrok`** and **`git-gitfrok`**, Google-managed certs (ADR-0107/0108) |
| Tenants | — | `7solutions` (`welcome.git`); `dev` (`hello.git`, a bring-up proof) |
| Out-of-band Secrets | all 9 present, incl. `openbao-ca` | 5 present (`postgres-*`, `gitfrok-database`, `gitfrok-pat-verifier`, `gitfrok-seaweedfs-s3`) |
| App database | 21 tables, 7 schemas | 21 tables, 7 schemas |

**Updated 2026-09-23.** The two rows above that said "not applied" and "not applicable until
T-0085" were true when written and false by the time anyone read them, which is the failure mode a
status table has. What changed: all five images are published, `deploy/k8s/dataplane/` exists
(ADR-0107, Accepted), and `git clone` / `git push` work from the public internet.

**The application databases had ZERO tables until 2026-09-23 — on BOTH clusters.** None of the
twelve backend migrations had ever been applied to production. Nothing reported it, because nothing
looks: the control plane fails earlier on the sealed barrier, and `policy.Decide` **fails closed**
on a missing `policy.decision_records`, so the symptom would have been every protected action
denied rather than anything naming a database. Applying them is still a manual step that no
installer, gate or runbook section owns.

`connected as gitfrok_app to gitfrok ssl=on` verified from inside prod-cp, as on the first build.

**Three defects were found by running this, and none of them could have been found by rendering
it.** Each is fixed in the tree and verified against the live clusters:

- **The Zero Trust connector had never worked, on any boot, since the module was written.** An
  OpenTofu heredoc escapes `${` as `$${` and nothing else, so the script's `$$(`, `$$*` and `$$VAR`
  rendered literally and `google-startup-scripts` exited 2 every time. `cloudflared` was therefore
  never installed and no tunnel ever existed. It went unseen because the operator path below is IAP
  + `ssh -D`, which reaches the connector's sshd and never uses the tunnel. Both tunnels now report
  healthy with 4 connections.
- **SeaweedFS could not start.** Its entrypoint chowns `/data` and `su-exec`s to uid 1000, which
  needs a capability `drop: ["ALL"]` removes. It was the only workload here without a pod-level
  `securityContext`, which is exactly the manifest that had never been applied — `prod-dp`'s
  overlay had never run.
- **CNPG had never archived a WAL**, while reporting `Ready=True` throughout, because archiving is
  a status condition and not a probe. Two independent causes: the `postgres` service account
  carried no Workload Identity annotation, so `gkeEnvironment: true` had no identity to be; and
  `roles/storage.objectAdmin` does not carry `storage.buckets.get`, which is
  `barman-cloud-check-wal-archive`'s first call.

**The operator path, corrected.** Use `gcloud compute ssh --tunnel-through-iap`, not a hand-rolled
`start-iap-tunnel` plus `ssh -i ~/.ssh/google_compute_engine`: on a freshly created connector the
hand-rolled form fails `Permission denied (publickey)`, because gcloud is what provisions the key.

```sh
gcloud compute ssh prod-cp-zt-connector --zone=asia-southeast1-a --project=gitfrok-prod-cp \
  --tunnel-through-iap --ssh-flag=-D --ssh-flag=1080 --ssh-flag=-N --ssh-flag=-f
gcloud container clusters get-credentials prod-cp-gke --zone=asia-southeast1-a \
  --project=gitfrok-prod-cp --internal-ip
HTTPS_PROXY=socks5://localhost:1080 kubectl get nodes
```
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

**No Secret is authored by any manifest here.** Every credential arrives by `secretKeyRef` or a
volume against a Secret an operator created out of band. A `secretGenerator` in an overlay would put
plaintext in git, and the platform gate fails on one.

The nine an operator creates, and which overlay consumes each:

| Secret | Keys | Consumed by |
|---|---|---|
| `postgres-superuser` | `username`, `password` | platform, both overlays (CNPG) |
| `postgres-app` | `username`, `password` | platform, both overlays (CNPG) |
| `zitadel-masterkey` | `masterkey` | platform, `prod-cp` |
| `zitadel-postgres` | `password` | platform, `prod-cp` |
| `zitadel-admin` | `username`, `password` | platform, `prod-cp` |
| `openbao-tls` | `tls.crt`, `tls.key`, `ca.crt` | platform, `prod-cp` — the custody **server**'s key |
| `gitfrok-database` | `url` | controlplane, `prod-cp` |
| `gitfrok-pat-verifier` | `key` | controlplane, `prod-cp` |
| **`openbao-ca`** | `ca.crt` | controlplane, `prod-cp` (ADR-0104, SPEC-0071) |
| `gitfrok-database` | `url` | dataplane, `prod-dp` — a **different** role password from prod-cp's |
| `gitfrok-pat-verifier` | `key` | dataplane, `prod-dp` — base64 of **at least 32 decoded bytes**, or the Git front door refuses to start |
| `gitfrok-seaweedfs-s3` | `access-key`, `secret-key` | dataplane, `prod-dp` — all five S3 settings or none |

**`openbao-ca` is the only one of the nine that is not secret** — it is a CA certificate, a public
verification input. It is called out because both mistakes cost something: handling it as a secret
makes rotation harder than it is, and reading "one of these is public" as "these are roughly public"
is how the other eight get mishandled.

It is deliberately **not** `openbao-tls`, which carries `tls.key`. That Secret also contains a usable
`ca.crt`, so mounting it into the control plane would *work* — which is why
`check-controlplane-kustomize.sh` refuses it by name rather than relying on convention. Create it
from the CA that signed the running `openbao-tls`:

```sh
kubectl -n gitfrok create secret generic openbao-ca --from-file=ca.crt=<path-to-ca.crt>
```

**`agents-gitfrok.7.solutions` has no Gateway route and must stay DNS-only in Cloudflare.** The agent
pins our CA to verify the *server* certificate, so any TLS-terminating proxy in front of the agent
door is untrusted by every agent and enrolment fails as a TLS error rather than as the topology
mistake it is (ADR-0095 decisions 3–5). Cloudflare defaults new A records to proxied, so the safe
click and the correct click differ here.

**Backup and restore for the stateful set is still open**, as is a staging environment (ADR-0099).
The `addresses` unit reserves the two external addresses this tree consumes **by name**; a rename on
either side fails at GKE programming time with no diff to read.

## Using the Git host (`gitfrok.7.solutions`)

**Give tenants `gitfrok.7.solutions`** (ADR-0108). `git-gitfrok.7.solutions` is the same door and stays
valid; both names reach the same Gateway, route and backend. The first tenant is `7solutions`, with
`welcome.git`.

Live since 2026-09-23. `git clone` and `git push` both work from the public internet with a
browser-trusted certificate; the three steps below are what the journey actually needs, and the
first two surprise people.

**1. The repository must already exist as a bare repo.** `git-storaged` serves only repositories
that are already on disk — the `git/v1` contract has **no create-repository RPC**, so a push to a
name nobody created fails rather than creating it. Until a tenant-facing create path exists, that is
an operator action:

```sh
kubectl -n gitfrok exec deploy/git-storaged -- sh -c \
  'mkdir -p /var/lib/gitfrok/repositories/<tenant>/<repo>.git &&
   cd /var/lib/gitfrok/repositories/<tenant>/<repo>.git && git init -q --bare -b main'
```

**2. The password is a PAT, and the identity door is not public.** HTTP Basic carries the PAT as the
password (any username; `admin` by convention). The door that mints one listens on `dataplane:9090`
inside the cluster and is deliberately not published, so it is reached over a port-forward:

```sh
kubectl -n gitfrok port-forward svc/dataplane 19090:9090 &
grpcurl -plaintext -import-path governance/contracts -proto proto/identity/v1/identity.proto \
  -d '{"tenant_id":"<tenant>","actor_id":"<actor>","label":"laptop",
       "scope_labels":["repo.read","repo.write"],"roles":["owner"]}' \
  127.0.0.1:19090 gitsaas.identity.v1.CredentialAuthenticator.IssuePAT
```

The plaintext token exists in exactly that one response and is never readable again.

**3. The URL carries a literal `/git/` prefix.** Not decoration — `internal/gitfrontdoor/http.go`
matches on it, and the published `HTTPRoute` only exposes that prefix:

```sh
git clone https://admin:$PAT@gitfrok.7.solutions/git/<tenant>/<repo>.git
```

### One thing about this door that is wrong

**The repository volume violates ADR-0106 decision 4.** That Accepted ADR says the git tier "must
declare its own `premium-rwo` claim"; `git-storaged-repositories` was shipped as `standard-rwo`.
`storageClassName` is immutable on a PVC, so the fix is a migration — copy the bare repos out,
recreate the claim as `premium-rwo`, copy them back — during which Git is down. Not done; recorded in
T-0092.

### Three things about this door that are decisions

- **DNS-only in Cloudflare, and it must stay that way.** A `git push` is one request whose body is
  the whole pack; the Cloudflare proxy caps request bodies, so proxying this record works for every
  small push and fails on the first large one. `agents-gitfrok` is DNS-only for a different reason
  (ADR-0095 decision 5) and `app-`/`auth-gitfrok` are proxied — the three are not interchangeable.
- **TLS is a Google-managed certificate**, attached by the `networking.gke.io/certmap` annotation,
  not cert-manager. Renewal depends on the `_acme-challenge.gitfrok` and `_acme-challenge.git-gitfrok`
  **CNAMEs** in Cloudflare.
  Deleting that record breaks renewal months later and silently.
- **No SSH.** `GITFROK_GIT_SSH_ADDR` exists in the binary and is set in zero deployments. An L7
  Gateway cannot carry SSH; ADR-0107 decision 7 records why that is a separate decision rather than
  a missing line.
