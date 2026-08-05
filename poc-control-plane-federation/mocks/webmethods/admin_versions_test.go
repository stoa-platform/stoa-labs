package main

// Palier 3, Task 2 : le mock apprend le multipart POST /apis (gap connu qui
// bloquait toute preuve producteur hors ligne, palier 2) et la sémantique
// MESURÉE de POST /apis/{id}/versions — les faits datés du 2026-08-05
// (spike-api-versions-1015 sur la vraie gateway 10.15 du lab, task-1-report.md),
// reproduits verbatim, y compris les SILENCES (flag mal casé = aucun effet,
// jamais un 400).

import (
	"bytes"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"
)

// --- multipart POST /apis -----------------------------------------------------

// multipartYAMLContract is a real-shape OpenAPI YAML document (2-space
// mappings, "- url:" sequence item) — the same structure as apis/*.openapi.yaml
// in this repo, which is what apim_publish_api actually uploads.
const multipartYAMLContract = `openapi: 3.0.3
info:
  title: Multipart Probe
  version: 1.0.0
servers:
  - url: http://backend.internal:9090/base
paths:
  /accounts:
    get:
      summary: list accounts
  /accounts/{id}:
    get:
      summary: get one account
`

// doMultipartCreateAPI builds the EXACT multipart shape
// ansible/roles/apim_publish_api/tasks/main.yml sends (relevé le 2026-08-05):
// form fields apiName/apiVersion/type + a "file" part carrying the raw
// contract bytes.
func doMultipartCreateAPI(t *testing.T, h http.Handler, apiName, apiVersion string, contract []byte) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for k, v := range map[string]string{
		"apiName": apiName, "apiVersion": apiVersion, "type": "openapi",
	} {
		if err := mw.WriteField(k, v); err != nil {
			t.Fatalf("write field %s: %v", k, err)
		}
	}
	fw, err := mw.CreateFormFile("file", apiName+".openapi.yaml")
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	if _, err := fw.Write(contract); err != nil {
		t.Fatalf("write file part: %v", err)
	}
	if err := mw.Close(); err != nil {
		t.Fatalf("close multipart writer: %v", err)
	}
	req := httptest.NewRequest("POST", "/rest/apigateway/apis", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.SetBasicAuth(testUser, testPass)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	return rr
}

func TestCreateAPI_Multipart_AcceptsFileFieldAndImports(t *testing.T) {
	h := newTestServer(t)
	rr := doMultipartCreateAPI(t, h, "p3t2-multipart", "1.0.0", []byte(multipartYAMLContract))
	if rr.Code != http.StatusCreated {
		t.Fatalf("multipart create = %d body=%s (this is the gap that blocked apim_publish_api offline)", rr.Code, rr.Body)
	}
	env := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)
	id, _ := env["id"].(string)
	if id == "" {
		t.Fatalf("multipart create carries no id: %s", rr.Body)
	}
	if active, _ := env["isActive"].(bool); active {
		t.Fatal("multipart import must NOT activate, like the JSON path")
	}

	// Re-read: the record persisted with the fields the multipart form carried.
	rr = doAdmin(t, h, "GET", "/rest/apigateway/apis/"+id, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("re-read = %d body=%s", rr.Code, rr.Body)
	}
	got := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)
	if got["apiName"] != "p3t2-multipart" || got["apiVersion"] != "1.0.0" {
		t.Errorf("re-read = %v, want apiName/apiVersion from the multipart fields", got)
	}
}

// TestCreateAPI_Multipart_ContractDrivesDataPlane proves the "file" part was
// actually decoded (servers[0].url + paths), not just accepted and discarded:
// the allowlist and routing target must reflect the uploaded YAML contract,
// exactly like the JSON import path.
func TestCreateAPI_Multipart_ContractDrivesDataPlane(t *testing.T) {
	h := newTestServer(t)
	rr := doMultipartCreateAPI(t, h, "p3t2-dataplane", "1.0.0", []byte(multipartYAMLContract))
	id := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)["id"].(string)
	doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+id+"/activate", nil)

	// In-contract path resolves against the YAML servers[0].url.
	rr = do(t, h, "GET", "/gateway/p3t2-dataplane/1.0.0/accounts/42", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("in-contract resource = %d body=%s", rr.Code, rr.Body)
	}
	body := decode(t, rr)
	want := "http://backend.internal:9090/base/accounts/42"
	if body["resolved_url"] != want {
		t.Errorf("resolved_url = %v, want %q (servers[0].url from the YAML file part)", body["resolved_url"], want)
	}

	// Out-of-contract path: the allowlist is built from the YAML `paths`, not
	// wide open — a mock that discarded the file part would let this through.
	rr = do(t, h, "GET", "/gateway/p3t2-dataplane/1.0.0/not-in-contract", nil)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("out-of-contract resource = %d, want 404 (allowlist from parsed YAML paths)", rr.Code)
	}
}

