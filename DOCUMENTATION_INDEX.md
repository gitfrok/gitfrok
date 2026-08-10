# Gitfrok — Documentation Index

> **Derived document — not a source of truth.** A map of where things live, plus statuses copied from
> `governance/`, which is authoritative (ADR-0001; super-repo `AGENTS.md` rule 4). If this disagrees
> with governance, governance is right.
>
> **Synced from governance `main` on 2026-08-11, at governance PR #119 — which is not yet merged.**
> The super-repo pin is still `62f1c79`, which predates it: at that commit T-0018 reads *In
> progress*. The statuses below are therefore ahead of the pin **on purpose and only until #119
> merges**, at which point this file's pin bump lands with the merged commit. Governance decides;
> if #119 changes in review, this file follows it rather than the other way round.

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
| see Phase-0 sequencing | `governance/docs/plans/phase-0-foundations.md` — all ten workstreams |
| see Phase-1 sequencing and what remains | `governance/docs/plans/phase-1-mvp.md` |
| **deploy the MVP** | [`deploy/MVP-RUNBOOK.md`](deploy/MVP-RUNBOOK.md) — clean host to running cluster, and what that cluster cannot prove |
| pick up a handed-over session | [`HANDOFF.md`](HANDOFF.md) |
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
│   ├── scripts/                      check-docs.sh · check-contracts.sh · check-policies.sh
│   └── docs/
│       ├── adr/                      0001…0034 + README index — decisions, immutable once Accepted
│       ├── bench/T-0007/            storage benchmark evidence (raw JSON + reading)
│       ├── product/PRD.md            product requirements (PR-#); restates ADRs, never decides
│       ├── specs/                    SPEC-0001…SPEC-0011 + _template.md
│       ├── roadmap/README.md         four phases + exit criteria
│       ├── plans/                    README.md + phase-0-foundations.md + phase-1-mvp.md
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
├── deploy/MVP-RUNBOOK.md             clean host → running MVP; the manual steps and the real limits
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
│   ├── check-codegen-fresh.sh        fitness: each consumer's gen/ matches its pin (T-0020)
│   ├── check-policy-composition.sh   fitness: the real authz path across repos (T-0005)
│   ├── testdata/policy-composition/  the two harness programs that check runs
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
| 0 — Foundations | T-0001…T-0009 + T-0020 (10) | **all ten** | — |
| 1 — MVP | T-0010…T-0018 + T-0021 (10) | **all ten** | — |
| 2 — the wedge | none defined | — | backlog: *to be expanded*, plus T-0018's AC19 (the evidence-pack criterion — SPEC-0011 AC14, ADR-0029 §4), moved here 2026-08-10 and recorded under EP-8 |
| 3 — BYO | none defined | — | backlog: *to be expanded* |

**Every task in both defined phases is Done, and Phase 1 has still not exited.** Its second exit
criterion — one end-to-end scenario in Minikube — is open, and nothing blocking it is missing code:
no object tier is wired into any deployment, migrations are applied by hand, rootless podman has no
gVisor RuntimeClass, and one node cannot demonstrate a quorum or a failover.
[`deploy/MVP-RUNBOOK.md`](deploy/MVP-RUNBOOK.md) is the operational account;
`governance/docs/plans/phase-1-mvp.md` is the authoritative one.

**EP-0 (scaffolding & process) closed 2026-08-04.** The merge gates now block rather than merely run
(ADR-0031, applied to all five repos), and since 2026-08-05 four-eyes review binds owners too.

No percentage-complete figure appears here on purpose: governance records `Todo | In progress | In
review | Done` per task and nothing finer, so any percentage would be invented.

### Current focus and blockers

- **T-0018 (repository & review-history import) — Done 2026-08-11; Phase 1's last task.** 23 of 24
  criteria met and AC19 moved to Phase 2. AC1 and AC2 are proved against a live SeaweedFS gateway, an
  HTTPS source, a block-backed filesystem and a two-node durability quorum — not against fakes, which
  is how three real defects surfaced: `git fetch` with no refspec landed **no branches**, `authz.rego`
  granted `repository.import` to **no role**, and SeaweedFS answers **200 to a PUT into a bucket that
  does not exist**. **ADR-0050 (Accepted)** narrows ADR-0020: LFS, CI artifacts and image blobs come
  from a SeaweedFS FUSE mount, transfers proxy, and every read is verified against the digest in the
  object's name. ADR-0033 is unchanged — live repos stay on block volumes.
- **T-0003 (Minikube dev env) — Done; AC1–AC4 verified.** AC1's create path completed 2026-08-08
  after three defects (`fs.inotify.max_user_instances`, an orphaned podman volume, and a missing
  `--container-runtime`); AC3 is verified over the real ingress under rootless podman with no
  `port-forward` — the earlier conclusion that it needed a rootful driver or KVM **was wrong** and is
  retracted, it needed the node's 80/443 published to the host. AC4 closed 2026-08-09 on a real macOS
  runner. Two residuals are named rather than closed: host DNS is still a manual root step, and a
  *cluster bring-up on a Mac* needs a hypervisor no hosted runner has.
- **T-0007 (storage benchmark) — Done 2026-08-06; EP-3 closed.** **ADR-0033 Accepted**: live bare repos
  stay on block volumes because SeaweedFS-FUSE's `rename()` is not atomic and git needs it for every ref
  update (36/428 concurrent ref reads missed a ref that always existed; block 0/229; zero rename errors,
  so rename works but is not atomic). **ADR-0016 was not amended** and invariant 7's escape clause is
  discharged. The T-0010 gate is lifted. Evidence: `governance/docs/bench/T-0007/`; harness
  `make bench-storage`. Non-blocking follow-up: re-measure the latency ratios on a real cluster once
  T-0003 is verified — the correctness verdict does not need it.
- **T-0004 (tenancy + RLS) — Done 2026-08-06.** All four SPEC-0001 criteria verified against a real
  Postgres with RLS enforced. `platform/db` wraps `pgxpool` so no unscoped query exists, scopes each
  transaction with `SET LOCAL app.tenant_id`, and **refuses a SUPERUSER/BYPASSRLS role** — without
  that guard every isolation test would pass against a database enforcing nothing. Two limits are
  recorded in the task: AC3 cannot see a cross-tenant UPDATE/DELETE (RLS makes those rows invisible,
  so nothing errors), and the audit routing key is provisional until **T-0006** adopts or renames it.
- **T-0020 (contract schema gate, EP-9) — Done 2026-08-06.** `buf lint` + `buf breaking` (baseline:
  tip of `main`, category `FILE`) are required in governance CI; `make codegen-check` requires every
  consumer's generated tree to match its pinned contracts. Both ride inside already-required check
  contexts, so they block. AC5 was amended: per-consumer codegen gating needs the ADR-0027/0028
  generated-type publishing follow-up, so the check sits at the composition boundary and a
  hand-edited `gen/` is caught at the pin bump rather than in the consumer's own PR.

- **T-0006 (audit log) — Done 2026-08-06.** Append-only enforced by the database (the app role has
  INSERT and SELECT only; triggers reject mutation even for the owner), SHA-256 chain over a
  length-prefixed canonical form, four tamper modes caught and reported distinctly. **One limit is
  tested, not hidden:** truncating the head of a chain is undetectable without an anchor outside the
  database, which ADR-0007 does not decide.

### Known governance gaps

Items 1–3 are tracked in PRD §12 — not invented here. Item 4 is observed in the tree and said so:

1. No Phase-2/3 plan files — those phases are sequenced only by what individual task files state.
   *(The Phase-1 half of PRD §12.2 open item 1 is closed: `governance/docs/plans/phase-1-mvp.md`
   exists and carries the workstreams, the critical path and the exit criteria.)*
2. Phase-2 and Phase-3 requirements (`PR-13`…`PR-23`) have no epics, specs or tasks yet (PRD §12.1).
3. Per-consumer codegen gating is still impossible: each consumer's `buf.gen.yaml` reads
   `../governance/contracts`, which exists only in this composition, so freshness is gated in the
   super-repo instead. Needs the generated-type publishing follow-up in ADR-0027/0028. *(The older
   gap here — a contract-schema check required in four repos that existed in none — was resolved by
   ADR-0032 + T-0020 on 2026-08-06, and `ci-gates.md`'s rows corrected with it.)*
4. **Backend integration tests do not run in CI.** T-0004's isolation proofs and T-0006's tamper
   proofs both skip without `TEST_DATABASE_URL`, so two tasks' central claims rest on evidence that
   exists only in a local run. A Postgres service container in backend CI would close it. Observed in
   the tree, not a PRD §12 item — and now the largest of these gaps.
5. **Nothing applies the migrations.** `platform/db/migrations` and `modules/audit/.../migrations`
   are hand-applied to the dev cluster; `deploy/dev/postgres.yaml` still creates the tenancy schema
   independently. Two sources of schema truth, across two schemas.

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

**Two gates live only in the super-repo**, because each spans repos that cannot see one another:
`check-codegen-fresh.sh` (T-0020 — every consumer's `gen/` follows from the pinned contracts) and
`check-policy-composition.sh` (T-0005 — the real authorization path, bff PEP → gRPC → backend PDP →
`governance/policies`). Each repo is green in isolation while the composition is broken; these are
where that is caught.

**Dev environment** — [`deploy/MVP-RUNBOOK.md`](deploy/MVP-RUNBOOK.md) is the ordered path from a
clean host to a running MVP, including the manual root steps and the four things the dev cluster
cannot demonstrate. `deploy/dev/README.md` is the per-manifest account of what works and what is
unverified; `ADR-0024` is the decision behind both.
