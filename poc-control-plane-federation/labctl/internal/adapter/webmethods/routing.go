package webmethods

// Routing-by-alias projection for the REAL apigateway:10.15, ported from the
// live-validated spike (data-plane proven: changing the alias value re-routes
// PER REQUEST, no reactivation). It turns the import-time backend (servers[]
// in the spec, see injectBackendServer) into an ENV-SWITCHABLE value held by a
// gateway endpoint alias:
//
//  1. ENDPOINT ALIAS (POST/PUT /rest/apigateway/alias, NAKED body): {"name",
//     "type":"endpoint", "endPointURI" (casse EXACTE: endPointURI),
//     "optimizationTechnique":"None", "passSecurityHeaders":true}. Read-back
//     GET serves the {"alias":{...}} envelope.
//  2. ${alias} ROUTING: the straightThroughRouting action's "endpointUri"
//     param is converged to ["${<aliasName>}/${sys:resource_path}"]. PIÈGE
//     pinned live: PUT /policyActions/{id} requires an ENVELOPED body
//     {"policyAction":{"id":...,...}} — a NAKED body answers 200 but persists
//     NOTHING (silent no-op). Every action PUT here is therefore followed by a
//     read-back assertion. The UI adds params this code does not model (e.g.
//     "method":["CUSTOM"]), so the converge PUTs the READ-BACK record with
//     ONLY endpointUri replaced — unknown params survive.
//  3. CREDENTIAL ALIAS (optional): {"type":"httpTransportSecurityAlias",
//     "authType":"HTTP_BASIC","authMode":"NEW","httpAuthCredentials":
//     {"userName", "password": BASE64 du mot de passe — OBLIGATOIRE, sinon
//     stocké corrompu}}. On read-back the password is MASKED (base64 of
//     asterisks), so labctl can never tell whether the stored secret drifted
//     (UI edit, ES restore, upstream rotation) — the alias is therefore
//     WRITE-ALWAYS: the desired credentials are re-emitted on EVERY apply. That
//     is what makes a password rotation (same userName, new password) actually
//     reach the gateway; idempotence is proven by stable ids, not by the
//     absence of a PUT.
//  4. OUTBOUND AUTH – TRANSPORT (optional, with the credential alias): action
//     templateKey "outboundTransportAuthentication" whose parameters are ONE
//     nested "transportSecurity" group (FLAT params => NPE 500 in
//     OutboundTransportSecurityFactory, pinned live), alias="${credAlias}".
//     Attached to the lowercase "routing" stage of the service policy (same
//     wholesale-PUT semantics as the IAM stage).
//
// Re-import (PUT /apis/{id}) PRESERVES the policy and the routing action on
// this build (same id, ${alias} intact) — the convergence stays defensive
// anyway: re-apply with no drift is a read-only pass.

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// stageRouting is the policy stage carrying routing enforcements — lowercase
// on the real product (IAM is the uppercase outlier).
const stageRouting = "routing"

// Default alias-name templates. "{api}" is replaced by the sanitised API name
// so one manifest block serves every API published through the target.
const (
	defaultEndpointAliasTemplate   = "{api}-backend"
	defaultCredentialAliasTemplate = "{api}-backend-cred"
)

// routingConfig is the parsed routing manifest block (nil = feature off).
type routingConfig struct {
	endpointAliasName string // name TEMPLATE ("{api}" placeholder allowed)
	endpointAliasURL  string // PER-ENV backend URL the alias resolves to (required)

	// credAliasName is the credential-alias name TEMPLATE; "" = no credential
	// alias. The user/pass VALUES come from Target.Credentials
	// backendUsername/backendPassword — never from the routing block itself.
	credAliasName   string
	backendUsername string
	backendPassword string

	// credAuthType selects the transport-security auth scheme: HTTP_BASIC
	// (default) or NTLM (spike-pinned 2026-07-17: same httpAuthCredentials
	// container + a `domain` field). Anything else is refused at construction
	// until its credential container is pinned by a spike (ADR-079).
	credAuthType string
	// credDomain is the NTLM domain (required when credAuthType is NTLM;
	// not a secret — it rides in the options block).
	credDomain string
}

