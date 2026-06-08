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