// --- POST /apis/{id}/versions — sémantique mesurée 2026-08-05 ----------------

// mkAppSubscribedTo creates a throwaway application already subscribed to
// apiID (mirrors the spike's "app jetable souscrite aux bases" witness).
func mkAppSubscribedTo(t *testing.T, h http.Handler, apiID string) string {
	t.Helper()
	rr := doAdmin(t, h, "POST", "/rest/apigateway/applications", map[string]any{"name": "p3t2-app-" + apiID})
	if rr.Code != http.StatusCreated {
		t.Fatalf("create app = %d body=%s", rr.Code, rr.Body)
	}
	appID := decode(t, rr)["id"].(string)
	rr = doAdmin(t, h, "PUT", "/rest/apigateway/applications/"+appID+"/apis",
		map[string]any{"apiIDs": []string{apiID}})
	if rr.Code != http.StatusNoContent {
		t.Fatalf("associate app to base = %d body=%s", rr.Code, rr.Body)
	}
	return appID
}

// consumingAPIsOf re-reads an application and returns its consumingAPIs ids.
func consumingAPIsOf(t *testing.T, h http.Handler, appID string) []string {
	t.Helper()
	rr := doAdmin(t, h, "GET", "/rest/apigateway/applications/"+appID, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("get app = %d body=%s", rr.Code, rr.Body)
	}
	app := decode(t, rr)["applications"].([]any)[0].(map[string]any)
	raw, _ := app["consumingAPIs"].([]any)
	out := make([]string, 0, len(raw))
	for _, v := range raw {
		out = append(out, v.(string))
	}
	return out
}

func containsStr(list []string, want string) bool {
	for _, v := range list {
		if v == want {
			return true
		}
	}
	return false
}

// TestCreateVersionAPI_Bare_MintsButDoesNotRetain is M1 (bare body suffices,
// 201) + the M3 default: retainApplications ABSENT never propagates the
// subscription, but the base stays subscribed.
func TestCreateVersionAPI_Bare_MintsButDoesNotRetain(t *testing.T) {
	h := newTestServer(t)
	baseID, basePolID := importAPI(t, h, "p3t2-bare", "1.0.0")
	appID := mkAppSubscribedTo(t, h, baseID)

	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis/"+baseID+"/versions",
		map[string]any{"newApiVersion": "2.0"}) // M1: newApiVersion ALONE
	if rr.Code != http.StatusCreated {
		t.Fatalf("bare /versions = %d body=%s, want 201 (M1: newApiVersion alone suffices)", rr.Code, rr.Body)
	}
	v2 := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)
	v2ID, _ := v2["id"].(string)
	if v2ID == "" {
		t.Fatalf("versions response carries no id: %s", rr.Body)
	}
	if active, _ := v2["isActive"].(bool); active {
		t.Error("a minted version must start isActive:false, like a first import")
	}
	v2Pols, _ := v2["policies"].([]any)
	if len(v2Pols) != 1 || v2Pols[0].(string) == basePolID {
		t.Errorf("M2: policies = %v, want ONE CLONED id different from the base's %q", v2Pols, basePolID)
	}

	// M3 default: no retainApplications -> NOT propagated. Counter-witness:
	// the base's own subscription must still be there (never desubscribed).
	got := consumingAPIsOf(t, h, appID)
	if containsStr(got, v2ID) {
		t.Errorf("consumingAPIs = %v: the new version leaked in WITHOUT retainApplications", got)
	}
	if !containsStr(got, baseID) {
		t.Errorf("consumingAPIs = %v: the base subscription must survive /versions", got)
	}
}

