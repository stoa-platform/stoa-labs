package uac

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeRepo materialises a governance repo from rel-path -> content in a temp
// dir and returns its root. Paths use forward slashes.
func writeRepo(t *testing.T, files map[string]string) string {
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

const accountsContract = `name: accounts-read
version: 1.0.0
tenant_id: banking-demo
display_name: "Comptes — consultation"
description: "Consultation des comptes."
status: published
endpoints:
  - path: /accounts
    methods: [GET]
    backend_url: http://microcks:8080/rest/Accounts+Read+API/1.0.0
    operation_id: listAccounts
  - path: /accounts/{iban}/balance
    methods: [GET]
    backend_url: http://microcks:8080/rest/Accounts+Read+API/1.0.0
    operation_id: getBalance
`

const paymentsContract = `name: payments-initiation
version: 0.3.0
tenant_id: banking-demo
status: published
endpoints:
  - path: /payments
    methods: [POST]
    backend_url: http://microcks:8080/rest/payments/0.3.0
  - path: /payments/{id}
    methods: [DELETE]
    backend_url: http://other-backend:9999/payments
`

const draftContract = `name: drafty
version: 0.1.0
tenant_id: banking-demo
status: draft
`

const enabledDeploy = "version: 1.0.0\nenabled: true\npromoted_by: alice\nmessage: ok\n"
const disabledDeploy = "version: 1.0.0\nenabled: false\npromoted_by: alice\nmessage: held\n"

func TestLoadRepo_LayoutDeploysAndOrder(t *testing.T) {
	root := writeRepo(t, map[string]string{
		"tenants/other-corp/apis/drafty/api.yaml":                              draftContract,
		"tenants/banking-demo/apis/payments-initiation/api.yaml":               paymentsContract,
		"tenants/banking-demo/apis/payments-initiation/deploy.production.yaml": enabledDeploy,
		"tenants/banking-demo/apis/accounts-read/api.yaml":                     accountsContract,
		"tenants/banking-demo/apis/accounts-read/deploy.dev.yaml":              enabledDeploy,
		"tenants/banking-demo/apis/accounts-read/deploy.staging.yaml":          disabledDeploy,
	})
	apis, err := LoadRepo(root)
	if err != nil {
		t.Fatalf("LoadRepo: %v", err)
	}
	if len(apis) != 3 {
		t.Fatalf("len(apis) = %d, want 3", len(apis))
	}
	// Deterministic (tenant, slug) order regardless of write order.
	wantOrder := []string{"banking-demo/accounts-read", "banking-demo/payments-initiation", "other-corp/drafty"}
	for i, w := range wantOrder {
		if got := apis[i].Tenant + "/" + apis[i].Slug; got != w {
			t.Errorf("apis[%d] = %s, want %s", i, got, w)
		}
	}
	acc := apis[0]
	if acc.Contract.Status != StatusPublished || acc.Contract.Version != "1.0.0" {
		t.Errorf("accounts-read contract misparsed: %+v", acc.Contract)
	}
	if len(acc.Deploys) != 2 {
		t.Fatalf("accounts-read deploys = %v, want dev+staging", acc.Deploys)
	}
	if d := acc.Deploys["dev"]; !d.Enabled || d.PromotedBy != "alice" || d.Message != "ok" || d.Version != "1.0.0" {
		t.Errorf("deploy.dev misparsed: %+v", d)
	}
	if d := acc.Deploys["staging"]; d.Enabled {
		t.Errorf("deploy.staging should be disabled: %+v", d)
	}
}

func TestLoadRepo_Validation(t *testing.T) {
	cases := []struct {
		name    string
		api     string
		wantErr string
	}{
		{
			name:    "name-slug mismatch",
			api:     "name: other-name\nstatus: published\nendpoints: [{path: /x, methods: [GET], backend_url: http://b}]\n",
			wantErr: "does not match its directory slug",
		},
		{
			name:    "missing status",
			api:     "name: accounts-read\n",
			wantErr: "status is required",
		},
		{
			name:    "unknown status",
			api:     "name: accounts-read\nstatus: live\n",
			wantErr: `unknown status "live"`,
		},
		{
			name:    "published endpoint without backend_url",
			api:     "name: accounts-read\nstatus: published\nendpoints: [{path: /x, methods: [GET]}]\n",
			wantErr: "backend_url is required",
		},
		{
			name:    "published endpoint without methods",
			api:     "name: accounts-read\nstatus: published\nendpoints: [{path: /x, backend_url: http://b}]\n",
			wantErr: "at least one method is required",
		},
		{
			name:    "published endpoint with unknown method",
			api:     "name: accounts-read\nstatus: published\nendpoints: [{path: /x, methods: [FETCH], backend_url: http://b}]\n",
			wantErr: `unknown method "FETCH"`,
		},
		{
			name:    "invalid slug name",
			api:     "name: Accounts_Read\nstatus: draft\n",
			wantErr: "is not a valid slug",
		},
		{
			name:    "published tenant_id spoofs another tenant",
			api:     "name: accounts-read\ntenant_id: evil-corp\nstatus: published\nendpoints: [{path: /x, methods: [GET], backend_url: http://b}]\n",
			wantErr: "does not match its path tenant",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := writeRepo(t, map[string]string{
				"tenants/banking-demo/apis/accounts-read/api.yaml": tc.api,
			})
			if _, err := LoadRepo(root); err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Errorf("err = %v, want %q", err, tc.wantErr)
			}
		})
	}
}

