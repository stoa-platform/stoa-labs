// Package adapter defines the contract every gateway driver implements so that
// labctl can "Define Once, Expose Everywhere": one parsed OpenAPI contract is
// published to N heterogeneous gateways through a uniform interface.
//
// Design rules (kubectl-style, faithful to stoactl):
//   - every method takes a context.Context (cancellation, deadlines, OTel spans);
//   - adapters are stateless drivers built from a *targets.Target (URL+creds);
//   - the OpenAPI parsing happens ONCE in internal/openapi and is handed to every
//     adapter as a *NormalizedAPI, so no adapter re-parses the spec;
//   - Publish/CreateConsumer are idempotent-by-intent: re-running `labctl apply`
//     converges to the same state (PUT/upsert where the gateway allows it,
//     delete+create where it does not — see webMethods).
package adapter

import (
	"context"
	"fmt"
)

// Adapter is the uniform driver for one gateway runtime (WSO2, APISIX,
// webMethods, ...). One concrete Adapter instance is bound to exactly one
// target gateway. All calls are context-aware and safe to cancel.
type Adapter interface {
	// Name returns the stable adapter/gateway identifier used in logs,
	// PublishResult.Gateway and Backstage annotations (e.g. "wso2", "apisix",
	// "webmethods"). It matches targets.Target.Type.
	Name() string

	// Health performs a cheap liveness/auth preflight against the gateway's
	// control plane. It returns nil when the gateway is reachable AND the
	// adapter's credentials are accepted, so `labctl apply` can fail fast with a
	// clear per-gateway diagnostic instead of a half-published fleet.
	Health(ctx context.Context) error

	// Publish materialises the NormalizedAPI on this gateway and makes it serve
	// live data-plane traffic. It must be idempotent: calling it twice with the
	// same NormalizedAPI converges to one published API (no duplicates).
	// It returns the gateway-native identifiers and the live invocation URL.
	Publish(ctx context.Context, api *NormalizedAPI) (*PublishResult, error)

	// List returns the APIs currently published on this gateway (gateway-native
	// view), used by `labctl get apis` and by the reconcile/diff loop.
	List(ctx context.Context) ([]PublishedAPI, error)

	// CreateConsumer provisions a consumer/application on this gateway and binds
	// it to a published API so it can invoke the protected data plane. The
	// out-of-band OAuth client (Keycloak) is referenced via ConsumerSpec; how the
	// gateway ties to it (DCR/map-keys, jwt-auth key, clientId subscription) is
	// adapter-specific. It must be idempotent on (api, consumer name).
	CreateConsumer(ctx context.Context, api *NormalizedAPI, spec *ConsumerSpec) (*ConsumerResult, error)
}

// NormalizedAPI is the gateway-agnostic view of one OpenAPI contract, produced
// once by internal/openapi from the spec referenced in targets.yaml. Every
// adapter maps these fields onto its own model; no adapter parses raw OpenAPI.
type NormalizedAPI struct {
	// Name is a DNS-safe slug derived from info.title (e.g. "accounts-read").
	// Used as the WSO2 API name, the APISIX route/upstream id seed and the
	// webMethods apiName.
	Name string

	// Version comes from info.version (e.g. "1.0.0"). WSO2 uses it in the
	// context+version; webMethods stores it as apiVersion.
	Version string

	// BasePath is the public context the gateway exposes, derived from the first
	// servers[].url path (e.g. "/accounts-read/v1"), always leading-slash, no
	// trailing slash. WSO2 "context", APISIX route prefix, webMethods basePath.
	BasePath string

	// BackendURL is the upstream the gateway proxies to (the synthetic Microcks
	// backend in the PoC), taken from targets.yaml backendUrl (authoritative)
	// or, if absent, an absolute servers[].url. Scheme matters for APISIX.
	BackendURL string

	// Endpoints is the flattened list of OpenAPI operations, used to build
	// per-operation routes (APISIX) or to document/verify the surface.
	Endpoints []Endpoint

	// Spec is the raw OpenAPI document bytes (YAML/JSON as read from disk), kept
	// so WSO2's import-openapi can upload the original contract verbatim and so
	// Backstage can embed the definition. Empty if not loaded from a file.
	Spec []byte

	// SpecPath is the on-disk path the Spec was read from (for multipart
	// file=@... uploads and for Backstage $text references). Optional.
	SpecPath string
}

