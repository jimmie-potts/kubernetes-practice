# Forge

A learning prototype that simulates a multi-tenant inference hosting platform across two data centers, built to learn Kubernetes hands-on. Two local kind clusters (`dc-east`, `dc-west`) stand in for the data centers. Tenants (Acme, Stark Industries) run inference Services managed through the Forge Console; the Infra Admin owns clusters, nodes, and quotas.

Design docs: [CONTEXT.md](CONTEXT.md) for vocabulary, [docs/adr/](docs/adr/) for decisions. Roadmap and user stories land as the design settles.
