# Phase 1: First Service by hand

Goal: Acme's chat Service serving completions in dc-east through ingress-nginx, built object by object with raw kubectl. Ticket [#3](https://github.com/jimmie-potts/kubernetes-practice/issues/3).

Everything happens in dc-east; dc-west sits idle until phase 4. Objects land in the `default` namespace for now. Tenant walls arrive in phase 3.

The path you are building, outside in:

```
curl chat.acme.dc-east.localtest.me:8080
  -> 127.0.0.1:8080 (localtest.me wildcard DNS)
  -> Docker port map to the control-plane node's port 80
  -> ingress-nginx pod (reads Ingress objects, routes by hostname)
  -> chat Service (stable address for the pods)
  -> a chat pod (fake-inference container)
```

Each object below exists to make one hop of that path work.

| You want | Kubernetes object | ECS | Cloud Run |
|---|---|---|---|
| Run containers | Pod | Task | An instance of your service |
| Keep N copies alive | Deployment | Service with desired count | Service with autoscaling |
| One stable address for them | Service | Target group plus service discovery | The service URL |
| Route outside traffic by hostname | Ingress | ALB listener rule | Domain mapping |
| The router itself | ingress-nginx controller | The ALB | Google's front end |

## Step 1: A pod, alone

Ask for a single pod running the fake-inference image:

```bash
kubectl --context kind-dc-east run chat-solo --image=forge/fake-inference:0.1.0
```

```bash
kubectl --context kind-dc-east get pods
```

Status shows `ErrImagePull` or `ImagePullBackOff`. This failure is the lesson: the node's container runtime went looking for `forge/fake-inference:0.1.0` and found nothing, because the image exists only in your laptop's Docker. The cluster cannot see it. In ECS terms, you asked for a task whose image was never pushed to ECR. Forge has no registry, so kind offers a shortcut that copies an image onto every node:

```bash
docker build -t forge/fake-inference:0.1.0 services/fake-inference/
```

```bash
kind load docker-image forge/fake-inference:0.1.0 --name dc-east
```

Now watch, touching nothing else:

```bash
kubectl --context kind-dc-east get pods -w
```

Within a minute or two the kubelet retries the pull, finds the image on its own node, and the pod flips to `Running`. Ctrl-C to stop watching. (Retries back off, so if you are impatient: delete the pod and run it again.) You fixed the cause; reconciliation did the rest. Talk to the pod through an API-server tunnel:

```bash
kubectl --context kind-dc-east port-forward pod/chat-solo 18080:8000
```

In a second terminal:

```bash
curl localhost:18080/healthz
```

`port-forward` tunnels through the control plane. It is a debug door, not a production path; customer traffic will use the ingress you build in step 4. Ctrl-C the port-forward, then see why a bare pod is not enough:

```bash
kubectl --context kind-dc-east delete pod chat-solo
```

```bash
kubectl --context kind-dc-east get pods
```

Gone, and nothing brings it back. No object in the cluster says "there should be a chat pod", so no control loop disagrees with an empty list. Deployments fix that.

## Step 2: A Deployment keeps them alive

Create the file `deploy/tenants/acme/chat-deployment.yaml` yourself (typing it is the point):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chat
  labels:
    app: chat
    tenant: acme
spec:
  replicas: 2
  selector:
    matchLabels:
      app: chat
  template:
    metadata:
      labels:
        app: chat
        tenant: acme
    spec:
      containers:
        - name: fake-inference
          image: forge/fake-inference:0.1.0
          ports:
            - containerPort: 8000
          env:
            - name: MODEL_NAME
              value: acme-chat-1
```

Read it as an ECS service fused with its task definition: `template` is the task definition (image, ports, env), `replicas` is desired count, and `selector` is the glue. The selector must match the template's labels; that is the contract by which the Deployment recognizes which pods are "its own".

```bash
kubectl --context kind-dc-east apply -f deploy/tenants/acme/chat-deployment.yaml
```

```bash
kubectl --context kind-dc-east get pods
```

Two pods with generated names like `chat-7c9f8b6d4-x2klm` (the middle hash names the ReplicaSet, an object the Deployment manages for you; you will meet it properly during rollouts in phase 2). Now the acceptance test. Delete one pod, then immediately watch:

```bash
kubectl --context kind-dc-east delete $(kubectl --context kind-dc-east get pods -l app=chat -o name | head -1) & kubectl --context kind-dc-east get pods -w
```

A replacement appears while the old one terminates: actual state dropped to one, desired said two, a control loop acted. Ctrl-C when it settles. This is the same reconciliation that recovered your image pull, and it never sleeps.

## Step 3: A Service gives them one address

Two pods, two private IPs, and both change every time a pod is replaced:

```bash
kubectl --context kind-dc-east get pods -o wide
```

Nothing should ever chase pod IPs. Create `deploy/tenants/acme/chat-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: chat
  labels:
    tenant: acme
