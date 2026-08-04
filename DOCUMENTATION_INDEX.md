# Gitfrok — Documentation Index

> **Derived document — not a source of truth.** A map of where things live, plus statuses copied from
> `governance/`, which is authoritative (ADR-0001; super-repo `AGENTS.md` rule 4). If this disagrees
> with governance, governance is right.
>
> **Synced from governance pin `0b3b9a9` on 2026-08-05.**

## Where to start

| You want to… | Read |
|---|---|
| understand **what** the product must do | `governance/docs/product/PRD.md` — `PR-1`…`PR-23`, phases, non-goals, GA definition |
| understand **why** it is built this way | `governance/docs/adr/` — the Source of Truth (ADR-0001); index in its `README.md` |
| pick up work | `governance/docs/tasks/` — one file per task, each with its own `Status:` and `Repo(s):` |
| know the rules before you commit | `governance/docs/agents/invariants.md` (25 constraints), then `governance/AGENTS.md` |
| know how work is executed | `governance/docs/process/agdd.md`, `agentic-sdlc.md`, `definition-of-done.md` |
| see phase intent and exit criteria | `governance/docs/roadmap/README.md` |
| see epics grouping tasks | `governance/docs/backlog/README.md` |
| see Phase-0 sequencing | `governance/docs/plans/phase-0-foundations.md` (the only plan file that exists) |
| run the dev cluster | `deploy/dev/README.md`, then `make dev-up && make dev-smoke` |
| a roadmap overview | `ROADMAP_QUICK_REFERENCE.md` (short) · `ROADMAP_PLANS_TASKS.md` (full) |

**Reading order for a new agent:** `AGENTS.md` (this repo) → `governance/AGENTS.md` →
`governance/docs/agents/invariants.md` → the task's spec and ADRs.

## Repository structure

```
gitfrok-rev4/                         super-repo — pins + orchestration only (ADR-0027, invariant 25)
│
├── governance/                       SOURCE OF TRUTH (submodule; depends on nothing)
│   ├── AGENTS.md · CLAUDE.md         agent entry points — canonical
│   ├── contracts/                    protobuf: gRPC services + events (additive-only within v1)
│   ├── policies/                     OPA/Rego policy-as-code
│   ├── scripts/                      check-docs.sh (the docs gate)
│   └── docs/
│       ├── adr/                      0001…0031 + README index — decisions, immutable once Accepted
│       ├── product/PRD.md            product requirements (PR-#); restates ADRs, never decides
│       ├── specs/                    SPEC-0001…SPEC-0011 + _template.md
│       ├── roadmap/README.md         four phases + exit criteria
│       ├── plans/                    phase-0-foundations.md  ← no phase-1/2/3 plan yet
│       ├── backlog/README.md         epics EP-0…EP-8
│       ├── tasks/                    T-0001…T-0018 + README + _template.md
│       ├── process/                  agdd.md · agentic-sdlc.md · definition-of-done.md
│       └── agents/                   invariants.md (25) · context.md
│
├── backend/                          Go modular monolith (submodule) — depends on governance
│   ├── cmd/{controlplane,dataplane}-app/
│   ├── modules/repository/           bounded context
│   └── platform/                     bus, ids, telemetry
│
├── bff/                              Go BFF, aggregation only (submodule) — governance + backend
├── webfrontend/                      Astro + React SSR (submodule) — governance + bff
│                                     scripts/check-boundaries.sh = TS half of invariant 22
│
├── deploy/dev/                       Minikube dev environment (T-0003, ADR-0024)
│   ├── postgres.yaml valkey.yaml redpanda.yaml seaweedfs.yaml zitadel.yaml
│   ├── ingress.yaml                  *.gitsaas.test over TLS — the only externally reachable path
│   ├── hello.yaml                    smoke-test fixture (busybox httpd)
│   ├── versions.env                  recorded image tags (ADR-0023)
│   └── README.md                     AC-by-AC state — read before trusting any of it
│
├── scripts/
│   ├── bootstrap.sh                  submodule init + toolchain floors
│   ├── check-dep-direction.sh        fitness: one-way dependency direction (invariant 22)
│   ├── check-version-floors.sh       fitness: ADR-0023 toolchain floors
│   ├── check-dev-images.sh           fitness: manifests match versions.env
│   ├── apply-rulesets.sh             ADR-0031 merge rulesets — plan | apply | check
│   ├── dev-up.sh                     Minikube + addons + mkcert TLS + apply + wait
│   └── smoke-dev.sh                  T-0003 integration test (AC2 + AC3)
│
├── AGENTS.md · CLAUDE.md             super-repo entry points — READ FIRST
├── Makefile · .tool-versions
└── ROADMAP_QUICK_REFERENCE.md · ROADMAP_PLANS_TASKS.md · DOCUMENTATION_INDEX.md   (derived)
```

