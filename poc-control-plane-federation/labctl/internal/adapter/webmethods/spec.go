package webmethods

// 10.15 OpenAPI-import compatibility layer, ported from the live-validated
// career adapter (stoa-go internal/connect/adapters/webmethods_spec.go).
// The real product rejects or crashes on several constructs that are valid
// OpenAPI:
//   - OpenAPI 3.1.x documents (only 3.0.x is accepted)        -> downgradeOpenAPI31
//   - $ref / complex schemas inside response objects
//     (RefProperty parser crash)                              -> stripResponseSchemas
//   - lowercase securityScheme enums (oauth2/http/apiKey...)  -> fixSecuritySchemeTypes
//   - object-shaped ROOT externalDocs (wants a list there,
//     but an object on nested occurrences)                    -> fixExternalDocs
//
// specToJSON applies the full pipeline once per Publish, plus the labctl
// specific step of re-pointing servers[] at the authoritative backendUrl from
// targets.yaml (the gateway derives its native endpoint from servers[]).

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"sigs.k8s.io/yaml"
)

// wmNameRe captures characters webMethods rejects in apiName (it only accepts
// alphanumerics, hyphens, underscores and dots).
var wmNameRe = regexp.MustCompile(`[^a-zA-Z0-9._-]`)

// sanitizeWMName normalizes an API name to characters webMethods accepts.
func sanitizeWMName(name string) string {
	return wmNameRe.ReplaceAllString(name, "-")
}

// specToJSON turns the raw contract bytes (YAML or JSON, as read from disk)
// into the JSON document embedded as apiDefinition, after the 10.15
// compatibility fixes and the backend re-point. The contract is REQUIRED: the
// real product creates APIs by import, there is no minimal-create fallback.
func specToJSON(api *adapter.NormalizedAPI) ([]byte, error) {
	if len(api.Spec) == 0 {
		return nil, fmt.Errorf("contract document is required (real apigateway:10.15 creates APIs by OpenAPI import); load it via internal/openapi")
	}
	specJSON, err := yaml.YAMLToJSON(api.Spec)
	if err != nil {
		return nil, fmt.Errorf("convert contract %s to JSON: %w", api.SpecPath, err)
	}
	specJSON = downgradeOpenAPI31(specJSON)
	specJSON = fixExternalDocs(specJSON)
	specJSON = fixSecuritySchemeTypes(specJSON)
	specJSON = stripResponseSchemas(specJSON)
	specJSON = objectifyBooleanAdditionalProperties(specJSON)
	specJSON = injectBackendServer(specJSON, api.BackendURL)
	return specJSON, nil
}

// objectifyBooleanAdditionalProperties rewrites every boolean
// `additionalProperties: true|false` into the empty schema `{}`. JSON Schema
// allows the boolean form, but the 10.15 deserializer models
// additionalProperties as a Schema object and the PUT /apis update path
// REJECTS the boolean with a 500 ("Cannot construct instance of Schema …
// no boolean-argument constructor") — proven live: the POST import tolerates
// it, the re-apply PUT does not, breaking idempotence on any contract using
// the boolean form. `{}` is semantically equivalent to `true`; `false` is
// also mapped to `{}` because 10.15 cannot represent it at all and this
// projection never enforces payload schemas (the gateway proxies, the
// authority stays the contract in Git).
func objectifyBooleanAdditionalProperties(spec []byte) []byte {
	var parsed interface{}
	if err := json.Unmarshal(spec, &parsed); err != nil {
		return spec
	}
	if !objectifyBoolAddProps(parsed) {
		return spec
	}
	return safeMarshal(spec, parsed)
}

// objectifyBoolAddProps walks the decoded document and replaces boolean
// additionalProperties values in place, reporting whether anything changed.
func objectifyBoolAddProps(v interface{}) bool {
	changed := false
	switch node := v.(type) {
	case map[string]interface{}:
		if _, isBool := node["additionalProperties"].(bool); isBool {
			node["additionalProperties"] = map[string]interface{}{}
			changed = true
		}
		for _, child := range node {
			if objectifyBoolAddProps(child) {
				changed = true
			}
		}
	case []interface{}:
		for _, child := range node {
			if objectifyBoolAddProps(child) {
				changed = true
			}
		}
	}
	return changed
}

// injectBackendServer rewrites servers[] to the single authoritative upstream
// from targets.yaml. The gateway derives the native (proxied-to) endpoint from
// servers[].url on import; the PoC contract carries a path-only logical server
// ("/accounts-read/v1") which would leave the gateway with nothing real to
// proxy to. No-op when backendURL is empty (then an absolute servers[].url in
// the contract, if any, stays authoritative).
//
// ROUTING-BY-ALIAS NOTE: when the manifest carries a routing.endpointAlias
// block (routing.go) this injection STILL runs — the import requires a real
// servers[] entry to mint the native endpoint — but the EFFECTIVE backend is
// then the ${alias} the straightThroughRouting action is converged to: the
// alias value (per env) wins over whatever servers[] said at import time.
func injectBackendServer(spec []byte, backendURL string) []byte {
	if strings.TrimSpace(backendURL) == "" {
		return spec
	}
	var parsed map[string]interface{}
	if err := json.Unmarshal(spec, &parsed); err != nil {
		return spec
	}
	parsed["servers"] = []interface{}{
		map[string]interface{}{"url": backendURL},
	}
	return safeMarshal(spec, parsed)
}

