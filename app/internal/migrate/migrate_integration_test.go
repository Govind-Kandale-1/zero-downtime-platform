//go:build integration

package migrate

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"slices"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Govind-Kandale-1/zero-downtime-platform/app/migrations"
)

// freshDB creates an empty database for one test and drops it afterwards.
func freshDB(t *testing.T) *pgxpool.Pool {
	t.Helper()
	base := os.Getenv("TEST_DATABASE_URL")
	if base == "" {
		t.Fatal("TEST_DATABASE_URL not set (run via scripts/test-go.sh integration)")
	}
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, base)
	if err != nil {
		t.Fatalf("connect admin: %v", err)
	}
	name := fmt.Sprintf("mig_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		t.Fatalf("create database: %v", err)
	}
	cfg, err := pgxpool.ParseConfig(base)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.Database = name
	cfg.MaxConns = 4
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		pool.Close()
		_, _ = admin.Exec(ctx, "DROP DATABASE "+name+" WITH (FORCE)")
		_ = admin.Close(ctx)
	})
	return pool
}

func TestMigrateIsIdempotentAndLocked(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()

	// Two "pods" start at the same time.
	var wg sync.WaitGroup
	var applied [2][]string
	var errs [2]error
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			applied[i], errs[i] = Run(ctx, pool, migrations.FS)
		}()
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("runner %d: %v", i, err)
		}
	}
	// Every embedded migration exactly once across both runners, whichever
	// won the lock. Derived from the embedded files, so adding a migration
	// doesn't break the test (0002 once did).
	want := embeddedVersions(t)
	got := append(append([]string{}, applied[0]...), applied[1]...)
	sort.Strings(got)
	if !slices.Equal(got, want) {
		t.Fatalf("migrations applied %v and %v, want %v applied exactly once in total", applied[0], applied[1], want)
	}

	var versions []string
	rows, _ := pool.Query(ctx, "SELECT version FROM schema_migrations ORDER BY version")
	versions, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil || !slices.Equal(versions, want) {
		t.Fatalf("schema_migrations = %v (%v), want %v", versions, err, want)
	}
	var items int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM items").Scan(&items); err != nil || items != 1000 {
		t.Fatalf("items = %d (%v), want 1000 seed rows", items, err)
	}
}

// embeddedVersions lists the versions Run would apply, by the same rule:
// every *.sql file, version = the name up to the first "_".
func embeddedVersions(t *testing.T) []string {
	t.Helper()
	files, err := fs.Glob(migrations.FS, "*.sql")
	if err != nil || len(files) == 0 {
		t.Fatalf("no embedded migrations (%v)", err)
	}
	var versions []string
	for _, f := range files {
		v, _, _ := strings.Cut(f, "_")
		versions = append(versions, v)
	}
	sort.Strings(versions)
	return versions
}

func TestMigrateToleratesUnknownAppliedVersion(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	if _, err := Run(ctx, pool, migrations.FS); err != nil {
		t.Fatal(err)
	}
	// A newer release applied 9999; this (older) image is rolled back onto it.
	if _, err := pool.Exec(ctx, "INSERT INTO schema_migrations (version) VALUES ('9999')"); err != nil {
		t.Fatal(err)
	}

	applied, err := Run(ctx, pool, migrations.FS)
	if err != nil || len(applied) != 0 {
		t.Fatalf("Run after rollback = %v, %v; want no error and nothing applied", applied, err)
	}
}
