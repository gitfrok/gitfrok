# Phase 3 code review — T-0029…T-0034

Reviewed ranges (hand-written code only; `gen/**`, `*.pb.go`, `src/gen/**` excluded):

- backend `90bf1a1..d3f4ad6` — 101 files, +15829/−72 (includes T-0029, the Phase-2 carry-over)
- bff `d63fdab..e2344de` — usage aggregation
- webfrontend `a44d1f1..0e80261` — usage view + tests
- governance `5f7dec4..170246f` — additive contracts, authz roles, exit records
- super-repo `6cb8b5c..824090c` — chart, release contract, `byo-chart` gate, runbook

Rubric: SPEC-0037…SPEC-0041 acceptance criteria, ADR-0060/0061, `governance/docs/agents/invariants.md`,
and the four "must not" rules the Phase-3 plan sets for itself.

Gate state at the pins: backend `go build` / `go vet` / `go test ./...` green; bff green; webfrontend
`tsc --noEmit` and 71 vitest cases green; super-repo `verify` (including the new `byo-chart` check),
`codegen-check`, `surfaces-check`, `threshold-parity` and `policy-check` all green. Every finding
below is a gap in coverage or in a record, not a failing gate.

---

## High

### H1. `DevCA.VerifyChain` reports success for a chain it never verified

`backend/modules/agent/internal/adapters/pki/ca.go:180`:

```go
_, err = leaf.Verify(...)
if err == nil { return leaf.Raw, false, nil }
if !now.Before(leaf.NotAfter) || now.Before(leaf.NotBefore) {
    return leaf.Raw, !now.Before(leaf.NotAfter), nil   // err == nil
}
return nil, false, fmt.Errorf("pki: chain does not verify: %w", err)
```

When `Verify` fails **for any reason** and the leaf happens to be outside its validity window, the
function returns a nil error and hands back the leaf. Verified by probe, not by reading:

```
PROBE forged not-yet-valid: err=<nil> expired=false leafReturned=true
PROBE forged expired:       err=<nil> expired=true  leafReturned=true
```

Both probes used a **self-signed** certificate carrying a victim's subject. The intent is visible —
the comment says a trusted chain past `NotAfter` should report `expired=true` rather than an error,
so expiry can be audited instead of looking like an attack — but the implementation reaches that
branch without establishing trust first.

Two consequences, one latent and one live:

1. **Latent impersonation.** `AdmitPeerCertificates` (`internal/app/service.go:354`) is saved only
   because the very next call, `issuer.Inspect`, does `cert.CheckSignatureFrom(ca.cert)`
   (`pki/ca.go:167`). An end-to-end probe against the real `DevCA` confirms the forged certificate is
   refused today — with `pki: leaf not issued by this ca`, i.e. by `Inspect`, not by `VerifyChain`.
   The door's safety therefore rests on an incidental second check, and the function whose documented
   job is "checks a peer chain against this CA" does not.
2. **Live: a not-yet-valid certificate is admitted.** For `now < NotBefore` the branch returns
   `expired=false`, so a certificate this CA *did* issue but whose validity has not begun passes
   admission as healthy. SPEC-0038's non-functional section names clock skew as a first-class failure
   mode; it is enforced on the expired side and not on the not-yet-valid side.

The test suite cannot see either. `TestVerifyChainRejectsForeignCAs` (`ca_test.go:109`) uses a rogue
certificate that is **currently valid**, so it lands in the final `return nil, false, err` and passes
for the wrong reason. The service-level admission tests use `newFakeIssuer()`
(`internal/app/service_test.go:87`), so the real CA's verification path has no coverage above the
adapter.

Fix shape: establish trust first, then classify. Return the trust failure whenever `Verify` fails for
any reason other than the validity window, and treat "outside the window" as a *classification* of a
chain that otherwise verifies — with `expired` distinguishing past-`NotAfter` from
before-`NotBefore`, both refused.

### H2. Envelope enforcement is computed and never applied — nothing in the data plane consumes it

