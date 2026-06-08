// Package webmethods is the labctl gateway driver for a webMethods API Gateway
// (apigateway:10.15 stand-in). It targets the PoC mock that exposes the admin
// surface under /rest/apigateway/* and the data-plane under /gateway/*.
//
// What makes this gateway distinctive (and shapes the code below):
//   - There is a SINGLE flat create call (POST /rest/apigateway/apis) — no
//     OpenAPI import, no revision, no deploy/activate/publish lifecycle. The API
//     is live the instant POST returns 201.
//   - There is NO update endpoint (no PUT/PATCH) for APIs or subscriptions, so
//     idempotent re-apply is "DELETE + POST" for APIs and "detect existing,
//     reuse" for subscriptions.
//   - Subscriptions do NOT mint credentials: the clientId is supplied by the
//     caller (minted out-of-band in Keycloak by `labctl subscribe`).
//   - JSON uses webMethods camelCase keys (apiId/apiName/basePath/...), NOT
//     id/name/version — the structs below pin those exact json tags.
package webmethods

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// gatewayName is the stable adapter identifier (matches targets.Target.Type and
// PublishResult.Gateway). Kept in one place so logs/results never drift.
const gatewayName = "webmethods"

// adminPrefix is the control-plane base path; dataPrefix is the data-plane base
// path. They are intentionally distinct on this gateway (/rest/apigateway vs
// /gateway) — mixing them is a classic misroute, so we keep them named.
const (
	adminPrefix = "/rest/apigateway"
	dataPrefix  = "/gateway"
)

// gatewayIdentity is the value the webMethods mock reports in the "gateway" field
// of GET /is/health (and in the X-Gateway response header). Health asserts it so a
// request misrouted to the wrong backend — which would return parsable JSON but a
// different (or empty) identity — is caught instead of silently parsing junk.
const gatewayIdentity = "webmethods-mock"

func init() {
	adapter.Register(gatewayName, New)
}

// New builds a webMethods adapter from a generic target descriptor. The mock
// uses no auth, but a real apigateway:10.15 uses HTTP Basic on /rest/apigateway;
// we read optional {username,password} credentials so the auth layer stays
// pluggable without changing call sites.
func New(cfg adapter.Config) (adapter.Adapter, error) {
	if strings.TrimSpace(cfg.AdminURL) == "" {
		return nil, fmt.Errorf("webmethods: adminUrl is required")
	}
	return &Adapter{
		adminURL:   strings.TrimRight(cfg.AdminURL, "/"),
		gatewayURL: strings.TrimRight(cfg.GatewayURL, "/"),
		username:   cfg.Cred("username", ""),
		password:   cfg.Cred("password", ""),
		http:       httpx.NewClient(cfg.Insecure),
	}, nil
}

// Adapter is one webMethods gateway driver bound to a single target. Stateless
// beyond its endpoints and HTTP client; safe for concurrent use.
type Adapter struct {
	adminURL   string // control-plane base, no trailing slash (e.g. http://webmethods-mock:8080)
	gatewayURL string // data-plane base, no trailing slash (used to build InvocationURL)
	username   string // optional HTTP Basic user (empty on the mock)
	password   string // optional HTTP Basic pass (empty on the mock)
	http       *http.Client
}

// Name returns the stable gateway identifier.
func (a *Adapter) Name() string { return gatewayName }

// adminPath joins the admin prefix to a sub-path (already starting with "/").
func (a *Adapter) adminPath(sub string) string {
	return a.adminURL + adminPrefix + sub
}

// authHeaders returns the per-request headers. On the mock this is empty; with
// credentials configured it adds HTTP Basic so the same code works against a
// real apigateway:10.15.
func (a *Adapter) authHeaders() map[string]string {
	if a.username == "" && a.password == "" {
		return nil
	}
	// Basic auth is built lazily so we never send an empty Authorization header.
	return map[string]string{
		"Authorization": basicAuth(a.username, a.password),
	}
}

// healthResponse is the envelope returned by GET /rest/apigateway/is/health.
type healthResponse struct {
	IsAlive bool   `json:"isAlive"`
	Gateway string `json:"gateway"`
}

// Health performs the liveness preflight: GET /rest/apigateway/is/health, assert
// the reported gateway identity, then gate on isAlive==true. Asserting the
// "gateway" field catches a request misrouted to a different backend that returns
// parsable JSON but is NOT the webMethods gateway. A reachable-but-not-alive
// gateway is treated as unhealthy so `labctl apply` fails fast with a clear
// diagnostic.
func (a *Adapter) Health(ctx context.Context) error {
	url := a.adminPath("/is/health")
	var hr healthResponse
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &hr); err != nil {
		return fmt.Errorf("webmethods health: %w", err)
	}
	if hr.Gateway != gatewayIdentity {
		return fmt.Errorf("webmethods health: gateway identity %q, want %q (misrouted/wrong backend at %s)", hr.Gateway, gatewayIdentity, url)
	}
	if !hr.IsAlive {
		return fmt.Errorf("webmethods health: gateway %q reports isAlive=false", url)
	}
	return nil
}

// List returns the APIs currently published on this gateway (gateway-native
// view) for `labctl get apis` and the reconcile/diff loop.
func (a *Adapter) List(ctx context.Context) ([]adapter.PublishedAPI, error) {
	apis, err := a.listAPIs(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]adapter.PublishedAPI, 0, len(apis))
	for _, api := range apis {
		out = append(out, adapter.PublishedAPI{
			Gateway:  gatewayName,
			APIID:    api.APIID,
			Name:     api.APIName,
			Version:  api.APIVersion,
			BasePath: api.BasePath,
		})
	}
	return out, nil
}

// basicAuth encodes HTTP Basic credentials. Used only when the target supplies
// {username,password}; the PoC mock needs none.
func basicAuth(user, pass string) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(user+":"+pass))
}
