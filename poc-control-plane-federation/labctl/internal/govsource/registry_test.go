package govsource

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const sampleRegistry = `apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: accounts-team, tenant: banking-demo,  api: accounts-read, classification: VH, exposure: external}
  - {owner: payments-team, tenant: payments-team, api: payments-read, classification: H,  exposure: internal}
`

func writeRegistry(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "classifications.yaml")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	return p
}

func TestLoadAndLookup(t *testing.T) {
	reg, err := Load(writeRegistry(t, sampleRegistry))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	e, ok := reg.Lookup("accounts-team", "accounts-read")
	if !ok {
		t.Fatal("accounts-read not found")
	}
	if e.Classification != "VH" || e.Exposure != "external" || e.Tenant != "banking-demo" {
		t.Errorf("entry = %+v", e)
	}
	e, ok = reg.Lookup("payments-team", "payments-read")
	if !ok || e.Classification != "H" || e.Exposure != "internal" {
		t.Errorf("payments entry = %+v ok=%v", e, ok)
	}
}

// The lookup is scoped to the OWNER: a project cannot borrow another project's
// row by renaming its api (the B1 anti-spoof anchor).
func TestLookup_OwnerScoped(t *testing.T) {
	reg, _ := Load(writeRegistry(t, sampleRegistry))
	// accounts-team pointing at payments-read → not owned → not found.
	if _, ok := reg.Lookup("accounts-team", "payments-read"); ok {
		t.Fatal("accounts-team must NOT resolve payments-read (owner-scoped)")
	}
	// Unknown owner → not found.
	if _, ok := reg.Lookup("rogue-team", "accounts-read"); ok {
		t.Fatal("unknown owner must not resolve")
	}
}

// Load is fail-closed: a missing/unparseable source is a hard error, never a
// silent empty registry (review S1).
func TestLoad_FailClosed(t *testing.T) {
	if _, err := Load(filepath.Join(t.TempDir(), "nope.yaml")); err == nil {
		t.Fatal("missing file should error")
	}
	bad := writeRegistry(t, "classifications: [ this is : not yaml")
	if _, err := Load(bad); err == nil {
		t.Fatal("unparseable file should error")
	}
}

// The AUTHORITATIVE registry is validated at load: a governance typo must fail
// LOUD here (registry-specific message), not downstream as a project-blaming
// INTEGRITY_INCONSISTENT (review S1). Covers classification/exposure typos,
// missing fields, empty registry, and duplicate keys (M4).
func TestLoad_ValidatesRegistry(t *testing.T) {
	cases := []struct{ name, body, want string }{
		{"class typo", `classifications:
  - {owner: a, tenant: t, api: x, classification: vh, exposure: internal}`, "classification"},
		{"exposure typo", `classifications:
  - {owner: a, tenant: t, api: x, classification: VH, exposure: ext}`, "exposure"},
		{"missing tenant", `classifications:
  - {owner: a, api: x, classification: VH, exposure: internal}`, "requis"},
		{"empty", `classifications: []`, "aucune entrée"},
		{"duplicate key", `classifications:
  - {owner: a, tenant: t, api: x, classification: VH, exposure: internal}
  - {owner: a, tenant: t2, api: x, classification: M, exposure: internal}`, "dupliqué"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := Load(writeRegistry(t, "apiVersion: governance.stoa.io/v1\nkind: ClassificationRegistry\n"+c.body))
			if err == nil {
				t.Fatalf("invalid registry (%s) should fail load", c.name)
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Errorf("err = %q, want substring %q", err.Error(), c.want)
			}
		})
	}
}
