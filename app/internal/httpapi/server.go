// Package httpapi implements the black-box API contract: port 8080,
// /healthz, /readyz, /metrics, plus two business routes used by load tests.
package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/Govind-Kandale-1/zero-downtime-platform/app/internal/config"
	"github.com/Govind-Kandale-1/zero-downtime-platform/app/internal/queue"
)

// maxJobDuration mirrors the brief: jobs take up to 60 s.
const maxJobDuration = 60_000

// Querier is the slice of *pgxpool.Pool the API needs.
type Querier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// Enqueuer is the slice of *queue.Queue the API needs.
type Enqueuer interface {
	Enqueue(ctx context.Context, job queue.Job) error
}

type Deps struct {
	DB    Querier
	Queue Enqueuer
}

type Server struct {
	cfg          config.Config
	deps         Deps
	metrics      *metrics
	limiter      *Limiter
	ready        atomic.Bool
	shuttingDown atomic.Bool
}

func New(cfg config.Config, deps Deps) *Server {
	return &Server{cfg: cfg, deps: deps, metrics: newMetrics(), limiter: NewLimiter(cfg.MaxInflight)}
}

// SetReady reports whether dependencies are reachable and migrations are done.
func (s *Server) SetReady(ok bool) { s.ready.Store(ok) }

// MarkShuttingDown makes /readyz fail so the ingress stops routing to this pod
// before the HTTP server stops accepting connections.
func (s *Server) MarkShuttingDown() { s.shuttingDown.Store(true) }

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	m := s.metrics
	mux.Handle("GET /healthz", m.instrument("healthz", http.HandlerFunc(s.healthz)))
	mux.Handle("GET /readyz", m.instrument("readyz", http.HandlerFunc(s.readyz)))
	mux.Handle("GET /metrics", m.handler())
	mux.Handle("GET /version", m.instrument("version", http.HandlerFunc(s.version)))
	mux.Handle("GET /api/items/{id}", m.instrument("items", s.limiter.Wrap(http.HandlerFunc(s.getItem))))
	mux.Handle("POST /api/jobs", m.instrument("jobs", s.limiter.Wrap(http.HandlerFunc(s.postJob))))
	return mux
}

func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	_, _ = w.Write([]byte("ok\n"))
}

func (s *Server) readyz(w http.ResponseWriter, _ *http.Request) {
	if !s.ready.Load() || s.shuttingDown.Load() {
		http.Error(w, "not ready", http.StatusServiceUnavailable)
		return
	}
	_, _ = w.Write([]byte("ready\n"))
}

func (s *Server) version(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"version": s.cfg.Version})
}

func (s *Server) getItem(w http.ResponseWriter, r *http.Request) {
	if s.injectFault(w, r) {
		return
	}
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		http.Error(w, "id must be an integer", http.StatusBadRequest)
		return
	}
	if s.cfg.WorkLatency > 0 {
		select {
		case <-time.After(s.cfg.WorkLatency):
		case <-r.Context().Done():
			return
		}
	}
	var item struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	}
	err = s.deps.DB.QueryRow(r.Context(), "SELECT id, name FROM items WHERE id = $1", id).Scan(&item.ID, &item.Name)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		http.Error(w, "not found", http.StatusNotFound)
	case err != nil:
		slog.Error("items query failed", "err", err)
		http.Error(w, "database error", http.StatusInternalServerError)
	default:
		writeJSON(w, http.StatusOK, item)
	}
}

func (s *Server) postJob(w http.ResponseWriter, r *http.Request) {
	if s.injectFault(w, r) {
		return
	}
	var body struct {
		DurationMS int `json:"duration_ms"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&body); err != nil {
		http.Error(w, "body must be {\"duration_ms\": int}", http.StatusBadRequest)
		return
	}
	if body.DurationMS < 0 || body.DurationMS > maxJobDuration {
		http.Error(w, "duration_ms must be within [0, 60000]", http.StatusBadRequest)
		return
	}
	job := queue.Job{ID: newID(), EnqueuedAt: time.Now().UTC(), DurationMS: body.DurationMS}
	if err := s.deps.Queue.Enqueue(r.Context(), job); err != nil {
		slog.Error("enqueue failed", "err", err)
		http.Error(w, "queue unavailable", http.StatusServiceUnavailable)
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]string{"id": job.ID})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func newID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
