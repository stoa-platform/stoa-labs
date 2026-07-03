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
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/render"
)

// uacFlag is the --uac override: an explicit UAC contract path (forces the
// gate ON even without a colocated api.yaml).
var uacFlag string

// enforcementSpec is the loaded, derived gate input for one apply run.
type enforcementSpec struct {
	contractPath string
	contract     render.ContractSubset
	req          adapter.EnforcementRequirement
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
	res, err := render.Derive(c.Input())
	if err != nil {
		// Same code as the validate-side gate: an underivable contract must not
		// merge NOR deploy.
		return nil, fmt.Errorf("[%s] %s: %w", render.CodeIntegrityInconsistent, path, err)
	}
	return &enforcementSpec{contractPath: path, contract: c, req: enforce.Requirement(c, res)}, nil
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
