# Tenants own Services, the Infra Admin owns capacity

Tenants create, update, and delete their own Services (image, env vars, replica count, per-replica CPU and memory), choose which data centers they run in, and view status and telemetry. Capacity belongs to the Infra Admin: tenant onboarding, Quota changes (Tenants file a Quota Request, the Infra Admin approves), nodes, clusters, ingress, and platform components. This mirrors the ECS split where customers own task definitions and services while the platform owns capacity and cluster config.
