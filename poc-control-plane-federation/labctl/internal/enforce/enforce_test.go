package enforce

import (
	"strings"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/render"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/targets"
)

func mustDerive(t *testing.T, classification, exposure string, tags ...string) adapter.EnforcementRequirement {
	t.Helper()
	c := render.ContractSubset{Name: "x", Classification: classification, Exposure: exposure, Tags: tags}
	res, err := render.Derive(c.Input())
	if err != nil {
		t.Fatalf("Derive(%s/%s): %v", classification, exposure, err)
	}
	return Requirement(c, res)
}

func vhTarget() targets.Target {
	return targets.Target{
		Name: "wm", Type: "webmethods",
		InboundAuth: &targets.InboundAuth{
			Issuer: "http://kc", JwksURI: "http://kc/jwks",
			Audience: "accounts-read", Scope: "accounts.read", ClientID: "consumer",
			Mtls: true,
		},
		RateLimit:         &targets.RateLimit{Requests: 1000},
		TransportProtocol: "https",
	}
}

func TestPrecheck_WebmethodsVHConforming(t *testing.T) {
	v, warns := PrecheckTarget(vhTarget(), mustDerive(t, "VH", "external"))
	if len(v) != 0 {
		t.Errorf("violations = %v, want none", v)
	}
	if len(warns) != 0 {
		t.Errorf("warnings = %v, want none", warns)
	}
}

func TestPrecheck_WebmethodsVHWithoutMTLSFails(t *testing.T) {
	tgt := vhTarget()
	tgt.InboundAuth.Mtls = false
	v, _ := PrecheckTarget(tgt, mustDerive(t, "VH", "external"))
	if len(v) == 0 {
		t.Fatal("VH without inboundAuth.mtls passed the pre-check, want a violation")
	}
	if !strings.Contains(strings.Join(v, "\n"), "mtls") {
		t.Errorf("violation should name mtls: %v", v)
	}
}

func TestPrecheck_WebmethodsVHWithoutHTTPSTransportFails(t *testing.T) {
	tgt := vhTarget()
	tgt.TransportProtocol = ""
	v, _ := PrecheckTarget(tgt, mustDerive(t, "VH", "external"))
	if len(v) == 0 {
		t.Fatal("VH without transportProtocol=https passed, want a violation")
	}
}

func TestPrecheck_WebmethodsHWithoutOAuth2Fails(t *testing.T) {
	tgt := vhTarget()
	tgt.InboundAuth = nil
	v, _ := PrecheckTarget(tgt, mustDerive(t, "H", ""))
	joined := strings.Join(v, "\n")
	if !strings.Contains(joined, "oauth2") {
		t.Errorf("H without inboundAuth should violate oauth2: %v", v)
	}
}

func TestPrecheck_WebmethodsMissingRateLimitFails(t *testing.T) {
	tgt := vhTarget()
	tgt.RateLimit = nil
	v, _ := PrecheckTarget(tgt, mustDerive(t, "VH", "external"))
	if !strings.Contains(strings.Join(v, "\n"), "rate-limit") {
		t.Errorf("missing rateLimit should violate rate-limit: %v", v)
	}
}

func TestPrecheck_WebmethodsApikeyUnsupported(t *testing.T) {
	tgt := targets.Target{Name: "wm", Type: "webmethods"}
	v, _ := PrecheckTarget(tgt, mustDerive(t, "M", "internal", render.AuthExceptionApiKey))
	if !strings.Contains(strings.Join(v, "\n"), "apikey") {
		t.Errorf("apikey bundle on webmethods should be a violation (ADR-076 gap #7): %v", v)
	}
}

// Anti-downgrade signal (ADR-076 gap #1, goal A5): mtls declared while the
// bundle does not require it warns — the classification may be under-declared.
func TestPrecheck_StrongerThanBundleWarns(t *testing.T) {
	tgt := vhTarget() // declares mtls
	_, warns := PrecheckTarget(tgt, mustDerive(t, "M", ""))
	if len(warns) == 0 || !strings.Contains(strings.Join(warns, "\n"), "sous-déclarée") {
		t.Errorf("mtls-capable target under an M bundle should warn about under-declared classification: %v", warns)
	}
}

