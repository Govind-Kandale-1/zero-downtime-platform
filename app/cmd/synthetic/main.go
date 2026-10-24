// Command synthetic is platform tooling, not part of the black-box contract.
// It sends a small constant stream of traffic to every stack through the
// ingress so canary analysis always has data (ADR-016), and doubles as a
// black-box probe. Requests carry X-Synthetic: 1 so dashboards can split
// them out.
package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// maxInflightPerHost stops a slow target from piling up goroutines.
const maxInflightPerHost = 20

func main() {
	if err := run(); err != nil {
		slog.Error("synthetic exited", "err", err)
		os.Exit(1)
	}
}

func run() error {
	target := envOr("TRAFFIC_TARGET", "http://traefik.traefik.svc")
	hosts := parseHosts(os.Getenv("HOSTS"))
	if len(hosts) == 0 {
		return errors.New("HOSTS is empty")
	}
	rps, err := strconv.Atoi(envOr("RPS_PER_HOST", "10"))
	if err != nil || rps < 1 {
		return fmt.Errorf("RPS_PER_HOST must be a positive integer")
	}
	jobEvery, err := time.ParseDuration(envOr("JOB_EVERY", "10s"))
	if err != nil {
		return fmt.Errorf("JOB_EVERY: %w", err)
	}

	requests := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "synthetic_requests_total", Help: "Synthetic requests by host and status code.",
	}, []string{"host", "code"})
	reg := prometheus.NewRegistry()
	reg.MustRegister(requests)
	go func() {
		mux := http.NewServeMux()
		mux.Handle("GET /metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
		srv := &http.Server{Addr: ":9090", Handler: mux, ReadHeaderTimeout: 5 * time.Second}
		slog.Error("metrics server", "err", srv.ListenAndServe())
	}()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	client := &http.Client{Timeout: 5 * time.Second}

	slog.Info("synthetic traffic started", "target", target, "hosts", hosts, "rps_per_host", rps, "job_every", jobEvery)
	for _, host := range hosts {
		slots := make(chan struct{}, maxInflightPerHost)
		send := func(method, path string, body []byte) {
			select {
			case slots <- struct{}{}:
			default:
				requests.WithLabelValues(host, "skipped").Inc()
				return
			}
			go func() {
				defer func() { <-slots }()
				req, _ := http.NewRequestWithContext(ctx, method, target+path, bytes.NewReader(body))
				req.Host = host
				req.Header.Set("X-Synthetic", "1")
				if body != nil {
					req.Header.Set("Content-Type", "application/json")
				}
				resp, err := client.Do(req)
				if err != nil {
					requests.WithLabelValues(host, "error").Inc()
					return
				}
				_ = resp.Body.Close()
				requests.WithLabelValues(host, strconv.Itoa(resp.StatusCode)).Inc()
			}()
		}
		go tick(ctx, time.Second/time.Duration(rps), func() {
			send(http.MethodGet, fmt.Sprintf("/api/items/%d", rand.IntN(1000)+1), nil)
		})
		go tick(ctx, jobEvery, func() {
			send(http.MethodPost, "/api/jobs", []byte(`{"duration_ms":2000}`))
		})
	}
	<-ctx.Done()
	return nil
}

// parseHosts splits a comma list, trimming blanks and dropping empties.
func parseHosts(s string) []string {
	var out []string
	for _, h := range strings.Split(s, ",") {
		if h = strings.TrimSpace(h); h != "" {
			out = append(out, h)
		}
	}
	return out
}

func tick(ctx context.Context, d time.Duration, fn func()) {
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

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
