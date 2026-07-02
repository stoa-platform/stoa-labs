package webmethods

// Rate-limit projection (ADR-076 rate-limit leg) for apigateway:10.15. A
// "Traffic Optimization" (templateKey "throttle") policyAction on the LMT stage
// enforces a hard request limit IN-GATEWAY: requests over the limit are rejected
// 429 (NOT fail-open, unlike the OAuth2 audience barrier). The exact body was
// pinned live against the trial (each parameter reverse-engineered from the
// policy-store template + the 500 errors):
//   - throttleRule.throttleRuleName = "requestCount" (ReadingType enum key, NOT
//     the display "Total Request Count"), monitorRuleOperator = "GT", value = limit
//   - consumerIds = ["all"] + consumerSpecificCounter = "false" (count globally)
//   - alertFrequency = "once" (AlertFrequencyType), alertIntervalUnit = minutes|...
//   - destination = { destinationType: "GATEWAY", logLevel: "Error" }
// dependentActions = [evaluatePolicy]: the LMT stage must sit after the IAM
// Identify & Authorize action, so ensureThrottle runs AFTER ensureInboundAuth.

import (
	"context"
	"fmt"
	"net/http"
	"strconv"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

// stageLMT carries the throttle enforcement — "Logging, Monitoring and Traffic
// Optimization". Like transport/routing it is not UPPERCASE the way IAM is.
const stageLMT = "LMT"

// throttleActionName is the display name POSTed with the action (documentation
// only: matching is on templateKey, never the name).
const throttleActionName = "Traffic Optimization (labctl)"

// throttleConfig is the parsed rateLimit manifest block.
type throttleConfig struct {
	requests int    // hard limit (max requests)
	interval int    // window/alert interval
	unit     string // minutes|hours|days|weeks|calendar_week|calendar_month
}

// throttleFromConfig projects the generic adapter Config onto the throttle knobs.
// Absent/zero limit -> nil (feature off, zero extra calls).
func throttleFromConfig(cfg adapter.Config) *throttleConfig {
	req, _ := strconv.Atoi(cfg.Opt("rateLimitRequests", ""))
	if req <= 0 {
		return nil
	}
	interval, _ := strconv.Atoi(cfg.Opt("rateLimitInterval", "1"))
	if interval <= 0 {
		interval = 1
	}
	unit := cfg.Opt("rateLimitUnit", "minutes")
	if unit == "" {
		unit = "minutes"
	}
	return &throttleConfig{requests: req, interval: interval, unit: unit}
}

// throttleActionBody builds the ENVELOPED throttle policyAction body (id empty ->
// POST create; id set -> PUT converge in place). Values are the live-pinned ones.
func (a *Adapter) throttleActionBody(id string) map[string]any {
	action := map[string]any{
		"names":       []any{map[string]any{"value": throttleActionName, "locale": "en"}},
		"templateKey": "throttle",
		"parameters": []any{
			map[string]any{"templateKey": "throttleRule", "parameters": []any{
				map[string]any{"templateKey": "throttleRuleName", "values": []any{"requestCount"}},
				map[string]any{"templateKey": "monitorRuleOperator", "values": []any{"GT"}},
				map[string]any{"templateKey": "value", "values": []any{strconv.Itoa(a.throttle.requests)}},
			}},
			map[string]any{"templateKey": "consumerIds", "values": []any{"all"}},
			map[string]any{"templateKey": "consumerSpecificCounter", "values": []any{"false"}},
			map[string]any{"templateKey": "alertInterval", "values": []any{strconv.Itoa(a.throttle.interval)}},
			map[string]any{"templateKey": "alertIntervalUnit", "values": []any{a.throttle.unit}},
			map[string]any{"templateKey": "alertFrequency", "values": []any{"once"}},
			map[string]any{"templateKey": "alertMessage", "values": []any{"Traffic limit exceeded"}},
			map[string]any{"templateKey": "destination", "parameters": []any{
				map[string]any{"templateKey": "destinationType", "values": []any{"GATEWAY"}},
				map[string]any{"templateKey": "logLevel", "values": []any{"Error"}},
			}},
		},
		"active": true,
	}
	if id != "" {
		action["id"] = id
	}
	return map[string]any{"policyAction": action}
}

// isThrottleAction reports whether an action record is a throttle (rate-limit) action.
func isThrottleAction(action map[string]any) bool {
	tk, _ := action["templateKey"].(string)
	return tk == "throttle"
}

// ensureThrottle converges the rate-limit throttle action onto the API's LMT
// stage. nil receiver config = no-op. Mirrors ensureInboundAuth: find/create the
// action, resolve the service policy, attach the LMT stage (mutating the read-back
// record so the wholesale-replacing PUT keeps IAM/routing), and prove it stuck.
func (a *Adapter) ensureThrottle(ctx context.Context, apiID, apiName string) error {
	if a.throttle == nil {
		return nil
	}
	actionID, err := a.ensureThrottleAction(ctx)
	if err != nil {
		return err
	}
	rec, err := a.getAPI(ctx, apiID)
	if err != nil {
		return fmt.Errorf("throttle: %w", err)
	}
	policyID, policy, err := a.findServicePolicy(ctx, rec.Policies)
	if err != nil {
		return err
	}
	if policyStageReferences(policy, stageLMT, actionID) {
		return nil // converged — idempotent no-op
	}
	injectStage(policy, stageLMT, actionID)
	if err := a.putPolicyGuarded(ctx, apiID, policyID, policy, "throttle: attach "+stageLMT+" stage"); err != nil {
		return err
	}
	after, err := a.getPolicy(ctx, policyID)
	if err != nil {
		return fmt.Errorf("throttle: read-back after attach: %w", err)
	}
	if !policyStageReferences(after, stageLMT, actionID) {
		return fmt.Errorf("throttle: policy %s still does not reference action %s in the %s stage after attach", policyID, actionID, stageLMT)
	}
	return nil
}

// ensureThrottleAction finds the throttle action (by templateKey) and converges
// its limit in place, or creates one. Returns its id. Like the shared Identify &
// Authorize action, a single throttle action is reused (per-API LMT references
// point at it).
func (a *Adapter) ensureThrottleAction(ctx context.Context) (string, error) {
	actions, err := a.listPolicyActions(ctx)
	if err != nil {
		return "", err
	}
	for _, act := range actions {
		if !isThrottleAction(act) {
			continue
		}
		id, _ := act["id"].(string)
		if id == "" {
			continue
		}
		// Converge the limit in place (PUT). Cheap and keeps the limit current.
		url := a.adminPath("/policyActions/" + id)
		code, raw, perr := a.sendJSON(ctx, http.MethodPut, url, a.throttleActionBody(id))
		if perr != nil {
			return "", fmt.Errorf("throttle: converge action %s: %w", id, perr)
		}
		if code != http.StatusOK && code != http.StatusCreated {
			return "", fmt.Errorf("throttle: converge action %s: expected 200/201, got %d: %s", id, code, truncate(raw, 300))
		}
		return id, nil
	}
	url := a.adminPath("/policyActions")
	code, raw, err := a.sendJSON(ctx, http.MethodPost, url, a.throttleActionBody(""))
	if err != nil {
		return "", fmt.Errorf("throttle: create action: %w", err)
	}
	if code != http.StatusCreated && code != http.StatusOK {
		return "", fmt.Errorf("throttle: create action: expected 200/201, got %d: %s", code, truncate(raw, 300))
	}
	id := parsePolicyActionID(raw)
	if id == "" {
		return "", fmt.Errorf("throttle: create action: response carries no id: %s", truncate(raw, 300))
	}
	return id, nil
}

// injectStage sets the named stage to reference exactly actionID, mutating the
// read-back policy record so the wholesale-replacing PUT keeps every existing
// stage. An existing stage of the same key is replaced in place; otherwise the
// stage is APPENDED — correct for LMT, which is last in the stage order
// (transport, IAM, routing, LMT). Companion to injectIAMStage (which inserts the
// IAM stage BEFORE routing).
func injectStage(policy map[string]any, stageKey, actionID string) {
	stage := map[string]any{
		"stageKey": stageKey,
		"enforcements": []any{
			map[string]any{"enforcementObjectId": actionID, "order": nil},
		},
	}
	stages, _ := policy["policyEnforcements"].([]any)
	for i, s := range stages {
		if sm, _ := s.(map[string]any); sm != nil {
			if key, _ := sm["stageKey"].(string); key == stageKey {
				stages[i] = stage
				policy["policyEnforcements"] = stages
				return
			}
		}
	}
	policy["policyEnforcements"] = append(stages, stage)
}
