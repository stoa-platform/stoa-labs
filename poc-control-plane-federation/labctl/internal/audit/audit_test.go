package audit

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// bufLogger returns a *log.Logger writing into a buffer, so a test can assert on
// the structured stdout line the Recorder always emits.
func bufLogger() (*log.Logger, *bytes.Buffer) {
	var b bytes.Buffer
	return log.New(&b, "", 0), &b
}

// TestEventJSON pins the wire shape: the audit doc carries exactly the documented
// keys, and commit_sha is omitted when empty (it is optional on the DENY paths).
func TestEventJSON(t *testing.T) {
	ev := Event{
		Timestamp: "2026-06-12T00:00:00Z", Actor: "onboarder-banking",
		Action: ActionOnboard, Tenant: "banking-demo", Partner: "acme",
		Decision: Accept, Reason: "ok", TraceID: "abc", ClientIP: "203.0.113.10",
		HTTPStatus: 201,
	}
	raw, err := json.Marshal(ev)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	s := string(raw)
	for _, key := range []string{
		`"timestamp"`, `"actor"`, `"action"`, `"tenant"`, `"partner"`,
		`"decision"`, `"reason"`, `"trace_id"`, `"client_ip"`, `"http_status"`,
	} {
		if !strings.Contains(s, key) {
			t.Errorf("marshalled event missing %s: %s", key, s)
		}
	}
	if strings.Contains(s, "commit_sha") {
		t.Errorf("commit_sha must be omitted when empty: %s", s)
	}

	ev.CommitSHA = "deadbeef"
	raw, _ = json.Marshal(ev)
	if !strings.Contains(string(raw), `"commit_sha":"deadbeef"`) {
		t.Errorf("commit_sha must appear when set: %s", raw)
	}
}

