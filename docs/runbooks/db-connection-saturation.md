# Runbook: database connection saturation (`ZdpDbPoolWaiting`)

**Trigger:** ticket. A client waited ≥ 1 s for a PgBouncer server connection, sustained for 5 minutes. Local stacks only, from the CNPG exporters. On AWS use RDS Performance Insights and CloudWatch `DatabaseConnections`.

**User impact:** requests slow down. If it's bad enough, the latency burn-rate alert pages too.

**How the pool is built:**
- Every API pod opens up to 12 client connections (pgx default: `max(4, NumCPU)`).
- PgBouncer (transaction mode) multiplexes all clients onto **40 server connections** (`default_pool_size`). Postgres allows 200.
- Waits mean either the 40 server connections are all busy, or new connections are slow to establish.

## 1. Which one? (5 min)

```promql
max by (database) (cnpg_pgbouncer_pools_cl_waiting{namespace="<ns>"})   # clients queued for a server connection
max by (database) (cnpg_pgbouncer_pools_sv_active{namespace="<ns>"})    # server connections busy (40 = pool full)
max(cnpg_pgbouncer_pools_maxwait{namespace="<ns>"})                     # worst wait, in seconds
sum(cnpg_backends_total{namespace="<ns>"})                              # Postgres backends
```

```bash
ns=app-prod; pg=$(kubectl -n $ns get pod -l cnpg.io/podRole=instance -o name | head -1)
kubectl -n $ns exec $pg -c postgres -- psql -d app -c "select pid, state, wait_event_type, now()-query_start as age, left(query,60) from pg_stat_activity where datname='app' order by age desc nulls last limit 10"
kubectl -n $ns exec $pg -c postgres -- psql -d app -c "select locktype, mode, granted, count(*) from pg_locks group by 1,2,3 order by 4 desc limit 10"
```

| What you see | Cause | Action |
|---|---|---|
| `sv_active` = 40, long-running queries | Slow queries hold server connections | Find the query (a new release? a missing index?); `select pg_cancel_backend(<pid>)` for runaways; roll back a release that introduced it |
| `sv_active` = 40, short queries, high request rate | The pool is simply too small for the load | Raise `default_pool_size` in `infra/modules/local/stack-data` (Postgres allows 200) and apply |
| Locks not granted, an advisory lock held | A migration is running or stuck (advisory lock 727274) | Find the holder in `pg_locks`; a stuck migration pod should be deleted, not the lock |
| Waits only during scale-up, `sv_active` well below 40 | A burst of new connections (evidence 01: ~100 logins in 30 s as 11 pods started) | Usually self-resolving; the fix is avoiding scale-up overshoot (ADR-013) and warming pools before readiness (an app-team item) |
| Postgres CPU high | The database is the bottleneck | Architecture risk 1: on AWS a larger instance or read replicas; locally, the laptop |

## 2. Verify

`max(cnpg_pgbouncer_pools_maxwait{namespace="<ns>"})` back to 0, and edge p95 normal.