// A draft may be incomplete (no endpoints, no backends) without failing the
// whole repo load — only PUBLISHED contracts are held to projection standards.
func TestLoadRepo_IncompleteDraftIsAccepted(t *testing.T) {
	root := writeRepo(t, map[string]string{
		"tenants/banking-demo/apis/drafty/api.yaml": "name: drafty\nstatus: draft\nendpoints: [{path: /x}]\n",
	})
	apis, err := LoadRepo(root)
	if err != nil {
		t.Fatalf("LoadRepo: %v", err)
	}
	if len(apis) != 1 || apis[0].Contract.Status != StatusDraft {
		t.Errorf("apis = %+v, want one draft", apis)
	}
}

// A DRAFT may carry a mismatched tenant_id (work-in-progress); the anti-spoof
// integrity check binds PUBLISHED contracts only, mirroring endpoint validation.
func TestLoadRepo_DraftTenantMismatchAccepted(t *testing.T) {
	root := writeRepo(t, map[string]string{
		"tenants/banking-demo/apis/drafty/api.yaml": "name: drafty\ntenant_id: other-corp\nstatus: draft\n",
	})
	if _, err := LoadRepo(root); err != nil {
		t.Fatalf("draft tenant mismatch must be accepted (published-only check): %v", err)
	}
}

func TestLoadRepo_MissingRootAndEmptyRepo(t *testing.T) {
	if _, err := LoadRepo(filepath.Join(t.TempDir(), "nope")); err == nil {
		t.Errorf("missing root should error")
	}
	if _, err := LoadRepo(t.TempDir()); err == nil || !strings.Contains(err.Error(), "no tenants/*/apis/*/api.yaml") {
		t.Errorf("empty repo: err = %v, want no-contracts error", err)
	}
}

func TestEnabledEnvs(t *testing.T) {
	a := API{Deploys: map[string]Deploy{
		"dev":        {Enabled: true},
		"staging":    {Enabled: false},
		"production": {Enabled: true},
		"qa":         {Enabled: true}, // non-canonical env found in a repo
	}}
	// EnvAny = union, canonical promotion order first, then extras alphabetical.
	if got := a.EnabledEnvs(EnvAny); strings.Join(got, ",") != "dev,production,qa" {
		t.Errorf("EnabledEnvs(any) = %v, want [dev production qa]", got)
	}
	if got := a.EnabledEnvs("dev"); strings.Join(got, ",") != "dev" {
		t.Errorf("EnabledEnvs(dev) = %v, want [dev]", got)
	}
	if got := a.EnabledEnvs("staging"); got != nil {
		t.Errorf("EnabledEnvs(staging) = %v, want nil (disabled)", got)
	}
	if got := a.EnabledEnvs("missing"); got != nil {
		t.Errorf("EnabledEnvs(missing) = %v, want nil", got)
	}
}

func TestValidEnv(t *testing.T) {
	for _, e := range []string{"dev", "staging", "production", "any"} {
		if !ValidEnv(e) {
			t.Errorf("ValidEnv(%q) = false, want true", e)
		}
	}
	for _, e := range []string{"", "prod", "DEV", "all"} {
		if ValidEnv(e) {
			t.Errorf("ValidEnv(%q) = true, want false", e)
		}
	}
}

func TestDriftWarnings(t *testing.T) {
	a := API{
		Contract: Contract{Name: "accounts-read", Version: "1.0.0"},
		Deploys: map[string]Deploy{
			"dev":     {Enabled: true, Version: "1.0.0"},
			"staging": {Enabled: true, Version: "0.9.0"},
			"qa":      {Enabled: true}, // no pinned version: no drift to report
		},
	}
	warns := a.DriftWarnings([]string{"dev", "staging", "qa"})
	if len(warns) != 1 || !strings.Contains(warns[0], "deploy.staging pins version 0.9.0") {
		t.Errorf("DriftWarnings = %v, want one staging drift", warns)
	}
}

func loadOne(t *testing.T, files map[string]string) API {
	t.Helper()
	apis, err := LoadRepo(writeRepo(t, files))
	if err != nil {
		t.Fatalf("LoadRepo: %v", err)
	}
	if len(apis) != 1 {
		t.Fatalf("len(apis) = %d, want 1", len(apis))
	}
	return apis[0]
}

