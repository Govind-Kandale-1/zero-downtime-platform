# infra/modules/local/stack-data/ — code review

**Purpose:** everything one stack needs from the provider contract: a namespace, Postgres, PgBouncer, Valkey, and the three connection URLs in the secrets manager. It is instantiated once per stack by `live/local/20-data`.

| Resource | What it creates |
|---|---|
| `kubernetes_namespace_v1` | `app-<stack>` or `tenant-<name>`. Labels: `zdp/stack`, `zdp/tier`, `zdp/residency`, `zdp/region` (used for per-tenant visibility and residency policy), and Pod Security **`restricted`** enforced. |
| `random_password` + `kubernetes_secret_v1` | A per-stack password for the `app` DB owner. CNPG bootstraps with it (`<stack>-pg-app`). |
| `kubectl_manifest.postgres` | CNPG `Cluster <stack>-pg`: 1 instance, Postgres 18.6, 1 Gi, `max_connections=200`, sized `shared_buffers`. Terraform **waits** for `status.phase = "Cluster in healthy state"`. |
| `kubectl_manifest.pooler` | CNPG `Pooler pgbouncer` (Service `pgbouncer`): **transaction mode**, `max_client_conn=1000`, `default_pool_size=40`. |
| `kubectl_manifest.valkey*` | Service `valkey` (6379 plus 9121 metrics) and a 1-replica StatefulSet. It runs with **AOF on** (`--appendonly yes`) and RDB off, a 1 Gi PVC, `maxmemory` with **`noeviction`**, and a `redis_exporter` sidecar exporting `LLEN jobs` (`REDIS_EXPORTER_CHECK_KEYS=jobs`). Non-root, read-only capabilities, RuntimeDefault seccomp. |
| `vault_kv_secret_v2.app` | `secret/stacks/<stack>/app`: `DATABASE_URL` (via PgBouncer), `MIGRATION_DATABASE_URL` (direct `-pg-rw`), `REDIS_URL`. |
| `kubernetes_persistent_volume_claim_v1.pg_backups` | PVC **`pg-backups`** (1 Gi, `wait_until_bound = false`) that the chart's backup CronJob and PreSync job mount. It's provider-layer infrastructure because Argo CD runs PreSync hooks before ordinary resources exist, and a hook-owned PVC would be deleted, backups and all, before every sync (Task 16). |

**Size presets** (requests / limits):

| Size | Postgres | `shared_buffers` | Valkey | `maxmemory` |
|---|---|---|---|---|
| tiny | 128/256 Mi | 32 MB | 32/64 Mi | 40 MB |
| small | 256/512 Mi | 64 MB | 48/128 Mi | 96 MB |

**Key decisions:**
- **`kubectl_manifest` for CRD-backed objects.** `kubernetes_manifest` needs the CRD to exist at *plan* time, which breaks a first apply that installs the operator in the same run.
- **Two URLs per database.** Runtime traffic goes through PgBouncer in transaction mode. Migrations go direct, because a session-level advisory lock taken through a transaction-mode pooler can land on one backend and be released on another (ADR-007).
- **AOF + `noeviction`** is what makes "no dropped jobs" true at the data layer. Valkey survives a restart with the queue intact, and when memory is full it rejects new jobs loudly instead of evicting queued ones.
- **Pod Security `restricted`** is enforced on every app namespace from the start, so everything later deployed there (app, backup jobs) must be non-root with no privilege escalation.

**Verify:** `bash infra/live/local/20-data/tests/contract_test.sh` checks all of the above for every stack.

**Limitations:**
- One instance each, so there is no HA locally. The AWS module uses RDS Multi-AZ and a Multi-AZ ElastiCache replication group.
- The Valkey metrics port is scraped by a ServiceMonitor that ships with the app chart. ServiceMonitor CRDs belong to the platform layer, which is installed later.

**Label:** RUN-LOCAL.

**Files:** `main.tf` (the resources above), `variables.tf` and `outputs.tf` (the module's inputs and outputs), `versions.tf` (Terraform and provider version pins).