// TestCreateVersionAPI_RetainApplicationsTrue_Propagates is the M3 positive
// counter-witness of the bare-body test above: same setup, exact casing and
// boolean true DOES propagate.
func TestCreateVersionAPI_RetainApplicationsTrue_Propagates(t *testing.T) {
	h := newTestServer(t)
	baseID, _ := importAPI(t, h, "p3t2-retain-true", "1.0.0")
	appID := mkAppSubscribedTo(t, h, baseID)

	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis/"+baseID+"/versions",
		map[string]any{"newApiVersion": "2.0", "retainApplications": true})
	if rr.Code != http.StatusCreated {
		t.Fatalf("/versions retainApplications:true = %d body=%s", rr.Code, rr.Body)
	}
	v2ID := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)["id"].(string)

	got := consumingAPIsOf(t, h, appID)
	if !containsStr(got, v2ID) {
		t.Errorf("consumingAPIs = %v: retainApplications:true must add the new version %q", got, v2ID)
	}
	if !containsStr(got, baseID) {
		t.Errorf("consumingAPIs = %v: the base subscription must survive too", got)
	}
}

// TestCreateVersionAPI_RetainApplicationsFalse_DoesNotPropagate: explicit
// false behaves exactly like absent (M1's measured 3rd variant).
func TestCreateVersionAPI_RetainApplicationsFalse_DoesNotPropagate(t *testing.T) {
	h := newTestServer(t)
	baseID, _ := importAPI(t, h, "p3t2-retain-false", "1.0.0")
	appID := mkAppSubscribedTo(t, h, baseID)

	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis/"+baseID+"/versions",
		map[string]any{"newApiVersion": "2.0", "retainApplications": false})
	if rr.Code != http.StatusCreated {
		t.Fatalf("/versions retainApplications:false = %d body=%s", rr.Code, rr.Body)
	}
	v2ID := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)["id"].(string)

	got := consumingAPIsOf(t, h, appID)
	if containsStr(got, v2ID) {
		t.Errorf("consumingAPIs = %v: retainApplications:false must NOT propagate", got)
	}
}

// TestCreateVersionAPI_WrongCasing_IsSilentlyIgnored is THE decisive trap
// (M3, brief): a wrong-cased "RetainApplications":true is accepted (201, no
// 400 — the product's JSON is lax about unknown keys everywhere else too),
// but has NO effect — indistinguishable, from the caller's HTTP response, from
// a body that never mentioned the flag at all. Only the read-back of
// consumingAPIs (this test) can tell "ignored" from "broken but silent".
func TestCreateVersionAPI_WrongCasing_IsSilentlyIgnored(t *testing.T) {
	h := newTestServer(t)
	baseID, _ := importAPI(t, h, "p3t2-wrong-case", "1.0.0")
	appID := mkAppSubscribedTo(t, h, baseID)

	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis/"+baseID+"/versions",
		map[string]any{"newApiVersion": "2.0", "RetainApplications": true}) // WRONG CASE
	if rr.Code != http.StatusCreated {
		t.Fatalf("/versions with wrong-cased flag = %d body=%s, want 201 (the mismatch is SILENT, never a 400)", rr.Code, rr.Body)
	}
	v2ID := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)["id"].(string)

	got := consumingAPIsOf(t, h, appID)
	if containsStr(got, v2ID) {
		t.Errorf("consumingAPIs = %v: a WRONG-CASED retainApplications must NOT propagate (the exact trap this test guards)", got)
	}
	if !containsStr(got, baseID) {
		t.Errorf("consumingAPIs = %v: the base subscription must still survive", got)
	}
}

// TestCreateVersionAPI_DuplicateVersionNumber_Is400 is the BONUS fact: minting
// a version number that already exists for this apiName is refused with the
// gateway's own message — no application-side guard needed for this case.
func TestCreateVersionAPI_DuplicateVersionNumber_Is400(t *testing.T) {
	h := newTestServer(t)
	baseID, _ := importAPI(t, h, "p3t2-dup", "1.0.0")

	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis/"+baseID+"/versions",
		map[string]any{"newApiVersion": "1.0.0"}) // == the base's OWN version
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("duplicate version number = %d, want 400", rr.Code)
	}
	want := `Unable to version the API p3t2-dup with version 1.0.0 that already exists.`
	if got := decode(t, rr)["errorDetails"]; got != want {
		t.Errorf("errorDetails = %q, want %q (exact product message, measured 2026-08-05)", got, want)
	}
}

