# The Console fakes login with a role picker

v1 authentication is a role picker (Infra Admin, Acme admin, Stark admin) with no passwords, while the Console still enforces tenant scoping server-side on every Kubernetes call. Real OIDC (for example Dex) is a stretch topic because auth plumbing would eat a phase without teaching Kubernetes.
