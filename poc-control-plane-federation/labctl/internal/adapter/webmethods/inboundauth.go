package webmethods

// Inbound JWT/JWKS auth projection for the REAL apigateway:10.15, ported from
// the live-validated spike (matrix 200 with token / 401 without / 401 forged).
// Three gateway objects close the no-auth hole on an imported API:
//
//  1. AUTH-SERVER ALIAS (POST /rest/apigateway/alias, NAKED body — no
//     envelope): an EXTERNAL authorization server with
//     localIntrospectionConfig{issuer, jwksuri}. CRITICAL split-horizon: the
//     issuer must equal the token's iss claim EXACTLY (host-pinned Keycloak
//     URL), while jwksuri must be reachable FROM THE GATEWAY CONTAINER
//     (docker-internal name). "jwksuri" is all-lowercase on 10.15.
//  2. IDENTIFY & AUTHORIZE ACTION (POST /rest/apigateway/policyActions,
//     ENVELOPED body {"policyAction":{...}}): templateKey "evaluatePolicy"
//     (NOT identifyAndAuthorize), identificationType "jwtClaims",
//     allowAnonymous=false, applicationLookup=open (a VALID JWT not mapped to
//     an application passes as sys:defaultApplication; absent/forged -> 401).
//     The product NORMALISES the action display name (custom names come back
//     as "Identify & Authorize"), so nothing here matches actions by name —
//     reuse keys on templateKey + identificationType instead.
//  3. POLICY ATTACH (PUT /rest/apigateway/policies/{id}, ENVELOPED body
//     {"policy":{...}}): add an "IAM" stage (UPPERCASE, unlike
//     transport/routing) referencing the action. The PUT REPLACES
//     policyEnforcements wholesale, so the existing stages must be re-listed
//     — which is why the code mutates the policy READ BACK from the gateway
//     instead of composing one from scratch. Observed live: the PUT succeeds
//     with the API ACTIVE (no deactivation, no restart, effect immediate);
//     a deactivate -> PUT -> reactivate fallback covers builds that refuse.
//
// Idempotence: the alias is found by name (alias names ARE stable) and
// converged in place; the action is found by its template fingerprint; the
// policy is only PUT when the IAM stage is missing. Re-apply is a read-only
// pass.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// defaultInboundAliasName is the auth-server alias name used when the
// manifest's inboundAuth block does not pin one. Alphanumeric only — alias
// names on 10.15 are conservative about special characters.
const defaultInboundAliasName = "LabctlInboundJWT"

// inboundActionName is the display name POSTed with the Identify & Authorize
// action. Documentation only: the product normalises it (it comes back as
// "Identify & Authorize"), so the code NEVER matches actions by name.
const inboundActionName = "Identify & Authorize JWT (labctl)"

// stageIAM is the policy stage carrying Identify & Authorize enforcements.
// UPPERCASE on the real product (transport/routing are lowercase).
const stageIAM = "IAM"

// inboundAuthConfig is the parsed inboundAuth manifest block.
type inboundAuthConfig struct {
	issuer    string // EXACT iss claim of the tokens to accept
	jwksURI   string // JWKS endpoint reachable FROM the gateway container
	aliasName string // gateway-side auth-server alias name

	// audience + scope switch on the FULL OAuth2 path (strategy + application
	// identifier + scope mapping + applicationLookup strict / oAuth2Token).
	// Both empty => signature-only path (applicationLookup open, jwtClaims), the
	// historical behavior. audience non-empty REQUIRES scope (the OAuth2 path
	// always enforces a scope) — fail closed at construction.
	audience string // OAuth2 audience (strategy.audience + scope.audience == aud claim)
	scope    string // OAuth scope required on the token (requiredAuthScopes[].scopeName)

	// consumerClientID is the Keycloak OAuth clientId the strategy is bound to
	// and the value the application identifier matches the token's azp against.
	// Equals keycloak.consumerClientId; required on the OAuth2 path.
	consumerClientID string

	// introspectionEndpoint, when non-empty, switches the alias from OFFLINE
	// JWKS validation (localIntrospectionConfig — never enforces aud) to REMOTE
	// RFC 7662 introspection (remoteIntrospectionConfig). Under remote the
	// authorization server returns active/aud/azp/scope per request and the
	// gateway resource-server path checks aud against strategy.audience, making
	// the audience the 4th barrier. Like jwksURI it must be reachable FROM the
	// gateway container (keycloak:8080, not the host-pinned issuer). The local
	// block is kept as a signature fallback; remote takes precedence when its
	// endpoint is non-empty. introspectionClientID/Secret are the gateway's OWN
	// confidential client (distinct from consumerClientID), defaulted upstream to
	// poc-gateways / poc-gateways-secret.
	introspectionEndpoint     string
	introspectionClientID     string
	introspectionClientSecret string

	// introspectionUser is the API Gateway user the remote introspection call
	// runs as. REQUIRED by the 10.15 AuthServerAliasValidator: a remote block
	// without it is rejected at PUT/POST with `Field "Remote introspection >
	// Gateway user" is empty` (observed live). Defaults to the admin username
	// (the Basic-auth principal already configured), so the manifest need not
	// repeat it.
	introspectionUser string
}