// TestCreateVersionAPI_OnlyLatestVersionAccepted is the "écart de conception"
// (task-1-report.md): {id} must be the CURRENT latest of its apiName lineage.
// A second /versions call on a now-superseded id fails even though it
// succeeded moments before; the chain can continue from the NEW latest.
func TestCreateVersionAPI_OnlyLatestVersionAccepted(t *testing.T) {
	h := newTestServer(t)
	baseID, _ := importAPI(t, h, "p3t2-latest", "1.0.0")

	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis/"+baseID+"/versions",
		map[string]any{"newApiVersion": "2.0"})
	if rr.Code != http.StatusCreated {
		t.Fatalf("first mint = %d body=%s", rr.Code, rr.Body)
	}
	v2ID := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)["id"].(string)

	// Counter-witness: the SAME baseID, which just worked one call ago, is
	// now refused — it is no longer the latest.
	rr = doAdmin(t, h, "POST", "/rest/apigateway/apis/"+baseID+"/versions",
		map[string]any{"newApiVersion": "3.0"})
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("second mint on superseded base = %d, want 400", rr.Code)
	}
	want := "Versioning is allowed only from latest version"
	if got := decode(t, rr)["errorDetails"]; got != want {
		t.Errorf("errorDetails = %q, want %q", got, want)
	}

	// The chain continues from the NEW latest.
	rr = doAdmin(t, h, "POST", "/rest/apigateway/apis/"+v2ID+"/versions",
		map[string]any{"newApiVersion": "3.0"})
	if rr.Code != http.StatusCreated {
		t.Fatalf("mint from the new latest = %d body=%s", rr.Code, rr.Body)
	}
}

// --- PUT /apis/{id} (update-in-place) — multipart + le refus mesuré sur une
// API active --------------------------------------------------------------
//
// ansible/roles/apim_publish_api/tasks/main.yml:103-121 sends the SAME
// multipart shape as the import (file/type/apiName/apiVersion) for the
// update-in-place path (apim_api.update:true), preceded by the measured
// dance: deactivate (the PUT is refused 400 on an ACTIVE api — ADR-078/079)
// → PUT multipart → reactivate.

// doMultipartUpdateAPI builds the same multipart shape as
// doMultipartCreateAPI, for PUT /apis/{id}.
func doMultipartUpdateAPI(t *testing.T, h http.Handler, id, apiVersion string, contract []byte) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for k, v := range map[string]string{"apiVersion": apiVersion, "type": "openapi"} {
		if err := mw.WriteField(k, v); err != nil {
			t.Fatalf("write field %s: %v", k, err)
		}
	}
	fw, err := mw.CreateFormFile("file", "update.openapi.yaml")
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	if _, err := fw.Write(contract); err != nil {
		t.Fatalf("write file part: %v", err)
	}
	if err := mw.Close(); err != nil {
		t.Fatalf("close multipart writer: %v", err)
	}
	req := httptest.NewRequest("PUT", "/rest/apigateway/apis/"+id, &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.SetBasicAuth(testUser, testPass)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	return rr
}

// updatedMultipartYAMLContract is a second, DIFFERENT contract (different
// servers[0].url and paths) — proves an update actually replaced the
// definition rather than merely being accepted.
const updatedMultipartYAMLContract = `openapi: 3.0.3
info:
  title: Multipart Probe v2
  version: 1.0.0
servers:
  - url: http://backend.internal:9191/base-v2
paths:
  /widgets:
    get:
      summary: list widgets
`

// TestUpdateAPI_Multipart_RefusedWhileActive is the fact this round adds:
// the PUT that main.yml sends for update-in-place is refused (400) on an
// ACTIVE api — the exact reason the role deactivates first.
func TestUpdateAPI_Multipart_RefusedWhileActive(t *testing.T) {
	h := newTestServer(t)
	id, _ := importAPI(t, h, "p3t2-update-active", "1.0.0") // importAPI activates

	rr := doMultipartUpdateAPI(t, h, id, "1.0.0", []byte(updatedMultipartYAMLContract))
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("multipart update on an ACTIVE api = %d body=%s, want 400", rr.Code, rr.Body)
	}
}

