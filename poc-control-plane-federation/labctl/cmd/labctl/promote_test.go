package cmd

// promote_test.go — the .promote.yml manifest loader: per_env recursive merge
// (root ⊕ per_env[env]) and the ENV_UNDEFINED fail-closed, mirroring the
// Ansible role's resolve-env semantics on the SAME manifest file.

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
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

// --- promote --action verify (G8): read-only replay of the gate -------------

// runPromoteVerifyAgainst spins a fake gateway, writes a targets file and a
// shared-shape manifest, then drives runPromote with --action verify. It
// returns the command output, the error, and the calls the gateway saw.
func runPromoteVerifyAgainst(t *testing.T, guid, apiJSON, aliasJSON string) (string, error, *[]string) {
	t.Helper()
	calls := &[]string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*calls = append(*calls, r.Method+" "+r.URL.Path)
		if r.Method != http.MethodGet {
			http.Error(w, "verify must be read-only", http.StatusMethodNotAllowed)
			return
		}
		switch {
		case strings.HasPrefix(r.URL.Path, "/rest/apigateway/apis/"):
			fmt.Fprint(w, apiJSON)
		case r.URL.Path == "/rest/apigateway/alias":
			fmt.Fprint(w, aliasJSON)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)

	dir := t.TempDir()
	manifest := filepath.Join(dir, "m.promote.yml")
	if err := os.WriteFile(manifest, []byte(`apim_promote:
  name: "g8par-api"
  version: "1.0.0"
  guid: "`+guid+`"
  backend_alias: { name: "g8par-backend" }
  per_env:
    rec: { backend_alias: { url: "http://poc-token-echo:8080/backend/rec" } }
`), 0o600); err != nil {
		t.Fatal(err)
	}
	contract := filepath.Join(dir, "contract.yaml")
	if err := os.WriteFile(contract, []byte("openapi: 3.0.0\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	targetsF := filepath.Join(dir, "targets.yaml")
	if err := os.WriteFile(targetsF, []byte(`apiVersion: labctl.stoa.io/v1
kind: FederationTarget
name: g8par
contract: `+contract+`
targets:
  - name: wm
    type: webmethods
    adminUrl: `+srv.URL+`
    gatewayUrl: `+srv.URL+`
    credentials:
      username: u
      password: p
`), 0o600); err != nil {
		t.Fatal(err)
	}

	savedManifest, savedAction, savedEnv, savedTarget, savedArchive, savedFile :=
		promoteManifestFlag, promoteActionFlag, promoteEnvFlag, promoteTargetFlag, promoteArchiveFlag, fileFlag
	t.Cleanup(func() {
		promoteManifestFlag, promoteActionFlag, promoteEnvFlag, promoteTargetFlag, promoteArchiveFlag, fileFlag =
			savedManifest, savedAction, savedEnv, savedTarget, savedArchive, savedFile
	})
	promoteManifestFlag, promoteActionFlag, promoteEnvFlag = manifest, "verify", "rec"
	promoteTargetFlag, promoteArchiveFlag, fileFlag = "", "", targetsF

	out := new(strings.Builder)
	promoteCmd.SetOut(out)
	promoteCmd.SetContext(context.Background())
	err := runPromote(promoteCmd, nil)
	return out.String(), err, calls
}

const verifyGUID = "11111111-2222-3333-4444-555555555555"

func TestPromoteVerify_NominalIsReadOnly(t *testing.T) {
	apiJSON := `{"apiResponse":{"api":{"id":"` + verifyGUID + `","apiName":"g8par-api","apiVersion":"1.0.0","isActive":true}}}`
	aliasJSON := `{"alias":[{"id":"a1","name":"g8par-backend","type":"endpoint","endPointURI":"http://poc-token-echo:8080/backend/rec"}]}`
	out, err, calls := runPromoteVerifyAgainst(t, verifyGUID, apiJSON, aliasJSON)
	if err != nil {
		t.Fatalf("verify nominal: %v (out=%s)", err, out)
	}
	if !strings.Contains(out, "PROMOTE_CONFIRMED") {
		t.Fatalf("want PROMOTE_CONFIRMED, out=%s", out)
	}
	if len(*calls) == 0 {
		t.Fatal("verify hit the gateway zero times — it verified nothing")
	}
	for _, c := range *calls {
		if !strings.HasPrefix(c, "GET ") {
			t.Fatalf("verify wrote to the gateway: %s", c)
		}
	}
}

func TestPromoteVerify_RefusesInactive(t *testing.T) {
	apiJSON := `{"apiResponse":{"api":{"id":"` + verifyGUID + `","apiName":"g8par-api","apiVersion":"1.0.0","isActive":false}}}`
	_, err, _ := runPromoteVerifyAgainst(t, verifyGUID, apiJSON, `{"alias":[]}`)
	if err == nil {
		t.Fatal("inactive API must refuse")
	}
}

func TestPromoteVerify_RefusesWrongName(t *testing.T) {
	apiJSON := `{"apiResponse":{"api":{"id":"` + verifyGUID + `","apiName":"autre-api","apiVersion":"1.0.0","isActive":true}}}`
	_, err, _ := runPromoteVerifyAgainst(t, verifyGUID, apiJSON, `{"alias":[]}`)
	if err == nil || !strings.Contains(err.Error(), "PROMOTE_UNCONFIRMED") {
		t.Fatalf("want PROMOTE_UNCONFIRMED on name mismatch, got %v", err)
	}
}

func TestPromoteVerify_NamesAliasDrift(t *testing.T) {
	apiJSON := `{"apiResponse":{"api":{"id":"` + verifyGUID + `","apiName":"g8par-api","apiVersion":"1.0.0","isActive":true}}}`
	aliasJSON := `{"alias":[{"id":"a1","name":"g8par-backend","type":"endpoint","endPointURI":"http://WRONG"}]}`
	_, err, _ := runPromoteVerifyAgainst(t, verifyGUID, apiJSON, aliasJSON)
	if err == nil || !strings.Contains(err.Error(), "ALIAS_DRIFT") {
		t.Fatalf("want ALIAS_DRIFT, got %v", err)
	}
}

func TestPromoteVerify_RequiresPinnedGUID(t *testing.T) {
	_, err, calls := runPromoteVerifyAgainst(t, "",
		`{"apiResponse":{"api":{}}}`, `{"alias":[]}`)
	if err == nil || !strings.Contains(err.Error(), "VERIFY_REFUSED") {
		t.Fatalf("want VERIFY_REFUSED without pinned guid, got %v", err)
	}
	if len(*calls) != 0 {
		t.Fatalf("refusal must precede any network call, saw %v", *calls)
	}
}