// routingFromConfig projects the generic adapter Config onto the routing
// knobs. Absent block -> nil (no-op, zero extra calls). A half-filled block is
// a config bug surfaced at construction (fail closed, like inboundAuth).
func routingFromConfig(cfg adapter.Config) (*routingConfig, error) {
	epName := cfg.Opt("routingEndpointAliasName", "")
	epURL := cfg.Opt("routingEndpointAliasUrl", "")
	credName := cfg.Opt("routingCredentialAliasName", "")
	if epName == "" && epURL == "" && credName == "" {
		return nil, nil
	}
	// The alias URL is the whole point of the feature: a routing block without
	// it can never re-point the backend — fail closed.
	if epURL == "" {
		return nil, fmt.Errorf("webmethods: routing needs endpointAlias.url (the per-environment backend URL the ${alias} resolves to)")
	}
	if epName == "" {
		epName = defaultEndpointAliasTemplate
	}
	rc := &routingConfig{
		endpointAliasName: epName,
		endpointAliasURL:  epURL,
		credAliasName:     credName,
	}
	if credName != "" {
		// The alias stores REAL backend credentials; without both values the
		// gateway would store a corrupt/empty credential — fail closed.
		rc.backendUsername = cfg.Cred("backendUsername", "")
		rc.backendPassword = cfg.Cred("backendPassword", "")
		if rc.backendUsername == "" || rc.backendPassword == "" {
			return nil, fmt.Errorf("webmethods: routing.credentialAlias needs credentials.backendUsername and credentials.backendPassword (the values the alias stores; got username-set=%t password-set=%t)", rc.backendUsername != "", rc.backendPassword != "")
		}
		rc.credAuthType = cfg.Opt("routingCredentialAuthType", "HTTP_BASIC")
		rc.credDomain = cfg.Opt("routingCredentialDomain", "")
		if rc.credAuthType != "HTTP_BASIC" && rc.credAuthType != "NTLM" {
			return nil, fmt.Errorf("webmethods: routing.credentialAlias authType %q unsupported — HTTP_BASIC or NTLM (other containers need a shape spike first, ADR-079)", rc.credAuthType)
		}
		if rc.credAuthType == "NTLM" && rc.credDomain == "" {
			return nil, fmt.Errorf("webmethods: routing.credentialAlias authType NTLM requires routingCredentialDomain")
		}
	}
	return rc, nil
}

// expandAliasTemplate replaces the "{api}" placeholder with the sanitised API
// name (alias names are as conservative as apiName on 10.15).
func expandAliasTemplate(tpl, apiName string) string {
	return strings.ReplaceAll(tpl, "{api}", sanitizeWMName(apiName))
}

// ensureRouting converges the gateway onto the manifest's routing block for
// one published API: endpoint alias present and pointing at the configured
// URL, ${alias} routing on the straightThroughRouting action, and (optionally)
// the credential alias + Outbound Auth – Transport action on the routing
// stage. nil receiver config = no-op (ZERO extra network calls).
func (a *Adapter) ensureRouting(ctx context.Context, apiID, apiName string) error {
	if a.routing == nil {
		return nil
	}
	epName := expandAliasTemplate(a.routing.endpointAliasName, apiName)
	if err := a.ensureEndpointAlias(ctx, epName); err != nil {
		return err
	}
	credName := ""
	if a.routing.credAliasName != "" {
		credName = expandAliasTemplate(a.routing.credAliasName, apiName)
		if err := a.ensureCredentialAlias(ctx, credName); err != nil {
			return err
		}
	}
	return a.convergeRouting(ctx, apiID, epName, credName)
}

// --- endpoint alias ----------------------------------------------------------

// ensureEndpointAlias converges the endpoint alias NAME onto the per-env URL —
// delegated to the parameterised ADR-079 primitive (create NAKED body with the
// spike-pinned shape, PUT-converge on drift, read-back asserted on the
// endPointURI casing trap, never delete/recreate).
func (a *Adapter) ensureEndpointAlias(ctx context.Context, name string) error {
	// The PROXY projection's spike-pinned creation shape: pass-through of the
	// security headers is REQUIRED here (proven pass-through Basic, spike
	// 2026-07-09) — promote-seeded aliases deliberately do NOT carry it.
	if err := a.ensureEndpointAliasValueWith(ctx, name, a.routing.endpointAliasURL, map[string]any{
		"optimizationTechnique": "None",
		"passSecurityHeaders":   true,
	}); err != nil {
		return fmt.Errorf("routing: %w", err)
	}
	return nil
}