// TestSanitizeTenant locks the index-name safety: lowercase, illegal chars to
// '-', trimmed, and a stable "unknown" fallback so a DENY without a tenant
// (no-token path) still lands in an auditable index instead of failing.
func TestSanitizeTenant(t *testing.T) {
	cases := map[string]string{
		"banking-demo":  "banking-demo",
		"payments-team": "payments-team",
		"Banking_Demo":  "banking-demo",
		"ACCOUNTS":      "accounts",
		"a/b":           "a-b",
		"--x--":         "x",
		"  ":            "unknown",
		"":              "unknown",
		"-":             "unknown",
		"tenant.with.dots": "tenant-with-dots",
	}
	for in, want := range cases {
		if got := sanitizeTenant(in); got != want {
			t.Errorf("sanitizeTenant(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestTraceAndSpanID checks the W3C ids are valid hex of the right width, never
// all-zero, and fresh on each call — they are the audit↔OTel correlation key.
func TestTraceAndSpanID(t *testing.T) {
	tid := NewTraceID()
	if len(tid) != 32 {
		t.Errorf("trace id len = %d, want 32: %q", len(tid), tid)
	}
	if b, err := hex.DecodeString(tid); err != nil || len(b) != 16 {
		t.Errorf("trace id not 16-byte hex: %q (%v)", tid, err)
	}
	if tid == strings.Repeat("0", 32) {
		t.Errorf("trace id must not be all-zero")
	}
	if NewTraceID() == tid {
		t.Errorf("trace ids must be fresh per call")
	}

	sid := NewSpanID()
	if len(sid) != 16 {
		t.Errorf("span id len = %d, want 16: %q", len(sid), sid)
	}
	if _, err := hex.DecodeString(sid); err != nil {
		t.Errorf("span id not hex: %q", sid)
	}
}

// TestNewRecorderDefaults pins the default index family and URL trimming.
func TestNewRecorderDefaults(t *testing.T) {
	r := NewRecorder("https://localhost:9201/", "admin", "x", true, nil)
	if r.IndexPrefix != "audit-onboarding" {
		t.Errorf("default IndexPrefix = %q, want audit-onboarding", r.IndexPrefix)
	}
	if r.OpenSearchURL != "https://localhost:9201" {
		t.Errorf("OpenSearchURL trailing slash not trimmed: %q", r.OpenSearchURL)
	}
}

// TestRecordStdoutOnly: with no OpenSearch URL the Recorder is still fully
// auditable — it emits the structured line AND defaults the timestamp.
func TestRecordStdoutOnly(t *testing.T) {
	lg, buf := bufLogger()
	r := NewRecorder("", "", "", false, lg)
	r.Record(context.Background(), Event{
		Actor: "onboarder-banking", Action: ActionOnboard, Tenant: "banking-demo",
		Decision: Accept, Reason: "ok", TraceID: "trace-xyz", HTTPStatus: 201,
	})
	out := buf.String()
	if !strings.Contains(out, `"event":"audit.onboarding"`) {
		t.Errorf("missing OTel-bridge discriminator: %s", out)
	}
	if !strings.Contains(out, `"trace_id":"trace-xyz"`) {
		t.Errorf("missing trace_id pivot: %s", out)
	}
	// The emitted line must carry a defaulted timestamp parseable as RFC3339Nano.
	var ll logLine
	if err := json.Unmarshal([]byte(strings.TrimSpace(out)), &ll); err != nil {
		t.Fatalf("stdout line is not valid JSON: %v (%s)", err, out)
	}
	if ll.Audit.Timestamp == "" {
		t.Errorf("Record must default an empty timestamp")
	}
	if _, err := time.Parse(time.RFC3339Nano, ll.Audit.Timestamp); err != nil {
		t.Errorf("defaulted timestamp not RFC3339Nano: %q", ll.Audit.Timestamp)
	}
}

// capture is a tiny race-safe holder for what the fake OpenSearch saw.
type capture struct {
	mu     sync.Mutex
	method string
	path   string
	query  string
	user   string
	pass   string
	ctype  string
	body   Event
}

// TestRecordIndexesToOpenSearch proves the per-tenant routing: POST to
// /{prefix}-{tenant}/_doc?refresh=true, basic-authed, with the Event as body.
func TestRecordIndexesToOpenSearch(t *testing.T) {
	var cap capture
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		cap.mu.Lock()
		defer cap.mu.Unlock()
		cap.method = req.Method
		cap.path = req.URL.Path
		cap.query = req.URL.RawQuery
		cap.user, cap.pass, _ = req.BasicAuth()
		cap.ctype = req.Header.Get("Content-Type")
		raw, _ := io.ReadAll(req.Body)
		_ = json.Unmarshal(raw, &cap.body)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"result":"created"}`))
	}))
	defer srv.Close()

	lg, buf := bufLogger()
	r := NewRecorder(srv.URL, "admin", "s3cret", true, lg)
	r.Record(context.Background(), Event{
		Actor: "onboarder-payments", Action: ActionOnboard, Tenant: "Payments-Team",
		Partner: "acme-payments", Decision: Accept, Reason: "ok",
		TraceID: "trace-1", HTTPStatus: 201,
	})

	cap.mu.Lock()
	defer cap.mu.Unlock()
	if cap.method != http.MethodPost {
		t.Errorf("method = %q, want POST", cap.method)
	}
	if cap.path != "/audit-onboarding-payments-team/_doc" {
		t.Errorf("path = %q, want /audit-onboarding-payments-team/_doc (tenant sanitized)", cap.path)
	}
	if cap.query != "refresh=true" {
		t.Errorf("query = %q, want refresh=true", cap.query)
	}
	if cap.user != "admin" || cap.pass != "s3cret" {
		t.Errorf("basic auth = %q/%q, want admin/s3cret", cap.user, cap.pass)
	}
	if !strings.HasPrefix(cap.ctype, "application/json") {
		t.Errorf("content-type = %q, want application/json", cap.ctype)
	}
	if cap.body.Actor != "onboarder-payments" || cap.body.TraceID != "trace-1" {
		t.Errorf("indexed body lost fields: %+v", cap.body)
	}
	// The stdout line is emitted on the success path too (never lost).
	if !strings.Contains(buf.String(), `"event":"audit.onboarding"`) {
		t.Errorf("stdout line must be emitted even on OpenSearch success")
	}
}

// TestRecordCustomIndexPrefix pre-validates the apply-plane reuse (It.3): the
// same Recorder routes to audit-apply-{tenant} when the prefix is overridden.
func TestRecordCustomIndexPrefix(t *testing.T) {
	var cap capture
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		cap.mu.Lock()
		cap.path = req.URL.Path
		cap.mu.Unlock()
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	lg, _ := bufLogger()
	r := NewRecorder(srv.URL, "admin", "x", true, lg)
	r.IndexPrefix = "audit-apply"
	r.Record(context.Background(), Event{Tenant: "banking-demo", Decision: Accept, TraceID: "t"})

	cap.mu.Lock()
	defer cap.mu.Unlock()
	if cap.path != "/audit-apply-banking-demo/_doc" {
		t.Errorf("path = %q, want /audit-apply-banking-demo/_doc", cap.path)
	}
}

// TestRecordSinkErrorStillEmits: an OpenSearch 5xx must NOT swallow the decision
// — the stdout line is still written and the sink error is logged, never fatal.
func TestRecordSinkErrorStillEmits(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"boom"}`))
	}))
	defer srv.Close()

	lg, buf := bufLogger()
	r := NewRecorder(srv.URL, "admin", "x", true, lg)
	r.Record(context.Background(), Event{
		Tenant: "banking-demo", Decision: Deny, Reason: "tenant_mismatch",
		TraceID: "trace-deny", HTTPStatus: 403,
	})
	out := buf.String()
	if !strings.Contains(out, `"event":"audit.onboarding"`) {
		t.Errorf("decision line must be emitted even when OpenSearch fails: %s", out)
	}
	if !strings.Contains(out, "audit.sink_error") {
		t.Errorf("sink error must be logged: %s", out)
	}
	if !strings.Contains(out, "trace-deny") {
		t.Errorf("sink error must carry the trace id for correlation: %s", out)
	}
}