`contracts/` and `policies/` sit at the **root of the governance repo**, not under `docs/`.

## Status

Every status below is the task file's own `Status:` field.

| Phase | Tasks | Done | Todo |
|---|---|---|---|
| 0 — Foundations | T-0001…T-0009 (9) | T-0001, T-0002, T-0008, T-0009 | T-0003, T-0004, T-0005, T-0006, T-0007 |
| 1 — MVP | T-0010…T-0018 (9) | — | all nine |
| 2 — the wedge | none defined | — | backlog: *to be expanded* |
| 3 — BYO | none defined | — | backlog: *to be expanded* |

**EP-0 (scaffolding & process) closed 2026-08-04.** The merge gates now block rather than merely run
(ADR-0031, applied to all five repos), and since 2026-08-05 four-eyes review binds owners too.

No percentage-complete figure appears here on purpose: governance records `Todo | In progress | In
review | Done` per task and nothing finer, so any percentage would be invented.

### Current focus and blockers

- **T-0003 (Minikube dev env)** — manifests and scripts are merged on `main`, but nothing has run on
  a cluster, so all four ACs are *implemented, unverified* and the task is correctly `Todo`. Next
  step: `make dev-up && make dev-smoke` on a machine with `minikube`/`kubectl`/`mkcert`.
- **T-0007 (storage benchmark)** — gates T-0010 and the whole Phase-1 git-storage design; its result
  may amend ADR-0016. Independent of everything else, so it can start now.
- **T-0004 (tenancy + RLS)** — depends on T-0003. The RLS baseline in `deploy/dev/postgres.yaml`
  creates a non-superuser `gitfrok_app` role because RLS never binds a superuser; consumers must use
  it or the policy is inert.

### Known governance gaps

Tracked in PRD §12, not invented here:

1. No Phase-1/2/3 plan files — later phases are sequenced only by what individual task files state,
   and only T-0018 states dependencies (PRD §12.2 open item 1).
2. Phase-2 and Phase-3 requirements (`PR-13`…`PR-23`) have no epics, specs or tasks yet (PRD §12.1).
3. `ZITADEL_IMAGE` is pinned to `:latest`, which is not a pin — `check-dev-images.sh` warns on it.

## Documents by purpose

**Decisions & contracts** — `governance/docs/adr/` (SoT; supersede, never edit an Accepted ADR),
`governance/contracts/` (additive-only within v1), `governance/policies/` (deny-by-default).

**Product** — `governance/docs/product/PRD.md`: `PR-#` requirements per phase, §7 non-goals
(enforceable scope), §10 GA definition (Phase-3 exit **plus** SOC 2 Type II), §12 open questions.

**Process** — `agdd.md` (the framework, ADR-0028), `agentic-sdlc.md` (the per-task loop),
`definition-of-done.md` (what Done means). Human gates: Proposed ADRs, spec approval, pin bumps.

**Enforcement** — `make verify` (dep direction, version floors, dev image pins), `make lint-shell`,
per-submodule CI, `scripts/apply-rulesets.sh check` (ADR-0031 drift), `governance/scripts/check-docs.sh`.

**Dev environment** — `deploy/dev/README.md` is the honest account of what works and what is
unverified; `ADR-0024` is the decision behind it.
