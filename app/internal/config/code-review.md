# app/internal/config/ — code review

**Purpose:** reads every setting from environment variables, validates them, and reports all problems at once (`errors.Join`).

| File | What it does |
|---|---|
| `config.go` | `Load() (Config, error)`. Defaults: `PORT=8080`, `MAX_INFLIGHT=8`, `WORK_LATENCY_MS=40`, `FAULT_LATENCY_MS=0`, `SHUTDOWN_DELAY=5s`, `SHUTDOWN_TIMEOUT=20s`, `QUEUE_NAME=jobs`. `DATABASE_URL` and `REDIS_URL` are required. `MIGRATION_DATABASE_URL` falls back to `DATABASE_URL`. `FAULT_ERROR_RATE` must be within [0,1]. |
| `defaults.go` | `const FaultErrorRate = 0.0`, the compiled-in fault default. **The "bad release" demo changes only this line**, so the fault travels through the pipeline as a new image digest, exactly like a real bug. |
| `config_test.go` | Env override of the fault default, out-of-range rejection, migration-URL fallback, defaults, required variables. |

**Key decisions:**
- The fault lives in *code*, not config. A config-only fault wouldn't change the image digest, so it couldn't demonstrate digest-based promotion and rollback.
- `MIGRATION_DATABASE_URL` is separate because the advisory lock in `internal/migrate` is session-level, and PgBouncer in transaction mode can't hold one (ADR-007).

**Verify:** `bash scripts/test-go.sh unit` (5 tests in this package).

**Label:** RUN-LOCAL (stand-in).
