package apisix

// Transactional analytics emission for APISIX (ADR-070, tranche APISIX).
//
// When the manifest carries an observability block, every route projected by
// Publish (and re-PUT by CreateConsumer) embeds a kafka-logger plugin that emits
// the common stoa.txn schema to Redpanda. A collector (Data Prepper) consumes
// the topic, normalises to stoa.txn, REDACTS deterministically (the single
// auditable redaction point — IBAN/MONETARY/PII), and routes to the
// tenant-isolated OpenSearch index txn-{tenant}-*.
//
// The gateway is an EMITTER only (le principe hors-data-plane, off the transaction path): it stamps
// metadata + a tenant tag + the W3C trace_id, and on ERROR (status>=400) the
// request/response headers — never the request body, and the response body
// capture is ARMED here but EXTRACTED/redacted at the collector (see the
// include_resp_body note below). Redaction is NOT the gateway's job.
//
// Two hard APISIX constraints shaped this projection (both proven on the live
// stack 2026-06-11):
//
//  1. kafka-logger must be in the static `plugins:` list of config.yaml or the
//     Admin API rejects the plugin with "unknown plugin [kafka-logger]".
//
//  2. With a CUSTOM log_format, APISIX's gen_log_format calls :byte() on every
//     value — so every log_format value MUST be a FLAT string (a nested object
//     crashes the log phase with "attempt to call method 'byte' (a nil value)").
//     Headers are therefore flat $http_*/$sent_http_* keys, redacted downstream.
//     Also: get_custom_format_log does NOT merge the captured ctx.resp_body into
//     a custom entry (there is no $resp_body var), so include_resp_body is armed
//     but the body itself is the collector's concern — consistent with ADR-070's
//     "redaction at ONE auditable point" (the gateway must not ship raw bodies).
//
// The trace_id is populated from $opentelemetry_trace_id, which is only non-empty
// when plugin_attr.opentelemetry.set_ngx_var=true is set in config.yaml (absent
// by default — enabled for this tranche). This is the audit↔ops correlation key
// (OpenSearch txn ↔ OTel/LGTM traces).