// Endpoint is one OpenAPI operation group: a path template plus the HTTP methods
// declared on it.
type Endpoint struct {
	// Path is the OpenAPI path template relative to BasePath (e.g. "/accounts",
	// "/accounts/{id}"). Path params use the {name} OpenAPI form; adapters that
	// need regex (APISIX) translate {name} -> a capture group themselves.
	Path string

	// Methods are the upper-case HTTP verbs on this path (e.g. ["GET","POST"]).
	Methods []string
}

// PublishResult is the uniform outcome of Publish for one gateway.
type PublishResult struct {
	// Gateway echoes Adapter.Name() (e.g. "wso2").
	Gateway string

	// APIID is the gateway-native identifier of the published API
	// (WSO2 apiId UUID, APISIX route id, webMethods "api-0001").
	APIID string

	// RevisionID is the deployed revision id where the gateway has the concept
	// (WSO2). Empty for APISIX/webMethods, which have no revision lifecycle.
	RevisionID string

	// InvocationURL is the live data-plane URL a consumer calls, as seen on the
	// docker-compose network (e.g. "https://wso2am:8243/accounts-read/v1",
	// "http://apisix:9080/accounts-read/v1",
	// "http://webmethods-mock:8080/gateway/accounts-read/v1").
	InvocationURL string

	// Published reports whether the API reached a "live + (where applicable)
	// PUBLISHED/subscribable" state. WSO2 sets this true only after both
	// deploy-revision AND change-lifecycle=Publish succeed.
	Published bool

	// Created is false when Publish converged onto an API that already existed
	// (idempotent re-apply), true when it created a new one.
	Created bool
}

// PublishedAPI is the gateway-native listing element returned by List.
type PublishedAPI struct {
	Gateway  string
	APIID    string
	Name     string
	Version  string
	BasePath string
}

// ConsumerSpec describes the consumer to provision and the out-of-band OAuth
// client (minted in Keycloak by `labctl subscribe`) it should be tied to.
type ConsumerSpec struct {
	// Name is the consumer/application name (WSO2 Application name, APISIX
	// consumer username — APISIX allows only [a-zA-Z0-9_], so the adapter
	// sanitises dashes; webMethods applicationName).
	Name string

	// ClientID / ClientSecret are the Keycloak OAuth client credentials minted
	// out-of-band by `labctl subscribe`. WSO2 maps them via /map-keys (or
	// generate-keys when self-issuing); webMethods stores ClientID on the
	// subscription; APISIX ignores them for key-auth/jwt-auth (its own credential
	// lives in Key/Secret below).
	ClientID     string
	ClientSecret string

	// AuthType selects the data-plane credential model the consumer will use:
	// "oauth2" (WSO2/webMethods, Keycloak-issued bearer), "jwt-auth" or
	// "key-auth" (APISIX-native). Defaults are adapter-specific.
	AuthType string

	// Key / Secret are the APISIX-native credential material: for key-auth, Key
	// is the apikey the client sends as the `apikey` header; for jwt-auth, Key is
	// the consumer "key" claim and Secret the HS256 signing secret. Ignored by
	// WSO2/webMethods. Generated by labctl when empty.
	Key    string
	Secret string

	// ThrottlingPolicy / Plan is the business plan/tier (WSO2 "Unlimited",
	// webMethods plan). Defaults to "Unlimited" in the PoC.
	ThrottlingPolicy string

	// --- Partner onboarding identifiers (ADR-071) ---------------------------
	// These OPTIONAL fields declare the partner identity an admin posts BY HAND
	// today on the webMethods application (custom TOKEN, IP allowlist, public
	// CERTIFICATE) so labctl can project them as-code. Absent on every field =>
	// the consumer behaves exactly as before (azp/openIdClaims only). Ignored by
	// gateways that do not model per-application identifiers (WSO2/APISIX).

	// TokenIdentifiers are custom token strings projected as a webMethods
	// application identifier (key "token"). The client presents the token in a
	// custom header; the "Identify & Authorize Application" action in token mode
	// resolves THIS application. Non-secret tokens (shared test material) may
	// live in Git; production secrets MUST be referenced from Vault/PAM, never
	// inlined in the manifest (ADR-068/069).
	TokenIdentifiers []string

	// IPAllowlist are IPs and/or ranges ("203.0.113.10", "10.60.30.1-10.60.30.30")
	// projected as a webMethods application identifier (key "ipAddressRange").
	// Enforced only when the API carries the IP-range identification action;
	// posed-but-inert otherwise (same semantics as azp). Auditable in Git.
	IPAllowlist []string

	// PublicCertRef references a PUBLIC X.509 certificate (PEM) of the partner —
	// an on-disk path OR an inline PEM. labctl registers it in the gateway
	// truststore (mTLS handshake trust) AND posts it as the application
	// identifier (key "httpsCertificate", identity match). Only PUBLIC material
	// is accepted; a PEM carrying a PRIVATE KEY is rejected (never in Git).
	PublicCertRef string
}

