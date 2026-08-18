# Handoff — start here

One page for an incoming session or a new agent. **`governance/` is the Source of Truth (ADR-0001);**
where this file disagrees with it, governance is right and this file is stale. This file says *where
work stands and how to run it*; governance says *what and why*. Verified against the tree on
2026-08-18.

## Navigate

| You want | Read |
|---|---|
| the rules before editing anything | `AGENTS.md` (this repo) → `governance/AGENTS.md` → `governance/docs/agents/invariants.md` |
| what the product must do | `governance/docs/product/PRD.md` (`PR-#` requirements, phases, non-goals) |
| why it is built this way | `governance/docs/adr/` — index in its `README.md` |
| a task to pick up | `governance/docs/tasks/` — one file each, own `Status:` and `Repo(s):` |
| phase intent and exit criteria | `governance/docs/roadmap/README.md`, `governance/docs/plans/` |
| how work is executed | `governance/docs/process/agdd.md`, `agentic-sdlc.md`, `definition-of-done.md`, `ci-gates.md` |
| what a review already found | `phase-2-code-review.md`, `phase-2-code-review-wave2.md`, `phase-3-code-review.md`, `phase-3.1-code-review.md`, `phase-3.1-plan-review.md` (this repo's root) |
| how the UI must look and behave | `governance/docs/adr/0069-cvd-first-design-system.md` → `docs/specs/SPEC-0047-*` (binding token table) |
| which surfaces get built next, and why some may not start | `governance/docs/adr/0070-full-product-surface.md` (Proposed) → `docs/plans/phase-4-full-product-surface.md` |
| to run the dev cluster | [`deploy/MVP-RUNBOOK.md`](deploy/MVP-RUNBOOK.md) — ordered steps |
| per-manifest detail and the defect record | [`deploy/dev/README.md`](deploy/dev/README.md) |

## Where work stands (2026-08-17)

Current pins — verified with `git submodule status` at super-repo `124a686`:
**governance `792e8c3`**, **backend `55db3bb`**, **bff `3b90090`**, **webfrontend `a668de5`**.
Backend and bff are untouched by Phase 4 so far; the phase has stayed in
`governance` + `webfrontend`, as Phase 3.5 did.

**Phases 0, 1 and 2 are Complete.** **Phase 3 (BYO) is implementation-complete** — its fifth exit
criterion is carried, not met: the install → self-register → upgrade → meter path has never run on a
real customer-shaped cluster; every real-cluster row of `deploy/conformance/byo-dataplane.md` reads
"not run", recorded against T-0003's cluster lane.

**Phase 3.1 is implementation-complete** (durability, custody, residency, signed operator, metering
UI) under ADR-0062…ADR-0067 and SPEC-0042…SPEC-0046, epics EP-19…EP-23, tasks T-0035…T-0044.
Final tips: governance `62075e2`→`c7cb3e8`, backend `7c05a86`→`55db3bb`, bff `1ffbb77`→`ee53bd8`→
`3b90090`, webfrontend `a1e614a`→`9dab620`→`6c8cceb`. Exit records live in
`governance/docs/tasks/`; the dependency spine is `governance/docs/plans/phase-3-byo-v2.md`.
**One task stands blocked:** T-0042 real GKE/EKS/AKS conformance — no code can unblock it; it waits
on T-0003's cluster lane. With it wait SPEC-0045 AC3 and SPEC-0039 AC8's migration proof on real
state.

**Phase 3.5 (the design system) is COMPLETE** — all ten SPEC-0047 criteria green, plan exit criteria
all ticked. It was opened and closed on 2026-08-17 under **ADR-0069** (Accepted same day), which
discharges ADR-0015's never-delivered design-system follow-up. Tasks T-0045…T-0048, epic EP-24,
webfrontend only — backend and bff were never touched.

What changed, beyond colours: `webfrontend/src` had **no tokens at all** (232 hex literals across 16
files) and the diff shipped the red/green encoding brand v2 exists to reject. Now every colour
resolves from `src/styles/tokens.css`, `scripts/check-hex-literals.mjs` fails the build on a literal
anywhere else, and the diff's meaning lives in text markers rather than tint. Severity stopped being
a red-to-green heat ramp — under deuteranopia that made "low" and "critical" the same badge.

**The AC10 capture run earned its place on first use.** It found that Astro renders style-object
values verbatim, so `gap: 24` shipped as `gap:24` and the browser dropped it — **197 spacing values
across nine files were being silently discarded**. No DOM assertion could see it; a grayscale
screenshot could. Fixed, with a guard test.

**Phase 4 (the full product surface) is OPEN** — planned 2026-08-18 under **ADR-0070**
(*Proposed*), plan `governance/docs/plans/phase-4-full-product-surface.md`, epics EP-25…EP-27.

It exists because three inventories of the web surface disagree: the BFF serves **eighteen routes
and ten have a UI**, the PRD requires twenty-three `PR-#` rows and several render nowhere, and the
`./UI` prototype shows a larger product than either. ADR-0070 sets a **route-before-pixel** ordering
law — no UI before the BFF route it reads, no route before the backend port it shapes — and tiers
the work: **Tier A** (route exists, UI does not: MR actions, code search, evidence packs, auditor
grants; `webfrontend` only, may start now), **Tier B** (PRD requires it, no route serves it:
repository list, blame/history, pipelines, policy authoring; backend first), **Tier C** (the
prototype shows it, nothing requires it; blocked until ADR-0070 is Accepted and the PRD carries
PR-24…PR-32).

**Tier A is COMPLETE** (T-0049, T-0050, T-0051, T-0052 — EP-25 closed). Every BFF route that had no
UI now has one. **ADR-0070 was Accepted 2026-08-18** and the PRD carries a Phase 4 table with
PR-24…PR-32, so Tier B and Tier C are unblocked at the requirement level. Tier C keeps its second
gate: issues, releases, repository settings and the admin area each need their own Proposed ADR
before a spec, because each is a bounded context under ADR-0022 rather than a screen.

**T-0049** (webfrontend `6d61827`, SPEC-0048 AC1–AC11 proven): a merge request can now be
**opened, reviewed and merged from the browser**. PR-9's write half had been served by the BFF since
T-0016 and reached by `curl` and nothing else. Two traps were found before any code was written, and
both would have produced a control that silently never works: **the MR writes are form-encoded**
(a JSON body reaches `r.ParseForm()` as no fields), and **the disposition must travel as the
protobuf enum name** — `codereviewv1.ReviewDisposition_value["APPROVE"]` is a Go map miss that
yields UNSPECIFIED with no error. Both are pinned by test. SPEC-0048's AC8 was **amended before
implementation**: its ≥ 25 L\* threshold between two status tones is unsatisfiable, because every
status ink in `tokens.css` sits between L\* 38 and L\* 46 — ADR-0069 law 1 governs foreground
against background, law 2's redundant channel separates one status from another.

**T-0051 and T-0052** (webfrontend `1141bc5`, SPEC-0050 and SPEC-0051 AC1–AC11 each): evidence packs
and auditor grants, landed together because they are one surface. The shell gains its first new
destination since the design system: **Compliance**, pointing at the evidence-pack page rather than
at a `/compliance` index, because an index would be a nav destination with no BFF route behind it.

Three traps, all recorded in the specs before code:

- **`response.ok` means nothing on the pack stream.** `getPack` writes `200` and its content type on
  the FIRST chunk, so a failure after that returns a truncated body with a success status.
  `final_chunk` is the only authority, and `readPackStream` treats truncation as the **default** that
  has to be cleared rather than a condition to be detected.
- **The server may bound an issued grant's expiry**, so the issue relay does not carry the grant
  through its redirect — the list re-reads it, because the server's record is the only place that
  value is true.
- **A grant's state is never computed here.** `src/lib/grants.ts` deliberately has no function that
  turns an `expires_at` into a state; validity is read at decision time (SPEC-0033 AC7), and the stub
  carries a grant whose expiry was 2020 and whose state is `ACTIVE` to keep that honest.

**T-0050** (webfrontend `a668de5`, SPEC-0049 AC1–AC12): code search, and the sharpest empty state in
the product. Three meanings share one wire shape — *nothing matched*, *you may not see what matched*,
and *nothing is indexed* — and `SearchPage` carries no total, because SPEC-0035 AC3 makes
non-enumeration a type property. "No results found" picks one of the three and states it as fact; on
the second it tells an unauthorized reader nothing exists where something does, which is PR-19's leak
inverted. The index status narrows it, and its **empty answer is a signal rather than an error**:
`readIndexFreshness(null)` is *unknown*, `readIndexFreshness({entries: []})` is *nothing indexed*.

**Two defects surfaced during T-0050 that it did not cause, and both were live for a while:**

- **Seven pages nested a second `<main>` landmark** inside the shell's, dating from the Phase 3.5
  shell. Invalid HTML and two `main` landmarks on every rendered page. Fixed everywhere.
- **The e2e journeys asserted post-submit content against a signed-out render.** The session travels
  as a request header (Chromium accepts a `__Host-` cookie only over https) and Playwright does not
  apply those headers when the browser follows the 303 every form POST answers with. Every content
  assertion after a form submit was passing for the wrong reason. **This is a standing harness
  limit:** a submit proves the redirect, and a `page.goto` of the resulting URL proves what that URL
  renders. Do not assert content directly after a submit.

**The grayscale review earned its place a third time.** The truncated pack rendered a **"✓ Ready"
badge above the notice saying the pack was not whole**. Both strings were true — READY is the
*assembly* state, and assembly did succeed — but the badge is the most glanceable thing on the page,
so a reader who skimmed it took the pack as complete. Every test passed while it was on screen. The
notice now precedes the badge and a test asserts document order.

**The North Star deployment proof is 9/9 on this machine** — `scripts/north-star.sh`
(`make dev-north-star`): enrolment token issued via the owner-only EnrolmentService door (:9094),
dataplane self-enrolled, residency declared, usage door serving, durability across controlplane
restart, evidence pack, and git clone/push/MR/merge through the live security merge gate over mkcert
TLS. Journey table with named evidence: MVP-RUNBOOK §8b. The proof CAUGHT and fixed a real defect:
the merge gate's merge-base resolver omitted the merging actor's verified roles, storage's PDP denied
every role-less `repo.read`, and every merge failed closed — fixed test-first at backend **55db3bb**
(recorded in RUNBOOK §4a/§8b/§9). Nothing weakens: precompute stays role-less best-effort.

**The usability chain landed (2026-08-16/17) and is browser-proven.** Zitadel project roles
owner/member/reader + an owner grant for `admin@gitsaas.test` converge idempotently in
`scripts/dev-provision.sh` §2b; the ingress routes `/login`, `/callback`, `/logout` → bff
(`deploy/dev/ingress.yaml`); the dataplane runs `GITFROK_OIDC_ALLOWED_ROLES=owner,member,reader`
with the singular role claim `urn:zitadel:iam:org:project:roles` (`deploy/dev/dataplane.yaml`); the
BFF session captures roles at login (bff `3b90090`, ADR-0049 d8); the webfrontend ships sign-in /
sign-out / `/usage` nav (webfrontend `6c8cceb`). Login works in a browser and `/usage` renders the
authenticated 8-dimension view. **Phase 3.5 then rebuilt that shell on the token layer** — the nav is
now Repositories / Security / Usage, marked with `aria-current` plus weight plus a rule rather than
colour, behind a skip link. The auth affordance itself is unchanged: cookie presence is still a
presentation hint, never a decision.

## How to run it

**Host prerequisites (this machine):** minikube+podman machine running; `mkcert -install` done;
`/etc/hosts` six-host line (`hello/zitadel/s3/filer/app/git.gitsaas.test → 127.0.0.1`); `grpcurl`
installed; **`helm` absent** — `make verify`'s byo-chart *rendered* assertions skip honestly, static
assertions still bind. Say so when you report a green run.

**Daily loop (all idempotent):**

| Target | Does |
|---|---|
| `make bootstrap` | clone/sync submodules |
| `make dev-up` | converge the cluster (addons + mkcert TLS + manifests); **hard-fails if OpenBao is sealed** |
| `make dev-provision` | DB migrations + Zitadel OIDC client + role vocabulary (§2b) + login roundtrip |
| `make dev-smoke` | deployments up, 200 over real TLS at `*.gitsaas.test` |
| `make dev-north-star` | the full nine-step journey proof |
| `cd webfrontend && npm run cvd` | regenerate the 15 CVD capture artifacts (SPEC-0047 AC10) |

**Cold-restart ritual:** OpenBao quorum unseal per MVP-RUNBOOK §6a — the Shamir shares are
operator-held. **Never automate the unseal and never re-initialize** (§6a: initialize is once per
cluster, ever). Unseal must precede any consumer start.

**Dev identities:** `admin@gitsaas.test` (Zitadel, owner role on the dev tenant) · operator PAT in
secret `gitfrok-operator-pat` · enrolment token in secret `gitfrok-enrolment-token`.

**Gate matrix before you push:**

- backend: full gate chain — gofmt/vet/build/arch + the real-Postgres `-race` harness (port 15432).
- governance: `governance/scripts/check-docs.sh`, contracts and policies checks.
- webfrontend: `npx tsc --noEmit` && `npm test` (203 cases) && `npm run build`. The build is gated
  by `prebuild`: the hex-literal check plus seven suites. **`usage-regression-pins` and
  `readonly-cause` must pass UNMODIFIED** — editing one to make a change pass means the change moved
  behaviour.
- super-repo: `make verify` (includes `scripts/check-runbook.sh`) && `make codegen-check` &&
  `make surfaces-check` && `make dev-smoke`.

## Governance rules that bind every agent

Condensed from `AGENTS.md` — read it before editing anything.

- **Governance is SoT.** Decisions, contracts, policies and shared surface live only in
  `governance/` (invariants 21–25). New decision → Proposed ADR and stop; new behaviour → spec
  first; API change → governance PR first, additive only.
- **One commit never spans two submodules.** Work lands in the submodule's own repo; the super-repo
  stores **pins only** (invariant 25), bumped in their own commit after the submodule commit is on
  its `main`.
- Dependency direction is one-way: `webfrontend → bff → backend → governance`. webfrontend never
  calls backend; bff holds no business logic.
- **Honest "not run" annotations.** A row that says "not run" is worth more than a row that implies
  it passed. **Write the limit down** — every carry is recorded against the spec it bounds.
- Accepted ADRs are immutable (supersede, never edit); approved specs may be amended with the
  amendment noted in `Status:`.
- **Work lands directly on `main`** (ADR-0053, ADR-0054) — no PR gate; run the local gates first.
  A red `main` is stop-everything: the next commit fixes or reverts it.

## Open items / carried limits (never silent)

1. **T-0042 multi-cloud conformance is blocked** on T-0003's cluster lane — the sole remaining
   Phase 3.1 task, and no code can unblock it.
2. **The release-trust door is unmounted in dev** (no dev-safe seed path, MVP-RUNBOOK §6b).
3. **Usage dimensions show gap states** until dataplane telemetry emission is wired — the next
   candidate task.
4. `GITFROK_CLOUD=gke` is **annotated dev fiction**; real-cluster proof is T-0042's.
5. **Backend integration tests skip without `TEST_DATABASE_URL`**, so some isolation and tamper
   proofs rest on a local run.
6. **`helm` is absent on this host** — rendered-chart assertions skip honestly; static ones bind.
7. **One throwaway probe-discard PAT** lives in the dev tenant (in-memory identity store; north-star
   git-flow PAT is the same class).
8. **Dependabot advisories are open on the bff and webfrontend default branches** — pre-existing.
9. **One-node limits stay "no" on this cluster:** failover, CI gVisor RuntimeClass under rootless
   podman, durability quorum — all need the cluster lane.
10. Proxy-only egress is unsolved (ADR-0017 follow-up) and can block a sale outright.
11. The dataplane gRPC door is unauthenticated (Phase-2 limit (d)): tenant/actor/roles come off the
    wire; mitigation is network isolation + RLS.
12. Phase-2 in-process state does not survive a restart (attribution projection, pack assembly,
    code-search index; the index also has no cap — limit (e)).
13. Two sources of schema truth: `deploy/dev/postgres.yaml`'s ConfigMap vs `backend/` migrations —
    they agree; nothing enforces it.
14. Per-consumer codegen gating is impossible while each `buf.gen.yaml` reads
    `../governance/contracts` — freshness is gated at the super-repo pin bump.
15. First-party images in `deploy/dev` are pinned by tag, not digest (ADR-0035 decision 4).
16. Host DNS for `*.gitsaas.test` needs root, so `dev-up.sh` prints the snippet rather than
    applying it.
17. git/v1 has no create-repository RPC — bare repos come back via the RUNBOOK §8a kubectl-exec
    recovery.
18. **The CVD captures run against the stub BFF, not a cluster** — deliberately, because the
    fixtures are state-dense in a way live data on a given day is not. They prove the ENCODINGS
    survive grayscale and deuteranopia; they are not a live-cluster walk, and the artifacts are
    gitignored (`npm run cvd` regenerates them; the reviewed verdict is in T-0048's exit record).
19. **Six prototype surfaces are deliberately absent from the product**: Issues, Releases, a
    pipelines list, repository Settings, the Admin area, and the marketing landing page. `./UI`
    shows all six; none has a BFF route or a `PR-#`, and SPEC-0047 records them out of scope. A
    prototype is not a requirement — do not "restore" them without a spec.
    **Superseded in principle, still binding in practice (2026-08-18):** **ADR-0070** is the spec
    this limit asks for, and it adopts all six as ADR-0070 Tier C — but it is **Proposed**, so none
    of them may be specced or built until it is Accepted and the PRD carries PR-28…PR-32. The bar
    did not drop; it moved to an ADR someone has to defend.
20. **Deepfreeze (dark) ships tokenized but unreachable** — no user-facing toggle, by ADR-0069 open
    decision 3. Both themes are defined together so they cannot drift; only the switch is missing.

## The storage picture, in one place

- **Live bare repositories: block volumes** (ADR-0033). `git-storaged` refuses a FUSE repository root
  outright (invariant 7).
- **LFS, CI artifacts, image blobs: ADR-0050** puts them on a SeaweedFS FUSE mount, produced by
  ADR-0051's privileged node DaemonSet. That mount **does not propagate on this driver**, so the dev
  cluster runs the S3 adapter ADR-0050 decision 6 keeps for that case. Measured, not assumed —
  `deploy/dev/README.md`.
- **Transfers proxy through the plane** under `repo.lfs.read` / `repo.lfs.write`, and every read is
  verified against the digest in the object's name (SPEC-0023, as amended by ADR-0050).
- **Browser sessions: Valkey** (ADR-0049), opened by the BFF itself under the one datastore waiver
  ADR-0052 grants. Every other cache or database client in the BFF still fails its boundary gate.

## What Phase 3.1 decided that changes how you build

- **Durability** (ADR-0062, SPEC-0042): agent and residency stores are Postgres adapters behind the
  existing ports. The enrolment-token hash lookup is the **one named RLS exemption** (bounded to one
  row, enumerated by test), and a **failed signature may not silently consume a token** (AC6).
- **The Declare surface verifies its caller** (SPEC-0043 AC6); no tenant/actor/role field exists in
  `residency/v1` messages, by contract test.
- **A tenant-scoped platform operator may declare** (ADR-0067, SPEC-0043 AC7), reusing ADR-0046's
  `platform_operator` principal.
- **Custody is OpenBao** (ADR-0066, SPEC-0044 AC5): control-plane-side, three-node Raft, Shamir
  quorum unseal, Kubernetes auth, image pinned per ADR-0034.
- **Two trust bundles, named apart:** the CA trust bundle (ADR-0064, T-0040) is not the release
  trust bundle (ADR-0044/ADR-0065, T-0041); neither one's test may stand in for the other's.
- **The operator image ships digest-pinned only** — `operator.image.tag` is a tripwire that FAILS the
  install (T-0041); the only honored pin is `operator.image.digest`, which must agree with
  `deploy/releases/operator-app-0.1.0.release` (gated by `check-signed-releases.sh`).

## What Phase 3.5 decided that changes how you build

- **Tokens are the only source of colour** (ADR-0069). A hex literal anywhere in `webfrontend/src`
  outside `styles/tokens.css` fails the build. If a literal is genuinely unavoidable, annotate it
  `gf-allow-hex: <reason>` **on the same line** — the checker is line-scoped, which caught its own
  author once.
- **Never hue-only encoding.** Every status carries a glyph and a word from the ONE vocabulary in
  `src/lib/status.ts`. A status added with a colour and nothing else fails
  `tests/status-vocabulary.test.ts`, which enumerates the table rather than sampling it.
- **Diffs are blue/orange with `+`/`−` text markers**, and the removed marker is U+2212 MINUS, not
  the patch format's hyphen. Four channels carry add-versus-remove; the tint is the weakest.
- **Astro does not add `px`.** A style object written `{ gap: 24 }` renders as `gap:24` and the
  browser discards it — React's behaviour is the exception, not the rule. Use `'24px'`. A test walks
  `src/**.astro` and fails on a bare number in a length property.
- **Frost (light) is the only default.** Deepfreeze is fully tokenized so it cannot drift, but ships
  no user-facing toggle — that is ADR-0069's open decision 3.
- Fonts are **self-hosted WOFF2** under `webfrontend/public/fonts`; the org blocks the Google CDN and
  a test asserts the built output never reaches it.

## History, compressed

- **Phase 3.1 wave records** (exit pins all resolve): EP-19 durable stores/residency
  (backend@c9e58c5, 816cb30) · EP-20 Declare surface + PlacementGate (governance@794f578/3b9e853,
  bundle 0.10.0, backend@f182761) · EP-21 custody (backend@b0ab32e, super-repo@f8449b8) · EP-22
  harness (backend@762d5f0, a669cef, super-repo@febf0f7) · EP-23 divergence gates + read-only cause
  (backend@bc30abd, 0238dee; bff@4059a23; webfrontend@08f42c4, 843a195) · T-0035 envelope throttle
  (backend@a9ed620, super-repo@9f526d0).
- **Phase 3.5 wave records:** T-0045 tokens/fonts/gate (webfrontend@cdf032c) · T-0046 the CVD diff
  and repo browsing (089c514) · T-0047 the status vocabulary, ratchet to zero (0f0dabd) · T-0048
  usage, trend arrows, the Okabe–Ito series palette (56c91d1) · AC10 captures and the unitless-px
  fix (ad075f4).
- **Reviews at this repo's root** — records, not governance, but they save you from re-deriving:
  `phase-3.1-code-review.md` and `phase-3.1-plan-review.md` (findings acted on, produced ADR-0067) ·
  `phase-3-code-review.md` (CA trust-ordering defect fixed at backend `e722046`; opened T-0035) ·
  `phase-2-code-review.md` + `-wave2.md` (seventeen findings, seven on fixes, two residuals).
- **The lesson the record keeps:** a test against a fake proves the control flow, not the claim —
  live proofs found the no-refspec fetch, the `authz.rego` that granted `repository.import` to no
  role, the SeaweedFS 200-on-missing-bucket, the S3 gateway serving unsigned reads, and the
  role-less merge-base read (backend 55db3bb). And: a green gate is not a correct spec — check the
  port signature before believing "no exception exists". Phase 3.5 added the visual case: a DOM
  assertion passes happily on a page whose layout has collapsed, which is why the CVD captures are a
  criterion and not a nicety.

## Tool entry points

`CLAUDE.md` → `AGENTS.md` for Claude Code; `AGENTS.md` for Codex, OpenCode (+ `opencode.json`) and any
other agent; `.cursor/rules/agdd.mdc` for Cursor; `.github/copilot-instructions.md` for Copilot. All of
them are **generated** from `governance/canonical/agent-surfaces/` by `scripts/gen-agent-surfaces.sh`
(ADR-0037) — edit the canonical source and regenerate; CI fails on drift.
