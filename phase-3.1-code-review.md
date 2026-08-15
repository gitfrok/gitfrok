# Phase 3.1 code review — T-0035…T-0044 (SPEC-0042…0046, ADR-0062…0067)

**Reviewed at:** super-repo `cfd8898` — backend `7c05a86`, bff `1ffbb77`, webfrontend `a1e614a`,
governance `62075e2`.

Reviewed ranges (hand-written code only; `gen/**`, `*.pb.go`, `src/gen/**` excluded):

- backend `d3f4ad6..7c05a86` — 111 files, +16963/−210 (residency durability + Declare door, custody
  CA rotation, release trust bundle, metering/usage, read-only cause contract)
- bff `e2344de..1ffbb77` — usage view: trend, throttle observation, divergence rendering
- webfrontend `0e80261..a1e614a` — usage regression pins, read-only cause lib
- governance `170246f..62075e2` — 48 files: SPEC-0042…0046, ADR-0062…0068, contracts, `authz.rego`
  bundle 0.10.0, contract-gate fixtures
- super-repo `824090c..cfd8898` — operator chart digest pin, OpenBao dev manifests, `check-custody-service.sh`,
  `check-runbook.sh`, provisioning scripts

**Rubric:** SPEC-0042…0046 acceptance criteria, ADR-0062…0067, `governance/docs/agents/invariants.md`,
and the Phase 3.1 plan's carried limits.

**Depth of review.** The backend range is 111 files; it was read by risk, not exhaustively. Deep-read:
the residency door / service / Postgres store and its migration, `pki/ca.go`, the custody bundle,
issuer and OpenBao adapter, the release trust bundle and its directory actuation, the operator's
trust / release / reconcile / status-writer path, the metering view and trend derivation, the
gateway's ack-attribution switch, the release-trust store's upsert, and the bff usage client. Skimmed
or not reviewed: the agent session/store churn, `internal/arch` fitness files, the audit evidence
residency section, the chaos/injection harness, and the test files themselves except where a claim
needed checking. Absence of a finding in those areas is not evidence about them.

**Gate state at the pins.** `make verify` exit 0 — dep-direction, version-floors, dev-images, trust
bundle, signed-releases, byo-chart, custody-service, runbook all OK. Backend `go build` / `go vet` /
`go test ./...` green; bff `go build` / `go vet` / `go test ./...` green; webfrontend `tsc --noEmit`
clean and 86/86 vitest cases pass. Two coverage gaps the gates themselves report and that must not be read as
"all green": `helm` is not on PATH, so the rendered-chart assertions of **both** `check-byo-chart.sh`
and `check-custody-service.sh` did not run (static assertions still bind); and
`check-custody-service.sh` reports its custody-env pairing assertion as **vacuous** — `deploy/dev/controlplane.yaml`
opens no agent door (`GITFROK_AGENT_GRPC_ADDR` unset), so nothing in the dev cluster exercises the
custody wiring end to end.

**Carry-forward from the Phase 3 review.** H1 (`DevCA.VerifyChain` returning a nil error for a chain
it never verified) is **fixed**. `modules/agent/internal/adapters/pki/ca.go:186` now verifies trust
first and only then classifies the window: a chain that fails at `now` is re-verified at an instant
inside the leaf's own window, and only a chain that verifies there is classified expired or
not-yet-valid. Regression tests exist and pass (`TestVerifyChainRejectsForgedLeafOutsideItsWindow`,
`TestVerifyChainReportsNotYetValid`).

Every finding below is green under the current gates; none of them is caught by a check.

---

## Medium

### M1. The operator erases `status.observedVersion` on every reconcile failure

`backend/cmd/operator-app/reconcile.go:91,95,100,105,116` — every call site passes `""` as the
observed version:

```go
return r.fail(ctx, "", fmt.Sprintf("release %s@%s not applicable: %v", r.Component, version, err))
```

and `fail`'s own comment states the intent: *"The observed version is NEVER advanced on a refusal:
the CR reads what is actually running, not what was attempted (SPEC-0039 AC6)."* But `WriteStatus`
(`cmd/operator-app/k8s.go:118-133`) replaces the whole status map with
`unstructured.SetNestedMap`, so writing `""` does not *hold* the previous value — it **erases** it.

