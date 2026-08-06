# Super-repo orchestration. Real per-repo build/test targets live in each submodule.
.PHONY: bootstrap submodules dev-up dev-smoke update-pins verify lint-shell codegen codegen-check policy-check bench-storage rulesets rulesets-apply rulesets-check
bootstrap: submodules ## init submodules + show toolchain floors
	@./scripts/bootstrap.sh
verify: ## super-repo fitness gates: dependency direction + version floors + dev image pins (T-0001, invariants 22–23)
	@./scripts/check-dep-direction.sh
	@./scripts/check-version-floors.sh
	@./scripts/check-dev-images.sh
lint-shell: ## shellcheck the fitness scripts (T-0009); CI gates this on every PR
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed: https://shellcheck.net"; exit 1; }
	@shellcheck scripts/*.sh && echo "shellcheck: OK"
bench-storage: ## T-0007: benchmark git on SeaweedFS-FUSE vs a block-backed dir + probe POSIX semantics
	@./scripts/bench-storage.sh
rulesets: ## show what the ADR-0031 merge-enforcement rulesets would do (read-only)
	@./scripts/apply-rulesets.sh plan
rulesets-apply: ## apply the ADR-0031 rulesets to all repos + drop legacy protection (needs an admin token)
	@./scripts/apply-rulesets.sh apply
rulesets-check: ## fail if any repo drifted from ADR-0031 (T-0002 AC5); not in CI — needs admin scope
	@./scripts/apply-rulesets.sh check
codegen-check: ## fail if any consumer's gen/ drifted from the pinned contracts (T-0020, ADR-0032)
	@./scripts/check-codegen-fresh.sh
policy-check: ## T-0005: run the real authz path — bff PEP → gRPC → backend PDP → governance/policies
	@./scripts/check-policy-composition.sh
codegen: ## regenerate Go (backend, bff) + TS (webfrontend) from governance/contracts (ADR-0022)
	@cd backend && buf generate
	@cd bff && buf generate
	@cd webfrontend && buf generate
submodules: ## init/update all submodules
	git submodule update --init --recursive
dev-up: ## start the Minikube dev cluster: addons + mkcert TLS + manifests (T-0003, ADR-0024)
	@./scripts/dev-up.sh
dev-smoke: ## T-0003 integration smoke test: deployments up, 200 over real TLS at *.gitsaas.test
	@./scripts/smoke-dev.sh
update-pins: ## fetch latest submodule commits (review before committing the bump)
	git submodule update --remote --merge
