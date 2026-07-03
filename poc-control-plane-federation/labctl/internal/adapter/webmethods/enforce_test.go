package webmethods

// Enforcement read-back tests (ADR-076 goal A1) against the mock gateway.
// Pinned here, per the adversarial design review:
//   - the oauth2/mtls verdicts read ALL IdentificationRules (rule order is not
//     guaranteed at read-back — the reversed-rules case);
//   - scalar params tolerate string AND bool/number encodings (their read-back
//     type is not pinned on the trial);
//   - both GET /policyActions/{id} response shapes (enveloped and naked) work;
//   - the oauth2 verdict fails when the scope mapping no longer binds the API
//     (fail-open scope drift), even though strategy + action still hold;
//   - allowAnonymous drift on the SHARED AND action — which the projector
//     deliberately never converges — is caught.

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

// vhRequirement is the derived VH/external bundle (render.Derive output).
var vhRequirement = adapter.EnforcementRequirement{
	Classification: "VH",
	Exposure:       "external",
	Authn:          "oauth2+mtls",
	Policies:       []string{"audit-log", "ip-allowlist", "mtls", "oauth2", "rate-limit"},
}

// newVHAdapter builds an adapter with the FULL VH manifest knobs (OAuth2 path +
// mTLS + rate-limit + https transport) against the mock.
func newVHAdapter(t *testing.T, srv *httptest.Server) (*Adapter, *adapter.NormalizedAPI) {
	t.Helper()
	a, err := New(adapter.Config{
		Type:       gatewayName,
		Name:       gatewayName,
		AdminURL:   srv.URL,
		GatewayURL: "http://webmethods-real:5555",
		Credentials: map[string]string{
			"username": testUser,
			"password": testPass,
		},
		Options: map[string]string{
			"inboundAuthIssuer":   "http://localhost:8480/realms/stoa-lab",
			"inboundAuthJwksUri":  "http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/certs",
			"inboundAuthAudience": "accounts-read",
			"inboundAuthScope":    "accounts.read",
			"inboundAuthClientId": "accounts-read-consumer",
			"inboundMtls":         "true",
			"rateLimitRequests":   "1000",
			"rateLimitInterval":   "1",
			"rateLimitUnit":       "minutes",
			"transportProtocol":   "https",
		},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	api := &adapter.NormalizedAPI{
		Name:       "accounts-read",
		Version:    "1.0.0",
		BasePath:   "/accounts-read/v1",
		BackendURL: "http://microcks:8080/rest/accounts",
		Spec:       []byte(sampleSpec),
		SpecPath:   "apis/accounts-read.openapi.yaml",
	}
	return a.(*Adapter), api
}

// publishVH stands up a mock with the audit-log substrate + transport action
// seeded, publishes the VH API and returns everything a verify needs.
func publishVH(t *testing.T, mutate func(*mockGateway)) (*mockGateway, *Adapter, string) {
	t.Helper()
	mock := newMockGateway()
	mock.seedTransportAction()
	mock.seedGlobalLogInvocation("true", "false")
	if mutate != nil {
		mutate(mock)
	}
	srv := httptest.NewServer(mock.handler())
	t.Cleanup(srv.Close)
	a, api := newVHAdapter(t, srv)
	res, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	return mock, a, res.APIID
}

func verdictOf(t *testing.T, rep *adapter.EnforcementReport, policy string) adapter.PolicyVerdict {
	t.Helper()
	for _, v := range rep.Verdicts {
		if v.Policy == policy {
			return v
		}
	}
	t.Fatalf("no verdict for policy %q in %+v", policy, rep.Verdicts)
	return adapter.PolicyVerdict{}
}

func TestVerifyEnforcement_VHAllConfirmed(t *testing.T) {
	_, a, apiID := publishVH(t, nil)
	rep, err := a.VerifyEnforcement(context.Background(), apiID, vhRequirement)
	if err != nil {
		t.Fatalf("VerifyEnforcement: %v", err)
	}
	want := map[string]string{
		"oauth2":       adapter.VerdictEnforced,
		"mtls":         adapter.VerdictEnforced,
		"rate-limit":   adapter.VerdictEnforced,
		"audit-log":    adapter.VerdictEnforced,
		"ip-allowlist": adapter.VerdictDegraded,
	}
	for p, status := range want {
		if v := verdictOf(t, rep, p); v.Status != status {
			t.Errorf("%s = %s (%s), want %s", p, v.Status, v.Detail, status)
		}
	}
	// Honesty annotations: the audience stays fail-open on the trial (3/4
	// barriers) and the throttle limit is reported.
	if v := verdictOf(t, rep, "oauth2"); !strings.Contains(v.Detail, "3/4") {
		t.Errorf("oauth2 detail should annotate the fail-open audience (3/4): %q", v.Detail)
	}
	if v := verdictOf(t, rep, "rate-limit"); !strings.Contains(v.Detail, "1000") {
		t.Errorf("rate-limit detail should report the read-back limit: %q", v.Detail)
	}
}

// The projector NEVER converges the shared AND action (present = reused as-is),
// so an out-of-band allowAnonymous flip is exactly the drift only the read-back
// can catch — the raison d'être of the apply gate.
func TestVerifyEnforcement_CatchesAllowAnonymousDrift(t *testing.T) {
	mock, a, apiID := publishVH(t, nil)

	mock.mu.Lock()
	for _, act := range mock.actions {
		if isMtlsIdentifyAction(act) {
			setActionParamValues(act, "allowAnonymous", []any{"true"})
		}
	}
	mock.mu.Unlock()

	rep, err := a.VerifyEnforcement(context.Background(), apiID, vhRequirement)
	if err != nil {
		t.Fatalf("VerifyEnforcement: %v", err)
	}
	if v := verdictOf(t, rep, "mtls"); v.Status != adapter.VerdictMissing {
		t.Errorf("mtls after allowAnonymous drift = %s, want missing", v.Status)
	}
	if v := verdictOf(t, rep, "oauth2"); v.Status != adapter.VerdictMissing {
		t.Errorf("oauth2 after allowAnonymous drift = %s, want missing", v.Status)
	}
}

// Rule ORDER is not pinned at read-back: with the httpsCertificate rule served
// FIRST, the all-rules reader must still confirm both legs (the first-rule-only
// helpers of the projection would misread this).
func TestVerifyEnforcement_ReversedRulesStillConfirmed(t *testing.T) {
	mock, a, apiID := publishVH(t, nil)

	mock.mu.Lock()
	for _, act := range mock.actions {
		if !isMtlsIdentifyAction(act) {
			continue
		}
		params, _ := act["parameters"].([]any)
		// Move every IdentificationRule group to the FRONT, reversed.
		var rules, rest []any
		for _, p := range params {
			pm, _ := p.(map[string]any)
			if pm != nil {
				if tk, _ := pm["templateKey"].(string); tk == "IdentificationRule" {
					rules = append([]any{p}, rules...)
					continue
				}
			}
			rest = append(rest, p)
		}
		act["parameters"] = append(rules, rest...)
	}
	mock.mu.Unlock()

	rep, err := a.VerifyEnforcement(context.Background(), apiID, vhRequirement)
	if err != nil {
		t.Fatalf("VerifyEnforcement: %v", err)
	}
	for _, p := range []string{"oauth2", "mtls"} {
		if v := verdictOf(t, rep, p); v.Status != adapter.VerdictEnforced {
			t.Errorf("%s with reversed rules = %s (%s), want enforced", p, v.Status, v.Detail)
		}
	}
}

// GET /policyActions/{id} may answer the record NAKED on some builds.
func TestVerifyEnforcement_NakedActionShape(t *testing.T) {
	mock, a, apiID := publishVH(t, nil)
	mock.mu.Lock()
	mock.nakedActionGet = true
	mock.mu.Unlock()

	rep, err := a.VerifyEnforcement(context.Background(), apiID, vhRequirement)
	if err != nil {
		t.Fatalf("VerifyEnforcement: %v", err)
	}
	for _, p := range []string{"oauth2", "mtls", "rate-limit"} {
		if v := verdictOf(t, rep, p); v.Status != adapter.VerdictEnforced {
			t.Errorf("%s with naked action GET = %s (%s), want enforced", p, v.Status, v.Detail)
		}
	}
}

// Scalar read-back types are not pinned on the trial: bool active, bool
// storeRequestPayload and a NUMBER throttle value must all confirm.
func TestVerifyEnforcement_ToleratesScalarTypes(t *testing.T) {
	mock, a, apiID := publishVH(t, func(m *mockGateway) {
		m.seedGlobalLogInvocation(true, false) // bools, not strings
	})

	mock.mu.Lock()
	for _, act := range mock.actions {
		if !isThrottleAction(act) {
			continue
		}
		params, _ := act["parameters"].([]any)
		for _, p := range params {
			pm, _ := p.(map[string]any)
			if pm == nil {
				continue
			}
			if tk, _ := pm["templateKey"].(string); tk != "throttleRule" {
				continue
			}
			nested, _ := pm["parameters"].([]any)
			for _, n := range nested {
				if nm, _ := n.(map[string]any); nm != nil {
					if tk, _ := nm["templateKey"].(string); tk == "value" {
						nm["values"] = []any{float64(1000)} // number, not string
					}
				}
			}
		}
	}
	mock.mu.Unlock()

	rep, err := a.VerifyEnforcement(context.Background(), apiID, vhRequirement)
	if err != nil {
		t.Fatalf("VerifyEnforcement: %v", err)
	}
	for _, p := range []string{"audit-log", "rate-limit"} {
		if v := verdictOf(t, rep, p); v.Status != adapter.VerdictEnforced {
			t.Errorf("%s with non-string scalars = %s (%s), want enforced", p, v.Status, v.Detail)
		}
	}
}

// Unbinding the scope mapping leaves strategy + IAM action intact but the
// scope barrier fail-open — the oauth2 verdict must fall to missing.
func TestVerifyEnforcement_CatchesUnboundScopeMapping(t *testing.T) {
	mock, a, apiID := publishVH(t, nil)

	mock.mu.Lock()
	for _, sc := range mock.scopes {
		sc["apiScopes"] = []any{}
	}
	mock.mu.Unlock()

	rep, err := a.VerifyEnforcement(context.Background(), apiID, vhRequirement)
	if err != nil {
		t.Fatalf("VerifyEnforcement: %v", err)
	}
	v := verdictOf(t, rep, "oauth2")
	if v.Status != adapter.VerdictMissing {
		t.Errorf("oauth2 with unbound scope mapping = %s, want missing", v.Status)
	}
	if !strings.Contains(v.Detail, "scope") {
		t.Errorf("detail should name the scope barrier: %q", v.Detail)
	}
}

// Without the global transaction-logging pair (fresh gateway, wm-otel-setup
// never run) audit-log must be missing — never blindly attested.
func TestVerifyEnforcement_AuditLogAbsentIsMissing(t *testing.T) {
	mock := newMockGateway()
	mock.seedTransportAction() // but NO seedGlobalLogInvocation
	srv := httptest.NewServer(mock.handler())
	t.Cleanup(srv.Close)
	a, api := newVHAdapter(t, srv)
	res, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}

	rep, err := a.VerifyEnforcement(context.Background(), res.APIID, vhRequirement)
	if err != nil {
		t.Fatalf("VerifyEnforcement: %v", err)
	}
	if v := verdictOf(t, rep, "audit-log"); v.Status != adapter.VerdictMissing {
		t.Errorf("audit-log without the global pair = %s, want missing", v.Status)
	}
}

// A redaction-posture violation (storeRequestPayload=true) is missing, not
// enforced: the ADR-070 rule is that the request body is NEVER captured.
func TestVerifyEnforcement_AuditLogPayloadCaptureIsMissing(t *testing.T) {
	_, a, apiID := publishVH(t, func(m *mockGateway) {
		m.seedGlobalLogInvocation("true", "true")
	})
	rep, err := a.VerifyEnforcement(context.Background(), apiID, vhRequirement)
	if err != nil {
		t.Fatalf("VerifyEnforcement: %v", err)
	}
	if v := verdictOf(t, rep, "audit-log"); v.Status != adapter.VerdictMissing {
		t.Errorf("audit-log with storeRequestPayload=true = %s, want missing", v.Status)
	}
}

// H/M bundle (no mtls) against a signature-only manifest: oauth2 must be
// missing when the OAuth2 path is not declared (never confirmable from a
// signature-only projection).
func TestVerifyEnforcement_SignatureOnlyManifestCannotConfirmOAuth2(t *testing.T) {
	mock := newMockGateway()
	mock.seedTransportAction()
	mock.seedGlobalLogInvocation("true", "false")
	srv := httptest.NewServer(mock.handler())
	t.Cleanup(srv.Close)
	// Signature-only inboundAuth (no audience) + rate-limit.
	a, err := New(adapter.Config{
		Type: gatewayName, Name: gatewayName, AdminURL: srv.URL,
		Credentials: map[string]string{"username": testUser, "password": testPass},
		Options: map[string]string{
			"inboundAuthIssuer":  "http://localhost:8480/realms/stoa-lab",
			"inboundAuthJwksUri": "http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/certs",
			"rateLimitRequests":  "500",
		},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	wm := a.(*Adapter)
	api := &adapter.NormalizedAPI{
		Name: "accounts-read", Version: "1.0.0", BasePath: "/accounts-read/v1",
		BackendURL: "http://microcks:8080/rest/accounts", Spec: []byte(sampleSpec),
	}
	res, err := wm.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	req := adapter.EnforcementRequirement{
		Classification: "H", Exposure: "internal", Authn: "oauth2",
		Policies: []string{"audit-log", "oauth2", "rate-limit"},
	}
	rep, err := wm.VerifyEnforcement(context.Background(), res.APIID, req)
	if err != nil {
		t.Fatalf("VerifyEnforcement: %v", err)
	}
	if v := verdictOf(t, rep, "oauth2"); v.Status != adapter.VerdictMissing {
		t.Errorf("oauth2 on signature-only manifest = %s, want missing", v.Status)
	}
	if v := verdictOf(t, rep, "rate-limit"); v.Status != adapter.VerdictEnforced {
		t.Errorf("rate-limit = %s (%s), want enforced", v.Status, v.Detail)
	}
}