The metering service derives counters, evaluates envelopes and emits desired state carrying
`MaxCIConcurrency` and `QueueDepthCap` (`modules/metering/internal/app/service.go`). On the wire,
`EnvelopeStateUpdate` appears in exactly three places outside `gen/`: the gateway that sends it, the
gateway's own integration test, and nothing else.

The shipped data-plane client ignores it by comment — `platform/agentclient/agentclient.go:273`:

```go
default:
    // DesiredState, commands and friends belong to later specs (SPEC-0039/0041); the
    // enrolment surface ignores them.
```

`grep` for `MaxCIConcurrency` / `QueueDepthCap` outside `modules/metering` and `gen/` returns only
the control-plane's own configuration parsing. No CI runtime reads either value, so a breached CI
envelope reduces nothing in the customer's cluster. The `EnvelopeStateAck` the gateway handles
(`adapters/grpc/gateway.go:226`) is produced only by the integration test's stub client.

SPEC-0041 AC9 says envelope state "reaches the data plane as desired state over the agent channel
**and is applied there**", and AC5 describes running jobs finishing while queued jobs are delayed and
visibly caused. Neither behaviour exists end to end.

T-0034's exit record states AC9 as "delivered **and acked** on the channel" — literally true of the
test client, and it reads as met. The recorded-limits block below it carries AC8's product
distinction, the deferred dimensions and prices — **it does not carry this**. This is the same class
the wave-2 review caught in the H1 record: a criterion whose wording is true of the code that exists
and false of the criterion as written.

---

## Medium

### M3. The no-inbound fitness scan does not cover two of the four control-plane modules

`internal/arch/inbound.go:32` scans `modules/rollout`, `modules/agent`, `cmd/controlplane-app`. Phase
3 added two more control-plane contexts — `modules/metering` and `modules/residency`, both composed
into `cmd/controlplane-app` — and neither is in the scanned set. A dial added inside either passes.

The gate itself is well built: `TestNoDataPlaneDialGateCanFail` proves it is not vacuous, which is
exactly the discipline the M11 parity-test lesson called for. The tree list is the gap, and it will
silently narrow further as the control plane grows: consider deriving the list from what
`cmd/controlplane-app` imports rather than maintaining it by hand.

### M4. ADR-0061's central claim is stronger than the mechanism delivers

ADR-0061 §2 says a data plane "cannot under-report itself into a smaller envelope, because it is not
asked". The implementation matches the ADR's *letter*: authoritative values come from
`TelemetrySample`, and `UsageSample` — the data plane's own totals — is kept only for divergence
(`domain/ledger.go:72`, `DeriveValue` at `:103`).

But both messages originate in the same customer-controlled process. A data plane that under-reports
its **telemetry counters** under-reports the authoritative number directly; what the design actually
buys is that there is no second, more-convenient channel for it to do so, and that divergence between
the two is detectable. That is worth having, and it is not what §2 claims.

Nothing to change in the code. The ADR's rationale should say what the split buys — one reporting
path instead of two, with cross-checking — rather than implying the customer's cluster is out of the
loop.

---

## Low

### L5. The governance submodule pin sits on a leftover branch label

`git submodule status` shows `governance (heads/docs/phase-3-exit-records)`. The commit matches
`origin/main`, so the pinned content is correct and no rule about merged commits is broken — but the
standing main-only preference means the local branch should be gone. Housekeeping, not a defect.

---

## Verified good

Each of these is a place the criteria could have been satisfied on paper and were not:

- **Reserved request-ID namespaces are now plural and enforced together.** `audit:` and `ci:` are
  both refused from wire callers (`modules/security/internal/app/service.go:41`), which is precisely
  what SPEC-0037 AC6 asked for after the wave-2 N2 finding — the derived-ID prefix got the same
  treatment as the one it was modelled on, rather than a second unguarded namespace.
- **Token hygiene holds under grep.** No log line, error string or metric label in the agent service,
  the agent client or the data-plane wiring carries a token or a certificate PEM; refusal detail is a
  closed vocabulary (`refusalDetail`, `gateway.go`), so a cause can never widen into a value.
