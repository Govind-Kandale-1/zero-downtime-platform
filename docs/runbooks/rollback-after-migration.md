# Runbook: rolling back after a migration ran

**Label:** RUN-LOCAL for the expand case (evidence 02); the breaking-migration and restore paths are DESCRIBED.

**When:** you need the previous image back (a canary aborted, or a promoted release misbehaves), and the new image's migration has **already run**. Migrations run at startup, so the canary's first pod applies them before any analysis has judged the release. Rolling back the image does **not** roll back the schema (ADR-018).

## 1. Classify the migration (5 min)

```bash
git diff <last good sha> <bad sha> -- app/migrations/
kubectl -n <ns> exec <cluster>-1 -c postgres -- psql -d app -c 'select * from schema_migrations order by version'
```

| The migration… | Class | The previous image on the new schema |
|---|---|---|
| adds a table, a nullable column, a column with a default, or an index | **expand** | works: it ignores what it doesn't know |
| drops or renames a column/table, changes a type, adds NOT NULL without a default, or adds a constraint old writes violate | **breaking** | fails, or corrupts writes |

Policy (ADR-018) says every release must be expand-only relative to the previous one. This table is for when the policy was broken by mistake.

## 2a. Expand → roll the image back; leave the schema alone

This is safe and is the normal case. Evidence 02 shows it: the stable version served at 100% on a schema that already had migration `0002`.

- **During a canary:** nothing to do. The abort already did it ([canary-aborted.md](canary-aborted.md)).
- **After full promotion:** revert the release-file commit. Argo CD rolls the previous digest out *as a canary*, so the rollback itself is gated:
  ```bash
  git log --oneline -- gitops/releases/<stage>.yaml   # find "release(<stage>): chart X image Y"
  git revert <that sha> && git push                   # via PR, or an admin push in an incident
  ```
- **Do not** write a down-migration. The expanded schema is now the baseline, and the next release ships on top of it.

**Precondition, for the real app:** the old version must start on a schema with migrations it doesn't know. The stand-in's runner tolerates newer applied versions. Many tools refuse by default (Flyway's `validateOnMigrate`, for example). Confirm this with the app team; it is in the open questions.

## 2b. Breaking → fix forward; do not roll back the image

The previous image can't run on the new schema, so rolling back turns a partial outage into a full one.
1. Keep the new version serving where it works. If the canary aborted, stable is already failing on the new schema: **this is the incident.**
2. Ship a compatibility release fast: re-add the dropped column (nullable), or put a view in place of the renamed table, so that **both** versions work.
3. Then redo the change properly as expand → migrate → contract across releases.

## 2c. Last resort: restore (accepts data loss)

Use this only if a forward fix is impossible, for example when the migration destroyed data (a dropped column with real content).
- **Data loss window:** every write since the restore point. Get a written go-ahead from the incident commander first.
- **Restore point:** the `presync-<timestamp>.dump` on the stack's `pg-backups` volume, taken by the Argo CD PreSync hook seconds before the bad sync. On AWS: RDS point-in-time restore to just before the sync time, shown in Argo CD's sync history.
- **Rehearse first:** `scripts/restore-test.sh <ns> --latest --keep` restores the newest dump into a scratch cluster `restore-test` and verifies row counts and checksums. That's also how evidence 04 was measured (RTO 34–43 s for the stand-in's data).
- **Cut over:**
  1. Point the stack's secret at the restored database (`secret/stacks/<stack>/app` in OpenBao: `DATABASE_URL` and `MIGRATION_DATABASE_URL`). External Secrets refreshes `app-env` within its refresh interval.
  2. Restart the pods. `kubectl rollout restart` does not apply to Rollouts, so use `kubectl argo rollouts restart api -n <ns>`. Without the plugin: `kubectl -n <ns> patch rollout api --type merge -p "{\"spec\":{\"restartAt\":\"$(date -u +%FT%TZ)\"}}"`. Do the same for `worker`.
  3. Pin the release file to the last good version **first**, so the bad migration doesn't run again.

## 3. Verify

- `select * from schema_migrations` shows what you expect.
- The stack's gate passes when re-run: `GATE_SOAK=180 scripts/gate.sh <stage> <stack>` from the runner.
- The error-budget burn rate is back below 1.

**Evidence:** `evidence/02-auto-rollback/` (an expand migration followed by an image rollback), `evidence/04-restore-test/` (a timed restore).
