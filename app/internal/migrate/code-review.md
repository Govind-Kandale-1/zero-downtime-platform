# app/internal/migrate/ — code review

**Purpose:** reproduces "migrations run on startup" safely when many pods start at once.

| File | What it does |
|---|---|
| `migrate.go` | `Run(ctx, pool, fs)`: (1) acquire **one** connection; (2) `pg_advisory_lock(727274)`; (3) create `schema_migrations` if missing; (4) apply each unapplied `NNNN_*.sql` in order, each in its own transaction together with its version row; (5) unlock, using a background context so even a cancelled ctx unlocks. Versions present in the table but missing from the FS are ignored. |
| `migrate_integration_test.go` | Build tag `integration`, against real Postgres. Two concurrent runners on a fresh DB both succeed, `0001` is applied exactly once, and the 1,000 seed rows exist. Also: an older image started on a schema that already has `9999` gives no error and applies nothing. |

**Key decisions:**
- **Session-level lock on a direct connection.** The lock and unlock must hit the same backend. Through PgBouncer in transaction mode they may not, which can deadlock or let two pods migrate at once. Hence `MIGRATION_DATABASE_URL` (ADR-007).
- **Forward-only, and unknown versions are tolerated.** This is what makes *rolling back the image after an expand migration* safe: the old image starts, sees a newer version in the table, and carries on (ADR-018).
- **One transaction per file.** A failed migration leaves no half-applied file; Postgres DDL is transactional.

**Verify:** `bash scripts/test-go.sh integration`.

**Limitations:** there are no down-migrations, by design. Recovery is a forward fix or a restore (`docs/runbooks/rollback-after-migration.md`). A migration that can't run inside a transaction, such as `CREATE INDEX CONCURRENTLY`, would need special handling.

**Label:** RUN-LOCAL (stand-in).
