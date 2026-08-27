package cmd

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/uac"
)

// dgWriteRepo lays out a minimal governance repo: environments.yaml (prod
// optionally itsm-gated) + one published accounts-read contract with an enabled
// prod deploy carrying changeRef (omitted when empty).
func dgWriteRepo(t *testing.T, changeRef string, itsmGated bool) string {
	t.Helper()
	root := t.TempDir()
	envs := "environments: [dev, prod]\n"
	if itsmGated {
		envs += "gates:\n  - to: prod\n    fourEyes: true\n    requireChangeRef: true\n    itsmCheck: true\n"
	}
	mustWriteFile(t, filepath.Join(root, "environments.yaml"), envs)
	dir := filepath.Join(root, "tenants", "banking-demo", "apis", "accounts-read")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	mustWriteFile(t, filepath.Join(dir, "api.yaml"),
		"name: accounts-read\nversion: 1.0.0\ntenant_id: banking-demo\nstatus: published\n"+
			"endpoints: [{path: /accounts, methods: [GET], backend_url: http://microcks:8080/x}]\n")
	deploy := "version: 1.0.0\nenabled: true\npromoted_by: alice\n"
	if changeRef != "" {
		deploy += "change_ref: " + changeRef + "\n"
	}
	mustWriteFile(t, filepath.Join(dir, "deploy.prod.yaml"), deploy)
	return root
}

