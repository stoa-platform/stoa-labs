package webmethods

// OAuth2 strategy + scope-mapping projection for the REAL apigateway:10.15,
// ported from the live-validated spike (matrix: consumer 200, other client 401,
// missing scope 403/401, forged 401, no token 401). These two gateway objects,
// together with the application identifier/authStrategyIds binding (set in
// CreateConsumer) and the IAM action flipped to strict/oAuth2Token (inboundauth
// .go), turn signature-only auth into a full audience+scope+application barrier:
//
//  1. STRATEGY (POST /rest/apigateway/strategies, NAKED body — no envelope; type
//     UPPERCASE "OAUTH2"; the response is ENVELOPED {"strategy":{"id":...}}).
//     Binds an OAUTH2 strategy to the EXTERNAL alias by NAME (authServerAlias is
//     the alias name, NOT its UUID), pinning clientId + audience. The strategy is
//     what an application's authStrategyIds points at.
//  2. SCOPE MAPPING (POST /rest/apigateway/scopes, NAKED body; list served as
//     {"scopes":[...]}). requiredAuthScopes[].scopeName is the scope the token
//     must carry; apiScopes binds the mapping to the API id; it is enforced ONLY
//     on the strict OAuth2 identification path (identificationType=oAuth2Token,
//     NOT jwtClaims) — hence the action mode flip done in inboundauth.go.
//
// Idempotence: the strategy is found by NAME, the scope by scopeName; both are
// converged in place via PUT when a field drifted, never re-POSTed (a duplicate
// name is an error on 10.15). Re-apply with no drift is a read-only pass.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// strategyName derives the OAUTH2 strategy name from the API name (names are
// the stable strategy identity, like aliases — found by name on re-apply).
// Per-API derivation ("OIDC-<api>") instead of a hardcoded constant so two APIs
// published through the same target never share (and never clobber) one
// strategy. Sanitised like apiName: strategy names are conservative on 10.15.
func strategyName(apiName string) string {
	return "OIDC-" + sanitizeWMName(apiName)
}

// --- strategy --------------------------------------------------------------

// wmStrategy is the OAUTH2 strategy subset the projection reads/writes. Raw is
// the full record so an in-place PUT preserves gateway-enriched fields.
type wmStrategy struct {
	ID   string
	Name string
	Raw  map[string]any
}

// listStrategies fetches /rest/apigateway/strategies. The product serves this
// as a BARE array on 10.15, but also accepts a {"strategies":[...]} envelope on
// some builds — decode both.
func (a *Adapter) listStrategies(ctx context.Context) ([]wmStrategy, error) {
	url := a.adminPath("/strategies")
	var raw json.RawMessage
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &raw); err != nil {
		return nil, fmt.Errorf("inbound auth: list strategies: %w", err)
	}
	items := decodeMaybeEnveloped(raw, "strategies")
	out := make([]wmStrategy, 0, len(items))
	for _, m := range items {
		id, _ := m["id"].(string)
		name, _ := m["name"].(string)
		if id == "" {
			continue
		}
		out = append(out, wmStrategy{ID: id, Name: name, Raw: m})
	}
	return out, nil
}

// strategyDrifted reports whether the existing strategy record diverges from the
// configured (alias, clientId, audience) triple (type stays OAUTH2).
func (a *Adapter) strategyDrifted(raw map[string]any) bool {
	alias, _ := raw["authServerAlias"].(string)
	clientID, _ := raw["clientId"].(string)
	audience, _ := raw["audience"].(string)
	return alias != a.inbound.aliasName ||
		clientID != a.strategyClientID() ||
		audience != a.inbound.audience
}

// strategyClientID is the OAuth clientId the strategy pins: the Keycloak
// consumer clientId. apply does not mint the consumer (that is subscribe), so
// the clientId is projected from the manifest's keycloak.consumerClientId via
// the adapter Options. The strategy + the application identifier (azp ==
// clientId) must agree, which is why both read the SAME configured clientId.
func (a *Adapter) strategyClientID() string {
	return a.inbound.consumerClientID
}

