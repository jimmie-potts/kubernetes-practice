# Forge

Forge is a fictional company that hosts customer inference services on bare metal across two data centers. This repo is a learning prototype that simulates Forge's platform with local Kubernetes clusters.

## Language

**Forge**:
The platform and the fictional company that owns the data centers.
_Avoid_: the platform, the company

**Data center**:
One Kubernetes cluster (`dc-east` or `dc-west`) standing in for a physical facility of bare-metal hosts.
_Avoid_: region, site, zone

**Tenant**:
A customer organization (Acme or Stark Industries) with isolated resources in one or both data centers.
_Avoid_: customer, client, account

**Service**:
A tenant-owned inference workload that Forge runs in one or both data centers.
_Avoid_: app, workload, deployment (Deployment names the Kubernetes object only)

**Forge Console**:
The web UI where Tenants manage their Services and the Infra Admin manages the platform.
_Avoid_: portal, dashboard, admin panel

**Infra Admin**:
The human who owns Forge's infrastructure: clusters, nodes, quotas, and platform components. In this prototype, Jimmie.
_Avoid_: operator (reserved for the Kubernetes operator pattern), platform admin

**Quota**:
The resource ceiling (CPU, memory, pod count) a Tenant holds in one data center.

**Quota Request**:
A Tenant's ask to raise a Quota. Only the Infra Admin can approve one.
