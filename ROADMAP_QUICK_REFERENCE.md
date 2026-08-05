# Gitfrok Roadmap — Quick Reference

> **Derived document — not a source of truth.** Statuses, epics and sequencing come from
> `governance/` (ADR-0001; super-repo `AGENTS.md` rule 4). If this disagrees with governance,
> governance is right. Companion: `ROADMAP_PLANS_TASKS.md` (full detail).
>
> **Synced from governance pin `130b824` on 2026-08-06.**

## The four phases

```
┌──────────────────────────────────────────────────────────────────┐
│ PHASE 0 — Foundations                          IN PROGRESS       │
│ scaffolding · dev env · tenancy/RLS · PDP · audit · storage bench│
│ 10 tasks: T-0001…T-0009 + T-0020  —  4 Done, 6 Todo             │
│ Exit: tenant-scoped, policy-checked, audited request end-to-end  │
│       in Minikube; boundary/arch tests in CI; benchmark decided  │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│ PHASE 1 — MVP (GitHub-lite)                    NOT STARTED       │
│ git push/pull · auth · repo UI · MR/PR · CI v0 · import          │
│ 9 tasks: T-0010…T-0018  —  all Todo                             │
│ Exit: a team hosts a repo, reviews+merges an MR, runs a pipeline │
│ Blocked by: Phase-0 exit; T-0007 benchmark gates git storage     │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│ PHASE 2 — the Ultimate wedge                   NO TASKS YET      │
│ scanners → normalized findings → unified dashboard · policies    │
│ as code · audit UI + evidence export · code search              │
│ Backlog: "to be expanded"; PRD PR-13…PR-19 need specs + tasks   │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│ PHASE 3 — BYO & commercial                     NO TASKS YET      │
│ agent · operator + Helm · per-cloud drivers · metering/fair-use  │
│ Backlog: "to be expanded"; PRD PR-20…PR-23 need specs + tasks   │
└──────────────────────────────────────────────────────────────────┘

GA = Phase-3 exit + a SOC 2 Type II report (PRD §10).
```

## Phase 0 status

Status is each task file's own `Status:` field.

| Task | Title | Status | Epic |
|---|---|---|---|
| T-0001 | Scaffold super-repo + submodules | ✅ **Done** | EP-0 |
| T-0002 | Boundary/arch enforcement in CI | ✅ **Done** | EP-0 |
| T-0003 | Minikube dev environment | 📝 Todo | EP-1 |
| T-0004 | Tenancy + RLS baseline | 📝 Todo | EP-2 |
| T-0005 | PDP skeleton (OPA) | 📝 Todo | EP-2 |
| T-0006 | Append-only audit log | 📝 Todo | EP-2 |
| T-0007 | Storage benchmark | 📝 Todo ⚠️ gates Phase 1 | EP-3 |
| T-0008 | In-process bus + module `api` | ✅ **Done** | EP-0 |
| T-0009 | Architecture fitness functions | ✅ **Done** | EP-0 |
| T-0020 | Contract schema gate (`buf lint`/`breaking`) | 📝 Todo — ready to start | EP-9 |

**EP-0 (scaffolding & process) closed 2026-08-04** — all four tasks Done. The merge gates now block
rather than merely run (ADR-0031), and since 2026-08-05 four-eyes review binds owners too.

**T-0003 caveat:** its manifests and scripts are merged on super-repo `main` (`deploy/dev/`,
`scripts/dev-up.sh`, `scripts/smoke-dev.sh`), but nothing has run on a cluster, so every AC is
*implemented, unverified* and the task is correctly still `Todo`. `deploy/dev/README.md` has the
AC-by-AC state.

## Phase 0 sequencing

From `governance/docs/plans/phase-0-foundations.md` — the only phase with a plan file.

```
critical path:  T-0001 ──▶ T-0003 ──▶ T-0004

parallel:       T-0001 ──▶ T-0002 ──▶ T-0009
                T-0001 ──▶ T-0005, T-0006, T-0008
                T-0007  (independent) ⚠️ must finish before Phase-1 storage work
```

## Phase 1 sequencing — mostly undefined

There is **no Phase-1 plan file**, and the task template has no `Depends on` field. The only stated
Phase-1 dependency in governance is T-0018's:

