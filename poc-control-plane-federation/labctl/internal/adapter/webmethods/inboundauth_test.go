package webmethods

// Unit tests for the inbound JWT/JWKS auth projection (alias + Identify &
// Authorize action + IAM policy stage), against the same httptest mock as
// webmethods_test.go. The mock reproduces the live-pinned 10.15 quirks the
// projection must survive: naked vs enveloped bodies, {"alias":[...]} /
// {"policyAction":[...]} envelopes, action display-name NORMALISATION, the
// wholesale-replacing policy PUT, and (optionally) builds that refuse policy
// edits while the API is active.

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

const (
	testIssuer    = "http://localhost:8480/realms/stoa-lab"
	testJWKS      = "http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/certs"
	testAliasName = "KeycloakStoaLab"
)

// newInboundAdapter builds an adapter with the inboundAuth knobs folded into
// Options exactly as targets.Target.ToConfig does.
func newInboundAdapter(t *testing.T, srv *httptest.Server) (*Adapter, *adapter.NormalizedAPI) {
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

// onlyAlias returns the single labctl-managed alias in the mock (the built-in
// "local" alias is served by the list handler, not stored).
func onlyAlias(t *testing.T, mock *mockGateway) map[string]any {
	t.Helper()
	if len(mock.aliases) != 1 {
		t.Fatalf("mock holds %d aliases, want 1", len(mock.aliases))
	}
	for _, al := range mock.aliases {
		return al
	}
	return nil
}

// iamStage returns the IAM stage of the API's policy, or nil.
func iamStage(t *testing.T, mock *mockGateway, polID string) map[string]any {
	t.Helper()
	pol := mock.policies[polID]
	if pol == nil {
		t.Fatalf("policy %s not found in mock", polID)
	}
	stages, _ := pol["policyEnforcements"].([]any)
	for _, s := range stages {
		sm, _ := s.(map[string]any)
		if sm != nil && sm["stageKey"] == stageIAM {
			return sm
		}
	}
	return nil
}

func TestPublish_InboundAuthProjectsAliasActionAndIAMStage(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newInboundAdapter(t, srv)
	res, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if !res.Published {
		t.Error("Published = false, want true")
	}

	// Alias: EXTERNAL auth server with the split-horizon issuer/jwksuri pair.
	al := onlyAlias(t, mock)
	if al["name"] != testAliasName {
		t.Errorf("alias name = %v, want %q", al["name"], testAliasName)
	}
	if al["authServerType"] != "EXTERNAL" {
		t.Errorf("authServerType = %v, want EXTERNAL", al["authServerType"])
	}
	issuer, jwks := aliasIntrospection(al)
	if issuer != testIssuer || jwks != testJWKS {
		t.Errorf("alias introspection = (%q, %q), want (%q, %q)", issuer, jwks, testIssuer, testJWKS)
	}

	// Action: one evaluatePolicy/jwtClaims action, allowAnonymous=false.
	if len(mock.actions) != 1 {
		t.Fatalf("mock holds %d policy actions, want 1", len(mock.actions))
	}
	var actID string
	for id, act := range mock.actions {
		actID = id
		if !isIdentifyAction(act) {
			t.Errorf("created action is not the Identify & Authorize fingerprint: %v", act)
		}
		// Signature-only manifest (no audience) -> open/jwtClaims mode.
		if !actionInMode(act, identifyActionMode{applicationLookup: "open", identificationType: "jwtClaims"}) {
			t.Errorf("signature-only action not in open/jwtClaims mode: %v", act)
		}
	}

	// Policy: IAM stage present, referencing the action; transport + routing
	// stages preserved (the PUT replaces policyEnforcements wholesale).
	stored := mock.apis[res.APIID]
	if stored == nil || len(stored.rec.Policies) != 1 {
		t.Fatalf("api record carries no policy: %+v", stored)
	}
	polID := stored.rec.Policies[0]
	stage := iamStage(t, mock, polID)
	if stage == nil {
		t.Fatalf("policy %s has no %s stage after publish", polID, stageIAM)
	}
	enf, _ := stage["enforcements"].([]any)
	if len(enf) != 1 {
		t.Fatalf("IAM enforcements = %v, want exactly one", enf)
	}
	if got := enf[0].(map[string]any)["enforcementObjectId"]; got != actID {
		t.Errorf("IAM enforcementObjectId = %v, want the created action %q", got, actID)
	}
	keys := map[string]bool{}
	stages, _ := mock.policies[polID]["policyEnforcements"].([]any)
	for _, s := range stages {
		keys[s.(map[string]any)["stageKey"].(string)] = true
	}
	for _, want := range []string{"transport", stageIAM, "routing"} {
		if !keys[want] {
			t.Errorf("policy lost stage %q after the wholesale PUT: have %v", want, keys)
		}
	}
	// The API must end ACTIVE — the whole point of the tooled projection.
	if !stored.rec.IsActive {
		t.Error("api isActive = false after publish, want true")
	}
}

func TestPublish_InboundAuthIdempotentSecondRun(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newInboundAdapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("first Publish: %v", err)
	}
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("second Publish: %v", err)
	}

	// No duplicates: one alias, one action, and the policy was written ONCE
	// (the second run hits the IAM-stage idempotence gate and stays read-only).
	if len(mock.aliases) != 1 {
		t.Errorf("aliases after re-apply = %d, want 1", len(mock.aliases))
	}
	if len(mock.actions) != 1 {
		t.Errorf("policy actions after re-apply = %d, want 1", len(mock.actions))
	}
	if got := mock.countRequests("POST /rest/apigateway/alias"); got != 1 {
		t.Errorf("POST /alias count = %d over two publishes, want 1", got)
	}
	if got := mock.countRequests("POST /rest/apigateway/policyActions"); got != 1 {
		t.Errorf("POST /policyActions count = %d over two publishes, want 1", got)
	}
	if got := mock.countRequests("PUT /rest/apigateway/policies/"); got != 1 {
		t.Errorf("PUT /policies count = %d over two publishes, want 1", got)
	}
}

