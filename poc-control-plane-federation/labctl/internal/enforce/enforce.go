// Package enforce is the apply-side gate of "security = f(integrity)"
// (ADR-076 Phase 3, goal A1). Two fail-closed checks bracket the dispatch:
//
//   - PRE-APPLY (static, before ANY write): does the federation manifest
//     declare, per target, the knobs the derived bundle requires? A VH contract
//     whose target.yaml lacks the mTLS leg is refused with
//     [INTEGRITY_UNFULFILLED] and nothing is dispatched.
//   - POST-APPLY (read-back, per target after Publish): does the gateway's LIVE
//     state confirm the bundle? Evaluated by Gate over the adapter's
//     EnforcementReport; a required policy that is missing or unverifiable
//     (including "adapter has no read-back at all") is refused with
//     [ENFORCEMENT_UNCONFIRMED].
//
// The gate never overclaims and never silently trusts: verdicts are printed in
// full (enforced/degraded annotations included), and what cannot be confirmed
// FAILS. What this gate deliberately does NOT close (ADR-076 gap #1, goal A5):
// the classification itself is still declared by the project repo — the gate
// guarantees bundle(declared classification) ⊆ enforced, not that the declared
// classification is the RIGHT one (no anti-downgrade). A target implementing
// strictly more than the declared bundle triggers a warning for that reason.
package enforce

import (
	"fmt"
	"sort"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/render"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/targets"
)

// Machine-readable failure codes, surfaced in error messages ([CODE] prefix)
// and stable for CI consumers. INTEGRITY_INCONSISTENT (an underivable contract)
// stays owned by internal/governance — same code, same meaning, other site.
const (
	// CodeUnfulfilled: the manifest does not implement the derived bundle
	// (static pre-check, nothing written).
	CodeUnfulfilled = "INTEGRITY_UNFULFILLED"
	// CodeUnconfirmed: the gateway's read-back state does not confirm the
	// derived bundle (post-apply gate).
	CodeUnconfirmed = "ENFORCEMENT_UNCONFIRMED"
	// CodeUngoverned (goal A5): the deploying project owns no central
	// classification for this API — a governed deploy requires the API to be
	// classified in the central registry (no self-classification).
	CodeUngoverned = "CLASSIFICATION_UNGOVERNED"
	// CodeSpoofed (goal A5): the project contract declares a posture WEAKER than
	// (or a tenant different from) the central governance registry — a downgrade
	// attempt. The bundle is derived from the CENTRAL value regardless; this code
	// makes the attempt loud instead of a confusing downstream INTEGRITY_UNFULFILLED.
	CodeSpoofed = "CLASSIFICATION_SPOOFED"
)

// Requirement builds the read-back requirement from the loaded contract subset
// and its derived bundle. Exposure is reported effective (defaulted) so the
// requirement always matches what Derive actually used.
func Requirement(c render.ContractSubset, res render.Result) adapter.EnforcementRequirement {
	return adapter.EnforcementRequirement{
		Classification: c.Classification,
		Exposure:       render.EffectiveExposure(c.Exposure),
		Authn:          res.Authn,
		Policies:       res.RequiredPolicies,
	}
}

