# Runbook: restore a stack's database from backup

**Label:** DESCRIBED. The rehearsal step (`scripts/restore-test.sh`) is RUN-LOCAL (evidence 04); an in-place restore was not exercised.

**When:** data is lost or corrupted (a destructive migration, a bad manual change, a broken volume) **and** a forward fix can't recover it. This is the last resort ([rollback-after-migration.md](rollback-after-migration.md), §2c). **It loses every write since the restore point** and needs the incident commander's written go-ahead.

**Rehearse first, every time:** `scripts/restore-test.sh <ns> --latest` proves the dump restores and shows the timing (evidence 04: 34–43 s for the stand-in's data). Real data takes longer: plan on tens of minutes for tens of GB.

## 1. Choose the restore point

| Option | Where | Data loss |
|---|---|---|
| **PreSync dump** of the bad deploy | `presync-<ts>.dump` on the stack's `pg-backups` volume, taken seconds before the sync | everything written after that sync |
| Latest **hourly** dump | `backup-<ts>.dump` | up to 1 hour |
| **AWS:** RDS point-in-time | any second in the last 14 days in eu-central-1, or the last 7 days from the eu-west-1 replica | from the chosen second onwards |

```bash
ns=tenant-acme
kubectl -n $ns run ls-backups --rm -i --restart=Never --image=postgres:18.6-alpine \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":70,"seccompProfile":{"type":"RuntimeDefault"}},"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"pg-backups","readOnly":true}}],"containers":[{"name":"ls","image":"postgres:18.6-alpine","command":["ls","-lt","/backups"],"volumeMounts":[{"name":"b","mountPath":"/backups"}],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
```

## 2. Local (CloudNativePG): restore in place

1. **Stop writes** (this causes downtime). Pin both ScaledObjects to zero:
   ```bash
   kubectl -n $ns annotate scaledobject api worker autoscaling.keda.sh/paused-replicas=0 --overwrite
   ```
2. **Take a safety dump of the current (bad) state**, so the restore itself can be undone:
   ```bash
   kubectl -n $ns create job --from=cronjob/backup before-restore-$(date +%s)
   ```
3. **Restore** with a Job shaped like the one in `scripts/restore-test.sh`: same image, security context and read-only `pg-backups` mount. It differs in three ways:
   - `DB` comes from secret `app-env`, key `MIGRATION_DATABASE_URL` (direct to Postgres, not PgBouncer);
   - `DUMP` is set to the chosen file;
   - the command is `pg_restore --clean --if-exists --no-owner --no-acl --exit-on-error -d "$DB" "$DUMP"`.
4. **Verify the data:** compare `select count(*), md5(...)` with that dump's `.counts` file, and check `schema_migrations`. **Pin the release file to the last good version first**, so a bad migration can't re-run when the pods start.
5. **Resume:** `kubectl -n $ns annotate scaledobject api worker autoscaling.keda.sh/paused-replicas-`.

## 3. AWS (RDS): restore to a new instance, then switch

1. `aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier zdp-<stack> --target-db-instance-identifier zdp-<stack>-restored --restore-time <UTC>` (or `--use-latest-restorable-time`). Use the same subnet group, security group and KMS key. This takes 10–30 minutes.
2. Update the stack's secret in Secrets Manager (`stacks/<stack>/app`): point `DATABASE_URL` (the PgBouncer target) and `MIGRATION_DATABASE_URL` at the new endpoint. ESO refreshes `app-env` within its refresh interval.
3. Restart the pods so they reconnect: `kubectl argo rollouts restart api -n <ns>` (and `worker`), or patch `spec.restartAt` without the plugin.
4. Codify it: point Terraform at the restored instance (or import it) before the next apply, otherwise drift will try to revert it.

## 4. Verify and close

- Re-run the gate against the stack: `scripts/gate.sh <stage> <stack>` on the runner. Expect `GATE PASS`.
- Tell affected tenants the exact data-loss window (restore point → restore time).
- Afterwards: why did forward recovery fail? That answer goes into the migration CI check (roadmap item 10).
