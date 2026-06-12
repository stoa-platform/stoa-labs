// Package keycloak mints the out-of-band OAuth client that `labctl subscribe`
// hands to every gateway adapter's CreateConsumer.
//
// In the "Define Once, Expose Everywhere" flow the data-plane credential is a
// single confidential OAuth client living in Keycloak: WSO2 maps it via
// /map-keys, webMethods stores its clientId on the subscription, and APISIX (for
// the oauth2/JWT path) validates tokens issued for it. So before any adapter can
// bind a consumer we must guarantee the client EXISTS in the target realm and we
// must know its secret. EnsureClient does exactly that and is idempotent: a
// second `labctl subscribe` converges onto the same client instead of failing or
// duplicating it.
//
// It speaks the Keycloak Admin REST API directly (no SDK): an admin token from
// the master realm, then a list/create on /admin/realms/{realm}/clients, then a
// read of the generated client-secret.
package keycloak

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// Config is the input to EnsureClient, projected from targets.yaml's Keycloak
// block by `labctl subscribe`.
type Config struct {
	// URL is the Keycloak base URL with no trailing slash
	// (e.g. "https://keycloak:8443" or "http://keycloak:8080").
	URL string

	// Realm is the target realm the client is minted in (e.g. "stoa"). The admin
	// token is always obtained from the "master" realm regardless of this value.
	Realm string

	// AdminUser / AdminPassword are the master-realm admin credentials used with
	// the built-in admin-cli public client (password grant) to obtain a token.
	AdminUser     string
	AdminPassword string

	// ClientID is the OAuth clientId to ensure (the human-facing identifier, NOT
	// the internal UUID). EnsureClient looks this up and creates it if absent.
	ClientID string

	// ClientSecret, when non-empty, is the desired secret seeded at creation time
	// (so the caller can pin a known secret). When empty, Keycloak generates one
	// and EnsureClient reads it back. On an existing client this field is ignored;
	// the already-registered secret is returned.
	ClientSecret string

	// Insecure skips TLS verification. Kept false by default: Keycloak in the PoC
	// terminates TLS with a trusted/plain cert, unlike WSO2's self-signed gateway.
	Insecure bool
}

// tokenResponse is the master-realm token endpoint payload (only the access
// token is consumed).
type tokenResponse struct {
	AccessToken string `json:"access_token"`
}

// clientRep is the subset of the Keycloak ClientRepresentation we read on list
// (id) and write on create.
type clientRep struct {
	ID                     string `json:"id,omitempty"`
	ClientID               string `json:"clientId"`
	Secret                 string `json:"secret,omitempty"`
	ServiceAccountsEnabled bool   `json:"serviceAccountsEnabled"`
	StandardFlowEnabled    bool   `json:"standardFlowEnabled"`
	PublicClient           bool   `json:"publicClient"`
}

// secretRep is the /client-secret endpoint payload (a CredentialRepresentation).
type secretRep struct {
	Value string `json:"value"`
}

// ConsumerAuthConfig parametrises EnsureConsumerAuth: the OAuth2 audience the
// consumer's tokens must carry and the client scope they must request, both
// projected from a target's inboundAuth block by `labctl subscribe`.
type ConsumerAuthConfig struct {
	Config

	// Audience is the value written into the access token's `aud` claim by an
	// audience protocol mapper on the consumer client. It MUST equal the gateway
	// strategy/scope audience (webMethods inboundAuth.audience).
	Audience string

	// Scope is the OAuth scope the consumer must carry. EnsureConsumerAuth
	// guarantees a realm client-scope of this name exists (with
	// include.in.token.scope=true) and assigns it as a DEFAULT client scope on
	// the consumer client, so the standard authorization_code/broker token —
	// which requests a fixed `scope=openid` — still carries it (the spike's
	// get-oracle-token.sh hardcodes scope=openid, so an OPTIONAL scope would be
	// absent and the legitimate consumer would be 401 on the gateway scope gate).
	Scope string
}

// protocolMapper is the subset of a Keycloak ProtocolMapperRepresentation the
// audience mapper read/write touches.
type protocolMapper struct {
	ID             string            `json:"id,omitempty"`
	Name           string            `json:"name"`
	Protocol       string            `json:"protocol"`
	ProtocolMapper string            `json:"protocolMapper"`
	ConsentReq     bool              `json:"consentRequired"`
	Config         map[string]string `json:"config"`
}

