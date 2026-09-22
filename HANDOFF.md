# Handoff — start here

One page for an incoming session or a new agent. **`governance/` is the Source of Truth (ADR-0001);**
where this file disagrees with it, governance is right and this file is stale. This file says *where
work stands and how to run it*; governance says *what and why*. Verified against the tree on
**2026-09-22**.

## Navigate

| You want | Read |
|---|---|
| the rules before editing anything | `AGENTS.md` (this repo) → `governance/AGENTS.md` → `governance/docs/agents/invariants.md` |
| what the product must do | `governance/docs/product/PRD.md` (`PR-#` rows, phases, non-goals) |
| why it is built this way | `governance/docs/adr/` — index in its `README.md` — ADR-0000 through ADR-0108 |
| a task to pick up | `governance/docs/tasks/` — one file each, own `Status:` and `Repo(s):` |
| what is actually done | `governance/docs/backlog/README.md` — the epic tables are more current than the task files |
| phase intent and exit criteria | `governance/docs/roadmap/README.md`, `governance/docs/plans/` |
| how work is executed | `governance/docs/process/agdd.md`, `agentic-sdlc.md`, `definition-of-done.md`, `ci-gates.md` |
| how the UI must look and behave | **ADR-0091** → **SPEC-0066** (the token source) → SPEC-0047 (the CVD laws, still binding) → ADR-0079/SPEC-0060 (the shell and the type scale) |
| how a token gets changed | `webfrontend/design/README.md` — edit `tokens.json`, `npm run tokens`, commit both |
| the brand kit the CVD laws come from | `webfrontend/design/gitfrok-brand-identity-v2.md` — §2 states the three laws |
| to run the dev cluster | [`deploy/MVP-RUNBOOK.md`](deploy/MVP-RUNBOOK.md) — ordered steps |
| to deploy to **production** (GKE) | [`deploy/k8s/README.md`](deploy/k8s/README.md) — the bring-up order, and why unseal gates it |
| to **use** the Git host (create a repo, issue a PAT, clone) | [`deploy/k8s/README.md`](deploy/k8s/README.md) § *Using the Git host* |
| what the first deployment still owes | `governance/docs/tasks/T-0092-the-debt-the-first-deployment-took-on.md` |
| what production **infrastructure** exists | [`deploy/gcp/README.md`](deploy/gcp/README.md) — OpenTofu units and their manual seams |
| to tear production down, or rebuild it | [`deploy/TEARDOWN-RUNBOOK.md`](deploy/TEARDOWN-RUNBOOK.md) — including the orphaned disks a destroy leaves behind |
| per-manifest detail and the defect record | [`deploy/dev/README.md`](deploy/dev/README.md) |
| what a review already found | `phase-2-code-review.md`, `-wave2.md`, `phase-3-code-review.md`, `phase-3.1-code-review.md`, `phase-3.1-plan-review.md` (this repo's root) |

## Current pins

Verified with `git submodule status` at super-repo **`c94058b`**:
**governance `8085a46`** · **backend `7a8dccd`** · **bff `3c02149`** · **webfrontend `f4d1612`**.

**Check what is unpushed before trusting these pins elsewhere:** `git status -sb` here and in
`governance/`. On 2026-09-23 both were well ahead of `origin/main`. Push governance first, then the
super-repo, or the pins reference commits nobody else has. (A count written into this file is wrong
by the next commit, so none is given.)

**The image claim changed again.** `asia-southeast1-docker.pkg.dev/gitfrok-prod-cp/gitfrok` now holds
all five first-party images at `0.1.0` — `bff`, `controlplane-app`, `webfrontend`, `dataplane-app`,
`git-storaged` — and production runs them. **They were built with podman and pushed by hand, not by
the `image-publish` workflow**, so they are unsigned, have no `.release` manifest, are pinned by tag
rather than digest, and have burned `0.1.0` under the registry's `immutableTags`. T-0092 item 3.
`operator-app` is not published at all.

## Production on GCP — purged to $0 (2026-09-23), after it had served Git

> **Read ADR-0109 before touching production.** The owner's verdict on letting an AI agent deploy
> this project: *"you are worthless and liar to trust you to deploy on prodcution that improbable
> and waste money with a lame and useless projects."* Agents no longer deploy to, change, or tear
> down production; they prepare, and a human runs it. ADR-0109 lists the twelve things the agent got
> wrong on 2026-09-22/23. Everything this section calls "proven" was proven by that agent — under
> ADR-0109 decision 2 it is a pointer to what to check, not a result to rely on.

**Nothing is running and nothing bills.** On the owner's instruction ("purge everything to $0 on
productions") both clusters and everything billable in `gitfrok-prod-cp` and `gitfrok-prod-dp` were
destroyed on 2026-09-23, and the seven `*gitfrok*` Cloudflare records were deleted rather than left
resolving to released addresses. Verified by sweep: zero clusters, instances, disks, snapshots,
addresses, routers, load-balancer parts, certificates, registries and secrets. **What remains is free:**
the two projects (kept, not deleted — a deleted project's ID can never be reused, and
`gitfrok-prod-cp` is hard-coded throughout the tree, registry path included), their default VPC
firewall rules, and the two `*-tfstate` buckets (1.4 KB and 0.9 KB, empty state).

**The data exists only on the operator's laptop now**, in `~/.gitfrok/backups/2026-09-23/` (0700):
`git bundle`s of `7solutions/welcome.git` and `dev/hello.git` (heads verified against the server),
`pg_dump -Fc` of prod-cp `gitfrok` and `zitadel` and prod-dp `gitfrok` (validated with the server's
`pg_restore -l`: 21, 141 and 21 table-data entries; the `7solutions` tenant row is in the prod-dp
dump), and the deleted Cloudflare records as JSON. Nothing else holds a copy — the CNPG backup buckets
and every snapshot were deleted to reach $0.

**Everything below is what was PROVEN while it was up.** It is a property of the tree, not of those
clusters, which is why it is kept: a rebuild from this tree should reach the same state, and where it
does not, that is a regression.

| proven 2026-09-23, before the purge | |
|---|---|
| **Git hosting** | `https://gitfrok.7.solutions/git/<tenant>/<repo>.git` (ADR-0108) — `git clone` and `git push` from the public internet; `git-gitfrok.7.solutions` was the same door (ADR-0107). Tenant isolation proven: a `7solutions` PAT was refused by tenant `dev` |
| **TLS** | browser-trusted everywhere: Let's Encrypt at the origin for `app-`/`auth-gitfrok` via cert-manager; Google-managed for the two Git names |
| **Installers** | `deploy/k8s/{platform,controlplane,dataplane}` applied with `kubectl diff` empty against the live clusters; `make verify` exit 0 |
| **Storage** | the git tier on `premium-rwo` per ADR-0106 decision 4, migrated live with refs and `fsck` verified |
| **Databases** | all twelve backend migrations applied on both clusters — a manual step no installer owns (T-0092 item 4) |

**Using it, once rebuilt,** is three operator steps — create the bare repo, issue a PAT over a port-forward, clone
with the `/git/` prefix. `deploy/k8s/README.md` § *Using the Git host* has the exact commands.
**"Ready to use" is true for an operator, not for a tenant:** there is no self-service repo creation
or credential issuance yet (T-0092 item 7).

**What would still block a complete product after a rebuild**, in order of how badly:

1. **OpenBao is uninitialised and sealed**, so the control plane cannot start. The ceremony is one
   command, `scripts/openbao-operator.sh all <shares-file>`, and **only a share-holder runs it, in
   their own terminal** — never through an agent session or a `!` prefix, because the five Shamir
   shares would land in a transcript (ADR-0066 decision 4). Its `unseal`/`wire` paths have never run.
2. **Nobody can log in.** Two independent causes (T-0092 item 8): Zitadel redirects every authorize
   to `/ui/v2/login/login` and no Login V2 service is deployed; and `controlplane-app` never
   registers `OIDCLogin`, so the control plane's BFF cannot complete a login regardless.
3. **A PAT dies on every data-plane restart.** `cmd/dataplane-app` composes `identity.NewInMemory`
   unconditionally; `identity.NewPostgres` exists and nothing calls it (T-0092 item 2).
4. **Every OpenBao restart re-seals** — Shamir + Raft, no auto-unseal. On a zonal autoscaling pool
   that is every node upgrade (T-0092 item 6; an ADR-0066 decision, the owner's).
5. ~~**The git-storaged volume violates ADR-0106 decision 4.**~~ **Fixed 2026-09-23** — migrated to
   `git-storaged-data` (`premium-rwo`), refs and `fsck` verified, old disk snapshotted then deleted
   (T-0092 item 12). **PR-6 is still unmet:** one storage node, no synchronous replica.

**Infrastructure that had to be created outside OpenTofu** — and must be again on a rebuild, by hand,
until T-0092 item 11 is fixed (`deploy/TEARDOWN-RUNBOOK.md` lists both directions): the `prod-dp-git-gateway` global address, the Certificate Manager DNS authorizations,
certificates and map (`gitfrok-dp-certmap`), and the Cloudflare records for `git-gitfrok`,
`gitfrok`, and their two `_acme-challenge` CNAMEs. A `tofu destroy` will not remove them and a
rebuild will not recreate them.

Decisions made for production that were not in the Phase story: **ADR-0092** (GCP + OpenTofu),
**0093** (control plane gets its own installer), **0095** (Cloudflare-authoritative DNS, and why the
agent door can never be proxied), **0096** (Kustomize only, no Helm), **0097** (private API
endpoints reached through Zero Trust), **0098** (Artifact Registry, `docker.io` retired), **0099**
(the third-party stateful set), **0100/0101** (which plane serves and owns what), **0104/0105**,
**0106** (cost is the binding constraint), **0107** (the data plane publishes the Git door) and
**0108** (`gitfrok.7.solutions` is its tenant-facing name) and **0109** (agents do not deploy to production) — all Accepted. **0102/0103** are still
**Proposed**.

## Where work stands (2026-08-23)

**Phases 0, 1, 2 complete. Phase 3 (BYO) implementation-complete** with its fifth exit criterion
carried, not met: the install → self-register → upgrade → meter path has never run on a real
customer-shaped cluster, and every real-cluster row of `deploy/conformance/byo-dataplane.md` reads
"not run". **Phase 3.1 implementation-complete**, one task blocked (T-0042, below). **Phase 3.5 (the
design system) complete.**

**Phase 4 (the full product surface) is complete across all three tiers.** ADR-0070 is **Accepted**
and the PRD carries PR-24…PR-32. Tier A (EP-25), Tier B (EP-26), Tier C (EP-27) and EP-28 (the design
layer) are all closed. **All four Tier C ADRs are now Accepted** — ADR-0074 issues, ADR-0075
releases, ADR-0076 repository settings, ADR-0077 admin area — as are ADR-0078 (marketing surface
separation), ADR-0072 (CI job logs deferred) and ADR-0073 (tenant policy authoring deferred). An
older version of this file called four of them Proposed; that is no longer true.

**Three epics landed after Phase 4:**

- **EP-29 durability debt** (Done 2026-08-21) — the Code Review context survives a restart.
  SPEC-0061 AC1–AC18, 16 real-Postgres proofs with `-race` and zero skips. ADR-0080, ADR-0084.
- **EP-30 the review loop, completed** (Done 2026-08-21) — the four-eyes floor (ADR-0085), draft
  merge requests (ADR-0087), merge strategies and trunk-based landing (ADR-0088). SPEC-0062/0064/0065.
- **EP-31 notifications** (Done 2026-08-21) — bell, list and mark-read end to end (ADR-0086). Email
  and webhooks are named follow-ups needing their own decisions.

### What landed on 2026-08-22/23 (this session)

**The Go floor is 1.27** — **ADR-0089**, superseding ADR-0023. `go.mod` in both modules,
`.tool-versions` everywhere, all five Docker build stages on `golang:1.27.0-alpine3.23`, and
`scripts/check-version-floors.sh`. Two consequences are recorded in the ADR because neither was
obvious:

- **The builder base had to move with the floor.** Alpine 3.22 publishes no Go 1.27 image.
- **The floor is an input to generated code.** `protoc-gen-go` stayed pinned at v1.35.2, but 1.27's
  `go/format` stopped emitting a blank comment separator, so the pinned *plugin* version was never
  enough to make generated bytes reproducible. **If you regenerate protobuf code, build the plugins
  with the floor toolchain** (`GOTOOLCHAIN=go1.27.0 go install …@v1.35.2`) or you will see the diff
  in reverse and read it as drift.

**`git-storaged` ships on a git that can rebase** — **ADR-0090**. The runtime base moved
`alpine:3.22.2` → `alpine:3.24.1` (git 2.49.1 → 2.54.0), because 2.49 and 2.52 both **reject** the
`--ref`/`--ref-action` flags the rebase landing depends on. Every rebase and trunk-fallback landing
had been refusing on the published image. The build now proves the capability rather than git's
presence, and the base pin finally has the floor and gate ADR-0048 decision 4 asked for
(`GIT_STORAGED_BASE_IMAGE` in `versions.env`, asserted by `check-dev-images.sh`).

**Verified live on the dev cluster:** a real `MergeRef` with a REBASE plan returned
`LANDING_SHAPE_REBASE`, moved the ref, produced a linear two-commit first-parent chain, preserved the
author (`GitFrok Dev`) and set the committer to the service (`gitfrok-landing`). First time that path
has ever worked on a deployed image.

**`landRebase` now reports which failure happened.** It used to map every non-zero `git replay` exit
to `merge_conflict`, so a missing committer identity and an unsupported git both read as "your
branches disagree". Exit 1 is a conflict, anything else is operational, and the replay capability is
**probed** rather than inferred from a version — which makes SPEC-0065's `rebase_path_unproven`
reachable for the first time. Two production defects were behind that mask: the rebase path set no
committer identity at all, and the version check tested the wrong thing.

**The design system's source moved** — **ADR-0091** (superseding ADR-0069), **SPEC-0066**, **T-0083**.
`webfrontend/design/tokens.json` is now the source for all 87 tokens; `src/styles/tokens.css` is
**generated** from it. The measurement that made this safe: the kit and the governed layer already
agreed on every value they both named, so the first landing was a provable no-op — all three token
scopes reproduce identically, and a no-loss check confirms 0 substantive lines of the 590-line
original went missing.

## How to run it

**Host prerequisites (this machine):** minikube (profile `gitfrok`) + podman machine running;
`mkcert -install` done; `/etc/hosts` six-host line (`hello/zitadel/s3/filer/app/git.gitsaas.test →
127.0.0.1`); `grpcurl` installed; **`helm` present (v4.2.4)** — the byo-chart *rendered* assertions
run. Say which of those you actually had when you report a green run.

**Daily loop (all idempotent):**

| Target | Does |
|---|---|
| `make bootstrap` | clone/sync submodules |
| `make dev-up` | converge the cluster; **hard-fails if OpenBao is sealed** |
| `make dev-provision` | DB migrations + Zitadel OIDC client + role vocabulary + login roundtrip |
| `make dev-smoke` | deployments up, 200 over real TLS at `*.gitsaas.test` |
| `make dev-north-star` | the full nine-step journey proof |
| `make verify` | the super-repo fitness gates |
| `make codegen-check` | every consumer's `gen/` still follows the pinned contracts |
| `make tokens-check` | **new** — `tokens.css` follows `tokens.json`, and every status colour has a glyph |
| `cd webfrontend && npm run tokens` | regenerate `tokens.css` after editing `design/tokens.json` |
| `cd webfrontend && npm run cvd` | regenerate the 15 CVD capture artifacts (SPEC-0047 AC10) |

**Redeploying a first-party image to dev.** Dev images are **not pulled from the registry** —
`dev-up.sh` builds them into the node, and `build_if_absent` **skips when the tag already exists**, so
`make dev-up` will not pick up a rebuild. Do this instead:

```bash
set -a; . ./deploy/dev/versions.env; set +a
minikube image build -p gitfrok -t "$GIT_STORAGED_IMAGE" -f Dockerfile.gitstoraged backend
kubectl rollout restart deploy/git-storaged
```

The Dockerfile path is **relative to the build context** — minikube 1.38 flattens the context, so
`backend/Dockerfile.x` resolves to nothing on the node. `imagePullPolicy` is `IfNotPresent`, so the
node's local image wins.

**Cold-restart ritual:** OpenBao quorum unseal per MVP-RUNBOOK §6a — the Shamir shares are
operator-held, 3 of 5. **Never automate the unseal and never re-initialize** (initialize is once per
cluster, ever). Unseal must precede any consumer start. `dev-up.sh` refuses to unseal on purpose and
says so.

**Dev identities:** `admin@gitsaas.test` (Zitadel, owner on the dev tenant) · operator PAT in secret
`gitfrok-operator-pat` · enrolment token in secret `gitfrok-enrolment-token`.

**Gate matrix before you push:**

- **backend:** gofmt/vet/build/arch + `go test ./...` (99 packages) + the real-Postgres `-race`
  harness (port-forward 15432).
- **governance:** `governance/scripts/check-docs.sh`, contracts and policies checks.
- **webfrontend:** `npm run check` (tsc) && `npm test` (**601 cases, 48 files**) && `npm run build`.
  The build is gated by `prebuild`: the token freshness and CVD gates, the hex-literal check, and the
  pinned suites. **`usage-regression-pins` and `readonly-cause` must pass UNMODIFIED** — editing one
  to make a change pass means the change moved behaviour.
- **super-repo:** `make verify` && `make codegen-check` && `make tokens-check` && `make surfaces-check`.

**`make verify` does NOT run `policy-check`.** It is a separate target and a separate CI step. Running
`make verify` green is not evidence the authorization path is green — see the lesson at the bottom.

## Governance rules that bind every agent

Condensed from `AGENTS.md` — read it before editing anything.

- **Deploy and test on minikube + podman + mkcert ONLY** (owner rule, 2026-09-23): TDD, unit, e2e and
  SIT all run on `MINIKUBE_DRIVER=podman make dev-up`. **Never deploy to production, and never ask or
  offer to**, until the owner grants permission unprompted (ADR-0109).

- **Governance is SoT.** Decisions, contracts, policies and shared surface live only in `governance/`
  (invariants 21–25). New decision → **Proposed ADR and stop**; new behaviour → spec first; API
  change → governance PR first, additive only.
- **One commit never spans two submodules.** Work lands in the submodule's own repo; the super-repo
  stores **pins only** (invariant 25), bumped in its own commit after the submodule commit is on its
  `main`. **Push submodules before the super-repo**, or the pins reference commits nobody else has.
- Dependency direction is one-way: `webfrontend → bff → backend → governance`. webfrontend never
  calls backend; bff holds no business logic.
- **Honest "not run" annotations.** A row that says "not run" is worth more than a row that implies it
  passed. **Write the limit down** against the spec it bounds.
- Accepted ADRs are immutable (supersede, never edit); approved specs may be amended with the
  amendment noted in `Status:`. A **factual correction** to an Accepted ADR is stated in place with
  its date and what was wrong — ADR-0091 carries one.
- **Work lands directly on `main`** (ADR-0053, ADR-0054) — no PR gate; run the local gates first. A
  red `main` is stop-everything: the next commit fixes or reverts it.
- **Image publishes are gated on a human.** The `Publish … image` runs sit in GitHub Actions status
  `waiting` on the `image-publish` environment, reviewer-approved, `wait_timer: 0` — they never
  release on their own. Approve with
  `gh api --method POST repos/gitfrok/<repo>/actions/runs/<id>/pending_deployments -f state=approved -F 'environment_ids[]=<env>'`.
  The response shape is not an object, so a `--jq '.[]|{…}'` filter errors even when the POST
  succeeded: verify by re-reading the run, not by the filter's output.

## Open items / carried limits (never silent)

1. **OpenBao is sealed on the dev cluster right now**, so `controlplane` is in `CrashLoopBackOff`
   (574+ restarts) and **`make dev-smoke` is red on that one deployment**. Everything else passes.
   It needs the §6a ceremony with 3 of 5 shares; no code can fix it.
2. **T-0042 multi-cloud conformance is blocked** on T-0003's cluster lane — no code can unblock it.
   With it wait SPEC-0045 AC3 and SPEC-0039 AC8's migration proof on real state.
3. **`landRebase` still has two open follow-ups for SPEC-0065's owner**, both recorded in its commit:
   a replay failure that is neither a conflict nor an unsupported git gets the coarse operational
   answer, and three tests assert a *successful* rebase so they fail on a host whose git lacks the
   flags (CI's git supports them; no skips were added).
4. **`--gf-font-display` (`'Baloo 2'`) is unresolved** — the token exists and the comp's CDN import
   supplied the face, but ADR-0069 decision 5 (carried forward by ADR-0091) requires self-hosted
   WOFF2. Vendor the WOFF2 or retire the token. SPEC-0066 AC6 only forbids the CDN reference.
5. **The release-trust door is unmounted in dev** (no dev-safe seed path, MVP-RUNBOOK §6b). The
   controlplane log says so on every start.
6. **Usage dimensions show gap states** until dataplane telemetry emission is wired.
7. `GITFROK_CLOUD=gke` is **annotated dev fiction**; real-cluster proof is T-0042's.
8. **Backend integration tests skip without `TEST_DATABASE_URL`** — and the ones that skip are the
    cross-tenant isolation proofs. **Count the skips**; a green summary with six skips reads
    identically to one without.
9. **Dependabot advisories are open** on the bff and webfrontend default branches — pre-existing.
10. **One-node limits stay "no" on this cluster:** failover, CI gVisor RuntimeClass under rootless
    podman, durability quorum — all need the cluster lane.
11. Proxy-only egress is unsolved (ADR-0017 follow-up) and can block a sale outright.
12. The dataplane gRPC door is unauthenticated (Phase-2 limit (d)): tenant/actor/roles come off the
    wire; mitigation is network isolation + RLS.
13. Phase-2 in-process state does not survive a restart (attribution projection, pack assembly,
    code-search index; the index also has no cap — limit (e)).
14. Two sources of schema truth: `deploy/dev/postgres.yaml`'s ConfigMap vs `backend/` migrations —
    they agree; nothing enforces it.
15. Per-consumer codegen gating is impossible while each `buf.gen.yaml` reads
    `../governance/contracts` — freshness is gated at the super-repo pin bump.
16. First-party images in `deploy/dev` are pinned by tag, not digest (ADR-0035 decision 4).
17. Host DNS for `*.gitsaas.test` needs root, so `dev-up.sh` prints the snippet rather than applying it.
18. `git/v1` has no create-repository RPC — bare repos come back via RUNBOOK §8a's kubectl-exec recovery.
    **In production this is how every repository is created**, not a recovery step (T-0092 item 7).
19. **The CVD captures run against the stub BFF, not a cluster** — deliberately: the fixtures are
    state-dense in a way live data on a given day is not. They prove the ENCODINGS survive grayscale
    and deuteranopia; they are not a live walk, and the artifacts are gitignored.
20. **Deepfreeze (dark) ships tokenized but unreachable** — no user-facing toggle, by ADR-0069 open
    decision 3, carried forward. Both themes come from one source so they cannot drift.
21. **PR-32 (marketing) is blocked on a decision this repository cannot make** — ADR-0078 requires
    its own repository on its own origin. If nobody will own one, **withdraw PR-32 from the PRD**;
    an open requirement nobody can start reads as planned work.
22. **PR-26's job logs and PR-27's policy authoring are deliberately undelivered** — ADR-0072 and
    ADR-0073, both Accepted. Held by `check-contracts.sh` **check 13** (no job-output field on
    `CIJob`) and **check 14** (no authoring verb on `PolicyDecisionPoint`), each with a fixture
    proving it can fail. If you are about to add "just a log URL", the gate is stopping you on purpose.

## The storage picture, in one place

- **Live bare repositories: block volumes** (ADR-0033). `git-storaged` refuses a FUSE repository root
  outright (invariant 7).
- **LFS, CI artifacts, image blobs: ADR-0050** puts them on a SeaweedFS FUSE mount from ADR-0051's
  privileged DaemonSet. That mount **does not propagate on this driver**, so dev runs the S3 adapter
  ADR-0050 decision 6 keeps for the case. Measured, not assumed — `deploy/dev/README.md`.
- **Transfers proxy through the plane** under `repo.lfs.read`/`repo.lfs.write`, every read verified
  against the digest in the object's name (SPEC-0023, amended by ADR-0050).
- **Browser sessions: Valkey** (ADR-0049), opened by the BFF under the one datastore waiver ADR-0052
  grants. Every other cache or database client in the BFF still fails its boundary gate.
- **The registry, not the disk, is the truth for existence** (ADR-0071): a bare repository with no
  registry row is absent from every product surface by consequence, not defect.

## What the design layer decides for you

- **`design/tokens.json` is the source; `src/styles/tokens.css` is generated** (ADR-0091, SPEC-0066).
  Edit the JSON, run `npm run tokens`, commit both. A hand edit to the CSS fails `make tokens-check`.
  The file is split three ways: generated `tokens.css`, hand-written `fonts.css` (@font-face) and
  hand-written `components.css` (the focus ring, reduced-motion, primitives, components).
- **Tokens are the only source of colour.** A hex literal anywhere in `webfrontend/src` outside
  `styles/tokens.css` fails the build. Genuinely unavoidable? annotate `gf-allow-hex: <reason>` **on
  the same line** — the checker is line-scoped.
- **Never hue-only encoding.** Every status carries a glyph and a word from the ONE vocabulary in
  `src/lib/status.ts`. A status colour with no `--gf-glyph-*` now fails `make tokens-check` too.
- **Diffs are blue/orange with `+`/`−` markers**, and the removed marker is U+2212 MINUS, not the
  patch format's hyphen. Four channels carry add-versus-remove; the tint is the weakest.
- **Astro does not add `px`.** `{ gap: 24 }` renders `gap:24` and the browser discards it. Use
  `'24px'`; a test walks `src/**.astro` and fails on a bare number in a length property. This once
  silently discarded 197 spacing values across nine files — no DOM assertion could see it, a
  grayscale screenshot could.
- **One shell owns the content column** (ADR-0079, SPEC-0060): `PageShell.astro` and
  `src/lib/shell.ts`. Pages carry no geometry; a dimensional literal fails a gate beside the hex one.
- **Frost (light) is the only default.** Deepfreeze is fully tokenized so it cannot drift.
- Fonts are **self-hosted WOFF2** under `webfrontend/public/fonts`; a test asserts the built output
  never reaches the Google CDN.

## What Phase 3.1 decided that changes how you build

- **Durability** (ADR-0062, SPEC-0042): agent and residency stores are Postgres adapters behind the
  existing ports. The enrolment-token hash lookup is the **one named RLS exemption**, and a failed
  signature may not silently consume a token (AC6).
- **The Declare surface verifies its caller** (SPEC-0043 AC6); no tenant/actor/role field exists in
  `residency/v1` messages, by contract test.
- **Custody is OpenBao** (ADR-0066, SPEC-0044 AC5): control-plane-side, three-node Raft, Shamir
  quorum unseal, Kubernetes auth, image pinned per ADR-0034.
- **Two trust bundles, named apart:** the CA trust bundle (ADR-0064) is not the release trust bundle
  (ADR-0044/ADR-0065); neither one's test may stand in for the other's.
- **The operator image ships digest-pinned only** — `operator.image.tag` is a tripwire that FAILS the
  install; the only honored pin is `operator.image.digest`, gated by `check-signed-releases.sh`.

## Rules the review loop added (EP-29…EP-31)

- **Four eyes on every merge** (ADR-0085): `approval_floor := 2` lives in `authz.rego` beside
  `required_approvals`, as a **second inequality** — `required_approvals` can raise the bar, never
  lower it. The author's own review records and audits but never counts.
- **A merge request can be a draft** (ADR-0087): while `DRAFT` the machinery stays quiet — no
  projections, no announcements, no merges. `MarkMergeRequestReady` is its one door out.
- **Merges are feature-based by default** (ADR-0088): the strategy is read **server-side from the
  repository record**, never a caller's choice. An unset strategy is the legacy landing,
  byte-for-byte. Trunk mode constrains history shape and never widens who may land what.
- **Commit-producing work lives in `git-storaged`**, and the committer is always the service
  identity while a replayed commit keeps its original author.

## History, compressed

- **2026-08-23** — ADR-0089 (Go 1.27), ADR-0090 (git-storaged's base), ADR-0091 + SPEC-0066 + T-0083
  (the token source). Four pre-existing reds fixed; five images published; a live rebase landing proven.
- **2026-08-21** — EP-29 durability debt, EP-30 the review loop completed, EP-31 notifications.
  ADR-0080, 0084–0088.
- **2026-08-19** — Tier B and Tier C closed; EP-28 the design layer (461 dimensional literals to
  zero, 0 waivers). ADR-0071…0079.
- **2026-08-18** — Phase 4 opened; ADR-0070 Accepted; Tier A closed (EP-25).
- **2026-08-17** — Phase 3.5, the design system, opened and closed in a day under ADR-0069.
- **Phase 3.1 wave records** and the earlier phase records live in `governance/docs/tasks/` exit
  records and `governance/docs/backlog/README.md`.

**The lesson the record keeps.** A test against a fake proves the control flow, not the claim. Live
proofs found the no-refspec fetch, the `authz.rego` that granted `repository.import` to no role, the
SeaweedFS 200-on-missing-bucket, the S3 gateway serving unsigned reads, the role-less merge-base read
— and this session, a rebase landing that had never worked on any published image while every unit
test passed. Three more shapes of the same lesson, all earned:

- **A green gate is not a correct spec.** Check the port signature before believing "no exception
  exists".
- **A DOM assertion passes happily on a page whose layout has collapsed** — which is why the CVD
  captures are a criterion and not a nicety.
- **"Green locally" is not "green in CI."** `make verify` does not run `policy-check`, and submodule
  CI only fires on push. Three of this session's four reds were work that had never reached CI at
  all because `origin/main` was many commits behind. **Push early**; it is what surfaces that class.

## Tool entry points

`CLAUDE.md` → `AGENTS.md` for Claude Code; `AGENTS.md` for Codex, OpenCode (+ `opencode.json`) and any
other agent; `.cursor/rules/agdd.mdc` for Cursor; `.github/copilot-instructions.md` for Copilot. All
are **generated** from `governance/canonical/agent-surfaces/` by `governance/scripts/gen-agent-surfaces.sh`
(ADR-0037) — edit the canonical source and regenerate; CI fails on drift.
