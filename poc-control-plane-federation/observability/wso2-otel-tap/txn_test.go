package main

import (
	"encoding/hex"
	"encoding/json"
	"testing"

	commonpb "go.opentelemetry.io/proto/otlp/common/v1"
	tracepb "go.opentelemetry.io/proto/otlp/trace/v1"
)

func strAttr(k, v string) *commonpb.KeyValue {
	return &commonpb.KeyValue{Key: k, Value: &commonpb.AnyValue{Value: &commonpb.AnyValue_StringValue{StringValue: v}}}
}

// apiSpan builds a WSO2-shaped API-request ROOT span (empty parent_span_id +
// the API attributes, exactly as WSO2 4.5 emits the per-request root).
func apiSpan(traceHex, name string, start, end uint64, status string) *tracepb.Span {
	tid, _ := hex.DecodeString(traceHex)
	return &tracepb.Span{
		TraceId:           tid,
		Name:              name,
		StartTimeUnixNano: start,
		EndTimeUnixNano:   end,
		Attributes: []*commonpb.KeyValue{
			strAttr(attrAPIName, "accounts-read"),
			strAttr(attrAPIVersion, "1.0.0"),
			strAttr(attrReqPath, "accounts-read/v1/1.0.0/accounts"),
			strAttr(attrReqMethod, "GET"),
			strAttr(attrStatusCode, status),
			strAttr(attrConsumer, "accounts-read-consumer"),
			strAttr(attrActivityID, "act-123"),
		},
	}
}

// childSpan is a non-root span carrying a parent id (a WSO2 latency/resource
// span). It must NEVER become a transaction even if it carries API attrs.
func childSpan(traceHex string) *tracepb.Span {
	s := apiSpan(traceHex, "GET--/accounts", 0, 1000, "200")
	s.ParentSpanId = []byte{1, 2, 3, 4, 5, 6, 7, 8}
	return s
}

func TestRecordsFromTrace_OnePerTrace_KeepsLongest(t *testing.T) {
	tr := "0af7651916cd43dd8448eb211c80319c"
	spans := []*tracepb.Span{
		apiSpan(tr, "GET--/accounts", 1000, 1500, "200"),                                 // short child
		apiSpan(tr, "accounts-read--1.0.0--carbon.super", 1000, 117_000_000+1000, "200"), // longest = overall request
	}
	recs := recordsFromTrace(spans, parseTenantMap("accounts-read=accounts-team", "default"))
	if len(recs) != 1 {
		t.Fatalf("want exactly 1 record per trace, got %d", len(recs))
	}
	r := recs[0]
	if r.TraceID != tr {
		t.Errorf("trace_id = %q, want %q", r.TraceID, tr)
	}
	if r.LatencyMs < 100 { // the longest span is ~117ms; the short one is 0.5ms
		t.Errorf("latency_ms = %v, want the longest span (~117)", r.LatencyMs)
	}
	if r.Gateway != "wso2" || r.Provider != "wso2" {
		t.Errorf("gateway/provider = %q/%q, want wso2/wso2", r.Gateway, r.Provider)
	}
	if r.Tenant != "accounts-team" {
		t.Errorf("tenant = %q, want accounts-team (from map)", r.Tenant)
	}
	if r.HTTPStatus != 200 || r.API != "accounts-read" || r.HTTPMethod != "GET" {
		t.Errorf("record fields off: %+v", r)
	}
	if r.ConsumerID != "accounts-read-consumer" || r.RequestID != "act-123" {
		t.Errorf("consumer/request id off: %+v", r)
	}
}

func TestRecordsFromTrace_DerivesStatusAndTenantFallback(t *testing.T) {
	tr := "11111111111111111111111111111111"
	recs := recordsFromTrace([]*tracepb.Span{apiSpan(tr, "GET--/x", 0, 5_000_000, "404")}, parseTenantMap("", "fallback-tenant"))
	if len(recs) != 1 {
		t.Fatalf("want 1, got %d", len(recs))
	}
	if recs[0].HTTPStatus != 404 {
		t.Errorf("http_status = %d, want 404", recs[0].HTTPStatus)
	}
	if recs[0].Tenant != "fallback-tenant" {
		t.Errorf("tenant = %q, want fallback-tenant", recs[0].Tenant)
	}
}

