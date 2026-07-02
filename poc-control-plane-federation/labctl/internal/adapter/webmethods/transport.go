package webmethods

// Transport-protocol projection (ADR-076 mTLS wiring). By default an imported API
// accepts HTTP on the transport stage (entryProtocolPolicy protocol=[http]).
// Setting protocol=[https] makes the API reachable ONLY over the HTTPS listener —
// which, when that listener enforces clientAuth=require (+ a trusted client CA in
// the IS truststore), gives end-to-end mTLS for THIS API: no-cert -> TLS reject,
// HTTP -> "Transport protocol not supported", HTTPS+trusted-cert -> reaches IAM.
//
// The clientAuth=require flip + the CA import into DEFAULT_IS_TRUSTSTORE are the
// IS-admin layer (keytool + listener config + restart, no apigateway REST) — the
// Ansible/sync-gateway-config responsibility. This projection wires the API-side
// half (which port protocol it accepts), which IS a clean REST policyAction edit.

import (
	"context"
	"fmt"
	"net/http"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

const stageTransport = "transport"

// firstStageActionID returns the first enforcement action id of the named stage,
// "" when the stage is absent or empty.
func firstStageActionID(policy map[string]any, stageKey string) string {
	stages, _ := policy["policyEnforcements"].([]any)
	for _, s := range stages {
		sm, _ := s.(map[string]any)
		if sm == nil {
			continue
		}
		if key, _ := sm["stageKey"].(string); key != stageKey {
			continue
		}
		enf, _ := sm["enforcements"].([]any)
		for _, e := range enf {
			if em, _ := e.(map[string]any); em != nil {
				if id, _ := em["enforcementObjectId"].(string); id != "" {
					return id
				}
			}
		}
	}
	return ""
}

// actionProtocolIs reports whether the entryProtocolPolicy action already carries
// exactly the single protocol value (idempotence gate).
func actionProtocolIs(action map[string]any, protocol string) bool {
	params, _ := action["parameters"].([]any)
	for _, p := range params {
		pm, _ := p.(map[string]any)
		if pm == nil {
			continue
		}
		if tk, _ := pm["templateKey"].(string); tk != "protocol" {
			continue
		}
		values, _ := pm["values"].([]any)
		if len(values) != 1 {
			return false
		}
		v, _ := values[0].(string)
		return v == protocol
	}
	return false
}

// setActionProtocol overwrites the entryProtocolPolicy action's protocol values.
func setActionProtocol(action map[string]any, protocol string) {
	params, _ := action["parameters"].([]any)
	for _, p := range params {
		if pm, _ := p.(map[string]any); pm != nil {
			if tk, _ := pm["templateKey"].(string); tk == "protocol" {
				pm["values"] = []any{protocol}
				return
			}
		}
	}
	// No protocol param yet (unexpected for entryProtocolPolicy): add one.
	action["parameters"] = append(params, map[string]any{"templateKey": "protocol", "values": []any{protocol}})
}

// ensureTransportProtocol converges the API's transport stage entryProtocolPolicy
// to the manifest's transportProtocol (e.g. "https" for mTLS-only). nil/empty =
// no-op. Idempotent: a read-back matching the desired protocol is a no-op.
func (a *Adapter) ensureTransportProtocol(ctx context.Context, apiID string) error {
	if a.transportProtocol == "" {
		return nil
	}
	rec, err := a.getAPI(ctx, apiID)
	if err != nil {
		return fmt.Errorf("transport: %w", err)
	}
	_, policy, err := a.findServicePolicy(ctx, rec.Policies)
	if err != nil {
		return err
	}
	actionID := firstStageActionID(policy, stageTransport)
	if actionID == "" {
		return fmt.Errorf("transport: no entryProtocolPolicy action on the %s stage", stageTransport)
	}

	url := a.adminPath("/policyActions/" + actionID)
	var raw map[string]any
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &raw); err != nil {
		return fmt.Errorf("transport: get action %s: %w", actionID, err)
	}
	action := raw
	if pa, ok := raw["policyAction"].(map[string]any); ok && pa != nil {
		action = pa
	}
	if actionProtocolIs(action, a.transportProtocol) {
		return nil // converged — idempotent no-op
	}
	setActionProtocol(action, a.transportProtocol)
	code, body, err := a.sendJSON(ctx, http.MethodPut, url, map[string]any{"policyAction": action})
	if err != nil {
		return fmt.Errorf("transport: set protocol=%s on action %s: %w", a.transportProtocol, actionID, err)
	}
	if code != http.StatusOK && code != http.StatusCreated {
		return fmt.Errorf("transport: set protocol=%s: expected 200/201, got %d: %s", a.transportProtocol, code, truncate(body, 300))
	}
	return nil
}
