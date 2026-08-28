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
	"bytes"
	"encoding/base64"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"regexp"
	"sort"
	"strings"
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

// --- Content-Transfer-Encoding: base64 (the Ansible engine's wire format) -----

// writeAnsibleFilePart writes one file part the way `ansible.builtin.uri` does
// in body_format: form-multipart — body BASE64-ENCODED, announced by the part
// header. Headers spelled as captured on the wire (G5 Task 10, écart É1).
func writeAnsibleFilePart(t *testing.T, mw *multipart.Writer, field, filename, contentType string, payload []byte) {
	t.Helper()
	hdr := make(textproto.MIMEHeader)
	hdr.Set("Content-Transfer-Encoding", "base64")
	hdr.Set("Content-Type", contentType)
	hdr.Set("Content-Disposition", fmt.Sprintf("form-data; name=%q; filename=%q", field, filename))
	part, err := mw.CreatePart(hdr)
	if err != nil {
		t.Fatalf("create part: %v", err)
	}
	if _, err := part.Write([]byte(base64.StdEncoding.EncodeToString(payload))); err != nil {
		t.Fatalf("write part: %v", err)
	}
}

func TestReadPart_HonoursContentTransferEncoding(t *testing.T) {
	payload := []byte("PK\x03\x04 the archive bytes")
	b64 := base64.StdEncoding.EncodeToString(payload)
	// RFC 2045 wraps base64 at 76 columns; the decoder must survive that.
	wrapped := b64[:8] + "\r\n" + b64[8:16] + "\n" + b64[16:]

	for _, tc := range []struct {
		name, cte, body string
		want            string
		wantErr         bool
	}{
		{name: "absent", cte: "", body: string(payload), want: string(payload)},
		{name: "binary", cte: "binary", body: string(payload), want: string(payload)},
		{name: "7bit", cte: "7bit", body: string(payload), want: string(payload)},
		{name: "8bit", cte: "8bit", body: string(payload), want: string(payload)},
		{name: "base64", cte: "base64", body: b64, want: string(payload)},
		{name: "base64 uppercase header value", cte: "BASE64", body: b64, want: string(payload)},
		{name: "base64 line-wrapped", cte: "base64", body: wrapped, want: string(payload)},
		{name: "base64 announced but not base64", cte: "base64", body: "PK\x03\x04not base64", wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fh := &multipart.FileHeader{Header: textproto.MIMEHeader{}}
			if tc.cte != "" {
				fh.Header.Set("Content-Transfer-Encoding", tc.cte)
			}
			got, err := readPart(strings.NewReader(tc.body), fh)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("readPart = %q, want an error naming the encoding", got)
				}
				if !strings.Contains(err.Error(), "base64") {
					t.Errorf("error = %v, want it to name the announced encoding", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("readPart: %v", err)
			}
			if string(got) != tc.want {
				t.Errorf("readPart = %q, want %q", got, tc.want)
			}
		})
	}
}

