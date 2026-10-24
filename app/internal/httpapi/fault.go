package httpapi

import (
	"math/rand/v2"
	"net/http"
	"time"
)

// injectFault applies the stand-in-only fault knobs to an API request. It
// returns true when it has already answered the request with a 500.
// Health endpoints never call it, so a "bad release" fails its canary
// analysis instead of being killed by liveness probes.
func (s *Server) injectFault(w http.ResponseWriter, r *http.Request) bool {
	if s.cfg.FaultLatency > 0 {
		select {
		case <-time.After(s.cfg.FaultLatency):
		case <-r.Context().Done():
		}
	}
	if s.cfg.FaultErrorRate > 0 && rand.Float64() < s.cfg.FaultErrorRate {
		http.Error(w, "injected fault", http.StatusInternalServerError)
		return true
	}
	return false
}