Failure scenario: a data plane runs the signed release `0.1.0` (status `UpToDate`,
`observedVersion: 0.1.0`). The CR's `spec.version` moves to `0.2.0`, whose manifest is missing or
mis-signed. The reconciler refuses correctly and nothing is applied — but the CR now reads
`observedVersion: ""`, `phase: Failed`. An operator (or any automation reading the CR) can no longer
tell what the plane is actually running, which is exactly what AC6 asks the CR to answer. The
refusal path is also the one most likely to be read under pressure.

Fix: carry the last known observed version into `fail` — the reconciler already has it whenever the
failure is post-manifest, and `CurrentWorkloadImage` can supply it otherwise — or write only the
fields the failure owns rather than replacing the status map wholesale.

### M2. `custody.Bundle.Bootstrap` is a check-then-act across a released lock

`backend/modules/agent/internal/adapters/custody/bundle.go:123-131`:

```go
b.mu.Lock()
live := b.liveRootsLocked()
b.mu.Unlock()
if len(live) > 0 {
    return "", fmt.Errorf("custody: bundle already bootstrapped; rotate with Stage")
}
return b.Stage(ctx, name)
```

The emptiness check and the staging are not one critical section, so two concurrent `Bootstrap`
calls can both observe an empty bundle and both stage a root. The result is a bundle with two
"first" roots, an issuance root chosen by append order, and two revisions consumed — with a custody
key generated for each.

This is worth fixing because the sibling package already got it right and documents why:
`releasebundle.Bundle.Bootstrap` (`adapters/releasebundle/bundle.go:97-115`) performs the check and
the stage *under one lock* and says so — *"two concurrent bootstraps can never both pass the check
and both stage."* The two bundles are peers by design; they should not disagree on this.

The sharper point: the final fix round (`cfd8898`, backend `7c05a86`) is where `releasebundle`'s
`Bootstrap` was rewritten into one atomic step — the fix landed on one bundle and the sibling was not
carried with it. That is the shape of an incomplete fix, not an unnoticed bug.

Likelihood is low (bootstrap is a composition-root path), which is why this is Medium and not High.

### M3. `releasebundle.RemoveKey` rewrites the retirement timestamp of keys retired earlier

`backend/modules/agent/internal/adapters/releasebundle/bundle.go:174-178`:

```go
for i := range b.keys {
    if b.keys[i].ID == keyID {
        b.keys[i].RemovedAt = b.now()
    }
}
```

`Stage` deliberately permits re-staging a key ID whose every prior occurrence is retired (the
`ReconcileDir` convergence must not wedge on a name the bundle once knew), so `b.keys` can legally
hold several entries with the same ID. `RemoveKey` then stamps `now` on **all** of them, including
entries retired weeks earlier. `Keys()` is documented as "the operator-visible rotation state", and
those timestamps ride into `Snapshot` and therefore into durable state — so a rotation history that
is supposed to be the record of when a key stopped being trusted is silently rewritten.

Only the live entry should be stamped. Related, in the same file: `Restore`
(`bundle.go:340-357`) re-validates every key's PEM but accepts a `SigningKeyID` that names no live
key — a snapshot in that shape restores into a bundle whose `LatestReleaseTrustBundle` publishes a
`SigningKeyID` absent from `Keys`. `custody.Bundle.Restore` has the analogous gap (no check that the
roots it restores are non-empty or mutually consistent). `custody.Bundle.RemoveRoot`
(`custody/bundle.go:413-417`) carries the same stamp-all-duplicates loop; whether it can actually see
duplicate refs depends on `ReattachRoot`, which this review did not read — check it when fixing.

---

## Low

### L4. The residency service claims a store-enforced tenant scope that the durable store does not provide

`backend/modules/residency/internal/app/service.go:210-213` states: *"The caller's tenant scope is
enforced by the store: a cross-tenant read is the same coarse denial as an absent declaration
(SPEC-0001)."* The durable store does the opposite — it scopes the transaction *from its own
parameter* (`adapters/postgres/store.go:169-172`):

```go
func scoped(ctx context.Context, tenantID string) context.Context {
    return tenancy.WithTenant(ctx, tenancy.ID(tenantID))
}
```

`db.Pool.InTx` reads the tenant from context and issues `SET LOCAL app.tenant_id`, so the RLS policy
is evaluated against the tenant that was *asked for*, not the tenant the caller was verified as. A
call with a mismatched tenant argument is not denied — it is served under the requested tenant.

