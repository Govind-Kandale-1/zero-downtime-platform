# Zero-Downtime Multi-Tenant Platform — Design

Date: 2026-10-25 · Status: draft for approval · Source brief: `Senior_DevOps_Assignment.pdf`

## 1. Intent

A Senior DevOps take-home: an automated, cloud-agnostic platform that provisions infrastructure, deploys a black-box application through a multi-stage pipeline with zero downtime, autoscales to 15x, and supports one shared stack plus dedicated per-tenant stacks from one template.

The person submitting it must defend every line in a 60-minute review. They want to understand the architecture and the reasoning, not hand-write code. So the documentation (decision log, per-folder code reviews, interview Q&A) matters as much as the code. Graders explicitly evaluate **what is built versus what is only described**, and anything not actually run must be labelled.

## 2. Goals

1. Everything in the brief's "Items to Cover" is either **built and run locally** or **written and clearly labelled NOT RUN**, with no silent gaps.
2. One command takes an empty laptop (with Docker running) to a running platform. No manual cluster steps.
3. Produce the four evidence items: deploy under load with zero errors, automatic rollback of a bad release, the 15x load test, and a restore test.
4. Write documentation that lets the submitter answer "why?" and "what breaks?" for every component.

## 3. Non-goals

- Running anything in AWS. The AWS Terraform is written and statically validated only (user decision, 2026-10-25).
- Rewriting or modelling the real application. The stand-in implements only the black-box contract.
- Production-grade hardening beyond what a reviewer would expect to see named and partially shown (e.g. no HSM, no multi-cluster Argo CD hub).
- Building the change-request stack (a second cloud with US-West plus US-East failover) before it is released. Section 13 covers that.

## 4. Anti-goals (failure even if it "works")

- Any result that looks real but was not run. Every evidence artifact and README row carries one of `RUN-LOCAL`, `RUN-LOCAL (stand-in)`, `NOT RUN (static validation only)` or `DESCRIBED`.
- Claiming laptop throughput numbers as production capacity. Laptop runs prove *mechanisms* (scaling reaction time, zero errors, rollback). Capacity is derived in `docs/capacity.md` and labelled as such.
- A tool added without a decision record. Every component has an entry in `decisions.md` with rejected alternatives.
- Docs that drift from the code. Each `code-review.md` describes what is actually in its folder.

## 5. Constraints

| Constraint | Value |
|---|---|
| Host | Windows 11, i7-1360P (16 threads), 16 GB RAM, Docker Desktop on WSL2 with no `.wslconfig` (so WSL gets about 8 GB). Git Bash is available. |
| Installed tools | git, gh (authenticated as `Govind-Kandale-1`), terraform 1.14, helm 4, kind 0.30, kubectl. Not installed: k3d, k6 (run k6 via the `grafana/k6` Docker image). |
| Cluster memory budget | Total pod memory requests across the cluster must be ≤ 6.5 GB at the 15x peak. |
| Time | 8–10 h of assignment time over 3 days. |
| Brief targets | p95 < 400 ms. Availability 99.9% (shared) and 99.95% (dedicated). 150 → 2,250 req/s. 20,000 jobs/h (assumed to be the peak rate). EU tenant data stays in the EU. Budget $9k/month steady, $16k at peak. |
| Black box | API: port 8080, `/healthz`, `/readyz`, `/metrics`. The worker consumes a Redis queue with jobs up to 60 s. Postgres migrations run at API startup, and some are not backward compatible. |
| Load assumptions (my calls; the brief is ambiguous) | **20,000 jobs/h is the peak-hour rate.** The brief says "2,250 req/s peak (15x) with 20,000 jobs/hour". If it meant baseline, 15x would be about 83 jobs/s, or about 830 workers at 10 s each; `docs/capacity.md` shows that case too. The **average job duration of 10 s** is assumed (the brief gives only the 60 s maximum); capacity.md includes a sensitivity table for 5, 10, 30 and 60 s. |

## 6. Architecture overview