// remoteIntrospectionEnabled reports whether the manifest asked to enforce the
// audience via remote RFC 7662 introspection (an endpoint is set), rather than
// the offline JWKS path that never checks aud.
//
// LIVE FINDING (apigateway-trial:10.15, 2026-06-11): filling
// remoteIntrospectionConfig does NOT make the audience a barrier on this build.
// The OAuth2TokenValidator short-circuits to the local JWKS path whenever
// localIntrospectionConfig is present ("validate locally OR remotely if not
// possible locally" — and local is always possible here), so the remote block
// is INERT: proven by pointing introspectionEndpoint at a dead host while JWKS
// works -> a valid token still returns 200 (the remote call is never made).
// Removing localIntrospectionConfig to force the remote path breaks token
// validation entirely (no signature anchor -> every token, even valid, 401).
// Net: the audience stays a best-effort, fail-OPEN check on this build (a valid
// token whose aud lacks the strategy audience returns 200). The remote block is
// still projected (issuer/scope/azp barriers remain 3/4) and the knobs are kept
// so a non-trial build that honours remote introspection enforces aud without a
// code change — but DO NOT claim the 4th (audience) barrier on this trial.
func (c *inboundAuthConfig) remoteIntrospectionEnabled() bool {
	return c != nil && c.introspectionEndpoint != ""
}

// oauth2Enabled reports whether the manifest asked for the full OAuth2
// projection (audience binding + scope gate + application identification),
// rather than the signature-only path.
func (c *inboundAuthConfig) oauth2Enabled() bool {
	return c != nil && c.audience != ""
}

// inboundAuthFromConfig projects the generic adapter Config onto the inbound
// auth knobs. Absent block -> nil (feature off, current behavior unchanged).
// A half-filled block is a config bug surfaced at construction (fail closed,
// like missing Basic credentials).
func inboundAuthFromConfig(cfg adapter.Config) (*inboundAuthConfig, error) {
	issuer := cfg.Opt("inboundAuthIssuer", "")
	jwks := cfg.Opt("inboundAuthJwksUri", "")
	audience := cfg.Opt("inboundAuthAudience", "")
	scope := cfg.Opt("inboundAuthScope", "")
	clientID := cfg.Opt("inboundAuthClientId", "")
	introspectionEndpoint := cfg.Opt("inboundAuthIntrospectionEndpoint", "")
	introspectionClientID := cfg.Opt("inboundAuthIntrospectionClientId", "")
	introspectionClientSecret := cfg.Opt("inboundAuthIntrospectionClientSecret", "")
	// The Gateway user the introspection call runs as. REQUIRED by 10.15; default
	// to the Basic-auth admin username already configured on the adapter.
	introspectionUser := cfg.Opt("inboundAuthIntrospectionUser", cfg.Cred("username", ""))
	if issuer == "" && jwks == "" {
		return nil, nil
	}
	if issuer == "" || jwks == "" {
		return nil, fmt.Errorf("webmethods: inboundAuth needs both issuer and jwksUri (got issuer=%q jwksUri=%q)", issuer, jwks)
	}
	// OAuth2 path: audience without scope is a half-open barrier (a token with
	// the right aud but no scope would pass). Fail closed, like a half-filled
	// issuer/jwks pair. The clientId binds the strategy + application identifier
	// to the consumer identity; it cannot be empty on the OAuth2 path.
	if audience != "" {
		if scope == "" {
			return nil, fmt.Errorf("webmethods: inboundAuth has audience but no scope (the OAuth2 path enforces a scope; set inboundAuth.scope)")
		}
		if clientID == "" {
			return nil, fmt.Errorf("webmethods: inboundAuth has audience but no clientId (set inboundAuth.clientId or keycloak.consumerClientId so the OAuth2 strategy can bind the consumer)")
		}
	}
	// Remote introspection only enforces aud on the OAuth2 path; an endpoint
	// without an audience to enforce is a config mistake (fail closed), and an
	// endpoint without its gateway client credential cannot authenticate the
	// RFC 7662 call (the upstream Load defaults poc-gateways / poc-gateways-secret;
	// guard here too for adapters constructed directly).
	if introspectionEndpoint != "" {
		if audience == "" {
			return nil, fmt.Errorf("webmethods: inboundAuth has introspectionEndpoint but no audience (remote introspection only enforces aud on the OAuth2 path; set inboundAuth.audience)")
		}
		if introspectionClientID == "" || introspectionClientSecret == "" {
			return nil, fmt.Errorf("webmethods: inboundAuth has introspectionEndpoint but no introspectionClientId/Secret (the gateway needs a confidential client to call the RFC 7662 endpoint; got clientId=%q secret-set=%t)", introspectionClientID, introspectionClientSecret != "")
		}
		// 10.15 rejects a remote block without a Gateway user; default it from the
		// Basic-auth username above, fail closed if even that is empty. In BEARER
		// token mode there is no Basic username to default from, so the manifest
		// must name the Gateway user explicitly.
		if introspectionUser == "" {
			return nil, fmt.Errorf("webmethods: inboundAuth has introspectionEndpoint but no introspectionUser, and no Basic-auth username to default from (bearer-token mode has none) — set inboundAuth.introspectionUser (10.15 requires a Gateway user on the remote introspection block)")
		}
	}
	return &inboundAuthConfig{
		issuer:                    issuer,
		jwksURI:                   jwks,
		aliasName:                 cfg.Opt("inboundAuthAliasName", defaultInboundAliasName),
		audience:                  audience,
		scope:                     scope,
		consumerClientID:          clientID,
		introspectionEndpoint:     introspectionEndpoint,
		introspectionClientID:     introspectionClientID,
		introspectionClientSecret: introspectionClientSecret,
		introspectionUser:         introspectionUser,
	}, nil
}

