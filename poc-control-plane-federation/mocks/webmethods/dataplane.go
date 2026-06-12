package main

// Data-plane PROBANT pour la démo multi-env: le mock ne proxifie RIEN, il
// PROUVE la résolution — contrat allowlist, routage ${alias} résolu PAR
// REQUÊTE (changer l'alias re-route instantanément, sans réactivation) et
// credential alias sortant (jamais le secret en clair). // The data-plane is
// evidence, not a proxy: it resolves the routing like the product would and
// returns the resolved URL as proof.
//
// GET/... /gateway/{apiName}/{apiVersion}/{resource...}
//   - unknown api/version            -> 404
//   - api imported but NOT activated -> 503 (import does not serve traffic)
//   - resource outside the imported apiDefinition paths -> 404 (allowlist)
//   - routing endpointUri resolved: ${<aliasName>} -> current endpoint alias
//     value, ${sys:resource_path} -> remaining path; a referenced alias that
//     does not exist fails CLOSED (502), never a silent passthrough
//   - an outboundTransportAuthentication ALIAS action resolves the credential
//     alias to "Basic <user>:***" (corruption surfaces when the stored
//     password was not base64 — the live storage trap)

import (
	"encoding/base64"
	"fmt"
	"net/http"
	"regexp"
	"strings"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
)

// placeholderRe captures every ${...} placeholder of a routing endpointUri.
var placeholderRe = regexp.MustCompile(`\$\{([^}]+)\}`)

// resourcePathVar is the product's per-request substitution variable.
const resourcePathVar = "sys:resource_path"

func (s *Server) dataPlane(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/gateway/")
	parts := strings.SplitN(rest, "/", 3)
	if len(parts) < 2 || parts[0] == "" || parts[1] == "" {
		s.dpFail(w, r, http.StatusNotFound, "data-plane path is /gateway/{apiName}/{apiVersion}/{resource}")
		return
	}
	name, version := parts[0], parts[1]
	resource := "/"
	if len(parts) == 3 && parts[2] != "" {
		resource = "/" + parts[2]
	}

	s.store.mu.RLock()
	defer s.store.mu.RUnlock()

	api := s.store.findAPIByNameVersion(name, version)
	if api == nil {
		s.dpFail(w, r, http.StatusNotFound, fmt.Sprintf("no API registered for %s/%s", name, version))
		return
	}
	if !api.IsActive {
		// Import alone does not serve traffic on the product: coherent 503.
		s.dpFail(w, r, http.StatusServiceUnavailable, fmt.Sprintf("API %s/%s is not active (PUT /rest/apigateway/apis/{id}/activate first)", name, version))
		return
	}
	if !resourceInContract(api.Definition, resource) {
		// Allowlist semantics: only the imported contract's paths are exposed.
		s.dpFail(w, r, http.StatusNotFound, fmt.Sprintf("resource %s is not part of the imported contract for %s/%s", resource, name, version))
		return
	}

	action := s.routingActionOf(api)
	if action == nil {
		s.dpFail(w, r, http.StatusBadGateway, "no straightThroughRouting action attached to the API policy")
		return
	}
	template := actionParamValue(action, "endpointUri")
	if template == "" {
		s.dpFail(w, r, http.StatusBadGateway, "routing action carries no endpointUri")
		return
	}
	resolved, aliasResolved, err := s.resolveEndpointURI(template, resource)
	if err != nil {
		// Fail closed: a routing alias that does not resolve is a 502, never a
		// silent passthrough to a half-substituted URL.
		s.dpFail(w, r, http.StatusBadGateway, err.Error())
		return
	}
	outboundAuth, err := s.resolveOutboundAuth(api)
	if err != nil {
		s.dpFail(w, r, http.StatusBadGateway, err.Error())
		return
	}

	s.dpCalls.Add(r.Context(), 1, metric.WithAttributes(
		attribute.String("api", api.APIName),
		attribute.String("version", api.APIVersion),
	))
	body := map[string]any{
		"mock":           true,
		"gateway":        "webmethods-mock",
		"api":            api.APIName,
		"version":        api.APIVersion,
		"resource":       resource,
		"resolved_url":   resolved,
		"alias_resolved": aliasResolved,
	}
	if outboundAuth != "" {
		body["outbound_auth"] = outboundAuth
	}
	writeJSON(w, http.StatusOK, body)
}

