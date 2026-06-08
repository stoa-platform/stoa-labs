// Package wso2 implements the adapter.Adapter contract for WSO2 API Manager
// 4.5.0 (all-in-one image). It drives the Publisher REST API v4 (control plane,
// :9443) and the DevPortal REST API v3 to take a NormalizedAPI from zero to
// "live on the gateway AND PUBLISHED/subscribable", and to provision consumer
// applications against the data plane (:8243).
//
// The full publish flow (see Publish) is, in order:
//
//	DCR register -> password-grant token -> import-openapi (201) ->
//	create revision -> deploy-revision (200) -> change-lifecycle=Publish (200).
//
// Both deploy-revision AND change-lifecycle are required: deploy puts the API on
// the gateway, Publish makes it visible/subscribable in the DevPortal. They are
// independent concerns in 4.x.
package wso2

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

func init() { adapter.Register("wso2", New) }

// REST API base paths and the (non-basepath) DCR/token endpoints for WSO2 4.5.0.
const (
	dcrPath          = "/client-registration/v0.17/register"
	tokenPath        = "/oauth2/token"
	publisherBase    = "/api/am/publisher/v4"
	devportalBase    = "/api/am/devportal/v3"
	residentKeyMgr   = "Resident Key Manager"
	defaultThrottle  = "Unlimited"
	defaultGatewayID = "Default"
	defaultVhost     = "localhost"

	// Scope supersets: import/create needs apim:api_create, lifecycle needs
	// apim:api_publish; api_manage covers broad ops. A single shared token with
	// all three avoids re-tokenising per step.
	publisherScope = "apim:api_create apim:api_publish apim:api_manage"
	devportalScope = "apim:subscribe apim:app_manage apim:api_key"
)

// Client is the WSO2 adapter bound to one target gateway. It is safe for
// concurrent use: token caches are guarded by mu.
type Client struct {
	cfg adapter.Config
	hc  *http.Client

	adminURL   string // e.g. https://wso2am:9443 (control plane), no trailing slash
	gatewayURL string // e.g. https://wso2am:8243 (data plane), no trailing slash

	username string
	password string

	gatewayEnv string // deploy-revision "name" (default "Default")
	vhost      string // deploy-revision "vhost" (default "localhost")

	mu             sync.Mutex
	publisherToken string
	devportalToken string
}

// compile-time assertion that Client satisfies the adapter contract.
var _ adapter.Adapter = (*Client)(nil)

// New builds a WSO2 adapter from a target descriptor. It reads admin/gateway
// URLs, basic admin credentials (default admin/admin) and the optional
// gatewayEnv/vhost knobs, and wires an httpx client honouring cfg.Insecure for
// WSO2's self-signed TLS.
func New(cfg adapter.Config) (adapter.Adapter, error) {
	if cfg.AdminURL == "" {
		return nil, fmt.Errorf("wso2: AdminURL is required (control-plane :9443)")
	}
	gw := cfg.GatewayURL
	if gw == "" {
		// Fall back to the conventional :8243 data plane on the admin host.
		gw = strings.Replace(strings.TrimRight(cfg.AdminURL, "/"), ":9443", ":8243", 1)
	}
	return &Client{
		cfg:        cfg,
		hc:         httpx.NewClient(cfg.Insecure),
		adminURL:   strings.TrimRight(cfg.AdminURL, "/"),
		gatewayURL: strings.TrimRight(gw, "/"),
		username:   cfg.Cred("username", "admin"),
		password:   cfg.Cred("password", "admin"),
		gatewayEnv: cfg.Opt("gatewayEnv", defaultGatewayID),
		vhost:      cfg.Opt("vhost", defaultVhost),
	}, nil
}

// Name returns the stable gateway identifier.
func (c *Client) Name() string { return "wso2" }

// Health performs a cheap auth preflight: it acquires a Publisher token (DCR +
// password grant) and lists APIs. A failure here means the control plane is
// unreachable or the admin credentials/scopes are rejected.
func (c *Client) Health(ctx context.Context) error {
	tok, err := c.ensureToken(ctx)
	if err != nil {
		return fmt.Errorf("wso2 health: %w", err)
	}
	var out apiSearchResponse
	if _, err := httpx.JSON(ctx, c.hc, "GET",
		c.adminURL+publisherBase+"/apis?limit=1", bearer(tok), nil, &out); err != nil {
		return fmt.Errorf("wso2 health: list apis: %w", err)
	}
	return nil
}

// List returns the APIs currently published on this gateway (Publisher view).
func (c *Client) List(ctx context.Context) ([]adapter.PublishedAPI, error) {
	tok, err := c.ensureToken(ctx)
	if err != nil {
		return nil, fmt.Errorf("wso2 list: %w", err)
	}
	var out apiSearchResponse
	if _, err := httpx.JSON(ctx, c.hc, "GET",
		c.adminURL+publisherBase+"/apis?limit=200", bearer(tok), nil, &out); err != nil {
		return nil, fmt.Errorf("wso2 list: %w", err)
	}
	apis := make([]adapter.PublishedAPI, 0, len(out.List))
	for _, a := range out.List {
		apis = append(apis, adapter.PublishedAPI{
			Gateway:  "wso2",
			APIID:    a.ID,
			Name:     a.Name,
			Version:  a.Version,
			BasePath: a.Context,
		})
	}
	return apis, nil
}

// bearer is the standard Authorization header map for an access token.
func bearer(token string) map[string]string {
	return map[string]string{"Authorization": "Bearer " + token}
}

// invocationURL builds the live data-plane URL for an API, e.g.
// https://localhost:8243/accounts-read/v1/1.0.0. WSO2's default version
// strategy puts the version IN the path: {gateway}/{context}/{version}.
// Verified against the live gateway — omitting the version 404s; including it
// routes and enforces auth (401 without a token).
func (c *Client) invocationURL(basePath, version string) string {
	u := c.gatewayURL + "/" + strings.TrimLeft(basePath, "/")
	if version != "" {
		u += "/" + version
	}
	return u
}

// withDeadline returns ctx unchanged when it already has a deadline, else adds a
// conservative one so a hung gateway cannot block apply forever.
func withDeadline(ctx context.Context) (context.Context, context.CancelFunc) {
	if _, ok := ctx.Deadline(); ok {
		return ctx, func() {}
	}
	return context.WithTimeout(ctx, 90*time.Second)
}

// queryEscape is a thin alias kept local so call sites read clearly.
func queryEscape(s string) string { return url.QueryEscape(s) }
