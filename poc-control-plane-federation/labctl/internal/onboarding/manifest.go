// Package onboarding is the engine behind cmd/onboarding-api: the self-service
// "partner onboarding as-code" surface (ADR-071). An IdP developer POSTs a
// declarative partner request; the service VALIDATES it and WRITES a partner
// manifest into the governance Git repository — and stops there. It NEVER calls
// webMethods (nor any gateway): the gateways are converged by the client's CI /
// `labctl subscribe` reading the committed manifest (le principe hors-data-plane — STOA is off the
// data path; Git is the source of truth = the douve of le principe reuse-first/069).
//
// The manifest this package writes is the SAME shape `labctl` consumes: its
// `partner` block deserialises into targets.Partner, so a `labctl subscribe`
// run over the manifest projects the application + token identifier + IP
// allowlist + public certificate + subscription onto the gateway, idempotently.
package onboarding

import (
	"fmt"
	"net"
	"regexp"
	"strings"

	"sigs.k8s.io/yaml"
)

// apiVersion / kind pin the manifest schema so a future field add stays
// detectable (the same convention as targets.yaml and the UAC contract).
const (
	APIVersion = "labctl.stoa.dev/v1"
	Kind       = "PartnerOnboarding"
)

// Request is the JSON body of POST /applications — the minimal, declarative
// description an IdP developer self-services. Everything maps onto an
// auditable, NON-SECRET manifest: a public certificate and an IP allowlist are
// configuration (auditable by PR), NOT secrets. A shared client SECRET is never
// accepted here — it is minted out-of-band by `labctl subscribe` in Keycloak and
// (in production) referenced from Vault/PAM, never inlined in Git.
type Request struct {
	// Name is the partner/application name (the webMethods applicationName, the
	// consumer name across gateways). DNS-safe slug.
	Name string `json:"name"`

	// Tenant scopes the manifest under tenants/{tenant}/ in the governance repo
	// (the same per-tenant isolation the rest of the platform uses).
	Tenant string `json:"tenant"`

	// ClientID is the Keycloak OAuth clientId the partner authenticates with
	// (the token's azp). The SECRET is NOT carried here.
	ClientID string `json:"clientId"`

	// APIs are the published API slugs the partner subscribes to (e.g.
	// "accounts-read"). At least one is required — onboarding with no
	// subscription is meaningless.
	APIs []string `json:"apis"`

	// IPAllowlist are IPs / ranges projected as a webMethods ipAddressRange
	// identifier. NON-SECRET; auditable in Git.
	IPAllowlist []string `json:"ipAllowlist"`

	// PublicCert is an inline PUBLIC X.509 PEM (or empty). A private key is
	// REFUSED. NON-SECRET; auditable in Git.
	PublicCert string `json:"publicCert"`

	// TokenIdentifiers are custom identification tokens projected as a webMethods
	// `token` identifier. Shared TEST tokens may live in Git; a real production
	// secret MUST be a Vault/PAM reference, never an inline literal.
	TokenIdentifiers []string `json:"tokenIdentifiers"`
}

// Manifest is what gets written to Git: tenants/{tenant}/partners/{name}.yaml.
// The `partner` block is byte-compatible with targets.Partner so labctl/CI
// projects it directly. Identity (apiVersion/kind/metadata) frames it for
// GitOps tooling; spec carries the projectable intent.
type Manifest struct {
	APIVersion string   `json:"apiVersion"`
	Kind       string   `json:"kind"`
	Metadata   Metadata `json:"metadata"`
	Spec       Spec     `json:"spec"`
}

// Metadata is the GitOps frame (name + tenant + the subscribed APIs as labels
// so a reviewer sees the blast radius at the top of the PR).
type Metadata struct {
	Name   string `json:"name"`
	Tenant string `json:"tenant"`
}

// Spec is the projectable intent. ClientID + APIs drive the subscription; the
// Partner block drives the per-application identifiers (token/IP/cert) labctl's
// webMethods adapter materialises (ADR-071).
type Spec struct {
	ClientID string  `json:"clientId"`
	APIs     []string `json:"apis"`
	Partner  Partner `json:"partner"`
}

// Partner is byte-compatible with internal/targets.Partner (same json tags) so a
// manifest can be lifted straight into a targets.yaml partner block. Only
// NON-SECRET material lives here.
type Partner struct {
	TokenIdentifiers []string `json:"tokenIdentifiers,omitempty"`
	IPAllowlist      []string `json:"ipAllowlist,omitempty"`
	// PublicCertRef carries the inline PUBLIC PEM (the targets field name is
	// reused so labctl reads it unchanged).
	PublicCertRef string `json:"publicCertRef,omitempty"`
}

// slugRE is the DNS-safe slug the gateways accept for names/tenants/api slugs.
var slugRE = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)

