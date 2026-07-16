package webmethods

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
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

// --- enforcement: pose the AND identification action + attach to the API -----

// actionMatchesRuleTypes reports whether an evaluatePolicy action's set of
// IdentificationRule types equals want (order-insensitive). It is the exact
// fingerprint that tells the OAuth2+cert action ({oAuth2Token,httpsCertificate})
// apart from the self-service cert+IP action ({httpsCertificate,ipAddressRange}):
// both carry an httpsCertificate rule, so a "has cert" test would confuse them.
func actionMatchesRuleTypes(action map[string]any, want []string) bool {
	got := actionRuleTypes(action)
	if len(got) != len(want) {
		return false
	}
	set := make(map[string]int, len(got))
	for _, g := range got {
		set[g]++
	}
	for _, w := range want {
		if set[w] == 0 {
			return false
		}
		set[w]--
	}
	return true
}

// selfServiceActionName documents the shared AND action (matching is on the rule
// fingerprint, never the name).
func selfServiceActionName(idTypes []string) string {
	return "Identify & Authorize (" + strings.Join(idTypes, "+") + ") (labctl)"
}

// ensureSelfServiceIdentifyAction finds the shared AND(idTypes) IAM action by its
// exact rule-type fingerprint or creates it, and returns its id. The body is
// fixed for a given idTypes, so a present action is reused as-is (no PUT) — same
// shared-action discipline as ensureMtlsIdentifyAction (avoids action sprawl).
func (a *Adapter) ensureSelfServiceIdentifyAction(ctx context.Context, idTypes []string) (string, error) {
	actions, err := a.listPolicyActions(ctx)
	if err != nil {
		return "", err
	}
	for _, act := range actions {
		if actionMatchesRuleTypes(act, idTypes) {
			if id, _ := act["id"].(string); id != "" {
				return id, nil // converged — idempotent no-op
			}
		}
	}
	url := a.adminPath("/policyActions")
	code, raw, err := a.sendJSON(ctx, http.MethodPost, url, identifyAndActionBody("", selfServiceActionName(idTypes), idTypes))
	if err != nil {
		return "", fmt.Errorf("self-service identify: create AND action: %w", err)
	}
	if code != http.StatusCreated && code != http.StatusOK {
		return "", fmt.Errorf("self-service identify: create AND action: expected 200/201, got %d: %s", code, truncate(raw, 300))
	}
	id := parsePolicyActionID(raw)
	if id == "" {
		return "", fmt.Errorf("self-service identify: create AND action: response carries no id: %s", truncate(raw, 300))
	}
	return id, nil
}

// ensureSelfServiceIdentify poses the AND(idTypes) Identify & Authorize action on
// the API's SERVICE policy and attaches it to the IAM stage — the enforcement
// that OPPOSES the consumer's cert/IP identifiers (posed-but-inert without it:
// the fail-open of ADR-078). Idempotent: converges once the stage references the
// action, and reuses attachIAMStage + the read-back proof from the inbound-auth
// path. A no-op when idTypes is empty.
func (a *Adapter) ensureSelfServiceIdentify(ctx context.Context, apiID string, idTypes []string) error {
	if len(idTypes) == 0 {
		return nil
	}
	rec, err := a.getAPI(ctx, apiID)
	if err != nil {
		return fmt.Errorf("self-service identify: %w", err)
	}
	policyID, policy, err := a.findServicePolicy(ctx, rec.Policies)
	if err != nil {
		return err
	}
	actionID, err := a.ensureSelfServiceIdentifyAction(ctx, idTypes)
	if err != nil {
		return err
	}
	if policyIAMReferences(policy, actionID) {
		return nil // converged
	}
	if err := a.attachIAMStage(ctx, apiID, policyID, policy, actionID); err != nil {
		return err
	}
	after, err := a.getPolicy(ctx, policyID)
	if err != nil {
		return fmt.Errorf("self-service identify: read-back after attach: %w", err)
	}
	if !policyIAMReferences(after, actionID) {
		return fmt.Errorf("self-service identify: policy %s does not reference action %s in the %s stage after attach", policyID, actionID, stageIAM)
	}
	return nil
}

// selfServiceIdTypes derives the identification dimensions to enforce from the
// consumer's DECLARED identity: oAuth2Token when the OAuth2 path is on (so the
// existing token gate is never weakened), plus httpsCertificate and/or
// ipAddressRange for each identifier the consumer actually carries. Order is
// stable so re-apply hits the same shared action.
func (a *Adapter) selfServiceIdTypes(spec *adapter.ConsumerSpec) []string {
	var t []string
	if a.inbound.oauth2Enabled() {
		t = append(t, "oAuth2Token")
	}
	if strings.TrimSpace(spec.PublicCertRef) != "" {
		t = append(t, identificationTypeCert)
	}
	if len(dedup(spec.IPAllowlist)) > 0 {
		t = append(t, identificationTypeIP)
	}
	return t
}
