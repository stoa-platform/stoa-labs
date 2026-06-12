// Package webmethods is the labctl gateway driver for a REAL webMethods API
// Gateway (softwareag/apigateway-trial:10.15). It targets the admin surface
// under /rest/apigateway/* with HTTP Basic auth and the data-plane under
// /gateway/{apiName}/{apiVersion}.
//
// What makes the real 10.15 product distinctive (and shapes the code below —
// payloads and endpoints ported from the live-validated stoa-go adapter):
//   - APIs are created by IMPORT: POST /rest/apigateway/apis with
//     {apiName, apiVersion, type: "openapi"|"swagger", apiDefinition: <spec>}.
//     The gateway derives resources and the native endpoint from the document.
//   - Creation does NOT make the API live: activation is a separate
//     PUT /rest/apigateway/apis/{id}/activate.
//   - Updates exist (PUT /rest/apigateway/apis/{id} with the same import
//     payload), so idempotent re-apply is "find by apiName+apiVersion, PUT".
//   - Envelope shapes are nested: list = {"apiResponse":[{"api":{...}},...]},
//     single = {"apiResponse":{"api":{...}}} — items may also appear flat.
//   - Consumers are APPLICATIONS (POST /rest/apigateway/applications) bound to
//     APIs via PUT /rest/apigateway/applications/{id}/apis {"apiIDs":[...]}.
//     The gateway does not mint OAuth credentials here; the clientId comes from
//     Keycloak (out-of-band, `labctl subscribe`).
//   - 10.15 chokes on some valid OpenAPI constructs ($ref in response schemas,
//     lowercase securityScheme enums, OpenAPI 3.1) — see spec.go for the
//     compatibility fixes ported from the career adapter.
package webmethods

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// gatewayName is the stable adapter identifier (matches targets.Target.Type and
// PublishResult.Gateway). Kept in one place so logs/results never drift.
const gatewayName = "webmethods"

// adminPrefix is the control-plane base path; dataPrefix is the data-plane base
// path. On the real product BOTH are served from port 5555 (Integration
// Server), but the paths are intentionally distinct — mixing them is a classic
// misroute, so we keep them named.
const (
	adminPrefix = "/rest/apigateway"
	dataPrefix  = "/gateway"
)

func init() {
	adapter.Register(gatewayName, New)
}

// New builds a webMethods adapter from a generic target descriptor. The real
// apigateway:10.15 enforces auth on every /rest/apigateway/* call, so the
// credentials must carry EXACTLY ONE mode — fail closed at construction
// instead of surfacing a confusing 401 mid-publish:
//   - {username,password}: HTTP Basic (the historical/trial mode);
//   - {bearerTokenFile}: path to a 0600 file holding a bearer token (CI mode —
//     the token never lives in the manifest, only a file reference does). The
//     file is read ONCE at construction, whitespace-trimmed.
func New(cfg adapter.Config) (adapter.Adapter, error) {
	if strings.TrimSpace(cfg.AdminURL) == "" {
		return nil, fmt.Errorf("webmethods: adminUrl is required")
	}
	user := cfg.Cred("username", "")
	pass := cfg.Cred("password", "")
	tokenFile := cfg.Cred("bearerTokenFile", "")
	var token string
	switch {
	case tokenFile != "" && (user != "" || pass != ""):
		// Mixed modes: ambiguous intent (which credential wins?) — refuse.
		return nil, fmt.Errorf("webmethods: credentials mix bearerTokenFile and username/password — use exactly ONE auth mode (bearer XOR HTTP Basic)")
	case tokenFile != "":
		tok, err := readBearerTokenFile(tokenFile)
		if err != nil {
			return nil, err
		}
		token = tok
	case user == "" || pass == "":
		return nil, fmt.Errorf("webmethods: credentials need either username+password (HTTP Basic) or bearerTokenFile (CI bearer mode) — real apigateway:10.15 enforces auth on %s/*", adminPrefix)
	}
	inbound, err := inboundAuthFromConfig(cfg)
	if err != nil {
		return nil, err
	}
	routing, err := routingFromConfig(cfg)
	if err != nil {
		return nil, err
	}
	return &Adapter{
		adminURL:    strings.TrimRight(cfg.AdminURL, "/"),
		gatewayURL:  strings.TrimRight(cfg.GatewayURL, "/"),
		username:    user,
		password:    pass,
		bearerToken: token,
		inbound:     inbound,
		routing:     routing,
		http:        httpx.NewClient(cfg.Insecure),
	}, nil
}