func TestPublish_NoInboundAuthTouchesNoAuthSurface(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	// Plain adapter (no inboundAuth in the manifest): behavior must be
	// byte-identical to before the feature — zero calls on the auth surface.
	a, api := newAdapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	for _, prefix := range []string{
		"GET /rest/apigateway/alias",
		"POST /rest/apigateway/alias",
		"GET /rest/apigateway/policyActions",
		"POST /rest/apigateway/policyActions",
		"GET /rest/apigateway/policies/",
		"PUT /rest/apigateway/policies/",
		"PUT /rest/apigateway/apis/wm-api-0001/deactivate",
	} {
		if got := mock.countRequests(prefix); got != 0 {
			t.Errorf("%s count = %d without inboundAuth, want 0", prefix, got)
		}
	}
	if stage := iamStage(t, mock, mock.apis["wm-api-0001"].rec.Policies[0]); stage != nil {
		t.Errorf("policy gained an IAM stage without inboundAuth: %v", stage)
	}
}

func TestPublish_InboundAuthConvergesDriftedAliasInPlace(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	// Pre-seed the alias under the SAME name but a stale JWKS (e.g. a realm
	// moved): the projection must PUT it back in line, never POST a duplicate
	// (a re-POST of the same name is a duplicate error on the real product).
	mock.aliases["alias-old"] = map[string]any{
		"id": "alias-old", "name": testAliasName,
		"type": "authServerAlias", "authServerType": "EXTERNAL",
		"localIntrospectionConfig": map[string]any{
			"issuer":  testIssuer,
			"jwksuri": "http://old-keycloak:8080/realms/stale/certs",
		},
		"scopes": []any{map[string]any{"name": "openid"}}, // gateway-enriched field to preserve
	}

	a, api := newInboundAdapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	if got := mock.countRequests("POST /rest/apigateway/alias"); got != 0 {
		t.Errorf("POST /alias count = %d, want 0 (converge via PUT)", got)
	}
	if got := mock.countRequests("PUT /rest/apigateway/alias/alias-old"); got != 1 {
		t.Errorf("PUT /alias/alias-old count = %d, want 1", got)
	}
	al := onlyAlias(t, mock)
	_, jwks := aliasIntrospection(al)
	if jwks != testJWKS {
		t.Errorf("alias jwksuri = %q, want converged %q", jwks, testJWKS)
	}
	if _, ok := al["scopes"]; !ok {
		t.Error("alias update dropped the gateway-enriched scopes field (must PUT the full read-back record)")
	}
}