// getAliasRecord reads one alias by id, unwrapping the {"alias":{...}}
// envelope (flat record fallback).
func (a *Adapter) getAliasRecord(ctx context.Context, aliasID string) (map[string]any, error) {
	url := a.adminPath("/alias/" + aliasID)
	var raw map[string]any
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &raw); err != nil {
		return nil, err
	}
	if al, ok := raw["alias"].(map[string]any); ok && al != nil {
		return al, nil
	}
	return raw, nil
}

// --- credential alias ----------------------------------------------------------

// credAliasPassword returns the base64 of the backend password — the
// spike-pinned wire format: a CLEAR password is stored CORRUPT by the product,
// the base64 encoding is MANDATORY on every write.
func (a *Adapter) credAliasPassword() string {
	return base64.StdEncoding.EncodeToString([]byte(a.routing.backendPassword))
}

// ensureCredentialAlias finds the httpTransportSecurityAlias by NAME and
// converges it WRITE-ALWAYS: the stored password is never readable (masked as
// the base64 of asterisks on every read-back), so labctl cannot detect drift
// on the gateway (UI edit, ES snapshot restore, upstream rotation). The only
// sound convergence for a write-only secret is to re-emit the desired
// credentials on EVERY apply — keying the write on the masked read-back would
// either PUT nothing useful or, worse, write the mask back as the real
// password. Re-emitting also makes a same-user password rotation reach the
// gateway (the bug this replaced: a drift check keyed on userName skipped the
// PUT and left the old password live). Idempotence is proven by stable ids and
// the data-plane, not by the absence of a PUT.
func (a *Adapter) ensureCredentialAlias(ctx context.Context, name string) error {
	if err := a.EnsureCredentialAliasValue(ctx, name,
		a.routing.credAuthType, a.routing.backendUsername,
		a.credAliasPassword(), a.routing.credDomain); err != nil {
		return fmt.Errorf("routing: %w", err)
	}
	return nil
}

// --- routing stage convergence -------------------------------------------------

// aliasRef renders the ${name} template reference the gateway resolves per
// request (both the routing endpointUri prefix and the outbound-auth alias
// param use this form, pinned live).
func aliasRef(name string) string {
	return "${" + name + "}"
}

// convergeRouting converges the routing STAGE of the API's service policy:
// (a) the straightThroughRouting action's endpointUri -> ${alias}/${sys:
// resource_path}; (b) when a credential alias is configured, an Outbound Auth –
// Transport action referencing ${credAlias}, attached to the routing stage.
func (a *Adapter) convergeRouting(ctx context.Context, apiID, epName, credName string) error {
	rec, err := a.getAPI(ctx, apiID)
	if err != nil {
		return fmt.Errorf("routing: %w", err)
	}
	policyID, policy, err := a.findServicePolicy(ctx, rec.Policies)
	if err != nil {
		return fmt.Errorf("routing: %w", err)
	}
	actions, err := a.listPolicyActions(ctx)
	if err != nil {
		return fmt.Errorf("routing: %w", err)
	}
	byID := make(map[string]map[string]any, len(actions))
	for _, act := range actions {
		if id, _ := act["id"].(string); id != "" {
			byID[id] = act
		}
	}
	routeIDs := stageEnforcementIDs(policy, stageRouting)

	// (a) ${alias} on the straightThroughRouting action minted at import.
	if err := a.convergeStraightThroughRouting(ctx, apiID, routeIDs, byID, epName); err != nil {
		return err
	}

	// (b) Outbound Auth – Transport, only when a credential alias is configured.
	if credName == "" {
		return nil
	}
	return a.convergeOutboundAuth(ctx, apiID, policyID, policy, routeIDs, byID, credName)
}

// stageEnforcementIDs returns the enforcementObjectIds of the named stage.
func stageEnforcementIDs(policy map[string]any, stageKey string) []string {
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
		out := make([]string, 0, len(enf))
		for _, e := range enf {
			if em, _ := e.(map[string]any); em != nil {
				if id, _ := em["enforcementObjectId"].(string); id != "" {
					out = append(out, id)
				}
			}
		}
		return out
	}
	return nil
}

