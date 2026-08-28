// Package targets loads the labctl federation manifest (targets.yaml) and
// projects each target onto an adapter.Config. It is the single source of truth
// for "which gateways, at which URLs, with which knobs".
package targets

import (
	"strconv"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

// File is the parsed targets.yaml.
type File struct {
	APIVersion string `json:"apiVersion"`
	Kind       string `json:"kind"`

	// Name optionally overrides the API name (else derived from the contract
	// title). Keeps WSO2 context / APISIX ids / Backstage entity name aligned.
	Name string `json:"name"`

	// Contract is the path to the single OpenAPI document ("Define Once").
	Contract string `json:"contract"`

	// BackendURL is the authoritative upstream the gateways proxy to.
	BackendURL string `json:"backendUrl"`

	Targets   []Target  `json:"targets"`
	Keycloak  Keycloak  `json:"keycloak"`
	Backstage Backstage `json:"backstage"`

	// Partner optionally declares the partner/consumer identity to project on
	// gateways that model per-application identifiers (webMethods): a custom
	// TOKEN, an IP allowlist and a PUBLIC certificate — the onboarding an admin
	// does BY HAND today, now as-code (ADR-071). The consumer is ONE identity
	// across all gateways, so the block lives at the manifest level (not per
	// target). Absent = the consumer keeps its current azp-only behavior.
	Partner *Partner `json:"partner"`
}

// Partner declares the optional partner-onboarding identifiers projected onto
// the consumer application (webMethods; ignored by WSO2/APISIX). Everything is
// optional; an empty block changes nothing.
//
// SECURITY: PublicCertRef and IPAllowlist are NON-SECRET config — auditable by
// PR in Git (the douve of le principe reuse-first/069). TokenIdentifiers carrying a real shared
// secret MUST be referenced from Vault/PAM, never inlined here; a PEM private
// key in PublicCertRef is REFUSED by the adapter.
type Partner struct {
	// TokenIdentifiers are custom identification tokens -> webMethods identifier
	// key "token". Le client présente ce token dans un header custom.
	TokenIdentifiers []string `json:"tokenIdentifiers"`

	// IPAllowlist are IPs / ranges -> webMethods identifier key "ipAddressRange"
	// (ex: "203.0.113.10", "10.60.30.1-10.60.30.30").
	IPAllowlist []string `json:"ipAllowlist"`

	// PublicCertRef is a PUBLIC X.509 PEM — chemin (résolu relativement au
	// manifeste) OU PEM inline. -> truststore gateway + identifier key
	// "httpsCertificate". JAMAIS de clé privée (rejetée).
	PublicCertRef string `json:"publicCertRef"`
}

// Target is one gateway entry.
type Target struct {
	Name       string `json:"name"`
	Type       string `json:"type"`
	AdminURL   string `json:"adminUrl"`
	GatewayURL string `json:"gatewayUrl"`
	Insecure   bool   `json:"insecure"`

	// WSO2-specific.
	GatewayEnv string `json:"gatewayEnv"`
	Vhost      string `json:"vhost"`

	// APISIX-specific data-plane consumer auth: "jwt-auth" | "key-auth".
	ConsumerAuth string `json:"consumerAuth"`

	// InboundAuth optionally projects the platform's JWT issuer as INBOUND
	// auth on gateways that materialise it control-plane-side (webMethods:
	// auth-server alias + Identify & Authorize IAM action attached to the API
	// policy; APISIX: openid-connect plugin on every projected route). Absent =
	// the target's current behavior is unchanged.
	InboundAuth *InboundAuth `json:"inboundAuth"`

	// Observability optionally projects centralised transactional analytics
	// (ADR-070): on APISIX it adds a kafka-logger plugin to every route, emitting
	// the common stoa.txn schema (tenant tag + trace_id) to Redpanda for the
	// collector (Data Prepper) to normalise/redact/route. Absent = unchanged.
	Observability *Observability `json:"observability"`

	// Routing optionally projects PER-ENVIRONMENT backend routing on gateways
	// that model it control-plane-side (webMethods: endpoint alias + ${alias}
	// straightThroughRouting, resolved per request — the CI multi-env chantier).
	// Absent = the import-time backend (backendUrl/servers[]) stays effective.
	Routing *Routing `json:"routing"`

	// RateLimit optionally projects a per-API traffic hard-limit (ADR-076
	// rate-limit leg): requests over the limit are rejected 429 at the gateway.
	// On webMethods it is a "Traffic Optimization" (throttle) policyAction on the
	// LMT stage. Absent = no throttle projected (behavior unchanged).
	RateLimit *RateLimit `json:"rateLimit"`

	// TransportProtocol optionally pins the API's accepted transport protocol
	// (ADR-076 mTLS wiring). "https" makes the API reachable ONLY over the HTTPS
	// listener (entryProtocolPolicy protocol=[https]) — combined with a
	// clientAuth=require HTTPS port + trusted client CA, that is end-to-end mTLS
	// for this API. Empty = leave the import default (http) untouched.
	TransportProtocol string `json:"transportProtocol"`

	// AllowDeactivate is the ADR-079 gate of a webMethods target: deactivating
	// an API CUTS its data plane, so outside the authoring environment the
	// adapter must refuse it (UPDATE_FORBIDDEN) and send the change through the
	// archive import verb instead.
	//
	// POINTER, NOT bool, ON PURPOSE. The default is TRUE (authoring behaviour,
	// unchanged), and a plain bool would decode an ABSENT key as false — that
	// would silently flip every existing targets file to the closed gate. Three
	// states, all meaningful: nil = absent, use the default; &true = explicitly
	// open; &false = closed, the deactivate is refused.
	//
	// This field exists because the knob was previously UNREACHABLE: the adapter
	// read Opt("allowDeactivate") but ToConfig never emitted that key, so a
	// targets file saying `allowDeactivate: false` looked like it closed a gate
	// that stayed open — a fail-open with a reassuring name.
	AllowDeactivate *bool `json:"allowDeactivate"`

	Credentials map[string]string `json:"credentials"`
}

// RateLimit declares the optional per-API traffic hard-limit of one target.
// Requests exceeding Requests over the window are rejected (429). The webMethods
// throttle enforces it in-gateway (not fail-open).
type RateLimit struct {
	Requests int    `json:"requests"` // hard limit (max requests); <=0 = feature off
	Interval int    `json:"interval"` // window/alert interval (default 1)
	Unit     string `json:"unit"`     // minutes|hours|days|weeks|... (default minutes)
}

// Routing declares the optional routing-by-alias block of one target. The
// endpoint alias makes the backend an ENV-SWITCHABLE gateway value; the
// credential alias (optional) carries the backend's HTTP Basic credential for
// the Outbound Auth – Transport action. The credential VALUES live in
// Target.Credentials (backendUsername/backendPassword) — never in this block,
// so the manifest stays free of inline secrets.
type Routing struct {
	EndpointAlias   *EndpointAlias   `json:"endpointAlias"`
	CredentialAlias *CredentialAlias `json:"credentialAlias"`
}

// EndpointAlias names and values the per-environment backend endpoint alias.
type EndpointAlias struct {
	// Name is a TEMPLATE: "{api}" is replaced by the sanitised API name.
	// Defaults to "{api}-backend" when empty.
	Name string `json:"name"`

	// URL is the PER-ENV backend the alias resolves to — the one value that
	// differs between dev/uat/prod manifests. REQUIRED.
	URL string `json:"url"`
}

// CredentialAlias names the backend HTTP Basic credential alias. Its presence
// switches on the Outbound Auth – Transport projection; the userName/password
// VALUES come from Target.Credentials backendUsername/backendPassword.
type CredentialAlias struct {
	// Name is a TEMPLATE like EndpointAlias.Name. Defaults to
	// "{api}-backend-cred" when empty.
	Name string `json:"name"`
}

// Observability declares where a gateway emits its transactional analytics feed
// (ADR-070). The schema (stoa.txn) and the redaction authority live at the
// COLLECTOR (Data Prepper) — the gateway only EMITS metadata (+ conditional
// error body/headers). On APISIX the adapter projects this onto a kafka-logger
// plugin carrying a tenant tag so the collector can route txn-{tenant}-*.
//
// KafkaBroker lives on the GATEWAY's network horizon (the docker-internal name
// on the compose network, e.g. poc-analytics-redpanda:9092) — NOT a host-mapped
// port: the kafka-logger producer runs INSIDE the gateway container.
type Observability struct {
	// KafkaBroker is the Kafka/Redpanda bootstrap endpoint "host:port" the
	// gateway's logger publishes to (reachable FROM the gateway container).
	KafkaBroker string `json:"kafkaBroker"`

	// Topic is the explicit destination topic. When empty it defaults to
	// "{TopicPrefix}.{gateway-type}" (e.g. stoa.txn.apisix) so one prefix drives
	// the per-gateway topic convention from ADR-070 (3 topics per gateway).
	Topic string `json:"topic"`

	// TopicPrefix seeds the per-gateway topic name when Topic is empty.
	// Defaults to "stoa.txn" (the ADR-070 bus convention).
	TopicPrefix string `json:"topicPrefix"`

	// Tenant tags every emitted record so the collector can route the
	// tenant-isolated index (txn-{tenant}-*). When empty, Load defaults it from
	// backstage.owner (the ADR-070 owner→tenant derivation: accounts-team).
	Tenant string `json:"tenant"`
}

// InboundAuth declares the trusted JWT issuer a gateway must enforce on
// incoming calls. Gateways consume DIFFERENT projections of the same trust
// anchor, so the block carries both shapes (per-type validation in Load keeps
// it fail-closed):
//   - webMethods needs the raw Issuer+JwksURI pair (auth-server alias);
//   - APISIX needs the DiscoveryURL (openid-connect resolves issuer + jwks_uri
//     from the discovery document itself).
//
// The URLs live on DIFFERENT network horizons (the recurring split-horizon
// trap):
//   - Issuer must equal the token's iss claim EXACTLY (the host-pinned
//     Keycloak URL — what the CLIENT saw when the token was minted);
//   - JwksURI and DiscoveryURL must be reachable FROM THE GATEWAY CONTAINER
//     (the docker-internal name on the compose network).
type InboundAuth struct {
	Issuer  string `json:"issuer"`
	JwksURI string `json:"jwksUri"`

	// DiscoveryURL is the OIDC discovery document (.well-known/openid-
	// configuration) for gateways that derive issuer+JWKS from it (APISIX
	// openid-connect). Required for apisix targets; ignored by webMethods.
	DiscoveryURL string `json:"discoveryUrl"`

	// AliasName names the gateway-side auth-server alias holding the
	// issuer+JWKS trust anchor. Optional; the adapter falls back to a stable
	// default so re-applies converge on one alias.
	AliasName string `json:"aliasName"`

	// Audience is the OAuth2 audience the gateway binds the consumer to
	// (webMethods strategy.audience + scope.audience). It MUST equal the `aud`
	// claim `labctl subscribe` writes into the Keycloak token (audience mapper).
	// Presence of Audience switches the webMethods inbound projection from
	// signature-only (applicationLookup=open, jwtClaims) to the FULL OAuth2 path
	// (strategy + application identifier + scope mapping + applicationLookup
	// strict / openIdClaims). Optional; absent keeps the signature-only behavior.
	Audience string `json:"audience"`

	// Scope is the OAuth scope the gateway requires on the token (webMethods
	// scope mapping requiredAuthScopes[].scopeName). It MUST equal a scope
	// `labctl subscribe` grants the Keycloak consumer (client scope). Required
	// when Audience is set (the OAuth2 path enforces a scope); ignored on the
	// signature-only path.
	Scope string `json:"scope"`

	// ClientID is the Keycloak OAuth clientId the OAuth2 strategy is bound to and
	// the value the application identifier matches the token's `azp` against. It
	// MUST equal keycloak.consumerClientId (the client `labctl subscribe` mints).
	// When empty on the OAuth2 path, Load defaults it from keycloak
	// .consumerClientId so the manifest does not repeat the clientId. Ignored on
	// the signature-only path.
	ClientID string `json:"clientId"`

	// IntrospectionEndpoint switches the webMethods auth-server alias from
	// OFFLINE JWKS validation (localIntrospectionConfig, which does NOT enforce
	// the aud claim — the proven 3/4 hole) to REMOTE RFC 7662 introspection
	// (remoteIntrospectionConfig). Under remote introspection the authorization
	// server returns active/aud/azp/scope on every request and the gateway's
	// resource-server path actually CHECKS the audience against strategy.audience
	// — turning aud into the 4th barrier. Like JwksURI it must be reachable FROM
	// THE GATEWAY CONTAINER (the docker-internal name: keycloak:8080, NOT the
	// host-pinned issuer URL). Optional; presence enriches the alias with the
	// remote block (localIntrospectionConfig is kept as a signature fallback).
	// Cost: NO native introspection cache on 10.15 — 1 call to the AS PER
	// request (CAB-938). Ignored on the signature-only path (no audience).
	IntrospectionEndpoint string `json:"introspectionEndpoint"`

	// IntrospectionClientID / IntrospectionClientSecret are the CONFIDENTIAL
	// gateway client the alias authenticates with at the introspection endpoint
	// (RFC 7662 client auth). Distinct from ClientID (the consumer's azp): this
	// is the gateway's own credential. Default poc-gateways / poc-gateways-secret
	// (the same client WSO2 and Keycloak already use). Ignored unless
	// IntrospectionEndpoint is set.
	IntrospectionClientID     string `json:"introspectionClientId"`
	IntrospectionClientSecret string `json:"introspectionClientSecret"`

	// IntrospectionUser is the API Gateway user the remote introspection call
	// runs as. REQUIRED by webMethods 10.15 (the alias validator rejects a remote
	// block with an empty Gateway user). When empty the adapter defaults it from
	// the target's Basic-auth username. Ignored unless IntrospectionEndpoint set.
	IntrospectionUser string `json:"introspectionUser"`

	// Mtls, when true, requires a trusted CLIENT CERTIFICATE at the IAM stage IN
	// ADDITION to the OAuth2 token (ADR-076 VH leg): the Identify & Authorize
	// action ANDs an httpsCertificate rule with oAuth2Token, so a no-cert request
	// is rejected 401 at IAM even on a clientAuth=request listener (mTLS enforced
	// per-API, not per-port). The client cert must be registered on the consumer
	// application (labctl subscribe publicCertRef). Requires the OAuth2 path
	// (Audience set). Absent = OAuth2 only (no cert requirement).
	Mtls bool `json:"mtls"`
}

// Keycloak holds the out-of-band OAuth client settings used by `labctl subscribe`.
type Keycloak struct {
	URL   string `json:"url"`
	Realm string `json:"realm"`
	Admin struct {
		Username string `json:"username"`
		Password string `json:"password"`
	} `json:"admin"`
	ConsumerClientID     string `json:"consumerClientId"`
	ConsumerClientSecret string `json:"consumerClientSecret"`
}

// Backstage holds catalog registration settings (Phase 3).
type Backstage struct {
	URL    string `json:"url"`
	Owner  string `json:"owner"`
	System string `json:"system"`
}

// ToConfig projects a Target onto the adapter construction Config, folding the
// adapter-specific knobs into Options.
func (t Target) ToConfig() adapter.Config {
	opts := map[string]string{
		"gatewayEnv":   t.GatewayEnv,
		"vhost":        t.Vhost,
		"consumerAuth": t.ConsumerAuth,
	}
	// ADR-079 gate. Emitted ONLY when the target states it: an absent key lets
	// the adapter apply its documented default (true), so files that never
	// mention the knob keep the behaviour they have today.
	if t.AllowDeactivate != nil {
		opts["allowDeactivate"] = strconv.FormatBool(*t.AllowDeactivate)
	}
	if t.InboundAuth != nil {
		opts["inboundAuthIssuer"] = t.InboundAuth.Issuer
		opts["inboundAuthJwksUri"] = t.InboundAuth.JwksURI
		opts["inboundAuthDiscoveryUrl"] = t.InboundAuth.DiscoveryURL
		opts["inboundAuthAliasName"] = t.InboundAuth.AliasName
		opts["inboundAuthAudience"] = t.InboundAuth.Audience
		opts["inboundAuthScope"] = t.InboundAuth.Scope
		opts["inboundAuthClientId"] = t.InboundAuth.ClientID
		opts["inboundAuthIntrospectionEndpoint"] = t.InboundAuth.IntrospectionEndpoint
		opts["inboundAuthIntrospectionClientId"] = t.InboundAuth.IntrospectionClientID
		opts["inboundAuthIntrospectionClientSecret"] = t.InboundAuth.IntrospectionClientSecret
		opts["inboundAuthIntrospectionUser"] = t.InboundAuth.IntrospectionUser
		if t.InboundAuth.Mtls {
			opts["inboundMtls"] = "true"
		}
	}
	if t.Observability != nil {
		opts["observabilityKafkaBroker"] = t.Observability.KafkaBroker
		opts["observabilityTopic"] = t.Observability.Topic
		opts["observabilityTopicPrefix"] = t.Observability.TopicPrefix
		opts["observabilityTenant"] = t.Observability.Tenant
	}
	if t.Routing != nil {
		if ea := t.Routing.EndpointAlias; ea != nil {
			name := ea.Name
			if name == "" {
				name = "{api}-backend"
			}
			opts["routingEndpointAliasName"] = name
			opts["routingEndpointAliasUrl"] = ea.URL
		}
		if ca := t.Routing.CredentialAlias; ca != nil {
			name := ca.Name
			if name == "" {
				name = "{api}-backend-cred"
			}
			opts["routingCredentialAliasName"] = name
		}
	}
	if t.RateLimit != nil && t.RateLimit.Requests > 0 {
		opts["rateLimitRequests"] = strconv.Itoa(t.RateLimit.Requests)
		opts["rateLimitInterval"] = strconv.Itoa(t.RateLimit.Interval)
		opts["rateLimitUnit"] = t.RateLimit.Unit
	}
	if t.TransportProtocol != "" {
		opts["transportProtocol"] = t.TransportProtocol
	}
	return adapter.Config{
		Type:        t.Type,
		Name:        t.Name,
		AdminURL:    t.AdminURL,
		GatewayURL:  t.GatewayURL,
		Credentials: t.Credentials,
		Insecure:    t.Insecure,
		Options:     opts,
	}
}
