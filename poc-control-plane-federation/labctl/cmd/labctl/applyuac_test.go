package cmd

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// writeGovRepo materialises a governance repo (rel-path -> content) in a temp
// dir and returns its root.
func writeGovRepo(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for rel, body := range files {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", p, err)
		}
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatalf("write %s: %v", p, err)
		}
	}
	return root
}

// writeUACManifest writes a targets.yaml whose contract points at a file that
// DOES NOT EXIST: apply-uac must reuse the manifest only for its gateway fleet
// and never touch the OpenAPI contract path.
func writeUACManifest(t *testing.T, targetsBody string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "targets.yaml")
	body := "contract: does-not-exist.yaml\nbackendUrl: http://ignored:1\n" + targetsBody
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	return p
}

// runApplyUACFormat sets apply-uac's own flags around the shared dispatch
// harness and restores them after the run.
func runApplyUACFormat(t *testing.T, repo, env, manifestPath, format string) (stdout, stderr string, err error) {
	t.Helper()
	prevRepo, prevEnv := uacRepoFlag, uacEnvFlag
	uacRepoFlag, uacEnvFlag = repo, env
	t.Cleanup(func() { uacRepoFlag, uacEnvFlag = prevRepo, prevEnv })
	return runDispatchFormat(t, runApplyUAC, manifestPath, format)
}

const uacAccountsRead = `name: accounts-read
version: 1.0.0
tenant_id: banking-demo
status: published
endpoints:
  - path: /accounts
    methods: [GET]
    backend_url: http://backend-a:8080/accounts
  - path: /accounts/{iban}/balance
    methods: [GET]
    backend_url: http://backend-a:8080/accounts
`

// uacPayments declares TWO DISTINCT backends — the multi-backend warning path.
const uacPayments = `name: payments-initiation
version: 0.3.0
tenant_id: banking-demo
status: published
endpoints:
  - path: /payments
    methods: [POST]
    backend_url: http://backend-a:8080/payments
  - path: /payments/{id}
    methods: [DELETE]
    backend_url: http://backend-b:9999/payments
`

const uacEnabledDeploy = "version: 1.0.0\nenabled: true\npromoted_by: alice\nmessage: ok\n"
const uacDisabledDeploy = "version: 1.0.0\nenabled: false\npromoted_by: alice\nmessage: held\n"

// uacStandardRepo: one projectable API (dev), one draft (must skip even with an
// enabled deploy), one published API whose only deploy is disabled (must skip).
func uacStandardRepo(t *testing.T) string {
	t.Helper()
	return writeGovRepo(t, map[string]string{
		"tenants/banking-demo/apis/accounts-read/api.yaml":        uacAccountsRead,
		"tenants/banking-demo/apis/accounts-read/deploy.dev.yaml": uacEnabledDeploy,
		"tenants/banking-demo/apis/drafty/api.yaml":               "name: drafty\nversion: 0.1.0\nstatus: draft\n",
		"tenants/banking-demo/apis/drafty/deploy.dev.yaml":        uacEnabledDeploy,
		"tenants/banking-demo/apis/held-back/api.yaml": "name: held-back\nversion: 1.0.0\nstatus: published\n" +
			"endpoints: [{path: /x, methods: [GET], backend_url: http://b:1}]\n",
		"tenants/banking-demo/apis/held-back/deploy.dev.yaml": uacDisabledDeploy,
	})
}

