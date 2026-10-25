# Where things live

**Label:** RUN-LOCAL (checked against the running kind platform); AWS mappings NOT RUN.

## Machines, containers and ports (local)

Everything runs inside Docker Desktop's VM on the laptop (12 CPUs, 10 GiB):

| Container | What it is | Ports on the laptop |
|---|---|---|
| `zdp-control-plane` | Kubernetes control plane (kind node) | `80` → Traefik (NodePort 30080), `443` → Traefik (30443), `8200` → OpenBao (30200, for Terraform), `6443` → API server |
| `zdp-worker`, `zdp-worker2` | Kubernetes worker nodes (kind) | — |
| `zdp-tfstate` | Postgres holding Terraform state | — |
| `zdp-runner` | GitHub Actions self-hosted runner (gate jobs only) | — (dials out to GitHub) |

So `http://prod.localtest.me` on the laptop reaches Traefik inside the cluster. `*.localtest.me` resolves to 127.0.0.1.

## Namespaces

| Namespace | What's inside | Created by |
|---|---|---|
| `argocd` | Argo CD; the root app and the ApplicationSets | Terraform (`30-gitops`) |
| `traefik` | Traefik (2 replicas) | Argo CD |
| `argo-rollouts` | Rollouts controller + dashboard | Argo CD |
| `keda` | KEDA operator + metrics server | Argo CD |
| `external-secrets` | External Secrets Operator; the `openbao-token` Secret | Terraform (`20-data`), then Argo CD |
| `monitoring` | Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter; the `grafana-admin` Secret | Terraform (`20-data`), then Argo CD |
| `synthetic` | The synthetic traffic generator | Argo CD |
| `openbao` | OpenBao (the local secrets manager) | Terraform (`20-data`) |
| `cnpg-system` | CloudNativePG operator | Terraform (`20-data`) |
| `kube-system` | Cluster components, metrics-server | kind / Argo CD |
| `local-path-storage` | kind's volume provisioner (StorageClass `standard`) | kind |
| `app-dev`, `app-staging` | Non-prod stacks | Terraform creates the namespace and data services; Argo CD deploys the app |
| `app-prod` | The **shared** prod stack, plus the shared tenants' routes and SLO rules | same |
| `tenant-acme`, `tenant-globex` | **Dedicated** tenant stacks (own database, queue, secret) | same |