// ensureInboundAuth converges the gateway onto the manifest's inboundAuth
// block for one published API: alias present and pointing at the configured
// issuer+JWKS, Identify & Authorize action present, IAM stage attached to the
// API's service policy. nil receiver config = no-op (zero extra calls).
//
// When the manifest carries an audience (OAuth2 path) the projection also
// converges the OAuth2 objects that turn signature-only auth into a full
// audience+scope+application barrier: an OAUTH2 strategy, a scope mapping on
// the API, and an Identify & Authorize action in applicationLookup=strict /
// identificationType=oAuth2Token mode (the live-validated config). The
// application identifier (azp/openIdClaims) + authStrategyIds binding lives in
// `labctl subscribe` (CreateConsumer), because the consumer's clientId is only
// known there. apiName seeds the per-API strategy name (see strategyName).
func (a *Adapter) ensureInboundAuth(ctx context.Context, apiID, apiName string) error {
	if a.inbound == nil {
		return nil
	}

	// 1. Trust anchor: the EXTERNAL auth-server alias (issuer + JWKS).
	if err := a.ensureAuthServerAlias(ctx); err != nil {
		return err
	}

	// 2. OAuth2 path only: the strategy (OAUTH2/audience/clientId/alias) and the
	// scope mapping (requiredAuthScopes + apiScopes[apiId]) must exist BEFORE the
	// action flips to strict/oAuth2Token, so the gate is never half-open. No-op
	// on the signature-only path (audience empty).
	if a.inbound.oauth2Enabled() {
		if _, err := a.ensureStrategy(ctx, apiName); err != nil {
			return err
		}
		if err := a.ensureScopeMapping(ctx, apiID); err != nil {
			return err
		}
	}

	// 3. Locate the API's service policy (the record lists its policy ids;
	// re-read AFTER import/update because a re-import may swap the policy).
	rec, err := a.getAPI(ctx, apiID)
	if err != nil {
		return fmt.Errorf("inbound auth: %w", err)
	}
	policyID, policy, err := a.findServicePolicy(ctx, rec.Policies)
	if err != nil {
		return err
	}

	// 4. Materialise the Identify & Authorize action in the configured mode and
	// reconcile the IAM stage to reference IT. The action is converged in place
	// (a pre-existing signature-only action is PUT to strict/oAuth2Token), so
	// this is NOT gated on "stage already present": a manifest that turns on the
	// OAuth2 path must re-point an API that already had the signature-only stage.
	actionID, err := a.ensureIdentifyAction(ctx)
	if err != nil {
		return err
	}

	// 5. Idempotence gate: the IAM stage already references the desired action
	// -> nothing to write (re-apply is a read-only pass once converged).
	if policyIAMReferences(policy, actionID) {
		return nil
	}

	// 6. Attach (or re-point) the IAM stage and prove it stuck.
	if err := a.attachIAMStage(ctx, apiID, policyID, policy, actionID); err != nil {
		return err
	}
	after, err := a.getPolicy(ctx, policyID)
	if err != nil {
		return fmt.Errorf("inbound auth: read-back after attach: %w", err)
	}
	if !policyIAMReferences(after, actionID) {
		return fmt.Errorf("inbound auth: policy %s still does not reference action %s in the %s stage after attach", policyID, actionID, stageIAM)
	}
	return nil
}

// --- alias --------------------------------------------------------------

// wmAlias is the auth-server alias subset the projection reads and writes.
// Raw is the full record as served, kept so updates can PUT the whole object
// back (preserving gateway-enriched fields like scopes/metadata) instead of
// composing a lossy one.
type wmAlias struct {
	ID   string
	Name string
	Raw  map[string]any
}

