# Decision Log

Every significant decision, the alternatives that were rejected, and the reason. Entries are appended as the work proceeds; IDs are stable (gaps mean the entry belongs to a later build step).

**Labels:**
- `RUN-LOCAL`: executed on the local kind platform.
- `RUN-LOCAL (stand-in)`: executed against the stand-in app, not the real black box.
- `NOT RUN (static validation only)`: written and validated, never applied.
- `DESCRIBED`: design only.

Template:

```
## ADR-NNN: Title
Date · Status · Label
**Context** — why a decision was needed
**Decision** — what we chose
**Rejected alternatives** — each with the reason
**Consequences** — what this costs us / what it enables
```

---

## ADR-001: Local kind is the only executed target; AWS is written and statically validated

2026-10-25 · Accepted · Label: RUN-LOCAL (local) / NOT RUN (AWS)

**Context.** The brief asks for the platform to "run on two targets (for example one cloud plus local kind/k3d)". An AWS account exists, but its credentials were invalid at the start. The submitter also chose not to spend money on live cloud infrastructure for an evaluation exercise.

**Decision.**
- Everything is built and executed on a local kind cluster.
- The AWS provider layer (VPC, EKS, RDS, ElastiCache for Valkey, Secrets Manager, S3 state, GitHub OIDC) is written in full against the same provider contract.
- In CI it is validated with `terraform validate`, `tflint` and `trivy config`.
- It is labelled `NOT RUN` everywhere.

**Rejected alternatives.**
- *Real EKS, created and destroyed each session (~$0.50/h, ~$15–25 total):* the strongest evidence, but declined by the submitter for cost and credential reasons.
- *Always-on EKS (~$12–15/day):* the same, and more expensive.
- *k3d as a second local target:* two local distributions prove little about cloud portability. The interesting differences are LB, IAM, managed databases and node autoscaling, and only a real cloud implementation exercises them.

**Consequences.** The "two targets" requirement is only *partially* met, and this is stated openly in the README. The portability claim rests on two things: (a) the provider contract, and (b) a complete second implementation that compiles and passes static analysis. The roadmap's first item is to run the AWS target.

## ADR-003: Three-layer infrastructure with an explicit provider contract

2026-10-25 · Accepted · Label: RUN-LOCAL / NOT RUN (AWS)

**Context.** The brief requires the provider layer (network, Kubernetes, databases, secrets) to be separate from the platform and app layers, and asks what is not portable.

**Decision.**
- **Provider layer (Terraform):** the only layer that differs per cloud. It must deliver exactly the following, the *provider contract*:
  - a cluster + kubeconfig;
  - per stack: Postgres, PgBouncer at `pgbouncer.<ns>.svc:5432`, and Valkey;
  - a secrets manager holding `DATABASE_URL`, `MIGRATION_DATABASE_URL` and `REDIS_URL` at `stacks/<stack>/app`;
  - a remote state backend with locking.
- **Platform layer (Argo CD-managed Helm):** identical everywhere apart from small per-provider values overlays.
- **App layer:** one Helm chart for every stack.

**Rejected alternatives.**
- *One monolithic Terraform root per cloud:* no portability boundary. Everything would be rewritten per cloud.
- *Crossplane for all infrastructure:* needs a running cluster before it can build one (bootstrap problem), and adds a control plane to learn and operate within the time box.
- *Helm/Kubernetes only:* cannot create networks, managed databases or IAM.

