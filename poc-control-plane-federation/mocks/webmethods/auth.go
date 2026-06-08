package main

import (
	"context"
	"net/http"
	"os"
	"strings"

	"github.com/coreos/go-oidc/v3/oidc"
)

// Authenticator validates Keycloak-issued Bearer access tokens (RS256) against
// the realm JWKS. It represents the data-plane policy a real apigateway:10.15
// would enforce — proving the legacy gateway federates the SAME Keycloak
// identity as WSO2 and APISIX.
type Authenticator struct {
	verifier *oidc.IDTokenVerifier
}

// NewAuthenticator builds a verifier WITHOUT OIDC discovery: it points straight
// at the JWKS URL. issuer is the exact `iss` claim to enforce; jwksURL is where
// the keys are fetched — kept separate so the fetch host (keycloak:8080) can
// differ from the advertised issuer host (e.g. localhost:8480).
func NewAuthenticator(ctx context.Context, issuer, jwksURL string) *Authenticator {
	keySet := oidc.NewRemoteKeySet(ctx, jwksURL)
	verifier := oidc.NewVerifier(issuer, keySet, &oidc.Config{
		SkipClientIDCheck:    true, // access token, not an ID token
		SupportedSigningAlgs: []string{oidc.RS256},
	})
	return &Authenticator{verifier: verifier}
}

// NewAuthenticatorFromEnv returns a configured Authenticator, or nil when
// JWT_ISSUER is unset (auth disabled — Phase 1/2 behaviour and unit tests).
//
//	JWT_ISSUER    the `iss` to enforce (enables auth when set)
//	JWT_JWKS_URL  where to FETCH the JWKS (default {issuer}/protocol/openid-connect/certs)
func NewAuthenticatorFromEnv(ctx context.Context) *Authenticator {
	issuer := os.Getenv("JWT_ISSUER")
	if issuer == "" {
		return nil
	}
	jwksURL := envOr("JWT_JWKS_URL", strings.TrimRight(issuer, "/")+"/protocol/openid-connect/certs")
	return NewAuthenticator(ctx, issuer, jwksURL)
}

// Middleware protects the data-plane: 401 if the Bearer token is absent or
// invalid, otherwise calls next.
func (a *Authenticator) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, ok := bearerToken(r)
		if !ok {
			unauthorized(w, "missing bearer token")
			return
		}
		if _, err := a.verifier.Verify(r.Context(), raw); err != nil {
			unauthorized(w, "invalid token: "+err.Error())
			return
		}
		next.ServeHTTP(w, r)
	})
}

func bearerToken(r *http.Request) (string, bool) {
	h := r.Header.Get("Authorization")
	const p = "Bearer "
	if len(h) <= len(p) || !strings.EqualFold(h[:len(p)], p) {
		return "", false
	}
	return strings.TrimSpace(h[len(p):]), true
}

func unauthorized(w http.ResponseWriter, msg string) {
	w.Header().Set("WWW-Authenticate", `Bearer realm="stoa-lab"`)
	writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized", "detail": msg})
}
