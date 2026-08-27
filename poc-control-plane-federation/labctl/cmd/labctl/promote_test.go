package cmd

// promote_test.go — the .promote.yml manifest loader: per_env recursive merge
// (root ⊕ per_env[env]) and the ENV_UNDEFINED fail-closed, mirroring the
// Ansible role's resolve-env semantics on the SAME manifest file.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const promoteManifestFixture = `apim_promote:
  name: "accounts-read"
  version: "1.0.0"
  guid: "604e433c-aad0-4013-a9bc-b00f7bdbf906"
  archive: "/tmp/accounts-read.zip"
  backend_alias:
    name: "accounts-backend"
  cred_alias:
    name: "accounts-backend-creds"
    auth_type: "NTLM"
  scope_mapping:
    external_scope: "accounts.read"
    auth_server_alias: "BankAuth-demo"
  per_env:
    dev:
      backend_alias: { url: "http://backend-dev:8080" }
      cred_alias: { vault_sub: "envs/dev/backends/accounts", domain: "CORPDEV" }
    prod:
      backend_alias: { url: "https://accounts.core.bank" }
      cred_alias: { vault_sub: "envs/prod/backends/accounts", domain: "CORP" }
`

func writePromoteFixture(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "test.promote.yml")
	if err := os.WriteFile(p, []byte(promoteManifestFixture), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadPromoteManifest_PerEnvMergeIsRecursive(t *testing.T) {
	spec, err := loadPromoteManifest(writePromoteFixture(t), "prod")
	if err != nil {
		t.Fatalf("loadPromoteManifest: %v", err)
	}
	// invariant root fields survive the merge…
	if spec.Name != "accounts-read" || spec.GUID == "" {
		t.Errorf("invariants lost in merge: name=%q guid=%q", spec.Name, spec.GUID)
	}
	if spec.BackendAlias.Name != "accounts-backend" {
		t.Errorf("backend_alias.name = %q — the per_env override must MERGE, not replace the block", spec.BackendAlias.Name)
	}
	if spec.CredAlias.AuthType != "NTLM" {
		t.Errorf("cred_alias.auth_type = %q, want the invariant NTLM", spec.CredAlias.AuthType)
	}
	// …and the env values land.
	if spec.BackendAlias.URL != "https://accounts.core.bank" {
		t.Errorf("backend_alias.url = %q, want prod's", spec.BackendAlias.URL)
	}
	if spec.CredAlias.VaultSub != "envs/prod/backends/accounts" || spec.CredAlias.Domain != "CORP" {
		t.Errorf("cred_alias = %+v, want prod's vault_sub + domain", spec.CredAlias)
	}
	// default overwrite is the proven scoped list, never "*"
	if strings.Contains(spec.Overwrite, "aliases") || spec.Overwrite == "*" {
		t.Errorf("overwrite default = %q — must never cover aliases", spec.Overwrite)
	}
}

func TestLoadPromoteManifest_FailsClosedOnUnknownEnv(t *testing.T) {
	p := writePromoteFixture(t)
	for _, env := range []string{"", "rec"} {
		if _, err := loadPromoteManifest(p, env); err == nil || !strings.Contains(err.Error(), "ENV_UNDEFINED") {
			t.Errorf("env=%q: err = %v, want ENV_UNDEFINED (per_env declared ⇒ env must be known)", env, err)
		}
	}
}

func TestPromoteArchiveOverride(t *testing.T) {
	spec := promoteSpec{Archive: "{{ playbook_dir }}/../dist/x.zip"}
	if err := applyArchiveOverride(&spec, "/tmp/fetched.zip"); err != nil || spec.Archive != "/tmp/fetched.zip" {
		t.Fatalf("override: %v / %q", err, spec.Archive)
	}
	spec = promoteSpec{Archive: "{{ playbook_dir }}/../dist/x.zip"}
	if err := applyArchiveOverride(&spec, ""); err == nil {
		t.Fatal("un chemin templaté sans --archive doit refuser (ARCHIVE_PATH_TEMPLATED)")
	}
	spec = promoteSpec{Archive: "/deja/absolu.zip"}
	if err := applyArchiveOverride(&spec, ""); err != nil || spec.Archive != "/deja/absolu.zip" {
		t.Fatalf("chemin littéral sans flag: %v", err)
	}
}
