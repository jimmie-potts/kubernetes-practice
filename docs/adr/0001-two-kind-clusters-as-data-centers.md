# Two kind clusters simulate the two data centers

Each Forge data center is a separate kind cluster (`dc-east`, `dc-west`) with one control-plane node and two worker nodes standing in for bare-metal hosts. We chose kind over minikube, k3d, and real cloud clusters because it runs multi-node clusters side by side on one machine, mirrors the kubeadm bootstrap used on real bare metal, and rebuilds in minutes.

## Consequences

Cross-cluster networking is limited to what Docker networks allow, so multi-DC behavior such as failover is simulated at the edge rather than reproduced faithfully. Features that assume a cloud provider (LoadBalancer services, cloud volumes) need local stand-ins.
