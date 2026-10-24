package queue

import (
	"context"
	"testing"
	"time"
)

func TestReapRequeuesDeadWorkerOnly(t *testing.T) {
	_, mr, rdb := newTestQueue(t, "unused")
	mr.Lpush("jobs:processing:dead", "job-of-dead-worker")
	mr.Lpush("jobs:processing:alive", "job-of-live-worker")
	_ = mr.Set("worker:hb:alive", "1")

	n, err := Reap(context.Background(), rdb, "jobs", 10*time.Second)
	if err != nil || n != 1 {
		t.Fatalf("Reap = %d, %v; want 1 requeued", n, err)
	}
	if pending, _ := mr.List("jobs"); len(pending) != 1 || pending[0] != "job-of-dead-worker" {
		t.Fatalf("jobs = %v, want the dead worker's job back", pending)
	}
	if alive, _ := mr.List("jobs:processing:alive"); len(alive) != 1 {
		t.Fatalf("live worker's processing list = %v, must be untouched", alive)
	}
	if mr.Exists("jobs:processing:dead") {
		t.Fatal("dead worker's processing list should be empty (deleted)")
	}
}

func TestReapPutsRequeuedJobsAtTheHead(t *testing.T) {
	q, mr, rdb := newTestQueue(t, "w1")
	ctx := context.Background()
	_ = q.Enqueue(ctx, Job{ID: "newer", EnqueuedAt: time.Now()})
	mr.Lpush("jobs:processing:dead", `{"id":"rescued","enqueued_at":"2026-01-01T00:00:00Z","duration_ms":1}`)

	if _, err := Reap(ctx, rdb, "jobs", 10*time.Second); err != nil {
		t.Fatal(err)
	}
	job, err := q.Claim(ctx, time.Second)
	if err != nil || job.ID != "rescued" {
		t.Fatalf("next claim = %+v, %v; want the rescued job first (it is older)", job, err)
	}
}

func TestReapSingleLeader(t *testing.T) {
	_, mr, rdb := newTestQueue(t, "unused")
	ctx := context.Background()
	mr.Lpush("jobs:processing:deadA", "a")
	if n, err := Reap(ctx, rdb, "jobs", 10*time.Second); err != nil || n != 1 {
		t.Fatalf("first Reap = %d, %v; want 1", n, err)
	}

	// While the first reaper's lock is held, another reaper does nothing.
	mr.Lpush("jobs:processing:deadB", "b")
	if n, err := Reap(ctx, rdb, "jobs", 10*time.Second); err != nil || n != 0 {
		t.Fatalf("second Reap = %d, %v; want 0 (lock held)", n, err)
	}
	if b, _ := mr.List("jobs:processing:deadB"); len(b) != 1 {
		t.Fatal("second reaper touched deadB while not leader")
	}
}
