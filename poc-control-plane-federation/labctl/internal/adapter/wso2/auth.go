package wso2

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/url"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// dcrRequest is the body of the API-M Dynamic Client Registration call. saasApp
// lets the client be reused across tenants; the grantType string is space
// separated as WSO2 expects.
type dcrRequest struct {
	CallbackURL string `json:"callbackUrl"`
	ClientName  string `json:"clientName"`
	Owner       string `json:"owner"`
	GrantType   string `json:"grantType"`
	SaasApp     bool   `json:"saasApp"`
}

// dcrResponse carries the OAuth client credentials minted by DCR.
type dcrResponse struct {
	ClientID     string `json:"clientId"`
	ClientSecret string `json:"clientSecret"`
}

// tokenResponse is the OAuth2 token endpoint reply.
type tokenResponse struct {
	AccessToken string `json:"access_token"`
	TokenType   string `json:"token_type"`
	ExpiresIn   int    `json:"expires_in"`
	Scope       string `json:"scope"`
}

// basicAuth builds an "Authorization: Basic ..." header value.
func basicAuth(user, pass string) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(user+":"+pass))
}

// register performs Dynamic Client Registration for one REST API client
// (Publisher or DevPortal). The DCR endpoint lives at the host root
// (/client-registration/v0.17/register), NOT under the REST API basepath, and is
// guarded by Basic admin:admin.
func (c *Client) register(ctx context.Context, clientName string) (dcrResponse, error) {
	var out dcrResponse
	req := dcrRequest{
		CallbackURL: "https://localhost",
		ClientName:  clientName,
		Owner:       c.username,
		GrantType:   "password refresh_token client_credentials",
		SaasApp:     true,
	}
	headers := map[string]string{"Authorization": basicAuth(c.username, c.password)}
	if _, err := httpx.JSON(ctx, c.hc, "POST", c.adminURL+dcrPath, headers, req, &out); err != nil {
		return out, fmt.Errorf("dcr register %q: %w", clientName, err)
	}
	if out.ClientID == "" || out.ClientSecret == "" {
		return out, fmt.Errorf("dcr register %q: empty clientId/clientSecret in response", clientName)
	}
	return out, nil
}

// passwordGrant exchanges DCR client credentials for an access token via the
// password grant, requesting the given (space-separated) scope. The token
// endpoint is form-encoded with the client's Basic auth.
func (c *Client) passwordGrant(ctx context.Context, dcr dcrResponse, scope string) (string, error) {
	form := url.Values{}
	form.Set("grant_type", "password")
	form.Set("username", c.username)
	form.Set("password", c.password)
	form.Set("scope", scope)

	headers := map[string]string{
		"Authorization": basicAuth(dcr.ClientID, dcr.ClientSecret),
		"Content-Type":  "application/x-www-form-urlencoded",
		"Accept":        "application/json",
	}
	code, raw, err := httpx.Do(ctx, c.hc, "POST", c.adminURL+tokenPath, headers,
		strings.NewReader(form.Encode()))
	if err != nil {
		return "", fmt.Errorf("token (password grant): %w", err)
	}
	if code < 200 || code >= 300 {
		return "", fmt.Errorf("token (password grant) -> %d: %s", code, string(raw))
	}
	var out tokenResponse
	if err := unmarshalJSON(raw, &out); err != nil {
		return "", fmt.Errorf("token (password grant): decode response: %w", err)
	}
	if out.AccessToken == "" {
		return "", fmt.Errorf("token (password grant): empty access_token")
	}
	return out.AccessToken, nil
}

// ensureToken returns a cached Publisher token or mints one (DCR + password
// grant) with the Publisher scope superset. Thread-safe.
func (c *Client) ensureToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.publisherToken != "" {
		return c.publisherToken, nil
	}
	dcr, err := c.register(ctx, "rest_api_publisher")
	if err != nil {
		return "", err
	}
	tok, err := c.passwordGrant(ctx, dcr, publisherScope)
	if err != nil {
		return "", err
	}
	c.publisherToken = tok
	return tok, nil
}

// ensureDevportalToken returns a cached DevPortal token or mints one with the
// subscribe/app_manage/api_key scopes. Thread-safe.
func (c *Client) ensureDevportalToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.devportalToken != "" {
		return c.devportalToken, nil
	}
	dcr, err := c.register(ctx, "rest_api_devportal")
	if err != nil {
		return "", err
	}
	tok, err := c.passwordGrant(ctx, dcr, devportalScope)
	if err != nil {
		return "", err
	}
	c.devportalToken = tok
	return tok, nil
}