func TestProject_Mapping(t *testing.T) {
	a := loadOne(t, map[string]string{
		"tenants/banking-demo/apis/accounts-read/api.yaml": accountsContract,
	})
	api, warns, err := a.Project()
	if err != nil {
		t.Fatalf("Project: %v", err)
	}
	if len(warns) != 0 {
		t.Errorf("warnings = %v, want none (single backend)", warns)
	}
	if api.Name != "accounts-read" || api.Version != "1.0.0" {
		t.Errorf("name/version = %s/%s, want accounts-read/1.0.0", api.Name, api.Version)
	}
	if api.BasePath != "/accounts-read/v1" {
		t.Errorf("BasePath = %q, want /accounts-read/v1", api.BasePath)
	}
	if api.BackendURL != "http://microcks:8080/rest/Accounts+Read+API/1.0.0" {
		t.Errorf("BackendURL = %q, want the first endpoint's backend", api.BackendURL)
	}
	if len(api.Endpoints) != 2 ||
		api.Endpoints[0].Path != "/accounts" || strings.Join(api.Endpoints[0].Methods, ",") != "GET" ||
		api.Endpoints[1].Path != "/accounts/{iban}/balance" {
		t.Errorf("endpoints misprojected: %+v", api.Endpoints)
	}
	// Synthesized OpenAPI: enough for WSO2 import-openapi to have a real file.
	spec := string(api.Spec)
	for _, want := range []string{"openapi: 3.0.3", "/accounts-read/v1", "operationId: getBalance", "title:", "paths:"} {
		if !strings.Contains(spec, want) {
			t.Errorf("synthesized spec missing %q:\n%s", want, spec)
		}
	}
	// Determinism: projecting twice yields the same bytes (idempotent re-apply).
	api2, _, err := a.Project()
	if err != nil {
		t.Fatalf("Project (second): %v", err)
	}
	if string(api2.Spec) != spec {
		t.Errorf("synthesized spec is not deterministic")
	}
}

func TestProject_MajorZeroBasePath(t *testing.T) {
	a := loadOne(t, map[string]string{
		"tenants/banking-demo/apis/payments-initiation/api.yaml": paymentsContract,
	})
	api, _, err := a.Project()
	if err != nil {
		t.Fatalf("Project: %v", err)
	}
	if api.BasePath != "/payments-initiation/v0" {
		t.Errorf("BasePath = %q, want /payments-initiation/v0 (version 0.3.0)", api.BasePath)
	}
}

func TestProject_MultiBackendTakesFirstAndWarns(t *testing.T) {
	a := loadOne(t, map[string]string{
		"tenants/banking-demo/apis/payments-initiation/api.yaml": paymentsContract,
	})
	api, warns, err := a.Project()
	if err != nil {
		t.Fatalf("Project: %v", err)
	}
	if api.BackendURL != "http://microcks:8080/rest/payments/0.3.0" {
		t.Errorf("BackendURL = %q, want the FIRST endpoint's backend", api.BackendURL)
	}
	if len(warns) != 1 ||
		!strings.Contains(warns[0], "multiple distinct backend_urls") ||
		!strings.Contains(warns[0], "http://other-backend:9999/payments") ||
		!strings.Contains(warns[0], "taking the first (http://microcks:8080/rest/payments/0.3.0)") {
		t.Errorf("warnings = %v, want one multi-backend warning naming both", warns)
	}
}

func TestProject_MergesSamePathEndpoints(t *testing.T) {
	a := loadOne(t, map[string]string{
		"tenants/banking-demo/apis/things/api.yaml": `name: things
version: 2.1.0
status: published
endpoints:
  - {path: /things, methods: [post], backend_url: http://b:1}
  - {path: /things, methods: [GET], backend_url: http://b:1}
`,
	})
	api, _, err := a.Project()
	if err != nil {
		t.Fatalf("Project: %v", err)
	}
	if len(api.Endpoints) != 1 ||
		api.Endpoints[0].Path != "/things" ||
		strings.Join(api.Endpoints[0].Methods, ",") != "GET,POST" {
		t.Errorf("endpoints = %+v, want one /things with GET,POST (merged, upper, sorted)", api.Endpoints)
	}
	if api.BasePath != "/things/v2" {
		t.Errorf("BasePath = %q, want /things/v2", api.BasePath)
	}
}

func TestProject_NoEndpointsErrors(t *testing.T) {
	a := API{Tenant: "t", Slug: "llm-only", Contract: Contract{Name: "llm-only", Version: "1.0.0", Status: StatusPublished}}
	if _, _, err := a.Project(); err == nil || !strings.Contains(err.Error(), "no REST endpoints to project") {
		t.Errorf("err = %v, want no-REST-endpoints error", err)
	}
}
