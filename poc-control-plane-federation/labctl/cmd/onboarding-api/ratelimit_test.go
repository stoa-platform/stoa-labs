package main

import (
	"testing"
	"time"
)

func TestRateLimiter_Window(t *testing.T) {
	t0 := time.Date(2026, 6, 12, 10, 0, 0, 0, time.UTC)
	r := newRateLimiter(3)

	// first 3 in the window pass, the 4th and 5th are refused
	for i := 1; i <= 3; i++ {
		if !r.allow("alice|banking-demo", t0) {
			t.Fatalf("request %d should pass within limit", i)
		}
	}
	if r.allow("alice|banking-demo", t0) {
		t.Error("4th request must be refused (over limit)")
	}
	if r.allow("alice|banking-demo", t0.Add(59*time.Second)) {
		t.Error("still within the same minute window: refused")
	}

	// the window rolls after a minute → fresh budget
	if !r.allow("alice|banking-demo", t0.Add(60*time.Second)) {
		t.Error("after the minute rolls, the budget resets")
	}
}

func TestRateLimiter_PerKeyIsolation(t *testing.T) {
	t0 := time.Date(2026, 6, 12, 10, 0, 0, 0, time.UTC)
	r := newRateLimiter(1)
	if !r.allow("alice|banking-demo", t0) {
		t.Fatal("alice first request passes")
	}
	if r.allow("alice|banking-demo", t0) {
		t.Error("alice second request refused")
	}
	// a different principal has its own independent budget
	if !r.allow("bob|payments-team", t0) {
		t.Error("bob must not be throttled by alice's usage")
	}
}

func TestRateLimiter_DisabledAndNil(t *testing.T) {
	t0 := time.Date(2026, 6, 12, 10, 0, 0, 0, time.UTC)
	// perMin <= 0 disables throttling
	r := newRateLimiter(0)
	for i := 0; i < 100; i++ {
		if !r.allow("alice|banking-demo", t0) {
			t.Fatal("perMin<=0 must never throttle")
		}
	}
	// a nil limiter allows everything (handler stays usable without one)
	var nilr *rateLimiter
	if !nilr.allow("alice|banking-demo", t0) {
		t.Error("nil limiter must allow")
	}
}
