package cmd

// Apply-side enforcement gate of "security = f(integrity)" (ADR-076 Phase 3,
// goal A1). Activation is by DISCOVERY: when an api.yaml (UAC contract) sits
// next to the federation manifest passed via -f — the repo-per-project layout —
// the gate derives the required bundle from its classification and brackets
// the dispatch with a static pre-check ([INTEGRITY_UNFULFILLED]) and a
// post-publish read-back ([ENFORCEMENT_UNCONFIRMED]). --uac points at a
// contract elsewhere. There is deliberately NO opt-out flag: a present
// contract always gates (fail-closed, no bypass); absence of a contract is the
// only off switch, and the PLATFORM pipeline makes the contract mandatory
// (stoa-platform-ci/deploy/deploy-one.yml fails when api.yaml is missing).

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/enforce"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/govsource"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/render"
)

// uacFlag is the --uac override: an explicit UAC contract path (forces the
// gate ON even without a colocated api.yaml).
var uacFlag string

// classificationSourceFlag / projectFlag drive the central-registry gate
// (goal A5). Both default to their env twins (LABCTL_CLASSIFICATION_SOURCE /
// LABCTL_PROJECT) set by the platform pipeline. When a source is configured the
// integrity classification comes from the CENTRAL registry (authoritative),
// keyed on the NON-EDITABLE project identity — never from the project's api.yaml.
var (
	classificationSourceFlag string
	projectFlag              string
)

// classificationSource / projectIdentity resolve flag-over-env (the flag wins;
// the env is how the pipeline injects them).
func classificationSource() string {
	if classificationSourceFlag != "" {
		return classificationSourceFlag
	}
	return os.Getenv("LABCTL_CLASSIFICATION_SOURCE")
}

func projectIdentity() string {
	if projectFlag != "" {
		return projectFlag
	}
	return os.Getenv("LABCTL_PROJECT")
}

// enforcementSpec is the loaded, derived gate input for one apply run.
type enforcementSpec struct {
	contractPath string
	contract     render.ContractSubset
	req          adapter.EnforcementRequirement
	// warnings are non-blocking notes (e.g. central over-declaration) surfaced
	// by runApply through the log writer — captured and json-mode-safe, unlike a
	// raw os.Stderr write.
	warnings []string
}

// loadEnforcement resolves the gate for this run: the --uac path when given,
// else an api.yaml colocated with the manifest, else nil (gate off, behavior
// strictly unchanged — verified: no such colocation exists outside the
// repo-per-project layout). Fail-closed on every present-but-broken shape: an
// unreadable/unparseable contract, a name that does not match the published
// API, or an underivable classification all refuse the run before any write.
func loadEnforcement(manifestPath, apiName string) (*enforcementSpec, error) {
	path := uacFlag
	if path == "" {
		cand := filepath.Join(filepath.Dir(manifestPath), "api.yaml")
		if _, err := os.Stat(cand); err != nil {
			return nil, nil // no contract discovered → gate off
		}
		path = cand
	}
	c, err := render.LoadContract(path)
	if err != nil {
		return nil, fmt.Errorf("[%s] contrat UAC %s: %w", enforce.CodeUnfulfilled, path, err)
	}
	if c.Name != apiName {
		return nil, fmt.Errorf("[%s] le contrat UAC %s porte name=%q mais le manifeste publie %q — colocalisation incohérente", enforce.CodeUnfulfilled, path, c.Name, apiName)
	}

	// A5: when a CENTRAL classification source is configured, the effective
	// classification/exposure come from the registry (authoritative), keyed on
	// the non-editable project identity — the project's api.yaml value becomes a
	// reference that must not be WEAKER. Without a source (dev-local / PR-gate),
	// behaviour is strictly A1 (project-declared classification).
	warnings, err := resolveCentralClassification(&c)
	if err != nil {
		return nil, err
	}

	res, err := render.Derive(c.Input())
	if err != nil {
		// Same code as the validate-side gate: an underivable contract must not
		// merge NOR deploy.
		return nil, fmt.Errorf("[%s] %s: %w", render.CodeIntegrityInconsistent, path, err)
	}
	return &enforcementSpec{contractPath: path, contract: c, req: enforce.Requirement(c, res), warnings: warnings}, nil
}

