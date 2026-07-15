package webmethods

import (
	"fmt"
	"net"
	"strings"
)

// Self-service consumer identity enforcement (ADR-078). The consumer application
// carries identifiers — a client CERTIFICATE (httpsCertificate) and an IP-range
// allowlist (ipAddressRange, identifiers.go) — but writing an identifier does NOT
// oppose it: the gateway only enforces a dimension when a policy IdentificationRule
// requires it (pinned live on apigateway:10.15, 2026-07-14 — an identifier alone
// lets the request through; a strict/ipAddressRange rule rejects an out-of-range
// caller 403). This is the fail-open the PoC left open (ipAllowlist written, never
// opposed). Here we project the IAM action that ENFORCES an AND of those
// dimensions, reusing the OAuth2+cert AND pattern (mtls.go), generalized.

// identificationTypeIP is the IAM identificationType for an application IP-range
// allowlist ("IP address range" in the UI). Same key as the consumer app's
// ipAddressRange identifier the caller's source IP must fall within.
const identificationTypeIP = "ipAddressRange"

// identifyAndActionBody builds the ENVELOPED Identify & Authorize (evaluatePolicy)
// action that requires the caller to be identified by ALL of idTypes at once:
// logicalConnector=AND, allowAnonymous=false, one strict IdentificationRule per
// type. It is the general form behind mtlsIdentifyActionBody (oAuth2Token +
// httpsCertificate) and the self-service cert+IP enforcement (ADR-078).
//
// Every rule uses applicationLookup=strict: each dimension must resolve to the
// SAME consumer application (cert via httpsCertificate, IP via ipAddressRange,
// token via oAuth2Token), so a request missing ANY one is rejected 401/403 at
// IAM. Param order (logicalConnector, allowAnonymous, then the rules) matches the
// live-pinned shape. An empty idTypes yields an action with no rule — callers
// must pass at least one dimension.
func identifyAndActionBody(id, name string, idTypes []string) map[string]any {
	params := []any{
		map[string]any{"templateKey": "logicalConnector", "values": []any{"AND"}},
		map[string]any{"templateKey": "allowAnonymous", "values": []any{"false"}},
	}
	for _, t := range idTypes {
		params = append(params, map[string]any{
			"templateKey": "IdentificationRule",
			"parameters": []any{
				map[string]any{"templateKey": "applicationLookup", "values": []any{"strict"}},
				map[string]any{"templateKey": "identificationType", "values": []any{t}},
			},
		})
	}
	action := map[string]any{
		"names":       []any{map[string]any{"value": name, "locale": "en"}},
		"templateKey": "evaluatePolicy",
		"parameters":  params,
		"active":      true,
	}
	if id != "" {
		action["id"] = id
	}
	return map[string]any{"policyAction": action}
}

// normalizeIPRange converts an ipAllowlist entry to the explicit from-to form
// webMethods stores unambiguously AND renders in its UI. Pinned live on
// apigateway:10.15 (2026-07-15):
//   - a single IP "X" -> "X-X". A bare single IP IS enforced as an exact match at
//     runtime (allowlist ["0.0.0.0"] rejects a different caller 403 — it is NOT a
//     from->infinity open range), but the UI two-field editor does not display a
//     "from" with no "to", so an operator sees "no IP set". "X-X" enforces the
//     same exact match and shows in the UI.
//   - a CIDR "X/n" -> "<first>-<last>". The gateway SILENTLY IGNORES CIDR (the PUT
//     is a no-op, the previous value survives) — a fail-open. Expanding to the
//     address range makes the restriction real.
//   - an explicit "A-B" -> unchanged (trimmed).
func normalizeIPRange(s string) (string, error) {
	s = strings.TrimSpace(s)
	if net.ParseIP(s) != nil {
		return s + "-" + s, nil
	}
	if _, ipnet, err := net.ParseCIDR(s); err == nil {
		first, last := cidrBounds(ipnet)
		return first.String() + "-" + last.String(), nil
	}
	if lo, hi, ok := strings.Cut(s, "-"); ok {
		lo, hi = strings.TrimSpace(lo), strings.TrimSpace(hi)
		if net.ParseIP(lo) != nil && net.ParseIP(hi) != nil {
			return lo + "-" + hi, nil
		}
	}
	return "", fmt.Errorf("ipAllowlist %q: not an IP, a CIDR, or an A-B range", s)
}

// cidrBounds returns the first (network) and last (broadcast) address of a CIDR.
func cidrBounds(n *net.IPNet) (net.IP, net.IP) {
	ip := n.IP
	if v4 := ip.To4(); v4 != nil {
		ip = v4
	}
	first := make(net.IP, len(ip))
	last := make(net.IP, len(ip))
	for i := range ip {
		first[i] = ip[i] & n.Mask[i]
		last[i] = ip[i] | ^n.Mask[i]
	}
	return first, last
}
