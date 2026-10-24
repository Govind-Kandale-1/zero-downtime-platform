package worker

import (
	"context"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/Govind-Kandale-1/zero-downtime-platform/app/internal/queue"
)

// Metrics are stand-in-only: the brief's worker contract has no /metrics. The
// platform's black-box-safe signal is queue length from redis_exporter; these
// add job outcomes and queue age, which the worker canary analysis uses.
type Metrics struct {
	registry  *prometheus.Registry
	processed *prometheus.CounterVec
	duration  prometheus.Histogram
	oldestAge prometheus.Gauge
	depth     prometheus.Gauge
}

func NewMetrics() *Metrics {
	m := &Metrics{
		registry: prometheus.NewRegistry(),
		processed: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "jobs_processed_total", Help: "Jobs finished, by result (done|failed).",
		}, []string{"result"}),
		duration: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name: "job_duration_seconds", Help: "Time spent processing a job.",
			Buckets: []float64{0.1, 0.5, 1, 2, 5, 10, 20, 30, 45, 60},
		}),
		oldestAge: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "queue_oldest_job_age_seconds", Help: "Age of the oldest pending job.",
		}),
		depth: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "queue_depth", Help: "Pending (unclaimed) jobs.",
		}),
	}
	m.processed.WithLabelValues("done")
	m.processed.WithLabelValues("failed")
	m.registry.MustRegister(m.processed, m.duration, m.oldestAge, m.depth,
		collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))
	return m
}

func (m *Metrics) Handler() http.Handler {
	return promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{})
}

// SampleQueue refreshes the queue gauges every interval until ctx ends.
func (m *Metrics) SampleQueue(ctx context.Context, q *queue.Queue, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		if age, err := q.OldestAge(ctx); err == nil {
			m.oldestAge.Set(age.Seconds())
		}
		if d, err := q.Depth(ctx); err == nil {
			m.depth.Set(float64(d))
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func record(m *Metrics, result string, took time.Duration) {
	if m == nil {
		return
	}
	m.processed.WithLabelValues(result).Inc()
	if result == "done" {
		m.duration.Observe(took.Seconds())
	}
}
