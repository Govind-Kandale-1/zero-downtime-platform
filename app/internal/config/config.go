// Package config reads the stand-in's settings from environment variables.
// Names match the black-box contract (DATABASE_URL, REDIS_URL) plus the
// stand-in-only knobs used to model capacity and inject faults.
package config

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"
)

type Config struct {
	Port                 int
	DatabaseURL          string // via PgBouncer (transaction mode)
	MigrationDatabaseURL string // direct to Postgres; session-level advisory locks need it
	RedisURL             string
	MaxInflight          int           // concurrent requests per pod before callers queue
	WorkLatency          time.Duration // simulated I/O per item read (slept, not CPU-spun)
	FaultErrorRate       float64       // share of API requests answered with 500
	FaultLatency         time.Duration // extra latency added to API requests
	ShutdownDelay        time.Duration // not-ready → stop accepting; lets the ingress deregister us
	ShutdownTimeout      time.Duration // max time to drain in-flight requests
	QueueName            string
	Version              string // set by main from -ldflags
}

func Load() (Config, error) {
	var errs []error
	cfg := Config{
		Port:                 intEnv("PORT", 8080, &errs),
		DatabaseURL:          os.Getenv("DATABASE_URL"),
		MigrationDatabaseURL: os.Getenv("MIGRATION_DATABASE_URL"),
		RedisURL:             os.Getenv("REDIS_URL"),
		MaxInflight:          intEnv("MAX_INFLIGHT", 8, &errs),
		WorkLatency:          msEnv("WORK_LATENCY_MS", 40, &errs),
		FaultErrorRate:       floatEnv("FAULT_ERROR_RATE", FaultErrorRate, &errs),
		FaultLatency:         msEnv("FAULT_LATENCY_MS", 0, &errs),
		ShutdownDelay:        durationEnv("SHUTDOWN_DELAY", 5*time.Second, &errs),
		ShutdownTimeout:      durationEnv("SHUTDOWN_TIMEOUT", 20*time.Second, &errs),
		QueueName:            stringEnv("QUEUE_NAME", "jobs"),
	}
	if cfg.MigrationDatabaseURL == "" {
		cfg.MigrationDatabaseURL = cfg.DatabaseURL
	}
	if cfg.DatabaseURL == "" {
		errs = append(errs, errors.New("DATABASE_URL is required"))
	}
	if cfg.RedisURL == "" {
		errs = append(errs, errors.New("REDIS_URL is required"))
	}
	if cfg.FaultErrorRate < 0 || cfg.FaultErrorRate > 1 {
		errs = append(errs, fmt.Errorf("FAULT_ERROR_RATE must be within [0,1], got %v", cfg.FaultErrorRate))
	}
	if cfg.MaxInflight < 1 {
		errs = append(errs, fmt.Errorf("MAX_INFLIGHT must be >= 1, got %d", cfg.MaxInflight))
	}
	return cfg, errors.Join(errs...)
}

func stringEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func intEnv(key string, def int, errs *[]error) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		*errs = append(*errs, fmt.Errorf("%s: %w", key, err))
		return def
	}
	return n
}

func floatEnv(key string, def float64, errs *[]error) float64 {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		*errs = append(*errs, fmt.Errorf("%s: %w", key, err))
		return def
	}
	return f
}

func msEnv(key string, defMS int, errs *[]error) time.Duration {
	return time.Duration(intEnv(key, defMS, errs)) * time.Millisecond
}

func durationEnv(key string, def time.Duration, errs *[]error) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		*errs = append(*errs, fmt.Errorf("%s: %w", key, err))
		return def
	}
	return d
}
