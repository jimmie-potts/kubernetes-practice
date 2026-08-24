# Phase 2: Config, health, and scaling

Goal: chat stops being a demo and starts behaving like a production service. Configuration moves out of the pod spec, probes teach Kubernetes what "healthy" and "ready" mean for a model server, resources make scheduling and autoscaling possible, an HPA scales chat under load, and a bad rollout gets rolled back. Ticket [#4](https://github.com/jimmie-potts/kubernetes-practice/issues/4).

Prerequisite: phase 1's end state in dc-east (chat Deployment, Service, Ingress, ingress-nginx answering on 8080).

## Step 1: Configuration out of the pod spec

`MODEL_NAME` currently sits as a literal inside `chat-deployment.yaml`. That couples the image's *identity* to its *settings*: the same YAML cannot serve two tenants or two environments. You already solved this in ECS by keeping env vars in the task definition and secrets in Secrets Manager; Kubernetes splits the same idea into ConfigMap and Secret objects.

Create `deploy/tenants/acme/chat-config.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: chat-config
  labels:
    tenant: acme
data:
  MODEL_NAME: acme-chat-1
  SIMULATED_DELAY_MS: "150"
  BURN_CPU_MS: "200"
```

(`BURN_CPU_MS` makes each request burn real CPU. Useless now, load-bearing in step 5.)

Create `deploy/tenants/acme/chat-secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: chat-api-key
  labels:
    tenant: acme
stringData:
  ACME_API_KEY: sk-acme-0000-not-real
```

Two honesty notes. First, Secrets are base64-encoded, not encrypted; `kubectl get secret chat-api-key -o yaml` shows you exactly how thin that veil is (decode it: base64 is encoding, anyone can reverse it). Second, a real key would never be committed to git like this; production platforms inject secrets from a vault (External Secrets Operator, Sealed Secrets). Fine for a fake key in a lab, and worth saying out loud once.

Now edit `chat-deployment.yaml`: delete the whole `env:` block under the container and replace it with:

```yaml
          envFrom:
            - configMapRef:
                name: chat-config
            - secretRef:
                name: chat-api-key
```

Apply all three files:

```bash
kubectl --context kind-dc-east apply -f deploy/tenants/acme/
```

The pod template changed, so the Deployment rolls the pods. Verify the environment actually landed inside a container:

```bash
kubectl --context kind-dc-east exec deploy/chat -- env | grep -E 'MODEL_NAME|ACME_API_KEY|BURN'
```

One gotcha to file away: editing a ConfigMap alone does NOT restart pods. Env vars are read at process start, so pods keep running with old values until something rolls them (`kubectl rollout restart deployment chat`). Platforms get bitten by this constantly.

## Step 2: Probes, or teaching Kubernetes what "ready" means

In phase 1's step 6, a restart served 503s: traffic reached pods whose model was still loading, because Kubernetes' only definition of "working" was "the process is running". For inference platforms this is *the* central health problem, and the fix is two probes with two different jobs:

- **Readiness**: "may I receive traffic?" Fails → pod is removed from the Service's rotation. Nothing is killed. This is the routing half of your ALB target group health check, with one crucial difference: ECS also stops and replaces a task that fails its ALB check. Kubernetes separates "stop routing to it" (readiness) from "restart it" (liveness), while ECS fuses them into one blunt verdict. Readiness-without-killing has no ECS twin, and it is the property that made the zero-downtime rollout below possible.
- **Liveness**: "am I beyond saving?" Fails repeatedly → kubelet restarts the container. This is the ECS container health check that replaces a task.

Version 0.1.1 of fake-inference ships a way to prove the difference (a `/admin/freeze` endpoint that simulates a hung server). Load it into the data center:

```bash
docker build -t forge/fake-inference:0.1.1 services/fake-inference/
```

```bash
kind load docker-image forge/fake-inference:0.1.1 --name dc-east
```

Edit `chat-deployment.yaml`: change the image tag to `0.1.1`, and add probes to the container (same indent level as `envFrom`):

```yaml
          readinessProbe:
            httpGet:
              path: /readyz
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 2
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8000
            initialDelaySeconds: 15
            periodSeconds: 5
            failureThreshold: 3
```

Apply, and rerun phase 1's crack-finder while the pods roll:

```bash
kubectl --context kind-dc-east apply -f deploy/tenants/acme/chat-deployment.yaml
```

```bash
for i in $(seq 1 20); do curl -s -o /dev/null -w '%{http_code} ' -X POST http://chat.acme.dc-east.localtest.me:8080/v1/completions -H 'Content-Type: application/json' -d '{"prompt":"hi"}'; sleep 1; done; echo
```

All 200s. Same ten-second model load as phase 1, but new pods now join the Service only after `/readyz` succeeds, and the rolling update keeps old pods serving until replacements are truly ready. Zero-downtime deploys are not a product feature; they are this probe.

(Real model servers load weights for minutes, not seconds. The production tool for that is a third probe, `startupProbe`, which suspends the other two until first success; one to know exists, not needed here.)

Now the liveness demo. Freeze one pod and watch both probes do their separate jobs. Terminal 2:

```bash
kubectl --context kind-dc-east get pods -w
```

Terminal 1:

```bash
POD=$(kubectl --context kind-dc-east get pods -l app=chat -o name | head -1); kubectl --context kind-dc-east port-forward $POD 18080:8000 & sleep 2; curl -s -X POST localhost:18080/admin/freeze; kill %1
```

Watch terminal 2 tell the story in two acts: within a few seconds the frozen pod drops to `READY 0/1` (readiness failed, traffic drained away, nothing killed), and around fifteen seconds later `RESTARTS` ticks to 1 (liveness gave up, kubelet restarted the container). The restart wipes the in-memory freeze, the model reloads, readiness passes, and the pod rejoins on its own. Ctrl-C the watch.

One production caution: keep liveness thresholds conservative. An aggressive liveness probe plus a slow dependency equals restart storms; readiness should do the fast reacting, liveness only the last resort.

## Step 3: Resources, the currency of everything that follows

Add to the container in `chat-deployment.yaml`:

```yaml
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
```

```bash
kubectl --context kind-dc-east apply -f deploy/tenants/acme/chat-deployment.yaml
```

Two numbers, two meanings. **Requests** are what the scheduler *reserves*: the pod lands only on a node with 100 millicores and 128Mi unclaimed (the ECS task size used for placement). **Limits** are what the runtime *enforces*: CPU beyond 500m gets throttled, memory beyond 256Mi gets the container OOM-killed. Everything ahead is denominated in requests: HPA percentages (step 5) measure against them, and tenant Quotas (phase 3) add them up.

## Step 4: metrics-server, so the cluster can see itself

`kubectl top` and the HPA both need a metrics pipeline that vanilla clusters (and kind) do not ship:

```bash
kubectl --context kind-dc-east apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml
```

```bash
kubectl --context kind-dc-east -n kube-system patch deployment metrics-server --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

(The patch exists because kind's kubelets present self-signed certs; metrics-server refuses them by default. A local-cluster concession, not a production practice.)

```bash
kubectl --context kind-dc-east -n kube-system rollout status deployment/metrics-server --timeout=120s
```

Give it thirty seconds to take its first scrape, then look at your data center's vitals:

```bash
kubectl --context kind-dc-east top nodes
```

```bash
kubectl --context kind-dc-east top pods
```

## Step 5: The HPA, or Cloud Run's autoscaler with the covers off

Create `deploy/tenants/acme/chat-hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: chat
  labels:
    tenant: acme
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: chat
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 60
```

The math: 50% of *requests* (100m) means the HPA adds pods whenever average usage exceeds 50m per pod, and removes them when it falls below, never leaving the 2..6 range. The stabilization window (default five minutes, shortened to one here so the lab fits an evening) is the anti-flapping brake on the way down. Cloud Run made these same decisions for you, keyed on request concurrency instead of CPU; ECS called it target tracking scaling.

```bash
kubectl --context kind-dc-east apply -f deploy/tenants/acme/chat-hpa.yaml
```

Terminal 2 (leave it running through the whole step; `<unknown>` in TARGETS just means the first metrics scrape hasn't landed yet):

```bash
kubectl --context kind-dc-east get hpa chat -w
```

Terminal 1, open the floodgates. 2000 requests, 12 at a time, each burning 200ms of CPU on arrival:

```bash
seq 1 2000 | xargs -P 12 -I{} curl -s -o /dev/null -w '%{http_code}\n' -X POST http://chat.acme.dc-east.localtest.me:8080/v1/completions -H 'Content-Type: application/json' -d '{"prompt":"load test"}' | sort | uniq -c
```

Watch terminal 2: CPU blows through the 50% target (throttling pins each pod near its 500m limit, which is 500% of requests), and REPLICAS jumps upward, often straight from 2 to 6 in a single decision, typically inside a minute. When the load finishes, read the histogram: expect all or nearly all 200s. Readiness keeps unready pods out of rotation (step 2 already proved a roll with zero errors), but under deliberate overload a stray 502 or two out of 2000 can still slip through at the instant several throttle-starved pods join at once; the validation run scored 1997 to 3. Production edges close that last 0.1% with retries at the load balancer or client, a knob we revisit with the Global Entry Point in phase 4. Then, roughly a minute after the load stops, watch the HPA walk the replicas back down to 2. Ctrl-C when it settles.

## Step 6: The bad rollout, and the undo

Ship a broken model version (a tag that does not exist):

```bash
kubectl --context kind-dc-east set image deployment/chat fake-inference=forge/fake-inference:0.2.0-broken
```

```bash
kubectl --context kind-dc-east rollout status deployment/chat --timeout=30s
```

It times out: the rollout is stuck. Look at why, and at what did NOT happen:

```bash
kubectl --context kind-dc-east get pods -l app=chat
```

One new pod in `ImagePullBackOff`, the old pods still `Running 1/1`. The rolling update strategy creates before it destroys, and it will not touch a healthy old pod until a replacement passes readiness. So Acme's view, right now, mid-failed-deploy:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://chat.acme.dc-east.localtest.me:8080/v1/completions -H 'Content-Type: application/json' -d '{"prompt":"still up?"}'
```

`200`. A botched deploy degraded into a non-event. ECS's deployment circuit breaker gives you this with `rollback: true`; here you are the circuit breaker:

```bash
kubectl --context kind-dc-east rollout undo deployment/chat
```

```bash
kubectl --context kind-dc-east rollout status deployment/chat --timeout=60s
```

`kubectl rollout history deployment/chat` shows the revision trail (the undo prints a warning about a last-applied annotation, and the rolled-back revision gets renumbered to the newest; both are normal, and the re-apply below squares everything). Last thing: `set image` was an imperative side-door, and your YAML file is supposed to be the truth. Re-assert it:

```bash
kubectl --context kind-dc-east apply -f deploy/tenants/acme/chat-deployment.yaml
```

No-op if they already agree, correction if they drifted. Sit with that idea for a second: a file in git as desired state, continuously re-asserted. That is the whole pitch of GitOps, and of phase 9. One honest asterisk: `spec.replicas`. Once the HPA owns the replica count, a re-apply mid-scale snaps replicas back to the file's 2 and the HPA fights its way back up. Standard practice is to drop `spec.replicas` from the file once an HPA manages it; we keep it today (it equals the HPA floor, so the apply was a no-op) and fix it properly when the Helm chart takes over in phase 5.

## Checkpoint

```bash
kubectl --context kind-dc-east get deploy,hpa -l tenant=acme && kubectl --context kind-dc-east exec deploy/chat -- env | grep MODEL_NAME && kubectl --context kind-dc-east top pods
```

Deployment 2/2 on image 0.1.1, HPA showing a live CPU percentage against a 50% target, `MODEL_NAME=acme-chat-1` from the ConfigMap, and `top` returning numbers. Plus, demonstrated along the way: the freeze restart, the all-200 load test, and the rollback.

## Appendix: the full chat-deployment.yaml

After all three edits, your file should read:

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
          image: forge/fake-inference:0.1.1
          ports:
            - containerPort: 8000
          envFrom:
            - configMapRef:
                name: chat-config
            - secretRef:
                name: chat-api-key
          readinessProbe:
            httpGet:
              path: /readyz
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 2
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8000
            initialDelaySeconds: 15
            periodSeconds: 5
            failureThreshold: 3
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
```

## What you learned

- Config and secrets are objects, decoupled from images; env vars load at process start, so config changes need a restart to land.
- Readiness controls traffic, liveness controls restarts, and conflating them causes either dropped requests or restart storms. Model loading time is a readiness problem.
- Requests are the scheduler's reservation and the unit everything else prices in; limits are the runtime's ceiling.
- The HPA is a reconciliation loop over metrics-server data, measured against requests.
- Rolling updates gated on readiness turn bad deploys into non-events, and `rollout undo` is the escape hatch.
- Imperative commands drift from your files; `kubectl apply` re-asserts the file as truth.

## ECS and Cloud Run mapping

| Kubernetes | AWS ECS | GCP Cloud Run |
|---|---|---|
| ConfigMap | Task definition environment / SSM parameters | Env vars |
| Secret | Secrets Manager reference | Secret mounts |
| Readiness probe | ALB health check's routing half (but ECS also replaces the task) | Startup probe; no true readiness equivalent |
| Liveness probe | Container health check, task replaced | Liveness probe, instance restarted |
| Requests / limits | Task size / hard limits | CPU and memory settings |
| HPA | Target tracking auto scaling | Automatic, keyed on concurrency |
| rollout undo | Deployment circuit breaker rollback | Revision traffic rollback |

Next: phase 3 ([#5](https://github.com/jimmie-potts/kubernetes-practice/issues/5)), where Stark Industries moves in next door and the walls go up: namespaces, quotas, RBAC, and network policy.
