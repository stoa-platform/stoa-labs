package webmethods

// archive_test.go — the ADR-079 archive verb: sanitize purity (strip + acdl
// purge + routing rewrite + isActive trap), import guards (overwrite scope,
// taint check) and ArchiveResult flattening. All fixtures mirror the
// spike-pinned product shapes (2026-07-17 campaign).

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const testArchiveGUID = "604e433c-aad0-4013-a9bc-b00f7bdbf906"

// buildTestArchive assembles a product-shaped export zip: acdl manifest with
// API+Policy+PolicyAction+Alias assets (and an Alias dependsOn), the API/
// payload tree, PLUS the three entries the sanitizer must drop (Alias/,
// PassmanData/, ExportReport.json).
func buildTestArchive(t *testing.T, isActive bool) []byte {
	t.Helper()
	acdl := `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<asset_composite name="APIGatewayAssets" xmlns="http://namespaces.softwareag.com/acdl/1.0">
    <buildInfo name="BuildTimestamp" value="2026-07-17T20:00:00"/>
    <asset name="API.` + testArchiveGUID + `" displayName="spike[1.0.0]" isDeployable="true">
        <implementation.generic type="API"/>
        <dependsOn>APIGateway:Policy.pol-1</dependsOn>
    </asset>
    <asset name="Policy.pol-1" displayName="Policy" isDeployable="true">
        <implementation.generic type="Policy"/>
        <dependsOn>APIGateway:PolicyAction.act-route</dependsOn>
        <dependsOn>APIGateway:Alias.al-1</dependsOn>
    </asset>
    <asset name="PolicyAction.act-route" displayName="Routing" isDeployable="true">
        <implementation.generic type="PolicyAction"/>
    </asset>
    <asset name="Alias.al-1" displayName="backend alias" isDeployable="true">
        <implementation.generic type="Alias"/>
    </asset>
</asset_composite>`
	apiRec := map[string]any{
		"id": testArchiveGUID, "apiName": "spike", "apiVersion": "1.0.0",
		"isActive": isActive, "type": "REST",
	}
	routeRec := map[string]any{
		"id":          "act-route",
		"templateKey": "straightThroughRouting",
		"parameters": []any{map[string]any{
			"templateKey": "endpointUri",
			"values":      []any{"http://backend-dev:8080/${sys:resource_path}"},
		}},
	}
	files := map[string]any{
		"APIGatewayAssets.acdl": acdl,
		"API/API." + testArchiveGUID + "/API." + testArchiveGUID:                                             apiRec,
		"API/API." + testArchiveGUID + "/Policy/Policy.pol-1/Policy.pol-1":                                   map[string]any{"id": "pol-1"},
		"API/API." + testArchiveGUID + "/Policy/Policy.pol-1/PolicyAction/PolicyAction.act-route":            routeRec,
		"Alias/Alias.al-1":       map[string]any{"id": "al-1", "type": "endpoint", "endPointURI": "http://backend-dev:8080"},
		"PassmanData/PassmanData.HTTP_AUTH_OUTBOUND_CLIENT_PWDcred": map[string]any{"pw": "encrypted"},
		"ExportReport.json":      []any{},
	}
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, content := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatalf("zip create %s: %v", name, err)
		}
		switch c := content.(type) {
		case string:
			_, err = w.Write([]byte(c))
		default:
			var data []byte
			data, err = json.Marshal(c)
			if err == nil {
				_, err = w.Write(data)
			}
		}
		if err != nil {
			t.Fatalf("zip write %s: %v", name, err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("zip close: %v", err)
	}
	return buf.Bytes()
}

func zipNames(t *testing.T, b []byte) []string {
	t.Helper()
	zr, err := zip.NewReader(bytes.NewReader(b), int64(len(b)))
	if err != nil {
		t.Fatalf("re-open sanitized zip: %v", err)
	}
	var names []string
	for _, f := range zr.File {
		names = append(names, f.Name)
	}
	return names
}

