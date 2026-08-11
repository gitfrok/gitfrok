# Handoff — start here

One page for an incoming session. **`governance/` is the Source of Truth (ADR-0001);** where this
file disagrees with it, governance is right and this file is stale. This file says *where work
stands*; governance says *what and why*.

## Navigate

| You want | Read |
|---|---|
| the rules before editing anything | `AGENTS.md` (this repo) → `governance/AGENTS.md` → `governance/docs/agents/invariants.md` |
| what the product must do | `governance/docs/product/PRD.md` (`PR-#` requirements, phases, non-goals) |
| why it is built this way | `governance/docs/adr/` — index in its `README.md` |
| a task to pick up | `governance/docs/tasks/` — one file each, own `Status:` and `Repo(s):` |
| phase intent and exit criteria | `governance/docs/roadmap/README.md`, `governance/docs/plans/` |
| how work is executed | `governance/docs/process/agdd.md`, `agentic-sdlc.md`, `definition-of-done.md`, `ci-gates.md` |
| to run the dev cluster | [`deploy/MVP-RUNBOOK.md`](deploy/MVP-RUNBOOK.md) — ordered steps |
| per-manifest detail and the defect record | [`deploy/dev/README.md`](deploy/dev/README.md) |

## Where work stands (2026-08-12)

**Phase 0 Closed. Phase 1 Complete (2026-08-11, governance #130.)** Every Phase-1 task —
T-0010…T-0018, T-0021 — is Done; T-0018 closed with 23 of 24 acceptance criteria and AC19
(evidence pack) moved to Phase 2. Exit criteria per `governance/docs/plans/phase-1-mvp.md`: tasks
Done **met**; CI gates **met** on every merged PR with the skip-without-infrastructure gaps
`ci-gates.md` records; the end-to-end scenario **met except two infrastructure-bound steps**, both
recorded as limits of this host against T-0003's cluster lane, neither missing code:

1. **No gVisor RuntimeClass under rootless podman** — CI dispatch is unconfigured in the dev cluster
   (T-0017). The sandbox model and the K8s Job path are implemented.
2. **One git node** — the durability quorum and failover promotion cannot be *demonstrated* there.
   Both are proved by T-0012's tests and T-0018's two-node integration suite.

**Next work is Phase 2** (`governance/docs/roadmap/README.md`). It has no plan file, epics or tasks
yet, so the first move is a plan under `governance/docs/plans/` — not code.

## Known gaps

1. Phase-2/3 have no plan files; their requirements (`PR-13`…`PR-23`) have no epics, specs or tasks.
2. **Backend integration tests do not run in CI** — T-0004's isolation proofs and T-0006's tamper
   proofs skip without `TEST_DATABASE_URL`, so two tasks' central claims rest on a local run only.
3. **Two sources of schema truth** — `deploy/dev/postgres.yaml`'s ConfigMap creates the T-0004
   tenancy schema independently of `backend/`'s migration files. They agree; nothing enforces it.
4. Host DNS for `*.gitsaas.test` is the one dev step nothing automates — it needs root, so `dev-up.sh`
   prints the snippet rather than applying it. Migrations and the Zitadel OIDC client are converged by
   `scripts/dev-provision.sh`.
5. Per-consumer codegen gating is impossible: each consumer's `buf.gen.yaml` reads
   `../governance/contracts`, a sibling checkout that exists only in this composition, so contract
   freshness is gated at the super-repo pin bump rather than in the consumer's own CI.
6. First-party images are pinned by tag, not digest (ADR-0035 decision 4).

## The storage picture, in one place

- **Live bare repositories: block volumes** (ADR-0033). `git-storaged` refuses a FUSE repository
  root outright (invariant 7).
- **LFS, CI artifacts, image blobs: ADR-0050** puts them on a SeaweedFS FUSE mount, produced by
  ADR-0051's privileged node DaemonSet. That mount **does not propagate on this driver**, so the dev
  cluster runs the S3 adapter ADR-0050 decision 6 keeps for that case. Measured, not assumed —
  `deploy/dev/README.md`.
- **Transfers proxy through the plane** under `repo.lfs.read` / `repo.lfs.write`, and every read is
  verified against the digest in the object's name (SPEC-0023, as amended by ADR-0050).

## The lesson the record keeps

A test against a fake proves the control flow, not the claim. Proving T-0018's AC1 and AC2 against
live infrastructure found three defects that had all passed review — a `git fetch` with no refspec
that landed no branches, so imports produced repositories nothing could reach; an `authz.rego` that
granted `repository.import` to no role, so AC20 had "passed" only because nobody could import; and a
SeaweedFS PUT into a missing bucket answering 200 and keeping nothing. Wiring the object tier found a
fourth: the S3 gateway served every object to unsigned requests, because the credentials sat on
SeaweedFS's `anonymous` identity. Prefer a live proof for anything an acceptance criterion rests on —
and see `deploy/dev/README.md` for the eleven separate defects that only a real cluster bring-up
exposed.

## Hard rules

- Decisions, contracts and policies change **only** in `governance/` (invariants 21–25).
- Dependency direction is one-way: `webfrontend → bff → backend → governance`.
- **One commit never spans two submodules.** The super-repo stores **pins**, never in-place edits to
  a submodule path; pins move in their own commit after the submodule PR merges.
- New decision → **Proposed ADR and stop.** New behaviour → **spec first.** API change → governance
  PR first, additive only.
- Every query tenant-scoped; authZ through the PDP; audit append-only.
- **Four-eyes review is mandatory** — an approving review from an account other than the author,
  owners included (ADR-0031). There is no `--admin` path around it.
- After a PR merges, delete the branch locally (`-D`; squash merges make `-d` refuse) **and** on the
  remote, then `git remote prune origin`. Delete-branch-on-merge is not enabled on these repos.

## Tool entry points

`CLAUDE.md` → `AGENTS.md` for Claude Code; `AGENTS.md` for Codex, OpenCode (+ `opencode.json`) and
any other agent; `.cursor/rules/agdd.mdc` for Cursor; `.github/copilot-instructions.md` for Copilot.
All of them are **generated** from `governance/canonical/agent-surfaces/` by
`scripts/gen-agent-surfaces.sh` (ADR-0037) — edit the canonical source and regenerate; CI fails on
drift.
