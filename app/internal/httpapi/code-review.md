# app/internal/httpapi/ — code review

**Purpose:** the HTTP contract of the black box, plus the stand-in's capacity model and fault injection.

| File | What it does |
|---|---|
| `server.go` | `New(cfg, Deps{DB Querier; Queue Enqueuer})`. `Querier`/`Enqueuer` are tiny interfaces, so tests use fakes and production uses `*pgxpool.Pool` / `*queue.Queue`. Routes, using Go 1.22+ method patterns: `GET /healthz` returns 200 always, even while draining. `GET /readyz` returns 200 only when ready and not shutting down. `GET /metrics`. `GET /version`. `GET /api/items/{id}` sleeps `WorkLatency`, then does an indexed SELECT, and handles 400/404/500. `POST /api/jobs` takes `duration_ms` in [0, 60000], enqueues the job and returns 202 with its id. |
| `limiter.go` | A semaphore of `MAX_INFLIGHT` slots. Callers **queue** for a slot until their context ends; there is no fast reject. Overload therefore shows up as rising latency, as it would with a real thread pool, so the scaling signal behaves realistically without burning laptop CPU. Per-pod capacity ≈ `MAX_INFLIGHT / latency`, about 100 req/s at the defaults. |
| `metrics.go` | A private Prometheus registry exposing `http_requests_total{route,code}`, `http_request_duration_seconds{route}` and `http_inflight_requests`, plus Go/process collectors. The latency buckets **include 0.4 s**, so p95 < 400 ms is read exactly. Route labels are fixed names, never raw paths, to keep cardinality bounded. |
| `fault.go` | Adds optional extra latency, then returns a 500 with probability `FaultErrorRate`. It applies only to `/api/*`, so a bad release fails *canary analysis* instead of being restarted by liveness probes. |
| `*_test.go` | readiness flips on shutdown; healthz is always OK; items return 200/404/400; fault rate 1 always gives 500 and rate 0 never gives a 5xx; job enqueue and duration validation; version; `le="0.4"` is present; the limiter queues beyond capacity and never leaks a slot when a waiter cancels. |

**Key decisions:** ADR-005 (bounded concurrency instead of CPU burn). The platform's SLIs and canary gates read **Traefik's** metrics, not these, because the real app's metric names are unknown (ADR-011). The app metrics here are for debugging.

**Verify:** `bash scripts/test-go.sh unit` (12 tests in this package).

**Label:** RUN-LOCAL (stand-in).
