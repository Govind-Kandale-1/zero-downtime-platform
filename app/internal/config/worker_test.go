package config

import "testing"

func TestLoadWorkerRequiresRedisAndDefaults(t *testing.T) {
	t.Setenv("REDIS_URL", "")
	if _, err := LoadWorker(); err == nil {
		t.Fatal("LoadWorker accepted empty REDIS_URL")
	}

	t.Setenv("REDIS_URL", "redis://valkey:6379/0")
	w, err := LoadWorker()
	if err != nil {
		t.Fatal(err)
	}
	if w.QueueName != "jobs" || w.MetricsPort != 9090 {
		t.Fatalf("defaults = %+v, want queue jobs and metrics port 9090", w)
	}
}