// ToManifest validates the request and projects it onto a Manifest. The
// returned errors are field-level and safe to echo to the caller (400). It is
// the ONLY place the request shape is trusted: the write path takes a Manifest.
func (req Request) ToManifest() (*Manifest, []string) {
	var errs []string

	name := strings.TrimSpace(req.Name)
	if !slugRE.MatchString(name) {
		errs = append(errs, "name: must be a DNS-safe slug [a-z0-9-] (1-63 chars)")
	}
	tenant := strings.TrimSpace(req.Tenant)
	if !slugRE.MatchString(tenant) {
		errs = append(errs, "tenant: must be a DNS-safe slug [a-z0-9-] (1-63 chars)")
	}
	if strings.TrimSpace(req.ClientID) == "" {
		errs = append(errs, "clientId: required (the Keycloak OAuth clientId / token azp)")
	}
	apis := dedupTrim(req.APIs)
	if len(apis) == 0 {
		errs = append(errs, "apis: at least one published API slug is required")
	}
	for _, a := range apis {
		if !slugRE.MatchString(a) {
			errs = append(errs, fmt.Sprintf("apis: %q is not a DNS-safe slug", a))
		}
	}

	ips := dedupTrim(req.IPAllowlist)
	for _, ip := range ips {
		if !validIPOrRange(ip) {
			errs = append(errs, fmt.Sprintf("ipAllowlist: %q is not an IP, CIDR or a.b.c.d-a.b.c.e range", ip))
		}
	}

	if err := assertPublicCert(req.PublicCert); err != nil {
		errs = append(errs, "publicCert: "+err.Error())
	}

	for i, t := range req.TokenIdentifiers {
		if looksLikePrivateKey(t) {
			errs = append(errs, fmt.Sprintf("tokenIdentifiers[%d]: refusing private-key material (secrets belong in Vault/PAM, never in Git)", i))
		}
	}

	if len(errs) > 0 {
		return nil, errs
	}

	m := &Manifest{
		APIVersion: APIVersion,
		Kind:       Kind,
		Metadata:   Metadata{Name: name, Tenant: tenant},
		Spec: Spec{
			ClientID: strings.TrimSpace(req.ClientID),
			APIs:     apis,
			Partner: Partner{
				TokenIdentifiers: dedupTrim(req.TokenIdentifiers),
				IPAllowlist:      ips,
				PublicCertRef:    strings.TrimSpace(req.PublicCert),
			},
		},
	}
	return m, nil
}

// Path is the repo-relative location the manifest is written to. One file per
// partner per tenant, so a PR diff is the audit unit and a delete is a removal.
func (m *Manifest) Path() string {
	return fmt.Sprintf("tenants/%s/partners/%s.yaml", m.Metadata.Tenant, m.Metadata.Name)
}

// YAML renders the manifest deterministically (sigs.k8s.io/yaml -> JSON tags ->
// stable key order) so re-writing an unchanged request is a byte-identical
// no-op commit (idempotence in Git).
func (m *Manifest) YAML() ([]byte, error) {
	header := "# Généré par onboarding-api (write-through-Git, ADR-071).\n" +
		"# NON-SECRET : cert public + IP + tokens de test, auditables par PR.\n" +
		"# Les secrets (client secret, clés privées) vivent dans Vault/PAM, JAMAIS ici.\n" +
		"# Projeté par `labctl subscribe` / la CI — l'API ne touche JAMAIS la gateway.\n"
	body, err := yaml.Marshal(m)
	if err != nil {
		return nil, err
	}
	return append([]byte(header), body...), nil
}

// --- validation helpers ------------------------------------------------------

// dedupTrim trims, drops empties and de-duplicates while preserving order.
func dedupTrim(in []string) []string {
	seen := make(map[string]struct{}, len(in))
	out := make([]string, 0, len(in))
	for _, s := range in {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		if _, ok := seen[s]; ok {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	return out
}

// validIPOrRange accepts a bare IP, a CIDR, or an "a.b.c.d-e.f.g.h" range — the
// forms the webMethods ipAddressRange identifier understands.
func validIPOrRange(s string) bool {
	if net.ParseIP(s) != nil {
		return true
	}
	if _, _, err := net.ParseCIDR(s); err == nil {
		return true
	}
	if lo, hi, ok := strings.Cut(s, "-"); ok {
		return net.ParseIP(strings.TrimSpace(lo)) != nil && net.ParseIP(strings.TrimSpace(hi)) != nil
	}
	return false
}

// assertPublicCert allows an empty value, requires a CERTIFICATE block when
// present, and REFUSES any private-key material (the guard that keeps secrets
// out of Git — mirrors the adapter's loadPublicCertPEM).
func assertPublicCert(pem string) error {
	pem = strings.TrimSpace(pem)
	if pem == "" {
		return nil
	}
	if looksLikePrivateKey(pem) {
		return fmt.Errorf("carries PRIVATE KEY material — only the PUBLIC certificate is accepted (secrets belong in Vault/PAM)")
	}
	if !strings.Contains(pem, "CERTIFICATE") {
		return fmt.Errorf("no CERTIFICATE block found (expected a public X.509 PEM)")
	}
	return nil
}

// looksLikePrivateKey is a coarse, fail-closed guard against any private-key
// material slipping into a Git-bound field.
func looksLikePrivateKey(s string) bool {
	return strings.Contains(strings.ToUpper(s), "PRIVATE KEY")
}
