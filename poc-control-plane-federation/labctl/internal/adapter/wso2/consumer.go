package wso2

import (
	"context"
	"fmt"
	"net/url"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// --- DevPortal REST API DTOs -------------------------------------------------

type devApplication struct {
	ApplicationID    string `json:"applicationId"`
	Name             string `json:"name"`
	ThrottlingPolicy string `json:"throttlingPolicy"`
	Description      string `json:"description"`
}

type devApplicationList struct {
	Count int              `json:"count"`
	List  []devApplication `json:"list"`
}

type devAPIList struct {
	Count int          `json:"count"`
	List  []apiSummary `json:"list"`
}

type subscriptionResponse struct {
	SubscriptionID string `json:"subscriptionId"`
	APIID          string `json:"apiId"`
	ApplicationID  string `json:"applicationId"`
}

// subscriptionList is the GET /subscriptions response used to probe for an
// existing (app, api) subscription before POSTing a new one.
type subscriptionList struct {
	Count int                    `json:"count"`
	List  []subscriptionResponse `json:"list"`
}

// mapKeysRequest maps an externally-minted OAuth client (Keycloak) onto the
// application instead of self-issuing keys.
type mapKeysRequest struct {
	ConsumerKey    string `json:"consumerKey"`
	ConsumerSecret string `json:"consumerSecret"`
	KeyType        string `json:"keyType"`
	KeyManager     string `json:"keyManager"`
}

// generateKeysRequest self-issues keys. validityTime is a STRING per the
// ApplicationKeyGenerateRequest schema (verdict correction — quoting avoids 400
// on strict deployments).
type generateKeysRequest struct {
	KeyType                 string   `json:"keyType"`
	GrantTypesToBeSupported []string `json:"grantTypesToBeSupported"`
	ValidityTime            string   `json:"validityTime"`
	CallbackURL             string   `json:"callbackUrl"`
}

// keyResponse is returned by both map-keys and generate-keys.
type keyResponse struct {
	ConsumerKey    string `json:"consumerKey"`
	ConsumerSecret string `json:"consumerSecret"`
	KeyType        string `json:"keyType"`
}

// CreateConsumer provisions a DevPortal application, subscribes it to api, and
// wires its OAuth keys (mapping the Keycloak client when ClientID is supplied,
// else self-issuing). Idempotent on (api, application name): an existing
// application is reused. Order matters — subscribe MUST precede key generation.
func (c *Client) CreateConsumer(ctx context.Context, api *adapter.NormalizedAPI, spec *adapter.ConsumerSpec) (*adapter.ConsumerResult, error) {
	ctx, cancel := withDeadline(ctx)
	defer cancel()

	tok, err := c.ensureDevportalToken(ctx)
	if err != nil {
		return nil, fmt.Errorf("wso2 consumer: %w", err)
	}

	// 1. Resolve the API id in the DevPortal (only PUBLISHED APIs appear here).
	devAPIID, err := c.resolveDevAPI(ctx, tok, api)
	if err != nil {
		return nil, err
	}

	// 2. Create (or reuse) the consumer application.
	appID, err := c.findOrCreateApplication(ctx, tok, spec)
	if err != nil {
		return nil, err
	}

	// 3. Subscribe the application to the API (must precede key generation).
	subID, err := c.subscribe(ctx, tok, devAPIID, appID, spec)
	if err != nil {
		return nil, err
	}

	// 4. Wire keys: map an external client when provided, else self-issue.
	keys, err := c.wireKeys(ctx, tok, appID, spec)
	if err != nil {
		return nil, err
	}

	return &adapter.ConsumerResult{
		Gateway:        "wso2",
		ConsumerID:     appID,
		SubscriptionID: subID,
		ConsumerKey:    keys.ConsumerKey,
		ConsumerSecret: keys.ConsumerSecret,
		TokenHint: fmt.Sprintf(
			"POST %s%s Basic(consumerKey:consumerSecret) grant_type=client_credentials; "+
				"then GET %s with Bearer <token>",
			c.adminURL, tokenPath, c.invocationURL(api.BasePath)),
	}, nil
}

// resolveDevAPI finds the DevPortal apiId matching api name+version.
func (c *Client) resolveDevAPI(ctx context.Context, tok string, api *adapter.NormalizedAPI) (string, error) {
	var out devAPIList
	if _, err := httpx.JSON(ctx, c.hc, "GET",
		c.adminURL+devportalBase+"/apis?query="+queryEscape(api.Name),
		bearer(tok), nil, &out); err != nil {
		return "", fmt.Errorf("wso2 consumer: list devportal apis: %w", err)
	}
	for _, a := range out.List {
		if a.Name == api.Name && a.Version == api.Version {
			return a.ID, nil
		}
	}
	// Fall back to a name-only match when version is not echoed in the summary.
	for _, a := range out.List {
		if a.Name == api.Name {
			return a.ID, nil
		}
	}
	return "", fmt.Errorf("wso2 consumer: api %q v%s not found in devportal (is it Published?)",
		api.Name, api.Version)
}

// findOrCreateApplication returns an existing application id by name, or creates
// one. Idempotent on the application name.
func (c *Client) findOrCreateApplication(ctx context.Context, tok string, spec *adapter.ConsumerSpec) (string, error) {
	var list devApplicationList
	if _, err := httpx.JSON(ctx, c.hc, "GET",
		c.adminURL+devportalBase+"/applications?query="+queryEscape(spec.Name),
		bearer(tok), nil, &list); err != nil {
		return "", fmt.Errorf("wso2 consumer: list applications: %w", err)
	}
	for _, a := range list.List {
		if a.Name == spec.Name {
			return a.ApplicationID, nil
		}
	}

	throttle := spec.ThrottlingPolicy
	if throttle == "" {
		throttle = defaultThrottle
	}
	in := devApplication{
		Name:             spec.Name,
		ThrottlingPolicy: throttle,
		Description:      "labctl consumer",
	}
	var out devApplication
	if _, err := httpx.JSON(ctx, c.hc, "POST",
		c.adminURL+devportalBase+"/applications", bearer(tok), in, &out); err != nil {
		return "", fmt.Errorf("wso2 consumer: create application: %w", err)
	}
	if out.ApplicationID == "" {
		return "", fmt.Errorf("wso2 consumer: create application returned empty applicationId")
	}
	return out.ApplicationID, nil
}

// subscribe binds the application to the API and returns the subscription id.
// Idempotent: an existing (app, api) subscription is reused instead of POSTing a
// duplicate (which WSO2 DevPortal rejects with 409).
func (c *Client) subscribe(ctx context.Context, tok, devAPIID, appID string, spec *adapter.ConsumerSpec) (string, error) {
	// Idempotency probe: reuse an existing subscription for this app+api.
	var existing subscriptionList
	if _, err := httpx.JSON(ctx, c.hc, "GET",
		c.adminURL+devportalBase+"/subscriptions?applicationId="+queryEscape(appID),
		bearer(tok), nil, &existing); err != nil {
		return "", fmt.Errorf("wso2 consumer: list subscriptions: %w", err)
	}
	for _, s := range existing.List {
		if s.APIID == devAPIID && s.SubscriptionID != "" {
			return s.SubscriptionID, nil
		}
	}

	throttle := spec.ThrottlingPolicy
	if throttle == "" {
		throttle = defaultThrottle
	}
	in := map[string]string{
		"apiId":            devAPIID,
		"applicationId":    appID,
		"throttlingPolicy": throttle,
	}
	var out subscriptionResponse
	if _, err := httpx.JSON(ctx, c.hc, "POST",
		c.adminURL+devportalBase+"/subscriptions", bearer(tok), in, &out); err != nil {
		return "", fmt.Errorf("wso2 consumer: subscribe: %w", err)
	}
	if out.SubscriptionID == "" {
		return "", fmt.Errorf("wso2 consumer: subscribe returned empty subscriptionId")
	}
	return out.SubscriptionID, nil
}

// wireKeys maps an externally-minted OAuth client (when spec.ClientID is set) or
// self-issues a key pair via generate-keys.
func (c *Client) wireKeys(ctx context.Context, tok, appID string, spec *adapter.ConsumerSpec) (keyResponse, error) {
	var out keyResponse
	if spec.ClientID != "" {
		in := mapKeysRequest{
			ConsumerKey:    spec.ClientID,
			ConsumerSecret: spec.ClientSecret,
			KeyType:        "PRODUCTION",
			KeyManager:     residentKeyMgr,
		}
		if _, err := httpx.JSON(ctx, c.hc, "POST",
			c.adminURL+devportalBase+"/applications/"+url.PathEscape(appID)+"/map-keys",
			bearer(tok), in, &out); err != nil {
			return out, fmt.Errorf("wso2 consumer: map-keys: %w", err)
		}
		// map-keys may not echo the secret back; keep the supplied one.
		if out.ConsumerKey == "" {
			out.ConsumerKey = spec.ClientID
		}
		if out.ConsumerSecret == "" {
			out.ConsumerSecret = spec.ClientSecret
		}
		return out, nil
	}

	in := generateKeysRequest{
		KeyType:                 "PRODUCTION",
		GrantTypesToBeSupported: []string{"client_credentials", "password", "refresh_token"},
		ValidityTime:            "3600",
		CallbackURL:             "https://localhost",
	}
	if _, err := httpx.JSON(ctx, c.hc, "POST",
		c.adminURL+devportalBase+"/applications/"+url.PathEscape(appID)+"/generate-keys",
		bearer(tok), in, &out); err != nil {
		return out, fmt.Errorf("wso2 consumer: generate-keys: %w", err)
	}
	if out.ConsumerKey == "" {
		return out, fmt.Errorf("wso2 consumer: generate-keys returned empty consumerKey")
	}
	return out, nil
}
