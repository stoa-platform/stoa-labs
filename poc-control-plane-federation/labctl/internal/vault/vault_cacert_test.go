package vault

import (
	"context"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// TestFromEnvHonorsVaultCACert proves the É0 knob end-to-end at the vault
// layer: a Vault behind an enterprise CA is readable with VAULT_CACERT set
// (standard Vault CLI knob) and rejected without it — no VAULT_INSECURE needed.
func TestFromEnvHonorsVaultCACert(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"data":{"adminKey":"from-vault"}}}`))
	}))
	defer srv.Close()
	caPath := filepath.Join(t.TempDir(), "ca.pem")
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: srv.Certificate().Raw})
	if err := os.WriteFile(caPath, pemBytes, 0o600); err != nil {
		t.Fatal(err)
	}

	t.Setenv("VAULT_ADDR", srv.URL)
	t.Setenv("VAULT_TOKEN", "test-token")
	t.Setenv("VAULT_INSECURE", "")
	t.Setenv("LABCTL_CA_FILE", "")

	// Control: unknown authority without the knob.
	t.Setenv("VAULT_CACERT", "")
	c, ok := FromEnv()
	if !ok {
		t.Fatal("FromEnv: expected enabled client")
	}
	if _, err := c.ReadKV(context.Background(), "gateways/apisix"); err == nil {
		t.Fatal("expected x509 failure without VAULT_CACERT (control)")
	}

	t.Setenv("VAULT_CACERT", caPath)
	c, _ = FromEnv()
	got, err := c.ReadKV(context.Background(), "gateways/apisix")
	if err != nil {
		t.Fatalf("ReadKV with VAULT_CACERT: %v", err)
	}
	if got["adminKey"] != "from-vault" {
		t.Fatalf("unexpected secret payload: %v", got)
	}
}