func TestPublish_InboundAuthReusesExistingActionByFingerprint(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	// Pre-seed an action whose display name is the NORMALISED one the product
	// serves ("Identify & Authorize", not what was POSTed): reuse must key on
	// the templateKey+identificationType fingerprint, not the name.
	mock.actions["act-preexisting"] = map[string]any{
		"id":          "act-preexisting",
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

	a, api := newInboundAdapter(t, srv)
	res, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if got := mock.countRequests("POST /rest/apigateway/policyActions"); got != 0 {
		t.Errorf("POST /policyActions count = %d, want 0 (reuse by fingerprint)", got)
	}
	stage := iamStage(t, mock, mock.apis[res.APIID].rec.Policies[0])
	if stage == nil {
		t.Fatal("policy has no IAM stage")
	}
	enf, _ := stage["enforcements"].([]any)
	if got := enf[0].(map[string]any)["enforcementObjectId"]; got != "act-preexisting" {
		t.Errorf("IAM references %v, want the pre-existing action act-preexisting", got)
	}
}

func TestPublish_InboundAuthStrictBuildDeactivateEditReactivate(t *testing.T) {
	mock := newMockGateway()
	mock.strictPolicyEdit = true
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newInboundAdapter(t, srv)
	res, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("Publish on strict build: %v", err)
	}

	// The cycle ran: deactivate once, policy PUT twice (refused, then OK),
	// and the API ends ACTIVE with the IAM stage in place.
	apiID := res.APIID
	if got := mock.countRequests("PUT /rest/apigateway/apis/" + apiID + "/deactivate"); got != 1 {
		t.Errorf("deactivate count = %d, want 1", got)
	}
	if got := mock.countRequests("PUT /rest/apigateway/policies/"); got != 2 {
		t.Errorf("policy PUT count = %d, want 2 (refused while active, retried inactive)", got)
	}
	if got := mock.countRequests("PUT /rest/apigateway/apis/" + apiID + "/activate"); got != 2 {
		t.Errorf("activate count = %d, want 2 (initial + reactivation after the cycle)", got)
	}
	if !mock.apis[apiID].rec.IsActive {
		t.Error("api isActive = false after the strict-build cycle, want true (never leave the API down)")
	}
	if stage := iamStage(t, mock, mock.apis[apiID].rec.Policies[0]); stage == nil {
		t.Error("policy has no IAM stage after the strict-build cycle")
	}
}

func TestNew_InboundAuthHalfConfigFailsClosed(t *testing.T) {
	for name, opts := range map[string]map[string]string{
		"issuer only": {"inboundAuthIssuer": testIssuer},
		"jwks only":   {"inboundAuthJwksUri": testJWKS},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := New(adapter.Config{
				AdminURL:    "http://localhost:5555",
				Credentials: map[string]string{"username": testUser, "password": testPass},
				Options:     opts,
			})
			if err == nil {
				t.Fatal("New with a half-filled inboundAuth succeeded, want fail-closed error")
			}
			if !strings.Contains(err.Error(), "inboundAuth") {
				t.Errorf("error %q should name the inboundAuth block", err.Error())
			}
		})
	}
}

func TestNew_InboundAuthDefaultAliasName(t *testing.T) {
	a, err := New(adapter.Config{
		AdminURL:    "http://localhost:5555",
		Credentials: map[string]string{"username": testUser, "password": testPass},
		Options: map[string]string{
			"inboundAuthIssuer":  testIssuer,
			"inboundAuthJwksUri": testJWKS,
		},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if got := a.(*Adapter).inbound.aliasName; got != defaultInboundAliasName {
		t.Errorf("default aliasName = %q, want %q", got, defaultInboundAliasName)
	}
}