// findStageActions returns the ids of EVERY action on the stage whose
// templateKey matches, in enforcement order. A well-formed policy carries at
// most one enforcing action per templateKey on a stage; more than one is an
// ambiguity the projection must never converge blindly — a first-match would
// leave the extra action live while reporting "converged" (the exact class of
// the A1 first-rule-only false negative, here for a duplicate/orphan or an
// injected outbound-auth action re-pointing the backend credentials).
func findStageActions(routeIDs []string, byID map[string]map[string]any, templateKey string) []string {
	var ids []string
	for _, id := range routeIDs {
		act := byID[id]
		if act == nil {
			continue
		}
		if tk, _ := act["templateKey"].(string); tk == templateKey {
			ids = append(ids, id)
		}
	}
	return ids
}

// findStageAction returns the SINGLE action of the stage whose templateKey
// matches (id + record), fail-closed on more than one. Callers rely on there
// being at most one enforcing action per templateKey; >1 is refused loudly
// rather than silently converging the first.
func findStageAction(routeIDs []string, byID map[string]map[string]any, templateKey string) (string, map[string]any, error) {
	ids := findStageActions(routeIDs, byID, templateKey)
	if len(ids) > 1 {
		return "", nil, fmt.Errorf("routing: the %s stage carries %d %s actions (%v) — ambiguous (duplicate, orphan of a prior run, or injected); refuse to converge the first and leave the rest live", stageRouting, len(ids), templateKey, ids)
	}
	if len(ids) == 0 {
		return "", nil, nil
	}
	return ids[0], byID[ids[0]], nil
}

// actionParamValues returns the values of a top-level action parameter
// (nil when the parameter is absent).
func actionParamValues(action map[string]any, key string) []any {
	params, _ := action["parameters"].([]any)
	for _, p := range params {
		pm, _ := p.(map[string]any)
		if pm == nil {
			continue
		}
		if tk, _ := pm["templateKey"].(string); tk == key {
			values, _ := pm["values"].([]any)
			return values
		}
	}
	return nil
}

// setActionParamValues overwrites (or appends) ONE top-level parameter on the
// read-back action record, leaving every other parameter — including ones this
// code does not model, like the UI-added "method":["CUSTOM"] — untouched.
func setActionParamValues(action map[string]any, key string, values []any) {
	params, _ := action["parameters"].([]any)
	for _, p := range params {
		pm, _ := p.(map[string]any)
		if pm == nil {
			continue
		}
		if tk, _ := pm["templateKey"].(string); tk == key {
			pm["values"] = values
			return
		}
	}
	action["parameters"] = append(params, map[string]any{"templateKey": key, "values": values})
}

// firstStringValue returns values[0] as a string ("" when empty/not a string).
func firstStringValue(values []any) string {
	if len(values) == 0 {
		return ""
	}
	s, _ := values[0].(string)
	return s
}

// convergeStraightThroughRouting re-points the import-minted routing action at
// ${alias}/${sys:resource_path}. The PUT sends the FULL read-back record
// ENVELOPED with ONLY endpointUri replaced, then read-back-asserts the value —
// the live trap is a 200 that persists NOTHING when the envelope is missing.
func (a *Adapter) convergeStraightThroughRouting(ctx context.Context, apiID string, routeIDs []string, byID map[string]map[string]any, epName string) error {
	actionID, action, err := findStageAction(routeIDs, byID, "straightThroughRouting")
	if err != nil {
		return err
	}
	if action == nil {
		// An imported API always carries one on this build; its absence means
		// the policy was hand-edited into a shape this projection cannot
		// converge — fail closed rather than route to the wrong backend.
		return fmt.Errorf("routing: the %s stage carries no straightThroughRouting action (policy hand-edited?) — cannot converge ${%s} routing", stageRouting, epName)
	}
	want := aliasRef(epName) + "/${sys:resource_path}"
	if got := firstStringValue(actionParamValues(action, "endpointUri")); got == want {
		return nil // converged — idempotent no-op
	}
	setActionParamValues(action, "endpointUri", []any{want})
	if err := a.putPolicyActionGuarded(ctx, apiID, actionID, action, "routing: converge straightThroughRouting"); err != nil {
		return err
	}
	return a.assertActionParamStuck(ctx, actionID, "endpointUri", want)
}

