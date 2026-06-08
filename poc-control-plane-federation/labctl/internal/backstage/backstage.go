// Package backstage materialises one labctl-published API as a Backstage
// catalog entity and registers it with a Backstage backend.
//
// PoC method = Catalog Locations REST API (the simplest, most robust one-shot
// path): labctl emits a SINGLE kind: API entity (apiVersion
// backstage.io/v1alpha1) that federates the N gateways the API was published to
// via labels (gateway.stoa.io/<gw>: "true") and annotations
// (stoa.io/<gw>-endpoint: <invocationURL>) — NOT N duplicated entities — then
// points a Backstage location at the served catalog-info.yaml.
//
// There is deliberately no "create entity" call: Backstage has no POST
// /entities; every entity must come from a location (or an Entity Provider).
// Idempotence is handled at registration time: a 409 ConflictError means the
// location already exists, which we treat as success (already registered).
package backstage

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"sigs.k8s.io/yaml"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

const (
	// apiVersion / kind are fixed for a first-class catalogue API entity. The
	// API kind is what surfaces in the Backstage API Explorer and carries the
	// OpenAPI definition plus owner/system relations.
	apiVersion = "backstage.io/v1alpha1"
	kind       = "API"

	// labelPrefix / annotationPrefix are our own reserved-domain prefixes;
	// backstage.io/ is reserved by Backstage itself so we never use it for our
	// federation metadata.
	labelPrefix      = "gateway.stoa.io/"
	annotationPrefix = "stoa.io/"

	// locationsPath is the Catalog Locations REST endpoint on the Backstage
	// backend (e.g. http://localhost:7007/api/catalog/locations).
	locationsPath = "/api/catalog/locations"
)

// EntityInput is the gateway-agnostic input from which a single federated
// kind: API entity is rendered. Endpoints maps each gateway it was published to
// (e.g. "wso2", "apisix", "webmethods") to its live data-plane invocation URL.
type EntityInput struct {
	// Name is the entity metadata.name; must be unique per (kind, namespace) and
	// match Backstage's name regex (e.g. "accounts-read").
	Name string

	// Owner is spec.owner (a group/user ref, e.g. "accounts-team").
	Owner string

	// System is spec.system, optionally rattaching the API to a System. Omitted
	// from the rendered YAML when empty.
	System string

	// SpecPath is the on-disk OpenAPI path embedded as spec.definition.$text
	// (e.g. "./apis/accounts-read.openapi.yaml").
	SpecPath string

	// Endpoints federates the multi-gateway publish result: gateway id ->
	// invocation URL. Each entry yields one label and one endpoint annotation.
	Endpoints map[string]string
}

// entity mirrors the Backstage entity envelope. Struct fields render in a
// stable order via sigs.k8s.io/yaml (which marshals through JSON tags), so the
// catalog-info.yaml is deterministic. Maps (labels/annotations) are key-sorted
// by sigs.k8s.io/yaml itself.
type entity struct {
	APIVersion string         `json:"apiVersion"`
	Kind       string         `json:"kind"`
	Metadata   entityMetadata `json:"metadata"`
	Spec       entitySpec     `json:"spec"`
}

type entityMetadata struct {
	Name        string            `json:"name"`
	Labels      map[string]string `json:"labels,omitempty"`
	Annotations map[string]string `json:"annotations,omitempty"`
}

type entitySpec struct {
	Type       string         `json:"type"`
	Lifecycle  string         `json:"lifecycle"`
	Owner      string         `json:"owner"`
	System     string         `json:"system,omitempty"`
	Definition specDefinition `json:"definition"`
}

// specDefinition carries the OpenAPI document by reference ($text), which
// Backstage resolves relative to the entity's location.
type specDefinition struct {
	Text string `json:"$text"`
}

// GenerateEntity renders a single federated kind: API catalog-info.yaml.
//
// For every gateway in in.Endpoints it adds:
//   - a boolean label   gateway.stoa.io/<gw>: "true"   (indexable/filterable)
//   - an annotation      stoa.io/<gw>-endpoint: <url>   (free-form value)
//
// The spec is fixed to type=openapi, lifecycle=experimental, with the OpenAPI
// document referenced via definition.$text -> in.SpecPath.
func GenerateEntity(in EntityInput) ([]byte, error) {
	if strings.TrimSpace(in.Name) == "" {
		return nil, fmt.Errorf("generate entity: empty metadata.name")
	}
	if strings.TrimSpace(in.SpecPath) == "" {
		return nil, fmt.Errorf("generate entity %q: empty spec definition path", in.Name)
	}

	labels := make(map[string]string, len(in.Endpoints))
	annotations := make(map[string]string, len(in.Endpoints))
	for _, gw := range sortedKeys(in.Endpoints) {
		url := in.Endpoints[gw]
		// One boolean label per gateway so the catalogue is filterable by which
		// gateways serve the API; one endpoint annotation per gateway for the
		// (free-form, URL-valued) invocation URL.
		labels[labelPrefix+gw] = "true"
		annotations[annotationPrefix+gw+"-endpoint"] = url
	}

	ent := entity{
		APIVersion: apiVersion,
		Kind:       kind,
		Metadata: entityMetadata{
			Name:        in.Name,
			Labels:      labels,
			Annotations: annotations,
		},
		Spec: entitySpec{
			Type:       "openapi",
			Lifecycle:  "experimental",
			Owner:      in.Owner,
			System:     in.System,
			Definition: specDefinition{Text: in.SpecPath},
		},
	}

	out, err := yaml.Marshal(ent)
	if err != nil {
		return nil, fmt.Errorf("generate entity %q: marshal yaml: %w", in.Name, err)
	}
	return out, nil
}

// RegisterLocation registers targetURL (the served catalog-info.yaml) with a
// Backstage backend via POST {backstageURL}/api/catalog/locations, body
// {"type":"url","target":targetURL}.
//
// Idempotence: a 201 (created) and a 409 (ConflictError — the location already
// exists) are BOTH treated as success, so re-running `labctl register` after a
// previous run converges instead of failing.
func RegisterLocation(ctx context.Context, backstageURL, targetURL string) error {
	if strings.TrimSpace(backstageURL) == "" {
		return fmt.Errorf("register location: empty backstage URL")
	}
	if strings.TrimSpace(targetURL) == "" {
		return fmt.Errorf("register location: empty target URL")
	}

	url := strings.TrimRight(backstageURL, "/") + locationsPath
	body := map[string]string{"type": "url", "target": targetURL}

	// httpx.NewClient(false): Backstage backend is plain HTTP/valid-TLS in the
	// PoC, no self-signed skip needed.
	code, err := httpx.JSON(ctx, httpx.NewClient(false), "POST", url, nil, body, nil)
	switch {
	case code == 409:
		// ConflictError: the location is already registered — that is success
		// for an idempotent register, even though httpx.JSON flags non-2xx as an
		// error.
		return nil
	case err != nil:
		return fmt.Errorf("register location %q: %w", targetURL, err)
	default:
		return nil
	}
}

// sortedKeys returns the keys of m in deterministic (sorted) order, so rendered
// labels/annotations and iteration are stable across runs.
func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
