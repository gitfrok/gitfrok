# Phase 2 code review — T-0022…T-0028

Reviewed ranges (hand-written code only; `gen/**`, `*.pb.go`, `src/gen/**` excluded):

- backend `29a9914..0a2097c` (11 commits, 128 files)
- bff `4693eae..b7c3763` (6 commits, 39 files)
- webfrontend `5bb110a..7997c7c` (3 commits, 25 files)

Rubric: SPEC-0024…SPEC-0035 acceptance criteria, `governance/docs/agents/invariants.md`,
ADR-0006/0007/0022/0029/0055.

Gate state at the pin: `go build ./...` clean; `go test` green across
`modules/{security,audit,policy,codesearch,identity}/...`. Every finding below is a gap in
coverage, not a failing test. All seven tasks are Done and merged, so these are new fix items,
not blockers on task closure.

The prior review wave (backend `0a2097c`) is excluded — nothing it fixed is re-reported.

---

## High

### H1. The policy decision-record surface makes RLS mirror untrusted input

`backend/modules/policy/internal/adapters/postgres/store.go:81` (`Get`) and `:120` (`Range`) both
open the transaction with `tenancy.WithTenant(ctx, tenancy.ID(tenantID))`, where `tenantID`
arrives verbatim from the wire: `internal/adapters/grpc/server.go` passes
`req.GetTenantId()` from `GetDecisionRequest` and `EvaluateDryRunRequest` straight through
`internal/app/service.go` into the store.

RLS is therefore set to the value the caller chose. The comment on `Get` — "RLS has already made
another tenant's record invisible to this transaction" — is not true: the transaction's tenant
*is* the caller's assertion.

Consequences: `GetDecision` reads another tenant's decision record given its ID;
`EvaluateDryRun` returns up to 1000 of another tenant's ENFORCED decisions **and appends
DRY_RUN records into that tenant's `policy.decision_records`**, writing into another tenant's
compliance evidence.

Violates invariant 1 ("tenant-scoped, with RLS as backstop — both, always") and SPEC-0030 AC6.
The tenant for these two reads must be derived from the verified caller, not from the request
message. Aggravated by H2.

### H2. The Phase-2 gRPC door is unauthenticated, and every new RPC takes the subject off the wire

`backend/cmd/dataplane-app/gitfront.go:298` builds the door as bare `grpc.NewServer()` — no
transport credentials, no authentication interceptor, no tenant-pinning interceptor.
`cmd/dataplane-app/main.go:351-373` registers all four Phase-2 services on it:
`FindingsService`, `EvidenceService`, `SearchService`, `AuditorGrantService`.

Those services read the principal from the request body:
`modules/security/internal/adapters/grpc/server.go:120-121` maps `c.GetActorId()` and
`c.GetActorRoles()` into the app context, and the app layer hands those roles to the PDP as the
subject (`internal/app/service.go:373-382`).

Anyone with network reach to the port can assert any tenant, any actor, and any role set —
including `auditor`, which `modules/audit/internal/app/evidence.go:388` uses to select the
grant-facts composition path. The PDP then decides correctly about a forged subject, which makes
invariant 2 advisory rather than enforced.

Honest caveat: Phase 1 already served `Decide` on this door, where a caller-supplied subject is
inherent to a PDP call and the BFF is the only intended client (invariant 22). What Phase 2
changed is that the same unauthenticated port now serves findings reads, triage writes, evidence
packs, grant administration and code search. If the deployment relies on network isolation, that
belongs in the specs as a recorded limit, not in the code's silence.

### H3. Cross-repository finding and triage read inside a tenant

`backend/modules/security/internal/app/service.go:241` (`GetFinding`) and `:468` (`GetTriage`)
ask the PDP with resource type `finding`, the finding ID, and **an empty attribute map** — no
repository. The store read is tenant-scoped only: `internal/adapters/postgres/store.go:315`
(`WHERE id = $1`) and `readTriage:569` (`WHERE finding_id = $1`) carry no repository predicate,
and RLS keys on `tenant_id`.

