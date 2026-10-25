# infra/live/local/20-data/tests/ — code review

| File | What it checks |
|---|---|
| `contract_test.sh` | The provider contract, for every stack. The stack list is derived from `gitops/stacks/*.yaml` plus `tenants/*.yaml` with `tier: dedicated`, the same rule as `locals.tf`. Per stack: the namespace exists; CNPG `Cluster <stack>-pg` is in phase `Cluster in healthy state`; the `pgbouncer` Deployment becomes Available (it waits up to 120 s, because Terraform does not wait for the Pooler Deployment and the stack is eventually consistent); `valkey-0` is Ready and `CONFIG GET appendonly` returns `yes`; `bao kv get secret/stacks/<stack>/app` has exactly `DATABASE_URL`, `MIGRATION_DATABASE_URL` and `REDIS_URL`; and `psql "$DATABASE_URL" -c 'select 1'` **through PgBouncer** returns 1. The psql check runs from inside the Postgres pod, which has `psql`, so no extra pod is needed in a `restricted` namespace. |

It prints a `PASS`/`FAIL` line per check, and exits 1 if any check fails.

**Label:** RUN-LOCAL.