// listAliases fetches /rest/apigateway/alias and decodes the {"alias":[...]}
// envelope into the generic record shape. Shared by the inbound-auth projection
// (authServerAlias) AND the routing projection (endpoint/credential aliases) —
// the surface serves ALL alias types in one list.
func (a *Adapter) listAliases(ctx context.Context) ([]wmAlias, error) {
	url := a.adminPath("/alias")
	var env struct {
		Alias []map[string]any `json:"alias"`
	}
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &env); err != nil {
		return nil, fmt.Errorf("webmethods: list aliases: %w", err)
	}
	out := make([]wmAlias, 0, len(env.Alias))
	for _, raw := range env.Alias {
		id, _ := raw["id"].(string)
		name, _ := raw["name"].(string)
		if id == "" {
			continue
		}
		out = append(out, wmAlias{ID: id, Name: name, Raw: raw})
	}
	return out, nil
}

// aliasIntrospection extracts (issuer, jwksuri) from an alias record.
func aliasIntrospection(raw map[string]any) (string, string) {
	cfg, _ := raw["localIntrospectionConfig"].(map[string]any)
	if cfg == nil {
		return "", ""
	}
	issuer, _ := cfg["issuer"].(string)
	jwks, _ := cfg["jwksuri"].(string)
	return issuer, jwks
}

// aliasRemoteIntrospection extracts (introspectionEndpoint, clientId) from an
// alias's remoteIntrospectionConfig block. The clientSecret is DELIBERATELY not
// returned: the alias implements MaskableEntity, so the secret comes back as
// "***" on a GET — comparing it would force a spurious PUT on every apply (or,
// worse, write "***" as the real secret). Drift is keyed on endpoint+clientId
// only; the secret is always re-emitted on the PUT body. An empty endpoint
// (block absent, the current live state) means the alias is on the offline
// JWKS path.
func aliasRemoteIntrospection(raw map[string]any) (string, string) {
	cfg, _ := raw["remoteIntrospectionConfig"].(map[string]any)
	if cfg == nil {
		return "", ""
	}
	endpoint, _ := cfg["introspectionEndpoint"].(string)
	clientID, _ := cfg["clientId"].(string)
	return endpoint, clientID
}

// remoteIntrospectionBody builds the remoteIntrospectionConfig block to write.
// The clientSecret is sent IN CLEAR on every write (GatewaySecret accepts a
// string and masks it on read-back), so the gateway always has the real secret
// even though drift never compares it.
func (a *Adapter) remoteIntrospectionBody() map[string]any {
	return map[string]any{
		"introspectionEndpoint": a.inbound.introspectionEndpoint,
		"clientId":              a.inbound.introspectionClientID,
		"clientSecret":          a.inbound.introspectionClientSecret,
		"user":                  a.inbound.introspectionUser,
	}
}

// ensureAuthServerAlias finds the alias by NAME (the only alias identity that
// is stable across re-applies) and converges it:
//   - absent             -> POST a new EXTERNAL alias (NAKED body, 201);
//   - present, drifted   -> PUT the read-back record with issuer/jwksuri
//     overwritten (a re-POST of the same name is a duplicate error on 10.15);
//   - present, identical -> no write at all.
func (a *Adapter) ensureAuthServerAlias(ctx context.Context) error {
	aliases, err := a.listAliases(ctx)
	if err != nil {
		return err
	}
	for _, al := range aliases {
		if al.Name != a.inbound.aliasName {
			continue
		}
		issuer, jwks := aliasIntrospection(al.Raw)
		localConverged := issuer == a.inbound.issuer && jwks == a.inbound.jwksURI
		// Remote drift: keyed on endpoint+clientId only (the secret is masked on
		// read — see aliasRemoteIntrospection). When remote is OFF in the manifest
		// the remote block is considered converged regardless of what is stored
		// (this projection never removes a remote block it did not ask for).
		remoteConverged := true
		if a.inbound.remoteIntrospectionEnabled() {
			gotEndpoint, gotClientID := aliasRemoteIntrospection(al.Raw)
			remoteConverged = gotEndpoint == a.inbound.introspectionEndpoint &&
				gotClientID == a.inbound.introspectionClientID
		}
		if localConverged && remoteConverged {
			return nil // converged — idempotent no-op
		}
		// Drifted: overwrite ONLY the introspection blocks on the full record,
		// preserving every gateway-enriched field (scopes/owner/...). The local
		// block is kept (signature fallback); the remote block is added/refreshed
		// when the manifest enables remote introspection (the secret is always
		// re-emitted because the read-back value is masked).
		cfg, _ := al.Raw["localIntrospectionConfig"].(map[string]any)
		if cfg == nil {
			cfg = map[string]any{}
		}
		cfg["issuer"] = a.inbound.issuer
		cfg["jwksuri"] = a.inbound.jwksURI
		al.Raw["localIntrospectionConfig"] = cfg
		if a.inbound.remoteIntrospectionEnabled() {
			al.Raw["remoteIntrospectionConfig"] = a.remoteIntrospectionBody()
		}
		url := a.adminPath("/alias/" + al.ID)
		code, raw, err := a.sendJSON(ctx, http.MethodPut, url, al.Raw)
		if err != nil {
			return fmt.Errorf("inbound auth: update alias %q: %w", al.Name, err)
		}
		if code != http.StatusOK && code != http.StatusCreated {
			return fmt.Errorf("inbound auth: update alias %q: expected 200/201, got %d: %s", al.Name, code, truncate(raw, 300))
		}
		return a.assertRemoteIntrospectionStuck(ctx, al.ID, al.Name)
	}

	// Absent: create. The body is NAKED (no {"alias":...} wrapper) — one of
	// the 10.15 envelope inconsistencies the spike pinned down. When the manifest
	// enables remote introspection both blocks are emitted: remote (enforces aud)
	// + local (signature fallback if the AS is unreachable).
	body := map[string]any{
		"name":           a.inbound.aliasName,
		"description":    "labctl inbound auth: external authorization server (JWKS local introspection)",
		"type":           "authServerAlias",
		"authServerType": "EXTERNAL",
		"localIntrospectionConfig": map[string]any{
			"issuer":  a.inbound.issuer,
			"jwksuri": a.inbound.jwksURI,
		},
	}
	if a.inbound.remoteIntrospectionEnabled() {
		body["remoteIntrospectionConfig"] = a.remoteIntrospectionBody()
	}
	url := a.adminPath("/alias")
	code, raw, err := a.sendJSON(ctx, http.MethodPost, url, body)
	if err != nil {
		return fmt.Errorf("inbound auth: create alias %q: %w", a.inbound.aliasName, err)
	}
	if code != http.StatusCreated && code != http.StatusOK {
		return fmt.Errorf("inbound auth: create alias %q: expected 200/201, got %d: %s", a.inbound.aliasName, code, truncate(raw, 300))
	}
	id := parseAliasID(raw)
	if id == "" {
		// The POST response may not echo an id on every build; fall back to a
		// name lookup so the read-back assertion still runs.
		id = a.lookupAliasID(ctx, a.inbound.aliasName)
	}
	return a.assertRemoteIntrospectionStuck(ctx, id, a.inbound.aliasName)
}