func TestRunApplyUAC_ProjectsPublishedSkipsDraftAndDisabled(t *testing.T) {
	repo := uacStandardRepo(t)
	p := writeUACManifest(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
  - {name: gw-b, type: faketgt, adminUrl: http://b}
`)
	out, _, err := runApplyUACFormat(t, repo, "any", p, "table")
	if err != nil {
		t.Fatalf("runApplyUAC: unexpected error: %v\n%s", err, out)
	}
	if !strings.Contains(out, "banking-demo/accounts-read v1.0.0 → /accounts-read/v1 (envs: dev)") {
		t.Errorf("output missing the projected API header:\n%s", out)
	}
	if !strings.Contains(out, "drafty skipped: status=draft") {
		t.Errorf("draft must be skipped with an explicit line:\n%s", out)
	}
	if !strings.Contains(out, "held-back skipped: no enabled deploy in any environment") {
		t.Errorf("disabled deploy must be skipped with an explicit line:\n%s", out)
	}
	if !strings.Contains(out, "2/2 gateway publications from 1 projected UAC contracts (2 skipped).") {
		t.Errorf("output missing the summary:\n%s", out)
	}
	// The combined table carries the governance coordinates.
	for _, want := range []string{"TENANT", "API", "GATEWAY", "gw-a", "gw-b", "http://gw-a/accounts-read/v1"} {
		if !strings.Contains(out, want) {
			t.Errorf("table missing %q:\n%s", want, out)
		}
	}
	// apply-uac never writes the Backstage entity (no on-disk OpenAPI contract).
	if _, statErr := os.Stat(filepath.Join(filepath.Dir(p), "catalog-info.yaml")); statErr == nil {
		t.Errorf("apply-uac must not write catalog-info.yaml")
	}
}

func TestRunApplyUAC_EnvGating(t *testing.T) {
	repo := writeGovRepo(t, map[string]string{
		"tenants/banking-demo/apis/accounts-read/api.yaml":                     uacAccountsRead,
		"tenants/banking-demo/apis/accounts-read/deploy.dev.yaml":              uacEnabledDeploy,
		"tenants/banking-demo/apis/payments-initiation/api.yaml":               uacPayments,
		"tenants/banking-demo/apis/payments-initiation/deploy.production.yaml": uacEnabledDeploy,
	})
	manifest := `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`
	cases := []struct {
		env           string
		wantProjected string
		wantSkipped   string
		wantSummary   string
	}{
		{"dev", "accounts-read v1.0.0", "payments-initiation skipped: no enabled deploy for env dev", "1/1 gateway publications from 1 projected UAC contracts (1 skipped)."},
		{"production", "payments-initiation v0.3.0 → /payments-initiation/v0 (envs: production)", "accounts-read skipped: no enabled deploy for env production", "1/1 gateway publications from 1 projected UAC contracts (1 skipped)."},
		{"any", "accounts-read v1.0.0", "", "2/2 gateway publications from 2 projected UAC contracts (0 skipped)."},
	}
	for _, tc := range cases {
		t.Run(tc.env, func(t *testing.T) {
			p := writeUACManifest(t, manifest)
			out, _, err := runApplyUACFormat(t, repo, tc.env, p, "table")
			if err != nil {
				t.Fatalf("runApplyUAC(env=%s): %v\n%s", tc.env, err, out)
			}
			if !strings.Contains(out, tc.wantProjected) {
				t.Errorf("env=%s: output missing projected %q:\n%s", tc.env, tc.wantProjected, out)
			}
			if tc.wantSkipped != "" && !strings.Contains(out, tc.wantSkipped) {
				t.Errorf("env=%s: output missing skip %q:\n%s", tc.env, tc.wantSkipped, out)
			}
			if !strings.Contains(out, tc.wantSummary) {
				t.Errorf("env=%s: output missing summary %q:\n%s", tc.env, tc.wantSummary, out)
			}
		})
	}
}

func TestRunApplyUAC_MultiBackendWarningOnStderr(t *testing.T) {
	repo := writeGovRepo(t, map[string]string{
		"tenants/banking-demo/apis/payments-initiation/api.yaml":        uacPayments,
		"tenants/banking-demo/apis/payments-initiation/deploy.dev.yaml": uacEnabledDeploy,
	})
	p := writeUACManifest(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	out, stderr, err := runApplyUACFormat(t, repo, "any", p, "table")
	if err != nil {
		t.Fatalf("runApplyUAC: %v\n%s", err, out)
	}
	if !strings.Contains(stderr, "multiple distinct backend_urls") ||
		!strings.Contains(stderr, "taking the first (http://backend-a:8080/payments)") {
		t.Errorf("multi-backend warning must land on stderr:\n%s", stderr)
	}
	if strings.Contains(out, "multiple distinct backend_urls") {
		t.Errorf("warning must not corrupt the table on stdout:\n%s", out)
	}
}

func TestRunApplyUAC_VersionDriftWarningOnStderr(t *testing.T) {
	repo := writeGovRepo(t, map[string]string{
		"tenants/banking-demo/apis/accounts-read/api.yaml":        uacAccountsRead,
		"tenants/banking-demo/apis/accounts-read/deploy.dev.yaml": "version: 0.9.0\nenabled: true\npromoted_by: alice\nmessage: stale pin\n",
	})
	p := writeUACManifest(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	_, stderr, err := runApplyUACFormat(t, repo, "any", p, "table")
	if err != nil {
		t.Fatalf("runApplyUAC: %v", err)
	}
	if !strings.Contains(stderr, "deploy.dev pins version 0.9.0 but the contract is 1.0.0") {
		t.Errorf("version drift warning must land on stderr:\n%s", stderr)
	}
}

func TestRunApplyUAC_JSONPartialFailureAcrossAPIs(t *testing.T) {
	repo := writeGovRepo(t, map[string]string{
		"tenants/banking-demo/apis/accounts-read/api.yaml":                  uacAccountsRead,
		"tenants/banking-demo/apis/accounts-read/deploy.dev.yaml":           uacEnabledDeploy,
		"tenants/banking-demo/apis/drafty/api.yaml":                         "name: drafty\nstatus: draft\n",
		"tenants/banking-demo/apis/payments-initiation/api.yaml":            uacPayments,
		"tenants/banking-demo/apis/payments-initiation/deploy.staging.yaml": uacEnabledDeploy,
	})
	p := writeUACManifest(t, `targets:
  - {name: gw-ok, type: faketgt, adminUrl: http://a}
  - {name: gw-bad, type: faketgt, adminUrl: http://b, credentials: {behavior: fail-publish}}
`)
	stdout, stderr, err := runApplyUACFormat(t, repo, "any", p, "json")
	if err == nil || !strings.Contains(err.Error(), "2/4 gateways failed to publish") {
		t.Fatalf("err = %v, want '2/4 gateways failed to publish'", err)
	}
	var report uacReport
	mustBareJSON(t, stdout, &report)

	if report.OK {
		t.Errorf("report.OK = true, want false")
	}
	if report.Env != "any" {
		t.Errorf("report.Env = %q, want any", report.Env)
	}
	if len(report.APIs) != 3 {
		t.Fatalf("len(apis) = %d, want 3 (2 projected + 1 skipped)", len(report.APIs))
	}

	acc := report.APIs[0]
	if acc.Tenant != "banking-demo" || acc.API != "accounts-read" ||
		acc.Version != "1.0.0" || acc.BasePath != "/accounts-read/v1" ||
		len(acc.Envs) != 1 || acc.Envs[0] != "dev" || acc.Skipped {
		t.Errorf("accounts-read entry lost governance coordinates: %+v", acc)
	}
	if acc.OK || len(acc.Targets) != 2 {
		t.Fatalf("accounts-read embedded report = ok:%v targets:%d, want ok:false 2 targets", acc.OK, len(acc.Targets))
	}
	// The embedded per-target object is the UNCHANGED apply contract.
	okT := acc.Targets[0]
	if okT.Gateway != "gw-ok" || okT.Type != "faketgt" || okT.APIID != "id-gw-ok" ||
		okT.InvocationURL != "http://gw-ok/accounts-read/v1" || !okT.Published || !okT.Created || okT.Error != "" {
		t.Errorf("success target lost information: %+v", okT)
	}
	if badT := acc.Targets[1]; badT.Gateway != "gw-bad" || !strings.Contains(badT.Error, "synthetic publish error") {
		t.Errorf("failed target = %+v, want gw-bad + publish error", badT)
	}

	if drafty := report.APIs[1]; drafty.API != "drafty" || !drafty.Skipped ||
		!strings.Contains(drafty.Reason, "status=draft") || !drafty.OK || drafty.Targets == nil || len(drafty.Targets) != 0 {
		t.Errorf("drafty entry = %+v, want skipped with reason and empty (non-null) targets", drafty)
	}
	if pay := report.APIs[2]; pay.API != "payments-initiation" || pay.BasePath != "/payments-initiation/v0" ||
		len(pay.Envs) != 1 || pay.Envs[0] != "staging" {
		t.Errorf("payments entry = %+v, want staging projection at /payments-initiation/v0", pay)
	}

	// Narration and warnings on stderr; stdout carried the document only.
	if !strings.Contains(stderr, "Governance → Federation") ||
		!strings.Contains(stderr, "multiple distinct backend_urls") {
		t.Errorf("json-mode narration/warnings should be on stderr:\n%s", stderr)
	}
}

func TestRunApplyUAC_FlagValidation(t *testing.T) {
	p := writeUACManifest(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	if _, _, err := runApplyUACFormat(t, "", "any", p, "table"); err == nil ||
		!strings.Contains(err.Error(), "--repo") {
		t.Errorf("err = %v, want missing --repo error", err)
	}
	repo := uacStandardRepo(t)
	if _, _, err := runApplyUACFormat(t, repo, "prod", p, "table"); err == nil ||
		!strings.Contains(err.Error(), `unsupported --env "prod"`) {
		t.Errorf("err = %v, want unsupported --env error", err)
	}
	if _, _, err := runApplyUACFormat(t, repo, "any", p, "yaml"); err == nil ||
		!strings.Contains(err.Error(), `unsupported output format "yaml"`) {
		t.Errorf("err = %v, want unsupported-format error", err)
	}
}

func TestRunApplyUAC_BrokenGovernanceRepoFailsLoudly(t *testing.T) {
	repo := writeGovRepo(t, map[string]string{
		// name does not match the directory slug: identity ambiguity.
		"tenants/banking-demo/apis/accounts-read/api.yaml": "name: something-else\nstatus: published\nendpoints: [{path: /x, methods: [GET], backend_url: http://b}]\n",
	})
	p := writeUACManifest(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	if _, _, err := runApplyUACFormat(t, repo, "any", p, "table"); err == nil ||
		!strings.Contains(err.Error(), "does not match its directory slug") {
		t.Errorf("err = %v, want slug-mismatch load error", err)
	}
}

// ---- configurable chain (environments.yaml) + version pinning ----

// gitGov runs one git command in the governance repo fixture (hermetic
// identity, no signing).
func gitGov(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_CONFIG_SYSTEM=/dev/null",
		"GIT_COMMITTER_NAME=seed",
		"GIT_COMMITTER_EMAIL=seed@test.local",
		"GIT_AUTHOR_NAME=seed",
		"GIT_AUTHOR_EMAIL=seed@test.local",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

func TestRunApplyUAC_CustomChainEnvValidation(t *testing.T) {
	repo := writeGovRepo(t, map[string]string{
		"environments.yaml": "environments: [dev, rec, int, prod]\n",
		"tenants/banking-demo/apis/accounts-read/api.yaml":        uacAccountsRead,
		"tenants/banking-demo/apis/accounts-read/deploy.rec.yaml": uacEnabledDeploy,
	})
	p := writeUACManifest(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	// staging is not part of THIS repo's chain: dynamic message lists it.
	if _, _, err := runApplyUACFormat(t, repo, "staging", p, "table"); err == nil ||
		!strings.Contains(err.Error(), `unsupported --env "staging" (supported: dev, rec, int, prod, any)`) {
		t.Errorf("err = %v, want chain-aware unsupported --env error", err)
	}
	// rec IS part of the chain and holds the enabled deploy.
	out, _, err := runApplyUACFormat(t, repo, "rec", p, "table")
	if err != nil {
		t.Fatalf("runApplyUAC(env=rec): %v\n%s", err, out)
	}
	if !strings.Contains(out, "accounts-read v1.0.0 → /accounts-read/v1 (envs: rec)") {
		t.Errorf("rec projection missing:\n%s", out)
	}
}

func TestRunApplyUAC_BrokenChainFileFailsLoudly(t *testing.T) {
	repo := writeGovRepo(t, map[string]string{
		"environments.yaml": "environments: []\n",
		"tenants/banking-demo/apis/accounts-read/api.yaml": uacAccountsRead,
	})
	p := writeUACManifest(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	if _, _, err := runApplyUACFormat(t, repo, "any", p, "table"); err == nil ||
		!strings.Contains(err.Error(), "environments.yaml") {
		t.Errorf("err = %v, want broken environments.yaml error", err)
	}
}

// uacAccountsReadV2 is the SAME contract after a version bump on HEAD.
const uacAccountsReadV2 = `name: accounts-read
version: 2.0.0
tenant_id: banking-demo
status: published
endpoints:
  - path: /accounts
    methods: [GET]
    backend_url: http://backend-v2:8080/accounts
`

// pinnedGovRepo: a real git governance repo where api.yaml moved to 2.0.0 on
// HEAD while deploy.dev pins the 1.0.0 commit.
func pinnedGovRepo(t *testing.T) (string, string) {
	t.Helper()
	repo := writeGovRepo(t, map[string]string{
		"tenants/banking-demo/apis/accounts-read/api.yaml": uacAccountsRead,
	})
	gitGov(t, repo, "init", "-b", "main")
	gitGov(t, repo, "config", "commit.gpgsign", "false")
	gitGov(t, repo, "add", "-A")
	gitGov(t, repo, "commit", "-m", "contract v1.0.0")
	sha1 := strings.TrimSpace(gitGov(t, repo, "rev-parse", "HEAD"))

	apiPath := filepath.Join(repo, "tenants", "banking-demo", "apis", "accounts-read", "api.yaml")
	if err := os.WriteFile(apiPath, []byte(uacAccountsReadV2), 0o600); err != nil {
		t.Fatal(err)
	}
	gitGov(t, repo, "add", "-A")
	gitGov(t, repo, "commit", "-m", "contract v2.0.0")

	deploy := "version: 1.0.0\nenabled: true\npromoted_by: alice\nmessage: ok\ncommit: " + sha1 + "\n"
	if err := os.WriteFile(filepath.Join(repo, "tenants", "banking-demo", "apis", "accounts-read", "deploy.dev.yaml"),
		[]byte(deploy), 0o600); err != nil {
		t.Fatal(err)
	}
	return repo, sha1
}

func TestRunApplyUAC_ConcreteEnvProjectsPinnedVersion(t *testing.T) {
	repo, sha1 := pinnedGovRepo(t)
	p := writeUACManifest(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	out, stderr, err := runApplyUACFormat(t, repo, "dev", p, "table")
	if err != nil {
		t.Fatalf("runApplyUAC(env=dev): %v\n%s", err, out)
	}
	// The pinned SHA is narrated and the PINNED contract (v1) is projected.
	if !strings.Contains(out, "pinned: "+sha1[:7]) {
		t.Errorf("output missing the pin narration:\n%s", out)
	}
	if !strings.Contains(out, "banking-demo/accounts-read v1.0.0 → /accounts-read/v1 (envs: dev)") {
		t.Errorf("pinned v1.0.0 not projected (HEAD is 2.0.0):\n%s", out)
	}
	// The pin REPLACES the drift warning for this env.
	if strings.Contains(stderr, "pins version") {
		t.Errorf("pinned env must not warn about drift:\n%s", stderr)
	}

	// --env any stays the HEAD inventory view: v2 projected, drift warned.
	out, stderr, err = runApplyUACFormat(t, repo, "any", p, "table")
	if err != nil {
		t.Fatalf("runApplyUAC(env=any): %v\n%s", err, out)
	}
	if !strings.Contains(out, "banking-demo/accounts-read v2.0.0 → /accounts-read/v2 (envs: dev)") {
		t.Errorf("any must project HEAD:\n%s", out)
	}
	if !strings.Contains(stderr, "deploy.dev pins version 1.0.0 but the contract is 2.0.0") {
		t.Errorf("any must surface the drift warning:\n%s", stderr)
	}
}

func TestRunApplyUAC_BrokenPinFailsLoudly(t *testing.T) {
	repo, _ := pinnedGovRepo(t)
	deploy := "version: 1.0.0\nenabled: true\npromoted_by: alice\ncommit: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n"
	if err := os.WriteFile(filepath.Join(repo, "tenants", "banking-demo", "apis", "accounts-read", "deploy.dev.yaml"),
		[]byte(deploy), 0o600); err != nil {
		t.Fatal(err)
	}
	p := writeUACManifest(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	if _, _, err := runApplyUACFormat(t, repo, "dev", p, "table"); err == nil ||
		!strings.Contains(err.Error(), "pinned contract") {
		t.Errorf("err = %v, want pinned-resolution failure (fail-closed, never HEAD)", err)
	}
}
