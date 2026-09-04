# Readiness and liveness in production inference

What real model servers check, what Kubernetes does with the answers, and how the lab's fake-inference compares. Sources were read on 2026-09-03 and 2026-09-04. Versions at the time: vLLM v0.28.0, Triton 2.72.0, TGI v3.3.7 (repository archived), NIM for LLMs 2.0.11 with NIM Operator v3.1.2, TorchServe v0.12.0 (no longer maintained), kubernetes.io v1.37 docs. Every numbered claim points at a primary source with a short quote in the list at the end.

## The short answer

Liveness answers one narrow question: is the serving process wedged, or is its engine dead. Readiness answers a different one: can this replica take an inference request right now.

Production servers keep the first check cheap and independent of anything outside the process. vLLM's `/health` reads one flag and returns 503 only when the engine process has died [1][2]. NIM's `/v1/health/live` is answered by an nginx proxy in front of the model and needs no backend at all [3]. Triton's `/v2/health/live` passes once the server has initialized, whatever the models are doing [4]. KServe's `live()` is unconditional [5].

They tie the second check to weights being loaded and, in several cases, to warm-up having finished. NIM's `/v1/health/ready` turns 200 only after the model loads and the backend's own health check passes [6]. Triton's default strict readiness requires every model version to be READY and answers 400 otherwise [7][8]. KServe returns 503 from its model-ready endpoint until `load()` sets the ready flag [9][10]. vLLM and TGI go further and do not open their HTTP port until loading, compilation, and warm-up are done, so during startup a probe gets connection refused rather than a status code [11][12][13].

Because that load takes minutes, most vendor manifests add a startup probe with a budget between 5 and 60 minutes and keep liveness tolerant, since a liveness restart reloads the whole model [14][15][16]. GPU hardware health is not something the pod probe checks; the node watches for it and the cloud provider repairs the node [17][18].

The lab's fake-inference draws the same line: `/readyz` gated on model load, `/healthz` independent of it, a freeze that simulates a hang. It compresses a minutes-long load into ten seconds, has no startup probe, and has no graceful shutdown. Section 7 lists the rest.

## 1. What each server checks

| System | Live means | Ready means | Startup handling |
|---|---|---|---|
| vLLM v0.28.0 | `/health`: 200 unless the engine process is dead, then 503 (since v0.11.0). No model or GPU work [1][2][19] | The same `/health`. The server does not listen until load, torch.compile, and CUDA graph capture finish [11][12][20] | startupProbe on `/health`: GKE 600 x 1 s, production-stack 60 x 10 s, AWS EKS 60 x 10 s; llm-d 120 x 30 s on `/v1/models` [21][22][23][24] |
| Triton 2.72.0 | `/v2/health/live`: initialized and responsive, independent of model load or unload [4][25] | `/v2/health/ready`: every model version READY and each backend instance alive; HTTP 400 when not [7][8][26] | All models load before the HTTP server starts. NVIDIA's on-prem chart uses a startupProbe of 30 x 10 s; Google's TensorRT-LLM manifest waits 600 s then allows 60 x 5 s [27][28][29] |
| TGI v3.3.7 | One `/health`, 200 or 503. On the cheap path each shard allocates a small tensor on the device [30][31][32] | The same `/health`. Only after a generation has failed does it run a one-token forward pass before reporting healthy again [31][33][34] | The router starts only after every shard is up and a warm-up call completes. Hugging Face's HUGS chart waits 360 s before its first liveness probe and has no startupProbe [35][13][36][37] |
| NIM 2.0.11 | `/v1/health/live`: nginx proxy, container running, answers during model load [3][38] | `/v1/health/ready`: model loaded and the backend `/health` passing [6][39] | NIM Operator: startupProbe on `/v1/health/ready` at 120 x 10 s, so 20 minutes; liveness and readiness every 10 s with failureThreshold 3 [40][41][42] |
| KServe 0.20 | `/v2/health/live` or `live()`: always alive [5][43] | Model-ready endpoint 503 until `load()` sets `self.ready`; server-ready is true only when all models are ready [9][10][44] | Default readiness is a TCP socket probe (timeout 1 s, period 10 s, failureThreshold 3) with no default liveness; override it with an HTTP probe on the model-ready path [45][46] |
| Ray Serve on KubeRay | kubelet liveness checks the Raylet (and GCS on the head) with failureThreshold 120. Ray Serve itself, not kubelet, kills and restarts a replica whose `check_health` raises [47][48][49] | The proxy's `/-/healthz` answers 503 while draining or before the route table arrives; KubeRay adds it to worker readiness with failureThreshold 1 [50][51][52] | Readiness failureThreshold 10. If an application stays non-RUNNING past `serviceUnhealthySecondThreshold`, KubeRay replaces the whole RayCluster [52][53] |
| TorchServe v0.12.0 | No separate live endpoint; `/ping` returns 500 when any model has fewer active workers than minWorkers [54] | `/ping` 200 only when every model has at least minWorkers workers [55] | The official chart ships no probes. A dead worker is tolerated for maxRetryTimeoutInSec, five minutes by default. The project is unmaintained [56][57][58] |

Where a server hosts many models, readiness is also reported per model: Triton's `/v2/models/{name}/ready` returns 400 "Model version not ready" while a version is loading [59][60], KServe frames model readiness as a separate question from server readiness [61][62], and SageMaker maps its `/ping` to Triton "ready" for single-model endpoints and to "live" for multi-model endpoints [63].

## 2. Patterns that recur

