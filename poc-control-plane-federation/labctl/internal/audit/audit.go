// Package audit records every onboarding authorization DECISION (ACCEPT/DENY)
// as a structured, tenant-scoped event — the traceability half of the
// enterprise requirement (RBAC + audit). It has two sinks, wired together so a
// decision is never silently lost:
//
//  1. OpenSearch (governance/audit, ADR-070): one document per decision in a
//     per-tenant index `audit-onboarding-{tenant}`, so the SAME role↔index-
//     pattern RBAC pattern that scopes `txn-{tenant}-*` (role
//     tenant-{tenant}-viewer) scopes the audit trail: a tenant sees ONLY its
//     own onboarding decisions. The admin/admin OpenSearch is reached over the
//     PoC's self-signed TLS (InsecureSkipVerify, like every other adapter).
//
//  2. stdout, as one structured JSON line (the OTel bridge). No OTel SDK is
//     vendored (air-gapped: GOPROXY=off, no `go get`), so instead of an OTLP
//     exporter we emit a W3C-trace-context `trace_id` + a structured log; that
//     same `trace_id` is the document's correlation key in OpenSearch, which is
//     exactly the audit↔ops pivot ADR-070 specifies (Tempo/Loki ingest the JSON
//     line; OpenSearch holds the authoritative audit doc). Routing the line to
//     an OTLP collector is the documented next step.
//
// Both sinks are best-effort relative to the request: a DENY is still returned
// to the caller (401/403) even if OpenSearch is briefly unreachable — but the
// stdout line is ALWAYS emitted, so no decision is unobservable. Nothing here
// ever logs a secret: only the decision metadata defined by Event.
package audit

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// Decision is the audited outcome of an onboarding authorization check.
type Decision string

const (
	// Accept: the token was valid, carried the partner-onboarder role and a
	// tenant matching the body; the manifest was committed.
	Accept Decision = "ACCEPT"
	// Deny: the request was refused (401 no/invalid token, or 403 missing role
	// / tenant mismatch). A DENY is ALWAYS audited (the requirement is explicit:
	// the refusal is the security event that matters most).
	Deny Decision = "DENY"
)

// Action is the audited action verb across the control plane's two surfaces:
// the write plane (onboarding) and the converge/apply plane (gateway mutations).
const (
	ActionOnboard   = "partner.onboard"    // write plane: a partner manifest commit
	ActionPublish   = "api.publish"        // apply plane: a gateway API publication
	ActionSubscribe = "consumer.subscribe" // apply plane: a consumer/subscription mutation
	ActionApply     = "api.apply"          // apply plane: a run-level decision (e.g. cross-tenant DENY)
)

// Event is one immutable audit record. Fields mirror the governance/audit
// schema (ADR-070) and carry NO secret material — the public manifest is
// auditable by PR; tokens, client secrets and Git credentials never appear.
type Event struct {
	Timestamp string   `json:"timestamp"`
	Actor     string   `json:"actor"`              // who is responsible: write plane = validated token user; apply plane = the manifest's Git commit author
	Action    string   `json:"action"`             // partner.onboard | api.publish | consumer.subscribe | api.apply
	Tenant    string   `json:"tenant"`             // tenant the decision is recorded under (the per-tenant index suffix)
	Partner   string   `json:"partner,omitempty"`  // write plane: partner/application name ("-" when unparsed)
	Resource  string   `json:"resource,omitempty"` // apply plane: the API slug / consumer being mutated
	Gateway   string   `json:"gateway,omitempty"`  // apply plane: the target gateway name
	Principal string   `json:"principal,omitempty"` // apply plane: the cp-applier CI service account (distinct from the human Actor)
	Decision  Decision `json:"decision"`           // ACCEPT | DENY
	Reason    string   `json:"reason"`             // machine reason (tenant_mismatch, cross_tenant, publish_failed, ok, …)
	CommitSHA string   `json:"commit_sha,omitempty"`
	TraceID   string   `json:"trace_id"` // W3C trace-context id — the OpenSearch↔OTel pivot (ADR-070)
	ClientIP  string   `json:"client_ip,omitempty"`
	HTTPStatus int     `json:"http_status,omitempty"` // write plane: the status returned to the caller
}

// Sink records audit events. Recorder is the production sink; tests use an
// in-memory fake.
type Sink interface {
	Record(ctx context.Context, ev Event)
}

