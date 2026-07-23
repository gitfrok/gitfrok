# AGENTS.md — super-repo entry (READ FIRST)

This is the **super-repo** for a multi-tenant Git SaaS, built with **AGDD** (AI-Agent
Governance-Driven Development, ADR-0028). Source is split into **four git submodules**
(ADR-0027). **Governance is the control surface — read it first, always.**

## Repositories (submodules) & the one-way dependency rule
```
webfrontend ──HTTP──▶ bff ──gRPC──▶ backend ──imports──▶ governance/contracts
     └───────────── generated TS types ◀────────────────┘   governance depends on NOTHING
```
| Submodule | Owns | Depends on |
|---|---|---|
| **governance/** | ADRs (SoT), specs, `contracts/`, `policies/`, roadmap/backlog/plans/tasks, process, invariants, agent rules | nothing |
| **backend/** | Go modular monolith (`modules/`, `cmd/{dataplane,controlplane}-app`, `platform/`, git-storaged, agent, operator) | governance |
| **bff/** | Go BFF (aggregation only) | governance, backend |
| **webfrontend/** | Astro + React SSR | governance, bff |

## STRICT rules for agents (non-negotiable — ADR-0027, invariants 21–25)
1. **Read `governance/AGENTS.md` and `governance/docs/` before doing anything.** Governance is SoT.
2. **Know which submodule your task targets** (each task states `Repo(s):`). **One commit never
   spans two submodules.** Do your work inside that submodule's own repo/branch and PR there.
3. **Dependency direction is one-way.** No repo imports another's internals; `webfrontend` never
   calls `backend` directly; `bff` holds no business logic.
4. **Decisions & shared surface live only in `governance/`** — ADRs, specs, invariants,
   `contracts/`, `policies/`. Changing an API = a **governance PR first** (additive-only), then
   consumers bump the pinned pointer.
5. **Cross-repo change order:** governance PR → consumer implements (bump governance pointer) →
   super-repo bumps submodule pointers to **merged** commits only. The super-repo stores **pins**,
   never in-place edits to a submodule path.
6. **Clone/pull with `--recurse-submodules`** (`make bootstrap`).

## Start
`make bootstrap` → read `governance/AGENTS.md` → pick a task in `governance/docs/tasks/` →
follow the AGDD loop (`governance/docs/process/agdd.md`).
