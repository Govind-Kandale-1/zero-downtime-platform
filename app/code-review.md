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
| `cmd/worker/` | Worker entry point: SIGTERM finishes the job in hand, then exits 0 |
| `cmd/synthetic/` | Platform tooling: constant low traffic so canary analysis always has data |
| `internal/queue/` | Reliable list queue: BLMOVE claims, ack/fail, heartbeats, reaper |
| `internal/worker/` | Consumer loop and its stand-in-only metrics |
| `internal/migrate/` | Advisory-locked, forward-only migration runner |
| `migrations/` | Embedded SQL (`0001` creates and seeds `items`) |
| `Dockerfile` | Multi-stage build. Stage 1 (`golang:${GO_VERSION}-alpine`): `CGO_ENABLED=0`, `-trimpath`, `-ldflags "-s -w -X main.version=${VERSION}"`, with BuildKit cache mounts for the module and build caches; it builds all of `./cmd/...`. Stage 2 (`${BASE_IMAGE}` = `distroless/static-debian13:nonroot`) holds `/api`, `/worker` and `/synthetic` only. `USER 65532`, `ENTRYPOINT ["/api"]` (the worker runs via `command: ["/worker"]`). OCI labels: `source` links the GHCR package to this repo; `licenses` is proprietary. |
| `.dockerignore` | Keeps docs, `bin/` and the Dockerfile out of the build context |

**Image facts** (measured by `scripts/tests/image_smoke_test.sh`):
- About **14 MB compressed** to pull; 36.5 MB of binaries plus a ~2 MB base on disk.
- **0 vulnerabilities** in Trivy (OS packages and all three Go binaries, CRITICAL/HIGH, fixable).
- No shell or package manager, so a compromised container has nothing to work with. Debugging uses `kubectl debug` with an ephemeral container.
- **One image for API and worker** means one digest is built once, scanned once, signed once and promoted for both (ADR-014).

Each folder has its own `code-review.md` with the detail.

**Key decisions:** ADR-005 (Go, contract-only, bounded-concurrency capacity model), ADR-006 (reliable queue), ADR-007 (direct URL for migrations).

**What the stand-in proves, and what it doesn't:**
- It proves the *platform mechanisms*: probes, draining, canary analysis, autoscaling triggers, job accounting, migration ordering.
- It doesn't prove the real app's performance or behaviour. Everything the stand-in makes true is an *assumption about the black box*: SIGTERM draining, advisory-locked migrations, a separate migration URL, enqueue timestamps, idempotent jobs. The README lists these.

**Verify:**
- `bash scripts/test-go.sh unit`
- `bash scripts/test-go.sh integration` (real Postgres 18 + Valkey 9 in Docker)

**Label:** RUN-LOCAL (stand-in).
