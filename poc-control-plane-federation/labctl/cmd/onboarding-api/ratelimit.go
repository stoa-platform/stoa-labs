package main

import (
	"sync"
	"time"
)

// rateLimiter is a per-principal fixed-window throttle for the SHARED management
// plane: one tenant's developer must not be able to flood onboarding-api and
// starve the others. It is keyed by actor+tenant (the VALIDATED identity, never
// a forgeable header), stdlib-only (no vendored dependency — air-gapped), and
// deliberately tiny: a one-minute window per key with a max count.
//
// A nil *rateLimiter allows everything (the limiter is optional — the handler
// stays usable in tests that don't wire one). perMin <= 0 also disables it.
type rateLimiter struct {
	mu      sync.Mutex
	perMin  int
	windows map[string]*rlWindow
}

type rlWindow struct {
	start time.Time
	count int
}

// newRateLimiter builds a limiter admitting perMin requests per key per minute.
func newRateLimiter(perMin int) *rateLimiter {
	return &rateLimiter{perMin: perMin, windows: map[string]*rlWindow{}}
}

// allow reports whether the key may proceed at instant now, counting this
// request when it does. The first request of a fresh window always passes; once
// perMin is reached within the window, further requests are refused until the
// minute rolls. A nil limiter or a non-positive perMin never throttles.
func (r *rateLimiter) allow(key string, now time.Time) bool {
	if r == nil || r.perMin <= 0 {
		return true
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	w := r.windows[key]
	if w == nil || now.Sub(w.start) >= time.Minute {
		r.windows[key] = &rlWindow{start: now, count: 1}
		return true
	}
	if w.count >= r.perMin {
		return false
	}
	w.count++
	return true
}
