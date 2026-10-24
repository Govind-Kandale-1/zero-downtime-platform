package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestLimiterSerializesBeyondCapacity(t *testing.T) {
	slow := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(50 * time.Millisecond)
		w.WriteHeader(http.StatusOK)
	})
	h := NewLimiter(1).Wrap(slow)

	start := time.Now()
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/", nil))
		}()
	}
	wg.Wait()

	if elapsed := time.Since(start); elapsed < 100*time.Millisecond {
		t.Fatalf("two 50ms requests through a limit of 1 took %v, want >= 100ms (queued, not parallel)", elapsed)
	}
}

func TestLimiterReleasesOnContextCancel(t *testing.T) {
	release := make(chan struct{})
	blocking := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		<-release
		w.WriteHeader(http.StatusOK)
	})
	h := NewLimiter(1).Wrap(blocking)

	// Occupy the only slot.
	done := make(chan struct{})
	go func() {
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/", nil))
		close(done)
	}()
	time.Sleep(20 * time.Millisecond)

	// A waiter whose client gives up must return promptly, not hang.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil).WithContext(ctx))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("cancelled waiter got %d, want 503", rec.Code)
	}

	// The cancelled waiter must not have leaked the slot.
	close(release)
	<-done
	finished := make(chan int, 1)
	go func() {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
		finished <- rec.Code
	}()
	select {
	case code := <-finished:
		if code != http.StatusOK {
			t.Fatalf("request after release got %d, want 200", code)
		}
	case <-time.After(time.Second):
		t.Fatal("slot leaked: request after release never ran")
	}
}