// ConsumerResult is the uniform outcome of CreateConsumer for one gateway.
type ConsumerResult struct {
	// Gateway echoes Adapter.Name().
	Gateway string

	// ConsumerID is the gateway-native consumer/application/subscription id
	// (WSO2 applicationId + subscriptionId, APISIX consumer username,
	// webMethods subscriptionId "sub-0001").
	ConsumerID string

	// SubscriptionID is the binding id where distinct from ConsumerID
	// (WSO2 subscriptionId, webMethods subscriptionId). Optional.
	SubscriptionID string

	// ConsumerKey / ConsumerSecret are the credentials the client uses against
	// the data plane: WSO2 returns generated/mapped consumerKey/secret;
	// APISIX key-auth returns the apikey in ConsumerKey; jwt-auth returns the
	// signing key/secret. webMethods echoes the supplied ClientID in ConsumerKey.
	ConsumerKey    string
	ConsumerSecret string

	// TokenHint is a human-readable note on how to obtain/use the data-plane
	// credential (e.g. the APISIX jwt sign URL, or the WSO2 token endpoint).
	TokenHint string
}

// ErrNotImplemented is returned by adapters for capabilities a given gateway
// does not support (e.g. List on a gateway without a list endpoint).
var ErrNotImplemented = fmt.Errorf("adapter: not implemented for this gateway")

// Factory builds a concrete Adapter from a generic target descriptor. Each
// adapter package registers one via Register so cmd/labctl can resolve a target
// by its Type string without importing every adapter package directly.
type Factory func(cfg Config) (Adapter, error)

// Config is the adapter-construction input projected from a targets.Target:
// the control-plane URL plus opaque credentials (admin key, basic creds, none).
type Config struct {
	Type        string            // "wso2" | "apisix" | "webmethods"
	Name        string            // target name from targets.yaml (usually == Type)
	AdminURL    string            // control-plane base URL (e.g. https://wso2am:9443)
	GatewayURL  string            // data-plane base URL (e.g. https://wso2am:8243)
	Credentials map[string]string // type-specific: {username,password} | {adminKey} | {}
	Insecure    bool              // skip TLS verify (self-signed WSO2)
	// Options carries adapter-specific, non-secret knobs projected from the
	// target: WSO2 {"gatewayEnv":"Default","vhost":"localhost"},
	// APISIX {"consumerAuth":"jwt-auth"}. Adapters read what they need and fall
	// back to documented defaults when a key is absent.
	Options map[string]string
}

// Opt returns Options[key] or def when missing/empty — so adapters don't repeat
// the nil-map + empty-string dance.
func (c Config) Opt(key, def string) string {
	if c.Options != nil {
		if v, ok := c.Options[key]; ok && v != "" {
			return v
		}
	}
	return def
}

// Cred returns Credentials[key] or def when missing/empty.
func (c Config) Cred(key, def string) string {
	if c.Credentials != nil {
		if v, ok := c.Credentials[key]; ok && v != "" {
			return v
		}
	}
	return def
}

var registry = map[string]Factory{}

// Register wires a Factory under a target type. Called from each adapter's
// package init(). Panics on duplicate registration (programmer error).
func Register(typ string, f Factory) {
	if _, dup := registry[typ]; dup {
		panic("adapter: duplicate registration for type " + typ)
	}
	registry[typ] = f
}

// New resolves and constructs the Adapter for a target type.
func New(cfg Config) (Adapter, error) {
	f, ok := registry[cfg.Type]
	if !ok {
		return nil, fmt.Errorf("adapter: unknown gateway type %q", cfg.Type)
	}
	return f(cfg)
}
