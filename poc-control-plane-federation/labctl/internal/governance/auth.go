package governance

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Verifier validates Keycloak RS256 access tokens stdlib-only (contract §1):
// JWKS fetched from {KC_BASE}/realms/{realm}/protocol/openid-connect/certs,
// cached 5 minutes, issuer pinned, exp enforced. No session, no cookie.
//
// Audience, when non-empty, is additionally enforced: the token's `aud` claim
// (string or []string) MUST contain it (RFC 7519 §4.1.3). It is left empty by
// the governance-api (which gates on roles, not a fixed audience); the
// onboarding-api sets it so a token minted for another resource cannot be
// replayed against the onboarding surface.
type Verifier struct {
	JWKSURL  string
	Issuer   string
	Audience string

	client *http.Client
	ttl    time.Duration

	mu        sync.Mutex
	keys      map[string]*rsa.PublicKey
	fetchedAt time.Time
}

// NewVerifier builds a verifier for one Keycloak realm. kcBase has no trailing
// slash (e.g. http://localhost:8480). Audience is not enforced (empty); use
// NewVerifierWithAudience to pin an expected `aud`.
func NewVerifier(kcBase, realm string) *Verifier {
	return NewVerifierWithAudience(kcBase, realm, "")
}

// NewVerifierWithAudience builds a verifier that additionally enforces that the
// token's `aud` claim contains audience (when audience is non-empty).
func NewVerifierWithAudience(kcBase, realm, audience string) *Verifier {
	base := strings.TrimRight(kcBase, "/")
	issuer := base + "/realms/" + realm
	return &Verifier{
		JWKSURL:  issuer + "/protocol/openid-connect/certs",
		Issuer:   issuer,
		Audience: audience,
		client:   &http.Client{Timeout: 5 * time.Second},
		ttl:      5 * time.Minute,
		keys:     map[string]*rsa.PublicKey{},
	}
}

// jwk is the subset of a JWKS entry we consume (RSA signature keys).
type jwk struct {
	Kid string `json:"kid"`
	Kty string `json:"kty"`
	Use string `json:"use"`
	Alg string `json:"alg"`
	N   string `json:"n"`
	E   string `json:"e"`
}

// claims is the subset of the Keycloak access-token payload we consume.
type claims struct {
	Iss               string   `json:"iss"`
	Exp               float64  `json:"exp"`
	Aud               audience `json:"aud"`
	PreferredUsername string   `json:"preferred_username"`
	Subject           string   `json:"sub"`
	Name              string   `json:"name"`
	Email             string   `json:"email"`
	Tenant            string   `json:"tenant"`
	Groups            []string `json:"groups"`
	RealmAccess       struct {
		Roles []string `json:"roles"`
	} `json:"realm_access"`
}

// audience decodes the JWT `aud` claim, which RFC 7519 §4.1.3 allows to be
// EITHER a single string OR an array of strings. Keycloak emits a single string
// for one audience and an array for several, so a plain []string tag would fail
// to unmarshal the common single-audience token.
type audience []string

func (a *audience) UnmarshalJSON(b []byte) error {
	var single string
	if err := json.Unmarshal(b, &single); err == nil {
		*a = audience{single}
		return nil
	}
	var many []string
	if err := json.Unmarshal(b, &many); err != nil {
		return err
	}
	*a = many
	return nil
}

func (a audience) contains(want string) bool {
	for _, v := range a {
		if v == want {
			return true
		}
	}
	return false
}

