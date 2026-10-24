package queue

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

// Reap returns jobs held by dead workers to the head of the pending list.
//
// A worker is dead when its heartbeat key has expired. Only one reaper acts
// per lockTTL window (SET NX EX), so many workers can run the sweep on a timer
// without fighting. Requeued jobs go to the right-hand (oldest) end because
// they were claimed before anything still pending.
func Reap(ctx context.Context, rdb *redis.Client, name string, lockTTL time.Duration) (int, error) {
	leader, err := rdb.SetNX(ctx, name+":reaper-lock", "1", lockTTL).Result()
	if err != nil || !leader {
		return 0, err
	}

	prefix := name + ":processing:"
	requeued := 0
	iter := rdb.Scan(ctx, 0, prefix+"*", 100).Iterator()
	for iter.Next(ctx) {
		key := iter.Val()
		workerID := strings.TrimPrefix(key, prefix)
		alive, err := rdb.Exists(ctx, heartbeatKey(workerID)).Result()
		if err != nil {
			return requeued, err
		}
		if alive == 1 {
			continue
		}
		for {
			_, err := rdb.LMove(ctx, key, name, "RIGHT", "RIGHT").Result()
			if errors.Is(err, redis.Nil) {
				break
			}
			if err != nil {
				return requeued, err
			}
			requeued++
		}
	}
	return requeued, iter.Err()
}