```
                    GitHub (repo + Actions + GHCR)
   PR ─► ci.yml (hosted): go test · helm lint/kubeconform · tf validate (local+aws)
                          tflint · trivy config · conftest tenant policy
   main ─► release.yml:  build ─► push by digest ─► trivy scan ─► SBOM ─► cosign sign+attest   (hosted)
                          └─► commit digest → gitops/releases/dev.yaml
                          gate-dev ─► staging ─► gate ─► [approval] ─► prod ring0 ─► gate ─► ring1 ─► gate ─► ring2
                          (gates run on a self-hosted runner on the laptop; they only READ metrics/rollout state)
                                          │ git commits only (no kubectl apply)
 ┌──────────────────────── kind cluster (laptop) ──────────────────▼───────────────────────────┐
 │ Argo CD (pull) ── app-of-apps ── platform apps ── ApplicationSets(tenants/*.yaml)            │
 │                                                                                              │
 │  Traefik ──weighted TraefikService──► api stable / api canary  (Argo Rollouts, analysis via  │
 │   (edge metrics = SLIs)                                          Prometheus)                │
 │  KEDA: api ← Prometheus RPS/pod · worker ← Valkey list length                                │
 │  Kyverno: verify cosign signature on admission · ESO ← OpenBao (local "secrets manager")     │
 │  kube-prometheus-stack: SLO recording rules, burn-rate alerts, per-tenant dashboards         │
 │                                                                                              │
 │  ns app-dev | app-staging | app-prod (shared, ring0) | tenant-acme (ring1, eu) | tenant-globex (ring2, us*) │
 │   each: api Rollout · worker Rollout · PgBouncer → CNPG Postgres · Valkey · pg_dump CronJob  │
 └──────────────────────────────────────────────────────────────────────────────────────────────┘
   Terraform state: Postgres container "tfstate" (pg backend, with locking), outside the cluster
   * regions are simulated locally with labels; real regions exist only in the AWS code (NOT RUN)
```

Three layers, matching the brief:

| Layer | Owns | Tool | Differs per provider? |
|---|---|---|---|
| Provider | cluster, network, databases + pooler, cache, secrets manager, state backend | Terraform | Yes. This is the only layer that does. |
| Platform | ingress, GitOps, progressive delivery, autoscaling, policy, secrets sync, observability | Argo CD apps (Helm) | Values overlays only (`values/local`, `values/aws`) |
| App | the API + worker per stack | one Helm chart `charts/app` | No |

### 6.1 Provider contract (the portability boundary)

Every provider implementation must deliver exactly these things. Platform and app layers depend only on this list:

1. A Kubernetes cluster and its kubeconfig.
2. For each **stack** (dev, staging, prod-shared, and each dedicated tenant):
   - a Postgres database;
   - a PgBouncer endpoint in transaction mode, at `pgbouncer.<namespace>.svc:5432`;
   - a Valkey endpoint.
3. A secrets manager holding, for each stack at path `stacks/<stack>/app`, the keys `DATABASE_URL` (through PgBouncer), `MIGRATION_DATABASE_URL` (direct to Postgres, for session-level advisory locks) and `REDIS_URL`.
4. A remote Terraform state backend with locking.

| Contract item | Local (RUN) | AWS (NOT RUN) |
|---|---|---|
| Cluster | kind: 1 control-plane + 2 workers, `tehcyx/kind` provider | EKS via `terraform-aws-modules/eks`, 3 AZs, managed system node group + Karpenter |
| Network | Docker `kind` bridge | `terraform-aws-modules/vpc`: 3 AZs, private subnets, NAT per AZ |
| Postgres | CloudNativePG `Cluster` (1 instance) + CNPG `Pooler` (PgBouncer) | RDS PostgreSQL Multi-AZ + in-cluster PgBouncer Deployment |
| Cache | `valkey/valkey` StatefulSet + `redis_exporter` sidecar | ElastiCache for Valkey, Multi-AZ replication group |
| Secrets | OpenBao in dev mode (in-cluster), written by the Terraform `vault` provider | AWS Secrets Manager, read by ESO through EKS Pod Identity |
| State | `backend "pg"` → `tfstate` Postgres container started by `scripts/up.sh` | `backend "s3"` with `use_lockfile = true`; bucket created by `infra/bootstrap/aws` (local state, chicken-and-egg documented) |
| Registry | GHCR (same for both) | GHCR (an ECR pull-through cache is noted in the roadmap) |

Terraform root layout: `infra/live/<target>/{10-cluster,20-data,30-gitops}`. AWS adds `infra/bootstrap/aws` and `infra/live/aws/eu-central-1/05-network`. `20-data` iterates over the env stacks plus every `tenants/*.yaml` whose `tier: dedicated`. The tenant YAML is therefore the single source for both Terraform and Argo CD.

`docs/non-portable.md` lists what is not portable: the database HA/backup mechanism, IAM (Pod Identity vs none), LB annotations, node autoscaling (Karpenter), the secrets-store backend, the state backend type, DNS/TLS, KMS, and the fact that Kyverno signature verification needs internet egress to Sigstore.

## 7. Stand-in application (Go)

**Language: Go (my call).** Its static binaries are about 15 MB in a distroless image, start fast (which helps the scale-up), and use very little CPU and RAM per pod. That headroom is what lets about 33 API pods plus about 60 workers fit within the laptop's ~8 GB. It also gives Trivy a near-empty image to scan.

