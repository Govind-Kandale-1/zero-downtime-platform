package config

import (
	"errors"
)

// Worker is the stand-in worker's configuration. The worker gets the same
// app-env Secret as the API, but needs only the queue.
type Worker struct {
	RedisURL    string
	QueueName   string
	MetricsPort int
}

func LoadWorker() (Worker, error) {
	var errs []error
	w := Worker{
		RedisURL:    stringEnv("REDIS_URL", ""),
		QueueName:   stringEnv("QUEUE_NAME", "jobs"),
		MetricsPort: intEnv("METRICS_PORT", 9090, &errs),
	}
	if w.RedisURL == "" {
		errs = append(errs, errors.New("REDIS_URL is required"))
	}
	return w, errors.Join(errs...)
}
