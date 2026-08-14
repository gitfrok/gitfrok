# Super-repo orchestration. Real per-repo build/test targets live in each submodule.
.PHONY: bootstrap submodules dev-up dev-provision dev-smoke update-pins verify lint-shell codegen codegen-check policy-check threshold-parity surfaces surfaces-check ceremony-check dispatch-check portability-check bench-storage rulesets rulesets-apply rulesets-check trust-bundle-check byo-chart-check signed-releases-check
bootstrap: submodules ## init submodules + show toolchain floors
	@./scripts/bootstrap.sh
verify: ## super-repo fitness gates: dependency direction + version floors + dev image pins (T-0001, invariants 22–23) + BYO install anti-faking (T-0031, SPEC-0039 AC2/AC8)
	@./scripts/check-dep-direction.sh
	@./scripts/check-version-floors.sh
	@./scripts/check-dev-images.sh
	@./scripts/check-image-trust-bundle.sh
	@./scripts/check-signed-releases.sh
	@./scripts/check-byo-chart.sh
lint-shell: ## shellcheck the fitness scripts (T-0009); CI gates this on every PR
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed: https://shellcheck.net"; exit 1; }
	@shellcheck scripts/*.sh && echo "shellcheck: OK"
trust-bundle-check: ## verify versioned public Cosign verification keys (ADR-0044)
	@./scripts/check-image-trust-bundle.sh
byo-chart-check: ## T-0031: the BYO chart carries no secret, token is reference-only, no inbound path (SPEC-0039 install scope)
	@./scripts/check-byo-chart.sh
signed-releases-check: ## T-0032: no unsigned/mis-signed release is applicable; release trust bundle intact (SPEC-0039 AC3, ADR-0044)
	@./scripts/check-signed-releases.sh
bench-storage: ## T-0007: benchmark git on SeaweedFS-FUSE vs a block-backed dir + probe POSIX semantics
	@./scripts/bench-storage.sh
rulesets: ## show what the ADR-0054 main-guard ruleset would do, read-only (needs an admin token)
	@./scripts/apply-rulesets.sh plan
rulesets-apply: ## apply main-guard to all repos + delete ADR-0031's superseded rulesets (admin token)
	@./scripts/apply-rulesets.sh apply
rulesets-check: ## fail if main-guard drifted, or if a pull-request rule came back (ADR-0054)
	@./scripts/apply-rulesets.sh check
codegen-check: ## fail if any consumer's gen/ drifted from the pinned contracts (T-0020, ADR-0032)
	@./scripts/check-codegen-fresh.sh
policy-check: ## T-0005: run the real authz path — bff PEP → gRPC → backend PDP → governance/policies
	@./scripts/check-policy-composition.sh
threshold-parity: ## fail if the merge gate's Go severity threshold drifted from the reviewed rego (SPEC-0029 AC3)
	@test -f governance/policies/gitsaas/authz/authz.rego || \
	  { echo "threshold-parity: governance/policies/gitsaas/authz/authz.rego is absent — run 'make submodules' first"; exit 1; }
	@cd backend && go test -count=1 -run TestSecurityGateSeverityThresholdMatchesReviewedRego ./modules/security/internal/app/
surfaces-check: ## fail if any repo's agent surfaces drifted from governance/canonical (ADR-0037)
	@./scripts/check-agent-surfaces-fresh.sh
surfaces: ## regenerate every agent surface from governance/canonical (ADR-0037)
	@./governance/scripts/gen-agent-surfaces.sh .
ceremony-check: ## fail if this PR's declared ceremony tier does not match its diff (SPEC-0012)
	@./scripts/check-ceremony-tier.sh
dispatch-check: ## fail if this PR spans two submodules, or leaves its declared Scope (SPEC-0013)
	@./scripts/check-dispatch-scope.sh
portability-check: ## fail if any tracked script would break on macOS (SPEC-0014, T-0003 AC4)
	@./scripts/check-shell-portability.sh
codegen: ## regenerate Go (backend, bff) + TS (webfrontend) from governance/contracts (ADR-0022)
	@cd backend && buf generate
	@cd bff && buf generate
	@# webfrontend's protoc-gen-es is a devDependency, not a global binary, so its own
	@# node_modules/.bin goes on PATH for this run only — the same shape
	@# scripts/check-codegen-fresh.sh uses, which is why the freshness gate passed while
	@# this target failed with "protoc-gen-es: executable file not found in $$PATH".
	@[ -x webfrontend/node_modules/.bin/protoc-gen-es ] || \
	  { echo "codegen: webfrontend/node_modules is absent — run 'npm ci --prefix webfrontend' first"; exit 1; }
	@cd webfrontend && PATH="$$PWD/node_modules/.bin:$$PATH" buf generate
submodules: ## init/update all submodules
	git submodule update --init --recursive
dev-up: ## start the Minikube dev cluster: addons + mkcert TLS + manifests (T-0003, ADR-0024)
	@./scripts/dev-up.sh
dev-provision: ## apply DB migrations + provision the Zitadel OIDC client + verify the login roundtrip (idempotent)
	@./scripts/dev-provision.sh
dev-smoke: ## T-0003 integration smoke test: deployments up, 200 over real TLS at *.gitsaas.test
	@./scripts/smoke-dev.sh
update-pins: ## fetch latest submodule commits (review before committing the bump)
	git submodule update --remote --merge
