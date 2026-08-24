# Forge

Forge is a fictional company that hosts tenant inference services on bare metal across two data centers. This repo is a learning prototype that simulates Forge's platform with local Kubernetes clusters.

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

**Registry**:
The desired-state store, one Tenant Spec per Tenant, that the Forge Console reads and applies to the data centers.
_Avoid_: database, config store

**Tenant Spec**:
The YAML record of one Tenant's Services and Quotas across data centers.
_Avoid_: manifest (reserved for rendered Kubernetes YAML)

**Global Entry Point**:
The host-level nginx in front of both data centers that health-checks each and routes one URL to whichever is alive.
_Avoid_: load balancer, GSLB

**fake-inference**:
The shared sample server image every tenant Service runs. It fakes model loading and latency and serves Prometheus metrics.

**chat**:
Acme's low-latency chat Service.

**jarvis**:
Stark Industries' batch summarizer Service, deliberately sized to strain Stark's Quota.
