# ingress-nginx with host-based routing per tenant

Each data center runs ingress-nginx, reachable from the host at `localhost:8080`/`8443` (dc-east) and `localhost:9080`/`9443` (dc-west) through kind port mappings. Services get hostnames of the form `<service>.<tenant>.<dc>.localtest.me`, so one shared ingress serves every Tenant. Chosen over Traefik and plain NodePorts because ingress-nginx is the controller most often met in production and host-based routing is how real platforms carve up shared ingress.

## Consequences

The classic kind convention (label the port-mapped node `ingress-ready=true` and let the ingress-nginx "kind provider" manifest select it) stopped working with controller v1.13.0, which dropped that nodeSelector. The label stays in our kind configs, but the phase 1 install must place the controller explicitly: pin the manifest to controller-v1.12.x, or install a current version with nodeSelector `ingress-ready: "true"`, hostPorts 80 and 443 enabled, and a toleration for `node-role.kubernetes.io/control-plane`. Otherwise the controller can land on a worker whose ports are not published to the host, and `localhost:8080`/`9080` serve nothing.
