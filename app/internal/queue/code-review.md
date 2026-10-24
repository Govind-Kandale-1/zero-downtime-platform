# app/internal/queue/ — code review

**Purpose:** the job queue shared by the API (producer) and the worker (consumer). It runs on any Redis-protocol server: Valkey locally, ElastiCache for Valkey on AWS.

| File | What it does |
|---|---|
| `queue.go` | `Job{id, enqueued_at, duration_ms}`, `New(rdb, name, workerID)`, and `Enqueue`. `Enqueue` runs `LPUSH jobs` + `INCR jobs:enqueued_total` in one MULTI/EXEC, so the accounting counter can never disagree with the list. |
| `enqueue_test.go` | Runs against miniredis: one item is pushed, the counter is 1, and the payload has a non-zero `enqueued_at`. |

The consumer side arrives with the worker (Task 3, ADR-006): `Claim` (BLMOVE into a per-worker processing list), `Ack`, `Fail`, heartbeats, the reaper, and `OldestAge`.

**Key decisions:**
- `enqueued_at` is stored in the payload because queue *age* can't be derived from a Redis list otherwise. That makes it an assumption about the real black box.
- The counters make "zero dropped jobs" provable: once the queue drains, `enqueued_total = done_total + failed_total`.

**Verify:** `bash scripts/test-go.sh unit`.

**Label:** RUN-LOCAL (stand-in).
