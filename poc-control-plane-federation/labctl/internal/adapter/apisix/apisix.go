// Package apisix implements the adapter.Adapter contract for Apache APISIX 3.11
// running in traditional + etcd mode.
//
// In traditional mode a PUT to the Admin API (control plane, default port 9180)
// writes the object straight to etcd and propagates it to every data-plane node
// (default port 9080) within seconds — there is NO separate deploy/revision/
// activate step (unlike WSO2). Because we PUT with deterministic ids derived from
// api.Name, Publish and CreateConsumer are idempotent by construction: re-running
// converges to the same etcd state with no duplicates.
//
// Every Admin API call carries the X-API-KEY header with the configured admin
// key (cfg.Cred("adminKey","")). The plugins field on routes/services/consumers
// is always a JSON OBJECT keyed by plugin name (never an array).
package apisix

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// gatewayName is the stable adapter identifier (matches targets.Target.Type).
const gatewayName = "apisix"

// adminKeyHeader is the Admin API authentication header for APISIX 3.x.
const adminKeyHeader = "X-API-KEY"

// defaultConsumerAuth is used when the target does not pin a consumerAuth knob.
// jwt-auth is the PoC default (HS256, with a public sign route).
const defaultConsumerAuth = "jwt-auth"

// usernameInvalid matches every character APISIX forbids in a consumer username
// (only [a-zA-Z0-9_] are allowed — notably NO dashes).
var usernameInvalid = regexp.MustCompile(`[^a-zA-Z0-9_]`)

// Adapter drives a single APISIX control plane. It is stateless beyond the
// resolved config + shared HTTP client, so it is safe to reuse across calls.
type Adapter struct {
	cfg      adapter.Config
	client   *http.Client
	adminURL string // control-plane base, no trailing slash (e.g. http://apisix:9180)
	gwURL    string // data-plane base,    no trailing slash (e.g. http://apisix:9080)
	adminKey string // value sent in X-API-KEY on every admin call
	auth     string // consumer auth model: "jwt-auth" | "key-auth"
}

// init registers the APISIX factory so internal/register can blank-import this
// package and wire it into the adapter registry without cmd/ importing us.
func init() {
	adapter.Register(gatewayName, New)
}

// New builds an APISIX Adapter from a generic Config. It validates only what it
// needs to fail fast with an actionable message; live reachability is checked by
// Health.
func New(cfg adapter.Config) (adapter.Adapter, error) {
	adminURL := strings.TrimRight(cfg.AdminURL, "/")
	if adminURL == "" {
		return nil, fmt.Errorf("apisix: missing AdminURL (control-plane Admin API, e.g. http://apisix:9180)")
	}
	auth := cfg.Opt("consumerAuth", defaultConsumerAuth)
	if auth != "jwt-auth" && auth != "key-auth" {
		return nil, fmt.Errorf("apisix: unsupported consumerAuth %q (want jwt-auth|key-auth)", auth)
	}
	return &Adapter{
		cfg:      cfg,
		client:   httpx.NewClient(cfg.Insecure),
		adminURL: adminURL,
		gwURL:    strings.TrimRight(cfg.GatewayURL, "/"),
		adminKey: cfg.Cred("adminKey", ""),
		auth:     auth,
	}, nil
}

// Name returns the stable gateway identifier.
func (a *Adapter) Name() string { return gatewayName }

// adminHeaders returns the headers every Admin API call must carry. The
// X-API-KEY is mandatory in APISIX 3.x or the call is rejected (401).
func (a *Adapter) adminHeaders() map[string]string {
	return map[string]string{adminKeyHeader: a.adminKey}
}

