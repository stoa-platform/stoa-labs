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
			// P6 : la cellule `external` exige `ip-allowlist`, et depuis
			// ADR-096 le pré-check refuse un target qui ne la déclare pas.
			IPAllowlist: true,
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

// TestPrecheck_WebmethodsExternalWithoutIPAllowlistFails est la mutation du
// pré-check P6 : une cible `external` qui ne déclare pas la restriction réseau
// doit être REFUSÉE À L'APPLY, avant toute écriture sur la gateway.
//
// Sans ce refus, la chaîne publierait — comme elle l'a fait jusqu'ici — une API
// dont le bouquet NOMME `ip-allowlist` alors que rien ne l'oppose : le spike P6
// (S2) a mesuré l'appelant hors plage servi 200, allow-list écrite comprise.
func TestPrecheck_WebmethodsExternalWithoutIPAllowlistFails(t *testing.T) {
	tgt := vhTarget()
	tgt.InboundAuth.IPAllowlist = false
	v, _ := PrecheckTarget(tgt, mustDerive(t, "VH", "external"))
	if len(v) == 0 {
		t.Fatal("external sans inboundAuth.ipAllowlist a passé le pré-check, want une violation")
	}
	if !strings.Contains(strings.Join(v, "\n"), "ip-allowlist") {
		t.Errorf("la violation doit NOMMER ip-allowlist : %v", v)
	}
}

// Contre-épreuve de la mutation ci-dessus : une cellule qui n'exige PAS
// l'ip-allowlist (internal, internet) ne doit rien réclamer. `internet` est le
// cas piégeux — ADR-091 y REMPLACE l'allow-list par threat-protection, parce que
// l'appelant public n'est pas énumérable.
func TestPrecheck_IPAllowlistNotDemandedOutsideExternal(t *testing.T) {
	tgt := vhTarget()
	tgt.InboundAuth.IPAllowlist = false
	for _, exposure := range []string{"internal", "internet"} {
		v, _ := PrecheckTarget(tgt, mustDerive(t, "VH", exposure))
		if strings.Contains(strings.Join(v, "\n"), "ip-allowlist") {
			t.Errorf("exposure=%s réclame ip-allowlist : %v", exposure, v)
		}
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
		{Policy: "https-only", Status: adapter.VerdictEnforced},
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
		{Policy: "https-only", Status: adapter.VerdictEnforced},
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
		// rate-limit, audit-log and the ADR-091 floor https-only NOT covered
	}}
	failing := Gate(req, rep)
	if len(failing) != 3 {
		t.Fatalf("failing = %v, want audit-log + https-only + rate-limit synthesized", failing)
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
		{Policy: "https-only", Status: adapter.VerdictEnforced},
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

// --- ADR-091 (jalon P1) ------------------------------------------------------

// https-only is a FLOOR, not a VH-only side effect of mtls: an H API that does
// not pin its transport must be caught too. Before P1 the only transport check
// lived inside the mtls branch, so this case passed silently.
func TestPrecheck_HTTPSOnlyIsAFloorAtEveryLevel(t *testing.T) {
	tgt := vhTarget()
	tgt.InboundAuth.Mtls = false // no mtls leg at all: H/internal
	tgt.TransportProtocol = ""
	v, _ := PrecheckTarget(tgt, mustDerive(t, "H", "internal"))
	joined := strings.Join(v, "\n")
	if !strings.Contains(joined, "https-only") {
		t.Errorf("H sans transportProtocol=https doit violer https-only : %v", v)
	}
}

func TestPrecheck_HTTPSOnlySatisfiedByHTTPSTransport(t *testing.T) {
	tgt := vhTarget()
	tgt.InboundAuth.Mtls = false
	v, _ := PrecheckTarget(tgt, mustDerive(t, "H", "internal"))
	if joined := strings.Join(v, "\n"); strings.Contains(joined, "https-only") {
		t.Errorf("transportProtocol=https ne doit pas violer https-only : %v", v)
	}
}

// threat-protection has no per-API knob to pre-check on wM 10.15, so the
// pre-check WARNS and defers; the read-back is what refuses (écart ADR-091 #1).
// A violation here would block the exposure value outright; silence would hide
// the gap. Neither is the honest answer.
func TestPrecheck_ThreatProtectionWarnsAndDefers(t *testing.T) {
	v, warns := PrecheckTarget(vhTarget(), mustDerive(t, "VH", "internet"))
	if len(v) != 0 {
		t.Errorf("exposure=internet ne doit pas bloquer au pré-check : %v", v)
	}
	joined := strings.Join(warns, "\n")
	if !strings.Contains(joined, "threat-protection") || !strings.Contains(joined, "ADR-091") {
		t.Errorf("l'avertissement doit nommer threat-protection et l'écart ADR-091 #1 : %v", warns)
	}
}

// The mirror image: an internet bundle carries NO ip-allowlist, so a target
// pre-checked at that exposure must not be asked for one.
func TestPrecheck_InternetCarriesNoIPAllowlist(t *testing.T) {
	req := mustDerive(t, "VH", "internet")
	for _, p := range req.Policies {
		if p == "ip-allowlist" {
			t.Fatalf("le bouquet %s porte une ip-allowlist alors que l'appelant public n'est pas énumérable : %v", req.Bundle, req.Policies)
		}
	}
	if req.Bundle != "vh-internet" {
		t.Errorf("bundle = %q, want vh-internet", req.Bundle)
	}
}