// parseAliasID extracts the alias id from a POST response (enveloped
// {"alias":{"id":...}} or flat {"id":...}).
func parseAliasID(respBody []byte) string {
	var resp struct {
		Alias struct {
			ID string `json:"id"`
		} `json:"alias"`
		ID string `json:"id"`
	}
	if err := json.Unmarshal(respBody, &resp); err != nil {
		return ""
	}
	if resp.Alias.ID != "" {
		return resp.Alias.ID
	}
	return resp.ID
}

// lookupAliasID re-lists aliases and returns the id of the named one ("" if not
// found). Used only as a fallback when a POST response carries no id.
func (a *Adapter) lookupAliasID(ctx context.Context, name string) string {
	aliases, err := a.listAliases(ctx)
	if err != nil {
		return ""
	}
	for _, al := range aliases {
		if al.Name == name {
			return al.ID
		}
	}
	return ""
}

// assertRemoteIntrospectionStuck GETs the alias and proves the
// remoteIntrospectionConfig.introspectionEndpoint we wrote came back non-empty.
// The gateway emits ONLY populated blocks, so a field name the build does not
// recognise (the 10.x introspectionEndpoint vs introspectionEndPoint trap) is
// dropped silently and the block returns null — which would leave the alias on
// the offline JWKS path with NO error from the PUT. This read-back turns that
// silent failure into a loud one. No-op when the manifest does not enable
// remote introspection.
func (a *Adapter) assertRemoteIntrospectionStuck(ctx context.Context, aliasID, aliasName string) error {
	if !a.inbound.remoteIntrospectionEnabled() || aliasID == "" {
		return nil
	}
	url := a.adminPath("/alias/" + aliasID)
	var raw map[string]any
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &raw); err != nil {
		return fmt.Errorf("inbound auth: read-back alias %q for remote-introspection check: %w", aliasName, err)
	}
	rec := raw
	if al, ok := raw["alias"].(map[string]any); ok && al != nil {
		rec = al
	}
	endpoint, _ := aliasRemoteIntrospection(rec)
	if endpoint == "" {
		return fmt.Errorf("inbound auth: alias %q remoteIntrospectionConfig.introspectionEndpoint came back empty after write — the field name was likely rejected by this build (check introspectionEndpoint vs introspectionEndPoint); the alias is STILL on the offline JWKS path and the audience is NOT enforced", aliasName)
	}
	return nil
}

// --- Identify & Authorize action -----------------------------------------

// listPolicyActions fetches /rest/apigateway/policyActions and decodes the
// {"policyAction":[...]} envelope (singular key, list value) into raw records.
// Shared by the inbound-auth and routing projections (the surface lists ALL
// action templates, straightThroughRouting included).
func (a *Adapter) listPolicyActions(ctx context.Context) ([]map[string]any, error) {
	url := a.adminPath("/policyActions")
	var env struct {
		PolicyAction []map[string]any `json:"policyAction"`
	}
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &env); err != nil {
		return nil, fmt.Errorf("webmethods: list policy actions: %w", err)
	}
	return env.PolicyAction, nil
}