// TestUpdateAPI_Multipart_InactiveAcceptsAndReplacesContract is the
// counter-witness: deactivate first (like the role does), and the SAME
// multipart update succeeds and the ALLOWLIST is really replaced — proven via
// the data-plane, not just the 200. The ROUTING TARGET (servers[0].url baked
// into the policy's straightThroughRouting action at import/versions time)
// is, like the JSON re-import path (TestReimport_PreservesPolicyAndRoutingAction),
// NOT regenerated from the new contract — the policy/action ids and their
// current ${alias} (if any) survive an update untouched. Only `paths`
// (the allowlist) comes from the freshly-decoded document.
func TestUpdateAPI_Multipart_InactiveAcceptsAndReplacesContract(t *testing.T) {
	h := newTestServer(t)
	id, polID := importAPI(t, h, "p3t2-update-inactive", "1.0.0")

	if rr := doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+id+"/deactivate", nil); rr.Code != http.StatusOK {
		t.Fatalf("deactivate = %d", rr.Code)
	}
	rr := doMultipartUpdateAPI(t, h, id, "1.0.0", []byte(updatedMultipartYAMLContract))
	if rr.Code != http.StatusOK {
		t.Fatalf("multipart update on an INACTIVE api = %d body=%s, want 200", rr.Code, rr.Body)
	}
	env := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)
	if got := env["policies"].([]any)[0].(string); got != polID {
		t.Errorf("policy id after update = %q, want %q (preserved, like the JSON re-import path)", got, polID)
	}

	if rr := doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+id+"/activate", nil); rr.Code != http.StatusOK {
		t.Fatalf("re-activate = %d", rr.Code)
	}
	// The NEW contract's resource resolves — the allowlist was replaced —
	// but at the ORIGINAL import's routing target (preserved, not regenerated).
	rr2 := do(t, h, "GET", "/gateway/p3t2-update-inactive/1.0.0/widgets", nil)
	if rr2.Code != http.StatusOK {
		t.Fatalf("resource from the NEW contract's paths = %d body=%s", rr2.Code, rr2.Body)
	}
	body := decode(t, rr2)
	want := "http://backend.internal:8080/base/widgets" // importBody()'s servers[0].url, preserved
	if body["resolved_url"] != want {
		t.Errorf("resolved_url = %v, want %q (routing target preserved across update)", body["resolved_url"], want)
	}
	// The OLD contract's path is gone: the allowlist now reflects only the
	// new definition's paths, not a union of both.
	if rr3 := do(t, h, "GET", "/gateway/p3t2-update-inactive/1.0.0/accounts", nil); rr3.Code != http.StatusNotFound {
		t.Errorf("old-contract path after update = %d, want 404 (allowlist replaced, not merged)", rr3.Code)
	}
}

// TestUpdateAPI_JSON_RefusedWhileActive_ButOwnerProjectionSurvives is the
// counter-witness that the isActive gate is scoped to RE-IMPORT bodies only:
// approvers.yml (main.yml runs it AFTER Activate) writes the owner field via
// the SAME route on an ACTIVE api and must keep working.
func TestUpdateAPI_JSON_RefusedWhileActive_ButOwnerProjectionSurvives(t *testing.T) {
	h := newTestServer(t)
	id, _ := importAPI(t, h, "p3t2-update-json-active", "1.0.0")

	// Re-import shape (apiVersion/apiDefinition): refused while active.
	rr := doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+id, importBody("p3t2-update-json-active", "1.0.0"))
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("JSON re-import on an ACTIVE api = %d, want 400", rr.Code)
	}

	// Field projection (owner only): NOT gated — approvers.yml depends on this.
	rr = doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+id, map[string]any{
		"apiResponse": map[string]any{"api": map[string]any{"owner": "team-x"}},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("owner projection on an ACTIVE api = %d body=%s, want 200 (approvers.yml runs AFTER activate)", rr.Code, rr.Body)
	}
	got := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)
	if got["owner"] != "team-x" {
		t.Errorf("owner after projection = %v, want %q", got["owner"], "team-x")
	}
}
