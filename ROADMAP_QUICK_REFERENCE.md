# Gitfrok Roadmap — Quick Reference

> **Derived document — not a source of truth.** Statuses, epics and sequencing come from
> `governance/` (ADR-0001; super-repo `AGENTS.md` rule 4). If this disagrees with governance,
> governance is right. Companion: `ROADMAP_PLANS_TASKS.md` (full detail).
>
> **Synced from governance `main` on 2026-08-11, at governance PR #119 — which is not yet merged.**
> The super-repo pin is still `62f1c79`, which predates it: at that commit T-0018 reads *In
> progress*. The statuses below are therefore ahead of the pin **on purpose and only until #119
> merges**, at which point this file's pin bump lands with the merged commit. Governance decides;
> if #119 changes in review, this file follows it rather than the other way round.

## The four phases

```
┌──────────────────────────────────────────────────────────────────┐
│ PHASE 0 — Foundations                          CLOSED            │
│ scaffolding · dev env · tenancy/RLS · PDP · audit · storage bench│
│ 10 tasks: T-0001…T-0009 + T-0020  —  all Done                   │
│ Exit: tenant-scoped, policy-checked, audited request end-to-end  │
│       in Minikube; boundary/arch tests in CI; benchmark decided  │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│ PHASE 1 — MVP (GitHub-lite)          ALL TASKS DONE, NOT EXITED  │
│ git push/pull · auth · repo UI · MR/PR · CI v0 · import          │
│ 10 tasks: T-0010…T-0018 + T-0021  —  all Done (T-0018 last,      │
│           2026-08-11; its AC19 moved to Phase 2)                 │
│ Exit: a team hosts a repo, reviews+merges an MR, runs a pipeline │
│ Open: the end-to-end Minikube scenario. No object tier is wired  │
│       into any manifest; migrations are hand-applied; rootless   │
│       podman has no gVisor; one node proves no quorum/failover.  │
│       Runbook: deploy/MVP-RUNBOOK.md                             │
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
| T-0003 | Minikube dev environment | ✅ **Done** — AC1–AC4 verified | EP-1 |
| T-0004 | Tenancy + RLS baseline | ✅ **Done** | EP-2 |
| T-0005 | PDP skeleton (OPA) | ✅ **Done** | EP-2 |
| T-0006 | Append-only audit log | ✅ **Done** | EP-2 |
| T-0007 | Storage benchmark | ✅ **Done** — ADR-0033 Accepted | EP-3 |
| T-0008 | In-process bus + module `api` | ✅ **Done** | EP-0 |
| T-0009 | Architecture fitness functions | ✅ **Done** | EP-0 |
| T-0020 | Contract schema gate (`buf lint`/`breaking`) | ✅ **Done** | EP-9 |

**EP-0 (scaffolding & process) closed 2026-08-04** — all four tasks Done. The merge gates now block
rather than merely run (ADR-0031), and since 2026-08-05 four-eyes review binds owners too.

**EP-2 (tenancy & governance base) closed 2026-08-06** — T-0005 Done. The PDP landed across all four
repos in dependency order: the deny-by-default OPA bundle and `contracts/proto/policy/v1` in
governance, the embedded PDP module in backend, the PEP with a revision-invalidated decision cache in
bff, and pins plus a composition gate in the super-repo. Two things worth carrying: cache
invalidation is by **bundle revision, not by clock**, so the TTL only bounds how long a *revoked
role* keeps working; and AC4's inline-permission-check fitness function is a **tripwire, not a
proof** — authorization logic has no import signature the way every other boundary rule does.

**EP-9 (contract gates) closed 2026-08-06** — T-0020 Done. `buf lint` + `buf breaking` are required
in governance, and the super-repo requires generated code to match its pinned contracts. AC5 was
amended: per-consumer codegen gating needs the ADR-0027/0028 generated-type publishing follow-up,
so it is gated at the composition boundary instead.

**EP-1 closed — T-0003 Done.** All four criteria are verified. The create path completed on
2026-08-08 at the third attempt, costing three defects the earlier seven-manifest-fix sweep could not
have caught, because nothing had ever exercised that branch. **AC3 needed no different host:** the
earlier conclusion that it required a rootful driver or KVM was an inference from a correct
observation and is retracted — publishing the node's 80/443 to the host (`--ports`, which the podman
driver supports) makes ingress reachable on `127.0.0.1` with no `port-forward`. AC4 closed 2026-08-09
on a real macOS runner rather than by grepping for bash-4 syntax. Two residuals are named in the
record: host DNS is a manual root step, and a cluster bring-up *on a Mac* needs a hypervisor no hosted
runner has. AC-by-AC state: `deploy/dev/README.md`; operator path: `deploy/MVP-RUNBOOK.md`.

## Phase 0 sequencing

From `governance/docs/plans/phase-0-foundations.md` — the only phase with a plan file.

```
critical path:  T-0001 ──▶ T-0003 ──▶ T-0004

