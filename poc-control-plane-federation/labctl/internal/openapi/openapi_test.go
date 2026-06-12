package openapi

import (
	"os"
	"path/filepath"
	"strings"
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

// Error paths: a missing file, malformed YAML, and a title-less doc are exactly
// the operator mistakes a demo will hit, and the messages are what the operator
// reads — so they must be exercised (parity with keycloak/backstage).
func TestLoad_ErrorPaths(t *testing.T) {
	t.Run("missing file", func(t *testing.T) {
		_, err := Load(filepath.Join(t.TempDir(), "does-not-exist.yaml"), "", "")
		if err == nil || !strings.Contains(err.Error(), "read contract") {
			t.Fatalf("err = %v, want 'read contract ...'", err)
		}
	})
	t.Run("malformed yaml", func(t *testing.T) {
		p := writeContract(t, "{{ not: valid: yaml")
		_, err := Load(p, "", "")
		if err == nil || !strings.Contains(err.Error(), "parse OpenAPI") {
			t.Fatalf("err = %v, want 'parse OpenAPI ...'", err)
		}
	})
	t.Run("missing info.title", func(t *testing.T) {
		p := writeContract(t, "openapi: 3.0.0\npaths: {}\n")
		_, err := Load(p, "", "")
		if err == nil || !strings.Contains(err.Error(), "info.title is required") {
			t.Fatalf("err = %v, want 'info.title is required'", err)
		}
	})
}

// Determinism: endpoints must come back sorted by Path (and methods sorted)
// regardless of map iteration order, because adapters derive stable resource ids
// from the endpoint index. Multiple paths + multiple verbs make a shuffle
// observable. Loading the same contract repeatedly must yield identical order.
func TestLoad_EndpointsDeterministicOrder(t *testing.T) {
	p := writeContract(t, `
openapi: 3.0.0
info:
  title: Accounts Read API
  version: 1.0.0
servers:
  - url: /accounts-read/v1
paths:
  /transactions:
    get: {}
  /accounts:
    post: {}
    get: {}
  /accounts/{id}:
    get: {}
`)
	const runs = 20
	var want []string
	for i := 0; i < runs; i++ {
		api, err := Load(p, "accounts-read", "")
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		got := make([]string, len(api.Endpoints))
		for j, ep := range api.Endpoints {
			got[j] = ep.Path + " " + strings.Join(ep.Methods, ",")
		}
		if i == 0 {
			want = got
			// Paths must be in sorted order.
			wantPaths := []string{"/accounts", "/accounts/{id}", "/transactions"}
			for k, ep := range api.Endpoints {
				if ep.Path != wantPaths[k] {
					t.Fatalf("endpoint[%d].Path = %q, want %q (sorted)", k, ep.Path, wantPaths[k])
				}
			}
			// Methods on /accounts must be sorted (GET before POST).
			if api.Endpoints[0].Methods[0] != "GET" || api.Endpoints[0].Methods[1] != "POST" {
				t.Fatalf("/accounts methods = %v, want [GET POST] sorted", api.Endpoints[0].Methods)
			}
			continue
		}
		if len(got) != len(want) {
			t.Fatalf("run %d: %d endpoints, want %d", i, len(got), len(want))
		}
		for j := range got {
			if got[j] != want[j] {
				t.Fatalf("run %d: endpoint[%d] = %+v, want %+v (non-deterministic order)", i, j, got[j], want[j])
			}
		}
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
