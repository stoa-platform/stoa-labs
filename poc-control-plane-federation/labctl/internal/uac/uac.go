// Package uac loads a GOVERNANCE repo (the Console Light Git layout) and
// projects its UAC v1 contracts onto the gateway-agnostic adapter.NormalizedAPI
// handed to every adapter — the Console→CI→federation bridge: what governance
// published is what the gateways serve.
//
// Repo layout (schema source of truth: cmd/governance-api/uac_contract_v1_schema.json):
//
//	tenants/{tenant}/apis/{slug}/api.yaml           UAC v1 contract (slug == name)
//	tenants/{tenant}/apis/{slug}/deploy.{env}.yaml  {version, enabled, promoted_by, message}
//
// Only status=published contracts with at least one enabled deploy are
// projectable, and the projection is REST-only: llm/llm_config metadata is
// carried by the contract but has no meaning for the REST gateways, so an
// llm-only published contract is simply not projectable here.
package uac

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"sigs.k8s.io/yaml"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

// Contract lifecycle statuses (schema $defs.Status).
const (
	StatusDraft      = "draft"
	StatusPublished  = "published"
	StatusDeprecated = "deprecated"
)

// EnvAny selects the union of every environment with an enabled deploy.
const EnvAny = "any"

// Envs are the DEFAULT deploy environments the governance chain promotes
// through, in promotion order — also the canonical display order of
// EnabledEnvs. environments.yaml overrides them (see LoadEnvChain).
var Envs = []string{"dev", "staging", "production"}

// ValidEnv reports whether env is a known --env value (one of Envs or EnvAny).
// Chain-aware callers use ValidEnvIn against the loaded environments.yaml.
func ValidEnv(env string) bool { return ValidEnvIn(env, Envs) }

// Contract is the REST-relevant subset of a UAC v1 contract (api.yaml). Fields
// the projection does not need (classification, required_policies, llm_config,
// per-endpoint llm/schemas) are intentionally not modeled — yaml.Unmarshal
// drops them — so the package never pretends to enforce what it cannot project.
type Contract struct {
	Name        string     `json:"name"`
	Version     string     `json:"version"`
	TenantID    string     `json:"tenant_id"`
	DisplayName string     `json:"display_name"`
	Description string     `json:"description"`
	Status      string     `json:"status"`
	Endpoints   []Endpoint `json:"endpoints"`
}

// Endpoint is one UAC endpoint: path + methods like adapter.Endpoint, plus the
// per-endpoint backend_url the UAC schema mandates (and NormalizedAPI cannot
// carry — see Project) and the optional operationId.
type Endpoint struct {
	Path        string   `json:"path"`
	Methods     []string `json:"methods"`
	BackendURL  string   `json:"backend_url"`
	OperationID string   `json:"operation_id"`
}

// Deploy is one deploy.{env}.yaml marker: the Console writes it on publish
// (first env of the chain) and on approved promotion. Commit, when set, pins
// the api.yaml main SHA the gate approved (see ResolvePinned).
type Deploy struct {
	Version    string `json:"version"`
	Enabled    bool   `json:"enabled"`
	PromotedBy string `json:"promoted_by"`
	Message    string `json:"message"`
	Commit     string `json:"commit"`
	// ChangeRef pins the ITSM change that authorised THIS dispatched state
	// (written by the promotion that enabled the env, ADR-075/A6). The dispatch
	// gate re-checks it LIVE at apply time — anchoring the anti-TOCTOU check on
	// the state actually being dispatched, not on "some approved promotion".
	ChangeRef string `json:"change_ref"`
}

// API is one governed API as laid out in the repo: its coordinates
// (tenant/slug), the parsed contract and the per-environment deploy markers.
type API struct {
	Tenant   string
	Slug     string
	Path     string // api.yaml path, for diagnostics
	Contract Contract
	Deploys  map[string]Deploy // env -> deploy marker
}

// httpMethods is the schema's Endpoint.methods enum.
var httpMethods = map[string]bool{
	"GET": true, "POST": true, "PUT": true, "PATCH": true,
	"DELETE": true, "HEAD": true, "OPTIONS": true,
}

