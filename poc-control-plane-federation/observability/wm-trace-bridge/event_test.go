package main

import (
	"context"
	"os"
	"strings"
	"testing"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
)

// loadFixture lit un event capturé in-situ (apigateway-trial:10.15, 2026-06-12).
func loadFixture(t *testing.T, name string) []Event {
	t.Helper()
	raw, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	evs, _, err := parseEvents(raw)
	if err != nil {
		t.Fatalf("parse fixture %s: %v", name, err)
	}
	return evs
}

func recordSpans(t *testing.T, evs []Event) []sdktrace.ReadOnlySpan {
	t.Helper()
	rec := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(rec))
	defer func() { _ = tp.Shutdown(context.Background()) }()
	tracer := tp.Tracer("test")
	for _, ev := range evs {
		emit(tracer, ev)
	}
	return rec.Ended()
}

func TestTransactionalEventProducesCorrelatedSpans(t *testing.T) {
	evs := loadFixture(t, "transactional.json")
	if len(evs) != 1 {
		t.Fatalf("want 1 event, got %d", len(evs))
	}
	ev := evs[0]
	if ev.EventType != "Transactional" || ev.APIName != "accounts-read" {
		t.Fatalf("unexpected fixture parse: %+v", ev)
	}

	spans := recordSpans(t, evs)
	if len(spans) != 2 {
		t.Fatalf("want 2 spans (server + native client), got %d", len(spans))
	}

	// tracetest restitue les spans dans l'ordre de fin : natif d'abord.
	native, server := spans[0], spans[1]
	if server.SpanKind() != trace.SpanKindServer {
		t.Errorf("server span kind = %v", server.SpanKind())
	}
	if native.SpanKind() != trace.SpanKindClient {
		t.Errorf("native span kind = %v", native.SpanKind())
	}

	// Corrélation : le trace_id vient du traceparent client stocké dans
	// requestHeaders (00-deadbeef...-cafebabe...-01).
	wantTrace := "deadbeefdeadbeefdeadbeefdeadbeef"
	if got := server.SpanContext().TraceID().String(); got != wantTrace {
		t.Errorf("trace id = %s, want %s (client traceparent)", got, wantTrace)
	}
	if got := server.Parent().SpanID().String(); got != "cafebabecafebabe" {
		t.Errorf("parent span id = %s, want client span id", got)
	}
	if native.Parent().SpanID() != server.SpanContext().SpanID() {
		t.Error("native span must be a child of the gateway server span")
	}

	// Timestamps : durée totale = totalTime ; le span natif utilise la fenêtre
	// EXACTE d'externalCalls (callStartTime/callEndTime), pas l'approximation.
	if d := server.EndTime().Sub(server.StartTime()).Milliseconds(); d != int64(ev.TotalTime) {
		t.Errorf("server span duration = %dms, want %vms", d, ev.TotalTime)
	}
	if server.StartTime().UnixMilli() != int64(ev.CreationDate) {
		t.Errorf("server start = %d, want creationDate %v", server.StartTime().UnixMilli(), ev.CreationDate)
	}
	nc := ev.ExternalCalls[0]
	if nc.ExternalCallType != "NATIVE_SERVICE_CALL" {
		t.Fatalf("fixture must carry a NATIVE_SERVICE_CALL, got %+v", ev.ExternalCalls)
	}
	if got := native.StartTime().UnixMilli(); got != int64(nc.CallStartTime) {
		t.Errorf("native start = %d, want exact callStartTime %v", got, nc.CallStartTime)
	}
	if got := native.EndTime().UnixMilli(); got != int64(nc.CallEndTime) {
		t.Errorf("native end = %d, want exact callEndTime %v", got, nc.CallEndTime)
	}

	if server.Status().Code != codes.Ok {
		t.Errorf("status = %v, want Ok", server.Status().Code)
	}

	assertNoHeaderLeak(t, ev, spans)
}

// assertNoHeaderLeak fait respecter le capture model (mémoire projet : jamais
// de payload, jamais de header sensible) sur TOUS les spans : aucune clé
// d'attribut en forme de header, aucune VALEUR égale à un header de la fixture.
func assertNoHeaderLeak(t *testing.T, ev Event, spans []sdktrace.ReadOnlySpan) {
	t.Helper()
	headerVals := map[string]bool{}
	for _, v := range ev.RequestHeaders {
		if s, ok := v.(string); ok && s != "" {
			headerVals[s] = true
		}
	}
	forbiddenPrefixes := []string{"http.request.header.", "http.response.header.", "wm.header."}
	for _, sp := range spans {
		for _, kv := range sp.Attributes() {
			k := strings.ToLower(string(kv.Key))
			for _, p := range forbiddenPrefixes {
				if strings.HasPrefix(k, p) {
					t.Errorf("span %q: forbidden header attribute key %q", sp.Name(), kv.Key)
				}
			}
			if k == "authorization" || k == "cookie" || k == "set-cookie" {
				t.Errorf("span %q: forbidden attribute key %q", sp.Name(), kv.Key)
			}
			if kv.Value.Type() == attribute.STRING && headerVals[kv.Value.AsString()] {
				t.Errorf("span %q: attribute %s carries a request-header value (%q)", sp.Name(), kv.Key, kv.Value.AsString())
			}
		}
	}
}

