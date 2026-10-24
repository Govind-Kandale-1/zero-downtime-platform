# Zero-Downtime Platform — P0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the P0 tier of the design. That means a local kind platform, reached from an empty laptop with one command, that deploys a stand-in API and worker through a build-once, signed, digest-promoted, metric-gated pipeline. It should do canary releases with automatic rollback, autoscale with KEDA, and produce evidence items 1–4 and 8. All learning documentation is written at full depth.

**Architecture:** Terraform provider layer (kind, CNPG, Valkey, OpenBao, pg state backend) → Argo CD platform layer (Traefik, Argo Rollouts, kube-prometheus-stack, KEDA, ESO, synthetic traffic) → one Helm chart for every stack. GitHub Actions builds, scans, signs and publishes image and chart, then commits release files. A self-hosted runner on the laptop runs the read-only gates between stages. AWS Terraform is written and statically validated only.

**Tech Stack:**
- Go: pgx v5, go-redis v9, client_golang, miniredis.
- Terraform: `tehcyx/kind`, `hashicorp/helm` v3, `hashicorp/kubernetes`, `alekc/kubectl`, `hashicorp/vault`, `hashicorp/random`, `terraform-aws-modules`.
- Cluster: Argo CD, Argo Rollouts, Traefik v3, KEDA, External Secrets Operator, CloudNativePG, OpenBao, kube-prometheus-stack.
- CI and tooling: GitHub Actions, Trivy, Cosign, k6, conftest, kubeconform, tflint.

**Spec:** `docs/superpowers/specs/2026-10-25-zero-downtime-platform-design.md` (approved 2026-10-25). Read it before any task. Section numbers below (§) refer to it.

## Global Constraints

- Repo: `Govind-Kandale-1/zero-downtime-platform`, **public**. Root `LICENSE` text is the user's exact proprietary notice: never edit it, never add an OSI licence, never pass `--license` to `gh repo create`.
- Image: `ghcr.io/govind-kandale-1/zero-downtime-platform`. Chart: `oci://ghcr.io/govind-kandale-1/charts/app`. Go module: `github.com/Govind-Kandale-1/zero-downtime-platform/app`. GHCR paths must be lowercase.
- Every result and README row carries one label: `RUN-LOCAL`, `RUN-LOCAL (stand-in)`, `NOT RUN (static validation only)` or `DESCRIBED`.
- Host is Windows 11. Scripts are bash run from **Git Bash** (`C:\Program Files\Git\bin\bash.exe`), not WSL's `bash.exe`. Every `docker run` that mounts a host path sets `MSYS_NO_PATHCONV=1`. `.gitattributes` forces LF line endings.
- Tools not installed natively (go, jq, yq, conftest, kubeconform, trivy, tflint, k6) run through `scripts/lib/tools.sh` wrappers using pinned Docker images. CI installs them natively.
- All versions are pinned exactly in `config/versions.env` (images, charts, providers) or by commit SHA for GitHub Actions. Use current stable releases resolved in Task 1, not versions remembered from training.
- The Docker VM has ~9.7 GB and 12 CPUs. Total pod memory **requests** must be ≤ 6.5 GB at the 15x peak.
- Names (used everywhere):
  - kind cluster `zdp`.
  - Stacks: `dev`, `staging`, `prod` (env, namespaces `app-<name>`); `acme`, `globex` (dedicated, namespaces `tenant-<name>`); `initech` (shared tenant on `app-prod`).
  - Release stages: `dev`, `staging`, `prod-ring0`, `ring1`, `ring2`.
  - Hosts: `<stack>.localtest.me`, `initech.localtest.me`, `argocd.localtest.me`, `grafana.localtest.me`.
  - Secrets path `secret/stacks/<stack>/app` with keys `DATABASE_URL`, `MIGRATION_DATABASE_URL`, `REDIS_URL`. ClusterSecretStore `platform-secrets`.
- Every task that creates a code/config folder writes that folder's `code-review.md`. The format is §14: purpose, each file, key decisions with ADR links, how to verify, limitations, label; about 40 lines. The task also appends its ADRs to `decisions.md` using the ADR IDs assigned below, and its interview entries to `questions-answers.md`.
- Commit after every task. Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## ADR ID allocation (so tasks never collide)

| ID | Decision | Task |
|---|---|---|
| ADR-001 | Local kind is the only executed target; AWS statically validated (accepted gap vs "two targets") | 1 |
| ADR-002 | Proprietary evaluation-only LICENSE (MIT/Apache rejected) | 1 |
| ADR-003 | Three-layer IaC with a provider contract | 1 |
| ADR-020 | Public repo; ruleset with deploy-key bypass for release commits | 1 |
| ADR-021 | Docker-wrapped toolchain on the Windows host | 1 |
| ADR-024 | Load interpretation: 20k jobs/h is the peak rate; 10 s mean job | 1 |
| ADR-005 | Stand-in in Go, contract-only, bounded-concurrency capacity model | 2 |
| ADR-006 | Reliable queue (BLMOVE + heartbeat reaper), at-least-once | 3 |
| ADR-004 | Terraform; `pg` backend locally, S3 `use_lockfile` on AWS | 5 |
| ADR-007 | CloudNativePG + PgBouncer transaction mode + direct migration URL | 6 |
| ADR-008 | Valkey instead of Redis | 6 |
| ADR-009 | OpenBao + External Secrets Operator as the secrets interface | 6 |
| ADR-010 | GitOps pull with Argo CD: app-of-apps + ApplicationSets | 7 |
| ADR-016 | Synthetic traffic so canary analysis is never inconclusive | 8 |
| ADR-011 | API canary with Argo Rollouts + Traefik; edge metrics as SLIs | 9 |
| ADR-012 | Worker gated rolling (replica-weighted Rollouts canary) | 9 |
| ADR-013 | KEDA for API (Prometheus RPS) and worker (list length) | 9 |
| ADR-018 | Expand/contract + PreSync backup; rollback-after-migration policy | 9 |
| ADR-023 | SLOs + multi-window burn-rate alerts on Traefik SLIs | 9 |
| ADR-017 | Dedicated tenant = namespace + own data services on a shared cluster | 10 |
| ADR-014 | Supply chain: GHCR, Trivy, keyless Cosign, SBOM attestation; chart promoted as OCI | 12 |
| ADR-015 | Promotion by digest via release files; gates on a self-hosted runner (Kargo rejected) | 13 |
| ADR-022 | AWS reference implementation on terraform-aws-modules (NOT RUN) | 15 |
| ADR-019 | Backups: pg_dump locally / RDS PITR on AWS; scripted restore test | 17 |

## Review Focus

1. **Windows path/line-ending breakage.** A script that works in CI but fails from Git Bash because of CRLF or MSYS path mangling of `docker -v` mounts. Expected: identical behaviour on both. Pinned by Task 1, `scripts/tests/eol_test.sh` (every tracked `*.sh|*.yaml|*.tf|*.go` is LF), and by CI running `shellcheck scripts/**/*.sh`.
2. **Docker VM memory exhaustion during the 15x test.** OOM kills masquerade as app errors. Expected: a preflight refuses to start the test without headroom. Pinned by Task 16, `scripts/preflight-load.sh`: sums pod requests vs node allocatable, exits 1 above 6.5 GB, and scales non-prod stacks to minimum first.
3. **A gate that hangs.** No traffic, or Argo CD never syncs. Expected: the gate fails within `GATE_TIMEOUT` (default 900 s) and prints which check failed. Pinned by Task 13, `scripts/tests/gate_test.sh` running `gate.sh` against stubbed `kubectl` responses for "never healthy", "wrong digest" and "SLI breach".
4. **Release-file push races.** Two pipeline runs, or a human commit, hit main at once. Expected: promotions serialize and a non-fast-forward push retries after a rebase. Pinned by the `concurrency: release` group (Task 13) and by Task 11's `scripts/tests/bump_release_test.sh`, which runs `bump-release.sh` against a diverged bare repo and asserts both commits land.
5. **First-sync ordering.** App pods start before their ExternalSecret or database exists. Expected: pods wait without crash-looping long, and the PreSync backup hook exits 0 with "no database yet". Pinned by Task 9 render tests (`envFrom.secretRef.optional: true` on the hook; `/readyz` failing until Postgres is reachable) and by the Task 14 bring-up check that all Applications are Healthy within 15 min of `up.sh`.

---

### Task 1: Repository foundation and GitHub repo

