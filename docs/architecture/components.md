# Components: what, where, why

**Label:** local components RUN-LOCAL (running on kind); the "On AWS" column is NOT RUN. Versions are pinned in `config/versions.env`.

Each table answers: **runs in** (machine, container or namespace), **defined in** (the file that creates it), **purpose**, and **why this one** (the decision record).

## 1. Outside the cluster

| Component | Runs in | Defined in | Purpose | Why (ADR) | On AWS |
|---|---|---|---|---|---|
| **Git repository** | GitHub | this repo | The single source of desired state: app code, chart, platform config, tenant files, and the release files that pin what each stage runs | GitOps (ADR-010) | same |
| **CI** (`ci.yml`) | GitHub-hosted runners | `.github/workflows/ci.yml` | Six required checks on every PR: Go tests, chart render tests, policy tests, Terraform validate + tflint, IaC scan, shell lint + docs test. No cluster access | ADR-014 | same |
| **Release pipeline** (`release.yml`, `_promote.yml`) | GitHub-hosted runners (build, scan, sign, promote) | `.github/workflows/` | Builds the image **once**, scans it, signs it, packages the chart, then promotes the same digest stage by stage, waiting for each gate | ADR-014, ADR-015 | same |
| **GHCR** | GitHub | images: `ghcr.io/govind-kandale-1/zero-downtime-platform`; charts: `ghcr.io/govind-kandale-1/charts/app` | Stores the signed image and the chart as OCI artifacts, addressed by digest/version | ADR-014 | same (an ECR pull-through cache is on the roadmap) |
| **Environment `production`** | GitHub | repo settings | The human approval before prod (ring 0) | ADR-015 | same |
| **Ruleset `main-protection`** | GitHub | `scripts/repo-ruleset.sh` | PRs + 6 green checks for everyone; only admins and the release deploy key may push directly | ADR-020 | same |
| **Self-hosted runner** `zdp-runner` | Docker container on the laptop | `scripts/runner-up.sh`, `scripts/runner/` | Runs only the **gate** jobs: `scripts/gate.sh` reads Argo CD and Prometheus through a **read-only** kubeconfig (service account `ci-gate`). It can't deploy | ADR-015 | Actions Runner Controller in the cluster |
| **Terraform** | the laptop (Docker-wrapped tools) | `infra/` | Builds the provider layer: cluster, data services, secrets, Argo CD | ADR-003, ADR-004 | same code shape, `infra/live/aws` |
| **Terraform state DB** `zdp-tfstate` | Docker container (Postgres 18.6) on the laptop | `scripts/state-up.sh` | Remote state with locking (`backend "pg"`), outside the cluster it describes | ADR-004 | S3 with native lockfile |

## 2. Provider layer (created by Terraform)

