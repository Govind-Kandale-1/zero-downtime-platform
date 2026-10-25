# load/k6/ — code review

| File | What it does |
|---|---|
| `lib.js` | `BASE_URL` (default `http://zdp-control-plane:30080`, Traefik's NodePort inside the `kind` network) and `HOST` (the stack's hostname). `getItem()` sends `GET /api/items/{1..1000}` and `postJob()` sends `POST /api/jobs`, both with a `Host` header and a 10 s timeout. `summarize()` produces a compact text summary; it labels `http_req_failed` counts as failed/ok, because k6 counts a failed request as a "pass" in that metric. |
| `step-single-pod.js` | **Per-pod capacity.** One `constant-arrival-rate` scenario per step (default 20 → 240 req/s, 60 s each). Per-step thresholds produce per-step sub-metrics. `handleSummary` writes a CSV of offered vs achieved req/s, p95 and error rate, with a verdict: **OK** when p95 < 400 ms and there are no errors, otherwise **SATURATED**. |
| `ramp-15x.js` | **The 15x test.** `ramping-arrival-rate` at `BASE_RPS` (150) for 2 min, ramp to 15× over 3 min, hold 5 min, ramp down over 2 min. Requests are tagged with a phase from elapsed time. Thresholds: `http_req_failed rate==0`, plus p95 < 400 ms during **hold** and **base**. The ramp phase is reported only (< 2 s), because the ramp is where pods are still arriving. `BASE_RPS` lets the same 15× shape run from a lower base if the laptop saturates first. |
| `steady-under-deploy.js` | A constant 150 req/s for `DURATION` (20 min), held while a release rolls through. Thresholds: zero failed requests, p95 < 400 ms. |

**Key decisions:**
- **Arrival-rate executors, not VU loops.** The offered load stays constant even when the system slows down. A closed-loop test would back off by itself and hide saturation.
- **Through the ingress, not straight to pods.** The test then measures what users get, and it exercises the same metrics that gate canaries and drive scaling.

**Label:** RUN-LOCAL (stand-in).