func mustWriteFile(t *testing.T, p, s string) {
	t.Helper()
	if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

// itsmServer serves {status} for any /changes/{id} GET.
func itsmServer(t *testing.T, status string) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"CHG","status":"` + status + `"}`))
	}))
	t.Cleanup(s.Close)
	return s
}

// gate loads the chain+apis of a repo and runs the pre-flight for env.
func gate(t *testing.T, repo, env string) error {
	t.Helper()
	gchain, err := loadGovChain(repo)
	if err != nil {
		return err
	}
	apis, err := uac.LoadRepo(repo)
	if err != nil {
		t.Fatalf("LoadRepo: %v", err)
	}
	return preflightDispatchGate(context.Background(), gchain, apis, "banking-demo", env)
}

func TestDispatchGate_ApprovedPasses(t *testing.T) {
	repo := dgWriteRepo(t, "CHG-0001", true)
	t.Setenv("ITSM_URL", itsmServer(t, "approved").URL)
	if err := gate(t, repo, "prod"); err != nil {
		t.Fatalf("approved change should pass, got %v", err)
	}
}

func TestDispatchGate_RevokedBlocks(t *testing.T) {
	repo := dgWriteRepo(t, "CHG-0001", true)
	t.Setenv("ITSM_URL", itsmServer(t, "cancelled").URL)
	err := gate(t, repo, "prod")
	if err == nil || !strings.Contains(err.Error(), "ITSM_NOT_APPROVED") {
		t.Fatalf("revoked change should block with ITSM_NOT_APPROVED, got %v", err)
	}
	if dispatchGateReason(err) != "itsm_not_approved_at_dispatch" {
		t.Errorf("audit reason = %q, want itsm_not_approved_at_dispatch", dispatchGateReason(err))
	}
}

func TestDispatchGate_ITSMUnavailableFailsClosed(t *testing.T) {
	repo := dgWriteRepo(t, "CHG-0001", true)
	t.Setenv("ITSM_URL", "http://127.0.0.1:1") // nothing listening
	err := gate(t, repo, "prod")
	if err == nil || !strings.Contains(err.Error(), "ITSM_UNAVAILABLE") {
		t.Fatalf("unreachable ITSM must fail closed with ITSM_UNAVAILABLE, got %v", err)
	}
}

func TestDispatchGate_ITSMNotConfiguredFailsClosed(t *testing.T) {
	repo := dgWriteRepo(t, "CHG-0001", true)
	t.Setenv("ITSM_URL", "")
	err := gate(t, repo, "prod")
	if err == nil || !strings.Contains(err.Error(), "ITSM_NOT_CONFIGURED") {
		t.Fatalf("empty ITSM_URL on a gated env must fail closed, got %v", err)
	}
}

func TestDispatchGate_MissingChangeRefFailsClosed(t *testing.T) {
	repo := dgWriteRepo(t, "", true) // gated but no change_ref in the dispatched state
	t.Setenv("ITSM_URL", itsmServer(t, "approved").URL)
	err := gate(t, repo, "prod")
	if err == nil || !strings.Contains(err.Error(), "NO_CHANGE_REF") {
		t.Fatalf("gated env with no change_ref must fail closed, got %v", err)
	}
}

func TestDispatchGate_UngatedEnvIsNoop(t *testing.T) {
	// No itsmCheck gate: even a revoked ITSM must not block (nothing to re-check).
	repo := dgWriteRepo(t, "CHG-0001", false)
	t.Setenv("ITSM_URL", itsmServer(t, "cancelled").URL)
	if err := gate(t, repo, "prod"); err != nil {
		t.Fatalf("ungated env should be a no-op, got %v", err)
	}
}

// --env any must NOT skip the gate: a gated+enabled prod deploy is re-checked.
func TestDispatchGate_AnyReChecksGatedEnv(t *testing.T) {
	repo := dgWriteRepo(t, "CHG-0001", true)
	t.Setenv("ITSM_URL", itsmServer(t, "cancelled").URL)
	err := gate(t, repo, uac.EnvAny)
	if err == nil || !strings.Contains(err.Error(), "ITSM_NOT_APPROVED") {
		t.Fatalf("--env any must re-check the gated prod deploy (no bypass), got %v", err)
	}
}

// --- deployer gate (G2, ADR-084) ---------------------------------------------

// dgWriteDeployerRepo lays out a 3-palier chain (dev → beta → prod) whose beta
// hop ALWAYS carries a gate (fourEyes) and declares deployerGroup only when
// named — so "no declaration" is tested against a REAL gate, not an absent one.
// betaEnabled=false leaves beta disabled and enables dev instead: a contract the
// run still walks, toward an env the beta declaration does not guard.
func dgWriteDeployerRepo(t *testing.T, deployerGroup string, betaEnabled bool) string {
	t.Helper()
	root := t.TempDir()
	envs := "environments: [dev, beta, prod]\ngates:\n  - to: beta\n    fourEyes: true\n"
	if deployerGroup != "" {
		envs += "    deployerGroup: " + deployerGroup + "\n"
	}
	mustWriteFile(t, filepath.Join(root, "environments.yaml"), envs)
	dir := filepath.Join(root, "tenants", "banking-demo", "apis", "accounts-read")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	mustWriteFile(t, filepath.Join(dir, "api.yaml"),
		"name: accounts-read\nversion: 1.0.0\ntenant_id: banking-demo\nstatus: published\n"+
			"endpoints: [{path: /accounts, methods: [GET], backend_url: http://microcks:8080/x}]\n")
	if betaEnabled {
		mustWriteFile(t, filepath.Join(dir, "deploy.beta.yaml"), "version: 1.0.0\nenabled: true\npromoted_by: alice\n")
		return root
	}
	mustWriteFile(t, filepath.Join(dir, "deploy.beta.yaml"), "version: 1.0.0\nenabled: false\npromoted_by: alice\n")
	mustWriteFile(t, filepath.Join(dir, "deploy.dev.yaml"), "version: 1.0.0\nenabled: true\npromoted_by: alice\n")
	return root
}

// dgVault serves lookup-self and COUNTS every request: the zero count is the
// only proof that an undeclared gate costs no round-trip to Vault.
type dgVault struct {
	url   string
	calls *atomic.Int32
}

func dgVaultServer(t *testing.T, status int, body string) *dgVault {
	t.Helper()
	var calls atomic.Int32
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/auth/token/lookup-self" {
			w.WriteHeader(http.StatusNotFound) // KV read (gateway creds) → manifest literal
			return
		}
		calls.Add(1)
		if status != http.StatusOK {
			w.WriteHeader(status)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(s.Close)
	return &dgVault{url: s.URL, calls: &calls}
}

// deployerGate loads the chain+apis of a repo and runs the deployer pre-flight.
func deployerGate(t *testing.T, repo, env string) error {
	t.Helper()
	gchain, err := loadGovChain(repo)
	if err != nil {
		return err
	}
	apis, err := uac.LoadRepo(repo)
	if err != nil {
		t.Fatalf("LoadRepo: %v", err)
	}
	return preflightDeployerGate(context.Background(), gchain, apis, "banking-demo", env)
}

func TestDeployerGate(t *testing.T) {
	const holds = `{"data":{"policies":["default","apply-beta"],"identity_policies":[]}}`
	const lacks = `{"data":{"policies":["default"],"identity_policies":[]}}`

	cases := []struct {
		name        string
		group       string // deployerGroup on the beta gate ("" = gate WITHOUT declaration)
		betaEnabled bool
		env         string
		vaultStatus int
		vaultBody   string
		noVaultAddr bool
		wantCode    string // "" = must pass
		wantReason  string
		wantCalls   int32 // lookup-self round-trips
	}{
		{
			name: "1_token_porteur_dans_le_groupe", group: "apim-apply-beta", betaEnabled: true, env: "beta",
			vaultStatus: http.StatusOK, vaultBody: holds, wantCalls: 1,
		},
		{
			name: "2_token_hors_groupe", group: "apim-apply-beta", betaEnabled: true, env: "beta",
			vaultStatus: http.StatusOK, vaultBody: lacks,
			wantCode: "DEPLOYER_GROUP_REQUIRED", wantReason: "deployer_group_required_at_dispatch", wantCalls: 1,
		},
		{
			name: "3_lookup_self_403", group: "apim-apply-beta", betaEnabled: true, env: "beta",
			vaultStatus: http.StatusForbidden,
			wantCode:    "DEPLOYER_GROUP_UNVERIFIABLE", wantReason: "deployer_group_unverifiable", wantCalls: 1,
		},
		{
			// Porte déclarée, identité invérifiable — fail-closed, sans même un appel.
			name: "4_vault_addr_vide", group: "apim-apply-beta", betaEnabled: true, env: "beta",
			vaultStatus: http.StatusOK, vaultBody: holds, noVaultAddr: true,
			wantCode: "DEPLOYER_GROUP_UNVERIFIABLE", wantReason: "deployer_group_unverifiable", wantCalls: 0,
		},
		{
			// Hors des deux familles projetables : refus LOUD, avant tout lookup.
			name: "5_famille_non_projetable", group: "int-team", betaEnabled: true, env: "beta",
			vaultStatus: http.StatusOK, vaultBody: holds,
			wantCode: "DEPLOYER_GROUP_UNSUPPORTED", wantReason: "deployer_group_unsupported", wantCalls: 0,
		},
		{
			// Une porte sans déclaration ne coûte RIEN : zéro appel à Vault.
			name: "6_gate_sans_deployer_group", group: "", betaEnabled: true, env: "beta",
			vaultStatus: http.StatusOK, vaultBody: holds, wantCalls: 0,
		},
		{
			// Jamais dispatché vers le palier déclaré = jamais gated (--env any).
			name: "7_api_non_enabled_sur_le_palier_declare", group: "apim-apply-beta", betaEnabled: false, env: uac.EnvAny,
			vaultStatus: http.StatusOK, vaultBody: lacks, wantCalls: 0,
		},
		{
			// Même contrat, palier concret : le contrat entier est hors dispatch.
			name: "7b_api_non_enabled_env_concret", group: "apim-apply-beta", betaEnabled: false, env: "beta",
			vaultStatus: http.StatusOK, vaultBody: lacks, wantCalls: 0,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			repo := dgWriteDeployerRepo(t, c.group, c.betaEnabled)
			v := dgVaultServer(t, c.vaultStatus, c.vaultBody)
			if c.noVaultAddr {
				t.Setenv("VAULT_ADDR", "")
			} else {
				t.Setenv("VAULT_ADDR", v.url)
			}
			t.Setenv("VAULT_TOKEN", "carrier-token")
			t.Setenv("VAULT_TOKEN_FILE", "")

			err := deployerGate(t, repo, c.env)
			if c.wantCode == "" {
				if err != nil {
					t.Fatalf("want pass, got %v", err)
				}
			} else {
				var g *dispatchGateError
				if !errors.As(err, &g) {
					t.Fatalf("want *dispatchGateError %s, got %v", c.wantCode, err)
				}
				if g.Code != c.wantCode {
					t.Fatalf("code = %q, want %q (msg %q)", g.Code, c.wantCode, g.Msg)
				}
				if got := dispatchGateReason(err); got != c.wantReason {
					t.Errorf("audit reason = %q, want %q", got, c.wantReason)
				}
			}
			if got := v.calls.Load(); got != c.wantCalls {
				t.Errorf("lookup-self calls = %d, want %d", got, c.wantCalls)
			}
		})
	}
}

// UN seul lookup-self par run : deux contrats gated sur le MÊME palier ne
// coûtent pas deux allers-retours vers Vault (la promesse du doc-comment).
func TestDeployerGate_OneLookupPerRun(t *testing.T) {
	repo := dgWriteDeployerRepo(t, "apim-apply-beta", true)
	dir := filepath.Join(repo, "tenants", "banking-demo", "apis", "payments-initiation")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	mustWriteFile(t, filepath.Join(dir, "api.yaml"),
		"name: payments-initiation\nversion: 1.0.0\ntenant_id: banking-demo\nstatus: published\n"+
			"endpoints: [{path: /payments, methods: [POST], backend_url: http://microcks:8080/y}]\n")
	mustWriteFile(t, filepath.Join(dir, "deploy.beta.yaml"), "version: 1.0.0\nenabled: true\npromoted_by: alice\n")

	v := dgVaultServer(t, http.StatusOK, `{"data":{"policies":["default","apply-beta"],"identity_policies":[]}}`)
	t.Setenv("VAULT_ADDR", v.url)
	t.Setenv("VAULT_TOKEN", "carrier-token")
	t.Setenv("VAULT_TOKEN_FILE", "")

	if err := deployerGate(t, repo, "beta"); err != nil {
		t.Fatalf("les deux contrats sont portés par le bon groupe, got %v", err)
	}
	if got := v.calls.Load(); got != 1 {
		t.Errorf("lookup-self calls = %d, want 1 (un seul par run)", got)
	}
}
