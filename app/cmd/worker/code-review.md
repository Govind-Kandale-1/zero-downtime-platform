# app/cmd/worker/ — code review

**Purpose:** the worker process lifecycle.

| File | What it does |
|---|---|
| `main.go` | 1. `config.LoadWorker()` (`REDIS_URL` required, `QUEUE_NAME=jobs`, `METRICS_PORT=9090`). 2. The worker id is the **pod hostname**, so each replica owns its own processing list. 3. Serves `/metrics` and `/healthz` on :9090. 4. Samples queue gauges every 5 s. 5. Runs `worker.Run` until SIGTERM, which finishes the in-flight job, then exits 0. |

**Key decisions:**
- **Hostname as worker id.** Pod names are unique and stable for a pod's life, so the processing list and heartbeat map one-to-one to a pod, and a dead pod's list is easy to spot.
- **A separate port for metrics.** The worker contract has no HTTP surface, so metrics get their own port (`9090`), scraped by a PodMonitor. They are stand-in-only and labelled as such.
- **The chart pairs this with `terminationGracePeriodSeconds: 90`.** SIGTERM → finish ≤ 60 s → exit, well before SIGKILL.

**Verify:** the behaviour is covered by `internal/worker` tests. The process wiring is exercised by `scripts/tests/image_smoke_test.sh` (Task 4), where the worker drains one job.

**Label:** RUN-LOCAL (stand-in).
