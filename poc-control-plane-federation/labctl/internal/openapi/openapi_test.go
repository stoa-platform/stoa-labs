package openapi

import (
	"os"
	"path/filepath"
	"testing"
)

// writeContract writes an OpenAPI doc to a temp dir and returns its path.
func writeContract(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "contract.yaml")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatalf("write contract: %v", err)
	}
	return p
}

// When servers[].url carries a path, BasePath is preserved verbatim (with /v1).
func TestLoad_BasePathFromServer(t *testing.T) {
	p := writeContract(t, `
openapi: 3.0.0
info:
  title: Accounts Read API
  version: 1.0.0
servers:
  - url: /accounts-read/v1
paths:
  /accounts:
    get: {}
`)
	api, err := Load(p, "accounts-read", "")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if api.BasePath != "/accounts-read/v1" {
		t.Errorf("BasePath = %q, want /accounts-read/v1", api.BasePath)
	}
}

// Regression: with NO servers[].url the fallback must match the documented
// /<name>/v<major> convention (previously emitted /<name> with no version),
// keeping the public context consistent with the server-derived path.
func TestLoad_BasePathFallbackHasVersion(t *testing.T) {
	p := writeContract(t, `
openapi: 3.0.0
info:
  title: Accounts Read API
  version: 2.3.4
paths:
  /accounts:
    get: {}
`)
	api, err := Load(p, "accounts-read", "")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if api.BasePath != "/accounts-read/v2" {
		t.Errorf("fallback BasePath = %q, want /accounts-read/v2 (comment/code must agree)", api.BasePath)
	}
}

// The default version (1.0.0) yields /v1 in the fallback.
func TestLoad_BasePathFallbackDefaultVersion(t *testing.T) {
	p := writeContract(t, `
openapi: 3.0.0
info:
  title: Accounts Read API
paths:
  /accounts:
    get: {}
`)
	api, err := Load(p, "accounts-read", "")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if api.Version != "1.0.0" {
		t.Errorf("Version = %q, want default 1.0.0", api.Version)
	}
	if api.BasePath != "/accounts-read/v1" {
		t.Errorf("fallback BasePath = %q, want /accounts-read/v1", api.BasePath)
	}
}

// SpecPath must echo the path passed to Load (used by Backstage $text).
func TestLoad_SpecPathEcho(t *testing.T) {
	p := writeContract(t, `
openapi: 3.0.0
info:
  title: X
paths: {}
`)
	api, err := Load(p, "", "")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if api.SpecPath != p {
		t.Errorf("SpecPath = %q, want %q", api.SpecPath, p)
	}
}

func TestMajorOf(t *testing.T) {
	cases := map[string]string{
		"1.0.0": "1",
		"2.3.4": "2",
		"10.1":  "10",
		"3":     "3",
		"":      "1",
		"  ":    "1",
		" 4.2 ": "4",
		".5":    "1", // no leading numeric component before the dot
		"v":     "v", // non-numeric but non-empty: returned as-is (defaulted upstream)
	}
	for in, want := range cases {
		if got := majorOf(in); got != want {
			t.Errorf("majorOf(%q) = %q, want %q", in, got, want)
		}
	}
}
