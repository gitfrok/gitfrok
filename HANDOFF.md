# Agent handoff pack

This repo is ready for autonomous coding agents under **AGDD** (ADR-0028). Every repo carries a
complete pack so any agent picks up the same rules. **`governance/` is the Source of Truth (ADR-0001)
for every decision, status and spec below — if this file ever disagrees with it, governance is right
and this file is stale.** Read this file first for where a session left off; read governance for why.

## Where to look

| You want to… | Read |
|---|---|
| pick up a handed-over session | this file |
| deploy or run the dev cluster | [`deploy/MVP-RUNBOOK.md`](deploy/MVP-RUNBOOK.md) (ordered steps), then [`deploy/dev/README.md`](deploy/dev/README.md) (per-manifest detail) |
| understand **what** the product must do | `governance/docs/product/PRD.md` |
| understand **why** it is built this way | `governance/docs/adr/` — the SoT; index in its `README.md` |
| pick up a task | `governance/docs/tasks/` — one file per task, its own `Status:` + `Repo(s):` |
| see phase intent, exit criteria, sequencing | `governance/docs/roadmap/README.md`, `docs/plans/`, `docs/backlog/README.md` |
| know the rules before committing | `governance/docs/agents/invariants.md` (25 constraints), then `governance/AGENTS.md` |
| know how work is executed | `governance/docs/process/agdd.md`, `agentic-sdlc.md`, `definition-of-done.md` |

**Reading order for a new agent:** `AGENTS.md` (this repo) → `governance/AGENTS.md` →
`governance/docs/agents/invariants.md` → the task's spec and ADRs.

## Where the work stands (2026-08-11)

**Phase 0 is Closed. Every Phase-1 task — T-0010…T-0018 plus T-0021 — is Done.** T-0018 was the last
of them, closed 2026-08-11 with 23 of its 24 acceptance criteria met and AC19 — the **evidence-pack**
criterion — formally moved to Phase 2, because no evidence-pack surface exists yet to satisfy it.

**Phase 1 is Complete, closed 2026-08-11** by governance #130 — `docs/plans/phase-1-mvp.md` and
`docs/roadmap/README.md` both read **Complete (2026-08-11)**:

| Exit criterion | State |
|---|---|
| all Phase-1 tasks Done | **met** — T-0018 was the last |
| the end-to-end Minikube scenario passes | **met except two infrastructure-bound steps** — the full MR flow was verified live 2026-08-11 and host DNS is closed on the verified host (`make dev-smoke` green by name); CI dispatch and the durability-quorum/failover demonstration are recorded as limits of this host, not as open code work |
| CI gates green per `ci-gates.md` | **met on every merged PR**, with the two skip-without-infrastructure gaps that file records |

The two remaining limits belong to T-0003's cluster lane, and neither is missing code:

1. **No gVisor RuntimeClass under rootless podman**, so CI dispatch is unconfigured in the dev
   cluster. The sandbox model and the K8s Job path are implemented. Recorded against T-0017.
2. **One git node**, so the durability quorum and failover promotion cannot be demonstrated in the
   cluster. Both are proved by T-0012's tests and T-0018's two-node integration suite; what is
   missing is a second physical node and an attached volume.

Two earlier blockers are closed. **Host DNS** is wired on the verified host — dnsmasq plus
systemd-resolved answer `*.gitsaas.test` at the loopback, and it stays a manual root step by design
(`dev-up.sh` prints the snippet, it does not apply it). **The object tier** is wired to the S3
adapter, `dev-up` creates its bucket, and backend's live suite passes against the cluster; ADR-0050's
FUSE mount cannot propagate to the node on this driver — the measurement is in `deploy/dev/README.md`.
Database migrations are still applied by hand (runbook step 4); that is a runbook ergonomic, not an
exit criterion.

**Next work is Phase 2** — see `governance/docs/roadmap/README.md` §Phase 2. It has no plan file,
epics or tasks yet, so the first move is a plan under `governance/docs/plans/`, not code.

**Start at [`deploy/MVP-RUNBOOK.md`](deploy/MVP-RUNBOOK.md)** if the task is to get something running.
Start at `governance/docs/plans/phase-1-mvp.md` if the task is to decide what to build next.

### Known gaps, beyond the two Phase-1 limits above

Tracked in PRD §12 except the last, which is observed in the tree:

1. No Phase-2/3 plan files — those phases are sequenced only by what individual task files state.
2. Phase-2/3 requirements (`PR-13`…`PR-23`) have no epics, specs or tasks yet.
3. Per-consumer codegen gating is impossible: every consumer's `buf.gen.yaml` reads
   `../governance/contracts`, a sibling checkout that exists only in this composition, so freshness
   is gated at the super-repo pin bump instead of in each consumer's own CI.
4. **Backend integration tests don't run in CI.** T-0004's isolation proofs and T-0006's tamper
   proofs both skip without `TEST_DATABASE_URL`, so two tasks' central claims rest on evidence that
   exists only in a local run.
5. **Two sources of schema truth.** `deploy/dev/postgres.yaml`'s ConfigMap creates the T-0004 tenancy
   schema independently of the migration files under `backend/` that a real deployment would run.
   Both currently agree; nothing enforces that they keep agreeing.

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

**ADR-0051 (Accepted 2026-08-11)** follows from wiring that mount into `deploy/dev`: producing a FUSE
mount in Kubernetes requires a privileged container somewhere, because kubelet rejects
`mountPropagation: Bidirectional` on anything unprivileged. It proposes one privileged DaemonSet per
node rather than a sidecar per consumer. Running it found that this driver never propagates the mount
to the node at all — so the dev cluster runs the S3 adapter ADR-0050 decision 6 keeps for exactly
that case, and the DaemonSet is opt-in behind `MOUNT_DAEMONSET=1`.

Two more defects came out of that, both found only by running it: the filer's **gRPC port 18888** was
never exposed by the Service, so the mount client retried forever against a healthy filer; and the S3
credentials were attached to SeaweedFS's `anonymous` identity, which meant **the gateway served every
object to unsigned requests**. Both fixed.

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
