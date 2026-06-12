package apisix

import (
	"context"
	"fmt"
	"net/http"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// CreateConsumer provisions an APISIX-native consumer and binds it to the
// already-published routes so the protected data plane becomes callable.
//
// Ordering matters: the consumer (carrying its credential) is created FIRST,
// then the auth plugin is enabled on every route. Doing it in this order avoids
// a 401 window where the route demands auth but no consumer can satisfy it.
//
// For jwt-auth we additionally publish a public sign route exposing
// /apisix/plugin/jwt/sign (not exposed by default) so the client can mint a
// token. The minted token is sent RAW in the Authorization header — NO "Bearer "
// prefix (APISIX's default jwt-auth header carries the bare token).
func (a *Adapter) CreateConsumer(ctx context.Context, api *adapter.NormalizedAPI, spec *adapter.ConsumerSpec) (*adapter.ConsumerResult, error) {
	// Resolve the auth model: spec wins, else the target/default.
	authType := spec.AuthType
	if authType != "jwt-auth" && authType != "key-auth" {
		authType = a.auth
	}

	username := sanitizeUsername(spec.Name)

	res := &adapter.ConsumerResult{
		Gateway:    gatewayName,
		ConsumerID: username,
	}

	// Idempotency: fetch the consumer's existing credential so a re-run CONVERGES
	// on the same secret rather than minting a fresh one (which would invalidate
	// every token/apikey already issued). A spec-supplied value still wins; we
	// only fall back to the stored credential before generating a brand-new one.
	existing, err := a.existingConsumerCreds(ctx, username)
	if err != nil {
		return nil, fmt.Errorf("apisix consumer %s: %w", username, err)
	}

	// 1. CONSUMER — username goes in the BODY; only PUT is supported (no POST).
	switch authType {
	case "key-auth":
		key := firstNonEmpty(spec.Key, existing["key-auth"].Key)
		if key == "" {
			gen, err := generateSecret()
			if err != nil {
				return nil, fmt.Errorf("apisix consumer %s: %w", username, err)
			}
			key = gen
		}
		body := consumerBody{
			Username: username,
			Plugins: map[string]any{
				"key-auth": map[string]any{"key": key},
			},
		}
		if err := a.putConsumer(ctx, body); err != nil {
			return nil, fmt.Errorf("apisix consumer %s: %w", username, err)
		}
		res.ConsumerKey = key
		// SECURITY: never interpolate the raw apikey into TokenHint — it is
		// printed verbatim on stdout (subscribe.go) and would leak the secret to
		// the terminal/CI logs/scrollback. Emit a TEMPLATE; the actual key is
		// surfaced (truncated) via the CREDENTIAL column from res.ConsumerKey.
		res.TokenHint = fmt.Sprintf(
			"send header  apikey: <key>  to %s%s (NO Bearer)",
			a.gwURL, api.BasePath)

	case "jwt-auth":
		// key claim: spec wins, else the existing consumer's key, else the
		// username (a stable default — never random, so it is idempotent anyway).
		key := firstNonEmpty(spec.Key, existing["jwt-auth"].Key, username)
		// secret: spec wins, else REUSE the stored secret, else generate once.
		secret := firstNonEmpty(spec.Secret, existing["jwt-auth"].Secret)
		if secret == "" {
			gen, err := generateSecret()
			if err != nil {
				return nil, fmt.Errorf("apisix consumer %s: %w", username, err)
			}
			secret = gen
		}
		body := consumerBody{
			Username: username,
			Plugins: map[string]any{
				// HS256 by default (RS256 would need public_key/private_key).
				"jwt-auth": map[string]any{"key": key, "secret": secret},
			},
		}
		if err := a.putConsumer(ctx, body); err != nil {
			return nil, fmt.Errorf("apisix consumer %s: %w", username, err)
		}
		res.ConsumerKey = key
		res.ConsumerSecret = secret
		res.TokenHint = fmt.Sprintf(
			"token=$(curl -s '%s/apisix/plugin/jwt/sign?key=%s'); then header  Authorization: $token  (RAW token, NO Bearer prefix)",
			a.gwURL, key)
	}

	// Under inboundAuth, openid-connect (not the consumer apikey/jwt) enforces
	// the route. The consumer credential just provisioned is INERT (no route
	// names key-auth), so don't surface it as if the caller must send it —
	// override with a bearer-shaped hint and clear the unused credential so
	// subscribe never writes a misleading APISIX apikey to labctl-credentials.
	if a.oidcDiscovery != "" {
		res.ConsumerKey = ""
		res.ConsumerSecret = ""
		res.TokenHint = fmt.Sprintf(
			"present the Keycloak bearer token to %s%s (validated by openid-connect; NO apikey)",
			a.gwURL, api.BasePath)
	}

	// 2. ENFORCE auth on every published route by merging an EMPTY auth plugin
	//    object (plus the shared non-auth plugins) onto each route id.
	endpoints := api.Endpoints
	if len(endpoints) == 0 {
		endpoints = []adapter.Endpoint{{Path: "/"}}
	}
	for i, ep := range endpoints {
		route := routeBody{
			URI:       routeURI(api.BasePath, ep.Path),
			Methods:   ep.Methods,
			Status:    1,
			ServiceID: api.Name,
			Plugins:   a.pluginsWithAuth(api.BasePath, backendBasePath(api.BackendURL), authType, api.Name, api.Version),
			// Re-stamp labels: a PUT replaces the whole route object, so without
			// these the publish-time Name/Version labels would be wiped here.
			Labels: routeLabels(api.Name, api.Version, api.BasePath),
		}
		rURL := fmt.Sprintf("%s/apisix/admin/routes/%s-%d", a.adminURL, api.Name, i)
		if _, err := httpx.JSON(ctx, a.client, http.MethodPut, rURL, a.adminHeaders(), route, nil); err != nil {
			return nil, fmt.Errorf("apisix consumer %s: enable %s on route %d: %w", username, authType, i, err)
		}
	}

	// 3. jwt-auth ONLY (and only without inboundAuth) — provision the public
	//    sign route. Without it /apisix/plugin/jwt/sign returns 404. Requires
	//    'public-api' and 'jwt-auth' enabled in the APISIX plugins list. Under
	//    inboundAuth the route enforces openid-connect, so a jwt-sign endpoint
	//    would be dead weight.
	if authType == "jwt-auth" && a.oidcDiscovery == "" {
		signRoute := publicAPIRoute{
			URI: "/apisix/plugin/jwt/sign",
			Plugins: map[string]any{
				"public-api": map[string]any{},
			},
		}
		signURL := fmt.Sprintf("%s/apisix/admin/routes/%s-jwt-sign", a.adminURL, api.Name)
		if _, err := httpx.JSON(ctx, a.client, http.MethodPut, signURL, a.adminHeaders(), signRoute, nil); err != nil {
			return nil, fmt.Errorf("apisix consumer %s: put jwt sign route: %w", username, err)
		}
	}

	return res, nil
}

// putConsumer PUTs a consumer to /apisix/admin/consumers (username carried in
// the body, the only supported create method).
func (a *Adapter) putConsumer(ctx context.Context, body consumerBody) error {
	u := a.adminURL + "/apisix/admin/consumers"
	if _, err := httpx.JSON(ctx, a.client, http.MethodPut, u, a.adminHeaders(), body, nil); err != nil {
		return fmt.Errorf("put consumer: %w", err)
	}
	return nil
}

// pluginsWithAuth returns the route plugins (shared non-auth set + inbound
// openid-connect when configured — routePlugins) with the requested consumer
// auth plugin enabled via an EMPTY object ({} merely turns the plugin on; the
// route names no consumer — APISIX matches the incoming credential at request
// time). Building on routePlugins matters: this PUT replaces the whole route
// object, so composing from sharedPlugins alone would silently wipe the
// inbound openid-connect enforcement off the route.
func (a *Adapter) pluginsWithAuth(basePath, backendPath, authType, api, apiVersion string) map[string]any {
	p := a.routePlugins(basePath, backendPath, api, apiVersion)
	// Inbound openid-connect (manifest inboundAuth) IS the route's auth model:
	// do NOT layer the consumer key-auth/jwt-auth on top. The two are
	// incompatible — key-auth runs first in the auth phase and rejects the
	// Keycloak bearer with "Missing API key in request" (the regression this
	// guards). With inboundAuth off, the consumer auth plugin stays the
	// enforcement, exactly as before.
	if a.oidcDiscovery == "" {
		p[authType] = map[string]any{}
	}
	return p
}

// consumerBody is the PUT body for /apisix/admin/consumers.
type consumerBody struct {
	Username string         `json:"username"`
	Plugins  map[string]any `json:"plugins"`
}

// publicAPIRoute is the thin PUT body for the jwt-sign public route.
type publicAPIRoute struct {
	URI     string         `json:"uri"`
	Plugins map[string]any `json:"plugins"`
}
