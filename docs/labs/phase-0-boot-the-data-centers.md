# Phase 0: Boot the data centers

Goal: two running Kubernetes clusters, `dc-east` and `dc-west`, each with one control-plane node and two workers standing in for bare-metal hosts. At the end, `kubectl` can talk to either data center.

You type every command in this lab yourself. Expected results follow the important ones.

## Before you start

Docker Desktop must be running with WSL integration enabled for this distro. Verify:

```bash
docker info --format '{{.ServerVersion}}'
```

A version number means you are ready. An error mentioning "this WSL 2 distro" means: Docker Desktop, Settings, Resources, WSL integration, enable this distro, Apply & Restart.

## Step 1: Install the tools

```bash
./scripts/00-install-tools.sh
```

The script installs three binaries into `~/.local/bin` and is safe to re-run:

- `kubectl`: the CLI for any Kubernetes API server. In ECS terms this is the `aws ecs` CLI, except the same binary works against every Kubernetes cluster anywhere.
- `kind`: runs Kubernetes clusters in which every "machine" is a Docker container.
- `helm`: a package manager for Kubernetes manifests. You will meet it in phase 5.

Verify:

```bash
kind version && kubectl version --client && helm version --short
```

## Step 2: Read the data center config

Open [infra/kind/dc-east.yaml](../../infra/kind/dc-east.yaml). Things to notice:

- Each entry under `nodes:` becomes one Docker container running its own kubelet and container runtime. These containers are our bare-metal hosts.
- The `control-plane` node will run the cluster's brain: API server, etcd, scheduler, controller manager. ECS and Cloud Run hide this half from you. Here you get to watch it work.
- `extraPortMappings` publishes the control-plane node's ports 80 and 443 to your host as 8080 and 8443. That is the door traffic will use to enter dc-east in phase 1.
- The worker `labels` name a rack and zone, so later phases can schedule against topology.

## Step 3: Create dc-east

```bash
kind create cluster --config infra/kind/dc-east.yaml
```

The first run pulls the node image and takes a few minutes. When it finishes:

```bash
kubectl cluster-info --context kind-dc-east
```

kind wrote credentials into `~/.kube/config` under the context name `kind-dc-east`. A context bundles cluster, user, and namespace. Think of an AWS CLI profile plus region in one name.

## Step 4: Meet your machines

Your "bare metal":

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

Three containers: `dc-east-control-plane`, `dc-east-worker`, `dc-east-worker2`. The same machines, as Kubernetes sees them:

```bash
kubectl --context kind-dc-east get nodes -o wide
```

All three nodes reach `Ready` within a minute or two. Now look at what Kubernetes runs for itself:

```bash
kubectl --context kind-dc-east get pods --all-namespaces
```

These system pods are the "other Kubernetes services" from the interview diagram:

| Pod | Job |
|---|---|
| `kube-apiserver` | The front door. Everything, including kubectl, talks to the cluster through it. |
| `etcd` | The database holding desired and observed state. |
| `kube-scheduler` | Picks which node each new pod lands on. ECS calls this task placement. |
| `kube-controller-manager` | Control loops that drive actual state toward desired state. |
| `kube-proxy` (one per node) | Programs each node's networking so Service IPs reach pods. |
| `kindnet` (one per node) | kind's built-in CNI plugin: gives every pod an IP and connects pods across nodes. kind-specific, like `local-path-provisioner`. |
| `coredns` | Cluster-internal DNS. How Services find each other by name. |
| `local-path-provisioner` | kind's stand-in for dynamic volume provisioning. |

## Step 5: Create dc-west

```bash
kind create cluster --config infra/kind/dc-west.yaml
```

```bash
kubectl config get-contexts
```

Two contexts now exist. `kubectl config use-context` switches the default, but the labs pass `--context` explicitly so the two data centers never blur.

## Checkpoint

```bash
kind get clusters
```

Lists `dc-east` and `dc-west`.

```bash
kubectl --context kind-dc-east get nodes && kubectl --context kind-dc-west get nodes
```

Six nodes total, all `Ready`.

## If you need to reset

```bash
kind delete cluster --name dc-east
```

Destroys that data center and forgets it. Rebuilding takes minutes. Resetting should feel cheap; you will do it often.

## What you learned

- A Kubernetes cluster is a control plane plus worker nodes. ECS only ever showed you the workers.
- kind's nodes are containers, which is how one laptop hosts two "data centers".
- A kubectl context selects which cluster you are talking to.
- Each system pod owns one job: API, state, scheduling, reconciliation, service networking, DNS.

## ECS and Cloud Run mapping

| Kubernetes | AWS ECS | GCP Cloud Run |
|---|---|---|
| Cluster | ECS cluster | Hidden behind the service |
| Node | EC2 container instance | Hidden |
| kubelet | ECS agent | Hidden |
| Control plane | Exists, but AWS-managed and invisible | Fully managed |
| kubectl context | CLI profile and region | `gcloud config` |

Next: phase 1, where you deploy Acme's chat Service to dc-east by hand. Its lab doc lands when you start the ticket.
