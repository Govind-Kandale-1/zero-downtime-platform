# app/internal/queue/ — code review

**Purpose:** the reliable job queue shared by the API (producer) and the worker (consumer), on any Redis-protocol server (Valkey locally, ElastiCache for Valkey on AWS). ADR-006.

| File | What it does |
|---|---|
| `queue.go` | `Job{id, enqueued_at, duration_ms}`, which keeps the raw payload privately because `LREM` needs the exact bytes. Methods: `Enqueue` (LPUSH + INCR `enqueued_total`, in one MULTI/EXEC); `Claim` (**BLMOVE** `jobs` → `jobs:processing:<worker>`, oldest first; nil on timeout; `ErrMalformed`, still carrying the raw payload, for undecodable jobs); `Ack` (LREM + INCR `done_total`); `Fail` (LREM + LPUSH `jobs:failed` + INCR `failed_total`); `Heartbeat` (SET `worker:hb:<id>` with a TTL); `OldestAge` (LINDEX -1 → `now - enqueued_at`); `Depth` (LLEN). |
| `reaper.go` | `Reap`: one leader per window (`SET jobs:reaper-lock NX EX`). It SCANs `jobs:processing:*`, and for each list whose heartbeat key has expired it **LMOVEs every item back to the head** of `jobs`, because those jobs are older than anything pending. |
| `queue_test.go`, `reaper_test.go` | miniredis: claim moves to the processing list; oldest first; timeout returns nil; ack and fail bookkeeping; oldest age reads the tail; heartbeat TTL; the reaper touches only dead workers, puts rescued jobs first, and runs as a single leader. |
| `queue_integration_test.go` | Against real Valkey: claim → crash (no heartbeat) → a peer reaps → claims → acks; the counters balance. |

**Key decisions:**
- **Claim = atomic move, not pop.** With a plain `RPOP`, a crash between pop and completion silently loses the job. With BLMOVE, the job is always in exactly one list: pending, processing or failed.
- **At-least-once, not exactly-once.** A worker that finishes a job but dies before `Ack` will see that job run again after the reaper returns it. Real jobs must be idempotent; exactly-once would need a dedupe store keyed by job id.
- **Heartbeat TTL 30 s, beat every 10 s:** three missed beats before a worker is declared dead.
- **Accounting counters** make "no dropped jobs" provable: after draining, `enqueued_total == done_total + failed_total`.
- **`enqueued_at` in the payload** is the only way to measure queue *age* on a list. It is an assumption about the real black box; list length (from redis_exporter) is the black-box-safe signal.

**Verify:**
- `bash scripts/test-go.sh unit`: 11 queue tests.
- `bash scripts/test-go.sh integration`: the Valkey lifecycle.

**Label:** RUN-LOCAL (stand-in).