**Liveness depends on nothing outside the process.** kubernetes.io says liveness must indicate unrecoverable failure such as a deadlock [64], that bad liveness probes cause cascading failures [65], and describes the mechanism: restarts under load shift work onto the surviving pods [66]. EKS says not to make liveness depend on anything external to the pod [67]. GKE says never let probe logic reach another service [68]. The servers follow this: NIM live has no backend dependency [3], Triton live ignores model state [4][25], KServe `live()` is unconditional [5], KubeRay checks only Raylet and GCS [47].

**Readiness gates on weights loaded, then on warm-up.** NIM [6], Triton [7], KServe [10], and TorchServe [55] all do the first. GKE's guidance: the readiness probe must say ready only after the startup cache is fully loaded [69]. Google's model serving docs: return success only when the model is loaded [70]. SageMaker: `/ping` should verify the model is in memory, with a 2 s timeout [71]. kubernetes.io names loading files and warming caches as exactly what readiness is for [72]. For warm-up, vLLM guarantees all torch.compile work finishes before it serves any request [12] and captures CUDA graphs on a dummy forward pass [20]; `--enforce-eager` skips both at a decode-performance cost [73]. AWS notes that a first pod must compile before serving and that this can take up to several minutes [74]; the same page's own measurements show under two minutes uncached, so treat "several minutes" as the upper bound. TGI's router does a health check and then a warm-up call before it accepts generate calls [13][75].

**A startup probe absorbs the load.** kubernetes.io: set failureThreshold times periodSeconds to cover the worst-case startup [14]; once it succeeds, liveness takes over [76]; leave the liveness defaults alone [77]; a failed startup probe kills the container [78]. Budgets in vendor manifests: GKE vLLM 10 minutes [21], production-stack 10 minutes [22], AWS EKS vLLM 10 minutes [23], llm-d 60 minutes [24], NVIDIA Triton chart 5 minutes [28], NIM Operator 20 minutes [40], Google's TensorRT-LLM manifest 600 s plus 60 x 5 s, because load "can take a few minutes (up to 20 minutes or longer)" [29][79]. Size the budget by measuring: vLLM's docs say remove the probes and time the server [80], and warn that a threshold that is too low kills the container [81]. Two vLLM sources go the other way and deserve a caveat: the docs' Kubernetes page uses initialDelaySeconds 60 with no startupProbe [82], and the in-repo chart defaults to initialDelaySeconds 5 and 15 with failureThreshold 3 [83][84]. Those defaults restart any model that takes more than about 45 seconds to load, so copy the startupProbe pattern instead. One more knob: a Deployment's progressDeadlineSeconds defaults to 600 s [85], so a 20-minute load shows ProgressDeadlineExceeded to `kubectl rollout status` and to GitOps tools even when the probe budget is right.

**Liveness stays tolerant after startup because a restart reloads the model.** GKE's manifest requires 5 failures for exactly this reason [15]. KubeRay's liveness failureThreshold is 120 [48]. kubernetes.io documents the pattern of one cheap endpoint for both probes with a higher liveness failureThreshold, so the pod is observed not-ready before it is hard killed [86][87]. That pattern fits servers with one signal, such as vLLM. Servers that distinguish live from ready, such as NIM, Triton, KServe, and the lab's fake-inference, use two endpoints, which kubernetes.io also describes [88]. Liveness does not wait for readiness [89], and with a startup probe defined, neither probe's delay begins until it succeeds [90].

**What the probes cannot see.** A hung engine that still answers is the deadlock case liveness exists for, and a flag-style check misses it: vLLM's `check_health` reads `engine_dead` and nothing else [2], so a stuck GPU collective passes both probes. A forward-pass readiness check for vLLM is proposed in an open issue and not shipped [91]. TGI's escalation to a one-token generation after a failure [33] and TensorRT-LLM's `/health_generate`, which is undocumented and on the main branch only [92], are the closest shipped answers, along with an external watchdog such as Ray Serve's controller-side health check [49]. GPU faults belong to the node. The NVIDIA device plugin marks a GPU unhealthy on a critical XID event from NVML [17] while ignoring application-level XIDs such as a memory page fault [93], and its own README says comprehensive health checking is missing [94]. GKE marks the GPU resources unhealthy and recreates the node under auto-repair [18]. EKS exposes an AcceleratedHardwareReady condition and repairs on well-known XIDs, when its node monitoring agent is installed [95][96]. DCGM's background monitoring is passive and does not prove a GPU can run a workload [97], and dcgm-exporter's XID metric is a gauge holding the last code, not a counter [98].

**Graceful shutdown.** Endpoint removal and the kubelet's shutdown run at the same time [99]. Terminating endpoints are marked ready=false regardless of the probe [100], proxies ignore them unless every endpoint is terminating [101], and the real readiness during a drain is the `serving` condition [102]. GKE: keep accepting requests after SIGTERM, because endpoint updates are asynchronous [103], and sleep a few seconds in preStop to postpone the signal [104]. preStop blocks SIGTERM [105]; the grace period covers preStop plus shutdown [106]; the default is 30 s [107]; a native `sleep` handler exists [108]; preStop also runs before a liveness kill [109]. For an inference server, size the grace period to the longest streaming generation you allow, because removal from the endpoints stops new requests but does not close a stream in flight. GKE's advice to fail readiness on SIGTERM is scoped to container-native load balancing [110]; behind a plain Service, the terminating flag already does that job [100].

