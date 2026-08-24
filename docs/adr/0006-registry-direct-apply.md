# The Console applies the Registry directly; GitOps comes later

The Forge Console treats the Registry as desired state: it renders each Tenant Spec into Kubernetes manifests and applies them to both data centers through the Kubernetes API. GitOps (Argo CD pulling the Registry) is deliberately deferred to a stretch phase: the learner should feel the raw API before adopting the abstraction that hides it, and the Registry design keeps that later migration small.