// identifyActionMode is the (applicationLookup, identificationType) pair the
// IAM action enforces. Signature-only auth uses (open, jwtClaims); the full
// OAuth2 path uses (strict, oAuth2Token) — the live-validated config that
// closes the sys:defaultApplication hole and consumes the application
// identifier + scope mapping.
//
// LIVE NOTE (apigateway-trial:10.15, 2026-06-11): the OAuth2 IAM action runs as
// identificationType=oAuth2Token, NOT openIdClaims. The product treats the
// bearer access token as the identification material on the strict path (the
// gateway resolves the token -> application via the OAUTH2 strategy + the
// azp/openIdClaims application identifier, see consumer.go). The application
// identifier KEY stays "openIdClaims" (that is the identifier dimension the
// strategy maps azp on), but the ACTION's identificationType is oAuth2Token.
// This is consistent with the OAUTH2 strategy: the scope is still imposed and
// the strict/application lookup still closes the sys:defaultApplication hole —
// no regression versus the prior openIdClaims action mode.
type identifyActionMode struct {
	applicationLookup  string
	identificationType string
}

// wantMode returns the action mode this manifest configures.
func (a *Adapter) wantMode() identifyActionMode {
	if a.inbound.oauth2Enabled() {
		return identifyActionMode{applicationLookup: "strict", identificationType: "oAuth2Token"}
	}
	return identifyActionMode{applicationLookup: "open", identificationType: "jwtClaims"}
}

// identificationType extracts the action's identificationType value, "" if absent.
func identificationType(action map[string]any) string {
	for _, p := range nestedRuleParams(action) {
		if tk, _ := p["templateKey"].(string); tk == "identificationType" {
			if values, _ := p["values"].([]any); len(values) > 0 {
				s, _ := values[0].(string)
				return s
			}
		}
	}
	return ""
}

// nestedRuleParams returns the IdentificationRule's nested parameter records
// of an evaluatePolicy action ([] when not that template / no rule).
func nestedRuleParams(action map[string]any) []map[string]any {
	if tk, _ := action["templateKey"].(string); tk != "evaluatePolicy" {
		return nil
	}
	params, _ := action["parameters"].([]any)
	for _, p := range params {
		pm, _ := p.(map[string]any)
		if pm == nil {
			continue
		}
		if tk, _ := pm["templateKey"].(string); tk != "IdentificationRule" {
			continue
		}
		nested, _ := pm["parameters"].([]any)
		out := make([]map[string]any, 0, len(nested))
		for _, n := range nested {
			if nm, _ := n.(map[string]any); nm != nil {
				out = append(out, nm)
			}
		}
		return out
	}
	return nil
}

// isIdentifyAction reports whether an action record is an Identify & Authorize
// action (evaluatePolicy carrying an IdentificationRule with a known
// identificationType — jwtClaims, openIdClaims OR oAuth2Token). Display names
// are deliberately ignored (the product normalises them). This matches the
// action REGARDLESS of mode, so the projection finds (and converges) a
// signature-only OR a legacy openIdClaims action when the manifest now asks for
// the oAuth2Token OAuth2 path, and vice versa.
func isIdentifyAction(action map[string]any) bool {
	switch identificationType(action) {
	case "jwtClaims", "openIdClaims", "oAuth2Token":
		return true
	}
	return false
}

// actionInMode reports whether the action is already in the desired mode (no
// PUT needed).
func actionInMode(action map[string]any, mode identifyActionMode) bool {
	lookup, idType := "", ""
	for _, p := range nestedRuleParams(action) {
		tk, _ := p["templateKey"].(string)
		values, _ := p["values"].([]any)
		if len(values) == 0 {
			continue
		}
		s, _ := values[0].(string)
		switch tk {
		case "applicationLookup":
			lookup = s
		case "identificationType":
			idType = s
		}
	}
	return lookup == mode.applicationLookup && idType == mode.identificationType
}

// identifyActionBody builds the ENVELOPED policyAction body for a given mode.
// id is set on a PUT (converge in place) and empty on a POST (create).
func identifyActionBody(id string, mode identifyActionMode) map[string]any {
	action := map[string]any{
		"names":       []any{map[string]any{"value": inboundActionName, "locale": "en"}},
		"templateKey": "evaluatePolicy",
		"parameters": []any{
			map[string]any{"templateKey": "logicalConnector", "values": []any{"OR"}},
			map[string]any{"templateKey": "allowAnonymous", "values": []any{"false"}},
			map[string]any{
				"templateKey": "IdentificationRule",
				"parameters": []any{
					map[string]any{"templateKey": "applicationLookup", "values": []any{mode.applicationLookup}},
					map[string]any{"templateKey": "identificationType", "values": []any{mode.identificationType}},
				},
			},
		},
		"active": true,
	}
	if id != "" {
		action["id"] = id
	}
	return map[string]any{"policyAction": action}
}

