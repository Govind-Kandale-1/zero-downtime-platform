//go:build integration

package migrate

import (
	"context"
	"fmt"
	"os"
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
	if total := len(applied[0]) + len(applied[1]); total != 1 {
		t.Fatalf("migrations applied %v and %v, want 0001 applied exactly once in total", applied[0], applied[1])
	}

	var versions []string
	rows, _ := pool.Query(ctx, "SELECT version FROM schema_migrations ORDER BY version")
	versions, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil || len(versions) != 1 || versions[0] != "0001" {
		t.Fatalf("schema_migrations = %v (%v), want [0001]", versions, err)
	}
	var items int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM items").Scan(&items); err != nil || items != 1000 {
		t.Fatalf("items = %d (%v), want 1000 seed rows", items, err)
	}
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
