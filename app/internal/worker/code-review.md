# app/internal/worker/ — code review

**Purpose:** the consumer loop. Its one hard rule: **a claimed job is always finished**, even after SIGTERM. Then neither a rollout nor a KEDA scale-in drops work, as long as the pod's `terminationGracePeriodSeconds` (90 s) exceeds the longest job (60 s).

| File | What it does |
|---|---|
| `worker.go` | `Run(ctx, q, Config)`: heartbeat at once, then every 10 s with a 30 s TTL; reaper every 15 s; loop `Claim` (2 s blocks) → sleep `duration_ms` (the "work") → `Ack`, or `Fail` malformed jobs. When `ctx` is cancelled it stops claiming, finishes the job in hand, and returns. `DefaultConfig()` holds the production timings. |
| `metrics.go` | Stand-in-only `/metrics`: `jobs_processed_total{result}`, `job_duration_seconds`, `queue_oldest_job_age_seconds`, `queue_depth`. `SampleQueue` refreshes the two gauges every 5 s. |
| `worker_test.go` | Cancel mid-job finishes and acks the job; cancel stops further claims (2 of 3 left for peers); 3 workers × 52 jobs (2 malformed) balance as `52 = 50 done + 2 failed`; a dead peer's orphaned job is reaped and completed. |

**Key decisions, the subtle parts:**
- **The heartbeat outlives `ctx`.** After SIGTERM the worker may still spend up to 60 s finishing a job. If the heartbeat stopped at SIGTERM, a peer's reaper would hand that job to someone else mid-flight and it would run twice. The heartbeat uses a background context that ends only when `Run` returns.
- **Claims use the background context too, bounded by `ClaimTimeout`.** Cancelling a blocking BLMOVE mid-flight could move a job server-side and lose the reply. Instead the loop checks `ctx` between 2 s claims, so shutdown latency is ≤ 2 s plus the job in hand.
- **The work is never interrupted.** This models a job that can't checkpoint. If the real worker ignores SIGTERM and is SIGKILLed at 90 s, its job stays in `jobs:processing:<pod>` and the reaper returns it after the heartbeat expires (≤ 30 s). The job is late, not lost.

**Verify:** `bash scripts/test-go.sh unit` (4 worker tests, stable across `-count=3`).

**Label:** RUN-LOCAL (stand-in).