// TestExportOTLP proves the trace_id becomes a real OTLP span: POST /v1/traces,
// the span traceId equals the audit trace_id (hex, byte-for-byte), and the span
// status reflects the decision (ACCEPT→OK, DENY→ERROR).
func TestExportOTLP(t *testing.T) {
	var mu sync.Mutex
	var lastPath, lastCType string
	var last otlpPayload
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		lastPath = req.URL.Path
		lastCType = req.Header.Get("Content-Type")
		raw, _ := io.ReadAll(req.Body)
		_ = json.Unmarshal(raw, &last)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	lg, _ := bufLogger()
	r := NewRecorder("", "", "", true, lg) // no OpenSearch sink
	r.OTLPEndpoint = srv.URL
	r.IndexPrefix = "audit-apply"

	const tid = "0123456789abcdef0123456789abcdef"
	r.Record(context.Background(), Event{
		Actor: "Alice Banking", Action: ActionPublish, Tenant: "banking-demo",
		Resource: "accounts-read", Gateway: "apisix", Decision: Accept, Reason: "ok", TraceID: tid,
	})

	mu.Lock()
	if lastPath != "/v1/traces" {
		t.Errorf("OTLP path = %q, want /v1/traces", lastPath)
	}
	if !strings.HasPrefix(lastCType, "application/json") {
		t.Errorf("OTLP content-type = %q", lastCType)
	}
	if len(last.ResourceSpans) == 0 || len(last.ResourceSpans[0].ScopeSpans) == 0 || len(last.ResourceSpans[0].ScopeSpans[0].Spans) == 0 {
		mu.Unlock()
		t.Fatalf("no span in OTLP payload: %+v", last)
	}
	span := last.ResourceSpans[0].ScopeSpans[0].Spans[0]
	mu.Unlock()
	if span.TraceID != tid {
		t.Errorf("span traceId = %q, want the audit trace_id %q (hex, byte-for-byte)", span.TraceID, tid)
	}
	if len(span.SpanID) != 16 {
		t.Errorf("span spanId hex len = %d, want 16", len(span.SpanID))
	}
	if span.Name != ActionPublish {
		t.Errorf("span name = %q, want %q", span.Name, ActionPublish)
	}
	if span.Status.Code != 1 {
		t.Errorf("ACCEPT span status = %d, want 1 (OK)", span.Status.Code)
	}

	// a DENY decision maps to span status ERROR (2)
	r.Record(context.Background(), Event{
		Action: ActionApply, Tenant: "banking-demo", Decision: Deny, Reason: "cross_tenant", TraceID: "deadbeef",
	})
	mu.Lock()
	defer mu.Unlock()
	denySpan := last.ResourceSpans[0].ScopeSpans[0].Spans[0]
	if denySpan.Status.Code != 2 {
		t.Errorf("DENY span status = %d, want 2 (ERROR)", denySpan.Status.Code)
	}
}

// recorderSink is a compile-time check that *Recorder satisfies Sink.
var _ Sink = (*Recorder)(nil)