```
T-0018 (import) requires  T-0010 (Git-RPC) · T-0006 (audit log) · T-0016 (MR + approval)
```

Plus the cross-phase gate: **T-0007 → T-0010**, and the benchmark result may amend ADR-0016.

Everything else is unsequenced. Writing `governance/docs/plans/phase-1-mvp.md` is tracked as PRD
§12.2 open item 1 — until it exists, do not treat any other Phase-1 ordering as authoritative.

| Task | Title | Epic |
|---|---|---|
| T-0010 | Git-RPC storage service | EP-4 Git plane |
| T-0011 | Smart-HTTP + SSH front doors | EP-4 |
| T-0012 | Sync-replica write path + failover | EP-4 |
| T-0013 | Identity & access: Zitadel + PATs | EP-5 Identity |
| T-0014 | Repository read APIs + BFF aggregation | EP-6 Code UX |
| T-0015 | Web: repo browser + file/diff + palette | EP-6 |
| T-0016 | Merge requests + protected branches | EP-7 Review & CI |
| T-0017 | CI v0: gVisor sandbox runner + KEDA | EP-7 |
| T-0018 | Repository & review-history import | EP-8 Migration |

## Phase 0 exit criteria

From `governance/docs/roadmap/README.md` and the phase-0 plan:

- [ ] all 10 Phase-0 tasks Done (per `definition-of-done.md`)
- [ ] CI green on unit + contract + boundary + policy/isolation + fitness-function tests
- [ ] `make dev-up` brings the stack up on `*.gitsaas.test`
- [ ] storage benchmark (T-0007) decided; any ADR-0016 amendment recorded

## Key ADRs

| ADR | Governs |
|---|---|
| **0001** | ADRs are the Source of Truth (**not** AGDD — that is ADR-0028) |
| **0023** | Stack + version floors: Go 1.26, Node 26, PostgreSQL 18, Valkey 9.1, Redpanda v26.1, SeaweedFS 4.40 |
| **0024** | Local dev: ✓ Minikube, ✓ mkcert TLS, ✓ `*.gitsaas.test`, ✗ OrbStack, ✗ Compose |
| **0025** | Modular monolith per plane |
| **0026** | Service extraction triggers — budgets set by **ADR-0030** |
| **0027** | Submodule topology: governance ◀ backend ◀ bff ◀ webfrontend |
| **0028** | AGDD is the delivery framework |
| **0029** | Imported history is `ATTESTED_IMPORT` — never audit, never satisfies a merge policy |
| **0031** | Merge enforcement split into `main-integrity` + `main-review` |
| **0032** | `buf lint` + `buf breaking` gate `contracts/`; the 13 `ENUM_VALUE_PREFIX` violations are renamed **before** the baseline is taken |

## What "Done" means

Spec exists (or ACs for a chore) · tests written **first** and passing · boundary/arch tests pass ·
policy + tenant-isolation tests pass · no invariant violated · contracts additive within v1 · ADR
added if a decision was made · ADR-0023 floors respected · PR satisfies the template · CI green ·
task file + backlog updated. Full text: `governance/docs/process/definition-of-done.md`.

## Picking up work

1. `make bootstrap`
2. Read `governance/AGENTS.md` → `governance/docs/agents/invariants.md`
3. Pick a `Todo` task; check its **`Repo(s):`** field — one commit never spans two submodules
4. AGDD loop: governance → spec (or Proposed ADR and **stop**) → failing tests from ACs → code →
   gates → PR in that submodule
5. Check the requirement against PRD phase and §7 non-goals; do not add scope the PRD excludes

## Reference

- Full detail: `ROADMAP_PLANS_TASKS.md` · document map: `DOCUMENTATION_INDEX.md`
- Governance: `governance/docs/roadmap/`, `docs/plans/`, `docs/backlog/`, `docs/tasks/`
- Product: `governance/docs/product/PRD.md` (`PR-#`, phases, non-goals, GA)
- Process: `governance/docs/process/agdd.md`, `agentic-sdlc.md`, `definition-of-done.md`
- Invariants: `governance/docs/agents/invariants.md` · Agents: `governance/AGENTS.md`
