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

// --- A5: central classification registry (anti-spoof) --------------------

// writeRegistry drops a central classification registry and points the gate at
// it for the duration of the test (flag + project identity).
func withCentral(t *testing.T, body, project string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "classifications.yaml")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatalf("write registry: %v", err)
	}
	// Hermetic (review M5): the flag wins, but clear the env twins so an ambient
	// LABCTL_PROJECT/LABCTL_CLASSIFICATION_SOURCE on the runner cannot mask an
	// intentionally-empty project (e.g. the no-identity test) or a flag-off case.
	t.Setenv("LABCTL_PROJECT", "")
	t.Setenv("LABCTL_CLASSIFICATION_SOURCE", "")
	prevSrc, prevProj := classificationSourceFlag, projectFlag
	classificationSourceFlag, projectFlag = p, project
	t.Cleanup(func() { classificationSourceFlag, projectFlag = prevSrc, prevProj })
	return p
}

const centralReg = `apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: accounts-team, tenant: banking-demo, api: accounts-read-api, classification: VH, exposure: external}
  - {owner: payments-team, tenant: payments-team, api: payments-read-api, classification: H, exposure: internal}
`

// The central classification is AUTHORITATIVE: a project api.yaml that matches
// central deploys with the governed bundle.
func TestRunApply_CentralGovernedMatches(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a, credentials: {behavior: verify-ok}}
`)
	writeUAC(t, p, uacVH) // name accounts-read-api, tenant banking-demo, VH/external
	withCentral(t, centralReg, "accounts-team")
	out, err := runDispatch(t, runApply, p)
	if err != nil {
		t.Fatalf("governed match should pass: %v\n%s", err, out)
	}
	if !strings.Contains(out, "classification=VH") {
		t.Errorf("gate should derive VH from central:\n%s", out)
	}
}

// DOWNGRADE: the project declares M while central says VH → refused
// CLASSIFICATION_SPOOFED (the anti-spoof property A5 exists for).
func TestRunApply_CentralRefusesDowngrade(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a, credentials: {behavior: verify-ok}}
`)
	writeUAC(t, p, strings.Replace(uacVH, "classification: VH\nexposure: external", "classification: M", 1))
	withCentral(t, centralReg, "accounts-team")
	_, err := runDispatch(t, runApply, p)
	if err == nil || !strings.Contains(err.Error(), "CLASSIFICATION_SPOOFED") {
		t.Fatalf("err = %v, want [CLASSIFICATION_SPOOFED]", err)
	}
}

// B1 anti-spoof: a project cannot borrow another project's weaker row. The
// api.yaml name is scoped to the injected project identity — accounts-team
// pointing at payments-read-api → UNGOVERNED (it owns no such API).
func TestRunApply_CentralRejectsRowBorrowing(t *testing.T) {
	p := writeFederation(t, `contract: contract.yaml
name: payments-read-api
targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a, credentials: {behavior: verify-ok}}
`)
	// api.yaml claims to be payments-read-api / H (matching payments' central row)…
	writeUAC(t, p, `name: payments-read-api
version: 1.0.0
tenant_id: payments-team
classification: H
status: draft
`)
	// …but the pipeline injects the REAL owner: accounts-team.
	withCentral(t, centralReg, "accounts-team")
	_, err := runDispatch(t, runApply, p)
	if err == nil || !strings.Contains(err.Error(), "CLASSIFICATION_UNGOVERNED") {
		t.Fatalf("err = %v, want [CLASSIFICATION_UNGOVERNED] (accounts-team owns no payments-read-api)", err)
	}
}

// The tenant is governed too: lying about tenant_id → SPOOFED.
func TestRunApply_CentralRefusesTenantSpoof(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a, credentials: {behavior: verify-ok}}
`)
	writeUAC(t, p, strings.Replace(uacVH, "tenant_id: banking-demo", "tenant_id: payments-team", 1))
	withCentral(t, centralReg, "accounts-team")
	_, err := runDispatch(t, runApply, p)
	if err == nil || !strings.Contains(err.Error(), "CLASSIFICATION_SPOOFED") {
		t.Fatalf("err = %v, want [CLASSIFICATION_SPOOFED] (tenant mismatch)", err)
	}
}

// An API absent from the registry cannot self-classify → UNGOVERNED.
func TestRunApply_CentralUngovernedAPI(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a, credentials: {behavior: verify-ok}}
`)
	writeUAC(t, p, uacVH)
	// registry without accounts-read-api for this owner
	withCentral(t, `apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: other-team, tenant: t, api: other-api, classification: M, exposure: internal}
`, "accounts-team")
	_, err := runDispatch(t, runApply, p)
	if err == nil || !strings.Contains(err.Error(), "CLASSIFICATION_UNGOVERNED") {
		t.Fatalf("err = %v, want [CLASSIFICATION_UNGOVERNED]", err)
	}
}

// Over-declaration (project stronger than central) is harmless: it warns and
// derives from central, does not block.
func TestRunApply_CentralOverDeclarationWarns(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a, credentials: {behavior: verify-ok}}
`)
	// api.yaml VH/external, but central says accounts-read-api is only H →
	// project over-declared: derives from central (H), warns, does not block.
	writeUAC(t, p, uacVH)
	withCentral(t, `apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: accounts-team, tenant: banking-demo, api: accounts-read-api, classification: H, exposure: external}
`, "accounts-team")
	out, err := runDispatch(t, runApply, p)
	if err != nil {
		t.Fatalf("over-declaration should pass (derives from central): %v\n%s", err, out)
	}
	if !strings.Contains(out, "sur-provisionné") {
		t.Errorf("should warn about over-declaration:\n%s", out)
	}
	if !strings.Contains(out, "classification=H") {
		t.Errorf("bundle should derive from CENTRAL H, not project VH:\n%s", out)
	}
}

// Source configured but no project identity → fail-closed UNGOVERNED (no
// governed lookup without the non-editable identity).
func TestRunApply_CentralNoProjectIdentityFails(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a, credentials: {behavior: verify-ok}}
`)
	writeUAC(t, p, uacVH)
	withCentral(t, centralReg, "") // empty project identity
	_, err := runDispatch(t, runApply, p)
	if err == nil || !strings.Contains(err.Error(), "CLASSIFICATION_UNGOVERNED") {
		t.Fatalf("err = %v, want [CLASSIFICATION_UNGOVERNED] (no project identity)", err)
	}
}

// Non-regression: with NO central source, the gate is strictly A1 (project
// classification drives). The historical VH path still passes.
func TestRunApply_NoCentralSourceIsStrictA1(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a, credentials: {behavior: verify-ok}}
`)
	writeUAC(t, p, uacVH)
	// classificationSourceFlag/projectFlag stay empty (no withCentral)
	out, err := runDispatch(t, runApply, p)
	if err != nil {
		t.Fatalf("A1 path (no central) should pass: %v\n%s", err, out)
	}
	if !strings.Contains(out, "classification=VH") {
		t.Errorf("A1 uses project-declared VH:\n%s", out)
	}
}