No exploit path today: `Declare` takes its tenant from the verified principal
(`adapters/grpc/server.go:125-140`), and `ObservePlacement` takes it from the enrolment token. The
same self-scoping pattern is used across the platform (`modules/security/internal/adapters/postgres/store.go`,
`modules/agent/internal/adapters/postgres/store.go:404`), so this is a convention, not a Phase 3.1
regression. What is wrong is the comment: it credits RLS with a second line of defense that, given
this call shape, cannot fire. Either the store should require the tenant from context
(`tenancy.Require`) and refuse a mismatched argument, or the comment should say plainly that the
caller is the only enforcement point.

### L5. SPEC-0046 AC4's read-only cause vocabulary has no producer or consumer on either side

AC4 is ticked as *"any read-only state in the UI or API identifies its cause"*. What landed is
vocabulary only:

- `backend/modules/repository/api/readonly.go` — `ReadOnlyCause`, `ReadOnlyState`,
  `ReadOnlyFromShard`. Grepping the tree, **no non-test code** calls any of them.
- `webfrontend/src/lib/readonlyCause.ts` — `describeReadOnly`, `readOnlyFromEnvelopeState`. Only
  `tests/readonly-cause.test.ts` imports them; no component renders the description.
- No wire field carries a cause: neither the usage contract nor any repository view proto has one,
  so even a producer could not reach the browser.

T-0044's exit record is honest about the reason (SPEC-0046's own assumption: PR-7's durability mode
has no product state yet, so the durability branch lands as the API cause contract). The mismatch is
between that honest record and an AC whose text is about surfaces. Worth restating in the phase's
recorded limits as *vocabulary defined, no surface produces or renders it* — otherwise a later reader
takes AC4 as evidence that a read-only repository in production explains itself, and it does not.

### L6. The release trust bundle is distributed but never applied on the receiving side

`cmd/operator-app/trust.go:27` loads the operator's verification keys once at startup from a mounted
directory, and nothing writes the bundle received over the reconcile channel into that directory —
`ReconcileDir` (`adapters/releasebundle/dir.go:35`) is the *control-plane-side* staging seam, wired
only from `cmd/controlplane-app/releasetrustconfig.go`. A rotation therefore reaches the data plane's
registry but does not change what the operator trusts until the ConfigMap is updated and the pod
restarts.

