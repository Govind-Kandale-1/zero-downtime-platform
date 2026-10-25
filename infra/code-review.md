# infra/ — code review

**Purpose:** the **provider layer** (ADR-003). This is the only code that differs per cloud. Everything above it (Argo CD, platform apps, the app chart) depends only on the *provider contract* below.

## The provider contract

A provider implementation must deliver:
1. **A Kubernetes cluster** plus a kubeconfig.
2. **Per stack** (dev, staging, prod, and each dedicated tenant):
   - a Postgres database;
   - **PgBouncer** (transaction mode) at `pgbouncer.<namespace>.svc:5432`;
   - a **Valkey** endpoint.
3. **A secrets manager** holding these keys at `stacks/<stack>/app`:
   - `DATABASE_URL` (via PgBouncer);
   - `MIGRATION_DATABASE_URL` (direct to Postgres);
   - `REDIS_URL`.
4. **Remote Terraform state with locking.**

| Contract item | `local` (RUN) | `aws` (NOT RUN) |
|---|---|---|
| Cluster | kind (1 control-plane + 2 workers) | EKS + Karpenter |
| Postgres + pooler | CloudNativePG + CNPG Pooler | RDS Multi-AZ + PgBouncer Deployment |
| Cache | Valkey StatefulSet (AOF on) | ElastiCache for Valkey |
| Secrets | OpenBao (dev mode) | Secrets Manager |
| State | `pg` backend → `zdp-tfstate` container | `s3` backend, `use_lockfile` |

## Layout

| Path | What it is |
|---|---|
| `modules/local/` | Building blocks for the local target (kind cluster, data operators, per-stack data) |
| `modules/aws/` | Building blocks for AWS (network, EKS, per-stack data). NOT RUN |
| `live/local/NN-*` | Root modules applied in order: `10-cluster` → `20-data` → `30-gitops`. Each has its own state schema. |
| `live/aws/eu-central-1/NN-*` | The same split for AWS, plus `05-network`. NOT RUN |
| `bootstrap/aws/` | Creates the S3 state bucket and the GitHub OIDC role. It uses local state (chicken-and-egg). NOT RUN |

**Why numbered roots instead of one big root:**
- A provider block can't safely depend on a resource created in the same apply. For example, the Kubernetes provider needs the cluster's endpoint.
- Small roots keep plans short and keep the blast radius per apply small.
- They let `30-gitops` be re-applied without touching databases.

**Label:** `local` RUN-LOCAL; `aws` NOT RUN (static validation only).
