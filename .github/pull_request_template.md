# Super-repo PR (submodule pointer bump)

The super-repo stores **pinned submodule commits only** (ADR-0027, invariant 25).

## Checklist
- [ ] This PR only **bumps submodule pointers** (no in-place edits to submodule paths).
- [ ] Every referenced submodule commit is **merged** on its own repo's default branch.
- [ ] Linked submodule PRs: <governance #… / backend #… / bff #… / webfrontend #…>
- [ ] Cross-repo order followed: governance (additive) → consumers → this bump (ADR-0027).
- [ ] Dependency direction intact: `webfrontend → bff → backend → governance` (invariant 22).
- [ ] `make bootstrap` succeeds from a clean clone.
