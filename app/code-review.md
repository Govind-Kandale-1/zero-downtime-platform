# app/ — code review

**Purpose:** a *minimal stand-in* for the black-box application, which the brief describes but doesn't provide. It implements only the contract:
- API on :8080 with `/healthz`, `/readyz` and `/metrics`;
- a worker consuming a Redis-protocol queue;
- Postgres migrations at startup.

It adds two stand-in-only knobs: a capacity model (`MAX_INFLIGHT` / `WORK_LATENCY_MS`) and fault injection (`FAULT_ERROR_RATE`).

| Path | What it is |
|---|---|
| `go.mod` | Module `github.com/Govind-Kandale-1/zero-downtime-platform/app`. Dependencies: pgx v5, go-redis v9, client_golang; miniredis for tests only. |
| `cmd/api/` | API entry point: startup, migrations, readiness, graceful shutdown |
| `internal/config/` | Environment → `Config`; the compiled-in fault default |
| `internal/httpapi/` | Routes, queueing limiter, metrics, fault injection |
| `internal/queue/` | Reliable list queue (enqueue now; claim/ack/reap arrive with the worker) |
| `internal/migrate/` | Advisory-locked, forward-only migration runner |
| `migrations/` | Embedded SQL (`0001` creates and seeds `items`) |

Each folder has its own `code-review.md` with the detail.

**Key decisions:** ADR-005 (Go, contract-only, bounded-concurrency capacity model), ADR-006 (reliable queue), ADR-007 (direct URL for migrations).

**What the stand-in proves, and what it doesn't:**
- It proves the *platform mechanisms*: probes, draining, canary analysis, autoscaling triggers, job accounting, migration ordering.
- It doesn't prove the real app's performance or behaviour. Everything the stand-in makes true is an *assumption about the black box*: SIGTERM draining, advisory-locked migrations, a separate migration URL, enqueue timestamps, idempotent jobs. The README lists these.

**Verify:**
- `bash scripts/test-go.sh unit`
- `bash scripts/test-go.sh integration` (real Postgres 18 + Valkey 9 in Docker)

**Label:** RUN-LOCAL (stand-in).
