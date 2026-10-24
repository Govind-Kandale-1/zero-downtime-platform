// Package worker is the stand-in's queue consumer. Its one hard rule: once a
// job is claimed it is finished, even after SIGTERM — so neither a rollout nor
// a KEDA scale-in drops work, provided the pod's terminationGracePeriodSeconds
// (90 s) exceeds the longest job (60 s).
package worker

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"time"

	"github.com/Govind-Kandale-1/zero-downtime-platform/app/internal/queue"
)

type Config struct {
	ClaimTimeout   time.Duration // how long one BLMOVE blocks; bounds shutdown latency
	HeartbeatEvery time.Duration
	HeartbeatTTL   time.Duration // > 2 × HeartbeatEvery so one missed beat is not death
	ReapEvery      time.Duration
	ReapLockTTL    time.Duration
	Metrics        *Metrics // optional
}

// DefaultConfig matches the design: 2 s claims, 10 s/30 s heartbeat, 15 s reaper.
func DefaultConfig() Config {
	return Config{
		ClaimTimeout:   2 * time.Second,
		HeartbeatEvery: 10 * time.Second,
		HeartbeatTTL:   30 * time.Second,
		ReapEvery:      15 * time.Second,
		ReapLockTTL:    10 * time.Second,
	}
}

// Run consumes jobs until ctx is cancelled, then finishes the job in hand and
// returns. Background housekeeping (heartbeat) outlives ctx until Run returns,
// so the reaper never steals the job this worker is still finishing.
func Run(ctx context.Context, q *queue.Queue, cfg Config) error {
	bg, stopBG := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	defer func() { stopBG(); wg.Wait() }()

	if err := q.Heartbeat(bg, cfg.HeartbeatTTL); err != nil {
		slog.Warn("initial heartbeat failed", "err", err)
	}
	wg.Add(2)
	go every(bg, cfg.HeartbeatEvery, &wg, func() {
		if err := q.Heartbeat(bg, cfg.HeartbeatTTL); err != nil {
			slog.Warn("heartbeat failed", "err", err)
		}
	})
	go every(ctx, cfg.ReapEvery, &wg, func() {
		if n, err := q.Reap(bg, cfg.ReapLockTTL); err != nil {
			slog.Warn("reaper failed", "err", err)
		} else if n > 0 {
			slog.Info("requeued jobs from dead workers", "count", n)
		}
	})

	for ctx.Err() == nil {
		// Claim on the background context: a claim interrupted by SIGTERM
		// could move a job and then lose the reply. ClaimTimeout bounds it.
		job, err := q.Claim(bg, cfg.ClaimTimeout)
		switch {
		case errors.Is(err, queue.ErrMalformed):
			record(cfg.Metrics, "failed", 0)
			if err := q.Fail(bg, job); err != nil {
				slog.Error("fail job", "err", err)
			}
		case err != nil:
			slog.Warn("claim failed; backing off", "err", err)
			sleep(ctx, time.Second)
		case job != nil:
			start := time.Now()
			time.Sleep(time.Duration(job.DurationMS) * time.Millisecond) // the "work"; never interrupted
			if err := q.Ack(bg, job); err != nil {
				slog.Error("ack job", "id", job.ID, "err", err)
				continue
			}
			record(cfg.Metrics, "done", time.Since(start))
		}
	}
	return nil
}

func every(ctx context.Context, d time.Duration, wg *sync.WaitGroup, fn func()) {
	defer wg.Done()
	t := time.NewTicker(d)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			fn()
		}
	}
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}