There is one image with two binaries (`/api`, `/worker`), so one digest is promoted for both components.

**API** (`app/cmd/api`), contract surface:
- `:8080` routes:
  - `/healthz`: the process is alive.
  - `/readyz`: Postgres and Valkey are reachable and migrations are complete. Returns 503 once SIGTERM is received.
  - `/metrics`: request counter plus a duration histogram that includes a 0.4 s bucket.
  - `GET /api/items/{id}`: indexed SELECT.
  - `POST /api/jobs`: LPUSH a job carrying `enqueued_at` and a `duration_ms`.
  - `GET /version`.
- Startup: run embedded SQL migrations under `pg_advisory_lock`, using `MIGRATION_DATABASE_URL`. Record them in `schema_migrations`.
- Shutdown on SIGTERM: set not-ready → wait `SHUTDOWN_DELAY` (5 s) → `http.Server.Shutdown` (20 s).
- **Bounded concurrency, to model a real app's capacity without burning laptop CPU:**
  - `MAX_INFLIGHT` (default 8) caps concurrent requests per pod.
  - `WORK_LATENCY_MS` (default ~40 ms, slept, not CPU-spun) is added to each item read.
  - Per-pod capacity is therefore about `MAX_INFLIGHT / latency` (~100 req/s). Above it, requests queue and p95 climbs, so scaling out is genuinely needed to hold p95 < 400 ms, as with a real app's thread pool. Total CPU stays proportional to req/s, not to pod count.
- Demo-only fault injection (labelled stand-in-only): `FAULT_ERROR_RATE` and `FAULT_LATENCY_MS`.
  - The env vars override a **compiled-in default**.
  - The "bad release" is a real commit that changes that default to 0.3, i.e. a code bug. It therefore travels through the pipeline as a new digest, like any release.
  - The fix is a follow-up commit.
- Migrations shipped:
  - `0001` creates and seeds `items`.
  - `0002` is an **expand** step that adds a nullable column. It ships with the "bad release" so the demo shows rollback after a migration. Migrations are forward-only, so the fix release keeps `0002`. It is never deleted from the code.
  - The **contract** step is described in the runbook, not shipped.