`validContext` (`service.go:544`) requires `c.RepositoryID` to be non-empty but never compares it
to the finding's `RepositoryID`. So a principal readable on repository A can pass
`repository_id = A` and read any finding — and its triage history, actor and justification — in
repository B of the same tenant.

`SetTriage` (`:392`) gets this right: it loads the finding, rejects on
`f.RepositoryID != req.RepositoryID`, and passes `repository` into the decision context. The two
read paths should do the same.

Violates SPEC-0026 AC6 and SPEC-0027 AC3/AC4.

### H4. Evidence pack trail read truncates silently and still reports sections complete

`backend/modules/audit/internal/adapters/postgres/query.go:20` sets `defaultQueryLimit = 10_000`
and `:59-69` applies it whenever the query names no limit.
`internal/app/evidence.go:511-513` names none. `internal/domain/evidence.go:185-191` then builds
every trail-fed section with `Complete: true` and no gap.

A range holding more than 10 000 trail records therefore produces a pack that presents a
truncated section as complete — the precise failure SPEC-0031 AC10 and SPEC-0032 AC8 exist to
prevent. Truncation takes the *earliest* records (`ORDER BY tenant_seq ASC`), so the tail of the
range disappears with no marker anywhere.

### H5. Attribution sees only one scan per revision, so a multi-scanner repository attributes one tool

`backend/modules/security/internal/adapters/postgres/store.go:724-728` — `ScanReportAt` selects
a single scan:

```sql
SELECT id FROM security.scans
 WHERE repository_id = $1 AND revision = $2 AND state = 'COMPLETE'
 ORDER BY completed_at DESC NULLS LAST, started_at DESC, id DESC
 LIMIT 1
```

A repository that runs Semgrep (SAST) and gitleaks (SECRETS) against the same head produces two
COMPLETE scans at that revision; attribution reads one of them. The consequence reaches the merge
gate: `internal/app/merge_facts.go` builds `FindingsGateFacts` from the same record, so the
security gate can pass a merge on breach-level findings the other scanner reported.

SPEC-0026 AC1 requires the dashboard to span every ingested scanner class; SPEC-0028 AC1 defines
attribution over what the head reports, not what one scan of the head reported.

### H6. A materialized attribution record is never recomputed, so a later scan cannot change it

`backend/modules/security/internal/app/attribution.go:246-252`:

```go
key := attributionKey(tenantID, mergeRequestID, mr.HeadRevision, base)
s.attrMu.Lock()
if existing, ok := s.attributions[key]; ok {
    rec = existing          // the freshly computed record is discarded
} else {
    s.attributions[key] = rec
}
```

`onScanIngestedAttribution` (`:123`) deliberately recomputes every open comparison whenever a
scan lands, and the result is thrown away on a cache hit. Since the key is
(tenant, MR, head, base), any second scan at the same head — a rescan, a newly added scanner
class, an upgraded tool — never reaches the merge request view or the gate facts.

Together with H5 this means the MR surface is fixed by whichever scan happened to complete first
for a given head/base pair.

---

## Medium

### M7. `Chunks` puts the entire pack in the header chunk

`backend/modules/audit/internal/domain/evidence.go:287-288`:

```go
header := p
push(api.PackChunk{Header: &header})
```

`header := p` copies the whole `api.Pack`, including `Sections` and `Appendix`. The bounded-chunk
streaming shape of `GetEvidencePack` is defeated: chunk 0 alone carries the complete pack, and its
size is unbounded. The header should be the pack with sections and appendix cleared.

### M8. A policy decision with no input digest is admitted to a control section

`backend/modules/audit/internal/domain/evidence.go:94` gates the policy-decisions section on
`decision_id` and `policy_revision` only. `InputDigest` is copied at `:100` and may be empty.

SPEC-0031 AC3: "Every policy decision in the pack carries its deciding policy version **and input
digest**." Add `detailInputDigest` to the same guard, where the comment already says exclusion
belongs.

### M9. Auditor-grant issuance audits before it stores

`backend/modules/identity/internal/app/auditor_grants.go:164-188`. The immutable
`auditor.grant.issued` record is appended at `:164`; `store.Insert` runs at `:180`. If the insert
fails and no prior grant exists under the request ID, the function returns
`ErrGrantUnavailable` — and the chain permanently states that a grant which does not exist was
issued.