// ensureStrategy converges the OAUTH2 strategy named after the API and returns
// its id:
//   - absent           -> POST a new strategy (NAKED body, ENVELOPED response);
//   - present, drifted -> PUT the read-back record with alias/clientId/audience
//     overwritten (a re-POST of the same name is a duplicate error on 10.15);
//   - present, identical -> no write at all.
func (a *Adapter) ensureStrategy(ctx context.Context, apiName string) (string, error) {
	wantName := strategyName(apiName)
	strategies, err := a.listStrategies(ctx)
	if err != nil {
		return "", err
	}
	for _, st := range strategies {
		if st.Name != wantName {
			continue
		}
		if !a.strategyDrifted(st.Raw) {
			return st.ID, nil // converged — idempotent no-op
		}
		st.Raw["type"] = "OAUTH2"
		st.Raw["authServerAlias"] = a.inbound.aliasName
		st.Raw["clientId"] = a.strategyClientID()
		st.Raw["audience"] = a.inbound.audience
		url := a.adminPath("/strategies/" + st.ID)
		code, raw, perr := a.sendJSON(ctx, http.MethodPut, url, st.Raw)
		if perr != nil {
			return "", fmt.Errorf("inbound auth: update strategy %q: %w", st.Name, perr)
		}
		if code != http.StatusOK && code != http.StatusCreated {
			return "", fmt.Errorf("inbound auth: update strategy %q: expected 200/201, got %d: %s", st.Name, code, truncate(raw, 300))
		}
		return st.ID, nil
	}

	body := map[string]any{
		"name":            wantName,
		"description":     "labctl inbound auth: OIDC OAuth2 strategy (Keycloak)",
		"type":            "OAUTH2",
		"authServerAlias": a.inbound.aliasName,
		"clientId":        a.strategyClientID(),
		"audience":        a.inbound.audience,
	}
	url := a.adminPath("/strategies")
	code, raw, err := a.sendJSON(ctx, http.MethodPost, url, body)
	if err != nil {
		return "", fmt.Errorf("inbound auth: create strategy %q: %w", wantName, err)
	}
	if code != http.StatusCreated && code != http.StatusOK {
		return "", fmt.Errorf("inbound auth: create strategy %q: expected 200/201, got %d: %s", wantName, code, truncate(raw, 300))
	}
	id := parseStrategyID(raw)
	if id == "" {
		return "", fmt.Errorf("inbound auth: create strategy %q: response carries no id: %s", wantName, truncate(raw, 300))
	}
	return id, nil
}

// parseStrategyID extracts the strategy id from a POST response — enveloped
// ({"strategy":{"id":...}}) or flat ({"id":...}).
func parseStrategyID(respBody []byte) string {
	var resp struct {
		Strategy struct {
			ID string `json:"id"`
		} `json:"strategy"`
		ID string `json:"id"`
	}
	if err := json.Unmarshal(respBody, &resp); err != nil {
		return ""
	}
	if resp.Strategy.ID != "" {
		return resp.Strategy.ID
	}
	return resp.ID
}

// --- scope mapping ----------------------------------------------------------

// scopeMappingName is the scope-mapping scopeName. It is alias-qualified
// ("<alias>:<scope>") exactly as the live product stores it, so the lookup is
// stable across re-applies.
func (a *Adapter) scopeMappingName() string {
	return a.inbound.aliasName + ":" + a.inbound.scope
}

// listScopes fetches /rest/apigateway/scopes ({"scopes":[...]} envelope, bare
// array fallback).
func (a *Adapter) listScopes(ctx context.Context) ([]map[string]any, error) {
	url := a.adminPath("/scopes")
	var raw json.RawMessage
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &raw); err != nil {
		return nil, fmt.Errorf("inbound auth: list scopes: %w", err)
	}
	return decodeMaybeEnveloped(raw, "scopes"), nil
}

// scopeBindsAPI reports whether the scope's apiScopes already lists apiID.
func scopeBindsAPI(raw map[string]any, apiID string) bool {
	apiScopes, _ := raw["apiScopes"].([]any)
	for _, s := range apiScopes {
		if id, _ := s.(string); id == apiID {
			return true
		}
	}
	return false
}