// ensureIdentifyAction converges the Identify & Authorize action to the mode
// the manifest configures and returns its id:
//   - no Identify action present  -> POST one (ENVELOPED body, the live payload);
//   - present, already in mode     -> reuse, no write;
//   - present, wrong mode          -> PUT it in place to the desired mode (a LIVE
//     edit; effect is immediate on the active API — NO deactivate/activate cycle,
//     which on the real 10.15 risks a JVM restart).
//
// Converging in place (rather than creating a second action) keeps one shared
// Identify & Authorize action and lets a manifest flip an API between
// signature-only and the full OAuth2 path without orphaning the old action.
func (a *Adapter) ensureIdentifyAction(ctx context.Context) (string, error) {
	actions, err := a.listPolicyActions(ctx)
	if err != nil {
		return "", err
	}
	mode := a.wantMode()
	for _, act := range actions {
		if !isIdentifyAction(act) {
			continue
		}
		id, _ := act["id"].(string)
		if id == "" {
			continue
		}
		if actionInMode(act, mode) {
			return id, nil // converged — idempotent no-op
		}
		// Wrong mode: PUT it to the desired one (live edit, immediate effect).
		url := a.adminPath("/policyActions/" + id)
		code, raw, perr := a.sendJSON(ctx, http.MethodPut, url, identifyActionBody(id, mode))
		if perr != nil {
			return "", fmt.Errorf("inbound auth: converge policy action %s to %s/%s: %w", id, mode.applicationLookup, mode.identificationType, perr)
		}
		if code != http.StatusOK && code != http.StatusCreated {
			return "", fmt.Errorf("inbound auth: converge policy action %s: expected 200/201, got %d: %s", id, code, truncate(raw, 300))
		}
		return id, nil
	}

	url := a.adminPath("/policyActions")
	code, raw, err := a.sendJSON(ctx, http.MethodPost, url, identifyActionBody("", mode))
	if err != nil {
		return "", fmt.Errorf("inbound auth: create policy action: %w", err)
	}
	if code != http.StatusCreated && code != http.StatusOK {
		return "", fmt.Errorf("inbound auth: create policy action: expected 200/201, got %d: %s", code, truncate(raw, 300))
	}
	id := parsePolicyActionID(raw)
	if id == "" {
		return "", fmt.Errorf("inbound auth: create policy action: response carries no id: %s", truncate(raw, 300))
	}
	return id, nil
}

// parsePolicyActionID extracts the action id from a POST response — enveloped
// ({"policyAction":{"id":...}}) or flat ({"id":...}).
func parsePolicyActionID(respBody []byte) string {
	var resp struct {
		PolicyAction struct {
			ID string `json:"id"`
		} `json:"policyAction"`
		ID string `json:"id"`
	}
	if err := json.Unmarshal(respBody, &resp); err != nil {
		return ""
	}
	if resp.PolicyAction.ID != "" {
		return resp.PolicyAction.ID
	}
	return resp.ID
}

// --- policy ----------------------------------------------------------------

// getPolicy reads one policy as a raw record ({"policy":{...}} envelope, flat
// fallback). Raw map and not a struct: the attach PUT must send the WHOLE
// object back, including fields this code does not model.
func (a *Adapter) getPolicy(ctx context.Context, policyID string) (map[string]any, error) {
	url := a.adminPath("/policies/" + policyID)
	var raw map[string]any
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &raw); err != nil {
		return nil, fmt.Errorf("webmethods: get policy %s: %w", policyID, err)
	}
	if pol, ok := raw["policy"].(map[string]any); ok && pol != nil {
		return pol, nil
	}
	if _, ok := raw["id"]; ok {
		return raw, nil // flat record fallback
	}
	return nil, fmt.Errorf("webmethods: get policy %s: unrecognized response shape", policyID)
}

// findServicePolicy resolves which of the API's policies carries the
// enforcement stages: the SERVICE-scoped one (an imported API gets exactly one
// "Default Policy for API <name>"), falling back to the first when no scope
// matches. Returns (id, raw record).
func (a *Adapter) findServicePolicy(ctx context.Context, policyIDs []string) (string, map[string]any, error) {
	if len(policyIDs) == 0 {
		return "", nil, fmt.Errorf("webmethods: api record lists no policies (cannot converge policy stages)")
	}
	var firstID string
	var first map[string]any
	for _, id := range policyIDs {
		pol, err := a.getPolicy(ctx, id)
		if err != nil {
			return "", nil, err
		}
		if first == nil {
			firstID, first = id, pol
		}
		if scope, _ := pol["policyScope"].(string); scope == "SERVICE" {
			return id, pol, nil
		}
	}
	return firstID, first, nil
}

// policyIAMReferences reports whether the policy's IAM stage already enforces
// exactly the given action id (the idempotence gate: present AND pointing at
// the desired action means inbound auth is in place in the configured mode).
func policyIAMReferences(policy map[string]any, actionID string) bool {
	return policyStageReferences(policy, stageIAM, actionID)
}

// policyStageReferences reports whether the named stage of the policy carries
// an enforcement pointing at actionID. Shared idempotence gate for the IAM
// (inbound auth) and routing (outbound transport auth) stage attachments.
func policyStageReferences(policy map[string]any, stageKey, actionID string) bool {
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
				if id, _ := em["enforcementObjectId"].(string); id == actionID {
					return true
				}
			}
		}
		return false
	}
	return false
}

