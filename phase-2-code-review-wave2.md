# Phase 2 code review — wave 2 (re-review at current pins)

Follows `phase-2-code-review.md` (17 findings, H1–L17, reviewed at backend `0a2097c`). This pass
re-reviews the fix wave and the SPEC-0036 idiom refactor.

Ranges reviewed (hand-written code only; `gen/**`, `*.pb.go`, `src/gen/**` excluded):

- backend `0a2097c..42ad9b3` — 59 files, +2450/−312
- bff `b7c3763..d63fdab` — 3 commits, SPEC-0036 idiom sweep only
- webfrontend — unchanged (`7997c7c`, same pin as the previous review); not re-reviewed
- governance `f523ad3` / `3313a42` — the records the fix wave cites

Pin note: the super-repo pins backend at `42ad9b3` on branch `fix/phase2-review-wave2`, not on a
merged `main`. The previous review reviewed merged mains.

Gates at these pins: backend `go build ./...` clean, `go test ./modules/...` green. bff
`go build ./...` clean, `go test ./...` green. Every finding below is a coverage or correctness gap,
not a failing gate.

---

## Verification matrix — the 17 prior findings

| # | Status | Evidence |
|---|---|---|
| H1 policy record reads mirror untrusted tenant | **Not fixed at runtime** (structure prepared) | see N1 |
| H2 unauthenticated dataplane door | **Recorded limit** | governance plan note (d), SPEC-0002 open question |
| H3 cross-repository finding/triage read | **Fixed** | `security/internal/app/service.go` `GetFinding`/`GetTriage` load the finding first and refuse `f.RepositoryID != c.RepositoryID`, then pass `repository` into the PDP context |
| H4 silent trail truncation | **Fixed** | `audit/.../postgres/query.go` fetches `limit+1`; `AssembleSections(records, repo, truncation)` sets `Complete:false` + `GapReadTruncated`. Residual: N4 |
| H5 one scan per revision | **Fixed** | `ScanReportAt` now `ROW_NUMBER() OVER (PARTITION BY scanner_class …) WHERE rn = 1`, report joins `scan_id = ANY($1)`, `ScanReport.ScanIDs` |
| H6 attribution never recomputed | **Fixed** | `attribution.go` replaces the stored record; `attributionContentEqual` carries the emitted flag so an unchanged recompute stays silent |
| M7 whole pack in header chunk | **Fixed** | `Chunks` clears `header.Sections` and `header.Appendix` |
| M8 decision with no input digest | **Fixed** (with a caveat) | `Classify` also requires `detailInputDigest`. Residual: N6 |
| M9 grant audited before stored | **Fixed** | `issueAttempt` inserts, then appends, then records the ISSUED transition; `issuedOnly` fails closed so an unaudited row never lists, never yields decision facts |
| M10 ingest audit record can be lost | **Fixed** (with a caveat) | audit record emitted before the domain events, `ClaimIngestAuditMarker` + replay backfill on `AuditAlreadyRecorded == false`. Residuals: N2, N5 |
| M11 severity threshold duplicated in Go | **Fixed differently, and the guard is conditional** | not moved into the bundle; `threshold_parity_test.go` really parses `security_severity_threshold` out of `governance/policies/gitsaas/authz/authz.rego` — but it `t.Skipf`s when that path is absent, and `backend/.github/workflows/ci.yml` checks out no governance tree. The parity guard runs only in a super-repo checkout, not in backend CI. Carried in `governance/docs/backlog/README.md` |
| M12 synchronous insert per decision | **Fixed** (partly) | `policy/internal/app/recorder.go` — bounded queue (256) + one worker, `Close()` wired in `cmd/dataplane-app/main.go`. The per-repository *decision* fan-out itself is unchanged. Residual: N3 |
| M13 in-process state | **Recorded limit** | governance plan note (e), SPEC-0031/SPEC-0034 open questions |
| L14 UNAVAILABLE with no reason | **Fixed** | `api.AttributionUnavailableMergeBaseResolverNotComposed`; wire still renders UNSPECIFIED until the contract adds the enum (carried in backlog) |
| L15 no per-job indexing timeout | **Fixed** | `Config.JobTimeout` (2 min default), `indexOne` uses `context.WithTimeout`. The single worker and the drop-on-full 256-slot queue are unchanged (as reported) |
| L16 grant repository scope absent from facts | **Fixed** | `GrantDecisionFacts.RepositoryID` populated and forwarded as `auditor_grant_repository_id`; the bundle does not consume it yet (additive, recorded) |
| L17 cursor not bound to principal | **Fixed** | `cursorClaims.Actor`, `cursor.ActorID`, `mrCursor.ActorID` all bound and compared. Pre-fix tokens decode with an empty actor and fail closed |

