package apisix

// Inbound openid-connect projection for APISIX, mirroring the webMethods
// inboundAuth design: when the target's manifest carries an inboundAuth block,
// every route projected by Publish (and re-PUT by CreateConsumer) embeds the
// openid-connect plugin, so the data plane enforces 401-without-token /
// 200-with-token like the other gateways. Without the block the adapter's
// behavior is strictly unchanged.
//
// The payload is the LIVE-VALIDATED one (matrix 200 with token / 401 without,
// proven three times on the PoC stack): bearer_only resource-server mode with
// RS256 signature validation against the JWKS advertised by the discovery
// document. APISIX needs a DISCOVERY URL (not a raw issuer/jwksUri pair):
// the plugin resolves both from the document itself. Split-horizon note: the
// discovery URL must be reachable FROM THE APISIX CONTAINER (docker-internal
// keycloak:8080), while KC_HOSTNAME pins the advertised iss to the host-side
// URL the client saw when the token was minted.
//
// Because Publish/CreateConsumer PUT routes wholesale, this projection also
// closes the previous regression: a `labctl apply` no longer wipes the
// openid-connect plugin off the routes.

import (
	"fmt"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

// oidcClientID / oidcClientSecret satisfy the openid-connect plugin schema
// (client_id is mandatory) but are UNUSED at runtime in bearer_only+use_jwks
// mode: no redirect/code flow, no introspection, no token exchange — the
// plugin only checks the bearer token's signature against the JWKS. Stable
// constants keep re-applies byte-identical.
const (
	oidcClientID     = "apisix-gateway"
	oidcClientSecret = "unused"
)

// defaultOIDCRealm is the fallback realm label when the discovery URL does not
// follow the Keycloak /realms/<realm>/ shape. The realm only labels the
// WWW-Authenticate header on 401 responses — it plays no part in validation.
const defaultOIDCRealm = "stoa-lab"

// inboundDiscoveryFromConfig projects the generic adapter Config onto the
// inbound auth knob APISIX consumes: the discovery URL. Absent block -> ""
// (feature off, current behavior unchanged). A block present without
// discoveryUrl (e.g. only the issuer/jwksUri pair meant for webMethods) is a
// config bug surfaced at construction — fail closed, like the webMethods
// adapter does for its half-filled blocks.
func inboundDiscoveryFromConfig(cfg adapter.Config) (string, error) {
	discovery := cfg.Opt("inboundAuthDiscoveryUrl", "")
	issuer := cfg.Opt("inboundAuthIssuer", "")
	jwks := cfg.Opt("inboundAuthJwksUri", "")
	if discovery == "" && issuer == "" && jwks == "" {
		return "", nil
	}
	if discovery == "" {
		return "", fmt.Errorf("apisix: inboundAuth needs discoveryUrl (openid-connect derives issuer+jwks from the discovery document; got issuer=%q jwksUri=%q)", issuer, jwks)
	}
	return discovery, nil
}

// realmFromDiscovery extracts the realm from a Keycloak-shaped discovery URL
// (".../realms/<realm>/.well-known/openid-configuration"). Non-Keycloak shapes
// fall back to defaultOIDCRealm — cosmetic only (401 WWW-Authenticate label).
func realmFromDiscovery(discovery string) string {
	const marker = "/realms/"
	i := strings.Index(discovery, marker)
	if i < 0 {
		return defaultOIDCRealm
	}
	realm := discovery[i+len(marker):]
	if j := strings.IndexByte(realm, '/'); j >= 0 {
		realm = realm[:j]
	}
	if realm == "" {
		return defaultOIDCRealm
	}
	return realm
}

// openIDConnectPlugin returns the live-validated openid-connect route plugin:
//   - bearer_only=true: pure resource server — absent/invalid bearer token is
//     a hard 401, never a redirect to the IdP;
//   - use_jwks=true + RS256: validate the token signature against the
//     jwks_uri advertised by the discovery document (fetched in-network);
//   - ssl_verify=false: PoC-only (plain-HTTP Keycloak on the compose network);
//   - set_userinfo_header / set_id_token_header=false: no userinfo
//     round-trip, keep the upstream headers lean.
func openIDConnectPlugin(discovery string) map[string]any {
	return map[string]any{
		"discovery":                         discovery,
		"bearer_only":                       true,
		"use_jwks":                          true,
		"token_signing_alg_values_expected": "RS256",
		"ssl_verify":                        false,
		"client_id":                         oidcClientID,
		"client_secret":                     oidcClientSecret,
		"realm":                             realmFromDiscovery(discovery),
		"set_userinfo_header":               false,
		"set_id_token_header":               false,
	}
}

// routePlugins returns the plugins every projected route carries: the shared
// non-auth pair (proxy-rewrite, opentelemetry), plus — when the manifest
// configures them — the openid-connect inbound-auth enforcement and the
// kafka-logger transactional-analytics emission (ADR-070). Centralised here so
// Publish and CreateConsumer PUT the SAME plugin set and neither path can wipe
// the inbound auth (openid-connect) OR the analytics feed (kafka-logger) off a
// route. The api/apiVersion stamp the kafka-logger log_format with the per-API
// identity; they are inert when observability is off.
func (a *Adapter) routePlugins(basePath, backendPath, api, apiVersion string) map[string]any {
	p := sharedPlugins(basePath, backendPath)
	if a.oidcDiscovery != "" {
		p["openid-connect"] = openIDConnectPlugin(a.oidcDiscovery)
	}
	if a.kafkaLogger.enabled() {
		p["kafka-logger"] = a.kafkaLogger.kafkaLoggerPlugin(api, apiVersion)
	}
	return p
}
