package governance

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// signedToken builds a real RS256 JWT signed by key, so the verifier exercises
// its actual signature/iss/exp/aud path (stdlib-only, no JWT library).
func signedToken(t *testing.T, key *rsa.PrivateKey, kid string, claims map[string]any) string {
	t.Helper()
	head := map[string]any{"alg": "RS256", "typ": "JWT", "kid": kid}
	enc := func(v any) string {
		b, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return base64.RawURLEncoding.EncodeToString(b)
	}
	signingInput := enc(head) + "." + enc(claims)
	digest := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)
}

// jwksServer serves a JWKS exposing key under kid.
func jwksServer(t *testing.T, key *rsa.PrivateKey, kid string) *httptest.Server {
	t.Helper()
	eBytes := make([]byte, 8)
	binary.BigEndian.PutUint64(eBytes, uint64(key.PublicKey.E))
	// trim leading zero bytes of the exponent
	i := 0
	for i < len(eBytes)-1 && eBytes[i] == 0 {
		i++
	}
	doc := map[string]any{"keys": []map[string]any{{
		"kid": kid, "kty": "RSA", "use": "sig", "alg": "RS256",
		"n": base64.RawURLEncoding.EncodeToString(key.PublicKey.N.Bytes()),
		"e": base64.RawURLEncoding.EncodeToString(eBytes[i:]),
	}}}
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(doc)
	}))
}

func newTestVerifier(jwksURL, issuer, audience string) *Verifier {
	return &Verifier{
		JWKSURL:  jwksURL,
		Issuer:   issuer,
		Audience: audience,
		client:   &http.Client{Timeout: 2 * time.Second},
		ttl:      5 * time.Minute,
		keys:     map[string]*rsa.PublicKey{},
	}
}

func TestVerify_LocalJWKS_AudienceEnforced(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	const kid = "test-kid"
	js := jwksServer(t, key, kid)
	defer js.Close()
	const issuer = "https://kc.example/realms/stoa-lab"

	base := map[string]any{
		"iss":                issuer,
		"exp":                float64(time.Now().Add(time.Hour).Unix()),
		"preferred_username": "alice",
		"sub":                "sub-alice",
		"tenant":             "banking-demo",
		"realm_access":       map[string]any{"roles": []string{"partner-onboarder"}},
	}

	t.Run("array aud containing the expected audience passes", func(t *testing.T) {
		c := cloneClaims(base)
		c["aud"] = []string{"account", "onboarding-api"}
		tok := signedToken(t, key, kid, c)
		v := newTestVerifier(js.URL, issuer, "onboarding-api")
		id, err := v.Verify(context.Background(), tok)
		if err != nil {
			t.Fatalf("expected valid, got %v", err)
		}
		if id.Tenant != "banking-demo" || id.Subject != "sub-alice" {
			t.Fatalf("claims projection wrong: %+v", id)
		}
	})

	t.Run("string aud equal to the expected audience passes", func(t *testing.T) {
		c := cloneClaims(base)
		c["aud"] = "onboarding-api"
		tok := signedToken(t, key, kid, c)
		v := newTestVerifier(js.URL, issuer, "onboarding-api")
		if _, err := v.Verify(context.Background(), tok); err != nil {
			t.Fatalf("expected valid, got %v", err)
		}
	})

	t.Run("missing audience is rejected", func(t *testing.T) {
		c := cloneClaims(base)
		c["aud"] = []string{"account"}
		tok := signedToken(t, key, kid, c)
		v := newTestVerifier(js.URL, issuer, "onboarding-api")
		if _, err := v.Verify(context.Background(), tok); err == nil {
			t.Fatal("expected audience rejection, got nil")
		}
	})

	t.Run("forged signature is rejected", func(t *testing.T) {
		c := cloneClaims(base)
		c["aud"] = "onboarding-api"
		tok := signedToken(t, key, kid, c)
		// Re-sign the SAME header.payload with a DIFFERENT key: a structurally
		// valid RS256 token whose signature does not verify against the JWKS.
		other, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			t.Fatal(err)
		}
		dot := lastDot(tok)
		signingInput := tok[:dot]
		digest := sha256.Sum256([]byte(signingInput))
		badSig, err := rsa.SignPKCS1v15(rand.Reader, other, crypto.SHA256, digest[:])
		if err != nil {
			t.Fatal(err)
		}
		forged := signingInput + "." + base64.RawURLEncoding.EncodeToString(badSig)
		v := newTestVerifier(js.URL, issuer, "onboarding-api")
		if _, err := v.Verify(context.Background(), forged); err == nil {
			t.Fatal("expected signature rejection, got nil")
		}
	})

	t.Run("expired token is rejected", func(t *testing.T) {
		c := cloneClaims(base)
		c["aud"] = "onboarding-api"
		c["exp"] = float64(time.Now().Add(-time.Minute).Unix())
		tok := signedToken(t, key, kid, c)
		v := newTestVerifier(js.URL, issuer, "onboarding-api")
		if _, err := v.Verify(context.Background(), tok); err == nil {
			t.Fatal("expected expiry rejection, got nil")
		}
	})

	t.Run("groups claim is projected for /tenants tenant derivation", func(t *testing.T) {
		c := cloneClaims(base)
		delete(c, "tenant")
		c["aud"] = "onboarding-api"
		c["groups"] = []string{"/tenants/payments-team"}
		tok := signedToken(t, key, kid, c)
		v := newTestVerifier(js.URL, issuer, "onboarding-api")
		id, err := v.Verify(context.Background(), tok)
		if err != nil {
			t.Fatalf("expected valid, got %v", err)
		}
		if len(id.Groups) != 1 || id.Groups[0] != "/tenants/payments-team" {
			t.Fatalf("groups not projected: %+v", id.Groups)
		}
	})
}

func lastDot(s string) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == '.' {
			return i
		}
	}
	return -1
}

func cloneClaims(in map[string]any) map[string]any {
	out := make(map[string]any, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}
