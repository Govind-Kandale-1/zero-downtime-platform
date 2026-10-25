# Runbook: backups stale (`ZdpBackupStale`)

**Label:** RUN-LOCAL: the stuck-job removal and catch-up backup were done exactly this way (evidence 04).

**Trigger:** ticket alert `ZdpBackupStale` for a stack. Either the newest successful hourly backup is older than 2 hours, or the backup CronJob is older than 2 hours and has never succeeded.

**User impact right now:** none. **Risk:** the restore point is getting old. If the database is lost or a migration destroys data, everything since the last good dump is gone. Treat it as urgent before the next deploy: the PreSync hook still takes a dump before every sync, but only for stacks that are deployed.

## 1. Find the blocked or failing job (2 min)

```bash
ns=tenant-acme   # the alert's namespace
kubectl -n $ns get cronjob backup -o jsonpath='{.status.lastSuccessfulTime} active={.status.active[*].name}{"\n"}'
kubectl -n $ns get jobs,pods -l batch.kubernetes.io/job-name --sort-by=.metadata.creationTimestamp | tail
kubectl -n $ns get events --field-selector involvedObject.name=backup | tail -3
```

| What you see | Cause | Fix |
|---|---|---|
| An **active** job for hours, pod `Pending`; event `JobAlreadyActive` | The pod can't schedule: a missing claim, no node capacity, a wrong PVC node | Fix the cause, then `kubectl -n $ns delete job <it>`. Since `backup.timeoutSeconds` (900 s) exists, this resolves itself; before it, one stuck job blocked every hourly run (evidence 04). |
| Job `Failed`, logs say `pg_dump: error: connection…` | The database or its secret is unreachable | Check `app-env` exists (External Secrets synced) and the `<stack>-pg` cluster is healthy |
| Job `Failed`, `No space left on device` | `pg-backups` (1 GiB locally) is full | Lower `backup.retain`, or grow the PVC in `infra/modules/local/stack-data` |
| Job `DeadlineExceeded` | The dump takes longer than 900 s | Raise `backup.timeoutSeconds`. On real data sizes, move to continuous archiving (ADR-019 roadmap) |

## 2. Take a catch-up backup and confirm

```bash
kubectl -n $ns create job --from=cronjob/backup backup-catchup-$(date +%s)
kubectl -n $ns logs -f job/<that job>          # "wrote /backups/backup-<ts>.dump (... bytes) counts: <rows> <md5>"
```

The alert clears once `lastSuccessfulTime` is fresh: kube-state-metrics picks it up within a minute, then the 10-minute `for`.

## 3. Prove the new backup restores

A backup that hasn't been restored is a hope. Run the drill against the stack:

```bash
scripts/restore-test.sh $ns --latest     # RESTORE PASS rows=… md5=… rto_seconds=…
```

**Evidence:** `evidence/04-restore-test/` (the tenant backups that stalled for 3 hours, and the drill).
