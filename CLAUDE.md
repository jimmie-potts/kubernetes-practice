# Forge (kubernetes-practice)

A learning prototype: a multi-tenant inference platform across two simulated data centers. Read `CONTEXT.md` before naming anything; it pins the vocabulary. Decisions live in `docs/adr/`.

## Working agreement

Jimmie is learning Kubernetes (background: AWS ECS and GCP Cloud Run). Hybrid mode: Claude scaffolds docs, app code, and configs; Jimmie personally types every `kind`, `kubectl`, and `helm` command by following the lab docs in `docs/labs/` (interactive HTML, ADR-0008; serve locally with `python3 -m http.server` from the repo root). Do not run cluster-mutating commands for him unless he asks. Map new concepts to ECS or Cloud Run equivalents where one exists.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on `jimmie-potts/kubernetes-practice`. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: `CONTEXT.md` at the repo root, ADRs in `docs/adr/`. See `docs/agents/domain.md`.
