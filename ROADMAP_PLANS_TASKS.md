# Gitfrok: Roadmap, Plans & Tasks

> **Derived document — not a source of truth.** Every phase, status, epic, spec and dependency below
> is copied from `governance/`, which is authoritative (ADR-0001; super-repo `AGENTS.md` rule 4). If
> this file disagrees with governance, **governance is right and this file is stale**. Re-derive it
> rather than editing a status here.
>
> **Synced from governance pin `0b3b9a9` on 2026-08-05.**
> Sources: `governance/docs/roadmap/README.md`, `docs/plans/`, `docs/backlog/README.md`,
> `docs/tasks/T-*.md` (each task file's own `Status:` field), `docs/product/PRD.md`.

---

## Executive summary

Four milestone-based phases, each with an exit criterion before the next begins. Work is executed
through the Agentic SDLC (`governance/docs/process/agentic-sdlc.md`) — spec-first, test-first — and
must satisfy `governance/docs/process/definition-of-done.md`.

| Phase | Theme | Tasks | State |
|---|---|---|---|
| 0 | Foundations | T-0001 – T-0009 (9) | in progress — 4 of 9 Done; EP-0 closed 2026-08-04 |
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

`governance/docs/plans/` contains **only** `phase-0-foundations.md`. There is no Phase-1, Phase-2 or
Phase-3 plan file; PRD §12.2 open item 1 records this, and notes the consequence — later phases are
sequenced only by whatever individual task files state.

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

**Critical path:** T-0001 → T-0003 → T-0004. T-0007 runs alongside and must finish before Phase-1
storage tasks.

**Risks** (the plan's own): version availability, since ADR-0023 floors sit near the knowledge
boundary — verify at setup; and a benchmark result that forces a storage redesign, which is exactly
why T-0007 is in Phase 0 rather than later.

**Exit criteria:** all Phase-0 tasks Done; CI green on unit + contract + boundary + policy/isolation
+ fitness-function tests; `make dev-up` brings the stack up on `*.gitsaas.test`.

---

## TASKS — inventory

Status is each task file's own `Status:` field. Epic is its `Phase / Epic:` field cross-checked
against `docs/backlog/README.md`. **Owner is `unassigned` on every task** — no task carries one.

### Phase 0 — Foundations (9 tasks)

| Task | Title | Status | Epic | Repo(s) | Spec | ADRs |
|---|---|---|---|---|---|---|
| T-0001 | Scaffold super-repo + submodules | **Done** | EP-0 | super-repo + all four | chore | 0027, 0025, 0022, 0023, 0028 |
| T-0002 | Boundary/arch enforcement in CI | **Done** | EP-0 | backend + bff + super-repo | chore | 0022, 0025, 0026, 0027, 0031 |
| T-0003 | Minikube dev environment | Todo | EP-1 | super-repo (`Makefile`, `deploy/dev/`) | chore | 0024, 0023 |
| T-0004 | Tenancy + RLS baseline | Todo | EP-2 | backend | SPEC-0001 | 0003, 0022, 0007 |
| T-0005 | PDP skeleton (OPA) | Todo | EP-2 | governance → backend → bff | SPEC-0002 | 0006, 0022 |
| T-0006 | Append-only audit log | Todo | EP-2 | governance → backend | SPEC-0003 | 0007, 0022 |
| T-0007 | Storage benchmark | Todo | EP-3 | super-repo → governance | chore | 0020, 0023, 0016 |
| T-0008 | In-process bus + module `api` | **Done** | EP-0 | backend | chore | 0025, 0022 |
| T-0009 | Architecture fitness functions | **Done** | EP-0 | backend (+ super-repo) | chore | 0026, 0025, 0022, 0030 |

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

#### T-0003 — the one with work already merged
`deploy/dev/` (manifests, ingress, hello fixture), `scripts/dev-up.sh`, `scripts/smoke-dev.sh` and
`scripts/check-dev-images.sh` are on super-repo `main`. **T-0003 is still `Todo`, correctly:** none
of it has been applied to a cluster, so all four ACs read *implemented, unverified*. See
`deploy/dev/README.md` for the AC-by-AC state. Running `make dev-up && make dev-smoke` on a machine
with `minikube`/`kubectl`/`mkcert` is what remains.

### Phase 1 — MVP (9 tasks)

Every Phase-1 task is `Todo`. Task files label the epic `1 / MVP`; the backlog groups them into
EP-4…EP-8, shown here.

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

**Known bottleneck:** T-0007 (storage benchmark) gates T-0010, and its result may amend ADR-0016.

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
