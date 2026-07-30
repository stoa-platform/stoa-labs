package webmethods

import (
	"context"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"net/http"
	"os"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

// --- webMethods application identifier keys (partner onboarding, ADR-071) -----
//
// The `key` of an application identifier is a FREE string in the OpenAPI schema,
// but the running 10.15 gateway enforces a fixed enum: a PUT with an unknown key
// is rejected 400 with "Undefined 'key' attribute value '<k>', should be one of
// [httpBasicAuth, accessProfile, apiKey, wssecX509Token, wssecUsernameToken,
//  ipAddressRange, hostNameAddress, openIdClaims, jwtClaims, oAuth2Token,
//  payloadElement, httpsCertificate, XPathExpression, kerberosToken, token,
//  partnerId, httpHeaders]".
//
// The three keys below were PINNED against the live trial by a write+read-back
// spike on labctl-live-consumer (the singular `token`, NOT `tokens`; the cert
// key is `httpsCertificate`, NOT `certificate`/`applicationCertificates`). They
// are kept as overridable package vars (not const) so a future build drift can be
// corrected in one place without touching the projection logic.
var (
	// identifierKeyToken posts a custom identification token on the application.
	identifierKeyToken = "token"
	// identifierKeyIP posts an IP / IP-range allowlist on the application.
	identifierKeyIP = "ipAddressRange"
	// identifierKeyCert posts the partner's public X.509 certificate (identity).
	identifierKeyCert = "httpsCertificate"
)

// Identifier display names (the free "name" label shown in the UI). Stable so
// re-apply upserts by (key,name) without spawning duplicates.
const (
	identifierNameToken = "partner-token"
	identifierNameIP    = "ip-allowlist"
	identifierNameCert  = "partner-cert"
)

// hasPartnerIdentifiers reports whether the spec declares any of the optional
// partner identifiers — so CreateConsumer can skip the whole projection (and its
// read-modify-write PUT) when none are set and stay byte-identical to before.
func hasPartnerIdentifiers(spec *adapter.ConsumerSpec) bool {
	return spec != nil && (len(spec.TokenIdentifiers) > 0 ||
		len(spec.IPAllowlist) > 0 ||
		strings.TrimSpace(spec.PublicCertRef) != "")
}

// ensureApplicationIdentifiers converges the partner identifiers (custom token,
// IP allowlist, public certificate) onto the webMethods application, additively
// and idempotently:
//
//  1. CERT FIRST: register the public PEM in the gateway truststore (the mTLS
//     handshake trust anchor) BEFORE binding the identity — otherwise the
//     handshake fails before identity is ever evaluated.
//  2. READ the application back (whole record), MERGE the desired identifiers
//     into the existing array by (key,name) WITHOUT touching azp/openIdClaims or
//     any other identifier the OAuth2 binding installed.
//  3. PUT the WHOLE record (the PUT replaces the object; consumingAPIs /
//     authStrategyIds / accessTokens are gateway-preserved or carried through,
//     exactly like ensureApplicationOAuthBinding).
//
// When every desired identifier is already present with the same value set, the
// merge is a no-op and NO PUT is issued (re-apply converges).
func (a *Adapter) ensureApplicationIdentifiers(ctx context.Context, appID string, spec *adapter.ConsumerSpec) error {
	desired, err := desiredPartnerIdentifiers(spec)
	if err != nil {
		return err
	}
	if len(desired) == 0 {
		return nil
	}

	// 1. Truststore: the cert must be trusted for the handshake before the
	// identity identifier means anything. Best-effort/idempotent: a gateway that
	// does not expose the keystore config still gets the app-level identifier.
	if strings.TrimSpace(spec.PublicCertRef) != "" {
		pemBytes, derr := loadPublicCertPEM(spec.PublicCertRef)
		if derr != nil {
			return derr
		}
		if err := a.ensureTruststoreCert(ctx, appID, pemBytes); err != nil {
			return err
		}
	}

	app, err := a.getApplication(ctx, appID)
	if err != nil {
		return err
	}

	merged, changed := mergeIdentifiers(app["identifiers"], desired)
	if !changed {
		return nil // converged — idempotent no-op
	}
	app["identifiers"] = merged

	url := a.adminPath("/applications/" + appID)
	code, raw, err := a.sendJSON(ctx, http.MethodPut, url, app)
	if err != nil {
		return err
	}
	if code != http.StatusOK && code != http.StatusCreated {
		return fmt.Errorf("PUT %s (partner identifiers) expected 200/201, got %d: %s", url, code, truncate(raw, 300))
	}
	return nil
}

// wmIdentifier is one desired identifier in the gateway's WRITE shape
// {name,key,value[]} (the read shape adds an `id` and may move simple values to
// swaggerValue[] — handled in identifierValues when comparing).
type wmIdentifier struct {
	key   string
	name  string
	value []string
}

// desiredPartnerIdentifiers builds the desired identifier set from the spec.
// Values are de-duplicated and order-preserved; an empty slice yields no entry
// (so an absent field projects nothing). The cert PEM is encoded as the base64
// DER body (BEGIN/END stripped), the exact form the live gateway accepted.
func desiredPartnerIdentifiers(spec *adapter.ConsumerSpec) ([]wmIdentifier, error) {
	out := make([]wmIdentifier, 0, 3)
	if v := dedup(spec.TokenIdentifiers); len(v) > 0 {
		out = append(out, wmIdentifier{key: identifierKeyToken, name: identifierNameToken, value: v})
	}
	if v := dedup(spec.IPAllowlist); len(v) > 0 {
		// Normalize to the from-to form the gateway stores unambiguously and the
		// UI renders: a single IP -> X-X, a CIDR -> first-last (the gateway
		// silently drops both a bare CIDR and hides a bare single in the UI).
		norm := make([]string, 0, len(v))
		for _, e := range v {
			nr, err := normalizeIPRange(e)
			if err != nil {
				return nil, err
			}
			norm = append(norm, nr)
		}
		out = append(out, wmIdentifier{key: identifierKeyIP, name: identifierNameIP, value: norm})
	}
	if ref := strings.TrimSpace(spec.PublicCertRef); ref != "" {
		pemBytes, err := loadPublicCertPEM(ref)
		if err != nil {
			return nil, err
		}
		body, err := certDERBody(pemBytes)
		if err != nil {
			return nil, err
		}
		out = append(out, wmIdentifier{key: identifierKeyCert, name: identifierNameCert, value: []string{body}})
	}
	return out, nil
}

// mergeIdentifiers upserts each desired identifier into the existing array by
// (key,name): an entry with the same value set is left untouched, a present
// entry with a different value set is replaced, an absent one is appended. Other
// identifiers (azp/openIdClaims, ...) are preserved verbatim. It reports whether
// anything changed so the caller can skip the PUT when converged.
func mergeIdentifiers(existing any, desired []wmIdentifier) ([]any, bool) {
	cur, _ := existing.([]any)
	out := make([]any, 0, len(cur)+len(desired))
	out = append(out, cur...)
	changed := false

	for _, d := range desired {
		idx := indexOfIdentifier(out, d.key, d.name)
		if idx >= 0 {
			if identifierValuesEqual(out[idx], d.value) {
				continue // already converged
			}
			out[idx] = map[string]any{"key": d.key, "name": d.name, "value": d.value}
			changed = true
			continue
		}
		out = append(out, map[string]any{"key": d.key, "name": d.name, "value": d.value})
		changed = true
	}
	return out, changed
}

// indexOfIdentifier returns the index of the identifier with (key,name), or -1.
func indexOfIdentifier(ids []any, key, name string) int {
	for i, raw := range ids {
		m, _ := raw.(map[string]any)
		if m == nil {
			continue
		}
		if k, _ := m["key"].(string); k != key {
			continue
		}
		if n, _ := m["name"].(string); n == name {
			return i
		}
	}
	return -1
}

// identifierValuesEqual compares an existing identifier's value set against the
// desired set, order-insensitively. It reads BOTH the write-shape `value[]` and
// the read-shape `swaggerValue[]` (the gateway returns simple identifiers — token
// /ip/cert — in swaggerValue on a GET), so idempotence holds across a write then
// read-back round-trip.
func identifierValuesEqual(existing any, want []string) bool {
	m, _ := existing.(map[string]any)
	if m == nil {
		return false
	}
	got := identifierValues(m)
	if len(got) != len(want) {
		return false
	}
	set := make(map[string]struct{}, len(got))
	for _, g := range got {
		set[g] = struct{}{}
	}
	for _, w := range want {
		if _, ok := set[w]; !ok {
			return false
		}
	}
	return true
}

// identifierValues extracts the string values from either the write-shape
// `value` or the read-shape `swaggerValue`. It tolerates both the JSON-decoded
// shape ([]any of strings, from a GET round-trip) and a Go-native []string (an
// entry this code just wrote in-memory) so idempotence holds in both.
func identifierValues(m map[string]any) []string {
	for _, field := range []string{"value", "swaggerValue"} {
		switch vals := m[field].(type) {
		case []any:
			if len(vals) == 0 {
				continue
			}
			out := make([]string, 0, len(vals))
			for _, v := range vals {
				if s, ok := v.(string); ok {
					out = append(out, s)
				}
			}
			return out
		case []string:
			if len(vals) == 0 {
				continue
			}
			return vals
		}
	}
	return nil
}

// dedup removes empty/duplicate entries while preserving first-seen order.
func dedup(in []string) []string {
	if len(in) == 0 {
		return nil
	}
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

// loadPublicCertPEM resolves PublicCertRef to PEM bytes — an inline PEM (the ref
// itself contains a BEGIN line) or an on-disk path — and REFUSES any material
// carrying a private key. Only PUBLIC certificates may flow through this path
// (secrets live in Vault/PAM, never in Git — le principe hors-data-plane/069).
func loadPublicCertPEM(ref string) ([]byte, error) {
	ref = strings.TrimSpace(ref)
	var raw []byte
	if strings.Contains(ref, "-----BEGIN") {
		raw = []byte(ref)
	} else {
		b, err := os.ReadFile(ref)
		if err != nil {
			return nil, fmt.Errorf("read publicCertRef %q: %w", ref, err)
		}
		raw = b
	}
	if err := assertNoPrivateKey(raw); err != nil {
		return nil, err
	}
	if !strings.Contains(string(raw), "CERTIFICATE") {
		return nil, fmt.Errorf("publicCertRef %q carries no CERTIFICATE block (expected a public X.509 PEM)", ref)
	}
	return raw, nil
}

// assertNoPrivateKey fails closed if the PEM contains a private key block — the
// guard that keeps secret material out of this code path (and out of Git).
func assertNoPrivateKey(pemBytes []byte) error {
	rest := pemBytes
	for {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			break
		}
		if strings.Contains(strings.ToUpper(block.Type), "PRIVATE KEY") {
			return fmt.Errorf("publicCertRef carries a %q block: refusing private key material (use the PUBLIC cert only; secrets belong in Vault/PAM)", block.Type)
		}
	}
	// Catch raw "PRIVATE KEY" text even if pem.Decode failed to parse a block.
	if strings.Contains(strings.ToUpper(string(pemBytes)), "PRIVATE KEY") {
		return fmt.Errorf("publicCertRef carries PRIVATE KEY material: refusing (use the PUBLIC cert only; secrets belong in Vault/PAM)")
	}
	return nil
}

// certDERBody extracts the base64 DER body of the FIRST certificate block —
// BEGIN/END lines stripped, whitespace removed — which is the exact value form
// the live 10.15 gateway accepted for the httpsCertificate identifier.
func certDERBody(pemBytes []byte) (string, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil || !strings.Contains(strings.ToUpper(block.Type), "CERTIFICATE") {
		return "", fmt.Errorf("publicCertRef: no parseable CERTIFICATE PEM block")
	}
	return base64.StdEncoding.EncodeToString(block.Bytes), nil
}
