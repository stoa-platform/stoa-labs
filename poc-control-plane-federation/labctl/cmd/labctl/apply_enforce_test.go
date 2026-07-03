package cmd

// Apply-side enforcement gate tests (ADR-076 goal A1). The gate activates by
// DISCOVERY of an api.yaml colocated with the manifest — dispatch_test.go's
// writeFederation never writes one, which doubles as the regression proof that
// every historical flow keeps running with the gate structurally OFF (see
// TestRunApply_AllSuccess & co, unchanged).

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/output"
)

// writeUAC drops an api.yaml next to an existing manifest (activating the
// discovery-driven gate for that manifest).
func writeUAC(t *testing.T, manifestPath, body string) {
	t.Helper()
	p := filepath.Join(filepath.Dir(manifestPath), "api.yaml")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatalf("write api.yaml: %v", err)
	}
}

// The fake contract slugs to "accounts-read-api" (title "Accounts Read API").
const uacVH = `name: accounts-read-api
version: 1.0.0
tenant_id: banking-demo
classification: VH
exposure: external
status: draft
`

const uacH = `name: accounts-read-api
version: 1.0.0
tenant_id: banking-demo
classification: H
status: draft
`

// A VH contract with a webmethods target that declares NONE of the bundle's
// knobs: the static pre-check must refuse with [INTEGRITY_UNFULFILLED] and
// dispatch must never start (the mock would fail on Health if reached — the
// error must be the gate's, not a network one).
func TestRunApply_EnforcementUnfulfilledFailsBeforeDispatch(t *testing.T) {
	p := writeFederation(t, `targets:
  - name: wm
    type: webmethods
    adminUrl: http://127.0.0.1:1
    credentials: {username: u, password: pw}
`)
	writeUAC(t, p, uacVH)
	out, err := runDispatch(t, runApply, p)
	if err == nil {
		t.Fatalf("expected INTEGRITY_UNFULFILLED, got success:\n%s", out)
	}
	if !strings.Contains(err.Error(), "INTEGRITY_UNFULFILLED") {
		t.Errorf("err = %v, want [INTEGRITY_UNFULFILLED]", err)
	}
	// Nothing dispatched: no adapter/health error may appear.
	if strings.Contains(out, "unreachable") || strings.Contains(out, "publish:") {
		t.Errorf("dispatch ran despite the failed pre-check:\n%s", out)
	}
	for _, leg := range []string{"oauth2", "mtls", "rate-limit"} {
		if !strings.Contains(out, leg) {
			t.Errorf("pre-check output should name the %s violation:\n%s", leg, out)
		}
	}
}

// An adapter WITHOUT the EnforcementVerifier capability under an active gate is
// unverifiable — refused with [ENFORCEMENT_UNCONFIRMED] (fail-closed, never
// silently trusted). The publish itself still happened (pipeline-level gate).
func TestRunApply_EnforcementUnverifiableAdapterFails(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	writeUAC(t, p, uacH)
	out, err := runDispatch(t, runApply, p)
	if err == nil {
		t.Fatalf("expected ENFORCEMENT_UNCONFIRMED, got success:\n%s", out)
	}
	if !strings.Contains(out+err.Error(), "ENFORCEMENT_UNCONFIRMED") {
		t.Errorf("err/out should carry [ENFORCEMENT_UNCONFIRMED]: %v\n%s", err, out)
	}
	if !strings.Contains(out, "read-back d'enforcement non implémenté") {
		t.Errorf("output should explain the adapter has no read-back:\n%s", out)
	}
}

