package worker

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"

	"github.com/Govind-Kandale-1/zero-downtime-platform/app/internal/queue"
)

func testConfig() Config {
	return Config{
		ClaimTimeout:   100 * time.Millisecond,
		HeartbeatEvery: 50 * time.Millisecond,
		HeartbeatTTL:   time.Second,
		ReapEvery:      50 * time.Millisecond,
		ReapLockTTL:    100 * time.Millisecond,
	}
}

func setup(t *testing.T) (*miniredis.Miniredis, *redis.Client) {
	t.Helper()
	mr := miniredis.RunT(t)
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	t.Cleanup(func() { _ = rdb.Close() })
	return mr, rdb
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func listLen(mr *miniredis.Miniredis, key string) int {
	l, _ := mr.List(key)
	return len(l)
}

func TestWorkerFinishesInflightJobOnCancel(t *testing.T) {
	mr, rdb := setup(t)
	q := queue.New(rdb, "jobs", "w1")
	_ = q.Enqueue(context.Background(), queue.Job{ID: "a", EnqueuedAt: time.Now(), DurationMS: 300})

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Run(ctx, q, testConfig()) }()

	waitFor(t, "job to be claimed", func() bool { return listLen(mr, "jobs:processing:w1") == 1 })
	cancel() // SIGTERM arrives mid-job

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Run returned %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Run did not return after finishing the in-flight job")
	}
	if got, _ := mr.Get("jobs:done_total"); got != "1" {
		t.Fatalf("jobs:done_total = %q, want 1 (the in-flight job must complete)", got)
	}
	if n := listLen(mr, "jobs:processing:w1"); n != 0 {
		t.Fatalf("processing list has %d items; the job was abandoned", n)
	}
}

func TestWorkerStopsClaimingAfterCancel(t *testing.T) {
	mr, rdb := setup(t)
	q := queue.New(rdb, "jobs", "w1")
	for i := 0; i < 3; i++ {
		_ = q.Enqueue(context.Background(), queue.Job{ID: fmt.Sprint(i), EnqueuedAt: time.Now(), DurationMS: 300})
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Run(ctx, q, testConfig()) }()
	waitFor(t, "first job to be claimed", func() bool { return listLen(mr, "jobs:processing:w1") == 1 })
	cancel()
	<-done

	if got, _ := mr.Get("jobs:done_total"); got != "1" {
		t.Fatalf("jobs:done_total = %q, want exactly 1", got)
	}
	if n := listLen(mr, "jobs"); n != 2 {
		t.Fatalf("pending jobs = %d, want 2 left for other workers", n)
	}
}

func TestAccountingInvariant(t *testing.T) {
	mr, rdb := setup(t)
	producer := queue.New(rdb, "jobs", "producer")
	for i := 0; i < 50; i++ {
		_ = producer.Enqueue(context.Background(), queue.Job{ID: fmt.Sprint(i), EnqueuedAt: time.Now(), DurationMS: 5})
	}
	// Two malformed payloads, counted as enqueued like any other.
	for i := 0; i < 2; i++ {
		mr.Lpush("jobs", "garbage")
		_, _ = mr.Incr("jobs:enqueued_total", 1)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 3)
	for i := 0; i < 3; i++ {
		q := queue.New(rdb, "jobs", fmt.Sprintf("w%d", i))
		go func() { done <- Run(ctx, q, testConfig()) }()
	}
	waitFor(t, "queue to drain", func() bool {
		processing, _ := rdb.Keys(context.Background(), "jobs:processing:*").Result()
		busy := 0
		for _, k := range processing {
			busy += listLen(mr, k)
		}
		return listLen(mr, "jobs") == 0 && busy == 0
	})
	cancel()
	for i := 0; i < 3; i++ {
		<-done
	}

	enq, _ := rdb.Get(context.Background(), "jobs:enqueued_total").Int()
	ok, _ := rdb.Get(context.Background(), "jobs:done_total").Int()
	failed, _ := rdb.Get(context.Background(), "jobs:failed_total").Int()
	if enq != 52 || ok != 50 || failed != 2 || enq != ok+failed {
		t.Fatalf("enqueued=%d done=%d failed=%d; want 52 = 50 + 2", enq, ok, failed)
	}
}

func TestWorkerReapsDeadPeersJobs(t *testing.T) {
	mr, rdb := setup(t)
	mr.Lpush("jobs:processing:crashed-pod", `{"id":"orphan","enqueued_at":"2026-01-01T00:00:00Z","duration_ms":1}`)
	q := queue.New(rdb, "jobs", "w1")

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Run(ctx, q, testConfig()) }()
	waitFor(t, "orphaned job to be reaped and completed", func() bool {
		got, _ := mr.Get("jobs:done_total")
		return got == "1"
	})
	cancel()
	<-done
}
