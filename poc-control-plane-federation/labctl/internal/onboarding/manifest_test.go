package onboarding

import (
	"strings"
	"testing"

	"sigs.k8s.io/yaml"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/targets"
)

// a valid, fully-populated request (used as the baseline most cases mutate).
func validRequest() Request {
	return Request{
		Name:     "acme-payments",
		Tenant:   "banking-demo",
		ClientID: "acme-payments-client",
		APIs:     []string{"accounts-read"},
		IPAllowlist: []string{
			"203.0.113.10",
			"10.60.30.1-10.60.30.30",
			"192.168.0.0/24",
		},
		PublicCert: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n",
		TokenIdentifiers: []string{"partner-token-abc"},
	}
}

func TestToManifestValid(t *testing.T) {
	m, errs := validRequest().ToManifest()
	if errs != nil {
		t.Fatalf("expected no validation errors, got %v", errs)
	}
	if m.APIVersion != APIVersion || m.Kind != Kind {
		t.Fatalf("bad identity: %s/%s", m.APIVersion, m.Kind)
	}
	if got := m.Path(); got != "tenants/banking-demo/partners/acme-payments.yaml" {
		t.Fatalf("unexpected path %q", got)
	}
	if m.Spec.ClientID != "acme-payments-client" {
		t.Fatalf("clientId not carried: %q", m.Spec.ClientID)
	}
	if len(m.Spec.Partner.IPAllowlist) != 3 || len(m.Spec.Partner.TokenIdentifiers) != 1 {
		t.Fatalf("partner block not carried: %+v", m.Spec.Partner)
	}
}

// The manifest's partner block MUST deserialise into targets.Partner unchanged
// (the contract that lets labctl/CI project the committed file directly).
func TestManifestPartnerBlockMatchesTargetsPartner(t *testing.T) {
	m, errs := validRequest().ToManifest()
	if errs != nil {
		t.Fatalf("validation: %v", errs)
	}
	raw, err := m.YAML()
	if err != nil {
		t.Fatalf("YAML: %v", err)
	}

	// Round-trip the whole manifest, then lift spec.partner into targets.Partner.
	var lifted struct {
		Spec struct {
			Partner targets.Partner `json:"partner"`
		} `json:"spec"`
	}
	if err := yaml.Unmarshal(raw, &lifted); err != nil {
		t.Fatalf("unmarshal into targets.Partner: %v", err)
	}
	p := lifted.Spec.Partner
	if len(p.TokenIdentifiers) != 1 || p.TokenIdentifiers[0] != "partner-token-abc" {
		t.Fatalf("tokenIdentifiers did not map onto targets.Partner: %+v", p)
	}
	if len(p.IPAllowlist) != 3 {
		t.Fatalf("ipAllowlist did not map onto targets.Partner: %+v", p)
	}
	if !strings.Contains(p.PublicCertRef, "BEGIN CERTIFICATE") {
		t.Fatalf("publicCertRef did not map onto targets.Partner: %q", p.PublicCertRef)
	}
}

func TestToManifestRejects(t *testing.T) {
	cases := map[string]func(r *Request){
		"empty name":      func(r *Request) { r.Name = "" },
		"bad name slug":   func(r *Request) { r.Name = "ACME Corp" },
		"empty tenant":    func(r *Request) { r.Tenant = "" },
		"empty clientId":  func(r *Request) { r.ClientID = "" },
		"no apis":         func(r *Request) { r.APIs = nil },
		"bad ip":          func(r *Request) { r.IPAllowlist = []string{"not-an-ip"} },
		"private key cert": func(r *Request) {
			r.PublicCert = "-----BEGIN PRIVATE KEY-----\nXX\n-----END PRIVATE KEY-----\n"
		},
		"cert without cert block": func(r *Request) { r.PublicCert = "just some text" },
		"private key in token": func(r *Request) {
			r.TokenIdentifiers = []string{"-----BEGIN RSA PRIVATE KEY-----"}
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			req := validRequest()
			mutate(&req)
			m, errs := req.ToManifest()
			if errs == nil || m != nil {
				t.Fatalf("expected validation failure for %q, got manifest=%v errs=%v", name, m, errs)
			}
		})
	}
}

// A private-key PEM in publicCert must be refused with a clear, auditable reason
// (the guard that keeps secrets out of Git — ADR-068/069).
func TestPrivateKeyRefusedWithReason(t *testing.T) {
	req := validRequest()
	req.PublicCert = "-----BEGIN EC PRIVATE KEY-----\nZZ\n-----END EC PRIVATE KEY-----\n"
	_, errs := req.ToManifest()
	joined := strings.Join(errs, " | ")
	if !strings.Contains(strings.ToLower(joined), "private") {
		t.Fatalf("expected a private-key refusal, got %q", joined)
	}
}

func TestYAMLIsDeterministic(t *testing.T) {
	m, _ := validRequest().ToManifest()
	a, err := m.YAML()
	if err != nil {
		t.Fatal(err)
	}
	b, err := m.YAML()
	if err != nil {
		t.Fatal(err)
	}
	if string(a) != string(b) {
		t.Fatal("YAML render is not deterministic")
	}
	if !strings.Contains(string(a), "kind: PartnerOnboarding") {
		t.Fatalf("kind not rendered:\n%s", a)
	}
}