// scopeRequiresAuthScope reports whether the scope's requiredAuthScopes already
// gates on (alias, scope).
func (a *Adapter) scopeRequiresAuthScope(raw map[string]any) bool {
	req, _ := raw["requiredAuthScopes"].([]any)
	for _, r := range req {
		rm, _ := r.(map[string]any)
		if rm == nil {
			continue
		}
		alias, _ := rm["authServerAlias"].(string)
		name, _ := rm["scopeName"].(string)
		if alias == a.inbound.aliasName && name == a.inbound.scope {
			return true
		}
	}
	return false
}

// ensureScopeMapping converges the scope mapping for one API:
//   - absent           -> POST a new mapping (NAKED body);
//   - present, drifted (apiScopes missing the API, or requiredAuthScopes missing
//     the (alias,scope) gate, or audience drift) -> PUT the read-back record with
//     those fields converged;
//   - present, identical -> no write.
//
// The mapping is found by scopeName ("<alias>:<scope>"). The API binding is
// ADDED to apiScopes (not replaced), so a scope shared by several APIs is never
// truncated.
func (a *Adapter) ensureScopeMapping(ctx context.Context, apiID string) error {
	scopes, err := a.listScopes(ctx)
	if err != nil {
		return err
	}
	wantName := a.scopeMappingName()
	for _, sc := range scopes {
		if name, _ := sc["scopeName"].(string); name != wantName {
			continue
		}
		id, _ := sc["id"].(string)
		if id == "" {
			return fmt.Errorf("inbound auth: scope mapping %q has no id", wantName)
		}
		audience, _ := sc["audience"].(string)
		if scopeBindsAPI(sc, apiID) && a.scopeRequiresAuthScope(sc) && audience == a.inbound.audience {
			return nil // converged — idempotent no-op
		}
		// Drifted: converge in place. ADD the API binding (preserve others).
		if !scopeBindsAPI(sc, apiID) {
			apiScopes, _ := sc["apiScopes"].([]any)
			sc["apiScopes"] = append(apiScopes, apiID)
		}
		sc["requiredAuthScopes"] = []any{map[string]any{
			"authServerAlias": a.inbound.aliasName,
			"scopeName":       a.inbound.scope,
		}}
		sc["audience"] = a.inbound.audience
		url := a.adminPath("/scopes/" + id)
		code, raw, perr := a.sendJSON(ctx, http.MethodPut, url, sc)
		if perr != nil {
			return fmt.Errorf("inbound auth: update scope mapping %q: %w", wantName, perr)
		}
		if code != http.StatusOK && code != http.StatusCreated {
			return fmt.Errorf("inbound auth: update scope mapping %q: expected 200/201, got %d: %s", wantName, code, truncate(raw, 300))
		}
		return nil
	}

	body := map[string]any{
		"scopeName":        wantName,
		"scopeDescription": "labctl inbound auth: scope mapping for " + a.inbound.scope,
		"audience":         a.inbound.audience,
		"apiScopes":        []string{apiID},
		"requiredAuthScopes": []any{map[string]any{
			"authServerAlias": a.inbound.aliasName,
			"scopeName":       a.inbound.scope,
		}},
	}
	url := a.adminPath("/scopes")
	code, raw, err := a.sendJSON(ctx, http.MethodPost, url, body)
	if err != nil {
		return fmt.Errorf("inbound auth: create scope mapping %q: %w", wantName, err)
	}
	if code != http.StatusCreated && code != http.StatusOK {
		return fmt.Errorf("inbound auth: create scope mapping %q: expected 200/201, got %d: %s", wantName, code, truncate(raw, 300))
	}
	return nil
}

// --- shared helpers --------------------------------------------------------

// decodeMaybeEnveloped decodes a list served either as a bare JSON array or
// wrapped in {"<key>":[...]} (10.15 is inconsistent across resources), into a
// slice of generic records. Unknown shapes decode to an empty slice.
func decodeMaybeEnveloped(raw json.RawMessage, key string) []map[string]any {
	var arr []map[string]any
	if err := json.Unmarshal(raw, &arr); err == nil && arr != nil {
		return arr
	}
	var env map[string]json.RawMessage
	if err := json.Unmarshal(raw, &env); err == nil {
		if inner, ok := env[key]; ok {
			var items []map[string]any
			if err := json.Unmarshal(inner, &items); err == nil {
				return items
			}
		}
	}
	return nil
}
