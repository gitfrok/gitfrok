# Agent handoff pack

This repo is ready for autonomous coding agents under **AGDD** (ADR-0028). Every repo carries a
complete pack so any agent picks up the same rules.

## Where the work stands (2026-08-11)

**Phase 0 is Closed. Every Phase-1 task — T-0010…T-0018 plus T-0021 — is Done.** T-0018 was the last
of them, closed 2026-08-11 with 23 of its 24 acceptance criteria met and AC19 (bidirectional sync
back to the source) formally moved to Phase 2.

Phase 1 is **not** exited. Its first exit criterion is met; the second is not, and that is the whole
of the remaining work:

| Exit criterion | State |
|---|---|
| all Phase-1 tasks Done | **met** |
| the end-to-end Minikube scenario passes | **not met** — four blockers, none of them missing code |
| CI gates green per `ci-gates.md` | **met on every merged PR**, with the two skip-without-infrastructure gaps that file records |

The four blockers, in the order they are cheapest to close:

1. **No object tier is wired into any deployment**, so the dev cluster serves no LFS. Wiring
   `GITFROK_SEAWEEDFS_MOUNT` per ADR-0050 is a super-repo manifest change — see
   [`deploy/MVP-RUNBOOK.md` step 6](deploy/MVP-RUNBOOK.md).
2. **Database migrations are applied by hand** (runbook step 4).
3. **No gVisor RuntimeClass under rootless podman**, so CI dispatch is unconfigured in the dev
   cluster. Recorded against T-0017.
4. **One git node**, so the durability quorum and failover promotion cannot be demonstrated in the
   cluster. Both are proved by T-0012's tests and T-0018's two-node integration suite; what is
   missing is a second physical node and an attached volume — T-0003's cluster lane.

**Start at [`deploy/MVP-RUNBOOK.md`](deploy/MVP-RUNBOOK.md)** if the task is to get something running.
Start at `governance/docs/plans/phase-1-mvp.md` if the task is to decide what to build next.

### What landed most recently, and why it matters

**ADR-0050 (Accepted 2026-08-11)** narrows ADR-0020: LFS objects, CI artifacts and container-image
blobs come from a **SeaweedFS FUSE mount**, not the S3 gateway. ADR-0033 is untouched — live bare
repositories stay on block volumes, and `git-storaged` refuses a FUSE repository root (invariant 7).
Because a mount has no signed URLs, SPEC-0023's pre-signed decision is superseded for that tier:
transfers proxy through the plane under `repo.lfs.read` / `repo.lfs.write`, and every read is
verified against the digest in the object's name before a byte reaches a client.

Three real defects were found by proving T-0018's AC1 and AC2 against live infrastructure rather than
fakes. They are worth knowing because each one had passed review:

1. `git fetch` with no refspec landed objects and tags but **no branches** — imports reported success
   and produced repositories nothing could reach.
2. `authz.rego` granted `repository.import` to **no role**, so every import in a real deployment was
   denied. The acceptance criterion had "passed" only because nobody could import.
3. SeaweedFS answers **200 to a PUT into a bucket that does not exist**. The object tier now reads
   back before acknowledging a write.

The lesson the record keeps: a test against a fake proves the control flow, not the claim.

## What each tool reads
| Tool | File(s) it reads (present in every repo) |
|---|---|
| **Claude Code** | `CLAUDE.md` → points to `AGENTS.md` |
| **Codex** | `AGENTS.md` |
| **OpenCode** | `AGENTS.md` + `opencode.json` |
| **Cursor** | `AGENTS.md` + `.cursor/rules/agdd.mdc` (super-repo) |
| **GitHub Copilot** | `.github/copilot-instructions.md` (super-repo) |
| **Any other agent** | `AGENTS.md` (the cross-tool standard) |

## Golden path for an agent
1. `make bootstrap` (clones submodules, shows toolchain floors).
2. Read `governance/AGENTS.md` + `governance/docs/agents/{context,invariants}.md`.
3. Read the framework: `governance/docs/process/agdd.md` (+ `agentic-sdlc.md`, `spec-driven-development.md`, `tdd.md`).
4. Pick a task: `governance/docs/roadmap` → `backlog` → `tasks/T-####.md` (note its `Repo(s):`).
5. Read the task's **spec** (`governance/docs/specs/`) + cited **ADRs** + `ci-gates.md` + DoD.
6. Work **inside the one target submodule**; spec-first, TDD; PR there; obey invariants 1–25.

## The five hard boundaries (see invariants)
- Decisions/contracts/policies live **only** in `governance`.
- Dependency direction is one-way: `webfrontend → bff → backend → governance`.
- One commit never spans two submodules; the super-repo stores **pinned** commits.
- New decision → **Proposed ADR + stop**. New behavior → **spec first**.
- Every query tenant-scoped; authZ via the PDP; audit is append-only.

## Merging, and the one rule that has no workaround

Every repo requires **four-eyes review**: an approving review from an account other than the author,
owners included (ADR-0031, since 2026-08-05). There is no `--admin` path around it and taking one
would be a governance violation, not a shortcut. After a PR merges, delete the branch locally *and*
on the remote — squash merges make `git branch -d` refuse, so use `-D` — then `git remote prune
origin`. These repos do not have GitHub's delete-branch-on-merge setting enabled.

Submodule pins move in their own super-repo commit, after the submodule PR merges, never with it.
