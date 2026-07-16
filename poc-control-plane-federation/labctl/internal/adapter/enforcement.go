// Enforcement read-back contract (ADR-076 Phase 3, goal A1): after a Publish,
// the dispatch loop asks the adapter to CONFIRM — by reading the gateway's live
// state, never the manifest intent — that the security bundle derived from the
// contract's integrity classification is actually enforced. Verification is an
// OPTIONAL capability (type-asserted), so adapters gain it one runtime at a
// time; an adapter that does not implement it is treated as UNVERIFIABLE by the
// gate — fail-closed, not silently trusted.
package adapter

import "context"

// Verdict statuses, from strongest to weakest. The gate (internal/enforce)
// fails a run when any REQUIRED policy is missing or unverifiable; enforced and
// degraded pass — degraded means "enforced through a documented weaker
// mechanism" (e.g. ip-allowlist carried by the consumer identifier instead of
// an API-level policy on webMethods) and is always annotated, never silent.
const (
	VerdictEnforced     = "enforced"     // read back from the gateway, matches the bundle
	VerdictDegraded     = "degraded"     // enforced via a documented weaker/structural mechanism
	VerdictMissing      = "missing"      // required but absent/drifted on the gateway
	VerdictUnverifiable = "unverifiable" // this adapter/runtime cannot confirm it
)

// EnforcementRequirement is the derived bundle (render.Derive output plus its
// inputs) one API must be observed to enforce. Policies uses the render policy
// identifiers (oauth2, mtls, rate-limit, audit-log, ip-allowlist, apikey).
type EnforcementRequirement struct {
	Classification string   // VH | H | M (as declared by the UAC contract)
	Exposure       string   // internal | external (effective, defaulted)
	Authn          string   // oauth2+mtls | oauth2 | apikey
	Policies       []string // sorted render.RequiredPolicies
}

// PolicyVerdict is one policy's read-back outcome. Detail carries ONLY
// whitelisted, non-secret facts (object names/ids, limits, barrier counts) —
// never a raw gateway record, never credentials.
type PolicyVerdict struct {
	Policy string `json:"policy"`
	Status string `json:"status"`
	Detail string `json:"detail,omitempty"`
}

// EnforcementReport is the full read-back result for one (API, gateway) pair.
type EnforcementReport struct {
	Verdicts []PolicyVerdict `json:"verdicts"`
}

// EnforcementVerifier is the optional adapter capability: read the LIVE state
// of the published API (by the exact gateway-native id Publish returned) and
// report, per required policy, whether the gateway enforces it. Implementations
// must be strictly READ-ONLY and must never overclaim: a leg that cannot be
// read on this runtime is unverifiable (or degraded when the weaker mechanism
// is documented), not enforced.
type EnforcementVerifier interface {
	VerifyEnforcement(ctx context.Context, apiID string, want EnforcementRequirement) (*EnforcementReport, error)
}