- **Residency silence is structural.** `SilenceGaps` (`modules/audit/internal/domain/residency.go:83`)
  produces a gap over the whole window when no placement fact exists, so "no contradiction" cannot
  render as compliance — the SPEC-0031 AC10 discipline carried into a new section.
- **Deferred metering dimensions are typed, not documented.** `CoverageDeferred` plus
  `DeferredReasons` (`modules/metering/api/metering.go:110–136`) make "not metered" a value the view
  must render, rather than a note someone has to remember.
- **The envelope enforcement vocabulary cannot express a git block.** `ThrottleFor` admits exactly
  three actions, and the AC7 test iterates every PRD dimension asserting membership — a structural
  guarantee rather than a behavioural sample. (Its reach is bounded by H2: nothing applies these
  actions yet.)
- **The exit records carry their limits honestly.** The plan names the fifth criterion as *carried,
  not met*, states that every conformance-matrix row is harness-evidence with the real-cluster column
  reading "not run", and lists the in-memory stores, the CA key custody and SPEC-0039 AC8's migration
  proof as carried. That is the standard the wave-2 H1 record failed to meet, and it is met here —
  which is what makes H2's omission stand out rather than blend in.

## Recommended disposition

- **H1** — fix in code; it is a small reordering, and it deserves the two tests the current suite
  lacks: a foreign CA whose leaf is outside its validity window, and a genuine leaf presented before
  `NotBefore`. Consider having the service-level admission tests run against the real `DevCA` at least
  once, since the fake issuer is what hid this.
- **H2** — decide, then record. Either the data-plane side of AC9/AC5 is built, or T-0034's exit
  record moves AC9 into its recorded-limits block and says plainly that enforcement is computed but
  not yet applied. What should not survive is the current wording, which reads as met.
- **M3** — extend the scanned trees; cheap, and it protects the phase's own "must not" rule.
- **M4** — one paragraph in ADR-0061's rationale.
- **L5** — delete the local branch.


---

## Disposition (2026-08-15, super-repo `4747ed8`)

| Finding | Outcome |
|---|---|
| H1 CA classifies the window before establishing trust | **Fixed** — backend@e722046 |
| H2 envelope computed, never applied | **Record corrected + T-0035 filed** — governance@7b7115e |
| M3 no-inbound scan misses two control-plane modules | **Fixed** — backend@e722046 |
| M4 ADR-0061 §2 overclaims | **Fixed** — governance@7b7115e |
| L5 leftover branch label | **Fixed** — branch deleted |

**H1.** Trust is established first; the window is classified only for a chain this CA signed. The
contract carries `api.Validity` (valid / expired / not-yet-valid) instead of a bare `expired bool`,
so a certificate presented before its `NotBefore` is refused *and* audited under its own reason —
the clock-skew case that used to be admitted as healthy. The two tests that missed it are fixed: the
foreign-CA case now presents forged leaves in every window, and admission gained a suite that runs
against the real `DevCA` rather than the fake issuer that hid this.

**H2 — record, not code, and deliberately so.** The data-plane half needs a design decision before
it needs code: the CI dispatcher claims at most one job per tick and scales by KEDA replicas, so
`MaxCIConcurrency` has nowhere to bind. Building it inside a review-fix commit would have meant
picking claim-gate versus scaler-input silently. T-0034's AC9 now reads "partially met, and carried"
with the reason in its limits block; **T-0035** owns the decision and the seven ACs behind it.

**M3.** The scanned tree list is derived from what `cmd/controlplane-app` imports, transitively, so
a module that reaches the control plane joins the gate with it. A test asserts the derivation reaches
`modules/metering` and `modules/residency`, the two phase 3 added and the old hand-maintained list
missed.

Gates after: backend build/vet/`go test ./...` green; super-repo `verify` (with `byo-chart`),
`codegen-check` and `surfaces-check` green.
