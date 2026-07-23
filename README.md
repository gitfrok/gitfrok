# git-saas — super-repo

Multi-tenant Git SaaS (GitLab-Ultimate governance, GitHub UX, flat-rate, BYO-Kubernetes),
delivered with **AGDD** (ADR-0028) across **four git submodules** (ADR-0027).

```
git-saas/                 super-repo (pinned submodule commits + dev orchestration)
├── governance/  [sub]    control surface: ADRs, specs, contracts/, policies/, process, agent rules
├── backend/     [sub]    Go modular monolith (one binary per plane) — ADR-0025
├── bff/         [sub]     Go BFF (aggregation only)
└── webfrontend/ [sub]    Astro + React SSR
```

## Quickstart
```bash
git clone --recurse-submodules <this-super-repo>
make bootstrap      # init submodules + install toolchain floors (.tool-versions)
make dev-up         # Minikube dev cluster (*.gitsaas.test, mkcert TLS) — ADR-0024
```

## Where to look
- **Agents:** `AGENTS.md` (this repo), then `governance/AGENTS.md` + `governance/docs/`.
- **Decisions (SoT):** `governance/docs/adr/README.md`.
- **How work flows:** `governance/docs/process/agdd.md` (framework) + `agentic-sdlc.md` (loop).
- **Topology & submodule workflow:** `governance/docs/architecture/04-repository-topology.md`.

Configure real submodule URLs in `.gitmodules` (placeholders provided).
