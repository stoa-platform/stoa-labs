package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"regexp"
)

// validTP matches a well-formed W3C traceparent (version 00).
var validTP = regexp.MustCompile(`^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$`)

const zeros32 = "00000000000000000000000000000000"

// ensureTraceparent guarantees every published event carries a W3C traceparent,
// so BOTH branches of the Y share ONE trace_id: the analytics record (Data
// Prepper copies /request_headers/traceparent -> trace_id, pipelines.yaml a.5)
// AND the OTel span (event.go remoteParent reads the same header). webMethods
// only stamps a trace context when the CLIENT propagated one — unlike APISIX,
// whose opentelemetry plugin roots a trace on every request. This makes the
// bridge the trace root when no upstream context exists, so 100% of webMethods
// transactions correlate txn<->trace (APISIX parity), not just the propagated
// ones. A real upstream traceparent is preserved (the distributed trace
// continues); only a missing/zero/malformed one is replaced.
func ensureTraceparent(raw []byte) []byte {
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return raw // best-effort: only single JSON objects are enriched
	}
	rh, ok := m["requestHeaders"].(map[string]any)
	if !ok || rh == nil {
		rh = map[string]any{}
	}
	if tp := headerValue(rh, "traceparent"); validTP.MatchString(tp) && tp[3:35] != zeros32 {
		return raw // genuine upstream context — keep it
	}
	rh["traceparent"] = "00-" + randHex(16) + "-" + randHex(8) + "-01"
	m["requestHeaders"] = rh
	out, err := json.Marshal(m)
	if err != nil {
		return raw
	}
	return out
}

// randHex returns n random bytes as lowercase hex (a W3C trace_id is 16 bytes,
// a span_id 8).
func randHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
