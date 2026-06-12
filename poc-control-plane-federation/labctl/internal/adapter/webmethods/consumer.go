package webmethods

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// wmApplication is the webMethods application object under
// /rest/apigateway/applications. Real product keys: id/name/description —
// applications are the product's consumer model (there is no "subscription"
// resource on 10.15).
type wmApplication struct {
	ID            string   `json:"id,omitempty"`
	Name          string   `json:"name"`
	Description   string   `json:"description,omitempty"`
	ContactEmails []string `json:"contactEmails,omitempty"`
}

// wmApplicationsResponse wraps GET /rest/apigateway/applications:
// {"applications":[...]} — an envelope, not a bare array.
type wmApplicationsResponse struct {
	Applications []wmApplication `json:"applications"`
}

// listApplications fetches all applications known to the gateway.
func (a *Adapter) listApplications(ctx context.Context) ([]wmApplication, error) {
	url := a.adminPath("/applications")
	var env wmApplicationsResponse
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &env); err != nil {
		return nil, fmt.Errorf("webmethods list applications: %w", err)
	}
	return env.Applications, nil
}

// findApplication returns an existing application by name (the identity used
// for idempotent re-apply), or false.
func findApplication(apps []wmApplication, name string) (wmApplication, bool) {
	for _, app := range apps {
		if app.Name == name {
			return app, true
		}
	}
	return wmApplication{}, false
}

// CreateConsumer provisions a webMethods APPLICATION and binds it to the
// published API — the real 10.15 consumer model:
//
//  1. RESOLVE: locate the published API by apiName (it must have been
//     published first) — the association call needs its id.
//  2. IDEMPOTENCY: list applications; reuse one with the same name (no
//     duplicate app on re-apply). Otherwise POST /applications
//     {name, description, contactEmails} and capture the id (the response is
//     served flat {"id":...} or as {"applications":[{...}]}).
//  3. ASSOCIATE: PUT /applications/{id}/apis {"apiIDs":[apiId]} — registers
//     the APIs the application may invoke. The PUT replaces the registered
//     set, which converges on re-apply (PoC consumers bind to exactly one API).
//
// The gateway does NOT mint OAuth credentials here: the clientId is
// caller-supplied (minted out-of-band in Keycloak by `labctl subscribe`) and
// REQUIRED — it is recorded in the application description and echoed in
// ConsumerKey so the binding to the Keycloak client stays traceable.
func (a *Adapter) CreateConsumer(ctx context.Context, api *adapter.NormalizedAPI, spec *adapter.ConsumerSpec) (*adapter.ConsumerResult, error) {
	if spec == nil || spec.ClientID == "" {
		return nil, fmt.Errorf("webmethods consumer: clientId is required (mint it in Keycloak first)")
	}
	if spec.Name == "" {
		return nil, fmt.Errorf("webmethods consumer: application name is required")
	}
	appName := sanitizeWMName(spec.Name)

	// 1. Resolve the target api id from the published APIs by name.
	apis, err := a.listAPIs(ctx)
	if err != nil {
		return nil, fmt.Errorf("webmethods consumer: %w", err)
	}
	target, ok := findByName(apis, sanitizeWMName(api.Name))
	if !ok {
		return nil, fmt.Errorf("webmethods consumer: api %q is not published — call Publish first", api.Name)
	}

	// 2. Idempotency: reuse an existing application with the same name.
	apps, err := a.listApplications(ctx)
	if err != nil {
		return nil, fmt.Errorf("webmethods consumer: %w", err)
	}
	appID := ""
	if cur, found := findApplication(apps, appName); found {
		appID = cur.ID
	} else {
		appID, err = a.createApplication(ctx, appName, spec.ClientID)
		if err != nil {
			return nil, fmt.Errorf("webmethods consumer: %w", err)
		}
	}

	// 3. Associate the application with the API (idempotent PUT).
	if err := a.associateAPIs(ctx, appID, target.ID); err != nil {
		return nil, fmt.Errorf("webmethods consumer: associate app %q with api %q: %w", appID, target.ID, err)
	}

	// 4. OAuth2 path only: bind the application to the consumer identity so the
	// strict/oAuth2Token action can RESOLVE the token to THIS application —
	// identifier azp/openIdClaims=[clientId] (the gateway matches the token's azp
	// claim) + authStrategyIds=[strategyId]. No-op on the signature-only path
	// (inbound nil or no audience). Failing here is a real failure: without the
	// identifier a strict lookup would reject the legitimate consumer.
	if a.inbound.oauth2Enabled() {
		if err := a.ensureApplicationOAuthBinding(ctx, appID, spec.ClientID, api.Name); err != nil {
			return nil, fmt.Errorf("webmethods consumer: bind app %q to consumer identity: %w", appID, err)
		}
	}

	// 5. Partner onboarding (ADR-071): project the optional partner identifiers
	// (custom token, IP allowlist, public certificate) onto the application —
	// the identity an admin posts BY HAND today, now as-code. Additive and
	// idempotent: it MERGES with the azp/openIdClaims identifier set above (never
	// clobbers it) and is a no-op when no partner field is declared, so the
	// default consumer is byte-identical to before. Runs AFTER the OAuth2 binding
	// so the read-modify-write sees azp already in place.
	if hasPartnerIdentifiers(spec) {
		if err := a.ensureApplicationIdentifiers(ctx, appID, spec); err != nil {
			return nil, fmt.Errorf("webmethods consumer: project partner identifiers on app %q: %w", appID, err)
		}
	}

	return a.consumerResult(appID, spec.ClientID), nil
}

