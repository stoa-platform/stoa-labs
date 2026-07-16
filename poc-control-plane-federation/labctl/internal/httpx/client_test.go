package httpx

import (
	"context"
	"crypto/x509"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// startTLSServer returns a TLS test server plus the path of a PEM file holding
// its (self-signed) certificate — the shape of an enterprise CA bundle.
func startTLSServer(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	t.Cleanup(srv.Close)
	caPath := filepath.Join(t.TempDir(), "ca.pem")
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: srv.Certificate().Raw})
	if err := os.WriteFile(caPath, pemBytes, 0o600); err != nil {
		t.Fatalf("write CA bundle: %v", err)
	}
	return srv, caPath
}

// TestCAFileTrustsEnterpriseCA proves the É0 knob: a CA outside the system
// store is trusted once LABCTL_CA_FILE (env path) or an explicit bundle
// (NewClientCA) points at it — without Insecure.
func TestCAFileTrustsEnterpriseCA(t *testing.T) {
	srv, caPath := startTLSServer(t)

	// Control: without the bundle the handshake must fail (unknown authority).
	t.Setenv("LABCTL_CA_FILE", "")
	if _, _, err := Do(context.Background(), NewClient(false), http.MethodGet, srv.URL, nil, nil); err == nil {
		t.Fatal("expected x509 failure without CA bundle (control)")
	}

	// Explicit path (the VAULT_CACERT route).
	code, body, err := Do(context.Background(), NewClientCA(false, caPath), http.MethodGet, srv.URL, nil, nil)
	if err != nil || code != http.StatusOK || string(body) != "ok" {
		t.Fatalf("NewClientCA with bundle: err=%v code=%d body=%q", err, code, body)
	}

	// Env knob (the labctl route).
	t.Setenv("LABCTL_CA_FILE", caPath)
	code, _, err = Do(context.Background(), NewClient(false), http.MethodGet, srv.URL, nil, nil)
	if err != nil || code != http.StatusOK {
		t.Fatalf("NewClient with LABCTL_CA_FILE: err=%v code=%d", err, code)
	}
}

// TestCAFileFailsClosed: a set-but-broken CA knob must error on every request,
// never silently fall back to the system pool.
func TestCAFileFailsClosed(t *testing.T) {
	srv, _ := startTLSServer(t)

	_, _, err := Do(context.Background(), NewClientCA(false, filepath.Join(t.TempDir(), "absent.pem")), http.MethodGet, srv.URL, nil, nil)
	if err == nil || !strings.Contains(err.Error(), "read CA bundle") {
		t.Fatalf("unreadable bundle: expected 'read CA bundle' error, got %v", err)
	}

	junk := filepath.Join(t.TempDir(), "junk.pem")
	if err := os.WriteFile(junk, []byte("not a pem"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, _, err = Do(context.Background(), NewClientCA(false, junk), http.MethodGet, srv.URL, nil, nil)
	if err == nil || !strings.Contains(err.Error(), "no PEM certificate") {
		t.Fatalf("junk bundle: expected 'no PEM certificate' error, got %v", err)
	}
}

// TestInsecureStillWorks: the PoC escape hatch is unchanged by the CA knob.
func TestInsecureStillWorks(t *testing.T) {
	srv, _ := startTLSServer(t)
	t.Setenv("LABCTL_CA_FILE", "")
	code, _, err := Do(context.Background(), NewClient(true), http.MethodGet, srv.URL, nil, nil)
	if err != nil || code != http.StatusOK {
		t.Fatalf("insecure client: err=%v code=%d", err, code)
	}
}

// TestLoadCAPoolExtendsSystemRoots: the bundle is appended to the system pool,
// not substituted for it — one knob must not break public endpoints.
func TestLoadCAPoolExtendsSystemRoots(t *testing.T) {
	_, caPath := startTLSServer(t)
	pool, err := loadCAPool(caPath)
	if err != nil {
		t.Fatalf("loadCAPool: %v", err)
	}
	sys, err := x509.SystemCertPool()
	if err != nil || sys == nil {
		t.Skip("no system cert pool on this platform")
	}
	if len(pool.Subjects()) <= len(sys.Subjects()) { //nolint:staticcheck // count comparison only
		t.Fatalf("pool (%d subjects) does not extend system roots (%d)", len(pool.Subjects()), len(sys.Subjects()))
	}
}