// Spans without the API attributes (internal WSO2 latency spans) must NOT
// become transactions.
func TestRecordsFromTrace_IgnoresNonAPISpans(t *testing.T) {
	tid, _ := hex.DecodeString("22222222222222222222222222222222")
	internal := &tracepb.Span{
		TraceId: tid, Name: "API:Throttle_Latency", StartTimeUnixNano: 0, EndTimeUnixNano: 1000,
		Attributes: []*commonpb.KeyValue{strAttr("span.something", "x")},
	}
	if recs := recordsFromTrace([]*tracepb.Span{internal}, parseTenantMap("", "t")); len(recs) != 0 {
		t.Fatalf("internal span produced %d records, want 0", len(recs))
	}
}

// ROOT-ONLY selection kills S-2 (cross-batch double-count): a CHILD span
// carrying the same API attrs must be ignored — only the root becomes a txn.
// This means a fragmented trace (children in one Export, root in another) never
// double-counts, because children produce nothing.
func TestRecordsFromTrace_ChildWithAttrsIgnored(t *testing.T) {
	tr := "33333333333333333333333333333333"
	// A batch with ONLY a child (attr-carrying, but parented) → zero records.
	if recs := recordsFromTrace([]*tracepb.Span{childSpan(tr)}, parseTenantMap("", "t")); len(recs) != 0 {
		t.Fatalf("child span with attrs produced %d records, want 0 (root-only)", len(recs))
	}
	// A batch with child + root → exactly ONE record (the root).
	root := apiSpan(tr, "accounts-read--1.0.0--carbon.super", 0, 50_000_000, "200")
	recs := recordsFromTrace([]*tracepb.Span{childSpan(tr), root}, parseTenantMap("", "t"))
	if len(recs) != 1 {
		t.Fatalf("child+root produced %d records, want exactly 1 (root)", len(recs))
	}
	if recs[0].LatencyMs != 50 {
		t.Errorf("latency = %v, want the ROOT's 50ms (not the child's)", recs[0].LatencyMs)
	}
}

// A malformed (non-16-byte) trace id can't pivot to Tempo → skip, never emit a
// record whose trace_id is unusable.
func TestRecordsFromTrace_RejectsBadTraceID(t *testing.T) {
	short := apiSpan("abcd", "root", 0, 1000, "200") // 2 bytes, not 16
	if recs := recordsFromTrace([]*tracepb.Span{short}, parseTenantMap("", "t")); len(recs) != 0 {
		t.Fatalf("short trace id produced %d records, want 0", len(recs))
	}
}

// Two distinct traces in one batch -> two records.
func TestRecordsFromTrace_MultipleTraces(t *testing.T) {
	a := apiSpan("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "GET--/a", 0, 1_000_000, "200")
	b := apiSpan("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "GET--/b", 0, 2_000_000, "500")
	recs := recordsFromTrace([]*tracepb.Span{a, b}, parseTenantMap("", "t"))
	if len(recs) != 2 {
		t.Fatalf("want 2 records for 2 traces, got %d", len(recs))
	}
}

func TestTxnRecord_MarshalSchema(t *testing.T) {
	r := txnRecord{Gateway: "wso2", Provider: "wso2", Tenant: "accounts-team", API: "accounts-read",
		APIVersion: "1.0.0", HTTPMethod: "GET", HTTPPath: "/x", HTTPStatus: 200, LatencyMs: 12.5,
		TraceID: "abc", RequestID: "r1", ConsumerID: "c1"}
	var m map[string]any
	if err := json.Unmarshal(r.marshal(), &m); err != nil {
		t.Fatalf("marshal invalide: %v", err)
	}
	for _, k := range []string{"gateway", "provider", "tenant", "api", "api_version", "http_method", "http_status", "latency_ms", "trace_id"} {
		if _, ok := m[k]; !ok {
			t.Errorf("clé stoa.txn manquante: %q", k)
		}
	}
	if m["http_status"].(float64) != 200 {
		t.Errorf("http_status doit être numérique JSON")
	}
}