// APISIX in A1: pre-checks exist only to fail earlier/better — rate-limit and
// audit-log are always in the bundle and not projectable there yet (A3/B1).
func TestPrecheck_ApisixStructurallyRedInA1(t *testing.T) {
	tgt := targets.Target{
		Name: "gw", Type: "apisix",
		InboundAuth: &targets.InboundAuth{DiscoveryURL: "http://kc/.well-known/openid-configuration"},
	}
	v, _ := PrecheckTarget(tgt, mustDerive(t, "H", ""))
	joined := strings.Join(v, "\n")
	if !strings.Contains(joined, "rate-limit") || !strings.Contains(joined, "audit-log") {
		t.Errorf("apisix under enforcement should violate rate-limit and audit-log in A1: %v", v)
	}
}

func TestPrecheck_UnknownTypeDefersWithWarning(t *testing.T) {
	tgt := targets.Target{Name: "gw", Type: "faketgt"}
	v, warns := PrecheckTarget(tgt, mustDerive(t, "VH", "external"))
	if len(v) != 0 {
		t.Errorf("unknown type should defer to the read-back, got violations: %v", v)
	}
	if len(warns) == 0 {
		t.Error("unknown type should warn that the pre-check is unavailable")
	}
}

func TestGate_FailsOnMissingAndUnverifiable(t *testing.T) {
	req := mustDerive(t, "VH", "external")
	rep := &adapter.EnforcementReport{Verdicts: []adapter.PolicyVerdict{
		{Policy: "oauth2", Status: adapter.VerdictEnforced},
		{Policy: "mtls", Status: adapter.VerdictMissing, Detail: "no cert rule"},
		{Policy: "rate-limit", Status: adapter.VerdictEnforced},
		{Policy: "audit-log", Status: adapter.VerdictEnforced},
		{Policy: "ip-allowlist", Status: adapter.VerdictDegraded},
	}}
	failing := Gate(req, rep)
	if len(failing) != 1 || failing[0].Policy != "mtls" {
		t.Errorf("failing = %v, want exactly mtls", failing)
	}
}

func TestGate_DegradedPasses(t *testing.T) {
	req := mustDerive(t, "VH", "external")
	rep := &adapter.EnforcementReport{Verdicts: []adapter.PolicyVerdict{
		{Policy: "oauth2", Status: adapter.VerdictEnforced},
		{Policy: "mtls", Status: adapter.VerdictEnforced},
		{Policy: "rate-limit", Status: adapter.VerdictEnforced},
		{Policy: "audit-log", Status: adapter.VerdictEnforced},
		{Policy: "ip-allowlist", Status: adapter.VerdictDegraded},
	}}
	if failing := Gate(req, rep); len(failing) != 0 {
		t.Errorf("degraded should pass the gate, got %v", failing)
	}
}

// Fail-closed against a lazy verifier: a required policy absent from the
// report is synthesized as missing.
func TestGate_UncoveredRequiredPolicyIsMissing(t *testing.T) {
	req := mustDerive(t, "H", "")
	rep := &adapter.EnforcementReport{Verdicts: []adapter.PolicyVerdict{
		{Policy: "oauth2", Status: adapter.VerdictEnforced},
		// rate-limit and audit-log NOT covered
	}}
	failing := Gate(req, rep)
	if len(failing) != 2 {
		t.Fatalf("failing = %v, want audit-log + rate-limit synthesized", failing)
	}
	for _, f := range failing {
		if f.Status != adapter.VerdictMissing {
			t.Errorf("%s = %s, want missing", f.Policy, f.Status)
		}
	}
}

// An informational verdict on a NON-required policy never gates.
func TestGate_NonRequiredVerdictIgnored(t *testing.T) {
	req := mustDerive(t, "H", "")
	rep := &adapter.EnforcementReport{Verdicts: []adapter.PolicyVerdict{
		{Policy: "oauth2", Status: adapter.VerdictEnforced},
		{Policy: "rate-limit", Status: adapter.VerdictEnforced},
		{Policy: "audit-log", Status: adapter.VerdictEnforced},
		{Policy: "active", Status: adapter.VerdictMissing, Detail: "informational"},
	}}
	if failing := Gate(req, rep); len(failing) != 0 {
		t.Errorf("non-required verdict gated the run: %v", failing)
	}
}

func TestGate_NilReportSynthesizesEverything(t *testing.T) {
	req := mustDerive(t, "H", "")
	failing := Gate(req, nil)
	if len(failing) != len(req.Policies) {
		t.Errorf("nil report should synthesize every required policy, got %v", failing)
	}
}