**Saturation is handled above the pod.** Kubernetes lets a readiness probe check required back-ends [111], but EKS warns that a readiness probe tied to a shared dependency takes every replica out at once [112], and AWS warns that a poorly configured readiness probe causes an outage instead of preventing one [113]. Failing readiness when the request queue is deep has the same shape: every busy replica drops out together. No official source recommends it. The inference-specific tooling puts saturation control in the gateway instead: the Kubernetes inference gateway begins queueing at 0.8 KV-cache utilization [114], argues that requests trapped in a model server's local queue cannot be re-routed [115], and sheds only negative-priority requests with 503 when saturated [116]; GKE's Inference Gateway routes on KV-cache utilization and queue depth [117]. The rule for an inference pod's readiness: local state yes (weights loaded, engine alive, warm-up done), remote dependencies and load no.

## 3. Anti-patterns

- **Liveness on an external dependency.** All pods fail at once, Kubernetes replaces them all, the app is offline [118][67].
- **A health check that returns a static 200.** SageMaker says to implement meaningful checks instead [119], and fails the instance launch if 200s do not arrive within 8 minutes [120].
- **Readiness that passes because the port is open.** Knative's default readiness is a TCP socket check on the traffic port [121] and KServe raw mode defaults to TCP [45]; Google's guidance exists precisely for servers that answer 200 before the model loads [70].
- **A startup budget smaller than the real load time.** GKE: pods crash loop forever [16]; Triton's chart README: an infinite loop of restarting pods [122]; vLLM's docs: the container is killed [81].
- **Aggressive liveness on a server whose restart reloads the model.** GKE biases toward 5 failures for this reason [15]. Cloud Run's liveness failure is a SIGKILL, so a false positive costs more there [123].
- **Closing the listener the moment SIGTERM arrives.** Endpoint updates are asynchronous [103][99].
- **A dead engine that still accepts connections.** TensorRT-LLM added shutdown on fatal error so the pod does not linger and never produce tokens [124]; before vLLM v0.11.0 a dead engine returned a generic 500 [125].

## 4. A production-shaped spec

A vLLM-like server that loads a model in a few minutes. The arithmetic is stated so the numbers can be changed together.

```yaml
spec:
  terminationGracePeriodSeconds: 120   # preStop plus the longest streaming generation you allow; the default is 30 s [107]; the period covers preStop and shutdown together [106]
  containers:
  - name: vllm
    ports:
    - name: http
      containerPort: 8000              # vLLM's docs probe /health on 8000 [82]
    startupProbe:                      # gates liveness and readiness until the model is loaded [90]
      httpGet:
        path: /health                  # unreachable until weights load and warm-up finishes [11]
        port: http
      initialDelaySeconds: 30          # AWS EKS example [23]
      periodSeconds: 10                # AWS EKS and production-stack [23][22]
      failureThreshold: 60             # 60 x 10 s = 10 minutes; measure your load time with the probes removed and set this above it [80]; too small crash-loops forever [16]
      timeoutSeconds: 5                # llm-d uses 5 on startup [24]
    readinessProbe:
      httpGet:
        path: /health                  # 503 only when the engine is dead [1]
        port: http
      periodSeconds: 5                 # AWS EKS, production-stack, llm-d [23][126]
      timeoutSeconds: 3                # AWS EKS [23]; llm-d uses 2 [126]
      failureThreshold: 1              # GKE: vLLM's check is simple, so any failure is significant [127]
    livenessProbe:
      httpGet:
        path: /health                  # same cheap endpoint, higher tolerance [86]
        port: http
      periodSeconds: 10                # production-stack and llm-d [128][126]
      timeoutSeconds: 5                # llm-d [126]
      failureThreshold: 5              # 5 x 10 s = 50 s of failures before a restart that reloads the model; GKE's reasoning [15]; llm-d uses 3 [126]
    lifecycle:
      preStop:
        sleep:                         # native handler, no shell needed [108]
          seconds: 5                   # "a sleep of a few seconds" while endpoints update [104]; the grace clock starts here [129]
```

Two things this spec does not solve. A hung engine still passes `/health` (section 2). And a Deployment rollout with a 10-minute startup needs `progressDeadlineSeconds` raised above the default 600 s [85].

## 5. The ECS and Cloud Run view

ECS has two health layers and no readiness-only outcome. The container health check, with its `startPeriod`, is the liveness twin. The load balancer target group health check is the readiness twin, except that ECS also replaces a task that fails it [130]. `healthCheckGracePeriodSeconds` on the service is the closest thing to a startup budget for the load balancer path.

Cloud Run maps more directly. Its startup probe gates traffic until the container is ready [131]. Its readiness probe stops new traffic without terminating the instance [132]. Its liveness probe restarts an instance that cannot recover, and a failure is a SIGKILL [133][123].

## 6. How fake-inference compares

Faithful:

- `/readyz` returning 503 until the simulated load finishes matches NIM's ready [6], KServe's 503 [10], GKE's cache rule [69], and Google's model serving guidance [70]. It is also how vLLM's check works: a flag, no GPU work [2].
- `/healthz` independent of model load matches NIM live [3][38], Triton live [25], KServe `live()` [5], and kubernetes.io's rule that liveness reflects only unrecoverable failure [64].
- `/admin/freeze` is the textbook liveness case: a process that runs but cannot make progress [134].
- Liveness initialDelaySeconds 15 with a known 10 s load matches kubernetes.io [89]. Readiness every 2 s against liveness every 5 s with failureThreshold 3 matches the higher-liveness-tolerance pattern [86].

Omitted:

