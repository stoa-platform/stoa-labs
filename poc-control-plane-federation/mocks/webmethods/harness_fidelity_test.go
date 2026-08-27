package main

// Tests of the three fidelity properties the LIVE promotion harness demands and
// that nothing else in the mock was asking for. Each one guards a failure that
// is SILENT from the admin surface: the ids look fine, the import reports
// Success, the API reads back active — and the proof still lies.
//
//	scripts/test-archive-promotion.sh, run unchanged against the mock:
//	  T10 needs gateway ids in the uuid silhouette (its id-map re-write skips
//	      anything else, and the "authored GUID" archive then collides);
//	  T2/T4/T6/T10 need the harness's FLOW-style contract to be understood
//	      (an unread contract = empty allowlist = 404 on the whole data-plane)
//	      and the routed path reported as `.path`.

import (
	"net/http"
	"regexp"
	"testing"
)

// harnessGUIDRe is VERBATIM the pattern scripts/test-archive-promotion.sh (T10)
// uses to recognise a gateway id inside an archive entry name.
var harnessGUIDRe = regexp.MustCompile(`^[A-Za-z]+\.([0-9a-f-]{36})$`)

func TestNextID_IsShapedLikeAGatewayGUID(t *testing.T) {
	s := NewStore()
	seen := map[string]bool{}
	for _, kind := range []string{"api", "pol", "action", "alias", "app", "strat", "scope", "client", "secret"} {
		for i := 0; i < 3; i++ {
			id := s.nextID(kind)
			// The harness matches "<Type>.<id>" — an id it does not recognise is
			// left as is by the L2 synthesis, which then collides on import.
			if !harnessGUIDRe.MatchString("PolicyAction." + id) {
				t.Errorf("nextID(%q) = %q — T10's ^[A-Za-z]+\\.([0-9a-f-]{36})$ does not match it", kind, id)
			}
			if len(id) != 36 {
				t.Errorf("nextID(%q) = %q, length %d, want 36", kind, id, len(id))
			}
			if seen[id] {
				t.Errorf("nextID(%q) minted %q twice", kind, id)
			}
			seen[id] = true
		}
	}
	// Sorting within a family must still follow creation order (listAPIs and
	// friends sort by id to keep demo diffs stable).
	a, b := s.nextID("api"), s.nextID("api")
	if a >= b {
		t.Errorf("ids of one family must sort in creation order, got %q >= %q", a, b)
	}
	// Determinism: proofs are replayed, ids must not drift between runs.
	if other := NewStore(); other.nextID("api") != NewStore().nextID("api") {
		t.Errorf("nextID is not deterministic across stores")
	}
}

// harnessContract is the contract scripts/test-archive-promotion.sh writes,
// character for character (flow style, quoted server url, quoted status key).
const harnessContract = `openapi: 3.0.0
info: { title: spike079t-api, version: 1.0.0 }
servers: [ { url: "http://poc-token-echo:8080" } ]
paths: { /ping: { get: { operationId: ping, responses: { '200': { description: ok } } } } }
`

func TestContractFromYAML_FlowStyle(t *testing.T) {
	def := parseContractDoc([]byte(harnessContract))

	servers, _ := def["servers"].([]any)
	if len(servers) != 1 {
		t.Fatalf("servers = %v, want one entry (the routing backend comes from servers[0])", def["servers"])
	}
	if url := servers[0].(map[string]any)["url"]; url != "http://poc-token-echo:8080" {
		t.Errorf("servers[0].url = %v", url)
	}
	paths, _ := def["paths"].(map[string]any)
	if len(paths) != 1 {
		t.Fatalf("paths = %v, want exactly {/ping} (nested commas must not split the mapping)", def["paths"])
	}
	if _, ok := paths["/ping"]; !ok {
		t.Errorf("paths = %v, want the /ping key", paths)
	}

	// Block style must keep working — it is what apis/*.openapi.yaml uses.
	block := parseContractDoc([]byte("openapi: 3.0.3\nservers:\n  - url: http://backend:8080/base\npaths:\n  /accounts:\n    get: {}\n  /accounts/{id}:\n    get: {}\n"))
	if srv, _ := block["servers"].([]any); len(srv) != 1 || srv[0].(map[string]any)["url"] != "http://backend:8080/base" {
		t.Errorf("block-style servers = %v", block["servers"])
	}
	if p, _ := block["paths"].(map[string]any); len(p) != 2 {
		t.Errorf("block-style paths = %v, want 2 keys", block["paths"])
	}
}

// A flow contract must reach the data-plane: routing derived from servers[0],
// allowlist derived from paths. Before the flow support, both were empty and
// EVERY call 404'd while the import reported success.
func TestDataPlane_ServesAnAPIImportedFromAFlowContract(t *testing.T) {
	h := newTestServer(t)
	rr := doMultipartCreateAPI(t, h, "spike079t-api", "1.0.0", []byte(harnessContract))
	if rr.Code != http.StatusCreated {
		t.Fatalf("import = %d body=%s", rr.Code, rr.Body)
	}
	id := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)["id"].(string)
	if rr := doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+id+"/activate", nil); rr.Code != http.StatusOK {
		t.Fatalf("activate = %d", rr.Code)
	}

	rr = do(t, h, "GET", "/gateway/spike079t-api/1.0.0/ping", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("data-plane = %d body=%s (an unread contract exposes NOTHING)", rr.Code, rr.Body)
	}
	body := decode(t, rr)
	if got := body["resolved_url"]; got != "http://poc-token-echo:8080/ping" {
		t.Errorf("resolved_url = %v, want the servers[0] backend + resource", got)
	}
	// T2/T6/T10 read `.path` — what the backend would see.
	if got := body["path"]; got != "/ping" {
		t.Errorf("path = %v, want /ping", got)
	}

	// …and through an ${alias}, the whole promotion routing.
	rr = doAdmin(t, h, "POST", "/rest/apigateway/alias", map[string]any{
		"name": "spike079t-backend", "type": "endpoint",
		"endPointURI": "http://poc-token-echo:8080/backend/dev",
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("create alias = %d body=%s", rr.Code, rr.Body)
	}
	pols := decode(t, doAdmin(t, h, "GET", "/rest/apigateway/apis/"+id, nil))["apiResponse"].(map[string]any)["api"].(map[string]any)["policies"].([]any)
	putRoutingURI(t, h, routingActionID(t, h, pols[0].(string)), "${spike079t-backend}/${sys:resource_path}")

	body = decode(t, do(t, h, "GET", "/gateway/spike079t-api/1.0.0/ping", nil))
	if got := body["path"]; got != "/backend/dev/ping" {
		t.Errorf("path = %v, want /backend/dev/ping (T2's assertion)", got)
	}
	if got := body["alias_resolved"]; got != true {
		t.Errorf("alias_resolved = %v", got)
	}
}

func TestResolvedPath_DropsSchemeAndAuthority(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"http://poc-token-echo:8080/backend/dev/ping", "/backend/dev/ping"},
		{"https://host/base", "/base"},
		{"http://host:8080", "/"},
		{"/base/accounts", "/base/accounts"},
		{"", "/"},
	} {
		if got := resolvedPath(tc.in); got != tc.want {
			t.Errorf("resolvedPath(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
