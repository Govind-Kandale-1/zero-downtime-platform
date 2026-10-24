// Command api is the stand-in for the black-box API: it serves on :8080,
// migrates the schema at startup, and shuts down gracefully on SIGTERM.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/Govind-Kandale-1/zero-downtime-platform/app/internal/config"
	"github.com/Govind-Kandale-1/zero-downtime-platform/app/internal/httpapi"
	"github.com/Govind-Kandale-1/zero-downtime-platform/app/internal/migrate"
	"github.com/Govind-Kandale-1/zero-downtime-platform/app/internal/queue"
	"github.com/Govind-Kandale-1/zero-downtime-platform/app/migrations"
)

var version = "dev" // set with -ldflags "-X main.version=..."

func main() {
	if err := run(); err != nil {
		slog.Error("api exited", "err", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	cfg.Version = version

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		return fmt.Errorf("database pool: %w", err)
	}
	defer pool.Close()

	redisOpts, err := redis.ParseURL(cfg.RedisURL)
	if err != nil {
		return fmt.Errorf("REDIS_URL: %w", err)
	}
	rdb := redis.NewClient(redisOpts)
	defer rdb.Close()

	host, _ := os.Hostname()
	srv := httpapi.New(cfg, httpapi.Deps{DB: pool, Queue: queue.New(rdb, cfg.QueueName, host)})
	httpServer := &http.Server{
		Addr:              fmt.Sprintf(":%d", cfg.Port),
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Serve immediately: /healthz must answer while migrations run, /readyz
	// stays 503 until they finish and dependencies respond.
	serveErr := make(chan error, 1)
	go func() {
		slog.Info("listening", "addr", httpServer.Addr, "version", cfg.Version)
		if err := httpServer.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
			serveErr <- err
		}
	}()

	if err := migrateWithRetry(ctx, cfg.MigrationDatabaseURL); err != nil {
		return err
	}
	go watchReadiness(ctx, srv, pool, rdb)

	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
	}

	// Graceful shutdown: fail readiness, give the ingress time to stop routing
	// to us, then drain in-flight requests.
	slog.Info("SIGTERM received; draining", "delay", cfg.ShutdownDelay, "timeout", cfg.ShutdownTimeout)
	srv.MarkShuttingDown()
	time.Sleep(cfg.ShutdownDelay)
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()
	return httpServer.Shutdown(shutdownCtx)
}

// migrateWithRetry keeps trying until the database is reachable, so a pod that
// starts before its database is ready waits instead of crash-looping.
func migrateWithRetry(ctx context.Context, url string) error {
	poolCfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return fmt.Errorf("MIGRATION_DATABASE_URL: %w", err)
	}
	poolCfg.MaxConns = 1
	migPool, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		return fmt.Errorf("migration pool: %w", err)
	}
	defer migPool.Close()

	backoff := time.Second
	for {
		applied, err := migrate.Run(ctx, migPool, migrations.FS)
		if err == nil {
			slog.Info("migrations complete", "applied", applied)
			return nil
		}
		slog.Warn("migrations not applied yet; retrying", "err", err, "in", backoff)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, 10*time.Second)
	}
}

// watchReadiness keeps /readyz truthful while the pod runs: a lost database or
// cache takes the pod out of rotation instead of serving errors.
func watchReadiness(ctx context.Context, srv *httpapi.Server, pool *pgxpool.Pool, rdb *redis.Client) {
	check := func() {
		c, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		srv.SetReady(pool.Ping(c) == nil && rdb.Ping(c).Err() == nil)
	}
	check()
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			check()
		}
	}
}
