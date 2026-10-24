//go:build integration

package queue

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

// TestQueueLifecycleOnValkey runs claim → crash → reap → claim → ack against a
// real Valkey, proving BLMOVE/LMOVE/SET NX semantics match what miniredis
// emulates in the unit tests.
func TestQueueLifecycleOnValkey(t *testing.T) {
	url := os.Getenv("TEST_REDIS_URL")
	if url == "" {
		t.Fatal("TEST_REDIS_URL not set (run via scripts/test-go.sh integration)")
	}
	opts, err := redis.ParseURL(url)
	if err != nil {
		t.Fatal(err)
	}
	rdb := redis.NewClient(opts)
	defer rdb.Close()
	ctx := context.Background()
	if err := rdb.FlushDB(ctx).Err(); err != nil {
		t.Fatal(err)
	}

	producer := New(rdb, "jobs", "api")
	if err := producer.Enqueue(ctx, Job{ID: "j1", EnqueuedAt: time.Now(), DurationMS: 1}); err != nil {
		t.Fatal(err)
	}

	// Worker A claims the job, then "crashes": no heartbeat, no ack.
	a := New(rdb, "jobs", "pod-a")
	if job, err := a.Claim(ctx, time.Second); err != nil || job == nil {
		t.Fatalf("pod-a claim = %v, %v", job, err)
	}

	// Worker B (alive) reaps A's processing list and completes the job.
	b := New(rdb, "jobs", "pod-b")
	if err := b.Heartbeat(ctx, 30*time.Second); err != nil {
		t.Fatal(err)
	}
	if n, err := b.Reap(ctx, 5*time.Second); err != nil || n != 1 {
		t.Fatalf("reap = %d, %v; want 1", n, err)
	}
	job, err := b.Claim(ctx, time.Second)
	if err != nil || job == nil || job.ID != "j1" {
		t.Fatalf("pod-b claim = %+v, %v; want j1", job, err)
	}
	if err := b.Ack(ctx, job); err != nil {
		t.Fatal(err)
	}

	enq, _ := rdb.Get(ctx, "jobs:enqueued_total").Int()
	done, _ := rdb.Get(ctx, "jobs:done_total").Int()
	left, _ := rdb.Keys(ctx, "jobs:processing:*").Result()
	if enq != 1 || done != 1 || len(left) != 0 {
		t.Fatalf("enqueued=%d done=%d processing=%v; want 1, 1, none", enq, done, left)
	}
}