parallel:       T-0001 ──▶ T-0002 ──▶ T-0009
                T-0001 ──▶ T-0005, T-0006, T-0008, T-0020
                T-0007  (independent) ⚠️ must finish before Phase-1 storage work
```

T-0020 is off the critical path — nothing in Phase 0 waits on it — but Phase 0 cannot exit without
it: it owns the *contract* half of the CI exit criterion.

## Phase 1 sequencing

`governance/docs/plans/phase-1-mvp.md` now exists and is authoritative: eight workstreams, a critical
path of T-0012 ⟷ T-0016 ⟷ T-0017, and three exit criteria of which one remains open. Every task in
the table below is **Done**; the plan's workstream 8 — the single end-to-end Minikube scenario — is
the only one still running.

The task template still has no `Depends on` field. The only dependency stated inside a task file is
T-0018's:

```
T-0018 (import) requires  T-0010 (Git-RPC) · T-0006 (audit log) · T-0016 (MR + approval)
```

The cross-phase gate **T-0007 → T-0010** is **lifted**: the benchmark ran on 2026-08-06, ADR-0033 is
Accepted, block volumes are confirmed and ADR-0016 needed **no** amendment. T-0010 can proceed on that
assumption.

| Task | Title | Epic | Status |
|---|---|---|---|
| T-0010 | Git-RPC storage service | EP-4 Git plane | ✅ Done |
| T-0011 | Smart-HTTP + SSH front doors | EP-4 | ✅ Done |
| T-0012 | Sync-replica write path + failover | EP-4 | ✅ Done |
| T-0013 | Identity & access: Zitadel + PATs | EP-5 Identity | ✅ Done |
| T-0014 | Repository read APIs + BFF aggregation | EP-6 Code UX | ✅ Done |
| T-0015 | Web: repo browser + file/diff + palette | EP-6 | ✅ Done |
| T-0016 | Merge requests + protected branches | EP-7 Review & CI | ✅ Done |
| T-0017 | CI v0: gVisor sandbox runner + KEDA | EP-7 | ✅ Done — dev cluster cannot run gVisor |
| T-0018 | Repository & review-history import | EP-8 Migration | ✅ **Done 2026-08-11** — AC19 → Phase 2 |
| T-0021 | Container images for both planes | EP-4 | ✅ Done |

## Phase 0 exit criteria

From `governance/docs/roadmap/README.md` and the phase-0 plan:

- [x] all 10 Phase-0 tasks Done (per `definition-of-done.md`) — *T-0003 was the last, closed with
      AC1–AC4 verified*
- [x] CI green on unit + contract + boundary + policy/isolation + fitness-function tests —
      *completed 2026-08-06 by T-0005, which supplied the policy half: `opa test` plus a
      deny-by-default assertion in governance, the PDP adapter and inline-authz fitness function in
      backend, the PEP in bff, and a cross-repo composition gate in the super-repo*
- [x] `make dev-up` brings the stack up on `*.gitsaas.test` — *closed: the full stack comes up under
      rootless podman and `make dev-smoke` is green, with the policy bundle published as a ConfigMap
      from `governance/policies` at bring-up. The one residual is host DNS, which needs root and is
      printed rather than applied*
- [x] storage benchmark (T-0007) decided; any ADR-0016 amendment recorded — *decided 2026-08-06 via
      ADR-0033 (Accepted): block volumes; ADR-0016 not amended*

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
| **0033** | Live bare repos stay on **block volumes** — SeaweedFS-FUSE's `rename()` is not atomic, which git needs for every ref update |
| **0034** | Image pins are fully-qualified, resolvable, **specific** tags; no `:latest`. A floor is not a pin — `redpanda:v26.1` was never published |

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
- Deploy the MVP: [`deploy/MVP-RUNBOOK.md`](deploy/MVP-RUNBOOK.md) · handing over a session:
  [`HANDOFF.md`](HANDOFF.md)
- Governance: `governance/docs/roadmap/`, `docs/plans/`, `docs/backlog/`, `docs/tasks/`
- Product: `governance/docs/product/PRD.md` (`PR-#`, phases, non-goals, GA)
- Process: `governance/docs/process/agdd.md`, `agentic-sdlc.md`, `definition-of-done.md`
- Invariants: `governance/docs/agents/invariants.md` · Agents: `governance/AGENTS.md`