// injectIAMStage sets the IAM stage to reference exactly actionID. If an IAM
// stage already exists (e.g. a signature-only action being re-pointed at the
// OAuth2 action), it is REPLACED in place rather than duplicated; otherwise the
// stage is inserted BEFORE the routing stage to mirror the live-validated stage
// order (transport, IAM, routing), appended when no routing stage exists. The
// slice is mutated on the read-back record so the wholesale-replacing PUT keeps
// every existing stage.
func injectIAMStage(policy map[string]any, actionID string) {
	stage := map[string]any{
		"stageKey": stageIAM,
		"enforcements": []any{
			map[string]any{"enforcementObjectId": actionID, "order": nil},
		},
	}
	stages, _ := policy["policyEnforcements"].([]any)

	// Replace an existing IAM stage in place (re-point), preserving order.
	for i, s := range stages {
		if sm, _ := s.(map[string]any); sm != nil {
			if key, _ := sm["stageKey"].(string); key == stageIAM {
				stages[i] = stage
				policy["policyEnforcements"] = stages
				return
			}
		}
	}

	// No IAM stage yet: insert before routing (or append).
	out := make([]any, 0, len(stages)+1)
	inserted := false
	for _, s := range stages {
		if sm, _ := s.(map[string]any); sm != nil && !inserted {
			if key, _ := sm["stageKey"].(string); key == "routing" {
				out = append(out, stage)
				inserted = true
			}
		}
		out = append(out, s)
	}
	if !inserted {
		out = append(out, stage)
	}
	policy["policyEnforcements"] = out
}

// putPolicy PUTs the (mutated) raw policy record back, enveloped.
func (a *Adapter) putPolicy(ctx context.Context, policyID string, policy map[string]any) (int, []byte, error) {
	url := a.adminPath("/policies/" + policyID)
	return a.sendJSON(ctx, http.MethodPut, url, map[string]any{"policy": policy})
}

// attachIAMStage injects the IAM stage and PUTs the policy (guarded).
func (a *Adapter) attachIAMStage(ctx context.Context, apiID, policyID string, policy map[string]any, actionID string) error {
	injectIAMStage(policy, actionID)
	return a.putPolicyGuarded(ctx, apiID, policyID, policy, "inbound auth: attach "+stageIAM+" stage")
}

// putPolicyGuarded PUTs the (mutated) policy. Observed live on 10.15: the PUT
// succeeds with the API ACTIVE (200, effect immediate). Some builds are
// stricter and refuse policy edits on an active API, so a non-2xx answer
// triggers the guarded cycle deactivate -> PUT -> reactivate; the reactivation
// runs even when the retry fails (never leave the API down), and ensureActive
// proves isActive=true afterwards. `what` labels errors with the calling
// projection (IAM attach, routing attach).
func (a *Adapter) putPolicyGuarded(ctx context.Context, apiID, policyID string, policy map[string]any, what string) error {
	code, raw, err := a.putPolicy(ctx, policyID, policy)
	if err != nil {
		return fmt.Errorf("%s to policy %s: %w", what, policyID, err)
	}
	if code == http.StatusOK || code == http.StatusCreated {
		return nil
	}

	// Strict build: deactivate ONLY this API, retry, reactivate regardless.
	if derr := a.setAPIActive(ctx, apiID, false); derr != nil {
		return fmt.Errorf("%s: policy %s PUT got %d (%s) and deactivate failed: %w", what, policyID, code, truncate(raw, 200), derr)
	}
	retryCode, retryRaw, retryErr := a.putPolicy(ctx, policyID, policy)
	if _, aerr := a.ensureActive(ctx, apiID, apiID); aerr != nil {
		return fmt.Errorf("%s: reactivate api %s after policy edit: %w", what, apiID, aerr)
	}
	if retryErr != nil {
		return fmt.Errorf("%s to policy %s (after deactivate): %w", what, policyID, retryErr)
	}
	if retryCode != http.StatusOK && retryCode != http.StatusCreated {
		return fmt.Errorf("%s to policy %s: expected 200/201, got %d: %s", what, policyID, retryCode, truncate(retryRaw, 300))
	}
	return nil
}

// setAPIActive drives the explicit activate/deactivate lifecycle endpoints.
func (a *Adapter) setAPIActive(ctx context.Context, apiID string, active bool) error {
	verb := "deactivate"
	if active {
		verb = "activate"
	}
	url := a.adminPath("/apis/" + apiID + "/" + verb)
	code, raw, err := httpx.Do(ctx, a.http, http.MethodPut, url, a.authHeaders(), nil)
	if err != nil {
		return fmt.Errorf("%s api %s: %w", verb, apiID, err)
	}
	if code != http.StatusOK && code != http.StatusNoContent {
		return fmt.Errorf("%s api %s: expected 200/204, got %d: %s", verb, apiID, code, truncate(raw, 300))
	}
	return nil
}