// nameRE is the schema's name pattern, verbatim: kebab-case, alphanumeric ends.
var nameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*[a-z0-9]$`)

// LoadRepo scans root for every tenants/*/apis/*/api.yaml contract and its
// deploy markers. The result is sorted by (tenant, slug) — deterministic
// projection order regardless of filesystem enumeration. Any malformed
// contract fails the WHOLE load: a governance repo is validated input, and the
// CI bridge must fail loudly rather than half-project a fleet.
func LoadRepo(root string) ([]API, error) {
	if _, err := os.Stat(root); err != nil {
		return nil, fmt.Errorf("governance repo: %w", err)
	}
	matches, err := filepath.Glob(filepath.Join(root, "tenants", "*", "apis", "*", "api.yaml"))
	if err != nil {
		return nil, fmt.Errorf("scan governance repo %s: %w", root, err)
	}
	if len(matches) == 0 {
		return nil, fmt.Errorf("governance repo %s: no tenants/*/apis/*/api.yaml contracts found", root)
	}
	sort.Strings(matches) // (tenant, slug) order
	apis := make([]API, 0, len(matches))
	for _, m := range matches {
		a, err := loadAPI(m)
		if err != nil {
			return nil, err
		}
		apis = append(apis, a)
	}
	return apis, nil
}

// loadAPI parses one api.yaml plus its sibling deploy.{env}.yaml markers and
// validates the contract identity. Endpoint completeness is enforced only for
// published contracts: drafts are work-in-progress by definition and may be
// incomplete without breaking the whole repo load.
func loadAPI(apiPath string) (API, error) {
	raw, err := os.ReadFile(apiPath)
	if err != nil {
		return API{}, fmt.Errorf("read UAC contract %s: %w", apiPath, err)
	}
	var c Contract
	if err := yaml.Unmarshal(raw, &c); err != nil {
		return API{}, fmt.Errorf("parse UAC contract %s: %w", apiPath, err)
	}

	dir := filepath.Dir(apiPath)
	slug := filepath.Base(dir)
	tenant := filepath.Base(filepath.Dir(filepath.Dir(dir)))

	if c.Name == "" {
		return API{}, fmt.Errorf("UAC contract %s: name is required", apiPath)
	}
	if !nameRE.MatchString(c.Name) {
		return API{}, fmt.Errorf("UAC contract %s: name %q is not a valid slug (^[a-z0-9][a-z0-9-]*[a-z0-9]$)", apiPath, c.Name)
	}
	if c.Name != slug {
		// Gateway identities (WSO2 name, APISIX ids, contexts) derive from the
		// name; a layout/contract disagreement is an identity ambiguity, not a
		// style nit.
		return API{}, fmt.Errorf("UAC contract %s: name %q does not match its directory slug %q", apiPath, c.Name, slug)
	}
	// Tenant integrity (anti-spoof): on a SHARED gateway the path tenant
	// (tenants/{tenant}/…) is the source-of-truth scope — who may write here is
	// controlled by the Git layout. A PUBLISHED contract that ALSO carries a
	// tenant_id MUST agree with its path, or it is claiming another tenant's
	// identity. Enforced on published only — drafts are work-in-progress and may
	// carry a placeholder; an absent tenant_id defers to the (authoritative) path.
	if c.Status == StatusPublished && c.TenantID != "" && c.TenantID != tenant {
		return API{}, fmt.Errorf("UAC contract %s: tenant_id %q does not match its path tenant %q (anti-spoof: a published contract may not claim another tenant)", apiPath, c.TenantID, tenant)
	}
	switch c.Status {
	case StatusDraft, StatusPublished, StatusDeprecated:
	case "":
		return API{}, fmt.Errorf("UAC contract %s: status is required", apiPath)
	default:
		return API{}, fmt.Errorf("UAC contract %s: unknown status %q (want draft|published|deprecated)", apiPath, c.Status)
	}
	if c.Status == StatusPublished {
		for i, e := range c.Endpoints {
			if e.Path == "" {
				return API{}, fmt.Errorf("UAC contract %s: endpoint #%d: path is required", apiPath, i)
			}
			if len(e.Methods) == 0 {
				return API{}, fmt.Errorf("UAC contract %s: endpoint %s: at least one method is required", apiPath, e.Path)
			}
			for _, m := range e.Methods {
				if !httpMethods[strings.ToUpper(m)] {
					return API{}, fmt.Errorf("UAC contract %s: endpoint %s: unknown method %q", apiPath, e.Path, m)
				}
			}
			if e.BackendURL == "" {
				return API{}, fmt.Errorf("UAC contract %s: endpoint %s: backend_url is required", apiPath, e.Path)
			}
		}
	}

	deploys, err := loadDeploys(dir)
	if err != nil {
		return API{}, err
	}
	return API{Tenant: tenant, Slug: slug, Path: apiPath, Contract: c, Deploys: deploys}, nil
}

// loadDeploys parses every sibling deploy.{env}.yaml of one api.yaml.
func loadDeploys(dir string) (map[string]Deploy, error) {
	matches, err := filepath.Glob(filepath.Join(dir, "deploy.*.yaml"))
	if err != nil {
		return nil, fmt.Errorf("scan deploys in %s: %w", dir, err)
	}
	out := make(map[string]Deploy, len(matches))
	for _, m := range matches {
		env := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(m), "deploy."), ".yaml")
		if env == "" {
			continue // "deploy..yaml" names no environment
		}
		raw, err := os.ReadFile(m)
		if err != nil {
			return nil, fmt.Errorf("read deploy %s: %w", m, err)
		}
		var d Deploy
		if err := yaml.Unmarshal(raw, &d); err != nil {
			return nil, fmt.Errorf("parse deploy %s: %w", m, err)
		}
		out[env] = d
	}
	return out, nil
}

// EnabledEnvs returns the environments where this API has an enabled deploy,
// filtered by env: a concrete env yields at most that env; EnvAny yields the
// union, in canonical order (Envs first in promotion order, then any other
// environment found in the repo, alphabetically). Chain-aware callers use
// EnabledEnvsIn against the loaded environments.yaml.
func (a API) EnabledEnvs(env string) []string { return a.EnabledEnvsIn(env, Envs) }

// DriftWarnings reports the enabled deploys (restricted to envs) whose pinned
// version differs from the contract version. The projection always serves the
// CONTRACT version — the deploy pin is governance metadata — so the drift is
// surfaced as a warning, never silently resolved.
func (a API) DriftWarnings(envs []string) []string {
	var warns []string
	for _, e := range envs {
		if d, ok := a.Deploys[e]; ok && d.Version != "" && d.Version != a.Contract.Version {
			warns = append(warns, fmt.Sprintf(
				"deploy.%s pins version %s but the contract is %s — projecting the contract version",
				e, d.Version, a.Contract.Version))
		}
	}
	return warns
}

// Project maps the UAC contract onto the gateway-agnostic NormalizedAPI:
//
//	Name     = name (the slug)
//	Version  = version (schema-defaulted to 1.0.0)
//	BasePath = /{name}/v{major} — the PoC context convention, identical to
//	           internal/openapi's fallback so a UAC projection and an OpenAPI
//	           load of the same API land on the same public context
//	Endpoints = endpoints[] (path + methods), merged per path, sorted
//	BackendURL = backend_url of the FIRST endpoint (document order)
//	Spec      = a minimal synthesized OpenAPI 3 document, so adapters that
//	            upload a raw spec (WSO2 import-openapi) keep working
//
// KNOWN LIMITATION: NormalizedAPI carries ONE upstream while UAC carries one
// backend_url per endpoint. When the contract declares several distinct
// backends, the first wins and a warning is returned for the caller to surface
// on stderr — per-endpoint upstreams need an adapter-contract change.
func (a API) Project() (*adapter.NormalizedAPI, []string, error) {
	c := a.Contract
	if len(c.Endpoints) == 0 {
		return nil, nil, fmt.Errorf(
			"UAC contract %s/%s: no REST endpoints to project (llm-only contracts target the MCP plane, not the REST gateways)",
			a.Tenant, a.Slug)
	}
	version := c.Version
	if version == "" {
		version = "1.0.0" // schema default
	}
	basePath := "/" + c.Name + "/v" + majorOf(version)

	var warnings []string
	backend := c.Endpoints[0].BackendURL
	distinct := distinctBackends(c.Endpoints)
	if len(distinct) > 1 {
		warnings = append(warnings, fmt.Sprintf(
			"multiple distinct backend_urls (%s) — NormalizedAPI carries ONE upstream, taking the first (%s); per-endpoint backends are a known limitation of this projection",
			strings.Join(distinct, ", "), backend))
	}

	spec, err := synthesizeSpec(c, version, basePath)
	if err != nil {
		return nil, nil, fmt.Errorf("UAC contract %s/%s: synthesize OpenAPI: %w", a.Tenant, a.Slug, err)
	}

	return &adapter.NormalizedAPI{
		Name:       c.Name,
		Version:    version,
		BasePath:   basePath,
		BackendURL: backend,
		Endpoints:  mergeEndpoints(c.Endpoints),
		Spec:       spec,
	}, warnings, nil
}

// distinctBackends collects the distinct backend_url values in document order,
// so the multi-backend warning lists them deterministically with the winning
// (first) one first.
func distinctBackends(eps []Endpoint) []string {
	seen := map[string]bool{}
	var out []string
	for _, e := range eps {
		if !seen[e.BackendURL] {
			seen[e.BackendURL] = true
			out = append(out, e.BackendURL)
		}
	}
	return out
}

// mergeEndpoints folds the UAC endpoints onto adapter.Endpoint: same-path
// entries merge their methods (upper-cased, deduplicated, sorted) and the
// result is sorted by path. Deterministic order is REQUIRED, not cosmetic:
// adapters derive stable resource ids from the endpoint INDEX (see
// internal/openapi), so a shuffled order would break re-apply idempotency.
func mergeEndpoints(eps []Endpoint) []adapter.Endpoint {
	byPath := map[string]map[string]bool{}
	for _, e := range eps {
		ms := byPath[e.Path]
		if ms == nil {
			ms = map[string]bool{}
			byPath[e.Path] = ms
		}
		for _, m := range e.Methods {
			ms[strings.ToUpper(m)] = true
		}
	}
	out := make([]adapter.Endpoint, 0, len(byPath))
	for p, ms := range byPath {
		methods := make([]string, 0, len(ms))
		for m := range ms {
			methods = append(methods, m)
		}
		sort.Strings(methods)
		out = append(out, adapter.Endpoint{Path: p, Methods: methods})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out
}

// majorOf returns the leading numeric component of a semver-ish version (the
// schema enforces \d+\.\d+\.\d+), defaulting to "1" when none is parseable —
// the same convention as internal/openapi, so e.g. 1.0.0 -> "1", 0.3.0 -> "0".
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

// synthesizeSpec renders a minimal OpenAPI 3.0.3 document from the UAC
// contract, because some adapters upload the raw spec verbatim (WSO2
// import-openapi writes api.Spec as the multipart file) and a UAC projection
// has no on-disk OpenAPI to hand them. sigs.k8s.io/yaml marshals through
// encoding/json, whose map keys are sorted — the bytes are deterministic, so
// re-applies stay idempotent and tests can assert on content.
func synthesizeSpec(c Contract, version, basePath string) ([]byte, error) {
	info := map[string]any{
		"title":   orDefault(c.DisplayName, c.Name),
		"version": version,
	}
	if c.Description != "" {
		info["description"] = c.Description
	}
	paths := map[string]map[string]any{}
	for _, e := range c.Endpoints {
		ops := paths[e.Path]
		if ops == nil {
			ops = map[string]any{}
			// Les paramètres de chemin ({id}, {iban}…) DOIVENT être déclarés —
			// WSO2 rejette l'import sinon (900754 « Declared path parameter …
			// needs to be defined »). Déclaration au niveau du path item.
			if params := pathParams(e.Path); len(params) > 0 {
				ops["parameters"] = params
			}
			paths[e.Path] = ops
		}
		for _, m := range e.Methods {
			op := map[string]any{
				// "responses" is mandatory on an OpenAPI operation; a default
				// description keeps the synthesized document import-valid.
				"responses": map[string]any{"default": map[string]any{"description": "UAC-projected operation"}},
			}
			if e.OperationID != "" {
				op["operationId"] = e.OperationID
			}
			ops[strings.ToLower(m)] = op
		}
	}
	doc := map[string]any{
		"openapi": "3.0.3",
		"info":    info,
		"servers": []map[string]string{{"url": basePath}},
		"paths":   paths,
	}
	return yaml.Marshal(doc)
}

// pathParams extrait les paramètres {name} d'un chemin et les rend sous la
// forme OpenAPI requise (in: path, required: true, type string).
func pathParams(path string) []map[string]any {
	var params []map[string]any
	for _, seg := range strings.Split(path, "/") {
		if strings.HasPrefix(seg, "{") && strings.HasSuffix(seg, "}") && len(seg) > 2 {
			params = append(params, map[string]any{
				"name":     seg[1 : len(seg)-1],
				"in":       "path",
				"required": true,
				"schema":   map[string]any{"type": "string"},
			})
		}
	}
	return params
}

func orDefault(v, def string) string {
	if strings.TrimSpace(v) == "" {
		return def
	}
	return v
}