---

## New findings

### N1. The H1 fix does not change runtime behaviour — the tenant is still the caller's

`backend/modules/policy/internal/adapters/grpc/server.go` `bindTenant` binds
`req.GetTenantId()` into the context, and `app/service.go` `guardTenant` then compares the request's
tenant against that same value. The comparison is a tautology today: `GetDecision` still reads any
tenant's decision record given its ID, and `EvaluateDryRun` still replays another tenant's ENFORCED
decisions and still appends DRY_RUN records into that tenant's `policy.decision_records`.

The code is honest about this — both comments name themselves hook points pending door
authentication. The governance record is not: `governance/docs/plans/phase-2-ultimate-wedge.md`
(fix wave 2, H1) says the reads "refuse a caller-supplied tenant that mismatches the verified
caller", which reads as enforcement. There is no verified caller on this door (recorded limit (d)).

Consequence: H1 remains open, subsumed by H2, and the exploit the previous review described is
unchanged. What the wave bought is that the enforcement point exists and is covered by tests, so the
interceptor is the only remaining change. Recommend restating H1 in the plan as *deferred behind
(d)*, not fixed.

### N2. The ingest audit marker shares a key namespace with caller-supplied request IDs

`backend/modules/security/internal/adapters/postgres/store.go` records the audit marker as a row in
`security.scan_chunks` with `request_id = 'audit:' || $4`, and the replay path tests
`EXISTS(… request_id = 'audit:' || $3)`. `RequestID` arrives verbatim from the wire
(`internal/adapters/grpc/server.go:122`) and `validContext` only requires it to be non-empty — a
request ID may itself begin with `audit:`.

Two consequences, both reachable on the unauthenticated door:

1. **Suppressed audit record.** A caller ingests once with `request_id = "audit:R"` (creating that
   row), then ingests with `request_id = "R"`. If the audit publish fails after the commit — the
   exact window M10 exists to close — the retry sees the marker as present and skips the backfill.
   A committed ingest ends with no audit record: SPEC-0025 AC5 back to where M10 started it.
2. **Forged replay.** A first request with `request_id = "audit:R"` matches a marker row written for
   a real request `R` and is answered as a completed replay with `findings_recorded = 0`.

The in-memory store is unaffected (separate `auditMarkers` map). Fix: use a separate marker table or
a column, or reject a caller request ID carrying the reserved prefix.

### N3. An enforced decision's record is now best-effort once it is admitted, and the runbook still describes the old contract

