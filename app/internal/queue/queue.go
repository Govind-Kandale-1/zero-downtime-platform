// Package queue is a reliable Redis/Valkey list queue (ADR-006).
//
// Keys, for a queue named "jobs":
//
//	jobs                    pending jobs; producers LPUSH, consumers take from the right (oldest)
//	jobs:enqueued_total     counter, for end-to-end job accounting
package queue

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

type Job struct {
	ID         string    `json:"id"`
	EnqueuedAt time.Time `json:"enqueued_at"`
	DurationMS int       `json:"duration_ms"`
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