- No startupProbe. Real loads run minutes, and vendor budgets run 5 to 60 minutes [14][21][24][28][40].
- The lab listens and returns 503 during load. vLLM and TGI do not open the port until warm-up is done [11][35][13].
- Restart cost. A lab restart costs 10 s; a production restart reloads the model, which is why GKE and KubeRay tolerate 5 and 120 failures [15][48].
- No graceful shutdown: no preStop, no SIGTERM handling, no grace period sized to in-flight work [99][103][105][106].
- One model per server. Triton, KServe, and TorchServe report readiness per model [59][61][54].
- Nothing at the node level for GPU health [17][18][95].
- No saturation signal and no gateway above the pods [114][117].
- Nothing that catches a hung engine which still answers its health check, the gap the real systems also struggle with [2][33][92].

If the labs ever grow a production variant, these are the candidates: a `MODEL_LOAD_SECONDS` of 90 with a startupProbe, a `preStop` sleep with a `terminationGracePeriodSeconds` sized to `SIMULATED_DELAY_MS`, and an endpoint that hangs generation while `/healthz` keeps passing, to show what a flag-style liveness check misses.

## Sources

1. https://github.com/vllm-project/vllm/blob/main/vllm/entrypoints/serve/instrumentator/health.py "try: await client.check_health() return Response(status_code=200) except EngineDeadError: return Response(status_code=503)"
2. https://github.com/vllm-project/vllm/blob/main/vllm/v1/engine/async_llm.py "async def check_health(self) -> None: logger.debug("Called check_health.") if self.errored: raise self.dead_error"
3. https://docs.nvidia.com/nim/large-language-models/latest/reference/api-reference.html "GET /v1/health/live Liveness probe. Returns 200 when the container is running (served by nginx; does not require model to be loaded)."
4. https://github.com/triton-inference-server/core/blob/main/src/server.cc "Server is considered live if it can respond to this health request and it was able to initialize."
5. https://github.com/kserve/kserve/blob/master/python/kserve/kserve/protocol/dataplane.py "Returns ``{"status": "alive"}`` on successful invocation. Primarily meant to be used for Kubernetes liveness check."
6. https://docs.nvidia.com/nim/large-language-models/latest/reference/architecture.html "Report readiness: After the model loads, nginx checks the backend /health endpoint, and /v1/health/ready begins returning 200 OK."
7. https://github.com/triton-inference-server/core/blob/main/src/server.cc "Server is considered ready if it is in the ready state. Additionally can report ready only when all models are ready."
8. https://github.com/triton-inference-server/server/blob/main/src/http_server.cc "evhtp_send_reply(req, ready ? EVHTP_RES_OK : EVHTP_RES_BADREQ);"
9. https://kserve.github.io/website/docs/model-serving/predictive-inference/frameworks/custom-predictor "The ready flag is used by model ready endpoint for readiness probes, set to True when model is loaded successfully without exceptions."
10. https://github.com/kserve/kserve/blob/master/python/kserve/kserve/errors.py "status_code=HTTPStatus.SERVICE_UNAVAILABLE, content={"error": str(exc)}"
11. https://docs.cloud.google.com/kubernetes-engine/docs/tutorials/serve-with-gke-inference-gateway "# vLLM does not start the OpenAI server (and hence make /health available) # until models are loaded. This may not be true for all model servers."
12. https://docs.vllm.ai/en/latest/design/torch_compile/ "we guarantee all the compilation finishes before we serve any requests. No requests will trigger new compilations."
13. https://github.com/huggingface/text-generation-inference/blob/main/docs/source/architecture.md "After these are done, the router is ready to receive generate calls from multiple clients."
14. https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/ "The solution is to set up a startup probe with the same command, HTTP or TCP check, with a failureThreshold * periodSeconds long enough to cover the worst case startup time."
15. https://docs.cloud.google.com/kubernetes-engine/docs/tutorials/serve-with-gke-inference-gateway "any liveness triggered restart requires the very large core model to be reloaded, and so we should bias towards ensuring the server is definitely unhealthy vs immediately restarting."
16. https://docs.cloud.google.com/kubernetes-engine/docs/tutorials/serve-with-gke-inference-gateway "# IMPORTANT: If the core model takes more than 10 minutes to load, pods will crash loop forever. Be sure to set this appropriately."
17. https://github.com/NVIDIA/k8s-device-plugin/blob/main/internal/rm/health.go "XidCriticalError: Xid=%d on Device=%s; marking device as unhealthy."
18. https://docs.cloud.google.com/kubernetes-engine/docs/troubleshooting/gpus "GKE marks the node's GPU resources as unhealthy. GKE prevents GPU workloads from being scheduled on the node. If node auto-repair is enabled, GKE will recreate the node."
19. https://github.com/vllm-project/vllm/releases/tag/v0.11.0 "Health 503 on dead engine (#24897)"
20. https://docs.vllm.ai/en/stable/design/cuda_graphs/ "The CUDA Graphs capturing happens when the runner first calls the model forward (using _dummy_run) with a non-NONE runtime mode."
21. https://docs.cloud.google.com/kubernetes-engine/docs/tutorials/serve-with-gke-inference-gateway "# We choose # 10 minutes as a reasonable maximum startup time before giving up and attempting # to restart the pod."
22. https://github.com/vllm-project/production-stack/blob/main/helm/values.yaml "failureThreshold: 60 # -- Configuration of the Kubelet http request on the server httpGet: # -- Path to access on the HTTP server path: /health"
23. https://docs.aws.amazon.com/eks/latest/userguide/ml-inference-fast-model-loading.html "startupProbe: httpGet: path: /health port: 8000 periodSeconds: 10 failureThreshold: 60 initialDelaySeconds: 30 readinessProbe: httpGet: path: /health port: 8000 periodSeconds: 5 timeoutSeconds: 3"
24. https://github.com/llm-d/llm-d/blob/main/guides/optimized-baseline/modelserver/gpu/vllm/base/patch-vllm.yaml "startupProbe: initialDelaySeconds: 15 periodSeconds: 30 timeoutSeconds: 5 failureThreshold: 120"
25. https://github.com/triton-inference-server/server/issues/7014 "/v2/health/live is the one you should use for liveliness check and is independent of the model being loaded/unloaded."
26. https://github.com/triton-inference-server/server/blob/main/src/command_line_parser.cc "If true /v2/health/ready endpoint indicates ready if the server is responsive and all models are available. If false /v2/health/ready endpoint indicates ready if server is responsive even if some/all models are unavailable."
27. https://github.com/triton-inference-server/server/blob/main/deploy/k8s-onprem/README.md "By default, Triton loads all the models before starting the HTTP server to respond to the probes. The process can take several minutes, depending on the models sizes."
28. https://github.com/triton-inference-server/server/blob/main/deploy/k8s-onprem/templates/deployment.yaml "startupProbe: # allows Triton to load the models during 30*10 = 300 sec = 5 min # starts checking the other probes only after the success of this one"
29. https://github.com/GoogleCloudPlatform/kubernetes-engine-samples/blob/main/ai-ml/llm-serving-gemma/trtllm/deploy-triton-server.yaml "readinessProbe: failureThreshold: 60 initialDelaySeconds: 600 periodSeconds: 5 httpGet: path: /v2/health/ready port: http"
30. https://github.com/huggingface/text-generation-inference/blob/main/router/src/server.rs "(status = 200, description = "Everything is working fine"), (status = 503, description = "Text generation inference is down", body = ErrorResponse, example = json ! ({"error": "unhealthy", "error_type": "healthcheck"})),"
31. https://github.com/huggingface/text-generation-inference/blob/main/backends/v3/src/backend.rs "if current_health { // Generation is healthy, we only check that the shards can allocate on device self.client.device_health().await } else { self.client.model_health().await }"
32. https://github.com/huggingface/text-generation-inference/blob/main/server/text_generation_server/server.py "async def Health(self, request, context): if self.model.device.type == "cuda": torch.zeros((2, 2)).cuda() return generate_pb2.HealthResponse()"
33. https://github.com/huggingface/text-generation-inference/blob/main/backends/client/src/lib.rs "/// Check if a generate server is healthy by asking it to allocate a tensor on device async fn device_health(&self) -> Result<()>; /// Check if a generate server is healthy by doing a forward pass. /// EXPENSIVE"
34. https://github.com/huggingface/text-generation-inference/blob/main/router/src/infer/mod.rs "let response = response.inspect_err(|_err| { self.backend_health.store(false, Ordering::SeqCst); })?;"
35. https://github.com/huggingface/text-generation-inference/blob/main/launcher/src/main.rs "// All shard started // Start webserver tracing::info!("Starting Webserver");"
36. https://github.com/huggingface/hugs-helm-chart/blob/main/charts/hugs/templates/deployment.yaml "livenessProbe: httpGet: path: /health port: {{ $.Values.env.PORT | default 80 | int }} initialDelaySeconds: {{ .Values.livenessProbe.initialDelaySeconds | default 360 }} periodSeconds: {{ .Values.livenessProbe.periodSeconds | default 30 }}"
37. https://github.com/huggingface/hugs-helm-chart/blob/main/charts/hugs/values.yaml "You may want to increase the initialDelaySeconds for the bigger LLMs as Llama 3.1 405B since the download will take longer and the default delay may not be enough"
38. https://docs.nvidia.com/nim/large-language-models/latest/deployment/kubernetes-deployment/nim-operator-deployment.html "The nginx proxy in the NIM container serves the health endpoints. /v1/health/live responds immediately, even during model loading, while /v1/health/ready only returns 200 after the model is fully loaded."
39. https://docs.nvidia.com/nim/large-language-models/latest/reference/api-reference.html "GET /v1/health/ready Readiness probe. Returns 200 when the model is loaded and inference is available."
40. https://docs.nvidia.com/nim/large-language-models/latest/deployment/kubernetes-deployment/nim-operator-deployment.html "The operator configures a startup probe on /v1/health/ready with a default failureThreshold of 120 and a periodSeconds of 10, giving the model up to 20 minutes to load before the pod is killed."
41. https://docs.nvidia.com/nim-operator/latest/service.html "By default, the Operator configures an HTTP GET probe to /v1/health/live with the following settings: Initial delay: 15 seconds Timeout: 1 second Period: 10 seconds Failure threshold: 3"
42. https://docs.nvidia.com/nim-operator/latest/service.html "All other probes are disabled until the startup probe succeeds. By default, the Operator configures an HTTP GET probe to /v1/health/ready with the following settings: Initial delay: 30 seconds"
43. https://kserve.github.io/website/docs/concepts/architecture/data-plane/v2-protocol "The 'server live' health API indicates if the inference server is able to receive and respond to metadata and inference requests."
44. https://kserve.github.io/website/docs/concepts/architecture/data-plane/v2-protocol "The 'server ready' health API indicates if all the models are ready for inferencing."
45. https://github.com/kserve/kserve/blob/master/pkg/controller/v1beta1/inferenceservice/reconcilers/deployment/deployment_reconciler.go "TimeoutSeconds:   1, PeriodSeconds:    10, SuccessThreshold: 1, FailureThreshold: 3,"
46. https://kserve.github.io/website/docs/model-serving/predictive-inference/transformers/collocation "HTTP readiness probe can be specified in the transformer container to override the default TCP readiness probe."
47. https://github.com/ray-project/kuberay/blob/master/ray-operator/controllers/ray/common/pod.go "Generally, the liveness and readiness probes perform the same checks. For head node => Check GCS and Raylet status. For worker node => Check Raylet status."
48. https://github.com/ray-project/kuberay/blob/master/ray-operator/controllers/ray/utils/constant.go "DefaultLivenessProbeFailureThreshold   = 120"
49. https://docs.ray.io/en/latest/serve/production-guide/fault-tolerance.html "If the health-check fails, the Serve controller logs the exception, kills the unhealthy replica(s), and restarts them."
50. https://github.com/ray-project/ray/blob/master/python/ray/serve/_private/proxy.py "If the proxy is draining or has not yet received a route table update from the controller, both will return a non-OK status."
51. https://github.com/ray-project/kuberay/blob/master/ray-operator/controllers/ray/common/pod.go "For worker Pods serving traffic, we need to add an additional HTTP proxy health check for the readiness probe."
52. https://github.com/ray-project/kuberay/blob/master/ray-operator/controllers/ray/utils/constant.go "DefaultReadinessProbeFailureThreshold   = 10 ServeReadinessProbeFailureThreshold     = 1"
53. https://docs.ray.io/en/latest/cluster/kubernetes/troubleshooting/rayservice-troubleshooting.html "If the status of a serve application remains non-`RUNNING` for more than `serviceUnhealthySecondThreshold` seconds, the KubeRay operator will consider the RayCluster as unhealthy and initiate the preparation of a new RayCluster."
54. https://docs.pytorch.org/serve/inference_api.html "return 500 + json message "unhealthy": for any model, the number of active workers is less than the configured minWorkers."
55. https://docs.pytorch.org/serve/inference_api.html "return 200 + json message "healthy": for any model, the number of active workers is equal or larger than the configured minWorkers."
56. https://github.com/pytorch/serve/blob/master/kubernetes/README.md "* [] Readiness / Liveness Probes"
57. https://docs.pytorch.org/serve/inference_api.html ""maxRetryTimeoutInSec" (default: 5MIN) can be defined in a model's config yaml file(e.g model-config.yaml). It is the maximum time window of recovering a dead backend worker."
58. https://github.com/pytorch/serve/blob/master/README.md "This project is no longer actively maintained. While existing releases remain available, there are no planned updates, bug fixes, new features, or security patches."
59. https://github.com/triton-inference-server/server/blob/main/src/http_server.cc "RETURN_AND_RESPOND_WITH_ERR(req, EVHTP_RES_BADREQ, "Model version not ready");"
60. https://github.com/triton-inference-server/core/blob/main/src/model_repository_manager/model_lifecycle.h "The model is being loaded by the inference server. The model is not available for inferencing."
61. https://kserve.github.io/website/docs/concepts/architecture/data-plane/v1-protocol "The 'model ready' health API indicates if a specific model is ready for inferencing."
62. https://kserve.github.io/website/docs/concepts/architecture/data-plane/v2-protocol "The Model Readiness probe answers the question 'Did the model download and is it able to serve requests?' and responds with the available model name(s)."
63. https://docs.aws.amazon.com/sagemaker/latest/dg/deploy-models-frameworks-triton.html "'ready' is the default mode in SageMaker AI's single model mode, and 'live' is the default in SageMaker AI's multi-model endpoints mode."
64. https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/ "Liveness probes must be configured carefully to ensure that they truly indicate unrecoverable application failure, for example a deadlock."
65. https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/ "Incorrect implementation of liveness probes can lead to cascading failures."
66. https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/ "This results in restarting of container under high load; failed client requests as your application became less scalable; and increased workload on remaining pods due to some failed pods."
67. https://docs.aws.amazon.com/eks/latest/best-practices/application.html "Avoid configuring the Liveness Probe to depend on an a factor that is external to your Pod, for example, a external database."
68. https://docs.cloud.google.com/architecture/best-practices-for-running-cost-effective-kubernetes-applications-on-gke "Never make any probe logic access other services. It can compromise the lifecycle of your Pod if these services don't respond promptly."
69. https://docs.cloud.google.com/architecture/best-practices-for-running-cost-effective-kubernetes-applications-on-gke "If your application depends on a cache to be loaded at startup, the readiness probe must say it's ready only after the cache is fully loaded."
70. https://docs.cloud.google.com/vertex-ai/docs/predictions/custom-container-requirements "a health probe should be configured to return success only when the model is loaded and ready to serve traffic."
71. https://docs.aws.amazon.com/sagemaker/latest/dg/your-algorithms-inference-code.html "For example, the container can verify that the model is loaded into memory and can serve inference requests. The request timeout on `/ping` attempts is 2 seconds."
72. https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/ "This is useful when waiting for an application to perform time-consuming initial tasks, such as establishing network connections, loading files, and warming caches."
73. https://docs.vllm.ai/en/latest/configuration/optimization/ "Skips both compilation and CUDA-graph capture for the fastest possible startup, at the cost of steady-state decode performance."
74. https://docs.aws.amazon.com/eks/latest/userguide/ml-inference-fast-model-loading.html "The tradeoff of torch.compile is that the first inference Pod must compile before it can serve requests. This compilation can take as long as several minutes depending on model size."
75. https://github.com/huggingface/text-generation-inference/blob/main/docs/source/architecture.md "Router->>Model Server: health check Model Server-->>Router: health OK Router->>Model Server: warmup(max_input_tokens, max_batch_prefill_tokens, max_total_tokens, max_batch_size)"
76. https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/ "Once the startup probe has succeeded once, the liveness probe takes over to provide a fast response to container deadlocks."
77. https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/ "You should then set its failureThreshold high enough to allow the container to start, without changing the default values of the liveness probe. This helps to protect against deadlocks."
78. https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/ "If the startup probe fails, the kubelet kills the container, and the container is subjected to its restart policy."
79. https://docs.cloud.google.com/kubernetes-engine/docs/tutorials/serve-gemma-gpu-tensortllm "The deployment resource launches the Triton server and loads the model data. This process can take a few minutes (up to 20 minutes or longer)."
80. https://docs.vllm.ai/en/latest/deployment/k8s/ "identify an ideal failureThreshold by removing the probes from the manifest and measuring how much time it takes for the model server to show it's ready to serve."
81. https://docs.vllm.ai/en/latest/deployment/k8s/ "If the startup or readiness probe failureThreshold is too low for the time needed to start up the server, Kubernetes scheduler will kill the container."
82. https://docs.vllm.ai/en/latest/deployment/k8s/ "livenessProbe: httpGet: path: /health port: 8000 initialDelaySeconds: 60 periodSeconds: 10 readinessProbe: httpGet: path: /health port: 8000 initialDelaySeconds: 60 periodSeconds: 5"
83. https://docs.vllm.ai/en/latest/deployment/frameworks/helm/ "| readinessProbe | object | {"failureThreshold":3,"httpGet":{"path":"/health","port":8000},"initialDelaySeconds":5,"periodSeconds":5} | Readiness probe configuration |"
84. https://docs.vllm.ai/en/latest/deployment/frameworks/helm/ "| livenessProbe | object | {"failureThreshold":3,"httpGet":{"path":"/health","port":8000},"initialDelaySeconds":15,"periodSeconds":10} | Liveness probe configuration |"
85. https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#progress-deadline-seconds ".spec.progressDeadlineSeconds is an optional field that specifies the number of seconds you want to wait for your Deployment to progress before the system reports back that the Deployment has failed progressing"
86. https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/ "A common pattern for liveness probes is to use the same low-cost HTTP endpoint as for readiness probes, but with a higher failureThreshold."
87. https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/ "This ensures that the pod is observed as not-ready for some period of time before it is hard killed."
88. https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/ "You can also use a readiness probe to let a container take itself down for maintenance, by checking an endpoint specific to readiness that is different from the liveness probe."
89. https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/ "Liveness probes do not wait for readiness probes to succeed. If you want to wait before executing a liveness probe, you can either define initialDelaySeconds or use a startup probe."
90. https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/ "If a startup probe is defined, liveness and readiness probe delays do not begin until the startup probe has succeeded."
91. https://github.com/vllm-project/vllm/issues/36960 "run an actual GPU forward pass (1-token dummy batch) to verify the GPU can execute inference end-to-end"
92. https://github.com/NVIDIA/TensorRT-LLM/blob/main/tensorrt_llm/serve/openai_server.py "Health check that performs a minimal generation."
93. https://github.com/NVIDIA/k8s-device-plugin/blob/main/internal/rm/health.go "Application errors: the GPU should still be healthy ignoredXids := []uint64{ 13, // Graphics Engine Exception 31, // GPU memory page fault 43, // GPU stopped processing 45, // Preemptive cleanup, due to previous errors"
94. https://github.com/NVIDIA/k8s-device-plugin "The NVIDIA device plugin is currently lacking - Comprehensive GPU health checking features - GPU cleanup features"
95. https://docs.aws.amazon.com/eks/latest/userguide/node-health.html "AcceleratedHardwareReady indicates whether accelerated hardware (GPU, Neuron) on the node is functioning correctly."
96. https://docs.aws.amazon.com/eks/latest/userguide/node-health-nma.html "Well-known XID codes – Critical errors that set a node condition (AcceleratedHardwareReady=False) and trigger auto repair when enabled."
97. https://docs.nvidia.com/datacenter/dcgm/latest/learn/modules/health-monitoring.html "does not apply load to prove that a GPU can execute a workload"
98. https://github.com/NVIDIA/dcgm-exporter/blob/main/etc/default-counters.csv "DCGM_FI_DEV_XID_ERRORS, gauge, Value of the last XID error encountered."
99. https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/ "At the same time as the kubelet is starting graceful shutdown of the Pod, the control plane evaluates whether to remove that shutting-down Pod from EndpointSlice objects,"
100. https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/ "Terminating endpoints always have their ready status as false (for backward compatibility with versions before 1.26), so load balancers will not use it for regular traffic."
101. https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/ "Service proxies will normally ignore endpoints that are terminating, but they may route traffic to endpoints that are both serving and terminating if all available endpoints are terminating."
102. https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/ "If traffic draining on terminating Pod is needed, the actual readiness can be checked as a condition serving."
103. https://docs.cloud.google.com/architecture/best-practices-for-running-cost-effective-kubernetes-applications-on-gke "Don't stop accepting new requests right after SIGTERM. Your application must not stop immediately, but instead finish all requests that are in flight and still listen to incoming connections"
104. https://docs.cloud.google.com/architecture/best-practices-for-running-cost-effective-kubernetes-applications-on-gke "One common strategy is to execute, in the preStop hook, a sleep of a few seconds to postpone the SIGTERM. This gives Kubernetes extra time to finish the Pod deletion process"
105. https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/ "PreStop hooks are not executed asynchronously from the signal to stop the Container; the hook must complete its execution before the TERM signal can be sent."
106. https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/ "This grace period applies to the total time it takes for both the PreStop hook to execute and for the Container to stop normally."
107. https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/ "The default terminationGracePeriodSeconds setting is 30 seconds."
108. https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/ "Sleep - Pauses the container for a specified duration."
109. https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/ "This hook is called immediately before a container is terminated due to an API request or management event such as a liveness/startup probe failure, preemption, resource contention and others."
110. https://docs.cloud.google.com/architecture/best-practices-for-running-cost-effective-kubernetes-applications-on-gke "start failing your readiness probe when you receive a SIGTERM. This action directly signals load balancers to stop forwarding new requests to the backend Pod."
111. https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/ "The liveness probe passes when the app itself is healthy, but the readiness probe additionally checks that each required back-end service is available."
112. https://docs.aws.amazon.com/eks/latest/best-practices/application.html "if a Pod's Readiness Probe fails when the app's database is unreachable, other Pod replicas will also fail simultaneously since they share the same health-check criteria."
113. https://docs.aws.amazon.com/prescriptive-guidance/latest/ha-resiliency-amazon-eks-apps/probes-checks.html "However, a poorly configured readiness probe can cause an outage instead of preventing it."
114. https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/release-1.5/site-src/guides/flow-control.md "kvCacheUtilThreshold (Default: 0.8): The maximum KV-cache memory utilization allowed before the pool is considered saturated and EPP queueing engages."
115. https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/release-1.5/site-src/guides/flow-control.md "Model servers protect their hardware during spikes by queuing requests locally. However, requests trapped inside isolated, local queues cannot be dynamically re-routed or preempted by higher-priority traffic"
116. https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/release-1.5/site-src/guides/epp-configuration/config-text.md "When the pool is saturated, the gateway immediately rejects (HTTP 503) incoming "sheddable" requests (those with a negative priority) to protect the backends."
117. https://docs.cloud.google.com/kubernetes-engine/docs/concepts/about-gke-inference-gateway "Load aware routing: GKE Inference Gateway monitors server load (KV cache utilization and pending queue depth), and gives a higher score to a server with lower load."
118. https://docs.aws.amazon.com/eks/latest/best-practices/application.html "ensure that your application doesn't run into a situation in which all Pods simultaneously fail the Liveness Probe because Kubernetes will try to replace all your Pods, which will render your application offline."
119. https://docs.aws.amazon.com/sagemaker/latest/dg/your-algorithms-inference-code.html "We strongly recommend implementing meaningful health checks rather than returning a static 200."
120. https://docs.aws.amazon.com/sagemaker/latest/dg/your-algorithms-inference-code.html "If the container does not begin to pass health checks by consistently responding with 200s during the 8 minutes after startup, the new instance launch fails."
121. https://knative.dev/docs/serving/services/configure-probing/ "Knative will define a default Readiness probe for the primary user container when no probe is defined by the user. It will check for a TCP socket on the traffic port of the Knative Service."
122. https://github.com/triton-inference-server/server/blob/main/deploy/k8s-onprem/README.md "If it is not completed in `startupProbe.failureThreshold * startupProbe.periodSeconds` seconds then Kubernetes considers this as a pod failure and restarts it, ending up with an infinite loop of restarting pods"
123. https://docs.cloud.google.com/run/docs/configuring/healthchecks "If a liveness probe does not succeed within the specified time (failureThreshold * periodSeconds), the container is shut down using a SIGKILL signal."
124. https://github.com/NVIDIA/TensorRT-LLM/blob/main/tensorrt_llm/serve/openai_server.py "If the engine has a fatal error, trigger server shutdown so the pod doesn't linger as a zombie that accepts connections but never produces tokens."
125. https://github.com/vllm-project/vllm/pull/24897 "caught by a generic exception handler in launcher.py that returns HTTP 500 Internal Server Error"
126. https://github.com/llm-d/llm-d/blob/main/guides/optimized-baseline/modelserver/gpu/vllm/base/patch-vllm.yaml "livenessProbe: periodSeconds: 10 timeoutSeconds: 5 failureThreshold: 3 readinessProbe: periodSeconds: 5 timeoutSeconds: 2 failureThreshold: 3"
127. https://docs.cloud.google.com/kubernetes-engine/docs/tutorials/serve-with-gke-inference-gateway "# vLLM has a very simple health implementation, which means that any failure is # likely significant, failureThreshold: 1 timeoutSeconds: 1"
128. https://github.com/vllm-project/production-stack/blob/main/helm/values.yaml "livenessProbe: # -- Number of seconds after the container has started before liveness probe is initiated initialDelaySeconds: 15"
129. https://docs.aws.amazon.com/eks/latest/best-practices/application.html "The terminationGracePeriodSeconds value applies from when the PreStop hook action begins executing, not when the SIGTERM signal is sent."
130. https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs_services.html "The service scheduler also replaces tasks determined to be unhealthy after a container health check or a load balancer target group health check fails."
131. https://docs.cloud.google.com/run/docs/configuring/healthchecks "Startup probes determine whether the container has started and is ready to accept traffic."
132. https://docs.cloud.google.com/run/docs/configuring/healthchecks "If an instance fails its readiness probe beyond the failure threshold value you configure, Cloud Run stops sending new traffic to it. Cloud Run doesn't terminate the instance"
133. https://docs.cloud.google.com/run/docs/configuring/healthchecks "Liveness probes are intended to restart individual instances that can't be recovered in any other way. They should be used primarily for unrecoverable instance failures, such as catching a deadlock"
134. https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/ "Liveness probes determine when to restart a container. For example, liveness probes could catch a deadlock, where an application is running, but unable to make progress."