| Component | Runs in | Defined in | Purpose | Why (ADR) | On AWS |
|---|---|---|---|---|---|
| **kind cluster** | 3 Docker containers: `zdp-control-plane`, `zdp-worker`, `zdp-worker2` (Kubernetes 1.34) | `infra/modules/local/kind-cluster`, root `infra/live/local/10-cluster` | Where everything else runs. Host ports: 80/443 → Traefik, 8200 → OpenBao, 6443 → API server | ADR-001 | EKS, 3 AZs, private endpoint |
| **CloudNativePG operator** | ns `cnpg-system` | `infra/modules/local/data-operators` | Runs Postgres clusters and PgBouncer poolers as Kubernetes resources | ADR-007 | not needed: RDS |
| **Postgres** (one per stack) | stack namespace, pod `<stack>-pg-1`, 1 Gi volume | `infra/modules/local/stack-data` (`Cluster <stack>-pg`) | The app's database | ADR-007 | RDS PostgreSQL Multi-AZ |
| **PgBouncer** (one per stack) | stack namespace, Service `pgbouncer` | `stack-data` (CNPG `Pooler`) | Transaction pooling: hundreds of app connections onto 40 database connections. The app's `DATABASE_URL` points here | ADR-007 | PgBouncer Deployment (2 replicas) |
| **Valkey** (one per stack) | stack namespace, StatefulSet `valkey` + `redis_exporter` sidecar, 1 Gi volume | `stack-data` | The job queue (`jobs` list). AOF persistence, `noeviction` | ADR-006, ADR-008 | ElastiCache for Valkey, Multi-AZ, TLS |
| **OpenBao** | ns `openbao` (dev mode) | `data-operators` | The secrets manager. Holds `secret/stacks/<stack>/app` with the three connection URLs | ADR-009 | AWS Secrets Manager |
| **Backup volume** `pg-backups` | stack namespace, 1 Gi PVC | `stack-data` | Where the backup jobs write dumps. Owned by Terraform so no Argo CD sync can delete it | ADR-019 | not needed: RDS automated backups + PITR |
| **Bootstrap secrets** | ns `external-secrets` (`openbao-token`), ns `monitoring` (`grafana-admin`) | `data-operators` | Credentials the platform needs before Argo CD starts | ADR-009 | Pod Identity (no tokens) |
| **Argo CD** | ns `argocd` | `infra/live/local/30-gitops` (Helm release + root Application) | Installed once by Terraform; from then on it pulls everything else from Git | ADR-010 | same |

## 3. Platform layer (Argo CD Applications from `gitops/clusters/local/apps/`)

| Component | Runs in | Defined in | Purpose | Why (ADR) | On AWS |
|---|---|---|---|---|---|
| **Prometheus Operator CRDs** | cluster-scoped | `00-prometheus-operator-crds.yaml` | Installs the monitoring CRDs first (sync wave 0), so every later app can ship its own scrape config and rules | ADR-023 | same |
| **Traefik** | ns `traefik`, 2 replicas, NodePort 30080 | `10-traefik.yaml`, `gitops/platform/values/local/traefik.yaml` | The only entry point. Routes by host, splits canary traffic with weighted services, and its metrics are the SLIs | ADR-011, ADR-023 | 3 replicas behind an NLB |
| **Argo Rollouts** | ns `argo-rollouts` (controller + dashboard) | `11-argo-rollouts.yaml` | Runs canaries: moves traffic weights, runs analysis, aborts and rolls back automatically | ADR-011, ADR-012 | same |
| **KEDA** | ns `keda` | `12-keda.yaml` | Feeds autoscaling metrics to the HPA: edge req/s, in-flight requests, CPU (API); queue length (worker) | ADR-013 | same |
| **External Secrets Operator** | ns `external-secrets` | `13-external-secrets.yaml`, `gitops/platform/config/secret-store.yaml` | Copies each stack's secret from OpenBao into a Kubernetes Secret (`app-env`), refreshed every minute | ADR-009 | same operator, Secrets Manager backend |
| **metrics-server** | ns `kube-system` | `14-metrics-server.yaml` | Pod CPU for the HPA's CPU trigger and `kubectl top` | ADR-013 | same |
| **kube-prometheus-stack** | ns `monitoring` | `20-kube-prometheus-stack.yaml` | Prometheus (15 s scrapes, 12 h retention), Alertmanager, Grafana, kube-state-metrics, node-exporter | ADR-023 | 2 Prometheus replicas, 15 d retention on gp3 |
| **Platform config** | cluster-wide | `21-platform-config.yaml` → `gitops/platform/config/` | UI routes (`argocd`, `grafana`, `rollouts`, `prometheus` `.localtest.me`), PriorityClasses, the `platform-secrets` store | ADR-010 | `gitops/platform/aws` (+ Karpenter pools, gp3 StorageClass) |
| **Synthetic traffic** | ns `synthetic` | `30-synthetic-traffic.yaml` → `gitops/platform/synthetic-traffic/` | 10 req/s to every stack's host plus a job every 10 s, so canary analysis and gates always have data | ADR-016 | same |
| **ApplicationSets** | ns `argocd` | `40-appset-stacks.yaml`, `41-appset-tenants-dedicated.yaml`, `42-appset-tenants-shared.yaml` | Generate one Application per stack and per tenant from `gitops/stacks/*.yaml`, `tenants/*.yaml` and the release files | ADR-010, ADR-017 | same, with AWS overrides |
| **Karpenter** | AWS only | `gitops/clusters/aws-eu-central-1/apps/15-karpenter.yaml` | Adds and removes nodes on demand; per-tenant and spot node pools | ADR-022 | — |

