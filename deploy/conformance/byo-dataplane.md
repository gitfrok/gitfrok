# BYO data-plane conformance matrix (T-0031 AC1/AC2, T-0032 AC3–AC7; SPEC-0039)

SPEC-0039 AC1 demands the record state, **per row**, what was verified on a real cluster
and what was verified in a conformance harness. A blurred row is a failed criterion,
so the two columns below never share a cell: every row says harness, real cluster, or
"not run" — and at this task's exit, no row has a real-cluster verification, because the
live-cluster proof is the phase exit, not T-0031. Which cloud gets a real cluster in CI
is the cost decision SPEC-0039's open questions name; it is recorded here as UNMADE, not
implied.

**Why every real-cluster column reads "not run" (annotated 2026-08-16, per SPEC-0045 AC3's honesty
rule):** these rows are pending execution by **T-0042**
(`governance/docs/tasks/T-0042-real-cluster-conformance.md`), which stands **Todo — blocked-by
T-0003's cluster lane availability**. The lane is the standing owner of every infrastructure-bound
demonstration since Phase 1, and T-0042 does not conjure clusters the lane does not provide — so,
exactly as T-0042 applies AC3's rule to its own dependency, each "not run" below is a named,
explained exception, not silence. This annotation records the cause; it fabricates no result. (Row
5's "not applicable" is structural — an arch-test boundary with no cluster half — not a lane wait.)
The plan's exit bar remains at least one real cluster per cloud, or an honestly annotated subset —
never a silent one.

**Harness** = the backend Go test suite (`go test -race ./...` at the pinned backend
commit) plus the super-repo chart gate `scripts/check-byo-chart.sh`. Backend test names
are cited; run them with:

```sh
cd backend && go test -race -count=1 ./platform/clouddriver/... ./platform/agentclient/... ./internal/arch/... ./cmd/dataplane-app/... ./modules/rollout/...
./scripts/check-byo-chart.sh
./scripts/check-signed-releases.sh
```

## Rows

| # | Requirement | Driver | Harness evidence | Real-cluster evidence |
|---|-------------|--------|------------------|-----------------------|
| 1 | Driver selection returns the registered driver with its per-cloud facts | gke | `platform/clouddriver` `TestSelectReturnsRegisteredDrivers`, `TestProvidersListsAllClouds` | not run |
| 2 | Driver selection returns the registered driver with its per-cloud facts | eks | same tests (eks row of the table cases) | not run |
| 3 | Driver selection returns the registered driver with its per-cloud facts | aks | same tests (aks row of the table cases) | not run |
| 4 | Refusal when a required per-cloud setting is absent — no silent default | gke, eks, aks | `platform/clouddriver` `TestSelectRefusesMissingRequiredSetting`; unknown provider: `TestSelectRefusesUnknownProvider`; install path: `cmd/dataplane-app` `TestRunAgentRefusesMissingDriverSetting` | not run |
| 5 | Boundary: provider-specific import outside the driver seam fails the arch test (SPEC-0039 AC2, invariant-22 shape) | all | `internal/arch` `TestForbiddenEdgesAreRejected` (rule `provider-import-outside-driver`, fixture `bad_provider_import.go.txt`) + `TestLegitimateCodeIsAccepted` (`good_provider_import.go.txt`) | not applicable |
| 6 | Install → self-register → serve over the T-0030 channel (Enrol, EnrolmentAck, issued ClientCertificate stored, CONNECTED in the registry) | gke | `platform/agentclient` `TestInstallSelfRegistersAndServe` — over-the-wire against the agent module's public composition root, with driver selection through `clouddriver.Select` | not run |
| 7 | Install → self-register → serve | eks | harness covers the DRIVER HALF only (`TestSelectReturnsRegisteredDrivers`, refusal tests). The over-the-wire path has not run with eks facts in any environment | not run |
| 8 | Install → self-register → serve | aks | harness covers the DRIVER HALF only (as eks row) | not run |
| 9 | CertificateRotation applied with certificate_id correlation; failure enum UNPARSABLE/UNTRUSTED/PERSIST_FAILED/CLOCK_SKEW | all | `platform/agentclient` `TestApplyRotationOutcomes`, `TestApplyRotationPersistsCredential`, `TestRotationAckCorrelation`; rotation-over-the-wire inside `TestInstallSelfRegistersAndServe` | not run |
| 10 | Token secrecy — never logged, echoed, or persisted by the agent (SPEC-0038 AC2) | all | `platform/agentclient` `TestStoreNeverSeesTheToken` + log/stored-credential assertions in `TestInstallSelfRegistersAndServe`; refusal echoes nothing: `TestBootstrapRefusalIsCoarse` | not run |
| 11 | Token secrecy — no token in chart-written-back artifacts (values, ConfigMap, CR status, rendered manifests) | all | super-repo `scripts/check-byo-chart.sh` (values carry no token field; chart authors no Secret; env is secretKeyRef-only; CRD is reference-only with credential-free status; with helm present: a `--set enrolment.token` sentinel never reaches rendered output) | not run |
| 12 | No inbound path opened (SPEC-0039 out-of-scope rule; AC4 shape) | all | `platform/agentclient` `TestInstallSelfRegistersAndServe` tripwire (customer-cluster listener counted 0 inbound connections); `scripts/check-byo-chart.sh` (no Service/Ingress/Gateway/LoadBalancer/NodePort/hostPort template; agent wiring opens no `net.Listen`) | not run |
| 13 | Install config contract (disabled by default; missing install inputs refuse; server name derived, never invented) | all | `cmd/dataplane-app` `TestAgentDisabledByDefault`, `TestAgentRequiresInstallInputs`, `TestAgentConfigResolved`, `TestParseCloudSettings`, `TestHostOf` | not run |
| 14 | `helm lint` / `helm template` render the install (required values enforced by `required`) | all | `scripts/check-byo-chart.sh` — runs only when `helm` is on PATH; where it is not, the gate says so on its own output line (the authoring machine of this row had no helm: static assertions only) | not run |

| 15 | A release is signed and its signature verified before anything is applied; unsigned/mis-signed refused, audited, running version untouched (ADR-0044) | all | `modules/rollout/internal/domain` `TestVerifyAcceptsCorrectlySignedRelease`, `TestVerifyRefusesUnsignedRelease`, `TestVerifyRefusesMisSignedRelease`, `TestVerifyRefusesTamperedIdentity`, `TestVerifyRefusesMalformedRelease`, `TestVerifyAcceptsRotationOverlapKey`, `TestTrustBundleRefusesGarbage`, `TestTrustBundleRefusesPrivateKey`; refusal leaves state untouched and audited: `modules/rollout/internal/app` `TestPublishRefusesUnsignedLeavesStateUntouched`, `TestPublishRefusesMisSigned`; super-repo `scripts/check-signed-releases.sh` (bundle integrity + a tampered manifest exits 1) | not run |
| 16 | Upgrades are reconcile-based; no inbound connection to the customer's cluster — a test fails if a control-plane component dials a data-plane address | all | `internal/arch` `TestNoControlPlaneDialsDataPlane` (real tree, 0 violations), `TestNoDataPlaneDialGateCanFail` (fixture caught), `TestNoDataPlaneDialIgnoresTestFiles`; reconcile is idempotent: `modules/rollout/internal/app` `TestPublishSameGenerationIsIdempotent`, `TestReconcileTerminalIsNoOp`; super-repo `scripts/check-byo-chart.sh` no-inbound tripwire stays 0 (no Service/Ingress/LB/hostPort; agent wiring opens no listener) | not run |
| 17 | A failed upgrade rolls back to the previous version and reports a reason; no half-applied state | all | `modules/rollout/internal/app` `TestReconcileFailureRollsBackToPrior`; integration against a fake cluster: `modules/rollout` `TestIntegrationRolloutFailureRollbackAgainstFakeCluster` (reads ROLLED_BACK, carries a reason, cluster back on the prior version) | not run |
| 18 | Rollout observable per data plane; a data plane silent since a rollout began is stale, never "upgraded" | all | `modules/rollout/internal/domain` `TestDeriveStatusTerminalNeverStale`, `TestDeriveStatusSilentRolloutGoesStale`, `TestDeriveStatusReportResetsContact`; `modules/rollout/internal/app` `TestReportActualAppliesOnlyOnReportedConvergence`; integration `TestIntegrationSilentDataPlaneIsStaleNeverUpgraded`; CRD status fields (observedVersion/phase/message/lastHeartbeatTime) tripwired by `scripts/check-byo-chart.sh` | not run |
| 19 | A customer may pin or defer within a supported window; the window's expiry is visible; upgrades are not silently forced | all | `modules/rollout/internal/app` `TestWindowHoldsPinnedVersion`, `TestExpiredWindowDoesNotSilentlyForce` | not run |

## Recorded limits (not defects of this task)

- **Clock skew** beyond the configured leeway (`GITFROK_AGENT_CLOCK_SKEW_LEEWAY`, default
  5m) is surfaced as the CLOCK_SKEW failure reason, not solved.
- **Proxy-only egress** is ADR-0017's open follow-up; this matrix does not claim
  proxy-traversal evidence in any row.
- **Operator reconcile** (SPEC-0039 AC3–AC7) is T-0032's surface. T-0032 lands the harness half — the rollout engine, signature
  verification, reconcile idempotency, rollback, staleness, and the no-inbound dial
  assertion (rows 15–19), plus the release-signing tooling/trust bundle and the
  reconcile-contract tripwires in this tree. Since T-0041 (super-repo@febf0f7) the operator
  ships as the vendor's signed, digest-pinned image defaulted by the chart — it is no longer
  a required install value; what remains real-cluster-only is the operator converging a live
  workload.