// convergeOutboundAuth materialises the Outbound Auth – Transport action
// (nested transportSecurity group — FLAT params NPE the product) and attaches
// it to the routing stage, or converges the alias param of an existing one.
func (a *Adapter) convergeOutboundAuth(ctx context.Context, apiID, policyID string, policy map[string]any, routeIDs []string, byID map[string]map[string]any, credName string) error {
	want := aliasRef(credName)
	actionID, action, err := findStageAction(routeIDs, byID, "outboundTransportAuthentication")
	if err != nil {
		return err
	}
	if action != nil {
		if got := outboundAuthAlias(action); got == want {
			return nil // converged — idempotent no-op
		}
		setOutboundAuthAlias(action, want)
		if err := a.putPolicyActionGuarded(ctx, apiID, actionID, action, "routing: converge outbound transport auth"); err != nil {
			return err
		}
		return a.assertOutboundAliasStuck(ctx, actionID, want)
	}

	// Absent: POST the action (ENVELOPED body, ONE nested transportSecurity
	// group — the spike-pinned shape), then attach it to the routing stage.
	body := map[string]any{"policyAction": map[string]any{
		"names":       []any{map[string]any{"value": "Outbound Auth - Transport (labctl)", "locale": "en"}},
		"templateKey": "outboundTransportAuthentication",
		"parameters": []any{
			map[string]any{
				"templateKey": "transportSecurity",
				"parameters": []any{
					map[string]any{"templateKey": "authType", "values": []any{"ALIAS"}},
					map[string]any{"templateKey": "authMode", "values": []any{"NEW"}},
					map[string]any{"templateKey": "alias", "values": []any{want}},
				},
			},
		},
		"active": true,
	}}
	url := a.adminPath("/policyActions")
	code, raw, err := a.sendJSON(ctx, http.MethodPost, url, body)
	if err != nil {
		return fmt.Errorf("routing: create outbound transport auth action: %w", err)
	}
	if code != http.StatusCreated && code != http.StatusOK {
		return fmt.Errorf("routing: create outbound transport auth action: expected 200/201, got %d: %s", code, truncate(raw, 300))
	}
	newID := parsePolicyActionID(raw)
	if newID == "" {
		return fmt.Errorf("routing: create outbound transport auth action: response carries no id: %s", truncate(raw, 300))
	}

	// Attach to the routing stage (mutating the READ-BACK policy: the PUT
	// replaces policyEnforcements wholesale — same pattern as the IAM stage).
	if !appendStageEnforcement(policy, stageRouting, newID) {
		return fmt.Errorf("routing: policy %s has no %s stage to attach the outbound auth action to", policyID, stageRouting)
	}
	if err := a.putPolicyGuarded(ctx, apiID, policyID, policy, "routing: attach outbound auth to "+stageRouting+" stage"); err != nil {
		return err
	}
	after, err := a.getPolicy(ctx, policyID)
	if err != nil {
		return fmt.Errorf("routing: read-back after attach: %w", err)
	}
	if !policyStageReferences(after, stageRouting, newID) {
		return fmt.Errorf("routing: policy %s still does not reference action %s in the %s stage after attach", policyID, newID, stageRouting)
	}
	return nil
}

// appendStageEnforcement appends an enforcement to the named stage of the
// read-back policy (false when the stage does not exist — never invents one:
// the routing stage is import-minted).
func appendStageEnforcement(policy map[string]any, stageKey, actionID string) bool {
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
		sm["enforcements"] = append(enf, map[string]any{"enforcementObjectId": actionID, "order": nil})
		return true
	}
	return false
}

// outboundAuthAlias extracts the alias value from the nested transportSecurity
// group of an outboundTransportAuthentication action ("" when absent).
func outboundAuthAlias(action map[string]any) string {
	return firstStringValue(transportSecurityParamValues(action, "alias"))
}

// setOutboundAuthAlias overwrites ONLY the alias param inside the nested
// transportSecurity group of the read-back record (other nested params and
// any unknown top-level params survive).
func setOutboundAuthAlias(action map[string]any, value string) {
	params, _ := action["parameters"].([]any)
	for _, p := range params {
		pm, _ := p.(map[string]any)
		if pm == nil {
			continue
		}
		if tk, _ := pm["templateKey"].(string); tk != "transportSecurity" {
			continue
		}
		setActionParamValues(pm, "alias", []any{value})
		return
	}
}