// clientScope is the subset of a Keycloak ClientScopeRepresentation we read on
// list (id+name) and write on create.
type clientScope struct {
	ID          string            `json:"id,omitempty"`
	Name        string            `json:"name"`
	Description string            `json:"description,omitempty"`
	Protocol    string            `json:"protocol"`
	Attributes  map[string]string `json:"attributes,omitempty"`
}

// EnsureConsumerAuth converges the Keycloak-side OAuth2 enforcement inputs on an
// EXISTING consumer client (minted first by EnsureClient): an audience protocol
// mapper writing aud=cfg.Audience into the access token, and a realm client
// scope cfg.Scope assigned as a DEFAULT scope so the consumer token always
// carries it. It is idempotent — the mapper is created only if absent (matched
// by protocolMapper type + audience), the scope is created only if absent, and
// the DEFAULT assignment is a PUT (no-op when already assigned).
//
// No-op when both Audience and Scope are empty (the signature-only path needs
// neither). A half-filled request (one without the other) is rejected: the
// gateway OAuth2 path enforces BOTH, so leaving one off would desync the token
// from the gateway barrier.
func EnsureConsumerAuth(ctx context.Context, cfg ConsumerAuthConfig) error {
	if cfg.Audience == "" && cfg.Scope == "" {
		return nil
	}
	if cfg.Audience == "" || cfg.Scope == "" {
		return fmt.Errorf("keycloak: consumer auth needs both audience and scope (got audience=%q scope=%q)", cfg.Audience, cfg.Scope)
	}
	if cfg.URL == "" || cfg.Realm == "" || cfg.ClientID == "" {
		return fmt.Errorf("keycloak: consumer auth: URL, Realm and ClientID are required")
	}
	base := strings.TrimRight(cfg.URL, "/")
	client := httpx.NewClient(cfg.Insecure)

	token, err := adminToken(ctx, client, base, cfg.Config)
	if err != nil {
		return fmt.Errorf("keycloak: admin token: %w", err)
	}
	auth := map[string]string{"Authorization": "Bearer " + token}

	clientUUID, err := clientUUIDByClientID(ctx, client, base, cfg.Realm, cfg.ClientID, auth)
	if err != nil {
		return fmt.Errorf("keycloak: resolve consumer client %q: %w", cfg.ClientID, err)
	}

	if err := ensureAudienceMapper(ctx, client, base, cfg.Realm, clientUUID, cfg.Audience, auth); err != nil {
		return fmt.Errorf("keycloak: audience mapper: %w", err)
	}
	if err := ensureDefaultClientScope(ctx, client, base, cfg.Realm, clientUUID, cfg.Scope, auth); err != nil {
		return fmt.Errorf("keycloak: client scope %q: %w", cfg.Scope, err)
	}
	return nil
}

// clientUUIDByClientID resolves the internal UUID of an existing client by its
// clientId.
func clientUUIDByClientID(ctx context.Context, client *http.Client, base, realm, clientID string, auth map[string]string) (string, error) {
	listURL := fmt.Sprintf("%s/admin/realms/%s/clients?clientId=%s",
		base, url.PathEscape(realm), url.QueryEscape(clientID))
	var found []clientRep
	if _, err := httpx.JSON(ctx, client, "GET", listURL, auth, nil, &found); err != nil {
		return "", fmt.Errorf("list clients: %w", err)
	}
	if len(found) == 0 || found[0].ID == "" {
		return "", fmt.Errorf("client %q not found", clientID)
	}
	return found[0].ID, nil
}

// ensureAudienceMapper creates the oidc-audience-mapper on the client only if no
// mapper already writes that custom audience into the access token (idempotent —
// re-runs never duplicate it).
func ensureAudienceMapper(ctx context.Context, client *http.Client, base, realm, clientUUID, audience string, auth map[string]string) error {
	modelsURL := fmt.Sprintf("%s/admin/realms/%s/clients/%s/protocol-mappers/models",
		base, url.PathEscape(realm), url.PathEscape(clientUUID))
	var existing []protocolMapper
	if _, err := httpx.JSON(ctx, client, "GET", modelsURL, auth, nil, &existing); err != nil {
		return fmt.Errorf("list protocol mappers: %w", err)
	}
	for _, m := range existing {
		if m.ProtocolMapper == "oidc-audience-mapper" && m.Config["included.custom.audience"] == audience {
			return nil // already present
		}
	}
	body := protocolMapper{
		Name:           audience + "-audience",
		Protocol:       "openid-connect",
		ProtocolMapper: "oidc-audience-mapper",
		ConsentReq:     false,
		Config: map[string]string{
			"included.custom.audience":  audience,
			"id.token.claim":            "false",
			"access.token.claim":        "true",
			"introspection.token.claim": "true",
		},
	}
	if _, err := httpx.JSON(ctx, client, "POST", modelsURL, auth, body, nil); err != nil {
		return fmt.Errorf("create audience mapper: %w", err)
	}
	return nil
}