spec:
  selector:
    app: chat
  ports:
    - port: 80
      targetPort: 8000
```

```bash
kubectl --context kind-dc-east apply -f deploy/tenants/acme/chat-service.yaml
```

```bash
kubectl --context kind-dc-east get svc chat
```

The `CLUSTER-IP` is a stable virtual address; kube-proxy (phase 0) programs every node to route it to whichever chat pods exist right now. It is a target group plus service discovery in one object. Prove the DNS half from inside the cluster, since a ClusterIP is not reachable from your laptop:

```bash
kubectl --context kind-dc-east run tester --rm -i --restart=Never --image=curlimages/curl -- curl -s http://chat/healthz
```

That pod resolved the name `chat` through coredns, hit the Service IP, and reached a pod. Services finding each other by name is how tenant microservices will talk in later phases.

## Step 4: ingress-nginx, the shared front door

The Service is reachable only inside the cluster. Enter the nginx from the interview diagram, installed like any workload:

```bash
kubectl --context kind-dc-east apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml
```

One correction before it can work here. Our kind config publishes ports 80/443 of the control-plane node only, but since v1.13 this manifest no longer pins the controller to a labeled node, so it may land on a worker nobody can reach (the trap recorded in ADR-0005). Pin it to the port-mapped node, which our config labeled `ingress-ready=true` in phase 0:

```bash
kubectl --context kind-dc-east -n ingress-nginx patch deployment ingress-nginx-controller -p '{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true","kubernetes.io/os":"linux"}}}}}'
```

On real bare metal this is a real decision: the edge proxy must run on the machines whose ports face the world. Wait for it:

```bash
kubectl --context kind-dc-east -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
```

## Step 5: An Ingress routes your hostname

Create `deploy/tenants/acme/chat-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: chat
  labels:
    tenant: acme
spec:
  ingressClassName: nginx
  rules:
    - host: chat.acme.dc-east.localtest.me
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: chat
                port:
                  number: 80
```

An Ingress is an ALB listener rule: "this hostname goes to that Service". The controller watches these objects through the API server and rewrites its own nginx config; no packet ever passes through the control plane.

```bash
kubectl --context kind-dc-east apply -f deploy/tenants/acme/chat-ingress.yaml
```

The moment of truth (`*.localtest.me` resolves to 127.0.0.1, and 8080 is dc-east's published port):

```bash
curl http://chat.acme.dc-east.localtest.me:8080/healthz
```

```bash
curl -s -X POST http://chat.acme.dc-east.localtest.me:8080/v1/completions -H 'Content-Type: application/json' -d '{"prompt":"hello forge"}'
```

A completion, served by Acme's model, through Forge's front door. One shared nginx will serve every Tenant this way, split by hostname; that is the multi-tenant carve-up from ADR-0005.

## Step 6: The crack in the wall

fake-inference takes about ten seconds to "load its model" after starting, and right now Kubernetes has no idea. Catch it in the act. Trigger a restart of all pods, then hammer the endpoint:

```bash
kubectl --context kind-dc-east rollout restart deployment chat
```

```bash
for i in $(seq 1 15); do curl -s -o /dev/null -w '%{http_code} ' -X POST http://chat.acme.dc-east.localtest.me:8080/v1/completions -H 'Content-Type: application/json' -d '{"prompt":"hi"}'; sleep 1; done; echo
```

Mixed in with the 200s you will see 503s: traffic reached pods whose model was still loading, because nobody told Kubernetes what "ready" means for this container. For an inference platform, model loading time is the whole game. Readiness probes fix this in phase 2, and you have now seen exactly why they exist.

## Checkpoint

```bash
kubectl --context kind-dc-east get deploy,svc,ingress -l tenant=acme
```

Deployment 2/2, Service with a ClusterIP, Ingress with your hostname. The completions curl above returns 200 with a body naming `acme-chat-1`. Deleting a chat pod gets it replaced without your help.

## What you learned

- Nothing in Kubernetes "starts a container"; you declare objects and control loops make them true. The image-pull recovery and the pod replacement were the same mechanism.
- Pod, Deployment, Service, Ingress each solve one failure of the previous layer: death, identity, reachability.
- The Deployment selector and pod labels are a contract, not decoration.
- The ingress controller is a workload like any other; only node placement and published ports make it the front door.
- `port-forward` goes through the control plane; ingress traffic never does.

Next: phase 2 ([#4](https://github.com/jimmie-potts/kubernetes-practice/issues/4)), where chat gets probes, config from ConfigMaps and Secrets, resource requests, autoscaling, and a rollback.
