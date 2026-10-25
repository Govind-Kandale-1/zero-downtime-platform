package httpapi

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/Govind-Kandale-1/zero-downtime-platform/app/internal/config"
	"github.com/Govind-Kandale-1/zero-downtime-platform/app/internal/queue"
)

// fakeDB answers the items query: ids 1..1000 exist, everything else is absent.
type fakeDB struct{}

type fakeRow struct{ id int }

func (fakeDB) QueryRow(_ context.Context, _ string, args ...any) pgx.Row {
	return fakeRow{id: args[0].(int)}
}

func (r fakeRow) Scan(dest ...any) error {
	if r.id < 1 || r.id > 1000 {
		return pgx.ErrNoRows
	}
	*dest[0].(*int) = r.id
	*dest[1].(*string) = "item"
	return nil
}

type fakeQueue struct{ jobs []queue.Job }

func (q *fakeQueue) Enqueue(_ context.Context, j queue.Job) error {
	q.jobs = append(q.jobs, j)
	return nil
}

func testConfig() config.Config {
	return config.Config{Port: 8080, MaxInflight: 8, QueueName: "jobs", Version: "test"}
}

func newTestServer(cfg config.Config) (*Server, *fakeQueue) {
	q := &fakeQueue{}
	return New(cfg, Deps{DB: fakeDB{}, Queue: q}), q
}

func get(t *testing.T, h http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestReadyzReflectsShutdown(t *testing.T) {
	s, _ := newTestServer(testConfig())
	h := s.Handler()

	if code := get(t, h, "/readyz").Code; code != http.StatusServiceUnavailable {
		t.Fatalf("before SetReady: /readyz = %d, want 503", code)
	}
	s.SetReady(true)
	if code := get(t, h, "/readyz").Code; code != http.StatusOK {
		t.Fatalf("after SetReady(true): /readyz = %d, want 200", code)
	}
	s.MarkShuttingDown()
	if code := get(t, h, "/readyz").Code; code != http.StatusServiceUnavailable {
		t.Fatalf("after MarkShuttingDown: /readyz = %d, want 503", code)
	}
}

func TestHealthzAlwaysOK(t *testing.T) {
	s, _ := newTestServer(testConfig())
	s.MarkShuttingDown()
	rec := get(t, s.Handler(), "/healthz")
	if rec.Code != http.StatusOK || strings.TrimSpace(rec.Body.String()) != "ok" {
		t.Fatalf("/healthz = %d %q, want 200 ok even while shutting down", rec.Code, rec.Body.String())
	}
}

func TestItemsReturnsRowAnd404(t *testing.T) {
	s, _ := newTestServer(testConfig())
	h := s.Handler()

	rec := get(t, h, "/api/items/7")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"id":7`) {
		t.Fatalf("/api/items/7 = %d %q, want 200 with id 7", rec.Code, rec.Body.String())
	}
	if code := get(t, h, "/api/items/5000").Code; code != http.StatusNotFound {
		t.Fatalf("/api/items/5000 = %d, want 404", code)
	}
	if code := get(t, h, "/api/items/abc").Code; code != http.StatusBadRequest {
		t.Fatalf("/api/items/abc = %d, want 400", code)
	}
}

func TestFaultRateOneReturns500(t *testing.T) {
	cfg := testConfig()
	cfg.FaultErrorRate = 1
	s, _ := newTestServer(cfg)

	if code := get(t, s.Handler(), "/api/items/1").Code; code != http.StatusInternalServerError {
		t.Fatalf("/api/items/1 with FaultErrorRate=1 = %d, want 500", code)
	}
}

func TestFaultRateZeroNeverErrors(t *testing.T) {
	s, _ := newTestServer(testConfig())
	h := s.Handler()

	for i := 0; i < 100; i++ {
		if code := get(t, h, "/api/items/1").Code; code >= 500 {
			t.Fatalf("call %d returned %d with FaultErrorRate=0", i, code)
		}
	}
}

func TestPostJobEnqueues(t *testing.T) {
	s, q := newTestServer(testConfig())

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/jobs", strings.NewReader(`{"duration_ms":1500}`))
	s.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusAccepted {
		t.Fatalf("POST /api/jobs = %d %q, want 202", rec.Code, rec.Body.String())
	}
	if len(q.jobs) != 1 || q.jobs[0].DurationMS != 1500 || q.jobs[0].ID == "" || q.jobs[0].EnqueuedAt.IsZero() {
		t.Fatalf("enqueued %+v, want one job with duration 1500, an id and an enqueue time", q.jobs)
	}
	if !strings.Contains(rec.Body.String(), q.jobs[0].ID) {
		t.Fatalf("response %q does not contain job id %q", rec.Body.String(), q.jobs[0].ID)
	}
}

func TestPostJobRejectsDurationOverMax(t *testing.T) {
	s, q := newTestServer(testConfig())

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/jobs", strings.NewReader(`{"duration_ms":60001}`))
	s.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest || len(q.jobs) != 0 {
		t.Fatalf("POST duration 60001 = %d with %d jobs, want 400 and nothing enqueued", rec.Code, len(q.jobs))
	}
}

func TestVersionEndpoint(t *testing.T) {
	s, _ := newTestServer(testConfig())
	rec := get(t, s.Handler(), "/version")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"version":"test"`) {
		t.Fatalf("/version = %d %q", rec.Code, rec.Body.String())
	}
}

func TestMetricsExposeLatencyBucket04(t *testing.T) {
	s, _ := newTestServer(testConfig())
	h := s.Handler()
	get(t, h, "/api/items/1")

	rec := get(t, h, "/metrics")
	body, err := io.ReadAll(rec.Body)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`http_request_duration_seconds_bucket{route="items",le="0.4"}`, `http_requests_total{code="200",route="items"}`, "http_inflight_requests"} {
		if !strings.Contains(string(body), want) {
			t.Fatalf("/metrics missing %q", want)
		}
	}
}