// ensureDefaultClientScope guarantees a realm client scope named scopeName
// exists (include.in.token.scope=true) and is assigned as a DEFAULT client scope
// on the consumer client. Default (not optional) so the fixed scope=openid token
// request still carries it.
func ensureDefaultClientScope(ctx context.Context, client *http.Client, base, realm, clientUUID, scopeName string, auth map[string]string) error {
	scopeID, err := ensureClientScopeExists(ctx, client, base, realm, scopeName, auth)
	if err != nil {
		return err
	}
	assignURL := fmt.Sprintf("%s/admin/realms/%s/clients/%s/default-client-scopes/%s",
		base, url.PathEscape(realm), url.PathEscape(clientUUID), url.PathEscape(scopeID))
	// PUT is idempotent: assigning an already-default scope is a no-op 204.
	if _, err := httpx.JSON(ctx, client, "PUT", assignURL, auth, nil, nil); err != nil {
		return fmt.Errorf("assign default client scope: %w", err)
	}
	return nil
}

// ensureClientScopeExists returns the id of the realm client scope named
// scopeName, creating it (openid-connect, include.in.token.scope=true) if absent.
func ensureClientScopeExists(ctx context.Context, client *http.Client, base, realm, scopeName string, auth map[string]string) (string, error) {
	scopesURL := fmt.Sprintf("%s/admin/realms/%s/client-scopes", base, url.PathEscape(realm))
	var scopes []clientScope
	if _, err := httpx.JSON(ctx, client, "GET", scopesURL, auth, nil, &scopes); err != nil {
		return "", fmt.Errorf("list client scopes: %w", err)
	}
	for _, s := range scopes {
		if s.Name == scopeName && s.ID != "" {
			return s.ID, nil
		}
	}
	body := clientScope{
		Name:        scopeName,
		Description: "labctl: scope required by the gateway OAuth2 barrier",
		Protocol:    "openid-connect",
		Attributes: map[string]string{
			"include.in.token.scope":    "true",
			"display.on.consent.screen": "false",
		},
	}
	if _, err := httpx.JSON(ctx, client, "POST", scopesURL, auth, body, nil); err != nil {
		return "", fmt.Errorf("create client scope: %w", err)
	}
	// Re-list to resolve the new id (Keycloak returns 201 + Location, empty body).
	scopes = nil
	if _, err := httpx.JSON(ctx, client, "GET", scopesURL, auth, nil, &scopes); err != nil {
		return "", fmt.Errorf("list client scopes after create: %w", err)
	}
	for _, s := range scopes {
		if s.Name == scopeName && s.ID != "" {
			return s.ID, nil
		}
	}
	return "", fmt.Errorf("client scope %q not found after create", scopeName)
}

// EnsureClient guarantees a confidential OAuth client named cfg.ClientID exists
// in cfg.Realm and returns its (clientID, clientSecret). It is idempotent.
//
// Steps, each error-wrapped with its stage so failures are actionable:
//  1. obtain an admin token from the master realm (admin-cli password grant);
//  2. look the client up by clientId; create it (confidential, service-accounts
//     + standard flow enabled) only if absent;
//  3. read back the generated/seeded secret.
func EnsureClient(ctx context.Context, cfg Config) (clientID, clientSecret string, err error) {
	if cfg.URL == "" || cfg.Realm == "" || cfg.ClientID == "" {
		return "", "", fmt.Errorf("keycloak: URL, Realm and ClientID are required")
	}
	base := strings.TrimRight(cfg.URL, "/")
	client := httpx.NewClient(cfg.Insecure)

	token, err := adminToken(ctx, client, base, cfg)
	if err != nil {
		return "", "", fmt.Errorf("keycloak: admin token: %w", err)
	}
	auth := map[string]string{"Authorization": "Bearer " + token}

	id, err := ensureClientUUID(ctx, client, base, cfg, auth)
	if err != nil {
		return "", "", fmt.Errorf("keycloak: ensure client %q: %w", cfg.ClientID, err)
	}

	secret, err := clientSecretValue(ctx, client, base, cfg.Realm, id, auth)
	if err != nil {
		return "", "", fmt.Errorf("keycloak: read secret for %q: %w", cfg.ClientID, err)
	}

	return cfg.ClientID, secret, nil
}

