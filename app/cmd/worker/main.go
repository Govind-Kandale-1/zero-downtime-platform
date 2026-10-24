// Command worker is the stand-in for the black-box worker: it consumes the
// queue and, on SIGTERM, finishes the job in hand before exiting 0.
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

	"github.com/redis/go-redis/v9"

	"github.com/Govind-Kandale-1/zero-downtime-platform/app/internal/config"
	"github.com/Govind-Kandale-1/zero-downtime-platform/app/internal/queue"
	"github.com/Govind-Kandale-1/zero-downtime-platform/app/internal/worker"
)

var version = "dev" // set with -ldflags "-X main.version=..."

func main() {
	if err := run(); err != nil {
		slog.Error("worker exited", "err", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.LoadWorker()
	if err != nil {
		return err
	}
	opts, err := redis.ParseURL(cfg.RedisURL)
	if err != nil {
		return fmt.Errorf("REDIS_URL: %w", err)
	}
	rdb := redis.NewClient(opts)
	defer rdb.Close()

	// The pod name is unique per replica, so each pod owns its processing list.
	workerID, _ := os.Hostname()
	q := queue.New(rdb, cfg.QueueName, workerID)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	metrics := worker.NewMetrics()
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", metrics.Handler())
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok\n")) })
	metricsSrv := &http.Server{Addr: fmt.Sprintf(":%d", cfg.MetricsPort), Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := metricsSrv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
			slog.Error("metrics server", "err", err)
		}
	}()
	go metrics.SampleQueue(ctx, q, 5*time.Second)

	wcfg := worker.DefaultConfig()
	wcfg.Metrics = metrics
	slog.Info("worker started", "id", workerID, "queue", cfg.QueueName, "version", version)
	err = worker.Run(ctx, q, wcfg)
	slog.Info("worker stopped; in-flight job finished")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = metricsSrv.Shutdown(shutdownCtx)
	return err
}