// Recorder writes each Event to OpenSearch (per-tenant index) AND to stdout as
// a structured JSON line. Construct it with NewRecorder.
type Recorder struct {
	// OpenSearchURL is the base, e.g. https://localhost:9201. Empty disables the
	// OpenSearch sink (stdout-only — used when OpenSearch is not provisioned).
	OpenSearchURL string
	User          string
	Password      string

	// IndexPrefix is prepended to the tenant: "{prefix}-{tenant}". Default
	// "audit-onboarding".
	IndexPrefix string

	// OTLPEndpoint, when set (e.g. http://localhost:4318), turns the trace_id
	// correlation key into a REAL span: each event is exported as one OTLP/HTTP
	// (JSON) span to {endpoint}/v1/traces, so the audit doc and the Tempo trace
	// share the same trace_id (ADR-070 pivot, now end-to-end). Empty disables it.
	// Stdlib-only JSON POST — no OTel SDK vendored (air-gapped).
	OTLPEndpoint string

	client *http.Client
	logger *log.Logger
}

// NewRecorder builds the live recorder. insecure skips TLS verification for the
// PoC self-signed OpenSearch cert (same opt-in as every gateway adapter).
func NewRecorder(osURL, user, password string, insecure bool, logger *log.Logger) *Recorder {
	if logger == nil {
		logger = log.Default()
	}
	return &Recorder{
		OpenSearchURL: strings.TrimRight(osURL, "/"),
		User:          user,
		Password:      password,
		IndexPrefix:   "audit-onboarding",
		client:        httpx.NewClient(insecure),
		logger:        logger,
	}
}

// Record emits the event to BOTH sinks. The stdout line is always written
// (audit.event=...), so the decision is observable even if OpenSearch is down;
// an OpenSearch failure is logged, never fatal, and never blocks the response.
func (r *Recorder) Record(ctx context.Context, ev Event) {
	if ev.Timestamp == "" {
		ev.Timestamp = time.Now().UTC().Format(time.RFC3339Nano)
	}
	// 1) stdout structured line (OTel bridge): always — so the decision is
	//    observable even when OpenSearch is down. The discriminator reflects the
	//    plane (audit.onboarding | audit.apply), derived from the index family, so
	//    a collector can route per plane.
	event := "audit." + strings.TrimPrefix(r.IndexPrefix, "audit-")
	if line, err := json.Marshal(logLine{Event: event, Audit: ev}); err == nil {
		r.logger.Printf("%s", line)
	}
	// 2) OTLP/HTTP span (best-effort): makes the trace_id a real, queryable span
	//    in Tempo. Never blocks; a collector hiccup is logged, never fatal.
	if r.OTLPEndpoint != "" {
		if err := r.exportOTLP(ctx, ev); err != nil {
			r.logger.Printf("{\"event\":\"audit.otlp_error\",\"trace_id\":%q,\"error\":%q}", ev.TraceID, err.Error())
		}
	}
	// 3) OpenSearch per-tenant index: best-effort (never blocks the response).
	if r.OpenSearchURL == "" {
		return
	}
	if err := r.index(ctx, ev); err != nil {
		r.logger.Printf("{\"event\":\"audit.sink_error\",\"trace_id\":%q,\"error\":%q}", ev.TraceID, err.Error())
	}
}

// logLine frames an Event for the stdout (OTel-bridge) sink.
type logLine struct {
	Event string `json:"event"`
	Audit Event  `json:"audit"`
}