**Worker** (`app/cmd/worker`):
- Reliable queue: `BLMOVE jobs → jobs:processing:<pod>`. Process the job by sleeping `duration_ms`, then `LREM` it. On failure, push it to `jobs:failed`.
- Each worker keeps a heartbeat key with a 30 s TTL. A reaper, guarded by a `SET NX` lock, re-queues the processing lists of dead pods. This gives **at-least-once** delivery.
- SIGTERM: stop claiming, finish the current job (≤ 60 s), exit 0.
- Stand-in-only `/metrics` on `:9090`: `jobs_processed_total{result}`, `job_duration_seconds`, and `queue_oldest_job_age_seconds` (read with `LINDEX` on the oldest item's `enqueued_at`).

**Labelling rule:** the README says which behaviours are *assumptions about the real black box* that the stand-in makes true. These are SIGTERM draining, advisory-locked migrations, a separate migration URL, enqueue timestamps, and idempotent jobs. Each runbook says what to do if the real app lacks one.

## 8. Delivery: pipeline, GitOps, promotion

### 8.1 CI (GitHub-hosted runners)

- `ci.yml` (PR):
  - `go vet/test`;
  - `helm lint` + `helm template | kubeconform` for every stack;
  - `terraform fmt -check` + `init -backend=false` + `validate` for local and AWS roots;
  - `tflint`;
  - `trivy config`;
  - `conftest` on `tenants/*.yaml`.
- `release.yml` (push to `main` touching `app/` or `charts/`):
  1. buildx build → push to GHCR → capture the **digest**;
  2. `trivy image`, failing on fixable CRITICAL/HIGH;
  3. CycloneDX SBOM;
  4. `cosign sign` keyless (GitHub OIDC → Fulcio/Rekor);
  5. `cosign attest` the SBOM;
  6. `helm package charts/app` with version `0.1.<run_number>` → `helm push` to `oci://ghcr.io/<owner>/charts` → cosign-sign the chart artifact;
  7. commit **both** the image digest and the chart version to `gitops/releases/dev.yaml`.

  The image is rebuilt only when `app/` changed. A chart-only change reuses the digest currently in `dev.yaml` and publishes just a new chart version.

  Downstream jobs never rebuild. They reference only the digest and the chart version. **The chart is promoted with the image** (my call, from the builder check). Without this, a change to probes, PDBs or analysis templates would reach every stack in one sync and bypass the gates.
- Actions are pinned by commit SHA. The workflow has `id-token: write` only where signing happens.

### 8.2 GitOps (Argo CD, pull)

- Terraform root `30-gitops` installs Argo CD with `helm_release` and applies the root Application (app-of-apps) pointing at `gitops/clusters/local/`. From then on, everything in-cluster is reconciled from Git.
- `gitops/clusters/<cluster>/` lists the platform apps and which provider values to use. Sync waves install CRDs and operators before their consumers.
- Each stack's Application uses multi-source:
  - the chart comes from the GHCR OCI repo, at the `chart.version` pinned in its **release file** `gitops/releases/<stage>.yaml`;
  - the values are `gitops/stacks/<stack>.yaml` plus that same release file, which also holds `image.repository` and `image.digest`.

  Suggested mechanism (the builder may choose another): ApplicationSets whose generators read the release file, so `targetRevision` is filled from it. Per-stack values files remain intentionally per-stack and are not gated.
- Release files: `dev`, `staging`, `prod-ring0`, `ring1`, `ring2`. A dedicated tenant's YAML names its ring, so it picks up that ring's release file.
- Reconciliation interval is 60 s. Self-heal is on for platform and app resources, which covers Kubernetes drift. Tenant Applications are created with `preserveResourcesOnDeletion`, so deleting a YAML never drops a database.

### 8.3 Promotion gates ("gates based on real metrics")

There are two levels of gate:

1. **In-cluster, per stack:** the Argo Rollouts AnalysisTemplates in §9 run against Prometheus during every canary step and abort automatically.
2. **Pipeline, between stages:** gate jobs run on a **self-hosted runner** (a container on the laptop, registered automatically through the `gh` API, label `local-kind`, with a read-only kubeconfig). Each gate checks four things:
   - (a) the Argo CD app is Synced and Healthy;
   - (b) the Rollout finished at the **expected digest**, verified from the pod spec;
   - (c) the SLI soak passed: error ratio < 0.5% and p95 < 400 ms over 5 min for that stack (3 min locally), queried from Prometheus;
   - (d) the worker queue age is < 120 s.

   If the gate passes, it commits the digest to the next release file. If it fails, the job fails and **later stages never run** (halt on failure).

**Synthetic traffic** (my call, from the builder check). Canary analysis with no traffic returns *inconclusive*, and Argo Rollouts pauses on that. One small platform Deployment (`synthetic-traffic`, ≤ 32 MB) therefore sends a constant ~10 req/s plus ~1 job per 10 s to every stack and shared-tenant host. This is standard practice: a canary needs traffic, and synthetic probes double as black-box monitoring.
- The analysis templates keep a minimum-request-count guard.
- Synthetic requests carry a header so dashboards can split them out.
- On AWS, real traffic plus the same probes would apply.

The order is dev → staging → **manual approval** (GitHub Environment `production`) → prod-ring0 (the shared stack) → ring1 → ring2. In AWS this extends to "then regions": EU rings, then US rings. Locally, regions are simulated by namespace labels. Self-hosted jobs run only on `push`/`schedule`/`workflow_dispatch`, never on fork PRs.

## 9. Deployment strategy

### API: canary (Argo Rollouts + Traefik weighted `TraefikService`)

- Steps: 10% → analysis 2 min → 25% → 2 min → 50% → 2 min → 100%. Local demo values shorten each pause to 1 min.
- Analysis uses **edge metrics from Traefik**, per canary vs stable Service, because the app is a black box:
  - success rate ≥ 99%;
  - p95 ≤ 400 ms (Traefik is configured with custom histogram buckets that include 0.4 s);
  - 1-minute interval, `failureLimit: 1`;
  - inconclusive below a minimum request count.
- Failure → abort → 100% back to stable. The canary ReplicaSet is scaled down.
- Rejected: **blue/green**, because it doubles 2,250 req/s worth of capacity during the cutover, and the DB schema is shared anyway. **Plain rolling**, because it has no traffic control and no metric gate.

### Worker: gated rolling (Argo Rollouts canary *without* traffic routing, i.e. replica-weighted)

- Steps: 25% of replicas → analysis 3 min → 50% → 3 min → 100%.
- Analysis checks: job failure ratio ≤ 2%, `queue_oldest_job_age_seconds` < 120, and no CrashLoopBackOff.
- This is still a rolling update in spirit (your decision), but implemented through Rollouts so the worker also gets **automatic abort**. A plain Deployment has none.
- `terminationGracePeriodSeconds: 90`, so the 60 s maximum job finishes. This applies to KEDA scale-in too, not just rollouts.

### Zero-downtime mechanics (both)

- startupProbe (generous, because migrations run at boot) → readinessProbe `/readyz` → livenessProbe `/healthz`.
- API: `preStop` sleep 5 s so Traefik deregisters the pod before it drains.
- PDBs: `maxUnavailable: 1`. Topology spread across nodes (zones on AWS).
- Pod Security `restricted`: non-root, read-only root FS.
- NetworkPolicies: default deny, then explicit allows.

### Database migrations

- **Policy:** every release must be backward compatible with N-1, i.e. expand/contract. A destructive change (contract) ships only when N-1 no longer uses the object.
- **Platform enforcement:**
  - an Argo CD PreSync hook Job takes a `pg_dump` (locally) / RDS snapshot (AWS) before any app sync that changes the image;
  - migrations use the direct URL under an advisory lock, because PgBouncer transaction mode breaks session-level advisory locks.
- **Rollback after a migration:** rolling back the image does not roll back the schema.
  - After an expand migration, rollback is safe. This is what the demo shows.
  - After a mistaken breaking migration, fix forward. Restoring from the pre-sync dump or point-in-time recovery is the last resort, with an explicit data-loss window.
  - The runbook covers both cases.

## 10. Autoscaling and capacity (`docs/capacity.md`)

- **API:** KEDA ScaledObject → Rollout.
  - Prometheus trigger: Traefik RPS per stack, threshold **70 req/s per pod**. A CPU trigger at 70% acts as a safety net.
  - Min 3, max 40 (prod).
  - Scale-up: no stabilization window; +100% or +8 pods per 15 s.
  - Scale-down: 300 s stabilization, −20% per 60 s.
- **Per-pod capacity is measured, not assumed.** A k6 step test against one pod finds the highest req/s that still keeps p95 < 400 ms. With the stand-in's bounded concurrency (§7), expect about 100 req/s at about 50m CPU.
  - The KEDA threshold is set to 70% of the measured value. "70 req/s" is a placeholder until then.
  - `max` replicas, the connection math and the memory budget are all **recomputed from the measured number** with the formulas in capacity.md, not hard-coded.
  - Reference arithmetic: 150/3 = 50 req/s per pod at baseline; 2,250/33 ≈ 68 req/s per pod at peak.
  - Pod requests are small (e.g. 50m CPU / 32 Mi) because CPU tracks total req/s, not pod count. That keeps about 33 pods within the laptop budget.
- **Worker:** KEDA Valkey/Redis list trigger on `jobs`, `listLength: 5`. Min 2, max 120 (prod). The local cap is set to fit the memory budget and labelled.
  - Little's law: λ = 20,000/3,600 = 5.56 jobs/s. A 10 s average job needs about 56 concurrent workers. If every job took the full 60 s, it would need about 333.
  - Sizing uses the average. The 90 s grace period covers the maximum.
- **Scale-up timeline to 15x** (documented; local measured where possible):

  | Step | Time |
  |---|---|
  | KEDA poll | 10 s |
  | HPA sync | 15 s |
  | Pod start, image cached | ~5 s |
  | Readiness | ~5 s |
  | Node provisioning on AWS (Karpenter, NOT RUN) | ~60–90 s |

  This is well under 5 min. Low-priority "pause pod" overprovisioning absorbs the first burst on AWS.
- **Database limits:**
  - Client connections: 40 API pods × 10 + 120 workers × 2 = 640 connections into PgBouncer, which multiplexes them onto `default_pool_size` ≈ 40 server connections. Postgres `max_connections` is 200.
  - Query rate: ~4,500 qps at peak (assume 2 queries per request) on one writer.
  - The doc shows the instance class that sustains this (AWS), and flags the single writer as a top risk.
  - Valkey: not a bottleneck (≈ 10k ops/s vs a ~100k ceiling).
- Node scaling locally uses pre-provisioned capacity (fixed kind nodes). Karpenter is described and coded for AWS, NOT RUN.

## 11. Multi-tenancy

- `tenants/<name>.yaml`:
  - `name`
  - `tier: shared|dedicated`
  - `residency: eu|us|none`
  - `region`
  - `ring`
  - `size: small|medium`
  - `slo: 99.9|99.95`
- **Dedicated** tenant gets its own namespace, its own Postgres + PgBouncer + Valkey (from Terraform `20-data`), its own app release (`charts/app`, via ApplicationSet), and its own SLO rules.
  - AWS design: a dedicated Karpenter NodePool (tainted) on a shared regional cluster. Cluster-per-tenant is the rejected default, reserved for contractual need. It costs a $73/month control plane per tenant and adds an upgrade burden.
- **Shared** tenant gets a host-based Traefik IngressRoute on the shared prod stack (chart `charts/tenant-route`, via a second ApplicationSet). Traefik router metrics then give **per-tenant visibility without changing the black box**.
- **Onboarding = one reviewed PR** adding a YAML file:
  1. CI runs conftest and a render check.
  2. On merge, a self-hosted job runs `terraform apply` on `20-data`.
  3. The ApplicationSet creates the app, and ESO syncs secrets.

  Target < 30 min. Expected local ≈ 5 min; AWS estimate ≈ 20 min, dominated by RDS Multi-AZ creation. The timing is recorded as evidence.
- Branch protection with CODEOWNERS on `tenants/`. The "review" constraint for a solo account is documented: the owner can't approve their own PR, so an admin merges after the checks pass.
- **EU residency is enforced, not just documented:**
  - conftest rejects `residency: eu` with any non-EU `region` (and the same for backup regions);
  - Terraform derives each tenant's provider region from its YAML;
  - AWS backups and snapshot copies stay in EU regions;
  - a sample SCP denying non-EU regions is documented (it needs AWS Organizations, so it is NOT RUN);
  - locally, a Kyverno policy checks namespace labels.
- Local fleet: `tenant-acme` (dedicated, eu, ring1) and `tenant-globex` (dedicated, us-simulated, ring2), plus one shared tenant `initech` on the shared stack.

## 12. Operations

- **SLIs** from Traefik per stack/tenant:
  - availability = non-5xx / total;
  - latency = share of requests under 400 ms.
- **SLO recording rules and multi-window burn-rate alerts** in the chart's PrometheusRule. Targets come from values (99.9 → 43.2 min/30 d budget; 99.95 → 21.6 min).
  - Page: 14.4× over 1 h AND 5 min.
  - Page: 6× over 6 h AND 30 min.
  - Ticket: 1× over 3 d.
- **Grafana dashboards:**
  - Fleet overview, per tenant: RPS, error ratio, p95, error budget left, queue depth/age, replicas, PgBouncer/CNPG connections.
  - Rollouts.
- **Alertmanager** routes by severity and tier. Locally it uses a webhook receiver that logs (labelled).
- **Runbooks** in `docs/runbooks/`: canary aborted, burn-rate page, queue backlog, DB connection saturation, rollback after migration, restore from backup, failed tenant onboarding, drift detected.
- **Backups:**
  - Local: hourly `pg_dump -Fc` CronJob per stack to a PVC with retention 24 (RPO ≤ 1 h).
  - AWS (NOT RUN): RDS automated backups + PITR (RPO ≈ 5 min). Snapshot copy within the residency zone (eu-central-1 → eu-west-1; us-east → us-west).
- **Restore test:** `scripts/restore-test.sh <stack>`.
  1. Restore the latest dump into a fresh CNPG cluster.
  2. Verify row counts and checksums recorded at backup time.
  3. Print the RTO.
  4. Tear down.

  A weekly CronJob version is documented.
- **Drift:**
  - Infrastructure: `drift.yml` runs nightly on the self-hosted runner. It does `terraform plan -detailed-exitcode` on the local roots; exit code 2 opens or updates a GitHub issue.
  - Kubernetes: Argo CD OutOfSync + self-heal, plus an alert.

## 13. Cost, roadmap, change request

- `docs/cost.md`: AWS eu-central-1 on-demand prices with the date and source cited.
  - Covers steady state and peak for shared prod, non-prod, and N dedicated tenants.
  - Shows headroom against $9k/$16k and **how many dedicated tenants fit in the budget**.
  - Calls out the cost drivers: NAT gateways, cross-AZ traffic, Multi-AZ RDS, observability.
- `docs/roadmap.md`: a 90-day plan, built from the NOT RUN items: run AWS, Karpenter, a real second region, Kargo evaluation, ECR pull-through, a multi-cluster Argo CD hub.
- **Change request** (released 24 h after start): design and write `docs/addendum-change-request.md` (one page) once it arrives. The provider contract (§6.1) is the extension point: a third provider directory, e.g. `infra/modules/azure`. Any infrastructure written for it is labelled NOT RUN. This is a later phase, not part of the first plan.

## 14. Repository and documentation deliverables

```
app/            Go stand-in (cmd/api, cmd/worker, internal/, migrations/, Dockerfile)
charts/app      the one template for every stack;  charts/tenant-route
infra/          modules/{local,aws}/…, live/{local,aws}/…, bootstrap/aws
gitops/         clusters/, platform/ (apps + values/{local,aws}), stacks/, releases/, appsets/
tenants/        one YAML per tenant (drives Terraform + Argo CD)
policy/         conftest Rego (tenant schema + residency); Kyverno policies live in gitops/platform
.github/        workflows (ci, release, tenant-apply, drift), CODEOWNERS
load/           k6 scripts (step test, 15x ramp, steady-under-deploy) + job producer
scripts/        up.sh, down.sh, runner-up.sh, demo-*.sh, restore-test.sh  (bash, run from Git Bash)
docs/           architecture.md (≤5 pages), capacity, cost, slos, non-portable, roadmap, runbooks/, addendum
evidence/       one folder per evidence item: raw logs + a short README with its label
decisions.md  questions-answers.md  README.md  LICENSE
```

- **LICENSE** (user decision, 2026-10-25): a proprietary, evaluation-only notice with the user's exact text ("All Rights Reserved … evaluation purposes during the interview process with immverse …").
  - **No** open-source licence. Never let `gh repo create` add a licence template, and never alter the LICENSE text.
  - The README links to it.
  - decisions.md records it as an ADR. Rejected alternative: MIT or Apache-2.0, because they would grant reuse rights the user does not want to give.
  - Note for the user: GitHub's Terms of Service still let anyone view and fork a public repo *on GitHub*. The licence forbids any use beyond that.

- **decisions.md** (root): an ADR log. Each entry has ID, date, status, context, decision, rejected alternatives with reasons, consequences, and the label (RUN/NOT RUN). It is appended as decisions are made and seeded with about 18 decisions. `docs/architecture.md` links its five most important ones and the top 5 risks.
- **code-review.md** in every folder that contains code or config we wrote (not `docs/` or `evidence/`). Each has the folder's purpose, every file and what it does, key decisions (with ADR links), how to verify it, known limitations, and its RUN/NOT RUN label. Keep each to about 40 lines.
- **questions-answers.md** (root): grouped by the brief's sections. Each entry has the likely question, a 2–4 sentence answer, likely follow-ups, and where in the repo to point. It must include the "uncomfortable" questions:
  - Why trust laptop numbers?
  - What if the real app doesn't drain?
  - Rollback after a breaking migration?
  - Why not blue/green?
  - Why a self-hosted runner?
  - Single Postgres writer at 15x?
  - What happens when GitHub is down?
- **README.md**: quickstart, prerequisites, and a table with one row per brief item: built / described / label / evidence link.
- `.gitattributes` forces LF line endings for `*.sh`, `*.yaml`, `*.tf` and `*.go`. This matters because the host is Windows.

## 15. Evidence plan

| # | Evidence | How | Label |
|---|---|---|---|
| 1 | Deploy under load, zero errors | k6 at 150 req/s for the whole of a v1→v2 canary on prod-ring0; k6 summary shows 0 failed requests + rollout timeline | RUN-LOCAL (stand-in) |
| 2 | Automatic rollback | **Primary:** a bad commit (compiled-in fault default 0.3, plus migration `0002`) goes through the real pipeline. The dev canary at 10% fails analysis on synthetic traffic → auto-abort → `gate-dev` fails → staging/prod are never touched. One run shows both rollback and halt-on-failure. v1 keeps serving on the expanded schema. **Secondary (P1):** `scripts/demo-bad-release.sh` writes the bad digest straight into `prod-ring0` under k6 load to show the blast radius (~10% of requests for ~1 min). Labelled "demo shortcut, bypasses gates". | RUN-LOCAL (stand-in) |
| 3 | 15x load | k6 ramps 150 → 2,250 req/s over **3 min** (inside the brief's 5-minute window), holds 5 min, ramps down. A job producer runs at 5.56 jobs/s (mean ~10 s, max 60 s). **Pass** = replicas reach the computed target within 5 min of ramp start, 0 failed requests, p95 < 400 ms during the hold. Ramp p95 is reported but not gated. Job accounting: enqueued = done + failed, 0 lost. If the laptop saturates before 2,250 req/s, rerun the same 15x ratio from a lower base and label it "laptop-bound". The capacity extrapolation stays DESCRIBED. | RUN-LOCAL (stand-in) |
| 4 | Restore test | `restore-test.sh` log with row/checksum match and RTO | RUN-LOCAL |
| 5 | Supply chain | trivy report, `cosign verify` output, Kyverno rejecting an unsigned image | RUN-LOCAL |
| 6 | Tenant onboarding | timestamps from PR merge → Healthy | RUN-LOCAL |
| 7 | Drift | a drift run that opens an issue after a manual change | RUN-LOCAL |
| 8 | AWS IaC | `terraform validate` + tflint + trivy config output | NOT RUN (static validation only) |

The user may optionally screen-record items 1–3. Before item 3, non-prod stacks are scaled to minimum and heavy desktop apps should be closed.

## 16. Build priority (what's built versus described)

The 8–10 h figure is the brief's guidance for the submitter. It is treated as a **soft** box, not a hard cap: build in priority order and stop at a tier boundary (my call).

- **P0 (must run):**
  - stand-in;
  - chart;
  - local provider layer;
  - Argo CD + platform (incl. synthetic traffic);
  - release pipeline through dev/staging/prod-ring0;
  - canary + auto-rollback;
  - KEDA both triggers;
  - evidence 1–4;
  - decisions.md, questions-answers.md, code-review.md files, architecture.md, capacity.md and README at **full depth**. They are the user's learning material, so they are not thinned.
- **P0, written and NOT RUN:**
  - **lean** AWS Terraform (bootstrap, network, eks, rds, elasticache, secrets) using `terraform-aws-modules`;
  - its CI validation (evidence 8).

  It goes before P1 because the provider/platform split is only credible with a second provider implementation in the repo.
- **P1 (run if time allows):** rings 1–2 fleet promotion, Kyverno verification, tenant onboarding timing, drift workflow, per-tenant dashboards, secondary rollback demo, cost.md/roadmap.md/runbooks (written either way, at the end of P0 if P1 is cut).
- **Described / NOT RUN:** Karpenter behaviour, real regions, cross-region DR, SCPs, the change-request stack.

## 17. Left to the builder

- Exact pinned versions of every chart, image, provider and action. Use the current stable version at build time and verify each one. In particular, check whether Argo Rollouts' Traefik routing is native or a plugin in the pinned version.
- How to create CRD-backed resources from Terraform without plan-time CRD lookups (e.g. small local Helm charts or a kubectl-style provider).
- Exact resource requests, provided the cluster stays within the 6.5 GB memory budget at peak.
- Dashboard layouts, alert wording, k6 script structure, and the CI job split.
- Whether the self-hosted runner is persistent or ephemeral, provided registration is fully scripted.

## 18. Audience and parameterisation (my call)

- `scripts/up.sh` targets the user on this laptop and repo.
- Repo URL, GHCR owner and cosign signer identity live in **one file** (`config/platform.env`) and are templated from it. A reviewer could fork and change one file, but fork-friendliness is not otherwise engineered.
- The self-hosted runner is optional for bringing the platform up. Only the gate, tenant-apply and drift jobs need it.

## 19. Open items requiring the user

- **Resolved 2026-10-25 (user decision): public repo `Govind-Kandale-1/zero-downtime-platform`.** Consequences:
  - Branch protection on `main` + CODEOWNERS. The `production` GitHub Environment has a required reviewer; self-approval is allowed for a solo owner.
  - GHCR image and chart packages are public, so Argo CD, Kyverno and the kubelet pull with no credentials. *Builder: verify whether packages pushed with `GITHUB_TOKEN` from a public repo inherit public visibility. If not, flipping it is a one-time GitHub UI step: document it as the only manual step, or fall back to a pull secret.*
  - Self-hosted runner hardening:
    - repo setting requires approval for fork-PR workflows;
    - runner-labelled jobs run only on `push` / `schedule` / `workflow_dispatch`;
    - gate jobs use a read-only kubeconfig;
    - only `tenant-apply` and `drift` get write credentials for the local cluster.
  - Keyless signing writes the repo identity to the public Rekor log. That's acceptable, because the repo is public anyway.
- WSL2 memory allocation (`.wslconfig`, e.g. `memory=10GB`). This is a host setting the user changes, not the builder.
- AWS credentials: not needed (no AWS runs).

## Appendix A. Brief coverage checklist (condensed from the brief)

The README's coverage table has one row per line:

1. Cloud-agnostic IaC: provider layer (network, k8s, DBs, secrets) separate from platform/app; two targets; non-portable list.
2. Full automation: empty account → running with no console steps; remote state; drift detection; secrets manager.
3. Multi-stage pipeline: build once, scan, sign, promote the same digest dev → staging → prod; gates on real metrics.
4. Deployment strategy: justified choice for API and for worker; traffic steps, gating metrics, automatic rollback; GitOps vs push; rollout order shared → dedicated rings → regions.
5. Zero downtime: graceful shutdown, probes, PDBs, worker draining, expand/contract migrations, rollback after a migration.
6. Autoscaling: 15x in < 5 min and back, no dropped jobs, queue depth for workers, capacity maths, DB limits.
7. Multi-deployment: shared + dedicated from one template; new tenant in < 30 min via one reviewed change; fleet rollout with halt on failure; EU data stays in the EU.
8. Operations: SLOs 99.9 / 99.95, alerts, per-tenant visibility, runbooks, backups, restore test.
9. Cost and plan: steady + peak monthly estimate; 90-day roadmap.
10. Deliverables:
    - repo (README, IaC, pipelines, scripts);
    - architecture doc ≤ 5 pages (diagram, ≥ 5 decisions with rejected alternatives, top 5 risks);
    - evidence (deploy under load, auto-rollback, 15x, restore);
    - change-request one-page addendum (second dedicated stack on a different cloud, US-West with US-East failover).
11. Label everything not actually run.
