// Package queue is a reliable Redis/Valkey list queue (ADR-006).
//
// Keys, for a queue named "jobs":
//
//	jobs                     pending jobs; producers LPUSH, consumers take from the right (oldest)
//	jobs:processing:<worker> jobs a worker has claimed but not finished
//	jobs:failed              malformed jobs, kept for inspection
//	jobs:{enqueued,done,failed}_total   counters for end-to-end job accounting
//	worker:hb:<worker>       heartbeat with a TTL; absent means the worker is dead
//
// A claim atomically moves a job into the worker's processing list (BLMOVE),
// so a crash between claim and completion never loses the job: the reaper
// moves it back. Delivery is therefore at-least-once and jobs must be
// idempotent.
package queue

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

// ErrMalformed means a claimed payload could not be decoded. The returned Job
// still carries the raw payload so the caller can Fail it.
var ErrMalformed = errors.New("malformed job payload")

type Job struct {
	ID         string    `json:"id"`
	EnqueuedAt time.Time `json:"enqueued_at"`
	DurationMS int       `json:"duration_ms"`

	raw string // exact payload as stored; LREM needs the original bytes
}

type Queue struct {
	rdb      *redis.Client
	name     string
	workerID string
}

// New returns a queue handle. workerID names this process's processing list
// and heartbeat; producers that never claim jobs may pass any value.
func New(rdb *redis.Client, name, workerID string) *Queue {
	return &Queue{rdb: rdb, name: name, workerID: workerID}
}

func (q *Queue) processingKey() string { return q.name + ":processing:" + q.workerID }

func heartbeatKey(workerID string) string { return "worker:hb:" + workerID }

// Enqueue pushes the job and bumps the enqueued counter atomically.
func (q *Queue) Enqueue(ctx context.Context, job Job) error {
	payload, err := json.Marshal(job)
	if err != nil {
		return fmt.Errorf("encode job: %w", err)
	}
	_, err = q.rdb.TxPipelined(ctx, func(p redis.Pipeliner) error {
		p.LPush(ctx, q.name, payload)
		p.Incr(ctx, q.name+":enqueued_total")
		return nil
	})
	return err
}

// Claim blocks up to timeout for the oldest pending job and atomically moves
// it into this worker's processing list. It returns nil, nil on timeout.
func (q *Queue) Claim(ctx context.Context, timeout time.Duration) (*Job, error) {
	payload, err := q.rdb.BLMove(ctx, q.name, q.processingKey(), "RIGHT", "LEFT", timeout).Result()
	if errors.Is(err, redis.Nil) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	job := &Job{raw: payload}
	if err := json.Unmarshal([]byte(payload), job); err != nil {
		return job, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	return job, nil
}

// Ack removes a finished job from the processing list and counts it done.
func (q *Queue) Ack(ctx context.Context, job *Job) error {
	_, err := q.rdb.TxPipelined(ctx, func(p redis.Pipeliner) error {
		p.LRem(ctx, q.processingKey(), 1, job.raw)
		p.Incr(ctx, q.name+":done_total")
		return nil
	})
	return err
}

// Fail parks a job in the failed list and counts it failed.
func (q *Queue) Fail(ctx context.Context, job *Job) error {
	_, err := q.rdb.TxPipelined(ctx, func(p redis.Pipeliner) error {
		p.LRem(ctx, q.processingKey(), 1, job.raw)
		p.LPush(ctx, q.name+":failed", job.raw)
		p.Incr(ctx, q.name+":failed_total")
		return nil
	})
	return err
}

// Heartbeat marks this worker alive for ttl.
func (q *Queue) Heartbeat(ctx context.Context, ttl time.Duration) error {
	return q.rdb.Set(ctx, heartbeatKey(q.workerID), "1", ttl).Err()
}

// OldestAge is how long the oldest pending job has waited; 0 when empty.
func (q *Queue) OldestAge(ctx context.Context) (time.Duration, error) {
	payload, err := q.rdb.LIndex(ctx, q.name, -1).Result()
	if errors.Is(err, redis.Nil) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	var job Job
	if err := json.Unmarshal([]byte(payload), &job); err != nil || job.EnqueuedAt.IsZero() {
		return 0, nil // a malformed head can't be aged; the worker will fail it
	}
	return time.Since(job.EnqueuedAt), nil
}

// Depth is the number of pending (unclaimed) jobs.
func (q *Queue) Depth(ctx context.Context) (int64, error) {
	return q.rdb.LLen(ctx, q.name).Result()
}

// Reap runs the dead-worker sweep for this queue (see Reap).
func (q *Queue) Reap(ctx context.Context, lockTTL time.Duration) (int, error) {
	return Reap(ctx, q.rdb, q.name, lockTTL)
}
