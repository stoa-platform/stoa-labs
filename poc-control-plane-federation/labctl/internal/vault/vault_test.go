package vault

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func decodeJSON(r *http.Request, v any) error {
	return json.NewDecoder(r.Body).Decode(v)
}

func TestEnabledAndFromEnv(t *testing.T) {
	t.Setenv("VAULT_ADDR", "")
	if Enabled() {
		t.Error("Enabled must be false without VAULT_ADDR")
	}
	if _, ok := FromEnv(); ok {
		t.Error("FromEnv must return ok=false without VAULT_ADDR")
	}
	t.Setenv("VAULT_ADDR", "http://localhost:8200")
	if !Enabled() {
		t.Error("Enabled must be true with VAULT_ADDR")
	}
	if _, ok := FromEnv(); !ok {
		t.Error("FromEnv must return ok=true with VAULT_ADDR")
	}
}

func TestReadKV(t *testing.T) {
	var gotPath, gotToken string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotToken = r.Header.Get("X-Vault-Token")
		// KV v2 envelope: data.data carries the secret pairs.
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"data":{"adminKey":"poc-apisix-admin-key"},"metadata":{"version":1}}}`))
	}))
	defer srv.Close()

	t.Setenv("VAULT_ADDR", srv.URL)
	t.Setenv("VAULT_TOKEN", "unit-test-token")
	t.Setenv("VAULT_KV_MOUNT", "secret")
	t.Setenv("VAULT_PREFIX", "stoa")

	c, ok := FromEnv()
	if !ok {
		t.Fatal("FromEnv ok=false")
	}
	data, err := c.ReadKV(context.Background(), "gateways/apisix")
	if err != nil {
		t.Fatalf("ReadKV: %v", err)
	}
	if data["adminKey"] != "poc-apisix-admin-key" {
		t.Errorf("adminKey = %q, want poc-apisix-admin-key", data["adminKey"])
	}
	if gotPath != "/v1/secret/data/stoa/gateways/apisix" {
		t.Errorf("path = %q, want /v1/secret/data/stoa/gateways/apisix", gotPath)
	}
	if gotToken != "unit-test-token" {
		t.Errorf("X-Vault-Token = %q, want unit-test-token", gotToken)
	}
}

func TestReadKV_MissingSecretFallsBack(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"errors":[]}`))
	}))
	defer srv.Close()
	t.Setenv("VAULT_ADDR", srv.URL)
	t.Setenv("VAULT_TOKEN", "t")
	c, _ := FromEnv()
	got, err := c.ReadKV(context.Background(), "gateways/nope")
	if err != nil || got != nil {
		t.Errorf("a 404 must return (nil,nil) so the caller falls back; got (%v,%v)", got, err)
	}
}

func TestTokenFilePreferredOverEnv(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "tok")
	if err := os.WriteFile(f, []byte("  file-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("VAULT_ADDR", "http://localhost:8200")
	t.Setenv("VAULT_TOKEN", "env-token")
	t.Setenv("VAULT_TOKEN_FILE", f)
	c, _ := FromEnv()
	tok, err := c.ensureToken(context.Background())
	if err != nil || tok != "file-token" {
		t.Errorf("token-file must win over env (trimmed): got (%q,%v)", tok, err)
	}
}

func TestAppRoleLogin(t *testing.T) {
	var loginBody map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/approle/login":
			_ = decodeJSON(r, &loginBody)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"auth":{"client_token":"ephemeral-token-123","policies":["default","stoa-labctl"],"lease_duration":180}}`))
		default: // KV read — must carry the ephemeral token from the login
			if r.Header.Get("X-Vault-Token") != "ephemeral-token-123" {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"data":{"data":{"adminKey":"k"}}}`))
		}
	}))
	defer srv.Close()

	t.Setenv("VAULT_ADDR", srv.URL)
	t.Setenv("VAULT_TOKEN", "")      // no static token
	t.Setenv("VAULT_TOKEN_FILE", "") // none
	t.Setenv("VAULT_ROLE_ID", "role-abc")
	t.Setenv("VAULT_SECRET_ID", "secret-xyz")

	c, ok := FromEnv()
	if !ok {
		t.Fatal("FromEnv ok=false")
	}
	data, err := c.ReadKV(context.Background(), "gateways/apisix")
	if err != nil {
		t.Fatalf("ReadKV via AppRole: %v", err)
	}
	if data["adminKey"] != "k" {
		t.Errorf("adminKey = %q, want k", data["adminKey"])
	}
	if loginBody["role_id"] != "role-abc" || loginBody["secret_id"] != "secret-xyz" {
		t.Errorf("AppRole login body = %+v, want role-abc/secret-xyz", loginBody)
	}
}