This is the same class the prior review wave fixed for evidence packs (reserve the key before any
side effect, roll back on failure); the fix shape is already in the codebase at
`modules/audit/internal/app/evidence.go:259`.

### M10. An accepted ingest can lose its audit record permanently

`backend/modules/security/internal/app/service.go:224-233` publishes the
`FindingsScanIngested` audit event **after** `store.IngestChunk` has committed. If the publish
fails, the caller gets an error and retries with the same request ID; the retry replays and
early-returns at `:187-189`, so the audit record is never written for a scan that was ingested.

SPEC-0025 AC5 requires exactly one immutable audit record per accepted ingest — one, and at least
one.

### M11. The merge-gate severity threshold is a Go constant mirroring the rego rule

`backend/modules/security/internal/app/merge_facts.go:69` reads
`codereviewapi.SecurityGateSeverityThreshold` and uses it at `:106` to decide which attributed
findings need triage coverage; `mergeGateSeverityRank` (`:36`) explicitly "mirrors severity_rank
in … authz.rego".

Two sources of truth for one policy value. If the reviewed bundle's threshold moves, the
assembler keeps filtering at the Go constant and reports the wrong
`ReliedUponTriageIDs` — and SPEC-0029 AC3 wants the rule in the bundle, not in Go. Pass the
severity distribution and the triage records to the PDP and let the rule pick the threshold.

### M12. One PDP decision per repository per request, and every decision is now a synchronous INSERT

Two changes compose badly:

- `backend/modules/policy/internal/app/service.go` `Decide` now calls `store.Append` on the hot
  path of every authorization decision (`internal/adapters/postgres/store.go:42`).
- The new read paths derive their scope with one decision per repository:
  `modules/security/internal/app/service.go:304-313` (`ListFindings`), `:499-509`
  (`GetFindingsSummary`), `modules/codesearch/internal/app/service.go:448-458` (`deriveScope`,
  called on every search *and* every `GetIndexStatus`).

A dashboard load or a single search keystroke on a 1000-repository tenant is 1000 PDP decisions
and 1000 Postgres inserts. In `Search` (`:402-412`) `deriveScope` runs *before* the tenant-level
`search.query` decision, so a caller who is about to be denied still costs N decisions and N
inserts — an amplification vector on an unauthenticated port (H2).

The per-request derivation is deliberate and correct for SPEC-0034 AC6 / SPEC-0026 AC6; the
recording of every decision is what makes it expensive. Batching the scope decision, or recording
asynchronously, is the fix — not caching the scope.

### M13. State that must survive a restart is in-process only, and uncapped

- Attribution: the merge-request projection and every materialized comparison
  (`modules/security/internal/app/service.go:47-48`). After a restart every MR renders
  UNAVAILABLE / head-scan-not-run until Code Review re-announces, and nothing evicts either map.
- Evidence packs: `modules/audit/internal/app/evidence.go:58` holds packs in a map, and `:68`
  holds idempotency reservations that by design "stay registered forever". A requested pack does
  not survive a restart; `assemble` runs on `context.Background()` (`:249,473`), so a pack
  interrupted mid-assembly is stuck in ASSEMBLING with no owner.
- Code search: the whole index (`modules/codesearch/internal/app/service.go:103`), with per-repo
  bounds (`MaxFilesPerRepo` 20 000 × `MaxFileBytes` 1 MiB) but no per-tenant or global cap.

Phase-2 migrations add tables for findings, triage, scan reports, grants and decision records —
none for packs or the search index. If in-process is the intended Phase-2 posture, it is a
recorded limit against SPEC-0031 AC8 (time-to-evidence measured in hours) and SPEC-0034 AC4/AC5,
and it should be stated as one.

---

## Low

### L14. `UNAVAILABLE` with no reason when no merge-base resolver is composed

