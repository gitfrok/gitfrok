# BYO data-plane conformance matrix (T-0031, SPEC-0039 AC1)

SPEC-0039 AC1 demands the record state, **per row**, what was verified on a real cluster
and what was verified in a conformance harness. A blurred row is a failed criterion,
so the two columns below never share a cell: every row says harness, real cluster, or
"not run" — and at this task's exit, no row has a real-cluster verification, because the
live-cluster proof is the phase exit, not T-0031. Which cloud gets a real cluster in CI
is the cost decision SPEC-0039's open questions name; it is recorded here as UNMADE, not
implied.

**Harness** = the backend Go test suite (`go test -race ./...` at the pinned backend
commit) plus the super-repo chart gate `scripts/check-byo-chart.sh`. Backend test names
are cited; run them with:

```sh
cd backend && go test -race -count=1 ./platform/clouddriver/... ./platform/agentclient/... ./internal/arch/... ./cmd/dataplane-app/...
./scripts/check-byo-chart.sh
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

## Recorded limits (not defects of this task)

- **Clock skew** beyond the configured leeway (`GITFROK_AGENT_CLOCK_SKEW_LEEWAY`, default
  5m) is surfaced as the CLOCK_SKEW failure reason, not solved.
- **Proxy-only egress** is ADR-0017's open follow-up; this matrix does not claim
  proxy-traversal evidence in any row.
- **Operator reconcile** (SPEC-0039 AC3–AC7) is T-0032's surface; the CRD/RBAC/CR shape
  laid by this task is unverified beyond schema honesty.