// Verify checks signature (RS256 via JWKS), issuer and expiry, then projects
// the identity claims. It returns an error for anything else than a valid,
// live token.
func (v *Verifier) Verify(ctx context.Context, token string) (*Identity, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("jwt: malformed token")
	}
	headRaw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, fmt.Errorf("jwt: decode header: %w", err)
	}
	var head struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	if err := json.Unmarshal(headRaw, &head); err != nil {
		return nil, fmt.Errorf("jwt: parse header: %w", err)
	}
	if head.Alg != "RS256" {
		return nil, fmt.Errorf("jwt: unsupported alg %q (RS256 only)", head.Alg)
	}

	key, err := v.key(ctx, head.Kid)
	if err != nil {
		return nil, err
	}

	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, fmt.Errorf("jwt: decode signature: %w", err)
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], sig); err != nil {
		return nil, fmt.Errorf("jwt: invalid signature")
	}

	payloadRaw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("jwt: decode payload: %w", err)
	}
	var c claims
	if err := json.Unmarshal(payloadRaw, &c); err != nil {
		return nil, fmt.Errorf("jwt: parse claims: %w", err)
	}
	if c.Iss != v.Issuer {
		return nil, fmt.Errorf("jwt: issuer %q does not match %q", c.Iss, v.Issuer)
	}
	if time.Now().Unix() >= int64(c.Exp) {
		return nil, fmt.Errorf("jwt: token expired")
	}
	if v.Audience != "" && !c.Aud.contains(v.Audience) {
		return nil, fmt.Errorf("jwt: audience %v does not contain %q", []string(c.Aud), v.Audience)
	}

	username := c.PreferredUsername
	if username == "" {
		username = c.Subject
	}
	if username == "" {
		username = "unknown"
	}
	return &Identity{
		Username: username,
		Subject:  c.Subject,
		Name:     c.Name,
		Email:    c.Email,
		Roles:    c.RealmAccess.Roles,
		Tenant:   c.Tenant,
		Groups:   c.Groups,
	}, nil
}

// key returns the RSA public key for kid, refreshing the JWKS cache when the
// TTL elapsed or the kid is unknown (key rotation).
func (v *Verifier) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	v.mu.Lock()
	defer v.mu.Unlock()

	fresh := time.Since(v.fetchedAt) < v.ttl
	if k, ok := v.keys[kid]; ok && fresh {
		return k, nil
	}
	// Unknown kid or stale cache -> refetch once.
	if err := v.fetchLocked(ctx); err != nil {
		// Keep serving a previously known key on transient JWKS failures.
		if k, ok := v.keys[kid]; ok {
			return k, nil
		}
		return nil, err
	}
	if k, ok := v.keys[kid]; ok {
		return k, nil
	}
	return nil, fmt.Errorf("jwt: signing key %q not found in JWKS", kid)
}

// fetchLocked refreshes the kid->key map from the JWKS endpoint. Caller holds
// the mutex.
func (v *Verifier) fetchLocked(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.JWKSURL, nil)
	if err != nil {
		return fmt.Errorf("jwks: build request: %w", err)
	}
	resp, err := v.client.Do(req)
	if err != nil {
		return fmt.Errorf("jwks: fetch %s: %w", v.JWKSURL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("jwks: fetch %s -> %d", v.JWKSURL, resp.StatusCode)
	}
	var doc struct {
		Keys []jwk `json:"keys"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return fmt.Errorf("jwks: decode: %w", err)
	}
	keys := map[string]*rsa.PublicKey{}
	for _, k := range doc.Keys {
		if k.Kty != "RSA" || (k.Use != "" && k.Use != "sig") {
			continue
		}
		pub, err := jwkToRSA(k)
		if err != nil {
			continue // skip malformed entries, keep the valid ones
		}
		keys[k.Kid] = pub
	}
	if len(keys) == 0 {
		return fmt.Errorf("jwks: no usable RSA signing keys at %s", v.JWKSURL)
	}
	v.keys = keys
	v.fetchedAt = time.Now()
	return nil
}

// jwkToRSA converts the base64url (n, e) JWK fields into an rsa.PublicKey.
func jwkToRSA(k jwk) (*rsa.PublicKey, error) {
	nRaw, err := base64.RawURLEncoding.DecodeString(k.N)
	if err != nil {
		return nil, fmt.Errorf("jwk %s: decode n: %w", k.Kid, err)
	}
	eRaw, err := base64.RawURLEncoding.DecodeString(k.E)
	if err != nil {
		return nil, fmt.Errorf("jwk %s: decode e: %w", k.Kid, err)
	}
	e := 0
	for _, b := range eRaw {
		e = e<<8 | int(b)
	}
	if e <= 0 {
		return nil, fmt.Errorf("jwk %s: invalid exponent", k.Kid)
	}
	return &rsa.PublicKey{N: new(big.Int).SetBytes(nRaw), E: e}, nil
}