// safeMarshal re-encodes parsed JSON and returns the bytes only when they
// round-trip to valid JSON. Any failure (marshal error, invalid bytes) falls
// back to the original spec so a transform can never corrupt the payload.
func safeMarshal(orig []byte, parsed interface{}) []byte {
	fixed, err := json.Marshal(parsed)
	if err != nil {
		return orig
	}
	if !json.Valid(fixed) {
		return orig
	}
	return fixed
}

// downgradeOpenAPI31 rewrites an OpenAPI 3.1.x spec to 3.0.3 — webMethods only
// accepts OpenAPI 3.0.x. The version is read from the decoded top-level
// `openapi` field only (never a raw byte scan, which could false-match docs
// strings).
func downgradeOpenAPI31(spec []byte) []byte {
	var parsed map[string]interface{}
	if err := json.Unmarshal(spec, &parsed); err != nil {
		return spec
	}
	v, ok := parsed["openapi"].(string)
	if !ok || !strings.HasPrefix(v, "3.1.") {
		return spec
	}
	parsed["openapi"] = "3.0.3"
	return safeMarshal(spec, parsed)
}

// normalizeExternalDocs recursively walks any JSON value and normalizes
// externalDocs to the mixed shape expected by webMethods imports: the ROOT
// externalDocs as a list, nested occurrences (tags, operations, schemas) as a
// single object. Returns true if any normalization was performed.
func normalizeExternalDocs(v interface{}, root bool) bool {
	modified := false
	switch val := v.(type) {
	case map[string]interface{}:
		if ed, ok := val["externalDocs"]; ok {
			if root {
				if obj, isObj := ed.(map[string]interface{}); isObj {
					val["externalDocs"] = []interface{}{obj}
					modified = true
				}
			} else if arr, isArr := ed.([]interface{}); isArr && len(arr) == 1 {
				if obj, isObj := arr[0].(map[string]interface{}); isObj {
					val["externalDocs"] = obj
					modified = true
				}
			}
		}
		for _, child := range val {
			if normalizeExternalDocs(child, false) {
				modified = true
			}
		}
	case []interface{}:
		for _, item := range val {
			if normalizeExternalDocs(item, false) {
				modified = true
			}
		}
	}
	return modified
}

// fixExternalDocs walks the full OpenAPI document and keeps externalDocs in
// the mixed shape accepted by webMethods (see normalizeExternalDocs).
// Malformed input is returned unchanged; an unmodified walk returns the
// original bytes to preserve key ordering.
func fixExternalDocs(spec []byte) []byte {
	var parsed interface{}
	if err := json.Unmarshal(spec, &parsed); err != nil {
		return spec
	}
	if !normalizeExternalDocs(parsed, true) {
		return spec
	}
	return safeMarshal(spec, parsed)
}

// fixSecuritySchemeTypes uppercases securityScheme enum values — webMethods
// expects OAUTH2/HTTP/APIKEY/OPENIDCONNECT, HEADER/QUERY/COOKIE and
// BASIC/BEARER/DIGEST where OpenAPI uses lowercase.
func fixSecuritySchemeTypes(spec []byte) []byte {
	var parsed map[string]interface{}
	if err := json.Unmarshal(spec, &parsed); err != nil {
		return spec
	}

	components, ok := parsed["components"].(map[string]interface{})
	if !ok {
		return spec
	}
	schemes, ok := components["securitySchemes"].(map[string]interface{})
	if !ok {
		return spec
	}

	modified := false
	for name, v := range schemes {
		scheme, ok := v.(map[string]interface{})
		if !ok {
			continue
		}
		for _, field := range []string{"type", "in", "scheme"} {
			if val, ok := scheme[field].(string); ok {
				upper := strings.ToUpper(val)
				if upper != val {
					scheme[field] = upper
					modified = true
				}
			}
		}
		schemes[name] = scheme
	}

	if !modified {
		return spec
	}
	return safeMarshal(spec, parsed)
}

// stripResponseSchemas removes schema bodies from response objects in both
// Swagger 2.0 and OpenAPI 3.x specs — the 10.15 RefProperty parser crashes on
// $ref inside response schema objects, and response schemas aren't needed for
// gateway routing.
//
// Covered sites:
//   - Swagger 2.0:  paths[*].<method>.responses.<code>.schema
//   - OpenAPI 3.x:  paths[*].<method>.responses.<code>.content.<mime>.schema
func stripResponseSchemas(spec []byte) []byte {
	var parsed map[string]interface{}
	if err := json.Unmarshal(spec, &parsed); err != nil {
		return spec
	}

	paths, ok := parsed["paths"].(map[string]interface{})
	if !ok {
		return spec
	}

	modified := false
	for _, pathItem := range paths {
		pi, ok := pathItem.(map[string]interface{})
		if !ok {
			continue
		}
		for _, method := range []string{"get", "post", "put", "delete", "patch", "options", "head"} {
			op, ok := pi[method].(map[string]interface{})
			if !ok {
				continue
			}
			responses, ok := op["responses"].(map[string]interface{})
			if !ok {
				continue
			}
			for code, resp := range responses {
				r, ok := resp.(map[string]interface{})
				if !ok {
					continue
				}
				// Swagger 2.0 shape.
				if _, hasSchema := r["schema"]; hasSchema {
					delete(r, "schema")
					modified = true
				}
				// OpenAPI 3.x shape.
				if content, ok := r["content"].(map[string]interface{}); ok {
					for mime, mediaType := range content {
						mt, ok := mediaType.(map[string]interface{})
						if !ok {
							continue
						}
						if _, hasSchema := mt["schema"]; hasSchema {
							delete(mt, "schema")
							content[mime] = mt
							modified = true
						}
					}
				}
				responses[code] = r
			}
		}
	}

	if !modified {
		return spec
	}
	return safeMarshal(spec, parsed)
}
