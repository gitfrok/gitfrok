# Agent handoff pack

This repo is ready for autonomous coding agents under **AGDD** (ADR-0028). Every repo carries a
complete pack so any agent picks up the same rules.

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