**One stack namespace contains:** Postgres (`<stack>-pg-1`), PgBouncer (`pgbouncer`), Valkey (`valkey-0`), the backup volume `pg-backups`, the API and worker pods, and the chart objects listed in [components.md](components.md#4-app-layer-chartsapp-rendered-once-per-stack). Network policies deny ingress from everywhere except the same namespace, Traefik (to the API only) and the platform namespaces.

## The repository: what is applied by whom

| Folder | Layer | Applied by | Change it to… |
|---|---|---|---|
| `infra/modules/{local,aws}`, `infra/live/{local,aws}` | Provider | Terraform (`scripts/up.sh` locally) | change clusters, databases, queues, secrets, state |
| `gitops/clusters/local/` | Platform | Argo CD (root app-of-apps) | add or remove a platform component |
| `gitops/platform/values/local/`, `gitops/platform/config/` | Platform | Argo CD | tune a platform component |
| `gitops/stacks/<stack>.yaml` | App config | Argo CD (and Terraform reads the `stack:` block) | change a stack's scaling, size or SLO, with no release needed |
| `gitops/releases/<stage>.yaml` | App version | **only the release pipeline** (`scripts/bump-release.sh`) | — (promotion writes these) |
| `tenants/<name>.yaml` | Tenancy | Terraform (dedicated data services) + Argo CD (apps, routes) | onboard or change a tenant: one file, one PR |
| `charts/app`, `charts/tenant-route` | App | packaged by the release pipeline, deployed by Argo CD | change what every stack runs (ships as a release) |
| `app/` | App code | built by the release pipeline | change the stand-in application |
| `.github/workflows/` | Delivery | GitHub Actions | change CI or the pipeline |
| `policy/` | Guard-rail | CI (conftest) | change tenant validation, e.g. residency |
| `scripts/` | Tooling | humans and the pipeline | bring-up, gates, promotion, tests, drills |
| `load/` | Testing | humans (k6 in a container) | load tests |
| `config/` | Pins | every script and workflow | change a tool or chart version |

## State, data, secrets and artifacts

| What | Where it's kept (local) | Durability | On AWS |
|---|---|---|---|
| **Desired state** (code, config, release pins) | Git on GitHub | Git history | same |
| **Terraform state** | Postgres in container `zdp-tfstate`, locked per run | survives cluster rebuilds; `down.sh --purge` deletes it | S3 bucket with lockfile (`infra/bootstrap/aws`) |
| **App data** | Postgres volume `<stack>-pg-1` (1 Gi) per stack | lives with the cluster | RDS Multi-AZ, encrypted with a KMS key |
| **Queue** | Valkey volume `data-valkey-0` (1 Gi), AOF every second | loses ≤ 1 s of enqueues on a crash | ElastiCache Multi-AZ |
| **Backups** | volume `pg-backups` per stack: hourly + pre-deploy dumps, each with a `.counts` file | 24 kept; same laptop disk as the data (a stated limit) | RDS automated backups, 14 days, replicated to eu-west-1 |
| **Secrets** | OpenBao `secret/stacks/<stack>/app` → External Secrets → Secret `app-env` | written by Terraform | Secrets Manager `stacks/<stack>/app` |
| **Images and charts** | GHCR, by digest (image) and version (chart) | permanent; signed | same |
| **Metrics** | inside the Prometheus pod | 12 h, lost if the pod restarts | 2 replicas, 15 days on gp3 volumes |
| **Pipeline secrets** | GitHub Actions secret `GITOPS_DEPLOY_KEY` (the deploy key that writes release files) | — | same |
| **Local credentials** | `.local/` (kubeconfig, state connection string, deploy key), git-ignored | — | — |

## Who can change what

| Identity | Can | Can't |
|---|---|---|
| Argo CD | apply anything in Git to the cluster | change Git |
| Release pipeline | push images/charts to GHCR; commit release files (deploy key) | touch the cluster |
| Gate runner (`ci-gate`) | **read** Argo CD apps, Rollouts and Prometheus | create, change or delete anything (checked by `runner-up.sh`) |
| External Secrets | read the stack secrets (OpenBao token locally, Pod Identity on AWS) | write them |
| The app (`ServiceAccount app`) | nothing in Kubernetes (no token mounted) | — |
| A human | merge PRs; approve `production` | push to `main` without the ruleset (except admins) |

## The provider contract

The only interface between the provider layer and everything above it (ADR-003). Any cloud implementation must deliver:

1. **A Kubernetes cluster** and its kubeconfig.
2. **Per stack** (dev, staging, prod, and each dedicated tenant), in namespace `app-<stack>` or `tenant-<name>`:
   - a Postgres database;
   - a PgBouncer endpoint in transaction mode at `pgbouncer.<namespace>.svc:5432`;
   - a Valkey endpoint;
   - a backup volume `pg-backups` (local only; managed backups on AWS).
3. **A secrets manager** holding, at `stacks/<stack>/app`:
   - `DATABASE_URL`, through PgBouncer;
   - `MIGRATION_DATABASE_URL`, direct to Postgres, for the migration advisory lock;
   - `REDIS_URL`.
4. **Remote Terraform state** with locking.

`bash infra/live/local/20-data/tests/contract_test.sh` checks items 2–3 for every stack. The chart only ever reads these three secret keys. It derives the queue's host:port for KEDA from `REDIS_URL`, so it never needs to know which cloud it's on. The full local-vs-AWS mapping is in [`docs/non-portable.md`](../non-portable.md).