func (r *Recorder) index(ctx context.Context, ev Event) error {
	tenant := sanitizeTenant(ev.Tenant)
	idx := r.IndexPrefix + "-" + tenant
	url := fmt.Sprintf("%s/%s/_doc?refresh=true", r.OpenSearchURL, idx)
	body, err := json.Marshal(ev)
	if err != nil {
		return fmt.Errorf("marshal audit event: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("build opensearch request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if r.User != "" {
		req.SetBasicAuth(r.User, r.Password)
	}
	resp, err := r.client.Do(req)
	if err != nil {
		return fmt.Errorf("opensearch index %s: %w", idx, err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("opensearch index %s -> %d: %s", idx, resp.StatusCode, truncate(raw, 300))
	}
	return nil
}

// --- OTLP/HTTP (JSON) span export -------------------------------------------
//
// The OTLP/JSON encoding maps protobuf to JSON, with ONE exception we rely on:
// trace_id and span_id are HEX strings (not base64). Our Event.TraceID is
// already a 32-hex W3C trace id, so the exported span shares it byte-for-byte —
// querying Tempo by that id returns this span. No OTel SDK is vendored; this is
// a plain stdlib JSON POST to the in-zone collector (air-gapped, like the
// OpenSearch sink).

type otlpValue struct {
	StringValue string `json:"stringValue"`
}
type otlpAttr struct {
	Key   string    `json:"key"`
	Value otlpValue `json:"value"`
}
type otlpSpan struct {
	TraceID           string     `json:"traceId"`
	SpanID            string     `json:"spanId"`
	Name              string     `json:"name"`
	Kind              int        `json:"kind"`
	StartTimeUnixNano string     `json:"startTimeUnixNano"`
	EndTimeUnixNano   string     `json:"endTimeUnixNano"`
	Attributes        []otlpAttr `json:"attributes"`
	Status            struct {
		Code int `json:"code"`
	} `json:"status"`
}
type otlpScopeSpans struct {
	Scope struct {
		Name string `json:"name"`
	} `json:"scope"`
	Spans []otlpSpan `json:"spans"`
}
type otlpResourceSpans struct {
	Resource struct {
		Attributes []otlpAttr `json:"attributes"`
	} `json:"resource"`
	ScopeSpans []otlpScopeSpans `json:"scopeSpans"`
}
type otlpPayload struct {
	ResourceSpans []otlpResourceSpans `json:"resourceSpans"`
}

func strAttr(k, v string) otlpAttr { return otlpAttr{Key: k, Value: otlpValue{StringValue: v}} }

// exportOTLP posts one span (this decision) to {OTLPEndpoint}/v1/traces.
func (r *Recorder) exportOTLP(ctx context.Context, ev Event) error {
	now := time.Now().UnixNano()
	start := now - int64(time.Millisecond)
	statusCode := 1 // STATUS_CODE_OK
	if ev.Decision == Deny {
		statusCode = 2 // STATUS_CODE_ERROR
	}
	attrs := []otlpAttr{
		strAttr("tenant", ev.Tenant),
		strAttr("actor", ev.Actor),
		strAttr("decision", string(ev.Decision)),
		strAttr("reason", ev.Reason),
	}
	for _, kv := range [][2]string{
		{"resource", ev.Resource}, {"gateway", ev.Gateway},
		{"principal", ev.Principal}, {"partner", ev.Partner}, {"commit_sha", ev.CommitSHA},
	} {
		if kv[1] != "" {
			attrs = append(attrs, strAttr(kv[0], kv[1]))
		}
	}
	span := otlpSpan{
		TraceID:           ev.TraceID,
		SpanID:            NewSpanID(),
		Name:              ev.Action,
		Kind:              1, // SPAN_KIND_INTERNAL
		StartTimeUnixNano: strconv.FormatInt(start, 10),
		EndTimeUnixNano:   strconv.FormatInt(now, 10),
		Attributes:        attrs,
	}
	span.Status.Code = statusCode

	var p otlpPayload
	var rs otlpResourceSpans
	rs.Resource.Attributes = []otlpAttr{
		strAttr("service.name", "stoa-control-plane"),
		strAttr("stoa.plane", strings.TrimPrefix(r.IndexPrefix, "audit-")),
	}
	var ss otlpScopeSpans
	ss.Scope.Name = "stoa.audit"
	ss.Spans = []otlpSpan{span}
	rs.ScopeSpans = []otlpScopeSpans{ss}
	p.ResourceSpans = []otlpResourceSpans{rs}

	body, err := json.Marshal(p)
	if err != nil {
		return fmt.Errorf("marshal otlp: %w", err)
	}
	url := strings.TrimRight(r.OTLPEndpoint, "/") + "/v1/traces"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("build otlp request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := r.client.Do(req)
	if err != nil {
		return fmt.Errorf("otlp post: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("otlp %s -> %d: %s", url, resp.StatusCode, truncate(raw, 200))
	}
	return nil
}

// sanitizeTenant lowercases and strips characters illegal in an OpenSearch
// index name, with a stable fallback so a DENY without a known tenant (e.g. no
// token) still lands somewhere auditable instead of failing the index call.
func sanitizeTenant(t string) string {
	t = strings.ToLower(strings.TrimSpace(t))
	t = strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '-':
			return r
		default:
			return '-'
		}
	}, t)
	t = strings.Trim(t, "-")
	if t == "" {
		return "unknown"
	}
	return t
}

func truncate(b []byte, n int) string {
	if len(b) <= n {
		return string(b)
	}
	return string(b[:n]) + "…"
}

// NewTraceID returns a fresh 16-byte W3C trace-context trace_id (32 lowercase
// hex). It is the correlation key shared by the audit doc and the structured
// log line — the audit↔OTel pivot of ADR-070.
func NewTraceID() string { return randHex(16) }

// NewSpanID returns a fresh 8-byte W3C span_id (16 lowercase hex).
func NewSpanID() string { return randHex(8) }

func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		// crypto/rand failing is catastrophic; fall back to a time seed so we
		// never emit an all-zero (invalid) trace id.
		t := time.Now().UnixNano()
		for i := range b {
			b[i] = byte(t >> (8 * (i % 8)))
		}
	}
	return hex.EncodeToString(b)
}
