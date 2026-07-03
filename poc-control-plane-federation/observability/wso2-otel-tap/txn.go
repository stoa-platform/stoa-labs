package main

import (
	"encoding/hex"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	commonpb "go.opentelemetry.io/proto/otlp/common/v1"
	tracepb "go.opentelemetry.io/proto/otlp/trace/v1"
)

// WSO2 API-Gateway 4.5 span attribute keys (vérifiés live, trace A2) : le span
// de requête API porte tout le schéma stoa.txn sauf le corps (les spans n'en
// transportent pas — succès = métadonnées seules par construction, ADR-070).
const (
	attrAPIName    = "span.api.name"
	attrAPIVersion = "span.api.version"
	attrReqPath    = "span.request.path"
	attrReqMethod  = "span.request.method"
	attrStatusCode = "span.http.response.status.code"
	attrConsumer   = "span.consumerkey"
	attrActivityID = "span.activity.id"
)

// txnRecord est le schéma stoa.txn PLAT que le tap émet vers Kafka — mêmes clés
// pré-normalisées que le kafka-logger APISIX, pour que la pipeline Data Prepper
// stoa-txn-wso2 soit le miroir de stoa-txn-apisix. Le collecteur (Data Prepper)
// reste la SEULE autorité de redaction ; le tap ne ship jamais de corps (les
// spans n'en portent pas) et n'applique aucune redaction lui-même.
type txnRecord struct {
	Gateway    string  `json:"gateway"`
	Provider   string  `json:"provider"`
	Tenant     string  `json:"tenant"`
	API        string  `json:"api"`
	APIVersion string  `json:"api_version"`
	HTTPMethod string  `json:"http_method,omitempty"`
	HTTPPath   string  `json:"http_path,omitempty"`
	HTTPStatus int64   `json:"http_status"`
	LatencyMs  float64 `json:"latency_ms"`
	TraceID    string  `json:"trace_id"`
	RequestID  string  `json:"request_id,omitempty"`
	ConsumerID string  `json:"consumer_id,omitempty"`
	// Timestamp is the transaction time = the span's end (RFC3339), NOT
	// ingestion time — mirrors the APISIX kafka-logger @timestamp ($time_iso8601)
	// so the data-stream ordering matches across the three slices.
	Timestamp string `json:"@timestamp,omitempty"`
}

// tenantResolver maps an API name to its owning tenant. WSO2 OTel spans carry
// no tenant (unlike the APISIX kafka-logger, which labctl projects with the
// manifest's observability.tenant), so the tap resolves it from a config map,
// falling back to a default — the honest PoC equivalent of the "filet PoC"
// hardcoded tenant in the webMethods pipeline.
type tenantResolver struct {
	byAPI   map[string]string
	fallbck string
}

// parseTenantMap builds the resolver from "api=tenant,api2=tenant2" + a default.
func parseTenantMap(spec, fallback string) tenantResolver {
	m := map[string]string{}
	for _, pair := range strings.Split(spec, ",") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		if k, v, ok := strings.Cut(pair, "="); ok {
			m[strings.TrimSpace(k)] = strings.TrimSpace(v)
		}
	}
	return tenantResolver{byAPI: m, fallbck: fallback}
}

func (r tenantResolver) resolve(api string) string {
	if t, ok := r.byAPI[api]; ok && t != "" {
		return t
	}
	return r.fallbck
}

// recordsFromTrace extracts AT MOST ONE stoa.txn record per trace from a batch
// of spans. Selection is the ROOT span (empty parent_span_id) carrying the API
// attributes: on WSO2 4.5, ONLY the per-request root span
// (`<api>--<ver>--<tenant>`) carries span.api.name + span.http.response.status.code
// (verified live); the child latency spans (GET--/x, API:*_Latency) do not.
// Keying on the root (not "longest span with attrs") makes the one-per-trace
// guarantee STRUCTURAL and batch-independent: the root ends last, so if
// WSO2's BatchSpanProcessor fragments a trace across several Export calls, the
// children (attr-less) produce nothing and only the root yields a record — no
// double-count, and latency is the overall request time, never a child's.
// Fail-closed by design: if a future WSO2 version moved the attrs off the root,
// the tap emits NOTHING for that trace (a visible gap in txn-{tenant}) rather
// than a wrong/duplicated record.
func recordsFromTrace(spans []*tracepb.Span, tenants tenantResolver) []txnRecord {
	type cand struct {
		rec txnRecord
		dur uint64
	}
	best := map[string]cand{}
	for _, s := range spans {
		if len(s.GetParentSpanId()) != 0 {
			continue // not a root span
		}
		attrs := attrMap(s.GetAttributes())
		api, hasAPI := attrs[attrAPIName]
		statusRaw, hasStatus := attrs[attrStatusCode]
		if !hasAPI || !hasStatus || api == "" {
			continue // root but not API-request-bearing
		}
		traceID := hex.EncodeToString(s.GetTraceId())
		if len(traceID) != 32 { // W3C trace id = 16 bytes; anything else can't pivot to Tempo
			continue
		}
		dur := s.GetEndTimeUnixNano() - s.GetStartTimeUnixNano()
		if c, ok := best[traceID]; ok && c.dur >= dur {
			continue // defensive: keep the longest if a trace somehow has >1 root
		}
		status, _ := strconv.ParseInt(strings.TrimSpace(statusRaw), 10, 64)
		best[traceID] = cand{
			dur: dur,
			rec: txnRecord{
				Gateway:    "wso2",
				Provider:   "wso2",
				Tenant:     tenants.resolve(api),
				API:        api,
				APIVersion: attrs[attrAPIVersion],
				HTTPMethod: attrs[attrReqMethod],
				HTTPPath:   attrs[attrReqPath],
				HTTPStatus: status,
				LatencyMs:  float64(dur) / 1e6,
				TraceID:    traceID,
				RequestID:  attrs[attrActivityID],
				ConsumerID: attrs[attrConsumer],
				Timestamp:  isoFromUnixNano(s.GetEndTimeUnixNano()),
			},
		}
	}
	out := make([]txnRecord, 0, len(best))
	for _, c := range best {
		out = append(out, c.rec)
	}
	return out
}

// attrMap flattens OTLP key-value attributes to a string map (string/int/bool
// scalar values rendered canonically; other AnyValue shapes ignored).
func attrMap(kvs []*commonpb.KeyValue) map[string]string {
	m := make(map[string]string, len(kvs))
	for _, kv := range kvs {
		if kv == nil || kv.Value == nil {
			continue
		}
		switch v := kv.Value.Value.(type) {
		case *commonpb.AnyValue_StringValue:
			m[kv.Key] = v.StringValue
		case *commonpb.AnyValue_IntValue:
			m[kv.Key] = strconv.FormatInt(v.IntValue, 10)
		case *commonpb.AnyValue_BoolValue:
			m[kv.Key] = strconv.FormatBool(v.BoolValue)
		case *commonpb.AnyValue_DoubleValue:
			m[kv.Key] = strconv.FormatFloat(v.DoubleValue, 'f', -1, 64)
		}
	}
	return m
}

// isoFromUnixNano renders an epoch-nanos span time as RFC3339 UTC ("" for 0).
func isoFromUnixNano(ns uint64) string {
	if ns == 0 {
		return ""
	}
	return time.Unix(0, int64(ns)).UTC().Format(time.RFC3339Nano)
}

func (r txnRecord) marshal() []byte {
	b, _ := json.Marshal(r)
	return b
}
