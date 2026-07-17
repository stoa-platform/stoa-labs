package webmethods

// Unit tests for the FULL OAuth2 projection (strategy + scope mapping +
// application identifier/authStrategyIds + IAM action flipped to strict/
// oAuth2Token), against the same httptest mock. They assert the live-pinned
// shape: NAKED strategy/scope bodies vs ENVELOPED responses, the strict/
// oAuth2Token action mode, the application identifier azp/openIdClaims (the
// identifier KEY is unchanged — only the ACTION's identificationType moved to
// oAuth2Token) and the authStrategyIds binding, all idempotent on re-apply.

import (
	"context"
	"net/http/httptest"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

const (
	testAudience = "accounts-read"
	testScope    = "accounts.read"
	testClientID = "accounts-read-consumer"
)

// newOAuth2Adapter builds an adapter with the FULL OAuth2 inboundAuth knobs
// folded into Options exactly as targets.Target.ToConfig does.
func newOAuth2Adapter(t *testing.T, srv *httptest.Server) (*Adapter, *adapter.NormalizedAPI) {
	t.Helper()
	a, err := New(adapter.Config{
		Type:       gatewayName,
		Name:       gatewayName,
		AdminURL:   srv.URL,
		GatewayURL: "http://webmethods-real:5555",
		Credentials: map[string]string{
			"username": testUser,
			"password": testPass,
		},
		Options: map[string]string{
			"inboundAuthIssuer":    testIssuer,
			"inboundAuthJwksUri":   testJWKS,
			"inboundAuthAliasName": testAliasName,
			"inboundAuthAudience":  testAudience,
			"inboundAuthScope":     testScope,
			"inboundAuthClientId":  testClientID,
		},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	api := &adapter.NormalizedAPI{
		Name:       "accounts-read",
		Version:    "1.0.0",
		BasePath:   "/accounts-read/v1",
		BackendURL: "http://microcks:8080/rest/accounts",
		Spec:       []byte(sampleSpec),
		SpecPath:   "apis/accounts-read.openapi.yaml",
	}
	return a.(*Adapter), api
}

// onlyStrategy returns the single strategy in the mock.
func onlyStrategy(t *testing.T, mock *mockGateway) map[string]any {
	t.Helper()
	if len(mock.strategies) != 1 {
		t.Fatalf("mock holds %d strategies, want 1", len(mock.strategies))
	}
	for _, st := range mock.strategies {
		return st
	}
	return nil
}

// onlyScope returns the single scope mapping in the mock.
func onlyScope(t *testing.T, mock *mockGateway) map[string]any {
	t.Helper()
	if len(mock.scopes) != 1 {
		t.Fatalf("mock holds %d scope mappings, want 1", len(mock.scopes))
	}
	for _, sc := range mock.scopes {
		return sc
	}
	return nil
}

func TestNew_OAuth2RequiresScopeAndClientID(t *testing.T) {
	base := map[string]string{
		"inboundAuthIssuer":   testIssuer,
		"inboundAuthJwksUri":  testJWKS,
		"inboundAuthAudience": testAudience,
	}
	// audience without scope -> fail closed.
	if _, err := New(adapter.Config{
		AdminURL:    "http://localhost:5555",
		Credentials: map[string]string{"username": testUser, "password": testPass},
		Options:     base,
	}); err == nil {
		t.Fatal("New with audience but no scope succeeded, want fail-closed")
	}
	// audience + scope but no clientId -> fail closed.
	withScope := map[string]string{}
	for k, v := range base {
		withScope[k] = v
	}
	withScope["inboundAuthScope"] = testScope
	if _, err := New(adapter.Config{
		AdminURL:    "http://localhost:5555",
		Credentials: map[string]string{"username": testUser, "password": testPass},
		Options:     withScope,
	}); err == nil {
		t.Fatal("New with audience+scope but no clientId succeeded, want fail-closed")
	}
}

func TestPublish_OAuth2ProjectsStrategyScopeAndStrictAction(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newOAuth2Adapter(t, srv)
	res, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if !res.Published {
		t.Error("Published = false, want true")
	}

	// Strategy: OAUTH2 bound to the alias by NAME, pinning clientId + audience.
	st := onlyStrategy(t, mock)
	if st["type"] != "OAUTH2" {
		t.Errorf("strategy type = %v, want OAUTH2", st["type"])
	}
	if st["authServerAlias"] != testAliasName {
		t.Errorf("strategy authServerAlias = %v, want %q (alias NAME, not uuid)", st["authServerAlias"], testAliasName)
	}
	if st["clientId"] != testClientID {
		t.Errorf("strategy clientId = %v, want %q", st["clientId"], testClientID)
	}
	if st["audience"] != testAudience {
		t.Errorf("strategy audience = %v, want %q", st["audience"], testAudience)
	}

	// Scope mapping: PER-API name (ADR-079 client model — one mapping per
	// API+version, no shared multi-API state; the legacy "<alias>:<scope>"
	// shared name stays reachable via inboundScopeMappingName).
	sc := onlyScope(t, mock)
	wantScopeName := api.Name + ":" + api.Version
	if sc["scopeName"] != wantScopeName {
		t.Errorf("scope scopeName = %v, want %q", sc["scopeName"], wantScopeName)
	}
	if !scopeBindsAPI(sc, res.APIID) {
		t.Errorf("scope apiScopes %v does not bind the API %q", sc["apiScopes"], res.APIID)
	}
	if !a.scopeRequiresAuthScope(sc) {
		t.Errorf("scope requiredAuthScopes %v does not gate on (%q,%q)", sc["requiredAuthScopes"], testAliasName, testScope)
	}
	if sc["audience"] != testAudience {
		t.Errorf("scope audience = %v, want %q", sc["audience"], testAudience)
	}

	// Action: strict / oAuth2Token (the hole-closing mode), referenced by the
	// IAM stage.
	if len(mock.actions) != 1 {
		t.Fatalf("mock holds %d actions, want 1", len(mock.actions))
	}
	var actID string
	for id, act := range mock.actions {
		actID = id
		if !actionInMode(act, identifyActionMode{applicationLookup: "strict", identificationType: "oAuth2Token"}) {
			t.Errorf("OAuth2 action not in strict/oAuth2Token mode: %v", act)
		}
	}
	polID := mock.apis[res.APIID].rec.Policies[0]
	if !policyIAMReferences(mock.policies[polID], actID) {
		t.Errorf("IAM stage does not reference the strict action %q", actID)
	}
}

func TestPublish_OAuth2ConvergesSignatureOnlyActionToStrict(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	// Pre-seed a signature-only action (open/jwtClaims), as a prior
	// signature-only apply would have left it: the OAuth2 apply must PUT it in
	// place to strict/oAuth2Token, NOT create a second action.
	mock.actions["act-sigonly"] = map[string]any{
		"id":          "act-sigonly",
		"names":       []any{map[string]any{"value": "Identify & Authorize", "locale": "en"}},
		"templateKey": "evaluatePolicy",
		"parameters": []any{
			map[string]any{"templateKey": "logicalConnector", "values": []any{"OR"}},
			map[string]any{"templateKey": "allowAnonymous", "values": []any{"false"}},
			map[string]any{"templateKey": "IdentificationRule", "parameters": []any{
				map[string]any{"templateKey": "applicationLookup", "values": []any{"open"}},
				map[string]any{"templateKey": "identificationType", "values": []any{"jwtClaims"}},
			}},
		},
	}

	a, api := newOAuth2Adapter(t, srv)
	res, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if got := mock.countRequests("POST /rest/apigateway/policyActions"); got != 0 {
		t.Errorf("POST /policyActions = %d, want 0 (converge the existing action in place)", got)
	}
	if got := mock.countRequests("PUT /rest/apigateway/policyActions/act-sigonly"); got != 1 {
		t.Errorf("PUT /policyActions/act-sigonly = %d, want 1 (flip to strict/oAuth2Token)", got)
	}
	if len(mock.actions) != 1 {
		t.Errorf("actions after converge = %d, want 1 (no second action)", len(mock.actions))
	}
	if !actionInMode(mock.actions["act-sigonly"], identifyActionMode{applicationLookup: "strict", identificationType: "oAuth2Token"}) {
		t.Errorf("action not flipped to strict/oAuth2Token: %v", mock.actions["act-sigonly"])
	}
	polID := mock.apis[res.APIID].rec.Policies[0]
	if !policyIAMReferences(mock.policies[polID], "act-sigonly") {
		t.Error("IAM stage does not reference the converged action")
	}
}

// TestOAuth2ActionMode_IdentificationTypeIsOAuth2Token pins the LIVE projection:
// the OAuth2 IAM action must run as identificationType=oAuth2Token (NOT the
// older openIdClaims), in applicationLookup=strict. This guards the value at the
// source (wantMode -> identifyActionBody) independently of any live gateway.
func TestOAuth2ActionMode_IdentificationTypeIsOAuth2Token(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, _ := newOAuth2Adapter(t, srv)
	mode := a.wantMode()
	if mode.applicationLookup != "strict" || mode.identificationType != "oAuth2Token" {
		t.Fatalf("wantMode = %+v, want {strict, oAuth2Token}", mode)
	}

	// The ENVELOPED action body the adapter POSTs/PUTs must carry the projected
	// value verbatim in the IdentificationRule (templateKey identificationType).
	body := identifyActionBody("", mode)
	action, _ := body["policyAction"].(map[string]any)
	if action == nil {
		t.Fatalf("identifyActionBody produced no policyAction envelope: %v", body)
	}
	if !actionInMode(action, mode) {
		t.Errorf("identifyActionBody not in strict/oAuth2Token mode: %v", action)
	}
	if got := identificationType(action); got != "oAuth2Token" {
		t.Errorf("projected identificationType = %q, want oAuth2Token", got)
	}

	// A legacy openIdClaims action must still be RECOGNISED as an Identify action
	// so a prior-mode action is converged in place (never orphaned by a second
	// POST). The signature-only jwtClaims action is recognised too.
	for _, idt := range []string{"openIdClaims", "oAuth2Token", "jwtClaims"} {
		legacy := map[string]any{
			"templateKey": "evaluatePolicy",
			"parameters": []any{map[string]any{
				"templateKey": "IdentificationRule",
				"parameters": []any{
					map[string]any{"templateKey": "applicationLookup", "values": []any{"strict"}},
					map[string]any{"templateKey": "identificationType", "values": []any{idt}},
				},
			}},
		}
		if !isIdentifyAction(legacy) {
			t.Errorf("isIdentifyAction(identificationType=%q) = false, want true", idt)
		}
	}
}

func TestPublish_OAuth2IdempotentSecondRun(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newOAuth2Adapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("first Publish: %v", err)
	}
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("second Publish: %v", err)
	}

	// No duplicates and no second write on any OAuth2 object.
	if len(mock.strategies) != 1 {
		t.Errorf("strategies after re-apply = %d, want 1", len(mock.strategies))
	}
	if len(mock.scopes) != 1 {
		t.Errorf("scopes after re-apply = %d, want 1", len(mock.scopes))
	}
	if len(mock.actions) != 1 {
		t.Errorf("actions after re-apply = %d, want 1", len(mock.actions))
	}
	for _, p := range []string{
		"POST /rest/apigateway/strategies",
		"POST /rest/apigateway/scopes",
		"POST /rest/apigateway/policyActions",
		"PUT /rest/apigateway/policies/",
	} {
		if got := mock.countRequests(p); got != 1 {
			t.Errorf("%s count = %d over two publishes, want 1 (idempotent)", p, got)
		}
	}
	// No drift PUTs on the converged strategy/scope/action on the second run.
	if got := mock.countRequests("PUT /rest/apigateway/strategies/"); got != 0 {
		t.Errorf("PUT /strategies = %d, want 0 (no drift)", got)
	}
	if got := mock.countRequests("PUT /rest/apigateway/scopes/"); got != 0 {
		t.Errorf("PUT /scopes = %d, want 0 (no drift)", got)
	}
}

func TestCreateConsumer_OAuth2BindsApplicationIdentifierAndStrategy(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newOAuth2Adapter(t, srv)
	// apply first so the strategy exists for the application to bind to.
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	strategyID := onlyStrategy(t, mock)["id"].(string)

	spec := &adapter.ConsumerSpec{Name: "labctl-live-consumer", ClientID: testClientID, AuthType: "oauth2"}
	res, err := a.CreateConsumer(context.Background(), api, spec)
	if err != nil {
		t.Fatalf("CreateConsumer: %v", err)
	}

	app := mock.appRaw[res.ConsumerID]
	if app == nil {
		t.Fatalf("application %q not stored", res.ConsumerID)
	}
	if !appHasAZPIdentifier(app, testClientID) {
		t.Errorf("application identifiers %v lack azp/openIdClaims=[%q]", app["identifiers"], testClientID)
	}
	if !appHasStrategy(app, strategyID) {
		t.Errorf("application authStrategyIds %v lack the strategy %q", app["authStrategyIds"], strategyID)
	}
	// consumingAPIs (the API association) survives the identifier PUT.
	if got := mock.appAPIs[res.ConsumerID]; len(got) != 1 || got[0] != "wm-api-0001" {
		t.Errorf("API association lost after the OAuth2 binding PUT: %v", got)
	}
}

func TestCreateConsumer_OAuth2IdempotentBinding(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newOAuth2Adapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	spec := &adapter.ConsumerSpec{Name: "labctl-live-consumer", ClientID: testClientID}

	if _, err := a.CreateConsumer(context.Background(), api, spec); err != nil {
		t.Fatalf("first CreateConsumer: %v", err)
	}
	if _, err := a.CreateConsumer(context.Background(), api, spec); err != nil {
		t.Fatalf("second CreateConsumer: %v", err)
	}
	if len(mock.apps) != 1 {
		t.Errorf("applications after re-subscribe = %d, want 1", len(mock.apps))
	}
	// The OAuth2 binding PUT happens ONCE (the second run sees it converged).
	// countExact so the /applications/{id}/apis associate PUTs are not conflated.
	if got := mock.countExact("PUT /rest/apigateway/applications/wm-app-0001"); got != 1 {
		t.Errorf("application binding PUT count = %d over two subscribes, want 1 (idempotent)", got)
	}
}

func TestCreateConsumer_OAuth2SetsIdentifierEvenWithoutStrategy(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newOAuth2Adapter(t, srv)
	// Publish WITHOUT the inbound projection (plain adapter) so the API exists
	// but NO strategy is present — simulates subscribe run before apply.
	plain, _ := newAdapter(t, srv)
	if _, err := plain.Publish(context.Background(), api); err != nil {
		t.Fatalf("plain Publish: %v", err)
	}
	if len(mock.strategies) != 0 {
		t.Fatalf("precondition: expected no strategy yet, have %d", len(mock.strategies))
	}

	spec := &adapter.ConsumerSpec{Name: "labctl-live-consumer", ClientID: testClientID}
	res, err := a.CreateConsumer(context.Background(), api, spec)
	if err != nil {
		t.Fatalf("CreateConsumer before apply: %v", err)
	}
	app := mock.appRaw[res.ConsumerID]
	if !appHasAZPIdentifier(app, testClientID) {
		t.Errorf("identifier not set when strategy absent: %v", app["identifiers"])
	}
	if ids, _ := app["authStrategyIds"].([]any); len(ids) != 0 {
		t.Errorf("authStrategyIds = %v, want empty (no strategy to bind yet)", ids)
	}
}

// The strategy name is DERIVED from the API name ("OIDC-<api>", sanitised) —
// not a hardcoded constant — so two APIs on one target never share a strategy.
func TestStrategyName_DerivedFromAPIName(t *testing.T) {
	if got := strategyName("accounts-read"); got != "OIDC-accounts-read" {
		t.Errorf("strategyName(accounts-read) = %q, want OIDC-accounts-read", got)
	}
	if got := strategyName("payments write/v2"); got != "OIDC-payments-write-v2" {
		t.Errorf("strategyName sanitisation = %q, want OIDC-payments-write-v2", got)
	}
}

// End-to-end: publishing an API named differently mints a strategy under ITS
// derived name, and the consumer binding finds it back by the SAME derivation.
func TestPublish_OAuth2StrategyNameFollowsAPIName(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newOAuth2Adapter(t, srv)
	api.Name = "payments write"
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	st := onlyStrategy(t, mock)
	if st["name"] != "OIDC-payments-write" {
		t.Errorf("strategy name = %v, want OIDC-payments-write (derived from the API name)", st["name"])
	}

	// The consumer binding must resolve the strategy by the SAME derived name.
	spec := &adapter.ConsumerSpec{Name: "labctl-live-consumer", ClientID: testClientID}
	res, err := a.CreateConsumer(context.Background(), api, spec)
	if err != nil {
		t.Fatalf("CreateConsumer: %v", err)
	}
	if !appHasStrategy(mock.appRaw[res.ConsumerID], st["id"].(string)) {
		t.Errorf("application authStrategyIds %v lack the derived-name strategy %v", mock.appRaw[res.ConsumerID]["authStrategyIds"], st["id"])
	}
}

func TestPublish_NoAudienceStaysSignatureOnly(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	// The signature-only inbound adapter (issuer+jwks, no audience) must NOT
	// touch the OAuth2 surface at all.
	a, api := newInboundAdapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	for _, p := range []string{
		"GET /rest/apigateway/strategies",
		"POST /rest/apigateway/strategies",
		"GET /rest/apigateway/scopes",
		"POST /rest/apigateway/scopes",
	} {
		if got := mock.countRequests(p); got != 0 {
			t.Errorf("%s count = %d on the signature-only path, want 0", p, got)
		}
	}
	if len(mock.strategies) != 0 || len(mock.scopes) != 0 {
		t.Errorf("OAuth2 objects materialised on the signature-only path: strat=%d scope=%d", len(mock.strategies), len(mock.scopes))
	}
}
