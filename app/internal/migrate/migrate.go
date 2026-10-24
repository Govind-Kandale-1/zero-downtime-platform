// Package migrate applies the embedded SQL migrations at startup, the way the
// black-box app does. It is safe when many pods start at once: a session-level
// advisory lock lets exactly one pod migrate while the others wait, then find
// nothing left to do. Session-level locks need a direct connection, which is
// why the caller passes the MIGRATION_DATABASE_URL pool, not the PgBouncer one
// (in transaction mode PgBouncer may hand the unlock to a different backend).
package migrate

import (
	"context"
	"fmt"
	"io/fs"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

// lockID is an arbitrary constant shared by every replica of this app.
const lockID = 727274

// Run applies every NNNN_*.sql file not yet recorded in schema_migrations, in
// order, each in its own transaction. Versions recorded in the table but
// missing from the FS are tolerated: migrations are forward-only, and an older
// image rolled back onto a newer schema must still start.
func Run(ctx context.Context, db *pgxpool.Pool, migrations fs.FS) (applied []string, err error) {
	conn, err := db.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("acquire connection: %w", err)
	}
	defer conn.Release()

	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", lockID); err != nil {
		return nil, fmt.Errorf("take migration lock: %w", err)
	}
	defer func() {
		// Unlock even if ctx was cancelled mid-migration.
		_, _ = conn.Exec(context.Background(), "SELECT pg_advisory_unlock($1)", lockID)
	}()

	if _, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version    text PRIMARY KEY,
		applied_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return nil, fmt.Errorf("create schema_migrations: %w", err)
	}

	done := map[string]bool{}
	rows, err := conn.Query(ctx, "SELECT version FROM schema_migrations")
	if err != nil {
		return nil, fmt.Errorf("read schema_migrations: %w", err)
	}
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			rows.Close()
			return nil, err
		}
		done[v] = true
	}
	rows.Close()

	files, err := fs.Glob(migrations, "*.sql")
	if err != nil {
		return nil, err
	}
	sort.Strings(files)

	for _, name := range files {
		version, _, _ := strings.Cut(name, "_")
		if done[version] {
			continue
		}
		body, err := fs.ReadFile(migrations, name)
		if err != nil {
			return applied, err
		}
		tx, err := conn.Begin(ctx)
		if err != nil {
			return applied, err
		}
		if _, err := tx.Exec(ctx, string(body)); err != nil {
			_ = tx.Rollback(ctx)
			return applied, fmt.Errorf("apply %s: %w", name, err)
		}
		if _, err := tx.Exec(ctx, "INSERT INTO schema_migrations (version) VALUES ($1)", version); err != nil {
			_ = tx.Rollback(ctx)
			return applied, fmt.Errorf("record %s: %w", name, err)
		}
		if err := tx.Commit(ctx); err != nil {
			return applied, fmt.Errorf("commit %s: %w", name, err)
		}
		applied = append(applied, version)
	}
	return applied, nil
}