`policy/internal/app/recorder.go`: admission is fail-closed (`ErrRecorderFull` for enforced records),
but a store failure *inside* the worker only increments `failed` and logs. Under the previous
synchronous append, a failed append failed the decision. SPEC-0029 AC1 ("every enforced decision is
recorded and retrievable") is therefore now guaranteed only up to store availability, plus a
queue-depth window on a non-clean exit — `Close()` is a `defer` registered at `main.go:182`, so the
ten `os.Exit(1)` paths after it skip the drain (the graceful SIGTERM path does return through it).

The code comments attribute this to "the MVP-RUNBOOK operational contract" and its "decision-record
lag" alert. `deploy/MVP-RUNBOOK.md` §4a still says the opposite — "Decision-record append is on the
`Decide` hot path and fail-closed … a failed append fails the decision" — and no lag alert is
documented anywhere; governance plan note (c) carries the same stale text. Either the runbook and
note (c) get updated with the async contract and the counters to alert on (`FailedRecords`,
`DroppedRecords`), or the code should stop citing a contract that does not exist.

### N4. ~~A pack section whose records all fell in the truncated tail is absent, not gapped~~ — WITHDRAWN

Not a defect. `AssembleSections` iterates `api.AllSectionTypes`, not the grouped map, so every
trail-fed section type is emitted with the truncation gap whether or not it cited a record. Read
from the diff hunk rather than the whole function; the claim was wrong at 42ad9b3 and remains wrong
at `d9774ef`. A pinning test now covers it (`evidence_test.go`).

### N5. The ingest audit record can still be written twice

`emitIngestAudit` publishes and then claims the marker, swallowing the claim error
(`_ = s.store.ClaimIngestAuditMarker(...)`). Publish-succeeded / claim-failed leaves a replay that
backfills a second record for one ingest. The comment states the trade deliberately, but SPEC-0025
AC5 says exactly one, and the previous review's "one, and at least one" now holds only on the
at-least-one side. Worth an explicit record if the duplicate is accepted; the alternative is
claiming the marker in the same transaction as the chunk commit.

### N6. A decision record missing its input digest is dropped from the pack with no gap

The M8 fix makes `Classify` return `false` for a policy decision with no `input_digest`; unclassified
records are skipped, and the surrounding section is still built with `Complete: true`. So a decision
that *is* in the trail leaves the pack silently. Under SPEC-0031 AC3 the record must not appear
without its digest; under AC10 its omission should be visible. A gap over the omitted records (or a
counted "excluded" marker) closes it.

### N7. `GetFinding`/`GetTriage` now read the store before the PDP decides

The H3 fix loads the finding row first and denies on a repository mismatch, then asks the PDP. That
is the SetTriage shape and the coarse-denial behaviour is preserved. Two consequences worth naming:
an unauthorized caller now causes a database read (a cheap amplification on the unauthenticated
door, H2/(d)), and the PDP is no longer the first gate on the path. Acceptable as written — recording
it so the ordering is a decision rather than a drift.

---

## SPEC-0036 refactor — behaviour drift check

Swept the idiom commits (backend `a4e016f`, `91366ed`, `16d9a56` and the sweeps inside the fix
commits; bff `22efc78`, `6e1b439`, `d63fdab`) for the patterns that silently change behaviour. No
drift found:

- `append([]T(nil), x...)` → `slices.Clone(x)`: nil-in/nil-out preserved; every site was already a
  defensive copy.
- `maps.Clone` in the bff evidence client is guarded by `len(...) > 0`, so the nil case is unchanged.
- `clear(p.entries)` in `bff/internal/pep/pep.go`: the map is never handed out (`len`, index, delete
  only), so reusing it rather than reallocating is not observable.
- `strings.Index`/slicing → `strings.Cut` in `git-storaged/importrefs.go` `validSourceURL` and
  `audit/internal/domain/evidence.go`: both cut at the first separator, as the index form did.
- `sort.Slice` → `slices.SortFunc` throughout: both unstable, and every comparator is a total order
  on a unique key except `ListPATs` (ties on `CreatedAt`), which was already nondeterministic.
- `size = min(size, api.MaxImportedHistoryPageSize)` is the same clamp.

## Still true from the previous review

The "Verified good" list stands, and the two recorded limits (H2/(d), M13/(e)) are recorded in
`governance/docs/plans/phase-2-ultimate-wedge.md`, SPEC-0002, SPEC-0031 and SPEC-0034 open questions
with follow-ups named. M11 and L14 are carried in `governance/docs/backlog/README.md`.

---

## Wave-3 verification (super-repo 7e02f7f — backend d9774ef, governance 390781b, runbook e2cda7b)

Gates re-run at `d9774ef`: `go build ./...` clean, `go test ./modules/...` green. `d9774ef` and
`42ad9b3` are both on backend `origin/main` — the earlier "pin on a branch" note was wrong and is
withdrawn.

| Finding | Verified |
|---|---|
| N1 | **Restated, not code-fixed** — plan now says H1 is "deferred behind limit (d), not runtime-fixed" and names the tautology explicitly. This is what the finding asked for; runtime enforcement still waits on door auth |
| N2 | **Fixed** — `reservedRequestIDPrefix`/`validRequestID` in `security/internal/app/service.go`; ingest refuses the prefix with `ErrMalformed` *before* the context check, and `validContext`/`validTenantContext` refuse it on every other path. `ErrMalformed` already maps at four gRPC sites. Both attack scenarios have regression tests (`TestAuditNamespaceCannotSuppressABackfill`, `TestAuditNamespaceCannotForgeAReplay`) |
| N3 | **Fixed (docs)** — runbook §4a and plan note (c) now describe async admission-fail-closed, the worker best-effort window, the `os.Exit` drain skip, and alert on `FailedRecords`/`DroppedRecords` |
| N4 | **Withdrawn** — my error, see above; pinning test added |
| N5 | **Fixed** — marker claimed inside the final chunk's transaction (`claimAuditMarker` in `IngestChunk`), so the marker means "committed"; the backfill decision moves to `AuditWitness.IngestAuditRecorded` reading the trail, wired unconditionally in `main.go` over the Postgres or memory trail. Witness error or truncation falls back to the marker — a documented, narrower window than before |
| N6 | **Fixed** — `GapRecordsExcluded`, one point gap per excluded record on the policy-decisions section, `Complete: false`. The section is always emitted, so the gap always lands |
| N7 | **Recorded** — plan states the store-before-PDP ordering, the lost first-gate property, and the read amplification against limit (d) |

Two small residuals, neither blocking:

- `excludedPolicyDecision` keys on `policy_mode == ENFORCED`. A policy-decision record that carries
  no mode detail *and* lacks its digest is still dropped silently rather than gapped. Only reachable
  if a producer omits the mode, which the current publishers do not.
- The wire still renders both `GapReadTruncated` and `GapRecordsExcluded` as
  `GAP_REASON_UNSPECIFIED`; `Complete: false` carries the signal until the contract change (already
  carried in the backlog alongside L14).

Open items unchanged and correctly recorded: H1 runtime enforcement + H2 door auth, M11
PDP-driven threshold (and its parity test that skips without a governance checkout — worth pinning
in backend CI), L14 wire enum, M13 persistence.

---

## Wave-3 close-out

Every wave-2 finding is now dispositioned:

| Finding | Disposition |
|---|---|
| N1 | Recorded — plan restates H1 as deferred behind limit (d); runtime enforcement tracked with H2 door auth |
| N2 | Fixed in code (`d9774ef`), two regression tests |
| N3 | Recorded — runbook §4a and plan note (c) now carry the async contract and the `FailedRecords`/`DroppedRecords` alert |
| N4 | Withdrawn (reviewer error); pinning test added |
| N5 | Fixed in code (`d9774ef`) — in-transaction marker claim plus trail witness |
| N6 | Fixed in code (`d9774ef`) — `GapRecordsExcluded` |
| N7 | Recorded — store-before-PDP ordering is an explicit decision against limit (d) |

Residual A — **fixed** on backend branch `fix/wave2-residual-a` (`b494d43`, off `main`, not the
SPEC-0036 sweep branch — a behaviour change must not ride a refactor PR). `excludedPolicyDecision`
now gaps three shapes instead of one: ENFORCED with incomplete provenance, a mode outside the
trail's vocabulary, and no mode alongside a policy revision or input digest. DRY_RUN stays absent
rather than gapped (SPEC-0032 AC3). The predicate deliberately ignores a bare `decision_id` —
`platform/auditsink/sink.go` writes that key on grant issuance, evidence-pack requests and scan
ingests too, so treating it as decision provenance would gap the section on healthy records. That
leaves one sliver: a decision record reduced to `decision_id` alone is still silent, and is
indistinguishable from those healthy records at this layer. Four pinning subtests cover the shapes;
backend gates green.

Residual B — **fixed** in this repo (`fd001ec`, branch `fix/wave2-residual-b`). The parity test ran
in no CI lane: backend's workflow checks out no governance tree, so the test skipped itself there,
and no super-repo lane invoked `go test` at all. A `make threshold-parity` target now guards on the
bundle's presence (failing with a message rather than skipping) and runs the test, wired as a step
in the existing "super-repo fitness gates" job — alongside `codegen-check` and `policy-check`, which
live here for the same reason: `submodules: recursive` is what puts both trees on disk. A step
inside an already-required check needs no ruleset registration. Verified locally: `--- PASS`, not
`--- SKIP`. `make verify`, `lint-shell` and `portability-check` still green.

## SPEC-0036 sweep (backend `8dc611f`, branch `chore/spec-0036-sweep-wave3`; bff: no change needed)

Swept both repos against SPEC-0036's binding triage — ALLOWED and CONDITIONAL only. The Modern Go
Guidelines CLI also returns `errors_as_type`, `sync_waitgroup_go`, `json_omitzero`,
`strings_split_seq`, `slices_collect`, `slices_sorted` and `strings_clone`/`bytes_clone`; SPEC-0036
lists all of them as SKIP this round, and governance wins (ADR-0001), so none were applied.

Backend, one commit, gates green (`go build`, `go vet`, `go test ./...`):

- `slices_clone` — 75 `append([]T(nil), x...)` sites across 36 files.
- `strings_cut_prefix_suffix` — 5 HasPrefix-guard-then-TrimPrefix pairs (smart-HTTP and LFS path
  parsing, the SSH command parser, both PAT key-ID parsers).
- `errors_is` — 2 `err == io.EOF` stream-drain comparisons.

bff: swept the same list and found nothing left — the earlier `d63fdab` sweep had already covered
it. Gates re-run green; no commit, branch dropped.

Not swept, and why: `internal/arch/**` in both repos still uses `sort.Slice`/`sort.Strings`, which
AC1 freezes. `sort.Search` (3 backend sites) has no replacement in the ALLOWED set. Existing
`_test.go` files were left alone under AC2, so `testing_t_context`/`testing_b_loop` were not
applied anywhere. `new_expression`, `sync_once_func`/`sync_once_value`, `fmt_appendf`,
`reflect_type_for`, `maps_copy`, `maps_delete_func` and `min_max` were searched for and had no
handwritten sites outside `gen/`.

Neither the branch nor the super-repo pin was pushed or bumped — that has been the team's step
each wave.