// dpFail counts and renders one data-plane refusal.
func (s *Server) dpFail(w http.ResponseWriter, r *http.Request, code int, msg string) {
	s.dpErrors.Add(r.Context(), 1)
	writeJSON(w, code, map[string]string{"error": msg})
}

// resourceInContract matches the resource against the imported apiDefinition
// paths, with OpenAPI template segments ({id} matches any one segment). An
// import with no paths exposes NOTHING (fail-closed allowlist).
func resourceInContract(def map[string]any, resource string) bool {
	paths, _ := def["paths"].(map[string]any)
	for tpl := range paths {
		if pathTemplateMatches(tpl, resource) {
			return true
		}
	}
	return false
}

// pathTemplateMatches compares segment by segment; "{param}" segments match
// any single non-empty segment (no wildcard suffix — allowlist, not prefix).
func pathTemplateMatches(tpl, resource string) bool {
	t := splitSegments(tpl)
	r := splitSegments(resource)
	if len(t) != len(r) {
		return false
	}
	for i := range t {
		if strings.HasPrefix(t[i], "{") && strings.HasSuffix(t[i], "}") {
			continue
		}
		if t[i] != r[i] {
			return false
		}
	}
	return true
}

func splitSegments(p string) []string {
	p = strings.Trim(p, "/")
	if p == "" {
		return nil
	}
	return strings.Split(p, "/")
}

// routingActionOf walks the API's policies and returns the FIRST
// straightThroughRouting action referenced by a routing stage.
// Caller MUST hold the store lock.
func (s *Server) routingActionOf(api *apiRecord) map[string]any {
	for _, act := range s.actionsOf(api, "routing") {
		if tk, _ := act["templateKey"].(string); tk == "straightThroughRouting" {
			return act
		}
	}
	return nil
}

// actionsOf collects the resolved action records referenced by the API's
// policy stages; stageKey "" means every stage. Caller MUST hold the lock.
func (s *Server) actionsOf(api *apiRecord, stageKey string) []map[string]any {
	var out []map[string]any
	for _, polID := range api.Policies {
		pol := s.store.policies[polID]
		if pol == nil {
			continue
		}
		stages, _ := pol["policyEnforcements"].([]any)
		for _, st := range stages {
			sm, _ := st.(map[string]any)
			if sm == nil {
				continue
			}
			if key, _ := sm["stageKey"].(string); stageKey != "" && key != stageKey {
				continue
			}
			enfs, _ := sm["enforcements"].([]any)
			for _, e := range enfs {
				em, _ := e.(map[string]any)
				if em == nil {
					continue
				}
				id, _ := em["enforcementObjectId"].(string)
				if act := s.store.actions[id]; act != nil {
					out = append(out, act)
				}
			}
		}
	}
	return out
}

// actionParamValue extracts values[0] of the named top-level parameter.
func actionParamValue(action map[string]any, templateKey string) string {
	params, _ := action["parameters"].([]any)
	return paramValue(params, templateKey)
}

// paramValue extracts values[0] of the named parameter in a parameter list.
func paramValue(params []any, templateKey string) string {
	for _, p := range params {
		pm, _ := p.(map[string]any)
		if pm == nil {
			continue
		}
		if tk, _ := pm["templateKey"].(string); tk != templateKey {
			continue
		}
		if values, _ := pm["values"].([]any); len(values) > 0 {
			s, _ := values[0].(string)
			return s
		}
	}
	return ""
}

