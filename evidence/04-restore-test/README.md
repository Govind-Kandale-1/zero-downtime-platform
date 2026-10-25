# Evidence 04: backups restore, timed (and the backups that had silently stopped)

**Label:** RUN-LOCAL (stand-in)

## The restore drill

`scripts/restore-test.sh <namespace>` (ADR-019) is non-destructive; it never touches the live database. It runs four steps:
1. Take a fresh backup with the stack's own `cronjob/backup`. `--latest` skips this and uses the newest dump already on the volume.
2. Create a throwaway CloudNativePG cluster `restore-test` in the same namespace.
3. In a Job that mounts the provider-layer volume `pg-backups` **read-only**: `pg_restore`, then recompute the `items` row count and md5.
4. Pass only if those values equal the `.counts` file the backup job wrote **at backup time**. Then delete the scratch cluster.

| Run | Dump | Recorded at backup | Restored | RTO (new instance + restore and verify) |
|---|---|---|---|---|
| `app-prod` (`restore-prod.txt`) | fresh, `backup-20261025T150446Z` | 1000 rows, `a507239f…` | 1000 rows, `a507239f…` | **38 s** (30 + 8) |
| `tenant-acme --latest` (`restore-acme-latest.txt`) | the 15:00 hourly, `backup-20261025T150001Z` | 1000 rows, `a507239f…` | 1000 rows, `a507239f…` | **34 s** (26 + 8) |
| `app-dev` (first trial run) | fresh | 1000 rows | 1000 rows | 43 s (36 + 7) |

Every stack's md5 is the same because each stack is seeded with the same 1,000 rows by migration `0001`. The check is still per stack: the counts file comes from that stack's backup, and the restore runs from that stack's volume.

**What the RTO means.** About 80% of it is creating a new Postgres instance. The data part takes 8 s for the stand-in's 1,000 rows. A real database scales with size: a logical restore of tens of GB, plus index builds, takes tens of minutes, and an RDS PITR to a new instance takes 10–30 minutes (ADR-019). One restore uses most of a 99.95% SLO's monthly error budget (21.9 min). That's why a restore is the last resort and fix-forward the default ([rollback-after-migration.md](../../docs/runbooks/rollback-after-migration.md)).

**RPO:** at most 1 hour (hourly dumps), or the time since the last deploy, because every Argo CD sync takes a PreSync dump first. On AWS (NOT RUN): about 5 minutes with RDS PITR.

## Finding: tenant backups had silently stopped for 3 hours (fixed)

While preparing the drill, I noticed both dedicated tenants (`tenant-acme`, `tenant-globex`) had **no successful backup at all**.

**What happened:**
- Their 12:00 backup job had been `Pending` for 3 hours. It mounted a claim from the old hook-PVC design (Task 14), which never existed in those namespaces.
- The CronJob uses `concurrencyPolicy: Forbid` and its jobs had no deadline. So every later run was skipped, with the event `Not starting job because prior execution is running and concurrency policy is Forbid`.

**Why nothing noticed:** Prometheus had no `kube_cronjob_status_last_successful_time` series for these CronJobs, because they had never succeeded. A plain staleness alert would also have stayed silent.

| When (UTC) | |
|---|---|
| 12:00 | The tenant backup job starts; its pod can never schedule |
| 13:00, 14:00 | Hourly runs skipped (`JobAlreadyActive`) |
| 14:45 | Prometheus: `kube_cronjob_status_active = 1` for both tenants, and no success series |
| 14:51 | Stuck jobs removed by hand; catch-up backups written. The controller also ran the missed 14:00 run at once |
| 15:00 | The hourly run succeeds on schedule (it's the dump restored above) |

**Fix** (commit `5b3d693`):
- `activeDeadlineSeconds` on both backup jobs (`backup.timeoutSeconds`, 900 s): a hung job fails instead of blocking the schedule.
- New alert **`ZdpBackupStale`**: fires when the last success is older than 2 h, **or** the CronJob is older than 2 h and has never succeeded.
- Runbook: [backup-stale.md](../../docs/runbooks/backup-stale.md). Render tests cover both, and promtool parses the rule.

## Reproduce

```bash
bash scripts/restore-test.sh app-prod              # fresh backup, then restore
bash scripts/restore-test.sh tenant-acme --latest  # newest existing dump
```