// ensureApplicationOAuthBinding converges the application's OAuth2 binding for
// the strict/oAuth2Token identification path:
//   - identifiers carries azp/openIdClaims=[clientId] (the gateway maps the
//     token's azp claim to THIS application);
//   - authStrategyIds carries the OAUTH2 strategy id (found by name).
//
// It reads the application back, mutates ONLY these two fields, and PUTs the
// WHOLE record (the PUT replaces the object; consumingAPIs is gateway-preserved,
// like the spike pinned). Idempotent: when both are already in place, no write.
//
// The strategy is created by `labctl apply` (the OAuth2 strategy lives on the
// API/control-plane side). If it is not present yet (subscribe run BEFORE apply)
// the identifier is still set and authStrategyIds is left empty; a later
// subscribe (after apply) converges the strategy binding. The identifier alone
// never weakens the gate — strict still needs BOTH a matching app AND the scope.
func (a *Adapter) ensureApplicationOAuthBinding(ctx context.Context, appID, clientID, apiName string) error {
	app, err := a.getApplication(ctx, appID)
	if err != nil {
		return err
	}
	strategyID, err := a.findStrategyID(ctx, apiName)
	if err != nil {
		return err
	}

	haveIdentifier := appHasAZPIdentifier(app, clientID)
	haveStrategy := strategyID == "" || appHasStrategy(app, strategyID)
	if haveIdentifier && haveStrategy {
		return nil // converged — idempotent no-op
	}

	app["identifiers"] = []any{map[string]any{
		"key":   "openIdClaims",
		"name":  "azp",
		"value": []string{clientID},
	}}
	if strategyID != "" {
		app["authStrategyIds"] = []string{strategyID}
	}

	url := a.adminPath("/applications/" + appID)
	code, raw, err := a.sendJSON(ctx, http.MethodPut, url, app)
	if err != nil {
		return err
	}
	if code != http.StatusOK && code != http.StatusCreated {
		return fmt.Errorf("PUT %s expected 200/201, got %d: %s", url, code, truncate(raw, 300))
	}
	return nil
}

// getApplication reads one application as a raw record so the OAuth2-binding PUT
// can send the WHOLE object back (the PUT replaces the application; fields this
// code does not model — e.g. gateway-enriched accessTokens — must survive). The
// single-record envelope is {"applications":[{...}]}; a flat record is accepted.
func (a *Adapter) getApplication(ctx context.Context, appID string) (map[string]any, error) {
	url := a.adminPath("/applications/" + appID)
	var raw map[string]json.RawMessage
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &raw); err != nil {
		return nil, fmt.Errorf("get application %q: %w", appID, err)
	}
	if inner, ok := raw["applications"]; ok {
		var list []map[string]any
		if err := json.Unmarshal(inner, &list); err == nil && len(list) > 0 {
			return list[0], nil
		}
	}
	flat := make(map[string]any, len(raw))
	for k, v := range raw {
		var val any
		_ = json.Unmarshal(v, &val)
		flat[k] = val
	}
	if _, ok := flat["id"]; ok {
		return flat, nil
	}
	return nil, fmt.Errorf("get application %q: unrecognized response shape", appID)
}

