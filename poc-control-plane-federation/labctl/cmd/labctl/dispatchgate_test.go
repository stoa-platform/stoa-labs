package cmd

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
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
