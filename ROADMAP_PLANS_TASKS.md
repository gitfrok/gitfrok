# Gitfrok: Roadmap, Plans & Tasks

> **Derived document — not a source of truth.** Every phase, status, epic, spec and dependency below
> is copied from `governance/`, which is authoritative (ADR-0001; super-repo `AGENTS.md` rule 4). If
> this file disagrees with governance, **governance is right and this file is stale**. Re-derive it
> rather than editing a status here.
>
> **Synced from governance pin `3431762` on 2026-08-06.**
> Sources: `governance/docs/roadmap/README.md`, `docs/plans/`, `docs/backlog/README.md`,
> `docs/tasks/T-*.md` (each task file's own `Status:` field), `docs/product/PRD.md`.

---

## Executive summary

Four milestone-based phases, each with an exit criterion before the next begins. Work is executed
through the Agentic SDLC (`governance/docs/process/agentic-sdlc.md`) — spec-first, test-first — and
must satisfy `governance/docs/process/definition-of-done.md`.

| Phase | Theme | Tasks | State |
|---|---|---|---|
| 0 | Foundations | T-0001 – T-0009, T-0020 (10) | in progress — 7 of 10 Done; EP-0 closed 2026-08-04, EP-9 + EP-3 2026-08-06 |
| 1 | MVP (GitHub-lite) | T-0010 – T-0018 (9) | not started |
| 2 | Unified security & governance (the wedge) | none yet | backlog says *to be expanded* |
| 3 | BYO & commercial | none yet | backlog says *to be expanded* |

**What the product must do** is `governance/docs/product/PRD.md` (`PR-1`–`PR-23`, phases, non-goals,
GA definition). **Why it is built this way** is the ADRs. GA is defined as Phase-3 exit **plus** a
SOC 2 Type II report (PRD §10) — it is a GA requirement, not a "later, unscheduled" item.

---

## ROADMAP — strategic phases

Verbatim intent from `governance/docs/roadmap/README.md`; exit criteria are that file's, not invented.

### Phase 0 — Foundations
Scaffolding, dev environment, tenancy + RLS, PDP, audit log, and the storage benchmark that unblocks
the git-storage design.

**Exit:** an empty-but-wired repo where a tenant-scoped, policy-checked, audited request runs
end-to-end in Minikube; boundary/arch tests enforced in CI; benchmark decided.

### Phase 1 — MVP (GitHub-lite)
Git push/pull (RPC + sync-replica write path), auth (Zitadel), repo/file/diff UI, MR/PR review with
protected branches, CI v0 (gVisor sandboxes).

**Exit:** a team can host a repo, open/review/merge an MR, and run a pipeline.

### Phase 2 — the Ultimate wedge
Security scanners → normalized findings → unified dashboard; security/approval policies as code;
audit UI + evidence export; code search.

**Exit:** the differentiating governance/security surface is usable end-to-end.

### Phase 3 — BYO
Agent (implements `contracts/proto/agent/v1`), Operator + Helm, per-cloud drivers, usage metering →
billing + fair-use.

**Exit:** a customer runs the data plane in their own GKE/EKS/AKS under a flat plan.

### Later / not scheduled
Registry hardening, packages, air-gapped installs (Topology A), advanced compliance frameworks
**beyond SOC 2 Type II** — SOC 2 Type II itself is in the GA definition (PRD §10), and PRD §12.3
deliberately leaves further frameworks unnamed.

### Architecture evolution (ADR-0025 → ADR-0026)
Phases 0–3 ship as a modular monolith per plane (ADR-0025). A module is extracted into a coarse
service (ADR-0026) only when a fitness-function trigger fires: distinct scaling profile;
isolation/blast-radius/compliance need; divergent SLO/deploy-cadence/ownership; or build/test/deploy
time crossing budget. Budgets are set by **ADR-0030**. Under BYO each extraction adds a pod to the
customer's cluster, so it must justify the footprint (**G8**, cost governance). Triggers are tracked
by T-0009, not scheduled.

---

## PLANS — execution strategy

`governance/docs/plans/` holds **one plan file**, `phase-0-foundations.md`, plus its `README.md`
index. There is no Phase-1, Phase-2 or Phase-3 plan; PRD §12.2 open item 1 records this, and notes
the consequence — later phases are sequenced only by whatever individual task files state.

### Plan: Phase 0 — Foundations

Workstreams and sequencing exactly as `phase-0-foundations.md` orders them:

| # | Workstream | Task | Sequencing per the plan |
|---|---|---|---|
| 1 | Scaffolding | T-0001 | unblocks everything |
| 2 | Boundary enforcement in CI | T-0002 | depends on T-0001; keeps HCLC honest from commit 1 |
| 3 | Dev environment | T-0003 | parallel with 1–2; needed to run anything |
| 4 | Tenancy + RLS | T-0004 | depends on T-0003 (DB up); foundational for all data |
| 5 | PDP skeleton | T-0005 | depends on T-0001; consumed by all request paths |
| 6 | Audit log | T-0006 | depends on T-0001; sink for all sensitive actions |
| 7 | Storage benchmark | T-0007 | parallelizable; **gates** the Phase-1 git-storage design |
| 8 | In-process bus + module `api` | T-0008 | depends on T-0001; the modular-monolith seam (ADR-0025) |
| 9 | Architecture fitness functions | T-0009 | depends on T-0002; proves extraction-readiness (ADR-0026) |
| 10 | Contract schema gates | T-0020 | depends on T-0001 (contracts + codegen wired); added 2026-08-06, hence last in the list rather than in dependency order |

**Critical path:** T-0001 → T-0003 → T-0004. T-0007 runs alongside and must finish before Phase-1
storage tasks. T-0020 is off the critical path — nothing in Phase 0 waits on it — but Phase 0 cannot
exit without it.

**Risks** (the plan's own): version availability, since ADR-0023 floors sit near the knowledge
boundary — verify at setup; and a benchmark result that forces a storage redesign, which is exactly
why T-0007 is in Phase 0 rather than later.

**Exit criteria:** all **ten** Phase-0 tasks Done; CI green on unit + contract + boundary +
policy/isolation + fitness-function tests; `make dev-up` brings the stack up on `*.gitsaas.test`.
The plan now attributes each half of that CI line to a workstream, because "runs green" reads as
already satisfied and is not: boundary + fitness → T-0002/T-0009 (done); contract → T-0020 (done);
unit + policy/isolation → T-0004/T-0005/T-0006 (open); `make dev-up` → T-0003 (in progress — it has
now run on a cluster; AC2 and AC4 verified, AC1's create path and AC3's DNS path still open).

---

## TASKS — inventory

Status is each task file's own `Status:` field. Epic is its `Phase / Epic:` field cross-checked
against `docs/backlog/README.md`. **Owner is `unassigned` on every task** — no task carries one.

### Phase 0 — Foundations (10 tasks)

| Task | Title | Status | Epic | Repo(s) | Spec | ADRs |
|---|---|---|---|---|---|---|
| T-0001 | Scaffold super-repo + submodules | **Done** | EP-0 | super-repo + all four | chore | 0027, 0025, 0022, 0023, 0028 |
| T-0002 | Boundary/arch enforcement in CI | **Done** | EP-0 | backend + bff + super-repo | chore | 0022, 0025, 0026, 0027, 0031 |
| T-0003 | Minikube dev environment | **In progress** — AC2+AC4 verified | EP-1 | super-repo (`Makefile`, `deploy/dev/`) | chore | 0024, 0023 |
| T-0004 | Tenancy + RLS baseline | **Done** | EP-2 | backend | SPEC-0001 | 0003, 0022, 0007 |
| T-0005 | PDP skeleton (OPA) | Todo | EP-2 | governance → backend → bff | SPEC-0002 | 0006, 0022 |
| T-0006 | Append-only audit log | Todo | EP-2 | governance → backend | SPEC-0003 | 0007, 0022 |
| T-0007 | Storage benchmark | **Done** | EP-3 | super-repo → governance | chore | 0020, 0023, 0016, **0033 (governing)** |
| T-0008 | In-process bus + module `api` | **Done** | EP-0 | backend | chore | 0025, 0022 |
| T-0009 | Architecture fitness functions | **Done** | EP-0 | backend (+ super-repo) | chore | 0026, 0025, 0022, 0030 |
| T-0020 | Contract schema gate | **Done** | EP-9 | governance → backend → bff → webfrontend → super-repo | chore | **0032 (governing)**, 0022, 0027, 0031 |

**EP-0 closed 2026-08-04** — all four of its tasks Done. T-0002's AC5 was the last item: the gates
now *block* rather than merely run. ADR-0031 split `main` enforcement into `main-integrity` (no
bypass actors) and `main-review` (one approval), applied to all five repos by
`scripts/apply-rulesets.sh`, with legacy branch protection deleted. Verified empirically: a direct
admin push to `main` is `[remote rejected]`, and `gh pr merge --admin` is refused on a red required
check.

Two ADR-0031 follow-ups have since closed: `webfrontend` gained a CI workflow and it is now a
required check; and `main-review`'s admin bypass was removed on **2026-08-05** when a second org
member joined, so four-eyes review binds owners too. ADR-0031's title still reads "keep review
bypassable" because Accepted ADRs are immutable (invariant 11) — where the follow-up landed is
recorded in T-0002 and the backlog, not by editing the decision.

Remaining follow-up: the two rulesets are five per-repo copies, because org-level rulesets need
GitHub Team. `make rulesets-check` keeps them honest.

#### T-0020 — the gate `ci-gates.md` always claimed (Done 2026-08-06)
Filed and finished 2026-08-06 under a **new epic, EP-9**, not a reopened EP-0.
`governance/docs/process/ci-gates.md` had marked "contract schema (additive / breaking-check)"
required in four repos all along while `buf` ran in no CI anywhere and `buf lint` on `contracts/` was
red — 13 `ENUM_VALUE_PREFIX` violations in `proto/agent/v1/agent.proto`. Phase 0, because the
phase-0 exit criteria require CI green on *contract* tests.

**What is enforced now.** ADR-0032 settled the 13 names as a **rename before the `buf breaking`
baseline was taken** — invariant 10 permits it, since a rename keeps the number and type — rather
than a path-scoped exemption. `buf lint` and `buf breaking` (baseline: tip of `main`, category
`FILE`) are required in governance CI, and the super-repo's `make codegen-check` requires every
consumer's generated tree to match its pinned contracts. Both ride inside already-required check
contexts, so they block rather than merely run.

**AC5 was amended during implementation, not quietly ticked.** It asked for codegen freshness in each
consumer's own CI, which cannot exist while every `buf.gen.yaml` reads `../governance/contracts` — a
sibling checkout present only in this composition. Per-consumer gating stays blocked on the
ADR-0027/0028 generated-type publishing follow-up; the trade accepted in exchange is that a
hand-edited `gen/` is caught at the pin bump rather than in the consumer's own PR.

**`ci-gates.md`'s rows were corrected too**, since the four-repo shape was unbuildable: lint and
breaking belong to governance, generated-code freshness to the super-repo. Every ✓ in that table now
maps to a check that runs.

#### T-0007 — measured, and the answer was a correctness one (Done 2026-08-06)
The benchmark ran: `make bench-storage` in the super-repo, both arms on one physical disk so the delta
isolates the storage path rather than the device. **SeaweedFS-FUSE is disqualified for live bare repos,
on `rename()` atomicity rather than on speed.** Git commits every ref update by renaming
`refs/heads/x.lock` over `refs/heads/x`; 36 of 428 concurrent `git rev-parse --verify` calls on the
FUSE arm failed to resolve a ref that never stopped existing, against 0 of 229 on block — with **zero**
rename errors reported by git, so rename succeeds and simply is not atomic. Reproduced three times
across two probe designs.

Performance was not the deciding factor: ~12% slower on push and clone, ~2× on `gc` and `status`, 2.6×
lower concurrent-push throughput. FUSE *passed* O_EXCL locking, fsync, durability across a remount,
contended-push semantics and `fsck`.

So **ADR-0016 needed no amendment**, and **ADR-0033 is Accepted** (2026-08-06) — which also discharged
invariant 7's escape clause: the rule already read "block volumes", and the benchmark it was waiting on
concluded the same way. Reopening it now requires demonstrating atomic `rename()` under concurrent
readers, not a faster FUSE client. Evidence and its limits — one workstation, single-node filer, so the
latency *ratios* want a cluster re-run after T-0003 while the correctness verdict does not — are in
`governance/docs/bench/T-0007/`.

#### T-0003 — it has now actually run (In progress, 2026-08-06)
`deploy/dev/` ran on a real cluster for the first time (minikube, rootless podman driver). **AC2 and
AC4 are verified**; AC1's addon half is verified and its cluster-create path is not; **AC3 is verified
in substance but not by the path it specifies** — ingress serves the mkcert wildcard and returns the
fixture (`http_code=200`, `ssl_verify_result=0` against the mkcert CA), but only via
`kubectl port-forward`, because under rootless podman the node IP is unroutable from the host. No
`/etc/hosts` entry fixes that.

**It cost seven manifest fixes** (super-repo `41e2f45`). As written, three of the five services could
not start: a Redpanda tag that was never published, a seaweedfs subcommand that does not exist, a
readiness path that 404s so the rollout blocks forever, ReadWriteOnce PVCs deadlocking on their own
volume under `RollingUpdate`, and a Zitadel config poisoned by Kubernetes service-link env vars — the
Service `zitadel` collides with Zitadel's own `ZITADEL_` config prefix. That is the value of running
something: none of it was visible to review or to `check-dev-images.sh`.

What remains is **not code** — AC1's create path and AC3's DNS path need a rootful container driver or
KVM, and macOS needs a macOS. AC-by-AC detail: `deploy/dev/README.md` and the task file.

### Phase 1 — MVP (9 tasks)

Every Phase-1 task is `Todo`. Eight of the nine task files label the epic `1 / MVP` and leave the
grouping to the backlog, which splits them into EP-4…EP-8 as shown here; T-0018 is the exception —
its own field already reads `1 / EP-8 Migration`.

| Task | Title | Epic | Repo(s) | Spec | ADRs |
|---|---|---|---|---|---|
| T-0010 | Git-RPC storage service | EP-4 Git plane | backend (git-storaged) | SPEC-0004 | 0004, 0016 |
| T-0011 | Smart-HTTP + SSH front doors | EP-4 | backend | SPEC-0004 | 0004, 0003 |
| T-0012 | Sync-replica write path + failover | EP-4 | backend (git-storaged) | SPEC-0005 | 0016, 0018 |
| T-0013 | Identity & access: Zitadel + PATs | EP-5 Identity | backend + governance | SPEC-0006 | 0003, 0006 |
| T-0014 | Repository read APIs + BFF aggregation | EP-6 Code UX | backend + bff | SPEC-0007 | 0022, 0015 |
| T-0015 | Web: repo browser + file/diff + palette | EP-6 | webfrontend | SPEC-0008 | 0015, 0023 |
| T-0016 | Merge requests + protected branches | EP-7 Review & CI | backend + governance | SPEC-0009 | 0004, 0006, 0007 |
| T-0017 | CI v0: gVisor sandbox runner + KEDA | EP-7 | backend (ci + runner) | SPEC-0010 | 0005, 0012 |
| T-0018 | Repository & review-history import | EP-8 Migration | governance + backend + bff + webfrontend | SPEC-0011 | **0029 (governing)**, 0004, 0016, 0007, 0006, 0003, 0022, 0015 |

T-0018 is ready to start: ADR-0029 Accepted, SPEC-0011 Approved. Imported history is
`ATTESTED_IMPORT` — it never enters the audit log, and imported approvals never satisfy a merge
policy. **T-0019 was retired**, folded into T-0018 at spec review; the number is never reused.

---

## Dependencies

**Only two sources of truth exist for sequencing, and neither covers Phase 1 as a whole.** The task
template has no `Depends on` field, and only T-0018 states dependencies explicitly.

**Phase 0** — from `plans/phase-0-foundations.md` (see the plan table above):

```
T-0001 ──┬─▶ T-0002 ──▶ T-0009
         ├─▶ T-0005
         ├─▶ T-0006
         └─▶ T-0008

T-0003 ──▶ T-0004          (T-0003 runs parallel to T-0001/T-0002)
T-0007                      parallel; GATES Phase-1 git-storage design
```

**Phase 1** — the only stated dependency is T-0018's: **T-0010** (Git-RPC), **T-0006** (audit log),
**T-0016** (MR + approval). Everything else is unsequenced in governance. Any other Phase-1 ordering
you see quoted elsewhere is inference, not governance — writing
`governance/docs/plans/phase-1-mvp.md` is the fix, and it is tracked as PRD §12.2 open item 1.

**Bottleneck cleared (2026-08-06):** T-0007 gated T-0010 and is now Done. The result does **not** amend
ADR-0016 — ADR-0033 (Accepted) confirms block volumes for live bare repos, so T-0010's storage
assumption stands and it is free to start.

---

## Definition of Done

Per `governance/docs/process/definition-of-done.md`, a task is Done when: a spec exists (or
acceptance criteria for a chore); tests were written **first** and pass (unit, contract,
integration); boundary/arch tests pass; policy and tenant-isolation tests pass; no invariant is
violated (`governance/docs/agents/invariants.md`); contract changes are additive within v1; an ADR
is added if a decision was made; ADR-0023 version floors hold; the PR satisfies the template; CI is
green; and the task file plus backlog are updated.

---

## Key ADRs

| ADR | Title |
|---|---|
| 0001 | Architecture Decision Records are the Source of Truth |
| 0002 | Adopt Governance-Driven design (policy-as-code, PEP/PDP, traceability) |
| 0003 | Multi-tenancy via shared Postgres + row-level security, with cell escalation |
| 0006 | Policy-as-code with OPA (PEP/PDP), deny-by-default |
| 0007 | Append-only, tamper-evident audit log |
| 0016 | Git storage failover — primary + one synchronous replica + async fan-out |
| 0022 | High cohesion, low coupling |
| 0023 | Technology stack (rev. 3) — version floors + Valkey |
| 0024 | Local/dev environment — Minikube only |
| 0025 | Modular monolith per plane |
| 0026 | Service-based target + extraction triggers |
| 0027 | Repo topology — git submodules |
| 0028 | Adopt AGDD as the delivery framework |
| 0029 | Imported history — attested provenance |
| 0030 | Extraction-trigger budgets for the modular monolith |
| 0031 | Split merge enforcement — bind admins to checks |
| 0032 | Gate the contract schema — lint + breaking checks on `contracts/` |
| 0033 | Live bare repos stay on block volumes — SeaweedFS-FUSE fails git's rename contract |
| 0034 | Image pins are fully-qualified, resolvable, patch-level tags |

ADR-0001 is the SoT decision, **not** the AGDD framework — AGDD is ADR-0028. The full index with
statuses is `governance/docs/adr/README.md`.

---

## Getting started

1. `make bootstrap` — initialises submodules and prints the toolchain floors.
2. Read `governance/AGENTS.md`, then `governance/docs/agents/invariants.md`.
3. Pick a `Todo` task in `governance/docs/tasks/`. Check its `Repo(s):` field — **one commit never
   spans two submodules** (invariant 23).
4. Follow the AGDD loop (`governance/docs/process/agdd.md`): governance first → spec (or Proposed ADR
   and stop) → failing tests from the ACs → minimal code → gates → PR in that submodule.
5. Cross-repo work follows ADR-0027's order: governance PR → consumers → super-repo pin bump to
   **merged** commits only.
