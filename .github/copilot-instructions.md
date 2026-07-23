# Copilot instructions

This repo uses **AGDD** (AI-Agent Governance-Driven Development). **Read `/AGENTS.md` and
`/governance/AGENTS.md` first — they are authoritative.** Governance (`/governance/docs/`) is the
Source of Truth: ADRs, specs, invariants (1–25), `contracts/`, `policies/`.

Rules: work inside a single submodule per change; dependency direction is one-way
(`webfrontend → bff → backend → governance`); spec-first + TDD; new decision → a Proposed ADR in
governance; API change → a governance PR first. See `/governance/docs/process/agdd.md`.