**Consequences.** Adding a cloud (e.g. for the change request) means writing one new provider implementation; nothing above it changes. The contract is listed in [docs/architecture/where-things-live.md](docs/architecture/where-things-live.md#the-provider-contract), and the leaks are listed in `docs/non-portable.md`.

## ADR-020: Public repository; `main` protected by a ruleset with a deploy-key bypass for release commits

2026-10-25 · Accepted · Label: RUN-LOCAL

**Context.**
- The repo needs branch protection and an approval step before production.
- The cluster must pull charts and images.
- The pipeline must be able to commit release files to `main`.

**Decision.**
- **Public repo.** Environment required reviewers and rulesets are free on public repos; Argo CD, the kubelet and Kyverno pull with no credentials.
- **Ruleset on `main`:** pull request + code-owner review, required CI checks, no force-push.
- **Bypass actors:**
  - repository admins, so the solo owner can merge;
  - a write-enabled **deploy key** used only by the release workflow to commit `gitops/releases/*.yaml`.
- **Self-hosted runner hardening:**
  - fork-PR workflows need approval;
  - runner-labelled jobs run only on `push`, `schedule` and `workflow_dispatch`;
  - gate jobs use a read-only kubeconfig.

**Rejected alternatives.**
- *Private repo:* on a personal plan it gets no Environment approvals and no enforced branch protection, and needs pull secrets in every namespace.
- *Pushing release commits with `GITHUB_TOKEN`:* blocked by the ruleset, and it can't be made a bypass actor.
- *A PR per promotion:* needs a human merge for every stage and ring, which defeats automated fleet rollout. It remains an option for regulated tenants.

**Consequences.**
- A solo owner cannot approve their own PR, so "reviewed change" means checks plus an admin merge. This limitation is documented.
- Keyless signing records the repo identity in the public Rekor log, which is acceptable for a public repo.

**Revised 2026-10-26: the admin bypass also bypassed CI.**
- A test (`TestMigrateIsIdempotentAndLocked`) failed on `main` for a day without anyone noticing. Migration `0002` was added in a direct admin push, and CI runs on PRs and dispatch, not on push.
- A manually dispatched CI run on `main` caught it. The test now derives its expectations from the embedded migrations.
- **The lesson:** "admins may bypass" quietly meant "admin changes are untested".
- **The fix** (roadmap): run CI on `push` to `main` as well, using `concurrency` to avoid double runs on PRs, or remove the admin bypass once there is a second reviewer.
- `release.yml` now ignores `*_test.go`, so a test-only fix doesn't start a release.

## ADR-021: Toolchain runs in pinned containers on the Windows host

2026-10-25 · Accepted · Label: RUN-LOCAL

**Context.** The host is Windows 11 with Docker Desktop. Go, jq, yq, conftest, kubeconform, trivy, tflint and k6 are not installed; CI (Linux) installs them natively.

**Decision.**
- `scripts/lib/tools.sh` exposes `tool_<name>` functions. Each uses the native binary if present, otherwise the image pinned in `config/versions.env`, with the repo bind-mounted.
- Scripts are bash, run from Git Bash. `.gitattributes` forces LF, and `scripts/tests/eol_test.sh` enforces it.

**Rejected alternatives.**
- *Install everything natively:* modifies the host, and local versions drift from CI.
- *A WSL distro:* yet another environment to keep in sync with Docker Desktop's.
- *A dev container:* a good next step, but heavier to set up inside the time box.

**Consequences.** The same pinned versions run locally and in CI. The cost is a few seconds of container start-up per tool call, plus the Windows path quirks handled in `host_path` (`MSYS_NO_PATHCONV`).

## ADR-024: Load interpretation: 20,000 jobs/hour is the peak rate; mean job duration 10 s

2026-10-25 · Accepted · Label: DESCRIBED (assumption)

**Context.** The brief says "150 req/s baseline, 2,250 req/s peak (15x) with 20,000 jobs/hour" and "jobs up to 60 s". It doesn't say whether the job rate is the baseline or the peak, or what the average job duration is.

**Decision.** 20,000 jobs/h (λ = 5.56 jobs/s) is the *peak* rate, and the mean job duration is 10 s. By Little's law that needs about 56 concurrent workers at peak. The 60 s maximum sets the shutdown grace period (90 s), not the fleet size.

**Rejected alternatives.**
- *Jobs as baseline (×15 at peak = 83 jobs/s, ~830 workers):* kept as a documented sensitivity case in `docs/capacity.md`.
- *Sizing on the 60 s maximum (~333 workers):* wastes capacity, because throughput depends on the mean.

**Consequences.** `docs/capacity.md` carries a sensitivity table (5/10/30/60 s means, both interpretations). If the real mean differs, only `worker.maxReplicas` and the KEDA `listLength` change.

## ADR-005: Stand-in application in Go, contract-only, with a bounded-concurrency capacity model

2026-10-25 · Accepted · Label: RUN-LOCAL (stand-in)

**Context.** The brief treats the application as a black box ("do not rewrite") but supplies no image. Something has to run so the platform can be exercised, and the 15x load test (estimated then at about 33 API pods and 60 workers; calibrated later to at most 21 API pods, `docs/capacity.md`) has to fit in a ~9.7 GB Docker VM on a laptop.

**Decision.**
- **Contract only.** A small Go module with one image and three binaries (`/api`, `/worker`, `/synthetic`). It implements only the black-box contract, plus two stand-in-only knobs.
- **Capacity model.** `MAX_INFLIGHT` (8) is a queueing semaphore and `WORK_LATENCY_MS` (40) is a slept per-request delay. Together they give each pod a finite capacity (≈ `MAX_INFLIGHT / latency`; estimated at ~100 req/s, measured at ~180 req/s in Task 16), so overload shows up as rising latency, as with a real thread pool.
- **Fault injection.** `FAULT_ERROR_RATE` is a compiled-in default with an env override, used by the bad-release demo.

**Rejected alternatives.**
- *Python/FastAPI:* most readable, but about 4× the memory per pod and slower start-up. That is a problem for both the laptop budget and the scale-up time.
- *An existing demo app (e.g. podinfo):* it has the HTTP endpoints but no Postgres migrations and no Redis worker, so the migration and queue stories couldn't be shown.
- *CPU-burn work per request:* it makes per-pod capacity CPU-bound, but CPU then grows with pod count × load. That would saturate the laptop long before 2,250 req/s and measure the laptop, not the platform.

**Consequences.**
- Every result obtained with it is labelled `RUN-LOCAL (stand-in)`.
- Behaviours the stand-in guarantees but the real app might not are listed in the README as assumptions, each with a mitigation: SIGTERM draining, advisory-locked migrations, a separate migration URL, enqueue timestamps, idempotent jobs.

## ADR-006: Reliable list queue (BLMOVE + heartbeat reaper), at-least-once delivery

2026-10-25 · Accepted · Label: RUN-LOCAL (stand-in)

**Context.** The brief requires autoscaling "without dropping jobs" (jobs take up to 60 s) and worker draining during rollouts. A worker can be stopped by a rollout, by KEDA scale-in, by node drain, by OOM or by a crash. The first three send SIGTERM; the last two don't.

**Decision.**
- **Claims are atomic moves, not pops.** `BLMOVE jobs → jobs:processing:<pod>`, so a job is always in exactly one list (pending, processing or failed).
- **Graceful stops.** On SIGTERM the worker stops claiming and finishes the job in hand. Its heartbeat keeps running until it exits, and `terminationGracePeriodSeconds: 90` exceeds the 60 s maximum job.
- **Ungraceful stops.** Each worker keeps a heartbeat key with a 30 s TTL. A reaper (one leader via `SET NX EX`) moves the processing lists of dead workers back to the *head* of the queue.
- **Accounting.** Counters (`enqueued_total`, `done_total`, `failed_total`) make "zero dropped jobs" provable.

**Rejected alternatives.**
- *Plain `BRPOP`:* simplest, but a crash between pop and completion loses the job silently.
- *Redis Streams with consumer groups (`XREADGROUP` + `XAUTOCLAIM`):* the industry-standard version of the same idea. Rejected only because the brief fixes the black box to a *list*-style "Redis queue", and KEDA's Redis *Lists* scaler matches that. Streams would be the choice for a new system.
- *KEDA ScaledJob (one Kubernetes Job per queue item):* never interrupts a job, but at 5.56 jobs/s it means 5.56 pod starts per second. Too much churn and too slow.
- *Exactly-once:* needs a dedupe store keyed by job id plus transactional side effects. Out of scope; jobs must be idempotent instead.

**Consequences.**
- Delivery is **at-least-once**. A job finished just before a crash (before `Ack`) runs again, so real jobs must be idempotent. This is listed as an assumption about the black box.
- After an ungraceful death, a job waits up to ~30 s (heartbeat TTL) plus up to 15 s (reaper interval) before it is retried.

## ADR-004: Terraform for the provider layer; `pg` backend locally, S3 with native locking on AWS

2026-10-25 · Accepted · Label: RUN-LOCAL (local) / NOT RUN (AWS)

**Context.** The brief requires IaC, remote state and drift detection, starting from an empty account with no console steps. The provider layer must create clusters, networks, managed databases and IAM on any cloud.

**Decision.**
- **Terraform** (≥ 1.14), one numbered root per stage (`10-cluster`, `20-data`, `30-gitops`; AWS adds `05-network`).
- **Local state:** the `pg` backend, pointed at a Postgres container (`zdp-tfstate`) started by `scripts/state-up.sh`. Each root gets its own schema, and locking uses Postgres advisory locks. The credentials live in the git-ignored `.local/tfstate.env`.
- **AWS state:** the `s3` backend with `use_lockfile = true` (S3-native conditional-write locking, so no DynamoDB table). The bucket is created by `infra/bootstrap/aws`, which uses local state.

**Rejected alternatives.**
- *OpenTofu:* functionally equivalent here and a fine choice. Terraform is already installed and more commonly asked about, and the code runs on both.
- *Pulumi / CDK:* infrastructure in a general-purpose language. It adds a second toolchain and a different review model, and gives no advantage for declarative cloud resources.
- *Crossplane:* needs a cluster before it can build one, and adds a control plane to operate (see ADR-003).
- *Local state for the local target:* violates "remote state" and has no locking.
- *S3 emulation (MinIO/LocalStack) to mirror AWS exactly:* adds a component whose licensing and distribution have changed recently. The interesting property is *networked state with locking*, which the pg backend gives directly.
- *The Kubernetes backend:* state would live inside the cluster that Terraform creates (chicken-and-egg), and destroying the cluster would destroy the state.

**Consequences.**
- The backend *type* differs per target (`pg` vs `s3`), so it is listed as non-portable. Everything else in the roots is identical.
- The bootstrap stack for AWS keeps local state by necessity; this is documented.
- Drift detection is `terraform plan -detailed-exitcode` per root (exit 2 = drift).

## ADR-007: CloudNativePG + PgBouncer in transaction mode, with a separate direct URL for migrations

2026-10-25 · Accepted · Label: RUN-LOCAL (local) / NOT RUN (AWS RDS)

**Context.** At 15x the platform runs about 40 API pods and up to about 120 workers (design-time estimate; calibrated: at most 21 API pods × 12 connections = 252, plus workers). With a 10-connection pool per API pod and 2 per worker, that is roughly **640 client connections**, while a Postgres primary performs best with a few dozen active backends. Separately, the black box runs migrations at startup, and safe concurrent migrations need a **session-level advisory lock**.

**Decision.**
- **Pooling.** Every stack gets PgBouncer in **transaction mode** (`max_client_conn=1000`, `default_pool_size=40`). Runtime traffic uses `DATABASE_URL` → PgBouncer.
- **Migrations go direct.** They use `MIGRATION_DATABASE_URL` straight to the primary.
- **The trap this avoids.** In transaction mode, PgBouncer may give each transaction a different server backend. A `pg_advisory_lock` taken in one transaction can then be held by a backend the client never talks to again, and the `pg_advisory_unlock` lands on another backend and does nothing. The result is a lock held forever, or two pods migrating at once. Flyway, golang-migrate and Prisma all use session advisory locks.
- **Where it runs.** Locally, Postgres is a CloudNativePG `Cluster`, with PgBouncer from its `Pooler` CRD. On AWS: RDS PostgreSQL Multi-AZ plus an in-cluster PgBouncer Deployment.

**Rejected alternatives.**
- *No pooler:* about 640 backends on one primary means context switching and per-backend memory, and `max_connections` exhaustion during scale-up.
- *PgBouncer in session mode for everything:* safe for advisory locks, but gives almost no multiplexing. One client equals one backend.
- *RDS Proxy:* managed, but AWS-only (not portable). It "pins" connections that use session state such as advisory locks, which silently removes the pooling benefit.
- *Bitnami PostgreSQL chart:* Bitnami's free images moved to an unmaintained legacy repository in 2025.
- *A plain Postgres StatefulSet:* no failover, backup or pooler management. CNPG behaves much more like a managed service.

**Consequences.**
- The app must accept two URLs. The stand-in does; for the real black box this is an assumption. If it accepts only one, run its migrations through a session-mode pool, or a direct URL plus a startup flag.
- Prepared statements over transaction mode need PgBouncer ≥ 1.21 (`max_prepared_statements`) or driver settings that avoid them.
- The connection maths lives in `docs/capacity.md`.

## ADR-008: Valkey instead of Redis

2026-10-25 · Accepted · Label: RUN-LOCAL (local) / NOT RUN (AWS)

**Context.** The black box consumes a "Redis queue", so any Redis-protocol server works. In 2024 Redis moved from BSD to source-available licences (RSAL/SSPL), and Redis 8 added AGPL as an option.

**Decision.** Valkey 9.1 (the Linux Foundation fork of Redis 7.2, BSD-licensed) runs locally as a StatefulSet with AOF persistence and `noeviction`. On AWS it is **ElastiCache for Valkey**.

**Rejected alternatives.**
- *Redis OSS / Redis 8:* the licence terms are a procurement and legal question for a platform that may be resold to tenants. Valkey removes the question at no functional cost.
- *KeyDB / Dragonfly:* compatible, but less widely adopted, and not offered as a managed service on the major clouds.

**Consequences.**
- The client libraries (go-redis), KEDA's Redis scaler and redis_exporter all work unchanged with Valkey.
- ElastiCache for Valkey is priced about 20% below ElastiCache for Redis OSS, which helps the cost model.

## ADR-009: OpenBao + External Secrets Operator as the secrets interface

2026-10-25 · Accepted · Label: RUN-LOCAL (local) / NOT RUN (AWS)

**Context.** The brief requires a secrets manager. The provider contract needs the app's database and cache URLs to come from it, without the app layer knowing which cloud it is on.

**Decision.**
- **One flow on both targets:** Terraform writes `stacks/<stack>/app` into the secrets manager. **External Secrets Operator** syncs it into a Kubernetes Secret `app-env` in each stack namespace, through a `ClusterSecretStore` named `platform-secrets`.
- **Locally**, the store is **OpenBao** in dev mode, using a token.
- **On AWS**, the store is **AWS Secrets Manager**, using EKS Pod Identity.
- The app chart's `ExternalSecret` is identical on both targets. Only the `ClusterSecretStore` spec differs.

**Rejected alternatives.**
- *Plain Kubernetes Secrets written by Terraform:* no secrets manager, no rotation, no audit, and the values end up in Terraform state *and* etcd with no central control.
- *SOPS-encrypted secrets in Git:* good for GitOps, but key management moves to the repo, rotation means a commit, and there is no runtime audit trail. Not a "secrets manager".
- *Sealed Secrets:* one controller key per cluster, so it doesn't map onto a cloud secrets manager and is hard to share across clusters.
- *Vault (HashiCorp):* the same API, but BSL-licensed since 2023. OpenBao is the open-licence fork, and ESO's Vault provider works with it unchanged.

**Consequences.**
- The secrets are still present in Terraform state, which generated them. State is therefore treated as sensitive: it is held in a credentialed Postgres locally and in an encrypted, access-controlled S3 bucket on AWS.
- Dev-mode OpenBao loses data on restart. That is acceptable for a laptop: `terraform apply` re-seeds it, and drift detection notices the loss.

## ADR-010: GitOps pull with Argo CD (app-of-apps + ApplicationSets)

2026-10-25 · Accepted · Label: RUN-LOCAL

**Context.** The brief asks to "choose GitOps (pull) or pipeline push" and to roll out shared first, then dedicated tenants in rings, then regions. The cluster may be anywhere (a laptop, a private VPC), and the platform must correct drift.

**Decision.**
- **Pull model.** Argo CD runs in each cluster and pulls from Git every 60 s. Terraform installs it and applies one root Application (app-of-apps).
- **What the root manages.**
  - Platform components: one Application each, ordered by sync waves.
  - Environment stacks and tenants: ApplicationSets driven by `gitops/stacks/*.yaml` and `tenants/*.yaml`, with release-file pins.
- **What pipelines do.** They never call `kubectl` or `helm` against a cluster. They only commit to Git.
- **Drift.** Automated sync with prune and self-heal.

**Rejected alternatives.**
- *Pipeline push (`helm upgrade`/`kubectl apply` from CI):*
  - CI would need cluster-admin credentials for every cluster, with a large blast radius if leaked.
  - The cluster must be reachable from CI, which a private EKS or a laptop isn't.
  - There's no continuous drift correction: a manual `kubectl edit` survives until the next deploy.
- *Flux:* an equally valid pull-based tool. Argo CD was chosen for its UI (useful for the demo and the review), its first-class Argo Rollouts integration (rollout health, abort and promote in the UI), and ApplicationSets for tenant fan-out.
- *One central Argo CD managing remote clusters (hub-and-spoke):* fewer installs, but the hub then holds credentials for every cluster and becomes a single point of failure. Per-cluster Argo CD keeps the pull model pure. A hub is a roadmap item, once there are many clusters.

**Consequences.**
- A promotion takes effect within about 60 s plus sync time, not instantly. That is acceptable and visible.
- The pipeline needs a way to *observe* the result without pushing. Gates read Rollout status and metrics with read-only credentials (ADR-015).
- Git becomes production-critical. If GitHub is down, nothing new deploys, but running workloads are unaffected.

## ADR-016: Synthetic traffic so canary analysis is never inconclusive

2026-10-25 · Accepted · Label: RUN-LOCAL (platform tooling)

**Context.**
- Canary gates evaluate real metrics (error ratio, p95) for the canary's share of traffic.
- When a query returns no data, Argo Rollouts marks the measurement *inconclusive*, and an inconclusive analysis **pauses** the rollout. It neither passes nor aborts.
- Locally, dev, staging and the tenant stacks receive no user traffic, so every pipeline run would stall at its first gate.
- In production, low-traffic tenants and off-peak hours have the same problem.

**Decision.**
- One small Deployment (`synthetic-traffic`, 32 Mi) sends a constant ~10 req/s per stack, plus one job per 10 s, **through the ingress** with each stack's `Host` header. Every request carries `X-Synthetic: 1`.
- The analysis templates include synthetic traffic and also require a minimum request count, so too little data is never mistaken for health.
- Dashboards can exclude synthetic requests from user-facing numbers.

**Rejected alternatives.**
- *Treat no-data as a pass:* a canary that receives zero requests would be promoted untested.
- *Skip analysis on non-prod:* then dev and staging prove nothing, and the first real gate is production.
- *k6 or blackbox-exporter as the generator:* k6 is built for bounded tests (its trend metrics grow in memory over long runs). Blackbox-exporter probes only, at a low rate. Both remain good choices for a production version.

**Consequences.**
- Every stack has a permanent baseline of known-good requests. This doubles as **black-box monitoring**: synthetic errors mean the stack is broken, whether or not users noticed.
- At 10 req/s and a 10% canary weight, the canary sees about 1 req/s. That is enough to detect a 30% fault rate within the 1-minute analysis interval, though not subtle regressions. Production traffic does that.

## ADR-011: API deploys by canary (Argo Rollouts + Traefik), gated on edge metrics

2026-10-25 · Accepted · Label: RUN-LOCAL (stand-in)

**Context.** The brief asks for a choice between canary, blue/green and rolling for the API, with defined traffic steps, gating metrics and automatic rollback. The app is a black box: its metric names are unknown, and its migrations run at startup.

**Decision.**
- **Strategy.** An Argo Rollouts canary with Traefik weighted routing. Steps are **10% → 25% → 50% → 100%**, with a 2-minute pause each (1 minute locally).
- **Gate.** A background AnalysisTemplate evaluates the **canary Service as seen by Traefik**:
  - success rate ≥ 99%;
  - p95 ≤ 400 ms;
  - at least 20 requests per minute, otherwise the result is inconclusive and the rollout pauses.
- **Automatic rollback.** Two failed measurements abort the rollout: 100% of traffic returns to stable within one reconcile, and the canary scales down.

**Rejected alternatives.**
- *Blue/green:* needs two full fleets during cutover. At 2,250 req/s that is about 21 extra API pods (calibrated; estimated at 40 when this was decided). It also gives no protection against schema changes, because both colours share one database, and the cutover is all-or-nothing.
- *Plain rolling update:* has no traffic control and no metric gate. A bad version reaches 100% as fast as pods turn Ready, and "Ready" says nothing about error rate.
- *Gating on the app's own metrics:* the black box's metric names are unknown. Edge metrics are uniform for every app behind the ingress.

**Consequences.**
- During a bad release, roughly 10–25% of requests see errors for 1–2 minutes before the abort. That is the blast radius, and it is measured in evidence item 2.
- Argo CD must ignore drift on `TraefikService` weights.
- Canaries need traffic, hence synthetic traffic (ADR-016).

## ADR-012: Worker deploys by gated rolling update (a Rollouts canary without traffic routing)

2026-10-25 · Accepted · Label: RUN-LOCAL (stand-in)

**Context.** A queue consumer has no request traffic to split. It still needs zero dropped jobs during a rollout, and the brief asks for automatic rollback for the worker too.

**Decision.**
- **Strategy.** An Argo Rollouts canary *without* `trafficRouting`, so "weight" means the share of replicas. In effect this is a rolling update with gates: 25% → 50% → 100% (`maxSurge 25%`, `maxUnavailable 0`).
- **Gates.** Background analysis checks:
  - the job failure ratio of canary pods ≤ 2%, isolated by pod-template hash;
  - the oldest queued job < 120 s;
  - zero restarts of canary pods.
- **Draining.** `terminationGracePeriodSeconds: 90`, against a 60 s maximum job.

**Rejected alternatives.**
- *A plain Deployment rolling update:* rolls the same way, but cannot roll *itself* back on a metric. `progressDeadlineSeconds` only marks the rollout failed.
- *Blue/green workers:* two consumer fleets would compete for the same queue anyway, so there's no isolation to gain, and it costs double the capacity.
- *KEDA ScaledJob (one Job per message):* never interrupts work, but at 5.56 jobs/s it means 5.56 pod starts per second.

**Consequences.**
- The worker analysis relies on stand-in metrics (`jobs_processed_total`, `queue_oldest_job_age_seconds`), so for the real black box it is an assumption. The black-box-safe fallback is queue depth from redis_exporter, plus pod restarts.

## ADR-013: KEDA for both components: API on edge RPS per pod, worker on queue length

2026-10-25 · Accepted · Label: RUN-LOCAL (stand-in)

**Context.** The platform must reach 15x (150 → 2,250 req/s) in under 5 minutes and come back down without dropping jobs, and the brief asks for queue depth to drive the workers. The API is I/O-bound: it waits on the database, not the CPU.

**Decision.**
- **API.** A KEDA `ScaledObject` targeting the Rollout. The Prometheus trigger is `sum(rate(traefik_service_requests_total{stack services}[1m]))` with a threshold of `rpsPerPod`, set to 70% of the *measured* per-pod capacity. A CPU trigger at 70% is a safety net.
  - Scale-up: no stabilization; each 15 s, add the larger of +100% or +8 pods.
  - Scale-down: a 300 s stabilization window, then at most −20% per minute.
- **Worker.** A KEDA Redis-list trigger on `LLEN jobs` with a target of 5 pending jobs per worker. The same scale-down damping applies; scale-in is safe because of draining plus the reaper.
- **Bounds.** Min 3 API pods (HA); the chart default maximum is 40 API and 120 worker pods. Prod sets 21 API (calibrated: 2,250 / 126 + headroom) and 60 workers (`gitops/stacks/prod.yaml`).

**Rejected alternatives.**
- *CPU-only HPA:* I/O-bound pods saturate on concurrency long before CPU. By the time CPU rises, latency has already blown the SLO. The signal lags the cause.
- *HPA with prometheus-adapter:* works, but KEDA covers both cases (Prometheus and Redis) with one component, and adds scale-to-N activation and queue scalers.
- *Fixed peak capacity:* about 40 pods, around the clock, for traffic that is 15x below peak most of the time.

**Consequences.**
- Scale-up to 15x takes about 15 s (HPA sync) per step of +100% or +8 pods (3 → 11 → 21), plus pod start; KEDA's poll isn't in the path while `minReplicaCount` ≥ 1. That's roughly 1.5 minutes in-cluster. On AWS, Karpenter node provisioning adds about 60–90 s, absorbed by over-provisioning pods.
- `spec.replicas` is left out of the Rollouts so Argo CD and KEDA don't fight over it.

**Revised 2026-10-25 (evidence 01): the CPU safety net fired first.** Under 150 req/s of steady load the HPA went from 3 to 14 API pods in 30 s, with the reason "cpu resource utilization above target". It then sat at 14–15 pods running at about 7% of their capacity. The cause was the CPU request, not the trigger design: the request was 50m and the trigger 70% of it, i.e. 35m. The stand-in uses about **1.4 millicores per req/s** (measured: total API CPU against total edge RPS at 20 and 170 req/s, with no meaningful fixed cost per pod). So CPU crossed its threshold at about 25 req/s per pod, five times below the RPS target of 126. The rule now:
- **A safety-net trigger must fire after the primary trigger and before saturation.** With `api.cpuRequest: 200m` and `cpuUtilization: 100`, CPU fires at about 143 req/s per pod. That's above the prod target (126) and below capacity (C ≈ 180, about 250m).
- **API CPU follows per-pod load, not stack size**, so it moved out of `sizes` into one value. Memory still scales with size.
- A render test enforces `request × utilization ≥ 1.4 m × 126`.
- The same evidence run found **no database metrics** at all. The CloudNativePG Postgres and PgBouncer exporters are now scraped (`dbMetrics`, local only), so pool waits can be told apart from slow code.

**Revised again 2026-10-25 (evidence 03, attempt 1): request rate alone cannot see an overload.** In the first 15x run the HPA held at 3–4 pods while the offered load climbed from 150 to 1,000 req/s. The trigger measured **completed** requests, and completed req/s can't exceed what the pods can serve. At 15:31:15, k6 offered 721 req/s, the trigger saw about 290 (a 1-minute average of a capped number), and the 3 pods held **242 requests in flight** against a limit of 8 each. The fleet saturated, latency rose, the load generator opened thousands of connections on the same VM, and the CPU starvation took KEDA and Traefik down with it (55.7% of requests failed).
- **Added a saturation trigger: requests in flight per pod** (served + queued; target 5.6, i.e. 70% of the concurrency limit). In-flight = arrival rate × latency (Little's law), so it grows *with* the overload instead of being capped by capacity. At 15:31:15 it would have asked for 242 / 5.6 ≈ 43 pods, and the scale-up policy delivers 3 → 11 → 21 in 30 s.
- The HPA takes the **maximum** across triggers: RPS sizes the steady state, in-flight reacts to saturation, and CPU is the safety net.
- **Assumption for the real app:** it exposes an active-requests gauge, such as OpenTelemetry's `http.server.active_requests` (`api.inflightMetric`). If it doesn't, the fallback is Traefik's entrypoint `open_connections`, which is shared across stacks and inflated by idle keep-alives. This is in the open questions.

**Revised 2026-10-26 (independent review): the worker scaler finds the queue through the contract.** It had a hard-coded `valkey.<ns>.svc:6379`, which exists only locally; on AWS the worker would never have scaled. The ExternalSecret now derives `QUEUE_ADDRESS` from `REDIS_URL`, and KEDA reads it through a TriggerAuthentication, with `queue.tls` for ElastiCache. Verified on the live cluster (`evidence/00-bringup/queue-wiring-check.txt`).

**Revised a third time 2026-10-25 (evidence 03, attempts 2–3): size the target for the ramp, not only for steady state. Designed, not applied.**
- Reactive scaling only keeps up if the spare capacity covers **ramp slope × reaction time**. The reaction time is about 60 s here: the 1-minute rate window lags a ramp by about 30 s, then scrape, HPA sync and pod start (KEDA's poll isn't in the path while `minReplicaCount` ≥ 1).
- The brief's ramp (2,100 req/s in 3 min, 11.7 req/s per second) needs about 700 req/s of headroom. 3 pods at 70% of C leave about 390. So the current targets **saturate briefly during the ramp on any infrastructure**.
- On a real cluster the in-flight trigger recovers that in about 30 s, as a latency bump (attempt 2 showed it reacting 4 → 12 → 21). On the laptop, saturation starves the shared VM and collapses the cluster (attempts 2 and 3).
- **The fix:** a `rate(...[30s])` window and a 5 s scrape for the scaling metrics (KEDA's poll doesn't matter while `minReplicaCount` ≥ 1), `rpsPerPod` ≈ 80 (about 45–50% of C), `inflightPerPod` 3.5, and KEDA `cron` pre-scaling for peaks known in advance.
- **Cost:** about 30 API pods at peak instead of about 21, i.e. about 4.5 more vCPU while the peak lasts.
- **Not applied:** the owner chose to stop load testing at the analysis stage. It's the first item on the roadmap.

## ADR-018: Expand/contract migrations, a pre-sync backup, and a rollback-after-migration policy

2026-10-25 · Accepted · Label: RUN-LOCAL (stand-in) for expand + rollback; DESCRIBED for contract

**Context.** The black box runs migrations at startup, and "some are not backward compatible". In a canary, the first new pod migrates the shared database while the old version is still serving 90% of traffic. Rolling back the image does **not** roll back the schema.

**Decision.**
- **Policy: every release is backward compatible with the previous one (N-1).** Breaking changes are split across releases:
  1. **Expand:** add the new column or table, nullable or with defaults; the old code ignores it.
  2. **Migrate:** the new code writes both shapes, and the data is backfilled.
  3. **Contract:** drop the old shape, only in a release *after* every running version has stopped using it.
- **Platform enforcement:**
  - An Argo CD **PreSync hook takes a `pg_dump`** before every sync (on AWS: an RDS snapshot plus PITR). A sync cannot proceed without a fresh restore point.
  - Migrations take a session-level advisory lock on a direct connection (ADR-007), so concurrent pods never migrate twice.
  - The migration runner tolerates newer applied versions, so an *older* image starts fine on an expanded schema.
- **Rolling back after a migration:**
  - *After an expand migration:* rolling back the image is safe. The stable version keeps serving on the expanded schema. This is what evidence item 2 demonstrates.
  - *After a breaking migration shipped by mistake:* **fix forward**, because a forward fix loses no data.
  - **Restore is the last resort:** restore the pre-sync dump or use PITR. That carries an explicit data-loss window, from the backup time to the restore, and is covered in a runbook.

**Rejected alternatives.**
- *Down-migrations:* rarely tested and often lossy (a dropped column can't be "un-dropped" with its data). They give false confidence.
- *A separate migration Job before the rollout (Argo CD PreSync, or Helm hooks):* the right pattern *if* the app can run migrations on their own and skip them at startup. The black box runs them at startup, so this can't be assumed. It is recommended to the app team instead.
- *Blue/green with a database copy:* doubles database cost, and needs data sync for writes during cutover.

**Consequences.**
- Database safety becomes partly an **app-team contract** (N-1 compatibility), and code review must check it. The platform makes violations recoverable, but it can't make them impossible.
- Every deploy costs a `pg_dump`. That is cheap at this size; at scale, use snapshots or PITR instead.

## ADR-019: Backups: logical dumps locally, RDS PITR on AWS, and a scripted restore drill

2026-10-25 · Accepted · Label: RUN-LOCAL (stand-in) for dumps and the restore drill; NOT RUN for AWS

**Context.** The brief asks for backups *and* a restore test. A backup that has never been restored is a hope, not a backup. Releases also run migrations at startup that may not be backward compatible (ADR-018), so a restore point must exist right before every sync, not just on a timer.

**Decision.**
- **Local (CloudNativePG):**
  - An **hourly `pg_dump -Fc` CronJob** (24 kept), plus the **Argo CD PreSync hook** dump before every sync.
  - Both write to the **provider-layer volume `pg-backups`**. Terraform creates it, so no chart sync or hook policy can ever delete it (evidence of why: Task 16, ADR-018).
  - Next to each dump the job writes a **`.counts` file**: the row count and an md5 of the `items` table, computed at backup time. That's the restore test's oracle.
- **Restore drill: `scripts/restore-test.sh <ns>`.** It takes a fresh backup with the stack's own CronJob, creates a **throwaway CNPG cluster** in the same namespace, runs `pg_restore` from the backup volume, recomputes the count and md5, and prints `RESTORE PASS rows=… md5=… rto_seconds=…`. It never touches the live database.
- **Valkey (the queue):** AOF persistence (`everysec`), so a crash loses at most about 1 s of enqueues. It isn't dumped: queue contents are in-flight work, not records. On AWS, ElastiCache Multi-AZ with 7 daily snapshots.
- **AWS (NOT RUN):**
  - RDS **automated backups with point-in-time restore, 14 days**, replicated to `eu-west-1` (same residency zone), Multi-AZ, deletion protection, and a final snapshot on delete.
  - The pre-sync restore point is a manual RDS snapshot, or simply a PITR timestamp: the sync time from Argo CD history.

**Rejected alternatives.**
- *CNPG Barman backups to object storage:* the right choice for CNPG in production (continuous WAL archiving, PITR). Locally it needs MinIO as one more component, and on AWS RDS replaces CNPG anyway.
- *Velero volume snapshots:* kind's local-path storage has no snapshot support. And a crash-consistent volume copy is harder to verify than a logical dump.
- *Restoring over the live database as the test:* destructive, and it measures nothing the scratch-cluster drill doesn't.

**Consequences.**
- **RPO, local:** at most 1 hour, or the time since the last deploy if that's shorter. **RPO, AWS:** about 5 minutes (PITR).
- **RTO measured locally: 34–43 s** (prod 38 s), mostly creating the new instance (evidence 04). That's for the stand-in's 1,000 rows. Real RTO scales with data size: a logical restore of tens of GB, plus index builds, takes tens of minutes, and an RDS PITR to a new instance takes 10–30 minutes. One restore uses most of a 99.95% SLO's 30-day error budget (21.6 min). That's why restore is the last resort and fix-forward the default (ADR-018).
- **Same failure domain, locally:** the dumps live on the same laptop disk as the database. On AWS the backups are in a separate service, and **cross-region replicas stay inside the EU**: `aws_db_instance_automated_backups_replication` copies each RDS instance's automated backups (PITR) to `eu-west-1` under a CMK in that region (`infra/modules/aws/stack-data`, NOT RUN).
- **Known gap:** `.counts` is computed in a separate transaction just after the dump. With concurrent writes it can differ from the dump's snapshot. The stand-in's `items` table is read-only, so this holds today. For the real app: `pg_dump --snapshot` on an exported snapshot, and the counts taken inside that same snapshot.
- The drill runs by hand today. **Scheduling it weekly** (a CronJob or a CI job, alerting on `RESTORE FAIL`) is on the roadmap.

## ADR-023: SLOs on edge SLIs with multi-window, multi-burn-rate alerts

2026-10-25 · Accepted · Label: RUN-LOCAL (stand-in)

**Context.** The brief sets targets of 99.9% availability for the shared stack and 99.95% for dedicated tenants, with p95 < 400 ms, alerts and per-tenant visibility.

**Decision.**
- **SLIs from Traefik, per stack.**
  - Availability: share of requests that are not 5xx.
  - Latency: share of requests answered within ≤ 400 ms. This is exact, because Traefik's histogram has a 0.4 s bucket.
- **Recording rules** over 5m, 30m, 1h, 6h and 3d windows, labelled with `namespace`, `stack` and `tier`.
- **Error budgets:** 99.9% gives 43.2 min per 30 days; 99.95% gives 21.6 min.
- **Alerts** (Google SRE workbook): page at a **14.4×** burn over 1h AND 5m (2% of the monthly budget gone in an hour) or **6×** over 6h AND 30m; open a ticket at **1×** over 3 days. Both SLIs are covered, and every alert links its runbook.

**Rejected alternatives.**
- *Static thresholds ("5xx > 1% for 5 min"):* these page on short blips that don't threaten the SLO and miss slow burns that do. They are not tied to the budget.
- *Single-window burn-rate alerts:* the long window alone is slow to reset after recovery; the short window alone is noisy. The AND of both windows gives fast detection *and* fast reset.
- *SLIs from app metrics:* unknown in the black box, and not uniform across tenants.

**Consequences.**
- Locally, Prometheus keeps only 12 h, so the 3d windows compute over whatever data exists. The design is correct, but the local data is truncated (labelled).
- Synthetic traffic is included in the local SLIs, since it is almost all the traffic there is. Production would split it out using Traefik's `synthetic` header label.

**Revised 2026-10-26: latency gets its own objective, and causes get alerts.**
- The latency burn-rate alerts had reused the availability objective (99.9%), which in effect demanded **p99.9** < 400 ms. The brief asks for **p95** < 400 ms, i.e. at least 95% of requests within 400 ms. Latency now uses `slo.latencyObjective: 0.95` (a 5% budget), and availability keeps 99.9 / 99.95.
- Two **cause alerts** back the runbooks that had no alert behind them:
  - `ZdpQueueBacklog` (page): oldest job > 300 s for 5 min.
  - `ZdpDbPoolWaiting` (ticket, local only): PgBouncer max wait ≥ 1 s for 5 min.
- They are deliberately not budget-based: they point at the broken part early, and the burn-rate alerts still page when users feel it. `docs/slos.md` has the full alert table.

## ADR-017: A dedicated tenant gets its own namespace and data services on a shared regional cluster

2026-10-25 · Accepted · Label: RUN-LOCAL (stand-in) / DESCRIBED (dedicated node pools on AWS)

**Context.** The brief requires one shared stack plus dedicated per-tenant stacks from one template; a new tenant in < 30 minutes through one reviewed change; 99.95% availability for dedicated tenants; EU data that stays in the EU; and a $9k/month budget.

**Decision.**
- **Dedicated tenant:**
  - its own namespace (`tenant-<name>`);
  - its own Postgres, PgBouncer and Valkey, created by the provider layer;
  - its own app release, using the same `charts/app` chart;
  - its own SLO rules (99.95%) and its own place in the rollout rings;
  - on AWS (DESCRIBED), a tainted Karpenter NodePool per tenant, for compute isolation.
- **Shared tenant:** a host route plus per-tenant SLO rules on the shared prod stack (`charts/tenant-route`).
- **Placement:** each tenant lands on a regional cluster in its residency zone.
- **Onboarding:** one file in `tenants/` drives everything, gated by `policy/tenants.rego`.

**Rejected alternatives.**
- *A cluster per dedicated tenant as the default:* the strongest isolation, but each cluster adds a $73/month control plane plus system nodes, a separate upgrade cycle, and its own Argo CD and monitoring stack. Under a $9k budget that caps the fleet at a handful of tenants. It is kept as an option for tenants who contractually require it.
- *Namespace-only isolation that shares databases:* cheap, but one tenant's load or migration affects others, and per-tenant residency and backups become impossible to guarantee.
- *Separate charts for shared and dedicated:* the two would drift apart. The brief explicitly asks for one template.

**Consequences.**
- Dedicated tenants share the Kubernetes control plane and ingress with others in the region, so a cluster-level incident affects them all. The 99.95% target relies on Multi-AZ data services, PDBs, topology spread and ring-ordered rollouts.
- Cost per dedicated tenant is mostly its database and cache (see `docs/cost.md`).

**Revised 2026-10-26 (independent review): the tenant node pool is now wired.** The pool was a hand-written example (`tenant-acme`), and no app pod could land on it because the chart set no tolerations or nodeSelector. Now `charts/app` renders `NodePool tenant-<name>` when `nodePool.enabled` (set for every dedicated tenant by the AWS ApplicationSet), and pins the tenant's api and worker pods to it. On AWS, onboarding stays one tenant file. Workers of the env stacks go to the spot pool the same way. NOT RUN; render-tested.

## ADR-014: Supply chain: GHCR, Trivy, keyless Cosign with SBOM attestation, and the chart promoted as an OCI artifact

2026-10-25 · Accepted · Label: RUN-LOCAL (GitHub Actions)

**Context.** The brief requires "build once, scan, sign, promote the same artifact by digest". The design review also found that a chart change (probes, PDBs, analysis) would otherwise bypass every gate, because all stacks read the chart from the same branch.

**Decision.**
- **Build and publish.** One image per commit is built once and pushed to **GHCR**. From that point it is referenced only as `repository@sha256:…`; the chart's values schema rejects anything else.
- **Scan.** **Trivy** scans that digest and fails the run on fixable HIGH/CRITICAL findings. It also generates a **CycloneDX SBOM**.
- **Sign.** **Cosign keyless**: GitHub's OIDC token gets a short-lived Fulcio certificate bound to `…/release.yml@refs/heads/main`, the signature goes to Rekor, and the SBOM is attached as a signed attestation.
- **Chart.** The chart is packaged as `0.1.<run>`, pushed to `oci://ghcr.io/…/charts` and signed too. **Release files pin both** the chart version and the image digest, so chart changes are promoted and gated exactly like code.

**Rejected alternatives.**
- *Key-based Cosign:* someone has to guard the private key (KMS, rotation). Keyless ties a signature to *which workflow on which branch* produced it, which is the property we want to verify.
- *Notation/Notary v2:* a smaller ecosystem, and it needs a key and a trust store.
- *ECR:* AWS-specific, so not portable. GHCR is reachable from every target. An ECR pull-through cache is on the roadmap for in-region pulls.
- *Retagging promoted images (`:staging`, `:prod`):* tags move, so the "same artifact" guarantee is lost. Digests are immutable.
- *Charts read straight from Git:* any chart edit would reach every stack within one sync, bypassing the gates.

**Consequences.**
- The repo identity is recorded in the public Rekor log, which is fine for a public repo.
- Enforcing signatures at admission (Kyverno `verifyImages` with the same identity regex as `config/platform.env`) is P1. Until then the signature is verifiable (`cosign verify`) but not enforced.

## ADR-015: Promotion by digest via release-file commits, gated by read-only checks on a self-hosted runner

2026-10-25 · Accepted · Label: RUN-LOCAL

**Context.** The brief requires promotion through dev → staging → production with gates based on real metrics, a rollout order of shared first, then dedicated rings, then regions, and a halt on failure. The pull model (ADR-010) means CI never deploys. And the metrics live in a cluster on a laptop that GitHub-hosted runners can't reach.

**Decision.**
- **A promotion is a commit.** `bump-release.sh` writes `gitops/releases/<stage>.yaml` (chart version + digest) using a write deploy key that bypasses the ruleset. Argo CD pulls it, and Argo Rollouts runs the canary with its own in-cluster analysis.
- **A gate is a read-only check.** `gate.sh` runs on a **self-hosted runner on the laptop** with a `view`-level ServiceAccount. It confirms:
  - the stack is synced at that chart version;
  - both Rollouts completed on that exact digest;
  - the stack's own edge SLIs over a soak window, a 5xx ratio under 0.5% and p95 under 400 ms;
  - the oldest job in the queue is under 120 s.

  No data is a failure.
- **Order:** dev → staging → **production approval** (GitHub Environment) → prod ring 0 (shared stack, and so its shared tenants) → ring 1 (acme) → ring 2 (globex). Rings are ordered by region on AWS. Any failed gate fails the workflow, and later rings never receive the release.

**Rejected alternatives.**
- *Kargo:* the purpose-built GitOps promotion tool (Freight, Stages, verification). It's the most "correct" option, but it adds a fourth control plane to operate and learn inside the time box. It's on the roadmap.
- *Argo CD Image Updater:* writes tags back to Git, and gating between environments is weak.
- *Gates in GitHub-hosted CI:* they can't reach the laptop's Prometheus without exposing it publicly, which is worse than a runner that only dials *out*.
- *Pipeline push to the cluster:* rejected in ADR-010.

**Consequences.**
- A self-hosted runner on a public repository is a known risk. It is mitigated by: approval required for fork workflows; the runner label used only by `release.yml` on `push`/`workflow_dispatch`; read-only cluster credentials, verified by `runner-up.sh`.
- In the cloud, the same role is played by Actions Runner Controller in each cluster.
- Promotion depends on GitHub (Actions, GHCR, the repo). If GitHub is down, nothing new is released, but running stacks keep serving.

## ADR-022: AWS reference implementation on terraform-aws-modules (NOT RUN)

2026-10-25 · Accepted · Label: NOT RUN (static validation only)

**Context.** The provider/platform split (ADR-003) is only credible if a second provider implementation of the same contract exists. The AWS code will not be applied (ADR-001), but it must be complete enough to plan from, and correct enough to pass validation and security scanning.

**Decision.**
- **Bootstrap:** an S3 state bucket (versioned, encrypted with a customer-managed KMS key, TLS-only, logged), a GitHub OIDC deploy role, and an EU-region permissions boundary.
- **Network and cluster:** `terraform-aws-modules/vpc` (3 AZs, NAT per AZ, flow logs) and `terraform-aws-modules/eks` (private endpoint, Pod Identity, Karpenter submodule).
- **Per-stack data, using raw resources:** RDS PostgreSQL Multi-AZ with 14-day PITR and backups replicated *within the residency zone*; ElastiCache for Valkey (Multi-AZ, TLS); Secrets Manager holding the same three keys; in-cluster PgBouncer.
- **Platform:** the same platform Applications with `values/aws`, plus Karpenter NodePools and over-provisioning.
- **Validation:** `terraform validate`, tflint and trivy in CI.

**Rejected alternatives.**
- *Hand-written VPC and EKS resources:* hundreds more lines to defend for code that is never applied. The community modules are the de facto standard, and reviewers know them.
- *Community modules for RDS and ElastiCache too:* those resources are small, and writing them out keeps every security-relevant setting (Multi-AZ, encryption, PITR, force_ssl) visible in review.
- *CDK or Pulumi for AWS:* a second IaC language and toolchain next to Terraform.
- *IRSA for workload identity:* it needs an OIDC trust policy per service account. EKS Pod Identity is simpler to manage in Terraform.

**Consequences.**
- Static validation cannot prove IAM sufficiency, quotas, or the availability of instance types and engine versions; those are assumptions (`evidence/08-aws-static/README.md`).
- Node egress to 0.0.0.0/0 is an accepted Trivy finding, with its reason in `.trivyignore.yaml`.