// Health performs a cheap auth + reachability preflight: a GET on the routes
// list endpoint. A 2xx means the Admin API is up AND the admin key is accepted,
// so `labctl apply` can fail fast per-gateway instead of half-publishing.
func (a *Adapter) Health(ctx context.Context) error {
	u := a.adminURL + "/apisix/admin/routes"
	if _, err := httpx.JSON(ctx, a.client, http.MethodGet, u, a.adminHeaders(), nil, nil); err != nil {
		return fmt.Errorf("apisix health: %w", err)
	}
	return nil
}

// List returns the routes currently published on this gateway, mapped to the
// gateway-agnostic PublishedAPI view used by `labctl get apis`.
func (a *Adapter) List(ctx context.Context) ([]adapter.PublishedAPI, error) {
	u := a.adminURL + "/apisix/admin/routes"
	var resp listRoutesResponse
	if _, err := httpx.JSON(ctx, a.client, http.MethodGet, u, a.adminHeaders(), nil, &resp); err != nil {
		return nil, fmt.Errorf("apisix list routes: %w", err)
	}
	out := make([]adapter.PublishedAPI, 0, len(resp.List))
	for _, item := range resp.List {
		v := item.Value
		out = append(out, adapter.PublishedAPI{
			Gateway:  gatewayName,
			APIID:    v.ID,
			Name:     v.Name,
			BasePath: v.URI,
		})
	}
	return out, nil
}

// listRoutesResponse mirrors APISIX 3.x GET /apisix/admin/routes:
// {"list":[{"key":"/apisix/routes/<id>","value":{...}}]}.
type listRoutesResponse struct {
	List []struct {
		Value struct {
			ID   string `json:"id"`
			Name string `json:"name"`
			URI  string `json:"uri"`
		} `json:"value"`
	} `json:"list"`
}

// sanitizeUsername strips every APISIX-forbidden character from a consumer name
// so dashes in "accounts-read-app" become underscores. An empty result (e.g. an
// all-symbol name) falls back to a stable placeholder.
func sanitizeUsername(name string) string {
	u := usernameInvalid.ReplaceAllString(name, "_")
	if u == "" {
		return "consumer"
	}
	return u
}

// backendNode parses BackendURL into the "host:port" key APISIX expects in
// upstream.nodes plus the matching scheme (http|https). When no explicit port is
// present we default to the scheme's well-known port so the node is always
// host:port (APISIX is happiest with an explicit port).
func backendNode(backendURL string) (node, scheme string, err error) {
	u, err := url.Parse(backendURL)
	if err != nil {
		return "", "", fmt.Errorf("parse backendURL %q: %w", backendURL, err)
	}
	scheme = u.Scheme
	if scheme == "" {
		scheme = "http"
	}
	host := u.Hostname()
	if host == "" {
		return "", "", fmt.Errorf("backendURL %q has no host", backendURL)
	}
	port := u.Port()
	if port == "" {
		if scheme == "https" {
			port = "443"
		} else {
			port = "80"
		}
	}
	return host + ":" + port, scheme, nil
}

// routeURI converts an OpenAPI path template into an APISIX uri. APISIX's '*'
// wildcard only matches a trailing segment, so a templated path like
// "/accounts/{id}" becomes a prefix wildcard "<basePath>/accounts/*"; a static
// path is appended verbatim. basePath is the public context (leading slash, no
// trailing slash).
func routeURI(basePath, epPath string) string {
	base := strings.TrimRight(basePath, "/")
	if i := strings.IndexByte(epPath, '{'); i >= 0 {
		// Keep the static prefix before the first {param}, then wildcard.
		prefix := strings.TrimRight(epPath[:i], "/")
		return base + prefix + "/*"
	}
	if epPath == "" || epPath == "/" {
		// Whole-API route: match the base and everything under it.
		return base + "/*"
	}
	return base + epPath
}

// generateSecret returns a hex-encoded random secret used as a fallback HS256
// signing secret (jwt-auth) or apikey (key-auth) when the spec supplies none.
func generateSecret() (string, error) {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generate credential: %w", err)
	}
	return hex.EncodeToString(b), nil
}
