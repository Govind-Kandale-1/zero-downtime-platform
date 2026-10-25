# load/ — code review

**Purpose:** the load tests behind the capacity numbers and evidence items 01 and 03. They run with k6 from a container (`tool_k6`) on the `kind` Docker network, against Traefik's NodePort with each stack's `Host` header. That's the same path real users take, so edge metrics, canary analysis and KEDA all see the load.

| Path | What it is |
|---|---|
| `k6/` | HTTP load scripts (see `k6/code-review.md`) |
| `jobs/` | The queue job producer (see `jobs/code-review.md`) |

**Run them:**

```bash
source scripts/lib/tools.sh && TOOL_DOCKER_ARGS="--network kind" tool_k6 run -e HOST=prod.localtest.me load/k6/<script>.js
```

**Results so far:** per-pod capacity C ≈ 180 req/s, with p95 ≈ 50 ms until it saturates at about 195 req/s (`docs/capacity.md`, `evidence/03-load-15x/calibration/`).

**Label:** RUN-LOCAL (stand-in).
