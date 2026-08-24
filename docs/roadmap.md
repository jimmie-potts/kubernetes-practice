# Roadmap

The build is ten tracer-bullet tickets, one per phase. Each phase ends with something you can demo, and a ticket unblocks when its blocker closes. Full user stories live in the spec, [#1](https://github.com/jimmie-potts/kubernetes-practice/issues/1).

| Phase | Ticket | You can demo |
|---|---|---|
| 0. Boot the data centers | [#2](https://github.com/jimmie-potts/kubernetes-practice/issues/2) | Two three-node clusters answering kubectl |
| 1. First Service by hand | [#3](https://github.com/jimmie-potts/kubernetes-practice/issues/3) | chat serving completions through ingress in dc-east |
| 2. Config, health, and scaling | [#4](https://github.com/jimmie-potts/kubernetes-practice/issues/4) | Probes gate model loading; HPA scales chat under load; a bad rollout is undone |
| 3. Tenant isolation | [#5](https://github.com/jimmie-potts/kubernetes-practice/issues/5) | Stark onboarded; Quota rejections; RBAC and network walls hold |
| 4. Second data center and failover | [#6](https://github.com/jimmie-potts/kubernetes-practice/issues/6) | One data center dies and chat keeps answering |
| 5. Package Services with Helm | [#7](https://github.com/jimmie-potts/kubernetes-practice/issues/7) | One chart renders any Service for any data center |
| 6. Telemetry | [#8](https://github.com/jimmie-potts/kubernetes-practice/issues/8) | Per-Tenant Grafana dashboards; an alert fires |
| 7. The Forge Console | [#9](https://github.com/jimmie-potts/kubernetes-practice/issues/9) | Tenants self-serve; the Quota Request approval flow works |
| 8. Tenant CRD and Go operator (stretch) | [#10](https://github.com/jimmie-potts/kubernetes-practice/issues/10) | `kubectl apply` onboards a Tenant |
| 9. GitOps with Argo CD (stretch) | [#11](https://github.com/jimmie-potts/kubernetes-practice/issues/11) | Clusters pull the Registry; drift reverts |

Start with [#2](https://github.com/jimmie-potts/kubernetes-practice/issues/2) and its lab, `docs/labs/phase-0-boot-the-data-centers.md`. Lab docs for later phases land when their ticket starts.