func TestSanitizeArchive_StripsRewritesAndReportsIDMap(t *testing.T) {
	clean, rep, err := SanitizeArchive(buildTestArchive(t, true), "acme-backend")
	if err != nil {
		t.Fatalf("SanitizeArchive: %v", err)
	}
	names := strings.Join(zipNames(t, clean), "\n")
	for _, banned := range []string{"Alias/", "PassmanData/", "ExportReport.json"} {
		if strings.Contains(names, banned) {
			t.Errorf("sanitized zip still carries %s:\n%s", banned, names)
		}
	}
	// acdl purge: the Alias asset AND the dependsOn pointing at it are gone
	// (a declared asset with no payload fails its whole dependency branch).
	zr, _ := zip.NewReader(bytes.NewReader(clean), int64(len(clean)))
	for _, f := range zr.File {
		if f.Name != "APIGatewayAssets.acdl" {
			continue
		}
		rc, _ := f.Open()
		var acdl bytes.Buffer
		if _, err := acdl.ReadFrom(rc); err != nil {
			t.Fatalf("read acdl: %v", err)
		}
		rc.Close()
		if strings.Contains(acdl.String(), "Alias.") {
			t.Errorf("acdl still references the Alias asset:\n%s", acdl.String())
		}
	}
	// routing rewritten onto ${alias}
	if len(rep.RoutingRewritten) != 1 {
		t.Errorf("RoutingRewritten = %v, want exactly the straightThroughRouting action", rep.RoutingRewritten)
	}
	for _, f := range zr.File {
		if !strings.HasSuffix(f.Name, "PolicyAction.act-route") {
			continue
		}
		rc, _ := f.Open()
		var rec struct {
			Parameters []struct {
				TemplateKey string   `json:"templateKey"`
				Values      []string `json:"values"`
			} `json:"parameters"`
		}
		if err := json.NewDecoder(rc).Decode(&rec); err != nil {
			t.Fatalf("decode rewritten action: %v", err)
		}
		rc.Close()
		want := "${acme-backend}/${sys:resource_path}"
		if len(rec.Parameters) != 1 || len(rec.Parameters[0].Values) != 1 || rec.Parameters[0].Values[0] != want {
			t.Errorf("endpointUri = %+v, want %q", rec.Parameters, want)
		}
	}
	// id-map
	if len(rep.APIs) != 1 || rep.APIs[0].ID != testArchiveGUID || !rep.APIs[0].IsActive {
		t.Errorf("id-map = %+v, want the single active API %s", rep.APIs, testArchiveGUID)
	}
}

func TestSanitizeArchive_FailsClosedOnInactive(t *testing.T) {
	_, _, err := SanitizeArchive(buildTestArchive(t, false), "")
	if err == nil || !strings.Contains(err.Error(), "ARCHIVE_INACTIVE") {
		t.Fatalf("err = %v, want ARCHIVE_INACTIVE (the isActive trap: such an archive deactivates on import)", err)
	}
}

func TestImportArchive_RefusesUnscopedOverwrite(t *testing.T) {
	a := &Adapter{adminURL: "http://unused", username: "u", password: "p", http: http.DefaultClient}
	for _, ow := range []string{"*", "apis,aliases", "aliases"} {
		if _, err := a.ImportArchive(context.Background(), []byte("PK"), ow); err == nil {
			t.Errorf("overwrite=%q accepted, want refusal (alias clobber trap)", ow)
		}
	}
}

func TestImportArchive_TaintCheckRefusesEmbeddedAliases(t *testing.T) {
	a := &Adapter{adminURL: "http://unused", username: "u", password: "p", http: http.DefaultClient}
	_, err := a.ImportArchive(context.Background(), buildTestArchive(t, true), DefaultOverwrite)
	if err == nil || !strings.Contains(err.Error(), "ARCHIVE_TAINTED") {
		t.Fatalf("err = %v, want ARCHIVE_TAINTED (Alias/ + PassmanData/ embedded)", err)
	}
}

