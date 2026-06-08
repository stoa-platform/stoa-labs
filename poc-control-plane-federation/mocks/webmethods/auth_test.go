package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAuth_DisabledWhenNoIssuer(t *testing.T) {
	t.Setenv("JWT_ISSUER", "")
	if a := NewAuthenticatorFromEnv(context.Background()); a != nil {
		t.Fatalf("expected nil authenticator when JWT_ISSUER unset, got %v", a)
	}
}

func TestAuth_EnabledWhenIssuerSet(t *testing.T) {
	t.Setenv("JWT_ISSUER", "http://keycloak:8080/realms/stoa-lab")
	if a := NewAuthenticatorFromEnv(context.Background()); a == nil {
		t.Fatal("expected a non-nil authenticator when JWT_ISSUER is set")
	}
}

func TestMiddleware_RejectsMissingAndGarbageBearer(t *testing.T) {
	// jwksURL is never hit: a missing/garbage token fails before any key fetch.
	a := NewAuthenticator(context.Background(),
		"http://keycloak:8080/realms/stoa-lab", "http://127.0.0.1:0/unused")
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	h := a.Middleware(next)

	for _, tc := range []struct{ name, authz string }{
		{"missing", ""},
		{"garbage", "Bearer not-a-jwt"},
	} {
		req := httptest.NewRequest("GET", "/gateway/accounts-read/v1/accounts", nil)
		if tc.authz != "" {
			req.Header.Set("Authorization", tc.authz)
		}
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		if rr.Code != http.StatusUnauthorized {
			t.Errorf("%s: code = %d, want 401", tc.name, rr.Code)
		}
		if got := rr.Header().Get("WWW-Authenticate"); got == "" {
			t.Errorf("%s: missing WWW-Authenticate header", tc.name)
		}
	}
}

func TestServer_DataPlaneOpenWhenAuthDisabled(t *testing.T) {
	t.Setenv("JWT_ISSUER", "") // auth off
	h := NewServer().Handler()
	// register an API, then hit the data-plane without any token -> not 401.
	do(t, h, "POST", "/rest/apigateway/apis", map[string]string{"apiName": "x", "basePath": "/x"})
	rr := do(t, h, "GET", "/gateway/x", nil)
	if rr.Code == http.StatusUnauthorized {
		t.Fatalf("data-plane must be open when auth disabled, got 401")
	}
}