// importArchiveAsAnsible POSTs the archive the way the promotion role does.
func importArchiveAsAnsible(t *testing.T, h http.Handler, query string, entries map[string][]byte) *httptest.ResponseRecorder {
	t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	writeAnsibleFilePart(t, mw, "file", "archive.zip", "application/zip", zipEntries(t, entries))
	if err := mw.Close(); err != nil {
		t.Fatalf("close multipart: %v", err)
	}
	req := httptest.NewRequest("POST", "/rest/apigateway/archive"+query, &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.SetBasicAuth(testUser, testPass)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	return rr
}

// The client-facing engine (the Ansible role) must import EXACTLY like curl.
// Before this, the mock read base64 text and answered
// "not a zip: zip: not a valid zip file" — while the real gateway accepted it,
// so the default engine could not deploy into any mock tier of the lab.
func TestImportArchive_AcceptsABase64EncodedPart(t *testing.T) {
	h := newTestServer(t)
	apiID, _ := aliasRoutedAPI(t, h, "accounts-read", "env-backend", "http://dev.internal:8081/base")
	entries := exportArchiveEntries(t, h, apiID)

	fromCurl := archiveRows(t, importArchive(t, h, "?overwrite="+defaultOverwriteScope, entries))
	fromAnsible := archiveRows(t, importArchiveAsAnsible(t, h, "?overwrite="+defaultOverwriteScope, entries))

	if got := summariseRows(fromAnsible); got != summariseRows(fromCurl) {
		t.Errorf("base64 part imported as %v, want the SAME outcome as the binary part %v",
			summariseRows(fromAnsible), summariseRows(fromCurl))
	}
	for _, r := range fromAnsible {
		if r.Status != "Success" {
			t.Errorf("row %+v, want Success", r)
		}
	}
	if !apiIsActive(t, h, apiID) {
		t.Error("the API must still be active after the base64 import")
	}
}

// summariseRows renders the rows as a stable, comparable string.
func summariseRows(rows []archiveRow) string {
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, fmt.Sprintf("%s/%s/%s/%t", r.Type, r.ID, r.Status, r.Overwritten))
	}
	sort.Strings(out)
	return strings.Join(out, " ")
}

// Same fidelity on the OTHER multipart surface the role drives: publishing and
// updating an API. A contract left base64-encoded would parse to an empty
// definition — no backend, no allowlist — under a perfectly green 201.
func TestCreateAndUpdateAPI_AcceptABase64ContractPart(t *testing.T) {
	h := newTestServer(t)
	post := func(method, path, version string) *httptest.ResponseRecorder {
		var body bytes.Buffer
		mw := multipart.NewWriter(&body)
		for k, v := range map[string]string{"apiName": "spike079t-api", "apiVersion": version, "type": "openapi"} {
			if err := mw.WriteField(k, v); err != nil {
				t.Fatalf("write field: %v", err)
			}
		}
		writeAnsibleFilePart(t, mw, "file", "contract.yaml", "application/x-yaml", []byte(harnessContract))
		if err := mw.Close(); err != nil {
			t.Fatalf("close multipart: %v", err)
		}
		req := httptest.NewRequest(method, path, &body)
		req.Header.Set("Content-Type", mw.FormDataContentType())
		req.SetBasicAuth(testUser, testPass)
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		return rr
	}

	rr := post("POST", "/rest/apigateway/apis", "1.0.0")
	if rr.Code != http.StatusCreated {
		t.Fatalf("import with a base64 contract part = %d body=%s", rr.Code, rr.Body)
	}
	id := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)["id"].(string)
	if rr := doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+id+"/activate", nil); rr.Code != http.StatusOK {
		t.Fatalf("activate = %d", rr.Code)
	}
	// The contract was DECODED: the allowlist and the backend both exist.
	rr = do(t, h, "GET", "/gateway/spike079t-api/1.0.0/ping", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("data-plane = %d body=%s (the contract stayed base64 text?)", rr.Code, rr.Body)
	}
	if got := decode(t, rr)["path"]; got != "/ping" {
		t.Errorf("path = %v, want /ping", got)
	}

	if rr := doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+id+"/deactivate", nil); rr.Code != http.StatusOK {
		t.Fatalf("deactivate = %d", rr.Code)
	}
	if rr := post("PUT", "/rest/apigateway/apis/"+id, "2.0.0"); rr.Code != http.StatusOK {
		t.Fatalf("update with a base64 contract part = %d body=%s", rr.Code, rr.Body)
	}
	api := decode(t, doAdmin(t, h, "GET", "/rest/apigateway/apis/"+id, nil))["apiResponse"].(map[string]any)["api"].(map[string]any)
	if api["apiVersion"] != "2.0.0" {
		t.Errorf("apiVersion = %v, want 2.0.0", api["apiVersion"])
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