// appHasAZPIdentifier reports whether the application already carries the
// azp/openIdClaims identifier mapping the token's azp to clientID.
func appHasAZPIdentifier(app map[string]any, clientID string) bool {
	ids, _ := app["identifiers"].([]any)
	for _, raw := range ids {
		m, _ := raw.(map[string]any)
		if m == nil {
			continue
		}
		if k, _ := m["key"].(string); k != "openIdClaims" {
			continue
		}
		if n, _ := m["name"].(string); n != "azp" {
			continue
		}
		vals, _ := m["value"].([]any)
		for _, v := range vals {
			if s, _ := v.(string); s == clientID {
				return true
			}
		}
	}
	return false
}

// appHasStrategy reports whether the application already lists strategyID.
func appHasStrategy(app map[string]any, strategyID string) bool {
	ids, _ := app["authStrategyIds"].([]any)
	for _, raw := range ids {
		if s, _ := raw.(string); s == strategyID {
			return true
		}
	}
	return false
}

// findStrategyID returns the per-API OAUTH2 strategy id by derived name
// (strategyName(apiName)), or "" when absent (apply has not created it yet). A
// lookup failure is surfaced; a clean "not found" is "" with no error, so
// subscribe-before-apply still sets the identifier.
func (a *Adapter) findStrategyID(ctx context.Context, apiName string) (string, error) {
	strategies, err := a.listStrategies(ctx)
	if err != nil {
		return "", err
	}
	wantName := strategyName(apiName)
	for _, st := range strategies {
		if st.Name == wantName {
			return st.ID, nil
		}
	}
	return "", nil
}

// createApplication POSTs a new application and extracts its id from either
// the flat or the enveloped response shape.
func (a *Adapter) createApplication(ctx context.Context, appName, clientID string) (string, error) {
	body := map[string]any{
		"name":        appName,
		"description": "labctl consumer (Keycloak clientId " + clientID + ")",
	}
	url := a.adminPath("/applications")
	code, raw, err := a.sendJSON(ctx, http.MethodPost, url, body)
	if err != nil {
		return "", fmt.Errorf("create application %q: %w", appName, err)
	}
	if code != http.StatusCreated && code != http.StatusOK {
		return "", fmt.Errorf("create application %q: expected 200/201, got %d: %s", appName, code, truncate(raw, 300))
	}
	id := parseApplicationID(raw)
	if id == "" {
		return "", fmt.Errorf("create application %q: response carries no id: %s", appName, truncate(raw, 300))
	}
	return id, nil
}

// parseApplicationID extracts the application id from a POST response body —
// flat {"id":...} or enveloped {"applications":[{"id":...}]}.
func parseApplicationID(respBody []byte) string {
	var resp struct {
		ID           string          `json:"id"`
		Applications []wmApplication `json:"applications"`
	}
	if err := json.Unmarshal(respBody, &resp); err != nil {
		return ""
	}
	if resp.ID != "" {
		return resp.ID
	}
	if len(resp.Applications) > 0 {
		return resp.Applications[0].ID
	}
	return ""
}

// associateAPIs registers the API onto the application:
// PUT /applications/{id}/apis {"apiIDs":[...]} (200/201/204 are success).
func (a *Adapter) associateAPIs(ctx context.Context, appID, apiID string) error {
	url := a.adminPath("/applications/" + appID + "/apis")
	code, raw, err := a.sendJSON(ctx, http.MethodPut, url, map[string]any{"apiIDs": []string{apiID}})
	if err != nil {
		return err
	}
	if code != http.StatusOK && code != http.StatusCreated && code != http.StatusNoContent {
		return fmt.Errorf("PUT %s expected 200/201/204, got %d: %s", url, code, truncate(raw, 300))
	}
	return nil
}

// consumerResult builds the uniform ConsumerResult. The application id is the
// gateway-native consumer id; webMethods mints no secret in this flow, so
// ConsumerSecret stays empty and ConsumerKey echoes the Keycloak clientId.
func (a *Adapter) consumerResult(appID, clientID string) *adapter.ConsumerResult {
	return &adapter.ConsumerResult{
		Gateway:        gatewayName,
		ConsumerID:     appID,
		SubscriptionID: appID,
		ConsumerKey:    clientID,
		ConsumerSecret: "",
		TokenHint:      "present the Keycloak bearer for clientId " + clientID + " (application " + appID + " is registered on the API)",
	}
}
