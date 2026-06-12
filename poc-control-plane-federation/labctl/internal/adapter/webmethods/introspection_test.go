package webmethods

// Unit tests for the REMOTE RFC 7662 introspection projection on the auth-server
// alias — the change that turns the audience into a 4th barrier. Offline JWKS
// validation (localIntrospectionConfig) never checks the aud claim; remote
// introspection asks the AS active/aud/azp/scope per request so the
// resource-server path enforces aud against strategy.audience. These tests pin:
//   - the create POST emits BOTH blocks (remote enforces aud, local is a
//     signature fallback);
//   - drift converges in place keyed on endpoint+clientId ONLY (the clientSecret
//     comes back masked "***" — MaskableEntity — and must never drive drift);
//   - the secret is always re-emitted in clear on the write;
//   - a build that silently drops the remote block (wrong field name) is caught
//     by the read-back assertion;
//   - config validation fails closed (introspection without audience).

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

const (
	testIntrospectionEndpoint = "http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/token/introspect"
	testIntrospectionClientID = "poc-gateways"
	testIntrospectionSecret   = "poc-gateways-secret"
)

// newRemoteIntrospectionAdapter builds an adapter with the FULL OAuth2 + remote
// introspection knobs, exactly as targets.Target.ToConfig + Load default them.
func newRemoteIntrospectionAdapter(t *testing.T, srv *httptest.Server) (*Adapter, *adapter.NormalizedAPI) {
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
			"inboundAuthIssuer":                    testIssuer,
			"inboundAuthJwksUri":                   testJWKS,
			"inboundAuthAliasName":                 testAliasName,
			"inboundAuthAudience":                  testAudience,
			"inboundAuthScope":                     testScope,
			"inboundAuthClientId":                  testClientID,
			"inboundAuthIntrospectionEndpoint":     testIntrospectionEndpoint,
			"inboundAuthIntrospectionClientId":     testIntrospectionClientID,
			"inboundAuthIntrospectionClientSecret": testIntrospectionSecret,
			"inboundAuthIntrospectionUser":         "Administrator",
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

// remoteConfig returns the alias's remoteIntrospectionConfig block (nil if absent).
func remoteConfig(al map[string]any) map[string]any {
	rc, _ := al["remoteIntrospectionConfig"].(map[string]any)
	return rc
}

func TestPublish_RemoteIntrospectionProjectedOnCreate(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newRemoteIntrospectionAdapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	al := onlyAlias(t, mock)
	// Local block kept (signature fallback).
	if _, jwks := aliasIntrospection(al); jwks != testJWKS {
		t.Errorf("localIntrospectionConfig.jwksuri = %q, want %q (kept as fallback)", jwks, testJWKS)
	}
	// Remote block present and pinned — this is what enforces aud.
	rc := remoteConfig(al)
	if rc == nil {
		t.Fatal("alias has no remoteIntrospectionConfig after create (audience stays unenforced)")
	}
	if got := rc["introspectionEndpoint"]; got != testIntrospectionEndpoint {
		t.Errorf("introspectionEndpoint = %v, want %q", got, testIntrospectionEndpoint)
	}
	if got := rc["clientId"]; got != testIntrospectionClientID {
		t.Errorf("clientId = %v, want %q", got, testIntrospectionClientID)
	}
	// The secret MUST be written in clear (GatewaySecret masks on read, not write).
	if got := rc["clientSecret"]; got != testIntrospectionSecret {
		t.Errorf("clientSecret = %v, want %q (must be sent in clear)", got, testIntrospectionSecret)
	}
	// The Gateway user is REQUIRED by 10.15 (the validator rejects an empty one).
	if got := rc["user"]; got != "Administrator" {
		t.Errorf("user = %v, want Administrator (10.15 requires a Gateway user)", got)
	}
}

// 10.15 rejects a remote block without a Gateway user; the adapter defaults it
// from the Basic-auth username — fail closed only when even that is absent.
func TestNew_RemoteIntrospectionUserDefaultsFromBasicAuth(t *testing.T) {
	a, err := New(adapter.Config{
		AdminURL:    "http://localhost:5555",
		Credentials: map[string]string{"username": "wm-admin", "password": testPass},
		Options: map[string]string{
			"inboundAuthIssuer":                    testIssuer,
			"inboundAuthJwksUri":                   testJWKS,
			"inboundAuthAudience":                  testAudience,
			"inboundAuthScope":                     testScope,
			"inboundAuthClientId":                  testClientID,
			"inboundAuthIntrospectionEndpoint":     testIntrospectionEndpoint,
			"inboundAuthIntrospectionClientId":     testIntrospectionClientID,
			"inboundAuthIntrospectionClientSecret": testIntrospectionSecret,
			// introspectionUser deliberately omitted -> defaults from Basic-auth.
		},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if got := a.(*Adapter).inbound.introspectionUser; got != "wm-admin" {
		t.Errorf("introspectionUser = %q, want defaulted from Basic-auth username wm-admin", got)
	}
}

func TestPublish_RemoteIntrospectionConvergesDriftedAliasInPlace(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	// Live starting state: the alias exists with ONLY localIntrospectionConfig
	// (the proven 3/4 hole). The projection must ENRICH it with the remote block
	// via PUT, not POST a duplicate, and keep gateway-enriched fields.
	mock.aliases["alias-local-only"] = map[string]any{
		"id": "alias-local-only", "name": testAliasName,
		"type": "authServerAlias", "authServerType": "EXTERNAL",
		"localIntrospectionConfig": map[string]any{
			"issuer":  testIssuer,
			"jwksuri": testJWKS,
		},
		"scopes": []any{map[string]any{"name": "accounts.read"}},
	}

	a, api := newRemoteIntrospectionAdapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	if got := mock.countRequests("POST /rest/apigateway/alias"); got != 0 {
		t.Errorf("POST /alias count = %d, want 0 (enrich via PUT)", got)
	}
	if got := mock.countRequests("PUT /rest/apigateway/alias/alias-local-only"); got != 1 {
		t.Errorf("PUT /alias count = %d, want 1", got)
	}
	al := onlyAlias(t, mock)
	rc := remoteConfig(al)
	if rc == nil || rc["introspectionEndpoint"] != testIntrospectionEndpoint {
		t.Fatalf("remoteIntrospectionConfig not converged onto a local-only alias: %v", rc)
	}
	if _, ok := al["scopes"]; !ok {
		t.Error("alias update dropped the gateway-enriched scopes field")
	}
}

func TestPublish_RemoteIntrospectionIdempotentDespiteMaskedSecret(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	// The alias is ALREADY converged, but the stored clientSecret is the MASKED
	// "***" the gateway serves on read (MaskableEntity). Drift must be keyed on
	// endpoint+clientId only: a re-apply must NOT PUT just because the read-back
	// secret differs from the configured one.
	mock.aliases["alias-converged"] = map[string]any{
		"id": "alias-converged", "name": testAliasName,
		"type": "authServerAlias", "authServerType": "EXTERNAL",
		"localIntrospectionConfig": map[string]any{
			"issuer":  testIssuer,
			"jwksuri": testJWKS,
		},
		"remoteIntrospectionConfig": map[string]any{
			"introspectionEndpoint": testIntrospectionEndpoint,
			"clientId":              testIntrospectionClientID,
			"clientSecret":          "***", // masked on read
		},
	}

	a, api := newRemoteIntrospectionAdapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if got := mock.countRequests("PUT /rest/apigateway/alias/alias-converged"); got != 0 {
		t.Errorf("PUT /alias count = %d, want 0 (masked secret must NOT trigger drift)", got)
	}
	if got := mock.countRequests("POST /rest/apigateway/alias"); got != 0 {
		t.Errorf("POST /alias count = %d, want 0", got)
	}
}

func TestPublish_RemoteIntrospectionReadBackCatchesDroppedField(t *testing.T) {
	mock := newMockGateway()
	mock.dropRemoteIntrospection = true // simulate a build that ignores the field name
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newRemoteIntrospectionAdapter(t, srv)
	_, err := a.Publish(context.Background(), api)
	if err == nil {
		t.Fatal("Publish succeeded though the gateway silently dropped remoteIntrospectionConfig — the read-back assertion must fail closed")
	}
	if !strings.Contains(err.Error(), "introspectionEndpoint") {
		t.Errorf("error %q should point at the dropped introspectionEndpoint field", err.Error())
	}
}

func TestNew_RemoteIntrospectionWithoutAudienceFailsClosed(t *testing.T) {
	_, err := New(adapter.Config{
		AdminURL:    "http://localhost:5555",
		Credentials: map[string]string{"username": testUser, "password": testPass},
		Options: map[string]string{
			"inboundAuthIssuer":                testIssuer,
			"inboundAuthJwksUri":               testJWKS,
			"inboundAuthIntrospectionEndpoint": testIntrospectionEndpoint,
		},
	})
	if err == nil {
		t.Fatal("New with introspectionEndpoint but no audience succeeded, want fail-closed")
	}
	if !strings.Contains(err.Error(), "audience") {
		t.Errorf("error %q should explain remote introspection needs an audience", err.Error())
	}
}
