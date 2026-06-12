package cmd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/spf13/cobra"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/keycloak"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/output"
)

// mustBareJSON asserts the json-mode stdout contract: one JSON document, no
// human narration mixed in, and unmarshals it into v.
func mustBareJSON(t *testing.T, stdout string, v any) {
	t.Helper()
	trimmed := strings.TrimSpace(stdout)
	if !strings.HasPrefix(trimmed, "{") || !strings.HasSuffix(trimmed, "}") {
		t.Fatalf("stdout is not a bare JSON document:\n%s", stdout)
	}
	if err := json.Unmarshal([]byte(trimmed), v); err != nil {
		t.Fatalf("stdout is not valid JSON: %v\n%s", err, stdout)
	}
}

func TestRunApply_JSONSuccessAndFailureTargets(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-ok, type: faketgt, adminUrl: http://a}
  - {name: gw-bad, type: faketgt, adminUrl: http://b, credentials: {behavior: fail-publish}}
`)
	stdout, stderr, err := runDispatchFormat(t, runApply, p, "json")
	if err == nil {
		t.Fatalf("apply must still exit non-zero on partial failure in json mode")
	}
	var report output.PublishReport
	mustBareJSON(t, stdout, &report)

	if report.OK {
		t.Errorf("report.OK = true, want false (one target failed)")
	}
	if len(report.Targets) != 2 {
		t.Fatalf("len(targets) = %d, want 2", len(report.Targets))
	}
	ok := report.Targets[0]
	if ok.Gateway != "gw-ok" || ok.Type != "faketgt" || ok.APIID != "id-gw-ok" ||
		ok.InvocationURL != "http://gw-ok/accounts-read/v1" || !ok.Published || !ok.Created || ok.Error != "" {
		t.Errorf("success target lost information: %+v", ok)
	}
	bad := report.Targets[1]
	if bad.Gateway != "gw-bad" || !strings.Contains(bad.Error, "synthetic publish error") {
		t.Errorf("failed target = %+v, want gw-bad + publish error", bad)
	}
	// Human narration (header, per-gateway progress, summary) moved to stderr.
	if !strings.Contains(stderr, "Define Once → Expose Everywhere") ||
		!strings.Contains(stderr, "1/2 gateways published from one contract") {
		t.Errorf("apply narration should be on stderr:\n%s", stderr)
	}
}

func TestRunGet_JSONFederatedCatalog(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-full, type: faketgt, adminUrl: http://a, credentials: {behavior: list-match}}
  - {name: gw-empty, type: faketgt, adminUrl: http://b}
  - {name: gw-down, type: faketgt, adminUrl: http://c, credentials: {behavior: fail-list}}
`)
	stdout, _, err := runDispatchFormat(t, runGet, p, "json")
	if err == nil {
		t.Fatalf("get must still exit non-zero when a gateway fails to list")
	}
	var report output.ListReport
	mustBareJSON(t, stdout, &report)

	if report.OK {
		t.Errorf("report.OK = true, want false (one gateway down)")
	}
	if len(report.Targets) != 3 {
		t.Fatalf("len(targets) = %d, want 3", len(report.Targets))
	}
	full := report.Targets[0]
	if len(full.APIs) != 1 || full.APIs[0].Name != "accounts-read-api" ||
		full.APIs[0].Version != "1.0.0" || full.APIs[0].BasePath != "/accounts-read/v1" {
		t.Errorf("gw-full catalog lost information: %+v", full)
	}
	if empty := report.Targets[1]; empty.APIs == nil || len(empty.APIs) != 0 || empty.Error != "" {
		t.Errorf("gw-empty should have an empty (non-nil) apis array: %+v", empty)
	}
	if down := report.Targets[2]; !strings.Contains(down.Error, "synthetic list error") {
		t.Errorf("gw-down should carry the list error: %+v", down)
	}
}

func TestRunSubscribe_JSONCarriesNoSecrets(t *testing.T) {
	withFakeKeycloak(t, func(keycloak.Config) (string, string, error) {
		return "cid-banking", "super-secret-material", nil
	})
	p := writeFederation(t, keycloakBlock+`targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
  - {name: gw-bad, type: faketgt, adminUrl: http://b, credentials: {behavior: fail-consumer}}
`)
	stdout, stderr, err := runDispatchFormat(t, runSubscribe, p, "json")
	if err == nil {
		t.Fatalf("subscribe must still exit non-zero on partial failure in json mode")
	}
	var report output.ConsumerReport
	mustBareJSON(t, stdout, &report)

	if report.OK {
		t.Errorf("report.OK = true, want false")
	}
	if report.ClientID != "cid-banking" {
		t.Errorf("client_id = %q, want cid-banking", report.ClientID)
	}
	if report.CredentialsFile != credentialsFile {
		t.Errorf("credentials_file = %q, want %q", report.CredentialsFile, credentialsFile)
	}
	if len(report.Targets) != 2 {
		t.Fatalf("len(targets) = %d, want 2", len(report.Targets))
	}
	okT := report.Targets[0]
	if okT.ConsumerID != "c-gw-a" || !okT.CredentialIssued || okT.Error != "" {
		t.Errorf("success target lost information: %+v", okT)
	}
	if badT := report.Targets[1]; !strings.Contains(badT.Error, "synthetic consumer error") {
		t.Errorf("failed target = %+v, want consumer error", badT)
	}

	// SECURITY: neither the Keycloak client secret nor the gateway data-plane
	// key (fake issues "k-gw-a") may appear on stdout OR stderr — only in the
	// 0600 credentials file.
	for _, secret := range []string{"super-secret-material", "k-gw-a"} {
		if strings.Contains(stdout, secret) {
			t.Errorf("stdout leaks secret %q:\n%s", secret, stdout)
		}
		if strings.Contains(stderr, secret) {
			t.Errorf("stderr leaks secret %q:\n%s", secret, stderr)
		}
	}
}

// Table mode must be untouched by the json work: stdout carries the table and
// the narration exactly as before, stderr stays empty.
func TestRunApply_TableModeKeepsStdoutShape(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	stdout, stderr, err := runDispatchFormat(t, runApply, p, "table")
	if err != nil {
		t.Fatalf("runApply: %v", err)
	}
	if !strings.Contains(stdout, "GATEWAY") || !strings.Contains(stdout, "1/1 gateways published") {
		t.Errorf("table-mode stdout lost the table/summary:\n%s", stdout)
	}
	if stderr != "" {
		t.Errorf("table mode must not write to stderr, got:\n%s", stderr)
	}
}

func TestUnknownOutputFormatIsRejected(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	for _, fn := range []func(*cobra.Command, []string) error{runApply, runGet, runSubscribe, runPlan} {
		if _, _, err := runDispatchFormat(t, fn, p, "yaml"); err == nil ||
			!strings.Contains(err.Error(), `unsupported output format "yaml"`) {
			t.Errorf("err = %v, want unsupported-format error", err)
		}
	}
}