// adminToken performs the master-realm password grant against the admin-cli
// public client. It uses httpx.Do (not JSON) because the token endpoint is
// form-urlencoded, not JSON.
func adminToken(ctx context.Context, client *http.Client, base string, cfg Config) (string, error) {
	endpoint := base + "/realms/master/protocol/openid-connect/token"
	form := url.Values{
		"client_id":  {"admin-cli"},
		"username":   {cfg.AdminUser},
		"password":   {cfg.AdminPassword},
		"grant_type": {"password"},
	}
	headers := map[string]string{
		"Content-Type": "application/x-www-form-urlencoded",
		"Accept":       "application/json",
	}
	code, raw, err := httpx.Do(ctx, client, "POST", endpoint, headers, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	if code < 200 || code >= 300 {
		return "", fmt.Errorf("POST %s -> %d: %s", endpoint, code, snippet(raw))
	}
	var tr tokenResponse
	if err := json.Unmarshal(raw, &tr); err != nil {
		return "", fmt.Errorf("decode token response: %w", err)
	}
	if tr.AccessToken == "" {
		return "", fmt.Errorf("token response carried no access_token")
	}
	return tr.AccessToken, nil
}

// ensureClientUUID returns the internal UUID of the client, looking it up by
// clientId and creating it (confidential) when absent.
func ensureClientUUID(ctx context.Context, client *http.Client, base string, cfg Config, auth map[string]string) (string, error) {
	listURL := fmt.Sprintf("%s/admin/realms/%s/clients?clientId=%s",
		base, url.PathEscape(cfg.Realm), url.QueryEscape(cfg.ClientID))
	var found []clientRep
	if _, err := httpx.JSON(ctx, client, "GET", listURL, auth, nil, &found); err != nil {
		return "", fmt.Errorf("list clients: %w", err)
	}
	if len(found) > 0 {
		if found[0].ID == "" {
			return "", fmt.Errorf("existing client %q has empty id", cfg.ClientID)
		}
		return found[0].ID, nil
	}

	// Not found -> create a confidential client. We pass the desired secret only
	// when the caller pinned one; otherwise Keycloak generates it and we read it
	// back in clientSecretValue.
	body := clientRep{
		ClientID:               cfg.ClientID,
		ServiceAccountsEnabled: true,
		StandardFlowEnabled:    true,
		PublicClient:           false,
	}
	if cfg.ClientSecret != "" {
		body.Secret = cfg.ClientSecret
	}
	createURL := fmt.Sprintf("%s/admin/realms/%s/clients", base, url.PathEscape(cfg.Realm))
	if _, err := httpx.JSON(ctx, client, "POST", createURL, auth, body, nil); err != nil {
		return "", fmt.Errorf("create client: %w", err)
	}

	// Keycloak returns the new UUID in the Location header and an empty body, so
	// we re-list to resolve the id uniformly (and to converge if a concurrent
	// `subscribe` created it first).
	found = nil
	if _, err := httpx.JSON(ctx, client, "GET", listURL, auth, nil, &found); err != nil {
		return "", fmt.Errorf("list clients after create: %w", err)
	}
	if len(found) == 0 || found[0].ID == "" {
		return "", fmt.Errorf("client %q not found after create", cfg.ClientID)
	}
	return found[0].ID, nil
}

// clientSecretValue reads the confidential client's secret value.
func clientSecretValue(ctx context.Context, client *http.Client, base, realm, id string, auth map[string]string) (string, error) {
	secretURL := fmt.Sprintf("%s/admin/realms/%s/clients/%s/client-secret",
		base, url.PathEscape(realm), url.PathEscape(id))
	var sr secretRep
	if _, err := httpx.JSON(ctx, client, "GET", secretURL, auth, nil, &sr); err != nil {
		return "", fmt.Errorf("get client-secret: %w", err)
	}
	if sr.Value == "" {
		return "", fmt.Errorf("client-secret endpoint returned an empty value")
	}
	return sr.Value, nil
}

// snippet trims a raw error body so token-endpoint failures stay readable in
// wrapped diagnostics.
func snippet(b []byte) string {
	const max = 300
	s := strings.TrimSpace(string(b))
	if len(s) <= max {
		return s
	}
	return s[:max] + "…"
}
