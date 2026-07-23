# CLAUDE.md (super-repo)

**Read `AGENTS.md` (this repo) then `governance/AGENTS.md` first.** Governance is the SoT.

- Determine the target submodule from the task's `Repo(s):` field; work inside that repo; never
  span two submodules in one commit (ADR-0027, invariants 21–25).
- Follow AGDD: spec-first, TDD, boundaries enforced by fitness functions + CI.
- New decision → Proposed ADR in `governance/` and stop. API change → governance PR first.