## 4. App layer (`charts/app`, rendered once per stack)

| Object | What it does |
|---|---|
| `Rollout api` | The API pods. A canary deployment: 10% → 25% → 50% → 100%, with analysis at each step. Graceful shutdown: preStop sleep, 30 s grace |
| `Rollout worker` | The queue workers. A replica-weighted canary (no traffic to split). 90 s grace, longer than the 60 s longest job |
| `Service api-stable` / `api-canary` | Point at the stable and canary pods; Argo Rollouts manages their selectors |
| `TraefikService api` | The weighted split between stable and canary that Argo Rollouts adjusts |
| `IngressRoute api` | `<stack>.localtest.me` → the weighted service |
| `AnalysisTemplate api-canary` / `worker-canary` | The canary's pass criteria: success ≥ 99%, p95 ≤ 400 ms, ≥ 20 req/min (API) |
| `ScaledObject api` / `worker` (+ HPAs) | Autoscaling: API on req/s, in-flight and CPU; worker on queue length |
| `TriggerAuthentication worker-queue` | Tells KEDA where the queue is, from the stack secret (`QUEUE_ADDRESS`) |
| `ExternalSecret app-env` → Secret `app-env` | The three connection URLs from the secrets manager, plus the derived `QUEUE_ADDRESS` |
| `PodDisruptionBudget api` / `worker` | Node drains can't take too many pods at once |
| `NetworkPolicy` × 4 | Default-deny ingress; then only same-namespace, Traefik → API, and platform namespaces (monitoring, CNPG, KEDA) |
| `PodMonitor` api, worker, postgres, pgbouncer; `ServiceMonitor valkey` | Scrape configs for this stack |
| `PrometheusRule slo` / `backup` | SLI recording rules, burn-rate alerts, cause alerts (queue backlog, DB pool waits), stale-backup alert |
| `CronJob backup` / `Job presync-backup` | Hourly `pg_dump`, plus one before every sync (Argo CD PreSync hook), to `pg-backups` |
| `ServiceAccount app` | No API token mounted; the app never talks to Kubernetes |
| `NodePool tenant-<name>` (AWS only) | A dedicated tenant's own tainted node pool, with its pods pinned to it |

**Shared tenants** get `charts/tenant-route` instead: an `IngressRoute` for their host on the prod stack, and per-tenant SLO rules from their own Traefik router ([tenancy](tenancy.md)).

## 5. The application itself (stand-in)

| Binary | Runs as | Purpose |
|---|---|---|
| `api` (`app/cmd/api`) | `Rollout api` | HTTP: `/healthz`, `/readyz`, `/metrics`, `GET /api/items/{id}` (Postgres), `POST /api/jobs` (Valkey). Runs migrations at startup under an advisory lock. Bounded concurrency (8 in flight) models capacity |
| `worker` (`app/cmd/worker`) | `Rollout worker` | Claims jobs with `BLMOVE`, heartbeats while working, drains on SIGTERM; a reaper requeues the jobs of dead workers |
| `synthetic` (`app/cmd/synthetic`) | the `synthetic` Deployment | The steady background traffic |

The real application is a black box. The stand-in implements its contract so the platform can be exercised (ADR-005); the README says which results depend on it.
