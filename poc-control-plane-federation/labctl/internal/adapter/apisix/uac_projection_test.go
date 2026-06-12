package apisix

// apply-uac contract test (PoC #6): apply-uac reuses the manifest's gateway
// FLEET via t.ToConfig(), so it projects the SAME inbound openid-connect barrier
// as apply — the only UAC-specific input is the contract's backend_url. This
// test drives the END-TO-END apply-uac projection for APISIX:
//
//	UAC contract (governed api.yaml) -> uac.Project() -> NormalizedAPI ->
//	apisix Publish with an inboundAuth-bearing fleet config
//
// and asserts the resulting route carries BOTH:
//   - openid-connect (the inbound bearer barrier — apply-uac must NOT reopen the
//     "200 without token" hole the fleet closes); and
//   - proxy-rewrite to the contract's backend base path /rest/Accounts+Read+API/
//     1.0.0 (the corrected Microcks service name; the old slug
//     /rest/accounts-read/1.0.0 would 404 against Microcks).
//
// It pins the regression closed: a stale backend_url in the UAC contract OR a
// fleet that fails to project inboundAuth would both fail here.

import (
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/uac"
)

// uacAccountsContract is the governed accounts-read api.yaml with the CORRECTED
// Microcks service name (Accounts+Read+API, not the periment slug accounts-read).
const uacAccountsContract = `name: accounts-read
version: 1.0.0
tenant_id: banking-demo
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

// projectUACAccounts loads + projects the governed accounts-read contract into a
// NormalizedAPI exactly as `labctl apply-uac` does before dispatching to the fleet.
func projectUACAccounts(t *testing.T) *adapter.NormalizedAPI {
	t.Helper()
	root := t.TempDir()
	p := filepath.Join(root, filepath.FromSlash("tenants/banking-demo/apis/accounts-read/api.yaml"))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(p, []byte(uacAccountsContract), 0o600); err != nil {
		t.Fatalf("write contract: %v", err)
	}
	apis, err := uac.LoadRepo(root)
	if err != nil {
		t.Fatalf("uac.LoadRepo: %v", err)
	}
	if len(apis) != 1 {
		t.Fatalf("len(apis) = %d, want 1", len(apis))
	}
	api, warns, err := apis[0].Project()
	if err != nil {
		t.Fatalf("uac Project: %v", err)
	}
	if len(warns) != 0 {
		t.Fatalf("unexpected projection warnings: %v", warns)
	}
	return api
}

// TestApplyUAC_APISIXProjectsOpenIDConnectAndAccountsRewrite proves the apply-uac
// path for APISIX: the governed contract, dispatched through the inboundAuth
// fleet, lands openid-connect on every route AND rewrites to the corrected
// Microcks service path — no key-auth, no stale slug.
func TestApplyUAC_APISIXProjectsOpenIDConnectAndAccountsRewrite(t *testing.T) {
	fake := newFakeAdmin(t)
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()
	a := newInboundAuthAdapter(t, srv) // fleet config carries inboundAuthDiscoveryUrl

	api := projectUACAccounts(t)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish (apply-uac path): %v", err)
	}

	for _, id := range []string{"accounts-read-0", "accounts-read-1"} {
		rt, ok := fake.callFor("PUT", "/apisix/admin/routes/"+id)
		if !ok {
			t.Fatalf("apply-uac: no PUT route %s recorded", id)
		}
		plugins, ok := rt.body["plugins"].(map[string]any)
		if !ok {
			t.Fatalf("route %s plugins is %T, want object", id, rt.body["plugins"])
		}

		// 1. Inbound barrier projected (apply-uac reuses the fleet's inboundAuth).
		oidc, ok := plugins["openid-connect"].(map[string]any)
		if !ok {
			t.Fatalf("apply-uac route %s missing openid-connect (inbound hole reopened): %v", id, plugins)
		}
		if got := oidc["discovery"]; got != testDiscovery {
			t.Errorf("route %s openid-connect.discovery = %v, want %s", id, got, testDiscovery)
		}
		if oidc["bearer_only"] != true {
			t.Errorf("route %s openid-connect not bearer_only: %v", id, oidc)
		}

		// 2. No consumer-auth at publish time (the #9 fix: never key-auth under inboundAuth).
		if _, has := plugins["key-auth"]; has {
			t.Errorf("apply-uac route %s carries key-auth under inboundAuth (regression #9)", id)
		}
		if _, has := plugins["jwt-auth"]; has {
			t.Errorf("apply-uac route %s carries jwt-auth at publish time", id)
		}

		// 3. proxy-rewrite to the CORRECTED Microcks service path, not the slug.
		pr, ok := plugins["proxy-rewrite"].(map[string]any)
		if !ok {
			t.Fatalf("route %s proxy-rewrite is %T, want object", id, plugins["proxy-rewrite"])
		}
		rx, ok := pr["regex_uri"].([]any)
		if !ok || len(rx) != 2 {
			t.Fatalf("route %s regex_uri = %v, want [pattern, replacement]", id, pr["regex_uri"])
		}
		const wantReplacement = "/rest/Accounts+Read+API/1.0.0/$1"
		if rx[1] != wantReplacement {
			t.Errorf("route %s rewrite replacement = %v, want %s (stale slug would 404 on Microcks)", id, rx[1], wantReplacement)
		}
	}
}
