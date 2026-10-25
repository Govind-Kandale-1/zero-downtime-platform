# infra/live/local/ — code review

**Purpose:** the root modules for the local target, applied in order by `scripts/up.sh`:

| Root | Creates | State schema |
|---|---|---|
| `10-cluster/` | The kind cluster | `local_10_cluster` |
| `20-data/` | CNPG + OpenBao operators; per-stack namespaces, Postgres, PgBouncer, Valkey, secrets | `local_20_data` |
| `30-gitops/` | Argo CD and the root Application, handing over to GitOps | `local_30_gitops` |

**State:** every root uses `backend "pg"` against the `zdp-tfstate` Postgres container (`scripts/state-up.sh`).
- The connection string comes from `PG_CONN_STR` in the git-ignored `.local/tfstate.env`, never from committed files.
- Each root has its own schema, so roots lock independently.
- The pg backend locks with Postgres advisory locks, so two concurrent `apply`s on one root can't corrupt state.
- Later roots read earlier outputs via `terraform_remote_state` (same backend, upstream schema).

**Run manually:**

```bash
bash scripts/state-up.sh && source .local/tfstate.env
terraform -chdir=infra/live/local/10-cluster init && terraform -chdir=infra/live/local/10-cluster apply
```

**Label:** RUN-LOCAL.
