# app/cmd/api/ — code review

**Purpose:** the API process lifecycle. All behaviour lives in `internal/`; this file wires it together.

| File | What it does |
|---|---|
| `main.go` | 1. Loads config; `Version` comes from `-ldflags`. 2. Opens a pgx pool to `DATABASE_URL` (PgBouncer) and a go-redis client. 3. **Starts serving immediately**, so `/healthz` answers during migrations. 4. Runs migrations through a separate 1-connection pool on `MIGRATION_DATABASE_URL`, retrying with backoff (1 s → 10 s). 5. Starts the readiness watcher, which pings Postgres and Valkey every 5 s and drives `/readyz`. 6. On SIGTERM: `MarkShuttingDown()` (so `/readyz` returns 503) → sleep `SHUTDOWN_DELAY` (5 s) → `http.Server.Shutdown(SHUTDOWN_TIMEOUT=20 s)`. |

**Key decisions:**
- **Serve before migrating.** A startupProbe on `/healthz` passes while `/readyz` keeps traffic away until the schema is ready. That avoids liveness kills during a long migration, and it avoids sending traffic to a half-migrated pod.
- **Retry, don't crash.** A pod that starts before its database waits with backoff instead of entering CrashLoopBackOff (plan Review Focus 5).
- **Delay before Shutdown.** Endpoint removal reaches Traefik asynchronously. Without the 5 s gap, requests already routed to the pod would hit a closed listener. The chart's `preStop: sleep 5` covers the same window from the kubelet's side.
- **Readiness tracks dependencies continuously**, not just at startup, so a lost cache takes the pod out of rotation.

**Verify:** `scripts/tests/image_smoke_test.sh` (Task 4) exercises this end to end: readiness, a request, and a graceful stop with exit code 0.

**Label:** RUN-LOCAL (stand-in).
