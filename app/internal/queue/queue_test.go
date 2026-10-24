package queue

import (
	"context"
	"testing"
	"time"
)

func TestClaimMovesToProcessingList(t *testing.T) {
	q, mr, _ := newTestQueue(t, "w1")
	ctx := context.Background()
	if err := q.Enqueue(ctx, Job{ID: "a", EnqueuedAt: time.Now(), DurationMS: 5}); err != nil {
		t.Fatal(err)
	}

	job, err := q.Claim(ctx, time.Second)
	if err != nil || job == nil || job.ID != "a" {
		t.Fatalf("Claim = %+v, %v; want job a", job, err)
	}
	if pending, _ := mr.List("jobs"); len(pending) != 0 {
		t.Fatalf("jobs still has %d items after claim", len(pending))
	}
	if inflight, _ := mr.List("jobs:processing:w1"); len(inflight) != 1 {
		t.Fatalf("jobs:processing:w1 has %d items, want 1", len(inflight))
	}
}

func TestClaimTakesOldestFirst(t *testing.T) {
	q, _, _ := newTestQueue(t, "w1")
	ctx := context.Background()
	for _, id := range []string{"first", "second"} {
		if err := q.Enqueue(ctx, Job{ID: id, EnqueuedAt: time.Now()}); err != nil {
			t.Fatal(err)
		}
	}
	job, err := q.Claim(ctx, time.Second)
	if err != nil || job.ID != "first" {
		t.Fatalf("Claim = %+v, %v; want the oldest job (first)", job, err)
	}
}

func TestClaimTimesOutWithNil(t *testing.T) {
	q, _, _ := newTestQueue(t, "w1")

	job, err := q.Claim(context.Background(), 100*time.Millisecond)
	if err != nil || job != nil {
		t.Fatalf("Claim on empty queue = %+v, %v; want nil, nil", job, err)
	}
}

func TestAckRemovesAndCounts(t *testing.T) {
	q, mr, _ := newTestQueue(t, "w1")
	ctx := context.Background()
	_ = q.Enqueue(ctx, Job{ID: "a", EnqueuedAt: time.Now()})
	job, _ := q.Claim(ctx, time.Second)

	if err := q.Ack(ctx, job); err != nil {
		t.Fatalf("Ack: %v", err)
	}
	if inflight, _ := mr.List("jobs:processing:w1"); len(inflight) != 0 {
		t.Fatalf("processing list still has %d items after Ack", len(inflight))
	}
	if got, _ := mr.Get("jobs:done_total"); got != "1" {
		t.Fatalf("jobs:done_total = %q, want 1", got)
	}
}

func TestFailMovesToFailedListAndCounts(t *testing.T) {
	q, mr, _ := newTestQueue(t, "w1")
	ctx := context.Background()
	mr.Lpush("jobs", "not-json")

	job, err := q.Claim(ctx, time.Second)
	if err == nil || job == nil {
		t.Fatalf("Claim of malformed payload = %+v, %v; want the job and ErrMalformed", job, err)
	}
	if err := q.Fail(ctx, job); err != nil {
		t.Fatalf("Fail: %v", err)
	}
	if failed, _ := mr.List("jobs:failed"); len(failed) != 1 || failed[0] != "not-json" {
		t.Fatalf("jobs:failed = %v, want [not-json]", failed)
	}
	if got, _ := mr.Get("jobs:failed_total"); got != "1" {
		t.Fatalf("jobs:failed_total = %q, want 1", got)
	}
	if inflight, _ := mr.List("jobs:processing:w1"); len(inflight) != 0 {
		t.Fatalf("processing list still has %d items after Fail", len(inflight))
	}
}

func TestOldestAgeReadsTail(t *testing.T) {
	q, _, _ := newTestQueue(t, "w1")
	ctx := context.Background()

	if age, err := q.OldestAge(ctx); err != nil || age != 0 {
		t.Fatalf("OldestAge on empty queue = %v, %v; want 0", age, err)
	}
	_ = q.Enqueue(ctx, Job{ID: "old", EnqueuedAt: time.Now().Add(-30 * time.Second)})
	_ = q.Enqueue(ctx, Job{ID: "new", EnqueuedAt: time.Now()})

	age, err := q.OldestAge(ctx)
	if err != nil || age < 29*time.Second || age > 40*time.Second {
		t.Fatalf("OldestAge = %v, %v; want ~30s (the oldest job, not the newest)", age, err)
	}
	if depth, err := q.Depth(ctx); err != nil || depth != 2 {
		t.Fatalf("Depth = %d, %v; want 2", depth, err)
	}
}

func TestHeartbeatSetsExpiringKey(t *testing.T) {
	q, mr, _ := newTestQueue(t, "w1")
	if err := q.Heartbeat(context.Background(), 30*time.Second); err != nil {
		t.Fatal(err)
	}
	if !mr.Exists("worker:hb:w1") {
		t.Fatal("worker:hb:w1 not set")
	}
	if ttl := mr.TTL("worker:hb:w1"); ttl <= 0 || ttl > 30*time.Second {
		t.Fatalf("heartbeat TTL = %v, want (0, 30s]", ttl)
	}
}