func TestPolicyViolationEventProducesErrorSpan(t *testing.T) {
	evs := loadFixture(t, "policyviolation.json")
	if len(evs) != 1 {
		t.Fatalf("want 1 event, got %d", len(evs))
	}
	if evs[0].EventType != "PolicyViolation" {
		t.Fatalf("unexpected fixture: %+v", evs[0])
	}

	spans := recordSpans(t, evs)
	if len(spans) != 1 {
		t.Fatalf("want 1 span (no native call on rejection), got %d", len(spans))
	}
	if spans[0].Status().Code != codes.Error {
		t.Errorf("status = %v, want Error", spans[0].Status().Code)
	}
	// Pas de traceparent stocké sur un rejet → nouvelle trace racine.
	if spans[0].Parent().IsValid() {
		t.Error("policy violation span must be a root span")
	}
	assertNoHeaderLeak(t, evs[0], spans)
}

func TestNativeWindowFallsBackToProviderTime(t *testing.T) {
	// Sans externalCalls (version/fixpack qui ne l'émettrait pas) : repli
	// providerTime en fin de fenêtre gateway.
	ev := Event{
		EventType: "Transactional", APIName: "a", NativeURL: "http://b",
		CreationDate: 1_700_000_000_000, TotalTime: 100, ProviderTime: 40,
	}
	spans := recordSpans(t, []Event{ev})
	if len(spans) != 2 {
		t.Fatalf("want 2 spans, got %d", len(spans))
	}
	native := spans[0]
	if got := native.StartTime().UnixMilli(); got != 1_700_000_000_060 {
		t.Errorf("fallback native start = %d, want creationDate+totalTime-providerTime", got)
	}
	if d := native.EndTime().Sub(native.StartTime()).Milliseconds(); d != 40 {
		t.Errorf("fallback native duration = %dms, want providerTime", d)
	}
}

func TestParseEventsShapes(t *testing.T) {
	single := `{"eventType":"Transactional","apiName":"a"}`
	array := `[{"eventType":"Transactional","apiName":"a"},{"eventType":"Error","apiName":"b"}]`
	envelope := `{"events":[{"eventType":"Transactional","apiName":"a"}]}`
	floats := `{"eventType":"Transactional","apiName":"a","totalTime":1835.0,"creationDate":1.781257971299e12}`

	if evs, raws, err := parseEvents([]byte(single)); err != nil || len(evs) != 1 || string(raws[0]) != single {
		t.Errorf("single: %v / %d", err, len(evs))
	}
	if evs, raws, err := parseEvents([]byte(array)); err != nil || len(evs) != 2 || len(raws) != 2 {
		t.Errorf("array: %v / %d", err, len(evs))
	}
	if evs, raws, err := parseEvents([]byte(envelope)); err != nil || len(evs) != 1 || evs[0].APIName != "a" || len(raws) != 1 {
		t.Errorf("envelope: %v / %d", err, len(evs))
	}
	// Un fixpack qui sérialiserait des flottants ne doit pas perdre l'event.
	if evs, _, err := parseEvents([]byte(floats)); err != nil || len(evs) != 1 || evs[0].TotalTime != 1835 {
		t.Errorf("floats: %v / %+v", err, evs)
	}
	if _, _, err := parseEvents([]byte("")); err == nil {
		t.Error("empty body must error")
	}
	// Objet non reconnu (ping de test, {}) : erreur, pas de span poubelle.
	if _, _, err := parseEvents([]byte("{}")); err == nil {
		t.Error("unknown object must error")
	}
	if _, _, err := parseEvents([]byte(`{"events":[]}`)); err == nil {
		t.Error("empty envelope must error")
	}
}

func TestRemoteParentFallsBackToB3(t *testing.T) {
	h := map[string]any{
		"X-B3-TraceId": "463ac35c9f6413ad48485a3953bb6124",
		"X-B3-SpanId":  "0020000000000001",
	}
	sc, ok := remoteParent(h)
	if !ok {
		t.Fatal("B3 headers must yield a parent context")
	}
	if sc.TraceID().String() != "463ac35c9f6413ad48485a3953bb6124" {
		t.Errorf("trace id = %s", sc.TraceID())
	}
	// 64-bit B3 trace id → padding gauche.
	h64 := map[string]any{"x-b3-traceid": "48485a3953bb6124", "x-b3-spanid": "0020000000000001"}
	if sc, ok := remoteParent(h64); !ok || sc.TraceID().String() != "000000000000000048485a3953bb6124" {
		t.Errorf("64-bit b3: ok=%v id=%s", ok, sc.TraceID())
	}
}

func TestFailureDetection(t *testing.T) {
	cases := []struct {
		ev   Event
		want bool
	}{
		{Event{EventType: "Transactional", Status: "SUCCESS", ResponseCode: "200"}, false},
		{Event{EventType: "Transactional", Status: "FAILURE", ResponseCode: "500"}, true},
		{Event{EventType: "Transactional", Status: "SUCCESS", ResponseCode: "404"}, true},
		{Event{EventType: "PolicyViolation", ResponseCode: "401"}, true},
		{Event{EventType: "Error"}, true},
	}
	for i, c := range cases {
		if got := c.ev.isFailure(); got != c.want {
			t.Errorf("case %d: isFailure=%v want %v", i, got, c.want)
		}
	}
}
