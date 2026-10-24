package queue

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func newTestQueue(t *testing.T, workerID string) (*Queue, *miniredis.Miniredis, *redis.Client) {
	t.Helper()
	mr := miniredis.RunT(t)
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	t.Cleanup(func() { _ = rdb.Close() })
	return New(rdb, "jobs", workerID), mr, rdb
}

func TestEnqueueLPushesAndCounts(t *testing.T) {
	q, mr, _ := newTestQueue(t, "w1")
	ctx := context.Background()

	if err := q.Enqueue(ctx, Job{ID: "a", EnqueuedAt: time.Now().UTC(), DurationMS: 100}); err != nil {
		t.Fatalf("Enqueue: %v", err)
	}

	items, err := mr.List("jobs")
	if err != nil || len(items) != 1 {
		t.Fatalf("LLEN jobs = %d (%v), want 1", len(items), err)
	}
	if got, _ := mr.Get("jobs:enqueued_total"); got != "1" {
		t.Fatalf("jobs:enqueued_total = %q, want 1", got)
	}
	var j Job
	if err := json.Unmarshal([]byte(items[0]), &j); err != nil {
		t.Fatalf("payload not JSON: %v", err)
	}
	if j.ID != "a" || j.DurationMS != 100 || j.EnqueuedAt.IsZero() {
		t.Fatalf("payload = %+v, want id a, duration 100, non-zero enqueued_at", j)
	}
}