// readBearerTokenFile reads and trims the bearer token. Fail-closed checks:
// the file must exist, must not be group/world-accessible (it IS a credential
// — chmod 600), and must not be empty after trimming.
func readBearerTokenFile(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("webmethods: bearerTokenFile %s: %w", path, err)
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		return "", fmt.Errorf("webmethods: bearerTokenFile %s is group/world-accessible (%#o) — chmod 600 it (the token is a credential)", path, perm)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("webmethods: bearerTokenFile %s: %w", path, err)
	}
	token := strings.TrimSpace(string(raw))
	if token == "" {
		return "", fmt.Errorf("webmethods: bearerTokenFile %s is empty after trimming whitespace", path)
	}
	return token, nil
}

// Adapter is one webMethods gateway driver bound to a single target. Stateless
// beyond its endpoints and HTTP client; safe for concurrent use.
type Adapter struct {
	adminURL    string             // control-plane base, no trailing slash (e.g. http://localhost:5555)
	gatewayURL  string             // data-plane base, no trailing slash (used to build InvocationURL)
	username    string             // HTTP Basic user (Administrator on the trial image; "" in bearer mode)
	password    string             // HTTP Basic pass ("" in bearer mode)
	bearerToken string             // bearer token (CI mode; "" in Basic mode) — exactly one mode is set
	inbound     *inboundAuthConfig // optional inbound JWT/JWKS projection (nil = feature off)
	routing     *routingConfig     // optional routing-by-alias projection (nil = feature off)
	http        *http.Client
}

// Name returns the stable gateway identifier.
func (a *Adapter) Name() string { return gatewayName }

// adminPath joins the admin prefix to a sub-path (already starting with "/").
func (a *Adapter) adminPath(sub string) string {
	return a.adminURL + adminPrefix + sub
}

// authHeaders returns the per-request Authorization header: Bearer in token
// mode, HTTP Basic otherwise. Exactly one mode is guaranteed set by New
// (fail-closed), so this never sends an empty Authorization header.
func (a *Adapter) authHeaders() map[string]string {
	if a.bearerToken != "" {
		return map[string]string{
			"Authorization": "Bearer " + a.bearerToken,
		}
	}
	return map[string]string{
		"Authorization": basicAuth(a.username, a.password),
	}
}

// Health performs the liveness+auth preflight: GET /rest/apigateway/health with
// Basic auth. A 200 proves both reachability AND accepted credentials (the real
// gateway answers 401 on bad Basic). When the body carries the 10.15
// {"status":"..."} field, a "red" cluster is reported as unhealthy too, so
// `labctl apply` fails fast instead of half-publishing into a degraded gateway.
func (a *Adapter) Health(ctx context.Context) error {
	url := a.adminPath("/health")
	var body map[string]json.RawMessage
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &body); err != nil {
		return fmt.Errorf("webmethods health: %w (check adminUrl %s and Basic credentials)", err, a.adminURL)
	}
	if raw, ok := body["status"]; ok {
		var status string
		if err := json.Unmarshal(raw, &status); err == nil && strings.EqualFold(status, "red") {
			return fmt.Errorf("webmethods health: gateway %s reports status=red (degraded — check Elasticsearch backing store)", url)
		}
	}
	return nil
}

// List returns the APIs currently published on this gateway (gateway-native
// view) for `labctl get apis` and the reconcile/diff loop. BasePath is the
// derived data-plane context (/gateway/{apiName}/{apiVersion}) — the real
// product does not store an explicit basePath on the API record.
func (a *Adapter) List(ctx context.Context) ([]adapter.PublishedAPI, error) {
	apis, err := a.listAPIs(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]adapter.PublishedAPI, 0, len(apis))
	for _, api := range apis {
		out = append(out, adapter.PublishedAPI{
			Gateway:  gatewayName,
			APIID:    api.ID,
			Name:     api.APIName,
			Version:  api.APIVersion,
			BasePath: dataPrefix + "/" + api.APIName + "/" + api.APIVersion,
		})
	}
	return out, nil
}

// basicAuth encodes HTTP Basic credentials (Administrator:manage on the trial).
func basicAuth(user, pass string) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(user+":"+pass))
}
