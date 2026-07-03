// Package render derives the concrete security-policy bundle an API must carry
// from its data-integrity classification — the Phase-3 engine of ADR-076 that
// turns "security = f(integrity)" from a declaration into a machine-derived,
// fail-closed fact. The project repo declares a classification (+ exposure/tags);
// it NEVER picks its own policies. An unknown classification, or an inconsistent
// auth-exception, is REJECTED (fail-closed) — a project cannot ship a posture
// weaker than its integrity level.
package render

import (
	"fmt"
	"sort"
)

// Input is the security-relevant subset of a UAC contract.
type Input struct {
	Classification string   // VH | H | M
	Exposure       string   // internal | external | "" (defaults internal)
	Tags           []string // orthogonal key:value tags (e.g. auth-exception:apikey)
}

// Result is the derived authn method plus the ordered, deduped policy bundle.
type Result struct {
	Authn            string   // oauth2+mtls | oauth2 | apikey
	RequiredPolicies []string // stable, sorted policy identifiers
}

// AuthExceptionApiKey is the tag that (only for M + internal) swaps OAuth2 for
// an ApiKey-only posture — the single governed downgrade the client scale allows.
const AuthExceptionApiKey = "auth-exception:apikey"

// CodeIntegrityInconsistent is the machine code for "this contract's integrity
// level yields no valid bundle" — SHARED by the validate-side gate
// (governance.ValidateUAC) and the apply-side gate (cmd/labctl), so the code
// announced stable to CI consumers cannot drift between the two sites.
const CodeIntegrityInconsistent = "INTEGRITY_INCONSISTENT"

// EffectiveExposure is the single place the empty-exposure default lives:
// Derive, the enforcement requirement and the render command all report the
// SAME effective value.
func EffectiveExposure(exposure string) string {
	if exposure == "" {
		return "internal"
	}
	return exposure
}

// Derive computes the required policy bundle, fail-closed (ADR-076):
//
//	VH -> oauth2 + mtls ; H -> oauth2 ; M -> oauth2 (default)
//	M + tag auth-exception:apikey + exposure internal -> apikey (governed exception)
//	exposure external -> ip-allowlist mandatory
//	every tier -> rate-limit + audit-log
//
// Rejected: unknown classification/exposure; apikey exception on non-M or non-internal.
func Derive(in Input) (Result, error) {
	switch in.Classification {
	case "VH", "H", "M":
	default:
		return Result{}, fmt.Errorf("classification %q inconnue (attendu VH, H ou M)", in.Classification)
	}

	exposure := EffectiveExposure(in.Exposure)
	if exposure != "internal" && exposure != "external" {
		return Result{}, fmt.Errorf("exposure %q invalide (attendu internal ou external)", in.Exposure)
	}

	apikeyException := false
	for _, t := range in.Tags {
		if t == AuthExceptionApiKey {
			apikeyException = true
		}
	}

	policies := map[string]bool{"rate-limit": true, "audit-log": true}
	var authn string

	switch {
	case apikeyException:
		if in.Classification != "M" {
			return Result{}, fmt.Errorf("%s interdite pour la classification %s (uniquement M)", AuthExceptionApiKey, in.Classification)
		}
		if exposure != "internal" {
			return Result{}, fmt.Errorf("%s interdite en exposure %s (uniquement internal)", AuthExceptionApiKey, exposure)
		}
		authn = "apikey"
		policies["apikey"] = true
	case in.Classification == "VH":
		authn = "oauth2+mtls"
		policies["oauth2"] = true
		policies["mtls"] = true
	default: // H, M
		authn = "oauth2"
		policies["oauth2"] = true
	}

	if exposure == "external" {
		policies["ip-allowlist"] = true
	}

	out := make([]string, 0, len(policies))
	for p := range policies {
		out = append(out, p)
	}
	sort.Strings(out)
	return Result{Authn: authn, RequiredPolicies: out}, nil
}