// resolveEndpointURI substitutes ${sys:resource_path} with the remaining path
// and every other ${name} with the CURRENT value of the endpoint alias of that
// name — per request, like the product (an alias edit re-routes instantly).
// Reports whether at least one alias was substituted; a referenced alias that
// is missing or not of type endpoint is an error (fail closed).
// Caller MUST hold the store lock.
func (s *Server) resolveEndpointURI(template, resource string) (string, bool, error) {
	aliasResolved := false
	var resolveErr error
	out := placeholderRe.ReplaceAllStringFunc(template, func(m string) string {
		name := strings.TrimSuffix(strings.TrimPrefix(m, "${"), "}")
		if name == resourcePathVar {
			return strings.TrimPrefix(resource, "/")
		}
		al := s.store.aliasByName(name)
		if al == nil {
			resolveErr = fmt.Errorf("routing references alias %q which does not exist", name)
			return m
		}
		if t, _ := al["type"].(string); t != "endpoint" {
			resolveErr = fmt.Errorf("routing references alias %q of type %q (want endpoint)", name, t)
			return m
		}
		uri, _ := al["endPointURI"].(string)
		if uri == "" {
			resolveErr = fmt.Errorf("endpoint alias %q has an empty endPointURI", name)
			return m
		}
		aliasResolved = true
		return strings.TrimRight(uri, "/")
	})
	if resolveErr != nil {
		return "", false, resolveErr
	}
	return out, aliasResolved, nil
}

// resolveOutboundAuth finds an outboundTransportAuthentication action on the
// API's policy and resolves its ALIAS credential to "Basic <user>:***" — the
// password is NEVER echoed; a stored non-base64 password (the live corruption
// trap) surfaces explicitly. Returns "" when no outbound auth is configured.
// Caller MUST hold the store lock.
func (s *Server) resolveOutboundAuth(api *apiRecord) (string, error) {
	for _, act := range s.actionsOf(api, "") {
		if tk, _ := act["templateKey"].(string); tk != "outboundTransportAuthentication" {
			continue
		}
		group := transportSecurityParams(act)
		if paramValue(group, "authType") != "ALIAS" {
			return "", nil // only the ALIAS mode is modeled
		}
		ref := paramValue(group, "alias")
		name := strings.TrimSuffix(strings.TrimPrefix(ref, "${"), "}")
		if name == "" {
			return "", fmt.Errorf("outbound auth action carries no alias parameter")
		}
		al := s.store.aliasByName(name)
		if al == nil {
			return "", fmt.Errorf("outbound auth references credential alias %q which does not exist", name)
		}
		if t, _ := al["type"].(string); t != "httpTransportSecurityAlias" {
			return "", fmt.Errorf("outbound auth references alias %q of type %q (want httpTransportSecurityAlias)", name, t)
		}
		creds, _ := al["httpAuthCredentials"].(map[string]any)
		user, _ := creds["userName"].(string)
		stored, _ := creds["password"].(string)
		if _, err := base64.StdEncoding.DecodeString(stored); err != nil {
			// The live trap made visible: a password POSTed in clear (not base64)
			// is stored corrupted and the outbound call would fail on the product.
			return "Basic " + user + ":<CORRUPTED — password was not base64 at write>", nil
		}
		return "Basic " + user + ":***", nil
	}
	return "", nil
}

// transportSecurityParams returns the nested parameters of the single
// transportSecurity group (the only valid outbound-auth shape — see
// flatOutboundParams for the flat-body NPE reproduction).
func transportSecurityParams(action map[string]any) []any {
	params, _ := action["parameters"].([]any)
	for _, p := range params {
		pm, _ := p.(map[string]any)
		if pm == nil {
			continue
		}
		if tk, _ := pm["templateKey"].(string); tk == "transportSecurity" {
			nested, _ := pm["parameters"].([]any)
			return nested
		}
	}
	return nil
}
