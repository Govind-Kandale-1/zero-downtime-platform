package httpapi

import "net/http"

// Limiter caps concurrent requests like a real app's worker/thread pool.
// Callers beyond the cap wait (queue) rather than being rejected, so overload
// shows up the way it does in production: as rising latency, which is what
// pushes p95 past 400 ms and makes scaling out necessary.
type Limiter struct {
	slots chan struct{}
}

func NewLimiter(n int) *Limiter {
	return &Limiter{slots: make(chan struct{}, n)}
}

func (l *Limiter) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case l.slots <- struct{}{}:
			defer func() { <-l.slots }()
			next.ServeHTTP(w, r)
		case <-r.Context().Done():
			// The client gave up while queued; don't take a slot.
			http.Error(w, "gave up waiting for capacity", http.StatusServiceUnavailable)
		}
	})
}