// resolveCentralClassification overrides the contract's classification/exposure
// with the CENTRAL governance registry when a source is configured (goal A5,
// ADR-076 écart #1). Anti-spoof invariants (all fail-closed):
//   - source set but no project identity → refuse (no governed lookup possible);
//   - registry unreadable → refuse (never silent fallback to project value);
//   - (project, api) absent from the registry → CLASSIFICATION_UNGOVERNED;
//   - api.yaml tenant_id != central tenant → CLASSIFICATION_SPOOFED (the tenant
//     is governed too; lying about it is a spoof);
//   - project posture WEAKER than central → CLASSIFICATION_SPOOFED (downgrade).
//
// On success the contract's Classification/Exposure are set to the CENTRAL
// values, so Derive produces the governed bundle regardless of what the project
// declared. A no-op when no source is configured (strict A1).
func resolveCentralClassification(c *render.ContractSubset) ([]string, error) {
	src := classificationSource()
	if src == "" {
		return nil, nil // no central source → A1 (project-declared), strictly unchanged
	}
	owner := projectIdentity()
	if owner == "" {
		return nil, fmt.Errorf("[%s] source de classification centrale configurée (%s) mais identité projet absente — poser LABCTL_PROJECT (PROJECT_NAME du pipeline) ; un lookup gouverné exige une identité non-éditable", enforce.CodeUngoverned, src)
	}
	reg, err := govsource.Load(src)
	if err != nil {
		// Fail-closed (review S1): a configured-but-broken source must NEVER
		// silently fall back to the project-declared classification.
		return nil, fmt.Errorf("[%s] %w", enforce.CodeUngoverned, err)
	}
	entry, ok := reg.Lookup(owner, c.Name)
	if !ok {
		return nil, fmt.Errorf("[%s] aucune classification centrale pour (projet=%q, api=%q) — une API gouvernée doit être classée dans le registre central (pas d'auto-classification) ; enregistrer via une PR gouvernance avant le 1er deploy", enforce.CodeUngoverned, owner, c.Name)
	}
	if c.TenantID != entry.Tenant {
		return nil, fmt.Errorf("[%s] l'api.yaml déclare tenant_id=%q mais la gouvernance assigne tenant=%q pour (projet=%q, api=%q) — le tenant est gouverné", enforce.CodeSpoofed, c.TenantID, entry.Tenant, owner, c.Name)
	}
	if render.Weaker(c.Classification, c.Exposure, entry.Classification, entry.Exposure) {
		return nil, fmt.Errorf("[%s] l'api.yaml déclare classification=%q/exposure=%q, PLUS FAIBLE que la gouvernance (%q/%q) pour %q — tentative de downgrade refusée",
			enforce.CodeSpoofed, c.Classification, render.EffectiveExposure(c.Exposure), entry.Classification, render.EffectiveExposure(entry.Exposure), c.Name)
	}
	var warnings []string
	if c.Classification != entry.Classification || render.EffectiveExposure(c.Exposure) != render.EffectiveExposure(entry.Exposure) {
		// Stronger-or-equal-but-different = over-declaration: harmless (the
		// bundle derives from central anyway). Surface it, don't block (review S3).
		warnings = append(warnings, fmt.Sprintf("classification centrale %s/%s appliquée (l'api.yaml déclarait %s/%s, sur-provisionné — le bundle vient du central)",
			entry.Classification, render.EffectiveExposure(entry.Exposure), c.Classification, render.EffectiveExposure(c.Exposure)))
	}
	// Authoritative: derive from the CENTRAL values.
	c.Classification = entry.Classification
	c.Exposure = entry.Exposure
	return warnings, nil
}

// verifyTargetEnforcement runs the post-publish read-back gate for one target:
// the adapter must implement EnforcementVerifier (no read-back = unverifiable
// = refused), its report must cover every required policy, and none may be
// missing/unverifiable. The full verdict list is returned even on failure so
// the report shows exactly what was and was not confirmed.
func verifyTargetEnforcement(ctx context.Context, ad adapter.Adapter, apiID string, req adapter.EnforcementRequirement) ([]adapter.PolicyVerdict, error) {
	v, ok := ad.(adapter.EnforcementVerifier)
	if !ok {
		return nil, fmt.Errorf("[%s] adapter %s: read-back d'enforcement non implémenté — état non confirmable (fail-closed; goals A3/B1)", enforce.CodeUnconfirmed, ad.Name())
	}
	rep, err := v.VerifyEnforcement(ctx, apiID, req)
	if err != nil {
		return nil, fmt.Errorf("[%s] %w", enforce.CodeUnconfirmed, err)
	}
	var verdicts []adapter.PolicyVerdict
	if rep != nil {
		verdicts = rep.Verdicts
	}
	if failing := enforce.Gate(req, rep); len(failing) > 0 {
		return verdicts, fmt.Errorf("[%s] %s", enforce.CodeUnconfirmed, enforce.Summary(failing))
	}
	return verdicts, nil
}
