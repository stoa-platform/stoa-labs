package webmethods

// Tests for the partner-onboarding identifier projection (ADR-071): the optional
// custom TOKEN, IP allowlist and public CERTIFICATE an admin posts BY HAND today
// on the webMethods application, now projected as-code. They assert the
// live-pinned identifier keys (token / ipAddressRange / httpsCertificate — the
// singular `token`, NOT `tokens`; `httpsCertificate`, NOT `certificate`), the
// ADDITIVE merge with the existing azp/openIdClaims set, the two-step cert
// binding (truststore PUT + app identifier), idempotence, the absent->unchanged
// default, and the private-key refusal that keeps secrets out of Git.

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

// testPublicCertPEM generates a throwaway self-signed PUBLIC certificate PEM for
// the cert-binding tests (no private key leaves this function).
func testPublicCertPEM(t *testing.T) string {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("gen key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(42),
		Subject:      pkix.Name{CommonName: "partner-acme-test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create cert: %v", err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
}

// identifierByKeyName returns the stored identifier with (key,name), or nil.
func identifierByKeyName(t *testing.T, mock *mockGateway, appID, key, name string) map[string]any {
	t.Helper()
	app := mock.appRaw[appID]
	if app == nil {
		t.Fatalf("application %q not stored", appID)
	}
	ids, _ := app["identifiers"].([]any)
	for _, raw := range ids {
		m, _ := raw.(map[string]any)
		if m == nil {
			continue
		}
		k, _ := m["key"].(string)
		n, _ := m["name"].(string)
		if k == key && n == name {
			return m
		}
	}
	return nil
}

// identifierStringValues reads value[] off a stored identifier as []string.
func identifierStringValues(m map[string]any) []string {
	vals, _ := m["value"].([]any)
	out := make([]string, 0, len(vals))
	for _, v := range vals {
		if s, ok := v.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

// TestCreateConsumer_ProjectsTokenAndIPIdentifiers asserts that declared token +
// IP identifiers are projected with the live-pinned keys, MERGED alongside the
// azp/openIdClaims identifier (which the OAuth2 path installs first).
func TestCreateConsumer_ProjectsTokenAndIPIdentifiers(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newOAuth2Adapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	spec := &adapter.ConsumerSpec{
		Name:             "labctl-live-consumer",
		ClientID:         testClientID,
		AuthType:         "oauth2",
		TokenIdentifiers: []string{"b2b-partner-acme-2026"},
		IPAllowlist:      []string{"203.0.113.10", "10.60.30.1-10.60.30.30"},
	}
	res, err := a.CreateConsumer(context.Background(), api, spec)
	if err != nil {
		t.Fatalf("CreateConsumer: %v", err)
	}

	// azp/openIdClaims survives (the OAuth2 binding is not clobbered by the merge).
	app := mock.appRaw[res.ConsumerID]
	if !appHasAZPIdentifier(app, testClientID) {
		t.Errorf("azp/openIdClaims identifier lost after partner projection: %v", app["identifiers"])
	}

	// token identifier — live-pinned key "token" (NOT "tokens").
	tok := identifierByKeyName(t, mock, res.ConsumerID, identifierKeyToken, identifierNameToken)
	if tok == nil {
		t.Fatalf("token identifier (key=%q) not posed: %v", identifierKeyToken, app["identifiers"])
	}
	if identifierKeyToken != "token" {
		t.Errorf("identifierKeyToken = %q, want live-pinned %q", identifierKeyToken, "token")
	}
	if got := identifierStringValues(tok); len(got) != 1 || got[0] != "b2b-partner-acme-2026" {
		t.Errorf("token value = %v, want [b2b-partner-acme-2026]", got)
	}

	// IP identifier — key "ipAddressRange", both entries carried.
	ip := identifierByKeyName(t, mock, res.ConsumerID, identifierKeyIP, identifierNameIP)
	if ip == nil {
		t.Fatalf("ipAddressRange identifier not posed: %v", app["identifiers"])
	}
	if got := identifierStringValues(ip); len(got) != 2 {
		t.Errorf("ip value = %v, want 2 entries", got)
	}

	// The API association survives the identifier PUT.
	if got := mock.appAPIs[res.ConsumerID]; len(got) != 1 || got[0] != "wm-api-0001" {
		t.Errorf("API association lost after partner identifier PUT: %v", got)
	}
}

// TestCreateConsumer_ProjectsCertIdentifierAndTruststore asserts the two-step
// cert binding: the public PEM is registered in the gateway truststore
// (/configurations/keystore PUT) AND posed as the httpsCertificate identifier.
func TestCreateConsumer_ProjectsCertIdentifierAndTruststore(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newOAuth2Adapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	spec := &adapter.ConsumerSpec{
		Name:          "labctl-live-consumer",
		ClientID:      testClientID,
		PublicCertRef: testPublicCertPEM(t), // inline PEM
	}
	res, err := a.CreateConsumer(context.Background(), api, spec)
	if err != nil {
		t.Fatalf("CreateConsumer: %v", err)
	}

	// (1) the cert identifier is posed with the live-pinned key "httpsCertificate".
	cert := identifierByKeyName(t, mock, res.ConsumerID, identifierKeyCert, identifierNameCert)
	if cert == nil {
		t.Fatalf("httpsCertificate identifier not posed: %v", mock.appRaw[res.ConsumerID]["identifiers"])
	}
	if identifierKeyCert != "httpsCertificate" {
		t.Errorf("identifierKeyCert = %q, want live-pinned %q", identifierKeyCert, "httpsCertificate")
	}
	if got := identifierStringValues(cert); len(got) != 1 || got[0] == "" || strings.Contains(got[0], "BEGIN") {
		t.Errorf("cert value should be the base64 DER body (no BEGIN/END), got %v", got)
	}

	// (2) the truststore PUT happened and carries our partner alias.
	if got := mock.countRequests("PUT /rest/apigateway/configurations/keystore"); got != 1 {
		t.Errorf("truststore PUT count = %d, want 1", got)
	}
	if !truststoreHasAlias(mock.keystoreConfig, truststoreAliasFor(res.ConsumerID)) {
		t.Errorf("truststore config %v does not carry the partner alias", mock.keystoreConfig)
	}
}

// TestCreateConsumer_PartnerIdentifiersIdempotent asserts a re-apply does not
// duplicate identifiers and issues NO second application PUT.
func TestCreateConsumer_PartnerIdentifiersIdempotent(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newOAuth2Adapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	spec := &adapter.ConsumerSpec{
		Name:             "labctl-live-consumer",
		ClientID:         testClientID,
		TokenIdentifiers: []string{"b2b-partner-acme-2026"},
		IPAllowlist:      []string{"203.0.113.10"},
	}

	if _, err := a.CreateConsumer(context.Background(), api, spec); err != nil {
		t.Fatalf("first CreateConsumer: %v", err)
	}
	res, err := a.CreateConsumer(context.Background(), api, spec)
	if err != nil {
		t.Fatalf("second CreateConsumer: %v", err)
	}

	app := mock.appRaw[res.ConsumerID]
	ids, _ := app["identifiers"].([]any)
	// Expect exactly: azp + token + ip = 3 identifiers, no duplicates.
	if len(ids) != 3 {
		t.Fatalf("identifiers after re-apply = %d (%v), want 3 (azp+token+ip, no dup)", len(ids), ids)
	}
	// The first subscribe writes azp (OAuth2 binding) then partner ids; the second
	// must see partner ids converged and skip the partner PUT. The azp binding PUT
	// + the one partner PUT on the first run = 2 PUTs to /applications/{id}; the
	// second run adds none.
	if got := mock.countExact("PUT /rest/apigateway/applications/" + res.ConsumerID); got != 2 {
		t.Errorf("application PUT count = %d over two subscribes, want 2 (azp + partner, then converged)", got)
	}
}

// TestCreateConsumer_NoPartnerFieldsLeavesAppUnchanged asserts the default
// behavior is byte-identical to before: with no partner field, the application
// carries ONLY the azp/openIdClaims identifier and the truststore is untouched.
func TestCreateConsumer_NoPartnerFieldsLeavesAppUnchanged(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newOAuth2Adapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	spec := &adapter.ConsumerSpec{Name: "labctl-live-consumer", ClientID: testClientID}

	res, err := a.CreateConsumer(context.Background(), api, spec)
	if err != nil {
		t.Fatalf("CreateConsumer: %v", err)
	}
	app := mock.appRaw[res.ConsumerID]
	ids, _ := app["identifiers"].([]any)
	if len(ids) != 1 {
		t.Fatalf("identifiers = %d (%v), want 1 (azp only — no partner projection)", len(ids), ids)
	}
	if !appHasAZPIdentifier(app, testClientID) {
		t.Errorf("the single identifier is not azp: %v", ids)
	}
	// No truststore call at all when no cert is declared.
	if got := mock.countRequests("PUT /rest/apigateway/configurations/keystore"); got != 0 {
		t.Errorf("truststore PUT count = %d, want 0 (no cert declared)", got)
	}
}

// TestCreateConsumer_PartnerIdentifiersWithoutOAuth2 asserts partner identifiers
// are projected even on the signature-only path (no audience -> no azp binding):
// the merge starts from an empty identifier set and is the load-bearing identity.
func TestCreateConsumer_PartnerIdentifiersWithoutOAuth2(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newAdapter(t, srv) // plain adapter, no inbound OAuth2
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	spec := &adapter.ConsumerSpec{
		Name:             "partner-app",
		ClientID:         "kc-client-abc123",
		TokenIdentifiers: []string{"shared-token-A"},
	}
	res, err := a.CreateConsumer(context.Background(), api, spec)
	if err != nil {
		t.Fatalf("CreateConsumer: %v", err)
	}
	if identifierByKeyName(t, mock, res.ConsumerID, identifierKeyToken, identifierNameToken) == nil {
		t.Errorf("token identifier not posed on the signature-only path: %v", mock.appRaw[res.ConsumerID]["identifiers"])
	}
}

// TestCreateConsumer_TruststoreEndpointMissingIsBestEffort asserts a build that
// does not expose /configurations/keystore (404) does NOT fail the subscribe:
// the cert identifier is still posed on the application (the load-bearing
// identity binding) while the truststore step degrades gracefully.
func TestCreateConsumer_TruststoreEndpointMissingIsBestEffort(t *testing.T) {
	mock := newMockGateway()
	mock.noKeystoreEndpoint = true
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newOAuth2Adapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	spec := &adapter.ConsumerSpec{
		Name:          "labctl-live-consumer",
		ClientID:      testClientID,
		PublicCertRef: testPublicCertPEM(t),
	}
	res, err := a.CreateConsumer(context.Background(), api, spec)
	if err != nil {
		t.Fatalf("CreateConsumer must not fail when the keystore endpoint is absent: %v", err)
	}
	if identifierByKeyName(t, mock, res.ConsumerID, identifierKeyCert, identifierNameCert) == nil {
		t.Errorf("cert identifier not posed despite best-effort truststore: %v", mock.appRaw[res.ConsumerID]["identifiers"])
	}
}

// TestLoadPublicCertPEM_RefusesPrivateKey asserts the guard that keeps secrets
// out of Git: a PEM carrying a private key block is REFUSED.
func TestLoadPublicCertPEM_RefusesPrivateKey(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("gen key: %v", err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(key),
	})
	bundle := testPublicCertPEM(t) + string(keyPEM)

	if _, err := loadPublicCertPEM(bundle); err == nil {
		t.Fatal("loadPublicCertPEM accepted a PEM containing a private key, want refusal")
	} else if !strings.Contains(strings.ToUpper(err.Error()), "PRIVATE KEY") {
		t.Errorf("error = %v, want it to mention the refused PRIVATE KEY", err)
	}
}

// TestLoadPublicCertPEM_FromFile asserts an on-disk public PEM path is read.
func TestLoadPublicCertPEM_FromFile(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "public.crt")
	if err := os.WriteFile(p, []byte(testPublicCertPEM(t)), 0o600); err != nil {
		t.Fatalf("write cert: %v", err)
	}
	got, err := loadPublicCertPEM(p)
	if err != nil {
		t.Fatalf("loadPublicCertPEM(path): %v", err)
	}
	if !strings.Contains(string(got), "CERTIFICATE") {
		t.Errorf("loaded PEM does not contain a CERTIFICATE block")
	}
}

// TestMergeIdentifiers_UpsertsWithoutClobbering is a focused unit test on the
// merge: an existing azp identifier is preserved, a new token is appended, and a
// re-merge of the same desired set reports no change (idempotent).
func TestMergeIdentifiers_UpsertsWithoutClobbering(t *testing.T) {
	existing := []any{
		map[string]any{"key": "openIdClaims", "name": "azp", "value": []any{"accounts-read-consumer"}},
	}
	desired := []wmIdentifier{
		{key: identifierKeyToken, name: identifierNameToken, value: []string{"tok-1"}},
	}
	merged, changed := mergeIdentifiers(existing, desired)
	if !changed {
		t.Fatal("first merge reported no change, want changed")
	}
	if len(merged) != 2 {
		t.Fatalf("merged len = %d, want 2 (azp preserved + token appended)", len(merged))
	}
	// azp still present.
	if indexOfIdentifier(merged, "openIdClaims", "azp") < 0 {
		t.Error("azp identifier was clobbered by the merge")
	}
	// Re-merge the same desired set against the result -> no change.
	if _, changed2 := mergeIdentifiers(merged, desired); changed2 {
		t.Error("second merge of the same desired set reported a change, want idempotent")
	}
}