// PrecheckTarget statically checks that ONE manifest target declares the knobs
// the bundle requires, BEFORE anything is written. Returns hard violations
// (each fails the run) and non-blocking warnings.
//
// Per-type mapping (A1 scope — the webMethods leg is the reference; APISIX and
// WSO2 pre-checks only produce earlier/better failures, they can never make the
// run pass: rate-limit and audit-log are always in the bundle and only the
// webMethods adapter can verify them at read-back, so any non-wM target under
// enforcement is structurally red until goals A3/B1 wire those runtimes).
// Unknown target types get a warning and defer to the post-apply read-back,
// which stays fail-closed (no verifier => unverifiable => refused).
func PrecheckTarget(t targets.Target, req adapter.EnforcementRequirement) (violations, warnings []string) {
	known := t.Type == "webmethods" || t.Type == "apisix" || t.Type == "wso2"
	if !known {
		// A type absent from the adapter registry fails at adapter.New before
		// any read-back — either way the downstream stays fail-closed.
		warnings = append(warnings, fmt.Sprintf("type %q: pré-check indisponible — fail-closed en aval (construction d'adapter, puis read-back)", t.Type))
	}

	for _, p := range req.Policies {
		if !known {
			continue
		}
		switch t.Type {
		case "webmethods":
			switch p {
			case "oauth2":
				if t.InboundAuth == nil || t.InboundAuth.Audience == "" {
					violations = append(violations, "oauth2 requis (classification "+req.Classification+") mais le target ne déclare pas inboundAuth.audience (chemin OAuth2 complet)")
				}
			case "mtls":
				if t.InboundAuth == nil || !t.InboundAuth.Mtls {
					violations = append(violations, "mtls requis (classification "+req.Classification+") mais le target ne déclare pas inboundAuth.mtls: true (barrière IAM OAuth2 AND httpsCertificate)")
				} else if t.TransportProtocol != "https" {
					violations = append(violations, "mtls requis mais transportProtocol n'est pas \"https\" (l'API resterait joignable hors du listener TLS)")
				}
			case "rate-limit":
				if t.RateLimit == nil || t.RateLimit.Requests <= 0 {
					violations = append(violations, "rate-limit requis (tout niveau) mais le target ne déclare pas rateLimit.requests > 0")
				}
			case "apikey":
				violations = append(violations, "apikey requis mais le mode apiKey n'est pas projeté sur webMethods (écart ADR-076 #7)")
			case "audit-log", "ip-allowlist":
				// audit-log: global policy, confirmed at read-back (2 fixed-ID GETs).
				// ip-allowlist: consumer-side identifier on wM (subscribe leg) —
				// reported degraded at read-back, no apply-side knob to pre-check.
			default:
				violations = append(violations, fmt.Sprintf("policy %q inconnue du pré-check webmethods (fail-closed)", p))
			}
		case "apisix":
			switch p {
			case "oauth2":
				if t.InboundAuth == nil || t.InboundAuth.DiscoveryURL == "" {
					violations = append(violations, "oauth2 requis mais le target apisix ne déclare pas inboundAuth.discoveryUrl (plugin openid-connect)")
				}
			case "apikey":
				if t.ConsumerAuth != "key-auth" {
					violations = append(violations, "apikey requis mais consumerAuth n'est pas \"key-auth\"")
				}
			default:
				// mtls, rate-limit, audit-log, ip-allowlist: non projetés/vérifiés
				// sur APISIX en A1 (goal A3/B1).
				violations = append(violations, fmt.Sprintf("policy %q non projetable/vérifiable sur apisix en A1 (goal A3/B1) — fail-closed", p))
			}
		case "wso2":
			violations = append(violations, fmt.Sprintf("policy %q non projetable/vérifiable sur wso2 en A1 (goal B1) — fail-closed", p))
		}
	}

	// Anti-downgrade signal (ADR-076 gap #1, goal A5): a target that implements
	// strictly MORE than the declared bundle suggests the classification may have
	// been declared lower than the API's real integrity level. Warning only —
	// the gate is unidirectional by design in A1.
	if t.InboundAuth != nil && t.InboundAuth.Mtls && !hasPolicy(req.Policies, "mtls") {
		warnings = append(warnings, fmt.Sprintf("le target déclare inboundAuth.mtls alors que le bundle dérivé (classification %s) ne l'exige pas — classification sous-déclarée ? (écart ADR-076 #1, goal A5)", req.Classification))
	}

	return violations, warnings
}

// Gate evaluates a read-back report against the requirement: it returns the
// verdicts that FAIL the run — every required policy whose status is missing
// or unverifiable, plus a synthesized missing verdict for any required policy
// the report does not cover at all (fail-closed against a lazy verifier).
func Gate(req adapter.EnforcementRequirement, rep *adapter.EnforcementReport) []adapter.PolicyVerdict {
	var failing []adapter.PolicyVerdict
	seen := map[string]bool{}
	if rep != nil {
		for _, v := range rep.Verdicts {
			seen[v.Policy] = true
			if !hasPolicy(req.Policies, v.Policy) {
				continue // informational verdict on a non-required policy never gates
			}
			if v.Status == adapter.VerdictMissing || v.Status == adapter.VerdictUnverifiable {
				failing = append(failing, v)
			}
		}
	}
	for _, p := range req.Policies {
		if !seen[p] {
			failing = append(failing, adapter.PolicyVerdict{
				Policy: p,
				Status: adapter.VerdictMissing,
				Detail: "policy requise absente du rapport de read-back (fail-closed)",
			})
		}
	}
	sort.Slice(failing, func(i, j int) bool { return failing[i].Policy < failing[j].Policy })
	return failing
}

// Summary renders the failing verdicts as one compact line for error messages:
// "mtls=missing (…); oauth2=missing (…)".
func Summary(failing []adapter.PolicyVerdict) string {
	parts := make([]string, 0, len(failing))
	for _, v := range failing {
		s := v.Policy + "=" + v.Status
		if v.Detail != "" {
			s += " (" + v.Detail + ")"
		}
		parts = append(parts, s)
	}
	return strings.Join(parts, "; ")
}

func hasPolicy(policies []string, p string) bool {
	for _, x := range policies {
		if x == p {
			return true
		}
	}
	return false
}
