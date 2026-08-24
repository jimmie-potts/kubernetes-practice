# A Tenant is a namespace in each data center

Tenant isolation is namespace-per-tenant per cluster (`tnt-acme`, `tnt-stark`): ResourceQuota and LimitRange for noisy-neighbor control, RBAC scoped to the namespace, and a default-deny NetworkPolicy between tenants. We rejected vcluster (stronger isolation, one more moving part) and cluster-per-tenant (strongest isolation, but wasteful locally and it avoids the shared-cluster skills this project exists to teach). vcluster stays on the stretch list.
