# Forge

A learning prototype that simulates a multi-tenant inference hosting platform across two data centers, built to learn Kubernetes hands-on. Two local kind clusters (`dc-east`, `dc-west`) stand in for the data centers. Tenants (Acme, Stark Industries) run inference Services managed through the Forge Console; the Infra Admin owns clusters, nodes, and quotas.

Design docs: [CONTEXT.md](CONTEXT.md) for vocabulary, [docs/adr/](docs/adr/) for decisions. Labs are interactive HTML pages: browse them at [jimmie-potts.github.io/kubernetes-practice/labs/](https://jimmie-potts.github.io/kubernetes-practice/labs/), or serve locally with `python3 -m http.server` from the repo root and open `http://localhost:8000/docs/labs/` (the local copy also enables the live check buttons). Roadmap: [docs/roadmap.md](docs/roadmap.md). Full user stories: the spec, [#1](https://github.com/jimmie-potts/kubernetes-practice/issues/1).