func TestImportArchive_FlattensRowsAndFailsClosedOnFailure(t *testing.T) {
	sanitized, _, err := SanitizeArchive(buildTestArchive(t, true), "acme-backend")
	if err != nil {
		t.Fatalf("sanitize fixture: %v", err)
	}
	respond := func(rows string) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !strings.HasPrefix(r.URL.Path, "/rest/apigateway/archive") {
				http.NotFound(w, r)
				return
			}
			if got := r.URL.Query().Get("overwrite"); got != DefaultOverwrite {
				t.Errorf("overwrite param = %q, want %q", got, DefaultOverwrite)
			}
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(rows))
		}))
	}

	okSrv := respond(`{"ArchiveResult":[
	  {"API":{"name":"spike[1.0.0]","id":"` + testArchiveGUID + `","status":"Success","overwritten":true}},
	  {"Policy":{"name":"p","id":"pol-1","status":"Success","overwritten":true}}]}`)
	defer okSrv.Close()
	a := &Adapter{adminURL: okSrv.URL, username: "u", password: "p", http: okSrv.Client()}
	rows, err := a.ImportArchive(context.Background(), sanitized, "")
	if err != nil {
		t.Fatalf("ImportArchive: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2", len(rows))
	}
	seenAPI := false
	for _, r := range rows {
		if r.Type == "API" && r.ID == testArchiveGUID && r.Overwritten {
			seenAPI = true
		}
	}
	if !seenAPI {
		t.Errorf("flattened rows missing the overwritten API row: %+v", rows)
	}

	failSrv := respond(`{"ArchiveResult":[
	  {"API":{"name":"spike[1.0.0]","id":"x","status":"Failed","explanation":"Asset already exists"}}]}`)
	defer failSrv.Close()
	a = &Adapter{adminURL: failSrv.URL, username: "u", password: "p", http: failSrv.Client()}
	if _, err := a.ImportArchive(context.Background(), sanitized, ""); err == nil || !strings.Contains(err.Error(), "IMPORT_FAILED") {
		t.Fatalf("err = %v, want IMPORT_FAILED with the row explanation", err)
	}
}

func TestSetAPIActive_DeactivateGate(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	// Gate closed: deactivate is UPDATE_FORBIDDEN, activate still flows.
	a := &Adapter{adminURL: srv.URL, username: "u", password: "p", http: srv.Client(), allowDeactivate: false}
	if err := a.setAPIActive(context.Background(), "api-1", false); err == nil || !strings.Contains(err.Error(), "UPDATE_FORBIDDEN") {
		t.Fatalf("deactivate err = %v, want UPDATE_FORBIDDEN (ADR-079 gate)", err)
	}
	if err := a.setAPIActive(context.Background(), "api-1", true); err != nil {
		t.Fatalf("activate with the gate closed should still pass: %v", err)
	}
	// Gate open (lab default): deactivate flows.
	a.allowDeactivate = true
	if err := a.setAPIActive(context.Background(), "api-1", false); err != nil {
		t.Fatalf("deactivate with the gate open: %v", err)
	}
}

func TestVerifyEndpointAliasValue(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/rest/apigateway/alias" {
			t.Errorf("unexpected call %s %s (verify must be read-only)", r.Method, r.URL.Path)
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(`{"alias":[{"id":"a1","name":"g8par-backend","type":"endpoint","endPointURI":"http://poc-token-echo:8080/backend/rec"}]}`))
	}))
	defer srv.Close()
	a := &Adapter{adminURL: srv.URL, username: "u", password: "p", http: srv.Client()}

	if err := a.VerifyEndpointAliasValue(context.Background(), "g8par-backend", "http://poc-token-echo:8080/backend/rec"); err != nil {
		t.Fatalf("nominal: %v", err)
	}
	if err := a.VerifyEndpointAliasValue(context.Background(), "g8par-backend", "http://autre"); err == nil || !strings.Contains(err.Error(), "ALIAS_DRIFT") {
		t.Fatalf("want ALIAS_DRIFT, got %v", err)
	}
	if err := a.VerifyEndpointAliasValue(context.Background(), "absent", "x"); err == nil || !strings.Contains(err.Error(), "ALIAS_MISSING") {
		t.Fatalf("want ALIAS_MISSING, got %v", err)
	}
}
