package config

import (
	"testing"
	"time"
)

func setRequired(t *testing.T) {
	t.Helper()
	t.Setenv("DATABASE_URL", "postgres://app@pgbouncer:5432/app")
	t.Setenv("REDIS_URL", "redis://valkey:6379/0")
}

func TestConfigFaultEnvOverridesDefault(t *testing.T) {
	setRequired(t)

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.FaultErrorRate != FaultErrorRate {
		t.Fatalf("without env, FaultErrorRate = %v, want compiled default %v", cfg.FaultErrorRate, FaultErrorRate)
	}

	t.Setenv("FAULT_ERROR_RATE", "0.25")
	cfg, err = Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.FaultErrorRate != 0.25 {
		t.Fatalf("FaultErrorRate = %v, want 0.25 from env", cfg.FaultErrorRate)
	}
}

func TestConfigRejectsFaultRateOutsideUnitInterval(t *testing.T) {
	setRequired(t)
	t.Setenv("FAULT_ERROR_RATE", "1.5")

	if _, err := Load(); err == nil {
		t.Fatal("Load accepted FAULT_ERROR_RATE=1.5, want error")
	}
}

func TestConfigMigrationURLFallsBack(t *testing.T) {
	setRequired(t)

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.MigrationDatabaseURL != cfg.DatabaseURL {
		t.Fatalf("MigrationDatabaseURL = %q, want fallback to DatabaseURL %q", cfg.MigrationDatabaseURL, cfg.DatabaseURL)
	}

	t.Setenv("MIGRATION_DATABASE_URL", "postgres://app@pg-rw:5432/app")
	cfg, err = Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.MigrationDatabaseURL != "postgres://app@pg-rw:5432/app" {
		t.Fatalf("MigrationDatabaseURL = %q, want the explicit direct URL", cfg.MigrationDatabaseURL)
	}
}

func TestConfigDefaults(t *testing.T) {
	setRequired(t)

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Port != 8080 || cfg.MaxInflight != 8 || cfg.WorkLatency != 40*time.Millisecond ||
		cfg.ShutdownDelay != 5*time.Second || cfg.ShutdownTimeout != 20*time.Second || cfg.QueueName != "jobs" {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
}

func TestConfigRequiresDatabaseAndRedis(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	t.Setenv("REDIS_URL", "redis://valkey:6379/0")
	if _, err := Load(); err == nil {
		t.Fatal("Load accepted empty DATABASE_URL, want error")
	}
}
