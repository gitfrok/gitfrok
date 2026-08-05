# Gitfrok — Documentation Index

> **Derived document — not a source of truth.** A map of where things live, plus statuses copied from
> `governance/`, which is authoritative (ADR-0001; super-repo `AGENTS.md` rule 4). If this disagrees
> with governance, governance is right.
>
> **Synced from governance pin `6c7cbdd` on 2026-08-06.**

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
| see Phase-0 sequencing | `governance/docs/plans/phase-0-foundations.md` — all ten workstreams (the only phase with a plan) |
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
│       ├── adr/                      0001…0034 + README index — decisions, immutable once Accepted
│       ├── bench/T-0007/            storage benchmark evidence (raw JSON + reading)
│       ├── product/PRD.md            product requirements (PR-#); restates ADRs, never decides
│       ├── specs/                    SPEC-0001…SPEC-0011 + _template.md
│       ├── roadmap/README.md         four phases + exit criteria
│       ├── plans/                    README.md + phase-0-foundations.md  ← no phase-1/2/3 plan yet
│       ├── backlog/README.md         epics EP-0…EP-9
│       ├── tasks/                    T-0001…T-0018, T-0020 + README + _template.md
│       ├── process/                  agdd.md · agentic-sdlc.md · definition-of-done.md
│       └── agents/                   invariants.md (25) · context.md
│
├── backend/                          Go modular monolith (submodule) — depends on governance
│   ├── cmd/{controlplane,dataplane}-app/
│   ├── modules/{repository,codesearch}/   bounded contexts — codesearch consumes repository
│   │                                 via its api/ + the bus, never its internal/ (T-0008 AC2)
│   ├── internal/arch/                fitness functions: boundary · graph · triggers (T-0002, T-0009)
│   └── platform/                     bus, ids, telemetry
│
├── bff/                              Go BFF, aggregation only (submodule) — governance + backend
├── webfrontend/                      Astro + React SSR (submodule) — governance + bff
│                                     scripts/check-boundaries.sh = TS half of invariant 22,
│                                     run by its CI gate (required on main since 2026-08-05)
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
| 0 — Foundations | T-0001…T-0009 + T-0020 (10) | T-0001, T-0002, T-0007, T-0008, T-0009, T-0020 | T-0003, T-0004, T-0005, T-0006 |
| 1 — MVP | T-0010…T-0018 (9) | — | all nine |
| 2 — the wedge | none defined | — | backlog: *to be expanded* |
| 3 — BYO | none defined | — | backlog: *to be expanded* |

**EP-0 (scaffolding & process) closed 2026-08-04.** The merge gates now block rather than merely run
(ADR-0031, applied to all five repos), and since 2026-08-05 four-eyes review binds owners too.

No percentage-complete figure appears here on purpose: governance records `Todo | In progress | In
review | Done` per task and nothing finer, so any percentage would be invented.

### Current focus and blockers

- **T-0003 (Minikube dev env) — In progress; first cluster run 2026-08-06.** **AC2 and AC4 verified**
  (six deployments Available, six images from `versions.env`); AC1's addon half verified, create path
  not exercised; **AC3 verified in substance only** — 200 with the cert validated against the mkcert
  CA, reached via `port-forward` because the rootless node IP is unroutable. Cost **seven manifest
  fixes**; three of five services could not previously start. Remaining work needs a rootful driver or
  KVM, and macOS for macOS.
- **T-0007 (storage benchmark) — Done 2026-08-06; EP-3 closed.** **ADR-0033 Accepted**: live bare repos
  stay on block volumes because SeaweedFS-FUSE's `rename()` is not atomic and git needs it for every ref
  update (36/428 concurrent ref reads missed a ref that always existed; block 0/229; zero rename errors,
  so rename works but is not atomic). **ADR-0016 was not amended** and invariant 7's escape clause is
  discharged. The T-0010 gate is lifted. Evidence: `governance/docs/bench/T-0007/`; harness
  `make bench-storage`. Non-blocking follow-up: re-measure the latency ratios on a real cluster once
  T-0003 is verified — the correctness verdict does not need it.
- **T-0004 (tenancy + RLS)** — depends on T-0003. The RLS baseline in `deploy/dev/postgres.yaml`
  creates a non-superuser `gitfrok_app` role because RLS never binds a superuser; consumers must use
  it or the policy is inert.
- **T-0020 (contract schema gate, EP-9) — Done 2026-08-06.** `buf lint` + `buf breaking` (baseline:
  tip of `main`, category `FILE`) are required in governance CI; `make codegen-check` requires every
  consumer's generated tree to match its pinned contracts. Both ride inside already-required check
  contexts, so they block. AC5 was amended: per-consumer codegen gating needs the ADR-0027/0028
  generated-type publishing follow-up, so the check sits at the composition boundary and a
  hand-edited `gen/` is caught at the pin bump rather than in the consumer's own PR.

### Known governance gaps

Items 1–3 are tracked in PRD §12 — not invented here. Item 4 is observed in the tree and said so:

1. No Phase-1/2/3 plan files — later phases are sequenced only by what individual task files state,
   and only T-0018 states dependencies (PRD §12.2 open item 1).
2. Phase-2 and Phase-3 requirements (`PR-13`…`PR-23`) have no epics, specs or tasks yet (PRD §12.1).
3. Per-consumer codegen gating is still impossible: each consumer's `buf.gen.yaml` reads
   `../governance/contracts`, which exists only in this composition, so freshness is gated in the
   super-repo instead. Needs the generated-type publishing follow-up in ADR-0027/0028. *(The older
   gap here — a contract-schema check required in four repos that existed in none — was resolved by
   ADR-0032 + T-0020 on 2026-08-06, and `ci-gates.md`'s rows corrected with it.)*
4. `ZITADEL_IMAGE` is pinned to `:latest`, which is not a pin — `check-dev-images.sh` warns on it.
   This one is observed in the tree, not a PRD §12 item.

*(The phase-0 plan gap closed 2026-08-06: it now carries T-0020 as workstream 10 and attributes each
half of its CI exit line to a workstream. PRD §12.2 item 4 resolved with it.)*

## Documents by purpose

**Decisions & contracts** — `governance/docs/adr/` (SoT; supersede, never edit an Accepted ADR),
`governance/contracts/` (additive-only within v1), `governance/policies/` (deny-by-default).

**Product** — `governance/docs/product/PRD.md`: `PR-#` requirements per phase, §7 non-goals
(enforceable scope), §10 GA definition (Phase-3 exit **plus** SOC 2 Type II), §12 open questions.

**Process** — `agdd.md` (the framework, ADR-0028), `agentic-sdlc.md` (the per-task loop),
`definition-of-done.md` (what Done means). Human gates: Proposed ADRs, spec approval, pin bumps.

**Enforcement** — `make verify` (dep direction, version floors, dev image pins), `make lint-shell`,
`make bench-storage` (T-0007 storage probes; not a gate — an experiment),
`make codegen-check` (generated trees match the pinned contracts, T-0020),
per-submodule CI, `scripts/apply-rulesets.sh check` (ADR-0031 drift), `governance/scripts/check-docs.sh`.

**Dev environment** — `deploy/dev/README.md` is the honest account of what works and what is
unverified; `ADR-0024` is the decision behind it.
