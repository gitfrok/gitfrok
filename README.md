# gitfrok — super-repo

Multi-tenant Git SaaS (GitLab-Ultimate governance, GitHub UX, flat rate, BYO-Kubernetes), built with
**AGDD** (ADR-0028) across four submodules (ADR-0027). This repo holds **pinned submodule commits and
dev orchestration only** — no product code.

```
governance/    [sub]  control surface: ADRs, specs, contracts/, policies/, process, agent rules
backend/       [sub]  Go modular monolith, one binary per plane (ADR-0025)
bff/           [sub]  Go BFF, aggregation only
webfrontend/   [sub]  Astro + React SSR
```

## Quickstart

```bash
git clone --recurse-submodules <this-repo>
make bootstrap      # init submodules + report toolchain floors (.tool-versions)
make dev-up         # Minikube dev cluster on *.gitsaas.test with mkcert TLS (ADR-0024)
make dev-smoke      # assert the cluster is actually serving
```

## Where to look

- **[`HANDOFF.md`](HANDOFF.md)** — where work stands, and the one page a new session should read.
- **`AGENTS.md`** (this repo) → **`governance/AGENTS.md`** — the rules, in that order.
- **`governance/docs/adr/README.md`** — decisions; governance is the Source of Truth (ADR-0001).
- **[`deploy/MVP-RUNBOOK.md`](deploy/MVP-RUNBOOK.md)** — run the dev cluster, step by step.
- **`governance/docs/architecture/04-repository-topology.md`** — submodule workflow.

Submodule URLs are relative (`../<repo>.git`), so SSH and HTTPS clones both work unmodified.