// A verifier reporting a missing required leg fails the run; the verdict table
// is printed in full (never overclaim).
func TestRunApply_EnforcementReadBackDriftFails(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a, credentials: {behavior: verify-missing}}
`)
	writeUAC(t, p, uacVH)
	out, err := runDispatch(t, runApply, p)
	if err == nil {
		t.Fatalf("expected ENFORCEMENT_UNCONFIRMED on mtls drift, got success:\n%s", out)
	}
	if !strings.Contains(out+err.Error(), "ENFORCEMENT_UNCONFIRMED") {
		t.Errorf("missing [ENFORCEMENT_UNCONFIRMED]: %v", err)
	}
	if !strings.Contains(out, "mtls=missing") && !strings.Contains(out, "mtls") {
		t.Errorf("output should name the failing leg:\n%s", out)
	}
}

// The conforming path: verifier confirms every leg, apply exits 0 and prints
// the full verdict table.
func TestRunApply_EnforcementConfirmedPasses(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a, credentials: {behavior: verify-ok}}
`)
	writeUAC(t, p, uacVH)
	out, err := runDispatch(t, runApply, p)
	if err != nil {
		t.Fatalf("conforming enforcement failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Enforcement (read-back") {
		t.Errorf("verdict table missing:\n%s", out)
	}
	for _, leg := range []string{"oauth2", "mtls", "rate-limit", "audit-log", "ip-allowlist"} {
		if !strings.Contains(out, leg) {
			t.Errorf("verdict table should list %s:\n%s", leg, out)
		}
	}
	if !strings.Contains(out, "1/1 gateways published") {
		t.Errorf("summary missing:\n%s", out)
	}
}

// JSON mode: stdout stays the bare document (CI contract), narration +
// verdicts go to stderr, and the report carries the additive enforcement
// block.
func TestRunApply_EnforcementJSONAdditive(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a, credentials: {behavior: verify-ok}}
`)
	writeUAC(t, p, uacVH)
	stdout, stderr, err := runDispatchFormat(t, runApply, p, "json")
	if err != nil {
		t.Fatalf("json apply: %v\n%s", err, stderr)
	}
	var rep output.PublishReport
	if uerr := json.Unmarshal([]byte(stdout), &rep); uerr != nil {
		t.Fatalf("stdout is not bare JSON: %v\n%s", uerr, stdout)
	}
	if !rep.OK || len(rep.Targets) != 1 {
		t.Fatalf("report = %+v", rep)
	}
	if len(rep.Targets[0].Enforcement) == 0 {
		t.Fatalf("enforcement block missing from JSON report: %s", stdout)
	}
	if !strings.Contains(stderr, "Enforcement (read-back") {
		t.Errorf("verdict table must go to stderr in json mode:\n%s", stderr)
	}
	if strings.Contains(stdout, "Enforcement (read-back") {
		t.Errorf("verdict table leaked into stdout:\n%s", stdout)
	}
}

// A colocated contract whose name does not match the published API is refused
// (incoherent colocation, fail-closed).
func TestRunApply_UACNameMismatchFails(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	writeUAC(t, p, strings.Replace(uacVH, "accounts-read-api", "other-api", 1))
	out, err := runDispatch(t, runApply, p)
	if err == nil {
		t.Fatalf("expected name-mismatch failure, got success:\n%s", out)
	}
	if !strings.Contains(err.Error(), "INTEGRITY_UNFULFILLED") {
		t.Errorf("err = %v, want [INTEGRITY_UNFULFILLED]", err)
	}
}

// An underivable classification refuses the run with the SAME code as the
// validate-side gate.
func TestRunApply_UACUnderivableFails(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	writeUAC(t, p, strings.Replace(uacVH, "classification: VH", "classification: VVH", 1))
	_, err := runDispatch(t, runApply, p)
	if err == nil || !strings.Contains(err.Error(), "INTEGRITY_INCONSISTENT") {
		t.Fatalf("err = %v, want [INTEGRITY_INCONSISTENT]", err)
	}
}

// --uac points at a contract elsewhere (no colocation needed) and forces the
// gate ON.
func TestRunApply_ExplicitUACFlag(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a, credentials: {behavior: verify-ok}}
`)
	alt := filepath.Join(t.TempDir(), "contract-uac.yaml")
	if err := os.WriteFile(alt, []byte(uacH), 0o600); err != nil {
		t.Fatalf("write alt uac: %v", err)
	}
	prev := uacFlag
	uacFlag = alt
	t.Cleanup(func() { uacFlag = prev })

	out, err := runDispatch(t, runApply, p)
	if err != nil {
		t.Fatalf("--uac apply failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Enforcement ADR-076") {
		t.Errorf("gate did not activate via --uac:\n%s", out)
	}
}