**Files:**
- Create: `.gitignore` (`.local/`, `*.tfstate*`, `.terraform/`, `evidence/**/tmp/`, `app/bin/`)
- Create: `.gitattributes` (`* text=auto eol=lf`; `*.png binary`; `*.pdf binary`)
- Create: `config/platform.env` (`GITHUB_OWNER=Govind-Kandale-1`, `GITHUB_REPO=zero-downtime-platform`, `GHCR_OWNER=govind-kandale-1`, `IMAGE=ghcr.io/govind-kandale-1/zero-downtime-platform`, `CHART_REPO=oci://ghcr.io/govind-kandale-1/charts`, `COSIGN_IDENTITY_REGEX=^https://github.com/Govind-Kandale-1/zero-downtime-platform/.github/workflows/release.yml@refs/heads/main$`, `COSIGN_ISSUER=https://token.actions.githubusercontent.com`, `KIND_CLUSTER=zdp`)
- Create: `config/versions.env` (every pinned version; resolved in Step 2)
- Create: `scripts/lib/tools.sh`, `scripts/lib/common.sh`, `scripts/tests/eol_test.sh`, `scripts/code-review.md`
- Create: `README.md` (skeleton: one-paragraph intent, label legend, prerequisites, "Quickstart: coming in Task 14", link to LICENSE)
- Create: `decisions.md` (ADR template + ADR-001, 002, 003, 020, 021, 024)
- Create: `questions-answers.md` (sections mirror spec Appendix A items 1–11; first entries for this task's ADRs)
- Keep: `LICENSE` (unchanged), `docs/superpowers/**`

**Interfaces:**
- Produces: `scripts/lib/common.sh`:
  - `load_config` sources both env files;
  - `log <msg>`;
  - `die <msg>`;
  - `require <cmd>`;
  - `repo_root`.
- Produces: `scripts/lib/tools.sh`. Each of these functions prefers the native binary, else runs the pinned image with the repo mounted at `/work`:
  - `tool_go <args>` (Go module cache in Docker volume `zdp-gomod`);
  - `tool_yq`, `tool_jq`, `tool_conftest`, `tool_kubeconform`, `tool_trivy`, `tool_tflint`, `tool_k6`.

- [ ] **Step 1: Write `scripts/tests/eol_test.sh`.** It runs `git ls-files --eol` and fails, listing offenders, if any `*.sh|*.yaml|*.yml|*.tf|*.go|*.md` file has `i/crlf` or `w/crlf`.
- [ ] **Step 2: Resolve current stable versions.** Use `docker run --rm <image> --version`, `helm search repo <chart> --versions | head -2` after `helm repo add`, the Terraform registry pages, and GitHub releases via `gh release view -R <repo>`. Do this for: golang, alpine/distroless, postgres client, CNPG operator chart + PG image, Valkey, redis_exporter, OpenBao chart, Argo CD chart, Argo Rollouts chart, Traefik chart, kube-prometheus-stack, KEDA, ESO, metrics-server, k6, Trivy, Cosign, conftest, kubeconform, tflint, the kind node image matching kind 0.30, and each Terraform provider. Write them to `config/versions.env` as `NAME_VERSION=x.y.z` lines with a dated comment header.
- [ ] **Step 3: Write `scripts/lib/*.sh`, the root docs and the config files** listed above. ADR format in `decisions.md`: `## ADR-NNN: Title` → Date · Status · Label → Context → Decision → Rejected alternatives (bullets, each with a reason) → Consequences.
- [ ] **Step 4: `git init -b main`, add everything, then run `bash scripts/tests/eol_test.sh`.** Expected: `OK: all text files LF`.
- [ ] **Step 5: Commit** with `chore: repository foundation, licence, decision log`.
- [ ] **Step 6: Create and push the repo:** `gh repo create Govind-Kandale-1/zero-downtime-platform --public --source . --remote origin --push --description "Cloud-agnostic zero-downtime deployment platform (interview evaluation only, all rights reserved)"`. Verify: `gh repo view --json visibility,url` shows `PUBLIC`, and `git diff origin/main -- LICENSE` is empty.
- [ ] **Step 7: Configure the repo with `gh api`.**
  - Require approval for all outside-collaborator fork PR workflows: `PUT /repos/{o}/{r}/actions/permissions/fork-pr-contributor-approval` with `approval_policy=all_external_contributors`. Verify the endpoint exists; if it doesn't, record the one-time UI step in the README "manual steps" list.
  - Create environment `production` with required reviewer = the owner's user id and `prevent_self_review=false`.
  - The `main` ruleset is created in Task 12, once CI check names exist.

---

### Task 2: Stand-in API

**Files:**
- Create: `app/go.mod`, `app/internal/config/config.go`, `app/internal/config/defaults.go`
- Create: `app/internal/migrate/migrate.go`, `app/migrations/0001_create_items.sql`, `app/migrations/embed.go`
- Create: `app/internal/httpapi/server.go`, `app/internal/httpapi/limiter.go`, `app/internal/httpapi/metrics.go`, `app/internal/httpapi/fault.go`
- Create: `app/internal/queue/queue.go`. Only `Job`, `New` and `Enqueue` are created here; Task 3 extends it.
- Create: `app/cmd/api/main.go`
- Test: `app/internal/httpapi/server_test.go`, `app/internal/httpapi/limiter_test.go`, `app/internal/config/config_test.go`, `app/internal/queue/enqueue_test.go` (miniredis), `app/internal/migrate/migrate_integration_test.go` (build tag `integration`)
- Create: `scripts/test-go.sh` (`unit` → `tool_go test ./...`; `integration` → starts `postgres` + `valkey` containers on Docker network `zdp-test`, then runs `go test -tags integration ./...` in a container on that network with `TEST_DATABASE_URL`/`TEST_REDIS_URL`)
- Create: `app/code-review.md`

**Interfaces:**
- Produces: `config.Load() (Config, error)`.
  - Fields:
    - `Port int` (8080)
    - `DatabaseURL`
    - `MigrationDatabaseURL` (falls back to DatabaseURL)
    - `RedisURL string`
    - `MaxInflight int` (8)
    - `WorkLatency time.Duration` (40ms)
    - `FaultErrorRate float64` (env `FAULT_ERROR_RATE` else `defaults.FaultErrorRate`)
    - `FaultLatency time.Duration` (0)
    - `ShutdownDelay` (5s)
    - `ShutdownTimeout` (20s)
    - `QueueName string` ("jobs")
    - `Version string`
  - `defaults.go` holds `const FaultErrorRate = 0.0`. **The bad-release commit in Task 17 changes only this line.**
- Produces: `migrate.Run(ctx context.Context, db *pgxpool.Pool, migrations fs.FS) (applied []string, err error)`. It takes `pg_advisory_lock(727274)`, creates `schema_migrations(version text primary key, applied_at timestamptz)`, applies `NNNN_*.sql` files in order inside one transaction each, skips versions already applied, and tolerates applied versions that are missing from the FS.
- Produces: `queue.Job{ID string; EnqueuedAt time.Time; DurationMS int}` (JSON `id`, `enqueued_at`, `duration_ms`), `queue.New(rdb *redis.Client, name string, workerID string) *Queue` and `(*Queue).Enqueue(ctx, Job) error` (LPUSH `jobs` + INCR `jobs:enqueued_total`).
- Produces: `httpapi.New(cfg config.Config, deps Deps) *Server` with `Deps{DB Querier; Queue Enqueuer}`.
  - `Querier` is `QueryRow(ctx, sql string, args ...any) pgx.Row`.
  - `Enqueuer` is `Enqueue(ctx, queue.Job) error`, defined in `httpapi` so tests can fake it.
  - Methods: `Handler() http.Handler`, `MarkShuttingDown()`, `SetReady(bool)`.
- Routes:
  - `GET /healthz` → 200 `ok`.
  - `GET /readyz` → 200 only when ready and not shutting down, else 503.
  - `GET /metrics`.
  - `GET /api/items/{id}` → the limiter applies, sleeps `WorkLatency`, runs `SELECT id,name FROM items WHERE id=$1`, returns JSON, 404 if absent.
  - `POST /api/jobs` with body `{"duration_ms":int}` → 202 `{"id":...}`.
  - `GET /version` → `{"version":...}`.
- Metrics:
  - `http_requests_total{route,code}`;
  - `http_request_duration_seconds{route}` with buckets `0.05,0.1,0.2,0.3,0.4,0.5,1,2.5,5`;
  - `http_inflight_requests`.
- Produces: `httpapi.NewLimiter(n int) *Limiter`, `(*Limiter).Wrap(http.Handler) http.Handler`. This is a semaphore that *queues* callers until the request context is done; it does not reject.

- [ ] **Step 1: Write failing unit tests.**
  - `TestReadyzReflectsShutdown`: SetReady(true) → 200; MarkShuttingDown() → 503.
  - `TestHealthzAlwaysOK`.
  - `TestFaultRateOneReturns500` (FaultErrorRate=1 → `/api/items/1` returns 500).
  - `TestFaultRateZeroNeverErrors` (100 calls, 0 × 5xx, fake Querier).
  - `TestLimiterSerializesBeyondCapacity`: n=1, two concurrent 50 ms handlers, total elapsed ≥ 100 ms.
  - `TestLimiterReleasesOnContextCancel`.
  - `TestConfigFaultEnvOverridesDefault`.
  - `TestConfigMigrationURLFallsBack`.
  - `TestMetricsExposeLatencyBucket04`: `/metrics` body contains `le="0.4"`.
  - `TestEnqueueLPushesAndCounts`: after `Enqueue`, `LLEN jobs`=1, `jobs:enqueued_total`=1, and the payload has a non-zero `enqueued_at`.
- [ ] **Step 2: Run `bash scripts/test-go.sh unit`.** Expected: FAIL (packages/functions undefined).
- [ ] **Step 3: Implement config, httpapi and limiter as specified.** `cmd/api/main.go`:
  1. load config;
  2. pgxpool to `DatabaseURL`, plus a separate single-connection pool to `MigrationDatabaseURL`;
  3. `migrate.Run`;
  4. `SetReady(true)` once Postgres and Valkey ping;
  5. SIGTERM → `MarkShuttingDown()` → sleep `ShutdownDelay` → `srv.Shutdown(ShutdownTimeout)`.

  Version comes from `-ldflags "-X main.version=…"`.
- [ ] **Step 4: Run `bash scripts/test-go.sh unit`.** Expected: PASS.
- [ ] **Step 5: Write `TestMigrateIsIdempotentAndLocked` (integration).** Two goroutines call `Run` concurrently on a fresh DB; both succeed; `schema_migrations` has exactly the `0001` row; `items` has the seed rows. Write `0001_create_items.sql`: `items(id int primary key, name text not null)` seeded with ids 1–1000.
- [ ] **Step 6: Run `bash scripts/test-go.sh integration`.** Expected: PASS.
- [ ] **Step 7: Write `app/code-review.md`, ADR-005 and the Q&A entries** ("Why Go?", "What does the stand-in prove and not prove?", "Why a queueing limiter instead of CPU burn?"). Commit with `feat(app): stand-in API with startup migrations and bounded concurrency`.

---

### Task 3: Stand-in worker, queue and synthetic-traffic tool

**Files:**
- Modify: `app/internal/queue/queue.go` (add the methods below)
- Create: `app/internal/queue/reaper.go`, `app/internal/worker/worker.go`, `app/internal/worker/metrics.go`
- Create: `app/cmd/worker/main.go`, `app/cmd/synthetic/main.go`
- Test: `app/internal/queue/queue_test.go`, `app/internal/queue/reaper_test.go`, `app/internal/worker/worker_test.go` (all using miniredis), `app/cmd/synthetic/targets_test.go`

**Interfaces:**
- Consumes: `queue.Job`, `queue.New` and `Enqueue` from Task 2.
- Produces: `*Queue` methods:
  - `Claim(ctx, timeout time.Duration) (*Job, error)`: BLMOVE `jobs` → `jobs:processing:<workerID>`, RIGHT LEFT; nil on timeout.
  - `Ack(ctx, *Job) error`: LREM processing, INCR `jobs:done_total`.
  - `Fail(ctx, *Job) error`: move to `jobs:failed`, INCR `jobs:failed_total`.
  - `Heartbeat(ctx, ttl time.Duration) error`: SET `worker:hb:<workerID>` with EX.
  - `OldestAge(ctx) (time.Duration, error)`: LINDEX `jobs` -1.
  - `Depth(ctx) (int64, error)`.
- Produces: `queue.Reap(ctx, rdb, name string, lockTTL time.Duration) (requeued int, err error)`. It takes `SET jobs:reaper-lock NX EX`, scans `jobs:processing:*`, and for each list whose `worker:hb:<id>` is missing RPOPLPUSHes every item back to `jobs`.
- Produces: `worker.Run(ctx, q *queue.Queue, cfg Config) error`.
  - Loop: Claim (2 s timeout) → sleep `DurationMS` → Ack, or Fail if the job is malformed.
  - On ctx cancel: stop claiming, finish the in-flight job, return.
  - The heartbeat runs every 10 s with a 30 s TTL. The reaper runs every 15 s.
  - Metrics on `:9090`: `jobs_processed_total{result}`, `job_duration_seconds`, `queue_oldest_job_age_seconds`, `queue_depth`.
- Produces: `cmd/synthetic`.
  - Env: `TRAFFIC_TARGET` (default `http://traefik.traefik.svc`), `HOSTS` (comma list), `RPS_PER_HOST` (10), `JOB_EVERY` (10s).
  - Sends `GET /api/items/{rand 1..1000}` with `Host: <host>` and `X-Synthetic: 1`, plus `POST /api/jobs {"duration_ms":2000}` every `JOB_EVERY` per host.
  - Exposes `synthetic_requests_total{host,code}` on `:9090`.
  - Labelled **platform tooling**, not part of the black-box contract.

- [ ] **Step 1: Write failing tests.**
  - `TestClaimMovesToProcessingList`.
  - `TestAckRemovesAndCounts`.
  - `TestOldestAgeReadsTail`.
  - `TestReapRequeuesDeadWorkerOnly`: two processing lists, one heartbeat alive; only the dead list is requeued.
  - `TestReapSingleLeader`: the second concurrent Reap returns 0.
  - `TestWorkerFinishesInflightJobOnCancel`: cancel mid-job; the job is acked, not left in processing.
  - `TestWorkerStopsClaimingAfterCancel`.
  - `TestAccountingInvariant`: enqueue 50 and run 3 workers to completion; `enqueued_total == done_total + failed_total` and all lists are empty.
  - `TestSyntheticParsesHosts`.
- [ ] **Step 2: Run `bash scripts/test-go.sh unit`.** Expected: FAIL.
- [ ] **Step 3: Implement the queue, reaper, worker, the worker main** (SIGTERM → cancel ctx; exit 0 once the in-flight job is done), and synthetic.
- [ ] **Step 4: Run `bash scripts/test-go.sh unit`.** Expected: PASS. Run `bash scripts/test-go.sh integration` (the queue against real Valkey). Expected: PASS.
- [ ] **Step 5: Update `app/code-review.md`, add ADR-006 and the Q&A entries** ("What happens to a job when a worker is killed?", "Is it exactly-once?", "How do you measure queue age on a black box?"). Commit with `feat(app): reliable-queue worker and synthetic traffic tool`.

---

### Task 4: Container image

**Files:**
- Create: `app/Dockerfile`: multi-stage; `golang:<GO_VERSION>` build with `CGO_ENABLED=0`, `-trimpath`, `-ldflags "-s -w -X main.version=${VERSION}"` → `gcr.io/distroless/static-debian12:nonroot`. Binaries are `/api`, `/worker` and `/synthetic`; there is no default ENTRYPOINT beyond `/api`. Uses `USER 65532`. Labels: `org.opencontainers.image.source=https://github.com/Govind-Kandale-1/zero-downtime-platform`.
- Create: `app/.dockerignore`
- Create: `scripts/tests/image_smoke_test.sh`

- [ ] **Step 1: Write `image_smoke_test.sh`.**
  1. Build the image as `zdp-app:test`.
  2. Start postgres and valkey on the `zdp-test` network.
  3. Run the API container.
  4. Assert: `curl /healthz` = 200; `/readyz` = 200 within 20 s; `/api/items/7` returns `"id":7`; `POST /api/jobs` = 202.
  5. Run the worker container and assert `jobs:done_total` reaches 1 within 10 s.
  6. Assert `docker stop` of the API exits within 30 s, with exit code 0.
  7. Assert the image is < 40 MB.
- [ ] **Step 2: Run it.** Expected: FAIL (no Dockerfile).
- [ ] **Step 3: Write the Dockerfile.**
- [ ] **Step 4: Run `bash scripts/tests/image_smoke_test.sh`.** Expected: `PASS` lines for all checks.
- [ ] **Step 5: Run `tool_trivy image --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 zdp-app:test`.** Expected: exit 0.
- [ ] **Step 6: Update `app/code-review.md` (Dockerfile section). Commit** with `feat(app): distroless multi-binary image`.

---

### Task 5: State backend and local cluster (provider layer, part 1)

**Files:**
- Create: `scripts/state-up.sh`. It starts `zdp-tfstate` (`postgres:<PG_VERSION>-alpine`, port `127.0.0.1:5433`, volume `zdp-tfstate`, password generated once into `.local/tfstate.env`). It is idempotent and attaches the container to the `kind` Docker network once that exists.
- Create: `infra/modules/local/kind-cluster/{main.tf,variables.tf,outputs.tf,versions.tf}`
- Create: `infra/live/local/10-cluster/{main.tf,backend.tf,outputs.tf,versions.tf}`
- Create: `infra/code-review.md`, `infra/modules/local/kind-cluster/code-review.md`, `infra/live/local/code-review.md`

**Interfaces:**
- Produces: module `kind-cluster`.
  - Inputs: `name` ("zdp"), `node_image`, `workers` (2).
  - Outputs: `kubeconfig_path`, `endpoint`, `cluster_ca_certificate`, `client_certificate`, `client_key`.
  - Port mappings: on the control-plane node, `30080→80`, `30443→443`, `30200→8200` (`listenAddress 127.0.0.1`).
- Produces: backend config `backend "pg" { schema_name = "local_10_cluster" }`, with the connection string supplied by `PG_CONN_STR` from `.local/tfstate.env`. Later roots use `local_20_data` and `local_30_gitops`. They read upstream outputs with `terraform_remote_state` (backend `pg`, same conn string, upstream schema).

- [ ] **Step 1: Run `terraform -chdir=infra/live/local/10-cluster init && terraform validate`.** Expected: FAIL (no files).
- [ ] **Step 2: Write the module and root.** Set `kubeconfig_path` to `${path.root}/../../../../.local/kubeconfig`.
- [ ] **Step 3: Run `bash scripts/state-up.sh && source .local/tfstate.env && terraform -chdir=infra/live/local/10-cluster init && terraform -chdir=infra/live/local/10-cluster apply -auto-approve`.** Expected: `kubectl --kubeconfig .local/kubeconfig get nodes` shows 3 nodes Ready.
- [ ] **Step 4: Verify the state is remote.** Run `docker exec zdp-tfstate psql -U tfstate -c "select name from local_10_cluster.states"`. Expected: one row `default`.
- [ ] **Step 5: Write the code-review files and ADR-004.** Its rejected alternatives: OpenTofu (equivalent; Terraform already installed and more commonly asked about), Pulumi, Crossplane; for local state, MinIO/S3 emulation and the kubernetes backend (chicken-and-egg). Add Q&A ("Where is state and how is it locked?", "What's the chicken-and-egg with remote state?"). Commit with `feat(infra): pg state backend and kind cluster`.

---

### Task 6: Local data services and secrets (provider layer, part 2)

**Files:**
- Create: `gitops/stacks/{dev,staging,prod}.yaml`. These are stack descriptors **and** Helm values:
  - top-level `stack: {name, namespace, release, residency: eu, region: eu-central-1, size, slo}`;
  - `dev`/`staging` use `size: tiny`, `slo: "99.9"`;
  - `prod` uses `size: small`, `slo: "99.9"`.
- Create: `tenants/acme.yaml` (`tier: dedicated, residency: eu, region: eu-central-1, ring: 1, size: small, slo: "99.95"`), `tenants/globex.yaml` (`dedicated, residency: us, region: us-east-1, ring: 2, small, "99.95"`), `tenants/initech.yaml` (`tier: shared, residency: eu, region: eu-central-1, slo: "99.9"`)
- Create: `infra/modules/local/data-operators/` (CNPG operator, OpenBao dev mode with NodePort 30200 and root token `root`, both via `helm_release`)
- Create: `infra/modules/local/stack-data/` (one per stack: namespace with labels `zdp/stack, zdp/tier, zdp/residency, zdp/region`; CNPG `Cluster` 1 instance with storage 1Gi; CNPG `Pooler` `pgbouncer`, transaction mode, 1 instance; Valkey StatefulSet with `appendonly yes`, 1Gi PVC, and a `redis_exporter` sidecar with `--check-keys=jobs`; the OpenBao KV secret)
- Create: `infra/live/local/20-data/{main.tf,backend.tf,versions.tf,locals.tf}`
- Create: code-review.md for both modules and update `infra/live/local/code-review.md`

**Interfaces:**
- Consumes: Task 5 remote-state outputs (cluster credentials).
- Produces: for each stack in `local.stacks`, the contract items of spec §6.1.
  - `local.stacks` = every `gitops/stacks/*.yaml` `stack` block, plus every `tenants/*.yaml` with `tier == "dedicated"` (namespace `tenant-<name>`).
  - Postgres service `<stack>-pg-rw.<ns>.svc:5432`.
  - PgBouncer `pgbouncer.<ns>.svc:5432`.
  - Valkey `valkey.<ns>.svc:6379`.
  - OpenBao secret `secret/stacks/<stack>/app`:
    - `DATABASE_URL=postgres://app:<pw>@pgbouncer.<ns>.svc:5432/app?sslmode=disable`;
    - `MIGRATION_DATABASE_URL=postgres://app:<pw>@<stack>-pg-rw.<ns>.svc:5432/app?sslmode=disable`;
    - `REDIS_URL=redis://valkey.<ns>.svc:6379/0`.
  - The password is a `random_password` per stack. It is also written as the CNPG `bootstrap.initdb.secret` Kubernetes secret `<stack>-pg-app`.
- Produces: `external-secrets/openbao-token` secret (`token=root`) for the ClusterSecretStore in Task 8.
- Use `alekc/kubectl` `kubectl_manifest` for CNPG CRs so plan does not need CRDs. Add `depends_on` on the operator release.

- [ ] **Step 1: Write `infra/live/local/20-data/tests/contract_test.sh`.** For every stack namespace, it asserts:
  - the CNPG cluster reports `Cluster in healthy state`;
  - the Pooler deployment is Available;
  - `valkey-0` is Ready;
  - `kubectl exec valkey-0 -- valkey-cli CONFIG GET appendonly` = `yes`;
  - `bao kv get secret/stacks/<stack>/app` (via `kubectl exec` into openbao-0, token root) shows all three keys;
  - a throwaway `postgres` pod can `psql "$DATABASE_URL" -c 'select 1'` through PgBouncer.
- [ ] **Step 2: Run it.** Expected: FAIL (no namespaces).
- [ ] **Step 3: Write the modules and the root.** Resource presets by size, as requests: `tiny` PG 128Mi / Valkey 32Mi; `small` PG 256Mi / Valkey 48Mi.
- [ ] **Step 4: Run `terraform -chdir=infra/live/local/20-data init && apply -auto-approve`, then `bash infra/live/local/20-data/tests/contract_test.sh`.** Expected: all `PASS`, for 5 stacks (dev, staging, prod, acme, globex).
- [ ] **Step 5: Write code-review files and ADR-007, 008, 009.** ADR-007 must explain the advisory-lock/transaction-mode trap. ADR-008 rejects Redis OSS on licence grounds; note ElastiCache supports Valkey and is cheaper. ADR-009 rejects SOPS, Sealed Secrets and plain Secrets. Add Q&A for each. Commit with `feat(infra): per-stack Postgres+PgBouncer, Valkey, OpenBao secrets`.

---

### Task 7: GitOps bootstrap (Argo CD)

**Files:**
- Create: `infra/live/local/30-gitops/{main.tf,backend.tf,versions.tf,values-argocd.yaml}`
- Create: `gitops/clusters/local/root.yaml` (root Application → `gitops/clusters/local/apps/`, recurse, automated + selfHeal + prune)
- Create: `gitops/clusters/local/apps/README` placeholder deleted in Task 8; `gitops/code-review.md`, `infra/live/local/30-gitops/code-review.md`

**Interfaces:**
- Produces: Argo CD in namespace `argocd`.
  - `server.insecure=true`; dex and notifications disabled.
  - `configs.cm."timeout.reconciliation"=60s`.
  - Repository secret for `ghcr.io/govind-kandale-1/charts` with `type: helm`, `enableOCI: "true"`. Public, so no credentials.
  - Git repo `https://github.com/Govind-Kandale-1/zero-downtime-platform.git` (public, no credentials).
  - The root Application is applied with `kubectl_manifest`.

- [ ] **Step 1: Run `kubectl -n argocd get application root`.** Expected: FAIL (NotFound).
- [ ] **Step 2: Write the root module and the root Application.**
- [ ] **Step 3: Apply. Then run `kubectl -n argocd get application root -o jsonpath='{.status.sync.status}'`.** Expected: `Synced`, with an empty app list.
- [ ] **Step 4: Write ADR-010** (rejected: pipeline push with kubectl/helm from CI, because it needs cluster credentials in CI and has no drift correction; Flux, because Argo CD's UI and Rollouts integration matter for the demo). Add Q&A ("GitOps pull vs push: what does a reviewer gain?", "How is drift handled in-cluster?"). Commit and push. Commit message: `feat(gitops): Argo CD bootstrap with app-of-apps root`.

---

### Task 8: Platform layer

**Files:**
- Create: `gitops/clusters/local/apps/*.yaml`, one Application per component, with sync waves:
  - wave -2: `prometheus-operator-crds`;
  - wave -1: `traefik`, `argo-rollouts`, `keda`, `external-secrets`, `metrics-server`;
  - wave 0: `kube-prometheus-stack`, `platform-config`;
  - wave 1: `synthetic-traffic`, `stacks` + `tenants` ApplicationSets (Task 11).
- Create: `gitops/platform/values/local/{traefik,argo-rollouts,keda,external-secrets,metrics-server,kube-prometheus-stack}.yaml`
- Create: `gitops/platform/config/` (Helm-less manifests synced by `platform-config`):
  - `ClusterSecretStore platform-secrets` (vault provider, `http://openbao.openbao.svc:8200`, path `secret`, v2, token from `external-secrets/openbao-token`);
  - IngressRoutes for argocd and grafana;
  - Traefik `ServiceMonitor`;
  - the `PriorityClass` set (`platform-critical`, `app`, `overprovision`: value -10, described for AWS).
- Create: `gitops/platform/synthetic-traffic/deployment.yaml`:
  - `replicas: 0` and a placeholder image until Task 14 sets the first published digest and `replicas: 1` (updated by hand, documented);
  - `HOSTS=dev.localtest.me,staging.localtest.me,prod.localtest.me,initech.localtest.me,acme.localtest.me,globex.localtest.me`;
  - memory request 32Mi.
- Create: `gitops/platform/code-review.md`

**Interfaces:**
- Traefik values:
  - NodePort web `30080`, websecure `30443`.
  - `metrics.prometheus` with `buckets: "0.05,0.1,0.2,0.3,0.4,0.5,1,2.5,5"`, `addServicesLabels`, `addRoutersLabels`, `addEntryPointsLabels`.
  - `providers.kubernetesCRD.allowCrossNamespace: true` (needed for shared-tenant routes).
- kube-prometheus-stack: retention `12h`; Prometheus request 600Mi; `serviceMonitorSelectorNilUsesHelmValues: false` and `ruleSelectorNilUsesHelmValues: false`, so chart-created monitors and rules are picked up; Alertmanager receiver `log` (webhook to a null sink, labelled).
- metrics-server: `--kubelet-insecure-tls` (kind).
- Argo Rollouts: verify in the pinned version whether Traefik routing is native (`trafficRouting.traefik.weightedTraefikServiceName`) or needs the traffic-router plugin. Configure accordingly and record the result in `gitops/platform/code-review.md`.

- [ ] **Step 1: Write `gitops/tests/platform_test.sh`.** It asserts:
  - every Application in `argocd` is `Synced`/`Healthy`;
  - `curl -s -H 'Host: grafana.localtest.me' http://127.0.0.1/api/health` = 200;
  - the Prometheus query `up{job=~".*traefik.*"}` returns 1 (via `kubectl get --raw .../services/http:kube-prometheus-stack-prometheus:9090/proxy/api/v1/query`);
  - `kubectl get clustersecretstore platform-secrets -o jsonpath='{.status.conditions[0].status}'` = `True`;
  - `kubectl top nodes` works.
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Write the manifests and values. Commit and push.** Argo CD then syncs from GitHub.
- [ ] **Step 4: Run `bash gitops/tests/platform_test.sh`** (allow up to 10 min for first sync). Expected: all PASS. Record the platform memory requests: `kubectl get pods -A -o json | tool_jq` sum → keep ≤ 3.0 GB.
- [ ] **Step 5: Write ADR-016 and the Q&A** ("Why synthetic traffic? Doesn't it skew SLIs?" Answer: excluded by header in dashboards; useful as a black-box probe). Commit with `feat(platform): traefik, rollouts, keda, eso, prometheus, synthetic traffic`.

---

### Task 9: App chart (the one template)

**Files:**
- Create: `charts/app/Chart.yaml` (`name: app`, `version: 0.1.0`; CI overrides it), `charts/app/values.yaml`, `charts/app/values.schema.json`
- Create: `charts/app/templates/`:
  - `_helpers.tpl`;
  - `api-rollout.yaml`, `api-services.yaml` (stable, canary), `traefikservice.yaml`, `ingressroute.yaml`;
  - `analysis-api.yaml`, `analysis-worker.yaml`;
  - `worker-rollout.yaml`;
  - `scaledobject-api.yaml`, `scaledobject-worker.yaml`;
  - `pdb.yaml`, `externalsecret.yaml`, `servicemonitor.yaml`, `podmonitor-worker.yaml`;
  - `prometheusrule-slo.yaml`, `networkpolicy.yaml`, `serviceaccount.yaml`;
  - `backup-pvc.yaml`, `backup-cronjob.yaml`, `presync-backup-job.yaml`.
- Create: `charts/app/tests/render_test.sh`, `charts/app/tests/values-*.yaml` fixtures, `charts/app/code-review.md`

**Interfaces:**
- Consumes values:
  - `stack.*` (Task 6 descriptor).
  - `image.repository`, `image.digest` (release file).
  - `sizes.<size>` presets.
  - `api.{minReplicas,maxReplicas,rpsPerPod,canarySteps,pauseSeconds}`.
  - `worker.{minReplicas,maxReplicas,listLength,terminationGracePeriodSeconds}`.
  - `analysis.{successRate: 0.99, p95Seconds: 0.4, minRequests: 20, interval: 1m}`.
  - `backup.mode: pgdump|managed`.
  - `ingress.hosts`.
- Pinned values:
  - API canary steps `[10,25,50]` with pause `120s` each. `gitops/stacks/*.yaml` sets `60s` locally.
  - API `terminationGracePeriodSeconds: 30`, `preStop: sleep 5`.
  - Probes: startup `/healthz` (failureThreshold 30, period 2); readiness `/readyz`; liveness `/healthz`.
  - Worker steps `[25,50]`, pause `180s`; `terminationGracePeriodSeconds: 90`.
  - KEDA API: prometheus trigger, query `sum(rate(traefik_service_requests_total{service=~"<ns>-api-(stable|canary)-.*"}[1m]))`, threshold `api.rpsPerPod` (70 placeholder), plus a cpu trigger at 70.
  - KEDA API behaviour: scaleUp stabilization 0, policies `Percent 100/15s` and `Pods 8/15s`, `selectPolicy: Max`; scaleDown stabilization 300, `Percent 20/60s`.
  - KEDA worker: `redis` trigger `listName: jobs`, `listLength: 5`, `address` from the secret via `TriggerAuthentication`.
  - PDB `maxUnavailable: 1`.
  - `securityContext`: runAsNonRoot, readOnlyRootFilesystem, drop ALL, seccomp RuntimeDefault.
  - The ExternalSecret maps `secret/stacks/<stack>/app` → Secret `app-env`.
  - The PreSync Job uses `envFrom.secretRef.optional: true` and exits 0 when `MIGRATION_DATABASE_URL` is empty. Otherwise it runs `pg_dump -Fc` to `/backups/presync-<ts>.dump` plus a `.counts` file holding `select count(*) from items` and `select md5(string_agg(id::text||name, ',' order by id)) from items`.
  - SLO rules use `stack.slo`.
  - Recording rules:
    - `zdp:sli_availability:ratio_rate{5m,30m,1h,6h,3d}` per namespace;
    - `zdp:sli_latency_good:ratio_rate*`, computed from `le="0.4"`.
  - Alerts `ZdpErrorBudgetBurnPage` (14.4× over 1h and 5m; 6× over 6h and 30m) and `ZdpErrorBudgetBurnTicket` (1× over 3d).
  - Analysis queries use the canary Service's Traefik label `service=~"<ns>-api-canary-.*"` and exclude nothing. Synthetic traffic **is** what the analysis needs.

- [ ] **Step 1: Write `render_test.sh`.** It runs `helm template` with each fixture, then `tool_yq` assertions and `tool_kubeconform -strict -ignore-missing-schemas`, failing on the first mismatch. Assertions:
  - canary steps 10/25/50;
  - worker grace 90;
  - API preStop present;
  - `optional: true` on the PreSync secret;
  - the ScaledObject `scaleTargetRef.kind` is `Rollout` for both;
  - the PDB exists for both;
  - image is `repository@digest` (never a tag);
  - an SLO rule contains `0.9995` for an slo `99.95` fixture;
  - NetworkPolicy default-deny exists;
  - the chart fails to render without `image.digest` (values.schema.json requires it).
- [ ] **Step 2: Run `bash charts/app/tests/render_test.sh`.** Expected: FAIL.
- [ ] **Step 3: Write the templates.**
- [ ] **Step 4: Run it.** Expected: all PASS. Also `helm lint charts/app -f charts/app/tests/values-prod.yaml`: 0 failures.
- [ ] **Step 5: Write `charts/app/code-review.md` and ADR-011, 012, 013, 018, 023.**
  - ADR-011 rejects blue/green (double capacity at peak; shared schema) and plain rolling (no gate).
  - ADR-012 rejects a plain Deployment (no automatic abort) and KEDA ScaledJob (one pod per job at 5.56/s).
  - ADR-013 rejects CPU-only HPA (lags for I/O-bound work).
  - ADR-018 contains the rollback-after-migration policy text from §9.
  - ADR-023 rejects single-threshold alerts.

  Add Q&A for each, including the uncomfortable one: "What if the real app doesn't drain on SIGTERM?". Commit with `feat(chart): one template for every stack`.

---

### Task 10: Shared-tenant route chart and tenancy policy

**Files:**
- Create: `charts/tenant-route/{Chart.yaml,values.yaml,templates/ingressroute.yaml,templates/prometheusrule.yaml,code-review.md}`. It creates, in namespace `app-prod`, an IngressRoute for host `<tenant>.localtest.me` → services `api-stable`/TraefikService of the prod stack, plus per-tenant SLO alerts keyed on the Traefik **router** label.
- Create: `policy/tenants.rego`, `policy/tenants_test.rego`, `policy/code-review.md`
- Create: `tenants/code-review.md` (the schema of a tenant file and the onboarding steps)

**Interfaces:**
- `policy/tenants.rego` package `tenants` with `deny[msg]` rules:
  - `residency == "eu"` and region not in `{eu-central-1, eu-west-1, eu-west-3, eu-north-1, eu-south-1}`;
  - `tier` not in `{shared, dedicated}`;
  - dedicated without an integer `ring >= 1`;
  - `slo` not in `{"99.9","99.95"}`;
  - a `name` that doesn't match `^[a-z][a-z0-9-]{1,20}$`;
  - the file name differing from `name`.

- [ ] **Step 1: Write `tenants_test.rego`:**
  - `test_eu_tenant_in_us_region_denied`;
  - `test_eu_tenant_in_frankfurt_allowed`;
  - `test_dedicated_without_ring_denied`;
  - `test_bad_slo_denied`;
  - `test_shared_tenant_needs_no_ring`.
- [ ] **Step 2: Run `tool_conftest verify -p policy`.** Expected: FAIL.
- [ ] **Step 3: Write `tenants.rego` and the tenant-route chart.**
- [ ] **Step 4: Run `tool_conftest verify -p policy` and `tool_conftest test -p policy tenants/*.yaml`.** Expected: all pass. Also `helm template charts/tenant-route --set tenant=initech | tool_kubeconform -strict -ignore-missing-schemas`.
- [ ] **Step 5: Write ADR-017** (rejected: cluster-per-tenant as the default, because of the $73/month control plane per tenant and the upgrade burden; namespace-only isolation without dedicated data services, because of noisy neighbours and residency). Add Q&A ("How is EU residency enforced, not just documented?", "Per-tenant visibility on a shared black-box app?"). Commit with `feat(tenancy): shared-tenant routes and residency policy`.

---

### Task 11: Stack and tenant ApplicationSets, release files

**Files:**
- Create: `gitops/releases/{dev,staging,prod-ring0,ring1,ring2}.yaml` with schema `{name: <stage>, chart: {version: "0.0.0"}, image: {repository: ghcr.io/govind-kandale-1/zero-downtime-platform, digest: ""}}`. Placeholders are filled by Task 14's bootstrap.
- The `stack.release` field written in Task 6 (`dev`, `staging`, `prod-ring0`) selects each env stack's release file.
- Create: `gitops/clusters/local/apps/appset-stacks.yaml`
  - Matrix generator: git files `gitops/stacks/*.yaml` × git files `gitops/releases/{{.stack.release}}.yaml`.
  - Application `stack-{{.stack.name}}`, namespace `{{.stack.namespace}}`.
  - Sources:
    - OCI chart `app` at `{{.chart.version}}`, with valueFiles `$values/gitops/stacks/{{.stack.name}}.yaml` and `valuesObject.image` from the params;
    - git ref `values`.
  - `syncPolicy.automated`, `preserveResourcesOnDeletion: true`, `CreateNamespace=false`.
  - Applications skip rendering while `chart.version == "0.0.0"`, via a generator selector `matchExpressions: chart.version NotIn ["0.0.0"]`.
- Create: `gitops/clusters/local/apps/appset-tenants-dedicated.yaml`
  - Matrix: git files `tenants/*.yaml` (selector `tier=dedicated`) × `gitops/releases/ring{{.ring}}.yaml`.
  - Application `stack-{{.name}}`, the same naming as env stacks, so `gate.sh` treats them identically. The shared-tenant ApplicationSet names its Applications `tenant-{{.name}}`.
  - Values are built from the tenant fields (`stack.name`, `stack.namespace: tenant-{{.name}}`, `stack.slo`, `stack.size`, `stack.residency`, `stack.region`).
- Create: `gitops/clusters/local/apps/appset-tenants-shared.yaml` (git files `tenants/*.yaml`, selector `tier=shared` → chart `charts/tenant-route` from git, path-based)
- Create: `scripts/bump-release.sh <stage> <chart-version> <digest>`. It rewrites one release file with `tool_yq`, then commits `release(<stage>): chart <v> image <short-digest>`. On a non-fast-forward push it retries 5× with `git pull --rebase`.
- Test: `scripts/tests/bump_release_test.sh`

**Interfaces:**
- Produces: release-file params `chart.version`, `image.repository`, `image.digest`. Task 13 gates read the same files to know the expected digest.

- [ ] **Step 1: Write `bump_release_test.sh`.** In a temp dir: create a bare repo + two clones; clone A commits an unrelated change and pushes; clone B runs `bump-release.sh staging 0.1.7 sha256:abc…`. Assert the push succeeded, both commits are on the bare main, and `yq .image.digest` = the given digest.
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Write `bump-release.sh`, the release files and the ApplicationSets.**
- [ ] **Step 4: Run `bash scripts/tests/bump_release_test.sh`.** Expected: PASS. Commit and push. Then run `kubectl -n argocd get applicationsets`. Expected: 3 ApplicationSets with no error conditions. While the placeholders are present, the stack Applications are absent and the shared-tenant Application exists.
- [ ] **Step 5: Update `gitops/code-review.md`.** Commit with `feat(gitops): release-file driven ApplicationSets for stacks and tenants`.

---

### Task 12: CI workflow and repo ruleset

**Files:**
- Create: `.github/workflows/ci.yml`. It triggers on `pull_request` and on `push` to non-main branches. Jobs (each named exactly as listed, because the ruleset requires these names):
  - `go-test`: unit, plus integration with `services: postgres, valkey`;
  - `chart-test`: `render_test.sh`, `helm lint`;
  - `policy-test`: `conftest verify` + `test tenants`;
  - `terraform-validate`: matrix over every root under `infra/live/**` and `infra/bootstrap/aws`; `fmt -check`, `init -backend=false`, `validate`, `tflint`;
  - `iac-scan`: `trivy config infra charts`, fails on HIGH+;
  - `shell-lint`: `shellcheck scripts/**/*.sh`, `eol_test.sh`.
- Create: `.github/CODEOWNERS` (`/tenants/ @Govind-Kandale-1`, `/gitops/releases/ @Govind-Kandale-1`)
- Create: `scripts/repo-ruleset.sh`. It creates or updates ruleset `main-protection` via `gh api`:
  - target `refs/heads/main`;
  - rules: `pull_request` (1 approving review, code-owner review), `required_status_checks` (the six job names), `non_fast_forward`;
  - bypass actors: RepositoryRole admin (mode `always`) and the deploy key (`DeployKey`, `always`).
- Create: `.github/code-review.md`

- [ ] **Step 1: Push a branch with an intentionally bad tenant** (`tenants/bad.yaml`: residency eu, region us-east-1) and open a PR. Expected: `policy-test` FAILS on the PR.
- [ ] **Step 2: Remove the bad file.** Expected: all six checks pass. Merge (admin). Record both runs' URLs in `evidence/00-ci/README.md` (RUN-LOCAL/CI).
- [ ] **Step 3: Run `bash scripts/repo-ruleset.sh`.** Verify `gh api repos/{o}/{r}/rulesets` lists `main-protection` as active.
- [ ] **Step 4: Write `.github/code-review.md`, ADR-020** (solo-owner review limitation documented) and the Q&A. Commit with `ci: PR validation and main ruleset`.

---

### Task 13: Release pipeline, gates, self-hosted runner

**Files:**
- Create: `.github/workflows/release.yml`. It triggers on `push` to main for paths `app/**` and `charts/**`, and on `workflow_dispatch`. `concurrency: {group: release, cancel-in-progress: false}`; `permissions: {contents: read}`, raised per job. Jobs:
  1. `changes`: did `app/` change?
  2. `build`, only if app changed (`packages: write`): buildx push `${IMAGE}:sha-<short>`; output `digest`. Otherwise output the digest read from `gitops/releases/dev.yaml`.
  3. `scan`: Trivy on `${IMAGE}@digest`, `CRITICAL,HIGH`, `--ignore-unfixed`, exit 1; upload the SARIF.
  4. `sign` (`id-token: write`, `packages: write`): CycloneDX SBOM via Trivy → `cosign sign --yes` → `cosign attest --yes --type cyclonedx`.
  5. `chart` (`packages: write`, `id-token: write`): `helm package charts/app --version 0.1.${{ github.run_number }} --app-version <short-digest>` → `helm push` → cosign-sign the chart digest.
  6. `promote-dev`: SSH with the `GITOPS_DEPLOY_KEY` secret → `scripts/bump-release.sh dev <ver> <digest>`.
  7. `gate-dev` (`runs-on: [self-hosted, local-kind]`) → `promote-staging` → `gate-staging` → `promote-prod-ring0` (`environment: production`) → `gate-prod-ring0` → `promote-ring1` → `gate-ring1` → `promote-ring2` → `gate-ring2`. Each promote waits on the previous gate.
- Create: `scripts/gate.sh <stage> <stack...>`. For each stack:
  - it reads the expected `chart.version` and `image.digest` from `gitops/releases/<stage>.yaml`;
  - it polls (every 15 s, until `GATE_TIMEOUT`=900) and checks four things:
    1. the Application `stack-<stack>` is Synced + Healthy, at a revision that contains that release commit;
    2. Rollouts `api` and `worker` are `Healthy`, with `status.stableRS` pods whose image contains the digest;
    3. a soak of `GATE_SOAK` (180 s locally): via the API-server service proxy, error ratio < 0.005 and p95 < 0.4 over the soak window;
    4. `queue_oldest_job_age_seconds` < 120.
  - An empty or NaN Prometheus result counts as `no traffic`. It is never treated as a pass.
  - On success it prints `GATE PASS <stage>/<stack>`. On failure it prints `GATE FAIL <stage>/<stack>: <check>: <detail>` and exits 1.
- Create: `scripts/runner-up.sh`.
  - Creates SA `ci-gate` in `argocd` with ClusterRole `view` + `get` on `applications.argoproj.io`, `rollouts.argoproj.io` and `services/proxy` in `monitoring`.
  - Writes an internal-address kubeconfig (`kind get kubeconfig --internal`, token auth) to `.local/runner/kubeconfig`.
  - Fetches a registration token: `gh api -X POST repos/{o}/{r}/actions/runners/registration-token`.
  - Runs the container `zdp-runner` (`ghcr.io/actions/actions-runner:<ver>`, network `kind`, labels `self-hosted,local-kind`, the kubeconfig mounted read-only, restart `unless-stopped`).
  - Installs kubectl + yq in the container at start.
- Create: `scripts/deploy-key.sh`. It generates an ed25519 key into `.local/`, runs `gh repo deploy-key add --allow-write --title gitops-release`, then `gh secret set GITOPS_DEPLOY_KEY`.
- Test: `scripts/tests/gate_test.sh`. It puts a stub `kubectl` on `PATH` that serves canned JSON per scenario. Assertions:
  - `healthy` → exit 0, prints `GATE PASS`;
  - `never-healthy` with `GATE_TIMEOUT=5` → exit 1, `Application not Healthy`;
  - `wrong-digest` → exit 1, `digest mismatch`;
  - `sli-breach` → exit 1, `error ratio`;
  - `no-traffic` (empty vector) → exit 1, `no traffic`.

- [ ] **Step 1: Write `gate_test.sh`.** Run it. Expected: FAIL.
- [ ] **Step 2: Write `gate.sh`.** Run `bash scripts/tests/gate_test.sh`. Expected: 5 × PASS.
- [ ] **Step 3: Write `release.yml`, `runner-up.sh` and `deploy-key.sh`.** Run `bash scripts/deploy-key.sh`, then add the key to the ruleset bypass by re-running `scripts/repo-ruleset.sh`.
- [ ] **Step 4: Write `.github/code-review.md` (release section), ADR-014 and ADR-015.**
  - ADR-014 rejects key-based Cosign (key custody), Notation (smaller ecosystem) and ECR (not portable).
  - ADR-015 rejects Kargo (another control plane to learn within the time box; on the roadmap), Argo CD Image Updater (writes tags, weak gating), and gates in hosted CI (they can't see laptop metrics).

  Add Q&A: "Build once — prove it's the same artifact in prod", "Why a self-hosted runner, and isn't that risky on a public repo?", "What happens when GitHub is down?". Commit with `feat(ci): build-once signed release with metric-gated promotion`. Do **not** push yet. Task 14 performs the first run deliberately.

---

### Task 14: One-command bring-up and first end-to-end release

**Files:**
- Create: `scripts/up.sh`. Steps:
  1. preflight (docker, kind, terraform, helm, kubectl, gh auth; Docker memory ≥ 9 GB, else a warning);
  2. `state-up.sh`;
  3. apply 10 → 20 → 30;
  4. wait for the platform (`gitops/tests/platform_test.sh`);
  5. `runner-up.sh` (skipped with `--no-runner`).

  It prints the URLs.
- Create: `scripts/down.sh` (destroys 30 → 20 → 10, stops runner and state container; `--purge` also removes the state volume).
- Create: `scripts/seed-releases.sh`. A one-time bootstrap that copies `dev.yaml`'s chart+digest into `staging`, `prod-ring0`, `ring1` and `ring2` via `bump-release.sh`. It is documented as the only out-of-pipeline promotion.
- Modify: `README.md` (Quickstart; the "manual steps" list; URLs)
- Create: `evidence/00-bringup/README.md`

- [ ] **Step 1: From a clean state (`scripts/down.sh --purge`, if anything exists), run `time bash scripts/up.sh`.** Expected: it exits 0 and `platform_test.sh` passes. Save the output to `evidence/00-bringup/up.log` (label RUN-LOCAL).
- [ ] **Step 2: Push the Task 13 commit.** Expected: `release.yml` builds, scans, signs and pushes the chart, then `promote-dev` commits `dev.yaml`. Run `gh run watch`. Then:
  1. Set `gitops/platform/synthetic-traffic/deployment.yaml` to that digest with `replicas: 1`. Commit and push.
  2. Run `bash scripts/seed-releases.sh` and push.
  3. Re-run the workflow with `gh workflow run release.yml`.

  `gate-dev` failing with `no traffic` on the very first run, before synthetic traffic exists, is expected and is the reason for this order.
- [ ] **Step 3: Verify end-to-end.**
  - `kubectl get applications -n argocd` shows `stack-dev`, `stack-staging`, `stack-prod`, `stack-acme`, `stack-globex` and `tenant-initech`, all Synced/Healthy.
  - `curl -H 'Host: prod.localtest.me' http://127.0.0.1/version` returns the version.
  - `cosign verify ghcr.io/govind-kandale-1/zero-downtime-platform@<digest> --certificate-identity-regexp "$COSIGN_IDENTITY_REGEX" --certificate-oidc-issuer "$COSIGN_ISSUER"` succeeds.
  - Save the outputs to `evidence/05-supply-chain/` (Trivy SARIF summary, cosign verify output). Label RUN-LOCAL.
- [ ] **Step 4: Approve the `production` environment** when prompted. The user can click, or use `gh api` with the owner's review. All gates through `gate-ring2` should pass. Save the run URL and the gate logs to `evidence/00-bringup/`.
- [ ] **Step 5: Update the README Quickstart with the timings observed. Commit** with `feat: one-command bring-up and first release`.

---

### Task 15: AWS provider implementation (NOT RUN)

**Files:**
- Create: `infra/bootstrap/aws/` (S3 state bucket: versioning, SSE-KMS, public access block, TLS-only policy; GitHub OIDC provider + role `zdp-deploy` trusting `repo:Govind-Kandale-1/zero-downtime-platform:ref:refs/heads/main`; local state, documented)
- Create: `infra/modules/aws/network/` (`terraform-aws-modules/vpc`, 3 AZs, private/public/intra subnets; `single_nat_gateway` variable — false for prod)
- Create: `infra/modules/aws/eks/` (`terraform-aws-modules/eks`, managed node group `system`, the Pod Identity agent, and the Karpenter submodule + IAM)
- Create: `infra/modules/aws/stack-data/`:
  - RDS PostgreSQL Multi-AZ: gp3, `backup_retention_period` 14, PITR, Performance Insights, a parameter group with `max_connections=200`;
  - ElastiCache for Valkey, Multi-AZ replication group;
  - a PgBouncer Deployment (helm_release of a small local chart);
  - a Secrets Manager secret `stacks/<stack>/app` with the same three keys;
  - an `aws_db_snapshot_copy` policy/variable restricting the copy region by residency.
- Create: `infra/live/aws/eu-central-1/{05-network,10-cluster,20-data,30-gitops}`, each with `backend "s3" { use_lockfile = true }` (partial config) and the same `tenants/*.yaml` iteration as local, with a region filter.
- Create: `gitops/platform/values/aws/*.yaml` (Traefik NLB annotations; ClusterSecretStore `platform-secrets` on the AWS provider; storage class gp3; Karpenter NodePool + EC2NodeClass + overprovisioning Deployment)
- Create: `docs/policies/eu-region-scp.json` (sample SCP denying non-EU regions; NOT RUN)
- Create: code-review.md in each new folder, every one headed `Label: NOT RUN (static validation only)`

- [ ] **Step 1: Run `terraform-validate` locally for each AWS root:** `terraform -chdir=<root> init -backend=false && terraform validate`. Expected: FAIL (no files).
- [ ] **Step 2: Write the modules and roots.**
- [ ] **Step 3: Validate.** Run `terraform validate` for every AWS root → `Success!`, then `tool_tflint --recursive` and `tool_trivy config infra/` → no HIGH/CRITICAL, or each accepted finding gets a `#trivy:ignore` with a written reason. Save the outputs to `evidence/08-aws-static/` (label NOT RUN).
- [ ] **Step 4: Write ADR-022** (rejected: hand-written VPC/EKS, which means more lines to defend for code that is not run; CDK/Pulumi, a second IaC language). Add Q&A ("What would change to run this on AWS tomorrow?", "Why EKS Pod Identity over IRSA?"). Commit with `feat(infra): AWS reference provider (not run, statically validated)`. Push and confirm `terraform-validate` passes in CI.

---

### Task 16: Load tooling and capacity calibration

**Files:**
- Create: `load/k6/step-single-pod.js`. It hits one stack (`HOST`), with constant-arrival-rate stages of 20, 40, …, 200 req/s for 60 s each, and thresholds per stage recorded.
- Create: `load/k6/ramp-15x.js`. It runs 150 req/s for 2 min, ramps to 2,250 req/s over 3 min, holds 5 min, then ramps down over 2 min. Thresholds: `http_req_failed rate==0`, plus `p(95)<400` tagged `phase:hold`.
- Create: `load/k6/steady-under-deploy.js` (150 req/s for `DURATION`).
- Create: `load/jobs/producer.js`. A k6 script posting jobs at 5.56/s with duration ~ lognormal (mean 10 s, capped at 60 s); `TOTAL` param.
- Create: `scripts/preflight-load.sh`.
  - Scales `app-dev`, `app-staging`, `tenant-acme` and `tenant-globex` Rollouts to minimum by pausing their ScaledObjects (`autoscaling.keda.sh/paused-replicas: "1"`).
  - Sums pod memory requests vs 6.5 GB and exits 1 when over.
  - `--restore` undoes it.
- Create: `scripts/scaling-timeline.sh <ns> <seconds>`. It samples `kubectl get rollout api worker` replicas and the queue depth every 5 s into a CSV.
- Create: `load/code-review.md`, `docs/capacity.md`

- [ ] **Step 1: Run the single-pod step test.** Temporarily pin prod API `min=max=1` by pausing the ScaledObject. Run `tool_k6 run -e HOST=prod.localtest.me load/k6/step-single-pod.js`. Record the highest stage with p95 < 400 ms and 0 errors as `C`.
- [ ] **Step 2: Compute and set the thresholds.** `rpsPerPod = floor(0.7 × C)`. `api.maxReplicas = ceil(2250 / rpsPerPod) + 3`. Write them into `gitops/stacks/prod.yaml`. Fill `docs/capacity.md`:
  - the method and raw table;
  - the formulas;
  - the worker math (Little's law, sensitivity for 5/10/30/60 s, and the 830-worker alternative interpretation);
  - DB connection math recomputed with the real `maxReplicas`;
  - Valkey ops;
  - the scale-up timeline;
  - the AWS node math (pods per node, Karpenter join time);
  - an instance-class rationale for RDS.

  Labels: measured numbers are `RUN-LOCAL (stand-in)`; extrapolations are `DESCRIBED`.
- [ ] **Step 3: Run `bash scripts/preflight-load.sh`.** Expected: exit 0 with a printed headroom figure. Commit with `feat(load): k6 scripts and calibrated capacity`.

---

### Task 17: Evidence runs (deploy under load, auto-rollback, 15x, restore)

**Files:**
- Create: `scripts/demo-deploy-under-load.sh`. It starts `steady-under-deploy.js` (DURATION 20m) against `prod.localtest.me`, then triggers a good release: a trivial commit to `app/` (version string). It waits for the pipeline to promote through prod-ring0, then saves the k6 summary, `kubectl argo rollouts get rollout api -n app-prod` snapshots and the gate logs.
- Create: `app/migrations/0002_add_items_description.sql` (`ALTER TABLE items ADD COLUMN IF NOT EXISTS description text NULL`)
- Create: `scripts/restore-test.sh <stack>`. It:
  1. finds the newest `*.dump` on the stack's backup PVC (via a helper pod);
  2. creates CNPG Cluster `restore-test` in the namespace;
  3. waits for it to be Ready;
  4. `pg_restore`s the dump;
  5. compares `count(*)` and the md5 aggregate with the dump's `.counts` file;
  6. prints `RESTORE PASS rows=<n> md5=<m> rto_seconds=<t>`, or FAIL;
  7. deletes the cluster.
- Create: `evidence/{01-deploy-under-load,02-auto-rollback,03-load-15x,04-restore-test}/README.md`, each stating what was run, the exact commands, the result and its label.
- Create: `docs/runbooks/rollback-after-migration.md`, `docs/runbooks/canary-aborted.md`

- [ ] **Step 1: Evidence 1.** Run `bash scripts/demo-deploy-under-load.sh`. Expected: the k6 summary shows `http_req_failed: 0.00%` across the whole canary on prod-ring0. Save it to `evidence/01-deploy-under-load/`.
- [ ] **Step 2: Evidence 2.**
  1. Commit A: add migration `0002` **and** change `defaults.go` to `const FaultErrorRate = 0.3`, with message `demo: bad release (intentional bug)`. Push.
  2. Expected: `release.yml` → `promote-dev` → the dev canary at 10% → AnalysisRun `Failed` → Rollout `Degraded`/aborted → `gate-dev` prints `GATE FAIL dev/dev`, and staging/prod jobs are skipped.
  3. Verify `curl -H 'Host: dev.localtest.me' /api/items/1` still returns 200 from the stable pods. Verify `select version from schema_migrations` in dev shows `0002`, which proves the stable pods serve on the expanded schema.
  4. Save `kubectl argo rollouts get rollout api -n app-dev`, `kubectl get analysisrun -n app-dev -o yaml`, the gate log and the run URL.
  5. Commit B: revert only `defaults.go` (keep `0002`), with message `fix: remove intentional bug`. Push. Expected: it promotes through all gates.
- [ ] **Step 3: Evidence 3.**
  1. Run `bash scripts/preflight-load.sh`.
  2. In parallel: `bash scripts/scaling-timeline.sh app-prod 900 > evidence/03-load-15x/timeline.csv`, `tool_k6 run -e HOST=prod.localtest.me load/k6/ramp-15x.js`, and `tool_k6 run -e HOST=prod.localtest.me -e TOTAL=5000 load/jobs/producer.js`.
  3. Expected: replicas reach `api.maxReplicas - 3` or more within 5 min of ramp start; `http_req_failed == 0`; hold-phase p95 < 400 ms. After the queue drains, `jobs:enqueued_total == jobs:done_total + jobs:failed_total` (via `valkey-cli`).
  4. Scale-down back to minimum within 15 min after the ramp-down, recorded from the timeline.
  5. If the laptop saturates, rerun with `-e BASE=50` (15x = 750 req/s) and label `laptop-bound`.
  6. Run `bash scripts/preflight-load.sh --restore`.
- [ ] **Step 4: Evidence 4.** Trigger a backup with `kubectl create job --from=cronjob/backup backup-now -n app-prod`, then run `bash scripts/restore-test.sh prod`. Expected: `RESTORE PASS` with an RTO. Save the log.
- [ ] **Step 5: Write ADR-019 and the two runbooks. Commit** with `docs(evidence): deploy under load, auto-rollback, 15x, restore`.

---

### Task 18: Documentation completion

**Files:**
- Create: `docs/architecture.md`. Under ~5 printed pages:
  - a diagram (Mermaid + the ASCII fallback from spec §6);
  - the layer table;
  - flows;
  - the five most important decisions with rejected alternatives (link ADR-010, 011, 015, 003, 018);
  - the top 5 risks with mitigations: single Postgres writer at 15x; a non-backward-compatible migration shipped despite policy; a black-box worker not draining → duplicates; laptop evidence not representative; dependency on GitHub (Actions/GHCR) for promotion.
- Create: `docs/non-portable.md`, `docs/slos.md` (SLIs, targets, budgets, alert table), `docs/cost.md`, `docs/roadmap.md`.
  - `docs/cost.md` uses AWS eu-central-1 on-demand prices fetched at build time, with the date and source cited per line; covers steady and peak for shared prod, non-prod and per dedicated tenant; and gives the max number of dedicated tenants within $9k/$16k.
  - `docs/roadmap.md` is a 90-day plan.
- Create: `docs/runbooks/{burn-rate-page,queue-backlog,db-connection-saturation,restore-from-backup,failed-tenant-onboarding,drift-detected}.md`
- Modify: `README.md`. Final coverage table: one row per spec Appendix A item with built/described, label and evidence link. Also a "Tested with stand-in vs real app" table, and the manual-steps list.
- Modify: `questions-answers.md`. Complete every section, including all the uncomfortable questions in spec §14.
- Modify: every `code-review.md`. Audit each against its folder's actual files.

- [ ] **Step 1: Write `scripts/tests/docs_test.sh`.** It fails if:
  - any folder containing `*.go|*.tf|*.yaml|*.sh|*.rego|Dockerfile` (excluding `docs/`, `evidence/` and `.github/workflows`, which are covered by `.github/code-review.md`) lacks a `code-review.md`;
  - a file named in a code-review.md doesn't exist;
  - `decisions.md` is missing any ADR ID from the allocation table;
  - `README.md` lacks any of the 11 Appendix A items;
  - an evidence README lacks a `Label:` line;
  - `LICENSE` differs from the original text (store its sha256 in the test).
- [ ] **Step 2: Run it.** Expected: FAIL (missing docs).
- [ ] **Step 3: Write the docs listed above.**
- [ ] **Step 4: Run `bash scripts/tests/docs_test.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** with `docs: architecture, capacity, cost, roadmap, runbooks, Q&A`. Push. Confirm CI is green.

---

## Out of this plan (follow-on plans)

- **P1:** Kyverno signature verification; tenant onboarding timing (`tenant-apply.yml`); `drift.yml`; per-tenant Grafana dashboards; secondary rollback demo on prod-ring0. Rings are already in P0.
- **Change request:** a third provider implementation plus a one-page addendum, after its release.
