"""fake-inference: the shared sample server every Forge tenant Service runs.

Simulates a model server: a startup delay stands in for model loading, a
per-request delay stands in for inference latency, and an optional CPU burn
gives HPA something real to scale on. Serves Prometheus metrics.
"""
import asyncio
import os
import time

from fastapi import FastAPI
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel

MODEL_NAME = os.environ.get("MODEL_NAME", "forge-tiny")
VERSION = os.environ.get("VERSION", "0.1.1")
# Seconds before the "model" is loaded and the server reports ready.
MODEL_LOAD_SECONDS = int(os.environ.get("MODEL_LOAD_SECONDS", "10"))
# Simulated inference latency per request (does not burn CPU).
SIMULATED_DELAY_MS = int(os.environ.get("SIMULATED_DELAY_MS", "150"))
# Busy-loop per request to consume real CPU, so HPA labs have a signal.
BURN_CPU_MS = int(os.environ.get("BURN_CPU_MS", "0"))

STARTED_AT = time.monotonic()

# Set by POST /admin/freeze. A frozen server keeps its process alive but fails
# health checks, simulating a hung model server so liveness probes have
# something real to catch.
FROZEN = False

app = FastAPI(title="fake-inference")

REQUESTS = Counter("inference_requests_total", "Completions served", ["model"])
LATENCY = Histogram("inference_latency_seconds", "Time to serve a completion", ["model"])


def model_loaded() -> bool:
    return time.monotonic() - STARTED_AT >= MODEL_LOAD_SECONDS


def burn_cpu(ms: int) -> None:
    """Busy-loop in a worker thread, off the event loop, so probes and
    /metrics stay responsive under load. The GIL still caps total burn near
    one core per pod, which is the point: the HPA lab scales replicas."""
    end = time.perf_counter() + ms / 1000
    while time.perf_counter() < end:
        pass


class CompletionRequest(BaseModel):
    prompt: str


@app.post("/v1/completions")
async def completions(req: CompletionRequest):
    if not model_loaded():
        return JSONResponse({"error": "model is still loading"}, status_code=503)
    start = time.perf_counter()
    await asyncio.sleep(SIMULATED_DELAY_MS / 1000)
    if BURN_CPU_MS:
        await asyncio.to_thread(burn_cpu, BURN_CPU_MS)
    elapsed = time.perf_counter() - start
    REQUESTS.labels(MODEL_NAME).inc()
    LATENCY.labels(MODEL_NAME).observe(elapsed)
    return {
        "model": MODEL_NAME,
        "version": VERSION,
        "completion": f"[{MODEL_NAME}] {len(req.prompt.split())} tokens in; here is a very confident answer.",
        "latency_ms": round(elapsed * 1000),
    }


@app.get("/healthz")
async def healthz():
    """Liveness: the process is healthy. Never gated on model loading."""
    if FROZEN:
        return JSONResponse({"status": "frozen"}, status_code=503)
    return {"status": "ok"}


@app.post("/admin/freeze")
async def freeze():
    """Simulate a hang: stay running but fail health checks from now on.

    Only a container restart clears the flag, which is the point: that is
    exactly what a liveness probe is for."""
    global FROZEN
    FROZEN = True
    return {"status": "frozen", "hint": "liveness probe should restart me"}


@app.get("/readyz")
async def readyz():
    """Readiness: safe to receive traffic only once the model is loaded."""
    if FROZEN:
        return JSONResponse({"status": "frozen"}, status_code=503)
    if not model_loaded():
        return JSONResponse({"status": "loading model"}, status_code=503)
    return {"status": "ready", "model": MODEL_NAME}


@app.get("/metrics")
async def metrics():
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)