`backend/modules/security/internal/app/attribution.go:186` returns
`attributionOutcome{reason: ""}`, which renders as `UNSPECIFIED` in the summary built at
`:343-350`. The surrounding comment argues for the honest UNAVAILABLE and then omits the reason
SPEC-0028 AC7 asks for.

### L15. A single indexer goroutine, no per-job timeout, and dropped jobs

`backend/modules/codesearch/internal/app/service.go:222` runs one `worker`; `indexOne` fetches
with `context.Background()` (`:242`) and no deadline. One hung `ListFiles` stops indexing for
every repository on the plane. `enqueue:197-207` drops the job when the 256-slot queue is full;
the admitted revision may then go unindexed until a `Backfill`, recorded only as an
`IndexLagged` event.

### L16. The auditor grant's repository scope never reaches the decision

`backend/modules/identity/internal/app/auditor_grants.go:345-353` builds
`GrantDecisionFacts` from grant ID, state, tenant, expiry, range and pack list — not
`RepositoryID`, which the grant carries (`:152`). The policy therefore cannot compare a grant's
repository scope against the pack's. Narrow in practice because `PackIDs` names packs
explicitly, but SPEC-0033 AC1 describes the scope and AC8 forbids widening.

### L17. The code-search cursor is not bound to the principal

`backend/modules/codesearch/internal/app/service.go:419` validates a cursor against tenant, text
and mode. A token issued to one actor is honoured for another in the same tenant. No content
leaks — `deriveScope` re-derives per query, per actor — but the offset then slides over a
different result set. The findings cursors (`modules/security/internal/app/service.go:691`) bind
filters but likewise not the actor.

---

## Verified good

Worth recording, because each of these is a place the ACs could have been faked and were not:

- **Identity derivation** (`modules/security/internal/domain/identity.go`) is a closed,
  length-prefixed input set with no commit, scan run, line number, tool version or provenance
  representable in it. The absent fields are enforced by the type, not by discipline.
- **RLS** is enabled *and* forced with a `tenant_isolation` policy on every new table across the
  four security/triage/scan-report/grant/decision-record migrations. `security.findings` has no
  `DELETE` grant, so SPEC-0024 AC9 ("resolved, not deleted") is a schema property.
- **Attested records cannot reach a control section**: `audit.entries` has no provenance column
  at all and `Append` rejects anything that is not first-party, so T-0018 AC19 / SPEC-0031 AC2
  holds structurally rather than by a filter that could be forgotten. `Classify` needs no
  provenance check.
- **Pack idempotency** reserves its key before any side effect, and rolls back on denial or a
  failed append, releasing the key only when the last waiter has observed the outcome.
- **Triage is a separate resource** keyed by finding identity, append-only with dense versions
  and a retained history — survives-rescan is true by construction, as designed.
- **No XSS surface** in the new Astro components: no `set:html`, no `innerHTML`, no
  `dangerouslySetInnerHTML` in `SecurityFindings.astro`, `MRFindings.astro`,
  `MRDiffFindings.astro`, `SecurityTriage.tsx` or the triage API route. Session cookies are
  `HttpOnly; Secure; SameSite=Lax`, so the triage POST is not cross-site forgeable.
- **The BFF shapes only.** The new handlers take no tenant, actor or role from the request, do no
  filtering or aggregation of their own, and forward the session's verified identity — invariant
  18 and SPEC-0026 AC8 / SPEC-0028 AC9 hold.

## Working-tree note (not a Phase-2 finding)

`backend` HEAD is `7b7172d` ("refactor(codereview): adopt Modern Go Guidelines idioms
(SPEC-0036)"), ahead of the super-repo pin `0a2097c`, and has uncommitted edits in
`modules/identity/internal/adapters/memory/grants.go`,
`modules/identity/internal/app/auditor_grants.go` and `modules/identity/internal/domain/pat.go`.
The working tree does not compile:

```
modules/identity/internal/adapters/memory/grants.go:8:2: "sort" imported and not used
modules/identity/internal/adapters/memory/grants.go:110:2: undefined: slices
```

The `sort` → `slices.SortFunc` conversion left the import block on the old set. In-progress
SPEC-0036 work, unrelated to the Phase-2 review; the pinned commit builds and tests clean.