func TestNoTokenNoAppRoleErrors(t *testing.T) {
	t.Setenv("VAULT_ADDR", "http://localhost:8200")
	t.Setenv("VAULT_TOKEN", "")
	t.Setenv("VAULT_TOKEN_FILE", "")
	t.Setenv("VAULT_ROLE_ID", "")
	t.Setenv("VAULT_SECRET_ID", "")
	c, _ := FromEnv()
	if _, err := c.ensureToken(context.Background()); err == nil {
		t.Error("no token and no AppRole must error")
	}
}

func TestReadKV_AuthFailureErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"errors":["permission denied"]}`))
	}))
	defer srv.Close()
	t.Setenv("VAULT_ADDR", srv.URL)
	t.Setenv("VAULT_TOKEN", "bad")
	c, _ := FromEnv()
	if _, err := c.ReadKV(context.Background(), "gateways/apisix"); err == nil {
		t.Error("a 403 (configured-but-broken Vault) must surface as an error")
	}
}

func TestTokenPolicies(t *testing.T) {
	var gotPath, gotToken string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotToken = r.Header.Get("X-Vault-Token")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"policies":["default","apply-int"],"identity_policies":["ldap-derived"]}}`))
	}))
	defer srv.Close()

	t.Setenv("VAULT_ADDR", srv.URL)
	t.Setenv("VAULT_TOKEN", "unit-test-token")

	c, ok := FromEnv()
	if !ok {
		t.Fatal("FromEnv ok=false")
	}
	got, err := c.TokenPolicies(context.Background())
	if err != nil {
		t.Fatalf("TokenPolicies: %v", err)
	}
	want := []string{"default", "apply-int", "ldap-derived"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("policies = %v, want %v", got, want)
	}
	if gotPath != "/v1/auth/token/lookup-self" {
		t.Errorf("path = %q, want /v1/auth/token/lookup-self", gotPath)
	}
	if gotToken != "unit-test-token" {
		t.Errorf("X-Vault-Token = %q, want unit-test-token", gotToken)
	}
}

// Fail-closed : un lookup refusé n'est jamais « pas de policies », c'est une erreur.
func TestTokenPolicies_AuthFailureErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()
	t.Setenv("VAULT_ADDR", srv.URL)
	t.Setenv("VAULT_TOKEN", "bad")
	c, _ := FromEnv()
	if _, err := c.TokenPolicies(context.Background()); err == nil {
		t.Fatal("expected error on 403 lookup-self, got nil (fail-open)")
	}
}

// Fail-closed : un 200 à corps vide (ou {"data":{}}) n'est jamais « zéro
// policy » — un token Vault réel porte toujours au moins une policy
// (default/root) ; l'union vide signale un corps illisible/inattendu, pas un
// token légitimement dépourvu de policies.
func TestTokenPolicies_EmptyBodyErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{}}`))
	}))
	defer srv.Close()
	t.Setenv("VAULT_ADDR", srv.URL)
	t.Setenv("VAULT_TOKEN", "tok")
	c, _ := FromEnv()
	if _, err := c.TokenPolicies(context.Background()); err == nil {
		t.Fatal("expected error on empty policies/identity_policies, got nil (fail-open)")
	}
}