import (
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

// defaultTopicPrefix is the ADR-070 bus convention; the per-gateway topic is
// "{prefix}.{gateway-type}" (e.g. stoa.txn.apisix) — 3 topics per gateway, one
// kafka source on the collector.
const defaultTopicPrefix = "stoa.txn"

// schemaVersion stamps the emitted record so the collector can evolve the
// stoa.txn mapping without ambiguity.
const schemaVersion = "stoa.txn/v1"

// kafkaLoggerConfig is the resolved observability emission knob set, projected
// from the manifest's observability block. Off (no plugin projected) when
// broker is "".
type kafkaLoggerConfig struct {
	broker string // host:port reachable FROM the gateway container
	topic  string // resolved destination topic (already prefix-expanded)
	tenant string // tenant tag stamped on every record (routes txn-{tenant}-*)
}

// enabled reports whether the observability feature is on for this target.
func (k kafkaLoggerConfig) enabled() bool { return k.broker != "" }

// kafkaLoggerFromConfig resolves the observability knobs the targets layer
// folded into Options. Absent block (broker "") -> a zero config (feature off,
// behavior unchanged). The topic defaults to "{prefix}.apisix" so one prefix
// drives the ADR-070 per-gateway topic convention.
func kafkaLoggerFromConfig(cfg adapter.Config) kafkaLoggerConfig {
	broker := cfg.Opt("observabilityKafkaBroker", "")
	if broker == "" {
		return kafkaLoggerConfig{}
	}
	topic := cfg.Opt("observabilityTopic", "")
	if topic == "" {
		prefix := cfg.Opt("observabilityTopicPrefix", defaultTopicPrefix)
		topic = prefix + "." + gatewayName // stoa.txn.apisix
	}
	return kafkaLoggerConfig{
		broker: broker,
		topic:  topic,
		tenant: cfg.Opt("observabilityTenant", ""),
	}
}

// kafkaLoggerPlugin builds the APISIX kafka-logger plugin object for a given API
// identity. The brokers list is a single host:port (split below); the log_format
// projects the stoa.txn schema FLAT (constraint 2 above). api/apiVersion stamp
// the per-API identity so the collector need not infer it.
//
// CAPTURE (the strict rule): success = METADATA only; ERROR (status>=400) = meta
// + request/response headers (flat, redacted at the collector) + the response
// body capture armed via include_resp_body_expr. NEVER the request body.
func (k kafkaLoggerConfig) kafkaLoggerPlugin(api, apiVersion string) map[string]any {
	host, port := splitHostPort(k.broker)
	return map[string]any{
		"brokers": []map[string]any{
			{"host": host, "port": port},
		},
		"kafka_topic":      k.topic,
		"producer_type":    "async",
		"required_acks":    1,
		"meta_format":      "default",
		"include_req_body": false, // NEVER the request body (strict rule)
		// Response body captured ONLY on ERROR (status>=400). With a custom
		// log_format APISIX does not emit ctx.resp_body itself, so the body is
		// the collector's concern — but arming the capture documents intent and
		// keeps the gateway honest (no raw body shipped by default on success).
		"include_resp_body":      true,
		"include_resp_body_expr": []any{[]any{"status", ">=", 400}},
		"log_format":             k.logFormat(api, apiVersion),
		// One log entry per Kafka message. APISIX's kafka-logger batches entries
		// into a JSON ARRAY by default; Data Prepper's kafka source (serde json)
		// deserializes ONE object per record and rejects START_ARRAY
		// ("Cannot deserialize ... from Array value"), silently dropping every
		// real event. batch_max_size=1 makes each record a single JSON object.
		"batch_max_size": 1,
	}
}

// logFormat returns the FLAT stoa.txn projection (constraint 2). Every value is
// a string: a literal tag, or a $-prefixed APISIX/nginx variable resolved at the
// log phase. trace_id/span_id need plugin_attr.opentelemetry.set_ngx_var=true.
func (k kafkaLoggerConfig) logFormat(api, apiVersion string) map[string]any {
	return map[string]any{
		// identity / routing
		"tenant":         k.tenant,
		"provider":       gatewayName,
		"gateway":        gatewayName,
		"api":            api,
		"api_version":    apiVersion,
		"schema_version": schemaVersion,
		// correlation (trace_id via set_ngx_var; request_id anti-sampling filet)
		"trace_id":   "$opentelemetry_trace_id",
		"span_id":    "$opentelemetry_span_id",
		"request_id": "$request_id",
		// result
		"@timestamp":  "$time_iso8601",
		"http_method": "$request_method",
		"http_path":   "$uri",
		"http_status": "$status",
		// NOTE: no "status" string here on purpose — $status is the numeric HTTP
		// code. The collector DERIVES status (success|error) from http_status so
		// the keyword field is never clobbered by a numeric value.
		"latency_ms": "$request_time",
		// PII (redacted/FLS-masked at the collector)
		"user_ip":     "$remote_addr",
		"user_agent":  "$http_user_agent",
		"consumer_id": "$consumer_name",
		// request headers (flat; ERROR-relevant, redacted at the collector)
		"req_header_authorization": "$http_authorization",
		"req_header_cookie":        "$http_cookie",
		"req_header_user_agent":    "$http_user_agent",
		"req_header_x_request_id":  "$http_x_request_id",
		// response headers (flat; redacted at the collector)
		"resp_header_content_type":     "$sent_http_content_type",
		"resp_header_www_authenticate": "$sent_http_www_authenticate",
	}
}

// splitHostPort splits "host:port" into (host, intPort). A missing/invalid port
// defaults to 9092 (Kafka/Redpanda). Kept dependency-free and total: the broker
// is validated for presence at the targets layer, not parsed there.
func splitHostPort(broker string) (string, int) {
	host := broker
	port := 9092
	for i := len(broker) - 1; i >= 0; i-- {
		if broker[i] == ':' {
			host = broker[:i]
			if p := atoiSafe(broker[i+1:]); p > 0 {
				port = p
			}
			break
		}
	}
	return host, port
}

// atoiSafe parses a non-negative decimal port, returning 0 on any non-digit so
// splitHostPort falls back to the Kafka default.
func atoiSafe(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
	}
	return n
}