This is the EP-21 "distribution without application" limit recorded at board #20, so it is not a new
gap — but it is the single most load-bearing limit in the phase (it is what makes AC2's "no downtime
during overlap" a control-plane property rather than a fleet property), and it deserves to be named
in the phase's exit summary rather than only in a board record.

---

## What holds up well

- **The Declare door (T-0038, SPEC-0043 AC6/AC7).** The verified-caller seam is real: no `tenant_id`
  on the wire, the principal resolved through the identity gateway before any PDP question, a nil
  authenticator failing closed, one coarse refusal shape, and a composition root that refuses to open
  the door without a verifier key (`cmd/controlplane-app/residency.go:47-60`). The `platform_operator`
  grant is a standalone rego rule with a tenant-equality conjunct and no role-table entry, exactly as
  ADR-0067 decision 1 specifies.
- **The custody rotation window (T-0040, SPEC-0044 AC2).** `ReserveIssuance`/`CompleteIssuance`/
  `AbortIssuance` close the removal race properly — the in-flight count is checked inside the same
  critical section as the ledger scan, so a root cannot retire while a signature for it is crossing
  the seam. Serials are drawn from `crypto/rand` rather than a counter, which is the right answer for
  restart safety.
- **The custody transport posture.** `validateAddress` allows plain HTTP only on loopback behind an
  explicit test flag; `PublicKey` refuses a key that reports itself exportable or is not P-256;
  `keyPath` refuses anything that is not a plain identifier before it reaches a URL path.
- **The two-bundles separation (SPEC-0045).** CA trust and release trust share no staging mechanism,
  no wire field and no type, and the AC2 test asserts per delivery that one artifact never carries
  the other. The naming discipline throughout the packages is unusually careful.
- **The operator chart's tag retirement.** `templates/operator.yaml` `fail`s loudly on a
  `operator.image.tag` rather than silently ignoring it — the right failure mode for a change that
  would otherwise lie about which image is running.
- **Absence handling in the usage path.** The bff shapes the throttle observation half by half
  (`internal/usage/client.go`), and an unknown enum maps to the empty string rather than an invented
  direction; "not metered" cannot become a zero.

---

## Disposition (2026-08-16, same day)

**Fixed at:** backend `86f4f0b`, governance `deb9cb6`, super-repo `b9c268f` (bff and webfrontend
unchanged). The findings above were all found at the reviewed state named in the header; this
section binds to the fix-round state.

All six findings were acted on. Code fixes are backend-only (one submodule, one commit); the two
scope findings became recorded limits in governance, as the disposition below originally proposed.

- **M1 — fixed.** `Reconciler` now carries `lastObserved`, advanced only by a pass that observed or
  converged the workload, and `fail` reports it instead of `""`. The status map therefore keeps
  naming what is RUNNING across a refusal. Test:
  `TestFailureKeepsTheObservedVersionOfWhatIsRunning` (converge 0.1.0 → desired 0.2.0 with no
  manifest → status reads Failed *and* 0.1.0). Red before the change. Scope of the fix: the memory
  is per-process, so the first pass after an operator restart that fails before observing anything
  still reports no version — genuinely unknown at that point, and the code says so. Reading the
  running image back from the workload on that path would make it restart-durable; that is a
  further change, not this one.
- **M2 — fixed.** `custody.Bundle` gains `firstRootMu`, held across the whole of `Bootstrap` and
  `ReattachRoot` (both claim the FIRST root and both cross the custody seam, which `mu` must not be
  held across), plus an emptiness re-check under `mu` at the append point so a concurrent `Stage`
  cannot slip a root in between. `ReattachRoot` had the identical race and is fixed in the same
  pass. Tests: `TestBootstrapIsAtomicUnderConcurrency`, `TestReattachIsAtomicUnderConcurrency` —
  both showed 8 of 8 racers succeeding before the change.
- **M3 — fixed.** `releasebundle.RemoveKey` stamps only the LIVE occurrence, so an earlier
  retirement keeps the instant it happened. `releasebundle.Restore` now refuses a snapshot whose
  `SigningKeyID` names no live key, whole rather than half. Tests:
  `TestRemovalStampsOnlyTheLiveOccurrence`, `TestRestoreRefusesASigningKeyThatIsNotLive`, both red
  before. `custody.RemoveRoot` gets the same one-line guard, stated as an invariant rather than a
  repair: the custody service refuses a key name it already holds, so two entries for one reference
  are not reachable through the API today and no test claims otherwise.
- **L4 — fixed, residency-local.** `postgres.scoped` now returns an error and refuses a tenant
  argument that contradicts the tenant already on the context, before any database work; the
  service comment no longer credits RLS with a defense it cannot provide. This also closes an
  adapter-parity gap — the in-memory store already refused a mismatch. One residual difference is
  deliberate: the in-memory store additionally refuses an *unscoped* context, while the durable one
  lets the argument establish the scope. Tests: `scope_test.go` (`TestScopeRefusesATenantOtherThanTheContextsOwn`,
  `TestMismatchedCallNeverReachesThePool` — the latter runs against a `Store` with no pool at all,
  proving the refusal precedes any database work). The same self-scoping pattern in the security and
  agent adapters is **untouched**: sweeping it is a platform decision, recorded as a follow-up in
  the phase plan.
- **L5, L6 — recorded, not fixed.** Both are scope, not defects: they are now recorded limits (f)
  and (g) in `governance/docs/plans/phase-3-byo-v2.md`, under "Recorded limits carried out of Phase
  3.1". No ticked task AC and no spec text was edited, and no Accepted ADR was touched.
- **Gate coverage** — unchanged and still worth acting on: `helm` is absent here, so the
  rendered-chart halves of two gates remain unrun. That is an environment prep item, not a code
  change; it belongs to whoever runs the final exit matrix.

## Suggested disposition (as written at review time)

1. **M1** — fix before the phase is called closed; it is a small change in `reconcile.go` and it is
   the only finding that degrades an operator-facing answer in production.
2. **M2, M3** — fix in the next fix round; both are small and both are correctness of state the
   durable snapshot carries.
3. **L4** — decide which way it goes (enforce in the store, or correct the comment) and apply the
   same answer platform-wide, since the pattern is not local to residency.
4. **L5, L6** — record, do not fix here: both are scope questions that belong to the phase's limits
   list, not to a code change.
5. **Gate coverage** — the helm-absent skip now silences rendered assertions in two gates. Consider
   making the phase exit require one run with `helm` on PATH, so "verify OK" and "the chart renders
   as asserted" stop being different claims.