// transportSecurityParamValues returns the values of one param nested inside
// the transportSecurity group (nil when absent).
func transportSecurityParamValues(action map[string]any, key string) []any {
	params, _ := action["parameters"].([]any)
	for _, p := range params {
		pm, _ := p.(map[string]any)
		if pm == nil {
			continue
		}
		if tk, _ := pm["templateKey"].(string); tk != "transportSecurity" {
			continue
		}
		return actionParamValues(pm, key)
	}
	return nil
}

// putPolicyActionGuarded PUTs ONE policy action (ENVELOPED — the naked-body
// 200-no-op trap is exactly why callers must read-back-assert afterwards).
// Observed live: the PUT succeeds with the API ACTIVE; a refusing build gets
// the guarded deactivate -> PUT -> reactivate cycle (never leave the API down).
func (a *Adapter) putPolicyActionGuarded(ctx context.Context, apiID, actionID string, action map[string]any, what string) error {
	action["id"] = actionID
	body := map[string]any{"policyAction": action}
	url := a.adminPath("/policyActions/" + actionID)
	code, raw, err := a.sendJSON(ctx, http.MethodPut, url, body)
	if err != nil {
		return fmt.Errorf("%s (action %s): %w", what, actionID, err)
	}
	if code == http.StatusOK || code == http.StatusCreated {
		return nil
	}

	// Strict build: deactivate ONLY this API, retry, reactivate regardless.
	if derr := a.setAPIActive(ctx, apiID, false); derr != nil {
		return fmt.Errorf("%s: action %s PUT got %d (%s) and deactivate failed: %w", what, actionID, code, truncate(raw, 200), derr)
	}
	retryCode, retryRaw, retryErr := a.sendJSON(ctx, http.MethodPut, url, body)
	if _, aerr := a.ensureActive(ctx, apiID, apiID); aerr != nil {
		return fmt.Errorf("%s: reactivate api %s after action edit: %w", what, apiID, aerr)
	}
	if retryErr != nil {
		return fmt.Errorf("%s (action %s, after deactivate): %w", what, actionID, retryErr)
	}
	if retryCode != http.StatusOK && retryCode != http.StatusCreated {
		return fmt.Errorf("%s (action %s): expected 200/201, got %d: %s", what, actionID, retryCode, truncate(retryRaw, 300))
	}
	return nil
}

// getPolicyAction re-reads ONE action through the list surface (id-keyed).
func (a *Adapter) getPolicyAction(ctx context.Context, actionID string) (map[string]any, error) {
	actions, err := a.listPolicyActions(ctx)
	if err != nil {
		return nil, err
	}
	for _, act := range actions {
		if id, _ := act["id"].(string); id == actionID {
			return act, nil
		}
	}
	return nil, fmt.Errorf("webmethods: policy action %s not found on read-back", actionID)
}

// assertActionParamStuck proves a top-level param of the action persisted —
// the loud failure that turns the silent naked-PUT no-op (200, nothing
// written) into an actionable error.
func (a *Adapter) assertActionParamStuck(ctx context.Context, actionID, key, want string) error {
	act, err := a.getPolicyAction(ctx, actionID)
	if err != nil {
		return fmt.Errorf("routing: read-back action %s: %w", actionID, err)
	}
	if got := firstStringValue(actionParamValues(act, key)); got != want {
		return fmt.Errorf("routing: action %s param %s came back %q, want %q — the PUT did not persist (10.15 answers 200 on a non-enveloped policyAction PUT without writing anything)", actionID, key, got, want)
	}
	return nil
}

// assertOutboundAliasStuck is assertActionParamStuck for the NESTED alias
// param of the outbound transport auth action.
func (a *Adapter) assertOutboundAliasStuck(ctx context.Context, actionID, want string) error {
	act, err := a.getPolicyAction(ctx, actionID)
	if err != nil {
		return fmt.Errorf("routing: read-back action %s: %w", actionID, err)
	}
	if got := outboundAuthAlias(act); got != want {
		return fmt.Errorf("routing: action %s transportSecurity alias came back %q, want %q — the PUT did not persist (10.15 answers 200 on a non-enveloped policyAction PUT without writing anything)", actionID, got, want)
	}
	return nil
}
