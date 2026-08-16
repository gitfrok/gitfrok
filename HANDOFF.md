# Handoff — start here

One page for an incoming session or a new agent. **`governance/` is the Source of Truth (ADR-0001);**
where this file disagrees with it, governance is right and this file is stale. This file says *where
work stands*; governance says *what and why*.

## Navigate

| You want | Read |
|---|---|
| the rules before editing anything | `AGENTS.md` (this repo) → `governance/AGENTS.md` → `governance/docs/agents/invariants.md` |
| what the product must do | `governance/docs/product/PRD.md` (`PR-#` requirements, phases, non-goals) |
| why it is built this way | `governance/docs/adr/` — index in its `README.md` |
| a task to pick up | `governance/docs/tasks/` — one file each, own `Status:` and `Repo(s):` |
| phase intent and exit criteria | `governance/docs/roadmap/README.md`, `governance/docs/plans/` |
| how work is executed | `governance/docs/process/agdd.md`, `agentic-sdlc.md`, `definition-of-done.md`, `ci-gates.md` |
| what a review already found | `phase-2-code-review.md`, `phase-2-code-review-wave2.md`, `phase-3-code-review.md`, `phase-3.1-plan-review.md` (this repo's root) |
| to run the dev cluster | [`deploy/MVP-RUNBOOK.md`](deploy/MVP-RUNBOOK.md) — ordered steps |
| per-manifest detail and the defect record | [`deploy/dev/README.md`](deploy/dev/README.md) |

## Where work stands (2026-08-16)

Pins as recorded by the Phase 3.1 docs close-out commit atop super-repo `a0ed3f5`:
**governance `a4c0748`**, **backend `0238dee`**, **bff `4059a23`**,
**webfrontend `843a195`**.

**Phases 0, 1 and 2 are Complete.** **Phase 3 (BYO) is implementation-complete** — T-0030…T-0034 all
Done against SPEC-0038…SPEC-0041, each acceptance criterion proven by named tests at the exit pins.
Its fifth exit criterion is **carried, not met**: the whole install → self-register → upgrade → meter
path has never run on a real customer-shaped cluster, so every real-cluster row of
`deploy/conformance/byo-dataplane.md` reads "not run". That is recorded against T-0003's cluster lane
the way Phase 1 and Phase 2 recorded their host limits.

**Phase 3.1 is implementation-complete — one task stands blocked.** It turned Phase 3's recorded
limits into production posture under **ADR-0062…ADR-0067** (all Accepted) and
**SPEC-0042…SPEC-0046** (all Approved), as epics EP-19…EP-23 and tasks **T-0035…T-0044** —
`governance/docs/plans/phase-3-byo-v2.md` carries the dependency spine and the exit criteria.
Exit records live in `governance/docs/tasks/`; every pin below resolves:

| Epic / task | State | Exit pins |
|---|---|---|
| **EP-19** — T-0036 durable agent stores; T-0037 durable residency declarations + pack assembly | Done | backend@c9e58c5; backend@816cb30 |
| **EP-20** — T-0038 residency Declare surface; T-0039 PlacementGate hardening | Done | governance@794f578/3b9e853 (bundle 0.10.0) + backend@f182761 |
| **EP-21** — T-0040 agent-CA custody & rotation | Done | backend@b0ab32e + super-repo@f8449b8 (Wave-3 close-out backend@28f729f + super-repo@5adedf1) |
| **EP-22 harness half** — T-0041 signed operator image + release-trust-bundle distribution | Done | backend@762d5f0 + backend@a669cef, super-repo@febf0f7 |
| **EP-23** — T-0043 divergence gates & envelope telemetry; T-0044 read-only cause distinction | Done | T-0043: backend@bc30abd + bff@4059a23 + webfrontend@08f42c4 (contracts governance@b425db0/36f284b); T-0044: backend@0238dee + webfrontend@843a195 |
| **T-0035** — envelope throttle applied in the data plane (Phase 3 carry that gated T-0043) | Done | backend@a9ed620, pin-bumped at super-repo@9f526d0 |
| **EP-22 real-cluster half** — T-0042 real GKE/EKS/AKS conformance | **Blocked** | blocked-by T-0003's cluster lane availability |

**T-0042 is the only task not Done, and no code can unblock it**: real clusters come only from
T-0003's lane. Every real-cluster row of `deploy/conformance/byo-dataplane.md` reads "not run"
with that cause annotated at the matrix's head — honest by construction, recorded against the lane
the way Phase 1 and Phase 2 recorded their host limits. With it wait SPEC-0045 AC3, Phase 3's
carried fifth exit criterion (the whole install → self-register → upgrade → meter path on a real
customer-shaped cluster), and SPEC-0039 AC8's forward/backward migration proof on real state. The
plan's exit criteria that the exit records prove are ticked in `phase-3-byo-v2.md`; the
real-cluster criterion and the final-pin-bump criterion are not.

**Start here if you are picking up work:** nothing in Phase 3.1 is actionable until the cluster
lane provides real GKE/EKS/AKS clusters — T-0042 is the sole remaining task.

**The North Star deployment proof ran to a full 9/9 verdict on this host (Stage D, 2026-08-16).**
`scripts/north-star.sh` (`make dev-north-star`) replays the whole journey on the live minikube
cluster — dev-smoke, custody, issuance, self-enrolment, residency, usage, durability, evidence,
git flow — and all nine steps passed against backend **55db3bb**; the journey table with named
evidence is MVP-RUNBOOK §8b. The proof CAUGHT a live defect the unit tests could not: the merge
gate's merge-base read went to git-storaged without the merging actor's verified roles, storage's
PDP denied every role-less `repo.read`, and every merge through the security gate failed closed.
Fixed test-first at backend **55db3bb** (roles threaded Merge → facts provider → attribution →
resolver → `ReadContext.ActorRoles`; precompute stays role-less best-effort; nothing weakens).
Carried by the run, written down in the script's verdict: `GITFROK_CLOUD=gke` is dev fiction,
the git-flow PAT is throwaway (in-memory identity store), the release-trust door stays unmounted
(no dev-safe seed), and bare repos are re-created via kubectl exec (git/v1 has no create-repo RPC).

## Read the reviews before you re-derive them

Four review reports live at this repo's root, each naming the pins it was taken at. They are records,
not governance — but they will save you from re-finding the same things:

- **`phase-3.1-plan-review.md`** — the most recent, and the one that shapes current work. Seven
  findings on the planning artifacts, all acted on, plus the ADR-0067 decision they produced. Worth
  reading in full before touching a Phase 3.1 spec or task.
- **`phase-3-code-review.md`** — the CA trust-ordering defect (fixed at backend `e722046`) and the
  carried envelope-throttle half that opened T-0035.
- **`phase-2-code-review.md`** and **`phase-2-code-review-wave2.md`** — seventeen findings, then seven
  on the fixes themselves, then two residuals.

## What Phase 3.1 decided that changes how you build

- **Durability** (ADR-0062, SPEC-0042). The agent and residency stores become Postgres adapters behind
  the ports that already exist. Two things the spec now states rather than leaves to the adapter:
  the enrolment-token hash lookup is the **one named RLS exemption** (enrolment resolves the tenant
  *from* the token, so `TokenByHash`/`ClaimToken` cannot be tenant-scoped — the exemption is bounded
  to one row and enumerated by test), and a **failed signature may not silently consume a token**
  (AC6), because durable spend plus a remote signer turns an availability event into a dead
  credential.
- **The Declare surface verifies its caller** (SPEC-0043 AC6). `residency/v1` writes control state, so
  it does not inherit SPEC-0002's limit (d) — the posture where the subject is the caller's assertion.
  No tenant, actor or role field exists in those messages, by contract test.
- **A tenant-scoped platform operator may declare** (ADR-0067, SPEC-0043 AC7). It reuses ADR-0046's
  `platform_operator` principal rather than adding a cross-tenant path: the tenant is a property of
  the verified principal. The Rego grant and its bundle-revision bump ship under T-0038 — **until then
  bundle 0.9.0 is owner-only in fact.**
- **Custody is OpenBao** (ADR-0066, SPEC-0044 AC5). Control-plane-side only, three-node Raft, Shamir
  quorum unseal, Kubernetes auth, image pinned per ADR-0034. Deploying it is T-0040's scope, not an
  assumption it inherits. Nothing in `deploy/` references it yet.
- **Two trust bundles, named apart.** The **CA trust bundle** (agent identity roots, ADR-0064,
  SPEC-0044 AC2, T-0040) is not the **release trust bundle** (cosign release-signing keys, ADR-0044 /
  ADR-0065, SPEC-0045 AC2, T-0041). Both ride the reconcile path and both stage with a dual-validate
  overlap; neither one's test may stand in for the other's.
- **The operator image ships digest-pinned only — the legacy tag is a tripwire.** T-0041 retired
  `operator.image.tag`: the dataplane chart FAILS the install if anyone still sets it
  (`deploy/helm/gitfrok-dataplane/templates/operator.yaml`), rather than silently discarding a
  mutable tag that would lie about the image the install converges. The only honored pin is
  `operator.image.digest`, and it must agree with the signed release manifest
  `deploy/releases/operator-app-0.1.0.release` (gated by check-signed-releases.sh).

## Known gaps and carried limits

1. **Proxy-only egress is unsolved and can block a sale outright** (ADR-0017's remaining follow-up). A
   customer whose egress permits only an HTTP proxy cannot install. Outside Phase 3.1's scope.
2. **The cluster lane is the standing blocker** for every infrastructure-bound proof since Phase 1: no
   gVisor RuntimeClass under rootless podman (CI dispatch), one git node (durability quorum and
   failover), measured scan and index freshness, and now the whole real-cluster conformance matrix
   (T-0042) plus SPEC-0039 AC8's forward/backward migration proof on real state.
3. **The dataplane gRPC door is unauthenticated** — Phase-2 limit (d). Every Phase-2 RPC takes tenant,
   actor and roles off the wire, so the PDP decides correctly about a caller-asserted subject; today's
   mitigation is network isolation plus RLS. SPEC-0043 AC6 gives the *new* admin surface a verified
   caller; whether that seam generalizes to the older doors is undecided and recorded in the ADR
   index's follow-ups.
4. **Phase-2 in-process state does not survive a restart** — the attribution projection, pack assembly
   state and the code-search index, which also has no per-tenant or global cap (limit (e)).
5. **Backend integration tests skip without `TEST_DATABASE_URL`**, so some isolation and tamper proofs
   rest on a local run.
6. **Two sources of schema truth** — `deploy/dev/postgres.yaml`'s ConfigMap creates the tenancy schema
   independently of `backend/`'s migrations. They agree; nothing enforces it.
7. **Per-consumer codegen gating is impossible** while each `buf.gen.yaml` reads
   `../governance/contracts`, so contract freshness is gated at the super-repo pin bump.
8. First-party images in `deploy/dev` are pinned by tag, not digest (ADR-0035 decision 4).
9. Host DNS for `*.gitsaas.test` needs root, so `dev-up.sh` prints the snippet rather than applying it.
10. `helm` is not on this host's PATH, so `make verify`'s byo-chart **rendered** assertions skip; its
    static assertions still bind. Say so when you report a green run.
11. **North Star carried limits** (Stage D, all annotated in `scripts/north-star.sh`'s verdict):
    the release-trust door is NOT mounted in dev (no dev-safe seed path, §6b), `GITFROK_CLOUD=gke`
    is dev fiction (real-cluster proof is T-0042's), the git-flow PAT is throwaway because the
    dataplane identity store is in-memory, and the git/v1 contract has no create-repository RPC —
    bare repos come back via the §8a kubectl-exec recovery.

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

## The lessons the record keeps

**A test against a fake proves the control flow, not the claim.** Proving T-0018's AC1 and AC2 against
live infrastructure found three defects that had all passed review — a `git fetch` with no refspec that
landed no branches; an `authz.rego` that granted `repository.import` to no role, so its criterion had
"passed" only because nobody could import; and a SeaweedFS PUT into a missing bucket answering 200 and
keeping nothing. Wiring the object tier found a fourth: the S3 gateway served every object to unsigned
requests. Prefer a live proof for anything an acceptance criterion rests on — and see
`deploy/dev/README.md` for the eleven defects only a real cluster bring-up exposed. The North Star
Stage D proof found one more of the same kind: the security merge gate's merge-base resolver handed
storage a role-less subject, its PDP denied the read, and every merge failed closed — invisible to
every unit test because the fake resolver has no PDP (fixed at backend 55db3bb).

**A green gate is not a correct spec.** Every Phase 3.1 review finding passed `check-docs.sh`. Two of
them — an unimplementable RLS rule and an unauthenticated write surface — would have shipped as written
and been discovered in code. When a spec says "no exception exists", check the port signature before
believing it.

**Write the limit down.** Every phase here carried something it could not finish, and each one is
readable because it was recorded against the spec it bounds rather than left as silence. A row that
says "not run" is worth more than a row that implies it passed.

## Hard rules

- Decisions, contracts and policies change **only** in `governance/` (invariants 21–25).
- Dependency direction is one-way: `webfrontend → bff → backend → governance`.
- **One commit never spans two submodules.** The super-repo stores **pins**, never in-place edits to a
  submodule path; pins move in their own commit, after the submodule commit is on its `main`
  (invariant 25).
- New decision → **Proposed ADR and stop.** New behaviour → **spec first.** API change → governance
  first, additive only.
- **Accepted ADRs are immutable** — supersede, never edit. Approved specs *may* be amended in place,
  with the amendment noted in the `Status:` line (see SPEC-0042…0045 for the shape).
- Every query tenant-scoped; authZ through the PDP; audit append-only.
- **Work lands directly on `main`** (ADR-0053, ADR-0054). No pull request and no review — four-eyes is
  removed by decision. `main` carries one ruleset, `main-guard`: no force-push, no deletion, nothing
  else. A pull request is available for anything worth discussing first; it is a choice, not a gate.
- **CI on push is the only gate, so run the local gates before you push** — `make verify`,
  `make surfaces-check`, `make codegen-check`, the repo's own tests and fitness functions, and
  `governance/scripts/check-docs.sh` for a governance change. A red `main` is a stop-everything
  condition: the next commit fixes it or reverts it, and nothing else proceeds until it is green.
- Declare SPEC-0012's ceremony tier as a `Ceremony:` trailer in the commit message. Its gate reads a
  PR body, so it is inert on a push until taught to read the commit (ADR-0053, open question).
- If you do use a branch, delete it locally (`-D`; squash merges make `-d` refuse) **and** on the
  remote once it lands, then `git remote prune origin`.

## Tool entry points

`CLAUDE.md` → `AGENTS.md` for Claude Code; `AGENTS.md` for Codex, OpenCode (+ `opencode.json`) and any
other agent; `.cursor/rules/agdd.mdc` for Cursor; `.github/copilot-instructions.md` for Copilot. All of
them are **generated** from `governance/canonical/agent-surfaces/` by `scripts/gen-agent-surfaces.sh`
(ADR-0037) — edit the canonical source and regenerate; CI fails on drift.
