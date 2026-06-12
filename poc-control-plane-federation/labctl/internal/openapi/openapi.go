// Package openapi parses an OpenAPI 3 contract ONCE into the gateway-agnostic
// adapter.NormalizedAPI handed to every adapter, so no adapter re-parses the
// spec. Parsing is intentionally light (info, servers, paths/methods): enough to
// drive WSO2 import-openapi, APISIX per-operation routes and webMethods basePath,
// without dragging in a full OpenAPI validator.
package openapi

import (
	"fmt"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"sigs.k8s.io/yaml"
)

// httpVerbs are the OpenAPI operation keys we treat as methods (lower-case as
// they appear in the document).
var httpVerbs = map[string]bool{
	"get": true, "put": true, "post": true, "delete": true,
	"patch": true, "head": true, "options": true, "trace": true,
}

type rawSpec struct {
	Info struct {
		Title   string `json:"title"`
		Version string `json:"version"`
	} `json:"info"`
	Servers []struct {
		URL string `json:"url"`
	} `json:"servers"`
	Paths map[string]map[string]any `json:"paths"`
}

// Load reads and normalises an OpenAPI file. nameOverride wins over the slugged
// title when non-empty (the title "Accounts Read API" slugs to
// "accounts-read-api", but the PoC wants the stable id "accounts-read").
// backendOverride is authoritative for the upstream the gateways proxy to.
func Load(path, nameOverride, backendOverride string) (*adapter.NormalizedAPI, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read contract %s: %w", path, err)
	}
	var spec rawSpec
	if err := yaml.Unmarshal(raw, &spec); err != nil {
		return nil, fmt.Errorf("parse OpenAPI %s: %w", path, err)
	}
	if spec.Info.Title == "" {
		return nil, fmt.Errorf("OpenAPI %s: info.title is required", path)
	}

	name := nameOverride
	if name == "" {
		name = Slug(spec.Info.Title)
	}

	basePath, backendFromServer := splitServer(firstServerURL(spec.Servers))
	backend := backendOverride
	if backend == "" {
		backend = backendFromServer // only set when servers[].url is absolute
	}

	api := &adapter.NormalizedAPI{
		Name:       name,
		Version:    orDefault(spec.Info.Version, "1.0.0"),
		BasePath:   basePath,
		BackendURL: backend,
		Endpoints:  endpoints(spec.Paths),
		Spec:       raw,
		SpecPath:   path,
	}
	if api.BasePath == "" {
		// Fall back to /<name>/v<major> so every gateway has a deterministic
		// context, consistent with the normal path derived from servers[].url
		// (e.g. "/accounts-read/v1") — otherwise two otherwise-identical APIs
		// would get divergent public contexts purely on servers[] presence.
		api.BasePath = "/" + name + "/v" + majorOf(api.Version)
	}
	return api, nil
}

// majorOf returns the leading numeric component of a semver-ish version,
// defaulting to "1" when none is parseable (api.Version is itself defaulted to
// "1.0.0" upstream, so this normally yields "1").
func majorOf(v string) string {
	v = strings.TrimSpace(v)
	if i := strings.IndexByte(v, '.'); i >= 0 {
		v = v[:i]
	}
	if v == "" {
		return "1"
	}
	return v
}

func firstServerURL(servers []struct {
	URL string `json:"url"`
}) string {
	if len(servers) > 0 {
		return servers[0].URL
	}
	return ""
}

// splitServer returns (basePath, absoluteBackend). For a path-only server url
// ("/accounts-read/v1") it returns that path and an empty backend. For an
// absolute url ("https://api.example/v1") it returns the path and the full url.
func splitServer(raw string) (basePath, backend string) {
	if raw == "" {
		return "", ""
	}
	u, err := url.Parse(raw)
	if err != nil {
		return "", ""
	}
	basePath = normalizePath(u.Path)
	if u.IsAbs() {
		backend = raw
	}
	return basePath, backend
}

func normalizePath(p string) string {
	p = strings.TrimRight(strings.TrimSpace(p), "/")
	if p == "" {
		return ""
	}
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	return p
}

func endpoints(paths map[string]map[string]any) []adapter.Endpoint {
	out := make([]adapter.Endpoint, 0, len(paths))
	for p, ops := range paths {
		var methods []string
		for verb := range ops {
			if httpVerbs[strings.ToLower(verb)] {
				methods = append(methods, strings.ToUpper(verb))
			}
		}
		if len(methods) == 0 {
			continue
		}
		sort.Strings(methods) // stable method order per endpoint
		out = append(out, adapter.Endpoint{Path: p, Methods: methods})
	}
	// Deterministic order is REQUIRED, not optional: Go map iteration is
	// randomized, and adapters derive stable resource ids from the endpoint
	// INDEX (e.g. the APISIX route id "<name>-<i>"). Without this sort a plain
	// re-apply would shuffle which operation maps to which id, creating
	// duplicate/orphan routes — a silent idempotency break. Sort by Path here so
	// every adapter inherits one canonical ordering.
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out
}

var nonSlug = regexp.MustCompile(`[^a-z0-9]+`)

// Slug turns "Accounts Read API" into "accounts-read-api".
func Slug(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	s = nonSlug.ReplaceAllString(s, "-")
	return strings.Trim(s, "-")
}

func orDefault(v, def string) string {
	if strings.TrimSpace(v) == "" {
		return def
	}
	return v
}
