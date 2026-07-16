// Package govsource is the CENTRAL classification authority of "security =
// f(integrity)" (ADR-076 écart #1, goal A5). The integrity classification that
// drives the derived security bundle must NOT live in the project repo (the API
// team can edit it → downgrade a VH API to M to dodge mTLS). It lives in a
// central registry owned by data-governance, referenced read-only by the gate.
//
// ANTI-SPOOF ANCHOR: the lookup key is (OWNER, api) where OWNER is the
// non-editable project identity injected by the PLATFORM pipeline (PROJECT_NAME
// → LABCTL_PROJECT), NOT any field of the project's editable api.yaml. A project
// therefore sees only its OWN entries: it cannot point at another project's
// weaker row by rewriting tenant_id/name (the reviewer's B1 hole). The tenant is
// governed too — a mismatch between the contract's tenant_id and the registry's
// tenant is a spoof.
package govsource

import (
	"fmt"
	"os"

	"sigs.k8s.io/yaml"
)

// Entry is one governed API's central classification. owner is the authoritative
// (pipeline-injected) project identity; tenant/api/classification/exposure are
// assigned by data-governance.
type Entry struct {
	Owner          string `json:"owner"`
	Tenant         string `json:"tenant"`
	API            string `json:"api"`
	Classification string `json:"classification"`
	Exposure       string `json:"exposure"`
}

// Registry is the parsed central classification source.
type Registry struct {
	APIVersion      string  `json:"apiVersion"`
	Kind            string  `json:"kind"`
	Classifications []Entry `json:"classifications"`
}

// validClassifications / validExposures pin the governed enums. The central
// registry is AUTHORITATIVE, so a typo in it (e.g. "vh") must fail loud AT LOAD
// with a registry-specific error — not silently downstream as a project-blaming
// INTEGRITY_INCONSISTENT (review S1). Kept in sync with the UAC schema + render.
var (
	validClassifications = map[string]bool{"VH": true, "H": true, "M": true}
	validExposures       = map[string]bool{"internal": true, "external": true}
)

// Load reads, decodes AND validates the registry. FAIL-CLOSED (goal A5, review
// S1): when a caller has a source configured, a missing/unreadable/unparseable/
// INVALID file is a HARD error — never a silent fallback to the project-declared
// classification (that would re-open the spoof the registry exists to close).
func Load(path string) (*Registry, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read classification registry %s: %w", path, err)
	}
	var r Registry
	if err := yaml.Unmarshal(raw, &r); err != nil {
		return nil, fmt.Errorf("parse classification registry %s: %w", path, err)
	}
	if err := r.validate(); err != nil {
		return nil, fmt.Errorf("classification registry %s: %w", path, err)
	}
	return &r, nil
}

// validate rejects a malformed authoritative registry: every entry must name a
// non-empty owner/tenant/api, a known classification and a known exposure, and
// no (owner, api) may appear twice (a duplicate would make Lookup's first-match
// silently pick one — possibly the weaker — review M4).
func (r *Registry) validate() error {
	if len(r.Classifications) == 0 {
		return fmt.Errorf("aucune entrée (pas un registre de classification, ou vide) — le gate refuserait TOUTE API en UNGOVERNED")
	}
	seen := map[string]bool{}
	for i, e := range r.Classifications {
		where := fmt.Sprintf("entrée %d (owner=%q api=%q)", i, e.Owner, e.API)
		if e.Owner == "" || e.API == "" || e.Tenant == "" {
			return fmt.Errorf("%s: owner/tenant/api requis", where)
		}
		if !validClassifications[e.Classification] {
			return fmt.Errorf("%s: classification %q invalide (attendu VH, H ou M) — typo gouvernance", where, e.Classification)
		}
		if !validExposures[e.Exposure] {
			return fmt.Errorf("%s: exposure %q invalide (attendu internal ou external) — typo gouvernance", where, e.Exposure)
		}
		key := e.Owner + "/" + e.API
		if seen[key] {
			return fmt.Errorf("%s: (owner, api) dupliqué — ambigu, refusé", where)
		}
		seen[key] = true
	}
	return nil
}

// Lookup returns the central entry for (owner, api). ok=false when the project
// owns no such API — the gate turns that into CLASSIFICATION_UNGOVERNED, so a
// project cannot borrow another project's row by renaming its api.
func (r *Registry) Lookup(owner, api string) (Entry, bool) {
	for _, e := range r.Classifications {
		if e.Owner == owner && e.API == api {
			return e, true
		}
	}
	return Entry{}, false
}
