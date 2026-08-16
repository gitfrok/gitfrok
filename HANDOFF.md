# Handoff — start here

One page for an incoming session or a new agent. **`governance/` is the Source of Truth (ADR-0001);**
where this file disagrees with it, governance is right and this file is stale. This file says *where
work stands and how to run it*; governance says *what and why*. Verified against the tree on
2026-08-17.

## Navigate

| You want | Read |
|---|---|
| the rules before editing anything | `AGENTS.md` (this repo) → `governance/AGENTS.md` → `governance/docs/agents/invariants.md` |
| what the product must do | `governance/docs/product/PRD.md` (`PR-#` requirements, phases, non-goals) |
| why it is built this way | `governance/docs/adr/` — index in its `README.md` |
| a task to pick up | `governance/docs/tasks/` — one file each, own `Status:` and `Repo(s):` |
| phase intent and exit criteria | `governance/docs/roadmap/README.md`, `governance/docs/plans/` |
| how work is executed | `governance/docs/process/agdd.md`, `agentic-sdlc.md`, `definition-of-done.md`, `ci-gates.md` |
| what a review already found | `phase-2-code-review.md`, `phase-2-code-review-wave2.md`, `phase-3-code-review.md`, `phase-3.1-code-review.md`, `phase-3.1-plan-review.md` (this repo's root) |
| to run the dev cluster | [`deploy/MVP-RUNBOOK.md`](deploy/MVP-RUNBOOK.md) — ordered steps |
| per-manifest detail and the defect record | [`deploy/dev/README.md`](deploy/dev/README.md) |

## Where work stands (2026-08-17)

Current pins — verified with `git submodule status` at super-repo `ec7077a`:
**governance `c7cb3e8`**, **backend `55db3bb`**, **bff `3b90090`**, **webfrontend `6c8cceb`**.

**Phases 0, 1 and 2 are Complete.** **Phase 3 (BYO) is implementation-complete** — its fifth exit
criterion is carried, not met: the install → self-register → upgrade → meter path has never run on a
real customer-shaped cluster; every real-cluster row of `deploy/conformance/byo-dataplane.md` reads
"not run", recorded against T-0003's cluster lane.

**Phase 3.1 is implementation-complete** (durability, custody, residency, signed operator, metering
UI) under ADR-0062…ADR-0067 and SPEC-0042…SPEC-0046, epics EP-19…EP-23, tasks T-0035…T-0044.
Final tips: governance `62075e2`→`c7cb3e8`, backend `7c05a86`→`55db3bb`, bff `1ffbb77`→`ee53bd8`→
`3b90090`, webfrontend `a1e614a`→`9dab620`→`6c8cceb`. Exit records live in
`governance/docs/tasks/`; the dependency spine is `governance/docs/plans/phase-3-byo-v2.md`.
**One task stands blocked:** T-0042 real GKE/EKS/AKS conformance — no code can unblock it; it waits
on T-0003's cluster lane. With it wait SPEC-0045 AC3 and SPEC-0039 AC8's migration proof on real
state.

**The North Star deployment proof is 9/9 on this machine** — `scripts/north-star.sh`
(`make dev-north-star`): enrolment token issued via the owner-only EnrolmentService door (:9094),
dataplane self-enrolled, residency declared, usage door serving, durability across controlplane
restart, evidence pack, and git clone/push/MR/merge through the live security merge gate over mkcert
TLS. Journey table with named evidence: MVP-RUNBOOK §8b. The proof CAUGHT and fixed a real defect:
the merge gate's merge-base resolver omitted the merging actor's verified roles, storage's PDP denied
every role-less `repo.read`, and every merge failed closed — fixed test-first at backend **55db3bb**
(recorded in RUNBOOK §4a/§8b/§9). Nothing weakens: precompute stays role-less best-effort.

**The usability chain landed (2026-08-16/17) and is browser-proven.** Zitadel project roles
owner/member/reader + an owner grant for `admin@gitsaas.test` converge idempotently in
`scripts/dev-provision.sh` §2b; the ingress routes `/login`, `/callback`, `/logout` → bff
(`deploy/dev/ingress.yaml`); the dataplane runs `GITFROK_OIDC_ALLOWED_ROLES=owner,member,reader`
with the singular role claim `urn:zitadel:iam:org:project:roles` (`deploy/dev/dataplane.yaml`); the
BFF session captures roles at login (bff `3b90090`, ADR-0049 d8); the webfrontend ships sign-in /
sign-out / `/usage` nav (webfrontend `6c8cceb`). Login works in a browser and `/usage` renders the
authenticated 8-dimension view.

## How to run it

**Host prerequisites (this machine):** minikube+podman machine running; `mkcert -install` done;
`/etc/hosts` six-host line (`hello/zitadel/s3/filer/app/git.gitsaas.test → 127.0.0.1`); `grpcurl`
installed; **`helm` absent** — `make verify`'s byo-chart *rendered* assertions skip honestly, static
assertions still bind. Say so when you report a green run.

**Daily loop (all idempotent):**

| Target | Does |
|---|---|
| `make bootstrap` | clone/sync submodules |
| `make dev-up` | converge the cluster (addons + mkcert TLS + manifests); **hard-fails if OpenBao is sealed** |
| `make dev-provision` | DB migrations + Zitadel OIDC client + role vocabulary (§2b) + login roundtrip |
| `make dev-smoke` | deployments up, 200 over real TLS at `*.gitsaas.test` |
| `make dev-north-star` | the full nine-step journey proof |

**Cold-restart ritual:** OpenBao quorum unseal per MVP-RUNBOOK §6a — the Shamir shares are
operator-held. **Never automate the unseal and never re-initialize** (§6a: initialize is once per
cluster, ever). Unseal must precede any consumer start.

**Dev identities:** `admin@gitsaas.test` (Zitadel, owner role on the dev tenant) · operator PAT in
secret `gitfrok-operator-pat` · enrolment token in secret `gitfrok-enrolment-token`.

**Gate matrix before you push:**

- backend: full gate chain — gofmt/vet/build/arch + the real-Postgres `-race` harness (port 15432).
- governance: `governance/scripts/check-docs.sh`, contracts and policies checks.
- super-repo: `make verify` (includes `scripts/check-runbook.sh`) && `make codegen-check` &&
  `make surfaces-check` && `make dev-smoke`.

## Governance rules that bind every agent

Condensed from `AGENTS.md` — read it before editing anything.

- **Governance is SoT.** Decisions, contracts, policies and shared surface live only in
  `governance/` (invariants 21–25). New decision → Proposed ADR and stop; new behaviour → spec
  first; API change → governance PR first, additive only.
- **One commit never spans two submodules.** Work lands in the submodule's own repo; the super-repo
  stores **pins only** (invariant 25), bumped in their own commit after the submodule commit is on
  its `main`.
- Dependency direction is one-way: `webfrontend → bff → backend → governance`. webfrontend never
  calls backend; bff holds no business logic.
- **Honest "not run" annotations.** A row that says "not run" is worth more than a row that implies
  it passed. **Write the limit down** — every carry is recorded against the spec it bounds.
- Accepted ADRs are immutable (supersede, never edit); approved specs may be amended with the
  amendment noted in `Status:`.
- **Work lands directly on `main`** (ADR-0053, ADR-0054) — no PR gate; run the local gates first.
  A red `main` is stop-everything: the next commit fixes or reverts it.

## Open items / carried limits (never silent)

1. **T-0042 multi-cloud conformance is blocked** on T-0003's cluster lane — the sole remaining
   Phase 3.1 task, and no code can unblock it.
2. **The release-trust door is unmounted in dev** (no dev-safe seed path, MVP-RUNBOOK §6b).
3. **Usage dimensions show gap states** until dataplane telemetry emission is wired — the next
   candidate task.
4. `GITFROK_CLOUD=gke` is **annotated dev fiction**; real-cluster proof is T-0042's.
5. **Backend integration tests skip without `TEST_DATABASE_URL`**, so some isolation and tamper
   proofs rest on a local run.
6. **`helm` is absent on this host** — rendered-chart assertions skip honestly; static ones bind.
7. **One throwaway probe-discard PAT** lives in the dev tenant (in-memory identity store; north-star
   git-flow PAT is the same class).
8. **Dependabot advisories are open on the bff and webfrontend default branches** — pre-existing.
9. **One-node limits stay "no" on this cluster:** failover, CI gVisor RuntimeClass under rootless
   podman, durability quorum — all need the cluster lane.
10. Proxy-only egress is unsolved (ADR-0017 follow-up) and can block a sale outright.
11. The dataplane gRPC door is unauthenticated (Phase-2 limit (d)): tenant/actor/roles come off the
    wire; mitigation is network isolation + RLS.
12. Phase-2 in-process state does not survive a restart (attribution projection, pack assembly,
    code-search index; the index also has no cap — limit (e)).
13. Two sources of schema truth: `deploy/dev/postgres.yaml`'s ConfigMap vs `backend/` migrations —
    they agree; nothing enforces it.
14. Per-consumer codegen gating is impossible while each `buf.gen.yaml` reads
    `../governance/contracts` — freshness is gated at the super-repo pin bump.
15. First-party images in `deploy/dev` are pinned by tag, not digest (ADR-0035 decision 4).
16. Host DNS for `*.gitsaas.test` needs root, so `dev-up.sh` prints the snippet rather than
    applying it.
17. git/v1 has no create-repository RPC — bare repos come back via the RUNBOOK §8a kubectl-exec
    recovery.

## The storage picture, in one place

- **Live bare repositories: block volumes** (ADR-0033). `git-storaged` refuses a FUSE repository root
  outright (invariant 7).
- **LFS, CI artifacts, image blobs: ADR-0050** puts them on a SeaweedFS FUSE mount, produced by
  ADR-0051's privileged node DaemonSet. That mount **does not propagate on this driver**, so the dev
  cluster runs the S3 adapter ADR-0050 decision 6 keeps for that case. Measured, not assumed —
  `deploy/dev/README.md`.
- **Transfers proxy through the plane** under `repo.lfs.read` / `repo.lfs.write`, and every read is
  verified against the digest in the object's name (SPEC-0023, as amended by ADR-0050).
- **Browser sessions: Valkey** (ADR-0049), opened by the BFF itself under the one datastore waiver
  ADR-0052 grants. Every other cache or database client in the BFF still fails its boundary gate.

## What Phase 3.1 decided that changes how you build

- **Durability** (ADR-0062, SPEC-0042): agent and residency stores are Postgres adapters behind the
  existing ports. The enrolment-token hash lookup is the **one named RLS exemption** (bounded to one
  row, enumerated by test), and a **failed signature may not silently consume a token** (AC6).
- **The Declare surface verifies its caller** (SPEC-0043 AC6); no tenant/actor/role field exists in
  `residency/v1` messages, by contract test.
- **A tenant-scoped platform operator may declare** (ADR-0067, SPEC-0043 AC7), reusing ADR-0046's
  `platform_operator` principal.
- **Custody is OpenBao** (ADR-0066, SPEC-0044 AC5): control-plane-side, three-node Raft, Shamir
  quorum unseal, Kubernetes auth, image pinned per ADR-0034.
- **Two trust bundles, named apart:** the CA trust bundle (ADR-0064, T-0040) is not the release
  trust bundle (ADR-0044/ADR-0065, T-0041); neither one's test may stand in for the other's.
- **The operator image ships digest-pinned only** — `operator.image.tag` is a tripwire that FAILS the
  install (T-0041); the only honored pin is `operator.image.digest`, which must agree with
  `deploy/releases/operator-app-0.1.0.release` (gated by `check-signed-releases.sh`).

## History, compressed

- **Phase 3.1 wave records** (exit pins all resolve): EP-19 durable stores/residency
  (backend@c9e58c5, 816cb30) · EP-20 Declare surface + PlacementGate (governance@794f578/3b9e853,
  bundle 0.10.0, backend@f182761) · EP-21 custody (backend@b0ab32e, super-repo@f8449b8) · EP-22
  harness (backend@762d5f0, a669cef, super-repo@febf0f7) · EP-23 divergence gates + read-only cause
  (backend@bc30abd, 0238dee; bff@4059a23; webfrontend@08f42c4, 843a195) · T-0035 envelope throttle
  (backend@a9ed620, super-repo@9f526d0).
- **Reviews at this repo's root** — records, not governance, but they save you from re-deriving:
  `phase-3.1-code-review.md` and `phase-3.1-plan-review.md` (findings acted on, produced ADR-0067) ·
  `phase-3-code-review.md` (CA trust-ordering defect fixed at backend `e722046`; opened T-0035) ·
  `phase-2-code-review.md` + `-wave2.md` (seventeen findings, seven on fixes, two residuals).
- **The lesson the record keeps:** a test against a fake proves the control flow, not the claim —
  live proofs found the no-refspec fetch, the `authz.rego` that granted `repository.import` to no
  role, the SeaweedFS 200-on-missing-bucket, the S3 gateway serving unsigned reads, and the
  role-less merge-base read (backend 55db3bb). And: a green gate is not a correct spec — check the
  port signature before believing "no exception exists".

## Tool entry points

`CLAUDE.md` → `AGENTS.md` for Claude Code; `AGENTS.md` for Codex, OpenCode (+ `opencode.json`) and any
other agent; `.cursor/rules/agdd.mdc` for Cursor; `.github/copilot-instructions.md` for Copilot. All of
them are **generated** from `governance/canonical/agent-surfaces/` by `scripts/gen-agent-surfaces.sh`
(ADR-0037) — edit the canonical source and regenerate; CI fails on drift.
