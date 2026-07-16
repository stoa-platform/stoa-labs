package main

import (
	"encoding/json"
	"testing"
)

func tpOf(t *testing.T, raw []byte) string {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	rh, ok := m["requestHeaders"].(map[string]any)
	if !ok {
		t.Fatalf("no requestHeaders in %s", raw)
	}
	tp, _ := rh["traceparent"].(string)
	return tp
}

func TestEnsureTraceparent_InjectsWhenAbsent(t *testing.T) {
	raw := []byte(`{"eventType":"Transactional","apiName":"accounts-read","requestHeaders":{"User-Agent":"curl"}}`)
	tp := tpOf(t, ensureTraceparent(raw))
	if !validTP.MatchString(tp) {
		t.Fatalf("expected an injected W3C traceparent, got %q", tp)
	}
	if tp[3:35] == zeros32 {
		t.Error("injected trace_id must not be all-zero")
	}
}

func TestEnsureTraceparent_CreatesHeadersWhenMissing(t *testing.T) {
	raw := []byte(`{"eventType":"Transactional","apiName":"x"}`)
	tp := tpOf(t, ensureTraceparent(raw))
	if !validTP.MatchString(tp) {
		t.Errorf("traceparent should be injected even without requestHeaders, got %q", tp)
	}
}

func TestEnsureTraceparent_PreservesUpstream(t *testing.T) {
	want := "00-1111111111111111111111111111aaaa-2222222222222222-01"
	raw := []byte(`{"requestHeaders":{"traceparent":"` + want + `"}}`)
	if got := tpOf(t, ensureTraceparent(raw)); got != want {
		t.Errorf("upstream traceparent must be preserved: got %q want %q", got, want)
	}
}

func TestEnsureTraceparent_ReplacesZeroTraceID(t *testing.T) {
	raw := []byte(`{"requestHeaders":{"traceparent":"00-` + zeros32 + `-2222222222222222-01"}}`)
	tp := tpOf(t, ensureTraceparent(raw))
	if tp[3:35] == zeros32 {
		t.Error("an all-zero trace_id must be replaced with a real one")
	}
}

func TestEnsureTraceparent_BadJSONPassthrough(t *testing.T) {
	if got := string(ensureTraceparent([]byte("not json"))); got != "not json" {
		t.Errorf("invalid JSON must pass through unchanged, got %q", got)
	}
}

func TestEnsureTraceparent_TwoCallsDistinct(t *testing.T) {
	raw := []byte(`{"requestHeaders":{}}`)
	if tpOf(t, ensureTraceparent(raw)) == tpOf(t, ensureTraceparent(raw)) {
		t.Error("injected trace ids must be fresh per call")
	}
}
