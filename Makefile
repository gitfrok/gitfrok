# Super-repo orchestration. Real per-repo build/test targets live in each submodule.
.PHONY: bootstrap submodules dev-up update-pins verify codegen
bootstrap: submodules ## init submodules + show toolchain floors
	@./scripts/bootstrap.sh
verify: ## super-repo fitness gates: dependency direction + version floors (T-0001, invariants 22–23)
	@./scripts/check-dep-direction.sh
	@./scripts/check-version-floors.sh
codegen: ## regenerate Go (backend, bff) + TS (webfrontend) from governance/contracts (ADR-0022)
	@cd backend && buf generate
	@cd bff && buf generate
	@cd webfrontend && buf generate
submodules: ## init/update all submodules
	git submodule update --init --recursive
dev-up: ## start the Minikube dev cluster (see deploy/dev) — ADR-0024
	@echo "TODO(T-0003): minikube start + ingress/ingress-dns + mkcert *.gitsaas.test; images from deploy/dev/versions.env"
update-pins: ## fetch latest submodule commits (review before committing the bump)
	git submodule update --remote --merge
