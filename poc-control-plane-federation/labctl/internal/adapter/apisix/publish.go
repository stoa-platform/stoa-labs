package apisix

import (
	"context"
	"fmt"
	"net/http"
	"regexp"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// Publish materialises a NormalizedAPI on APISIX and makes it serve live
// data-plane traffic. The sequence is upstream -> service -> route(s) -> verify;
// every object is PUT with a deterministic id so re-running converges (idempotent
// by construction in traditional+etcd mode — the PUT itself makes traffic live,
// there is NO deploy/revision step).
//
// Auth (jwt-auth/key-auth) is deliberately NOT enabled here: enabling it at
// publish time would open a 401 window on the data plane before any consumer
// exists. Auth is attached in CreateConsumer instead.
func (a *Adapter) Publish(ctx context.Context, api *adapter.NormalizedAPI) (*adapter.PublishResult, error) {
	upstreamID := api.Name // stable seed shared by upstream + service

	// 0. Probe the representative route to report Created accurately on re-apply.
	existed := a.routeExists(ctx, api.Name+"-0")

	// 1. UPSTREAM — point at the backend host:port with a scheme that MUST match
	//    the backend (mismatch => TLS/connection errors).
	node, scheme, err := backendNode(api.BackendURL)
	if err != nil {
		return nil, fmt.Errorf("apisix publish %s: %w", api.Name, err)
	}
	backendPath := backendBasePath(api.BackendURL)
	upstream := upstreamBody{
		Type:     "roundrobin",
		Scheme:   scheme,
		PassHost: "pass",
		Nodes:    map[string]int{node: 1},
	}
	upURL := a.adminURL + "/apisix/admin/upstreams/" + upstreamID
	if _, err := httpx.JSON(ctx, a.client, http.MethodPut, upURL, a.adminHeaders(), upstream, nil); err != nil {
		return nil, fmt.Errorf("apisix publish %s: put upstream: %w", api.Name, err)
	}

	// 2. SERVICE — bundle the upstream + shared (non-auth) plugins so per-path
	//    routes stay thin. Routes reference it via service_id.
	service := serviceBody{
		UpstreamID: upstreamID,
		Plugins:    sharedPlugins(api.BasePath, backendPath),
	}
	svcURL := a.adminURL + "/apisix/admin/services/" + upstreamID
	if _, err := httpx.JSON(ctx, a.client, http.MethodPut, svcURL, a.adminHeaders(), service, nil); err != nil {
		return nil, fmt.Errorf("apisix publish %s: put service: %w", api.Name, err)
	}

	// 3. ROUTES — one per OpenAPI endpoint for clean method/path mapping. When
	//    the spec has no endpoints we still publish a single catch-all route so
	//    the API is reachable.
	endpoints := api.Endpoints
	if len(endpoints) == 0 {
		endpoints = []adapter.Endpoint{{Path: "/", Methods: nil}}
	}
	for i, ep := range endpoints {
		route := routeBody{
			URI:       routeURI(api.BasePath, ep.Path),
			Methods:   ep.Methods,
			Status:    1, // 1 = enabled (0 would create but serve no traffic)
			ServiceID: upstreamID,
			Plugins:   sharedPlugins(api.BasePath, backendPath),
			Labels:    routeLabels(api.Name, api.Version, api.BasePath),
		}
		rURL := fmt.Sprintf("%s/apisix/admin/routes/%s-%d", a.adminURL, api.Name, i)
		if _, err := httpx.JSON(ctx, a.client, http.MethodPut, rURL, a.adminHeaders(), route, nil); err != nil {
			return nil, fmt.Errorf("apisix publish %s: put route %d: %w", api.Name, i, err)
		}
	}

	// 4. VERIFY — read back the representative route and assert it is enabled.
	verifyURL := fmt.Sprintf("%s/apisix/admin/routes/%s-0", a.adminURL, api.Name)
	var got routeResponse
	if _, err := httpx.JSON(ctx, a.client, http.MethodGet, verifyURL, a.adminHeaders(), nil, &got); err != nil {
		return nil, fmt.Errorf("apisix publish %s: verify route: %w", api.Name, err)
	}
	if got.Value.Status != 1 {
		return nil, fmt.Errorf("apisix publish %s: route %s-0 not enabled (status=%d)", api.Name, api.Name, got.Value.Status)
	}

	return &adapter.PublishResult{
		Gateway:       gatewayName,
		APIID:         api.Name + "-0", // representative route id
		RevisionID:    "",              // APISIX has no revision lifecycle
		InvocationURL: a.gwURL + api.BasePath,
		Published:     true,
		Created:       !existed,
	}, nil
}

// routeExists reports whether a route id already exists (used to set the Created
// flag on idempotent re-apply). Any non-2xx (including 404) means "not present".
func (a *Adapter) routeExists(ctx context.Context, id string) bool {
	u := a.adminURL + "/apisix/admin/routes/" + id
	code, _, err := httpx.Do(ctx, a.client, http.MethodGet, u, a.adminHeaders(), nil)
	return err == nil && code >= 200 && code < 300
}

// sharedPlugins returns the non-auth plugins applied to every route/service for
// an API: proxy-rewrite (strip the public basePath prefix before the backend)
// and opentelemetry (always-on sampling). plugins is a JSON OBJECT keyed by
// plugin name — never an array.
func sharedPlugins(basePath, backendPath string) map[string]any {
	// Rewrite the public basePath to the BACKEND base path so the upstream
	// (host:port only) receives the full path it serves. e.g.
	//   /accounts-read/v1/accounts -> /rest/Accounts+Read+API/1.0.0/accounts
	// Without the backendPath prefix the backend gets "/accounts" and 404s.
	rewrite := "/$1"
	if backendPath != "" {
		rewrite = backendPath + "/$1"
	}
	return map[string]any{
		"proxy-rewrite": map[string]any{
			// QuoteMeta the basePath so a legal path metachar (e.g. "/v1.0")
			// is matched literally instead of as a regex wildcard (over-match).
			"regex_uri": []string{"^" + regexp.QuoteMeta(basePath) + "/(.*)", rewrite},
		},
		"opentelemetry": map[string]any{
			"sampler": map[string]any{"name": "always_on"},
		},
	}
}

// routeLabels stamps the APISIX route with identifying labels so the
// gateway-native List() can round-trip Name+Version (APISIX routes carry no
// native API name/version). "version" is only set when non-empty so the label
// map never PUTs a blank value.
func routeLabels(name, version, basePath string) map[string]string {
	labels := map[string]string{
		"managed-by": "labctl",
		"api":        name,
		"basepath":   basePath,
	}
	if version != "" {
		labels["version"] = version
	}
	return labels
}

// --- Admin API request/response bodies ---

// upstreamBody is the PUT body for /apisix/admin/upstreams/{id}.
type upstreamBody struct {
	Type     string         `json:"type"`
	Scheme   string         `json:"scheme"`
	PassHost string         `json:"pass_host"`
	Nodes    map[string]int `json:"nodes"`
}

// serviceBody is the PUT body for /apisix/admin/services/{id}.
type serviceBody struct {
	UpstreamID string         `json:"upstream_id"`
	Plugins    map[string]any `json:"plugins"`
}

// routeBody is the PUT body for /apisix/admin/routes/{id}. omitempty on methods
// lets "all methods" be expressed by omitting the field.
type routeBody struct {
	URI       string            `json:"uri"`
	Methods   []string          `json:"methods,omitempty"`
	Status    int               `json:"status"`
	ServiceID string            `json:"service_id,omitempty"`
	Plugins   map[string]any    `json:"plugins"`
	Labels    map[string]string `json:"labels,omitempty"`
}

// routeResponse mirrors GET /apisix/admin/routes/{id}: {"value":{"status":1,...}}.
type routeResponse struct {
	Value struct {
		Status int `json:"status"`
	} `json:"value"`
}
